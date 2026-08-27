import Foundation

#if SWIFT_PACKAGE
    import CodexPadDomain
#endif

public typealias CodexTurnReasoningSummary =
    CodexAppServerReasoningSummary

public struct CodexTurnStartParams: Equatable, Sendable {
    public var threadID: CodexStoredThreadID
    public var input: [CodexStoredUserInput]
    public var clientUserMessageID: CodexWireOptional<String>
    public var cwd: CodexWireOptional<String>
    public var approvalPolicy: CodexWireOptional<CodexAppServerAskForApproval>
    public var approvalsReviewer: CodexWireOptional<CodexAppServerApprovalsReviewer>
    public var sandboxPolicy: CodexWireOptional<CodexAppServerSandboxPolicy>
    public var model: CodexWireOptional<String>
    public var serviceTier: CodexWireOptional<String>
    public var effort: CodexWireOptional<String>
    public var summary: CodexWireOptional<CodexTurnReasoningSummary>
    public var collaborationMode:
        CodexWireOptional<CodexCollaborationMode>
    public var multiAgentMode:
        CodexWireOptional<CodexMultiAgentMode>
    public var personality: CodexWireOptional<CodexAppServerPersonality>
    public var outputSchema: CodexWireOptional<CodexJSONValue>
    public var additionalContext:
        CodexWireOptional<[String: CodexJSONValue]>
    public var environments: CodexWireOptional<[CodexJSONValue]>
    public var permissions: CodexWireOptional<String>
    public var responsesAPIClientMetadata:
        CodexWireOptional<[String: String]>
    public var runtimeWorkspaceRoots: CodexWireOptional<[String]>
    public var dynamicTools: CodexWireOptional<[CodexJSONValue]>
    public var selectedCapabilityRoots:
        CodexWireOptional<[CodexJSONValue]>

    public init(
        threadID: CodexStoredThreadID,
        input: [CodexStoredUserInput],
        clientUserMessageID: CodexWireOptional<String> = .omitted,
        cwd: CodexWireOptional<String> = .omitted,
        approvalPolicy:
            CodexWireOptional<CodexAppServerAskForApproval> = .omitted,
        approvalsReviewer:
            CodexWireOptional<CodexAppServerApprovalsReviewer> = .omitted,
        sandboxPolicy:
            CodexWireOptional<CodexAppServerSandboxPolicy> = .omitted,
        model: CodexWireOptional<String> = .omitted,
        serviceTier: CodexWireOptional<String> = .omitted,
        effort: CodexWireOptional<String> = .omitted,
        summary:
            CodexWireOptional<CodexTurnReasoningSummary> = .omitted,
        collaborationMode:
            CodexWireOptional<CodexCollaborationMode> = .omitted,
        multiAgentMode:
            CodexWireOptional<CodexMultiAgentMode> = .omitted,
        personality:
            CodexWireOptional<CodexAppServerPersonality> = .omitted,
        outputSchema:
            CodexWireOptional<CodexJSONValue> = .omitted,
        additionalContext:
            CodexWireOptional<[String: CodexJSONValue]> = .omitted,
        environments:
            CodexWireOptional<[CodexJSONValue]> = .omitted,
        permissions: CodexWireOptional<String> = .omitted,
        responsesAPIClientMetadata:
            CodexWireOptional<[String: String]> = .omitted,
        runtimeWorkspaceRoots:
            CodexWireOptional<[String]> = .omitted,
        dynamicTools:
            CodexWireOptional<[CodexJSONValue]> = .omitted,
        selectedCapabilityRoots:
            CodexWireOptional<[CodexJSONValue]> = .omitted
    ) {
        self.threadID = threadID
        self.input = input
        self.clientUserMessageID = clientUserMessageID
        self.cwd = cwd
        self.approvalPolicy = approvalPolicy
        self.approvalsReviewer = approvalsReviewer
        self.sandboxPolicy = sandboxPolicy
        self.model = model
        self.serviceTier = serviceTier
        self.effort = effort
        self.summary = summary
        self.collaborationMode = collaborationMode
        self.multiAgentMode = multiAgentMode
        self.personality = personality
        self.outputSchema = outputSchema
        self.additionalContext = additionalContext
        self.environments = environments
        self.permissions = permissions
        self.responsesAPIClientMetadata = responsesAPIClientMetadata
        self.runtimeWorkspaceRoots = runtimeWorkspaceRoots
        self.dynamicTools = dynamicTools
        self.selectedCapabilityRoots = selectedCapabilityRoots
    }
}

public struct CodexTurnSteerParams: Equatable, Sendable {
    public let threadID: CodexStoredThreadID
    public let clientUserMessageID: CodexWireOptional<String>
    public let input: [CodexStoredUserInput]
    public let expectedTurnID: String

    public init(
        threadID: CodexStoredThreadID,
        clientUserMessageID: CodexWireOptional<String> = .omitted,
        input: [CodexStoredUserInput],
        expectedTurnID: String
    ) {
        self.threadID = threadID
        self.clientUserMessageID = clientUserMessageID
        self.input = input
        self.expectedTurnID = expectedTurnID
    }
}

public struct CodexTurnSteerResult: Codable, Equatable, Sendable {
    public let turnID: String

    public init(turnID: String) {
        self.turnID = turnID
    }

    private enum CodingKeys: String, CodingKey {
        case turnID = "turnId"
    }
}

public enum CodexAppServerTurnEnvelopeError:
    Error,
    Equatable,
    Sendable
{
    case invalidTurnStartParams
    case invalidTurnStartParam(String)
    case invalidTurnSteerParams
}

