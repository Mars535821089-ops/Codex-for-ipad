#if SWIFT_PACKAGE
    import CodexPadDomain
#endif
import Foundation

// MARK: - Injectable lifecycle boundaries

/// The small error surface the lifecycle needs from any HTTP implementation.
/// `retryAt` is an absolute Unix timestamp when the server supplied Retry-After.
public protocol CodexRemoteControlLifecycleWireFailure: Error, Sendable {
    var statusCode: Int? { get }
    var retryAt: Int64? { get }
    var isTransient: Bool { get }
}

public protocol CodexRemoteControlLifecycleWire: Sendable {
    func enroll(
        auth: CodexRemoteControlAccountAuth,
        installationID: String,
        serverName: String,
        operatingSystem: String,
        architecture: String,
        appServerVersion: String
    ) async throws -> CodexRemoteControlHTTPEnrollment

    func refresh(
        auth: CodexRemoteControlAccountAuth,
        installationID: String,
        serverID: String,
        environmentID: String
    ) async throws -> CodexRemoteControlHTTPEnrollment

    func startPairing(
        serverToken: String,
        serverID: String,
        environmentID: String,
        manualCode: Bool
    ) async throws -> CodexRemoteControlPairingStartResponse

    func pairingStatus(
        serverToken: String,
        pairingCode: String?,
        manualPairingCode: String?
    ) async throws -> CodexRemoteControlPairingStatusResponse

    func listClients(
        auth: CodexRemoteControlAccountAuth,
        params: CodexRemoteControlClientsListParams
    ) async throws -> CodexRemoteControlClientsListResponse

    func revokeClient(
        auth: CodexRemoteControlAccountAuth,
        params: CodexRemoteControlClientsRevokeParams
    ) async throws -> CodexRemoteControlClientsRevokeResponse
}

public protocol CodexRemoteControlLifecycleAuthProviding: Sendable {
    func currentRemoteControlAuth() async throws
        -> CodexRemoteControlAccountAuth

    func recoverRemoteControlAuth() async throws
        -> CodexRemoteControlAccountAuth?
}

public protocol CodexRemoteControlLifecyclePersisting: Sendable {
    func load(
        for key: CodexRemoteControlPersistenceKey
    ) async throws -> CodexRemoteControlPersistedEnrollment?

    /// A nil value preserves the existing enabled preference on conflict.
    func upsert(
        _ enrollment: CodexRemoteControlPersistedEnrollment,
        for key: CodexRemoteControlPersistenceKey,
        enabled: Bool?
    ) async throws

    /// Returns true when an existing row was updated.
    func setEnabled(
        _ enabled: Bool,
        for key: CodexRemoteControlPersistenceKey
    ) async throws -> Bool
}

public protocol CodexRemoteControlWebSocketLifecycle: Sendable {
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
    >

    func disconnect() async
}

// MARK: - Durable and runtime state

public struct CodexRemoteControlPersistenceKey: Codable, Equatable, Hashable,
    Sendable
{
    public let target: String
    public let accountID: String
    public let appServerClientName: String

    public init(
        target: String,
        accountID: String,
        appServerClientName: String
    ) {
        self.target = target
        self.accountID = accountID
        self.appServerClientName = appServerClientName
    }
}

/// The durable enrollment intentionally contains no server credential.
public struct CodexRemoteControlPersistedEnrollment: Codable, Equatable,
    Sendable
{
    public let serverID: String
    public let environmentID: String
    public let serverName: String
    public let enabled: Bool?

    public init(
        serverID: String,
        environmentID: String,
        serverName: String,
        enabled: Bool?
    ) {
        self.serverID = serverID
        self.environmentID = environmentID
        self.serverName = serverName
        self.enabled = enabled
    }
}

public enum CodexRemoteControlServerTokenRefreshRequirement: Equatable,
    Sendable
{
    case required
    case proactive
    case notNeeded
}

public struct CodexRemoteControlRuntimeEnrollment: Equatable, Sendable {
    public let target: String
    public let accountID: String
    public let serverID: String
    public let environmentID: String
    public let serverName: String
    public var token: String?
    public var expiresAt: Int64?
    public var nextRefreshAt: Int64?

    public init(
        target: String,
        accountID: String,
        serverID: String,
        environmentID: String,
        serverName: String,
        token: String?,
        expiresAt: Int64?,
        nextRefreshAt: Int64?
    ) {
        self.target = target
        self.accountID = accountID
        self.serverID = serverID
        self.environmentID = environmentID
        self.serverName = serverName
        self.token = token
        self.expiresAt = expiresAt
        self.nextRefreshAt = nextRefreshAt
    }

