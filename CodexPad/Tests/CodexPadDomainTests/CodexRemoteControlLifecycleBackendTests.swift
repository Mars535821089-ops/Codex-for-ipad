import Foundation
import Testing

@testable import CodexPadApplication
@testable import CodexPadDomain

private struct LifecycleWireTestError: CodexRemoteControlLifecycleWireFailure,
    Equatable
{
    let statusCode: Int?
    let retryAt: Int64?
    let isTransient: Bool

    init(
        statusCode: Int? = nil,
        retryAt: Int64? = nil,
        isTransient: Bool = false
    ) {
        self.statusCode = statusCode
        self.retryAt = retryAt
        self.isTransient = isTransient
    }
}

private enum LifecycleStub<Value: Sendable>: Sendable {
    case success(Value)
    case failure(LifecycleWireTestError)

    func get() throws -> Value {
        switch self {
        case let .success(value): value
        case let .failure(error): throw error
        }
    }
}

private actor LifecycleWireProbe: CodexRemoteControlLifecycleWire {
    private var enrollStubs: [LifecycleStub<CodexRemoteControlHTTPEnrollment>]
    private var refreshStubs: [LifecycleStub<CodexRemoteControlHTTPEnrollment>]
    private var pairingStartStubs:
        [LifecycleStub<CodexRemoteControlPairingStartResponse>]
    private var pairingStatusStubs:
        [LifecycleStub<CodexRemoteControlPairingStatusResponse>]
    private var operations: [String] = []
    private var pairingStartHook: (@Sendable () async -> Void)?

    init(
        enroll: [LifecycleStub<CodexRemoteControlHTTPEnrollment>] = [],
        refresh: [LifecycleStub<CodexRemoteControlHTTPEnrollment>] = [],
        pairingStart:
            [LifecycleStub<CodexRemoteControlPairingStartResponse>] = [],
        pairingStatus:
            [LifecycleStub<CodexRemoteControlPairingStatusResponse>] = []
    ) {
        enrollStubs = enroll
        refreshStubs = refresh
        pairingStartStubs = pairingStart
        pairingStatusStubs = pairingStatus
    }

    func enroll(
        auth: CodexRemoteControlAccountAuth,
        installationID: String,
        serverName: String,
        operatingSystem: String,
        architecture: String,
        appServerVersion: String
    ) async throws -> CodexRemoteControlHTTPEnrollment {
        _ = (auth, installationID, serverName, operatingSystem, architecture,
             appServerVersion)
        operations.append("enroll")
        guard !enrollStubs.isEmpty else {
            throw LifecycleWireTestError()
        }
        return try enrollStubs.removeFirst().get()
    }

    func refresh(
        auth: CodexRemoteControlAccountAuth,
        installationID: String,
        serverID: String,
        environmentID: String
    ) async throws -> CodexRemoteControlHTTPEnrollment {
        _ = (auth, installationID, serverID, environmentID)
        operations.append("refresh")
        guard !refreshStubs.isEmpty else {
            throw LifecycleWireTestError()
        }
        return try refreshStubs.removeFirst().get()
    }

    func startPairing(
        serverToken: String,
        serverID: String,
        environmentID: String,
        manualCode: Bool
    ) async throws -> CodexRemoteControlPairingStartResponse {
        _ = (serverToken, serverID, environmentID, manualCode)
        operations.append("pair")
        if let pairingStartHook {
            await pairingStartHook()
        }
        guard !pairingStartStubs.isEmpty else {
            throw LifecycleWireTestError()
        }
        return try pairingStartStubs.removeFirst().get()
    }

    func pairingStatus(
        serverToken: String,
        pairingCode: String?,
        manualPairingCode: String?
    ) async throws -> CodexRemoteControlPairingStatusResponse {
        _ = (serverToken, pairingCode, manualPairingCode)
        operations.append("pairStatus")
        guard !pairingStatusStubs.isEmpty else {
            throw LifecycleWireTestError()
        }
        return try pairingStatusStubs.removeFirst().get()
    }

    func listClients(
        auth: CodexRemoteControlAccountAuth,
        params: CodexRemoteControlClientsListParams
    ) async throws -> CodexRemoteControlClientsListResponse {
        _ = (auth, params)
        operations.append("list")
        return CodexRemoteControlClientsListResponse(
            data: [
                CodexRemoteControlClient(
                    clientId: "client-1",
                    displayName: nil,
                    deviceType: nil,
                    platform: nil,
                    osVersion: nil,
                    deviceModel: nil,
                    appVersion: nil,
                    lastSeenAt: nil
                ),
            ],
            nextCursor: nil
        )
    }

    func revokeClient(
        auth: CodexRemoteControlAccountAuth,
        params: CodexRemoteControlClientsRevokeParams
    ) async throws -> CodexRemoteControlClientsRevokeResponse {
        _ = (auth, params)
        operations.append("revoke")
        return CodexRemoteControlClientsRevokeResponse()
    }

    func setPairingStartHook(
        _ hook: @escaping @Sendable () async -> Void
    ) {
        pairingStartHook = hook
    }

    func recordedOperations() -> [String] {
        operations
    }
}

