import Foundation
import Testing

@testable import CodexPadApplication
@testable import CodexPadDomain

private typealias RemoteProjectValue = CodexDesktopAppHostRPC.Value

@MainActor
@Test
func remoteProjectBackendCreatesDeduplicatesAndPersistsReleasedState()
    async throws
{
    let fixture = RemoteProjectMutationFixture()
    let backend = fixture.makeBackend()
    let appearance = RemoteProjectValue.object([
        "color": .string("purple"),
        "marker": .object([
            "icon": .string("function"),
            "kind": .string("icon"),
        ]),
    ])

    let created = try await backend.handle(
        method: "createRemote",
        request: .object([
            "appearance": appearance,
            "hostId": .string("ssh-host-1"),
            "label": .string("   "),
            "remotePath": .string("/srv/repo/./"),
        ])
    )

    #expect(created == .object([
        "hostId": .string("ssh-host-1"),
        "id": .string("remote-project-1"),
        "label": .string("repo"),
        "remotePath": .string("/srv/repo"),
    ]))
    #expect(
        fixture.atoms.snapshot["remote-projects"] == .array([
            .object([
                "hostId": .string("ssh-host-1"),
                "id": .string("remote-project-1"),
                "label": .string("repo"),
                "remotePath": .string("/srv/repo"),
            ]),
        ])
    )
    #expect(
        fixture.atoms.snapshot["project-order"] == .array([
            .string("remote-project-1"),
        ])
    )
    #expect(
        fixture.atoms.snapshot["project-appearances"] == .object([
            "remote-project-1": .object([
                "color": .string("purple"),
                "marker": .object([
                    "icon": .string("function"),
                    "kind": .string("icon"),
                ]),
            ]),
        ])
    )
    #expect(fixture.publishKeys == [[
        "remote-projects",
        "project-order",
        "project-appearances",
    ]])

    await #expect(
        throws: CodexDesktopRemoteProjectMutationBackend.Error
            .duplicateRemoteProject
    ) {
        _ = try await backend.handle(
            method: "createRemote",
            request: .object([
                "appearance": .null,
                "hostId": .string("ssh-host-1"),
                "label": .string("Again"),
                "remotePath": .string("/srv/repo"),
            ])
        )
    }
    #expect(fixture.projectIDRequests == 1)
}

@MainActor
@Test
func remoteProjectBackendSetsAndClearsAppearanceWithoutManufacturingProject()
    async throws
{
    let fixture = RemoteProjectMutationFixture()
    let backend = fixture.makeBackend()
    let appearance = RemoteProjectValue.object([
        "color": .string("blue"),
        "marker": .object([
            "emoji": .string("🚀"),
            "kind": .string("emoji"),
        ]),
    ])

    _ = try await backend.handle(
        method: "setAppearance",
        request: .object([
            "appearance": appearance,
            "projectId": .string("remote-project-existing"),
        ])
    )
    #expect(
        fixture.atoms.snapshot["project-appearances"] == .object([
            "remote-project-existing": .object([
                "color": .string("blue"),
                "marker": .object([
                    "emoji": .string("🚀"),
                    "kind": .string("emoji"),
                ]),
            ]),
        ])
    )
    #expect(fixture.publishKeys == [["project-appearances"]])

    _ = try await backend.handle(
        method: "setAppearance",
        request: .object([
            "appearance": .null,
            "projectId": .string("remote-project-existing"),
        ])
    )
    #expect(
        fixture.atoms.snapshot["project-appearances"] == .object([:])
    )
    #expect(fixture.publishKeys == [
        ["project-appearances"],
        ["project-appearances"],
    ])
}

@MainActor
@Test
func remoteProjectBackendRenamesAnExistingProjectAndPublishesOnlyRemoteProjects()
    async throws
{
    let fixture = RemoteProjectMutationFixture()
    fixture.seedRemoteProjects([
        [
            "hostId": .string("ssh-host-1"),
            "id": .string("remote-1"),
            "label": .string("Old name"),
            "remotePath": .string("/srv/repo"),
        ],
    ])
    fixture.seedProjectOrder(["remote-1"])
    let backend = fixture.makeBackend()

    try await backend.handle(
        method: "renameRemote",
        request: .object([
            "name": .string("  New name  "),
            "projectId": .string("remote-1"),
        ])
    )

    #expect(
        fixture.atoms.snapshot["remote-projects"] == .array([
            .object([
                "hostId": .string("ssh-host-1"),
                "id": .string("remote-1"),
                "label": .string("New name"),
                "remotePath": .string("/srv/repo"),
            ]),
        ])
    )
    #expect(fixture.atoms.snapshot["project-order"] == .array([
        .string("remote-1"),
    ]))
    #expect(fixture.publishKeys == [["remote-projects"]])
}

