import SwiftUI

struct ThreadGoalEditorSheet: View {
    @Binding var objective: String
    @Binding var status: ThreadGoalStatus
    @Binding var tokenBudget: String
    let onCancel: () -> Void
    let onSave: () -> Void

    private var canSave: Bool {
        !objective.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (
                tokenBudget.trimmingCharacters(
                    in: .whitespacesAndNewlines
                ).isEmpty
                    || (Int64(tokenBudget).map { $0 > 0 } ?? false)
            )
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Objective") {
                    TextField(
                        "What should Codex keep working toward?",
                        text: $objective,
                        axis: .vertical
                    )
                    .lineLimit(3...8)
                }
                Section("Status") {
                    Picker("Goal status", selection: $status) {
                        ForEach(ThreadGoalStatus.allCases, id: \.self) {
                            Text($0.displayName).tag($0)
                        }
                    }
                }
                Section("Optional budget") {
                    TextField("Token budget", text: $tokenBudget)
                        .keyboardType(.numberPad)
                    Text("Leave empty for no token limit.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Thread goal")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: onSave)
                        .disabled(!canSave)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
