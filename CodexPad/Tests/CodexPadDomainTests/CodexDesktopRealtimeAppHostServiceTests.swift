import Foundation
import Testing

@testable import CodexPadApplication

private typealias RealtimeValue = CodexDesktopAppHostRPC.Value

private func realtimeLocator(
    hostID: String = "local",
    conversationID: String = "thread-1"
) -> RealtimeValue {
    .object([
        "hostId": .string(hostID),
        "conversationId": .string(conversationID),
    ])
}

@Test
func desktopRealtimeContinuityPersistsReleasedTrimAndLimitContract()
    async throws
{
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let service = CodexDesktopRealtimeAppHostService(codexHome: root)

    for text in [" first ", "second", "third"] {
        _ = try await service.invoke(
            service: "realtimeContinuity",
            method: "record",
            arguments: [
                .object([
                    "threadId": .string("thread-1"),
                    "item": .object([
                        "role": .string("user"),
                        "text": .string(text),
                    ]),
                    "maxItems": .integer(2),
                    "maxTextLength": .integer(5),
                ])
            ]
        )
    }

    let reloaded = CodexDesktopRealtimeAppHostService(
        codexHome: root
    )
    let result = try await reloaded.invoke(
        service: "realtimeContinuity",
        method: "read",
        arguments: [
            .object([
                "threadId": .string("thread-1"),
                "maxItems": .integer(10),
            ])
        ]
    )

    #expect(
        result
            == .array([
                .object([
                    "role": .string("user"),
                    "text": .string("secon"),
                ]),
                .object([
                    "role": .string("user"),
                    "text": .string("third"),
                ]),
            ])
    )
    #expect(
        FileManager.default.fileExists(
            atPath: root
                .appendingPathComponent(
                    "realtime-voice-continuity.json"
                )
                .path
        )
    )
}

@Test
func desktopRealtimeMemoryReadsRealCodexSummary() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
    let memories = root.appendingPathComponent("memories")
    try FileManager.default.createDirectory(
        at: memories,
        withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: root) }
    try Data("  current memory\n".utf8).write(
        to: memories.appendingPathComponent("memory_summary.md")
    )
    let service = CodexDesktopRealtimeAppHostService(codexHome: root)

    #expect(
        try await service.invoke(
            service: "realtimeMemory",
            method: "readSummary",
            arguments: []
        ) == .string("current memory")
    )
}

@Test
func desktopRealtimeVoiceClaimsPublishesControlsAndReleases()
    async throws
{
    let recorder = RealtimeEventRecorder()
    let service = CodexDesktopRealtimeAppHostService(
        codexHome: FileManager.default.temporaryDirectory,
        eventHandler: { service, method, arguments in
            await recorder.record(
                service: service,
                method: method,
                arguments: arguments
            )
        }
    )
    let locator = realtimeLocator()
    let claim = try await service.invoke(
        service: "realtimeVoice",
        method: "claim",
        arguments: [
            locator,
            .import(91),
            .string("main-thread"),
        ]
    )
    guard case let .string(claimID) = claim else {
        Issue.record("claim must return a claim id")
        return
    }

    _ = try await service.invoke(
        service: "realtimeVoice",
        method: "publish",
        arguments: [
            .string(claimID),
            .object([
                "activity": .string("speaking"),
                "microphoneMuted": .bool(false),
                "outputMuted": .bool(false),
                "phase": .string("active"),
            ]),
        ]
    )
    #expect(
        await service.voiceSnapshot()
            == .object([
                "activity": .string("speaking"),
                "locator": locator,
                "microphoneMuted": .bool(false),
                "outputMuted": .bool(false),
                "phase": .string("active"),
                "preferredPresentationSurface":
                    .string("main-thread"),
                "sessionId": .null,
            ])
    )
    #expect(
        try await service.invoke(
            service: "realtimeVoice",
            method: "controlActive",
            arguments: [
                .object(["type": .string("toggle-microphone-mute")])
            ]
        ) == .bool(true)
    )
    #expect(
        await recorder.contains(
            service: "realtimeVoice",
            method: "control"
        )
    )

    _ = try await service.invoke(
        service: "realtimeVoice",
        method: "release",
        arguments: [.string(claimID)]
    )
    #expect(
        await service.voiceSnapshot()
            == CodexDesktopRealtimeAppHostService.inactiveVoiceSnapshot
    )
}

