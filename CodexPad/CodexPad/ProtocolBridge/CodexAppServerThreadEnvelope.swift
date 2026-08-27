#if SWIFT_PACKAGE
import CodexPadDomain
#endif
import Foundation

public enum CodexAppServerThreadEnvelopeError:
    Error,
    Equatable,
    Sendable
{
    case blankSearchTerm
    case invalidThreadListParam(String)
    case invalidThreadListParams
    case mutuallyExclusiveThreadLineageFilters
}

public enum CodexAppServerThreadListParamsDecoder {
    public static func decode(
        _ params: CodexJSONValue?
    ) throws -> CodexThreadListParams {
        guard case let .object(fields)? = params else {
            throw CodexAppServerThreadEnvelopeError.invalidThreadListParams
        }

        let parentThreadID = try decodeNullableField(
            fields,
            key: "parentThreadId",
            using: decodeString
        )
        let ancestorThreadID = try decodeNullableField(
            fields,
            key: "ancestorThreadId",
            using: decodeString
        )
        if case .value = parentThreadID,
           case .value = ancestorThreadID
        {
            throw CodexAppServerThreadEnvelopeError
                .mutuallyExclusiveThreadLineageFilters
        }

        return try CodexThreadListParams(
            cursor: decodeNullableField(
                fields,
                key: "cursor",
                using: decodeString
            ),
            limit: decodeNullableField(
                fields,
                key: "limit",
                using: decodeLimit
            ),
            sortKey: decodeNullableField(
                fields,
                key: "sortKey",
                using: decodeSortKey
            ),
            sortDirection: decodeNullableField(
                fields,
                key: "sortDirection",
                using: decodeSortDirection
            ),
            modelProviders: decodeNullableField(
                fields,
                key: "modelProviders",
                using: decodeStringArray
            ),
            sourceKinds: decodeNullableField(
                fields,
                key: "sourceKinds",
                using: decodeSourceKinds
            ),
            archived: decodeNullableField(
                fields,
                key: "archived",
                using: decodeBool
            ),
            isPinned: decodeNullableField(
                fields,
                key: "isPinned",
                using: decodeBool
            ),
            cwd: decodeNullableField(
                fields,
                key: "cwd",
                using: decodeCWD
            ),
            useStateDbOnly: try decodeOptionalBool(
                fields,
                key: "useStateDbOnly"
            ),
            searchTerm: decodeNullableField(
                fields,
                key: "searchTerm",
                using: decodeString
            ),
            parentThreadID: parentThreadID,
            ancestorThreadID: ancestorThreadID
        )
    }

    private static func decodeNullableField<Value>(
        _ fields: [String: CodexJSONValue],
        key: String,
        using decode: (CodexJSONValue) -> Value?
    ) throws -> CodexWireOptional<Value>
    where Value: Equatable & Sendable {
        guard let value = fields[key] else {
            return .omitted
        }
        if case .null = value {
            return .null
        }
        guard let decoded = decode(value) else {
            throw CodexAppServerThreadEnvelopeError
                .invalidThreadListParam(key)
        }
        return .value(decoded)
    }

    private static func decodeOptionalBool(
        _ fields: [String: CodexJSONValue],
        key: String
    ) throws -> Bool? {
        guard let value = fields[key] else {
            return nil
        }
        guard case let .bool(decoded) = value else {
            throw CodexAppServerThreadEnvelopeError
                .invalidThreadListParam(key)
        }
        return decoded
    }

    private static func decodeString(
        _ value: CodexJSONValue
    ) -> String? {
        guard case let .string(decoded) = value else {
            return nil
        }
        return decoded
    }

    private static func decodeLimit(
        _ value: CodexJSONValue
    ) -> UInt32? {
        guard case let .integer(decoded) = value else {
            return nil
        }
        return UInt32(exactly: decoded)
    }

    private static func decodeSortKey(
        _ value: CodexJSONValue
    ) -> CodexThreadSortKey? {
        guard let rawValue = decodeString(value) else {
            return nil
        }
        return CodexThreadSortKey(rawValue: rawValue)
    }

    private static func decodeSortDirection(
        _ value: CodexJSONValue
    ) -> CodexThreadSortDirection? {
        guard let rawValue = decodeString(value) else {
            return nil
        }
        return CodexThreadSortDirection(rawValue: rawValue)
    }

    private static func decodeStringArray(
        _ value: CodexJSONValue
    ) -> [String]? {
        guard case let .array(values) = value else {
            return nil
        }
        var decoded: [String] = []
        decoded.reserveCapacity(values.count)
        for value in values {
            guard case let .string(item) = value else {
                return nil
            }
            decoded.append(item)
        }
        return decoded
    }

    private static func decodeSourceKinds(
        _ value: CodexJSONValue
    ) -> [CodexThreadSourceKind]? {
        guard let rawValues = decodeStringArray(value) else {
            return nil
        }
        var decoded: [CodexThreadSourceKind] = []
        decoded.reserveCapacity(rawValues.count)
        for rawValue in rawValues {
            guard let sourceKind = CodexThreadSourceKind(
                rawValue: rawValue
            ) else {
                return nil
            }
            decoded.append(sourceKind)
        }
        return decoded
    }

    private static func decodeBool(
        _ value: CodexJSONValue
    ) -> Bool? {
        guard case let .bool(decoded) = value else {
            return nil
        }
        return decoded
    }

