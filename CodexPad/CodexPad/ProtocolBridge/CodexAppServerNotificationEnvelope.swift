#if SWIFT_PACKAGE
import CodexPadDomain
#endif
import Foundation

public struct CodexThreadStartedNotification:
    Codable,
    Equatable,
    Sendable
{
    public let thread: CodexJSONValue

    public init(thread: CodexJSONValue) {
        self.thread = thread
    }
}

public struct CodexThreadStatusChangedNotification:
    Codable,
    Equatable,
    Sendable
{
    public let threadID: String
    public let status: CodexStoredThreadStatus

    public init(threadID: String, status: CodexStoredThreadStatus) {
        self.threadID = threadID
        self.status = status
    }

    private enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case status
    }
}

public struct CodexThreadClosedNotification:
    Codable,
    Equatable,
    Sendable
{
    public let threadID: String

    public init(threadID: String) {
        self.threadID = threadID
    }

    private enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
    }
}

public struct CodexThreadQueueChangedNotification:
    Codable,
    Equatable,
    Sendable
{
    public let threadID: String

    public init(threadID: String) {
        self.threadID = threadID
    }

    private enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
    }
}

public struct CodexThreadRevertedNotification:
    Codable,
    Equatable,
    Sendable
{
    public let threadID: String

    public init(threadID: String) {
        self.threadID = threadID
    }

    private enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
    }
}

public struct CodexThreadArchivedNotification:
    Codable,
    Equatable,
    Sendable
{
    public let threadID: String

    public init(threadID: String) {
        self.threadID = threadID
    }

    private enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
    }
}

public struct CodexThreadDeletedNotification:
    Codable,
    Equatable,
    Sendable
{
    public let threadID: String

    public init(threadID: String) {
        self.threadID = threadID
    }

    private enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
    }
}

public struct CodexThreadUnarchivedNotification:
    Codable,
    Equatable,
    Sendable
{
    public let threadID: String

    public init(threadID: String) {
        self.threadID = threadID
    }

    private enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
    }
}

public struct CodexThreadNameUpdatedNotification:
    Codable,
    Equatable,
    Sendable
{
    public let threadID: String
    public let threadName: String?

    public init(threadID: String, threadName: String?) {
        self.threadID = threadID
        self.threadName = threadName
    }

    private enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case threadName
    }
}

public struct CodexThreadGoalUpdatedNotification:
    Codable,
    Equatable,
    Sendable
{
    public let threadID: String
    public let turnID: String?
    /// Kept as JSON because goal fields can grow independently of the iPad
    /// domain model and this envelope must preserve the official payload.
    public let goal: CodexJSONValue

    public init(
        threadID: String,
        turnID: String?,
        goal: CodexJSONValue
    ) {
        self.threadID = threadID
        self.turnID = turnID
        self.goal = goal
    }

    private enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case turnID = "turnId"
        case goal
    }
}

public struct CodexThreadGoalClearedNotification:
    Codable,
    Equatable,
    Sendable
{
    public let threadID: String

    public init(threadID: String) {
        self.threadID = threadID
    }

    private enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
    }
}

public struct CodexSkillsChangedNotification:
    Codable,
    Equatable,
    Sendable
{
    public init() {}
}

public struct CodexEnvironmentConnectionNotification:
    Codable,
    Equatable,
    Sendable
{
    public let threadID: String
    public let environmentID: String

    public init(threadID: String, environmentID: String) {
        self.threadID = threadID
        self.environmentID = environmentID
    }

    private enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case environmentID = "environmentId"
    }
}

public enum CodexMCPServerStartupState:
    String,
    Codable,
    Equatable,
    Sendable
{
    case starting
    case ready
    case failed
    case cancelled
}

public enum CodexMCPServerStartupFailureReason:
    String,
    Codable,
    Equatable,
    Sendable
{
    case reauthenticationRequired
}

