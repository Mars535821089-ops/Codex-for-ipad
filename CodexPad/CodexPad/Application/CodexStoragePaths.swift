import Foundation

public struct CodexStoragePaths: Equatable, Sendable {
    public let databasePath: String
    public let snapshotDirectory: String

    public static func prepare(
        in applicationSupportDirectory: URL,
        fileManager: FileManager = .default
    ) throws -> Self {
        let root = applicationSupportDirectory
            .appendingPathComponent("CodexPad", isDirectory: true)
        let snapshots = root.appendingPathComponent(
            "MigrationSnapshots",
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: snapshots,
            withIntermediateDirectories: true
        )
        return Self(
            databasePath: root
                .appendingPathComponent("CodexPad.sqlite", isDirectory: false)
                .path,
            snapshotDirectory: snapshots.path
        )
    }
}
