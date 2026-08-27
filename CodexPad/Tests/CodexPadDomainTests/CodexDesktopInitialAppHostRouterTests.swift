import Foundation
import Testing

@testable import CodexPadApplication

private let releasedAppInfo =
    CodexDesktopInitialAppHostRouter.AppInfo(
        version: "26.721.81911",
        buildNumber: "5973",
        buildFlavor: "prod",
        osName: "iPadOS",
        systemVersion: "18.0",
        appName: "Codex for ipad",
        appBrand: "codex"
    )

private let releasedServiceNames = [
    "ambientSuggestions",
    "appActions",
    "appInfo",
    "appServerHistorySnapshots",
    "appUpdates",
    "applicationMenu",
    "appshot",
    "artifactDocuments",
    "avatarOverlay",
    "browserProfileImport",
    "browserSidebar",
    "browserSidebarAutocomplete",
    "browserTabs",
    "browserUsePermissions",
    "browsingHistory",
    "chatGptProjectFiles",
    "chromeNativeHost",
    "chromiumBrowser",
    "chronicle",
    "clientCoordination",
    "clipboard",
    "codexMicro",
    "computerUseSettings",
    "conversationalOnboarding",
    "customAvatars",
    "debug",
    "dictationAudio",
    "dictationHistory",
    "downloads",
    "dynamicToolCalls",
    "fileAttachments",
    "fileDrags",
    "github",
    "hotkeyWindowCommands",
    "hotkeyWindowHotkeys",
    "inAppBrowserIncompleteNavigation",
    "keyboardModifiers",
    "libraryFiles",
    "localEnvironments",
    "localThreadCatalog",
    "notifications",
    "openIn",
    "owlBrowserCrashCounter",
    "owlFeatures",
    "performanceTelemetry",
    "pinnedThreads",
    "pluginScheduledTasks",
    "primaryRuntime",
    "projects",
    "processMemory",
    "pullRequestMessageGeneration",
    "quickChatWindow",
    "realtimeContinuity",
    "realtimeMemory",
    "realtimeVoice",
    "realtimeVoiceHistory",
    "realtimeVoiceMultiAgentActivity",
    "realtimeVoicePresentation",
    "realtimeVoiceRuntime",
    "remoteControlEnvironments",
    "remoteHostedPIP",
    "requestUserInputAutoResolution",
    "startup",
    "systemFonts",
    "systemPermissions",
    "terminal",
    "threadArchive",
    "threadMetadataGeneration",
    "threadProjectAssignments",
    "threadTurnSummaries",
    "tracing",
    "visualizations",
    "windowNavigation",
    "workspaceFiles",
]

private func targetID(for serviceName: String) -> Int {
    guard let index = releasedServiceNames.firstIndex(
        of: serviceName
    ) else {
        preconditionFailure(
            "Unknown released AppHost service: \(serviceName)"
        )
    }
    return -(index + 1)
}

private actor RecordingStartupReady {
    private(set) var callCount = 0

    func waitUntilReady() async {
        callCount += 1
    }
}

@Test
func desktopAppUpdatesAreDisabledWithoutAProductManager() async {
    let service = CodexDesktopAppUpdatesAppHostService()
    await #expect(
        throws: CodexDesktopAppUpdatesAppHostService.Error
            .unavailable(method: "checkForUpdates")
    ) {
        _ = try await service.invoke(method: "checkForUpdates", arguments: [])
    }
}

@Test
func desktopInitialAppHostRouterKeepsCanonicalServiceExportIDs() {
    let router = CodexDesktopInitialAppHostRouter(
        appInfo: releasedAppInfo
    )

    #expect(
        CodexDesktopInitialAppHostRouter.serviceNames
            == releasedServiceNames
    )
    #expect(
        router.services.keys.sorted()
            == (releasedServiceNames
                + ["notificationPermissionsSupported"]).sorted()
    )
    #expect(
        router.services["notificationPermissionsSupported"]
            == .bool(true)
    )
    #expect(!router.services.keys.contains("customRuntime"))
    #expect(!router.services.keys.contains("appshotHotkeys"))
    #expect(!router.services.keys.contains("browserTabMentions"))

    for (index, serviceName) in releasedServiceNames.enumerated() {
        #expect(
            router.serviceName(forTargetID: -(index + 1))
                == serviceName
        )
    }
    #expect(
        router.serviceName(
            forTargetID: -(releasedServiceNames.count + 1)
        ) == nil
    )
}

