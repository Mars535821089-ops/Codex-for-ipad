import Foundation

public struct CodexPluginMarketplaceLoadError: Equatable, Sendable {
    public let path: String
    public let message: String
}

public struct CodexPluginSummary: Equatable, Sendable {
    public let id: String
    public let name: String
    public let version: String?
    public let localVersion: String?
    public let sourcePath: String
    public let installed: Bool
    public let enabled: Bool
    public let installPolicy: String
    public let authPolicy: String
    public let availability: String
    public let keywords: [String]
}

public struct CodexPluginMarketplaceEntry: Equatable, Sendable {
    public let name: String
    public let path: String
    public let displayName: String?
    public let plugins: [CodexPluginSummary]
}

public struct CodexPluginListResponse: Equatable, Sendable {
    public let marketplaces: [CodexPluginMarketplaceEntry]
    public let marketplaceLoadErrors:
        [CodexPluginMarketplaceLoadError]
    public let featuredPluginIDs: [String]
}

public struct CodexPluginDetail: Equatable, Sendable {
    public let marketplaceName: String
    public let marketplacePath: String
    public let summary: CodexPluginSummary
    public let description: String?
    public let skillNames: [String]
    public let hookKeys: [String]
    public let appIDs: [String]
    public let mcpServerNames: [String]
}

public struct CodexPluginInstallResult: Equatable, Sendable {
    public let authPolicy: String
    public let appsNeedingAuth: [String]
}

public struct CodexInstalledPluginComponents: Equatable, Sendable {
    public let pluginID: String
    public let namespace: String
    public let version: String
    public let rootPath: String
    public let skillRootPaths: [String]
    public let hookSourcePaths: [String]
}

struct CodexInstalledPluginHookSource: Equatable, Sendable {
    let path: URL
    let sourceRelativePath: String
    let inlineData: Data?
}

struct CodexInstalledPluginRecord: Equatable, Sendable {
    let pluginID: String
    let namespace: String
    let version: String
    let root: URL
    let skillRoots: [URL]
    let hookSources: [CodexInstalledPluginHookSource]
}

enum CodexInstalledPluginInventory {
    private struct SemanticVersion: Comparable {
        let major: UInt64
        let minor: UInt64
        let patch: UInt64
        let prerelease: [String]
        let build: [String]

        init?(_ rawValue: String) {
            let buildParts = rawValue.split(
                separator: "+",
                maxSplits: 1,
                omittingEmptySubsequences: false
            )
            guard buildParts.count <= 2 else {
                return nil
            }
            let coreAndPrerelease = buildParts[0]
            let prereleaseParts = coreAndPrerelease.split(
                separator: "-",
                maxSplits: 1,
                omittingEmptySubsequences: false
            )
            let core = prereleaseParts[0].split(
                separator: ".",
                omittingEmptySubsequences: false
            )
            guard core.count == 3,
                  let major = Self.coreNumber(core[0]),
                  let minor = Self.coreNumber(core[1]),
                  let patch = Self.coreNumber(core[2])
            else {
                return nil
            }
            let prerelease: [String]
            if prereleaseParts.count == 2 {
                guard let parsed = Self.identifiers(
                    prereleaseParts[1],
                    allowsLeadingZeroNumeric: false
                ) else {
                    return nil
                }
                prerelease = parsed
            } else {
                prerelease = []
            }
            let build: [String]
            if buildParts.count == 2 {
                guard let parsed = Self.identifiers(
                    buildParts[1],
                    allowsLeadingZeroNumeric: true
                ) else {
                    return nil
                }
                build = parsed
            } else {
                build = []
            }
            self.major = major
            self.minor = minor
            self.patch = patch
            self.prerelease = prerelease
            self.build = build
        }

        static func < (
            lhs: SemanticVersion,
            rhs: SemanticVersion
        ) -> Bool {
            if lhs.major != rhs.major {
                return lhs.major < rhs.major
            }
            if lhs.minor != rhs.minor {
                return lhs.minor < rhs.minor
            }
            if lhs.patch != rhs.patch {
                return lhs.patch < rhs.patch
            }
            let prereleaseComparison = comparePrerelease(
                lhs.prerelease,
                rhs.prerelease
            )
            if prereleaseComparison != 0 {
                return prereleaseComparison < 0
            }
            return compareBuild(lhs.build, rhs.build) < 0
        }

        private static func coreNumber(
            _ value: Substring
        ) -> UInt64? {
            guard !value.isEmpty,
                  value.allSatisfy(\.isNumber),
                  value == "0" || value.first != "0"
            else {
                return nil
            }
            return UInt64(value)
        }