@Test
func desktopRealtimeVoiceAcceptsReleasedTransferCancellationAndDictation()
    async throws
{
    let service = CodexDesktopRealtimeAppHostService(
        codexHome: FileManager.default.temporaryDirectory
    )
    let locator = realtimeLocator()
    #expect(
        try await service.invoke(
            service: "realtimeVoice",
            method: "cancelTransfer",
            arguments: [locator]
        ) == .undefined
    )
    #expect(
        try await service.invoke(
            service: "realtimeVoice",
            method: "setDictationActive",
            arguments: [.bool(true)]
        ) == .undefined
    )
}

@Test
func desktopRealtimeVoiceTransfersActiveCall() async throws {
    let recorder = RealtimeEventRecorder()
    let service = CodexDesktopRealtimeAppHostService(
        codexHome: FileManager.default.temporaryDirectory,
        eventHandler: { service, method, arguments in
            await recorder.record(
                service: service,
                method: method,
                arguments: arguments
            )
        }
    )
    let source = realtimeLocator()
    let destination = realtimeLocator(conversationID: "thread-2")
    let claim = try await service.invoke(
        service: "realtimeVoice",
        method: "claim",
        arguments: [source, .import(91), .string("main-thread")]
    )
    guard case let .string(claimID) = claim else {
        Issue.record("claim must return a claim id")
        return
    }
    _ = try await service.invoke(
        service: "realtimeVoice",
        method: "publish",
        arguments: [
            .string(claimID),
            .object([
                "activity": .string("listening"),
                "microphoneMuted": .bool(false),
                "outputMuted": .bool(false),
                "phase": .string("active"),
            ]),
        ]
    )

    #expect(
        try await service.invoke(
            service: "realtimeVoice",
            method: "transfer",
            arguments: [source, destination, .string("handoff")]
        ) == .bool(true)
    )
    #expect(
        await recorder.contains(
            service: "realtimeVoice",
            method: "transfer"
        )
    )
}

@Test
func desktopRealtimeMultiAgentDeduplicatesAndKeepsLatestHundred()
    async throws
{
    let service = CodexDesktopRealtimeAppHostService(
        codexHome: FileManager.default.temporaryDirectory
    )
    let locator = realtimeLocator()
    for index in 0..<105 {
        _ = try await service.invoke(
            service: "realtimeVoiceMultiAgentActivity",
            method: "publish",
            arguments: [
                .object([
                    "id": .string("activity-\(index)"),
                    "realtimeThread": locator,
                    "text": .string("event \(index)"),
                ])
            ]
        )
    }
    _ = try await service.invoke(
        service: "realtimeVoiceMultiAgentActivity",
        method: "publish",
        arguments: [
            .object([
                "id": .string("activity-104"),
                "realtimeThread": locator,
                "text": .string("duplicate"),
            ])
        ]
    )

    let activities = await service.activities(for: locator)
    #expect(activities.count == 100)
    #expect(
        activities.first
            == .object([
                "id": .string("activity-104"),
                "realtimeThread": locator,
                "text": .string("event 104"),
            ])
    )
    #expect(
        activities.last
            == .object([
                "id": .string("activity-5"),
                "realtimeThread": locator,
                "text": .string("event 5"),
            ])
    )
}

