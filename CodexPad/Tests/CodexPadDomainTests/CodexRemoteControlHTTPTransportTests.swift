import CodexPadDomain
import Foundation
import Testing

@testable import CodexPadApplication

private struct RemoteControlHTTPStub: Sendable {
    let statusCode: Int
    let data: Data
    let headers: [String: String]

    init(
        statusCode: Int = 200,
        body: String,
        headers: [String: String] = [
            "Content-Type": "application/json",
        ]
    ) {
        self.statusCode = statusCode
        data = Data(body.utf8)
        self.headers = headers
    }
}

private enum RemoteControlHTTPProbeError: Error, Sendable {
    case exhausted
}

private actor RemoteControlHTTPExecutorProbe:
    CodexRemoteControlHTTPExecuting
{
    private var stubs: [RemoteControlHTTPStub]
    private var requests: [URLRequest] = []

    init(_ stubs: [RemoteControlHTTPStub]) {
        self.stubs = stubs
    }

    func execute(
        _ request: URLRequest
    ) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        guard !stubs.isEmpty else {
            throw RemoteControlHTTPProbeError.exhausted
        }
        let stub = stubs.removeFirst()
        return (
            stub.data,
            HTTPURLResponse(
                url: request.url
                    ?? URL(string: "http://localhost/")!,
                statusCode: stub.statusCode,
                httpVersion: nil,
                headerFields: stub.headers
            )!
        )
    }

    func recordedRequests() -> [URLRequest] {
        requests
    }
}

private actor RemoteControlHTTPTimeoutExecutor:
    CodexRemoteControlHTTPExecuting
{
    private var requests: [URLRequest] = []

    func execute(
        _ request: URLRequest
    ) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        throw URLError(.timedOut)
    }

    func recordedRequests() -> [URLRequest] {
        requests
    }
}

private actor RemoteControlAuthRecoveryProbe {
    private let result: CodexRemoteControlAccountAuth?
    private var callCount = 0

    init(result: CodexRemoteControlAccountAuth?) {
        self.result = result
    }

    func recover() -> CodexRemoteControlAccountAuth? {
        callCount += 1
        return result
    }

    func calls() -> Int {
        callCount
    }
}

private let remoteControlHTTPBaseURL =
    URL(string: "http://localhost:7443/backend-api")!
private let remoteControlHTTPAuth = CodexRemoteControlAccountAuth(
    accessToken: "account-token",
    accountID: "account-id"
)

private func remoteControlJSONObject(
    _ request: URLRequest
) throws -> [String: Any] {
    try #require(
        JSONSerialization.jsonObject(
            with: request.httpBody ?? Data()
        ) as? [String: Any]
    )
}

private func remoteControlHTTPError(
    _ operation: () async throws -> Void
) async -> CodexRemoteControlHTTPError? {
    do {
        try await operation()
        return nil
    } catch let error as CodexRemoteControlHTTPError {
        return error
    } catch {
        Issue.record("Unexpected error type: \(error)")
        return nil
    }
}

@Test
func remoteControlHTTPBaseURLSecurityMatchesOfficialAllowlist() throws {
    let executor = RemoteControlHTTPExecutorProbe([])
    let defaultTransport = try CodexRemoteControlHTTPTransport(
        executor: executor
    )
    #expect(
        defaultTransport.baseURL.absoluteString
            == "https://chatgpt.com/backend-api/"
    )

    for candidate in [
        "https://chatgpt.com/backend-api",
        "https://api.chatgpt.com/backend-api",
        "https://chatgpt-staging.com/backend-api",
        "https://api.chatgpt-staging.com/backend-api",
        "http://localhost:8080/backend-api",
        "https://localhost:8443/backend-api",
        "http://127.0.0.1:8080/backend-api",
        "http://[::1]:8080/backend-api",
    ] {
        let transport = try CodexRemoteControlHTTPTransport(
            baseURL: try #require(URL(string: candidate)),
            executor: executor
        )
            #expect(transport.baseURL.absoluteString.hasSuffix("/"))
    }

    for candidate in [
        "http://chatgpt.com/backend-api",
        "http://example.com/backend-api",
        "https://example.com/backend-api",
        "https://chat.openai.com/backend-api",
        "https://chatgpt.com.evil.com/backend-api",
        "https://evilchatgpt.com/backend-api",
        "https://foo.localhost/backend-api",
    ] {
        #expect(throws: CodexRemoteControlHTTPError.self) {
            _ = try CodexRemoteControlHTTPTransport(
                baseURL: try #require(URL(string: candidate)),
                executor: executor
            )
        }
    }
}

