import CryptoKit
import Foundation
import Testing

@testable import CodexPadApplication

private typealias HistoryMediaValue = CodexDesktopAppHostRPC.Value
private typealias HistoryMediaService =
    CodexDesktopHistoryMediaAppHostService

@Test
func desktopDictationHistoryPersistsChunksAndRecoversRecording()
    async throws
{
    let fixture = try HistoryMediaFixture()
    defer { fixture.remove() }
    let changes = HistoryMediaChangeRecorder()
    let service = HistoryMediaService(
        dictationDirectory: fixture.dictationDirectory,
        downloadsDirectory: { fixture.downloadsDirectory },
        onDictationChanged: { await changes.record() }
    )

    let append: HistoryMediaValue = .object([
        "chunk": .array([.integer(1), .integer(2), .integer(3)]),
        "createdAtMs": .integer(1_700_000_000_000),
        "id": .string("recording-1"),
        "mimeType": .string("audio/webm;codecs=opus"),
        "sequence": .integer(4),
        "surface": .string("composer"),
    ])
    #expect(
        try await service.invoke(
            service: "dictationHistory",
            method: "appendChunk",
            arguments: [append]
        ) == .undefined
    )
    _ = try await service.invoke(
        service: "dictationHistory",
        method: "appendChunk",
        arguments: [append]
    )

    let hash = SHA256.hash(data: Data("recording-1".utf8))
        .map { String(format: "%02x", $0) }
        .joined()
    let recordingDirectory = fixture.dictationDirectory
        .appendingPathComponent(hash, isDirectory: true)
    #expect(
        try Data(
            contentsOf: recordingDirectory
                .appendingPathComponent("0000000004.chunk")
        ) == Data([1, 2, 3])
    )
    #expect(await changes.count == 2)

    let reloaded = HistoryMediaService(
        dictationDirectory: fixture.dictationDirectory,
        downloadsDirectory: { fixture.downloadsDirectory }
    )
    let listed = try await reloaded.invoke(
        service: "dictationHistory",
        method: "list",
        arguments: []
    )
    #expect(
        listed == .object([
            "items": .array([
                .object([
                    "createdAtMs": .integer(1_700_000_000_000),
                    "id": .string("recording-1"),
                    "mimeType": .string("audio/webm;codecs=opus"),
                    "sizeBytes": .integer(3),
                    "status": .string("interrupted"),
                    "surface": .string("composer"),
                    "text": .string(""),
                ]),
            ])
        ])
    )
}

@Test
func desktopDictationHistoryFinalizesTranscribesDownloadsAndDeletes()
    async throws
{
    let fixture = try HistoryMediaFixture()
    defer { fixture.remove() }
    let service = HistoryMediaService(
        dictationDirectory: fixture.dictationDirectory,
        downloadsDirectory: { fixture.downloadsDirectory }
    )

    for (sequence, bytes) in [(1, [3, 4]), (0, [1, 2])] {
        _ = try await service.invoke(
            service: "dictationHistory",
            method: "appendChunk",
            arguments: [
                .object([
                    "chunk": .array(bytes.map {
                        .integer(Int64($0))
                    }),
                    "createdAtMs": .integer(1_700_000_000_000),
                    "id": .string("recording-2"),
                    "mimeType": .string("audio/mp4; codecs=aac"),
                    "sequence": .integer(Int64(sequence)),
                    "surface": .string("global"),
                ])
            ]
        )
    }
    _ = try await service.invoke(
        service: "dictationHistory",
        method: "setTranscript",
        arguments: [
            .object([
                "id": .string("recording-2"),
                "text": .string("  hello voice \n"),
            ])
        ]
    )
    _ = try await service.invoke(
        service: "dictationHistory",
        method: "finalize",
        arguments: [
            .object([
                "cancelled": .bool(false),
                "durationMs": .integer(950),
                "id": .string("recording-2"),
            ])
        ]
    )

    #expect(
        try await service.invoke(
            service: "dictationHistory",
            method: "readAudio",
            arguments: [.object(["id": .string("recording-2")])]
        ) == .object([
            "audio": .array([
                .integer(1), .integer(2), .integer(3), .integer(4),
            ]),
            "mimeType": .string("audio/mp4; codecs=aac"),
        ])
    )

    let expectedName =
        "Codex dictation 2023-11-14T22-13-20.000Z.m4a"
    try Data([9]).write(
        to: fixture.downloadsDirectory
            .appendingPathComponent(expectedName)
    )
    #expect(
        try await service.invoke(
            service: "dictationHistory",
            method: "download",
            arguments: [.object(["id": .string("recording-2")])]
        ) == .undefined
    )
    #expect(
        try Data(
            contentsOf: fixture.downloadsDirectory.appendingPathComponent(
                "Codex dictation 2023-11-14T22-13-20.000Z (1).m4a"
            )
        ) == Data([1, 2, 3, 4])
    )

    let listed = try await service.invoke(
        service: "dictationHistory",
        method: "list",
        arguments: nil
    )
    #expect(
        listed.historyObjectFields?["items"]?
            .historyArrayValues?.first?
            .historyObjectFields?["durationMs"]
            == HistoryMediaValue.integer(950)
    )
    #expect(
        listed.historyObjectFields?["items"]?
            .historyArrayValues?.first?
            .historyObjectFields?["text"]
            == HistoryMediaValue.string("hello voice")
    )
    _ = try await service.invoke(
        service: "dictationHistory",
        method: "delete",
        arguments: [.object(["id": .string("recording-2")])]
    )
    #expect(
        try await service.invoke(
            service: "dictationHistory",
            method: "list",
            arguments: []
        ) == .object(["items": .array([])])
    )
}

