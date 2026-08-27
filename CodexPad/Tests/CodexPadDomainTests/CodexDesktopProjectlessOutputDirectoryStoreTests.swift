import Foundation
import Testing

@testable import CodexPadApplication

@Test
func projectlessOutputStoreAssociatesAndPersistsReleasedSplitPaths()
    throws
{
    let fixture = try ProjectlessOutputFixture()
    defer { fixture.remove() }
    let thread = try fixture.makeThread(
        name: "split-thread",
        withOutputs: true
    )
    let store = fixture.makeStore()

    #expect(
        store.recordCreatedPaths(
            cwd: thread.cwd.path,
            outputDirectory: try #require(thread.output).path,
            workspaceRoot: fixture.workspaceRoot.path
        )
    )
    #expect(
        store.associate(
            threadID: "thread-split",
            cwd: thread.cwd.path
        )
    )
    #expect(
        store.outputDirectories
            == ["thread-split": try #require(thread.output)]
    )

    let restored = fixture.makeStore()
    #expect(
        restored.outputDirectories
            == ["thread-split": try #require(thread.output)]
    )
}

@Test
func projectlessOutputStoreSupportsUnsplitAndLegacyDirectories()
    throws
{
    let fixture = try ProjectlessOutputFixture()
    defer { fixture.remove() }
    let unsplit = try fixture.makeThread(
        name: "unsplit-thread",
        withOutputs: false
    )
    let legacy = try fixture.makeThread(
        name: "legacy-thread",
        withOutputs: true
    )
    let store = fixture.makeStore()

    #expect(
        store.recordCreatedPaths(
            cwd: unsplit.cwd.path,
            outputDirectory: unsplit.cwd.path,
            workspaceRoot: fixture.workspaceRoot.path
        )
    )
    #expect(
        store.associate(
            threadID: "thread-unsplit",
            cwd: unsplit.cwd.path
        )
    )
    #expect(
        store.associate(
            threadID: "thread-legacy",
            cwd: legacy.cwd.path
        )
    )
    #expect(
        store.outputDirectories["thread-unsplit"]
            == unsplit.cwd
    )
    #expect(
        store.outputDirectories["thread-legacy"]
            == legacy.output
    )
}

@Test
func projectlessOutputStoreRejectsOutsideAndSymlinkPathsAndPrunesStale()
    throws
{
    let fixture = try ProjectlessOutputFixture()
    defer { fixture.remove() }
    let thread = try fixture.makeThread(
        name: "valid-thread",
        withOutputs: true
    )
    let outside = fixture.root.appendingPathComponent(
        "outside",
        isDirectory: true
    )
    try FileManager.default.createDirectory(
        at: outside,
        withIntermediateDirectories: true
    )
    let symlink = fixture.workspaceRoot.appendingPathComponent(
        "linked-thread",
        isDirectory: true
    )
    try FileManager.default.createSymbolicLink(
        at: symlink,
        withDestinationURL: outside
    )
    let store = fixture.makeStore()

    #expect(
        !store.recordCreatedPaths(
            cwd: outside.path,
            outputDirectory: outside.path,
            workspaceRoot: fixture.workspaceRoot.path
        )
    )
    #expect(
        !store.recordCreatedPaths(
            cwd: thread.cwd.path,
            outputDirectory: outside.path,
            workspaceRoot: fixture.workspaceRoot.path
        )
    )
    #expect(
        !store.recordCreatedPaths(
            cwd: symlink.path,
            outputDirectory: symlink.path,
            workspaceRoot: fixture.workspaceRoot.path
        )
    )
    #expect(
        store.recordCreatedPaths(
            cwd: thread.cwd.path,
            outputDirectory: try #require(thread.output).path,
            workspaceRoot: fixture.workspaceRoot.path
        )
    )
    #expect(
        store.associate(
            threadID: "thread-valid",
            cwd: thread.cwd.path
        )
    )

    try FileManager.default.removeItem(
        at: try #require(thread.output)
    )
    #expect(store.outputDirectories.isEmpty)
    let persisted = fixture.userDefaults.dictionary(
        forKey: fixture.persistenceKey
    ) as? [String: String]
    #expect(persisted?.isEmpty == true)
}

private final class ProjectlessOutputFixture:
    @unchecked Sendable
{
    struct ThreadPaths {
        let cwd: URL
        let output: URL?
    }

    let root: URL
    let workspaceRoot: URL
    let suiteName: String
    let persistenceKey: String
    let userDefaults: UserDefaults

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "projectless-output-\(UUID().uuidString)",
                isDirectory: true
            )
        workspaceRoot = root.appendingPathComponent(
            "Codex",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: workspaceRoot,
            withIntermediateDirectories: true
        )
        suiteName =
            "CodexDesktopProjectlessOutputDirectoryStoreTests."
            + UUID().uuidString
        persistenceKey = "projectless-output-test"
        userDefaults = try #require(
            UserDefaults(suiteName: suiteName)
        )
        userDefaults.removePersistentDomain(
            forName: suiteName
        )
    }

    func makeStore()
        -> CodexDesktopProjectlessOutputDirectoryStore
    {
        CodexDesktopProjectlessOutputDirectoryStore(
            workspaceRoot: workspaceRoot,
            userDefaults: userDefaults,
            persistenceKey: persistenceKey
        )
    }

    func makeThread(
        name: String,
        withOutputs: Bool
    ) throws -> ThreadPaths {
        let cwd = workspaceRoot
            .appendingPathComponent(
                "2026-08-05",
                isDirectory: true
            )
            .appendingPathComponent(
                name,
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: cwd,
            withIntermediateDirectories: true
        )
        guard withOutputs else {
            return ThreadPaths(cwd: cwd, output: nil)
        }
        let output = cwd.appendingPathComponent(
            "outputs",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: output,
            withIntermediateDirectories: false
        )
        return ThreadPaths(cwd: cwd, output: output)
    }

    func remove() {
        userDefaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: root)
    }
}