@MainActor
@Test
func remoteProjectBackendRemovesProjectAndCleansOrderAndAppearance()
    async throws
{
    let fixture = RemoteProjectMutationFixture()
    fixture.seedRemoteProjects([
        [
            "hostId": .string("ssh-host-1"),
            "id": .string("remote-1"),
            "label": .string("Remote"),
            "remotePath": .string("/srv/repo"),
        ],
        [
            "hostId": .string("ssh-host-2"),
            "id": .string("remote-2"),
            "label": .string("Other"),
            "remotePath": .string("/srv/other"),
        ],
    ])
    fixture.seedProjectOrder(["remote-1", "remote-2"])
    fixture.seedAppearances([
        "remote-1": .object(["color": .string("blue")]),
    ])
    let backend = fixture.makeBackend()

    try await backend.handle(
        method: "removeRemote",
        request: .string("remote-1")
    )

    #expect(fixture.atoms.snapshot["remote-projects"] == .array([
        .object([
            "hostId": .string("ssh-host-2"),
            "id": .string("remote-2"),
            "label": .string("Other"),
            "remotePath": .string("/srv/other"),
        ]),
    ]))
    #expect(fixture.atoms.snapshot["project-order"] == .array([
        .string("remote-2"),
    ]))
    #expect(fixture.atoms.snapshot["project-appearances"] == .object([:]))
    #expect(fixture.publishKeys == [[
        "remote-projects",
        "project-order",
        "project-appearances",
    ]])
}

@MainActor
@Test
func remoteProjectBackendUpsertsProjectAtReleasedOrderIndex()
    async throws
{
    let fixture = RemoteProjectMutationFixture()
    fixture.seedRemoteProjects([
        [
            "hostId": .string("ssh-host-1"),
            "id": .string("remote-1"),
            "label": .string("One"),
            "remotePath": .string("/srv/one"),
        ],
    ])
    fixture.seedProjectOrder(["remote-1"])
    let backend = fixture.makeBackend()

    try await backend.handle(
        method: "upsertRemote",
        request: .object([
            "index": .integer(0),
            "project": .object([
                "hostId": .string("ssh-host-2"),
                "id": .string("remote-2"),
                "label": .string("Two"),
                "remotePath": .string("/srv/two"),
            ]),
        ])
    )

    #expect(fixture.atoms.snapshot["remote-projects"] == .array([
        .object([
            "hostId": .string("ssh-host-2"),
            "id": .string("remote-2"),
            "label": .string("Two"),
            "remotePath": .string("/srv/two"),
        ]),
        .object([
            "hostId": .string("ssh-host-1"),
            "id": .string("remote-1"),
            "label": .string("One"),
            "remotePath": .string("/srv/one"),
        ]),
    ]))
    #expect(fixture.atoms.snapshot["project-order"] == .array([
        .string("remote-2"),
        .string("remote-1"),
    ]))
    #expect(fixture.publishKeys == [["remote-projects", "project-order"]])
}

@MainActor
private final class RemoteProjectMutationFixture {
    let atoms: CodexDesktopPersistedAtomStore
    var projectIDRequests = 0
    var publishKeys: [[String]] = []

    init() {
        let suiteName =
            "CodexRemoteProjectBackendTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        atoms = CodexDesktopPersistedAtomStore(
            userDefaults: defaults,
            storageKey: "remote-project-atoms"
        )
    }

    func makeBackend() -> CodexDesktopRemoteProjectMutationBackend {
        CodexDesktopRemoteProjectMutationBackend(
            persistedAtoms: atoms,
            makeProjectID: { [unowned self] in
                projectIDRequests += 1
                return "remote-project-\(projectIDRequests)"
            },
            publishStateChange: { [unowned self] keys in
                publishKeys.append(keys)
            }
        )
    }

    func seedRemoteProjects(_ projects: [[String: RemoteProjectValue]]) {
        _ = atoms.update(
            key: "remote-projects",
            value: .array(projects.map { project in
                .object(project.mapValues(Self.jsonValue))
            })
        )
    }

    func seedProjectOrder(_ ids: [String]) {
        _ = atoms.update(
            key: "project-order",
            value: .array(ids.map(CodexJSONValue.string))
        )
    }

    func seedAppearances(_ appearances: [String: RemoteProjectValue]) {
        _ = atoms.update(
            key: "project-appearances",
            value: .object(appearances.mapValues { value in
                switch value {
                case .null: return .null
                case let .bool(value): return .bool(value)
                case let .integer(value): return .integer(value)
                case let .number(value): return .number(value)
                case let .string(value): return .string(value)
                case let .array(values): return .array(values.map(Self.jsonValue))
                case let .object(values): return .object(values.mapValues(Self.jsonValue))
                default: return .null
                }
            })
        )
    }

    private static func jsonValue(_ value: RemoteProjectValue) -> CodexJSONValue {
        switch value {
        case .null: return .null
        case let .bool(value): return .bool(value)
        case let .integer(value): return .integer(value)
        case let .number(value): return .number(value)
        case let .string(value): return .string(value)
        case let .array(values): return .array(values.map(jsonValue))
        case let .object(values): return .object(values.mapValues(jsonValue))
        default: return .null
        }
    }
}
