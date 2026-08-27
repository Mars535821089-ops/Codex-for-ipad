#if SWIFT_PACKAGE
    import CodexPadProtocolBridge
#endif
import Foundation

public protocol CodexLoopbackOAuthTokenExchanging: Sendable {
    func exchangeAuthorizationCode(
        _ authorizationCode: String,
        redirectURI: String,
        codeVerifier: String
    ) async throws -> CodexChatGPTTokens
}

extension CodexLoopbackOAuthTokenClient:
    CodexLoopbackOAuthTokenExchanging
{}

public enum CodexDesktopLoginSuccessRedirectPolicy: Sendable {
    case honorRequest
    case localOnly
}

public actor CodexDesktopLoopbackLoginDriver:
    CodexDesktopLoginSessionDriving
{
    public typealias LoginIDFactory =
        @Sendable () async -> String
    public typealias StateFactory =
        @Sendable () throws -> String
    public typealias PKCEFactory =
        @Sendable () throws -> CodexLoopbackOAuthPKCE
    public typealias PersistAndAdopt =
        @Sendable
        (CodexChatGPTTokens) async throws -> CodexDesktopMCPPlanType?

    public static let preferredPorts: [UInt16] = [1455, 1457]
    public static let officialTimeout: Duration = .seconds(600)

    private struct ActiveSession {
        let loginID: String
        let server: any CodexLoopbackHTTPServerSession
        let task: Task<Void, Never>
    }

    private enum SessionFailure: Error, Sendable {
        case canceled
        case timedOut
        case callback
        case tokenExchange
        case workspaceRestriction(String)
        case credentialPersistence
        case browserCompletion

        var message: String {
            switch self {
            case .canceled:
                return "Login was not completed"
            case .timedOut:
                return "Login timed out"
            case .callback:
                return "OAuth callback rejected"
            case .tokenExchange:
                return "Token exchange failed"
            case let .workspaceRestriction(message):
                return message
            case .credentialPersistence:
                return "Credentials could not be saved"
            case .browserCompletion:
                return "Login completion page failed"
            }
        }

        var shouldRenderFailurePage: Bool {
            switch self {
            case .tokenExchange,
                 .workspaceRestriction,
                 .credentialPersistence:
                return true
            case .canceled,
                 .timedOut,
                 .callback,
                 .browserCompletion:
                return false
            }
        }
    }

    private enum RaceResult: Sendable {
        case operation(
            Result<CodexDesktopMCPPlanType?, SessionFailure>
        )
        case timedOut
        case timerCanceled
    }

    private let serverStarter:
        any CodexLoopbackHTTPServerStarting
    private let tokenExchanger:
        any CodexLoopbackOAuthTokenExchanging
    private let makeLoginID: LoginIDFactory
    private let makeState: StateFactory
    private let makePKCE: PKCEFactory
    private let persistAndAdopt: PersistAndAdopt
    private let timeout: Duration
    private let issuer: URL
    private let clientID: String
    private let originator: String
    private let allowedWorkspaceIDs: [String]?
    private let successRedirectPolicy:
        CodexDesktopLoginSuccessRedirectPolicy

    private var activeSession: ActiveSession?

    public init(
        serverStarter:
            any CodexLoopbackHTTPServerStarting,
        tokenExchanger:
            any CodexLoopbackOAuthTokenExchanging,
        makeLoginID:
            @escaping LoginIDFactory = {
                UUID().uuidString
            },
        makeState:
            @escaping StateFactory = {
                try CodexLoopbackOAuth.makeState()
            },
        makePKCE:
            @escaping PKCEFactory = {
                try CodexLoopbackOAuth.makePKCE()
            },
        persistAndAdopt:
            @escaping PersistAndAdopt,
        timeout: Duration = officialTimeout,
        issuer: URL = CodexLoopbackOAuth.defaultIssuer,
        clientID: String = CodexLoopbackOAuth.defaultClientID,
        originator: String = CodexLoopbackOAuth.desktopOriginator,
        allowedWorkspaceIDs: [String]? = nil,
        successRedirectPolicy:
            CodexDesktopLoginSuccessRedirectPolicy = .honorRequest
    ) {
        self.serverStarter = serverStarter
        self.tokenExchanger = tokenExchanger
        self.makeLoginID = makeLoginID
        self.makeState = makeState
        self.makePKCE = makePKCE
        self.persistAndAdopt = persistAndAdopt
        self.timeout = timeout
        self.issuer = issuer
        self.clientID = clientID
        self.originator = originator
        self.allowedWorkspaceIDs = allowedWorkspaceIDs
        self.successRedirectPolicy = successRedirectPolicy
    }

    public func startChatGPTLogin(
        options: CodexDesktopChatGPTLoginOptions,
        completion:
            @escaping @Sendable
            (CodexDesktopLoginSessionCompletion) async -> Void
    ) async throws -> CodexDesktopLoginSessionStart {
        let state = try makeState()
        let pkce = try makePKCE()
        let server = try await serverStarter.start(
            preferredPorts: Self.preferredPorts
        )
        let redirectURI = CodexLoopbackOAuth.redirectURI(
            port: server.port
        )

        let authorizeURL: URL
        do {
            authorizeURL = try CodexLoopbackOAuth.authorizeURL(
                issuer: issuer,
                clientID: clientID,
                redirectURI: redirectURI,
                pkce: pkce,
                state: state,
                originator: originator,
                allowedWorkspaceIDs: allowedWorkspaceIDs
            )
        } catch {
            await server.cancel()
            throw error
        }

        let loginID = await makeLoginID()
        let previous = activeSession
        let task = Task {
            await self.runSession(
                loginID: loginID,
                state: state,
                pkce: pkce,
                redirectURI: redirectURI,
                options: options,
                server: server,
                completion: completion
            )
        }
        activeSession = ActiveSession(
            loginID: loginID,
            server: server,
            task: task
        )

        if let previous {
            previous.task.cancel()
            await previous.server.cancel()
        }

        return CodexDesktopLoginSessionStart(
            loginID: loginID,
            authURL: authorizeURL.absoluteString
        )
    }

    public func cancelChatGPTLogin(
        loginID: String
    ) async -> Bool {
        guard let session = activeSession,
              session.loginID == loginID
        else {
            return false
        }
        activeSession = nil
        session.task.cancel()
        await session.server.cancel()
        return true
    }

    private func runSession(
        loginID: String,
        state: String,
        pkce: CodexLoopbackOAuthPKCE,
        redirectURI: String,
        options: CodexDesktopChatGPTLoginOptions,
        server: any CodexLoopbackHTTPServerSession,
        completion:
            @escaping @Sendable
            (CodexDesktopLoginSessionCompletion) async -> Void
    ) async {
        let result: Result<
            CodexDesktopMCPPlanType?,
            SessionFailure
        >
        if Task.isCancelled {
            result = .failure(.canceled)
        } else {
            result = await raceSessionAgainstTimeout(
                state: state,
                pkce: pkce,
                redirectURI: redirectURI,
                options: options,
                server: server
            )
        }

        let sessionCompletion: CodexDesktopLoginSessionCompletion
        switch result {
        case let .success(planType):
            sessionCompletion = .succeeded(
                loginID: loginID,
                planType: planType
            )

        case let .failure(failure):
            if failure.shouldRenderFailurePage {
                try? await server.finish(
                    .failure(failure.message)
                )
            }
            sessionCompletion = .failed(
                loginID: loginID,
                error: failure.message
            )
        }

        if activeSession?.loginID == loginID {
            activeSession = nil
        }
        await completion(sessionCompletion)
    }

    private func raceSessionAgainstTimeout(
        state: String,
        pkce: CodexLoopbackOAuthPKCE,
        redirectURI: String,
        options: CodexDesktopChatGPTLoginOptions,
        server: any CodexLoopbackHTTPServerSession
    ) async -> Result<
        CodexDesktopMCPPlanType?,
        SessionFailure
    > {
        await withTaskGroup(of: RaceResult.self) { group in
            group.addTask {
                do {
                    return .operation(
                        .success(
                            try await self.performSession(
                                state: state,
                                pkce: pkce,
                                redirectURI: redirectURI,
                                options: options,
                                server: server
                            )
                        )
                    )
                } catch let failure as SessionFailure {
                    return .operation(.failure(failure))
                } catch {
                    return .operation(.failure(.callback))
                }
            }
            group.addTask {
                do {
                    try await Task.sleep(for: self.timeout)
                    return .timedOut
                } catch {
                    return .timerCanceled
                }
            }

            guard let first = await group.next() else {
                await server.cancel()
                return .failure(.canceled)
            }
            group.cancelAll()

            switch first {
            case let .operation(result):
                return result

            case .timedOut:
                await server.cancel()
                return .failure(.timedOut)

            case .timerCanceled:
                return .failure(.canceled)
            }
        }
    }

    private func performSession(
        state: String,
        pkce: CodexLoopbackOAuthPKCE,
        redirectURI: String,
        options: CodexDesktopChatGPTLoginOptions,
        server: any CodexLoopbackHTTPServerSession
    ) async throws -> CodexDesktopMCPPlanType? {
        try requireNotCanceled()

        let authorizationCode: String
        do {
            authorizationCode =
                try await server.waitForAuthorizationCode(
                    expectedState: state
                )
        } catch {
            if Task.isCancelled {
                throw SessionFailure.canceled
            }
            if case CodexLoopbackHTTPServerError.canceled = error {
                throw SessionFailure.canceled
            }
            throw SessionFailure.callback
        }

        try requireNotCanceled()
        let tokens: CodexChatGPTTokens
        do {
            tokens =
                try await tokenExchanger
                .exchangeAuthorizationCode(
                    authorizationCode,
                    redirectURI: redirectURI,
                    codeVerifier: pkce.codeVerifier
                )
        } catch {
            if Task.isCancelled {
                throw SessionFailure.canceled
            }
            throw SessionFailure.tokenExchange
        }

        try requireNotCanceled()
        if let message =
            CodexDesktopLoopbackSuccessRedirect
            .workspaceRestrictionMessage(
                allowedWorkspaceIDs: allowedWorkspaceIDs,
                idToken: tokens.idToken
            )
        {
            throw SessionFailure.workspaceRestriction(message)
        }

        try requireNotCanceled()
        let planType: CodexDesktopMCPPlanType?
        do {
            planType = try await persistAndAdopt(tokens)
        } catch {
            if Task.isCancelled {
                throw SessionFailure.canceled
            }
            throw SessionFailure.credentialPersistence
        }

        try requireNotCanceled()
        let redirect =
            CodexDesktopLoopbackSuccessRedirect.compose(
                port: server.port,
                issuer: issuer,
                tokens: tokens,
                options: options,
                successRedirectPolicy: successRedirectPolicy
            )
        do {
            try await server.finish(.success(redirect))
        } catch {
            if Task.isCancelled {
                throw SessionFailure.canceled
            }
            throw SessionFailure.browserCompletion
        }
        return planType
    }

    private func requireNotCanceled() throws {
        guard !Task.isCancelled else {
            throw SessionFailure.canceled
        }
    }
}

