import Foundation
import Testing

@testable import CodexPadApplication

private typealias OptionalPlatformValue =
    CodexDesktopAppHostRPC.Value

@Test
func desktopOptionalPlatformAcceptsReleasedAvatarInputShape() async throws {
    actor CapturedRegions {
        var value: [CodexDesktopAvatarOverlayInputRegion] = []
        func set(_ regions: [CodexDesktopAvatarOverlayInputRegion]) {
            value = regions
        }
    }

    let captured = CapturedRegions()
    let service = CodexDesktopOptionalPlatformAppHostService(
        avatarInputShapeHandler: { regions in
            await captured.set(regions)
        }
    )
    let shape: OptionalPlatformValue = .array([
        .object([
            "left": .number(12),
            "top": .number(18),
            "width": .number(112),
            "height": .number(112),
        ]),
    ])

    #expect(
        try await service.invoke(
            service: "avatarOverlay",
            method: "setInputShape",
            arguments: [shape]
        ) == .undefined
    )
    #expect(await service.avatarInputShape == shape)
    #expect(await captured.value == [
        .init(left: 12, top: 18, width: 112, height: 112)
    ])
}

@Test
func desktopOptionalPlatformForwardsChronicleOperations() async throws {
    let recorder = OptionalPlatformRecorder()
    let service = CodexDesktopOptionalPlatformAppHostService(
        chronicleOperation: { method, arguments in
            await recorder.record(
                service: "chronicle",
                method: method,
                arguments: arguments
            )
            switch method {
            case "getState":
                return .object([
                    "enabled": .bool(true),
                    "recorderState": .string("recording"),
                    "activationState": .string("idle"),
                ])
            case "listHistory":
                return .array([
                    .object(["id": .string("history-1")]),
                ])
            default:
                return .undefined
            }
        }
    )

    #expect(
        try await service.invoke(
            service: "chronicle",
            method: "getState",
            arguments: []
        ) == .object([
            "enabled": .bool(true),
            "recorderState": .string("recording"),
            "activationState": .string("idle"),
        ])
    )
    #expect(
        try await service.invoke(
            service: "chronicle",
            method: "listHistory",
            arguments: []
        ) == .array([
            .object(["id": .string("history-1")]),
        ])
    )
    _ = try await service.invoke(
        service: "chronicle",
        method: "updateSettings",
        arguments: [
            .object(["captureAudio": .bool(false)]),
        ]
    )
    #expect(
        await recorder.contains(
            service: "chronicle",
            method: "updateSettings"
        )
    )
}

@Test
func desktopOptionalPlatformForwardsReleasedChronicleHistoryQueries()
    async throws
{
    let recorder = OptionalPlatformRecorder()
    let service = CodexDesktopOptionalPlatformAppHostService(
        chronicleOperation: { method, arguments in
            await recorder.record(
                service: "chronicle",
                method: method,
                arguments: arguments
            )
            switch method {
            case "listHistorySuggestions":
                return .array([
                    .object([
                        "id": .string("suggestion-1"),
                        "query": .string("Continue the release review"),
                    ]),
                ])
            case "listHistorySummaryIntervals":
                return .array([
                    .object([
                        "startMs": .integer(1_000),
                        "endMs": .integer(2_000),
                    ]),
                ])
            default:
                return .undefined
            }
        }
    )

    #expect(
        try await service.invoke(
            service: "chronicle",
            method: "listHistorySuggestions",
            arguments: []
        ) == .array([
            .object([
                "id": .string("suggestion-1"),
                "query": .string("Continue the release review"),
            ]),
        ])
    )

    let summaryArguments: [OptionalPlatformValue] = [
        .object(["sinceMs": .integer(1_000)]),
    ]
    #expect(
        try await service.invoke(
            service: "chronicle",
            method: "listHistorySummaryIntervals",
            arguments: summaryArguments
        ) == .array([
            .object([
                "startMs": .integer(1_000),
                "endMs": .integer(2_000),
            ]),
        ])
    )
    #expect(
        await recorder.contains(
            service: "chronicle",
            method: "listHistorySuggestions"
        )
    )
    #expect(
        await recorder.contains(
            service: "chronicle",
            method: "listHistorySummaryIntervals"
        )
    )
}

@Test
func desktopOptionalPlatformValidatesChronicleSummaryIntervalArguments()
    async throws
{
    let service = CodexDesktopOptionalPlatformAppHostService(
        chronicleOperation: { _, _ in .array([]) }
    )

    await #expect(
        throws: CodexDesktopOptionalPlatformAppHostService.Error
            .invalidArguments
    ) {
        _ = try await service.invoke(
            service: "chronicle",
            method: "listHistorySummaryIntervals",
            arguments: []
        )
    }
    await #expect(
        throws: CodexDesktopOptionalPlatformAppHostService.Error
            .invalidArguments
    ) {
        _ = try await service.invoke(
            service: "chronicle",
            method: "listHistorySummaryIntervals",
            arguments: [
                .object(["sinceMs": .string("yesterday")]),
            ]
        )
    }
}

