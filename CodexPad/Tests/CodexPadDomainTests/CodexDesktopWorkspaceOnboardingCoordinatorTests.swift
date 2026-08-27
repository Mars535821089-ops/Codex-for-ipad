import CodexPadDomain
import CodexPadProtocolBridge
import Foundation
import Testing

@testable import CodexPadApplication

@Test
func uiTestWorkspaceBootstrapRequiresExplicitFlagAndCreatesGitProject() throws {
    let fileManager = FileManager.default
    let documents = fileManager.temporaryDirectory.appendingPathComponent(
        "codexpad-ui-test-bootstrap-\(UUID().uuidString)",
        isDirectory: true
    )
    try fileManager.createDirectory(
        at: documents,
        withIntermediateDirectories: true
    )
    defer {
        try? fileManager.removeItem(at: documents)
    }
    var persisted: [Workspace] = []

    let disabled = try CodexPadUITestWorkspaceBootstrap.prepare(
        environment: [:],
        documentsDirectory: documents,
        fileManager: fileManager,
        persistWorkspace: { persisted.append($0) }
    )
    #expect(disabled == nil)
    #expect(persisted.isEmpty)
    #expect((try fileManager.contentsOfDirectory(atPath: documents.path)).isEmpty)

    let preparedRoot = try CodexPadUITestWorkspaceBootstrap.prepare(
        environment: ["CODEXPAD_UI_TEST_GIT_WORKSPACE": "1"],
        documentsDirectory: documents,
        fileManager: fileManager,
        persistWorkspace: { persisted.append($0) }
    )
    let root = try #require(preparedRoot)
    #expect(root.deletingLastPathComponent() == documents)
    #expect(root.lastPathComponent == "Parity Git Workspace")
    #expect(
        fileManager.fileExists(
            atPath: root.appendingPathComponent(".git/HEAD").path
        )
    )
    #expect(
        try String(
            contentsOf: root.appendingPathComponent("README.md"),
            encoding: .utf8
        ).contains("Codex for ipad parity workspace")
    )
    #expect(persisted.count == 1)
    #expect(persisted[0].displayName == "Parity Git Workspace")
    #expect(
        try CodexWorkspaceAccess().resolve(
            #require(persisted[0].rootBookmarkID)
        ).standardizedFileURL == root.standardizedFileURL
    )
}

@Test
func uiTestWorkspaceBootstrapRebindsTheExistingParityProjectAfterContainerMigration()
    throws
{
    let fileManager = FileManager.default
    let sandbox = fileManager.temporaryDirectory.appendingPathComponent(
        "codexpad-ui-test-bootstrap-migration-\(UUID().uuidString)",
        isDirectory: true
    )
    let documents = sandbox.appendingPathComponent(
        "new-container/Documents",
        isDirectory: true
    )
    try fileManager.createDirectory(
        at: documents,
        withIntermediateDirectories: true
    )
    defer {
        try? fileManager.removeItem(at: sandbox)
    }
    let existingID = UUID()
    let oldRoot = sandbox.appendingPathComponent(
        "old-container/Documents/Parity Git Workspace",
        isDirectory: true
    )
    try fileManager.createDirectory(
        at: oldRoot,
        withIntermediateDirectories: true
    )
    let oldBookmark = try CodexWorkspaceAccess().bookmark(for: oldRoot)
    try fileManager.removeItem(
        at: sandbox.appendingPathComponent(
            "old-container",
            isDirectory: true
        )
    )
    let existing = Workspace(
        id: existingID,
        displayName: "Parity Git Workspace",
        rootBookmarkID: oldBookmark
    )
    var persisted: [Workspace] = []

    let preparedRoot = try CodexPadUITestWorkspaceBootstrap.prepare(
        environment: ["CODEXPAD_UI_TEST_GIT_WORKSPACE": "1"],
        documentsDirectory: documents,
        existingWorkspaces: [existing],
        fileManager: fileManager,
        persistWorkspace: { persisted.append($0) }
    )

    let root = try #require(preparedRoot)
    let rebound = try #require(persisted.first)
    #expect(persisted.count == 1)
    #expect(rebound.id == existingID)
    #expect(
        try CodexWorkspaceAccess().resolve(
            #require(rebound.rootBookmarkID)
        ).standardizedFileURL == root.standardizedFileURL
    )
}

