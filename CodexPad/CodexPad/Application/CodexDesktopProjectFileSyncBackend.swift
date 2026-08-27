import CryptoKit
import Foundation

/// Mirrors ChatGPT project files into the released desktop layout below
/// `<codex-home>/.chatgpt-projects/<project-id>`.
///
/// The renderer-owned callback first produces a download request. The injected
/// downloader then resolves that request to bytes, keeping Cap'n Web and HTTP
/// transport details outside the filesystem transaction.
public actor CodexDesktopProjectFileSyncBackend {
    public typealias Value = CodexDesktopAppHostRPC.Value
    public typealias ResolveDownloadRequest =
        @Sendable (Value, String) async throws -> Value
    public typealias Download =
        @Sendable (Value) async throws -> Data

    public enum Error: Swift.Error, Equatable, Sendable {
        case invalidRequest
        case invalidProjectID
        case filesystem
    }

    /// Optional HTTP status carrier used by either transport stage.
    public struct TransferError: Swift.Error, Equatable, Sendable {
        public let status: Int?

        public init(status: Int? = nil) {
            self.status = status
        }
    }

    private struct ProjectFile: Equatable, Sendable {
        let fileID: String
        let name: String
    }

    private struct Request: Sendable {
        let files: [ProjectFile]
        let callback: Value
        let instructions: String
        let projectID: String
        let projectName: String
    }

    private struct Metadata: Codable {
        let files: [MetadataFile]
        let version: Int
    }

    private struct MetadataFile: Codable {
        let fileId: String
        let name: String
        let sha256: String
    }

    private struct FailedFile: Sendable {
        let ordinal: Int
        let stage: String
        let status: Int?

        var value: Value {
            var fields: [String: Value] = [
                "fileOrdinal": .integer(Int64(ordinal)),
                "stage": .string(stage),
            ]
            if let status {
                fields["status"] = .integer(Int64(status))
            }
            return .object(fields)
        }
    }

    private static let projectDirectoryName = ".chatgpt-projects"
    private static let metadataDirectoryName = ".metadata"
    private static let sourcesDirectoryName = "sources"
    private static let metadataVersion = 1
    private static let invalidFilenameCharacters =
        Set(#"<>:"/\|?*"#)

    private let codexHome: URL
    private let fileManager: FileManager
    private let resolveDownloadRequest: ResolveDownloadRequest
    private let download: Download

    public init(
        codexHome: URL,
        resolveDownloadRequest:
            @escaping ResolveDownloadRequest,
        download: @escaping Download
    ) {
        self.codexHome = codexHome.standardizedFileURL
        self.fileManager = .default
        self.resolveDownloadRequest = resolveDownloadRequest
        self.download = download
    }

    public func sync(request value: Value) async throws -> Value {
        let request = try Self.parse(value)
        guard Self.isValidProjectID(request.projectID) else {
            throw Error.invalidProjectID
        }

        let projectsRoot = codexHome.appendingPathComponent(
            Self.projectDirectoryName,
            isDirectory: true
        )
        let projectRoot = projectsRoot.appendingPathComponent(
            request.projectID,
            isDirectory: true
        )
        let stagingRoot = projectsRoot.appendingPathComponent(
            ".\(request.projectID)-staging-\(UUID().uuidString)",
            isDirectory: true
        )
        let previousRoot = projectsRoot.appendingPathComponent(
            ".\(request.projectID)-previous-\(UUID().uuidString)",
            isDirectory: true
        )
        let stagingSources = stagingRoot.appendingPathComponent(
            Self.sourcesDirectoryName,
            isDirectory: true
        )
        let metadataFile = projectsRoot
            .appendingPathComponent(
                Self.metadataDirectoryName,
                isDirectory: true
            )
            .appendingPathComponent("\(request.projectID).json")
        let previousMetadata = loadMetadata(at: metadataFile)
        let files = Self.normalizedFiles(request.files)

        do {
            try fileManager.createDirectory(
                at: stagingSources,
                withIntermediateDirectories: true
            )
            var failures: [FailedFile] = []
            var metadataFiles: [MetadataFile] = []

            for (index, file) in files.enumerated() {
                let ordinal = index + 1
                let destination = stagingSources.appendingPathComponent(
                    file.name
                )
                if let cached = previousMetadata?.files.first(
                    where: {
                        $0.fileId == file.fileID
                            && Self.isSafeStoredFilename($0.name)
                    }
                ),
                    reuseCachedFile(
                        projectRoot: projectRoot,
                        cached: cached,
                        destination: destination
                    )
                {
                    metadataFiles.append(
                        MetadataFile(
                            fileId: file.fileID,
                            name: file.name,
                            sha256: cached.sha256
                        )
                    )
                    continue
                }

                let downloadRequest: Value
                do {
                    downloadRequest = try await resolveDownloadRequest(
                        request.callback,
                        file.fileID
                    )
                } catch {
                    failures.append(
                        FailedFile(
                            ordinal: ordinal,
                            stage: "download-link",
                            status: Self.status(from: error)
                        )
                    )
                    continue
                }

                let data: Data
                do {
                    data = try await download(downloadRequest)
                } catch {
                    failures.append(
                        FailedFile(
                            ordinal: ordinal,
                            stage: "download",
                            status: Self.status(from: error)
                        )
                    )
                    continue
                }

                try data.write(to: destination, options: .atomic)
                try setPermissions(0o444, at: destination)
                metadataFiles.append(
                    MetadataFile(
                        fileId: file.fileID,
                        name: file.name,
                        sha256: Self.sha256(data)
                    )
                )
            }

            let agents = Self.agentsFile(
                projectName: request.projectName,
                instructions: request.instructions,
                failureCount: failures.count
            )
            let agentsURL = stagingRoot.appendingPathComponent("AGENTS.md")
            try Data(agents.utf8).write(to: agentsURL, options: .atomic)
            try setPermissions(0o444, at: agentsURL)

            let hadPrevious = fileManager.fileExists(
                atPath: projectRoot.path
            )
            if hadPrevious {
                try fileManager.moveItem(
                    at: projectRoot,
                    to: previousRoot
                )
            }
            do {
                try fileManager.moveItem(
                    at: stagingRoot,
                    to: projectRoot
                )
            } catch {
                if hadPrevious {
                    try? fileManager.moveItem(
                        at: previousRoot,
                        to: projectRoot
                    )
                }
                throw error
            }
            if hadPrevious {
                try? fileManager.removeItem(at: previousRoot)
            }

            try? writeMetadata(
                Metadata(
                    files: metadataFiles,
                    version: Self.metadataVersion
                ),
                to: metadataFile
            )
            return .object([
                "failedFiles": .array(failures.map(\.value)),
                "rootPath": .string(projectRoot.path),
            ])
        } catch let error as Error {
            try? fileManager.removeItem(at: stagingRoot)
            throw error
        } catch {
            try? fileManager.removeItem(at: stagingRoot)
            throw Error.filesystem
        }
    }

    private func reuseCachedFile(
        projectRoot: URL,
        cached: MetadataFile,
        destination: URL
    ) -> Bool {
        let source = projectRoot
            .appendingPathComponent(
                Self.sourcesDirectoryName,
                isDirectory: true
            )
            .appendingPathComponent(cached.name)
        do {
            try fileManager.copyItem(at: source, to: destination)
            let data = try Data(contentsOf: destination)
            guard Self.sha256(data) == cached.sha256 else {
                try? fileManager.removeItem(at: destination)
                return false
            }
            try setPermissions(0o444, at: destination)
            return true
        } catch {
            try? fileManager.removeItem(at: destination)
            return false
        }
    }

    private func loadMetadata(at url: URL) -> Metadata? {
        guard let data = try? Data(contentsOf: url),
              let metadata = try? JSONDecoder().decode(
                  Metadata.self,
                  from: data
              ),
              metadata.version == Self.metadataVersion,
              metadata.files.allSatisfy({
                  Self.isSHA256($0.sha256)
              })
        else {
            return nil
        }
        return metadata
    }

    private func writeMetadata(
        _ metadata: Metadata,
        to url: URL
    ) throws {
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [
                .posixPermissions: 0o700,
            ]
        )
        var data = try JSONEncoder().encode(metadata)
        data.append(0x0A)
        try data.write(to: url, options: .atomic)
        try setPermissions(0o600, at: url)
    }

    private func setPermissions(
        _ permissions: Int,
        at url: URL
    ) throws {
        try fileManager.setAttributes(
            [.posixPermissions: permissions],
            ofItemAtPath: url.path
        )
    }

    private static func parse(_ value: Value) throws -> Request {
        guard case let .object(fields) = value,
              case let .array(rawFiles)? = fields["files"],
              case let .string(instructions)? = fields["instructions"],
              case let .string(projectID)? = fields["projectId"],
              case let .string(projectName)? = fields["projectName"],
              let callback = fields["getFileDownloadRequest"],
              isRPCTarget(callback)
        else {
            throw Error.invalidRequest
        }
        let files = try rawFiles.map { rawFile -> ProjectFile in
            guard case let .object(fields) = rawFile,
                  case let .string(fileID)? = fields["fileId"],
                  !fileID.trimmingCharacters(
                      in: .whitespacesAndNewlines
                  ).isEmpty,
                  case let .string(name)? = fields["name"],
                  !name.trimmingCharacters(
                      in: .whitespacesAndNewlines
                  ).isEmpty
            else {
                throw Error.invalidRequest
            }
            return ProjectFile(fileID: fileID, name: name)
        }
        return Request(
            files: files,
            callback: callback,
            instructions: instructions,
            projectID: projectID,
            projectName: projectName
        )
    }

    private static func normalizedFiles(
        _ files: [ProjectFile]
    ) -> [ProjectFile] {
        var usedNames = Set<String>()
        return files.map { file in
            let sanitized = sanitizedFilename(file.name)
            let safeName =
                sanitized.isEmpty
                    || sanitized == "."
                    || sanitized == ".."
                ? "file" : sanitized
            let extensionWithDot: String
            let initialStem: String
            let pathExtension = (safeName as NSString).pathExtension
            if pathExtension.isEmpty {
                extensionWithDot = ""
                initialStem = safeName
            } else {
                extensionWithDot = ".\(pathExtension)"
                initialStem = (safeName as NSString)
                    .deletingPathExtension
            }
            var stem =
                isAgentsFilename(safeName)
                ? "\(initialStem) (project file)"
                : initialStem.isEmpty ? "file" : initialStem
            let reservedBase =
                stem.split(separator: ".", maxSplits: 1)
                    .first.map(String.init) ?? stem
            if isWindowsReservedName(reservedBase) {
                stem = "_\(stem)"
            }
            var candidate = "\(stem)\(extensionWithDot)"
            var suffix = 2
            while usedNames.contains(candidate.lowercased()) {
                candidate = "\(stem) (\(suffix))\(extensionWithDot)"
                suffix += 1
            }
            usedNames.insert(candidate.lowercased())
            return ProjectFile(
                fileID: file.fileID,
                name: candidate
            )
        }
    }

    private static func sanitizedFilename(_ rawName: String) -> String {
        let basename = (
            rawName.trimmingCharacters(in: .whitespacesAndNewlines)
                as NSString
        ).lastPathComponent
        let replaced = String(
            basename.unicodeScalars.map { scalar -> Character in
                if scalar.value < 32
                    || invalidFilenameCharacters.contains(
                        Character(String(scalar))
                    )
                {
                    return "_"
                }
                return Character(String(scalar))
            }
        )
        return replaced.replacingOccurrences(
            of: #"[ .]+$"#,
            with: "",
            options: .regularExpression
        )
    }

    private static func isAgentsFilename(_ name: String) -> Bool {
        let lowercased = name.lowercased()
        return lowercased == "agents.md"
            || lowercased == "agents.override.md"
    }

    private static func isWindowsReservedName(_ name: String) -> Bool {
        name.range(
            of: #"^(?:con|prn|aux|nul|com[1-9]|lpt[1-9])$"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }

    private static func isValidProjectID(_ projectID: String) -> Bool {
        guard !projectID.isEmpty,
              projectID != ".",
              projectID != "..",
              projectID.lowercased() != metadataDirectoryName
        else {
            return false
        }
        return projectID.range(
            of: #"^[A-Za-z0-9._-]+$"#,
            options: .regularExpression
        ) != nil
    }

    private static func isRPCTarget(_ value: Value) -> Bool {
        switch value {
        case .rpcObject, .export, .import:
            true
        default:
            false
        }
    }

    private static func isSafeStoredFilename(_ name: String) -> Bool {
        guard !name.isEmpty,
              name != ".",
              name != "..",
              !name.contains("/"),
              !name.contains("\\")
        else {
            return false
        }
        return (name as NSString).lastPathComponent == name
    }

    private static func status(from error: Swift.Error) -> Int? {
        guard let status = (error as? TransferError)?.status,
              (100 ... 599).contains(status)
        else {
            return nil
        }
        return status
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map {
            String(format: "%02x", $0)
        }.joined()
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.range(
            of: #"^[a-f0-9]{64}$"#,
            options: .regularExpression
        ) != nil
    }

    private static func agentsFile(
        projectName: String,
        instructions: String,
        failureCount: Int
    ) -> String {
        let trimmedInstructions = instructions.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let failureLine: String
        if failureCount == 0 {
            failureLine = ""
        } else {
            let noun = failureCount == 1 ? "source" : "sources"
            failureLine =
                "- \(failureCount) project \(noun) could not be synced. "
                + "Do not assume the local mirror is complete.\n"
        }
        let instructionBody =
            trimmedInstructions.isEmpty
            ? "This project has no custom instructions."
            : trimmedInstructions
        return """
        # ChatGPT project context

        This directory is a local mirror of the ChatGPT project “\(projectName)”.

        - Treat every file under `sources/` as read-only reference material.
        - Do not edit, rename, move, or delete synced project files.
        - These files may be replaced the next time a task is created from this ChatGPT project.
        \(failureLine)
        ## Project instructions

        \(instructionBody)
        """
    }
}
