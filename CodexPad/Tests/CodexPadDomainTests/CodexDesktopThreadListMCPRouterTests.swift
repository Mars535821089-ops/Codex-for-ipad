import CodexPadApplication
import CodexPadDomain
import CodexPadProtocolBridge
import Foundation
import Testing

@MainActor
private final class ThreadListMCPListingSpy:
    CodexDesktopThreadSessionListing
{
    enum Outcome {
        case success(CodexThreadPage)
        case failure(CodexSessionStoreError)
    }

    private let outcome: Outcome
    private(set) var receivedIDs: [CodexAppServerRequestID] = []
    private(set) var receivedParams: [CodexThreadListParams] = []

    init(_ outcome: Outcome) {
        self.outcome = outcome
    }

    func listThreads(
        id: CodexAppServerRequestID,
        params: CodexThreadListParams
    ) throws -> CodexThreadPage {
        receivedIDs.append(id)
        receivedParams.append(params)
        switch outcome {
        case let .success(page):
            return page
        case let .failure(error):
            throw error
        }
    }
}

@MainActor
private final class ThreadListMCPTransport: CodexCoreTransport {
    private(set) var requested: [CodexAppServerThreadRequest] = []
    private let reply: Data

    init(reply: Data) {
        self.reply = reply
    }

    func submit(_ command: CodexCoreCommand) throws {}

    func request(
        _ request: CodexAppServerThreadRequest
    ) throws -> Data {
        requested.append(request)
        return reply
    }

    func nextEvent() throws -> CodexCoreEvent? {
        nil
    }
}

@MainActor
@Test
func desktopThreadListMCPRouterPreservesIDParamsAndPageCursors()
    async throws
{
    let thread = threadListMCPStoredThread()
    let page = CodexThreadPage(
        data: [thread],
        nextCursor: "next-opaque",
        backwardsCursor: "backwards-opaque"
    )
    let listing = ThreadListMCPListingSpy(.success(page))
    let requestID = CodexAppServerRequestID.string(
        "thread-list-request"
    )
    let expectedParams = CodexThreadListParams(
        cursor: .value("cursor-opaque"),
        limit: .value(25),
        sortKey: .value(.updatedAt),
        sortDirection: .value(.descending),
        modelProviders: .value(["openai", "local"]),
        sourceKinds: .value([.cli, .subAgent]),
        archived: .value(false),
        cwd: .value(.many(["/workspace/a", "/workspace/b"])),
        useStateDbOnly: true,
        searchTerm: .value("active project"),
        parentThreadID: .value("parent-thread"),
        ancestorThreadID: .null
    )

    let response =
        await CodexDesktopInitialMCPRouter
            .responseIncludingFileSystem(
                to: threadListMCPRequest(
                    id: requestID,
                    params: .object([
                        "cursor": .string("cursor-opaque"),
                        "limit": .integer(25),
                        "sortKey": .string("updated_at"),
                        "sortDirection": .string("desc"),
                        "modelProviders": .array([
                            .string("openai"),
                            .string("local"),
                        ]),
                        "sourceKinds": .array([
                            .string("cli"),
                            .string("subAgent"),
                        ]),
                        "archived": .bool(false),
                        "cwd": .array([
                            .string("/workspace/a"),
                            .string("/workspace/b"),
                        ]),
                        "useStateDbOnly": .bool(true),
                        "searchTerm": .string("active project"),
                        "parentThreadId": .string("parent-thread"),
                        "ancestorThreadId": .null,
                        "futureField": .string("ignored"),
                    ])
                ),
                state: threadListMCPState(),
                allowedFileSystemRoots: [],
                threadLister: listing
            )

    #expect(listing.receivedIDs == [requestID])
    #expect(listing.receivedParams == [expectedParams])
    #expect(
        response
            == .mcpResponse(
                hostID: "desktop-host-thread-list",
                message: .object([
                    "id": .string("thread-list-request"),
                    "result": .object([
                        "data": try threadListMCPJSONValue([thread]),
                        "nextCursor": .string("next-opaque"),
                        "backwardsCursor":
                            .string("backwards-opaque"),
                    ]),
                ]),
                metadata: [:]
            )
    )
}

@MainActor
@Test
func desktopThreadListMCPRouterRejectsMalformedParamsWithoutListing()
    async
{
    let listing = ThreadListMCPListingSpy(
        .success(
            .init(
                data: [],
                nextCursor: nil,
                backwardsCursor: nil
            )
        )
    )
    let malformed: [CodexJSONValue?] = [
        nil,
        .string("not-an-object"),
        .object(["limit": .integer(-1)]),
        .object([
            "limit": .integer(Int64(UInt32.max) + 1)
        ]),
        .object([
            "sourceKinds": .array([.string("future-kind")])
        ]),
        .object([
            "cwd": .array([
                .string("/workspace"),
                .bool(true),
            ])
        ]),
        .object([
            "parentThreadId": .string("parent"),
            "ancestorThreadId": .string("ancestor"),
        ]),
    ]

    for (offset, params) in malformed.enumerated() {
        let id = CodexAppServerRequestID.integer(
            Int64(700 + offset)
        )
        let response =
            await CodexDesktopInitialMCPRouter
                .responseIncludingFileSystem(
                    to: threadListMCPRequest(
                        id: id,
                        params: params
                    ),
                    state: threadListMCPState(),
                    allowedFileSystemRoots: [],
                    threadLister: listing
                )

        #expect(
            response
                == threadListMCPError(
                    id: id,
                    code: -32602,
                    message: "Invalid params for thread/list"
                )
        )
    }

    #expect(listing.receivedIDs.isEmpty)
    #expect(listing.receivedParams.isEmpty)
}

