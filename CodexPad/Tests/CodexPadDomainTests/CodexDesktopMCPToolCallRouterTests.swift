import CodexPadApplication
import CodexPadDomain
import CodexPadProtocolBridge
import Foundation
import Testing

@MainActor
private final class MCPToolCallProbe:
    CodexDesktopMCPToolCalling
{
    private(set) var received:
        (
            threadID: CodexStoredThreadID,
            server: String,
            tool: String,
            arguments: CodexJSONValue?,
            meta: CodexJSONValue?
        )?
    var error: CodexMCPResourceError?

    func callMCPTool(
        threadID: CodexStoredThreadID,
        server: String,
        tool: String,
        arguments: CodexJSONValue?,
        meta: CodexJSONValue?
    ) async throws -> CodexDesktopMCPToolCallResult {
        received = (threadID, server, tool, arguments, meta)
        if let error {
            throw error
        }
        return .init(
            content: [
                .object([
                    "type": .string("text"),
                    "text": .string("echo: hello from app"),
                ]),
            ],
            structuredContent: .object([
                "echoed": .string("hello from app"),
                "threadId": .string(threadID.rawValue),
            ]),
            isError: false,
            meta: .object([
                "calledBy": .string("mcp-app"),
            ])
        )
    }
}

@MainActor
private final class MCPToolThreadProbe:
    CodexDesktopThreadSessionListing,
    CodexDesktopThreadSessionReading
{
    private(set) var readParams: CodexThreadReadParams?

    func listThreads(
        id _: CodexAppServerRequestID,
        params _: CodexThreadListParams
    ) throws -> CodexThreadPage {
        .init(data: [], nextCursor: nil, backwardsCursor: nil)
    }

    func readThread(
        id _: CodexAppServerRequestID,
        params: CodexThreadReadParams
    ) throws -> CodexThreadReadResult {
        readParams = params
        return .init(
            thread: CodexStoredThread(
                id: params.threadID,
                sessionID: "tool-session",
                preview: "tool",
                ephemeral: false,
                modelProvider: "openai",
                createdAt: 1,
                updatedAt: 1,
                recencyAt: 1,
                status: .idle,
                path: "/tmp/tool.jsonl",
                cwd: "/workspace",
                cliVersion: "1",
                source: .named("appServer"),
                name: "Tool",
                turns: []
            )
        )
    }
}

@Test
@MainActor
func mcpToolCallMatchesOfficialWireContractAndInjectsThreadMeta()
    async
{
    let caller = MCPToolCallProbe()
    let threadReader = MCPToolThreadProbe()
    let response = await CodexDesktopInitialMCPRouter
        .responseIncludingFileSystem(
            to: mcpToolRequest(
                params: .object([
                    "threadId": .string("thread-tool"),
                    "server": .string("tool_server"),
                    "tool": .string("echo_tool"),
                    "arguments": .object([
                        "message": .string("hello from app"),
                    ]),
                    "_meta": .object([
                        "source": .string("mcp-app"),
                        "threadId": .string("wrong-thread"),
                    ]),
                ])
            ),
            state: mcpToolState(),
            allowedFileSystemRoots: [],
            threadLister: threadReader,
            mcpToolCaller: caller
        )

    #expect(threadReader.readParams?.threadID == .init("thread-tool"))
    #expect(threadReader.readParams?.includeTurns == false)
    #expect(caller.received?.threadID == .init("thread-tool"))
    #expect(caller.received?.server == "tool_server")
    #expect(caller.received?.tool == "echo_tool")
    #expect(
        caller.received?.arguments
            == .object([
                "message": .string("hello from app"),
            ])
    )
    #expect(
        caller.received?.meta
            == .object([
                "source": .string("mcp-app"),
                "threadId": .string("thread-tool"),
            ])
    )
    #expect(
        mcpToolResult(response)
            == [
                "content": .array([
                    .object([
                        "type": .string("text"),
                        "text": .string("echo: hello from app"),
                    ]),
                ]),
                "structuredContent": .object([
                    "echoed": .string("hello from app"),
                    "threadId": .string("thread-tool"),
                ]),
                "isError": .bool(false),
                "_meta": .object([
                    "calledBy": .string("mcp-app"),
                ]),
            ]
    )
}

