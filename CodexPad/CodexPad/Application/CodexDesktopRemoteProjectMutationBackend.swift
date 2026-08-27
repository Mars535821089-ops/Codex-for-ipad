#if SWIFT_PACKAGE
    import CodexPadDomain
#endif
import Foundation

/// Applies the released `projects.createRemote` and `projects.setAppearance`
/// mutations to the iPad's persisted Electron global state.
///
/// Remote projects intentionally remain separate from `Workspace`: an SSH
/// path cannot be represented by an iPad security-scoped bookmark. The
/// released renderer reads these three atoms directly, so this backend keeps
/// their transaction boundary together and publishes exactly the changed keys.
@MainActor
public final class CodexDesktopRemoteProjectMutationBackend {
    public typealias Value = CodexDesktopAppHostRPC.Value

    public enum Error: Swift.Error, Equatable, Sendable {
        case duplicateRemoteProject
        case invalidRequest
        case remoteProjectUnavailable
        case unsupportedMethod(String)
    }

    private struct RemoteProject: Equatable {
        let hostID: String
        let id: String
        let label: String
        let remotePath: String

        var value: Value {
            .object([
                "hostId": .string(hostID),
                "id": .string(id),
                "label": .string(label),
                "remotePath": .string(remotePath),
            ])
        }
    }

    private let persistedAtoms: CodexDesktopPersistedAtomStore
    private let makeProjectID: () -> String
    private let localProjectIDs: () -> [String]
    private let publishStateChange: ([String]) async -> Void

    public init(
        persistedAtoms: CodexDesktopPersistedAtomStore,
        makeProjectID: @escaping () -> String = {
            UUID().uuidString.lowercased()
        },
        localProjectIDs: @escaping () -> [String] = { [] },
        publishStateChange: @escaping ([String]) async -> Void
    ) {
        self.persistedAtoms = persistedAtoms
        self.makeProjectID = makeProjectID
        self.localProjectIDs = localProjectIDs
        self.publishStateChange = publishStateChange
    }

    public func handle(
        method: String,
        request: Value
    ) async throws -> Value {
        switch method {
        case "createRemote":
            return try await createRemote(request)
        case "setAppearance":
            try await setAppearance(request)
            return .undefined
        case "renameRemote":
            try await renameRemote(request)
            return .undefined
        case "editRemote":
            try await renameRemote(request)
            return .undefined
        case "removeRemote":
            try await removeRemote(request)
            return .undefined
        case "upsertRemote":
            try await upsertRemote(request)
            return .undefined
        default:
            throw Error.unsupportedMethod(method)
        }
    }

    private func createRemote(_ request: Value) async throws -> Value {
        let fields = try Self.object(request)
        let hostID = try Self.nonemptyString(fields, key: "hostId")
        let requestedLabel = try Self.string(fields, key: "label")
        let remotePath = try Self.normalizedRemotePath(
            Self.nonemptyString(fields, key: "remotePath")
        )
        let appearance = try Self.required(fields, key: "appearance")
        let remoteProjects = Self.remoteProjects(
            from: persistedAtoms.snapshot["remote-projects"]
        )
        guard !remoteProjects.contains(where: {
            $0.hostID == hostID && $0.remotePath == remotePath
        }) else {
            throw Error.duplicateRemoteProject
        }

        let project = RemoteProject(
            hostID: hostID,
            id: makeProjectID(),
            label: Self.resolvedLabel(
                requestedLabel,
                remotePath: remotePath
            ),
            remotePath: remotePath
        )
        guard !project.id.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty else {
            throw Error.invalidRequest
        }

        _ = persistedAtoms.update(
            key: "remote-projects",
            value: .array(
                ([project] + remoteProjects).map {
                    Self.jsonValue($0.value)
                }
            )
        )
        let remoteProjectIDs = Set(
            ([project] + remoteProjects).map(\.id)
        )
        _ = persistedAtoms.update(
            key: "project-order",
            value: .array(
                Self.mergedProjectOrder(
                    persistedOrder: Self.projectOrder(
                        persistedAtoms.snapshot["project-order"]
                    ),
                    localProjectIDs: localProjectIDs(),
                    remoteProjectIDs: remoteProjectIDs,
                    prepending: project.id
                ).map(CodexJSONValue.string)
            )
        )

        var changedKeys = ["remote-projects", "project-order"]
        if appearance != .null {
            var appearances = Self.appearances(
                persistedAtoms.snapshot["project-appearances"]
            )
            appearances[project.id] = Self.jsonValue(appearance)
            _ = persistedAtoms.update(
                key: "project-appearances",
                value: .object(appearances)
            )
            changedKeys.append("project-appearances")
        }
        await publishStateChange(changedKeys)
        return project.value
    }

