import CodexPadDomain
import Foundation
import Testing
@testable import CodexPadProtocolBridge

private let storedThreadJSON = #"""
{
  "id":"019fab26-5c01-7562-97f1-0999adf15538",
  "sessionId":"019fab26-5c01-7562-97f1-0999adf15538",
  "forkedFromId":null,
  "parentThreadId":null,
  "preview":"Inspect the protocol",
  "ephemeral":false,
  "modelProvider":"openai",
  "createdAt":100,
  "updatedAt":120,
  "recencyAt":121,
  "status":{"type":"active","activeFlags":["waitingOnApproval"]},
  "path":"/rollouts/thread.jsonl",
  "cwd":"/workspace",
  "cliVersion":"1.2.3",
  "source":"cli",
  "threadSource":"app",
  "agentNickname":null,
  "agentRole":null,
  "gitInfo":{"sha":"abc123","branch":"main","originUrl":null},
  "name":"Protocol audit",
  "turns":[]
}
"""#

@Test
func threadQueueRequestsAndResponsesMatchLatestStableWireContract() throws {
    let threadID = CodexStoredThreadID(
        rawValue: "019fab26-5c01-7562-97f1-0999adf15538"
    )
    let input: [CodexStoredUserInput] = [
        .text(text: "Queue this", textElements: [])
    ]
    let requests: [(CodexAppServerThreadRequest, Data)] = [
        (
            .queueAdd(
                id: .integer(81),
                params: .init(
                    threadID: threadID,
                    input: input,
                    clientUserMessageID: "client-queue-1"
                )
            ),
            Data(#"{"id":81,"method":"thread/queue/add","params":{"clientUserMessageId":"client-queue-1","input":[{"text":"Queue this","text_elements":[],"type":"text"}],"threadId":"019fab26-5c01-7562-97f1-0999adf15538"}}"#.utf8)
        ),
        (
            .queueList(
                id: .integer(82),
                params: .init(
                    threadID: threadID,
                    cursor: .null,
                    limit: .value(20)
                )
            ),
            Data(#"{"id":82,"method":"thread/queue/list","params":{"cursor":null,"limit":20,"threadId":"019fab26-5c01-7562-97f1-0999adf15538"}}"#.utf8)
        ),
        (
            .queueUpdate(
                id: .integer(83),
                params: .init(
                    threadID: threadID,
                    queuedSubmissionID: "019fab26-5c01-7562-97f1-0999adf15539",
                    input: input
                )
            ),
            Data(#"{"id":83,"method":"thread/queue/update","params":{"input":[{"text":"Queue this","text_elements":[],"type":"text"}],"queuedSubmissionId":"019fab26-5c01-7562-97f1-0999adf15539","threadId":"019fab26-5c01-7562-97f1-0999adf15538"}}"#.utf8)
        ),
        (
            .queueDelete(
                id: .integer(84),
                params: .init(
                    threadID: threadID,
                    queuedSubmissionID: "019fab26-5c01-7562-97f1-0999adf15539"
                )
            ),
            Data(#"{"id":84,"method":"thread/queue/delete","params":{"queuedSubmissionId":"019fab26-5c01-7562-97f1-0999adf15539","threadId":"019fab26-5c01-7562-97f1-0999adf15538"}}"#.utf8)
        ),
        (
            .queueReorder(
                id: .integer(85),
                params: .init(
                    threadID: threadID,
                    queuedSubmissionIDs: [
                        "019fab26-5c01-7562-97f1-0999adf15540",
                        "019fab26-5c01-7562-97f1-0999adf15539",
                    ]
                )
            ),
            Data(#"{"id":85,"method":"thread/queue/reorder","params":{"queuedSubmissionIds":["019fab26-5c01-7562-97f1-0999adf15540","019fab26-5c01-7562-97f1-0999adf15539"],"threadId":"019fab26-5c01-7562-97f1-0999adf15538"}}"#.utf8)
        ),
        (
            .queueStart(
                id: .integer(86),
                params: .init(
                    threadID: threadID,
                    queuedSubmissionID: .omitted
                )
            ),
            Data(#"{"id":86,"method":"thread/queue/start","params":{"threadId":"019fab26-5c01-7562-97f1-0999adf15538"}}"#.utf8)
        ),
    ]

    for (request, expected) in requests {
        #expect(try request.encodedData() == expected)
    }

    let responseData = Data(
        #"{"id":82,"result":{"data":[{"id":"019fab26-5c01-7562-97f1-0999adf15539","input":[{"type":"text","text":"Queue this","text_elements":[]}],"clientUserMessageId":"client-queue-1"}],"nextCursor":null}}"#.utf8
    )
    let reply = try JSONDecoder().decode(
        CodexAppServerReply<CodexThreadQueueListResponse>.self,
        from: responseData
    )
    guard case let .success(response) = reply else {
        Issue.record("queue list response did not decode")
        return
    }
    #expect(response.result.data.count == 1)
    #expect(response.result.data[0].clientUserMessageID == "client-queue-1")
    #expect(response.result.nextCursor == nil)
}

@Test
func threadCompactStartRequestMatchesReleasedStableWireContract() throws {
    let request = CodexAppServerThreadRequest.compactStart(
        id: .string("compact-1"),
        threadID: CodexStoredThreadID(
            rawValue: "019fab26-5c01-7562-97f1-0999adf15538"
        )
    )

    #expect(
        try request.encodedData()
            == Data(
                #"{"id":"compact-1","method":"thread/compact/start","params":{"threadId":"019fab26-5c01-7562-97f1-0999adf15538"}}"#.utf8
            )
    )
}

@Test
func threadInjectItemsRequestMatchesReleasedStableWireContract() throws {
    let request = CodexAppServerThreadRequest.injectItems(
        id: .string("inject-1"),
        threadID: CodexStoredThreadID(
            rawValue: "019fab26-5c01-7562-97f1-0999adf15538"
        ),
        items: [
            .object([
                "type": .string("message"),
                "role": .string("user"),
                "content": .array([
                    .object([
                        "type": .string("input_text"),
                        "text": .string("side conversation context"),
                    ])
                ]),
            ])
        ]
    )

    #expect(
        try request.encodedData()
            == Data(
                #"{"id":"inject-1","method":"thread/inject_items","params":{"items":[{"content":[{"text":"side conversation context","type":"input_text"}],"role":"user","type":"message"}],"threadId":"019fab26-5c01-7562-97f1-0999adf15538"}}"#.utf8
            )
    )
}

@Test
func threadRollbackRequestMatchesReleasedStableWireContract() throws {
    let request = CodexAppServerThreadRequest.rollback(
        id: .string("rollback-1"),
        threadID: CodexStoredThreadID(
            rawValue: "019fab26-5c01-7562-97f1-0999adf15538"
        ),
        numTurns: 2
    )

    #expect(
        try request.encodedData()
            == Data(
                #"{"id":"rollback-1","method":"thread/rollback","params":{"numTurns":2,"threadId":"019fab26-5c01-7562-97f1-0999adf15538"}}"#.utf8
            )
    )
}

@Test
func threadRevertRequestMatchesLatestStableWireContract() throws {
    let request = CodexAppServerThreadRequest.revert(
        id: .string("revert-1"),
        threadID: CodexStoredThreadID(
            rawValue: "019fab26-5c01-7562-97f1-0999adf15538"
        ),
        beforeTurnID: "019fab26-5c01-7562-97f1-0999adf15539"
    )

    #expect(
        try request.encodedData()
            == Data(
                #"{"id":"revert-1","method":"thread/revert","params":{"beforeTurnId":"019fab26-5c01-7562-97f1-0999adf15539","threadId":"019fab26-5c01-7562-97f1-0999adf15538"}}"#.utf8
            )
    )
}

@Test
func threadForkRequestMatchesReleasedStableWireContract() throws {
    let request = CodexAppServerThreadRequest.fork(
        id: .string("fork-1"),
        params: CodexThreadForkParams(
            threadID: CodexStoredThreadID(
                rawValue: "019fab26-5c01-7562-97f1-0999adf15538"
            ),
            lastTurnID: .value("turn-1"),
            model: .value("gpt-5.5"),
            modelProvider: .value("openai"),
            serviceTier: .null,
            cwd: .value("/workspace/fork"),
            approvalPolicy: .value(.never),
            approvalsReviewer: .value(.user),
            sandbox: .value(.dangerFullAccess),
            ephemeral: true,
            threadSource: .value("automation")
        )
    )

    #expect(
        try request.encodedData()
            == Data(
                #"{"id":"fork-1","method":"thread/fork","params":{"approvalPolicy":"never","approvalsReviewer":"user","cwd":"/workspace/fork","ephemeral":true,"lastTurnId":"turn-1","model":"gpt-5.5","modelProvider":"openai","sandbox":"danger-full-access","serviceTier":null,"threadId":"019fab26-5c01-7562-97f1-0999adf15538","threadSource":"automation"}}"#.utf8
            )
    )
}

@Test
func threadStartRequestMatchesReleasedStableWireContract() throws {
    let request = CodexAppServerThreadRequest.start(
        id: .string("start-1"),
        params: CodexThreadStartParams(
            model: .value("gpt-5.6-sol"),
            modelProvider: .value("openai"),
            serviceTier: .null,
            cwd: .value("/workspace/project"),
            approvalPolicy: .value(.onRequest),
            approvalsReviewer: .value(.user),
            sandbox: .value(.workspaceWrite),
            config: .value(["model_reasoning_effort": .string("high")]),
            personality: .value(.pragmatic),
            ephemeral: .value(true),
            sessionStartSource: .value("startup"),
            threadSource: .value("app")
        )
    )

    #expect(
        try request.encodedData()
            == Data(
                #"{"id":"start-1","method":"thread/start","params":{"approvalPolicy":"on-request","approvalsReviewer":"user","config":{"model_reasoning_effort":"high"},"cwd":"/workspace/project","ephemeral":true,"model":"gpt-5.6-sol","modelProvider":"openai","personality":"pragmatic","sandbox":"workspace-write","serviceTier":null,"sessionStartSource":"startup","threadSource":"app"}}"#.utf8
            )
    )
}

@Test
func threadStartProjectsReleasedDesktopExtensionsToPortableCoreContract() throws {
    let request = CodexAppServerThreadRequest.start(
        id: .string("start-desktop-extensions"),
        params: CodexThreadStartParams(
            model: .value("gpt-5.6-sol"),
            cwd: .value("/workspace/project"),
            config: .value([
                "ambient-suggestions-enabled": .bool(true),
                "features": .object(["thread_tools": .bool(true)]),
                "model_reasoning_effort": .string("high"),
            ]),
            serviceName: .value("desktop"),
            baseInstructions: .value("released desktop base instructions"),
            developerInstructions: .value("released desktop developer instructions"),
            allowProviderModelFallback: .value(true),
            dynamicTools: .value([]),
            environments: .value([
                .object(["environmentId": .string("local")])
            ]),
            experimentalRawEvents: .value(false),
            historyMode: .value(.paginated),
            mockExperimentalField: .null,
            mode: .value("default"),
            multiAgentMode: .value(.explicitRequestOnly),
            permissions: .value(":workspace"),
            runtimeWorkspaceRoots: .value(["/workspace"]),
            selectedCapabilityRoots: .value([
                .object(["id": .string("github@openai")])
            ]),
            threadStartKind: .value("default")
        )
    )

    #expect(
        try request.encodedData()
            == Data(
                #"{"id":"start-desktop-extensions","method":"thread/start","params":{"allowProviderModelFallback":true,"baseInstructions":"released desktop base instructions","config":{"ambient-suggestions-enabled":true,"features":{"thread_tools":true},"model_reasoning_effort":"high"},"cwd":"/workspace/project","developerInstructions":"released desktop developer instructions","dynamicTools":[],"environments":[{"environmentId":"local"}],"experimentalRawEvents":false,"historyMode":"paginated","mockExperimentalField":null,"mode":"default","model":"gpt-5.6-sol","multiAgentMode":"explicitRequestOnly","permissions":":workspace","runtimeWorkspaceRoots":["/workspace"],"selectedCapabilityRoots":[{"id":"github@openai"}],"serviceName":"desktop","threadStartKind":"default"}}"#.utf8
            )
    )
}

@Test
func threadStartTreatsTopLevelModelAsAuthoritativeOverStaleConfigModel() throws {
    let request = CodexAppServerThreadRequest.start(
        id: .string("start-model-conflict"),
        params: CodexThreadStartParams(
            model: .value("gpt-5.6-sol"),
            cwd: .value("/workspace/project"),
            config: .value([
                "model": .string("stale-config-model"),
                "model_reasoning_effort": .string("high"),
            ])
        )
    )

    #expect(
        try request.encodedData()
            == Data(
                #"{"id":"start-model-conflict","method":"thread/start","params":{"config":{"model_reasoning_effort":"high"},"cwd":"/workspace/project","model":"gpt-5.6-sol"}}"#.utf8
            )
    )
}

private let storedThreadWithTurnsJSON = #"""
{
  "id":"019fab26-5c01-7562-97f1-0999adf15538",
  "sessionId":"019fab26-5c01-7562-97f1-0999adf15538",
  "forkedFromId":null,
  "parentThreadId":null,
  "preview":"Inspect the protocol",
  "ephemeral":false,
  "modelProvider":"openai",
  "createdAt":100,
  "updatedAt":124,
  "recencyAt":124,
  "status":{"type":"idle"},
  "path":"/rollouts/thread.jsonl",
  "cwd":"/workspace",
  "cliVersion":"1.2.3",
  "source":"cli",
  "threadSource":"app",
  "agentNickname":null,
  "agentRole":null,
  "gitInfo":{"sha":"abc123","branch":"main","originUrl":null},
  "name":"Protocol audit",
  "turns":[{
    "id":"turn-1",
    "items":[{
      "type":"userMessage",
      "id":"item-1",
      "clientId":"client-1",
      "content":[{"type":"text","text":"Inspect","text_elements":[]}]
    }],
    "itemsView":"full",
    "status":"failed",
    "error":{
      "message":"Provider stopped",
      "codexErrorInfo":"serverOverloaded",
      "additionalDetails":"retry later"
    },
    "startedAt":122,
    "completedAt":124,
    "durationMs":2000
  }]
}
"""#

@Test
func threadListRequestEncodesEveryStableFilterExactly() throws {
    let request = CodexAppServerThreadRequest.list(
        id: .string("list-1"),
        params: CodexThreadListParams(
            cursor: .value("cursor-1"),
            limit: .value(25),
            sortKey: .value(.recencyAt),
            sortDirection: .value(.descending),
            modelProviders: .value([]),
            sourceKinds: .value([.cli, .appServer]),
            archived: .value(false),
            cwd: .value(.many(["/workspace", "/workspace-two"])),
            useStateDbOnly: true,
            searchTerm: .value("protocol")
        )
    )

    #expect(
        try request.encodedData() == Data(
            #"{"id":"list-1","method":"thread/list","params":{"archived":false,"cursor":"cursor-1","cwd":["/workspace","/workspace-two"],"limit":25,"modelProviders":[],"searchTerm":"protocol","sortDirection":"desc","sortKey":"recency_at","sourceKinds":["cli","appServer"],"useStateDbOnly":true}}"#.utf8
        )
    )
}

@Test
func threadListAndSearchLimitsUseUInt32() {
    let list = CodexThreadListParams(limit: .value(100))
    let search = CodexThreadSearchParams(
        limit: .value(100),
        searchTerm: "protocol"
    )
    let expected: CodexWireOptional<UInt32> = .value(100)

    #expect(list.limit == expected)
    #expect(search.limit == expected)
}

@Test
func threadSectionMutationRequestsMatchReleasedWireContracts() throws {
    let create = CodexAppServerThreadRequest.sectionCreate(
        id: .integer(1),
        params: CodexThreadSectionCreateParams(name: "Pinned work")
    )
    let update = CodexAppServerThreadRequest.sectionUpdate(
        id: .integer(2),
        params: CodexThreadSectionUpdateParams(
            sectionID: "section-1",
            name: "Today"
        )
    )
    let delete = CodexAppServerThreadRequest.sectionDelete(
        id: .integer(3),
        params: CodexThreadSectionDeleteParams(sectionID: "section-1")
    )
    let move = CodexAppServerThreadRequest.sectionMove(
        id: .integer(4),
        params: CodexThreadSectionMoveParams(
            threadID: CodexStoredThreadID("thread-1"),
            sectionID: .value("section-1"),
            beforeThreadID: .null
        )
    )
    let remove = CodexAppServerThreadRequest.sectionMove(
        id: .integer(5),
        params: CodexThreadSectionMoveParams(
            threadID: CodexStoredThreadID("thread-1"),
            sectionID: .null
        )
    )

    #expect(
        try create.encodedData() == Data(
            #"{"id":1,"method":"threadSection/create","params":{"name":"Pinned work"}}"#.utf8
        )
    )
    #expect(
        try update.encodedData() == Data(
            #"{"id":2,"method":"threadSection/update","params":{"name":"Today","sectionId":"section-1"}}"#.utf8
        )
    )
    #expect(
        try delete.encodedData() == Data(
            #"{"id":3,"method":"threadSection/delete","params":{"sectionId":"section-1"}}"#.utf8
        )
    )
    #expect(
        try move.encodedData() == Data(
            #"{"id":4,"method":"thread/section/move","params":{"beforeThreadId":null,"sectionId":"section-1","threadId":"thread-1"}}"#.utf8
        )
    )
    #expect(
        try remove.encodedData() == Data(
            #"{"id":5,"method":"thread/section/move","params":{"sectionId":null,"threadId":"thread-1"}}"#.utf8
        )
    )
}

@Test
func threadListRequestPreservesOmittedNullAndEmptyProviderFilters() throws {
    let omitted = CodexAppServerThreadRequest.list(
        id: .integer(1),
        params: CodexThreadListParams()
    )
    let null = CodexAppServerThreadRequest.list(
        id: .integer(2),
        params: CodexThreadListParams(modelProviders: .null)
    )
    let empty = CodexAppServerThreadRequest.list(
        id: .integer(3),
        params: CodexThreadListParams(modelProviders: .value([]))
    )

    #expect(
        try omitted.encodedData()
            == Data(#"{"id":1,"method":"thread/list","params":{}}"#.utf8)
    )
    #expect(
        try null.encodedData()
            == Data(
                #"{"id":2,"method":"thread/list","params":{"modelProviders":null}}"#.utf8
            )
    )
    #expect(
        try empty.encodedData()
            == Data(
                #"{"id":3,"method":"thread/list","params":{"modelProviders":[]}}"#.utf8
            )
    )
}

@Test
func threadListRequestEncodesSingleCWDAsAString() throws {
    let request = CodexAppServerThreadRequest.list(
        id: .integer(4),
        params: CodexThreadListParams(cwd: .value(.one("/workspace")))
    )

    #expect(
        try request.encodedData()
            == Data(
                #"{"id":4,"method":"thread/list","params":{"cwd":"/workspace"}}"#.utf8
            )
    )
}

@Test
func threadListInboundParamsDecodeEveryReleasedRendererFieldExactly() throws {
    let decoded = try CodexAppServerThreadListParamsDecoder.decode(
        .object([
            "cursor": .string("cursor-1"),
            "limit": .integer(25),
            "sortKey": .string("recency_at"),
            "sortDirection": .string("desc"),
            "modelProviders": .array([
                .string("openai"),
                .string("provider-next"),
            ]),
            "sourceKinds": .array([
                .string("cli"),
                .string("vscode"),
                .string("exec"),
                .string("appServer"),
                .string("subAgent"),
                .string("subAgentReview"),
                .string("subAgentCompact"),
                .string("subAgentThreadSpawn"),
                .string("subAgentOther"),
                .string("unknown"),
            ]),
            "archived": .bool(false),
            "cwd": .array([
                .string("/workspace"),
                .string("/workspace-two"),
            ]),
            "useStateDbOnly": .bool(true),
            "searchTerm": .string("protocol"),
            "parentThreadId": .null,
            "ancestorThreadId": .string("ancestor"),
            "futureField": .object(["retainedByServer": .bool(true)]),
        ])
    )

    #expect(
        decoded
            == CodexThreadListParams(
                cursor: .value("cursor-1"),
                limit: .value(25),
                sortKey: .value(.recencyAt),
                sortDirection: .value(.descending),
                modelProviders: .value([
                    "openai",
                    "provider-next",
                ]),
                sourceKinds: .value([
                    .cli,
                    .vscode,
                    .exec,
                    .appServer,
                    .subAgent,
                    .subAgentReview,
                    .subAgentCompact,
                    .subAgentThreadSpawn,
                    .subAgentOther,
                    .unknown,
                ]),
                archived: .value(false),
                cwd: .value(
                    .many([
                        "/workspace",
                        "/workspace-two",
                    ])
                ),
                useStateDbOnly: true,
                searchTerm: .value("protocol"),
                parentThreadID: .null,
                ancestorThreadID: .value("ancestor")
            )
    )
}

@Test
func threadListInboundParamsPreserveOmittedNullEmptyAndSingleCWD() throws {
    let omitted = try CodexAppServerThreadListParamsDecoder.decode(
        .object([:])
    )
    let explicitNulls = try CodexAppServerThreadListParamsDecoder.decode(
        .object([
            "cursor": .null,
            "limit": .null,
            "sortKey": .null,
            "sortDirection": .null,
            "modelProviders": .null,
            "sourceKinds": .null,
            "archived": .null,
            "cwd": .null,
            "searchTerm": .null,
            "parentThreadId": .null,
            "ancestorThreadId": .null,
        ])
    )
    let emptyArrays = try CodexAppServerThreadListParamsDecoder.decode(
        .object([
            "modelProviders": .array([]),
            "sourceKinds": .array([]),
            "cwd": .array([]),
            "useStateDbOnly": .bool(false),
        ])
    )
    let singleCWD = try CodexAppServerThreadListParamsDecoder.decode(
        .object(["cwd": .string("/workspace")])
    )

    #expect(omitted == CodexThreadListParams())
    #expect(
        explicitNulls
            == CodexThreadListParams(
                cursor: .null,
                limit: .null,
                sortKey: .null,
                sortDirection: .null,
                modelProviders: .null,
                sourceKinds: .null,
                archived: .null,
                cwd: .null,
                searchTerm: .null,
                parentThreadID: .null,
                ancestorThreadID: .null
            )
    )
    #expect(
        emptyArrays
            == CodexThreadListParams(
                modelProviders: .value([]),
                sourceKinds: .value([]),
                cwd: .value(.many([])),
                useStateDbOnly: false
            )
    )
    #expect(
        singleCWD
            == CodexThreadListParams(cwd: .value(.one("/workspace")))
    )
}

@Test
func threadListInboundParamsRejectNonObjectParamsAndInvalidFieldShapes() {
    let invalidParams: [
        (
            params: CodexJSONValue?,
            expected: CodexAppServerThreadEnvelopeError
        )
    ] = [
        (nil, .invalidThreadListParams),
        (.null, .invalidThreadListParams),
        (.array([]), .invalidThreadListParams),
        (
            .object(["cursor": .bool(true)]),
            .invalidThreadListParam("cursor")
        ),
        (
            .object(["limit": .integer(-1)]),
            .invalidThreadListParam("limit")
        ),
        (
            .object(["limit": .integer(4_294_967_296)]),
            .invalidThreadListParam("limit")
        ),
        (
            .object(["limit": .number(25.0)]),
            .invalidThreadListParam("limit")
        ),
        (
            .object(["sortKey": .string("future")]),
            .invalidThreadListParam("sortKey")
        ),
        (
            .object(["sortDirection": .string("newest")]),
            .invalidThreadListParam("sortDirection")
        ),
        (
            .object([
                "modelProviders": .array([
                    .string("openai"),
                    .integer(1),
                ])
            ]),
            .invalidThreadListParam("modelProviders")
        ),
        (
            .object([
                "sourceKinds": .array([
                    .string("cli"),
                    .string("future"),
                ])
            ]),
            .invalidThreadListParam("sourceKinds")
        ),
        (
            .object(["archived": .string("false")]),
            .invalidThreadListParam("archived")
        ),
        (
            .object([
                "cwd": .array([
                    .string("/workspace"),
                    .bool(false),
                ])
            ]),
            .invalidThreadListParam("cwd")
        ),
        (
            .object(["useStateDbOnly": .null]),
            .invalidThreadListParam("useStateDbOnly")
        ),
        (
            .object(["searchTerm": .integer(1)]),
            .invalidThreadListParam("searchTerm")
        ),
        (
            .object(["parentThreadId": .bool(true)]),
            .invalidThreadListParam("parentThreadId")
        ),
        (
            .object(["ancestorThreadId": .array([])]),
            .invalidThreadListParam("ancestorThreadId")
        ),
    ]

    for invalid in invalidParams {
        #expect(
            throws: invalid.expected,
            performing: {
                try CodexAppServerThreadListParamsDecoder.decode(
                    invalid.params
                )
            }
        )
    }
}

@Test
func threadListInboundParamsRejectBothLineageValues() {
    #expect(
        throws:
            CodexAppServerThreadEnvelopeError
                .mutuallyExclusiveThreadLineageFilters,
        performing: {
            try CodexAppServerThreadListParamsDecoder.decode(
                .object([
                    "parentThreadId": .string("parent"),
                    "ancestorThreadId": .string("ancestor"),
                ])
            )
        }
    )
}

@Test
func threadListResponseDecodesFullThreadAndBothCursors() throws {
    let data = Data(
        """
        {
          "id":7,
          "result":{
            "data":[\(storedThreadJSON)],
            "nextCursor":"next-opaque",
            "backwardsCursor":"back-opaque"
          }
        }
        """.utf8
    )

    let response = try JSONDecoder().decode(
        CodexAppServerResponse<CodexThreadPage>.self,
        from: data
    )
    let thread = try #require(response.result.data.first)

    #expect(response.id == .integer(7))
    #expect(response.result.nextCursor == "next-opaque")
    #expect(response.result.backwardsCursor == "back-opaque")
    #expect(thread.id.rawValue == "019fab26-5c01-7562-97f1-0999adf15538")
    #expect(thread.sessionID == "019fab26-5c01-7562-97f1-0999adf15538")
    #expect(thread.preview == "Inspect the protocol")
    #expect(thread.status == .active([.waitingOnApproval]))
    #expect(thread.gitInfo?.branch == "main")
    #expect(thread.turns.isEmpty)
}

@Test
func threadReadRequestIncludesTurnsOnlyWhenRequested() throws {
    let included = CodexAppServerThreadRequest.read(
        id: .string("read-1"),
        params: CodexThreadReadParams(
            threadID: CodexStoredThreadID("thread-1"),
            includeTurns: true
        )
    )
    let omitted = CodexAppServerThreadRequest.read(
        id: .string("read-2"),
        params: CodexThreadReadParams(
            threadID: CodexStoredThreadID("thread-1")
        )
    )

    #expect(
        try included.encodedData()
            == Data(
                #"{"id":"read-1","method":"thread/read","params":{"includeTurns":true,"threadId":"thread-1"}}"#.utf8
            )
    )
    #expect(
        try omitted.encodedData()
            == Data(
                #"{"id":"read-2","method":"thread/read","params":{"threadId":"thread-1"}}"#.utf8
            )
    )
}

@Test
func threadReadIncludeTurnsResponseDecodesTypedTurns() throws {
    let data = Data(
        """
        {"id":"read-1","result":{"thread":\(storedThreadWithTurnsJSON)}}
        """.utf8
    )

    let response = try JSONDecoder().decode(
        CodexAppServerResponse<CodexThreadReadResult>.self,
        from: data
    )

    #expect(response.id == .string("read-1"))
    let turn = try #require(response.result.thread.turns.first)

    #expect(response.result.thread.name == "Protocol audit")
    #expect(response.result.thread.cwd == "/workspace")
    #expect(turn.id == "turn-1")
    #expect(turn.items.count == 1)
    #expect(turn.itemsView == .full)
    #expect(turn.status == .failed)
    #expect(turn.error?.message == "Provider stopped")
    #expect(turn.error?.codexErrorInfo == .serverOverloaded)
    #expect(turn.error?.additionalDetails == "retry later")
    #expect(turn.startedAt == 122)
    #expect(turn.completedAt == 124)
    #expect(turn.durationMs == 2_000)
}

@Test
func threadResumeRequestPreservesRawIDAndEveryStableOverrideState() throws {
    let rawThreadID = " 任务/thread-Ω/../原样 "
    let omitted = CodexAppServerThreadRequest.resume(
        id: .string("resume-omitted"),
        params: CodexThreadResumeParams(
            threadID: CodexStoredThreadID(rawThreadID)
        )
    )
    let null = CodexAppServerThreadRequest.resume(
        id: .string("resume-null"),
        params: CodexThreadResumeParams(
            threadID: CodexStoredThreadID(rawThreadID),
            model: .null,
            modelProvider: .null,
            serviceTier: .null,
            cwd: .null,
            approvalPolicy: .null,
            approvalsReviewer: .null,
            sandbox: .null,
            config: .null,
            baseInstructions: .null,
            developerInstructions: .null,
            personality: .null
        )
    )
    let values = CodexAppServerThreadRequest.resume(
        id: .string("resume-values"),
        params: CodexThreadResumeParams(
            threadID: CodexStoredThreadID(rawThreadID),
            model: .value("model-next"),
            modelProvider: .value("provider-next"),
            serviceTier: .value("priority-next"),
            cwd: .value("/workspace/项目"),
            approvalPolicy: .value(
                .granular(
                    .init(
                        sandboxApproval: true,
                        rules: false,
                        skillApproval: true,
                        requestPermissions: false,
                        mcpElicitations: true
                    )
                )
            ),
            approvalsReviewer: .value(.autoReview),
            sandbox: .value(.workspaceWrite),
            config: .value([
                "nested": .object([
                    "array": .array([.integer(1), .null]),
                    "enabled": .bool(true),
                ]),
            ]),
            baseInstructions: .value("base"),
            developerInstructions: .value("developer"),
            personality: .value(.pragmatic)
        )
    )

    #expect(
        try omitted.encodedData()
            == Data(
                #"{"id":"resume-omitted","method":"thread/resume","params":{"threadId":" 任务/thread-Ω/../原样 "}}"#.utf8
            )
    )
    #expect(
        try null.encodedData()
            == Data(
                #"{"id":"resume-null","method":"thread/resume","params":{"approvalPolicy":null,"approvalsReviewer":null,"baseInstructions":null,"config":null,"cwd":null,"developerInstructions":null,"model":null,"modelProvider":null,"personality":null,"sandbox":null,"serviceTier":null,"threadId":" 任务/thread-Ω/../原样 "}}"#.utf8
            )
    )
    #expect(
        try values.encodedData()
            == Data(
                #"{"id":"resume-values","method":"thread/resume","params":{"approvalPolicy":{"granular":{"mcp_elicitations":true,"request_permissions":false,"rules":false,"sandbox_approval":true,"skill_approval":true}},"approvalsReviewer":"auto_review","baseInstructions":"base","config":{"nested":{"array":[1,null],"enabled":true}},"cwd":"/workspace/项目","developerInstructions":"developer","model":"model-next","modelProvider":"provider-next","personality":"pragmatic","sandbox":"workspace-write","serviceTier":"priority-next","threadId":" 任务/thread-Ω/../原样 "}}"#.utf8
            )
    )
}

@Test
func threadResumeResponseDecodesTheCompleteStableContractWithoutLoss() throws {
    let data = Data(
        """
        {
          "id":"resume-1",
          "result":{
            "thread":\(storedThreadWithTurnsJSON),
            "model":"model-next",
            "modelProvider":"provider-next",
            "serviceTier":null,
            "cwd":"/workspace",
            "runtimeWorkspaceRoots":["/workspace","/shared"],
            "dynamicTools":[{
              "type":"function",
              "name":"lookup_ticket",
              "description":"Look up a ticket",
              "inputSchema":{"type":"object"}
            }],
            "selectedCapabilityRoots":[{"id":"github@openai"}],
            "approvalPolicy":{
              "granular":{
                "sandbox_approval":true,
                "rules":false,
                "skill_approval":true,
                "request_permissions":false,
                "mcp_elicitations":true
              }
            },
            "approvalsReviewer":"guardian_subagent",
            "sandbox":{
              "type":"workspaceWrite",
              "writableRoots":["/workspace","/shared"],
              "networkAccess":true,
              "excludeTmpdirEnvVar":true,
              "excludeSlashTmp":false
            },
            "reasoningEffort":"future-super-deep-v9"
          }
        }
        """.utf8
    )

    let response = try JSONDecoder().decode(
        CodexAppServerResponse<CodexThreadResumeResult>.self,
        from: data
    )

    #expect(response.id == .string("resume-1"))
    #expect(
        response.result.thread.id
            == CodexStoredThreadID(
                "019fab26-5c01-7562-97f1-0999adf15538"
            )
    )
    #expect(response.result.thread.turns.count == 1)
    #expect(response.result.model == "model-next")
    #expect(response.result.modelProvider == "provider-next")
    #expect(response.result.serviceTier == nil)
    #expect(response.result.cwd == "/workspace")
    #expect(response.result.runtimeWorkspaceRoots == ["/workspace", "/shared"])
    #expect(
        response.result.dynamicTools == [
            .object([
                "type": .string("function"),
                "name": .string("lookup_ticket"),
                "description": .string("Look up a ticket"),
                "inputSchema": .object(["type": .string("object")]),
            ]),
        ]
    )
    #expect(
        response.result.selectedCapabilityRoots == [
            .object(["id": .string("github@openai")]),
        ]
    )
    #expect(response.result.instructionSources.isEmpty)
    #expect(
        response.result.approvalPolicy
            == .granular(
                .init(
                    sandboxApproval: true,
                    rules: false,
                    skillApproval: true,
                    requestPermissions: false,
                    mcpElicitations: true
                )
            )
    )
    #expect(response.result.approvalsReviewer == .guardianSubagent)
    #expect(
        response.result.sandbox
            == .workspaceWrite(
                writableRoots: ["/workspace", "/shared"],
                networkAccess: true,
                excludeTmpdirEnvVar: true,
                excludeSlashTmp: false
            )
    )
    #expect(response.result.reasoningEffort == "future-super-deep-v9")
}

@Test
func stableApprovalAndTaggedSandboxVariantsRemainExpressive() throws {
    let granular = try JSONDecoder().decode(
        CodexAppServerAskForApproval.self,
        from: Data(
            #"{"granular":{"sandbox_approval":true,"rules":false,"skill_approval":false,"request_permissions":false,"mcp_elicitations":true}}"#.utf8
        )
    )
    #expect(
        granular
            == .granular(
                .init(
                    sandboxApproval: true,
                    rules: false,
                    skillApproval: false,
                    requestPermissions: false,
                    mcpElicitations: true
                )
            )
    )
    #expect(
        try JSONDecoder().decode(
            CodexAppServerAskForApproval.self,
            from: Data(
                #"{"granular":{"sandbox_approval":true,"rules":false,"mcp_elicitations":true}}"#.utf8
            )
        )
            == .granular(
                .init(
                    sandboxApproval: true,
                    rules: false,
                    skillApproval: false,
                    requestPermissions: false,
                    mcpElicitations: true
                )
            )
    )

    let fixtures: [(String, CodexAppServerSandboxPolicy)] = [
        (#"{"type":"dangerFullAccess"}"#, .dangerFullAccess),
        (#"{"type":"readOnly"}"#, .readOnly(networkAccess: false)),
        (
            #"{"type":"externalSandbox"}"#,
            .externalSandbox(networkAccess: .restricted)
        ),
        (
            #"{"type":"workspaceWrite"}"#,
            .workspaceWrite(
                writableRoots: [],
                networkAccess: false,
                excludeTmpdirEnvVar: false,
                excludeSlashTmp: false
            )
        ),
        (
            #"{"type":"readOnly","networkAccess":false}"#,
            .readOnly(networkAccess: false)
        ),
        (
            #"{"type":"externalSandbox","networkAccess":"restricted"}"#,
            .externalSandbox(networkAccess: .restricted)
        ),
        (
            #"{"type":"workspaceWrite","writableRoots":[],"networkAccess":false,"excludeTmpdirEnvVar":false,"excludeSlashTmp":false}"#,
            .workspaceWrite(
                writableRoots: [],
                networkAccess: false,
                excludeTmpdirEnvVar: false,
                excludeSlashTmp: false
            )
        ),
    ]
    for (json, expected) in fixtures {
        #expect(
            try JSONDecoder().decode(
                CodexAppServerSandboxPolicy.self,
                from: Data(json.utf8)
            ) == expected
        )
    }
}

@Test
func stableResumeRejectsMissingOrNullRequiredNestedFields() {
    for json in [
        #"{"granular":{"rules":false,"skill_approval":true,"request_permissions":false,"mcp_elicitations":true}}"#,
        #"{"granular":{"sandbox_approval":true,"skill_approval":true,"request_permissions":false,"mcp_elicitations":true}}"#,
        #"{"granular":{"sandbox_approval":true,"rules":false,"skill_approval":true,"request_permissions":false}}"#,
        #"{"granular":{"sandbox_approval":null,"rules":false,"skill_approval":true,"request_permissions":false,"mcp_elicitations":true}}"#,
        #"{"granular":{"sandbox_approval":true,"rules":null,"skill_approval":true,"request_permissions":false,"mcp_elicitations":true}}"#,
        #"{"granular":{"sandbox_approval":true,"rules":false,"skill_approval":null,"request_permissions":false,"mcp_elicitations":true}}"#,
        #"{"granular":{"sandbox_approval":true,"rules":false,"skill_approval":true,"request_permissions":null,"mcp_elicitations":true}}"#,
        #"{"granular":{"sandbox_approval":true,"rules":false,"skill_approval":true,"request_permissions":false,"mcp_elicitations":null}}"#,
    ] {
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(
                CodexAppServerAskForApproval.self,
                from: Data(json.utf8)
            )
        }
    }

    for json in [
        #"{"type":"readOnly","networkAccess":null}"#,
        #"{"type":"externalSandbox","networkAccess":null}"#,
        #"{"type":"workspaceWrite","writableRoots":null,"networkAccess":false,"excludeTmpdirEnvVar":false,"excludeSlashTmp":false}"#,
        #"{"type":"workspaceWrite","writableRoots":[],"networkAccess":null,"excludeTmpdirEnvVar":false,"excludeSlashTmp":false}"#,
        #"{"type":"workspaceWrite","writableRoots":[],"networkAccess":false,"excludeTmpdirEnvVar":null,"excludeSlashTmp":false}"#,
        #"{"type":"workspaceWrite","writableRoots":[],"networkAccess":false,"excludeTmpdirEnvVar":false,"excludeSlashTmp":null}"#,
    ] {
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(
                CodexAppServerSandboxPolicy.self,
                from: Data(json.utf8)
            )
        }
    }

    let responseWithNullInstructionSources = Data(
        """
        {
          "thread":\(storedThreadJSON),
          "model":"model-next",
          "modelProvider":"provider-next",
          "cwd":"/workspace",
          "instructionSources":null,
          "approvalPolicy":"on-request",
          "approvalsReviewer":"user",
          "sandbox":{"type":"dangerFullAccess"}
        }
        """.utf8
    )
    #expect(throws: (any Error).self) {
        try JSONDecoder().decode(
            CodexThreadResumeResult.self,
            from: responseWithNullInstructionSources
        )
    }
}

@Test
func threadResumeResponseRejectsEmptyRequiredRuntimeStringsAndPaths() throws {
    let fixtures: [(String, String, String, [String])] = [
        ("", "provider-next", "/workspace", ["/workspace/AGENTS.md"]),
        ("model-next", "", "/workspace", ["/workspace/AGENTS.md"]),
        ("model-next", "provider-next", "", ["/workspace/AGENTS.md"]),
        ("model-next", "provider-next", "/workspace", [""]),
    ]
    let thread = try JSONDecoder().decode(
        CodexStoredThread.self,
        from: Data(storedThreadJSON.utf8)
    )

    for (model, modelProvider, cwd, instructionSources) in fixtures {
        let response = CodexThreadResumeResult(
            thread: thread,
            model: model,
            modelProvider: modelProvider,
            serviceTier: nil,
            cwd: cwd,
            instructionSources: instructionSources,
            approvalPolicy: .onRequest,
            approvalsReviewer: .user,
            sandbox: .dangerFullAccess,
            reasoningEffort: nil
        )
        let data = try JSONEncoder().encode(response)

        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(
                CodexThreadResumeResult.self,
                from: data
            )
        }
    }
}

@Test
func threadResumeDecodesReopenedRawProviderHistoryFromCodexCore() throws {
    // Captured from CodexCore after a SQLite reopen and thread/resume request.
    let data = Data(
        #"{"id":"resume-after-reopen","result":{"approvalPolicy":"never","approvalsReviewer":"user","cwd":"/workspace","instructionSources":[],"model":"gpt-5.6-sol","modelProvider":"openai","reasoningEffort":null,"sandbox":{"type":"dangerFullAccess"},"serviceTier":null,"thread":{"agentNickname":null,"agentRole":null,"cliVersion":"0.146.0-alpha.3.1","createdAt":100,"cwd":"/workspace","ephemeral":false,"forkedFromId":null,"gitInfo":null,"id":"ABCDEFAB-CDEF-4ABC-8DEF-ABCDEFABCDEF","isPinned":false,"modelProvider":"openai","name":"Exact raw ID","parentThreadId":null,"path":null,"preview":"","recencyAt":100,"section":null,"sessionId":"raw-history-durable","source":"appServer","status":{"type":"idle"},"threadSource":"user","turns":[{"completedAt":null,"durationMs":null,"error":null,"id":"019ffe6a-8575-7971-9cb3-3c3586f05c25","items":[{"clientId":null,"content":[{"text":"Do not synthesize this as ResponseItem","type":"text"}],"id":"019ffe6a-8575-7971-9cb3-3c4cf472eb5a","type":"userMessage"},{"id":"raw-history-019ffe6a-8575-7971-9cb3-3c3586f05c25-0","memoryCitation":null,"phase":null,"text":"A","type":"agentMessage"}],"itemsView":"summary","startedAt":null,"status":"completed"}],"updatedAt":100}}}"#.utf8
    )

    let reply = try JSONDecoder().decode(
        CodexAppServerReply<CodexThreadResumeResult>.self,
        from: data
    )
    guard case let .success(response) = reply else {
        Issue.record("CodexCore resume output must decode as a success reply")
        return
    }

    #expect(response.result.thread.turns.count == 1)
    #expect(response.result.thread.turns[0].items.count == 2)
    guard case let .agentMessage(_, text, phase, memoryCitation) =
        response.result.thread.turns[0].items[1]
    else {
        Issue.record("Reopened provider history must decode as agentMessage")
        return
    }
    #expect(text == "A")
    #expect(phase == nil)
    #expect(memoryCitation == nil)
}

@Test
func threadSearchRequestCoversThreadSearchParamsAndExactFilters() throws {
    let officialMethod = "thread/search"
    let request = CodexAppServerThreadRequest.search(
        id: .string("search-1"),
        params: CodexThreadSearchParams(
            cursor: .null,
            limit: .value(50),
            sortKey: .value(.updatedAt),
            sortDirection: .value(.ascending),
            sourceKinds: .value([.vscode]),
            archived: .value(true),
            searchTerm: "protocol bridge"
        )
    )

    #expect(
        try request.encodedData()
            == Data(
                #"{"id":"search-1","method":"thread/search","params":{"archived":true,"cursor":null,"limit":50,"searchTerm":"protocol bridge","sortDirection":"asc","sortKey":"updated_at","sourceKinds":["vscode"]}}"#.utf8
            )
    )
    let wire = try JSONDecoder().decode(
        CodexJSONValue.self,
        from: request.encodedData()
    )
    guard case let .object(fields) = wire else {
        Issue.record("thread search request must be an object")
        return
    }
    #expect(fields["method"] == .string(officialMethod))
}

@Test
func threadSearchRejectsABlankRequiredSearchTerm() {
    let request = CodexAppServerThreadRequest.search(
        id: .string("search-blank"),
        params: CodexThreadSearchParams(searchTerm: " \n ")
    )

    #expect(
        throws: CodexAppServerThreadEnvelopeError.blankSearchTerm,
        performing: { try request.encodedData() }
    )
}

@Test
func threadSearchResponseCoversThreadSearchResponseAndOpaqueCursors() throws {
    let data = Data(
        """
        {
          "id":"search-1",
          "result":{
            "data":[{"thread":\(storedThreadJSON),"snippet":"…protocol bridge…"}],
            "nextCursor":"search-next",
            "backwardsCursor":null
          }
        }
        """.utf8
    )

    let response = try JSONDecoder().decode(
        CodexAppServerResponse<CodexThreadSearchPage>.self,
        from: data
    )

    #expect(response.result.data.first?.snippet == "…protocol bridge…")
    #expect(
        response.result.data.first?.thread.id
            == CodexStoredThreadID("019fab26-5c01-7562-97f1-0999adf15538")
    )
    #expect(response.result.nextCursor == "search-next")
    #expect(response.result.backwardsCursor == nil)
}

@Test
func threadArchiveDeleteAndNameSetMatchOfficialRequestsAndEmptyResponses()
    throws
{
    let officialMethods = [
        "thread/archive",
        "thread/delete",
        "thread/name/set",
    ]
    let threadID = CodexStoredThreadID("thread-lifecycle-1")
    let requests: [(CodexAppServerThreadRequest, Data)] = [
        (
            .archive(id: .integer(41), threadID: threadID),
            Data(
                #"{"id":41,"method":"thread/archive","params":{"threadId":"thread-lifecycle-1"}}"#.utf8
            )
        ),
        (
            .delete(id: .integer(42), threadID: threadID),
            Data(
                #"{"id":42,"method":"thread/delete","params":{"threadId":"thread-lifecycle-1"}}"#.utf8
            )
        ),
        (
            .setName(
                id: .integer(43),
                threadID: threadID,
                name: "Renamed task"
            ),
            Data(
                #"{"id":43,"method":"thread/name/set","params":{"name":"Renamed task","threadId":"thread-lifecycle-1"}}"#.utf8
            )
        ),
    ]

    for (request, expected) in requests {
        #expect(try request.encodedData() == expected)
    }
    #expect(officialMethods.count == requests.count)

    for id in [41, 42, 43] {
        let response = try JSONDecoder().decode(
            CodexAppServerResponse<CodexThreadEmptyResponse>.self,
            from: Data(#"{"id":\#(id),"result":{}}"#.utf8)
        )
        #expect(response.result == CodexThreadEmptyResponse())
    }
}

@Test
func threadNameSetRejectsBlankNames() {
    #expect(
        throws: CodexAppServerThreadEnvelopeError.invalidThreadListParam(
            "name"
        ),
        performing: {
            try CodexAppServerThreadRequest.setName(
                id: .integer(43),
                threadID: CodexStoredThreadID("thread-lifecycle-1"),
                name: " \n\t "
            ).encodedData()
        }
    )
}

@Test
func threadMetadataUpdateRequiresANonEmptyGitInfoObject() throws {
    let officialMethod = "thread/metadata/update"
    let patch = try CodexThreadGitInfoPatch(
        sha: .clear,
        branch: .set("feature/thread-list"),
        originURL: .keep
    )
    let params = CodexThreadMetadataUpdateParams(
        threadID: CodexStoredThreadID("thread-1"),
        gitInfo: patch
    )
    let request = CodexAppServerThreadRequest.metadataUpdate(
        id: .integer(12),
        params: params
    )
    let requiredPatch: CodexThreadGitInfoPatch
    guard case let .value(patch) = params.gitInfo else {
        Issue.record("metadata gitInfo patch was not encoded")
        return
    }
    requiredPatch = patch

    #expect(requiredPatch == patch)
    #expect(
        try request.encodedData()
            == Data(
                #"{"id":12,"method":"thread/metadata/update","params":{"gitInfo":{"branch":"feature/thread-list","sha":null},"threadId":"thread-1"}}"#.utf8
            )
    )
    let wire = try JSONDecoder().decode(
        CodexJSONValue.self,
        from: request.encodedData()
    )
    guard case let .object(fields) = wire else {
        Issue.record("thread metadata update request must be an object")
        return
    }
    #expect(fields["method"] == .string(officialMethod))
}

@Test
func threadMetadataUpdateRejectsAnAllKeepPatch() {
    #expect(
        throws: CodexThreadDirectoryModelError.emptyGitInfoPatch,
        performing: { try CodexThreadGitInfoPatch() }
    )
}

@Test
func threadMetadataUpdateRejectsBlankReplacementValuesAfterTrimming() {
    for value in ["", " \n\t "] {
        #expect(
            throws: CodexThreadDirectoryModelError.blankGitInfoValue,
            performing: {
                try CodexThreadGitInfoPatch(branch: .set(value))
            }
        )
    }
}

@Test
func threadMetadataUpdateResponseCoversThreadMetadataUpdateResponseAsTruth() throws {
    let data = Data(
        """
        {"id":12,"result":{"thread":\(storedThreadJSON)}}
        """.utf8
    )

    let response = try JSONDecoder().decode(
        CodexAppServerResponse<CodexThreadMetadataUpdateResult>.self,
        from: data
    )

    #expect(response.result.thread.gitInfo?.sha == "abc123")
    #expect(response.result.thread.gitInfo?.originURL == nil)
}

@Test
func appServerErrorReplyDecodesStringAndIntegerIDsWithOptionalData() throws {
    let omittedData = try JSONDecoder().decode(
        CodexAppServerReply<CodexThreadPage>.self,
        from: Data(
            #"{"id":"error-1","error":{"code":-32602,"message":"Invalid params"}}"#.utf8
        )
    )
    let valueData = try JSONDecoder().decode(
        CodexAppServerReply<CodexThreadPage>.self,
        from: Data(
            #"{"id":42,"error":{"code":-32000,"message":"Search failed","data":{"field":"searchTerm"}}}"#.utf8
        )
    )

    guard case let .failure(omittedError) = omittedData else {
        Issue.record("Expected an error reply with omitted data")
        return
    }
    guard case let .failure(valueError) = valueData else {
        Issue.record("Expected an error reply with data")
        return
    }

    #expect(omittedError.id == .string("error-1"))
    #expect(omittedError.error.code == -32_602)
    #expect(omittedError.error.message == "Invalid params")
    #expect(omittedError.error.data == nil)
    #expect(valueError.id == .integer(42))
    #expect(valueError.error.code == -32_000)
    #expect(
        valueError.error.data
            == .object(["field": .string("searchTerm")])
    )
}

@Test
func appServerReplyRetainsSuccessfulResultDecoding() throws {
    let reply = try JSONDecoder().decode(
        CodexAppServerReply<CodexThreadPage>.self,
        from: Data(
            #"{"id":"list-success","result":{"data":[],"nextCursor":null,"backwardsCursor":null}}"#.utf8
        )
    )

    guard case let .success(response) = reply else {
        Issue.record("Expected a successful reply")
        return
    }

    #expect(response.id == .string("list-success"))
    #expect(response.result.data.isEmpty)
    #expect(response.result.nextCursor == nil)
    #expect(response.result.backwardsCursor == nil)
}

private let officialStoredThreadItemFixtures: [(CodexStoredThreadItemKind, String, [String])] = [
    (
        .userMessage,
        #"{"type":"userMessage","id":"user-1","clientId":"client-1","content":[{"type":"text","text":"Inspect","text_elements":[]},{"type":"image","detail":"high","url":"https://example.invalid/image.png"},{"type":"localImage","path":"/tmp/image.png"},{"type":"audio","url":"https://example.invalid/audio.mp3"},{"type":"localAudio","path":"/tmp/audio.mp3"},{"type":"skill","name":"audit","path":"/skills/audit"},{"type":"mention","name":"notes","path":"/notes"}]}"#,
        ["id", "content"]
    ),
    (
        .hookPrompt,
        #"{"type":"hookPrompt","id":"hook-1","fragments":[]}"#,
        ["id", "fragments"]
    ),
    (
        .agentMessage,
        #"{"type":"agentMessage","id":"agent-1","text":"Done","phase":"final_answer","memoryCitation":null}"#,
        ["id", "text"]
    ),
    (
        .plan,
        #"{"type":"plan","id":"plan-1","text":"Inspect then verify"}"#,
        ["id", "text"]
    ),
    (
        .reasoning,
        #"{"type":"reasoning","id":"reason-1","summary":["summary"],"content":["detail"]}"#,
        ["id"]
    ),
    (
        .commandExecution,
        #"{"type":"commandExecution","id":"command-1","command":"pwd","cwd":"/workspace","processId":null,"source":"agent","status":"completed","commandActions":[],"aggregatedOutput":"/workspace","exitCode":0,"durationMs":12}"#,
        [
            "id", "command", "cwd", "status", "commandActions",
        ]
    ),
    (
        .fileChange,
        #"{"type":"fileChange","id":"file-1","changes":[],"status":"declined"}"#,
        ["id", "changes", "status"]
    ),
    (
        .mcpToolCall,
        #"{"type":"mcpToolCall","id":"mcp-1","server":"fixture","tool":"read","status":"failed","arguments":{"path":"/tmp/a"},"appContext":null,"mcpAppResourceUri":"fixture://resource","pluginId":null,"result":null,"error":{"message":"failed"},"durationMs":23}"#,
        [
            "id", "server", "tool", "status", "arguments",
        ]
    ),
    (
        .dynamicToolCall,
        #"{"type":"dynamicToolCall","id":"dynamic-1","namespace":null,"tool":"fixture","arguments":[1,true],"status":"inProgress","contentItems":null,"success":null,"durationMs":null}"#,
        [
            "id", "tool", "arguments", "status",
        ]
    ),
    (
        .collabAgentToolCall,
        #"{"type":"collabAgentToolCall","id":"collab-1","tool":"spawnAgent","status":"completed","senderThreadId":"sender","receiverThreadIds":["receiver"],"prompt":null,"model":"MiniMax-M3","reasoningEffort":"high","agentsStates":{"receiver":{"status":"completed"}}}"#,
        [
            "id", "tool", "status", "senderThreadId", "receiverThreadIds",
            "agentsStates",
        ]
    ),
    (
        .subAgentActivity,
        #"{"type":"subAgentActivity","id":"activity-1","kind":"interacted","agentThreadId":"agent-thread","agentPath":"/root/audit"}"#,
        ["id", "kind", "agentThreadId", "agentPath"]
    ),
    (
        .webSearch,
        #"{"type":"webSearch","id":"search-1","query":"protocol","action":null,"results":[{"title":"Protocol"}]}"#,
        ["id", "query"]
    ),
    (
        .imageView,
        #"{"type":"imageView","id":"image-1","path":"/tmp/image.png"}"#,
        ["id", "path"]
    ),
    (
        .sleep,
        #"{"type":"sleep","id":"sleep-1","durationMs":1000}"#,
        ["id", "durationMs"]
    ),
    (
        .imageGeneration,
        #"{"type":"imageGeneration","id":"generated-1","status":"completed","revisedPrompt":null,"result":"data:image/png;base64,fixture","savedPath":"/tmp/generated.png"}"#,
        ["id", "status", "result"]
    ),
    (
        .enteredReviewMode,
        #"{"type":"enteredReviewMode","id":"review-in","review":"Review current changes"}"#,
        ["id", "review"]
    ),
    (
        .exitedReviewMode,
        #"{"type":"exitedReviewMode","id":"review-out","review":"Review complete"}"#,
        ["id", "review"]
    ),
    (
        .contextCompaction,
        #"{"type":"contextCompaction","id":"compact-1"}"#,
        ["id"]
    ),
]

private enum OfficialWireFixtureError: Error {
    case expectedJSONObject
}

private func officialFixtureData(_ json: String) -> Data {
    Data(json.utf8)
}

private func officialFixtureDeleting(
    _ key: String,
    from json: String
) throws -> Data {
    guard var object = try JSONSerialization.jsonObject(
        with: officialFixtureData(json)
    ) as? [String: Any] else {
        throw OfficialWireFixtureError.expectedJSONObject
    }
    object.removeValue(forKey: key)
    return try JSONSerialization.data(withJSONObject: object)
}

private func officialFixtureReplacing(
    _ key: String,
    with value: Any,
    in json: String
) throws -> Data {
    guard var object = try JSONSerialization.jsonObject(
        with: officialFixtureData(json)
    ) as? [String: Any] else {
        throw OfficialWireFixtureError.expectedJSONObject
    }
    object[key] = value
    return try JSONSerialization.data(withJSONObject: object)
}

@Test
func storedTurnItemsDecodeAndRoundTripEveryOfficialStableVariant() throws {
    let decoder = JSONDecoder()
    let encoder = JSONEncoder()

    for (expectedKind, json, _) in officialStoredThreadItemFixtures {
        let decoded = try decoder.decode(
            CodexStoredThreadItem.self,
            from: officialFixtureData(json)
        )
        let originalJSON = try decoder.decode(
            CodexJSONValue.self,
            from: officialFixtureData(json)
        )
        let roundTrippedJSON = try decoder.decode(
            CodexJSONValue.self,
            from: encoder.encode(decoded)
        )

        #expect(decoded.kind == expectedKind)
        #expect(!decoded.id.isEmpty)
        #expect(roundTrippedJSON == originalJSON)
    }
}

@Test
func storedTurnItemsRejectMissingRequiredTopLevelFieldsAndUnknownTypes() throws {
    let decoder = JSONDecoder()

    for (_, json, requiredFields) in officialStoredThreadItemFixtures {
        for field in requiredFields {
            #expect(throws: (any Error).self) {
                try decoder.decode(
                    CodexStoredThreadItem.self,
                    from: officialFixtureDeleting(field, from: json)
                )
            }
        }
    }

    #expect(throws: (any Error).self) {
        try decoder.decode(
            CodexStoredThreadItem.self,
            from: officialFixtureData(#"{"id":"missing-type"}"#)
        )
    }
    #expect(throws: (any Error).self) {
        try decoder.decode(
            CodexStoredThreadItem.self,
            from: officialFixtureData(#"{"type":"futureItem","id":"future"}"#)
        )
    }
}

@Test
func storedUserMessageAppliesOfficialClientAndTextElementDefaults() throws {
    let decoder = JSONDecoder()
    let fixture = officialStoredThreadItemFixtures[0].1
    let item = try decoder.decode(
        CodexStoredThreadItem.self,
        from: officialFixtureData(fixture)
    )

    guard case let .userMessage(id, clientID, content) = item else {
        Issue.record("Expected a userMessage item")
        return
    }
    #expect(id == "user-1")
    #expect(clientID == "client-1")
    #expect(content.count == 7)
    guard case let .text(text, textElements) = content[0] else {
        Issue.record("Expected official text UserInput")
        return
    }
    #expect(text == "Inspect")
    #expect(textElements.isEmpty)

    let minimum = try decoder.decode(
        CodexStoredThreadItem.self,
        from: officialFixtureData(
            #"{"type":"userMessage","id":"minimum","content":[{"type":"text","text":"Inspect"}]}"#
        )
    )
    guard case let .userMessage(_, minimumClientID, minimumContent) = minimum,
          case let .text(_, minimumTextElements) = minimumContent.first
    else {
        Issue.record("Expected minimum official userMessage")
        return
    }
    #expect(minimumClientID == nil)
    #expect(minimumTextElements.isEmpty)
}

@Test
func storedTurnItemsRejectUnknownOfficialEnumsAndMalformedTopLevelShapes() throws {
    let decoder = JSONDecoder()
    let mutations: [(Int, String, Any)] = [
        (2, "phase", "future"),
        (5, "source", "future"),
        (5, "status", "future"),
        (6, "status", "future"),
        (7, "status", "future"),
        (8, "status", "future"),
        (9, "tool", "future"),
        (9, "status", "future"),
        (10, "kind", "future"),
    ]

    for (fixtureIndex, key, value) in mutations {
        #expect(throws: (any Error).self) {
            try decoder.decode(
                CodexStoredThreadItem.self,
                from: officialFixtureReplacing(
                    key,
                    with: value,
                    in: officialStoredThreadItemFixtures[fixtureIndex].1
                )
            )
        }
    }

    #expect(throws: (any Error).self) {
        try decoder.decode(
            CodexStoredThreadItem.self,
            from: officialFixtureData(
                #"{"type":"userMessage","id":"user-1","clientId":null,"content":[{"type":"image","detail":"future","url":"fixture://image"}]}"#
            )
        )
    }
    #expect(throws: (any Error).self) {
        try decoder.decode(
            CodexStoredThreadItem.self,
            from: officialFixtureReplacing(
                "receiverThreadIds",
                with: "receiver",
                in: officialStoredThreadItemFixtures[9].1
            )
        )
    }
}

@Test
func storedTurnItemNullableFieldsAcceptOmissionAndNull() throws {
    let decoder = JSONDecoder()
    let mcpWithoutDeprecatedURI =
        #"{"type":"mcpToolCall","id":"mcp-omitted","server":"fixture","tool":"read","status":"completed","arguments":null}"#
    let generatedWithoutSavedPath =
        #"{"type":"imageGeneration","id":"generated-omitted","status":"completed","result":"fixture"}"#

    #expect(
        try decoder.decode(
            CodexStoredThreadItem.self,
            from: officialFixtureData(mcpWithoutDeprecatedURI)
        ).kind == .mcpToolCall
    )
    #expect(
        try decoder.decode(
            CodexStoredThreadItem.self,
            from: officialFixtureData(generatedWithoutSavedPath)
        ).kind == .imageGeneration
    )
    #expect(
        try decoder.decode(
            CodexStoredThreadItem.self,
            from: officialFixtureData(
                mcpWithoutDeprecatedURI.replacingOccurrences(
                    of: #""arguments":null"#,
                    with: #""arguments":null,"mcpAppResourceUri":null"#
                )
            )
        ).kind == .mcpToolCall
    )
    #expect(
        try decoder.decode(
            CodexStoredThreadItem.self,
            from: officialFixtureData(
                generatedWithoutSavedPath.replacingOccurrences(
                    of: #""result":"fixture""#,
                    with: #""result":"fixture","savedPath":null"#
                )
            )
        ).kind == .imageGeneration
    )
    #expect(
        try decoder.decode(
            CodexStoredUserInput.self,
            from: officialFixtureData(
                #"{"type":"image","url":"fixture://image","detail":null}"#
            )
        ).kind == .image
    )
}

@Test
func storedThreadItemsApplyPinnedSchemaDefaults() throws {
    let decoder = JSONDecoder()
    let fixtures: [(String, CodexStoredThreadItemKind)] = [
        (
            #"{"type":"agentMessage","id":"agent","text":"Done"}"#,
            .agentMessage
        ),
        (#"{"type":"reasoning","id":"reason"}"#, .reasoning),
        (
            #"{"type":"commandExecution","id":"command","command":"pwd","cwd":"/workspace","status":"completed","commandActions":[]}"#,
            .commandExecution
        ),
        (
            #"{"type":"mcpToolCall","id":"mcp","server":"fixture","tool":"read","status":"completed","arguments":{}}"#,
            .mcpToolCall
        ),
        (
            #"{"type":"dynamicToolCall","id":"dynamic","tool":"fixture","arguments":{},"status":"completed"}"#,
            .dynamicToolCall
        ),
        (
            #"{"type":"collabAgentToolCall","id":"collab","tool":"wait","status":"completed","senderThreadId":"sender","receiverThreadIds":[],"agentsStates":{}}"#,
            .collabAgentToolCall
        ),
        (
            #"{"type":"webSearch","id":"web","query":"schema"}"#,
            .webSearch
        ),
        (
            #"{"type":"imageGeneration","id":"image","status":"completed","result":"fixture"}"#,
            .imageGeneration
        ),
    ]

    for (json, expectedKind) in fixtures {
        let item = try decoder.decode(
            CodexStoredThreadItem.self,
            from: officialFixtureData(json)
        )
        #expect(item.kind == expectedKind)
    }

    let command = try decoder.decode(
        CodexStoredThreadItem.self,
        from: officialFixtureData(fixtures[2].0)
    )
    guard case let .commandExecution(
        _, _, _, processID, source, _, _, output, exitCode, durationMs
    ) = command else {
        Issue.record("Expected minimum commandExecution")
        return
    }
    #expect(source == .agent)
    #expect(processID == nil)
    #expect(output == nil)
    #expect(exitCode == nil)
    #expect(durationMs == nil)
}

@Test
func codexErrorInfoDecodesEveryOfficialVariantAndRoundTrips() throws {
    let fixtures: [(String, CodexErrorInfo)] = [
        (#""contextWindowExceeded""#, .contextWindowExceeded),
        (#""sessionBudgetExceeded""#, .sessionBudgetExceeded),
        (#""usageLimitExceeded""#, .usageLimitExceeded),
        (#""serverOverloaded""#, .serverOverloaded),
        (#""cyberPolicy""#, .cyberPolicy),
        (#""internalServerError""#, .internalServerError),
        (#""unauthorized""#, .unauthorized),
        (#""badRequest""#, .badRequest),
        (#""threadRollbackFailed""#, .threadRollbackFailed),
        (#""sandboxError""#, .sandboxError),
        (#""other""#, .other),
        (
            #"{"httpConnectionFailed":{"httpStatusCode":502}}"#,
            .httpConnectionFailed(httpStatusCode: 502)
        ),
        (
            #"{"responseStreamConnectionFailed":{"httpStatusCode":null}}"#,
            .responseStreamConnectionFailed(httpStatusCode: nil)
        ),
        (
            #"{"responseStreamDisconnected":{"httpStatusCode":503}}"#,
            .responseStreamDisconnected(httpStatusCode: 503)
        ),
        (
            #"{"responseTooManyFailedAttempts":{"httpStatusCode":429}}"#,
            .responseTooManyFailedAttempts(httpStatusCode: 429)
        ),
        (
            #"{"activeTurnNotSteerable":{"turnKind":"review"}}"#,
            .activeTurnNotSteerable(turnKind: .review)
        ),
        (
            #"{"activeTurnNotSteerable":{"turnKind":"compact"}}"#,
            .activeTurnNotSteerable(turnKind: .compact)
        ),
    ]
    let decoder = JSONDecoder()
    let encoder = JSONEncoder()

    for (json, expected) in fixtures {
        let decoded = try decoder.decode(
            CodexErrorInfo.self,
            from: officialFixtureData(json)
        )
        #expect(decoded == expected)
        #expect(
            try decoder.decode(
                CodexJSONValue.self,
                from: encoder.encode(decoded)
            )
                == decoder.decode(
                    CodexJSONValue.self,
                    from: officialFixtureData(json)
                )
        )
    }
}

@Test
func codexErrorInfoRejectsUnknownOrMalformedVariants() {
    let invalid = [
        #""futureError""#,
        #"42"#,
        #"{}"#,
        #"{"httpConnectionFailed":{}}"#,
        #"{"httpConnectionFailed":{"httpStatusCode":"502"}}"#,
        #"{"httpConnectionFailed":{"httpStatusCode":502},"other":{}}"#,
        #"{"activeTurnNotSteerable":{"turnKind":"future"}}"#,
    ]

    for json in invalid {
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(
                CodexErrorInfo.self,
                from: officialFixtureData(json)
            )
        }
    }
}

@Test
func codexErrorInfoRejectsNonFiniteNumbersDuringEncodingWithoutTrapping() {
    #expect(throws: (any Error).self) {
        try JSONEncoder().encode(
            CodexErrorInfo.httpConnectionFailed(
                httpStatusCode: .infinity
            )
        )
    }
}

@Test
func sessionSourceDecodesOnlyOfficialStringsAndTypedSubAgentVariants() throws {
    let fixtures: [(String, CodexThreadSessionSource)] = [
        (#""cli""#, .named(.cli)),
        (#""vscode""#, .named(.vscode)),
        (#""exec""#, .named(.exec)),
        (#""appServer""#, .named(.appServer)),
        (#""unknown""#, .named(.unknown)),
        (#"{"custom":"fixture"}"#, .custom("fixture")),
        (#"{"subAgent":"review"}"#, .subAgent(.review)),
        (#"{"subAgent":"compact"}"#, .subAgent(.compact)),
        (
            #"{"subAgent":"memory_consolidation"}"#,
            .subAgent(.memoryConsolidation)
        ),
        (
            #"{"subAgent":{"thread_spawn":{"parent_thread_id":"parent","depth":3,"agent_path":"/root/child","agent_nickname":"Scout","agent_role":null,"model":null}}}"#,
            .subAgent(
                .threadSpawn(
                    parentThreadID: CodexStoredThreadID("parent"),
                    depth: 3,
                    agentPath: "/root/child",
                    agentNickname: "Scout",
                    agentRole: nil,
                    model: nil
                )
            )
        ),
        (
            #"{"subAgent":{"other":"fixture"}}"#,
            .subAgent(.other("fixture"))
        ),
    ]

    let decoder = JSONDecoder()
    let encoder = JSONEncoder()
    for (json, expected) in fixtures {
        let decoded = try decoder.decode(
            CodexThreadSessionSource.self,
            from: officialFixtureData(json)
        )
        #expect(decoded == expected)
        #expect(
            try decoder.decode(
                CodexJSONValue.self,
                from: encoder.encode(decoded)
            )
                == decoder.decode(
                    CodexJSONValue.self,
                    from: officialFixtureData(json)
                )
        )
    }
}

@Test
func sessionSourceAcceptsMinimumSpawnDefaultsAndInt32Depth() throws {
    let decoder = JSONDecoder()
    let minimum =
        #"{"subAgent":{"thread_spawn":{"parent_thread_id":"parent","depth":3}}}"#
    let withOptionalNulls =
        #"{"subAgent":{"thread_spawn":{"parent_thread_id":"parent","depth":3,"agent_path":null,"agent_nickname":null,"agent_role":null,"model":null}}}"#

    _ = try decoder.decode(
        CodexThreadSessionSource.self,
        from: officialFixtureData(minimum)
    )
    _ = try decoder.decode(
        CodexThreadSessionSource.self,
        from: officialFixtureData(withOptionalNulls)
    )

    for invalidDepth in ["3.5", "2147483648", "-2147483649"] {
        #expect(throws: (any Error).self) {
            try decoder.decode(
                CodexThreadSessionSource.self,
                from: officialFixtureData(
                    minimum.replacingOccurrences(
                        of: #""depth":3"#,
                        with: #""depth":\#(invalidDepth)"#
                    )
                )
            )
        }
    }
}

@Test
func sessionSourceRejectsUnknownOrMalformedOfficialVariants() {
    let invalid = [
        #""app""#,
        #""review""#,
        #"{}"#,
        #"{"custom":null}"#,
        #"{"custom":"fixture","subAgent":"review"}"#,
        #"{"subAgent":"future"}"#,
        #"{"subAgent":{"other":null}}"#,
        #"{"subAgent":{"thread_spawn":{"parent_thread_id":"parent","depth":"1","agent_path":null,"agent_nickname":null,"agent_role":null}}}"#,
    ]

    for json in invalid {
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(
                CodexThreadSessionSource.self,
                from: officialFixtureData(json)
            )
        }
    }
}

@Test
func threadListLineageFiltersPreserveOmittedNullAndValueExactly() throws {
    let omitted = CodexAppServerThreadRequest.list(
        id: .integer(20),
        params: CodexThreadListParams()
    )
    let null = CodexAppServerThreadRequest.list(
        id: .integer(21),
        params: CodexThreadListParams(
            parentThreadID: .null,
            ancestorThreadID: .null
        )
    )
    let parent = CodexAppServerThreadRequest.list(
        id: .integer(22),
        params: CodexThreadListParams(parentThreadID: .value("parent"))
    )
    let ancestor = CodexAppServerThreadRequest.list(
        id: .integer(23),
        params: CodexThreadListParams(ancestorThreadID: .value("ancestor"))
    )
    let nullAndValue = CodexAppServerThreadRequest.list(
        id: .integer(24),
        params: CodexThreadListParams(
            parentThreadID: .null,
            ancestorThreadID: .value("ancestor")
        )
    )

    #expect(
        try omitted.encodedData()
            == Data(#"{"id":20,"method":"thread/list","params":{}}"#.utf8)
    )
    #expect(
        try null.encodedData()
            == Data(
                #"{"id":21,"method":"thread/list","params":{"ancestorThreadId":null,"parentThreadId":null}}"#.utf8
            )
    )
    #expect(
        try parent.encodedData()
            == Data(
                #"{"id":22,"method":"thread/list","params":{"parentThreadId":"parent"}}"#.utf8
            )
    )
    #expect(
        try ancestor.encodedData()
            == Data(
                #"{"id":23,"method":"thread/list","params":{"ancestorThreadId":"ancestor"}}"#.utf8
            )
    )
    #expect(
        try nullAndValue.encodedData()
            == Data(
                #"{"id":24,"method":"thread/list","params":{"ancestorThreadId":"ancestor","parentThreadId":null}}"#.utf8
            )
    )
}

@Test
func threadListRejectsBothLineageFilterValuesLocally() {
    let request = CodexAppServerThreadRequest.list(
        id: .integer(25),
        params: CodexThreadListParams(
            parentThreadID: .value("parent"),
            ancestorThreadID: .value("ancestor")
        )
    )

    #expect(
        throws:
            CodexAppServerThreadEnvelopeError
                .mutuallyExclusiveThreadLineageFilters,
        performing: { try request.encodedData() }
    )
}

@Test
func experimentalStoredThreadFieldsAreRetainedWhileStableOmissionDecodes() throws {
    let experimentalJSON = storedThreadJSON
        .replacingOccurrences(
            of: #""sessionId":"#,
            with: #""extra":{},"historyMode":"paginated","sessionId":"#
        )
        .replacingOccurrences(
            of: #""threadSource":"#,
            with: #""canAcceptDirectInput":true,"threadSource":"#
        )
    let decoder = JSONDecoder()
    let stable = try decoder.decode(
        CodexStoredThread.self,
        from: officialFixtureData(storedThreadJSON)
    )
    let experimental = try decoder.decode(
        CodexStoredThread.self,
        from: officialFixtureData(experimentalJSON)
    )

    #expect(stable.extra == nil)
    #expect(stable.historyMode == .legacy)
    #expect(stable.canAcceptDirectInput == nil)
    #expect(experimental.extra == CodexThreadExtra())
    #expect(experimental.historyMode == .paginated)
    #expect(experimental.canAcceptDirectInput == true)

    let encoded = try JSONSerialization.jsonObject(
        with: JSONEncoder().encode(experimental)
    )
    let encodedObject = try #require(encoded as? [String: Any])
    #expect((encodedObject["extra"] as? [String: Any])?.isEmpty == true)
    #expect(encodedObject["historyMode"] as? String == "paginated")
    #expect(encodedObject["canAcceptDirectInput"] as? Bool == true)

    #expect(throws: (any Error).self) {
        try decoder.decode(
            CodexStoredThread.self,
            from: officialFixtureData(
                experimentalJSON.replacingOccurrences(
                    of: #""historyMode":"paginated""#,
                    with: #""historyMode":"future""#
                )
            )
        )
    }
}

@Test
func experimentalStoredThreadAcceptsAndRetainsNullableOptionalFields() throws {
    let nullExtraJSON = storedThreadJSON
        .replacingOccurrences(
            of: #""sessionId":"#,
            with: #""extra":null,"sessionId":"#
        )
    let nullDirectInputJSON = storedThreadJSON
        .replacingOccurrences(
            of: #""threadSource":"#,
            with: #""canAcceptDirectInput":null,"threadSource":"#
        )

    for json in [nullExtraJSON, nullDirectInputJSON] {
        let decoded = try JSONDecoder().decode(
            CodexStoredThread.self,
            from: officialFixtureData(json)
        )
        let encoded = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(decoded)
        )
        let object = try #require(encoded as? [String: Any])

        if json == nullExtraJSON {
            #expect(object["extra"] is NSNull)
        } else {
            #expect(object["canAcceptDirectInput"] is NSNull)
        }
    }
}

@Test
func storedThreadDecodesPinnedMinimumAndOmitsNilOptionals() throws {
    let minimumJSON = #"""
    {
      "cliVersion":"26.721.81911",
      "createdAt":1,
      "cwd":"/workspace",
      "ephemeral":false,
      "id":"thread-minimum",
      "modelProvider":"openai",
      "preview":"",
      "sessionId":"session-minimum",
      "source":"appServer",
      "status":{"type":"idle"},
      "turns":[],
      "updatedAt":2
    }
    """#
    let thread = try JSONDecoder().decode(
        CodexStoredThread.self,
        from: officialFixtureData(minimumJSON)
    )
    #expect(thread.forkedFromID == nil)
    #expect(thread.parentThreadID == nil)
    #expect(thread.recencyAt == nil)
    #expect(thread.path == nil)
    #expect(thread.threadSource == nil)
    #expect(thread.agentNickname == nil)
    #expect(thread.agentRole == nil)
    #expect(thread.gitInfo == nil)
    #expect(thread.name == nil)
    #expect(thread.historyMode == .legacy)

    let encoded = try JSONSerialization.jsonObject(
        with: JSONEncoder().encode(thread)
    )
    let object = try #require(encoded as? [String: Any])
    for field in [
        "forkedFromId",
        "parentThreadId",
        "recencyAt",
        "path",
        "threadSource",
        "agentNickname",
        "agentRole",
        "gitInfo",
        "name",
    ] {
        #expect(object[field] == nil)
    }
}

@Test
func storedThreadRejectsNullHistoryMode() {
    let nullHistoryJSON = storedThreadJSON.replacingOccurrences(
        of: #""sessionId":"#,
        with: #""historyMode":null,"sessionId":"#
    )
    #expect(throws: (any Error).self) {
        try JSONDecoder().decode(
            CodexStoredThread.self,
            from: officialFixtureData(nullHistoryJSON)
        )
    }
}

@Test
func storedTurnAndErrorDecodePinnedMinimumsAndDefaults() throws {
    let turn = try JSONDecoder().decode(
        CodexStoredTurn.self,
        from: officialFixtureData(
            #"{"id":"turn","items":[],"status":"completed"}"#
        )
    )
    #expect(turn.itemsView == .full)
    #expect(turn.error == nil)
    #expect(turn.startedAt == nil)
    #expect(turn.completedAt == nil)
    #expect(turn.durationMs == nil)
    #expect(throws: (any Error).self) {
        try JSONDecoder().decode(
            CodexStoredTurn.self,
            from: officialFixtureData(
                #"{"id":"turn","items":[],"itemsView":null,"status":"completed"}"#
            )
        )
    }

    let error = try JSONDecoder().decode(
        CodexStoredTurnError.self,
        from: officialFixtureData(#"{"message":"failed"}"#)
    )
    #expect(error.message == "failed")
    #expect(error.codexErrorInfo == nil)
    #expect(error.additionalDetails == nil)
}

@Test
func experimentalThreadExtraRoundTripsOpaqueObject() throws {
    let opaqueJSON = storedThreadJSON.replacingOccurrences(
        of: #""sessionId":"#,
        with:
            #""extra":{"future":true,"nested":{"values":[1,null,"two"]}},"historyMode":"legacy","sessionId":"#
    )
    let decoded = try JSONDecoder().decode(
        CodexStoredThread.self,
        from: officialFixtureData(opaqueJSON)
    )
    let encoded = try JSONDecoder().decode(
        CodexJSONValue.self,
        from: JSONEncoder().encode(decoded)
    )
    guard case let .object(threadObject) = encoded else {
        Issue.record("Expected encoded thread object")
        return
    }
    #expect(
        threadObject["extra"]
            == .object([
                "future": .bool(true),
                "nested": .object([
                    "values": .array([
                        .integer(1),
                        .null,
                        .string("two"),
                    ]),
                ]),
            ])
    )
}

@Test
func threadSettingsUpdateRequestEncodesEveryOfficialFieldExactly() throws {
    let params = CodexThreadSettingsUpdateParams(
        threadID: CodexStoredThreadID("Thread/Raw/Ω"),
        cwd: .value("/Workspace/Mixed Case"),
        approvalPolicy: .value(
            .granular(
                .init(
                    sandboxApproval: true,
                    rules: false,
                    skillApproval: true,
                    requestPermissions: false,
                    mcpElicitations: true
                )
            )
        ),
        approvalsReviewer: .value(.guardianSubagent),
        sandboxPolicy: .value(
            .workspaceWrite(
                writableRoots: ["/Workspace/Mixed Case"],
                networkAccess: true,
                excludeTmpdirEnvVar: false,
                excludeSlashTmp: true
            )
        ),
        permissions: .value(":workspace"),
        model: .value("model-next"),
        serviceTier: .value("priority"),
        effort: .value("future-super-deep-v9"),
        summary: .value(.detailed),
        collaborationMode: .value(
            .init(
                mode: .plan,
                settings: .init(
                    model: "collaboration-model",
                    reasoningEffort: "low",
                    developerInstructions: "Plan carefully."
                )
            )
        ),
        multiAgentMode: .value(.custom("fixture-policy")),
        personality: .value(.pragmatic)
    )
    let request = CodexAppServerThreadRequest.settingsUpdate(
        id: .string("settings-1"),
        params: params
    )

    #expect(
        try request.encodedData()
            == Data(
                #"{"id":"settings-1","method":"thread/settings/update","params":{"approvalPolicy":{"granular":{"mcp_elicitations":true,"request_permissions":false,"rules":false,"sandbox_approval":true,"skill_approval":true}},"approvalsReviewer":"guardian_subagent","collaborationMode":{"mode":"plan","settings":{"developer_instructions":"Plan carefully.","model":"collaboration-model","reasoning_effort":"low"}},"cwd":"/Workspace/Mixed Case","effort":"future-super-deep-v9","model":"model-next","multiAgentMode":{"custom":"fixture-policy"},"permissions":":workspace","personality":"pragmatic","sandboxPolicy":{"excludeSlashTmp":true,"excludeTmpdirEnvVar":false,"networkAccess":true,"type":"workspaceWrite","writableRoots":["/Workspace/Mixed Case"]},"serviceTier":"priority","summary":"detailed","threadId":"Thread/Raw/Ω"}}"#
                    .utf8
            )
    )
}

@Test
func threadSettingsUpdateRequestCoversThreadSettingsUpdateParamsOmittedNullAndIntegerIDs() throws {
    let officialMethod = "thread/settings/update"
    let omitted = CodexAppServerThreadRequest.settingsUpdate(
        id: .integer(71),
        params: CodexThreadSettingsUpdateParams(
            threadID: CodexStoredThreadID("Thread-Raw")
        )
    )
    let null = CodexAppServerThreadRequest.settingsUpdate(
        id: .integer(72),
        params: CodexThreadSettingsUpdateParams(
            threadID: CodexStoredThreadID("Thread-Raw"),
            cwd: .null,
            approvalPolicy: .null,
            approvalsReviewer: .null,
            sandboxPolicy: .null,
            permissions: .null,
            model: .null,
            serviceTier: .null,
            effort: .null,
            summary: .null,
            collaborationMode: .null,
            multiAgentMode: .null,
            personality: .null
        )
    )

    #expect(
        try omitted.encodedData()
            == Data(
                #"{"id":71,"method":"thread/settings/update","params":{"threadId":"Thread-Raw"}}"#
                    .utf8
            )
    )
    #expect(
        try null.encodedData()
            == Data(
                #"{"id":72,"method":"thread/settings/update","params":{"approvalPolicy":null,"approvalsReviewer":null,"collaborationMode":null,"cwd":null,"effort":null,"model":null,"multiAgentMode":null,"permissions":null,"personality":null,"sandboxPolicy":null,"serviceTier":null,"summary":null,"threadId":"Thread-Raw"}}"#
                    .utf8
            )
    )
    let wire = try JSONDecoder().decode(
        CodexJSONValue.self,
        from: omitted.encodedData()
    )
    guard case let .object(fields) = wire else {
        Issue.record("thread settings update request must be an object")
        return
    }
    #expect(fields["method"] == .string(officialMethod))
}

@Test
func threadSettingsUpdateResponseCoversThreadSettingsUpdateResponseOfficialEmptyObject() throws {
    let response = try JSONDecoder().decode(
        CodexAppServerResponse<CodexThreadSettingsUpdateResponse>.self,
        from: Data(#"{"id":"settings-empty","result":{}}"#.utf8)
    )

    #expect(response.id == .string("settings-empty"))
    #expect(response.result == CodexThreadSettingsUpdateResponse())
    #expect(try JSONEncoder().encode(response.result) == Data("{}".utf8))
}

@Test
func threadSettingsUpdatedNotificationPreservesTheCompleteSnapshot() throws {
    let data = Data(
        #"""
        {
          "method":"thread/settings/updated",
          "params":{
            "threadId":"Thread/Raw/Ω",
            "threadSettings":{
              "cwd":"/Workspace/Mixed Case",
              "approvalPolicy":"on-request",
              "approvalsReviewer":"auto_review",
              "sandboxPolicy":{
                "type":"externalSandbox",
                "networkAccess":"enabled"
              },
              "activePermissionProfile":{
                "id":"profile-private",
                "extends":":workspace"
              },
              "model":"model-notified",
              "modelProvider":"provider-notified",
              "serviceTier":"priority",
              "effort":"future-super-deep-v9",
              "summary":"detailed",
              "collaborationMode":{
                "mode":"default",
                "settings":{
                  "model":"collaboration-model",
                  "reasoning_effort":null,
                  "developer_instructions":"Keep continuity."
                }
              },
              "multiAgentMode":{"custom":"fixture-policy"},
              "personality":"friendly"
            }
          }
        }
        """#.utf8
    )
    let event = try CodexCoreEvent(data: data)
    guard case .threadSettingsUpdated(let notification) = event else {
        Issue.record("Expected formal thread/settings/updated notification")
        return
    }
    let settings = notification.threadSettings
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]

    #expect(notification.threadID == CodexStoredThreadID("Thread/Raw/Ω"))
    #expect(settings.cwd == "/Workspace/Mixed Case")
    #expect(settings.approvalPolicy == .onRequest)
    #expect(settings.approvalsReviewer == .autoReview)
    #expect(
        settings.sandboxPolicy
            == .externalSandbox(networkAccess: .enabled)
    )
    #expect(
        settings.activePermissionProfile
            == .init(id: "profile-private", extends: ":workspace")
    )
    #expect(settings.model == "model-notified")
    #expect(settings.modelProvider == "provider-notified")
    #expect(settings.serviceTier == "priority")
    #expect(settings.effort == "future-super-deep-v9")
    #expect(settings.summary == .detailed)
    #expect(settings.collaborationMode.mode == .default)
    #expect(
        settings.collaborationMode.settings.reasoningEffort == nil
    )
    #expect(
        settings.collaborationMode.settings.developerInstructions
            == "Keep continuity."
    )
    #expect(settings.multiAgentMode == .custom("fixture-policy"))
    #expect(settings.personality == .friendly)
    #expect(
        try encoder.encode(settings)
            == Data(
                #"{"activePermissionProfile":{"extends":":workspace","id":"profile-private"},"approvalPolicy":"on-request","approvalsReviewer":"auto_review","collaborationMode":{"mode":"default","settings":{"developer_instructions":"Keep continuity.","model":"collaboration-model","reasoning_effort":null}},"cwd":"/Workspace/Mixed Case","effort":"future-super-deep-v9","model":"model-notified","modelProvider":"provider-notified","multiAgentMode":{"custom":"fixture-policy"},"personality":"friendly","sandboxPolicy":{"networkAccess":"enabled","type":"externalSandbox"},"serviceTier":"priority","summary":"detailed"}"#
                    .utf8
            )
    )
}

@Test
func threadSettingsSnapshotEncodesNilOfficialFieldsAsExplicitNulls() throws {
    let settings = CodexAppServerThreadSettings(
        cwd: "/workspace",
        approvalPolicy: .never,
        approvalsReviewer: .user,
        sandboxPolicy: .dangerFullAccess,
        activePermissionProfile: nil,
        model: "model",
        modelProvider: "provider",
        serviceTier: nil,
        effort: nil,
        summary: nil,
        collaborationMode: .init(
            mode: .default,
            settings: .init(
                model: "model",
                reasoningEffort: nil,
                developerInstructions: nil
            )
        ),
        multiAgentMode: .explicitRequestOnly,
        personality: nil
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]

    #expect(
        try encoder.encode(settings)
            == Data(
                #"{"activePermissionProfile":null,"approvalPolicy":"never","approvalsReviewer":"user","collaborationMode":{"mode":"default","settings":{"developer_instructions":null,"model":"model","reasoning_effort":null}},"cwd":"/workspace","effort":null,"model":"model","modelProvider":"provider","multiAgentMode":"explicitRequestOnly","personality":null,"sandboxPolicy":{"type":"dangerFullAccess"},"serviceTier":null,"summary":null}"#
                    .utf8
            )
    )
}

@Test
func threadShellCommandCoversThreadShellCommandParamsAndThreadShellCommandResponse() throws {
    let officialMethod = "thread/shellCommand"
    let request = CodexAppServerThreadRequest.shellCommand(
        id: .string("shell-1"),
        threadID: CodexStoredThreadID("Thread-Raw"),
        command: "printf 'alpha beta' | tr a-z A-Z > result.txt"
    )
    #expect(
        try request.encodedData()
            == Data(
                #"{"id":"shell-1","method":"thread/shellCommand","params":{"command":"printf 'alpha beta' | tr a-z A-Z > result.txt","threadId":"Thread-Raw"}}"#
                    .utf8
            )
    )
    let response = try JSONDecoder().decode(
        CodexAppServerResponse<CodexThreadEmptyResponse>.self,
        from: Data(#"{"id":"shell-1","result":{}}"#.utf8)
    )
    #expect(response.result == CodexThreadEmptyResponse())
    let wire = try JSONDecoder().decode(
        CodexJSONValue.self,
        from: request.encodedData()
    )
    guard case let .object(fields) = wire else {
        Issue.record("thread shell command request must be an object")
        return
    }
    #expect(fields["method"] == .string(officialMethod))
    #expect(throws: CodexAppServerThreadEnvelopeError.self) {
        try CodexAppServerThreadRequest.shellCommand(
            id: .string("blank"),
            threadID: CodexStoredThreadID("Thread-Raw"),
            command: " \n "
        ).encodedData()
    }
}

@Test
func threadApproveGuardianDeniedActionPreservesSerializedEvent() throws {
    let event = CodexJSONValue.object([
        "id": .string("review-command-1"),
        "target_item_id": .string("command-1"),
        "status": .string("denied"),
        "action": .object([
            "type": .string("command"),
            "source": .string("shell"),
            "command": .string("printf approved"),
            "cwd": .string("/workspace"),
        ]),
    ])
    let request = CodexAppServerThreadRequest.approveGuardianDeniedAction(
        id: .string("approve-1"),
        threadID: CodexStoredThreadID("thread-a"),
        event: event
    )
    #expect(
        try request.encodedData()
            == Data(
                #"{"id":"approve-1","method":"thread/approveGuardianDeniedAction","params":{"event":{"action":{"command":"printf approved","cwd":"/workspace","source":"shell","type":"command"},"id":"review-command-1","status":"denied","target_item_id":"command-1"},"threadId":"thread-a"}}"#
                    .utf8
            )
    )
    let response = try JSONDecoder().decode(
        CodexAppServerResponse<CodexThreadEmptyResponse>.self,
        from: Data(#"{"id":"approve-1","result":{}}"#.utf8)
    )
    #expect(response.result == CodexThreadEmptyResponse())
}

@Test
func threadMemoryModeSetRequestMatchesReleasedStableWireContract() throws {
    let request = CodexAppServerThreadRequest.memoryModeSet(
        id: .integer(73),
        params: CodexThreadMemoryModeSetParams(
            threadID: CodexStoredThreadID("Thread/Raw/Ω"),
            mode: .disabled
        )
    )

    #expect(
        try request.encodedData()
            == Data(
                #"{"id":73,"method":"thread/memoryMode/set","params":{"mode":"disabled","threadId":"Thread/Raw/Ω"}}"#.utf8
            )
    )
}

@Test
func releasedGitDiffToRemoteRequestAndResponseMatchWireContract() throws {
    let request = CodexAppServerThreadRequest.gitDiffToRemote(
        id: .integer(74),
        params: CodexGitDiffToRemoteParams(
            cwd: "/Workspace/Mixed Case"
        )
    )
    #expect(
        try request.encodedData()
            == Data(
                #"{"id":74,"method":"gitDiffToRemote","params":{"cwd":"/Workspace/Mixed Case"}}"#
                    .utf8
            )
    )

    let sha = "0123456789abcdef0123456789abcdef01234567"
    let data = Data(
        #"{"id":74,"result":{"sha":"\#(sha)","diff":"diff --git a/file b/file\n"}}"#
            .utf8
    )
    let reply = try JSONDecoder().decode(
        CodexAppServerReply<CodexGitDiffToRemoteResponse>.self,
        from: data
    )
    #expect(
        reply == .success(
            CodexAppServerResponse(
                id: .integer(74),
                result: CodexGitDiffToRemoteResponse(
                    sha: sha,
                    diff: "diff --git a/file b/file\n"
                )
            )
        )
    )
}

@Test
func threadUnsubscribeUsesOfficialMethodAndStatusValues() throws {
    let request = CodexAppServerThreadRequest.unsubscribe(
        id: .integer(41),
        threadID: CodexStoredThreadID("thread-a")
    )
    #expect(
        try request.encodedData()
            == Data(
                #"{"id":41,"method":"thread/unsubscribe","params":{"threadId":"thread-a"}}"#
                    .utf8
            )
    )
    for status in CodexThreadUnsubscribeStatus.allCasesForTesting {
        let data = Data(
            #"{"id":41,"result":{"status":"\#(status.rawValue)"}}"#.utf8
        )
        let response = try JSONDecoder().decode(
            CodexAppServerResponse<CodexThreadUnsubscribeResponse>.self,
            from: data
        )
        #expect(response.result.status == status)
    }
}

private extension CodexThreadUnsubscribeStatus {
    static let allCasesForTesting: [Self] = [
        .notLoaded, .notSubscribed, .unsubscribed,
    ]
}