enum CodexDesktopLoopbackSuccessRedirect {
    private static let authClaim =
        "https://api.openai.com/auth"
    private static let hostedSuccessURL =
        "https://chatgpt.com/codex/open-app"

    static func compose(
        port: UInt16,
        issuer: URL,
        tokens: CodexChatGPTTokens,
        options: CodexDesktopChatGPTLoginOptions,
        successRedirectPolicy:
            CodexDesktopLoginSuccessRedirectPolicy = .honorRequest
    ) -> CodexLoopbackHTTPSuccessRedirect {
        let idClaims = authClaims(from: tokens.idToken)
        let completedOnboarding =
            idClaims["completed_platform_onboarding"]
                as? Bool ?? false
        let isOrganizationOwner =
            idClaims["is_org_owner"] as? Bool ?? false
        let needsSetup =
            !completedOnboarding && isOrganizationOwner

        let allowsHostedSuccessPage: Bool
        switch successRedirectPolicy {
        case .honorRequest:
            allowsHostedSuccessPage =
                options.useHostedLoginSuccessPage
        case .localOnly:
            allowsHostedSuccessPage = false
        }

        if allowsHostedSuccessPage,
           !needsSetup
        {
            let brand = options.appBrand ?? .codex
            let url = URL(
                string:
                    "\(hostedSuccessURL)"
                    + "?source=login"
                    + "&app_brand=\(brand.rawValue)"
            )!
            return .hosted(url)
        }

        let organizationID =
            idClaims["organization_id"] as? String ?? ""
        let projectID =
            idClaims["project_id"] as? String ?? ""
        let rawPlanType =
            authClaims(from: tokens.accessToken)[
                "chatgpt_plan_type"
            ] as? String ?? ""
        let platformURL =
            issuer.absoluteString
                == CodexLoopbackOAuth.defaultIssuer.absoluteString
            ? "https://platform.openai.com"
            : "https://platform.api.openai.org"

        var query: [(String, String)] = [
            ("id_token", tokens.idToken),
            ("needs_setup", needsSetup ? "true" : "false"),
            ("org_id", organizationID),
            ("project_id", projectID),
            ("plan_type", rawPlanType),
            ("platform_url", platformURL),
        ]
        if options.codexStreamlinedLogin {
            query.append(
                ("codex_streamlined_login", "true")
            )
        }
        let encodedQuery = query.map {
            "\($0.0)=\(percentEncode($0.1))"
        }
        .joined(separator: "&")
        let url = URL(
            string:
                "http://localhost:\(port)/success?"
                + encodedQuery
        )!
        return .local(
            url,
            streamlined: options.codexStreamlinedLogin
        )
    }

