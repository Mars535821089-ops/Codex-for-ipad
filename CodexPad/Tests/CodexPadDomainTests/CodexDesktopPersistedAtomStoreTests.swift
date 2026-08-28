import CodexPadDomain
import Foundation
import Testing

@testable import CodexPadApplication

@Test
func persistedAtomStoreUsesTheReleasedStorageKeyAndRoundTripsValues() {
    let suiteName = "CodexDesktopPersistedAtomStoreTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer {
        defaults.removePersistentDomain(forName: suiteName)
    }

    let first = CodexDesktopPersistedAtomStore(userDefaults: defaults)
    #expect(first.snapshot.isEmpty)
    _ = first.update(key: "sidebar.open", value: .bool(true))
    _ = first.update(
        key: "composer.draft",
        value: .object(["text": .string("hello")])
    )

    let second = CodexDesktopPersistedAtomStore(userDefaults: defaults)
    #expect(
        second.snapshot == [
            "sidebar.open": .bool(true),
            "composer.draft": .object(["text": .string("hello")]),
        ]
    )
}

@Test
func persistedAtomStoreDeletesValuesWhenRendererSendsUndefined() {
    let suiteName = "CodexDesktopPersistedAtomStoreTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer {
        defaults.removePersistentDomain(forName: suiteName)
    }

    let store = CodexDesktopPersistedAtomStore(userDefaults: defaults)
    _ = store.update(key: "one", value: .integer(1))
    _ = store.update(key: "one", value: nil)
    _ = store.update(key: "", value: .string("ignored"))

    #expect(store.snapshot.isEmpty)
}

@Test
func persistedAtomStoreRecoversFromMalformedStorageWithoutInventingState() {
    let suiteName = "CodexDesktopPersistedAtomStoreTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer {
        defaults.removePersistentDomain(forName: suiteName)
    }
    defaults.set(Data("not-json".utf8), forKey:
        CodexDesktopPersistedAtomStore.releasedStorageKey)

    let store = CodexDesktopPersistedAtomStore(userDefaults: defaults)
    #expect(store.snapshot.isEmpty)
}

@Test
func pinnedThreadStorePreservesReleasedOrderAcrossRelaunches() {
    let suiteName =
        "CodexDesktopPinnedThreadStoreTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer {
        defaults.removePersistentDomain(forName: suiteName)
    }
    let first = CodexDesktopPinnedThreadStore(userDefaults: defaults)

    #expect(first.setPinned(threadID: "thread-a", pinned: true))
    #expect(first.setPinned(threadID: "thread-c", pinned: true))
    #expect(
        first.setPinned(
            threadID: "thread-b",
            pinned: true,
            beforeThreadID: "thread-c"
        )
    )
    #expect(
        first.threadIDs == ["thread-a", "thread-b", "thread-c"]
    )
    #expect(
        first.globalStateValue == .array([
            .string("thread-a"),
            .string("thread-b"),
            .string("thread-c"),
        ])
    )

    let second = CodexDesktopPinnedThreadStore(userDefaults: defaults)
    #expect(
        second.threadIDs == ["thread-a", "thread-b", "thread-c"]
    )
}

@Test
func pinnedThreadStoreMovesUnpinsAndDeduplicatesRendererOrders() {
    let suiteName =
        "CodexDesktopPinnedThreadMutationTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer {
        defaults.removePersistentDomain(forName: suiteName)
    }
    let store = CodexDesktopPinnedThreadStore(userDefaults: defaults)

    #expect(
        store.setOrder(
            threadIDs: [
                "thread-a",
                "thread-b",
                "thread-a",
                "",
                "thread-c",
            ]
        )
    )
    #expect(store.threadIDs == ["thread-a", "thread-b", "thread-c"])

    #expect(
        store.setPinned(
            threadID: "thread-c",
            pinned: true,
            beforeThreadID: "thread-a"
        )
    )
    #expect(store.threadIDs == ["thread-c", "thread-a", "thread-b"])

    #expect(store.setPinned(threadID: "thread-a", pinned: false))
    #expect(store.threadIDs == ["thread-c", "thread-b"])
    #expect(!store.setPinned(threadID: "", pinned: true))
}

