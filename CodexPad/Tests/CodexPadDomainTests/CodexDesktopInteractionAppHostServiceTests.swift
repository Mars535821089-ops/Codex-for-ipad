import Foundation
import Testing

@testable import CodexPadApplication

@Test
func desktopInteractionAppHostClaimsEachDynamicCallOnlyOnce()
    async throws
{
    let service = CodexDesktopInteractionAppHostService()
    let arguments: [CodexDesktopAppHostRPC.Value] = [
        .object([
            "callId": .string("call-1"),
            "hostId": .string("local"),
            "threadId": .string("thread-1"),
            "turnId": .string("turn-1"),
        ])
    ]

    #expect(
        try await service.invoke(
            service: "dynamicToolCalls",
            method: "tryClaimExecution",
            arguments: arguments
        ) == .bool(true)
    )
    #expect(
        try await service.invoke(
            service: "dynamicToolCalls",
            method: "tryClaimExecution",
            arguments: arguments
        ) == .bool(false)
    )
}

@Test
func desktopInteractionAppHostReturnsReleasedApplicationMenuSnapshotShape()
    async throws
{
    let service = CodexDesktopInteractionAppHostService(
        applicationMenuSnapshot: .object([
            "file": .array([]),
            "edit": .array([]),
            "view": .array([]),
            "help": .array([]),
        ])
    )

    #expect(
        try await service.invoke(
            service: "applicationMenu",
            method: "getSnapshot",
            arguments: nil
        ) == .object([
            "file": .array([]),
            "edit": .array([]),
            "view": .array([]),
            "help": .array([]),
        ])
    )
}

@Test
func desktopInteractionAppHostMaintainsHotkeyAndQuickChatState()
    async throws
{
    let service = CodexDesktopInteractionAppHostService()

    #expect(
        try await service.invoke(
            service: "hotkeyWindowHotkeys",
            method: "getState",
            arguments: nil
        ) == .object([
            "supported": .bool(false),
            "configuredHotkey": .null,
            "isGateEnabled": .bool(false),
            "isDevMode": .bool(false),
            "isDevOverrideEnabled": .bool(false),
            "isActive": .bool(false),
        ])
    )

    #expect(
        try await service.invoke(
            service: "hotkeyWindowHotkeys",
            method: "setEnabled",
            arguments: [.bool(true)]
        ) == .undefined
    )
    #expect(
        try await service.invoke(
            service: "hotkeyWindowHotkeys",
            method: "open",
            arguments: [.object(["path": .string("/thread/1")])]
        ) == .undefined
    )
    #expect(
        try await service.invoke(
            service: "quickChatWindow",
            method: "prewarm",
            arguments: nil
        ) == .undefined
    )
    #expect(await service.hotkeyWindowEnabled)
    #expect(await service.hotkeyWindowPath == "/thread/1")
    #expect(await service.quickChatPrewarmed)

    _ = try await service.invoke(
        service: "hotkeyWindowHotkeys",
        method: "dismiss",
        arguments: nil
    )
    _ = try await service.invoke(
        service: "quickChatWindow",
        method: "clearPrewarm",
        arguments: nil
    )
    #expect(await service.hotkeyWindowPath == nil)
    #expect(await !service.quickChatPrewarmed)
}

@Test
func desktopInteractionAppHostSupportsReleasedHotkeyWindowCommands() async throws {
    let service = CodexDesktopInteractionAppHostService()

    #expect(
        try await service.invoke(
            service: "hotkeyWindowHotkeys",
            method: "toggle",
            arguments: nil
        ) == .undefined
    )
    #expect(
        try await service.invoke(
            service: "hotkeyWindowHotkeys",
            method: "setHotkey",
            arguments: [.string("CommandOrControl+Space")]
        ) == .undefined
    )
    #expect(
        try await service.invoke(
            service: "hotkeyWindowHotkeys",
            method: "setDevOverrideEnabled",
            arguments: [.bool(true)]
        ) == .undefined
    )
    #expect(
        try await service.invoke(
            service: "hotkeyWindowHotkeys",
            method: "getState",
            arguments: nil
        ) == .object([
            "supported": .bool(false),
            "configuredHotkey": .string("CommandOrControl+Space"),
            "isGateEnabled": .bool(false),
            "isDevMode": .bool(false),
            "isDevOverrideEnabled": .bool(true),
            "isActive": .bool(false),
        ])
    )
}

