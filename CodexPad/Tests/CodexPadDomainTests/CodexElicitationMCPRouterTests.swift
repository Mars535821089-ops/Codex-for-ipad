import CodexPadApplication
import CodexPadDomain
import CodexPadProtocolBridge
import Foundation
import Testing

@MainActor
private final class ElicitationCounterRecorder:
    CodexDesktopTurnSessionStarting,
    CodexDesktopElicitationCounting
{
    private(set) var calls:
        [(incrementing: Bool, id: CodexAppServerRequestID,
          threadID: CodexStoredThreadID)] = []
    var counts: [CodexStoredThreadID: Int64] = [:]

    func startDesktopTurn(
        id _: CodexAppServerRequestID,
        params _: CodexTurnStartParams
    ) throws -> CodexTurnStartResult {
        CodexTurnStartResult(
            turn: CodexStoredTurn(
                id: "ordinary-turn",
                items: [],
                status: .inProgress
            )
        )
    }

    func incrementDesktopElicitation(
        id: CodexAppServerRequestID,
        threadID: CodexStoredThreadID
    ) throws -> Int64 {
        calls.append((true, id, threadID))
        let next = (counts[threadID] ?? 0) + 1
        counts[threadID] = next
        return next
    }

    func decrementDesktopElicitation(
        id: CodexAppServerRequestID,
        threadID: CodexStoredThreadID
    ) throws -> Int64 {
        calls.append((false, id, threadID))
        guard let current = counts[threadID], current > 0 else {
            throw CodexDesktopTurnSessionRunnerError
                .elicitationCountAlreadyZero
        }
        let next = current - 1
        counts[threadID] = next
        return next
    }
}

@MainActor
private final class ElicitationRunnerTransport: CodexCoreTransport {
    let thread = CodexStoredThread(
        id: .init("persisted-thread"),
        sessionID: "session-elicitation",
        preview: "Persisted",
        ephemeral: false,
        modelProvider: "openai",
        createdAt: 100,
        updatedAt: 100,
        recencyAt: 100,
        status: .idle,
        path: "/tmp/elicitation.jsonl",
        cwd: "/workspace",
        cliVersion: "1.0",
        source: .named("cli"),
        name: "Elicitation",
        turns: []
    )
    private(set) var readCount = 0

    func submit(_ command: CodexCoreCommand) throws {}

    func request(
        _ request: CodexAppServerThreadRequest
    ) throws -> Data {
        guard case let .read(id, params) = request,
              params.threadID == thread.id,
              params.includeTurns == false
        else {
            throw CodexSessionStoreError.invalidReply
        }
        readCount += 1
        return try JSONEncoder().encode(
            CodexAppServerReply<CodexThreadReadResult>.success(
                .init(
                    id: id,
                    result: .init(thread: thread)
                )
            )
        )
    }

    func nextEvent() throws -> CodexCoreEvent? {
        nil
    }
}

@Test
@MainActor
func elicitationIncrementAndDecrementMatchOfficialWireContract()
    async
{
    let recorder = ElicitationCounterRecorder()
    let incremented = await elicitationResponse(
        method: "thread/increment_elicitation",
        recorder: recorder
    )
    let decremented = await elicitationResponse(
        method: "thread/decrement_elicitation",
        recorder: recorder
    )

    #expect(
        recorder.calls.map(\.incrementing) == [true, false]
    )
    #expect(
        recorder.calls.map(\.threadID)
            == [.init("thread-1"), .init("thread-1")]
    )
    #expect(
        recorder.calls.map(\.id)
            == [.string("elicitation-1"), .string("elicitation-1")]
    )
    #expect(
        resultObject(incremented)
            == [
                "count": .integer(1),
                "paused": .bool(true),
            ]
    )
    #expect(
        resultObject(decremented)
            == [
                "count": .integer(0),
                "paused": .bool(false),
            ]
    )
}

