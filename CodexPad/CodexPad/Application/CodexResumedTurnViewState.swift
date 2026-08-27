#if SWIFT_PACKAGE
    import CodexPadDomain
    import CodexPadProtocolBridge
#endif

public enum CodexResumedTurnPhase: Equatable, Sendable {
    case idle
    case starting
    case inProgress
    case completed
    case failed
    case interrupted
}

public enum CodexResumedTurnError: Error, Equatable, Sendable {
    case invalidInitialTurn
    case threadIDMismatch(
        expected: CodexStoredThreadID,
        actual: CodexStoredThreadID
    )
    case turnIDMismatch(expected: String, actual: String)
    case invalidTerminalStatus(CodexStoredTurnStatus)
    case appServer(code: Int64, message: String)
    case transport(String)
    case server(CodexStoredTurnError)
}

public struct CodexResumedTurnStartRequest: Equatable, Sendable {
    public let id: CodexAppServerRequestID
    public let params: CodexTurnStartParams
    public let selectionGeneration: UInt64
}

public struct CodexResumedTurnViewState: Equatable, Sendable {
    public private(set) var phase: CodexResumedTurnPhase
    public private(set) var selectionGeneration: UInt64
    public private(set) var exactRawThreadID: CodexStoredThreadID?
    public private(set) var requestID: CodexAppServerRequestID?
    public private(set) var serverTurnID: String?
    public private(set) var orderedItemIDs: [String]
    public private(set) var itemsByID: [String: CodexStoredThreadItem]
    public private(set) var deltasByItemID: [String: String]
    /// Raw proposed-plan deltas keyed by their canonical plan item ID.
    ///
    /// The completed `.plan` item remains authoritative in `itemsByID`; this
    /// buffer is retained only for live rendering/reconciliation diagnostics.
    public private(set) var planDeltasByItemID: [String: String]
    public private(set) var tokenUsage: CodexThreadTokenUsage?
    public private(set) var latestDiff: String?
    public private(set) var pendingNotifications: [CodexAppServerTurnNotification]
    public private(set) var error: CodexResumedTurnError?
    public private(set) var reconciliationNeeded: Bool

    public init() {
        phase = .idle
        selectionGeneration = 0
        exactRawThreadID = nil
        requestID = nil
        serverTurnID = nil
        orderedItemIDs = []
        itemsByID = [:]
        deltasByItemID = [:]
        planDeltasByItemID = [:]
        tokenUsage = nil
        latestDiff = nil
        pendingNotifications = []
        error = nil
        reconciliationNeeded = false
    }

    public mutating func selectThread(_ threadID: CodexStoredThreadID) {
        selectionGeneration &+= 1
        exactRawThreadID = threadID
        resetTurn()
    }

    public mutating func clearSelection() {
        selectionGeneration &+= 1
        exactRawThreadID = nil
        resetTurn()
    }

    public mutating func beginStart(
        id: CodexAppServerRequestID,
        params: CodexTurnStartParams
    ) -> CodexResumedTurnStartRequest? {
        guard phase == .idle,
            let exactRawThreadID,
            exactRawThreadID.rawValue == params.threadID.rawValue
        else {
            return nil
        }
        phase = .starting
        requestID = id
        error = nil
        reconciliationNeeded = false
        return CodexResumedTurnStartRequest(
            id: id,
            params: params,
            selectionGeneration: selectionGeneration
        )
    }

    public mutating func receiveStartResult(
        _ result: CodexTurnStartResult,
        for request: CodexResumedTurnStartRequest
    ) {
        guard accepts(request) else {
            return
        }
        guard Self.isInitial(result.turn) else {
            failStart(.invalidInitialTurn, for: request)
            return
        }

        serverTurnID = result.turn.id
        phase = .inProgress
        let buffered = pendingNotifications
        pendingNotifications.removeAll(keepingCapacity: true)
        for notification in buffered {
            apply(notification)
            if phase == .failed {
                break
            }
        }
    }

    public mutating func failStart(
        _ failure: CodexResumedTurnError,
        for request: CodexResumedTurnStartRequest
    ) {
        guard accepts(request) else {
            return
        }
        phase = .failed
        error = failure
        reconciliationNeeded = true
    }

