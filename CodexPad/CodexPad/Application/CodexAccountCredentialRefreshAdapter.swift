#if SWIFT_PACKAGE
import CodexPadProtocolBridge
#endif
import Foundation

/// Connects credential refresh to the released renderer account state.
///
/// A refresh rejection from the authorization server invalidates the stale
/// ChatGPT session and publishes the same account notification as logout.
/// Transient failures leave the account intact so a later request can retry.
@MainActor
public final class CodexAccountCredentialRefreshAdapter {
    public typealias Send =
        @MainActor (CodexDesktopHostMessage) async -> Void
    public typealias AccountStore =
        @MainActor () -> CodexAccountStore?

    private let accountStore: AccountStore
    private let send: Send

    public init(
        accountStore: CodexAccountStore,
        send: @escaping Send
    ) {
        self.accountStore = { [weak accountStore] in accountStore }
        self.send = send
    }

    public init(
        accountStore: @escaping AccountStore,
        send: @escaping Send
    ) {
        self.accountStore = accountStore
        self.send = send
    }

    public func refresh() async throws -> CodexOfficialCredentials {
        guard let accountStore = accountStore() else {
            throw CodexAccountCredentialRefreshError.signedOut
        }
        do {
            return try await accountStore.refreshOfficialCredentials()
        } catch {
            if accountStore.invalidateExpiredChatGPTCredentials(
                afterRefreshFailure: error
            ) {
                await send(
                    .mcpNotification(
                        hostID: "local",
                        method: "account/updated",
                        params: .object([
                            "authMode": .null,
                            "planType": .null,
                        ]),
                        metadata: [:]
                    )
                )
            }
            throw error
        }
    }
}
