import Foundation
import Testing

@testable import CodexPadApplication
@testable import CodexPadProtocolBridge

private actor RemotePluginTransport:
    CodexDesktopNetworkFetchTransport
{
    private var responses:
        [CodexDesktopNetworkTransportResponse]
    private(set) var requests:
        [CodexDesktopNetworkTransportRequest] = []

    init(_ payloads: [[String: Any]]) throws {
        responses = try payloads.map {
            CodexDesktopNetworkTransportResponse(
                status: 200,
                headers: [:],
                body: try JSONSerialization.data(
                    withJSONObject: $0
                )
            )
        }
    }

    init(statusPayloads: [(Int, [String: Any])]) throws {
        responses = try statusPayloads.map { status, payload in
            CodexDesktopNetworkTransportResponse(
                status: status,
                headers: [:],
                body: try JSONSerialization.data(
                    withJSONObject: payload
                )
            )
        }
    }

    init(responses: [CodexDesktopNetworkTransportResponse]) {
        self.responses = responses
    }

    func execute(
        _ request: CodexDesktopNetworkTransportRequest
    ) async throws -> CodexDesktopNetworkTransportResponse {
        requests.append(request)
        return responses.removeFirst()
    }

    func capturedRequests()
        -> [CodexDesktopNetworkTransportRequest]
    {
        requests
    }
}

@Test @MainActor
func remotePluginSearchTrimsClampsAndForwardsOfficialParameters()
    async throws
{
    let transport = try RemotePluginTransport([
        [
            "plugins": [
                remotePlugin(
                    id: "plugin_linear",
                    scope: "GLOBAL"
                ),
            ],
            "pagination": [
                "next_page_token": "next page/+",
            ],
        ],
    ])
    let service = CodexRemotePluginService(
        credentialsProvider: {
            CodexOfficialCredentials(
                accessToken: "test-token",
                accountID: "account-1"
            )
        },
        transport: transport,
        baseURL: URL(
            string: "https://chatgpt.example/backend-api"
        )!
    )

    let response = try await service.search(
        searchTerm: "  linear & docs/+  ",
        scope: "global",
        cwds: ["/workspace/project"],
        cursor: "cursor/+",
        limit: 5_000
    )

    #expect(response.data.count == 1)
    #expect(response.data[0].plugin.remotePluginID == "plugin_linear")
    #expect(
        response.data[0].marketplaceName
            == "openai-curated-remote"
    )
    #expect(response.data[0].marketplacePath == nil)
    #expect(response.nextCursor == "next page/+")

    let requests = await transport.capturedRequests()
    let request = try #require(requests.first)
    let components = try #require(
        URLComponents(url: request.url, resolvingAgainstBaseURL: false)
    )
    #expect(
        components.queryItems
            == [
                URLQueryItem(name: "q", value: "linear & docs/+"),
                URLQueryItem(name: "scope", value: "GLOBAL"),
                URLQueryItem(name: "limit", value: "1000"),
                URLQueryItem(name: "pageToken", value: "cursor/+"),
            ]
    )
    #expect(request.headers["Authorization"] == "Bearer test-token")
    #expect(request.headers["chatgpt-account-id"] == "account-1")
}

@Test @MainActor
func remotePluginSearchReturnsEmptyResponseWithoutNetworkForBlankTerm()
    async throws
{
    let transport = try RemotePluginTransport([
        [
            "plugins": [],
            "pagination": ["next_page_token": NSNull()],
        ],
    ])
    let service = CodexRemotePluginService(
        credentialsProvider: {
            CodexOfficialCredentials(
                accessToken: "test-token",
                accountID: nil
            )
        },
        transport: transport,
        baseURL: URL(
            string: "https://chatgpt.example/backend-api"
        )!
    )

    let response = try await service.search(
        searchTerm: " \n\t ",
        scope: "workspace",
        cwds: nil,
        cursor: "ignored",
        limit: nil
    )

    #expect(response.data.isEmpty)
    #expect(response.nextCursor == nil)
    #expect((await transport.capturedRequests()).isEmpty)
}