@Test
@MainActor
func mcpToolCallSuppliesThreadMetaAndOmitsAbsentOptionals()
    async
{
    let caller = MCPToolCallProbe()
    let threadReader = MCPToolThreadProbe()
    let response = await CodexDesktopInitialMCPRouter
        .responseIncludingFileSystem(
            to: mcpToolRequest(
                params: .object([
                    "threadId": .string("thread-tool"),
                    "server": .string("tool_server"),
                    "tool": .string("echo_tool"),
                ])
            ),
            state: mcpToolState(),
            allowedFileSystemRoots: [],
            threadLister: threadReader,
            mcpToolCaller: caller
        )
    #expect(caller.received?.arguments == nil)
    #expect(
        caller.received?.meta
            == .object([
                "threadId": .string("thread-tool"),
            ])
    )
    #expect(mcpToolResult(response)?["content"] != nil)
}

@Test(arguments: [
    nil,
    CodexJSONValue.null,
    .object([:]),
    .object([
        "threadId": .string(""),
        "server": .string("tool_server"),
        "tool": .string("echo_tool"),
    ]),
    .object([
        "threadId": .string("thread-tool"),
        "server": .string(""),
        "tool": .string("echo_tool"),
    ]),
    .object([
        "threadId": .string("thread-tool"),
        "server": .string("tool_server"),
        "tool": .string("echo_tool"),
        "extra": .bool(true),
    ]),
])
@MainActor
func mcpToolCallRejectsNonOfficialParameterShapes(
    params: CodexJSONValue?
) async {
    let response = await CodexDesktopInitialMCPRouter
        .responseIncludingFileSystem(
            to: mcpToolRequest(params: params),
            state: mcpToolState(),
            allowedFileSystemRoots: [],
            threadLister: MCPToolThreadProbe(),
            mcpToolCaller: MCPToolCallProbe()
        )
    #expect(mcpToolError(response)?["code"] == .integer(-32602))
}

@Test(arguments: [
    (
        CodexMCPResourceError.unknownServer("missing"),
        "MCP server not found"
    ),
    (
        CodexMCPResourceError.unknownTool(
            server: "tool_server",
            tool: "missing"
        ),
        "MCP tool not found"
    ),
])
@MainActor
func mcpToolCallMapsLookupFailuresToInvalidRequest(
    fixture: (CodexMCPResourceError, String)
) async {
    let caller = MCPToolCallProbe()
    caller.error = fixture.0
    let response = await CodexDesktopInitialMCPRouter
        .responseIncludingFileSystem(
            to: mcpToolRequest(
                params: .object([
                    "threadId": .string("thread-tool"),
                    "server": .string("tool_server"),
                    "tool": .string("echo_tool"),
                ])
            ),
            state: mcpToolState(),
            allowedFileSystemRoots: [],
            threadLister: MCPToolThreadProbe(),
            mcpToolCaller: caller
        )
    #expect(mcpToolError(response)?["code"] == .integer(-32600))
    #expect(
        mcpToolError(response)?["message"]
            == .string(fixture.1)
    )
}

private func mcpToolRequest(
    params: CodexJSONValue?
) -> CodexDesktopMCPRequest {
    .init(
        request: .init(
            id: .string("tool-call-1"),
            method: "mcpServer/tool/call",
            params: params,
            metadata: [:]
        ),
        hostID: "desktop-host-tool",
        dispatchedAtMs: nil,
        priority: nil,
        source: nil,
        timeoutMs: nil,
        expiresAtMs: nil,
        metadata: [:]
    )
}

private func mcpToolState() -> CodexDesktopInitialMCPState {
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

private func mcpToolResult(
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

private func mcpToolError(
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
