import Foundation
import SwiftUI

struct PersistedThreadDetailView: View {
    let state: CodexThreadDirectoryViewState
    let resumeState: CodexThreadResumeViewState
    let canOpenLiveTask: Bool
    let onOpenLiveTask: () -> Void
    let onResumeTask: () -> Void
    let streamingText: String
    let latestDiff: String?
    let onSubmit:
        (String, CodexTurnCancellation) async throws -> Void
    let onCancel: () -> Void
    let onRetryRead: () -> Void

    var body: some View {
        Group {
            switch state.selectionPhase {
            case .loading:
                loadingView

            case .failed:
                failureView

            case .loaded:
                if let thread = displayedThread {
                    threadContent(thread)
                } else {
                    unavailableView
                }

            case .idle:
                unavailableView
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(CodexTheme.canvas)
        .navigationTitle(displayedThread?.title ?? "Thread history")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("codex.persisted-thread.detail")
    }

    private var displayedThread: CodexStoredThreadPresentation? {
        guard resumeState.phase == .resumed,
              resumeState.selectedThreadID == state.selectedThreadID,
              let resumedThread = resumeState.resumedThread
        else {
            return state.selectedThread
        }
        return resumedThread
    }

    private var displayedResumeResult: CodexThreadResumeResult? {
        guard resumeState.phase == .resumed,
              resumeState.selectedThreadID == state.selectedThreadID
        else {
            return nil
        }
        return resumeState.resumeResult
    }

    private var loadingView: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Loading saved thread…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var failureView: some View {
        ContentUnavailableView {
            Label("Thread could not be loaded", systemImage: "exclamationmark.triangle")
        } description: {
            if let message = state.selectionErrorMessage {
                Text(message)
            }
        } actions: {
            Button("Retry", action: onRetryRead)
                .buttonStyle(.borderedProminent)
        }
    }

    private var unavailableView: some View {
        ContentUnavailableView(
            "Select a saved thread",
            systemImage: "clock.arrow.circlepath",
            description: Text(
                "Choose a thread from Thread history to inspect its saved turns."
            )
        )
    }

    private func threadContent(
        _ presentation: CodexStoredThreadPresentation
    ) -> some View {
        let thread = presentation.storedThread
        return VStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    threadHeader(presentation)
                    if let result = displayedResumeResult {
                        ResumedThreadRuntimeCard(result: result)
                    }
                    ThreadMetadataCard(thread: thread)

                    HStack(alignment: .firstTextBaseline) {
                        Text("Turns")
                            .font(.title3.weight(.semibold))
                        Spacer()
                        Text(thread.turns.count, format: .number)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if thread.turns.isEmpty {
                        Label(
                            "No turns were returned for this thread",
                            systemImage: "rectangle.stack"
                        )
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(18)
                        .background(CodexTheme.raisedSurface)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                    } else {
                        ForEach(thread.turns) { turn in
                            PersistedTurnCard(turn: turn)
                        }
                    }

                    if !streamingText.isEmpty {
                        PersistedStreamingAssistantRow(
                            text: streamingText
                        )
                    }

                    if let latestDiff = displayedLatestDiff {
                        PersistedLatestChangesPanel(
                            latestDiff: latestDiff
                        )
                    }
                }
                .frame(maxWidth: 860)
                .padding(.horizontal, 24)
                .padding(.vertical, 24)
                .frame(maxWidth: .infinity)
            }
            .defaultScrollAnchor(.bottom)

            if let result = displayedResumeResult {
                if thread.canAcceptDirectInput != false {
                    PersistedThreadComposer(
                        workspacePath: result.cwd,
                        model: result.model,
                        reasoningEffort: result.reasoningEffort,
                        onSubmit: onSubmit,
                        onCancel: onCancel
                    )
                    .id(result.thread.id.rawValue)
                    .accessibilityIdentifier(
                        "codex.persisted-thread.composer"
                    )
                } else {
                    Label(
                        "This saved task is read-only.",
                        systemImage: "lock.fill"
                    )
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 768, alignment: .leading)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 18)
                    .accessibilityIdentifier(
                        "codex.persisted-thread.read-only"
                    )
                }
            }
        }
    }

    private var displayedLatestDiff: String? {
        guard let latestDiff,
              !latestDiff.trimmingCharacters(
                in: .whitespacesAndNewlines
              ).isEmpty
        else {
            return nil
        }
        return latestDiff
    }

    private func threadHeader(
        _ presentation: CodexStoredThreadPresentation
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 7) {
                    Text(presentation.title)
                        .font(.largeTitle.weight(.semibold))
                        .textSelection(.enabled)

                    if !presentation.storedThread.preview
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .isEmpty
                    {
                        Text(presentation.storedThread.preview)
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }

                Spacer(minLength: 12)

                ThreadStatusBadge(
                    status: presentation.storedThread.status
                )
            }

            if canOpenLiveTask {
                Button(action: onOpenLiveTask) {
                    Label("Open live task", systemImage: "arrow.up.right.square")
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier(
                    "codex.persisted-thread.open-live"
                )
            } else {
                resumeControls
            }
        }
    }

    @ViewBuilder
    private var resumeControls: some View {
        switch resumeState.phase {
        case .idle:
            Button(action: onResumeTask) {
                Label(
                    "Resume task",
                    systemImage: "arrow.clockwise.circle"
                )
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier(
                "codex.persisted-thread.resume"
            )

        case .resuming:
            HStack(spacing: 9) {
                ProgressView()
                Text("Resuming task…")
                    .font(.subheadline.weight(.semibold))
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier(
                "codex.persisted-thread.resume"
            )

        case .failed:
            VStack(alignment: .leading, spacing: 9) {
                Label(
                    "Task resume failed",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.red)

                if let message = resumeState.errorMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                Button("Retry resume", action: onResumeTask)
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier(
                        "codex.persisted-thread.resume"
                    )
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(
                "codex.persisted-thread.resume-error"
            )

        case .resumed:
            Label("Resumed context", systemImage: "checkmark.circle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.green)
        }
    }
}

private struct PersistedLatestChangesPanel: View {
    let latestDiff: String
    @State private var changesExpanded = true

    var body: some View {
        DisclosureGroup("Changes", isExpanded: $changesExpanded) {
            UnifiedDiffView(diff: latestDiff)
                .padding(.top, 12)
        }
        .font(.headline)
        .padding(18)
        .background(CodexTheme.raisedSurface)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(CodexTheme.border, lineWidth: 1)
        }
        .accessibilityIdentifier(
            "codex.persisted-thread.latest-diff"
        )
    }
}

private struct PersistedStreamingAssistantRow: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label("Codex", systemImage: "sparkles")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(text)
                .font(.body)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(CodexTheme.raisedSurface.opacity(0.70))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .stroke(CodexTheme.border, lineWidth: 1)
        }
        .accessibilityIdentifier(
            "codex.persisted-thread.streaming-reply"
        )
    }
}

