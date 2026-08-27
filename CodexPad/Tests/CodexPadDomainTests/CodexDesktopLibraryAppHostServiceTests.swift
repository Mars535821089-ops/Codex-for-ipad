import Foundation
import Testing

@testable import CodexPadApplication

private typealias LibraryValue = CodexDesktopAppHostRPC.Value

@Test
func desktopLibraryAppHostListsReleasedGeneratedImageShape() async throws {
    let fixture = try LibraryFixture()
    defer { fixture.remove() }

    let threadDirectory = fixture.generatedImages
        .appendingPathComponent("thread-1", isDirectory: true)
    try FileManager.default.createDirectory(
        at: threadDirectory,
        withIntermediateDirectories: true
    )
    let image = threadDirectory.appendingPathComponent("frame.png")
    let ignored = threadDirectory.appendingPathComponent("notes.txt")
    try Data([0x89, 0x50, 0x4e, 0x47]).write(to: image)
    try Data("ignore".utf8).write(to: ignored)
    try FileManager.default.createSymbolicLink(
        at: threadDirectory.appendingPathComponent("outside.webp"),
        withDestinationURL: fixture.outsideFile
    )

    let service = CodexDesktopLibraryAppHostService(
        workspaceRoot: fixture.workspace,
        generatedImagesDirectory: fixture.generatedImages,
        outputDirectories: [:]
    )
    let response = try await service.invoke(
        method: "listGeneratedImages",
        arguments: nil
    )

    guard case let .array(entries) = response,
          entries.count == 1,
          case let .object(fields) = entries[0]
    else {
        Issue.record("Expected one released generated-image entry")
        return
    }
    #expect(fields["desktopPath"] == .string(image.path))
    #expect(fields["name"] == .string("frame.png"))
    #expect(fields["path"] == .string(image.path))
    #expect(fields["relativePath"] == .string("thread-1/frame.png"))
    #expect(fields["sizeBytes"] == .integer(4))
    #expect(fields["threadId"] == .string("thread-1"))
    guard case let .string(modifiedAt)? = fields["modifiedAt"] else {
        Issue.record("Expected ISO-8601 modifiedAt")
        return
    }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [
        .withInternetDateTime,
        .withFractionalSeconds,
    ]
    #expect(formatter.date(from: modifiedAt) != nil)
}

@Test
func desktopLibraryAppHostListsRecursiveOutputFilesAndRejectsSymlinks()
    async throws
{
    let fixture = try LibraryFixture()
    defer { fixture.remove() }

    let nested = fixture.output
        .appendingPathComponent("nested", isDirectory: true)
    try FileManager.default.createDirectory(
        at: nested,
        withIntermediateDirectories: true
    )
    let first = fixture.output.appendingPathComponent("a.txt")
    let second = nested.appendingPathComponent("b.bin")
    try Data("A".utf8).write(to: first)
    try Data([1, 2, 3]).write(to: second)
    try FileManager.default.createSymbolicLink(
        at: fixture.output.appendingPathComponent("outside.txt"),
        withDestinationURL: fixture.outsideFile
    )

    let service = CodexDesktopLibraryAppHostService(
        workspaceRoot: fixture.workspace,
        generatedImagesDirectory: fixture.generatedImages,
        outputDirectories: ["thread-1": fixture.output]
    )
    let response = try await service.invoke(
        method: "listOutputFiles",
        arguments: nil
    )

    guard case let .array(entries) = response else {
        Issue.record("Expected released output-file array")
        return
    }
    let objects = entries.compactMap { value -> [String: LibraryValue]? in
        guard case let .object(fields) = value else { return nil }
        return fields
    }
    #expect(objects.count == 2)
    #expect(
        objects.compactMap {
            guard case let .string(path)? = $0["path"] else {
                return nil
            }
            return path
        } == [first.path, second.path]
    )
    #expect(objects[0]["relativePath"] == .string("a.txt"))
    #expect(objects[0]["sizeBytes"] == .integer(1))
    #expect(objects[0]["threadId"] == .string("thread-1"))
    #expect(objects[1]["relativePath"] == .string("nested/b.bin"))
    #expect(objects[1]["sizeBytes"] == .integer(3))
}

