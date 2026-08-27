import CodexPadApplication
import CodexPadDomain
import CodexPadProtocolBridge
import Foundation
import Testing

@MainActor
private final class ActivityTurnTransport: CodexCoreTransport {
    private var pendingTurnIDs:
        [CodexStoredThreadID: [String]]
    private var threadIDsByTurnID:
        [UUID: CodexStoredThreadID]
    private var events: [CodexCoreEvent] = []
    private var nextSequence: Int64 = 1
    private let emitsTurnStartedEvents: Bool
    private(set) var submitted: [CodexCoreCommand] = []

    init(
        pendingTurnIDs: [CodexStoredThreadID: [String]],
        emitsTurnStartedEvents: Bool = false
    ) {
        self.pendingTurnIDs = pendingTurnIDs
        self.emitsTurnStartedEvents = emitsTurnStartedEvents
        threadIDsByTurnID = Dictionary(
            uniqueKeysWithValues: pendingTurnIDs.flatMap { threadID, turnIDs in
                turnIDs.compactMap { turnID in
                    UUID(uuidString: turnID).map { ($0, threadID) }
                }
            }
        )
    }

    func submit(_ command: CodexCoreCommand) throws {
        submitted.append(command)
        guard case let .cancelTurn(turnID, _) = command,
              let threadID = threadIDsByTurnID[turnID]
        else {
            return
        }
        events.append(
            .domain(
                DomainEvent(
                    sequence: nextSequence,
                    payload: .turnStatusChanged(
                        turnID: turnID,
                        status: .cancelled
                    )
                )
            )
        )
        nextSequence += 1
        events.append(
            .appServerNotification(terminalIdle(for: threadID))
        )
    }

    var cancelledTurnIDs: [UUID] {
        submitted.compactMap { command in
            guard case let .cancelTurn(turnID, _) = command else {
                return nil
            }
            return turnID
        }
    }

    func terminalIdle(
        for threadID: CodexStoredThreadID
    ) -> CodexAppServerNotification {
        .threadStatusChanged(
            CodexThreadStatusChangedNotification(
                threadID: threadID.rawValue,
                status: .idle
            )
        )
    }

    func request(
        _ request: CodexAppServerThreadRequest
    ) throws -> Data {
        throw CodexCoreTransportError.unsupportedTurnRequest
    }

    func request(
        _ request: CodexAppServerTurnRequest
    ) throws -> Data {
        guard case let .start(id, params) = request,
              var turnIDs = pendingTurnIDs[params.threadID],
              !turnIDs.isEmpty
        else {
            throw CodexCoreTransportError.unsupportedTurnRequest
        }
        let turnID = turnIDs.removeFirst()
        pendingTurnIDs[params.threadID] = turnIDs
        if emitsTurnStartedEvents,
           let turnUUID = UUID(uuidString: turnID),
           let threadUUID = UUID(uuidString: params.threadID.rawValue)
        {
            events.append(
                .domain(
                    DomainEvent(
                        sequence: nextSequence,
                        payload: .turnStarted(
                            Turn(
                                id: turnUUID,
                                threadID: threadUUID,
                                status: .running
                            )
                        )
                    )
                )
            )
            nextSequence += 1
        }
        return try JSONEncoder().encode(
            CodexAppServerReply<CodexTurnStartResult>.success(
                .init(
                    id: id,
                    result: CodexTurnStartResult(
                        turn: CodexStoredTurn(
                            id: turnID,
                            items: [],
                            itemsView: .notLoaded,
                            status: .inProgress
                        )
                    )
                )
            )
        )
    }

    func request(
        _ request: CodexRawHistoryRequest
    ) throws -> Data {
        guard case let .priorInputItems(id, params) = request else {
            throw CodexCoreTransportError
                .unsupportedRawHistoryRequest
        }
        return try JSONEncoder().encode(
            CodexAppServerReply<CodexPriorInputItemsResult>.success(
                .init(
                    id: id,
                    result: CodexPriorInputItemsResult(
                        threadID: params.threadID,
                        throughTurnID: nil,
                        items: [],
                        completeness: .complete
                    )
                )
            )
        )
    }

