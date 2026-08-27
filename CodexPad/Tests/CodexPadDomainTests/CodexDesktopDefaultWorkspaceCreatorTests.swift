import Foundation
import Testing

@testable import CodexPadApplication

@Test
func defaultWorkspaceCreatorUsesChatGPTDirectoryAndReleasedDefaultName()
    throws
{
    let fileManager = FileManager.default
    let documents = fileManager.temporaryDirectory.appendingPathComponent(
        "codex-default-creator-\(UUID().uuidString)",
        isDirectory: true
    )
    try fileManager.createDirectory(
        at: documents,
        withIntermediateDirectories: true
    )
    defer { try? fileManager.removeItem(at: documents) }

    let root = try CodexDesktopDefaultWorkspaceCreator.create(
        named: "   ",
        initializeGitRepository: false,
        documentsDirectory: documents,
        fileManager: fileManager
    )

    #expect(
        root.path
            == documents
                .appendingPathComponent("ChatGPT", isDirectory: true)
                .appendingPathComponent("New project", isDirectory: true)
                .path
    )
    #expect(fileManager.fileExists(atPath: root.path))
}

@Test
func defaultWorkspaceCreatorReplacesUnsafeScalarsAndTrimsTrailingDots()
    throws
{
    let fileManager = FileManager.default
    let documents = fileManager.temporaryDirectory.appendingPathComponent(
        "codex-default-creator-\(UUID().uuidString)",
        isDirectory: true
    )
    try fileManager.createDirectory(
        at: documents,
        withIntermediateDirectories: true
    )
    defer { try? fileManager.removeItem(at: documents) }

    let root = try CodexDesktopDefaultWorkspaceCreator.create(
        named: "A\u{0000}<B>:\"C\"/D\\E|F?G*H...   ",
        initializeGitRepository: false,
        documentsDirectory: documents,
        fileManager: fileManager
    )

    #expect(root.lastPathComponent == "A__B___C__D_E_F_G_H")
}

@Test
func defaultWorkspaceCreatorProtectsWindowsNamesAndUsesNumericCollisionSuffix()
    throws
{
    let fileManager = FileManager.default
    let documents = fileManager.temporaryDirectory.appendingPathComponent(
        "codex-default-creator-\(UUID().uuidString)",
        isDirectory: true
    )
    try fileManager.createDirectory(
        at: documents,
        withIntermediateDirectories: true
    )
    defer { try? fileManager.removeItem(at: documents) }

    let first = try CodexDesktopDefaultWorkspaceCreator.create(
        named: "CON",
        initializeGitRepository: false,
        documentsDirectory: documents,
        fileManager: fileManager
    )
    let second = try CodexDesktopDefaultWorkspaceCreator.create(
        named: "CON",
        initializeGitRepository: false,
        documentsDirectory: documents,
        fileManager: fileManager
    )

    #expect(first.lastPathComponent == "CON_")
    #expect(second.lastPathComponent == "CON_ 2")
}
