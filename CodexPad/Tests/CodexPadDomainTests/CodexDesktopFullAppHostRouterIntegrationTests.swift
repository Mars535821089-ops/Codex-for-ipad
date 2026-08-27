import Foundation
import Testing

@testable import CodexPadApplication

private typealias FullRouterValue = CodexDesktopAppHostRPC.Value

/// `uae({ ... })` in desktop 26.814.41957 (build 6744), sorted exactly as
/// Cap'n Web allocates root RpcTarget exports. `customRuntime: void 0` and
/// `notificationPermissionsSupported: Bool` are deliberately absent: an
/// undefined or primitive property does not allocate a target ID.
private let fullRouterReleasedServiceNames = [
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

private let fullRouterAppInfo =
    CodexDesktopInitialAppHostRouter.AppInfo(
        version: "26.814.41957",
        buildNumber: "6744",
        buildFlavor: "prod",
        osName: "iPadOS",
        systemVersion: "18.0",
        appName: "Codex for ipad",
        appBrand: "codex"
    )

@Test
func desktopFullAppHostRouterAllocatesEveryReleasedRpcTargetInSortedOrder() {
    let router = CodexDesktopInitialAppHostRouter(
        appInfo: fullRouterAppInfo
    )

    #expect(
        CodexDesktopInitialAppHostRouter.serviceNames
            == fullRouterReleasedServiceNames
    )
    #expect(
        router.services.keys.sorted()
            == (fullRouterReleasedServiceNames
                + ["notificationPermissionsSupported"]).sorted()
    )
    #expect(
        router.services["notificationPermissionsSupported"]
            == .bool(true)
    )
    #expect(!router.services.keys.contains("customRuntime"))

    for (index, serviceName) in
        fullRouterReleasedServiceNames.enumerated()
    {
        #expect(
            router.serviceName(forTargetID: -(index + 1))
                == serviceName
        )
    }
    #expect(
        router.serviceName(
            forTargetID: -(fullRouterReleasedServiceNames.count + 1)
        ) == nil
    )
}