@Test @MainActor
func remotePluginShareSaveUploadsFinalizesAndRecordsLocalPath()
    async throws
{
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory.appendingPathComponent(
        "codex-share-save-\(UUID().uuidString)",
        isDirectory: true
    )
    defer { try? fileManager.removeItem(at: root) }
    let plugin = root.appendingPathComponent(
        "calendar-plugin",
        isDirectory: true
    )
    try fileManager.createDirectory(
        at: plugin,
        withIntermediateDirectories: true
    )
    try Data("# Calendar".utf8).write(
        to: plugin.appendingPathComponent("SKILL.md")
    )
    func jsonResponse(
        _ status: Int,
        _ object: [String: Any]
    ) throws -> CodexDesktopNetworkTransportResponse {
        CodexDesktopNetworkTransportResponse(
            status: status,
            headers: [:],
            body: try JSONSerialization.data(withJSONObject: object)
        )
    }
    let transport = RemotePluginTransport(responses: [
        try jsonResponse(200, [
            "file_id": "file-1",
            "upload_url": "https://blob.example/upload",
            "etag": "etag-1",
        ]),
        CodexDesktopNetworkTransportResponse(
            status: 201,
            headers: [:],
            body: Data()
        ),
        try jsonResponse(200, [
            "plugin_id": "plugin-shared-1",
            "share_url": "https://chatgpt.example/share/1",
            "can_publish_to_workspace": true,
        ]),
    ])
    let codexHome = root.appendingPathComponent("CodexHome")
    let service = CodexRemotePluginService(
        credentialsProvider: {
            CodexOfficialCredentials(
                accessToken: "test-token",
                accountID: "workspace-1"
            )
        },
        transport: transport,
        baseURL: URL(
            string: "https://chatgpt.example/backend-api"
        )!,
        codexHome: codexHome
    )

    let result = try await service.saveShare(
        pluginPath: plugin,
        discoverability: "PRIVATE",
        shareTargets: [
            CodexRemotePluginShareTarget(
                principalType: "user",
                principalID: "user-1",
                role: "reader"
            ),
        ]
    )

    #expect(result.remotePluginID == "plugin-shared-1")
    #expect(result.canPublishToWorkspace == true)
    let requests = await transport.capturedRequests()
    #expect(requests.count == 3)
    #expect(requests[0].url.path.hasSuffix(
        "/public/plugins/workspace/upload-url"
    ))
    #expect(requests[1].method == "PUT")
    #expect(requests[1].headers["Authorization"] == nil)
    #expect(requests[1].headers["x-ms-blob-type"] == "BlockBlob")
    #expect(requests[1].body?.prefix(2) == Data([0x1f, 0x8b]))
    #expect(requests[2].url.path.hasSuffix(
        "/public/plugins/workspace"
    ))
    let uploadBody = try #require(requests[0].body)
    let uploadJSON = try #require(
        JSONSerialization.jsonObject(with: uploadBody)
            as? [String: Any]
    )
    #expect(uploadJSON["filename"] as? String
        == "calendar-plugin.tar.gz")
    #expect(uploadJSON["mime_type"] as? String
        == "application/gzip")
    let saved = try CodexPluginShareLocalPathStore(
        codexHome: codexHome
    ).load()
    #expect(saved["plugin-shared-1"] == plugin.standardizedFileURL)
}

