#if SWIFT_PACKAGE
    import CodexPadDomain
    import CodexPadProtocolBridge
#endif
import Foundation

public enum CodexDesktopMCPOAuthLoopbackError:
    Error,
    Equatable,
    Sendable
{
    case serverNotFound(String)
    case unsupportedTransport
    case bearerTokenConfigured
    case invalidAuthorizationURL
    case timedOut
    case canceled
    case callbackFailed
    case tokenExchangeFailed
    case credentialPersistenceFailed
}

public struct CodexMCPOAuthFlowRequest: Equatable, Sendable {
    public let serverName: String
    public let serverURL: URL
    public let redirectURI: String
    public let state: String
    public let codeChallenge: String
    public let scopes: [String]
    public let configuredClientID: String?
    public let resource: String?
    public let headers: [String: String]

    public init(
        serverName: String,
        serverURL: URL,
        redirectURI: String,
        state: String,
        codeChallenge: String,
        scopes: [String],
        configuredClientID: String?,
        resource: String?,
        headers: [String: String]
    ) {
        self.serverName = serverName
        self.serverURL = serverURL
        self.redirectURI = redirectURI
        self.state = state
        self.codeChallenge = codeChallenge
        self.scopes = scopes
        self.configuredClientID = configuredClientID
        self.resource = resource
        self.headers = headers
    }
}

public struct CodexMCPOAuthPreparedAuthorization:
    Equatable,
    Sendable
{
    public let authorizationURL: URL
    public let tokenEndpoint: URL
    public let clientID: String
    public let resource: String?

    public init(
        authorizationURL: URL,
        tokenEndpoint: URL,
        clientID: String,
        resource: String?
    ) {
        self.authorizationURL = authorizationURL
        self.tokenEndpoint = tokenEndpoint
        self.clientID = clientID
        self.resource = resource
    }
}

public struct CodexMCPOAuthCredential:
    Codable,
    Equatable,
    Sendable
{
    public let accessToken: String
    public let refreshToken: String?
    public let tokenType: String?
    public let scope: String?
    public let expiresAt: Date?
    public let clientID: String
    public let tokenEndpoint: URL

    public init(
        accessToken: String,
        refreshToken: String?,
        tokenType: String?,
        scope: String?,
        expiresAt: Date?,
        clientID: String,
        tokenEndpoint: URL
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.tokenType = tokenType
        self.scope = scope
        self.expiresAt = expiresAt
        self.clientID = clientID
        self.tokenEndpoint = tokenEndpoint
    }
}

public protocol CodexMCPOAuthFlowClient: Sendable {
    func prepareAuthorization(
        _ request: CodexMCPOAuthFlowRequest
    ) async throws -> CodexMCPOAuthPreparedAuthorization

    func exchangeAuthorizationCode(
        _ code: String,
        redirectURI: String,
        codeVerifier: String,
        prepared: CodexMCPOAuthPreparedAuthorization,
        headers: [String: String]
    ) async throws -> CodexMCPOAuthCredential
}

public protocol CodexMCPOAuthCredentialPersisting: Sendable {
    func save(
        _ credential: CodexMCPOAuthCredential,
        serverName: String
    ) async throws
}