private struct PersistedThreadComposer: View {
    let workspacePath: String
    let model: String
    let reasoningEffort: String?
    let onSubmit:
        (String, CodexTurnCancellation) async throws -> Void
    let onCancel: () -> Void

    @State private var draft = ""
    @State private var submissionProblem: String?
    @State private var isSubmitting = false
    @State private var cancellation: CodexTurnCancellation?
    @State private var submissionTask: Task<Void, Never>?

    private var trimmedDraft: String {
        draft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(spacing: 10) {
            TextField(
                "Continue this Codex task…",
                text: $draft,
                axis: .vertical
            )
            .lineLimit(1...10)
            .textFieldStyle(.plain)
            .padding(.horizontal, 16)
            .padding(.top, 14)

            HStack(spacing: 10) {
                Label(workspacePath, systemImage: "folder")
                    .lineLimit(1)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text(
                    [model, reasoningEffort]
                        .compactMap { $0 }
                        .joined(separator: " · ")
                )
                .lineLimit(1)
                .font(.caption)
                .foregroundStyle(.secondary)

                Spacer()
                sendButton
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
        }
        .background(CodexTheme.raisedSurface)
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .overlay {
            RoundedRectangle(cornerRadius: 18)
                .stroke(CodexTheme.border, lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.06), radius: 16, y: 5)
        .frame(maxWidth: 768)
        .padding(.horizontal, 24)
        .padding(.bottom, 18)
        .alert(
            "Message not sent",
            isPresented: Binding(
                get: { submissionProblem != nil },
                set: { if !$0 { submissionProblem = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(submissionProblem ?? "")
        }
        .onDisappear {
            if isSubmitting {
                stop()
            }
        }
    }

    private var sendButton: some View {
        Button {
            if isSubmitting {
                stop()
            } else {
                submit()
            }
        } label: {
            ZStack {
                Circle()
                    .fill(
                        trimmedDraft.isEmpty
                            ? Color.secondary.opacity(0.18)
                            : CodexTheme.accent
                    )
                    .frame(width: 32, height: 32)
                Image(
                    systemName: isSubmitting
                        ? "stop.fill"
                        : "arrow.up"
                )
                .font(
                    .system(
                        size: isSubmitting ? 11 : 14,
                        weight: .bold
                    )
                )
                .foregroundStyle(.white)
            }
        }
        .buttonStyle(.plain)
        .disabled(!isSubmitting && trimmedDraft.isEmpty)
        .accessibilityLabel(
            isSubmitting ? "Stop task" : "Send message"
        )
    }

    private func submit() {
        let text = trimmedDraft
        guard !text.isEmpty else {
            return
        }
        let cancellation = CodexTurnCancellation()
        self.cancellation = cancellation
        isSubmitting = true
        submissionTask = Task {
            do {
                try await onSubmit(text, cancellation)
                draft = ""
                submissionProblem = nil
            } catch is CancellationError {
                submissionProblem = nil
            } catch {
                submissionProblem = error.localizedDescription
            }
            isSubmitting = false
            self.cancellation = nil
            submissionTask = nil
        }
    }

    private func stop() {
        cancellation?.cancel()
        submissionTask?.cancel()
        onCancel()
    }
}

private struct ResumedThreadRuntimeCard: View {
    let result: CodexThreadResumeResult

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Resumed context", systemImage: "bolt.circle.fill")
                .font(.headline)
                .foregroundStyle(.green)

            Divider()

            PersistedMetadataRow(
                label: "Model",
                value: result.model
            )
            PersistedMetadataRow(
                label: "Model provider",
                value: result.modelProvider
            )
            PersistedMetadataRow(
                label: "Working directory",
                value: result.cwd,
                monospaced: true
            )
            if let serviceTier = result.serviceTier {
                PersistedMetadataRow(
                    label: "Service tier",
                    value: serviceTier
                )
            }
            if let reasoningEffort = result.reasoningEffort {
                PersistedMetadataRow(
                    label: "Reasoning effort",
                    value: reasoningEffort
                )
            }
        }
        .padding(18)
        .background(CodexTheme.raisedSurface)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(CodexTheme.border, lineWidth: 1)
        }
        .accessibilityIdentifier("codex.persisted-thread.resumed")
    }
}

private struct ThreadMetadataCard: View {
    let thread: CodexStoredThread

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Thread metadata")
                .font(.headline)

