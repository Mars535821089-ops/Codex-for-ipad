import Foundation
import Testing

@testable import CodexPadApplication

private func writeSkill(
    root: URL,
    directory: String,
    frontmatter: String
) throws -> URL {
    let folder = root.appendingPathComponent(
        directory,
        isDirectory: true
    )
    try FileManager.default.createDirectory(
        at: folder,
        withIntermediateDirectories: true
    )
    let file = folder.appendingPathComponent("SKILL.md")
    try frontmatter.write(
        to: file,
        atomically: true,
        encoding: .utf8
    )
    return file
}

@Test @MainActor
func skillCatalogListsRealSkillFilesWithOfficialMetadata() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let path = try writeSkill(
        root: root,
        directory: "calendar",
        frontmatter: """
        ---
        name: calendar
        description: Manage calendar events
        short-description: Calendar tools
        ---
        # Calendar
        """
    )
    let service = CodexSkillCatalogService(
        userRoots: [root],
        systemRoots: []
    )

    let response = try service.list(
        cwds: [root.path],
        forceReload: false
    )

    #expect(response.count == 1)
    #expect(response[0].cwd == root.path)
    #expect(response[0].errors.isEmpty)
    #expect(response[0].skills.count == 1)
    #expect(response[0].skills[0].name == "calendar")
    #expect(
        response[0].skills[0].description
            == "Manage calendar events"
    )
    #expect(response[0].skills[0].shortDescription == "Calendar tools")
    #expect(response[0].skills[0].path == path.path)
    #expect(response[0].skills[0].scope == .user)
    #expect(response[0].skills[0].enabled)
}

@Test @MainActor
func skillCatalogReplacesExtraRootsAndPersistsPathEnablement() throws {
    let first = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let second = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer {
        try? FileManager.default.removeItem(at: first)
        try? FileManager.default.removeItem(at: second)
    }
    _ = try writeSkill(
        root: first,
        directory: "one",
        frontmatter: "---\nname: one\ndescription: First\n---"
    )
    let secondPath = try writeSkill(
        root: second,
        directory: "two",
        frontmatter: "---\nname: two\ndescription: Second\n---"
    )
    let defaults = UserDefaults(
        suiteName: "skill-catalog-\(UUID().uuidString)"
    )!
    let service = CodexSkillCatalogService(
        userRoots: [],
        systemRoots: [],
        userDefaults: defaults
    )

    service.setExtraRoots([first.path])
    #expect(
        try service.list(cwds: [first.path], forceReload: false)[0]
            .skills.map(\.name) == ["one"]
    )
    service.setExtraRoots([second.path])
    #expect(
        try service.list(cwds: [second.path], forceReload: true)[0]
            .skills.map(\.name) == ["two"]
    )
    let effective = try service.setEnabled(
        path: secondPath.path,
        name: nil,
        enabled: false
    )
    #expect(!effective)

    let restored = CodexSkillCatalogService(
        userRoots: [],
        systemRoots: [],
        userDefaults: defaults
    )
    restored.setExtraRoots([second.path])
    #expect(
        try restored.list(cwds: [second.path], forceReload: false)[0]
            .skills.first?.enabled == false
    )
}

@Test @MainActor
func skillCatalogReportsMalformedSkillWithoutInventingMetadata() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    _ = try writeSkill(
        root: root,
        directory: "broken",
        frontmatter: "# Missing frontmatter"
    )
    let service = CodexSkillCatalogService(
        userRoots: [root],
        systemRoots: []
    )

    let response = try service.list(cwds: [root.path], forceReload: false)
    #expect(response[0].skills.isEmpty)
    #expect(response[0].errors.count == 1)
    #expect(response[0].errors[0].message.contains("frontmatter"))
}

@Test @MainActor
func skillCatalogDiscoversInstalledManifestRootsAndNamespacesSkills()
    throws
{
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let cache = root.appendingPathComponent("plugins/cache")
    let workspace = root.appendingPathComponent(
        "workspace",
        isDirectory: true
    )
    try FileManager.default.createDirectory(
        at: workspace,
        withIntermediateDirectories: true
    )
    let service = CodexSkillCatalogService(
        userRoots: [],
        systemRoots: []
    )
    service.setPluginCacheRoots([cache.path])
    #expect(
        try service.list(
            cwds: [workspace.path],
            forceReload: false
        )[0].skills.isEmpty
    )

    let plugin = cache.appendingPathComponent(
        "curated/calendar-tools/local",
        isDirectory: true
    )
    let manifest = plugin.appendingPathComponent(
        ".codex-plugin/plugin.json"
    )
    try FileManager.default.createDirectory(
        at: manifest.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try Data(
        #"{"name":"calendar-tools","skills":"./capabilities/"}"#.utf8
    ).write(to: manifest)
    let skillPath = try writeSkill(
        root: plugin.appendingPathComponent("capabilities"),
        directory: "calendar",
        frontmatter: """
        ---
        name: calendar
        description: Manage installed calendar data
        ---
        """
    )
    _ = try writeSkill(
        root: plugin.appendingPathComponent("skills"),
        directory: "undeclared",
        frontmatter:
            "---\nname: undeclared\ndescription: Ignore me\n---"
    )

    let response = try service.list(
        cwds: [workspace.path],
        forceReload: true
    )
    let skill = try #require(response[0].skills.first)
    #expect(response[0].skills.count == 1)
    #expect(skill.name == "calendar-tools:calendar")
    #expect(skill.description == "Manage installed calendar data")
    #expect(skill.path == skillPath.path)
    #expect(skill.scope == .user)
}