/// Decodes the released renderer's JSON-valued `turn/start` params while
/// preserving the app-server distinction between omission, null, and value.
public enum CodexAppServerTurnStartParamsDecoder {
    public static func decode(
        _ params: CodexJSONValue?
    ) throws -> CodexTurnStartParams {
        guard case let .object(fields)? = params,
              case let .string(threadID)? = fields["threadId"],
              let inputValue = fields["input"]
        else {
            throw CodexAppServerTurnEnvelopeError.invalidTurnStartParams
        }

        return CodexTurnStartParams(
            threadID: CodexStoredThreadID(rawValue: threadID),
            input: try decodeRequired(
                inputValue,
                key: "input",
                as: [CodexStoredUserInput].self
            ),
            clientUserMessageID: try decodeOptional(
                fields,
                key: "clientUserMessageId",
                as: String.self
            ),
            cwd: try decodeOptional(fields, key: "cwd", as: String.self),
            approvalPolicy: try decodeOptional(
                fields,
                key: "approvalPolicy",
                as: CodexAppServerAskForApproval.self
            ),
            approvalsReviewer: try decodeOptional(
                fields,
                key: "approvalsReviewer",
                as: CodexAppServerApprovalsReviewer.self
            ),
            sandboxPolicy: try decodeOptional(
                fields,
                key: "sandboxPolicy",
                as: CodexAppServerSandboxPolicy.self
            ),
            model: try decodeOptional(fields, key: "model", as: String.self),
            serviceTier: try decodeOptional(
                fields,
                key: "serviceTier",
                as: String.self
            ),
            effort: try decodeOptional(fields, key: "effort", as: String.self),
            summary: try decodeOptional(
                fields,
                key: "summary",
                as: CodexTurnReasoningSummary.self
            ),
            collaborationMode: try decodeOptional(
                fields,
                key: "collaborationMode",
                as: CodexCollaborationMode.self
            ),
            multiAgentMode: try decodeOptional(
                fields,
                key: "multiAgentMode",
                as: CodexMultiAgentMode.self
            ),
            personality: try decodeOptional(
                fields,
                key: "personality",
                as: CodexAppServerPersonality.self
            ),
            outputSchema: try decodeOptional(
                fields,
                key: "outputSchema",
                as: CodexJSONValue.self
            ),
            additionalContext: try decodeOptional(
                fields,
                key: "additionalContext",
                as: [String: CodexJSONValue].self
            ),
            environments: try decodeOptional(
                fields,
                key: "environments",
                as: [CodexJSONValue].self
            ),
            permissions: try decodeOptional(
                fields,
                key: "permissions",
                as: String.self
            ),
            responsesAPIClientMetadata: try decodeOptional(
                fields,
                key: "responsesapiClientMetadata",
                as: [String: String].self
            ),
            runtimeWorkspaceRoots: try decodeOptional(
                fields,
                key: "runtimeWorkspaceRoots",
                as: [String].self
            ),
            dynamicTools: try decodeOptional(
                fields,
                key: "dynamicTools",
                as: [CodexJSONValue].self
            ),
            selectedCapabilityRoots: try decodeOptional(
                fields,
                key: "selectedCapabilityRoots",
                as: [CodexJSONValue].self
            )
        )
    }

    private static func decodeOptional<Value>(
        _ fields: [String: CodexJSONValue],
        key: String,
        as type: Value.Type
    ) throws -> CodexWireOptional<Value>
    where Value: Decodable & Equatable & Sendable {
        guard let value = fields[key] else {
            return .omitted
        }
        if case .null = value {
            return .null
        }
        return .value(
            try decodeRequired(value, key: key, as: type)
        )
    }

    private static func decodeRequired<Value>(
        _ value: CodexJSONValue,
        key: String,
        as type: Value.Type
    ) throws -> Value
    where Value: Decodable {
        do {
            return try JSONDecoder().decode(
                type,
                from: JSONEncoder().encode(value)
            )
        } catch {
            throw CodexAppServerTurnEnvelopeError
                .invalidTurnStartParam(key)
        }
    }
}

public enum CodexAppServerTurnSteerParamsDecoder {
    public static func decode(
        _ params: CodexJSONValue?
    ) throws -> CodexTurnSteerParams {
        guard case let .object(fields)? = params,
              case let .string(threadID)? = fields["threadId"],
              case let .array(inputValues)? = fields["input"],
              case let .string(expectedTurnID)? =
                  fields["expectedTurnId"],
              !threadID.isEmpty,
              !expectedTurnID.isEmpty
        else {
            throw CodexAppServerTurnEnvelopeError
                .invalidTurnSteerParams
        }

        let input: [CodexStoredUserInput]
        do {
            input = try JSONDecoder().decode(
                [CodexStoredUserInput].self,
                from: JSONEncoder().encode(
                    CodexJSONValue.array(inputValues)
                )
            )
        } catch {
            throw CodexAppServerTurnEnvelopeError
                .invalidTurnSteerParams
        }

        let clientUserMessageID: CodexWireOptional<String>
        switch fields["clientUserMessageId"] {
        case nil:
            clientUserMessageID = .omitted
        case .null?:
            clientUserMessageID = .null
        case let .string(value)?:
            clientUserMessageID = .value(value)
        default:
            throw CodexAppServerTurnEnvelopeError
                .invalidTurnSteerParams
        }

        return CodexTurnSteerParams(
            threadID: CodexStoredThreadID(rawValue: threadID),
            clientUserMessageID: clientUserMessageID,
            input: input,
            expectedTurnID: expectedTurnID
        )
    }
}

public enum CodexAppServerTurnRequest: Equatable, Sendable {
    case start(id: CodexAppServerRequestID, params: CodexTurnStartParams)

    public func encodedData() throws -> Data {
        switch self {
        case .start(let id, let params):
            return try encodeTurnWire(
                TurnRequestEnvelope(
                    id: id,
                    method: "turn/start",
                    params: TurnStartWire(params)
                )
            )
        }
    }
}

public struct CodexTurnStartResult: Codable, Equatable, Sendable {
    public let turn: CodexStoredTurn

    public init(turn: CodexStoredTurn) {
        self.turn = turn
    }
}

public enum CodexReviewDelivery:
    String,
    Codable,
    Equatable,
    Sendable
{
    case inline
    case detached
}

public enum CodexReviewTarget: Equatable, Sendable {
    case uncommittedChanges
    case baseBranch(branch: String)
    case commit(sha: String, title: String?)
    case custom(instructions: String)
}

public struct CodexReviewStartParams: Equatable, Sendable {
    public let threadID: CodexStoredThreadID
    public let target: CodexReviewTarget
    public let delivery: CodexReviewDelivery

    public init(
        threadID: CodexStoredThreadID,
        target: CodexReviewTarget,
        delivery: CodexReviewDelivery = .inline
    ) {
        self.threadID = threadID
        self.target = target
        self.delivery = delivery
    }
}

public struct CodexReviewStartResult: Codable, Equatable, Sendable {
    public let turn: CodexStoredTurn
    public let reviewThreadID: CodexStoredThreadID

