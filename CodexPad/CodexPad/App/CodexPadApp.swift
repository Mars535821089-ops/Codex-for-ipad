import SwiftUI

@main
struct CodexPadApp: App {
    @State private var store: CodexSessionStore
    @State private var accountStore: CodexAccountStore
    private let officialProvider: CodexOfficialProviderClient?
    private let modelCatalogClient: (any CodexModelCatalogClient)?
    private let desktopRuntimeFactory:
        CodexDesktopSceneRuntimeFactory

    init() {
        let environment = ProcessInfo.processInfo.environment
        let restoreCredentials =
            environment[
                "CODEXPAD_UI_TEST_FORCE_SIGNED_OUT"
            ] != "1"
        let credentialNamespace = environment[
            "CODEXPAD_UI_TEST_CREDENTIAL_NAMESPACE"
        ]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let credentialStore: CodexCredentialStore
        let apiKeyCredentialStore: CodexAPIKeyCredentialStore
        if let credentialNamespace, !credentialNamespace.isEmpty {
            credentialStore = CodexCredentialStore(
                service: "dev.codexforipad.chatgpt.ui-test."
                    + credentialNamespace
            )
            apiKeyCredentialStore = CodexAPIKeyCredentialStore(
                service: "dev.codexforipad.openai.ui-test."
                    + credentialNamespace
            )
        } else {
            credentialStore = CodexCredentialStore()
            apiKeyCredentialStore = CodexAPIKeyCredentialStore()
            #if DEBUG
            // An older UI test wrote its fixture into the production
            // simulator Keychain before test namespaces were introduced.
            // Remove only that exact fixture; never delete or inspect any
            // other saved credential.
            if (try? apiKeyCredentialStore.load())
                == "sk-codexpad-ui-test-placeholder"
            {
                try? apiKeyCredentialStore.delete()
            }
            #endif
        }
        let accountStore = CodexAccountStore(
            credentials: credentialStore,
            apiKeyCredentials: apiKeyCredentialStore,
            restoreCredentials: restoreCredentials
        )
        let sessionStore: CodexSessionStore
        let modelCatalogClient:
            (any CodexModelCatalogClient)?
        let coreClient: CodexCoreClient?

        do {
            let client = try CodexCoreClient()
            coreClient = client
            modelCatalogClient = client
            sessionStore = CodexSessionStore(transport: client)
            do {
                let fileManager = FileManager.default
                guard let applicationSupport = fileManager.urls(
                    for: .applicationSupportDirectory,
                    in: .userDomainMask
                ).first else {
                    throw CodexSessionStoreError.transportUnavailable
                }
                let paths = try CodexStoragePaths.prepare(
                    in: applicationSupport,
                    fileManager: fileManager
                )
                try sessionStore.openStorage(
                    databasePath: paths.databasePath,
                    snapshotDirectory: paths.snapshotDirectory
                )
                if sessionStore.lastApplyProblem == nil {
                    try sessionStore.confirmStorage()
                }
            } catch {
                sessionStore.recordStartupProblem(error)
            }
        } catch {
            coreClient = nil
            modelCatalogClient = nil
            sessionStore = CodexSessionStore(
                initialTransportProblem: String(
                    describing: error
                )
            )
        }

        do {
            try CodexPadValidationFixtureCleaner.cleanIfRequested(
                environment: environment,
                sessionStore: sessionStore
            )
        } catch {
            sessionStore.recordStartupProblem(error)
        }

        #if DEBUG
        do {
            let fileManager = FileManager.default
            let documents = fileManager.urls(
                for: .documentDirectory,
                in: .userDomainMask
            ).first ?? fileManager.temporaryDirectory
            try CodexPadUITestWorkspaceBootstrap.prepare(
                environment: environment,
                documentsDirectory: documents,
                existingWorkspaces: sessionStore.state.workspaces,
                fileManager: fileManager
            ) { workspace in
                if sessionStore.state.workspaces.contains(
                    where: { $0.id == workspace.id }
                ) {
                    try sessionStore.updateWorkspace(
                        id: workspace.id,
                        displayName: workspace.displayName,
                        rootBookmarkID: workspace.rootBookmarkID
                    )
                    sessionStore.selectedWorkspaceID = workspace.id
                } else {
                    try sessionStore.openWorkspace(
                        id: workspace.id,
                        displayName: workspace.displayName,
                        rootBookmarkID: workspace.rootBookmarkID
                    )
                }
            }
        } catch {
            sessionStore.recordStartupProblem(error)
        }
        #endif

        let officialProvider = try? CodexOfficialProviderClient()
        let gitDiffer = try? CodexGitDiffWorker()
        _accountStore = State(initialValue: accountStore)
        _store = State(initialValue: sessionStore)
        self.officialProvider = officialProvider
        self.modelCatalogClient = modelCatalogClient
        desktopRuntimeFactory =
            CodexDesktopSceneRuntimeFactory(
                accountStore: accountStore,
                sessionStore: sessionStore,
                officialProvider: officialProvider,
                coreClient: coreClient,
                gitDiffer: gitDiffer
            )
    }