private actor LifecycleAuthProbe: CodexRemoteControlLifecycleAuthProviding {
    private var current: CodexRemoteControlAccountAuth
    private var recoveries: [CodexRemoteControlAccountAuth?]
    private var recoveryCount = 0

    init(
        current: CodexRemoteControlAccountAuth,
        recoveries: [CodexRemoteControlAccountAuth?] = []
    ) {
        self.current = current
        self.recoveries = recoveries
    }

    func currentRemoteControlAuth() async throws
        -> CodexRemoteControlAccountAuth
    {
        current
    }

    func recoverRemoteControlAuth() async throws
        -> CodexRemoteControlAccountAuth?
    {
        recoveryCount += 1
        guard !recoveries.isEmpty else { return nil }
        let recovered = recoveries.removeFirst()
        if let recovered {
            current = recovered
        }
        return recovered
    }

    func setCurrent(_ auth: CodexRemoteControlAccountAuth) {
        current = auth
    }

    func recordedRecoveryCount() -> Int {
        recoveryCount
    }
}

private actor LifecyclePersistenceProbe:
    CodexRemoteControlLifecyclePersisting
{
    private var records:
        [CodexRemoteControlPersistenceKey: CodexRemoteControlPersistedEnrollment]
    private var setEnabledCalls:
        [(CodexRemoteControlPersistenceKey, Bool)] = []
    private var upsertCalls:
        [(CodexRemoteControlPersistenceKey, Bool?)] = []

    init(
        records: [
            CodexRemoteControlPersistenceKey:
                CodexRemoteControlPersistedEnrollment
        ] = [:]
    ) {
        self.records = records
    }

    func load(
        for key: CodexRemoteControlPersistenceKey
    ) async throws -> CodexRemoteControlPersistedEnrollment? {
        records[key]
    }

    func upsert(
        _ enrollment: CodexRemoteControlPersistedEnrollment,
        for key: CodexRemoteControlPersistenceKey,
        enabled: Bool?
    ) async throws {
        let preservedEnabled = enabled ?? records[key]?.enabled
        records[key] = CodexRemoteControlPersistedEnrollment(
            serverID: enrollment.serverID,
            environmentID: enrollment.environmentID,
            serverName: enrollment.serverName,
            enabled: preservedEnabled
        )
        upsertCalls.append((key, enabled))
    }

    func setEnabled(
        _ enabled: Bool,
        for key: CodexRemoteControlPersistenceKey
    ) async throws -> Bool {
        setEnabledCalls.append((key, enabled))
        guard let record = records[key] else { return false }
        records[key] = CodexRemoteControlPersistedEnrollment(
            serverID: record.serverID,
            environmentID: record.environmentID,
            serverName: record.serverName,
            enabled: enabled
        )
        return true
    }

    func record(
        for key: CodexRemoteControlPersistenceKey
    ) -> CodexRemoteControlPersistedEnrollment? {
        records[key]
    }

    func enabledWrites() -> [(CodexRemoteControlPersistenceKey, Bool)] {
        setEnabledCalls
    }

    func enrollmentWrites() -> [(CodexRemoteControlPersistenceKey, Bool?)] {
        upsertCalls
    }
}

