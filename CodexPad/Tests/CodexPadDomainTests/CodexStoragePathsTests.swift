import Foundation
import Testing
import CodexPadApplication

@Test
func codexStoragePathsStayInsideApplicationSupport() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let paths = try CodexStoragePaths.prepare(in: root)

    #expect(
        paths.databasePath
            == root.appendingPathComponent("CodexPad/CodexPad.sqlite").path
    )
    #expect(
        paths.snapshotDirectory
            == root.appendingPathComponent(
                "CodexPad/MigrationSnapshots",
                isDirectory: true
            ).path
    )
    #expect(
        FileManager.default.fileExists(
            atPath: paths.snapshotDirectory
        )
    )
}
