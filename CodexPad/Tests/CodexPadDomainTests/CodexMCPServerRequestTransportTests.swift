import Foundation
import Testing

@testable import CodexPadApplication
@testable import CodexPadDomain

private actor MCPServerRequestProbe {
    struct Request: Equatable, Sendable {
        let method: String
        let params: CodexJSONValue?
    }

    private let response: CodexJSONValue
    private var requests: [Request] = []

    init(response: CodexJSONValue) {
        self.response = response
    }

    func handle(
        method: String,
        params: CodexJSONValue?
    ) -> CodexJSONValue {
        requests.append(.init(method: method, params: params))
        return response
    }

    func snapshot() -> [Request] {
        requests
    }
}

private struct MCPServerRequestFixture {
    static let configuration = CodexMCPServerConfiguration(
        transport: .stdio(
            command: "/fixture",
            args: [],
            env: nil,
            envVars: [],
            cwd: nil
        )
    )
}

private actor MCPServerRequestStdioTransport:
    CodexMCPStdioTransport
{
    private var incoming: [Data]
    private var written: [Data] = []

    init(lines: [String]) {
        incoming = lines.map { Data($0.utf8) }
    }

    func writeLine(_ data: Data) {
        written.append(data)
    }

    func readLine(timeoutSeconds _: Double?) throws -> Data {
        guard !incoming.isEmpty else {
            throw CodexMCPStdioError.invalidResponse
        }
        return incoming.removeFirst()
    }

    func writtenMessages() throws -> [CodexJSONValue] {
        try written.map {
            try JSONDecoder().decode(CodexJSONValue.self, from: $0)
        }
    }
}

@Test
func mcpStdioForwardsLegacyElicitationAndRepliesWithOriginalID()
    async throws
{
    let transport = MCPServerRequestStdioTransport(lines: [
        """
        {"jsonrpc":"2.0","id":"elicit-stdio","method":"elicitation/create","params":{"message":"Choose","requestedSchema":{"type":"object","properties":{"confirmed":{"type":"boolean"}}},"_meta":{"trace":"stdio"}}}
        """,
        """
        {"jsonrpc":"2.0","id":1,"result":{"content":[{"type":"text","text":"done"}],"isError":false}}
        """,
    ])
    let result: CodexJSONValue = .object([
        "action": .string("accept"),
        "content": .object(["confirmed": .bool(true)]),
        "_meta": .object(["persist": .bool(true)]),
    ])
    let probe = MCPServerRequestProbe(response: result)
    let client = CodexMCPStdioClient(
        serverName: "stdio-fixture",
        transport: transport,
        serverRequestHandler: { method, params in
            await probe.handle(method: method, params: params)
        }
    )

    _ = try await client.callTool(
        tool: "fixture",
        arguments: nil,
        meta: .object([
            "threadId": .string("thread-stdio"),
            "turnId": .string("turn-stdio"),
        ])
    )

    #expect(
        await probe.snapshot()
            == [
                .init(
                    method: "mcpServer/elicitation/request",
                    params: .object([
                        "threadId": .string("thread-stdio"),
                        "turnId": .string("turn-stdio"),
                        "serverName": .string("stdio-fixture"),
                        "mode": .string("form"),
                        "message": .string("Choose"),
                        "requestedSchema": .object([
                            "type": .string("object"),
                            "properties": .object([
                                "confirmed": .object([
                                    "type": .string("boolean")
                                ]),
                            ]),
                        ]),
                        "_meta": .object([
                            "trace": .string("stdio")
                        ]),
                    ])
                ),
            ]
    )
    let written = try await transport.writtenMessages()
    #expect(written.count == 2)
    #expect(
        written[1]
            == .object([
                "jsonrpc": .string("2.0"),
                "id": .string("elicit-stdio"),
                "result": result,
            ])
    )
}

private struct MCPServerRequestHTTPReply: Sendable {
    let status: Int
    let data: Data

    init(status: Int = 200, body: String = "") {
        self.status = status
        self.data = Data(body.utf8)
    }
}

