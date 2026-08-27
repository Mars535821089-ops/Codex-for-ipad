#if SWIFT_PACKAGE
import CodexPadDomain
#endif

public enum CodexApprovalPolicy: String, CaseIterable, Codable, Sendable {
    case untrusted
    case onFailure = "on-failure"
    case onRequest = "on-request"
    case never

    public var displayName: String {
        switch self {
        case .untrusted: "Untrusted"
        case .onFailure: "On failure"
        case .onRequest: "On request"
        case .never: "Never ask for approval"
        }
    }
}

public enum CodexSandboxMode: String, CaseIterable, Codable, Sendable {
    case readOnly = "read-only"
    case workspaceWrite = "workspace-write"
    case fullAccess = "full-access"

    public var displayName: String {
        switch self {
        case .readOnly: "Read only"
        case .workspaceWrite: "Workspace write"
        case .fullAccess: "Full access"
        }
    }
}

public enum CodexToolDecision: Equatable, Sendable {
    case allow
    case requireApproval
    case deny
}

public struct CodexExecutionPolicy: Equatable, Sendable {
    public var approvalPolicy: CodexApprovalPolicy
    public var sandboxMode: CodexSandboxMode
    public var granularApproval: CodexAppServerGranularApproval?

    public var allowsRequestPermissionsTool: Bool {
        granularApproval?.requestPermissions
            ?? (approvalPolicy != .never)
    }

    public var requiresRulesApproval: Bool {
        granularApproval?.rules ?? false
    }

    public var requiresSkillApproval: Bool {
        granularApproval?.skillApproval ?? false
    }

    public var requiresMCPElicitationApproval: Bool {
        granularApproval?.mcpElicitations ?? false
    }

    public init(
        approvalPolicy: CodexApprovalPolicy = .onRequest,
        sandboxMode: CodexSandboxMode = .workspaceWrite,
        granularApproval: CodexAppServerGranularApproval? = nil
    ) {
        self.approvalPolicy = approvalPolicy
        self.sandboxMode = sandboxMode
        self.granularApproval = granularApproval
    }

    public init(
        resumedApprovalPolicy: CodexAppServerAskForApproval,
        resumedSandboxPolicy: CodexAppServerSandboxPolicy
    ) {
        if case let .granular(granular) = resumedApprovalPolicy {
            granularApproval = granular
        } else {
            granularApproval = nil
        }
        approvalPolicy = switch resumedApprovalPolicy {
        case .untrusted:
            .untrusted
        case .onRequest:
            .onRequest
        case .granular(let granular):
            granular.sandboxApproval ? .onRequest : .never
        case .never:
            .never
        }
        sandboxMode = switch resumedSandboxPolicy {
        case .dangerFullAccess:
            .fullAccess
        case .readOnly, .externalSandbox:
            .readOnly
        case .workspaceWrite:
            .workspaceWrite
        }
    }

    public func decision(for toolName: String) -> CodexToolDecision {
        switch toolName {
        case "list_workspace_files",
             "read_workspace_file",
             "search_workspace_text":
            return .allow
        case "write_workspace_file", "apply_patch":
            guard sandboxMode != .readOnly else {
                return .deny
            }
            switch approvalPolicy {
            case .untrusted, .onRequest:
                return .requireApproval
            case .onFailure, .never:
                return .allow
            }
        case "exec_command":
            guard sandboxMode != .readOnly else {
                return .deny
            }
            switch approvalPolicy {
            case .untrusted, .onRequest:
                return .requireApproval
            case .onFailure, .never:
                return .allow
            }
        case "write_stdin":
            return sandboxMode == .readOnly ? .deny : .allow
        default:
            return .deny
        }
    }
}
