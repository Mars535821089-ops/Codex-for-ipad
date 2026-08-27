import Foundation
import Testing

@testable import CodexPadApplication

@Test
func pluginShareLocalPathStoreMatchesDesktopCacheContract() throws {
    let fileManager = FileManager.default
    let home = fileManager.temporaryDirectory.appendingPathComponent(
        "codex-plugin-paths-\(UUID().uuidString)",
        isDirectory: true
    )
    defer { try? fileManager.removeItem(at: home) }
    let store = CodexPluginShareLocalPathStore(
        codexHome: home,
        fileManager: fileManager
    )
    let first = home.appendingPathComponent("plugins/first")
    let second = home.appendingPathComponent("plugins/second")

    #expect(try store.load().isEmpty)
    try store.record(remotePluginID: "remote-2", pluginPath: second)
    try store.record(remotePluginID: "remote-1", pluginPath: first)

    #expect(try store.load() == [
        "remote-1": first.standardizedFileURL,
        "remote-2": second.standardizedFileURL,
    ])
    let cache = home.appendingPathComponent(
        ".tmp/plugin-share-local-paths-v1.json"
    )
    let object = try JSONSerialization.jsonObject(
        with: Data(contentsOf: cache)
    ) as? [String: Any]
    let mapping = object?[
        "localPluginPathsByRemotePluginId"
    ] as? [String: String]
    #expect(mapping == [
        "remote-1": first.standardizedFileURL.path,
        "remote-2": second.standardizedFileURL.path,
    ])

    try store.remove(remotePluginID: "remote-1")
    #expect(try store.load() == [
        "remote-2": second.standardizedFileURL,
    ])
    try store.remove(remotePluginID: "remote-2")
    #expect(!fileManager.fileExists(atPath: cache.path))
}

@Test
func pluginShareLocalPathStoreRepairsMalformedCacheOnUpdate() throws {
    let fileManager = FileManager.default
    let home = fileManager.temporaryDirectory.appendingPathComponent(
        "codex-plugin-paths-repair-\(UUID().uuidString)",
        isDirectory: true
    )
    defer { try? fileManager.removeItem(at: home) }
    let cache = home.appendingPathComponent(
        ".tmp/plugin-share-local-paths-v1.json"
    )
    try fileManager.createDirectory(
        at: cache.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try Data("{broken".utf8).write(to: cache)
    let store = CodexPluginShareLocalPathStore(
        codexHome: home,
        fileManager: fileManager
    )

    #expect(throws: (any Error).self) {
        _ = try store.load()
    }
    let plugin = home.appendingPathComponent("plugins/repaired")
    try store.record(remotePluginID: "remote-fixed", pluginPath: plugin)
    #expect(try store.load() == [
        "remote-fixed": plugin.standardizedFileURL,
    ])
}