    var body: some Scene {
        WindowGroup {
            CodexDesktopSceneRoot(
                runtimeFactory: desktopRuntimeFactory,
                store: store,
                accountStore: accountStore,
                officialProvider: officialProvider,
                modelCatalogClient: modelCatalogClient
            )
        }
        .commands {
            CodexPadDesktopCommands()
        }
    }
}

@MainActor
enum CodexPadValidationFixtureCleaner {
    private static let realtimeVoiceBaseName = "realtime-voice-chat"

    static func cleanIfRequested(
        environment: [String: String],
        sessionStore: CodexSessionStore,
        userDefaults: UserDefaults = .standard,
        fileManager: FileManager = .default
    ) throws {
        guard environment["XCTestConfigurationFilePath"] != nil,
              environment[
                "CODEXPAD_UI_TEST_CLEAN_VALIDATION_FIXTURES"
              ] == "1"
        else {
            return
        }

        let validationWorkspaceIDs = sessionStore.state.workspaces
            .filter { $0.displayName == "Parity Git Workspace" }
            .map(\.id)
        for workspaceID in validationWorkspaceIDs {
            try? sessionStore.removeWorkspace(id: workspaceID)
        }

        let fixtureThreadIDs = realtimeVoiceFixtureThreadIDs(
            userDefaults: userDefaults
        )
        try deleteRealtimeVoiceDirectories(fileManager: fileManager)
        pruneRealtimeVoicePreferences(
            fixtureThreadIDs: fixtureThreadIDs,
            userDefaults: userDefaults
        )
        sessionStore.selectedWorkspaceID = nil
        sessionStore.selectedThreadID = nil
        deleteRealtimeVoiceThreads(
            sessionStore: sessionStore,
            fixtureThreadIDs: fixtureThreadIDs
        )
    }

    private static func realtimeVoiceFixtureThreadIDs(
        userDefaults: UserDefaults
    ) -> Set<String> {
        let values = userDefaults.dictionary(
            forKey: CodexDesktopProjectlessOutputDirectoryStore
                .defaultPersistenceKey
        ) as? [String: String] ?? [:]
        return Set(values.compactMap { threadID, path in
            pathContainsRealtimeVoiceFixture(path) ? threadID : nil
        })
    }

    private static func deleteRealtimeVoiceThreads(
        sessionStore: CodexSessionStore,
        fixtureThreadIDs: Set<String>
    ) {
        var threadsToDelete = Set<CodexStoredThreadID>()
        for archived in [false, true] {
            var cursor: String?
            var seenCursors = Set<String>()
            repeat {
                guard let page = try? sessionStore.listThreads(
                    id: .string(
                        "validation-voice-list-\(UUID().uuidString)"
                    ),
                    params: CodexThreadListParams(
                        cursor: cursor.map(CodexWireOptional.value)
                            ?? .omitted,
                        limit: .value(100),
                        sortKey: .value(.updatedAt),
                        sortDirection: .value(.descending),
                        archived: .value(archived)
                    )
                ) else {
                    break
                }
                for thread in page.data where
                    fixtureThreadIDs.contains(thread.id.rawValue)
                    || pathContainsRealtimeVoiceFixture(thread.cwd)
                {
                    threadsToDelete.insert(thread.id)
                }
                cursor = page.nextCursor
                if let nextCursor = cursor,
                   !seenCursors.insert(nextCursor).inserted
                {
                    cursor = nil
                }
            } while cursor != nil
        }
        for threadID in threadsToDelete {
            try? sessionStore.deleteStoredThread(
                id: .string(
                    "validation-voice-delete-\(UUID().uuidString)"
                ),
                threadID: threadID
            )
        }
    }