@Test
func desktopInitialAppHostRouterReturnsReleasedAppInfoShape()
    throws
{
    let router = CodexDesktopInitialAppHostRouter(
        appInfo: releasedAppInfo
    )

    #expect(
        try router.response(
            to: CodexDesktopAppHostRPC.Pipeline(
                targetID: targetID(for: "appInfo"),
                path: [.key("get")],
                arguments: []
            )
        )
            == .object([
                "version": .string("26.721.81911"),
                "buildNumber": .string("5973"),
                "buildFlavor": .string("prod"),
                "osName": .string("iPadOS"),
                "systemVersion": .string("18.0"),
                "appName": .string("Codex for ipad"),
                "appBrand": .string("codex"),
                "appIconMedium": .null,
                "dockIconPreviews": .null,
            ])
    )
}

@Test
func desktopInitialAppHostRouterAcceptsReleasedStartupPhases() throws {
    let router = CodexDesktopInitialAppHostRouter(
        appInfo: releasedAppInfo
    )

    for phase in [
        "renderer_ready",
        "first_content_visible",
        "background_ready",
    ] {
        #expect(
            try router.response(
                to: CodexDesktopAppHostRPC.Pipeline(
                    targetID: targetID(for: "startup"),
                    path: [.key("reach")],
                    arguments: [.string(phase)]
                )
            ) == .undefined
        )
    }

    #expect(
        router.reachedStartupPhases
            == [
                "renderer_ready",
                "first_content_visible",
                "background_ready",
            ]
    )
}

@Test
func desktopInitialAppHostRouterReturnsReleasedProcessMemoryShape()
    throws
{
    let router = CodexDesktopInitialAppHostRouter(
        appInfo: releasedAppInfo,
        processResidentMemoryKb: { 12_345 }
    )

    #expect(
        try router.response(
            to: CodexDesktopAppHostRPC.Pipeline(
                targetID: targetID(for: "processMemory"),
                path: [.key("getSnapshot")],
                arguments: []
            )
        )
            == .object([
                "appServerRssKb": .number(0),
                "codexAppRssKb": .number(12_345),
                "otherChildProcessesRssKb": .number(0),
                "rolloutChildProcessesRssKb": .number(0),
                "totalRssKb": .number(12_345),
            ])
    )
}

