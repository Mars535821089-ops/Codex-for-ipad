import SwiftUI
import UniformTypeIdentifiers

/// Route identifier for the 10 desktop surfaces from
/// `versions/26.730.61309/desktop-ui-parity.json`. Each surface is a peer of
/// the main shell so users can jump between the same regions that desktop
/// Codex exposes.
enum CodexSurfaceRoute: String, CaseIterable, Identifiable, Hashable {
    case launchAndSignIn
    case mainShell
    case homeProjects
    case conversationWorkspace
    case taskPanels
    case reviewDiff
    case terminal
    case settingsShortcuts
    case secondaryProducts
    case globalOverlays

    var id: String { rawValue }

    var surfaceID: String {
        switch self {
        case .launchAndSignIn:        return "S01"
        case .mainShell:              return "S02"
        case .homeProjects:           return "S03"
        case .conversationWorkspace:  return "S04"
        case .taskPanels:             return "S05"
        case .reviewDiff:             return "S06"
        case .terminal:               return "S07"
        case .settingsShortcuts:      return "S08"
        case .secondaryProducts:      return "S09"
        case .globalOverlays:         return "S10"
        }
    }

    var displayName: String {
        switch self {
        case .launchAndSignIn:        return "Launch & Sign in"
        case .mainShell:              return "Main shell"
        case .homeProjects:           return "Home & Projects"
        case .conversationWorkspace:  return "Conversation workspace"
        case .taskPanels:             return "Task panels"
        case .reviewDiff:             return "Review & Diff"
        case .terminal:               return "Terminal"
        case .settingsShortcuts:      return "Settings & Shortcuts"
        case .secondaryProducts:      return "Automations, PRs, Plugins"
        case .globalOverlays:         return "Overlays & iPad layout"
        }
    }

    var systemImage: String {
        switch self {
        case .launchAndSignIn:        return "person.crop.circle.badge.questionmark"
        case .mainShell:              return "rectangle.split.2x1"
        case .homeProjects:           return "house"
        case .conversationWorkspace:  return "bubble.left.and.bubble.right"
        case .taskPanels:             return "rectangle.split.3x1"
        case .reviewDiff:             return "doc.on.doc"
        case .terminal:               return "terminal"
        case .settingsShortcuts:      return "gearshape.2"
        case .secondaryProducts:      return "puzzlepiece.extension"
        case .globalOverlays:         return "rectangle.3.group"
        }
    }
}

/// Single entry-point picker that lets users jump to any of the 10 desktop
/// surfaces. Mirrors the desktop command palette's surface list.
struct CodexSurfacePicker: View {
    @Binding var selection: CodexSurfaceRoute

    var body: some View {
        List {
            ForEach(CodexSurfaceRoute.allCases) { route in
                Button {
                    selection = route
                } label: {
                    HStack {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(route.displayName)
                                    .font(.body.weight(.medium))
                                Text("Surface \(route.surfaceID)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: route.systemImage)
                                .foregroundStyle(CodexTheme.accent)
                        }
                        Spacer()
                        if selection == route {
                            Image(systemName: "checkmark")
                                .foregroundStyle(CodexTheme.accent)
                        }
                    }
                }
                .buttonStyle(.plain)
                .tag(route)
            }
        }
        .navigationTitle("Surfaces")
        .accessibilityIdentifier("codex.surface.picker")
    }
}

/// Common header used across the 10 surface views.
struct CodexSurfaceHeader: View {
    let route: CodexSurfaceRoute
    let states: [String]
    let routes: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: route.systemImage)
                    .font(.title2)
                    .foregroundStyle(CodexTheme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(route.displayName)
                        .font(.title2.weight(.semibold))
                    Text("Surface \(route.surfaceID)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            if !routes.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Routes")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(routes, id: \.self) { route in
                        Text(route)
                            .font(.caption.monospaced())
                            .foregroundStyle(.primary)
                    }
                }
            }
            if !states.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Required states")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    FlowChips(items: states)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(CodexTheme.raisedSurface)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

struct FlowChips: View {
    let items: [String]