@Test @MainActor
func remotePluginShareCheckoutDownloadsExtractsAndUpdatesMarketplace()
    async throws
{
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory.appendingPathComponent(
        "codex-share-checkout-\(UUID().uuidString)",
        isDirectory: true
    )
    defer { try? fileManager.removeItem(at: root) }
    let bundleSource = root.appendingPathComponent("bundle-source")
    try fileManager.createDirectory(
        at: bundleSource,
        withIntermediateDirectories: true
    )
    try Data("# Checked out".utf8).write(
        to: bundleSource.appendingPathComponent("SKILL.md")
    )
    let bundle = try CodexPluginBundleArchiveService().packDirectory(
        at: bundleSource,
        maximumBytes: 50 * 1024 * 1024
    )
    var detail = remotePlugin(
        id: "plugin_shared_1",
        scope: "WORKSPACE",
        discoverability: "PRIVATE"
    )
    detail["share_principals"] = [[
        "principal_type": "user",
        "principal_id": "user-1",
        "role": "reader",
        "name": "Mars",
    ]]
    var release = try #require(detail["release"] as? [String: Any])
    release["bundle_download_url"] =
        "https://bundle.example/plugin.tar.gz"
    detail["release"] = release
    let transport = RemotePluginTransport(responses: [
        CodexDesktopNetworkTransportResponse(
            status: 200,
            headers: [:],
            body: try JSONSerialization.data(withJSONObject: detail)
        ),
        CodexDesktopNetworkTransportResponse(
            status: 200,
            headers: [:],
            body: try JSONSerialization.data(withJSONObject: [
                "plugins": [],
                "pagination": ["next_page_token": NSNull()],
            ])
        ),
        CodexDesktopNetworkTransportResponse(
            status: 200,
            headers: ["Content-Type": "application/gzip"],
            body: bundle
        ),
    ])
    let home = root.appendingPathComponent("home")
    let codexHome = root.appendingPathComponent("CodexHome")
    let service = CodexRemotePluginService(
        credentialsProvider: {
            CodexOfficialCredentials(
                accessToken: "test-token",
                accountID: nil
            )
        },
        transport: transport,
        baseURL: URL(
            string: "https://chatgpt.example/backend-api"
        )!,
        codexHome: codexHome,
        homeDirectory: home
    )

    let result = try await service.checkoutShare(
        remotePluginID: "plugin_shared_1"
    )

    #expect(result.pluginID == "calendar@codex-curated")
    #expect(result.marketplaceName == "codex-curated")
    #expect(
        try String(
            contentsOf: URL(fileURLWithPath: result.pluginPath)
                .appendingPathComponent("SKILL.md"),
            encoding: .utf8
        ) == "# Checked out"
    )
    let requests = await transport.capturedRequests()
    #expect(requests[2].url.absoluteString
        == "https://bundle.example/plugin.tar.gz")
    #expect(requests[2].headers["Authorization"] == nil)
    let marketplace = try JSONSerialization.jsonObject(
        with: Data(
            contentsOf: home.appendingPathComponent(
                ".agents/plugins/marketplace.json"
            )
        )
    ) as? [String: Any]
    #expect(marketplace?["name"] as? String == "codex-curated")
    let saved = try CodexPluginShareLocalPathStore(
        codexHome: codexHome
    ).load()
    #expect(saved["plugin_shared_1"]?.path
        == home.appendingPathComponent("plugins/calendar").path)
}

@Test @MainActor
func remotePluginShareCheckoutPreservesConflictingDestination()
    async throws
{
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory.appendingPathComponent(
        "codex-share-checkout-conflict-\(UUID().uuidString)",
        isDirectory: true
    )
    defer { try? fileManager.removeItem(at: root) }
    let home = root.appendingPathComponent("home")
    let destination = home.appendingPathComponent(
        "plugins/calendar",
        isDirectory: true
    )
    try fileManager.createDirectory(
        at: destination,
        withIntermediateDirectories: true
    )
    let sentinel = destination.appendingPathComponent("keep.txt")
    try Data("keep".utf8).write(to: sentinel)
    var detail = remotePlugin(
        id: "plugin_shared_conflict",
        scope: "WORKSPACE",
        discoverability: "PRIVATE"
    )
    detail["share_principals"] = [[
        "principal_type": "user",
        "principal_id": "user-1",
        "role": "reader",
    ]]
    let transport = RemotePluginTransport(responses: [
        CodexDesktopNetworkTransportResponse(
            status: 200,
            headers: [:],
            body: try JSONSerialization.data(withJSONObject: detail)
        ),
        CodexDesktopNetworkTransportResponse(
            status: 200,
            headers: [:],
            body: try JSONSerialization.data(withJSONObject: [
                "plugins": [],
                "pagination": ["next_page_token": NSNull()],
            ])
        ),
    ])
    let service = CodexRemotePluginService(
        credentialsProvider: {
            CodexOfficialCredentials(
                accessToken: "test-token",
                accountID: nil
            )
        },
        transport: transport,
        baseURL: URL(
            string: "https://chatgpt.example/backend-api"
        )!,
        codexHome: root.appendingPathComponent("CodexHome"),
        homeDirectory: home
    )

    await #expect(throws: CodexRemotePluginError.self) {
        _ = try await service.checkoutShare(
            remotePluginID: "plugin_shared_conflict"
        )
    }

    #expect(try Data(contentsOf: sentinel) == Data("keep".utf8))
    let requests = await transport.capturedRequests()
    #expect(
        requests.allSatisfy {
            $0.url.host != "bundle.example"
        }
    )
}