    private static func decodeCWD(
        _ value: CodexJSONValue
    ) -> CodexThreadCWDFilter? {
        switch value {
        case let .string(path):
            return .one(path)
        case .array:
            guard let paths = decodeStringArray(value) else {
                return nil
            }
            return .many(paths)
        default:
            return nil
        }
    }
}

public enum CodexAppServerRequestID:
    Codable,
    Equatable,
    Hashable,
    Sendable
{
    case string(String)
    case integer(Int64)

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(String.self) {
            self = .string(value)
        } else {
            self = .integer(try container.decode(Int64.self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .string(value):
            try container.encode(value)
        case let .integer(value):
            try container.encode(value)
        }
    }
}

public struct CodexAppServerResponse<Result>:
    Codable,
    Equatable,
    Sendable
where Result: Codable & Equatable & Sendable {
    public let id: CodexAppServerRequestID
    public let result: Result

    public init(id: CodexAppServerRequestID, result: Result) {
        self.id = id
        self.result = result
    }
}

public struct CodexAppServerErrorPayload:
    Codable,
    Equatable,
    Sendable
{
    public let code: Int64
    public let message: String
    public let data: CodexJSONValue?

    public init(code: Int64, message: String, data: CodexJSONValue?) {
        self.code = code
        self.message = message
        self.data = data
    }
}

public struct CodexAppServerErrorResponse:
    Codable,
    Equatable,
    Sendable
{
    public let id: CodexAppServerRequestID
    public let error: CodexAppServerErrorPayload

    public init(
        id: CodexAppServerRequestID,
        error: CodexAppServerErrorPayload
    ) {
        self.id = id
        self.error = error
    }
}

public enum CodexAppServerReply<Result>:
    Codable,
    Equatable,
    Sendable
where Result: Codable & Equatable & Sendable {
    case success(CodexAppServerResponse<Result>)
    case failure(CodexAppServerErrorResponse)

    private enum CodingKeys: String, CodingKey {
        case id
        case result
        case error
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(
            CodexAppServerRequestID.self,
            forKey: .id
        )
        if container.contains(.result) {
            self = .success(
                CodexAppServerResponse(
                    id: id,
                    result: try container.decode(Result.self, forKey: .result)
                )
            )
        } else {
            self = .failure(
                CodexAppServerErrorResponse(
                    id: id,
                    error: try container.decode(
                        CodexAppServerErrorPayload.self,
                        forKey: .error
                    )
                )
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .success(response):
            try container.encode(response.id, forKey: .id)
            try container.encode(response.result, forKey: .result)
        case let .failure(response):
            try container.encode(response.id, forKey: .id)
            try container.encode(response.error, forKey: .error)
        }
    }
}

public enum CodexAppServerThreadRequest: Equatable, Sendable {
    case list(id: CodexAppServerRequestID, params: CodexThreadListParams)
    case read(id: CodexAppServerRequestID, params: CodexThreadReadParams)
    case resume(id: CodexAppServerRequestID, params: CodexThreadResumeParams)
    case start(id: CodexAppServerRequestID, params: CodexThreadStartParams)
    case fork(id: CodexAppServerRequestID, params: CodexThreadForkParams)
    case search(id: CodexAppServerRequestID, params: CodexThreadSearchParams)
    case sectionList(
        id: CodexAppServerRequestID,
        params: CodexThreadSectionListParams
    )
    case sectionCreate(
        id: CodexAppServerRequestID,
        params: CodexThreadSectionCreateParams
    )
    case sectionUpdate(
        id: CodexAppServerRequestID,
        params: CodexThreadSectionUpdateParams
    )
    case sectionDelete(
        id: CodexAppServerRequestID,
        params: CodexThreadSectionDeleteParams
    )
    case sectionMove(
        id: CodexAppServerRequestID,
        params: CodexThreadSectionMoveParams
    )
    case metadataUpdate(
        id: CodexAppServerRequestID,
        params: CodexThreadMetadataUpdateParams
    )
    case settingsUpdate(
        id: CodexAppServerRequestID,
        params: CodexThreadSettingsUpdateParams
    )
    case memoryModeSet(
        id: CodexAppServerRequestID,
        params: CodexThreadMemoryModeSetParams
    )
    case gitDiffToRemote(
        id: CodexAppServerRequestID,
        params: CodexGitDiffToRemoteParams
    )
    case archive(id: CodexAppServerRequestID, threadID: CodexStoredThreadID)
    case unarchive(id: CodexAppServerRequestID, threadID: CodexStoredThreadID)
    case delete(id: CodexAppServerRequestID, threadID: CodexStoredThreadID)
    case unsubscribe(id: CodexAppServerRequestID, threadID: CodexStoredThreadID)
    case compactStart(
        id: CodexAppServerRequestID,
        threadID: CodexStoredThreadID
    )
    case injectItems(
        id: CodexAppServerRequestID,
        threadID: CodexStoredThreadID,
        items: [CodexJSONValue]
    )
    case shellCommand(
        id: CodexAppServerRequestID,
        threadID: CodexStoredThreadID,
        command: String
    )
    case approveGuardianDeniedAction(
        id: CodexAppServerRequestID,
        threadID: CodexStoredThreadID,
        event: CodexJSONValue
    )
    case rollback(
        id: CodexAppServerRequestID,
        threadID: CodexStoredThreadID,
        numTurns: UInt32
    )
    case revert(
        id: CodexAppServerRequestID,
        threadID: CodexStoredThreadID,
        beforeTurnID: String
    )
    case queueAdd(
        id: CodexAppServerRequestID,
        params: CodexThreadQueueAddParams
    )
    case queueList(
        id: CodexAppServerRequestID,
        params: CodexThreadQueueListParams
    )
    case queueUpdate(
        id: CodexAppServerRequestID,
        params: CodexThreadQueueUpdateParams
    )
    case queueDelete(
        id: CodexAppServerRequestID,
        params: CodexThreadQueueDeleteParams
    )
    case queueReorder(
        id: CodexAppServerRequestID,
        params: CodexThreadQueueReorderParams
    )
    case queueStart(
        id: CodexAppServerRequestID,
        params: CodexThreadQueueStartParams
    )
    case setName(
        id: CodexAppServerRequestID,
        threadID: CodexStoredThreadID,
        name: String
    )

    public func encodedData() throws -> Data {
        switch self {
        case let .list(id, params):
            if case .value = params.parentThreadID,
               case .value = params.ancestorThreadID
            {
                throw CodexAppServerThreadEnvelopeError
                    .mutuallyExclusiveThreadLineageFilters
            }
            return try encode(
                RequestEnvelope(
                    id: id,
                    method: "thread/list",
                    params: ThreadListWire(params)
                )
            )

        case let .read(id, params):
            return try encode(
                RequestEnvelope(
                    id: id,
                    method: "thread/read",
                    params: ThreadReadWire(params)
                )
            )

        case let .resume(id, params):
            return try encode(
                RequestEnvelope(
                    id: id,
                    method: "thread/resume",
                    params: ThreadResumeWire(params)
                )
            )

        case let .start(id, params):
            return try encode(
                RequestEnvelope(
                    id: id,
                    method: "thread/start",
                    params: ThreadStartWire(params)
                )
            )

        case let .fork(id, params):
            return try encode(
                RequestEnvelope(
                    id: id,
                    method: "thread/fork",
                    params: ThreadForkWire(params)
                )
            )

        case let .search(id, params):
            guard !params.searchTerm.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).isEmpty else {
                throw CodexAppServerThreadEnvelopeError.blankSearchTerm
            }
            return try encode(
                RequestEnvelope(
                    id: id,
                    method: "thread/search",
                    params: ThreadSearchWire(params)
                )
            )

        case let .sectionList(id, params):
            return try encode(
                RequestEnvelope(
                    id: id,
                    method: "threadSection/list",
                    params: ThreadSectionListWire(params)
                )
            )

        case let .sectionCreate(id, params):
            return try encode(
                RequestEnvelope(
                    id: id,
                    method: "threadSection/create",
                    params: ThreadSectionCreateWire(params)
                )
            )

        case let .sectionUpdate(id, params):
            return try encode(
                RequestEnvelope(
                    id: id,
                    method: "threadSection/update",
                    params: ThreadSectionUpdateWire(params)
                )
            )

        case let .sectionDelete(id, params):
            return try encode(
                RequestEnvelope(
                    id: id,
                    method: "threadSection/delete",
                    params: ThreadSectionDeleteWire(params)
                )
            )

        case let .sectionMove(id, params):
            guard case .omitted = params.sectionID else {
                return try encode(
                    RequestEnvelope(
                        id: id,
                        method: "thread/section/move",
                        params: ThreadSectionMoveWire(params)
                    )
                )
            }
            throw CodexAppServerThreadEnvelopeError
                .invalidThreadListParam("sectionId")

        case let .metadataUpdate(id, params):
            return try encode(
                RequestEnvelope(
                    id: id,
                    method: "thread/metadata/update",
                    params: ThreadMetadataUpdateWire(params)
                )
            )

        case let .settingsUpdate(id, params):
            return try encode(
                RequestEnvelope(
                    id: id,
                    method: "thread/settings/update",
                    params: ThreadSettingsUpdateWire(params)
                )
            )

        case let .memoryModeSet(id, params):
            return try encode(
                RequestEnvelope(
                    id: id,
                    method: "thread/memoryMode/set",
                    params: ThreadMemoryModeSetWire(params)
                )
            )

        case let .gitDiffToRemote(id, params):
            return try encode(
                RequestEnvelope(
                    id: id,
                    method: "gitDiffToRemote",
                    params: GitDiffToRemoteWire(params)
                )
            )

        case let .archive(id, threadID):
            return try encode(
                RequestEnvelope(
                    id: id,
                    method: "thread/archive",
                    params: ThreadIDWire(threadID: threadID)
                )
            )

        case let .unarchive(id, threadID):
            return try encode(
                RequestEnvelope(
                    id: id,
                    method: "thread/unarchive",
                    params: ThreadIDWire(threadID: threadID)
                )
            )

        case let .delete(id, threadID):
            return try encode(
                RequestEnvelope(
                    id: id,
                    method: "thread/delete",
                    params: ThreadIDWire(threadID: threadID)
                )
            )

        case let .unsubscribe(id, threadID):
            return try encode(
                RequestEnvelope(
                    id: id,
                    method: "thread/unsubscribe",
                    params: ThreadIDWire(threadID: threadID)
                )
            )

        case let .compactStart(id, threadID):
            return try encode(
                RequestEnvelope(
                    id: id,
                    method: "thread/compact/start",
                    params: ThreadIDWire(threadID: threadID)
                )
            )

        case let .injectItems(id, threadID, items):
            guard !items.isEmpty,
                  items.allSatisfy({
                      if case .object = $0 { return true }
                      return false
                  })
            else {
                throw CodexAppServerThreadEnvelopeError
                    .invalidThreadListParam("items")
            }
            return try encode(
                RequestEnvelope(
                    id: id,
                    method: "thread/inject_items",
                    params: ThreadInjectItemsWire(
                        threadID: threadID,
                        items: items
                    )
                )
            )

        case let .shellCommand(id, threadID, command):
            guard !command.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).isEmpty, !command.contains("\u{0}") else {
                throw CodexAppServerThreadEnvelopeError
                    .invalidThreadListParam("command")
            }
            return try encode(
                RequestEnvelope(
                    id: id,
                    method: "thread/shellCommand",
                    params: ThreadShellCommandWire(
                        threadID: threadID,
                        command: command
                    )
                )
            )

        case let .approveGuardianDeniedAction(id, threadID, event):
            return try encode(
                RequestEnvelope(
                    id: id,
                    method: "thread/approveGuardianDeniedAction",
                    params: ThreadApproveGuardianDeniedActionWire(
                        threadID: threadID,
                        event: event
                    )
                )
            )

        case let .rollback(id, threadID, numTurns):
            guard numTurns > 0 else {
                throw CodexAppServerThreadEnvelopeError
                    .invalidThreadListParam("numTurns")
            }
            return try encode(
                RequestEnvelope(
                    id: id,
                    method: "thread/rollback",
                    params: ThreadRollbackWire(
                        threadID: threadID,
                        numTurns: numTurns
                    )
                )
            )

        case let .revert(id, threadID, beforeTurnID):
            guard !beforeTurnID.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).isEmpty else {
                throw CodexAppServerThreadEnvelopeError
                    .invalidThreadListParam("beforeTurnId")
            }
            return try encode(
                RequestEnvelope(
                    id: id,
                    method: "thread/revert",
                    params: ThreadRevertWire(
                        threadID: threadID,
                        beforeTurnID: beforeTurnID
                    )
                )
            )

        case let .queueAdd(id, params):
            return try encode(
                RequestEnvelope(
                    id: id,
                    method: "thread/queue/add",
                    params: params
                )
            )

        case let .queueList(id, params):
            return try encode(
                RequestEnvelope(
                    id: id,
                    method: "thread/queue/list",
                    params: ThreadQueueListWire(params)
                )
            )

        case let .queueUpdate(id, params):
            return try encode(
                RequestEnvelope(
                    id: id,
                    method: "thread/queue/update",
                    params: params
                )
            )

        case let .queueDelete(id, params):
            return try encode(
                RequestEnvelope(
                    id: id,
                    method: "thread/queue/delete",
                    params: params
                )
            )

        case let .queueReorder(id, params):
            return try encode(
                RequestEnvelope(
                    id: id,
                    method: "thread/queue/reorder",
                    params: params
                )
            )

        case let .queueStart(id, params):
            return try encode(
                RequestEnvelope(
                    id: id,
                    method: "thread/queue/start",
                    params: ThreadQueueStartWire(params)
                )
            )

        case let .setName(id, threadID, name):
            guard !name.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).isEmpty else {
                throw CodexAppServerThreadEnvelopeError
                    .invalidThreadListParam("name")
            }
            return try encode(
                RequestEnvelope(
                    id: id,
                    method: "thread/name/set",
                    params: ThreadSetNameWire(
                        threadID: threadID,
                        name: name
                    )
                )
            )
        }
    }
}

