import Foundation

#if canImport(Darwin)
    import Darwin
#endif

/// The subset of the released desktop AppHost that is required while the
/// renderer leaves its native splash and mounts the first React tree.
///
/// Cap'n Web materializes service targets by sorted property name. Keeping the
/// service list and target lookup in one place prevents the native invocation
/// router from drifting away from the export IDs sent to the renderer.
public final class CodexDesktopInitialAppHostRouter: @unchecked Sendable {
    public struct AppInfo: Equatable, Sendable {
        public let version: String
        public let buildNumber: String
        public let buildFlavor: String
        public let osName: String
        public let systemVersion: String
        public let appName: String
        public let appBrand: String

        public init(
            version: String,
            buildNumber: String,
            buildFlavor: String,
            osName: String,
            systemVersion: String,
            appName: String,
            appBrand: String
        ) {
            self.version = version
            self.buildNumber = buildNumber
            self.buildFlavor = buildFlavor
            self.osName = osName
            self.systemVersion = systemVersion
            self.appName = appName
            self.appBrand = appBrand
        }
    }

    public enum Error: Swift.Error, Equatable, Sendable {
        case unknownServiceTarget(Int)
        case invalidMethodPath
    }

    public static let serviceNames = [
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

    public let appInfo: AppInfo
    public let systemAppearance: String
    public let workspaceRoot: String
    private let workspaceFileService: CodexDesktopWorkspaceAppHostService
    private let platformService: CodexDesktopPlatformAppHostService
    private let intelligenceService: CodexDesktopIntelligenceAppHostService
    private let interactionService: CodexDesktopInteractionAppHostService
    private let coordinationService: CodexDesktopCoordinationAppHostService
    private let browserService: CodexDesktopBrowserAppHostService
    private let realtimeService: CodexDesktopRealtimeAppHostService
    private let visualizationsService: CodexDesktopVisualizationsAppHostService
    private let utilityService: CodexDesktopUtilityAppHostService
    private let artifactDocumentsService: CodexDesktopArtifactDocumentsAppHostService
    private let appUpdatesService: CodexDesktopAppUpdatesAppHostService
    private let browsingStateService: CodexDesktopBrowsingStateAppHostService
    private let downloadsService: CodexDesktopDownloadsAppHostService
    private let githubService: CodexDesktopGitHubAppHostService
    private let historyMediaService: CodexDesktopHistoryMediaAppHostService
    private let historySnapshotsService: CodexDesktopHistorySnapshotsAppHostService
    private let libraryService: CodexDesktopLibraryAppHostService
    private let localEnvironmentsService: CodexDesktopLocalEnvironmentsAppHostService
    private let localThreadCatalogService: CodexDesktopLocalThreadCatalogAppHostService
    private let optionalPlatformService: CodexDesktopOptionalPlatformAppHostService
    private let peripheralService: CodexDesktopPeripheralAppHostService
    private let projectService: CodexDesktopProjectAppHostService
    private let terminalService: CodexDesktopTerminalAppHostService
    private let threadStateService: CodexDesktopThreadStateAppHostService
    private let tracingService: CodexDesktopTracingAppHostService
    private let conversationalOnboardingService: CodexDesktopConversationalOnboardingAppHostService
    private let processResidentMemoryKb: @Sendable () -> UInt64
    private let startupReadyHandler: @Sendable () async -> Void
    private let featureLock = NSLock()
    private let startupPhaseLock = NSLock()
    private var activeFeatureNames: Set<String>
    private var activeDisabledFeatureNames: Set<String>
    private var pendingFeatureNames: Set<String>
    private var pendingDisabledFeatureNames: Set<String>
    private var startupPhases: [String] = []
    private var bufferedStartupPhases: [String] = []

    public var reachedStartupPhases: [String] {
        startupPhaseLock.withLock { startupPhases }
    }

    public init(
        appInfo: AppInfo,
        systemAppearance: String = "auto",
        workspaceRoot: String = NSHomeDirectory(),
        activeFeatureNames: Set<String> = [],
        activeDisabledFeatureNames: Set<String> = [],
        workspaceFileService:
            CodexDesktopWorkspaceAppHostService? = nil,
        platformService:
            CodexDesktopPlatformAppHostService? = nil,
        intelligenceService:
            CodexDesktopIntelligenceAppHostService? = nil,
        interactionService:
            CodexDesktopInteractionAppHostService? = nil,
        coordinationService:
            CodexDesktopCoordinationAppHostService? = nil,
        browserService:
            CodexDesktopBrowserAppHostService? = nil,
        realtimeService:
            CodexDesktopRealtimeAppHostService? = nil,
        visualizationsService:
            CodexDesktopVisualizationsAppHostService? = nil,
        utilityService:
            CodexDesktopUtilityAppHostService? = nil,
        artifactDocumentsService:
            CodexDesktopArtifactDocumentsAppHostService? = nil,
        appUpdatesService:
            CodexDesktopAppUpdatesAppHostService? = nil,
        browsingStateService:
            CodexDesktopBrowsingStateAppHostService? = nil,
        downloadsService:
            CodexDesktopDownloadsAppHostService? = nil,
        githubService:
            CodexDesktopGitHubAppHostService? = nil,
        historyMediaService:
            CodexDesktopHistoryMediaAppHostService? = nil,
        historySnapshotsService:
            CodexDesktopHistorySnapshotsAppHostService? = nil,
        libraryService:
            CodexDesktopLibraryAppHostService? = nil,
        localEnvironmentsService:
            CodexDesktopLocalEnvironmentsAppHostService? = nil,
        localThreadCatalogService:
            CodexDesktopLocalThreadCatalogAppHostService? = nil,
        optionalPlatformService:
            CodexDesktopOptionalPlatformAppHostService? = nil,
        peripheralService:
            CodexDesktopPeripheralAppHostService? = nil,
        projectService:
            CodexDesktopProjectAppHostService? = nil,
        terminalService:
            CodexDesktopTerminalAppHostService? = nil,
        threadStateService:
            CodexDesktopThreadStateAppHostService? = nil,
        tracingService:
            CodexDesktopTracingAppHostService? = nil,
        conversationalOnboardingService:
            CodexDesktopConversationalOnboardingAppHostService? = nil,
        processResidentMemoryKb: @escaping @Sendable () -> UInt64 = {
            CodexDesktopInitialAppHostRouter
                .currentResidentMemoryKb()
        },
        startupReadyHandler: @escaping @Sendable () async -> Void = {}
    ) {
        let workspaceURL = URL(
            fileURLWithPath: workspaceRoot,
            isDirectory: true
        ).standardizedFileURL
        let codexHome = workspaceURL.appendingPathComponent(
            ".codex",
            isDirectory: true
        )
        let downloadsURL = workspaceURL.appendingPathComponent(
            "Downloads",
            isDirectory: true
        )

        self.appInfo = appInfo
        self.systemAppearance = systemAppearance
        self.workspaceRoot = workspaceRoot
        self.workspaceFileService =
            workspaceFileService
            ?? CodexDesktopWorkspaceAppHostService(
                workspaceRoot: workspaceURL,
                downloadsDirectory: downloadsURL
            )
        self.platformService =
            platformService
            ?? CodexDesktopPlatformAppHostService()
        self.intelligenceService =
            intelligenceService
            ?? CodexDesktopIntelligenceAppHostService()
        self.interactionService =
            interactionService
            ?? CodexDesktopInteractionAppHostService()
        self.coordinationService =
            coordinationService
            ?? CodexDesktopCoordinationAppHostService()
        self.browserService =
            browserService
            ?? CodexDesktopBrowserAppHostService()
        self.realtimeService =
            realtimeService
            ?? CodexDesktopRealtimeAppHostService(
                codexHome: codexHome
            )
        self.visualizationsService =
            visualizationsService
            ?? CodexDesktopVisualizationsAppHostService(
                codexHome: codexHome
            )
        self.utilityService =
            utilityService
            ?? CodexDesktopUtilityAppHostService(
                codexHome: codexHome
            )
        self.artifactDocumentsService =
            artifactDocumentsService
            ?? CodexDesktopArtifactDocumentsAppHostService(
                allowedWorkspaceRoots: [workspaceURL],
                storeDirectory: codexHome.appendingPathComponent(
                    "artifact-documents",
                    isDirectory: true
                )
            )
        self.appUpdatesService =
            appUpdatesService
            ?? CodexDesktopAppUpdatesAppHostService()
        self.browsingStateService =
            browsingStateService
            ?? CodexDesktopBrowsingStateAppHostService()
        self.downloadsService =
            downloadsService
            ?? CodexDesktopDownloadsAppHostService()
        self.githubService =
            githubService
            ?? CodexDesktopGitHubAppHostService()
        self.historyMediaService =
            historyMediaService
            ?? CodexDesktopHistoryMediaAppHostService(
                dictationDirectory: codexHome.appendingPathComponent(
                    "dictation-history",
                    isDirectory: true
                ),
                downloadsDirectory: {
                    try FileManager.default.createDirectory(
                        at: downloadsURL,
                        withIntermediateDirectories: true
                    )
                    return downloadsURL
                }
            )
        self.historySnapshotsService =
            historySnapshotsService
            ?? CodexDesktopHistorySnapshotsAppHostService(
                storeRoot: codexHome.appendingPathComponent(
                    "app-server-history-snapshots",
                    isDirectory: true
                ),
                principalProvider: { nil },
                hostKeyProvider: { _ in nil }
            )
        self.libraryService =
            libraryService
            ?? CodexDesktopLibraryAppHostService(
                workspaceRoot: workspaceURL,
                generatedImagesDirectory:
                    codexHome.appendingPathComponent(
                        "generated_images",
                        isDirectory: true
                    ),
                outputDirectories: [:]
            )
        self.localEnvironmentsService =
            localEnvironmentsService
            ?? CodexDesktopLocalEnvironmentsAppHostService()
        self.localThreadCatalogService =
            localThreadCatalogService
            ?? CodexDesktopLocalThreadCatalogAppHostService()
        self.optionalPlatformService =
            optionalPlatformService
            ?? CodexDesktopOptionalPlatformAppHostService()
        self.peripheralService =
            peripheralService
            ?? CodexDesktopPeripheralAppHostService()
        self.projectService =
            projectService
            ?? CodexDesktopProjectAppHostService()
        self.terminalService =
            terminalService
            ?? CodexDesktopTerminalAppHostService()
        self.threadStateService =
            threadStateService
            ?? CodexDesktopThreadStateAppHostService(
                codexHome: codexHome
            )
        self.tracingService =
            tracingService
            ?? CodexDesktopTracingAppHostService()
        self.conversationalOnboardingService =
            conversationalOnboardingService
            ?? CodexDesktopConversationalOnboardingAppHostService(
                allowedWorkspaceRoots: [workspaceURL]
            )
        self.processResidentMemoryKb = processResidentMemoryKb
        self.startupReadyHandler = startupReadyHandler
        self.activeFeatureNames = activeFeatureNames
        self.activeDisabledFeatureNames = activeDisabledFeatureNames
        pendingFeatureNames = activeFeatureNames
        pendingDisabledFeatureNames = activeDisabledFeatureNames
    }

    public var services: [String: CodexDesktopAppHostRPC.Value] {
        var values: [String: CodexDesktopAppHostRPC.Value] = Dictionary(
            uniqueKeysWithValues: Self.serviceNames.map {
                ($0, .rpcObject([:]))
            }
        )
        values["notificationPermissionsSupported"] = .bool(true)
        return values
    }

    public func serviceName(
        forTargetID targetID: Int
    ) -> String? {
        guard targetID < 0 else {
            return nil
        }
        let index = -targetID - 1
        guard Self.serviceNames.indices.contains(index) else {
            return nil
        }
        return Self.serviceNames[index]
    }

    public func response(
        to pipeline: CodexDesktopAppHostRPC.Pipeline
    ) throws -> CodexDesktopAppHostRPC.Value {
        guard
            let service = serviceName(
                forTargetID: pipeline.targetID
            )
        else {
            throw Error.unknownServiceTarget(pipeline.targetID)
        }
        guard case .key(let method)? = pipeline.path.first else {
            throw Error.invalidMethodPath
        }

        switch (service, method) {
        case ("appActions", "isPrimaryWindowFocused"):
            return .bool(true)

        case ("appInfo", "get"):
            return .object([
                "version": .string(appInfo.version),
                "buildNumber": .string(appInfo.buildNumber),
                "buildFlavor": .string(appInfo.buildFlavor),
                "osName": .string(appInfo.osName),
                "systemVersion": .string(appInfo.systemVersion),
                "appName": .string(appInfo.appName),
                "appBrand": .string(appInfo.appBrand),
                "appIconMedium": .null,
                "dockIconPreviews": .null,
            ])

        case ("conversationalOnboarding", "getSystemAppearance"):
            return .string(systemAppearance)

        case ("conversationalOnboarding", "requestDesktopRoot"):
            return .string(workspaceRoot)

        case (
            "conversationalOnboarding",
            "requestComputerUsePermissions"
        ):
            // iPadOS presents permission prompts at the point of use.
            return .undefined

        case ("owlFeatures", "getState"):
            return featureState()

        case ("owlFeatures", "isOwlFeatureEnabled"):
            guard
                case .string(let featureName)? =
                    pipeline.arguments?.first
            else {
                return .bool(false)
            }
            return .bool(
                featureLock.withLock {
                    activeFeatureNames.contains(featureName)
                        && !activeDisabledFeatureNames
                            .contains(featureName)
                }
            )

        case ("owlFeatures", "setFeatureNames"):
            if case .object(let fields)? = pipeline.arguments?.first {
                let enabled = Self.stringSet(
                    fields["enabledFeatureNames"]
                )
                let disabled = Self.stringSet(
                    fields["disabledFeatureNames"]
                )
                featureLock.withLock {
                    pendingFeatureNames = enabled
                    pendingDisabledFeatureNames = disabled
                }
            }
            return featureState()

        case ("owlFeatures", "setRuntimeFeatures"):
            // Runtime feature flags are renderer-process hints. They do not
            // require an app restart and are deliberately accepted in place.
            return .undefined

        case ("startup", "reach"):
            if case .string(let phase)? = pipeline.arguments?.first {
                reachStartupPhase(phase)
            }
            return .undefined

        case ("startup", "bufferPhase"):
            if case .string(let phase)? = pipeline.arguments?.first {
                bufferStartupPhase(phase)
            }
            return .undefined

        case ("startup", "clearBufferedPhases"):
            clearBufferedStartupPhases()
            return .undefined

        case ("processMemory", "getSnapshot"):
            let residentMemoryKb = processResidentMemoryKb()
            return .object([
                "appServerRssKb": .number(0),
                "codexAppRssKb": .number(Double(residentMemoryKb)),
                "otherChildProcessesRssKb": .number(0),
                "rolloutChildProcessesRssKb": .number(0),
                "totalRssKb": .number(Double(residentMemoryKb)),
            ])

        case ("requestUserInputAutoResolution", "setDisabled"),
            ("requestUserInputAutoResolution", "snooze"),
            (
                "requestUserInputAutoResolution",
                "setConversationPresented"
            ),
            (
                "requestUserInputAutoResolution",
                "recordConversationActivity"
            ),
            ("tracing", "setSampleRate"),
            (
                "windowNavigation",
                "setHistorySwipeNavigationState"
            ):
            return .undefined

        case ("tracing", "confirmTraceRecordingStart"),
            ("tracing", "cancelTraceRecordingStart"),
            ("tracing", "submitTraceRecordingDetails"):
            // No trace-recording confirmation sheet is pending on iPad.
            return .bool(false)

        default:
            // All bootstrap services are intentionally real RpcTargets.
            // A newer released renderer can probe a newly added setter without
            // blocking first paint; diagnostics still records its exact path.
            return .undefined
        }
    }

    public func responseAsync(
        to pipeline: CodexDesktopAppHostRPC.Pipeline
    ) async throws -> CodexDesktopAppHostRPC.Value {
        guard
            let service = serviceName(
                forTargetID: pipeline.targetID
            )
        else {
            throw Error.unknownServiceTarget(pipeline.targetID)
        }
        guard case .key(let method)? = pipeline.path.first else {
            throw Error.invalidMethodPath
        }
        switch service {
        case "startup" where method == "whenReady":
            await startupReadyHandler()
            flushBufferedStartupPhases()
            return .undefined
        case "appUpdates":
            return try await appUpdatesService.invoke(
                method: method,
                arguments: pipeline.arguments
            )
        case "fileAttachments", "workspaceFiles":
            return try await workspaceFileService.invoke(
                service: service,
                method: method,
                arguments: pipeline.arguments
            )
        case "dictationAudio", "notifications", "openIn",
            "systemFonts", "systemPermissions":
            return try await platformService.invoke(
                service: service,
                method: method,
                arguments: pipeline.arguments
            )
        case "ambientSuggestions", "threadMetadataGeneration":
            return try await intelligenceService.invoke(
                service: service,
                method: method,
                arguments: pipeline.arguments
            )
        case "applicationMenu",
            "dynamicToolCalls",
            "fileDrags",
            "hotkeyWindowHotkeys",
            "keyboardModifiers",
            "primaryRuntime",
            "quickChatWindow":
            return try await interactionService.invoke(
                service: service,
                method: method,
                arguments: pipeline.arguments
            )
        case "clientCoordination", "computerUseSettings":
            return try await coordinationService.invoke(
                service: service,
                method: method,
                arguments: pipeline.arguments
            )
        case "browserSidebar",
            "browserTabs",
            "chromeNativeHost",
            "chromiumBrowser",
            "inAppBrowserIncompleteNavigation":
            return try await browserService.invoke(
                service: service,
                method: method,
                arguments: pipeline.arguments
            )
        case "realtimeContinuity",
            "realtimeMemory",
            "realtimeVoice",
            "realtimeVoiceMultiAgentActivity",
            "realtimeVoicePresentation",
            "realtimeVoiceRuntime":
            return try await realtimeService.invoke(
                service: service,
                method: method,
                arguments: pipeline.arguments
            )
        case "visualizations":
            return try await visualizationsService.invoke(
                method: method,
                arguments: pipeline.arguments
            )
        case "browserProfileImport",
            "browserUsePermissions",
            "clipboard",
            "performanceTelemetry",
            "pluginScheduledTasks":
            return try await utilityService.invoke(
                service: service,
                method: method,
                arguments: pipeline.arguments
            )
        case "appServerHistorySnapshots":
            return try await historySnapshotsService.invoke(
                method: method,
                arguments: pipeline.arguments
            )
        case "artifactDocuments":
            return try await artifactDocumentsService.invoke(
                service: service,
                method: method,
                arguments: pipeline.arguments
            )
        case "browserSidebarAutocomplete",
            "browsingHistory",
            "customAvatars":
            return try await browsingStateService.invoke(
                service: service,
                method: method,
                arguments: pipeline.arguments
            )
        case "downloads":
            return try await downloadsService.invoke(
                service: service,
                method: method,
                arguments: pipeline.arguments
            )
        case "github":
            return try await githubService.invoke(
                service: service,
                method: method,
                arguments: pipeline.arguments
            )
        case "dictationHistory", "realtimeVoiceHistory":
            return try await historyMediaService.invoke(
                service: service,
                method: method,
                arguments: pipeline.arguments
            )
        case "libraryFiles":
            return try await libraryService.invoke(
                method: method,
                arguments: pipeline.arguments
            )
        case "localEnvironments":
            return try await localEnvironmentsService.invoke(
                service: service,
                method: method,
                arguments: pipeline.arguments
            )
        case "localThreadCatalog":
            return try await localThreadCatalogService.invoke(
                method: method,
                arguments: pipeline.arguments
            )
        case "chronicle",
            "avatarOverlay",
            "codexMicro",
            "debug",
            "owlBrowserCrashCounter",
            "remoteHostedPIP":
            return try await optionalPlatformService.invoke(
                service: service,
                method: method,
                arguments: pipeline.arguments
            )
        case "appshot",
            "hotkeyWindowCommands",
            "pullRequestMessageGeneration",
            "remoteControlEnvironments":
            return try await peripheralService.invoke(
                service: service,
                method: method,
                arguments: pipeline.arguments
            )
        case "chatGptProjectFiles",
            "localProjects",
            "projects",
            "threadArchive",
            "threadProjectAssignments":
            return try await projectService.invoke(
                service: service,
                method: method,
                arguments: pipeline.arguments
            )
        case "terminal":
            return try await terminalService.invoke(
                service: service,
                method: method,
                arguments: pipeline.arguments
            )
        case "pinnedThreads", "threadTurnSummaries":
            return try await threadStateService.invoke(
                service: service,
                method: method,
                arguments: pipeline.arguments
            )
        case "tracing":
            return try await tracingService.invoke(
                method: method,
                arguments: pipeline.arguments
            )
        case "conversationalOnboarding":
            return try await conversationalOnboardingService.invoke(
                method: method,
                arguments: pipeline.arguments
            )
        default:
            return try response(to: pipeline)
        }
    }

    private func reachStartupPhase(_ phase: String) {
        guard Self.releasedStartupPhases.contains(phase) else { return }
        startupPhaseLock.withLock {
            guard !startupPhases.contains(phase) else { return }
            startupPhases.append(phase)
        }
    }

    private func bufferStartupPhase(_ phase: String) {
        guard Self.bufferableStartupPhases.contains(phase) else { return }
        startupPhaseLock.withLock {
            guard !startupPhases.contains(phase),
                !bufferedStartupPhases.contains(phase)
            else { return }
            let last = bufferedStartupPhases.last
            guard
                Self.isValidBufferedTransition(
                    from: last,
                    to: phase
                )
            else { return }
            bufferedStartupPhases.append(phase)
        }
    }

    private func flushBufferedStartupPhases() {
        startupPhaseLock.withLock {
            let buffered = bufferedStartupPhases
            bufferedStartupPhases.removeAll()
            for phase in buffered where !startupPhases.contains(phase) {
                startupPhases.append(phase)
            }
        }
    }

    private func clearBufferedStartupPhases() {
        startupPhaseLock.withLock {
            bufferedStartupPhases.removeAll()
        }
    }

    private static let bufferableStartupPhases: Set<String> = [
        "renderer_ready",
        "first_content_visible",
        "background_ready",
    ]

    private static func isValidBufferedTransition(
        from previous: String?,
        to next: String
    ) -> Bool {
        switch next {
        case "renderer_ready":
            return previous == nil
        case "first_content_visible":
            return previous == "renderer_ready"
        case "background_ready":
            return previous == "first_content_visible"
        default:
            return false
        }
    }

    private func featureState() -> CodexDesktopAppHostRPC.Value {
        featureLock.withLock {
            .object([
                "activeFeatureNames": .array(
                    activeFeatureNames.sorted().map {
                        .string($0)
                    }
                ),
                "activeDisabledFeatureNames": .array(
                    activeDisabledFeatureNames.sorted().map {
                        .string($0)
                    }
                ),
                "pendingFeatureNames": .array(
                    pendingFeatureNames.sorted().map {
                        .string($0)
                    }
                ),
                "pendingDisabledFeatureNames": .array(
                    pendingDisabledFeatureNames.sorted().map {
                        .string($0)
                    }
                ),
                "restartRequired": .bool(
                    activeFeatureNames != pendingFeatureNames
                        || activeDisabledFeatureNames
                            != pendingDisabledFeatureNames
                ),
            ])
        }
    }

    private static func stringSet(
        _ value: CodexDesktopAppHostRPC.Value?
    ) -> Set<String> {
        guard case .array(let values)? = value else {
            return []
        }
        return Set(
            values.compactMap { value in
                guard case .string(let string) = value else {
                    return nil
                }
                return string
            }
        )
    }

    private static let releasedStartupPhases: Set<String> = [
        "renderer_ready",
        "first_content_visible",
        "background_ready",
    ]

    public static func currentResidentMemoryKb() -> UInt64 {
        #if canImport(Darwin)
            var info = mach_task_basic_info_data_t()
            var count = mach_msg_type_number_t(
                MemoryLayout<mach_task_basic_info_data_t>.size
                    / MemoryLayout<natural_t>.size
            )
            let result = withUnsafeMutablePointer(to: &info) { pointer in
                pointer.withMemoryRebound(
                    to: integer_t.self,
                    capacity: Int(count)
                ) { rebound in
                    task_info(
                        mach_task_self_,
                        task_flavor_t(MACH_TASK_BASIC_INFO),
                        rebound,
                        &count
                    )
                }
            }
            guard result == KERN_SUCCESS else {
                return 0
            }
            return UInt64(info.resident_size) / 1_024
        #else
            return 0
        #endif
    }
}