@Test @MainActor
func remotePluginShareCheckoutRollsBackAfterMarketplaceConflict()
    async throws
{
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory.appendingPathComponent(
        "codex-share-checkout-rollback-\(UUID().uuidString)",
        isDirectory: true
    )
    defer { try? fileManager.removeItem(at: root) }
    let source = root.appendingPathComponent("bundle-source")
    try fileManager.createDirectory(
        at: source,
        withIntermediateDirectories: true
    )
    try Data("# Rollback".utf8).write(
        to: source.appendingPathComponent("SKILL.md")
    )
    let bundle = try CodexPluginBundleArchiveService().packDirectory(
        at: source,
        maximumBytes: 50 * 1024 * 1024
    )
    var detail = remotePlugin(
        id: "plugin_shared_rollback",
        scope: "WORKSPACE",
        discoverability: "PRIVATE"
    )
    detail["share_principals"] = [[
        "principal_type": "user",
        "principal_id": "user-1",
        "role": "reader",
    ]]
    var release = try #require(detail["release"] as? [String: Any])
    release["bundle_download_url"] =
        "https://bundle.example/plugin.tar.gz"
    detail["release"] = release
    let transport = RemotePluginTransport(responses: [
        CodexDesktopNetworkTransportResponse(
            status: 200,
            headers: [:],
            body: try JSONSerialization.data(withJSONObject: detail)
        ),
        CodexDesktopNetworkTransportResponse(
            status: 200,
            headers: [:],
            body: try JSONSerialization.data(withJSONObject: [
                "plugins": [],
                "pagination": ["next_page_token": NSNull()],
            ])
        ),
        CodexDesktopNetworkTransportResponse(
            status: 200,
            headers: ["Content-Type": "application/gzip"],
            body: bundle
        ),
    ])
    let home = root.appendingPathComponent("home")
    let marketplace = home.appendingPathComponent(
        ".agents/plugins/marketplace.json"
    )
    try fileManager.createDirectory(
        at: marketplace.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    let originalMarketplace: [String: Any] = [
        "name": "codex-curated",
        "plugins": [
            [
                "name": "calendar",
                "source": [
                    "source": "local",
                    "path": "./plugins/different-calendar",
                ],
            ],
        ],
    ]
    let originalData = try JSONSerialization.data(
        withJSONObject: originalMarketplace,
        options: [.prettyPrinted, .sortedKeys]
    )
    try originalData.write(to: marketplace)
    let service = CodexRemotePluginService(
        credentialsProvider: {
            CodexOfficialCredentials(
                accessToken: "test-token",
                accountID: nil
            )
        },
        transport: transport,
        baseURL: URL(
            string: "https://chatgpt.example/backend-api"
        )!,
        codexHome: root.appendingPathComponent("CodexHome"),
        homeDirectory: home
    )

    await #expect(throws: CodexRemotePluginError.self) {
        _ = try await service.checkoutShare(
            remotePluginID: "plugin_shared_rollback"
        )
    }

    #expect(
        !fileManager.fileExists(
            atPath: home.appendingPathComponent(
                "plugins/calendar"
            ).path
        )
    )
    #expect(try Data(contentsOf: marketplace) == originalData)
}

private func remotePlugin(
    id: String = "plugin_remote_1",
    enabled: Bool? = nil,
    scope: String = "GLOBAL",
    discoverability: String? = nil,
    includeStatus: Bool = true
) -> [String: Any] {
    var plugin: [String: Any] = [
        "id": id,
        "name": "calendar",
        "scope": scope,
        "installation_policy": "AVAILABLE",
        "authentication_policy": "ON_USE",
        "release": [
            "version": "2.0.0",
            "display_name": "Calendar",
            "description": "Calendar integration",
            "app_ids": ["app_calendar"],
            "keywords": ["calendar"],
            "interface": [
                "short_description": "Manage events",
                "capabilities": ["events"],
                "screenshot_urls": [],
            ],
            "skills": [],
            "mcp_servers": [],
        ],
    ]
    if includeStatus {
        plugin["status"] = "AVAILABLE"
    }
    if let discoverability {
        plugin["discoverability"] = discoverability
    }
    if let enabled {
        plugin["enabled"] = enabled
        plugin["disabled_skill_names"] = []
    }
    return plugin
}

