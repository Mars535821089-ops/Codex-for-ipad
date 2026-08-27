import Foundation
import Testing
@testable import CodexPadApplication
@testable import CodexPadDomain
@testable import CodexPadProtocolBridge

private enum RouterBackendError: Error { case failed }

private struct RouterBackendSnapshot: Sendable {
    let enable: [CodexRemoteControlEnableParams]
    let disable: [CodexRemoteControlDisableParams]
    let statusReadCount: Int
    let pairingStart: [CodexRemoteControlPairingStartParams]
    let pairingStatus: [CodexRemoteControlPairingStatusParams]
    let clientsList: [CodexRemoteControlClientsListParams]
    let clientsRevoke: [CodexRemoteControlClientsRevokeParams]
}

private actor RouterBackend: CodexRemoteControlBackend {
    private var failingOperation: String?
    private var enableCalls: [CodexRemoteControlEnableParams] = []
    private var disableCalls: [CodexRemoteControlDisableParams] = []
    private var statusReadCount = 0
    private var pairingStartCalls: [CodexRemoteControlPairingStartParams] = []
    private var pairingStatusCalls: [CodexRemoteControlPairingStatusParams] = []
    private var clientsListCalls: [CodexRemoteControlClientsListParams] = []
    private var clientsRevokeCalls: [CodexRemoteControlClientsRevokeParams] = []
    private let stream: AsyncThrowingStream<CodexRemoteControlStatusChangedNotification, Error>
    private let continuation: AsyncThrowingStream<CodexRemoteControlStatusChangedNotification, Error>.Continuation

    init() {
        let pair = AsyncThrowingStream<CodexRemoteControlStatusChangedNotification, Error>.makeStream()
        stream = pair.stream
        continuation = pair.continuation
    }

    func fail(_ operation: String) { failingOperation = operation }
    private func check(_ operation: String) throws {
        if failingOperation == operation { throw RouterBackendError.failed }
    }

    func enable(_ params: CodexRemoteControlEnableParams) async throws -> CodexRemoteControlEnableResponse {
        enableCalls.append(params); try check("enable")
        return .init(status: .connected, serverName: "Codex-for-iPad", installationId: "install-1", environmentId: "env-1")
    }

    func disable(_ params: CodexRemoteControlDisableParams) async throws -> CodexRemoteControlDisableResponse {
        disableCalls.append(params); try check("disable")
        return .init(status: .disabled, serverName: "Codex-for-iPad", installationId: "install-1", environmentId: nil)
    }

    func statusRead() async throws -> CodexRemoteControlStatusReadResponse {
        statusReadCount += 1; try check("statusRead")
        return .init(status: .connected, serverName: "Codex-for-iPad", installationId: "install-1", environmentId: "env-1")
    }

    func pairingStart(_ params: CodexRemoteControlPairingStartParams) async throws -> CodexRemoteControlPairingStartResponse {
        pairingStartCalls.append(params); try check("pairingStart")
        return .init(pairingCode: "pair-1", manualPairingCode: params.manualCode ? "ABCD-EFGH" : nil, environmentId: "env-1", expiresAt: 2_000)
    }

    func pairingStatus(_ params: CodexRemoteControlPairingStatusParams) async throws -> CodexRemoteControlPairingStatusResponse {
        pairingStatusCalls.append(params); try check("pairingStatus")
        return .init(claimed: true)
    }

    func clientsList(_ params: CodexRemoteControlClientsListParams) async throws -> CodexRemoteControlClientsListResponse {
        clientsListCalls.append(params); try check("clientsList")
        return .init(data: [.init(clientId: "client-1", displayName: nil, deviceType: "tablet", platform: "iPadOS", osVersion: nil, deviceModel: "iPad", appVersion: nil, lastSeenAt: 1_234)], nextCursor: nil)
    }

    func clientsRevoke(_ params: CodexRemoteControlClientsRevokeParams) async throws -> CodexRemoteControlClientsRevokeResponse {
        clientsRevokeCalls.append(params); try check("clientsRevoke")
        return .init()
    }

    func statusChanges() async -> AsyncThrowingStream<CodexRemoteControlStatusChangedNotification, Error> { stream }

    func snapshot() -> RouterBackendSnapshot {
        .init(enable: enableCalls, disable: disableCalls, statusReadCount: statusReadCount, pairingStart: pairingStartCalls, pairingStatus: pairingStatusCalls, clientsList: clientsListCalls, clientsRevoke: clientsRevokeCalls)
    }
}