@Test
func desktopInitialAppHostRouterClosesOfficialServicesHandshake()
    throws
{
    let router = CodexDesktopInitialAppHostRouter(
        appInfo: releasedAppInfo
    )
    let rpc = CodexDesktopAppHostRPC(
        services: router.services,
        invocationHandler: router.response(to:)
    )

    _ = try rpc.receive(
        #"["push",["pipeline",0,["services"]]]"#
    )
    var exportIndex = 0
    let releasedExports = (
        releasedServiceNames + ["notificationPermissionsSupported"]
    ).sorted().map { serviceName in
        if serviceName == "notificationPermissionsSupported" {
            return #""notificationPermissionsSupported":true"#
        }
        exportIndex += 1
        return #""\#(serviceName)":["export",\#(-exportIndex)]"#
    }.joined(separator: ",")
    let servicesFrames = try rpc.receive(#"["pull",1]"#)
    let expectedServicesFrames = [
        #"["resolve",1,{\#(releasedExports)}]"#
    ]
    #expect(servicesFrames == expectedServicesFrames)

    _ = try rpc.receive(
        #"["push",["pipeline",\#(targetID(for: "appInfo")),["get"],[]]]"#
    )
    let appInfoFrame = try rpc.receive(#"["pull",2]"#)
    #expect(appInfoFrame.count == 1)
    #expect(
        try CodexDesktopAppHostRPC.decode(appInfoFrame[0])
            == .resolve(
                id: 2,
                value: try router.response(
                    to: CodexDesktopAppHostRPC.Pipeline(
                        targetID: targetID(for: "appInfo"),
                        path: [.key("get")],
                        arguments: []
                    )
                )
            )
    )
}

@Test
func desktopInitialAppHostRouterResolvesReviewBootstrapContracts()
    async throws
{
    let router = CodexDesktopInitialAppHostRouter(
        appInfo: releasedAppInfo
    )

    #expect(
        try await router.responseAsync(
            to: .init(
                targetID: targetID(for: "hotkeyWindowHotkeys"),
                path: [.key("getState")],
                arguments: []
            )
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
        try await router.responseAsync(
            to: .init(
                targetID: targetID(for: "clientCoordination"),
                path: [.key("getIdeContext")],
                arguments: [
                    .object([
                        "workspaceRoot": .string("/workspace/project")
                    ])
                ]
            )
        ) == .object([
            "workspaceRoot": .string("/workspace/project")
        ])
    )
    #expect(
        try await router.responseAsync(
            to: .init(
                targetID: targetID(for: "github"),
                path: [.key("request")],
                arguments: [
                    .string("gh-cli-status"),
                    .object([
                        "hostId": .string("local"),
                        "hostname": .undefined,
                    ]),
                    .string("git_direct_call"),
                ]
            )
        ) == .object([
            "isInstalled": .bool(false),
            "isAuthenticated": .bool(false),
        ])
    )
}

@Test
func desktopInitialAppHostRouterWaitsForReleasedStartupWhenReady()
    async throws
{
    let startup = RecordingStartupReady()
    let router = CodexDesktopInitialAppHostRouter(
        appInfo: releasedAppInfo,
        startupReadyHandler: {
            await startup.waitUntilReady()
        }
    )

    #expect(
        try await router.responseAsync(
            to: .init(
                targetID: targetID(for: "startup"),
                path: [.key("whenReady")],
                arguments: []
            )
        ) == .undefined
    )
    #expect(await startup.callCount == 1)
}

@Test
func desktopInitialAppHostRouterSupportsAutoResolutionDisableSetter()
    throws
{
    let router = CodexDesktopInitialAppHostRouter(
        appInfo: releasedAppInfo
    )

    #expect(
        try router.response(
            to: CodexDesktopAppHostRPC.Pipeline(
                targetID: targetID(
                    for: "requestUserInputAutoResolution"
                ),
                path: [.key("setDisabled")],
                arguments: [
                    .object(["disabled": .bool(true)])
                ]
            )
        ) == .undefined
    )
}

@Test
func desktopInitialAppHostRouterSupportsReleasedBootstrapCapabilities()
    throws
{
    let router = CodexDesktopInitialAppHostRouter(
        appInfo: releasedAppInfo,
        systemAppearance: "dark",
        workspaceRoot: "/workspace",
        activeFeatureNames: ["released_feature"]
    )

    #expect(
        try router.response(
            to: .init(
                targetID: targetID(for: "appActions"),
                path: [.key("isPrimaryWindowFocused")],
                arguments: []
            )
        ) == .bool(true)
    )
    #expect(
        try router.response(
            to: .init(
                targetID: targetID(
                    for: "conversationalOnboarding"
                ),
                path: [.key("getSystemAppearance")],
                arguments: []
            )
        ) == .string("dark")
    )
    #expect(
        try router.response(
            to: .init(
                targetID: targetID(
                    for: "conversationalOnboarding"
                ),
                path: [.key("requestDesktopRoot")],
                arguments: []
            )
        ) == .string("/workspace")
    )
    #expect(
        try router.response(
            to: .init(
                targetID: targetID(for: "owlFeatures"),
                path: [.key("isOwlFeatureEnabled")],
                arguments: [.string("released_feature")]
            )
        ) == .bool(true)
    )
}