@Test @MainActor
func remotePluginServicePaginatesAndDefaultsMissingAvailability()
    async throws
{
    let transport = try RemotePluginTransport([
        [
            "plugins": [
                remotePlugin(
                    id: "plugin_remote_1",
                    includeStatus: false
                ),
            ],
            "pagination": ["next_page_token": "next-2"],
        ],
        [
            "plugins": [remotePlugin(id: "plugin_remote_2")],
            "pagination": ["next_page_token": NSNull()],
        ],
        [
            "plugins": [],
            "pagination": ["next_page_token": NSNull()],
        ],
        ["enabled": false, "plugins": []],
    ])
    let service = CodexRemotePluginService(
        credentialsProvider: {
            CodexOfficialCredentials(
                accessToken: "test-token",
                accountID: nil
            )
        },
        transport: transport,
        baseURL: URL(
            string: "https://chatgpt.example/backend-api"
        )!
    )

    let response = try await service.list(
        marketplaceKinds: ["global"],
        forceRefetch: true
    )

    #expect(response.marketplaces[0].plugins.count == 2)
    #expect(
        response.marketplaces[0].plugins
            .first { $0.remotePluginID == "plugin_remote_1" }?
            .availability == "AVAILABLE"
    )
    let requests = await transport.capturedRequests()
    #expect(
        requests[1].url.absoluteString.contains(
            "pageToken=next-2"
        )
    )
}

@Test @MainActor
func remotePluginServiceMatchesOfficialSharedMarketplaceBuckets()
    async throws
{
    let directlyPrivate = remotePlugin(
        id: "plugin_private",
        scope: "WORKSPACE",
        discoverability: "PRIVATE"
    )
    let directlyUnlisted = remotePlugin(
        id: "plugin_direct_unlisted",
        scope: "WORKSPACE",
        discoverability: "UNLISTED"
    )
    let linkInstalled = remotePlugin(
        id: "plugin_link_unlisted",
        enabled: true,
        scope: "WORKSPACE",
        discoverability: "UNLISTED"
    )
    let transport = try RemotePluginTransport([
        [
            "plugins": [directlyPrivate, directlyUnlisted],
            "pagination": ["next_page_token": NSNull()],
        ],
        [
            "plugins": [
                remotePlugin(
                    id: "plugin_private",
                    enabled: true,
                    scope: "WORKSPACE",
                    discoverability: "PRIVATE"
                ),
                linkInstalled,
            ],
            "pagination": ["next_page_token": NSNull()],
        ],
        ["enabled": false, "plugins": []],
    ])
    let service = CodexRemotePluginService(
        credentialsProvider: {
            CodexOfficialCredentials(
                accessToken: "test-token",
                accountID: nil
            )
        },
        transport: transport,
        baseURL: URL(
            string: "https://chatgpt.example/backend-api"
        )!
    )

    let response = try await service.list(
        marketplaceKinds: ["shared-with-me"],
        forceRefetch: true
    )

    #expect(response.marketplaces.map(\.name) == [
        "workspace-shared-with-me-private",
        "workspace-shared-with-me-unlisted",
    ])
    #expect(response.marketplaces[0].plugins.count == 2)
    #expect(
        response.marketplaces[0].plugins.allSatisfy {
            $0.id.hasSuffix("@workspace-shared-with-me")
        }
    )
    #expect(
        response.marketplaces[1].plugins.map(\.remotePluginID)
            == ["plugin_link_unlisted"]
    )
}

@Test @MainActor
func remotePluginServiceResolvesConfigIDForUninstall()
    async throws
{
    let transport = try RemotePluginTransport([
        [
            "plugins": [remotePlugin()],
            "pagination": ["next_page_token": NSNull()],
        ],
        [
            "plugins": [remotePlugin(enabled: true)],
            "pagination": ["next_page_token": NSNull()],
        ],
        ["enabled": false, "plugins": []],
        [
            "id": "plugin_remote_1",
            "enabled": false,
        ],
    ])
    let service = CodexRemotePluginService(
        credentialsProvider: {
            CodexOfficialCredentials(
                accessToken: "test-token",
                accountID: nil
            )
        },
        transport: transport,
        baseURL: URL(
            string: "https://chatgpt.example/backend-api"
        )!
    )
    _ = try await service.list(
        marketplaceKinds: ["global"],
        forceRefetch: true
    )

    try await service.uninstall(
        pluginID: "calendar@openai-curated-remote"
    )

    let requests = await transport.capturedRequests()
    #expect(
        requests.last?.url.absoluteString.hasSuffix(
            "/ps/plugins/plugin_remote_1/uninstall"
        ) == true
    )
}