    public init(
        turn: CodexStoredTurn,
        reviewThreadID: CodexStoredThreadID
    ) {
        self.turn = turn
        self.reviewThreadID = reviewThreadID
    }

    private enum CodingKeys: String, CodingKey {
        case turn
        case reviewThreadID = "reviewThreadId"
    }
}

public struct CodexTurnStartedNotification:
    Codable,
    Equatable,
    Sendable
{
    public let threadID: CodexStoredThreadID
    public let turn: CodexStoredTurn

    public init(threadID: CodexStoredThreadID, turn: CodexStoredTurn) {
        self.threadID = threadID
        self.turn = turn
    }

    private enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case turn
    }
}

public struct CodexItemStartedNotification:
    Codable,
    Equatable,
    Sendable
{
    public let item: CodexStoredThreadItem
    public let threadID: CodexStoredThreadID
    public let turnID: String
    public let startedAtMs: Int64

    public init(
        item: CodexStoredThreadItem,
        threadID: CodexStoredThreadID,
        turnID: String,
        startedAtMs: Int64
    ) {
        self.item = item
        self.threadID = threadID
        self.turnID = turnID
        self.startedAtMs = startedAtMs
    }

    private enum CodingKeys: String, CodingKey {
        case item
        case threadID = "threadId"
        case turnID = "turnId"
        case startedAtMs
    }
}

public struct CodexAgentMessageDeltaNotification:
    Codable,
    Equatable,
    Sendable
{
    public let threadID: CodexStoredThreadID
    public let turnID: String
    public let itemID: String
    public let delta: String

    public init(
        threadID: CodexStoredThreadID,
        turnID: String,
        itemID: String,
        delta: String
    ) {
        self.threadID = threadID
        self.turnID = turnID
        self.itemID = itemID
        self.delta = delta
    }

    private enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case turnID = "turnId"
        case itemID = "itemId"
        case delta
    }
}

public struct CodexReasoningSummaryTextDeltaNotification:
    Codable,
    Equatable,
    Sendable
{
    public let threadID: CodexStoredThreadID
    public let turnID: String
    public let itemID: String
    public let summaryIndex: Int64
    public let delta: String

    public init(
        threadID: CodexStoredThreadID,
        turnID: String,
        itemID: String,
        summaryIndex: Int64,
        delta: String
    ) {
        self.threadID = threadID
        self.turnID = turnID
        self.itemID = itemID
        self.summaryIndex = summaryIndex
        self.delta = delta
    }

    private enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case turnID = "turnId"
        case itemID = "itemId"
        case summaryIndex
        case delta
    }
}

public struct CodexReasoningSummaryPartAddedNotification:
    Codable,
    Equatable,
    Sendable
{
    public let threadID: CodexStoredThreadID
    public let turnID: String
    public let itemID: String
    public let summaryIndex: Int64

    public init(
        threadID: CodexStoredThreadID,
        turnID: String,
        itemID: String,
        summaryIndex: Int64
    ) {
        self.threadID = threadID
        self.turnID = turnID
        self.itemID = itemID
        self.summaryIndex = summaryIndex
    }

    private enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case turnID = "turnId"
        case itemID = "itemId"
        case summaryIndex
    }
}

public struct CodexReasoningTextDeltaNotification:
    Codable,
    Equatable,
    Sendable
{
    public let threadID: CodexStoredThreadID
    public let turnID: String
    public let itemID: String
    public let contentIndex: Int64
    public let delta: String

    public init(
        threadID: CodexStoredThreadID,
        turnID: String,
        itemID: String,
        contentIndex: Int64,
        delta: String
    ) {
        self.threadID = threadID
        self.turnID = turnID
        self.itemID = itemID
        self.contentIndex = contentIndex
        self.delta = delta
    }

    private enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case turnID = "turnId"
        case itemID = "itemId"
        case contentIndex
        case delta
    }
}

/// Incremental content for a proposed-plan item.
///
/// This is intentionally distinct from `turn/plan/updated` (the legacy
/// update_plan tool stream) and from agent-message deltas.  The released
/// desktop app uses `item/plan/delta` for the experimental proposed-plan
/// collaboration mode.
public struct CodexPlanDeltaNotification:
    Codable,
    Equatable,
    Sendable
{
    public let threadID: CodexStoredThreadID
    public let turnID: String
    public let itemID: String
    public let delta: String

    public init(
        threadID: CodexStoredThreadID,
        turnID: String,
        itemID: String,
        delta: String
    ) {
        self.threadID = threadID
        self.turnID = turnID
        self.itemID = itemID
        self.delta = delta
    }

    private enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case turnID = "turnId"
        case itemID = "itemId"
        case delta
    }
}

public struct CodexItemCompletedNotification:
    Codable,
    Equatable,
    Sendable
{
    public let item: CodexStoredThreadItem
    public let threadID: CodexStoredThreadID
    public let turnID: String
    public let completedAtMs: Int64

    public init(
        item: CodexStoredThreadItem,
        threadID: CodexStoredThreadID,
        turnID: String,
        completedAtMs: Int64
    ) {
        self.item = item
        self.threadID = threadID
        self.turnID = turnID
        self.completedAtMs = completedAtMs
    }

    private enum CodingKeys: String, CodingKey {
        case item
        case threadID = "threadId"
        case turnID = "turnId"
        case completedAtMs
    }
}

public struct CodexTokenUsageBreakdown:
    Codable,
    Equatable,
    Sendable
{
    public let totalTokens: Int64
    public let inputTokens: Int64
    public let cachedInputTokens: Int64
    public let cacheWriteInputTokens: Int64
    public let outputTokens: Int64
    public let reasoningOutputTokens: Int64

    public init(
        totalTokens: Int64,
        inputTokens: Int64,
        cachedInputTokens: Int64,
        cacheWriteInputTokens: Int64 = 0,
        outputTokens: Int64,
        reasoningOutputTokens: Int64
    ) {
        self.totalTokens = totalTokens
        self.inputTokens = inputTokens
        self.cachedInputTokens = cachedInputTokens
        self.cacheWriteInputTokens = cacheWriteInputTokens
        self.outputTokens = outputTokens
        self.reasoningOutputTokens = reasoningOutputTokens
    }

}

