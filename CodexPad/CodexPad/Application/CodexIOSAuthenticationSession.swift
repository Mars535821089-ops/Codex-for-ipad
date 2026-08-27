#if os(iOS)
import AuthenticationServices
import Foundation
import UIKit

/// Legacy iOS OAuth session retained for source compatibility only.
/// Production login uses `CodexDesktopLoopbackLoginDriver`, because
/// `ASWebAuthenticationSession` cannot match an HTTP localhost callback.
@MainActor
private final class CodexIOSAuthenticationSessionHandle: NSObject,
    ASWebAuthenticationPresentationContextProviding,
    @unchecked Sendable
{
    private let authorizeURL: URL
    private let callbackURLScheme: String
    private var session: ASWebAuthenticationSession?
    private var continuation: CheckedContinuation<URL, Error>?
    private var didFinish = false

    init(authorizeURL: URL, callbackURLScheme: String) {
        self.authorizeURL = authorizeURL
        self.callbackURLScheme = callbackURLScheme
    }

    func startAndWait() async throws -> URL {
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                guard !didFinish else {
                    continuation.resume(
                        throwing: CodexIOSAuthenticationError.canceled
                    )
                    return
                }
                self.continuation = continuation
                let session = ASWebAuthenticationSession(
                    url: authorizeURL,
                    callbackURLScheme: callbackURLScheme
                ) { [weak self] callbackURL, error in
                    guard let self else { return }
                    if let error {
                        self.finish(throwing: error)
                    } else if let callbackURL {
                        self.finish(returning: callbackURL)
                    } else {
                        self.finish(
                            throwing: CodexIOSAuthenticationError.callbackMissing
                        )
                    }
                }
                session.presentationContextProvider = self
                session.prefersEphemeralWebBrowserSession = false
                self.session = session
                guard session.start() else {
                    self.finish(
                        throwing: CodexIOSAuthenticationError.startFailed
                    )
                    return
                }
            }
        }, onCancel: {
            Task { @MainActor [weak self] in
                self?.cancel()
            }
        })
    }

    func cancel() {
        guard !didFinish else { return }
        session?.cancel()
        finish(throwing: CodexIOSAuthenticationError.canceled)
    }

    func presentationAnchor(
        for _: ASWebAuthenticationSession
    ) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first(where: { $0.activationState == .foregroundActive })?
            .windows
            .first(where: { $0.isKeyWindow })
            ?? ASPresentationAnchor()
    }

    private func finish(returning url: URL) {
        finish(with: .success(url))
    }

    private func finish(throwing error: Error) {
        finish(with: .failure(error))
    }

    private func finish(with result: Result<URL, Error>) {
        guard !didFinish else { return }
        didFinish = true
        session = nil
        let continuation = continuation
        self.continuation = nil
        switch result {
        case let .success(url): continuation?.resume(returning: url)
        case let .failure(error): continuation?.resume(throwing: error)
        }
    }
}