@Test
func desktopInteractionAppHostAcceptsReleasedHomeDragLifecycle()
    async throws
{
    let service = CodexDesktopInteractionAppHostService()
    for method in ["homeDragStart", "homeDragMove", "homeDragEnd"] {
        #expect(
            try await service.invoke(
                service: "hotkeyWindowHotkeys",
                method: method,
                arguments: [.object(["x": .number(1), "y": .number(2)])]
            ) == .undefined
        )
    }
}

@Test
func desktopInteractionAppHostReportsEmbeddedPrimaryRuntime()
    async throws
{
    let service = CodexDesktopInteractionAppHostService(
        primaryRuntimeVersion: "26.730.61309",
        primaryRuntimeInstalled: true
    )

    #expect(
        try await service.invoke(
            service: "primaryRuntime",
            method: "getInstalledBundleVersion",
            arguments: nil
        ) == .string("26.730.61309")
    )
    #expect(
        try await service.invoke(
            service: "primaryRuntime",
            method: "diagnoseDependencies",
            arguments: [
                .object(["hostId": .string("local")])
            ]
        ) == .object([
            "artifactToolVersion": .null,
            "bundleVersion": .string("26.730.61309"),
            "installed": .bool(true),
            "libreOfficeVersion": .null,
            "problems": .array([]),
        ])
    )
}

@Test
func desktopInteractionAppHostFinishesAgainstEmbeddedPrimaryRuntime()
    async throws
{
    let service = CodexDesktopInteractionAppHostService(
        primaryRuntimeVersion: "26.810.50856",
        primaryRuntimeInstalled: true
    )

    #expect(
        try await service.invoke(
            service: "primaryRuntime",
            method: "finishInstall",
            arguments: [
                .object([
                    "hostId": .string("local"),
                    "release": .string("latest"),
                ])
            ]
        ) == .object([
            "bundleVersion": .string("26.810.50856"),
            "status": .string("already-current"),
        ])
    )
}

@Test
func desktopInteractionAppHostRoutesPlatformSpecificNoOpCalls()
    async throws
{
    let service = CodexDesktopInteractionAppHostService()
    let calls: [(String, String, [CodexDesktopAppHostRPC.Value]?)] = [
        ("applicationMenu", "invokeItem", [.integer(7)]),
        ("fileDrags", "prepareDrag", [
            .object([
                "hostId": .string("local"),
                "path": .string("/workspace/file.txt"),
            ])
        ]),
        ("keyboardModifiers", "watchMetaRelease", nil),
        ("hotkeyWindowHotkeys", "collapseToHome", nil),
        ("hotkeyWindowHotkeys", "transitionDone", [
            .object([
                "transitionId": .string("transition-1"),
                "step": .string("raised"),
            ])
        ]),
    ]

    for (serviceName, method, arguments) in calls {
        #expect(
            try await service.invoke(
                service: serviceName,
                method: method,
                arguments: arguments
            ) == .undefined
        )
    }
}

@Test
func desktopInteractionAppHostAcceptsReleasedQuickChatComposerAndRendererReadyPayloads()
    async throws
{
    actor Events {
        var values: [(String, String, [CodexDesktopAppHostRPC.Value]?)] = []
        func append(_ value: (String, String, [CodexDesktopAppHostRPC.Value]?)) {
            values.append(value)
        }
        func snapshot() -> [(String, String, [CodexDesktopAppHostRPC.Value]?)] {
            values
        }
    }
    let events = Events()
    let service = CodexDesktopInteractionAppHostService(
        eventHandler: { service, method, arguments in
            await events.append((service, method, arguments))
        }
    )

    #expect(
        try await service.invoke(
            service: "quickChatWindow",
            method: "addToComposer",
            arguments: [.object([
                "conversationId": .string("conversation-1"),
                "title": .string("A quick question"),
            ])]
        ) == .undefined
    )
    #expect(await service.quickChatConversationID == "conversation-1")
    let recordedEvents = await events.snapshot()
    #expect(recordedEvents.count == 1)
    #expect(recordedEvents.first?.0 == "quickChatWindow")
    #expect(recordedEvents.first?.1 == "addToComposer")

    #expect(
        try await service.invoke(
            service: "quickChatWindow",
            method: "rendererReady",
            arguments: [.null]
        ) == .undefined
    )
    #expect(await service.quickChatRendererReadyConversationID == nil)
    #expect(await service.quickChatPrewarmedRendererReady)

    #expect(
        try await service.invoke(
            service: "quickChatWindow",
            method: "rendererReady",
            arguments: [.string("conversation-1")]
        ) == .undefined
    )
    #expect(await service.quickChatRendererReadyConversationID == "conversation-1")
    #expect(await !service.quickChatPrewarmedRendererReady)
}