@Test
func desktopDictationHistoryRejectsActiveDeleteAndMissingAudioDownload()
    async throws
{
    let fixture = try HistoryMediaFixture()
    defer { fixture.remove() }
    let service = HistoryMediaService(
        dictationDirectory: fixture.dictationDirectory,
        downloadsDirectory: { fixture.downloadsDirectory }
    )
    _ = try await service.invoke(
        service: "dictationHistory",
        method: "appendChunk",
        arguments: [
            .object([
                "chunk": .array([.integer(7)]),
                "createdAtMs": .number(2),
                "id": .string("active"),
                "mimeType": .string("audio/ogg"),
                "sequence": .number(0),
                "surface": .string("composer"),
            ])
        ]
    )

    await #expect(
        throws: HistoryMediaService.Error
            .cannotDeleteActiveRecording
    ) {
        _ = try await service.invoke(
            service: "dictationHistory",
            method: "delete",
            arguments: [.object(["id": .string("active")])]
        )
    }
    await #expect(
        throws: HistoryMediaService.Error.recordingNotFound
    ) {
        _ = try await service.invoke(
            service: "dictationHistory",
            method: "download",
            arguments: [.object(["id": .string("missing")])]
        )
    }
}

@Test
func desktopRealtimeVoiceHistoryImmediatelyPushesRealSnapshotAndFilters()
    async throws
{
    let runtime = HistoryMediaRealtimeRuntime()
    let callbacks = HistoryMediaCallbackRecorder()
    let locator = HistoryMediaService.RealtimeLocator(
        hostID: "local",
        conversationID: "thread-1"
    )
    await runtime.setSnapshot(
        .object([
            "entries": .array([
                .object([
                    "type": .string("item"),
                    "completed": .bool(true),
                    "id": .string("segment-1"),
                    "role": .string("user"),
                    "text": .string("real persisted text"),
                ])
            ]),
            "isLoaded": .bool(true),
            "records": .array([]),
        ]),
        for: locator
    )
    let service = HistoryMediaService(
        dictationDirectory: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString),
        realtimeSnapshotProvider: { locator in
            try await runtime.snapshot(for: locator)
        },
        realtimeRuntimeSubscribe: { receive in
            await runtime.subscribe(receive)
        },
        subscriptionEventHandler: { callbackID, snapshot in
            await callbacks.record(callbackID, snapshot)
        }
    )

    #expect(
        try await service.invoke(
            service: "realtimeVoiceHistory",
            method: "subscribe",
            arguments: [
                .object([
                    "hostId": .string("local"),
                    "conversationId": .string("thread-1"),
                ]),
                .import(41),
            ]
        ) == .rpcObject([
            "unsubscribe": .rpcObject([:])
        ])
    )
    #expect(
        await callbacks.values(for: 41)
            == [try await runtime.snapshot(for: locator)]
    )

    await runtime.emit(
        .object(["entries": .array([]), "isLoaded": .bool(true)]),
        for: .init(hostID: "other", conversationID: "thread-1")
    )
    let matching = HistoryMediaValue.object([
        "entries": .array([]),
        "isLoaded": .bool(true),
        "records": .array([
            .object(["eventId": .string("event-2")])
        ]),
    ])
    await runtime.emit(matching, for: locator)
    #expect(
        await callbacks.values(for: 41).last == matching
    )
    #expect(await callbacks.values(for: 41).count == 2)

    await service.unsubscribe(callbackID: 41)
    await runtime.emit(
        .object(["entries": .array([]), "isLoaded": .bool(false)]),
        for: locator
    )
    #expect(await callbacks.values(for: 41).count == 2)
}

