import CodexPadApplication
import CodexPadDomain
import CodexPadProtocolBridge
import Foundation
import Testing

@MainActor
private final class ConversationSummaryThreadStore:
    CodexDesktopThreadSessionListing,
    CodexDesktopThreadSessionReading
{
    var pages: [CodexThreadPage] = []
    var readResult: CodexThreadReadResult?
    private(set) var listParams: [CodexThreadListParams] = []
    private(set) var readParams: CodexThreadReadParams?

    func listThreads(
        id _: CodexAppServerRequestID,
        params: CodexThreadListParams
    ) throws -> CodexThreadPage {
        listParams.append(params)
        guard !pages.isEmpty else {
            throw CodexSessionStoreError.invalidReply
        }
        return pages.removeFirst()
    }

    func readThread(
        id _: CodexAppServerRequestID,
        params: CodexThreadReadParams
    ) throws -> CodexThreadReadResult {
        readParams = params
        guard let readResult else {
            throw CodexSessionStoreError.invalidReply
        }
        return readResult
    }
}

@Test
@MainActor
func conversationSummaryReadsThreadIDAndMatchesLegacyWireShape()
    async
{
    let store = ConversationSummaryThreadStore()
    let thread = conversationSummaryThread(
        source: .subAgent(
            .threadSpawn(
                parentThreadID: .init("parent-thread"),
                depth: 2,
                agentPath: "/root/reviewer",
                agentNickname: nil,
                agentRole: nil,
                model: "gpt-5.6"
            )
        ),
        agentNickname: "Reviewer",
        agentRole: "code-reviewer"
    )
    store.readResult = .init(thread: thread)

    let response = await CodexDesktopInitialMCPRouter
        .responseIncludingFileSystem(
            to: conversationSummaryRequest(
                id: .integer(701),
                params: .object([
                    "conversationId": .string(
                        thread.id.rawValue
                    ),
                ])
            ),
            state: conversationSummaryState(),
            allowedFileSystemRoots: [],
            threadLister: store
        )

    #expect(
        store.readParams
            == .init(threadID: thread.id, includeTurns: false)
    )
    #expect(store.listParams.isEmpty)
    guard case let .mcpResponse(_, .object(envelope), _) =
        response,
        case let .object(result)? = envelope["result"],
        case let .object(summary)? = result["summary"],
        case let .object(source)? = summary["source"],
        case let .object(subAgent)? = source["subAgent"],
        case let .object(spawn)? = subAgent["thread_spawn"],
        case let .object(gitInfo)? = summary["gitInfo"]
    else {
        Issue.record("conversation summary response shape mismatch")
        return
    }
    #expect(envelope["id"] == .integer(701))
    #expect(
        summary["conversationId"]
            == .string(thread.id.rawValue)
    )
    #expect(summary["path"] == .string("/tmp/thread.jsonl"))
    #expect(summary["preview"] == .string("Review this patch"))
    #expect(
        summary["timestamp"]
            == .string("2025-01-02T12:00:00.000Z")
    )
    #expect(
        summary["updatedAt"]
            == .string("2025-01-02T12:01:00.000Z")
    )
    #expect(summary["modelProvider"] == .string("openai"))
    #expect(summary["cwd"] == .string("/workspace/project"))
    #expect(summary["cliVersion"] == .string("0.146.0"))
    #expect(spawn["agent_nickname"] == .string("Reviewer"))
    #expect(
        spawn["agent_role"] == .string("code-reviewer")
    )
    #expect(gitInfo["sha"] == .string("abc123"))
    #expect(gitInfo["branch"] == .string("main"))
    #expect(
        gitInfo["origin_url"]
            == .string("https://example.invalid/repo.git")
    )
}