@Test
func remoteControlHTTPEnrollUsesExactAccountAndInstallationWire()
    async throws
{
    let executor = RemoteControlHTTPExecutorProbe([
        RemoteControlHTTPStub(
            body: """
                {
                  "server_id": "server-1",
                  "environment_id": "environment-1",
                  "remote_control_token": "server-token",
                  "expires_at": "1970-01-01T00:00:42Z"
                }
                """
        ),
    ])
    let transport = try CodexRemoteControlHTTPTransport(
        baseURL: remoteControlHTTPBaseURL,
        executor: executor
    )

    let enrollment = try await transport.enroll(
        auth: remoteControlHTTPAuth,
        installationID: "installation-1",
        serverName: "Codex for ipad",
        operatingSystem: "ios",
        architecture: "arm64",
        appServerVersion: "0.0.0"
    )

    #expect(
        enrollment == CodexRemoteControlHTTPEnrollment(
            serverID: "server-1",
            environmentID: "environment-1",
            remoteControlToken: "server-token",
            expiresAt: 42,
            accountID: "account-id"
        )
    )
    let request = try #require(
        await executor.recordedRequests().first
    )
    #expect(request.httpMethod == "POST")
    #expect(
        request.url?.path
            == "/backend-api/wham/remote/control/server/enroll"
    )
    #expect(
        request.value(forHTTPHeaderField: "Authorization")
            == "Bearer account-token"
    )
    #expect(
        request.value(forHTTPHeaderField: "chatgpt-account-id")
            == "account-id"
    )
    #expect(
        request.value(
            forHTTPHeaderField: "x-codex-installation-id"
        ) == "installation-1"
    )
    #expect(
        request.value(forHTTPHeaderField: "Content-Type")
            == "application/json"
    )
    let body = try remoteControlJSONObject(request)
    #expect(body.count == 5)
    #expect(body["name"] as? String == "Codex for ipad")
    #expect(body["os"] as? String == "ios")
    #expect(body["arch"] as? String == "arm64")
    #expect(body["app_server_version"] as? String == "0.0.0")
    #expect(body["installation_id"] as? String == "installation-1")
}