public struct CodexThreadQueueAddParams:
    Codable,
    Equatable,
    Sendable
{
    public let threadID: CodexStoredThreadID
    public let input: [CodexStoredUserInput]
    public let clientUserMessageID: String

    public init(
        threadID: CodexStoredThreadID,
        input: [CodexStoredUserInput],
        clientUserMessageID: String
    ) {
        self.threadID = threadID
        self.input = input
        self.clientUserMessageID = clientUserMessageID
    }

    private enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case input
        case clientUserMessageID = "clientUserMessageId"
    }
}

public struct CodexThreadQueueAddResponse:
    Codable,
    Equatable,
    Sendable
{
    public let queuedSubmission: CodexQueuedSubmission
}

public struct CodexThreadQueueListParams: Equatable, Sendable {
    public let threadID: CodexStoredThreadID
    public let cursor: CodexWireOptional<String>
    public let limit: CodexWireOptional<UInt32>

    public init(
        threadID: CodexStoredThreadID,
        cursor: CodexWireOptional<String> = .omitted,
        limit: CodexWireOptional<UInt32> = .omitted
    ) {
        self.threadID = threadID
        self.cursor = cursor
        self.limit = limit
    }
}

public struct CodexThreadQueueListResponse:
    Codable,
    Equatable,
    Sendable
{
    public let data: [CodexQueuedSubmission]
    public let nextCursor: String?
}

