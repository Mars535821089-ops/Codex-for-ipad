import Foundation
import Testing

@testable import CodexPadApplication

@Test
func desktopAppHostWorkspaceRegistryNormalizesAndFallsBack() {
    let documents = URL(fileURLWithPath: "/container/Documents")
    let first = URL(fileURLWithPath: "/workspace/one/../one")
    let duplicate = URL(fileURLWithPath: "/workspace/one")
    let second = URL(fileURLWithPath: "/workspace/two")
    let registry = CodexDesktopAppHostWorkspaceRegistry(
        authorizedRoots: [first, duplicate, second],
        selectedRoot: URL(fileURLWithPath: "/outside"),
        documentsRoot: documents
    )

    let snapshot = registry.snapshot()

    #expect(
        snapshot.authorizedRoots.map(\.path)
            == ["/workspace/one", "/workspace/two"]
    )
    #expect(snapshot.selectedRoot.path == "/workspace/one")
    #expect(
        snapshot.artifactRoots.map(\.path)
            == [
                "/workspace/one",
                "/workspace/two",
                "/container/Documents",
            ]
    )
}

@Test
func desktopAppHostWorkspaceRegistryAtomicallyReplacesSnapshot() {
    let registry = CodexDesktopAppHostWorkspaceRegistry(
        authorizedRoots: [],
        selectedRoot: nil,
        documentsRoot: URL(
            fileURLWithPath: "/container/Documents"
        )
    )

    #expect(
        registry.snapshot().selectedRoot.path
            == "/container/Documents"
    )

    registry.replace(
        authorizedRoots: [
            URL(fileURLWithPath: "/workspace/a"),
            URL(fileURLWithPath: "/workspace/b"),
        ],
        selectedRoot: URL(fileURLWithPath: "/workspace/b")
    )
    let replacement = registry.snapshot()

    #expect(
        replacement.authorizedRoots.map(\.path)
            == ["/workspace/a", "/workspace/b"]
    )
    #expect(replacement.selectedRoot.path == "/workspace/b")
}
