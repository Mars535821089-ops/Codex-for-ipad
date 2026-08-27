#if SWIFT_PACKAGE
import CodexPadDomain
#endif
import Foundation

public struct CodexRemotePluginSummary: Equatable, Sendable {
    public let id: String
    public let remotePluginID: String
    public let version: String?
    public let localVersion: String?
    public let name: String
    public let installed: Bool
    public let enabled: Bool
    public let installPolicy: String
    public let installPolicySource: String?
    public let mustShowInstallationInterstitial: Bool?
    public let authPolicy: String
    public let availability: String
    public let interface: CodexJSONValue?
    public let keywords: [String]
    public var shareContext: CodexRemotePluginShareContext? = nil
}

public struct CodexRemotePluginSharePrincipal:
    Equatable,
    Sendable,
    Codable
{
    public let principalType: String
    public let principalID: String
    public let role: String
    public let name: String

    private enum CodingKeys: String, CodingKey {
        case principalType
        case principalID = "principalId"
        case role
        case name
    }
}

public struct CodexRemotePluginShareTarget:
    Equatable,
    Sendable,
    Codable
{
    public let principalType: String
    public let principalID: String
    public let role: String

    public init(
        principalType: String,
        principalID: String,
        role: String
    ) {
        self.principalType = principalType
        self.principalID = principalID
        self.role = role
    }

    private enum CodingKeys: String, CodingKey {
        case principalType
        case principalID = "principalId"
        case role
    }
}

public struct CodexRemotePluginShareContext:
    Equatable,
    Sendable
{
    public let remotePluginID: String
    public let remoteVersion: String?
    public let discoverability: String
    public let shareURL: String?
    public let creatorAccountUserID: String?
    public let creatorName: String?
    public let sharePrincipals: [CodexRemotePluginSharePrincipal]?
    public let canPublishToWorkspace: Bool?
}

public struct CodexRemotePluginShareUpdateResult:
    Equatable,
    Sendable
{
    public let principals: [CodexRemotePluginSharePrincipal]
    public let discoverability: String
}

public struct CodexRemotePluginShareSaveResult:
    Equatable,
    Sendable
{
    public let remotePluginID: String
    public let shareURL: String?
    public let canPublishToWorkspace: Bool?
}

public struct CodexRemotePluginShareCheckoutResult:
    Equatable,
    Sendable
{
    public let remotePluginID: String
    public let pluginID: String
    public let pluginName: String
    public let pluginPath: String
    public let marketplaceName: String
    public let marketplacePath: String
    public let remoteVersion: String?
}

public struct CodexRemotePluginShareListItem:
    Equatable,
    Sendable
{
    public let plugin: CodexRemotePluginSummary
    public let localPluginPath: String?
}

public struct CodexRemotePluginMarketplace: Equatable, Sendable {
    public let name: String
    public let displayName: String
    public let plugins: [CodexRemotePluginSummary]
}

public struct CodexRemotePluginListResponse: Equatable, Sendable {
    public let marketplaces: [CodexRemotePluginMarketplace]
    public let featuredPluginIDs: [String]
}

public struct CodexRemotePluginSearchResult: Equatable, Sendable {
    public let plugin: CodexRemotePluginSummary
    public let marketplaceName: String
    public let marketplacePath: String?

    public init(
        plugin: CodexRemotePluginSummary,
        marketplaceName: String,
        marketplacePath: String?
    ) {
        self.plugin = plugin
        self.marketplaceName = marketplaceName
        self.marketplacePath = marketplacePath
    }
}

public struct CodexRemotePluginSearchResponse: Equatable, Sendable {
    public let data: [CodexRemotePluginSearchResult]
    public let nextCursor: String?

    public init(
        data: [CodexRemotePluginSearchResult],
        nextCursor: String?
    ) {
        self.data = data
        self.nextCursor = nextCursor
    }
}

public struct CodexRemotePluginSkill: Equatable, Sendable {
    public let name: String
    public let description: String
    public let interface: CodexJSONValue?
    public let enabled: Bool
}

public struct CodexRemotePluginDetail: Equatable, Sendable {
    public let marketplaceName: String
    public let marketplaceDisplayName: String
    public let summary: CodexRemotePluginSummary
    public let shareURL: String?
    public let description: String?
    public let releaseVersion: String?
    public let bundleDownloadURL: String?
    public let appManifest: CodexJSONValue?
    public let skills: [CodexRemotePluginSkill]
    public let appIDs: [String]
    public let appTemplates: [CodexJSONValue]
    public let mcpServerNames: [String]
    public let scheduledTasks: [CodexJSONValue]?
}

public enum CodexRemotePluginError: Error, Equatable, Sendable {
    case authenticationRequired
    case invalidRemotePluginID
    case unknownMarketplace(String)
    case invalidURL
    case requestFailed(status: Int, message: String)
    case invalidResponse(String)
    case unexpectedPluginID(expected: String, actual: String)
    case unexpectedEnabledState(
        pluginID: String,
        expected: Bool,
        actual: Bool
    )
}

@MainActor
public final class CodexRemotePluginService {
    nonisolated public static let globalMarketplace =
        "openai-curated-remote"
    nonisolated public static let createdByMeMarketplace =
        "created-by-me-remote"
    nonisolated public static let workspaceMarketplace =
        "workspace-directory"
    nonisolated public static let sharedWithMeMarketplace =
        "workspace-shared-with-me"
    nonisolated public static let sharedPrivateMarketplace =
        "workspace-shared-with-me-private"
    nonisolated public static let sharedUnlistedMarketplace =
        "workspace-shared-with-me-unlisted"

    private let credentialsProvider: () -> CodexOfficialCredentials?
    private let transport: any CodexDesktopNetworkFetchTransport
    private let baseURL: URL
    private let decoder: JSONDecoder
    private let archiveService: any CodexPluginBundleArchiving
    private let localPathStore: CodexPluginShareLocalPathStore
    private let homeDirectory: URL
    private var detailsByRemoteID: [String: DirectoryItem] = [:]