public struct CodexThreadQueueUpdateParams:
    Codable,
    Equatable,
    Sendable
{
    public let threadID: CodexStoredThreadID
    public let queuedSubmissionID: String
    public let input: [CodexStoredUserInput]

    public init(
        threadID: CodexStoredThreadID,
        queuedSubmissionID: String,
        input: [CodexStoredUserInput]
    ) {
        self.threadID = threadID
        self.queuedSubmissionID = queuedSubmissionID
        self.input = input
    }

    private enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case queuedSubmissionID = "queuedSubmissionId"
        case input
    }
}

public struct CodexThreadQueueUpdateResponse:
    Codable,
    Equatable,
    Sendable
{
    public let queuedSubmission: CodexQueuedSubmission
}

public struct CodexThreadQueueDeleteParams:
    Codable,
    Equatable,
    Sendable
{
    public let threadID: CodexStoredThreadID
    public let queuedSubmissionID: String

    public init(
        threadID: CodexStoredThreadID,
        queuedSubmissionID: String
    ) {
        self.threadID = threadID
        self.queuedSubmissionID = queuedSubmissionID
    }

    private enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case queuedSubmissionID = "queuedSubmissionId"
    }
}

public struct CodexThreadQueueDeleteResponse:
    Codable,
    Equatable,
    Sendable
{
    public let deleted: Bool
}

