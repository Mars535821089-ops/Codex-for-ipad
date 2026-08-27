import CodexPadApplication
import CodexPadDomain
import CodexPadProtocolBridge
import Foundation
import Testing

private enum ThreadDirectoryTestTransportError: Error {
    case missingReply
}

@MainActor
private final class FakeThreadDirectoryTransport: CodexCoreTransport {
    private(set) var submitted: [CodexCoreCommand] = []
    private(set) var requested: [CodexAppServerThreadRequest] = []
    private(set) var nextEventCallCount = 0
    var queuedReplies: [Data] = []
    var queuedEvents: [CodexCoreEvent] = []

    func submit(_ command: CodexCoreCommand) throws {
        submitted.append(command)
    }

    func request(_ request: CodexAppServerThreadRequest) throws -> Data {
        requested.append(request)
        guard !queuedReplies.isEmpty else {
            throw ThreadDirectoryTestTransportError.missingReply
        }
        return queuedReplies.removeFirst()
    }

    func nextEvent() throws -> CodexCoreEvent? {
        nextEventCallCount += 1
        guard !queuedEvents.isEmpty else {
            return nil
        }
        return queuedEvents.removeFirst()
    }
}

@MainActor
@Test
func codexThreadDirectoryStoreQueriesWithoutDrainingEvents() throws {
    let thread = storedThread()
    let listPage = CodexThreadPage(
        data: [thread],
        nextCursor: "list-next",
        backwardsCursor: nil
    )
    let readResult = CodexThreadReadResult(thread: thread)
    let searchPage = CodexThreadSearchPage(
        data: [
            CodexThreadSearchHit(
                thread: thread,
                snippet: "matched preview"
            ),
        ],
        nextCursor: nil,
        backwardsCursor: "search-back"
    )
    let listID = CodexAppServerRequestID.integer(11)
    let readID = CodexAppServerRequestID.string("read-12")
    let searchID = CodexAppServerRequestID.integer(13)
    let listParams = CodexThreadListParams(limit: .value(25))
    let readParams = CodexThreadReadParams(
        threadID: thread.id,
        includeTurns: true
    )
    let searchParams = CodexThreadSearchParams(
        limit: .value(10),
        searchTerm: "preview"
    )
    let transport = FakeThreadDirectoryTransport()
    transport.queuedReplies = [
        try encodedReply(
            CodexAppServerReply<CodexThreadPage>.success(
                .init(id: listID, result: listPage)
            )
        ),
        try encodedReply(
            CodexAppServerReply<CodexThreadReadResult>.success(
                .init(id: readID, result: readResult)
            )
        ),
        try encodedReply(
            CodexAppServerReply<CodexThreadSearchPage>.success(
                .init(id: searchID, result: searchPage)
            )
        ),
    ]
    transport.queuedEvents = [
        .domain(
            .init(
                sequence: 1,
                payload: .threadMetadataChanged(threadID: thread.id)
            )
        ),
    ]
    let store = CodexSessionStore(transport: transport)

    let listed = try store.listThreads(id: listID, params: listParams)
    let read = try store.readThread(id: readID, params: readParams)
    let searched = try store.searchThreads(
        id: searchID,
        params: searchParams
    )

    #expect(listed == listPage)
    #expect(read == readResult)
    #expect(searched == searchPage)
    #expect(store.threadListPage == listPage)
    #expect(store.threadReadResult == readResult)
    #expect(store.threadSearchPage == searchPage)
    #expect(
        transport.requested == [
            .list(id: listID, params: listParams),
            .read(id: readID, params: readParams),
            .search(id: searchID, params: searchParams),
        ]
    )
    #expect(transport.nextEventCallCount == 0)
    #expect(transport.queuedEvents.count == 1)
    #expect(store.state.lastAppliedSequence == 0)
}