public struct CodexThreadTokenUsage:
    Codable,
    Equatable,
    Sendable
{
    public let total: CodexTokenUsageBreakdown
    public let last: CodexTokenUsageBreakdown
    public let modelContextWindow: Int64?

    public init(
        total: CodexTokenUsageBreakdown,
        last: CodexTokenUsageBreakdown,
        modelContextWindow: Int64?
    ) {
        self.total = total
        self.last = last
        self.modelContextWindow = modelContextWindow
    }
}

public struct CodexThreadTokenUsageUpdatedNotification:
    Codable,
    Equatable,
    Sendable
{
    public let threadID: CodexStoredThreadID
    public let turnID: String
    public let tokenUsage: CodexThreadTokenUsage

    public init(
        threadID: CodexStoredThreadID,
        turnID: String,
        tokenUsage: CodexThreadTokenUsage
    ) {
        self.threadID = threadID
        self.turnID = turnID
        self.tokenUsage = tokenUsage
    }

    private enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case turnID = "turnId"
        case tokenUsage
    }
}

public struct CodexTurnCompletedNotification:
    Codable,
    Equatable,
    Sendable
{
    public let threadID: CodexStoredThreadID
    public let turn: CodexStoredTurn

    public init(threadID: CodexStoredThreadID, turn: CodexStoredTurn) {
        self.threadID = threadID
        self.turn = turn
    }

    private enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case turn
    }
}

public struct CodexTurnDiffUpdatedNotification:
    Codable,
    Equatable,
    Sendable
{
    public let threadID: CodexStoredThreadID
    public let turnID: String
    public let diff: String

    public init(
        threadID: CodexStoredThreadID,
        turnID: String,
        diff: String
    ) {
        self.threadID = threadID
        self.turnID = turnID
        self.diff = diff
    }

    private enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case turnID = "turnId"
        case diff
    }
}

public struct CodexRawResponseItem:
    Codable,
    Equatable,
    Sendable
{
    public let values: [String: CodexJSONValue]

    public init(values: [String: CodexJSONValue]) {
        self.values = values
    }

    public init(from decoder: any Decoder) throws {
        let rawValue = try CodexJSONValue(from: decoder)
        guard case .object(let values) = rawValue else {
            throw DecodingError.typeMismatch(
                [String: CodexJSONValue].self,
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription:
                        "Raw response item must be a JSON object"
                )
            )
        }
        self.values = values
    }

    public func encode(to encoder: any Encoder) throws {
        try CodexJSONValue.object(values).encode(to: encoder)
    }
}

public struct CodexRawResponseItemCompletedNotification:
    Codable,
    Equatable,
    Sendable
{
    public let threadID: CodexStoredThreadID
    public let turnID: String
    public let item: CodexRawResponseItem

    public init(
        threadID: CodexStoredThreadID,
        turnID: String,
        item: CodexRawResponseItem
    ) {
        self.threadID = threadID
        self.turnID = turnID
        self.item = item
    }

    private enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case turnID = "turnId"
        case item
    }
}

public struct CodexRawResponseCompletedNotification:
    Codable,
    Equatable,
    Sendable
{
    public let threadID: CodexStoredThreadID
    public let turnID: String
    public let responseID: String
    public let usage: CodexTokenUsageBreakdown?

    public init(
        threadID: CodexStoredThreadID,
        turnID: String,
        responseID: String,
        usage: CodexTokenUsageBreakdown?
    ) {
        self.threadID = threadID
        self.turnID = turnID
        self.responseID = responseID
        self.usage = usage
    }

    private enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case turnID = "turnId"
        case responseID = "responseId"
        case usage
    }
}

public struct CodexTurnErrorNotification:
    Codable,
    Equatable,
    Sendable
{
    public let error: CodexStoredTurnError
    public let willRetry: Bool
    public let threadID: CodexStoredThreadID
    public let turnID: String

    public init(
        error: CodexStoredTurnError,
        willRetry: Bool,
        threadID: CodexStoredThreadID,
        turnID: String
    ) {
        self.error = error
        self.willRetry = willRetry
        self.threadID = threadID
        self.turnID = turnID
    }

    private enum CodingKeys: String, CodingKey {
        case error
        case willRetry
        case threadID = "threadId"
        case turnID = "turnId"
    }
}

public struct CodexHookNotification:
    Codable,
    Equatable,
    Sendable
{
    public let threadID: CodexStoredThreadID
    public let turnID: String?
    public let run: CodexJSONValue

    public init(
        threadID: CodexStoredThreadID,
        turnID: String?,
        run: CodexJSONValue
    ) {
        self.threadID = threadID
        self.turnID = turnID
        self.run = run
    }

    private enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case turnID = "turnId"
        case run
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard container.contains(.turnID) else {
            throw DecodingError.keyNotFound(
                CodingKeys.turnID,
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription: "turnId is required, including null"
                )
            )
        }
        threadID = try container.decode(
            CodexStoredThreadID.self,
            forKey: .threadID
        )
        turnID = try container.decodeIfPresent(String.self, forKey: .turnID)
        run = try container.decode(CodexJSONValue.self, forKey: .run)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(threadID, forKey: .threadID)
        if let turnID {
            try container.encode(turnID, forKey: .turnID)
        } else {
            try container.encodeNil(forKey: .turnID)
        }
        try container.encode(run, forKey: .run)
    }
}

public struct CodexAutoApprovalReviewStartedNotification:
    Codable,
    Equatable,
    Sendable
{
    public let threadID: CodexStoredThreadID
    public let turnID: String
    public let startedAtMs: Int64
    public let reviewID: String
    public let targetItemID: String?
    public let review: CodexJSONValue
    public let action: CodexJSONValue

    private enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case turnID = "turnId"
        case startedAtMs
        case reviewID = "reviewId"
        case targetItemID = "targetItemId"
        case review
        case action
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard container.contains(.targetItemID) else {
            throw DecodingError.keyNotFound(
                CodingKeys.targetItemID,
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription:
                        "targetItemId is required, including null"
                )
            )
        }
        threadID = try container.decode(
            CodexStoredThreadID.self,
            forKey: .threadID
        )
        turnID = try container.decode(String.self, forKey: .turnID)
        startedAtMs = try container.decode(Int64.self, forKey: .startedAtMs)
        reviewID = try container.decode(String.self, forKey: .reviewID)
        targetItemID = try container.decodeIfPresent(
            String.self,
            forKey: .targetItemID
        )
        review = try container.decode(CodexJSONValue.self, forKey: .review)
        action = try container.decode(CodexJSONValue.self, forKey: .action)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(threadID, forKey: .threadID)
        try container.encode(turnID, forKey: .turnID)
        try container.encode(startedAtMs, forKey: .startedAtMs)
        try container.encode(reviewID, forKey: .reviewID)
        if let targetItemID {
            try container.encode(targetItemID, forKey: .targetItemID)
        } else {
            try container.encodeNil(forKey: .targetItemID)
        }
        try container.encode(review, forKey: .review)
        try container.encode(action, forKey: .action)
    }
}