public struct CodexThreadQueueReorderParams:
    Codable,
    Equatable,
    Sendable
{
    public let threadID: CodexStoredThreadID
    public let queuedSubmissionIDs: [String]

    public init(
        threadID: CodexStoredThreadID,
        queuedSubmissionIDs: [String]
    ) {
        self.threadID = threadID
        self.queuedSubmissionIDs = queuedSubmissionIDs
    }

    private enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case queuedSubmissionIDs = "queuedSubmissionIds"
    }
}

public struct CodexThreadQueueReorderResponse:
    Codable,
    Equatable,
    Sendable
{
    public init() {}
}

public struct CodexThreadQueueStartParams: Equatable, Sendable {
    public let threadID: CodexStoredThreadID
    public let queuedSubmissionID: CodexWireOptional<String>

    public init(
        threadID: CodexStoredThreadID,
        queuedSubmissionID: CodexWireOptional<String> = .omitted
    ) {
        self.threadID = threadID
        self.queuedSubmissionID = queuedSubmissionID
    }
}

public struct CodexThreadQueueStartResponse:
    Codable,
    Equatable,
    Sendable
{
    public let turn: CodexStoredTurn
}

public struct CodexThreadEmptyResponse:
    Codable,
    Equatable,
    Sendable
{
    public init() {}
}

public enum CodexThreadUnsubscribeStatus: String, Codable, Sendable {
    case notLoaded
    case notSubscribed
    case unsubscribed
}

public struct CodexThreadUnsubscribeResponse:
    Codable, Equatable, Sendable
{
    public let status: CodexThreadUnsubscribeStatus
}

public struct CodexThreadUnarchiveResponse:
    Codable,
    Equatable,
    Sendable
{
    public let thread: CodexStoredThread

    public init(thread: CodexStoredThread) {
        self.thread = thread
    }
}

private struct RequestEnvelope<Params: Encodable>: Encodable {
    let id: CodexAppServerRequestID
    let method: String
    let params: Params
}

private struct ThreadQueueListWire: Encodable {
    let params: CodexThreadQueueListParams

    init(_ params: CodexThreadQueueListParams) {
        self.params = params
    }

    private enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case cursor
        case limit
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(params.threadID, forKey: .threadID)
        try encodeWireOptional(params.cursor, forKey: .cursor, into: &container)
        try encodeWireOptional(params.limit, forKey: .limit, into: &container)
    }
}

private struct ThreadQueueStartWire: Encodable {
    let params: CodexThreadQueueStartParams

    init(_ params: CodexThreadQueueStartParams) {
        self.params = params
    }

    private enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case queuedSubmissionID = "queuedSubmissionId"
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(params.threadID, forKey: .threadID)
        try encodeWireOptional(
            params.queuedSubmissionID,
            forKey: .queuedSubmissionID,
            into: &container
        )
    }
}

private struct GitDiffToRemoteWire: Encodable {
    let cwd: String

    init(_ params: CodexGitDiffToRemoteParams) {
        cwd = params.cwd
    }
}

private struct ThreadIDWire: Encodable {
    let threadID: CodexStoredThreadID

    private enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
    }
}

private struct ThreadSetNameWire: Encodable {
    let threadID: CodexStoredThreadID
    let name: String

    private enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case name
    }
}

private struct ThreadRollbackWire: Encodable {
    let threadID: CodexStoredThreadID
    let numTurns: UInt32

    private enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case numTurns
    }
}

private struct ThreadRevertWire: Encodable {
    let threadID: CodexStoredThreadID
    let beforeTurnID: String

    private enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case beforeTurnID = "beforeTurnId"
    }
}

private struct ThreadInjectItemsWire: Encodable {
    let threadID: CodexStoredThreadID
    let items: [CodexJSONValue]

    private enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case items
    }
}

private struct ThreadShellCommandWire: Encodable {
    let threadID: CodexStoredThreadID
    let command: String

    private enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case command
    }
}

private struct ThreadApproveGuardianDeniedActionWire: Encodable {
    let threadID: CodexStoredThreadID
    let event: CodexJSONValue

    private enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case event
    }
}

private struct ThreadListWire: Encodable {
    let params: CodexThreadListParams

    init(_ params: CodexThreadListParams) {
        self.params = params
    }

