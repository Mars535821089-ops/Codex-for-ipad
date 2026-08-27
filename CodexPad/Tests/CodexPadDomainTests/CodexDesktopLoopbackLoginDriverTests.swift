import Foundation
import Testing

@testable import CodexPadApplication
@testable import CodexPadProtocolBridge

@Suite(.serialized)
struct CodexDesktopLoopbackLoginDriverTests {
    @Test
    func startUsesOfficialPortsRedirectAndDesktopOriginatorThenPersists()
        async throws
    {
        let server = LoopbackServerSessionStub(
            port: 1457,
            result: .success("SAMPLE_CODE")
        )
        let starter = LoopbackServerStarterSpy(servers: [server])
        let tokens = try makeTokens(plan: "free")
        let exchanger = LoopbackTokenExchangerSpy(
            result: .success(tokens)
        )
        let persistence = LoopbackPersistenceRecorder(
            adoptedPlan: .plus
        )
        let completions = LoopbackCompletionRecorder()
        let driver = CodexDesktopLoopbackLoginDriver(
            serverStarter: starter,
            tokenExchanger: exchanger,
            makeLoginID: { "login-fixed" },
            makeState: { "state-fixed" },
            makePKCE: {
                .init(
                    codeVerifier: "verifier-fixed",
                    codeChallenge: "challenge-fixed"
                )
            },
            persistAndAdopt: { received in
                try await persistence.persistAndAdopt(received)
            },
            timeout: .seconds(10)
        )

        let started = try await driver.startChatGPTLogin(
            options: .init(
                codexStreamlinedLogin: true,
                useHostedLoginSuccessPage: true,
                appBrand: .codex
            ),
            completion: { completion in
                await completions.append(completion)
            }
        )

        #expect(started.loginID == "login-fixed")
        #expect(
            started.authURL
                == "https://auth.openai.com/oauth/authorize"
                + "?response_type=code"
                + "&client_id=app_EMoamEEZ73f0CkXaXp7hrann"
                + "&redirect_uri=http%3A%2F%2Flocalhost%3A1457%2Fauth%2Fcallback"
                + "&scope=openid%20profile%20email%20offline_access%20api.connectors.read%20api.connectors.invoke"
                + "&code_challenge=challenge-fixed"
                + "&code_challenge_method=S256"
                + "&id_token_add_organizations=true"
                + "&codex_cli_simplified_flow=true"
                + "&state=state-fixed"
                + "&originator=Codex%20Desktop"
        )
        #expect(await starter.requestedPorts() == [[1455, 1457]])