public struct CodexAutoApprovalReviewCompletedNotification:
    Codable,
    Equatable,
    Sendable
{
    public let threadID: CodexStoredThreadID
    public let turnID: String
    public let startedAtMs: Int64
    public let completedAtMs: Int64
    public let reviewID: String
    public let targetItemID: String?
    public let decisionSource: CodexJSONValue
    public let review: CodexJSONValue
    public let action: CodexJSONValue

    private enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case turnID = "turnId"
        case startedAtMs
        case completedAtMs
        case reviewID = "reviewId"
        case targetItemID = "targetItemId"
        case decisionSource
        case review
        case action
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard container.contains(.targetItemID) else {
            throw DecodingError.keyNotFound(
                CodingKeys.targetItemID,
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription:
                        "targetItemId is required, including null"
                )
            )
        }
        threadID = try container.decode(
            CodexStoredThreadID.self,
            forKey: .threadID
        )
        turnID = try container.decode(String.self, forKey: .turnID)
        startedAtMs = try container.decode(Int64.self, forKey: .startedAtMs)
        completedAtMs = try container.decode(
            Int64.self,
            forKey: .completedAtMs
        )
        reviewID = try container.decode(String.self, forKey: .reviewID)
        targetItemID = try container.decodeIfPresent(
            String.self,
            forKey: .targetItemID
        )
        decisionSource = try container.decode(
            CodexJSONValue.self,
            forKey: .decisionSource
        )
        review = try container.decode(CodexJSONValue.self, forKey: .review)
        action = try container.decode(CodexJSONValue.self, forKey: .action)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(threadID, forKey: .threadID)
        try container.encode(turnID, forKey: .turnID)
        try container.encode(startedAtMs, forKey: .startedAtMs)
        try container.encode(completedAtMs, forKey: .completedAtMs)
        try container.encode(reviewID, forKey: .reviewID)
        if let targetItemID {
            try container.encode(targetItemID, forKey: .targetItemID)
        } else {
            try container.encodeNil(forKey: .targetItemID)
        }
        try container.encode(decisionSource, forKey: .decisionSource)
        try container.encode(review, forKey: .review)
        try container.encode(action, forKey: .action)
    }
}

public struct CodexTurnPlanStep:
    Codable,
    Equatable,
    Sendable
{
    public let step: String
    public let status: String

    public init(step: String, status: String) {
        self.step = step
        self.status = status
    }
}

public struct CodexTurnPlanUpdatedNotification:
    Codable,
    Equatable,
    Sendable
{
    public let threadID: CodexStoredThreadID
    public let turnID: String
    public let explanation: String?
    public let plan: [CodexTurnPlanStep]

    public init(
        threadID: CodexStoredThreadID,
        turnID: String,
        explanation: String?,
        plan: [CodexTurnPlanStep]
    ) {
        self.threadID = threadID
        self.turnID = turnID
        self.explanation = explanation
        self.plan = plan
    }

    private enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case turnID = "turnId"
        case explanation
        case plan
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard container.contains(.explanation) else {
            throw DecodingError.keyNotFound(
                CodingKeys.explanation,
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription:
                        "explanation is required, including null"
                )
            )
        }
        threadID = try container.decode(
            CodexStoredThreadID.self,
            forKey: .threadID
        )
        turnID = try container.decode(String.self, forKey: .turnID)
        explanation = try container.decodeIfPresent(
            String.self,
            forKey: .explanation
        )
        plan = try container.decode(
            [CodexTurnPlanStep].self,
            forKey: .plan
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(threadID, forKey: .threadID)
        try container.encode(turnID, forKey: .turnID)
        if let explanation {
            try container.encode(explanation, forKey: .explanation)
        } else {
            try container.encodeNil(forKey: .explanation)
        }
        try container.encode(plan, forKey: .plan)
    }
}

public struct CodexCommandExecutionOutputDeltaNotification:
    Codable,
    Equatable,
    Sendable
{
    public let threadID: CodexStoredThreadID
    public let turnID: String
    public let itemID: String
    public let delta: String

    public init(
        threadID: CodexStoredThreadID,
        turnID: String,
        itemID: String,
        delta: String
    ) {
        self.threadID = threadID
        self.turnID = turnID
        self.itemID = itemID
        self.delta = delta
    }

    private enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case turnID = "turnId"
        case itemID = "itemId"
        case delta
    }
}

public struct CodexTerminalInteractionNotification:
    Codable,
    Equatable,
    Sendable
{
    public let threadID: CodexStoredThreadID
    public let turnID: String
    public let itemID: String
    public let processID: String
    public let stdin: String

    public init(
        threadID: CodexStoredThreadID,
        turnID: String,
        itemID: String,
        processID: String,
        stdin: String
    ) {
        self.threadID = threadID
        self.turnID = turnID
        self.itemID = itemID
        self.processID = processID
        self.stdin = stdin
    }

    private enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case turnID = "turnId"
        case itemID = "itemId"
        case processID = "processId"
        case stdin
    }
}

public enum CodexPatchChangeKind: Equatable, Sendable {
    case add
    case delete
    case update(movePath: String?)
}

extension CodexPatchChangeKind: Codable {
    private enum CodingKeys: String, CodingKey {
        case type
        case movePath = "move_path"
    }

