#if SWIFT_PACKAGE
import CodexPadDomain
import CodexPadProtocolBridge
#endif

/// Allows one transparent ChatGPT credential refresh only when the official
/// provider rejects the token before any response content becomes visible.
public enum CodexOfficialProviderTransportAction:
    Equatable,
    Sendable
{
    case refreshCredentials
    case fail
}

public struct CodexOfficialProviderCredentialRetryGate: Sendable {
    private var sawVisibleOutput = false
    private var sawStructuredTokenExpiry = false
    private var consumedRetry = false

    public init() {}

    public mutating func observe(_ event: CodexCoreProviderEvent) {
        switch event {
        case let .assistantTextDelta(_, _, delta):
            if !delta.isEmpty {
                sawVisibleOutput = true
            }
        case .responseItemDone, .responseCompleted:
            sawVisibleOutput = true
        case let .realtime(_, _, eventType, payload):
            guard eventType == "provider_transport_error",
                  case let .object(fields) = payload,
                  case let .integer(status)? = fields["status"],
                  status == 401,
                  case let .string(code)? = fields["code"],
                  code == "token_expired"
            else {
                return
            }
            sawStructuredTokenExpiry = true
        default:
            break
        }
    }

    public mutating func consumeRetryIfEligible(
        credentials: CodexOfficialCredentials
    ) -> Bool {
        guard credentials.authMethod == .chatGPT,
              sawStructuredTokenExpiry,
              !sawVisibleOutput,
              !consumedRetry
        else {
            return false
        }
        consumedRetry = true
        sawStructuredTokenExpiry = false
        return true
    }

    public mutating func transportAction(
        for event: CodexCoreProviderEvent,
        credentials: CodexOfficialCredentials
    ) -> CodexOfficialProviderTransportAction? {
        guard case let .realtime(_, _, eventType, _) = event,
              eventType == "provider_transport_error"
        else {
            return nil
        }
        observe(event)
        if consumeRetryIfEligible(credentials: credentials) {
            return .refreshCredentials
        }
        return .fail
    }
}

public enum CodexOfficialProviderStreamDiagnostic {
    public static func make(
        runID: String,
        startedAtMs: Int64,
        rendererModel: String,
        providerModel: String,
        authMethod: CodexDesktopMCPAuthMethod,
        terminalReason: String
    ) -> String {
        let authMethodName = switch authMethod {
        case .apiKey:
            "apiKey"
        case .chatGPT:
            "chatGPT"
        case .chatGPTAuthTokens:
            "chatGPTAuthTokens"
        case .headers:
            "headers"
        case .agentIdentity:
            "agentIdentity"
        case .personalAccessToken:
            "personalAccessToken"
        case .bedrockAPIKey:
            "bedrockAPIKey"
        }
        return "run=\(runID)"
            + " startedAt=\(startedAtMs)"
            + " rendererModel=\(rendererModel)"
            + " providerModel=\(providerModel)"
            + " authMethod=\(authMethodName)"
            + " terminalReason=\(terminalReason)"
    }
}