    public init(
        credentialsProvider:
            @escaping () -> CodexOfficialCredentials?,
        transport: any CodexDesktopNetworkFetchTransport =
            CodexDesktopURLSessionNetworkFetchTransport(),
        baseURL: URL =
            CodexDesktopNetworkFetchClient.releasedProductAPIBaseURL,
        archiveService: any CodexPluginBundleArchiving =
            CodexPluginBundleArchiveService(),
        codexHome: URL = URL(
            fileURLWithPath: NSHomeDirectory(),
            isDirectory: true
        )
            .appendingPathComponent(".codex"),
        homeDirectory: URL = URL(
            fileURLWithPath: NSHomeDirectory(),
            isDirectory: true
        )
    ) {
        self.credentialsProvider = credentialsProvider
        self.transport = transport
        self.baseURL = baseURL
        self.archiveService = archiveService
        localPathStore = CodexPluginShareLocalPathStore(
            codexHome: codexHome
        )
        self.homeDirectory = homeDirectory.standardizedFileURL
        decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
    }

    public func list(
        marketplaceKinds: [String],
        forceRefetch _: Bool
    ) async throws -> CodexRemotePluginListResponse {
        var marketplaces: [CodexRemotePluginMarketplace] = []
        let requested = Set(marketplaceKinds)

        if requested.contains("vertical")
            || requested.contains("global")
        {
            let isVertical = requested.contains("vertical")
            if let marketplace = try await marketplace(
                scope: .global,
                collection: isVertical ? "vertical" : nil,
                includeInstalledOnly: !isVertical
            ) {
                marketplaces.append(marketplace)
            }
        }
        if requested.contains("created-by-me-remote")
            || requested.contains("user")
        {
            if let marketplace = try await marketplace(
                scope: .user,
                includeInstalledOnly: false
            ) {
                marketplaces.append(marketplace)
            }
        }
        if requested.contains("workspace-directory") {
            if let marketplace = try await marketplace(
                scope: .workspace,
                includeInstalledOnly: false
            ) {
                marketplaces.append(marketplace)
            }
        }
        if requested.contains("shared-with-me") {
            let directory = try await pagedDirectory(
                path: "ps/plugins/workspace/shared",
                scope: nil,
                collection: nil
            )
            let installed = try await pagedInstalled(
                scope: .workspace
            )
            let groups = try buildSharedMarketplaces(
                directory: directory,
                installed: installed
            )
            marketplaces.append(contentsOf: groups)
        }

        let featured = try await featuredPluginIDs()
        return CodexRemotePluginListResponse(
            marketplaces: marketplaces,
            featuredPluginIDs: featured
        )
    }

    public func search(
        searchTerm: String,
        scope: String?,
        cwds _: [String]?,
        cursor: String?,
        limit: Int?
    ) async throws -> CodexRemotePluginSearchResponse {
        let term = searchTerm.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !term.isEmpty else {
            return CodexRemotePluginSearchResponse(
                data: [],
                nextCursor: nil
            )
        }
        let scopeValue: Scope?
        switch scope {
        case nil:
            scopeValue = nil
        case "global":
            scopeValue = .global
        case "workspace":
            scopeValue = .workspace
        case "personal":
            scopeValue = .user
        default:
            throw CodexRemotePluginError.invalidResponse(
                "invalid plugin search scope"
            )
        }
        let normalizedLimit = min(
            max(limit ?? 16, 1),
            1_000
        )
        var query = [
            URLQueryItem(name: "q", value: term),
        ]
        if let scopeValue {
            query.append(
                URLQueryItem(
                    name: "scope",
                    value: scopeValue.rawValue
                )
            )
        }
        query.append(
            URLQueryItem(
                name: "limit",
                value: String(normalizedLimit)
            )
        )
        if let cursor {
            query.append(
                URLQueryItem(name: "pageToken", value: cursor)
            )
        }
        let page: DirectoryPage = try await request(
            path: "ps/plugins/search",
            method: "GET",
            query: query
        )
        let data = try page.plugins.map { item in
            let marketplaceName = try canonicalMarketplace(for: item)
            return CodexRemotePluginSearchResult(
                plugin: try makeSummary(item, installed: nil),
                marketplaceName: marketplaceName,
                marketplacePath: nil
            )
        }
        return CodexRemotePluginSearchResponse(
            data: data,
            nextCursor: page.pagination.nextPageToken
        )
    }

    public func installed() async throws
        -> [CodexRemotePluginMarketplace]
    {
        var all: [InstalledItem] = []
        for scope in Scope.allCases {
            all.append(contentsOf: try await pagedInstalled(scope: scope))
        }
        return try groupInstalled(all)
    }

    public func read(
        marketplaceName _: String,
        remotePluginID: String
    ) async throws -> CodexRemotePluginDetail {
        try validate(remotePluginID)
        let item: DirectoryItem = try await request(
            path: "ps/plugins/\(remotePluginID)",
            method: "GET"
        )
        guard item.id == remotePluginID else {
            throw CodexRemotePluginError.unexpectedPluginID(
                expected: remotePluginID,
                actual: item.id
            )
        }
        detailsByRemoteID[item.id] = item
        let installed = try await pagedInstalled(scope: item.scope)
            .first { $0.id == item.id }
        return try makeDetail(item, installed: installed)
    }

    public func skillContents(
        remotePluginID: String,
        skillName: String
    ) async throws -> String? {
        try validate(remotePluginID)
        guard !skillName.isEmpty else {
            throw CodexRemotePluginError.invalidResponse(
                "empty skill name"
            )
        }
        let response: SkillDetailResponse = try await request(
            path:
                "ps/plugins/\(remotePluginID)/skills/\(skillName)",
            method: "GET"
        )
        guard response.pluginId == remotePluginID else {
            throw CodexRemotePluginError.unexpectedPluginID(
                expected: remotePluginID,
                actual: response.pluginId
            )
        }
        guard response.name == skillName else {
            throw CodexRemotePluginError.invalidResponse(
                "unexpected skill name \(response.name)"
            )
        }
        return response.skillMdContents
    }

