import Foundation

#if canImport(ImageIO)
import ImageIO
#endif

/// Native iPadOS implementation of the released `libraryFiles` AppHost
/// service. It enumerates real generated/output files, exposes thumbnails,
/// and creates isolated read-only previews without granting the renderer
/// arbitrary filesystem access.
public actor CodexDesktopLibraryAppHostService {
    public typealias Value = CodexDesktopAppHostRPC.Value
    public typealias ThumbnailGenerator =
        @Sendable (URL, Int) async throws -> String?
    public typealias OutputDirectoriesProvider =
        @Sendable () async -> [String: URL]

    public enum Error: Swift.Error, Equatable, Sendable {
        case invalidArguments
        case fileUnavailable
        case unsupportedMethod(String)
    }

    private struct OutputRoot: Sendable {
        let url: URL
        let threadID: String?
    }

    private let authorizedOutputRoots: [URL]
    private let generatedImagesDirectory: URL
    private let outputDirectoriesProvider:
        OutputDirectoriesProvider
    private let thumbnailGenerator: ThumbnailGenerator
    private var previewDirectoriesByPath: [String: URL] = [:]

    public init(
        workspaceRoot: URL,
        generatedImagesDirectory: URL,
        outputDirectories: [String: URL],
        thumbnailGenerator: ThumbnailGenerator? = nil
    ) {
        self.authorizedOutputRoots = [
            workspaceRoot.standardizedFileURL
        ]
        self.generatedImagesDirectory =
            generatedImagesDirectory.standardizedFileURL
        self.outputDirectoriesProvider = {
            outputDirectories
        }
        self.thumbnailGenerator =
            thumbnailGenerator ?? Self.generateThumbnail
    }

    public init(
        authorizedOutputRoots: [URL],
        generatedImagesDirectory: URL,
        outputDirectoriesProvider:
            @escaping OutputDirectoriesProvider,
        thumbnailGenerator: ThumbnailGenerator? = nil
    ) {
        self.authorizedOutputRoots = authorizedOutputRoots.map {
            $0.standardizedFileURL
        }
        self.generatedImagesDirectory =
            generatedImagesDirectory.standardizedFileURL
        self.outputDirectoriesProvider =
            outputDirectoriesProvider
        self.thumbnailGenerator =
            thumbnailGenerator ?? Self.generateThumbnail
    }

    public func invoke(
        method: String,
        arguments: [Value]?
    ) async throws -> Value {
        switch method {
        case "listGeneratedImages":
            try Self.requireNoArguments(arguments)
            return .array(listGeneratedImages())

        case "listOutputFiles":
            try Self.requireNoArguments(arguments)
            return .array(await listOutputFiles())

        case "getThumbnailDataUrl":
            let fields = try Self.argumentObject(arguments)
            guard let size = Self.string(fields["size"]),
                  let sourcePath = Self.string(fields["sourcePath"]),
                  let pixelSize = Self.thumbnailPixelSize(size)
            else {
                throw Error.invalidArguments
            }
            let source = try await allowedFile(
                atPath: sourcePath
            )
            let dataURL = try await thumbnailGenerator(
                source,
                pixelSize
            )
            return .object([
                "dataUrl": dataURL.map(Value.string) ?? .null,
            ])

        case "prepareFilePreview":
            let fields = try Self.argumentObject(arguments)
            guard let sourcePath = Self.string(fields["sourcePath"])
            else {
                throw Error.invalidArguments
            }
            return .object([
                "previewPath": .string(
                    try await prepareFilePreview(
                        sourcePath: sourcePath
                    )
                ),
            ])

        case "releaseFilePreview":
            let fields = try Self.argumentObject(arguments)
            guard let previewPath = Self.string(fields["previewPath"])
            else {
                throw Error.invalidArguments
            }
            releaseFilePreview(previewPath: previewPath)
            return .undefined

        default:
            throw Error.unsupportedMethod(method)
        }
    }

    private func listGeneratedImages() -> [Value] {
        guard let root = realDirectory(
            generatedImagesDirectory,
            constrainedTo: nil
        ) else {
            return []
        }
        return enumerateFiles(
            root: root,
            include: {
                Self.generatedImageExtensions.contains(
                    $0.pathExtension.lowercased()
                )
            }
        ).map { file in
            let relativePath = Self.relativePath(
                from: root,
                to: file.url
            )
            let separator = relativePath.firstIndex(of: "/")
            let threadID = separator.map {
                String(relativePath[..<$0])
            }
            return .object([
                "desktopPath": .string(file.url.path),
                "modifiedAt": .string(Self.iso8601(file.modifiedAt)),
                "name": .string(file.url.lastPathComponent),
                "path": .string(file.url.path),
                "relativePath": .string(relativePath),
                "sizeBytes": .integer(Int64(file.size)),
                "threadId": threadID.map(Value.string) ?? .null,
            ])
        }
    }

    private func listOutputFiles() async -> [Value] {
        var entriesByPath: [String: Value] = [:]
        for configuredRoot in await currentOutputRoots() {
            let root = configuredRoot.url
            for file in enumerateFiles(root: root, include: { _ in true }) {
                guard entriesByPath[file.url.path] == nil else {
                    continue
                }
                entriesByPath[file.url.path] = .object([
                    "modifiedAt": .string(
                        Self.iso8601(file.modifiedAt)
                    ),
                    "name": .string(file.url.lastPathComponent),
                    "path": .string(file.url.path),
                    "relativePath": .string(
                        Self.relativePath(from: root, to: file.url)
                    ),
                    "sizeBytes": .integer(Int64(file.size)),
                    "threadId": configuredRoot.threadID
                        .map(Value.string) ?? .null,
                ])
            }
        }
        return entriesByPath.keys.sorted().compactMap {
            entriesByPath[$0]
        }
    }

    private func prepareFilePreview(
        sourcePath: String
    ) async throws -> String {
        let source = try await allowedFile(atPath: sourcePath)
        let data: Data
        do {
            data = try Data(contentsOf: source)
        } catch {
            throw Error.fileUnavailable
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "codex-library-preview-\(UUID().uuidString)",
                isDirectory: true
            )
        let filename = source.lastPathComponent.isEmpty
            ? "preview"
            : source.lastPathComponent
        let destination = directory.appendingPathComponent(filename)
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            try data.write(to: destination, options: .withoutOverwriting)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: destination.path
            )
            previewDirectoriesByPath[destination.path] = directory
            return destination.path
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw Error.fileUnavailable
        }
    }

    private func releaseFilePreview(previewPath: String) {
        guard let directory = previewDirectoriesByPath.removeValue(
            forKey: URL(fileURLWithPath: previewPath)
                .standardizedFileURL.path
        ) else {
            return
        }
        try? FileManager.default.removeItem(at: directory)
    }

    private func allowedFile(
        atPath path: String
    ) async throws -> URL {
        let candidate = URL(fileURLWithPath: path).standardizedFileURL
        guard let values = try? candidate.resourceValues(
            forKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey,
            ]
        ),
        values.isRegularFile == true,
        values.isSymbolicLink != true
        else {
            throw Error.fileUnavailable
        }

        let realCandidate = candidate.resolvingSymlinksInPath()
            .standardizedFileURL
        let roots = await allowedRealDirectories()
        guard roots.contains(where: {
            Self.isStrictDescendant(realCandidate, of: $0)
        }) else {
            throw Error.fileUnavailable
        }
        return realCandidate
    }

    private func allowedRealDirectories() async -> [URL] {
        var roots: [URL] = []
        if let generated = realDirectory(
            generatedImagesDirectory,
            constrainedTo: nil
        ) {
            roots.append(generated)
        }
        roots.append(
            contentsOf: await currentOutputRoots().map(\.url)
        )
        return roots
    }

    private func currentOutputRoots() async -> [OutputRoot] {
        let outputDirectories = await outputDirectoriesProvider()
        let grouped = Dictionary(
            grouping: outputDirectories,
            by: { $0.value.standardizedFileURL.path }
        )
        let realAuthorizedRoots = authorizedOutputRoots.compactMap {
            realDirectory($0, constrainedTo: nil)
        }
        return grouped.keys.sorted().compactMap { path in
            guard let entries = grouped[path],
                  let first = entries.first,
                  let realOutput = realAuthorizedRoots
                    .compactMap({
                        realDirectory(
                            first.value,
                            constrainedTo: $0
                        )
                    })
                    .first
            else {
                return nil
            }
            let threadIDs = Set(entries.map(\.key))
            return OutputRoot(
                url: realOutput,
                threadID: threadIDs.count == 1
                    ? threadIDs.first
                    : nil
            )
        }
    }

    private func realDirectory(
        _ url: URL,
        constrainedTo parent: URL?
    ) -> URL? {
        let standardized = url.standardizedFileURL
        guard let values = try? standardized.resourceValues(
            forKeys: [
                .isDirectoryKey,
                .isSymbolicLinkKey,
            ]
        ),
        values.isDirectory == true,
        values.isSymbolicLink != true
        else {
            return nil
        }
        let real = standardized.resolvingSymlinksInPath()
            .standardizedFileURL
        if let parent,
           !Self.isStrictDescendant(real, of: parent)
        {
            return nil
        }
        return real
    }

    private struct FileEntry {
        let url: URL
        let modifiedAt: Date
        let size: Int
    }

    private func enumerateFiles(
        root: URL,
        include: (URL) -> Bool
    ) -> [FileEntry] {
        var entries: [FileEntry] = []
        var pending = [root]
        while let directory = pending.popLast() {
            let children: [URL]
            do {
                children = try FileManager.default.contentsOfDirectory(
                    at: directory,
                    includingPropertiesForKeys: [
                        .contentModificationDateKey,
                        .fileSizeKey,
                        .isDirectoryKey,
                        .isRegularFileKey,
                        .isSymbolicLinkKey,
                    ],
                    options: []
                )
            } catch {
                continue
            }
            for child in children {
                guard let values = try? child.resourceValues(
                    forKeys: [
                        .contentModificationDateKey,
                        .fileSizeKey,
                        .isDirectoryKey,
                        .isRegularFileKey,
                        .isSymbolicLinkKey,
                    ]
                ),
                values.isSymbolicLink != true
                else {
                    continue
                }
                let realChild = child.resolvingSymlinksInPath()
                    .standardizedFileURL
                guard Self.isStrictDescendant(realChild, of: root)
                else {
                    continue
                }
                if values.isDirectory == true {
                    pending.append(realChild)
                } else if values.isRegularFile == true,
                          include(realChild)
                {
                    entries.append(
                        FileEntry(
                            url: realChild,
                            modifiedAt:
                                values.contentModificationDate ?? .distantPast,
                            size: values.fileSize ?? 0
                        )
                    )
                }
            }
        }
        return entries.sorted { $0.url.path < $1.url.path }
    }

    private static let generatedImageExtensions: Set<String> = [
        "avif",
        "bmp",
        "gif",
        "heic",
        "heif",
        "jpeg",
        "jpg",
        "png",
        "tif",
        "tiff",
        "webp",
    ]

    private static func argumentObject(
        _ arguments: [Value]?
    ) throws -> [String: Value] {
        guard arguments?.count == 1,
              case let .object(fields)? = arguments?.first
        else {
            throw Error.invalidArguments
        }
        return fields
    }

    private static func requireNoArguments(
        _ arguments: [Value]?
    ) throws {
        guard arguments == nil || arguments?.isEmpty == true else {
            throw Error.invalidArguments
        }
    }

    private static func string(_ value: Value?) -> String? {
        guard case let .string(string)? = value,
              !string.isEmpty
        else {
            return nil
        }
        return string
    }

    private static func thumbnailPixelSize(_ size: String) -> Int? {
        switch size {
        case "compact":
            return 96
        case "large":
            return 320
        default:
            return nil
        }
    }

    private static func relativePath(from root: URL, to file: URL) -> String {
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        return String(file.path.dropFirst(prefix.count))
    }

    private static func isStrictDescendant(
        _ candidate: URL,
        of root: URL
    ) -> Bool {
        let rootPath = root.standardizedFileURL.path
        let candidatePath = candidate.standardizedFileURL.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        return candidatePath.hasPrefix(prefix)
    }

    private static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [
            .withInternetDateTime,
            .withFractionalSeconds,
        ]
        return formatter.string(from: date)
    }

    private static func generateThumbnail(
        source: URL,
        pixelSize: Int
    ) async throws -> String? {
        #if canImport(ImageIO)
        guard let imageSource = CGImageSourceCreateWithURL(
            source as CFURL,
            nil
        ) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: pixelSize,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(
            imageSource,
            0,
            options as CFDictionary
        ) else {
            return nil
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            "public.png" as CFString,
            1,
            nil
        ) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            return nil
        }
        return "data:image/png;base64,"
            + (data as Data).base64EncodedString()
        #else
        return nil
        #endif
    }
}