        private static func identifiers(
            _ value: Substring,
            allowsLeadingZeroNumeric: Bool
        ) -> [String]? {
            let identifiers = value.split(
                separator: ".",
                omittingEmptySubsequences: false
            )
            guard !identifiers.isEmpty,
                  identifiers.allSatisfy({
                      !$0.isEmpty
                          && $0.allSatisfy {
                              $0.isASCII
                                  && ($0.isLetter || $0.isNumber
                                      || $0 == "-")
                          }
                          && (allowsLeadingZeroNumeric
                              || !$0.allSatisfy(\.isNumber)
                              || $0 == "0"
                              || $0.first != "0")
                  })
            else {
                return nil
            }
            return identifiers.map(String.init)
        }

        private static func comparePrerelease(
            _ lhs: [String],
            _ rhs: [String]
        ) -> Int {
            if lhs.isEmpty {
                return rhs.isEmpty ? 0 : 1
            }
            if rhs.isEmpty {
                return -1
            }
            return compareIdentifiers(
                lhs,
                rhs,
                normalizeBuildNumbers: false
            )
        }

        private static func compareBuild(
            _ lhs: [String],
            _ rhs: [String]
        ) -> Int {
            compareIdentifiers(
                lhs,
                rhs,
                normalizeBuildNumbers: true
            )
        }

        private static func compareIdentifiers(
            _ lhs: [String],
            _ rhs: [String],
            normalizeBuildNumbers: Bool
        ) -> Int {
            for index in 0..<min(lhs.count, rhs.count) {
                let left = lhs[index]
                let right = rhs[index]
                let leftIsNumeric = left.allSatisfy(\.isNumber)
                let rightIsNumeric = right.allSatisfy(\.isNumber)
                let comparison: Int
                switch (leftIsNumeric, rightIsNumeric) {
                case (true, true):
                    comparison = compareNumericIdentifiers(
                        left,
                        right,
                        normalizeLeadingZeros:
                            normalizeBuildNumbers
                    )
                case (true, false):
                    return -1
                case (false, true):
                    return 1
                case (false, false):
                    comparison = lexicalComparison(left, right)
                }
                if comparison != 0 {
                    return comparison
                }
            }
            if lhs.count == rhs.count {
                return 0
            }
            return lhs.count < rhs.count ? -1 : 1
        }

        private static func compareNumericIdentifiers(
            _ lhs: String,
            _ rhs: String,
            normalizeLeadingZeros: Bool
        ) -> Int {
            let leftValue = normalizeLeadingZeros
                ? String(lhs.drop(while: { $0 == "0" }))
                : lhs
            let rightValue = normalizeLeadingZeros
                ? String(rhs.drop(while: { $0 == "0" }))
                : rhs
            if leftValue.count != rightValue.count {
                return leftValue.count < rightValue.count ? -1 : 1
            }
            let valueComparison = lexicalComparison(
                leftValue,
                rightValue
            )
            if valueComparison != 0 || !normalizeLeadingZeros {
                return valueComparison
            }
            if lhs.count == rhs.count {
                return 0
            }
            return lhs.count < rhs.count ? -1 : 1
        }

        private static func lexicalComparison(
            _ lhs: String,
            _ rhs: String
        ) -> Int {
            if lhs == rhs {
                return 0
            }
            return lhs < rhs ? -1 : 1
        }
    }

    static func discover(
        cacheRoot: URL,
        fileManager: FileManager
    ) -> [CodexInstalledPluginRecord] {
        let cacheRoot = cacheRoot.standardizedFileURL
        var records: [CodexInstalledPluginRecord] = []
        for marketplace in directoryEntries(
            at: cacheRoot,
            fileManager: fileManager
        ) where validPluginSegment(marketplace.lastPathComponent) {
            for plugin in directoryEntries(
                at: marketplace,
                fileManager: fileManager
            ) where validPluginSegment(plugin.lastPathComponent) {
                guard let versionRoot = activeVersionRoot(
                    at: plugin,
                    fileManager: fileManager
                ),
                    let record = record(
                        pluginRoot: versionRoot,
                        marketplaceName:
                            marketplace.lastPathComponent,
                        expectedPluginName:
                            plugin.lastPathComponent,
                        version: versionRoot.lastPathComponent,
                        fileManager: fileManager
                    )
                else {
                    continue
                }
                records.append(record)
            }
        }
        return records.sorted {
            ($0.pluginID, $0.root.path)
                < ($1.pluginID, $1.root.path)
        }
    }

