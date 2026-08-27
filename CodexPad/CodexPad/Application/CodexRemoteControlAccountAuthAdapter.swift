import Foundation

public struct CodexRemoteControlCredentialSnapshot:
    Equatable,
    Sendable
{
    public let accessToken: String
    public let accountID: String?

    public init(accessToken: String, accountID: String?) {
        self.accessToken = accessToken
        self.accountID = accountID
    }
}

public enum CodexRemoteControlAccountAuthAdapterError:
    Error,
    Equatable,
    Sendable
{
    case signedOut
    case emptyAccessToken
    case missingAccountID
}

/// Bridges the account store into Remote Control without retaining a token.
/// Every operation resolves the current credential snapshot, and recovery
/// performs a refresh before resolving the snapshot again.
@MainActor
public final class CodexRemoteControlAccountAuthAdapter:
    CodexRemoteControlLifecycleAuthProviding
{
    public typealias CurrentCredentials =
        @MainActor @Sendable () -> CodexRemoteControlCredentialSnapshot?
    public typealias RefreshCredentials =
        @MainActor @Sendable () async throws -> Void

    private let currentCredentials: CurrentCredentials
    private let refreshCredentials: RefreshCredentials

    public init(
        currentCredentials: @escaping CurrentCredentials,
        refreshCredentials: @escaping RefreshCredentials
    ) {
        self.currentCredentials = currentCredentials
        self.refreshCredentials = refreshCredentials
    }

    public func currentRemoteControlAuth() async throws
        -> CodexRemoteControlAccountAuth
    {
        try currentAuth()
    }

    public func recoverRemoteControlAuth() async throws
        -> CodexRemoteControlAccountAuth?
    {
        try await refreshCredentials()
        return try currentAuth()
    }

    private func currentAuth() throws -> CodexRemoteControlAccountAuth {
        guard let credentials = currentCredentials() else {
            throw CodexRemoteControlAccountAuthAdapterError.signedOut
        }
        let accessToken = credentials.accessToken.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !accessToken.isEmpty else {
            throw CodexRemoteControlAccountAuthAdapterError.emptyAccessToken
        }
        guard let rawAccountID = credentials.accountID else {
            throw CodexRemoteControlAccountAuthAdapterError.missingAccountID
        }
        let accountID = rawAccountID.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !accountID.isEmpty else {
            throw CodexRemoteControlAccountAuthAdapterError.missingAccountID
        }
        return CodexRemoteControlAccountAuth(
            accessToken: accessToken,
            accountID: accountID
        )
    }
}