    public func install(
        marketplaceName _: String,
        remotePluginID: String
    ) async throws -> CodexPluginInstallResult {
        try validate(remotePluginID)
        let detail: DirectoryItem
        if let cached = detailsByRemoteID[remotePluginID] {
            detail = cached
        } else {
            detail = try await request(
                path: "ps/plugins/\(remotePluginID)",
                method: "GET"
            )
            guard detail.id == remotePluginID else {
                throw CodexRemotePluginError.unexpectedPluginID(
                    expected: remotePluginID,
                    actual: detail.id
                )
            }
            detailsByRemoteID[detail.id] = detail
        }
        let response: MutationResponse = try await request(
            path: "ps/plugins/\(remotePluginID)/install",
            method: "POST",
            query: [
                URLQueryItem(
                    name: "includeAppsNeedingAuth",
                    value: "true"
                ),
            ]
        )
        try verifyMutation(
            response,
            remotePluginID: remotePluginID,
            expectedEnabled: true
        )
        return CodexPluginInstallResult(
            authPolicy: detail.authenticationPolicy,
            appsNeedingAuth: response.appIdsNeedingAuth ?? []
        )
    }

    public func uninstall(remotePluginID: String) async throws {
        try validate(remotePluginID)
        let response: MutationResponse = try await request(
            path: "ps/plugins/\(remotePluginID)/uninstall",
            method: "POST"
        )
        try verifyMutation(
            response,
            remotePluginID: remotePluginID,
            expectedEnabled: false
        )
    }

    public func uninstall(pluginID: String) async throws {
        if let cached = detailsByRemoteID.first(where: { entry in
            guard let marketplace = try? canonicalMarketplace(
                for: entry.value
            ) else { return false }
            return "\(entry.value.name)@\(marketplace)" == pluginID
        }) {
            try await uninstall(remotePluginID: cached.key)
            return
        }
        let installedMarketplaces = try await installed()
        guard let summary = installedMarketplaces
            .flatMap(\.plugins)
            .first(where: { $0.id == pluginID })
        else {
            throw CodexRemotePluginError.invalidRemotePluginID
        }
        try await uninstall(remotePluginID: summary.remotePluginID)
    }

    public func updateShareTargets(
        remotePluginID: String,
        discoverability: String,
        shareTargets: [CodexRemotePluginShareTarget]
    ) async throws -> CodexRemotePluginShareUpdateResult {
        try validate(remotePluginID)
        guard ["LISTED", "UNLISTED", "PRIVATE"].contains(
            discoverability
        ),
        shareTargets.allSatisfy({
            ["user", "group", "workspace"].contains(
                $0.principalType
            )
                && !$0.principalID.isEmpty
                && ["reader", "editor"].contains($0.role)
        })
        else {
            throw CodexRemotePluginError.invalidResponse(
                "invalid plugin share target"
            )
        }
        var targets = shareTargets
        if discoverability == "UNLISTED",
           let accountID = credentialsProvider()?.accountID,
           !targets.contains(where: {
               $0.principalType == "workspace"
                   && $0.principalID == accountID
           })
        {
            targets.append(
                CodexRemotePluginShareTarget(
                    principalType: "workspace",
                    principalID: accountID,
                    role: "reader"
                )
            )
        }
        let body = try JSONEncoder.remotePluginEncoder.encode(
            ShareUpdateRequest(
                discoverability: discoverability,
                targets: targets
            )
        )
        let response: ShareUpdateResponse = try await request(
            path: "ps/plugins/\(remotePluginID)/shares",
            method: "PUT",
            body: body
        )
        return CodexRemotePluginShareUpdateResult(
            principals: response.principals,
            discoverability: response.discoverability
        )
    }

    public func listShares() async throws
        -> [CodexRemotePluginShareListItem]
    {
        let created = try await pagedDirectory(
            path: "ps/plugins/workspace/created",
            scope: nil,
            collection: nil
        )
        guard !created.isEmpty else { return [] }
        let installed = try await pagedInstalled(scope: .workspace)
        let installedByID = Dictionary(
            uniqueKeysWithValues: installed.map { ($0.id, $0) }
        )
        return try created.map { item in
            guard item.sharePrincipals != nil else {
                throw CodexRemotePluginError.invalidResponse(
                    "created workspace plugin \(item.id) lacks share principals"
                )
            }
            return CodexRemotePluginShareListItem(
                plugin: try makeSummary(
                    item,
                    installed: installedByID[item.id]
                ),
                localPluginPath: nil
            )
        }
    }

    public func deleteShare(remotePluginID: String) async throws {
        try validate(remotePluginID)
        let response = try await rawRequest(
            path: "public/plugins/workspace/\(remotePluginID)",
            method: "DELETE"
        )
        guard response.status == 204 else {
            throw CodexRemotePluginError.requestFailed(
                status: response.status,
                message:
                    String(data: response.body, encoding: .utf8) ?? ""
            )
        }
        detailsByRemoteID.removeValue(forKey: remotePluginID)
        try? localPathStore.remove(remotePluginID: remotePluginID)
    }

