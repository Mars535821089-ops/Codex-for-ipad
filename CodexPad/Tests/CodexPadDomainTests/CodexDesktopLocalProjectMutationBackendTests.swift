import Foundation
import Testing

@testable import CodexPadApplication
@testable import CodexPadDomain

private typealias LocalProjectValue = CodexDesktopAppHostRPC.Value

@MainActor
@Test
func localProjectBackendCreatesDefaultWorkspaceAndSelectsIt() async throws {
    let fixture = LocalProjectMutationFixture()
    let backend = fixture.makeBackend()

    let response = try await backend.handle(
        method: "create",
        request: .object([
            "appearance": .object([
                "color": .string("blue"),
                "marker": .object([
                    "kind": .string("emoji"),
                    "emoji": .string("🚀"),
                ]),
            ]),
            "initializeDefaultWorkspaceGitRepository": .bool(true),
            "name": .string("  Launch Pad  "),
            "sources": .array([]),
        ])
    )

    guard case let .object(fields) = response,
          case let .string(projectID)? = fields["projectId"],
          case let .array(rootValues)? = fields["rootPaths"]
    else {
        Issue.record("Expected released localProjects.create response")
        return
    }
    #expect(rootValues == [.string(fixture.defaultRoot.path)])
    #expect(fixture.defaultRequests.count == 1)
    #expect(fixture.defaultRequests.first?.0 == "Launch Pad")
    #expect(fixture.defaultRequests.first?.1 == true)
    #expect(fixture.createdWorkspaces.count == 1)
    #expect(fixture.createdWorkspaces.first?.displayName == "Launch Pad")
    #expect(
        fixture.createdWorkspaces.first?.rootBookmarkID
            == "bookmark:\(fixture.defaultRoot.path)"
    )
    #expect(
        fixture.selectedWorkspaceIDs
            == [UUID(uuidString: projectID)]
    )
    #expect(fixture.appearanceProjectIDs == [projectID])
    #expect(fixture.publishCount == 1)
    #expect(
        fixture.stateStore.project(projectID: projectID)?.rootPaths
            == [fixture.defaultRoot.path]
    )
}

@MainActor
@Test
func localProjectBackendPreservesOrderedMultiRootSources() async throws {
    let fixture = LocalProjectMutationFixture()
    let backend = fixture.makeBackend()
    let first = fixture.root.appendingPathComponent("One", isDirectory: true)
    let second = fixture.root.appendingPathComponent("Two", isDirectory: true)

    let response = try await backend.handle(
        method: "create",
        request: .object([
            "appearance": .null,
            "initializeDefaultWorkspaceGitRepository": .bool(false),
            "name": .string(""),
            "sources": .array([
                .string(first.path),
                .string(second.path),
                .string(first.path),
            ]),
        ])
    )

    guard case let .object(fields) = response,
          case let .string(projectID)? = fields["projectId"]
    else {
        Issue.record("Expected create response")
        return
    }
    #expect(fixture.defaultRequests.isEmpty)
    #expect(
        fixture.stateStore.project(projectID: projectID)?.rootPaths
            == [first.path, second.path]
    )
    #expect(fixture.createdWorkspaces.first?.displayName == "One")
    #expect(
        fixture.createdWorkspaces.first?.rootBookmarkID
            == "bookmark:\(first.path)"
    )
    #expect(fixture.appearanceProjectIDs.isEmpty)
}

@MainActor
@Test
func localProjectBackendMatchesEditRenameAndUpsertDistinctions()
    async throws
{
    let fixture = LocalProjectMutationFixture()
    let existingID = UUID()
    let existingPath = fixture.root.appendingPathComponent(
        "Existing",
        isDirectory: true
    ).path
    fixture.seed(
        workspace: Workspace(
            id: existingID,
            displayName: "Existing",
            rootBookmarkID: "bookmark:\(existingPath)"
        ),
        rootPaths: [existingPath]
    )
    let backend = fixture.makeBackend()

    _ = try await backend.handle(
        method: "edit",
        request: .object([
            "projectId": .string(existingID.uuidString.lowercased()),
            "name": .string("   "),
            "sources": .array([]),
        ])
    )
    #expect(
        fixture.stateStore.project(
            projectID: existingID.uuidString.lowercased()
        )?.name == "Existing"
    )
    #expect(
        fixture.updatedWorkspaces.last?.rootBookmarkID == nil
    )

    _ = try await backend.handle(
        method: "rename",
        request: .object([
            "projectId": .string(existingID.uuidString.lowercased()),
            "name": .string("Renamed"),
        ])
    )
    #expect(fixture.updatedWorkspaces.last?.displayName == "Renamed")

    let importedID = UUID().uuidString.lowercased()
    _ = try await backend.handle(
        method: "upsert",
        request: .object([
            "projectId": .string(importedID),
            "name": .string(""),
            "sources": .array([]),
        ])
    )
    #expect(
        fixture.stateStore.project(projectID: importedID)?.name == ""
    )
    #expect(fixture.createdWorkspaces.last?.id == UUID(uuidString: importedID))
    #expect(
        fixture.stateStore.globalStateSnapshot()["project-order"]
            == .array([.string(existingID.uuidString.lowercased())])
    )

    _ = try await backend.handle(
        method: "edit",
        request: .object([
            "projectId": .string("missing"),
            "name": .string("Ignored"),
            "sources": .array([.string(existingPath)]),
        ])
    )
    #expect(fixture.stateStore.project(projectID: "missing") == nil)
}

