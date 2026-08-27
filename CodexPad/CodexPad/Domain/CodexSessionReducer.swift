import Foundation

public struct CodexSessionState: Equatable, Sendable {
    public fileprivate(set) var lastAppliedSequence: Int64
    public fileprivate(set) var workspaces: [Workspace]
    public fileprivate(set) var threads: [CodexThread]
    public fileprivate(set) var turns: [Turn]
    public fileprivate(set) var items: [ThreadItem]
    public fileprivate(set) var approvals: [Approval]
    public fileprivate(set) var archivedThreadIDs: Set<UUID>
    public fileprivate(set) var threadGoals: [ThreadGoal]
    public fileprivate(set) var threadSettings: [ThreadSettings]
    public fileprivate(set) var threadQueues: [CodexThreadQueue]

    public init(
        lastAppliedSequence: Int64 = 0,
        workspaces: [Workspace] = [],
        threads: [CodexThread] = [],
        turns: [Turn] = [],
        items: [ThreadItem] = [],
        approvals: [Approval] = [],
        archivedThreadIDs: Set<UUID> = [],
        threadGoals: [ThreadGoal] = [],
        threadSettings: [ThreadSettings] = [],
        threadQueues: [CodexThreadQueue] = []
    ) {
        self.lastAppliedSequence = lastAppliedSequence
        self.workspaces = workspaces
        self.threads = threads
        self.turns = turns
        self.items = items
        self.approvals = approvals
        self.archivedThreadIDs = archivedThreadIDs
        self.threadGoals = threadGoals
        self.threadSettings = threadSettings
        self.threadQueues = threadQueues
    }
}

public enum ApplyResult: Equatable, Sendable {
    case applied
    case duplicate
    case gap(expected: Int64, received: Int64)
    case invalidReference(String)
}

public enum CodexSessionReducer {
    public static func consumeSequence(
        _ sequence: Int64,
        in state: inout CodexSessionState
    ) -> ApplyResult {
        if sequence <= state.lastAppliedSequence {
            return .duplicate
        }
        let expected = state.lastAppliedSequence + 1
        guard sequence == expected else {
            return .gap(expected: expected, received: sequence)
        }
        state.lastAppliedSequence = sequence
        return .applied
    }

    public static func apply(
        _ event: DomainEvent,
        to state: inout CodexSessionState
    ) -> ApplyResult {
        if event.sequence <= state.lastAppliedSequence {
            return .duplicate
        }
        let expected = state.lastAppliedSequence + 1
        guard event.sequence == expected else {
            return .gap(expected: expected, received: event.sequence)
        }

        var candidate = state
        let result = applyPayload(event.payload, to: &candidate)
        guard result == .applied else {
            return result
        }
        candidate.lastAppliedSequence = event.sequence
        state = candidate
        return .applied
    }