private actor LifecycleWebSocketProbe:
    CodexRemoteControlWebSocketLifecycle
{
    private let stream:
        AsyncThrowingStream<CodexRemoteControlConnectionStatus, Error>
    private let continuation:
        AsyncThrowingStream<CodexRemoteControlConnectionStatus, Error>
            .Continuation
    private var connectCount = 0
    private var disconnectCount = 0

    init() {
        let pair = AsyncThrowingStream<
            CodexRemoteControlConnectionStatus,
            Error
        >.makeStream()
        stream = pair.stream
        continuation = pair.continuation
    }

    func connect(
        target: String,
        installationID: String,
        accountID: String,
        serverID: String,
        environmentID: String,
        serverName: String,
        token: String
    ) async throws -> AsyncThrowingStream<
        CodexRemoteControlConnectionStatus,
        Error
    > {
        _ = (target, installationID, accountID, serverID, environmentID,
             serverName, token)
        connectCount += 1
        return stream
    }

    func disconnect() async {
        disconnectCount += 1
        continuation.finish()
    }

    func emit(_ status: CodexRemoteControlConnectionStatus) {
        continuation.yield(status)
    }

    func counts() -> (connect: Int, disconnect: Int) {
        (connectCount, disconnectCount)
    }
}

private let lifecycleAuth = CodexRemoteControlAccountAuth(
    accessToken: "account-token",
    accountID: "account-1"
)
private let lifecycleTarget = "wss://chatgpt.com/backend-api/wham/remote/control"
private let lifecycleKey = CodexRemoteControlPersistenceKey(
    target: lifecycleTarget,
    accountID: "account-1",
    appServerClientName: "desktop-client"
)

private func lifecycleEnrollment(
    accountID: String = "account-1",
    serverID: String = "server-1",
    environmentID: String = "environment-1",
    token: String? = "server-token",
    expiresAt: Int64? = 10_000,
    nextRefreshAt: Int64? = nil
) -> CodexRemoteControlRuntimeEnrollment {
    CodexRemoteControlRuntimeEnrollment(
        target: lifecycleTarget,
        accountID: accountID,
        serverID: serverID,
        environmentID: environmentID,
        serverName: "Mars-iPad",
        token: token,
        expiresAt: expiresAt,
        nextRefreshAt: nextRefreshAt
    )
}

private func httpEnrollment(
    serverID: String = "server-1",
    environmentID: String = "environment-1",
    token: String = "server-token-2",
    expiresAt: Int64 = 10_000
) -> CodexRemoteControlHTTPEnrollment {
    CodexRemoteControlHTTPEnrollment(
        serverID: serverID,
        environmentID: environmentID,
        remoteControlToken: token,
        expiresAt: expiresAt
    )
}

private func pairingResponse(
    environmentID: String = "environment-1"
) -> CodexRemoteControlPairingStartResponse {
    CodexRemoteControlPairingStartResponse(
        pairingCode: "pairing-code",
        manualPairingCode: "ABCD-EFGH",
        environmentId: environmentID,
        expiresAt: 2_000
    )
}

private func lifecycleBackend(
    wire: LifecycleWireProbe,
    auth: LifecycleAuthProbe,
    persistence: LifecyclePersistenceProbe = LifecyclePersistenceProbe(),
    webSocket: LifecycleWebSocketProbe = LifecycleWebSocketProbe(),
    desiredState: CodexRemoteControlLifecycleDesiredState = .disabled,
    enrollment: CodexRemoteControlRuntimeEnrollment? = nil,
    now: Int64 = 1_000,
    fallbackDelay: Int64 = 30
) -> CodexRemoteControlLifecycleBackend {
    CodexRemoteControlLifecycleBackend(
        target: lifecycleTarget,
        installationID: "installation-1",
        serverName: "Mars-iPad",
        operatingSystem: "ios",
        architecture: "arm64",
        appServerVersion: "0.1.0",
        appServerClientName: "desktop-client",
        initialDesiredState: desiredState,
        initialEnrollment: enrollment,
        wire: wire,
        authProvider: auth,
        persistence: persistence,
        webSocket: webSocket,
        now: { now },
        fallbackRefreshDelay: { fallbackDelay }
    )
}

private func caughtLifecycleError(
    _ operation: () async throws -> Void
) async -> (any Error)? {
    do {
        try await operation()
        return nil
    } catch {
        return error
    }
}

