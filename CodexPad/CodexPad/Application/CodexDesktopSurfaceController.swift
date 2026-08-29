#if os(iOS) && canImport(UIKit) && canImport(WebKit)
    #if SWIFT_PACKAGE
        import CodexPadDomain
        import CodexPadProtocolBridge
    #endif
    import Foundation
    import Observation
    import OSLog
    import UniformTypeIdentifiers
    import UIKit
    import WebKit

    private enum CodexDesktopFileInteractionError: Error {
        case interactionInProgress
    }

    private enum CodexDesktopAppshotCaptureError: Error {
        case webViewUnavailable
        case snapshotUnavailable
        case pngEncodingFailed
    }

    private final class CodexDesktopSecurityScopedFileLease {
        let url: URL

        init(url: URL) {
            self.url = url
        }

        deinit {
            url.stopAccessingSecurityScopedResource()
        }
    }

    @Observable
    @MainActor
    public final class CodexDesktopSurfaceController:
        CodexDesktopFileInteracting,
        CodexDesktopGitCredentialProviding,
        CodexDesktopManagedWorktreeInteracting,
        CodexDesktopWorktreeSnapshotUploading
    {
        public private(set) var surfaceState:
            CodexDesktopSurfaceState
        public private(set) var diagnostics: [String] = []
        public var isWorkspacePickerPresented = false
        public private(set) var workspacePickerAllowsMultipleSelection =
            false
        public var isDesktopFilePickerPresented = false
        public private(set) var desktopFilePickerAllowsMultipleSelection =
            false
        public private(set) var desktopFilePickerImagesOnly = false
        public var isDesktopFileExporterPresented = false
        public private(set) var desktopFileExportContents = Data()
        public private(set) var desktopFileExportSuggestedFilename =
            "Untitled"
        public private(set) var appShellShortcutState:
            CodexDesktopAppShellShortcutState?
        public private(set) var isAvatarOverlayPresented = false
        public private(set) var lastFetchStreamDiagnostic =
            CodexDesktopFetchStreamDiagnostic()
        public var lastFetchStreamState: String {
            lastFetchStreamDiagnostic.state.rawValue
        }
        public var lastActiveLocalThreadAnchorState: String {
            lastActiveLocalThreadStore.threadID == nil
                ? "missing"
                : "present"
        }

        @ObservationIgnored
        public private(set) var host: CodexDesktopWebViewHost?
        @ObservationIgnored
        private lazy var appshotCaptureCoordinator =
            CodexDesktopAppshotCaptureCoordinator(
                snapshotOperation: { [weak self] in
                    guard let self else {
                        throw CancellationError()
                    }
                    return try await self.captureAppshotSnapshot()
                },
                eventSink: { [weak self] message in
                    await self?.send(message)
                }
            )
        @ObservationIgnored
        public private(set) var avatarOverlayHost:
            CodexDesktopWebViewHost?
        @ObservationIgnored
        private var avatarOverlayBootstrap:
            CodexDesktopBridgeBootstrap?
        @ObservationIgnored
        private var avatarOverlayState =
            CodexDesktopAvatarOverlayState()
        @ObservationIgnored
        private var hardwareShortcutDispatchGate =
            CodexDesktopHardwareShortcutDispatchGate()

        @ObservationIgnored
        private weak var accountStore: CodexAccountStore?
        @ObservationIgnored
        private let sessionStore: CodexSessionStore
        @ObservationIgnored
        private let persistedAtoms: CodexDesktopPersistedAtomStore
        @ObservationIgnored
        private let configStore: CodexDesktopConfigStore
        @ObservationIgnored
        private let gitCredentialStore: CodexGitCredentialStore
        @ObservationIgnored
        private let selectedProjectStore:
            CodexDesktopSelectedProjectStore
        @ObservationIgnored
        private let pinnedThreadStore:
            CodexDesktopPinnedThreadStore
        @ObservationIgnored
        private let lastActiveLocalThreadStore:
            CodexDesktopLastActiveLocalThreadStore
        @ObservationIgnored
        private let localProjectsStateStore:
            CodexDesktopLocalProjectsStateStore
        @ObservationIgnored
        private let threadProjectAssignmentStore:
            CodexDesktopThreadProjectAssignmentStore
        @ObservationIgnored
        private let projectlessOutputDirectoryStore:
            CodexDesktopProjectlessOutputDirectoryStore
        @ObservationIgnored
        private let sharedObjects: CodexDesktopSharedObjectStore
        @ObservationIgnored
        private var appHostSessions:
            CodexDesktopAppHostSessionStore?
        @ObservationIgnored
        private var appHostRouterStore:
            CodexDesktopAppHostPortRouterStore?
        @ObservationIgnored
        private var appHostWorkspaceRegistry:
            CodexDesktopAppHostWorkspaceRegistry?
        @ObservationIgnored
        private var loginCoordinator:
            CodexDesktopLoginCoordinator?
        @ObservationIgnored
        private var mcpOAuthCoordinator:
            CodexDesktopMCPOAuthCoordinator?
        @ObservationIgnored
        private var mcpRuntimeRegistry:
            CodexMCPRuntimeRegistry?
        @ObservationIgnored
        private var skillCatalog:
            CodexSkillCatalogService?
        @ObservationIgnored
        private var recommendedSkillService:
            CodexRecommendedSkillService?
        @ObservationIgnored
        private var hookCatalog:
            CodexHookCatalogService?
        @ObservationIgnored
        private var appCatalog:
            CodexAppCatalogService?
        @ObservationIgnored
        private var settingsCatalog:
            CodexExperimentalSettingsService?
        @ObservationIgnored
        private var marketplaceManager:
            CodexMarketplaceManagementService?
        @ObservationIgnored
        private var pluginCatalog:
            CodexPluginCatalogService?
        @ObservationIgnored
        private var remotePluginCatalog:
            CodexRemotePluginService?
        @ObservationIgnored
        private var externalAgentConfigMigrationService:
            CodexExternalAgentConfigMigrationService?
        @ObservationIgnored
        private var feedbackUploadService:
            CodexFeedbackUploadService?
        @ObservationIgnored
        private var environmentService:
            CodexEnvironmentService?
        @ObservationIgnored
        private var realtimeService:
            CodexRealtimeService?
        @ObservationIgnored
        private var remoteControlBridge:
            CodexRemoteControlMCPBridge?
        @ObservationIgnored
        private var remoteControlStatusTask:
            Task<Void, Never>?
        @ObservationIgnored
        private var surfaceVerificationTask:
            Task<Void, Never>?
        @ObservationIgnored
        private var pendingRestoredInitialRoute: String?
        @ObservationIgnored
        private var fetchStreamTasks:
            [String: Task<Void, Never>] = [:]
        @ObservationIgnored
        private var turnNotificationTail:
            Task<Void, Never>?
        @ObservationIgnored
        private var workspaceOnboardingCoordinator:
            CodexDesktopWorkspaceOnboardingCoordinator?
        @ObservationIgnored
        private var desktopFilePickerContinuation:
            CheckedContinuation<[URL], any Error>?
        @ObservationIgnored
        private var desktopFileExporterContinuation:
            CheckedContinuation<URL?, any Error>?
        @ObservationIgnored
        private var securityScopedDesktopFileLeases:
            [CodexDesktopSecurityScopedFileLease] = []
        @ObservationIgnored
        private var desktopTurnRunner:
            CodexDesktopTurnSessionRunner?
        @ObservationIgnored
        private var extendedSessionAdapter:
            CodexDesktopExtendedSessionAdapter?
        @ObservationIgnored
        private var extendedSessionBackend:
            CodexDesktopExtendedSessionBackend?
        @ObservationIgnored
        private let turnProviderFactory:
            CodexDesktopTurnSessionRunner.ProviderFactory?
        @ObservationIgnored
        private var automationStore:
            CodexDesktopAutomationStore?
        @ObservationIgnored
        private var automationScheduler:
            CodexDesktopAutomationScheduler?
        @ObservationIgnored
        private var approvalBroker:
            CodexDesktopApprovalBroker?
        @ObservationIgnored
        private var requestUserInputBroker:
            CodexDesktopRequestUserInputBroker?
        @ObservationIgnored
        fileprivate var dynamicToolCallBroker:
            CodexDesktopDynamicToolCallBroker?
        @ObservationIgnored
        private var serverRequestBroker:
            CodexDesktopServerRequestBroker?
        @ObservationIgnored
        private let commandExecutor:
            CodexDesktopWorkspaceCommandExecutor
        @ObservationIgnored
        private let gitDiffer:
            (any CodexDesktopGitDiffing)?
        @ObservationIgnored
        private lazy var gitWorker = CodexDesktopGitWorker(
            runWithEnvironment: {
                [weak self] arguments, cwd, environment in
                guard let self else {
                    throw CancellationError()
                }
                let command = arguments
                    .map(Self.shellQuote)
                    .joined(separator: " ")
                return try await self.commandExecutor.execute(
                    CodexDesktopCommandExecParams(
                        command: ["sh", "-lc", command],
                        processID: nil,
                        tty: false,
                        streamStdin: false,
                        streamStdoutStderr: false,
                        outputBytesCap: 1_048_576,
                        disableOutputCap: false,
                        disableTimeout: false,
                        timeoutMs: 30_000,
                        cwd: cwd,
                        environment: environment,
                        size: nil,
                        sandboxPolicy: nil
                    ),
                    allowedRoots: [cwd]
                )
            },
            embeddedReader: {
                [weak self] method, params in
                guard let self,
                      let requester =
                        self.gitDiffer
                            as? any CodexDesktopEmbeddedGitRequesting
                else {
                    throw CodexDesktopWorkerMethodError(
                        "Embedded Git reader is unavailable"
                    )
                }
                return try await requester.embeddedGitRead(
                    method: method,
                    params: params
                )
            }
        )
        @ObservationIgnored
        private lazy var workerBus = CodexDesktopWorkerBus(
            handlers: [
                "git": gitWorker
            ],
            output: { [weak self] message in
                await self?.send(message)
            },
            diagnostic: { [weak self] diagnostic in
                await self?.recordWorkerDiagnostic(diagnostic)
            }
        )
        @ObservationIgnored
        private var fileWatchManager:
            CodexDesktopFileWatchManager?
        @ObservationIgnored
        private var fuzzyFileSearchService:
            CodexDesktopFuzzyFileSearchService?
        @ObservationIgnored
        private var memoryResetService:
            CodexDesktopMemoryResetService?
        @ObservationIgnored
        private let externalURLOpener:
            any CodexDesktopExternalURLOpening
        @ObservationIgnored
        private let networkFetchClient:
            CodexDesktopNetworkFetchClient
        @ObservationIgnored
        private lazy var credentialRefreshAdapter:
            CodexAccountCredentialRefreshAdapter =
                CodexAccountCredentialRefreshAdapter(
                    accountStore: { [weak self] in
                        self?.accountStore
                    },
                    send: { [weak self] message in
                        await self?.send(message)
                    }
                )
        @ObservationIgnored
        private let officialProvider:
            CodexOfficialProviderClient?
        @ObservationIgnored
        private let fileManager: FileManager
        @ObservationIgnored
        private let userDefaults: UserDefaults
        @ObservationIgnored
        private let focusedDiagnosticStore:
            CodexDesktopFocusedDiagnosticStore
        @ObservationIgnored
        private let logger = Logger(
            subsystem: Bundle.main.bundleIdentifier
                ?? "com.mars.codexpad",
            category: "DesktopSurface"
        )

        private var hasStarted = false
        private var startupGate =
            CodexDesktopReleasedStartupGate()
        private var startupReadyContinuations:
            [CheckedContinuation<Void, Never>] = []
        private var didOpenHomeDataGate = false

        private static let installationIDKey =
            "codex.desktop.installation-id"
        private static let runtimeDiagnosticsKey =
            "codex.desktop.runtime-diagnostics"
        private static let lastReviewDiagnosticKey =
            "codex.desktop.last-review-diagnostic"
        private static let lastGitMetadataDiagnosticKey =
            "codex.desktop.last-git-metadata-diagnostic"

        nonisolated private static func shellQuote(
            _ value: String
        ) -> String {
            "'" + value.replacingOccurrences(
                of: "'",
                with: "'\\''"
            ) + "'"
        }
        public init(
            accountStore: CodexAccountStore,
            sessionStore: CodexSessionStore,
            userDefaults: UserDefaults = .standard,
            fileManager: FileManager = .default,
            externalURLOpener:
                any CodexDesktopExternalURLOpening =
                    CodexDesktopExternalURLOpener(
                        authenticationPresentationPolicy:
                            .inAppOnly
                    ),
            networkFetchClient:
                CodexDesktopNetworkFetchClient =
                    CodexDesktopNetworkFetchClient(),
            officialProvider:
                CodexOfficialProviderClient? = nil,
            commandExecutor:
                CodexDesktopWorkspaceCommandExecutor =
                    CodexDesktopWorkspaceCommandExecutor(),
            turnProviderFactory:
                CodexDesktopTurnSessionRunner.ProviderFactory? = nil,
            turnToolExecutorFactory:
                @escaping
                CodexDesktopTurnSessionRunner.ToolExecutorFactory =
                    { _, _, _, _ in nil },
            mcpOAuthDriver:
                (any CodexDesktopMCPOAuthSessionDriving)? = nil,
            gitDiffer:
                (any CodexDesktopGitDiffing)? = nil,
            gitCredentialStore:
                CodexGitCredentialStore =
                    CodexGitCredentialStore()
        ) {
            self.accountStore = accountStore
            self.sessionStore = sessionStore
            self.userDefaults = userDefaults
            let focusedDiagnosticStore =
                CodexDesktopFocusedDiagnosticStore(
                    userDefaults: userDefaults
                )
            focusedDiagnosticStore.beginSession()
            self.focusedDiagnosticStore = focusedDiagnosticStore
            self.fileManager = fileManager
            self.externalURLOpener = externalURLOpener
            self.networkFetchClient = networkFetchClient
            self.officialProvider = officialProvider
            self.commandExecutor = commandExecutor
            self.gitDiffer = gitDiffer
            self.gitCredentialStore = gitCredentialStore
            self.turnProviderFactory = turnProviderFactory
            self.persistedAtoms = CodexDesktopPersistedAtomStore(
                userDefaults: userDefaults
            )
            self.configStore = CodexDesktopConfigStore(
                userDefaults: userDefaults
            )
            self.localProjectsStateStore =
                CodexDesktopLocalProjectsStateStore(
                    userDefaults: userDefaults
                )
            self.threadProjectAssignmentStore =
                CodexDesktopThreadProjectAssignmentStore(
                    userDefaults: userDefaults
                )
            let documentsDirectory = fileManager.urls(
                for: .documentDirectory,
                in: .userDomainMask
            ).first ?? fileManager.temporaryDirectory
            self.projectlessOutputDirectoryStore =
                CodexDesktopProjectlessOutputDirectoryStore(
                    workspaceRoot:
                        documentsDirectory.appendingPathComponent(
                            "Codex",
                            isDirectory: true
                        ),
                    userDefaults: userDefaults,
                    fileManager: fileManager
                )
            let selectedProjectStore =
                CodexDesktopSelectedProjectStore(
                    userDefaults: userDefaults
                )
            self.selectedProjectStore = selectedProjectStore
            self.pinnedThreadStore =
                CodexDesktopPinnedThreadStore(
                    userDefaults: userDefaults
                )
            self.lastActiveLocalThreadStore =
                CodexDesktopLastActiveLocalThreadStore(
                    userDefaults: userDefaults
                )
            if ProcessInfo.processInfo.environment[
                "XCTestConfigurationFilePath"
            ] != nil,
               ProcessInfo.processInfo.environment[
                   "CODEXPAD_UI_TEST_CLEAN_VALIDATION_FIXTURES"
               ] == "1"
            {
                _ = localProjectsStateStore.removeProjects(
                    namedExactly: "Parity Git Workspace"
                )
                selectedProjectStore.setSelectedWorkspaceID(nil)
                lastActiveLocalThreadStore.clearDurableThreadID(
                    source: "validation-fixture-cleanup"
                )
            }
            if let initialWorkspaceID =
                selectedProjectStore.resolveInitialSelection(
                    preferredWorkspaceID:
                        sessionStore.selectedWorkspaceID,
                    from: sessionStore.state.workspaces
                )
            {
                sessionStore.selectedWorkspaceID =
                    initialWorkspaceID
            }
            sessionStore.setWorkspaceSelectionPersistence {
                selectedProjectStore.setSelectedWorkspaceID($0)
            }

            let currentInstallationID: String
            if let existing = userDefaults.string(
                forKey: Self.installationIDKey
            ), !existing.isEmpty {
                currentInstallationID = existing
            } else {
                currentInstallationID = UUID().uuidString
                userDefaults.set(
                    currentInstallationID,
                    forKey: Self.installationIDKey
                )
            }
            let sharedObjectSnapshot =
                CodexDesktopSharedObjectStore
                    .releasedInitialSnapshot(
                        installationID:
                            currentInstallationID
                    )
            self.sharedObjects = CodexDesktopSharedObjectStore(
                initialValues: sharedObjectSnapshot
            )

            let appSessionID = UUID().uuidString
            let localProjectGlobalState =
                localProjectsStateStore.globalStateSnapshot(
                    selectedProject:
                        selectedProjectStore.globalStateValue
                )
            let initialLocalProjects:
                [String: CodexJSONValue]
            if case let .object(projects)? =
                localProjectGlobalState["local-projects"]
            {
                initialLocalProjects = projects
            } else {
                initialLocalProjects = [:]
            }
            let initialProjectOrder: [String]
            if case let .array(values)? =
                localProjectGlobalState["project-order"]
            {
                let localProjectIDs = values.compactMap {
                    if case let .string(value) = $0 { return value }
                    return nil
                }
                initialProjectOrder = Self.mergedReleasedProjectOrder(
                    persistedOrder:
                        persistedAtoms.snapshot["project-order"],
                    localProjectIDs: localProjectIDs,
                    remoteProjects:
                        persistedAtoms.snapshot["remote-projects"]
                )
            } else {
                initialProjectOrder = Self.mergedReleasedProjectOrder(
                    persistedOrder:
                        persistedAtoms.snapshot["project-order"],
                    localProjectIDs: [],
                    remoteProjects:
                        persistedAtoms.snapshot["remote-projects"]
                )
            }
            let bootstrap = CodexDesktopBridgeBootstrap(
                preloadStartedAtMs:
                    Date().timeIntervalSince1970 * 1_000,
                systemThemeVariant:
                    Self.currentSystemThemeVariant(),
                initialSidebarBootstrap:
                    CodexDesktopInitialSidebarBootstrap.make(
                        state: sessionStore.state,
                        persistedAtoms: persistedAtoms.snapshot,
                        selectedProject: selectedProjectStore.globalStateValue,
                        pinnedThreadIDs: pinnedThreadStore.threadIDs,
                        threadProjectAssignments:
                            threadProjectAssignmentStore.globalStateValue,
                        localProjects: initialLocalProjects,
                        projectOrder: initialProjectOrder
                    ),
                sharedObjectSnapshot: sharedObjectSnapshot,
                sentryInitOptions:
                    CodexDesktopBridgeBootstrap
                        .releasedSentryInitOptions(
                            appSessionID: appSessionID,
                            appVersion:
                                CodexBuildMetadata
                                    .desktopVersion,
                            buildNumber:
                                CodexBuildMetadata
                                    .desktopBuild
                        ),
                buildFlavor: "prod",
                appSessionID: appSessionID,
                usesOwlAppShell:
                    CodexDesktopBridgeBootstrap
                        .releasedUsesOwlAppShell
            )
            avatarOverlayBootstrap = bootstrap

            do {
                let createdHost = try CodexDesktopWebViewHost(
                    bootstrap: bootstrap
                )
                host = createdHost
                surfaceState = createdHost.state
            } catch {
                host = nil
                surfaceState = .failed(
                    reason: CodexDiagnosticSanitization.publicErrorSummary(error)
                )
            }

            fileWatchManager = CodexDesktopFileWatchManager {
                [weak self] hostID, watchID, changedPaths in
                Task { @MainActor [weak self] in
                    await self?.send(
                        .mcpNotification(
                            hostID: hostID,
                            method: "fs/changed",
                            params: .object([
                                "watchId": .string(watchID),
                                "changedPaths": .array(
                                    changedPaths.map(
                                        CodexJSONValue.string
                                    )
                                ),
                            ]),
                            metadata: [:]
                        )
                    )
                    self?.record("mcp-notification fs/changed")
                }
            }
            fuzzyFileSearchService =
                CodexDesktopFuzzyFileSearchService {
                    [weak self] method, params in
                    Task { @MainActor [weak self] in
                        await self?.send(
                            .mcpNotification(
                                hostID: "local",
                                method: method,
                                params: params,
                                metadata: [:]
                            )
                        )
                        self?.record(
                            "mcp-notification \(method)"
                        )
                    }
                }
            configureHostCallbacks()
            approvalBroker = CodexDesktopApprovalBroker(
                send: { [weak self] message in
                    await self?.send(message)
                }
            )
            requestUserInputBroker =
                CodexDesktopRequestUserInputBroker(
                    send: { [weak self] message in
                        await self?.send(message)
                    }
                )
            let nativeAppServerRequestHandler =
                CodexDesktopAppServerRequestHandler(
                    refreshCredentials: {
                        [weak self] _ in
                        guard let self else {
                            throw CodexAccountCredentialRefreshError
                                .signedOut
                        }
                        return try await self
                            .credentialRefreshAdapter
                            .refresh()
                    },
                    planType: { [weak accountStore] in
                        accountStore?.planType?.rawValue
                    },
                    attestationProvider:
                        CodexDesktopPlatformDeviceCheckTokenProvider()
                )
            serverRequestBroker = CodexDesktopServerRequestBroker(
                nativeHandler: { method, params in
                    try await nativeAppServerRequestHandler.handle(
                        method: method,
                        params: params
                    )
                },
                send: { [weak self] message in
                    await self?.send(message)
                }
            )
            commandExecutor.configureOutputSink {
                [weak self] output in
                await self?.sendCommandOutput(output)
            }
            commandExecutor.configureProcessSinks(
                output: { [weak self] output in
                    await self?.sendProcessOutput(output)
                },
                exited: { [weak self] exited in
                    await self?.sendProcessExited(exited)
                }
            )
            commandExecutor.configureUnifiedOutputSink {
                [weak self] output in
                await self?.sendTurnNotification(
                    .commandExecutionOutputDelta(output)
                )
            }
            commandExecutor.configureUnifiedTerminalInteractionSink {
                [weak self] interaction in
                await self?.sendTurnNotification(
                    .terminalInteraction(interaction)
                )
            }
            configureLoginCoordinator(
                accountStore: accountStore
            )
            let mcpConfigurationStore = CodexMCPConfigurationStore(
                configStore: self.configStore
            )
            let mcpCredentialStore =
                CodexMCPOAuthCredentialStore()
            let mcpRuntimeRegistry = CodexMCPRuntimeRegistry(
                configurationProvider: {
                    try mcpConfigurationStore.readAll()
                },
                credentialProvider: { name in
                    try mcpCredentialStore.load(
                        serverName: name
                    )
                },
                connector: CodexMCPCompositeConnector(
                    serverRequestHandler: { [weak self] method, params in
                        guard let self else {
                            throw CodexMCPServerRequestError.invalidRequest
                        }
                        let threadID: String?
                        if case let .object(fields)? = params,
                           case let .string(value)? = fields["threadId"],
                           !value.isEmpty
                        {
                            threadID = value
                        } else {
                            threadID = nil
                        }
                        return try await self.serverRequestBroker?.request(
                            method: method,
                            params: params,
                            threadID: threadID
                        ) ?? .null
                    }
                )
            )
            self.mcpRuntimeRegistry = mcpRuntimeRegistry
            let applicationSupport =
                fileManager.urls(
                    for: .applicationSupportDirectory,
                    in: .userDomainMask
                ).first ?? fileManager.temporaryDirectory
            let codexHome = applicationSupport
                .appendingPathComponent(
                    "CodexPad/CodexHome",
                    isDirectory: true
                )
            let bundledSkillsRepoRoot =
                Bundle.main.resourceURL?.appendingPathComponent(
                    "skills",
                    isDirectory: true
                )
            self.skillCatalog = CodexSkillCatalogService(
                userRoots: [
                    URL(
                        fileURLWithPath: NSHomeDirectory(),
                        isDirectory: true
                    )
                        .appendingPathComponent(
                            ".codex/skills",
                            isDirectory: true
                        ),
                    codexHome.appendingPathComponent(
                        "skills",
                        isDirectory: true
                    ),
                ],
                systemRoots:
                    bundledSkillsRepoRoot.map { [$0] }
                    ?? [],
                userDefaults: userDefaults,
                fileManager: fileManager
            )
            self.recommendedSkillService =
                CodexRecommendedSkillService(
                    bundledRepoRoot:
                        bundledSkillsRepoRoot,
                    vendorRepoRoot:
                        codexHome.appendingPathComponent(
                            "vendor_imports/skills",
                            isDirectory: true
                        ),
                    defaultInstallRoot:
                        codexHome.appendingPathComponent(
                            "skills",
                            isDirectory: true
                        ),
                    fileManager: fileManager
                )
            self.skillCatalog?.setPluginCacheRoots([
                codexHome.appendingPathComponent(
                    "plugins/cache",
                    isDirectory: true
                ).path
            ])
            do {
                automationStore =
                    try CodexDesktopAutomationStore(
                        codexHome: codexHome,
                        fileManager: fileManager
                    )
            } catch {
                diagnostics.append(
                    "automation-store failure "
                        + CodexDiagnosticSanitization.publicErrorSummary(error)
                )
            }
            self.memoryResetService =
                CodexDesktopMemoryResetService(
                    codexHome: codexHome,
                    fileManager: fileManager
                )
            self.hookCatalog = CodexHookCatalogService(
                codexHome: codexHome,
                fileManager: fileManager
            )
            self.appCatalog = CodexAppCatalogService(
                codexHome: codexHome,
                fileManager: fileManager
            )
            self.settingsCatalog =
                CodexExperimentalSettingsService(
                    configStore: configStore
                )
            var marketplacePaths = [
                codexHome.appendingPathComponent(
                    ".agents/plugins/marketplace.json"
                )
            ]
            let workspaceAccess = CodexWorkspaceAccess()
            marketplacePaths += sessionStore.state.workspaces
                .compactMap { workspace -> URL? in
                    guard let bookmark =
                        workspace.rootBookmarkID,
                        let root = try? workspaceAccess.resolve(
                            bookmark
                        )
                    else {
                        return nil
                    }
                    return root.appendingPathComponent(
                        ".agents/plugins/marketplace.json"
                    )
                }
            if let bundledMarketplace =
                Bundle.main.url(
                    forResource: "marketplace",
                    withExtension: "json",
                    subdirectory: "plugins"
                )
            {
                marketplacePaths.append(bundledMarketplace)
            }
            let marketplaceManager =
                CodexMarketplaceManagementService(
                    codexHome: codexHome,
                    configStore: configStore,
                    fileManager: fileManager
                )
            self.marketplaceManager = marketplaceManager
            self.pluginCatalog = CodexPluginCatalogService(
                marketplacePaths: marketplacePaths,
                additionalMarketplacePaths: {
                    [weak marketplaceManager] in
                    marketplaceManager?
                        .configuredMarketplaceManifestPaths()
                        ?? []
                },
                cacheRoot: codexHome.appendingPathComponent(
                    "plugins/cache",
                    isDirectory: true
                ),
                fileManager: fileManager
            )
            self.remotePluginCatalog =
                CodexRemotePluginService(
                    credentialsProvider: {
                        [weak accountStore] in
                        accountStore?.chatGPTCredentials()
                    },
                    transport:
                        CodexDesktopURLSessionNetworkFetchTransport(),
                    baseURL:
                        CodexDesktopNetworkFetchClient
                            .releasedProductAPIBaseURL,
                    codexHome: codexHome,
                    homeDirectory: codexHome
                )
            self.externalAgentConfigMigrationService =
                CodexExternalAgentConfigMigrationService(
                    codexHome: codexHome,
                    userHome: URL(
                        fileURLWithPath: NSHomeDirectory(),
                        isDirectory: true
                    ),
                    configStore: configStore,
                    fileManager: fileManager,
                    sendNotification: {
                        [weak self] method, params in
                        await self?.send(
                            .mcpNotification(
                                hostID: "local",
                                method: method,
                                params: params,
                                metadata: [:]
                            )
                        )
                        self?.record(
                            "mcp-notification \(method)"
                        )
                    }
                )
            self.feedbackUploadService =
                CodexFeedbackUploadService(
                    diagnosticsProvider: {
                        [weak self] in
                        self?.diagnostics ?? []
                    },
                    fileManager: fileManager
                )
            self.environmentService = CodexEnvironmentService()
            self.realtimeService = CodexRealtimeService(
                credentialsProvider: {
                    [weak accountStore] in
                    accountStore?.chatGPTCredentials()
                },
                notificationSink: {
                    [weak self] method, params in
                    let message = CodexDesktopHostMessage.mcpNotification(
                        hostID: "local",
                        method: method,
                        params: params,
                        metadata: [:]
                    )
                    await self?.broadcastRealtimeNotification(message)
                    // WebKit does not reliably deliver a host JavaScript call
                    // re-entrantly while the renderer is still awaiting the
                    // native reply to `thread/realtime/start`. Electron's IPC
                    // queues this notification naturally. Replay only the SDP
                    // after that request has unwound so the released renderer
                    // can apply the answer to its pending peer connection.
                    if method == "thread/realtime/sdp" {
                        Task { @MainActor [weak self] in
                            try? await Task.sleep(
                                for: .milliseconds(300)
                            )
                            await self?.send(
                                .mcpNotification(
                                    hostID: "local",
                                    method: method,
                                    params: params,
                                    metadata: [:]
                                )
                            )
                        }
                    }
                    await MainActor.run { [weak self] in
                        guard let self else { return }
                        let realtimeTimestamp = Int64(
                            Date().timeIntervalSince1970 * 1_000
                        )
                        self.userDefaults.set(
                            method,
                            forKey:
                                "codex.desktop.last-realtime-notification-method"
                        )
                        self.userDefaults.set(
                            realtimeTimestamp,
                            forKey:
                                "codex.desktop.last-realtime-notification-timestamp-ms"
                        )
                        if method == "thread/realtime/sdp" {
                            if case let .object(fields) = params {
                                let threadID: String
                                if case let .string(value)? = fields["threadId"] {
                                    threadID = value
                                } else {
                                    threadID = ""
                                }
                                let sdpLength: Int
                                if case let .string(value)? = fields["sdp"] {
                                    sdpLength = value.count
                                } else {
                                    sdpLength = 0
                                }
                                self.record(
                                    "realtime-sdp-send thread="
                                        + threadID
                                        + " length=\(sdpLength)"
                                )
                            }
                            self.userDefaults.removeObject(
                                forKey:
                                    "codex.desktop.last-realtime-error-message"
                            )
                            self.userDefaults.removeObject(
                                forKey:
                                    "codex.desktop.last-realtime-closed-timestamp-ms"
                            )
                        } else if method == "thread/realtime/started" {
                            self.userDefaults.set(
                                realtimeTimestamp,
                                forKey:
                                    "codex.desktop.last-realtime-started-timestamp-ms"
                            )
                        } else if method == "thread/realtime/closed" {
                            self.userDefaults.set(
                                realtimeTimestamp,
                                forKey:
                                    "codex.desktop.last-realtime-closed-timestamp-ms"
                            )
                        }
                        var diagnostic =
                            "mcp-notification \(method)"
                        if method == "thread/realtime/error",
                           case let .object(fields) = params,
                           case let .string(message)? =
                               fields["message"]
                        {
                            diagnostic +=
                                " message="
                                + String(message.prefix(512))
                            self.userDefaults.set(
                                String(message.prefix(512)),
                                forKey:
                                    "codex.desktop.last-realtime-error-message"
                            )
                        }
                        self.record(diagnostic)
                    }
                }
            )
            Task {
                try? await mcpRuntimeRegistry
                    .refreshMCPServers()
            }
            let resolvedMCPOAuthDriver =
                mcpOAuthDriver
                ?? CodexDesktopMCPOAuthLoopbackDriver(
                    configurationProvider: { name in
                        try mcpConfigurationStore
                            .readAll()[name]
                    },
                    serverStarter: CodexLoopbackHTTPServerFactory(),
                    flowClient: CodexMCPOAuthHTTPClient(),
                    credentialStore: mcpCredentialStore,
                    invalidateRuntime: {
                        try? await mcpRuntimeRegistry
                            .refreshMCPServers()
                    }
                )
            mcpOAuthCoordinator =
                CodexDesktopMCPOAuthCoordinator(
                    driver: resolvedMCPOAuthDriver,
                    sendNotification: { [weak self] message in
                        await self?.send(message)
                    }
                )
            configureWorkspaceOnboarding()
            if let turnProviderFactory {
                desktopTurnRunner =
                    CodexDesktopTurnSessionRunner(
                sessionStore: sessionStore,
                providerFactory: turnProviderFactory,
                toolExecutorFactory: turnToolExecutorFactory,
                approvalRequester: { [weak self] activity in
                    guard let broker = self?.approvalBroker else {
                        return false
                    }
                    return await broker.requestApproval(activity)
                },
                requestUserInputRequester: {
                    [weak self] prompt in
                    guard let broker =
                        self?.requestUserInputBroker
                    else {
                        throw
                            CodexDesktopRequestUserInputBrokerError
                                .cancelled
                    }
                    return try await broker.request(prompt)
                },
                notificationSink: { [weak self] notification in
                    self?.enqueueTurnNotification(notification)
                },
                appServerNotificationSink: { [weak self] notifications in
                    self?.enqueueAppServerNotifications(notifications)
                },
                lifecycleAnchor:
                    CodexDesktopConversationLifecycleAnchor(
                        store: lastActiveLocalThreadStore
                    )
                    )
            }
            let extendedSessionAdapter =
                CodexDesktopExtendedSessionAdapter(
                    threadStarter: sessionStore,
                    runner: desktopTurnRunner,
                    feedbackUploader: feedbackUploadService,
                    sandboxStore:
                        CodexDesktopInteractiveSessionSandboxStore(
                            root: codexHome.appendingPathComponent(
                                "interactive-sessions",
                                isDirectory: true
                            )
                        )
                )
            self.extendedSessionAdapter =
                extendedSessionAdapter
            let extendedSessionHandler:
                CodexDesktopExtendedSessionBackend.Handler = {
                    [weak extendedSessionAdapter] request in
                    guard let extendedSessionAdapter else {
                        throw
                            CodexDesktopExtendedSessionBackend
                                .Error
                                .handlerUnavailable(
                                    request.method
                                )
                    }
                    return try await extendedSessionAdapter
                        .handle(request)
                }
            self.extendedSessionBackend =
                CodexDesktopExtendedSessionBackend(
                    handlers: .init(
                        threadStartAeon:
                            extendedSessionHandler,
                        threadStop:
                            extendedSessionHandler,
                        interactiveLiveSessionsList:
                            extendedSessionHandler,
                        interactiveSessionUpload:
                            extendedSessionHandler,
                        interactiveSessionSandboxList:
                            extendedSessionHandler,
                        interactiveSessionSandboxRead:
                            extendedSessionHandler
                    )
                )
            configureAppHostSessions()
            mcpRuntimeRegistry.configureProgressSink {
                [weak self] progress in
                await MainActor.run {
                    self?.desktopTurnRunner?
                        .emitMCPToolProgress(progress)
                }
            }
            if let automationStore {
                let automationSessionRunner:
                    CodexDesktopAutomationSessionRunner
                if let desktopTurnRunner {
                    automationSessionRunner =
                        CodexDesktopAutomationSessionRunner(
                            threadReader: sessionStore,
                            threadResumer: sessionStore,
                            threadStarter: sessionStore,
                            turnStarter: desktopTurnRunner,
                            threadSettingsUpdater: sessionStore
                        )
                } else {
                    automationSessionRunner =
                        CodexDesktopAutomationSessionRunner(
                            threadReader: sessionStore,
                            threadResumer: sessionStore,
                            threadStarter: sessionStore,
                            turnStarter: sessionStore,
                            threadSettingsUpdater: sessionStore
                        )
                }
                automationScheduler =
                    CodexDesktopAutomationScheduler(
                        store: automationStore,
                        onStateChange: {
                            [weak self] in
                            await self?.sendInboxItemsChanged()
                        },
                        runner: { request in
                            try automationSessionRunner.run(
                                request
                            )
                        }
                    )
            }
        }

        public func persistedTurnOfficialToolSearchSources()
            -> [CodexOfficialToolSearchSource]
        {
            mcpRuntimeRegistry?.officialToolSearchSources() ?? []
        }

        public func makePersistedTurnMCPResourceExecutor()
            -> CodexPersistedTurnMCPResourceExecutor?
        {
            guard let mcpRuntimeRegistry else {
                return nil
            }
            return CodexPersistedTurnMCPResourceExecutor(
                runtimeRegistry: mcpRuntimeRegistry
            )
        }

        public func makePersistedTurnToolSearchExecutor(
            threadID: CodexStoredThreadID
        ) -> CodexPersistedTurnToolSearchExecutor? {
            guard let mcpRuntimeRegistry else {
                return nil
            }
            return mcpRuntimeRegistry.makeToolSearchExecutor(
                threadID: threadID
            )
        }

        public func saveGitCredential(
            username: String,
            password: String
        ) throws {
            try gitCredentialStore.save(
                CodexGitCredential(
                    username: username,
                    password: password
                )
            )
        }

        public func deleteGitCredential() throws {
            try gitCredentialStore.delete()
        }

        public func gitCredential(
            forRepositoryAt _: String
        ) throws -> CodexDesktopGitCredential? {
            guard let credential = try gitCredentialStore.load()
            else {
                return nil
            }
            return CodexDesktopGitCredential(
                username: credential.username,
                password: credential.password
            )
        }

        public func startIfNeeded() {
            guard !hasStarted else {
                return
            }
            hasStarted = true
            automationScheduler?.start()
            verifyAndLoadReleasedSurface()
        }

        public var remoteControlInstallationID: String {
            installationID()
        }

        public func installRemoteControlBridge(
            _ bridge: CodexRemoteControlMCPBridge
        ) {
            remoteControlStatusTask?.cancel()
            remoteControlStatusTask = nil
            remoteControlBridge = bridge
        }

        public func retry() {
            guard let host else {
                return
            }
            approvalBroker?.cancelAll()
            requestUserInputBroker?.cancelAll()
            dynamicToolCallBroker?.cancelAll()
            serverRequestBroker?.cancelAll()
            do {
                try host.retry()
                resetHomeDataGate()
                verifyAndLoadReleasedSurface()
            } catch {
                recordFailure(error)
            }
        }

        public func completeWorkspacePicker(
            _ result: Result<[URL], any Error>
        ) {
            isWorkspacePickerPresented = false
            switch result {
            case let .success(urls):
                Task { @MainActor [weak self] in
                    guard let self,
                          let workspaceOnboardingCoordinator
                    else {
                        return
                    }
                    await workspaceOnboardingCoordinator
                        .completePicker(urls: urls)
                }
            case let .failure(error):
                if (error as NSError).code
                    == NSUserCancelledError
                {
                    Task { @MainActor [weak self] in
                        guard let self,
                              let workspaceOnboardingCoordinator
                        else {
                            return
                        }
                        await workspaceOnboardingCoordinator
                            .completePicker(urls: [])
                    }
                } else {
                    record(
                        "workspace-picker failure "
                            + CodexDiagnosticSanitization.publicErrorSummary(error)
                    )
                }
            }
        }

        public func pickDesktopFiles(
            allowsMultipleSelection: Bool,
            imagesOnly: Bool,
            pickerTitle _: String?
        ) async throws -> [URL] {
            guard desktopFilePickerContinuation == nil else {
                throw CodexDesktopFileInteractionError
                    .interactionInProgress
            }
            desktopFilePickerAllowsMultipleSelection =
                allowsMultipleSelection
            desktopFilePickerImagesOnly = imagesOnly
            return try await withCheckedThrowingContinuation {
                continuation in
                desktopFilePickerContinuation = continuation
                isDesktopFilePickerPresented = true
                record(
                    "desktop-file-picker requested multiple="
                        + "\(allowsMultipleSelection)"
                        + " imagesOnly=\(imagesOnly)"
                )
            }
        }

        public func completeDesktopFilePicker(
            _ result: Result<[URL], any Error>
        ) {
            isDesktopFilePickerPresented = false
            guard let continuation =
                desktopFilePickerContinuation
            else {
                return
            }
            desktopFilePickerContinuation = nil
            switch result {
            case let .success(urls):
                let selected = desktopFilePickerAllowsMultipleSelection
                    ? urls
                    : Array(urls.prefix(1))
                for url in selected
                where url.startAccessingSecurityScopedResource() {
                    securityScopedDesktopFileLeases.append(
                        CodexDesktopSecurityScopedFileLease(url: url)
                    )
                }
                continuation.resume(returning: selected)
            case let .failure(error):
                if (error as NSError).code
                    == NSUserCancelledError
                {
                    continuation.resume(returning: [])
                } else {
                    continuation.resume(throwing: error)
                }
            }
        }

        public func releaseDesktopFiles(_ urls: [URL]) {
            for url in urls {
                guard let index =
                    securityScopedDesktopFileLeases.firstIndex(
                        where: { $0.url == url }
                    )
                else {
                    continue
                }
                securityScopedDesktopFileLeases.remove(at: index)
            }
        }

        public func saveDesktopFile(
            suggestedFilename: String,
            contents: Data
        ) async throws -> URL? {
            guard desktopFileExporterContinuation == nil else {
                throw CodexDesktopFileInteractionError
                    .interactionInProgress
            }
            desktopFileExportSuggestedFilename =
                suggestedFilename
            desktopFileExportContents = contents
            return try await withCheckedThrowingContinuation {
                continuation in
                desktopFileExporterContinuation = continuation
                isDesktopFileExporterPresented = true
                record(
                    "desktop-file-exporter requested "
                        + suggestedFilename
                )
            }
        }

        public func completeDesktopFileExporter(
            _ result: Result<URL, any Error>
        ) {
            isDesktopFileExporterPresented = false
            guard let continuation =
                desktopFileExporterContinuation
            else {
                return
            }
            desktopFileExporterContinuation = nil
            switch result {
            case let .success(url):
                continuation.resume(returning: url)
            case let .failure(error):
                if (error as NSError).code
                    == NSUserCancelledError
                {
                    continuation.resume(returning: nil)
                } else {
                    continuation.resume(throwing: error)
                }
            }
        }

        public func addDesktopContextFile(
            path: String,
            origin _: CodexJSONValue
        ) async throws {
            let normalized = URL(
                fileURLWithPath: path
            ).standardizedFileURL.path
            await send(
                .event(
                    type: "add-context-file",
                    payload: .object([
                        "file": .object([
                            "label": .string(
                                URL(
                                    fileURLWithPath: normalized
                                ).lastPathComponent
                            ),
                            "path": .string(normalized),
                            "fsPath": .string(normalized),
                        ])
                    ])
                )
            )
        }

        public func performManagedWorktreeRequest(
            workerMethod: String,
            params: CodexJSONValue
        ) async throws -> CodexJSONValue {
            let result = try await gitWorker.handle(
                CodexDesktopWorkerRequest(
                    workerID: "git",
                    id: UUID().uuidString.lowercased(),
                    method: workerMethod,
                    params: params
                ),
                emit: { [weak self] event in
                    await self?.forwardManagedWorktreeEvent(event)
                }
            )
            if workerMethod == "delete-worktree",
               case let .object(fields) = params,
               case let .string(hostID)? = fields["hostId"]
            {
                await send(
                    .event(
                        type: "worktrees-reload-requested",
                        payload: .object([
                            "hostId": .string(hostID)
                        ])
                    )
                )
            }
            return result
        }

        /// Supplies the native recovery surfaces with the same command and
        /// Git boundaries used by the released desktop surface.  The bridge
        /// is deliberately explicit: native buttons either reach a backend or
        /// surface its error; they never use an empty SwiftUI action.
        public func makeNativeSurfaceActionBridge()
            -> CodexNativeSurfaceActionBridge
        {
            CodexNativeSurfaceActionBridge(
                revert: { [weak self] cwd in
                    guard let self else {
                        throw CancellationError()
                    }
                    let result = try await self.commandExecutor.execute(
                        CodexDesktopCommandExecParams(
                            command: [
                                "git", "restore", "--worktree",
                                "--staged", "--", ".",
                            ],
                            processID: nil,
                            tty: false,
                            streamStdin: false,
                            streamStdoutStderr: false,
                            outputBytesCap: 1_048_576,
                            disableOutputCap: false,
                            disableTimeout: false,
                            timeoutMs: 30_000,
                            cwd: cwd,
                            environment: nil,
                            size: nil,
                            sandboxPolicy: nil
                        ),
                        allowedRoots: [cwd]
                    )
                    return result.json
                },
                commit: { [weak self] cwd, message in
                    guard let self else {
                        throw CancellationError()
                    }
                    return try await self.performManagedWorktreeRequest(
                        workerMethod: "commit",
                        params: .object([
                            "cwd": .string(cwd),
                            "message": .string(message),
                            "includeUnstaged": .bool(true),
                        ])
                    )
                },
                terminal: { [weak self] cwd, command in
                    guard let self else {
                        throw CancellationError()
                    }
                    let result = try await self.commandExecutor.execute(
                        CodexDesktopCommandExecParams(
                            command: ["sh", "-lc", command],
                            processID: nil,
                            tty: false,
                            streamStdin: false,
                            streamStdoutStderr: false,
                            outputBytesCap: 1_048_576,
                            disableOutputCap: false,
                            disableTimeout: false,
                            timeoutMs: 30_000,
                            cwd: cwd,
                            environment: nil,
                            size: nil,
                            sandboxPolicy: nil
                        ),
                        allowedRoots: [cwd]
                    )
                    return result.json
                }
            )
        }

        public func uploadWorktreeSnapshot(
            tarballPath: String,
            uploadURL: URL,
            contentLength: Int64,
            contentType: String
        ) async throws {
            let tarballURL = URL(
                fileURLWithPath: tarballPath
            ).standardizedFileURL
            let attributes = try FileManager.default
                .attributesOfItem(atPath: tarballURL.path)
            guard let actualLength =
                attributes[.size] as? NSNumber,
                actualLength.int64Value == contentLength
            else {
                throw CodexDesktopWorkerMethodError(
                    "Worktree snapshot content length mismatch"
                )
            }
            var request = URLRequest(url: uploadURL)
            request.httpMethod = "PUT"
            request.setValue(
                contentType,
                forHTTPHeaderField: "Content-Type"
            )
            request.setValue(
                String(contentLength),
                forHTTPHeaderField: "Content-Length"
            )
            let (_, response) = try await URLSession.shared.upload(
                for: request,
                fromFile: tarballURL
            )
            guard let httpResponse =
                response as? HTTPURLResponse,
                (200 ..< 300).contains(
                    httpResponse.statusCode
                )
            else {
                throw CodexDesktopWorkerMethodError(
                    "Worktree snapshot upload failed"
                )
            }
        }

        private func forwardManagedWorktreeEvent(
            _ event: CodexJSONValue
        ) async {
            guard case var .object(fields) = event,
                  case let .string(type)? =
                    fields.removeValue(forKey: "type")
            else {
                return
            }
            await send(
                .event(
                    type: type,
                    payload: .object(fields)
                )
            )
        }

        private func configureHostCallbacks() {
            guard let host else {
                return
            }
            host.onStateChange = { [weak self] state in
                guard let self else {
                    return
                }
                self.surfaceState = state
                if state == .awaitingBridgeReady {
                    self.startupGate.observeDocumentLoaded()
                }
                self.record("state=\(String(describing: state))")
                self.openHomeDataGateIfReady()
            }
            host.onEvent = { [weak self] event in
                guard let self else {
                    return
                }
                Task { @MainActor in
                    await self.handle(event)
                }
            }
            host.onNativeChannel = {
                [weak self] name, payload in
                guard let self else {
                    return nil
                }
                return try await self.handleNativeChannel(
                    name: name,
                    payload: payload
                )
            }
            host.onHardwareShortcut = { [weak self] shortcut in
                self?.performNativeShortcut(shortcut)
            }
        }

        private func configureAvatarOverlayHostCallbacks(
            _ overlayHost: CodexDesktopWebViewHost
        ) {
            overlayHost.onStateChange = { [weak self] state in
                self?.record(
                    "avatar-overlay state="
                        + String(describing: state)
                )
            }
            overlayHost.onEvent = { [weak self] event in
                guard let self else {
                    return
                }
                Task { @MainActor in
                    if event == .rendererReady {
                        self.record("avatar-overlay renderer-ready")
                        if overlayHost.state == .awaitingHomeData {
                            do {
                                try overlayHost.markHomeDataLoaded()
                                self.record(
                                    "avatar-overlay home-data-ready"
                                )
                            } catch {
                                self.recordFailure(error)
                            }
                        }
                    } else {
                        await self.handle(
                            event,
                            replyHost: overlayHost
                        )
                    }
                }
            }
            overlayHost.onNativeChannel = {
                [weak self] name, payload in
                guard let self else {
                    return nil
                }
                if name
                    == CodexDesktopRendererRouteObservationScript
                        .messageChannel
                {
                    if case let .object(fields) = payload,
                       case let .string(path)? = fields["path"]
                    {
                        self.record(
                            "avatar-overlay renderer-route \(path)"
                        )
                    }
                    return nil
                }
                return try await self.handleNativeChannel(
                    name: name,
                    payload: payload
                )
            }
        }

        private func presentAvatarOverlayIfNeeded() throws {
            if avatarOverlayHost == nil {
                guard let avatarOverlayBootstrap else {
                    throw CodexDesktopWebViewHostError
                        .invalidScriptMessagePayload
                }
                let createdHost = try CodexDesktopWebViewHost(
                    bootstrap: avatarOverlayBootstrap
                        .scopedToAppHostPortIDPrefix(
                            "avatar-overlay-app-host"
                        )
                )
                createdHost.webView.isOpaque = false
                createdHost.webView.backgroundColor = .clear
                createdHost.webView.scrollView.backgroundColor = .clear
                createdHost.setAvatarOverlayInputShape([])
                configureAvatarOverlayHostCallbacks(createdHost)
                let plan = try CodexDesktopWebViewResourceLocator.resolve(
                    bundle: .main,
                    initialRoute: "/avatar-overlay"
                )
                try createdHost.loadVerifiedSurface(plan)
                avatarOverlayHost = createdHost
            }
            isAvatarOverlayPresented = true
        }

        private func publishAvatarOverlayOpenState() async {
            let message = CodexDesktopHostMessage.event(
                type: "avatar-overlay-open-state-changed",
                payload: .object([
                    "isOpen": .bool(avatarOverlayState.isOpen)
                ])
            )
            await send(message)
            if let avatarOverlayHost {
                try? await avatarOverlayHost.send(message)
            }
        }

        private func handleAvatarOverlayViewEvent(
            type: String
        ) async -> Bool {
            let effect = avatarOverlayState.handle(type: type)
            switch effect {
            case .ignored:
                return false
            case .handled:
                record("avatar-overlay \(type)")
            case .reportOpenState:
                await publishAvatarOverlayOpenState()
            case let .presentationChanged(isOpen):
                if isOpen {
                    do {
                        try presentAvatarOverlayIfNeeded()
                    } catch {
                        avatarOverlayState =
                            CodexDesktopAvatarOverlayState()
                        isAvatarOverlayPresented = false
                        recordFailure(error)
                    }
                } else {
                    isAvatarOverlayPresented = false
                }
                await publishAvatarOverlayOpenState()
                record("avatar-overlay presented=\(isOpen)")
            }
            return true
        }

        private func captureAppshotSnapshot() async throws
            -> CodexDesktopAppshotSnapshot
        {
            guard let webView = host?.webView else {
                throw CodexDesktopAppshotCaptureError
                    .webViewUnavailable
            }
            return try await withCheckedThrowingContinuation {
                continuation in
                webView.takeSnapshot(with: nil) { image, error in
                    if let error {
                        continuation.resume(throwing: error)
                        return
                    }
                    guard let image,
                          image.size.height > 0
                    else {
                        continuation.resume(
                            throwing:
                                CodexDesktopAppshotCaptureError
                                .snapshotUnavailable
                        )
                        return
                    }
                    guard let pngData = image.pngData() else {
                        continuation.resume(
                            throwing:
                                CodexDesktopAppshotCaptureError
                                .pngEncodingFailed
                        )
                        return
                    }
                    continuation.resume(
                        returning: CodexDesktopAppshotSnapshot(
                            screenshotDataURL:
                                "data:image/png;base64,"
                                + pngData.base64EncodedString(),
                            height: image.size.height
                        )
                    )
                }
            }
        }

        private func configureAppHostSessions() {
            let embeddedRuntimeInstalled =
                Bundle.main.url(
                    forResource: "codex-node-mcp-host",
                    withExtension: "js",
                    subdirectory: "NodeRuntime"
                ) != nil
            let interactionService =
                CodexDesktopInteractionAppHostService(
                    primaryRuntimeVersion:
                        embeddedRuntimeInstalled
                        ? CodexBuildMetadata.desktopVersion : nil,
                    primaryRuntimeInstalled:
                        embeddedRuntimeInstalled,
                    eventHandler: {
                        [weak self] service, method, arguments in
                        await MainActor.run {
                            self?.record(
                                "app-host interaction "
                                    + "\(service).\(method)"
                            )
                        }
                        guard service == "quickChatWindow",
                              method == "addToComposer",
                              let arguments,
                              case let .object(fields)? = arguments.first,
                              case let .string(conversationID)? =
                                fields["conversationId"],
                              !conversationID.isEmpty
                        else {
                            return
                        }
                        var payload: [String: CodexJSONValue] = [
                            "conversationId": .string(conversationID)
                        ]
                        if let title = fields["title"],
                           let titleValue = Self.codexJSONValue(title)
                        {
                            payload["title"] = titleValue
                        }
                        let message = CodexDesktopHostMessage.event(
                            type: "add-quick-chat-to-codex",
                            payload: .object(payload)
                        )
                        await self?.send(message)
                    }
                )
            let remoteControlEnvironmentBackend =
                CodexDesktopRemoteControlEnvironmentBackend(
                    credentialsProvider: {
                        [weak self] in
                        await MainActor.run {
                            self?.accountStore?
                                .chatGPTCredentials()
                        }
                    }
                )
            let appshotHotkeyOperation:
                CodexDesktopPeripheralAppHostService.Operation = {
                    [weak self] method, arguments in
                    switch method {
                    case "getState":
                        guard let coordinator = await MainActor.run(
                            body: { self?.appshotCaptureCoordinator }
                        ) else {
                            return CodexDesktopPeripheralAppHostService
                                .unsupportedAppshotState
                        }
                        return await coordinator.appHostState()
                    case "setHotkey":
                        throw CodexDesktopPeripheralAppHostService
                            .Error.unavailable(
                                service: "appshot",
                                method: method
                            )
                    case "requestFinalUpdate":
                        break
                    default:
                        return .bool(false)
                    }
                    guard case let .object(fields)? = arguments?.first,
                          case let .string(requestID)? =
                            fields["requestId"]
                    else {
                        return .bool(false)
                    }
                    guard let coordinator = await MainActor.run(
                        body: { self?.appshotCaptureCoordinator }
                    ) else {
                        return .bool(false)
                    }
                    return .bool(
                        await coordinator.requestFinalUpdate(
                            requestID: requestID
                        )
                    )
                }
            let metadataGenerator = turnProviderFactory.map {
                CodexDesktopThreadMetadataGenerator(
                    providerFactory: $0,
                    history: sessionStore
                )
            }
            let pullRequestGenerator = turnProviderFactory.map {
                CodexDesktopPullRequestMessageGenerator(
                    providerFactory: $0
                )
            }
            let peripheralService:
                CodexDesktopPeripheralAppHostService
            if let pullRequestGenerator {
                peripheralService =
                    CodexDesktopPeripheralAppHostService(
                        appshotHotkeyOperation:
                            appshotHotkeyOperation,
                        hotkeyWindowOperation: {
                            method, arguments in
                            try await interactionService.invoke(
                                service: "hotkeyWindowHotkeys",
                                method: method,
                                arguments: arguments
                            )
                        },
                        remoteControlEnvironmentOperation: {
                            method, arguments in
                            try await remoteControlEnvironmentBackend
                                .invoke(
                                    method: method,
                                    arguments: arguments
                                )
                        },
                        pullRequestGenerationOperation: {
                            [weak self] request in
                            let cwd = await MainActor.run {
                                self?.activeWorkspaceRoots().first
                                    ?? self?
                                    .projectlessOutputDirectoryStore
                                    .workspaceRoot.path
                                    ?? FileManager.default
                                    .temporaryDirectory.path
                            }
                            return try await pullRequestGenerator
                                .start(request, cwd: cwd)
                        },
                        pullRequestGenerationWait: {
                            operation in
                            try await pullRequestGenerator.wait(
                                for: operation
                            )
                        },
                        pullRequestGenerationCancel: {
                            operation in
                            Task { @MainActor in
                                pullRequestGenerator.cancel(operation)
                            }
                        },
                        pullRequestGenerationRelease: {
                            operation in
                            Task { @MainActor in
                                pullRequestGenerator.release(operation)
                            }
                        }
                    )
            } else {
                peripheralService =
                    CodexDesktopPeripheralAppHostService(
                        appshotHotkeyOperation:
                            appshotHotkeyOperation,
                        hotkeyWindowOperation: {
                            method, arguments in
                            try await interactionService.invoke(
                                service: "hotkeyWindowHotkeys",
                                method: method,
                                arguments: arguments
                            )
                        },
                        remoteControlEnvironmentOperation: {
                            method, arguments in
                            try await remoteControlEnvironmentBackend
                                .invoke(
                                    method: method,
                                    arguments: arguments
                                )
                        }
                    )
            }
            let intelligenceService =
                CodexDesktopIntelligenceAppHostService(
                    hasAccessibleAndEnabledApp: {
                        [weak self] in
                        await MainActor.run {
                            self?.appCatalog?
                                .installedApps(
                                    forceRefresh: false
                                )
                                .contains(where: \.callable)
                                ?? false
                        }
                    },
                    generateTitle: { request in
                        guard let metadataGenerator else {
                            return nil
                        }
                        return try await metadataGenerator
                            .generateTitle(request)
                    },
                    generateDescription: { request in
                        guard let metadataGenerator else {
                            return nil
                        }
                        return try await metadataGenerator
                            .generateDescription(request)
                    },
                    reconsiderTitle: { request in
                        guard let metadataGenerator else {
                            return nil
                        }
                        return try await metadataGenerator
                            .reconsiderTitle(request)
                    },
                    generateSummary: { request in
                        guard let metadataGenerator else {
                            return nil
                        }
                        return try await metadataGenerator
                            .generateSummary(request)
                    }
                )
            let coordinationService =
                CodexDesktopCoordinationAppHostService(
                    eventHandler: {
                        [weak self] service, method, arguments in
                        if let message = try?
                            CodexDesktopCoordinationAppHostService
                                .rendererEvent(
                                    method: method,
                                    arguments: arguments
                                )
                        {
                            await self?.send(message)
                        }
                        await MainActor.run {
                            self?.record(
                                "app-host coordination "
                                    + "\(service).\(method)"
                            )
                        }
                    }
                )
            let browserPageRestoreState =
                CodexDesktopBrowserPageRestoreState()
            let browserService =
                CodexDesktopBrowserAppHostService(
                    pageRestoreState: browserPageRestoreState,
                    eventHandler: {
                        [weak self] service, method, arguments in
                        if service == "chromiumBrowser",
                           method == "openUrl",
                           case let .object(fields)? =
                               arguments?.first,
                           case let .string(rawURL)? = fields["url"],
                           let url = URL(string: rawURL)
                        {
                            _ = await Self.openExternalURL(url)
                        }
                        await MainActor.run {
                            self?.record(
                                "app-host browser "
                                    + "\(service).\(method)"
                            )
                        }
                    }
                )
            let applicationSupport = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first ?? FileManager.default.temporaryDirectory
            let visualizationsService =
                CodexDesktopVisualizationsAppHostService(
                    codexHome: applicationSupport
                        .appendingPathComponent(
                            "CodexPad/CodexHome",
                            isDirectory: true
                        ),
                    eventHandler: {
                        [weak self] method, _ in
                        await MainActor.run {
                            self?.record(
                                "app-host visualizations.\(method)"
                            )
                        }
                    }
                )
            let utilityService =
                CodexDesktopUtilityAppHostService(
                    codexHome: applicationSupport
                        .appendingPathComponent(
                            "CodexPad/CodexHome",
                            isDirectory: true
                        )
                )
            let appInfo = CodexDesktopInitialAppHostRouter.AppInfo(
                version: CodexBuildMetadata.desktopVersion,
                buildNumber: CodexBuildMetadata.desktopBuild,
                buildFlavor: "prod",
                osName: "iPadOS",
                systemVersion: UIDevice.current.systemVersion,
                appName: "Codex for ipad",
                appBrand: "codex"
            )
            let systemAppearance =
                UITraitCollection.current.userInterfaceStyle == .dark
                    ? "dark"
                    : "light"
            let documentsDirectory = fileManager.urls(
                for: .documentDirectory,
                in: .userDomainMask
            ).first ?? fileManager.temporaryDirectory
            let downloadsDirectory = documentsDirectory
                .appendingPathComponent(
                    "Downloads",
                    isDirectory: true
                )
            let authorizedWorkspaceRoots =
                workspaceRootOptions().map {
                    URL(
                        fileURLWithPath: $0,
                        isDirectory: true
                    ).standardizedFileURL
                }
            let selectedWorkspaceRoot =
                activeWorkspaceRoots().first.map {
                    URL(
                        fileURLWithPath: $0,
                        isDirectory: true
                    ).standardizedFileURL
                }
                ?? authorizedWorkspaceRoots.first
                ?? documentsDirectory
            let workspaceRegistry =
                CodexDesktopAppHostWorkspaceRegistry(
                    authorizedRoots: authorizedWorkspaceRoots,
                    selectedRoot: selectedWorkspaceRoot,
                    documentsRoot: documentsDirectory
                )
            let callbackDispatcher =
                CodexDesktopAppHostCallbackDispatcher()
            let realtimeRuntimeCoordinator =
                CodexDesktopRealtimeAppHostService.RuntimeCoordinator()
            let archiveBackend =
                CodexDesktopLocalProjectArchiveBackend(
                    threadMutator: sessionStore
                )
            let workspaceAccess = CodexWorkspaceAccess()
            let projectMutationBackend =
                CodexDesktopLocalProjectMutationBackend(
                    stateStore: localProjectsStateStore,
                    workspaceSnapshot: {
                        [weak sessionStore] in
                        sessionStore?.state.workspaces ?? []
                    },
                    threadSnapshot: {
                        [weak sessionStore] in
                        sessionStore?.state.threads ?? []
                    },
                    createWorkspace: {
                        [weak sessionStore] workspace in
                        guard let sessionStore else {
                            throw CodexSessionStoreError
                                .transportUnavailable
                        }
                        try sessionStore.openWorkspace(
                            id: workspace.id,
                            displayName: workspace.displayName,
                            rootBookmarkID:
                                workspace.rootBookmarkID
                        )
                    },
                    updateWorkspace: {
                        [weak sessionStore] workspace in
                        guard let sessionStore else {
                            throw CodexSessionStoreError
                                .transportUnavailable
                        }
                        try sessionStore.updateWorkspace(
                            id: workspace.id,
                            displayName: workspace.displayName,
                            rootBookmarkID:
                                workspace.rootBookmarkID
                        )
                    },
                    removeWorkspace: {
                        [weak sessionStore] workspaceID in
                        guard let sessionStore else {
                            throw CodexSessionStoreError
                                .transportUnavailable
                        }
                        try sessionStore.removeWorkspace(
                            id: workspaceID
                        )
                    },
                    bookmark: workspaceAccess.bookmark(for:),
                    createDefaultWorkspace: { [fileManager] name, initializeGitRepository in
                        try Self.createDefaultWorkspace(
                            named: name,
                            initializeGitRepository:
                                initializeGitRepository,
                            fileManager: fileManager
                        )
                    },
                    selectWorkspace: {
                        [weak sessionStore] workspaceID in
                        sessionStore?.selectedWorkspaceID =
                            workspaceID
                        if workspaceID == nil {
                            sessionStore?.selectedThreadID = nil
                        }
                    },
                    persistAppearance: {
                        [weak self] projectID, appearance in
                        self?.persistProjectAppearance(
                            projectID: projectID,
                            appearance: appearance
                        )
                    },
                    publishStateChange: {
                        [weak self] in
                        await self?
                            .publishLocalProjectsStateChange()
                    }
                )
            let remoteProjectMutationBackend =
                CodexDesktopRemoteProjectMutationBackend(
                    persistedAtoms: persistedAtoms,
                    localProjectIDs: {
                        self.localProjectsStateStore.projectsInOrder.map(\.id)
                    },
                    publishStateChange: { [weak self] keys in
                        await self?
                            .publishRemoteProjectsStateChange(
                                keys: keys
                            )
                    }
                )
            let terminalProcessDriver =
                CodexDesktopTerminalCommandProcessDriver(
                    commandExecutor: commandExecutor
                )
            let downloadsManager:
                CodexDesktopDownloadsManager
            do {
                downloadsManager =
                    try CodexDesktopDownloadsManager(
                        downloadsDirectory: downloadsDirectory,
                        openURL: { url in
                            await Self.openExternalURL(url)
                        },
                        revealURL: { url in
                            await Self.openExternalURL(url)
                        },
                        chooseDirectory: {
                            // iPadOS owns this app-scoped Downloads
                            // container; unlike macOS, it has no Finder
                            // directory chooser for changing that root.
                            downloadsDirectory
                        }
                    )
            } catch {
                recordFailure(error)
                return
            }
            let downloadsService =
                CodexDesktopDownloadsAppHostService(
                    manager: downloadsManager
                )
            let installationIdentity = installationID()
            let localThreadCatalogSessionStore = sessionStore
            let routerStore =
                CodexDesktopAppHostPortRouterStore {
                    [weak self] portID in
                    let workspaceSnapshot =
                        workspaceRegistry.snapshot()
                    let artifactDocumentsService =
                        CodexDesktopArtifactDocumentsAppHostService(
                            allowedWorkspaceRoots:
                                workspaceSnapshot.artifactRoots,
                            storeDirectory: applicationSupport
                                .appendingPathComponent(
                                    "CodexPad/CodexHome/"
                                        + "artifact-documents",
                                    isDirectory: true
                                ),
                            subscriptionEventHandler: {
                                callbackID, event in
                                try? await callbackDispatcher.send(
                                    portID: portID,
                                    callbackID: callbackID,
                                    arguments: [event]
                                )
                            }
                        )
                    let historyMediaService =
                        CodexDesktopHistoryMediaAppHostService(
                            dictationDirectory:
                                applicationSupport
                                .appendingPathComponent(
                                    "CodexPad/CodexHome/"
                                        + "dictation-history",
                                    isDirectory: true
                                ),
                            downloadsDirectory: {
                                try FileManager.default
                                    .createDirectory(
                                        at: downloadsDirectory,
                                        withIntermediateDirectories:
                                            true
                                    )
                                return downloadsDirectory
                            },
                            onDictationChanged: {
                                await MainActor.run {
                                    self?.record(
                                        "app-host dictation-history "
                                            + "changed"
                                    )
                                }
                            },
                            subscriptionEventHandler: {
                                callbackID, snapshot in
                                try? await callbackDispatcher.send(
                                    portID: portID,
                                    callbackID: callbackID,
                                    arguments: [snapshot]
                                )
                            }
                        )
                    let historySnapshotsService =
                        CodexDesktopHistorySnapshotsAppHostService(
                            storeRoot: applicationSupport
                                .appendingPathComponent(
                                    "CodexPad/CodexHome/"
                                        + "app-server-history-snapshots",
                                    isDirectory: true
                                ),
                            principalProvider: {
                                [weak self] in
                                await MainActor.run {
                                    guard let account =
                                        self?.accountStore,
                                          let userID =
                                            account.userID,
                                          let accountID =
                                            account.accountID,
                                          !userID.isEmpty,
                                          !accountID.isEmpty
                                    else {
                                        return nil
                                    }
                                    return .init(
                                        userID: userID,
                                        accountID: accountID
                                    )
                                }
                            },
                            hostKeyProvider: { hostID in
                                let normalized = hostID
                                    .trimmingCharacters(
                                        in:
                                            .whitespacesAndNewlines
                                    )
                                guard !normalized.isEmpty else {
                                    return nil
                                }
                                return installationIdentity
                                    + ":" + normalized
                            },
                            invalidationHandler: {
                                callbackID in
                                try? await callbackDispatcher.send(
                                    portID: portID,
                                    callbackID: callbackID,
                                    arguments: []
                                )
                            }
                        )
                    let libraryService =
                        CodexDesktopLibraryAppHostService(
                            authorizedOutputRoots:
                                workspaceSnapshot.artifactRoots
                                + [
                                    self?.projectlessOutputDirectoryStore
                                        .workspaceRoot
                                        ?? URL(
                                            fileURLWithPath:
                                                NSTemporaryDirectory(),
                                            isDirectory: true
                                        )
                                ],
                            generatedImagesDirectory:
                                applicationSupport
                                .appendingPathComponent(
                                    "CodexPad/CodexHome/"
                                        + "generated_images",
                                    isDirectory: true
                                ),
                            outputDirectoriesProvider: {
                                [weak self] in
                                self?.projectlessOutputDirectoryStore
                                    .outputDirectories ?? [:]
                            }
                        )
                    let localEnvironmentsBackend =
                        CodexDesktopLocalEnvironmentsFileSystemBackend(
                            authorizedWorkspaceRoots:
                                workspaceSnapshot.artifactRoots
                        )
                    let localEnvironmentsService =
                        CodexDesktopLocalEnvironmentsAppHostService(
                            hostProvider:
                                localEnvironmentsBackend.hostProvider,
                            fileSystemHandler:
                                localEnvironmentsBackend
                                .fileSystemHandler
                        )
                    let localThreadCatalogService =
                        CodexDesktopLocalThreadCatalogAppHostService(
                            backend:
                                CodexDesktopLocalThreadCatalogSessionBackend(
                                    sessionStore:
                                        localThreadCatalogSessionStore
                                ),
                            callbackHandler: {
                                callbackID, event in
                                try? await callbackDispatcher.send(
                                    portID: portID,
                                    callbackID: callbackID,
                                    arguments: [event]
                                )
                            }
                        )
                    let projectFileSyncBackend =
                        CodexDesktopProjectFileSyncBackend(
                            codexHome: applicationSupport
                                .appendingPathComponent(
                                    "CodexPad/CodexHome",
                                    isDirectory: true
                                ),
                            resolveDownloadRequest: {
                                [weak self] callback, fileID in
                                guard let self else {
                                    throw CancellationError()
                                }
                                return try await self
                                    .resolveProjectFileDownloadRequest(
                                        portID: portID,
                                        callback: callback,
                                        fileID: fileID
                                    )
                            },
                            download: {
                                [weak self] request in
                                guard let self else {
                                    throw CancellationError()
                                }
                                return try await self
                                    .downloadProjectFile(request)
                            }
                        )
                    let projectService =
                        CodexDesktopProjectAppHostService(
                            localProjectHandler: {
                                [weak self] method, request in
                                let response =
                                    try await projectMutationBackend
                                    .handle(
                                        method: method,
                                        request: request
                                    )
                                if method == "remove",
                                   case let .string(projectID) =
                                       request
                                {
                                    await self?
                                        .cleanupRemovedLocalProject(
                                            projectID: projectID
                                        )
                                }
                                return response
                            },
                            remoteProjectHandler: {
                                method, request in
                                try await remoteProjectMutationBackend
                                    .handle(
                                        method: method,
                                        request: request
                                    )
                            },
                            projectQueryHandler: {
                                [weak self] method, request in
                                guard let self else {
                                    throw CancellationError()
                                }
                                return try await self.handleProjectQuery(
                                    method: method,
                                    request: request
                                )
                            },
                            threadProjectAssignmentHandler: {
                                [weak self] request in
                                guard let self else {
                                    throw CancellationError()
                                }
                                try await self
                                    .applyThreadProjectAssignment(
                                        request
                                    )
                            },
                            threadArchiveHandler:
                                archiveBackend.threadArchiveHandler,
                            chatGptProjectFileSyncHandler: {
                                request in
                                try await projectFileSyncBackend
                                    .sync(request: request)
                            }
                        )
                    let terminalService =
                        CodexDesktopTerminalAppHostService(
                            manager:
                                CodexDesktopTerminalSessionManager(
                                    processDriver:
                                        terminalProcessDriver,
                                    allowedWorkspaceRoots:
                                        workspaceSnapshot
                                        .artifactRoots
                                        .map(\.path)
                                ),
                            subscriptionEventHandler: {
                                callbackID, event in
                                try? await callbackDispatcher.send(
                                    portID: portID,
                                    callbackID: callbackID,
                                    arguments: [event]
                                )
                            }
                        )
                    let optionalPlatformService =
                        CodexDesktopOptionalPlatformAppHostService(
                            avatarInputShapeHandler: {
                                [weak self] regions in
                                guard CodexDesktopAppHostSurfaceTarget
                                    .resolve(portID: portID)
                                    == .avatarOverlay
                                else {
                                    return
                                }
                                await MainActor.run {
                                    self?.avatarOverlayHost?
                                        .setAvatarOverlayInputShape(
                                            regions
                                        )
                                    self?.record(
                                        "avatar-overlay input-shape "
                                            + "regions=\(regions.count)"
                                    )
                                }
                            }
                        )
                    let realtimeAppHostService =
                        CodexDesktopRealtimeAppHostService(
                            codexHome: applicationSupport
                                .appendingPathComponent(
                                    "CodexPad/CodexHome",
                                    isDirectory: true
                                ),
                            eventHandler: {
                                [weak self] service, method, arguments in
                                await MainActor.run {
                                    self?.record(
                                        "app-host realtime "
                                            + "\(service).\(method)"
                                    )
                                }
                                guard service == "realtimeVoiceRuntime"
                                else {
                                    return
                                }
                                if method == "requestRealtimeStart" {
                                    await MainActor.run {
                                        do {
                                            try self?
                                                .presentAvatarOverlayIfNeeded()
                                        } catch {
                                            self?.recordFailure(error)
                                        }
                                    }
                                } else if method == "launchStateChanged",
                                          case let .object(payload)? =
                                              arguments?.first
                                {
                                    guard
                                        case let .string(launchID)? =
                                            payload["launchId"],
                                        case let .string(phase)? = payload["phase"]
                                    else {
                                        return
                                    }
                                    let error: CodexJSONValue
                                    if case let .string(message)? =
                                        payload["error"]
                                    {
                                        error = .string(message)
                                    } else {
                                        error = .null
                                    }
                                    await self?.send(
                                        .event(
                                            type:
                                                "realtime-voice-launch-state-changed",
                                            payload: .object([
                                                "launchId": .string(launchID),
                                                "phase": .string(phase),
                                                "error": error,
                                            ])
                                        )
                                    )
                                }
                            },
                            callbackInvoker: {
                                callbackID, arguments in
                                try await callbackDispatcher.send(
                                    portID: portID,
                                    callbackID: callbackID,
                                    arguments: arguments
                                )
                            },
                            runtimeCoordinator:
                                realtimeRuntimeCoordinator
                        )
                    let browsingStateService =
                        CodexDesktopBrowsingStateAppHostService(
                            pageRestoreState:
                                browserPageRestoreState,
                            customAvatarStore:
                                CodexDesktopCustomAvatarStore(
                                    rootURL: applicationSupport
                                        .appendingPathComponent(
                                            "CodexPad/CodexHome/custom-avatars",
                                            isDirectory: true
                                        )
                                ),
                            callbackInvoker: {
                                callbackID, arguments in
                                try await callbackDispatcher.send(
                                    portID: portID,
                                    callbackID: callbackID,
                                    arguments: arguments
                                )
                            }
                        )
                    return CodexDesktopInitialAppHostRouter(
                        appInfo: appInfo,
                        systemAppearance: systemAppearance,
                        workspaceRoot:
                            workspaceSnapshot.selectedRoot.path,
                        intelligenceService:
                            intelligenceService,
                        interactionService: interactionService,
                        coordinationService:
                            coordinationService,
                        browserService: browserService,
                        realtimeService:
                            realtimeAppHostService,
                        visualizationsService:
                            visualizationsService,
                        utilityService: utilityService,
                        artifactDocumentsService:
                            artifactDocumentsService,
                        browsingStateService:
                            browsingStateService,
                        downloadsService: downloadsService,
                        historyMediaService:
                            historyMediaService,
                        historySnapshotsService:
                            historySnapshotsService,
                        libraryService: libraryService,
                        localEnvironmentsService:
                            localEnvironmentsService,
                        localThreadCatalogService:
                            localThreadCatalogService,
                        optionalPlatformService:
                            optionalPlatformService,
                        peripheralService:
                            peripheralService,
                        projectService: projectService,
                        terminalService: terminalService,
                        startupReadyHandler: { [weak self] in
                            await self?.waitForReleasedStartupReady()
                        }
                    )
                }
            let services =
                CodexDesktopInitialAppHostRouter(
                    appInfo: appInfo
                ).services
            do {
                let sessions =
                    try CodexDesktopAppHostSessionStore(
                    services: services,
                    portScopedAsyncInvocationHandler: {
                        context in
                        return try await routerStore.response(to: context)
                    },
                    deferredFrameHandler: { [weak self] frame in
                        Task { @MainActor [weak self] in
                            await self?.sendAppHostFrame(frame)
                        }
                    },
                    portConnectedHandler: {
                        portID in
                        routerStore.reset(portID: portID)
                    },
                    servicesResolvedHandler: {
                        [weak self] portID in
                        Task { @MainActor [weak self] in
                            guard let self else {
                                return
                            }
                    self.startupGate
                                .observeAppHostServicesResolved()
                            self.signalReleasedStartupReadyIfNeeded()
                            self.record(
                                "app-host-services-resolved "
                                    + portID
                            )
                            self.openHomeDataGateIfReady()
                        }
                    }
                )
                appHostWorkspaceRegistry = workspaceRegistry
                appHostRouterStore = routerStore
                appHostSessions = sessions
                callbackDispatcher.install {
                    [weak self] callback, arguments in
                    try await MainActor.run {
                        guard let sessions =
                            self?.appHostSessions
                        else {
                            throw CodexDesktopAppHostCallbackDispatcher
                                .Error.handlerUnavailable
                        }
                        _ = try sessions.sendImportCall(
                            to: callback,
                            arguments: arguments
                        )
                    }
                }
            } catch {
                recordFailure(error)
            }
        }

        private func configureLoginCoordinator(
            accountStore: CodexAccountStore
        ) {
            let deviceAuthClient = CodexChatGPTAuthClient()
            let persistAndAdopt:
                @Sendable
                (CodexChatGPTTokens) async throws
                -> CodexDesktopMCPPlanType? = { tokens in
                try await accountStore
                    .acceptChatGPTTokens(tokens)
                return await accountStore.planType
            }
            let driver = CodexDesktopLoopbackLoginDriver(
                serverStarter:
                    CodexLoopbackHTTPServerFactory(),
                tokenExchanger:
                    CodexLoopbackOAuthTokenClient(),
                persistAndAdopt: persistAndAdopt,
                successRedirectPolicy: .localOnly
            )
            let deviceCodeDriver =
                CodexDesktopDeviceCodeLoginDriver(
                    requestDeviceCode: {
                        try await deviceAuthClient
                            .requestDeviceCode()
                    },
                    completeDeviceCode: { code in
                        let tokens =
                            try await deviceAuthClient
                                .completeDeviceCodeLogin(code)
                        try await accountStore
                            .acceptChatGPTTokens(tokens)
                        return await accountStore.planType
                    }
                )
            loginCoordinator = CodexDesktopLoginCoordinator(
                driver: driver,
                deviceCodeDriver: deviceCodeDriver,
                completionSink: { [weak self] completion in
                    if completion.shouldDismissAuthenticationBrowser {
                        await self?.record(
                            "chatgpt-login keychain-save-load-verified"
                        )
                        await self?.dismissAuthenticationBrowser()
                    } else {
                        let problem = await accountStore.problem
                            ?? "login did not complete"
                        await self?.record(
                            "chatgpt-login failed " + problem
                        )
                    }
                },
                acceptAPIKey: { apiKey in
                    try await accountStore.acceptAPIKey(apiKey)
                },
                diagnosticSink: { [weak self] diagnostic in
                    await MainActor.run {
                        guard let self else { return }
                        switch diagnostic {
                        case .apiKeyRequestReceived:
                            self.record(
                                "api-key-login native-request-received"
                            )
                        case .apiKeyPersistenceSucceeded:
                            self.record(
                                "api-key-login keychain-save-load-verified"
                            )
                        case .apiKeyPersistenceFailed:
                            let problem = accountStore.problem
                                ?? "credential persistence failed"
                            self.record(
                                "api-key-login persistence-failed "
                                    + problem
                            )
                        }
                    }
                },
                sendNotification: { [weak self] message in
                    await self?.send(message)
                }
            )
        }

        private nonisolated static func openExternalURL(
            _ url: URL
        ) async -> Bool {
            await withCheckedContinuation { continuation in
                Task { @MainActor in
                    UIApplication.shared.open(
                        url,
                        options: [:]
                    ) { success in
                        continuation.resume(returning: success)
                    }
                }
            }
        }

        private func dismissAuthenticationBrowser() {
            externalURLOpener.dismissAuthentication()
        }

        private func configureWorkspaceOnboarding() {
            let access = CodexWorkspaceAccess()
            let fileManager = self.fileManager
            workspaceOnboardingCoordinator =
                CodexDesktopWorkspaceOnboardingCoordinator(
                    workspaces: { [weak sessionStore] in
                        sessionStore?.state.workspaces ?? []
                    },
                    persistWorkspace: {
                        [weak self, weak sessionStore] id, name, bookmark in
                        guard let sessionStore else {
                            throw CodexSessionStoreError
                                .transportUnavailable
                        }
                        try sessionStore.openWorkspace(
                            id: id,
                            displayName: name,
                            rootBookmarkID: bookmark
                        )
                        self?.refreshAppHostWorkspaceRegistry()
                    },
                    bookmark: access.bookmark(for:),
                    resolveBookmark: access.resolve(_:),
                    createDefaultWorkspace: {
                        name, initializeGitRepository in
                        try Self.createDefaultWorkspace(
                            named: name,
                            initializeGitRepository:
                                initializeGitRepository,
                            fileManager: fileManager
                        )
                    },
                    selectWorkspace: { [weak self, weak sessionStore] id in
                        sessionStore?.selectedWorkspaceID = id
                        if id == nil {
                            sessionStore?.selectedThreadID = nil
                        }
                        self?.refreshAppHostWorkspaceRegistry()
                    },
                    send: { [weak self] message in
                        await self?.send(message)
                    }
                )
        }

        private func refreshAppHostWorkspaceRegistry() {
            guard let registry = appHostWorkspaceRegistry else {
                return
            }
            let roots = workspaceRootOptions().map {
                URL(
                    fileURLWithPath: $0,
                    isDirectory: true
                )
            }
            let selectedRoot =
                activeWorkspaceRoots().first.map {
                    URL(
                        fileURLWithPath: $0,
                        isDirectory: true
                    )
                }
            registry.replace(
                authorizedRoots: roots,
                selectedRoot: selectedRoot
            )
            appHostRouterStore?.resetAll()
            record(
                "app-host workspace registry refreshed roots="
                    + "\(roots.count)"
            )
        }

        private func persistProjectAppearance(
            projectID: String,
            appearance: CodexDesktopAppHostRPC.Value
        ) {
            guard let appearance =
                Self.codexJSONValue(appearance)
            else {
                return
            }
            var appearances: [String: CodexJSONValue]
            if case let .object(existing)? =
                persistedAtoms.snapshot["project-appearances"]
            {
                appearances = existing
            } else {
                appearances = [:]
            }
            appearances[projectID] = appearance
            _ = persistedAtoms.update(
                key: "project-appearances",
                value: .object(appearances)
            )
        }

        private func resolveProjectFileDownloadRequest(
            portID: String,
            callback: CodexDesktopAppHostRPC.Value,
            fileID: String
        ) async throws -> CodexDesktopAppHostRPC.Value {
            guard case let .import(callbackID) = callback else {
                throw CodexDesktopProjectFileSyncBackend
                    .Error.invalidRequest
            }
            guard let appHostSessions else {
                throw CancellationError()
            }
            return try await appHostSessions.callImport(
                onPortID: portID,
                callbackID: callbackID,
                arguments: [.string(fileID)]
            )
        }

        private func downloadProjectFile(
            _ request: CodexDesktopAppHostRPC.Value
        ) async throws -> Data {
            guard case let .object(fields) = request,
                  case let .string(downloadURL)? =
                      fields["downloadUrl"],
                  !downloadURL.isEmpty
            else {
                throw CodexDesktopProjectFileSyncBackend
                    .TransferError()
            }
            var requestHeaders: [String: String] = [:]
            if let rawHeaders = fields["requestHeaders"] {
                guard case let .object(headers) = rawHeaders else {
                    throw CodexDesktopProjectFileSyncBackend
                        .TransferError()
                }
                for (name, value) in headers {
                    guard case let .string(value) = value else {
                        throw CodexDesktopProjectFileSyncBackend
                            .TransferError()
                    }
                    requestHeaders[name] = value
                }
            }
            return try await networkFetchClient.downloadProjectFile(
                downloadURL: downloadURL,
                requestHeaders: requestHeaders,
                credentials: accountStore?.officialCredentials()
            )
        }

        private func applyThreadProjectAssignment(
            _ request: CodexDesktopAppHostRPC.Value
        ) async throws {
            guard case let .object(fields) = request,
                  case let .string(threadID)? = fields["threadId"],
                  !threadID.trimmingCharacters(
                      in: .whitespacesAndNewlines
                  ).isEmpty,
                  let rawAssignment = fields["assignment"]
            else {
                throw CodexDesktopProjectAppHostService
                    .Error.invalidArguments
            }

            let assignment:
                CodexDesktopThreadProjectAssignment?
            if rawAssignment == .null {
                assignment = nil
            } else {
                assignment = try Self.threadProjectAssignment(
                    from: rawAssignment
                )
            }
            guard threadProjectAssignmentStore.setAssignment(
                threadID: threadID,
                assignment: assignment
            ) else {
                return
            }

            await sendThreadProjectAssignmentsUpdated([
                threadID:
                    assignment?.globalStateValue ?? .null
            ])
        }

        private static func threadProjectAssignment(
            from value: CodexDesktopAppHostRPC.Value
        ) throws -> CodexDesktopThreadProjectAssignment {
            guard case let .object(fields) = value,
                  case let .string(kind)? = fields["projectKind"],
                  case let .string(projectID)? = fields["projectId"],
                  !projectID.trimmingCharacters(
                      in: .whitespacesAndNewlines
                  ).isEmpty
            else {
                throw CodexDesktopProjectAppHostService
                    .Error.invalidArguments
            }
            let pendingCoreUpdate: Bool
            if let rawPendingCoreUpdate = fields["pendingCoreUpdate"] {
                guard case let .bool(value) = rawPendingCoreUpdate else {
                    throw CodexDesktopProjectAppHostService
                        .Error.invalidArguments
                }
                pendingCoreUpdate = value
            } else {
                pendingCoreUpdate = false
            }

            switch kind {
            case "local":
                let projectOrigin:
                    CodexDesktopThreadProjectAssignment
                    .ProjectOrigin?
                if let rawOrigin = fields["projectOrigin"] {
                    guard case let .string(origin) = rawOrigin,
                          origin == "chatgpt"
                    else {
                        throw CodexDesktopProjectAppHostService
                            .Error.invalidArguments
                    }
                    projectOrigin = .chatgpt
                } else {
                    projectOrigin = nil
                }
                return .local(
                    projectID: projectID,
                    projectOrigin: projectOrigin,
                    path: try appHostOptionalString(
                        fields["path"]
                    ),
                    cwd: try appHostOptionalString(
                        fields["cwd"]
                    ),
                    pendingCoreUpdate: pendingCoreUpdate
                )

            case "remote":
                guard case let .string(path)? = fields["path"] else {
                    throw CodexDesktopProjectAppHostService
                        .Error.invalidArguments
                }
                return .remote(
                    projectID: projectID,
                    path: path,
                    cwd: try appHostOptionalString(
                        fields["cwd"]
                    ),
                    hostID: try appHostOptionalString(
                        fields["hostId"]
                    ),
                    pendingCoreUpdate: pendingCoreUpdate
                )

            default:
                throw CodexDesktopProjectAppHostService
                    .Error.invalidArguments
            }
        }

        private static func appHostOptionalString(
            _ value: CodexDesktopAppHostRPC.Value?
        ) throws -> String? {
            guard let value else {
                return nil
            }
            guard case let .string(string) = value else {
                throw CodexDesktopProjectAppHostService
                    .Error.invalidArguments
            }
            return string
        }

        private nonisolated static func string(
            _ value: CodexDesktopAppHostRPC.Value?
        ) -> String? {
            guard case let .string(string) = value else {
                return nil
            }
            return string
        }

        private nonisolated static func nonemptyString(
            _ value: CodexDesktopAppHostRPC.Value?
        ) -> String? {
            guard let string = string(value) else {
                return nil
            }
            let trimmed = string.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            return trimmed.isEmpty ? nil : trimmed
        }

        private func cleanupRemovedLocalProject(
            projectID: String
        ) async {
            let threadIDs = threadProjectAssignmentStore
                .assignments
                .compactMap { threadID, assignment in
                    assignment.projectKind == .local
                        && assignment.projectID == projectID
                        ? threadID
                        : nil
                }
                .sorted()

            var assignmentChanges:
                [String: CodexJSONValue] = [:]
            for threadID in threadIDs where
                threadProjectAssignmentStore.removeAssignment(
                    threadID: threadID
                )
            {
                assignmentChanges[threadID] = .null
            }
            if !assignmentChanges.isEmpty {
                await sendThreadProjectAssignmentsUpdated(
                    assignmentChanges
                )
            }

            var changedKeys: [String] = []
            if !threadIDs.isEmpty {
                var projectlessThreadIDs: [String] = []
                if case let .array(existing)? =
                    persistedAtoms.snapshot[
                        "projectless-thread-ids"
                    ]
                {
                    projectlessThreadIDs = existing.compactMap {
                        guard case let .string(threadID) = $0 else {
                            return nil
                        }
                        return threadID
                    }
                }
                var seen = Set(projectlessThreadIDs)
                for threadID in threadIDs
                    where seen.insert(threadID).inserted
                {
                    projectlessThreadIDs.append(threadID)
                }
                _ = persistedAtoms.update(
                    key: "projectless-thread-ids",
                    value: .array(
                        projectlessThreadIDs.map(
                            CodexJSONValue.string
                        )
                    )
                )
                changedKeys.append(
                    "thread-project-assignments"
                )
                changedKeys.append("projectless-thread-ids")
            }

            if case var .object(appearances)? =
                persistedAtoms.snapshot["project-appearances"],
               appearances.removeValue(forKey: projectID) != nil
            {
                _ = persistedAtoms.update(
                    key: "project-appearances",
                    value: .object(appearances)
                )
                changedKeys.append("project-appearances")
            }
            if !changedKeys.isEmpty {
                await sendGlobalStateUpdated(keys: changedKeys)
            }
        }

        private func sendThreadProjectAssignmentsUpdated(
            _ assignments: [String: CodexJSONValue]
        ) async {
            await send(
                .event(
                    type: "thread-project-assignments-updated",
                    payload: .object([
                        "assignments": .object(assignments)
                    ])
                )
            )
        }

        private func publishLocalProjectsStateChange() async {
            refreshAppHostWorkspaceRegistry()
            await send(
                .event(
                    type: "active-workspace-roots-updated",
                    payload: .object([:])
                )
            )
            await sendGlobalStateUpdated(keys: [
                "local-projects",
                "project-order",
                "selected-project",
                "project-appearances",
            ])
            await send(
                .event(
                    type: "workspace-root-options-updated",
                    payload: .object([:])
                )
            )
        }

        private func publishRemoteProjectsStateChange(
            keys: [String]
        ) async {
            await sendGlobalStateUpdated(keys: keys)
        }

        private nonisolated static func codexJSONValue(
            _ value: CodexDesktopAppHostRPC.Value
        ) -> CodexJSONValue? {
            switch value {
            case .null:
                return .null
            case let .bool(value):
                return .bool(value)
            case let .integer(value):
                return .integer(value)
            case let .number(value):
                return .number(value)
            case let .string(value):
                return .string(value)
            case let .array(values):
                let converted = values.compactMap(codexJSONValue)
                return converted.count == values.count
                    ? .array(converted)
                    : nil
            case let .object(fields):
                var converted: [String: CodexJSONValue] = [:]
                for (key, field) in fields {
                    guard let field = codexJSONValue(field) else {
                        return nil
                    }
                    converted[key] = field
                }
                return .object(converted)
            default:
                return nil
            }
        }

        private static func mergedReleasedProjectOrder(
            persistedOrder: CodexJSONValue?,
            localProjectIDs: [String],
            remoteProjects: CodexJSONValue?
        ) -> [String] {
            let persistedIDs: [String]
            if case let .array(values)? = persistedOrder {
                persistedIDs = values.compactMap {
                    guard case let .string(id) = $0 else {
                        return nil
                    }
                    return id
                }
            } else {
                persistedIDs = []
            }
            let remoteProjectIDs: Set<String>
            if case let .array(values)? = remoteProjects {
                remoteProjectIDs = Set(values.compactMap { value in
                    guard case let .object(fields) = value,
                          case let .string(id)? = fields["id"]
                    else {
                        return nil
                    }
                    return id
                })
            } else {
                remoteProjectIDs = []
            }
            let validIDs = remoteProjectIDs.union(localProjectIDs)
            var seen = Set<String>()
            return (persistedIDs + localProjectIDs).filter {
                validIDs.contains($0) && seen.insert($0).inserted
            }
        }

        private func verifyAndLoadReleasedSurface() {
            surfaceVerificationTask?.cancel()
            surfaceVerificationTask = Task { [weak self] in
                await self?.performReleasedSurfaceVerification()
            }
        }

        private func performReleasedSurfaceVerification() async {
            guard let host else {
                return
            }
            do {
                let surfaceDirectory =
                    try CodexDesktopSurfaceVerifier
                        .bundledSurfaceDirectory()
                let verification = try await CodexDesktopSurfaceVerifier
                    .verifyReleasedSurfaceInBackground(
                    surfaceDirectory: surfaceDirectory,
                    expectedDesktopVersion:
                        CodexBuildMetadata.desktopVersion,
                    expectedDesktopBuild:
                        CodexBuildMetadata.desktopBuild,
                    installIdentity:
                        CodexDesktopSurfaceVerifier
                            .releasedSurfaceInstallIdentity(),
                    cacheURL:
                        CodexDesktopSurfaceVerifier
                            .releasedSurfaceTrustCacheURL()
                )
                try Task.checkCancellation()
                let initialRoute =
                    lastActiveLocalThreadStore
                        .restoredInitialRoute(
                            threadExists: { [sessionStore] threadID in
                                do {
                                    _ = try sessionStore.readThread(
                                        id: .string(
                                            "restore-last-active-"
                                                + UUID().uuidString
                                                    .lowercased()
                                        ),
                                        params: CodexThreadReadParams(
                                            threadID:
                                                CodexStoredThreadID(threadID),
                                            includeTurns: false
                                        )
                                    )
                                    return true
                                } catch {
                                    return false
                                }
                            },
                            threadIsArchived: { [sessionStore] threadID in
                                guard let id = UUID(uuidString: threadID)
                                else {
                                    return false
                                }
                                return sessionStore.state.archivedThreadIDs
                                    .contains(id)
                            }
                        )
                pendingRestoredInitialRoute = initialRoute
                let plan =
                    try CodexDesktopWebViewResourceLocator.resolve(
                        bundle: .main,
                        initialRoute: nil
                    )
                try prepareHostFilesystem()
                try host.loadVerifiedSurface(plan)
                if let initialRoute {
                    record(
                        "restoring released renderer route "
                            + initialRoute
                    )
                }
                record(
                    "loading released renderer "
                        + "\(CodexBuildMetadata.desktopVersion)"
                        + " (\(CodexBuildMetadata.desktopBuild))"
                        + (verification.didVerifyCompleteTree
                            ? " complete-tree-verified"
                            : " trusted-install-cache")
                )
            } catch is CancellationError {
                return
            } catch {
                do {
                    if host.state == .verifyingResources {
                        try host.resourceVerificationFailed(
                            CodexDiagnosticSanitization.publicErrorSummary(error)
                        )
                    }
                } catch {
                    record(
                        "resource failure transition="
                            + CodexDiagnosticSanitization.publicErrorSummary(error)
                    )
                }
                recordFailure(error)
            }
        }

        private func handle(
            _ event: CodexDesktopWebViewInboundEvent,
            replyHost: CodexDesktopWebViewHost? = nil
        ) async {
            if case let .nativeChannel(name, payload) = event,
               name == CodexDesktopInteractiveSurfaceProbe.channel,
               CodexDesktopInteractiveSurfaceProbe
                .isCommitPayload(payload)
            {
                startupGate.observeInteractiveSurfaceCommitted()
                record("interactive-surface-committed")
                openHomeDataGateIfReady()
            }
            if Self.isReleasedBridgeEvidence(event) {
                startupGate.observeBridgeMessage()
                openHomeDataGateIfReady()
            }
            switch event {
            case .rendererReady:
                record("renderer-ready")
                if let restoredRoute = pendingRestoredInitialRoute {
                    pendingRestoredInitialRoute = nil
                    await send(
                        .event(
                            type: "navigate-to-route",
                            payload: .object([
                                "path": .string(restoredRoute)
                            ])
                        )
                    )
                    record(
                        "replayed released renderer route "
                            + restoredRoute
                    )
                }
                await synchronizeRemoteControlRenderer()
                openHomeDataGateIfReady()

            case .viewFocused:
                record("view-focused")

            case let .logMessage(message):
                record(message.diagnosticDescription)

            case let .fetch(request):
                let response: CodexDesktopHostMessage
                if request.isVSCodeHostRequest {
                    let initialState =
                        makeInitialHostState(for: request)
                    if let asyncResponse =
                        await CodexDesktopAsyncFetchRouter.response(
                            to: request,
                            state: initialState,
                            automationScheduler:
                                automationScheduler,
                            embeddedGitRequester:
                                gitDiffer
                                    as? any CodexDesktopEmbeddedGitRequesting,
                            archivedThreadStore:
                                sessionStore,
                            fileInteractor: self,
                            managedWorktreeInteractor: self,
                            worktreeSnapshotUploader: self,
                            gitCredentialProvider: self,
                            appshotCaptureStarter:
                                appshotCaptureCoordinator
                        )
                    {
                        response = asyncResponse
                    } else {
                        response =
                            CodexDesktopInitialFetchRouter.response(
                                to: request,
                                state: initialState,
                                automationStore:
                                    automationStore,
                                pinnedThreadStore:
                                    pinnedThreadStore,
                                globalStateStore:
                                    persistedAtoms,
                                configStore: configStore,
                                recommendedSkillService:
                                    recommendedSkillService,
                                settingsFilePath:
                                    hostFilesystemPaths()
                                    .codexHome
                                    .appendingPathComponent(
                                        "settings.json",
                                        isDirectory: false
                                    ).path,
                                projectlessWorkspaceRootPath:
                                    projectlessOutputDirectoryStore
                                    .workspaceRoot.path,
                                fileManager: fileManager
                            )
                    }
                } else {
                    if officialProvider != nil,
                       Self.isAttestationChallengeRequest(request)
                    {
                        response = .fetchSuccess(
                            requestID: request.requestID,
                            status: 200,
                            headers: [
                                "content-type": "application/json"
                            ],
                            body: .object([
                                "attestation_challenge": .string(
                                    "codex-for-ipad-local-provider"
                                )
                            ])
                        )
                    } else if officialProvider != nil,
                              Self.isConversationPrepareRequest(request)
                    {
                        response = .fetchSuccess(
                            requestID: request.requestID,
                            status: 200,
                            headers: [
                                "content-type": "application/json"
                            ],
                            body: .object([:])
                        )
                    } else {
                        response =
                            await networkFetchClient.response(
                                to: request,
                                credentials:
                                    accountStore?
                                        .officialCredentials(),
                                refreshCredentials: {
                                    [credentialRefreshAdapter] in
                                    try await credentialRefreshAdapter
                                        .refresh()
                                }
                            )
                    }
                }
                await send(response, replyingTo: replyHost)
                if !request.isVSCodeHostRequest {
                    recordNetworkFetchMessage(
                        request: request,
                        response: response
                    )
                }
                if request.isVSCodeHostRequest,
                   request.hostMethod == "projectless-thread-cwd",
                   case let .fetchSuccess(
                       _,
                       status,
                       _,
                       .object(paths)
                   ) = response,
                   (200 ..< 300).contains(status),
                   case let .string(cwd)? = paths["cwd"],
                   case let .string(outputDirectory)? =
                       paths["outputDirectory"],
                   case let .string(workspaceRoot)? =
                       paths["workspaceRoot"]
                {
                    _ = projectlessOutputDirectoryStore
                        .recordCreatedPaths(
                            cwd: cwd,
                            outputDirectory: outputDirectory,
                            workspaceRoot: workspaceRoot
                        )
                }
                if request.isVSCodeHostRequest,
                   Self.isSuccessfulFetchResponse(response),
                   request.hostMethod == "set-thread-pinned"
                    || request.hostMethod
                        == "set-pinned-threads-order"
                {
                    await sendPinnedThreadsUpdated()
                }
                if request.isVSCodeHostRequest,
                   Self.isSuccessfulFetchResponse(response),
                   request.hostMethod == "set-global-state",
                   let key = Self.fetchRequestKey(request)
                {
                    await sendGlobalStateUpdated(
                        keys: [key]
                    )
                }
                if request.isVSCodeHostRequest,
                   Self.isSuccessfulFetchResponse(response),
                   request.hostMethod
                    == "automation-run-archive"
                    || request.hostMethod
                        == "automation-run-delete"
                {
                    await sendInboxItemsChanged()
                }
                if request.isVSCodeHostRequest,
                   Self.isSuccessfulFetchResponse(response)
                {
                    startupGate.observeSuccessfulFetch(
                        request.hostMethod
                    )
                }
                record(
                    request.isVSCodeHostRequest
                        ? "fetch \(request.hostMethod)"
                        : "fetch network"
                )
                openHomeDataGateIfReady()

            case let .fetchStream(request):
                fetchStreamTasks[request.requestID]?.cancel()
                lastFetchStreamDiagnostic.start(
                    requestID: request.requestID
                )
                let credentials = accountStore?.officialCredentials()
                let headerNames = (request.headers ?? [:]).keys
                    .map { $0.lowercased() }
                    .sorted()
                record(
                    "fetch-stream request "
                        + (URL(string: request.url).map {
                            "\($0.host ?? "unknown")\($0.path)"
                        } ?? request.url)
                        + " method=\(request.method)"
                        + " format=\(request.format ?? "sse")"
                        + " bodyBytes=\(request.body?.utf8.count ?? 0)"
                        + " headers=\(headerNames.joined(separator: ","))"
                )
                let credentialRefreshAdapter = credentialRefreshAdapter
                fetchStreamTasks[request.requestID] = Task {
                    [
                        weak self,
                        networkFetchClient,
                        officialProvider,
                        credentialRefreshAdapter,
                    ] in
                    if CodexDesktopConversationStreamAdapter
                        .shouldUseOfficialProvider(
                            request,
                            authMethod: credentials?.authMethod
                        ),
                       let officialProvider
                    {
                        await self?
                            .streamConversationThroughOfficialProvider(
                                request,
                                credentials: credentials,
                                provider: officialProvider
                            )
                    } else {
                        await networkFetchClient.stream(
                            request,
                            credentials: credentials,
                            refreshCredentials: {
                                [credentialRefreshAdapter] in
                                try await credentialRefreshAdapter
                                    .refresh()
                            }
                        ) { [weak self] message in
                            await self?.send(message)
                        }
                    }
                    await MainActor.run {
                        self?.fetchStreamTasks[
                            request.requestID
                        ] = nil
                    }
                }
                record("fetch-stream started")

            case let .cancelFetchStream(requestID):
                fetchStreamTasks.removeValue(
                    forKey: requestID
                )?.cancel()
                lastFetchStreamDiagnostic.cancel(
                    requestID: requestID
                )
                record("fetch-stream cancelled")

            case let .openInBrowser(request):
                let accepted = externalURLOpener.open(request)
                record(
                    "open-in-browser "
                        + (accepted ? "accepted" : "rejected")
                )

            case let .mcpRequest(request):
                let routed = await routeDesktopMCPRequest(request)
                if request.request.method == "thread/start",
                   !Self.isSuccessfulMCPResponse(routed.response),
                   let problem = sessionStore.lastTransportProblem
                {
                    record("thread/start transport \(problem)")
                    if let params = try? CodexDesktopInitialMCPRouter
                        .decodeThreadStartParams(request.request.params)
                    {
                        let cwdKind: String
                        switch params.cwd {
                        case let .value(cwd):
                            cwdKind = cwd.hasPrefix("/") ? "absolute" : "relative"
                        case .null:
                            cwdKind = "null"
                        case .omitted:
                            cwdKind = "omitted"
                        }
                        let configKeys: String
                        switch params.config {
                        case let .value(config):
                            configKeys = config.keys.sorted().joined(separator: ",")
                        case .null:
                            configKeys = "null"
                        case .omitted:
                            configKeys = "omitted"
                        }
                        let nonNullInstructions = [
                            ("base", params.baseInstructions),
                            ("developer", params.developerInstructions),
                            ("service", params.serviceName),
                        ].compactMap { name, value in
                            if case .value = value { return name }
                            return nil
                        }.joined(separator: ",")
                        let instructionDescription = nonNullInstructions.isEmpty
                            ? "none"
                            : nonNullInstructions
                        record(
                            "thread/start normalized cwd=\(cwdKind) "
                                + "config=\(configKeys) "
                                + "instructions=\(instructionDescription)"
                        )
                    }
                }
                if request.request.method == "turn/start",
                   !Self.isSuccessfulMCPResponse(routed.response),
                   let problem = sessionStore.lastTransportProblem,
                   let params = try? CodexAppServerTurnStartParamsDecoder
                       .decode(request.request.params)
                {
                    let diagnostic =
                        CodexDesktopTurnStartFailureDiagnostic.make(
                            problem: problem,
                            params: params,
                            rawParams: request.request.params
                        )
                    CodexDesktopTurnStartDiagnosticStore.persist(
                        diagnostic,
                        to: userDefaults
                    )
                    record(diagnostic)
                }
                if request.request.method == "thread/resume",
                   !Self.isSuccessfulMCPResponse(routed.response),
                   let problem = sessionStore.lastTransportProblem
                {
                    record("thread/resume transport \(problem)")
                    if let summary = CodexDesktopInitialMCPRouter
                        .threadResumeDiagnosticSummary(
                            request.request.params
                        )
                    {
                        record("thread/resume normalized \(summary)")
                    }
                }
                for message in routed.preResponseMessages {
                    await send(message, replyingTo: replyHost)
                }
                if request.request.method == "account/logout" {
                    // Desktop publishes the auth-state transition while the
                    // logout RPC is still pending. If the result wins this
                    // race, the renderer navigates to /login against stale
                    // auth state and its guard immediately restores home.
                    for message in routed.postResponseMessages {
                        await send(message, replyingTo: replyHost)
                    }
                    await send(routed.response, replyingTo: replyHost)
                } else {
                    await send(routed.response, replyingTo: replyHost)
                    for message in routed.postResponseMessages {
                        await send(message, replyingTo: replyHost)
                    }
                }
                if request.request.method == "fs/readFile" {
                    let result = Self.isSuccessfulMCPResponse(
                        routed.response
                    ) ? "success" : "error"
                    let summary: String
                    if case let .object(params)? = request.request.params,
                       case let .string(path)? = params["path"]
                    {
                        let paths = hostFilesystemPaths()
                        summary = CodexDesktopInitialMCPRouter
                            .fileReadDiagnosticSummary(
                                path: path,
                                applicationRoot:
                                    paths.applicationRoot.path,
                                codexHome: paths.codexHome.path,
                                workspaceRoots: workspaceRootOptions()
                            )
                    } else {
                        summary = "scope=invalid-request"
                    }
                    record(
                        "mcp fs/readFile \(summary) result=\(result)"
                    )
                } else {
                    record("mcp \(request.request.method)")
                }
                if routed.isLoginResponse {
                    return
                }
                if Self.isSuccessfulMCPResponse(routed.response) {
                    startupGate.observeSuccessfulMCP(
                        request.request.method
                    )
                }
                openHomeDataGateIfReady()

            case let .mcpResponse(hostID, response):
                receiveDesktopMCPClientResponse(
                    hostID: hostID,
                    response: response
                )

            case .persistedAtomSyncRequest:
                await send(
                    .event(
                        type: "persisted-atom-sync",
                        payload: .object([
                            "state": .object(
                                persistedAtoms.snapshot
                            )
                        ])
                    ),
                    replyingTo: replyHost
                )
                record("persisted-atom-sync")

            case let .persistedAtomUpdate(update):
                _ = persistedAtoms.update(
                    key: update.key,
                    value: update.deleted ? nil : update.value
                )
                var payload: [String: CodexJSONValue] = [
                    "key": .string(update.key),
                    "deleted": .bool(update.deleted),
                ]
                if !update.deleted, let value = update.value {
                    payload["value"] = value
                }
                await send(
                    .event(
                        type: "persisted-atom-updated",
                        payload: .object(payload)
                    )
                )
                record("persisted-atom-update \(update.key)")

            case let .sharedObjectSubscribe(key):
                let current = sharedObjects.subscribe(key)
                await sendSharedObjectUpdate(
                    key: key,
                    lookup: current
                )
                record(
                    "shared-object-subscribe \(key) "
                        + "count="
                        + "\(sharedObjects.subscriptionCount(for: key))"
                )

            case let .sharedObjectUnsubscribe(key):
                let remaining = sharedObjects.unsubscribe(key)
                record(
                    "shared-object-unsubscribe \(key) "
                        + "count=\(remaining)"
                )

            case let .sharedObjectSet(key, value):
                let current = sharedObjects.set(
                    value,
                    for: key
                )
                if sharedObjects.isSubscribed(to: key) {
                    await sendSharedObjectUpdate(
                        key: key,
                        lookup: current
                    )
                }
                record("shared-object-set \(key)")

            case let .viewEvent(type, payload):
                if type == "new-chat" || type == "new-projectless-task" {
                    let nonce = String(Int(Date().timeIntervalSince1970 * 1_000))
                    await send(
                        .event(
                            type: "navigate-to-route",
                            payload: .object([
                                "path": .string("/"),
                                "state": .object([
                                    "focusComposerNonce": .string(nonce)
                                ])
                            ])
                        )
                    )
                    record("new-chat routed to home focus=(type)")
                    return
                }
                if await handleAvatarOverlayViewEvent(type: type) {
                    return
                }
                if type == "app-shell-shortcut-state-changed" {
                    guard let state = CodexDesktopAppShellShortcutState(
                        payload: payload
                    ) else {
                        record("invalid app-shell-shortcut-state-changed")
                        return
                    }
                    appShellShortcutState = state
                    record(
                        "app-shell-shortcut-state-changed focus="
                            + state.focusArea
                    )
                    return
                }
                if let response =
                    CodexDesktopCommandMenuHostRouter.response(
                        to: type,
                        payload: payload
                    )
                {
                    await send(response)
                    record("command-menu \(type)")
                    return
                }
                if await handleAutomationViewEvent(
                    type: type,
                    payload: payload
                ) {
                    return
                }
                if let workspaceOnboardingCoordinator {
                    let effect =
                        await workspaceOnboardingCoordinator
                            .handleViewEvent(
                                type: type,
                                payload: payload
                            )
                    switch effect {
                    case .ignored:
                        break
                    case .handled:
                        record("workspace-onboarding \(type)")
                        return
                    case let .presentPicker(allowsMultiple):
                        workspacePickerAllowsMultipleSelection =
                            allowsMultiple
                        isWorkspacePickerPresented = true
                        record("workspace-picker requested")
                        return
                    }
                }
                record("view-event \(type)")

            case let .nativeChannel(name, _):
                record("native-channel event \(name)")
            }
        }

        private func streamConversationThroughOfficialProvider(
            _ request: CodexDesktopFetchStreamRequest,
            credentials: CodexOfficialCredentials?,
            provider: CodexOfficialProviderClient
        ) async {
            guard let credentials else {
                await send(
                    .event(
                        type: "fetch-stream-error",
                        payload: .object([
                            "requestId": .string(request.requestID),
                            "error": .string("Authentication is required"),
                        ])
                    )
                )
                return
            }
            let fallbackModel =
                CodexModelCatalog.current.first(where: \.isDefault)?.model
                ?? "gpt-5"
            let parsed = CodexDesktopConversationStreamAdapter.parse(
                body: request.body,
                fallbackModel: fallbackModel
            )
            let officialProviderModel =
                CodexDesktopConversationStreamAdapter
                    .officialProviderModel(for: parsed.model)
            let providerRunID = UUID().uuidString.lowercased()
            let providerStartedAtMs = Int64(
                Date().timeIntervalSince1970 * 1_000
            )
            let persistence = CodexDesktopConversationPersistenceBridge(
                store: sessionStore,
                lastActiveLocalThreadStore:
                    lastActiveLocalThreadStore
            )
            let persistedContext: CodexDesktopPersistedConversationContext
            do {
                persistedContext = try persistence.begin(
                    requestID: request.requestID,
                    conversationID: parsed.conversationID,
                    input: parsed.input,
                    model: officialProviderModel,
                    reasoningEffort: parsed.reasoningEffort,
                    cwd: NSHomeDirectory()
                )
            } catch {
                record(
                    "official-provider persistence-start failed error="
                        + CodexDiagnosticSanitization.publicErrorSummary(error)
                )
                await send(
                    .event(
                        type: "fetch-stream-error",
                        payload: .object([
                            "requestId": .string(request.requestID),
                            "error": .string(
                                "Conversation persistence start failed"
                            ),
                        ])
                    )
                )
                await send(
                    .event(
                        type: "fetch-stream-complete",
                        payload: .object([
                            "requestId": .string(request.requestID),
                        ])
                    )
                )
                return
            }
            // Returning the durable app-server thread id on the first stream
            // event migrates the released renderer's temporary local mapping
            // to the same identity used by thread/list and thread/read.
            let conversationID = persistedContext.threadID.rawValue
            let messageID = UUID().uuidString.lowercased()
            let cancellation = CodexTurnCancellation()
            await send(
                .event(
                    type: "fetch-stream-response",
                    payload: .object([
                        "requestId": .string(request.requestID),
                        "status": .integer(200),
                        "headers": .object([
                            "content-type": .string("text/event-stream"),
                        ]),
                    ])
                )
            )
            var accumulated = ""
            var responseItems: [String] = []
            var didCommitResponse = false
            var currentCredentials = credentials
            var retryGate = CodexOfficialProviderCredentialRetryGate()
            var providerTransportPayload: CodexJSONValue?
            do {
                providerAttempts: while !didCommitResponse {
                    providerTransportPayload = nil
                    let officialRequest = CodexOfficialResponseRequest(
                        requestID: persistedContext.turnID,
                        accessToken: currentCredentials.accessToken,
                        accountID: currentCredentials.accountID,
                        baseURL: currentCredentials.authMethod == .chatGPT
                            || currentCredentials.authMethod
                                == .chatGPTAuthTokens
                            ? nil
                            : currentCredentials.baseURL,
                        model: officialProviderModel,
                        reasoningEffort: parsed.reasoningEffort,
                        instructions: """
                        You are Codex, a coding agent. Be precise and practical.
                        """,
                        input: parsed.input,
                        priorInputItems: persistedContext.priorInputItems
                    )
                    do {
                        record(
                            "official-provider started model="
                                + "\(officialProviderModel)"
                                + (officialProviderModel == parsed.model
                                    ? ""
                                    : " rendererModel=\(parsed.model)")
                        )
                        let providerEvents = await provider.stream(
                            officialRequest,
                            cancellation: cancellation
                        )
                        let events =
                            CodexOfficialProviderFirstEventDeadline.enforce(
                                providerEvents,
                                timeout: .seconds(30)
                            )
                        for try await event in events {
                            try Task.checkCancellation()
                            switch event {
                            case .responseStarted:
                                record("official-provider response-started")
                            case let .realtime(
                                _,
                                _,
                                eventType,
                                payload
                            ) where eventType == "provider_transport_error":
                                providerTransportPayload = payload
                                let diagnostic =
                                    CodexOfficialProviderStreamDiagnostic.make(
                                        runID: providerRunID,
                                        startedAtMs: providerStartedAtMs,
                                        rendererModel: parsed.model,
                                        providerModel: officialProviderModel,
                                        authMethod:
                                            currentCredentials.authMethod,
                                        terminalReason:
                                            "provider_transport_error"
                                    )
                                    + CodexOfficialProviderTransportDiagnostic
                                        .make(payload: payload)
                                record(diagnostic)
                                userDefaults.set(
                                    diagnostic,
                                    forKey:
                                        "codex.desktop.last-official-provider-transport-diagnostic"
                                )
                                switch retryGate.transportAction(
                                    for: event,
                                    credentials: currentCredentials
                                ) {
                                case .refreshCredentials:
                                    record(
                                        "official-provider refreshing expired "
                                            + "ChatGPT credentials"
                                    )
                                    currentCredentials = try await
                                        credentialRefreshAdapter.refresh()
                                    continue providerAttempts
                                case .fail:
                                    throw CodexPersistedTurnCoordinatorError
                                        .missingResponseCompletion
                                case nil:
                                    break
                                }
                            case let .assistantTextDelta(_, _, delta):
                                retryGate.observe(event)
                                accumulated += delta
                                record(
                                    "official-provider text-delta bytes="
                                        + "\(delta.utf8.count)"
                                )
                                record(
                                    "official-provider renderer-message "
                                        + "conversation=\(conversationID) "
                                        + "parent="
                                        + "\(parsed.parentMessageID ?? "nil") "
                                        + "textBytes="
                                        + "\(accumulated.utf8.count)"
                                )
                                await send(
                                    Self.chatGPTMessageEvent(
                                        requestID: request.requestID,
                                        conversationID: conversationID,
                                        messageID: messageID,
                                        text: accumulated,
                                        completed: false,
                                        parentMessageID:
                                            parsed.parentMessageID
                                    )
                                )
                            case let .responseItemDone(_, _, itemJSON):
                                retryGate.observe(event)
                                responseItems.append(itemJSON)
                            case let .responseCompleted(
                                _,
                                _,
                                responseID,
                                usage,
                                endTurn
                            ):
                                retryGate.observe(event)
                                try persistence.commit(
                                    persistedContext,
                                    responseItems: responseItems,
                                    responseID: responseID,
                                    usage: usage,
                                    endTurn: endTurn ?? true,
                                    fallbackAssistantText: accumulated
                                )
                                didCommitResponse = true
                                userDefaults.removeObject(
                                    forKey:
                                        "codex.desktop.last-official-provider-diagnostic"
                                )
                                userDefaults.removeObject(
                                    forKey:
                                        "codex.desktop.last-official-provider-transport-diagnostic"
                                )
                                record(
                                    "official-provider persisted thread="
                                        + conversationID
                                        + " turn=\(persistedContext.turnID)"
                                        + " items=\(responseItems.count)"
                                )
                                record(
                                    "official-provider last-active-anchor="
                                        + (
                                            lastActiveLocalThreadStore
                                                .threadID == nil
                                                ? "missing"
                                                : "present"
                                        )
                                )
                                record(
                                    "official-provider completed bytes="
                                        + "\(accumulated.utf8.count)"
                                )
                                record(
                                    "official-provider renderer-complete "
                                        + "conversation=\(conversationID)"
                                )
                                await send(
                                    Self.chatGPTMessageEvent(
                                        requestID: request.requestID,
                                        conversationID: conversationID,
                                        messageID: messageID,
                                        text: accumulated,
                                        completed: true,
                                        parentMessageID:
                                            parsed.parentMessageID
                                    )
                                )
                                if let host {
                                    let visibleCount =
                                        (try? await host
                                            .visibleTextOccurrenceCount(
                                                accumulated
                                            )) ?? -1
                                    record(
                                        "official-provider "
                                            + "renderer-visible-count="
                                            + "\(visibleCount)"
                                    )
                                }
                                await send(
                                    Self.chatGPTCompletionEvent(
                                        requestID: request.requestID,
                                        conversationID: conversationID
                                    )
                                )
                            default:
                                break
                            }
                        }
                        if didCommitResponse {
                            break
                        }
                        if retryGate.consumeRetryIfEligible(
                            credentials: currentCredentials
                        ) {
                            record(
                                "official-provider refreshing expired "
                                    + "ChatGPT credentials"
                            )
                            currentCredentials = try await
                                credentialRefreshAdapter.refresh()
                            continue
                        }
                        throw CodexPersistedTurnCoordinatorError
                            .missingResponseCompletion
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        if !didCommitResponse,
                           retryGate.consumeRetryIfEligible(
                                credentials: currentCredentials
                           )
                        {
                            record(
                                "official-provider refreshing expired "
                                    + "ChatGPT credentials"
                            )
                            currentCredentials = try await
                                credentialRefreshAdapter.refresh()
                            continue
                        }
                        throw error
                    }
                }
            } catch is CancellationError {
                cancellation.cancel()
                await send(
                    Self.chatGPTCompletionEvent(
                        requestID: request.requestID,
                        conversationID: conversationID
                    )
                )
            } catch {
                cancellation.cancel()
                let displayedError = CodexDesktopTurnSessionRunner
                    .displayedProviderError(
                        original: error,
                        transportPayload: providerTransportPayload
                    )
                let diagnostic =
                    CodexOfficialProviderStreamDiagnostic.make(
                        runID: providerRunID,
                        startedAtMs: providerStartedAtMs,
                        rendererModel: parsed.model,
                        providerModel: officialProviderModel,
                        authMethod: currentCredentials.authMethod,
                        terminalReason: providerTransportPayload == nil
                            ? "provider_stream_error"
                            : "provider_transport_error"
                    )
                    + " errorType="
                    + String(describing: type(of: error))
                record(diagnostic)
                userDefaults.set(
                    diagnostic,
                    forKey:
                        "codex.desktop.last-official-provider-diagnostic"
                )
                await send(
                    .event(
                        type: "fetch-stream-error",
                        payload: .object([
                            "requestId": .string(request.requestID),
                            "error": .string(
                                String(describing: displayedError)
                            ),
                        ])
                    )
                )
            }
            await send(
                .event(
                    type: "fetch-stream-complete",
                    payload: .object([
                        "requestId": .string(request.requestID),
                    ])
                )
            )
        }

        private static func chatGPTMessageEvent(
            requestID: String,
            conversationID: String,
            messageID: String,
            text: String,
            completed: Bool,
            parentMessageID: String?
        ) -> CodexDesktopHostMessage {
            return .event(
                type: "fetch-stream-event",
                payload: .object([
                    "requestId": .string(requestID),
                    "event": .string("message"),
                    // `fetch-stream-event` is already the decoded event-bus
                    // envelope.  Its non-delta decoder consumes the
                    // canonical `{conversation_id, message}` object in
                    // `data`; the wire `type`/`data` SSE envelope belongs
                    // only to messageData().
                    "data":
                        CodexDesktopConversationStreamAdapter
                            .messagePayloadValue(
                            conversationID: conversationID,
                            messageID: messageID,
                            text: text,
                            completed: completed,
                            parentMessageID: parentMessageID
                        ),
                ])
            )
        }

        private static func chatGPTCompletionEvent(
            requestID: String,
            conversationID: String
        ) -> CodexDesktopHostMessage {
            CodexDesktopConversationStreamAdapter.completionEvent(
                requestID: requestID,
                conversationID: conversationID
            )
        }

        private func recordStreamMessage(
            _ message: CodexDesktopHostMessage
        ) {
            lastFetchStreamDiagnostic.observe(message)
            switch message {
            case let .event(type, payload):
                let requestID: String
                if case let .object(fields) = payload,
                   case let .string(value)? = fields["requestId"]
                {
                    requestID = String(value.prefix(8))
                } else {
                    requestID = "unknown"
                }
                let detail: String
                if case let .object(fields) = payload,
                   case let .string(error)? = fields["error"]
                {
                    detail = " error=\(String(error.prefix(160)))"
                } else if type == "fetch-stream-event",
                          case let .object(fields) = payload,
                          case let .string(event)? = fields["event"],
                          case let .object(data)? = fields["data"]
                {
                    let dataKeys = data.keys.sorted().joined(separator: ",")
                    let messageBytes: Int
                    if case let .object(message)? = data["message"],
                       case let .object(content)? = message["content"],
                       case let .array(parts)? = content["parts"]
                    {
                        messageBytes = parts.reduce(0) { total, part in
                            if case let .string(value) = part {
                                return total + value.utf8.count
                            }
                            return total
                        }
                    } else {
                        messageBytes = 0
                    }
                    detail = " event=\(event) dataKeys=\(dataKeys)"
                        + " messageTextBytes=\(messageBytes)"
                } else if case let .object(fields) = payload,
                          case let .integer(status)? = fields["status"]
                {
                    detail = " status=\(status)"
                } else {
                    detail = ""
                }
                record(
                    "fetch-stream \(type) request=\(requestID)"
                        + detail
                )
                userDefaults.set(
                    "\(type) request=\(requestID)" + detail,
                    forKey: "codex.desktop.last-fetch-stream-diagnostic"
                )
            default:
                record("fetch-stream host-message")
            }
        }

        private func recordNetworkFetchMessage(
            request: CodexDesktopFetchRequest,
            response: CodexDesktopHostMessage
        ) {
            if URL(string: request.url)?.path
                .hasSuffix("/wham/statsig/bootstrap") == true
            {
                CodexDesktopStatsigSummaryGateDiagnosticStore(
                    userDefaults: userDefaults
                ).record(response: response)
                CodexDesktopStatsigVoiceConfigDiagnosticStore(
                    userDefaults: userDefaults
                ).record(response: response)
            }
            switch response {
            case let .fetchSuccess(_, status, _, _):
                self.recordNetworkFetchDiagnostic(
                    request: request,
                    status: status,
                    errorCode: nil
                )
                return
            case let .fetchFailure(_, status, _, errorCode):
                self.recordNetworkFetchDiagnostic(
                    request: request,
                    status: status,
                    errorCode: errorCode
                )
                return
            default:
                record("fetch network \(request.method) response=unexpected")
                return
            }
        }

        private func recordNetworkFetchDiagnostic(
            request: CodexDesktopFetchRequest,
            status: Int,
            errorCode: String?
        ) {
            let diagnostic = CodexDiagnosticSanitization.networkFetchSummary(
                method: request.method,
                requestURL: request.url,
                status: status,
                errorCode: errorCode
            )
            record(diagnostic)
            userDefaults.set(
                diagnostic,
                forKey: "codex.desktop.last-network-fetch-diagnostic"
            )
        }

    private static func isAttestationChallengeRequest(
        _ request: CodexDesktopFetchRequest
    ) -> Bool {
        URL(string: request.url)?.path
            .hasSuffix("/ios/attestation_challenge") == true
    }

    /// The released renderer performs a preparation POST before opening
    /// `/f/conversation`. New local threads have no server conversation id,
    /// so forwarding this request upstream yields a 422 before the native
    /// provider stream can start. Keep this preparation contract local.
    private static func isConversationPrepareRequest(
        _ request: CodexDesktopFetchRequest
    ) -> Bool {
        URL(string: request.url)?.path
            .hasSuffix("/f/conversation/prepare") == true
    }

        private func handleNativeChannel(
            name: String,
            payload: CodexJSONValue
        ) async throws -> CodexJSONValue? {
            if name
                == CodexDesktopAppHostSessionStore
                    .messageChannel,
                case let .object(fields) = payload,
                case let .string(frame)? = fields["frame"]
            {
                record(
                    "app-host-frame-in "
                        + String(frame.prefix(1_000))
                )
            }
            if let appHostSessions {
                switch try await appHostSessions
                    .handleNativeChannelAsync(
                    name: name,
                    payload: payload
                ) {
                case .notHandled:
                    break
                case let .handled(response):
                    if name
                        == CodexDesktopAppHostSessionStore
                            .connectedChannel
                    {
                        startupGate.resetAppHostServices()
                        record("app-host-connected")
                    }
                    if let reply = response.reply,
                       case let .string(frame) = reply
                    {
                        record(
                            "app-host-frame-out "
                                + String(frame.prefix(1_000))
                        )
                    }
                    return response.reply
                }
            }

            switch name {
            case CodexDesktopRendererRouteObservationScript.messageChannel:
                guard case let .object(fields) = payload,
                      case let .string(path)? = fields["path"],
                      !path.isEmpty
                else {
                    throw CodexDesktopWebViewHostError
                        .invalidScriptMessagePayload
                }
                lastActiveLocalThreadStore.recordRendererPath(path)
                record("renderer-route \(path)")
                return nil
            case "renderer-diagnostic":
                if case let .object(fields) = payload,
                   case let .string(kind)? = fields["kind"]
                {
                    if kind == "renderer-exception" {
                        focusedDiagnosticStore
                            .recordRendererException(payload)
                    } else if kind == "hardware-shortcut" {
                        focusedDiagnosticStore
                            .recordHardwareShortcut(
                                "source=dom payload="
                                    + Self.compactDescription(
                                        CodexDesktopFocusedDiagnosticStore
                                            .sanitizedRendererDiagnosticPayload(payload)
                                    )
                            )
                    } else if kind == "webkit-entry-probe" {
                        focusedDiagnosticStore.recordWebKitViewport(payload)
                    }
                }
                record(
                    "renderer-diagnostic "
                        + Self.compactDescription(
                            CodexDesktopFocusedDiagnosticStore
                                .sanitizedRendererDiagnosticPayload(payload)
                        )
                )
                return nil
            case CodexDesktopInteractiveSurfaceProbe.channel:
                return nil
            case "fast-mode-rollout-metrics":
                return .object([:])
            case "chunked-message-ack":
                record("native-channel \(name)")
                return nil
            case "start-file-drag",
                 "trigger-sentry-test-error":
                record("native-channel \(name)")
                return nil
            case "worker-message":
                guard case let .object(fields) = payload,
                      case let .string(workerID)? = fields["workerID"],
                      let message = fields["message"]
                else {
                    throw CodexDesktopWorkerBusError.invalidEnvelope
                }
                try await workerBus.receive(
                    workerID: workerID,
                    message: message
                )
                record("worker-message \(workerID)")
                return nil
            default:
                if ProcessInfo.processInfo.environment[
                    "CODEXPAD_UI_TEST_VOICE_DIAGNOSTIC"
                ] == "1",
                   name.hasPrefix("voice-debug-")
                {
                    if name.hasPrefix("voice-debug-webrtc-") {
                        let entry =
                            name + " " + Self.compactDescription(payload)
                        var history = userDefaults.stringArray(
                            forKey:
                                "codex.desktop.voice-webrtc-diagnostics"
                        ) ?? []
                        history.append(entry)
                        if history.count > 100 {
                            history.removeFirst(history.count - 100)
                        }
                        userDefaults.set(
                            history,
                            forKey:
                                "codex.desktop.voice-webrtc-diagnostics"
                        )
                    }
                    record(
                        "voice-diagnostic \(name) "
                            + Self.compactDescription(payload)
                    )
                    return nil
                }
                record("unhandled-native-channel \(name)")
                return nil
            }
        }

        fileprivate func send(
            _ message: CodexDesktopHostMessage
        ) async {
            guard let host else {
                return
            }
            do {
                try await host.send(message)
                if case let .event(type, _) = message,
                   type.hasPrefix("fetch-stream-")
                {
                    recordStreamMessage(message)
                }
            } catch {
                recordFailure(error)
            }
        }

        /// Realtime voice is owned by the released avatar-overlay renderer,
        /// while the primary renderer still owns the conversation surface.
        /// Electron broadcasts app-server notifications to both renderer
        /// contexts; mirror that behavior so the overlay's PeerConnection can
        /// consume SDP and subsequent realtime transcript/session events.
        private func broadcastRealtimeNotification(
            _ message: CodexDesktopHostMessage
        ) async {
            await send(message)
            guard let avatarOverlayHost else {
                return
            }
            do {
                try await avatarOverlayHost.send(message)
            } catch {
                recordFailure(error)
            }
        }

        private func send(
            _ message: CodexDesktopHostMessage,
            replyingTo replyHost: CodexDesktopWebViewHost?
        ) async {
            guard let replyHost else {
                await send(message)
                return
            }
            do {
                try await replyHost.send(message)
            } catch {
                recordFailure(error)
            }
        }

        private func sendAppHostFrame(
            _ frame: CodexDesktopAppHostOutboundFrame
        ) async {
            switch CodexDesktopAppHostSurfaceTarget.resolve(
                portID: frame.portID
            ) {
            case .primary:
                await send(frame.hostMessage)
            case .avatarOverlay:
                guard let avatarOverlayHost else {
                    record(
                        "avatar-overlay app-host frame dropped port="
                            + frame.portID
                    )
                    return
                }
                do {
                    try await avatarOverlayHost.send(frame.hostMessage)
                } catch {
                    recordFailure(error)
                }
            }
        }

        /// Replays a released Electron menu accelerator into the renderer.
        public func performNativeShortcut(
            _ shortcut: CodexDesktopNativeShortcut
        ) {
            guard hardwareShortcutDispatchGate.shouldDispatch(
                shortcut,
                timestamp: ProcessInfo.processInfo.systemUptime
            ) else {
                focusedDiagnosticStore.recordHardwareShortcut(
                    "source=uikit shortcut=\(shortcut) status=duplicate"
                )
                return
            }
            Task { @MainActor [weak self] in
                guard let self,
                      let message = shortcut.rendererMessage
                else {
                    self?.focusedDiagnosticStore
                        .recordHardwareShortcut(
                            "source=uikit shortcut=\(shortcut) status=invalid"
                        )
                    self?.record("invalid hardware-shortcut \(shortcut)")
                    return
                }
                focusedDiagnosticStore.recordHardwareShortcut(
                    "source=uikit shortcut=\(shortcut) status=dispatching"
                )
                await self.send(message)
                if shortcut == .openReviewTab {
                    self.userDefaults.set(
                        "hardware-shortcut openReviewTab",
                        forKey: Self.lastReviewDiagnosticKey
                    )
                }
                guard shortcut == .settings
                        || shortcut == .keyboardShortcuts
                else {
                    focusedDiagnosticStore.recordHardwareShortcut(
                        "source=uikit shortcut=\(shortcut) status=forwarded"
                    )
                    self.record("hardware-shortcut \(shortcut)")
                    return
                }
                await self.recordRendererPath(
                    shortcut: shortcut,
                    phase: "dispatched"
                )
                try? await Task.sleep(for: .milliseconds(300))
                await self.recordRendererPath(
                    shortcut: shortcut,
                    phase: "settled"
                )
            }
        }

        func recordNativeGeometry(
            _ snapshot: CodexDesktopNativeGeometrySnapshot
        ) {
            focusedDiagnosticStore.recordNativeGeometry(
                CodexDesktopNativeGeometryDiagnostic.payload(snapshot)
            )
        }

        private func recordRendererPath(
            shortcut: CodexDesktopNativeShortcut,
            phase: String
        ) async {
            guard let host else {
                let diagnostic =
                    "source=uikit shortcut=\(shortcut) phase=\(phase) "
                    + "path=unavailable"
                focusedDiagnosticStore.recordHardwareShortcut(
                    diagnostic
                )
                record("hardware-shortcut \(shortcut) \(phase)-path=unavailable")
                return
            }
            do {
                let path = try await host.currentRendererPath()
                let renderedPath = path ?? "outside-app-origin"
                focusedDiagnosticStore.recordHardwareShortcut(
                    "source=uikit shortcut=\(shortcut) phase=\(phase) "
                        + "path=\(renderedPath)"
                )
                record("hardware-shortcut \(shortcut) \(phase)-path=" + renderedPath)
            } catch {
                let diagnostic =
                    "source=uikit shortcut=\(shortcut) phase=\(phase) "
                    + "path-error-type=" + String(describing: type(of: error))
                focusedDiagnosticStore.recordHardwareShortcut(
                    diagnostic
                )
                record("hardware-shortcut \(shortcut) \(phase)-path-error-type " + String(describing: type(of: error)))
            }
        }

        private func handleAutomationViewEvent(
            type: String,
            payload: CodexJSONValue
        ) async -> Bool {
            guard type == "inbox-item-set-read-state"
                    || type
                        == "inbox-automation-runs-mark-all-read"
            else {
                return false
            }
            guard let automationStore else {
                record("automation-store unavailable \(type)")
                return true
            }

            do {
                switch type {
                case "inbox-item-set-read-state":
                    guard case let .object(fields) = payload,
                          case let .string(id)? = fields["id"],
                          !id.isEmpty,
                          case let .bool(isRead)? =
                              fields["isRead"]
                    else {
                        record(
                            "invalid automation view-event \(type)"
                        )
                        return true
                    }
                    if try automationStore.setInboxItemRead(
                        id: id,
                        isRead: isRead
                    ) {
                        await sendInboxItemsChanged()
                    }
                default:
                    guard case let .object(fields) = payload
                    else {
                        record(
                            "invalid automation view-event \(type)"
                        )
                        return true
                    }
                    let readAt: Int64?
                    switch fields["readAt"] {
                    case let .integer(value)?:
                        readAt = value
                    case let .number(value)?
                        where value.isFinite
                            && value >= Double(Int64.min)
                            && value <= Double(Int64.max):
                        readAt = Int64(value)
                    case nil, .null?:
                        readAt = nil
                    default:
                        record(
                            "invalid automation view-event \(type)"
                        )
                        return true
                    }
                    try automationStore.markAllAutomationRunsRead(
                        at: readAt
                    )
                    await sendInboxItemsChanged()
                }
                record("automation view-event \(type)")
            } catch {
                record(
                    "automation view-event failure "
                        + CodexDiagnosticSanitization.publicErrorSummary(error)
                )
            }
            return true
        }

        private func sendInboxItemsChanged() async {
            await send(
                .event(
                    type: "inbox-items-changed",
                    payload: .object([:])
                )
            )
        }

        private func sendPinnedThreadsUpdated() async {
            await send(
                .event(
                    type: "pinned-threads-updated",
                    payload: .object([:])
                )
            )
        }

        private func sendGlobalStateUpdated(
            keys: [String]
        ) async {
            await send(
                .event(
                    type: "global-state-updated",
                    payload: .object([
                        "keys": .array(
                            keys.map(
                                CodexJSONValue.string
                            )
                        )
                    ])
                )
            )
        }

        private func sendTurnNotification(
            _ notification: CodexAppServerTurnNotification
        ) async {
            do {
                let wire =
                    try CodexAppServerTurnNotificationEncoder
                        .wire(notification)
                await send(
                    .mcpNotification(
                        hostID: "local",
                        method: wire.method,
                        params: wire.params,
                        metadata: [:]
                    )
                )
                record("mcp-notification \(wire.method)")
            } catch {
                recordFailure(error)
            }
        }

        private func enqueueTurnNotification(
            _ notification: CodexAppServerTurnNotification
        ) {
            let previous = turnNotificationTail
            turnNotificationTail = Task { [weak self] in
                await previous?.value
                await self?.sendTurnNotification(notification)
            }
        }

        private func enqueueAppServerNotifications(
            _ notifications: [CodexAppServerNotification]
        ) {
            let messages =
                CodexDesktopAppServerNotificationProjector.messages(
                    notifications,
                    hostID: "local"
                )
            guard !messages.isEmpty else {
                return
            }
            let previous = turnNotificationTail
            turnNotificationTail = Task { [weak self] in
                await previous?.value
                guard let self else {
                    return
                }
                for message in messages {
                    await self.send(message)
                    if case let .mcpNotification(_, method, _, _) = message {
                        self.record("mcp-notification \(method)")
                    }
                }
            }
        }

        private func sendCommandOutput(
            _ output: CodexDesktopCommandExecOutputDelta
        ) async {
            await send(
                .mcpNotification(
                    hostID: "local",
                    method: "command/exec/outputDelta",
                    params: output.json,
                    metadata: [:]
                )
            )
            record("mcp-notification command/exec/outputDelta")
        }

        private func sendProcessOutput(
            _ output: CodexDesktopCommandExecOutputDelta
        ) async {
            await send(
                .mcpNotification(
                    hostID: "local",
                    method: "process/outputDelta",
                    params: output.processJSON,
                    metadata: [:]
                )
            )
            record("mcp-notification process/outputDelta")
        }

        private func sendProcessExited(
            _ exited: CodexDesktopProcessExited
        ) async {
            await send(
                .mcpNotification(
                    hostID: "local",
                    method: "process/exited",
                    params: exited.json,
                    metadata: [:]
                )
            )
            record("mcp-notification process/exited")
        }

    private func openHomeDataGateIfReady() {
            guard let host else {
                return
            }

            if startupGate.canMarkBridgeReady,
               host.state == .awaitingBridgeReady
            {
                do {
                    try host.markBridgeReady()
                } catch {
                    recordFailure(error)
                    return
                }
            }

            guard !didOpenHomeDataGate,
                  startupGate.canMarkHomeDataReady,
                  host.state == .awaitingHomeData
            else {
                return
            }
            do {
                try host.markHomeDataLoaded()
                didOpenHomeDataGate = true
                record("home-data-ready")
            } catch {
                recordFailure(error)
            }
        }

        private func resetHomeDataGate() {
            startupGate.reset()
            sharedObjects.resetSubscriptions()
            didOpenHomeDataGate = false
            Task {
                await workerBus.cancelAll()
            }
            for task in fetchStreamTasks.values {
                task.cancel()
            }
            fetchStreamTasks.removeAll()
            lastFetchStreamDiagnostic.reset()
        }

        private static func isReleasedBridgeEvidence(
            _ event: CodexDesktopWebViewInboundEvent
        ) -> Bool {
            if case let .nativeChannel(name, _) = event {
                return name
                    != CodexDesktopWebViewEntryDiagnosticProbe.channel
                    && name
                        != CodexDesktopInteractiveSurfaceProbe.channel
            }
            return true
        }

        private struct DesktopMCPRouteResult {
            let preResponseMessages: [CodexDesktopHostMessage]
            let response: CodexDesktopHostMessage
            let postResponseMessages: [CodexDesktopHostMessage]
            let isLoginResponse: Bool
        }

        /// Shared semantic MCP entry used by both the released WebView and
        /// remote-control virtual sessions. Keeping the login router and the
        /// full desktop capability router behind one boundary prevents the
        /// remote path from drifting into a reduced method subset.
        public func response(
            toDesktopMCPRequest request: CodexDesktopMCPRequest
        ) async -> CodexDesktopHostMessage {
            await routeDesktopMCPRequest(request).response
        }

        private func routeDesktopMCPRequest(
            _ request: CodexDesktopMCPRequest
        ) async -> DesktopMCPRouteResult {
            if let loginCoordinator,
               let exchange = await loginCoordinator.exchange(to: request)
            {
                return .init(
                    preResponseMessages: [],
                    response: exchange.response,
                    postResponseMessages:
                        exchange.postResponseMessages,
                    isLoginResponse: true
                )
            }
            if let remoteControlBridge,
               let response = await remoteControlBridge.response(to: request)
            {
                return .init(
                    preResponseMessages: [],
                    response: response,
                    postResponseMessages: [],
                    isLoginResponse: false
                )
            }
            var preResponseMessages: [CodexDesktopHostMessage] = []
            let response = await CodexDesktopInitialMCPRouter
                .responseIncludingFileSystem(
                    to: request,
                    state: makeInitialMCPState(),
                    allowedFileSystemRoots: allowedFileSystemRoots(),
                    threadLister: sessionStore,
                    modelLister: sessionStore,
                    turnStarter: desktopTurnRunner ?? sessionStore,
                    commandExecutor: commandExecutor,
                    accountStore: accountStore,
                    configStore: configStore,
                    memoryResetter: memoryResetService,
                    rateLimitsReader: accountStore.map {
                        CodexAccountRateLimitsClient(accountStore: $0)
                    },
                    fileWatcher: fileWatchManager,
                    fuzzyFileSearch: fuzzyFileSearchService,
                    mcpStatusLister: mcpRuntimeRegistry,
                    mcpResourceReader: mcpRuntimeRegistry,
                    mcpToolCaller: mcpRuntimeRegistry,
                    mcpRefresher: mcpRuntimeRegistry,
                    mcpOAuthLogin: mcpOAuthCoordinator,
                    skillCatalog: skillCatalog,
                    hookCatalog: hookCatalog,
                    appCatalog: appCatalog,
                    appListUpdated: {
                        preResponseMessages.append($0)
                    },
                    settingsCatalog: settingsCatalog,
                    marketplaceManager: marketplaceManager,
                    pluginCatalog: pluginCatalog,
                    remotePluginCatalog: remotePluginCatalog,
                    externalAgentConfig:
                        externalAgentConfigMigrationService,
                    gitDiffer: gitDiffer,
                    feedbackUploader: feedbackUploadService,
                    environmentManager: environmentService,
                    realtimeManager: realtimeService,
                    extendedSessionBackend:
                        extendedSessionBackend
                )
            if request.request.method == "thread/start",
               case let .object(params)? = request.request.params,
               case let .string(cwd)? = params["cwd"],
               case let .mcpResponse(
                   _,
                   .object(envelope),
                   _
               ) = response,
               case let .object(result)? = envelope["result"],
               case let .object(thread)? = result["thread"],
               case let .string(threadID)? = thread["id"]
            {
                _ = projectlessOutputDirectoryStore.associate(
                    threadID: threadID,
                    cwd: cwd
                )
                lastActiveLocalThreadStore.recordDurableThreadID(
                    threadID,
                    source: "thread-start"
                )
            }
            var postResponseMessages =
                CodexDesktopAppServerNotificationProjector.messages(
                    sessionStore.takeAppServerNotifications(),
                    hostID: request.hostID
                )
            if request.request.method == "account/logout",
               Self.isSuccessfulMCPResponse(response)
            {
                // The released renderer keeps its auth cache current from
                // account/updated. The request result alone clears Keychain,
                // but leaves the visible route authenticated until this
                // app-server notification arrives.
                postResponseMessages.append(
                    .mcpNotification(
                        hostID: request.hostID,
                        method: "account/updated",
                        params: .object([
                            "authMode": .null,
                            "planType": .null,
                        ]),
                        metadata: [:]
                    )
                )
            }
            return .init(
                preResponseMessages: preResponseMessages,
                response: response,
                postResponseMessages: postResponseMessages,
                isLoginResponse: false
            )
        }

        private func synchronizeRemoteControlRenderer() async {
            guard let remoteControlBridge else {
                return
            }
            do {
                await send(
                    try await remoteControlBridge
                        .currentStatusNotification()
                )
            } catch {
                record(
                    "remote-control status-read "
                        + CodexDiagnosticSanitization.publicErrorSummary(error)
                )
            }
            guard remoteControlStatusTask == nil else {
                return
            }
            remoteControlStatusTask = Task {
                [weak self, remoteControlBridge] in
                let notifications =
                    await remoteControlBridge.statusNotifications()
                do {
                    for try await notification in notifications {
                        guard !Task.isCancelled else {
                            return
                        }
                        await self?.send(notification)
                    }
                } catch is CancellationError {
                    return
                } catch {
                    self?.record(
                        "remote-control status-stream "
                            + CodexDiagnosticSanitization.publicErrorSummary(error)
                    )
                }
                self?.remoteControlStatusTask = nil
            }
        }

        /// Shared response sink for renderer and remote virtual sessions.
        public func receiveDesktopMCPClientResponse(
            hostID: String,
            response: CodexDesktopMCPClientResponse
        ) {
            let consumedByServerRequest = serverRequestBroker?.receive(
                hostID: hostID,
                response: response
            ) == true
            let consumedByDynamicTool =
                dynamicToolCallBroker?.receive(
                    hostID: hostID,
                    response: response
                ) == true
            let consumedByUserInput = requestUserInputBroker?.receive(
                hostID: hostID,
                response: response
            ) == true
            if !consumedByServerRequest
                && !consumedByDynamicTool
                && !consumedByUserInput
            {
                approvalBroker?.receive(
                    hostID: hostID,
                    response: response
                )
            }
            record("mcp-response \(response.id)")
        }

        fileprivate func requestPersistedTurnPermission(
            _ approval: CodexDesktopApprovalRequest
        ) async -> CodexJSONValue? {
            await approvalBroker?.request(approval)
        }

        /// Builds the logical-session router with the same semantic MCP
        /// boundary used by the released renderer.
        public func makeRemoteControlVirtualSessionRouter()
            -> CodexRemoteControlVirtualSessionRouter
        {
            CodexRemoteControlVirtualSessionRouter {
                [weak self] identity in
                CodexRemoteControlDesktopSemanticSession(
                    identity: identity,
                    routeRequest: { [weak self] request in
                        await self?.response(
                            toDesktopMCPRequest: request
                        )
                    },
                    receiveNonRequest: { [weak self] message in
                        await self?.receiveRemoteControlNonRequest(
                            message,
                            hostID: identity.desktopHostID
                        )
                    }
                )
            }
        }

        private func receiveRemoteControlNonRequest(
            _ message: CodexJSONValue,
            hostID: String
        ) {
            guard case let .object(fields) = message,
                  fields["method"] == nil,
                  fields["result"] != nil || fields["error"] != nil,
                  let id = Self.remoteControlResponseID(fields["id"])
            else {
                return
            }
            receiveDesktopMCPClientResponse(
                hostID: hostID,
                response: .init(
                    id: id,
                    result: fields["result"],
                    error: fields["error"]
                )
            )
        }

        private static func remoteControlResponseID(
            _ value: CodexJSONValue?
        ) -> CodexAppServerRequestID? {
            switch value {
            case let .string(id)?: .string(id)
            case let .integer(id)?: .integer(id)
            default: nil
            }
        }

        private func sendSharedObjectUpdate(
            key: String,
            lookup: CodexDesktopSharedObjectLookup
        ) async {
            var payload: [String: CodexJSONValue] = [
                "key": .string(key)
            ]
            if case let .value(value) = lookup {
                payload["value"] = value
            }
            await send(
                .event(
                    type: "shared-object-updated",
                    payload: .object(payload)
                )
            )
        }

        private static func isSuccessfulFetchResponse(
            _ response: CodexDesktopHostMessage
        ) -> Bool {
            guard case let .fetchSuccess(
                _,
                status,
                _,
                _
            ) = response else {
                return false
            }
            return (200 ..< 300).contains(status)
        }

        private static func fetchRequestKey(
            _ request: CodexDesktopFetchRequest
        ) -> String? {
            guard let body = request.body,
                  let data = body.data(using: .utf8),
                  let value = try? JSONDecoder().decode(
                      CodexJSONValue.self,
                      from: data
                  ),
                  case let .object(fields) = value,
                  case let .string(key)? = fields["key"],
                  !key.isEmpty
            else {
                return nil
            }
            return key
        }

        private static func isSuccessfulMCPResponse(
            _ response: CodexDesktopHostMessage
        ) -> Bool {
            guard case let .mcpResponse(
                _,
                message,
                _
            ) = response,
                case let .object(fields) = message
            else {
                return false
            }
            return fields["result"] != nil
                && fields["error"] == nil
        }

        private func makeInitialHostState(
            for request: CodexDesktopFetchRequest
        ) -> CodexDesktopInitialHostState {
            let paths = hostFilesystemPaths()
            let activeRoots = activeWorkspaceRoots()
            let workspaceRoots = workspaceRootOptions()
            let automationSnapshot = automationStore?.snapshot()
            var globalState = persistedAtoms.snapshot
            var localProjectGlobalState =
                localProjectsStateStore.synchronize(
                    workspaces: sessionStore.state.workspaces,
                    selectedProject:
                        selectedProjectStore.globalStateValue,
                    rootPath: workspaceRootPath
                )
            let localProjectIDs: [String]
            if case let .array(values)? =
                localProjectGlobalState["project-order"]
            {
                localProjectIDs = values.compactMap {
                    guard case let .string(value) = $0 else {
                        return nil
                    }
                    return value
                }
            } else {
                localProjectIDs = []
            }
            localProjectGlobalState.removeValue(forKey: "project-order")
            globalState.merge(localProjectGlobalState) { _, releasedValue in
                releasedValue
            }
            globalState["project-order"] = .array(
                Self.mergedReleasedProjectOrder(
                    persistedOrder: persistedAtoms.snapshot[
                        "project-order"
                    ],
                    localProjectIDs: localProjectIDs,
                    remoteProjects: persistedAtoms.snapshot[
                        "remote-projects"
                    ]
                ).map(CodexJSONValue.string)
            )
            globalState[
                CodexDesktopPinnedThreadStore.releasedStorageKey
            ] = pinnedThreadStore.globalStateValue
            globalState[
                CodexDesktopThreadProjectAssignmentStore
                    .releasedStorageKey
            ] = threadProjectAssignmentStore.globalStateValue
            let configuredSettings = configStore.snapshot
            var existingPaths = Set(
                [
                    paths.codexHome.path,
                    paths.worktrees.path,
                    paths.applicationRoot.path,
                ] + workspaceRoots
            )
            if fileManager.fileExists(
                atPath: paths.commandKeymap.path
            ) {
                existingPaths.insert(paths.commandKeymap.path)
            }
            if request.hostMethod == "paths-exist",
               let body = request.body,
               let data = body.data(using: .utf8),
               let value = try? JSONDecoder().decode(
                   CodexJSONValue.self,
                   from: data
               ),
               case let .object(fields) = value,
               case let .array(values)? = fields["paths"]
            {
                for value in values {
                    guard case let .string(path) = value,
                          fileManager.fileExists(atPath: path)
                    else {
                        continue
                    }
                    existingPaths.insert(path)
                }
            }

            let locale =
                Locale.current.identifier
                    .replacingOccurrences(of: "_", with: "-")
            let accountInfo: CodexJSONValue?
            if let accountStore,
               accountStore.isChatGPTSignedIn
            {
                accountInfo = .object([
                    "userId": accountStore.userID.map {
                        .string($0)
                    } ?? .null,
                    "accountId": accountStore.accountID.map {
                        .string($0)
                    } ?? .null,
                    "email": accountStore.email.map {
                        .string($0)
                    } ?? .null,
                    "plan": accountStore.planType.map {
                        .string($0.rawValue)
                    } ?? .string("unknown"),
                    "computeResidency": .null,
                    "hasChatGptToken": .bool(true),
                ])
            } else {
                accountInfo = nil
            }
            return CodexDesktopInitialHostState(
                codexHome: paths.codexHome.path,
                worktreesSegment: paths.worktrees.path,
                // iPadOS and macOS share Darwin. The released renderer
                // branches on Node's platform vocabulary.
                platform: "darwin",
                osVersion: UIDevice.current.systemVersion,
                osRelease:
                    ProcessInfo.processInfo
                        .operatingSystemVersionString,
                isSystemBackdropSupported: false,
                isVsCodeRunningInsideWsl: false,
                windowsAccountType: "unknown",
                isCopilotAPIAvailable: false,
                configuredSettings: configuredSettings,
                effectiveSettings:
                    CodexDesktopReleasedSettings.effectiveValues(
                        configured: configuredSettings
                    ),
                globalState: globalState,
                ideLocale: locale,
                systemLocale: locale,
                automationItems:
                    automationSnapshot?.items ?? [],
                activeWorkspaceRoots: activeRoots,
                workspaceRootOptions: workspaceRoots,
                remoteControlConnections: [],
                inboxItems:
                    automationSnapshot?.inboxItems ?? [],
                unreadRunCount:
                    automationSnapshot?.unreadRunCount ?? 0,
                unreadAutomationIDs:
                    automationSnapshot?
                        .unreadAutomationIDs ?? [],
                unreadRuns:
                    automationSnapshot?.unreadRuns ?? [],
                commandKeymapPath: paths.commandKeymap.path,
                commandKeyBindings: [],
                existingPaths: existingPaths,
                pinnedThreadIDs: pinnedThreadStore.threadIDs,
                accountInfo: accountInfo
            )
        }

        private func makeInitialMCPState()
            -> CodexDesktopInitialMCPState
        {
            let account =
                accountStore?.desktopAccountState
                ?? CodexDesktopMCPAccountState(
                    account: nil,
                    authMethod: nil,
                    requiresOpenAIAuth: true
                )
            let accountKind: String
            switch account.account {
            case .apiKey:
                accountKind = "apiKey"
            case let .chatGPT(_, planType):
                accountKind = "chatgpt plan=\(planType.rawValue)"
            case let .amazonBedrock(usesManagedCredentials):
                accountKind =
                    "amazonBedrock managed=\(usesManagedCredentials)"
            case nil:
                accountKind = "signedOut"
            }
            record(
                "initial-mcp-account kind=\(accountKind) "
                    + "authMethod="
                    + (account.authMethod?.rawValue ?? "none")
                    + " requiresOpenaiAuth="
                    + String(account.requiresOpenAIAuth)
            )
            return CodexDesktopInitialMCPState(
                account: account,
                config: CodexDesktopMCPConfigState(
                    config: [:],
                    origins: [:],
                    layers: []
                ),
                remoteControl: CodexDesktopMCPRemoteControlState(
                    status: .disabled,
                    serverName: "Codex for ipad",
                    installationID: installationID(),
                    environmentID: nil
                )
            )
        }

        private func handleProjectQuery(
            method: String,
            request: CodexDesktopAppHostRPC.Value?
        ) async throws -> CodexDesktopAppHostRPC.Value {
            synchronizeLocalProjectsState()
            switch method {
            case "getRemoteProjects":
                return rpcValue(
                    from: persistedAtoms.snapshot["remote-projects"]
                        ?? .array([])
                )
            case "getProjectAppearances":
                return rpcValue(
                    from: persistedAtoms.snapshot["project-appearances"]
                        ?? .object([:])
                )
            case "getProjectRootPathsForHost":
                guard case let .string(hostID) = request,
                      !hostID.trimmingCharacters(
                          in: .whitespacesAndNewlines
                      ).isEmpty
                else {
                    throw CodexDesktopProjectAppHostService.Error
                        .invalidArguments
                }
                if hostID == "local" {
                    return .array(
                        workspaceRootOptions().map {
                            CodexDesktopAppHostRPC.Value.string($0)
                        }
                    )
                }
                let roots: [String]
                if case let .array(remoteProjects)? =
                    persistedAtoms.snapshot["remote-projects"]
                {
                    roots = remoteProjects.compactMap { value in
                        guard case let .object(fields) = value,
                              fields["hostId"] == .string(hostID),
                              case let .string(path)? = fields["remotePath"]
                        else {
                            return nil
                        }
                        return path
                    }
                } else {
                    roots = []
                }
                return .array(
                    roots.map {
                        CodexDesktopAppHostRPC.Value.string($0)
                    }
                )
            case "createOrSelectLocalProjects":
                guard case let .array(roots)? = request else {
                    throw CodexDesktopProjectAppHostService.Error
                        .invalidArguments
                }
                let records = try await createOrSelectLocalProjects(
                    roots: roots.compactMap(Self.nonemptyString)
                )
                return .array(records.map(localProjectRecordValue))
            case "createProjectForRoot":
                guard case let .object(fields)? = request,
                      let root = Self.nonemptyString(fields["root"])
                else {
                    throw CodexDesktopProjectAppHostService.Error
                        .invalidArguments
                }
                let name = Self.string(fields["name"])
                let record = try await createProjectForRoot(
                    root: root,
                    name: name
                )
                return localProjectRecordValue(record)
            case "assignUnassignedThreadsBeforeProjectRootsChange":
                guard case let .array(roots)? = request else {
                    throw CodexDesktopProjectAppHostService.Error
                        .invalidArguments
                }
                try await assignUnassignedThreadsBeforeProjectRootsChange(
                    roots: roots.compactMap(Self.nonemptyString)
                )
                return .undefined
            case "getActiveWorkspaceRoots":
                return .object([
                    "roots": .array(
                        activeWorkspaceRoots().map(CodexDesktopAppHostRPC.Value.string)
                    ),
                ])
            case "getLocalProjects", "getLocalProjectsForRenderer":
                return localProjectsValue(
                    from: localProjectsStateStore.projectsInOrder
                )
            case "getLocalProjectsForDesktopState":
                guard case let .object(projects)? = request else {
                    throw CodexDesktopProjectAppHostService.Error.invalidArguments
                }
                return rpcValue(
                    from: .object(
                        projects.mapValues { value in
                            Self.codexJSONValue(value) ?? .null
                        }
                    )
                )
            case "getLocalWorkspaceRootOptionsSync":
                return workspaceRootOptionsValue(
                    roots: workspaceRootOptions()
                )
            case "getWorkspaceRootOptions":
                guard case let .object(host)? = request else {
                    throw CodexDesktopProjectAppHostService.Error.invalidArguments
                }
                guard case let .string(hostID)? = host["id"] else {
                    throw CodexDesktopProjectAppHostService.Error.invalidArguments
                }
                guard hostID == "local" else {
                    throw CodexDesktopProjectAppHostService.Error
                        .platformHandlerUnavailable(
                            service: "projects",
                            method: method
                        )
                }
                return workspaceRootOptionsValue(
                    roots: workspaceRootOptions()
                )
            case "hasProjectNamed":
                guard case let .string(name)? = request else {
                    throw CodexDesktopProjectAppHostService.Error.invalidArguments
                }
                let wanted = name.trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
                return .bool(
                    localProjectsStateStore.projectsInOrder.contains {
                        $0.name.trimmingCharacters(
                            in: .whitespacesAndNewlines
                        ) == wanted
                    }
                )
            default:
                throw CodexDesktopProjectAppHostService.Error.unsupportedMethod(
                    service: "projects",
                    method: method
                )
            }
        }

        private func createOrSelectLocalProjects(
            roots: [String]
        ) async throws -> [CodexDesktopLocalProjectRecord] {
            let normalizedRoots = roots.map { URL(fileURLWithPath: $0)
                .standardizedFileURL.path }
            guard !normalizedRoots.isEmpty else { return [] }
            var records: [CodexDesktopLocalProjectRecord] = []
            for root in normalizedRoots {
                records.append(
                    try await createProjectForRoot(root: root, name: nil)
                )
            }
            if let selected = records.last,
               let uuid = UUID(uuidString: selected.id)
            {
                selectedProjectStore.setSelectedWorkspaceID(uuid)
            }
            await publishLocalProjectsStateChange()
            return records
        }

        private func createProjectForRoot(
            root: String,
            name: String?
        ) async throws -> CodexDesktopLocalProjectRecord {
            let normalizedRoot = URL(fileURLWithPath: root)
                .standardizedFileURL.path
            if let existing = localProjectsStateStore.projectsInOrder
                .first(where: { $0.rootPaths.contains(normalizedRoot) })
            {
                return existing
            }
            let projectID = UUID().uuidString.lowercased()
            let resolvedName = name?.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).isEmpty == false
                ? name!.trimmingCharacters(in: .whitespacesAndNewlines)
                : URL(fileURLWithPath: normalizedRoot).lastPathComponent
            let record = localProjectsStateStore.createProject(
                projectID: projectID,
                name: resolvedName.isEmpty ? normalizedRoot : resolvedName,
                rootPaths: [normalizedRoot]
            )
            await publishLocalProjectsStateChange()
            return record
        }

        private func assignUnassignedThreadsBeforeProjectRootsChange(
            roots: [String]
        ) async throws {
            let normalizedRoots = Set(
                roots.map { URL(fileURLWithPath: $0)
                    .standardizedFileURL.path }
            )
            guard !normalizedRoots.isEmpty else { return }
            // The iPad catalog does not expose Electron's unassigned-thread
            // scanner. Preserve the released mutation boundary by ensuring
            // project metadata is synchronized before roots are consumed.
            synchronizeLocalProjectsState()
            await publishLocalProjectsStateChange()
        }

        private func localProjectRecordValue(
            _ record: CodexDesktopLocalProjectRecord
        ) -> CodexDesktopAppHostRPC.Value {
            .object([
                "createdAt": .integer(record.createdAt),
                "id": .string(record.id),
                "name": .string(record.name),
                "rootPaths": .array(
                    record.rootPaths.map {
                        CodexDesktopAppHostRPC.Value.string($0)
                    }
                ),
                "updatedAt": .integer(record.updatedAt),
            ])
        }

        private func localProjectsValue(
            from records: [CodexDesktopLocalProjectRecord]
        ) -> CodexDesktopAppHostRPC.Value {
            let values = Dictionary(
                uniqueKeysWithValues: records.map { record in
                    (
                        record.id,
                        CodexDesktopAppHostRPC.Value.object([
                            "id": .string(record.id),
                            "name": .string(record.name),
                            "rootPaths": .array(
                                record.rootPaths.map(
                                    CodexDesktopAppHostRPC.Value.string
                                )
                            ),
                            "createdAt": .integer(record.createdAt),
                            "updatedAt": .integer(record.updatedAt),
                        ])
                    )
                }
            )
            return .object(values)
        }

        private func workspaceRootOptionsValue(
            roots: [String]
        ) -> CodexDesktopAppHostRPC.Value {
            var labels: [String: CodexDesktopAppHostRPC.Value] = [:]
            for record in localProjectsStateStore.projectsInOrder {
                guard record.rootPaths.count == 1,
                      !record.name.trimmingCharacters(
                          in: .whitespacesAndNewlines
                      ).isEmpty
                else {
                    continue
                }
                labels[record.rootPaths[0]] = .string(record.name)
            }
            var canonicalPathByRoot:
                [String: CodexDesktopAppHostRPC.Value] = [:]
            for root in roots {
                let url = URL(fileURLWithPath: root)
                    .resolvingSymlinksInPath()
                    .standardizedFileURL
                if fileManager.fileExists(atPath: root),
                   url.path != root
                {
                    canonicalPathByRoot[root] = .string(url.path)
                }
            }
            var result: [String: CodexDesktopAppHostRPC.Value] = [
                "roots": .array(
                    roots.map(CodexDesktopAppHostRPC.Value.string)
                ),
                "labels": .object(labels),
            ]
            if !canonicalPathByRoot.isEmpty {
                result["canonicalPathByRoot"] = .object(
                    canonicalPathByRoot
                )
            }
            return .object(result)
        }

        private func rpcValue(
            from value: CodexJSONValue
        ) -> CodexDesktopAppHostRPC.Value {
            switch value {
            case .null:
                return .null
            case let .bool(value):
                return .bool(value)
            case let .integer(value):
                return .integer(value)
            case let .number(value):
                return .number(value)
            case let .string(value):
                return .string(value)
            case let .array(values):
                return .array(values.map(rpcValue))
            case let .object(values):
                return .object(values.mapValues(rpcValue))
            }
        }

        private func activeWorkspaceRoots() -> [String] {
            guard let selectedWorkspaceID =
                sessionStore.selectedWorkspaceID
            else {
                return []
            }
            synchronizeLocalProjectsState()
            return localProjectsStateStore.project(
                projectID:
                    selectedWorkspaceID.uuidString.lowercased()
            )?.rootPaths ?? []
        }

        private func workspaceRootOptions() -> [String] {
            synchronizeLocalProjectsState()
            var seen = Set<String>()
            return localProjectsStateStore.projectsInOrder.flatMap(
                \.rootPaths
            ).filter {
                seen.insert($0).inserted
            }
        }

        private func synchronizeLocalProjectsState() {
            _ = localProjectsStateStore.synchronize(
                workspaces: sessionStore.state.workspaces,
                selectedProject:
                    selectedProjectStore.globalStateValue,
                rootPath: workspaceRootPath
            )
        }

        private func workspaceRootPath(
            _ workspace: Workspace
        ) -> String? {
            let access = CodexWorkspaceAccess()
            guard let bookmark = workspace.rootBookmarkID,
                  let url = try? access.resolve(bookmark)
            else {
                return nil
            }
            return url.standardizedFileURL.path
        }

        private func allowedFileSystemRoots() -> [String] {
            [
                hostFilesystemPaths().applicationRoot.path
            ] + workspaceRootOptions()
        }

        private func prepareHostFilesystem() throws {
            let paths = hostFilesystemPaths()
            try fileManager.createDirectory(
                at: paths.worktrees,
                withIntermediateDirectories: true
            )
        }

        private static func createDefaultWorkspace(
            named requestedName: String,
            initializeGitRepository: Bool,
            fileManager: FileManager
        ) throws -> URL {
            let documents = fileManager.urls(
                for: .documentDirectory,
                in: .userDomainMask
            ).first ?? fileManager.temporaryDirectory
            return try CodexDesktopDefaultWorkspaceCreator.create(
                named: requestedName,
                initializeGitRepository:
                    initializeGitRepository,
                documentsDirectory: documents,
                fileManager: fileManager
            )
        }

        private func hostFilesystemPaths() -> (
            applicationRoot: URL,
            codexHome: URL,
            worktrees: URL,
            commandKeymap: URL
        ) {
            let applicationSupport =
                fileManager.urls(
                    for: .applicationSupportDirectory,
                    in: .userDomainMask
                ).first
                ?? fileManager.temporaryDirectory
            let applicationRoot = applicationSupport
                .appendingPathComponent(
                    "CodexPad",
                    isDirectory: true
                )
            let codexHome = applicationRoot
                .appendingPathComponent(
                    "CodexHome",
                    isDirectory: true
                )
            return (
                applicationRoot,
                codexHome,
                codexHome.appendingPathComponent(
                    "worktrees",
                    isDirectory: true
                ),
                applicationRoot.appendingPathComponent(
                    "codex-command-keymap.json",
                    isDirectory: false
                )
            )
        }

        private func installationID() -> String {
            if let existing = userDefaults.string(
                forKey: Self.installationIDKey
            ), !existing.isEmpty {
                return existing
            }
            let created = UUID().uuidString
            userDefaults.set(
                created,
                forKey: Self.installationIDKey
            )
            return created
        }

        private static func currentSystemThemeVariant()
            -> String
        {
            UITraitCollection.current.userInterfaceStyle == .dark
                ? "dark"
                : "light"
        }

        private static func compactDescription(
            _ value: CodexJSONValue
        ) -> String {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [
                .sortedKeys,
                .withoutEscapingSlashes,
            ]
            guard let data = try? encoder.encode(value),
                  let string = String(
                    data: data,
                    encoding: .utf8
                  )
            else {
                return String(describing: value)
            }
            return String(string.prefix(4_000))
        }

        private func waitForReleasedStartupReady() async {
            guard !startupGate.canMarkStartupReady else {
                return
            }
            await withCheckedContinuation { continuation in
                if startupGate.canMarkStartupReady {
                    continuation.resume()
                } else {
                    startupReadyContinuations.append(continuation)
                }
            }
        }

        private func signalReleasedStartupReadyIfNeeded() {
            guard startupGate.canMarkStartupReady,
                  !startupReadyContinuations.isEmpty
            else {
                return
            }
            let continuations = startupReadyContinuations
            startupReadyContinuations.removeAll(keepingCapacity: false)
            for continuation in continuations {
                continuation.resume()
            }
        }

        private func recordFailure(_ error: Error) {
            record("failure \(CodexDiagnosticSanitization.publicErrorSummary(error))")
        }

        private func recordWorkerDiagnostic(
            _ diagnostic: CodexDesktopWorkerDiagnostic
        ) {
            let message: String
            switch diagnostic {
            case let .request(method):
                guard method == "stable-metadata" else {
                    return
                }
                message = "worker-request git stable-metadata"
            case let .result(method, outcome):
                guard method == "stable-metadata" else {
                    return
                }
                let classification: String
                switch outcome {
                case .value:
                    classification = "metadata"
                case .null:
                    classification = "null"
                case .error:
                    classification = "error"
                }
                message = "worker-result git stable-metadata \(classification)"
            }
            userDefaults.set(
                message,
                forKey: Self.lastGitMetadataDiagnosticKey
            )
            record(message)
        }

        private func record(_ message: String) {
            diagnostics.append(message)
            // Realtime voice startup spans the primary renderer, the native
            // avatar-overlay host, Statsig/bootstrap fetches, and several MCP
            // requests. Two hundred entries can evict the initiating
            // request and starter-registration evidence before a physical
            // device assertion reads this trace. Keep a bounded but complete
            // startup window so the failing boundary remains observable.
            if diagnostics.count > 1_000 {
                diagnostics.removeFirst(
                    diagnostics.count - 1_000
                )
            }
            logger.info("\(message, privacy: .public)")
            userDefaults.set(
                diagnostics,
                forKey: Self.runtimeDiagnosticsKey
            )
        }
    }

    @MainActor
    public final class CodexDesktopSceneRuntime {
        public let controller: CodexDesktopSurfaceController
        public let remoteControlLifecycle:
            CodexRemoteControlLifecycleBackend?

        public init(
            controller: CodexDesktopSurfaceController,
            remoteControlLifecycle:
                CodexRemoteControlLifecycleBackend?
        ) {
            self.controller = controller
            self.remoteControlLifecycle = remoteControlLifecycle
        }
    }

    @MainActor
    public struct CodexDesktopSceneRuntimeFactory {
        private final class ControllerReference {
            weak var value: CodexDesktopSurfaceController?
        }

        private let accountStore: CodexAccountStore
        private let sessionStore: CodexSessionStore
        private let officialProvider:
            CodexOfficialProviderClient?
        private let coreClient: CodexCoreClient?
        private let gitDiffer:
            (any CodexDesktopGitDiffing)?

        public init(
            accountStore: CodexAccountStore,
            sessionStore: CodexSessionStore,
            officialProvider:
                CodexOfficialProviderClient?,
            coreClient: CodexCoreClient?,
            gitDiffer:
                (any CodexDesktopGitDiffing)?
        ) {
            self.accountStore = accountStore
            self.sessionStore = sessionStore
            self.officialProvider = officialProvider
            self.coreClient = coreClient
            self.gitDiffer = gitDiffer
        }

        public func makeRuntime() -> CodexDesktopSceneRuntime {
            let commandExecutor =
                CodexDesktopWorkspaceCommandExecutor()
            let controllerReference = ControllerReference()
            let permissionGrantStore =
                CodexPersistedTurnPermissionGrantStore()
            let controller = CodexDesktopSurfaceController(
                accountStore: accountStore,
                sessionStore: sessionStore,
                officialProvider: officialProvider,
                commandExecutor: commandExecutor,
                turnProviderFactory: { params in
                    guard let credentials =
                        accountStore.officialCredentials(),
                        let officialProvider
                    else {
                        return nil
                    }
                    UserDefaults.standard.set(
                        credentials.authMethod.rawValue,
                        forKey: "codex.desktop.last-turn-provider-auth-mode"
                    )
                    let normalizedRouteHost: String
                    switch credentials.authMethod {
                    case .apiKey:
                        normalizedRouteHost = "api.openai.com"
                    case .chatGPT, .chatGPTAuthTokens:
                        normalizedRouteHost = "chatgpt.com"
                    default:
                        normalizedRouteHost =
                            URL(string: credentials.baseURL ?? "")?.host
                            ?? "none"
                    }
                    UserDefaults.standard.set(
                        "authMode=\(credentials.authMethod.rawValue)"
                            + " routeHost=\(normalizedRouteHost)"
                            + " hasAccountID=\(credentials.accountID != nil)",
                        forKey:
                            "codex.desktop.last-turn-provider-route-diagnostic"
                    )
                    let fallback =
                        CodexModelCatalog.current.first {
                            $0.isDefault
                        } ?? CodexModelCatalog.current[0]
                    let fallbackCollaborationMode =
                        CodexCollaborationMode(
                            mode: .default,
                            settings:
                                CodexCollaborationModeSettings(
                                    model: fallback.model,
                                    reasoningEffort:
                                        fallback
                                            .defaultReasoningEffort
                                            .rawValue,
                                    developerInstructions: nil
                                )
                        )
                    let collaborationMode =
                        CodexCollaborationModeWireResolver.resolve(
                            collaborationMode:
                                params.collaborationMode,
                            model: params.model,
                            effort: params.effort,
                            stored: sessionStore.threadSettings(
                                for: params.threadID
                            )?.collaborationMode,
                            fallback: fallbackCollaborationMode
                        )
                    let model = collaborationMode.settings.model
                    // ChatGPT OAuth accounts use the Codex product route,
                    // whose accepted model identifiers can lag the renderer
                    // catalog aliases. Keep the persisted turn path aligned
                    // with the conversation fetch adapter normalization.
                    let providerModel =
                        CodexDesktopConversationStreamAdapter
                            .officialProviderModel(
                                for: model,
                                baseURL: credentials.authMethod == .apiKey
                                    ? CodexOfficialCredentials
                                        .openAIAPIBaseURL
                                    : nil
                            )
                    let modelFallback =
                        CodexModelCatalog.current.first {
                            $0.model == providerModel
                        } ?? fallback
                    let effort =
                        collaborationMode.settings
                            .reasoningEffort
                            .flatMap(
                                CodexReasoningEffort.init(
                                    rawValue:
                                )
                            )
                        ?? modelFallback.defaultReasoningEffort
                    let workspace = Self.turnWorkspace(
                        for: params,
                        in: sessionStore
                    )
                    let toolSearchSources =
                        controllerReference.value?
                            .persistedTurnOfficialToolSearchSources()
                        ?? []
                    let requestPermissionsTool: Bool
                    if case let .value(policy) =
                        params.approvalPolicy
                    {
                        requestPermissionsTool = switch policy {
                        case .granular(let granular):
                            granular.requestPermissions
                        case .never:
                            false
                        case .untrusted, .onRequest:
                            true
                        }
                    } else {
                        requestPermissionsTool = true
                    }
                    return CodexPersistedTurnOfficialProvider(
                        configuration:
                            CodexDesktopSceneRuntimeProviderConfigurationFactory
                                .make(
                                        credentials: credentials,
                                    model: providerModel,
                                    reasoningEffort: effort,
                                    collaborationInstructions:
                                        collaborationMode.settings
                                            .developerInstructions,
                                    workspaceTools: workspace != nil,
                                    requestPermissionsTool:
                                        requestPermissionsTool,
                                    mcpResourceTools:
                                        controllerReference.value != nil,
                                    planMode:
                                        collaborationMode.mode == .plan,
                                    toolSearchSources: toolSearchSources
                                ),
                        client: officialProvider
                    )
                },
                turnToolExecutorFactory: {
                    params,
                    approvalRequester,
                    requestUserInputRequester,
                    planUpdateRequester in
                    let interactionExecutor =
                        CodexPersistedTurnRequestUserInputExecutor(
                            prompt: requestUserInputRequester
                        )
                    let planExecutor =
                        CodexPersistedTurnUpdatePlanExecutor(
                            publish: planUpdateRequester
                        )
                    let mcpResourceExecutor =
                        controllerReference.value?
                            .makePersistedTurnMCPResourceExecutor()
                    let toolSearchExecutor =
                        controllerReference.value?
                            .makePersistedTurnToolSearchExecutor(
                                threadID: params.threadID
                            )
                    let dynamicTools: [CodexJSONValue]
                    if case let .value(values) = params.dynamicTools {
                        dynamicTools = values
                    } else {
                        dynamicTools = []
                    }
                    let dynamicToolExecutor:
                        CodexDesktopDynamicToolCallBroker?
                    controllerReference.value?
                        .dynamicToolCallBroker?.cancelAll()
                    controllerReference.value?
                        .dynamicToolCallBroker = nil
                    if dynamicTools.isEmpty {
                        dynamicToolExecutor = nil
                    } else {
                        let broker = CodexDesktopDynamicToolCallBroker(
                            dynamicTools: dynamicTools,
                            send: { [weak controllerReference] message in
                                await controllerReference?.value?.send(
                                    message
                                )
                            }
                        )
                        controllerReference.value?
                            .dynamicToolCallBroker = broker
                        dynamicToolExecutor = broker
                    }
                    guard let workspace = Self.turnWorkspace(
                        for: params,
                        in: sessionStore
                    ),
                    let workspacePath = Self.workspacePath(workspace)
                    else {
                        return CodexPersistedTurnToolRouter(
                            interactionExecutor: interactionExecutor,
                            workspaceExecutor: nil,
                            updatePlanExecutor: planExecutor,
                            mcpResourceExecutor: mcpResourceExecutor,
                            toolSearchExecutor: toolSearchExecutor,
                            dynamicToolExecutor: dynamicToolExecutor
                        )
                    }
                    let expectedWorkspacePath: String
                    if case let .value(cwd) = params.cwd {
                        expectedWorkspacePath = cwd
                    } else {
                        expectedWorkspacePath = workspacePath
                    }
                    let permissionsExecutor =
                        CodexPersistedTurnRequestPermissionsExecutor(
                            cwd: expectedWorkspacePath,
                            grantStore: permissionGrantStore,
                            prompt: { approval in
                                await controllerReference.value?
                                    .requestPersistedTurnPermission(
                                        approval
                                    )
                            }
                        )
                    let approvalPolicy: CodexAppServerAskForApproval
                    if case let .value(value) =
                        params.approvalPolicy
                    {
                        approvalPolicy = value
                    } else {
                        approvalPolicy = .onRequest
                    }
                    let sandboxPolicy: CodexAppServerSandboxPolicy
                    if case let .value(value) = params.sandboxPolicy {
                        sandboxPolicy = value
                    } else {
                        sandboxPolicy = .workspaceWrite(
                            writableRoots: [workspacePath],
                            networkAccess: true,
                            excludeTmpdirEnvVar: false,
                            excludeSlashTmp: false
                        )
                    }
                    let workspaceExecutor =
                        CodexPersistedTurnWorkspaceToolExecutor(
                            policy: CodexExecutionPolicy(
                                resumedApprovalPolicy: approvalPolicy,
                                resumedSandboxPolicy: sandboxPolicy
                            ),
                            expectedWorkspacePath:
                                expectedWorkspacePath,
                            workspace: workspace,
                            runner: CodexWorkspaceToolRunner(),
                            commandExecutor: commandExecutor,
                            permissionGrantStore:
                                permissionGrantStore,
                            approval: approvalRequester
                        )
                    let viewImageExecutor =
                        CodexPersistedTurnViewImageExecutor(
                            workspaceRoot: URL(
                                fileURLWithPath: workspacePath
                            ),
                            supportsOriginalDetail: true
                        )
                    return CodexPersistedTurnToolRouter(
                        interactionExecutor: interactionExecutor,
                        requestPermissionsExecutor:
                            permissionsExecutor,
                        workspaceExecutor: workspaceExecutor,
                        updatePlanExecutor: planExecutor,
                        viewImageExecutor: viewImageExecutor,
                        mcpResourceExecutor: mcpResourceExecutor,
                        toolSearchExecutor: toolSearchExecutor,
                        dynamicToolExecutor: dynamicToolExecutor
                    )
                },
                gitDiffer: gitDiffer
            )
            controllerReference.value = controller

            let lifecycle: CodexRemoteControlLifecycleBackend?
            if let coreClient,
               let httpTransport =
                   try? CodexRemoteControlHTTPTransport()
            {
                let router =
                    controller
                        .makeRemoteControlVirtualSessionRouter()
                let webSocket =
                    CodexRemoteControlWebSocketLifecycleAdapter(
                        router: router
                    )
                let backend = CodexRemoteControlLifecycleBackend(
                    target:
                        CodexRemoteControlHTTPTransport
                            .defaultBaseURL.absoluteString,
                    installationID:
                        controller.remoteControlInstallationID,
                    serverName: "Codex for ipad",
                    operatingSystem: "iPadOS",
                    architecture: "arm64",
                    appServerVersion:
                        CodexBuildMetadata.embeddedCliVersion,
                    appServerClientName: "codex_for_ipad",
                    wire: httpTransport,
                    authProvider:
                        accountStore.remoteControlAuthAdapter(),
                    persistence:
                        CodexRemoteControlCorePersistenceAdapter(
                            transport: coreClient
                        ),
                    webSocket: webSocket
                )
                controller.installRemoteControlBridge(
                    CodexRemoteControlMCPBridge(backend: backend)
                )
                lifecycle = backend
            } else {
                lifecycle = nil
            }
            return CodexDesktopSceneRuntime(
                controller: controller,
                remoteControlLifecycle: lifecycle
            )
        }

        private static func turnWorkspace(
            for params: CodexTurnStartParams,
            in sessionStore: CodexSessionStore
        ) -> Workspace? {
            guard let selectedWorkspaceID =
                sessionStore.selectedWorkspaceID
            else {
                return nil
            }
            guard let workspace =
                sessionStore.state.workspaces.first(
                    where: { $0.id == selectedWorkspaceID }
                ),
                let resolvedPath = workspacePath(workspace)
            else {
                return nil
            }
            if case let .value(cwd) = params.cwd,
               URL(fileURLWithPath: cwd).standardizedFileURL.path
                != URL(fileURLWithPath: resolvedPath)
                    .standardizedFileURL.path
            {
                return nil
            }
            return workspace
        }

        private static func workspacePath(
            _ workspace: Workspace
        ) -> String? {
            guard let bookmark = workspace.rootBookmarkID,
                  let url =
                    try? CodexWorkspaceAccess().resolve(bookmark)
            else {
                return nil
            }
            return url.standardizedFileURL.path
        }
    }
#endif