@Test
func pinnedThreadStoreRecoversFromMalformedStorage() {
    let suiteName =
        "CodexDesktopPinnedThreadMalformedTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer {
        defaults.removePersistentDomain(forName: suiteName)
    }
    defaults.set(
        Data("not-json".utf8),
        forKey: CodexDesktopPinnedThreadStore.releasedStorageKey
    )

    let store = CodexDesktopPinnedThreadStore(userDefaults: defaults)
    #expect(store.threadIDs.isEmpty)
    #expect(store.globalStateValue == .array([]))
}

@Test
func selectedProjectStoreSurvivesRelaunchAndUsesReleasedGlobalStateShape() {
    let suiteName =
        "CodexDesktopSelectedProjectStoreTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer {
        defaults.removePersistentDomain(forName: suiteName)
    }
    let selectedID = UUID()
    let first = CodexDesktopSelectedProjectStore(
        userDefaults: defaults
    )

    first.setSelectedWorkspaceID(selectedID)

    let second = CodexDesktopSelectedProjectStore(
        userDefaults: defaults
    )
    #expect(second.selectedWorkspaceID == selectedID)
    #expect(
        second.globalStateValue == .object([
            "type": .string("local"),
            "projectId": .string(
                selectedID.uuidString.lowercased()
            ),
        ])
    )

    second.setSelectedWorkspaceID(nil)
    #expect(
        defaults.object(
            forKey:
                CodexDesktopSelectedProjectStore.releasedStorageKey
        ) == nil
    )
}

@Test
func selectedProjectStoreRejectsMalformedAndStaleWorkspaceSelections() {
    let suiteName =
        "CodexDesktopSelectedProjectStoreInvalidTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer {
        defaults.removePersistentDomain(forName: suiteName)
    }
    defaults.set(
        Data("not-json".utf8),
        forKey:
            CodexDesktopSelectedProjectStore.releasedStorageKey
    )
    let malformed = CodexDesktopSelectedProjectStore(
        userDefaults: defaults
    )
    #expect(malformed.selectedWorkspaceID == nil)

    let staleID = UUID()
    malformed.setSelectedWorkspaceID(staleID)
    #expect(
        malformed.restoreSelection(
            from: [
                Workspace(
                    id: UUID(),
                    displayName: "Current",
                    rootBookmarkID: "bookmark"
                )
            ]
        ) == nil
    )
    #expect(malformed.selectedWorkspaceID == nil)
}

@Test
func selectedProjectStorePrefersAnExplicitStartupSelectionOverRestoredState() {
    let suiteName =
        "CodexDesktopSelectedProjectStartupTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer {
        defaults.removePersistentDomain(forName: suiteName)
    }
    let restoredWorkspace = Workspace(
        id: UUID(),
        displayName: "Restored",
        rootBookmarkID: "restored-bookmark"
    )
    let startupWorkspace = Workspace(
        id: UUID(),
        displayName: "Parity Git Workspace",
        rootBookmarkID: "startup-bookmark"
    )
    let store = CodexDesktopSelectedProjectStore(userDefaults: defaults)
    store.setSelectedWorkspaceID(restoredWorkspace.id)

    let resolved = store.resolveInitialSelection(
        preferredWorkspaceID: startupWorkspace.id,
        from: [restoredWorkspace, startupWorkspace]
    )

    #expect(resolved == startupWorkspace.id)
    #expect(store.selectedWorkspaceID == startupWorkspace.id)
}