@MainActor
@Test
func desktopThreadListMCPRouterPreservesBackendErrorPayload()
    async
{
    let requestID = CodexAppServerRequestID.integer(803)
    let errorData = CodexJSONValue.object([
        "field": .string("cursor"),
        "retryable": .bool(false),
    ])
    let listing = ThreadListMCPListingSpy(
        .failure(
            .appServerError(
                code: -32_077,
                message: "thread listing failed",
                data: errorData
            )
        )
    )

    let response =
        await CodexDesktopInitialMCPRouter
            .responseIncludingFileSystem(
                to: threadListMCPRequest(
                    id: requestID,
                    params: .object([:])
                ),
                state: threadListMCPState(),
                allowedFileSystemRoots: [],
                threadLister: listing
            )

    #expect(listing.receivedIDs == [requestID])
    #expect(listing.receivedParams == [.init()])
    #expect(
        response
            == threadListMCPError(
                id: requestID,
                code: -32_077,
                message: "thread listing failed",
                data: errorData
            )
    )
}

@MainActor
@Test
func desktopThreadListMCPRouterUsesRealSessionStoreBoundary()
    async throws
{
    let requestID = CodexAppServerRequestID.string(
        "real-session-list"
    )
    let params = CodexThreadListParams(
        limit: .value(10),
        cwd: .value(.one("/workspace"))
    )
    let page = CodexThreadPage(
        data: [threadListMCPStoredThread()],
        nextCursor: nil,
        backwardsCursor: "previous-page"
    )
    let reply =
        CodexAppServerReply<CodexThreadPage>.success(
            .init(id: requestID, result: page)
        )
    let transport = ThreadListMCPTransport(
        reply: try JSONEncoder().encode(reply)
    )
    let store = CodexSessionStore(transport: transport)

    let response =
        await CodexDesktopInitialMCPRouter
            .responseIncludingFileSystem(
                to: threadListMCPRequest(
                    id: requestID,
                    params: .object([
                        "limit": .integer(10),
                        "cwd": .string("/workspace"),
                    ])
                ),
                state: threadListMCPState(),
                allowedFileSystemRoots: [],
                threadLister: store
            )

    #expect(
        transport.requested == [
            .list(id: requestID, params: params)
        ]
    )
    #expect(store.threadListPage == page)
    #expect(
        response
            == .mcpResponse(
                hostID: "desktop-host-thread-list",
                message: .object([
                    "id": .string("real-session-list"),
                    "result": .object([
                        "data":
                            try threadListMCPJSONValue(page.data),
                        "nextCursor": .null,
                        "backwardsCursor":
                            .string("previous-page"),
                    ]),
                ]),
                metadata: [:]
            )
    )
}

private func threadListMCPRequest(
    id: CodexAppServerRequestID,
    params: CodexJSONValue?
) -> CodexDesktopMCPRequest {
    CodexDesktopMCPRequest(
        request: .init(
            id: id,
            method: "thread/list",
            params: params,
            metadata: [:]
        ),
        hostID: "desktop-host-thread-list",
        dispatchedAtMs: .integer(100),
        priority: .string("startup"),
        source: .string("renderer"),
        timeoutMs: .integer(5_000),
        expiresAtMs: .integer(5_100),
        metadata: [:]
    )
}

private func threadListMCPState() -> CodexDesktopInitialMCPState {
    CodexDesktopInitialMCPState(
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
            status: .connected,
            serverName: "Codex-for-iPad",
            installationID: "installation",
            environmentID: nil
        )
    )
}

private func threadListMCPStoredThread() -> CodexStoredThread {
    CodexStoredThread(
        id: .init("stored-thread-1"),
        sessionID: "session-1",
        preview: "Real listed thread",
        ephemeral: false,
        modelProvider: "openai",
        createdAt: 100,
        updatedAt: 200,
        recencyAt: 200,
        status: .idle,
        path: "/tmp/rollout.jsonl",
        cwd: "/workspace",
        cliVersion: "1.0.0",
        source: .named("cli"),
        name: "Listed task",
        turns: []
    )
}

private func threadListMCPJSONValue<Value: Encodable>(
    _ value: Value
) throws -> CodexJSONValue {
    try JSONDecoder().decode(
        CodexJSONValue.self,
        from: JSONEncoder().encode(value)
    )
}

private func threadListMCPError(
    id: CodexAppServerRequestID,
    code: Int64,
    message: String,
    data: CodexJSONValue? = nil
) -> CodexDesktopHostMessage {
    let responseID: CodexJSONValue
    switch id {
    case let .string(value):
        responseID = .string(value)
    case let .integer(value):
        responseID = .integer(value)
    }

    var payload: [String: CodexJSONValue] = [
        "code": .integer(code),
        "message": .string(message),
    ]
    if let data {
        payload["data"] = data
    }

    return .mcpResponse(
        hostID: "desktop-host-thread-list",
        message: .object([
            "id": responseID,
            "error": .object(payload),
        ]),
        metadata: [:]
    )
}