            Divider()

            PersistedMetadataRow(
                label: "Thread ID",
                value: thread.id.rawValue,
                monospaced: true
            )
            PersistedMetadataRow(
                label: "Session ID",
                value: thread.sessionID,
                monospaced: true
            )
            PersistedMetadataRow(
                label: "Working directory",
                value: thread.cwd,
                monospaced: true
            )
            PersistedMetadataRow(
                label: "Status",
                value: thread.status.displayText
            )
            PersistedMetadataRow(
                label: "Source",
                value: thread.source.displayText
            )
            PersistedMetadataRow(
                label: "Model provider",
                value: thread.modelProvider
            )
            PersistedMetadataRow(
                label: "CLI version",
                value: thread.cliVersion,
                monospaced: true
            )
            PersistedMetadataRow(
                label: "Created",
                value: persistedTimestamp(thread.createdAt)
            )
            PersistedMetadataRow(
                label: "Updated",
                value: persistedTimestamp(thread.updatedAt)
            )

            if let recencyAt = thread.recencyAt {
                PersistedMetadataRow(
                    label: "Recent activity",
                    value: persistedTimestamp(recencyAt)
                )
            }
            if let path = thread.path {
                PersistedMetadataRow(
                    label: "Saved path",
                    value: path,
                    monospaced: true
                )
            }
            if let threadSource = thread.threadSource {
                PersistedMetadataRow(
                    label: "Thread source",
                    value: threadSource
                )
            }
            if let nickname = thread.agentNickname {
                PersistedMetadataRow(
                    label: "Agent nickname",
                    value: nickname
                )
            }
            if let role = thread.agentRole {
                PersistedMetadataRow(label: "Agent role", value: role)
            }
            if let parent = thread.parentThreadID {
                PersistedMetadataRow(
                    label: "Parent thread",
                    value: parent.rawValue,
                    monospaced: true
                )
            }
            if let forkedFrom = thread.forkedFromID {
                PersistedMetadataRow(
                    label: "Forked from",
                    value: forkedFrom.rawValue,
                    monospaced: true
                )
            }
            if let historyMode = thread.historyMode {
                PersistedMetadataRow(
                    label: "History mode",
                    value: historyMode.rawValue
                )
            }
            if let canAcceptDirectInput = thread.canAcceptDirectInput {
                PersistedMetadataRow(
                    label: "Direct input",
                    value: canAcceptDirectInput ? "true" : "false"
                )
            }
            if let gitInfo = thread.gitInfo {
                if let branch = gitInfo.branch {
                    PersistedMetadataRow(
                        label: "Git branch",
                        value: branch,
                        monospaced: true
                    )
                }
                if let sha = gitInfo.sha {
                    PersistedMetadataRow(
                        label: "Git SHA",
                        value: sha,
                        monospaced: true
                    )
                }
                if let originURL = gitInfo.originURL {
                    PersistedMetadataRow(
                        label: "Git origin",
                        value: originURL,
                        monospaced: true
                    )
                }
            }
            if thread.ephemeral {
                PersistedMetadataRow(label: "Ephemeral", value: "true")
            }
        }
        .padding(18)
        .background(CodexTheme.raisedSurface)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(CodexTheme.border, lineWidth: 1)
        }
    }
}