private func request(_ method: String, params: CodexJSONValue?, id: CodexAppServerRequestID = .integer(91)) -> CodexDesktopMCPRequest {
    .init(
        request: .init(id: id, method: method, params: params, metadata: ["trace": .string("ignored")]),
        hostID: "desktop-host-1",
        dispatchedAtMs: nil,
        priority: nil,
        source: nil,
        timeoutMs: nil,
        expiresAtMs: nil,
        metadata: ["envelope": .string("ignored")]
    )
}

private func expected(_ id: CodexJSONValue = .integer(91), result: CodexJSONValue) -> CodexDesktopHostMessage {
    .mcpResponse(hostID: "desktop-host-1", message: .object(["id": id, "result": result]), metadata: [:])
}

private func invalid(_ method: String, id: CodexJSONValue = .integer(91)) -> CodexDesktopHostMessage {
    .mcpResponse(hostID: "desktop-host-1", message: .object([
        "id": id,
        "error": .object(["code": .integer(-32602), "message": .string("Invalid params for \(method)")]),
    ]), metadata: [:])
}

@Test(arguments: [CodexJSONValue?.none, .some(.null), .some(.object([:])), .some(.object(["ephemeral": .bool(false)]))])
func enableAcceptsReleasedOptionalForms(params: CodexJSONValue?) async {
    let backend = RouterBackend(); let service = CodexRemoteControlService(backend: backend)
    let response = await CodexRemoteControlMCPRouter.response(to: request("remoteControl/enable", params: params), service: service)
    #expect(response == expected(result: .object(["status": .string("connected"), "serverName": .string("Codex-for-iPad"), "installationId": .string("install-1"), "environmentId": .string("env-1")])))
    #expect(await backend.snapshot().enable == [.init(ephemeral: false)])
}

@Test
func enableDecodesEphemeralAndPreservesStringID() async {
    let backend = RouterBackend(); let service = CodexRemoteControlService(backend: backend)
    let response = await CodexRemoteControlMCPRouter.response(to: request("remoteControl/enable", params: .object(["ephemeral": .bool(true), "futureField": .string("accepted")]), id: .string("enable-1")), service: service)
    #expect(response == expected(.string("enable-1"), result: .object(["status": .string("connected"), "serverName": .string("Codex-for-iPad"), "installationId": .string("install-1"), "environmentId": .string("env-1")])))
    #expect(await backend.snapshot().enable == [.init(ephemeral: true)])
}

@Test(arguments: [CodexJSONValue?.none, .some(.null), .some(.object([:]))])
func disableAcceptsReleasedOptionalForms(params: CodexJSONValue?) async {
    let backend = RouterBackend(); let service = CodexRemoteControlService(backend: backend)
    let response = await CodexRemoteControlMCPRouter.response(to: request("remoteControl/disable", params: params), service: service)
    #expect(response == expected(result: .object(["status": .string("disabled"), "serverName": .string("Codex-for-iPad"), "installationId": .string("install-1"), "environmentId": .null])))
    #expect(await backend.snapshot().disable == [.init(ephemeral: false)])
}

@Test(arguments: [CodexJSONValue?.none, .some(.null), .some(.object([:]))])
func statusReadAcceptsUnitBridgeForms(params: CodexJSONValue?) async {
    let backend = RouterBackend(); let service = CodexRemoteControlService(backend: backend)
    let response = await CodexRemoteControlMCPRouter.response(to: request("remoteControl/status/read", params: params), service: service)
    #expect(response == expected(result: .object(["status": .string("connected"), "serverName": .string("Codex-for-iPad"), "installationId": .string("install-1"), "environmentId": .string("env-1")])))
}

@Test
func pairingStartRoutesRequiredObjectAndExactWireResult() async {
    let backend = RouterBackend(); let service = CodexRemoteControlService(backend: backend)
    let response = await CodexRemoteControlMCPRouter.response(to: request("remoteControl/pairing/start", params: .object(["manualCode": .bool(true)])), service: service)
    #expect(response == expected(result: .object(["pairingCode": .string("pair-1"), "manualPairingCode": .string("ABCD-EFGH"), "environmentId": .string("env-1"), "expiresAt": .integer(2_000)])))
    #expect(await backend.snapshot().pairingStart == [.init(manualCode: true)])
}

