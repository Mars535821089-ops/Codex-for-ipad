import Foundation
import Testing

@testable import CodexPadApplication

@Test
func desktopWorkspaceAppHostReadsWritesAndDetectsConflicts() async throws {
    let fixture = try AppHostWorkspaceFixture()
    defer { fixture.remove() }
    let service = CodexDesktopWorkspaceAppHostService(
        workspaceRoot: fixture.workspace,
        downloadsDirectory: fixture.downloads,
        temporaryDirectory: fixture.temporary
    )
    let file = fixture.workspace.appendingPathComponent("note.txt")
    try Data("first".utf8).write(to: file)

    let first = try await service.invoke(
        service: "workspaceFiles",
        method: "read",
        arguments: [
            .object([
                "hostId": .string("local"),
                "path": .string(file.path),
                "representation": .string("text"),
            ])
        ]
    )
    guard case let .object(firstFields) = first,
          case let .string(etag)? = firstFields["etag"]
    else {
        Issue.record("read must return the released etag/text shape")
        return
    }
    #expect(firstFields["text"] == .string("first"))

    let saved = try await service.invoke(
        service: "workspaceFiles",
        method: "write",
        arguments: [
            .object([
                "bytes": .array(Array("second".utf8).map {
                    .integer(Int64($0))
                }),
                "hostId": .string("local"),
                "ifMatch": .string(etag),
                "path": .string(file.path),
            ])
        ]
    )
    guard case let .object(savedFields) = saved,
          case let .string(savedETag)? = savedFields["etag"]
    else {
        Issue.record("write must return an etag")
        return
    }
    #expect(savedFields["outcome"] == .string("saved"))
    #expect(try String(contentsOf: file, encoding: .utf8) == "second")

    let conflict = try await service.invoke(
        service: "workspaceFiles",
        method: "write",
        arguments: [
            .object([
                "bytes": .array([.integer(120)]),
                "hostId": .string("local"),
                "ifMatch": .string(etag),
                "path": .string(file.path),
            ])
        ]
    )
    #expect(
        conflict == .object([
            "etag": .string(savedETag),
            "outcome": .string("conflict"),
        ])
    )
}

@Test
func desktopWorkspaceAppHostCopiesCountsAndPersistsImages() async throws {
    let fixture = try AppHostWorkspaceFixture()
    defer { fixture.remove() }
    let service = CodexDesktopWorkspaceAppHostService(
        workspaceRoot: fixture.workspace,
        downloadsDirectory: fixture.downloads,
        temporaryDirectory: fixture.temporary
    )
    let nested = fixture.workspace.appendingPathComponent("nested")
    try FileManager.default.createDirectory(
        at: nested,
        withIntermediateDirectories: true
    )
    let source = nested.appendingPathComponent("asset.txt")
    try Data("asset".utf8).write(to: source)
    try Data("other".utf8).write(
        to: fixture.workspace.appendingPathComponent("other.txt")
    )

    #expect(
        try await service.invoke(
            service: "fileAttachments",
            method: "countFolderFiles",
            arguments: [
                .object([
                    "folderPath": .string(fixture.workspace.path),
                    "hostId": .string("local"),
                ])
            ]
        ) == .integer(2)
    )

    #expect(
        try await service.invoke(
            service: "workspaceFiles",
            method: "downloadCopy",
            arguments: [
                .object([
                    "hostId": .string("local"),
                    "path": .string(source.path),
                ])
            ]
        ) == .undefined
    )
    #expect(
        FileManager.default.fileExists(
            atPath: fixture.downloads
                .appendingPathComponent("asset.txt").path
        )
    )

    let image = try await service.invoke(
        service: "fileAttachments",
        method: "persistImageFileToTemp",
        arguments: [
            .object([
                "bytes": .array([.integer(137), .integer(80)]),
                "mimeType": .string("image/png"),
            ])
        ]
    )
    guard case let .string(imagePath) = image else {
        Issue.record("supported image MIME must return a path")
        return
    }
    #expect(imagePath.hasSuffix(".png"))
    #expect(FileManager.default.fileExists(atPath: imagePath))
}

private struct AppHostWorkspaceFixture {
    let root: URL
    let workspace: URL
    let downloads: URL
    let temporary: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        workspace = root.appendingPathComponent("workspace")
        downloads = root.appendingPathComponent("downloads")
        temporary = root.appendingPathComponent("tmp")
        for directory in [workspace, downloads, temporary] {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
