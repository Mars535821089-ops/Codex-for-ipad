import CodexPadApplication
import CodexPadDomain
import CodexPadProtocolBridge
import Foundation
import Testing

private enum StableTurnTestTransportError: Error {
    case missingReply
}

@MainActor
private final class StableTurnTestTransport: CodexCoreTransport {
    private(set) var submitted: [CodexCoreCommand] = []
    private(set) var threadRequests: [CodexAppServerThreadRequest] = []
    private(set) var turnRequests: [CodexAppServerTurnRequest] = []
    var turnReplies: [Data] = []

    func submit(_ command: CodexCoreCommand) throws {
        submitted.append(command)
    }

    func request(_ request: CodexAppServerThreadRequest) throws -> Data {
        threadRequests.append(request)
        throw StableTurnTestTransportError.missingReply
    }

    func request(_ request: CodexAppServerTurnRequest) throws -> Data {
        turnRequests.append(request)
        guard !turnReplies.isEmpty else {
            throw StableTurnTestTransportError.missingReply
        }
        return turnReplies.removeFirst()
    }

    func nextEvent() throws -> CodexCoreEvent? {
        nil
    }
}

@MainActor
@Test
func desktopTurnStartSelectsExactThreadAndUsesStableTransport() throws {
    let rawThreadID = CodexStoredThreadID("Thread/Desktop/Raw")
    let requestID = CodexAppServerRequestID.string("desktop-turn-1")
    let params = CodexTurnStartParams(
        threadID: rawThreadID,
        input: [.text(text: "Build it", textElements: [])]
    )
    let transport = StableTurnTestTransport()
    let store = CodexSessionStore(transport: transport)
    let result = CodexTurnStartResult(
        turn: initialServerTurn(id: "server-desktop-1")
    )
    transport.turnReplies.append(
        try encodedTurnReply(id: requestID, result: result)
    )

    let returned = try store.startDesktopTurn(
        id: requestID,
        params: params
    )

    #expect(returned == result)
    #expect(
        transport.turnRequests
            == [.start(id: requestID, params: params)]
    )
    #expect(
        store.resumedTurnState.exactRawThreadID?.rawValue
            == "Thread/Desktop/Raw"
    )
    #expect(store.resumedTurnState.phase == .inProgress)
}

@MainActor
@Test
func desktopTurnStartDropsLegacySandboxWhenPermissionsProfileIsPresent() throws {
    let requestID = CodexAppServerRequestID.string("desktop-turn-legacy-profile")
    let rawThreadID = CodexStoredThreadID("Thread/Desktop/LegacyProfile")
    let params = CodexTurnStartParams(
        threadID: rawThreadID,
        input: [.text(text: "Build it", textElements: [])],
        sandboxPolicy: .value(
            .workspaceWrite(
                writableRoots: ["/workspace"],
                networkAccess: true,
                excludeTmpdirEnvVar: false,
                excludeSlashTmp: false
            )
        ),
        permissions: .value(":workspace")
    )
    let transport = StableTurnTestTransport()
    let store = CodexSessionStore(transport: transport)
    let result = CodexTurnStartResult(
        turn: initialServerTurn(id: "server-desktop-legacy-profile")
    )
    transport.turnReplies.append(
        try encodedTurnReply(id: requestID, result: result)
    )

    _ = try store.startDesktopTurn(id: requestID, params: params)

    guard case let .start(_, normalized)? = transport.turnRequests.last else {
        Issue.record("expected a turn/start request")
        return
    }
    #expect(normalized.permissions == .value(":workspace"))
    #expect(normalized.sandboxPolicy == .omitted)
}