@MainActor
@Test
func codexThreadDirectoryStoreRejectsMismatchedAndErrorReplies() throws {
    let mismatchTransport = FakeThreadDirectoryTransport()
    let expectedID = CodexAppServerRequestID.integer(21)
    let actualID = CodexAppServerRequestID.integer(99)
    mismatchTransport.queuedReplies = [
        try encodedReply(
            CodexAppServerReply<CodexThreadPage>.success(
                .init(
                    id: actualID,
                    result: .init(
                        data: [storedThread()],
                        nextCursor: nil,
                        backwardsCursor: nil
                    )
                )
            )
        ),
    ]
    let mismatchStore = CodexSessionStore(
        transport: mismatchTransport
    )

    #expect(
        throws: CodexSessionStoreError.replyIDMismatch(
            expected: expectedID,
            actual: actualID
        )
    ) {
        try mismatchStore.listThreads(
            id: expectedID,
            params: .init()
        )
    }
    #expect(mismatchStore.threadListPage == nil)

    let errorTransport = FakeThreadDirectoryTransport()
    let errorID = CodexAppServerRequestID.string("read-error")
    let errorPayload = CodexAppServerErrorPayload(
        code: -32_602,
        message: "invalid params https://api.example.test/secret?token=redact-me",
        data: .object(["field": .string("threadId")])
    )
    errorTransport.queuedReplies = [
        try encodedReply(
            CodexAppServerReply<CodexThreadReadResult>.failure(
                .init(id: errorID, error: errorPayload)
            )
        ),
    ]
    let errorStore = CodexSessionStore(transport: errorTransport)

    #expect(
        throws: CodexSessionStoreError.appServerError(
            code: errorPayload.code,
            message: errorPayload.message,
            data: errorPayload.data
        )
    ) {
        try errorStore.readThread(
            id: errorID,
            params: .init(
                threadID: CodexStoredThreadID("missing"),
                includeTurns: nil
            )
        )
    }
    #expect(errorStore.threadReadResult == nil)
    #expect(errorStore.lastTransportProblem == "appServerError code=-32602")
    #expect(
        !(errorStore.lastTransportProblem ?? "").contains("redact-me")
    )
}

@MainActor
@Test
func codexThreadDirectoryStoreMetadataUpdateDrainsPersistedEvent() throws {
    let threadID = CodexStoredThreadID(
        "019fab26-5c01-7562-97f1-0999adf15538"
    )
    let updatedThread = storedThread(
        gitInfo: .init(
            sha: "abc123",
            branch: "main",
            originURL: nil
        )
    )
    let result = CodexThreadMetadataUpdateResult(thread: updatedThread)
    let requestID = CodexAppServerRequestID.string("metadata-31")
    let params = CodexThreadMetadataUpdateParams(
        threadID: threadID,
        gitInfo: try .init(
            sha: .set("abc123"),
            branch: .set("main"),
            originURL: .clear
        )
    )
    let metadataEvent = try CodexCoreEvent(
        data: Data(
            #"{"sequence":1,"kind":"threadMetadataChanged","threadId":"019fab26-5c01-7562-97f1-0999adf15538"}"#.utf8
        )
    )
    #expect(
        metadataEvent == .domain(
            .init(
                sequence: 1,
                payload: .threadMetadataChanged(threadID: threadID)
            )
        )
    )
    let transport = FakeThreadDirectoryTransport()
    transport.queuedReplies = [
        try encodedReply(
            CodexAppServerReply<CodexThreadMetadataUpdateResult>.success(
                .init(id: requestID, result: result)
            )
        ),
    ]
    transport.queuedEvents = [metadataEvent]
    let store = CodexSessionStore(transport: transport)

    let updated = try store.updateThreadMetadata(
        id: requestID,
        params: params
    )

    #expect(updated == result)
    #expect(store.threadMetadataUpdateResult == result)
    #expect(
        transport.requested == [
            .metadataUpdate(id: requestID, params: params),
        ]
    )
    #expect(transport.nextEventCallCount == 2)
    #expect(store.state.lastAppliedSequence == 1)
    #expect(store.lastApplyProblem == nil)
    #expect(store.lastTransportProblem == nil)
}

@MainActor
@Test
func codexThreadDirectoryStoreResumesWithoutWaitingForThreadStarted() throws {
    let thread = storedThread()
    let readID = CodexAppServerRequestID.string("read-before-resume")
    let readResult = CodexThreadReadResult(thread: thread)
    let resumeID = CodexAppServerRequestID.string("resume-success")
    let resumeParams = CodexThreadResumeParams(
        threadID: thread.id,
        model: .value("model-next")
    )
    let resumeResult = storedResumeResult(thread: thread)
    let transport = FakeThreadDirectoryTransport()
    transport.queuedReplies = [
        try encodedReply(
            CodexAppServerReply<CodexThreadReadResult>.success(
                .init(id: readID, result: readResult)
            )
        ),
        try encodedReply(
            CodexAppServerReply<CodexThreadResumeResult>.success(
                .init(id: resumeID, result: resumeResult)
            )
        ),
    ]
    transport.queuedEvents = [
        .domain(
            .init(
                sequence: 1,
                payload: .threadMetadataChanged(threadID: thread.id)
            )
        ),
    ]
    let store = CodexSessionStore(transport: transport)
    let selectedThreadID = UUID()
    store.selectedThreadID = selectedThreadID
    _ = try store.readThread(
        id: readID,
        params: .init(threadID: thread.id, includeTurns: true)
    )

    let resumed = try store.resumeThread(
        id: resumeID,
        params: resumeParams
    )

    #expect(resumed == resumeResult)
    #expect(store.threadResumeResult == resumeResult)
    #expect(store.threadResumeResult(for: thread.id) == resumeResult)
    #expect(store.threadReadResult == readResult)
    #expect(store.selectedThreadID == selectedThreadID)
    #expect(
        transport.requested == [
            .read(
                id: readID,
                params: .init(threadID: thread.id, includeTurns: true)
            ),
            .resume(id: resumeID, params: resumeParams),
        ]
    )
    #expect(transport.nextEventCallCount == 0)
    #expect(transport.queuedEvents.count == 1)
    #expect(store.state.lastAppliedSequence == 0)
}

