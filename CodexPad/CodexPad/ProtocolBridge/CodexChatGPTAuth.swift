import Foundation

public enum CodexChatGPTAuthError: Error, Equatable, Sendable {
    case invalidResponse
    case serverStatus(Int)
    case expired
}

public struct CodexDeviceCode: Equatable, Sendable {
    public let verificationURL: URL
    public let userCode: String
    public let interval: Duration
    fileprivate let deviceAuthID: String

    init(
        verificationURL: URL,
        userCode: String,
        intervalSeconds: UInt64,
        deviceAuthID: String
    ) {
        self.verificationURL = verificationURL
        self.userCode = userCode
        interval = .seconds(intervalSeconds)
        self.deviceAuthID = deviceAuthID
    }
}

public struct CodexChatGPTTokens:
    Codable,
    Equatable,
    Sendable,
    CustomStringConvertible,
    CustomDebugStringConvertible
{
    public let idToken: String
    public let accessToken: String
    public let refreshToken: String
    public let accountID: String?

    public var description: String {
        "CodexChatGPTTokens(accountID: \(accountID ?? "none"), credentials: <redacted>)"
    }

    public var debugDescription: String { description }

    init(
        idToken: String,
        accessToken: String,
        refreshToken: String
    ) throws {
        guard !idToken.isEmpty, !accessToken.isEmpty, !refreshToken.isEmpty else {
            throw CodexChatGPTAuthError.invalidResponse
        }
        self.idToken = idToken
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        accountID = Self.accountID(from: idToken)
    }

    private static func accountID(from token: String) -> String? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        payload.append(String(repeating: "=", count: (4 - payload.count % 4) % 4))
        guard let data = Data(base64Encoded: payload),
              let object = try? JSONSerialization.jsonObject(with: data)
                  as? [String: Any],
              let auth = object["https://api.openai.com/auth"]
                  as? [String: Any]
        else {
            return nil
        }
        return auth["chatgpt_account_id"] as? String
    }
}

public actor CodexChatGPTAuthClient {
    public static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    public static let issuer = URL(string: "https://auth.openai.com")!

    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func requestDeviceCode() async throws -> CodexDeviceCode {
        var request = URLRequest(
            url: Self.issuer
                .appending(path: "api/accounts/deviceauth/usercode")
        )
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            UserCodeRequest(clientID: Self.clientID)
        )
        let (data, response) = try await session.data(for: request)
        try Self.requireSuccess(response)
        let payload = try JSONDecoder().decode(UserCodeResponse.self, from: data)
        guard let verificationURL = URL(
            string: Self.issuer.appending(path: "codex/device").absoluteString
        ),
              !payload.deviceAuthID.isEmpty,
              !payload.userCode.isEmpty,
              payload.interval > 0
        else {
            throw CodexChatGPTAuthError.invalidResponse
        }
        return CodexDeviceCode(
            verificationURL: verificationURL,
            userCode: payload.userCode,
            intervalSeconds: payload.interval,
            deviceAuthID: payload.deviceAuthID
        )
    }

    public func completeDeviceCodeLogin(
        _ code: CodexDeviceCode
    ) async throws -> CodexChatGPTTokens {
        let deadline = ContinuousClock.now + .seconds(15 * 60)
        let codeExchange: DeviceCodeExchange
        while true {
            let result = try await pollDeviceCode(code)
            switch result {
            case let .ready(exchange):
                codeExchange = exchange
                break
            case .pending:
                guard ContinuousClock.now < deadline else {
                    throw CodexChatGPTAuthError.expired
                }
                try await Task.sleep(for: code.interval)
                continue
            }
            break
        }
        return try await exchangeAuthorizationCode(codeExchange)
    }

    public func refresh(
        _ current: CodexChatGPTTokens
    ) async throws -> CodexChatGPTTokens {
        var request = URLRequest(
            url: Self.issuer.appending(path: "oauth/token")
        )
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            RefreshRequest(
                clientID: Self.clientID,
                grantType: "refresh_token",
                refreshToken: current.refreshToken
            )
        )
        let (data, response) = try await session.data(for: request)
        try Self.requireSuccess(response)
        let refreshed = try JSONDecoder().decode(
            RefreshResponse.self,
            from: data
        )
        return try CodexChatGPTTokens(
            idToken: refreshed.idToken ?? current.idToken,
            accessToken: refreshed.accessToken ?? current.accessToken,
            refreshToken: refreshed.refreshToken ?? current.refreshToken
        )
    }

    private enum PollResult {
        case pending
        case ready(DeviceCodeExchange)
    }

    private func pollDeviceCode(
        _ code: CodexDeviceCode
    ) async throws -> PollResult {
        var request = URLRequest(
            url: Self.issuer.appending(path: "api/accounts/deviceauth/token")
        )
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            TokenPollRequest(
                deviceAuthID: code.deviceAuthID,
                userCode: code.userCode
            )
        )
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CodexChatGPTAuthError.invalidResponse
        }
        if http.statusCode == 403 || http.statusCode == 404 {
            return .pending
        }
        guard (200..<300).contains(http.statusCode) else {
            throw CodexChatGPTAuthError.serverStatus(http.statusCode)
        }
        return .ready(
            try JSONDecoder().decode(DeviceCodeExchange.self, from: data)
        )
    }

    private func exchangeAuthorizationCode(
        _ exchange: DeviceCodeExchange
    ) async throws -> CodexChatGPTTokens {
        var request = URLRequest(
            url: Self.issuer.appending(path: "oauth/token")
        )
        request.httpMethod = "POST"
        request.setValue(
            "application/x-www-form-urlencoded",
            forHTTPHeaderField: "Content-Type"
        )
        request.httpBody = Self.formEncoded([
            ("grant_type", "authorization_code"),
            ("code", exchange.authorizationCode),
            (
                "redirect_uri",
                Self.issuer.appending(path: "deviceauth/callback")
                    .absoluteString
            ),
            ("client_id", Self.clientID),
            ("code_verifier", exchange.codeVerifier),
        ])
        let (data, response) = try await session.data(for: request)
        try Self.requireSuccess(response)
        let tokens = try JSONDecoder().decode(TokenResponse.self, from: data)
        return try CodexChatGPTTokens(
            idToken: tokens.idToken,
            accessToken: tokens.accessToken,
            refreshToken: tokens.refreshToken
        )
    }

    private static func requireSuccess(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else {
            throw CodexChatGPTAuthError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw CodexChatGPTAuthError.serverStatus(http.statusCode)
        }
    }

    static func formEncoded(_ values: [(String, String)]) -> Data {
        let allowed = CharacterSet.alphanumerics.union(
            CharacterSet(charactersIn: "-._~")
        )
        let body = values.map { key, value in
            let encodedKey = key.addingPercentEncoding(
                withAllowedCharacters: allowed
            ) ?? ""
            let encodedValue = value.addingPercentEncoding(
                withAllowedCharacters: allowed
            ) ?? ""
            return "\(encodedKey)=\(encodedValue)"
        }
        .joined(separator: "&")
        return Data(body.utf8)
    }
}

