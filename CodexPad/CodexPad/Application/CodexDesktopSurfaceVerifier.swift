import CryptoKit
import Foundation

public struct CodexDesktopSurfaceManifest:
    Codable,
    Equatable,
    Sendable
{
    public struct Entry:
        Codable,
        Equatable,
        Sendable
    {
        public var path: String

        public init(path: String) {
            self.path = path
        }
    }

    public struct CriticalFile:
        Codable,
        Equatable,
        Sendable
    {
        public var path: String
        public var role: String
        public var bytes: Int
        public var sha256: String

        public init(
            path: String,
            role: String,
            bytes: Int,
            sha256: String
        ) {
            self.path = path
            self.role = role
            self.bytes = bytes
            self.sha256 = sha256
        }
    }

    public var schemaVersion: Int
    public var desktopVersion: String
    public var desktopBuild: String
    public var productName: String
    public var ipadProductName: String
    public var resourceDirectoryName: String
    public var resourceFileCount: Int
    public var resourceTotalBytes: Int
    public var resourceTreeSha256: String
    public var entry: Entry
    public var criticalFiles: [CriticalFile]

    public init(
        schemaVersion: Int,
        desktopVersion: String,
        desktopBuild: String,
        productName: String,
        ipadProductName: String,
        resourceDirectoryName: String,
        resourceFileCount: Int,
        resourceTotalBytes: Int,
        resourceTreeSha256: String,
        entry: Entry,
        criticalFiles: [CriticalFile]
    ) {
        self.schemaVersion = schemaVersion
        self.desktopVersion = desktopVersion
        self.desktopBuild = desktopBuild
        self.productName = productName
        self.ipadProductName = ipadProductName
        self.resourceDirectoryName = resourceDirectoryName
        self.resourceFileCount = resourceFileCount
        self.resourceTotalBytes = resourceTotalBytes
        self.resourceTreeSha256 = resourceTreeSha256
        self.entry = entry
        self.criticalFiles = criticalFiles
    }
}

public enum CodexDesktopSurfaceVerificationMode:
    Equatable,
    Sendable
{
    case criticalFiles
    case completeTree
}

public enum CodexDesktopSurfaceVerificationError:
    Error,
    Equatable,
    Sendable
{
    case surfaceDirectoryMissing
    case manifestMissing
    case manifestMalformed
    case unsupportedSchema(Int)
    case productNameMismatch(expected: String, actual: String)
    case resourceDirectoryNameMismatch(expected: String, actual: String)
    case desktopVersionMismatch(expected: String, actual: String)
    case desktopBuildMismatch(expected: String, actual: String)
    case unsafeRelativePath(String)
    case missingFile(path: String)
    case sizeMismatch(path: String)
    case hashMismatch(path: String)
    case resourceFileCountMismatch(expected: Int, actual: Int)
    case resourceTotalBytesMismatch(expected: Int, actual: Int)
    case resourceTreeHashMismatch(expected: String, actual: String)
}

public struct CodexDesktopSurfaceTreeIdentity:
    Equatable,
    Sendable
{
    public let fileCount: Int
    public let totalBytes: Int
    public let sha256: String
}

public struct CodexDesktopSurfaceVerificationResult:
    Equatable,
    Sendable
{
    public let surfaceDirectory: URL
    public let entryURL: URL
    public let manifest: CodexDesktopSurfaceManifest
    public let verifiedFileCount: Int
    public let didVerifyCompleteTree: Bool
}

public enum CodexDesktopSurfaceVerifier {
    private struct ReleasedSurfaceTrustRecord:
        Codable,
        Equatable,
        Sendable
    {
        let schemaVersion: Int
        let desktopVersion: String
        let desktopBuild: String
        let installIdentity: String
        let manifestSha256: String
    }

    public static let resourceDirectoryName = "CodexDesktopSurface"
    public static let manifestFileName = "desktop-surface-manifest.json"
    public static let releasedSurfaceMode:
        CodexDesktopSurfaceVerificationMode = .completeTree
    private static let releasedSurfaceTrustSchemaVersion = 1
    private static let releasedSurfaceTrustFileName =
        "released-surface-trust-v1.json"