        let completion = await completions.first()
        #expect(
            completion
                == .succeeded(
                    loginID: "login-fixed",
                    planType: .plus
                )
        )
        #expect(
            await exchanger.requests()
                == [
                    .init(
                        authorizationCode: "SAMPLE_CODE",
                        redirectURI:
                            "http://localhost:1457/auth/callback",
                        codeVerifier: "verifier-fixed"
                    )
                ]
        )
        #expect(await persistence.transactions() == [tokens])
        #expect(
            await server.finishes()
                == [
                    .success(
                        .hosted(
                            URL(
                                string:
                                    "https://chatgpt.com/codex/open-app?source=login&app_brand=codex"
                            )!
                        )
                    )
                ]
        )
        #expect(
            await driver.cancelChatGPTLogin(
                loginID: "login-fixed"
            ) == false
        )
    }

    @Test
    func localOnlySuccessRedirectIgnoresHostedRequestAndPreservesLocalClaims()
        async throws
    {
        let server = LoopbackServerSessionStub(
            port: 1457,
            result: .success("SAMPLE_CODE")
        )
        let starter = LoopbackServerStarterSpy(servers: [server])
        let tokens = try makeTokens(
            plan: "plus",
            extraIDClaims: [
                "completed_platform_onboarding": true,
                "organization_id": "org-local",
                "project_id": "project-local",
            ]
        )
        let exchanger = LoopbackTokenExchangerSpy(
            result: .success(tokens)
        )
        let persistence = LoopbackPersistenceRecorder(
            adoptedPlan: .plus
        )
        let completions = LoopbackCompletionRecorder()
        let driver = CodexDesktopLoopbackLoginDriver(
            serverStarter: starter,
            tokenExchanger: exchanger,
            makeLoginID: { "login-local-only" },
            makeState: { "state-fixed" },
            makePKCE: {
                .init(
                    codeVerifier: "verifier-fixed",
                    codeChallenge: "challenge-fixed"
                )
            },
            persistAndAdopt: { received in
                try await persistence.persistAndAdopt(received)
            },
            timeout: .seconds(10),
            successRedirectPolicy: .localOnly
        )

        _ = try await driver.startChatGPTLogin(
            options: .init(
                codexStreamlinedLogin: true,
                useHostedLoginSuccessPage: true,
                appBrand: .codex
            ),
            completion: { completion in
                await completions.append(completion)
            }
        )

        #expect(
            await completions.first()
                == .succeeded(
                    loginID: "login-local-only",
                    planType: .plus
                )
        )
        let finishes = await server.finishes()
        guard case let .success(.local(url, streamlined)) =
            finishes.first
        else {
            Issue.record(
                "local-only policy must finish on the active loopback server"
            )
            return
        }
        #expect(finishes.count == 1)
        #expect(streamlined)
        #expect(url.host == "localhost")
        #expect(url.port == 1457)
        #expect(url.path == "/success")
        let items = Dictionary(
            uniqueKeysWithValues:
                URLComponents(
                    url: url,
                    resolvingAgainstBaseURL: false
                )?.queryItems?.map {
                    ($0.name, $0.value ?? "")
                } ?? []
        )
        #expect(items["id_token"] == tokens.idToken)
        #expect(items["needs_setup"] == "false")
        #expect(items["org_id"] == "org-local")
        #expect(items["project_id"] == "project-local")
        #expect(items["plan_type"] == "plus")
        #expect(items["platform_url"] == "https://platform.openai.com")
        #expect(items["codex_streamlined_login"] == "true")
    }

    @Test
    func localOnlyRealListenerRoundTripRendersSuccessWithoutFollowingHostedURL()
        async throws
    {
        let tokens = try makeTokens(
            plan: "plus",
            extraIDClaims: [
                "completed_platform_onboarding": true
            ]
        )
        let exchanger = LoopbackTokenExchangerSpy(
            result: .success(tokens)
        )
        let persistence = LoopbackPersistenceRecorder(
            adoptedPlan: .plus
        )
        let completions = LoopbackCompletionRecorder()
        let driver = CodexDesktopLoopbackLoginDriver(
            serverStarter: CodexLoopbackHTTPServerFactory(),
            tokenExchanger: exchanger,
            makeLoginID: { "login-real-local-only" },
            makeState: { "state-real-local-only" },
            makePKCE: {
                .init(
                    codeVerifier: "verifier-real-local-only",
                    codeChallenge: "challenge-real-local-only"
                )
            },
            persistAndAdopt: { received in
                try await persistence.persistAndAdopt(received)
            },
            timeout: .seconds(10),
            successRedirectPolicy: .localOnly
        )

        let started = try await driver.startChatGPTLogin(
            options: .init(
                codexStreamlinedLogin: true,
                useHostedLoginSuccessPage: true,
                appBrand: .codex
            ),
            completion: { completion in
                await completions.append(completion)
            }
        )
        let authComponents = try #require(
            URLComponents(string: started.authURL)
        )
        let redirectURI = try #require(
            authComponents.queryItems?.first {
                $0.name == "redirect_uri"
            }?.value
        )
        var callbackComponents = try #require(
            URLComponents(string: redirectURI)
        )
        callbackComponents.queryItems = [
            .init(name: "code", value: "socket-code"),
            .init(name: "state", value: "state-real-local-only"),
        ]
        let callbackURL = try #require(callbackComponents.url)
        let delegate = LoopbackLocalRedirectDelegate()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 10
        let session = URLSession(
            configuration: configuration,
            delegate: delegate,
            delegateQueue: nil
        )

        defer {
            session.invalidateAndCancel()
            Task {
                _ = await driver.cancelChatGPTLogin(
                    loginID: started.loginID
                )
            }
        }

        let (body, response) = try await session.data(
            from: callbackURL
        )
        let httpResponse = try #require(
            response as? HTTPURLResponse
        )
        #expect(httpResponse.statusCode == 200)
        #expect(httpResponse.url?.host == "localhost")
        #expect(httpResponse.url?.path == "/success")
        let renderedPage = String(decoding: body, as: UTF8.self)
        #expect(renderedPage.contains("<h1>Sign-in complete</h1>"))
        #expect(renderedPage.contains("You can return to Codex."))

        let redirects = delegate.redirects()
        #expect(redirects.observed.count == 1)
        #expect(redirects.followed.count == 1)
        #expect(redirects.followed.first?.host == "localhost")
        #expect(redirects.followed.first?.path == "/success")
        #expect(
            !redirects.observed.contains {
                $0.host?.lowercased() == "chatgpt.com"
            }
        )
        #expect(
            await completions.first()
                == .succeeded(
                    loginID: "login-real-local-only",
                    planType: .plus
                )
        )
        #expect(await persistence.transactions() == [tokens])
    }

    @Test
    func cancellationIsScopedToTheLoginIDAndCompletesWithoutTokens()
        async throws
    {
        let server = LoopbackServerSessionStub(port: 1455)
        let starter = LoopbackServerStarterSpy(servers: [server])
        let exchanger = LoopbackTokenExchangerSpy(
            result: .failure(LoopbackTestError.exchange)
        )
        let persistence = LoopbackPersistenceRecorder()
        let completions = LoopbackCompletionRecorder()
        let driver = makeDriver(
            starter: starter,
            exchanger: exchanger,
            persistence: persistence,
            loginIDs: ["login-cancel"]
        )

        _ = try await driver.startChatGPTLogin(
            options: defaultOptions,
            completion: { completion in
                await completions.append(completion)
            }
        )

        #expect(
            await driver.cancelChatGPTLogin(
                loginID: "different-login"
            ) == false
        )
        #expect(
            await driver.cancelChatGPTLogin(
                loginID: "login-cancel"
            )
        )
        #expect(
            await driver.cancelChatGPTLogin(
                loginID: "login-cancel"
            ) == false
        )
        #expect(
            await completions.first()
                == .failed(
                    loginID: "login-cancel",
                    error: "Login was not completed"
                )
        )
        #expect(await server.cancelCount() == 1)
        #expect(await exchanger.requests().isEmpty)
        #expect(await persistence.transactions().isEmpty)
    }

    @Test
    func startingAnotherLoginCancelsAndCleansThePreviousSession()
        async throws
    {
        let firstServer = LoopbackServerSessionStub(port: 1455)
        let secondServer = LoopbackServerSessionStub(port: 1457)
        let starter = LoopbackServerStarterSpy(
            servers: [firstServer, secondServer]
        )
        let exchanger = LoopbackTokenExchangerSpy(
            result: .failure(LoopbackTestError.exchange)
        )
        let persistence = LoopbackPersistenceRecorder()
        let completions = LoopbackCompletionRecorder()
        let driver = makeDriver(
            starter: starter,
            exchanger: exchanger,
            persistence: persistence,
            loginIDs: ["login-first", "login-second"]
        )

        _ = try await driver.startChatGPTLogin(
            options: defaultOptions,
            completion: { completion in
                await completions.append(completion)
            }
        )
        _ = try await driver.startChatGPTLogin(
            options: defaultOptions,
            completion: { completion in
                await completions.append(completion)
            }
        )

        #expect(await firstServer.cancelCount() == 1)
        #expect(
            await completions.first()
                == .failed(
                    loginID: "login-first",
                    error: "Login was not completed"
                )
        )
        #expect(
            await driver.cancelChatGPTLogin(
                loginID: "login-first"
            ) == false
        )
        #expect(
            await driver.cancelChatGPTLogin(
                loginID: "login-second"
            )
        )
        #expect(await secondServer.cancelCount() == 1)
    }

    @Test
    func tokenExchangeFailureFinishesBrowserAndReturnsRedactedFailure()
        async throws
    {
        let server = LoopbackServerSessionStub(
            port: 1455,
            result: .success("SECRET_CODE")
        )
        let starter = LoopbackServerStarterSpy(servers: [server])
        let exchanger = LoopbackTokenExchangerSpy(
            result: .failure(LoopbackTestError.exchange)
        )
        let persistence = LoopbackPersistenceRecorder()
        let completions = LoopbackCompletionRecorder()
        let driver = makeDriver(
            starter: starter,
            exchanger: exchanger,
            persistence: persistence,
            loginIDs: ["login-exchange-failure"]
        )

        _ = try await driver.startChatGPTLogin(
            options: defaultOptions,
            completion: { completion in
                await completions.append(completion)
            }
        )

        let completion = await completions.first()
        #expect(
            completion
                == .failed(
                    loginID: "login-exchange-failure",
                    error: "Token exchange failed"
                )
        )
        #expect(
            await server.finishes()
                == [.failure("Token exchange failed")]
        )
        #expect(await persistence.transactions().isEmpty)
        let rendered = String(describing: completion)
        #expect(!rendered.contains("SECRET_CODE"))
    }

    @Test
    func persistenceTransactionFailureDoesNotCommitAccount() async throws {
        let server = LoopbackServerSessionStub(
            port: 1455,
            result: .success("SAMPLE_CODE")
        )
        let starter = LoopbackServerStarterSpy(servers: [server])
        let tokens = try makeTokens(plan: "pro")
        let exchanger = LoopbackTokenExchangerSpy(
            result: .success(tokens)
        )
        let persistence = LoopbackPersistenceRecorder(
            saveError: LoopbackTestError.persistence
        )
        let completions = LoopbackCompletionRecorder()
        let driver = makeDriver(
            starter: starter,
            exchanger: exchanger,
            persistence: persistence,
            loginIDs: ["login-persist-failure"]
        )

        _ = try await driver.startChatGPTLogin(
            options: defaultOptions,
            completion: { completion in
                await completions.append(completion)
            }
        )

        #expect(
            await completions.first()
                == .failed(
                    loginID: "login-persist-failure",
                    error: "Credentials could not be saved"
                )
        )
        #expect(await persistence.transactions().isEmpty)
        #expect(
            await server.finishes()
                == [.failure("Credentials could not be saved")]
        )
    }

    @Test
    func workspaceRestrictionRejectsMissingAndMismatchedAccountsBeforeSave()
        async throws
    {
        let cases: [
            (
                accountID: String?,
                expectedMessage: String
            )
        ] = [
            (
                nil,
                "Login is restricted to a specific workspace, "
                    + "but the token did not include an "
                    + "chatgpt_account_id claim."
            ),
            (
                "workspace-other",
                "Login is restricted to workspace id(s) "
                    + "workspace-allowed."
            ),
        ]

        for (index, testCase) in cases.enumerated() {
            let server = LoopbackServerSessionStub(
                port: 1455,
                result: .success("SAMPLE_CODE")
            )
            let starter = LoopbackServerStarterSpy(
                servers: [server]
            )
            let tokens = try makeTokens(
                plan: "plus",
                accountID: testCase.accountID
            )
            let exchanger = LoopbackTokenExchangerSpy(
                result: .success(tokens)
            )
            let persistence = LoopbackPersistenceRecorder()
            let completions = LoopbackCompletionRecorder()
            let driver = makeDriver(
                starter: starter,
                exchanger: exchanger,
                persistence: persistence,
                loginIDs: ["login-workspace-\(index)"],
                allowedWorkspaceIDs: ["workspace-allowed"]
            )

            _ = try await driver.startChatGPTLogin(
                options: defaultOptions,
                completion: { completion in
                    await completions.append(completion)
                }
            )

            #expect(
                await completions.first()
                    == .failed(
                        loginID: "login-workspace-\(index)",
                        error: testCase.expectedMessage
                    )
            )
            #expect(await persistence.transactions().isEmpty)
            #expect(
                await server.finishes()
                    == [.failure(testCase.expectedMessage)]
            )
        }
    }

    @Test
    func hostedLoginPreservesChatGPTBrandAndSetupFallsBackLocal()
        throws
    {
        let ordinary = try makeTokens(plan: "plus")
        #expect(
            CodexDesktopLoopbackSuccessRedirect.compose(
                port: 1455,
                issuer: CodexLoopbackOAuth.defaultIssuer,
                tokens: ordinary,
                options: .init(
                    codexStreamlinedLogin: true,
                    useHostedLoginSuccessPage: true,
                    appBrand: .chatGPT
                )
            )
                == .hosted(
                    URL(
                        string:
                            "https://chatgpt.com/codex/open-app?source=login&app_brand=chatgpt"
                    )!
                )
        )

        let setupTokens = try makeTokens(
            plan: "team",
            extraIDClaims: [
                "completed_platform_onboarding": false,
                "is_org_owner": true,
                "organization_id": "org-1",
                "project_id": "project-1",
            ]
        )
        let redirect =
            CodexDesktopLoopbackSuccessRedirect.compose(
                port: 1457,
                issuer: CodexLoopbackOAuth.defaultIssuer,
                tokens: setupTokens,
                options: .init(
                    codexStreamlinedLogin: true,
                    useHostedLoginSuccessPage: true,
                    appBrand: .codex
                )
            )
        guard case let .local(url, streamlined) = redirect else {
            Issue.record("setup-required login must use local success page")
            return
        }
        #expect(streamlined)
        #expect(url.host == "localhost")
        #expect(url.port == 1457)
        #expect(url.path == "/success")
        let items = Dictionary(
            uniqueKeysWithValues:
                URLComponents(
                    url: url,
                    resolvingAgainstBaseURL: false
                )?.queryItems?.map {
                    ($0.name, $0.value ?? "")
                } ?? []
        )
        #expect(items["needs_setup"] == "true")
        #expect(items["org_id"] == "org-1")
        #expect(items["project_id"] == "project-1")
        #expect(items["codex_streamlined_login"] == "true")
        #expect(items["id_token"] == setupTokens.idToken)
    }

    @Test
    func planTypeUsesAccessTokenRawMappingIncludingAliasesAndUnknown()
        throws
    {
        let expected: [(String, CodexDesktopMCPPlanType)] = [
            ("free", .free),
            ("go", .go),
            ("plus", .plus),
            ("pro", .pro),
            ("prolite", .proLite),
            ("team", .team),
            (
                "self_serve_business_usage_based",
                .selfServeBusinessUsageBased
            ),
            ("business", .business),
            (
                "enterprise_cbp_usage_based",
                .enterpriseCBPUsageBased
            ),
            ("enterprise", .enterprise),
            ("hc", .enterprise),
            ("education", .edu),
            ("edu", .edu),
            ("future_plan", .unknown),
        ]

        for (rawValue, planType) in expected {
            let tokens = try makeTokens(plan: rawValue)
            #expect(
                CodexDesktopLoopbackSuccessRedirect.planType(
                    fromAccessToken: tokens.accessToken
                ) == planType
            )
        }
        #expect(
            CodexDesktopLoopbackSuccessRedirect.planType(
                fromAccessToken: "not-a-jwt"
            ) == nil
        )
        #expect(
            CodexDesktopLoopbackSuccessRedirect.planType(
                fromAccessToken: try makeAccessToken(plan: nil)
            ) == nil
        )
    }

    @Test
    func officialTenMinuteTimeoutCanBeInjectedAndCancelsListener()
        async throws
    {
        let server = LoopbackServerSessionStub(port: 1455)
        let starter = LoopbackServerStarterSpy(servers: [server])
        let exchanger = LoopbackTokenExchangerSpy(
            result: .failure(LoopbackTestError.exchange)
        )
        let persistence = LoopbackPersistenceRecorder()
        let completions = LoopbackCompletionRecorder()
        let driver = makeDriver(
            starter: starter,
            exchanger: exchanger,
            persistence: persistence,
            loginIDs: ["login-timeout"],
            timeout: .milliseconds(10)
        )

        _ = try await driver.startChatGPTLogin(
            options: defaultOptions,
            completion: { completion in
                await completions.append(completion)
            }
        )

        #expect(
            await completions.first()
                == .failed(
                    loginID: "login-timeout",
                    error: "Login timed out"
                )
        )
        #expect(await server.cancelCount() == 1)
        #expect(await persistence.transactions().isEmpty)
    }

    private var defaultOptions: CodexDesktopChatGPTLoginOptions {
        .init(
            codexStreamlinedLogin: false,
            useHostedLoginSuccessPage: false,
            appBrand: nil
        )
    }

    private func makeDriver(
        starter: LoopbackServerStarterSpy,
        exchanger: LoopbackTokenExchangerSpy,
        persistence: LoopbackPersistenceRecorder,
        loginIDs: [String],
        timeout: Duration = .seconds(10),
        allowedWorkspaceIDs: [String]? = nil
    ) -> CodexDesktopLoopbackLoginDriver {
        let ids = LoopbackLoginIDSource(values: loginIDs)
        return CodexDesktopLoopbackLoginDriver(
            serverStarter: starter,
            tokenExchanger: exchanger,
            makeLoginID: { await ids.next() },
            makeState: { "state-fixed" },
            makePKCE: {
                .init(
                    codeVerifier: "verifier-fixed",
                    codeChallenge: "challenge-fixed"
                )
            },
            persistAndAdopt: { tokens in
                try await persistence.persistAndAdopt(tokens)
            },
            timeout: timeout,
            allowedWorkspaceIDs: allowedWorkspaceIDs
        )
    }

    private func makeTokens(
        plan: String,
        accountID: String? = "account-1",
        extraIDClaims: [String: Any] = [:]
    ) throws -> CodexChatGPTTokens {
        var idClaims: [String: Any] = [
            "chatgpt_plan_type": plan
        ]
        if let accountID {
            idClaims["chatgpt_account_id"] = accountID
        }
        extraIDClaims.forEach { idClaims[$0] = $1 }
        let payload = try JSONSerialization.data(
            withJSONObject: [
                "https://api.openai.com/auth": idClaims
            ]
        )
        let encoded = payload
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return try CodexChatGPTTokens(
            idToken: "header.\(encoded).signature",
            accessToken: makeAccessToken(plan: plan),
            refreshToken: "SAMPLE_REFRESH"
        )
    }

    private func makeAccessToken(
        plan: String?
    ) throws -> String {
        var auth: [String: Any] = [:]
        if let plan {
            auth["chatgpt_plan_type"] = plan
        }
        let accessPayload = try JSONSerialization.data(
            withJSONObject: [
                "https://api.openai.com/auth": auth
            ]
        )
        let accessEncoded = accessPayload
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "header.\(accessEncoded).signature"
    }
}

