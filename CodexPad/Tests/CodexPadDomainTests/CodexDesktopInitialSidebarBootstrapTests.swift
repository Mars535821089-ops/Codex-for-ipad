import CodexPadApplication
import CodexPadDomain
import Foundation
import Testing

@Test
func initialSidebarBootstrapContainsReleasedShapeAndLocalState() {
    let workspaceID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
    let threadID = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
    let state = CodexSessionState(
        workspaces: [
            Workspace(
                id: workspaceID,
                displayName: "Project",
                rootBookmarkID: "/tmp/project"
            ),
        ],
        threads: [
            CodexThread(
                id: threadID,
                workspaceID: workspaceID,
                title: "A thread"
            ),
        ]
    )

    let bootstrap = CodexDesktopInitialSidebarBootstrap.make(
        state: state,
        persistedAtoms: ["project-appearances": .object([:])],
        selectedProject: .object([
            "type": .string("local"),
            "projectId": .string(workspaceID.uuidString.lowercased()),
        ]),
        pinnedThreadIDs: [threadID.uuidString.lowercased()],
        threadProjectAssignments: .object([:]),
        localProjects: [workspaceID.uuidString.lowercased(): .object([:])],
        projectOrder: [workspaceID.uuidString.lowercased()]
    )

    guard case let .object(fields) = bootstrap else {
        Issue.record("bootstrap must be an object")
        return
    }
    guard case let .array(catalogEntries)? = fields["catalogEntries"] else {
        Issue.record("catalogEntries missing")
        return
    }
    #expect(catalogEntries.count == 1)
    #expect(fields["catalogHostIds"] == .array([.string("local")]))
    #expect(fields["workspaceRootOptions"] == .object([
        "roots": .array([.string("/tmp/project")]),
        "labels": .object(["/tmp/project": .string("Project")]),
    ]))
    #expect(fields["projectlessWorkspaceRoot"] == .object([
        "workspaceRoot": .string(""),
    ]))
    if case let .object(entry) = catalogEntries[0] {
        #expect(entry["hostId"] == .string("local"))
        #expect(entry["threadId"] == .string(threadID.uuidString.lowercased()))
        #expect(entry["displayTitle"] == .string("A thread"))
        #expect(entry["sourceCreatedAt"] == .integer(0))
        #expect(entry["sourceUpdatedAt"] == .integer(0))
        #expect(entry["sourceRecencyAt"] == .integer(0))
        #expect(entry["cwd"] == .string("/tmp/project"))
        #expect(entry["sourceKind"] == .string("appServer"))
        #expect(entry["sourceDetail"] == .null)
        #expect(entry["threadSource"] == .null)
        #expect(entry["modelProvider"] == .string(""))
        #expect(entry["gitBranch"] == .null)
        #expect(entry["host_id"] == nil)
        #expect(entry["thread_id"] == nil)
        #expect(entry["display_title"] == nil)
        #expect(entry["source_kind"] == nil)
    } else {
        Issue.record("catalog entry must be an object")
    }
    guard case let .array(globalStateEntries)? = fields["globalStateEntries"] else {
        Issue.record("globalStateEntries missing")
        return
    }
    #expect(globalStateEntries.count == CodexDesktopInitialSidebarBootstrap.globalStateKeys.count)
}

@Test
func initialSidebarBootstrapIsSafeForAnonymousEmptyState() {
    let bootstrap = CodexDesktopInitialSidebarBootstrap.make(
        state: CodexSessionState(),
        persistedAtoms: [:],
        selectedProject: nil,
        pinnedThreadIDs: [],
        threadProjectAssignments: .object([:])
    )
    guard case let .object(fields) = bootstrap else {
        Issue.record("bootstrap must be an object")
        return
    }
    #expect(fields["catalogEntries"] == .array([]))
    #expect(fields["catalogHostIds"] == .array([.string("local")]))
}

@Test
func initialSidebarBootstrapDeduplicatesRepeatedWorkspaceRoots() {
    let firstWorkspaceID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
    let secondWorkspaceID = UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!
    let state = CodexSessionState(
        workspaces: [
            Workspace(
                id: firstWorkspaceID,
                displayName: "First label",
                rootBookmarkID: "/tmp/shared"
            ),
            Workspace(
                id: secondWorkspaceID,
                displayName: "Second label",
                rootBookmarkID: "/tmp/shared"
            ),
        ]
    )

    let bootstrap = CodexDesktopInitialSidebarBootstrap.make(
        state: state,
        persistedAtoms: [:],
        selectedProject: nil,
        pinnedThreadIDs: [],
        threadProjectAssignments: .object([:])
    )

    guard case let .object(fields) = bootstrap,
          case let .object(options)? = fields["workspaceRootOptions"] else {
        Issue.record("workspaceRootOptions must be an object")
        return
    }
    #expect(options["roots"] == .array([.string("/tmp/shared")]))
    #expect(options["labels"] == .object([
        "/tmp/shared": .string("First label"),
    ]))
}

@Test
func initialSidebarBootstrapCarriesPersistedProjectRootsWhenWorkspacesAreEmpty() {
    let root = "/tmp/persisted-project"
    let bootstrap = CodexDesktopInitialSidebarBootstrap.make(
        state: CodexSessionState(),
        persistedAtoms: [:],
        selectedProject: nil,
        pinnedThreadIDs: [],
        threadProjectAssignments: .object([:]),
        localProjects: [
            "project-1": .object([
                "id": .string("project-1"),
                "name": .string("Persisted Project"),
                "rootPaths": .array([.string(root)]),
            ]),
        ]
    )

    guard case let .object(fields) = bootstrap,
          case let .object(options)? = fields["workspaceRootOptions"] else {
        Issue.record("workspaceRootOptions must be an object")
        return
    }
    #expect(options["roots"] == .array([.string(root)]))
    #expect(options["labels"] == .object([
        root: .string("Persisted Project"),
    ]))
}
