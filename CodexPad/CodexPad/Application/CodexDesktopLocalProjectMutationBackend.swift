#if SWIFT_PACKAGE
    import CodexPadDomain
#endif
import Foundation

/// Applies the released desktop `localProjects` mutation contract to the
/// iPad's persisted project metadata and its primary CodexCore workspace.
///
/// Desktop projects may contain several ordered roots while CodexCore keeps a
/// single primary bookmark. This adapter deliberately preserves the complete
/// root array in `CodexDesktopLocalProjectsStateStore` and mirrors only the
/// first root into the Core workspace.
@MainActor
public final class CodexDesktopLocalProjectMutationBackend {
    public typealias Value = CodexDesktopAppHostRPC.Value

    public enum Error: Swift.Error, Equatable, Sendable {
        case invalidRequest
        case invalidRootPath(String)
        case unsupportedMethod(String)
    }

    private let stateStore: CodexDesktopLocalProjectsStateStore
    private let workspaceSnapshot: () -> [Workspace]
    private let threadSnapshot: () -> [CodexThread]
    private let createWorkspace: (Workspace) throws -> Void
    private let updateWorkspace: (Workspace) throws -> Void
    private let removeWorkspace: (UUID) throws -> Void
    private let bookmark: (URL) throws -> String
    private let createDefaultWorkspace: (String, Bool) throws -> URL
    private let selectWorkspace: (UUID?) -> Void
    private let persistAppearance: (String, Value) -> Void
    private let publishStateChange: () async -> Void

    public init(
        stateStore: CodexDesktopLocalProjectsStateStore,
        workspaceSnapshot: @escaping () -> [Workspace],
        threadSnapshot: @escaping () -> [CodexThread],
        createWorkspace: @escaping (Workspace) throws -> Void,
        updateWorkspace: @escaping (Workspace) throws -> Void,
        removeWorkspace: @escaping (UUID) throws -> Void,
        bookmark: @escaping (URL) throws -> String,
        createDefaultWorkspace:
            @escaping (String, Bool) throws -> URL,
        selectWorkspace: @escaping (UUID?) -> Void,
        persistAppearance: @escaping (String, Value) -> Void,
        publishStateChange: @escaping () async -> Void
    ) {
        self.stateStore = stateStore
        self.workspaceSnapshot = workspaceSnapshot
        self.threadSnapshot = threadSnapshot
        self.createWorkspace = createWorkspace
        self.updateWorkspace = updateWorkspace
        self.removeWorkspace = removeWorkspace
        self.bookmark = bookmark
        self.createDefaultWorkspace = createDefaultWorkspace
        self.selectWorkspace = selectWorkspace
        self.persistAppearance = persistAppearance
        self.publishStateChange = publishStateChange
    }

    public func handle(
        method: String,
        request: Value
    ) async throws -> Value {
        switch method {
        case "create":
            return try await create(request)
        case "edit":
            try await edit(request)
            return .undefined
        case "remove":
            try await remove(request)
            return .undefined
        case "rename":
            try await rename(request)
            return .undefined
        case "upsert":
            try await upsert(request)
            return .undefined
        default:
            throw Error.unsupportedMethod(method)
        }
    }

    private func create(_ request: Value) async throws -> Value {
        let fields = try Self.object(request)
        let requestedName = try Self.string(fields, key: "name")
        let initializeGit = try Self.bool(
            fields,
            key: "initializeDefaultWorkspaceGitRepository"
        )
        let appearance = try Self.required(
            fields,
            key: "appearance"
        )
        var roots = try Self.rootPaths(fields, key: "sources")
        let trimmedRequestedName = Self.trimmed(requestedName)

        if roots.isEmpty {
            let defaultName = trimmedRequestedName.isEmpty
                ? "New project"
                : trimmedRequestedName
            let createdURL = try createDefaultWorkspace(
                defaultName,
                initializeGit
            )
            roots = try Self.normalizedRootPaths([createdURL.path])
        }

        let name = Self.resolvedCreateName(
            requestedName: requestedName,
            rootPaths: roots
        )
        let workspaceID = UUID()
        let projectID = workspaceID.uuidString.lowercased()
        let workspace = try makeWorkspace(
            id: workspaceID,
            displayName: name,
            rootPaths: roots
        )

        try createWorkspace(workspace)
        _ = stateStore.createProject(
            projectID: projectID,
            name: name,
            rootPaths: roots
        )
        selectWorkspace(workspaceID)
        if appearance != .null {
            persistAppearance(projectID, appearance)
        }
        await publishStateChange()

        return .object([
            "projectId": .string(projectID),
            "rootPaths": .array(roots.map(Value.string)),
        ])
    }

    private func edit(_ request: Value) async throws {
        let fields = try Self.object(request)
        let projectID = try Self.string(fields, key: "projectId")
        guard stateStore.project(projectID: projectID) != nil else {
            return
        }
        let name = try Self.string(fields, key: "name")
        let roots = try Self.rootPaths(fields, key: "sources")
        let resultingName = Self.trimmed(name).isEmpty
            ? stateStore.project(projectID: projectID)?.name ?? ""
            : Self.trimmed(name)

        if let workspaceID = UUID(uuidString: projectID),
           workspaceSnapshot().contains(where: { $0.id == workspaceID })
        {
            try updateWorkspace(
                try makeWorkspace(
                    id: workspaceID,
                    displayName: resultingName,
                    rootPaths: roots
                )
            )
        }
        _ = stateStore.editProject(
            projectID: projectID,
            name: name,
            rootPaths: roots
        )
        await publishStateChange()
    }