@MainActor
@Test
func codexThreadDirectoryStoreRetainsResumeRuntimeForEveryThread() throws {
    let firstThread = storedThread()
    let secondThread = CodexStoredThread(
        id: .init("019fab26-5c01-7562-97f1-0999adf15539"),
        sessionID: "session-2",
        forkedFromID: nil,
        parentThreadID: nil,
        preview: "second preview",
        ephemeral: false,
        modelProvider: "openai",
        createdAt: 300,
        updatedAt: 400,
        recencyAt: 400,
        status: .idle,
        path: "/tmp/second-rollout.jsonl",
        cwd: "/workspace/second",
        cliVersion: "1.0.0",
        source: .named("cli"),
        threadSource: nil,
        agentNickname: nil,
        agentRole: nil,
        gitInfo: nil,
        name: "Second task",
        turns: []
    )
    let firstResult = storedResumeResult(thread: firstThread)
    let secondResult = CodexThreadResumeResult(
        thread: secondThread,
        model: "model-second",
        modelProvider: "provider-second",
        serviceTier: "priority",
        cwd: "/workspace/second",
        runtimeWorkspaceRoots: ["/workspace/second"],
        dynamicTools: [
            .object([
                "type": .string("function"),
                "name": .string("lookup_second"),
                "description": .string("Look up second"),
                "inputSchema": .object(["type": .string("object")]),
            ]),
        ],
        selectedCapabilityRoots: [
            .object(["id": .string("second@openai")]),
        ],
        instructionSources: [],
        approvalPolicy: .never,
        approvalsReviewer: .user,
        sandbox: .dangerFullAccess,
        reasoningEffort: "high"
    )
    let firstID = CodexAppServerRequestID.string("resume-first-runtime")
    let secondID = CodexAppServerRequestID.string("resume-second-runtime")
    let transport = FakeThreadDirectoryTransport()
    transport.queuedReplies = [
        try encodedReply(
            CodexAppServerReply<CodexThreadResumeResult>.success(
                .init(id: firstID, result: firstResult)
            )
        ),
        try encodedReply(
            CodexAppServerReply<CodexThreadResumeResult>.success(
                .init(id: secondID, result: secondResult)
            )
        ),
    ]
    let store = CodexSessionStore(transport: transport)

    _ = try store.resumeThread(
        id: firstID,
        params: .init(threadID: firstThread.id)
    )
    _ = try store.resumeThread(
        id: secondID,
        params: .init(threadID: secondThread.id)
    )

    #expect(store.threadResumeResult == secondResult)
    #expect(store.threadResumeResult(for: firstThread.id) == firstResult)
    #expect(store.threadResumeResult(for: secondThread.id) == secondResult)
}

