#if SWIFT_PACKAGE
import CodexPadDomain
#endif
import Foundation

public enum CodexRawHistoryEnvelopeError:
    Error,
    Equatable,
    Sendable
{
    case invalidCommit
    case invalidRawItem
}

public enum CodexRawHistorySource:
    String,
    Codable,
    Equatable,
    Sendable
{
    case provider
    case localTool
}

public struct CodexRawHistoryEntry:
    Codable,
    Equatable,
    Sendable
{
    public let order: UInt64
    public let source: CodexRawHistorySource
    public let itemJSON: String

    public init(
        order: UInt64,
        source: CodexRawHistorySource,
        itemJSON: String
    ) {
        self.order = order
        self.source = source
        self.itemJSON = itemJSON
    }

    var containsJSONObject: Bool {
        guard let data = itemJSON.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(
                  with: data,
                  options: [.fragmentsAllowed]
              )
        else {
            return false
        }
        return value is [String: Any]
    }

    private enum CodingKeys: String, CodingKey {
        case order
        case source
        case itemJSON = "itemJson"
    }
}

public struct CodexRawHistoryCompletion:
    Codable,
    Equatable,
    Sendable
{
    public let responseID: String
    public let usage: CodexWireOptional<CodexTokenUsageBreakdown>
    public let endTurn: CodexWireOptional<Bool>

    public init(
        responseID: String,
        usage: CodexWireOptional<CodexTokenUsageBreakdown> = .omitted,
        endTurn: CodexWireOptional<Bool> = .omitted
    ) {
        self.responseID = responseID
        self.usage = usage
        self.endTurn = endTurn
    }

    private enum CodingKeys: String, CodingKey {
        case responseID = "responseId"
        case usage
        case endTurn
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        responseID = try container.decode(String.self, forKey: .responseID)
        usage = try decodeRawOptional(
            CodexTokenUsageBreakdown.self,
            forKey: .usage,
            from: container
        )
        endTurn = try decodeRawOptional(
            Bool.self,
            forKey: .endTurn,
            from: container
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(responseID, forKey: .responseID)
        try encodeRawOptional(usage, forKey: .usage, into: &container)
        try encodeRawOptional(endTurn, forKey: .endTurn, into: &container)
    }
}

public struct CodexRawHistoryCommit:
    Equatable,
    Sendable
{
    public let threadID: CodexStoredThreadID
    public let turnID: String
    public let expectedNextOrder: UInt64
    public let entries: [CodexRawHistoryEntry]
    public let completion:
        CodexWireOptional<CodexRawHistoryCompletion>

    public init(
        threadID: CodexStoredThreadID,
        turnID: String,
        expectedNextOrder: UInt64,
        entries: [CodexRawHistoryEntry],
        completion:
            CodexWireOptional<CodexRawHistoryCompletion> = .omitted
    ) {
        self.threadID = threadID
        self.turnID = turnID
        self.expectedNextOrder = expectedNextOrder
        self.entries = entries
        self.completion = completion
    }

    public func encodedData() throws -> Data {
        guard !threadID.rawValue.isEmpty,
              !turnID.isEmpty,
              !entries.isEmpty || completion.hasConcreteValue,
              rawHistoryEntriesAreContiguous(
                  entries,
                  startingAt: expectedNextOrder
              ),
              entries.allSatisfy(\.containsJSONObject)
        else {
            throw CodexRawHistoryEnvelopeError.invalidCommit
        }
        if case .value(let completion) = completion,
           completion.responseID.trimmingCharacters(
               in: .whitespacesAndNewlines
           ).isEmpty
        {
            throw CodexRawHistoryEnvelopeError.invalidCommit
        }
        return try encodeRawWire(RawHistoryCommitWire(self))
    }
}

public struct CodexCompactHistoryCommit:
    Equatable,
    Sendable
{
    public let threadID: CodexStoredThreadID
    public let turnID: String
    public let itemID: String
    public let replacementItems: [String]
    public let responseID: String
    public let usage: CodexTokenUsageBreakdown?

    public init(
        threadID: CodexStoredThreadID,
        turnID: String,
        itemID: String,
        replacementItems: [String],
        responseID: String,
        usage: CodexTokenUsageBreakdown?
    ) {
        self.threadID = threadID
        self.turnID = turnID
        self.itemID = itemID
        self.replacementItems = replacementItems
        self.responseID = responseID
        self.usage = usage
    }

    public func encodedData() throws -> Data {
        guard !threadID.rawValue.isEmpty,
              !turnID.isEmpty,
              !itemID.isEmpty,
              !replacementItems.isEmpty,
              !responseID.trimmingCharacters(
                  in: .whitespacesAndNewlines
              ).isEmpty,
              replacementItems.allSatisfy(Self.containsJSONObject)
        else {
            throw CodexRawHistoryEnvelopeError.invalidCommit
        }
        return try JSONEncoder().encode(Wire(self))
    }

    private static func containsJSONObject(_ itemJSON: String) -> Bool {
        guard let data = itemJSON.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(
                  with: data,
                  options: [.fragmentsAllowed]
              )
        else {
            return false
        }
        return value is [String: Any]
    }

    private struct Wire: Encodable {
        let kind = "turn.compact-history.commit"
        let threadID: String
        let turnID: String
        let itemID: String
        let replacementItems: [String]
        let responseID: String
        let usage: CodexTokenUsageBreakdown?

        init(_ command: CodexCompactHistoryCommit) {
            threadID = command.threadID.rawValue
            turnID = command.turnID
            itemID = command.itemID
            replacementItems = command.replacementItems
            responseID = command.responseID
            usage = command.usage
        }

        private enum CodingKeys: String, CodingKey {
            case kind
            case threadID = "threadId"
            case turnID = "turnId"
            case itemID = "itemId"
            case replacementItems
            case responseID = "responseId"
            case usage
        }
    }
}

private struct RawHistoryCommitWire: Encodable {
    let commit: CodexRawHistoryCommit

    init(_ commit: CodexRawHistoryCommit) {
        self.commit = commit
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case threadID = "threadId"
        case turnID = "turnId"
        case expectedNextOrder
        case entries
        case completion
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(
            "turn.raw-history.commit",
            forKey: .kind
        )
        try container.encode(
            commit.threadID.rawValue,
            forKey: .threadID
        )
        try container.encode(commit.turnID, forKey: .turnID)
        try container.encode(
            commit.expectedNextOrder,
            forKey: .expectedNextOrder
        )
        try container.encode(commit.entries, forKey: .entries)
        try encodeRawOptional(
            commit.completion,
            forKey: .completion,
            into: &container
        )
    }
}

public struct CodexPriorInputItemsParams:
    Equatable,
    Sendable
{
    public let threadID: CodexStoredThreadID
    public let beforeTurnID: CodexWireOptional<String>

    public init(
        threadID: CodexStoredThreadID,
        beforeTurnID: CodexWireOptional<String> = .omitted
    ) {
        self.threadID = threadID
        self.beforeTurnID = beforeTurnID
    }
}

public enum CodexPriorInputCompleteness:
    String,
    Codable,
    Equatable,
    Sendable
{
    case complete
    case partialLegacy
    case legacyUnavailable
}

public struct CodexPriorInputItemsResult:
    Codable,
    Equatable,
    Sendable
{
    public let threadID: CodexStoredThreadID
    public let throughTurnID: String?
    public let items: [String]
    public let completeness: CodexPriorInputCompleteness

    public init(
        threadID: CodexStoredThreadID,
        throughTurnID: String?,
        items: [String],
        completeness: CodexPriorInputCompleteness
    ) {
        self.threadID = threadID
        self.throughTurnID = throughTurnID
        self.items = items
        self.completeness = completeness
    }

    private enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case throughTurnID = "throughTurnId"
        case items
        case completeness
    }
}

