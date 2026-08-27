import CryptoKit
import Darwin
import Foundation

/// Native implementation of the released desktop dictation and realtime
/// voice-history AppHost services.
///
/// Dictation audio and metadata are stored on real disk using the desktop
/// directory layout. Realtime snapshots come only from the injected runtime:
/// subscribing immediately forwards that runtime's current snapshot and then
/// forwards matching locator updates.
public actor CodexDesktopHistoryMediaAppHostService {
    public typealias Value = CodexDesktopAppHostRPC.Value
    public typealias DictationChangedHandler =
        @Sendable () async -> Void
    public typealias DownloadsDirectoryProvider =
        @Sendable () throws -> URL
    public typealias RealtimeSnapshotProvider =
        @Sendable (RealtimeLocator) async throws -> Value
    public typealias RealtimeUpdateHandler =
        @Sendable (RealtimeLocator, Value) async -> Void
    public typealias RealtimeUnsubscribe =
        @Sendable () async -> Void
    public typealias RealtimeRuntimeSubscribe =
        @Sendable (
            @escaping RealtimeUpdateHandler
        ) async throws -> RealtimeUnsubscribe
    public typealias SubscriptionEventHandler =
        @Sendable (_ callbackID: Int, _ snapshot: Value) async -> Void

    public enum Error: Swift.Error, Equatable, Sendable {
        case cannotDeleteActiveRecording
        case invalidArguments
        case recordingHasNoAudio
        case recordingNotFound
        case realtimeHistoryUnavailable
        case subscriptionEventHandlerUnavailable
        case unsupportedMethod(service: String, method: String)
    }

    public struct RealtimeLocator:
        Equatable, Hashable, Sendable
    {
        public let hostID: String
        public let conversationID: String

        public init(hostID: String, conversationID: String) {
            self.hostID = hostID
            self.conversationID = conversationID
        }
    }

    private enum DictationStatus: String, Codable, Sendable {
        case recording
        case completed
        case cancelled
        case interrupted
    }

    private enum DictationSurface: String, Codable, Sendable {
        case composer
        case global
    }

    private struct DictationMetadata: Codable, Sendable {
        var createdAtMs: Double
        var durationMs: Double?
        let id: String
        let mimeType: String
        var sizeBytes: Int64
        var status: DictationStatus
        let surface: DictationSurface
        var text: String
    }

    private struct LegacyDictation: Codable {
        let id: String
        let createdAtMs: Double
        let text: String
    }

    private struct RealtimeListener: Sendable {
        let callbackID: Int
        let locator: RealtimeLocator
    }

    private static let metadataName = "metadata.json"
    private static let chunkSuffix = ".chunk"
    private static let retentionLimit = 20
    private static let directoryPermissions = 0o700
    private static let filePermissions = 0o600

    private let dictationDirectory: URL
    private let downloadsDirectory: DownloadsDirectoryProvider?
    private let onDictationChanged: DictationChangedHandler
    private let realtimeSnapshotProvider: RealtimeSnapshotProvider?
    private let realtimeRuntimeSubscribe: RealtimeRuntimeSubscribe?
    private let subscriptionEventHandler: SubscriptionEventHandler?

    private var didLoadDictations = false
    private var dictations: [String: DictationMetadata] = [:]
    private var realtimeListeners: [Int: RealtimeListener] = [:]
    private var runtimeUnsubscribe: RealtimeUnsubscribe?

    public init(
        dictationDirectory: URL,
        downloadsDirectory: DownloadsDirectoryProvider? = nil,
        onDictationChanged: DictationChangedHandler? = nil,
        realtimeSnapshotProvider: RealtimeSnapshotProvider? = nil,
        realtimeRuntimeSubscribe: RealtimeRuntimeSubscribe? = nil,
        subscriptionEventHandler: SubscriptionEventHandler? = nil
    ) {
        self.dictationDirectory = dictationDirectory
        self.downloadsDirectory = downloadsDirectory
        self.onDictationChanged = onDictationChanged ?? {}
        self.realtimeSnapshotProvider = realtimeSnapshotProvider
        self.realtimeRuntimeSubscribe = realtimeRuntimeSubscribe
        self.subscriptionEventHandler = subscriptionEventHandler
    }

    public func invoke(
        service: String,
        method: String,
        arguments: [Value]?
    ) async throws -> Value {
        switch (service, method) {
        case ("dictationHistory", "appendChunk"):
            try await appendChunk(arguments)
            return .undefined
        case ("dictationHistory", "finalize"):
            try await finalize(arguments)
            return .undefined
        case ("dictationHistory", "setTranscript"):
            try await setTranscript(arguments)
            return .undefined
        case ("dictationHistory", "list"):
            try await loadDictationsIfNeeded()
            return .object([
                "items": .array(
                    sortedDictations().map(Self.metadataValue)
                )
            ])
        case ("dictationHistory", "readAudio"):
            return try await readAudio(arguments)
        case ("dictationHistory", "download"):
            try await download(arguments)
            return .undefined
        case ("dictationHistory", "delete"):
            try await delete(arguments)
            return .undefined
        case ("realtimeVoiceHistory", "subscribe"):
            return try await subscribe(arguments)
        default:
            throw Error.unsupportedMethod(
                service: service,
                method: method
            )
        }
    }

    public func unsubscribe(callbackID: Int) async {
        realtimeListeners.removeValue(forKey: callbackID)
        if realtimeListeners.isEmpty, let runtimeUnsubscribe {
            self.runtimeUnsubscribe = nil
            await runtimeUnsubscribe()
        }
    }

    private func appendChunk(_ arguments: [Value]?) async throws {
        let fields = try Self.onlyObject(arguments)
        let chunk = try Self.bytes(fields["chunk"])
        let createdAtMs = try Self.finiteNumber(
            fields["createdAtMs"]
        )
        let id = try Self.nonemptyString(fields["id"])
        let mimeType = try Self.nonemptyString(fields["mimeType"])
        let sequence = try Self.integer(
            fields["sequence"],
            minimum: 0,
            maximum: 9_999_999_999
        )
        let surface = try Self.surface(fields["surface"])
        guard !chunk.isEmpty else {
            return
        }

        try await loadDictationsIfNeeded()
        try Self.ensurePrivateDirectory(dictationDirectory)
        let recordingDirectory = recordingDirectory(for: id)
        try Self.ensurePrivateDirectory(recordingDirectory)

        var metadata = dictations[id]
            ?? DictationMetadata(
                createdAtMs: createdAtMs,
                durationMs: nil,
                id: id,
                mimeType: mimeType,
                sizeBytes: 0,
                status: .recording,
                surface: surface,
                text: ""
            )
        if dictations[id] == nil {
            dictations[id] = metadata
            try persist(metadata)
        }

        let chunkURL = recordingDirectory.appendingPathComponent(
            String(format: "%010lld", sequence)
                + Self.chunkSuffix
        )
        if try Self.writeExclusive(chunk, to: chunkURL) {
            metadata.sizeBytes += Int64(chunk.count)
        }
        dictations[id] = metadata
        try persist(metadata)
        try cleanupRetention()
        await onDictationChanged()
    }

    private func finalize(_ arguments: [Value]?) async throws {
        let fields = try Self.onlyObject(arguments)
        let id = try Self.nonemptyString(fields["id"])
        guard case let .bool(cancelled) = fields["cancelled"] else {
            throw Error.invalidArguments
        }
        let durationMs: Double?
        if let value = fields["durationMs"] {
            let parsed = try Self.finiteNumber(value)
            guard parsed >= 0 else {
                throw Error.invalidArguments
            }
            durationMs = parsed
        } else {
            durationMs = nil
        }

        try await loadDictationsIfNeeded()
        guard var metadata = dictations[id] else {
            return
        }
        metadata.status = cancelled ? .cancelled : .completed
        metadata.durationMs = durationMs
        dictations[id] = metadata
        try persist(metadata)
        try cleanupRetention()
        await onDictationChanged()
    }

    private func setTranscript(_ arguments: [Value]?) async throws {
        let fields = try Self.onlyObject(arguments)
        let id = try Self.nonemptyString(fields["id"])
        guard case let .string(text) = fields["text"] else {
            throw Error.invalidArguments
        }
        try await loadDictationsIfNeeded()
        guard var metadata = dictations[id] else {
            return
        }
        metadata.text = text.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        dictations[id] = metadata
        try persist(metadata)
        await onDictationChanged()
    }

    private func download(_ arguments: [Value]?) async throws {
        let fields = try Self.onlyObject(arguments)
        let id = try Self.nonemptyString(fields["id"])
        try await loadDictationsIfNeeded()
        guard let metadata = dictations[id] else {
            throw Error.recordingNotFound
        }
        let chunks = try Self.chunkFiles(
            in: recordingDirectory(for: id)
        )
        guard !chunks.isEmpty else {
            throw Error.recordingHasNoAudio
        }
        let downloadsDirectory = try self.downloadsDirectory?()
            ?? Self.systemDownloadsDirectory()
        let fileExtension = Self.audioFileExtension(
            for: metadata.mimeType
        )
        let timestamp = Self.javascriptISOString(
            milliseconds: metadata.createdAtMs
        ).replacingOccurrences(of: ":", with: "-")
        let baseName = "Codex dictation \(timestamp)"

        var collisionIndex = 0
        while true {
            let suffix = collisionIndex == 0
                ? ""
                : " (\(collisionIndex))"
            let destination = downloadsDirectory.appendingPathComponent(
                "\(baseName)\(suffix).\(fileExtension)"
            )
            if try Self.concatenateExclusively(
                chunks,
                to: destination
            ) {
                return
            }
            collisionIndex += 1
        }
    }

    private func readAudio(_ arguments: [Value]?) async throws -> Value {
        let fields = try Self.onlyObject(arguments)
        let id = try Self.nonemptyString(fields["id"])
        try await loadDictationsIfNeeded()
        guard let metadata = dictations[id] else {
            throw Error.recordingNotFound
        }
        let chunks = try Self.chunkFiles(
            in: recordingDirectory(for: id)
        )
        guard !chunks.isEmpty else {
            throw Error.recordingHasNoAudio
        }
        var audio = Data()
        audio.reserveCapacity(
            chunks.reduce(0) { $0 + $1.sizeBytes }
        )
        for chunk in chunks {
            audio.append(try Data(contentsOf: chunk.url))
        }
        return .object([
            "audio": .array(audio.map { .integer(Int64($0)) }),
            "mimeType": .string(metadata.mimeType),
        ])
    }

    private func delete(_ arguments: [Value]?) async throws {
        let fields = try Self.onlyObject(arguments)
        let id = try Self.nonemptyString(fields["id"])
        try await loadDictationsIfNeeded()
        guard let metadata = dictations[id] else {
            return
        }
        guard metadata.status != .recording else {
            throw Error.cannotDeleteActiveRecording
        }
        dictations.removeValue(forKey: id)
        try FileManager.default.removeItemIfPresent(
            at: recordingDirectory(for: id)
        )
        try removeLegacyDictations(ids: [id])
        await onDictationChanged()
    }

    private func subscribe(_ arguments: [Value]?) async throws -> Value {
        guard let arguments,
              arguments.count == 2,
              case let .import(callbackID) = arguments[1]
        else {
            throw Error.invalidArguments
        }
        let locator = try Self.locator(arguments[0])
        guard let realtimeSnapshotProvider else {
            throw Error.realtimeHistoryUnavailable
        }
        guard let subscriptionEventHandler else {
            throw Error.subscriptionEventHandlerUnavailable
        }

        if runtimeUnsubscribe == nil,
           let realtimeRuntimeSubscribe
        {
            runtimeUnsubscribe = try await realtimeRuntimeSubscribe {
                [weak self] locator, snapshot in
                await self?.receiveRealtimeUpdate(
                    locator: locator,
                    snapshot: snapshot
                )
            }
        }
        realtimeListeners[callbackID] = RealtimeListener(
            callbackID: callbackID,
            locator: locator
        )
        let snapshot = try await realtimeSnapshotProvider(locator)
        await subscriptionEventHandler(callbackID, snapshot)
        return .rpcObject([
            "unsubscribe": .rpcObject([:])
        ])
    }

    private func receiveRealtimeUpdate(
        locator: RealtimeLocator,
        snapshot: Value
    ) async {
        guard let subscriptionEventHandler else {
            return
        }
        let listeners = realtimeListeners.values.filter {
            $0.locator == locator
        }
        for listener in listeners {
            await subscriptionEventHandler(
                listener.callbackID,
                snapshot
            )
        }
    }

    private func loadDictationsIfNeeded() async throws {
        guard !didLoadDictations else {
            return
        }
        try Self.ensurePrivateDirectory(dictationDirectory)
        let entries = try FileManager.default.contentsOfDirectory(
            at: dictationDirectory,
            includingPropertiesForKeys: [
                .isDirectoryKey,
                .isSymbolicLinkKey,
            ],
            options: [.skipsHiddenFiles]
        )
        for directory in entries {
            let values = try? directory.resourceValues(
                forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
            )
            guard values?.isDirectory == true,
                  values?.isSymbolicLink != true
            else {
                continue
            }
            do {
                try FileManager.default.setAttributes(
                    [.posixPermissions: Self.directoryPermissions],
                    ofItemAtPath: directory.path
                )
                var metadata = try Self.decodeMetadata(
                    at: directory.appendingPathComponent(
                        Self.metadataName
                    )
                )
                metadata.sizeBytes = try Self.chunkFiles(in: directory)
                    .reduce(0) { $0 + Int64($1.sizeBytes) }
                if metadata.status == .recording {
                    metadata.status = .interrupted
                }
                try persist(metadata)
                dictations[metadata.id] = metadata
            } catch {
                // Released desktop recovery ignores a malformed recording
                // directory while preserving every independently valid one.
                continue
            }
        }
        try migrateLegacyDictations()
        try cleanupRetention()
        didLoadDictations = true
    }

    private func sortedDictations() -> [DictationMetadata] {
        dictations.values.sorted {
            $0.createdAtMs > $1.createdAtMs
        }
    }

    private func cleanupRetention() throws {
        let sorted = sortedDictations()
        let recordingCount = sorted.filter {
            $0.status == .recording
        }.count
        let completed = sorted.filter {
            $0.status != .recording
        }
        let keepCompletedCount = max(
            0,
            Self.retentionLimit - recordingCount
        )
        let removed = completed.dropFirst(keepCompletedCount)
        for metadata in removed {
            try FileManager.default.removeItemIfPresent(
                at: recordingDirectory(for: metadata.id)
            )
            dictations.removeValue(forKey: metadata.id)
        }
        try removeLegacyDictations(ids: removed.map(\.id))
    }

    private func recordingDirectory(for id: String) -> URL {
        let digest = SHA256.hash(data: Data(id.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return dictationDirectory.appendingPathComponent(
            digest,
            isDirectory: true
        )
    }

    private func persist(_ metadata: DictationMetadata) throws {
        let directory = recordingDirectory(for: metadata.id)
        try Self.ensurePrivateDirectory(directory)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(metadata)
        let url = directory.appendingPathComponent(Self.metadataName)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: Self.filePermissions],
            ofItemAtPath: url.path
        )
    }

    private var legacyHistoryURL: URL {
        dictationDirectory.deletingLastPathComponent()
            .appendingPathComponent("transcription-history.jsonl")
    }

    private func migrateLegacyDictations() throws {
        let legacy = Self.readLegacyDictations(at: legacyHistoryURL)
        for item in legacy {
            if var existing = dictations[item.id] {
                if existing.text.isEmpty, !item.text.isEmpty {
                    existing.text = item.text
                    dictations[item.id] = existing
                    try persist(existing)
                }
                continue
            }
            let metadata = DictationMetadata(
                createdAtMs: item.createdAtMs,
                durationMs: nil,
                id: item.id,
                mimeType: "audio/webm",
                sizeBytes: 0,
                status: .completed,
                surface: .global,
                text: item.text
            )
            dictations[item.id] = metadata
            try persist(metadata)
        }
        try writeLegacyDictations(legacy)
    }

    private func removeLegacyDictations(ids: [String]) throws {
        guard !ids.isEmpty else {
            return
        }
        let removed = Set(ids)
        try writeLegacyDictations(
            Self.readLegacyDictations(at: legacyHistoryURL)
                .filter { !removed.contains($0.id) }
        )
    }

    private func writeLegacyDictations(
        _ dictations: [LegacyDictation]
    ) throws {
        try Self.ensurePrivateDirectory(
            legacyHistoryURL.deletingLastPathComponent()
        )
        let encoder = JSONEncoder()
        var lines = Data()
        for dictation in dictations.reversed() {
            lines.append(try encoder.encode(dictation))
            lines.append(0x0A)
        }
        try lines.write(to: legacyHistoryURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: Self.filePermissions],
            ofItemAtPath: legacyHistoryURL.path
        )
    }

    private static func readLegacyDictations(
        at url: URL
    ) -> [LegacyDictation] {
        guard let raw = try? String(contentsOf: url, encoding: .utf8)
        else {
            return []
        }
        let decoder = JSONDecoder()
        let valid = raw.split(whereSeparator: \.isNewline).compactMap {
            try? decoder.decode(
                LegacyDictation.self,
                from: Data($0.utf8)
            )
        }
        return Array(valid.suffix(retentionLimit).reversed())
    }

    private struct ChunkFile {
        let url: URL
        let sequence: Int64
        let sizeBytes: Int
    }

    private static func chunkFiles(in directory: URL) throws
        -> [ChunkFile]
    {
        let entries = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        )
        return try entries.compactMap { url in
            let name = url.lastPathComponent
            guard name.count == 16,
                  name.hasSuffix(chunkSuffix)
            else {
                return nil
            }
            let sequenceText = name.prefix(10)
            guard sequenceText.allSatisfy(\.isNumber),
                  let sequence = Int64(sequenceText)
            else {
                return nil
            }
            let size = try url.resourceValues(
                forKeys: [.fileSizeKey]
            ).fileSize ?? 0
            return ChunkFile(
                url: url,
                sequence: sequence,
                sizeBytes: size
            )
        }.sorted { $0.sequence < $1.sequence }
    }

    private static func writeExclusive(
        _ data: Data,
        to url: URL
    ) throws -> Bool {
        guard let handle = try exclusiveFileHandle(at: url) else {
            return false
        }
        defer { try? handle.close() }
        try handle.write(contentsOf: data)
        try handle.synchronize()
        return true
    }

    private static func concatenateExclusively(
        _ chunks: [ChunkFile],
        to destination: URL
    ) throws -> Bool {
        guard let handle = try exclusiveFileHandle(at: destination)
        else {
            return false
        }
        do {
            defer { try? handle.close() }
            for chunk in chunks {
                try handle.write(
                    contentsOf: Data(contentsOf: chunk.url)
                )
            }
            try handle.synchronize()
            return true
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    private static func exclusiveFileHandle(at url: URL) throws
        -> FileHandle?
    {
        let descriptor = url.path.withCString {
            Darwin.open(
                $0,
                O_WRONLY | O_CREAT | O_EXCL,
                mode_t(filePermissions)
            )
        }
        guard descriptor >= 0 else {
            if errno == EEXIST {
                return nil
            }
            throw POSIXError(
                POSIXErrorCode(rawValue: errno) ?? .EIO
            )
        }
        return FileHandle(
            fileDescriptor: descriptor,
            closeOnDealloc: true
        )
    }

    private static func decodeMetadata(
        at url: URL
    ) throws -> DictationMetadata {
        try JSONDecoder().decode(
            DictationMetadata.self,
            from: Data(contentsOf: url)
        )
    }

    private static func ensurePrivateDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: directoryPermissions]
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: directoryPermissions],
            ofItemAtPath: url.path
        )
    }

    private static func systemDownloadsDirectory() throws -> URL {
        if let directory = FileManager.default.urls(
            for: .downloadsDirectory,
            in: .userDomainMask
        ).first {
            return directory
        }
        throw CocoaError(.fileNoSuchFile)
    }

    private static func audioFileExtension(
        for mimeType: String
    ) -> String {
        switch mimeType.split(separator: ";", maxSplits: 1)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        {
        case "audio/mp4":
            return "m4a"
        case "audio/ogg":
            return "ogg"
        case "audio/mpeg":
            return "mp3"
        case "audio/aac":
            return "aac"
        case "audio/wav", "audio/wave", "audio/x-wav":
            return "wav"
        default:
            return "webm"
        }
    }

    private static func javascriptISOString(
        milliseconds: Double
    ) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [
            .withInternetDateTime,
            .withFractionalSeconds,
        ]
        return formatter.string(
            from: Date(
                timeIntervalSince1970:
                    milliseconds.rounded(.towardZero) / 1_000
            )
        )
    }

    private static func metadataValue(
        _ metadata: DictationMetadata
    ) -> Value {
        var fields: [String: Value] = [
            "createdAtMs": numberValue(metadata.createdAtMs),
            "id": .string(metadata.id),
            "mimeType": .string(metadata.mimeType),
            "sizeBytes": .integer(metadata.sizeBytes),
            "status": .string(metadata.status.rawValue),
            "surface": .string(metadata.surface.rawValue),
            "text": .string(metadata.text),
        ]
        if let durationMs = metadata.durationMs {
            fields["durationMs"] = numberValue(durationMs)
        }
        return .object(fields)
    }

    private static func numberValue(_ value: Double) -> Value {
        if value.rounded(.towardZero) == value,
           value >= Double(Int64.min),
           value <= Double(Int64.max)
        {
            return .integer(Int64(value))
        }
        return .number(value)
    }

    private static func onlyObject(
        _ arguments: [Value]?
    ) throws -> [String: Value] {
        guard let arguments,
              arguments.count == 1,
              case let .object(fields) = arguments[0]
        else {
            throw Error.invalidArguments
        }
        return fields
    }

    private static func bytes(_ value: Value?) throws -> Data {
        guard case let .array(values) = value else {
            throw Error.invalidArguments
        }
        var result = Data()
        result.reserveCapacity(values.count)
        for value in values {
            let byte = try integer(
                value,
                minimum: 0,
                maximum: 255
            )
            result.append(UInt8(byte))
        }
        return result
    }

    private static func finiteNumber(_ value: Value?) throws -> Double {
        switch value {
        case let .integer(integer):
            return Double(integer)
        case let .number(number) where number.isFinite:
            return number
        default:
            throw Error.invalidArguments
        }
    }

    private static func integer(
        _ value: Value?,
        minimum: Int64,
        maximum: Int64
    ) throws -> Int64 {
        let integer: Int64
        switch value {
        case let .integer(value):
            integer = value
        case let .number(value)
            where value.isFinite
                && value.rounded(.towardZero) == value
                && value >= Double(Int64.min)
                && value <= Double(Int64.max):
            integer = Int64(value)
        default:
            throw Error.invalidArguments
        }
        guard (minimum ... maximum).contains(integer) else {
            throw Error.invalidArguments
        }
        return integer
    }

    private static func nonemptyString(_ value: Value?) throws
        -> String
    {
        guard case let .string(value) = value, !value.isEmpty else {
            throw Error.invalidArguments
        }
        return value
    }

    private static func surface(_ value: Value?) throws
        -> DictationSurface
    {
        guard case let .string(value) = value,
              let surface = DictationSurface(rawValue: value)
        else {
            throw Error.invalidArguments
        }
        return surface
    }

    private static func locator(_ value: Value?) throws
        -> RealtimeLocator
    {
        guard case let .object(fields) = value else {
            throw Error.invalidArguments
        }
        return RealtimeLocator(
            hostID: try nonemptyString(fields["hostId"]),
            conversationID: try nonemptyString(
                fields["conversationId"]
            )
        )
    }
}

private extension FileManager {
    func removeItemIfPresent(at url: URL) throws {
        guard fileExists(atPath: url.path) else {
            return
        }
        try removeItem(at: url)
    }
}
