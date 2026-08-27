import Foundation
import Testing

@testable import CodexPadApplication
@testable import CodexPadDomain
@testable import CodexPadProtocolBridge

private enum BridgeBackendError: Error, Equatable {
    case streamFailed
}

private actor BridgeBackend: CodexRemoteControlBackend {
    private var readResponse: CodexRemoteControlStatusReadResponse
    private var readCount = 0
    private var statusChangesCount = 0
    private var statusChangesWaiters: [
        CheckedContinuation<Void, Never>
    ] = []
    private let stream: AsyncThrowingStream<
        CodexRemoteControlStatusChangedNotification,
        Error
    >
    private let continuation: AsyncThrowingStream<
        CodexRemoteControlStatusChangedNotification,
        Error
    >.Continuation

    init(
        readResponse: CodexRemoteControlStatusReadResponse = .init(
            status: .disabled,
            serverName: "Codex for ipad",
            installationId: "installation-1",
            environmentId: nil
        )
    ) {
        self.readResponse = readResponse
        let pair = AsyncThrowingStream<
            CodexRemoteControlStatusChangedNotification,
            Error
        >.makeStream()
        stream = pair.stream
        continuation = pair.continuation
    }

    func enable(
        _ params: CodexRemoteControlEnableParams
    ) async throws -> CodexRemoteControlEnableResponse {
        _ = params
        return .init(
            status: .connected,
            serverName: readResponse.serverName,
            installationId: readResponse.installationId,
            environmentId: "environment-1"
        )
    }

    func disable(
        _ params: CodexRemoteControlDisableParams
    ) async throws -> CodexRemoteControlDisableResponse {
        _ = params
        return .init(
            status: .disabled,
            serverName: readResponse.serverName,
            installationId: readResponse.installationId,
            environmentId: nil
        )
    }

    func statusRead() async throws
        -> CodexRemoteControlStatusReadResponse
    {
        readCount += 1
        return readResponse
    }

    func pairingStart(
        _ params: CodexRemoteControlPairingStartParams
    ) async throws -> CodexRemoteControlPairingStartResponse {
        _ = params
        return .init(
            pairingCode: "pairing-1",
            manualPairingCode: nil,
            environmentId: "environment-1",
            expiresAt: 2_000
        )
    }

    func pairingStatus(
        _ params: CodexRemoteControlPairingStatusParams
    ) async throws -> CodexRemoteControlPairingStatusResponse {
        _ = params
        return .init(claimed: true)
    }

    func clientsList(
        _ params: CodexRemoteControlClientsListParams
    ) async throws -> CodexRemoteControlClientsListResponse {
        _ = params
        return .init(data: [], nextCursor: nil)
    }

    func clientsRevoke(
        _ params: CodexRemoteControlClientsRevokeParams
    ) async throws -> CodexRemoteControlClientsRevokeResponse {
        _ = params
        return .init()
    }

    func statusChanges() async -> AsyncThrowingStream<
        CodexRemoteControlStatusChangedNotification,
        Error
    > {
        statusChangesCount += 1
        let waiters = statusChangesWaiters
        statusChangesWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
        return stream
    }

    func waitForStatusChanges() async {
        if statusChangesCount > 0 {
            return
        }
        await withCheckedContinuation { continuation in
            statusChangesWaiters.append(continuation)
        }
    }

    func emit(
        _ status: CodexRemoteControlStatusChangedNotification
    ) {
        continuation.yield(status)
    }

    func finish() {
        continuation.finish()
    }

    func fail() {
        continuation.finish(throwing: BridgeBackendError.streamFailed)
    }

    func snapshot() -> (readCount: Int, statusChangesCount: Int) {
        (readCount, statusChangesCount)
    }
}

private func bridgeRequest(
    _ method: String,
    params: CodexJSONValue? = nil
) -> CodexDesktopMCPRequest {
    .init(
        request: .init(
            id: .string("request-1"),
            method: method,
            params: params,
            metadata: [:]
        ),
        hostID: "desktop-host",
        dispatchedAtMs: nil,
        priority: nil,
        source: nil,
        timeoutMs: nil,
        expiresAtMs: nil,
        metadata: [:]
    )
}

private func expectedStatusNotification(
    status: String,
    environmentID: CodexJSONValue,
    hostID: String = "local"
) -> CodexDesktopHostMessage {
    .mcpNotification(
        hostID: hostID,
        method: "remoteControl/status/changed",
        params: .object([
            "status": .string(status),
            "serverName": .string("Codex for ipad"),
            "installationId": .string("installation-1"),
            "environmentId": environmentID,
        ]),
        metadata: [:]
    )
}

