import Foundation
import Testing

@testable import CodexPadApplication
@testable import CodexPadDomain

private enum RemoteControlBackendFixtureError: Error, Equatable {
    case backend
}

private struct RemoteControlBackendCallSnapshot: Sendable {
    let enable: [CodexRemoteControlEnableParams]
    let disable: [CodexRemoteControlDisableParams]
    let statusReadCount: Int
    let pairingStartCount: Int
    let pairingStatus: [CodexRemoteControlPairingStatusParams]
    let clientsListCount: Int
    let clientsRevokeCount: Int
}

private actor RemoteControlBackendFixture: CodexRemoteControlBackend {
    private var enableResponse = CodexRemoteControlEnableResponse(
        status: .connecting,
        serverName: "Mars-iPad",
        installationId: "installation-123",
        environmentId: nil
    )
    private var disableResponse = CodexRemoteControlDisableResponse(
        status: .disabled,
        serverName: "Mars-iPad",
        installationId: "installation-123",
        environmentId: nil
    )
    private var readResponse = CodexRemoteControlStatusReadResponse(
        status: .disabled,
        serverName: "Mars-iPad",
        installationId: "installation-123",
        environmentId: nil
    )
    private var pairingStartResponse =
        CodexRemoteControlPairingStartResponse(
            pairingCode: "pairing-code",
            manualPairingCode: "ABCD-EFGH",
            environmentId: "env-123",
            expiresAt: 2_000
        )
    private var pairingStatusResponse =
        CodexRemoteControlPairingStatusResponse(claimed: false)
    private var clientsListResponse =
        CodexRemoteControlClientsListResponse(
            data: [],
            nextCursor: nil
        )

    private var failingOperations: Set<String> = []
    private var enableCalls: [CodexRemoteControlEnableParams] = []
    private var disableCalls: [CodexRemoteControlDisableParams] = []
    private var statusReadCount = 0
    private var pairingStartCount = 0
    private var pairingStatusCalls:
        [CodexRemoteControlPairingStatusParams] = []
    private var clientsListCount = 0
    private var clientsRevokeCount = 0

    private var enableBlocked = false
    private var enableReleaseWaiters: [
        CheckedContinuation<Void, Never>
    ] = []
    private var enableCallWaiters: [
        CheckedContinuation<Void, Never>
    ] = []

    private let notificationStream:
        AsyncThrowingStream<
            CodexRemoteControlStatusChangedNotification,
            Error
        >
    private let notificationContinuation:
        AsyncThrowingStream<
            CodexRemoteControlStatusChangedNotification,
            Error
        >.Continuation

    init() {
        let pair = AsyncThrowingStream<
            CodexRemoteControlStatusChangedNotification,
            Error
        >.makeStream()
        notificationStream = pair.stream
        notificationContinuation = pair.continuation
    }

    func enable(
        _ params: CodexRemoteControlEnableParams
    ) async throws -> CodexRemoteControlEnableResponse {
        enableCalls.append(params)
        let callWaiters = enableCallWaiters
        enableCallWaiters.removeAll()
        for waiter in callWaiters {
            waiter.resume()
        }
        if enableBlocked {
            await withCheckedContinuation { continuation in
                enableReleaseWaiters.append(continuation)
            }
        }
        try failIfRequested("enable")
        return enableResponse
    }

    func disable(
        _ params: CodexRemoteControlDisableParams
    ) async throws -> CodexRemoteControlDisableResponse {
        disableCalls.append(params)
        try failIfRequested("disable")
        return disableResponse
    }

    func statusRead() async throws
        -> CodexRemoteControlStatusReadResponse
    {
        statusReadCount += 1
        try failIfRequested("statusRead")
        return readResponse
    }

    func pairingStart(
        _ params: CodexRemoteControlPairingStartParams
    ) async throws -> CodexRemoteControlPairingStartResponse {
        _ = params
        pairingStartCount += 1
        try failIfRequested("pairingStart")
        return pairingStartResponse
    }

    func pairingStatus(
        _ params: CodexRemoteControlPairingStatusParams
    ) async throws -> CodexRemoteControlPairingStatusResponse {
        pairingStatusCalls.append(params)
        try failIfRequested("pairingStatus")
        return pairingStatusResponse
    }

    func clientsList(
        _ params: CodexRemoteControlClientsListParams
    ) async throws -> CodexRemoteControlClientsListResponse {
        _ = params
        clientsListCount += 1
        try failIfRequested("clientsList")
        return clientsListResponse
    }

    func clientsRevoke(
        _ params: CodexRemoteControlClientsRevokeParams
    ) async throws -> CodexRemoteControlClientsRevokeResponse {
        _ = params
        clientsRevokeCount += 1
        try failIfRequested("clientsRevoke")
        return CodexRemoteControlClientsRevokeResponse()
    }

    func statusChanges() async
        -> AsyncThrowingStream<
            CodexRemoteControlStatusChangedNotification,
            Error
        >
    {
        notificationStream
    }

    func setEnableBlocked(_ blocked: Bool) {
        enableBlocked = blocked
    }

    func waitForEnableCall() async {
        if !enableCalls.isEmpty {
            return
        }
        await withCheckedContinuation { continuation in
            enableCallWaiters.append(continuation)
        }
    }

    func releaseEnable() {
        enableBlocked = false
        let waiters = enableReleaseWaiters
        enableReleaseWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    func setEnableResponse(
        _ response: CodexRemoteControlEnableResponse
    ) {
        enableResponse = response
    }

    func setPairingStartResponse(
        _ response: CodexRemoteControlPairingStartResponse
    ) {
        pairingStartResponse = response
    }

    func setPairingClaimed(_ claimed: Bool) {
        pairingStatusResponse =
            CodexRemoteControlPairingStatusResponse(
                claimed: claimed
            )
    }

    func fail(_ operation: String) {
        failingOperations.insert(operation)
    }

    func emit(
        _ notification:
            CodexRemoteControlStatusChangedNotification
    ) {
        notificationContinuation.yield(notification)
    }

    func finishNotifications() {
        notificationContinuation.finish()
    }

    func failNotifications() {
        notificationContinuation.finish(
            throwing: RemoteControlBackendFixtureError.backend
        )
    }

    func snapshot() -> RemoteControlBackendCallSnapshot {
        RemoteControlBackendCallSnapshot(
            enable: enableCalls,
            disable: disableCalls,
            statusReadCount: statusReadCount,
            pairingStartCount: pairingStartCount,
            pairingStatus: pairingStatusCalls,
            clientsListCount: clientsListCount,
            clientsRevokeCount: clientsRevokeCount
        )
    }

    private func failIfRequested(_ operation: String) throws {
        if failingOperations.contains(operation) {
            throw RemoteControlBackendFixtureError.backend
        }
    }
}

@Test
func remoteControlConcurrentTransitionsAreSingleFlightAndPreserveEphemeral()
    async throws
{
    let backend = RemoteControlBackendFixture()
    await backend.setEnableBlocked(true)
    let service = CodexRemoteControlService(backend: backend)

    let first = Task {
        try await service.enable(.init(ephemeral: true))
    }
    await backend.waitForEnableCall()
    let second = Task {
        try await service.enable(.init(ephemeral: true))
    }
    for _ in 0 ..< 20 {
        await Task.yield()
    }
    #expect((await backend.snapshot()).enable.count == 1)

    await backend.releaseEnable()
    #expect(try await first.value.status == .connecting)
    #expect(try await second.value.status == .connecting)
    let enabledSnapshot = await backend.snapshot()
    #expect(enabledSnapshot.enable == [.init(ephemeral: true)])

    let disabled = try await service.disable(
        .init(ephemeral: true)
    )
    #expect(disabled.status == .disabled)
    let finalSnapshot = await backend.snapshot()
    #expect(finalSnapshot.disable == [.init(ephemeral: true)])
    #expect((await service.cachedStatus())?.status == .disabled)
}

@Test
func remoteControlRejectsInvalidTransitionAndSurfacesBackendFailure()
    async throws
{
    let transitionBackend = RemoteControlBackendFixture()
    await transitionBackend.setEnableResponse(
        .init(
            status: .connected,
            serverName: "Mars-iPad",
            installationId: "installation-123",
            environmentId: "env-123"
        )
    )
    let transitionService = CodexRemoteControlService(
        backend: transitionBackend
    )
    #expect(try await transitionService.statusRead().status == .disabled)
    await #expect(
        throws: CodexRemoteControlServiceError
            .invalidStatusTransition(
                from: .disabled,
                to: .connected
            )
    ) {
        try await transitionService.enable()
    }

    let failingBackend = RemoteControlBackendFixture()
    await failingBackend.fail("enable")
    let failingService = CodexRemoteControlService(
        backend: failingBackend
    )
    await #expect(
        throws: RemoteControlBackendFixtureError.backend
    ) {
        try await failingService.enable(
            .init(ephemeral: true)
        )
    }
    #expect(await failingService.cachedStatus() == nil)
    #expect((await failingBackend.snapshot()).enable == [
        .init(ephemeral: true),
    ])
}

