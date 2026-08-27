import Foundation
import Testing
@testable import CodexPadApplication
@testable import CodexPadProtocolBridge

@Test
func chatGPTCredentialStoreSplitsLargeTokensIntoCommittedRevision()
    throws
{
    let keychain = CredentialKeychainProbe(maxItemBytes: 6_000)
    let store = CodexCredentialStore(
        service: "test.chatgpt",
        account: "oauth-tokens",
        keychain: keychain,
        makeRevision: { "revision-large" }
    )
    let tokens = try makeCredentialTokens(repeating: 5_000)

    try store.save(tokens)

    #expect(try store.load() == tokens)
    let snapshot = keychain.snapshot()
    #expect(snapshot.count == 4)
    #expect(snapshot["oauth-tokens"] == nil)
    #expect(
        snapshot.keys.contains(
            "oauth-tokens.v2.revision-large.id-token"
        )
    )
    #expect(
        snapshot.keys.contains(
            "oauth-tokens.v2.revision-large.access-token"
        )
    )
    #expect(
        snapshot.keys.contains(
            "oauth-tokens.v2.revision-large.refresh-token"
        )
    )
    #expect(snapshot.keys.contains("oauth-tokens.v2.manifest"))
    #expect(snapshot.values.allSatisfy { $0.count <= 6_000 })
}

@Test
func chatGPTCredentialStoreCommitsManifestAfterAllTokenComponents()
    throws
{
    let keychain = CredentialKeychainProbe()
    let store = CodexCredentialStore(
        service: "test.chatgpt",
        account: "oauth-tokens",
        keychain: keychain,
        makeRevision: { "revision-order" }
    )

    try store.save(try makeCredentialTokens(repeating: 20))

    let upserts = keychain.operations().compactMap { operation -> String? in
        guard case let .upsert(account, _) = operation else {
            return nil
        }
        return account
    }
    #expect(
        upserts == [
            "oauth-tokens.v2.revision-order.id-token",
            "oauth-tokens.v2.revision-order.access-token",
            "oauth-tokens.v2.revision-order.refresh-token",
            "oauth-tokens.v2.manifest",
        ]
    )
}

@Test
func chatGPTCredentialStoreRollsBackPartialRevisionAndKeepsOldLogin()
    throws
{
    let keychain = CredentialKeychainProbe()
    let oldStore = CodexCredentialStore(
        service: "test.chatgpt",
        account: "oauth-tokens",
        keychain: keychain,
        makeRevision: { "revision-old" }
    )
    let oldTokens = try makeCredentialTokens(
        repeating: 30,
        marker: "old"
    )
    try oldStore.save(oldTokens)

    keychain.failUpsert(
        whenAccountContains:
            "oauth-tokens.v2.revision-new.access-token"
    )
    let newStore = CodexCredentialStore(
        service: "test.chatgpt",
        account: "oauth-tokens",
        keychain: keychain,
        makeRevision: { "revision-new" }
    )

    #expect(throws: CodexCredentialStoreError.self) {
        try newStore.save(
            try makeCredentialTokens(
                repeating: 40,
                marker: "new"
            )
        )
    }

    #expect(try oldStore.load() == oldTokens)
    #expect(
        !keychain.snapshot().keys.contains {
            $0.contains(".revision-new.")
        }
    )
}

@Test
func chatGPTCredentialStoreLoadsAndMigratesLegacySingleItem()
    throws
{
    let keychain = CredentialKeychainProbe()
    let legacyTokens = try makeCredentialTokens(
        repeating: 25,
        marker: "legacy"
    )
    keychain.seed(
        account: "oauth-tokens",
        data: try JSONEncoder().encode(legacyTokens)
    )
    let store = CodexCredentialStore(
        service: "test.chatgpt",
        account: "oauth-tokens",
        keychain: keychain,
        makeRevision: { "revision-migrated" }
    )

    #expect(try store.load() == legacyTokens)

    let snapshot = keychain.snapshot()
    #expect(snapshot["oauth-tokens"] == nil)
    #expect(snapshot["oauth-tokens.v2.manifest"] != nil)
    #expect(
        snapshot[
            "oauth-tokens.v2.revision-migrated.refresh-token"
        ] != nil
    )
    #expect(try store.load() == legacyTokens)
}

@Test
func chatGPTCredentialStoreDeleteRemovesManifestRevisionAndLegacy()
    throws
{
    let keychain = CredentialKeychainProbe()
    let store = CodexCredentialStore(
        service: "test.chatgpt",
        account: "oauth-tokens",
        keychain: keychain,
        makeRevision: { "revision-delete" }
    )
    try store.save(try makeCredentialTokens(repeating: 10))
    keychain.seed(
        account: "oauth-tokens",
        data: Data("stale-legacy".utf8)
    )

    try store.delete()

    #expect(keychain.snapshot().isEmpty)
    #expect(try store.load() == nil)
}

