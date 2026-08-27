import Foundation

public enum CodexRemoteControlConnectionStatus: String, Codable, CaseIterable,
    Equatable, Sendable
{
    case disabled
    case connecting
    case connected
    case errored
}

public struct CodexRemoteControlEnableParams: Codable, Equatable, Sendable {
    public let ephemeral: Bool

    public init(ephemeral: Bool = false) {
        self.ephemeral = ephemeral
    }

    private enum CodingKeys: String, CodingKey {
        case ephemeral
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ephemeral = if container.contains(.ephemeral) {
            try container.decode(Bool.self, forKey: .ephemeral)
        } else {
            false
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if ephemeral {
            try container.encode(true, forKey: .ephemeral)
        }
    }
}

public typealias CodexNullableRemoteControlEnableParams =
    CodexRemoteControlEnableParams?

public struct CodexRemoteControlDisableParams: Codable, Equatable, Sendable {
    public let ephemeral: Bool

    public init(ephemeral: Bool = false) {
        self.ephemeral = ephemeral
    }

    private enum CodingKeys: String, CodingKey {
        case ephemeral
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ephemeral = if container.contains(.ephemeral) {
            try container.decode(Bool.self, forKey: .ephemeral)
        } else {
            false
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if ephemeral {
            try container.encode(true, forKey: .ephemeral)
        }
    }
}

public typealias CodexNullableRemoteControlDisableParams =
    CodexRemoteControlDisableParams?

public protocol CodexRemoteControlStatusFields: Sendable {
    var status: CodexRemoteControlConnectionStatus { get }
    var serverName: String { get }
    var installationId: String { get }
    var environmentId: String? { get }
}

public struct CodexRemoteControlStatusChangedNotification: Codable, Equatable,
    Sendable, CodexRemoteControlStatusFields
{
    public let status: CodexRemoteControlConnectionStatus
    public let serverName: String
    public let installationId: String
    public let environmentId: String?

    public init(
        status: CodexRemoteControlConnectionStatus,
        serverName: String,
        installationId: String,
        environmentId: String?
    ) {
        self.status = status
        self.serverName = serverName
        self.installationId = installationId
        self.environmentId = environmentId
    }

    private enum CodingKeys: String, CodingKey {
        case status
        case serverName
        case installationId
        case environmentId
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        status = try container.decode(
            CodexRemoteControlConnectionStatus.self,
            forKey: .status
        )
        serverName = try container.decode(String.self, forKey: .serverName)
        installationId = try container.decode(
            String.self,
            forKey: .installationId
        )
        environmentId = try container.decodeIfPresent(
            String.self,
            forKey: .environmentId
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(status, forKey: .status)
        try container.encode(serverName, forKey: .serverName)
        try container.encode(installationId, forKey: .installationId)
        try container.encodeRemoteControlNullable(
            environmentId,
            forKey: .environmentId
        )
    }
}

public struct CodexRemoteControlEnableResponse: Codable, Equatable, Sendable,
    CodexRemoteControlStatusFields
{
    public let status: CodexRemoteControlConnectionStatus
    public let serverName: String
    public let installationId: String
    public let environmentId: String?

    public init(
        status: CodexRemoteControlConnectionStatus,
        serverName: String,
        installationId: String,
        environmentId: String?
    ) {
        self.status = status
        self.serverName = serverName
        self.installationId = installationId
        self.environmentId = environmentId
    }

    public init(_ notification: CodexRemoteControlStatusChangedNotification) {
        self.init(
            status: notification.status,
            serverName: notification.serverName,
            installationId: notification.installationId,
            environmentId: notification.environmentId
        )
    }

    private enum CodingKeys: String, CodingKey {
        case status
        case serverName
        case installationId
        case environmentId
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        status = try container.decode(
            CodexRemoteControlConnectionStatus.self,
            forKey: .status
        )
        serverName = try container.decode(String.self, forKey: .serverName)
        installationId = try container.decode(
            String.self,
            forKey: .installationId
        )
        environmentId = try container.decodeIfPresent(
            String.self,
            forKey: .environmentId
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(status, forKey: .status)
        try container.encode(serverName, forKey: .serverName)
        try container.encode(installationId, forKey: .installationId)
        try container.encodeRemoteControlNullable(
            environmentId,
            forKey: .environmentId
        )
    }
}

public struct CodexRemoteControlDisableResponse: Codable, Equatable, Sendable,
    CodexRemoteControlStatusFields
{
    public let status: CodexRemoteControlConnectionStatus
    public let serverName: String
    public let installationId: String
    public let environmentId: String?

    public init(
        status: CodexRemoteControlConnectionStatus,
        serverName: String,
        installationId: String,
        environmentId: String?
    ) {
        self.status = status
        self.serverName = serverName
        self.installationId = installationId
        self.environmentId = environmentId
    }

    public init(_ notification: CodexRemoteControlStatusChangedNotification) {
        self.init(
            status: notification.status,
            serverName: notification.serverName,
            installationId: notification.installationId,
            environmentId: notification.environmentId
        )
    }

    private enum CodingKeys: String, CodingKey {
        case status
        case serverName
        case installationId
        case environmentId
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        status = try container.decode(
            CodexRemoteControlConnectionStatus.self,
            forKey: .status
        )
        serverName = try container.decode(String.self, forKey: .serverName)
        installationId = try container.decode(
            String.self,
            forKey: .installationId
        )
        environmentId = try container.decodeIfPresent(
            String.self,
            forKey: .environmentId
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(status, forKey: .status)
        try container.encode(serverName, forKey: .serverName)
        try container.encode(installationId, forKey: .installationId)
        try container.encodeRemoteControlNullable(
            environmentId,
            forKey: .environmentId
        )
    }
}

public struct CodexRemoteControlStatusReadResponse: Codable, Equatable, Sendable,
    CodexRemoteControlStatusFields
{
    public let status: CodexRemoteControlConnectionStatus
    public let serverName: String
    public let installationId: String
    public let environmentId: String?

    public init(
        status: CodexRemoteControlConnectionStatus,
        serverName: String,
        installationId: String,
        environmentId: String?
    ) {
        self.status = status
        self.serverName = serverName
        self.installationId = installationId
        self.environmentId = environmentId
    }

    public init(_ notification: CodexRemoteControlStatusChangedNotification) {
        self.init(
            status: notification.status,
            serverName: notification.serverName,
            installationId: notification.installationId,
            environmentId: notification.environmentId
        )
    }

    private enum CodingKeys: String, CodingKey {
        case status
        case serverName
        case installationId
        case environmentId
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        status = try container.decode(
            CodexRemoteControlConnectionStatus.self,
            forKey: .status
        )
        serverName = try container.decode(String.self, forKey: .serverName)
        installationId = try container.decode(
            String.self,
            forKey: .installationId
        )
        environmentId = try container.decodeIfPresent(
            String.self,
            forKey: .environmentId
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(status, forKey: .status)
        try container.encode(serverName, forKey: .serverName)
        try container.encode(installationId, forKey: .installationId)
        try container.encodeRemoteControlNullable(
            environmentId,
            forKey: .environmentId
        )
    }
}

public struct CodexRemoteControlPairingStartParams: Codable, Equatable, Sendable {
    public let manualCode: Bool

    public init(manualCode: Bool = false) {
        self.manualCode = manualCode
    }

    private enum CodingKeys: String, CodingKey {
        case manualCode
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        manualCode = if container.contains(.manualCode) {
            try container.decode(Bool.self, forKey: .manualCode)
        } else {
            false
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if manualCode {
            try container.encode(true, forKey: .manualCode)
        }
    }
}

public struct CodexRemoteControlPairingStartResponse: Codable, Equatable,
    Sendable
{
    public let pairingCode: String
    public let manualPairingCode: String?
    public let environmentId: String
    public let expiresAt: Int64

    public init(
        pairingCode: String,
        manualPairingCode: String?,
        environmentId: String,
        expiresAt: Int64
    ) {
        self.pairingCode = pairingCode
        self.manualPairingCode = manualPairingCode
        self.environmentId = environmentId
        self.expiresAt = expiresAt
    }

    private enum CodingKeys: String, CodingKey {
        case pairingCode
        case manualPairingCode
        case environmentId
        case expiresAt
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        pairingCode = try container.decode(String.self, forKey: .pairingCode)
        manualPairingCode = try container.decodeIfPresent(
            String.self,
            forKey: .manualPairingCode
        )
        environmentId = try container.decode(
            String.self,
            forKey: .environmentId
        )
        expiresAt = try container.decode(Int64.self, forKey: .expiresAt)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(pairingCode, forKey: .pairingCode)
        try container.encodeRemoteControlNullable(
            manualPairingCode,
            forKey: .manualPairingCode
        )
        try container.encode(environmentId, forKey: .environmentId)
        try container.encode(expiresAt, forKey: .expiresAt)
    }
}

public struct CodexRemoteControlPairingStatusParams: Codable, Equatable,
    Sendable
{
    public let pairingCode: String?
    public let manualPairingCode: String?

    public init(
        pairingCode: String? = nil,
        manualPairingCode: String? = nil
    ) {
        self.pairingCode = pairingCode
        self.manualPairingCode = manualPairingCode
    }

    private enum CodingKeys: String, CodingKey {
        case pairingCode
        case manualPairingCode
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        pairingCode = try container.decodeIfPresent(
            String.self,
            forKey: .pairingCode
        )
        manualPairingCode = try container.decodeIfPresent(
            String.self,
            forKey: .manualPairingCode
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeRemoteControlNullable(
            pairingCode,
            forKey: .pairingCode
        )
        try container.encodeRemoteControlNullable(
            manualPairingCode,
            forKey: .manualPairingCode
        )
    }
}

public struct CodexRemoteControlPairingStatusResponse: Codable, Equatable,
    Sendable
{
    public let claimed: Bool

    public init(claimed: Bool) {
        self.claimed = claimed
    }
}

public struct CodexRemoteControlClientsListParams: Codable, Equatable, Sendable {
    public let environmentId: String
    public let cursor: String?
    public let limit: UInt32?
    public let order: CodexRemoteControlClientsListOrder?

    public init(
        environmentId: String,
        cursor: String? = nil,
        limit: UInt32? = nil,
        order: CodexRemoteControlClientsListOrder? = nil
    ) {
        self.environmentId = environmentId
        self.cursor = cursor
        self.limit = limit
        self.order = order
    }

    private enum CodingKeys: String, CodingKey {
        case environmentId
        case cursor
        case limit
        case order
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        environmentId = try container.decode(
            String.self,
            forKey: .environmentId
        )
        cursor = try container.decodeIfPresent(String.self, forKey: .cursor)
        limit = try container.decodeIfPresent(UInt32.self, forKey: .limit)
        order = try container.decodeIfPresent(
            CodexRemoteControlClientsListOrder.self,
            forKey: .order
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(environmentId, forKey: .environmentId)
        try container.encodeRemoteControlNullable(cursor, forKey: .cursor)
        try container.encodeRemoteControlNullable(limit, forKey: .limit)
        try container.encodeRemoteControlNullable(order, forKey: .order)
    }
}

public enum CodexRemoteControlClientsListOrder: String, Codable, CaseIterable,
    Equatable, Sendable
{
    case asc
    case desc
}

public struct CodexRemoteControlClientsListResponse: Codable, Equatable,
    Sendable
{
    public let data: [CodexRemoteControlClient]
    public let nextCursor: String?

    public init(
        data: [CodexRemoteControlClient],
        nextCursor: String?
    ) {
        self.data = data
        self.nextCursor = nextCursor
    }

    private enum CodingKeys: String, CodingKey {
        case data
        case nextCursor
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        data = try container.decode(
            [CodexRemoteControlClient].self,
            forKey: .data
        )
        nextCursor = try container.decodeIfPresent(
            String.self,
            forKey: .nextCursor
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(data, forKey: .data)
        try container.encodeRemoteControlNullable(
            nextCursor,
            forKey: .nextCursor
        )
    }
}

public struct CodexRemoteControlClient: Codable, Equatable, Sendable {
    public let clientId: String
    public let displayName: String?
    public let deviceType: String?
    public let platform: String?
    public let osVersion: String?
    public let deviceModel: String?
    public let appVersion: String?
    public let lastSeenAt: Int64?

    public init(
        clientId: String,
        displayName: String?,
        deviceType: String?,
        platform: String?,
        osVersion: String?,
        deviceModel: String?,
        appVersion: String?,
        lastSeenAt: Int64?
    ) {
        self.clientId = clientId
        self.displayName = displayName
        self.deviceType = deviceType
        self.platform = platform
        self.osVersion = osVersion
        self.deviceModel = deviceModel
        self.appVersion = appVersion
        self.lastSeenAt = lastSeenAt
    }

    private enum CodingKeys: String, CodingKey {
        case clientId
        case displayName
        case deviceType
        case platform
        case osVersion
        case deviceModel
        case appVersion
        case lastSeenAt
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        clientId = try container.decode(String.self, forKey: .clientId)
        displayName = try container.decodeIfPresent(
            String.self,
            forKey: .displayName
        )
        deviceType = try container.decodeIfPresent(
            String.self,
            forKey: .deviceType
        )
        platform = try container.decodeIfPresent(
            String.self,
            forKey: .platform
        )
        osVersion = try container.decodeIfPresent(
            String.self,
            forKey: .osVersion
        )
        deviceModel = try container.decodeIfPresent(
            String.self,
            forKey: .deviceModel
        )
        appVersion = try container.decodeIfPresent(
            String.self,
            forKey: .appVersion
        )
        lastSeenAt = try container.decodeIfPresent(
            Int64.self,
            forKey: .lastSeenAt
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(clientId, forKey: .clientId)
        try container.encodeRemoteControlNullable(
            displayName,
            forKey: .displayName
        )
        try container.encodeRemoteControlNullable(
            deviceType,
            forKey: .deviceType
        )
        try container.encodeRemoteControlNullable(
            platform,
            forKey: .platform
        )
        try container.encodeRemoteControlNullable(
            osVersion,
            forKey: .osVersion
        )
        try container.encodeRemoteControlNullable(
            deviceModel,
            forKey: .deviceModel
        )
        try container.encodeRemoteControlNullable(
            appVersion,
            forKey: .appVersion
        )
        try container.encodeRemoteControlNullable(
            lastSeenAt,
            forKey: .lastSeenAt
        )
    }
}

public struct CodexRemoteControlClientsRevokeParams: Codable, Equatable,
    Sendable
{
    public let environmentId: String
    public let clientId: String

    public init(environmentId: String, clientId: String) {
        self.environmentId = environmentId
        self.clientId = clientId
    }
}

public struct CodexRemoteControlClientsRevokeResponse: Codable, Equatable,
    Sendable
{
    public init() {}
}

private extension KeyedEncodingContainer {
    mutating func encodeRemoteControlNullable<T: Encodable>(
        _ value: T?,
        forKey key: Key
    ) throws {
        if let value {
            try encode(value, forKey: key)
        } else {
            try encodeNil(forKey: key)
        }
    }
}