@Test
func desktopInitialAppHostRouterTracksPendingOwlFeatureNames()
    throws
{
    let router = CodexDesktopInitialAppHostRouter(
        appInfo: releasedAppInfo,
        activeFeatureNames: ["active"]
    )

    let state = try router.response(
        to: .init(
            targetID: targetID(for: "owlFeatures"),
            path: [.key("setFeatureNames")],
            arguments: [
                .object([
                    "enabledFeatureNames": .array([
                        .string("future")
                    ]),
                    "disabledFeatureNames": .array([
                        .string("legacy")
                    ]),
                ])
            ]
        )
    )

    #expect(
        state
            == .object([
                "activeFeatureNames": .array([.string("active")]),
                "activeDisabledFeatureNames": .array([]),
                "pendingFeatureNames": .array([.string("future")]),
                "pendingDisabledFeatureNames": .array([
                    .string("legacy")
                ]),
                "restartRequired": .bool(true),
            ])
    )
}

@Test
func desktopInitialAppHostRouterRoutesWorkspaceCallsAsynchronously()
    async throws
{
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
    let downloads = root.appendingPathComponent("downloads")
    let temporary = root.appendingPathComponent("temporary")
    try FileManager.default.createDirectory(
        at: root,
        withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("readme.txt")
    try Data("renderer file".utf8).write(to: file)
    let workspaceFiles = CodexDesktopWorkspaceAppHostService(
        workspaceRoot: root,
        downloadsDirectory: downloads,
        temporaryDirectory: temporary
    )
    let router = CodexDesktopInitialAppHostRouter(
        appInfo: releasedAppInfo,
        workspaceFileService: workspaceFiles
    )

    let response = try await router.responseAsync(
        to: .init(
            targetID: targetID(for: "workspaceFiles"),
            path: [.key("read")],
            arguments: [
                .object([
                    "hostId": .string("local"),
                    "path": .string(file.path),
                    "representation": .string("text"),
                ])
            ]
        )
    )

    guard case let .object(fields) = response else {
        Issue.record("workspace read must resolve an object")
        return
    }
    #expect(fields["text"] == .string("renderer file"))
}

@Test
func desktopInitialAppHostRouterBuffersAndFlushesOrderedStartupPhases()
    async throws
{
    let router = CodexDesktopInitialAppHostRouter(appInfo: releasedAppInfo)
    for phase in [
        "renderer_ready",
        "first_content_visible",
        "background_ready",
    ] {
        #expect(
            try router.response(
                to: .init(
                    targetID: targetID(for: "startup"),
                    path: [.key("bufferPhase")],
                    arguments: [.string(phase)]
                )
            ) == .undefined
        )
    }
    #expect(router.reachedStartupPhases.isEmpty)
    #expect(
        try await router.responseAsync(
            to: .init(
                targetID: targetID(for: "startup"),
                path: [.key("whenReady")],
                arguments: []
            )
        ) == .undefined
    )
    #expect(
        router.reachedStartupPhases == [
            "renderer_ready",
            "first_content_visible",
            "background_ready",
        ]
    )
}

@Test
func desktopInitialAppHostRouterRejectsOutOfOrderAndClearsBufferedStartupPhases()
    async throws
{
    let router = CodexDesktopInitialAppHostRouter(appInfo: releasedAppInfo)
    _ = try router.response(
        to: .init(
            targetID: targetID(for: "startup"),
            path: [.key("bufferPhase")],
            arguments: [.string("first_content_visible")]
        )
    )
    _ = try router.response(
        to: .init(
            targetID: targetID(for: "startup"),
            path: [.key("bufferPhase")],
            arguments: [.string("renderer_ready")]
        )
    )
    _ = try router.response(
        to: .init(
            targetID: targetID(for: "startup"),
            path: [.key("clearBufferedPhases")],
            arguments: []
        )
    )
    _ = try await router.responseAsync(
        to: .init(
            targetID: targetID(for: "startup"),
            path: [.key("whenReady")],
            arguments: []
        )
    )
    #expect(router.reachedStartupPhases.isEmpty)
}
