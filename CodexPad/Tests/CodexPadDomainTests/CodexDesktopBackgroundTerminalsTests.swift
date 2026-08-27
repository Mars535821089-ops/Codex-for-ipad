import Foundation
import Testing

@testable import CodexPadApplication
@testable import CodexPadDomain
@testable import CodexPadProtocolBridge

@Test
@MainActor
func desktopBackgroundTerminalsMatchOfficialListTerminateAndCleanContracts()
    async throws
{
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "codex-background-terminals-\(UUID().uuidString)",
        isDirectory: true
    )
    try FileManager.default.createDirectory(
        at: root,
        withIntermediateDirectories: true
    )
    defer {
        try? FileManager.default.removeItem(at: root)
    }

    let executor = CodexDesktopWorkspaceCommandExecutor()
    let processIDs: [String] = ["4", "1", "3"]
    let tasks = processIDs.map { processID in
        Task { @MainActor in
            try await executor.execute(
                CodexDesktopCommandExecParams(
                    command: ["cat"],
                    processID: processID,
                    tty: false,
                    streamStdin: true,
                    streamStdoutStderr: false,
                    outputBytesCap: nil,
                    disableOutputCap: true,
                    disableTimeout: true,
                    timeoutMs: nil,
                    cwd: root.path,
                    environment: nil,
                    size: nil,
                    sandboxPolicy: nil,
                    backgroundTerminal:
                        CodexDesktopBackgroundCommandMetadata(
                            threadID: "thread-alpha",
                            itemID: "item-\(processID)",
                            command: "long-running-\(processID)"
                        )
                ),
                allowedRoots: [root.path]
            )
        }
    }

    let initialPage = try await waitForBackgroundTerminalCount(
        3,
        executor: executor,
        root: root,
        threadID: "thread-alpha"
    )
    #expect(initialPage == backgroundTerminalResponse(
        id: .integer(1),
        terminals: [
            backgroundTerminal(
                processID: "1",
                cwd: root.path
            ),
            backgroundTerminal(
                processID: "3",
                cwd: root.path
            ),
            backgroundTerminal(
                processID: "4",
                cwd: root.path
            ),
        ],
        nextCursor: nil
    ))

    let firstPage = await backgroundTerminalRequest(
        id: .integer(2),
        method: "thread/backgroundTerminals/list",
        params: .object([
            "threadId": .string("thread-alpha"),
            "limit": .integer(2),
        ]),
        executor: executor,
        root: root
    )
    #expect(firstPage == backgroundTerminalResponse(
        id: .integer(2),
        terminals: [
            backgroundTerminal(processID: "1", cwd: root.path),
            backgroundTerminal(processID: "3", cwd: root.path),
        ],
        nextCursor: "3"
    ))

    let anchoredPage = await backgroundTerminalRequest(
        id: .integer(3),
        method: "thread/backgroundTerminals/list",
        params: .object([
            "threadId": .string("thread-alpha"),
            "cursor": .string("2"),
            "limit": .integer(0),
        ]),
        executor: executor,
        root: root
    )
    #expect(anchoredPage == backgroundTerminalResponse(
        id: .integer(3),
        terminals: [
            backgroundTerminal(processID: "3", cwd: root.path)
        ],
        nextCursor: "3"
    ))

    let invalidCursor = await backgroundTerminalRequest(
        id: .integer(4),
        method: "thread/backgroundTerminals/list",
        params: .object([
            "threadId": .string("thread-alpha"),
            "cursor": .string("not-a-process-id"),
        ]),
        executor: executor,
        root: root
    )
    #expect(invalidCursor == backgroundTerminalError(
        id: .integer(4),
        code: -32602,
        message:
            "Invalid params for thread/backgroundTerminals/list"
    ))

    let terminated = await backgroundTerminalRequest(
        id: .integer(5),
        method: "thread/backgroundTerminals/terminate",
        params: .object([
            "threadId": .string("thread-alpha"),
            "processId": .string("3"),
        ]),
        executor: executor,
        root: root
    )
    #expect(terminated == backgroundTerminalBooleanResponse(
        id: .integer(5),
        key: "terminated",
        value: true
    ))

    let alreadyTerminated = await backgroundTerminalRequest(
        id: .integer(6),
        method: "thread/backgroundTerminals/terminate",
        params: .object([
            "threadId": .string("thread-alpha"),
            "processId": .string("3"),
        ]),
        executor: executor,
        root: root
    )
    #expect(alreadyTerminated == backgroundTerminalBooleanResponse(
        id: .integer(6),
        key: "terminated",
        value: false
    ))

    let invalidProcessID = await backgroundTerminalRequest(
        id: .integer(7),
        method: "thread/backgroundTerminals/terminate",
        params: .object([
            "threadId": .string("thread-alpha"),
            "processId": .string("bad"),
        ]),
        executor: executor,
        root: root
    )
    #expect(invalidProcessID == backgroundTerminalError(
        id: .integer(7),
        code: -32602,
        message:
            "Invalid params for thread/backgroundTerminals/terminate"
    ))

    let cleaned = await backgroundTerminalRequest(
        id: .integer(8),
        method: "thread/backgroundTerminals/clean",
        params: .object([
            "threadId": .string("thread-alpha")
        ]),
        executor: executor,
        root: root
    )
    #expect(cleaned == backgroundTerminalObjectResponse(
        id: .integer(8),
        value: [:]
    ))

    let emptyPage = await backgroundTerminalRequest(
        id: .integer(9),
        method: "thread/backgroundTerminals/list",
        params: .object([
            "threadId": .string("thread-alpha")
        ]),
        executor: executor,
        root: root
    )
    #expect(emptyPage == backgroundTerminalResponse(
        id: .integer(9),
        terminals: [],
        nextCursor: nil
    ))

    for task in tasks {
        _ = try? await task.value
    }
}

