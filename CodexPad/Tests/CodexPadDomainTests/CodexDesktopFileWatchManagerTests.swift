import Foundation
import Testing
@testable import CodexPadApplication

@Test @MainActor
func desktopFileWatchManagerCoversFsChangedNotificationAndStopsReleasedWatchEvents() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("codex-watch-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    var events: [(String, String, String, [String])] = []
    let manager = CodexDesktopFileWatchManager { hostID, watchID, paths in
        events.append(("fs/changed", hostID, watchID, paths))
    }
    let canonical = try manager.watch(watchID: "watch-1", path: root, hostID: "host-1")
    try Data("change".utf8).write(to: root.appendingPathComponent("file.txt"))
    for _ in 0..<40 where events.isEmpty { try await Task.sleep(for: .milliseconds(25)) }
    #expect(canonical == root.resolvingSymlinksInPath().standardizedFileURL.path)
    #expect(
        events.contains {
            $0.0 == "fs/changed"
                && $0.1 == "host-1"
                && $0.2 == "watch-1"
                && $0.3 == [canonical]
        }
    )
    manager.unwatch(watchID: "watch-1")
}