    public mutating func receive(
        _ notification: CodexAppServerTurnNotification,
        selectionGeneration: UInt64
    ) {
        guard selectionGeneration == self.selectionGeneration,
            exactRawThreadID != nil,
            phase != .idle
        else {
            return
        }

        if phase == .starting {
            pendingNotifications.append(notification)
            return
        }
        if phase.isTerminal {
            if case .opaque = notification {
                pendingNotifications.append(notification)
            }
            return
        }
        apply(notification)
    }

    public static func isInitial(_ turn: CodexStoredTurn) -> Bool {
        turn.status == .inProgress
            && turn.itemsView == .notLoaded
            && turn.items.isEmpty
    }

    private mutating func apply(
        _ notification: CodexAppServerTurnNotification
    ) {
        if case .opaque = notification {
            pendingNotifications.append(notification)
            return
        }

        if case .turnDiffUpdated(let payload) = notification {
            guard payload.threadID.rawValue == exactRawThreadID?.rawValue,
                payload.turnID == serverTurnID
            else {
                return
            }
            latestDiff = payload.diff
            return
        }

        guard let expectedThreadID = exactRawThreadID,
            let actualThreadID = notification.threadID
        else {
            return
        }
        guard expectedThreadID.rawValue == actualThreadID.rawValue else {
            protocolFailure(
                .threadIDMismatch(
                    expected: expectedThreadID,
                    actual: actualThreadID
                )
            )
            return
        }
        guard let expectedTurnID = serverTurnID else {
            return
        }
        if let actualTurnID = notification.turnID {
            guard expectedTurnID == actualTurnID else {
                protocolFailure(
                    .turnIDMismatch(
                        expected: expectedTurnID,
                        actual: actualTurnID
                    )
                )
                return
            }
        } else if !notification.allowsMissingTurnID {
            return
        }

        switch notification {
        case .error:
            pendingNotifications.append(notification)

        case .turnStarted:
            break

        case .itemStarted(let payload):
            upsert(payload.item)

        case .agentMessageDelta(let payload):
            deltasByItemID[payload.itemID, default: ""] += payload.delta

        case .reasoningSummaryTextDelta,
            .reasoningSummaryPartAdded,
            .reasoningTextDelta:
            pendingNotifications.append(notification)

        case .planDelta(let payload):
            planDeltasByItemID[payload.itemID, default: ""] += payload.delta

        case .itemCompleted(let payload):
            upsert(payload.item)

        case .threadTokenUsageUpdated(let payload):
            tokenUsage = payload.tokenUsage

        case .turnCompleted(let payload):
            finish(with: payload.turn)

        case .turnDiffUpdated:
            break

        case .turnPlanUpdated,
            .commandExecutionOutputDelta,
            .terminalInteraction,
            .fileChangePatchUpdated,
            .mcpToolCallProgress,
            .rawResponseItemCompleted,
            .rawResponseCompleted,
            .hookStarted,
            .hookCompleted,
            .autoApprovalReviewStarted,
            .autoApprovalReviewCompleted:
            pendingNotifications.append(notification)

        case .opaque:
            break
        }
    }

    private mutating func upsert(_ item: CodexStoredThreadItem) {
        if itemsByID[item.id] == nil {
            orderedItemIDs.append(item.id)
        }
        itemsByID[item.id] = item
    }

    private mutating func finish(with turn: CodexStoredTurn) {
        var canonicalOrder: [String] = []
        var canonicalItems: [String: CodexStoredThreadItem] = [:]
        for item in turn.items {
            if canonicalItems[item.id] == nil {
                canonicalOrder.append(item.id)
            }
            canonicalItems[item.id] = item
        }
        orderedItemIDs = canonicalOrder
        itemsByID = canonicalItems

        switch turn.status {
        case .completed:
            phase = .completed
        case .failed:
            phase = .failed
        case .interrupted:
            phase = .interrupted
        case .inProgress:
            protocolFailure(.invalidTerminalStatus(.inProgress))
            return
        }
        if let turnError = turn.error {
            error = .server(turnError)
        }
        reconciliationNeeded = true
    }

    private mutating func protocolFailure(
        _ failure: CodexResumedTurnError
    ) {
        phase = .failed
        error = failure
        reconciliationNeeded = true
        pendingNotifications.removeAll()
    }