@Test
func localProjectsStateStoreBuildsReleasedShapeAndPersistsMetadata() {
    let suiteName =
        "CodexDesktopLocalProjectsStateStoreTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer {
        defaults.removePersistentDomain(forName: suiteName)
    }
    let firstID = UUID()
    var now: Int64 = 1_754_000_000_000
    let first = CodexDesktopLocalProjectsStateStore(
        userDefaults: defaults,
        nowMilliseconds: { now }
    )

    let initial = first.synchronize(
        workspaces: [
            Workspace(
                id: firstID,
                displayName: "CodexPad",
                rootBookmarkID: "bookmark-one"
            )
        ],
        rootPath: { workspace in
            workspace.rootBookmarkID == "bookmark-one"
                ? "/private/Workspace/CodexPad"
                : nil
        }
    )

    let firstKey = firstID.uuidString.lowercased()
    #expect(
        initial == [
            "local-projects": .object([
                firstKey: .object([
                    "id": .string(firstKey),
                    "name": .string("CodexPad"),
                    "rootPaths": .array([
                        .string("/private/Workspace/CodexPad")
                    ]),
                    "createdAt": .integer(1_754_000_000_000),
                    "updatedAt": .integer(1_754_000_000_000),
                ])
            ]),
            "project-order": .array([.string(firstKey)]),
        ]
    )

    now = 1_754_000_001_000
    let second = CodexDesktopLocalProjectsStateStore(
        userDefaults: defaults,
        nowMilliseconds: { now }
    )
    let relaunched = second.synchronize(
        workspaces: [
            Workspace(
                id: firstID,
                displayName: "Codex for ipad",
                rootBookmarkID: "bookmark-one"
            )
        ],
        rootPath: { _ in "/private/Workspace/CodexPad" }
    )
    #expect(
        relaunched["local-projects"] == .object([
            firstKey: .object([
                "id": .string(firstKey),
                "name": .string("Codex for ipad"),
                "rootPaths": .array([
                    .string("/private/Workspace/CodexPad")
                ]),
                "createdAt": .integer(1_754_000_000_000),
                "updatedAt": .integer(1_754_000_001_000),
            ])
        ])
    )
}

@Test
func localProjectsStateStoreRefreshesCoreRootAfterContainerMigration() {
    let suiteName =
        "CodexDesktopLocalProjectsRootMigrationTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer {
        defaults.removePersistentDomain(forName: suiteName)
    }
    let workspaceID = UUID()
    let projectID = workspaceID.uuidString.lowercased()
    let workspace = Workspace(
        id: workspaceID,
        displayName: "Parity Git Workspace",
        rootBookmarkID: "parity-bookmark"
    )
    var now: Int64 = 1_754_050_000_000
    let store = CodexDesktopLocalProjectsStateStore(
        userDefaults: defaults,
        nowMilliseconds: { now }
    )

    _ = store.synchronize(
        workspaces: [workspace],
        rootPath: { _ in "/old-container/Parity Git Workspace" }
    )
    now += 1_000
    let migrated = store.synchronize(
        workspaces: [workspace],
        rootPath: { _ in "/new-container/Parity Git Workspace" }
    )

    #expect(
        migrated["local-projects"] == .object([
            projectID: .object([
                "id": .string(projectID),
                "name": .string("Parity Git Workspace"),
                "rootPaths": .array([
                    .string("/new-container/Parity Git Workspace")
                ]),
                "createdAt": .integer(1_754_050_000_000),
                "updatedAt": .integer(1_754_050_001_000),
            ])
        ])
    )
}

