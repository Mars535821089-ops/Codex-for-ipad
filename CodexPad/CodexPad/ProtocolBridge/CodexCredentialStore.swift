import Foundation
import Security

public enum CodexCredentialStoreError: Error, Equatable, Sendable {
    case keychainStatus(OSStatus)
    case invalidData
}

public struct CodexGitCredential:
    Codable, Equatable, Sendable, CustomStringConvertible
{
    public let username: String
    public let password: String

    public init(username: String, password: String) {
        self.username = username
        self.password = password
    }

    public var description: String {
        "CodexGitCredential(username: \(username), password: <redacted>)"
    }
}

public struct CodexGitCredentialStore: Sendable {
    private let service: String
    private let account: String

    public init(
        service: String = "com.mars.codex-for-ipad.git",
        account: String = "default"
    ) {
        self.service = service
        self.account = account
    }

    public func save(_ credential: CodexGitCredential) throws {
        let data = try JSONEncoder().encode(credential)
        let selector = baseQuery()
        let attributes: [CFString: Any] = [
            kSecValueData: data,
            kSecAttrAccessible:
                kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let updateStatus = SecItemUpdate(
            selector as CFDictionary,
            attributes as CFDictionary
        )
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw CodexCredentialStoreError.keychainStatus(
                updateStatus
            )
        }
        var insertion = selector
        attributes.forEach { insertion[$0] = $1 }
        let addStatus = SecItemAdd(
            insertion as CFDictionary,
            nil
        )
        guard addStatus == errSecSuccess else {
            throw CodexCredentialStoreError.keychainStatus(
                addStatus
            )
        }
    }

    public func load() throws -> CodexGitCredential? {
        var query = baseQuery()
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(
            query as CFDictionary,
            &result
        )
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw CodexCredentialStoreError.keychainStatus(status)
        }
        guard let data = result as? Data,
              let credential = try? JSONDecoder().decode(
                  CodexGitCredential.self,
                  from: data
              )
        else {
            throw CodexCredentialStoreError.invalidData
        }
        return credential
    }

    public func delete() throws {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        guard status == errSecSuccess
                || status == errSecItemNotFound
        else {
            throw CodexCredentialStoreError.keychainStatus(status)
        }
    }

    private func baseQuery() -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecAttrSynchronizable: kCFBooleanFalse as Any,
        ]
    }
}

protocol CodexCredentialKeychain: Sendable {
    func upsert(service: String, account: String, data: Data) throws
    func read(service: String, account: String) throws -> Data?
    func delete(service: String, account: String) throws
}

private struct CodexSystemCredentialKeychain:
    CodexCredentialKeychain,
    Sendable
{
    func upsert(
        service: String,
        account: String,
        data: Data
    ) throws {
        let selector = baseQuery(service: service, account: account)
        let attributes: [CFString: Any] = [
            kSecValueData: data,
            kSecAttrAccessible:
                kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let updateStatus = SecItemUpdate(
            selector as CFDictionary,
            attributes as CFDictionary
        )
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw CodexCredentialStoreError.keychainStatus(updateStatus)
        }

        var insertion = selector
        attributes.forEach { insertion[$0] = $1 }
        let addStatus = SecItemAdd(insertion as CFDictionary, nil)
        if addStatus == errSecSuccess {
            return
        }

        // Another writer can insert the same item between update and add.
        // Retrying the update makes that race indistinguishable from a
        // normal overwrite instead of surfacing errSecDuplicateItem.
        if addStatus == errSecDuplicateItem {
            let retryStatus = SecItemUpdate(
                selector as CFDictionary,
                attributes as CFDictionary
            )
            guard retryStatus == errSecSuccess else {
                throw CodexCredentialStoreError.keychainStatus(retryStatus)
            }
            return
        }
        throw CodexCredentialStoreError.keychainStatus(addStatus)
    }

    func read(service: String, account: String) throws -> Data? {
        var query = baseQuery(service: service, account: account)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(
            query as CFDictionary,
            &result
        )
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw CodexCredentialStoreError.keychainStatus(status)
        }
        guard let data = result as? Data else {
            throw CodexCredentialStoreError.invalidData
        }
        return data
    }

    func delete(service: String, account: String) throws {
        let status = SecItemDelete(
            baseQuery(service: service, account: account) as CFDictionary
        )
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CodexCredentialStoreError.keychainStatus(status)
        }
    }

    private func baseQuery(
        service: String,
        account: String
    ) -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecAttrSynchronizable: kCFBooleanFalse as Any,
        ]
    }
}