@Test
func statusStreamMapsReleasedNotificationWireExactly() async throws {
    let backend = BridgeBackend()
    let bridge = CodexRemoteControlMCPBridge(
        service: CodexRemoteControlService(backend: backend)
    )
    let stream = await bridge.statusNotifications()
    var iterator = stream.makeAsyncIterator()

    await backend.emit(.init(
        status: .connected,
        serverName: "Codex for ipad",
        installationId: "installation-1",
        environmentId: "environment-1"
    ))

    #expect(try await iterator.next() == expectedStatusNotification(
        status: "connected",
        environmentID: .string("environment-1")
    ))
    await backend.finish()
    #expect(try await iterator.next() == nil)
}

@Test
func rendererReadyReadsOnceThenUsesSharedCachedStatus() async throws {
    let backend = BridgeBackend()
    let bridge = CodexRemoteControlMCPBridge(
        service: CodexRemoteControlService(backend: backend)
    )

    let first = try await bridge.currentStatusNotification()
    let second = try await bridge.currentStatusNotification()

    #expect(first == expectedStatusNotification(
        status: "disabled",
        environmentID: .null
    ))
    #expect(second == first)
    #expect(await backend.snapshot().readCount == 1)
    await backend.finish()
}

@Test
func rpcAndRendererReadyShareTheSameLongLivedServiceState() async throws {
    let backend = BridgeBackend(readResponse: .init(
        status: .connected,
        serverName: "Codex for ipad",
        installationId: "installation-1",
        environmentId: "environment-1"
    ))
    let bridge = CodexRemoteControlMCPBridge(
        service: CodexRemoteControlService(backend: backend)
    )

    let response = await bridge.response(
        to: bridgeRequest("remoteControl/status/read")
    )
    #expect(response != nil)
    #expect(try await bridge.currentStatusNotification() ==
        expectedStatusNotification(
            status: "connected",
            environmentID: .string("environment-1")
        ))
    #expect(await backend.snapshot().readCount == 1)
    await backend.waitForStatusChanges()
    #expect(await backend.snapshot().statusChangesCount == 1)
    await backend.finish()
}

@Test
func duplicateBackendStatusIsSuppressedWithoutReordering() async throws {
    let backend = BridgeBackend()
    let bridge = CodexRemoteControlMCPBridge(
        service: CodexRemoteControlService(backend: backend)
    )
    let stream = await bridge.statusNotifications()
    var iterator = stream.makeAsyncIterator()
    let connected = CodexRemoteControlStatusChangedNotification(
        status: .connected,
        serverName: "Codex for ipad",
        installationId: "installation-1",
        environmentId: "environment-1"
    )
    let errored = CodexRemoteControlStatusChangedNotification(
        status: .errored,
        serverName: "Codex for ipad",
        installationId: "installation-1",
        environmentId: "environment-1"
    )

    await backend.emit(connected)
    await backend.emit(connected)
    await backend.emit(errored)

    #expect(try await iterator.next() == expectedStatusNotification(
        status: "connected",
        environmentID: .string("environment-1")
    ))
    #expect(try await iterator.next() == expectedStatusNotification(
        status: "errored",
        environmentID: .string("environment-1")
    ))
    await backend.finish()
    #expect(try await iterator.next() == nil)
}

@Test
func backendStatusFailureTerminatesMappedStreamWithSameFailure() async {
    let backend = BridgeBackend()
    let bridge = CodexRemoteControlMCPBridge(
        service: CodexRemoteControlService(backend: backend)
    )
    let stream = await bridge.statusNotifications()
    var iterator = stream.makeAsyncIterator()
    await backend.fail()

    do {
        _ = try await iterator.next()
        Issue.record("expected backend stream failure")
    } catch let error as BridgeBackendError {
        #expect(error == .streamFailed)
    } catch {
        Issue.record("unexpected error: \(error)")
    }
}

@Test
func unknownRPCStillFallsThroughWithoutReadingStatus() async {
    let backend = BridgeBackend()
    let bridge = CodexRemoteControlMCPBridge(
        service: CodexRemoteControlService(backend: backend)
    )

    #expect(await bridge.response(
        to: bridgeRequest("thread/read", params: .object([:]))
    ) == nil)
    #expect(await backend.snapshot().readCount == 0)
    #expect(await backend.snapshot().statusChangesCount == 0)
    await backend.finish()
}