public struct CodexMCPServerStatusUpdatedNotification:
    Codable,
    Equatable,
    Sendable
{
    public let threadID: String?
    public let name: String
    public let status: CodexMCPServerStartupState
    public let error: String?
    public let failureReason: CodexMCPServerStartupFailureReason?

    public init(
        threadID: String?,
        name: String,
        status: CodexMCPServerStartupState,
        error: String?,
        failureReason: CodexMCPServerStartupFailureReason?
    ) {
        self.threadID = threadID
        self.name = name
        self.status = status
        self.error = error
        self.failureReason = failureReason
    }

    private enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case name
        case status
        case error
        case failureReason
    }
}

public struct CodexAccountRateLimitsUpdatedNotification:
    Codable,
    Equatable,
    Sendable
{
    /// The server's rate-limit snapshot is intentionally retained as JSON:
    /// the desktop protocol adds optional fields between releases.
    public let rateLimits: CodexJSONValue

    public init(rateLimits: CodexJSONValue) {
        self.rateLimits = rateLimits
    }

    private enum CodingKeys: String, CodingKey {
        case rateLimits
    }
}

public enum CodexModelRerouteReason:
    String,
    Codable,
    Equatable,
    Sendable
{
    case highRiskCyberActivity
}

public enum CodexModelVerification:
    String,
    Codable,
    Equatable,
    Sendable
{
    case trustedAccessForCyber
}

public struct CodexModelReroutedNotification:
    Codable,
    Equatable,
    Sendable
{
    public let threadID: String
    public let turnID: String
    public let fromModel: String
    public let toModel: String
    public let reason: CodexModelRerouteReason

    public init(
        threadID: String,
        turnID: String,
        fromModel: String,
        toModel: String,
        reason: CodexModelRerouteReason
    ) {
        self.threadID = threadID
        self.turnID = turnID
        self.fromModel = fromModel
        self.toModel = toModel
        self.reason = reason
    }

    private enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case turnID = "turnId"
        case fromModel
        case toModel
        case reason
    }
}

public struct CodexModelVerificationNotification:
    Codable,
    Equatable,
    Sendable
{
    public let threadID: String
    public let turnID: String
    public let verifications: [CodexModelVerification]

    public init(
        threadID: String,
        turnID: String,
        verifications: [CodexModelVerification]
    ) {
        self.threadID = threadID
        self.turnID = turnID
        self.verifications = verifications
    }

    private enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case turnID = "turnId"
        case verifications
    }
}

public struct CodexTurnModerationMetadataNotification:
    Codable,
    Equatable,
    Sendable
{
    public let threadID: String
    public let turnID: String
    public let metadata: CodexJSONValue

    public init(
        threadID: String,
        turnID: String,
        metadata: CodexJSONValue
    ) {
        self.threadID = threadID
        self.turnID = turnID
        self.metadata = metadata
    }

    private enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case turnID = "turnId"
        case metadata
    }
}

public struct CodexModelSafetyBufferingUpdatedNotification:
    Codable,
    Equatable,
    Sendable
{
    public let threadID: String
    public let turnID: String
    public let model: String
    public let useCases: [String]
    public let reasons: [String]
    public let showBufferingUI: Bool
    public let fasterModel: String?

    public init(
        threadID: String,
        turnID: String,
        model: String,
        useCases: [String],
        reasons: [String],
        showBufferingUI: Bool,
        fasterModel: String?
    ) {
        self.threadID = threadID
        self.turnID = turnID
        self.model = model
        self.useCases = useCases
        self.reasons = reasons
        self.showBufferingUI = showBufferingUI
        self.fasterModel = fasterModel
    }

    private enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case turnID = "turnId"
        case model
        case useCases
        case reasons
        case showBufferingUI = "showBufferingUi"
        case fasterModel
    }
}

public struct CodexTextPosition:
    Codable,
    Equatable,
    Sendable
{
    public let line: Int
    public let column: Int
}

