import Foundation

#if SWIFT_PACKAGE
import CodexPadDomain
#endif

public actor CodexDesktopInteractiveSessionSandboxStore {
    public enum Error: Swift.Error, Equatable, Sendable {
        case invalidSessionID
        case invalidPath
        case pathNotFound
        case notDirectory
        case notFile
        case readLimitExceeded(maximumBytes: Int)
    }

    public static let defaultMaximumReadBytes = 4 * 1024 * 1024

    public nonisolated let root: URL

    private let maximumReadBytes: Int

    public init(
        root: URL,
        maximumReadBytes: Int = defaultMaximumReadBytes
    ) {
        precondition(
            maximumReadBytes >= 0,
            "maximumReadBytes must not be negative"
        )
        self.root = root
            .standardizedFileURL
            .resolvingSymlinksInPath()
        self.maximumReadBytes = maximumReadBytes
    }

    public func list(
        sessionID: String,
        relativePath: String? = nil
    ) throws -> CodexJSONValue {
        if let relativePath, !relativePath.isEmpty {
            _ = try Self.validatedPathComponents(relativePath)
        }
        let session = try sessionRoot(
            sessionID,
            missingSessionIsAllowed: true
        )
        guard session.exists else {
            return .object(["data": .array([])])
        }

        let directory: URL
        if let relativePath, !relativePath.isEmpty {
            directory = try existingURL(
                relativePath: relativePath,
                inside: session.url
            )
        } else {
            directory = session.url
        }
        guard try itemType(at: directory) == .typeDirectory else {
            throw Error.notDirectory
        }

        let records = try recursiveRecords(
            in: directory,
            sessionRoot: session.url
        )
        return .object([
            "data": .array(records.map(\.jsonValue))
        ])
    }

    public func read(
        sessionID: String,
        relativePath: String
    ) throws -> CodexJSONValue {
        _ = try Self.validatedPathComponents(relativePath)
        let session = try sessionRoot(
            sessionID,
            missingSessionIsAllowed: false
        )
        let file = try existingURL(
            relativePath: relativePath,
            inside: session.url
        )
        guard try itemType(at: file) == .typeRegular else {
            throw Error.notFile
        }

        let attributes = try FileManager.default.attributesOfItem(
            atPath: file.path
        )
        let declaredSize = (attributes[.size] as? NSNumber)?.int64Value
        if let declaredSize, declaredSize > Int64(maximumReadBytes) {
            throw Error.readLimitExceeded(
                maximumBytes: maximumReadBytes
            )
        }

        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let readCount = maximumReadBytes == Int.max
            ? maximumReadBytes
            : maximumReadBytes + 1
        let data = try handle.read(upToCount: readCount) ?? Data()
        guard data.count <= maximumReadBytes else {
            throw Error.readLimitExceeded(
                maximumBytes: maximumReadBytes
            )
        }

        return .object([
            "dataBase64": .string(data.base64EncodedString()),
            "path": .string(
                try Self.relativePath(
                    for: file,
                    inside: session.url
                )
            ),
            "sizeBytes": .integer(Int64(data.count)),
        ])
    }

    public func attachmentURLs(
        sessionID: String
    ) throws -> [URL] {
        let session = try sessionRoot(
            sessionID,
            missingSessionIsAllowed: true
        )
        guard session.exists else {
            return []
        }
        return try recursiveRecords(
            in: session.url,
            sessionRoot: session.url
        ).compactMap { record in
            record.type == .file ? record.url : nil
        }
    }

    private func sessionRoot(
        _ sessionID: String,
        missingSessionIsAllowed: Bool
    ) throws -> (url: URL, exists: Bool) {
        guard Self.isValidSessionID(sessionID) else {
            throw Error.invalidSessionID
        }

        let candidate = root
            .appendingPathComponent(sessionID, isDirectory: true)
            .standardizedFileURL
        guard Self.isWithin(candidate, root: root) else {
            throw Error.invalidSessionID
        }

        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: candidate.path) else {
            if missingSessionIsAllowed {
                return (candidate, false)
            }
            throw Error.pathNotFound
        }
        guard try itemType(at: candidate) != .typeSymbolicLink else {
            throw Error.invalidPath
        }

        let canonical = candidate
            .resolvingSymlinksInPath()
            .standardizedFileURL
        guard Self.isWithin(canonical, root: root),
              try itemType(at: canonical) == .typeDirectory
        else {
            throw Error.invalidPath
        }
        return (canonical, true)
    }

    private func existingURL(
        relativePath: String,
        inside sessionRoot: URL
    ) throws -> URL {
        let components = try Self.validatedPathComponents(relativePath)
        var candidate = sessionRoot
        for component in components {
            candidate.appendPathComponent(component)
            guard Self.isWithin(candidate, root: sessionRoot) else {
                throw Error.invalidPath
            }
            guard FileManager.default.fileExists(
                atPath: candidate.path
            ) else {
                throw Error.pathNotFound
            }
            guard try itemType(at: candidate) != .typeSymbolicLink else {
                throw Error.invalidPath
            }
        }

        let canonical = candidate
            .standardizedFileURL
            .resolvingSymlinksInPath()
        guard Self.isWithin(canonical, root: sessionRoot) else {
            throw Error.invalidPath
        }
        return canonical
    }

    private func recursiveRecords(
        in directory: URL,
        sessionRoot: URL
    ) throws -> [Record] {
        var records: [Record] = []
        try appendRecords(
            in: directory,
            sessionRoot: sessionRoot,
            to: &records
        )
        return records.sorted { $0.path < $1.path }
    }

    private func appendRecords(
        in directory: URL,
        sessionRoot: URL,
        to records: inout [Record]
    ) throws {
        let children = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: []
        ).sorted { $0.lastPathComponent < $1.lastPathComponent }

        for lexicalChild in children {
            let child = lexicalChild.standardizedFileURL
            guard Self.isWithin(child, root: sessionRoot) else {
                continue
            }
            let type = try itemType(at: child)
            guard type != .typeSymbolicLink else {
                continue
            }

            let canonical = child
                .resolvingSymlinksInPath()
                .standardizedFileURL
            guard Self.isWithin(canonical, root: sessionRoot) else {
                continue
            }

            switch type {
            case .typeDirectory:
                records.append(
                    try record(
                        for: canonical,
                        type: .directory,
                        sessionRoot: sessionRoot
                    )
                )
                try appendRecords(
                    in: canonical,
                    sessionRoot: sessionRoot,
                    to: &records
                )
            case .typeRegular:
                records.append(
                    try record(
                        for: canonical,
                        type: .file,
                        sessionRoot: sessionRoot
                    )
                )
            default:
                continue
            }
        }
    }

    private func record(
        for url: URL,
        type: Record.ItemType,
        sessionRoot: URL
    ) throws -> Record {
        let attributes = try FileManager.default.attributesOfItem(
            atPath: url.path
        )
        guard let modificationDate =
            attributes[.modificationDate] as? Date
        else {
            throw Error.invalidPath
        }
        let size: Int64?
        if type == .file,
           let number = attributes[.size] as? NSNumber
        {
            size = number.int64Value
        } else {
            size = nil
        }
        return Record(
            url: url,
            path: try Self.relativePath(
                for: url,
                inside: sessionRoot
            ),
            type: type,
            sizeBytes: size,
            modifiedAtMs: Int64(
                (modificationDate.timeIntervalSince1970 * 1_000)
                    .rounded(.towardZero)
            )
        )
    }

    private func itemType(at url: URL) throws -> FileAttributeType {
        let attributes = try FileManager.default.attributesOfItem(
            atPath: url.path
        )
        guard let type = attributes[.type] as? FileAttributeType else {
            throw Error.invalidPath
        }
        return type
    }

    private static func isValidSessionID(_ value: String) -> Bool {
        guard !value.isEmpty,
              value.utf8.count <= 255,
              value == value.trimmingCharacters(
                  in: .whitespacesAndNewlines
              ),
              value != ".",
              value != "..",
              !value.contains("/"),
              !value.contains("\\"),
              value.unicodeScalars.allSatisfy({
                  !CharacterSet.controlCharacters.contains($0)
              })
        else {
            return false
        }
        return true
    }

    private static func validatedPathComponents(
        _ relativePath: String
    ) throws -> [String] {
        guard !relativePath.isEmpty,
              relativePath.utf8.count <= 4_096,
              !relativePath.hasPrefix("/"),
              !relativePath.contains("\\"),
              relativePath.unicodeScalars.allSatisfy({
                  !CharacterSet.controlCharacters.contains($0)
              })
        else {
            throw Error.invalidPath
        }

        let components = relativePath.split(
            separator: "/",
            omittingEmptySubsequences: false
        ).map(String.init)
        guard components.allSatisfy({
            !$0.isEmpty && $0 != "." && $0 != ".."
        }) else {
            throw Error.invalidPath
        }
        return components
    }

    private static func relativePath(
        for url: URL,
        inside root: URL
    ) throws -> String {
        let canonicalRoot = root
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let canonicalURL = url
            .standardizedFileURL
            .resolvingSymlinksInPath()
        guard isWithin(canonicalURL, root: canonicalRoot),
              canonicalURL.path != canonicalRoot.path
        else {
            throw Error.invalidPath
        }
        return String(
            canonicalURL.path.dropFirst(canonicalRoot.path.count + 1)
        )
    }

    private static func isWithin(_ url: URL, root: URL) -> Bool {
        let path = url.standardizedFileURL.path
        let rootPath = root.standardizedFileURL.path
        return path == rootPath
            || path.hasPrefix(
                rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
            )
    }
}

private extension CodexDesktopInteractiveSessionSandboxStore {
    struct Record: Sendable {
        enum ItemType: Sendable {
            case directory
            case file
        }

        let url: URL
        let path: String
        let type: ItemType
        let sizeBytes: Int64?
        let modifiedAtMs: Int64

        var jsonValue: CodexJSONValue {
            .object([
                "modifiedAtMs": .integer(modifiedAtMs),
                "name": .string(url.lastPathComponent),
                "path": .string(path),
                "sizeBytes": sizeBytes.map(CodexJSONValue.integer)
                    ?? .null,
                "type": .string(
                    type == .directory ? "directory" : "file"
                ),
            ])
        }
    }
}