@Test
func remoteControlPairingDefersCodeAndExpirySemanticsToBackend()
    async throws
{
    let backend = RemoteControlBackendFixture()
    let service = CodexRemoteControlService(backend: backend)

    await #expect(
        throws: CodexRemoteControlServiceError
            .pairingRequiresEnabledRemoteControl
    ) {
        try await service.pairingStart()
    }
    #expect((await backend.snapshot()).pairingStartCount == 0)

    _ = try await service.enable(.init(ephemeral: true))
    await backend.setPairingStartResponse(
        .init(
            pairingCode: "pairing-code",
            manualPairingCode: nil,
            environmentId: "env-123",
            expiresAt: 1
        )
    )
    let pairing = try await service.pairingStart(
        .init(manualCode: true)
    )
    #expect(pairing == .init(
        pairingCode: "pairing-code",
        manualPairingCode: nil,
        environmentId: "env-123",
        expiresAt: 1
    ))

    await #expect(
        throws: CodexRemoteControlServiceError
            .pairingStatusRequiresExactlyOneCode
    ) {
        try await service.pairingStatus(.init())
    }
    await #expect(
        throws: CodexRemoteControlServiceError
            .pairingStatusRequiresExactlyOneCode
    ) {
        try await service.pairingStatus(
            .init(
                pairingCode: "pairing-code",
                manualPairingCode: "ABCD-EFGH"
            )
        )
    }
    #expect((await backend.snapshot()).pairingStatus.isEmpty)

    let pending = try await service.pairingStatus(
        .init(pairingCode: "arbitrary-backend-code")
    )
    #expect(!pending.claimed)

    _ = try await service.pairingStatus(
        .init(manualPairingCode: "")
    )
    #expect((await backend.snapshot()).pairingStatus == [
        .init(pairingCode: "arbitrary-backend-code"),
        .init(manualPairingCode: ""),
    ])
}