public struct CodexTextRange:
    Codable,
    Equatable,
    Sendable
{
    public let start: CodexTextPosition
    public let end: CodexTextPosition
}

public struct CodexConfigWarningNotification:
    Codable,
    Equatable,
    Sendable
{
    public let summary: String
    public let details: String?
    public let path: String?
    public let range: CodexTextRange?
}

public enum CodexAppServerNotification:
    Equatable,
    Sendable
{
    case threadStarted(CodexThreadStartedNotification)
    case threadStatusChanged(CodexThreadStatusChangedNotification)
    case threadArchived(CodexThreadArchivedNotification)
    case threadDeleted(CodexThreadDeletedNotification)
    case threadUnarchived(CodexThreadUnarchivedNotification)
    case threadClosed(CodexThreadClosedNotification)
    case threadQueueChanged(CodexThreadQueueChangedNotification)
    case threadReverted(CodexThreadRevertedNotification)
    case threadNameUpdated(CodexThreadNameUpdatedNotification)
    case threadGoalUpdated(CodexThreadGoalUpdatedNotification)
    case threadGoalCleared(CodexThreadGoalClearedNotification)
    case skillsChanged(CodexSkillsChangedNotification)
    case environmentConnected(CodexEnvironmentConnectionNotification)
    case environmentDisconnected(CodexEnvironmentConnectionNotification)
    case mcpServerStatusUpdated(CodexMCPServerStatusUpdatedNotification)
    case accountRateLimitsUpdated(CodexAccountRateLimitsUpdatedNotification)
    case modelRerouted(CodexModelReroutedNotification)
    case modelVerification(CodexModelVerificationNotification)
    case turnModerationMetadata(CodexTurnModerationMetadataNotification)
    case modelSafetyBufferingUpdated(
        CodexModelSafetyBufferingUpdatedNotification
    )
    case configWarning(CodexConfigWarningNotification)
    case opaque(method: String, params: CodexJSONValue)

    public var method: String {
        switch self {
        case .threadStarted: return "thread/started"
        case .threadStatusChanged: return "thread/status/changed"
        case .threadArchived: return "thread/archived"
        case .threadDeleted: return "thread/deleted"
        case .threadUnarchived: return "thread/unarchived"
        case .threadClosed: return "thread/closed"
        case .threadQueueChanged: return "thread/queue/changed"
        case .threadReverted: return "thread/reverted"
        case .threadNameUpdated: return "thread/name/updated"
        case .threadGoalUpdated: return "thread/goal/updated"
        case .threadGoalCleared: return "thread/goal/cleared"
        case .skillsChanged: return "skills/changed"
        case .environmentConnected: return "thread/environment/connected"
        case .environmentDisconnected:
            return "thread/environment/disconnected"
        case .mcpServerStatusUpdated:
            return "mcpServer/startupStatus/updated"
        case .accountRateLimitsUpdated:
            return "account/rateLimits/updated"
        case .modelRerouted: return "model/rerouted"
        case .modelVerification: return "model/verification"
        case .turnModerationMetadata: return "turn/moderationMetadata"
        case .modelSafetyBufferingUpdated:
            return "model/safetyBuffering/updated"
        case .configWarning: return "configWarning"
        case let .opaque(method, _): return method
        }
    }

    public var params: CodexJSONValue {
        switch self {
        case let .threadStarted(value):
            return Self.json(value)
        case let .threadStatusChanged(value):
            return Self.json(value)
        case let .threadArchived(value):
            return Self.json(value)
        case let .threadDeleted(value):
            return Self.json(value)
        case let .threadUnarchived(value):
            return Self.json(value)
        case let .threadClosed(value):
            return Self.json(value)
        case let .threadQueueChanged(value):
            return Self.json(value)
        case let .threadReverted(value):
            return Self.json(value)
        case let .threadNameUpdated(value):
            return Self.json(value)
        case let .threadGoalUpdated(value):
            return Self.json(value)
        case let .threadGoalCleared(value):
            return Self.json(value)
        case let .skillsChanged(value):
            return Self.json(value)
        case let .environmentConnected(value),
             let .environmentDisconnected(value):
            return Self.json(value)
        case let .mcpServerStatusUpdated(value):
            return Self.json(value)
        case let .accountRateLimitsUpdated(value):
            return Self.json(value)
        case let .modelRerouted(value):
            return Self.json(value)
        case let .modelVerification(value):
            return Self.json(value)
        case let .turnModerationMetadata(value):
            return Self.json(value)
        case let .modelSafetyBufferingUpdated(value):
            return Self.json(value)
        case let .configWarning(value):
            return Self.json(value)
        case let .opaque(_, params):
            return params
        }
    }

    public init(data: Data) throws {
        let decoder = JSONDecoder()
        let envelope: WireEnvelope
        do {
            envelope = try decoder.decode(WireEnvelope.self, from: data)
        } catch {
            throw CodexCoreEnvelopeError.invalidEventPayload
        }
        guard let method = envelope.method,
              let params = envelope.params
        else {
            throw CodexCoreEnvelopeError.invalidEventPayload
        }
        do {
            switch method {
            case "thread/started":
                let value = try Self.decode(
                    CodexThreadStartedNotification.self,
                    params,
                    using: decoder
                )
                guard case let .object(thread) = value.thread,
                      case let .string(id)? = thread["id"],
                      !id.isEmpty
                else { throw CodexCoreEnvelopeError.invalidEventPayload }
                self = .threadStarted(value)
            case "thread/status/changed":
                let value = try Self.decode(
                    CodexThreadStatusChangedNotification.self,
                    params,
                    using: decoder
                )
                try Self.require(value.threadID)
                self = .threadStatusChanged(value)
            case "thread/archived":
                let value = try Self.decode(
                    CodexThreadArchivedNotification.self,
                    params,
                    using: decoder
                )
                try Self.require(value.threadID)
                self = .threadArchived(value)
            case "thread/deleted":
                let value = try Self.decode(
                    CodexThreadDeletedNotification.self,
                    params,
                    using: decoder
                )
                try Self.require(value.threadID)
                self = .threadDeleted(value)
            case "thread/unarchived":
                let value = try Self.decode(
                    CodexThreadUnarchivedNotification.self,
                    params,
                    using: decoder
                )
                try Self.require(value.threadID)
                self = .threadUnarchived(value)
            case "thread/closed":
                let value = try Self.decode(
                    CodexThreadClosedNotification.self,
                    params,
                    using: decoder
                )
                try Self.require(value.threadID)
                self = .threadClosed(value)
            case "thread/queue/changed":
                let value = try Self.decode(
                    CodexThreadQueueChangedNotification.self,
                    params,
                    using: decoder
                )
                try Self.require(value.threadID)
                self = .threadQueueChanged(value)
            case "thread/reverted":
                let value = try Self.decode(
                    CodexThreadRevertedNotification.self,
                    params,
                    using: decoder
                )
                try Self.require(value.threadID)
                self = .threadReverted(value)
            case "thread/name/updated":
                let value = try Self.decode(
                    CodexThreadNameUpdatedNotification.self,
                    params,
                    using: decoder
                )
                try Self.require(value.threadID)
                self = .threadNameUpdated(value)
            case "thread/goal/updated":
                let value = try Self.decode(
                    CodexThreadGoalUpdatedNotification.self,
                    params,
                    using: decoder
                )
                try Self.require(value.threadID)
                guard case .object = value.goal else {
                    throw CodexCoreEnvelopeError.invalidEventPayload
                }
                self = .threadGoalUpdated(value)
            case "thread/goal/cleared":
                let value = try Self.decode(
                    CodexThreadGoalClearedNotification.self,
                    params,
                    using: decoder
                )
                try Self.require(value.threadID)
                self = .threadGoalCleared(value)
            case "skills/changed":
                self = .skillsChanged(
                    try Self.decode(
                        CodexSkillsChangedNotification.self,
                        params,
                        using: decoder
                    )
                )
            case "thread/environment/connected":
                self = .environmentConnected(
                    try Self.environment(params, decoder: decoder)
                )
            case "thread/environment/disconnected":
                self = .environmentDisconnected(
                    try Self.environment(params, decoder: decoder)
                )
            case "mcpServer/startupStatus/updated":
                let value = try Self.decode(
                    CodexMCPServerStatusUpdatedNotification.self,
                    params,
                    using: decoder
                )
                try Self.require(value.name)
                self = .mcpServerStatusUpdated(value)
            case "account/rateLimits/updated":
                let value = try Self.decode(
                    CodexAccountRateLimitsUpdatedNotification.self,
                    params,
                    using: decoder
                )
                guard case .object = value.rateLimits else {
                    throw CodexCoreEnvelopeError.invalidEventPayload
                }
                self = .accountRateLimitsUpdated(value)
            case "model/rerouted":
                let value = try Self.decode(
                    CodexModelReroutedNotification.self,
                    params,
                    using: decoder
                )
                try Self.require(value.threadID)
                try Self.require(value.turnID)
                self = .modelRerouted(value)
            case "model/verification":
                let value = try Self.decode(
                    CodexModelVerificationNotification.self,
                    params,
                    using: decoder
                )
                try Self.require(value.threadID)
                try Self.require(value.turnID)
                self = .modelVerification(value)
            case "turn/moderationMetadata":
                let value = try Self.decode(
                    CodexTurnModerationMetadataNotification.self,
                    params,
                    using: decoder
                )
                try Self.require(value.threadID)
                try Self.require(value.turnID)
                self = .turnModerationMetadata(value)
            case "model/safetyBuffering/updated":
                let value = try Self.decode(
                    CodexModelSafetyBufferingUpdatedNotification.self,
                    params,
                    using: decoder
                )
                try Self.require(value.threadID)
                try Self.require(value.turnID)
                try Self.require(value.model)
                self = .modelSafetyBufferingUpdated(value)
            case "configWarning":
                self = .configWarning(
                    try Self.decode(
                        CodexConfigWarningNotification.self,
                        params,
                        using: decoder
                    )
                )
            default:
                guard !method.isEmpty, case .object = params else {
                    throw CodexCoreEnvelopeError.invalidEventPayload
                }
                self = .opaque(method: method, params: params)
            }
        } catch let error as CodexCoreEnvelopeError {
            throw error
        } catch {
            throw CodexCoreEnvelopeError.invalidEventPayload
        }
    }

    public func encodedData() throws -> Data {
        try JSONEncoder().encode(
            WireEnvelope(
                method: method,
                params: params
            )
        )
    }

    private struct WireEnvelope: Codable {
        let method: String?
        let params: CodexJSONValue?
    }

    private static func decode<T: Decodable>(
        _ type: T.Type,
        _ params: CodexJSONValue,
        using decoder: JSONDecoder
    ) throws -> T {
        try decoder.decode(type, from: JSONEncoder().encode(params))
    }

    private static func json<T: Encodable>(_ value: T) -> CodexJSONValue {
        (try? JSONDecoder().decode(
            CodexJSONValue.self,
            from: JSONEncoder().encode(value)
        )) ?? .null
    }

    private static func require(_ value: String) throws {
        guard !value.isEmpty else {
            throw CodexCoreEnvelopeError.invalidEventPayload
        }
    }

    private static func environment(
        _ params: CodexJSONValue,
        decoder: JSONDecoder
    ) throws -> CodexEnvironmentConnectionNotification {
        let value = try decode(
            CodexEnvironmentConnectionNotification.self,
            params,
            using: decoder
        )
        try require(value.threadID)
        try require(value.environmentID)
        return value
    }
}
