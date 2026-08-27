import CryptoKit
import Foundation

/// iPad implementation of the released desktop `artifactDocuments` AppHost.
///
/// The contract is taken from `Vge` and its `hye` durable store in desktop
/// release 26.730.61309. Unlike a DTO-only bridge, this service owns a real
/// durable document store, verifies the public file on every operation,
/// materializes bytes atomically, and shares viewer sessions across exact-file
/// bindings.
public actor CodexDesktopArtifactDocumentsAppHostService {
    public typealias Value = CodexDesktopAppHostRPC.Value
    public typealias SubscriptionEventHandler =
        @Sendable (_ callbackID: Int, _ event: Value) async -> Void

    public enum Error: Swift.Error, Equatable, Sendable {
        case invalidArguments
        case invalidArtifactPath
        case unauthorizedWorkspaceRoot
        case exactFileMismatch
        case documentDoesNotExist
        case documentIDMismatch
        case documentIDCollision
        case documentKindCollision
        case checkpointCollision
        case publicFileHashMismatch
        case updateIDCollision
        case materializationIDCollision
        case replacementDocumentIDCollision
        case subscriptionEventHandlerUnavailable
        case unsupportedMethod(service: String, method: String)
    }

    private let runtime: ArtifactDocumentsRuntime
    private let exactPublicFilePath: String?
    private let subscriptionEventHandler: SubscriptionEventHandler?

    public init(
        allowedWorkspaceRoots: [URL],
        storeDirectory: URL,
        subscriptionEventHandler: SubscriptionEventHandler? = nil
    ) {
        runtime = ArtifactDocumentsRuntime(
            allowedWorkspaceRoots: allowedWorkspaceRoots,
            storeDirectory: storeDirectory
        )
        exactPublicFilePath = nil
        self.subscriptionEventHandler = subscriptionEventHandler
    }

    private init(
        runtime: ArtifactDocumentsRuntime,
        exactPublicFilePath: String,
        subscriptionEventHandler: SubscriptionEventHandler?
    ) {
        self.runtime = runtime
        self.exactPublicFilePath = exactPublicFilePath
        self.subscriptionEventHandler = subscriptionEventHandler
    }

    /// Returns the executable Swift counterpart of the RPC object returned by
    /// desktop `bindToExactFile`. The regular `invoke` route returns the exact
    /// Cap'n Web RPC-object value, while native integration can retain this
    /// bound service and route its subsequent calls to it.
    public func bindToExactFile(
        publicFilePath: String
    ) async throws -> CodexDesktopArtifactDocumentsAppHostService {
        guard Self.isAbsolutePath(publicFilePath) else {
            throw Error.invalidArguments
        }
        let canonical = try await runtime.canonicalArtifactFile(
            publicFilePath
        )
        if let exactPublicFilePath,
           canonical != exactPublicFilePath
        {
            throw Error.exactFileMismatch
        }
        return CodexDesktopArtifactDocumentsAppHostService(
            runtime: runtime,
            exactPublicFilePath: canonical,
            subscriptionEventHandler: subscriptionEventHandler
        )
    }

    /// Native counterpart of the subscription object's `unsubscribe` method.
    public func unsubscribe(callbackID: Int) async {
        await runtime.unsubscribe(callbackID: callbackID)
    }

    public func invoke(
        service: String,
        method: String,
        arguments: [Value]?
    ) async throws -> Value {
        guard service == "artifactDocuments" else {
            throw Error.unsupportedMethod(
                service: service,
                method: method
            )
        }

        switch method {
        case "bindToExactFile":
            let fields = try Self.onlyObject(
                arguments,
                keys: ["publicFilePath"]
            )
            let path = try Self.absolutePath(
                fields["publicFilePath"]
            )
            _ = try await bindToExactFile(publicFilePath: path)
            return .rpcObject([:])

        case "find":
            let request = try Self.baseRequest(arguments)
            return try await runtime.find(
                request,
                exactPublicFilePath: exactPublicFilePath
            )

        case "adopt":
            let fields = try Self.onlyObject(
                arguments,
                keys: [
                    "checkpoint",
                    "documentId",
                    "kind",
                    "publicFileHash",
                    "publicFilePath",
                    "workspaceRoot",
                ]
            )
            let request = try Self.baseRequest(fields)
            let documentID = try Self.nonemptyString(
                fields["documentId"]
            )
            let kind = try Self.kind(fields["kind"])
            let checkpoint = try Self.bytes(fields["checkpoint"])
            let publicFileHash = try Self.hash(
                fields["publicFileHash"]
            )
            return try await runtime.adopt(
                request,
                checkpoint: checkpoint,
                documentID: documentID,
                kind: kind,
                publicFileHash: publicFileHash,
                exactPublicFilePath: exactPublicFilePath
            )

        case "read":
            let request = try Self.documentRequest(arguments)
            return try await runtime.read(
                request.base,
                documentID: request.documentID,
                exactPublicFilePath: exactPublicFilePath
            )

        case "append":
            let fields = try Self.onlyObject(
                arguments,
                keys: [
                    "baseStateVersion",
                    "bytes",
                    "documentId",
                    "originId",
                    "publicFilePath",
                    "source",
                    "updateId",
                    "workspaceRoot",
                ]
            )
            let request = try Self.baseRequest(fields)
            let documentID = try Self.nonemptyString(
                fields["documentId"]
            )
            let baseStateVersion = try Self.nonnegativeInteger(
                fields["baseStateVersion"]
            )
            let bytes = try Self.bytes(fields["bytes"])
            let originID = try Self.nonemptyString(fields["originId"])
            let source = try Self.source(fields["source"])
            let updateID = try Self.nonemptyString(fields["updateId"])
            return try await runtime.append(
                request,
                documentID: documentID,
                baseStateVersion: baseStateVersion,
                bytes: bytes,
                originID: originID,
                source: source,
                updateID: updateID,
                exactPublicFilePath: exactPublicFilePath
            )

        case "refreshCleanSession":
            let fields = try Self.onlyObject(
                arguments,
                keys: [
                    "checkpoint",
                    "documentId",
                    "expectedPublicFileHash",
                    "expectedStateVersion",
                    "observedPublicFileHash",
                    "publicFilePath",
                    "replacementDocumentId",
                    "workspaceRoot",
                ]
            )
            let request = try Self.baseRequest(fields)
            return try await runtime.refreshCleanSession(
                request,
                checkpoint: try Self.bytes(fields["checkpoint"]),
                documentID: try Self.nonemptyString(
                    fields["documentId"]
                ),
                expectedPublicFileHash: try Self.hash(
                    fields["expectedPublicFileHash"]
                ),
                expectedStateVersion: try Self.nonnegativeInteger(
                    fields["expectedStateVersion"]
                ),
                observedPublicFileHash: try Self.hash(
                    fields["observedPublicFileHash"]
                ),
                replacementDocumentID: try Self.nonemptyString(
                    fields["replacementDocumentId"]
                ),
                exactPublicFilePath: exactPublicFilePath
            )

        case "materialize":
            let fields = try Self.onlyObject(
                arguments,
                keys: [
                    "documentId",
                    "expectedStateVersion",
                    "materializationId",
                    "publicFileBytes",
                    "publicFilePath",
                    "workspaceRoot",
                ]
            )
            let request = try Self.baseRequest(fields)
            return try await runtime.materialize(
                request,
                documentID: try Self.nonemptyString(
                    fields["documentId"]
                ),
                expectedStateVersion: try Self.nonnegativeInteger(
                    fields["expectedStateVersion"]
                ),
                materializationID: try Self.nonemptyString(
                    fields["materializationId"]
                ),
                publicFileBytes: try Self.bytes(
                    fields["publicFileBytes"]
                ),
                exactPublicFilePath: exactPublicFilePath
            )

        case "subscribe":
            guard let arguments,
                  arguments.count == 2,
                  case let .import(callbackID) = arguments[1]
            else {
                throw Error.invalidArguments
            }
            guard let subscriptionEventHandler else {
                throw Error.subscriptionEventHandlerUnavailable
            }
            let request = try Self.documentRequest(
                [arguments[0]]
            )
            return try await runtime.subscribe(
                request.base,
                documentID: request.documentID,
                callbackID: callbackID,
                handler: subscriptionEventHandler,
                exactPublicFilePath: exactPublicFilePath
            )

        default:
            throw Error.unsupportedMethod(
                service: service,
                method: method
            )
        }
    }

    private static func baseRequest(
        _ arguments: [Value]?
    ) throws -> ArtifactBaseRequest {
        try baseRequest(
            onlyObject(
                arguments,
                keys: ["publicFilePath", "workspaceRoot"]
            )
        )
    }

    private static func baseRequest(
        _ fields: [String: Value]
    ) throws -> ArtifactBaseRequest {
        ArtifactBaseRequest(
            publicFilePath: try absolutePath(
                fields["publicFilePath"]
            ),
            workspaceRoot: try absolutePath(fields["workspaceRoot"])
        )
    }

    private static func documentRequest(
        _ arguments: [Value]?
    ) throws -> (
        base: ArtifactBaseRequest,
        documentID: String
    ) {
        let fields = try onlyObject(
            arguments,
            keys: [
                "documentId",
                "publicFilePath",
                "workspaceRoot",
            ]
        )
        return (
            try baseRequest(fields),
            try nonemptyString(fields["documentId"])
        )
    }

    private static func onlyObject(
        _ arguments: [Value]?,
        keys: Set<String>
    ) throws -> [String: Value] {
        guard let arguments,
              arguments.count == 1,
              case let .object(fields) = arguments[0],
              Set(fields.keys) == keys
        else {
            throw Error.invalidArguments
        }
        return fields
    }

    private static func nonemptyString(
        _ value: Value?
    ) throws -> String {
        guard case let .string(value) = value,
              !value.isEmpty
        else {
            throw Error.invalidArguments
        }
        return value
    }

    private static func absolutePath(
        _ value: Value?
    ) throws -> String {
        let path = try nonemptyString(value)
        guard isAbsolutePath(path) else {
            throw Error.invalidArguments
        }
        return path
    }

    private nonisolated static func isAbsolutePath(
        _ path: String
    ) -> Bool {
        (path as NSString).isAbsolutePath
    }

    private static func nonnegativeInteger(
        _ value: Value?
    ) throws -> Int64 {
        switch value {
        case let .integer(value) where value >= 0:
            return value
        case let .number(value)
            where value.isFinite
                && value >= 0
                && value.rounded(.towardZero) == value
                && value <= Double(Int64.max):
            return Int64(value)
        default:
            throw Error.invalidArguments
        }
    }

    private static func bytes(_ value: Value?) throws -> Data {
        guard case let .array(values) = value else {
            throw Error.invalidArguments
        }
        var result = Data()
        result.reserveCapacity(values.count)
        for value in values {
            let byte: Int64
            switch value {
            case let .integer(integer):
                byte = integer
            case let .number(number)
                where number.isFinite
                    && number.rounded(.towardZero) == number:
                byte = Int64(number)
            default:
                throw Error.invalidArguments
            }
            guard (0 ... 255).contains(byte) else {
                throw Error.invalidArguments
            }
            result.append(UInt8(byte))
        }
        return result
    }

    private static func hash(_ value: Value?) throws -> String {
        let value = try nonemptyString(value)
        guard value.utf8.count == 64,
              value.utf8.allSatisfy({
                  (48 ... 57).contains($0)
                      || (97 ... 102).contains($0)
              })
        else {
            throw Error.invalidArguments
        }
        return value
    }

    private static func kind(_ value: Value?) throws -> ArtifactKind {
        guard case let .string(value) = value,
              let kind = ArtifactKind(rawValue: value)
        else {
            throw Error.invalidArguments
        }
        return kind
    }

    private static func source(_ value: Value?) throws -> ArtifactSource {
        guard case let .string(value) = value,
              let source = ArtifactSource(rawValue: value)
        else {
            throw Error.invalidArguments
        }
        return source
    }
}