    static func planType(
        fromAccessToken token: String
    ) -> CodexDesktopMCPPlanType? {
        guard let rawValue =
            authClaims(from: token)["chatgpt_plan_type"]
                as? String,
              !rawValue.isEmpty
        else {
            return nil
        }
        switch rawValue.lowercased() {
        case "free":
            return .free
        case "go":
            return .go
        case "plus":
            return .plus
        case "pro":
            return .pro
        case "prolite":
            return .proLite
        case "team":
            return .team
        case "self_serve_business_usage_based":
            return .selfServeBusinessUsageBased
        case "business":
            return .business
        case "enterprise_cbp_usage_based":
            return .enterpriseCBPUsageBased
        case "enterprise", "hc":
            return .enterprise
        case "education", "edu":
            return .edu
        default:
            return .unknown
        }
    }

    static func workspaceRestrictionMessage(
        allowedWorkspaceIDs: [String]?,
        idToken: String
    ) -> String? {
        guard let allowedWorkspaceIDs else {
            return nil
        }
        guard let actualWorkspaceID =
            authClaims(from: idToken)[
                "chatgpt_account_id"
            ] as? String
        else {
            return
                "Login is restricted to a specific workspace, "
                + "but the token did not include an "
                + "chatgpt_account_id claim."
        }
        guard allowedWorkspaceIDs.contains(actualWorkspaceID) else {
            return
                "Login is restricted to workspace id(s) "
                + "\(allowedWorkspaceIDs.joined(separator: ", "))."
        }
        return nil
    }

