import Foundation
import Testing
@testable import CodexPadDomain

@Test
func domainEventRoundTripsWithoutLosingIdentity() throws {
    let workspace = Workspace(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
        displayName: "Codex",
        rootBookmarkID: nil
    )
    let event = DomainEvent(
        sequence: 1,
        payload: .workspaceUpserted(workspace)
    )

    let encoded = try JSONEncoder().encode(event)

    #expect(try JSONDecoder().decode(DomainEvent.self, from: encoded) == event)
}

@Test
func approvalKeepsRequestedPendingState() {
    let approval = Approval(
        id: UUID(),
        turnID: UUID(),
        itemID: UUID(),
        title: "Apply patch",
        details: "1 file",
        status: .requested
    )

    #expect(approval.status == .requested)
}