@MainActor
@Test
func workspaceOnboardingPickerStagesThenCommitsTheSelectedRoot() async throws {
    let root = URL(fileURLWithPath: "/Projects/Codex", isDirectory: true)
    var persisted: [(String, String)] = []
    var messages: [CodexDesktopHostMessage] = []
    let coordinator = CodexDesktopWorkspaceOnboardingCoordinator(
        workspaces: { [] },
        persistWorkspace: { _, name, bookmark in
            persisted.append((name, bookmark))
        },
        bookmark: { url in "bookmark:" + url.path },
        resolveBookmark: { _ in root },
        createDefaultWorkspace: { _, _ in root },
        send: { messages.append($0) }
    )

    let picker = await coordinator.handleViewEvent(
        type: "electron-pick-workspace-root-option",
        payload: .object(["allowMultiple": .bool(false)])
    )
    #expect(picker == .presentPicker(allowsMultipleSelection: false))

    await coordinator.completePicker(urls: [root])
    #expect(persisted.isEmpty)
    #expect(
        messages == [
            .event(
                type: "workspace-root-option-picked",
                payload: .object(["root": .string(root.path)])
            )
        ]
    )

    let committed = await coordinator.handleViewEvent(
        type: "electron-update-workspace-root-options",
        payload: .object([
            "roots": .array([.string(root.path)])
        ])
    )
    #expect(committed == .handled)
    #expect(persisted.count == 1)
    #expect(persisted[0].0 == "Codex")
    #expect(persisted[0].1 == "bookmark:/Projects/Codex")
    #expect(
        messages.suffix(3) == [
            .event(
                type: "active-workspace-roots-updated",
                payload: .object([:])
            ),
            .event(
                type: "global-state-updated",
                payload: .object([
                    "keys": .array([
                        .string("local-projects"),
                        .string("project-order"),
                        .string("selected-project"),
                    ])
                ])
            ),
            .event(
                type: "workspace-root-options-updated",
                payload: .object([:])
            ),
        ]
    )
}

@MainActor
@Test
func workspaceOnboardingCommitDeduplicatesRepeatedRoots() async {
    let root = URL(
        fileURLWithPath: "/Projects/Codex",
        isDirectory: true
    )
    var persisted: [(String, String)] = []
    let coordinator = CodexDesktopWorkspaceOnboardingCoordinator(
        workspaces: { [] },
        persistWorkspace: { _, name, bookmark in
            persisted.append((name, bookmark))
        },
        bookmark: { url in "bookmark:" + url.path },
        resolveBookmark: { _ in root },
        createDefaultWorkspace: { _, _ in root },
        send: { _ in }
    )

    await coordinator.completePicker(urls: [root, root])
    let effect = await coordinator.handleViewEvent(
        type: "electron-update-workspace-root-options",
        payload: .object([
            "roots": .array([
                .string(root.path),
                .string(root.path),
            ])
        ])
    )

    #expect(effect == .handled)
    #expect(persisted.count == 1)
    #expect(persisted.first?.0 == "Codex")
}

