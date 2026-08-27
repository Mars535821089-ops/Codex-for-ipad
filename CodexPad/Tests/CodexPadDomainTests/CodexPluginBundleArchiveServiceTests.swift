import Foundation
import Testing

@testable import CodexPadApplication

@Test
func pluginBundleArchiveRoundTripsNestedPluginDirectory() throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory.appendingPathComponent(
        UUID().uuidString,
        isDirectory: true
    )
    defer { try? fileManager.removeItem(at: root) }
    let source = root.appendingPathComponent(
        "calendar",
        isDirectory: true
    )
    try fileManager.createDirectory(
        at: source.appendingPathComponent(
            "skills/calendar",
            isDirectory: true
        ),
        withIntermediateDirectories: true
    )
    try Data("# Calendar\n".utf8).write(
        to: source.appendingPathComponent(
            "skills/calendar/SKILL.md"
        )
    )
    try Data(
        #"{"name":"calendar","version":"1.0.0"}"#.utf8
    ).write(to: source.appendingPathComponent("plugin.json"))
    let destination = root.appendingPathComponent(
        "checkout",
        isDirectory: true
    )
    let service = CodexPluginBundleArchiveService(
        fileManager: fileManager
    )

    let archive = try service.packDirectory(
        at: source,
        maximumBytes: 50 * 1024 * 1024
    )
    #expect(Array(archive.prefix(3)) == [0x1f, 0x8b, 0x08])
    try service.extractGzipTar(
        archive,
        to: destination,
        maximumExpandedBytes: 50 * 1024 * 1024
    )

    #expect(
        try String(
            contentsOf: destination.appendingPathComponent(
                "skills/calendar/SKILL.md"
            ),
            encoding: .utf8
        ) == "# Calendar\n"
    )
    #expect(
        try String(
            contentsOf:
                destination.appendingPathComponent("plugin.json"),
            encoding: .utf8
        ).contains(#""version":"1.0.0""#)
    )
}

@Test
func pluginBundleArchiveRejectsTraversalAndSizeOverflow() throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory.appendingPathComponent(
        UUID().uuidString,
        isDirectory: true
    )
    defer { try? fileManager.removeItem(at: root) }
    try fileManager.createDirectory(
        at: root,
        withIntermediateDirectories: true
    )
    var randomState: UInt64 = 0x5eed
    var incompressible = Data()
    for _ in 0..<4096 {
        randomState = randomState &* 6_364_136_223_846_793_005 &+ 1
        incompressible.append(UInt8(truncatingIfNeeded: randomState >> 32))
    }
    try incompressible.write(
        to: root.appendingPathComponent("large.bin")
    )
    let service = CodexPluginBundleArchiveService(
        fileManager: fileManager
    )

    #expect(throws: CodexPluginBundleArchiveError.self) {
        _ = try service.packDirectory(
            at: root,
            maximumBytes: 512
        )
    }

    let maliciousTar = CodexPluginBundleArchiveService
        .testingGzipTar(
            path: "../outside.txt",
            contents: Data("bad".utf8)
        )
    #expect(throws: CodexPluginBundleArchiveError.self) {
        try service.extractGzipTar(
            maliciousTar,
            to: root.appendingPathComponent("checkout"),
            maximumExpandedBytes: 1024 * 1024
        )
    }
    #expect(
        !fileManager.fileExists(
            atPath: root.deletingLastPathComponent()
                .appendingPathComponent("outside.txt").path
        )
    )
}

@Test
func pluginBundleArchiveAppliesUploadLimitToCompressedBytes() throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory.appendingPathComponent(
        UUID().uuidString,
        isDirectory: true
    )
    defer { try? fileManager.removeItem(at: root) }
    try fileManager.createDirectory(
        at: root,
        withIntermediateDirectories: true
    )
    try Data(repeating: 0x41, count: 4096).write(
        to: root.appendingPathComponent("compressible.bin")
    )

    let archive = try CodexPluginBundleArchiveService(
        fileManager: fileManager
    ).packDirectory(
        at: root,
        maximumBytes: 512
    )

    #expect(archive.count <= 512)
}

@Test
func pluginBundleArchiveAcceptsStandardGzipOptionalHeaderFields() throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory.appendingPathComponent(
        UUID().uuidString,
        isDirectory: true
    )
    defer { try? fileManager.removeItem(at: root) }
    var archive = CodexPluginBundleArchiveService.testingGzipTar(
        path: "plugin.json",
        contents: Data(#"{"name":"calendar"}"#.utf8)
    )
    archive[3] = 0x08
    archive.insert(
        contentsOf: Data("bundle.tar\u{0}".utf8),
        at: 10
    )
    let destination = root.appendingPathComponent(
        "checkout",
        isDirectory: true
    )

    try CodexPluginBundleArchiveService(
        fileManager: fileManager
    ).extractGzipTar(
        archive,
        to: destination,
        maximumExpandedBytes: 1024 * 1024
    )

    #expect(
        try String(
            contentsOf: destination.appendingPathComponent(
                "plugin.json"
            ),
            encoding: .utf8
        ) == #"{"name":"calendar"}"#
    )
}

@Test
func pluginBundleArchiveAcceptsGitHubStyleGlobalPAXHeader() throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory.appendingPathComponent(
        UUID().uuidString,
        isDirectory: true
    )
    defer { try? fileManager.removeItem(at: root) }
    let destination = root.appendingPathComponent(
        "checkout",
        isDirectory: true
    )

    try CodexPluginBundleArchiveService(
        fileManager: fileManager
    ).extractGzipTar(
        CodexPluginBundleArchiveService
            .testingGzipTarWithGlobalPAX(
                path: "repository/README.md",
                contents: Data("marketplace".utf8)
            ),
        to: destination,
        maximumExpandedBytes: 1024 * 1024
    )

    #expect(
        try String(
            contentsOf: destination.appendingPathComponent(
                "repository/README.md"
            ),
            encoding: .utf8
        ) == "marketplace"
    )
}