@Test
func remoteControlHTTPRefreshUsesExactWireAndChecksEnrollmentIdentity()
    async throws
{
    let executor = RemoteControlHTTPExecutorProbe([
        RemoteControlHTTPStub(
            body: """
                {
                  "server_id": "server-1",
                  "environment_id": "environment-1",
                  "remote_control_token": "refreshed-token",
                  "expires_at": "1970-01-01T00:01:24Z"
                }
                """
        ),
    ])
    let transport = try CodexRemoteControlHTTPTransport(
        baseURL: remoteControlHTTPBaseURL,
        executor: executor
    )

    let refreshed = try await transport.refresh(
        auth: remoteControlHTTPAuth,
        installationID: "installation-1",
        serverID: "server-1",
        environmentID: "environment-1"
    )

    #expect(refreshed.remoteControlToken == "refreshed-token")
    #expect(refreshed.expiresAt == 84)
    #expect(refreshed.accountID == "account-id")
    let request = try #require(
        await executor.recordedRequests().first
    )
    #expect(request.httpMethod == "POST")
    #expect(
        request.url?.path
            == "/backend-api/wham/remote/control/server/refresh"
    )
    #expect(
        request.value(forHTTPHeaderField: "Authorization")
            == "Bearer account-token"
    )
    #expect(
        request.value(forHTTPHeaderField: "chatgpt-account-id")
            == "account-id"
    )
    #expect(
        request.value(
            forHTTPHeaderField: "x-codex-installation-id"
        ) == "installation-1"
    )
    let body = try remoteControlJSONObject(request)
    #expect(body.count == 2)
    #expect(body["server_id"] as? String == "server-1")
    #expect(body["installation_id"] as? String == "installation-1")

    let mismatchExecutor = RemoteControlHTTPExecutorProbe([
        RemoteControlHTTPStub(
            body: """
                {
                  "server_id": "other-server",
                  "environment_id": "other-environment",
                  "remote_control_token": "refreshed-token",
                  "expires_at": "1970-01-01T00:01:24Z"
                }
                """
        ),
    ])
    let mismatchTransport = try CodexRemoteControlHTTPTransport(
        baseURL: remoteControlHTTPBaseURL,
        executor: mismatchExecutor
    )
    let error = await remoteControlHTTPError {
        _ = try await mismatchTransport.refresh(
            auth: remoteControlHTTPAuth,
            installationID: "installation-1",
            serverID: "server-1",
            environmentID: "environment-1"
        )
    }
    #expect(
        error == .mismatchedEnrollment(
            expectedServerID: "server-1",
            expectedEnvironmentID: "environment-1",
            actualServerID: "other-server",
            actualEnvironmentID: "other-environment"
        )
    )
}

@Test
func remoteControlHTTPPairUsesOnlyServerBearerAndMapsRFC3339()
    async throws
{
    let executor = RemoteControlHTTPExecutorProbe([
        RemoteControlHTTPStub(
            body: """
                {
                  "pairing_code": "pair-code",
                  "manual_pairing_code": null,
                  "server_id": "server-1",
                  "environment_id": "environment-1",
                  "expires_at": "1970-01-01T00:01:40.900Z"
                }
                """
        ),
    ])
    let transport = try CodexRemoteControlHTTPTransport(
        baseURL: remoteControlHTTPBaseURL,
        executor: executor
    )

    let pairing = try await transport.startPairing(
        serverToken: "server-token",
        serverID: "server-1",
        environmentID: "environment-1",
        manualCode: false
    )

    #expect(pairing.pairingCode == "pair-code")
    #expect(pairing.manualPairingCode == nil)
    #expect(pairing.environmentId == "environment-1")
    #expect(pairing.expiresAt == 100)
    let request = try #require(
        await executor.recordedRequests().first
    )
    #expect(request.httpMethod == "POST")
    #expect(
        request.url?.path
            == "/backend-api/wham/remote/control/server/pair"
    )
    #expect(
        request.value(forHTTPHeaderField: "Authorization")
            == "Bearer server-token"
    )
    #expect(
        request.value(forHTTPHeaderField: "chatgpt-account-id") == nil
    )
    #expect(
        request.value(
            forHTTPHeaderField: "x-codex-installation-id"
        ) == nil
    )
    let body = try remoteControlJSONObject(request)
    #expect(body.count == 1)
    #expect(body["manual_code"] as? Bool == false)
}