    private enum Kind: String, Codable {
        case add
        case delete
        case update
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .type) {
        case .add:
            self = .add
        case .delete:
            self = .delete
        case .update:
            guard container.contains(.movePath) else {
                throw DecodingError.keyNotFound(
                    CodingKeys.movePath,
                    DecodingError.Context(
                        codingPath: decoder.codingPath,
                        debugDescription:
                            "update patch kind requires move_path"
                    )
                )
            }
            self = .update(
                movePath: try container.decodeIfPresent(
                    String.self,
                    forKey: .movePath
                )
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .add:
            try container.encode(Kind.add, forKey: .type)
        case .delete:
            try container.encode(Kind.delete, forKey: .type)
        case let .update(movePath):
            try container.encode(Kind.update, forKey: .type)
            if let movePath {
                try container.encode(movePath, forKey: .movePath)
            } else {
                try container.encodeNil(forKey: .movePath)
            }
        }
    }
}

public struct CodexFileUpdateChange: Codable, Equatable, Sendable {
    public let path: String
    public let kind: CodexPatchChangeKind
    public let diff: String

    public init(
        path: String,
        kind: CodexPatchChangeKind,
        diff: String
    ) {
        self.path = path
        self.kind = kind
        self.diff = diff
    }
}

public struct CodexFileChangePatchUpdatedNotification:
    Codable,
    Equatable,
    Sendable
{
    public let threadID: CodexStoredThreadID
    public let turnID: String
    public let itemID: String
    public let changes: [CodexFileUpdateChange]

    public init(
        threadID: CodexStoredThreadID,
        turnID: String,
        itemID: String,
        changes: [CodexFileUpdateChange]
    ) {
        self.threadID = threadID
        self.turnID = turnID
        self.itemID = itemID
        self.changes = changes
    }

    private enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case turnID = "turnId"
        case itemID = "itemId"
        case changes
    }
}

public struct CodexMCPToolCallProgressNotification:
    Codable,
    Equatable,
    Sendable
{
    public let threadID: CodexStoredThreadID
    public let turnID: String
    public let itemID: String
    public let message: String

    public init(
        threadID: CodexStoredThreadID,
        turnID: String,
        itemID: String,
        message: String
    ) {
        self.threadID = threadID
        self.turnID = turnID
        self.itemID = itemID
        self.message = message
    }

    private enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case turnID = "turnId"
        case itemID = "itemId"
        case message
    }
}

public enum CodexAppServerTurnNotification: Equatable, Sendable {
    case error(CodexTurnErrorNotification)
    case turnStarted(CodexTurnStartedNotification)
    case itemStarted(CodexItemStartedNotification)
    case agentMessageDelta(CodexAgentMessageDeltaNotification)
    case reasoningSummaryTextDelta(
        CodexReasoningSummaryTextDeltaNotification
    )
    case reasoningSummaryPartAdded(
        CodexReasoningSummaryPartAddedNotification
    )
    case reasoningTextDelta(CodexReasoningTextDeltaNotification)
    case planDelta(CodexPlanDeltaNotification)
    case itemCompleted(CodexItemCompletedNotification)
    case threadTokenUsageUpdated(
        CodexThreadTokenUsageUpdatedNotification
    )
    case turnCompleted(CodexTurnCompletedNotification)
    case turnDiffUpdated(CodexTurnDiffUpdatedNotification)
    case turnPlanUpdated(CodexTurnPlanUpdatedNotification)
    case commandExecutionOutputDelta(
        CodexCommandExecutionOutputDeltaNotification
    )
    case terminalInteraction(CodexTerminalInteractionNotification)
    case fileChangePatchUpdated(
        CodexFileChangePatchUpdatedNotification
    )
    case mcpToolCallProgress(
        CodexMCPToolCallProgressNotification
    )
    case rawResponseItemCompleted(
        CodexRawResponseItemCompletedNotification
    )
    case rawResponseCompleted(CodexRawResponseCompletedNotification)
    case hookStarted(CodexHookNotification)
    case hookCompleted(CodexHookNotification)
    case autoApprovalReviewStarted(
        CodexAutoApprovalReviewStartedNotification
    )
    case autoApprovalReviewCompleted(
        CodexAutoApprovalReviewCompletedNotification
    )
    case opaque(method: String, rawEnvelope: CodexJSONValue)
}

