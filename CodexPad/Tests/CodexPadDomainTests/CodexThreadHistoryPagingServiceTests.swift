import CodexPadApplication
import CodexPadDomain
import CodexPadProtocolBridge
import Foundation
import Testing

@MainActor
private final class ThreadHistoryTransport: CodexCoreTransport {
    private(set) var requested: [CodexAppServerThreadRequest] = []
    var replies: [Data]

    init(replies: [Data]) {
        self.replies = replies
    }

    func submit(_ command: CodexCoreCommand) throws {}

    func request(
        _ request: CodexAppServerThreadRequest
    ) throws -> Data {
        requested.append(request)
        guard !replies.isEmpty else {
            throw CodexSessionStoreError.invalidReply
        }
        return replies.removeFirst()
    }

    func nextEvent() throws -> CodexCoreEvent? { nil }
}

@MainActor
@Test
func threadHistoryTurnsDefaultToDescendingSummaryAndPage()
    async throws
{
    let thread = threadHistoryStoredThread()
    let reply = try threadHistoryReply(
        id: .integer(7_001),
        thread: thread
    )
    let transport = ThreadHistoryTransport(
        replies: [reply, reply]
    )
    let store = CodexSessionStore(transport: transport)

    let first = await threadHistoryRequest(
        id: 7_001,
        method: "thread/turns/list",
        params: [
            "threadId": .string(thread.id.rawValue),
            "limit": .integer(1),
        ],
        store: store
    )
    let firstResult = try #require(
        threadHistoryResult(first)
    )
    guard case let .array(firstData)? =
        firstResult["data"],
        case let .object(firstTurn) =
            try #require(firstData.first),
        case let .array(firstItems)? = firstTurn["items"],
        case let .string(nextCursor)? =
            firstResult["nextCursor"]
    else {
        Issue.record("invalid first turns page")
        return
    }
    #expect(firstTurn["id"] == .string("turn-2"))
    #expect(firstTurn["itemsView"] == .string("summary"))
    #expect(firstItems.count == 2)

    let second = await threadHistoryRequest(
        id: 7_001,
        method: "thread/turns/list",
        params: [
            "threadId": .string(thread.id.rawValue),
            "limit": .integer(1),
            "cursor": .string(nextCursor),
        ],
        store: store
    )
    let secondResult = try #require(
        threadHistoryResult(second)
    )
    guard case let .array(secondData)? =
        secondResult["data"],
        case let .object(secondTurn) =
            try #require(secondData.first)
    else {
        Issue.record("invalid second turns page")
        return
    }
    #expect(secondTurn["id"] == .string("turn-1"))
    #expect(secondResult["nextCursor"] == .null)
    #expect(transport.requested.count == 2)
}

@MainActor
@Test
func threadHistoryItemsDefaultAscendingAndFilterByTurn()
    async throws
{
    let thread = threadHistoryStoredThread()
    let transport = ThreadHistoryTransport(
        replies: [
            try threadHistoryReply(
                id: .integer(7_101),
                thread: thread
            ),
        ]
    )
    let store = CodexSessionStore(transport: transport)
    let response = await threadHistoryRequest(
        id: 7_101,
        method: "thread/items/list",
        params: [
            "threadId": .string(thread.id.rawValue),
            "turnId": .string("turn-2"),
        ],
        store: store
    )
    let result = try #require(threadHistoryResult(response))
    guard case let .array(data)? = result["data"] else {
        Issue.record("missing items data")
        return
    }
    #expect(data.count == 3)
    var turnIDs: [String] = []
    let itemIDs = data.compactMap { value -> String? in
            guard case let .object(entry) = value,
                  case let .object(item)? = entry["item"],
                  case let .string(id)? = item["id"]
            else { return nil }
            if case let .string(turnID)? = entry["turnId"] {
                turnIDs.append(turnID)
            }
            return id
        }
    #expect(turnIDs == ["turn-2", "turn-2", "turn-2"])
    #expect(itemIDs == ["user-2", "reasoning-2", "agent-2"])
}

