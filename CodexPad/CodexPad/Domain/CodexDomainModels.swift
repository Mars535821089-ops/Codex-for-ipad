import Foundation

public struct Workspace: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var displayName: String
    public var rootBookmarkID: String?

    public init(id: UUID, displayName: String, rootBookmarkID: String?) {
        self.id = id
        self.displayName = displayName
        self.rootBookmarkID = rootBookmarkID
    }
}

public struct CodexThread: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let workspaceID: UUID
    public var title: String

    public init(id: UUID, workspaceID: UUID, title: String) {
        self.id = id
        self.workspaceID = workspaceID
        self.title = title
    }
}

public struct CodexThreadCreateMetadata:
    Codable,
    Equatable,
    Sendable
{
    public let sessionID: String
    public let forkedFromID: CodexStoredThreadID?
    public let preview: String
    public let ephemeral: Bool
    public let modelProvider: String
    public let createdAt: Int64
    public let updatedAt: Int64
    public let recencyAt: Int64?
    public let path: String?
    public let cwd: String
    public let cliVersion: String
    public let source: CodexThreadSessionSource
    public let threadSource: String?
    public let parentThreadID: CodexStoredThreadID?
    public let agentNickname: String?
    public let agentRole: String?
    public let gitInfo: CodexThreadGitInfo?

    public init(
        sessionID: String,
        forkedFromID: CodexStoredThreadID?,
        preview: String,
        ephemeral: Bool,
        modelProvider: String,
        createdAt: Int64,
        updatedAt: Int64,
        recencyAt: Int64?,
        path: String?,
        cwd: String,
        cliVersion: String,
        source: CodexThreadSessionSource,
        threadSource: String?,
        parentThreadID: CodexStoredThreadID?,
        agentNickname: String?,
        agentRole: String?,
        gitInfo: CodexThreadGitInfo?
    ) {
        self.sessionID = sessionID
        self.forkedFromID = forkedFromID
        self.preview = preview
        self.ephemeral = ephemeral
        self.modelProvider = modelProvider
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.recencyAt = recencyAt
        self.path = path
        self.cwd = cwd
        self.cliVersion = cliVersion
        self.source = source
        self.threadSource = threadSource
        self.parentThreadID = parentThreadID
        self.agentNickname = agentNickname
        self.agentRole = agentRole
        self.gitInfo = gitInfo
    }

    private enum CodingKeys: String, CodingKey {
        case sessionID = "sessionId"
        case forkedFromID = "forkedFromId"
        case preview
        case ephemeral
        case modelProvider
        case createdAt
        case updatedAt
        case recencyAt
        case path
        case cwd
        case cliVersion
        case source
        case threadSource
        case parentThreadID = "parentThreadId"
        case agentNickname
        case agentRole
        case gitInfo
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionID = try container.decode(String.self, forKey: .sessionID)
        forkedFromID = try container.decodeIfPresent(
            CodexStoredThreadID.self,
            forKey: .forkedFromID
        )
        preview = try container.decode(String.self, forKey: .preview)
        ephemeral = try container.decode(Bool.self, forKey: .ephemeral)
        modelProvider = try container.decode(
            String.self,
            forKey: .modelProvider
        )
        createdAt = try container.decode(Int64.self, forKey: .createdAt)
        updatedAt = try container.decode(Int64.self, forKey: .updatedAt)
        recencyAt = try container.decodeIfPresent(
            Int64.self,
            forKey: .recencyAt
        )
        path = try container.decodeIfPresent(String.self, forKey: .path)
        cwd = try container.decode(String.self, forKey: .cwd)
        cliVersion = try container.decode(String.self, forKey: .cliVersion)
        source = try container.decode(
            CodexThreadSessionSource.self,
            forKey: .source
        )
        threadSource = try container.decodeIfPresent(
            String.self,
            forKey: .threadSource
        )
        parentThreadID = try container.decodeIfPresent(
            CodexStoredThreadID.self,
            forKey: .parentThreadID
        )
        agentNickname = try container.decodeIfPresent(
            String.self,
            forKey: .agentNickname
        )
        agentRole = try container.decodeIfPresent(
            String.self,
            forKey: .agentRole
        )
        gitInfo = try container.decodeIfPresent(
            CodexThreadGitInfo.self,
            forKey: .gitInfo
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sessionID, forKey: .sessionID)
        try container.encode(forkedFromID, forKey: .forkedFromID)
        try container.encode(preview, forKey: .preview)
        try container.encode(ephemeral, forKey: .ephemeral)
        try container.encode(modelProvider, forKey: .modelProvider)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encode(recencyAt, forKey: .recencyAt)
        try container.encode(path, forKey: .path)
        try container.encode(cwd, forKey: .cwd)
        try container.encode(cliVersion, forKey: .cliVersion)
        try container.encode(source, forKey: .source)
        try container.encode(threadSource, forKey: .threadSource)
        try container.encode(parentThreadID, forKey: .parentThreadID)
        try container.encode(agentNickname, forKey: .agentNickname)
        try container.encode(agentRole, forKey: .agentRole)
        try container.encode(gitInfo, forKey: .gitInfo)
    }
}

public enum TurnStatus: String, Codable, Sendable {
    case queued
    case running
    case completed
    case failed
    case cancelled
}

