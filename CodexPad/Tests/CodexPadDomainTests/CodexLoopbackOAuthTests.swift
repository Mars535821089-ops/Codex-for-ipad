import Foundation
import Testing
@testable import CodexPadProtocolBridge

@Suite(.serialized)
struct CodexLoopbackOAuthTests {
    @Test
    func stateAndPKCEMatchOfficialFixedVectors() throws {
        let deterministicBytes: CodexLoopbackOAuthRandomBytes = { count in
            (0..<count).map(UInt8.init)
        }

        let state = try CodexLoopbackOAuth.makeState(
            randomBytes: deterministicBytes
        )
        let pkce = try CodexLoopbackOAuth.makePKCE(
            randomBytes: deterministicBytes
        )

        #expect(
            state
                == "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8"
        )
        #expect(
            pkce.codeVerifier
                == "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8gISIjJCUmJygpKissLS4vMDEyMzQ1Njc4OTo7PD0-Pw"
        )
        #expect(
            pkce.codeChallenge
                == "wsNdZaf3VpLTsEDmR5gPk2C6xYVWxKb0xcaG3O6kX10"
        )
        #expect(!state.contains("="))
        #expect(!pkce.codeVerifier.contains("="))
        #expect(!pkce.codeChallenge.contains("="))
    }

    @Test
    func entropySourceMustReturnTheExactRequestedByteCount() {
        #expect(
            throws: CodexLoopbackOAuthError.invalidEntropyLength(
                expected: 32,
                actual: 31
            )
        ) {
            try CodexLoopbackOAuth.makeState { count in
                Array(repeating: 0, count: count - 1)
            }
        }
        #expect(
            throws: CodexLoopbackOAuthError.invalidEntropyLength(
                expected: 64,
                actual: 63
            )
        ) {
            try CodexLoopbackOAuth.makePKCE { count in
                Array(repeating: 0, count: count - 1)
            }
        }
    }

    @Test
    func authorizeURLMatchesOfficialParameterOrderAndEncoding() throws {
        let redirectURI = CodexLoopbackOAuth.redirectURI(port: 1455)
        let url = try CodexLoopbackOAuth.authorizeURL(
            issuer: URL(string: "https://auth.example")!,
            clientID: "client id",
            redirectURI: redirectURI,
            pkce: CodexLoopbackOAuthPKCE(
                codeVerifier: "verifier",
                codeChallenge: "challenge+/="
            ),
            state: "state value",
            allowedWorkspaceIDs: ["workspace-one", "workspace two"]
        )

        #expect(
            url.absoluteString
                == "https://auth.example/oauth/authorize"
                + "?response_type=code"
                + "&client_id=client%20id"
                + "&redirect_uri=http%3A%2F%2Flocalhost%3A1455%2Fauth%2Fcallback"
                + "&scope=openid%20profile%20email%20offline_access%20api.connectors.read%20api.connectors.invoke"
                + "&code_challenge=challenge%2B%2F%3D"
                + "&code_challenge_method=S256"
                + "&id_token_add_organizations=true"
                + "&codex_cli_simplified_flow=true"
                + "&state=state%20value"
                + "&originator=Codex%20Desktop"
                + "&allowed_workspace_id=workspace-one%2Cworkspace%20two"
        )
    }

    @Test
    func authorizeURLOmitsWorkspaceParameterWhenNotRestricted() throws {
        let url = try CodexLoopbackOAuth.authorizeURL(
            issuer: URL(string: "https://auth.example")!,
            clientID: "client",
            redirectURI: CodexLoopbackOAuth.redirectURI(port: 1457),
            pkce: CodexLoopbackOAuthPKCE(
                codeVerifier: "verifier",
                codeChallenge: "challenge"
            ),
            state: "state",
            originator: "codex_cli_rs",
            allowedWorkspaceIDs: nil
        )

        #expect(!url.absoluteString.contains("allowed_workspace_id"))
    }

    @Test
    func callbackParserAcceptsCodeAndPercentDecodesValues() throws {
        let callback = URL(
            string: "http://localhost:1455/auth/callback"
                + "?state=expected%20state&code=authorization%2Bcode"
        )!

        #expect(
            try CodexLoopbackOAuthCallback.authorizationCode(
                from: callback,
                expectedState: "expected state"
            ) == "authorization+code"
        )
    }

    @Test
    func callbackParserRejectsStateAndMissingCode() {
        let wrongState = URL(
            string: "http://localhost:1455/auth/callback"
                + "?state=other&code=code"
        )!
        #expect(
            throws: CodexLoopbackOAuthCallbackError.stateMismatch
        ) {
            try CodexLoopbackOAuthCallback.authorizationCode(
                from: wrongState,
                expectedState: "expected"
            )
        }

        let missingCode = URL(
            string: "http://localhost:1455/auth/callback?state=expected"
        )!
        #expect(
            throws: CodexLoopbackOAuthCallbackError.missingAuthorizationCode
        ) {
            try CodexLoopbackOAuthCallback.authorizationCode(
                from: missingCode,
                expectedState: "expected"
            )
        }
    }

    @Test
    func callbackParserPreservesOAuthErrorAndDescription() {
        let callback = URL(
            string: "http://localhost:1455/auth/callback"
                + "?state=expected&error=access_denied"
                + "&error_description=user%20cancelled"
        )!
        #expect(
            throws: CodexLoopbackOAuthCallbackError.oauthDenied(
                code: "access_denied",
                description: "user cancelled"
            )
        ) {
            try CodexLoopbackOAuthCallback.authorizationCode(
                from: callback,
                expectedState: "expected"
            )
        }
    }

    @Test
    func tokenExchangeUsesExactOfficialFormAndReturnsExistingTokenType() async throws {
        let recorder = RequestRecorder()
        let session = makeSession { request in
            recorder.store(request)
            return try response(
                request: request,
                status: 200,
                body: """
                {
                  "id_token":"header.eyJodHRwczovL2FwaS5vcGVuYWkuY29tL2F1dGgiOnsiY2hhdGdwdF9hY2NvdW50X2lkIjoiYWNjb3VudC0xIn19.signature",
                  "access_token":"SAMPLE_ACCESS",
                  "refresh_token":"SAMPLE_REFRESH"
                }
                """
            )
        }
        defer { session.invalidateAndCancel() }
        let client = CodexLoopbackOAuthTokenClient(
            issuer: URL(string: "https://auth.example")!,
            clientID: "client id",
            session: session
        )

        let tokens = try await client.exchangeAuthorizationCode(
            "code +/=",
            redirectURI: "http://localhost:1455/auth/callback",
            codeVerifier: "verifier +/="
        )
        let request = try #require(recorder.request)
        let body = try #require(
            request.httpBody.flatMap { String(data: $0, encoding: .utf8) }
        )

        #expect(request.url?.absoluteString == "https://auth.example/oauth/token")
        #expect(request.httpMethod == "POST")
        #expect(
            request.value(forHTTPHeaderField: "Content-Type")
                == "application/x-www-form-urlencoded"
        )
        #expect(
            body
                == "grant_type=authorization_code"
                + "&code=code%20%2B%2F%3D"
                + "&redirect_uri=http%3A%2F%2Flocalhost%3A1455%2Fauth%2Fcallback"
                + "&client_id=client%20id"
                + "&code_verifier=verifier%20%2B%2F%3D"
        )
        #expect(tokens.accountID == "account-1")
    }

    @Test
    func tokenExchangeRejectsNonSuccessStatus() async throws {
        let session = makeSession { request in
            try response(request: request, status: 401, body: #"{"error":"denied"}"#)
        }
        defer { session.invalidateAndCancel() }
        let client = makeClient(session: session)

        await #expect(
            throws: CodexLoopbackOAuthError.serverStatus(401)
        ) {
            try await client.exchangeAuthorizationCode(
                "SAMPLE_CODE",
                redirectURI: "http://localhost:1455/auth/callback",
                codeVerifier: "SAMPLE_VERIFIER"
            )
        }
    }

    @Test(
        arguments: [
            #"{"id_token":"header.e30.signature","access_token":"SAMPLE_ACCESS"}"#,
            #"{"id_token":"header.e30.signature","access_token":"","refresh_token":"SAMPLE_REFRESH"}"#,
            #"{"id_token":"header.e30.signature","access_token":"SAMPLE_ACCESS","refresh_token":""}"#,
        ]
    )
    func tokenExchangeRejectsMissingOrEmptyTokens(body: String) async throws {
        let session = makeSession { request in
            try response(request: request, status: 200, body: body)
        }
        defer { session.invalidateAndCancel() }
        let client = makeClient(session: session)

        await #expect(throws: CodexLoopbackOAuthError.invalidResponse) {
            try await client.exchangeAuthorizationCode(
                "SAMPLE_CODE",
                redirectURI: "http://localhost:1455/auth/callback",
                codeVerifier: "SAMPLE_VERIFIER"
            )
        }
    }

    @Test(
        arguments: [
            "not-a-jwt",
            "header..signature",
            "header.invalid_base64.signature",
            "header.W10.signature",
        ]
    )
    func tokenExchangeRejectsStructurallyInvalidIDToken(
        idToken: String
    ) async throws {
        let session = makeSession { request in
            let body = """
                {
                  "id_token":"\(idToken)",
                  "access_token":"SAMPLE_ACCESS",
                  "refresh_token":"SAMPLE_REFRESH"
                }
                """
            return try response(request: request, status: 200, body: body)
        }
        defer { session.invalidateAndCancel() }
        let client = makeClient(session: session)

        await #expect(throws: CodexLoopbackOAuthError.invalidIDToken) {
            try await client.exchangeAuthorizationCode(
                "SAMPLE_CODE",
                redirectURI: "http://localhost:1455/auth/callback",
                codeVerifier: "SAMPLE_VERIFIER"
            )
        }
    }

    private func makeClient(
        session: URLSession
    ) -> CodexLoopbackOAuthTokenClient {
        CodexLoopbackOAuthTokenClient(
            issuer: URL(string: "https://auth.example")!,
            clientID: "client",
            session: session
        )
    }

    private func makeSession(
        handler: @escaping @Sendable (URLRequest) throws
            -> (HTTPURLResponse, Data)
    ) -> URLSession {
        LoopbackOAuthURLProtocolStub.install(handler)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LoopbackOAuthURLProtocolStub.self]
        return URLSession(configuration: configuration)
    }

    private func response(
        request: URLRequest,
        status: Int,
        body: String
    ) throws -> (HTTPURLResponse, Data) {
        let url = try #require(request.url)
        let response = try #require(
            HTTPURLResponse(
                url: url,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )
        )
        return (response, Data(body.utf8))
    }
}

private final class RequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedRequest: URLRequest?

    var request: URLRequest? {
        lock.withLock { storedRequest }
    }

    func store(_ request: URLRequest) {
        var materialized = request
        if materialized.httpBody == nil,
           let stream = materialized.httpBodyStream
        {
            stream.open()
            defer { stream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 1_024)
            while true {
                let count = stream.read(
                    &buffer,
                    maxLength: buffer.count
                )
                guard count > 0 else { break }
                data.append(buffer, count: count)
            }
            materialized.httpBody = data
        }
        lock.withLock {
            storedRequest = materialized
        }
    }
}

private final class LoopbackOAuthURLProtocolStub: URLProtocol {
    typealias Handler = @Sendable (URLRequest) throws
        -> (HTTPURLResponse, Data)

    private static let lock = NSLock()
    nonisolated(unsafe) private static var handler: Handler?

    static func install(_ handler: @escaping Handler) {
        lock.withLock {
            self.handler = handler
        }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let handler = Self.lock.withLock { Self.handler }
        guard let handler else {
            client?.urlProtocol(
                self,
                didFailWithError: URLError(.resourceUnavailable)
            )
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(
                self,
                didReceive: response,
                cacheStoragePolicy: .notAllowed
            )
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
