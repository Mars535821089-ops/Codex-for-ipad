import CryptoKit
import Foundation

/// Native implementation of the released `workspaceFiles` and
/// `fileAttachments` AppHost services.
///
/// The desktop host accepts platform paths. On iPadOS those paths are confined
/// to the selected app workspace; temporary previews and downloaded copies are
/// created in explicit app-owned directories.
public actor CodexDesktopWorkspaceAppHostService {
    public typealias Value = CodexDesktopAppHostRPC.Value

    public enum Error: Swift.Error, Equatable, Sendable {
        case invalidArguments
        case invalidPath
        case unsupportedMethod(service: String, method: String)
    }

    public static let maximumBytes = 256 * 1_024 * 1_024

    private let workspaceRoot: URL
    private let downloadsDirectory: URL
    private let temporaryDirectory: URL
    private let fileManager: FileManager
    private var temporaryFilePaths = Set<String>()

    public init(
        workspaceRoot: URL,
        downloadsDirectory: URL,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory,
        fileManager: FileManager = .default
    ) {
        self.workspaceRoot = workspaceRoot.standardizedFileURL
        self.downloadsDirectory =
            downloadsDirectory.standardizedFileURL
        self.temporaryDirectory =
            temporaryDirectory.standardizedFileURL
        self.fileManager = fileManager
    }

    public func invoke(
        service: String,
        method: String,
        arguments: [Value]?
    ) throws -> Value {
        switch (service, method) {
        case ("fileAttachments", "countFolderFiles"):
            let fields = try argumentObject(arguments)
            let folder = try requiredPath(
                named: "folderPath",
                in: fields
            )
            return .integer(Int64(try countFiles(in: folder)))

        case ("fileAttachments", "persistImageFileToTemp"):
            let fields = try argumentObject(arguments)
            guard case let .string(mimeType)? = fields["mimeType"],
                  let fileExtension = [
                      "image/gif": "gif",
                      "image/jpeg": "jpg",
                      "image/png": "png",
                      "image/webp": "webp",
                  ][mimeType]
            else {
                return .null
            }
            let bytes = try Self.bytes(fields["bytes"])
            try enforceMaximum(bytes.count)
            try ensureDirectory(temporaryDirectory)
            let file = temporaryDirectory.appendingPathComponent(
                "codex-clipboard-\(UUID().uuidString).\(fileExtension)"
            )
            try bytes.write(to: file, options: .withoutOverwriting)
            temporaryFilePaths.insert(file.path)
            return .string(file.path)

        case ("workspaceFiles", "createTemporaryFile"):
            let fields = try argumentObject(arguments)
            let bytes = try Self.bytes(fields["bytes"])
            try enforceMaximum(bytes.count)
            guard case let .string(fileName)? = fields["fileName"] else {
                throw Error.invalidArguments
            }
            let directory = temporaryDirectory.appendingPathComponent(
                "codex-file-preview-\(UUID().uuidString)",
                isDirectory: true
            )
            try ensureDirectory(directory)
            let file = directory.appendingPathComponent(
                Self.previewFileName(fileName)
            )
            try bytes.write(to: file, options: .withoutOverwriting)
            temporaryFilePaths.insert(file.path)
            return .object(["path": .string(file.path)])

        case ("workspaceFiles", "downloadCopy"):
            let fields = try argumentObject(arguments)
            let source = try requiredPath(named: "path", in: fields)
            try ensureDirectory(downloadsDirectory)
            let parsedName = source.deletingPathExtension()
                .lastPathComponent
            let pathExtension = source.pathExtension
            var index = 0
            while true {
                let suffix = index == 0 ? "" : " (\(index))"
                let base = parsedName + suffix
                let name = pathExtension.isEmpty
                    ? base
                    : "\(base).\(pathExtension)"
                let destination = downloadsDirectory
                    .appendingPathComponent(name)
                do {
                    try fileManager.copyItem(
                        at: source,
                        to: destination
                    )
                    return .undefined
                } catch CocoaError.fileWriteFileExists {
                    index += 1
                }
            }

        case ("workspaceFiles", "getDownloadsFolderIcon"):
            // The renderer treats a missing platform icon as optional.
            return .null

        case ("workspaceFiles", "read"):
            let fields = try argumentObject(arguments)
            let file = try requiredPath(named: "path", in: fields)
            guard case let .string(representation)? =
                fields["representation"]
            else {
                throw Error.invalidArguments
            }
            let data = try Data(
                contentsOf: file,
                options: [.mappedIfSafe]
            )
            try enforceMaximum(data.count)
            var response = ["etag": Value.string(try etag(for: file))]
            switch representation {
            case "text":
                guard let text = String(data: data, encoding: .utf8) else {
                    throw Error.invalidArguments
                }
                response["text"] = .string(text)
            case "blob":
                response["blob"] = .string(data.base64EncodedString())
            case "auto":
                if let text = String(data: data, encoding: .utf8),
                   !text.unicodeScalars.contains(where: {
                       $0.value == 0
                   })
                {
                    response["text"] = .string(text)
                } else {
                    response["blob"] = .string(
                        data.base64EncodedString()
                    )
                }
            default:
                throw Error.invalidArguments
            }
            return .object(response)

        case ("workspaceFiles", "releaseTemporaryFile"):
            let fields = try argumentObject(arguments)
            guard case let .string(path)? = fields["path"] else {
                throw Error.invalidArguments
            }
            if temporaryFilePaths.remove(path) != nil {
                let file = URL(fileURLWithPath: path)
                try? fileManager.removeItem(
                    at: file.deletingLastPathComponent()
                )
            }
            return .undefined

        case ("workspaceFiles", "write"):
            let fields = try argumentObject(arguments)
            let data = try Self.bytes(fields["bytes"])
            if data.count > Self.maximumBytes {
                return .object([
                    "maxBytes": .integer(Int64(Self.maximumBytes)),
                    "outcome": .string("too-large"),
                ])
            }
            let file = try requiredPath(
                named: "path",
                in: fields,
                allowMissing: true
            )
            if case let .string(expected)? = fields["ifMatch"] {
                let current = try etagIfPresent(for: file)
                if current != expected {
                    return .object([
                        "etag": .string(current),
                        "outcome": .string("conflict"),
                    ])
                }
            }
            try ensureDirectory(file.deletingLastPathComponent())
            try data.write(to: file, options: .atomic)
            return .object([
                "etag": .string(try etag(for: file)),
                "outcome": .string("saved"),
            ])

        default:
            throw Error.unsupportedMethod(
                service: service,
                method: method
            )
        }
    }

    private func argumentObject(
        _ arguments: [Value]?
    ) throws -> [String: Value] {
        guard case let .object(fields)? = arguments?.first else {
            throw Error.invalidArguments
        }
        return fields
    }

    private func requiredPath(
        named name: String,
        in fields: [String: Value],
        allowMissing: Bool = false
    ) throws -> URL {
        guard case let .string(path)? = fields[name] else {
            throw Error.invalidArguments
        }
        let candidate = URL(fileURLWithPath: path)
            .standardizedFileURL
        let root = workspaceRoot.resolvingSymlinksInPath()
        let checked = candidate.resolvingSymlinksInPath()
        let rootPrefix = root.path.hasSuffix("/")
            ? root.path
            : root.path + "/"
        guard checked.path == root.path
            || checked.path.hasPrefix(rootPrefix)
        else {
            throw Error.invalidPath
        }
        if !allowMissing {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(
                atPath: checked.path,
                isDirectory: &isDirectory
            ) else {
                throw Error.invalidPath
            }
        }
        return checked
    }

    private func countFiles(in folder: URL) throws -> Int {
        let keys: [URLResourceKey] = [
            .isRegularFileKey,
            .isDirectoryKey,
            .isSymbolicLinkKey,
        ]
        guard let enumerator = fileManager.enumerator(
            at: folder,
            includingPropertiesForKeys: keys,
            options: [.skipsPackageDescendants]
        ) else {
            throw Error.invalidPath
        }
        var count = 0
        for case let file as URL in enumerator {
            let values = try file.resourceValues(
                forKeys: Set(keys)
            )
            if values.isSymbolicLink == true {
                enumerator.skipDescendants()
            } else if values.isRegularFile == true {
                count += 1
            }
        }
        return count
    }

    private func ensureDirectory(_ directory: URL) throws {
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
    }

    private func enforceMaximum(_ count: Int) throws {
        guard count <= Self.maximumBytes else {
            throw Error.invalidArguments
        }
    }

    private func etagIfPresent(for file: URL) throws -> String {
        guard fileManager.fileExists(atPath: file.path) else {
            return "missing"
        }
        return try etag(for: file)
    }

    private func etag(for file: URL) throws -> String {
        let attributes = try fileManager.attributesOfItem(
            atPath: file.path
        )
        let modified = (
            attributes[.modificationDate] as? Date
        )?.timeIntervalSince1970 ?? 0
        let created = (
            attributes[.creationDate] as? Date
        )?.timeIntervalSince1970 ?? 0
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        let input = "\(modified * 1000):\(created * 1000):\(size)"
        let digest = SHA256.hash(data: Data(input.utf8))
        let encoded = Data(digest).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "stat:\(encoded)"
    }

    private static func bytes(_ value: Value?) throws -> Data {
        guard case let .array(values)? = value else {
            throw Error.invalidArguments
        }
        var bytes = [UInt8]()
        bytes.reserveCapacity(values.count)
        for value in values {
            guard case let .integer(integer) = value,
                  (0 ... 255).contains(integer)
            else {
                throw Error.invalidArguments
            }
            bytes.append(UInt8(integer))
        }
        return Data(bytes)
    }

    private static func previewFileName(_ requestedName: String) -> String {
        let normalized = requestedName.replacingOccurrences(
            of: "\\",
            with: "/"
        )
        let component = URL(fileURLWithPath: normalized)
            .lastPathComponent
        let pathExtension = URL(fileURLWithPath: component)
            .pathExtension.lowercased()
        guard (1 ... 16).contains(pathExtension.count),
              pathExtension.allSatisfy({
                  $0.isASCII && ($0.isLetter || $0.isNumber)
              })
        else {
            return "preview"
        }
        return "preview.\(pathExtension)"
    }
}