public actor CodexDesktopMCPOAuthLoopbackDriver:
    CodexDesktopMCPOAuthSessionDriving
{
    public typealias ConfigurationProvider =
        @Sendable (String) async throws -> CodexMCPServerConfiguration?
    public typealias RuntimeInvalidator = @Sendable () async -> Void

    public static let preferredPorts: [UInt16] = [
        1456, 1458, 1460, 1462,
    ]
    public static let defaultTimeoutSeconds: Int64 = 300

    private struct ActiveSession {
        let server: any CodexLoopbackHTTPServerSession
        let task: Task<Void, Never>
    }

    private let configurationProvider: ConfigurationProvider
    private let serverStarter: any CodexLoopbackHTTPServerStarting
    private let flowClient: any CodexMCPOAuthFlowClient
    private let credentialStore:
        any CodexMCPOAuthCredentialPersisting
    private let invalidateRuntime: RuntimeInvalidator
    private let makeState: @Sendable () throws -> String
    private let makePKCE:
        @Sendable () throws -> CodexLoopbackOAuthPKCE
    private var activeSessions:
        [String: ActiveSession] = [:]

    public init(
        configurationProvider:
            @escaping ConfigurationProvider,
        serverStarter:
            any CodexLoopbackHTTPServerStarting,
        flowClient: any CodexMCPOAuthFlowClient,
        credentialStore:
            any CodexMCPOAuthCredentialPersisting,
        invalidateRuntime:
            @escaping RuntimeInvalidator = {},
        makeState:
            @escaping @Sendable () throws -> String = {
                try CodexLoopbackOAuth.makeState()
            },
        makePKCE:
            @escaping @Sendable () throws
                -> CodexLoopbackOAuthPKCE = {
                    try CodexLoopbackOAuth.makePKCE()
                }
    ) {
        self.configurationProvider = configurationProvider
        self.serverStarter = serverStarter
        self.flowClient = flowClient
        self.credentialStore = credentialStore
        self.invalidateRuntime = invalidateRuntime
        self.makeState = makeState
        self.makePKCE = makePKCE
    }

    public func startMCPOAuthLogin(
        name: String,
        threadID _: String?,
        scopes explicitScopes: [String]?,
        timeoutSeconds: Int64?,
        completion:
            @escaping @Sendable
            (CodexDesktopMCPOAuthSessionCompletion) async -> Void
    ) async throws -> CodexDesktopMCPOAuthSessionStart {
        guard let configuration =
            try await configurationProvider(name)
        else {
            throw CodexDesktopMCPOAuthLoopbackError
                .serverNotFound(name)
        }
        guard case let .streamableHTTP(
            rawURL,
            bearerTokenEnvironmentVariable,
            configuredHeaders,
            _
        ) = configuration.transport
        else {
            throw CodexDesktopMCPOAuthLoopbackError
                .unsupportedTransport
        }
        guard bearerTokenEnvironmentVariable == nil else {
            throw CodexDesktopMCPOAuthLoopbackError
                .bearerTokenConfigured
        }
        guard let serverURL = URL(string: rawURL),
              let scheme = serverURL.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else {
            throw CodexDesktopMCPOAuthLoopbackError
                .invalidAuthorizationURL
        }

        let state = try makeState()
        let pkce = try makePKCE()
        let server = try await serverStarter.start(
            preferredPorts: Self.preferredPorts
        )
        let redirectURI = CodexLoopbackOAuth.redirectURI(
            port: server.port
        )
        let headers = configuredHeaders ?? [:]
        let scopes =
            explicitScopes
            ?? configuration.scopes
            ?? []
        let prepared: CodexMCPOAuthPreparedAuthorization
        do {
            prepared = try await flowClient.prepareAuthorization(
                CodexMCPOAuthFlowRequest(
                    serverName: name,
                    serverURL: serverURL,
                    redirectURI: redirectURI,
                    state: state,
                    codeChallenge: pkce.codeChallenge,
                    scopes: scopes,
                    configuredClientID:
                        configuration.oauthClientID,
                    resource: configuration.oauthResource,
                    headers: headers
                )
            )
        } catch {
            await server.cancel()
            throw error
        }

        if let previous = activeSessions[name] {
            previous.task.cancel()
            await previous.server.cancel()
        }
        let effectiveTimeout =
            timeoutSeconds
            ?? Self.defaultTimeoutSeconds
        let task = Task {
            await self.runSession(
                name: name,
                redirectURI: redirectURI,
                state: state,
                codeVerifier: pkce.codeVerifier,
                headers: headers,
                prepared: prepared,
                timeoutSeconds: effectiveTimeout,
                server: server,
                completion: completion
            )
        }
        activeSessions[name] = ActiveSession(
            server: server,
            task: task
        )
        return CodexDesktopMCPOAuthSessionStart(
            authorizationURL:
                prepared.authorizationURL.absoluteString
        )
    }

    private func runSession(
        name: String,
        redirectURI: String,
        state: String,
        codeVerifier: String,
        headers: [String: String],
        prepared: CodexMCPOAuthPreparedAuthorization,
        timeoutSeconds: Int64,
        server: any CodexLoopbackHTTPServerSession,
        completion:
            @escaping @Sendable
            (CodexDesktopMCPOAuthSessionCompletion) async -> Void
    ) async {
        let operation = Task {
            try await self.finishSession(
                name: name,
                redirectURI: redirectURI,
                state: state,
                codeVerifier: codeVerifier,
                headers: headers,
                prepared: prepared,
                server: server
            )
        }
        let timeout = Task {
            try? await Task.sleep(
                for: .seconds(max(1, timeoutSeconds))
            )
            guard !Task.isCancelled else { return }
            operation.cancel()
            await server.cancel()
        }
        do {
            try await operation.value
            timeout.cancel()
            await completion(.succeeded)
        } catch {
            timeout.cancel()
            await server.cancel()
            let message: String
            if operation.isCancelled {
                message =
                    CodexDesktopMCPOAuthLoopbackError
                    .timedOut.localizedDescription
            } else {
                message = String(describing: error)
            }
            await completion(.failed(message))
        }
        if activeSessions[name]?.task.isCancelled == false {
            activeSessions[name] = nil
        }
    }

    private func finishSession(
        name: String,
        redirectURI: String,
        state: String,
        codeVerifier: String,
        headers: [String: String],
        prepared: CodexMCPOAuthPreparedAuthorization,
        server: any CodexLoopbackHTTPServerSession
    ) async throws {
        let code: String
        do {
            code = try await server.waitForAuthorizationCode(
                expectedState: state
            )
        } catch {
            throw CodexDesktopMCPOAuthLoopbackError.callbackFailed
        }
        let credential: CodexMCPOAuthCredential
        do {
            credential =
                try await flowClient.exchangeAuthorizationCode(
                    code,
                    redirectURI: redirectURI,
                    codeVerifier: codeVerifier,
                    prepared: prepared,
                    headers: headers
                )
        } catch {
            try? await server.finish(
                .failure("Token exchange failed")
            )
            throw CodexDesktopMCPOAuthLoopbackError
                .tokenExchangeFailed
        }
        do {
            try await credentialStore.save(
                credential,
                serverName: name
            )
        } catch {
            try? await server.finish(
                .failure("Credentials could not be saved")
            )
            throw CodexDesktopMCPOAuthLoopbackError
                .credentialPersistenceFailed
        }
        await invalidateRuntime()
        let successURL = URL(
            string: "http://localhost:\(server.port)/success"
        )!
        try await server.finish(
            .success(.local(successURL, streamlined: false))
        )
    }
}

private extension CodexDesktopMCPOAuthLoopbackError {
    var localizedDescription: String {
        switch self {
        case .timedOut: "MCP OAuth login timed out"
        case .canceled: "MCP OAuth login was canceled"
        default: String(describing: self)
        }
    }
}