    private func setAppearance(_ request: Value) async throws {
        let fields = try Self.object(request)
        let projectID = try Self.nonemptyString(fields, key: "projectId")
        let appearance = try Self.required(fields, key: "appearance")
        var appearances = Self.appearances(
            persistedAtoms.snapshot["project-appearances"]
        )
        if appearance == .null {
            appearances.removeValue(forKey: projectID)
        } else {
            appearances[projectID] = Self.jsonValue(appearance)
        }
        _ = persistedAtoms.update(
            key: "project-appearances",
            value: .object(appearances)
        )
        await publishStateChange(["project-appearances"])
    }

    private func renameRemote(_ request: Value) async throws {
        let fields = try Self.object(request)
        let projectID = try Self.nonemptyString(fields, key: "projectId")
        let label = try Self.nonemptyString(fields, key: "name")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty else {
            throw Error.invalidRequest
        }
        var projects = Self.remoteProjects(
            from: persistedAtoms.snapshot["remote-projects"]
        )
        guard let index = projects.firstIndex(where: { $0.id == projectID })
        else {
            throw Error.remoteProjectUnavailable
        }
        let existing = projects[index]
        projects[index] = RemoteProject(
            hostID: existing.hostID,
            id: existing.id,
            label: label,
            remotePath: existing.remotePath
        )
        _ = persistedAtoms.update(
            key: "remote-projects",
            value: .array(projects.map { Self.jsonValue($0.value) })
        )
        await publishStateChange(["remote-projects"])
    }

    private func removeRemote(_ request: Value) async throws {
        guard case let .string(projectID) = request,
              !projectID.trimmingCharacters(in: .whitespacesAndNewlines)
                  .isEmpty
        else {
            throw Error.invalidRequest
        }
        var projects = Self.remoteProjects(
            from: persistedAtoms.snapshot["remote-projects"]
        )
        guard projects.contains(where: { $0.id == projectID }) else {
            throw Error.remoteProjectUnavailable
        }
        projects.removeAll { $0.id == projectID }
        _ = persistedAtoms.update(
            key: "remote-projects",
            value: .array(projects.map { Self.jsonValue($0.value) })
        )

        var order = Self.projectOrder(
            persistedAtoms.snapshot["project-order"]
        )
        order.removeAll { $0 == projectID }
        _ = persistedAtoms.update(
            key: "project-order",
            value: .array(order.map(CodexJSONValue.string))
        )

        var changedKeys = ["remote-projects", "project-order"]
        var appearances = Self.appearances(
            persistedAtoms.snapshot["project-appearances"]
        )
        if appearances.removeValue(forKey: projectID) != nil {
            _ = persistedAtoms.update(
                key: "project-appearances",
                value: .object(appearances)
            )
            changedKeys.append("project-appearances")
        }
        await publishStateChange(changedKeys)
    }