@Test
func desktopLibraryAppHostPreparesAndReleasesRealPreview() async throws {
    let fixture = try LibraryFixture()
    defer { fixture.remove() }
    let source = fixture.output.appendingPathComponent("report.md")
    let contents = Data("desktop parity".utf8)
    try contents.write(to: source)

    let service = CodexDesktopLibraryAppHostService(
        workspaceRoot: fixture.workspace,
        generatedImagesDirectory: fixture.generatedImages,
        outputDirectories: ["thread-1": fixture.output]
    )
    let prepared = try await service.invoke(
        method: "prepareFilePreview",
        arguments: [
            .object(["sourcePath": .string(source.path)]),
        ]
    )
    guard case let .object(fields) = prepared,
          case let .string(previewPath)? = fields["previewPath"]
    else {
        Issue.record("Expected previewPath")
        return
    }
    #expect(previewPath != source.path)
    #expect(FileManager.default.fileExists(atPath: previewPath))
    #expect(try Data(contentsOf: URL(fileURLWithPath: previewPath)) == contents)

    #expect(
        try await service.invoke(
            method: "releaseFilePreview",
            arguments: [
                .object(["previewPath": .string(previewPath)]),
            ]
        ) == .undefined
    )
    #expect(!FileManager.default.fileExists(atPath: previewPath))

    await #expect(
        throws: CodexDesktopLibraryAppHostService.Error.fileUnavailable
    ) {
        _ = try await service.invoke(
            method: "prepareFilePreview",
            arguments: [
                .object([
                    "sourcePath": .string(fixture.outsideFile.path),
                ]),
            ]
        )
    }
}

@Test
func desktopLibraryAppHostRoutesThumbnailGenerationWithReleasedSizes()
    async throws
{
    let fixture = try LibraryFixture()
    defer { fixture.remove() }
    let image = fixture.generatedImages.appendingPathComponent("cover.webp")
    try Data([1, 2, 3]).write(to: image)
    let recorder = LibraryThumbnailRecorder()
    let service = CodexDesktopLibraryAppHostService(
        workspaceRoot: fixture.workspace,
        generatedImagesDirectory: fixture.generatedImages,
        outputDirectories: [:],
        thumbnailGenerator: { source, pixelSize in
            await recorder.record(source: source, pixelSize: pixelSize)
            return "data:image/png;base64,AA=="
        }
    )

    for (size, pixels) in [("compact", 96), ("large", 320)] {
        #expect(
            try await service.invoke(
                method: "getThumbnailDataUrl",
                arguments: [
                    .object([
                        "size": .string(size),
                        "sourcePath": .string(image.path),
                    ]),
                ]
            ) == .object([
                "dataUrl": .string("data:image/png;base64,AA=="),
            ])
        )
        #expect(await recorder.pixelSizes.last == pixels)
    }
    #expect(await recorder.sources == [image.path, image.path])
}

@Test
func desktopLibraryAppHostReadsOutputDirectoriesDynamically()
    async throws
{
    let fixture = try LibraryFixture()
    defer { fixture.remove() }
    let provider = LibraryOutputDirectoriesProvider()
    let service = CodexDesktopLibraryAppHostService(
        authorizedOutputRoots: [fixture.workspace],
        generatedImagesDirectory: fixture.generatedImages,
        outputDirectoriesProvider: {
            await provider.snapshot()
        }
    )

    #expect(
        try await service.invoke(
            method: "listOutputFiles",
            arguments: nil
        ) == .array([])
    )

    let report = fixture.output.appendingPathComponent("report.md")
    try Data("real output".utf8).write(to: report)
    await provider.set([
        "thread-dynamic": fixture.output,
    ])
    let response = try await service.invoke(
        method: "listOutputFiles",
        arguments: nil
    )
    guard case let .array(entries) = response,
          entries.count == 1,
          case let .object(fields) = entries[0]
    else {
        Issue.record("Expected one dynamic output file")
        return
    }
    #expect(fields["path"] == .string(report.path))
    #expect(fields["threadId"] == .string("thread-dynamic"))
}