@Test
func chatGPTCredentialFailuresAndDescriptionsDoNotRevealTokens()
    throws
{
    let secret = "credential-secret-marker"
    let tokens = try CodexChatGPTTokens(
        idToken: "\(secret)-id",
        accessToken: "\(secret)-access",
        refreshToken: "\(secret)-refresh"
    )
    let keychain = CredentialKeychainProbe()
    keychain.failUpsert(whenAccountContains: ".access-token")
    let store = CodexCredentialStore(
        service: "test.chatgpt",
        account: "oauth-tokens",
        keychain: keychain,
        makeRevision: { "revision-redaction" }
    )

    var renderedError = ""
    do {
        try store.save(tokens)
    } catch {
        renderedError = String(describing: error)
    }

    #expect(!tokens.description.contains(secret))
    #expect(!tokens.debugDescription.contains(secret))
    #expect(!renderedError.contains(secret))
}

@Test
func apiKeyCredentialStoreSavesUpdatesLoadsAndDeletes() throws {
    let keychain = CredentialKeychainProbe()
    let store = CodexAPIKeyCredentialStore(
        service: "test.openai",
        account: "api-key",
        keychain: keychain
    )

    try store.save("  TEST_API_KEY_A  ")
    #expect(try store.load() == "TEST_API_KEY_A")

    try store.save("TEST_API_KEY_B")
    #expect(try store.load() == "TEST_API_KEY_B")

    try store.delete()
    #expect(try store.load() == nil)
}

@Test
func apiKeyCredentialStoreRejectsEmptyAndInvalidPersistedValues() throws {
    let keychain = CredentialKeychainProbe()
    let store = CodexAPIKeyCredentialStore(
        service: "test.openai",
        account: "api-key",
        keychain: keychain
    )

    #expect(throws: CodexCredentialStoreError.invalidData) {
        try store.save(" \n\t ")
    }

    keychain.seed(
        account: "api-key",
        data: Data(" \n ".utf8)
    )
    #expect(throws: CodexCredentialStoreError.invalidData) {
        _ = try store.load()
    }
}

@Test @MainActor
func accountStoreRestoresAPIKeyAsReleasedAPIKeyAccount() throws {
    let keychain = CredentialKeychainProbe()
    let chatGPTStore = CodexCredentialStore(
        service: "test.chatgpt",
        account: "oauth-tokens",
        keychain: keychain,
        makeRevision: { "account-restore" }
    )
    let apiKeyStore = CodexAPIKeyCredentialStore(
        service: "test.openai",
        account: "api-key",
        keychain: keychain
    )
    try apiKeyStore.save("TEST_API_KEY_RESTORED")

    let accountStore = CodexAccountStore(
        credentials: chatGPTStore,
        apiKeyCredentials: apiKeyStore,
        restoreCredentials: true
    )

    #expect(accountStore.isSignedIn)
    #expect(accountStore.authMode == .apiKey)
    #expect(
        accountStore.desktopAccountState
            == CodexDesktopMCPAccountState(
                account: .apiKey,
                authMethod: .apiKey,
                requiresOpenAIAuth: true
            )
    )
    let providerCredentials = try #require(
        accountStore.officialCredentials()
    )
    #expect(providerCredentials.accessToken == "TEST_API_KEY_RESTORED")
    #expect(providerCredentials.accountID == nil)
    #expect(
        providerCredentials.baseURL
            == CodexOfficialCredentials.openAIAPIBaseURL
    )
}

@Test @MainActor
func accountStorePrefersRestoredChatGPTTokensOverStaleAPIKey() throws {
    let keychain = CredentialKeychainProbe()
    let chatGPTStore = CodexCredentialStore(
        service: "test.chatgpt",
        account: "oauth-tokens",
        keychain: keychain,
        makeRevision: { "account-restore-preferred" }
    )
    let apiKeyStore = CodexAPIKeyCredentialStore(
        service: "test.openai",
        account: "api-key",
        keychain: keychain
    )
    let tokens = try makeCredentialTokens(
        repeating: 25,
        marker: "oauth-preferred"
    )
    try chatGPTStore.save(tokens)
    try apiKeyStore.save("TEST_STALE_API_KEY")

    let accountStore = CodexAccountStore(
        credentials: chatGPTStore,
        apiKeyCredentials: apiKeyStore,
        restoreCredentials: true
    )

    #expect(accountStore.isChatGPTSignedIn)
    #expect(accountStore.authMode == .chatGPT)
    #expect(accountStore.officialCredentials()?.authMethod == .chatGPT)
    #expect(accountStore.officialCredentials()?.accessToken == tokens.accessToken)
}