@Test
func remoteControlRefreshRequirementMatchesOfficialBoundaries() {
    #expect(
        lifecycleEnrollment(token: nil, expiresAt: nil)
            .serverTokenRefreshRequirement(at: 1_000) == .required
    )
    #expect(
        lifecycleEnrollment(expiresAt: 1_000)
            .serverTokenRefreshRequirement(at: 1_000) == .required
    )
    #expect(
        lifecycleEnrollment(expiresAt: 1_300)
            .serverTokenRefreshRequirement(at: 1_000) == .proactive
    )
    #expect(
        lifecycleEnrollment(expiresAt: 1_301)
            .serverTokenRefreshRequirement(at: 1_000) == .notNeeded
    )
    #expect(
        lifecycleEnrollment(expiresAt: 1_200, nextRefreshAt: 1_050)
            .serverTokenRefreshRequirement(at: 1_000) == .notNeeded
    )
    #expect(
        lifecycleEnrollment(expiresAt: 999, nextRefreshAt: 1_050)
            .serverTokenRefreshRequirement(at: 1_000) == .required
    )
}

@Test
func remoteControlResolvePersistedPreferenceUsesCompositeKeyAndTriState()
    async throws
{
    let enabledRecord = CodexRemoteControlPersistedEnrollment(
        serverID: "server-1",
        environmentID: "environment-1",
        serverName: "old-name",
        enabled: true
    )
    let persistence = LifecyclePersistenceProbe(records: [
        lifecycleKey: enabledRecord,
    ])
    let backend = lifecycleBackend(
        wire: LifecycleWireProbe(),
        auth: LifecycleAuthProbe(current: lifecycleAuth),
        persistence: persistence,
        desiredState: .unknown
    )

    #expect(try await backend.resolvePersistedPreference())
    #expect(
        await backend.desiredStateSnapshot()
            == .enabled(persistencePreference: true)
    )
    let runtime = try #require(await backend.runtimeEnrollmentSnapshot())
    #expect(runtime.accountID == "account-1")
    #expect(runtime.serverID == "server-1")
    #expect(runtime.serverName == "Mars-iPad")
    #expect(runtime.token == nil)
    #expect(runtime.expiresAt == nil)

    let nullKey = CodexRemoteControlPersistenceKey(
        target: lifecycleTarget,
        accountID: "account-2",
        appServerClientName: "desktop-client"
    )
    let nullPersistence = LifecyclePersistenceProbe(records: [
        nullKey: CodexRemoteControlPersistedEnrollment(
            serverID: "server-2",
            environmentID: "environment-2",
            serverName: "name",
            enabled: nil
        ),
    ])
    let nullBackend = lifecycleBackend(
        wire: LifecycleWireProbe(),
        auth: LifecycleAuthProbe(
            current: CodexRemoteControlAccountAuth(
                accessToken: "token-2",
                accountID: "account-2"
            )
        ),
        persistence: nullPersistence,
        desiredState: .unknown
    )
    #expect(try await nullBackend.resolvePersistedPreference() == false)
    #expect(await nullBackend.desiredStateSnapshot() == .disabled)
}

@Test
func remoteControlSuspendResumePreservesPreferenceAndReconnects()
    async throws
{
    let webSocket = LifecycleWebSocketProbe()
    let backend = lifecycleBackend(
        wire: LifecycleWireProbe(),
        auth: LifecycleAuthProbe(current: lifecycleAuth),
        webSocket: webSocket,
        desiredState: .enabled(persistencePreference: true),
        enrollment: lifecycleEnrollment()
    )

    _ = try await backend.statusRead()
    #expect(await webSocket.counts().connect == 1)

    await backend.suspendTransport()
    #expect(await webSocket.counts().disconnect == 1)
    #expect(
        await backend.desiredStateSnapshot()
            == .enabled(persistencePreference: true)
    )

    try await backend.resumeTransportIfNeeded()
    #expect(await webSocket.counts().connect == 2)
    #expect(
        await backend.desiredStateSnapshot()
            == .enabled(persistencePreference: true)
    )
}