public enum CodexRawHistoryRequest: Equatable, Sendable {
    case priorInputItems(
        id: CodexAppServerRequestID,
        params: CodexPriorInputItemsParams
    )

    public func encodedData() throws -> Data {
        switch self {
        case .priorInputItems(let id, let params):
            guard !params.threadID.rawValue.isEmpty,
                  params.beforeTurnID.hasNonblankValueOrNoValue
            else {
                throw CodexRawHistoryEnvelopeError.invalidCommit
            }
            return try encodeRawWire(
                RawRequestEnvelope(
                    id: id,
                    method: "thread/prior-input-items",
                    params: PriorInputItemsWire(params)
                )
            )
        }
    }
}

private struct RawRequestEnvelope<Params: Encodable>: Encodable {
    let id: CodexAppServerRequestID
    let method: String
    let params: Params
}

private struct PriorInputItemsWire: Encodable {
    let params: CodexPriorInputItemsParams

    init(_ params: CodexPriorInputItemsParams) {
        self.params = params
    }

    private enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case beforeTurnID = "beforeTurnId"
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(
            params.threadID.rawValue,
            forKey: .threadID
        )
        try encodeRawOptional(
            params.beforeTurnID,
            forKey: .beforeTurnID,
            into: &container
        )
    }
}

public struct CodexStableTurnStartedEvent:
    Codable,
    Equatable,
    Sendable
{
    public let sequence: UInt64
    public let threadID: CodexStoredThreadID
    public let turnID: String
    public let userItemID: String
    public let params: CodexJSONValue

    public init(
        sequence: UInt64,
        threadID: CodexStoredThreadID,
        turnID: String,
        userItemID: String,
        params: CodexJSONValue
    ) {
        self.sequence = sequence
        self.threadID = threadID
        self.turnID = turnID
        self.userItemID = userItemID
        self.params = params
    }

    private enum CodingKeys: String, CodingKey {
        case sequence
        case threadID = "threadId"
        case turnID = "turnId"
        case userItemID = "userItemId"
        case params
    }
}

