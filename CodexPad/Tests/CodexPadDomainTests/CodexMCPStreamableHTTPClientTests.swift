import Foundation
import Testing

@testable import CodexPadApplication
@testable import CodexPadDomain

private struct MCPHTTPReply: Sendable {
    let status: Int
    let headers: [String: String]
    let data: Data

    init(
        status: Int = 200,
        headers: [String: String] = [:],
        body: String = ""
    ) {
        self.status = status
        self.headers = headers
        self.data = Data(body.utf8)
    }
}

private actor MCPHTTPTransportProbe:
    CodexMCPStreamableHTTPTransport
{
    private var replies: [MCPHTTPReply]
    private var requests: [URLRequest] = []
    private var streamingRequests = 0

    init(_ replies: [MCPHTTPReply]) {
        self.replies = replies
    }

    func data(
        for request: URLRequest
    ) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        guard !replies.isEmpty,
              let url = request.url,
              let response = HTTPURLResponse(
                  url: url,
                  statusCode: replies[0].status,
                  httpVersion: "HTTP/1.1",
                  headerFields: replies[0].headers
              )
        else {
            throw CodexMCPStreamableHTTPError.invalidResponse
        }
        let reply = replies.removeFirst()
        return (reply.data, response)
    }

    func streamingData(
        for request: URLRequest,
        receiveEvent:
            @escaping @Sendable (Data) async throws -> Void
    ) async throws -> (Data, HTTPURLResponse) {
        streamingRequests += 1
        let response = try await data(for: request)
        try await receiveEvent(response.0)
        return response
    }

    func recordedRequests() -> [URLRequest] {
        requests
    }

    func streamingRequestCount() -> Int {
        streamingRequests
    }
}

private func mcpRequestJSON(
    _ request: URLRequest
) throws -> [String: CodexJSONValue] {
    guard let body = request.httpBody,
          case let .object(fields) = try JSONDecoder().decode(
              CodexJSONValue.self,
              from: body
          )
    else {
        throw CodexMCPStreamableHTTPError.invalidResponse
    }
    return fields
}

private actor MCPProgressProbe {
    private var values: [String] = []

    func append(_ value: String) {
        values.append(value)
    }

    func snapshot() -> [String] {
        values
    }
}