    private static func deleteRealtimeVoiceDirectories(
        fileManager: FileManager
    ) throws {
        let documents = fileManager.urls(
            for: .documentDirectory,
            in: .userDomainMask
        ).first ?? fileManager.temporaryDirectory
        let root = documents.appendingPathComponent(
            "Codex",
            isDirectory: true
        )
        guard let dateDirectories = try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }
        for dateDirectory in dateDirectories {
            guard (try? dateDirectory.resourceValues(
                forKeys: [.isDirectoryKey]
            ).isDirectory) == true,
            let children = try? fileManager.contentsOfDirectory(
                at: dateDirectory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }
            for child in children where
                isRealtimeVoiceFixtureName(child.lastPathComponent)
            {
                try fileManager.removeItem(at: child)
            }
        }
    }

    private static func pruneRealtimeVoicePreferences(
        fixtureThreadIDs: Set<String>,
        userDefaults: UserDefaults
    ) {
        let outputKey = CodexDesktopProjectlessOutputDirectoryStore
            .defaultPersistenceKey
        let outputValues = userDefaults.dictionary(forKey: outputKey)
            as? [String: String] ?? [:]
        userDefaults.set(
            outputValues.filter {
                !fixtureThreadIDs.contains($0.key)
                    && !pathContainsRealtimeVoiceFixture($0.value)
            },
            forKey: outputKey
        )

        let assignmentStore = CodexDesktopThreadProjectAssignmentStore(
            userDefaults: userDefaults
        )
        for threadID in fixtureThreadIDs {
            _ = assignmentStore.removeAssignment(threadID: threadID)
        }

        let atomStore = CodexDesktopPersistedAtomStore(
            userDefaults: userDefaults
        )
        var atoms = atomStore.snapshot
        if case let .array(values)? = atoms["projectless-thread-ids"] {
            atoms["projectless-thread-ids"] = .array(values.filter {
                guard case let .string(threadID) = $0 else {
                    return true
                }
                return !fixtureThreadIDs.contains(threadID)
            })
        }
        if case let .object(values)? =
            atoms["thread-projectless-output-directories"]
        {
            atoms["thread-projectless-output-directories"] = .object(
                values.filter { threadID, value in
                    guard !fixtureThreadIDs.contains(threadID) else {
                        return false
                    }
                    guard case let .string(path) = value else {
                        return true
                    }
                    return !pathContainsRealtimeVoiceFixture(path)
                }
            )
        }
        for key in atoms.keys where key.hasPrefix(
            "thread-reference-capability:"
        ) {
            let threadID = String(
                key.dropFirst("thread-reference-capability:".count)
            )
            if fixtureThreadIDs.contains(threadID) {
                atoms.removeValue(forKey: key)
            }
        }
        _ = atomStore.replace(atoms)
        let documents = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        _ = atomStore.pruneStaleIOSApplicationContainerRoots(
            currentDocumentsURL: documents
        )

        _ = CodexDesktopLocalProjectsStateStore(
            userDefaults: userDefaults
        ).removeNumberedValidationProjects(
            baseName: realtimeVoiceBaseName
        )

        if let lastActive = userDefaults.string(
            forKey: "codex.desktop.last-active-local-thread-id"
        ), fixtureThreadIDs.contains(lastActive) {
            userDefaults.removeObject(
                forKey: "codex.desktop.last-active-local-thread-id"
            )
        }
    }

    private static func pathContainsRealtimeVoiceFixture(
        _ path: String
    ) -> Bool {
        path.split(separator: "/").contains {
            isRealtimeVoiceFixtureName(String($0))
        }
    }

    private static func isRealtimeVoiceFixtureName(_ name: String) -> Bool {
        guard name != realtimeVoiceBaseName else {
            return true
        }
        let prefix = realtimeVoiceBaseName + "-"
        guard name.hasPrefix(prefix) else {
            return false
        }
        let suffix = name.dropFirst(prefix.count)
        return !suffix.isEmpty && suffix.allSatisfy(\.isNumber)
    }
}

private extension Notification.Name {
    static let codexDesktopNativeShortcut = Notification.Name(
        "codex.desktop.native-shortcut"
    )
}