public struct CodexStableCompactStartedEvent:
    Codable,
    Equatable,
    Sendable
{
    public let sequence: UInt64
    public let threadID: CodexStoredThreadID
    public let turnID: String
    public let itemID: String

    public init(
        sequence: UInt64,
        threadID: CodexStoredThreadID,
        turnID: String,
        itemID: String
    ) {
        self.sequence = sequence
        self.threadID = threadID
        self.turnID = turnID
        self.itemID = itemID
    }

    private enum CodingKeys: String, CodingKey {
        case sequence
        case threadID = "threadId"
        case turnID = "turnId"
        case itemID = "itemId"
    }
}

public struct CodexCompactionCommittedEvent:
    Codable,
    Equatable,
    Sendable
{
    public let sequence: UInt64
    public let threadID: CodexStoredThreadID
    public let turnID: String
    public let itemID: String
    public let replacementItems: [String]
    public let responseID: String
    public let usage: CodexTokenUsageBreakdown?

    private enum CodingKeys: String, CodingKey {
        case sequence
        case threadID = "threadId"
        case turnID = "turnId"
        case itemID = "itemId"
        case replacementItems
        case responseID = "responseId"
        case usage
    }
}

public struct CodexRawHistoryCommittedEvent:
    Codable,
    Equatable,
    Sendable
{
    public let sequence: UInt64
    public let threadID: CodexStoredThreadID
    public let turnID: String
    public let expectedNextOrder: UInt64
    public let entries: [CodexRawHistoryEntry]
    public let completion: CodexRawHistoryCompletion?

    public init(
        sequence: UInt64,
        threadID: CodexStoredThreadID,
        turnID: String,
        expectedNextOrder: UInt64,
        entries: [CodexRawHistoryEntry],
        completion: CodexRawHistoryCompletion?
    ) {
        self.sequence = sequence
        self.threadID = threadID
        self.turnID = turnID
        self.expectedNextOrder = expectedNextOrder
        self.entries = entries
        self.completion = completion
    }

    private enum CodingKeys: String, CodingKey {
        case sequence
        case threadID = "threadId"
        case turnID = "turnId"
        case expectedNextOrder
        case entries
        case completion
    }
}

private extension CodexWireOptional {
    var hasConcreteValue: Bool {
        if case .value = self {
            return true
        }
        return false
    }
}

private extension CodexWireOptional where Value == String {
    var hasNonblankValueOrNoValue: Bool {
        switch self {
        case .omitted, .null:
            true
        case .value(let value):
            !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }
}

func rawHistoryEntriesAreContiguous(
    _ entries: [CodexRawHistoryEntry],
    startingAt expectedNextOrder: UInt64
) -> Bool {
    for (offset, entry) in entries.enumerated() {
        let (expectedOrder, overflow) = expectedNextOrder.addingReportingOverflow(
            UInt64(offset)
        )
        if overflow || entry.order != expectedOrder {
            return false
        }
    }
    return true
}

private func decodeRawOptional<Value, Key>(
    _ type: Value.Type,
    forKey key: Key,
    from container: KeyedDecodingContainer<Key>
) throws -> CodexWireOptional<Value>
where
    Value: Decodable & Equatable & Sendable,
    Key: CodingKey
{
    guard container.contains(key) else {
        return .omitted
    }
    if try container.decodeNil(forKey: key) {
        return .null
    }
    return .value(try container.decode(Value.self, forKey: key))
}

private func encodeRawOptional<Value, Key>(
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

private func encodeRawWire(_ value: some Encodable) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(value)
}