@Test
func desktopInteractionAppHostRejectsInvalidQuickChatComposerAndRendererReadyPayloads()
    async throws
{
    let service = CodexDesktopInteractionAppHostService()
    for arguments in [
        nil,
        [],
        [.object(["title": .string("Missing conversation")])],
        [.object(["conversationId": .string("")])],
        [.string("conversation-1")],
        [.object(["conversationId": .string("conversation-1")]), .null],
    ] as [[CodexDesktopAppHostRPC.Value]?] {
        await #expect(throws: CodexDesktopInteractionAppHostService.Error.invalidArguments) {
            try await service.invoke(
                service: "quickChatWindow",
                method: "addToComposer",
                arguments: arguments
            )
        }
    }
    for arguments in [nil, [], [.bool(true)], [.null, .null]] as [[CodexDesktopAppHostRPC.Value]?] {
        await #expect(throws: CodexDesktopInteractionAppHostService.Error.invalidArguments) {
            try await service.invoke(
                service: "quickChatWindow",
                method: "rendererReady",
                arguments: arguments
            )
        }
    }
}

@Test
func desktopInteractionAppHostForwardsPrimaryWindowActionsAndThreadEnqueues()
    async throws
{
    actor Recorder {
        var run: [(CodexDesktopAppHostRPC.Value, String?, String?)] = []
        var enqueued: [CodexDesktopAppHostRPC.Value] = []
        func recordRun(_ action: CodexDesktopAppHostRPC.Value, _ host: String?, _ thread: String?) {
            run.append((action, host, thread))
        }
        func recordEnqueue(_ action: CodexDesktopAppHostRPC.Value) {
            enqueued.append(action)
        }
    }

    let recorder = Recorder()
    let action: CodexDesktopAppHostRPC.Value = .object([
        "type": .string("app.get_summary"),
    ])
    let service = CodexDesktopInteractionAppHostService(
        runPrimaryWindowAction: { action, host, thread in
            await recorder.recordRun(action, host, thread)
            return .object(["ok": .bool(true)])
        },
        enqueuePrimaryThreadAction: { action in
            await recorder.recordEnqueue(action)
        }
    )

    #expect(
        try await service.invoke(
            service: "appActions",
            method: "runInPrimaryWindow",
            arguments: [.object([
                "action": action,
                "sourceHostId": .string("local"),
                "sourceThreadId": .string("thread-1"),
            ])]
        ) == .object(["ok": .bool(true)])
    )
    #expect(
        try await service.invoke(
            service: "appActions",
            method: "enqueueForThreadInPrimaryWindow",
            arguments: [action]
        ) == .undefined
    )
    #expect(await recorder.run.count == 1)
    #expect(await recorder.run.first?.1 == "local")
    #expect(await recorder.run.first?.2 == "thread-1")
    #expect(await recorder.enqueued == [action])
}

@Test
func desktopInteractionAppHostReportsSingleNativePrimaryAppView()
    async throws
{
    let service = CodexDesktopInteractionAppHostService()
    #expect(
        try await service.invoke(
            service: "appActions",
            method: "getPrimaryAppView",
            arguments: nil
        ) == .object([
            "available": .bool(true),
            "platform": .string("ipad"),
        ])
    )
}