@Test @MainActor
func accountStoreKeepsVerifiedAPIKeyActiveWhenOAuthCleanupFails()
    throws
{
    let keychain = CredentialKeychainProbe()
    let chatGPTStore = CodexCredentialStore(
        service: "test.chatgpt",
        account: "oauth-tokens",
        keychain: keychain,
        makeRevision: { "account-cleanup-failure" }
    )
    let apiKeyStore = CodexAPIKeyCredentialStore(
        service: "test.openai",
        account: "api-key",
        keychain: keychain
    )
    try chatGPTStore.save(
        try makeCredentialTokens(
            repeating: 16,
            marker: "previous-login"
        )
    )
    let accountStore = CodexAccountStore(
        credentials: chatGPTStore,
        apiKeyCredentials: apiKeyStore,
        restoreCredentials: false
    )
    keychain.failDelete(whenAccountContains: "oauth-tokens")

    try accountStore.acceptAPIKey("  TEST_API_KEY_VERIFIED  ")

    #expect(accountStore.isSignedIn)
    #expect(accountStore.authMode == .apiKey)
    #expect(accountStore.officialCredentials()?.accessToken
        == "TEST_API_KEY_VERIFIED")
    #expect(try apiKeyStore.load() == "TEST_API_KEY_VERIFIED")
    #expect(
        accountStore.problem
            == "API key saved, but the previous ChatGPT sign-in could not be removed."
    )
}

@Test @MainActor
func accountStoreDoesNotActivateAPIKeyWhenKeychainSaveFails() {
    let keychain = CredentialKeychainProbe()
    let chatGPTStore = CodexCredentialStore(
        service: "test.chatgpt",
        account: "oauth-tokens",
        keychain: keychain,
        makeRevision: { "unused" }
    )
    let apiKeyStore = CodexAPIKeyCredentialStore(
        service: "test.openai",
        account: "api-key",
        keychain: keychain
    )
    let accountStore = CodexAccountStore(
        credentials: chatGPTStore,
        apiKeyCredentials: apiKeyStore,
        restoreCredentials: false
    )
    keychain.failUpsert(whenAccountContains: "api-key")

    #expect(throws: CodexCredentialStoreError.self) {
        try accountStore.acceptAPIKey("TEST_API_KEY_REJECTED")
    }

    #expect(!accountStore.isSignedIn)
    #expect(accountStore.authMode == nil)
    #expect(accountStore.officialCredentials() == nil)
    #expect(
        accountStore.problem
            == "API key could not be saved (Keychain status -34018)."
    )
}

@Test @MainActor
func accountStoreDoesNotExposeAPIKeyToRemoteControl() async throws {
    let keychain = CredentialKeychainProbe()
    let accountStore = CodexAccountStore(
        credentials: CodexCredentialStore(
            service: "test.chatgpt",
            account: "oauth-tokens",
            keychain: keychain,
            makeRevision: { "unused" }
        ),
        apiKeyCredentials: CodexAPIKeyCredentialStore(
            service: "test.openai",
            account: "api-key",
            keychain: keychain
        ),
        restoreCredentials: false
    )
    try accountStore.acceptAPIKey("TEST_API_KEY_REMOTE_CONTROL")

    await #expect(
        throws: CodexRemoteControlAccountAuthAdapterError.signedOut
    ) {
        _ = try await accountStore
            .remoteControlAuthAdapter()
            .currentRemoteControlAuth()
    }
}

@Test @MainActor
func accountStoreKeepsVerifiedChatGPTLoginWhenAPIKeyCleanupFails()
    throws
{
    let keychain = CredentialKeychainProbe()
    let chatGPTStore = CodexCredentialStore(
        service: "test.chatgpt",
        account: "oauth-tokens",
        keychain: keychain,
        makeRevision: { "verified-chatgpt-login" }
    )
    let apiKeyStore = CodexAPIKeyCredentialStore(
        service: "test.openai",
        account: "api-key",
        keychain: keychain
    )
    try apiKeyStore.save("TEST_PREVIOUS_API_KEY")
    let accountStore = CodexAccountStore(
        credentials: chatGPTStore,
        apiKeyCredentials: apiKeyStore,
        restoreCredentials: false
    )
    keychain.failDelete(whenAccountContains: "api-key")
    let tokens = try makeCredentialTokens(
        repeating: 18,
        marker: "verified-chatgpt"
    )

    try accountStore.acceptChatGPTTokens(tokens)

    #expect(accountStore.isSignedIn)
    #expect(accountStore.isChatGPTSignedIn)
    #expect(accountStore.authMode == .chatGPT)
    #expect(accountStore.chatGPTCredentials()?.accessToken
        == tokens.accessToken)
    #expect(try chatGPTStore.load() == tokens)
    #expect(
        accountStore.problem
            == "ChatGPT sign-in saved, but the previous API key could not be removed."
    )
}

