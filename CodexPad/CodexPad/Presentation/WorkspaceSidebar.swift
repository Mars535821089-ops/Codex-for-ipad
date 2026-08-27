import SwiftUI

struct WorkspaceSidebar: View {
    let workspaces: [Workspace]
    let threads: [CodexThread]
    let archivedThreadIDs: Set<UUID>
    let goalThreadIDs: Set<UUID>
    let threadDirectoryState: CodexThreadDirectoryViewState
    @Binding var workspaceSelection: UUID?
    @Binding var threadSelection: UUID?
    @Binding var persistedThreadSearchText: String
    let persistedThreadSelection: String?
    let onPersistedArchiveScopeChange:
        (CodexThreadDirectoryArchiveScope) -> Void
    let onSelectPersistedThread: (String) -> Void
    let onLoadMorePersistedThreads: () -> Void
    let onRetryPersistedThreads: () -> Void
    let onActivateLiveSelection: () -> Void
    let onCreateWorkspace: () -> Void
    let onCreateThread: () -> Void
    let onRenameThread: (CodexThread) -> Void
    let onForkThread: (CodexThread) -> Void
    let onEditThreadGoal: (CodexThread) -> Void
    let onClearThreadGoal: (CodexThread) -> Void
    let onArchiveThread: (CodexThread) -> Void
    let onUnarchiveThread: (CodexThread) -> Void
    let onDeleteThread: (CodexThread) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Codex")
                    .font(.title2.weight(.semibold))
                Spacer()
                Image(systemName: "sidebar.left")
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 10)

            Button(action: onCreateThread) {
                Label("New thread", systemImage: "square.and.pencil")
                    .font(.body.weight(.medium))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(CodexTheme.raisedSurface)
                    .clipShape(RoundedRectangle(cornerRadius: 9))
            }
            .buttonStyle(.plain)
            .disabled(
                workspaceSelection == nil || isBrowsingPersistedThread
            )
            .accessibilityHint(
                isBrowsingPersistedThread
                    ? "Return to a live task to create a thread."
                    : "Create a thread in the selected live project."
            )
            .help(
                isBrowsingPersistedThread
                    ? "Available from a live task"
                    : "Create a new live thread"
            )
            .padding(.horizontal, 10)
            .accessibilityIdentifier("codex.thread.create")

            List {
                PersistedThreadDirectorySection(
                    state: threadDirectoryState,
                    searchText: $persistedThreadSearchText,
                    selection: persistedThreadSelection,
                    onArchiveScopeChange: onPersistedArchiveScopeChange,
                    onSelectThread: onSelectPersistedThread,
                    onLoadMore: onLoadMorePersistedThreads,
                    onRetryLoad: onRetryPersistedThreads
                )

                Section("Projects") {
                    ForEach(workspaces) { workspace in
                        DisclosureGroup(
                            isExpanded: expansionBinding(for: workspace.id)
                        ) {
                            let workspaceThreads = threads.filter {
                                $0.workspaceID == workspace.id
                                    && !archivedThreadIDs.contains($0.id)
                            }
                            if workspaceThreads.isEmpty {
                                Text("No threads yet")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                                    .padding(.leading, 8)
                            } else {
                                ForEach(workspaceThreads) { thread in
                                    Button {
                                        onActivateLiveSelection()
                                        workspaceSelection = workspace.id
                                        threadSelection = thread.id
                                    } label: {
                                        HStack(spacing: 8) {
                                            Image(systemName: "text.bubble")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                            Text(thread.title)
                                                .lineLimit(2)
                                            Spacer(minLength: 0)
                                        }
                                        .contentShape(Rectangle())
                                        .padding(.vertical, 3)
                                    }
                                    .buttonStyle(.plain)
                                    .contextMenu {
                                        Button {
                                            onRenameThread(thread)
                                        } label: {
                                            Label("Rename", systemImage: "pencil")
                                        }
                                        Button {
                                            onForkThread(thread)
                                        } label: {
                                            Label(
                                                "Fork",
                                                systemImage: "square.on.square"
                                            )
                                        }
                                        Button {
                                            onEditThreadGoal(thread)
                                        } label: {
                                            Label("Set goal", systemImage: "target")
                                        }
                                        Button {
                                            onClearThreadGoal(thread)
                                        } label: {
                                            Label(
                                                "Clear goal",
                                                systemImage: "xmark.circle"
                                            )
                                        }
                                        .disabled(!goalThreadIDs.contains(thread.id))
                                        Button(role: .destructive) {
                                            onArchiveThread(thread)
                                        } label: {
                                            Label(
                                                "Archive",
                                                systemImage: "archivebox"
                                            )
                                        }
                                        Button(role: .destructive) {
                                            onDeleteThread(thread)
                                        } label: {
                                            Label("Delete", systemImage: "trash")
                                        }
                                    }
                                    .listRowBackground(
                                        threadSelection == thread.id
                                            ? CodexTheme.raisedSurface
                                            : Color.clear
                                    )
                                }
                            }
                            let archivedThreads = threads.filter {
                                $0.workspaceID == workspace.id
                                    && archivedThreadIDs.contains($0.id)
                            }
                            if !archivedThreads.isEmpty {
                                DisclosureGroup("Archived") {
                                    ForEach(archivedThreads) { thread in
                                        HStack {
                                            Button {
                                                onUnarchiveThread(thread)
                                            } label: {
                                                Label(
                                                    thread.title,
                                                    systemImage: "arrow.uturn.backward"
                                                )
                                            }
                                            Button(role: .destructive) {
                                                onDeleteThread(thread)
                                            } label: {
                                                Image(systemName: "trash")
                                            }
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }
                        } label: {
                            Label(workspace.displayName, systemImage: "folder")
                                .font(.body.weight(.medium))
                        }
                        .tint(.secondary)
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)

            Divider()
            Button(action: onCreateWorkspace) {
                Label("Add project", systemImage: "plus")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("codex.workspace.create")
        }
        .background(CodexTheme.sidebar)
        .accessibilityIdentifier("codex.workspace.sidebar")
    }

    private var isBrowsingPersistedThread: Bool {
        persistedThreadSelection != nil
    }

    private func expansionBinding(for workspaceID: UUID) -> Binding<Bool> {
        Binding(
            get: { workspaceSelection == workspaceID },
            set: { expanded in
                onActivateLiveSelection()
                if expanded {
                    workspaceSelection = workspaceID
                    if !threads.contains(where: {
                        $0.id == threadSelection
                            && $0.workspaceID == workspaceID
                    }) {
                        threadSelection = threads.first(where: {
                            $0.workspaceID == workspaceID
                        })?.id
                    }
                }
            }
        )
    }
}