@Test
@MainActor
func conversationSummaryFindsArchivedRolloutAcrossPages()
    async
{
    let store = ConversationSummaryThreadStore()
    let target = conversationSummaryThread()
    store.pages = [
        .init(
            data: [
                conversationSummaryThread(
                    id: .init("other-thread"),
                    path: "/tmp/other.jsonl"
                ),
            ],
            nextCursor: "page-2",
            backwardsCursor: nil
        ),
        .init(
            data: [],
            nextCursor: nil,
            backwardsCursor: nil
        ),
        .init(
            data: [target],
            nextCursor: nil,
            backwardsCursor: nil
        ),
    ]

    let response = await CodexDesktopInitialMCPRouter
        .responseIncludingFileSystem(
            to: conversationSummaryRequest(
                id: .string("summary-by-path"),
                params: .object([
                    "rolloutPath": .string(
                        "/tmp/./thread.jsonl"
                    ),
                ])
            ),
            state: conversationSummaryState(),
            allowedFileSystemRoots: [],
            threadLister: store
        )

    #expect(store.listParams.count == 3)
    #expect(store.listParams[0].archived == .value(false))
    #expect(store.listParams[1].cursor == .value("page-2"))
    #expect(store.listParams[2].archived == .value(true))
    #expect(store.listParams.allSatisfy { $0.useStateDbOnly == true })
    guard case let .mcpResponse(_, .object(envelope), _) =
        response,
        case let .object(result)? = envelope["result"],
        case let .object(summary)? = result["summary"]
    else {
        Issue.record("rollout summary response shape mismatch")
        return
    }
    #expect(envelope["id"] == .string("summary-by-path"))
    #expect(
        summary["conversationId"]
            == .string(target.id.rawValue)
    )
}

@Test
@MainActor
func conversationSummaryRejectsAmbiguousOrMissingLookup()
    async
{
    let store = ConversationSummaryThreadStore()
    for params: CodexJSONValue in [
        .object([:]),
        .object([
            "conversationId": .string("thread"),
            "rolloutPath": .string("/tmp/thread.jsonl"),
        ]),
        .object(["conversationId": .string("")]),
    ] {
        let response = await CodexDesktopInitialMCPRouter
            .responseIncludingFileSystem(
                to: conversationSummaryRequest(
                    id: .integer(702),
                    params: params
                ),
                state: conversationSummaryState(),
                allowedFileSystemRoots: [],
                threadLister: store
            )
        #expect(conversationSummaryErrorCode(response) == -32602)
    }
}

private func conversationSummaryThread(
    id: CodexStoredThreadID = .init(
        "019fab26-5c01-7562-97f1-0999adf15538"
    ),
    path: String = "/tmp/thread.jsonl",
    source: CodexThreadSessionSource = .named(.cli),
    agentNickname: String? = nil,
    agentRole: String? = nil
) -> CodexStoredThread {
    CodexStoredThread(
        id: id,
        sessionID: id.rawValue,
        preview: "Review this patch",
        ephemeral: false,
        modelProvider: "openai",
        createdAt: 1_735_819_200,
        updatedAt: 1_735_819_260,
        status: .idle,
        path: path,
        cwd: "/workspace/project",
        cliVersion: "0.146.0",
        source: source,
        agentNickname: agentNickname,
        agentRole: agentRole,
        gitInfo: .init(
            sha: "abc123",
            branch: "main",
            originURL: "https://example.invalid/repo.git"
        ),
        turns: []
    )
}

private func conversationSummaryRequest(
    id: CodexAppServerRequestID,
    params: CodexJSONValue
) -> CodexDesktopMCPRequest {
    CodexDesktopMCPRequest(
        request: CodexDesktopMCPRequestMessage(
            id: id,
            method: "getConversationSummary",
            params: params,
            metadata: [:]
        ),
        hostID: "desktop-host-summary",
        dispatchedAtMs: .integer(100),
        priority: .string("startup"),
        source: .string("renderer"),
        timeoutMs: .integer(5_000),
        expiresAtMs: .integer(5_100),
        metadata: [:]
    )
}

private func conversationSummaryState()
    -> CodexDesktopInitialMCPState
{
    .init(
        account: .init(
            account: nil,
            authMethod: nil,
            requiresOpenAIAuth: true
        ),
        config: .init(config: [:], origins: [:], layers: []),
        remoteControl: .init(
            status: .disabled,
            serverName: "Codex for ipad",
            installationID: "installation",
            environmentID: nil
        )
    )
}

private func conversationSummaryErrorCode(
    _ response: CodexDesktopHostMessage
) -> Int64? {
    guard case let .mcpResponse(_, .object(envelope), _) =
        response,
        case let .object(error)? = envelope["error"],
        case let .integer(code)? = error["code"]
    else {
        return nil
    }
    return code
}
