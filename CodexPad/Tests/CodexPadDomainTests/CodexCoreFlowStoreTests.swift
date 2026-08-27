import Foundation
import Testing
import CodexPadApplication
import CodexPadDomain
import CodexPadProtocolBridge

private enum FakeCodexCoreTransportError: Error {
    case missingReply
}

@MainActor
private final class FakeCodexCoreTransport: CodexCoreTransport {
    private(set) var submitted: [CodexCoreCommand] = []
    private(set) var requested: [CodexAppServerThreadRequest] = []
    var queuedReplies: [Data] = []
    var queuedEvents: [CodexCoreEvent] = []

    func submit(_ command: CodexCoreCommand) throws {
        submitted.append(command)
    }

    func request(_ request: CodexAppServerThreadRequest) throws -> Data {
        requested.append(request)
        guard !queuedReplies.isEmpty else {
            throw FakeCodexCoreTransportError.missingReply
        }
        return queuedReplies.removeFirst()
    }

    func nextEvent() throws -> CodexCoreEvent? {
        guard !queuedEvents.isEmpty else {
            return nil
        }
        return queuedEvents.removeFirst()
    }
}

@MainActor
@Test
func codexSessionStoreBridgesAllThreadQueueOperations() throws {
    let threadID = CodexStoredThreadID(
        rawValue: "019fab26-5c01-7562-97f1-0999adf15538"
    )
    let queuedID = "019fab26-5c01-7562-97f1-0999adf15539"
    let input: [CodexStoredUserInput] = [
        .text(text: "queued", textElements: [])
    ]
    let transport = FakeCodexCoreTransport()
    transport.queuedReplies = [
        Data(#"{"id":101,"result":{"queuedSubmission":{"id":"019fab26-5c01-7562-97f1-0999adf15539","input":[{"type":"text","text":"queued","text_elements":[]}],"clientUserMessageId":"client-1"}}}"#.utf8),
        Data(#"{"id":102,"result":{"data":[{"id":"019fab26-5c01-7562-97f1-0999adf15539","input":[{"type":"text","text":"queued","text_elements":[]}],"clientUserMessageId":"client-1"}],"nextCursor":null}}"#.utf8),
        Data(#"{"id":103,"result":{"queuedSubmission":{"id":"019fab26-5c01-7562-97f1-0999adf15539","input":[{"type":"text","text":"updated","text_elements":[]}],"clientUserMessageId":"client-1"}}}"#.utf8),
        Data(#"{"id":104,"result":{"deleted":true}}"#.utf8),
        Data(#"{"id":105,"result":{}}"#.utf8),
        Data(#"{"id":106,"result":{"turn":{"id":"turn-1","items":[],"status":"inProgress","error":null,"startedAt":null,"completedAt":null,"durationMs":null}}}"#.utf8),
    ]
    let store = CodexSessionStore(transport: transport)

    let added = try store.addQueuedSubmission(
        id: .integer(101),
        params: .init(
            threadID: threadID,
            input: input,
            clientUserMessageID: "client-1"
        )
    )
    #expect(added.queuedSubmission.id == queuedID)

    let listed = try store.listQueuedSubmissions(
        id: .integer(102),
        params: .init(threadID: threadID, cursor: .null, limit: .value(20))
    )
    #expect(listed.data.map(\.id) == [queuedID])
    #expect(listed.nextCursor == nil)

    let updated = try store.updateQueuedSubmission(
        id: .integer(103),
        params: .init(
            threadID: threadID,
            queuedSubmissionID: queuedID,
            input: [.text(text: "updated", textElements: [])]
        )
    )
    #expect(updated.queuedSubmission.input == [.text(text: "updated", textElements: [])])

    let deleted = try store.deleteQueuedSubmission(
        id: .integer(104),
        params: .init(threadID: threadID, queuedSubmissionID: queuedID)
    )
    #expect(deleted.deleted)

    try store.reorderQueuedSubmissions(
        id: .integer(105),
        params: .init(threadID: threadID, queuedSubmissionIDs: [queuedID])
    )

    let started = try store.startQueuedSubmission(
        id: .integer(106),
        params: .init(threadID: threadID, queuedSubmissionID: .value(queuedID))
    )
    #expect(started.turn.id == "turn-1")

    #expect(transport.requested.count == 6)
    #expect(transport.requested.map { request in
        switch request {
        case .queueAdd: return "add"
        case .queueList: return "list"
        case .queueUpdate: return "update"
        case .queueDelete: return "delete"
        case .queueReorder: return "reorder"
        case .queueStart: return "start"
        default: return "unexpected"
        }
    } == ["add", "list", "update", "delete", "reorder", "start"])
}

@MainActor
@Test
func codexCoreFlowStoreSubmitsAndDrainsAFirstTurn() throws {
    let workspace = Workspace(
        id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
        displayName: "Mars Project",
        rootBookmarkID: nil
    )
    let thread = CodexThread(
        id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
        workspaceID: workspace.id,
        title: "First thread"
    )
    let turn = Turn(
        id: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
        threadID: thread.id,
        status: .running
    )
    let userItem = ThreadItem(
        id: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!,
        threadID: thread.id,
        turnID: turn.id,
        kind: .userMessage,
        text: "Inspect this workspace"
    )
    let transport = FakeCodexCoreTransport()
    let store = CodexSessionStore(transport: transport)
    let metadata = CodexThreadCreateMetadata(
        sessionID: thread.id.uuidString.lowercased(),
        forkedFromID: nil,
        preview: thread.title,
        ephemeral: false,
        modelProvider: "openai",
        createdAt: 1_722_345_600,
        updatedAt: 1_722_345_600,
        recencyAt: 1_722_345_600,
        path: nil,
        cwd: "/workspace/Mars Project",
        cliVersion: "0.146.0-alpha.3.1",
        source: .named(.appServer),
        threadSource: "user",
        parentThreadID: nil,
        agentNickname: nil,
        agentRole: nil,
        gitInfo: nil
    )

    transport.queuedEvents = [
        .pong(sequence: 99, requestID: "ignored"),
        .domain(DomainEvent(
            sequence: 1,
            payload: .workspaceUpserted(workspace)
        )),
    ]
    try store.openWorkspace(
        id: workspace.id,
        displayName: workspace.displayName,
        rootBookmarkID: workspace.rootBookmarkID
    )
    #expect(transport.submitted == [.openWorkspace(workspace)])
    #expect(store.selectedWorkspaceID == workspace.id)

    transport.queuedEvents = [
        .domain(DomainEvent(
            sequence: 2,
            payload: .threadUpserted(thread)
        )),
    ]
    try store.startThread(
        id: thread.id,
        workspaceID: workspace.id,
        title: thread.title,
        metadata: metadata
    )
    #expect(
        transport.submitted.last
            == .startThread(thread, metadata: metadata)
    )
    #expect(store.selectedThreadID == thread.id)

    transport.queuedEvents = [
        .domain(DomainEvent(
            sequence: 3,
            payload: .turnStarted(turn)
        )),
        .domain(DomainEvent(
            sequence: 4,
            payload: .itemAppended(userItem)
        )),
    ]
    try store.startTurn(
        id: turn.id,
        threadID: thread.id,
        itemID: userItem.id,
        text: userItem.text,
        timestamp: 1_722_345_601
    )

    #expect(
        transport.submitted.last
            == .startTurn(
                turn,
                userItem: userItem,
                timestamp: 1_722_345_601
            )
    )
    #expect(transport.submitted.count == 3)
    #expect(store.state.lastAppliedSequence == 4)
    #expect(store.state.items.last?.text == "Inspect this workspace")
    #expect(store.lastTransportProblem == nil)
}

@MainActor
@Test
func codexCoreFlowStoreExposesSequenceGap() throws {
    let workspace = Workspace(
        id: UUID(),
        displayName: "Gap workspace",
        rootBookmarkID: nil
    )
    let transport = FakeCodexCoreTransport()
    transport.queuedEvents = [
        .domain(DomainEvent(
            sequence: 2,
            payload: .workspaceUpserted(workspace)
        )),
    ]
    let store = CodexSessionStore(transport: transport)

    try store.openWorkspace(
        id: workspace.id,
        displayName: workspace.displayName,
        rootBookmarkID: nil
    )

    #expect(store.state.workspaces.isEmpty)
    #expect(store.selectedWorkspaceID == nil)
    #expect(store.lastApplyProblem == .gap(expected: 1, received: 2))
}

@MainActor
@Test
func codexCoreFlowStoreUpdatesWorkspaceMetadataForTheSameID() throws {
    let workspace = Workspace(
        id: UUID(),
        displayName: "Original",
        rootBookmarkID: "OLD_BOOKMARK"
    )
    let updated = Workspace(
        id: workspace.id,
        displayName: "Renamed",
        rootBookmarkID: "NEW_BOOKMARK"
    )
    let transport = FakeCodexCoreTransport()
    transport.queuedEvents = [
        .domain(
            .init(
                sequence: 1,
                payload: .workspaceUpserted(updated)
            )
        ),
    ]
    let store = CodexSessionStore(
        state: .init(workspaces: [workspace]),
        transport: transport
    )
    store.selectedWorkspaceID = workspace.id

    try store.updateWorkspace(
        id: updated.id,
        displayName: updated.displayName,
        rootBookmarkID: updated.rootBookmarkID
    )

    #expect(transport.submitted == [.updateWorkspace(updated)])
    #expect(store.state.workspaces == [updated])
    #expect(store.selectedWorkspaceID == updated.id)
}

@MainActor
@Test
func codexCoreFlowStoreRemovesSelectedWorkspaceAndThreadSelection() throws {
    let workspace = Workspace(
        id: UUID(),
        displayName: "Disposable",
        rootBookmarkID: nil
    )
    let staleSelectedThreadID = UUID()
    let transport = FakeCodexCoreTransport()
    transport.queuedEvents = [
        .domain(
            .init(
                sequence: 1,
                payload: .workspaceRemoved(
                    workspaceID: workspace.id
                )
            )
        ),
    ]
    let store = CodexSessionStore(
        state: .init(workspaces: [workspace]),
        transport: transport
    )
    store.selectedWorkspaceID = workspace.id
    store.selectedThreadID = staleSelectedThreadID

    try store.removeWorkspace(id: workspace.id)

    #expect(transport.submitted == [.removeWorkspace(workspace.id)])
    #expect(store.state.workspaces.isEmpty)
    #expect(store.selectedWorkspaceID == nil)
    #expect(store.selectedThreadID == nil)
}

@MainActor
@Test
func codexCoreFlowStoreRestoresPersistedEventsBeforeSelection() throws {
    let workspace = Workspace(
        id: UUID(),
        displayName: "Recovered",
        rootBookmarkID: "BASE64_BOOKMARK_SAMPLE"
    )
    let thread = CodexThread(
        id: UUID(),
        workspaceID: workspace.id,
        title: "Previous thread"
    )
    let transport = FakeCodexCoreTransport()
    transport.queuedEvents = [
        .domain(DomainEvent(
            sequence: 1,
            payload: .workspaceUpserted(workspace)
        )),
        .domain(DomainEvent(
            sequence: 2,
            payload: .threadUpserted(thread)
        )),
    ]
    let store = CodexSessionStore(transport: transport)

    try store.openStorage(
        databasePath: "/container/CodexPad.sqlite",
        snapshotDirectory: "/container/Snapshots"
    )

    #expect(
        transport.submitted == [
            .openStorage(
                databasePath: "/container/CodexPad.sqlite",
                snapshotDirectory: "/container/Snapshots"
            ),
        ]
    )
    #expect(store.state.lastAppliedSequence == 2)
    #expect(
        store.state.workspaces.first?.rootBookmarkID
            == "BASE64_BOOKMARK_SAMPLE"
    )
    #expect(store.selectedWorkspaceID == workspace.id)
    #expect(store.selectedThreadID == thread.id)

    try store.confirmStorage()
    #expect(transport.submitted.last == .confirmStorage)
}