@Test
func remoteControlHTTPPairStatusOmitsUnusedCodeAndMapsStatusErrors()
    async throws
{
    let executor = RemoteControlHTTPExecutorProbe([
        RemoteControlHTTPStub(body: #"{"claimed":true}"#),
        RemoteControlHTTPStub(body: #"{"claimed":false}"#),
    ])
    let transport = try CodexRemoteControlHTTPTransport(
        baseURL: remoteControlHTTPBaseURL,
        executor: executor
    )

    let status = try await transport.pairingStatus(
        serverToken: "server-token",
        manualPairingCode: "manual-code"
    )

    #expect(status.claimed)
    let request = try #require(
        await executor.recordedRequests().first
    )
    #expect(request.httpMethod == "POST")
    #expect(
        request.url?.path
            == "/backend-api/wham/remote/control/server/pair/status"
    )
    #expect(
        request.value(forHTTPHeaderField: "Authorization")
            == "Bearer server-token"
    )
    let body = try remoteControlJSONObject(request)
    #expect(body.count == 1)
    #expect(body["manual_pairing_code"] as? String == "manual-code")
    #expect(body["pairing_code"] == nil)

    let emptyCodeStatus = try await transport.pairingStatus(
        serverToken: "server-token",
        pairingCode: ""
    )
    #expect(!emptyCodeStatus.claimed)
    let emptyCodeRequest = try #require(
        await executor.recordedRequests().last
    )
    let emptyCodeBody = try remoteControlJSONObject(emptyCodeRequest)
    #expect(emptyCodeBody.count == 1)
    #expect(emptyCodeBody["pairing_code"] as? String == "")
    #expect(emptyCodeBody["manual_pairing_code"] == nil)

    let goneExecutor = RemoteControlHTTPExecutorProbe([
        RemoteControlHTTPStub(statusCode: 410, body: #"{"error":"gone"}"#),
    ])
    let goneTransport = try CodexRemoteControlHTTPTransport(
        baseURL: remoteControlHTTPBaseURL,
        executor: goneExecutor
    )
    let error = await remoteControlHTTPError {
        _ = try await goneTransport.pairingStatus(
            serverToken: "server-token",
            pairingCode: "pair-code"
        )
    }
    #expect(
        error == .httpStatus(
            endpoint: .pairStatus,
            statusCode: 410,
            classification: .invalidInput
        )
    )
}

@Test
func remoteControlHTTPClientListUsesExactQueryAndMapsBackendWire()
    async throws
{
    let executor = RemoteControlHTTPExecutorProbe([
        RemoteControlHTTPStub(
            body: """
                {
                  "items": [
                    {
                      "client_id": "client-1",
                      "display_name": "Example iPad",
                      "device_type": "tablet",
                      "platform": "iPadOS",
                      "os_version": "18.0",
                      "device_model": "iPad",
                      "app_version": "26.727.51351",
                      "last_seen_at": "1970-01-01T00:02:03.900Z"
                    }
                  ],
                  "cursor": "next-cursor"
                }
                """
        ),
    ])
    let transport = try CodexRemoteControlHTTPTransport(
        baseURL: remoteControlHTTPBaseURL,
        executor: executor
    )

    let response = try await transport.listClients(
        auth: remoteControlHTTPAuth,
        params: CodexRemoteControlClientsListParams(
            environmentId: "environment /?",
            cursor: "cursor /?",
            limit: 100,
            order: .desc
        )
    )

    #expect(response.nextCursor == "next-cursor")
    #expect(response.data.count == 1)
    let client = try #require(response.data.first)
    #expect(client.clientId == "client-1")
    #expect(client.displayName == "Example iPad")
    #expect(client.deviceType == "tablet")
    #expect(client.platform == "iPadOS")
    #expect(client.osVersion == "18.0")
    #expect(client.deviceModel == "iPad")
    #expect(client.appVersion == "26.727.51351")
    #expect(client.lastSeenAt == 123)

    let request = try #require(
        await executor.recordedRequests().first
    )
    #expect(request.httpMethod == "GET")
    #expect(
        request.url.flatMap {
            URLComponents(
                url: $0,
                resolvingAgainstBaseURL: false
            )?.percentEncodedPath
        } == "/backend-api/wham/remote/control/environments/environment%20%2F%3F/clients"
    )
    let components = URLComponents(
        url: try #require(request.url),
        resolvingAgainstBaseURL: false
    )
    #expect(
        components?.percentEncodedQuery
            == "cursor=cursor+%2F%3F&limit=100&order=desc"
    )
    let query = components?.queryItems
    #expect(query?.map(\.name) == ["cursor", "limit", "order"])
    #expect(query?[1].value == "100")
    #expect(query?[2].value == "desc")
    #expect(
        request.value(forHTTPHeaderField: "Authorization")
            == "Bearer account-token"
    )
    #expect(
        request.value(forHTTPHeaderField: "chatgpt-account-id")
            == "account-id"
    )
    #expect(request.httpBody == nil)
    #expect(request.value(forHTTPHeaderField: "Content-Type") == nil)
}

