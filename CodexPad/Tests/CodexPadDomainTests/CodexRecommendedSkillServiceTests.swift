import Foundation
import Testing

@testable import CodexPadApplication

private func makeRecommendedSkillFixture()
    throws -> (
        root: URL,
        installRoot: URL,
        workspace: URL
    )
{
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(
            "CodexRecommendedSkillTests-\(UUID().uuidString)",
            isDirectory: true
        )
    let bundled = root.appendingPathComponent(
        "bundled",
        isDirectory: true
    )
    let curated = bundled.appendingPathComponent(
        "skills/.curated",
        isDirectory: true
    )
    let skill = curated.appendingPathComponent(
        "calendar",
        isDirectory: true
    )
    try FileManager.default.createDirectory(
        at: skill.appendingPathComponent(
            "agents",
            isDirectory: true
        ),
        withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
        at: skill.appendingPathComponent(
            "assets",
            isDirectory: true
        ),
        withIntermediateDirectories: true
    )
    try Data(
        """
        ---
        name: calendar
        description: Manage real calendar events
        metadata:
          icon-small: icon-small.svg
        ---
        # Calendar
        """.utf8
    ).write(
        to: skill.appendingPathComponent("SKILL.md")
    )
    try Data(
        """
        interface:
          display_name: "Calendar"
          short_description: "Calendar tools"
          icon_large: "icon.png"
        """.utf8
    ).write(
        to: skill.appendingPathComponent(
            "agents/openai.yaml"
        )
    )
    try Data("<svg/>".utf8).write(
        to: skill.appendingPathComponent(
            "assets/icon-small.svg"
        )
    )
    try Data([0x89, 0x50, 0x4E, 0x47]).write(
        to: skill.appendingPathComponent(
            "assets/icon.png"
        )
    )

    let duplicate = bundled.appendingPathComponent(
        "skills/.experimental/calendar",
        isDirectory: true
    )
    try FileManager.default.createDirectory(
        at: duplicate,
        withIntermediateDirectories: true
    )
    try Data(
        """
        ---
        name: replaced-calendar
        description: Experimental duplicate
        ---
        """.utf8
    ).write(
        to: duplicate.appendingPathComponent("SKILL.md")
    )

    let installRoot = root.appendingPathComponent(
        "CodexHome/skills",
        isDirectory: true
    )
    let workspace = root.appendingPathComponent(
        "Workspace",
        isDirectory: true
    )
    try FileManager.default.createDirectory(
        at: workspace,
        withIntermediateDirectories: true
    )
    return (bundled, installRoot, workspace)
}

@Test
func recommendedSkillServiceListsExactBundledShapeAndMetadata()
    throws
{
    let fixture = try makeRecommendedSkillFixture()
    defer {
        try? FileManager.default.removeItem(
            at: fixture.root.deletingLastPathComponent()
        )
    }
    let date = Date(timeIntervalSince1970: 1_725_000_000)
    let service = CodexRecommendedSkillService(
        bundledRepoRoot: fixture.root,
        defaultInstallRoot: fixture.installRoot,
        now: { date }
    )

    let snapshot = service.list(refresh: false)

    #expect(snapshot.source == "bundled")
    #expect(snapshot.repoRoot == fixture.root.path)
    #expect(snapshot.error == nil)
    #expect(snapshot.fetchedAt == 1_725_000_000_000)
    #expect(snapshot.skills.count == 1)
    let skill = try #require(snapshot.skills.first)
    #expect(skill.id == "calendar")
    #expect(skill.name == "calendar")
    #expect(skill.description == "Manage real calendar events")
    #expect(skill.shortDescription == "Calendar tools")
    #expect(skill.repoPath == "skills/.curated/calendar")
    #expect(skill.iconSmall == "icon-small.svg")
    #expect(skill.iconLarge == "icon.png")
}