@MainActor
@Test
func threadHistoryRouterRejectsInvalidOfficialParamsAndCursor()
    async throws
{
    let thread = threadHistoryStoredThread()
    let transport = ThreadHistoryTransport(
        replies: [
            try threadHistoryReply(
                id: .integer(7_201),
                thread: thread
            ),
        ]
    )
    let store = CodexSessionStore(transport: transport)
    let invalid: [(String, [String: CodexJSONValue])] = [
        (
            "thread/turns/list",
            ["threadId": .string(""), "itemsView": .string("full")]
        ),
        (
            "thread/turns/list",
            [
                "threadId": .string(thread.id.rawValue),
                "itemsView": .string("unknown"),
            ]
        ),
        (
            "thread/items/list",
            [
                "threadId": .string(thread.id.rawValue),
                "turnId": .string(""),
            ]
        ),
        (
            "thread/items/list",
            [
                "threadId": .string(thread.id.rawValue),
                "sortDirection": .string("newest"),
            ]
        ),
        (
            "thread/items/list",
            [
                "threadId": .string(thread.id.rawValue),
                "limit": .integer(-1),
            ]
        ),
    ]
    for (offset, entry) in invalid.enumerated() {
        let response = await threadHistoryRequest(
            id: Int64(7_200 + offset),
            method: entry.0,
            params: entry.1,
            store: store
        )
        #expect(threadHistoryErrorCode(response) == -32602)
    }
    #expect(transport.requested.isEmpty)

    let cursorResponse = await threadHistoryRequest(
        id: 7_201,
        method: "thread/turns/list",
        params: [
            "threadId": .string(thread.id.rawValue),
            "cursor": .string("not-a-valid-cursor"),
        ],
        store: store
    )
    #expect(threadHistoryErrorCode(cursorResponse) == -32602)
    #expect(transport.requested.count == 1)
}

@MainActor
@Test
func threadSearchOccurrencesUsesVisibleMessagesUTF16AndPagination()
    async throws
{
    var thread = threadHistoryStoredThread()
    thread.turns[0] = .init(
        id: "turn-1",
        items: [
            .userMessage(
                id: "user-1",
                clientID: nil,
                content: [
                    .text(
                        text: "## My request for Codex: 😀Alpha alpha",
                        textElements: []
                    ),
                ]
            ),
            .reasoning(
                id: "hidden",
                summary: ["alpha"],
                content: ["alpha"]
            ),
            .agentMessage(
                id: "agent-old",
                text: "alpha old draft",
                phase: nil,
                memoryCitation: nil
            ),
            .agentMessage(
                id: "agent-1",
                text: "**Alpha** final",
                phase: .finalAnswer,
                memoryCitation: nil
            ),
        ],
        status: .completed
    )
    let reply = try threadHistoryReply(
        id: .integer(7_301),
        thread: thread
    )
    let store = CodexSessionStore(
        transport: ThreadHistoryTransport(
            replies: [reply, reply, reply]
        )
    )
    let first = await threadHistoryRequest(
        id: 7_301,
        method: "thread/searchOccurrences",
        params: [
            "threadId": .string(thread.id.rawValue),
            "searchTerm": .string("ALPHA"),
            "limit": .integer(2),
        ],
        store: store
    )
    let firstResult = try #require(threadHistoryResult(first))
    guard case let .array(firstData)? = firstResult["data"],
          firstData.count == 2,
          case let .object(firstOccurrence) = firstData[0],
          case let .object(firstRange)? =
              firstOccurrence["snippetMatchRange"],
          case let .string(nextCursor)? =
              firstResult["nextCursor"]
    else {
        Issue.record("invalid first occurrence page")
        return
    }
    #expect(firstOccurrence["itemId"] == .string("user-1"))
    #expect(firstOccurrence["snippet"] == .string("😀Alpha alpha"))
    #expect(firstRange["start"] == .integer(2))
    #expect(firstRange["end"] == .integer(7))

    let second = await threadHistoryRequest(
        id: 7_301,
        method: "thread/searchOccurrences",
        params: [
            "threadId": .string(thread.id.rawValue),
            "searchTerm": .string("ALPHA"),
            "limit": .integer(2),
            "cursor": .string(nextCursor),
        ],
        store: store
    )
    let secondResult = try #require(threadHistoryResult(second))
    guard case let .array(secondData)? = secondResult["data"]
    else {
        Issue.record("missing second occurrence page")
        return
    }
    #expect(secondData.count == 1)
    guard case let .object(finalOccurrence) =
        try #require(secondData.first)
    else { return }
    #expect(finalOccurrence["itemId"] == .string("agent-1"))
    #expect(finalOccurrence["snippet"] == .string("Alpha final"))
    #expect(secondResult["nextCursor"] == .null)

    guard case let .string(turnCursor)? =
        finalOccurrence["turnCursor"]
    else {
        Issue.record("missing turn cursor")
        return
    }
    let turnPage = await threadHistoryRequest(
        id: 7_301,
        method: "thread/turns/list",
        params: [
            "threadId": .string(thread.id.rawValue),
            "cursor": .string(turnCursor),
            "sortDirection": .string("asc"),
            "limit": .integer(1),
        ],
        store: store
    )
    guard case let .array(turns)? =
        try #require(threadHistoryResult(turnPage))["data"],
        case let .object(turn)? = turns.first
    else {
        Issue.record("occurrence cursor did not navigate")
        return
    }
    #expect(turn["id"] == .string("turn-1"))
}