@Test
func remoteControlHTTPClientRevokeUsesExactEscapedPathAndNoBody()
    async throws
{
    let executor = RemoteControlHTTPExecutorProbe([
        RemoteControlHTTPStub(statusCode: 204, body: ""),
    ])
    let transport = try CodexRemoteControlHTTPTransport(
        baseURL: remoteControlHTTPBaseURL,
        executor: executor
    )

    _ = try await transport.revokeClient(
        auth: remoteControlHTTPAuth,
        params: CodexRemoteControlClientsRevokeParams(
            environmentId: "environment-1",
            clientId: "client/one"
        )
    )

    let request = try #require(
        await executor.recordedRequests().first
    )
    #expect(request.httpMethod == "DELETE")
    #expect(
        request.url.flatMap {
            URLComponents(
                url: $0,
                resolvingAgainstBaseURL: false
            )?.percentEncodedPath
        } == "/backend-api/wham/remote/control/environments/environment-1/clients/client%2Fone"
    )
    #expect(request.url?.query == nil)
    #expect(request.httpBody == nil)
    #expect(
        request.value(forHTTPHeaderField: "Authorization")
            == "Bearer account-token"
    )
    #expect(
        request.value(forHTTPHeaderField: "chatgpt-account-id")
            == "account-id"
    )
}

@Test
func remoteControlHTTPClientManagementRecoversOnceAndRetriesOnce()
    async throws
{
    let recoveredAuth = CodexRemoteControlAccountAuth(
        accessToken: "recovered-token",
        accountID: "recovered-account"
    )
    let listRecovery = RemoteControlAuthRecoveryProbe(
        result: recoveredAuth
    )
    let listExecutor = RemoteControlHTTPExecutorProbe([
        RemoteControlHTTPStub(statusCode: 401, body: "{}"),
        RemoteControlHTTPStub(body: #"{"items":[],"cursor":null}"#),
    ])
    let listTransport = try CodexRemoteControlHTTPTransport(
        baseURL: remoteControlHTTPBaseURL,
        executor: listExecutor,
        authRecovery: {
            await listRecovery.recover()
        }
    )

    let response = try await listTransport.listClients(
        auth: remoteControlHTTPAuth,
        params: CodexRemoteControlClientsListParams(
            environmentId: "environment-1"
        )
    )

    #expect(response.data.isEmpty)
    #expect(await listRecovery.calls() == 1)
    let listRequests = await listExecutor.recordedRequests()
    #expect(listRequests.count == 2)
    #expect(
        listRequests[0].value(forHTTPHeaderField: "Authorization")
            == "Bearer account-token"
    )
    #expect(
        listRequests[1].value(forHTTPHeaderField: "Authorization")
            == "Bearer recovered-token"
    )
    #expect(
        listRequests[1].value(
            forHTTPHeaderField: "chatgpt-account-id"
        ) == "recovered-account"
    )

    let revokeRecovery = RemoteControlAuthRecoveryProbe(
        result: recoveredAuth
    )
    let revokeExecutor = RemoteControlHTTPExecutorProbe([
        RemoteControlHTTPStub(statusCode: 401, body: "{}"),
        RemoteControlHTTPStub(statusCode: 401, body: "{}"),
    ])
    let revokeTransport = try CodexRemoteControlHTTPTransport(
        baseURL: remoteControlHTTPBaseURL,
        executor: revokeExecutor,
        authRecovery: {
            await revokeRecovery.recover()
        }
    )
    let revokeError = await remoteControlHTTPError {
        _ = try await revokeTransport.revokeClient(
            auth: remoteControlHTTPAuth,
            params: CodexRemoteControlClientsRevokeParams(
                environmentId: "environment-1",
                clientId: "client-1"
            )
        )
    }
    #expect(
        revokeError == .httpStatus(
            endpoint: .clientRevoke,
            statusCode: 401,
            classification: .permissionDenied
        )
    )
    #expect(await revokeRecovery.calls() == 1)
    #expect(await revokeExecutor.recordedRequests().count == 2)
}