    public func saveShare(
        pluginPath: URL,
        remotePluginID: String? = nil,
        discoverability: String? = nil,
        shareTargets: [CodexRemotePluginShareTarget]? = nil
    ) async throws -> CodexRemotePluginShareSaveResult {
        if let remotePluginID { try validate(remotePluginID) }
        if remotePluginID != nil,
           discoverability != nil || shareTargets != nil
        {
            throw CodexRemotePluginError.invalidResponse(
                "access policy is only supported for new shares"
            )
        }
        if let discoverability,
           !["UNLISTED", "PRIVATE"].contains(discoverability)
        {
            throw CodexRemotePluginError.invalidResponse(
                "invalid share discoverability"
            )
        }
        let archive = try archiveService.packDirectory(
            at: pluginPath,
            maximumBytes: 50 * 1024 * 1024
        )
        let filename = pluginPath.lastPathComponent + ".tar.gz"
        let uploadBody = try JSONEncoder.remotePluginEncoder.encode(
            WorkspaceUploadURLRequest(
                filename: filename,
                mimeType: "application/gzip",
                sizeBytes: archive.count,
                pluginID: remotePluginID
            )
        )
        let upload: WorkspaceUploadURLResponse = try await request(
            path: "public/plugins/workspace/upload-url",
            method: "POST",
            body: uploadBody
        )
        guard !upload.fileId.isEmpty,
              let uploadURL = URL(string: upload.uploadUrl),
              let etag = upload.etag,
              !etag.isEmpty
        else {
            throw CodexRemotePluginError.invalidResponse(
                "workspace upload response is incomplete"
            )
        }
        let uploadResponse = try await transport.execute(
            CodexDesktopNetworkTransportRequest(
                url: uploadURL,
                method: "PUT",
                headers: [
                    "Content-Type": "application/gzip",
                    "x-ms-blob-type": "BlockBlob",
                ],
                body: archive
            )
        )
        guard (200..<300).contains(uploadResponse.status) else {
            throw CodexRemotePluginError.requestFailed(
                status: uploadResponse.status,
                message: String(
                    data: uploadResponse.body,
                    encoding: .utf8
                ) ?? ""
            )
        }
        let finalizeBody = try JSONEncoder.remotePluginEncoder.encode(
            WorkspaceFinalizeRequest(
                fileID: upload.fileId,
                etag: etag,
                discoverability: discoverability,
                shareTargets: shareTargets
            )
        )
        let path = remotePluginID.map {
            "public/plugins/workspace/\($0)"
        } ?? "public/plugins/workspace"
        let result: WorkspaceFinalizeResponse = try await request(
            path: path,
            method: "POST",
            body: finalizeBody
        )
        guard !result.pluginId.isEmpty else {
            throw CodexRemotePluginError.invalidResponse(
                "workspace plugin response lacks plugin id"
            )
        }
        try? localPathStore.record(
            remotePluginID: result.pluginId,
            pluginPath: pluginPath
        )
        return CodexRemotePluginShareSaveResult(
            remotePluginID: result.pluginId,
            shareURL: result.shareUrl,
            canPublishToWorkspace: result.canPublishToWorkspace
        )
    }

    public func checkoutShare(
        remotePluginID: String
    ) async throws -> CodexRemotePluginShareCheckoutResult {
        try validate(remotePluginID)
        let detail = try await read(
            marketplaceName: Self.sharedPrivateMarketplace,
            remotePluginID: remotePluginID
        )
        let supported = [
            Self.sharedWithMeMarketplace,
            Self.sharedPrivateMarketplace,
            Self.sharedUnlistedMarketplace,
        ]
        guard supported.contains(detail.marketplaceName),
              detail.summary.shareContext != nil,
              Self.isValidPluginSegment(detail.summary.name)
        else {
            throw CodexRemotePluginError.invalidResponse(
                "plugin share checkout is unavailable"
            )
        }
        let mapping = (try? localPathStore.load()) ?? [:]
        let existing = mapping[remotePluginID]
        let pluginPath = (
            existing
                ?? homeDirectory.appendingPathComponent(
                    "plugins/\(detail.summary.name)",
                    isDirectory: true
                )
        ).standardizedFileURL
        try Self.ensureInsideHome(pluginPath, home: homeDirectory)
        let alreadyCheckedOut = existing != nil
            && FileManager.default.fileExists(atPath: pluginPath.path)
        var createdCheckout = false
        if !alreadyCheckedOut {
            guard !FileManager.default.fileExists(
                atPath: pluginPath.path
            ) else {
                throw CodexRemotePluginError.invalidResponse(
                    "checkout destination already exists"
                )
            }
            guard let version = detail.releaseVersion?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                !version.isEmpty,
                let urlString = detail.bundleDownloadURL,
                let url = URL(string: urlString),
                url.scheme?.lowercased() == "https"
            else {
                throw CodexRemotePluginError.invalidResponse(
                    "remote plugin bundle metadata is incomplete"
                )
            }
            let download = try await transport.execute(
                CodexDesktopNetworkTransportRequest(
                    url: url,
                    method: "GET",
                    headers: ["Accept": "application/gzip"],
                    body: nil
                )
            )
            guard (200..<300).contains(download.status) else {
                throw CodexRemotePluginError.requestFailed(
                    status: download.status,
                    message: String(
                        data: download.body.prefix(8 * 1024),
                        encoding: .utf8
                    ) ?? ""
                )
            }
            guard download.body.count <= 50 * 1024 * 1024 else {
                throw CodexRemotePluginError.invalidResponse(
                    "remote plugin bundle exceeds 50 MB"
                )
            }
            try archiveService.extractGzipTar(
                download.body,
                to: pluginPath,
                maximumExpandedBytes: 250 * 1024 * 1024
            )
            createdCheckout = true
        }
        do {
            let marketplace = try updatePersonalMarketplace(
                pluginName: detail.summary.name,
                pluginPath: pluginPath,
                installPolicy: detail.summary.installPolicy,
                authPolicy: detail.summary.authPolicy,
                category: Self.interfaceCategory(
                    detail.summary.interface
                )
            )
            try localPathStore.record(
                remotePluginID: remotePluginID,
                pluginPath: pluginPath
            )
            return CodexRemotePluginShareCheckoutResult(
                remotePluginID: remotePluginID,
                pluginID:
                    "\(detail.summary.name)@\(marketplace.name)",
                pluginName: detail.summary.name,
                pluginPath: pluginPath.path,
                marketplaceName: marketplace.name,
                marketplacePath: marketplace.path.path,
                remoteVersion: detail.releaseVersion
            )
        } catch {
            if createdCheckout {
                try? FileManager.default.removeItem(at: pluginPath)
            }
            throw error
        }
    }