private struct PersistedMetadataRow: View {
    let label: String
    let value: String
    var monospaced = false

    var body: some View {
        LabeledContent {
            Text(value)
                .font(
                    monospaced
                        ? .system(.caption, design: .monospaced)
                        : .subheadline
                )
                .foregroundStyle(.primary)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        } label: {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct ThreadStatusBadge: View {
    let status: CodexStoredThreadStatus

    var body: some View {
        Label(status.displayText, systemImage: status.symbolName)
            .font(.caption.weight(.semibold))
            .foregroundStyle(status.tint)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(status.tint.opacity(0.11))
            .clipShape(Capsule())
    }
}

private struct PersistedTurnCard: View {
    let turn: CodexStoredTurn

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 9) {
                Image(systemName: turn.status.symbolName)
                    .foregroundStyle(turn.status.tint)
                Text("Turn")
                    .font(.headline)
                Text(turn.id)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .textSelection(.enabled)
                Spacer(minLength: 8)
                Text(turn.status.rawValue)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(turn.status.tint)
            }

            HStack(spacing: 12) {
                Label(
                    "\(turn.items.count) items",
                    systemImage: "rectangle.stack"
                )
                Text(turn.itemsView.rawValue)
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if let startedAt = turn.startedAt {
                PersistedMetadataRow(
                    label: "Started",
                    value: persistedTimestamp(startedAt)
                )
            }
            if let completedAt = turn.completedAt {
                PersistedMetadataRow(
                    label: "Completed",
                    value: persistedTimestamp(completedAt)
                )
            }
            if let durationMs = turn.durationMs {
                PersistedMetadataRow(
                    label: "Duration",
                    value: "\(durationMs) ms"
                )
            }
            if let error = turn.error {
                VStack(alignment: .leading, spacing: 5) {
                    Label("Turn error", systemImage: "exclamationmark.triangle")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(CodexTheme.deleted)
                    Text(error.message)
                        .font(.subheadline)
                        .textSelection(.enabled)
                    if let details = error.additionalDetails {
                        Text(details)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(CodexTheme.deleted.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }

            if !turn.items.isEmpty {
                Divider()

                ForEach(turn.items) { item in
                    PersistedThreadItemCard(
                        item: CodexStoredThreadItemPresentation(
                            item: item,
                            turnID: turn.id
                        )
                    )
                }
            }
        }
        .padding(18)
        .background(CodexTheme.raisedSurface.opacity(0.70))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .stroke(CodexTheme.border, lineWidth: 1)
        }
    }
}

private struct PersistedThreadItemCard: View {
    let item: CodexStoredThreadItemPresentation

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Label(item.kind.rawValue, systemImage: item.kind.symbolName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(item.kind.tint)
                Spacer(minLength: 8)
                Text(item.itemID)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .textSelection(.enabled)
            }

            ForEach(
                Array(item.textFragments.enumerated()),
                id: \.offset
            ) { _, fragment in
                if !fragment.isEmpty {
                    Text(fragment)
                        .font(
                            item.kind.usesMonospacedText
                                ? .system(.caption, design: .monospaced)
                                : .body
                        )
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(13)
        .background(CodexTheme.canvas)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(CodexTheme.border, lineWidth: 1)
        }
    }
}

private func persistedTimestamp(_ rawValue: Int64) -> String {
    let absolute = rawValue.magnitude
    let seconds =
        absolute > 100_000_000_000
        ? TimeInterval(rawValue) / 1_000
        : TimeInterval(rawValue)
    return Date(timeIntervalSince1970: seconds).formatted(
        date: .abbreviated,
        time: .shortened
    )
}

private extension CodexStoredThreadStatus {
    var displayText: String {
        switch self {
        case .notLoaded:
            "notLoaded"
        case .idle:
            "idle"
        case .systemError:
            "systemError"
        case let .active(flags):
            if flags.isEmpty {
                "active"
            } else {
                "active · " + flags.map(\.rawValue).joined(separator: ", ")
            }
        }
    }

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

private extension CodexStoredTurnStatus {
    var symbolName: String {
        switch self {
        case .completed:
            "checkmark.circle.fill"
        case .interrupted:
            "pause.circle.fill"
        case .failed:
            "xmark.octagon.fill"
        case .inProgress:
            "circle.dotted"
        }
    }

    var tint: Color {
        switch self {
        case .completed:
            CodexTheme.added
        case .interrupted:
            .orange
        case .failed:
            CodexTheme.deleted
        case .inProgress:
            CodexTheme.accent
        }
    }
}

private extension CodexThreadSessionSource {
    var displayText: String {
        switch self {
        case let .named(source):
            source.rawValue
        case let .custom(source):
            source
        case let .subAgent(source):
            switch source {
            case .review:
                "subAgent.review"
            case .compact:
                "subAgent.compact"
            case .memoryConsolidation:
                "subAgent.memoryConsolidation"
            case let .threadSpawn(
                parentThreadID,
                depth,
                agentPath,
                agentNickname,
                agentRole,
                model
            ):
                [
                    "subAgent.threadSpawn",
                    parentThreadID.rawValue,
                    String(depth),
                    agentPath,
                    agentNickname,
                    agentRole,
                    model,
                ]
                .compactMap { $0 }
                .joined(separator: " · ")
            case let .other(source):
                "subAgent.\(source)"
            }
        }
    }
}

private extension CodexStoredThreadItemKind {
    var symbolName: String {
        switch self {
        case .userMessage, .hookPrompt:
            "person.crop.circle"
        case .agentMessage:
            "sparkles"
        case .plan:
            "list.bullet.clipboard"
        case .reasoning:
            "brain"
        case .commandExecution:
            "terminal"
        case .fileChange:
            "doc.badge.gearshape"
        case .mcpToolCall, .dynamicToolCall, .collabAgentToolCall:
            "wrench.and.screwdriver"
        case .subAgentActivity:
            "person.2"
        case .webSearch:
            "globe"
        case .imageView:
            "photo"
        case .sleep:
            "moon.zzz"
        case .imageGeneration:
            "wand.and.stars"
        case .enteredReviewMode, .exitedReviewMode:
            "checkmark.seal"
        case .contextCompaction:
            "arrow.down.right.and.arrow.up.left"
        }
    }

    var tint: Color {
        switch self {
        case .userMessage:
            CodexTheme.accent
        case .fileChange:
            CodexTheme.added
        case .commandExecution, .mcpToolCall, .dynamicToolCall,
             .collabAgentToolCall:
            .orange
        default:
            .secondary
        }
    }

    var usesMonospacedText: Bool {
        switch self {
        case .commandExecution, .fileChange, .mcpToolCall,
             .dynamicToolCall, .collabAgentToolCall:
            true
        default:
            false
        }
    }
}
