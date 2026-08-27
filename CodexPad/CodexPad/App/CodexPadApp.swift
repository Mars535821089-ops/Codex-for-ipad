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
                == "test-key-codexpad-placeholder"
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