    private static func record(
        pluginRoot: URL,
        marketplaceName: String,
        expectedPluginName: String,
        version: String,
        fileManager: FileManager
    ) -> CodexInstalledPluginRecord? {
        let root = pluginRoot.standardizedFileURL
        let manifestPath = root
            .appendingPathComponent(
                ".codex-plugin",
                isDirectory: true
            )
            .appendingPathComponent("plugin.json")
        guard let data = try? Data(contentsOf: manifestPath),
              let raw = try? JSONSerialization.jsonObject(
                  with: data
              ),
              let manifest = raw as? [String: Any],
              let name = manifest["name"] as? String,
              name == expectedPluginName,
              validPluginSegment(name)
        else {
            return nil
        }

        return CodexInstalledPluginRecord(
            pluginID: "\(name)@\(marketplaceName)",
            namespace: name,
            version: version,
            root: root,
            skillRoots: skillRoots(
                manifest: manifest,
                pluginRoot: root,
                fileManager: fileManager
            ),
            hookSources: hookSources(
                manifest: manifest,
                manifestPath: manifestPath,
                pluginRoot: root,
                fileManager: fileManager
            )
        )
    }

    private static func skillRoots(
        manifest: [String: Any],
        pluginRoot: URL,
        fileManager: FileManager
    ) -> [URL] {
        let declared = resolvedPathReferences(
            manifest["skills"],
            pluginRoot: pluginRoot
        )
        let candidates: [URL]
        if declared.isEmpty {
            candidates = [
                pluginRoot.appendingPathComponent(
                    "skills",
                    isDirectory: true
                ),
            ]
        } else {
            candidates = declared
        }
        return uniqueURLs(
            candidates.filter {
                isDirectory($0, fileManager: fileManager)
            }
        )
    }

    private static func hookSources(
        manifest: [String: Any],
        manifestPath: URL,
        pluginRoot: URL,
        fileManager: FileManager
    ) -> [CodexInstalledPluginHookSource] {
        guard let rawHooks = manifest["hooks"] else {
            return defaultHookSources(
                pluginRoot: pluginRoot,
                fileManager: fileManager
            )
        }

        if rawHooks is String
            || (rawHooks as? [Any])?.allSatisfy({
                $0 is String
            }) == true
        {
            let declared = resolvedPathReferences(
                rawHooks,
                pluginRoot: pluginRoot
            )
            guard !declared.isEmpty else {
                return defaultHookSources(
                    pluginRoot: pluginRoot,
                    fileManager: fileManager
                )
            }
            return uniqueURLs(declared).compactMap { path in
                guard isRegularFile(
                    path,
                    fileManager: fileManager
                ) else {
                    return nil
                }
                return CodexInstalledPluginHookSource(
                    path: path,
                    sourceRelativePath: relativePath(
                        path,
                        under: pluginRoot
                    ),
                    inlineData: nil
                )
            }
        }

        let inlineObjects: [[String: Any]]
        if let object = rawHooks as? [String: Any] {
            inlineObjects = [object]
        } else if let values = rawHooks as? [Any],
                  values.allSatisfy({ $0 is [String: Any] })
        {
            inlineObjects = values.compactMap {
                $0 as? [String: Any]
            }
        } else {
            return defaultHookSources(
                pluginRoot: pluginRoot,
                fileManager: fileManager
            )
        }
        guard !inlineObjects.isEmpty else {
            return defaultHookSources(
                pluginRoot: pluginRoot,
                fileManager: fileManager
            )
        }
        let sources = inlineObjects.enumerated().compactMap {
            index,
            object -> CodexInstalledPluginHookSource? in
            guard object["hooks"] is [String: Any],
                  let data = try? JSONSerialization.data(
                      withJSONObject: object,
                      options: [.sortedKeys]
                  )
            else {
                return nil
            }
            return CodexInstalledPluginHookSource(
                path: manifestPath.standardizedFileURL,
                sourceRelativePath:
                    "plugin.json#hooks[\(index)]",
                inlineData: data
            )
        }
        return sources.isEmpty
            ? defaultHookSources(
                pluginRoot: pluginRoot,
                fileManager: fileManager
            )
            : sources
    }

    private static func defaultHookSources(
        pluginRoot: URL,
        fileManager: FileManager
    ) -> [CodexInstalledPluginHookSource] {
        let path = pluginRoot.appendingPathComponent(
            "hooks/hooks.json"
        ).standardizedFileURL
        guard isRegularFile(path, fileManager: fileManager)
        else {
            return []
        }
        return [
            CodexInstalledPluginHookSource(
                path: path,
                sourceRelativePath: "hooks/hooks.json",
                inlineData: nil
            ),
        ]
    }

