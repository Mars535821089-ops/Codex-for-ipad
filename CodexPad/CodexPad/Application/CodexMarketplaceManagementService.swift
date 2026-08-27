#if SWIFT_PACKAGE
import CodexPadDomain
#endif
import CryptoKit
import Foundation

public struct CodexMarketplaceAddResult: Equatable, Sendable {
    public let marketplaceName: String
    public let installedRoot: String
    public let alreadyAdded: Bool
}

public struct CodexMarketplaceRemoveResult: Equatable, Sendable {
    public let marketplaceName: String
    public let installedRoot: String?
}

public struct CodexMarketplaceUpgradeErrorInfo:
    Equatable,
    Sendable
{
    public let marketplaceName: String
    public let message: String
}

public struct CodexMarketplaceUpgradeResult:
    Equatable,
    Sendable
{
    public let selectedMarketplaces: [String]
    public let upgradedRoots: [String]
    public let errors: [CodexMarketplaceUpgradeErrorInfo]
}

public enum CodexMarketplaceManagementError:
    Error,
    Equatable,
    Sendable
{
    case invalidRequest(String)
    case internalFailure(String)
}

public protocol CodexMarketplaceGitInstalling: Sendable {
    func install(
        source: String,
        refName: String?,
        sparsePaths: [String],
        destination: URL
    ) async throws -> String
}