@Test
func recommendedSkillServiceInstallsAndPreservesExistingSkill()
    throws
{
    let fixture = try makeRecommendedSkillFixture()
    defer {
        try? FileManager.default.removeItem(
            at: fixture.root.deletingLastPathComponent()
        )
    }
    let service = CodexRecommendedSkillService(
        bundledRepoRoot: fixture.root,
        defaultInstallRoot: fixture.installRoot
    )

    let installed = service.install(
        skillID: "calendar",
        repoPath: "skills/.curated/calendar",
        installRoot: nil,
        markdownOverride: nil,
        forceReinstall: false,
        source: nil,
        allowedInstallRoots: []
    )
    #expect(installed.success)
    let destination = try #require(installed.destination)
    #expect(
        FileManager.default.fileExists(
            atPath: URL(fileURLWithPath: destination)
                .appendingPathComponent("agents/openai.yaml")
                .path
        )
    )

    let marker = URL(fileURLWithPath: destination)
        .appendingPathComponent("local-marker.txt")
    try Data("preserve".utf8).write(to: marker)
    let repeated = service.install(
        skillID: "calendar",
        repoPath: "skills/.curated/calendar",
        installRoot: nil,
        markdownOverride: nil,
        forceReinstall: false,
        source: nil,
        allowedInstallRoots: []
    )
    #expect(repeated.success)
    #expect(
        FileManager.default.fileExists(atPath: marker.path)
    )

    let replaced = service.install(
        skillID: "calendar",
        repoPath: "skills/.curated/calendar",
        installRoot: nil,
        markdownOverride: nil,
        forceReinstall: true,
        source: nil,
        allowedInstallRoots: []
    )
    #expect(replaced.success)
    #expect(
        !FileManager.default.fileExists(atPath: marker.path)
    )
}

@Test
func recommendedSkillServiceSupportsWorkspaceOverrideAndSafeRemoval()
    throws
{
    let fixture = try makeRecommendedSkillFixture()
    defer {
        try? FileManager.default.removeItem(
            at: fixture.root.deletingLastPathComponent()
        )
    }
    let service = CodexRecommendedSkillService(
        bundledRepoRoot: fixture.root,
        defaultInstallRoot: fixture.installRoot
    )
    let override = """
        ---
        name: custom-calendar
        description: Custom workspace instructions
        ---
        """

    let installed = service.install(
        skillID: "custom-calendar",
        repoPath: "unused",
        installRoot: fixture.workspace.path,
        markdownOverride: override,
        forceReinstall: false,
        source: nil,
        allowedInstallRoots: [fixture.workspace]
    )
    #expect(installed.success)
    let destination = try #require(installed.destination)
    #expect(
        try String(
            contentsOf: URL(fileURLWithPath: destination)
                .appendingPathComponent("SKILL.md"),
            encoding: .utf8
        ) == override
    )

    let outside = service.remove(
        skillPath: fixture.root.path,
        allowedInstallRoots: [fixture.workspace]
    )
    #expect(!outside.success)
    #expect(
        FileManager.default.fileExists(
            atPath: fixture.root.path
        )
    )

    let removed = service.remove(
        skillPath: destination + "/SKILL.md",
        allowedInstallRoots: [fixture.workspace]
    )
    #expect(removed.success)
    #expect(removed.deletedPath == destination)
    #expect(
        !FileManager.default.fileExists(
            atPath: destination
        )
    )
}

@Test
func recommendedSkillServiceRejectsTraversalAndUnlistedWorkspace()
    throws
{
    let fixture = try makeRecommendedSkillFixture()
    defer {
        try? FileManager.default.removeItem(
            at: fixture.root.deletingLastPathComponent()
        )
    }
    let service = CodexRecommendedSkillService(
        bundledRepoRoot: fixture.root,
        defaultInstallRoot: fixture.installRoot
    )

    let traversal = service.install(
        skillID: "../outside",
        repoPath: "skills/.curated/calendar",
        installRoot: nil,
        markdownOverride: nil,
        forceReinstall: false,
        source: nil,
        allowedInstallRoots: []
    )
    #expect(!traversal.success)
    #expect(traversal.error?.contains("Invalid skill id") == true)

    let workspace = service.install(
        skillID: "calendar",
        repoPath: "skills/.curated/calendar",
        installRoot: fixture.workspace.path,
        markdownOverride: nil,
        forceReinstall: false,
        source: nil,
        allowedInstallRoots: []
    )
    #expect(!workspace.success)
    #expect(
        workspace.error?.contains(
            "Invalid skill install root"
        ) == true
    )

    let repoTraversal = service.install(
        skillID: "calendar",
        repoPath: "../../etc/passwd",
        installRoot: nil,
        markdownOverride: nil,
        forceReinstall: true,
        source: nil,
        allowedInstallRoots: []
    )
    #expect(!repoTraversal.success)
    #expect(
        repoTraversal.error?.contains(
            "Invalid skill repo path"
        ) == true
    )
}