@Test
func desktopLibraryAppHostRejectsDynamicOutputsOutsideAuthorizedRoots()
    async throws
{
    let fixture = try LibraryFixture()
    defer { fixture.remove() }
    let outsideDirectory = fixture.root.appendingPathComponent(
        "outside-outputs",
        isDirectory: true
    )
    try FileManager.default.createDirectory(
        at: outsideDirectory,
        withIntermediateDirectories: true
    )
    let outsideOutput = outsideDirectory.appendingPathComponent(
        "leak.txt"
    )
    try Data("outside".utf8).write(to: outsideOutput)
    let service = CodexDesktopLibraryAppHostService(
        authorizedOutputRoots: [fixture.workspace],
        generatedImagesDirectory: fixture.generatedImages,
        outputDirectoriesProvider: {
            ["thread-outside": outsideDirectory]
        }
    )

    #expect(
        try await service.invoke(
            method: "listOutputFiles",
            arguments: nil
        ) == .array([])
    )
    await #expect(
        throws: CodexDesktopLibraryAppHostService.Error.fileUnavailable
    ) {
        _ = try await service.invoke(
            method: "prepareFilePreview",
            arguments: [
                .object([
                    "sourcePath": .string(outsideOutput.path),
                ]),
            ]
        )
    }
}

@Test
func desktopLibraryAppHostRejectsMalformedReleasedRequests() async {
    let fixture: LibraryFixture
    do {
        fixture = try LibraryFixture()
    } catch {
        Issue.record("Fixture failed: \(error)")
        return
    }
    defer { fixture.remove() }
    let service = CodexDesktopLibraryAppHostService(
        workspaceRoot: fixture.workspace,
        generatedImagesDirectory: fixture.generatedImages,
        outputDirectories: [:]
    )

    await #expect(
        throws: CodexDesktopLibraryAppHostService.Error.invalidArguments
    ) {
        _ = try await service.invoke(
            method: "getThumbnailDataUrl",
            arguments: [
                .object([
                    "size": .string("medium"),
                    "sourcePath": .string("/tmp/image.png"),
                ]),
            ]
        )
    }
    await #expect(
        throws: CodexDesktopLibraryAppHostService.Error.unsupportedMethod(
            "missing"
        )
    ) {
        _ = try await service.invoke(
            method: "missing",
            arguments: nil
        )
    }
}

private final class LibraryFixture: @unchecked Sendable {
    let root: URL
    let workspace: URL
    let generatedImages: URL
    let output: URL
    let outsideFile: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        workspace = root.appendingPathComponent("workspace", isDirectory: true)
        generatedImages = root
            .appendingPathComponent("generated_images", isDirectory: true)
        output = workspace.appendingPathComponent("outputs", isDirectory: true)
        outsideFile = root.appendingPathComponent("outside.txt")
        for directory in [workspace, generatedImages, output] {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }
        try Data("outside".utf8).write(to: outsideFile)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

private actor LibraryThumbnailRecorder {
    private(set) var sources: [String] = []
    private(set) var pixelSizes: [Int] = []

    func record(source: URL, pixelSize: Int) {
        sources.append(source.path)
        pixelSizes.append(pixelSize)
    }
}

private actor LibraryOutputDirectoriesProvider {
    private var directories: [String: URL] = [:]

    func set(_ directories: [String: URL]) {
        self.directories = directories
    }

    func snapshot() -> [String: URL] {
        directories
    }
}
