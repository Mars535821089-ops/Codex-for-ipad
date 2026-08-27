import Foundation
import Testing

@testable import CodexPadApplication
@testable import CodexPadDomain

private func registryConfiguration(
    transport: CodexMCPServerTransport
) -> CodexMCPServerConfiguration {
    CodexMCPServerConfiguration(transport: transport)
}

private actor MCPRuntimeProgressProbe {
    private var values: [CodexMCPToolProgress] = []

    func append(_ value: CodexMCPToolProgress) {
        values.append(value)
    }

    func snapshot() -> [CodexMCPToolProgress] {
        values
    }
}

@Test @MainActor
func mcpRuntimeRegistryRefreshesOfficialAuthStatesAndDropsRemovedServers()
    async throws
{
    let credential = CodexMCPOAuthCredential(
        accessToken: "token",
        refreshToken: nil,
        tokenType: "Bearer",
        scope: nil,
        expiresAt: nil,
        clientID: "client",
        tokenEndpoint: URL(string: "https://auth.example.test/token")!
    )
    var configurations: [String: CodexMCPServerConfiguration] = [
        "local": registryConfiguration(
            transport: .stdio(
                command: "sample",
                args: [],
                env: nil,
                envVars: [],
                cwd: nil
            )
        ),
        "bearer": registryConfiguration(
            transport: .streamableHTTP(
                url: "https://bearer.example.test/mcp",
                bearerTokenEnvVar: "MCP_TOKEN",
                httpHeaders: nil,
                envHTTPHeaders: nil
            )
        ),
        "calendar": registryConfiguration(
            transport: .streamableHTTP(
                url: "https://calendar.example.test/mcp",
                bearerTokenEnvVar: nil,
                httpHeaders: nil,
                envHTTPHeaders: nil
            )
        ),
    ]
    let registry = CodexMCPRuntimeRegistry(
        configurationProvider: { configurations },
        credentialProvider: { name in
            name == "calendar" ? credential : nil
        }
    )

    try await registry.refreshMCPServers()
    let first = try registry.listMCPServerStatuses(
        cursor: nil,
        limit: nil,
        detail: .full
    )
    #expect(
        Dictionary(
            uniqueKeysWithValues:
                first.data.map { ($0.name, $0.authStatus) }
        ) == [
            "local": .unsupported,
            "bearer": .bearerToken,
            "calendar": .oauth,
        ]
    )

    configurations.removeValue(forKey: "local")
    try await registry.refreshMCPServers()
    let second = try registry.listMCPServerStatuses(
        cursor: nil,
        limit: nil,
        detail: .full
    )
    #expect(second.data.map(\.name) == ["bearer", "calendar"])
    #expect(registry.revision == 2)
}

@Test @MainActor
func mcpRuntimeRegistryPreservesConnectedInventoryAcrossAuthRefresh()
    async throws
{
    let configuration = registryConfiguration(
        transport: .streamableHTTP(
            url: "https://mcp.example.test/mcp",
            bearerTokenEnvVar: nil,
            httpHeaders: nil,
            envHTTPHeaders: nil
        )
    )
    let registry = CodexMCPRuntimeRegistry(
        configurationProvider: { ["sample": configuration] },
        credentialProvider: { _ in nil }
    )

    try await registry.refreshMCPServers()
    registry.updateInventory(
        for: "sample",
        serverInfo: .object(["name": .string("Fixture MCP")]),
        tools: ["read": .object(["name": .string("read")])],
        resources: [
            CodexMCPResource(uri: "fixture://one", name: "one"),
        ],
        resourceTemplates: [],
        contentsByURI: [
            "fixture://one": [
                .text(
                    uri: "fixture://one",
                    text: "real fixture content"
                ),
            ],
        ]
    )
    try await registry.refreshMCPServers()

    let page = try registry.listMCPServerStatuses(
        cursor: nil,
        limit: nil,
        detail: .full
    )
    #expect(page.data.first?.authStatus == .notLoggedIn)
    #expect(page.data.first?.tools.keys.sorted() == ["read"])
    #expect(page.data.first?.resources.map(\.uri) == ["fixture://one"])
    #expect(
        try await registry.readMCPResource(
            threadID: nil,
            server: "sample",
            uri: "fixture://one"
        ) == [
            .text(
                uri: "fixture://one",
                text: "real fixture content"
            ),
        ]
    )
}

