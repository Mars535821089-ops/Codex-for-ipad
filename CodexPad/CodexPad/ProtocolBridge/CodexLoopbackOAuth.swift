import CryptoKit
import Foundation
import Security

public typealias CodexLoopbackOAuthRandomBytes =
    @Sendable (_ count: Int) throws -> [UInt8]

public enum CodexLoopbackOAuthError: Error, Equatable, Sendable {
    case randomGenerationFailed(Int32)
    case invalidEntropyLength(expected: Int, actual: Int)
    case invalidAuthorizeURL
    case invalidResponse
    case serverStatus(Int)
    case invalidIDToken
}

public enum CodexLoopbackOAuthCallbackError:
    Error,
    Equatable,
    Sendable
{
    case invalidURL
    case stateMismatch
    case missingAuthorizationCode
    case oauthDenied(code: String, description: String?)
}

/// Parses the authorization redirect identically for loopback and
/// AuthenticationServices-backed iPad login.
public enum CodexLoopbackOAuthCallback {
    public static func authorizationCode(
        from callbackURL: URL,
        expectedState: String
    ) throws -> String {
        guard let components = URLComponents(
            url: callbackURL,
            resolvingAgainstBaseURL: false
        ) else {
            throw CodexLoopbackOAuthCallbackError.invalidURL
        }
        let parameters = Dictionary(
            uniqueKeysWithValues: (components.queryItems ?? []).map {
                ($0.name, $0.value ?? "")
            }
        )
        guard parameters["state"] == expectedState else {
            throw CodexLoopbackOAuthCallbackError.stateMismatch
        }
        if let error = parameters["error"] {
            throw CodexLoopbackOAuthCallbackError.oauthDenied(
                code: error,
                description: parameters["error_description"]
            )
        }
        guard let code = parameters["code"], !code.isEmpty else {
            throw CodexLoopbackOAuthCallbackError.missingAuthorizationCode
        }
        return code
    }
}

public struct CodexLoopbackOAuthPKCE: Equatable, Sendable {
    public let codeVerifier: String
    public let codeChallenge: String

    public init(codeVerifier: String, codeChallenge: String) {
        self.codeVerifier = codeVerifier
        self.codeChallenge = codeChallenge
    }
}

public enum CodexLoopbackOAuth {
    public static let defaultIssuer = URL(
        string: "https://auth.openai.com"
    )!
    public static let defaultClientID = CodexChatGPTAuthClient.clientID
    public static let desktopOriginator = "Codex Desktop"
    public static let officialScope =
        "openid profile email offline_access "
        + "api.connectors.read api.connectors.invoke"

    public static func makeState() throws -> String {
        try makeState(randomBytes: secureRandomBytes)
    }

    public static func makeState(
        randomBytes: CodexLoopbackOAuthRandomBytes
    ) throws -> String {
        base64URLNoPadding(
            try exactRandomBytes(count: 32, source: randomBytes)
        )
    }

    public static func makePKCE() throws -> CodexLoopbackOAuthPKCE {
        try makePKCE(randomBytes: secureRandomBytes)
    }

    public static func makePKCE(
        randomBytes: CodexLoopbackOAuthRandomBytes
    ) throws -> CodexLoopbackOAuthPKCE {
        let verifier = base64URLNoPadding(
            try exactRandomBytes(count: 64, source: randomBytes)
        )
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return CodexLoopbackOAuthPKCE(
            codeVerifier: verifier,
            codeChallenge: base64URLNoPadding(Array(digest))
        )
    }

    public static func redirectURI(port: UInt16) -> String {
        "http://localhost:\(port)/auth/callback"
    }

    public static func authorizeURL(
        issuer: URL = defaultIssuer,
        clientID: String = defaultClientID,
        redirectURI: String,
        pkce: CodexLoopbackOAuthPKCE,
        state: String,
        originator: String = desktopOriginator,
        allowedWorkspaceIDs: [String]? = nil
    ) throws -> URL {
        var query: [(String, String)] = [
            ("response_type", "code"),
            ("client_id", clientID),
            ("redirect_uri", redirectURI),
            ("scope", officialScope),
            ("code_challenge", pkce.codeChallenge),
            ("code_challenge_method", "S256"),
            ("id_token_add_organizations", "true"),
            ("codex_cli_simplified_flow", "true"),
            ("state", state),
            ("originator", originator),
        ]
        if let allowedWorkspaceIDs {
            query.append(
                ("allowed_workspace_id", allowedWorkspaceIDs.joined(separator: ","))
            )
        }
        let encodedQuery = query.map { key, value in
            "\(key)=\(percentEncode(value))"
        }
        .joined(separator: "&")
        guard let url = URL(
            string: "\(issuer.absoluteString)/oauth/authorize?\(encodedQuery)"
        ) else {
            throw CodexLoopbackOAuthError.invalidAuthorizeURL
        }
        return url
    }

