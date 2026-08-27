import Foundation

public final class CodexPluginShareLocalPathStore:
    @unchecked Sendable
{
    private struct Payload: Codable {
        var localPluginPathsByRemotePluginId: [String: String]
    }

    private let codexHome: URL
    private let fileManager: FileManager
    private let lock = NSLock()

    public init(
        codexHome: URL,
        fileManager: FileManager = .default
    ) {
        self.codexHome = codexHome.standardizedFileURL
        self.fileManager = fileManager
    }

    public func load() throws -> [String: URL] {
        try lock.withLock {
            try read().mapValues {
                URL(fileURLWithPath: $0).standardizedFileURL
            }
        }
    }

    public func record(
        remotePluginID: String,
        pluginPath: URL
    ) throws {
        try lock.withLock {
            var mapping = readForUpdate()
            mapping[remotePluginID] = try absolutePath(pluginPath)
            try write(mapping)
        }
    }

    public func remove(remotePluginID: String) throws {
        try lock.withLock {
            var mapping = readForUpdate()
            mapping.removeValue(forKey: remotePluginID)
            try write(mapping)
        }
    }

    private var cacheURL: URL {
        codexHome.appendingPathComponent(
            ".tmp/plugin-share-local-paths-v1.json"
        )
    }

    private func read() throws -> [String: String] {
        guard fileManager.fileExists(atPath: cacheURL.path) else {
            return [:]
        }
        let payload = try JSONDecoder().decode(
            Payload.self,
            from: Data(contentsOf: cacheURL)
        )
        var validated: [String: String] = [:]
        for (remoteID, path) in
            payload.localPluginPathsByRemotePluginId
        {
            validated[remoteID] = try absolutePath(
                URL(fileURLWithPath: path)
            )
        }
        return validated
    }

    private func readForUpdate() -> [String: String] {
        (try? read()) ?? [:]
    }

    private func write(_ mapping: [String: String]) throws {
        if mapping.isEmpty {
            guard fileManager.fileExists(atPath: cacheURL.path)
            else { return }
            try fileManager.removeItem(at: cacheURL)
            return
        }
        try fileManager.createDirectory(
            at: cacheURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var data = try encoder.encode(
            Payload(
                localPluginPathsByRemotePluginId: mapping
            )
        )
        data.append(0x0a)
        try data.write(to: cacheURL, options: .atomic)
    }

    private func absolutePath(_ url: URL) throws -> String {
        let standardized = url.standardizedFileURL
        guard standardized.isFileURL,
              standardized.path.hasPrefix("/")
        else {
            throw CocoaError(.fileReadInvalidFileName)
        }
        return standardized.path
    }
}