    public func serverTokenRefreshRequirement(
        at now: Int64
    ) -> CodexRemoteControlServerTokenRefreshRequirement {
        guard token != nil, let expiresAt else {
            return .required
        }
        guard expiresAt > now else {
            return .required
        }
        if expiresAt > now + 300 {
            return .notNeeded
        }
        if let nextRefreshAt, nextRefreshAt > now {
            return .notNeeded
        }
        return .proactive
    }
}

public enum CodexRemoteControlLifecycleDesiredState: Equatable, Sendable {
    /// Used only until the current auth scope has been resolved in persistence.
    case unknown
    case disabled
    /// nil is an ephemeral enable; true is a durable enable.
    case enabled(persistencePreference: Bool?)

    fileprivate var isEnabled: Bool {
        if case .enabled = self { return true }
        return false
    }

    fileprivate var persistencePreference: Bool? {
        guard case let .enabled(preference) = self else { return nil }
        return preference
    }
}

public enum CodexRemoteControlLifecycleError: Error, Equatable, Sendable {
    case invalidTarget
    case pairingRequiresEnabledRemoteControl
    case pairingUnavailable
    case recoveredAccountMismatch(expected: String, actual: String)
    case refreshDeferred(until: Int64)
}

// MARK: - Concrete HTTP adaptation

extension CodexRemoteControlHTTPTransport: CodexRemoteControlLifecycleWire {}

extension CodexRemoteControlHTTPError:
    CodexRemoteControlLifecycleWireFailure
{
    public var statusCode: Int? {
        guard case let .httpStatus(_, statusCode, _) = self else {
            return nil
        }
        return statusCode
    }

    /// The transport currently exposes no Retry-After value. A transport that
    /// does expose it can use the lifecycle wire seam directly.
    public var retryAt: Int64? { nil }

    public var isTransient: Bool {
        switch self {
        case .nonHTTPResponse, .transport:
            true
        case let .httpStatus(_, statusCode, _):
            statusCode == 429 || (500 ... 599).contains(statusCode)
        default:
            false
        }
    }
}

// MARK: - Lifecycle backend

