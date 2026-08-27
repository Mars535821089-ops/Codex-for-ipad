import SwiftUI

struct SessionInspectorView: View {
    let store: CodexSessionStore

    var body: some View {
        Form {
            Section("Session") {
                LabeledContent("Last sequence", value: String(store.state.lastAppliedSequence))
                LabeledContent("Workspaces", value: String(store.state.workspaces.count))
                LabeledContent("Threads", value: String(store.state.threads.count))
                LabeledContent("Turns", value: String(store.state.turns.count))
                LabeledContent("Items", value: String(store.state.items.count))
            }

            if let problem = store.lastApplyProblem {
                Section("Event stream") {
                    Text(problem.description)
                        .foregroundStyle(.orange)
                }
            }

            if let problem = store.lastTransportProblem {
                Section("Core storage") {
                    Text(problem)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            }
        }
        .navigationTitle("Inspector")
        .accessibilityIdentifier("codex.inspector")
    }
}

private extension ApplyResult {
    var description: String {
        switch self {
        case .applied:
            "Applied"
        case .duplicate:
            "Duplicate event"
        case .gap(let expected, let received):
            "Expected event \(expected), received \(received)"
        case .invalidReference(let message):
            message
        }
    }
}