private actor MCPServerRequestHTTPTransport:
    CodexMCPStreamableHTTPTransport
{
    private var replies: [MCPServerRequestHTTPReply]
    private var requests: [URLRequest] = []

    init(replies: [MCPServerRequestHTTPReply]) {
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
                  headerFields: nil
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
        let response = try await data(for: request)
        for event in response.0.split(separator: 0x0A, omittingEmptySubsequences: true) {
            guard event.starts(with: Data("data: ".utf8)) else { continue }
            try await receiveEvent(Data(event.dropFirst(6)))
        }
        return response
    }

    func recordedMessages() throws -> [CodexJSONValue] {
        try requests.map { request in
            guard let body = request.httpBody else {
                throw CodexMCPStreamableHTTPError.invalidResponse
            }
            return try JSONDecoder().decode(CodexJSONValue.self, from: body)
        }
    }
}

@Test
func mcpHTTPForwardsOpenAIFormAndPostsServerRequestResponse()
    async throws
{
    let transport = MCPServerRequestHTTPTransport(replies: [
        .init(
            body: """
            data: {"jsonrpc":"2.0","id":77,"method":"openai/form","params":{"message":"Sign in","requestedSchema":{"type":"object","properties":{}},"_meta":{"trace":"http"}}}

            data: {"jsonrpc":"2.0","id":1,"result":{"content":[{"type":"text","text":"done"}],"isError":false}}

            """
        ),
        .init(status: 202),
    ])
    let result: CodexJSONValue = .object([
        "action": .string("decline"),
        "content": .null,
        "_meta": .object(["reason": .string("user")]),
    ])
    let probe = MCPServerRequestProbe(response: result)
    let client = CodexMCPStreamableHTTPClient(
        endpoint: URL(string: "https://mcp.example.test/server-request")!,
        serverName: "http-fixture",
        transport: transport,
        serverRequestHandler: { method, params in
            await probe.handle(method: method, params: params)
        }
    )

    _ = try await client.callTool(
        tool: "fixture",
        arguments: nil,
        meta: .object([
            "threadId": .string("thread-http"),
            "turnId": .string("turn-http"),
        ])
    )

    #expect(
        await probe.snapshot()
            == [
                .init(
                    method: "mcpServer/elicitation/request",
                    params: .object([
                        "threadId": .string("thread-http"),
                        "turnId": .string("turn-http"),
                        "serverName": .string("http-fixture"),
                        "mode": .string("openai/form"),
                        "message": .string("Sign in"),
                        "requestedSchema": .object([
                            "type": .string("object"),
                            "properties": .object([:]),
                        ]),
                        "_meta": .object([
                            "trace": .string("http")
                        ]),
                    ])
                ),
            ]
    )
    let messages = try await transport.recordedMessages()
    #expect(messages.count == 2)
    #expect(
        messages[1]
            == .object([
                "jsonrpc": .string("2.0"),
                "id": .integer(77),
                "result": result,
            ])
    )
}

@Test
func mcpStdioConnectorWiresServerRequestHandlerAndThreadContext()
    async throws
{
    let transport = MCPServerRequestStdioTransport(lines: [
        """
        {"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-06-18","capabilities":{},"serverInfo":{"name":"fixture"}}}
        """,
        """
        {"jsonrpc":"2.0","id":"elicitation","method":"elicitation/create","params":{"message":"Choose","requestedSchema":{"type":"object"}}}
        """,
        """
        {"jsonrpc":"2.0","id":2,"result":{"content":[{"type":"text","text":"done"}],"isError":false}}
        """,
    ])
    let probe = MCPServerRequestProbe(response: .object([
        "action": .string("accept"),
        "content": .object([:]),
    ]))
    let connector = CodexMCPCompositeConnector(
        stdio: CodexMCPStdioConnector(
            transportProvider: { _, _, _, _ in transport }
        ),
        serverRequestHandler: { method, params in
            await probe.handle(method: method, params: params)
        }
    )
    let connected = try await connector.connect(
        name: "fixture",
        configuration: MCPServerRequestFixture.configuration,
        credential: nil
    )
    _ = try await connected.toolCaller(
        .init("thread-connector"),
        "fixture",
        nil,
        .object(["turnId": .string("turn-connector")])
    )
    #expect(await probe.snapshot() == [
        .init(
            method: "mcpServer/elicitation/request",
            params: .object([
                "threadId": .string("thread-connector"),
                "turnId": .string("turn-connector"),
                "serverName": .string("fixture"),
                "mode": .string("form"),
                "message": .string("Choose"),
                "requestedSchema": .object(["type": .string("object")]),
            ])
        ),
    ])
}