    private static func authClaims(
        from token: String
    ) -> [String: Any] {
        let parts = token.split(
            separator: ".",
            omittingEmptySubsequences: false
        )
        guard parts.count == 3,
              parts.allSatisfy({ !$0.isEmpty })
        else {
            return [:]
        }
        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        payload.append(
            String(
                repeating: "=",
                count: (4 - payload.count % 4) % 4
            )
        )
        guard let data = Data(base64Encoded: payload),
              let object =
                  try? JSONSerialization.jsonObject(
                      with: data
                  ) as? [String: Any],
              let claims = object[authClaim]
                  as? [String: Any]
        else {
            return [:]
        }
        return claims
    }

    private static func percentEncode(
        _ value: String
    ) -> String {
        var result = ""
        result.reserveCapacity(value.utf8.count)
        for byte in value.utf8 {
            switch byte {
            case 65...90,
                 97...122,
                 48...57,
                 45,
                 46,
                 95,
                 126:
                result.unicodeScalars.append(
                    UnicodeScalar(byte)
                )
            default:
                result.append("%")
                result.append(hexDigit(byte >> 4))
                result.append(hexDigit(byte & 0x0F))
            }
        }
        return result
    }

    private static func hexDigit(
        _ nibble: UInt8
    ) -> Character {
        Character(
            UnicodeScalar(
                nibble < 10 ? nibble + 48 : nibble + 55
            )
        )
    }
}