@MainActor
@Test
func failedResumePreservesPreviousResumeReadAndSelectionState() throws {
    let originalThread = storedThread()
    let readID = CodexAppServerRequestID.string("read-before-failures")
    let readResult = CodexThreadReadResult(thread: originalThread)
    let originalResult = storedResumeResult(thread: originalThread)
    let firstID = CodexAppServerRequestID.string("resume-first")
    let replyMismatchRequestID =
        CodexAppServerRequestID.string("resume-reply-request")
    let replyMismatchActualID =
        CodexAppServerRequestID.string("resume-reply-actual")
    let threadMismatchID =
        CodexAppServerRequestID.string("resume-thread-mismatch")
    let requestedThreadID = originalThread.id
    let mismatchedThread = CodexStoredThread(
        id: .init("thread-id-with-different-bytes"),
        sessionID: originalThread.sessionID,
        preview: originalThread.preview,
        ephemeral: originalThread.ephemeral,
        modelProvider: originalThread.modelProvider,
        createdAt: originalThread.createdAt,
        updatedAt: originalThread.updatedAt,
        status: originalThread.status,
        cwd: originalThread.cwd,
        cliVersion: originalThread.cliVersion,
        source: originalThread.source,
        turns: originalThread.turns
    )
    let transport = FakeThreadDirectoryTransport()
    transport.queuedReplies = [
        try encodedReply(
            CodexAppServerReply<CodexThreadReadResult>.success(
                .init(id: readID, result: readResult)
            )
        ),
        try encodedReply(
            CodexAppServerReply<CodexThreadResumeResult>.success(
                .init(id: firstID, result: originalResult)
            )
        ),
        try encodedReply(
            CodexAppServerReply<CodexThreadResumeResult>.success(
                .init(id: replyMismatchActualID, result: originalResult)
            )
        ),
        try encodedReply(
            CodexAppServerReply<CodexThreadResumeResult>.success(
                .init(
                    id: threadMismatchID,
                    result: storedResumeResult(thread: mismatchedThread)
                )
            )
        ),
    ]
    let store = CodexSessionStore(transport: transport)
    let selectedThreadID = UUID()
    store.selectedThreadID = selectedThreadID
    _ = try store.readThread(
        id: readID,
        params: .init(threadID: requestedThreadID, includeTurns: true)
    )
    _ = try store.resumeThread(
        id: firstID,
        params: .init(threadID: requestedThreadID)
    )

    #expect(
        throws: CodexSessionStoreError.replyIDMismatch(
            expected: replyMismatchRequestID,
            actual: replyMismatchActualID
        )
    ) {
        try store.resumeThread(
            id: replyMismatchRequestID,
            params: .init(threadID: requestedThreadID)
        )
    }
    #expect(
        throws: CodexSessionStoreError.resumedThreadIDMismatch(
            expected: requestedThreadID,
            actual: mismatchedThread.id
        )
    ) {
        try store.resumeThread(
            id: threadMismatchID,
            params: .init(threadID: requestedThreadID)
        )
    }
    #expect(store.threadResumeResult == originalResult)
    #expect(store.threadReadResult == readResult)
    #expect(store.selectedThreadID == selectedThreadID)
    #expect(
        transport.requested == [
            .read(
                id: readID,
                params: .init(
                    threadID: requestedThreadID,
                    includeTurns: true
                )
            ),
            .resume(
                id: firstID,
                params: .init(threadID: requestedThreadID)
            ),
            .resume(
                id: replyMismatchRequestID,
                params: .init(threadID: requestedThreadID)
            ),
            .resume(
                id: threadMismatchID,
                params: .init(threadID: requestedThreadID)
            ),
        ]
    )
    #expect(store.lastTransportProblem != nil)
}