@Test
func localProjectsStateStorePrependsNewProjectsAndRemovesStaleOnes() {
    let suiteName =
        "CodexDesktopLocalProjectsOrderTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer {
        defaults.removePersistentDomain(forName: suiteName)
    }
    let firstID = UUID()
    let secondID = UUID()
    var now: Int64 = 1_754_100_000_000
    let store = CodexDesktopLocalProjectsStateStore(
        userDefaults: defaults,
        nowMilliseconds: { now }
    )
    let first = Workspace(
        id: firstID,
        displayName: "First",
        rootBookmarkID: "first"
    )
    let second = Workspace(
        id: secondID,
        displayName: "Second",
        rootBookmarkID: "second"
    )
    let roots: [String: String] = [
        "first": "/private/First",
        "second": "/private/Second",
    ]

    _ = store.synchronize(
        workspaces: [first],
        rootPath: { workspace in
            workspace.rootBookmarkID.flatMap { roots[$0] }
        }
    )
    now += 1_000
    let added = store.synchronize(
        workspaces: [first, second],
        rootPath: { workspace in
            workspace.rootBookmarkID.flatMap { roots[$0] }
        }
    )
    #expect(
        added["project-order"] == .array([
            .string(secondID.uuidString.lowercased()),
            .string(firstID.uuidString.lowercased()),
        ])
    )

    let removed = store.synchronize(
        workspaces: [second],
        rootPath: { workspace in
            workspace.rootBookmarkID.flatMap { roots[$0] }
        }
    )
    #expect(
        removed["project-order"] == .array([
            .string(secondID.uuidString.lowercased())
        ])
    )
    guard case let .object(projects)? = removed["local-projects"] else {
        Issue.record("Expected released local-projects object")
        return
    }
    #expect(
        Set(projects.keys) == [secondID.uuidString.lowercased()]
    )
}

@Test
func localProjectsStateStoreIncludesOnlyACoherentSelectedProject() {
    let suiteName =
        "CodexDesktopProjectGlobalStateTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer {
        defaults.removePersistentDomain(forName: suiteName)
    }
    let workspaceID = UUID()
    let workspace = Workspace(
        id: workspaceID,
        displayName: "Selected",
        rootBookmarkID: "bookmark"
    )
    let store = CodexDesktopLocalProjectsStateStore(
        userDefaults: defaults,
        nowMilliseconds: { 1_754_200_000_000 }
    )
    let selected = CodexJSONValue.object([
        "type": .string("local"),
        "projectId": .string(
            workspaceID.uuidString.lowercased()
        ),
    ])

    let coherent = store.synchronize(
        workspaces: [workspace],
        selectedProject: selected,
        rootPath: { _ in "/private/Selected" }
    )
    #expect(coherent["selected-project"] == selected)

    let stale = store.synchronize(
        workspaces: [workspace],
        selectedProject: .object([
            "type": .string("local"),
            "projectId": .string(UUID().uuidString.lowercased()),
        ]),
        rootPath: { _ in "/private/Selected" }
    )
    #expect(stale["selected-project"] == nil)
}

@Test
func localProjectsStateStoreCreatesAndEditsSendableRecordsWithDesktopTimestamps() {
    let suiteName =
        "CodexDesktopLocalProjectsMutationTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer {
        defaults.removePersistentDomain(forName: suiteName)
    }
    var now: Int64 = 1_754_300_000_000
    let store = CodexDesktopLocalProjectsStateStore(
        userDefaults: defaults,
        nowMilliseconds: { now }
    )

    let created = store.createProject(
        projectID: "caller-id",
        name: "  Project  ",
        rootPaths: ["/one", "/two", "/one", " ", ""]
    )
    #expect(created.id == "caller-id")
    #expect(created.name == "Project")
    #expect(created.rootPaths == ["/one", "/two", " ", ""])
    #expect(created.createdAt == 1_754_300_000_000)
    #expect(created.updatedAt == 1_754_300_000_000)
    #expect(
        store.globalStateSnapshot()["project-order"]
            == .array([.string("caller-id")])
    )
    _ = store.upsertProject(
        projectID: "unlisted-import",
        name: "Imported",
        rootPaths: ["/imported"]
    )
    #expect(
        store.projectsInOrder.map(\.id)
            == ["caller-id", "unlisted-import"]
    )

    now += 1_000
    let edited = store.editProject(
        projectID: "caller-id",
        name: " \t",
        rootPaths: ["/three", "/three", "/four"]
    )
    #expect(edited?.name == "Project")
    #expect(edited?.rootPaths == ["/three", "/four"])
    #expect(edited?.createdAt == created.createdAt)
    #expect(edited?.updatedAt == 1_754_300_001_000)
    #expect(
        store.editProject(
            projectID: "missing",
            name: "Missing",
            rootPaths: ["/missing"]
        ) == nil
    )
}