    private func marketplace(
        scope: Scope,
        collection: String? = nil,
        includeInstalledOnly: Bool
    ) async throws -> CodexRemotePluginMarketplace? {
        let directory = try await pagedDirectory(
            path: "ps/plugins/list",
            scope: scope,
            collection: collection
        )
        let installed = try await pagedInstalled(scope: scope)
        var installedByID = Dictionary(
            uniqueKeysWithValues: installed.map { ($0.id, $0) }
        )
        var summaries = try directory.map { item in
            let match = installedByID.removeValue(forKey: item.id)
            return try makeSummary(item, installed: match)
        }
        if includeInstalledOnly {
            summaries.append(
                contentsOf: try installedByID.values.map {
                    try makeSummary($0.directoryItem, installed: $0)
                }
            )
        }
        guard !summaries.isEmpty else { return nil }
        return CodexRemotePluginMarketplace(
            name: scope.marketplaceName,
            displayName: scope.displayName,
            plugins: sort(summaries)
        )
    }

    private func pagedDirectory(
        path: String,
        scope: Scope?,
        collection: String?
    ) async throws -> [DirectoryItem] {
        var result: [DirectoryItem] = []
        var pageToken: String?
        repeat {
            var query: [URLQueryItem] = []
            if let scope {
                query.append(
                    URLQueryItem(name: "scope", value: scope.rawValue)
                )
            }
            query.append(URLQueryItem(name: "limit", value: "200"))
            if let collection {
                query.append(
                    URLQueryItem(
                        name: "collection",
                        value: collection
                    )
                )
            }
            if let pageToken {
                query.append(
                    URLQueryItem(name: "pageToken", value: pageToken)
                )
            }
            let page: DirectoryPage = try await request(
                path: path,
                method: "GET",
                query: query
            )
            result.append(contentsOf: page.plugins)
            pageToken = page.pagination.nextPageToken
        } while pageToken != nil
        for item in result {
            detailsByRemoteID[item.id] = item
        }
        return result
    }

    private func pagedInstalled(
        scope: Scope
    ) async throws -> [InstalledItem] {
        var result: [InstalledItem] = []
        var pageToken: String?
        repeat {
            var query = [
                URLQueryItem(name: "scope", value: scope.rawValue),
            ]
            if let pageToken {
                query.append(
                    URLQueryItem(name: "pageToken", value: pageToken)
                )
            }
            let page: InstalledPage = try await request(
                path: "ps/plugins/installed",
                method: "GET",
                query: query
            )
            result.append(contentsOf: page.plugins)
            pageToken = page.pagination.nextPageToken
        } while pageToken != nil
        for item in result {
            detailsByRemoteID[item.id] = item.directoryItem
        }
        return result
    }

    private func featuredPluginIDs() async throws -> [String] {
        let response: RecommendedResponse = try await request(
            path: "ps/plugins/suggested",
            method: "GET"
        )
        guard response.enabled == true else { return [] }
        var seen = Set<String>()
        return response.plugins.compactMap { item in
            guard isValidRemoteID(item.id),
                  item.status.map({ $0 == "AVAILABLE" }) ?? true,
                  item.installationPolicy.map({
                      $0 == "AVAILABLE"
                  }) ?? true,
                  seen.insert(item.id).inserted
            else { return nil }
            return item.id
        }
    }

    private func buildSharedMarketplaces(
        directory: [DirectoryItem],
        installed: [InstalledItem]
    ) throws -> [CodexRemotePluginMarketplace] {
        let installedByID = Dictionary(
            uniqueKeysWithValues: installed.map { ($0.id, $0) }
        )
        let sharedIDs = Set(directory.map(\.id))
        let directlyShared: [CodexRemotePluginSummary] =
            try directory.compactMap { item in
            guard item.scope == .workspace else { return nil }
            switch item.discoverability {
            case "PRIVATE", "UNLISTED":
                return try makeSummary(
                    item,
                    installed: installedByID[item.id]
                )
            case "LISTED":
                return nil
            default:
                throw CodexRemotePluginError.invalidResponse(
                    "workspace plugin \(item.id) lacks discoverability"
                )
            }
        }
        let linkInstalled: [CodexRemotePluginSummary] =
            try installed.compactMap { item in
            guard item.scope == .workspace,
                  item.discoverability == "UNLISTED",
                  !sharedIDs.contains(item.id)
            else { return nil }
            return try makeSummary(item.directoryItem, installed: item)
        }
        var marketplaces: [CodexRemotePluginMarketplace] = []
        if !directlyShared.isEmpty {
            marketplaces.append(
                CodexRemotePluginMarketplace(
                    name: Self.sharedPrivateMarketplace,
                    displayName: displayName(
                        for: Self.sharedPrivateMarketplace
                    ),
                    plugins: sort(directlyShared)
                )
            )
        }
        if !linkInstalled.isEmpty {
            marketplaces.append(
                CodexRemotePluginMarketplace(
                    name: Self.sharedUnlistedMarketplace,
                    displayName: displayName(
                        for: Self.sharedUnlistedMarketplace
                    ),
                    plugins: sort(linkInstalled)
                )
            )
        }
        return marketplaces
    }

    private func groupInstalled(
        _ installed: [InstalledItem]
    ) throws -> [CodexRemotePluginMarketplace] {
        var groups: [String: [CodexRemotePluginSummary]] = [:]
        for item in installed {
            let marketplace = try canonicalMarketplace(
                for: item.directoryItem
            )
            groups[marketplace, default: []].append(
                try makeSummary(item.directoryItem, installed: item)
            )
        }
        let order = [
            Self.globalMarketplace,
            Self.createdByMeMarketplace,
            Self.workspaceMarketplace,
            Self.sharedWithMeMarketplace,
            Self.sharedPrivateMarketplace,
            Self.sharedUnlistedMarketplace,
        ]
        return order.compactMap { name in
            guard let plugins = groups[name], !plugins.isEmpty else {
                return nil
            }
            return CodexRemotePluginMarketplace(
                name: name,
                displayName: displayName(for: name),
                plugins: sort(plugins)
            )
        }
    }