@MainActor
@Test
func stableTurnStartPreservesRawThreadAndExactRequestID() throws {
    let rawThreadID = CodexStoredThreadID(" 任务/thread-Ω/../原样 ")
    let stringID = CodexAppServerRequestID.string("turn-start/原样")
    let integerID = CodexAppServerRequestID.integer(9_007)
    let transport = StableTurnTestTransport()
    let store = CodexSessionStore(transport: transport)

    for requestID in [stringID, integerID] {
        store.selectResumedTurnThread(rawThreadID)
        let params = CodexTurnStartParams(
            threadID: rawThreadID,
            input: [
                .text(text: "continue", textElements: [])
            ]
        )
        let result = CodexTurnStartResult(
            turn: initialServerTurn(id: "server-\(requestID)")
        )
        transport.turnReplies.append(
            try encodedTurnReply(id: requestID, result: result)
        )

        let returned = try store.startStableTurn(
            id: requestID,
            params: params
        )

        #expect(returned == result)
        #expect(
            transport.turnRequests.last
                == .start(id: requestID, params: params)
        )
        #expect(
            store.resumedTurnState.exactRawThreadID?.rawValue
                == " 任务/thread-Ω/../原样 "
        )
        #expect(store.resumedTurnState.requestID == requestID)
        #expect(store.resumedTurnState.phase == .inProgress)
        #expect(
            store.resumedTurnState.serverTurnID
                == result.turn.id
        )
    }
}

@MainActor
@Test
func stableTurnStartRejectsNonInitialServerTurns() throws {
    let rawThreadID = CodexStoredThreadID("thread/raw")
    let transport = StableTurnTestTransport()
    let store = CodexSessionStore(transport: transport)
    let invalidTurns = [
        CodexStoredTurn(
            id: "completed",
            items: [],
            itemsView: .notLoaded,
            status: .completed
        ),
        CodexStoredTurn(
            id: "loaded",
            items: [],
            itemsView: .full,
            status: .inProgress
        ),
        CodexStoredTurn(
            id: "has-item",
            items: [agentMessage(id: "unexpected", text: "already here")],
            itemsView: .notLoaded,
            status: .inProgress
        ),
    ]

    for (index, invalidTurn) in invalidTurns.enumerated() {
        store.selectResumedTurnThread(rawThreadID)
        let requestID = CodexAppServerRequestID.integer(Int64(index))
        transport.turnReplies.append(
            try encodedTurnReply(
                id: requestID,
                result: CodexTurnStartResult(turn: invalidTurn)
            )
        )

        #expect(throws: CodexSessionStoreError.invalidReply) {
            try store.startStableTurn(
                id: requestID,
                params: CodexTurnStartParams(
                    threadID: rawThreadID,
                    input: []
                )
            )
        }
        #expect(store.resumedTurnState.phase == .failed)
        #expect(store.resumedTurnState.error == .invalidInitialTurn)
    }
}

@MainActor
@Test
func stableTurnStartRejectsAResponseIDOfAnotherWireType() throws {
    let rawThreadID = CodexStoredThreadID("thread/id-mismatch")
    let transport = StableTurnTestTransport()
    let store = CodexSessionStore(transport: transport)
    store.selectResumedTurnThread(rawThreadID)
    transport.turnReplies.append(
        try encodedTurnReply(
            id: .string("17"),
            result: CodexTurnStartResult(
                turn: initialServerTurn(id: "turn-id-mismatch")
            )
        )
    )

    #expect(
        throws: CodexSessionStoreError.replyIDMismatch(
            expected: .integer(17),
            actual: .string("17")
        )
    ) {
        try store.startStableTurn(
            id: .integer(17),
            params: CodexTurnStartParams(
                threadID: rawThreadID,
                input: []
            )
        )
    }
}

