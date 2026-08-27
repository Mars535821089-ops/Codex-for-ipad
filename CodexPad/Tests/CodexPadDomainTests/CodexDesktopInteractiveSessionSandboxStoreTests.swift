import Foundation
import Testing

@testable import CodexPadApplication
@testable import CodexPadDomain

@Test
func interactiveSessionSandboxListsRealFilesRecursivelyInStableOrder()
    async throws
{
    let fixture = try InteractiveSessionSandboxFixture()
    defer { fixture.remove() }

    try fixture.write(
        Data("zeta".utf8),
        sessionID: "session-a",
        relativePath: "zeta.txt"
    )
    try fixture.write(
        Data("alpha".utf8),
        sessionID: "session-a",
        relativePath: "nested/alpha.txt"
    )

    let store = CodexDesktopInteractiveSessionSandboxStore(
        root: fixture.root
    )
    let response = try await store.list(sessionID: "session-a")
    let entries = try sandboxEntries(response)

    #expect(
        entries.compactMap { $0.string("path") }
            == ["nested", "nested/alpha.txt", "zeta.txt"]
    )
    #expect(
        entries.compactMap { $0.string("type") }
            == ["directory", "file", "file"]
    )
    #expect(entries[0]["sizeBytes"] == .null)
    #expect(entries[1]["sizeBytes"] == .integer(5))
    #expect(entries[2]["sizeBytes"] == .integer(4))
    #expect(entries.allSatisfy { $0["modifiedAtMs"] != nil })
}

@Test
func interactiveSessionSandboxListsOnlyRequestedSubdirectory()
    async throws
{
    let fixture = try InteractiveSessionSandboxFixture()
    defer { fixture.remove() }

    try fixture.write(
        Data("inside".utf8),
        sessionID: "session-a",
        relativePath: "nested/inside.txt"
    )
    try fixture.write(
        Data("outside".utf8),
        sessionID: "session-a",
        relativePath: "outside.txt"
    )

    let store = CodexDesktopInteractiveSessionSandboxStore(
        root: fixture.root
    )
    let response = try await store.list(
        sessionID: "session-a",
        relativePath: "nested"
    )

    #expect(
        try sandboxEntries(response).compactMap { $0.string("path") }
            == ["nested/inside.txt"]
    )
}

@Test
func interactiveSessionSandboxReadsBase64WithoutInventingContent()
    async throws
{
    let fixture = try InteractiveSessionSandboxFixture()
    defer { fixture.remove() }

    let payload = Data([0x00, 0x01, 0x7f, 0x80, 0xff])
    try fixture.write(
        payload,
        sessionID: "session-a",
        relativePath: "capture.bin"
    )
    let store = CodexDesktopInteractiveSessionSandboxStore(
        root: fixture.root
    )

    #expect(
        try await store.read(
            sessionID: "session-a",
            relativePath: "capture.bin"
        ) == .object([
            "dataBase64": .string(payload.base64EncodedString()),
            "path": .string("capture.bin"),
            "sizeBytes": .integer(Int64(payload.count)),
        ])
    )
}

@Test
func interactiveSessionSandboxRejectsOversizedReadsBeforeReturningData()
    async throws
{
    let fixture = try InteractiveSessionSandboxFixture()
    defer { fixture.remove() }

    try fixture.write(
        Data(repeating: 0xaa, count: 5),
        sessionID: "session-a",
        relativePath: "large.bin"
    )
    let store = CodexDesktopInteractiveSessionSandboxStore(
        root: fixture.root,
        maximumReadBytes: 4
    )

    await #expect(
        throws:
            CodexDesktopInteractiveSessionSandboxStore.Error
                .readLimitExceeded(maximumBytes: 4)
    ) {
        _ = try await store.read(
            sessionID: "session-a",
            relativePath: "large.bin"
        )
    }
}