@Test
func remoteControlEnrollRecoversPermissionOnceAndPersistsWithoutToken()
    async throws
{
    let recovered = CodexRemoteControlAccountAuth(
        accessToken: "recovered-token",
        accountID: "account-2"
    )
    let wire = LifecycleWireProbe(enroll: [
        .failure(LifecycleWireTestError(statusCode: 403)),
        .success(
            httpEnrollment(
                serverID: "server-2",
                environmentID: "environment-2"
            )
        ),
    ])
    let auth = LifecycleAuthProbe(
        current: lifecycleAuth,
        recoveries: [recovered]
    )
    let persistence = LifecyclePersistenceProbe()
    let backend = lifecycleBackend(
        wire: wire,
        auth: auth,
        persistence: persistence
    )

    let response = try await backend.enable(.init(ephemeral: false))
    #expect(response.status == .connecting)
    #expect(await auth.recordedRecoveryCount() == 1)
    #expect(await wire.recordedOperations() == ["enroll", "enroll"])

    let recoveredKey = CodexRemoteControlPersistenceKey(
        target: lifecycleTarget,
        accountID: "account-2",
        appServerClientName: "desktop-client"
    )
    let record = try #require(await persistence.record(for: recoveredKey))
    #expect(record.serverID == "server-2")
    #expect(record.environmentID == "environment-2")
    #expect(record.enabled == true)
    let encoded = try JSONEncoder().encode(record)
    let object = try #require(
        JSONSerialization.jsonObject(with: encoded) as? [String: Any]
    )
    #expect(object["token"] == nil)
    #expect(object["remoteControlToken"] == nil)
}

@Test
func remoteControlEnrollRecoveryRetriesOnlyOnce() async {
    let wire = LifecycleWireProbe(enroll: [
        .failure(LifecycleWireTestError(statusCode: 401)),
        .failure(LifecycleWireTestError(statusCode: 403)),
    ])
    let auth = LifecycleAuthProbe(
        current: lifecycleAuth,
        recoveries: [lifecycleAuth]
    )
    let backend = lifecycleBackend(wire: wire, auth: auth)

    let error = await caughtLifecycleError {
        _ = try await backend.enable(.init(ephemeral: true))
    }
    #expect(error is LifecycleWireTestError)
    #expect(await auth.recordedRecoveryCount() == 1)
    #expect(await wire.recordedOperations() == ["enroll", "enroll"])
}

@Test
func remoteControlRefreshRejectsRecoveredAccountMismatchAndClearsToken()
    async
{
    let wire = LifecycleWireProbe(refresh: [
        .failure(LifecycleWireTestError(statusCode: 401)),
    ])
    let auth = LifecycleAuthProbe(
        current: lifecycleAuth,
        recoveries: [
            CodexRemoteControlAccountAuth(
                accessToken: "other-token",
                accountID: "account-2"
            ),
        ]
    )
    let backend = lifecycleBackend(
        wire: wire,
        auth: auth,
        desiredState: .enabled(persistencePreference: nil),
        enrollment: lifecycleEnrollment(expiresAt: 1_100)
    )

    let error = await caughtLifecycleError {
        try await backend.refreshEnrollmentIfNeeded()
    }
    #expect(
        error as? CodexRemoteControlLifecycleError
            == .recoveredAccountMismatch(
                expected: "account-1",
                actual: "account-2"
            )
    )
    #expect(await backend.runtimeEnrollmentSnapshot()?.token == nil)
    #expect(await wire.recordedOperations() == ["refresh"])
}

@Test
func remoteControlProactiveTransientRefreshKeepsTokenAndUsesRetryAfter()
    async throws
{
    let wire = LifecycleWireProbe(refresh: [
        .failure(
            LifecycleWireTestError(
                statusCode: 503,
                retryAt: 1_120,
                isTransient: true
            )
        ),
    ])
    let backend = lifecycleBackend(
        wire: wire,
        auth: LifecycleAuthProbe(current: lifecycleAuth),
        desiredState: .enabled(persistencePreference: nil),
        enrollment: lifecycleEnrollment(expiresAt: 1_200)
    )

    try await backend.refreshEnrollmentIfNeeded()
    let runtime = try #require(await backend.runtimeEnrollmentSnapshot())
    #expect(runtime.token == "server-token")
    #expect(runtime.expiresAt == 1_200)
    #expect(runtime.nextRefreshAt == 1_120)
}

@Test
func remoteControlRequiredTransientRefreshBlocksAndUsesFallbackDelay()
    async
{
    let wire = LifecycleWireProbe(refresh: [
        .failure(
            LifecycleWireTestError(statusCode: 503, isTransient: true)
        ),
    ])
    let backend = lifecycleBackend(
        wire: wire,
        auth: LifecycleAuthProbe(current: lifecycleAuth),
        desiredState: .enabled(persistencePreference: nil),
        enrollment: lifecycleEnrollment(expiresAt: 999),
        fallbackDelay: 33
    )

    let error = await caughtLifecycleError {
        try await backend.refreshEnrollmentIfNeeded()
    }
    #expect(error is LifecycleWireTestError)
    #expect(await backend.runtimeEnrollmentSnapshot()?.nextRefreshAt == 1_033)
}