private struct ArtifactBaseRequest: Sendable {
    let publicFilePath: String
    let workspaceRoot: String
}

private enum ArtifactKind: String, Codable, Sendable {
    case presentation
    case spreadsheet
}

private enum ArtifactSource: String, Codable, Sendable {
    case model
    case user
}

private struct ArtifactUpdate: Codable, Equatable, Sendable {
    let bytes: Data
    let originID: String
    let source: ArtifactSource
    let stateVersion: Int64
    let updateID: String

    var value: CodexDesktopAppHostRPC.Value {
        .object([
            "bytes": Self.bytesValue(bytes),
            "originId": .string(originID),
            "source": .string(source.rawValue),
            "stateVersion": .integer(stateVersion),
            "updateId": .string(updateID),
        ])
    }

    fileprivate static func bytesValue(
        _ data: Data
    ) -> CodexDesktopAppHostRPC.Value {
        .array(data.map {
            .integer(Int64($0))
        })
    }
}

private struct ArtifactCommit: Codable, Equatable, Sendable {
    let bytesHash: String
    let originID: String
    let source: ArtifactSource
    let stateVersion: Int64
    let updateID: String
}

private struct ArtifactMaterialization:
    Codable,
    Equatable,
    Sendable
{
    let materializationID: String
    let publicFileHash: String
    let stateVersion: Int64
}

