#if SWIFT_PACKAGE
import CodexPadProtocolBridge
#endif
import Foundation
import Observation

public struct CodexOfficialCredentials: Equatable, Sendable {
    public static let openAIAPIBaseURL = "https://api.openai.com/v1"

    public let accessToken: String
    public let accountID: String?
    public let baseURL: String?
    public let authMethod: CodexDesktopMCPAuthMethod

    public init(
        accessToken: String,
        accountID: String?,
        baseURL: String? = nil,
        authMethod: CodexDesktopMCPAuthMethod = .chatGPT
    ) {
        self.accessToken = accessToken
        self.accountID = accountID
        self.baseURL = baseURL
        self.authMethod = authMethod
    }
}

@Observable
@MainActor
public final class CodexAccountStore {
    public private(set) var accountID: String?
    public private(set) var userID: String?
    public private(set) var email: String?
    public private(set) var planType: CodexDesktopMCPPlanType?
    public private(set) var deviceCode: CodexDeviceCode?
    public private(set) var isWorking = false
    public private(set) var problem: String?
    public private(set) var authMode: CodexDesktopMCPAuthMethod?

    @ObservationIgnored private var tokens: CodexChatGPTTokens?
    @ObservationIgnored private var apiKey: String?
    @ObservationIgnored private let credentials: CodexCredentialStore
    @ObservationIgnored private let apiKeyCredentials:
        CodexAPIKeyCredentialStore
    @ObservationIgnored private let authClient: CodexChatGPTAuthClient
    @ObservationIgnored private let refreshCoordinator =
        CodexAccountCredentialRefreshCoordinator<CodexChatGPTTokens>()

    public var isSignedIn: Bool {
        tokens != nil || apiKey != nil
    }

    public var isChatGPTSignedIn: Bool {
        authMode == .chatGPT && tokens != nil
    }

    public var desktopAccountState: CodexDesktopMCPAccountState {
        switch authMode {
        case .apiKey where apiKey != nil:
            CodexDesktopMCPAccountState(
                account: .apiKey,
                authMethod: .apiKey,
                // Desktop uses this as the host's authentication-policy flag,
                // not as "credentials are currently missing". Keeping it true
                // enables released authenticated commands such as Log out.
                requiresOpenAIAuth: true
            )

        case .chatGPT where tokens != nil:
            CodexDesktopMCPAccountState(
                account: .chatGPT(
                    email: email,
                    planType: planType ?? .unknown
                ),
                authMethod: .chatGPT,
                requiresOpenAIAuth: true
            )

        default:
            CodexDesktopMCPAccountState(
                account: nil,
                authMethod: nil,
                requiresOpenAIAuth: true
            )
        }
    }

    public init(
        credentials: CodexCredentialStore = CodexCredentialStore(),
        apiKeyCredentials: CodexAPIKeyCredentialStore =
            CodexAPIKeyCredentialStore(),
        authClient: CodexChatGPTAuthClient = CodexChatGPTAuthClient(),
        restoreCredentials: Bool = true
    ) {
        self.credentials = credentials
        self.apiKeyCredentials = apiKeyCredentials
        self.authClient = authClient
        guard restoreCredentials else {
            return
        }
        do {
            // ChatGPT OAuth is the primary released login mode. If an older
            // API-key record survived a failed cross-mode cleanup, it must
            // not silently take precedence on the next launch and route
            // authenticated turns to api.openai.com with a stale key.
            if let restored = try credentials.load() {
                activateTokens(restored)
            } else if let restoredAPIKey = try apiKeyCredentials.load() {
                activateAPIKey(restoredAPIKey)
            }
        } catch {
            problem = "Saved sign-in could not be restored."
        }
    }

    public func requestDeviceCode() async {
        isWorking = true
        problem = nil
        do {
            deviceCode = try await authClient.requestDeviceCode()
        } catch is CancellationError {
            // The sheet was dismissed while requesting a code.
        } catch {
            problem = "ChatGPT sign-in could not be started."
        }
        isWorking = false
    }

    public func completeDeviceCodeLogin() async {
        guard let deviceCode else { return }
        isWorking = true
        problem = nil
        do {
            let received = try await authClient.completeDeviceCodeLogin(
                deviceCode
            )
            try acceptChatGPTTokens(received)
            self.deviceCode = nil
        } catch is CancellationError {
            // Polling is expected to stop if the account sheet is dismissed.
        } catch {
            problem = "ChatGPT sign-in did not complete. Request a new code."
        }
        isWorking = false
    }