@Test
func remoteControlRequiredRefreshRespectsFutureDeferral() async {
    let wire = LifecycleWireProbe()
    let backend = lifecycleBackend(
        wire: wire,
        auth: LifecycleAuthProbe(current: lifecycleAuth),
        desiredState: .enabled(persistencePreference: nil),
        enrollment: lifecycleEnrollment(
            expiresAt: 999,
            nextRefreshAt: 1_050
        )
    )

    let error = await caughtLifecycleError {
        try await backend.refreshEnrollmentIfNeeded()
    }
    #expect(
        error as? CodexRemoteControlLifecycleError
            == .refreshDeferred(until: 1_050)
    )
    #expect(await wire.recordedOperations().isEmpty)
}

@Test
func remoteControlPairingStartRefreshesProactivelyBeforePairing()
    async throws
{
    let wire = LifecycleWireProbe(
        refresh: [.success(httpEnrollment(expiresAt: 10_000))],
        pairingStart: [.success(pairingResponse())]
    )
    let backend = lifecycleBackend(
        wire: wire,
        auth: LifecycleAuthProbe(current: lifecycleAuth),
        desiredState: .enabled(persistencePreference: nil),
        enrollment: lifecycleEnrollment(expiresAt: 1_200)
    )

    let response = try await backend.pairingStart(.init())
    #expect(response.pairingCode == "pairing-code")
    #expect(await wire.recordedOperations() == ["refresh", "pair"])
}

@Test
func remoteControlPairingStartPermissionRefreshesAndRetriesOnce()
    async throws
{
    let wire = LifecycleWireProbe(
        refresh: [.success(httpEnrollment(expiresAt: 10_000))],
        pairingStart: [
            .failure(LifecycleWireTestError(statusCode: 401)),
            .success(pairingResponse()),
        ]
    )
    let backend = lifecycleBackend(
        wire: wire,
        auth: LifecycleAuthProbe(current: lifecycleAuth),
        desiredState: .enabled(persistencePreference: nil),
        enrollment: lifecycleEnrollment()
    )

    _ = try await backend.pairingStart(.init())
    #expect(await wire.recordedOperations() == ["pair", "refresh", "pair"])
}

@Test
func remoteControlPairingStartNotFoundReenrollsAndRetriesOnce()
    async throws
{
    let wire = LifecycleWireProbe(
        enroll: [
            .success(
                httpEnrollment(
                    serverID: "server-2",
                    environmentID: "environment-2",
                    token: "server-token-2"
                )
            ),
        ],
        pairingStart: [
            .failure(LifecycleWireTestError(statusCode: 404)),
            .success(pairingResponse(environmentID: "environment-2")),
        ]
    )
    let backend = lifecycleBackend(
        wire: wire,
        auth: LifecycleAuthProbe(current: lifecycleAuth),
        desiredState: .enabled(persistencePreference: nil),
        enrollment: lifecycleEnrollment()
    )

    let response = try await backend.pairingStart(.init())
    #expect(response.environmentId == "environment-2")
    #expect(await wire.recordedOperations() == ["pair", "enroll", "pair"])
    #expect(await backend.runtimeEnrollmentSnapshot()?.serverID == "server-2")
}

@Test
func remoteControlPairingStatusPermissionRefreshesAndRetriesOnce()
    async throws
{
    let wire = LifecycleWireProbe(
        refresh: [.success(httpEnrollment(expiresAt: 10_000))],
        pairingStatus: [
            .failure(LifecycleWireTestError(statusCode: 403)),
            .success(.init(claimed: true)),
        ]
    )
    let backend = lifecycleBackend(
        wire: wire,
        auth: LifecycleAuthProbe(current: lifecycleAuth),
        desiredState: .enabled(persistencePreference: nil),
        enrollment: lifecycleEnrollment()
    )

    let response = try await backend.pairingStatus(
        .init(pairingCode: "pairing-code")
    )
    #expect(response.claimed)
    #expect(
        await wire.recordedOperations()
            == ["pairStatus", "refresh", "pairStatus"]
    )
}

