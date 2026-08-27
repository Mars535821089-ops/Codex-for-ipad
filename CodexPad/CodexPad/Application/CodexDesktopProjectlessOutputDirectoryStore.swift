import Foundation

/// Persists the released projectless-conversation output-directory hint after
/// the renderer creates a directory and the app server returns the thread ID.
public final class CodexDesktopProjectlessOutputDirectoryStore:
    @unchecked Sendable
{
    public static let defaultPersistenceKey =
        "codex.desktop.projectless-output-directories"

    public let workspaceRoot: URL

    private let userDefaults: UserDefaults
    private let fileManager: FileManager
    private let persistenceKey: String
    private let lock = NSLock()
    private var pendingByCWD: [String: URL] = [:]
    private var directoriesByThreadID: [String: URL] = [:]

    public init(
        workspaceRoot: URL,
        userDefaults: UserDefaults = .standard,
        fileManager: FileManager = .default,
        persistenceKey: String = defaultPersistenceKey
    ) {
        self.workspaceRoot = workspaceRoot.standardizedFileURL
        self.userDefaults = userDefaults
        self.fileManager = fileManager
        self.persistenceKey = persistenceKey

        let persisted =
            userDefaults.dictionary(forKey: persistenceKey)
                as? [String: String] ?? [:]
        directoriesByThreadID = persisted.reduce(
            into: [:]
        ) { result, entry in
            let threadID = entry.key.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            guard !threadID.isEmpty else {
                return
            }
            result[threadID] = URL(
                fileURLWithPath: entry.value,
                isDirectory: true
            ).standardizedFileURL
        }
    }

    /// Records the exact directory tuple returned by
    /// `projectless-thread-cwd`. The pending association remains memory-only
    /// until the subsequent `thread/start` response provides a durable ID.
    @discardableResult
    public func recordCreatedPaths(
        cwd: String,
        outputDirectory: String,
        workspaceRoot returnedWorkspaceRoot: String
    ) -> Bool {
        guard let root = validatedDirectory(
            URL(
                fileURLWithPath: returnedWorkspaceRoot,
                isDirectory: true
            ),
            within: workspaceRoot,
            allowEqual: true
        ),
        root.path == validatedWorkspaceRoot()?.path,
        let cwdURL = validatedDirectory(
            URL(fileURLWithPath: cwd, isDirectory: true),
            within: root,
            allowEqual: false
        ),
        let outputURL = validatedDirectory(
            URL(
                fileURLWithPath: outputDirectory,
                isDirectory: true
            ),
            within: cwdURL,
            allowEqual: true
        )
        else {
            return false
        }
        lock.withLock {
            pendingByCWD[cwdURL.path] = outputURL
        }
        return true
    }

    /// Pairs a successful `thread/start` result with its previously created
    /// output directory. Existing projectless directories use the released
    /// legacy inference (`cwd/outputs`, then `cwd`) when no pending tuple is
    /// available.
    @discardableResult
    public func associate(
        threadID rawThreadID: String,
        cwd: String
    ) -> Bool {
        let threadID = rawThreadID.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !threadID.isEmpty,
              let root = validatedWorkspaceRoot(),
              let cwdURL = validatedDirectory(
                  URL(fileURLWithPath: cwd, isDirectory: true),
                  within: root,
                  allowEqual: false
              )
        else {
            return false
        }

        return lock.withLock {
            let outputURL: URL?
            if let pending = pendingByCWD.removeValue(
                forKey: cwdURL.path
            ), let validated = validatedDirectory(
                pending,
                within: cwdURL,
                allowEqual: true
            ) {
                outputURL = validated
            } else {
                let legacyOutputs = cwdURL.appendingPathComponent(
                    "outputs",
                    isDirectory: true
                )
                outputURL =
                    validatedDirectory(
                        legacyOutputs,
                        within: cwdURL,
                        allowEqual: false
                    )
                    ?? validatedDirectory(
                        cwdURL,
                        within: root,
                        allowEqual: false
                    )
            }
            guard let outputURL else {
                return false
            }
            directoriesByThreadID[threadID] = outputURL
            persistLocked()
            return true
        }
    }

    /// Returns only current real directories under the configured projectless
    /// root. Stale or redirected persisted entries are pruned atomically.
    public var outputDirectories: [String: URL] {
        lock.withLock {
            guard let root = validatedWorkspaceRoot() else {
                return [:]
            }
            let filtered = directoriesByThreadID.reduce(
                into: [String: URL]()
            ) { result, entry in
                guard let directory = validatedDirectory(
                    entry.value,
                    within: root,
                    allowEqual: false
                ) else {
                    return
                }
                result[entry.key] = directory
            }
            if filtered != directoriesByThreadID {
                directoriesByThreadID = filtered
                persistLocked()
            }
            return filtered
        }
    }

    private func validatedWorkspaceRoot() -> URL? {
        validatedDirectory(
            workspaceRoot,
            within: workspaceRoot,
            allowEqual: true
        )
    }

    private func validatedDirectory(
        _ rawURL: URL,
        within rawParent: URL,
        allowEqual: Bool
    ) -> URL? {
        let url = rawURL.standardizedFileURL
        let parent = rawParent.standardizedFileURL
        guard Self.isContained(
            url,
            in: parent,
            allowEqual: allowEqual
        ),
        !hasSymbolicLinkComponent(
            from: parent,
            through: url
        ),
        let values = try? url.resourceValues(
            forKeys: [
                .isDirectoryKey,
                .isSymbolicLinkKey,
            ]
        ),
        values.isDirectory == true,
        values.isSymbolicLink != true
        else {
            return nil
        }

        let realURL = url.resolvingSymlinksInPath()
            .standardizedFileURL
        let realParent = parent.resolvingSymlinksInPath()
            .standardizedFileURL
        guard Self.isContained(
            realURL,
            in: realParent,
            allowEqual: allowEqual
        ) else {
            return nil
        }
        return realURL
    }

    private func hasSymbolicLinkComponent(
        from root: URL,
        through candidate: URL
    ) -> Bool {
        let root = root.standardizedFileURL
        let candidate = candidate.standardizedFileURL
        guard Self.isContained(
            candidate,
            in: root,
            allowEqual: true
        ) else {
            return true
        }

        var current = root
        if Self.isSymbolicLink(current) {
            return true
        }
        if candidate.path == root.path {
            return false
        }
        let prefix =
            root.path.hasSuffix("/") ? root.path : root.path + "/"
        let suffix = candidate.path.dropFirst(prefix.count)
        for component in suffix.split(separator: "/") {
            current = current.appendingPathComponent(
                String(component),
                isDirectory: true
            )
            if Self.isSymbolicLink(current) {
                return true
            }
        }
        return false
    }

    private static func isSymbolicLink(_ url: URL) -> Bool {
        (try? url.resourceValues(
            forKeys: [.isSymbolicLinkKey]
        ).isSymbolicLink) == true
    }

    private static func isContained(
        _ candidate: URL,
        in root: URL,
        allowEqual: Bool
    ) -> Bool {
        let candidatePath = candidate.standardizedFileURL.path
        let rootPath = root.standardizedFileURL.path
        if allowEqual, candidatePath == rootPath {
            return true
        }
        let prefix = rootPath.hasSuffix("/")
            ? rootPath
            : rootPath + "/"
        return candidatePath.hasPrefix(prefix)
    }

    private func persistLocked() {
        let values = directoriesByThreadID.mapValues(\.path)
        userDefaults.set(values, forKey: persistenceKey)
    }
}
