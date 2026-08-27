import Foundation
import Testing

@testable import CodexPadApplication

private func makeLocalPluginMarketplace(
    root: URL,
    marketplaceName: String = "local-tools",
    pluginName: String = "calendar"
) throws -> (marketplace: URL, plugin: URL) {
    let plugin = root.appendingPathComponent(
        pluginName,
        isDirectory: true
    )
    let manifestDirectory = plugin.appendingPathComponent(
        ".codex-plugin",
        isDirectory: true
    )
    try FileManager.default.createDirectory(
        at: manifestDirectory,
        withIntermediateDirectories: true
    )
    let manifest: [String: Any] = [
        "name": pluginName,
        "version": "1.2.3",
        "description": "Calendar integration",
        "keywords": ["calendar", "events"],
    ]
    try JSONSerialization.data(
        withJSONObject: manifest,
        options: [.prettyPrinted]
    ).write(
        to: manifestDirectory.appendingPathComponent("plugin.json")
    )
    let marketplace = root.appendingPathComponent("marketplace.json")
    let catalog: [String: Any] = [
        "name": marketplaceName,
        "plugins": [
            [
                "name": pluginName,
                "source": [
                    "source": "local",
                    "path": pluginName,
                ],
                "policy": [
                    "installation": "AVAILABLE",
                    "authentication": "ON_USE",
                ],
            ],
        ],
    ]
    try JSONSerialization.data(
        withJSONObject: catalog,
        options: [.prettyPrinted]
    ).write(to: marketplace)
    return (marketplace, plugin)
}

private func writePluginSkill(
    root: URL,
    directory: String,
    frontmatter: String
) throws {
    let folder = root.appendingPathComponent(
        directory,
        isDirectory: true
    )
    try FileManager.default.createDirectory(
        at: folder,
        withIntermediateDirectories: true
    )
    try frontmatter.write(
        to: folder.appendingPathComponent("SKILL.md"),
        atomically: true,
        encoding: .utf8
    )
}