@Test
func localProjectsStateStoreAppliesRenameRemoveAndUpsertNoOpRules() {
    let suiteName =
        "CodexDesktopLocalProjectsNoOpTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer {
        defaults.removePersistentDomain(forName: suiteName)
    }
    var now: Int64 = 1_754_400_000_000
    let store = CodexDesktopLocalProjectsStateStore(
        userDefaults: defaults,
        nowMilliseconds: { now }
    )

    let upserted = store.upsertProject(
        projectID: "upsert-id",
        name: "  Upserted  ",
        rootPaths: []
    )
    #expect(upserted.name == "Upserted")
    #expect(upserted.rootPaths.isEmpty)
    #expect(store.globalStateSnapshot()["project-order"] == .array([]))
    #expect(store.projectsInOrder == [upserted])

    now += 1_000
    #expect(store.renameProject(projectID: "upsert-id", name: "Renamed"))
    #expect(store.project(projectID: "upsert-id")?.name == "Renamed")
    #expect(!store.renameProject(projectID: "upsert-id", name: " Renamed "))
    #expect(!store.renameProject(projectID: "upsert-id", name: " \t"))
    #expect(!store.renameProject(projectID: "missing", name: "New"))

    now += 1_000
    let edited = store.upsertProject(
        projectID: "upsert-id",
        name: "  ",
        rootPaths: ["/root", "/root"]
    )
    #expect(edited.name == "Renamed")
    #expect(edited.rootPaths == ["/root"])
    #expect(edited.updatedAt == 1_754_400_002_000)

    #expect(!store.removeProject(projectID: "missing"))
    #expect(store.removeProject(projectID: "upsert-id"))
    #expect(store.project(projectID: "upsert-id") == nil)
    #expect(store.globalStateSnapshot()["project-order"] == .array([]))
}

@Test
func localProjectsStateStoreRemovesOnlyExactNamedProjectsAndPersists() {
    let suiteName =
        "CodexDesktopLocalProjectsExactNameRemovalTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer {
        defaults.removePersistentDomain(forName: suiteName)
    }
    let store = CodexDesktopLocalProjectsStateStore(
        userDefaults: defaults,
        nowMilliseconds: { 1_754_425_000_000 }
    )
    _ = store.createProject(
        projectID: "fixture-one",
        name: "Parity Git Workspace",
        rootPaths: ["/fixture-one"]
    )
    _ = store.createProject(
        projectID: "fixture-two",
        name: "Parity Git Workspace",
        rootPaths: ["/fixture-two"]
    )
    _ = store.createProject(
        projectID: "user-project",
        name: "Parity Git Workspace Personal",
        rootPaths: ["/user"]
    )

    #expect(
        store.removeProjects(namedExactly: "Parity Git Workspace") == 2
    )
    #expect(store.projectsInOrder.map(\.id) == ["user-project"])
    #expect(
        store.removeProjects(namedExactly: "Parity Git Workspace") == 0
    )

    let relaunched = CodexDesktopLocalProjectsStateStore(
        userDefaults: defaults
    )
    #expect(relaunched.projectsInOrder.map(\.id) == ["user-project"])
    #expect(
        relaunched.synchronize(
            workspaces: [],
            rootPath: { _ in nil }
        )["local-projects"] == .object([
            "user-project": .object([
                "id": .string("user-project"),
                "name": .string("Parity Git Workspace Personal"),
                "rootPaths": .array([.string("/user")]),
                "createdAt": .integer(1_754_425_000_000),
                "updatedAt": .integer(1_754_425_000_000),
            ])
        ])
    )
}

