import Foundation

public struct CodexAppCatalogItem: Equatable, Sendable {
    public let id: String
    public let name: String
    public let description: String?
    public let category: String?
    public let pluginDisplayNames: [String]
    public let isAccessible: Bool
    public let isEnabled: Bool
}

public struct CodexAppCatalogPage: Equatable, Sendable {
    public let data: [CodexAppCatalogItem]
    public let nextCursor: String?
    public let allData: [CodexAppCatalogItem]
    public let shouldPublishUpdate: Bool
}

public struct CodexAppReadResult: Equatable, Sendable {
    public let apps: [CodexAppCatalogItem]
    public let missingAppIDs: [String]
}

public struct CodexInstalledApp: Equatable, Sendable {
    public let id: String
    public let runtimeName: String?
    public let enabled: Bool
    public let callable: Bool
}

public enum CodexAppCatalogError: Error, Equatable, Sendable {
    case invalidCursor
    case invalidLimit
    case tooManyIDs
}

@MainActor
public final class CodexAppCatalogService {
    private let codexHome: URL
    private let fileManager: FileManager
    private var lastObservedApps: [CodexAppCatalogItem]?

    public init(
        codexHome: URL,
        fileManager: FileManager = .default
    ) {
        self.codexHome = codexHome.standardizedFileURL
        self.fileManager = fileManager
    }

    public func listApps(
        cursor: String?,
        limit: Int?,
        forceRefetch: Bool
    ) throws -> CodexAppCatalogPage {
        let start: Int
        if let cursor {
            guard let value = Int(cursor), value >= 0 else {
                throw CodexAppCatalogError.invalidCursor
            }
            start = value
        } else {
            start = 0
        }
        let all = loadApps()
        guard start <= all.count else {
            throw CodexAppCatalogError.invalidCursor
        }
        let pageSize = max(limit ?? all.count, 1)
        let shouldPublishUpdate = forceRefetch
            || start == 0
            || lastObservedApps.map { $0 != all } == true
        lastObservedApps = all
        guard start < all.count else {
            return CodexAppCatalogPage(
                data: [],
                nextCursor: nil,
                allData: all,
                shouldPublishUpdate: shouldPublishUpdate
            )
        }
        let end = min(start + pageSize, all.count)
        return CodexAppCatalogPage(
            data: Array(all[start..<end]),
            nextCursor: end < all.count ? String(end) : nil,
            allData: all,
            shouldPublishUpdate: shouldPublishUpdate
        )
    }

    public func readApps(
        appIDs: [String],
        includeTools _: Bool
    ) throws -> CodexAppReadResult {
        guard appIDs.count <= 100 else {
            throw CodexAppCatalogError.tooManyIDs
        }
        var seen: Set<String> = []
        let ids = appIDs.filter { seen.insert($0).inserted }
        let byID = Dictionary(
            uniqueKeysWithValues: loadApps().map { ($0.id, $0) }
        )
        return CodexAppReadResult(
            apps: ids.compactMap { byID[$0] },
            missingAppIDs: ids.filter { byID[$0] == nil }
        )
    }

    public func installedApps(
        forceRefresh _: Bool
    ) -> [CodexInstalledApp] {
        loadApps().map {
            CodexInstalledApp(
                id: $0.id,
                runtimeName: $0.name,
                enabled: $0.isEnabled,
                callable: $0.isEnabled && $0.isAccessible
            )
        }
    }

    private func loadApps() -> [CodexAppCatalogItem] {
        let cache = codexHome.appendingPathComponent(
            "plugins/cache",
            isDirectory: true
        )
        guard let enumerator = fileManager.enumerator(
            atPath: cache.path
        ) else { return [] }
        var merged: [
            String: (
                name: String,
                category: String?,
                plugins: Set<String>
            )
        ] = [:]
        for case let relative as String in enumerator
        where relative.hasSuffix(
            "/.codex-plugin/plugin.json"
        ) {
            let manifestURL = cache.appendingPathComponent(relative)
            guard let manifestData = try? Data(contentsOf: manifestURL),
                  let raw = try? JSONSerialization
                    .jsonObject(with: manifestData),
                  let manifest = raw as? [String: Any],
                  let pluginName =
                    (manifest["displayName"] as? String)
                    ?? (manifest["name"] as? String)
            else { continue }
            let pluginRoot = manifestURL
                .deletingLastPathComponent()
                .deletingLastPathComponent()
            let appPath: URL
            if let path = manifest["apps"] as? String {
                appPath = pluginRoot.appendingPathComponent(path)
                    .standardizedFileURL
            } else {
                appPath = pluginRoot.appendingPathComponent(".app.json")
            }
            guard appPath.path == pluginRoot.path
                    || appPath.path.hasPrefix(pluginRoot.path + "/"),
                  let appData = try? Data(contentsOf: appPath),
                  let appRaw = try? JSONSerialization
                    .jsonObject(with: appData),
                  let appFile = appRaw as? [String: Any],
                  let apps = appFile["apps"] as? [String: Any]
            else { continue }
            for (declarationName, value) in apps {
                guard let declaration = value as? [String: Any],
                      let id = declaration["id"] as? String,
                      !id.trimmingCharacters(
                          in: .whitespacesAndNewlines
                      ).isEmpty
                else { continue }
                let category = (
                    declaration["category"] as? String
                )?.trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
                if var existing = merged[id] {
                    existing.plugins.insert(pluginName)
                    if existing.category == nil,
                       category?.isEmpty == false
                    {
                        existing.category = category
                    }
                    merged[id] = existing
                } else {
                    merged[id] = (
                        name: declarationName,
                        category:
                            category?.isEmpty == false
                            ? category : nil,
                        plugins: [pluginName]
                    )
                }
            }
        }
        return merged.map { id, value in
            CodexAppCatalogItem(
                id: id,
                name: value.name,
                description: nil,
                category: value.category,
                pluginDisplayNames: value.plugins.sorted(),
                isAccessible: false,
                isEnabled: true
            )
        }.sorted {
            ($0.name.localizedLowercase, $0.id)
                < ($1.name.localizedLowercase, $1.id)
        }
    }
}