@MainActor
@Test
func codexCoreFlowStoreConsumesNonDomainSequenceBeforeNewWorkspace() throws {
    let recovered = Workspace(
        id: UUID(),
        displayName: "Recovered",
        rootBookmarkID: nil
    )
    let injected = Workspace(
        id: UUID(),
        displayName: "Parity Git Workspace",
        rootBookmarkID: "PARITY_BOOKMARK"
    )
    let transport = FakeCodexCoreTransport()
    transport.queuedEvents = [
        .pong(sequence: 118, requestID: "replay-probe"),
        .domain(.init(
            sequence: 119,
            payload: .workspaceUpserted(injected)
        )),
    ]
    let store = CodexSessionStore(
        state: .init(
            lastAppliedSequence: 117,
            workspaces: [recovered]
        ),
        transport: transport
    )

    try store.openWorkspace(
        id: injected.id,
        displayName: injected.displayName,
        rootBookmarkID: injected.rootBookmarkID
    )

    #expect(store.lastApplyProblem == nil)
    #expect(store.state.lastAppliedSequence == 119)
    #expect(store.state.workspaces.contains(injected))
    #expect(store.selectedWorkspaceID == injected.id)
}

@MainActor
@Test
func codexCoreFlowStoreReplaysInjectedItemsBeforeWorkspaceUpsert() throws {
    let recoveredWorkspace = Workspace(
        id: UUID(uuidString: "019ff5d3-5cae-7412-8e02-90b301576a6d")!,
        displayName: "verify-that-thread",
        rootBookmarkID: nil
    )
    let renamedThread = CodexThread(
        id: UUID(uuidString: "019ff5d3-5cae-7412-8e02-90a59018d58c")!,
        workspaceID: recoveredWorkspace.id,
        title: "New thread"
    )
    let parityWorkspace = Workspace(
        id: UUID(uuidString: "b553386b-53fc-4c76-8124-bbfe22d01c48")!,
        displayName: "Parity Git Workspace",
        rootBookmarkID: "PARITY_BOOKMARK"
    )
    let injected = try CodexCoreEvent(
        data: Data(
            #"{"sequence":116,"kind":"threadItemsInjected","threadId":"019ff5d3-6e0f-7561-b528-26c8dc4c4661","afterTurnId":"019ff5d3-6e0f-7561-b528-26d26a98f9b6","items":["{\"content\":[{\"text\":\"Side conversation boundary.\",\"type\":\"input_text\"}],\"role\":\"user\",\"type\":\"message\"}"]}"#.utf8
        )
    )
    let transport = FakeCodexCoreTransport()
    transport.queuedEvents = [
        injected,
        .domain(.init(
            sequence: 117,
            payload: .threadNameUpdated(
                threadID: renamedThread.id,
                name: "Verify that parity capture reaches the provider boundary."
            )
        )),
        .domain(.init(
            sequence: 118,
            payload: .workspaceUpserted(parityWorkspace)
        )),
    ]
    let store = CodexSessionStore(
        state: .init(
            lastAppliedSequence: 115,
            workspaces: [recoveredWorkspace],
            threads: [renamedThread]
        ),
        transport: transport
    )

    try store.openStorage(
        databasePath: "/container/CodexPad.sqlite",
        snapshotDirectory: "/container/Snapshots"
    )

    #expect(store.lastApplyProblem == nil)
    #expect(store.state.lastAppliedSequence == 118)
    #expect(store.state.workspaces.contains(parityWorkspace))
    #expect(
        store.state.threads.first(where: { $0.id == renamedThread.id })?.title
            == "Verify that parity capture reaches the provider boundary."
    )
}