@Test
func remoteControlHTTPAccountProviderHeadersArePreservedButIdentityIsSelected()
    async throws
{
    let executor = RemoteControlHTTPExecutorProbe([
        RemoteControlHTTPStub(body: #"{"items":[],"cursor":null}"#),
    ])
    let auth = CodexRemoteControlAccountAuth(
        accessToken: "selected-token",
        accountID: "selected-account",
        providerHeaders: [
            "Authorization": "Bearer provider-token-one",
            "AUTHORIZATION": "Bearer provider-token-two",
            "ChatGPT-Account-ID": "provider-account-one",
            "chatgpt-account-id": "provider-account-two",
            "x-openai-fedramp": "true",
        ]
    )
    let transport = try CodexRemoteControlHTTPTransport(
        baseURL: remoteControlHTTPBaseURL,
        executor: executor
    )

    _ = try await transport.listClients(
        auth: auth,
        params: CodexRemoteControlClientsListParams(
            environmentId: "environment-1"
        )
    )

    let request = try #require(
        await executor.recordedRequests().first
    )
    #expect(
        request.value(forHTTPHeaderField: "Authorization")
            == "Bearer selected-token"
    )
    #expect(
        request.value(forHTTPHeaderField: "chatgpt-account-id")
            == "selected-account"
    )
    #expect(
        request.value(forHTTPHeaderField: "x-openai-fedramp")
            == "true"
    )
    let headerNames = (request.allHTTPHeaderFields ?? [:]).keys
    #expect(
        headerNames.filter {
            $0.caseInsensitiveCompare("Authorization") == .orderedSame
        }.count == 1
    )
    #expect(
        headerNames.filter {
            $0.caseInsensitiveCompare("chatgpt-account-id") == .orderedSame
        }.count == 1
    )
}

