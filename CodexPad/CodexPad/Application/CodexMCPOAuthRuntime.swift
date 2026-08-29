#if SWIFT_PACKAGE
    import CodexPadDomain
#endif
import Foundation
import Security

public enum CodexMCPOAuthRuntimeError:
    Error,
    Equatable,
    Sendable
{
    case invalidMetadata
    case discoveryFailed(Int)
    case registrationFailed(Int)
    case tokenExchangeFailed(Int)
    case invalidResponse
    case keychain(OSStatus)
}

public protocol CodexMCPOAuthHTTPTransport: Sendable {
    func data(
        for request: URLRequest
    ) async throws -> (Data, HTTPURLResponse)
}

public struct CodexMCPOAuthURLSessionTransport:
    CodexMCPOAuthHTTPTransport,
    Sendable
{
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func data(
        for request: URLRequest
    ) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw CodexMCPOAuthRuntimeError.invalidResponse
        }
        return (data, response)
    }
}

public actor CodexMCPOAuthHTTPClient:
    CodexMCPOAuthFlowClient
{
    private struct ProtectedResourceMetadata: Decodable {
        let authorizationServers: [String]?
        let authorizationServer: String?
        let resource: String?
        let scopesSupported: [String]?

        enum CodingKeys: String, CodingKey {
            case authorizationServers = "authorization_servers"
            case authorizationServer = "authorization_server"
            case resource
            case scopesSupported = "scopes_supported"
        }
    }

    private struct AuthorizationServerMetadata: Decodable {
        let authorizationEndpoint: String
        let tokenEndpoint: String
        let registrationEndpoint: String?
        let scopesSupported: [String]?

        enum CodingKeys: String, CodingKey {
            case authorizationEndpoint = "authorization_endpoint"
            case tokenEndpoint = "token_endpoint"
            case registrationEndpoint = "registration_endpoint"
            case scopesSupported = "scopes_supported"
        }
    }

    private struct RegistrationResponse: Decodable {
        let clientID: String

        enum CodingKeys: String, CodingKey {
            case clientID = "client_id"
        }
    }

    private struct TokenResponse: Decodable {
        let accessToken: String
        let refreshToken: String?
        let tokenType: String?
        let scope: String?
        let expiresIn: Double?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case tokenType = "token_type"
            case scope
            case expiresIn = "expires_in"
        }
    }

    private let transport: any CodexMCPOAuthHTTPTransport
    private let clientName: String

    public init(
        transport: any CodexMCPOAuthHTTPTransport =
            CodexMCPOAuthURLSessionTransport(),
        clientName: String = "Codex for ipad"
    ) {
        self.transport = transport
        self.clientName = clientName
    }

    public func prepareAuthorization(
        _ request: CodexMCPOAuthFlowRequest
    ) async throws -> CodexMCPOAuthPreparedAuthorization {
        let metadata = try await discover(
            serverURL: request.serverURL,
            headers: request.headers
        )
        let clientID: String
        if let configured = request.configuredClientID,
           !configured.isEmpty
        {
            clientID = configured
        } else {
            guard let registration = metadata.registrationEndpoint,
                  let registrationURL = URL(string: registration)
            else {
                throw CodexMCPOAuthRuntimeError.invalidMetadata
            }
            clientID = try await register(
                registrationURL: registrationURL,
                redirectURI: request.redirectURI,
                headers: request.headers
            )
        }
        guard let authorizationEndpoint = URL(
            string: metadata.authorizationEndpoint
        ),
              let tokenEndpoint = URL(string: metadata.tokenEndpoint)
        else {
            throw CodexMCPOAuthRuntimeError.invalidMetadata
        }
        let effectiveScopes =
            request.scopes.isEmpty
            ? (metadata.scopesSupported ?? [])
            : request.scopes
        var components = URLComponents(
            url: authorizationEndpoint,
            resolvingAgainstBaseURL: false
        )
        var query = components?.queryItems ?? []
        query.append(contentsOf: [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: request.redirectURI),
            URLQueryItem(name: "code_challenge", value: request.codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: request.state),
        ])
        if !effectiveScopes.isEmpty {
            query.append(
                URLQueryItem(
                    name: "scope",
                    value: effectiveScopes.joined(separator: " ")
                )
            )
        }
        let resource = request.resource ?? metadata.resource
        if let resource {
            query.append(URLQueryItem(name: "resource", value: resource))
        }
        components?.queryItems = query
        guard let authorizationURL = components?.url else {
            throw CodexMCPOAuthRuntimeError.invalidMetadata
        }
        return CodexMCPOAuthPreparedAuthorization(
            authorizationURL: authorizationURL,
            tokenEndpoint: tokenEndpoint,
            clientID: clientID,
            resource: resource
        )
    }

    public func exchangeAuthorizationCode(
        _ code: String,
        redirectURI: String,
        codeVerifier: String,
        prepared: CodexMCPOAuthPreparedAuthorization,
        headers: [String: String]
    ) async throws -> CodexMCPOAuthCredential {
        var request = URLRequest(url: prepared.tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue(
            "application/x-www-form-urlencoded",
            forHTTPHeaderField: "Content-Type"
        )
        apply(headers: headers, to: &request)
        var fields: [(String, String)] = [
            ("grant_type", "authorization_code"),
            ("code", code),
            ("redirect_uri", redirectURI),
            ("client_id", prepared.clientID),
            ("code_verifier", codeVerifier),
        ]
        if let resource = prepared.resource {
            fields.append(("resource", resource))
        }
        request.httpBody = Self.formEncoded(fields)
        let (data, response) = try await transport.data(for: request)
        guard (200..<300).contains(response.statusCode) else {
            throw CodexMCPOAuthRuntimeError
                .tokenExchangeFailed(response.statusCode)
        }
        let token: TokenResponse
        do {
            token = try JSONDecoder().decode(
                TokenResponse.self,
                from: data
            )
        } catch {
            throw CodexMCPOAuthRuntimeError.invalidResponse
        }
        guard !token.accessToken.isEmpty else {
            throw CodexMCPOAuthRuntimeError.invalidResponse
        }
        return CodexMCPOAuthCredential(
            accessToken: token.accessToken,
            refreshToken: token.refreshToken,
            tokenType: token.tokenType,
            scope: token.scope,
            expiresAt: token.expiresIn.map {
                Date().addingTimeInterval($0)
            },
            clientID: prepared.clientID,
            tokenEndpoint: prepared.tokenEndpoint
        )
    }

    private func discover(
        serverURL: URL,
        headers: [String: String]
    ) async throws -> (
        authorizationEndpoint: String,
        tokenEndpoint: String,
        registrationEndpoint: String?,
        resource: String?,
        scopesSupported: [String]?
    ) {
        let candidates = Self.metadataCandidates(for: serverURL)
        var protected: ProtectedResourceMetadata?
        for candidate in candidates {
            var request = URLRequest(url: candidate)
            request.setValue(
                "application/json",
                forHTTPHeaderField: "Accept"
            )
            apply(headers: headers, to: &request)
            let (data, response) = try await transport.data(for: request)
            guard response.statusCode != 404 else { continue }
            guard (200..<300).contains(response.statusCode) else {
                throw CodexMCPOAuthRuntimeError
                    .discoveryFailed(response.statusCode)
            }
            protected = try? JSONDecoder().decode(
                ProtectedResourceMetadata.self,
                from: data
            )
            if protected != nil { break }
        }
        guard let protected else {
            throw CodexMCPOAuthRuntimeError.invalidMetadata
        }
        let issuerString =
            protected.authorizationServer
            ?? protected.authorizationServers?.first
        guard let issuerString,
              let issuer = URL(string: issuerString)
        else {
            throw CodexMCPOAuthRuntimeError.invalidMetadata
        }
        let metadataURLs = Self.authorizationMetadataCandidates(
            for: issuer
        )
        var metadata: AuthorizationServerMetadata?
        for candidate in metadataURLs {
            var request = URLRequest(url: candidate)
            request.setValue(
                "application/json",
                forHTTPHeaderField: "Accept"
            )
            apply(headers: headers, to: &request)
            let (data, response) = try await transport.data(for: request)
            guard response.statusCode != 404 else { continue }
            guard (200..<300).contains(response.statusCode) else {
                throw CodexMCPOAuthRuntimeError
                    .discoveryFailed(response.statusCode)
            }
            metadata = try? JSONDecoder().decode(
                AuthorizationServerMetadata.self,
                from: data
            )
            if metadata != nil { break }
        }
        guard let metadata else {
            throw CodexMCPOAuthRuntimeError.invalidMetadata
        }
        return (
            metadata.authorizationEndpoint,
            metadata.tokenEndpoint,
            metadata.registrationEndpoint,
            protected.resource,
            metadata.scopesSupported ?? protected.scopesSupported
        )
    }

    private func register(
        registrationURL: URL,
        redirectURI: String,
        headers: [String: String]
    ) async throws -> String {
        var request = URLRequest(url: registrationURL)
        request.httpMethod = "POST"
        request.setValue(
            "application/json",
            forHTTPHeaderField: "Content-Type"
        )
        apply(headers: headers, to: &request)
        request.httpBody = try JSONSerialization.data(
            withJSONObject: [
                "client_name": clientName,
                "redirect_uris": [redirectURI],
                "grant_types": ["authorization_code"],
                "response_types": ["code"],
                "token_endpoint_auth_method": "none",
            ]
        )
        let (data, response) = try await transport.data(for: request)
        guard (200..<300).contains(response.statusCode) else {
            throw CodexMCPOAuthRuntimeError
                .registrationFailed(response.statusCode)
        }
        guard let registration = try? JSONDecoder().decode(
            RegistrationResponse.self,
            from: data
        ), !registration.clientID.isEmpty else {
            throw CodexMCPOAuthRuntimeError.invalidResponse
        }
        return registration.clientID
    }

    private static func metadataCandidates(
        for serverURL: URL
    ) -> [URL] {
        guard var components = URLComponents(
            url: serverURL,
            resolvingAgainstBaseURL: false
        ) else { return [] }
        let originalPath = components.path
        components.path = "/.well-known/oauth-protected-resource"
        let root = components.url
        if originalPath.isEmpty || originalPath == "/" {
            return root.map { [$0] } ?? []
        }
        components.path =
            "/.well-known/oauth-protected-resource"
            + originalPath
        let pathSpecific = components.url
        return [pathSpecific, root].compactMap { $0 }
    }

    private static func authorizationMetadataCandidates(
        for issuer: URL
    ) -> [URL] {
        guard var components = URLComponents(
            url: issuer,
            resolvingAgainstBaseURL: false
        ) else { return [] }
        let path = components.path
        components.path = "/.well-known/oauth-authorization-server"
        let root = components.url
        components.path =
            "/.well-known/openid-configuration"
        let openID = components.url
        if !path.isEmpty && path != "/" {
            components.path =
                path + "/.well-known/oauth-authorization-server"
            return [components.url, root, openID].compactMap { $0 }
        }
        return [root, openID].compactMap { $0 }
    }

    private static func apply(
        headers: [String: String],
        to request: inout URLRequest
    ) {
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
    }

    private func apply(
        headers: [String: String],
        to request: inout URLRequest
    ) {
        Self.apply(headers: headers, to: &request)
    }

    private static func formEncoded(
        _ values: [(String, String)]
    ) -> Data {
        Data(
            values.map {
                "\(percentEncode($0.0))=\(percentEncode($0.1))"
            }
            .joined(separator: "&")
            .utf8
        )
    }

    private static func percentEncode(_ value: String) -> String {
        var result = ""
        for byte in value.utf8 {
            switch byte {
            case 65...90, 97...122, 48...57, 45, 46, 95, 126:
                result.append(Character(UnicodeScalar(byte)))
            default:
                result += String(format: "%%%02X", byte)
            }
        }
        return result
    }
}