@Test
func interactiveSessionSandboxRejectsSessionAndPathTraversal()
    async throws
{
    let fixture = try InteractiveSessionSandboxFixture()
    defer { fixture.remove() }
    let store = CodexDesktopInteractiveSessionSandboxStore(
        root: fixture.root
    )

    await #expect(
        throws:
            CodexDesktopInteractiveSessionSandboxStore.Error
                .invalidSessionID
    ) {
        _ = try await store.list(sessionID: "../session-a")
    }
    await #expect(
        throws:
            CodexDesktopInteractiveSessionSandboxStore.Error.invalidPath
    ) {
        _ = try await store.read(
            sessionID: "session-a",
            relativePath: "../outside.txt"
        )
    }
    await #expect(
        throws:
            CodexDesktopInteractiveSessionSandboxStore.Error.invalidPath
    ) {
        _ = try await store.list(
            sessionID: "session-a",
            relativePath: "/absolute"
        )
    }
}

@Test
func interactiveSessionSandboxConfinesSymlinksAndAttachmentsToSessionRoot()
    async throws
{
    let fixture = try InteractiveSessionSandboxFixture()
    defer { fixture.remove() }

    try fixture.write(
        Data("inside".utf8),
        sessionID: "session-a",
        relativePath: "inside.txt"
    )
    let outside = fixture.root
        .deletingLastPathComponent()
        .appendingPathComponent(
            "interactive-session-outside-\(UUID().uuidString).txt"
        )
    defer { try? FileManager.default.removeItem(at: outside) }
    try Data("outside".utf8).write(to: outside)
    try fixture.createSymlink(
        sessionID: "session-a",
        relativePath: "outside-link.txt",
        destination: outside
    )

    let store = CodexDesktopInteractiveSessionSandboxStore(
        root: fixture.root
    )
    let listedPaths = try sandboxEntries(
        await store.list(sessionID: "session-a")
    ).compactMap { $0.string("path") }
    let attachments = try await store.attachmentURLs(
        sessionID: "session-a"
    )

    #expect(listedPaths == ["inside.txt"])
    #expect(
        attachments.map(\.standardizedFileURL.path)
            == [
                fixture.url(
                    sessionID: "session-a",
                    relativePath: "inside.txt"
                ).standardizedFileURL.path,
            ]
    )
    await #expect(
        throws:
            CodexDesktopInteractiveSessionSandboxStore.Error.invalidPath
    ) {
        _ = try await store.read(
            sessionID: "session-a",
            relativePath: "outside-link.txt"
        )
    }
}

@Test
func interactiveSessionSandboxReturnsEmptyRealCollectionsForMissingSession()
    async throws
{
    let fixture = try InteractiveSessionSandboxFixture()
    defer { fixture.remove() }
    let store = CodexDesktopInteractiveSessionSandboxStore(
        root: fixture.root
    )

    #expect(
        try await store.list(sessionID: "missing")
            == .object(["data": .array([])])
    )
    #expect(
        try await store.attachmentURLs(sessionID: "missing").isEmpty
    )
}

private func sandboxEntries(
    _ value: CodexJSONValue
) throws -> [[String: CodexJSONValue]] {
    guard case let .object(response) = value,
          case let .array(values)? = response["data"]
    else {
        throw InteractiveSessionSandboxTestError.invalidResponse
    }
    return try values.map { value in
        guard case let .object(entry) = value else {
            throw InteractiveSessionSandboxTestError.invalidResponse
        }
        return entry
    }
}

private extension Dictionary where Key == String, Value == CodexJSONValue {
    func string(_ key: String) -> String? {
        guard case let .string(value)? = self[key] else {
            return nil
        }
        return value
    }
}

private enum InteractiveSessionSandboxTestError: Swift.Error {
    case invalidResponse
}

private final class InteractiveSessionSandboxFixture {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "CodexDesktopInteractiveSessionSandbox-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
    }

    func url(sessionID: String, relativePath: String) -> URL {
        root
            .appendingPathComponent(sessionID, isDirectory: true)
            .appendingPathComponent(relativePath)
    }

    func write(
        _ data: Data,
        sessionID: String,
        relativePath: String
    ) throws {
        let file = url(
            sessionID: sessionID,
            relativePath: relativePath
        )
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: file)
    }

    func createSymlink(
        sessionID: String,
        relativePath: String,
        destination: URL
    ) throws {
        let link = url(
            sessionID: sessionID,
            relativePath: relativePath
        )
        try FileManager.default.createDirectory(
            at: link.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            at: link,
            withDestinationURL: destination
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
