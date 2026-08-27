#if SWIFT_PACKAGE
    import CodexPadDomain
#endif
import Foundation

public final class CodexDesktopPersistedAtomStore {
    public static let releasedStorageKey =
        "electron-persisted-atom-state"

    private let defaults: UserDefaults
    private let storageKey: String
    private var values: [String: CodexJSONValue]

    public init(
        userDefaults: UserDefaults = .standard,
        storageKey: String = CodexDesktopPersistedAtomStore.releasedStorageKey
    ) {
        self.defaults = userDefaults
        self.storageKey = storageKey
        self.values = Self.decode(
            userDefaults.data(forKey: storageKey)
        )
    }

    public var snapshot: [String: CodexJSONValue] {
        values
    }

    @discardableResult
    public func replace(
        _ state: [String: CodexJSONValue]
    ) -> [String: CodexJSONValue] {
        values = state
        persist()
        return values
    }

    @discardableResult
    public func update(
        key: String,
        value: CodexJSONValue?
    ) -> [String: CodexJSONValue] {
        guard !key.isEmpty else {
            return values
        }
        if let value {
            values[key] = value
        } else {
            values.removeValue(forKey: key)
        }
        persist()
        return values
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(values) else {
            return
        }
        defaults.set(data, forKey: storageKey)
    }

    private static func decode(
        _ data: Data?
    ) -> [String: CodexJSONValue] {
        guard let data,
              let decoded = try? JSONDecoder().decode(
                  [String: CodexJSONValue].self,
                  from: data
              )
        else {
            return [:]
        }
        return decoded
    }
}

/// Persists the released desktop `pinned-thread-ids` global-state entry and
/// implements the same ordered pin/unpin operations exposed by Electron.
public final class CodexDesktopPinnedThreadStore {
    public static let releasedStorageKey = "pinned-thread-ids"

    private let defaults: UserDefaults
    private let storageKey: String
    private var values: [String]

    public init(
        userDefaults: UserDefaults = .standard,
        storageKey: String =
            CodexDesktopPinnedThreadStore.releasedStorageKey
    ) {
        defaults = userDefaults
        self.storageKey = storageKey
        values = Self.decode(userDefaults.data(forKey: storageKey))
    }

    public var threadIDs: [String] {
        values
    }

    public var globalStateValue: CodexJSONValue {
        .array(values.map(CodexJSONValue.string))
    }

    /// Pins or unpins a thread. Supplying `beforeThreadID` also moves an
    /// already-pinned thread to the requested released-sidebar position.
    @discardableResult
    public func setPinned(
        threadID: String,
        pinned: Bool,
        beforeThreadID: String? = nil
    ) -> Bool {
        guard !threadID.isEmpty else {
            return false
        }

        var next = values.filter { $0 != threadID }
        if pinned {
            if let beforeThreadID,
               let index = next.firstIndex(of: beforeThreadID)
            {
                next.insert(threadID, at: index)
            } else {
                next.append(threadID)
            }
        }
        replaceIfNeeded(next)
        return true
    }

    /// Replaces the complete released sidebar order. Duplicate identifiers are
    /// collapsed by first occurrence so renderer retries remain idempotent.
    @discardableResult
    public func setOrder(threadIDs: [String]) -> Bool {
        var seen = Set<String>()
        let normalized = threadIDs.filter {
            !$0.isEmpty && seen.insert($0).inserted
        }
        replaceIfNeeded(normalized)
        return true
    }

    private func replaceIfNeeded(_ next: [String]) {
        guard next != values else {
            return
        }
        values = next
        guard let data = try? JSONEncoder().encode(values) else {
            return
        }
        defaults.set(data, forKey: storageKey)
    }

    private static func decode(_ data: Data?) -> [String] {
        guard let data,
              let decoded = try? JSONDecoder().decode(
                  [String].self,
                  from: data
              )
        else {
            return []
        }

        var seen = Set<String>()
        return decoded.filter {
            !$0.isEmpty && seen.insert($0).inserted
        }
    }
}

/// Persists the desktop config surface and applies the released key-path
/// replace/upsert semantics without inventing values.
public final class CodexDesktopConfigStore {
    private let backing: CodexDesktopPersistedAtomStore

    public init(
        userDefaults: UserDefaults = .standard,
        storageKey: String = "codex.desktop.config.v1"
    ) {
        backing = CodexDesktopPersistedAtomStore(
            userDefaults: userDefaults,
            storageKey: storageKey
        )
    }