@Test
@MainActor
func persistedTurnUnifiedExecCreatesAndContinuesARealBackgroundTerminal()
    async throws
{
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "codex-unified-exec-\(UUID().uuidString)",
        isDirectory: true
    )
    try FileManager.default.createDirectory(
        at: root,
        withIntermediateDirectories: true
    )
    defer {
        try? FileManager.default.removeItem(at: root)
    }
    let workspace = Workspace(
        id: UUID(),
        displayName: "Unified exec workspace",
        rootBookmarkID: "bookmark/unified-exec"
    )
    let commandExecutor = CodexDesktopWorkspaceCommandExecutor()
    var commandDeltas:
        [CodexCommandExecutionOutputDeltaNotification] = []
    commandExecutor.configureUnifiedOutputSink {
        commandDeltas.append($0)
    }
    var terminalInteractions:
        [CodexTerminalInteractionNotification] = []
    commandExecutor.configureUnifiedTerminalInteractionSink {
        terminalInteractions.append($0)
    }
    let toolExecutor = CodexPersistedTurnWorkspaceToolExecutor(
        policy: CodexExecutionPolicy(
            approvalPolicy: .never,
            sandboxMode: .workspaceWrite
        ),
        expectedWorkspacePath: root.path,
        workspace: workspace,
        runner: CodexWorkspaceToolRunner(),
        commandExecutor: commandExecutor,
        resolveBookmark: { bookmark in
            #expect(bookmark == "bookmark/unified-exec")
            return root
        },
        approval: { _ in true }
    )
    let cancellation = CodexTurnCancellation()
    let threadID = CodexStoredThreadID(rawValue: "thread-unified")

    let launch = try await toolExecutor.execute(
        CodexPersistedTurnToolRequest(
            threadID: threadID,
            turnID: "turn-unified",
            roundIndex: 0,
            name: "exec_command",
            arguments:
                #"{"cmd":"cat","tty":true,"yield_time_ms":250}"#,
            callID: "call-unified",
            itemJSON:
                #"{"type":"function_call","name":"exec_command","arguments":"{}","call_id":"call-unified"}"#
        ),
        cancellation: cancellation
    )
    let launchText = try unifiedExecToolOutput(launch.itemJSON)
    #expect(launchText.contains("Chunk ID: "))
    #expect(
        launchText.contains("Process running with session ID 1")
    )

    let listed = await backgroundTerminalRequest(
        id: .integer(20),
        method: "thread/backgroundTerminals/list",
        params: .object([
            "threadId": .string(threadID.rawValue)
        ]),
        executor: commandExecutor,
        root: root
    )
    #expect(listed == backgroundTerminalResponse(
        id: .integer(20),
        terminals: [
            .object([
                "itemId": .string("call-unified"),
                "processId": .string("1"),
                "command": .string("cat"),
                "cwd": .string(root.path),
                "osPid": .null,
                "cpuPercent": .null,
                "rssKb": .null,
            ])
        ],
        nextCursor: nil
    ))

    let firstWrite = try await toolExecutor.execute(
        CodexPersistedTurnToolRequest(
            threadID: threadID,
            turnID: "turn-unified",
            roundIndex: 1,
            name: "write_stdin",
            arguments:
                #"{"session_id":1,"chars":"first\n","yield_time_ms":250}"#,
            callID: "call-write-first",
            itemJSON:
                #"{"type":"function_call","name":"write_stdin","arguments":"{}","call_id":"call-write-first"}"#
        ),
        cancellation: cancellation
    )
    let firstWriteText = try unifiedExecToolOutput(firstWrite.itemJSON)
    #expect(
        firstWriteText.contains("Process running with session ID 1")
    )
    #expect(firstWriteText.contains("first\n"))
    #expect(
        terminalInteractions.contains(
            CodexTerminalInteractionNotification(
                threadID: threadID,
                turnID: "turn-unified",
                itemID: "call-unified",
                processID: "1",
                stdin: "first\n"
            )
        )
    )

    let finish = try await toolExecutor.execute(
        CodexPersistedTurnToolRequest(
            threadID: threadID,
            turnID: "turn-unified",
            roundIndex: 2,
            name: "write_stdin",
            arguments:
                #"{"session_id":1,"chars":"second\n\u0004","yield_time_ms":250}"#,
            callID: "call-write",
            itemJSON:
                #"{"type":"function_call","name":"write_stdin","arguments":"{}","call_id":"call-write"}"#
        ),
        cancellation: cancellation
    )
    let finishText = try unifiedExecToolOutput(finish.itemJSON)
    #expect(finishText.contains("Chunk ID: "))
    #expect(finishText.contains("Process exited with code 0"))
    #expect(finishText.contains("second\n"))
    #expect(!finishText.contains("first\n"))

    let bounded = try await toolExecutor.execute(
        CodexPersistedTurnToolRequest(
            threadID: threadID,
            turnID: "turn-unified",
            roundIndex: 3,
            name: "exec_command",
            arguments:
                #"{"cmd":"printf this-is-a-long-output-that-must-be-truncated","max_output_tokens":5,"yield_time_ms":250}"#,
            callID: "call-bounded",
            itemJSON:
                #"{"type":"function_call","name":"exec_command","arguments":"{}","call_id":"call-bounded"}"#
        ),
        cancellation: cancellation
    )
    let boundedText = try unifiedExecToolOutput(bounded.itemJSON)
    #expect(
        boundedText.contains(
            "Warning: truncated output (original token count:"
        )
    )
    #expect(boundedText.contains("tokens truncated"))
    #expect(
        commandDeltas.contains(
            CodexCommandExecutionOutputDeltaNotification(
                threadID: threadID,
                turnID: "turn-unified",
                itemID: "call-bounded",
                delta:
                    "this-is-a-long-output-that-must-be-truncated"
            )
        )
    )

    let empty = await backgroundTerminalRequest(
        id: .integer(21),
        method: "thread/backgroundTerminals/list",
        params: .object([
            "threadId": .string(threadID.rawValue)
        ]),
        executor: commandExecutor,
        root: root
    )
    #expect(empty == backgroundTerminalResponse(
        id: .integer(21),
        terminals: [],
        nextCursor: nil
    ))
}