@MainActor
@Test
func workspaceProjectCommandsCreateRenameSelectAndClearPersistedRoots()
    async
{
    let firstRoot = URL(
        fileURLWithPath: "/Projects/Existing",
        isDirectory: true
    )
    let createdRoot = URL(
        fileURLWithPath: "/Projects/My project",
        isDirectory: true
    )
    let firstID = UUID()
    var workspaces = [
        Workspace(
            id: firstID,
            displayName: "Existing",
            rootBookmarkID: "bookmark:/Projects/Existing"
        )
    ]
    var selectedIDs: [UUID?] = []
    var messages: [CodexDesktopHostMessage] = []
    let coordinator = CodexDesktopWorkspaceOnboardingCoordinator(
        workspaces: { workspaces },
        persistWorkspace: { id, name, bookmark in
            let workspace = Workspace(
                id: id,
                displayName: name,
                rootBookmarkID: bookmark
            )
            if let index = workspaces.firstIndex(where: { $0.id == id }) {
                workspaces[index] = workspace
            } else {
                workspaces.append(workspace)
            }
        },
        bookmark: { url in "bookmark:" + url.path },
        resolveBookmark: { bookmark in
            URL(
                fileURLWithPath: bookmark.replacingOccurrences(
                    of: "bookmark:",
                    with: ""
                ),
                isDirectory: true
            )
        },
        createDefaultWorkspace: { _, _ in createdRoot },
        selectWorkspace: { selectedIDs.append($0) },
        send: { messages.append($0) }
    )

    #expect(
        await coordinator.handleViewEvent(
            type: "electron-set-active-workspace-root",
            payload: .object(["root": .string(firstRoot.path)])
        ) == .handled
    )
    #expect(selectedIDs.last == firstID)

    #expect(
        await coordinator.handleViewEvent(
            type: "electron-rename-workspace-root-option",
            payload: .object([
                "root": .string(firstRoot.path),
                "label": .string("Renamed"),
            ])
        ) == .handled
    )
    #expect(workspaces.first?.displayName == "Renamed")

    #expect(
        await coordinator.handleViewEvent(
            type: "electron-create-new-workspace-root-option",
            payload: .object([
                "projectName": .string("My project"),
                "initializeGitRepository": .bool(true),
            ])
        ) == .handled
    )
    #expect(workspaces.count == 2)
    #expect(workspaces.last?.displayName == "My project")
    #expect(selectedIDs.last == workspaces.last?.id)

    #expect(
        await coordinator.handleViewEvent(
            type: "electron-clear-active-workspace-root",
            payload: .object([:])
        ) == .handled
    )
    #expect(selectedIDs.last == .some(nil))
    #expect(
        messages.contains(
            .event(
                type: "workspace-root-option-added",
                payload: .object([
                    "projectId": .string(
                        workspaces.last!.id.uuidString.lowercased()
                    ),
                    "root": .string(createdRoot.path),
                ])
            )
        )
    )
}

@MainActor
@Test
func workspaceOnboardingSkipCreatesPersistsAndReportsTheDefaultRoot() async {
    let root = URL(
        fileURLWithPath: "/Projects/My project",
        isDirectory: true
    )
    var creation: (String, Bool)?
    var persisted: [(String, String)] = []
    var messages: [CodexDesktopHostMessage] = []
    let coordinator = CodexDesktopWorkspaceOnboardingCoordinator(
        workspaces: { [] },
        persistWorkspace: { _, name, bookmark in
            persisted.append((name, bookmark))
        },
        bookmark: { _ in "bookmark:default" },
        resolveBookmark: { _ in root },
        createDefaultWorkspace: { name, initializeGitRepository in
            creation = (name, initializeGitRepository)
            return root
        },
        send: { messages.append($0) }
    )

    let effect = await coordinator.handleViewEvent(
        type: "electron-onboarding-skip-workspace",
        payload: .object([
            "projectName": .string("My project"),
            "initializeGitRepository": .bool(true),
        ])
    )

    #expect(effect == .handled)
    #expect(creation?.0 == "My project")
    #expect(creation?.1 == true)
    #expect(persisted.count == 1)
    #expect(persisted[0].0 == "My project")
    #expect(persisted[0].1 == "bookmark:default")
    #expect(
        messages.first == .event(
            type: "electron-onboarding-skip-workspace-result",
            payload: .object([
                "success": .bool(true),
                "root": .string(root.path),
            ])
        )
    )
}