    private enum CodingKeys: String, CodingKey {
        case cursor
        case limit
        case sortKey
        case sortDirection
        case modelProviders
        case sourceKinds
        case archived
        case isPinned
        case cwd
        case useStateDbOnly
        case searchTerm
        case parentThreadID = "parentThreadId"
        case ancestorThreadID = "ancestorThreadId"
        case sectionId = "sectionId"
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try encodeWireOptional(
            params.cursor,
            forKey: .cursor,
            into: &container
        )
        try encodeWireOptional(
            params.limit,
            forKey: .limit,
            into: &container
        )
        try encodeWireOptional(
            params.sortKey,
            forKey: .sortKey,
            into: &container
        )
        try encodeWireOptional(
            params.sortDirection,
            forKey: .sortDirection,
            into: &container
        )
        try encodeWireOptional(
            params.modelProviders,
            forKey: .modelProviders,
            into: &container
        )
        try encodeWireOptional(
            params.sourceKinds,
            forKey: .sourceKinds,
            into: &container
        )
        try encodeWireOptional(
            params.archived,
            forKey: .archived,
            into: &container
        )
        try encodeWireOptional(
            params.isPinned,
            forKey: .isPinned,
            into: &container
        )
        switch params.cwd {
        case .omitted:
            break
        case .null:
            try container.encodeNil(forKey: .cwd)
        case let .value(.one(path)):
            try container.encode(path, forKey: .cwd)
        case let .value(.many(paths)):
            try container.encode(paths, forKey: .cwd)
        }
        try container.encodeIfPresent(
            params.useStateDbOnly,
            forKey: .useStateDbOnly
        )
        try encodeWireOptional(
            params.searchTerm,
            forKey: .searchTerm,
            into: &container
        )
        try encodeWireOptional(
            params.parentThreadID,
            forKey: .parentThreadID,
            into: &container
        )
        try encodeWireOptional(
            params.ancestorThreadID,
            forKey: .ancestorThreadID,
            into: &container
        )
        try encodeWireOptional(
            params.sectionId,
            forKey: .sectionId,
            into: &container
        )
    }
}

private struct ThreadSectionListWire: Encodable {
    let params: CodexThreadSectionListParams

    init(_ params: CodexThreadSectionListParams) {
        self.params = params
    }

    private enum CodingKeys: String, CodingKey {
        case cursor
        case limit
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try encodeWireOptional(
            params.cursor,
            forKey: .cursor,
            into: &container
        )
        try encodeWireOptional(
            params.limit,
            forKey: .limit,
            into: &container
        )
    }
}

private struct ThreadSectionCreateWire: Encodable {
    let name: String

    init(_ params: CodexThreadSectionCreateParams) {
        name = params.name
    }
}

private struct ThreadSectionUpdateWire: Encodable {
    let sectionID: String
    let name: String

    init(_ params: CodexThreadSectionUpdateParams) {
        sectionID = params.sectionID
        name = params.name
    }

    private enum CodingKeys: String, CodingKey {
        case sectionID = "sectionId"
        case name
    }
}

private struct ThreadSectionDeleteWire: Encodable {
    let sectionID: String

    init(_ params: CodexThreadSectionDeleteParams) {
        sectionID = params.sectionID
    }

    private enum CodingKeys: String, CodingKey {
        case sectionID = "sectionId"
    }
}

private struct ThreadSectionMoveWire: Encodable {
    let params: CodexThreadSectionMoveParams

    init(_ params: CodexThreadSectionMoveParams) {
        self.params = params
    }

    private enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case sectionID = "sectionId"
        case beforeThreadID = "beforeThreadId"
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(params.threadID.rawValue, forKey: .threadID)
        try encodeWireOptional(
            params.sectionID,
            forKey: .sectionID,
            into: &container
        )
        try encodeWireOptional(
            params.beforeThreadID,
            forKey: .beforeThreadID,
            into: &container
        )
    }
}

private struct ThreadReadWire: Encodable {
    let threadID: String
    let includeTurns: Bool?

    init(_ params: CodexThreadReadParams) {
        threadID = params.threadID.rawValue
        includeTurns = params.includeTurns
    }

    private enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case includeTurns
    }
}

private struct ThreadResumeWire: Encodable {
    let params: CodexThreadResumeParams

    init(_ params: CodexThreadResumeParams) {
        self.params = params
    }

    private enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case model
        case modelProvider
        case serviceTier
        case cwd
        case approvalPolicy
        case approvalsReviewer
        case sandbox
        case config
        case baseInstructions
        case developerInstructions
        case personality
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(params.threadID.rawValue, forKey: .threadID)
        try encodeWireOptional(
            params.model,
            forKey: .model,
            into: &container
        )
        try encodeWireOptional(
            params.modelProvider,
            forKey: .modelProvider,
            into: &container
        )
        try encodeWireOptional(
            params.serviceTier,
            forKey: .serviceTier,
            into: &container
        )
        try encodeWireOptional(
            params.cwd,
            forKey: .cwd,
            into: &container
        )
        try encodeWireOptional(
            params.approvalPolicy,
            forKey: .approvalPolicy,
            into: &container
        )
        try encodeWireOptional(
            params.approvalsReviewer,
            forKey: .approvalsReviewer,
            into: &container
        )
        try encodeWireOptional(
            params.sandbox,
            forKey: .sandbox,
            into: &container
        )
        try encodeWireOptional(
            params.config,
            forKey: .config,
            into: &container
        )
        try encodeWireOptional(
            params.baseInstructions,
            forKey: .baseInstructions,
            into: &container
        )
        try encodeWireOptional(
            params.developerInstructions,
            forKey: .developerInstructions,
            into: &container
        )
        try encodeWireOptional(
            params.personality,
            forKey: .personality,
            into: &container
        )
    }
}

private struct ThreadForkWire: Encodable {
    let params: CodexThreadForkParams

    init(_ params: CodexThreadForkParams) {
        self.params = params
    }