private struct CodexPadDesktopCommands: Commands {
    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            command("Settings", ",", .command, .settings)
        }

        CommandMenu("Codex") {
            command("New Chat", "n", .command, .newTask)
            command("Command Menu", "k", .command, .commandMenu)
            command(
                "Command Menu",
                "p",
                [.command, .shift],
                .commandMenuWithEmptyQuery
            )
            command("Search Files", "p", .command, .searchFiles)
            command(
                "Keyboard Shortcuts",
                "/",
                .command,
                .keyboardShortcuts
            )
            Divider()
            command("Toggle Sidebar", "b", .command, .toggleSidebar)
            command(
                "Toggle Bottom Panel",
                "j",
                .command,
                .toggleBottomPanel
            )
            command("Open Terminal", "`", .control, .toggleTerminal)
            command("Open Browser Tab", "t", .command, .openBrowserTab)
            command(
                "Open Review Tab",
                "g",
                [.control, .shift],
                .openReviewTab
            )
            command(
                "Open Side Chat",
                "s",
                [.command, .option],
                .openSideChat
            )
            command("Back", "[", .command, .navigateBack)
            command("Forward", "]", .command, .navigateForward)
            Divider()
            ForEach(1 ... 9, id: \.self) { slot in
                command(
                    "Open Chat \(slot)",
                    KeyEquivalent(Character(String(slot))),
                    .command,
                    .threadSlot(slot)
                )
            }
        }
    }

    private func command(
        _ title: String,
        _ key: KeyEquivalent,
        _ modifiers: EventModifiers,
        _ shortcut: CodexDesktopNativeShortcut
    ) -> some View {
        Button(title) {
            UserDefaults.standard.set(
                "path=swiftui-command shortcut=\(shortcut)",
                forKey: CodexDesktopFocusedDiagnosticStore.hardwareShortcutKey
            )
            NotificationCenter.default.post(
                name: .codexDesktopNativeShortcut,
                object: shortcut
            )
        }
        .keyboardShortcut(key, modifiers: modifiers)
    }
}

private struct CodexDesktopSceneRoot: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var runtime: CodexDesktopSceneRuntime
    @State private var isShowingNativeRecovery = false
    let store: CodexSessionStore
    let accountStore: CodexAccountStore
    let officialProvider: CodexOfficialProviderClient?
    let modelCatalogClient: (any CodexModelCatalogClient)?

    @MainActor
    init(
        runtimeFactory: CodexDesktopSceneRuntimeFactory,
        store: CodexSessionStore,
        accountStore: CodexAccountStore,
        officialProvider: CodexOfficialProviderClient?,
        modelCatalogClient: (any CodexModelCatalogClient)?
    ) {
        _runtime = State(
            initialValue: runtimeFactory.makeRuntime()
        )
        self.store = store
        self.accountStore = accountStore
        self.officialProvider = officialProvider
        self.modelCatalogClient = modelCatalogClient
    }

    var body: some View {
        Group {
            if isShowingNativeRecovery {
                ZStack(alignment: .topTrailing) {
                    CodexRootView(
                        store: store,
                        accountStore: accountStore,
                        officialProvider: officialProvider,
                        modelCatalogClient: modelCatalogClient,
                        nativeSurfaceActionBridge:
                            runtime.controller
                                .makeNativeSurfaceActionBridge()
                    )
                    Button("Return to Codex") {
                        isShowingNativeRecovery = false
                        runtime.controller.retry()
                    }
                    .buttonStyle(.borderedProminent)
                    .padding()
                }
            } else {
                CodexDesktopSurfaceView(
                    controller: runtime.controller,
                    onOpenNativeRecovery: {
                        isShowingNativeRecovery = true
                    }
                )
            }
        }
        .onChange(of: scenePhase) { _, phase in
            guard let lifecycle =
                runtime.remoteControlLifecycle
            else {
                return
            }
            Task {
                switch phase {
                case .active:
                    try? await lifecycle
                        .resumeTransportIfNeeded()
                case .background:
                    await lifecycle.suspendTransport()
                case .inactive:
                    break
                @unknown default:
                    break
                }
            }
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: .codexDesktopNativeShortcut
            )
        ) { notification in
            guard let shortcut = notification.object
                    as? CodexDesktopNativeShortcut
            else {
                return
            }
            runtime.controller.performNativeShortcut(shortcut)
        }
    }
}