    private func rename(_ request: Value) async throws {
        let fields = try Self.object(request)
        let projectID = try Self.string(fields, key: "projectId")
        let name = try Self.string(fields, key: "name")
        let nextName = Self.trimmed(name)
        guard let project = stateStore.project(projectID: projectID),
              !nextName.isEmpty,
              project.name != nextName
        else {
            return
        }

        if let workspaceID = UUID(uuidString: projectID),
           let workspace = workspaceSnapshot().first(
               where: { $0.id == workspaceID }
           )
        {
            try updateWorkspace(
                Workspace(
                    id: workspace.id,
                    displayName: nextName,
                    rootBookmarkID: workspace.rootBookmarkID
                )
            )
        }
        _ = stateStore.renameProject(
            projectID: projectID,
            name: nextName
        )
        await publishStateChange()
    }

    private func upsert(_ request: Value) async throws {
        let fields = try Self.object(request)
        let projectID = try Self.string(fields, key: "projectId")
        if stateStore.project(projectID: projectID) != nil {
            try await edit(request)
            return
        }

        let name = Self.trimmed(
            try Self.string(fields, key: "name")
        )
        let roots = try Self.rootPaths(fields, key: "sources")
        if let workspaceID = UUID(uuidString: projectID),
           !workspaceSnapshot().contains(where: { $0.id == workspaceID })
        {
            try createWorkspace(
                try makeWorkspace(
                    id: workspaceID,
                    displayName: name,
                    rootPaths: roots
                )
            )
        }
        _ = stateStore.upsertProject(
            projectID: projectID,
            name: name,
            rootPaths: roots
        )
        await publishStateChange()
    }

    private func remove(_ request: Value) async throws {
        guard case let .string(projectID) = request else {
            throw Error.invalidRequest
        }
        guard stateStore.project(projectID: projectID) != nil else {
            return
        }

        if let workspaceID = UUID(uuidString: projectID),
           workspaceSnapshot().contains(where: { $0.id == workspaceID }),
           !threadSnapshot().contains(
               where: { $0.workspaceID == workspaceID }
           )
        {
            try removeWorkspace(workspaceID)
        }
        _ = stateStore.removeProject(projectID: projectID)
        await publishStateChange()
    }

    private func makeWorkspace(
        id: UUID,
        displayName: String,
        rootPaths: [String]
    ) throws -> Workspace {
        let rootBookmarkID: String?
        if let primaryRoot = rootPaths.first {
            rootBookmarkID = try bookmark(
                URL(fileURLWithPath: primaryRoot, isDirectory: true)
            )
        } else {
            rootBookmarkID = nil
        }
        return Workspace(
            id: id,
            displayName: displayName,
            rootBookmarkID: rootBookmarkID
        )
    }

    private static func object(
        _ value: Value
    ) throws -> [String: Value] {
        guard case let .object(fields) = value else {
            throw Error.invalidRequest
        }
        return fields
    }

    private static func required(
        _ fields: [String: Value],
        key: String
    ) throws -> Value {
        guard let value = fields[key] else {
            throw Error.invalidRequest
        }
        return value
    }

    private static func string(
        _ fields: [String: Value],
        key: String
    ) throws -> String {
        guard case let .string(value)? = fields[key] else {
            throw Error.invalidRequest
        }
        return value
    }

    private static func bool(
        _ fields: [String: Value],
        key: String
    ) throws -> Bool {
        guard case let .bool(value)? = fields[key] else {
            throw Error.invalidRequest
        }
        return value
    }

    private static func rootPaths(
        _ fields: [String: Value],
        key: String
    ) throws -> [String] {
        guard case let .array(values)? = fields[key] else {
            throw Error.invalidRequest
        }
        let paths = try values.map { value in
            guard case let .string(path) = value else {
                throw Error.invalidRequest
            }
            return path
        }
        return try normalizedRootPaths(paths)
    }

    private static func normalizedRootPaths(
        _ paths: [String]
    ) throws -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for path in paths {
            guard !path.isEmpty,
                  (path as NSString).isAbsolutePath
            else {
                throw Error.invalidRootPath(path)
            }
            let normalized = URL(
                fileURLWithPath: path,
                isDirectory: true
            ).standardizedFileURL.path
            if seen.insert(normalized).inserted {
                result.append(normalized)
            }
        }
        return result
    }

    private static func resolvedCreateName(
        requestedName: String,
        rootPaths: [String]
    ) -> String {
        let requestedName = trimmed(requestedName)
        if !requestedName.isEmpty {
            return requestedName
        }
        if let firstRoot = rootPaths.first {
            let basename = URL(
                fileURLWithPath: firstRoot,
                isDirectory: true
            ).lastPathComponent
            if !basename.isEmpty {
                return basename
            }
            if !firstRoot.isEmpty {
                return firstRoot
            }
        }
        return "New project"
    }

    private static func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