@Test @MainActor
func accountStoreDoesNotActivateChatGPTWhenKeychainSaveFails()
    throws
{
    let keychain = CredentialKeychainProbe()
    let chatGPTStore = CodexCredentialStore(
        service: "test.chatgpt",
        account: "oauth-tokens",
        keychain: keychain,
        makeRevision: { "rejected-chatgpt-login" }
    )
    let accountStore = CodexAccountStore(
        credentials: chatGPTStore,
        apiKeyCredentials: CodexAPIKeyCredentialStore(
            service: "test.openai",
            account: "api-key",
            keychain: keychain
        ),
        restoreCredentials: false
    )
    keychain.failUpsert(
        whenAccountContains:
            "oauth-tokens.v2.rejected-chatgpt-login.access-token"
    )

    #expect(throws: CodexCredentialStoreError.self) {
        try accountStore.acceptChatGPTTokens(
            try makeCredentialTokens(
                repeating: 18,
                marker: "rejected-chatgpt"
            )
        )
    }

    #expect(!accountStore.isSignedIn)
    #expect(accountStore.authMode == nil)
    #expect(accountStore.chatGPTCredentials() == nil)
    #expect(
        accountStore.problem
            == "ChatGPT sign-in could not be saved (Keychain status -34018)."
    )
}

@Test @MainActor
func accountStoreInvalidatesExpiredChatGPTSessionAfterRejectedRefresh()
    throws
{
    let keychain = CredentialKeychainProbe()
    let chatGPTStore = CodexCredentialStore(
        service: "test.chatgpt",
        account: "oauth-tokens",
        keychain: keychain,
        makeRevision: { "expired-chatgpt" }
    )
    let apiKeyStore = CodexAPIKeyCredentialStore(
        service: "test.openai",
        account: "api-key",
        keychain: keychain
    )
    let accountStore = CodexAccountStore(
        credentials: chatGPTStore,
        apiKeyCredentials: apiKeyStore,
        restoreCredentials: false
    )
    try accountStore.acceptChatGPTTokens(
        try makeCredentialTokens(
            repeating: 20,
            marker: "expired"
        )
    )
    try apiKeyStore.save("TEST_STALE_BUT_VALID_API_KEY")

    let invalidated =
        accountStore.invalidateExpiredChatGPTCredentials(
            afterRefreshFailure:
                CodexChatGPTAuthError.serverStatus(400)
        )

    #expect(invalidated)
    #expect(!accountStore.isSignedIn)
    #expect(!accountStore.isChatGPTSignedIn)
    #expect(accountStore.authMode == nil)
    #expect(accountStore.officialCredentials() == nil)
    #expect(try chatGPTStore.load() == nil)
    #expect(
        try apiKeyStore.load()
            == "TEST_STALE_BUT_VALID_API_KEY"
    )
    #expect(
        accountStore.problem
            == "ChatGPT session expired. Sign in again."
    )
}

@Test @MainActor
func accountStoreHidesExpiredChatGPTSessionWhenKeychainDeleteFails()
    throws
{
    let keychain = CredentialKeychainProbe()
    let chatGPTStore = CodexCredentialStore(
        service: "test.chatgpt",
        account: "oauth-tokens",
        keychain: keychain,
        makeRevision: { "expired-delete-failure" }
    )
    let accountStore = CodexAccountStore(
        credentials: chatGPTStore,
        apiKeyCredentials: CodexAPIKeyCredentialStore(
            service: "test.openai",
            account: "api-key",
            keychain: keychain
        ),
        restoreCredentials: false
    )
    try accountStore.acceptChatGPTTokens(
        try makeCredentialTokens(
            repeating: 20,
            marker: "expired-delete-failure"
        )
    )
    keychain.failDelete(
        whenAccountContains: "oauth-tokens"
    )

    let invalidated =
        accountStore.invalidateExpiredChatGPTCredentials(
            afterRefreshFailure:
                CodexChatGPTAuthError.serverStatus(401)
        )

    #expect(invalidated)
    #expect(!accountStore.isSignedIn)
    #expect(accountStore.authMode == nil)
    #expect(accountStore.officialCredentials() == nil)
    #expect(try chatGPTStore.load() != nil)
    #expect(
        accountStore.problem
            == "ChatGPT session expired. Sign in again. Saved credentials could not be removed."
    )
}