@MainActor
@Test
func workspaceOnboardingPickUsesSelectionOrCreatesDefaultAfterCancellation()
    async
{
    let pickedRoot = URL(
        fileURLWithPath: "/Projects/Picked",
        isDirectory: true
    )
    let defaultRoot = URL(
        fileURLWithPath: "/Projects/Default",
        isDirectory: true
    )

    for scenario in ["picked", "created_default"] {
        var workspaces: [Workspace] = []
        var selectedID: UUID?
        var creation: (String, Bool)?
        var messages: [CodexDesktopHostMessage] = []
        let coordinator = CodexDesktopWorkspaceOnboardingCoordinator(
            workspaces: { workspaces },
            persistWorkspace: { id, name, bookmark in
                workspaces.append(
                    Workspace(
                        id: id,
                        displayName: name,
                        rootBookmarkID: bookmark
                    )
                )
            },
            bookmark: { "bookmark:" + $0.path },
            resolveBookmark: {
                URL(
                    fileURLWithPath: $0.replacingOccurrences(
                        of: "bookmark:",
                        with: ""
                    ),
                    isDirectory: true
                )
            },
            createDefaultWorkspace: { name, initializeGitRepository in
                creation = (name, initializeGitRepository)
                return defaultRoot
            },
            selectWorkspace: { selectedID = $0 },
            send: { messages.append($0) }
        )

        let effect = await coordinator.handleViewEvent(
            type:
                "electron-onboarding-pick-workspace-or-create-default",
            payload: .object([
                "defaultProjectName": .string("Default"),
                "initializeGitRepository": .bool(true),
            ])
        )
        #expect(
            effect == .presentPicker(
                allowsMultipleSelection: false
            )
        )

        await coordinator.completePicker(
            urls: scenario == "picked" ? [pickedRoot] : []
        )

        #expect(workspaces.count == 1)
        #expect(selectedID == workspaces.first?.id)
        #expect(
            workspaces.first?.rootBookmarkID
                == "bookmark:"
                    + (
                        scenario == "picked"
                            ? pickedRoot.path
                            : defaultRoot.path
                    )
        )
        if scenario == "picked" {
            #expect(creation == nil)
        } else {
            #expect(creation?.0 == "Default")
            #expect(creation?.1 == true)
        }
        #expect(
            messages.first == .event(
                type: "workspace-root-options-updated",
                payload: .object([:])
            )
        )
        #expect(
            messages.contains(
                .event(
                    type:
                        "electron-onboarding-pick-workspace-or-create-default-result",
                    payload: .object([
                        "success": .bool(true),
                        "source": .string(scenario),
                        "root": .string(
                            scenario == "picked"
                                ? pickedRoot.path
                                : defaultRoot.path
                        ),
                    ])
                )
            )
        )
        #expect(
            messages.last.map { message in
                guard case let .event(type, payload) = message,
                      type == "navigate-to-route",
                      case let .object(fields) = payload,
                      fields["path"] == .string("/")
                else {
                    return false
                }
                return true
            } == true
        )
    }
}

@Test
func defaultWorkspaceCreationProducesAValidGitRepositoryAndUniqueNames()
    throws
{
    let fileManager = FileManager.default
    let documents = fileManager.temporaryDirectory.appendingPathComponent(
        "codex-default-workspace-\(UUID().uuidString)",
        isDirectory: true
    )
    try fileManager.createDirectory(
        at: documents,
        withIntermediateDirectories: true
    )
    defer {
        try? fileManager.removeItem(at: documents)
    }

    let first = try CodexDesktopDefaultWorkspaceCreator.create(
        named: "My project",
        initializeGitRepository: true,
        documentsDirectory: documents,
        fileManager: fileManager
    )
    let second = try CodexDesktopDefaultWorkspaceCreator.create(
        named: "My project",
        initializeGitRepository: false,
        documentsDirectory: documents,
        fileManager: fileManager
    )

    #expect(first.lastPathComponent == "My project")
    #expect(second.lastPathComponent == "My project 2")
    #expect(
        fileManager.fileExists(
            atPath: first.appendingPathComponent(
                ".git/objects/info",
                isDirectory: true
            ).path
        )
    )
    #expect(
        fileManager.fileExists(
            atPath: first.appendingPathComponent(
                ".git/objects/pack",
                isDirectory: true
            ).path
        )
    )
    #expect(
        try String(
            contentsOf: first.appendingPathComponent(".git/HEAD"),
            encoding: .utf8
        ) == "ref: refs/heads/main\n"
    )

    let git = Process()
    git.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    git.arguments = [
        "-C",
        first.path,
        "rev-parse",
        "--is-inside-work-tree",
    ]
    let output = Pipe()
    git.standardOutput = output
    git.standardError = output
    try git.run()
    git.waitUntilExit()
    let result = String(
        data: output.fileHandleForReading.readDataToEndOfFile(),
        encoding: .utf8
    )
    #expect(git.terminationStatus == 0)
    #expect(
        result?.trimmingCharacters(in: .whitespacesAndNewlines)
            == "true"
    )
}