    private func upsertRemote(_ request: Value) async throws {
        let fields = try Self.object(request)
        guard case let .integer(index)? = fields["index"], index >= 0,
              let projectValue = fields["project"]
        else {
            throw Error.invalidRequest
        }
        let project = try Self.remoteProject(from: projectValue)
        var projects = Self.remoteProjects(
            from: persistedAtoms.snapshot["remote-projects"]
        )
        projects.removeAll { $0.id == project.id }
        let insertionIndex = min(Int(index), projects.count)
        projects.insert(project, at: insertionIndex)
        _ = persistedAtoms.update(
            key: "remote-projects",
            value: .array(projects.map { Self.jsonValue($0.value) })
        )

        var order = Self.projectOrder(
            persistedAtoms.snapshot["project-order"]
        )
        order.removeAll { $0 == project.id }
        order.insert(project.id, at: min(Int(index), order.count))
        _ = persistedAtoms.update(
            key: "project-order",
            value: .array(order.map(CodexJSONValue.string))
        )
        await publishStateChange(["remote-projects", "project-order"])
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

    private static func nonemptyString(
        _ fields: [String: Value],
        key: String
    ) throws -> String {
        let value = try string(fields, key: key)
        guard !value.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty else {
            throw Error.invalidRequest
        }
        return value
    }

    private static func normalizedRemotePath(
        _ path: String
    ) throws -> String {
        let trimmed = path.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !trimmed.isEmpty else {
            throw Error.invalidRequest
        }
        let normalized = (trimmed as NSString).standardizingPath
        guard !normalized.isEmpty else {
            throw Error.invalidRequest
        }
        return normalized
    }

    private static func resolvedLabel(
        _ requestedLabel: String,
        remotePath: String
    ) -> String {
        let trimmed = requestedLabel.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard trimmed.isEmpty else {
            return trimmed
        }
        let fallback = (remotePath as NSString).lastPathComponent
        return fallback.isEmpty ? remotePath : fallback
    }

    private static func remoteProjects(
        from value: CodexJSONValue?
    ) -> [RemoteProject] {
        guard case let .array(values)? = value else {
            return []
        }
        return values.compactMap { value in
            guard case let .object(fields) = value,
                  case let .string(hostID)? = fields["hostId"],
                  case let .string(id)? = fields["id"],
                  case let .string(label)? = fields["label"],
                  case let .string(remotePath)? = fields["remotePath"],
                  !hostID.isEmpty,
                  !id.isEmpty,
                  !remotePath.isEmpty
            else {
                return nil
            }
            return RemoteProject(
                hostID: hostID,
                id: id,
                label: label,
                remotePath: remotePath
            )
        }
    }

    private static func remoteProject(
        from value: Value
    ) throws -> RemoteProject {
        let fields = try object(value)
        return RemoteProject(
            hostID: try nonemptyString(fields, key: "hostId"),
            id: try nonemptyString(fields, key: "id"),
            label: try nonemptyString(fields, key: "label"),
            remotePath: try normalizedRemotePath(
                nonemptyString(fields, key: "remotePath")
            )
        )
    }

    private static func projectOrder(
        _ value: CodexJSONValue?
    ) -> [String] {
        guard case let .array(values)? = value else {
            return []
        }
        return values.compactMap { value in
            guard case let .string(id) = value else { return nil }
            return id
        }
    }

    private static func appearances(
        _ value: CodexJSONValue?
    ) -> [String: CodexJSONValue] {
        guard case let .object(appearances)? = value else {
            return [:]
        }
        return appearances
    }

    private static func mergedProjectOrder(
        persistedOrder: [String],
        localProjectIDs: [String],
        remoteProjectIDs: Set<String>,
        prepending projectID: String? = nil
    ) -> [String] {
        let validIDs = remoteProjectIDs.union(localProjectIDs)
        var seen = Set<String>()
        var result: [String] = []
        for id in [projectID].compactMap({ $0 })
            + persistedOrder + localProjectIDs
            where validIDs.contains(id) && seen.insert(id).inserted
        {
            result.append(id)
        }
        return result
    }

    private static func jsonValue(_ value: Value) -> CodexJSONValue {
        switch value {
        case .null:
            .null
        case let .bool(value):
            .bool(value)
        case let .integer(value):
            .integer(value)
        case let .number(value):
            .number(value)
        case let .string(value):
            .string(value)
        case let .array(values):
            .array(values.map(jsonValue))
        case let .object(values):
            .object(values.mapValues(jsonValue))
        case .undefined,
             .rpcObject,
             .export,
             .import,
             .promise,
             .error,
             .bigInt,
             .positiveInfinity,
             .negativeInfinity,
             .nan:
            .null
        }
    }
}