    public static func bundledSurfaceDirectory(
        in bundle: Bundle = .main
    ) throws -> URL {
        guard let resources = bundle.resourceURL else {
            throw CodexDesktopSurfaceVerificationError.surfaceDirectoryMissing
        }
        let directory = resources.appending(
            path: resourceDirectoryName,
            directoryHint: .isDirectory
        )
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: directory.path,
            isDirectory: &isDirectory
        ), isDirectory.boolValue else {
            throw CodexDesktopSurfaceVerificationError.surfaceDirectoryMissing
        }
        return directory
    }

    public static func verify(
        surfaceDirectory: URL,
        expectedDesktopVersion: String? = nil,
        expectedDesktopBuild: String? = nil,
        mode: CodexDesktopSurfaceVerificationMode
    ) throws -> CodexDesktopSurfaceVerificationResult {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: surfaceDirectory.path,
            isDirectory: &isDirectory
        ), isDirectory.boolValue else {
            throw CodexDesktopSurfaceVerificationError.surfaceDirectoryMissing
        }

        let manifestURL = surfaceDirectory.appending(path: manifestFileName)
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            throw CodexDesktopSurfaceVerificationError.manifestMissing
        }
        let manifest: CodexDesktopSurfaceManifest
        do {
            manifest = try JSONDecoder().decode(
                CodexDesktopSurfaceManifest.self,
                from: Data(contentsOf: manifestURL)
            )
        } catch {
            throw CodexDesktopSurfaceVerificationError.manifestMalformed
        }

        guard manifest.schemaVersion == 1 else {
            throw CodexDesktopSurfaceVerificationError.unsupportedSchema(
                manifest.schemaVersion
            )
        }
        try requireEqual(
            manifest.productName,
            "Codex",
            error: .productNameMismatch(
                expected: "Codex",
                actual: manifest.productName
            )
        )
        try requireEqual(
            manifest.ipadProductName,
            "Codex for ipad",
            error: .productNameMismatch(
                expected: "Codex for ipad",
                actual: manifest.ipadProductName
            )
        )
        try requireEqual(
            manifest.resourceDirectoryName,
            resourceDirectoryName,
            error: .resourceDirectoryNameMismatch(
                expected: resourceDirectoryName,
                actual: manifest.resourceDirectoryName
            )
        )
        if let expectedDesktopVersion {
            try requireEqual(
                manifest.desktopVersion,
                expectedDesktopVersion,
                error: .desktopVersionMismatch(
                    expected: expectedDesktopVersion,
                    actual: manifest.desktopVersion
                )
            )
        }
        if let expectedDesktopBuild {
            try requireEqual(
                manifest.desktopBuild,
                expectedDesktopBuild,
                error: .desktopBuildMismatch(
                    expected: expectedDesktopBuild,
                    actual: manifest.desktopBuild
                )
            )
        }

        let entryURL = try fileURL(
            relativePath: manifest.entry.path,
            beneath: surfaceDirectory
        )
        guard FileManager.default.fileExists(atPath: entryURL.path) else {
            throw CodexDesktopSurfaceVerificationError.missingFile(
                path: manifest.entry.path
            )
        }

        var seenPaths = Set<String>()
        for file in manifest.criticalFiles {
            _ = try fileURL(relativePath: file.path, beneath: surfaceDirectory)
            guard seenPaths.insert(file.path).inserted else {
                throw CodexDesktopSurfaceVerificationError.manifestMalformed
            }
            let url = try fileURL(
                relativePath: file.path,
                beneath: surfaceDirectory
            )
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw CodexDesktopSurfaceVerificationError.missingFile(
                    path: file.path
                )
            }
            let attributes = try FileManager.default.attributesOfItem(
                atPath: url.path
            )
            let size = (attributes[.size] as? NSNumber)?.intValue
            guard size == file.bytes else {
                throw CodexDesktopSurfaceVerificationError.sizeMismatch(
                    path: file.path
                )
            }
            guard try sha256(of: url) == file.sha256.lowercased() else {
                throw CodexDesktopSurfaceVerificationError.hashMismatch(
                    path: file.path
                )
            }
        }

        if mode == .completeTree {
            let actual = try computeTreeIdentity(
                surfaceDirectory: surfaceDirectory
            )
            guard actual.fileCount == manifest.resourceFileCount else {
                throw CodexDesktopSurfaceVerificationError
                    .resourceFileCountMismatch(
                        expected: manifest.resourceFileCount,
                        actual: actual.fileCount
                    )
            }
            guard actual.totalBytes == manifest.resourceTotalBytes else {
                throw CodexDesktopSurfaceVerificationError
                    .resourceTotalBytesMismatch(
                        expected: manifest.resourceTotalBytes,
                        actual: actual.totalBytes
                    )
            }
            guard
                actual.sha256.lowercased()
                    == manifest.resourceTreeSha256.lowercased()
            else {
                throw CodexDesktopSurfaceVerificationError
                    .resourceTreeHashMismatch(
                        expected: manifest.resourceTreeSha256,
                        actual: actual.sha256
                    )
            }
        }

        return CodexDesktopSurfaceVerificationResult(
            surfaceDirectory: surfaceDirectory,
            entryURL: entryURL,
            manifest: manifest,
            verifiedFileCount: manifest.criticalFiles.count,
            didVerifyCompleteTree: mode == .completeTree
        )
    }

    public static func verifyInBackground(
        surfaceDirectory: URL,
        expectedDesktopVersion: String? = nil,
        expectedDesktopBuild: String? = nil,
        mode: CodexDesktopSurfaceVerificationMode
    ) async throws -> CodexDesktopSurfaceVerificationResult {
        let verification = Task.detached(priority: .userInitiated) {
            try verify(
                surfaceDirectory: surfaceDirectory,
                expectedDesktopVersion: expectedDesktopVersion,
                expectedDesktopBuild: expectedDesktopBuild,
                mode: mode
            )
        }
        return try await withTaskCancellationHandler {
            try await verification.value
        } onCancel: {
            verification.cancel()
        }
    }

    public static func verifyReleasedSurfaceInBackground(
        surfaceDirectory: URL,
        expectedDesktopVersion: String,
        expectedDesktopBuild: String,
        installIdentity: String,
        cacheURL: URL
    ) async throws -> CodexDesktopSurfaceVerificationResult {
        let verification = Task.detached(priority: .userInitiated) {
            let currentTrust = try releasedSurfaceTrustRecord(
                surfaceDirectory: surfaceDirectory,
                expectedDesktopVersion: expectedDesktopVersion,
                expectedDesktopBuild: expectedDesktopBuild,
                installIdentity: installIdentity
            )
            let cachedTrust = try? readReleasedSurfaceTrust(
                from: cacheURL
            )
            let mode: CodexDesktopSurfaceVerificationMode =
                cachedTrust == currentTrust
                    ? .criticalFiles
                    : releasedSurfaceMode
            let result = try verify(
                surfaceDirectory: surfaceDirectory,
                expectedDesktopVersion: expectedDesktopVersion,
                expectedDesktopBuild: expectedDesktopBuild,
                mode: mode
            )
            if mode == releasedSurfaceMode {
                try? writeReleasedSurfaceTrust(
                    currentTrust,
                    to: cacheURL
                )
            }
            return result
        }
        return try await withTaskCancellationHandler {
            try await verification.value
        } onCancel: {
            verification.cancel()
        }
    }

    public static func releasedSurfaceInstallIdentity(
        bundle: Bundle = .main
    ) -> String {
        let codeResourcesURL = bundle.bundleURL
            .appending(
                path: "_CodeSignature",
                directoryHint: .isDirectory
            )
            .appending(path: "CodeResources")
        let signedContentIdentity: String
        if let codeResourcesHash = try? sha256(of: codeResourcesURL) {
            signedContentIdentity = "code-resources:\(codeResourcesHash)"
        } else if let executableURL = bundle.executableURL,
                  let executableHash = try? sha256(of: executableURL)
        {
            signedContentIdentity = "executable:\(executableHash)"
        } else {
            signedContentIdentity = "unsigned-bundle"
        }
        let bundleID = bundle.bundleIdentifier ?? ""
        let desktopVersion = bundle.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? ""
        let desktopBuild = bundle.object(
            forInfoDictionaryKey: "CFBundleVersion"
        ) as? String ?? ""
        let values = [
            "bundle-id:\(bundleID)",
            "version:\(desktopVersion)",
            "build:\(desktopBuild)",
            signedContentIdentity,
        ]
        return hex(SHA256.hash(data: Data(values.joined(
            separator: "\n"
        ).utf8)))
    }

    public static func releasedSurfaceTrustCacheURL(
        fileManager: FileManager = .default
    ) -> URL {
        let root = fileManager.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        ).first ?? fileManager.temporaryDirectory
        return root
            .appending(
                path: "CodexDesktopSurface",
                directoryHint: .isDirectory
            )
            .appending(path: releasedSurfaceTrustFileName)
    }

    public static func computeTreeIdentity(
        surfaceDirectory: URL
    ) throws -> CodexDesktopSurfaceTreeIdentity {
        let keys: [URLResourceKey] = [
            .isRegularFileKey,
            .fileSizeKey,
        ]
        guard let enumerator = FileManager.default.enumerator(
            at: surfaceDirectory,
            includingPropertiesForKeys: keys,
            options: [],
            errorHandler: { _, _ in false }
        ) else {
            throw CodexDesktopSurfaceVerificationError
                .surfaceDirectoryMissing
        }
        var records: [(path: String, url: URL, bytes: Int)] = []
        let rootPath = surfaceDirectory.standardizedFileURL.path
        while let url = enumerator.nextObject() as? URL {
            let values = try url.resourceValues(forKeys: Set(keys))
            guard values.isRegularFile == true else {
                continue
            }
            let standardized = url.standardizedFileURL.path
            guard standardized.hasPrefix(rootPath + "/") else {
                throw CodexDesktopSurfaceVerificationError.unsafeRelativePath(
                    standardized
                )
            }
            let relative = String(
                standardized.dropFirst(rootPath.count + 1)
            )
            if relative == manifestFileName {
                continue
            }
            records.append(
                (
                    path: relative,
                    url: url,
                    bytes: values.fileSize ?? 0
                )
            )
        }
        records.sort { $0.path < $1.path }

        var treeHasher = SHA256()
        var totalBytes = 0
        for record in records {
            let fileHash = try sha256(of: record.url)
            treeHasher.update(data: Data(record.path.utf8))
            treeHasher.update(data: Data([0]))
            treeHasher.update(data: Data(String(record.bytes).utf8))
            treeHasher.update(data: Data([0]))
            treeHasher.update(data: Data(fileHash.utf8))
            treeHasher.update(data: Data([10]))
            totalBytes += record.bytes
        }
        return CodexDesktopSurfaceTreeIdentity(
            fileCount: records.count,
            totalBytes: totalBytes,
            sha256: hex(treeHasher.finalize())
        )
    }

    public static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let data = try handle.read(upToCount: 1_048_576) ?? Data()
            if data.isEmpty {
                break
            }
            hasher.update(data: data)
        }
        return hex(hasher.finalize())
    }

    private static func releasedSurfaceTrustRecord(
        surfaceDirectory: URL,
        expectedDesktopVersion: String,
        expectedDesktopBuild: String,
        installIdentity: String
    ) throws -> ReleasedSurfaceTrustRecord {
        let manifestURL = surfaceDirectory.appending(path: manifestFileName)
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            throw CodexDesktopSurfaceVerificationError.manifestMissing
        }
        return ReleasedSurfaceTrustRecord(
            schemaVersion: releasedSurfaceTrustSchemaVersion,
            desktopVersion: expectedDesktopVersion,
            desktopBuild: expectedDesktopBuild,
            installIdentity: installIdentity,
            manifestSha256: try sha256(of: manifestURL)
        )
    }

    private static func readReleasedSurfaceTrust(
        from cacheURL: URL
    ) throws -> ReleasedSurfaceTrustRecord {
        try JSONDecoder().decode(
            ReleasedSurfaceTrustRecord.self,
            from: Data(contentsOf: cacheURL)
        )
    }

    private static func writeReleasedSurfaceTrust(
        _ record: ReleasedSurfaceTrustRecord,
        to cacheURL: URL
    ) throws {
        try FileManager.default.createDirectory(
            at: cacheURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(record).write(to: cacheURL, options: .atomic)
    }

    private static func fileURL(
        relativePath: String,
        beneath root: URL
    ) throws -> URL {
        let components = relativePath.split(
            separator: "/",
            omittingEmptySubsequences: false
        )
        guard
            !relativePath.hasPrefix("/"),
            !relativePath.hasSuffix("/"),
            !relativePath.contains("\\"),
            !components.isEmpty,
            components.allSatisfy({
                !$0.isEmpty && $0 != "." && $0 != ".."
            })
        else {
            throw CodexDesktopSurfaceVerificationError.unsafeRelativePath(
                relativePath
            )
        }
        let rootPath = root.standardizedFileURL.path
        let url = root.appending(path: relativePath).standardizedFileURL
        guard url.path.hasPrefix(rootPath + "/") else {
            throw CodexDesktopSurfaceVerificationError.unsafeRelativePath(
                relativePath
            )
        }
        return url
    }

    private static func requireEqual<T: Equatable>(
        _ actual: T,
        _ expected: T,
        error: CodexDesktopSurfaceVerificationError
    ) throws {
        guard actual == expected else {
            throw error
        }
    }

    private static func hex<D: Sequence>(_ digest: D) -> String
    where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}