@Test @MainActor
func mcpRuntimeRegistryCallsOnlyAdvertisedConnectedTools()
    async throws
{
    let configuration = registryConfiguration(
        transport: .streamableHTTP(
            url: "https://mcp.example.test/mcp",
            bearerTokenEnvVar: nil,
            httpHeaders: nil,
            envHTTPHeaders: nil
        )
    )
    let registry = CodexMCPRuntimeRegistry(
        configurationProvider: { ["sample": configuration] },
        credentialProvider: { _ in nil }
    )
    try await registry.refreshMCPServers()
    var received:
        (
            CodexStoredThreadID,
            String,
            CodexJSONValue?,
            CodexJSONValue?
        )?
    registry.updateInventory(
        for: "sample",
        serverInfo: nil,
        tools: [
            "echo": .object(["name": .string("echo")]),
        ],
        resources: [],
        resourceTemplates: [],
        toolCaller: { threadID, tool, arguments, meta in
            received = (threadID, tool, arguments, meta)
            return .init(
                content: [
                    .object([
                        "type": .string("text"),
                        "text": .string("echoed"),
                    ]),
                ],
                isError: false
            )
        }
    )

    let result = try await registry.callMCPTool(
        threadID: .init("thread-tool"),
        server: "sample",
        tool: "echo",
        arguments: .object(["message": .string("hello")]),
        meta: .object(["threadId": .string("thread-tool")])
    )
    #expect(result.isError == false)
    #expect(received?.0 == .init("thread-tool"))
    #expect(received?.1 == "echo")
    #expect(
        received?.2 == .object(["message": .string("hello")])
    )
    #expect(
        received?.3
            == .object(["threadId": .string("thread-tool")])
    )
    await #expect(
        throws: CodexMCPResourceError.unknownTool(
            server: "sample",
            tool: "missing"
        )
    ) {
        try await registry.callMCPTool(
            threadID: .init("thread-tool"),
            server: "sample",
            tool: "missing",
            arguments: nil,
            meta: nil
        )
    }
}