@Test
func desktopFullAppHostRouterForwardsEachNewAdapterPrecisely()
    async throws
{
    let fixture = try FullRouterFixture()
    defer { fixture.remove() }

    let artifactDocuments =
        CodexDesktopArtifactDocumentsAppHostService(
            allowedWorkspaceRoots: [fixture.workspace],
            storeDirectory: fixture.store
        )
    let browsingState =
        CodexDesktopBrowsingStateAppHostService { request in
            .string("browsing-state:\(request.method)")
        }
    let downloads = CodexDesktopDownloadsAppHostService(
        manager: FullRouterDownloadsManager()
    )
    let github = CodexDesktopGitHubAppHostService(
        requestOperation: { _ in .init(rawValue: "github-operation") },
        requestWait: { operation in
            .string("github:\(operation.rawValue)")
        }
    )
    let historyMedia = CodexDesktopHistoryMediaAppHostService(
        dictationDirectory: fixture.dictation
    )
    let historySnapshots =
        CodexDesktopHistorySnapshotsAppHostService(
            storeRoot: fixture.history,
            principalProvider: { nil },
            hostKeyProvider: { _ in "stable-host-key" }
        )
    let library = CodexDesktopLibraryAppHostService(
        workspaceRoot: fixture.workspace,
        generatedImagesDirectory: fixture.generatedImages,
        outputDirectories: [:]
    )
    let localEnvironments =
        CodexDesktopLocalEnvironmentsAppHostService(
            hostProvider: { .init(id: $0) },
            fileSystemHandler: { host, operation in
                guard host.id == "local",
                      case .list(workspaceRoot: "/workspace") =
                          operation
                else {
                    return .array([])
                }
                return .array([
                    .object([
                        "configPath": .string(
                            "/workspace/.codex/environments/environment.toml"
                        ),
                        "cwdRelativeToGitRoot": .string("."),
                        "environment": .object([
                            "name": .string("local-environments"),
                            "setup": .object([
                                "script": .string(""),
                            ]),
                            "version": .integer(1),
                        ]),
                        "type": .string("success"),
                    ]),
                ])
            }
        )
    let localThreadCatalog =
        CodexDesktopLocalThreadCatalogAppHostService(
            backend: FullRouterCatalogBackend()
        )
    let optionalPlatform =
        CodexDesktopOptionalPlatformAppHostService(
            debugOperation: { method, _ in
                .string("debug:\(method)")
            }
        )
    let peripheral = CodexDesktopPeripheralAppHostService(
        appshotHotkeyOperation: { method, _ in
            .string("appshot:\(method)")
        }
    )
    let project = CodexDesktopProjectAppHostService(
        remoteProjectHandler: { method, _ in
            .object([
                "hostId": .string("remote-host"),
                "id": .string("project-from-\(method)"),
                "label": .string("Router integration"),
                "remotePath": .string("/workspace"),
            ])
        }
    )
    let terminal = CodexDesktopTerminalAppHostService(
        manager: FullRouterTerminalManager()
    )

    let router = CodexDesktopInitialAppHostRouter(
        appInfo: fullRouterAppInfo,
        workspaceRoot: fixture.workspace.path,
        artifactDocumentsService: artifactDocuments,
        browsingStateService: browsingState,
        downloadsService: downloads,
        githubService: github,
        historyMediaService: historyMedia,
        historySnapshotsService: historySnapshots,
        libraryService: library,
        localEnvironmentsService: localEnvironments,
        localThreadCatalogService: localThreadCatalog,
        optionalPlatformService: optionalPlatform,
        peripheralService: peripheral,
        projectService: project,
        terminalService: terminal
    )

    #expect(
        try await fullRouterResponse(
            router,
            service: "artifactDocuments",
            method: "bindToExactFile",
            arguments: [
                .object([
                    "publicFilePath": .string(
                        fixture.artifact.path
                    ),
                ]),
            ]
        ) == .rpcObject([:])
    )
    #expect(
        try await fullRouterResponse(
            router,
            service: "browsingHistory",
            method: "getBrowsingDataSettings"
        ) == .string(
            "browsing-state:getBrowsingDataSettings"
        )
    )
    #expect(
        try await fullRouterResponse(
            router,
            service: "downloads",
            method: "chooseDownloadDirectory"
        ) == .string("/adapter/downloads")
    )
    #expect(
        try await fullRouterResponse(
            router,
            service: "github",
            method: "request",
            arguments: [
                .string("gh-cli-status"),
                .object(["hostId": .string("local")]),
                .string("router-integration"),
            ]
        ) == .string("github:github-operation")
    )
    #expect(
        try await fullRouterResponse(
            router,
            service: "dictationHistory",
            method: "list"
        ) == .object(["items": .array([])])
    )
    #expect(
        try await fullRouterResponse(
            router,
            service: "appServerHistorySnapshots",
            method: "acquireAuthorizationLease",
            arguments: [.string("local")]
        ) == .object(["status": .string("unavailable")])
    )
    #expect(
        try await fullRouterResponse(
            router,
            service: "libraryFiles",
            method: "listGeneratedImages"
        ) == .array([])
    )
    #expect(
        try await fullRouterResponse(
            router,
            service: "localEnvironments",
            method: "list",
            arguments: [
                .object([
                    "hostId": .string("local"),
                    "workspaceRoot": .string("/workspace"),
                ]),
            ]
        ) == .object([
            "environments": .array([
                .object([
                    "configPath": .string(
                        "/workspace/.codex/environments/environment.toml"
                    ),
                    "cwdRelativeToGitRoot": .string("."),
                    "environment": .object([
                        "name": .string("local-environments"),
                        "setup": .object([
                            "script": .string(""),
                        ]),
                        "version": .integer(1),
                    ]),
                    "type": .string("success"),
                ]),
            ]),
        ])
    )
    #expect(
        try await fullRouterResponse(
            router,
            service: "localThreadCatalog",
            method: "readStatus"
        ) == .object([
            "adapter": .string("local-thread-catalog"),
        ])
    )
    #expect(
        try await fullRouterResponse(
            router,
            service: "debug",
            method: "getBrowserSnapshot"
        ) == .string("debug:getBrowserSnapshot")
    )
    #expect(
        try await fullRouterResponse(
            router,
            service: "appshot",
            method: "requestFinalUpdate",
            arguments: [
                .object(["requestId": .string("request-1")])
            ]
        ) == .string("appshot:requestFinalUpdate")
    )
    #expect(
        try await fullRouterResponse(
            router,
            service: "projects",
            method: "createRemote",
            arguments: [
                .object([
                    "appearance": .null,
                    "hostId": .string("remote-host"),
                    "label": .string("Router integration"),
                    "remotePath": .string("/workspace"),
                ]),
            ]
        ) == .object([
            "hostId": .string("remote-host"),
            "id": .string("project-from-createRemote"),
            "label": .string("Router integration"),
            "remotePath": .string("/workspace"),
        ])
    )
    #expect(
        try await fullRouterResponse(
            router,
            service: "terminal",
            method: "getShellCwd",
            arguments: [
                .string("terminal-1"),
                .string("/requested"),
            ]
        ) == .string("/adapter/terminal")
    )
}

private func fullRouterResponse(
    _ router: CodexDesktopInitialAppHostRouter,
    service: String,
    method: String,
    arguments: [FullRouterValue]? = nil
) async throws -> FullRouterValue {
    let index = try #require(
        fullRouterReleasedServiceNames.firstIndex(of: service)
    )
    return try await router.responseAsync(
        to: .init(
            targetID: -(index + 1),
            path: [.key(method)],
            arguments: arguments
        )
    )
}