public struct CodexAppServerTurnNotificationEnvelope:
    Decodable,
    Equatable,
    Sendable
{
    public let notification: CodexAppServerTurnNotification
    public let emittedAtMs: Int64?
    public let rawValue: CodexJSONValue

    public init(from decoder: any Decoder) throws {
        let rawValue = try CodexJSONValue(from: decoder)
        guard case .object(let values) = rawValue else {
            throw DecodingError.typeMismatch(
                [String: CodexJSONValue].self,
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription:
                        "App-server notification envelope must be an object"
                )
            )
        }
        guard case .string(let method)? = values["method"] else {
            throw DecodingError.keyNotFound(
                NotificationCodingKey.method,
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription:
                        "App-server notification requires a string method"
                )
            )
        }

        self.rawValue = rawValue
        emittedAtMs = try Self.decodeEmittedAtMs(
            values["emittedAtMs"],
            codingPath: decoder.codingPath
        )

        guard Self.knownMethods.contains(method) else {
            notification = .opaque(
                method: method,
                rawEnvelope: rawValue
            )
            return
        }
        guard let params = values["params"] else {
            throw DecodingError.keyNotFound(
                NotificationCodingKey.params,
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription:
                        "Known app-server notification requires params"
                )
            )
        }

        switch method {
        case "error":
            notification = .error(
                try Self.decodePayload(
                    CodexTurnErrorNotification.self,
                    from: params
                )
            )
        case "turn/started":
            notification = .turnStarted(
                try Self.decodePayload(
                    CodexTurnStartedNotification.self,
                    from: params
                )
            )
        case "item/started":
            notification = .itemStarted(
                try Self.decodePayload(
                    CodexItemStartedNotification.self,
                    from: params
                )
            )
        case "item/agentMessage/delta":
            notification = .agentMessageDelta(
                try Self.decodePayload(
                    CodexAgentMessageDeltaNotification.self,
                    from: params
                )
            )
        case "item/reasoning/summaryTextDelta":
            notification = .reasoningSummaryTextDelta(
                try Self.decodePayload(
                    CodexReasoningSummaryTextDeltaNotification.self,
                    from: params
                )
            )
        case "item/reasoning/summaryPartAdded":
            notification = .reasoningSummaryPartAdded(
                try Self.decodePayload(
                    CodexReasoningSummaryPartAddedNotification.self,
                    from: params
                )
            )
        case "item/reasoning/textDelta":
            notification = .reasoningTextDelta(
                try Self.decodePayload(
                    CodexReasoningTextDeltaNotification.self,
                    from: params
                )
            )
        case "item/plan/delta":
            notification = .planDelta(
                try Self.decodePayload(
                    CodexPlanDeltaNotification.self,
                    from: params
                )
            )
        case "item/completed":
            notification = .itemCompleted(
                try Self.decodePayload(
                    CodexItemCompletedNotification.self,
                    from: params
                )
            )
        case "thread/tokenUsage/updated":
            notification = .threadTokenUsageUpdated(
                try Self.decodePayload(
                    CodexThreadTokenUsageUpdatedNotification.self,
                    from: params
                )
            )
        case "turn/completed":
            notification = .turnCompleted(
                try Self.decodePayload(
                    CodexTurnCompletedNotification.self,
                    from: params
                )
            )
        case "turn/diff/updated":
            notification = .turnDiffUpdated(
                try Self.decodePayload(
                    CodexTurnDiffUpdatedNotification.self,
                    from: params
                )
            )
        case "turn/plan/updated":
            notification = .turnPlanUpdated(
                try Self.decodePayload(
                    CodexTurnPlanUpdatedNotification.self,
                    from: params
                )
            )
        case "item/commandExecution/outputDelta":
            notification = .commandExecutionOutputDelta(
                try Self.decodePayload(
                    CodexCommandExecutionOutputDeltaNotification.self,
                    from: params
                )
            )
        case "item/commandExecution/terminalInteraction":
            notification = .terminalInteraction(
                try Self.decodePayload(
                    CodexTerminalInteractionNotification.self,
                    from: params
                )
            )
        case "item/fileChange/patchUpdated":
            notification = .fileChangePatchUpdated(
                try Self.decodePayload(
                    CodexFileChangePatchUpdatedNotification.self,
                    from: params
                )
            )
        case "item/mcpToolCall/progress":
            notification = .mcpToolCallProgress(
                try Self.decodePayload(
                    CodexMCPToolCallProgressNotification.self,
                    from: params
                )
            )
        case "rawResponseItem/completed":
            notification = .rawResponseItemCompleted(
                try Self.decodePayload(
                    CodexRawResponseItemCompletedNotification.self,
                    from: params
                )
            )
        case "rawResponse/completed":
            notification = .rawResponseCompleted(
                try Self.decodePayload(
                    CodexRawResponseCompletedNotification.self,
                    from: params
                )
            )
        case "hook/started":
            notification = .hookStarted(
                try Self.decodePayload(
                    CodexHookNotification.self,
                    from: params
                )
            )
        case "hook/completed":
            notification = .hookCompleted(
                try Self.decodePayload(
                    CodexHookNotification.self,
                    from: params
                )
            )
        case "item/autoApprovalReview/started":
            notification = .autoApprovalReviewStarted(
                try Self.decodePayload(
                    CodexAutoApprovalReviewStartedNotification.self,
                    from: params
                )
            )
        case "item/autoApprovalReview/completed":
            notification = .autoApprovalReviewCompleted(
                try Self.decodePayload(
                    CodexAutoApprovalReviewCompletedNotification.self,
                    from: params
                )
            )
        default:
            preconditionFailure("Known method routing is incomplete")
        }
    }

    private static let knownMethods: Set<String> = [
        "error",
        "turn/started",
        "item/started",
        "item/agentMessage/delta",
        "item/reasoning/summaryTextDelta",
        "item/reasoning/summaryPartAdded",
        "item/reasoning/textDelta",
        "item/plan/delta",
        "item/completed",
        "thread/tokenUsage/updated",
        "turn/completed",
        "turn/diff/updated",
        "turn/plan/updated",
        "item/commandExecution/outputDelta",
        "item/commandExecution/terminalInteraction",
        "item/fileChange/patchUpdated",
        "item/mcpToolCall/progress",
        "rawResponseItem/completed",
        "rawResponse/completed",
        "hook/started",
        "hook/completed",
        "item/autoApprovalReview/started",
        "item/autoApprovalReview/completed",
    ]

    private static func decodePayload<Payload>(
        _ type: Payload.Type,
        from rawValue: CodexJSONValue
    ) throws -> Payload where Payload: Decodable {
        let data = try encodeTurnWire(rawValue)
        return try JSONDecoder().decode(type, from: data)
    }

    private static func decodeEmittedAtMs(
        _ rawValue: CodexJSONValue?,
        codingPath: [any CodingKey]
    ) throws -> Int64? {
        guard let rawValue else {
            return nil
        }
        if case .integer(let value) = rawValue {
            return value
        }
        if case .number(let value) = rawValue,
            value.isFinite,
            value.rounded(.towardZero) == value,
            value >= Double(Int64.min),
            value < Double(Int64.max)
        {
            return Int64(value)
        }
        throw DecodingError.typeMismatch(
            Int64.self,
            DecodingError.Context(
                codingPath:
                    codingPath + [NotificationCodingKey.emittedAtMs],
                debugDescription:
                    "emittedAtMs must be an integer when present"
            )
        )
    }
}

public struct CodexAppServerTurnNotificationWire:
    Equatable,
    Sendable
{
    public let method: String
    public let params: CodexJSONValue

    public init(method: String, params: CodexJSONValue) {
        self.method = method
        self.params = params
    }
}