@Test
func desktopOptionalPlatformReturnsSchemaValidEmptyChronicleHistoryQueries()
    async throws
{
    let service = CodexDesktopOptionalPlatformAppHostService()

    #expect(
        try await service.invoke(
            service: "chronicle",
            method: "listHistorySuggestions",
            arguments: []
        ) == .array([])
    )
    #expect(
        try await service.invoke(
            service: "chronicle",
            method: "listHistorySummaryIntervals",
            arguments: [
                .object(["sinceMs": .integer(1_000)]),
            ]
        ) == .array([])
    )
}

@Test
func desktopOptionalPlatformMaintainsReleasedCodexMicroShape()
    async throws
{
    let recorder = OptionalPlatformRecorder()
    let service = CodexDesktopOptionalPlatformAppHostService(
        codexMicroOperation: { method, arguments in
            await recorder.record(
                service: "codexMicro",
                method: method,
                arguments: arguments
            )
            switch method {
            case "getInputMonitoringPermissionStatus":
                return .string("unavailable")
            case "ownsPrimaryWindow":
                return .bool(true)
            case "updateAgentThreadKeys", "updateLighting":
                return .bool(true)
            default:
                return .undefined
            }
        }
    )

    #expect(
        try await service.invoke(
            service: "codexMicro",
            method: "getState",
            arguments: []
        ) == CodexDesktopOptionalPlatformAppHostService
            .notDetectedCodexMicroState
    )
    #expect(
        try await service.invoke(
            service: "codexMicro",
            method: "getInputMonitoringPermissionStatus",
            arguments: []
        ) == .string("unavailable")
    )
    #expect(
        try await service.invoke(
            service: "codexMicro",
            method: "updateAgentThreadKeys",
            arguments: [
                .array([.string("thread-1")]),
                .array([.integer(0)]),
                .bool(true),
            ]
        ) == .bool(true)
    )
    #expect(
        await recorder.contains(
            service: "codexMicro",
            method: "updateAgentThreadKeys"
        )
    )
}

@Test
func desktopOptionalPlatformRoutesSupportedDebugOperations()
    async throws
{
    let recorder = OptionalPlatformRecorder()
    let service = CodexDesktopOptionalPlatformAppHostService(
        debugOperation: { method, arguments in
            await recorder.record(
                service: "debug",
                method: method,
                arguments: arguments
            )
            switch method {
            case "getBrowserSnapshot":
                return .object([
                    "tabs": .array([]),
                    "windows": .array([]),
                ])
            default:
                return .undefined
            }
        }
    )

    #expect(
        try await service.invoke(
            service: "debug",
            method: "getBrowserSnapshot",
            arguments: []
        ) == .object([
            "tabs": .array([]),
            "windows": .array([]),
        ])
    )
    _ = try await service.invoke(
        service: "debug",
        method: "exportLogs",
        arguments: [
            .object(["scope": .string("current-session")]),
        ]
    )
    #expect(
        await recorder.contains(
            service: "debug",
            method: "exportLogs"
        )
    )
}

@Test
func desktopOptionalPlatformRejectsUnavailableMemoryDiagnostics()
    async throws
{
    let service = CodexDesktopOptionalPlatformAppHostService()

    await #expect(throws: CodexDesktopOptionalPlatformAppHostService.Error.self) {
        _ = try await service.invoke(
            service: "debug",
            method: "captureMemoryHeapSnapshots",
            arguments: []
        )
    }
}

@Test
func desktopOptionalPlatformExposesNoCrashEventsOnIPad() async throws {
    let service = CodexDesktopOptionalPlatformAppHostService()

    #expect(
        try await service.invoke(
            service: "owlBrowserCrashCounter",
            method: "subscribe",
            arguments: [.rpcObject([:])]
        ) == .undefined
    )
    #expect(
        try await service.invoke(
            service: "owlBrowserCrashCounter",
            method: "unsubscribe",
            arguments: []
        ) == .undefined
    )
}

@Test
func desktopOptionalPlatformMaintainsRemoteHostedPIPTaskState()
    async throws
{
    let service = CodexDesktopOptionalPlatformAppHostService()

    #expect(
        try await service.invoke(
            service: "remoteHostedPIP",
            method: "showTask",
            arguments: [.string("thread-1")]
        ) == .object([
            "activeTaskIds": .array([]),
            "globalHidden": .bool(false),
            "revision": .integer(1),
            "taskVisibilities": .object([
                "thread-1": .string("shown")
            ]),
        ])
    )
    #expect(
        try await service.invoke(
            service: "remoteHostedPIP",
            method: "hideTask",
            arguments: [.string("thread-1")]
        ) == .object([
            "activeTaskIds": .array([]),
            "globalHidden": .bool(false),
            "revision": .integer(2),
            "taskVisibilities": .object([
                "thread-1": .string("hidden")
            ]),
        ])
    )
    #expect(
        try await service.invoke(
            service: "remoteHostedPIP",
            method: "hideForAllActiveTasks",
            arguments: []
        ) == .object([
            "activeTaskIds": .array([]),
            "globalHidden": .bool(true),
            "revision": .integer(3),
            "taskVisibilities": .object([
                "thread-1": .string("hidden")
            ]),
        ])
    )
}

private actor OptionalPlatformRecorder {
    struct Event: Sendable {
        let service: String
        let method: String
        let arguments: [OptionalPlatformValue]?
    }

    private var events: [Event] = []

    func record(
        service: String,
        method: String,
        arguments: [OptionalPlatformValue]?
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