@MainActor
@Test
func localProjectBackendRemovesMetadataWithoutDeletingReferencedThread()
    async throws
{
    let fixture = LocalProjectMutationFixture()
    let workspaceID = UUID()
    let path = fixture.root.appendingPathComponent(
        "Referenced",
        isDirectory: true
    ).path
    fixture.seed(
        workspace: Workspace(
            id: workspaceID,
            displayName: "Referenced",
            rootBookmarkID: "bookmark:\(path)"
        ),
        rootPaths: [path]
    )
    fixture.threads = [
        CodexThread(
            id: UUID(),
            workspaceID: workspaceID,
            title: "Keep this thread"
        ),
    ]
    let backend = fixture.makeBackend()

    _ = try await backend.handle(
        method: "remove",
        request: .string(workspaceID.uuidString.lowercased())
    )

    #expect(
        fixture.stateStore.project(
            projectID: workspaceID.uuidString.lowercased()
        ) == nil
    )
    #expect(fixture.removedWorkspaceIDs.isEmpty)
    #expect(fixture.selectedWorkspaceIDs.isEmpty)
    #expect(fixture.publishCount == 1)
}

@MainActor
@Test
func localProjectBackendRemovesUnusedCoreWorkspaceAndRejectsRelativeRoot()
    async throws
{
    let fixture = LocalProjectMutationFixture()
    let workspaceID = UUID()
    let path = fixture.root.appendingPathComponent(
        "Unused",
        isDirectory: true
    ).path
    fixture.seed(
        workspace: Workspace(
            id: workspaceID,
            displayName: "Unused",
            rootBookmarkID: "bookmark:\(path)"
        ),
        rootPaths: [path]
    )
    let backend = fixture.makeBackend()

    _ = try await backend.handle(
        method: "remove",
        request: .string(workspaceID.uuidString.lowercased())
    )
    #expect(fixture.removedWorkspaceIDs == [workspaceID])

    await #expect(
        throws: CodexDesktopLocalProjectMutationBackend.Error
            .invalidRootPath("relative/path")
    ) {
        _ = try await backend.handle(
            method: "create",
            request: .object([
                "appearance": .null,
                "initializeDefaultWorkspaceGitRepository": .bool(false),
                "name": .string("Invalid"),
                "sources": .array([.string("relative/path")]),
            ])
        )
    }
}

@MainActor
private final class LocalProjectMutationFixture {
    let root: URL
    let defaultRoot: URL
    let stateStore: CodexDesktopLocalProjectsStateStore
    var workspaces: [Workspace] = []
    var threads: [CodexThread] = []
    var createdWorkspaces: [Workspace] = []
    var updatedWorkspaces: [Workspace] = []
    var removedWorkspaceIDs: [UUID] = []
    var selectedWorkspaceIDs: [UUID?] = []
    var appearanceProjectIDs: [String] = []
    var defaultRequests: [(String, Bool)] = []
    var publishCount = 0

    init() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "CodexLocalProjectBackendTests-\(UUID().uuidString)",
            isDirectory: true
        )
        defaultRoot = root.appendingPathComponent(
            "Launch Pad",
            isDirectory: true
        )
        let defaults = UserDefaults(
            suiteName: "CodexLocalProjectBackendTests-\(UUID().uuidString)"
        )!
        stateStore = CodexDesktopLocalProjectsStateStore(
            userDefaults: defaults,
            nowMilliseconds: { 1_754_300_000_000 }
        )
    }

    func seed(workspace: Workspace, rootPaths: [String]) {
        workspaces.append(workspace)
        _ = stateStore.createProject(
            projectID: workspace.id.uuidString.lowercased(),
            name: workspace.displayName,
            rootPaths: rootPaths
        )
    }

    func makeBackend() -> CodexDesktopLocalProjectMutationBackend {
        CodexDesktopLocalProjectMutationBackend(
            stateStore: stateStore,
            workspaceSnapshot: { [unowned self] in workspaces },
            threadSnapshot: { [unowned self] in threads },
            createWorkspace: { [unowned self] workspace in
                createdWorkspaces.append(workspace)
                workspaces.append(workspace)
            },
            updateWorkspace: { [unowned self] workspace in
                updatedWorkspaces.append(workspace)
                if let index = workspaces.firstIndex(
                    where: { $0.id == workspace.id }
                ) {
                    workspaces[index] = workspace
                }
            },
            removeWorkspace: { [unowned self] workspaceID in
                removedWorkspaceIDs.append(workspaceID)
                workspaces.removeAll { $0.id == workspaceID }
            },
            bookmark: { url in "bookmark:\(url.path)" },
            createDefaultWorkspace: {
                [unowned self] name, initializeGit in
                defaultRequests.append((name, initializeGit))
                return defaultRoot
            },
            selectWorkspace: { [unowned self] id in
                selectedWorkspaceIDs.append(id)
            },
            persistAppearance: { [unowned self] projectID, _ in
                appearanceProjectIDs.append(projectID)
            },
            publishStateChange: { [unowned self] in
                publishCount += 1
            }
        )
    }
}
