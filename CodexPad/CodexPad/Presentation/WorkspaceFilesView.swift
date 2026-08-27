import SwiftUI

struct WorkspaceFilesView: View {
    let workspace: Workspace
    private let access = CodexWorkspaceAccess()
    @State private var files: [CodexWorkspaceFile] = []
    @State private var selectedFile: CodexWorkspaceFile?
    @State private var selectedText = ""
    @State private var problem: String?

    var body: some View {
        NavigationSplitView {
            List(files, selection: $selectedFile) { file in
                Label(
                    file.relativePath,
                    systemImage: file.isDirectory ? "folder" : "doc.text"
                )
                .tag(file)
            }
            .navigationTitle(workspace.displayName)
        } detail: {
            if let selectedFile, !selectedFile.isDirectory {
                ScrollView([.horizontal, .vertical]) {
                    Text(selectedText)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
                .navigationTitle(selectedFile.relativePath)
            } else {
                ContentUnavailableView(
                    "Select a File",
                    systemImage: "doc.text.magnifyingglass"
                )
            }
        }
        .task {
            loadFiles()
        }
        .onChange(of: selectedFile) {
            loadSelectedFile()
        }
        .alert(
            "Workspace Access Failed",
            isPresented: Binding(
                get: { problem != nil },
                set: { if !$0 { problem = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(problem ?? "")
        }
    }

    private func loadFiles() {
        guard let bookmark = workspace.rootBookmarkID else {
            problem = "This workspace has no Files permission."
            return
        }
        do {
            files = try access.listFiles(bookmark: bookmark)
            problem = nil
        } catch {
            problem = "Reopen this workspace to restore Files permission."
        }
    }

    private func loadSelectedFile() {
        guard let file = selectedFile, !file.isDirectory,
              let bookmark = workspace.rootBookmarkID
        else {
            selectedText = ""
            return
        }
        do {
            selectedText = try access.readText(
                bookmark: bookmark,
                relativePath: file.relativePath
            )
            problem = nil
        } catch CodexWorkspaceAccessError.fileTooLarge {
            problem = "This file is larger than the 2 MB preview limit."
        } catch CodexWorkspaceAccessError.notText {
            problem = "This file is not UTF-8 text."
        } catch {
            problem = "The selected file could not be opened."
        }
    }
}
