import Foundation
import Testing
@testable import CodexPadDomain

@Test
func threadQueueChangedReplacesQueueAtomically() {
    let workspace = Workspace(
        id: UUID(),
        displayName: "Queue",
        rootBookmarkID: nil
    )
    let thread = CodexThread(
        id: UUID(),
        workspaceID: workspace.id,
        title: "Queued work"
    )
    let submission = CodexQueuedSubmission(
        id: UUID().uuidString.lowercased(),
        input: [.text(text: "Next", textElements: [])],
        clientUserMessageID: "client-next"
    )
    var state = CodexSessionState(
        workspaces: [workspace],
        threads: [thread]
    )

    #expect(
        CodexSessionReducer.apply(
            .init(
                sequence: 1,
                payload: .threadQueueChanged(
                    threadID: thread.id,
                    submissions: [submission]
                )
            ),
            to: &state
        ) == .applied
    )
    #expect(
        state.threadQueues == [
            CodexThreadQueue(
                threadID: thread.id,
                submissions: [submission]
            )
        ]
    )
}

@Test
func duplicateSequenceIsIgnored() {
    let workspace = Workspace(
        id: UUID(),
        displayName: "Codex",
        rootBookmarkID: nil
    )
    let event = DomainEvent(
        sequence: 1,
        payload: .workspaceUpserted(workspace)
    )
    var state = CodexSessionState()

    #expect(CodexSessionReducer.apply(event, to: &state) == .applied)
    #expect(CodexSessionReducer.apply(event, to: &state) == .duplicate)
    #expect(state.workspaces == [workspace])
    #expect(state.lastAppliedSequence == 1)
}

@Test
func gapDoesNotMutateState() {
    var state = CodexSessionState()
    let event = DomainEvent(
        sequence: 2,
        payload: .workspaceUpserted(
            Workspace(id: UUID(), displayName: "Codex", rootBookmarkID: nil)
        )
    )

    #expect(
        CodexSessionReducer.apply(event, to: &state)
            == .gap(expected: 1, received: 2)
    )
    #expect(state.workspaces.isEmpty)
    #expect(state.lastAppliedSequence == 0)
}

@Test
func workspaceUpsertReplacesMetadataForTheSameID() {
    let workspaceID = UUID()
    let original = Workspace(
        id: workspaceID,
        displayName: "Original",
        rootBookmarkID: "OLD_BOOKMARK"
    )
    let updated = Workspace(
        id: workspaceID,
        displayName: "Renamed",
        rootBookmarkID: "NEW_BOOKMARK"
    )
    var state = CodexSessionState(workspaces: [original])

    #expect(
        CodexSessionReducer.apply(
            .init(sequence: 1, payload: .workspaceUpserted(updated)),
            to: &state
        ) == .applied
    )
    #expect(state.workspaces == [updated])
}

@Test
func workspaceRemoveRejectsReferencedWorkspaceAtomically() {
    let workspace = Workspace(
        id: UUID(),
        displayName: "Referenced",
        rootBookmarkID: nil
    )
    let thread = CodexThread(
        id: UUID(),
        workspaceID: workspace.id,
        title: "Active thread"
    )
    var state = CodexSessionState(
        workspaces: [workspace],
        threads: [thread]
    )
    let original = state

    #expect(
        CodexSessionReducer.apply(
            .init(
                sequence: 1,
                payload: .workspaceRemoved(
                    workspaceID: workspace.id
                )
            ),
            to: &state
        ) == .invalidReference("workspace")
    )
    #expect(state == original)
}

@Test
func workspaceRemoveDeletesUnreferencedWorkspace() {
    let workspace = Workspace(
        id: UUID(),
        displayName: "Disposable",
        rootBookmarkID: nil
    )
    var state = CodexSessionState(workspaces: [workspace])

    #expect(
        CodexSessionReducer.apply(
            .init(
                sequence: 1,
                payload: .workspaceRemoved(
                    workspaceID: workspace.id
                )
            ),
            to: &state
        ) == .applied
    )
    #expect(state.workspaces.isEmpty)
    #expect(state.lastAppliedSequence == 1)
}

@Test
func turnRequiresExistingThread() {
    var state = CodexSessionState()
    let turn = Turn(id: UUID(), threadID: UUID(), status: .running)
    let event = DomainEvent(sequence: 1, payload: .turnStarted(turn))

    #expect(
        CodexSessionReducer.apply(event, to: &state)
            == .invalidReference("thread")
    )
    #expect(state.lastAppliedSequence == 0)
}

@Test
func completeLifecycleAppliesInSequence() {
    let workspace = Workspace(
        id: UUID(),
        displayName: "Codex",
        rootBookmarkID: nil
    )
    let thread = CodexThread(
        id: UUID(),
        workspaceID: workspace.id,
        title: "Task"
    )
    let turn = Turn(id: UUID(), threadID: thread.id, status: .running)
    let item = ThreadItem(
        id: UUID(),
        threadID: thread.id,
        turnID: turn.id,
        kind: .toolCall,
        text: "Apply patch"
    )
    let approval = Approval(
        id: UUID(),
        turnID: turn.id,
        itemID: item.id,
        title: "Apply patch",
        details: "1 file",
        status: .requested
    )
    let events: [DomainEvent] = [
        .init(sequence: 1, payload: .workspaceUpserted(workspace)),
        .init(sequence: 2, payload: .threadUpserted(thread)),
        .init(sequence: 3, payload: .turnStarted(turn)),
        .init(sequence: 4, payload: .itemAppended(item)),
        .init(sequence: 5, payload: .approvalRequested(approval)),
        .init(
            sequence: 6,
            payload: .approvalResolved(
                approvalID: approval.id,
                status: .approved
            )
        ),
        .init(
            sequence: 7,
            payload: .turnStatusChanged(
                turnID: turn.id,
                status: .completed
            )
        ),
    ]
    var state = CodexSessionState()

    for event in events {
        #expect(CodexSessionReducer.apply(event, to: &state) == .applied)
    }

    #expect(state.lastAppliedSequence == 7)
    #expect(state.approvals.first?.status == .approved)
    #expect(state.turns.first?.status == .completed)
}