@Test
func desktopUnifiedExecResponseMatchesOfficialSectionsAndTokenTruncation() {
    let complete = CodexDesktopUnifiedExecOutput(
        chunkID: "abc123",
        wallTimeSeconds: 0.125,
        processID: nil,
        exitCode: 0,
        originalTokenCount: 42,
        output: "complete output",
        maxOutputTokens: nil
    )
    #expect(
        complete.responseText
            == """
            Chunk ID: abc123
            Wall time: 0.1250 seconds
            Process exited with code 0
            Original token count: 42
            Output:
            complete output
            """
    )

    let truncated = CodexDesktopUnifiedExecOutput(
        chunkID: "fed456",
        wallTimeSeconds: 1,
        processID: "7",
        exitCode: nil,
        originalTokenCount: nil,
        output:
            "this is an example of a long output that should be truncated",
        maxOutputTokens: 5
    )
    #expect(
        truncated.responseText
            == """
            Chunk ID: fed456
            Wall time: 1.0000 seconds
            Process running with session ID 7
            Output:
            Warning: truncated output (original token count: 15)
            Total output lines: 1

            this is an…10 tokens truncated… truncated
            """
    )
}

@Test
func desktopUnifiedExecTimingMatchesOfficialInitialWriteAndPollBounds() {
    #expect(
        CodexDesktopUnifiedExecTiming.initialYield(0)
            == 250
    )
    #expect(
        CodexDesktopUnifiedExecTiming.initialYield(300_001)
            == 30_000
    )
    #expect(
        CodexDesktopUnifiedExecTiming.stdinWriteYield(0)
            == 250
    )
    #expect(
        CodexDesktopUnifiedExecTiming.stdinWriteYield(300_001)
            == 30_000
    )
    #expect(
        CodexDesktopUnifiedExecTiming.backgroundPollYield(0)
            == 5_000
    )
    #expect(
        CodexDesktopUnifiedExecTiming.backgroundPollYield(300_001)
            == 300_000
    )
}