@Test
func stableTurnBuffersEarlyNotificationsAndReconcilesCanonicalItems() throws {
    let rawThreadID = CodexStoredThreadID("thread/early-events")
    var state = CodexResumedTurnViewState()
    state.selectThread(rawThreadID)
    let possibleRequest = state.beginStart(
        id: .string("request-early"),
        params: CodexTurnStartParams(
            threadID: rawThreadID,
            input: []
        )
    )
    let request = try #require(possibleRequest)
    let generation = state.selectionGeneration
    let provisional = agentMessage(id: "item-1", text: "")
    let canonical = agentMessage(
        id: "item-1",
        text: "canonical server text"
    )
    let usage = tokenUsage(total: 21, last: 8)

    state.receive(
        .turnStarted(
            .init(
                threadID: rawThreadID,
                turn: initialServerTurn(id: "turn-early")
            )
        ),
        selectionGeneration: generation
    )
    state.receive(
        .itemStarted(
            .init(
                item: provisional,
                threadID: rawThreadID,
                turnID: "turn-early",
                startedAtMs: 10
            )
        ),
        selectionGeneration: generation
    )
    state.receive(
        .agentMessageDelta(
            .init(
                threadID: rawThreadID,
                turnID: "turn-early",
                itemID: "item-1",
                delta: "Hel"
            )
        ),
        selectionGeneration: generation
    )

    #expect(state.phase == .starting)
    #expect(state.pendingNotifications.count == 3)
    #expect(state.itemsByID.isEmpty)

    state.receiveStartResult(
        CodexTurnStartResult(
            turn: initialServerTurn(id: "turn-early")
        ),
        for: request
    )
    state.receive(
        .agentMessageDelta(
            .init(
                threadID: rawThreadID,
                turnID: "turn-early",
                itemID: "item-1",
                delta: "lo"
            )
        ),
        selectionGeneration: generation
    )
    state.receive(
        .itemCompleted(
            .init(
                item: canonical,
                threadID: rawThreadID,
                turnID: "turn-early",
                completedAtMs: 20
            )
        ),
        selectionGeneration: generation
    )
    state.receive(
        .threadTokenUsageUpdated(
            .init(
                threadID: rawThreadID,
                turnID: "turn-early",
                tokenUsage: usage
            )
        ),
        selectionGeneration: generation
    )
    state.receive(
        .turnCompleted(
            .init(
                threadID: rawThreadID,
                turn: CodexStoredTurn(
                    id: "turn-early",
                    items: [canonical],
                    itemsView: .full,
                    status: .completed
                )
            )
        ),
        selectionGeneration: generation
    )

    #expect(state.phase == .completed)
    #expect(state.pendingNotifications.isEmpty)
    #expect(state.orderedItemIDs == ["item-1"])
    #expect(state.itemsByID == ["item-1": canonical])
    #expect(state.deltasByItemID == ["item-1": "Hello"])
    #expect(state.tokenUsage == usage)
    #expect(state.error == nil)
    #expect(state.reconciliationNeeded)
}

@Test
func stableTurnBuffersProposedPlanDeltasAndKeepsCompletedPlanAuthoritative()
    throws
{
    let threadID = CodexStoredThreadID("thread/proposed-plan")
    let turnID = "turn/proposed-plan"
    let itemID = "\(turnID)-plan"
    let provisional = CodexStoredThreadItem.plan(id: itemID, text: "")
    let canonical = CodexStoredThreadItem.plan(
        id: itemID,
        text: "Authoritative completed plan"
    )
    var state = CodexResumedTurnViewState()
    state.selectThread(threadID)
    let possibleRequest = state.beginStart(
        id: .string("request-proposed-plan"),
        params: CodexTurnStartParams(threadID: threadID, input: [])
    )
    let request = try #require(possibleRequest)
    state.receiveStartResult(
        CodexTurnStartResult(turn: initialServerTurn(id: turnID)),
        for: request
    )
    let generation = state.selectionGeneration

    state.receive(
        .itemStarted(
            .init(
                item: provisional,
                threadID: threadID,
                turnID: turnID,
                startedAtMs: 10
            )
        ),
        selectionGeneration: generation
    )
    for delta in ["- inspect\n", "- implement\n"] {
        state.receive(
            .planDelta(
                .init(
                    threadID: threadID,
                    turnID: turnID,
                    itemID: itemID,
                    delta: delta
                )
            ),
            selectionGeneration: generation
        )
    }
    state.receive(
        .itemCompleted(
            .init(
                item: canonical,
                threadID: threadID,
                turnID: turnID,
                completedAtMs: 20
            )
        ),
        selectionGeneration: generation
    )
    state.receive(
        .turnCompleted(
            .init(
                threadID: threadID,
                turn: CodexStoredTurn(
                    id: turnID,
                    items: [canonical],
                    itemsView: .full,
                    status: .completed
                )
            )
        ),
        selectionGeneration: generation
    )

    #expect(
        state.planDeltasByItemID
            == [itemID: "- inspect\n- implement\n"]
    )
    #expect(state.itemsByID[itemID] == canonical)
    #expect(state.phase == .completed)

    state.selectThread(CodexStoredThreadID("thread/after-plan"))
    #expect(state.planDeltasByItemID.isEmpty)
}