    private func makeDetail(
        _ item: DirectoryItem,
        installed: InstalledItem?
    ) throws -> CodexRemotePluginDetail {
        let disabled = Set(installed?.disabledSkillNames ?? [])
        return CodexRemotePluginDetail(
            marketplaceName: try canonicalMarketplace(for: item),
            marketplaceDisplayName: item.scope.displayName,
            summary: try makeSummary(item, installed: installed),
            shareURL: item.shareUrl,
            description: item.release.description.nilIfEmpty,
            releaseVersion: item.release.version,
            bundleDownloadURL: item.release.bundleDownloadUrl,
            appManifest: item.release.appManifest,
            skills: item.release.skills.map {
                CodexRemotePluginSkill(
                    name: $0.name,
                    description: $0.description,
                    interface: $0.interface,
                    enabled: !disabled.contains($0.name)
                )
            },
            appIDs: item.release.appIds,
            appTemplates: item.release.appTemplates,
            mcpServerNames: Array(
                Set(item.release.mcpServers.map(\.key))
            ).sorted(),
            scheduledTasks: item.release.scheduledTasks
        )
    }

    private func makeSummary(
        _ item: DirectoryItem,
        installed: InstalledItem?
    ) throws -> CodexRemotePluginSummary {
        let marketplace = try canonicalMarketplace(for: item)
        return CodexRemotePluginSummary(
            id: "\(item.name)@\(marketplace)",
            remotePluginID: item.id,
            version: item.release.version,
            localVersion: installed?.release.version,
            name: item.name,
            installed: installed != nil,
            enabled: installed?.enabled ?? false,
            installPolicy: item.installationPolicy,
            installPolicySource: item.installationPolicySource,
            mustShowInstallationInterstitial:
                item.mustShowInstallationInterstitial,
            authPolicy: item.authenticationPolicy,
            availability: item.status ?? "AVAILABLE",
            interface: item.release.interface,
            keywords: item.release.keywords,
            shareContext: shareContext(for: item)
        )
    }

    private func shareContext(
        for item: DirectoryItem
    ) -> CodexRemotePluginShareContext? {
        guard item.scope == .workspace,
              let discoverability = item.discoverability
        else { return nil }
        return CodexRemotePluginShareContext(
            remotePluginID: item.id,
            remoteVersion: item.release.version,
            discoverability: discoverability,
            shareURL: item.shareUrl,
            creatorAccountUserID: item.creatorAccountUserId,
            creatorName: item.creatorName,
            sharePrincipals: item.sharePrincipals,
            canPublishToWorkspace: item.canPublishToWorkspace
        )
    }

    private func canonicalMarketplace(
        for item: DirectoryItem
    ) throws -> String {
        switch item.scope {
        case .global:
            return Self.globalMarketplace
        case .user:
            return Self.createdByMeMarketplace
        case .workspace:
            switch item.discoverability {
            case "LISTED":
                return Self.workspaceMarketplace
            case "PRIVATE":
                return Self.sharedWithMeMarketplace
            case "UNLISTED":
                return Self.sharedWithMeMarketplace
            default:
                throw CodexRemotePluginError.invalidResponse(
                    "workspace plugin \(item.id) lacks discoverability"
                )
            }
        }
    }

    private func displayName(for marketplace: String) -> String {
        switch marketplace {
        case Self.globalMarketplace: "OpenAI Curated Remote"
        case Self.createdByMeMarketplace: "Created by me"
        case Self.workspaceMarketplace: "Workspace Directory"
        case Self.sharedUnlistedMarketplace:
            "Shared with me (unlisted)"
        default: "Shared with me"
        }
    }

    private func sort(
        _ summaries: [CodexRemotePluginSummary]
    ) -> [CodexRemotePluginSummary] {
        summaries.sorted {
            $0.name.localizedStandardCompare($1.name)
                == .orderedAscending
        }
    }

    private func verifyMutation(
        _ response: MutationResponse,
        remotePluginID: String,
        expectedEnabled: Bool
    ) throws {
        guard response.id == remotePluginID else {
            throw CodexRemotePluginError.unexpectedPluginID(
                expected: remotePluginID,
                actual: response.id
            )
        }
        guard response.enabled == expectedEnabled else {
            throw CodexRemotePluginError.unexpectedEnabledState(
                pluginID: remotePluginID,
                expected: expectedEnabled,
                actual: response.enabled
            )
        }
    }

    private func request<Response: Decodable>(
        path: String,
        method: String,
        query: [URLQueryItem] = [],
        body: Data? = nil
    ) async throws -> Response {
        let response = try await rawRequest(
            path: path,
            method: method,
            query: query,
            body: body
        )
        guard (200..<300).contains(response.status) else {
            throw CodexRemotePluginError.requestFailed(
                status: response.status,
                message:
                    String(data: response.body, encoding: .utf8) ?? ""
            )
        }
        do {
            return try decoder.decode(Response.self, from: response.body)
        } catch {
            throw CodexRemotePluginError.invalidResponse(
                String(describing: error)
            )
        }
    }

    private func rawRequest(
        path: String,
        method: String,
        query: [URLQueryItem] = [],
        body: Data? = nil
    ) async throws -> CodexDesktopNetworkTransportResponse {
        guard let credentials = credentialsProvider() else {
            throw CodexRemotePluginError.authenticationRequired
        }
        guard var components = URLComponents(
            url: baseURL.appendingPathComponent(path),
            resolvingAgainstBaseURL: false
        ) else {
            throw CodexRemotePluginError.invalidURL
        }
        components.queryItems = query.isEmpty ? nil : query
        guard let url = components.url else {
            throw CodexRemotePluginError.invalidURL
        }
        var headers = [
            "Authorization": "Bearer \(credentials.accessToken)",
            "OAI-Product-Sku": "codex",
            "Accept": "application/json",
        ]
        if body != nil {
            headers["Content-Type"] = "application/json"
        }
        if let accountID = credentials.accountID,
           !accountID.isEmpty
        {
            headers["chatgpt-account-id"] = accountID
        }
        return try await transport.execute(
            CodexDesktopNetworkTransportRequest(
                url: url,
                method: method,
                headers: headers,
                body: body
            )
        )
    }