@Test
func localProjectsStateStorePreservesExplicitMissingUpsertsAcrossSynchronization() {
    let suiteName =
        "CodexDesktopLocalProjectsExplicitUpsertTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer {
        defaults.removePersistentDomain(forName: suiteName)
    }
    let projectID = "caller-owned:rootless"
    let store = CodexDesktopLocalProjectsStateStore(
        userDefaults: defaults,
        nowMilliseconds: { 1_754_450_000_000 }
    )

    let upserted = store.upsertProject(
        projectID: projectID,
        name: " Rootless ",
        rootPaths: []
    )
    let afterSynchronization = store.synchronize(
        workspaces: [],
        rootPath: { _ in nil }
    )
    #expect(
        afterSynchronization["local-projects"] == .object([
            projectID: .object([
                "id": .string(projectID),
                "name": .string("Rootless"),
                "rootPaths": .array([]),
                "createdAt": .integer(1_754_450_000_000),
                "updatedAt": .integer(1_754_450_000_000),
            ])
        ])
    )
    #expect(afterSynchronization["project-order"] == .array([]))
    #expect(store.project(projectID: projectID) == upserted)

    let relaunched = CodexDesktopLocalProjectsStateStore(
        userDefaults: defaults,
        nowMilliseconds: { 1_754_450_001_000 }
    )
    let afterRelaunch = relaunched.synchronize(
        workspaces: [],
        rootPath: { _ in nil }
    )
    #expect(afterRelaunch == afterSynchronization)
    #expect(relaunched.project(projectID: projectID) == upserted)
    #expect(relaunched.projectsInOrder == [upserted])
}

@Test
func localProjectsStateStoreSynchronizePreservesExplicitMultiRootMetadata() {
    let suiteName =
        "CodexDesktopLocalProjectsMultiRootTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer {
        defaults.removePersistentDomain(forName: suiteName)
    }
    let workspaceID = UUID()
    var now: Int64 = 1_754_500_000_000
    let store = CodexDesktopLocalProjectsStateStore(
        userDefaults: defaults,
        nowMilliseconds: { now }
    )
    let workspace = Workspace(
        id: workspaceID,
        displayName: "Seed",
        rootBookmarkID: "seed"
    )

    _ = store.createProject(
        projectID: workspaceID.uuidString.lowercased(),
        name: "Explicit",
        rootPaths: ["/one", "/two"]
    )
    now += 1_000
    let snapshot = store.synchronize(
        workspaces: [
            Workspace(
                id: workspace.id,
                displayName: "Renamed",
                rootBookmarkID: workspace.rootBookmarkID
            )
        ],
        rootPath: { _ in "/core-only" }
    )
    let id = workspaceID.uuidString.lowercased()
    #expect(
        snapshot["local-projects"] == .object([
            id: .object([
                "id": .string(id),
                "name": .string("Renamed"),
                "rootPaths": .array([.string("/one"), .string("/two")]),
                "createdAt": .integer(1_754_500_000_000),
                "updatedAt": .integer(1_754_500_001_000),
            ])
        ])
    )
}

