import SwiftUI

struct ThreadListView: View {
    let threads: [CodexThread]
    @Binding var selection: UUID?
    let canCreate: Bool
    let onCreate: () -> Void

    var body: some View {
        Group {
            if threads.isEmpty {
                ContentUnavailableView(
                    "No Threads",
                    systemImage: "bubble.left.and.bubble.right",
                    description: Text("Select a workspace with an existing thread.")
                )
            } else {
                List(threads, selection: $selection) { thread in
                    Text(thread.title)
                        .lineLimit(2)
                        .tag(thread.id)
                }
            }
        }
        .navigationTitle("Threads")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: onCreate) {
                    Label("New Thread", systemImage: "plus")
                }
                .disabled(!canCreate)
                .accessibilityIdentifier("codex.thread.create")
            }
        }
        .accessibilityIdentifier("codex.thread.list")
    }
}