@MainActor
@Test
func codexCoreFlowStoreReplaysStableTurnBeforeTerminalEvents() throws {
    let workspace = Workspace(
        id: UUID(uuidString: "019ff452-fd14-7eb0-a59d-a274ec448edf")!,
        displayName: "verify-that-parity-2",
        rootBookmarkID: nil
    )
    let thread = CodexThread(
        id: UUID(uuidString: "019ff452-fd13-78c1-a59d-a2734b29b34a")!,
        workspaceID: workspace.id,
        title: "New thread"
    )
    let turnID = UUID(
        uuidString: "019ff453-05eb-79a2-9e1a-0a60c09967ac"
    )!
    let item = ThreadItem(
        id: UUID(uuidString: "616d008b-b22b-4100-ade9-85dca73ae871")!,
        threadID: thread.id,
        turnID: turnID,
        kind: .error,
        text: "Your saved sign-in credential was rejected (HTTP 401)."
    )
    let settingsNotification = try CodexCoreEvent(data: Data(
        #"{"method":"thread/settings/updated","params":{"threadId":"019ff452-fd13-78c1-a59d-a2734b29b34a","threadSettings":{"cwd":"/workspace/parity","approvalPolicy":"on-request","approvalsReviewer":"user","sandboxPolicy":{"type":"workspaceWrite","writableRoots":[],"networkAccess":false,"excludeTmpdirEnvVar":false,"excludeSlashTmp":false},"activePermissionProfile":null,"model":"gpt-5.6-sol","modelProvider":"openai","serviceTier":"default","effort":"low","summary":"detailed","collaborationMode":{"mode":"default","settings":{"model":"gpt-5.6-sol","reasoning_effort":"low","developer_instructions":null}},"multiAgentMode":"explicitRequestOnly","personality":"friendly"}}}"#.utf8
    ))
    let transport = FakeCodexCoreTransport()
    transport.queuedEvents = [
        settingsNotification,
        .stableTurnStarted(.init(
            sequence: 48,
            threadID: .init(rawValue: thread.id.uuidString.lowercased()),
            turnID: turnID.uuidString.lowercased(),
            userItemID: UUID().uuidString.lowercased(),
            params: .object([:])
        )),
        .domain(.init(sequence: 49, payload: .itemAppended(item))),
        .domain(.init(
            sequence: 50,
            payload: .turnStatusChanged(
                turnID: turnID,
                status: .failed
            )
        )),
    ]
    let store = CodexSessionStore(
        state: .init(
            lastAppliedSequence: 46,
            workspaces: [workspace],
            threads: [thread]
        ),
        transport: transport
    )

    try store.openStorage(
        databasePath: "/container/CodexPad.sqlite",
        snapshotDirectory: "/container/Snapshots"
    )

    #expect(store.lastApplyProblem == nil)
    #expect(store.state.lastAppliedSequence == 50)
    #expect(store.state.turns == [
        Turn(id: turnID, threadID: thread.id, status: .failed),
    ])
    #expect(store.state.items == [item])
}