@Test
func localProjectsStateStoreRemovalSurvivesWorkspaceSynchronizationUntilRecreated() {
    let suiteName =
        "CodexDesktopLocalProjectsTombstoneTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer {
        defaults.removePersistentDomain(forName: suiteName)
    }
    let workspaceID = UUID()
    let projectID = workspaceID.uuidString.lowercased()
    let workspace = Workspace(
        id: workspaceID,
        displayName: "Still referenced",
        rootBookmarkID: "bookmark"
    )
    let store = CodexDesktopLocalProjectsStateStore(
        userDefaults: defaults,
        nowMilliseconds: { 1_754_550_000_000 }
    )

    _ = store.createProject(
        projectID: projectID,
        name: "Removed",
        rootPaths: ["/explicit"]
    )
    #expect(store.removeProject(projectID: projectID))
    let afterSynchronization = store.synchronize(
        workspaces: [workspace],
        rootPath: { _ in "/core-still-references-this" }
    )
    #expect(afterSynchronization["local-projects"] == .object([:]))
    #expect(afterSynchronization["project-order"] == .array([]))

    let relaunched = CodexDesktopLocalProjectsStateStore(
        userDefaults: defaults,
        nowMilliseconds: { 1_754_550_001_000 }
    )
    let afterRelaunch = relaunched.synchronize(
        workspaces: [workspace],
        rootPath: { _ in "/core-still-references-this" }
    )
    #expect(afterRelaunch["local-projects"] == .object([:]))

    let recreated = relaunched.upsertProject(
        projectID: projectID,
        name: " Recreated ",
        rootPaths: ["/one", "/two"]
    )
    #expect(recreated.name == "Recreated")
    #expect(
        relaunched.synchronize(
            workspaces: [workspace],
            rootPath: { _ in "/core-only" }
        )["local-projects"] != .object([:])
    )

    #expect(relaunched.removeProject(projectID: projectID))
    _ = relaunched.createProject(
        projectID: projectID,
        name: "Created again",
        rootPaths: ["/created"]
    )
    #expect(
        relaunched.synchronize(
            workspaces: [workspace],
            rootPath: { _ in "/core-only" }
        )["local-projects"] != .object([:])
    )
}

@Test
func localProjectsStateStoreDecodesMetadataWrittenBeforeTombstones() throws {
    let suiteName =
        "CodexDesktopLocalProjectsLegacyStateTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer {
        defaults.removePersistentDomain(forName: suiteName)
    }
    let legacyState: [String: Any] = [
        "projects": [
            "legacy-project": [
                "name": "Legacy",
                "rootPaths": ["/legacy"],
                "createdAt": 1_754_575_000_000,
                "updatedAt": 1_754_575_001_000,
            ],
        ],
        "order": ["legacy-project"],
    ]
    defaults.set(
        try JSONSerialization.data(withJSONObject: legacyState),
        forKey: CodexDesktopLocalProjectsStateStore.storageKey
    )

    let store = CodexDesktopLocalProjectsStateStore(
        userDefaults: defaults
    )
    #expect(
        store.project(projectID: "legacy-project")
            == CodexDesktopLocalProjectRecord(
                id: "legacy-project",
                name: "Legacy",
                rootPaths: ["/legacy"],
                createdAt: 1_754_575_000_000,
                updatedAt: 1_754_575_001_000
            )
    )
    #expect(
        store.globalStateSnapshot()["project-order"]
            == .array([.string("legacy-project")])
    )
    #expect(
        store.synchronize(
            workspaces: [],
            rootPath: { _ in nil }
        )["local-projects"] != .object([:])
    )
}

@Test
func localProjectsStateStoreSerializesConcurrentMutationsAndExposesSendableRecords() async {
    let suiteName =
        "CodexDesktopLocalProjectsConcurrencyTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer {
        defaults.removePersistentDomain(forName: suiteName)
    }
    let store = CodexDesktopLocalProjectsStateStore(
        userDefaults: defaults,
        nowMilliseconds: { 1_754_600_000_000 }
    )

    await withTaskGroup(of: Void.self) { group in
        for index in 0..<32 {
            group.addTask {
                _ = store.createProject(
                    projectID: "project-\(index)",
                    name: "Project \(index)",
                    rootPaths: []
                )
            }
        }
    }
    let snapshot = store.globalStateSnapshot()
    guard case let .object(projects)? = snapshot["local-projects"] else {
        Issue.record("Expected local-projects object")
        return
    }
    #expect(projects.count == 32)
    guard case let .array(projectOrder)? = snapshot["project-order"] else {
        Issue.record("Expected project-order array")
        return
    }
    #expect(projectOrder.count == 32)
    let record: CodexDesktopLocalProjectRecord? =
        store.project(projectID: "project-0")
    #expect(record?.id == "project-0")
}