public enum CodexAppServerTurnNotificationEncoder {
    public static func wire(
        _ notification: CodexAppServerTurnNotification
    ) throws -> CodexAppServerTurnNotificationWire {
        switch notification {
        case let .error(payload):
            return try wire("error", payload)
        case let .turnStarted(payload):
            return try wire("turn/started", payload)
        case let .itemStarted(payload):
            return try wire("item/started", payload)
        case let .agentMessageDelta(payload):
            return try wire("item/agentMessage/delta", payload)
        case let .reasoningSummaryTextDelta(payload):
            return try wire("item/reasoning/summaryTextDelta", payload)
        case let .reasoningSummaryPartAdded(payload):
            return try wire("item/reasoning/summaryPartAdded", payload)
        case let .reasoningTextDelta(payload):
            return try wire("item/reasoning/textDelta", payload)
        case let .planDelta(payload):
            return try wire("item/plan/delta", payload)
        case let .itemCompleted(payload):
            return try wire("item/completed", payload)
        case let .threadTokenUsageUpdated(payload):
            return try wire("thread/tokenUsage/updated", payload)
        case let .turnCompleted(payload):
            return try wire("turn/completed", payload)
        case let .turnDiffUpdated(payload):
            return try wire("turn/diff/updated", payload)
        case let .turnPlanUpdated(payload):
            return try wire("turn/plan/updated", payload)
        case let .commandExecutionOutputDelta(payload):
            return try wire(
                "item/commandExecution/outputDelta",
                payload
            )
        case let .terminalInteraction(payload):
            return try wire(
                "item/commandExecution/terminalInteraction",
                payload
            )
        case let .fileChangePatchUpdated(payload):
            return try wire("item/fileChange/patchUpdated", payload)
        case let .mcpToolCallProgress(payload):
            return try wire("item/mcpToolCall/progress", payload)
        case let .rawResponseItemCompleted(payload):
            return try wire("rawResponseItem/completed", payload)
        case let .rawResponseCompleted(payload):
            return try wire("rawResponse/completed", payload)
        case let .hookStarted(payload):
            return try wire("hook/started", payload)
        case let .hookCompleted(payload):
            return try wire("hook/completed", payload)
        case let .autoApprovalReviewStarted(payload):
            return try wire(
                "item/autoApprovalReview/started",
                payload
            )
        case let .autoApprovalReviewCompleted(payload):
            return try wire(
                "item/autoApprovalReview/completed",
                payload
            )
        case let .opaque(method, rawEnvelope):
            guard case let .object(fields) = rawEnvelope,
                  fields["method"] == .string(method),
                  let params = fields["params"],
                  case .object = params
            else {
                throw CodexAppServerTurnEnvelopeError
                    .invalidTurnStartParam("notification")
            }
            return CodexAppServerTurnNotificationWire(
                method: method,
                params: params
            )
        }
    }

    private static func wire<Payload>(
        _ method: String,
        _ payload: Payload
    ) throws -> CodexAppServerTurnNotificationWire
    where Payload: Encodable {
        let data = try JSONEncoder().encode(payload)
        let params = try JSONDecoder().decode(
            CodexJSONValue.self,
            from: data
        )
        guard case .object = params else {
            throw CodexAppServerTurnEnvelopeError
                .invalidTurnStartParam("notification")
        }
        return CodexAppServerTurnNotificationWire(
            method: method,
            params: params
        )
    }
}

private enum NotificationCodingKey: String, CodingKey {
    case method
    case params
    case emittedAtMs
}

private struct TurnRequestEnvelope<Params: Encodable>: Encodable {
    let id: CodexAppServerRequestID
    let method: String
    let params: Params
}

private struct TurnStartWire: Encodable {
    let params: CodexTurnStartParams

    init(_ params: CodexTurnStartParams) {
        self.params = params
    }

    private enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case clientUserMessageID = "clientUserMessageId"
        case input
        case cwd
        case approvalPolicy
        case approvalsReviewer
        case sandboxPolicy
        case model
        case serviceTier
        case effort
        case summary
        case collaborationMode
        case multiAgentMode
        case personality
        case outputSchema
        case additionalContext
        case environments
        case permissions
        case responsesAPIClientMetadata = "responsesapiClientMetadata"
        case runtimeWorkspaceRoots
        case dynamicTools
        case selectedCapabilityRoots
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(params.threadID.rawValue, forKey: .threadID)
        try container.encode(params.input, forKey: .input)
        try encodeTurnOptional(
            params.clientUserMessageID,
            forKey: .clientUserMessageID,
            into: &container
        )
        try encodeTurnOptional(
            params.cwd,
            forKey: .cwd,
            into: &container
        )
        try encodeTurnOptional(
            params.approvalPolicy,
            forKey: .approvalPolicy,
            into: &container
        )
        try encodeTurnOptional(
            params.approvalsReviewer,
            forKey: .approvalsReviewer,
            into: &container
        )
        try encodeTurnOptional(
            params.sandboxPolicy,
            forKey: .sandboxPolicy,
            into: &container
        )
        try encodeTurnOptional(
            params.model,
            forKey: .model,
            into: &container
        )
        try encodeTurnOptional(
            params.serviceTier,
            forKey: .serviceTier,
            into: &container
        )
        try encodeTurnOptional(
            params.effort,
            forKey: .effort,
            into: &container
        )
        try encodeTurnOptional(
            params.summary,
            forKey: .summary,
            into: &container
        )
        try encodeTurnOptional(
            params.collaborationMode,
            forKey: .collaborationMode,
            into: &container
        )
        try encodeTurnOptional(
            params.multiAgentMode,
            forKey: .multiAgentMode,
            into: &container
        )
        try encodeTurnOptional(
            params.personality,
            forKey: .personality,
            into: &container
        )
        try encodeTurnOptional(
            params.outputSchema,
            forKey: .outputSchema,
            into: &container
        )
        try encodeTurnOptional(
            params.additionalContext,
            forKey: .additionalContext,
            into: &container
        )
        try encodeTurnOptional(
            params.environments,
            forKey: .environments,
            into: &container
        )
        try encodeTurnOptional(
            params.permissions,
            forKey: .permissions,
            into: &container
        )
        try encodeTurnOptional(
            params.responsesAPIClientMetadata,
            forKey: .responsesAPIClientMetadata,
            into: &container
        )
        try encodeTurnOptional(
            params.runtimeWorkspaceRoots,
            forKey: .runtimeWorkspaceRoots,
            into: &container
        )
        try encodeTurnOptional(
            params.dynamicTools,
            forKey: .dynamicTools,
            into: &container
        )
        try encodeTurnOptional(
            params.selectedCapabilityRoots,
            forKey: .selectedCapabilityRoots,
            into: &container
        )
    }
}

private func encodeTurnOptional<Value, Key>(
    _ field: CodexWireOptional<Value>,
    forKey key: Key,
    into container: inout KeyedEncodingContainer<Key>
) throws
where
    Value: Encodable & Equatable & Sendable,
    Key: CodingKey
{
    switch field {
    case .omitted:
        break
    case .null:
        try container.encodeNil(forKey: key)
    case .value(let value):
        try container.encode(value, forKey: key)
    }
}

private func encodeTurnWire(_ value: some Encodable) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(value)
}
