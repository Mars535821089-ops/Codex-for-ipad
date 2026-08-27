import Foundation
import Testing

@testable import CodexPadApplication
@testable import CodexPadDomain
@testable import CodexPadProtocolBridge

private func marketplaceFixture(
    at root: URL,
    name: String = "calendar-tools",
    marker: String = "local"
) throws {
    let manifest = root.appendingPathComponent(
        ".agents/plugins/marketplace.json"
    )
    let plugin = root.appendingPathComponent(
        "plugins/calendar",
        isDirectory: true
    )
    try FileManager.default.createDirectory(
        at: manifest.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
        at: plugin,
        withIntermediateDirectories: true
    )
    try Data(marker.utf8).write(
        to: plugin.appendingPathComponent("marker.txt")
    )
    let pluginManifest = plugin.appendingPathComponent(
        ".codex-plugin/plugin.json"
    )
    try FileManager.default.createDirectory(
        at: pluginManifest.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try JSONSerialization.data(
        withJSONObject: [
            "name": "calendar",
            "version": "1.0.0",
            "description": "Calendar tools",
        ],
        options: [.sortedKeys]
    ).write(to: pluginManifest)
    let object: [String: Any] = [
        "name": name,
        "plugins": [
            [
                "name": "calendar",
                "source": [
                    "source": "local",
                    "path": "./plugins/calendar",
                ],
            ],
        ],
    ]
    try JSONSerialization.data(
        withJSONObject: object,
        options: [.sortedKeys]
    ).write(to: manifest)
}

private actor MarketplaceGitInstallerProbe:
    CodexMarketplaceGitInstalling
{
    struct Release: Sendable {
        let revision: String
        let marker: String
    }

    private var releases: [Release]
    private var invocations = 0

    init(_ releases: [Release]) {
        self.releases = releases
    }

    func install(
        source _: String,
        refName _: String?,
        sparsePaths _: [String],
        destination: URL
    ) async throws -> String {
        let index = min(invocations, releases.count - 1)
        let release = releases[index]
        invocations += 1
        try marketplaceFixture(
            at: destination,
            marker: release.marker
        )
        return release.revision
    }

    func callCount() -> Int { invocations }
}

@Test @MainActor
func marketplaceManagerAddsListsAndRemovesLocalSource() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(
            "codex-marketplace-local-\(UUID().uuidString)",
            isDirectory: true
        )
    let home = root.appendingPathComponent("home", isDirectory: true)
    let source = root.appendingPathComponent(
        "source",
        isDirectory: true
    )
    let suite = "CodexMarketplaceLocal.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }
    try marketplaceFixture(at: source)
    let config = CodexDesktopConfigStore(
        userDefaults: defaults,
        storageKey: "config"
    )
    let manager = CodexMarketplaceManagementService(
        codexHome: home,
        configStore: config
    )

    let added = try await manager.addMarketplace(
        source: source.path,
        refName: nil,
        sparsePaths: []
    )
    #expect(
        added == CodexMarketplaceAddResult(
            marketplaceName: "calendar-tools",
            installedRoot: source.path,
            alreadyAdded: false
        )
    )
    let duplicate = try await manager.addMarketplace(
        source: source.path,
        refName: nil,
        sparsePaths: []
    )
    #expect(duplicate.alreadyAdded)
    #expect(
        manager.configuredMarketplaceManifestPaths()
            == [
                source.appendingPathComponent(
                    ".agents/plugins/marketplace.json"
                )
            ]
    )
    let catalog = CodexPluginCatalogService(
        marketplacePaths: [],
        additionalMarketplacePaths: {
            manager.configuredMarketplaceManifestPaths()
        },
        cacheRoot: home.appendingPathComponent("cache")
    )
    #expect(
        catalog.list().marketplaces.first?.plugins.first?.name
            == "calendar"
    )

    let removed = try manager.removeMarketplace(
        named: "calendar-tools"
    )
    #expect(removed.installedRoot == nil)
    #expect(FileManager.default.fileExists(atPath: source.path))
    #expect(manager.configuredMarketplaceManifestPaths().isEmpty)
}