@Test
func pairingStatusRoutesExactlyOneCode() async {
    let backend = RouterBackend(); let service = CodexRemoteControlService(backend: backend)
    let response = await CodexRemoteControlMCPRouter.response(to: request("remoteControl/pairing/status", params: .object(["pairingCode": .string("pair-1"), "manualPairingCode": .null])), service: service)
    #expect(response == expected(result: .object(["claimed": .bool(true)])))
    #expect(await backend.snapshot().pairingStatus == [.init(pairingCode: "pair-1", manualPairingCode: nil)])
}

@Test
func clientsListRoutesPaginationAndKeepsExplicitNulls() async {
    let backend = RouterBackend(); let service = CodexRemoteControlService(backend: backend)
    let response = await CodexRemoteControlMCPRouter.response(to: request("remoteControl/client/list", params: .object(["environmentId": .string("env-1"), "cursor": .string("cursor-1"), "limit": .integer(25), "order": .string("desc")])), service: service)
    #expect(response == expected(result: .object([
        "data": .array([.object(["clientId": .string("client-1"), "displayName": .null, "deviceType": .string("tablet"), "platform": .string("iPadOS"), "osVersion": .null, "deviceModel": .string("iPad"), "appVersion": .null, "lastSeenAt": .integer(1_234)])]),
        "nextCursor": .null,
    ])))
    #expect(await backend.snapshot().clientsList == [.init(environmentId: "env-1", cursor: "cursor-1", limit: 25, order: .desc)])
}

@Test
func clientsRevokeRoutesRequiredIdentityAndReturnsEmptyObject() async {
    let backend = RouterBackend(); let service = CodexRemoteControlService(backend: backend)
    let response = await CodexRemoteControlMCPRouter.response(to: request("remoteControl/client/revoke", params: .object(["environmentId": .string("env-1"), "clientId": .string("client-1")])), service: service)
    #expect(response == expected(result: .object([:])))
    #expect(await backend.snapshot().clientsRevoke == [.init(environmentId: "env-1", clientId: "client-1")])
}

@Test(arguments: [
    ("remoteControl/enable", CodexJSONValue.bool(true)),
    ("remoteControl/disable", CodexJSONValue.object(["ephemeral": .string("yes")])),
    ("remoteControl/status/read", CodexJSONValue.object(["unexpected": .bool(true)])),
    ("remoteControl/pairing/start", CodexJSONValue.null),
    ("remoteControl/pairing/status", CodexJSONValue.object(["pairingCode": .string("a"), "manualPairingCode": .string("b")])),
    ("remoteControl/client/list", CodexJSONValue.object(["environmentId": .string(""), "limit": .integer(0)])),
    ("remoteControl/client/revoke", CodexJSONValue.object(["environmentId": .string("env-1")])),
])
func malformedParamsReturnJSONRPCInvalidParams(method: String, params: CodexJSONValue) async {
    let backend = RouterBackend(); let service = CodexRemoteControlService(backend: backend)
    let response = await CodexRemoteControlMCPRouter.response(to: request(method, params: params), service: service)
    #expect(response == invalid(method))
    let snapshot = await backend.snapshot()
    #expect(snapshot.enable.isEmpty && snapshot.disable.isEmpty && snapshot.statusReadCount == 0 && snapshot.pairingStart.isEmpty && snapshot.pairingStatus.isEmpty && snapshot.clientsList.isEmpty && snapshot.clientsRevoke.isEmpty)
}

@Test
func backendFailureReturnsInternalErrorWithoutLeakingDetails() async {
    let backend = RouterBackend(); await backend.fail("statusRead")
    let service = CodexRemoteControlService(backend: backend)
    let response = await CodexRemoteControlMCPRouter.response(to: request("remoteControl/status/read", params: nil), service: service)
    #expect(response == .mcpResponse(hostID: "desktop-host-1", message: .object([
        "id": .integer(91),
        "error": .object(["code": .integer(-32603), "message": .string("Remote control request failed")]),
    ]), metadata: [:]))
}

@Test
func unknownMethodFallsThroughWithoutTouchingBackend() async {
    let backend = RouterBackend(); let service = CodexRemoteControlService(backend: backend)
    #expect(await CodexRemoteControlMCPRouter.response(to: request("thread/read", params: .object([:])), service: service) == nil)
    #expect(await backend.snapshot().statusReadCount == 0)
}