public actor CodexIOSAuthenticationSessionDriver:
    CodexDesktopLoginSessionDriving
{
    public typealias LoginIDFactory = @Sendable () async -> String
    public typealias StateFactory = @Sendable () throws -> String
    public typealias PKCEFactory = @Sendable () throws -> CodexLoopbackOAuthPKCE
    public typealias PersistAndAdopt = @Sendable
        (CodexChatGPTTokens) async throws -> CodexDesktopMCPPlanType?

    private struct ActiveSession {
        let loginID: String
        let handle: CodexIOSAuthenticationSessionHandle
        let task: Task<Void, Never>
    }

    private let issuer: URL
    private let loginIDFactory: LoginIDFactory
    private let stateFactory: StateFactory
    private let pkceFactory: PKCEFactory
    private let tokenExchanger: any CodexLoopbackOAuthTokenExchanging
    private let persistAndAdopt: PersistAndAdopt
    private let timeout: Duration

    private var activeSession: ActiveSession?

    public init(
        issuer: URL = CodexLoopbackOAuth.defaultIssuer,
        loginIDFactory: @escaping LoginIDFactory = { UUID().uuidString },
        stateFactory: @escaping StateFactory = { try CodexLoopbackOAuth.makeState() },
        pkceFactory: @escaping PKCEFactory = { try CodexLoopbackOAuth.makePKCE() },
        tokenExchanger: any CodexLoopbackOAuthTokenExchanging,
        persistAndAdopt: @escaping PersistAndAdopt,
        timeout: Duration = .seconds(600)
    ) {
        self.issuer = issuer
        self.loginIDFactory = loginIDFactory
        self.stateFactory = stateFactory
        self.pkceFactory = pkceFactory
        self.tokenExchanger = tokenExchanger
        self.persistAndAdopt = persistAndAdopt
        self.timeout = timeout
    }

    public func startChatGPTLogin(
        options: CodexDesktopChatGPTLoginOptions,
        completion: @escaping @Sendable
            (CodexDesktopLoginSessionCompletion) async -> Void
    ) async throws -> CodexDesktopLoginSessionStart {
        let state = try stateFactory()
        let pkce = try pkceFactory()
        let loginID = await loginIDFactory()
        let redirectURI = CodexLoopbackOAuth.redirectURI(port: 1455)
        let authorizeURL = try CodexLoopbackOAuth.authorizeURL(
            issuer: issuer,
            redirectURI: redirectURI,
            pkce: pkce,
            state: state
        )
        let handle = await MainActor.run {
            CodexIOSAuthenticationSessionHandle(
                authorizeURL: authorizeURL,
                callbackURLScheme: "codex"
            )
        }
        let previous = activeSession
        let task = Task { [weak self] in
            guard let self else { return }
            await self.runSession(
                loginID: loginID,
                state: state,
                pkce: pkce,
                redirectURI: redirectURI,
                options: options,
                handle: handle,
                completion: completion
            )
        }
        activeSession = ActiveSession(
            loginID: loginID,
            handle: handle,
            task: task
        )
        previous?.task.cancel()
        if let previous {
            await previous.handle.cancel()
        }
        return CodexDesktopLoginSessionStart(
            loginID: loginID,
            authURL: authorizeURL.absoluteString
        )
    }

    public func cancelChatGPTLogin(loginID: String) async -> Bool {
        guard let session = activeSession, session.loginID == loginID else {
            return false
        }
        activeSession = nil
        session.task.cancel()
        await session.handle.cancel()
        return true
    }

    private func runSession(
        loginID: String,
        state: String,
        pkce: CodexLoopbackOAuthPKCE,
        redirectURI: String,
        options: CodexDesktopChatGPTLoginOptions,
        handle: CodexIOSAuthenticationSessionHandle,
        completion: @escaping @Sendable
            (CodexDesktopLoginSessionCompletion) async -> Void
    ) async {
        _ = options
        let result: Result<CodexDesktopMCPPlanType?, Error>
        do {
            let plan = try await withThrowingTaskGroup(
                of: CodexDesktopMCPPlanType?.self
            ) { group in
                group.addTask {
                    let callbackURL = try await handle.startAndWait()
                    let code: String
                    do {
                        code = try CodexLoopbackOAuthCallback.authorizationCode(
                            from: callbackURL,
                            expectedState: state
                        )
                    } catch let error as CodexLoopbackOAuthCallbackError {
                        switch error {
                        case .invalidURL, .missingAuthorizationCode:
                            throw CodexIOSAuthenticationError.callbackMissing
                        case .stateMismatch:
                            throw CodexIOSAuthenticationError.stateMismatch
                        case let .oauthDenied(code, description):
                            throw CodexIOSAuthenticationError.callbackRejected(
                                description.map { "\(code): \($0)" } ?? code
                            )
                        }
                    }
                    let tokens = try await self.tokenExchanger
                        .exchangeAuthorizationCode(
                            code,
                            redirectURI: redirectURI,
                            codeVerifier: pkce.codeVerifier
                        )
                    return try await self.persistAndAdopt(tokens)
                }
                group.addTask {
                    try await Task.sleep(for: self.timeout)
                    throw CodexIOSAuthenticationError.timedOut
                }
                defer { group.cancelAll() }
                guard let first = try await group.next() else {
                    throw CodexIOSAuthenticationError.canceled
                }
                return first
            }
            result = .success(plan)
        } catch {
            result = .failure(error)
        }

        if activeSession?.loginID == loginID {
            activeSession = nil
        }
        let completionResult: CodexDesktopLoginSessionCompletion
        switch result {
        case let .success(plan):
            completionResult = .succeeded(loginID: loginID, planType: plan)
        case let .failure(error):
            completionResult = .failed(
                loginID: loginID,
                error: CodexDiagnosticSanitization.publicErrorSummary(error)
            )
        }
        await completion(completionResult)
    }
}

public enum CodexIOSAuthenticationError: Error, Sendable {
    case timedOut
    case canceled
    case startFailed
    case callbackMissing
    case stateMismatch
    case callbackRejected(String)
}
#endif
