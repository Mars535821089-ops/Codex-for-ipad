#if SWIFT_PACKAGE
    import CodexPadDomain
#endif
import Foundation

/// The released desktop assignment object stored under
/// `thread-project-assignments`.
///
/// Thread and project identifiers are opaque. Desktop's normalizers preserve
/// their spelling rather than trimming, lowercasing, or requiring UUIDs.
public struct CodexDesktopThreadProjectAssignment:
    Codable,
    Equatable,
    Sendable
{
    public enum ProjectKind: String, Codable, Sendable {
        case local
        case remote
    }

    public enum ProjectOrigin: String, Codable, Sendable {
        case chatgpt
    }

    public let projectKind: ProjectKind
    public let projectID: String
    public let projectOrigin: ProjectOrigin?
    public let path: String?
    public let cwd: String?
    public let hostID: String?
    public let pendingCoreUpdate: Bool

    public static func local(
        projectID: String,
        projectOrigin: ProjectOrigin? = nil,
        path: String? = nil,
        cwd: String? = nil,
        pendingCoreUpdate: Bool
    ) -> Self {
        Self(
            projectKind: .local,
            projectID: projectID,
            projectOrigin: projectOrigin,
            path: path,
            cwd: cwd,
            hostID: nil,
            pendingCoreUpdate: pendingCoreUpdate
        )
    }

    public static func remote(
        projectID: String,
        path: String,
        cwd: String? = nil,
        hostID: String? = nil,
        pendingCoreUpdate: Bool
    ) -> Self {
        Self(
            projectKind: .remote,
            projectID: projectID,
            projectOrigin: nil,
            path: path,
            cwd: cwd,
            hostID: hostID,
            pendingCoreUpdate: pendingCoreUpdate
        )
    }

    public var globalStateValue: CodexJSONValue {
        var fields: [String: CodexJSONValue] = [
            "projectKind": .string(projectKind.rawValue),
            "projectId": .string(projectID),
            "pendingCoreUpdate": .bool(pendingCoreUpdate),
        ]
        switch projectKind {
        case .local:
            if let projectOrigin {
                fields["projectOrigin"] = .string(
                    projectOrigin.rawValue
                )
            }
        case .remote:
            if let hostID {
                fields["hostId"] = .string(hostID)
            }
        }
        if let path {
            fields["path"] = .string(path)
        }
        if let cwd {
            fields["cwd"] = .string(cwd)
        }
        return .object(fields)
    }

    private enum CodingKeys: String, CodingKey {
        case projectKind
        case projectID = "projectId"
        case projectOrigin
        case path
        case cwd
        case hostID = "hostId"
        case pendingCoreUpdate
    }

    private init(
        projectKind: ProjectKind,
        projectID: String,
        projectOrigin: ProjectOrigin?,
        path: String?,
        cwd: String?,
        hostID: String?,
        pendingCoreUpdate: Bool
    ) {
        self.projectKind = projectKind
        self.projectID = projectID
        self.projectOrigin = projectOrigin
        self.path = path
        self.cwd = cwd
        self.hostID = hostID
        self.pendingCoreUpdate = pendingCoreUpdate
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(
            keyedBy: CodingKeys.self
        )
        let projectKind = try container.decode(
            ProjectKind.self,
            forKey: .projectKind
        )
        let projectID = try container.decode(
            String.self,
            forKey: .projectID
        )
        let pendingCoreUpdate: Bool
        if container.contains(.pendingCoreUpdate) {
            pendingCoreUpdate = try container.decode(
                Bool.self,
                forKey: .pendingCoreUpdate
            )
        } else {
            pendingCoreUpdate = false
        }
        let path = try Self.optionalString(
            in: container,
            forKey: .path
        )
        let cwd = try Self.optionalString(
            in: container,
            forKey: .cwd
        )

        switch projectKind {
        case .local:
            let projectOrigin: ProjectOrigin?
            if container.contains(.projectOrigin) {
                projectOrigin = try container.decode(
                    ProjectOrigin.self,
                    forKey: .projectOrigin
                )
            } else {
                projectOrigin = nil
            }
            self.init(
                projectKind: .local,
                projectID: projectID,
                projectOrigin: projectOrigin,
                path: path,
                cwd: cwd,
                hostID: nil,
                pendingCoreUpdate: pendingCoreUpdate
            )
        case .remote:
            guard let path else {
                throw DecodingError.keyNotFound(
                    CodingKeys.path,
                    DecodingError.Context(
                        codingPath: decoder.codingPath,
                        debugDescription:
                            "Remote assignment requires path"
                    )
                )
            }
            let hostID = try Self.optionalString(
                in: container,
                forKey: .hostID
            )
            self.init(
                projectKind: .remote,
                projectID: projectID,
                projectOrigin: nil,
                path: path,
                cwd: cwd,
                hostID: hostID,
                pendingCoreUpdate: pendingCoreUpdate
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(
            keyedBy: CodingKeys.self
        )
        try container.encode(projectKind, forKey: .projectKind)
        try container.encode(projectID, forKey: .projectID)
        try container.encode(
            pendingCoreUpdate,
            forKey: .pendingCoreUpdate
        )
        try container.encodeIfPresent(path, forKey: .path)
        try container.encodeIfPresent(cwd, forKey: .cwd)
        switch projectKind {
        case .local:
            try container.encodeIfPresent(
                projectOrigin,
                forKey: .projectOrigin
            )
        case .remote:
            try container.encodeIfPresent(hostID, forKey: .hostID)
        }
    }

    private static func optionalString(
        in container:
            KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys
    ) throws -> String? {
        guard container.contains(key) else {
            return nil
        }
        return try container.decode(String.self, forKey: key)
    }
}

/// Persists the released thread-to-project assignment map and serializes it
/// directly into the desktop global-state value.
public final class CodexDesktopThreadProjectAssignmentStore:
    @unchecked Sendable
{
    public static let releasedStorageKey =
        "thread-project-assignments"

    private struct DynamicCodingKey: CodingKey {
        let stringValue: String
        let intValue: Int? = nil

        init?(stringValue: String) {
            self.stringValue = stringValue
        }

        init?(intValue: Int) {
            return nil
        }
    }

    private struct LossyAssignments: Decodable {
        let values: [String: CodexDesktopThreadProjectAssignment]

        init(from decoder: Decoder) throws {
            let container = try decoder.container(
                keyedBy: DynamicCodingKey.self
            )
            var values:
                [String: CodexDesktopThreadProjectAssignment] = [:]
            for key in container.allKeys where !key.stringValue.isEmpty {
                guard let assignment = try? container.decode(
                    CodexDesktopThreadProjectAssignment.self,
                    forKey: key
                ) else {
                    continue
                }
                values[key.stringValue] = assignment
            }
            self.values = values
        }
    }

    private let defaults: UserDefaults
    private let storageKey: String
    private let lock = NSLock()
    private var values:
        [String: CodexDesktopThreadProjectAssignment]

    public init(
        userDefaults: UserDefaults = .standard,
        storageKey: String =
            CodexDesktopThreadProjectAssignmentStore
                .releasedStorageKey
    ) {
        defaults = userDefaults
        self.storageKey = storageKey
        values = Self.decode(
            userDefaults.data(forKey: storageKey)
        )
    }

    public var assignments:
        [String: CodexDesktopThreadProjectAssignment]
    {
        withLock { values }
    }

    public func assignment(
        threadID: String
    ) -> CodexDesktopThreadProjectAssignment? {
        withLock { values[threadID] }
    }

    public var globalStateValue: CodexJSONValue {
        withLock {
            .object(
                values.mapValues(\.globalStateValue)
            )
        }
    }

    public func serialize() -> CodexJSONValue {
        globalStateValue
    }

    /// Stores or removes one assignment. An empty thread ID is rejected;
    /// every other identifier is preserved exactly as supplied by desktop.
    @discardableResult
    public func setAssignment(
        threadID: String,
        assignment:
            CodexDesktopThreadProjectAssignment?
    ) -> Bool {
        withLock {
            guard !threadID.isEmpty,
                  values[threadID] != assignment
            else {
                return false
            }
            if let assignment {
                values[threadID] = assignment
            } else {
                values.removeValue(forKey: threadID)
            }
            persistLocked()
            return true
        }
    }

    @discardableResult
    public func removeAssignment(
        threadID: String
    ) -> Bool {
        setAssignment(
            threadID: threadID,
            assignment: nil
        )
    }

    private func persistLocked() {
        guard let data = try? JSONEncoder().encode(values) else {
            return
        }
        defaults.set(data, forKey: storageKey)
    }

    private func withLock<T>(
        _ body: () throws -> T
    ) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    private static func decode(
        _ data: Data?
    ) -> [String: CodexDesktopThreadProjectAssignment] {
        guard let data,
              let decoded = try? JSONDecoder().decode(
                  LossyAssignments.self,
                  from: data
              )
        else {
            return [:]
        }
        return decoded.values
    }
}