private func unifiedExecToolOutput(
    _ itemJSON: String
) throws -> String {
    let object = try #require(
        JSONSerialization.jsonObject(
            with: Data(itemJSON.utf8)
        ) as? [String: Any]
    )
    return try #require(object["output"] as? String)
}

@MainActor
private func waitForBackgroundTerminalCount(
    _ count: Int,
    executor: CodexDesktopWorkspaceCommandExecutor,
    root: URL,
    threadID: String
) async throws -> CodexDesktopHostMessage {
    for _ in 0..<50 {
        let response = await backgroundTerminalRequest(
            id: .integer(1),
            method: "thread/backgroundTerminals/list",
            params: .object([
                "threadId": .string(threadID)
            ]),
            executor: executor,
            root: root
        )
        if backgroundTerminalCount(response) == count {
            return response
        }
        await Task.yield()
    }
    Issue.record("background terminal sessions did not register")
    return await backgroundTerminalRequest(
        id: .integer(1),
        method: "thread/backgroundTerminals/list",
        params: .object([
            "threadId": .string(threadID)
        ]),
        executor: executor,
        root: root
    )
}

private func backgroundTerminalCount(
    _ response: CodexDesktopHostMessage
) -> Int? {
    guard case let .mcpResponse(_, message, _) = response,
          case let .object(envelope) = message,
          case let .object(result)? = envelope["result"],
          case let .array(data)? = result["data"]
    else {
        return nil
    }
    return data.count
}

@MainActor
private func backgroundTerminalRequest(
    id: CodexAppServerRequestID,
    method: String,
    params: CodexJSONValue,
    executor: CodexDesktopWorkspaceCommandExecutor,
    root: URL
) async -> CodexDesktopHostMessage {
    await CodexDesktopInitialMCPRouter.responseIncludingFileSystem(
        to: CodexDesktopMCPRequest(
            request: CodexDesktopMCPRequestMessage(
                id: id,
                method: method,
                params: params,
                metadata: [:]
            ),
            hostID: "desktop-host-1",
            dispatchedAtMs: nil,
            priority: nil,
            source: nil,
            timeoutMs: nil,
            expiresAtMs: nil,
            metadata: [:]
        ),
        state: CodexDesktopInitialMCPState(
            account: .init(
                account: nil,
                authMethod: nil,
                requiresOpenAIAuth: true
            ),
            config: .init(config: [:], origins: [:], layers: []),
            remoteControl: .init(
                status: .disabled,
                serverName: "Codex-for-iPad",
                installationID: "installation-1",
                environmentID: nil
            )
        ),
        allowedFileSystemRoots: [root.path],
        commandExecutor: executor
    )
}

private func backgroundTerminal(
    processID: String,
    cwd: String
) -> CodexJSONValue {
    .object([
        "itemId": .string("item-\(processID)"),
        "processId": .string(processID),
        "command": .string("long-running-\(processID)"),
        "cwd": .string(cwd),
        "osPid": .null,
        "cpuPercent": .null,
        "rssKb": .null,
    ])
}

private func backgroundTerminalResponse(
    id: CodexAppServerRequestID,
    terminals: [CodexJSONValue],
    nextCursor: String?
) -> CodexDesktopHostMessage {
    backgroundTerminalObjectResponse(
        id: id,
        value: [
            "data": .array(terminals),
            "nextCursor": nextCursor.map(CodexJSONValue.string) ?? .null,
        ]
    )
}

private func backgroundTerminalBooleanResponse(
    id: CodexAppServerRequestID,
    key: String,
    value: Bool
) -> CodexDesktopHostMessage {
    backgroundTerminalObjectResponse(
        id: id,
        value: [key: .bool(value)]
    )
}

private func backgroundTerminalObjectResponse(
    id: CodexAppServerRequestID,
    value: [String: CodexJSONValue]
) -> CodexDesktopHostMessage {
    .mcpResponse(
        hostID: "desktop-host-1",
        message: .object([
            "id": backgroundTerminalRequestID(id),
            "result": .object(value),
        ]),
        metadata: [:]
    )
}

private func backgroundTerminalError(
    id: CodexAppServerRequestID,
    code: Int64,
    message: String
) -> CodexDesktopHostMessage {
    .mcpResponse(
        hostID: "desktop-host-1",
        message: .object([
            "id": backgroundTerminalRequestID(id),
            "error": .object([
                "code": .integer(code),
                "message": .string(message),
            ]),
        ]),
        metadata: [:]
    )
}

private func backgroundTerminalRequestID(
    _ id: CodexAppServerRequestID
) -> CodexJSONValue {
    switch id {
    case let .string(value):
        return .string(value)
    case let .integer(value):
        return .integer(value)
    }
}