    static func formEncoded(_ values: [(String, String)]) -> Data {
        Data(
            values.map { key, value in
                "\(percentEncode(key))=\(percentEncode(value))"
            }
            .joined(separator: "&")
            .utf8
        )
    }

    private static func secureRandomBytes(count: Int) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: count)
        let result = bytes.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(
                kSecRandomDefault,
                count,
                buffer.baseAddress!
            )
        }
        guard result == errSecSuccess else {
            throw CodexLoopbackOAuthError.randomGenerationFailed(result)
        }
        return bytes
    }

    private static func exactRandomBytes(
        count: Int,
        source: CodexLoopbackOAuthRandomBytes
    ) throws -> [UInt8] {
        let bytes = try source(count)
        guard bytes.count == count else {
            throw CodexLoopbackOAuthError.invalidEntropyLength(
                expected: count,
                actual: bytes.count
            )
        }
        return bytes
    }

    private static func base64URLNoPadding(
        _ bytes: [UInt8]
    ) -> String {
        Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func percentEncode(_ value: String) -> String {
        var result = ""
        result.reserveCapacity(value.utf8.count)
        for byte in value.utf8 {
            switch byte {
            case 65...90, 97...122, 48...57, 45, 46, 95, 126:
                result.unicodeScalars.append(UnicodeScalar(byte))
            default:
                result.append("%")
                result.append(hexDigit(byte >> 4))
                result.append(hexDigit(byte & 0x0F))
            }
        }
        return result
    }

    private static func hexDigit(_ nibble: UInt8) -> Character {
        Character(
            UnicodeScalar(nibble < 10 ? nibble + 48 : nibble + 55)
        )
    }
}

public actor CodexLoopbackOAuthTokenClient {
    private let issuer: URL
    private let clientID: String
    private let session: URLSession

    public init(
        issuer: URL = CodexLoopbackOAuth.defaultIssuer,
        clientID: String = CodexLoopbackOAuth.defaultClientID,
        session: URLSession = .shared
    ) {
        self.issuer = issuer
        self.clientID = clientID
        self.session = session
    }

    public func exchangeAuthorizationCode(
        _ authorizationCode: String,
        redirectURI: String,
        codeVerifier: String
    ) async throws -> CodexChatGPTTokens {
        let issuerRoot = issuer.absoluteString.hasSuffix("/")
            ? String(issuer.absoluteString.dropLast())
            : issuer.absoluteString
        guard let tokenEndpoint = URL(
            string: "\(issuerRoot)/oauth/token"
        ) else {
            throw CodexLoopbackOAuthError.invalidResponse
        }
        var request = URLRequest(url: tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue(
            "application/x-www-form-urlencoded",
            forHTTPHeaderField: "Content-Type"
        )
        request.httpBody = CodexLoopbackOAuth.formEncoded([
            ("grant_type", "authorization_code"),
            ("code", authorizationCode),
            ("redirect_uri", redirectURI),
            ("client_id", clientID),
            ("code_verifier", codeVerifier),
        ])

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CodexLoopbackOAuthError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw CodexLoopbackOAuthError.serverStatus(http.statusCode)
        }
        let payload: TokenResponse
        do {
            payload = try JSONDecoder().decode(TokenResponse.self, from: data)
        } catch {
            throw CodexLoopbackOAuthError.invalidResponse
        }
        guard !payload.idToken.isEmpty,
              !payload.accessToken.isEmpty,
              !payload.refreshToken.isEmpty
        else {
            throw CodexLoopbackOAuthError.invalidResponse
        }
        guard Self.hasValidIDTokenStructure(payload.idToken) else {
            throw CodexLoopbackOAuthError.invalidIDToken
        }
        do {
            return try CodexChatGPTTokens(
                idToken: payload.idToken,
                accessToken: payload.accessToken,
                refreshToken: payload.refreshToken
            )
        } catch {
            throw CodexLoopbackOAuthError.invalidResponse
        }
    }

    private static func hasValidIDTokenStructure(_ token: String) -> Bool {
        let parts = token.split(
            separator: ".",
            omittingEmptySubsequences: false
        )
        guard parts.count == 3, parts.allSatisfy({ !$0.isEmpty }) else {
            return false
        }
        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        payload.append(
            String(repeating: "=", count: (4 - payload.count % 4) % 4)
        )
        guard let data = Data(base64Encoded: payload),
              let object = try? JSONSerialization.jsonObject(with: data),
              object is [String: Any]
        else {
            return false
        }
        return true
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