@MainActor
@Test
func formalThreadSettingsUpdateMatchesReplyAndAppliesFullNotification() throws {
    let rawThreadID = CodexStoredThreadID("Thread/Raw/Ω")
    let requestID = CodexAppServerRequestID.string("settings-store-1")
    let params = CodexThreadSettingsUpdateParams(
        threadID: rawThreadID,
        model: .value("model-updated"),
        serviceTier: .null,
        effort: .value("ultra"),
        personality: .value(.friendly)
    )
    let notification = try CodexCoreEvent(
        data: Data(
            #"""
            {
              "method":"thread/settings/updated",
              "params":{
                "threadId":"Thread/Raw/Ω",
                "threadSettings":{
                  "cwd":"/updated/cwd",
                  "approvalPolicy":"never",
                  "approvalsReviewer":"guardian_subagent",
                  "sandboxPolicy":{"type":"readOnly"},
                  "activePermissionProfile":null,
                  "model":"model-updated",
                  "modelProvider":"provider-updated",
                  "serviceTier":null,
                  "effort":"ultra",
                  "summary":"concise",
                  "collaborationMode":{
                    "mode":"default",
                    "settings":{
                      "model":"model-updated",
                      "reasoning_effort":"ultra",
                      "developer_instructions":null
                    }
                  },
                  "multiAgentMode":"explicitRequestOnly",
                  "personality":"friendly"
                }
              }
            }
            """#.utf8
        )
    )
    let transport = FakeThreadDirectoryTransport()
    transport.queuedReplies = [
        try encodedReply(
            CodexAppServerReply<CodexThreadSettingsUpdateResponse>.success(
                .init(
                    id: requestID,
                    result: CodexThreadSettingsUpdateResponse()
                )
            )
        ),
    ]
    transport.queuedEvents = [notification]
    let store = CodexSessionStore(transport: transport)

    let response = try store.updateThreadSettings(
        id: requestID,
        params: params
    )
    let settings = try #require(
        store.threadSettings(for: rawThreadID)
    )

    #expect(response == CodexThreadSettingsUpdateResponse())
    #expect(
        transport.requested == [
            .settingsUpdate(id: requestID, params: params),
        ]
    )
    #expect(transport.nextEventCallCount == 2)
    #expect(settings.model == "model-updated")
    #expect(settings.modelProvider == "provider-updated")
    #expect(settings.serviceTier == nil)
    #expect(settings.effort == "ultra")
    #expect(settings.summary == .concise)
    #expect(settings.personality == .friendly)
    #expect(
        settings.sandboxPolicy == .readOnly(networkAccess: false)
    )
    #expect(store.lastTransportProblem == nil)
}

@MainActor
@Test
func formalThreadSettingsUpdateRejectsMismatchedReplyBeforeNotification() throws {
    let expectedID = CodexAppServerRequestID.integer(81)
    let actualID = CodexAppServerRequestID.integer(82)
    let rawThreadID = CodexStoredThreadID("Thread-Mismatch")
    let transport = FakeThreadDirectoryTransport()
    transport.queuedReplies = [
        try encodedReply(
            CodexAppServerReply<CodexThreadSettingsUpdateResponse>.success(
                .init(
                    id: actualID,
                    result: CodexThreadSettingsUpdateResponse()
                )
            )
        ),
    ]
    let store = CodexSessionStore(transport: transport)

    #expect(
        throws: CodexSessionStoreError.replyIDMismatch(
            expected: expectedID,
            actual: actualID
        )
    ) {
        try store.updateThreadSettings(
            id: expectedID,
            params: .init(
                threadID: rawThreadID,
                model: .value("model")
            )
        )
    }
    #expect(store.threadSettings(for: rawThreadID) == nil)
    #expect(transport.nextEventCallCount == 0)
}

@MainActor
@Test
func threadMemoryModeSetUsesTransportAndDrainsPersistedMutation() throws {
    let requestID = CodexAppServerRequestID.string("memory-mode-1")
    let params = CodexThreadMemoryModeSetParams(
        threadID: CodexStoredThreadID("Thread/Raw/Ω"),
        mode: .disabled
    )
    let transport = FakeThreadDirectoryTransport()
    transport.queuedReplies = [
        try encodedReply(
            CodexAppServerReply<CodexThreadEmptyResponse>.success(
                .init(
                    id: requestID,
                    result: CodexThreadEmptyResponse()
                )
            )
        ),
    ]
    transport.queuedEvents = [
        .threadMemoryModeUpdated(
            sequence: 1,
            threadID: params.threadID,
            mode: params.mode
        ),
    ]
    let store = CodexSessionStore(transport: transport)

    try store.setThreadMemoryMode(id: requestID, params: params)

    #expect(
        transport.requested == [
            .memoryModeSet(id: requestID, params: params),
        ]
    )
    #expect(transport.nextEventCallCount == 2)
    #expect(transport.queuedEvents.isEmpty)
    #expect(store.state.lastAppliedSequence == 1)
    #expect(store.lastApplyProblem == nil)
    #expect(store.lastTransportProblem == nil)
}

private func encodedReply<Result>(
    _ reply: CodexAppServerReply<Result>
) throws -> Data
where Result: Codable & Equatable & Sendable {
    try JSONEncoder().encode(reply)
}

private func storedResumeResult(
    thread: CodexStoredThread
) -> CodexThreadResumeResult {
    CodexThreadResumeResult(
        thread: thread,
        model: "model-next",
        modelProvider: "provider-next",
        serviceTier: nil,
        cwd: "/workspace",
        instructionSources: ["/workspace/AGENTS.md"],
        approvalPolicy: .onRequest,
        approvalsReviewer: .user,
        sandbox: .readOnly(networkAccess: false),
        reasoningEffort: "future-effort"
    )
}

private func storedThread(
    gitInfo: CodexThreadGitInfo? = nil
) -> CodexStoredThread {
    CodexStoredThread(
        id: .init("019fab26-5c01-7562-97f1-0999adf15538"),
        sessionID: "session-1",
        forkedFromID: nil,
        parentThreadID: nil,
        preview: "matched preview",
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
        threadSource: nil,
        agentNickname: nil,
        agentRole: nil,
        gitInfo: gitInfo,
        name: "Stored task",
        turns: []
    )
}