@Test
func threadNameNotificationUpdatesExistingThread() {
    let workspace = Workspace(
        id: UUID(),
        displayName: "Codex",
        rootBookmarkID: nil
    )
    let thread = CodexThread(
        id: UUID(),
        workspaceID: workspace.id,
        title: "Original"
    )
    var state = CodexSessionState()
    #expect(
        CodexSessionReducer.apply(
            .init(sequence: 1, payload: .workspaceUpserted(workspace)),
            to: &state
        ) == .applied
    )
    #expect(
        CodexSessionReducer.apply(
            .init(sequence: 2, payload: .threadUpserted(thread)),
            to: &state
        ) == .applied
    )
    #expect(
        CodexSessionReducer.apply(
            .init(
                sequence: 3,
                payload: .threadNameUpdated(
                    threadID: thread.id,
                    name: "Renamed"
                )
            ),
            to: &state
        ) == .applied
    )
    #expect(state.threads.first?.title == "Renamed")
}

@Test
func threadArchiveLifecycleUpdatesArchivedIDs() {
    let workspace = Workspace(
        id: UUID(),
        displayName: "Codex",
        rootBookmarkID: nil
    )
    let thread = CodexThread(
        id: UUID(),
        workspaceID: workspace.id,
        title: "Task"
    )
    var state = CodexSessionState()
    let events: [DomainEvent] = [
        .init(sequence: 1, payload: .workspaceUpserted(workspace)),
        .init(sequence: 2, payload: .threadUpserted(thread)),
        .init(sequence: 3, payload: .threadArchived(threadID: thread.id)),
        .init(sequence: 4, payload: .threadUnarchived(threadID: thread.id)),
    ]
    #expect(CodexSessionReducer.apply(events[0], to: &state) == .applied)
    #expect(CodexSessionReducer.apply(events[1], to: &state) == .applied)
    #expect(CodexSessionReducer.apply(events[2], to: &state) == .applied)
    #expect(state.archivedThreadIDs.contains(thread.id))
    #expect(CodexSessionReducer.apply(events[3], to: &state) == .applied)
    #expect(!state.archivedThreadIDs.contains(thread.id))
}

@Test
func threadDeleteCascadesThroughLocalSessionState() {
    let workspace = Workspace(
        id: UUID(),
        displayName: "Codex",
        rootBookmarkID: nil
    )
    let thread = CodexThread(
        id: UUID(),
        workspaceID: workspace.id,
        title: "Disposable"
    )
    let turn = Turn(id: UUID(), threadID: thread.id, status: .completed)
    let item = ThreadItem(
        id: UUID(),
        threadID: thread.id,
        turnID: turn.id,
        kind: .assistantMessage,
        text: "Done"
    )
    let settings = ThreadSettings(
        threadID: thread.id,
        cwd: "/workspace",
        model: "gpt-5.4",
        effort: .high,
        approvalPolicy: .onRequest,
        sandboxPolicy: .workspaceWrite
    )
    var state = CodexSessionState()
    let events: [DomainEvent] = [
        .init(sequence: 1, payload: .workspaceUpserted(workspace)),
        .init(sequence: 2, payload: .threadUpserted(thread)),
        .init(sequence: 3, payload: .threadArchived(threadID: thread.id)),
        .init(sequence: 4, payload: .turnStarted(turn)),
        .init(sequence: 5, payload: .itemAppended(item)),
        .init(sequence: 6, payload: .threadSettingsUpdated(settings)),
        .init(sequence: 7, payload: .threadDeleted(threadID: thread.id)),
    ]
    for event in events {
        #expect(CodexSessionReducer.apply(event, to: &state) == .applied)
    }
    #expect(state.threads.isEmpty)
    #expect(state.turns.isEmpty)
    #expect(state.items.isEmpty)
    #expect(state.approvals.isEmpty)
    #expect(state.archivedThreadIDs.isEmpty)
    #expect(state.threadSettings.isEmpty)
}
@Test
func threadGoalNotificationsUpdateAndClearPersistedState() {
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
    var state = CodexSessionState(workspaces: [workspace], threads: [thread])

    #expect(
        CodexSessionReducer.apply(
            .init(sequence: 1, payload: .threadGoalUpdated(goal)),
            to: &state
        ) == .applied
    )
    #expect(state.threadGoals == [goal])
    #expect(
        CodexSessionReducer.apply(
            .init(sequence: 2, payload: .threadGoalCleared(threadID: thread.id)),
            to: &state
        ) == .applied
    )
    #expect(state.threadGoals.isEmpty)
}

@Test
func threadSettingsNotificationUpdatesPersistedState() {
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
    var state = CodexSessionState(workspaces: [workspace], threads: [thread])

    #expect(
        CodexSessionReducer.apply(
            .init(sequence: 1, payload: .threadSettingsUpdated(settings)),
            to: &state
        ) == .applied
    )
    #expect(state.threadSettings == [settings])
}