@Test
func mcpStreamableHTTPConnectsDiscoversPagesReadsAndCalls()
    async throws
{
    let transport = MCPHTTPTransportProbe([
        MCPHTTPReply(
            headers: ["Mcp-Session-Id": "session-7"],
            body: """
            {"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-06-18","capabilities":{"tools":{"listChanged":true},"resources":{"subscribe":false,"listChanged":true}},"serverInfo":{"name":"Fixture MCP","version":"7"}}}
            """
        ),
        MCPHTTPReply(status: 202),
        MCPHTTPReply(
            body: """
            {"jsonrpc":"2.0","id":2,"result":{"tools":[{"name":"echo","description":"Echo"}],"nextCursor":"tools-2"}}
            """
        ),
        MCPHTTPReply(
            body: """
            {"jsonrpc":"2.0","id":3,"result":{"tools":[{"name":"sum","inputSchema":{"type":"object"}}]}}
            """
        ),
        MCPHTTPReply(
            body: """
            {"jsonrpc":"2.0","id":4,"result":{"resources":[{"uri":"fixture://today","name":"today","mimeType":"text/plain"}]}}
            """
        ),
        MCPHTTPReply(
            body: """
            {"jsonrpc":"2.0","id":5,"result":{"resourceTemplates":[{"uriTemplate":"fixture://{day}","name":"day"}]}}
            """
        ),
        MCPHTTPReply(
            body: """
            {"jsonrpc":"2.0","id":6,"result":{"contents":[{"uri":"fixture://today","mimeType":"text/plain","text":"real body"}]}}
            """
        ),
        MCPHTTPReply(
            body: """
            event: message\r
            data: {"jsonrpc":"2.0","id":7,"result":{"content":[{"type":"text","text":"echoed"}],"structuredContent":{"ok":true},"isError":false,"_meta":{"trace":"real"}}}\r
            \r
            """
        ),
    ])
    let client = CodexMCPStreamableHTTPClient(
        endpoint: URL(string: "https://mcp.example.test/rpc")!,
        headers: ["X-Client": "ipad"],
        transport: transport
    )

    let connected = try await client.connect()
    #expect(
        connected.serverInfo
            == .object([
                "name": .string("Fixture MCP"),
                "version": .string("7"),
            ])
    )
    #expect(connected.tools.keys.sorted() == ["echo", "sum"])
    #expect(connected.resources.map(\.uri) == ["fixture://today"])
    #expect(
        connected.resourceTemplates.map(\.uriTemplate)
            == ["fixture://{day}"]
    )

    let contents = try await connected.resourceReader(
        "fixture://today"
    )
    #expect(
        contents
            == [.text(
                uri: "fixture://today",
                mimeType: "text/plain",
                text: "real body"
            )]
    )
    let call = try await connected.toolCaller(
        .init("thread-real"),
        "echo",
        .object(["value": .string("hello")]),
        .object(["threadId": .string("thread-real")])
    )
    #expect(call.isError == false)
    #expect(
        call.structuredContent
            == .object(["ok": .bool(true)])
    )
    #expect(call.meta == .object(["trace": .string("real")]))

    let requests = await transport.recordedRequests()
    #expect(requests.count == 8)
    #expect(
        try requests.map {
            try mcpRequestJSON($0)["method"]
        } == [
            .string("initialize"),
            .string("notifications/initialized"),
            .string("tools/list"),
            .string("tools/list"),
            .string("resources/list"),
            .string("resources/templates/list"),
            .string("resources/read"),
            .string("tools/call"),
        ]
    )
    #expect(
        requests.dropFirst().allSatisfy {
            $0.value(forHTTPHeaderField: "Mcp-Session-Id")
                == "session-7"
        }
    )
    #expect(
        requests.allSatisfy {
            $0.value(forHTTPHeaderField: "MCP-Protocol-Version")
                == "2025-06-18"
                && $0.value(forHTTPHeaderField: "X-Client")
                    == "ipad"
        }
    )
    let callParams = try mcpRequestJSON(requests[7])["params"]
    #expect(
        callParams
            == .object([
                "name": .string("echo"),
                "arguments": .object([
                    "value": .string("hello"),
                ]),
                "_meta": .object([
                    "threadId": .string("thread-real"),
                ]),
            ])
    )
}

@Test
func mcpStreamableHTTPHonorsCapabilitiesAndConnectorHeaders()
    async throws
{
    let transport = MCPHTTPTransportProbe([
        MCPHTTPReply(
            body: """
            {"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-06-18","capabilities":{},"serverInfo":{"name":"No Inventory"}}}
            """
        ),
        MCPHTTPReply(status: 204),
    ])
    let connector = CodexMCPStreamableHTTPConnector(
        environmentProvider: {
            [
                "TOKEN_VAR": "secret-token",
                "HEADER_VAR": "dynamic-value",
            ]
        },
        transportProvider: { transport }
    )
    let connected = try await connector.connect(
        name: "empty",
        configuration: CodexMCPServerConfiguration(
            transport: .streamableHTTP(
                url: "https://empty.example.test/mcp",
                bearerTokenEnvVar: "TOKEN_VAR",
                httpHeaders: ["X-Static": "fixed"],
                envHTTPHeaders: ["X-Dynamic": "HEADER_VAR"]
            )
        ),
        credential: nil
    )
    #expect(connected.tools.isEmpty)
    #expect(connected.resources.isEmpty)
    #expect(connected.resourceTemplates.isEmpty)

    let requests = await transport.recordedRequests()
    #expect(requests.count == 2)
    #expect(
        requests[0].value(forHTTPHeaderField: "Authorization")
            == "Bearer secret-token"
    )
    #expect(
        requests[0].value(forHTTPHeaderField: "X-Static")
            == "fixed"
    )
    #expect(
        requests[0].value(forHTTPHeaderField: "X-Dynamic")
            == "dynamic-value"
    )
}