@Test
func remoteControlHTTPDefaultHeadersAndThirtySecondTimeoutReachAllSixEndpoints()
    async throws
{
    let executor = RemoteControlHTTPExecutorProbe([
        RemoteControlHTTPStub(
            body: """
                {
                  "server_id": "server-1",
                  "environment_id": "environment-1",
                  "remote_control_token": "server-token",
                  "expires_at": "1970-01-01T00:00:42Z"
                }
                """
        ),
        RemoteControlHTTPStub(
            body: """
                {
                  "server_id": "server-1",
                  "environment_id": "environment-1",
                  "remote_control_token": "refreshed-token",
                  "expires_at": "1970-01-01T00:01:24Z"
                }
                """
        ),
        RemoteControlHTTPStub(
            body: """
                {
                  "pairing_code": "pair-code",
                  "manual_pairing_code": null,
                  "server_id": "server-1",
                  "environment_id": "environment-1",
                  "expires_at": "1970-01-01T00:01:40Z"
                }
                """
        ),
        RemoteControlHTTPStub(body: #"{"claimed":false}"#),
        RemoteControlHTTPStub(body: #"{"items":[],"cursor":null}"#),
        RemoteControlHTTPStub(statusCode: 204, body: ""),
    ])
    let auth = CodexRemoteControlAccountAuth(
        accessToken: "account-token",
        accountID: "account-id",
        providerHeaders: ["x-openai-fedramp": "true"]
    )
    let transport = try CodexRemoteControlHTTPTransport(
        baseURL: remoteControlHTTPBaseURL,
        executor: executor,
        headerContext: CodexRemoteControlHTTPHeaderContext(
            originator: "codex_desktop",
            userAgent: "codex_desktop/0.146.0-alpha.9.2",
            residency: "us"
        )
    )

    _ = try await transport.enroll(
        auth: auth,
        installationID: "installation-1",
        serverName: "Codex for ipad",
        operatingSystem: "ios",
        architecture: "arm64",
        appServerVersion: "0.146.0-alpha.9.2"
    )
    _ = try await transport.refresh(
        auth: auth,
        installationID: "installation-1",
        serverID: "server-1",
        environmentID: "environment-1"
    )
    _ = try await transport.startPairing(
        serverToken: "server-token",
        serverID: "server-1",
        environmentID: "environment-1",
        manualCode: false
    )
    _ = try await transport.pairingStatus(
        serverToken: "server-token",
        pairingCode: "pair-code"
    )
    _ = try await transport.listClients(
        auth: auth,
        params: CodexRemoteControlClientsListParams(
            environmentId: "environment-1"
        )
    )
    _ = try await transport.revokeClient(
        auth: auth,
        params: CodexRemoteControlClientsRevokeParams(
            environmentId: "environment-1",
            clientId: "client-1"
        )
    )

    let requests = await executor.recordedRequests()
    #expect(requests.count == 6)
    for request in requests {
        #expect(
            request.value(forHTTPHeaderField: "originator")
                == "codex_desktop"
        )
        #expect(
            request.value(forHTTPHeaderField: "User-Agent")
                == "codex_desktop/0.146.0-alpha.9.2"
        )
        #expect(
            request.value(
                forHTTPHeaderField: "x-openai-internal-codex-residency"
            ) == "us"
        )
        #expect(request.timeoutInterval == 30)
    }
    for index in [0, 1, 4, 5] {
        #expect(
            requests[index].value(forHTTPHeaderField: "x-openai-fedramp")
                == "true"
        )
        #expect(
            requests[index].value(
                forHTTPHeaderField: "chatgpt-account-id"
            ) == "account-id"
        )
    }
    for index in [2, 3] {
        #expect(
            requests[index].value(forHTTPHeaderField: "Authorization")
                == "Bearer server-token"
        )
        #expect(
            requests[index].value(
                forHTTPHeaderField: "chatgpt-account-id"
            ) == nil
        )
        #expect(
            requests[index].value(forHTTPHeaderField: "x-openai-fedramp")
                == nil
        )
    }
}

@Test
func remoteControlHTTPEnrollAndRefreshMapTransportTimeoutsToTypedErrors()
    async throws
{
    let executor = RemoteControlHTTPTimeoutExecutor()
    let transport = try CodexRemoteControlHTTPTransport(
        baseURL: remoteControlHTTPBaseURL,
        executor: executor
    )

    let enrollError = await remoteControlHTTPError {
        _ = try await transport.enroll(
            auth: remoteControlHTTPAuth,
            installationID: "installation-1",
            serverName: "Codex for ipad",
            operatingSystem: "ios",
            architecture: "arm64",
            appServerVersion: "0.146.0-alpha.9.2"
        )
    }
    #expect(enrollError == .timeout(endpoint: .enroll))

    let refreshError = await remoteControlHTTPError {
        _ = try await transport.refresh(
            auth: remoteControlHTTPAuth,
            installationID: "installation-1",
            serverID: "server-1",
            environmentID: "environment-1"
        )
    }
    #expect(refreshError == .timeout(endpoint: .refresh))
    let requests = await executor.recordedRequests()
    #expect(requests.count == 2)
    #expect(requests.allSatisfy { $0.timeoutInterval == 30 })
}