    private enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case lastTurnID = "lastTurnId"
        case path
        case model
        case modelProvider
        case serviceTier
        case cwd
        case approvalPolicy
        case approvalsReviewer
        case sandbox
        case config
        case baseInstructions
        case developerInstructions
        case ephemeral
        case threadSource
        case excludeTurns
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        let resume = params.resume
        try container.encode(resume.threadID.rawValue, forKey: .threadID)
        try encodeWireOptional(params.lastTurnID, forKey: .lastTurnID, into: &container)
        try encodeWireOptional(params.path, forKey: .path, into: &container)
        try encodeWireOptional(resume.model, forKey: .model, into: &container)
        try encodeWireOptional(resume.modelProvider, forKey: .modelProvider, into: &container)
        try encodeWireOptional(resume.serviceTier, forKey: .serviceTier, into: &container)
        try encodeWireOptional(resume.cwd, forKey: .cwd, into: &container)
        try encodeWireOptional(resume.approvalPolicy, forKey: .approvalPolicy, into: &container)
        try encodeWireOptional(resume.approvalsReviewer, forKey: .approvalsReviewer, into: &container)
        try encodeWireOptional(resume.sandbox, forKey: .sandbox, into: &container)
        try encodeWireOptional(resume.config, forKey: .config, into: &container)
        try encodeWireOptional(resume.baseInstructions, forKey: .baseInstructions, into: &container)
        try encodeWireOptional(
            resume.developerInstructions,
            forKey: .developerInstructions,
            into: &container
        )
        try container.encodeIfPresent(params.ephemeral, forKey: .ephemeral)
        try encodeWireOptional(params.threadSource, forKey: .threadSource, into: &container)
        try container.encodeIfPresent(params.excludeTurns, forKey: .excludeTurns)
    }
}

private struct ThreadStartWire: Encodable {
    let params: CodexThreadStartParams
    init(_ params: CodexThreadStartParams) { self.params = params }

    private var portableConfig: CodexWireOptional<[String: CodexJSONValue]> {
        switch params.config {
        case .omitted:
            return .omitted
        case .null:
            return .null
        case let .value(config):
            var supported = config
            // The released renderer can send its selected model both as the
            // canonical top-level field and as a stale config snapshot. The
            // embedded core deliberately rejects conflicting duplicates, so
            // keep config.model only when the top-level field was omitted.
            if case .omitted = params.model {
                // Preserve the config-only compatibility path.
            } else {
                supported.removeValue(forKey: "model")
            }
            return supported.isEmpty ? .omitted : .value(supported)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case mode, model, modelProvider, serviceTier, cwd, approvalPolicy
        case approvalsReviewer, sandbox, config, serviceName
        case baseInstructions, developerInstructions, personality
        case ephemeral, sessionStartSource, threadSource
        case allowProviderModelFallback, dynamicTools, environments
        case experimentalRawEvents, historyMode, mockExperimentalField
        case multiAgentMode, permissions, runtimeWorkspaceRoots
        case selectedCapabilityRoots, threadStartKind
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try encodeWireOptional(params.mode, forKey: .mode, into: &container)
        try encodeWireOptional(params.model, forKey: .model, into: &container)
        try encodeWireOptional(params.modelProvider, forKey: .modelProvider, into: &container)
        try encodeWireOptional(params.serviceTier, forKey: .serviceTier, into: &container)
        try encodeWireOptional(params.cwd, forKey: .cwd, into: &container)
        try encodeWireOptional(params.approvalPolicy, forKey: .approvalPolicy, into: &container)
        try encodeWireOptional(params.approvalsReviewer, forKey: .approvalsReviewer, into: &container)
        try encodeWireOptional(params.sandbox, forKey: .sandbox, into: &container)
        try encodeWireOptional(portableConfig, forKey: .config, into: &container)
        try encodeWireOptional(params.serviceName, forKey: .serviceName, into: &container)
        try encodeWireOptional(params.baseInstructions, forKey: .baseInstructions, into: &container)
        try encodeWireOptional(
            params.developerInstructions,
            forKey: .developerInstructions,
            into: &container
        )
        try encodeWireOptional(params.personality, forKey: .personality, into: &container)
        try encodeWireOptional(params.ephemeral, forKey: .ephemeral, into: &container)
        try encodeWireOptional(
            params.sessionStartSource,
            forKey: .sessionStartSource,
            into: &container
        )
        try encodeWireOptional(params.threadSource, forKey: .threadSource, into: &container)
        try encodeWireOptional(
            params.allowProviderModelFallback,
            forKey: .allowProviderModelFallback,
            into: &container
        )
        try encodeWireOptional(params.dynamicTools, forKey: .dynamicTools, into: &container)
        try encodeWireOptional(params.environments, forKey: .environments, into: &container)
        try encodeWireOptional(
            params.experimentalRawEvents,
            forKey: .experimentalRawEvents,
            into: &container
        )
        try encodeWireOptional(params.historyMode, forKey: .historyMode, into: &container)
        try encodeWireOptional(
            params.mockExperimentalField,
            forKey: .mockExperimentalField,
            into: &container
        )
        try encodeWireOptional(params.multiAgentMode, forKey: .multiAgentMode, into: &container)
        try encodeWireOptional(params.permissions, forKey: .permissions, into: &container)
        try encodeWireOptional(
            params.runtimeWorkspaceRoots,
            forKey: .runtimeWorkspaceRoots,
            into: &container
        )
        try encodeWireOptional(
            params.selectedCapabilityRoots,
            forKey: .selectedCapabilityRoots,
            into: &container
        )
        try encodeWireOptional(
            params.threadStartKind,
            forKey: .threadStartKind,
            into: &container
        )
    }
}

private struct ThreadSearchWire: Encodable {
    let params: CodexThreadSearchParams