@Test
func stableTurnReplacesLatestDiffWithMatchingSnapshot() throws {
    let rawThreadID = CodexStoredThreadID("thread/diff")
    var state = CodexResumedTurnViewState()
    state.selectThread(rawThreadID)
    let possibleRequest = state.beginStart(
        id: .string("request-diff"),
        params: CodexTurnStartParams(
            threadID: rawThreadID,
            input: []
        )
    )
    let request = try #require(possibleRequest)
    state.receiveStartResult(
        CodexTurnStartResult(
            turn: initialServerTurn(id: "turn-diff")
        ),
        for: request
    )

    state.receive(
        .turnDiffUpdated(
            .init(
                threadID: rawThreadID,
                turnID: "turn-diff",
                diff: "-old\n+first\n"
            )
        ),
        selectionGeneration: state.selectionGeneration
    )
    #expect(state.latestDiff == "-old\n+first\n")

    state.receive(
        .turnDiffUpdated(
            .init(
                threadID: rawThreadID,
                turnID: "turn-diff",
                diff: "-old\n+second complete snapshot\n"
            )
        ),
        selectionGeneration: state.selectionGeneration
    )

    #expect(state.latestDiff == "-old\n+second complete snapshot\n")
    #expect(state.phase == .inProgress)
    #expect(state.error == nil)
}

@Test
func stableTurnIgnoresDiffSnapshotsForAnotherThreadOrTurn() throws {
    let rawThreadID = CodexStoredThreadID("thread/current-diff")
    var state = CodexResumedTurnViewState()
    state.selectThread(rawThreadID)
    let possibleRequest = state.beginStart(
        id: .string("request-current-diff"),
        params: CodexTurnStartParams(
            threadID: rawThreadID,
            input: []
        )
    )
    let request = try #require(possibleRequest)
    state.receiveStartResult(
        CodexTurnStartResult(
            turn: initialServerTurn(id: "turn-current-diff")
        ),
        for: request
    )
    state.receive(
        .turnDiffUpdated(
            .init(
                threadID: rawThreadID,
                turnID: "turn-current-diff",
                diff: "current snapshot"
            )
        ),
        selectionGeneration: state.selectionGeneration
    )
    let beforeMismatch = state

    state.receive(
        .turnDiffUpdated(
            .init(
                threadID: CodexStoredThreadID("thread/other-diff"),
                turnID: "turn-current-diff",
                diff: "wrong thread snapshot"
            )
        ),
        selectionGeneration: state.selectionGeneration
    )
    #expect(state == beforeMismatch)

    state.receive(
        .turnDiffUpdated(
            .init(
                threadID: rawThreadID,
                turnID: "turn-other-diff",
                diff: "wrong turn snapshot"
            )
        ),
        selectionGeneration: state.selectionGeneration
    )
    #expect(state == beforeMismatch)
}