@Test
func remoteControlHTTPTypedDecodeTimestampAndValidationErrorsDoNotFakeSuccess()
    async throws
{
    let decodeExecutor = RemoteControlHTTPExecutorProbe([
        RemoteControlHTTPStub(body: #"{"server_id":"incomplete"}"#),
    ])
    let decodeTransport = try CodexRemoteControlHTTPTransport(
        baseURL: remoteControlHTTPBaseURL,
        executor: decodeExecutor
    )
    let decodeError = await remoteControlHTTPError {
        _ = try await decodeTransport.enroll(
            auth: remoteControlHTTPAuth,
            installationID: "installation-1",
            serverName: "Codex for ipad",
            operatingSystem: "ios",
            architecture: "arm64",
            appServerVersion: "0.0.0"
        )
    }
    #expect(decodeError == .decoding(endpoint: .enroll))

    let timestampExecutor = RemoteControlHTTPExecutorProbe([
        RemoteControlHTTPStub(
            body: """
                {
                  "items": [
                    {
                      "client_id": "client-1",
                      "last_seen_at": "yesterday"
                    }
                  ]
                }
                """
        ),
    ])
    let timestampTransport = try CodexRemoteControlHTTPTransport(
        baseURL: remoteControlHTTPBaseURL,
        executor: timestampExecutor
    )
    let timestampError = await remoteControlHTTPError {
        _ = try await timestampTransport.listClients(
            auth: remoteControlHTTPAuth,
            params: CodexRemoteControlClientsListParams(
                environmentId: "environment-1"
            )
        )
    }
    #expect(
        timestampError == .invalidTimestamp(
            field: "last_seen_at",
            value: "yesterday"
        )
    )

    let validationExecutor = RemoteControlHTTPExecutorProbe([])
    let validationTransport = try CodexRemoteControlHTTPTransport(
        baseURL: remoteControlHTTPBaseURL,
        executor: validationExecutor
    )
    for limit: UInt32 in [0, 101] {
        let error = await remoteControlHTTPError {
            _ = try await validationTransport.listClients(
                auth: remoteControlHTTPAuth,
                params: CodexRemoteControlClientsListParams(
                    environmentId: "environment-1",
                    limit: limit
                )
            )
        }
        #expect(error == .invalidLimit(limit))
    }
    let emptyEnvironmentError = await remoteControlHTTPError {
        _ = try await validationTransport.listClients(
            auth: remoteControlHTTPAuth,
            params: CodexRemoteControlClientsListParams(
                environmentId: ""
            )
        )
    }
    #expect(
        emptyEnvironmentError == .invalidValue(
            field: "environmentId"
        )
    )
    let bothCodesError = await remoteControlHTTPError {
        _ = try await validationTransport.pairingStatus(
            serverToken: "server-token",
            pairingCode: "pair-code",
            manualPairingCode: "manual-code"
        )
    }
    #expect(
        bothCodesError == .invalidValue(
            field: "exactly one pairingCode or manualPairingCode"
        )
    )
    #expect(await validationExecutor.recordedRequests().isEmpty)
}

@Test
func remoteControlHTTPRFC3339ConvertsToAndFromInt64Seconds() throws {
    #expect(
        try CodexRemoteControlRFC3339.unixSeconds(
            from: "1970-01-01T01:00:01+01:00",
            field: "fixture"
        ) == 1
    )
    #expect(
        try CodexRemoteControlRFC3339.unixSeconds(
            from: "1970-01-01T00:00:42.999Z",
            field: "fixture"
        ) == 42
    )
    #expect(
        try CodexRemoteControlRFC3339.unixSeconds(
            from: "1970-01-01 00:00:01z",
            field: "fixture"
        ) == 1
    )
    #expect(
        try CodexRemoteControlRFC3339.unixSeconds(
            from: "1970-01-01T00:00:42.12345678901234567890z",
            field: "fixture"
        ) == 42
    )
    #expect(
        try CodexRemoteControlRFC3339.unixSeconds(
            from: "1998-12-31T23:59:60Z",
            field: "fixture"
        ) == 915_148_799
    )
    #expect(
        CodexRemoteControlRFC3339.string(fromUnixSeconds: 42)
            == "1970-01-01T00:00:42Z"
    )
    #expect(throws: CodexRemoteControlHTTPError.self) {
        _ = try CodexRemoteControlRFC3339.unixSeconds(
            from: "not-a-time",
            field: "fixture"
        )
    }
}
