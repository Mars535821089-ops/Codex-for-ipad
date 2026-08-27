import Foundation
import Testing

@testable import CodexPadApplication
@testable import CodexPadDomain

private actor MCPStdioProgressProbe {
    private var values: [String] = []

    func append(_ value: String) {
        values.append(value)
    }

    func snapshot() -> [String] {
        values
    }
}

@Test
func mcpStdioTransportEnforcesWholeLineTimeout() async throws {
    #if os(macOS)
    let transport = CodexMCPStdioProcessTransport(
        command: "/bin/sh",
        arguments: ["-c", "sleep 2"],
        environment: ProcessInfo.processInfo.environment,
        cwd: nil
    )
    let startedAt = ContinuousClock.now
    await #expect(throws: CodexMCPStdioError.timedOut) {
        try await transport.readLine(timeoutSeconds: 0.025)
    }
    #expect(startedAt.duration(to: .now) < .seconds(1))
    #endif
}

@Test
func mcpStdioConnectorRunsNewlineJSONRPCProcessAndLiveMethods()
    async throws
{
    #if os(macOS)
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(
            "codex-mcp-stdio-\(UUID().uuidString)",
            isDirectory: true
        )
    try FileManager.default.createDirectory(
        at: root,
        withIntermediateDirectories: true
    )
    defer {
        try? FileManager.default.removeItem(at: root)
    }
    let script = root.appendingPathComponent("server.py")
    try """
    import json, os, sys
    for line in sys.stdin:
        message = json.loads(line)
        request_id = message.get("id")
        if request_id is None:
            continue
        method = message.get("method")
        if method == "initialize":
            result = {
                "protocolVersion": "2025-06-18",
                "capabilities": {"tools": {}, "resources": {}},
                "serverInfo": {"name": os.environ["MCP_FIXTURE"]}
            }
        elif method == "tools/list":
            result = {"tools": [{
                "name": "echo",
                "description": "Echo text",
                "inputSchema": {"type": "object"}
            }]}
        elif method == "resources/list":
            result = {"resources": [{
                "uri": "fixture://one",
                "name": "one"
            }]}
        elif method == "resources/templates/list":
            result = {"resourceTemplates": []}
        elif method == "resources/read":
            result = {"contents": [{
                "uri": message["params"]["uri"],
                "text": "stdio resource"
            }]}
        elif method == "tools/call":
            meta = message["params"].get("_meta", {})
            progress_token = meta.get("progressToken")
            if progress_token:
                print(json.dumps({
                    "jsonrpc": "2.0",
                    "method": "notifications/progress",
                    "params": {
                        "progressToken": progress_token,
                        "progress": 0.5,
                        "message": "stdio:" + meta.get("trace", "missing")
                    }
                }), flush=True)
            result = {
                "content": [{
                    "type": "text",
                    "text": message["params"]["arguments"]["message"]
                }],
                "isError": False
            }
        else:
            result = {}
        print(json.dumps({
            "jsonrpc": "2.0",
            "id": request_id,
            "result": result
        }), flush=True)
    """.write(to: script, atomically: true, encoding: .utf8)

    let connector = CodexMCPStdioConnector()
    let connected = try await connector.connect(
        name: "fixture",
        configuration: CodexMCPServerConfiguration(
            transport: .stdio(
                command: "/usr/bin/python3",
                args: [script.path],
                env: ["MCP_FIXTURE": "Fixture Stdio"],
                envVars: [],
                cwd: root.path
            ),
            startupTimeoutSeconds: 5,
            toolTimeoutSeconds: 5
        ),
        credential: nil
    )
    #expect(
        connected.serverInfo
            == .object(["name": .string("Fixture Stdio")])
    )
    #expect(connected.tools.keys.sorted() == ["echo"])
    #expect(connected.resources.map(\.uri) == ["fixture://one"])
    #expect(
        try await connected.resourceReader("fixture://one")
            == [
                .text(
                    uri: "fixture://one",
                    text: "stdio resource"
                ),
            ]
    )
    let call = try await connected.toolCaller(
        .init("thread-stdio"),
        "echo",
        .object(["message": .string("stdio call")]),
        nil
    )
    #expect(call.isError == false)
    #expect(
        call.content
            == [
                .object([
                    "type": .string("text"),
                    "text": .string("stdio call"),
                ]),
            ]
    )
    let progressCaller = try #require(
        connected.progressToolCaller
    )
    let progress = MCPStdioProgressProbe()
    let progressCall = try await progressCaller(
        .init("thread-stdio"),
        "echo",
        .object(["message": .string("stdio progress call")]),
        .object(["trace": .string("keep")]),
        { message in
            await progress.append(message)
        }
    )
    #expect(progressCall.isError == false)
    #expect(
        progressCall.content
            == [
                .object([
                    "type": .string("text"),
                    "text": .string("stdio progress call"),
                ]),
            ]
    )
    #expect(await progress.snapshot() == ["stdio:keep"])
    #endif
}
