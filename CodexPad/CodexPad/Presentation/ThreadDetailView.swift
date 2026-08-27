import SwiftUI

struct ThreadDetailView: View {
    let thread: CodexThread?
    let workspaceName: String?
    let modelName: String
    let reasoningEffortName: String
    let goal: ThreadGoal?
    let items: [ThreadItem]
    let streamingText: String
    let onSubmit: (String, CodexTurnCancellation) async throws -> Void
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
        VStack(spacing: 0) {
            if let thread {
                Group {
                    if let goal {
                        HStack(spacing: 8) {
                            Image(systemName: "target")
                            Text(goal.objective)
                                .lineLimit(2)
                            Spacer()
                            Text(goal.status.rawValue)
                                .foregroundStyle(.secondary)
                        }
                        .font(.caption)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 9)
                        .background(CodexTheme.raisedSurface)
                    }
                    if items.isEmpty && streamingText.isEmpty {
                        CodexLandingView()
                    } else {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 22) {
                                ForEach(items) { item in
                                    ThreadItemRow(item: item)
                                }
                                if !streamingText.isEmpty {
                                    StreamingAssistantRow(text: streamingText)
                                }
                            }
                            .frame(maxWidth: 768)
                            .padding(.horizontal, 28)
                            .padding(.vertical, 32)
                            .frame(maxWidth: .infinity)
                        }
                        .defaultScrollAnchor(.bottom)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                composer
                    .accessibilityIdentifier("codex.composer")
                .navigationTitle(thread.title)
            } else {
                CodexLandingView(
                    title: "What can I help you build?",
                    subtitle: "Add a project or select a thread to get started."
                )
            }
        }
        .background(CodexTheme.canvas)
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
        .accessibilityIdentifier("codex.thread.detail")
    }

    private var composer: some View {
        VStack(spacing: 10) {
            TextField(
                "Ask Codex to build, fix, or explore…",
                text: $draft,
                axis: .vertical
            )
            .lineLimit(1...10)
            .textFieldStyle(.plain)
            .accessibilityIdentifier("codex.composer.input")
            .padding(.horizontal, 16)
            .padding(.top, 14)

            HStack(spacing: 10) {
                Label(
                    workspaceName ?? "Select project",
                    systemImage: "folder"
                )
                .lineLimit(1)
                .font(.caption)
                .foregroundStyle(.secondary)

                Text("\(modelName) · \(reasoningEffortName)")
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
                if isSubmitting {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                } else {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(!isSubmitting && trimmedDraft.isEmpty)
        .accessibilityLabel(isSubmitting ? "Stop task" : "Send message")
    }

    private func submit() {
        let text = trimmedDraft
        guard !text.isEmpty else { return }
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

private struct StreamingAssistantRow: View {
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
                .accessibilityIdentifier("codex.streaming.reply")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ThreadItemRow: View {
    let item: ThreadItem

    var body: some View {
        HStack {
            if item.kind == .userMessage {
                Spacer(minLength: 70)
            }
            VStack(alignment: .leading, spacing: 7) {
                if item.kind != .userMessage {
                    Label(item.kind.label, systemImage: item.kind.symbol)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(item.kind.tint)
                }
                if item.kind == .fileChange,
                   item.text.hasPrefix("--- ")
                {
                    UnifiedDiffView(diff: item.text)
                } else {
                    Text(item.text)
                        .font(.body)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(item.kind == .userMessage ? 13 : 0)
            .background(
                item.kind == .userMessage
                    ? CodexTheme.raisedSurface
                    : Color.clear
            )
            .clipShape(RoundedRectangle(cornerRadius: 14))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct UnifiedDiffView: View {
    let diff: String

    var body: some View {
        ScrollView(.horizontal) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(CodexDiffLine.parse(diff)) { line in
                    Text(line.text.isEmpty ? " " : line.text)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(line.foreground)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(line.background)
                }
            }
            .textSelection(.enabled)
        }
        .background(CodexTheme.raisedSurface)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(CodexTheme.border, lineWidth: 1)
        }
        .accessibilityIdentifier("codex.file.diff")
    }
}

private extension CodexDiffLine {
    var foreground: Color {
        switch kind {
        case .addition: CodexTheme.added
        case .deletion: CodexTheme.deleted
        case .header: CodexTheme.accent
        case .context: .primary
        }
    }

    var background: Color {
        switch kind {
        case .addition: CodexTheme.added.opacity(0.10)
        case .deletion: CodexTheme.deleted.opacity(0.10)
        case .header: CodexTheme.accent.opacity(0.08)
        case .context: .clear
        }
    }
}

private extension ThreadItemKind {
    var label: String {
        switch self {
        case .userMessage: "You"
        case .assistantMessage: "Codex"
        case .reasoning: "Reasoning"
        case .toolCall: "Working"
        case .toolResult: "Done"
        case .approval: "Approval"
        case .fileChange: "File change"
        case .terminal: "Terminal"
        case .error: "Error"
        case .contextCompaction: "Context compacted"
        }
    }

    var symbol: String {
        switch self {
        case .userMessage: "person"
        case .assistantMessage: "sparkles"
        case .reasoning: "brain"
        case .toolCall: "wrench.and.screwdriver"
        case .toolResult: "checkmark.circle"
        case .approval: "hand.raised"
        case .fileChange: "doc.badge.gearshape"
        case .terminal: "terminal"
        case .error: "exclamationmark.triangle"
        case .contextCompaction: "arrow.trianglehead.2.clockwise.rotate.90"
        }
    }

    var tint: Color {
        switch self {
        case .error: CodexTheme.deleted
        case .fileChange, .toolResult: CodexTheme.added
        default: .secondary
        }
    }
}

private struct CodexLandingView: View {
    var title = "What can I help you build?"
    var subtitle = "Describe a task and Codex will work in your selected project."

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "terminal.fill")
                .font(.system(size: 32, weight: .medium))
                .foregroundStyle(CodexTheme.accent)
                .frame(width: 64, height: 64)
                .background(CodexTheme.raisedSurface)
                .clipShape(RoundedRectangle(cornerRadius: 16))
            Text(title)
                .font(.title2.weight(.semibold))
            Text(subtitle)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
        }
        .padding(32)
    }
}