    private func updatePersonalMarketplace(
        pluginName: String,
        pluginPath: URL,
        installPolicy: String,
        authPolicy: String,
        category: String?
    ) throws -> (name: String, path: URL) {
        let marketplacePath = homeDirectory.appendingPathComponent(
            ".agents/plugins/marketplace.json"
        )
        let relative = try Self.relativeMarketplacePath(
            pluginPath,
            home: homeDirectory
        )
        var marketplace: [String: Any]
        if FileManager.default.fileExists(
            atPath: marketplacePath.path
        ) {
            guard let object = try JSONSerialization.jsonObject(
                with: Data(contentsOf: marketplacePath)
            ) as? [String: Any] else {
                throw CodexRemotePluginError.invalidResponse(
                    "personal marketplace must be a JSON object"
                )
            }
            marketplace = object
        } else {
            marketplace = [
                "name": "codex-curated",
                "interface": ["displayName": "Personal"],
                "plugins": [],
            ]
        }
        let marketplaceName =
            marketplace["name"] as? String ?? "codex-curated"
        guard Self.isValidPluginSegment(marketplaceName),
              var plugins = marketplace["plugins"] as? [[String: Any]]
        else {
            throw CodexRemotePluginError.invalidResponse(
                "personal marketplace metadata is invalid"
            )
        }
        var entry: [String: Any] = [
            "name": pluginName,
            "source": [
                "source": "local",
                "path": relative,
            ],
            "policy": [
                "installation": installPolicy,
                "authentication": authPolicy,
            ],
        ]
        if let category,
           !category.trimmingCharacters(
               in: .whitespacesAndNewlines
           ).isEmpty
        {
            entry["category"] = category
        }
        if let index = plugins.firstIndex(where: {
            $0["name"] as? String == pluginName
        }) {
            let oldSource = plugins[index]["source"]
                as? [String: Any]
            guard oldSource?["path"] as? String == relative else {
                throw CodexRemotePluginError.invalidResponse(
                    "personal marketplace has a conflicting plugin path"
                )
            }
            plugins[index] = entry
        } else {
            plugins.append(entry)
        }
        marketplace["name"] = marketplaceName
        marketplace["plugins"] = plugins
        try FileManager.default.createDirectory(
            at: marketplacePath.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var data = try JSONSerialization.data(
            withJSONObject: marketplace,
            options: [.prettyPrinted, .sortedKeys]
        )
        data.append(0x0a)
        try data.write(to: marketplacePath, options: .atomic)
        return (marketplaceName, marketplacePath)
    }

    private static func interfaceCategory(
        _ value: CodexJSONValue?
    ) -> String? {
        guard case let .object(object)? = value,
              case let .string(category)? = object["category"]
        else { return nil }
        return category
    }

    private static func isValidPluginSegment(
        _ value: String
    ) -> Bool {
        !value.isEmpty
            && value != "." && value != ".."
            && !value.contains("/")
            && !value.contains("\\")
            && value.unicodeScalars.allSatisfy {
                !$0.properties.isWhitespace
                    && !CharacterSet.controlCharacters.contains($0)
            }
    }

    private static func ensureInsideHome(
        _ path: URL,
        home: URL
    ) throws {
        _ = try relativeMarketplacePath(path, home: home)
    }

    private static func relativeMarketplacePath(
        _ path: URL,
        home: URL
    ) throws -> String {
        let root = home.standardizedFileURL.path
        let candidate = path.standardizedFileURL.path
        let prefix = root.hasSuffix("/") ? root : root + "/"
        guard candidate.hasPrefix(prefix) else {
            throw CodexRemotePluginError.invalidResponse(
                "plugin path must be inside the home directory"
            )
        }
        let relative = String(candidate.dropFirst(prefix.count))
        guard !relative.isEmpty,
              !relative.split(separator: "/").contains("..")
        else {
            throw CodexRemotePluginError.invalidResponse(
                "plugin path cannot be represented in marketplace"
            )
        }
        return "./\(relative)"
    }

    private func validate(_ remotePluginID: String) throws {
        guard isValidRemoteID(remotePluginID) else {
            throw CodexRemotePluginError.invalidRemotePluginID
        }
    }

    private func isValidRemoteID(_ value: String) -> Bool {
        !value.isEmpty && value.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0)
                || $0 == "_" || $0 == "-" || $0 == "~"
        }
    }
}

private extension CodexRemotePluginService {
    enum Scope: String, CaseIterable, Decodable, Sendable {
        case global = "GLOBAL"
        case user = "USER"
        case workspace = "WORKSPACE"

        var marketplaceName: String {
            switch self {
            case .global:
                CodexRemotePluginService.globalMarketplace
            case .user:
                CodexRemotePluginService.createdByMeMarketplace
            case .workspace:
                CodexRemotePluginService.workspaceMarketplace
            }
        }

        var displayName: String {
            switch self {
            case .global: "OpenAI Curated Remote"
            case .user: "Created by me"
            case .workspace: "Workspace Directory"
            }
        }
    }

    struct Pagination: Decodable {
        let nextPageToken: String?
    }

    struct DirectoryPage: Decodable {
        let plugins: [DirectoryItem]
        let pagination: Pagination
    }

    struct InstalledPage: Decodable {
        let plugins: [InstalledItem]
        let pagination: Pagination
    }