@Test @MainActor
func remotePluginServiceLoadsDetailBeforeDirectInstall()
    async throws
{
    let transport = try RemotePluginTransport([
        remotePlugin(),
        [
            "id": "plugin_remote_1",
            "enabled": true,
        ],
    ])
    let service = CodexRemotePluginService(
        credentialsProvider: {
            CodexOfficialCredentials(
                accessToken: "test-token",
                accountID: nil
            )
        },
        transport: transport,
        baseURL: URL(
            string: "https://chatgpt.example/backend-api"
        )!
    )

    let result = try await service.install(
        marketplaceName: "openai-curated-remote",
        remotePluginID: "plugin_remote_1"
    )

    #expect(result.authPolicy == "ON_USE")
    let requests = await transport.capturedRequests()
    #expect(requests.count == 2)
    #expect(requests[0].method == "GET")
    #expect(requests[1].method == "POST")
}

@Test @MainActor
func remotePluginServiceUpdatesShareTargetsWithWorkspaceReader()
    async throws
{
    let transport = try RemotePluginTransport([
        [
            "principals": [
                [
                    "principal_type": "workspace",
                    "principal_id": "workspace-1",
                    "role": "reader",
                    "name": "Workspace",
                ],
            ],
            "discoverability": "UNLISTED",
        ],
    ])
    let service = CodexRemotePluginService(
        credentialsProvider: {
            CodexOfficialCredentials(
                accessToken: "test-token",
                accountID: "workspace-1"
            )
        },
        transport: transport,
        baseURL: URL(
            string: "https://chatgpt.example/backend-api"
        )!
    )

    let response = try await service.updateShareTargets(
        remotePluginID: "plugin_remote_1",
        discoverability: "UNLISTED",
        shareTargets: []
    )

    #expect(response.discoverability == "UNLISTED")
    #expect(response.principals[0].principalID == "workspace-1")
    let request = try #require(
        await transport.capturedRequests().first
    )
    #expect(request.method == "PUT")
    let body = try #require(request.body)
    let object = try #require(
        JSONSerialization.jsonObject(with: body)
            as? [String: Any]
    )
    let targets = try #require(
        object["targets"] as? [[String: Any]]
    )
    #expect(targets.count == 1)
    #expect(targets[0]["principal_type"] as? String == "workspace")
    #expect(targets[0]["principal_id"] as? String == "workspace-1")
}

@Test @MainActor
func remotePluginServiceListsAndDeletesOwnedShares()
    async throws
{
    var owned = remotePlugin(
        id: "plugin_owned",
        scope: "WORKSPACE",
        discoverability: "PRIVATE"
    )
    owned["share_url"] = "https://chatgpt.example/g/g-plugin"
    owned["creator_name"] = "Mars"
    owned["share_principals"] = [
        [
            "principal_type": "user",
            "principal_id": "user-1",
            "role": "owner",
            "name": "Mars",
        ],
    ]
    let transport = try RemotePluginTransport(statusPayloads: [
        (
            200,
            [
                "plugins": [owned],
                "pagination": ["next_page_token": NSNull()],
            ]
        ),
        (
            200,
            [
                "plugins": [],
                "pagination": ["next_page_token": NSNull()],
            ]
        ),
        (204, [:]),
    ])
    let service = CodexRemotePluginService(
        credentialsProvider: {
            CodexOfficialCredentials(
                accessToken: "test-token",
                accountID: "workspace-1"
            )
        },
        transport: transport,
        baseURL: URL(
            string: "https://chatgpt.example/backend-api"
        )!
    )

    let shares = try await service.listShares()
    #expect(shares.count == 1)
    #expect(shares[0].plugin.shareContext?.creatorName == "Mars")
    #expect(
        shares[0].plugin.shareContext?.sharePrincipals?.first?.role
            == "owner"
    )
    try await service.deleteShare(remotePluginID: "plugin_owned")

    let requests = await transport.capturedRequests()
    #expect(
        requests[0].url.absoluteString.contains(
            "/ps/plugins/workspace/created?limit=200"
        )
    )
    #expect(requests.last?.method == "DELETE")
}