private enum LoopbackTestError: Error, Sendable {
    case exchange
    case persistence
}

private struct LoopbackTokenExchangeRequest:
    Equatable,
    Sendable
{
    let authorizationCode: String
    let redirectURI: String
    let codeVerifier: String
}

private actor LoopbackTokenExchangerSpy:
    CodexLoopbackOAuthTokenExchanging
{
    private let result: Result<CodexChatGPTTokens, any Error>
    private var recordedRequests: [LoopbackTokenExchangeRequest] = []

    init(result: Result<CodexChatGPTTokens, any Error>) {
        self.result = result
    }

    func exchangeAuthorizationCode(
        _ authorizationCode: String,
        redirectURI: String,
        codeVerifier: String
    ) async throws -> CodexChatGPTTokens {
        recordedRequests.append(
            .init(
                authorizationCode: authorizationCode,
                redirectURI: redirectURI,
                codeVerifier: codeVerifier
            )
        )
        return try result.get()
    }

    func requests() -> [LoopbackTokenExchangeRequest] {
        recordedRequests
    }
}

private actor LoopbackServerStarterSpy:
    CodexLoopbackHTTPServerStarting
{
    private var servers: [LoopbackServerSessionStub]
    private var ports: [[UInt16]] = []

    init(servers: [LoopbackServerSessionStub]) {
        self.servers = servers
    }

    func start(
        preferredPorts: [UInt16]
    ) async throws -> any CodexLoopbackHTTPServerSession {
        ports.append(preferredPorts)
        guard !servers.isEmpty else {
            throw CodexLoopbackHTTPServerError.addressUnavailable
        }
        return servers.removeFirst()
    }

    func requestedPorts() -> [[UInt16]] {
        ports
    }
}