    public var snapshot: [String: CodexJSONValue] { backing.snapshot }

    @discardableResult
    public func write(
        keyPath: String,
        value: CodexJSONValue,
        mergeStrategy: String
    ) -> [String: CodexJSONValue] {
        var next = backing.snapshot
        let parts = keyPath.split(separator: ".").map(String.init)
        guard !parts.isEmpty else { return next }
        if parts.count == 1 {
            next[parts[0]] = value
        } else {
            var root: CodexJSONValue = .object(next)
            Self.assign(&root, parts: parts, value: value,
                        mergeStrategy: mergeStrategy)
            if case let .object(fields) = root { next = fields }
        }
        return backing.replace(next)
    }

    @discardableResult
    public func batchWrite(
        edits: [(keyPath: String, value: CodexJSONValue, mergeStrategy: String)]
    ) -> [String: CodexJSONValue] {
        var result = backing.snapshot
        for edit in edits {
            _ = write(
                keyPath: edit.keyPath,
                value: edit.value,
                mergeStrategy: edit.mergeStrategy
            )
            result = backing.snapshot
        }
        return result
    }

    private static func assign(
        _ node: inout CodexJSONValue,
        parts: [String],
        value: CodexJSONValue,
        mergeStrategy: String
    ) {
        guard let head = parts.first else { return }
        if parts.count == 1 {
            guard case var .object(fields) = node else {
                node = .object([head: value]); return
            }
            if mergeStrategy == "upsert",
               case let .object(existing) = fields[head],
               case let .object(incoming) = value {
                fields[head] = .object(existing.merging(incoming) { _, new in new })
            } else {
                fields[head] = value
            }
            node = .object(fields)
            return
        }
        var child: CodexJSONValue
        if case let .object(fields) = node {
            child = fields[head] ?? .object([:])
        } else {
            child = .object([:])
        }
        assign(&child, parts: Array(parts.dropFirst()), value: value,
               mergeStrategy: mergeStrategy)
        if case var .object(fields) = node {
            fields[head] = child; node = .object(fields)
        } else {
            node = .object([head: child])
        }
    }
}

/// Persists the released desktop `selected-project` global-state value.
///
/// Workspace contents remain in CodexCore's SQLite event log. This store owns
/// only the UI selection that Electron keeps separately from project data.
public final class CodexDesktopSelectedProjectStore {
    public static let releasedStorageKey = "selected-project"

    private let defaults: UserDefaults
    private let storageKey: String

    public init(
        userDefaults: UserDefaults = .standard,
        storageKey: String =
            CodexDesktopSelectedProjectStore.releasedStorageKey
    ) {
        defaults = userDefaults
        self.storageKey = storageKey
    }

    public var globalStateValue: CodexJSONValue? {
        guard let data = defaults.data(forKey: storageKey) else {
            return nil
        }
        return try? JSONDecoder().decode(
            CodexJSONValue.self,
            from: data
        )
    }

    public var selectedWorkspaceID: UUID? {
        guard case let .object(fields)? = globalStateValue,
              fields["type"] == .string("local"),
              case let .string(projectID)? = fields["projectId"]
        else {
            return nil
        }
        return UUID(uuidString: projectID)
    }

    public func setSelectedWorkspaceID(_ id: UUID?) {
        guard let id else {
            defaults.removeObject(forKey: storageKey)
            return
        }
        let value = CodexJSONValue.object([
            "type": .string("local"),
            "projectId": .string(
                id.uuidString.lowercased()
            ),
        ])
        guard let data = try? JSONEncoder().encode(value) else {
            return
        }
        defaults.set(data, forKey: storageKey)
    }

    @discardableResult
    public func restoreSelection(
        from workspaces: [Workspace]
    ) -> UUID? {
        guard let selectedWorkspaceID else {
            defaults.removeObject(forKey: storageKey)
            return nil
        }
        guard workspaces.contains(
            where: { $0.id == selectedWorkspaceID }
        ) else {
            defaults.removeObject(forKey: storageKey)
            return nil
        }
        return selectedWorkspaceID
    }

    @discardableResult
    public func resolveInitialSelection(
        preferredWorkspaceID: UUID?,
        from workspaces: [Workspace]
    ) -> UUID? {
        if let preferredWorkspaceID,
           workspaces.contains(where: { $0.id == preferredWorkspaceID })
        {
            setSelectedWorkspaceID(preferredWorkspaceID)
            return preferredWorkspaceID
        }
        return restoreSelection(from: workspaces)
    }
}