@Test
func remoteControlClientManagementMatchesOfficialValidationWhileDisabled()
    async throws
{
    let backend = RemoteControlBackendFixture()
    let service = CodexRemoteControlService(backend: backend)

    await #expect(
        throws: CodexRemoteControlServiceError
            .clientListRequiresEnvironmentID
    ) {
        try await service.clientsList(
            .init(environmentId: "")
        )
    }
    await #expect(
        throws: CodexRemoteControlServiceError
            .clientListLimitOutOfRange(0)
    ) {
        try await service.clientsList(
            .init(environmentId: "env-123", limit: 0)
        )
    }
    await #expect(
        throws: CodexRemoteControlServiceError
            .clientListLimitOutOfRange(101)
    ) {
        try await service.clientsList(
            .init(environmentId: "env-123", limit: 101)
        )
    }

    let page = try await service.clientsList(
        .init(
            environmentId: "env-123",
            limit: 100,
            order: .asc
        )
    )
    #expect(page.data.isEmpty)
    #expect((await backend.snapshot()).clientsListCount == 1)

    await #expect(
        throws: CodexRemoteControlServiceError
            .clientRevokeRequiresEnvironmentID
    ) {
        try await service.clientsRevoke(
            .init(environmentId: "", clientId: "client-123")
        )
    }
    await #expect(
        throws: CodexRemoteControlServiceError
            .clientRevokeRequiresClientID
    ) {
        try await service.clientsRevoke(
            .init(environmentId: "env-123", clientId: "")
        )
    }
    _ = try await service.clientsRevoke(
        .init(
            environmentId: "env-123",
            clientId: "client-123"
        )
    )
    #expect((await backend.snapshot()).clientsRevokeCount == 1)
}

@Test
func remoteControlNotificationStreamForwardsRealChangesWithoutPolling()
    async throws
{
    let backend = RemoteControlBackendFixture()
    let service = CodexRemoteControlService(backend: backend)
    let stream = await service.statusNotifications()
    let collector = Task {
        var notifications: [
            CodexRemoteControlStatusChangedNotification
        ] = []
        for try await notification in stream {
            notifications.append(notification)
        }
        return notifications
    }

    let connecting = CodexRemoteControlStatusChangedNotification(
        status: .connecting,
        serverName: "Mars-iPad",
        installationId: "installation-123",
        environmentId: "env-123"
    )
    await backend.emit(connecting)
    await backend.emit(connecting)
    await backend.emit(
        .init(
            status: .connected,
            serverName: "Mars-iPad",
            installationId: "installation-123",
            environmentId: "env-123"
        )
    )
    await backend.emit(
        .init(
            status: .disabled,
            serverName: "Mars-iPad",
            installationId: "installation-123",
            environmentId: nil
        )
    )
    await backend.finishNotifications()

    let notifications = try await collector.value
    #expect(notifications.map(\.status) == [
        .connecting,
        .connected,
        .disabled,
    ])
    #expect((await backend.snapshot()).statusReadCount == 0)

    let failingBackend = RemoteControlBackendFixture()
    let failingService = CodexRemoteControlService(
        backend: failingBackend
    )
    let failingStream = await failingService.statusNotifications()
    await failingBackend.failNotifications()
    var iterator = failingStream.makeAsyncIterator()
    await #expect(
        throws: RemoteControlBackendFixtureError.backend
    ) {
        try await iterator.next()
    }
}
