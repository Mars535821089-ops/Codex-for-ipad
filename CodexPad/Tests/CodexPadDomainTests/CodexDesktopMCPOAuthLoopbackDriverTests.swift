import Foundation
import Testing

@testable import CodexPadApplication
@testable import CodexPadDomain
@testable import CodexPadProtocolBridge

private actor MCPLoopbackServerProbe:
    CodexLoopbackHTTPServerSession
{
    nonisolated let port: UInt16 = 1456
    var finishResult: CodexLoopbackHTTPCallbackFinish?
    var canceled = false

    func waitForAuthorizationCode(
        expectedState _: String
    ) async throws -> String {
        "authorization-code"
    }

    func finish(
        _ result: CodexLoopbackHTTPCallbackFinish
    ) async throws {
        finishResult = result
    }

    func cancel() async {
        canceled = true
    }
}

private struct MCPLoopbackServerStarterProbe:
    CodexLoopbackHTTPServerStarting
{
    let server: MCPLoopbackServerProbe

    func start(
        preferredPorts _: [UInt16]
    ) async throws -> any CodexLoopbackHTTPServerSession {
        server
    }
}

private actor MCPLoopbackFlowProbe:
    CodexMCPOAuthFlowClient
{
    private(set) var preparedRequest: CodexMCPOAuthFlowRequest?
    private(set) var exchangedCode: String?

    func prepareAuthorization(
        _ request: CodexMCPOAuthFlowRequest
    ) async throws -> CodexMCPOAuthPreparedAuthorization {
        preparedRequest = request
        return CodexMCPOAuthPreparedAuthorization(
            authorizationURL: URL(
                string: "https://mcp.example.test/authorize"
            )!,
            tokenEndpoint: URL(
                string: "https://mcp.example.test/token"
            )!,
            clientID: "client-1",
            resource: nil
        )
    }

    func exchangeAuthorizationCode(
        _ code: String,
        redirectURI _: String,
        codeVerifier _: String,
        prepared: CodexMCPOAuthPreparedAuthorization,
        headers _: [String: String]
    ) async throws -> CodexMCPOAuthCredential {
        exchangedCode = code
        return CodexMCPOAuthCredential(
            accessToken: "access-token",
            refreshToken: "refresh-token",
            tokenType: "Bearer",
            scope: "read",
            expiresAt: Date().addingTimeInterval(3_600),
            clientID: prepared.clientID,
            tokenEndpoint: prepared.tokenEndpoint
        )
    }
}

private actor MCPLoopbackCredentialStoreProbe:
    CodexMCPOAuthCredentialPersisting
{
    private(set) var saved:
        (CodexMCPOAuthCredential, String)?

    func save(
        _ credential: CodexMCPOAuthCredential,
        serverName: String
    ) async throws {
        saved = (credential, serverName)
    }
}

private actor MCPLoopbackCompletionProbe {
    private(set) var values:
        [CodexDesktopMCPOAuthSessionCompletion] = []

    func append(_ value: CodexDesktopMCPOAuthSessionCompletion) {
        values.append(value)
    }
}

@Test
func mcpLoopbackDriverExchangesPersistsInvalidatesAndFinishes()
    async throws
{
    let server = MCPLoopbackServerProbe()
    let flow = MCPLoopbackFlowProbe()
    let store = MCPLoopbackCredentialStoreProbe()
    let completion = MCPLoopbackCompletionProbe()
    let invalidations = MCPAtomicCounter()
    let configuration = CodexMCPServerConfiguration(
        transport: .streamableHTTP(
            url: "https://mcp.example.test/mcp",
            bearerTokenEnvVar: nil,
            httpHeaders: ["X-Client": "ipad"],
            envHTTPHeaders: nil
        ),
        auth: .oauth,
        environmentID: "local",
        enabled: true,
        required: false,
        supportsParallelToolCalls: true,
        startupTimeoutSeconds: nil,
        toolTimeoutSeconds: nil,
        defaultToolsApprovalMode: nil,
        enabledTools: nil,
        disabledTools: nil,
        scopes: ["configured.read"],
        oauthClientID: nil,
        oauthResource: nil,
        toolApprovalModes: [:]
    )
    let driver = CodexDesktopMCPOAuthLoopbackDriver(
        configurationProvider: { _ in configuration },
        serverStarter: MCPLoopbackServerStarterProbe(server: server),
        flowClient: flow,
        credentialStore: store,
        invalidateRuntime: {
            await invalidations.increment()
        },
        makeState: { "state-1" },
        makePKCE: {
            CodexLoopbackOAuthPKCE(
                codeVerifier: "verifier-1",
                codeChallenge: "challenge-1"
            )
        }
    )

    let started = try await driver.startMCPOAuthLogin(
        name: "calendar",
        threadID: nil,
        scopes: nil,
        timeoutSeconds: 5,
        completion: { value in
            await completion.append(value)
        }
    )
    #expect(
        started.authorizationURL
            == "https://mcp.example.test/authorize"
    )
    #expect(
        await flow.preparedRequest
            == CodexMCPOAuthFlowRequest(
                serverName: "calendar",
                serverURL: URL(
                    string: "https://mcp.example.test/mcp"
                )!,
                redirectURI: "http://localhost:1456/auth/callback",
                state: "state-1",
                codeChallenge: "challenge-1",
                scopes: ["configured.read"],
                configuredClientID: nil,
                resource: nil,
                headers: ["X-Client": "ipad"]
            )
    )

    for _ in 0..<50 where await completion.values.isEmpty {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(await flow.exchangedCode == "authorization-code")
    #expect(await store.saved?.1 == "calendar")
    #expect(await invalidations.value == 1)
    #expect(await completion.values == [.succeeded])
    #expect(
        await server.finishResult
            == .success(
                .local(
                    URL(string: "http://localhost:1456/success")!,
                    streamlined: false
                )
            )
    )
}

@Test
func mcpLoopbackDriverRejectsBearerConfiguredServer() async {
    let server = MCPLoopbackServerProbe()
    let driver = CodexDesktopMCPOAuthLoopbackDriver(
        configurationProvider: { _ in
            CodexMCPServerConfiguration(
                transport: .streamableHTTP(
                    url: "https://mcp.example.test/mcp",
                    bearerTokenEnvVar: "MCP_TOKEN",
                    httpHeaders: nil,
                    envHTTPHeaders: nil
                ),
                auth: .oauth,
                environmentID: "local",
                enabled: true,
                required: false,
                supportsParallelToolCalls: false,
                startupTimeoutSeconds: nil,
                toolTimeoutSeconds: nil,
                defaultToolsApprovalMode: nil,
                enabledTools: nil,
                disabledTools: nil,
                scopes: nil,
                oauthClientID: nil,
                oauthResource: nil,
                toolApprovalModes: [:]
            )
        },
        serverStarter: MCPLoopbackServerStarterProbe(server: server),
        flowClient: MCPLoopbackFlowProbe(),
        credentialStore: MCPLoopbackCredentialStoreProbe()
    )

    await #expect(throws: CodexDesktopMCPOAuthLoopbackError.bearerTokenConfigured) {
        try await driver.startMCPOAuthLogin(
            name: "calendar",
            threadID: nil,
            scopes: nil,
            timeoutSeconds: nil,
            completion: { _ in }
        )
    }
}

private actor MCPAtomicCounter {
    private(set) var value = 0
    func increment() { value += 1 }
}