private struct UserCodeRequest: Encodable {
    let clientID: String

    private enum CodingKeys: String, CodingKey {
        case clientID = "client_id"
    }
}

private struct UserCodeResponse: Decodable {
    let deviceAuthID: String
    let userCode: String
    let interval: UInt64

    private enum CodingKeys: String, CodingKey {
        case deviceAuthID = "device_auth_id"
        case userCode = "user_code"
        case interval
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        deviceAuthID = try container.decode(String.self, forKey: .deviceAuthID)
        userCode = try container.decode(String.self, forKey: .userCode)
        let intervalString = try container.decode(String.self, forKey: .interval)
        guard let interval = UInt64(intervalString) else {
            throw CodexChatGPTAuthError.invalidResponse
        }
        self.interval = interval
    }
}

private struct TokenPollRequest: Encodable {
    let deviceAuthID: String
    let userCode: String

    private enum CodingKeys: String, CodingKey {
        case deviceAuthID = "device_auth_id"
        case userCode = "user_code"
    }
}

private struct DeviceCodeExchange: Decodable {
    let authorizationCode: String
    let codeChallenge: String
    let codeVerifier: String

    private enum CodingKeys: String, CodingKey {
        case authorizationCode = "authorization_code"
        case codeChallenge = "code_challenge"
        case codeVerifier = "code_verifier"
    }
}

private struct TokenResponse: Decodable {
    let idToken: String
    let accessToken: String
    let refreshToken: String

    private enum CodingKeys: String, CodingKey {
        case idToken = "id_token"
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
    }
}

private struct RefreshRequest: Encodable {
    let clientID: String
    let grantType: String
    let refreshToken: String

    private enum CodingKeys: String, CodingKey {
        case clientID = "client_id"
        case grantType = "grant_type"
        case refreshToken = "refresh_token"
    }
}

private struct RefreshResponse: Decodable {
    let idToken: String?
    let accessToken: String?
    let refreshToken: String?

    private enum CodingKeys: String, CodingKey {
        case idToken = "id_token"
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
    }
}