    private static func applyPayload(
        _ payload: DomainEvent.Payload,
        to state: inout CodexSessionState
    ) -> ApplyResult {
        switch payload {
        case let .workspaceUpserted(workspace):
            upsert(workspace, in: &state.workspaces)

        case let .workspaceRemoved(workspaceID):
            guard state.workspaces.contains(where: {
                $0.id == workspaceID
            }), !state.threads.contains(where: {
                $0.workspaceID == workspaceID
            }) else {
                return .invalidReference("workspace")
            }
            state.workspaces.removeAll { $0.id == workspaceID }

        case let .threadUpserted(thread):
            guard state.workspaces.contains(where: {
                $0.id == thread.workspaceID
            }) else {
                return .invalidReference("workspace")
            }
            upsert(thread, in: &state.threads)

        case let .threadNameUpdated(threadID, name):
            guard let index = state.threads.firstIndex(where: {
                $0.id == threadID
            }), !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                return .invalidReference("thread")
            }
            state.threads[index].title = name

        case let .threadArchived(threadID):
            guard state.threads.contains(where: { $0.id == threadID }) else {
                return .invalidReference("thread")
            }
            state.archivedThreadIDs.insert(threadID)

        case let .threadUnarchived(threadID):
            guard state.threads.contains(where: { $0.id == threadID }),
                  state.archivedThreadIDs.contains(threadID)
            else {
                return .invalidReference("thread")
            }
            state.archivedThreadIDs.remove(threadID)

        case let .threadDeleted(threadID):
            guard state.threads.contains(where: { $0.id == threadID }) else {
                return .invalidReference("thread")
            }
            let turnIDs = Set(
                state.turns
                    .filter { $0.threadID == threadID }
                    .map(\.id)
            )
            let itemIDs = Set(
                state.items
                    .filter { $0.threadID == threadID }
                    .map(\.id)
            )
            state.approvals.removeAll {
                turnIDs.contains($0.turnID) || itemIDs.contains($0.itemID)
            }
            state.items.removeAll { $0.threadID == threadID }
            state.turns.removeAll { $0.threadID == threadID }
            state.threads.removeAll { $0.id == threadID }
            state.archivedThreadIDs.remove(threadID)
            state.threadGoals.removeAll { $0.threadID == threadID }
            state.threadSettings.removeAll { $0.threadID == threadID }
            state.threadQueues.removeAll { $0.threadID == threadID }

        case let .threadGoalUpdated(goal):
            guard state.threads.contains(where: { $0.id == goal.threadID }),
                  !goal.objective.trimmingCharacters(
                    in: .whitespacesAndNewlines
                  ).isEmpty,
                  goal.tokenBudget.map({ $0 > 0 }) ?? true,
                  goal.tokensUsed >= 0,
                  goal.timeUsedSeconds >= 0,
                  goal.createdAt >= 0,
                  goal.updatedAt >= goal.createdAt
            else {
                return .invalidReference("thread-goal")
            }
            upsert(goal, in: &state.threadGoals)

        case let .threadGoalCleared(threadID):
            guard state.threadGoals.contains(where: {
                $0.threadID == threadID
            }) else {
                return .invalidReference("thread-goal")
            }
            state.threadGoals.removeAll { $0.threadID == threadID }

        case let .threadSettingsUpdated(settings):
            guard state.threads.contains(where: { $0.id == settings.threadID }),
                  settings.cwd.hasPrefix("/"),
                  !settings.model.isEmpty,
                  !settings.modelProvider.isEmpty,
                  settings.approvalsReviewer == "user",
                  ["default", "plan"].contains(settings.collaborationMode)
            else {
                return .invalidReference("thread-settings")
            }
            upsert(settings, in: &state.threadSettings)

        case .threadMetadataChanged:
            break

        case let .threadQueueChanged(threadID, submissions):
            guard state.threads.contains(where: { $0.id == threadID }) else {
                return .invalidReference("thread")
            }
            let queue = CodexThreadQueue(
                threadID: threadID,
                submissions: submissions
            )
            if let index = state.threadQueues.firstIndex(where: {
                $0.threadID == threadID
            }) {
                state.threadQueues[index] = queue
            } else {
                state.threadQueues.append(queue)
            }

        case let .threadRolledBack(threadID, removedTurnIDs):
            guard state.threads.contains(where: { $0.id == threadID }),
                  !removedTurnIDs.isEmpty,
                  removedTurnIDs.allSatisfy({ turnID in
                      state.turns.contains(where: {
                          $0.id == turnID && $0.threadID == threadID
                      })
                  })
            else {
                return .invalidReference("thread-rollback")
            }
            let removed = Set(removedTurnIDs)
            state.items.removeAll { removed.contains($0.turnID) }
            state.turns.removeAll { removed.contains($0.id) }

        case let .turnStarted(turn):
            guard state.threads.contains(where: { $0.id == turn.threadID })
            else {
                return .invalidReference("thread")
            }
            guard !state.turns.contains(where: { $0.id == turn.id }) else {
                return .invalidReference("duplicate-turn")
            }
            state.turns.append(turn)

        case let .turnStatusChanged(turnID, status):
            guard let index = state.turns.firstIndex(where: {
                $0.id == turnID
            }) else {
                return .invalidReference("turn")
            }
            state.turns[index].status = status

        case let .itemAppended(item):
            guard state.threads.contains(where: {
                $0.id == item.threadID
            }) else {
                return .invalidReference("thread")
            }
            guard let turn = state.turns.first(where: {
                $0.id == item.turnID
            }), turn.threadID == item.threadID else {
                return .invalidReference("turn")
            }
            guard !state.items.contains(where: { $0.id == item.id }) else {
                return .invalidReference("duplicate-item")
            }
            state.items.append(item)

        case let .approvalRequested(approval):
            guard state.turns.contains(where: {
                $0.id == approval.turnID
            }) else {
                return .invalidReference("turn")
            }
            guard let item = state.items.first(where: {
                $0.id == approval.itemID
            }), item.turnID == approval.turnID else {
                return .invalidReference("item")
            }
            guard !state.approvals.contains(where: {
                $0.id == approval.id
            }) else {
                return .invalidReference("duplicate-approval")
            }
            state.approvals.append(approval)

        case let .approvalResolved(approvalID, status):
            guard let index = state.approvals.firstIndex(where: {
                $0.id == approvalID
            }) else {
                return .invalidReference("approval")
            }
            state.approvals[index].status = status
        }
        return .applied
    }

    private static func upsert<Value: Identifiable>(
        _ value: Value,
        in values: inout [Value]
    ) where Value.ID: Equatable {
        if let index = values.firstIndex(where: { $0.id == value.id }) {
            values[index] = value
        } else {
            values.append(value)
        }
    }
}
