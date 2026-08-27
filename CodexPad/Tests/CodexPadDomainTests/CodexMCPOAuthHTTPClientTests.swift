import Foundation
import Testing

@testable import CodexPadApplication

private actor OAuthHTTPTransportProbe: CodexMCPOAuthHTTPTransport {
    private(set) var requests: [URLRequest] = []

    func data(
        for request: URLRequest
    ) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let path = request.url?.path ?? ""
        switch (request.httpMethod ?? "GET", path) {
        case ("GET", "/.well-known/oauth-protected-resource/mcp"):
            return response(
                """
                {
                  "authorization_servers": ["https://auth.example.test"],
                  "resource": "https://mcp.example.test/mcp"
                }
                """
            )
        case ("GET", "/.well-known/oauth-protected-resource"):
            return response("{}", status: 404)
        case ("GET", "/.well-known/oauth-authorization-server"):
            return response(
                """
                {
                  "authorization_endpoint": "https://auth.example.test/authorize",
                  "token_endpoint": "https://auth.example.test/token",
                  "registration_endpoint": "https://auth.example.test/register",
                  "scopes_supported": ["mcp.read", "mcp.write"]
                }
                """
            )
        case ("POST", "/register"):
            return response(#"{"client_id":"dynamic-client"}"#)
        case ("POST", "/token"):
            let body = String(
                data: request.httpBody ?? Data(),
                encoding: .utf8
            ) ?? ""
            #expect(body.contains("grant_type=authorization_code"))
            #expect(body.contains("code=auth-code"))
            #expect(body.contains("client_id=dynamic-client"))
            #expect(body.contains("code_verifier=verifier"))
            #expect(body.contains("resource=https%3A%2F%2Fmcp.example.test%2Fmcp"))
            return response(
                #"{"access_token":"access-token","refresh_token":"refresh-token","token_type":"Bearer","scope":"mcp.read","expires_in":3600}"#
            )
        default:
            return response("{}", status: 404)
        }
    }

    func recordedRequests() -> [URLRequest] {
        requests
    }

    private func response(
        _ string: String,
        status: Int = 200
    ) -> (Data, HTTPURLResponse) {
        (
            Data(string.utf8),
            HTTPURLResponse(
                url: URL(string: "https://fixture.example.test")!,
                statusCode: status,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
        )
    }
}

@Test
func mcpOAuthHTTPClientDiscoversRegistersBuildsPKCEURLAndExchangesToken()
    async throws
{
    let transport = OAuthHTTPTransportProbe()
    let client = CodexMCPOAuthHTTPClient(transport: transport)
    let prepared = try await client.prepareAuthorization(
        CodexMCPOAuthFlowRequest(
            serverName: "calendar",
            serverURL: URL(string: "https://mcp.example.test/mcp")!,
            redirectURI: "http://localhost:1456/auth/callback",
            state: "state",
            codeChallenge: "challenge",
            scopes: [],
            configuredClientID: nil,
            resource: nil,
            headers: ["X-Client": "ipad"]
        )
    )

    let query = URLComponents(
        url: prepared.authorizationURL,
        resolvingAgainstBaseURL: false
    )?.queryItems ?? []
    #expect(prepared.clientID == "dynamic-client")
    #expect(query.contains(URLQueryItem(name: "state", value: "state")))
    #expect(
        query.contains(
            URLQueryItem(name: "scope", value: "mcp.read mcp.write")
        )
    )
    #expect(
        query.contains(
            URLQueryItem(
                name: "resource",
                value: "https://mcp.example.test/mcp"
            )
        )
    )

    let credential = try await client.exchangeAuthorizationCode(
        "auth-code",
        redirectURI: "http://localhost:1456/auth/callback",
        codeVerifier: "verifier",
        prepared: prepared,
        headers: ["X-Client": "ipad"]
    )
    #expect(credential.accessToken == "access-token")
    #expect(credential.refreshToken == "refresh-token")
    #expect(credential.clientID == "dynamic-client")

    let requests = await transport.recordedRequests()
    #expect(
        requests.map { $0.url?.path }
            == [
                "/.well-known/oauth-protected-resource/mcp",
                "/.well-known/oauth-authorization-server",
                "/register",
                "/token",
            ]
    )
    #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "X-Client") == "ipad" })
}