private actor LoopbackServerSessionStub:
    CodexLoopbackHTTPServerSession
{
    nonisolated let port: UInt16
    private let immediateResult: Result<String, any Error>?
    private var waiter: CheckedContinuation<String, any Error>?
    private var recordedFinishes:
        [CodexLoopbackHTTPCallbackFinish] = []
    private var cancellations = 0

    init(
        port: UInt16,
        result: Result<String, any Error>? = nil
    ) {
        self.port = port
        immediateResult = result
    }

    func waitForAuthorizationCode(
        expectedState _: String
    ) async throws -> String {
        if let immediateResult {
            return try immediateResult.get()
        }
        return try await withCheckedThrowingContinuation {
            waiter = $0
        }
    }

    func finish(
        _ result: CodexLoopbackHTTPCallbackFinish
    ) async throws {
        recordedFinishes.append(result)
    }

    func cancel() async {
        cancellations += 1
        waiter?.resume(
            throwing: CodexLoopbackHTTPServerError.canceled
        )
        waiter = nil
    }

    func finishes() -> [CodexLoopbackHTTPCallbackFinish] {
        recordedFinishes
    }

    func cancelCount() -> Int {
        cancellations
    }
}

private actor LoopbackPersistenceRecorder {
    private let saveError: (any Error)?
    private let adoptedPlan: CodexDesktopMCPPlanType?
    private var persistedTokens: [CodexChatGPTTokens] = []

    init(
        saveError: (any Error)? = nil,
        adoptedPlan: CodexDesktopMCPPlanType? = nil
    ) {
        self.saveError = saveError
        self.adoptedPlan = adoptedPlan
    }

    func persistAndAdopt(
        _ tokens: CodexChatGPTTokens
    ) throws -> CodexDesktopMCPPlanType? {
        if let saveError {
            throw saveError
        }
        persistedTokens.append(tokens)
        return adoptedPlan
    }

    func transactions() -> [CodexChatGPTTokens] {
        persistedTokens
    }
}

