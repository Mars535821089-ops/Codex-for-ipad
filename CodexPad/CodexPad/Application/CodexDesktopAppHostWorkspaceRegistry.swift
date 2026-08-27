import Foundation

/// Thread-safe workspace snapshot used by per-port AppHost router factories.
///
/// Renderer ports may reconnect after the selected project changes. Keeping
/// the workspace inputs behind one locked registry lets the next router graph
/// observe the current authorized roots instead of the values captured during
/// application startup.
public final class CodexDesktopAppHostWorkspaceRegistry:
    @unchecked Sendable
{
    public struct Snapshot: Equatable, Sendable {
        public let authorizedRoots: [URL]
        public let artifactRoots: [URL]
        public let selectedRoot: URL

        public init(
            authorizedRoots: [URL],
            artifactRoots: [URL],
            selectedRoot: URL
        ) {
            self.authorizedRoots = authorizedRoots
            self.artifactRoots = artifactRoots
            self.selectedRoot = selectedRoot
        }
    }

    private let lock = NSLock()
    private let documentsRoot: URL
    private var authorizedRoots: [URL]
    private var selectedRoot: URL?

    public init(
        authorizedRoots: [URL],
        selectedRoot: URL?,
        documentsRoot: URL
    ) {
        self.documentsRoot = Self.normalized(documentsRoot)
        let normalizedRoots = Self.uniqueNormalized(
            authorizedRoots
        )
        self.authorizedRoots = normalizedRoots
        self.selectedRoot = Self.authorizedSelection(
            selectedRoot,
            in: normalizedRoots
        )
    }

    public func replace(
        authorizedRoots: [URL],
        selectedRoot: URL?
    ) {
        let normalizedRoots = Self.uniqueNormalized(
            authorizedRoots
        )
        let normalizedSelection = Self.authorizedSelection(
            selectedRoot,
            in: normalizedRoots
        )
        lock.lock()
        self.authorizedRoots = normalizedRoots
        self.selectedRoot = normalizedSelection
        lock.unlock()
    }

    public func snapshot() -> Snapshot {
        lock.lock()
        let roots = authorizedRoots
        let selected = selectedRoot
        lock.unlock()

        let effectiveSelected =
            selected ?? roots.first ?? documentsRoot
        var artifactRoots = roots
        if !artifactRoots.contains(documentsRoot) {
            artifactRoots.append(documentsRoot)
        }
        return Snapshot(
            authorizedRoots: roots,
            artifactRoots: artifactRoots,
            selectedRoot: effectiveSelected
        )
    }

    private static func authorizedSelection(
        _ selectedRoot: URL?,
        in authorizedRoots: [URL]
    ) -> URL? {
        guard let selectedRoot else {
            return nil
        }
        let normalizedSelection = normalized(selectedRoot)
        return authorizedRoots.first {
            $0.path == normalizedSelection.path
        }
    }

    private static func uniqueNormalized(
        _ roots: [URL]
    ) -> [URL] {
        var paths = Set<String>()
        return roots.compactMap { root in
            let normalizedRoot = normalized(root)
            guard paths.insert(normalizedRoot.path).inserted else {
                return nil
            }
            return normalizedRoot
        }
    }

    private static func normalized(_ url: URL) -> URL {
        URL(
            fileURLWithPath: url.standardizedFileURL.path,
            isDirectory: true
        )
    }
}
