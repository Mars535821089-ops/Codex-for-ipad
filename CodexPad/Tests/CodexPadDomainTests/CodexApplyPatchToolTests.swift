import Foundation
import Testing
@testable import CodexPadApplication
@testable import CodexPadDomain
@testable import CodexPadProtocolBridge

struct CodexApplyPatchToolTests {
    @Test
    func applyPatchWritesAddUpdateMoveAndDeleteHunksAndReturnsCombinedDiff()
        throws
    {
        let fixture = try WorkspaceFixture()
        defer { fixture.remove() }
        try fixture.write(
            "Sources/App.swift",
            """
            let first = 1
            let middle = 2
            let last = 3
            """
        )
        try fixture.write("Sources/OldName.swift", "let moved = false\n")
        try fixture.write("obsolete.txt", "remove me\n")

        let patch = """
        *** Begin Patch
        *** Add File: Notes/result.txt
        +hello
        +world
        *** Update File: Sources/App.swift
        @@
        -let first = 1
        +let first = 10
         let middle = 2
        @@
        -let last = 3
        +let last = 30
        *** Update File: Sources/OldName.swift
        *** Move to: Sources/NewName.swift
        @@
        -let moved = false
        +let moved = true
        *** Delete File: obsolete.txt
        *** End Patch
        """

        let result = try fixture.runner.executeDetailed(
            name: "apply_patch",
            arguments: patch,
            workspace: fixture.workspace
        )

        #expect(
            result.output
                == """
                Success. Updated the following files:
                A Notes/result.txt
                M Sources/App.swift
                M Sources/NewName.swift
                D obsolete.txt

                """
        )
        #expect(try fixture.read("Notes/result.txt") == "hello\nworld\n")
        #expect(
            try fixture.read("Sources/App.swift")
                == """
                let first = 10
                let middle = 2
                let last = 30

                """
        )
        #expect(try fixture.read("Sources/NewName.swift") == "let moved = true\n")
        #expect(!fixture.exists("Sources/OldName.swift"))
        #expect(!fixture.exists("obsolete.txt"))

        let diff = try #require(result.workspaceDiff)
        #expect(diff.contains("--- /dev/null\n+++ b/Notes/result.txt"))
        #expect(diff.contains("--- a/Sources/App.swift\n+++ b/Sources/App.swift"))
        #expect(
            diff.contains(
                "--- a/Sources/OldName.swift\n+++ b/Sources/NewName.swift"
            )
        )
        #expect(diff.contains("--- a/obsolete.txt\n+++ /dev/null"))
        #expect(diff.contains("-let first = 1"))
        #expect(diff.contains("+let first = 10"))
        #expect(diff.contains("-remove me"))
        let changes = try #require(result.fileChanges)
        #expect(changes.map(\.path) == [
            "Notes/result.txt",
            "Sources/App.swift",
            "Sources/OldName.swift",
            "obsolete.txt",
        ])
        #expect(changes[0].kind == .add)
        #expect(changes[0].diff == "hello\nworld\n")
        #expect(changes[1].kind == .update(movePath: nil))
        #expect(
            changes[2].kind
                == .update(movePath: "Sources/NewName.swift")
        )
        #expect(
            changes[2].diff
                .hasSuffix("\n\nMoved to: Sources/NewName.swift")
        )
        #expect(changes[3].kind == .delete)
        #expect(changes[3].diff == "remove me\n")
    }

    @Test
    func applyPatchCompatibilityExecuteReturnsOfficialSummary() throws {
        let fixture = try WorkspaceFixture()
        defer { fixture.remove() }

        let output = try fixture.runner.execute(
            name: "apply_patch",
            arguments: """
            *** Begin Patch
            *** Add File: README.md
            +created
            *** End Patch
            """,
            workspace: fixture.workspace
        )

        #expect(
            output
                == """
                Success. Updated the following files:
                A README.md

                """
        )
        #expect(try fixture.read("README.md") == "created\n")
    }

    @Test
    func applyPatchRejectsTraversalBeforeWritingAnyFiles() throws {
        let fixture = try WorkspaceFixture()
        defer { fixture.remove() }
        let escaped = fixture.root.deletingLastPathComponent()
            .appending(path: "escaped-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: escaped) }

        #expect(throws: CodexWorkspacePatchError.self) {
            _ = try fixture.runner.executeDetailed(
                name: "apply_patch",
                arguments: """
                *** Begin Patch
                *** Add File: safe.txt
                +must not be committed
                *** Add File: ../\(escaped.lastPathComponent)
                +escaped
                *** End Patch
                """,
                workspace: fixture.workspace
            )
        }

        #expect(!fixture.exists("safe.txt"))
        #expect(!FileManager.default.fileExists(atPath: escaped.path))
    }

    @Test
    func applyPatchRejectsAbsoluteAndEscapingMovePaths() throws {
        let fixture = try WorkspaceFixture()
        defer { fixture.remove() }
        try fixture.write("inside.txt", "old\n")

        for destination in ["/tmp/outside.txt", "../outside.txt"] {
            #expect(throws: CodexWorkspacePatchError.self) {
                _ = try fixture.runner.executeDetailed(
                    name: "apply_patch",
                    arguments: """
                    *** Begin Patch
                    *** Update File: inside.txt
                    *** Move to: \(destination)
                    @@
                    -old
                    +new
                    *** End Patch
                    """,
                    workspace: fixture.workspace
                )
            }
            #expect(try fixture.read("inside.txt") == "old\n")
        }
    }

    @Test
    func applyPatchContextFailureDoesNotModifyTheWorkspace() throws {
        let fixture = try WorkspaceFixture()
        defer { fixture.remove() }
        try fixture.write("App.swift", "let value = 1\n")

        #expect(throws: CodexWorkspacePatchError.self) {
            _ = try fixture.runner.executeDetailed(
                name: "apply_patch",
                arguments: """
                *** Begin Patch
                *** Update File: App.swift
                @@
                -let missing = 1
                +let value = 2
                *** End Patch
                """,
                workspace: fixture.workspace
            )
        }

        #expect(try fixture.read("App.swift") == "let value = 1\n")
    }

    @Test
    func applyPatchRollsBackEveryPathWhenALaterWriteFails() throws {
        let fixture = try WorkspaceFixture()
        defer { fixture.remove() }
        try fixture.write("first.txt", "first-before\n")
        try fixture.write("move-source.txt", "move-before\n")
        try fixture.write("delete-source.txt", "delete-before\n")
        let firstBefore = try fixture.bytes("first.txt")
        let moveBefore = try fixture.bytes("move-source.txt")
        let deleteBefore = try fixture.bytes("delete-source.txt")
        let oversized = String(
            repeating: "x",
            count: CodexWorkspaceAccess.maximumReadableBytes + 1
        )

        #expect(throws: CodexWorkspaceAccessError.fileTooLarge) {
            _ = try fixture.runner.executeDetailed(
                name: "apply_patch",
                arguments: """
                *** Begin Patch
                *** Update File: first.txt
                @@
                -first-before
                +first-after
                *** Update File: move-source.txt
                *** Move to: move-target.txt
                @@
                -move-before
                +move-after
                *** Delete File: delete-source.txt
                *** Add File: too-large.txt
                +\(oversized)
                *** End Patch
                """,
                workspace: fixture.workspace
            )
        }

        #expect(try fixture.bytes("first.txt") == firstBefore)
        #expect(try fixture.bytes("move-source.txt") == moveBefore)
        #expect(try fixture.bytes("delete-source.txt") == deleteBefore)
        #expect(!fixture.exists("move-target.txt"))
        #expect(!fixture.exists("too-large.txt"))
    }

    @Test
    func applyPatchAddFileOverwritesExistingTargetLikeOfficialCodex() throws {
        let fixture = try WorkspaceFixture()
        defer { fixture.remove() }
        try fixture.write("existing.txt", "before\n")

        let result = try fixture.runner.executeDetailed(
            name: "apply_patch",
            arguments: """
            *** Begin Patch
            *** Add File: existing.txt
            +after
            *** End Patch
            """,
            workspace: fixture.workspace
        )

        #expect(try fixture.read("existing.txt") == "after\n")
        #expect(result.output.contains("A existing.txt"))
        #expect(
            result.workspaceDiff?
                .contains("--- a/existing.txt\n+++ b/existing.txt") == true
        )
    }

    @Test
    func applyPatchEndOfFileConstrainsTheFinalChunk() throws {
        let fixture = try WorkspaceFixture()
        defer { fixture.remove() }
        try fixture.write("values.txt", "same\nother\nsame\n")

        let result = try fixture.runner.executeDetailed(
            name: "apply_patch",
            arguments: """
            *** Begin Patch
            *** Update File: values.txt
            @@
            -same
            +last
            *** End of File
            *** End Patch
            """,
            workspace: fixture.workspace
        )

        #expect(try fixture.read("values.txt") == "same\nother\nlast\n")
        #expect(result.workspaceDiff?.contains("+last") == true)
    }

    @Test
    func applyPatchRequiresOfficialBoundariesAndAtLeastOneHunk() throws {
        let fixture = try WorkspaceFixture()
        defer { fixture.remove() }

        for patch in [
            "*** Add File: missing-boundaries.txt\n+bad\n",
            "*** Begin Patch\n*** End Patch\n",
        ] {
            #expect(throws: CodexWorkspacePatchError.self) {
                _ = try fixture.runner.executeDetailed(
                    name: "apply_patch",
                    arguments: patch,
                    workspace: fixture.workspace
                )
            }
        }
    }
}

private struct WorkspaceFixture {
    let root: URL
    let access: CodexWorkspaceAccess
    let workspace: Workspace
    let runner: CodexWorkspaceToolRunner

    init() throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "codex-apply-patch-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        let access = CodexWorkspaceAccess()
        self.root = root
        self.access = access
        workspace = Workspace(
            id: UUID(),
            displayName: "Patch fixture",
            rootBookmarkID: try access.bookmark(for: root)
        )
        runner = CodexWorkspaceToolRunner(access: access)
    }

    func write(_ relativePath: String, _ text: String) throws {
        try access.writeText(
            bookmark: workspace.rootBookmarkID!,
            relativePath: relativePath,
            text: text
        )
    }

    func read(_ relativePath: String) throws -> String {
        try access.readText(
            bookmark: workspace.rootBookmarkID!,
            relativePath: relativePath
        )
    }

    func bytes(_ relativePath: String) throws -> Data {
        try Data(contentsOf: root.appending(path: relativePath))
    }

    func exists(_ relativePath: String) -> Bool {
        FileManager.default.fileExists(
            atPath: root.appending(path: relativePath).path
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