/// iPad-native GitHub marketplace installer. It uses GitHub's source archive
/// endpoint rather than launching a desktop `git` process, then returns the
/// archive digest as the revision used by upgrade comparisons.
public struct CodexMarketplaceGitArchiveInstaller:
    CodexMarketplaceGitInstalling,
    @unchecked Sendable
{
    private let transport: any CodexDesktopNetworkFetchTransport
    private let archiveService: any CodexPluginBundleArchiving
    private let fileManager: FileManager

    public init(
        transport:
            any CodexDesktopNetworkFetchTransport =
                CodexDesktopURLSessionNetworkFetchTransport(),
        archiveService:
            any CodexPluginBundleArchiving =
                CodexPluginBundleArchiveService(),
        fileManager: FileManager = .default
    ) {
        self.transport = transport
        self.archiveService = archiveService
        self.fileManager = fileManager
    }

    public func install(
        source: String,
        refName: String?,
        sparsePaths: [String],
        destination: URL
    ) async throws -> String {
        let repository = try Self.githubRepository(source)
        let revision = refName?.isEmpty == false ? refName! : "HEAD"
        guard let encodedRevision = revision.addingPercentEncoding(
            withAllowedCharacters: .urlPathAllowed
        ),
              let url = URL(
                  string:
                    "https://codeload.github.com/\(repository.owner)/"
                    + "\(repository.name)/tar.gz/\(encodedRevision)"
              )
        else {
            throw CodexMarketplaceManagementError.invalidRequest(
                "invalid GitHub marketplace source"
            )
        }
        let response = try await transport.execute(
            CodexDesktopNetworkTransportRequest(
                url: url,
                method: "GET",
                headers: ["Accept": "application/octet-stream"],
                body: nil
            )
        )
        guard (200..<300).contains(response.status) else {
            throw CodexMarketplaceManagementError.internalFailure(
                "GitHub marketplace download failed with HTTP "
                    + "\(response.status)"
            )
        }
        let extraction = destination.deletingLastPathComponent()
            .appendingPathComponent(
                ".archive-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? fileManager.removeItem(at: extraction) }
        try archiveService.extractGzipTar(
            response.body,
            to: extraction,
            maximumExpandedBytes: 512 * 1_024 * 1_024
        )
        let roots = try fileManager.contentsOfDirectory(
            at: extraction,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        guard roots.count == 1,
              try roots[0].resourceValues(
                  forKeys: [.isDirectoryKey]
              ).isDirectory == true
        else {
            throw CodexMarketplaceManagementError.internalFailure(
                "GitHub marketplace archive has no single repository root"
            )
        }
        if sparsePaths.isEmpty {
            try fileManager.moveItem(at: roots[0], to: destination)
        } else {
            try fileManager.createDirectory(
                at: destination,
                withIntermediateDirectories: true
            )
            do {
                for path in sparsePaths {
                    let relative = try Self.safeRelativePath(path)
                    let sourceURL = roots[0].appendingPathComponent(relative)
                    guard fileManager.fileExists(atPath: sourceURL.path)
                    else {
                        throw CodexMarketplaceManagementError
                            .invalidRequest(
                                "sparse path does not exist: \(path)"
                            )
                    }
                    let target = destination.appendingPathComponent(relative)
                    try fileManager.createDirectory(
                        at: target.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    try fileManager.copyItem(at: sourceURL, to: target)
                }
            } catch {
                try? fileManager.removeItem(at: destination)
                throw error
            }
        }
        return SHA256.hash(data: response.body).map {
            String(format: "%02x", $0)
        }.joined()
    }

    private static func githubRepository(
        _ source: String
    ) throws -> (owner: String, name: String) {
        var candidate = source
        if source.hasPrefix("git@github.com:") {
            candidate = String(
                source.dropFirst("git@github.com:".count)
            )
        } else if let url = URL(string: source),
                  url.host?.lowercased() == "github.com"
        {
            candidate = url.path.trimmingCharacters(
                in: CharacterSet(charactersIn: "/")
            )
        }
        if candidate.hasSuffix(".git") {
            candidate.removeLast(4)
        }
        let parts = candidate.split(separator: "/").map(String.init)
        guard parts.count == 2,
              parts.allSatisfy({
                  !$0.isEmpty
                      && $0 != "."
                      && $0 != ".."
              })
        else {
            throw CodexMarketplaceManagementError.invalidRequest(
                "marketplace Git source must be a GitHub owner/repository"
            )
        }
        return (parts[0], parts[1])
    }

    private static func safeRelativePath(
        _ path: String
    ) throws -> String {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.hasPrefix("/"),
              !parts.isEmpty,
              !parts.contains(where: {
                  $0.isEmpty || $0 == "." || $0 == ".."
              })
        else {
            throw CodexMarketplaceManagementError.invalidRequest(
                "invalid sparse path: \(path)"
            )
        }
        return path
    }
}

@MainActor
public protocol CodexDesktopMarketplaceManaging: AnyObject {
    func addMarketplace(
        source: String,
        refName: String?,
        sparsePaths: [String]
    ) async throws -> CodexMarketplaceAddResult

    func removeMarketplace(
        named marketplaceName: String
    ) throws -> CodexMarketplaceRemoveResult

    func upgradeMarketplaces(
        named marketplaceName: String?
    ) async -> CodexMarketplaceUpgradeResult

    func configuredMarketplaceManifestPaths() -> [URL]
}

@MainActor
public final class CodexMarketplaceManagementService:
    CodexDesktopMarketplaceManaging
{
    private struct Record {
        let name: String
        let sourceType: String
        let source: String
        let refName: String?
        let sparsePaths: [String]
        let revision: String?
    }

    private let codexHome: URL
    private let configStore: CodexDesktopConfigStore
    private let gitInstaller: any CodexMarketplaceGitInstalling
    private let fileManager: FileManager

    public init(
        codexHome: URL,
        configStore: CodexDesktopConfigStore,
        gitInstaller:
            any CodexMarketplaceGitInstalling =
                CodexMarketplaceGitArchiveInstaller(),
        fileManager: FileManager = .default
    ) {
        self.codexHome = codexHome.standardizedFileURL
        self.configStore = configStore
        self.gitInstaller = gitInstaller
        self.fileManager = fileManager
    }

    public func addMarketplace(
        source: String,
        refName: String?,
        sparsePaths: [String]
    ) async throws -> CodexMarketplaceAddResult {
        guard !source.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty else {
            throw CodexMarketplaceManagementError.invalidRequest(
                "marketplace source is required"
            )
        }
        if let localRoot = localSourceURL(source) {
            guard refName == nil, sparsePaths.isEmpty else {
                throw CodexMarketplaceManagementError.invalidRequest(
                    "ref and sparsePaths are only supported for Git sources"
                )
            }
            let name = try marketplaceName(at: localRoot)
            if let existing = records()[name] {
                guard existing.sourceType == "local",
                      URL(fileURLWithPath: existing.source)
                        .standardizedFileURL == localRoot
                else {
                    throw nameConflict(name)
                }
                return CodexMarketplaceAddResult(
                    marketplaceName: name,
                    installedRoot: localRoot.path,
                    alreadyAdded: true
                )
            }
            try ensureNoCaseConflict(name)
            writeRecord(
                name: name,
                sourceType: "local",
                source: localRoot.path,
                refName: nil,
                sparsePaths: [],
                revision: nil
            )
            return CodexMarketplaceAddResult(
                marketplaceName: name,
                installedRoot: localRoot.path,
                alreadyAdded: false
            )
        }

        if let same = records().values.first(where: {
            $0.sourceType == "git"
                && $0.source == source
                && $0.refName == refName
                && $0.sparsePaths == sparsePaths
        }) {
            return CodexMarketplaceAddResult(
                marketplaceName: same.name,
                installedRoot: installRoot
                    .appendingPathComponent(
                        same.name,
                        isDirectory: true
                    ).path,
                alreadyAdded: true
            )
        }

        try fileManager.createDirectory(
            at: stagingRoot,
            withIntermediateDirectories: true
        )
        let staged = stagingRoot.appendingPathComponent(
            "marketplace-add-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? fileManager.removeItem(at: staged) }
        let revision = try await gitInstaller.install(
            source: source,
            refName: refName,
            sparsePaths: sparsePaths,
            destination: staged
        )
        let name = try marketplaceName(at: staged)
        try ensureNoCaseConflict(name)
        let destination = installRoot.appendingPathComponent(
            name,
            isDirectory: true
        )
        guard !fileManager.fileExists(atPath: destination.path)
        else { throw nameConflict(name) }
        try fileManager.createDirectory(
            at: installRoot,
            withIntermediateDirectories: true
        )
        try fileManager.moveItem(at: staged, to: destination)
        writeRecord(
            name: name,
            sourceType: "git",
            source: source,
            refName: refName,
            sparsePaths: sparsePaths,
            revision: revision
        )
        return CodexMarketplaceAddResult(
            marketplaceName: name,
            installedRoot: destination.path,
            alreadyAdded: false
        )
    }

    public func removeMarketplace(
        named marketplaceName: String
    ) throws -> CodexMarketplaceRemoveResult {
        try validateSegment(marketplaceName)
        let all = records()
        if let mismatch = all.keys.first(where: {
            $0 != marketplaceName
                && $0.caseInsensitiveCompare(marketplaceName)
                    == .orderedSame
        }) {
            throw CodexMarketplaceManagementError.invalidRequest(
                "marketplace `\(marketplaceName)` does not match "
                    + "configured marketplace `\(mismatch)` exactly"
            )
        }
        let record = all[marketplaceName]
        let installed = installRoot.appendingPathComponent(
            marketplaceName,
            isDirectory: true
        )
        let hasInstalled = fileManager.fileExists(atPath: installed.path)
        guard record != nil || hasInstalled else {
            throw CodexMarketplaceManagementError.invalidRequest(
                "marketplace `\(marketplaceName)` is not configured or installed"
            )
        }
        var next = marketplaceObject()
        next.removeValue(forKey: marketplaceName)
        configStore.write(
            keyPath: "marketplaces",
            value: .object(next),
            mergeStrategy: "replace"
        )
        if hasInstalled {
            try fileManager.removeItem(at: installed)
        }
        return CodexMarketplaceRemoveResult(
            marketplaceName: marketplaceName,
            installedRoot: hasInstalled ? installed.path : nil
        )
    }

    public func upgradeMarketplaces(
        named marketplaceName: String?
    ) async -> CodexMarketplaceUpgradeResult {
        let selected = records().values
            .filter {
                $0.sourceType == "git"
                    && (marketplaceName == nil
                        || $0.name == marketplaceName)
            }
            .sorted { $0.name < $1.name }
        var upgradedRoots: [String] = []
        var errors: [CodexMarketplaceUpgradeErrorInfo] = []
        for record in selected {
            let staged = stagingRoot.appendingPathComponent(
                "marketplace-upgrade-\(UUID().uuidString)",
                isDirectory: true
            )
            defer { try? fileManager.removeItem(at: staged) }
            do {
                try fileManager.createDirectory(
                    at: stagingRoot,
                    withIntermediateDirectories: true
                )
                let revision = try await gitInstaller.install(
                    source: record.source,
                    refName: record.refName,
                    sparsePaths: record.sparsePaths,
                    destination: staged
                )
                let name = try self.marketplaceName(at: staged)
                guard name == record.name else {
                    throw CodexMarketplaceManagementError
                        .invalidRequest(
                            "upgraded marketplace name `\(name)` "
                                + "does not match configured marketplace "
                                + "`\(record.name)`"
                        )
                }
                if revision == record.revision {
                    continue
                }
                let destination = installRoot.appendingPathComponent(
                    record.name,
                    isDirectory: true
                )
                let backup = stagingRoot.appendingPathComponent(
                    "marketplace-backup-\(UUID().uuidString)",
                    isDirectory: true
                )
                if fileManager.fileExists(atPath: destination.path) {
                    try fileManager.moveItem(
                        at: destination,
                        to: backup
                    )
                }
                do {
                    try fileManager.moveItem(
                        at: staged,
                        to: destination
                    )
                    writeRecord(
                        name: record.name,
                        sourceType: "git",
                        source: record.source,
                        refName: record.refName,
                        sparsePaths: record.sparsePaths,
                        revision: revision
                    )
                    try? fileManager.removeItem(at: backup)
                    upgradedRoots.append(destination.path)
                } catch {
                    try? fileManager.removeItem(at: destination)
                    if fileManager.fileExists(atPath: backup.path) {
                        try? fileManager.moveItem(
                            at: backup,
                            to: destination
                        )
                    }
                    throw error
                }
            } catch {
                errors.append(
                    CodexMarketplaceUpgradeErrorInfo(
                        marketplaceName: record.name,
                        message: String(describing: error)
                    )
                )
            }
        }
        return CodexMarketplaceUpgradeResult(
            selectedMarketplaces: selected.map(\.name),
            upgradedRoots: upgradedRoots,
            errors: errors
        )
    }

    public func configuredMarketplaceManifestPaths() -> [URL] {
        records().values.compactMap { record in
            let root = record.sourceType == "local"
                ? URL(fileURLWithPath: record.source)
                : installRoot.appendingPathComponent(
                    record.name,
                    isDirectory: true
                )
            return manifestURL(for: root)
        }.sorted { $0.path < $1.path }
    }

    private var installRoot: URL {
        codexHome.appendingPathComponent(
            "plugins/marketplaces",
            isDirectory: true
        )
    }

    private var stagingRoot: URL {
        installRoot.appendingPathComponent(
            ".staging",
            isDirectory: true
        )
    }

    private func localSourceURL(_ source: String) -> URL? {
        if source.hasPrefix("file://"),
           let url = URL(string: source),
           url.isFileURL
        {
            return url.standardizedFileURL
        }
        if source.hasPrefix("/") {
            return URL(fileURLWithPath: source)
                .standardizedFileURL
        }
        return nil
    }

    private func manifestURL(for root: URL) -> URL {
        root.appendingPathComponent(
            ".agents/plugins/marketplace.json"
        )
    }

    private func marketplaceName(at root: URL) throws -> String {
        let manifest = manifestURL(for: root)
        guard fileManager.fileExists(atPath: manifest.path),
              let object = try JSONSerialization.jsonObject(
                  with: Data(contentsOf: manifest)
              ) as? [String: Any],
              let name = object["name"] as? String
        else {
            throw CodexMarketplaceManagementError.invalidRequest(
                "marketplace source must contain "
                    + ".agents/plugins/marketplace.json"
            )
        }
        try validateSegment(name)
        return name
    }

    private func validateSegment(_ value: String) throws {
        guard !value.isEmpty,
              value != ".",
              value != "..",
              !value.contains("/"),
              !value.contains("\\"),
              !value.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0)
              })
        else {
            throw CodexMarketplaceManagementError.invalidRequest(
                "invalid marketplace name: \(value)"
            )
        }
    }

    private func ensureNoCaseConflict(_ name: String) throws {
        if records().keys.contains(name) {
            throw nameConflict(name)
        }
        if let mismatch = records().keys.first(where: {
            $0.caseInsensitiveCompare(name) == .orderedSame
        }) {
            throw CodexMarketplaceManagementError.invalidRequest(
                "marketplace `\(name)` conflicts with configured "
                    + "marketplace `\(mismatch)`"
            )
        }
    }

    private func nameConflict(
        _ name: String
    ) -> CodexMarketplaceManagementError {
        .invalidRequest(
            "marketplace '\(name)' is already added from a "
                + "different source; remove it before adding this source"
        )
    }

    private func marketplaceObject()
        -> [String: CodexJSONValue]
    {
        guard case let .object(value)? =
            configStore.snapshot["marketplaces"]
        else { return [:] }
        return value
    }

    private func records() -> [String: Record] {
        marketplaceObject().reduce(into: [:]) { result, entry in
            guard case let .object(fields) = entry.value,
                  case let .string(sourceType)? =
                    fields["source_type"],
                  case let .string(source)? = fields["source"]
            else { return }
            let refName: String?
            if case let .string(value)? = fields["ref"] {
                refName = value
            } else {
                refName = nil
            }
            let sparsePaths: [String]
            if case let .array(values)? = fields["sparse_paths"] {
                sparsePaths = values.compactMap {
                    guard case let .string(value) = $0
                    else { return nil }
                    return value
                }
            } else {
                sparsePaths = []
            }
            let revision: String?
            if case let .string(value)? = fields["last_revision"] {
                revision = value
            } else {
                revision = nil
            }
            result[entry.key] = Record(
                name: entry.key,
                sourceType: sourceType,
                source: source,
                refName: refName,
                sparsePaths: sparsePaths,
                revision: revision
            )
        }
    }

    private func writeRecord(
        name: String,
        sourceType: String,
        source: String,
        refName: String?,
        sparsePaths: [String],
        revision: String?
    ) {
        var fields: [String: CodexJSONValue] = [
            "last_updated": .string(
                ISO8601DateFormatter().string(from: Date())
            ),
            "source_type": .string(sourceType),
            "source": .string(source),
        ]
        if let refName { fields["ref"] = .string(refName) }
        if !sparsePaths.isEmpty {
            fields["sparse_paths"] = .array(
                sparsePaths.map(CodexJSONValue.string)
            )
        }
        if let revision {
            fields["last_revision"] = .string(revision)
        }
        var next = marketplaceObject()
        next[name] = .object(fields)
        configStore.write(
            keyPath: "marketplaces",
            value: .object(next),
            mergeStrategy: "replace"
        )
    }
}
