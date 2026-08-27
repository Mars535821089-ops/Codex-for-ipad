import CodexPadApplication
import CodexPadDomain
import CodexPadProtocolBridge
import Foundation
import Testing

@Test
func compactHistoryCommitAndLifecycleEventsPreserveExactWire() throws {
    let command = CodexCompactHistoryCommit(
        threadID: CodexStoredThreadID("thread-compact"),
        turnID: "turn-compact",
        itemID: "item-compact",
        replacementItems: [
            #"{"type":"message","role":"user","content":[{"type":"input_text","text":"summary"}]}"#,
        ],
        responseID: "response-compact",
        usage: nil
    )
    let encoded = try JSONDecoder().decode(
        CodexJSONValue.self,
        from: command.encodedData()
    )
    guard case let .object(fields) = encoded else {
        Issue.record("Expected compact commit object")
        return
    }
    #expect(fields["kind"] == .string("turn.compact-history.commit"))
    #expect(fields["threadId"] == .string("thread-compact"))
    #expect(fields["itemId"] == .string("item-compact"))
    #expect(fields["responseId"] == .string("response-compact"))

    let started = try CodexCoreEvent(
        data: Data(
            #"{"sequence":7,"kind":"stableCompactStarted","threadId":"thread-compact","turnId":"turn-compact","itemId":"item-compact"}"#.utf8
        )
    )
    guard case let .stableCompactStarted(event) = started else {
        Issue.record("Expected stable compact start")
        return
    }
    #expect(event.turnID == "turn-compact")
    #expect(event.itemID == "item-compact")
}

@Test
func rawHistoryCommitPreservesExactItemStringsAndWireOptionals() throws {
    let exactItem =
        "{\n  \"type\":\"message\", \"role\":\"assistant\","
        + "\"content\":[{\"type\":\"output_text\",\"text\":\"A\"}]\n}"
    let usage = CodexTokenUsageBreakdown(
        totalTokens: 18,
        inputTokens: 11,
        cachedInputTokens: 3,
        cacheWriteInputTokens: 1,
        outputTokens: 7,
        reasoningOutputTokens: 2
    )
    let omitted = CodexRawHistoryCommit(
        threadID: CodexStoredThreadID(" Thread/Raw "),
        turnID: "Turn/Raw",
        expectedNextOrder: 0,
        entries: [
            .init(
                order: 0,
                source: .provider,
                itemJSON: exactItem
            )
        ]
    )
    let explicitNull = CodexRawHistoryCommit(
        threadID: CodexStoredThreadID(" Thread/Raw "),
        turnID: "Turn/Raw",
        expectedNextOrder: 1,
        entries: [],
        completion: .value(
            .init(
                responseID: "response-1",
                usage: .null,
                endTurn: .null
            )
        )
    )
    let terminal = CodexRawHistoryCommit(
        threadID: CodexStoredThreadID(" Thread/Raw "),
        turnID: "Turn/Raw",
        expectedNextOrder: 1,
        entries: [],
        completion: .value(
            .init(
                responseID: "response-2",
                usage: .value(usage),
                endTurn: .value(true)
            )
        )
    )

    let omittedObject = try jsonObject(omitted.encodedData())
    let nullObject = try jsonObject(explicitNull.encodedData())
    let terminalObject = try jsonObject(terminal.encodedData())

    #expect(omittedObject["kind"] as? String == "turn.raw-history.commit")
    #expect(omittedObject["threadId"] as? String == " Thread/Raw ")
    #expect(omittedObject["turnId"] as? String == "Turn/Raw")
    #expect(omittedObject["completion"] == nil)
    let omittedEntries = try #require(omittedObject["entries"] as? [[String: Any]])
    #expect(omittedEntries[0]["itemJson"] as? String == exactItem)

    let nullCompletion = try #require(
        nullObject["completion"] as? [String: Any]
    )
    #expect(nullCompletion.keys.contains("usage"))
    #expect(nullCompletion["usage"] is NSNull)
    #expect(nullCompletion.keys.contains("endTurn"))
    #expect(nullCompletion["endTurn"] is NSNull)

    let terminalCompletion = try #require(
        terminalObject["completion"] as? [String: Any]
    )
    #expect(terminalCompletion["responseId"] as? String == "response-2")
    #expect(terminalCompletion["endTurn"] as? Bool == true)
    let encodedUsage = try #require(
        terminalCompletion["usage"] as? [String: Any]
    )
    #expect(encodedUsage["totalTokens"] as? Int == 18)
    #expect(encodedUsage["cacheWriteInputTokens"] as? Int == 1)
}