@Test(arguments: [
    nil,
    CodexJSONValue.null,
    .object([:]),
    .object(["threadId": .string("")]),
    .object([
        "threadId": .string("thread-1"),
        "extra": .bool(true),
    ]),
])
@MainActor
func elicitationRejectsNonOfficialParameterShapes(
    params: CodexJSONValue?
) async {
    let response = await CodexDesktopInitialMCPRouter
        .responseIncludingFileSystem(
            to: elicitationRequest(
                method: "thread/increment_elicitation",
                params: params
            ),
            state: elicitationState(),
            allowedFileSystemRoots: [],
            turnStarter: ElicitationCounterRecorder()
        )
    #expect(errorObject(response)?["code"] == .integer(-32602))
}

@Test
@MainActor
func elicitationDecrementUnderflowUsesOfficialInvalidRequest()
    async
{
    let response = await elicitationResponse(
        method: "thread/decrement_elicitation",
        recorder: ElicitationCounterRecorder()
    )
    #expect(errorObject(response)?["code"] == .integer(-32600))
    #expect(
        errorObject(response)?["message"]
            == .string(
                "out-of-band elicitation count is already zero"
            )
    )
}

@Test
@MainActor
func elicitationRunnerValidatesPersistedThreadAndRetainsCount()
    throws
{
    let transport = ElicitationRunnerTransport()
    let runner = CodexDesktopTurnSessionRunner(
        sessionStore: CodexSessionStore(transport: transport),
        providerFactory: { _ in nil },
        notificationSink: { _ in }
    )

    #expect(
        try runner.incrementDesktopElicitation(
            id: .string("increment-1"),
            threadID: transport.thread.id
        ) == 1
    )
    #expect(
        try runner.incrementDesktopElicitation(
            id: .string("increment-2"),
            threadID: transport.thread.id
        ) == 2
    )
    #expect(
        try runner.decrementDesktopElicitation(
            id: .string("decrement-1"),
            threadID: transport.thread.id
        ) == 1
    )
    #expect(
        try runner.decrementDesktopElicitation(
            id: .string("decrement-2"),
            threadID: transport.thread.id
        ) == 0
    )
    #expect(transport.readCount == 4)
    #expect(throws: CodexDesktopTurnSessionRunnerError
        .elicitationCountAlreadyZero) {
        try runner.decrementDesktopElicitation(
            id: .string("decrement-underflow"),
            threadID: transport.thread.id
        )
    }
}

private func elicitationResponse(
    method: String,
    recorder: ElicitationCounterRecorder
) async -> CodexDesktopHostMessage {
    await CodexDesktopInitialMCPRouter.responseIncludingFileSystem(
        to: elicitationRequest(
            method: method,
            params: .object([
                "threadId": .string("thread-1"),
            ])
        ),
        state: elicitationState(),
        allowedFileSystemRoots: [],
        turnStarter: recorder
    )
}

private func elicitationRequest(
    method: String,
    params: CodexJSONValue?
) -> CodexDesktopMCPRequest {
    CodexDesktopMCPRequest(
        request: CodexDesktopMCPRequestMessage(
            id: .string("elicitation-1"),
            method: method,
            params: params,
            metadata: [:]
        ),
        hostID: "desktop-host-elicitation",
        dispatchedAtMs: .integer(100),
        priority: .string("interactive"),
        source: .string("renderer"),
        timeoutMs: .integer(5_000),
        expiresAtMs: .integer(5_100),
        metadata: [:]
    )
}

private func elicitationState() -> CodexDesktopInitialMCPState {
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

private func resultObject(
    _ response: CodexDesktopHostMessage
) -> [String: CodexJSONValue]? {
    guard case let .mcpResponse(_, .object(envelope), _) =
        response,
        case let .object(result)? = envelope["result"]
    else {
        return nil
    }
    return result
}

private func errorObject(
    _ response: CodexDesktopHostMessage
) -> [String: CodexJSONValue]? {
    guard case let .mcpResponse(_, .object(envelope), _) =
        response,
        case let .object(error)? = envelope["error"]
    else {
        return nil
    }
    return error
}