    /// Persists and activates credentials produced by the released desktop
    /// browser-login flow.
    public func acceptChatGPTTokens(
        _ received: CodexChatGPTTokens
    ) throws {
        refreshCoordinator.invalidate()
        let persisted: CodexChatGPTTokens
        do {
            try credentials.save(received)
            guard let verified = try credentials.load() else {
                throw CodexCredentialStoreError.invalidData
            }
            persisted = verified
        } catch {
            problem = Self.publicCredentialError(
                operation: "ChatGPT sign-in could not be saved",
                error: error
            )
            throw error
        }
        activateTokens(persisted)
        do {
            try apiKeyCredentials.delete()
        } catch {
            // The verified ChatGPT tokens remain authoritative. A stale API
            // key must not turn a completed browser/device login into failure.
            problem =
                "ChatGPT sign-in saved, but the previous API key could not be removed."
        }
    }

    /// Persists and activates the released app-server API-key login mode.
    public func acceptAPIKey(_ received: String) throws {
        refreshCoordinator.invalidate()
        let persisted: String
        do {
            try apiKeyCredentials.save(received)
            guard let verified = try apiKeyCredentials.load() else {
                throw CodexCredentialStoreError.invalidData
            }
            persisted = verified
        } catch {
            problem = Self.publicCredentialError(
                operation: "API key could not be saved",
                error: error
            )
            throw error
        }
        activateAPIKey(persisted)
        do {
            try credentials.delete()
        } catch {
            // The verified API key remains the authoritative mode. Keep the
            // login successful and surface only the cleanup warning.
            problem =
                "API key saved, but the previous ChatGPT sign-in could not be removed."
        }
    }

    /// Activates credentials after the desktop loopback driver has already
    /// persisted them to the same Keychain slot.
    public func activatePersistedChatGPTTokens(
        _ received: CodexChatGPTTokens
    ) {
        refreshCoordinator.invalidate()
        activateTokens(received)
    }

    public func signOut() {
        refreshCoordinator.invalidate()
        var firstError: (any Error)?
        do {
            try credentials.delete()
        } catch {
            firstError = error
        }
        do {
            try apiKeyCredentials.delete()
        } catch {
            if firstError == nil {
                firstError = error
            }
        }
        tokens = nil
        apiKey = nil
        authMode = nil
        accountID = nil
        userID = nil
        email = nil
        planType = nil
        deviceCode = nil
        if firstError == nil {
            problem = nil
        } else {
            problem = "Sign-out did not completely remove saved credentials."
        }
    }

    @discardableResult
    public func refreshOfficialCredentials() async throws
        -> CodexOfficialCredentials
    {
        guard let current = tokens else {
            throw CodexAccountCredentialRefreshError.signedOut
        }
        let refreshed = try await refreshCoordinator.refresh(
            current: current,
            operation: { [authClient] current in
                try await authClient.refresh(current)
            },
            apply: { [weak self] received in
                guard let self else { throw CancellationError() }
                try self.credentials.save(received)
                self.activateTokens(received)
            }
        )
        return CodexOfficialCredentials(
            accessToken: refreshed.accessToken,
            accountID: refreshed.accountID,
            authMethod: .chatGPT
        )
    }

    /// Removes a ChatGPT session after the refresh endpoint has confirmed
    /// that its refresh credential is no longer accepted. Transient network
    /// and server failures keep the session so a later request can retry.
    ///
    /// Memory is cleared even when Keychain deletion fails: an expired access
    /// token must never continue to make the released renderer look signed in.
    @discardableResult
    public func invalidateExpiredChatGPTCredentials(
        afterRefreshFailure error: any Error
    ) -> Bool {
        guard authMode == .chatGPT,
              tokens != nil,
              Self.isPermanentRefreshRejection(error)
        else {
            return false
        }

        refreshCoordinator.invalidate()
        let deletionFailed: Bool
        do {
            try credentials.delete()
            deletionFailed = false
        } catch {
            deletionFailed = true
        }
        tokens = nil
        authMode = nil
        accountID = nil
        userID = nil
        email = nil
        planType = nil
        deviceCode = nil
        problem =
            "ChatGPT session expired. Sign in again."
            + (deletionFailed
                ? " Saved credentials could not be removed."
                : "")
        return true
    }