    func nextEvent() throws -> CodexCoreEvent? {
        guard !events.isEmpty else {
            return nil
        }
        return events.removeFirst()
    }
}

@MainActor
private final class BlockingActivityTurnProvider:
    CodexPersistedTurnProvider
{
    private var cancellations:
        [String: CodexTurnCancellation] = [:]

    func stream(
        _ request: CodexPersistedTurnProviderRequest,
        cancellation: CodexTurnCancellation
    ) async -> AsyncThrowingStream<CodexCoreProviderEvent, Error> {
        cancellations[request.turnID] = cancellation
        return AsyncThrowingStream { _ in }
    }

    func waitUntilStarted(
        _ expectedTurnIDs: Set<String>
    ) async -> Bool {
        for _ in 0..<1_000 {
            if Set(cancellations.keys) == expectedTurnIDs {
                return true
            }
            await Task.yield()
        }
        return false
    }

    func isCancelled(turnID: String) -> Bool? {
        cancellations[turnID]?.isCancelled
    }
}

@Suite
@MainActor
struct CodexDesktopTurnSessionActivityTests {
    @Test
    func stoppingPersistedRunningTurnAfterRelaunchProjectsInterruptedState()
        throws
    {
        let workspaceID = UUID(
            uuidString: "91000000-0000-0000-0000-000000000019"
        )!
        let threadUUID = UUID(
            uuidString: "a1000000-0000-0000-0000-00000000001a"
        )!
        let turnUUID = UUID(
            uuidString: "b1000000-0000-0000-0000-00000000001b"
        )!
        let threadID = CodexStoredThreadID(
            threadUUID.uuidString.lowercased()
        )
        let turnID = turnUUID.uuidString.lowercased()
        let transport = ActivityTurnTransport(
            pendingTurnIDs: [threadID: [turnID]]
        )
        let store = CodexSessionStore(
            state: CodexSessionState(
                workspaces: [
                    Workspace(
                        id: workspaceID,
                        displayName: "Restored activity",
                        rootBookmarkID: nil
                    )
                ],
                threads: [
                    CodexThread(
                        id: threadUUID,
                        workspaceID: workspaceID,
                        title: "Interrupted after relaunch"
                    )
                ],
                turns: [
                    Turn(
                        id: turnUUID,
                        threadID: threadUUID,
                        status: .running
                    )
                ]
            ),
            transport: transport
        )
        var turnNotifications: [CodexAppServerTurnNotification] = []
        var appServerNotifications: [CodexAppServerNotification] = []
        let runner = CodexDesktopTurnSessionRunner(
            sessionStore: store,
            providerFactory: { _ in nil },
            notificationSink: { turnNotifications.append($0) },
            appServerNotificationSink: {
                appServerNotifications.append(contentsOf: $0)
            }
        )

        try runner.interruptDesktopTurn(
            threadID: threadID,
            turnID: turnID
        )

        #expect(runner.activeTurnSnapshots().isEmpty)
        #expect(transport.cancelledTurnIDs == [turnUUID])
        #expect(
            store.state.turns.first(where: { $0.id == turnUUID })?.status
                == .cancelled
        )
        let terminalTurns = turnNotifications.compactMap {
            notification -> CodexStoredTurn? in
            guard case let .turnCompleted(payload) = notification else {
                return nil
            }
            return payload.turn
        }
        #expect(terminalTurns.count == 1)
        #expect(terminalTurns.first?.id == turnID)
        #expect(terminalTurns.first?.status == .interrupted)
        #expect(
            appServerNotifications == [
                transport.terminalIdle(for: threadID)
            ]
        )
    }

    @Test
    func stoppingTurnStartedByCorePersistsCancellationWithoutPreloadedTurn()
        async throws
    {
        let workspaceID = UUID(
            uuidString: "90000000-0000-0000-0000-000000000009"
        )!
        let threadUUID = UUID(
            uuidString: "a0000000-0000-0000-0000-00000000000a"
        )!
        let turnUUID = UUID(
            uuidString: "b0000000-0000-0000-0000-00000000000b"
        )!
        let threadID = CodexStoredThreadID(
            threadUUID.uuidString.lowercased()
        )
        let turnID = turnUUID.uuidString.lowercased()
        let transport = ActivityTurnTransport(
            pendingTurnIDs: [threadID: [turnID]],
            emitsTurnStartedEvents: true
        )
        let store = CodexSessionStore(
            state: CodexSessionState(
                workspaces: [
                    Workspace(
                        id: workspaceID,
                        displayName: "Core-started turn",
                        rootBookmarkID: nil
                    )
                ],
                threads: [
                    CodexThread(
                        id: threadUUID,
                        workspaceID: workspaceID,
                        title: "Projected by Core"
                    )
                ],
                turns: []
            ),
            transport: transport
        )
        let provider = BlockingActivityTurnProvider()
        var appServerNotifications: [CodexAppServerNotification] = []
        let runner = CodexDesktopTurnSessionRunner(
            sessionStore: store,
            providerFactory: { _ in provider },
            notificationSink: { _ in },
            appServerNotificationSink: {
                appServerNotifications.append(contentsOf: $0)
            }
        )

        let started = try runner.startDesktopTurn(
            id: .string("start/core-projected"),
            params: Self.params(
                threadID: threadID,
                text: "Start in Core, then stop"
            )
        )
        #expect(await provider.waitUntilStarted([started.turn.id]))
        #expect(
            store.state.turns == [
                Turn(
                    id: turnUUID,
                    threadID: threadUUID,
                    status: .running
                )
            ]
        )

        #expect(
            runner.interruptDesktopTurns(threadID: threadID) == [turnID]
        )
        await runner.waitForTurn(started.turn.id)

        #expect(transport.cancelledTurnIDs == [turnUUID])
        #expect(
            store.state.turns.first(where: { $0.id == turnUUID })?.status
                == .cancelled
        )
        #expect(
            appServerNotifications == [
                transport.terminalIdle(for: threadID)
            ]
        )
    }

    @Test
    func stoppingActiveThreadPersistsCancellationExactlyOnce()
        async throws
    {
        let workspaceID = UUID(
            uuidString: "10000000-0000-0000-0000-000000000001"
        )!
        let targetThreadUUID = UUID(
            uuidString: "20000000-0000-0000-0000-000000000002"
        )!
        let survivingThreadUUID = UUID(
            uuidString: "30000000-0000-0000-0000-000000000003"
        )!
        let targetTurnUUID = UUID(
            uuidString: "40000000-0000-0000-0000-000000000004"
        )!
        let survivingTurnUUID = UUID(
            uuidString: "50000000-0000-0000-0000-000000000005"
        )!
        let targetThreadID = CodexStoredThreadID(
            targetThreadUUID.uuidString.lowercased()
        )
        let survivingThreadID = CodexStoredThreadID(
            survivingThreadUUID.uuidString.lowercased()
        )
        let targetTurnID = targetTurnUUID.uuidString.lowercased()
        let survivingTurnID = survivingTurnUUID.uuidString.lowercased()
        let transport = ActivityTurnTransport(
            pendingTurnIDs: [
                targetThreadID: [targetTurnID],
                survivingThreadID: [survivingTurnID],
            ]
        )
        let store = CodexSessionStore(
            state: CodexSessionState(
                workspaces: [
                    Workspace(
                        id: workspaceID,
                        displayName: "Activity",
                        rootBookmarkID: nil
                    )
                ],
                threads: [
                    CodexThread(
                        id: targetThreadUUID,
                        workspaceID: workspaceID,
                        title: "Target"
                    ),
                    CodexThread(
                        id: survivingThreadUUID,
                        workspaceID: workspaceID,
                        title: "Survivor"
                    ),
                ],
                turns: [
                    Turn(
                        id: targetTurnUUID,
                        threadID: targetThreadUUID,
                        status: .running
                    ),
                    Turn(
                        id: survivingTurnUUID,
                        threadID: survivingThreadUUID,
                        status: .running
                    ),
                ]
            ),
            transport: transport
        )
        let provider = BlockingActivityTurnProvider()
        var appServerNotifications: [CodexAppServerNotification] = []
        let runner = CodexDesktopTurnSessionRunner(
            sessionStore: store,
            providerFactory: { _ in provider },
            notificationSink: { _ in },
            appServerNotificationSink: {
                appServerNotifications.append(contentsOf: $0)
            }
        )
        defer {
            for snapshot in runner.activeTurnSnapshots() {
                runner.interrupt(turnID: snapshot.turnID)
            }
        }

        let target = try runner.startDesktopTurn(
            id: .string("start/target"),
            params: Self.params(
                threadID: targetThreadID,
                text: "Stop this turn"
            )
        )
        let survivor = try runner.startDesktopTurn(
            id: .string("start/survivor"),
            params: Self.params(
                threadID: survivingThreadID,
                text: "Keep this turn active"
            )
        )
        #expect(
            await provider.waitUntilStarted([
                target.turn.id,
                survivor.turn.id,
            ])
        )

        #expect(
            runner.interruptDesktopTurns(
                threadID: targetThreadID
            ) == [targetTurnID]
        )
        #expect(
            runner.interruptDesktopTurns(
                threadID: targetThreadID
            ).isEmpty
        )
        await runner.waitForTurn(target.turn.id)

        #expect(transport.cancelledTurnIDs == [targetTurnUUID])
        #expect(
            store.state.turns.first(where: {
                $0.id == targetTurnUUID
            })?.status == .cancelled
        )
        #expect(
            appServerNotifications == [
                transport.terminalIdle(for: targetThreadID)
            ]
        )
        #expect(
            runner.activeTurnSnapshots() == [
                .init(
                    turnID: survivingTurnID,
                    threadID: survivingThreadID
                )
            ]
        )
        #expect(
            provider.isCancelled(turnID: survivingTurnID) == false
        )

        #expect(
            runner.interruptDesktopTurns(
                threadID: survivingThreadID
            ) == [survivingTurnID]
        )
        await runner.waitForTurn(survivor.turn.id)
    }

    @Test
    func stoppingTurnAfterTerminalCompletionDoesNotPersistCancellation()
        async throws
    {
        let workspaceID = UUID(
            uuidString: "60000000-0000-0000-0000-000000000006"
        )!
        let threadUUID = UUID(
            uuidString: "70000000-0000-0000-0000-000000000007"
        )!
        let turnUUID = UUID(
            uuidString: "80000000-0000-0000-0000-000000000008"
        )!
        let threadID = CodexStoredThreadID(
            threadUUID.uuidString.lowercased()
        )
        let turnID = turnUUID.uuidString.lowercased()
        let transport = ActivityTurnTransport(
            pendingTurnIDs: [threadID: [turnID]]
        )
        let store = CodexSessionStore(
            state: CodexSessionState(
                workspaces: [
                    Workspace(
                        id: workspaceID,
                        displayName: "Terminal race",
                        rootBookmarkID: nil
                    )
                ],
                threads: [
                    CodexThread(
                        id: threadUUID,
                        workspaceID: workspaceID,
                        title: "Already complete"
                    )
                ],
                turns: [
                    Turn(
                        id: turnUUID,
                        threadID: threadUUID,
                        status: .running
                    )
                ]
            ),
            transport: transport
        )
        let provider = BlockingActivityTurnProvider()
        var appServerNotifications: [CodexAppServerNotification] = []
        let runner = CodexDesktopTurnSessionRunner(
            sessionStore: store,
            providerFactory: { _ in provider },
            notificationSink: { _ in },
            appServerNotificationSink: {
                appServerNotifications.append(contentsOf: $0)
            }
        )

        let started = try runner.startDesktopTurn(
            id: .string("start/terminal-race"),
            params: Self.params(
                threadID: threadID,
                text: "Finish before stop"
            )
        )
        #expect(await provider.waitUntilStarted([started.turn.id]))
        #expect(
            store.apply(
                DomainEvent(
                    sequence: 1,
                    payload: .turnStatusChanged(
                        turnID: turnUUID,
                        status: .completed
                    )
                )
            ) == .applied
        )

        #expect(
            runner.interruptDesktopTurns(threadID: threadID) == [turnID]
        )
        await runner.waitForTurn(started.turn.id)

        #expect(transport.cancelledTurnIDs.isEmpty)
        #expect(
            store.state.turns.first(where: {
                $0.id == turnUUID
            })?.status == .completed
        )
        #expect(appServerNotifications.isEmpty)
    }

    @Test
    func listsStableActivityAndStopsOnlyTheRequestedThread()
        async throws
    {
        let targetThreadID = CodexStoredThreadID("thread/zeta")
        let survivingThreadID =
            CodexStoredThreadID("thread/alpha")
        let transport = ActivityTurnTransport(
            pendingTurnIDs: [
                targetThreadID: [
                    "turn/zeta-2",
                    "turn/zeta-1",
                ],
                survivingThreadID: ["turn/alpha"],
            ]
        )
        let provider = BlockingActivityTurnProvider()
        let runner = CodexDesktopTurnSessionRunner(
            sessionStore: CodexSessionStore(transport: transport),
            providerFactory: { _ in provider },
            notificationSink: { _ in }
        )
        defer {
            for snapshot in runner.activeTurnSnapshots() {
                runner.interrupt(turnID: snapshot.turnID)
            }
        }

        let targetSecond = try runner.startDesktopTurn(
            id: .string("start/zeta-2"),
            params: Self.params(
                threadID: targetThreadID,
                text: "Keep target turn two active"
            )
        )
        let survivor = try runner.startDesktopTurn(
            id: .string("start/alpha"),
            params: Self.params(
                threadID: survivingThreadID,
                text: "Keep survivor active"
            )
        )
        let targetFirst = try runner.startDesktopTurn(
            id: .string("start/zeta-1"),
            params: Self.params(
                threadID: targetThreadID,
                text: "Keep target turn one active"
            )
        )

        let allTurnIDs: Set<String> = [
            targetSecond.turn.id,
            survivor.turn.id,
            targetFirst.turn.id,
        ]
        #expect(await provider.waitUntilStarted(allTurnIDs))

        #expect(
            runner.activeTurnSnapshots() == [
                .init(
                    turnID: "turn/alpha",
                    threadID: survivingThreadID
                ),
                .init(
                    turnID: "turn/zeta-1",
                    threadID: targetThreadID
                ),
                .init(
                    turnID: "turn/zeta-2",
                    threadID: targetThreadID
                ),
            ]
        )

        #expect(
            runner.interruptDesktopTurns(
                threadID: targetThreadID
            ) == [
                "turn/zeta-1",
                "turn/zeta-2",
            ]
        )
        #expect(
            runner.activeTurnSnapshots() == [
                .init(
                    turnID: "turn/alpha",
                    threadID: survivingThreadID
                )
            ]
        )
        #expect(
            provider.isCancelled(turnID: "turn/zeta-1")
                == true
        )
        #expect(
            provider.isCancelled(turnID: "turn/zeta-2")
                == true
        )
        #expect(
            provider.isCancelled(turnID: "turn/alpha")
                == false
        )
        #expect(
            runner.interruptDesktopTurns(
                threadID: targetThreadID
            ).isEmpty
        )

        await runner.waitForTurn(targetFirst.turn.id)
        await runner.waitForTurn(targetSecond.turn.id)

        #expect(
            runner.interruptDesktopTurns(
                threadID: survivingThreadID
            ) == ["turn/alpha"]
        )
        await runner.waitForTurn(survivor.turn.id)
        #expect(runner.activeTurnSnapshots().isEmpty)
    }

    private static func params(
        threadID: CodexStoredThreadID,
        text: String
    ) -> CodexTurnStartParams {
        CodexTurnStartParams(
            threadID: threadID,
            input: [
                .text(
                    text: text,
                    textElements: []
                )
            ]
        )
    }
}