public struct CodexMCPOAuthCredentialStore:
    CodexMCPOAuthCredentialPersisting,
    Sendable
{
    private let service: String

    public init(
        service: String = "com.mars.codex-for-ipad.mcp-oauth"
    ) {
        self.service = service
    }

    public func save(
        _ credential: CodexMCPOAuthCredential,
        serverName: String
    ) async throws {
        let data = try JSONEncoder().encode(credential)
        let query = baseQuery(serverName: serverName)
        let attributes: [CFString: Any] = [
            kSecValueData: data,
            kSecAttrAccessible:
                kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let update = SecItemUpdate(
            query as CFDictionary,
            attributes as CFDictionary
        )
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else {
            throw CodexMCPOAuthRuntimeError.keychain(update)
        }
        var insertion = query
        attributes.forEach { insertion[$0] = $1 }
        let add = SecItemAdd(insertion as CFDictionary, nil)
        guard add == errSecSuccess else {
            throw CodexMCPOAuthRuntimeError.keychain(add)
        }
    }

    public func load(
        serverName: String
    ) throws -> CodexMCPOAuthCredential? {
        var query = baseQuery(serverName: serverName)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(
            query as CFDictionary,
            &result
        )
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess,
              let data = result as? Data,
              let credential = try? JSONDecoder().decode(
                  CodexMCPOAuthCredential.self,
                  from: data
              )
        else {
            throw CodexMCPOAuthRuntimeError.keychain(status)
        }
        return credential
    }

    public func delete(serverName: String) throws {
        let status = SecItemDelete(
            baseQuery(serverName: serverName) as CFDictionary
        )
        guard status == errSecSuccess || status == errSecItemNotFound
        else {
            throw CodexMCPOAuthRuntimeError.keychain(status)
        }
    }

    private func baseQuery(
        serverName: String
    ) -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: serverName,
            kSecAttrSynchronizable: kCFBooleanFalse as Any,
        ]
    }
}