/// Mirrors the released desktop global-state entries that describe local
/// projects. CodexCore remains the source of truth for workspace identity and
/// bookmarks; this store preserves only Electron's ordering and timestamps.
public struct CodexDesktopLocalProjectRecord:
    Codable,
    Equatable,
    Sendable
{
    public let id: String
    public let name: String
    public let rootPaths: [String]
    public let createdAt: Int64
    public let updatedAt: Int64

    public init(
        id: String,
        name: String,
        rootPaths: [String],
        createdAt: Int64,
        updatedAt: Int64
    ) {
        self.id = id
        self.name = name
        self.rootPaths = rootPaths
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public final class CodexDesktopLocalProjectsStateStore:
    @unchecked Sendable
{
    public static let storageKey =
        "codex.desktop.local-projects-metadata.v1"

    private struct ProjectMetadata: Codable, Equatable {
        var name: String
        var rootPaths: [String]
        var createdAt: Int64
        var updatedAt: Int64
    }

    private struct StoredState: Codable {
        var projects: [String: ProjectMetadata]
        var order: [String]
        var removedProjectIDs: Set<String>
        var explicitProjectIDs: Set<String>

        static let empty = StoredState(
            projects: [:],
            order: [],
            removedProjectIDs: [],
            explicitProjectIDs: []
        )

        private enum CodingKeys: String, CodingKey {
            case projects
            case order
            case removedProjectIDs
            case explicitProjectIDs
        }

        init(
            projects: [String: ProjectMetadata],
            order: [String],
            removedProjectIDs: Set<String> = [],
            explicitProjectIDs: Set<String> = []
        ) {
            self.projects = projects
            self.order = order
            self.removedProjectIDs = removedProjectIDs
            self.explicitProjectIDs = explicitProjectIDs
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(
                keyedBy: CodingKeys.self
            )
            projects = try container.decode(
                [String: ProjectMetadata].self,
                forKey: .projects
            )
            order = try container.decode(
                [String].self,
                forKey: .order
            )
            removedProjectIDs = try container.decodeIfPresent(
                Set<String>.self,
                forKey: .removedProjectIDs
            ) ?? []
            explicitProjectIDs = try container.decodeIfPresent(
                Set<String>.self,
                forKey: .explicitProjectIDs
            ) ?? Set(projects.keys)
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(
                keyedBy: CodingKeys.self
            )
            try container.encode(projects, forKey: .projects)
            try container.encode(order, forKey: .order)
            try container.encode(
                removedProjectIDs,
                forKey: .removedProjectIDs
            )
            try container.encode(
                explicitProjectIDs,
                forKey: .explicitProjectIDs
            )
        }
    }

    private let defaults: UserDefaults
    private let storageKey: String
    private let nowMilliseconds: () -> Int64
    private let lock = NSLock()
    private var state: StoredState

    public init(
        userDefaults: UserDefaults = .standard,
        storageKey: String =
            CodexDesktopLocalProjectsStateStore.storageKey,
        nowMilliseconds: @escaping () -> Int64 = {
            Int64(Date().timeIntervalSince1970 * 1_000)
        }
    ) {
        defaults = userDefaults
        self.storageKey = storageKey
        self.nowMilliseconds = nowMilliseconds
        if let data = userDefaults.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode(
               StoredState.self,
               from: data
           )
        {
            state = decoded
        } else {
            state = .empty
        }
    }

    /// Returns an immutable, Sendable snapshot of one local project.
    public func project(
        projectID: String
    ) -> CodexDesktopLocalProjectRecord? {
        withLock {
            state.projects[projectID].map {
                Self.record(projectID: projectID, metadata: $0)
            }
        }
    }

    /// Returns ordered projects first, followed by every project that has not
    /// yet been inserted into the released desktop sidebar order.
    public var projectsInOrder: [CodexDesktopLocalProjectRecord] {
        withLock {
            var seen = Set<String>()
            let projectIDs = state.order.filter {
                state.projects[$0] != nil && seen.insert($0).inserted
            } + state.projects.keys.filter {
                seen.insert($0).inserted
            }
            return projectIDs.compactMap { projectID in
                state.projects[projectID].map {
                    Self.record(
                        projectID: projectID,
                        metadata: $0
                    )
                }
            }
        }
    }

    /// Creates a caller-identified project and prepends it to desktop order.
    @discardableResult
    public func createProject(
        projectID: String,
        name: String,
        rootPaths: [String]
    ) -> CodexDesktopLocalProjectRecord {
        withLock {
            let now = nowMilliseconds()
            let metadata = ProjectMetadata(
                name: Self.trimmedName(name),
                rootPaths: Self.removingExactDuplicates(rootPaths),
                createdAt: now,
                updatedAt: now
            )
            state.projects[projectID] = metadata
            state.removedProjectIDs.remove(projectID)
            state.explicitProjectIDs.insert(projectID)
            state.order = [
                projectID
            ] + state.order.filter { $0 != projectID }
            persistLocked()
            return Self.record(
                projectID: projectID,
                metadata: metadata
            )
        }
    }

    /// Edits an existing project without changing its sidebar position.
    ///
    /// A blank name preserves the previous display name. Root paths are
    /// de-duplicated by exact first occurrence so path spelling and order stay
    /// renderer-controlled.
    @discardableResult
    public func editProject(
        projectID: String,
        name: String,
        rootPaths: [String]
    ) -> CodexDesktopLocalProjectRecord? {
        withLock {
            editProjectLocked(
                projectID: projectID,
                name: name,
                rootPaths: rootPaths
            )
        }
    }

    /// Renames an existing project. Missing, blank, and unchanged names are
    /// desktop no-ops.
    @discardableResult
    public func renameProject(
        projectID: String,
        name: String
    ) -> Bool {
        withLock {
            guard var metadata = state.projects[projectID] else {
                return false
            }
            let nextName = Self.trimmedName(name)
            guard !nextName.isEmpty, nextName != metadata.name else {
                return false
            }
            metadata.name = nextName
            metadata.updatedAt = nowMilliseconds()
            state.projects[projectID] = metadata
            persistLocked()
            return true
        }
    }

    /// Removes project metadata and every matching sidebar-order entry.
    @discardableResult
    public func removeProject(
        projectID: String
    ) -> Bool {
        withLock {
            guard state.projects.removeValue(forKey: projectID) != nil else {
                return false
            }
            state.order.removeAll { $0 == projectID }
            state.removedProjectIDs.insert(projectID)
            state.explicitProjectIDs.remove(projectID)
            persistLocked()
            return true
        }
    }

    /// Updates existing metadata or records caller-provided metadata without
    /// implicitly inserting a missing project into sidebar order.
    @discardableResult
    public func upsertProject(
        projectID: String,
        name: String,
        rootPaths: [String]
    ) -> CodexDesktopLocalProjectRecord {
        withLock {
            if let edited = editProjectLocked(
                projectID: projectID,
                name: name,
                rootPaths: rootPaths
            ) {
                return edited
            }
            let now = nowMilliseconds()
            let metadata = ProjectMetadata(
                name: Self.trimmedName(name),
                rootPaths: Self.removingExactDuplicates(rootPaths),
                createdAt: now,
                updatedAt: now
            )
            state.projects[projectID] = metadata
            state.removedProjectIDs.remove(projectID)
            state.explicitProjectIDs.insert(projectID)
            persistLocked()
            return Self.record(
                projectID: projectID,
                metadata: metadata
            )
        }
    }

    /// Generates the released `local-projects` and `project-order` values from
    /// the current persisted metadata without reconciling Core workspaces.
    public func globalStateSnapshot(
        selectedProject: CodexJSONValue? = nil
    ) -> [String: CodexJSONValue] {
        withLock {
            globalStateSnapshotLocked(
                selectedProject: selectedProject
            )
        }
    }

    /// Returns the exact released `local-projects` and `project-order` values.
    ///
    /// Existing metadata keeps its creation time across launches. A real
    /// workspace name change advances only `updatedAt`, matching desktop.
    /// Workspace roots only seed missing metadata: explicit multi-root project
    /// metadata must not collapse back to Core's single bookmark root.
    public func synchronize(
        workspaces: [Workspace],
        selectedProject: CodexJSONValue? = nil,
        rootPath: (Workspace) -> String?
    ) -> [String: CodexJSONValue] {
        let seeds = workspaces.map { workspace in
            (
                workspace: workspace,
                rootPath: rootPath(workspace)
            )
        }
        return withLock {
            let workspaceIDs = Set(
                seeds.map {
                    $0.workspace.id.uuidString.lowercased()
                }
            ).subtracting(state.removedProjectIDs)
            let explicitProjectIDs = state.explicitProjectIDs
                .intersection(state.projects.keys)
                .subtracting(state.removedProjectIDs)
            let retainedProjectIDs = workspaceIDs.union(
                explicitProjectIDs
            )
            var nextOrder = state.order.filter(
                retainedProjectIDs.contains
            )
            var nextProjects = state.projects.filter {
                explicitProjectIDs.contains($0.key)
            }

            for seed in seeds {
                let workspace = seed.workspace
                let projectID = workspace.id.uuidString.lowercased()
                guard !state.removedProjectIDs.contains(projectID) else {
                    continue
                }
                if var metadata = state.projects[projectID] {
                    let workspaceName = Self.trimmedName(
                        workspace.displayName
                    )
                    var metadataChanged = false
                    if !workspaceName.isEmpty,
                       metadata.name != workspaceName
                    {
                        metadata.name = workspaceName
                        metadataChanged = true
                    }
                    if !explicitProjectIDs.contains(projectID),
                       let rootPath = seed.rootPath,
                       metadata.rootPaths != [rootPath]
                    {
                        metadata.rootPaths = [rootPath]
                        metadataChanged = true
                    }
                    if metadataChanged {
                        metadata.updatedAt = nowMilliseconds()
                    }
                    nextProjects[projectID] = metadata
                } else {
                    let now = nowMilliseconds()
                    nextProjects[projectID] = ProjectMetadata(
                        name: Self.trimmedName(workspace.displayName),
                        rootPaths: seed.rootPath.map { [$0] } ?? [],
                        createdAt: now,
                        updatedAt: now
                    )
                    nextOrder.insert(projectID, at: 0)
                }
            }

            for projectID in workspaceIDs
                where !nextOrder.contains(projectID)
            {
                nextOrder.append(projectID)
            }
            state = StoredState(
                projects: nextProjects,
                order: nextOrder,
                removedProjectIDs: state.removedProjectIDs,
                explicitProjectIDs: explicitProjectIDs
            )
            persistLocked()
            return globalStateSnapshotLocked(
                selectedProject: selectedProject
            )
        }
    }

    private func editProjectLocked(
        projectID: String,
        name: String,
        rootPaths: [String]
    ) -> CodexDesktopLocalProjectRecord? {
        guard var metadata = state.projects[projectID] else {
            return nil
        }
        let nextName = Self.trimmedName(name)
        if !nextName.isEmpty {
            metadata.name = nextName
        }
        metadata.rootPaths = Self.removingExactDuplicates(rootPaths)
        metadata.updatedAt = nowMilliseconds()
        state.projects[projectID] = metadata
        persistLocked()
        return Self.record(
            projectID: projectID,
            metadata: metadata
        )
    }

    private func globalStateSnapshotLocked(
        selectedProject: CodexJSONValue?
    ) -> [String: CodexJSONValue] {
        let projects = Dictionary(
            uniqueKeysWithValues: state.projects.map {
                projectID, metadata in
                (
                    projectID,
                    CodexJSONValue.object([
                        "id": .string(projectID),
                        "name": .string(metadata.name),
                        "rootPaths": .array(
                            metadata.rootPaths.map(
                                CodexJSONValue.string
                            )
                        ),
                        "createdAt": .integer(metadata.createdAt),
                        "updatedAt": .integer(metadata.updatedAt),
                    ])
                )
            }
        )
        var snapshot: [String: CodexJSONValue] = [
            "local-projects": .object(projects),
            "project-order": .array(
                state.order.map(CodexJSONValue.string)
            ),
        ]
        if case let .object(selection)? = selectedProject,
           selection["type"] == .string("local"),
           case let .string(projectID)? = selection["projectId"],
           state.projects[projectID] != nil
        {
            snapshot["selected-project"] = selectedProject
        }
        return snapshot
    }

    private func persistLocked() {
        guard let data = try? JSONEncoder().encode(state) else {
            return
        }
        defaults.set(data, forKey: storageKey)
    }

    private func withLock<Result>(
        _ operation: () throws -> Result
    ) rethrows -> Result {
        lock.lock()
        defer { lock.unlock() }
        return try operation()
    }

    private static func record(
        projectID: String,
        metadata: ProjectMetadata
    ) -> CodexDesktopLocalProjectRecord {
        CodexDesktopLocalProjectRecord(
            id: projectID,
            name: metadata.name,
            rootPaths: metadata.rootPaths,
            createdAt: metadata.createdAt,
            updatedAt: metadata.updatedAt
        )
    }

    private static func trimmedName(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func removingExactDuplicates(
        _ rootPaths: [String]
    ) -> [String] {
        var seen = Set<String>()
        return rootPaths.filter { seen.insert($0).inserted }
    }
}
