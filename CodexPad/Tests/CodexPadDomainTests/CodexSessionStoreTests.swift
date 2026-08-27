import Foundation
import Testing
import CodexPadApplication
import CodexPadDomain

@MainActor
@Test
func storePublishesAppliedStateAndRetainsGap() {
    let store = CodexSessionStore()
    let workspace = Workspace(
        id: UUID(),
        displayName: "Codex",
        rootBookmarkID: nil
    )

    #expect(
        store.apply(
            DomainEvent(
                sequence: 1,
                payload: .workspaceUpserted(workspace)
            )
        ) == .applied
    )
    #expect(store.state.workspaces == [workspace])
    #expect(
        store.apply(
            DomainEvent(
                sequence: 3,
                payload: .workspaceUpserted(workspace)
            )
        ) == .gap(expected: 2, received: 3)
    )
    #expect(
        store.lastApplyProblem == .gap(expected: 2, received: 3)
    )
}

@MainActor
@Test
func storePersistsEveryWorkspaceSelectionIncludingClear() {
    let store = CodexSessionStore()
    let workspaceID = UUID()
    var persistedSelections: [UUID?] = []

    store.setWorkspaceSelectionPersistence {
        persistedSelections.append($0)
    }
    store.selectedWorkspaceID = workspaceID
    store.selectedWorkspaceID = workspaceID
    store.selectedWorkspaceID = nil

    #expect(
        persistedSelections.count == 3
    )
    #expect(persistedSelections[0] == nil)
    #expect(persistedSelections[1] == workspaceID)
    #expect(persistedSelections[2] == nil)
}
