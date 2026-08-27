#if SWIFT_PACKAGE
import CodexPadDomain
#endif
import Foundation

public protocol CodexRemoteControlBackend: Sendable {
    func enable(
        _ params: CodexRemoteControlEnableParams
    ) async throws -> CodexRemoteControlEnableResponse

    func disable(
        _ params: CodexRemoteControlDisableParams
    ) async throws -> CodexRemoteControlDisableResponse

    func statusRead() async throws -> CodexRemoteControlStatusReadResponse

    func pairingStart(
        _ params: CodexRemoteControlPairingStartParams
    ) async throws -> CodexRemoteControlPairingStartResponse

    func pairingStatus(
        _ params: CodexRemoteControlPairingStatusParams
    ) async throws -> CodexRemoteControlPairingStatusResponse

    func clientsList(
        _ params: CodexRemoteControlClientsListParams
    ) async throws -> CodexRemoteControlClientsListResponse

    func clientsRevoke(
        _ params: CodexRemoteControlClientsRevokeParams
    ) async throws -> CodexRemoteControlClientsRevokeResponse

    func statusChanges() async
        -> AsyncThrowingStream<
            CodexRemoteControlStatusChangedNotification,
            Error
        >
}

public enum CodexRemoteControlServiceError: Error, Equatable, Sendable {
    case disabledStatusHasEnvironmentID
    case statusIdentityChanged
    case invalidStatusTransition(
        from: CodexRemoteControlConnectionStatus,
        to: CodexRemoteControlConnectionStatus
    )
    case invalidEnableResponse(CodexRemoteControlConnectionStatus)
    case invalidDisableResponse(CodexRemoteControlConnectionStatus)
    case pairingRequiresEnabledRemoteControl
    case pairingStatusRequiresExactlyOneCode
    case clientListRequiresEnvironmentID
    case clientListLimitOutOfRange(UInt32)
    case clientRevokeRequiresEnvironmentID
    case clientRevokeRequiresClientID
}

