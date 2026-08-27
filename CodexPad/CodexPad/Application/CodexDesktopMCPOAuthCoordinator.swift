#if SWIFT_PACKAGE
    import CodexPadDomain
    import CodexPadProtocolBridge
#endif
import Foundation

public enum CodexDesktopMCPOAuthSessionCompletion:
    Equatable,
    Sendable
{
    case succeeded
    case failed(String?)
}

public struct CodexDesktopMCPOAuthSessionStart:
    Equatable,
    Sendable
{
    public let authorizationURL: String

    public init(authorizationURL: String) {
        self.authorizationURL = authorizationURL
    }
}

public protocol CodexDesktopMCPOAuthSessionDriving: Sendable {
    func startMCPOAuthLogin(
        name: String,
        threadID: String?,
        scopes: [String]?,
        timeoutSeconds: Int64?,
        completion:
            @escaping @Sendable
            (CodexDesktopMCPOAuthSessionCompletion) async -> Void
    ) async throws -> CodexDesktopMCPOAuthSessionStart
}

/// Owns the released app-server MCP OAuth start/completion contract.
///
/// Transport discovery, browser presentation, callback handling, token
/// exchange, and credential persistence stay in the injected session driver.
/// This coordinator guarantees that the completion notification is delivered
/// to the same renderer host that initiated the login.
public actor CodexDesktopMCPOAuthCoordinator:
    CodexDesktopMCPOAuthLoggingIn
{
    public typealias NotificationSink =
        @Sendable (CodexDesktopHostMessage) async -> Void

    private let driver: any CodexDesktopMCPOAuthSessionDriving
    private let sendNotification: NotificationSink

    public init(
        driver: any CodexDesktopMCPOAuthSessionDriving,
        sendNotification: @escaping NotificationSink
    ) {
        self.driver = driver
        self.sendNotification = sendNotification
    }

    public func loginMCPServer(
        hostID: String,
        name: String,
        threadID: String?,
        scopes: [String]?,
        timeoutSeconds: Int64?
    ) async throws -> CodexDesktopMCPOAuthLoginResult {
        let sendNotification = self.sendNotification
        let started = try await driver.startMCPOAuthLogin(
            name: name,
            threadID: threadID,
            scopes: scopes,
            timeoutSeconds: timeoutSeconds,
            completion: { completion in
                let success: Bool
                let completionError: String?
                switch completion {
                case .succeeded:
                    success = true
                    completionError = nil
                case let .failed(error):
                    success = false
                    completionError = error
                }
                var params: [String: CodexJSONValue] = [
                    "name": .string(name),
                    "threadId":
                        threadID.map(CodexJSONValue.string)
                        ?? .null,
                    "success": .bool(success),
                ]
                if let completionError {
                    params["error"] = .string(completionError)
                }
                await sendNotification(
                    .mcpNotification(
                        hostID: hostID,
                        method: "mcpServer/oauthLogin/completed",
                        params: .object(params),
                        metadata: [:]
                    )
                )
            }
        )
        return CodexDesktopMCPOAuthLoginResult(
            authorizationURL: started.authorizationURL
        )
    }
}
