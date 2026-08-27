import Foundation

public enum CodexRemoteControlCoreEnvelopeError:
    Error,
    Equatable,
    Sendable
{
    case emptyRequestID
    case emptyWebSocketURL
    case emptyAccountID
    case emptyServerID
    case emptyEnvironmentID
    case emptyServerName
}

public struct CodexRemoteControlCoreEnrollmentKey:
    Equatable,
    Hashable,
    Sendable
{
    public let websocketURL: String
    public let accountID: String
    public let appServerClientName: String

    public init(
        websocketURL: String,
        accountID: String,
        appServerClientName: String? = nil
    ) {
        self.websocketURL = websocketURL
        self.accountID = accountID
        self.appServerClientName = appServerClientName ?? ""
    }

    fileprivate func validate() throws {
        guard !websocketURL.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty else {
            throw CodexRemoteControlCoreEnvelopeError.emptyWebSocketURL
        }
        guard !accountID.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty else {
            throw CodexRemoteControlCoreEnvelopeError.emptyAccountID
        }
    }
}

public struct CodexRemoteControlCoreEnrollmentLoadRequest:
    Equatable,
    Sendable
{
    public let requestID: String
    public let key: CodexRemoteControlCoreEnrollmentKey

    public init(
        requestID: String,
        key: CodexRemoteControlCoreEnrollmentKey
    ) {
        self.requestID = requestID
        self.key = key
    }

    public func encodedData() throws -> Data {
        guard !requestID.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty else {
            throw CodexRemoteControlCoreEnvelopeError.emptyRequestID
        }
        try key.validate()
        return try JSONEncoder().encode(
            Wire(
                id: requestID,
                method: "remote_control.enrollment.load",
                params: KeyWire(key)
            )
        )
    }

    private struct Wire: Encodable {
        let id: String
        let method: String
        let params: KeyWire
    }
}

public enum CodexRemoteControlCoreEnrollmentCommand:
    Equatable,
    Sendable
{
    case upsert(
        key: CodexRemoteControlCoreEnrollmentKey,
        serverID: String,
        environmentID: String,
        serverName: String,
        updatedAt: Int64,
        remoteControlEnabled: Bool?
    )
    case setEnabled(
        key: CodexRemoteControlCoreEnrollmentKey,
        enabled: Bool,
        updatedAt: Int64
    )
    case delete(key: CodexRemoteControlCoreEnrollmentKey)

    public func encodedData() throws -> Data {
        let encoder = JSONEncoder()
        switch self {
        case let .upsert(
            key,
            serverID,
            environmentID,
            serverName,
            updatedAt,
            remoteControlEnabled
        ):
            try key.validate()
            try Self.require(serverID, error: .emptyServerID)
            try Self.require(environmentID, error: .emptyEnvironmentID)
            try Self.require(serverName, error: .emptyServerName)
            return try encoder.encode(
                UpsertWire(
                    kind: "remote_control.enrollment.upsert",
                    key: key,
                    serverID: serverID,
                    environmentID: environmentID,
                    serverName: serverName,
                    updatedAt: updatedAt,
                    remoteControlEnabled: remoteControlEnabled
                )
            )
        case let .setEnabled(key, enabled, updatedAt):
            try key.validate()
            return try encoder.encode(
                SetEnabledWire(
                    kind: "remote_control.enrollment.set_enabled",
                    key: key,
                    enabled: enabled,
                    updatedAt: updatedAt
                )
            )
        case let .delete(key):
            try key.validate()
            return try encoder.encode(
                DeleteWire(
                    kind: "remote_control.enrollment.delete",
                    key: key
                )
            )
        }
    }

    private static func require(
        _ value: String,
        error: CodexRemoteControlCoreEnvelopeError
    ) throws {
        guard !value.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty else {
            throw error
        }
    }
}

@MainActor
public protocol CodexRemoteControlCoreEnrollmentTransport: AnyObject {
    func submit(
        _ command: CodexRemoteControlCoreEnrollmentCommand
    ) throws

    func request(
        _ request: CodexRemoteControlCoreEnrollmentLoadRequest
    ) throws -> Data
}

private struct KeyWire: Encodable {
    let websocketURL: String
    let accountID: String
    let appServerClientName: String

    init(_ key: CodexRemoteControlCoreEnrollmentKey) {
        websocketURL = key.websocketURL
        accountID = key.accountID
        appServerClientName = key.appServerClientName
    }

    enum CodingKeys: String, CodingKey {
        case websocketURL = "websocketUrl"
        case accountID = "accountId"
        case appServerClientName
    }
}

private struct UpsertWire: Encodable {
    let kind: String
    let websocketURL: String
    let accountID: String
    let appServerClientName: String
    let serverID: String
    let environmentID: String
    let serverName: String
    let updatedAt: Int64
    let remoteControlEnabled: Bool?

    init(
        kind: String,
        key: CodexRemoteControlCoreEnrollmentKey,
        serverID: String,
        environmentID: String,
        serverName: String,
        updatedAt: Int64,
        remoteControlEnabled: Bool?
    ) {
        self.kind = kind
        websocketURL = key.websocketURL
        accountID = key.accountID
        appServerClientName = key.appServerClientName
        self.serverID = serverID
        self.environmentID = environmentID
        self.serverName = serverName
        self.updatedAt = updatedAt
        self.remoteControlEnabled = remoteControlEnabled
    }

    enum CodingKeys: String, CodingKey {
        case kind
        case websocketURL = "websocketUrl"
        case accountID = "accountId"
        case appServerClientName
        case serverID = "serverId"
        case environmentID = "environmentId"
        case serverName
        case updatedAt
        case remoteControlEnabled
    }
}

private struct SetEnabledWire: Encodable {
    let kind: String
    let websocketURL: String
    let accountID: String
    let appServerClientName: String
    let enabled: Bool
    let updatedAt: Int64

    init(
        kind: String,
        key: CodexRemoteControlCoreEnrollmentKey,
        enabled: Bool,
        updatedAt: Int64
    ) {
        self.kind = kind
        websocketURL = key.websocketURL
        accountID = key.accountID
        appServerClientName = key.appServerClientName
        self.enabled = enabled
        self.updatedAt = updatedAt
    }

    enum CodingKeys: String, CodingKey {
        case kind
        case websocketURL = "websocketUrl"
        case accountID = "accountId"
        case appServerClientName
        case enabled
        case updatedAt
    }
}

private struct DeleteWire: Encodable {
    let kind: String
    let websocketURL: String
    let accountID: String
    let appServerClientName: String

    init(
        kind: String,
        key: CodexRemoteControlCoreEnrollmentKey
    ) {
        self.kind = kind
        websocketURL = key.websocketURL
        accountID = key.accountID
        appServerClientName = key.appServerClientName
    }

    enum CodingKeys: String, CodingKey {
        case kind
        case websocketURL = "websocketUrl"
        case accountID = "accountId"
        case appServerClientName
    }
}
