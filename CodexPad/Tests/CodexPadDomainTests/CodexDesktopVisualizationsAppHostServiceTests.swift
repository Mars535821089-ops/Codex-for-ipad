import Foundation
import Testing

@testable import CodexPadApplication

@Test
func desktopVisualizationsReturnsOnlyLocalTemporaryRoots()
    async throws
{
    let temporary = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
    let service = CodexDesktopVisualizationsAppHostService(
        codexHome: temporary,
        temporaryDirectory: temporary,
        isLocalHost: { $0 == "local" }
    )

    #expect(
        try await service.invoke(
            method: "getTemporaryRoots",
            arguments: [.string("remote")]
        ) == .array([])
    )
    let local = try await service.invoke(
        method: "getTemporaryRoots",
        arguments: [.string("local")]
    )
    guard case let .array(roots) = local else {
        Issue.record("local roots must be an array")
        return
    }
    #expect(roots.contains(.string(temporary.path)))
}

@Test
func desktopVisualizationsReadsOnlyReleasedHtmlArtifactShape()
    async throws
{
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
    let threadRoot = root
        .appendingPathComponent("visualizations")
        .appendingPathComponent("thread-1")
    try FileManager.default.createDirectory(
        at: threadRoot,
        withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: root) }
    try Data("<html>real</html>".utf8).write(
        to: threadRoot.appendingPathComponent("result-one.html")
    )
    let service = CodexDesktopVisualizationsAppHostService(
        codexHome: root,
        threadRoot: { threadID in
            root.appendingPathComponent("visualizations")
                .appendingPathComponent(threadID)
        }
    )

    #expect(
        try await service.invoke(
            method: "read",
            arguments: [
                .object([
                    "hostId": .string("local"),
                    "path": .string("result-one.html"),
                    "threadId": .string("thread-1"),
                ])
            ]
        )
            == .object([
                "contents": .string("<html>real</html>")
            ])
    )
    await #expect(throws: CodexDesktopVisualizationsAppHostService.Error.self) {
        _ = try await service.invoke(
            method: "read",
            arguments: [
                .object([
                    "hostId": .string("local"),
                    "path": .string("../result-one.html"),
                    "threadId": .string("thread-1"),
                ])
            ]
        )
    }
}