@Test
func mcpStreamableHTTPForwardsInterleavedProgressBeforeResponse()
    async throws
{
    let transport = MCPHTTPTransportProbe([
        MCPHTTPReply(
            body: """
            {"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-06-18","capabilities":{},"serverInfo":{"name":"Progress"}}}
            """
        ),
        MCPHTTPReply(status: 202),
        MCPHTTPReply(
            body: """
            event: message
            data: {"jsonrpc":"2.0","method":"notifications/progress","params":{"progressToken":"progress-1","progress":0.5,"message":"halfway"}}

            event: message
            data: {"jsonrpc":"2.0","id":2,"result":{"content":[{"type":"text","text":"done"}],"isError":false}}

            """
        ),
    ])
    let client = CodexMCPStreamableHTTPClient(
        endpoint: URL(string: "https://mcp.example.test/progress")!,
        transport: transport
    )
    _ = try await client.connect()
    let progress = MCPProgressProbe()
    let result = try await client.callTool(
        tool: "progress",
        arguments: nil,
        meta: .object(["trace": .string("keep")]),
        progress: { message in
            await progress.append(message)
        }
    )
    #expect(result.isError == false)
    #expect(await progress.snapshot() == ["halfway"])
    #expect(await transport.streamingRequestCount() == 1)

    let requests = await transport.recordedRequests()
    let params = try mcpRequestJSON(requests[2])["params"]
    #expect(
        params == .object([
            "name": .string("progress"),
            "_meta": .object([
                "trace": .string("keep"),
                "progressToken": .string("progress-1"),
            ]),
        ])
    )
}

private struct MCPConnectorProbe:
    CodexMCPServerConnecting
{
    func connect(
        name _: String,
        configuration _: CodexMCPServerConfiguration,
        credential _: CodexMCPOAuthCredential?
    ) async throws -> CodexMCPConnectedServer {
        CodexMCPConnectedServer(
            serverInfo: .object(["name": .string("Connected")]),
            tools: [
                "echo": .object(["name": .string("echo")]),
            ],
            resources: [
                .init(uri: "connected://resource", name: "resource"),
            ],
            resourceTemplates: [],
            resourceReader: { uri in
                [.text(uri: uri, text: "connected body")]
            },
            toolCaller: { _, _, _, _ in
                .init(
                    content: [
                        .object([
                            "type": .string("text"),
                            "text": .string("connected call"),
                        ]),
                    ],
                    isError: false
                )
            }
        )
    }
}

@Test @MainActor
func mcpRuntimeRegistryConnectsRemoteInventoryAndExecutors()
    async throws
{
    let configuration = CodexMCPServerConfiguration(
        transport: .streamableHTTP(
            url: "https://connected.example.test/mcp",
            bearerTokenEnvVar: nil,
            httpHeaders: nil,
            envHTTPHeaders: nil
        )
    )
    let registry = CodexMCPRuntimeRegistry(
        configurationProvider: {
            ["connected": configuration]
        },
        credentialProvider: { _ in nil },
        connector: MCPConnectorProbe()
    )

    try await registry.refreshMCPServers()
    let status = try registry.listMCPServerStatuses(
        cursor: nil,
        limit: nil,
        detail: .full
    ).data.first
    #expect(status?.startupState == .ready)
    #expect(status?.tools.keys.sorted() == ["echo"])
    #expect(
        try await registry.readMCPResource(
            threadID: nil,
            server: "connected",
            uri: "connected://resource"
        ) == [
            .text(
                uri: "connected://resource",
                text: "connected body"
            ),
        ]
    )
    let call = try await registry.callMCPTool(
        threadID: .init("thread-connected"),
        server: "connected",
        tool: "echo",
        arguments: nil,
        meta: nil
    )
    #expect(call.isError == false)
}

@Test @MainActor
func mcpRuntimeRegistryConnectsConfiguredStdioInventory()
    async throws
{
    let configuration = CodexMCPServerConfiguration(
        transport: .stdio(
            command: "sample-mcp",
            args: ["--stdio"],
            env: ["FIXTURE": "ready"],
            envVars: [],
            cwd: nil
        )
    )
    let registry = CodexMCPRuntimeRegistry(
        configurationProvider: {
            ["local": configuration]
        },
        credentialProvider: { _ in nil },
        connector: MCPConnectorProbe()
    )

    try await registry.refreshMCPServers()
    let status = try registry.listMCPServerStatuses(
        cursor: nil,
        limit: nil,
        detail: .full
    ).data.first
    #expect(status?.authStatus == .unsupported)
    #expect(status?.startupState == .ready)
    #expect(status?.tools.keys.sorted() == ["echo"])
}