@MainActor
@Test
func codexCoreFlowStoreDeletesSelectedThread() throws {
    let workspace = Workspace(id: UUID(), displayName: "Project", rootBookmarkID: nil)
    let thread = CodexThread(id: UUID(), workspaceID: workspace.id, title: "Task")
    let state = CodexSessionState(workspaces: [workspace], threads: [thread])
    let transport = FakeCodexCoreTransport()
    transport.queuedEvents = [
        .domain(.init(sequence: 1, payload: .threadDeleted(threadID: thread.id))),
    ]
    let store = CodexSessionStore(state: state, transport: transport)
    store.selectedWorkspaceID = workspace.id
    store.selectedThreadID = thread.id

    try store.deleteThread(id: thread.id)

    #expect(transport.submitted == [.deleteThread(threadID: thread.id)])
    #expect(store.state.threads.isEmpty)
    #expect(store.selectedWorkspaceID == workspace.id)
    #expect(store.selectedThreadID == nil)
}

@MainActor
@Test
func codexCoreFlowStoreForksHistoryThroughSelectedTurn() throws {
    let workspace = Workspace(id: UUID(), displayName: "Project", rootBookmarkID: nil)
    let source = CodexThread(id: UUID(), workspaceID: workspace.id, title: "Task")
    let firstTurn = Turn(id: UUID(), threadID: source.id, status: .completed)
    let secondTurn = Turn(id: UUID(), threadID: source.id, status: .completed)
    let firstItem = ThreadItem(
        id: UUID(), threadID: source.id, turnID: firstTurn.id,
        kind: .userMessage, text: "First"
    )
    let secondItem = ThreadItem(
        id: UUID(), threadID: source.id, turnID: secondTurn.id,
        kind: .userMessage, text: "Second"
    )
    let state = CodexSessionState(
        workspaces: [workspace],
        threads: [source],
        turns: [firstTurn, secondTurn],
        items: [firstItem, secondItem]
    )
    let transport = FakeCodexCoreTransport()
    let store = CodexSessionStore(state: state, transport: transport)
    let forkID = UUID()
    let copiedTurnID = UUID()
    let copiedItemID = UUID()
    let fork = CodexThread(id: forkID, workspaceID: workspace.id, title: "Task (fork)")
    let copiedTurn = Turn(id: copiedTurnID, threadID: forkID, status: .completed)
    let copiedItem = ThreadItem(
        id: copiedItemID, threadID: forkID, turnID: copiedTurnID,
        kind: .userMessage, text: "First"
    )
    transport.queuedEvents = [
        .domain(.init(sequence: 1, payload: .threadUpserted(fork))),
        .domain(.init(sequence: 2, payload: .turnStarted(copiedTurn))),
        .domain(.init(sequence: 3, payload: .itemAppended(copiedItem))),
    ]

    try store.forkThread(
        id: source.id,
        newThreadID: forkID,
        title: fork.title,
        lastTurnID: firstTurn.id,
        turnIDMap: [firstTurn.id: copiedTurnID],
        itemIDMap: [firstItem.id: copiedItemID],
        timestamp: 1_722_345_700
    )

    #expect(
        transport.submitted == [
            .forkThread(
                threadID: source.id,
                newThreadID: forkID,
                title: fork.title,
                lastTurnID: firstTurn.id,
                turnIDMap: [firstTurn.id: copiedTurnID],
                itemIDMap: [firstItem.id: copiedItemID],
                timestamp: 1_722_345_700
            ),
        ]
    )
    #expect(store.selectedThreadID == forkID)
    #expect(store.state.items.filter { $0.threadID == forkID } == [copiedItem])
}

