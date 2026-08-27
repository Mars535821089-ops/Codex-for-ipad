#if SWIFT_PACKAGE
import CodexPadDomain
#endif
import Dispatch
import Foundation

@MainActor
public protocol CodexDesktopFileWatching: AnyObject {
    func watch(watchID: String, path: URL, hostID: String) throws -> String
    func unwatch(watchID: String)
}

@MainActor
public final class CodexDesktopFileWatchManager: CodexDesktopFileWatching {
    public typealias ChangeSink = @MainActor @Sendable (String, String, [String]) -> Void
    private struct Entry {
        let hostID: String
        let path: URL
        let timer: DispatchSourceTimer
        var fingerprint: String
    }
    private var entries: [String: Entry] = [:]
    private let changeSink: ChangeSink

    public init(changeSink: @escaping ChangeSink) { self.changeSink = changeSink }

    public func watch(watchID: String, path: URL, hostID: String) throws -> String {
        guard !watchID.isEmpty else { throw WatchError.invalidWatchID }
        unwatch(watchID: watchID)
        let canonical = path.resolvingSymlinksInPath().standardizedFileURL
        guard FileManager.default.fileExists(atPath: canonical.path) else {
            throw WatchError.pathMissing
        }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + .milliseconds(200), repeating: .milliseconds(250), leeway: .milliseconds(50))
        let initial = Self.fingerprint(canonical)
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                self?.poll(watchID: watchID)
            }
        }
        entries[watchID] = Entry(hostID: hostID, path: canonical, timer: timer, fingerprint: initial)
        timer.resume()
        return canonical.path
    }

    public func unwatch(watchID: String) {
        entries.removeValue(forKey: watchID)?.timer.cancel()
    }

    private func poll(watchID: String) {
        guard var entry = entries[watchID] else { return }
        let next = Self.fingerprint(entry.path)
        guard next != entry.fingerprint else { return }
        entry.fingerprint = next
        entries[watchID] = entry
        changeSink(entry.hostID, watchID, [entry.path.path])
    }

    private static func fingerprint(_ root: URL) -> String {
        let manager = FileManager.default
        guard let rootAttributes = try? manager.attributesOfItem(atPath: root.path) else { return "missing" }
        var rows = [attributeRow(".", rootAttributes)]
        if (rootAttributes[.type] as? FileAttributeType) == .typeDirectory,
           let enumerator = manager.enumerator(at: root, includingPropertiesForKeys: nil, options: [.skipsPackageDescendants]) {
            for case let child as URL in enumerator {
                if let attributes = try? manager.attributesOfItem(atPath: child.path) {
                    rows.append(attributeRow(String(child.path.dropFirst(root.path.count)), attributes))
                }
            }
        }
        return rows.sorted().joined(separator: "\n")
    }

    private static func attributeRow(_ path: String, _ attributes: [FileAttributeKey: Any]) -> String {
        let type = (attributes[.type] as? FileAttributeType)?.rawValue ?? ""
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return "\(path)|\(type)|\(size)|\(modified)"
    }

    deinit { for entry in entries.values { entry.timer.cancel() } }
    public enum WatchError: Error, Equatable { case invalidWatchID; case pathMissing }
}
