import SwiftUI
import UniformTypeIdentifiers

struct CodexRootView: View {
    @Bindable var store: CodexSessionStore
    @Bindable var accountStore: CodexAccountStore
    let officialProvider: CodexOfficialProviderClient?
    let modelCatalogClient: (any CodexModelCatalogClient)?
    let nativeSurfaceActionBridge: CodexNativeSurfaceActionBridge?
    @State private var inspectorPresented = false
    @State private var accountPresented = false
    @State private var workspacePickerPresented = false
    @State private var threadSheetPresented = false
    @State private var threadTitle = ""
    @State private var renamingThreadID: UUID?
    @State private var renamedThreadTitle = ""
    @State private var goalEditingThreadID: UUID?
    @State private var goalObjective = ""
    @State private var goalStatus = ThreadGoalStatus.active
    @State private var goalTokenBudget = ""
    @State private var operationProblem: String?
    @State private var filesPresented = false
    @State private var settingsPresented = false
    @State private var surfacesPresented = false
    @State private var activeSurface: CodexSurfaceRoute?
    @State private var streamingReply = CodexStreamingReply()
    @State private var persistedStreamingReply = CodexStreamingReply()
    @State private var pendingToolApproval: PendingToolApproval?
    @State private var threadDirectoryState =
        CodexThreadDirectoryViewState()
    @State private var threadResumeState =
        CodexThreadResumeViewState()
    @State private var modelCatalogState =
        CodexModelCatalogViewState()
    @State private var persistedThreadSearchText = ""
    @State private var persistedThreadSelection: String?
    @State private var threadDirectoryRequestSequence: Int64 = 0
    @State private var modelCatalogRequestSequence: Int64 = 0
    @State private var hasStartedThreadDirectory = false
    @State private var persistedSettingsDraft:
        PersistedThreadSettingsDraft?
    @State private var agentSettingsDraft = CodexAgentSettingsDraft(
        approvalPolicyRaw: CodexApprovalPolicy.onRequest.rawValue,
        sandboxModeRaw: CodexSandboxMode.workspaceWrite.rawValue,
        modelID: "",
        reasoningEffortRaw: ""
    )
    @AppStorage("codex.approval-policy")
    private var approvalPolicyRaw = CodexApprovalPolicy.onRequest.rawValue
    @AppStorage("codex.sandbox-mode")
    private var sandboxModeRaw = CodexSandboxMode.workspaceWrite.rawValue
    @AppStorage("codex.model")
    private var modelID = ""
    @AppStorage("codex.reasoning-effort")
    private var reasoningEffortRaw = ""
    private let workspaceAccess = CodexWorkspaceAccess()
    private let workspaceToolRunner = CodexWorkspaceToolRunner()

    private var selectedThread: CodexThread? {
        store.state.threads.first { $0.id == store.selectedThreadID }
    }

    private var selectedModelSelection: CodexModelSelection {
        if let threadID = store.selectedThreadID,
           let settings = store.threadSettings(for: threadID) {
            return modelCatalogState.selection(
                modelID: settings.model,
                reasoningEffortRaw: settings.effort?.rawValue
            )
        }
        return modelCatalogState.selection(
            modelID: modelID.isEmpty ? nil : modelID,
            reasoningEffortRaw:
                reasoningEffortRaw.isEmpty ? nil : reasoningEffortRaw
        )
    }

    private var activeModelCatalogSource: CodexModelCatalogSource {
        let modelProvider = activeModelProvider
        return CodexModelCatalogSource(
            modelProvider: modelProvider,
            accountIdentity:
                accountStore.isChatGPTSignedIn
                    ? accountStore.accountID
                    : nil,
            chatGPTAuthenticated:
                accountStore.isChatGPTSignedIn
                    && modelProvider.caseInsensitiveCompare("openai")
                        == .orderedSame
        )
    }

    private var activeModelProvider: String {
        if let rawThreadID = persistedThreadSelection {
            let threadID = CodexStoredThreadID(rawValue: rawThreadID)
            if let settings = store.threadSettings(for: threadID) {
                return settings.modelProvider
            }
            if let provider = threadResumeState.resumeResult?.modelProvider {
                return provider
            }
            if let provider =
                threadDirectoryState.selectedThread?.storedThread.modelProvider
            {
                return provider
            }
        }
        if let threadID = store.selectedThreadID,
           let settings = store.threadSettings(for: threadID) {
            return settings.modelProvider
        }
        return "openai"
    }