@Test @MainActor
func pluginCatalogListsAndReadsRealLocalMarketplace() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(
        at: root,
        withIntermediateDirectories: true
    )
    let fixture = try makeLocalPluginMarketplace(root: root)
    try writePluginSkill(
        root: fixture.plugin.appendingPathComponent(
            "skills",
            isDirectory: true
        ),
        directory: "events",
        frontmatter:
            "---\nname: events\ndescription: Manage events\n---"
    )
    let hooksPath = fixture.plugin.appendingPathComponent(
        "hooks/hooks.json"
    )
    try FileManager.default.createDirectory(
        at: hooksPath.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try Data(
        #"""
        {
          "hooks": {
            "PreToolUse": [
              {
                "matcher": "calendar",
                "hooks": [
                  {
                    "type": "command",
                    "command": "calendar-check"
                  }
                ]
              }
            ]
          }
        }
        """#.utf8
    ).write(to: hooksPath)
    let service = CodexPluginCatalogService(
        marketplacePaths: [fixture.marketplace],
        cacheRoot: root.appendingPathComponent("cache")
    )

    let response = service.list()
    #expect(response.marketplaceLoadErrors.isEmpty)
    #expect(response.marketplaces.count == 1)
    #expect(response.marketplaces[0].name == "local-tools")
    #expect(response.marketplaces[0].plugins.count == 1)
    #expect(response.marketplaces[0].plugins[0].id == "calendar@local-tools")
    #expect(response.marketplaces[0].plugins[0].sourcePath == fixture.plugin.path)
    #expect(response.marketplaces[0].plugins[0].installed == false)
    #expect(response.marketplaces[0].plugins[0].authPolicy == "ON_USE")

    let detail = try service.read(
        marketplacePath: fixture.marketplace.path,
        pluginName: "calendar"
    )
    #expect(detail.marketplaceName == "local-tools")
    #expect(detail.summary.name == "calendar")
    #expect(detail.summary.version == "1.2.3")
    #expect(detail.description == "Calendar integration")
    #expect(detail.summary.keywords == ["calendar", "events"])
    #expect(detail.skillNames == ["events"])
    #expect(
        detail.hookKeys == [
            "calendar@local-tools:hooks/hooks.json:pre_tool_use:0:0",
        ]
    )
}

@Test @MainActor
func pluginCatalogInstallsAndUninstallsTransactionalLocalCopy() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(
        at: root,
        withIntermediateDirectories: true
    )
    let fixture = try makeLocalPluginMarketplace(root: root)
    let cache = root.appendingPathComponent("cache", isDirectory: true)
    let service = CodexPluginCatalogService(
        marketplacePaths: [fixture.marketplace],
        cacheRoot: cache
    )

    let result = try service.install(
        marketplacePath: fixture.marketplace.path,
        pluginName: "calendar"
    )
    #expect(result.authPolicy == "ON_USE")
    #expect(result.appsNeedingAuth.isEmpty)
    let installed = cache
        .appendingPathComponent("local-tools/calendar/1.2.3")
    #expect(
        FileManager.default.fileExists(
            atPath: installed.appendingPathComponent(
                ".codex-plugin/plugin.json"
            ).path
        )
    )
    #expect(service.list().marketplaces[0].plugins[0].installed)

    try service.uninstall(pluginID: "calendar@local-tools")
    #expect(!FileManager.default.fileExists(atPath: installed.path))
    #expect(service.list().marketplaces[0].plugins[0].installed == false)
}

@Test @MainActor
func pluginCatalogDerivesInstalledComponentsFromCachedManifest() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(
        at: root,
        withIntermediateDirectories: true
    )
    let fixture = try makeLocalPluginMarketplace(root: root)
    let manifest = fixture.plugin
        .appendingPathComponent(".codex-plugin/plugin.json")
    let manifestObject: [String: Any] = [
        "name": "calendar",
        "version": "1.2.3+build.7",
        "skills": "./capabilities/",
        "hooks": ["./runtime/pre-tool.json"],
    ]
    try JSONSerialization.data(
        withJSONObject: manifestObject,
        options: [.sortedKeys]
    ).write(to: manifest)
    try writePluginSkill(
        root: fixture.plugin.appendingPathComponent("capabilities"),
        directory: "events",
        frontmatter:
            "---\nname: events\ndescription: Manage events\n---"
    )
    try writePluginSkill(
        root: fixture.plugin.appendingPathComponent("skills"),
        directory: "undeclared",
        frontmatter:
            "---\nname: undeclared\ndescription: Ignore me\n---"
    )
    let hook = fixture.plugin.appendingPathComponent(
        "runtime/pre-tool.json"
    )
    try FileManager.default.createDirectory(
        at: hook.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try Data(#"{"hooks":{}}"#.utf8).write(to: hook)
    let cache = root.appendingPathComponent("cache", isDirectory: true)
    let service = CodexPluginCatalogService(
        marketplacePaths: [fixture.marketplace],
        cacheRoot: cache
    )

    _ = try service.install(
        marketplacePath: fixture.marketplace.path,
        pluginName: "calendar"
    )
    try FileManager.default.removeItem(at: fixture.plugin)

    let component = try #require(
        service.installedComponents().first
    )
    let installed = cache.appendingPathComponent(
        "local-tools/calendar/1.2.3+build.7",
        isDirectory: true
    )
    #expect(component.pluginID == "calendar@local-tools")
    #expect(component.namespace == "calendar")
    #expect(component.version == "1.2.3+build.7")
    #expect(component.rootPath == installed.path)
    #expect(
        component.skillRootPaths == [
            installed.appendingPathComponent(
                "capabilities",
                isDirectory: true
            ).path,
        ]
    )
    #expect(
        component.hookSourcePaths == [
            installed.appendingPathComponent(
                "runtime/pre-tool.json"
            ).path,
        ]
    )

    try service.uninstall(pluginID: "calendar@local-tools")
    #expect(service.installedComponents().isEmpty)
}

@Test @MainActor
func pluginCatalogSelectsReleaseOverPrereleaseAsActiveVersion() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let cache = root.appendingPathComponent("cache", isDirectory: true)
    let plugin = cache.appendingPathComponent(
        "local-tools/calendar",
        isDirectory: true
    )
    for version in ["1.0.0-alpha", "1.0.0"] {
        let manifest = plugin
            .appendingPathComponent(version, isDirectory: true)
            .appendingPathComponent(".codex-plugin/plugin.json")
        try FileManager.default.createDirectory(
            at: manifest.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(#"{"name":"calendar"}"#.utf8).write(to: manifest)
    }
    let service = CodexPluginCatalogService(
        marketplacePaths: [],
        cacheRoot: cache
    )

    let component = try #require(service.installedComponents().first)
    #expect(component.version == "1.0.0")
}

@Test @MainActor
func pluginCatalogReportsMalformedMarketplaceWithoutSyntheticRows() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(
        at: root,
        withIntermediateDirectories: true
    )
    let marketplace = root.appendingPathComponent("marketplace.json")
    try Data("{bad-json".utf8).write(to: marketplace)
    let service = CodexPluginCatalogService(
        marketplacePaths: [marketplace],
        cacheRoot: root.appendingPathComponent("cache")
    )

    let response = service.list()
    #expect(response.marketplaces.isEmpty)
    #expect(response.marketplaceLoadErrors.count == 1)
    #expect(response.marketplaceLoadErrors[0].path == marketplace.path)
}

@Test @MainActor
func pluginCatalogDiscoversMarketplaceCreatedAfterServiceInitialization() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(
        at: root,
        withIntermediateDirectories: true
    )
    let marketplace = root.appendingPathComponent("marketplace.json")
    let service = CodexPluginCatalogService(
        marketplacePaths: [marketplace],
        cacheRoot: root.appendingPathComponent("cache")
    )

    let beforeCreation = service.list()
    #expect(beforeCreation.marketplaces.isEmpty)
    #expect(beforeCreation.marketplaceLoadErrors.isEmpty)

    _ = try makeLocalPluginMarketplace(root: root)

    let afterCreation = service.list()
    #expect(afterCreation.marketplaceLoadErrors.isEmpty)
    #expect(afterCreation.marketplaces.map(\.name) == ["local-tools"])
    #expect(
        afterCreation.marketplaces[0].plugins.map(\.name)
            == ["calendar"]
    )
}

@Test @MainActor
func pluginCatalogResolvesPersonalMarketplaceSourcesFromCodexHome() throws {
    let home = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: home) }
    let marketplaceDirectory = home
        .appendingPathComponent(".agents/plugins", isDirectory: true)
    try FileManager.default.createDirectory(
        at: marketplaceDirectory,
        withIntermediateDirectories: true
    )
    let plugin = home.appendingPathComponent(
        "plugins/calendar",
        isDirectory: true
    )
    let manifestDirectory = plugin.appendingPathComponent(
        ".codex-plugin",
        isDirectory: true
    )
    try FileManager.default.createDirectory(
        at: manifestDirectory,
        withIntermediateDirectories: true
    )
    try Data(
        #"{"name":"calendar","version":"2.0.0"}"#.utf8
    ).write(to: manifestDirectory.appendingPathComponent("plugin.json"))
    let marketplace = marketplaceDirectory
        .appendingPathComponent("marketplace.json")
    let catalog: [String: Any] = [
        "name": "codex-curated",
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
        withJSONObject: catalog,
        options: [.prettyPrinted]
    ).write(to: marketplace)
    let service = CodexPluginCatalogService(
        marketplacePaths: [marketplace],
        cacheRoot: home.appendingPathComponent("cache")
    )

    let response = service.list()
    #expect(response.marketplaceLoadErrors.isEmpty)
    #expect(response.marketplaces.count == 1)
    #expect(
        response.marketplaces[0].plugins[0].sourcePath
            == plugin.standardizedFileURL.path
    )
}