public struct Turn: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let threadID: UUID
    public var status: TurnStatus

    public init(id: UUID, threadID: UUID, status: TurnStatus) {
        self.id = id
        self.threadID = threadID
        self.status = status
    }
}

public enum ThreadItemKind: String, Codable, Sendable {
    case userMessage
    case assistantMessage
    case reasoning
    case toolCall
    case toolResult
    case approval
    case fileChange
    case terminal
    case contextCompaction
    case error
}

public struct ThreadItem: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let threadID: UUID
    public let turnID: UUID
    public let kind: ThreadItemKind
    public var text: String

    public init(
        id: UUID,
        threadID: UUID,
        turnID: UUID,
        kind: ThreadItemKind,
        text: String
    ) {
        self.id = id
        self.threadID = threadID
        self.turnID = turnID
        self.kind = kind
        self.text = text
    }
}

public enum ApprovalStatus: String, Codable, Sendable {
    case requested
    case approved
    case declined
    case cancelled
}

public struct Approval: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let turnID: UUID
    public let itemID: UUID
    public var title: String
    public var details: String
    public var status: ApprovalStatus

    public init(
        id: UUID,
        turnID: UUID,
        itemID: UUID,
        title: String,
        details: String,
        status: ApprovalStatus
    ) {
        self.id = id
        self.turnID = turnID
        self.itemID = itemID
        self.title = title
        self.details = details
        self.status = status
    }
}

public enum ThreadGoalStatus: String, CaseIterable, Codable, Sendable {
    case active
    case paused
    case blocked
    case usageLimited
    case budgetLimited
    case complete

    public var displayName: String {
        switch self {
        case .active: "Active"
        case .paused: "Paused"
        case .blocked: "Blocked"
        case .usageLimited: "Usage limited"
        case .budgetLimited: "Budget limited"
        case .complete: "Complete"
        }
    }
}

public struct ThreadGoal: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID { threadID }
    public let threadID: UUID
    public var objective: String
    public var status: ThreadGoalStatus
    public var tokenBudget: Int64?
    public var tokensUsed: Int64
    public var timeUsedSeconds: Int64
    public let createdAt: Int64
    public var updatedAt: Int64

    public init(
        threadID: UUID,
        objective: String,
        status: ThreadGoalStatus,
        tokenBudget: Int64?,
        tokensUsed: Int64,
        timeUsedSeconds: Int64,
        createdAt: Int64,
        updatedAt: Int64
    ) {
        self.threadID = threadID
        self.objective = objective
        self.status = status
        self.tokenBudget = tokenBudget
        self.tokensUsed = tokensUsed
        self.timeUsedSeconds = timeUsedSeconds
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public enum ThreadApprovalPolicy: String, Codable, Sendable {
    case untrusted
    case onRequest = "on-request"
    case never
}

public enum ThreadSandboxPolicy: String, Codable, Sendable {
    case readOnly
    case workspaceWrite
    case dangerFullAccess
}

public struct ThreadSettings: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID { threadID }
    public let threadID: UUID
    public var cwd: String
    public var model: String
    public var modelProvider: String
    public var effort: CodexReasoningEffort?
    public var approvalPolicy: ThreadApprovalPolicy
    public var approvalsReviewer: String
    public var collaborationMode: String
    public var sandboxPolicy: ThreadSandboxPolicy

    public init(
        threadID: UUID,
        cwd: String,
        model: String,
        modelProvider: String = "openai",
        effort: CodexReasoningEffort?,
        approvalPolicy: ThreadApprovalPolicy,
        approvalsReviewer: String = "user",
        collaborationMode: String = "default",
        sandboxPolicy: ThreadSandboxPolicy
    ) {
        self.threadID = threadID
        self.cwd = cwd
        self.model = model
        self.modelProvider = modelProvider
        self.effort = effort
        self.approvalPolicy = approvalPolicy
        self.approvalsReviewer = approvalsReviewer
        self.collaborationMode = collaborationMode
        self.sandboxPolicy = sandboxPolicy
    }
}

public struct DomainEvent: Codable, Equatable, Identifiable, Sendable {
    public enum Payload: Codable, Equatable, Sendable {
        case workspaceUpserted(Workspace)
        case workspaceRemoved(workspaceID: UUID)
        case threadUpserted(CodexThread)
        case threadNameUpdated(threadID: UUID, name: String)
        case threadArchived(threadID: UUID)
        case threadUnarchived(threadID: UUID)
        case threadDeleted(threadID: UUID)
        case threadGoalUpdated(ThreadGoal)
        case threadGoalCleared(threadID: UUID)
        case threadSettingsUpdated(ThreadSettings)
        case threadMetadataChanged(threadID: CodexStoredThreadID)
        case threadQueueChanged(
            threadID: UUID,
            submissions: [CodexQueuedSubmission]
        )
        case threadRolledBack(threadID: UUID, removedTurnIDs: [UUID])
        case turnStarted(Turn)
        case turnStatusChanged(turnID: UUID, status: TurnStatus)
        case itemAppended(ThreadItem)
        case approvalRequested(Approval)
        case approvalResolved(approvalID: UUID, status: ApprovalStatus)
    }

    public var id: Int64 { sequence }
    public let sequence: Int64
    public let payload: Payload

    public init(sequence: Int64, payload: Payload) {
        self.sequence = sequence
        self.payload = payload
    }
}