private actor LoopbackCompletionRecorder {
    private var values: [CodexDesktopLoginSessionCompletion] = []
    private var waiters:
        [CheckedContinuation<CodexDesktopLoginSessionCompletion, Never>] = []

    func append(_ completion: CodexDesktopLoginSessionCompletion) {
        if let waiter = waiters.first {
            waiters.removeFirst()
            waiter.resume(returning: completion)
        } else {
            values.append(completion)
        }
    }

    func first() async -> CodexDesktopLoginSessionCompletion {
        if !values.isEmpty {
            return values.removeFirst()
        }
        return await withCheckedContinuation {
            waiters.append($0)
        }
    }
}

private actor LoopbackLoginIDSource {
    private var values: [String]

    init(values: [String]) {
        self.values = values
    }

    func next() -> String {
        values.removeFirst()
    }
}

private final class LoopbackLocalRedirectDelegate:
    NSObject,
    URLSessionTaskDelegate,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var observedRedirects: [URL] = []
    private var followedRedirects: [URL] = []

    func urlSession(
        _: URLSession,
        task _: URLSessionTask,
        willPerformHTTPRedirection _: HTTPURLResponse,
        newRequest: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let redirectURL = newRequest.url else {
            completionHandler(nil)
            return
        }
        let followsRedirect =
            redirectURL.scheme?.lowercased() == "http"
            && redirectURL.host?.lowercased() == "localhost"
            && redirectURL.path == "/success"

        lock.lock()
        observedRedirects.append(redirectURL)
        if followsRedirect {
            followedRedirects.append(redirectURL)
        }
        lock.unlock()

        completionHandler(
            followsRedirect ? newRequest : nil
        )
    }

    func redirects() -> (
        observed: [URL],
        followed: [URL]
    ) {
        lock.lock()
        defer { lock.unlock() }
        return (observedRedirects, followedRedirects)
    }
}