public struct CodexCredentialStore: Sendable {
    private struct Manifest: Codable, Equatable, Sendable {
        let schemaVersion: Int
        let revision: String
    }

    private enum Component: String, CaseIterable, Sendable {
        case idToken = "id-token"
        case accessToken = "access-token"
        case refreshToken = "refresh-token"
    }

    private static let schemaVersion = 2

    private let service: String
    private let account: String
    private let keychain: any CodexCredentialKeychain
    private let makeRevision: @Sendable () -> String

    public init(
        service: String = "com.mars.codex-for-ipad.chatgpt",
        account: String = "oauth-tokens"
    ) {
        self.service = service
        self.account = account
        keychain = CodexSystemCredentialKeychain()
        makeRevision = { UUID().uuidString.lowercased() }
    }

    init(
        service: String,
        account: String,
        keychain: any CodexCredentialKeychain,
        makeRevision: @escaping @Sendable () -> String
    ) {
        self.service = service
        self.account = account
        self.keychain = keychain
        self.makeRevision = makeRevision
    }

    public func save(_ tokens: CodexChatGPTTokens) throws {
        let previousManifest = try? loadManifest()
        let revision = makeRevision()
        guard !revision.isEmpty else {
            throw CodexCredentialStoreError.invalidData
        }
        let components: [(Component, String)] = [
            (.idToken, tokens.idToken),
            (.accessToken, tokens.accessToken),
            (.refreshToken, tokens.refreshToken),
        ]

        do {
            for (component, value) in components {
                try keychain.upsert(
                    service: service,
                    account: componentAccount(
                        revision: revision,
                        component: component
                    ),
                    data: Data(value.utf8)
                )
            }

            // The manifest is the commit record and must always be written
            // after every component. Readers therefore see either the
            // complete old revision or the complete new revision.
            let manifest = Manifest(
                schemaVersion: Self.schemaVersion,
                revision: revision
            )
            try keychain.upsert(
                service: service,
                account: manifestAccount,
                data: try JSONEncoder().encode(manifest)
            )
        } catch {
            rollback(revision: revision)
            throw error
        }

        if let previousManifest,
           previousManifest.revision != revision
        {
            removeComponents(revision: previousManifest.revision)
        }
        // A successful v2 commit supersedes the former single-item JSON
        // representation. Cleanup is intentionally best-effort because the
        // newly committed login must remain usable even if stale deletion
        // encounters an OS-level error.
        try? keychain.delete(service: service, account: account)
    }

    public func load() throws -> CodexChatGPTTokens? {
        if let manifest = try loadManifest() {
            guard manifest.schemaVersion == Self.schemaVersion else {
                throw CodexCredentialStoreError.invalidData
            }
            let idToken = try load(
                component: .idToken,
                revision: manifest.revision
            )
            let accessToken = try load(
                component: .accessToken,
                revision: manifest.revision
            )
            let refreshToken = try load(
                component: .refreshToken,
                revision: manifest.revision
            )
            guard let idToken, let accessToken, let refreshToken else {
                throw CodexCredentialStoreError.invalidData
            }
            do {
                return try CodexChatGPTTokens(
                    idToken: idToken,
                    accessToken: accessToken,
                    refreshToken: refreshToken
                )
            } catch {
                throw CodexCredentialStoreError.invalidData
            }
        }

        guard let legacyData = try keychain.read(
            service: service,
            account: account
        ) else {
            return nil
        }
        guard let tokens = try? JSONDecoder().decode(
            CodexChatGPTTokens.self,
            from: legacyData
        ) else {
            throw CodexCredentialStoreError.invalidData
        }
        // Preserve compatibility with existing installs. A migration error
        // does not discard a credential set that was already readable.
        try? save(tokens)
        return tokens
    }