private struct ArtifactStoredRecord: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let adoptedCheckpointHash: String
    let checkpoint: Data
    let checkpointStateVersion: Int64
    var commits: [ArtifactCommit]
    let documentID: String
    let kind: ArtifactKind
    var materializations: [ArtifactMaterialization]
    var materializedStateVersion: Int64
    var publicFileHash: String
    let publicFilePath: String
    var stateVersion: Int64
    var updates: [ArtifactUpdate]

    var publicValue: CodexDesktopAppHostRPC.Value {
        .object([
            "checkpoint": ArtifactUpdate.bytesValue(checkpoint),
            "checkpointStateVersion": .integer(
                checkpointStateVersion
            ),
            "documentId": .string(documentID),
            "kind": .string(kind.rawValue),
            "materializedStateVersion": .integer(
                materializedStateVersion
            ),
            "publicFileHash": .string(publicFileHash),
            "publicFilePath": .string(publicFilePath),
            "stateVersion": .integer(stateVersion),
            "updates": .array(updates.map(\.value)),
        ])
    }
}

private actor ArtifactDocumentsRuntime {
    typealias Value = CodexDesktopAppHostRPC.Value
    typealias EventHandler =
        CodexDesktopArtifactDocumentsAppHostService
            .SubscriptionEventHandler
    typealias ServiceError =
        CodexDesktopArtifactDocumentsAppHostService.Error

    private enum LoadedRecord {
        case missing
        case corrupt
        case record(ArtifactStoredRecord)
    }

    private struct Listener: Sendable {
        let callbackID: Int
        let handler: EventHandler?
    }

    private static let maximumMaterializationBytes = 256 * 1024 * 1024
    private static let maximumRetainedCommits = 512

    private let allowedWorkspaceRoots: [URL]
    private let storeDirectory: URL
    private var loadedPaths: Set<String> = []
    private var records: [String: ArtifactStoredRecord] = [:]
    private var corruptPaths: Set<String> = []
    private var listenersByPath: [String: [Int: Listener]] = [:]

    init(
        allowedWorkspaceRoots: [URL],
        storeDirectory: URL
    ) {
        self.allowedWorkspaceRoots = allowedWorkspaceRoots
        self.storeDirectory = storeDirectory
    }

    func canonicalArtifactFile(_ path: String) throws -> String {
        let url = URL(fileURLWithPath: path)
            .resolvingSymlinksInPath()
            .standardizedFileURL
        guard let values = try? url.resourceValues(
            forKeys: [.isRegularFileKey]
        ),
            values.isRegularFile == true
        else {
            throw ServiceError.invalidArtifactPath
        }
        return url.path
    }

    func find(
        _ request: ArtifactBaseRequest,
        exactPublicFilePath: String?
    ) throws -> Value {
        let path = try operationPath(
            request,
            exactPublicFilePath: exactPublicFilePath
        )
        _ = try publicFileHash(path)
        switch load(path) {
        case .missing:
            return ok(.null)
        case .corrupt:
            return failed(reason: "corrupt")
        case let .record(record):
            return ok(record.publicValue)
        }
    }

    func adopt(
        _ request: ArtifactBaseRequest,
        checkpoint: Data,
        documentID: String,
        kind: ArtifactKind,
        publicFileHash suppliedHash: String,
        exactPublicFilePath: String?
    ) throws -> Value {
        let path = try operationPath(
            request,
            exactPublicFilePath: exactPublicFilePath
        )
        let currentHash = try publicFileHash(path)
        guard currentHash == suppliedHash else {
            throw ServiceError.publicFileHashMismatch
        }

        switch load(path) {
        case .corrupt:
            return failed(reason: "corrupt")
        case let .record(record):
            if record.publicFileHash != suppliedHash {
                return conflict(
                    actual: suppliedHash,
                    expected: record.publicFileHash
                )
            }
            guard record.documentID == documentID else {
                throw ServiceError.documentIDCollision
            }
            guard record.kind == kind else {
                throw ServiceError.documentKindCollision
            }
            guard record.adoptedCheckpointHash
                == Self.sha256(checkpoint)
            else {
                throw ServiceError.checkpointCollision
            }
            return ok(record.publicValue)

        case .missing:
            let record = ArtifactStoredRecord(
                schemaVersion: 1,
                adoptedCheckpointHash: Self.sha256(checkpoint),
                checkpoint: checkpoint,
                checkpointStateVersion: 0,
                commits: [],
                documentID: documentID,
                kind: kind,
                materializations: [],
                materializedStateVersion: 0,
                publicFileHash: suppliedHash,
                publicFilePath: path,
                stateVersion: 0,
                updates: []
            )
            guard persist(record) else {
                return failed(reason: "persistence")
            }
            return ok(record.publicValue)
        }
    }

    func read(
        _ request: ArtifactBaseRequest,
        documentID: String,
        exactPublicFilePath: String?
    ) throws -> Value {
        let path = try operationPath(
            request,
            exactPublicFilePath: exactPublicFilePath
        )
        _ = try publicFileHash(path)
        switch load(path) {
        case .missing:
            throw ServiceError.documentDoesNotExist
        case .corrupt:
            return failed(reason: "corrupt")
        case let .record(record):
            guard record.documentID == documentID else {
                throw ServiceError.documentIDMismatch
            }
            return ok(record.publicValue)
        }
    }

    func append(
        _ request: ArtifactBaseRequest,
        documentID: String,
        baseStateVersion: Int64,
        bytes: Data,
        originID: String,
        source: ArtifactSource,
        updateID: String,
        exactPublicFilePath: String?
    ) async throws -> Value {
        let path = try operationPath(
            request,
            exactPublicFilePath: exactPublicFilePath
        )
        _ = try publicFileHash(path)
        let loaded = load(path)
        guard case var .record(record) = loaded else {
            if case .missing = loaded {
                throw ServiceError.documentDoesNotExist
            }
            return failed(reason: "corrupt")
        }
        guard record.documentID == documentID else {
            throw ServiceError.documentIDMismatch
        }

        let bytesHash = Self.sha256(bytes)
        if let existing = record.commits.first(
            where: { $0.updateID == updateID }
        ) {
            guard existing.bytesHash == bytesHash,
                  existing.originID == originID,
                  existing.source == source
            else {
                throw ServiceError.updateIDCollision
            }
            return ok(.object([
                "applied": .bool(false),
                "stateVersion": .integer(existing.stateVersion),
            ]))
        }

        let earliestRetained =
            record.commits.first?.stateVersion
            ?? (record.stateVersion + 1)
        if baseStateVersion < earliestRetained - 1 {
            return ok(.object([
                "earliestRetainedStateVersion": .integer(
                    earliestRetained
                ),
                "outcome": .string("expired-retry"),
                "stateVersion": .integer(record.stateVersion),
            ]))
        }

        let stateVersion = record.stateVersion + 1
        let update = ArtifactUpdate(
            bytes: bytes,
            originID: originID,
            source: source,
            stateVersion: stateVersion,
            updateID: updateID
        )
        record.stateVersion = stateVersion
        record.updates.append(update)
        record.commits.append(
            ArtifactCommit(
                bytesHash: bytesHash,
                originID: originID,
                source: source,
                stateVersion: stateVersion,
                updateID: updateID
            )
        )
        if record.commits.count > Self.maximumRetainedCommits {
            record.commits.removeFirst(
                record.commits.count - Self.maximumRetainedCommits
            )
        }
        guard persist(record) else {
            return failed(reason: "persistence")
        }

        let event: Value = .object([
            "checkpointStateVersion": .integer(
                record.checkpointStateVersion
            ),
            "committedUpdate": update.value,
            "documentId": .string(record.documentID),
            "materializedStateVersion": .integer(
                record.materializedStateVersion
            ),
            "stateVersion": .integer(record.stateVersion),
        ])
        let listeners = Array(
            listenersByPath[path]?.values ?? [:].values
        )
        for listener in listeners {
            await listener.handler?(listener.callbackID, event)
        }

        return ok(.object([
            "applied": .bool(true),
            "stateVersion": .integer(stateVersion),
        ]))
    }

    func refreshCleanSession(
        _ request: ArtifactBaseRequest,
        checkpoint: Data,
        documentID: String,
        expectedPublicFileHash: String,
        expectedStateVersion: Int64,
        observedPublicFileHash: String,
        replacementDocumentID: String,
        exactPublicFilePath: String?
    ) throws -> Value {
        let path = try operationPath(
            request,
            exactPublicFilePath: exactPublicFilePath
        )
        let currentHash = try publicFileHash(path)
        let loaded = load(path)
        guard case let .record(currentRecord) = loaded else {
            if case .missing = loaded {
                throw ServiceError.documentDoesNotExist
            }
            return failed(reason: "corrupt")
        }

        if observedPublicFileHash != currentHash {
            return ok(.object([
                "outcome": .string("stale"),
                "record": currentRecord.publicValue,
            ]))
        }

        if (listenersByPath[path]?.count ?? 0) > 1 {
            guard currentRecord.documentID == documentID else {
                throw ServiceError.documentIDMismatch
            }
            return ok(.object([
                "outcome": .string("multiple-viewers"),
                "record": currentRecord.publicValue,
            ]))
        }

        if currentRecord.documentID == replacementDocumentID {
            guard currentRecord.adoptedCheckpointHash
                == Self.sha256(checkpoint),
                currentRecord.publicFileHash == currentHash
            else {
                throw ServiceError.replacementDocumentIDCollision
            }
            return ok(.object([
                "applied": .bool(false),
                "outcome": .string("refreshed"),
                "record": currentRecord.publicValue,
            ]))
        }

        if currentRecord.documentID != documentID
            || currentRecord.publicFileHash
                != expectedPublicFileHash
            || currentRecord.stateVersion != expectedStateVersion
        {
            return ok(.object([
                "outcome": .string("stale"),
                "record": currentRecord.publicValue,
            ]))
        }

        if currentRecord.stateVersion
            != currentRecord.materializedStateVersion
        {
            return ok(.object([
                "outcome": .string("dirty"),
                "record": currentRecord.publicValue,
            ]))
        }
        guard replacementDocumentID != documentID else {
            throw ServiceError.replacementDocumentIDCollision
        }

        let replacement = ArtifactStoredRecord(
            schemaVersion: 1,
            adoptedCheckpointHash: Self.sha256(checkpoint),
            checkpoint: checkpoint,
            checkpointStateVersion: 0,
            commits: [],
            documentID: replacementDocumentID,
            kind: currentRecord.kind,
            materializations: [],
            materializedStateVersion: 0,
            publicFileHash: currentHash,
            publicFilePath: path,
            stateVersion: 0,
            updates: []
        )
        guard persist(replacement) else {
            return failed(reason: "persistence")
        }
        return ok(.object([
            "applied": .bool(true),
            "outcome": .string("refreshed"),
            "record": replacement.publicValue,
        ]))
    }

    func materialize(
        _ request: ArtifactBaseRequest,
        documentID: String,
        expectedStateVersion: Int64,
        materializationID: String,
        publicFileBytes: Data,
        exactPublicFilePath: String?
    ) throws -> Value {
        if publicFileBytes.count > Self.maximumMaterializationBytes {
            return ok(.object([
                "maxBytes": .integer(
                    Int64(Self.maximumMaterializationBytes)
                ),
                "outcome": .string("too-large"),
            ]))
        }

        let path = try operationPath(
            request,
            exactPublicFilePath: exactPublicFilePath
        )
        let currentHash = try publicFileHash(path)
        let loaded = load(path)
        guard case var .record(record) = loaded else {
            if case .missing = loaded {
                throw ServiceError.documentDoesNotExist
            }
            return failed(reason: "corrupt")
        }
        guard currentHash == record.publicFileHash else {
            return conflict(
                actual: currentHash,
                expected: record.publicFileHash
            )
        }
        guard record.documentID == documentID else {
            throw ServiceError.documentIDMismatch
        }

        let intendedHash = Self.sha256(publicFileBytes)
        if let existing = record.materializations.first(
            where: { $0.materializationID == materializationID }
        ) {
            guard existing.publicFileHash == intendedHash,
                  existing.stateVersion == expectedStateVersion
            else {
                throw ServiceError.materializationIDCollision
            }
            return materialized(
                record: record,
                applied: false
            )
        }

        if record.stateVersion != expectedStateVersion
            || record.materializations.contains(
                where: {
                    $0.stateVersion == expectedStateVersion
                }
            )
        {
            return ok(.object([
                "outcome": .string("stale"),
                "stateVersion": .integer(record.stateVersion),
            ]))
        }
        if intendedHash != currentHash {
            do {
                try publicFileBytes.write(
                    to: URL(fileURLWithPath: path),
                    options: .atomic
                )
            } catch {
                return failed(reason: "persistence")
            }
            let committedHash: String
            do {
                committedHash = try publicFileHash(path)
            } catch {
                return failed(reason: "persistence")
            }
            guard committedHash == intendedHash else {
                return conflict(
                    actual: committedHash,
                    expected: intendedHash
                )
            }
        }

        record.materializations.append(
            ArtifactMaterialization(
                materializationID: materializationID,
                publicFileHash: intendedHash,
                stateVersion: expectedStateVersion
            )
        )
        record.materializedStateVersion = expectedStateVersion
        record.publicFileHash = intendedHash
        guard persist(record) else {
            return failed(reason: "persistence")
        }
        return materialized(record: record, applied: true)
    }

    func subscribe(
        _ request: ArtifactBaseRequest,
        documentID: String,
        callbackID: Int,
        handler: EventHandler?,
        exactPublicFilePath: String?
    ) throws -> Value {
        let path = try operationPath(
            request,
            exactPublicFilePath: exactPublicFilePath
        )
        _ = try publicFileHash(path)
        let loaded = load(path)
        guard case let .record(record) = loaded else {
            if case .missing = loaded {
                throw ServiceError.documentDoesNotExist
            }
            return failed(reason: "corrupt")
        }
        guard record.documentID == documentID else {
            throw ServiceError.documentIDMismatch
        }
        listenersByPath[path, default: [:]][callbackID] = Listener(
            callbackID: callbackID,
            handler: handler
        )
        return ok(.object([
            "record": record.publicValue,
            "subscription": .rpcObject([
                "unsubscribe": .rpcObject([:])
            ]),
        ]))
    }

    func unsubscribe(callbackID: Int) {
        for path in Array(listenersByPath.keys) {
            listenersByPath[path]?.removeValue(forKey: callbackID)
            if listenersByPath[path]?.isEmpty == true {
                listenersByPath.removeValue(forKey: path)
            }
        }
    }

    private func operationPath(
        _ request: ArtifactBaseRequest,
        exactPublicFilePath: String?
    ) throws -> String {
        if let exactPublicFilePath {
            let path = try canonicalArtifactFile(
                request.publicFilePath
            )
            guard path == exactPublicFilePath else {
                throw ServiceError.exactFileMismatch
            }
            return path
        }

        let root = URL(fileURLWithPath: request.workspaceRoot)
            .resolvingSymlinksInPath()
            .standardizedFileURL
        guard let rootValues = try? root.resourceValues(
            forKeys: [.isDirectoryKey]
        ),
            rootValues.isDirectory == true
        else {
            throw ServiceError.unauthorizedWorkspaceRoot
        }
        let authorizedRoots = allowedWorkspaceRoots.compactMap {
            candidate -> String? in
            let canonical = candidate
                .resolvingSymlinksInPath()
                .standardizedFileURL
            guard let values = try? canonical.resourceValues(
                forKeys: [.isDirectoryKey]
            ),
                values.isDirectory == true
            else {
                return nil
            }
            return canonical.path
        }
        guard authorizedRoots.contains(root.path) else {
            throw ServiceError.unauthorizedWorkspaceRoot
        }

        let path = try canonicalArtifactFile(request.publicFilePath)
        guard Self.isWithin(path: path, root: root.path) else {
            throw ServiceError.unauthorizedWorkspaceRoot
        }
        return path
    }

    private static func isWithin(path: String, root: String) -> Bool {
        path == root || path.hasPrefix(
            root.hasSuffix("/") ? root : root + "/"
        )
    }

    private func publicFileHash(_ path: String) throws -> String {
        do {
            return Self.sha256(try Data(
                contentsOf: URL(fileURLWithPath: path),
                options: .mappedIfSafe
            ))
        } catch {
            throw ServiceError.invalidArtifactPath
        }
    }

    private func load(_ path: String) -> LoadedRecord {
        if loadedPaths.contains(path) {
            if corruptPaths.contains(path) {
                return .corrupt
            }
            return records[path].map(LoadedRecord.record) ?? .missing
        }
        loadedPaths.insert(path)

        let url = recordURL(for: path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .missing
        }
        do {
            let record = try JSONDecoder().decode(
                ArtifactStoredRecord.self,
                from: Data(contentsOf: url)
            )
            guard record.schemaVersion == 1,
                  record.publicFilePath == path,
                  record.checkpointStateVersion >= 0,
                  record.materializedStateVersion >= 0,
                  record.materializedStateVersion <= record.stateVersion
            else {
                corruptPaths.insert(path)
                return .corrupt
            }
            records[path] = record
            return .record(record)
        } catch {
            corruptPaths.insert(path)
            return .corrupt
        }
    }

    private func persist(_ record: ArtifactStoredRecord) -> Bool {
        do {
            try FileManager.default.createDirectory(
                at: storeDirectory,
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(record).write(
                to: recordURL(for: record.publicFilePath),
                options: .atomic
            )
            loadedPaths.insert(record.publicFilePath)
            corruptPaths.remove(record.publicFilePath)
            records[record.publicFilePath] = record
            return true
        } catch {
            return false
        }
    }

    private func recordURL(for path: String) -> URL {
        storeDirectory.appendingPathComponent(
            "\(Self.sha256(Data(path.utf8))).json"
        )
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map {
            String(format: "%02x", $0)
        }.joined()
    }

    private func ok(_ value: Value) -> Value {
        .object([
            "status": .string("ok"),
            "value": value,
        ])
    }

    private func failed(reason: String) -> Value {
        .object([
            "reason": .string(reason),
            "status": .string("failed"),
        ])
    }

    private func conflict(actual: String, expected: String) -> Value {
        .object([
            "actualPublicFileHash": .string(actual),
            "expectedPublicFileHash": .string(expected),
            "status": .string("conflict"),
        ])
    }

    private func materialized(
        record: ArtifactStoredRecord,
        applied: Bool
    ) -> Value {
        ok(.object([
            "applied": .bool(applied),
            "materializedStateVersion": .integer(
                record.materializedStateVersion
            ),
            "outcome": .string("materialized"),
            "publicFileHash": .string(record.publicFileHash),
            "stateVersion": .integer(record.stateVersion),
        ]))
    }
}