private final class FullRouterFixture: @unchecked Sendable {
    let root: URL
    let workspace: URL
    let store: URL
    let history: URL
    let dictation: URL
    let generatedImages: URL
    let artifact: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "CodexDesktopFullAppHostRouter-\(UUID().uuidString)",
                isDirectory: true
            )
        workspace = root.appendingPathComponent(
            "workspace",
            isDirectory: true
        )
        store = root.appendingPathComponent(
            "artifact-store",
            isDirectory: true
        )
        history = root.appendingPathComponent(
            "history",
            isDirectory: true
        )
        dictation = root.appendingPathComponent(
            "dictation",
            isDirectory: true
        )
        generatedImages = root.appendingPathComponent(
            "generated-images",
            isDirectory: true
        )
        artifact = workspace.appendingPathComponent("artifact.bin")
        try FileManager.default.createDirectory(
            at: workspace,
            withIntermediateDirectories: true
        )
        try Data("router-artifact".utf8).write(to: artifact)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

private actor FullRouterDownloadsManager:
    CodexDesktopDownloadsAppHostManaging
{
    func acknowledge(
        _ acknowledgement:
            CodexDesktopDownloadsAppHostService.Acknowledgement
    ) async throws {}

    func cancel(id: String) async throws
        -> CodexDesktopDownloadsAppHostService.ActionResult
    {
        .success
    }

    func chooseDownloadDirectory() async throws -> String? {
        "/adapter/downloads"
    }

    func clearHistory() async throws {}

    func getSnapshot() async throws
        -> CodexDesktopDownloadsAppHostService.Snapshot
    {
        .init(
            capturedAtMs: 0,
            downloads: [],
            unacknowledgedIDs: []
        )
    }

    func open(id: String) async throws
        -> CodexDesktopDownloadsAppHostService.ActionResult
    {
        .success
    }

    func pause(id: String) async throws
        -> CodexDesktopDownloadsAppHostService.ActionResult
    {
        .success
    }

    func removeFromHistory(id: String) async throws
        -> CodexDesktopDownloadsAppHostService.ActionResult
    {
        .success
    }

    func resume(id: String) async throws
        -> CodexDesktopDownloadsAppHostService.ActionResult
    {
        .success
    }

    func searchHistory(
        _ request: CodexDesktopDownloadsAppHostService.SearchRequest
    ) async throws -> CodexDesktopDownloadsAppHostService.Snapshot {
        .init(
            capturedAtMs: 0,
            downloads: [],
            unacknowledgedIDs: []
        )
    }

    func showDownloadsFolder() async throws
        -> CodexDesktopDownloadsAppHostService.ActionResult
    {
        .success
    }

    func showInFolder(id: String) async throws
        -> CodexDesktopDownloadsAppHostService.ActionResult
    {
        .success
    }
}

private actor FullRouterCatalogBackend:
    CodexDesktopLocalThreadCatalogBackend
{
    func readPage(_ request: FullRouterValue) async throws
        -> FullRouterValue
    {
        .object(["entries": .array([]), "nextCursor": .null])
    }

    func readEntries(
        _ locators: [FullRouterValue]
    ) async throws -> [FullRouterValue] {
        []
    }

    func removeMissingEntry(
        _ locator: FullRouterValue
    ) async throws -> Bool {
        false
    }

    func readSnapshot() async throws -> FullRouterValue {
        .object([
            "revision": .integer(0),
            "hosts": .array([]),
            "entries": .array([]),
        ])
    }

    func readStatus() async throws -> FullRouterValue {
        .object([
            "adapter": .string("local-thread-catalog"),
        ])
    }

    func setPopulationEnabled(
        _ enabled: Bool,
        startup: String
    ) async throws {}

    func requestSync(
        hostIDs: [String]?,
        priority: String
    ) async throws {}

    func requestStartupSync() async throws {}
}

private actor FullRouterTerminalManager:
    CodexDesktopTerminalAppHostManaging
{
    func createOrAttach(
        _ request:
            CodexDesktopTerminalAppHostService.SessionRequest
    ) async throws {}

    func close(sessionID: String) async throws {}

    func getShellCWD(
        sessionID: String,
        requestedCWD: String
    ) async throws -> String? {
        "/adapter/terminal"
    }

    func getThreadSnapshot(
        conversationID: String
    ) async throws
        -> CodexDesktopTerminalAppHostService.ThreadSnapshot?
    {
        nil
    }

    func resize(
        sessionID: String,
        columns: UInt32,
        rows: UInt32,
        repaint: Bool
    ) async throws {}

    func runAction(
        sessionID: String,
        cwd: String,
        command: String
    ) async throws {}

    func write(
        sessionID: String,
        data: String
    ) async throws {}

    func subscribe(
        _ receive: @escaping CodexDesktopTerminalEventReceiver
    ) async throws -> CodexDesktopTerminalUnsubscribe {
        {}
    }
}
