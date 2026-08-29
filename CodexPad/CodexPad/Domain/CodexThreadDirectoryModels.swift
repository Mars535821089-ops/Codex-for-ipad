import Foundation

public struct CodexStoredThreadID:
    RawRepresentable,
    Codable,
    Equatable,
    Hashable,
    Sendable
{
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        rawValue = try container.decode(String.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public enum CodexWireOptional<Value>: Equatable, Sendable
where Value: Equatable & Sendable {
    case omitted
    case null
    case value(Value)
}

public enum CodexPatchField<Value>: Equatable, Sendable
where Value: Equatable & Sendable {
    case keep
    case clear
    case set(Value)
}

public enum CodexThreadDirectoryModelError:
    Error,
    Equatable,
    Sendable
{
    case emptyGitInfoPatch
    case blankGitInfoValue
}

public enum CodexThreadSortKey: String, Codable, Equatable, Sendable {
    case createdAt = "created_at"
    case updatedAt = "updated_at"
    case recencyAt = "recency_at"
}

public enum CodexThreadSortDirection: String, Codable, Equatable, Sendable {
    case ascending = "asc"
    case descending = "desc"
}

public enum CodexThreadSourceKind: String, Codable, Equatable, Sendable {
    case cli
    case vscode
    case exec
    case appServer
    case subAgent
    case subAgentReview
    case subAgentCompact
    case subAgentThreadSpawn
    case subAgentOther
    case unknown
}

public enum CodexThreadCWDFilter: Equatable, Sendable {
    case one(String)
    case many([String])
}

public struct CodexThreadListParams: Equatable, Sendable {
    public var cursor: CodexWireOptional<String>
    public var limit: CodexWireOptional<UInt32>
    public var sortKey: CodexWireOptional<CodexThreadSortKey>
    public var sortDirection: CodexWireOptional<CodexThreadSortDirection>
    public var modelProviders: CodexWireOptional<[String]>
    public var sourceKinds: CodexWireOptional<[CodexThreadSourceKind]>
    public var archived: CodexWireOptional<Bool>
    public var isPinned: CodexWireOptional<Bool>
    public var cwd: CodexWireOptional<CodexThreadCWDFilter>
    public var useStateDbOnly: Bool?
    public var searchTerm: CodexWireOptional<String>
    public var parentThreadID: CodexWireOptional<String>
    public var ancestorThreadID: CodexWireOptional<String>
    public var sectionId: CodexWireOptional<String>

    public init(
        cursor: CodexWireOptional<String> = .omitted,
        limit: CodexWireOptional<UInt32> = .omitted,
        sortKey: CodexWireOptional<CodexThreadSortKey> = .omitted,
        sortDirection: CodexWireOptional<CodexThreadSortDirection> = .omitted,
        modelProviders: CodexWireOptional<[String]> = .omitted,
        sourceKinds: CodexWireOptional<[CodexThreadSourceKind]> = .omitted,
        archived: CodexWireOptional<Bool> = .omitted,
        isPinned: CodexWireOptional<Bool> = .omitted,
        cwd: CodexWireOptional<CodexThreadCWDFilter> = .omitted,
        useStateDbOnly: Bool? = nil,
        searchTerm: CodexWireOptional<String> = .omitted,
        parentThreadID: CodexWireOptional<String> = .omitted,
        ancestorThreadID: CodexWireOptional<String> = .omitted,
        sectionId: CodexWireOptional<String> = .omitted
    ) {
        self.cursor = cursor
        self.limit = limit
        self.sortKey = sortKey
        self.sortDirection = sortDirection
        self.modelProviders = modelProviders
        self.sourceKinds = sourceKinds
        self.archived = archived
        self.isPinned = isPinned
        self.cwd = cwd
        self.useStateDbOnly = useStateDbOnly
        self.searchTerm = searchTerm
        self.parentThreadID = parentThreadID
        self.ancestorThreadID = ancestorThreadID
        self.sectionId = sectionId
    }
}

public struct CodexThreadReadParams: Equatable, Sendable {
    public var threadID: CodexStoredThreadID
    public var includeTurns: Bool?

    public init(
        threadID: CodexStoredThreadID,
        includeTurns: Bool? = nil
    ) {
        self.threadID = threadID
        self.includeTurns = includeTurns
    }
}

public enum CodexAppServerAskForApproval:
    Codable,
    Equatable,
    Sendable
{
    case untrusted
    case onRequest
    case granular(CodexAppServerGranularApproval)
    case never

    private enum CodingKeys: String, CodingKey {
        case granular
    }

    public init(from decoder: any Decoder) throws {
        let singleValue = try decoder.singleValueContainer()
        if let value = try? singleValue.decode(String.self) {
            switch value {
            case "untrusted":
                self = .untrusted
            case "on-request":
                self = .onRequest
            case "never":
                self = .never
            default:
                throw DecodingError.dataCorruptedError(
                    in: singleValue,
                    debugDescription:
                        "Unknown AskForApproval value \(value)"
                )
            }
            return
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        self = .granular(
            try container.decode(
                CodexAppServerGranularApproval.self,
                forKey: .granular
            )
        )
    }

    public func encode(to encoder: any Encoder) throws {
        switch self {
        case .untrusted:
            var container = encoder.singleValueContainer()
            try container.encode("untrusted")
        case .onRequest:
            var container = encoder.singleValueContainer()
            try container.encode("on-request")
        case let .granular(granular):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(granular, forKey: .granular)
        case .never:
            var container = encoder.singleValueContainer()
            try container.encode("never")
        }
    }
}

public struct CodexAppServerGranularApproval:
    Codable,
    Equatable,
    Sendable
{
    public var sandboxApproval: Bool
    public var rules: Bool
    public var skillApproval: Bool
    public var requestPermissions: Bool
    public var mcpElicitations: Bool

    public init(
        sandboxApproval: Bool,
        rules: Bool,
        skillApproval: Bool = false,
        requestPermissions: Bool = false,
        mcpElicitations: Bool
    ) {
        self.sandboxApproval = sandboxApproval
        self.rules = rules
        self.skillApproval = skillApproval
        self.requestPermissions = requestPermissions
        self.mcpElicitations = mcpElicitations
    }

    private enum CodingKeys: String, CodingKey {
        case sandboxApproval = "sandbox_approval"
        case rules
        case skillApproval = "skill_approval"
        case requestPermissions = "request_permissions"
        case mcpElicitations = "mcp_elicitations"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sandboxApproval = try container.decode(
            Bool.self,
            forKey: .sandboxApproval
        )
        rules = try container.decode(Bool.self, forKey: .rules)
        skillApproval = if container.contains(.skillApproval) {
            try container.decode(Bool.self, forKey: .skillApproval)
        } else {
            false
        }
        requestPermissions = if container.contains(.requestPermissions) {
            try container.decode(Bool.self, forKey: .requestPermissions)
        } else {
            false
        }
        mcpElicitations = try container.decode(
            Bool.self,
            forKey: .mcpElicitations
        )
    }
}

public enum CodexAppServerApprovalsReviewer:
    String,
    Codable,
    Equatable,
    Sendable
{
    case user
    case autoReview = "auto_review"
    case guardianSubagent = "guardian_subagent"
}

public enum CodexAppServerSandboxMode:
    String,
    Codable,
    Equatable,
    Sendable
{
    case readOnly = "read-only"
    case workspaceWrite = "workspace-write"
    case dangerFullAccess = "danger-full-access"
}

public enum CodexAppServerPersonality:
    String,
    Codable,
    Equatable,
    Sendable
{
    case none
    case friendly
    case pragmatic
}

public enum CodexAppServerReasoningSummary:
    String,
    Codable,
    Equatable,
    Sendable
{
    case auto
    case concise
    case detailed
    case none
}

public struct CodexActivePermissionProfile:
    Codable,
    Equatable,
    Sendable
{
    public var id: String
    public var extends: String?

    public init(id: String, extends: String?) {
        self.id = id
        self.extends = extends
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case extends
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        extends = try container.decodeIfPresent(
            String.self,
            forKey: .extends
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        if let extends {
            try container.encode(extends, forKey: .extends)
        } else {
            try container.encodeNil(forKey: .extends)
        }
    }
}

public enum CodexCollaborationModeKind:
    String,
    Codable,
    Equatable,
    Sendable
{
    case plan
    case `default`
}

public struct CodexCollaborationModeSettings:
    Codable,
    Equatable,
    Sendable
{
    public var model: String
    public var reasoningEffort: String?
    public var developerInstructions: String?

    public init(
        model: String,
        reasoningEffort: String?,
        developerInstructions: String?
    ) {
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.developerInstructions = developerInstructions
    }

    private enum CodingKeys: String, CodingKey {
        case model
        case reasoningEffort = "reasoning_effort"
        case developerInstructions = "developer_instructions"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        model = try container.decode(String.self, forKey: .model)
        reasoningEffort = try container.decodeIfPresent(
            String.self,
            forKey: .reasoningEffort
        )
        developerInstructions = try container.decodeIfPresent(
            String.self,
            forKey: .developerInstructions
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(model, forKey: .model)
        if let reasoningEffort {
            try container.encode(
                reasoningEffort,
                forKey: .reasoningEffort
            )
        } else {
            try container.encodeNil(forKey: .reasoningEffort)
        }
        if let developerInstructions {
            try container.encode(
                developerInstructions,
                forKey: .developerInstructions
            )
        } else {
            try container.encodeNil(forKey: .developerInstructions)
        }
    }
}

public struct CodexCollaborationMode:
    Codable,
    Equatable,
    Sendable
{
    public var mode: CodexCollaborationModeKind
    public var settings: CodexCollaborationModeSettings

    public init(
        mode: CodexCollaborationModeKind,
        settings: CodexCollaborationModeSettings
    ) {
        self.mode = mode
        self.settings = settings
    }
}

public enum CodexMultiAgentMode:
    Codable,
    Equatable,
    Sendable
{
    case explicitRequestOnly
    case proactive
    case custom(String)

    private enum CodingKeys: String, CodingKey {
        case custom
    }

    public init(from decoder: any Decoder) throws {
        let singleValue = try decoder.singleValueContainer()
        if let value = try? singleValue.decode(String.self) {
            switch value {
            case "explicitRequestOnly":
                self = .explicitRequestOnly
            case "proactive":
                self = .proactive
            default:
                throw DecodingError.dataCorruptedError(
                    in: singleValue,
                    debugDescription:
                        "Unknown MultiAgentMode value \(value)"
                )
            }
            return
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        self = .custom(
            try container.decode(String.self, forKey: .custom)
        )
    }

    public func encode(to encoder: any Encoder) throws {
        switch self {
        case .explicitRequestOnly:
            var container = encoder.singleValueContainer()
            try container.encode("explicitRequestOnly")
        case .proactive:
            var container = encoder.singleValueContainer()
            try container.encode("proactive")
        case let .custom(value):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(value, forKey: .custom)
        }
    }
}

public struct CodexThreadSettingsUpdateParams:
    Equatable,
    Sendable
{
    public var threadID: CodexStoredThreadID
    public var cwd: CodexWireOptional<String>
    public var approvalPolicy:
        CodexWireOptional<CodexAppServerAskForApproval>
    public var approvalsReviewer:
        CodexWireOptional<CodexAppServerApprovalsReviewer>
    public var sandboxPolicy:
        CodexWireOptional<CodexAppServerSandboxPolicy>
    public var permissions: CodexWireOptional<String>
    public var model: CodexWireOptional<String>
    public var serviceTier: CodexWireOptional<String>
    public var effort: CodexWireOptional<String>
    public var summary:
        CodexWireOptional<CodexAppServerReasoningSummary>
    public var collaborationMode:
        CodexWireOptional<CodexCollaborationMode>
    public var multiAgentMode:
        CodexWireOptional<CodexMultiAgentMode>
    public var personality:
        CodexWireOptional<CodexAppServerPersonality>

    public init(
        threadID: CodexStoredThreadID,
        cwd: CodexWireOptional<String> = .omitted,
        approvalPolicy:
            CodexWireOptional<CodexAppServerAskForApproval> = .omitted,
        approvalsReviewer:
            CodexWireOptional<CodexAppServerApprovalsReviewer> = .omitted,
        sandboxPolicy:
            CodexWireOptional<CodexAppServerSandboxPolicy> = .omitted,
        permissions: CodexWireOptional<String> = .omitted,
        model: CodexWireOptional<String> = .omitted,
        serviceTier: CodexWireOptional<String> = .omitted,
        effort: CodexWireOptional<String> = .omitted,
        summary:
            CodexWireOptional<CodexAppServerReasoningSummary> = .omitted,
        collaborationMode:
            CodexWireOptional<CodexCollaborationMode> = .omitted,
        multiAgentMode:
            CodexWireOptional<CodexMultiAgentMode> = .omitted,
        personality:
            CodexWireOptional<CodexAppServerPersonality> = .omitted
    ) {
        self.threadID = threadID
        self.cwd = cwd
        self.approvalPolicy = approvalPolicy
        self.approvalsReviewer = approvalsReviewer
        self.sandboxPolicy = sandboxPolicy
        self.permissions = permissions
        self.model = model
        self.serviceTier = serviceTier
        self.effort = effort
        self.summary = summary
        self.collaborationMode = collaborationMode
        self.multiAgentMode = multiAgentMode
        self.personality = personality
    }
}

public struct CodexThreadSettingsUpdateResponse:
    Codable,
    Equatable,
    Sendable
{
    public init() {}
}

public enum CodexThreadMemoryMode:
    String,
    Codable,
    Equatable,
    Sendable
{
    case enabled
    case disabled
}

public struct CodexThreadMemoryModeSetParams:
    Equatable,
    Sendable
{
    public var threadID: CodexStoredThreadID
    public var mode: CodexThreadMemoryMode

    public init(
        threadID: CodexStoredThreadID,
        mode: CodexThreadMemoryMode
    ) {
        self.threadID = threadID
        self.mode = mode
    }
}

public struct CodexAppServerThreadSettings:
    Codable,
    Equatable,
    Sendable
{
    public var cwd: String
    public var approvalPolicy: CodexAppServerAskForApproval
    public var approvalsReviewer: CodexAppServerApprovalsReviewer
    public var sandboxPolicy: CodexAppServerSandboxPolicy
    public var activePermissionProfile: CodexActivePermissionProfile?
    public var model: String
    public var modelProvider: String
    public var serviceTier: String?
    public var effort: String?
    public var summary: CodexAppServerReasoningSummary?
    public var collaborationMode: CodexCollaborationMode
    public var multiAgentMode: CodexMultiAgentMode
    public var personality: CodexAppServerPersonality?

    public init(
        cwd: String,
        approvalPolicy: CodexAppServerAskForApproval,
        approvalsReviewer: CodexAppServerApprovalsReviewer,
        sandboxPolicy: CodexAppServerSandboxPolicy,
        activePermissionProfile: CodexActivePermissionProfile?,
        model: String,
        modelProvider: String,
        serviceTier: String?,
        effort: String?,
        summary: CodexAppServerReasoningSummary?,
        collaborationMode: CodexCollaborationMode,
        multiAgentMode: CodexMultiAgentMode,
        personality: CodexAppServerPersonality?
    ) {
        self.cwd = cwd
        self.approvalPolicy = approvalPolicy
        self.approvalsReviewer = approvalsReviewer
        self.sandboxPolicy = sandboxPolicy
        self.activePermissionProfile = activePermissionProfile
        self.model = model
        self.modelProvider = modelProvider
        self.serviceTier = serviceTier
        self.effort = effort
        self.summary = summary
        self.collaborationMode = collaborationMode
        self.multiAgentMode = multiAgentMode
        self.personality = personality
    }

    private enum CodingKeys: String, CodingKey {
        case cwd
        case approvalPolicy
        case approvalsReviewer
        case sandboxPolicy
        case activePermissionProfile
        case model
        case modelProvider
        case serviceTier
        case effort
        case summary
        case collaborationMode
        case multiAgentMode
        case personality
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        cwd = try container.decode(String.self, forKey: .cwd)
        approvalPolicy = try container.decode(
            CodexAppServerAskForApproval.self,
            forKey: .approvalPolicy
        )
        approvalsReviewer = try container.decode(
            CodexAppServerApprovalsReviewer.self,
            forKey: .approvalsReviewer
        )
        sandboxPolicy = try container.decode(
            CodexAppServerSandboxPolicy.self,
            forKey: .sandboxPolicy
        )
        activePermissionProfile = try container.decodeIfPresent(
            CodexActivePermissionProfile.self,
            forKey: .activePermissionProfile
        )
        model = try container.decode(String.self, forKey: .model)
        modelProvider = try container.decode(
            String.self,
            forKey: .modelProvider
        )
        serviceTier = try container.decodeIfPresent(
            String.self,
            forKey: .serviceTier
        )
        effort = try container.decodeIfPresent(
            String.self,
            forKey: .effort
        )
        summary = try container.decodeIfPresent(
            CodexAppServerReasoningSummary.self,
            forKey: .summary
        )
        collaborationMode = try container.decode(
            CodexCollaborationMode.self,
            forKey: .collaborationMode
        )
        multiAgentMode = try container.decodeIfPresent(
            CodexMultiAgentMode.self,
            forKey: .multiAgentMode
        ) ?? .explicitRequestOnly
        personality = try container.decodeIfPresent(
            CodexAppServerPersonality.self,
            forKey: .personality
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(cwd, forKey: .cwd)
        try container.encode(approvalPolicy, forKey: .approvalPolicy)
        try container.encode(
            approvalsReviewer,
            forKey: .approvalsReviewer
        )
        try container.encode(sandboxPolicy, forKey: .sandboxPolicy)
        if let activePermissionProfile {
            try container.encode(
                activePermissionProfile,
                forKey: .activePermissionProfile
            )
        } else {
            try container.encodeNil(forKey: .activePermissionProfile)
        }
        try container.encode(model, forKey: .model)
        try container.encode(modelProvider, forKey: .modelProvider)
        if let serviceTier {
            try container.encode(serviceTier, forKey: .serviceTier)
        } else {
            try container.encodeNil(forKey: .serviceTier)
        }
        if let effort {
            try container.encode(effort, forKey: .effort)
        } else {
            try container.encodeNil(forKey: .effort)
        }
        if let summary {
            try container.encode(summary, forKey: .summary)
        } else {
            try container.encodeNil(forKey: .summary)
        }
        try container.encode(
            collaborationMode,
            forKey: .collaborationMode
        )
        try container.encode(multiAgentMode, forKey: .multiAgentMode)
        if let personality {
            try container.encode(personality, forKey: .personality)
        } else {
            try container.encodeNil(forKey: .personality)
        }
    }
}

public struct CodexThreadSettingsUpdatedNotification:
    Codable,
    Equatable,
    Sendable
{
    public var threadID: CodexStoredThreadID
    public var threadSettings: CodexAppServerThreadSettings

    public init(
        threadID: CodexStoredThreadID,
        threadSettings: CodexAppServerThreadSettings
    ) {
        self.threadID = threadID
        self.threadSettings = threadSettings
    }

    private enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case threadSettings
    }
}

public struct CodexThreadResumeParams: Equatable, Sendable {
    public var threadID: CodexStoredThreadID
    public var model: CodexWireOptional<String>
    public var modelProvider: CodexWireOptional<String>
    public var serviceTier: CodexWireOptional<String>
    public var cwd: CodexWireOptional<String>
    public var approvalPolicy:
        CodexWireOptional<CodexAppServerAskForApproval>
    public var approvalsReviewer:
        CodexWireOptional<CodexAppServerApprovalsReviewer>
    public var sandbox: CodexWireOptional<CodexAppServerSandboxMode>
    public var config:
        CodexWireOptional<[String: CodexJSONValue]>
    public var baseInstructions: CodexWireOptional<String>
    public var developerInstructions: CodexWireOptional<String>
    public var personality:
        CodexWireOptional<CodexAppServerPersonality>

    public init(
        threadID: CodexStoredThreadID,
        model: CodexWireOptional<String> = .omitted,
        modelProvider: CodexWireOptional<String> = .omitted,
        serviceTier: CodexWireOptional<String> = .omitted,
        cwd: CodexWireOptional<String> = .omitted,
        approvalPolicy:
            CodexWireOptional<CodexAppServerAskForApproval> = .omitted,
        approvalsReviewer:
            CodexWireOptional<CodexAppServerApprovalsReviewer> = .omitted,
        sandbox:
            CodexWireOptional<CodexAppServerSandboxMode> = .omitted,
        config:
            CodexWireOptional<[String: CodexJSONValue]> = .omitted,
        baseInstructions: CodexWireOptional<String> = .omitted,
        developerInstructions: CodexWireOptional<String> = .omitted,
        personality:
            CodexWireOptional<CodexAppServerPersonality> = .omitted
    ) {
        self.threadID = threadID
        self.model = model
        self.modelProvider = modelProvider
        self.serviceTier = serviceTier
        self.cwd = cwd
        self.approvalPolicy = approvalPolicy
        self.approvalsReviewer = approvalsReviewer
        self.sandbox = sandbox
        self.config = config
        self.baseInstructions = baseInstructions
        self.developerInstructions = developerInstructions
        self.personality = personality
    }
}

public struct CodexThreadForkParams: Equatable, Sendable {
    public var resume: CodexThreadResumeParams
    public var lastTurnID: CodexWireOptional<String>
    public var path: CodexWireOptional<String>
    public var ephemeral: Bool?
    public var threadSource: CodexWireOptional<String>
    public var excludeTurns: Bool?

    public init(
        threadID: CodexStoredThreadID,
        lastTurnID: CodexWireOptional<String> = .omitted,
        path: CodexWireOptional<String> = .omitted,
        model: CodexWireOptional<String> = .omitted,
        modelProvider: CodexWireOptional<String> = .omitted,
        serviceTier: CodexWireOptional<String> = .omitted,
        cwd: CodexWireOptional<String> = .omitted,
        approvalPolicy:
            CodexWireOptional<CodexAppServerAskForApproval> = .omitted,
        approvalsReviewer:
            CodexWireOptional<CodexAppServerApprovalsReviewer> = .omitted,
        sandbox:
            CodexWireOptional<CodexAppServerSandboxMode> = .omitted,
        config:
            CodexWireOptional<[String: CodexJSONValue]> = .omitted,
        baseInstructions: CodexWireOptional<String> = .omitted,
        developerInstructions: CodexWireOptional<String> = .omitted,
        ephemeral: Bool? = nil,
        threadSource: CodexWireOptional<String> = .omitted,
        excludeTurns: Bool? = nil
    ) {
        resume = CodexThreadResumeParams(
            threadID: threadID,
            model: model,
            modelProvider: modelProvider,
            serviceTier: serviceTier,
            cwd: cwd,
            approvalPolicy: approvalPolicy,
            approvalsReviewer: approvalsReviewer,
            sandbox: sandbox,
            config: config,
            baseInstructions: baseInstructions,
            developerInstructions: developerInstructions
        )
        self.lastTurnID = lastTurnID
        self.path = path
        self.ephemeral = ephemeral
        self.threadSource = threadSource
        self.excludeTurns = excludeTurns
    }

    public var threadID: CodexStoredThreadID {
        resume.threadID
    }
}

public struct CodexThreadStartParams: Equatable, Sendable {
    public var mode: CodexWireOptional<String>
    public var model: CodexWireOptional<String>
    public var modelProvider: CodexWireOptional<String>
    public var serviceTier: CodexWireOptional<String>
    public var cwd: CodexWireOptional<String>
    public var approvalPolicy: CodexWireOptional<CodexAppServerAskForApproval>
    public var approvalsReviewer: CodexWireOptional<CodexAppServerApprovalsReviewer>
    public var sandbox: CodexWireOptional<CodexAppServerSandboxMode>
    public var config: CodexWireOptional<[String: CodexJSONValue]>
    public var serviceName: CodexWireOptional<String>
    public var baseInstructions: CodexWireOptional<String>
    public var developerInstructions: CodexWireOptional<String>
    public var personality: CodexWireOptional<CodexAppServerPersonality>
    public var ephemeral: CodexWireOptional<Bool>
    public var sessionStartSource: CodexWireOptional<String>
    public var threadSource: CodexWireOptional<String>
    public var allowProviderModelFallback: CodexWireOptional<Bool>
    public var dynamicTools: CodexWireOptional<[CodexJSONValue]>
    public var environments: CodexWireOptional<[CodexJSONValue]>
    public var experimentalRawEvents: CodexWireOptional<Bool>
    public var historyMode: CodexWireOptional<CodexThreadHistoryMode>
    public var mockExperimentalField: CodexWireOptional<String>
    public var multiAgentMode: CodexWireOptional<CodexMultiAgentMode>
    public var permissions: CodexWireOptional<String>
    public var runtimeWorkspaceRoots: CodexWireOptional<[String]>
    public var selectedCapabilityRoots: CodexWireOptional<[CodexJSONValue]>
    public var threadStartKind: CodexWireOptional<String>

    public init(
        model: CodexWireOptional<String> = .omitted,
        modelProvider: CodexWireOptional<String> = .omitted,
        serviceTier: CodexWireOptional<String> = .omitted,
        cwd: CodexWireOptional<String> = .omitted,
        approvalPolicy: CodexWireOptional<CodexAppServerAskForApproval> = .omitted,
        approvalsReviewer: CodexWireOptional<CodexAppServerApprovalsReviewer> = .omitted,
        sandbox: CodexWireOptional<CodexAppServerSandboxMode> = .omitted,
        config: CodexWireOptional<[String: CodexJSONValue]> = .omitted,
        serviceName: CodexWireOptional<String> = .omitted,
        baseInstructions: CodexWireOptional<String> = .omitted,
        developerInstructions: CodexWireOptional<String> = .omitted,
        personality: CodexWireOptional<CodexAppServerPersonality> = .omitted,
        ephemeral: CodexWireOptional<Bool> = .omitted,
        sessionStartSource: CodexWireOptional<String> = .omitted,
        threadSource: CodexWireOptional<String> = .omitted,
        allowProviderModelFallback: CodexWireOptional<Bool> = .omitted,
        dynamicTools: CodexWireOptional<[CodexJSONValue]> = .omitted,
        environments: CodexWireOptional<[CodexJSONValue]> = .omitted,
        experimentalRawEvents: CodexWireOptional<Bool> = .omitted,
        historyMode: CodexWireOptional<CodexThreadHistoryMode> = .omitted,
        mockExperimentalField: CodexWireOptional<String> = .omitted,
        mode: CodexWireOptional<String> = .omitted,
        multiAgentMode: CodexWireOptional<CodexMultiAgentMode> = .omitted,
        permissions: CodexWireOptional<String> = .omitted,
        runtimeWorkspaceRoots: CodexWireOptional<[String]> = .omitted,
        selectedCapabilityRoots: CodexWireOptional<[CodexJSONValue]> = .omitted,
        threadStartKind: CodexWireOptional<String> = .omitted
    ) {
        self.mode = mode
        self.model = model
        self.modelProvider = modelProvider
        self.serviceTier = serviceTier
        self.cwd = cwd
        self.approvalPolicy = approvalPolicy
        self.approvalsReviewer = approvalsReviewer
        self.sandbox = sandbox
        self.config = config
        self.serviceName = serviceName
        self.baseInstructions = baseInstructions
        self.developerInstructions = developerInstructions
        self.personality = personality
        self.ephemeral = ephemeral
        self.sessionStartSource = sessionStartSource
        self.threadSource = threadSource
        self.allowProviderModelFallback = allowProviderModelFallback
        self.dynamicTools = dynamicTools
        self.environments = environments
        self.experimentalRawEvents = experimentalRawEvents
        self.historyMode = historyMode
        self.mockExperimentalField = mockExperimentalField
        self.multiAgentMode = multiAgentMode
        self.permissions = permissions
        self.runtimeWorkspaceRoots = runtimeWorkspaceRoots
        self.selectedCapabilityRoots = selectedCapabilityRoots
        self.threadStartKind = threadStartKind
    }
}

public struct CodexThreadSearchParams: Equatable, Sendable {
    public var cursor: CodexWireOptional<String>
    public var limit: CodexWireOptional<UInt32>
    public var sortKey: CodexWireOptional<CodexThreadSortKey>
    public var sortDirection: CodexWireOptional<CodexThreadSortDirection>
    public var sourceKinds: CodexWireOptional<[CodexThreadSourceKind]>
    public var archived: CodexWireOptional<Bool>
    public var searchTerm: String

    public init(
        cursor: CodexWireOptional<String> = .omitted,
        limit: CodexWireOptional<UInt32> = .omitted,
        sortKey: CodexWireOptional<CodexThreadSortKey> = .omitted,
        sortDirection: CodexWireOptional<CodexThreadSortDirection> = .omitted,
        sourceKinds: CodexWireOptional<[CodexThreadSourceKind]> = .omitted,
        archived: CodexWireOptional<Bool> = .omitted,
        searchTerm: String
    ) {
        self.cursor = cursor
        self.limit = limit
        self.sortKey = sortKey
        self.sortDirection = sortDirection
        self.sourceKinds = sourceKinds
        self.archived = archived
        self.searchTerm = searchTerm
    }
}

public struct CodexThreadSection: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

public struct CodexThreadSectionListParams: Equatable, Sendable {
    public var cursor: CodexWireOptional<String>
    public var limit: CodexWireOptional<UInt32>

    public init(
        cursor: CodexWireOptional<String> = .omitted,
        limit: CodexWireOptional<UInt32> = .omitted
    ) {
        self.cursor = cursor
        self.limit = limit
    }
}

public struct CodexThreadSectionCreateParams: Equatable, Sendable {
    public let name: String

    public init(name: String) {
        self.name = name
    }
}

public struct CodexThreadSectionCreateResult: Codable, Equatable, Sendable {
    public let section: CodexThreadSection

    public init(section: CodexThreadSection) {
        self.section = section
    }
}

public struct CodexThreadSectionUpdateParams: Equatable, Sendable {
    public let sectionID: String
    public let name: String

    public init(sectionID: String, name: String) {
        self.sectionID = sectionID
        self.name = name
    }
}

public struct CodexThreadSectionUpdateResult: Codable, Equatable, Sendable {
    public let section: CodexThreadSection

    public init(section: CodexThreadSection) {
        self.section = section
    }
}

public struct CodexThreadSectionDeleteParams: Equatable, Sendable {
    public let sectionID: String

    public init(sectionID: String) {
        self.sectionID = sectionID
    }
}

public struct CodexThreadSectionMoveParams: Equatable, Sendable {
    public let threadID: CodexStoredThreadID
    public let sectionID: CodexWireOptional<String>
    public let beforeThreadID: CodexWireOptional<String>

    public init(
        threadID: CodexStoredThreadID,
        sectionID: CodexWireOptional<String>,
        beforeThreadID: CodexWireOptional<String> = .omitted
    ) {
        self.threadID = threadID
        self.sectionID = sectionID
        self.beforeThreadID = beforeThreadID
    }
}

public struct CodexThreadSectionPage:
    Codable,
    Equatable,
    Sendable
{
    public var data: [CodexThreadSection]
    public var nextCursor: String?

    public init(
        data: [CodexThreadSection],
        nextCursor: String?
    ) {
        self.data = data
        self.nextCursor = nextCursor
    }
}

public struct CodexThreadGitInfoPatch: Equatable, Sendable {
    public let sha: CodexPatchField<String>
    public let branch: CodexPatchField<String>
    public let originURL: CodexPatchField<String>

    public init(
        sha: CodexPatchField<String> = .keep,
        branch: CodexPatchField<String> = .keep,
        originURL: CodexPatchField<String> = .keep
    ) throws {
        guard sha != .keep || branch != .keep || originURL != .keep else {
            throw CodexThreadDirectoryModelError.emptyGitInfoPatch
        }
        for field in [sha, branch, originURL] {
            if case let .set(value) = field,
               value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                throw CodexThreadDirectoryModelError.blankGitInfoValue
            }
        }
        self.sha = sha
        self.branch = branch
        self.originURL = originURL
    }
}

public struct CodexThreadMetadataUpdateParams: Equatable, Sendable {
    public let threadID: CodexStoredThreadID
    public let gitInfo: CodexWireOptional<CodexThreadGitInfoPatch>
    public let isPinned: CodexWireOptional<Bool>
    public let sectionId: CodexWireOptional<String>

    public init(
        threadID: CodexStoredThreadID,
        gitInfo: CodexWireOptional<CodexThreadGitInfoPatch> = .omitted,
        isPinned: CodexWireOptional<Bool> = .omitted,
        sectionId: CodexWireOptional<String> = .omitted
    ) {
        self.threadID = threadID
        self.gitInfo = gitInfo
        self.isPinned = isPinned
        self.sectionId = sectionId
    }

    public init(
        threadID: CodexStoredThreadID,
        gitInfo: CodexThreadGitInfoPatch
    ) {
        self.init(threadID: threadID, gitInfo: .value(gitInfo))
    }
}

public struct CodexThreadGitInfo: Codable, Equatable, Sendable {
    public var sha: String?
    public var branch: String?
    public var originURL: String?

    public init(sha: String?, branch: String?, originURL: String?) {
        self.sha = sha
        self.branch = branch
        self.originURL = originURL
    }

    private enum CodingKeys: String, CodingKey {
        case sha
        case branch
        case originURL = "originUrl"
    }
}

public enum CodexThreadActiveFlag: String, Codable, Equatable, Sendable {
    case waitingOnApproval
    case waitingOnUserInput
}

public enum CodexStoredThreadStatus: Codable, Equatable, Sendable {
    case notLoaded
    case idle
    case systemError
    case active([CodexThreadActiveFlag])

    private enum CodingKeys: String, CodingKey {
        case type
        case activeFlags
    }

    private enum Kind: String, Codable {
        case notLoaded
        case idle
        case systemError
        case active
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .type) {
        case .notLoaded:
            self = .notLoaded
        case .idle:
            self = .idle
        case .systemError:
            self = .systemError
        case .active:
            self = .active(
                try container.decode(
                    [CodexThreadActiveFlag].self,
                    forKey: .activeFlags
                )
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .notLoaded:
            try container.encode(Kind.notLoaded, forKey: .type)
        case .idle:
            try container.encode(Kind.idle, forKey: .type)
        case .systemError:
            try container.encode(Kind.systemError, forKey: .type)
        case let .active(flags):
            try container.encode(Kind.active, forKey: .type)
            try container.encode(flags, forKey: .activeFlags)
        }
    }
}

public enum CodexJSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case integer(Int64)
    case number(Double)
    case string(String)
    case array([CodexJSONValue])
    case object([String: CodexJSONValue])

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .integer(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([CodexJSONValue].self) {
            self = .array(value)
        } else {
            self = .object(
                try container.decode([String: CodexJSONValue].self)
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case let .bool(value):
            try container.encode(value)
        case let .integer(value):
            try container.encode(value)
        case let .number(value):
            try container.encode(value)
        case let .string(value):
            try container.encode(value)
        case let .array(value):
            try container.encode(value)
        case let .object(value):
            try container.encode(value)
        }
    }
}

public enum CodexAppServerNetworkAccess:
    String,
    Codable,
    Equatable,
    Sendable
{
    case restricted
    case enabled
}

public enum CodexAppServerSandboxPolicy:
    Codable,
    Equatable,
    Sendable
{
    case dangerFullAccess
    case readOnly(networkAccess: Bool)
    case externalSandbox(networkAccess: CodexAppServerNetworkAccess)
    case workspaceWrite(
        writableRoots: [String],
        networkAccess: Bool,
        excludeTmpdirEnvVar: Bool,
        excludeSlashTmp: Bool
    )

    private enum CodingKeys: String, CodingKey {
        case type
        case writableRoots
        case networkAccess
        case excludeTmpdirEnvVar
        case excludeSlashTmp
    }

    private enum Kind: String, Codable {
        case dangerFullAccess
        case readOnly
        case externalSandbox
        case workspaceWrite
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func decodeOrDefault<Value: Decodable>(
            _ type: Value.Type,
            forKey key: CodingKeys,
            default defaultValue: Value
        ) throws -> Value {
            if container.contains(key) {
                return try container.decode(type, forKey: key)
            }
            return defaultValue
        }

        switch try container.decode(Kind.self, forKey: .type) {
        case .dangerFullAccess:
            self = .dangerFullAccess
        case .readOnly:
            self = .readOnly(
                networkAccess: try decodeOrDefault(
                    Bool.self,
                    forKey: .networkAccess,
                    default: false
                )
            )
        case .externalSandbox:
            self = .externalSandbox(
                networkAccess: try decodeOrDefault(
                    CodexAppServerNetworkAccess.self,
                    forKey: .networkAccess,
                    default: .restricted
                )
            )
        case .workspaceWrite:
            self = .workspaceWrite(
                writableRoots: try decodeOrDefault(
                    [String].self,
                    forKey: .writableRoots,
                    default: []
                ),
                networkAccess: try decodeOrDefault(
                    Bool.self,
                    forKey: .networkAccess,
                    default: false
                ),
                excludeTmpdirEnvVar: try decodeOrDefault(
                    Bool.self,
                    forKey: .excludeTmpdirEnvVar,
                    default: false
                ),
                excludeSlashTmp: try decodeOrDefault(
                    Bool.self,
                    forKey: .excludeSlashTmp,
                    default: false
                )
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .dangerFullAccess:
            try container.encode(Kind.dangerFullAccess, forKey: .type)
        case let .readOnly(networkAccess):
            try container.encode(Kind.readOnly, forKey: .type)
            try container.encode(networkAccess, forKey: .networkAccess)
        case let .externalSandbox(networkAccess):
            try container.encode(Kind.externalSandbox, forKey: .type)
            try container.encode(networkAccess, forKey: .networkAccess)
        case let .workspaceWrite(
            writableRoots,
            networkAccess,
            excludeTmpdirEnvVar,
            excludeSlashTmp
        ):
            try container.encode(Kind.workspaceWrite, forKey: .type)
            try container.encode(writableRoots, forKey: .writableRoots)
            try container.encode(networkAccess, forKey: .networkAccess)
            try container.encode(
                excludeTmpdirEnvVar,
                forKey: .excludeTmpdirEnvVar
            )
            try container.encode(
                excludeSlashTmp,
                forKey: .excludeSlashTmp
            )
        }
    }
}

public enum CodexStoredThreadItemKind:
    String,
    Codable,
    Equatable,
    Sendable
{
    case userMessage
    case hookPrompt
    case agentMessage
    case plan
    case reasoning
    case commandExecution
    case fileChange
    case mcpToolCall
    case dynamicToolCall
    case collabAgentToolCall
    case subAgentActivity
    case webSearch
    case imageView
    case sleep
    case imageGeneration
    case enteredReviewMode
    case exitedReviewMode
    case contextCompaction
}

public enum CodexStoredUserInputKind:
    String,
    Codable,
    Equatable,
    Sendable
{
    case text
    case image
    case localImage
    case audio
    case localAudio
    case skill
    case mention
}

public enum CodexMessagePhase: String, Codable, Equatable, Sendable {
    case commentary
    case finalAnswer = "final_answer"
}

public enum CodexCommandExecutionSource:
    String,
    Codable,
    Equatable,
    Sendable
{
    case agent
    case userShell
    case unifiedExecStartup
    case unifiedExecInteraction
}

public enum CodexCommandExecutionStatus:
    String,
    Codable,
    Equatable,
    Sendable
{
    case inProgress
    case completed
    case failed
    case declined
}

public enum CodexPatchApplyStatus:
    String,
    Codable,
    Equatable,
    Sendable
{
    case inProgress
    case completed
    case failed
    case declined
}

public enum CodexMCPToolCallStatus:
    String,
    Codable,
    Equatable,
    Sendable
{
    case inProgress
    case completed
    case failed
}

public enum CodexDynamicToolCallStatus:
    String,
    Codable,
    Equatable,
    Sendable
{
    case inProgress
    case completed
    case failed
}

public enum CodexCollabAgentTool:
    String,
    Codable,
    Equatable,
    Sendable
{
    case spawnAgent
    case sendInput
    case resumeAgent
    case wait
    case closeAgent
}

public enum CodexCollabAgentToolCallStatus:
    String,
    Codable,
    Equatable,
    Sendable
{
    case inProgress
    case completed
    case failed
}

public enum CodexSubAgentActivityKind:
    String,
    Codable,
    Equatable,
    Sendable
{
    case started
    case interacted
    case interrupted
}

public enum CodexImageDetail: String, Codable, Equatable, Sendable {
    case auto
    case low
    case high
    case original
}

public enum CodexStoredUserInput: Codable, Equatable, Sendable {
    case text(text: String, textElements: [CodexJSONValue])
    case image(detail: CodexImageDetail?, url: String)
    case localImage(detail: CodexImageDetail?, path: String)
    case audio(url: String)
    case localAudio(path: String)
    case skill(name: String, path: String)
    case mention(name: String, path: String)

    public var kind: CodexStoredUserInputKind {
        switch self {
        case .text: .text
        case .image: .image
        case .localImage: .localImage
        case .audio: .audio
        case .localAudio: .localAudio
        case .skill: .skill
        case .mention: .mention
        }
    }

    public init(from decoder: any Decoder) throws {
        self = try Self(
            wireValue: CodexJSONValue(from: decoder),
            codingPath: decoder.codingPath
        )
    }

    fileprivate init(
        wireValue: CodexJSONValue,
        codingPath: [any CodingKey]
    ) throws {
        let object = try CodexWireObject(
            wireValue,
            codingPath: codingPath
        )
        let kind = try object.requiredEnum(
            CodexStoredUserInputKind.self,
            for: "type"
        )
        switch kind {
        case .text:
            self = .text(
                text: try object.requiredString("text"),
                textElements:
                    try object.optionalArray("text_elements") ?? []
            )
        case .image:
            self = .image(
                detail: try object.optionalNullableEnum(
                    CodexImageDetail.self,
                    for: "detail"
                ),
                url: try object.requiredString("url")
            )
        case .localImage:
            self = .localImage(
                detail: try object.optionalNullableEnum(
                    CodexImageDetail.self,
                    for: "detail"
                ),
                path: try object.requiredString("path")
            )
        case .audio:
            self = .audio(url: try object.requiredString("url"))
        case .localAudio:
            self = .localAudio(path: try object.requiredString("path"))
        case .skill:
            self = .skill(
                name: try object.requiredString("name"),
                path: try object.requiredString("path")
            )
        case .mention:
            self = .mention(
                name: try object.requiredString("name"),
                path: try object.requiredString("path")
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var object: [String: CodexJSONValue]
        switch self {
        case let .text(text, textElements):
            object = [
                "type": .string(kind.rawValue),
                "text": .string(text),
                "text_elements": .array(textElements),
            ]
        case let .image(detail, url):
            object = [
                "type": .string(kind.rawValue),
                "url": .string(url),
            ]
            if let detail {
                object["detail"] = .string(detail.rawValue)
            }
        case let .localImage(detail, path):
            object = [
                "type": .string(kind.rawValue),
                "path": .string(path),
            ]
            if let detail {
                object["detail"] = .string(detail.rawValue)
            }
        case let .audio(url):
            object = [
                "type": .string(kind.rawValue),
                "url": .string(url),
            ]
        case let .localAudio(path):
            object = [
                "type": .string(kind.rawValue),
                "path": .string(path),
            ]
        case let .skill(name, path), let .mention(name, path):
            object = [
                "type": .string(kind.rawValue),
                "name": .string(name),
                "path": .string(path),
            ]
        }
        try CodexJSONValue.object(object).encode(to: encoder)
    }
}

public struct CodexQueuedSubmission:
    Codable,
    Equatable,
    Identifiable,
    Sendable
{
    public let id: String
    public let input: [CodexStoredUserInput]
    public let clientUserMessageID: String

    public init(
        id: String,
        input: [CodexStoredUserInput],
        clientUserMessageID: String
    ) {
        self.id = id
        self.input = input
        self.clientUserMessageID = clientUserMessageID
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case input
        case clientUserMessageID = "clientUserMessageId"
    }
}

public struct CodexThreadQueue: Codable, Equatable, Sendable {
    public let threadID: UUID
    public let submissions: [CodexQueuedSubmission]

    public init(
        threadID: UUID,
        submissions: [CodexQueuedSubmission]
    ) {
        self.threadID = threadID
        self.submissions = submissions
    }
}

public enum CodexStoredThreadItem:
    Codable,
    Equatable,
    Identifiable,
    Sendable
{
    case userMessage(
        id: String,
        clientID: String?,
        content: [CodexStoredUserInput]
    )
    case hookPrompt(id: String, fragments: [CodexJSONValue])
    case agentMessage(
        id: String,
        text: String,
        phase: CodexMessagePhase?,
        memoryCitation: CodexJSONValue?
    )
    case plan(id: String, text: String)
    case reasoning(id: String, summary: [String], content: [String])
    case commandExecution(
        id: String,
        command: String,
        cwd: String,
        processID: String?,
        source: CodexCommandExecutionSource,
        status: CodexCommandExecutionStatus,
        commandActions: [CodexJSONValue],
        aggregatedOutput: String?,
        exitCode: Double?,
        durationMs: Double?
    )
    case fileChange(
        id: String,
        changes: [CodexJSONValue],
        status: CodexPatchApplyStatus
    )
    case mcpToolCall(
        id: String,
        server: String,
        tool: String,
        status: CodexMCPToolCallStatus,
        arguments: CodexJSONValue,
        appContext: CodexJSONValue?,
        mcpAppResourceURI: String?,
        pluginID: String?,
        result: CodexJSONValue?,
        error: CodexJSONValue?,
        durationMs: Double?
    )
    case dynamicToolCall(
        id: String,
        namespace: String?,
        tool: String,
        arguments: CodexJSONValue,
        status: CodexDynamicToolCallStatus,
        contentItems: [CodexJSONValue]?,
        success: Bool?,
        durationMs: Double?
    )
    case collabAgentToolCall(
        id: String,
        tool: CodexCollabAgentTool,
        status: CodexCollabAgentToolCallStatus,
        senderThreadID: String,
        receiverThreadIDs: [String],
        prompt: String?,
        model: String?,
        reasoningEffort: String?,
        agentsStates: [String: CodexJSONValue]
    )
    case subAgentActivity(
        id: String,
        kind: CodexSubAgentActivityKind,
        agentThreadID: String,
        agentPath: String
    )
    case webSearch(
        id: String,
        query: String,
        action: CodexJSONValue?,
        results: [CodexJSONValue]?
    )
    case imageView(id: String, path: String)
    case sleep(id: String, durationMs: Double)
    case imageGeneration(
        id: String,
        status: String,
        revisedPrompt: String?,
        result: String,
        savedPath: String?
    )
    case enteredReviewMode(id: String, review: String)
    case exitedReviewMode(id: String, review: String)
    case contextCompaction(id: String)

    public var kind: CodexStoredThreadItemKind {
        switch self {
        case .userMessage: .userMessage
        case .hookPrompt: .hookPrompt
        case .agentMessage: .agentMessage
        case .plan: .plan
        case .reasoning: .reasoning
        case .commandExecution: .commandExecution
        case .fileChange: .fileChange
        case .mcpToolCall: .mcpToolCall
        case .dynamicToolCall: .dynamicToolCall
        case .collabAgentToolCall: .collabAgentToolCall
        case .subAgentActivity: .subAgentActivity
        case .webSearch: .webSearch
        case .imageView: .imageView
        case .sleep: .sleep
        case .imageGeneration: .imageGeneration
        case .enteredReviewMode: .enteredReviewMode
        case .exitedReviewMode: .exitedReviewMode
        case .contextCompaction: .contextCompaction
        }
    }

    public var id: String {
        switch self {
        case let .userMessage(id, _, _),
             let .hookPrompt(id, _),
             let .agentMessage(id, _, _, _),
             let .plan(id, _),
             let .reasoning(id, _, _),
             let .commandExecution(id, _, _, _, _, _, _, _, _, _),
             let .fileChange(id, _, _),
             let .mcpToolCall(id, _, _, _, _, _, _, _, _, _, _),
             let .dynamicToolCall(id, _, _, _, _, _, _, _),
             let .collabAgentToolCall(id, _, _, _, _, _, _, _, _),
             let .subAgentActivity(id, _, _, _),
             let .webSearch(id, _, _, _),
             let .imageView(id, _),
             let .sleep(id, _),
             let .imageGeneration(id, _, _, _, _),
             let .enteredReviewMode(id, _),
             let .exitedReviewMode(id, _),
             let .contextCompaction(id):
            id
        }
    }

    public init(from decoder: any Decoder) throws {
        let wireValue = try CodexJSONValue(from: decoder)
        let object = try CodexWireObject(
            wireValue,
            codingPath: decoder.codingPath
        )
        let kind = try object.requiredEnum(
            CodexStoredThreadItemKind.self,
            for: "type"
        )
        let id = try object.requiredString("id")

        switch kind {
        case .userMessage:
            let content = try object.requiredArray("content")
            self = .userMessage(
                id: id,
                clientID: try object.optionalNullableString("clientId"),
                content: try content.enumerated().map { index, value in
                    try CodexStoredUserInput(
                        wireValue: value,
                        codingPath: decoder.codingPath
                            + [CodexAnyCodingKey("content")]
                            + [CodexAnyCodingKey(index: index)]
                    )
                }
            )
        case .hookPrompt:
            self = .hookPrompt(
                id: id,
                fragments: try object.requiredArray("fragments")
            )
        case .agentMessage:
            self = .agentMessage(
                id: id,
                text: try object.requiredString("text"),
                phase: try object.optionalNullableEnum(
                    CodexMessagePhase.self,
                    for: "phase"
                ),
                memoryCitation: try object.optionalNullableObject(
                    "memoryCitation"
                )
            )
        case .plan:
            self = .plan(id: id, text: try object.requiredString("text"))
        case .reasoning:
            self = .reasoning(
                id: id,
                summary: try object.optionalStringArray("summary") ?? [],
                content: try object.optionalStringArray("content") ?? []
            )
        case .commandExecution:
            self = .commandExecution(
                id: id,
                command: try object.requiredString("command"),
                cwd: try object.requiredString("cwd"),
                processID: try object.optionalNullableString("processId"),
                source: try object.optionalEnum(
                    CodexCommandExecutionSource.self,
                    for: "source"
                ) ?? .agent,
                status: try object.requiredEnum(
                    CodexCommandExecutionStatus.self,
                    for: "status"
                ),
                commandActions: try object.requiredArray("commandActions"),
                aggregatedOutput: try object.optionalNullableString(
                    "aggregatedOutput"
                ),
                exitCode: try object.optionalNullableNumber("exitCode"),
                durationMs: try object.optionalNullableNumber("durationMs")
            )
        case .fileChange:
            self = .fileChange(
                id: id,
                changes: try object.requiredArray("changes"),
                status: try object.requiredEnum(
                    CodexPatchApplyStatus.self,
                    for: "status"
                )
            )
        case .mcpToolCall:
            self = .mcpToolCall(
                id: id,
                server: try object.requiredString("server"),
                tool: try object.requiredString("tool"),
                status: try object.requiredEnum(
                    CodexMCPToolCallStatus.self,
                    for: "status"
                ),
                arguments: try object.requiredValue("arguments"),
                appContext: try object.optionalNullableObject("appContext"),
                mcpAppResourceURI: try object.optionalNullableString(
                    "mcpAppResourceUri"
                ),
                pluginID: try object.optionalNullableString("pluginId"),
                result: try object.optionalNullableObject("result"),
                error: try object.optionalNullableObject("error"),
                durationMs: try object.optionalNullableNumber("durationMs")
            )
        case .dynamicToolCall:
            self = .dynamicToolCall(
                id: id,
                namespace: try object.optionalNullableString("namespace"),
                tool: try object.requiredString("tool"),
                arguments: try object.requiredValue("arguments"),
                status: try object.requiredEnum(
                    CodexDynamicToolCallStatus.self,
                    for: "status"
                ),
                contentItems: try object.optionalNullableArray("contentItems"),
                success: try object.optionalNullableBool("success"),
                durationMs: try object.optionalNullableNumber("durationMs")
            )
        case .collabAgentToolCall:
            self = .collabAgentToolCall(
                id: id,
                tool: try object.requiredEnum(
                    CodexCollabAgentTool.self,
                    for: "tool"
                ),
                status: try object.requiredEnum(
                    CodexCollabAgentToolCallStatus.self,
                    for: "status"
                ),
                senderThreadID: try object.requiredString("senderThreadId"),
                receiverThreadIDs: try object.requiredStringArray(
                    "receiverThreadIds"
                ),
                prompt: try object.optionalNullableString("prompt"),
                model: try object.optionalNullableString("model"),
                reasoningEffort: try object.optionalNullableString(
                    "reasoningEffort"
                ),
                agentsStates: try object.requiredObject("agentsStates")
            )
        case .subAgentActivity:
            self = .subAgentActivity(
                id: id,
                kind: try object.requiredEnum(
                    CodexSubAgentActivityKind.self,
                    for: "kind"
                ),
                agentThreadID: try object.requiredString("agentThreadId"),
                agentPath: try object.requiredString("agentPath")
            )
        case .webSearch:
            self = .webSearch(
                id: id,
                query: try object.requiredString("query"),
                action: try object.optionalNullableObject("action"),
                results: try object.optionalNullableArray("results")
            )
        case .imageView:
            self = .imageView(
                id: id,
                path: try object.requiredString("path")
            )
        case .sleep:
            self = .sleep(
                id: id,
                durationMs: try object.requiredNumber("durationMs")
            )
        case .imageGeneration:
            self = .imageGeneration(
                id: id,
                status: try object.requiredString("status"),
                revisedPrompt: try object.optionalNullableString(
                    "revisedPrompt"
                ),
                result: try object.requiredString("result"),
                savedPath: try object.optionalNullableString("savedPath")
            )
        case .enteredReviewMode:
            self = .enteredReviewMode(
                id: id,
                review: try object.requiredString("review")
            )
        case .exitedReviewMode:
            self = .exitedReviewMode(
                id: id,
                review: try object.requiredString("review")
            )
        case .contextCompaction:
            self = .contextCompaction(id: id)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var object: [String: CodexJSONValue] = [
            "type": .string(kind.rawValue),
            "id": .string(id),
        ]
        switch self {
        case let .userMessage(_, clientID, content):
            object["clientId"] = clientID.map(CodexJSONValue.string) ?? .null
            object["content"] = .array(
                try content.map(Self.wireValue)
            )
        case let .hookPrompt(_, fragments):
            object["fragments"] = .array(fragments)
        case let .agentMessage(_, text, phase, memoryCitation):
            object["text"] = .string(text)
            object["phase"] = phase.map {
                .string($0.rawValue)
            } ?? .null
            object["memoryCitation"] = memoryCitation ?? .null
        case let .plan(_, text):
            object["text"] = .string(text)
        case let .reasoning(_, summary, content):
            object["summary"] = .array(summary.map(CodexJSONValue.string))
            object["content"] = .array(content.map(CodexJSONValue.string))
        case let .commandExecution(
            _, command, cwd, processID, source, status, commandActions,
            aggregatedOutput, exitCode, durationMs
        ):
            object["command"] = .string(command)
            object["cwd"] = .string(cwd)
            object["processId"] = processID.map(CodexJSONValue.string) ?? .null
            object["source"] = .string(source.rawValue)
            object["status"] = .string(status.rawValue)
            object["commandActions"] = .array(commandActions)
            object["aggregatedOutput"] =
                aggregatedOutput.map(CodexJSONValue.string) ?? .null
            object["exitCode"] = Self.numberValue(exitCode)
            object["durationMs"] = Self.numberValue(durationMs)
        case let .fileChange(_, changes, status):
            object["changes"] = .array(changes)
            object["status"] = .string(status.rawValue)
        case let .mcpToolCall(
            _, server, tool, status, arguments, appContext,
            mcpAppResourceURI, pluginID, result, error, durationMs
        ):
            object["server"] = .string(server)
            object["tool"] = .string(tool)
            object["status"] = .string(status.rawValue)
            object["arguments"] = arguments
            object["appContext"] = appContext ?? .null
            if let mcpAppResourceURI {
                object["mcpAppResourceUri"] = .string(mcpAppResourceURI)
            }
            object["pluginId"] = pluginID.map(CodexJSONValue.string) ?? .null
            object["result"] = result ?? .null
            object["error"] = error ?? .null
            object["durationMs"] = Self.numberValue(durationMs)
        case let .dynamicToolCall(
            _, namespace, tool, arguments, status, contentItems,
            success, durationMs
        ):
            object["namespace"] =
                namespace.map(CodexJSONValue.string) ?? .null
            object["tool"] = .string(tool)
            object["arguments"] = arguments
            object["status"] = .string(status.rawValue)
            object["contentItems"] = contentItems.map {
                .array($0)
            } ?? .null
            object["success"] = success.map(CodexJSONValue.bool) ?? .null
            object["durationMs"] = Self.numberValue(durationMs)
        case let .collabAgentToolCall(
            _, tool, status, senderThreadID, receiverThreadIDs, prompt,
            model, reasoningEffort, agentsStates
        ):
            object["tool"] = .string(tool.rawValue)
            object["status"] = .string(status.rawValue)
            object["senderThreadId"] = .string(senderThreadID)
            object["receiverThreadIds"] = .array(
                receiverThreadIDs.map(CodexJSONValue.string)
            )
            object["prompt"] = prompt.map(CodexJSONValue.string) ?? .null
            object["model"] = model.map(CodexJSONValue.string) ?? .null
            object["reasoningEffort"] =
                reasoningEffort.map(CodexJSONValue.string) ?? .null
            object["agentsStates"] = .object(agentsStates)
        case let .subAgentActivity(
            _, activityKind, agentThreadID, agentPath
        ):
            object["kind"] = .string(activityKind.rawValue)
            object["agentThreadId"] = .string(agentThreadID)
            object["agentPath"] = .string(agentPath)
        case let .webSearch(_, query, action, results):
            object["query"] = .string(query)
            object["action"] = action ?? .null
            object["results"] = results.map {
                .array($0)
            } ?? .null
        case let .imageView(_, path):
            object["path"] = .string(path)
        case let .sleep(_, durationMs):
            object["durationMs"] = Self.numberValue(durationMs)
        case let .imageGeneration(
            _, status, revisedPrompt, result, savedPath
        ):
            object["status"] = .string(status)
            object["revisedPrompt"] =
                revisedPrompt.map(CodexJSONValue.string) ?? .null
            object["result"] = .string(result)
            if let savedPath {
                object["savedPath"] = .string(savedPath)
            }
        case let .enteredReviewMode(_, review),
             let .exitedReviewMode(_, review):
            object["review"] = .string(review)
        case .contextCompaction:
            break
        }
        try CodexJSONValue.object(object).encode(to: encoder)
    }

    private static func wireValue(
        _ input: CodexStoredUserInput
    ) throws -> CodexJSONValue {
        let data = try JSONEncoder().encode(input)
        return try JSONDecoder().decode(CodexJSONValue.self, from: data)
    }

    private static func numberValue(_ value: Double?) -> CodexJSONValue {
        value.map(numberValue) ?? .null
    }

    private static func numberValue(_ value: Double) -> CodexJSONValue {
        if value.isFinite,
           value.rounded(.towardZero) == value,
           value >= Double(Int64.min),
           value <= Double(Int64.max)
        {
            return .integer(Int64(value))
        }
        return .number(value)
    }
}

public enum CodexNonSteerableTurnKind:
    String,
    Codable,
    Equatable,
    Sendable
{
    case review
    case compact
}

public enum CodexErrorInfo: Codable, Equatable, Sendable {
    case contextWindowExceeded
    case sessionBudgetExceeded
    case usageLimitExceeded
    case serverOverloaded
    case cyberPolicy
    case internalServerError
    case unauthorized
    case badRequest
    case threadRollbackFailed
    case sandboxError
    case other
    case httpConnectionFailed(httpStatusCode: Double?)
    case responseStreamConnectionFailed(httpStatusCode: Double?)
    case responseStreamDisconnected(httpStatusCode: Double?)
    case responseTooManyFailedAttempts(httpStatusCode: Double?)
    case activeTurnNotSteerable(turnKind: CodexNonSteerableTurnKind)

    public init(from decoder: any Decoder) throws {
        let value = try CodexJSONValue(from: decoder)
        if case let .string(name) = value {
            switch name {
            case "contextWindowExceeded": self = .contextWindowExceeded
            case "sessionBudgetExceeded": self = .sessionBudgetExceeded
            case "usageLimitExceeded": self = .usageLimitExceeded
            case "serverOverloaded": self = .serverOverloaded
            case "cyberPolicy": self = .cyberPolicy
            case "internalServerError": self = .internalServerError
            case "unauthorized": self = .unauthorized
            case "badRequest": self = .badRequest
            case "threadRollbackFailed": self = .threadRollbackFailed
            case "sandboxError": self = .sandboxError
            case "other": self = .other
            default:
                throw CodexWireObject.failure(
                    decoder.codingPath,
                    "Unknown CodexErrorInfo string variant \(name)"
                )
            }
            return
        }

        let object = try CodexWireObject(value, codingPath: decoder.codingPath)
        guard object.values.count == 1,
              let variant = object.values.keys.first
        else {
            throw CodexWireObject.failure(
                decoder.codingPath,
                "CodexErrorInfo object must contain exactly one variant"
            )
        }
        let payload = try object.requiredObject(variant)
        let payloadObject = CodexWireObject(
            values: payload,
            codingPath: decoder.codingPath + [CodexAnyCodingKey(variant)]
        )
        switch variant {
        case "httpConnectionFailed":
            try payloadObject.requireExactly(["httpStatusCode"])
            self = .httpConnectionFailed(
                httpStatusCode: try payloadObject.requiredNullableNumber(
                    "httpStatusCode"
                )
            )
        case "responseStreamConnectionFailed":
            try payloadObject.requireExactly(["httpStatusCode"])
            self = .responseStreamConnectionFailed(
                httpStatusCode: try payloadObject.requiredNullableNumber(
                    "httpStatusCode"
                )
            )
        case "responseStreamDisconnected":
            try payloadObject.requireExactly(["httpStatusCode"])
            self = .responseStreamDisconnected(
                httpStatusCode: try payloadObject.requiredNullableNumber(
                    "httpStatusCode"
                )
            )
        case "responseTooManyFailedAttempts":
            try payloadObject.requireExactly(["httpStatusCode"])
            self = .responseTooManyFailedAttempts(
                httpStatusCode: try payloadObject.requiredNullableNumber(
                    "httpStatusCode"
                )
            )
        case "activeTurnNotSteerable":
            try payloadObject.requireExactly(["turnKind"])
            self = .activeTurnNotSteerable(
                turnKind: try payloadObject.requiredEnum(
                    CodexNonSteerableTurnKind.self,
                    for: "turnKind"
                )
            )
        default:
            throw CodexWireObject.failure(
                decoder.codingPath,
                "Unknown CodexErrorInfo object variant \(variant)"
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        let value: CodexJSONValue
        switch self {
        case .contextWindowExceeded:
            value = .string("contextWindowExceeded")
        case .sessionBudgetExceeded:
            value = .string("sessionBudgetExceeded")
        case .usageLimitExceeded:
            value = .string("usageLimitExceeded")
        case .serverOverloaded:
            value = .string("serverOverloaded")
        case .cyberPolicy:
            value = .string("cyberPolicy")
        case .internalServerError:
            value = .string("internalServerError")
        case .unauthorized:
            value = .string("unauthorized")
        case .badRequest:
            value = .string("badRequest")
        case .threadRollbackFailed:
            value = .string("threadRollbackFailed")
        case .sandboxError:
            value = .string("sandboxError")
        case .other:
            value = .string("other")
        case let .httpConnectionFailed(status):
            value = Self.httpVariant("httpConnectionFailed", status)
        case let .responseStreamConnectionFailed(status):
            value = Self.httpVariant(
                "responseStreamConnectionFailed",
                status
            )
        case let .responseStreamDisconnected(status):
            value = Self.httpVariant("responseStreamDisconnected", status)
        case let .responseTooManyFailedAttempts(status):
            value = Self.httpVariant(
                "responseTooManyFailedAttempts",
                status
            )
        case let .activeTurnNotSteerable(turnKind):
            value = .object([
                "activeTurnNotSteerable": .object([
                    "turnKind": .string(turnKind.rawValue),
                ]),
            ])
        }
        try value.encode(to: encoder)
    }

    private static func httpVariant(
        _ name: String,
        _ status: Double?
    ) -> CodexJSONValue {
        let statusValue = status.map(CodexJSONValue.number) ?? .null
        return .object([
            name: .object(["httpStatusCode": statusValue]),
        ])
    }
}

private struct CodexAnyCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init(_ stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }

    init(index: Int) {
        stringValue = String(index)
        intValue = index
    }

    init?(stringValue: String) {
        self.init(stringValue)
    }

    init?(intValue: Int) {
        self.init(index: intValue)
    }
}

private struct CodexWireObject {
    let values: [String: CodexJSONValue]
    let codingPath: [any CodingKey]

    init(
        _ value: CodexJSONValue,
        codingPath: [any CodingKey]
    ) throws {
        guard case let .object(values) = value else {
            throw Self.failure(codingPath, "Expected a JSON object")
        }
        self.values = values
        self.codingPath = codingPath
    }

    init(
        values: [String: CodexJSONValue],
        codingPath: [any CodingKey]
    ) {
        self.values = values
        self.codingPath = codingPath
    }

    static func failure(
        _ codingPath: [any CodingKey],
        _ description: String
    ) -> DecodingError {
        .dataCorrupted(
            .init(codingPath: codingPath, debugDescription: description)
        )
    }

    func requireExactly(_ keys: Set<String>) throws {
        guard Set(values.keys) == keys else {
            throw Self.failure(
                codingPath,
                "Expected exactly keys \(keys.sorted())"
            )
        }
    }

    func requiredValue(_ key: String) throws -> CodexJSONValue {
        guard let value = values[key] else {
            throw invalid(key, "Missing required field")
        }
        return value
    }

    func requiredString(_ key: String) throws -> String {
        guard case let .string(value) = try requiredValue(key) else {
            throw invalid(key, "Expected a string")
        }
        return value
    }

    func optionalNullableString(_ key: String) throws -> String? {
        guard let value = values[key] else {
            return nil
        }
        switch value {
        case .null:
            return nil
        case let .string(string):
            return string
        default:
            throw invalid(key, "Expected a string or null")
        }
    }

    func requiredNullableBool(_ key: String) throws -> Bool? {
        switch try requiredValue(key) {
        case .null:
            return nil
        case let .bool(value):
            return value
        default:
            throw invalid(key, "Expected a boolean or null")
        }
    }

    func optionalNullableBool(_ key: String) throws -> Bool? {
        guard values[key] != nil else {
            return nil
        }
        return try requiredNullableBool(key)
    }

    func requiredNumber(_ key: String) throws -> Double {
        try number(try requiredValue(key), key: key, nullable: false)!
    }

    func requiredNullableNumber(_ key: String) throws -> Double? {
        try number(try requiredValue(key), key: key, nullable: true)
    }

    func optionalNullableNumber(_ key: String) throws -> Double? {
        guard let value = values[key] else {
            return nil
        }
        return try number(value, key: key, nullable: true)
    }

    func requiredInt32(_ key: String) throws -> Int32 {
        guard case let .integer(value) = try requiredValue(key),
              let result = Int32(exactly: value)
        else {
            throw invalid(key, "Expected an int32 integer")
        }
        return result
    }

    func requiredArray(_ key: String) throws -> [CodexJSONValue] {
        guard case let .array(value) = try requiredValue(key) else {
            throw invalid(key, "Expected an array")
        }
        return value
    }

    func optionalArray(_ key: String) throws -> [CodexJSONValue]? {
        guard values[key] != nil else {
            return nil
        }
        return try requiredArray(key)
    }

    func requiredNullableArray(_ key: String) throws -> [CodexJSONValue]? {
        switch try requiredValue(key) {
        case .null:
            return nil
        case let .array(value):
            return value
        default:
            throw invalid(key, "Expected an array or null")
        }
    }

    func optionalNullableArray(_ key: String) throws -> [CodexJSONValue]? {
        guard values[key] != nil else {
            return nil
        }
        return try requiredNullableArray(key)
    }

    func requiredStringArray(_ key: String) throws -> [String] {
        try requiredArray(key).enumerated().map { index, value in
            guard case let .string(string) = value else {
                throw invalid(
                    key,
                    "Expected string at array index \(index)"
                )
            }
            return string
        }
    }

    func optionalStringArray(_ key: String) throws -> [String]? {
        guard let values = try optionalArray(key) else {
            return nil
        }
        return try values.enumerated().map { index, value in
            guard case let .string(string) = value else {
                throw invalid(
                    key,
                    "Expected string at array index \(index)"
                )
            }
            return string
        }
    }

    func requiredObject(
        _ key: String
    ) throws -> [String: CodexJSONValue] {
        guard case let .object(value) = try requiredValue(key) else {
            throw invalid(key, "Expected an object")
        }
        return value
    }

    func requiredNullableObject(
        _ key: String
    ) throws -> CodexJSONValue? {
        switch try requiredValue(key) {
        case .null:
            return nil
        case let .object(value):
            return .object(value)
        default:
            throw invalid(key, "Expected an object or null")
        }
    }

    func optionalNullableObject(
        _ key: String
    ) throws -> CodexJSONValue? {
        guard values[key] != nil else {
            return nil
        }
        return try requiredNullableObject(key)
    }

    func requiredEnum<Value>(
        _ type: Value.Type,
        for key: String
    ) throws -> Value where Value: RawRepresentable, Value.RawValue == String {
        let rawValue = try requiredString(key)
        guard let value = Value(rawValue: rawValue) else {
            throw invalid(key, "Unknown enum value \(rawValue)")
        }
        return value
    }

    func optionalEnum<Value>(
        _ type: Value.Type,
        for key: String
    ) throws -> Value? where Value: RawRepresentable, Value.RawValue == String {
        guard values[key] != nil else {
            return nil
        }
        return try requiredEnum(type, for: key)
    }

    func optionalNullableEnum<Value>(
        _ type: Value.Type,
        for key: String
    ) throws -> Value? where Value: RawRepresentable, Value.RawValue == String {
        guard values[key] != nil else {
            return nil
        }
        if case .null = try requiredValue(key) {
            return nil
        }
        return try requiredEnum(type, for: key)
    }

    private func number(
        _ value: CodexJSONValue,
        key: String,
        nullable: Bool
    ) throws -> Double? {
        switch value {
        case .null where nullable:
            return nil
        case let .integer(value):
            return Double(value)
        case let .number(value):
            return value
        default:
            throw invalid(
                key,
                nullable ? "Expected a number or null" : "Expected a number"
            )
        }
    }

    private func invalid(_ key: String, _ description: String) -> DecodingError {
        Self.failure(
            codingPath + [CodexAnyCodingKey(key)],
            "\(description): \(key)"
        )
    }
}

private extension KeyedDecodingContainer {
    func decodeWireOptional<Value>(
        _ type: Value.Type,
        forKey key: Key
    ) throws -> CodexWireOptional<Value> where
        Value: Decodable & Equatable & Sendable
    {
        guard contains(key) else {
            return .omitted
        }
        if try decodeNil(forKey: key) {
            return .null
        }
        return .value(try decode(type, forKey: key))
    }
}

private extension KeyedEncodingContainer {
    mutating func encodeWireOptional<Value>(
        _ value: CodexWireOptional<Value>,
        forKey key: Key
    ) throws where Value: Encodable & Equatable & Sendable {
        switch value {
        case .omitted:
            break
        case .null:
            try encodeNil(forKey: key)
        case let .value(value):
            try encode(value, forKey: key)
        }
    }
}

public enum CodexStoredTurnItemsView:
    String,
    Codable,
    Equatable,
    Sendable
{
    case notLoaded
    case summary
    case full
}

public enum CodexStoredTurnStatus:
    String,
    Codable,
    Equatable,
    Sendable
{
    case completed
    case interrupted
    case failed
    case inProgress
}

public struct CodexStoredTurnError: Codable, Equatable, Sendable {
    public let message: String
    public let codexErrorInfo: CodexErrorInfo?
    public let additionalDetails: String?

    public init(
        message: String,
        codexErrorInfo: CodexErrorInfo? = nil,
        additionalDetails: String? = nil
    ) {
        self.message = message
        self.codexErrorInfo = codexErrorInfo
        self.additionalDetails = additionalDetails
    }

    private enum CodingKeys: String, CodingKey {
        case message
        case codexErrorInfo
        case additionalDetails
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        message = try container.decode(String.self, forKey: .message)
        codexErrorInfo = try container.decodeIfPresent(
            CodexErrorInfo.self,
            forKey: .codexErrorInfo
        )
        additionalDetails = try container.decodeIfPresent(
            String.self,
            forKey: .additionalDetails
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(message, forKey: .message)
        try container.encodeIfPresent(
            codexErrorInfo,
            forKey: .codexErrorInfo
        )
        try container.encodeIfPresent(
            additionalDetails,
            forKey: .additionalDetails
        )
    }
}

public struct CodexStoredTurn:
    Codable,
    Equatable,
    Identifiable,
    Sendable
{
    public let id: String
    public let items: [CodexStoredThreadItem]
    public let itemsView: CodexStoredTurnItemsView
    public let status: CodexStoredTurnStatus
    public let error: CodexStoredTurnError?
    public let startedAt: Int64?
    public let completedAt: Int64?
    public let durationMs: Int64?

    public init(
        id: String,
        items: [CodexStoredThreadItem],
        itemsView: CodexStoredTurnItemsView = .full,
        status: CodexStoredTurnStatus,
        error: CodexStoredTurnError? = nil,
        startedAt: Int64? = nil,
        completedAt: Int64? = nil,
        durationMs: Int64? = nil
    ) {
        self.id = id
        self.items = items
        self.itemsView = itemsView
        self.status = status
        self.error = error
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.durationMs = durationMs
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case items
        case itemsView
        case status
        case error
        case startedAt
        case completedAt
        case durationMs
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        items = try container.decode(
            [CodexStoredThreadItem].self,
            forKey: .items
        )
        if container.contains(.itemsView) {
            itemsView = try container.decode(
                CodexStoredTurnItemsView.self,
                forKey: .itemsView
            )
        } else {
            itemsView = .full
        }
        status = try container.decode(
            CodexStoredTurnStatus.self,
            forKey: .status
        )
        error = try container.decodeIfPresent(
            CodexStoredTurnError.self,
            forKey: .error
        )
        startedAt = try container.decodeIfPresent(
            Int64.self,
            forKey: .startedAt
        )
        completedAt = try container.decodeIfPresent(
            Int64.self,
            forKey: .completedAt
        )
        durationMs = try container.decodeIfPresent(
            Int64.self,
            forKey: .durationMs
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(items, forKey: .items)
        try container.encode(itemsView, forKey: .itemsView)
        try container.encode(status, forKey: .status)
        try container.encodeIfPresent(error, forKey: .error)
        try container.encodeIfPresent(startedAt, forKey: .startedAt)
        try container.encodeIfPresent(
            completedAt,
            forKey: .completedAt
        )
        try container.encodeIfPresent(durationMs, forKey: .durationMs)
    }
}

public enum CodexThreadSessionSourceName:
    String,
    Codable,
    Equatable,
    Sendable,
    ExpressibleByStringLiteral
{
    case cli
    case vscode
    case exec
    case appServer
    case unknown

    public init(stringLiteral value: String) {
        guard let name = Self(rawValue: value) else {
            preconditionFailure("Unknown official SessionSource string")
        }
        self = name
    }
}

public enum CodexSubAgentSource: Codable, Equatable, Sendable {
    case review
    case compact
    case memoryConsolidation
    case threadSpawn(
        parentThreadID: CodexStoredThreadID,
        depth: Int32,
        agentPath: String? = nil,
        agentNickname: String? = nil,
        agentRole: String? = nil,
        model: String? = nil
    )
    case other(String)

    public init(from decoder: any Decoder) throws {
        let value = try CodexJSONValue(from: decoder)
        if case let .string(name) = value {
            switch name {
            case "review": self = .review
            case "compact": self = .compact
            case "memory_consolidation": self = .memoryConsolidation
            default:
                throw CodexWireObject.failure(
                    decoder.codingPath,
                    "Unknown SubAgentSource string variant \(name)"
                )
            }
            return
        }

        let object = try CodexWireObject(value, codingPath: decoder.codingPath)
        guard object.values.count == 1,
              let variant = object.values.keys.first
        else {
            throw CodexWireObject.failure(
                decoder.codingPath,
                "SubAgentSource object must contain exactly one variant"
            )
        }
        switch variant {
        case "thread_spawn":
            let spawn = CodexWireObject(
                values: try object.requiredObject(variant),
                codingPath: decoder.codingPath
                    + [CodexAnyCodingKey(variant)]
            )
            self = .threadSpawn(
                parentThreadID: CodexStoredThreadID(
                    try spawn.requiredString("parent_thread_id")
                ),
                depth: try spawn.requiredInt32("depth"),
                agentPath: try spawn.optionalNullableString("agent_path"),
                agentNickname: try spawn.optionalNullableString(
                    "agent_nickname"
                ),
                agentRole: try spawn.optionalNullableString("agent_role"),
                model: try spawn.optionalNullableString("model")
            )
        case "other":
            self = .other(try object.requiredString(variant))
        default:
            throw CodexWireObject.failure(
                decoder.codingPath,
                "Unknown SubAgentSource object variant \(variant)"
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        let value: CodexJSONValue
        switch self {
        case .review:
            value = .string("review")
        case .compact:
            value = .string("compact")
        case .memoryConsolidation:
            value = .string("memory_consolidation")
        case let .threadSpawn(
            parentThreadID,
            depth,
            agentPath,
            agentNickname,
            agentRole,
            model
        ):
            var spawn: [String: CodexJSONValue] = [
                "parent_thread_id": .string(parentThreadID.rawValue),
                "depth": .integer(Int64(depth)),
                "agent_path":
                    agentPath.map(CodexJSONValue.string) ?? .null,
                "agent_nickname":
                    agentNickname.map(CodexJSONValue.string) ?? .null,
                "agent_role":
                    agentRole.map(CodexJSONValue.string) ?? .null,
            ]
            spawn["model"] = model.map(CodexJSONValue.string) ?? .null
            value = .object(["thread_spawn": .object(spawn)])
        case let .other(name):
            value = .object(["other": .string(name)])
        }
        try value.encode(to: encoder)
    }
}

public enum CodexThreadSessionSource: Codable, Equatable, Sendable {
    case named(CodexThreadSessionSourceName)
    case custom(String)
    case subAgent(CodexSubAgentSource)

    public init(from decoder: any Decoder) throws {
        let value = try CodexJSONValue(from: decoder)
        if case let .string(name) = value {
            guard let source = CodexThreadSessionSourceName(rawValue: name) else {
                throw CodexWireObject.failure(
                    decoder.codingPath,
                    "Unknown official SessionSource string \(name)"
                )
            }
            self = .named(source)
            return
        }

        let object = try CodexWireObject(value, codingPath: decoder.codingPath)
        guard object.values.count == 1,
              let variant = object.values.keys.first
        else {
            throw CodexWireObject.failure(
                decoder.codingPath,
                "SessionSource object must contain exactly one variant"
            )
        }
        switch variant {
        case "custom":
            self = .custom(try object.requiredString(variant))
        case "subAgent":
            let data = try JSONEncoder().encode(
                object.requiredValue(variant)
            )
            self = .subAgent(
                try JSONDecoder().decode(CodexSubAgentSource.self, from: data)
            )
        default:
            throw CodexWireObject.failure(
                decoder.codingPath,
                "Unknown SessionSource object variant \(variant)"
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        switch self {
        case let .named(name):
            try CodexJSONValue.string(name.rawValue).encode(to: encoder)
        case let .custom(name):
            try CodexJSONValue.object([
                "custom": .string(name),
            ]).encode(to: encoder)
        case let .subAgent(source):
            let data = try JSONEncoder().encode(source)
            let value = try JSONDecoder().decode(
                CodexJSONValue.self,
                from: data
            )
            try CodexJSONValue.object([
                "subAgent": value,
            ]).encode(to: encoder)
        }
    }
}

public struct CodexThreadExtra: Codable, Equatable, Sendable {
    public var values: [String: CodexJSONValue]

    public init(values: [String: CodexJSONValue] = [:]) {
        self.values = values
    }

    public init(from decoder: any Decoder) throws {
        values = try CodexWireObject(
            CodexJSONValue(from: decoder),
            codingPath: decoder.codingPath
        ).values
    }

    public func encode(to encoder: any Encoder) throws {
        try CodexJSONValue.object(values).encode(to: encoder)
    }
}

public enum CodexThreadHistoryMode:
    String,
    Codable,
    Equatable,
    Sendable
{
    case legacy
    case paginated
}

public struct CodexStoredThread:
    Codable,
    Equatable,
    Identifiable,
    Sendable
{
    public let id: CodexStoredThreadID
    private var extraWire: CodexWireOptional<CodexThreadExtra>
    private var historyModeWire: CodexWireOptional<CodexThreadHistoryMode>
    private var canAcceptDirectInputWire: CodexWireOptional<Bool>
    private var sectionWire: CodexWireOptional<CodexThreadSection>

    public var extra: CodexThreadExtra? {
        get {
            guard case let .value(extra) = extraWire else {
                return nil
            }
            return extra
        }
        set {
            extraWire = newValue.map(CodexWireOptional.value) ?? .omitted
        }
    }

    public var historyMode: CodexThreadHistoryMode? {
        get {
            switch historyModeWire {
            case .omitted:
                return .legacy
            case .null:
                return nil
            case let .value(mode):
                return mode
            }
        }
        set {
            historyModeWire =
                newValue.map(CodexWireOptional.value) ?? .omitted
        }
    }

    public var canAcceptDirectInput: Bool? {
        get {
            guard case let .value(value) = canAcceptDirectInputWire else {
                return nil
            }
            return value
        }
        set {
            canAcceptDirectInputWire =
                newValue.map(CodexWireOptional.value) ?? .omitted
        }
    }

    public var section: CodexThreadSection? {
        get {
            guard case let .value(section) = sectionWire else {
                return nil
            }
            return section
        }
        set {
            sectionWire = newValue.map(CodexWireOptional.value) ?? .omitted
        }
    }

    public var sessionID: String
    public var forkedFromID: CodexStoredThreadID?
    public var parentThreadID: CodexStoredThreadID?
    public var preview: String
    public var ephemeral: Bool
    public var isPinned: Bool
    public var mode: String
    public var modelProvider: String
    public var createdAt: Int64
    public var updatedAt: Int64
    public var recencyAt: Int64?
    public var status: CodexStoredThreadStatus
    public var path: String?
    public var cwd: String
    public var cliVersion: String
    public var source: CodexThreadSessionSource
    public var threadSource: String?
    public var agentNickname: String?
    public var agentRole: String?
    public var gitInfo: CodexThreadGitInfo?
    public var name: String?
    public var turns: [CodexStoredTurn]
    public var threadStartKind: String

    public init(
        id: CodexStoredThreadID,
        sessionID: String,
        forkedFromID: CodexStoredThreadID? = nil,
        parentThreadID: CodexStoredThreadID? = nil,
        preview: String,
        ephemeral: Bool,
        isPinned: Bool = false,
        mode: String = "default",
        modelProvider: String,
        createdAt: Int64,
        updatedAt: Int64,
        recencyAt: Int64? = nil,
        status: CodexStoredThreadStatus,
        path: String? = nil,
        cwd: String,
        cliVersion: String,
        source: CodexThreadSessionSource,
        threadSource: String? = nil,
        agentNickname: String? = nil,
        agentRole: String? = nil,
        gitInfo: CodexThreadGitInfo? = nil,
        name: String? = nil,
        turns: [CodexStoredTurn],
        extra: CodexThreadExtra? = nil,
        historyMode: CodexThreadHistoryMode? = nil,
        canAcceptDirectInput: Bool? = nil,
        section: CodexThreadSection? = nil,
        threadStartKind: String = "default"
    ) {
        self.id = id
        extraWire = extra.map(CodexWireOptional.value) ?? .omitted
        historyModeWire =
            historyMode.map(CodexWireOptional.value) ?? .omitted
        canAcceptDirectInputWire =
            canAcceptDirectInput.map(CodexWireOptional.value) ?? .omitted
        sectionWire = section.map(CodexWireOptional.value) ?? .omitted
        self.sessionID = sessionID
        self.forkedFromID = forkedFromID
        self.parentThreadID = parentThreadID
        self.preview = preview
        self.ephemeral = ephemeral
        self.isPinned = isPinned
        self.mode = mode
        self.modelProvider = modelProvider
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.recencyAt = recencyAt
        self.status = status
        self.path = path
        self.cwd = cwd
        self.cliVersion = cliVersion
        self.source = source
        self.threadSource = threadSource
        self.agentNickname = agentNickname
        self.agentRole = agentRole
        self.gitInfo = gitInfo
        self.name = name
        self.turns = turns
        self.threadStartKind = threadStartKind
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case extra
        case sessionID = "sessionId"
        case forkedFromID = "forkedFromId"
        case parentThreadID = "parentThreadId"
        case preview
        case ephemeral
        case isPinned
        case historyMode
        case mode
        case modelProvider
        case createdAt
        case updatedAt
        case recencyAt
        case status
        case path
        case cwd
        case cliVersion
        case source
        case canAcceptDirectInput
        case section
        case threadSource
        case agentNickname
        case agentRole
        case gitInfo
        case name
        case turns
        case threadStartKind
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        id = try container.decode(CodexStoredThreadID.self, forKey: .id)
        extraWire = try container.decodeWireOptional(
            CodexThreadExtra.self,
            forKey: .extra
        )
        historyModeWire = try container.decodeWireOptional(
            CodexThreadHistoryMode.self,
            forKey: .historyMode
        )
        if case .null = historyModeWire {
            throw DecodingError.valueNotFound(
                CodexThreadHistoryMode.self,
                .init(
                    codingPath: decoder.codingPath
                        + [CodexAnyCodingKey("historyMode")],
                    debugDescription:
                        "Experimental historyMode is required and non-null"
                )
            )
        }
        canAcceptDirectInputWire = try container.decodeWireOptional(
            Bool.self,
            forKey: .canAcceptDirectInput
        )
        sectionWire = try container.decodeWireOptional(
            CodexThreadSection.self,
            forKey: .section
        )

        sessionID = try container.decode(String.self, forKey: .sessionID)
        forkedFromID = try container.decodeIfPresent(
            CodexStoredThreadID.self,
            forKey: .forkedFromID
        )
        parentThreadID = try container.decodeIfPresent(
            CodexStoredThreadID.self,
            forKey: .parentThreadID
        )
        preview = try container.decode(String.self, forKey: .preview)
        ephemeral = try container.decode(Bool.self, forKey: .ephemeral)
        isPinned = try container.decodeIfPresent(
            Bool.self,
            forKey: .isPinned
        ) ?? false
        mode = try container.decodeIfPresent(String.self, forKey: .mode)
            ?? "default"
        guard !mode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DecodingError.dataCorruptedError(
                forKey: .mode,
                in: container,
                debugDescription: "Thread mode must not be empty"
            )
        }
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
        status = try container.decode(
            CodexStoredThreadStatus.self,
            forKey: .status
        )
        path = try container.decodeIfPresent(
            String.self,
            forKey: .path
        )
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
        name = try container.decodeIfPresent(
            String.self,
            forKey: .name
        )
        turns = try container.decode([CodexStoredTurn].self, forKey: .turns)
        threadStartKind = try container.decodeIfPresent(
            String.self,
            forKey: .threadStartKind
        ) ?? "default"
        guard !threadStartKind.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty else {
            throw DecodingError.dataCorruptedError(
                forKey: .threadStartKind,
                in: container,
                debugDescription: "Thread start kind must not be empty"
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        try container.encode(id, forKey: .id)
        try container.encodeWireOptional(extraWire, forKey: .extra)
        try container.encodeWireOptional(
            historyModeWire,
            forKey: .historyMode
        )
        try container.encodeWireOptional(
            canAcceptDirectInputWire,
            forKey: .canAcceptDirectInput
        )
        try container.encodeWireOptional(
            sectionWire,
            forKey: .section
        )
        try container.encode(sessionID, forKey: .sessionID)
        try container.encodeIfPresent(
            forkedFromID,
            forKey: .forkedFromID
        )
        try container.encodeIfPresent(
            parentThreadID,
            forKey: .parentThreadID
        )
        try container.encode(preview, forKey: .preview)
        try container.encode(ephemeral, forKey: .ephemeral)
        try container.encode(isPinned, forKey: .isPinned)
        try container.encode(mode, forKey: .mode)
        try container.encode(modelProvider, forKey: .modelProvider)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encodeIfPresent(recencyAt, forKey: .recencyAt)
        try container.encode(status, forKey: .status)
        try container.encodeIfPresent(path, forKey: .path)
        try container.encode(cwd, forKey: .cwd)
        try container.encode(cliVersion, forKey: .cliVersion)
        try container.encode(source, forKey: .source)
        try container.encodeIfPresent(
            threadSource,
            forKey: .threadSource
        )
        try container.encodeIfPresent(
            agentNickname,
            forKey: .agentNickname
        )
        try container.encodeIfPresent(
            agentRole,
            forKey: .agentRole
        )
        try container.encodeIfPresent(gitInfo, forKey: .gitInfo)
        try container.encodeIfPresent(name, forKey: .name)
        try container.encode(turns, forKey: .turns)
        try container.encode(threadStartKind, forKey: .threadStartKind)
    }
}

public struct CodexThreadPage: Codable, Equatable, Sendable {
    public var data: [CodexStoredThread]
    public var nextCursor: String?
    public var backwardsCursor: String?

    public init(
        data: [CodexStoredThread],
        nextCursor: String?,
        backwardsCursor: String?
    ) {
        self.data = data
        self.nextCursor = nextCursor
        self.backwardsCursor = backwardsCursor
    }
}

public struct CodexThreadReadResult: Codable, Equatable, Sendable {
    public var thread: CodexStoredThread

    public init(thread: CodexStoredThread) {
        self.thread = thread
    }
}

public struct CodexThreadRevertResult: Codable, Equatable, Sendable {
    public var thread: CodexStoredThread
    public var turnsBackwardsCursor: String?
    public var itemsBackwardsCursor: String?

    public init(
        thread: CodexStoredThread,
        turnsBackwardsCursor: String?,
        itemsBackwardsCursor: String?
    ) {
        self.thread = thread
        self.turnsBackwardsCursor = turnsBackwardsCursor
        self.itemsBackwardsCursor = itemsBackwardsCursor
    }
}

public struct CodexThreadResumeResult:
    Codable,
    Equatable,
    Sendable
{
    public var thread: CodexStoredThread
    public var model: String
    public var modelProvider: String
    public var serviceTier: String?
    public var cwd: String
    public var runtimeWorkspaceRoots: [String]
    public var dynamicTools: [CodexJSONValue]
    public var selectedCapabilityRoots: [CodexJSONValue]
    public var instructionSources: [String]
    public var approvalPolicy: CodexAppServerAskForApproval
    public var approvalsReviewer: CodexAppServerApprovalsReviewer
    public var sandbox: CodexAppServerSandboxPolicy
    public var reasoningEffort: String?

    public init(
        thread: CodexStoredThread,
        model: String,
        modelProvider: String,
        serviceTier: String?,
        cwd: String,
        runtimeWorkspaceRoots: [String] = [],
        dynamicTools: [CodexJSONValue] = [],
        selectedCapabilityRoots: [CodexJSONValue] = [],
        instructionSources: [String],
        approvalPolicy: CodexAppServerAskForApproval,
        approvalsReviewer: CodexAppServerApprovalsReviewer,
        sandbox: CodexAppServerSandboxPolicy,
        reasoningEffort: String?
    ) {
        self.thread = thread
        self.model = model
        self.modelProvider = modelProvider
        self.serviceTier = serviceTier
        self.cwd = cwd
        self.runtimeWorkspaceRoots = runtimeWorkspaceRoots
        self.dynamicTools = dynamicTools
        self.selectedCapabilityRoots = selectedCapabilityRoots
        self.instructionSources = instructionSources
        self.approvalPolicy = approvalPolicy
        self.approvalsReviewer = approvalsReviewer
        self.sandbox = sandbox
        self.reasoningEffort = reasoningEffort
    }

    private enum CodingKeys: String, CodingKey {
        case thread
        case model
        case modelProvider
        case serviceTier
        case cwd
        case runtimeWorkspaceRoots
        case dynamicTools
        case selectedCapabilityRoots
        case instructionSources
        case approvalPolicy
        case approvalsReviewer
        case sandbox
        case reasoningEffort
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        thread = try container.decode(
            CodexStoredThread.self,
            forKey: .thread
        )
        model = try container.decode(String.self, forKey: .model)
        guard !model.isEmpty else {
            throw DecodingError.dataCorruptedError(
                forKey: .model,
                in: container,
                debugDescription: "Resume model must not be empty"
            )
        }
        modelProvider = try container.decode(
            String.self,
            forKey: .modelProvider
        )
        guard !modelProvider.isEmpty else {
            throw DecodingError.dataCorruptedError(
                forKey: .modelProvider,
                in: container,
                debugDescription: "Resume modelProvider must not be empty"
            )
        }
        serviceTier = try container.decodeIfPresent(
            String.self,
            forKey: .serviceTier
        )
        cwd = try container.decode(String.self, forKey: .cwd)
        guard !cwd.isEmpty else {
            throw DecodingError.dataCorruptedError(
                forKey: .cwd,
                in: container,
                debugDescription: "Resume cwd must not be empty"
            )
        }
        runtimeWorkspaceRoots = try container.decodeIfPresent(
            [String].self,
            forKey: .runtimeWorkspaceRoots
        ) ?? []
        guard !runtimeWorkspaceRoots.contains(where: { $0.isEmpty }) else {
            throw DecodingError.dataCorruptedError(
                forKey: .runtimeWorkspaceRoots,
                in: container,
                debugDescription:
                    "Resume runtimeWorkspaceRoots paths must not be empty"
            )
        }
        dynamicTools = try container.decodeIfPresent(
            [CodexJSONValue].self,
            forKey: .dynamicTools
        ) ?? []
        selectedCapabilityRoots = try container.decodeIfPresent(
            [CodexJSONValue].self,
            forKey: .selectedCapabilityRoots
        ) ?? []
        instructionSources = try container.contains(.instructionSources)
            ? container.decode(
                [String].self,
                forKey: .instructionSources
            )
            : []
        guard !instructionSources.contains(where: { $0.isEmpty }) else {
            throw DecodingError.dataCorruptedError(
                forKey: .instructionSources,
                in: container,
                debugDescription:
                    "Resume instructionSources paths must not be empty"
            )
        }
        approvalPolicy = try container.decode(
            CodexAppServerAskForApproval.self,
            forKey: .approvalPolicy
        )
        approvalsReviewer = try container.decode(
            CodexAppServerApprovalsReviewer.self,
            forKey: .approvalsReviewer
        )
        sandbox = try container.decode(
            CodexAppServerSandboxPolicy.self,
            forKey: .sandbox
        )
        reasoningEffort = try container.decodeIfPresent(
            String.self,
            forKey: .reasoningEffort
        )
    }
}

public struct CodexThreadSearchHit: Codable, Equatable, Sendable {
    public var thread: CodexStoredThread
    public var snippet: String

    public init(thread: CodexStoredThread, snippet: String) {
        self.thread = thread
        self.snippet = snippet
    }
}

public struct CodexThreadSearchPage: Codable, Equatable, Sendable {
    public var data: [CodexThreadSearchHit]
    public var nextCursor: String?
    public var backwardsCursor: String?

    public init(
        data: [CodexThreadSearchHit],
        nextCursor: String?,
        backwardsCursor: String?
    ) {
        self.data = data
        self.nextCursor = nextCursor
        self.backwardsCursor = backwardsCursor
    }
}

public struct CodexThreadMetadataUpdateResult:
    Codable,
    Equatable,
    Sendable
{
    public var thread: CodexStoredThread

    public init(thread: CodexStoredThread) {
        self.thread = thread
    }
}

public struct CodexGitDiffToRemoteParams:
    Codable,
    Equatable,
    Sendable
{
    public var cwd: String

    public init(cwd: String) {
        self.cwd = cwd
    }
}

public struct CodexGitDiffToRemoteResponse:
    Codable,
    Equatable,
    Sendable
{
    public var sha: String
    public var diff: String

    public init(sha: String, diff: String) {
        self.sha = sha
        self.diff = diff
    }
}