    var body: some View {
        let columns = [GridItem(.adaptive(minimum: 110), spacing: 6)]
        LazyVGrid(columns: columns, alignment: .leading, spacing: 6) {
            ForEach(items, id: \.self) { item in
                Text(item)
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(CodexTheme.canvas)
                    .overlay(
                        Capsule().stroke(CodexTheme.border, lineWidth: 0.5)
                    )
                    .clipShape(Capsule())
            }
        }
    }
}

// MARK: - S01 Launch, sign in, and first run

struct CodexSurfaceLaunchSignInView: View {
    @Bindable var store: CodexSessionStore
    @Bindable var accountStore: CodexAccountStore
    @State private var apiKeyExpanded = false
    @State private var apiKeyDraft = ""
    @State private var apiKeySaveProblem: String?
    @State private var projectSelection = ""
    @State private var projectPickerPresented = false
    @State private var projectSelectionProblem: String?
    private let workspaceAccess = CodexWorkspaceAccess()

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                CodexSurfaceHeader(
                    route: .launchAndSignIn,
                    states: [
                        "launch", "signed-out", "device-code",
                        "api-key-expanded", "project-selection",
                        "first-run", "error"
                    ],
                    routes: [
                        "/login", "/welcome", "/select-workspace",
                        "/first-run", "/codex-access"
                    ]
                )

                CodexAccountView(accountStore: accountStore)

                DisclosureGroup(
                    isExpanded: $apiKeyExpanded,
                    content: {
                        Text("Use an OpenAI API key when ChatGPT sign-in is unavailable.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        SecureField("sk-…", text: $apiKeyDraft)
                            .textFieldStyle(.roundedBorder)
                            .textContentType(.password)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .accessibilityIdentifier("codex.s01.apiKey")
                        Button("Save API key") {
                            do {
                                try accountStore.acceptAPIKey(apiKeyDraft)
                                apiKeyDraft = ""
                                apiKeySaveProblem = nil
                                apiKeyExpanded = false
                            } catch {
                                apiKeySaveProblem =
                                    accountStore.problem
                                    ?? "API key could not be saved."
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(
                            apiKeyDraft.trimmingCharacters(
                                in: .whitespacesAndNewlines
                            ).isEmpty
                        )
                        .accessibilityIdentifier("codex.s01.saveAPIKey")
                        if let apiKeySaveProblem {
                            Text(apiKeySaveProblem)
                                .font(.caption)
                                .foregroundStyle(.red)
                                .accessibilityIdentifier(
                                    "codex.s01.apiKeyError"
                                )
                        }
                    },
                    label: {
                        Label("Use an API key", systemImage: "key")
                    }
                )
                .padding(.horizontal, 16)

                Group {
                    Text("Project selection")
                        .font(.headline)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    TextField("Path to a project folder", text: $projectSelection)
                        .textFieldStyle(.roundedBorder)
                    Button {
                        projectPickerPresented = true
                    } label: {
                        Label(
                            projectSelection.isEmpty
                                ? "Choose project…"
                                : "Change project…",
                            systemImage: "folder"
                        )
                    }
                    .accessibilityIdentifier("codex.s01.chooseProject")
                    if let projectSelectionProblem {
                        Text(projectSelectionProblem)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .accessibilityIdentifier(
                                "codex.s01.projectError"
                            )
                    }
                }
                .padding(.horizontal, 16)
            }
            .padding(.vertical, 16)
        }
        .background(CodexTheme.canvas)
        .navigationTitle("Launch & Sign in")
        .accessibilityIdentifier("codex.surface.S01")
        .fileImporter(
            isPresented: $projectPickerPresented,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false,
            onCompletion: openProject
        )
    }

    private func openProject(_ result: Result<[URL], any Error>) {
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
            projectSelection = url.path
            projectSelectionProblem = nil
        } catch {
            projectSelectionProblem =
                "The selected folder could not be opened."
        }
    }
}

// MARK: - S02 Main shell, sidebar, and top navigation

struct CodexSurfaceMainShellView: View {
    @Bindable var store: CodexSessionStore
    @State private var sidebarCollapsed = false
    @State private var filter: ShellFilter = .all

    enum ShellFilter: String, CaseIterable, Identifiable {
        case all, chat, work
        var id: String { rawValue }
        var label: String { rawValue.capitalized }
    }