@Test
func priorInputItemsRequestAndReplyPreserveOpaqueIDsAndExactItems() throws {
    let request = CodexRawHistoryRequest.priorInputItems(
        id: .integer(77),
        params: .init(
            threadID: CodexStoredThreadID("Thread/Ω"),
            beforeTurnID: .value("Turn/Ω")
        )
    )
    #expect(
        try request.encodedData()
            == Data(
                #"{"id":77,"method":"thread/prior-input-items","params":{"beforeTurnId":"Turn/Ω","threadId":"Thread/Ω"}}"#
                    .utf8
            )
    )

    let exact =
        "{\n \"type\":\"function_call_output\","
        + "\"call_id\":\"call-1\",\"output\":\"ok\" }"
    let reply = try JSONDecoder().decode(
        CodexAppServerReply<CodexPriorInputItemsResult>.self,
        from: Data(
            #"""
            {
              "id":77,
              "result":{
                "threadId":"Thread/Ω",
                "throughTurnId":"Turn/Ω",
                "items":[
                  "{\n \"type\":\"function_call_output\",\"call_id\":\"call-1\",\"output\":\"ok\" }"
                ],
                "completeness":"complete"
              }
            }
            """#.utf8
        )
    )

    guard case .success(let response) = reply else {
        Issue.record("Expected successful prior input reply")
        return
    }
    #expect(response.id == .integer(77))
    #expect(response.result.threadID.rawValue == "Thread/Ω")
    #expect(response.result.throughTurnID == "Turn/Ω")
    #expect(response.result.items == [exact])
    #expect(response.result.completeness == .complete)
}

@Test
func rawHistoryEnvelopeRejectsNonObjectGapsOverflowAndBlankBoundary() {
    let threadID = CodexStoredThreadID("Thread/Raw")

    #expect(throws: CodexRawHistoryEnvelopeError.invalidCommit) {
        try CodexRawHistoryCommit(
            threadID: threadID,
            turnID: "Turn/Raw",
            expectedNextOrder: 0,
            entries: [
                .init(order: 0, source: .provider, itemJSON: "[]")
            ]
        ).encodedData()
    }
    #expect(throws: CodexRawHistoryEnvelopeError.invalidCommit) {
        try CodexRawHistoryCommit(
            threadID: threadID,
            turnID: "Turn/Raw",
            expectedNextOrder: 4,
            entries: [
                .init(order: 5, source: .provider, itemJSON: #"{"type":"x"}"#)
            ]
        ).encodedData()
    }
    #expect(throws: CodexRawHistoryEnvelopeError.invalidCommit) {
        try CodexRawHistoryCommit(
            threadID: threadID,
            turnID: "Turn/Raw",
            expectedNextOrder: UInt64.max,
            entries: [
                .init(
                    order: UInt64.max,
                    source: .provider,
                    itemJSON: #"{"type":"x"}"#
                ),
                .init(order: 0, source: .localTool, itemJSON: #"{"type":"y"}"#),
            ]
        ).encodedData()
    }
    #expect(throws: CodexRawHistoryEnvelopeError.invalidCommit) {
        try CodexRawHistoryRequest.priorInputItems(
            id: .string("prior"),
            params: .init(
                threadID: threadID,
                beforeTurnID: .value(" \n ")
            )
        ).encodedData()
    }
}

@Test
func coreEnvelopeDecodesDurableStableStartAndRawCommitEvents() throws {
    let exact =
        "{\n  \"type\":\"message\", \"role\":\"assistant\","
        + "\"content\":[]\n}"
    let stable = try CodexCoreEvent(
        data: Data(
            #"""
            {
              "sequence":40,
              "kind":"stableTurnStarted",
              "threadId":"Thread/Raw",
              "turnId":"Turn/Raw",
              "userItemId":"Item/Raw",
              "params":{
                "threadId":"Thread/Raw",
                "input":[{"type":"text","text":"hello"}]
              }
            }
            """#.utf8
        )
    )
    let raw = try CodexCoreEvent(
        data: try JSONSerialization.data(
            withJSONObject: [
                "sequence": 41,
                "kind": "turnRawHistoryCommitted",
                "threadId": "Thread/Raw",
                "turnId": "Turn/Raw",
                "expectedNextOrder": 0,
                "entries": [
                    [
                        "order": 0,
                        "source": "provider",
                        "itemJson": exact,
                    ]
                ],
                "completion": [
                    "responseId": "response-raw",
                    "endTurn": true,
                ],
            ],
            options: [.sortedKeys]
        )
    )

    guard case .stableTurnStarted(let stableEvent) = stable else {
        Issue.record("Expected stableTurnStarted")
        return
    }
    #expect(stableEvent.sequence == 40)
    #expect(stableEvent.threadID.rawValue == "Thread/Raw")
    #expect(stableEvent.turnID == "Turn/Raw")
    #expect(stableEvent.userItemID == "Item/Raw")

    guard case .rawHistoryCommitted(let rawEvent) = raw else {
        Issue.record("Expected rawHistoryCommitted")
        return
    }
    #expect(rawEvent.sequence == 41)
    #expect(rawEvent.entries.map(\.itemJSON) == [exact])
    #expect(rawEvent.completion?.responseID == "response-raw")
    #expect(rawEvent.completion?.endTurn == .value(true))
}

@MainActor
private final class RawHistoryTestTransport: CodexCoreTransport {
    var submittedRaw: [CodexRawHistoryCommit] = []
    var requestedRaw: [CodexRawHistoryRequest] = []
    var queuedReplies: [Data] = []
    var queuedEvents: [CodexCoreEvent] = []

    func submit(_ command: CodexCoreCommand) throws {}

    func submit(_ command: CodexRawHistoryCommit) throws {
        submittedRaw.append(command)
    }

    func request(_ request: CodexAppServerThreadRequest) throws -> Data {
        Data()
    }

    func request(_ request: CodexRawHistoryRequest) throws -> Data {
        requestedRaw.append(request)
        return queuedReplies.removeFirst()
    }

    func nextEvent() throws -> CodexCoreEvent? {
        guard !queuedEvents.isEmpty else {
            return nil
        }
        return queuedEvents.removeFirst()
    }
}

@MainActor
@Test
func sessionStoreQueriesFrozenPriorAndVerifiesCommittedEvent() throws {
    let threadID = CodexStoredThreadID("Thread/Raw")
    let priorID = CodexAppServerRequestID.string("prior-1")
    let prior = CodexPriorInputItemsResult(
        threadID: threadID,
        throughTurnID: "Turn/Previous",
        items: [#"{"type":"message","role":"assistant","content":[]}"#],
        completeness: .complete
    )
    let committedCompletion = CodexRawHistoryCompletion(
        responseID: "response-current",
        endTurn: .value(true)
    )
    let commit = CodexRawHistoryCommit(
        threadID: threadID,
        turnID: "Turn/Current",
        expectedNextOrder: 0,
        entries: [
            .init(
                order: 0,
                source: .provider,
                itemJSON:
                    #"{"type":"message","role":"assistant","content":[]}"#
            )
        ],
        completion: .value(committedCompletion)
    )
    let committed = CodexRawHistoryCommittedEvent(
        sequence: 52,
        threadID: threadID,
        turnID: commit.turnID,
        expectedNextOrder: commit.expectedNextOrder,
        entries: commit.entries,
        completion: committedCompletion
    )
    let transport = RawHistoryTestTransport()
    transport.queuedReplies = [
        try JSONEncoder().encode(
            CodexAppServerReply<CodexPriorInputItemsResult>.success(
                .init(id: priorID, result: prior)
            )
        )
    ]
    transport.queuedEvents = [
        .stableTurnStarted(
            .init(
                sequence: 51,
                threadID: threadID,
                turnID: "Turn/Current",
                userItemID: "Item/Current",
                params: .object([
                    "threadId": .string(threadID.rawValue),
                    "input": .array([]),
                ])
            )
        ),
        .rawHistoryCommitted(committed),
    ]
    let store = CodexSessionStore(transport: transport)

    let result = try store.priorInputItems(
        id: priorID,
        params: .init(
            threadID: threadID,
            beforeTurnID: .value("Turn/Current")
        )
    )
    let event = try store.commitRawHistory(commit)

    #expect(result == prior)
    #expect(event == committed)
    #expect(store.priorInputItemsResult == prior)
    #expect(store.lastRawHistoryCommitEvent == committed)
    #expect(transport.submittedRaw == [commit])
    #expect(transport.queuedEvents.isEmpty)
}

@MainActor
@Test
func sessionStoreRejectsRawCommitEventFromAnotherTurn() throws {
    let threadID = CodexStoredThreadID("Thread/Raw")
    let commit = CodexRawHistoryCommit(
        threadID: threadID,
        turnID: "Turn/Expected",
        expectedNextOrder: 0,
        entries: [
            .init(
                order: 0,
                source: .provider,
                itemJSON: #"{"type":"message","role":"assistant","content":[]}"#
            )
        ]
    )
    let transport = RawHistoryTestTransport()
    transport.queuedEvents = [
        .rawHistoryCommitted(
            .init(
                sequence: 1,
                threadID: threadID,
                turnID: "Turn/Other",
                expectedNextOrder: 0,
                entries: commit.entries,
                completion: nil
            )
        )
    ]
    let store = CodexSessionStore(transport: transport)

    #expect(throws: CodexSessionStoreError.invalidReply) {
        try store.commitRawHistory(commit)
    }
    #expect(store.lastRawHistoryCommitEvent == nil)
}

private func jsonObject(_ data: Data) throws -> [String: Any] {
    try #require(
        JSONSerialization.jsonObject(with: data) as? [String: Any]
    )
}