    struct DirectoryItem: Decodable {
        let id: String
        let name: String
        let scope: Scope
        let discoverability: String?
        let shareUrl: String?
        let creatorAccountUserId: String?
        let creatorName: String?
        let sharePrincipals: [CodexRemotePluginSharePrincipal]?
        let canPublishToWorkspace: Bool?
        let installationPolicy: String
        let installationPolicySource: String?
        let mustShowInstallationInterstitial: Bool?
        let authenticationPolicy: String
        let status: String?
        let release: Release
    }

    struct InstalledItem: Decodable {
        let id: String
        let name: String
        let scope: Scope
        let discoverability: String?
        let shareUrl: String?
        let creatorAccountUserId: String?
        let creatorName: String?
        let sharePrincipals: [CodexRemotePluginSharePrincipal]?
        let canPublishToWorkspace: Bool?
        let installationPolicy: String
        let installationPolicySource: String?
        let mustShowInstallationInterstitial: Bool?
        let authenticationPolicy: String
        let status: String?
        let release: Release
        let enabled: Bool
        let disabledSkillNames: [String]

        var directoryItem: DirectoryItem {
            DirectoryItem(
                id: id,
                name: name,
                scope: scope,
                discoverability: discoverability,
                shareUrl: shareUrl,
                creatorAccountUserId: creatorAccountUserId,
                creatorName: creatorName,
                sharePrincipals: sharePrincipals,
                canPublishToWorkspace: canPublishToWorkspace,
                installationPolicy: installationPolicy,
                installationPolicySource: installationPolicySource,
                mustShowInstallationInterstitial:
                    mustShowInstallationInterstitial,
                authenticationPolicy: authenticationPolicy,
                status: status,
                release: release
            )
        }
    }

    struct Release: Decodable {
        let version: String?
        let displayName: String
        let description: String
        let bundleDownloadUrl: String?
        let appIds: [String]
        let appManifest: CodexJSONValue?
        let appTemplates: [CodexJSONValue]
        let keywords: [String]
        let interface: CodexJSONValue?
        let skills: [Skill]
        let mcpServers: [MCPServer]
        let scheduledTasks: [CodexJSONValue]?

        init(from decoder: any Decoder) throws {
            let values = try decoder.container(
                keyedBy: DynamicCodingKey.self
            )
            version = try values.decodeIfPresent(
                String.self, forKey: "version"
            )
            displayName = try values.decode(
                String.self, forKey: "displayName"
            )
            description = try values.decode(
                String.self, forKey: "description"
            )
            bundleDownloadUrl = try values.decodeIfPresent(
                String.self, forKey: "bundleDownloadUrl"
            )
            appIds = try values.decodeIfPresent(
                [String].self, forKey: "appIds"
            ) ?? []
            appManifest = try values.decodeIfPresent(
                CodexJSONValue.self, forKey: "appManifest"
            )
            appTemplates = try values.decodeIfPresent(
                [CodexJSONValue].self, forKey: "appTemplates"
            ) ?? []
            keywords = try values.decodeIfPresent(
                [String].self, forKey: "keywords"
            ) ?? []
            interface = try values.decodeIfPresent(
                CodexJSONValue.self, forKey: "interface"
            )
            skills = try values.decodeIfPresent(
                [Skill].self, forKey: "skills"
            ) ?? []
            mcpServers = try values.decodeIfPresent(
                [MCPServer].self, forKey: "mcpServers"
            ) ?? []
            scheduledTasks = try values.decodeIfPresent(
                [CodexJSONValue].self, forKey: "scheduledTasks"
            )
        }
    }

    struct Skill: Decodable {
        let name: String
        let description: String
        let interface: CodexJSONValue?
    }

    struct MCPServer: Decodable {
        let key: String
    }

    struct RecommendedResponse: Decodable {
        let enabled: Bool?
        let plugins: [RecommendedItem]
    }

    struct RecommendedItem: Decodable {
        let id: String
        let name: String
        let status: String?
        let installationPolicy: String?
    }

    struct MutationResponse: Decodable {
        let id: String
        let enabled: Bool
        let appIdsNeedingAuth: [String]?
    }

    struct SkillDetailResponse: Decodable {
        let pluginId: String
        let name: String
        let skillMdContents: String?
    }

    struct ShareUpdateRequest: Encodable {
        let discoverability: String
        let targets: [CodexRemotePluginShareTarget]
    }

    struct ShareUpdateResponse: Decodable {
        let principals: [CodexRemotePluginSharePrincipal]
        let discoverability: String
    }

    struct WorkspaceUploadURLRequest: Encodable {
        let filename: String
        let mimeType: String
        let sizeBytes: Int
        let pluginID: String?
    }

    struct WorkspaceUploadURLResponse: Decodable {
        let fileId: String
        let uploadUrl: String
        let etag: String?
    }

    struct WorkspaceFinalizeRequest: Encodable {
        let fileID: String
        let etag: String
        let discoverability: String?
        let shareTargets: [CodexRemotePluginShareTarget]?
    }

    struct WorkspaceFinalizeResponse: Decodable {
        let pluginId: String
        let shareUrl: String?
        let canPublishToWorkspace: Bool?
    }

    struct DynamicCodingKey: CodingKey {
        var stringValue: String
        var intValue: Int?

        init?(stringValue: String) {
            self.stringValue = stringValue
        }

        init?(intValue: Int) {
            stringValue = String(intValue)
            self.intValue = intValue
        }

        init(_ value: String) {
            stringValue = value
        }
    }
}

private extension KeyedDecodingContainer
where Key == CodexRemotePluginService.DynamicCodingKey {
    func decode<T: Decodable>(
        _ type: T.Type,
        forKey key: String
    ) throws -> T {
        try decode(type, forKey: .init(key))
    }

    func decodeIfPresent<T: Decodable>(
        _ type: T.Type,
        forKey key: String
    ) throws -> T? {
        try decodeIfPresent(type, forKey: .init(key))
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

private extension JSONEncoder {
    static var remotePluginEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return encoder
    }
}