    private func accepts(
        _ request: CodexResumedTurnStartRequest
    ) -> Bool {
        phase == .starting
            && request.selectionGeneration == selectionGeneration
            && request.id == requestID
            && request.params.threadID.rawValue
                == exactRawThreadID?.rawValue
    }

    private mutating func resetTurn() {
        phase = .idle
        requestID = nil
        serverTurnID = nil
        orderedItemIDs = []
        itemsByID = [:]
        deltasByItemID = [:]
        planDeltasByItemID = [:]
        tokenUsage = nil
        latestDiff = nil
        pendingNotifications = []
        error = nil
        reconciliationNeeded = false
    }
}

private extension CodexResumedTurnPhase {
    var isTerminal: Bool {
        switch self {
        case .completed, .failed, .interrupted:
            true
        case .idle, .starting, .inProgress:
            false
        }
    }
}

private extension CodexAppServerTurnNotification {
    var threadID: CodexStoredThreadID? {
        switch self {
        case .error(let payload):
            payload.threadID
        case .turnStarted(let payload):
            payload.threadID
        case .itemStarted(let payload):
            payload.threadID
        case .agentMessageDelta(let payload):
            payload.threadID
        case .reasoningSummaryTextDelta(let payload):
            payload.threadID
        case .reasoningSummaryPartAdded(let payload):
            payload.threadID
        case .reasoningTextDelta(let payload):
            payload.threadID
        case .planDelta(let payload):
            payload.threadID
        case .itemCompleted(let payload):
            payload.threadID
        case .threadTokenUsageUpdated(let payload):
            payload.threadID
        case .turnCompleted(let payload):
            payload.threadID
        case .turnDiffUpdated(let payload):
            payload.threadID
        case .turnPlanUpdated(let payload):
            payload.threadID
        case .commandExecutionOutputDelta(let payload):
            payload.threadID
        case .terminalInteraction(let payload):
            payload.threadID
        case .fileChangePatchUpdated(let payload):
            payload.threadID
        case .mcpToolCallProgress(let payload):
            payload.threadID
        case .rawResponseItemCompleted(let payload):
            payload.threadID
        case .rawResponseCompleted(let payload):
            payload.threadID
        case .hookStarted(let payload):
            payload.threadID
        case .hookCompleted(let payload):
            payload.threadID
        case .autoApprovalReviewStarted(let payload):
            payload.threadID
        case .autoApprovalReviewCompleted(let payload):
            payload.threadID
        case .opaque:
            nil
        }
    }

    var turnID: String? {
        switch self {
        case .error(let payload):
            payload.turnID
        case .turnStarted(let payload):
            payload.turn.id
        case .itemStarted(let payload):
            payload.turnID
        case .agentMessageDelta(let payload):
            payload.turnID
        case .reasoningSummaryTextDelta(let payload):
            payload.turnID
        case .reasoningSummaryPartAdded(let payload):
            payload.turnID
        case .reasoningTextDelta(let payload):
            payload.turnID
        case .planDelta(let payload):
            payload.turnID
        case .itemCompleted(let payload):
            payload.turnID
        case .threadTokenUsageUpdated(let payload):
            payload.turnID
        case .turnCompleted(let payload):
            payload.turn.id
        case .turnDiffUpdated(let payload):
            payload.turnID
        case .turnPlanUpdated(let payload):
            payload.turnID
        case .commandExecutionOutputDelta(let payload):
            payload.turnID
        case .terminalInteraction(let payload):
            payload.turnID
        case .fileChangePatchUpdated(let payload):
            payload.turnID
        case .mcpToolCallProgress(let payload):
            payload.turnID
        case .rawResponseItemCompleted(let payload):
            payload.turnID
        case .rawResponseCompleted(let payload):
            payload.turnID
        case .hookStarted(let payload):
            payload.turnID
        case .hookCompleted(let payload):
            payload.turnID
        case .autoApprovalReviewStarted(let payload):
            payload.turnID
        case .autoApprovalReviewCompleted(let payload):
            payload.turnID
        case .opaque:
            nil
        }
    }

    var allowsMissingTurnID: Bool {
        switch self {
        case .hookStarted, .hookCompleted:
            true
        default:
            false
        }
    }
}