@Test
func stableTurnSelectionClearsPriorLatestDiff() throws {
    let firstThreadID = CodexStoredThreadID("thread/first-diff")
    var state = CodexResumedTurnViewState()
    state.selectThread(firstThreadID)
    let possibleRequest = state.beginStart(
        id: .integer(91),
        params: CodexTurnStartParams(
            threadID: firstThreadID,
            input: []
        )
    )
    let request = try #require(possibleRequest)
    state.receiveStartResult(
        CodexTurnStartResult(
            turn: initialServerTurn(id: "turn-first-diff")
        ),
        for: request
    )
    state.receive(
        .turnDiffUpdated(
            .init(
                threadID: firstThreadID,
                turnID: "turn-first-diff",
                diff: "first thread snapshot"
            )
        ),
        selectionGeneration: state.selectionGeneration
    )
    #expect(state.latestDiff == "first thread snapshot")

    state.selectThread(CodexStoredThreadID("thread/second-diff"))

    #expect(state.latestDiff == nil)
}

@Test
func stableTurnTreatsBufferedTurnMismatchAsProtocolFailure() throws {
    let rawThreadID = CodexStoredThreadID("thread/mismatch")
    var state = CodexResumedTurnViewState()
    state.selectThread(rawThreadID)
    let possibleRequest = state.beginStart(
        id: .integer(44),
        params: CodexTurnStartParams(
            threadID: rawThreadID,
            input: []
        )
    )
    let request = try #require(possibleRequest)

    state.receive(
        .turnStarted(
            .init(
                threadID: rawThreadID,
                turn: initialServerTurn(id: "notification-turn")
            )
        ),
        selectionGeneration: state.selectionGeneration
    )
    state.receiveStartResult(
        CodexTurnStartResult(
            turn: initialServerTurn(id: "response-turn")
        ),
        for: request
    )

    #expect(state.phase == .failed)
    #expect(
        state.error
            == .turnIDMismatch(
                expected: "response-turn",
                actual: "notification-turn"
            )
    )
    #expect(state.reconciliationNeeded)
}

@Test
func stableTurnValidatesRawResponseNotificationIdentity() throws {
    let rawThreadID = CodexStoredThreadID("thread/raw-response")
    var state = CodexResumedTurnViewState()
    state.selectThread(rawThreadID)
    let possibleRequest = state.beginStart(
        id: .integer(45),
        params: CodexTurnStartParams(
            threadID: rawThreadID,
            input: []
        )
    )
    let request = try #require(possibleRequest)
    state.receiveStartResult(
        CodexTurnStartResult(
            turn: initialServerTurn(id: "expected-turn")
        ),
        for: request
    )

    state.receive(
        .rawResponseCompleted(
            .init(
                threadID: rawThreadID,
                turnID: "different-turn",
                responseID: "response-1",
                usage: nil
            )
        ),
        selectionGeneration: state.selectionGeneration
    )

    #expect(state.phase == .failed)
    #expect(
        state.error
            == .turnIDMismatch(
                expected: "expected-turn",
                actual: "different-turn"
            )
    )
    #expect(state.pendingNotifications.isEmpty)
    #expect(state.reconciliationNeeded)
}

@Test
func stableTurnRetainsThreadScopedHookWithExplicitNullTurnID() throws {
    let rawThreadID = CodexStoredThreadID("thread/hook")
    var state = CodexResumedTurnViewState()
    state.selectThread(rawThreadID)
    let possibleRequest = state.beginStart(
        id: .integer(46),
        params: CodexTurnStartParams(
            threadID: rawThreadID,
            input: []
        )
    )
    let request = try #require(possibleRequest)
    state.receiveStartResult(
        CodexTurnStartResult(
            turn: initialServerTurn(id: "expected-turn")
        ),
        for: request
    )
    let notification = CodexAppServerTurnNotification.hookCompleted(
        .init(
            threadID: rawThreadID,
            turnID: nil,
            run: .object([
                "id": .string("hook-1"),
                "status": .string("completed"),
            ])
        )
    )

    state.receive(
        notification,
        selectionGeneration: state.selectionGeneration
    )

    #expect(state.phase == .inProgress)
    #expect(state.pendingNotifications == [notification])
    #expect(state.error == nil)
}

