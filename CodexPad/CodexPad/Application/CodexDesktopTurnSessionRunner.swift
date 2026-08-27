#if SWIFT_PACKAGE
import CodexPadDomain
import CodexPadProtocolBridge
#endif
import Foundation

@MainActor
public final class CodexDesktopTurnSessionRunner:
    CodexDesktopTurnSessionStarting,
    CodexDesktopReviewStarting,
    CodexDesktopElicitationCounting,
    CodexDesktopTurnSessionInterrupting,
    CodexDesktopTurnSessionSteering,
    CodexDesktopThreadCompacting
{
    public struct ActiveTurnSnapshot:
        Equatable,
        Sendable
    {
        public let turnID: String
        public let threadID: CodexStoredThreadID

        public init(
            turnID: String,
            threadID: CodexStoredThreadID
        ) {
            self.turnID = turnID
            self.threadID = threadID
        }
    }

    public typealias ProviderFactory =
        (CodexTurnStartParams) -> (any CodexPersistedTurnProvider)?
    public typealias ToolExecutorFactory =
        (
            CodexTurnStartParams,
            @escaping (
                CodexPersistedTurnWorkspaceToolActivity
            ) async -> Bool,
            @escaping (
                CodexRequestUserInputPrompt
            ) async throws -> CodexRequestUserInputAnswers,
            @escaping (
                CodexUpdatePlan
            ) async throws -> Void
        ) ->
            (any CodexPersistedTurnToolExecutor)?
    public typealias NotificationSink =
        @MainActor (CodexAppServerTurnNotification) -> Void
    public typealias AppServerNotificationSink =
        @MainActor ([CodexAppServerNotification]) -> Void

    private let sessionStore: CodexSessionStore
    private let providerFactory: ProviderFactory
    private let toolExecutorFactory: ToolExecutorFactory
    private let approvalRequester:
        (CodexPersistedTurnWorkspaceToolActivity) async -> Bool
    private let requestUserInputRequester:
        (CodexRequestUserInputPrompt) async throws
            -> CodexRequestUserInputAnswers
    private let notificationSink: NotificationSink
    private let appServerNotificationSink:
        AppServerNotificationSink
    private let lifecycleAnchor:
        CodexDesktopConversationLifecycleAnchor?
    private var requestSequence: Int64 = 0
    private var tasks: [String: Task<Void, Never>] = [:]
    private var cancellations: [String: CodexTurnCancellation] = [:]
    private var threadIDs: [String: CodexStoredThreadID] = [:]
    private var selectionGenerations: [String: UInt64] = [:]
    private var steeringInputs:
        [String: [CodexStoredUserInput]] = [:]
    private var planItems:
        [String: [CodexStoredThreadItem]] = [:]
    private var elicitationCounts:
        [CodexStoredThreadID: Int64] = [:]
    private struct WaitingCounts {
        var approval: Int = 0
        var userInput: Int = 0
    }
    private enum WaitingKind {
        case approval
        case userInput
    }
    private var waitingCounts:
        [CodexStoredThreadID: WaitingCounts] = [:]

    public init(
        sessionStore: CodexSessionStore,
        providerFactory: @escaping ProviderFactory,
        toolExecutorFactory:
            @escaping ToolExecutorFactory = { _, _, _, _ in nil },
        approvalRequester:
            @escaping (
                CodexPersistedTurnWorkspaceToolActivity
            ) async -> Bool = { _ in false },
        requestUserInputRequester:
            @escaping (
                CodexRequestUserInputPrompt
            ) async throws -> CodexRequestUserInputAnswers = { _ in
                CodexRequestUserInputAnswers(answers: [:])
            },
        notificationSink: @escaping NotificationSink,
        appServerNotificationSink:
            @escaping AppServerNotificationSink = { _ in },
        lifecycleAnchor:
            CodexDesktopConversationLifecycleAnchor? = nil
    ) {
        self.sessionStore = sessionStore
        self.providerFactory = providerFactory
        self.toolExecutorFactory = toolExecutorFactory
        self.approvalRequester = approvalRequester
        self.requestUserInputRequester = requestUserInputRequester
        self.notificationSink = notificationSink
        self.appServerNotificationSink = appServerNotificationSink
        self.lifecycleAnchor = lifecycleAnchor
    }

    @discardableResult
    public func startDesktopTurn(
        id: CodexAppServerRequestID,
        params: CodexTurnStartParams
    ) throws -> CodexTurnStartResult {
        try startDesktopTurn(
            id: id,
            persistedParams: params,
            providerParams: params,
            reviewHint: nil
        )
    }

    private func startDesktopTurn(
        id: CodexAppServerRequestID,
        persistedParams: CodexTurnStartParams,
        providerParams: CodexTurnStartParams,
        reviewHint: String?
    ) throws -> CodexTurnStartResult {
        sessionStore.selectResumedTurnThread(
            persistedParams.threadID
        )
        // Route released desktop composer requests through the desktop
        // compatibility boundary.  The renderer may still send the legacy
        // permissions profile together with the newer sandboxPolicy; the
        // core rejects that ambiguous pair, so normalization must happen
        // before the stable turn/start transport call (not only for direct
        // SessionStore callers).
        let started = try sessionStore.startDesktopTurn(
            id: id,
            params: persistedParams
        )
        lifecycleAnchor?.turnStarted(persistedParams.threadID)
        let selectionGeneration =
            sessionStore.resumedTurnState.selectionGeneration
        let cancellation = CodexTurnCancellation()
        cancellations[started.turn.id] = cancellation
        threadIDs[started.turn.id] = persistedParams.threadID
        selectionGenerations[started.turn.id] =
            selectionGeneration
        steeringInputs[started.turn.id] = []
        planItems[started.turn.id] = []

        guard let provider = providerFactory(providerParams) else {
            let error = CodexDesktopTurnSessionRunnerError
                .providerUnavailable
            var projector = CodexDesktopTurnNotificationProjector(
                threadID: persistedParams.threadID,
                turnID: started.turn.id,
                startedAtMs: Self.now()
            )
            persistStableTurnFailure(
                error,
                threadID: persistedParams.threadID,
                turnID: started.turn.id
            )
            for notification in projector.failed(
                    error
                )
            {
                emit(
                    notification,
                    selectionGeneration: selectionGeneration
                )
            }
            cancellations[started.turn.id] = nil
            threadIDs[started.turn.id] = nil
            selectionGenerations[started.turn.id] = nil
            steeringInputs[started.turn.id] = nil
            planItems[started.turn.id] = nil
            return started
        }

        var projector = CodexDesktopTurnNotificationProjector(
            threadID: persistedParams.threadID,
            turnID: started.turn.id,
            startedAtMs: Self.now()
        )
        for notification in projector.started(turn: started.turn) {
            emit(
                notification,
                selectionGeneration: selectionGeneration
            )
        }
        if let reviewHint {
            let item = CodexStoredThreadItem.enteredReviewMode(
                id: "\(started.turn.id)-entered-review",
                review: reviewHint
            )
            let timestamp = Self.now()
            emit(
                .itemStarted(
                    CodexItemStartedNotification(
                        item: item,
                        threadID: persistedParams.threadID,
                        turnID: started.turn.id,
                        startedAtMs: timestamp
                    )
                ),
                selectionGeneration: selectionGeneration
            )
            emit(
                .itemCompleted(
                    CodexItemCompletedNotification(
                        item: item,
                        threadID: persistedParams.threadID,
                        turnID: started.turn.id,
                        completedAtMs: timestamp
                    )
                ),
                selectionGeneration: selectionGeneration
            )
        }

        let priorRequestID = nextRequestID(prefix: "desktop-prior")
        let turnID = started.turn.id
        Self.recordProviderDiagnostic(
            "turn-provider started turn=\(turnID)"
        )
        let task = Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            defer {
                self.tasks[turnID] = nil
                self.cancellations[turnID] = nil
                self.threadIDs[turnID] = nil
                self.selectionGenerations[turnID] = nil
                self.steeringInputs[turnID] = nil
                self.planItems[turnID] = nil
            }
            var attempt = 0
            var providerEventCount = 0
            while true {
                var providerTransportPayload: CodexJSONValue?
                do {
                    guard let attemptProvider =
                        attempt == 0
                            ? provider
                            : self.providerFactory(providerParams)
                    else {
                        throw CodexDesktopTurnSessionRunnerError.providerUnavailable
                    }
                    let planPublisher:
                        (CodexUpdatePlan) async throws -> Void =
                        { [weak self] update in
                            guard let self else {
                                return
                            }
                            let item = CodexStoredThreadItem.plan(
                                id: "\(turnID)-plan",
                                text: Self.planText(update)
                            )
                            self.planItems[turnID] = [item]
                            let timestamp = Self.now()
                            self.emit(
                                .turnPlanUpdated(
                                    CodexTurnPlanUpdatedNotification(
                                        threadID:
                                            persistedParams.threadID,
                                        turnID: turnID,
                                        explanation:
                                            update.explanation,
                                        plan: update.plan.map {
                                            CodexTurnPlanStep(
                                                step: $0.step,
                                                status:
                                                    $0.status.rawValue
                                            )
                                        }
                                    )
                                ),
                                selectionGeneration:
                                    selectionGeneration
                            )
                            self.emit(
                                .itemStarted(
                                    CodexItemStartedNotification(
                                        item: item,
                                        threadID:
                                            persistedParams.threadID,
                                        turnID: turnID,
                                        startedAtMs: timestamp
                                    )
                                ),
                                selectionGeneration:
                                    selectionGeneration
                            )
                            self.emit(
                                .itemCompleted(
                                    CodexItemCompletedNotification(
                                        item: item,
                                        threadID:
                                            persistedParams.threadID,
                                        turnID: turnID,
                                        completedAtMs: timestamp
                                    )
                                ),
                                selectionGeneration:
                                    selectionGeneration
                            )
                        }
                    let trackedApprovalRequester:
                        (
                            CodexPersistedTurnWorkspaceToolActivity
                        ) async -> Bool =
                        { [weak self] activity in
                            guard let self else {
                                return false
                            }
                            return await self.requestApproval(
                                activity,
                                threadID: persistedParams.threadID
                            )
                        }
                    let trackedRequestUserInputRequester:
                        (
                            CodexRequestUserInputPrompt
                        ) async throws
                            -> CodexRequestUserInputAnswers =
                        { [weak self] prompt in
                            guard let self else {
                                throw
                                    CodexDesktopRequestUserInputBrokerError
                                        .cancelled
                            }
                            return try await self.requestUserInput(
                                prompt,
                                threadID: persistedParams.threadID
                            )
                        }
                    let coordinator = CodexPersistedTurnCoordinator(
                        history: self.sessionStore,
                        provider: attemptProvider,
                        toolExecutor: self.toolExecutorFactory(
                            providerParams,
                            trackedApprovalRequester,
                            trackedRequestUserInputRequester,
                            planPublisher
                        )
                    )
                    _ = try await coordinator.continueRun(
                        started: started,
                        priorRequestID: priorRequestID,
                        params: providerParams,
                        cancellation: cancellation,
                        onTurnNotification: { notification in
                            self.emit(
                                notification,
                                selectionGeneration: selectionGeneration
                            )
                        },
                        onProviderEvent: { event in
                            providerEventCount += 1
                            if case let .realtime(
                                _, _, eventType, payload
                            ) = event,
                               eventType == "provider_transport_error"
                            {
                                providerTransportPayload = payload
                                let transportDiagnostic =
                                    CodexOfficialProviderTransportDiagnostic
                                        .make(payload: payload)
                                UserDefaults.standard.set(
                                    "turn-provider transport-error at="
                                        + String(
                                            Int(
                                                Date().timeIntervalSince1970
                                                    * 1_000
                                            )
                                        )
                                        + " turn=\(turnID) "
                                        + transportDiagnostic,
                                    forKey:
                                        "codex.desktop.last-turn-provider-transport-diagnostic"
                                )
                            }
                            Self.recordProviderDiagnostic(
                                "turn-provider event="
                                    + Self.providerEventKind(event)
                                    + " count=\(providerEventCount)"
                            )
                            // Do not clear the transport diagnostic from a
                            // responseCompleted event. The released desktop
                            // coordinator may synthesize that event while
                            // terminating a transport-error turn, and the
                            // diagnostic is intentionally retained for the
                            // settings/error surface. A later turn can replace
                            // it with a newer diagnostic.
                            var projected =
                                projector.providerEvent(event)
                            if reviewHint != nil,
                               case let .responseCompleted(
                                   _, _, _, _, endTurn
                               ) = event,
                               endTurn != false
                            {
                                let timestamp = Self.now()
                                let item =
                                    CodexStoredThreadItem
                                        .exitedReviewMode(
                                            id:
                                                "\(turnID)-exited-review",
                                            review:
                                                projector.currentText
                                        )
                                let exitNotifications:
                                    [CodexAppServerTurnNotification] = [
                                        .itemStarted(
                                            CodexItemStartedNotification(
                                                item: item,
                                                threadID:
                                                    persistedParams
                                                        .threadID,
                                                turnID: turnID,
                                                startedAtMs: timestamp
                                            )
                                        ),
                                        .itemCompleted(
                                            CodexItemCompletedNotification(
                                                item: item,
                                                threadID:
                                                    persistedParams
                                                        .threadID,
                                                turnID: turnID,
                                                completedAtMs: timestamp
                                            )
                                        ),
                                    ]
                                let completionIndex =
                                    projected.firstIndex {
                                        if case .turnCompleted = $0 {
                                            return true
                                        }
                                        return false
                                    } ?? projected.endIndex
                                projected.insert(
                                    contentsOf: exitNotifications,
                                    at: completionIndex
                                )
                            }
                            for notification in Self.withPlanItems(
                                projected,
                                planItems:
                                    self.planItems[turnID] ?? []
                            ) {
                                self.emit(
                                    notification,
                                    selectionGeneration:
                                        selectionGeneration
                                )
                            }
                        },
                        onToolOutput: { request, output in
                            for notification in projector.toolOutput(
                                request: request,
                                output: output
                            ) {
                                self.emit(
                                    notification,
                                    selectionGeneration:
                                        selectionGeneration
                                )
                            }
                        },
                        takeSteeringInput: {
                            let input =
                                self.steeringInputs[turnID] ?? []
                            self.steeringInputs[turnID] = []
                            return input
                        }
                    )
                    let terminalIdle =
                        self.sessionStore
                            .takeTerminalIdleNotifications(
                                for: persistedParams.threadID
                            )
                    if !terminalIdle.isEmpty {
                        self.appServerNotificationSink(terminalIdle)
                    }
                    break
                } catch {
                    Self.recordProviderDiagnostic(
                        "turn-provider failed attempt=\(attempt)"
                            + " eventCount=\(providerEventCount)"
                            + " type=\(String(describing: type(of: error)))"
                            + " error=\(CodexDiagnosticSanitization.publicErrorSummary(error))"
                    )
                    if cancellation.isCancelled
                        || error is CancellationError
                    {
                        self.persistStableTurnCancellationIfRunning(
                            threadID: persistedParams.threadID,
                            turnID: turnID
                        )
                        self.emit(
                            Self.withPlanItems(
                                projector.interrupted(),
                                planItems: self.planItems[turnID] ?? []
                            ),
                            selectionGeneration: selectionGeneration
                        )
                        break
                    }
                    let displayedError = Self.displayedProviderError(
                        original: error,
                        transportPayload: providerTransportPayload
                    )
                    if attempt == 0 && providerEventCount == 0
                        && !(error
                            is CodexOfficialProviderFirstEventTimeoutError)
                        && !(error
                            is CodexOfficialProviderActivityTimeoutError)
                    {
                        for notification in Self.withPlanItems(
                            projector.failed(
                                displayedError,
                                willRetry: true
                            ),
                            planItems: self.planItems[turnID] ?? []
                        ) {
                            self.emit(
                                notification,
                                selectionGeneration: selectionGeneration
                            )
                        }
                        attempt += 1
                        try? await Task.sleep(
                            nanoseconds: 250_000_000
                        )
                        continue
                    }
                    cancellation.cancel()
                    self.persistStableTurnFailure(
                        displayedError,
                        threadID: persistedParams.threadID,
                        turnID: turnID
                    )
                    for notification in Self.withPlanItems(
                        projector.failed(displayedError),
                        planItems: self.planItems[turnID] ?? []
                    ) {
                        self.emit(
                            notification,
                            selectionGeneration: selectionGeneration
                        )
                    }
                    break
                }
            }
        }
        tasks[turnID] = task
        return started
    }

    public func startDesktopReview(
        id: CodexAppServerRequestID,
        params: CodexReviewStartParams
    ) throws -> CodexReviewStartResult {
        let resolved = Self.reviewPrompt(for: params.target)
        let reviewThreadID: CodexStoredThreadID
        if params.delivery == .detached {
            let fork = try sessionStore.forkThread(
                id: Self.derivedRequestID(
                    id,
                    suffix: "review-fork"
                ),
                params: CodexThreadForkParams(
                    threadID: params.threadID,
                    threadSource: .value("subAgent")
                )
            )
            reviewThreadID = fork.thread.id
        } else {
            reviewThreadID = params.threadID
        }

        let displayedText =
            params.delivery == .inline
            ? resolved.hint
            : resolved.detachedPrompt
        let persistedParams = CodexTurnStartParams(
            threadID: reviewThreadID,
            input: [
                .text(
                    text: displayedText,
                    textElements: []
                ),
            ]
        )
        let providerParams = CodexTurnStartParams(
            threadID: reviewThreadID,
            input: [
                .text(
                    text: params.delivery == .inline
                        ? resolved.prompt
                        : resolved.detachedPrompt,
                    textElements: []
                ),
            ]
        )
        let started = try startDesktopTurn(
            id: id,
            persistedParams: persistedParams,
            providerParams: providerParams,
            reviewHint:
                params.delivery == .inline
                    ? resolved.hint
                    : nil
        )
        return CodexReviewStartResult(
            turn: started.turn,
            reviewThreadID: reviewThreadID
        )
    }

    public func incrementDesktopElicitation(
        id: CodexAppServerRequestID,
        threadID: CodexStoredThreadID
    ) throws -> Int64 {
        try verifyElicitationThreadExists(id: id, threadID: threadID)
        let current = elicitationCounts[threadID] ?? 0
        let (next, overflow) = current.addingReportingOverflow(1)
        guard !overflow else {
            throw CodexDesktopTurnSessionRunnerError
                .elicitationCountOverflow
        }
        elicitationCounts[threadID] = next
        return next
    }

    public func decrementDesktopElicitation(
        id: CodexAppServerRequestID,
        threadID: CodexStoredThreadID
    ) throws -> Int64 {
        try verifyElicitationThreadExists(id: id, threadID: threadID)
        guard let current = elicitationCounts[threadID],
              current > 0
        else {
            throw CodexDesktopTurnSessionRunnerError
                .elicitationCountAlreadyZero
        }
        let next = current - 1
        if next == 0 {
            elicitationCounts.removeValue(forKey: threadID)
        } else {
            elicitationCounts[threadID] = next
        }
        return next
    }

    private func verifyElicitationThreadExists(
        id: CodexAppServerRequestID,
        threadID: CodexStoredThreadID
    ) throws {
        _ = try sessionStore.readThread(
            id: Self.derivedRequestID(
                id,
                suffix: "elicitation-thread-read"
            ),
            params: CodexThreadReadParams(
                threadID: threadID,
                includeTurns: false
            )
        )
    }

    public func startDesktopCompaction(
        id: CodexAppServerRequestID,
        threadID: CodexStoredThreadID
    ) throws {
        sessionStore.selectResumedTurnThread(threadID)
        let selectionGeneration =
            sessionStore.resumedTurnState.selectionGeneration
        let started = try sessionStore.startStableCompaction(
            id: id,
            threadID: threadID
        )
        let turnID = started.turnID
        let item = CodexStoredThreadItem.contextCompaction(
            id: started.itemID
        )
        let startedAt = Self.now()
        let cancellation = CodexTurnCancellation()
        cancellations[turnID] = cancellation
        threadIDs[turnID] = threadID
        selectionGenerations[turnID] = selectionGeneration
        emit(
            .turnStarted(
                CodexTurnStartedNotification(
                    threadID: threadID,
                    turn: CodexStoredTurn(
                        id: turnID,
                        items: [],
                        status: .inProgress,
                        startedAt: startedAt
                    )
                )
            ),
            selectionGeneration: selectionGeneration
        )
        emit(
            .itemStarted(
                CodexItemStartedNotification(
                    item: item,
                    threadID: threadID,
                    turnID: turnID,
                    startedAtMs: startedAt
                )
            ),
            selectionGeneration: selectionGeneration
        )

        let promptParams = CodexTurnStartParams(
            threadID: threadID,
            input: [
                .text(
                    text: Self.compactionPrompt,
                    textElements: []
                ),
            ]
        )
        guard let provider = providerFactory(promptParams) else {
            try? cancelCompaction(turnID: turnID)
            emitCompactionFailure(
                CodexDesktopTurnSessionRunnerError.providerUnavailable,
                threadID: threadID,
                turnID: turnID,
                item: item,
                startedAt: startedAt,
                selectionGeneration: selectionGeneration
            )
            return
        }
        let priorRequestID = nextRequestID(prefix: "compact-prior")
        let providerRequestID = "compact-\(turnID)"
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.tasks[turnID] = nil
                self.cancellations[turnID] = nil
                self.threadIDs[turnID] = nil
                self.selectionGenerations[turnID] = nil
            }
            do {
                let prior = try self.sessionStore.priorInputItems(
                    id: priorRequestID,
                    params: CodexPriorInputItemsParams(
                        threadID: threadID,
                        beforeTurnID: .value(turnID)
                    )
                )
                let request = CodexPersistedTurnProviderRequest(
                    requestID: providerRequestID,
                    roundIndex: 0,
                    threadID: threadID,
                    turnID: turnID,
                    startParams: promptParams,
                    frozenPriorInputItems: prior.items,
                    currentTurnInputItems: [],
                    steeringInput: []
                )
                let stream = await provider.stream(
                    request,
                    cancellation: cancellation
                )
                var summary = ""
                var responseID: String?
                var usage: CodexTokenUsageBreakdown?
                var completed = false
                for try await event in stream {
                    try cancellation.checkCancellation()
                    switch event {
                    case let .assistantTextDelta(
                        _, requestID, delta
                    ):
                        guard requestID == providerRequestID else {
                            throw CodexDesktopTurnSessionRunnerError
                                .providerRequestMismatch
                        }
                        summary += delta
                    case let .responseItemDone(
                        _, requestID, itemJSON
                    ):
                        guard requestID == providerRequestID else {
                            throw CodexDesktopTurnSessionRunnerError
                                .providerRequestMismatch
                        }
                        if summary.isEmpty {
                            summary = Self.assistantText(
                                from: itemJSON
                            ) ?? ""
                        }
                    case let .planDelta(_, requestID, _, _):
                        guard requestID == providerRequestID else {
                            throw CodexDesktopTurnSessionRunnerError
                                .providerRequestMismatch
                        }
                    case let .planStarted(_, requestID, _),
                      let .planCompleted(_, requestID, _, _):
                        guard requestID == providerRequestID else {
                            throw CodexDesktopTurnSessionRunnerError
                                .providerRequestMismatch
                        }
                    case let .responseCompleted(
                        _, requestID, completedResponseID,
                        completedUsage, endTurn
                    ):
                        guard requestID == providerRequestID,
                              endTurn != false,
                              !completed
                        else {
                            throw CodexDesktopTurnSessionRunnerError
                                .invalidCompactionResponse
                        }
                        responseID = completedResponseID
                        usage = completedUsage
                        completed = true
                    case .toolCallRequested:
                        throw CodexDesktopTurnSessionRunnerError
                            .compactionRequestedTool
                    case let .realtime(_, requestID, _, _):
                        guard requestID == providerRequestID else {
                            throw CodexDesktopTurnSessionRunnerError
                                .providerRequestMismatch
                        }
                    case let .responseStarted(_, requestID, _):
                        guard requestID == providerRequestID else {
                            throw CodexDesktopTurnSessionRunnerError
                                .providerRequestMismatch
                        }
                    }
                }
                let trimmed = summary.trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
                guard completed,
                      let responseID,
                      !trimmed.isEmpty
                else {
                    throw CodexDesktopTurnSessionRunnerError
                        .invalidCompactionResponse
                }
                let replacement = try Self.compactedHistory(
                    prior.items,
                    summary: trimmed
                )
                try self.sessionStore.commitCompaction(
                    CodexCompactHistoryCommit(
                        threadID: threadID,
                        turnID: turnID,
                        itemID: started.itemID,
                        replacementItems: replacement,
                        responseID: responseID,
                        usage: usage
                    )
                )
                let completedAt = Self.now()
                self.emit(
                    .itemCompleted(
                        CodexItemCompletedNotification(
                            item: item,
                            threadID: threadID,
                            turnID: turnID,
                            completedAtMs: completedAt
                        )
                    ),
                    selectionGeneration: selectionGeneration
                )
                self.emit(
                    .turnCompleted(
                        CodexTurnCompletedNotification(
                            threadID: threadID,
                            turn: CodexStoredTurn(
                                id: turnID,
                                items: [item],
                                status: .completed,
                                startedAt: startedAt,
                                completedAt: completedAt,
                                durationMs: completedAt - startedAt
                            )
                        )
                    ),
                    selectionGeneration: selectionGeneration
                )
            } catch {
                try? self.cancelCompaction(turnID: turnID)
                self.emitCompactionFailure(
                    error,
                    threadID: threadID,
                    turnID: turnID,
                    item: item,
                    startedAt: startedAt,
                    selectionGeneration: selectionGeneration
                )
            }
        }
        tasks[turnID] = task
    }

    public func interrupt(turnID: String) {
        cancellations[turnID]?.cancel()
        tasks[turnID]?.cancel()
    }

    /// Returns only turns that still own both an executing task and a live
    /// cancellation token. Ordering is stable so renderer refreshes do not
    /// reorder otherwise unchanged interactive sessions.
    public func activeTurnSnapshots() -> [ActiveTurnSnapshot] {
        threadIDs.compactMap { turnID, threadID in
            guard
                tasks[turnID] != nil,
                let cancellation = cancellations[turnID],
                !cancellation.isCancelled
            else {
                return nil
            }
            return ActiveTurnSnapshot(
                turnID: turnID,
                threadID: threadID
            )
        }
        .sorted {
            if $0.threadID.rawValue == $1.threadID.rawValue {
                return $0.turnID < $1.turnID
            }
            return $0.threadID.rawValue < $1.threadID.rawValue
        }
    }

    /// Interrupts every active turn for a released desktop thread. The
    /// operation is intentionally idempotent, matching `thread/stop`.
    @discardableResult
    public func interruptDesktopTurns(
        threadID: CodexStoredThreadID
    ) -> [String] {
        let turnIDs = activeTurnSnapshots()
            .filter { $0.threadID == threadID }
            .map(\.turnID)
        for turnID in turnIDs {
            interrupt(turnID: turnID)
        }
        return turnIDs
    }

    public func emitMCPToolProgress(
        _ progress: CodexMCPToolProgress
    ) {
        guard
            threadIDs[progress.turnID] == progress.threadID,
            let selectionGeneration =
                selectionGenerations[progress.turnID],
            let cancellation = cancellations[progress.turnID],
            !cancellation.isCancelled
        else {
            return
        }
        emit(
            .mcpToolCallProgress(
                CodexMCPToolCallProgressNotification(
                    threadID: progress.threadID,
                    turnID: progress.turnID,
                    itemID: progress.itemID,
                    message: progress.message
                )
            ),
            selectionGeneration: selectionGeneration
        )
    }

    public func interruptDesktopTurn(
        threadID: CodexStoredThreadID,
        turnID: String
    ) throws {
        if let activeThreadID = threadIDs[turnID],
           cancellations[turnID] != nil
        {
            guard activeThreadID == threadID else {
                throw CodexDesktopTurnSessionRunnerError.threadMismatch
            }
            interrupt(turnID: turnID)
            return
        }

        guard let resolvedTurnID = UUID(uuidString: turnID),
              let resolvedThreadID = UUID(uuidString: threadID.rawValue),
              let persistedTurn = sessionStore.state.turns.first(where: {
                  $0.id == resolvedTurnID
              }),
              persistedTurn.threadID == resolvedThreadID,
              persistedTurn.status == .running
        else {
            throw CodexDesktopTurnSessionRunnerError.turnNotActive
        }

        let timestamp = Self.now()
        try sessionStore.cancelTurn(
            id: resolvedTurnID,
            timestamp: timestamp
        )
        let terminalIdle = sessionStore.takeTerminalIdleNotifications(
            for: threadID
        )
        if !terminalIdle.isEmpty {
            appServerNotificationSink(terminalIdle)
        }
        var projector = CodexDesktopTurnNotificationProjector(
            threadID: threadID,
            turnID: turnID,
            startedAtMs: timestamp
        )
        emit(
            projector.interrupted(),
            selectionGeneration:
                sessionStore.resumedTurnState.selectionGeneration
        )
    }

    public func steerDesktopTurn(
        params: CodexTurnSteerParams
    ) throws -> CodexTurnSteerResult {
        let turnID = params.expectedTurnID
        guard let activeThreadID = threadIDs[turnID],
              cancellations[turnID] != nil,
              tasks[turnID] != nil
        else {
            throw CodexDesktopTurnSessionRunnerError.turnNotActive
        }
        guard activeThreadID == params.threadID else {
            throw CodexDesktopTurnSessionRunnerError.threadMismatch
        }
        steeringInputs[turnID, default: []].append(
            contentsOf: params.input
        )
        let message = CodexStoredThreadItem.userMessage(
            id: UUID().uuidString.lowercased(),
            clientID: {
                if case let .value(value) =
                    params.clientUserMessageID
                {
                    return value
                }
                return nil
            }(),
            content: params.input
        )
        let timestamp = Self.now()
        let selectionGeneration =
            selectionGenerations[turnID]
                ?? sessionStore.resumedTurnState.selectionGeneration
        emit(
            .itemStarted(
                CodexItemStartedNotification(
                    item: message,
                    threadID: params.threadID,
                    turnID: turnID,
                    startedAtMs: timestamp
                )
            ),
            selectionGeneration: selectionGeneration
        )
        emit(
            .itemCompleted(
                CodexItemCompletedNotification(
                    item: message,
                    threadID: params.threadID,
                    turnID: turnID,
                    completedAtMs: timestamp
                )
            ),
            selectionGeneration: selectionGeneration
        )
        return CodexTurnSteerResult(turnID: turnID)
    }

    public func waitForTurn(_ turnID: String) async {
        await tasks[turnID]?.value
    }

    private func emit(
        _ notification: CodexAppServerTurnNotification,
        selectionGeneration: UInt64
    ) {
        sessionStore.receiveTurnNotification(
            notification,
            selectionGeneration: selectionGeneration
        )
        notificationSink(notification)
    }

    private func persistStableTurnFailure(
        _ error: any Error,
        threadID: CodexStoredThreadID,
        turnID: String
    ) {
        do {
            try sessionStore.failStableTurn(
                turnID: turnID,
                threadID: threadID,
                message: String(describing: error),
                timestamp: Self.now()
            )
            let terminalIdle = sessionStore.takeTerminalIdleNotifications(
                for: threadID
            )
            if !terminalIdle.isEmpty {
                appServerNotificationSink(terminalIdle)
            }
        } catch {
            Self.recordProviderDiagnostic(
                "turn-provider failed to persist terminal state"
                    + " turn=\(turnID)"
                    + " type=\(String(describing: type(of: error)))"
            )
        }
    }

    private func persistStableTurnCancellationIfRunning(
        threadID: CodexStoredThreadID,
        turnID: String
    ) {
        guard let id = UUID(uuidString: turnID),
              sessionStore.state.turns.first(where: { $0.id == id })?.status
                == .running
        else {
            return
        }

        do {
            try sessionStore.cancelTurn(
                id: id,
                timestamp: Self.now()
            )
            let terminalIdle = sessionStore.takeTerminalIdleNotifications(
                for: threadID
            )
            if !terminalIdle.isEmpty {
                appServerNotificationSink(terminalIdle)
            }
        } catch {
            Self.recordProviderDiagnostic(
                "turn-provider failed to persist cancellation"
                    + " turn=\(turnID)"
                    + " type=\(String(describing: type(of: error)))"
            )
        }
    }

    private func nextRequestID(
        prefix: String
    ) -> CodexAppServerRequestID {
        requestSequence &+= 1
        return .string("\(prefix)-\(requestSequence)")
    }

    private static func recordProviderDiagnostic(_ value: String) {
        UserDefaults.standard.set(
            value,
            forKey: "codex.desktop.last-turn-provider-diagnostic"
        )
    }

    private static func providerEventKind(
        _ event: CodexCoreProviderEvent
    ) -> String {
        switch event {
        case .responseStarted:
            "responseStarted"
        case .assistantTextDelta:
            "assistantTextDelta"
        case .planStarted:
            "planStarted"
        case .planDelta:
            "planDelta"
        case .planCompleted:
            "planCompleted"
        case .toolCallRequested:
            "toolCallRequested"
        case .responseItemDone:
            "responseItemDone"
        case let .realtime(_, _, eventType, _):
            "realtime:\(eventType)"
        case .responseCompleted:
            "responseCompleted"
        }
    }

    private func cancelCompaction(turnID: String) throws {
        guard let id = UUID(uuidString: turnID) else {
            throw CodexDesktopTurnSessionRunnerError
                .invalidCompactionResponse
        }
        try sessionStore.cancelTurn(
            id: id,
            timestamp: Self.now()
        )
    }

    private func emitCompactionFailure(
        _ error: Error,
        threadID: CodexStoredThreadID,
        turnID: String,
        item: CodexStoredThreadItem,
        startedAt: Int64,
        selectionGeneration: UInt64
    ) {
        let turnError = CodexStoredTurnError(
            message: String(describing: error)
        )
        emit(
            .error(
                CodexTurnErrorNotification(
                    error: turnError,
                    willRetry: false,
                    threadID: threadID,
                    turnID: turnID
                )
            ),
            selectionGeneration: selectionGeneration
        )
        emit(
            .turnCompleted(
                CodexTurnCompletedNotification(
                    threadID: threadID,
                    turn: CodexStoredTurn(
                        id: turnID,
                        items: [item],
                        status: .failed,
                        error: turnError,
                        startedAt: startedAt,
                        completedAt: Self.now()
                    )
                )
            ),
            selectionGeneration: selectionGeneration
        )
    }

    private static func compactedHistory(
        _ priorItems: [String],
        summary: String
    ) throws -> [String] {
        var retained: [(String, Int)] = []
        for raw in priorItems.reversed() {
            guard let data = raw.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(
                      with: data
                  ) as? [String: Any],
                  object["type"] as? String == "message",
                  object["role"] as? String == "user",
                  !raw.contains(summaryPrefix)
            else {
                continue
            }
            retained.append((raw, raw.utf8.count))
            if retained.reduce(0, { $0 + $1.1 }) >= 80_000 {
                break
            }
        }
        let summaryObject: [String: Any] = [
            "type": "message",
            "role": "user",
            "content": [[
                "type": "input_text",
                "text": "\(summaryPrefix)\n\(summary)",
            ]],
        ]
        let summaryData = try JSONSerialization.data(
            withJSONObject: summaryObject,
            options: [.sortedKeys]
        )
        guard let summaryJSON = String(
            data: summaryData,
            encoding: .utf8
        ) else {
            throw CodexDesktopTurnSessionRunnerError
                .invalidCompactionResponse
        }
        return retained.reversed().map(\.0) + [summaryJSON]
    }

    private static func assistantText(
        from itemJSON: String
    ) -> String? {
        guard let data = itemJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(
                  with: data
              ) as? [String: Any],
              object["role"] as? String == "assistant",
              let content = object["content"] as? [[String: Any]]
        else {
            return nil
        }
        return content.compactMap { $0["text"] as? String }
            .joined()
    }

    private static func planText(
        _ update: CodexUpdatePlan
    ) -> String {
        let steps = update.plan.map { item in
            let marker: String
            switch item.status {
            case .pending:
                marker = "[ ]"
            case .inProgress:
                marker = "[>]"
            case .completed:
                marker = "[x]"
            }
            return "\(marker) \(item.step)"
        }
        let explanation = update.explanation?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let nonemptyExplanation =
            explanation?.isEmpty == false ? explanation : nil
        return (
            [nonemptyExplanation]
                .compactMap { $0 }
                + steps
        )
        .joined(separator: "\n")
    }

    private static func withPlanItems(
        _ notifications: [CodexAppServerTurnNotification],
        planItems: [CodexStoredThreadItem]
    ) -> [CodexAppServerTurnNotification] {
        notifications.map {
            withPlanItems($0, planItems: planItems)
        }
    }

    private static func withPlanItems(
        _ notification: CodexAppServerTurnNotification,
        planItems: [CodexStoredThreadItem]
    ) -> CodexAppServerTurnNotification {
        guard !planItems.isEmpty else {
            return notification
        }
        guard case let .turnCompleted(payload) = notification else {
            return notification
        }
        let turn = payload.turn
        let completedTurn = CodexStoredTurn(
            id: turn.id,
            items: planItems + turn.items,
            itemsView: turn.itemsView,
            status: turn.status,
            error: turn.error,
            startedAt: turn.startedAt,
            completedAt: turn.completedAt,
            durationMs: turn.durationMs
        )
        return .turnCompleted(
            CodexTurnCompletedNotification(
                threadID: payload.threadID,
                turn: completedTurn
            )
        )
    }

    private func requestApproval(
        _ activity: CodexPersistedTurnWorkspaceToolActivity,
        threadID: CodexStoredThreadID
    ) async -> Bool {
        beginWaiting(.approval, threadID: threadID)
        defer {
            endWaiting(.approval, threadID: threadID)
        }
        return await approvalRequester(activity)
    }

    private func requestUserInput(
        _ prompt: CodexRequestUserInputPrompt,
        threadID: CodexStoredThreadID
    ) async throws -> CodexRequestUserInputAnswers {
        beginWaiting(.userInput, threadID: threadID)
        defer {
            endWaiting(.userInput, threadID: threadID)
        }
        return try await requestUserInputRequester(prompt)
    }

    private func beginWaiting(
        _ kind: WaitingKind,
        threadID: CodexStoredThreadID
    ) {
        let before = activeFlags(for: threadID)
        var counts = waitingCounts[threadID] ?? WaitingCounts()
        switch kind {
        case .approval:
            counts.approval += 1
        case .userInput:
            counts.userInput += 1
        }
        waitingCounts[threadID] = counts
        publishWaitingStatusIfChanged(
            before: before,
            threadID: threadID
        )
    }

    private func endWaiting(
        _ kind: WaitingKind,
        threadID: CodexStoredThreadID
    ) {
        let before = activeFlags(for: threadID)
        guard var counts = waitingCounts[threadID] else {
            return
        }
        switch kind {
        case .approval:
            counts.approval = max(0, counts.approval - 1)
        case .userInput:
            counts.userInput = max(0, counts.userInput - 1)
        }
        if counts.approval == 0 && counts.userInput == 0 {
            waitingCounts.removeValue(forKey: threadID)
        } else {
            waitingCounts[threadID] = counts
        }
        publishWaitingStatusIfChanged(
            before: before,
            threadID: threadID
        )
    }

    private func activeFlags(
        for threadID: CodexStoredThreadID
    ) -> [CodexThreadActiveFlag] {
        let counts = waitingCounts[threadID] ?? WaitingCounts()
        var flags: [CodexThreadActiveFlag] = []
        if counts.approval > 0 {
            flags.append(.waitingOnApproval)
        }
        if counts.userInput > 0 {
            flags.append(.waitingOnUserInput)
        }
        return flags
    }

    private func publishWaitingStatusIfChanged(
        before: [CodexThreadActiveFlag],
        threadID: CodexStoredThreadID
    ) {
        let after = activeFlags(for: threadID)
        guard before != after else {
            return
        }
        appServerNotificationSink(
            [
                .threadStatusChanged(
                    CodexThreadStatusChangedNotification(
                        threadID: threadID.rawValue,
                        status: .active(after)
                    )
                ),
            ]
        )
    }

    private struct ResolvedReviewPrompt {
        let hint: String
        let prompt: String
        let detachedPrompt: String
    }

    private static func reviewPrompt(
        for target: CodexReviewTarget
    ) -> ResolvedReviewPrompt {
        let hint: String
        let prompt: String
        switch target {
        case .uncommittedChanges:
            hint = "current changes"
            prompt = """
            Review the current code changes (staged, unstaged, and untracked files) and provide prioritized findings.
            """
        case let .baseBranch(branch):
            hint = "changes against '\(branch)'"
            prompt = """
            Review the code changes against the base branch '\(branch)'. Start by finding the merge diff between the current branch and \(branch)'s upstream e.g. (`git merge-base HEAD "$(git rev-parse --abbrev-ref "\(branch)@{upstream}")"`), then run `git diff` against that SHA to see what changes we would merge into the \(branch) branch. Provide prioritized, actionable findings.
            """
        case let .commit(sha, title):
            let shortSHA = String(sha.prefix(7))
            if let title {
                hint = "commit \(shortSHA): \(title)"
                prompt = """
                Review the code changes introduced by commit \(sha) ("\(title)"). Provide prioritized, actionable findings.
                """
            } else {
                hint = "commit \(shortSHA)"
                prompt = """
                Review the code changes introduced by commit \(sha). Provide prioritized, actionable findings.
                """
            }
        case let .custom(instructions):
            hint = instructions
            prompt = instructions
        }
        return ResolvedReviewPrompt(
            hint: hint,
            prompt: prompt,
            detachedPrompt: """
            Use the review skill for this review.

            \(prompt)
            """
        )
    }

    private static func derivedRequestID(
        _ id: CodexAppServerRequestID,
        suffix: String
    ) -> CodexAppServerRequestID {
        switch id {
        case let .string(value):
            .string("\(value)-\(suffix)")
        case let .integer(value):
            .string("\(value)-\(suffix)")
        }
    }

    private static let compactionPrompt = """
    You are performing a CONTEXT CHECKPOINT COMPACTION. Create a handoff summary for another LLM that will resume the task.

    Include:
    - Current progress and key decisions made
    - Important context, constraints, or user preferences
    - What remains to be done (clear next steps)
    - Any critical data, examples, or references needed to continue

    Be concise, structured, and focused on helping the next LLM seamlessly continue the work.
    """

    private static let summaryPrefix = "Another language model started to solve this problem and produced a summary of its thinking process. You also have access to the state of the tools that were used by that language model. Use this to build on the work that has already been done and avoid duplicating work. Here is the summary produced by the other language model, use the information in this summary to assist with your own analysis:"

    private static func now() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }

    static func displayedProviderError(
        original: Error,
        transportPayload: CodexJSONValue?
    ) -> Error {
        if original is CodexOfficialProviderFirstEventTimeoutError {
            return CodexDesktopTurnDisplayedError(
                message:
                    "The provider request timed out before a response was "
                    + "received. Check the network connection and try again."
            )
        }
        if original is CodexOfficialProviderActivityTimeoutError {
            return CodexDesktopTurnDisplayedError(
                message:
                    "The provider request timed out before a response was "
                    + "received. Check the network connection and try again."
            )
        }
        guard let transportPayload else {
            return original
        }
        let diagnostic = providerTransportDiagnosticText(
            transportPayload
        )
        if diagnostic.contains("401") {
            return CodexDesktopTurnDisplayedError(
                message:
                    "Your saved sign-in credential was rejected (HTTP 401). "
                    + "Open Settings and sign in again."
            )
        }
        if diagnostic.contains("400") {
            return CodexDesktopTurnDisplayedError(
                message:
                    "The provider rejected the request (HTTP 400). "
                    + "Check the selected model and account configuration."
            )
        }
        if diagnostic.contains("403") {
            return CodexDesktopTurnDisplayedError(
                message:
                    "This account is not permitted to send the request "
                    + "(HTTP 403). Check account access and sign in again."
            )
        }
        if diagnostic.contains("429") {
            return CodexDesktopTurnDisplayedError(
                message:
                    "The account rate limit was reached (HTTP 429). "
                    + "Try again after the limit resets."
            )
        }
        return original
    }

    private static func providerTransportDiagnosticText(
        _ value: CodexJSONValue
    ) -> String {
        switch value {
        case .null:
            return ""
        case let .bool(value):
            return String(value)
        case let .integer(value):
            return String(value)
        case let .number(value):
            return String(value)
        case let .string(value):
            return value
        case let .array(values):
            return values.map(providerTransportDiagnosticText)
                .joined(separator: " ")
        case let .object(values):
            return values.sorted { $0.key < $1.key }
                .map {
                    $0.key + " "
                        + providerTransportDiagnosticText($0.value)
                }
                .joined(separator: " ")
        }
    }
}

private struct CodexDesktopTurnDisplayedError:
    Error,
    CustomStringConvertible,
    Sendable
{
    let message: String

    var description: String {
        message
    }
}

public enum CodexDesktopTurnSessionRunnerError:
    Error,
    Equatable,
    Sendable
{
    case providerUnavailable
    case turnNotActive
    case threadMismatch
    case providerRequestMismatch
    case invalidCompactionResponse
    case compactionRequestedTool
    case elicitationCountAlreadyZero
    case elicitationCountOverflow
}