public actor CodexRemoteControlLifecycleBackend:
    CodexRemoteControlBackend
{
    public typealias StatusStream = AsyncThrowingStream<
        CodexRemoteControlStatusChangedNotification,
        Error
    >

    private enum EnrollmentSelection {
        case reuse
        case replace
    }

    private let target: String
    private let installationID: String
    private let serverName: String
    private let operatingSystem: String
    private let architecture: String
    private let appServerVersion: String
    private let appServerClientName: String
    private let wire: any CodexRemoteControlLifecycleWire
    private let authProvider: any CodexRemoteControlLifecycleAuthProviding
    private let persistence: any CodexRemoteControlLifecyclePersisting
    private let webSocket: any CodexRemoteControlWebSocketLifecycle
    private let now: @Sendable () -> Int64
    private let fallbackRefreshDelay: @Sendable () -> Int64

    private var desiredState: CodexRemoteControlLifecycleDesiredState
    private var enrollment: CodexRemoteControlRuntimeEnrollment?
    private var currentStatus: CodexRemoteControlStatusChangedNotification
    private var statusContinuations: [UUID: StatusStream.Continuation] = [:]
    private var webSocketTask: Task<Void, Never>?
    private var webSocketGeneration: UInt64 = 0

    public init(
        target: String,
        installationID: String,
        serverName: String,
        operatingSystem: String,
        architecture: String,
        appServerVersion: String,
        appServerClientName: String,
        initialDesiredState: CodexRemoteControlLifecycleDesiredState = .unknown,
        initialEnrollment: CodexRemoteControlRuntimeEnrollment? = nil,
        wire: any CodexRemoteControlLifecycleWire,
        authProvider: any CodexRemoteControlLifecycleAuthProviding,
        persistence: any CodexRemoteControlLifecyclePersisting,
        webSocket: any CodexRemoteControlWebSocketLifecycle,
        now: @escaping @Sendable () -> Int64 = {
            Int64(Date().timeIntervalSince1970)
        },
        fallbackRefreshDelay: @escaping @Sendable () -> Int64 = {
            Int64.random(in: 24 ... 36)
        }
    ) {
        self.target = target
        self.installationID = installationID
        self.serverName = serverName
        self.operatingSystem = operatingSystem
        self.architecture = architecture
        self.appServerVersion = appServerVersion
        self.appServerClientName = appServerClientName
        self.desiredState = initialDesiredState
        enrollment = initialEnrollment
        self.wire = wire
        self.authProvider = authProvider
        self.persistence = persistence
        self.webSocket = webSocket
        self.now = now
        self.fallbackRefreshDelay = fallbackRefreshDelay

        let enabled = initialDesiredState.isEnabled
        currentStatus = CodexRemoteControlStatusChangedNotification(
            status: enabled ? .connecting : .disabled,
            serverName: serverName,
            installationId: installationID,
            environmentId: enabled ? initialEnrollment?.environmentID : nil
        )
    }

    public func desiredStateSnapshot()
        -> CodexRemoteControlLifecycleDesiredState
    {
        desiredState
    }

    public func runtimeEnrollmentSnapshot()
        -> CodexRemoteControlRuntimeEnrollment?
    {
        enrollment
    }

    /// Resolve the tri-state preference once the current account scope is known.
    @discardableResult
    public func resolvePersistedPreference() async throws -> Bool {
        guard desiredState == .unknown else {
            return desiredState.isEnabled
        }
        try validateTarget()
        let auth = try await authProvider.currentRemoteControlAuth()
        let key = persistenceKey(for: auth.accountID)
        let record = try await persistence.load(for: key)
        if let record {
            enrollment = runtimeEnrollment(from: record, accountID: auth.accountID)
        } else {
            enrollment = nil
        }

        if record?.enabled == true {
            desiredState = .enabled(persistencePreference: true)
            publishStatus(
                .connecting,
                environmentID: record?.environmentID
            )
            return true
        }

        desiredState = .disabled
        publishStatus(.disabled, environmentID: nil)
        return false
    }

    public func enable(
        _ params: CodexRemoteControlEnableParams
    ) async throws -> CodexRemoteControlEnableResponse {
        try validateTarget()
        if desiredState == .unknown {
            _ = try await resolvePersistedPreference()
        }

        if params.ephemeral {
            if desiredState != .enabled(persistencePreference: true) {
                desiredState = .enabled(persistencePreference: nil)
            }
            publishStatus(
                .connecting,
                environmentID: enrollment?.environmentID
            )
            do {
                let ready = try await readyEnrollment(selection: .reuse)
                try await requireCurrentAccount(ready.auth.accountID)
                guard desiredState.isEnabled else {
                    throw CodexRemoteControlLifecycleError
                        .pairingRequiresEnabledRemoteControl
                }
                try await startWebSocketIfNeeded(
                    auth: ready.auth,
                    enrollment: ready.enrollment
                )
            } catch {
                if desiredState.isEnabled {
                    publishStatus(
                        .errored,
                        environmentID: enrollment?.environmentID
                    )
                }
                throw error
            }
        } else {
            let ready = try await readyEnrollment(selection: .reuse)
            try await requireCurrentAccount(ready.auth.accountID)
            let key = persistenceKey(for: ready.auth.accountID)
            let updated = try await persistence.setEnabled(true, for: key)
            if !updated {
                try await persistence.upsert(
                    persistedEnrollment(from: ready.enrollment),
                    for: key,
                    enabled: true
                )
            }
            desiredState = .enabled(persistencePreference: true)
            publishStatus(
                .connecting,
                environmentID: ready.enrollment.environmentID
            )
            do {
                try await startWebSocketIfNeeded(
                    auth: ready.auth,
                    enrollment: ready.enrollment
                )
            } catch {
                publishStatus(
                    .errored,
                    environmentID: enrollment?.environmentID
                )
                throw error
            }
        }

        return CodexRemoteControlEnableResponse(currentStatus)
    }

    public func disable(
        _ params: CodexRemoteControlDisableParams
    ) async throws -> CodexRemoteControlDisableResponse {
        try validateTarget()
        if desiredState == .unknown {
            _ = try await resolvePersistedPreference()
        }

        if !params.ephemeral {
            let auth = try await authProvider.currentRemoteControlAuth()
            _ = try await persistence.setEnabled(
                false,
                for: persistenceKey(for: auth.accountID)
            )
        }

        desiredState = .disabled
        await stopWebSocket()
        publishStatus(.disabled, environmentID: nil)
        return CodexRemoteControlDisableResponse(currentStatus)
    }

    public func statusRead() async throws
        -> CodexRemoteControlStatusReadResponse
    {
        try validateTarget()
        if desiredState == .unknown {
            _ = try await resolvePersistedPreference()
        }
        if desiredState.isEnabled, webSocketTask == nil {
            do {
                let ready = try await readyEnrollment(selection: .reuse)
                guard desiredState.isEnabled else {
                    throw CodexRemoteControlLifecycleError
                        .pairingRequiresEnabledRemoteControl
                }
                try await requireCurrentAccount(ready.auth.accountID)
                publishStatus(
                    .connecting,
                    environmentID: ready.enrollment.environmentID
                )
                try await startWebSocketIfNeeded(
                    auth: ready.auth,
                    enrollment: ready.enrollment
                )
            } catch {
                if desiredState.isEnabled {
                    publishStatus(
                        .errored,
                        environmentID: enrollment?.environmentID
                    )
                }
                throw error
            }
        }
        return CodexRemoteControlStatusReadResponse(currentStatus)
    }

    public func pairingStart(
        _ params: CodexRemoteControlPairingStartParams
    ) async throws -> CodexRemoteControlPairingStartResponse {
        try await requirePairingEnabled()
        var ready: (
            auth: CodexRemoteControlAccountAuth,
            enrollment: CodexRemoteControlRuntimeEnrollment
        )
        do {
            ready = try await readyEnrollment(selection: .reuse)
        } catch {
            if statusCode(of: error) == 404 {
                ready = try await readyEnrollment(selection: .replace)
            } else {
                throw error
            }
        }

        var response: CodexRemoteControlPairingStartResponse
        do {
            response = try await wire.startPairing(
                serverToken: try requiredToken(ready.enrollment),
                serverID: ready.enrollment.serverID,
                environmentID: ready.enrollment.environmentID,
                manualCode: params.manualCode
            )
        } catch {
            switch statusCode(of: error) {
            case 401, 403:
                clearServerToken(for: ready.enrollment)
                ready = try await refreshEnrollment(
                    ready.enrollment.clearingToken(),
                    auth: ready.auth
                )
                do {
                    response = try await wire.startPairing(
                        serverToken: try requiredToken(ready.enrollment),
                        serverID: ready.enrollment.serverID,
                        environmentID: ready.enrollment.environmentID,
                        manualCode: params.manualCode
                    )
                } catch {
                    if isPermissionError(error) {
                        clearServerToken(for: ready.enrollment)
                        throw CodexRemoteControlLifecycleError
                            .pairingUnavailable
                    }
                    if statusCode(of: error) == 404 {
                        _ = try? await readyEnrollment(selection: .replace)
                        throw CodexRemoteControlLifecycleError
                            .pairingUnavailable
                    }
                    throw error
                }
            case 404:
                ready = try await readyEnrollment(selection: .replace)
                do {
                    response = try await wire.startPairing(
                        serverToken: try requiredToken(ready.enrollment),
                        serverID: ready.enrollment.serverID,
                        environmentID: ready.enrollment.environmentID,
                        manualCode: params.manualCode
                    )
                } catch {
                    if isPermissionError(error) {
                        clearServerToken(for: ready.enrollment)
                        throw CodexRemoteControlLifecycleError
                            .pairingUnavailable
                    }
                    if statusCode(of: error) == 404 {
                        _ = try? await readyEnrollment(selection: .replace)
                        throw CodexRemoteControlLifecycleError
                            .pairingUnavailable
                    }
                    throw error
                }
            default:
                throw error
            }
        }

        try await recheckPairingContext(
            auth: ready.auth,
            enrollment: ready.enrollment
        )
        guard response.environmentId == ready.enrollment.environmentID else {
            throw CodexRemoteControlLifecycleError.pairingUnavailable
        }
        return response
    }

    public func pairingStatus(
        _ params: CodexRemoteControlPairingStatusParams
    ) async throws -> CodexRemoteControlPairingStatusResponse {
        try await requirePairingEnabled()
        let initialAuth = try await authProvider.currentRemoteControlAuth()
        guard let existing = enrollment,
              existing.target == target,
              existing.accountID == initialAuth.accountID
        else {
            throw CodexRemoteControlLifecycleError.pairingUnavailable
        }

        var ready: (
            auth: CodexRemoteControlAccountAuth,
            enrollment: CodexRemoteControlRuntimeEnrollment
        )
        do {
            ready = try await refreshEnrollment(existing, auth: initialAuth)
        } catch {
            if statusCode(of: error) == 404 {
                _ = try? await readyEnrollment(selection: .replace)
                throw CodexRemoteControlLifecycleError.pairingUnavailable
            }
            throw error
        }

        var response: CodexRemoteControlPairingStatusResponse
        do {
            response = try await wire.pairingStatus(
                serverToken: try requiredToken(ready.enrollment),
                pairingCode: params.pairingCode,
                manualPairingCode: params.manualPairingCode
            )
        } catch {
            guard isPermissionError(error) else {
                // 404/410 are invalid pairing codes and deliberately pass through.
                throw error
            }
            clearServerToken(for: ready.enrollment)
            ready = try await refreshEnrollment(
                ready.enrollment.clearingToken(),
                auth: ready.auth
            )
            do {
                response = try await wire.pairingStatus(
                    serverToken: try requiredToken(ready.enrollment),
                    pairingCode: params.pairingCode,
                    manualPairingCode: params.manualPairingCode
                )
            } catch {
                if isPermissionError(error) {
                    clearServerToken(for: ready.enrollment)
                    throw CodexRemoteControlLifecycleError.pairingUnavailable
                }
                throw error
            }
        }

        try await recheckPairingContext(
            auth: ready.auth,
            enrollment: ready.enrollment
        )
        return response
    }

    public func clientsList(
        _ params: CodexRemoteControlClientsListParams
    ) async throws -> CodexRemoteControlClientsListResponse {
        let auth = try await authProvider.currentRemoteControlAuth()
        do {
            return try await wire.listClients(auth: auth, params: params)
        } catch {
            guard statusCode(of: error) == 401,
                  let recovered = try await authProvider
                    .recoverRemoteControlAuth()
            else {
                throw error
            }
            return try await wire.listClients(
                auth: recovered,
                params: params
            )
        }
    }

    public func clientsRevoke(
        _ params: CodexRemoteControlClientsRevokeParams
    ) async throws -> CodexRemoteControlClientsRevokeResponse {
        let auth = try await authProvider.currentRemoteControlAuth()
        do {
            return try await wire.revokeClient(auth: auth, params: params)
        } catch {
            guard statusCode(of: error) == 401,
                  let recovered = try await authProvider
                    .recoverRemoteControlAuth()
            else {
                throw error
            }
            return try await wire.revokeClient(
                auth: recovered,
                params: params
            )
        }
    }

    public func statusChanges() async -> StatusStream {
        let id = UUID()
        let pair = StatusStream.makeStream()
        pair.continuation.onTermination = { @Sendable [weak self] _ in
            Task { await self?.removeStatusContinuation(id) }
        }
        statusContinuations[id] = pair.continuation
        return pair.stream
    }

    public func refreshEnrollmentIfNeeded() async throws {
        guard let enrollment else {
            throw CodexRemoteControlLifecycleError.pairingUnavailable
        }
        let auth = try await authProvider.currentRemoteControlAuth()
        guard auth.accountID == enrollment.accountID else {
            throw CodexRemoteControlLifecycleError
                .recoveredAccountMismatch(
                    expected: enrollment.accountID,
                    actual: auth.accountID
                )
        }
        _ = try await refreshEnrollment(enrollment, auth: auth)
    }

    /// Drops only the process-bound transport while preserving the user's
    /// durable enable preference and enrollment across iPad suspension.
    public func suspendTransport() async {
        guard desiredState.isEnabled else {
            return
        }
        await stopWebSocket()
        publishStatus(
            .connecting,
            environmentID: enrollment?.environmentID
        )
    }

    /// Re-establishes an enabled transport after foreground activation without
    /// mutating the durable preference.
    public func resumeTransportIfNeeded() async throws {
        _ = try await statusRead()
    }

    // MARK: Enrollment and refresh

    private func readyEnrollment(
        selection: EnrollmentSelection
    ) async throws -> (
        auth: CodexRemoteControlAccountAuth,
        enrollment: CodexRemoteControlRuntimeEnrollment
    ) {
        var auth = try await authProvider.currentRemoteControlAuth()
        var selected: CodexRemoteControlRuntimeEnrollment?

        if selection == .reuse,
           let enrollment,
           enrollment.target == target,
           enrollment.accountID == auth.accountID
        {
            selected = enrollment
        }

        if selection == .reuse, selected == nil {
            let key = persistenceKey(for: auth.accountID)
            if let record = try await persistence.load(for: key) {
                selected = runtimeEnrollment(
                    from: record,
                    accountID: auth.accountID
                )
                enrollment = selected
            }
        }

        if selected == nil {
            let enrolled = try await enroll(auth: auth)
            auth = enrolled.auth
            selected = enrolled.enrollment
        }

        guard let selected else {
            throw CodexRemoteControlLifecycleError.pairingUnavailable
        }

        do {
            return try await refreshEnrollment(selected, auth: auth)
        } catch {
            if statusCode(of: error) == 404, selection == .reuse {
                return try await enroll(auth: auth)
            }
            throw error
        }
    }

    private func enroll(
        auth initialAuth: CodexRemoteControlAccountAuth
    ) async throws -> (
        auth: CodexRemoteControlAccountAuth,
        enrollment: CodexRemoteControlRuntimeEnrollment
    ) {
        var auth = initialAuth
        let response: CodexRemoteControlHTTPEnrollment
        do {
            response = try await wire.enroll(
                auth: auth,
                installationID: installationID,
                serverName: serverName,
                operatingSystem: operatingSystem,
                architecture: architecture,
                appServerVersion: appServerVersion
            )
        } catch {
            guard isPermissionError(error),
                  let recovered = try await authProvider
                    .recoverRemoteControlAuth()
            else {
                throw error
            }
            auth = recovered
            response = try await wire.enroll(
                auth: auth,
                installationID: installationID,
                serverName: serverName,
                operatingSystem: operatingSystem,
                architecture: architecture,
                appServerVersion: appServerVersion
            )
        }

        let runtime = CodexRemoteControlRuntimeEnrollment(
            target: target,
            accountID: auth.accountID,
            serverID: response.serverID,
            environmentID: response.environmentID,
            serverName: serverName,
            token: response.remoteControlToken,
            expiresAt: response.expiresAt,
            nextRefreshAt: nil
        )
        enrollment = runtime
        try await persistence.upsert(
            persistedEnrollment(from: runtime),
            for: persistenceKey(for: auth.accountID),
            enabled: desiredState.persistencePreference
        )
        return (auth, runtime)
    }

    private func refreshEnrollment(
        _ initialEnrollment: CodexRemoteControlRuntimeEnrollment,
        auth initialAuth: CodexRemoteControlAccountAuth
    ) async throws -> (
        auth: CodexRemoteControlAccountAuth,
        enrollment: CodexRemoteControlRuntimeEnrollment
    ) {
        let timestamp = now()
        let requirement = initialEnrollment
            .serverTokenRefreshRequirement(at: timestamp)
        guard requirement != .notNeeded else {
            commit(initialEnrollment)
            return (initialAuth, initialEnrollment)
        }
        if requirement == .required,
           let retryAt = initialEnrollment.nextRefreshAt,
           retryAt > timestamp
        {
            throw CodexRemoteControlLifecycleError
                .refreshDeferred(until: retryAt)
        }

        var auth = initialAuth
        do {
            let response: CodexRemoteControlHTTPEnrollment
            do {
                response = try await wire.refresh(
                    auth: auth,
                    installationID: installationID,
                    serverID: initialEnrollment.serverID,
                    environmentID: initialEnrollment.environmentID
                )
            } catch {
                guard isPermissionError(error) else { throw error }
                guard let recovered = try await authProvider
                    .recoverRemoteControlAuth()
                else {
                    clearServerToken(for: initialEnrollment)
                    throw error
                }
                guard recovered.accountID == initialEnrollment.accountID else {
                    clearServerToken(for: initialEnrollment)
                    throw CodexRemoteControlLifecycleError
                        .recoveredAccountMismatch(
                            expected: initialEnrollment.accountID,
                            actual: recovered.accountID
                        )
                }
                auth = recovered
                do {
                    response = try await wire.refresh(
                        auth: auth,
                        installationID: installationID,
                        serverID: initialEnrollment.serverID,
                        environmentID: initialEnrollment.environmentID
                    )
                } catch {
                    if isPermissionError(error) {
                        clearServerToken(for: initialEnrollment)
                    }
                    throw error
                }
            }

            guard response.serverID == initialEnrollment.serverID,
                  response.environmentID == initialEnrollment.environmentID
            else {
                throw CodexRemoteControlHTTPError.mismatchedEnrollment(
                    expectedServerID: initialEnrollment.serverID,
                    expectedEnvironmentID: initialEnrollment.environmentID,
                    actualServerID: response.serverID,
                    actualEnvironmentID: response.environmentID
                )
            }
            var refreshed = initialEnrollment
            refreshed.token = response.remoteControlToken
            refreshed.expiresAt = response.expiresAt
            refreshed.nextRefreshAt = nil
            try commitChecked(refreshed, replacing: initialEnrollment)
            return (auth, refreshed)
        } catch {
            guard isTransient(error) else { throw error }
            var deferred = initialEnrollment
            if let retryAt = retryAt(of: error), retryAt > timestamp {
                deferred.nextRefreshAt = retryAt
            } else {
                let delay = min(36, max(24, fallbackRefreshDelay()))
                deferred.nextRefreshAt = timestamp + delay
            }
            try commitChecked(deferred, replacing: initialEnrollment)
            if requirement == .proactive,
               deferred.token != nil,
               let expiresAt = deferred.expiresAt,
               expiresAt > timestamp
            {
                return (auth, deferred)
            }
            throw error
        }
    }

    // MARK: WebSocket lifecycle

    private func startWebSocketIfNeeded(
        auth: CodexRemoteControlAccountAuth,
        enrollment expectedEnrollment: CodexRemoteControlRuntimeEnrollment
    ) async throws {
        guard webSocketTask == nil else { return }
        guard desiredState.isEnabled else {
            throw CodexRemoteControlLifecycleError
                .pairingRequiresEnabledRemoteControl
        }
        try await requireCurrentAccount(auth.accountID)
        guard sameEnrollment(enrollment, expectedEnrollment) else {
            throw CodexRemoteControlLifecycleError.pairingUnavailable
        }

        let stream = try await webSocket.connect(
            target: target,
            installationID: installationID,
            accountID: auth.accountID,
            serverID: expectedEnrollment.serverID,
            environmentID: expectedEnrollment.environmentID,
            serverName: expectedEnrollment.serverName,
            token: try requiredToken(expectedEnrollment)
        )
        guard desiredState.isEnabled else {
            await webSocket.disconnect()
            throw CodexRemoteControlLifecycleError
                .pairingRequiresEnabledRemoteControl
        }
        try await requireCurrentAccount(auth.accountID)
        guard sameEnrollment(enrollment, expectedEnrollment) else {
            await webSocket.disconnect()
            throw CodexRemoteControlLifecycleError.pairingUnavailable
        }

        webSocketGeneration &+= 1
        let generation = webSocketGeneration
        webSocketTask = Task { [weak self] in
            do {
                for try await status in stream {
                    guard !Task.isCancelled else { break }
                    await self?.receiveWebSocketStatus(
                        status,
                        generation: generation,
                        environmentID: expectedEnrollment.environmentID
                    )
                }
                await self?.webSocketFinished(
                    generation: generation,
                    error: nil
                )
            } catch {
                await self?.webSocketFinished(
                    generation: generation,
                    error: error
                )
            }
        }
    }

    private func stopWebSocket() async {
        webSocketGeneration &+= 1
        webSocketTask?.cancel()
        webSocketTask = nil
        await webSocket.disconnect()
    }

    private func receiveWebSocketStatus(
        _ status: CodexRemoteControlConnectionStatus,
        generation: UInt64,
        environmentID: String
    ) {
        guard generation == webSocketGeneration,
              desiredState.isEnabled
        else { return }
        publishStatus(
            status,
            environmentID: status == .disabled ? nil : environmentID
        )
    }

    private func webSocketFinished(
        generation: UInt64,
        error: (any Error)?
    ) {
        _ = error
        guard generation == webSocketGeneration else { return }
        webSocketTask = nil
        if desiredState.isEnabled {
            publishStatus(
                .errored,
                environmentID: enrollment?.environmentID
            )
        }
    }

    // MARK: State helpers

    private func requirePairingEnabled() async throws {
        if desiredState == .unknown {
            _ = try await resolvePersistedPreference()
        }
        guard desiredState.isEnabled else {
            throw CodexRemoteControlLifecycleError
                .pairingRequiresEnabledRemoteControl
        }
    }

    private func recheckPairingContext(
        auth: CodexRemoteControlAccountAuth,
        enrollment expectedEnrollment: CodexRemoteControlRuntimeEnrollment
    ) async throws {
        guard desiredState.isEnabled else {
            throw CodexRemoteControlLifecycleError.pairingUnavailable
        }
        let currentAuth = try await authProvider.currentRemoteControlAuth()
        guard currentAuth.accountID == auth.accountID,
              sameEnrollment(enrollment, expectedEnrollment)
        else {
            throw CodexRemoteControlLifecycleError.pairingUnavailable
        }
    }

    private func requireCurrentAccount(_ accountID: String) async throws {
        let current = try await authProvider.currentRemoteControlAuth()
        guard current.accountID == accountID else {
            throw CodexRemoteControlLifecycleError
                .recoveredAccountMismatch(
                    expected: accountID,
                    actual: current.accountID
                )
        }
    }

    private func requiredToken(
        _ enrollment: CodexRemoteControlRuntimeEnrollment
    ) throws -> String {
        guard let token = enrollment.token, !token.isEmpty else {
            throw CodexRemoteControlLifecycleError.pairingUnavailable
        }
        return token
    }

    private func validateTarget() throws {
        guard !target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw CodexRemoteControlLifecycleError.invalidTarget
        }
    }

    private func persistenceKey(
        for accountID: String
    ) -> CodexRemoteControlPersistenceKey {
        CodexRemoteControlPersistenceKey(
            target: target,
            accountID: accountID,
            appServerClientName: appServerClientName
        )
    }

    private func runtimeEnrollment(
        from record: CodexRemoteControlPersistedEnrollment,
        accountID: String
    ) -> CodexRemoteControlRuntimeEnrollment {
        CodexRemoteControlRuntimeEnrollment(
            target: target,
            accountID: accountID,
            serverID: record.serverID,
            environmentID: record.environmentID,
            serverName: serverName,
            token: nil,
            expiresAt: nil,
            nextRefreshAt: nil
        )
    }

    private func persistedEnrollment(
        from enrollment: CodexRemoteControlRuntimeEnrollment
    ) -> CodexRemoteControlPersistedEnrollment {
        CodexRemoteControlPersistedEnrollment(
            serverID: enrollment.serverID,
            environmentID: enrollment.environmentID,
            serverName: enrollment.serverName,
            enabled: desiredState.persistencePreference
        )
    }

    private func sameEnrollment(
        _ lhs: CodexRemoteControlRuntimeEnrollment?,
        _ rhs: CodexRemoteControlRuntimeEnrollment
    ) -> Bool {
        guard let lhs else { return false }
        return lhs.target == rhs.target
            && lhs.accountID == rhs.accountID
            && lhs.serverID == rhs.serverID
            && lhs.environmentID == rhs.environmentID
    }

    private func commit(
        _ updated: CodexRemoteControlRuntimeEnrollment
    ) {
        enrollment = updated
    }

    private func commitChecked(
        _ updated: CodexRemoteControlRuntimeEnrollment,
        replacing old: CodexRemoteControlRuntimeEnrollment
    ) throws {
        guard sameEnrollment(enrollment, old) else {
            throw CodexRemoteControlLifecycleError.pairingUnavailable
        }
        enrollment = updated
    }

    private func clearServerToken(
        for expectedEnrollment: CodexRemoteControlRuntimeEnrollment
    ) {
        guard sameEnrollment(enrollment, expectedEnrollment),
              var current = enrollment
        else { return }
        current.token = nil
        current.expiresAt = nil
        enrollment = current
    }

    private func publishStatus(
        _ status: CodexRemoteControlConnectionStatus,
        environmentID: String?
    ) {
        let notification = CodexRemoteControlStatusChangedNotification(
            status: status,
            serverName: serverName,
            installationId: installationID,
            environmentId: status == .disabled ? nil : environmentID
        )
        guard notification != currentStatus else { return }
        currentStatus = notification
        for continuation in statusContinuations.values {
            continuation.yield(notification)
        }
    }

    private func removeStatusContinuation(_ id: UUID) {
        statusContinuations[id] = nil
    }

    private func statusCode(of error: any Error) -> Int? {
        (error as? any CodexRemoteControlLifecycleWireFailure)?.statusCode
    }

    private func retryAt(of error: any Error) -> Int64? {
        (error as? any CodexRemoteControlLifecycleWireFailure)?.retryAt
    }

    private func isTransient(_ error: any Error) -> Bool {
        (error as? any CodexRemoteControlLifecycleWireFailure)?.isTransient
            == true
    }

    private func isPermissionError(_ error: any Error) -> Bool {
        guard let code = statusCode(of: error) else { return false }
        return code == 401 || code == 403
    }
}

private extension CodexRemoteControlRuntimeEnrollment {
    func clearingToken() -> Self {
        var copy = self
        copy.token = nil
        copy.expiresAt = nil
        return copy
    }
}