public actor CodexRemoteControlService {
    public typealias StatusStream = AsyncThrowingStream<
        CodexRemoteControlStatusChangedNotification,
        Error
    >

    private enum TransitionKey: Equatable, Sendable {
        case enable(ephemeral: Bool)
        case disable(ephemeral: Bool)
    }

    private enum TransitionResult: Sendable {
        case enable(CodexRemoteControlEnableResponse)
        case disable(CodexRemoteControlDisableResponse)
    }

    private struct ActiveTransition {
        let id: UUID
        let key: TransitionKey
        let task: Task<TransitionResult, Error>
    }

    private let backend: any CodexRemoteControlBackend
    private var activeTransition: ActiveTransition?
    private var currentStatus:
        CodexRemoteControlStatusChangedNotification?
    private var lastBackendNotification:
        CodexRemoteControlStatusChangedNotification?
    private var desiredEnabled: Bool?

    private var observationTask: Task<Void, Never>?
    private var observationFinished = false
    private var observationError: (any Error)?
    private var statusContinuations: [
        UUID: StatusStream.Continuation
    ] = [:]

    public init(backend: any CodexRemoteControlBackend) {
        self.backend = backend
    }

    public func enable(
        _ params: CodexRemoteControlEnableParams = .init()
    ) async throws -> CodexRemoteControlEnableResponse {
        ensureObservationStarted()
        let result = try await performTransition(
            .enable(ephemeral: params.ephemeral),
            enableParams: params,
            disableParams: nil
        )
        guard case let .enable(response) = result else {
            preconditionFailure("enable transition returned a disable response")
        }
        return response
    }

    public func disable(
        _ params: CodexRemoteControlDisableParams = .init()
    ) async throws -> CodexRemoteControlDisableResponse {
        ensureObservationStarted()
        let result = try await performTransition(
            .disable(ephemeral: params.ephemeral),
            enableParams: nil,
            disableParams: params
        )
        guard case let .disable(response) = result else {
            preconditionFailure("disable transition returned an enable response")
        }
        return response
    }

    public func statusRead() async throws
        -> CodexRemoteControlStatusReadResponse
    {
        ensureObservationStarted()
        let response = try await backend.statusRead()
        try acceptStatusSnapshot(response)
        return response
    }

    public func pairingStart(
        _ params: CodexRemoteControlPairingStartParams = .init()
    ) async throws -> CodexRemoteControlPairingStartResponse {
        ensureObservationStarted()
        try await requireEnabledForPairing()
        let response = try await backend.pairingStart(params)
        guard desiredEnabled == true else {
            throw CodexRemoteControlServiceError
                .pairingRequiresEnabledRemoteControl
        }
        return response
    }

    public func pairingStatus(
        _ params: CodexRemoteControlPairingStatusParams
    ) async throws -> CodexRemoteControlPairingStatusResponse {
        ensureObservationStarted()
        try await requireEnabledForPairing()
        try validatePairingCodePresence(params)
        let response = try await backend.pairingStatus(params)
        guard desiredEnabled == true else {
            throw CodexRemoteControlServiceError
                .pairingRequiresEnabledRemoteControl
        }
        return response
    }

    public func clientsList(
        _ params: CodexRemoteControlClientsListParams
    ) async throws -> CodexRemoteControlClientsListResponse {
        guard !params.environmentId.isEmpty else {
            throw CodexRemoteControlServiceError
                .clientListRequiresEnvironmentID
        }
        if let limit = params.limit,
           !(1 ... 100).contains(limit)
        {
            throw CodexRemoteControlServiceError
                .clientListLimitOutOfRange(limit)
        }
        return try await backend.clientsList(params)
    }

    public func clientsRevoke(
        _ params: CodexRemoteControlClientsRevokeParams
    ) async throws -> CodexRemoteControlClientsRevokeResponse {
        guard !params.environmentId.isEmpty else {
            throw CodexRemoteControlServiceError
                .clientRevokeRequiresEnvironmentID
        }
        guard !params.clientId.isEmpty else {
            throw CodexRemoteControlServiceError
                .clientRevokeRequiresClientID
        }
        return try await backend.clientsRevoke(params)
    }

    public func statusNotifications() -> StatusStream {
        ensureObservationStarted()
        let id = UUID()
        let pair = StatusStream.makeStream()
        pair.continuation.onTermination = { @Sendable [weak self] _ in
            Task {
                await self?.removeStatusContinuation(id)
            }
        }
        if let observationError {
            pair.continuation.finish(throwing: observationError)
        } else if observationFinished {
            pair.continuation.finish()
        } else {
            statusContinuations[id] = pair.continuation
        }
        return pair.stream
    }

    public func cachedStatus()
        -> CodexRemoteControlStatusChangedNotification?
    {
        currentStatus
    }

    private func performTransition(
        _ key: TransitionKey,
        enableParams: CodexRemoteControlEnableParams?,
        disableParams: CodexRemoteControlDisableParams?
    ) async throws -> TransitionResult {
        while true {
            if let activeTransition {
                if activeTransition.key == key {
                    return try await activeTransition.task.value
                }
                _ = try? await activeTransition.task.value
                continue
            }

            let id = UUID()
            let backend = self.backend
            let task = Task<TransitionResult, Error> { [weak self] in
                do {
                    let result: TransitionResult
                    switch key {
                    case .enable:
                        guard let enableParams else {
                            preconditionFailure("missing enable parameters")
                        }
                        result = .enable(
                            try await backend.enable(enableParams)
                        )
                    case .disable:
                        guard let disableParams else {
                            preconditionFailure("missing disable parameters")
                        }
                        result = .disable(
                            try await backend.disable(disableParams)
                        )
                    }
                    guard let self else {
                        throw CancellationError()
                    }
                    return try await self.finishTransition(
                        id: id,
                        key: key,
                        result: result
                    )
                } catch {
                    await self?.finishFailedTransition(id: id)
                    throw error
                }
            }
            activeTransition = ActiveTransition(
                id: id,
                key: key,
                task: task
            )
            return try await task.value
        }
    }

    private func finishTransition(
        id: UUID,
        key: TransitionKey,
        result: TransitionResult
    ) throws -> TransitionResult {
        guard activeTransition?.id == id else {
            return result
        }
        defer { activeTransition = nil }

        switch (key, result) {
        case let (.enable(ephemeral), .enable(response)):
            guard response.status == .connecting
                    || response.status == .connected
            else {
                throw CodexRemoteControlServiceError
                    .invalidEnableResponse(response.status)
            }
            try acceptCommandStatus(response)
            desiredEnabled = true
            // Runtime-only enable is deliberately not promoted into a
            // persistent success. Persistence remains the backend's concern.
            _ = ephemeral
        case let (.disable(ephemeral), .disable(response)):
            guard response.status == .disabled else {
                throw CodexRemoteControlServiceError
                    .invalidDisableResponse(response.status)
            }
            try acceptCommandStatus(response)
            desiredEnabled = false
            // Ephemeral disable stops this runtime without claiming that a
            // durable preference was cleared.
            _ = ephemeral
        case (.enable, .disable), (.disable, .enable):
            preconditionFailure("remote-control transition response mismatch")
        }
        return result
    }

    private func finishFailedTransition(id: UUID) {
        if activeTransition?.id == id {
            activeTransition = nil
        }
    }

    private func acceptStatusSnapshot(
        _ response: CodexRemoteControlStatusReadResponse
    ) throws {
        let status = statusNotification(response)
        try validateStatusPayload(status)
        currentStatus = status
        updateDesiredState(from: status)
    }

    private func acceptCommandStatus(
        _ response: some CodexRemoteControlStatusFields
    ) throws {
        let status = statusNotification(response)
        try validateStatusPayload(status)
        if let currentStatus,
           !isValidTransition(
               from: currentStatus.status,
               to: status.status
           )
        {
            throw CodexRemoteControlServiceError
                .invalidStatusTransition(
                    from: currentStatus.status,
                    to: status.status
                )
        }
        currentStatus = status
    }

    private func acceptBackendNotification(
        _ notification:
            CodexRemoteControlStatusChangedNotification
    ) throws {
        if notification == lastBackendNotification {
            return
        }
        try validateStatusPayload(notification)
        if let currentStatus,
           !isValidTransition(
               from: currentStatus.status,
               to: notification.status
           )
        {
            throw CodexRemoteControlServiceError
                .invalidStatusTransition(
                    from: currentStatus.status,
                    to: notification.status
                )
        }
        currentStatus = notification
        lastBackendNotification = notification
        updateDesiredState(from: notification)
        for continuation in statusContinuations.values {
            continuation.yield(notification)
        }
    }

    private func validateStatusPayload(
        _ status: CodexRemoteControlStatusChangedNotification
    ) throws {
        if status.status == .disabled,
           status.environmentId != nil
        {
            throw CodexRemoteControlServiceError
                .disabledStatusHasEnvironmentID
        }
        if let currentStatus,
           (
               currentStatus.serverName != status.serverName
                   || currentStatus.installationId
                   != status.installationId
           )
        {
            throw CodexRemoteControlServiceError.statusIdentityChanged
        }
    }

    private func isValidTransition(
        from: CodexRemoteControlConnectionStatus,
        to: CodexRemoteControlConnectionStatus
    ) -> Bool {
        if from == to {
            return true
        }
        switch from {
        case .disabled:
            return to == .connecting
        case .connecting:
            return true
        case .connected:
            return to == .connecting
                || to == .errored
                || to == .disabled
        case .errored:
            return to == .connecting
                || to == .connected
                || to == .disabled
        }
    }

    private func updateDesiredState(
        from status: CodexRemoteControlStatusChangedNotification
    ) {
        desiredEnabled = status.status != .disabled
    }

    private func requireEnabledForPairing() async throws {
        if desiredEnabled == nil {
            _ = try await statusRead()
        }
        guard desiredEnabled == true else {
            throw CodexRemoteControlServiceError
                .pairingRequiresEnabledRemoteControl
        }
    }

    private func validatePairingCodePresence(
        _ params: CodexRemoteControlPairingStatusParams
    ) throws {
        switch (
            params.pairingCode,
            params.manualPairingCode
        ) {
        case (.some, .none), (.none, .some):
            return
        case (.some, .some), (.none, .none):
            throw CodexRemoteControlServiceError
                .pairingStatusRequiresExactlyOneCode
        }
    }

    private func statusNotification(
        _ fields: some CodexRemoteControlStatusFields
    ) -> CodexRemoteControlStatusChangedNotification {
        CodexRemoteControlStatusChangedNotification(
            status: fields.status,
            serverName: fields.serverName,
            installationId: fields.installationId,
            environmentId: fields.environmentId
        )
    }

    private func ensureObservationStarted() {
        guard observationTask == nil,
              !observationFinished
        else {
            return
        }
        let backend = self.backend
        observationTask = Task { [weak self] in
            let changes = await backend.statusChanges()
            do {
                for try await notification in changes {
                    guard let self else { return }
                    try await self.acceptBackendNotification(notification)
                }
                await self?.finishObservation(error: nil)
            } catch {
                await self?.finishObservation(error: error)
            }
        }
    }

    private func finishObservation(error: (any Error)?) {
        observationTask = nil
        observationFinished = true
        observationError = error
        let continuations = statusContinuations.values
        statusContinuations.removeAll()
        for continuation in continuations {
            if let error {
                continuation.finish(throwing: error)
            } else {
                continuation.finish()
            }
        }
    }

    private func removeStatusContinuation(_ id: UUID) {
        statusContinuations.removeValue(forKey: id)
    }
}