@Test
func stableTurnSelectionInvalidatesOldResponseAndNotification() throws {
    let firstID = CodexStoredThreadID("thread/first")
    let secondID = CodexStoredThreadID("thread/second")
    var state = CodexResumedTurnViewState()
    state.selectThread(firstID)
    let firstGeneration = state.selectionGeneration
    let possibleRequest = state.beginStart(
        id: .string("old-request"),
        params: CodexTurnStartParams(threadID: firstID, input: [])
    )
    let request = try #require(possibleRequest)

    state.selectThread(secondID)
    state.receiveStartResult(
        CodexTurnStartResult(
            turn: initialServerTurn(id: "old-turn")
        ),
        for: request
    )
    state.receive(
        .turnStarted(
            .init(
                threadID: firstID,
                turn: initialServerTurn(id: "old-turn")
            )
        ),
        selectionGeneration: firstGeneration
    )

    #expect(state.exactRawThreadID == secondID)
    #expect(state.phase == .idle)
    #expect(state.requestID == nil)
    #expect(state.serverTurnID == nil)
    #expect(state.pendingNotifications.isEmpty)
    #expect(state.error == nil)
}

@Test
func stableTurnRetainsOpaqueNotificationWithoutChangingKnownState() throws {
    let rawThreadID = CodexStoredThreadID("thread/opaque")
    var state = CodexResumedTurnViewState()
    state.selectThread(rawThreadID)
    let possibleRequest = state.beginStart(
        id: .integer(8),
        params: CodexTurnStartParams(threadID: rawThreadID, input: [])
    )
    let request = try #require(possibleRequest)
    state.receiveStartResult(
        CodexTurnStartResult(
            turn: initialServerTurn(id: "turn-opaque")
        ),
        for: request
    )
    let before = state
    let opaque = CodexAppServerTurnNotification.opaque(
        method: "future/notification",
        rawEnvelope: .object([
            "method": .string("future/notification")
        ])
    )

    state.receive(
        opaque,
        selectionGeneration: state.selectionGeneration
    )

    #expect(state.phase == before.phase)
    #expect(state.serverTurnID == before.serverTurnID)
    #expect(state.orderedItemIDs == before.orderedItemIDs)
    #expect(state.itemsByID == before.itemsByID)
    #expect(state.deltasByItemID == before.deltasByItemID)
    #expect(state.tokenUsage == before.tokenUsage)
    #expect(state.error == before.error)
    #expect(state.pendingNotifications == [opaque])
}

private func initialServerTurn(id: String) -> CodexStoredTurn {
    CodexStoredTurn(
        id: id,
        items: [],
        itemsView: .notLoaded,
        status: .inProgress
    )
}

private func agentMessage(
    id: String,
    text: String
) -> CodexStoredThreadItem {
    .agentMessage(
        id: id,
        text: text,
        phase: nil,
        memoryCitation: nil
    )
}

private func tokenUsage(
    total: Int64,
    last: Int64
) -> CodexThreadTokenUsage {
    CodexThreadTokenUsage(
        total: .init(
            totalTokens: total,
            inputTokens: total - 1,
            cachedInputTokens: 1,
            outputTokens: 1,
            reasoningOutputTokens: 0
        ),
        last: .init(
            totalTokens: last,
            inputTokens: last - 1,
            cachedInputTokens: 0,
            outputTokens: 1,
            reasoningOutputTokens: 0
        ),
        modelContextWindow: 100_000
    )
}

private func encodedTurnReply(
    id: CodexAppServerRequestID,
    result: CodexTurnStartResult
) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(
        CodexAppServerReply<CodexTurnStartResult>.success(
            .init(id: id, result: result)
        )
    )
}