    init(_ params: CodexThreadSearchParams) {
        self.params = params
    }

    private enum CodingKeys: String, CodingKey {
        case cursor
        case limit
        case sortKey
        case sortDirection
        case sourceKinds
        case archived
        case searchTerm
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try encodeWireOptional(
            params.cursor,
            forKey: .cursor,
            into: &container
        )
        try encodeWireOptional(
            params.limit,
            forKey: .limit,
            into: &container
        )
        try encodeWireOptional(
            params.sortKey,
            forKey: .sortKey,
            into: &container
        )
        try encodeWireOptional(
            params.sortDirection,
            forKey: .sortDirection,
            into: &container
        )
        try encodeWireOptional(
            params.sourceKinds,
            forKey: .sourceKinds,
            into: &container
        )
        try encodeWireOptional(
            params.archived,
            forKey: .archived,
            into: &container
        )
        try container.encode(params.searchTerm, forKey: .searchTerm)
    }
}

private struct ThreadMetadataUpdateWire: Encodable {
    let params: CodexThreadMetadataUpdateParams

    init(_ params: CodexThreadMetadataUpdateParams) {
        self.params = params
    }

    private enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case gitInfo
        case isPinned
        case sectionId = "sectionId"
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(params.threadID.rawValue, forKey: .threadID)
        switch params.gitInfo {
        case .omitted:
            break
        case .null:
            try container.encodeNil(forKey: .gitInfo)
        case let .value(patch):
            try container.encode(
                ThreadGitInfoPatchWire(patch),
                forKey: .gitInfo
            )
        }
        try encodeWireOptional(
            params.isPinned,
            forKey: .isPinned,
            into: &container
        )
        try encodeWireOptional(
            params.sectionId,
            forKey: .sectionId,
            into: &container
        )
    }
}

private struct ThreadSettingsUpdateWire: Encodable {
    let params: CodexThreadSettingsUpdateParams

    init(_ params: CodexThreadSettingsUpdateParams) {
        self.params = params
    }

    private enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case cwd
        case approvalPolicy
        case approvalsReviewer
        case sandboxPolicy
        case permissions
        case model
        case serviceTier
        case effort
        case summary
        case collaborationMode
        case multiAgentMode
        case personality
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(params.threadID.rawValue, forKey: .threadID)
        try encodeWireOptional(params.cwd, forKey: .cwd, into: &container)
        try encodeWireOptional(
            params.approvalPolicy,
            forKey: .approvalPolicy,
            into: &container
        )
        try encodeWireOptional(
            params.approvalsReviewer,
            forKey: .approvalsReviewer,
            into: &container
        )
        try encodeWireOptional(
            params.sandboxPolicy,
            forKey: .sandboxPolicy,
            into: &container
        )
        try encodeWireOptional(
            params.permissions,
            forKey: .permissions,
            into: &container
        )
        try encodeWireOptional(
            params.model,
            forKey: .model,
            into: &container
        )
        try encodeWireOptional(
            params.serviceTier,
            forKey: .serviceTier,
            into: &container
        )
        try encodeWireOptional(
            params.effort,
            forKey: .effort,
            into: &container
        )
        try encodeWireOptional(
            params.summary,
            forKey: .summary,
            into: &container
        )
        try encodeWireOptional(
            params.collaborationMode,
            forKey: .collaborationMode,
            into: &container
        )
        try encodeWireOptional(
            params.multiAgentMode,
            forKey: .multiAgentMode,
            into: &container
        )
        try encodeWireOptional(
            params.personality,
            forKey: .personality,
            into: &container
        )
    }
}

private struct ThreadMemoryModeSetWire: Encodable {
    let threadID: String
    let mode: CodexThreadMemoryMode

    init(_ params: CodexThreadMemoryModeSetParams) {
        threadID = params.threadID.rawValue
        mode = params.mode
    }

    private enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case mode
    }
}

private struct ThreadGitInfoPatchWire: Encodable {
    let patch: CodexThreadGitInfoPatch

    init(_ patch: CodexThreadGitInfoPatch) {
        self.patch = patch
    }

    private enum CodingKeys: String, CodingKey {
        case sha
        case branch
        case originURL = "originUrl"
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try encodePatchField(
            patch.sha,
            forKey: .sha,
            into: &container
        )
        try encodePatchField(
            patch.branch,
            forKey: .branch,
            into: &container
        )
        try encodePatchField(
            patch.originURL,
            forKey: .originURL,
            into: &container
        )
    }
}

private func encodeWireOptional<Value, Key>(
    _ field: CodexWireOptional<Value>,
    forKey key: Key,
    into container: inout KeyedEncodingContainer<Key>
) throws where
    Value: Encodable & Equatable & Sendable,
    Key: CodingKey
{
    switch field {
    case .omitted:
        break
    case .null:
        try container.encodeNil(forKey: key)
    case let .value(value):
        try container.encode(value, forKey: key)
    }
}

private func encodePatchField<Value, Key>(
    _ field: CodexPatchField<Value>,
    forKey key: Key,
    into container: inout KeyedEncodingContainer<Key>
) throws where
    Value: Encodable & Equatable & Sendable,
    Key: CodingKey
{
    switch field {
    case .keep:
        break
    case .clear:
        try container.encodeNil(forKey: key)
    case let .set(value):
        try container.encode(value, forKey: key)
    }
}

private func encode(_ value: some Encodable) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(value)
}
