import Foundation
import Testing
@testable import CodexPadApplication
@testable import CodexPadDomain

@Test
func threadProjectAssignmentStoreUsesReleasedKeyAndExactAssignmentShape() {
    let suiteName =
        "CodexDesktopThreadProjectAssignmentShapeTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer {
        defaults.removePersistentDomain(forName: suiteName)
    }
    let store = CodexDesktopThreadProjectAssignmentStore(
        userDefaults: defaults
    )
    let local = CodexDesktopThreadProjectAssignment.local(
        projectID: " Project/Local ",
        projectOrigin: .chatgpt,
        path: "/legacy/path",
        cwd: "/current/cwd",
        pendingCoreUpdate: false
    )
    let remote = CodexDesktopThreadProjectAssignment.remote(
        projectID: "remote-project",
        path: "/remote/path",
        cwd: "/remote/cwd",
        hostID: "host-1",
        pendingCoreUpdate: true
    )

    #expect(
        CodexDesktopThreadProjectAssignmentStore.releasedStorageKey
            == "thread-project-assignments"
    )
    #expect(
        store.setAssignment(
            threadID: " Thread/Raw/Ω ",
            assignment: local
        )
    )
    #expect(
        store.setAssignment(
            threadID: "thread-remote",
            assignment: remote
        )
    )
    #expect(
        store.globalStateValue == .object([
            " Thread/Raw/Ω ": .object([
                "projectKind": .string("local"),
                "projectId": .string(" Project/Local "),
                "projectOrigin": .string("chatgpt"),
                "path": .string("/legacy/path"),
                "cwd": .string("/current/cwd"),
                "pendingCoreUpdate": .bool(false),
            ]),
            "thread-remote": .object([
                "projectKind": .string("remote"),
                "projectId": .string("remote-project"),
                "path": .string("/remote/path"),
                "cwd": .string("/remote/cwd"),
                "hostId": .string("host-1"),
                "pendingCoreUpdate": .bool(true),
            ]),
        ])
    )
    #expect(
        store.assignment(threadID: " Thread/Raw/Ω ") == local
    )
    #expect(store.assignment(threadID: "Thread/Raw/Ω") == nil)
}

@Test
func threadProjectAssignmentStorePersistsSetsRemovesAndSkipsNoOps() {
    let suiteName =
        "CodexDesktopThreadProjectAssignmentMutationTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer {
        defaults.removePersistentDomain(forName: suiteName)
    }
    let assignment = CodexDesktopThreadProjectAssignment.local(
        projectID: "project-1",
        pendingCoreUpdate: false
    )
    let store = CodexDesktopThreadProjectAssignmentStore(
        userDefaults: defaults
    )

    #expect(
        !store.setAssignment(
            threadID: "",
            assignment: assignment
        )
    )
    #expect(
        store.setAssignment(
            threadID: "thread-1",
            assignment: assignment
        )
    )
    #expect(
        !store.setAssignment(
            threadID: "thread-1",
            assignment: assignment
        )
    )

    let relaunched = CodexDesktopThreadProjectAssignmentStore(
        userDefaults: defaults
    )
    #expect(relaunched.assignments == ["thread-1": assignment])
    #expect(relaunched.removeAssignment(threadID: "thread-1"))
    #expect(!relaunched.removeAssignment(threadID: "thread-1"))
    #expect(
        !relaunched.setAssignment(
            threadID: "",
            assignment: nil
        )
    )
    #expect(relaunched.globalStateValue == .object([:]))

    let afterRemoval = CodexDesktopThreadProjectAssignmentStore(
        userDefaults: defaults
    )
    #expect(afterRemoval.assignments.isEmpty)
}

@Test
func threadProjectAssignmentStoreNormalizesMalformedPersistedEntries() throws {
    let suiteName =
        "CodexDesktopThreadProjectAssignmentDecodeTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer {
        defaults.removePersistentDomain(forName: suiteName)
    }
    let raw: [String: Any] = [
        "valid-local": [
            "projectKind": "local",
            "projectId": "local-project",
            "pendingCoreUpdate": false,
            "unknown": "discarded",
        ],
        "valid-remote": [
            "projectKind": "remote",
            "projectId": "remote-project",
            "path": "/remote",
            "pendingCoreUpdate": true,
        ],
        "": [
            "projectKind": "local",
            "projectId": "empty-thread",
            "pendingCoreUpdate": false,
        ],
        "missing-remote-path": [
            "projectKind": "remote",
            "projectId": "remote-project",
            "pendingCoreUpdate": false,
        ],
        "missing-pending-flag": [
            "projectKind": "local",
            "projectId": "local-project",
        ],
        "invalid-pending-flag": [
            "projectKind": "local",
            "projectId": "local-project",
            "pendingCoreUpdate": "false",
        ],
        "unknown-kind": [
            "projectKind": "fixture",
            "projectId": "fixture-project",
            "pendingCoreUpdate": false,
        ],
        "invalid-origin": [
            "projectKind": "local",
            "projectId": "local-project",
            "projectOrigin": "fixture",
            "pendingCoreUpdate": false,
        ],
    ]
    defaults.set(
        try JSONSerialization.data(withJSONObject: raw),
        forKey:
            CodexDesktopThreadProjectAssignmentStore.releasedStorageKey
    )

    let store = CodexDesktopThreadProjectAssignmentStore(
        userDefaults: defaults
    )
    #expect(
        store.assignments == [
            "valid-local": .local(
                projectID: "local-project",
                pendingCoreUpdate: false
            ),
            "valid-remote": .remote(
                projectID: "remote-project",
                path: "/remote",
                pendingCoreUpdate: true
            ),
            "missing-pending-flag": .local(
                projectID: "local-project",
                pendingCoreUpdate: false
            ),
        ]
    )
    #expect(
        store.globalStateValue == .object([
            "valid-local": .object([
                "projectKind": .string("local"),
                "projectId": .string("local-project"),
                "pendingCoreUpdate": .bool(false),
            ]),
            "valid-remote": .object([
                "projectKind": .string("remote"),
                "projectId": .string("remote-project"),
                "path": .string("/remote"),
                "pendingCoreUpdate": .bool(true),
            ]),
            "missing-pending-flag": .object([
                "projectKind": .string("local"),
                "projectId": .string("local-project"),
                "pendingCoreUpdate": .bool(false),
            ]),
        ])
    )
}