@Test @MainActor
func accountStoreDoesNotInvalidateAPIKeyOrTransientRefreshFailure()
    throws
{
    let keychain = CredentialKeychainProbe()
    let chatGPTStore = CodexCredentialStore(
        service: "test.chatgpt",
        account: "oauth-tokens",
        keychain: keychain,
        makeRevision: { "transient-refresh" }
    )
    let apiKeyStore = CodexAPIKeyCredentialStore(
        service: "test.openai",
        account: "api-key",
        keychain: keychain
    )
    let accountStore = CodexAccountStore(
        credentials: chatGPTStore,
        apiKeyCredentials: apiKeyStore,
        restoreCredentials: false
    )
    try accountStore.acceptChatGPTTokens(
        try makeCredentialTokens(
            repeating: 20,
            marker: "transient"
        )
    )

    #expect(
        !accountStore.invalidateExpiredChatGPTCredentials(
            afterRefreshFailure:
                CodexChatGPTAuthError.serverStatus(500)
        )
    )
    #expect(accountStore.isChatGPTSignedIn)

    try accountStore.acceptAPIKey("TEST_ACTIVE_API_KEY")
    #expect(
        !accountStore.invalidateExpiredChatGPTCredentials(
            afterRefreshFailure:
                CodexChatGPTAuthError.serverStatus(401)
        )
    )
    #expect(accountStore.authMode == .apiKey)
    #expect(
        accountStore.officialCredentials()?.accessToken
            == "TEST_ACTIVE_API_KEY"
    )
    #expect(try apiKeyStore.load() == "TEST_ACTIVE_API_KEY")
}

private func makeCredentialTokens(
    repeating count: Int,
    marker: String = "token"
) throws -> CodexChatGPTTokens {
    try CodexChatGPTTokens(
        idToken: "\(marker)-id-" + String(repeating: "i", count: count),
        accessToken:
            "\(marker)-access-" + String(repeating: "a", count: count),
        refreshToken:
            "\(marker)-refresh-" + String(repeating: "r", count: count)
    )
}

private final class CredentialKeychainProbe:
    CodexCredentialKeychain,
    @unchecked Sendable
{
    enum Operation: Equatable {
        case upsert(account: String, byteCount: Int)
        case read(account: String)
        case delete(account: String)
    }

    private let lock = NSLock()
    private let maxItemBytes: Int?
    private var items: [String: Data] = [:]
    private var recordedOperations: [Operation] = []
    private var failingAccountFragment: String?
    private var failingDeleteAccountFragment: String?

    init(maxItemBytes: Int? = nil) {
        self.maxItemBytes = maxItemBytes
    }

    func upsert(
        service _: String,
        account: String,
        data: Data
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        recordedOperations.append(
            .upsert(account: account, byteCount: data.count)
        )
        if let maxItemBytes, data.count > maxItemBytes {
            throw CodexCredentialStoreError.keychainStatus(-50)
        }
        if let failingAccountFragment,
           account.contains(failingAccountFragment)
        {
            throw CodexCredentialStoreError.keychainStatus(-34018)
        }
        items[account] = data
    }

    func read(
        service _: String,
        account: String
    ) throws -> Data? {
        lock.lock()
        defer { lock.unlock() }
        recordedOperations.append(.read(account: account))
        return items[account]
    }

    func delete(service _: String, account: String) throws {
        lock.lock()
        defer { lock.unlock() }
        recordedOperations.append(.delete(account: account))
        if let failingDeleteAccountFragment,
           account.contains(failingDeleteAccountFragment)
        {
            throw CodexCredentialStoreError.keychainStatus(-34018)
        }
        items.removeValue(forKey: account)
    }

    func seed(account: String, data: Data) {
        lock.lock()
        defer { lock.unlock() }
        items[account] = data
    }

    func failUpsert(whenAccountContains fragment: String) {
        lock.lock()
        defer { lock.unlock() }
        failingAccountFragment = fragment
    }

    func failDelete(whenAccountContains fragment: String) {
        lock.lock()
        defer { lock.unlock() }
        failingDeleteAccountFragment = fragment
    }

    func snapshot() -> [String: Data] {
        lock.lock()
        defer { lock.unlock() }
        return items
    }

    func operations() -> [Operation] {
        lock.lock()
        defer { lock.unlock() }
        return recordedOperations
    }
}