    var body: some View {
        NavigationSplitView {
            WorkspaceSidebar(
                workspaces: store.state.workspaces,
                threads: store.state.threads,
                archivedThreadIDs: store.state.archivedThreadIDs,
                goalThreadIDs: Set(store.state.threadGoals.map(\.threadID)),
                threadDirectoryState: threadDirectoryState,
                workspaceSelection: $store.selectedWorkspaceID,
                threadSelection: $store.selectedThreadID,
                persistedThreadSearchText: $persistedThreadSearchText,
                persistedThreadSelection: persistedThreadSelection,
                onPersistedArchiveScopeChange:
                    changePersistedThreadArchiveScope,
                onSelectPersistedThread: selectPersistedThread,
                onLoadMorePersistedThreads: loadMorePersistedThreads,
                onRetryPersistedThreads: retryPersistedThreadLoad,
                onActivateLiveSelection: clearPersistedThreadSelection,
                onCreateWorkspace: {
                    clearPersistedThreadSelection()
                    workspacePickerPresented = true
                },
                onCreateThread: {
                    clearPersistedThreadSelection()
                    if modelCatalogState.canRunModelOperations {
                        threadSheetPresented = true
                    } else {
                        operationProblem =
                            modelCatalogState.problem?.message
                            ?? "Load the server model catalog before creating a task."
                    }
                },
                onRenameThread: beginRenamingThread,
                onForkThread: forkThread,
                onEditThreadGoal: beginEditingGoal,
                onClearThreadGoal: clearThreadGoal,
                onArchiveThread: archiveThread,
                onUnarchiveThread: unarchiveThread,
                onDeleteThread: deleteThread
            )
        } detail: {
            ZStack {
                ThreadDetailView(
                    thread: selectedThread,
                    workspaceName: selectedWorkspace?.displayName,
                    modelName:
                        selectedModelSelection.model?.displayName
                            ?? selectedModelSelection.modelID
                            ?? "Model unavailable",
                    reasoningEffortName:
                        selectedModelSelection.reasoningEffortRaw
                            ?? "Unavailable",
                    goal: store.selectedThreadID.flatMap(
                        store.threadGoal(for:)
                    ),
                    items: store.state.items.filter {
                        $0.threadID == store.selectedThreadID
                    },
                    streamingText: streamingReply.text,
                    onSubmit: submitTurn,
                    onCancel: cancelActiveTurn
                )
                .disabled(!modelCatalogState.canRunModelOperations)
                .opacity(isBrowsingPersistedThread ? 0 : 1)
                .allowsHitTesting(!isBrowsingPersistedThread)
                .accessibilityHidden(isBrowsingPersistedThread)

                if isBrowsingPersistedThread {
                    PersistedThreadDetailView(
                        state: threadDirectoryState,
                        resumeState: threadResumeState,
                        canOpenLiveTask:
                            liveThreadMatchingPersistedSelection != nil,
                        onOpenLiveTask: openPersistedThreadAsLiveTask,
                        onResumeTask: resumePersistedThread,
                        streamingText: persistedStreamingReply.text,
                        latestDiff: store.resumedTurnState.latestDiff,
                        onSubmit: submitPersistedTurn,
                        onCancel: cancelActiveTurn,
                        onRetryRead: retryPersistedThreadRead
                    )
                    .zIndex(1)
                }
            }
        }
        .onChange(of: store.selectedWorkspaceID) {
            clearPersistedThreadSelection()
            if !store.state.threads.contains(where: {
                $0.id == store.selectedThreadID
                    && $0.workspaceID == store.selectedWorkspaceID
            }) {
                store.selectedThreadID = nil
            }
        }
        .onChange(of: store.selectedThreadID) {
            if store.selectedThreadID != nil {
                clearPersistedThreadSelection()
            }
        }
        .onChange(of: store.lastThreadSettingsNotification) {
            guard let notification = store.lastThreadSettingsNotification else {
                return
            }
            threadResumeState.reconcileThreadSettings(notification)
        }
        .task(id: persistedThreadSearchText) {
            let isInitialLoad = !hasStartedThreadDirectory
            if isInitialLoad {
                hasStartedThreadDirectory = true
            } else {
                do {
                    try await Task.sleep(for: .milliseconds(250))
                } catch {
                    return
                }
            }

            guard !Task.isCancelled else {
                return
            }
            applyPersistedThreadSearchText()
        }
        .task(id: activeModelCatalogSource) {
            loadModelCatalog(for: activeModelCatalogSource)
        }
        .tint(CodexTheme.accent)
        .inspector(isPresented: $inspectorPresented) {
            SessionInspectorView(store: store)
                .inspectorColumnWidth(min: 260, ideal: 320, max: 420)
        }
        .fileImporter(
            isPresented: $workspacePickerPresented,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false,
            onCompletion: openWorkspace
        )
        .sheet(isPresented: $threadSheetPresented) {
            NameEntrySheet(
                title: "New thread",
                fieldLabel: "What are you working on?",
                value: $threadTitle,
                onCancel: {
                    threadTitle = ""
                    threadSheetPresented = false
                },
                onSubmit: createThread
            )
        }
        .sheet(
            isPresented: Binding(
                get: { renamingThreadID != nil },
                set: {
                    if !$0 {
                        renamingThreadID = nil
                        renamedThreadTitle = ""
                    }
                }
            )
        ) {
            NameEntrySheet(
                title: "Rename thread",
                fieldLabel: "Thread name",
                value: $renamedThreadTitle,
                onCancel: {
                    renamingThreadID = nil
                    renamedThreadTitle = ""
                },
                onSubmit: commitThreadRename
            )
        }
        .sheet(
            isPresented: Binding(
                get: { goalEditingThreadID != nil },
                set: {
                    if !$0 {
                        resetGoalEditor()
                    }
                }
            )
        ) {
            ThreadGoalEditorSheet(
                objective: $goalObjective,
                status: $goalStatus,
                tokenBudget: $goalTokenBudget,
                onCancel: resetGoalEditor,
                onSave: commitThreadGoal
            )
        }
        .sheet(isPresented: $accountPresented) {
            CodexAccountView(
                accountStore: accountStore,
                threadID: store.selectedThreadID?.uuidString.lowercased()
            )
        }
        .sheet(isPresented: $filesPresented) {
            if let workspace = selectedWorkspace {
                WorkspaceFilesView(workspace: workspace)
            }
        }
        .sheet(isPresented: $settingsPresented) {
            CodexAgentSettingsView(
                approvalPolicyRaw:
                    $agentSettingsDraft.approvalPolicyRaw,
                sandboxModeRaw: $agentSettingsDraft.sandboxModeRaw,
                modelID: $agentSettingsDraft.modelID,
                reasoningEffortRaw:
                    $agentSettingsDraft.reasoningEffortRaw,
                modelCatalog: modelCatalogState,
                onSave: commitThreadSettings
            )
        }
        .sheet(isPresented: $surfacesPresented) {
            NavigationStack {
                CodexSurfacePicker(selection: Binding(
                    get: { activeSurface ?? .mainShell },
                    set: { newValue in
                        activeSurface = newValue
                        surfacesPresented = false
                    }
                ))
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close") { surfacesPresented = false }
                    }
                }
            }
            .presentationDetents([.medium, .large])
        }
        .fullScreenCover(item: $activeSurface) { route in
            NavigationStack {
                surfaceView(for: route)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") { activeSurface = nil }
                        }
                    }
            }
        }
        .alert(
            "Allow this workspace change?",
            isPresented: Binding(
                get: { pendingToolApproval != nil },
                set: { if !$0 { resolveToolApproval(false) } }
            ),
            presenting: pendingToolApproval
        ) { approval in
            Button("Deny", role: .cancel) {
                resolveToolApproval(false)
            }
            Button("Allow") {
                resolveToolApproval(true)
            }
        } message: { approval in
            Text(approval.summary)
        }
        .alert(
            "Something went wrong",
            isPresented: Binding(
                get: { operationProblem != nil },
                set: { if !$0 { operationProblem = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(operationProblem ?? "")
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    surfacesPresented = true
                } label: {
                    Label("Surfaces", systemImage: "rectangle.3.group")
                }
                .accessibilityHint("Open the surface switcher (S01-S10).")
                .accessibilityIdentifier("codex.surfaces.open")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    filesPresented = true
                } label: {
                    Label("Files", systemImage: "folder")
                }
                .disabled(
                    isBrowsingPersistedThread
                        || selectedWorkspace?.rootBookmarkID == nil
                )
                .accessibilityHint(
                    isBrowsingPersistedThread
                        ? "Return to a live task to browse workspace files."
                        : "Browse files in the selected live project."
                )
                .help(
                    isBrowsingPersistedThread
                        ? "Available from a live task"
                        : "Browse project files"
                )
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    beginThreadSettingsEditing()
                } label: {
                    Label("Agent settings", systemImage: "gearshape")
                }
                .disabled(
                    !modelCatalogState.canRunModelOperations
                        || (isBrowsingPersistedThread
                            && !canEditPersistedThreadSettings)
                )
                .accessibilityHint(
                    isBrowsingPersistedThread
                        ? canEditPersistedThreadSettings
                            ? "Edit settings for the resumed saved task."
                            : "Resume this saved task before editing its agent settings."
                        : "Edit settings for the selected live task."
                )
                .help(
                    isBrowsingPersistedThread
                        ? canEditPersistedThreadSettings
                            ? "Edit resumed task settings"
                            : "Resume this task to edit settings"
                        : "Edit live task settings"
                )
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    accountPresented = true
                } label: {
                    Label(
                        accountStore.isSignedIn
                            ? accountStore.authMode == .apiKey
                                ? "API Key Connected"
                                : "ChatGPT Connected"
                            : "Sign In",
                        systemImage: accountStore.isSignedIn
                            ? "person.crop.circle.fill.badge.checkmark"
                            : "person.crop.circle"
                    )
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    inspectorPresented.toggle()
                } label: {
                    Label("Inspector", systemImage: "sidebar.right")
                }
            }
        }
    }

    private var selectedWorkspace: Workspace? {
        store.state.workspaces.first { $0.id == store.selectedWorkspaceID }
    }

    private var selectedWorkspacePath: String? {
        guard let bookmark = selectedWorkspace?.rootBookmarkID else {
            return nil
        }
        return try? workspaceAccess.resolve(bookmark).path
    }

    private var isBrowsingPersistedThread: Bool {
        persistedThreadSelection != nil
    }

    private var canEditPersistedThreadSettings: Bool {
        guard let rawThreadID = persistedThreadSelection,
              threadDirectoryState.selectedThreadID?.rawValue == rawThreadID,
              threadResumeState.phase == .resumed,
              threadResumeState.selectedThreadID?.rawValue == rawThreadID,
              threadResumeState.resumeResult?.thread.id.rawValue == rawThreadID
        else {
            return false
        }
        return true
    }

    private var liveThreadMatchingPersistedSelection: CodexThread? {
        guard let rawID = persistedThreadSelection,
              threadDirectoryState.selectedThreadID?.rawValue == rawID,
              let threadID = UUID(uuidString: rawID),
              threadID.uuidString.lowercased() == rawID.lowercased()
        else {
            return nil
        }
        return store.state.threads.first { $0.id == threadID }
    }

    private var executionPolicy: CodexExecutionPolicy {
        CodexExecutionPolicy(
            approvalPolicy: CodexApprovalPolicy(rawValue: approvalPolicyRaw)
                ?? .onRequest,
            sandboxMode: CodexSandboxMode(rawValue: sandboxModeRaw)
                ?? .workspaceWrite
        )
    }

    private func applyPersistedThreadSearchText() {
        let criteriaChanged =
            threadDirectoryState.criteria.searchText
            != persistedThreadSearchText
        if criteriaChanged {
            clearPersistedThreadSelection()
            threadDirectoryState.setSearchText(
                persistedThreadSearchText
            )
        }
        if criteriaChanged || threadDirectoryState.loadPhase == .idle {
            loadInitialPersistedThreads()
        }
    }

    private func changePersistedThreadArchiveScope(
        _ archiveScope: CodexThreadDirectoryArchiveScope
    ) {
        guard threadDirectoryState.criteria.archiveScope != archiveScope
        else {
            return
        }
        clearPersistedThreadSelection()
        threadDirectoryState.setArchiveScope(archiveScope)
        loadInitialPersistedThreads()
    }

    private func loadInitialPersistedThreads() {
        let request = threadDirectoryState.beginInitialLoad()
        performPersistedThreadLoad(request)
    }

    private func loadMorePersistedThreads() {
        guard let request = threadDirectoryState.beginNextPageLoad()
        else {
            return
        }
        performPersistedThreadLoad(request)
    }

    private func retryPersistedThreadLoad() {
        if threadDirectoryState.rows.isEmpty {
            loadInitialPersistedThreads()
        } else {
            loadMorePersistedThreads()
        }
    }

    private func performPersistedThreadLoad(
        _ request: CodexThreadDirectoryLoadRequest
    ) {
        let requestID = nextPersistedThreadRequestID()
        do {
            switch request.query {
            case let .list(params):
                let page = try store.listThreads(
                    id: requestID,
                    params: params
                )
                threadDirectoryState.receiveListPage(
                    page,
                    for: request
                )

            case let .search(params):
                let page = try store.searchThreads(
                    id: requestID,
                    params: params
                )
                threadDirectoryState.receiveSearchPage(
                    page,
                    for: request
                )
            }
        } catch {
            threadDirectoryState.failLoad(
                String(describing: error),
                for: request
            )
        }
    }

    private func selectPersistedThread(_ rawID: String) {
        clearPersistedThreadSelection()
        store.selectedThreadID = nil
        persistedThreadSelection = rawID
        let storedThreadID = CodexStoredThreadID(rawValue: rawID)
        store.selectResumedTurnThread(storedThreadID)
        threadResumeState.selectThread(storedThreadID)
        let request = threadDirectoryState.selectThread(
            storedThreadID
        )
        performPersistedThreadRead(request)
    }

    private func retryPersistedThreadRead() {
        guard let rawID = persistedThreadSelection else {
            return
        }
        let request = threadDirectoryState.selectThread(
            CodexStoredThreadID(rawValue: rawID)
        )
        performPersistedThreadRead(request)
    }

    private func performPersistedThreadRead(
        _ request: CodexThreadDirectoryReadRequest
    ) {
        let requestID = nextPersistedThreadRequestID()
        do {
            let result = try store.readThread(
                id: requestID,
                params: request.params
            )
            threadDirectoryState.receiveReadResult(
                result,
                for: request
            )
            if threadDirectoryState.selectedThreadID == result.thread.id,
               let presentation = threadDirectoryState.selectedThread {
                threadResumeState.reconcileResumedThread(
                    with: presentation
                )
            }
        } catch {
            threadDirectoryState.failSelection(
                String(describing: error),
                for: request
            )
        }
    }

    private func nextPersistedThreadRequestID()
        -> CodexAppServerRequestID
    {
        threadDirectoryRequestSequence += 1
        return .integer(threadDirectoryRequestSequence)
    }

    private func nextModelCatalogRequestID()
        -> CodexAppServerRequestID
    {
        modelCatalogRequestSequence += 1
        return .string("model-catalog-\(modelCatalogRequestSequence)")
    }

    private func loadModelCatalog(for source: CodexModelCatalogSource) {
        let load = modelCatalogState.beginLoad(source: source)
        guard let modelCatalogClient else {
            modelCatalogState.fail(
                .transport("The app-server model catalog is unavailable."),
                for: load.capabilities
            )
            return
        }
        do {
            try modelCatalogClient.submit(.clear)
            try modelCatalogClient.submit(
                .configure(
                    try modelCatalogRuntimeConfiguration(for: source)
                )
            )
        } catch {
            modelCatalogState.fail(
                .transport(String(describing: error)),
                for: load.capabilities
            )
            return
        }

        let capabilitiesID = nextModelCatalogRequestID()
        do {
            let data = try modelCatalogClient.request(
                .providerCapabilitiesRead(id: capabilitiesID)
            )
            let reply = try JSONDecoder().decode(
                CodexAppServerReply<CodexModelProviderCapabilities>.self,
                from: data
            )
            switch reply {
            case let .success(response):
                guard response.id == capabilitiesID else {
                    modelCatalogState.fail(
                        .invalidResponse(
                            "The capabilities reply used another request id."
                        ),
                        for: load.capabilities
                    )
                    return
                }
                modelCatalogState.receive(
                    response.result,
                    for: load.capabilities
                )
            case let .failure(response):
                guard response.id == capabilitiesID else {
                    modelCatalogState.fail(
                        .invalidResponse(
                            "The capabilities error used another request id."
                        ),
                        for: load.capabilities
                    )
                    return
                }
                modelCatalogState.fail(
                    .server(
                        code: response.error.code,
                        message: response.error.message
                    ),
                    for: load.capabilities
                )
                return
            }
        } catch {
            modelCatalogState.fail(
                .transport(String(describing: error)),
                for: load.capabilities
            )
            return
        }

        var pageRequest: CodexModelCatalogPageRequest? = load.firstPage
        while let currentPage = pageRequest {
            let requestID = nextModelCatalogRequestID()
            do {
                let data = try modelCatalogClient.request(
                    .list(id: requestID, params: currentPage.params)
                )
                let reply = try JSONDecoder().decode(
                    CodexAppServerReply<CodexModelListResponse>.self,
                    from: data
                )
                switch reply {
                case let .success(response):
                    guard response.id == requestID else {
                        modelCatalogState.fail(
                            .invalidResponse(
                                "The model-list reply used another request id."
                            ),
                            for: currentPage
                        )
                        return
                    }
                    pageRequest = modelCatalogState.receive(
                        response.result,
                        for: currentPage
                    )
                case let .failure(response):
                    guard response.id == requestID else {
                        modelCatalogState.fail(
                            .invalidResponse(
                                "The model-list error used another request id."
                            ),
                            for: currentPage
                        )
                        return
                    }
                    modelCatalogState.fail(
                        .server(
                            code: response.error.code,
                            message: response.error.message
                        ),
                        for: currentPage
                    )
                    return
                }
            } catch {
                modelCatalogState.fail(
                    .transport(String(describing: error)),
                    for: currentPage
                )
                return
            }
        }

        synchronizeNewThreadModelSelection()
    }

    private func modelCatalogRuntimeConfiguration(
        for source: CodexModelCatalogSource
    ) throws -> CodexModelCatalogRuntimeConfiguration {
        guard let cachesDirectory = FileManager.default.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        ).first else {
            throw CodexModelCatalogConfigurationError
                .cacheDirectoryUnavailable
        }
        let credentials =
            source.chatGPTAuthenticated
                ? accountStore.chatGPTCredentials()
                : nil
        return CodexModelCatalogRuntimeConfiguration(
            providerID: source.modelProvider,
            accountIdentity: source.accountIdentity,
            accessToken: credentials?.accessToken,
            accountID: credentials?.accountID,
            baseURL: nil,
            chatGPTAuth: credentials != nil,
            cacheDirectory: cachesDirectory
                .appendingPathComponent(
                    "CodexForIPad/ModelCatalog",
                    isDirectory: true
                )
                .path,
            capabilities: nil
        )
    }

    @ViewBuilder
    private func surfaceView(for route: CodexSurfaceRoute) -> some View {
        switch route {
        case .launchAndSignIn:
            CodexSurfaceLaunchSignInView(
                store: store,
                accountStore: accountStore
            )
        case .mainShell:
            CodexSurfaceMainShellView(store: store)
        case .homeProjects:
            CodexSurfaceHomeProjectsView(store: store)
        case .conversationWorkspace:
            CodexSurfaceConversationWorkspaceView(
                threadTitle: selectedThread?.title ?? "New conversation"
            )
        case .taskPanels:
            CodexSurfaceTaskPanelsView()
        case .reviewDiff:
            CodexSurfaceReviewDiffView(
                actionBridge: nativeSurfaceActionBridge,
                cwd: selectedWorkspacePath
            )
        case .terminal:
            CodexSurfaceTerminalView(
                actionBridge: nativeSurfaceActionBridge,
                cwd: selectedWorkspacePath
            )
        case .settingsShortcuts:
            CodexSurfaceSettingsShortcutsView(accountStore: accountStore)
        case .secondaryProducts:
            CodexSurfaceSecondaryProductsView()
        case .globalOverlays:
            CodexSurfaceGlobalOverlaysView()
        }
    }

        private func synchronizeNewThreadModelSelection() {
        guard modelCatalogState.canRunModelOperations,
              store.selectedThreadID == nil,
              persistedThreadSelection == nil,
              let defaultModel = modelCatalogState.defaultModel
        else {
            return
        }
        modelID = defaultModel.model
        reasoningEffortRaw =
            defaultModel.defaultReasoningEffort.rawValue
    }

    private func clearPersistedThreadSelection() {
        let hadPersistedSelection =
            persistedThreadSelection != nil
                || threadDirectoryState.selectedThreadID != nil
                || threadResumeState.selectedThreadID != nil
                || store.resumedTurnState.exactRawThreadID != nil
        store.clearResumedTurnSelection()
        guard hadPersistedSelection else {
            return
        }
        resolveToolApproval(false)
        persistedStreamingReply.reset()
        persistedSettingsDraft = nil
        persistedThreadSelection = nil
        threadDirectoryState.clearSelection()
        threadResumeState.clearSelection()
    }

    private func resumePersistedThread() {
        guard let persistedThread =
                threadDirectoryState.selectedThread?.storedThread,
              persistedThreadSelection == persistedThread.id.rawValue,
              modelCatalogState.canRunModelOperations
        else {
            if !modelCatalogState.canRunModelOperations {
                operationProblem =
                    modelCatalogState.problem?.message
                    ?? "Load the server model catalog before resuming this task."
            }
            return
        }
        // Omitting overrides lets app-server restore the task's persisted
        // model, effort, provider, cwd, and execution policies verbatim.
        let params = CodexThreadResumeParams(threadID: persistedThread.id)
        guard let request = threadResumeState.beginResume(params) else {
            return
        }
        Task { @MainActor in
            await Task.yield()
            let requestID = nextPersistedThreadRequestID()
            do {
                let result = try store.resumeThread(
                    id: requestID,
                    params: request.params
                )
                threadResumeState.receiveResumeResult(
                    result,
                    for: request
                )
                if threadResumeState.phase == .resumed,
                   threadResumeState.selectedThreadID == result.thread.id,
                   persistedThreadSelection == result.thread.id.rawValue {
                    store.selectResumedTurnThread(result.thread.id)
                }
            } catch {
                threadResumeState.failResume(
                    String(describing: error),
                    for: request
                )
            }
        }
    }

    private func openPersistedThreadAsLiveTask() {
        guard let thread = liveThreadMatchingPersistedSelection else {
            return
        }
        store.selectedWorkspaceID = thread.workspaceID
        store.selectedThreadID = thread.id
        clearPersistedThreadSelection()
    }

    private func beginThreadSettingsEditing() {
        agentSettingsDraft = CodexAgentSettingsDraft(
            approvalPolicyRaw: approvalPolicyRaw,
            sandboxModeRaw: sandboxModeRaw,
            modelID: modelID,
            reasoningEffortRaw: reasoningEffortRaw
        )
        if let rawThreadID = persistedThreadSelection {
            guard canEditPersistedThreadSettings,
                  let resumeResult = threadResumeState.resumeResult,
                  resumeResult.thread.id.rawValue == rawThreadID
            else {
                return
            }
            let threadID = CodexStoredThreadID(rawValue: rawThreadID)
            let runtime = CodexResumedThreadRuntimeSettings(
                resumeResult: resumeResult,
                authoritativeSettings: store.threadSettings(for: threadID)
            )
            agentSettingsDraft.modelID = runtime.model
            agentSettingsDraft.reasoningEffortRaw = runtime.effort
                ?? modelCatalogState.model(selectionID: runtime.model)?
                    .defaultReasoningEffort.rawValue
                ?? ""
            agentSettingsDraft.approvalPolicyRaw =
                Self.editorApprovalPolicyRaw(
                runtime.approvalPolicy
            )
            agentSettingsDraft.sandboxModeRaw =
                Self.editorSandboxModeRaw(
                runtime.sandboxPolicy
            )
            persistedSettingsDraft = PersistedThreadSettingsDraft(
                threadID: threadID,
                cwd: runtime.cwd,
                modelID: agentSettingsDraft.modelID,
                reasoningEffortRaw:
                    agentSettingsDraft.reasoningEffortRaw,
                approvalPolicyRaw:
                    agentSettingsDraft.approvalPolicyRaw,
                sandboxModeRaw:
                    agentSettingsDraft.sandboxModeRaw
            )
            settingsPresented = true
            return
        }

        persistedSettingsDraft = nil
        if let threadID = store.selectedThreadID,
           let settings = store.threadSettings(for: threadID) {
            agentSettingsDraft.modelID = settings.model
            agentSettingsDraft.reasoningEffortRaw =
                settings.effort?.rawValue
                ?? modelCatalogState.model(selectionID: settings.model)?
                    .defaultReasoningEffort.rawValue
                ?? ""
            agentSettingsDraft.approvalPolicyRaw =
                switch settings.approvalPolicy {
            case .untrusted: CodexApprovalPolicy.untrusted.rawValue
            case .onRequest: CodexApprovalPolicy.onRequest.rawValue
            case .never: CodexApprovalPolicy.never.rawValue
            }
            agentSettingsDraft.sandboxModeRaw =
                switch settings.sandboxPolicy {
            case .readOnly: CodexSandboxMode.readOnly.rawValue
            case .workspaceWrite: CodexSandboxMode.workspaceWrite.rawValue
            case .dangerFullAccess: CodexSandboxMode.fullAccess.rawValue
            }
        } else if let defaultModel = modelCatalogState.defaultModel {
            agentSettingsDraft.modelID = defaultModel.model
            agentSettingsDraft.reasoningEffortRaw =
                defaultModel.defaultReasoningEffort.rawValue
        }
        settingsPresented = true
    }

    private func commitThreadSettings() {
        if let draft = persistedSettingsDraft {
            commitPersistedThreadSettings(draft)
            return
        }

        guard let threadID = store.selectedThreadID,
              let workspace = selectedWorkspace,
              let bookmark = workspace.rootBookmarkID,
              modelCatalogState.canRunModelOperations
        else {
            operationProblem =
                modelCatalogState.problem?.message
                ?? "Select a thread with an open project and a loaded model catalog first."
            return
        }
        let selection = modelCatalogState.selection(
            modelID: agentSettingsDraft.modelID.isEmpty
                ? nil
                : agentSettingsDraft.modelID,
            reasoningEffortRaw:
                agentSettingsDraft.reasoningEffortRaw.isEmpty
                    ? nil
                    : agentSettingsDraft.reasoningEffortRaw
        )
        guard selection.isAvailable,
              let model = selection.model,
              let effortRaw = selection.reasoningEffortRaw,
              let effort = CodexReasoningEffort(rawValue: effortRaw)
        else {
            operationProblem =
                "Select a model and reasoning effort available in the current server catalog."
            return
        }
        do {
            let cwd = try workspaceAccess.resolve(bookmark).path
            let approval: ThreadApprovalPolicy = switch CodexApprovalPolicy(
                rawValue: agentSettingsDraft.approvalPolicyRaw
            ) ?? .onRequest {
            case .untrusted: .untrusted
            case .never: .never
            case .onFailure, .onRequest: .onRequest
            }
            let sandbox: ThreadSandboxPolicy = switch CodexSandboxMode(
                rawValue: agentSettingsDraft.sandboxModeRaw
            ) ?? .workspaceWrite {
            case .readOnly: .readOnly
            case .workspaceWrite: .workspaceWrite
            case .fullAccess: .dangerFullAccess
            }
            try store.updateThreadSettings(
                ThreadSettings(
                    threadID: threadID,
                    cwd: cwd,
                    model: model.model,
                    effort: effort,
                    approvalPolicy: approval,
                    sandboxPolicy: sandbox
                )
            )
        } catch {
            operationProblem = String(describing: error)
        }
    }

    private func commitPersistedThreadSettings(
        _ draft: PersistedThreadSettingsDraft
    ) {
        guard persistedThreadSelection == draft.threadID.rawValue,
              threadDirectoryState.selectedThreadID == draft.threadID,
              threadResumeState.phase == .resumed,
              threadResumeState.selectedThreadID == draft.threadID,
              threadResumeState.resumeResult?.thread.id == draft.threadID
        else {
            operationProblem = "The resumed task selection changed."
            return
        }

        let modelChanged =
            agentSettingsDraft.modelID != draft.modelID
        let effortChanged =
            agentSettingsDraft.reasoningEffortRaw
                != draft.reasoningEffortRaw
        let approvalChanged =
            agentSettingsDraft.approvalPolicyRaw
                != draft.approvalPolicyRaw
        let sandboxChanged =
            agentSettingsDraft.sandboxModeRaw
                != draft.sandboxModeRaw
        guard modelChanged || effortChanged
                || approvalChanged || sandboxChanged
        else {
            persistedSettingsDraft = nil
            return
        }

        let selection = modelCatalogState.selection(
            modelID: agentSettingsDraft.modelID.isEmpty
                ? nil
                : agentSettingsDraft.modelID,
            reasoningEffortRaw:
                agentSettingsDraft.reasoningEffortRaw.isEmpty
                    ? nil
                    : agentSettingsDraft.reasoningEffortRaw
        )
        if modelChanged || effortChanged {
            guard modelCatalogState.canRunModelOperations,
                  selection.isAvailable,
                  let selectedModel = selection.model,
                  let selectedEffort = selection.reasoningEffortRaw
            else {
                operationProblem =
                    "The selected model or reasoning effort is unavailable."
                return
            }
            agentSettingsDraft.modelID = selectedModel.model
            agentSettingsDraft.reasoningEffortRaw = selectedEffort
        }

        let params = CodexThreadSettingsUpdateParams(
            threadID: draft.threadID,
            approvalPolicy: approvalChanged
                ? .value(
                    Self.appServerApprovalPolicy(
                        agentSettingsDraft.approvalPolicyRaw
                    )
                )
                : .omitted,
            sandboxPolicy: sandboxChanged
                ? .value(
                    Self.appServerSandboxPolicy(
                        agentSettingsDraft.sandboxModeRaw,
                        cwd: draft.cwd
                    )
                )
                : .omitted,
            model: modelChanged
                ? .value(agentSettingsDraft.modelID)
                : .omitted,
            effort: effortChanged
                ? .value(agentSettingsDraft.reasoningEffortRaw)
                : .omitted
        )

        do {
            try store.updateThreadSettings(
                id: nextPersistedThreadRequestID(),
                params: params
            )
            guard let settings = store.threadSettings(for: draft.threadID)
            else {
                throw CodexSessionStoreError.invalidReply
            }
            let notification = CodexThreadSettingsUpdatedNotification(
                threadID: draft.threadID,
                threadSettings: settings
            )
            guard threadResumeState.reconcileThreadSettings(notification)
            else {
                throw CodexSessionStoreError.invalidReply
            }
            persistedSettingsDraft = nil
        } catch {
            operationProblem = String(describing: error)
        }
    }

    private static func editorApprovalPolicyRaw(
        _ policy: CodexAppServerAskForApproval
    ) -> String {
        switch policy {
        case .untrusted:
            CodexApprovalPolicy.untrusted.rawValue
        case .onRequest:
            CodexApprovalPolicy.onRequest.rawValue
        case let .granular(granular):
            granular.sandboxApproval
                ? CodexApprovalPolicy.onRequest.rawValue
                : CodexApprovalPolicy.never.rawValue
        case .never:
            CodexApprovalPolicy.never.rawValue
        }
    }

    private static func editorSandboxModeRaw(
        _ policy: CodexAppServerSandboxPolicy
    ) -> String {
        switch policy {
        case .dangerFullAccess:
            CodexSandboxMode.fullAccess.rawValue
        case .readOnly, .externalSandbox:
            CodexSandboxMode.readOnly.rawValue
        case .workspaceWrite:
            CodexSandboxMode.workspaceWrite.rawValue
        }
    }

    private static func appServerApprovalPolicy(
        _ rawValue: String
    ) -> CodexAppServerAskForApproval {
        switch CodexApprovalPolicy(rawValue: rawValue) ?? .onRequest {
        case .untrusted:
            .untrusted
        case .onFailure, .onRequest:
            .onRequest
        case .never:
            .never
        }
    }

    private static func appServerSandboxPolicy(
        _ rawValue: String,
        cwd: String
    ) -> CodexAppServerSandboxPolicy {
        switch CodexSandboxMode(rawValue: rawValue) ?? .workspaceWrite {
        case .readOnly:
            .readOnly(networkAccess: false)
        case .workspaceWrite:
            .workspaceWrite(
                writableRoots: [cwd],
                networkAccess: false,
                excludeTmpdirEnvVar: false,
                excludeSlashTmp: false
            )
        case .fullAccess:
            .dangerFullAccess
        }
    }

    private func openWorkspace(
        _ result: Result<[URL], any Error>
    ) {
        do {
            let urls = try result.get()
            guard let url = urls.first else {
                throw CodexWorkspaceAccessError.accessDenied
            }
            let bookmark = try workspaceAccess.bookmark(for: url)
            try store.openWorkspace(
                id: UUID(),
                displayName: url.lastPathComponent,
                rootBookmarkID: bookmark
            )
        } catch {
            operationProblem = "The selected folder could not be opened."
        }
    }

    private func createThread() {
        let title = threadTitle.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !title.isEmpty,
              let workspaceID = store.selectedWorkspaceID,
              let workspace = selectedWorkspace,
              workspace.id == workspaceID,
              let bookmark = workspace.rootBookmarkID,
              modelCatalogState.canRunModelOperations,
              let defaultModel = modelCatalogState.defaultModel
        else {
            if !modelCatalogState.canRunModelOperations {
                operationProblem =
                    modelCatalogState.problem?.message
                    ?? "Load the server model catalog before creating a task."
            }
            return
        }
        do {
            let threadID = UUID()
            let timestamp = Self.currentUnixTimestamp()
            let cwd = try workspaceAccess.resolve(bookmark).path
            try store.startThread(
                id: threadID,
                workspaceID: workspaceID,
                title: title,
                metadata: CodexThreadCreateMetadata(
                    sessionID: threadID.uuidString.lowercased(),
                    forkedFromID: nil,
                    preview: "",
                    ephemeral: false,
                    modelProvider: "openai",
                    createdAt: timestamp,
                    updatedAt: timestamp,
                    recencyAt: timestamp,
                    path: nil,
                    cwd: cwd,
                    cliVersion: CodexBuildMetadata.embeddedCliVersion,
                    source: .named(.appServer),
                    threadSource: "user",
                    parentThreadID: nil,
                    agentNickname: nil,
                    agentRole: nil,
                    gitInfo: nil
                )
            )
            let approval: ThreadApprovalPolicy =
                switch executionPolicy.approvalPolicy {
                case .untrusted:
                    .untrusted
                case .onFailure, .onRequest:
                    .onRequest
                case .never:
                    .never
                }
            let sandbox: ThreadSandboxPolicy =
                switch executionPolicy.sandboxMode {
                case .readOnly:
                    .readOnly
                case .workspaceWrite:
                    .workspaceWrite
                case .fullAccess:
                    .dangerFullAccess
                }
            do {
                try store.updateThreadSettings(
                    ThreadSettings(
                        threadID: threadID,
                        cwd: cwd,
                        model: defaultModel.model,
                        modelProvider: "openai",
                        effort: defaultModel.defaultReasoningEffort,
                        approvalPolicy: approval,
                        approvalsReviewer: "user",
                        sandboxPolicy: sandbox
                    )
                )
            } catch {
                try? store.deleteThread(id: threadID)
                throw error
            }
            loadInitialPersistedThreads()
            threadTitle = ""
            threadSheetPresented = false
        } catch {
            operationProblem = String(describing: error)
        }
    }

    private func beginRenamingThread(_ thread: CodexThread) {
        renamingThreadID = thread.id
        renamedThreadTitle = thread.title
    }

    private func commitThreadRename() {
        guard let threadID = renamingThreadID else {
            return
        }
        do {
            try store.setThreadName(id: threadID, name: renamedThreadTitle)
            loadInitialPersistedThreads()
            renamingThreadID = nil
            renamedThreadTitle = ""
        } catch {
            operationProblem = String(describing: error)
        }
    }

    private func archiveThread(_ thread: CodexThread) {
        do {
            try store.archiveThread(id: thread.id)
            loadInitialPersistedThreads()
        } catch {
            operationProblem = String(describing: error)
        }
    }

    private func unarchiveThread(_ thread: CodexThread) {
        do {
            try store.unarchiveThread(id: thread.id)
            loadInitialPersistedThreads()
            store.selectedWorkspaceID = thread.workspaceID
            store.selectedThreadID = thread.id
        } catch {
            operationProblem = String(describing: error)
        }
    }

    private func deleteThread(_ thread: CodexThread) {
        do {
            try store.deleteThread(id: thread.id)
            loadInitialPersistedThreads()
        } catch {
            operationProblem = String(describing: error)
        }
    }

    private func forkThread(_ thread: CodexThread) {
        do {
            try store.forkThread(
                id: thread.id,
                newThreadID: UUID(),
                title: "\(thread.title) (fork)",
                timestamp: Self.currentUnixTimestamp()
            )
            loadInitialPersistedThreads()
        } catch {
            operationProblem = String(describing: error)
        }
    }

    private func beginEditingGoal(_ thread: CodexThread) {
        let goal = store.threadGoal(for: thread.id)
        goalEditingThreadID = thread.id
        goalObjective = goal?.objective ?? ""
        goalStatus = goal?.status ?? .active
        goalTokenBudget = goal?.tokenBudget.map(String.init) ?? ""
    }

    private func commitThreadGoal() {
        guard let threadID = goalEditingThreadID else {
            return
        }
        let budgetText = goalTokenBudget.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let budget = budgetText.isEmpty ? nil : Int64(budgetText)
        guard budgetText.isEmpty || budget != nil else {
            operationProblem = "Token budget must be a whole number."
            return
        }
        do {
            try store.setThreadGoal(
                threadID: threadID,
                objective: goalObjective,
                status: goalStatus,
                tokenBudget: budget
            )
            resetGoalEditor()
        } catch {
            operationProblem = String(describing: error)
        }
    }

    private func clearThreadGoal(_ thread: CodexThread) {
        do {
            try store.clearThreadGoal(threadID: thread.id)
        } catch {
            operationProblem = String(describing: error)
        }
    }

    private func resetGoalEditor() {
        goalEditingThreadID = nil
        goalObjective = ""
        goalStatus = .active
        goalTokenBudget = ""
    }

    private func submitPersistedTurn(
        _ text: String,
        cancellation: CodexTurnCancellation
    ) async throws {
        guard let rawThreadID = persistedThreadSelection,
              let selectedStoredThread =
                threadDirectoryState.selectedThread?.storedThread,
              threadDirectoryState.selectedThreadID?.rawValue == rawThreadID,
              selectedStoredThread.id.rawValue == rawThreadID,
              threadResumeState.phase == .resumed,
              threadResumeState.selectedThreadID?.rawValue == rawThreadID,
              let resumeResult = threadResumeState.resumeResult,
              resumeResult.thread.id.rawValue == rawThreadID
        else {
            throw CodexConversationError.persistedThreadUnavailable
        }
        guard selectedStoredThread.canAcceptDirectInput != false else {
            throw CodexConversationError.persistedDirectInputUnavailable
        }
        guard let credentials = accountStore.officialCredentials() else {
            accountPresented = true
            throw CodexConversationError.signInRequired
        }
        guard let officialProvider else {
            throw CodexConversationError.providerUnavailable
        }

        let storedThreadID = CodexStoredThreadID(
            rawValue: rawThreadID
        )
        let runtime = CodexResumedThreadRuntimeSettings(
            resumeResult: resumeResult,
            authoritativeSettings: store.threadSettings(
                for: storedThreadID
            )
        )
        guard modelCatalogState.canRunModelOperations else {
            throw CodexConversationError.modelCatalogUnavailable
        }
        let runtimeSelection = modelCatalogState.selection(
            modelID: runtime.model,
            reasoningEffortRaw: runtime.effort
        )
        guard let providerModelID = runtimeSelection.providerModelID,
              let providerEffortRaw =
                runtimeSelection.reasoningEffortRaw,
              let providerReasoningEffort = CodexReasoningEffort(
                rawValue: providerEffortRaw
              )
        else {
            throw CodexConversationError.modelSelectionUnavailable
        }
        let startParams = runtime.makeTurnStartParams(
            threadID: storedThreadID,
            input: [.text(text: text, textElements: [])],
            clientUserMessageID: UUID().uuidString.lowercased(),
            modelOverride: providerModelID
        )

        let workspace = persistedWorkspace(
            matching: runtime.cwd
        )
        let supportsNamespaceTools =
            modelCatalogState.capabilityGate(.namespaceTools)
        let provider = CodexPersistedTurnOfficialProvider(
            configuration:
                CodexPersistedTurnOfficialProviderConfiguration(
                    accessToken: credentials.accessToken,
                    accountID: credentials.accountID,
                    baseURL: credentials.baseURL,
                    model: providerModelID,
                    reasoningEffort: providerReasoningEffort,
                    instructions: Self.persistedTurnInstructions,
                    collaborationInstructions:
                        runtime.collaborationMode?.settings
                            .developerInstructions,
                    workspaceTools:
                        workspace != nil && supportsNamespaceTools,
                    planMode: runtime.proposedPlanStreamingEnabled
                ),
            client: officialProvider
        )
        let toolExecutor = supportsNamespaceTools
            ? workspace.map { workspace in
            CodexPersistedTurnWorkspaceToolExecutor(
                policy: CodexExecutionPolicy(
                    resumedApprovalPolicy:
                        runtime.approvalPolicy,
                    resumedSandboxPolicy: runtime.sandboxPolicy
                ),
                expectedWorkspacePath: runtime.cwd,
                workspace: workspace,
                runner: workspaceToolRunner,
                approval: { activity in
                    await requestToolApproval(
                        name: activity.request.name,
                        arguments: activity.request.arguments
                    )
                }
            )
        } : nil
        let coordinator = CodexPersistedTurnCoordinator(
            history: store,
            provider: provider,
            toolExecutor: toolExecutor
        )

        store.selectResumedTurnThread(storedThreadID)
        let turnSelectionGeneration = store.resumedTurnState.selectionGeneration
        persistedStreamingReply.reset()
        defer {
            if persistedThreadSelection == rawThreadID {
                persistedStreamingReply.reset()
            }
        }

        do {
            let result = try await coordinator.run(
                startRequestID: nextPersistedThreadRequestID(),
                priorRequestID: nextPersistedThreadRequestID(),
                params: startParams,
                cancellation: cancellation,
                onTurnNotification: { notification in
                    store.receiveTurnNotification(
                        notification,
                        selectionGeneration: turnSelectionGeneration
                    )
                },
                onProviderEvent: { event in
                    guard persistedThreadSelection == rawThreadID else {
                        return
                    }
                    if case .assistantTextDelta(
                        _,
                        _,
                        let delta
                    ) = event {
                        persistedStreamingReply.append(delta)
                    }
                }
            )
            guard result.threadID == storedThreadID else {
                throw CodexConversationError.persistedThreadUnavailable
            }
            reconcilePersistedThreadAfterTurn(rawThreadID)
        } catch {
            reconcilePersistedThreadAfterTurn(rawThreadID)
            throw error
        }
    }

    private func reconcilePersistedThreadAfterTurn(
        _ rawThreadID: String
    ) {
        guard persistedThreadSelection == rawThreadID,
              threadDirectoryState.selectedThreadID?.rawValue
                == rawThreadID
        else {
            return
        }
        let request = threadDirectoryState.selectThread(
            CodexStoredThreadID(rawValue: rawThreadID)
        )
        performPersistedThreadRead(request)
        loadInitialPersistedThreads()
    }

    private func persistedWorkspace(
        matching expectedPath: String
    ) -> Workspace? {
        let expectedURL = URL(
            fileURLWithPath: expectedPath,
            isDirectory: true
        )
        let expectedCanonicalPath = Self.canonicalWorkspacePath(
            expectedURL
        )
        return store.state.workspaces.first { workspace in
            guard let bookmark = workspace.rootBookmarkID,
                  let url = try? workspaceAccess.resolve(bookmark)
            else {
                return false
            }
            return Self.canonicalWorkspacePath(url)
                == expectedCanonicalPath
        }
    }

    private static func canonicalWorkspacePath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    private static let persistedTurnInstructions = """
        You are Codex, a coding agent. Be precise and practical. Use the \
        workspace tools to inspect or modify the selected project when the \
        request requires it.
        """

    private func submitTurn(
        _ text: String,
        cancellation: CodexTurnCancellation
    ) async throws {
        guard let threadID = store.selectedThreadID else {
            throw CodexCoreEnvelopeError.invalidCommandPayload
        }
        guard modelCatalogState.canRunModelOperations else {
            throw CodexConversationError.modelCatalogUnavailable
        }
        guard let settings = store.threadSettings(for: threadID) else {
            throw CodexConversationError.modelSelectionUnavailable
        }
        let threadSelection = modelCatalogState.selection(
            modelID: settings.model,
            reasoningEffortRaw: settings.effort?.rawValue
        )
        guard let providerModelID = threadSelection.providerModelID,
              let effortRaw = threadSelection.reasoningEffortRaw,
              let reasoningEffort = CodexReasoningEffort(
                rawValue: effortRaw
              )
        else {
            throw CodexConversationError.modelSelectionUnavailable
        }
        guard let credentials = accountStore.officialCredentials() else {
            accountPresented = true
            throw CodexConversationError.signInRequired
        }
        guard let officialProvider else {
            throw CodexConversationError.providerUnavailable
        }
        let turnID = UUID()
        try store.startTurn(
            id: turnID,
            threadID: threadID,
            itemID: UUID(),
            text: text,
            timestamp: Self.currentUnixTimestamp()
        )
        loadInitialPersistedThreads()
        streamingReply.reset()
        defer {
            streamingReply.reset()
        }
        do {
            try cancellation.checkCancellation()
            var reply = ""
            var inputHistory: [String] = []
            let workspace = selectedWorkspace
            let supportsNamespaceTools =
                modelCatalogState.capabilityGate(.namespaceTools)
            for _ in 0..<8 {
                try cancellation.checkCancellation()
                let request = CodexOfficialResponseRequest(
                    requestID: turnID.uuidString.lowercased(),
                    accessToken: credentials.accessToken,
                    accountID: credentials.accountID,
                    baseURL: credentials.baseURL,
                    model: providerModelID,
                    reasoningEffort: reasoningEffort,
                    instructions: """
                    You are Codex, a coding agent. Be precise and practical. \
                    Use the workspace tools to inspect or modify the selected \
                    project when the request requires it.
                    """,
                    input: [
                        .text(text: text, textElements: [])
                    ],
                    workspaceTools:
                        workspace?.rootBookmarkID != nil
                            && supportsNamespaceTools,
                    planMode: settings.collaborationMode == "plan",
                    inputHistory: inputHistory
                )
                var requestedTool: (
                    name: String,
                    arguments: String,
                    callID: String
                )?
                let events = await officialProvider.stream(
                    request,
                    cancellation: cancellation
                )
                for try await event in events {
                    try cancellation.checkCancellation()
                    switch event {
                    case let .assistantTextDelta(_, _, delta):
                        reply.append(delta)
                        streamingReply.append(delta)
                    case let .toolCallRequested(
                        _,
                        _,
                        name,
                        arguments,
                        callID,
                        itemJSON
                    ):
                        inputHistory.append(itemJSON)
                        requestedTool = (name, arguments, callID)
                    case let .responseItemDone(_, _, itemJSON):
                        inputHistory.append(itemJSON)
                    default:
                        break
                    }
                }
                guard let requestedTool else {
                    try cancellation.checkCancellation()
                    guard !reply.isEmpty else {
                        throw CodexConversationError.emptyResponse
                    }
                    try store.completeTurn(
                        id: turnID,
                        itemID: UUID(),
                        text: reply,
                        timestamp: Self.currentUnixTimestamp()
                    )
                    loadInitialPersistedThreads()
                    return
                }
                guard supportsNamespaceTools else {
                    throw CodexConversationError
                        .providerCapabilityUnavailable
                }
                guard let workspace else {
                    throw CodexWorkspaceToolError.unavailableWorkspace
                }
                try store.appendItem(
                    id: UUID(),
                    turnID: turnID,
                    kind: .toolCall,
                    text: Self.toolActivitySummary(
                        name: requestedTool.name,
                        arguments: requestedTool.arguments
                    )
                )
                let output: String
                try cancellation.checkCancellation()
                switch executionPolicy.decision(for: requestedTool.name) {
                case .allow:
                    output = executeWorkspaceTool(
                        requestedTool,
                        workspace: workspace
                    )
                case .requireApproval:
                    if await requestToolApproval(
                        name: requestedTool.name,
                        arguments: requestedTool.arguments
                    ) {
                        try cancellation.checkCancellation()
                        output = executeWorkspaceTool(
                            requestedTool,
                            workspace: workspace
                        )
                    } else {
                        output = #"{"error":"workspace change denied"}"#
                    }
                case .deny:
                    output = #"{"error":"blocked by sandbox policy"}"#
                }
                try store.appendItem(
                    id: UUID(),
                    turnID: turnID,
                    kind: requestedTool.name == "write_workspace_file"
                        ? .fileChange
                        : requestedTool.name == "search_workspace_text"
                            ? .terminal
                            : .toolResult,
                    text: requestedTool.name == "write_workspace_file"
                        ? Self.jsonString("diff", in: output)
                            ?? Self.toolResultSummary(
                                name: requestedTool.name,
                                output: output
                            )
                        : Self.toolResultSummary(
                            name: requestedTool.name,
                            output: output
                        )
                )
                inputHistory.append(
                    try Self.toolOutputItem(
                        callID: requestedTool.callID,
                        output: output
                    )
                )
            }
            throw CodexConversationError.toolLimitReached
        } catch is CancellationError {
            try? store.cancelTurn(
                id: turnID,
                timestamp: Self.currentUnixTimestamp()
            )
            loadInitialPersistedThreads()
            throw CancellationError()
        } catch {
            try? store.failTurn(
                id: turnID,
                itemID: UUID(),
                message: "Codex request failed.",
                timestamp: Self.currentUnixTimestamp()
            )
            loadInitialPersistedThreads()
            throw error
        }
    }

    private static func currentUnixTimestamp() -> Int64 {
        Int64(Date().timeIntervalSince1970.rounded(.down))
    }

    private func cancelActiveTurn() {
        if pendingToolApproval != nil {
            resolveToolApproval(false)
        }
    }

    private func executeWorkspaceTool(
        _ tool: (name: String, arguments: String, callID: String),
        workspace: Workspace
    ) -> String {
        do {
            return try workspaceToolRunner.execute(
                name: tool.name,
                arguments: tool.arguments,
                workspace: workspace
            )
        } catch {
            return #"{"error":"workspace tool execution failed"}"#
        }
    }

    private func requestToolApproval(
        name: String,
        arguments: String
    ) async -> Bool {
        await withCheckedContinuation { continuation in
            pendingToolApproval = PendingToolApproval(
                summary: Self.toolActivitySummary(
                    name: name,
                    arguments: arguments
                ),
                continuation: continuation
            )
        }
    }

    private func resolveToolApproval(_ approved: Bool) {
        guard let approval = pendingToolApproval else {
            return
        }
        pendingToolApproval = nil
        approval.continuation.resume(returning: approved)
    }

    private static func toolOutputItem(
        callID: String,
        output: String
    ) throws -> String {
        let data = try JSONEncoder().encode(
            ToolOutputItem(
                type: "function_call_output",
                callID: callID,
                output: output
            )
        )
        guard let value = String(data: data, encoding: .utf8) else {
            throw CodexCoreEnvelopeError.invalidCommandPayload
        }
        return value
    }

    private static func toolActivitySummary(
        name: String,
        arguments: String
    ) -> String {
        let path = jsonString("path", in: arguments)
        switch name {
        case "list_workspace_files":
            return "Listing project files"
        case "read_workspace_file":
            return path.map { "Reading \($0)" } ?? "Reading a project file"
        case "search_workspace_text":
            let query = jsonString("query", in: arguments)
            return query.map { "Searching project for “\($0)”" }
                ?? "Searching project text"
        case "write_workspace_file":
            return path.map { "Updating \($0)" } ?? "Updating a project file"
        default:
            return "Running \(name)"
        }
    }

    private static func toolResultSummary(
        name: String,
        output: String
    ) -> String {
        if output.contains(#""error":"#) {
            return "Tool execution reported an error"
        }
        switch name {
        case "list_workspace_files":
            return "Project files listed"
        case "read_workspace_file":
            return "File read"
        case "search_workspace_text":
            return output
        case "write_workspace_file":
            let path = jsonString("path", in: output)
            let bytes = jsonInt("bytesWritten", in: output)
            if let path, let bytes {
                return "Updated \(path) · \(bytes) bytes"
            }
            return "Project file updated"
        default:
            return "Tool completed"
        }
    }

    private static func jsonString(
        _ key: String,
        in json: String
    ) -> String? {
        guard let object = try? JSONSerialization.jsonObject(
            with: Data(json.utf8)
        ) as? [String: Any] else {
            return nil
        }
        return object[key] as? String
    }

    private static func jsonInt(
        _ key: String,
        in json: String
    ) -> Int? {
        guard let object = try? JSONSerialization.jsonObject(
            with: Data(json.utf8)
        ) as? [String: Any] else {
            return nil
        }
        return object[key] as? Int
    }
}