@Test
func desktopHistoryMediaValidatesReleasedArguments() async throws {
    let fixture = try HistoryMediaFixture()
    defer { fixture.remove() }
    let service = HistoryMediaService(
        dictationDirectory: fixture.dictationDirectory
    )

    await #expect(throws: HistoryMediaService.Error.invalidArguments) {
        _ = try await service.invoke(
            service: "dictationHistory",
            method: "appendChunk",
            arguments: [
                .object([
                    "chunk": .array([.integer(256)]),
                    "createdAtMs": .integer(1),
                    "id": .string("bad"),
                    "mimeType": .string("audio/webm"),
                    "sequence": .integer(0),
                    "surface": .string("composer"),
                ])
            ]
        )
    }
    await #expect(
        throws: HistoryMediaService.Error.unsupportedMethod(
            service: "dictationHistory",
            method: "unknown"
        )
    ) {
        _ = try await service.invoke(
            service: "dictationHistory",
            method: "unknown",
            arguments: []
        )
    }
}

private struct HistoryMediaFixture {
    let root: URL
    let dictationDirectory: URL
    let downloadsDirectory: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        dictationDirectory = root
            .appendingPathComponent("dictation-history", isDirectory: true)
        downloadsDirectory = root
            .appendingPathComponent("Downloads", isDirectory: true)
        try FileManager.default.createDirectory(
            at: downloadsDirectory,
            withIntermediateDirectories: true
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

private actor HistoryMediaChangeRecorder {
    private(set) var count = 0

    func record() {
        count += 1
    }
}

private actor HistoryMediaCallbackRecorder {
    private var snapshots: [Int: [HistoryMediaValue]] = [:]

    func record(_ callbackID: Int, _ snapshot: HistoryMediaValue) {
        snapshots[callbackID, default: []].append(snapshot)
    }

    func values(for callbackID: Int) -> [HistoryMediaValue] {
        snapshots[callbackID] ?? []
    }
}

private actor HistoryMediaRealtimeRuntime {
    typealias Locator = HistoryMediaService.RealtimeLocator
    typealias Update = HistoryMediaService.RealtimeUpdateHandler

    private var snapshots: [Locator: HistoryMediaValue] = [:]
    private var updates: [UUID: Update] = [:]

    func setSnapshot(
        _ snapshot: HistoryMediaValue,
        for locator: Locator
    ) {
        snapshots[locator] = snapshot
    }

    func snapshot(for locator: Locator) throws -> HistoryMediaValue {
        guard let snapshot = snapshots[locator] else {
            throw HistoryMediaService.Error.realtimeHistoryUnavailable
        }
        return snapshot
    }

    func subscribe(
        _ receive: @escaping Update
    ) -> HistoryMediaService.RealtimeUnsubscribe {
        let id = UUID()
        updates[id] = receive
        return { await self.remove(id) }
    }

    func emit(_ snapshot: HistoryMediaValue, for locator: Locator)
        async
    {
        snapshots[locator] = snapshot
        for receive in updates.values {
            await receive(locator, snapshot)
        }
    }

    private func remove(_ id: UUID) {
        updates.removeValue(forKey: id)
    }
}

private extension CodexDesktopAppHostRPC.Value {
    var historyObjectFields: [String: Self]? {
        guard case let .object(fields) = self else {
            return nil
        }
        return fields
    }

    var historyArrayValues: [Self]? {
        guard case let .array(values) = self else {
            return nil
        }
        return values
    }
}
