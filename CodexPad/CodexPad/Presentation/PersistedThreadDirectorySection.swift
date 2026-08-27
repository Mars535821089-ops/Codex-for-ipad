import SwiftUI

struct PersistedThreadDirectorySection: View {
    let state: CodexThreadDirectoryViewState
    @Binding var searchText: String
    let selection: String?
    let onArchiveScopeChange: (CodexThreadDirectoryArchiveScope) -> Void
    let onSelectThread: (String) -> Void
    let onLoadMore: () -> Void
    let onRetryLoad: () -> Void

    var body: some View {
        Group {
            Section {
                searchField
                archiveScopePicker
            } header: {
                Text("Thread history")
            }

            Section {
                directoryContent
            } header: {
                HStack {
                    Text(
                        state.criteria.archiveScope == .active
                            ? "Active threads"
                            : "Archived threads"
                    )
                    Spacer()
                    if !state.rows.isEmpty {
                        Text(state.rows.count, format: .number)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.caption)
                .foregroundStyle(.secondary)

            TextField("Search saved threads", text: $searchText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear thread search")
            }
        }
        .padding(.vertical, 2)
    }

    private var archiveScopePicker: some View {
        Picker(
            "Thread archive",
            selection: Binding(
                get: {
                    state.criteria.archiveScope == .archived
                },
                set: {
                    onArchiveScopeChange($0 ? .archived : .active)
                }
            )
        ) {
            Text("Active").tag(false)
            Text("Archived").tag(true)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .accessibilityLabel("Thread archive")
    }

    @ViewBuilder
    private var directoryContent: some View {
        if state.rows.isEmpty {
            emptyDirectoryContent
        } else {
            ForEach(state.rows) { row in
                Button {
                    onSelectThread(row.id.rawValue)
                } label: {
                    PersistedThreadDirectoryRow(
                        thread: row,
                        isSelected: selection == row.id.rawValue
                    )
                }
                .buttonStyle(.plain)
                .listRowBackground(
                    selection == row.id.rawValue
                        ? CodexTheme.raisedSurface
                        : Color.clear
                )
                .accessibilityIdentifier(
                    "codex.persisted-thread.\(row.id.rawValue)"
                )
            }

            pagingContent
        }
    }

    @ViewBuilder
    private var emptyDirectoryContent: some View {
        switch state.loadPhase {
        case .loadingInitial, .loadingNextPage:
            HStack(spacing: 9) {
                ProgressView()
                    .controlSize(.small)
                Text("Loading threads…")
                    .foregroundStyle(.secondary)
            }
            .font(.caption)

        case .failed:
            loadFailureContent

        case .idle, .loaded:
            Label(
                searchText.trimmingCharacters(
                    in: .whitespacesAndNewlines
                ).isEmpty
                    ? "No threads in this section"
                    : "No matching threads",
                systemImage: "text.bubble"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var pagingContent: some View {
        switch state.loadPhase {
        case .loadingNextPage:
            HStack(spacing: 9) {
                ProgressView()
                    .controlSize(.small)
                Text("Loading more…")
            }
            .font(.caption)
            .foregroundStyle(.secondary)

        case .failed:
            loadFailureContent

        case .idle, .loadingInitial, .loaded:
            if state.canLoadNextPage {
                Button(action: onLoadMore) {
                    Label("Load more", systemImage: "arrow.down.circle")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .foregroundStyle(CodexTheme.accent)
                .accessibilityIdentifier(
                    "codex.persisted-thread.load-more"
                )
            }
        }
    }

    private var loadFailureContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let message = state.loadErrorMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
            Button(action: onRetryLoad) {
                Label("Retry", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .font(.caption.weight(.semibold))
            .foregroundStyle(CodexTheme.accent)
        }
        .padding(.vertical, 3)
    }
}

private struct PersistedThreadDirectoryRow: View {
    let thread: CodexStoredThreadPresentation
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Image(systemName: thread.storedThread.status.symbolName)
                    .font(.caption2)
                    .foregroundStyle(thread.storedThread.status.tint)

                Text(thread.title)
                    .font(.subheadline.weight(isSelected ? .semibold : .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(2)

                Spacer(minLength: 4)
            }

            Text(thread.summary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)

            Label(thread.storedThread.cwd, systemImage: "folder")
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .padding(.vertical, 4)
    }
}

private extension CodexStoredThreadStatus {
    var symbolName: String {
        switch self {
        case .notLoaded:
            "circle.dashed"
        case .idle:
            "checkmark.circle"
        case .systemError:
            "exclamationmark.triangle"
        case .active:
            "circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .notLoaded:
            .secondary
        case .idle:
            CodexTheme.added
        case .systemError:
            CodexTheme.deleted
        case .active:
            CodexTheme.accent
        }
    }
}