    public func officialCredentials() -> CodexOfficialCredentials? {
        switch authMode {
        case .apiKey:
            guard let apiKey else { return nil }
            return CodexOfficialCredentials(
                accessToken: apiKey,
                accountID: nil,
                baseURL: Self.openAIAPIBaseURL,
                authMethod: .apiKey
            )

        case .chatGPT:
            guard let tokens else { return nil }
            return CodexOfficialCredentials(
                accessToken: tokens.accessToken,
                accountID: tokens.accountID,
                authMethod: .chatGPT
            )

        default:
            return nil
        }
    }

    public func chatGPTCredentials() -> CodexOfficialCredentials? {
        guard authMode == .chatGPT else { return nil }
        return officialCredentials()
    }

    public func remoteControlAuthAdapter()
        -> CodexRemoteControlAccountAuthAdapter
    {
        CodexRemoteControlAccountAuthAdapter(
            currentCredentials: { [weak self] in
                guard let credentials = self?.chatGPTCredentials() else {
                    return nil
                }
                return CodexRemoteControlCredentialSnapshot(
                    accessToken: credentials.accessToken,
                    accountID: credentials.accountID
                )
            },
            refreshCredentials: { [weak self] in
                guard let self else {
                    throw CodexAccountCredentialRefreshError.signedOut
                }
                _ = try await self.refreshOfficialCredentials()
            }
        )
    }

    private func activateTokens(_ received: CodexChatGPTTokens) {
        tokens = received
        apiKey = nil
        authMode = .chatGPT
        accountID = received.accountID
        userID = Self.userID(fromIDToken: received.idToken)
        email = Self.email(fromIDToken: received.idToken)
        planType = Self.planType(from: received)
        deviceCode = nil
        problem = nil
    }

    private func activateAPIKey(_ received: String) {
        tokens = nil
        apiKey = received
        authMode = .apiKey
        accountID = nil
        userID = nil
        email = nil
        planType = nil
        deviceCode = nil
        problem = nil
    }

    private static func publicCredentialError(
        operation: String,
        error: any Error
    ) -> String {
        if case let CodexCredentialStoreError.keychainStatus(status) = error {
            return "\(operation) (Keychain status \(status))."
        }
        if error is CodexCredentialStoreError {
            return "\(operation)."
        }
        return "\(operation)."
    }

    private static func isPermanentRefreshRejection(
        _ error: any Error
    ) -> Bool {
        guard let error = error as? CodexChatGPTAuthError else {
            return false
        }
        switch error {
        case let .serverStatus(status):
            return status == 400 || status == 401 || status == 403
        case .expired:
            return true
        case .invalidResponse:
            return false
        }
    }

    private static let openAIAPIBaseURL =
        CodexOfficialCredentials.openAIAPIBaseURL

    /// The released OAuth contract stores `chatgpt_plan_type` in the access
    /// token. Keeping this extraction behind one helper prevents restored and
    /// freshly accepted credentials from drifting to the unsupported
    /// `.unknown` account surface.
    static func planType(
        from tokens: CodexChatGPTTokens
    ) -> CodexDesktopMCPPlanType? {
        CodexDesktopLoopbackSuccessRedirect.planType(
            fromAccessToken: tokens.accessToken
        )
    }

    static func userID(fromIDToken token: String) -> String? {
        guard let value = claims(fromJWT: token),
              let subject = value["sub"] as? String
        else { return nil }
        let normalized = subject.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        return normalized.isEmpty ? nil : normalized
    }

    private static func email(fromIDToken token: String) -> String? {
        guard let value = claims(fromJWT: token) else { return nil }
        for key in [
            "email",
            "preferred_username",
            "https://api.openai.com/profile",
        ] {
            if let string = value[key] as? String, !string.isEmpty {
                return string
            }
        }
        if let profile =
            value["https://api.openai.com/profile"] as? [String: Any],
           let string = profile["email"] as? String,
           !string.isEmpty
        {
            return string
        }
        return nil
    }

    private static func claims(
        fromJWT token: String
    ) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var encoded = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        guard let data = Data(base64Encoded: encoded),
              let value = try? JSONSerialization.jsonObject(
                  with: data
              ) as? [String: Any]
        else { return nil }
        return value
    }
}