@MainActor
@Test
func threadSearchOccurrencesRejectsEmptyTermAndMismatchedCursor()
    async throws
{
    let thread = threadHistoryStoredThread()
    let reply = try threadHistoryReply(
        id: .integer(7_401),
        thread: thread
    )
    let store = CodexSessionStore(
        transport: ThreadHistoryTransport(
            replies: [reply, reply]
        )
    )
    let empty = await threadHistoryRequest(
        id: 7_400,
        method: "thread/searchOccurrences",
        params: [
            "threadId": .string(thread.id.rawValue),
            "searchTerm": .string("  "),
        ],
        store: store
    )
    #expect(threadHistoryErrorCode(empty) == -32602)

    let first = await threadHistoryRequest(
        id: 7_401,
        method: "thread/searchOccurrences",
        params: [
            "threadId": .string(thread.id.rawValue),
            "searchTerm": .string("first"),
            "limit": .integer(1),
        ],
        store: store
    )
    let result = try #require(threadHistoryResult(first))
    guard case let .string(cursor)? = result["nextCursor"]
    else {
        Issue.record("missing search cursor")
        return
    }
    let mismatched = await threadHistoryRequest(
        id: 7_401,
        method: "thread/searchOccurrences",
        params: [
            "threadId": .string(thread.id.rawValue),
            "searchTerm": .string("second"),
            "cursor": .string(cursor),
        ],
        store: store
    )
    #expect(threadHistoryErrorCode(mismatched) == -32602)
}

private func threadHistoryStoredThread() -> CodexStoredThread {
    .init(
        id: .init("thread-history"),
        sessionID: "session-history",
        preview: "History",
        ephemeral: false,
        modelProvider: "openai",
        createdAt: 1,
        updatedAt: 2,
        status: .idle,
        cwd: "/workspace",
        cliVersion: "1.0.0",
        source: .named("cli"),
        turns: [
            .init(
                id: "turn-1",
                items: [
                    .userMessage(
                        id: "user-1",
                        clientID: nil,
                        content: [
                            .text(text: "first", textElements: []),
                        ]
                    ),
                    .agentMessage(
                        id: "agent-1",
                        text: "first answer",
                        phase: .finalAnswer,
                        memoryCitation: nil
                    ),
                ],
                status: .completed
            ),
            .init(
                id: "turn-2",
                items: [
                    .userMessage(
                        id: "user-2",
                        clientID: nil,
                        content: [
                            .text(text: "second", textElements: []),
                        ]
                    ),
                    .reasoning(
                        id: "reasoning-2",
                        summary: ["work"],
                        content: []
                    ),
                    .agentMessage(
                        id: "agent-2",
                        text: "second answer",
                        phase: .finalAnswer,
                        memoryCitation: nil
                    ),
                ],
                status: .completed
            ),
        ]
    )
}

private func threadHistoryReply(
    id: CodexAppServerRequestID,
    thread: CodexStoredThread
) throws -> Data {
    try JSONEncoder().encode(
        CodexAppServerReply<CodexThreadReadResult>.success(
            .init(
                id: id,
                result: .init(thread: thread)
            )
        )
    )
}

@MainActor
private func threadHistoryRequest(
    id: Int64,
    method: String,
    params: [String: CodexJSONValue],
    store: CodexSessionStore
) async -> CodexDesktopHostMessage {
    await CodexDesktopInitialMCPRouter
        .responseIncludingFileSystem(
            to: .init(
                request: .init(
                    id: .integer(id),
                    method: method,
                    params: .object(params),
                    metadata: [:]
                ),
                hostID: "desktop-host-history",
                dispatchedAtMs: nil,
                priority: nil,
                source: nil,
                timeoutMs: nil,
                expiresAtMs: nil,
                metadata: [:]
            ),
            state: .init(
                account: .init(
                    account: nil,
                    authMethod: nil,
                    requiresOpenAIAuth: true
                ),
                config: .init(
                    config: [:],
                    origins: [:],
                    layers: []
                ),
                remoteControl: .init(
                    status: .disabled,
                    serverName: "Codex for ipad",
                    installationID: "history",
                    environmentID: nil
                )
            ),
            allowedFileSystemRoots: [],
            threadLister: store
        )
}

private func threadHistoryResult(
    _ message: CodexDesktopHostMessage
) -> [String: CodexJSONValue]? {
    guard case let .mcpResponse(_, payload, _) = message,
          case let .object(envelope) = payload,
          case let .object(result)? = envelope["result"]
    else { return nil }
    return result
}

private func threadHistoryErrorCode(
    _ message: CodexDesktopHostMessage
) -> Int64? {
    guard case let .mcpResponse(_, payload, _) = message,
          case let .object(envelope) = payload,
          case let .object(error)? = envelope["error"],
          case let .integer(code)? = error["code"]
    else { return nil }
    return code
}