@MainActor
@Test
func codexCoreFlowStoreSetsGetsAndClearsThreadGoal() throws {
    let workspace = Workspace(id: UUID(), displayName: "Project", rootBookmarkID: nil)
    let thread = CodexThread(id: UUID(), workspaceID: workspace.id, title: "Task")
    let goal = ThreadGoal(
        threadID: thread.id,
        objective: "Ship the iPad build",
        status: .active,
        tokenBudget: 12_000,
        tokensUsed: 0,
        timeUsedSeconds: 0,
        createdAt: 100,
        updatedAt: 100
    )
    let transport = FakeCodexCoreTransport()
    let store = CodexSessionStore(
        state: .init(workspaces: [workspace], threads: [thread]),
        transport: transport
    )
    transport.queuedEvents = [
        .domain(.init(sequence: 1, payload: .threadGoalUpdated(goal))),
    ]
    try store.setThreadGoal(
        threadID: thread.id,
        objective: goal.objective,
        tokenBudget: goal.tokenBudget,
        updatedAt: 100
    )
    #expect(transport.submitted == [.setThreadGoal(goal)])
    #expect(store.threadGoal(for: thread.id) == goal)

    transport.queuedEvents = [
        .domain(.init(sequence: 2, payload: .threadGoalCleared(threadID: thread.id))),
    ]
    try store.clearThreadGoal(threadID: thread.id)
    #expect(transport.submitted.last == .clearThreadGoal(threadID: thread.id))
    #expect(store.threadGoal(for: thread.id) == nil)
}

@MainActor
@Test
func codexCoreFlowStoreUpdatesAndReadsThreadSettings() throws {
    let workspace = Workspace(id: UUID(), displayName: "Project", rootBookmarkID: nil)
    let thread = CodexThread(id: UUID(), workspaceID: workspace.id, title: "Task")
    let settings = ThreadSettings(
        threadID: thread.id,
        cwd: "/workspace",
        model: "gpt-5.4",
        effort: .high,
        approvalPolicy: .onRequest,
        sandboxPolicy: .workspaceWrite
    )
    let transport = FakeCodexCoreTransport()
    let store = CodexSessionStore(
        state: .init(workspaces: [workspace], threads: [thread]),
        transport: transport
    )
    transport.queuedEvents = [
        .domain(.init(sequence: 1, payload: .threadSettingsUpdated(settings))),
    ]

    try store.updateThreadSettings(settings)

    #expect(transport.submitted == [.updateThreadSettings(settings)])
    #expect(store.threadSettings(for: thread.id) == settings)
}