    private static func resolvedPathReferences(
        _ rawValue: Any?,
        pluginRoot: URL
    ) -> [URL] {
        let references: [String]
        if let value = rawValue as? String {
            references = [value]
        } else if let values = rawValue as? [String] {
            references = values
        } else {
            return []
        }
        return references.compactMap {
            resolvedPluginPath(
                $0,
                pluginRoot: pluginRoot
            )
        }
    }

    private static func resolvedPluginPath(
        _ reference: String,
        pluginRoot: URL
    ) -> URL? {
        guard reference.hasPrefix("./") else {
            return nil
        }
        let relative = String(reference.dropFirst(2))
        guard !relative.isEmpty,
              !relative.split(
                  separator: "/",
                  omittingEmptySubsequences: false
              ).contains("..")
        else {
            return nil
        }
        let root = pluginRoot.standardizedFileURL
        let candidate = root.appendingPathComponent(relative)
            .standardizedFileURL
        guard candidate.path.hasPrefix(root.path + "/")
        else {
            return nil
        }
        let resolvedRoot = root.resolvingSymlinksInPath()
        let resolvedCandidate = candidate.resolvingSymlinksInPath()
        guard resolvedCandidate.path.hasPrefix(
            resolvedRoot.path + "/"
        ) else {
            return nil
        }
        return candidate
    }

    private static func relativePath(
        _ path: URL,
        under root: URL
    ) -> String {
        String(
            path.standardizedFileURL.path.dropFirst(
                root.standardizedFileURL.path.count + 1
            )
        )
    }

    static func activeVersionRoot(
        at pluginRoot: URL,
        fileManager: FileManager
    ) -> URL? {
        let versions = directoryEntries(
            at: pluginRoot,
            fileManager: fileManager
        ).filter {
            validVersionSegment($0.lastPathComponent)
        }
        if let local = versions.first(
            where: { $0.lastPathComponent == "local" }
        ) {
            return local
        }
        return versions.sorted {
            compareVersions(
                $0.lastPathComponent,
                $1.lastPathComponent
            ) < 0
        }.last
    }

    private static func compareVersions(
        _ lhs: String,
        _ rhs: String
    ) -> Int {
        if let left = SemanticVersion(lhs),
           let right = SemanticVersion(rhs)
        {
            if left == right {
                return 0
            }
            return left < right ? -1 : 1
        }
        if lhs == rhs {
            return 0
        }
        return lhs < rhs ? -1 : 1
    }

    private static func directoryEntries(
        at root: URL,
        fileManager: FileManager
    ) -> [URL] {
        guard let entries = try? fileManager
            .contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
        else {
            return []
        }
        return entries.filter {
            isDirectory($0, fileManager: fileManager)
        }.sorted { $0.path < $1.path }
    }

    private static func isDirectory(
        _ path: URL,
        fileManager: FileManager
    ) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(
            atPath: path.path,
            isDirectory: &isDirectory
        ) && isDirectory.boolValue
    }

    private static func isRegularFile(
        _ path: URL,
        fileManager: FileManager
    ) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(
            atPath: path.path,
            isDirectory: &isDirectory
        ) && !isDirectory.boolValue
    }

    private static func uniqueURLs(_ values: [URL]) -> [URL] {
        var visited: Set<String> = []
        return values.filter {
            visited.insert($0.standardizedFileURL.path).inserted
        }
    }

    private static func validPluginSegment(_ value: String) -> Bool {
        !value.isEmpty
            && value.allSatisfy {
                $0.isASCII
                    && ($0.isLetter || $0.isNumber
                        || $0 == "_" || $0 == "-")
            }
    }

    private static func validVersionSegment(_ value: String) -> Bool {
        !value.isEmpty
            && value.allSatisfy {
                $0.isASCII
                    && ($0.isLetter || $0.isNumber
                        || $0 == "_" || $0 == "-"
                        || $0 == "." || $0 == "+")
            }
            && value != "."
            && value != ".."
    }
}

public enum CodexPluginCatalogError:
    Error, Equatable, Sendable
{
    case invalidPluginID
    case marketplaceNotFound(String)
    case pluginNotFound(String)
    case invalidManifest(String)
    case unsupportedSource(String)
}

@MainActor
public final class CodexPluginCatalogService {
    private let marketplacePaths: [URL]
    private let additionalMarketplacePaths: () -> [URL]
    private let cacheRoot: URL
    private let fileManager: FileManager