@Test
func desktopRealtimePresentationAndRuntimeForwardReleasedOperations()
    async throws
{
    let recorder = RealtimeEventRecorder()
    let service = CodexDesktopRealtimeAppHostService(
        codexHome: FileManager.default.temporaryDirectory,
        eventHandler: { service, method, arguments in
            await recorder.record(
                service: service,
                method: method,
                arguments: arguments
            )
        }
    )
    let locator = realtimeLocator()

    #expect(
        try await service.invoke(
            service: "realtimeVoicePresentation",
            method: "reportToast",
            arguments: [
                locator,
                .object(["message": .string("ready")]),
            ]
        ) == .bool(false)
    )
    _ = try await service.invoke(
        service: "realtimeVoicePresentation",
        method: "requestSurface",
        arguments: [
            locator,
            .string("global-overlay"),
            .null,
        ]
    )
    _ = try await service.invoke(
        service: "realtimeVoiceRuntime",
        method: "requestRealtimeStart",
        arguments: [
            .object(["source": .string("composer_button_existing_thread")]),
            .string("launch-test"),
        ]
    )
    _ = try await service.invoke(
        service: "realtimeVoiceRuntime",
        method: "cancelRealtimeSessionStart",
        arguments: []
    )

    #expect(
        await recorder.contains(
            service: "realtimeVoicePresentation",
            method: "requestSurface"
        )
    )
    #expect(
        await recorder.contains(
            service: "realtimeVoiceRuntime",
            method: "requestRealtimeStart"
        )
    )
    #expect(
        await recorder.contains(
            service: "realtimeVoiceRuntime",
            method: "cancelRealtimeSessionStart"
        )
    )
}

@Test
func desktopRealtimeRuntimeInvokesRegisteredStarterCallbacks()
    async throws
{
    let recorder = RealtimeCallbackRecorder()
    let service = CodexDesktopRealtimeAppHostService(
        codexHome: FileManager.default.temporaryDirectory,
        callbackInvoker: { callbackID, arguments in
            await recorder.record(
                callbackID: callbackID,
                arguments: arguments
            )
        }
    )
    let requestCallbackID = 17
    let cancelCallbackID = 23

    _ = try await service.invoke(
        service: "realtimeVoiceRuntime",
        method: "registerRealtimeStarter",
        arguments: [
            .import(requestCallbackID),
            .import(cancelCallbackID),
            .bool(true),
        ]
    )
    _ = try await service.invoke(
        service: "realtimeVoiceRuntime",
        method: "requestRealtimeStart",
        arguments: [
            .object(["source": .string("test")]),
            .string("launch-1"),
        ]
    )
    _ = try await service.invoke(
        service: "realtimeVoiceRuntime",
        method: "cancelRealtimeSessionStart",
        arguments: []
    )

    #expect(
        await recorder.calls() == [
            .init(
                callbackID: requestCallbackID,
                arguments: [
                    .object(["source": .string("test")]),
                ]
            ),
            .init(callbackID: cancelCallbackID, arguments: []),
        ]
    )

    _ = try await service.invoke(
        service: "realtimeVoiceRuntime",
        method: "unregisterRealtimeStarter",
        arguments: []
    )
    _ = try await service.invoke(
        service: "realtimeVoiceRuntime",
        method: "requestRealtimeStart",
        arguments: [.object(["source": .string("after-unregister")])]
    )
    #expect(await recorder.calls().count == 2)
}

@Test
func desktopRealtimeRuntimeRejectsInvalidStarterRegistration()
    async throws
{
    let service = CodexDesktopRealtimeAppHostService(
        codexHome: FileManager.default.temporaryDirectory
    )

    await #expect(throws: CodexDesktopRealtimeAppHostService.Error.invalidArguments) {
        _ = try await service.invoke(
            service: "realtimeVoiceRuntime",
            method: "registerRealtimeStarter",
            arguments: [.string("not-an-import"), .import(2), .bool(true)]
        )
    }
}

private actor RealtimeEventRecorder {
    struct Event: Sendable {
        let service: String
        let method: String
        let arguments: [RealtimeValue]?
    }

    private var events: [Event] = []

    func record(
        service: String,
        method: String,
        arguments: [RealtimeValue]?
    ) {
        events.append(
            Event(
                service: service,
                method: method,
                arguments: arguments
            )
        )
    }

    func contains(service: String, method: String) -> Bool {
        events.contains {
            $0.service == service && $0.method == method
        }
    }
}

private actor RealtimeCallbackRecorder {
    struct Call: Equatable, Sendable {
        let callbackID: Int
        let arguments: [RealtimeValue]
    }

    private var recorded: [Call] = []

    func record(callbackID: Int, arguments: [RealtimeValue]) {
        recorded.append(Call(callbackID: callbackID, arguments: arguments))
    }

    func calls() -> [Call] {
        recorded
    }
}