@Test @MainActor
func mcpRuntimeRegistryWiresDeferredToolSearchAndLiveResourceReads()
    async throws
{
    let configuration = registryConfiguration(
        transport: .streamableHTTP(
            url: "https://mcp.example.test/mcp",
            bearerTokenEnvVar: nil,
            httpHeaders: nil,
            envHTTPHeaders: nil
        )
    )
    let registry = CodexMCPRuntimeRegistry(
        configurationProvider: { ["sample": configuration] },
        credentialProvider: { _ in nil }
    )
    try await registry.refreshMCPServers()

    var invocationArguments: CodexJSONValue?
    registry.updateInventory(
        for: "sample",
        serverInfo: nil,
        tools: [
            "echo": .object([
                "description": .string("Echo a message."),
                "inputSchema": .object([
                    "type": .string("object"),
                    "properties": .object([
                        "message": .object([
                            "type": .string("string"),
                        ]),
                    ]),
                ]),
            ]),
        ],
        resources: [
            .init(uri: "fixture://live", name: "live"),
        ],
        resourceTemplates: [],
        resourceReader: { uri in
            [
                .text(uri: uri, text: "live registry content"),
            ]
        },
        toolCaller: { _, _, arguments, _ in
            invocationArguments = arguments
            return .init(
                content: [
                    .object([
                        "type": .string("text"),
                        "text": .string("echoed"),
                    ]),
                ],
                isError: false
            )
        }
    )

    #expect(
        registry.officialToolSearchSources().map(\.name)
            == ["mcp__sample"]
    )

    let search = registry.makeToolSearchExecutor(
        threadID: .init("thread-runtime")
    )
    _ = try await search.execute(
        .init(
            threadID: .init("thread-runtime"),
            turnID: "turn-runtime",
            roundIndex: 1,
            name: "tool_search",
            arguments: #"{"query":"echo message"}"#,
            callID: "call-search",
            itemJSON: #"{"type":"tool_search_call"}"#
        ),
        cancellation: .init()
    )
    let call = CodexPersistedTurnToolRequest(
        threadID: .init("thread-runtime"),
        turnID: "turn-runtime",
        roundIndex: 2,
        name: "echo",
        arguments: #"{"message":"hello"}"#,
        callID: "call-echo",
        itemJSON:
            #"{"type":"function_call","namespace":"mcp__sample","name":"echo"}"#
    )
    #expect(
        search.canExecute(
            toolName: call.name,
            itemJSON: call.itemJSON
        )
    )
    let output = try await search.execute(
        call,
        cancellation: .init()
    )
    #expect(
        invocationArguments
            == .object(["message": .string("hello")])
    )
    #expect(output.itemJSON.contains(#""call_id":"call-echo""#))
    #expect(output.itemJSON.contains("echoed"))

    let resourceExecutor = CodexPersistedTurnMCPResourceExecutor(
        runtimeRegistry: registry
    )
    let read = try await resourceExecutor.execute(
        .init(
            threadID: .init("thread-runtime"),
            turnID: "turn-runtime",
            roundIndex: 1,
            name: "read_mcp_resource",
            arguments:
                #"{"server":"sample","uri":"fixture://live"}"#,
            callID: "call-read",
            itemJSON: #"{"type":"function_call"}"#
        ),
        cancellation: .init()
    )
    #expect(read.itemJSON.contains("live registry content"))
}

@Test @MainActor
func mcpRuntimeRegistryForwardsRealToolProgressWithTurnIdentity()
    async throws
{
    let configuration = registryConfiguration(
        transport: .streamableHTTP(
            url: "https://mcp.example.test/mcp",
            bearerTokenEnvVar: nil,
            httpHeaders: nil,
            envHTTPHeaders: nil
        )
    )
    let registry = CodexMCPRuntimeRegistry(
        configurationProvider: { ["sample": configuration] },
        credentialProvider: { _ in nil }
    )
    try await registry.refreshMCPServers()
    let probe = MCPRuntimeProgressProbe()
    registry.configureProgressSink { progress in
        await probe.append(progress)
    }
    registry.updateInventory(
        for: "sample",
        serverInfo: nil,
        tools: [
            "echo": .object([
                "description": .string("Echo a message."),
            ]),
        ],
        resources: [],
        resourceTemplates: [],
        toolCaller: { _, _, _, _ in
            .init(content: [], isError: false)
        },
        progressToolCaller: {
            _, _, _, _, progress in
            await progress?("halfway")
            return .init(content: [], isError: false)
        }
    )

    let executor = registry.makeToolSearchExecutor(
        threadID: .init("thread-progress")
    )
    _ = try await executor.execute(
        .init(
            threadID: .init("thread-progress"),
            turnID: "turn-progress",
            roundIndex: 1,
            name: "tool_search",
            arguments: #"{"query":"echo"}"#,
            callID: "call-search",
            itemJSON: #"{"type":"tool_search_call"}"#
        ),
        cancellation: .init()
    )
    _ = try await executor.execute(
        .init(
            threadID: .init("thread-progress"),
            turnID: "turn-progress",
            roundIndex: 2,
            name: "echo",
            arguments: #"{"message":"hello"}"#,
            callID: "call-progress",
            itemJSON:
                #"{"type":"function_call","namespace":"mcp__sample","name":"echo"}"#
        ),
        cancellation: .init()
    )

    #expect(
        await probe.snapshot()
            == [
                CodexMCPToolProgress(
                    threadID: .init("thread-progress"),
                    turnID: "turn-progress",
                    itemID: "call-progress",
                    message: "halfway"
                ),
            ]
    )
}