    public init(
        marketplacePaths: [URL],
        additionalMarketplacePaths:
            @escaping () -> [URL] = { [] },
        cacheRoot: URL,
        fileManager: FileManager = .default
    ) {
        self.marketplacePaths = marketplacePaths.map(
            \.standardizedFileURL
        )
        self.additionalMarketplacePaths =
            additionalMarketplacePaths
        self.cacheRoot = cacheRoot.standardizedFileURL
        self.fileManager = fileManager
    }

    public func list() -> CodexPluginListResponse {
        var marketplaces: [CodexPluginMarketplaceEntry] = []
        var errors: [CodexPluginMarketplaceLoadError] = []
        for path in currentMarketplacePaths {
            guard fileManager.fileExists(atPath: path.path)
            else { continue }
            do {
                marketplaces.append(try loadMarketplace(at: path))
            } catch {
                errors.append(
                    CodexPluginMarketplaceLoadError(
                        path: path.path,
                        message: String(describing: error)
                    )
                )
            }
        }
        return CodexPluginListResponse(
            marketplaces: marketplaces.sorted {
                $0.name.localizedStandardCompare($1.name)
                    == .orderedAscending
            },
            marketplaceLoadErrors: errors,
            featuredPluginIDs: []
        )
    }

    public func read(
        marketplacePath: String,
        pluginName: String
    ) throws -> CodexPluginDetail {
        let path = URL(fileURLWithPath: marketplacePath)
            .standardizedFileURL
        guard currentMarketplacePaths.contains(path) else {
            throw CodexPluginCatalogError.marketplaceNotFound(
                marketplacePath
            )
        }
        let catalog = try decodedMarketplace(at: path)
        guard let plugin = catalog.plugins.first(
            where: { $0.name == pluginName }
        ) else {
            throw CodexPluginCatalogError.pluginNotFound(pluginName)
        }
        return try makeDetail(
            plugin,
            marketplace: catalog,
            marketplacePath: path
        )
    }

    private var currentMarketplacePaths: [URL] {
        var seen: Set<String> = []
        return (marketplacePaths + additionalMarketplacePaths())
            .map(\.standardizedFileURL)
            .filter { seen.insert($0.path).inserted }
    }

    public func installedComponents()
        -> [CodexInstalledPluginComponents]
    {
        CodexInstalledPluginInventory.discover(
            cacheRoot: cacheRoot,
            fileManager: fileManager
        ).map { record in
            var hookPaths: [String] = []
            var visited: Set<String> = []
            for source in record.hookSources {
                let path = source.path.standardizedFileURL.path
                if visited.insert(path).inserted {
                    hookPaths.append(path)
                }
            }
            return CodexInstalledPluginComponents(
                pluginID: record.pluginID,
                namespace: record.namespace,
                version: record.version,
                rootPath: record.root.path,
                skillRootPaths:
                    record.skillRoots.map(\.path),
                hookSourcePaths: hookPaths
            )
        }
    }

