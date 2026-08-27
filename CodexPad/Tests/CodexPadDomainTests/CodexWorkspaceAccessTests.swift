import Foundation
import Testing
@testable import CodexPadApplication
@testable import CodexPadDomain

@Test
func workspacePathValidationRejectsTraversalAndAbsolutePaths() throws {
    let root = URL(fileURLWithPath: "/tmp/codex-workspace", isDirectory: true)
    #expect(throws: CodexWorkspaceAccessError.invalidRelativePath) {
        try CodexWorkspaceAccess.secureURL(
            relativePath: "../private.txt",
            inside: root
        )
    }
    #expect(throws: CodexWorkspaceAccessError.invalidRelativePath) {
        try CodexWorkspaceAccess.secureURL(
            relativePath: "/etc/passwd",
            inside: root
        )
    }
}

@Test
func workspacePathValidationKeepsFilesInsideSelectedFolder() throws {
    let root = URL(fileURLWithPath: "/tmp/codex-workspace", isDirectory: true)
    let file = try CodexWorkspaceAccess.secureURL(
        relativePath: "Sources/App.swift",
        inside: root
    )
    #expect(file.path == "/tmp/codex-workspace/Sources/App.swift")
}

@Test
func workspaceWriteCreatesNestedUtf8FileAtomically() throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
        at: root,
        withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: root) }

    let access = CodexWorkspaceAccess()
    let bookmark = try access.bookmark(for: root)
    try access.writeText(
        bookmark: bookmark,
        relativePath: "Sources/App.swift",
        text: "print(\"Codex for ipad\")\n"
    )

    #expect(
        try access.readText(
            bookmark: bookmark,
            relativePath: "Sources/App.swift"
        ) == "print(\"Codex for ipad\")\n"
    )
}

@Test
func persistedWorkspaceBookmarkSurvivesRelaunchAndRestoresFileAccess()
    throws
{
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory.appending(
        path: "codex-bookmark-relaunch-\(UUID().uuidString)",
        directoryHint: .isDirectory
    )
    try fileManager.createDirectory(
        at: root,
        withIntermediateDirectories: true
    )
    defer { try? fileManager.removeItem(at: root) }
    try Data("desktop parity\n".utf8).write(
        to: root.appending(path: "README.md"),
        options: .atomic
    )

    let initialAccess = CodexWorkspaceAccess()
    let original = Workspace(
        id: UUID(),
        displayName: "Codex",
        rootBookmarkID: try initialAccess.bookmark(for: root)
    )
    let persistedBytes = try JSONEncoder().encode(original)

    let restored = try JSONDecoder().decode(
        Workspace.self,
        from: persistedBytes
    )
    let relaunchedAccess = CodexWorkspaceAccess()
    let bookmark = try #require(restored.rootBookmarkID)
    #expect(
        try relaunchedAccess.resolve(bookmark)
            .standardizedFileURL.path
            == root.standardizedFileURL.path
    )
    #expect(
        try relaunchedAccess.listFiles(bookmark: bookmark)
            .contains(
                CodexWorkspaceFile(
                    relativePath: "README.md",
                    isDirectory: false
                )
            )
    )
    #expect(
        try relaunchedAccess.readText(
            bookmark: bookmark,
            relativePath: "README.md"
        ) == "desktop parity\n"
    )
    try relaunchedAccess.writeText(
        bookmark: bookmark,
        relativePath: "Sources/App.swift",
        text: "print(\"restored\")\n"
    )
    #expect(
        try String(
            contentsOf: root.appending(path: "Sources/App.swift"),
            encoding: .utf8
        ) == "print(\"restored\")\n"
    )
}

@Test
func workspaceToolRunnerListsReadsAndWritesSelectedWorkspace() throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
        at: root,
        withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: root) }

    let access = CodexWorkspaceAccess()
    let workspace = Workspace(
        id: UUID(),
        displayName: "Fixture",
        rootBookmarkID: try access.bookmark(for: root)
    )
    let runner = CodexWorkspaceToolRunner(access: access)
    let write = try runner.execute(
        name: "write_workspace_file",
        arguments: #"{"path":"README.md","text":"hello"}"#,
        workspace: workspace
    )
    #expect(write.contains(#""bytesWritten":5"#))
    let writeObject = try #require(
        JSONSerialization.jsonObject(with: Data(write.utf8))
            as? [String: Any]
    )
    let diff = try #require(writeObject["diff"] as? String)
    #expect(diff.contains("--- /dev/null"))
    #expect(diff.contains("+hello"))
    let read = try runner.execute(
        name: "read_workspace_file",
        arguments: #"{"path":"README.md"}"#,
        workspace: workspace
    )
    #expect(read.contains(#""text":"hello""#))
    let search = try runner.execute(
        name: "search_workspace_text",
        arguments: #"{"query":"hello","limit":20}"#,
        workspace: workspace
    )
    #expect(search.contains(#""path":"README.md""#))
    #expect(search.contains(#""line":1"#))
    #expect(search.contains(#""text":"hello""#))
    let list = try runner.execute(
        name: "list_workspace_files",
        arguments: #"{"limit":10}"#,
        workspace: workspace
    )
    #expect(list.contains(#""path":"README.md""#))
}

@Test
func cancelledWorkspaceToolRunnerDoesNotStartAFileWrite() throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
        at: root,
        withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: root) }

    let access = CodexWorkspaceAccess()
    let workspace = Workspace(
        id: UUID(),
        displayName: "Fixture",
        rootBookmarkID: try access.bookmark(for: root)
    )
    let cancellation = CodexTurnCancellation()
    cancellation.cancel()

    do {
        _ = try CodexWorkspaceToolRunner(access: access).execute(
            name: "write_workspace_file",
            arguments: #"{"path":"cancelled.txt","text":"late write"}"#,
            workspace: workspace,
            cancellation: cancellation
        )
        Issue.record("Expected cancellation")
    } catch {
        #expect(error is CancellationError)
    }
    #expect(
        !FileManager.default.fileExists(
            atPath: root.appending(path: "cancelled.txt").path
        )
    )
}