@Test(arguments: [404, 410])
func remoteControlPairingStatusTreatsNotFoundAndGoneAsInvalidPairingCode(
    statusCode: Int
) async {
    let wire = LifecycleWireProbe(pairingStatus: [
        .failure(LifecycleWireTestError(statusCode: statusCode)),
    ])
    let backend = lifecycleBackend(
        wire: wire,
        auth: LifecycleAuthProbe(current: lifecycleAuth),
        desiredState: .enabled(persistencePreference: nil),
        enrollment: lifecycleEnrollment()
    )

    let error = await caughtLifecycleError {
        _ = try await backend.pairingStatus(
            .init(pairingCode: "expired-code")
        )
    }
    #expect((error as? LifecycleWireTestError)?.statusCode == statusCode)
    #expect(await wire.recordedOperations() == ["pairStatus"])
}

@Test
func remoteControlPairingRechecksAccountAfterRequest() async {
    let auth = LifecycleAuthProbe(current: lifecycleAuth)
    let wire = LifecycleWireProbe(
        pairingStart: [.success(pairingResponse())]
    )
    await wire.setPairingStartHook {
        await auth.setCurrent(
            CodexRemoteControlAccountAuth(
                accessToken: "new-token",
                accountID: "account-2"
            )
        )
    }
    let backend = lifecycleBackend(
        wire: wire,
        auth: auth,
        desiredState: .enabled(persistencePreference: nil),
        enrollment: lifecycleEnrollment()
    )

    let error = await caughtLifecycleError {
        _ = try await backend.pairingStart(.init())
    }
    #expect(error as? CodexRemoteControlLifecycleError == .pairingUnavailable)
}

@Test
func remoteControlEnableDisableStatusStreamAndClientOperationsOrchestrate()
    async throws
{
    let wire = LifecycleWireProbe()
    let auth = LifecycleAuthProbe(current: lifecycleAuth)
    let persistence = LifecyclePersistenceProbe(records: [
        lifecycleKey: CodexRemoteControlPersistedEnrollment(
            serverID: "server-1",
            environmentID: "environment-1",
            serverName: "Mars-iPad",
            enabled: true
        ),
    ])
    let webSocket = LifecycleWebSocketProbe()
    let backend = lifecycleBackend(
        wire: wire,
        auth: auth,
        persistence: persistence,
        webSocket: webSocket,
        enrollment: lifecycleEnrollment()
    )
    let changes = await backend.statusChanges()
    var iterator = changes.makeAsyncIterator()

    let enabled = try await backend.enable(.init(ephemeral: true))
    #expect(enabled.status == .connecting)
    #expect(try await iterator.next()?.status == .connecting)
    await webSocket.emit(.connected)
    #expect(try await iterator.next()?.status == .connected)

    let clients = try await backend.clientsList(
        .init(environmentId: "environment-1")
    )
    #expect(clients.data.map(\.clientId) == ["client-1"])
    _ = try await backend.clientsRevoke(
        .init(environmentId: "environment-1", clientId: "client-1")
    )

    let disabled = try await backend.disable(.init(ephemeral: false))
    #expect(disabled.status == .disabled)
    #expect(disabled.environmentId == nil)
    #expect(try await iterator.next()?.status == .disabled)
    #expect(
        await persistence.enabledWrites().map(\.1) == [false]
    )
    #expect(await webSocket.counts().disconnect == 1)
    #expect(
        await wire.recordedOperations().suffix(2) == ["list", "revoke"]
    )
}

@Test
func remoteControlEphemeralTransitionsDoNotDowngradeDurablePreference()
    async throws
{
    let persistence = LifecyclePersistenceProbe(records: [
        lifecycleKey: CodexRemoteControlPersistedEnrollment(
            serverID: "server-1",
            environmentID: "environment-1",
            serverName: "Mars-iPad",
            enabled: true
        ),
    ])
    let backend = lifecycleBackend(
        wire: LifecycleWireProbe(),
        auth: LifecycleAuthProbe(current: lifecycleAuth),
        persistence: persistence,
        desiredState: .enabled(persistencePreference: true),
        enrollment: lifecycleEnrollment()
    )

    _ = try await backend.enable(.init(ephemeral: true))
    #expect(
        await backend.desiredStateSnapshot()
            == .enabled(persistencePreference: true)
    )
    _ = try await backend.disable(.init(ephemeral: true))
    #expect(await persistence.enabledWrites().isEmpty)
    #expect((await persistence.record(for: lifecycleKey))?.enabled == true)
}
