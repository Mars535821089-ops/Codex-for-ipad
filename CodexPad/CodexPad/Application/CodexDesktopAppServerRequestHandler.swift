#if SWIFT_PACKAGE
import CodexPadDomain
#endif
import Foundation

public enum CodexDesktopAppServerRequestError:
    Swift.Error,
    Equatable,
    Sendable
{
    case invalidParams(method: String)
    case missingAccountID
    case attestationUnavailable
}

/// Handles app-server requests that the desktop main process owns natively.
/// Unknown methods remain available to the released renderer broker.
@MainActor
public final class CodexDesktopAppServerRequestHandler {
    public typealias RefreshCredentials =
        @MainActor (_ previousAccountID: String?) async throws
            -> CodexOfficialCredentials
    public typealias PlanType = @MainActor () -> String?
    public typealias Clock = @MainActor () -> Date

    private let refreshCredentials: RefreshCredentials
    private let planType: PlanType
    private let attestationProvider:
        any CodexDesktopDeviceCheckTokenProviding
    private let now: Clock

    public init(
        refreshCredentials: @escaping RefreshCredentials,
        planType: @escaping PlanType,
        attestationProvider:
            any CodexDesktopDeviceCheckTokenProviding,
        now: @escaping Clock = Date.init
    ) {
        self.refreshCredentials = refreshCredentials
        self.planType = planType
        self.attestationProvider = attestationProvider
        self.now = now
    }

    public func handle(
        method: String,
        params: CodexJSONValue?
    ) async throws -> CodexJSONValue? {
        switch method {
        case "account/chatgptAuthTokens/refresh":
            return try await refreshAuthTokens(
                params: params,
                method: method
            )
        case "attestation/generate":
            return try await generateAttestation(
                params: params,
                method: method
            )
        case "currentTime/read":
            return try readCurrentTime(
                params: params,
                method: method
            )
        default:
            return nil
        }
    }

    private func refreshAuthTokens(
        params: CodexJSONValue?,
        method: String
    ) async throws -> CodexJSONValue {
        guard case let .object(fields)? = params,
              fields["reason"] == .string("unauthorized")
        else {
            throw CodexDesktopAppServerRequestError.invalidParams(
                method: method
            )
        }

        let previousAccountID: String?
        switch fields["previousAccountId"] {
        case nil, .null?:
            previousAccountID = nil
        case let .string(value)?:
            previousAccountID = value
        default:
            throw CodexDesktopAppServerRequestError.invalidParams(
                method: method
            )
        }

        let credentials = try await refreshCredentials(previousAccountID)
        guard let accountID = credentials.accountID,
              !accountID.isEmpty
        else {
            throw CodexDesktopAppServerRequestError.missingAccountID
        }
        return .object([
            "accessToken": .string(credentials.accessToken),
            "chatgptAccountId": .string(accountID),
            "chatgptPlanType": planType().map(CodexJSONValue.string)
                ?? .null,
        ])
    }

    private func generateAttestation(
        params: CodexJSONValue?,
        method: String
    ) async throws -> CodexJSONValue {
        guard case .object? = params else {
            throw CodexDesktopAppServerRequestError.invalidParams(
                method: method
            )
        }
        guard let token = await attestationProvider.token(),
              !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw CodexDesktopAppServerRequestError.attestationUnavailable
        }
        return .object(["token": .string(token)])
    }

    private func readCurrentTime(
        params: CodexJSONValue?,
        method: String
    ) throws -> CodexJSONValue {
        guard case let .object(fields)? = params,
              case let .string(threadID)? = fields["threadId"],
              !threadID.isEmpty
        else {
            throw CodexDesktopAppServerRequestError.invalidParams(
                method: method
            )
        }
        let seconds = Int64(now().timeIntervalSince1970.rounded(.down))
        return .object(["currentTimeAt": .integer(seconds)])
    }
}