@Test @MainActor
func marketplaceManagerInstallsUpgradesAndRemovesGitSource()
    async throws
{
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(
            "codex-marketplace-git-\(UUID().uuidString)",
            isDirectory: true
        )
    let suite = "CodexMarketplaceGit.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }
    let installer = MarketplaceGitInstallerProbe([
        .init(revision: "revision-1", marker: "one"),
        .init(revision: "revision-2", marker: "two"),
    ])
    let manager = CodexMarketplaceManagementService(
        codexHome: root,
        configStore: CodexDesktopConfigStore(
            userDefaults: defaults,
            storageKey: "config"
        ),
        gitInstaller: installer
    )

    let added = try await manager.addMarketplace(
        source: "owner/repository",
        refName: "main",
        sparsePaths: []
    )
    #expect(added.marketplaceName == "calendar-tools")
    #expect(added.alreadyAdded == false)
    #expect(
        try String(
            contentsOf: URL(fileURLWithPath: added.installedRoot)
                .appendingPathComponent(
                    "plugins/calendar/marker.txt"
                ),
            encoding: .utf8
        ) == "one"
    )

    let upgraded = await manager.upgradeMarketplaces(
        named: nil
    )
    #expect(upgraded.selectedMarketplaces == ["calendar-tools"])
    #expect(upgraded.upgradedRoots == [added.installedRoot])
    #expect(upgraded.errors.isEmpty)
    #expect(
        try String(
            contentsOf: URL(fileURLWithPath: added.installedRoot)
                .appendingPathComponent(
                    "plugins/calendar/marker.txt"
                ),
            encoding: .utf8
        ) == "two"
    )
    #expect(await installer.callCount() == 2)

    let removed = try manager.removeMarketplace(
        named: "calendar-tools"
    )
    #expect(removed.installedRoot == added.installedRoot)
    #expect(
        !FileManager.default.fileExists(
            atPath: added.installedRoot
        )
    )
}

@Test @MainActor
func desktopInitialMCPRouterServesMarketplaceLifecycle()
    async throws
{
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(
            "codex-marketplace-router-\(UUID().uuidString)",
            isDirectory: true
        )
    let source = root.appendingPathComponent(
        "source",
        isDirectory: true
    )
    let suite = "CodexMarketplaceRouter.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }
    try marketplaceFixture(at: source)
    let manager = CodexMarketplaceManagementService(
        codexHome: root.appendingPathComponent("home"),
        configStore: CodexDesktopConfigStore(
            userDefaults: defaults,
            storageKey: "config"
        )
    )
    let request = CodexDesktopMCPRequest(
        request: CodexDesktopMCPRequestMessage(
            id: .integer(401),
            method: "marketplace/add",
            params: .object([
                "source": .string(source.path),
                "refName": .null,
                "sparsePaths": .null,
            ]),
            metadata: [:]
        ),
        hostID: "desktop-host-1",
        dispatchedAtMs: nil,
        priority: nil,
        source: nil,
        timeoutMs: nil,
        expiresAtMs: nil,
        metadata: [:]
    )
    let response = await CodexDesktopInitialMCPRouter
        .responseIncludingFileSystem(
            to: request,
            state: CodexDesktopInitialMCPState(
                account: CodexDesktopMCPAccountState(
                    account: nil,
                    authMethod: nil,
                    requiresOpenAIAuth: false
                ),
                config: CodexDesktopMCPConfigState(
                    config: [:],
                    origins: [:],
                    layers: []
                ),
                remoteControl:
                    CodexDesktopMCPRemoteControlState(
                        status: .disabled,
                        serverName: "Codex-for-iPad",
                        installationID: "installation-1",
                        environmentID: nil
                    )
            ),
            allowedFileSystemRoots: [],
            marketplaceManager: manager
        )
    guard case let .mcpResponse(_, .object(envelope), _) = response,
          case let .object(result)? = envelope["result"]
    else {
        Issue.record("missing marketplace/add result")
        return
    }
    #expect(result["marketplaceName"] == .string("calendar-tools"))
    #expect(result["installedRoot"] == .string(source.path))
    #expect(result["alreadyAdded"] == .bool(false))
}