    var body: some View {
        VStack(spacing: 0) {
            CodexSurfaceHeader(
                route: .mainShell,
                states: [
                    "sidebar-expanded", "sidebar-collapsed",
                    "filter-all", "filter-chat", "filter-work",
                    "pinned", "unread", "loading"
                ],
                routes: ["/", "/global/search"]
            )

            HStack(spacing: 0) {
                VStack(spacing: 12) {
                    Image(systemName: sidebarCollapsed ? "sidebar.right" : "sidebar.left")
                        .imageScale(.large)
                    Divider()
                    Image(systemName: "house")
                    Image(systemName: "bubble.left.and.bubble.right")
                    Image(systemName: "folder")
                    Image(systemName: "person.crop.circle")
                }
                .frame(width: sidebarCollapsed ? 56 : 220)
                .padding(.vertical, 14)
                .background(CodexTheme.sidebar)

                Divider()

                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Picker("Filter", selection: $filter) {
                            ForEach(ShellFilter.allCases) { f in
                                Text(f.label).tag(f)
                            }
                        }
                        .pickerStyle(.segmented)
                        Spacer()
                        Toggle("Collapsed", isOn: $sidebarCollapsed)
                            .toggleStyle(.switch)
                            .labelsHidden()
                    }
                    .padding(.horizontal, 16)

                    if store.state.threads.isEmpty {
                        ContentUnavailableView(
                            "No conversations yet",
                            systemImage: "bubble.left",
                            description: Text("Start a new thread to populate the shell.")
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        List(store.state.threads) { thread in
                            Label(thread.title, systemImage: "text.bubble")
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(CodexTheme.canvas)
        .navigationTitle("Main shell")
        .accessibilityIdentifier("codex.surface.S02")
    }
}

// MARK: - S03 Home, new task, and projects

struct CodexSurfaceHomeProjectsView: View {
    @Bindable var store: CodexSessionStore
    @State private var searchText = ""
    @State private var newTaskTitle = ""
    @State private var temporaryChat = false
    @State private var homeMode: HomeMode = .chat

    enum HomeMode: String, CaseIterable, Identifiable {
        case chat, codex, work
        var id: String { rawValue }
        var label: String {
            switch self {
            case .chat: return "Home"
            case .codex: return "Codex"
            case .work: return "Work"
            }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                CodexSurfaceHeader(
                    route: .homeProjects,
                    states: [
                        "home-chat", "home-codex", "home-work",
                        "temporary-chat", "projects-empty",
                        "projects-populated", "projects-search"
                    ],
                    routes: ["/", "/projects", "/extension/panel/new"]
                )

                Picker("Home", selection: $homeMode) {
                    ForEach(HomeMode.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)

                HStack {
                    TextField("Start a new task…", text: $newTaskTitle)
                        .textFieldStyle(.roundedBorder)
                    Toggle("Temporary", isOn: $temporaryChat)
                }

                if store.state.workspaces.isEmpty {
                    ContentUnavailableView(
                        "No projects",
                        systemImage: "folder",
                        description: Text("Use ‘Add project’ in the sidebar to create one.")
                    )
                    .frame(maxHeight: 220)
                } else {
                    TextField("Search projects", text: $searchText)
                        .textFieldStyle(.roundedBorder)
                    ForEach(store.state.workspaces) { workspace in
                        VStack(alignment: .leading) {
                            Label(workspace.displayName, systemImage: "folder.fill")
                                .font(.headline)
                            Text("Workspace ID: \(workspace.id.uuidString.prefix(8))")
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(CodexTheme.raisedSurface)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                }
            }
            .padding(16)
        }
        .background(CodexTheme.canvas)
        .navigationTitle("Home & Projects")
        .accessibilityIdentifier("codex.surface.S03")
    }
}

// MARK: - S04 Conversation and task workspace

struct CodexSurfaceConversationWorkspaceView: View {
    let threadTitle: String
    @State private var composerText = ""
    @State private var streaming = false
    @State private var working = false
    @State private var queued = false
    @State private var reconnecting = false
    @State private var error: String?
    @State private var approval: String?
    @State private var subagentsActive: [String] = []
    @State private var subagentsDone: [String] = []

    var body: some View {
        VStack(spacing: 12) {
            CodexSurfaceHeader(
                route: .conversationWorkspace,
                states: [
                    "empty-composer", "streaming", "working",
                    "queued", "steered", "approval",
                    "subagents-active", "subagents-done",
                    "reconnecting", "error"
                ],
                routes: [
                    "/local/:conversationId",
                    "/work/conversation/:conversationId",
                    "/remote/:taskId",
                    "/chatgpt/quick-chat/:conversationId",
                    "/hotkey-window/*"
                ]
            )

            HStack {
                Toggle("Streaming", isOn: $streaming)
                Toggle("Working", isOn: $working)
                Toggle("Queued", isOn: $queued)
                Toggle("Reconnecting", isOn: $reconnecting)
            }
            .padding(.horizontal, 16)

            if !subagentsActive.isEmpty {
                Label("\(subagentsActive.count) subagents running", systemImage: "person.2")
                    .padding(.horizontal, 16)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    Text(threadTitle)
                        .font(.title3.weight(.semibold))
                    Text("This surface mirrors desktop Codex's conversation workspace: composer, queued messages, streamed replies, tool approvals, and subagent activity.")
                        .foregroundStyle(.secondary)
                    if let approval {
                        Label(approval, systemImage: "checkmark.shield")
                            .padding(10)
                            .background(CodexTheme.raisedSurface)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    if let error {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }
                .padding(16)
            }

            HStack {
                TextField("Ask Codex anything", text: $composerText, axis: .vertical)
                    .lineLimit(1...5)
                    .textFieldStyle(.roundedBorder)
                Button(action: {}) {
                    Image(systemName: "paperplane.fill")
                }
                .disabled(composerText.isEmpty)
            }
            .padding(16)
        }
        .background(CodexTheme.canvas)
        .navigationTitle("Conversation workspace")
        .accessibilityIdentifier("codex.surface.S04")
    }
}

// MARK: - S05 Files, Side chat, Browser, Review, Detail, and Terminal panels

struct CodexSurfaceTaskPanelsView: View {
    enum Panel: String, CaseIterable, Identifiable {
        case files, sideChat, browser, review, detail, terminalBottom, terminalRight
        var id: String { rawValue }
        var label: String {
            switch self {
            case .files:           return "Files"
            case .sideChat:        return "Side chat"
            case .browser:         return "Browser"
            case .review:          return "Review"
            case .detail:          return "Detail"
            case .terminalBottom:  return "Terminal (bottom)"
            case .terminalRight:   return "Terminal (right)"
            }
        }
        var icon: String {
            switch self {
            case .files:           return "folder"
            case .sideChat:        return "bubble.left.and.bubble.right"
            case .browser:         return "safari"
            case .review:          return "doc.text.magnifyingglass"
            case .detail:          return "info.circle"
            case .terminalBottom:  return "terminal"
            case .terminalRight:   return "terminal.fill"
            }
        }
    }
    @State private var panel: Panel = .files
    @State private var terminalCollapsed = false
    @State private var width: CGFloat = 320

    var body: some View {
        VStack(spacing: 12) {
            CodexSurfaceHeader(
                route: .taskPanels,
                states: [
                    "files", "side-chat", "browser",
                    "review", "detail",
                    "terminal-bottom", "terminal-right",
                    "panel-resize", "panel-collapsed"
                ],
                routes: ["/local/:conversationId"]
            )

            Picker("Panel", selection: $panel) {
                ForEach(Panel.allCases) { p in
                    Label(p.label, systemImage: p.icon).tag(p)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)

            HStack(spacing: 0) {
                panelContent
                    .frame(width: width)
                    .background(CodexTheme.canvas)
                Divider()
                if !terminalCollapsed {
                    VStack(alignment: .leading) {
                        Label("Terminal", systemImage: "terminal")
                            .font(.headline)
                        ScrollView {
                            Text("$ echo panel terminal")
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .background(CodexTheme.raisedSurface)
                }
            }
            .frame(maxHeight: .infinity)

            HStack {
                Button("Collapse terminal") { terminalCollapsed.toggle() }
                Spacer()
                Slider(value: $width, in: 200...600)
                    .frame(width: 200)
            }
            .padding(.horizontal, 16)
        }
        .background(CodexTheme.canvas)
        .navigationTitle("Task panels")
        .accessibilityIdentifier("codex.surface.S05")
    }

    @ViewBuilder
    private var panelContent: some View {
        switch panel {
        case .files:
            VStack(alignment: .leading) {
                Label("Files", systemImage: "folder")
                    .font(.headline)
                List(["src/", "tests/", "README.md"], id: \.self) { Text($0) }
            }
            .padding(12)
        case .sideChat:
            VStack(alignment: .leading) {
                Label("Side chat", systemImage: "bubble.left.and.bubble.right")
                    .font(.headline)
                Text("Drop a side conversation here without leaving the active task.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(12)
        case .browser:
            VStack(alignment: .leading) {
                Label("Browser", systemImage: "safari")
                    .font(.headline)
                Text("Embedded browser pane is wired through CodexDesktopBrowserAppHostService.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(12)
        case .review:
            VStack(alignment: .leading) {
                Label("Review", systemImage: "doc.text.magnifyingglass")
                    .font(.headline)
                Text("Inline review queue (matches desktop Review panel).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(12)
        case .detail:
            VStack(alignment: .leading) {
                Label("Detail", systemImage: "info.circle")
                    .font(.headline)
                Text("Tool, turn, and message metadata.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(12)
        case .terminalBottom, .terminalRight:
            EmptyView()
        }
    }
}

// MARK: - S06 Review and diff

struct CodexSurfaceReviewDiffView: View {
    let actionBridge: CodexNativeSurfaceActionBridge?
    let cwd: String?
    @State private var mode: DiffMode = .unified
    @State private var lastTurn = true
    @State private var hasComments = false
    @State private var operationProblem: String?
    @State private var operationResult: String?

    enum DiffMode: String, CaseIterable, Identifiable {
        case unified, split
        var id: String { rawValue }
        var label: String { rawValue.capitalized }
    }

    var body: some View {
        VStack(spacing: 12) {
            CodexSurfaceHeader(
                route: .reviewDiff,
                states: [
                    "unified", "split", "staged", "unstaged",
                    "last-turn", "comments", "conflict",
                    "revert-confirmation", "commit", "empty", "error"
                ],
                routes: ["/diff"]
            )

            Picker("Mode", selection: $mode) {
                ForEach(DiffMode.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)

            HStack {
                Toggle("Last turn", isOn: $lastTurn)
                Toggle("Comments", isOn: $hasComments)
            }
            .padding(.horizontal, 16)

            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    diffRow("@@ -12,3 +12,4 @@", color: .secondary)
                    diffRow("-    old line", color: CodexTheme.deleted)
                    diffRow("+    new line", color: CodexTheme.added)
                    diffRow("+    additional line", color: CodexTheme.added)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(CodexTheme.raisedSurface)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .padding(.horizontal, 16)

            HStack {
                Button("Revert", role: .destructive) {
                    runReviewAction {
                        guard let actionBridge, let cwd else {
                            throw NativeSurfaceActionError.unavailable
                        }
                        return try await actionBridge.revert(cwd)
                    }
                }
                Button("Commit") {
                    runReviewAction {
                        guard let actionBridge, let cwd else {
                            throw NativeSurfaceActionError.unavailable
                        }
                        return try await actionBridge.commit(
                            cwd,
                            "Commit reviewed changes"
                        )
                    }
                }
                Spacer()
            }
            .padding(16)
            if let operationProblem {
                Text(operationProblem)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 16)
            }
            if let operationResult {
                Text(operationResult)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
            }
        }
        .background(CodexTheme.canvas)
        .navigationTitle("Review & Diff")
        .accessibilityIdentifier("codex.surface.S06")
    }

    private func diffRow(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(.body, design: .monospaced))
            .foregroundStyle(color)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func runReviewAction(
        _ operation: @escaping @Sendable () async throws -> CodexJSONValue
    ) {
        operationProblem = nil
        operationResult = nil
        Task {
            do {
                let result = try await operation()
                operationResult = String(describing: result)
            } catch {
                operationProblem = String(describing: error)
            }
        }
    }
}

// MARK: - S07 Terminal

struct CodexSurfaceTerminalView: View {
    let actionBridge: CodexNativeSurfaceActionBridge?
    let cwd: String?
    @State private var input = ""
    @State private var exited = false
    @State private var reconnecting = false
    @State private var resized = false
    @State private var workspaceMismatch = false
    @State private var operationProblem: String?

    var body: some View {
        VStack(spacing: 12) {
            CodexSurfaceHeader(
                route: .terminal,
                states: [
                    "created", "input", "output",
                    "resized", "reconnecting", "exited",
                    "workspace-mismatch"
                ],
                routes: ["/local/:conversationId"]
            )

            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    Text("$ pwd")
                        .foregroundStyle(.secondary)
                    Text("/Users/you/projects/Codex-持续更新逆向Ipad版")
                    Text("$ ls -1")
                    Text("CodexPad")
                    Text("CodexCore")
                    Text("scripts")
                    Text("tests")
                    if exited {
                        Text("Process exited with code 0")
                            .foregroundStyle(.secondary)
                    }
                    if reconnecting {
                        Text("Reconnecting…")
                            .foregroundStyle(.orange)
                    }
                    if workspaceMismatch {
                        Text("Workspace mismatch — restore from /Users/mars")
                            .foregroundStyle(.red)
                    }
                }
                .font(.system(.body, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
            }
            .background(CodexTheme.raisedSurface)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .padding(.horizontal, 16)

            HStack {
                Toggle("Resized", isOn: $resized)
                Toggle("Exited", isOn: $exited)
                Toggle("Reconnecting", isOn: $reconnecting)
                Toggle("Mismatch", isOn: $workspaceMismatch)
            }
            .padding(.horizontal, 16)

            HStack {
                Text("$").foregroundStyle(.secondary)
                TextField("run a command", text: $input)
                    .textFieldStyle(.plain)
                Button("Send") {
                    let command = input
                    input = ""
                    operationProblem = nil
                    Task {
                        do {
                            guard let actionBridge, let cwd else {
                                throw NativeSurfaceActionError.unavailable
                            }
                            let result = try await actionBridge.terminal(
                                cwd,
                                command
                            )
                            operationProblem = String(describing: result)
                        } catch {
                            operationProblem = String(describing: error)
                        }
                    }
                }
                    .disabled(input.isEmpty)
            }
            .padding(12)
            .background(CodexTheme.raisedSurface)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .padding(16)
            if let operationProblem {
                Text(operationProblem)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
            }
        }
        .background(CodexTheme.canvas)
        .navigationTitle("Terminal")
        .accessibilityIdentifier("codex.surface.S07")
    }
}

private enum NativeSurfaceActionError: LocalizedError {
    case unavailable

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "The selected workspace or native backend is unavailable."
        }
    }
}

// MARK: - S08 Settings and keyboard shortcuts

struct CodexSurfaceSettingsShortcutsView: View {
    @Bindable var accountStore: CodexAccountStore
    @State private var query = ""
    @State private var section: SettingsSection = .personal
    @State private var archivedOnly = false
    @State private var readOnly = false
    @State private var shortcutConflict = false

    enum SettingsSection: String, CaseIterable, Identifiable {
        case personal, integrations, coding, archived, managed
        var id: String { rawValue }
        var label: String {
            switch self {
            case .personal:     return "Personal"
            case .integrations: return "Integrations"
            case .coding:       return "Coding"
            case .archived:     return "Archived"
            case .managed:      return "Managed"
            }
        }
        var icon: String {
            switch self {
            case .personal:     return "person"
            case .integrations: return "link"
            case .coding:       return "chevron.left.forwardslash.chevron.right"
            case .archived:     return "archivebox"
            case .managed:      return "building.2"
            }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                CodexSurfaceHeader(
                    route: .settingsShortcuts,
                    states: [
                        "search", "search-empty",
                        "personal", "integrations", "coding",
                        "archived", "managed", "read-only",
                        "shortcut-conflict", "shortcut-override"
                    ],
                    routes: [
                        "/settings",
                        "/settings/general-settings",
                        "/settings/profile",
                        "/settings/appearance",
                        "/settings/git-settings",
                        "/settings/connections",
                        "/settings/agent",
                        "/settings/keyboard-shortcuts",
                        "/settings/usage",
                        "/settings/browser-use",
                        "/settings/computer-use",
                        "/settings/plugins-settings",
                        "/settings/data-controls"
                    ]
                )

                TextField("Search settings", text: $query)
                    .textFieldStyle(.roundedBorder)

                Picker("Section", selection: $section) {
                    ForEach(SettingsSection.allCases) { s in
                        Label(s.label, systemImage: s.icon).tag(s)
                    }
                }
                .pickerStyle(.segmented)

                HStack {
                    Toggle("Archived", isOn: $archivedOnly)
                    Toggle("Read only", isOn: $readOnly)
                    Toggle("Shortcut conflict", isOn: $shortcutConflict)
                }

                CodexAccountView(accountStore: accountStore)

                Group {
                    Text("Keyboard shortcuts")
                        .font(.headline)
                    ForEach(Self.shortcutRows, id: \.command) { row in
                        HStack {
                            Text(row.command)
                            Spacer()
                            Text(row.keys)
                                .font(.caption.monospaced())
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(CodexTheme.canvas)
                                .overlay(Capsule().stroke(CodexTheme.border, lineWidth: 0.5))
                                .clipShape(Capsule())
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
            .padding(16)
        }
        .background(CodexTheme.canvas)
        .navigationTitle("Settings & Shortcuts")
        .accessibilityIdentifier("codex.surface.S08")
    }

    private struct ShortcutRow {
        let command: String
        let keys: String
    }

    private static let shortcutRows: [ShortcutRow] = [
        .init(command: "New Chat", keys: "⌘N"),
        .init(command: "Command Menu", keys: "⌘K"),
        .init(command: "Search Files", keys: "⌘P"),
        .init(command: "Settings", keys: "⌘,"),
        .init(command: "Keyboard Shortcuts", keys: "⌘/"),
        .init(command: "Sidebar", keys: "⌘B"),
        .init(command: "Bottom Panel", keys: "⌘J"),
        .init(command: "Terminal", keys: "Ctrl+`"),
        .init(command: "Browser", keys: "⌘T"),
        .init(command: "Review", keys: "Ctrl+Shift+G"),
        .init(command: "Side Chat", keys: "⌘⌥S")
    ]
}

// MARK: - S09 Automations, PRs, security, library, sites, plugins, skills

struct CodexSurfaceSecondaryProductsView: View {
    enum Product: String, CaseIterable, Identifiable {
        case automations, pullRequests, security, library, sites, plugins, skills
        var id: String { rawValue }
        var label: String {
            switch self {
            case .automations:  return "Automations"
            case .pullRequests: return "Pull requests"
            case .security:     return "Security"
            case .library:      return "Library"
            case .sites:        return "Sites"
            case .plugins:      return "Plugins"
            case .skills:       return "Skills"
            }
        }
        var icon: String {
            switch self {
            case .automations:  return "alarm"
            case .pullRequests: return "arrow.triangle.branch"
            case .security:     return "lock.shield"
            case .library:      return "books.vertical"
            case .sites:        return "globe"
            case .plugins:      return "puzzlepiece"
            case .skills:       return "sparkles"
            }
        }
    }
    @State private var product: Product = .automations
    @State private var empty = false

    var body: some View {
        VStack(spacing: 12) {
            CodexSurfaceHeader(
                route: .secondaryProducts,
                states: ["loading", "empty", "populated", "error"],
                routes: [
                    "/automations", "/pull-requests", "/security",
                    "/library", "/sites", "/plugins", "/skills",
                    "/mcp-app/:server/:toolName",
                    "/codex-mobile", "/remote-connections",
                    "/connector/oauth_callback"
                ]
            )

            Picker("Product", selection: $product) {
                ForEach(Product.allCases) { p in
                    Label(p.label, systemImage: p.icon).tag(p)
                }
            }
            .pickerStyle(.menu)

            Toggle("Empty state", isOn: $empty)
                .padding(.horizontal, 16)

            if empty {
                ContentUnavailableView(
                    "No \(product.label.lowercased()) yet",
                    systemImage: product.icon,
                    description: Text("Connect an account or create your first \(product.label.lowercased()).")
                )
                .frame(maxHeight: 240)
            } else {
                List(0..<6, id: \.self) { idx in
                    Label("\(product.label) #\(idx + 1)", systemImage: product.icon)
                }
            }
        }
        .background(CodexTheme.canvas)
        .navigationTitle("Automations & Plugins")
        .accessibilityIdentifier("codex.surface.S09")
    }
}

// MARK: - S10 Global overlays, transient states, shortcuts, iPad layout

struct CodexSurfaceGlobalOverlaysView: View {
    @State private var showCommandPalette = false
    @State private var showFileSearch = false
    @State private var showDialog = false
    @State private var showToast = false
    @State private var layout: LayoutMode = .portrait
    @State private var dragActive = false
    @State private var resizeActive = false
    @State private var hoverActive = false
    @State private var focusActive = false
    @State private var pressedActive = false
    @State private var disabledActive = false

    enum LayoutMode: String, CaseIterable, Identifiable {
        case portrait, landscape, stageManager
        var id: String { rawValue }
        var label: String { rawValue.replacingOccurrences(of: "-", with: " ").capitalized }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                CodexSurfaceHeader(
                    route: .globalOverlays,
                    states: [
                        "command-palette", "file-search", "context-menu",
                        "tooltip", "dropdown", "dialog", "toast",
                        "hover", "focus", "pressed", "disabled",
                        "drag", "resize",
                        "portrait", "landscape", "stage-manager"
                    ],
                    routes: ["*"]
                )

                Picker("Layout", selection: $layout) {
                    ForEach(LayoutMode.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 8)], spacing: 8) {
                    overlayTile("Command palette", icon: "command") {
                        showCommandPalette = true
                    }
                    overlayTile("File search", icon: "doc.text.magnifyingglass") {
                        showFileSearch = true
                    }
                    overlayTile("Context menu", icon: "contextualmenu.and.cursorarrow") {}
                    overlayTile("Dialog", icon: "rectangle.dashed") {
                        showDialog = true
                    }
                    overlayTile("Toast", icon: "bell.badge") {
                        showToast = true
                    }
                    overlayTile("Hover", icon: "hand.point.up.left") {
                        hoverActive = true
                    }
                    overlayTile("Focus", icon: "circle.dashed") {
                        focusActive = true
                    }
                    overlayTile("Pressed", icon: "rectangle.compress.vertical") {
                        pressedActive = true
                    }
                    overlayTile("Disabled", icon: "nosign") {
                        disabledActive = true
                    }
                    overlayTile("Drag", icon: "arrow.up.and.down.and.arrow.left.and.right") {
                        dragActive = true
                    }
                    overlayTile("Resize", icon: "arrow.up.left.and.arrow.down.right") {
                        resizeActive = true
                    }
                }

                Group {
                    Toggle("Hover", isOn: $hoverActive)
                    Toggle("Focus", isOn: $focusActive)
                    Toggle("Pressed", isOn: $pressedActive)
                    Toggle("Disabled", isOn: $disabledActive)
                    Toggle("Drag", isOn: $dragActive)
                    Toggle("Resize", isOn: $resizeActive)
                }
                .padding(.horizontal, 16)
            }
            .padding(16)
        }
        .background(CodexTheme.canvas)
        .navigationTitle("Overlays & iPad layout")
        .accessibilityIdentifier("codex.surface.S10")
        .sheet(isPresented: $showCommandPalette) { commandPaletteSheet }
        .sheet(isPresented: $showFileSearch)   { fileSearchSheet }
        .confirmationDialog("Sample dialog", isPresented: $showDialog) {
            Button("Confirm", role: .destructive) {}
            Button("Cancel", role: .cancel) {}
        }
        .overlay(alignment: .top) {
            if showToast {
                Text("Saved")
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.thickMaterial)
                    .clipShape(Capsule())
                    .padding(.top, 18)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .task {
                        try? await Task.sleep(for: .seconds(1.5))
                        showToast = false
                    }
            }
        }
    }

    @ViewBuilder
    private func overlayTile(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
                .padding(12)
                .background(CodexTheme.raisedSurface)
                .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }

    private var commandPaletteSheet: some View {
        NavigationStack {
            List(CodexSurfaceRoute.allCases) { route in
                Label(route.displayName, systemImage: route.systemImage)
            }
            .navigationTitle("Command palette")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { showCommandPalette = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var fileSearchSheet: some View {
        NavigationStack {
            List(["README.md", "CodexSurfaces.swift", "CodexRootView.swift"], id: \.self) { file in
                Label(file, systemImage: "doc.text")
            }
            .navigationTitle("Search files")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { showFileSearch = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