private struct PersistedThreadSettingsDraft: Equatable {
    let threadID: CodexStoredThreadID
    let cwd: String
    let modelID: String
    let reasoningEffortRaw: String
    let approvalPolicyRaw: String
    let sandboxModeRaw: String
}

@MainActor
private final class PendingToolApproval: Identifiable {
    let id = UUID()
    let summary: String
    let continuation: CheckedContinuation<Bool, Never>

    init(
        summary: String,
        continuation: CheckedContinuation<Bool, Never>
    ) {
        self.summary = summary
        self.continuation = continuation
    }
}

private struct ToolOutputItem: Encodable {
    let type: String
    let callID: String
    let output: String

    private enum CodingKeys: String, CodingKey {
        case type
        case callID = "call_id"
        case output
    }
}

private enum CodexModelCatalogConfigurationError: LocalizedError {
    case cacheDirectoryUnavailable

    var errorDescription: String? {
        "The model catalog cache directory is unavailable."
    }
}

private enum CodexConversationError: LocalizedError {
    case signInRequired
    case providerUnavailable
    case emptyResponse
    case toolLimitReached
    case modelCatalogUnavailable
    case modelSelectionUnavailable
    case providerCapabilityUnavailable
    case persistedThreadUnavailable
    case persistedDirectInputUnavailable

    var errorDescription: String? {
        switch self {
        case .signInRequired:
            "Sign in with ChatGPT before sending a message."
        case .providerUnavailable:
            "The official Codex provider is not available in this build."
        case .emptyResponse:
            "Codex completed without returning assistant text."
        case .toolLimitReached:
            "Codex exceeded the workspace tool-call limit."
        case .modelCatalogUnavailable:
            "The current server model catalog is not ready."
        case .modelSelectionUnavailable:
            "This task's model or reasoning effort is not available in the current server catalog."
        case .providerCapabilityUnavailable:
            "The current model provider does not support workspace tools."
        case .persistedThreadUnavailable:
            "Reload and resume this saved task before sending a message."
        case .persistedDirectInputUnavailable:
            "This saved task is read-only."
        }
    }
}

private struct NameEntrySheet: View {
    let title: String
    let fieldLabel: String
    @Binding var value: String
    let onCancel: () -> Void
    let onSubmit: () -> Void

    private var trimmedValue: String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField(fieldLabel, text: $value)
                    .textInputAutocapitalization(.sentences)
                    .submitLabel(.done)
                    .onSubmit(onSubmit)
            }
            .navigationTitle(title)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create", action: onSubmit)
                        .disabled(trimmedValue.isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
    }
}