@Test @MainActor
func remotePluginServiceFetchesOfficialPagedCatalogAndInstalledState()
    async throws
{
    let transport = try RemotePluginTransport([
        [
            "plugins": [remotePlugin()],
            "pagination": ["next_page_token": NSNull()],
        ],
        [
            "plugins": [remotePlugin(enabled: true)],
            "pagination": ["next_page_token": NSNull()],
        ],
        [
            "enabled": true,
            "plugins": [
                [
                    "id": "plugin_remote_1",
                    "name": "calendar",
                    "release": [
                        "display_name": "Calendar",
                        "app_ids": ["app_calendar"],
                    ],
                ],
            ],
        ],
    ])
    let service = CodexRemotePluginService(
        credentialsProvider: {
            CodexOfficialCredentials(
                accessToken: "test-token",
                accountID: "account-1"
            )
        },
        transport: transport,
        baseURL: URL(
            string: "https://chatgpt.example/backend-api"
        )!
    )

    let response = try await service.list(
        marketplaceKinds: ["vertical"],
        forceRefetch: true
    )

    #expect(response.marketplaces.count == 1)
    #expect(response.marketplaces[0].name == "openai-curated-remote")
    #expect(response.marketplaces[0].plugins[0].remotePluginID == "plugin_remote_1")
    #expect(response.marketplaces[0].plugins[0].installed)
    #expect(response.marketplaces[0].plugins[0].enabled)
    #expect(response.featuredPluginIDs == ["plugin_remote_1"])
    let requests = await transport.capturedRequests()
    #expect(requests.count == 3)
    #expect(
        requests[0].url.absoluteString.contains(
            "/ps/plugins/list?scope=GLOBAL"
        )
    )
    #expect(
        requests[0].url.absoluteString.contains(
            "collection=vertical"
        )
    )
    #expect(
        requests[1].url.absoluteString.contains(
            "/ps/plugins/installed?scope=GLOBAL"
        )
    )
    #expect(
        requests[0].headers["Authorization"]
            == "Bearer test-token"
    )
    #expect(
        requests[0].headers["chatgpt-account-id"]
            == "account-1"
    )
    #expect(requests[0].headers["OAI-Product-Sku"] == "codex")
}

@Test @MainActor
func remotePluginServiceReadsInstallsAndUninstallsOfficialPlugin()
    async throws
{
    let transport = try RemotePluginTransport([
        remotePlugin(),
        [
            "plugins": [],
            "pagination": ["next_page_token": NSNull()],
        ],
        [
            "id": "plugin_remote_1",
            "enabled": true,
            "app_ids_needing_auth": ["app_calendar"],
        ],
        [
            "id": "plugin_remote_1",
            "enabled": false,
        ],
    ])
    let service = CodexRemotePluginService(
        credentialsProvider: {
            CodexOfficialCredentials(
                accessToken: "test-token",
                accountID: nil
            )
        },
        transport: transport,
        baseURL: URL(
            string: "https://chatgpt.example/backend-api"
        )!
    )

    let detail = try await service.read(
        marketplaceName: "openai-curated-remote",
        remotePluginID: "plugin_remote_1"
    )
    #expect(detail.summary.remotePluginID == "plugin_remote_1")
    #expect(detail.description == "Calendar integration")

    let install = try await service.install(
        marketplaceName: "openai-curated-remote",
        remotePluginID: "plugin_remote_1"
    )
    #expect(install.authPolicy == "ON_USE")
    #expect(install.appsNeedingAuth == ["app_calendar"])
    try await service.uninstall(
        remotePluginID: "plugin_remote_1"
    )

    let requests = await transport.capturedRequests()
    #expect(
        requests[0].url.absoluteString.hasSuffix(
            "/ps/plugins/plugin_remote_1"
        )
    )
    #expect(
        requests[2].url.absoluteString.contains(
            "/ps/plugins/plugin_remote_1/install?includeAppsNeedingAuth=true"
        )
    )
    #expect(
        requests[3].url.absoluteString.hasSuffix(
            "/ps/plugins/plugin_remote_1/uninstall"
        )
    )
}