    public func install(
        marketplacePath: String,
        pluginName: String
    ) throws -> CodexPluginInstallResult {
        let detail = try read(
            marketplacePath: marketplacePath,
            pluginName: pluginName
        )
        let version = detail.summary.version ?? "local"
        let destination = cacheRoot
            .appendingPathComponent(
                detail.marketplaceName,
                isDirectory: true
            )
            .appendingPathComponent(pluginName, isDirectory: true)
            .appendingPathComponent(version, isDirectory: true)
        let source = URL(
            fileURLWithPath: detail.summary.sourcePath,
            isDirectory: true
        )
        let staging = destination
            .deletingLastPathComponent()
            .appendingPathComponent(
                ".\(version).staging-\(UUID().uuidString)",
                isDirectory: true
            )
        try fileManager.createDirectory(
            at: staging.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        do {
            try fileManager.copyItem(at: source, to: staging)
            _ = try pluginManifest(at: staging)
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
            try fileManager.moveItem(at: staging, to: destination)
        } catch {
            try? fileManager.removeItem(at: staging)
            throw error
        }
        return CodexPluginInstallResult(
            authPolicy: detail.summary.authPolicy,
            appsNeedingAuth:
                detail.summary.authPolicy == "ON_INSTALL"
                ? detail.appIDs : []
        )
    }

    public func uninstall(pluginID: String) throws {
        guard let separator = pluginID.lastIndex(of: "@") else {
            throw CodexPluginCatalogError.invalidPluginID
        }
        let pluginName = String(pluginID[..<separator])
        let marketplaceName = String(
            pluginID[pluginID.index(after: separator)...]
        )
        guard validSegment(pluginName),
              validSegment(marketplaceName)
        else {
            throw CodexPluginCatalogError.invalidPluginID
        }
        let destination = cacheRoot
            .appendingPathComponent(
                marketplaceName,
                isDirectory: true
            )
            .appendingPathComponent(pluginName, isDirectory: true)
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
    }

    private func loadMarketplace(
        at path: URL
    ) throws -> CodexPluginMarketplaceEntry {
        let catalog = try decodedMarketplace(at: path)
        let plugins = try catalog.plugins.map {
            try makeSummary(
                $0,
                marketplaceName: catalog.name,
                marketplacePath: path
            )
        }
        return CodexPluginMarketplaceEntry(
            name: catalog.name,
            path: path.path,
            displayName: catalog.interface?.displayName,
            plugins: plugins.sorted {
                $0.name.localizedStandardCompare($1.name)
                    == .orderedAscending
            }
        )
    }

    private func makeDetail(
        _ plugin: MarketplacePlugin,
        marketplace: Marketplace,
        marketplacePath: URL
    ) throws -> CodexPluginDetail {
        let summary = try makeSummary(
            plugin,
            marketplaceName: marketplace.name,
            marketplacePath: marketplacePath
        )
        let root = URL(
            fileURLWithPath: summary.sourcePath,
            isDirectory: true
        )
        let manifest = try pluginManifest(at: root)
        let manifestObject = rawPluginManifest(at: root)
        return CodexPluginDetail(
            marketplaceName: marketplace.name,
            marketplacePath: marketplacePath.path,
            summary: summary,
            description: manifest.description,
            skillNames: pluginSkillNames(
                at: root,
                manifest: manifestObject
            ),
            hookKeys: pluginHookKeys(
                at: root,
                pluginID: summary.id,
                manifest: manifestObject
            ),
            appIDs: appIDs(at: root),
            mcpServerNames: objectKeys(
                at: root.appendingPathComponent(".mcp.json"),
                container: "mcpServers"
            )
        )
    }

    private func makeSummary(
        _ plugin: MarketplacePlugin,
        marketplaceName: String,
        marketplacePath: URL
    ) throws -> CodexPluginSummary {
        guard plugin.source.source == "local",
              let relativePath = plugin.source.path
        else {
            throw CodexPluginCatalogError.unsupportedSource(
                plugin.name
            )
        }
        let source = URL(
            fileURLWithPath: relativePath,
            relativeTo: sourceBaseDirectory(
                for: marketplacePath
            )
        ).standardizedFileURL
        let manifest = try pluginManifest(at: source)
        guard manifest.name == plugin.name,
              validSegment(plugin.name),
              validSegment(marketplaceName)
        else {
            throw CodexPluginCatalogError.invalidManifest(
                plugin.name
            )
        }
        let version = manifest.version
        let installedVersion = installedVersion(
            marketplace: marketplaceName,
            plugin: plugin.name
        )
        return CodexPluginSummary(
            id: "\(plugin.name)@\(marketplaceName)",
            name: plugin.name,
            version: version,
            localVersion: installedVersion,
            sourcePath: source.path,
            installed: installedVersion != nil,
            enabled: installedVersion != nil,
            installPolicy:
                plugin.policy?.installation ?? "AVAILABLE",
            authPolicy:
                plugin.policy?.authentication ?? "ON_USE",
            availability: "AVAILABLE",
            keywords: manifest.keywords ?? []
        )
    }

    private func sourceBaseDirectory(
        for marketplacePath: URL
    ) -> URL {
        let marketplaceDirectory =
            marketplacePath.deletingLastPathComponent()
        let agentsDirectory =
            marketplaceDirectory.deletingLastPathComponent()
        if marketplacePath.lastPathComponent == "marketplace.json",
           marketplaceDirectory.lastPathComponent == "plugins",
           agentsDirectory.lastPathComponent == ".agents"
        {
            return agentsDirectory.deletingLastPathComponent()
        }
        return marketplaceDirectory
    }

    private func installedVersion(
        marketplace: String,
        plugin: String
    ) -> String? {
        let root = cacheRoot
            .appendingPathComponent(marketplace, isDirectory: true)
            .appendingPathComponent(plugin, isDirectory: true)
        return CodexInstalledPluginInventory.activeVersionRoot(
            at: root,
            fileManager: fileManager
        )?.lastPathComponent
    }

    private func decodedMarketplace(at path: URL) throws -> Marketplace {
        let data = try Data(contentsOf: path)
        return try JSONDecoder().decode(Marketplace.self, from: data)
    }

    private func pluginManifest(at root: URL) throws -> PluginManifest {
        let path = root
            .appendingPathComponent(
                ".codex-plugin",
                isDirectory: true
            )
            .appendingPathComponent("plugin.json")
        do {
            return try JSONDecoder().decode(
                PluginManifest.self,
                from: Data(contentsOf: path)
            )
        } catch {
            throw CodexPluginCatalogError.invalidManifest(path.path)
        }
    }

    private func rawPluginManifest(
        at root: URL
    ) -> [String: Any] {
        let path = root
            .appendingPathComponent(
                ".codex-plugin",
                isDirectory: true
            )
            .appendingPathComponent("plugin.json")
        guard let data = try? Data(contentsOf: path),
              let object = try? JSONSerialization
                .jsonObject(with: data) as? [String: Any]
        else {
            return [:]
        }
        return object
    }

    private func pluginSkillNames(
        at root: URL,
        manifest: [String: Any]
    ) -> [String] {
        let skillRoots: [URL]
        let declared = pluginPathReferences(
            manifest["skills"],
            root: root
        )
        if declared.isEmpty {
            skillRoots = [
                root.appendingPathComponent(
                    "skills",
                    isDirectory: true
                ),
            ]
        } else {
            skillRoots = declared
        }
        var names = Set<String>()
        for skillRoot in skillRoots {
            let rootMarker =
                skillRoot.appendingPathComponent("SKILL.md")
            if fileManager.fileExists(
                atPath: rootMarker.path
            ) {
                names.insert(skillRoot.lastPathComponent)
            }
            guard let enumerator = fileManager.enumerator(
                at: skillRoot,
                includingPropertiesForKeys: [
                    .isRegularFileKey,
                ],
                options: [
                    .skipsHiddenFiles,
                    .skipsPackageDescendants,
                ]
            ) else {
                continue
            }
            for case let file as URL in enumerator
            where file.lastPathComponent == "SKILL.md" {
                names.insert(
                    file.deletingLastPathComponent()
                        .lastPathComponent
                )
            }
        }
        return names.sorted()
    }

    private func pluginHookKeys(
        at root: URL,
        pluginID: String,
        manifest: [String: Any]
    ) -> [String] {
        let sources = pluginHookSources(
            at: root,
            manifest: manifest
        )
        let events: [
            (wire: String, key: String, asyncAllowed: Bool)
        ] = [
            ("PreToolUse", "pre_tool_use", false),
            ("PermissionRequest", "permission_request", false),
            ("PostToolUse", "post_tool_use", false),
            ("PreCompact", "pre_compact", false),
            ("PostCompact", "post_compact", false),
            ("SessionStart", "session_start", false),
            ("SessionEnd", "session_end", true),
            ("UserPromptSubmit", "user_prompt_submit", false),
            ("SubagentStart", "subagent_start", false),
            ("SubagentStop", "subagent_stop", false),
            ("Stop", "stop", false),
        ]
        var keys: [String] = []
        for source in sources {
            guard let object = try? JSONSerialization
                .jsonObject(with: source.data) as? [String: Any],
                Set(object.keys).isSubset(
                    of: ["description", "hooks"]
                ),
                let hooks = object["hooks"] as? [String: Any]
            else {
                continue
            }
            for event in events {
                guard let groups =
                    hooks[event.wire] as? [Any]
                else {
                    continue
                }
                for (
                    groupIndex,
                    rawGroup
                ) in groups.enumerated() {
                    guard let group =
                        rawGroup as? [String: Any],
                        let handlers =
                            group["hooks"] as? [Any]
                    else {
                        continue
                    }
                    for (
                        handlerIndex,
                        rawHandler
                    ) in handlers.enumerated() {
                        guard let handler =
                            rawHandler as? [String: Any],
                            handler["type"] as? String
                                == "command",
                            let command =
                                handler["command"] as? String,
                            !command.trimmingCharacters(
                                in: .whitespacesAndNewlines
                            ).isEmpty,
                            event.asyncAllowed
                                || handler["async"] as? Bool
                                    != true
                        else {
                            continue
                        }
                        keys.append(
                            "\(pluginID):\(source.relativePath):\(event.key):\(groupIndex):\(handlerIndex)"
                        )
                    }
                }
            }
        }
        return keys
    }

    private func pluginHookSources(
        at root: URL,
        manifest: [String: Any]
    ) -> [(relativePath: String, data: Data)] {
        guard let rawHooks = manifest["hooks"] else {
            return pluginHookFileSources(
                [
                    root.appendingPathComponent(
                        "hooks/hooks.json"
                    ),
                ],
                root: root
            )
        }
        if rawHooks is String
            || (rawHooks as? [Any])?.allSatisfy({
                $0 is String
            }) == true
        {
            let declared = pluginPathReferences(
                rawHooks,
                root: root
            )
            let resolved = pluginHookFileSources(
                declared,
                root: root
            )
            return resolved.isEmpty
                ? pluginHookFileSources(
                    [
                        root.appendingPathComponent(
                            "hooks/hooks.json"
                        ),
                    ],
                    root: root
                )
                : resolved
        }
        let inlineObjects: [[String: Any]]
        if let object = rawHooks as? [String: Any] {
            inlineObjects = [object]
        } else if let values = rawHooks as? [Any] {
            inlineObjects = values.compactMap {
                $0 as? [String: Any]
            }
        } else {
            inlineObjects = []
        }
        let inline = inlineObjects.enumerated().compactMap {
            index,
            object
                -> (relativePath: String, data: Data)? in
            guard object["hooks"] is [String: Any],
                  let data = try? JSONSerialization.data(
                      withJSONObject: object,
                      options: [.sortedKeys]
                  )
            else {
                return nil
            }
            return (
                relativePath: "plugin.json#hooks[\(index)]",
                data: data
            )
        }
        return inline.isEmpty
            ? pluginHookFileSources(
                [
                    root.appendingPathComponent(
                        "hooks/hooks.json"
                    ),
                ],
                root: root
            )
            : inline
    }

    private func pluginHookFileSources(
        _ paths: [URL],
        root: URL
    ) -> [(relativePath: String, data: Data)] {
        paths.compactMap { path in
            guard let data = try? Data(contentsOf: path)
            else {
                return nil
            }
            return (
                relativePath: pluginRelativePath(
                    path,
                    root: root
                ),
                data: data
            )
        }
    }

    private func pluginPathReferences(
        _ rawValue: Any?,
        root: URL
    ) -> [URL] {
        let references: [String]
        if let value = rawValue as? String {
            references = [value]
        } else if let values = rawValue as? [String] {
            references = values
        } else {
            return []
        }
        let resolvedRoot =
            root.standardizedFileURL
                .resolvingSymlinksInPath()
        var visited = Set<String>()
        return references.compactMap { reference in
            guard !reference.isEmpty,
                  !reference.contains("\0"),
                  !(reference as NSString).isAbsolutePath
            else {
                return nil
            }
            let lexical = root.appendingPathComponent(
                reference
            ).standardizedFileURL
            let resolved =
                lexical.resolvingSymlinksInPath()
            let prefix =
                resolvedRoot.path.hasSuffix("/")
                    ? resolvedRoot.path
                    : resolvedRoot.path + "/"
            guard resolved.path == resolvedRoot.path
                    || resolved.path.hasPrefix(prefix),
                  visited.insert(resolved.path).inserted
            else {
                return nil
            }
            return resolved
        }
    }

    private func pluginRelativePath(
        _ path: URL,
        root: URL
    ) -> String {
        let candidate = path.standardizedFileURL.path
        let rootPath = root.standardizedFileURL.path
        let prefix =
            rootPath.hasSuffix("/")
                ? rootPath : rootPath + "/"
        guard candidate.hasPrefix(prefix) else {
            return path.lastPathComponent
        }
        return String(candidate.dropFirst(prefix.count))
    }

    private func appIDs(at root: URL) -> [String] {
        objectKeys(
            at: root.appendingPathComponent(".app.json"),
            container: "apps"
        )
    }

    private func objectKeys(
        at path: URL,
        container: String
    ) -> [String] {
        guard let data = try? Data(contentsOf: path),
              let object = try? JSONSerialization.jsonObject(
                  with: data
              ) as? [String: Any],
              let values = object[container] as? [String: Any]
        else {
            return []
        }
        return values.keys.sorted()
    }

    private func validSegment(_ value: String) -> Bool {
        !value.isEmpty
            && value.allSatisfy {
                $0.isASCII
                    && ($0.isLetter || $0.isNumber
                        || $0 == "_" || $0 == "-")
            }
    }
}

private struct Marketplace: Decodable {
    let name: String
    let interface: MarketplaceInterface?
    let plugins: [MarketplacePlugin]
}

private struct MarketplaceInterface: Decodable {
    let displayName: String?
}

private struct MarketplacePlugin: Decodable {
    let name: String
    let source: MarketplaceSource
    let policy: MarketplacePolicy?
}

private struct MarketplaceSource: Decodable {
    let source: String
    let path: String?
}

private struct MarketplacePolicy: Decodable {
    let installation: String?
    let authentication: String?
}

private struct PluginManifest: Decodable {
    let name: String
    let version: String?
    let description: String?
    let keywords: [String]?
}