    public func delete() throws {
        let currentManifest = try? loadManifest()
        var firstError: (any Error)?

        if let currentManifest {
            for component in Component.allCases {
                do {
                    try keychain.delete(
                        service: service,
                        account: componentAccount(
                            revision: currentManifest.revision,
                            component: component
                        )
                    )
                } catch {
                    if firstError == nil {
                        firstError = error
                    }
                }
            }
        }
        for key in [manifestAccount, account] {
            do {
                try keychain.delete(service: service, account: key)
            } catch {
                if firstError == nil {
                    firstError = error
                }
            }
        }
        if let firstError {
            throw firstError
        }
    }

    private var manifestAccount: String {
        "\(account).v2.manifest"
    }

    private func componentAccount(
        revision: String,
        component: Component
    ) -> String {
        "\(account).v2.\(revision).\(component.rawValue)"
    }

    private func loadManifest() throws -> Manifest? {
        guard let data = try keychain.read(
            service: service,
            account: manifestAccount
        ) else {
            return nil
        }
        guard let manifest = try? JSONDecoder().decode(
            Manifest.self,
            from: data
        ),
              !manifest.revision.isEmpty
        else {
            throw CodexCredentialStoreError.invalidData
        }
        return manifest
    }

    private func load(
        component: Component,
        revision: String
    ) throws -> String? {
        guard let data = try keychain.read(
            service: service,
            account: componentAccount(
                revision: revision,
                component: component
            )
        ) else {
            return nil
        }
        guard let value = String(data: data, encoding: .utf8),
              !value.isEmpty
        else {
            throw CodexCredentialStoreError.invalidData
        }
        return value
    }

    private func rollback(revision: String) {
        removeComponents(revision: revision)
    }

    private func removeComponents(revision: String) {
        for component in Component.allCases {
            try? keychain.delete(
                service: service,
                account: componentAccount(
                    revision: revision,
                    component: component
                )
            )
        }
    }
}

/// Stores the OpenAI API key used by the released `apiKey` login mode.
///
/// The system adapter applies
/// `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` on every upsert. The
/// value is kept as one generic-password item because it is small, unlike the
/// three large ChatGPT OAuth tokens above.
public struct CodexAPIKeyCredentialStore: Sendable {
    private let service: String
    private let account: String
    private let keychain: any CodexCredentialKeychain

    public init(
        service: String = "com.mars.codex-for-ipad.openai",
        account: String = "api-key"
    ) {
        self.service = service
        self.account = account
        keychain = CodexSystemCredentialKeychain()
    }

    init(
        service: String,
        account: String,
        keychain: any CodexCredentialKeychain
    ) {
        self.service = service
        self.account = account
        self.keychain = keychain
    }

    public func save(_ apiKey: String) throws {
        let normalized = Self.normalized(apiKey)
        guard !normalized.isEmpty else {
            throw CodexCredentialStoreError.invalidData
        }
        try keychain.upsert(
            service: service,
            account: account,
            data: Data(normalized.utf8)
        )
    }

    public func load() throws -> String? {
        guard let data = try keychain.read(
            service: service,
            account: account
        ) else {
            return nil
        }
        guard let value = String(data: data, encoding: .utf8) else {
            throw CodexCredentialStoreError.invalidData
        }
        let normalized = Self.normalized(value)
        guard !normalized.isEmpty else {
            throw CodexCredentialStoreError.invalidData
        }
        return normalized
    }

    public func delete() throws {
        try keychain.delete(service: service, account: account)
    }

    private static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
