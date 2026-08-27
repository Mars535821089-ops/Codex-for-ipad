import Foundation
import Testing
@testable import CodexPadApplication
@testable import CodexPadProtocolBridge

@Suite(.serialized)
struct CodexAccountCredentialRefreshAdapterTests {
    @Test @MainActor
    func refreshReturnsNewCredentialsWithoutAccountNotification() async throws {
        let fixture = try makeFixture(
            marker: "success",
            refreshStatus: 200,
            refreshBody: """
            {
              "access_token": "success-new-access",
              "refresh_token": "success-new-refresh"
            }
            """
        )
        var notifications: [CodexDesktopHostMessage] = []
        let adapter = CodexAccountCredentialRefreshAdapter(
            accountStore: fixture.accountStore,
            send: { notifications.append($0) }
        )

        let credentials = try await adapter.refresh()

        #expect(credentials.accessToken == "success-new-access")
        #expect(credentials.authMethod == .chatGPT)
        #expect(
            fixture.accountStore.officialCredentials()?.accessToken
                == "success-new-access"
        )
        #expect(notifications.isEmpty)
    }

    @Test @MainActor
    func rejectedRefreshInvalidatesAccountAndNotifiesReleasedRenderer()
        async throws
    {
        let fixture = try makeFixture(
            marker: "rejected",
            refreshStatus: 401,
            refreshBody: #"{"error":{"code":"invalid_grant"}}"#
        )
        var notifications: [CodexDesktopHostMessage] = []
        let adapter = CodexAccountCredentialRefreshAdapter(
            accountStore: fixture.accountStore,
            send: { notifications.append($0) }
        )

        await #expect(
            throws: CodexChatGPTAuthError.serverStatus(401)
        ) {
            _ = try await adapter.refresh()
        }

        #expect(!fixture.accountStore.isSignedIn)
        #expect(fixture.accountStore.officialCredentials() == nil)
        #expect(
            notifications == [
                .mcpNotification(
                    hostID: "local",
                    method: "account/updated",
                    params: .object([
                        "authMode": .null,
                        "planType": .null,
                    ]),
                    metadata: [:]
                )
            ]
        )
    }

    @Test @MainActor
    func transientRefreshFailureKeepsAccountAndSendsNoNotification()
        async throws
    {
        let fixture = try makeFixture(
            marker: "transient",
            refreshStatus: 500,
            refreshBody: #"{"error":{"code":"server_error"}}"#
        )
        var notifications: [CodexDesktopHostMessage] = []
        let adapter = CodexAccountCredentialRefreshAdapter(
            accountStore: fixture.accountStore,
            send: { notifications.append($0) }
        )

        await #expect(
            throws: CodexChatGPTAuthError.serverStatus(500)
        ) {
            _ = try await adapter.refresh()
        }

        #expect(fixture.accountStore.isChatGPTSignedIn)
        #expect(
            fixture.accountStore.officialCredentials()?.accessToken
                == "transient-access"
        )
        #expect(notifications.isEmpty)
    }

    @Test @MainActor
    func rejectedRefreshNotificationAndPublicProblemDoNotRevealTokens()
        async throws
    {
        let secret = "never-log-this-refresh-token"
        let fixture = try makeFixture(
            marker: secret,
            refreshStatus: 403,
            refreshBody: #"{"error":{"code":"invalid_grant"}}"#
        )
        var notifications: [CodexDesktopHostMessage] = []
        let adapter = CodexAccountCredentialRefreshAdapter(
            accountStore: fixture.accountStore,
            send: { notifications.append($0) }
        )

        await #expect(
            throws: CodexChatGPTAuthError.serverStatus(403)
        ) {
            _ = try await adapter.refresh()
        }

        #expect(!String(describing: notifications).contains(secret))
        #expect(
            !(fixture.accountStore.problem ?? "").contains(secret)
        )
    }

    @MainActor
    private func makeFixture(
        marker: String,
        refreshStatus: Int,
        refreshBody: String
    ) throws -> (
        accountStore: CodexAccountStore,
        session: URLSession
    ) {
        AccountRefreshURLProtocolStub.install { request in
            guard let url = request.url,
                  let response = HTTPURLResponse(
                      url: url,
                      statusCode: refreshStatus,
                      httpVersion: "HTTP/1.1",
                      headerFields: [
                          "Content-Type": "application/json"
                      ]
                  )
            else {
                throw URLError(.badServerResponse)
            }
            return (response, Data(refreshBody.utf8))
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [
            AccountRefreshURLProtocolStub.self
        ]
        let session = URLSession(configuration: configuration)
        let keychain = AccountRefreshCredentialKeychain()
        let accountStore = CodexAccountStore(
            credentials: CodexCredentialStore(
                service: "test.refresh.\(marker)",
                account: "oauth-tokens",
                keychain: keychain,
                makeRevision: { "refresh-revision" }
            ),
            apiKeyCredentials: CodexAPIKeyCredentialStore(
                service: "test.refresh.\(marker)",
                account: "api-key",
                keychain: keychain
            ),
            authClient: CodexChatGPTAuthClient(session: session),
            restoreCredentials: false
        )
        try accountStore.acceptChatGPTTokens(
            CodexChatGPTTokens(
                idToken: "\(marker)-id",
                accessToken: "\(marker)-access",
                refreshToken: "\(marker)-refresh"
            )
        )
        return (accountStore, session)
    }
}

private final class AccountRefreshURLProtocolStub: URLProtocol {
    typealias Handler = @Sendable (URLRequest) throws
        -> (HTTPURLResponse, Data)

    private static let lock = NSLock()
    nonisolated(unsafe) private static var handler: Handler?

    static func install(_ handler: @escaping Handler) {
        lock.withLock {
            self.handler = handler
        }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(
        for request: URLRequest
    ) -> URLRequest {
        request
    }

    override func startLoading() {
        let handler = Self.lock.withLock { Self.handler }
        guard let handler else {
            client?.urlProtocol(
                self,
                didFailWithError: URLError(.resourceUnavailable)
            )
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(
                self,
                didReceive: response,
                cacheStoragePolicy: .notAllowed
            )
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private final class AccountRefreshCredentialKeychain:
    CodexCredentialKeychain,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var items: [String: Data] = [:]

    func upsert(
        service _: String,
        account: String,
        data: Data
    ) throws {
        lock.withLock {
            items[account] = data
        }
    }

    func read(
        service _: String,
        account: String
    ) throws -> Data? {
        lock.withLock { items[account] }
    }

    func delete(service _: String, account: String) throws {
        _ = lock.withLock {
            items.removeValue(forKey: account)
        }
    }
}
