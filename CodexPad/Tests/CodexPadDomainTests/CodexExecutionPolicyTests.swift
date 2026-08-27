import Testing
@testable import CodexPadApplication
@testable import CodexPadDomain

struct CodexExecutionPolicyTests {
    @Test
    func readToolIsAllowedInReadOnlySandbox() {
        let policy = CodexExecutionPolicy(
            approvalPolicy: .onRequest,
            sandboxMode: .readOnly
        )

        #expect(policy.decision(for: "read_workspace_file") == .allow)
    }

    @Test
    func writeToolIsDeniedInReadOnlySandbox() {
        let policy = CodexExecutionPolicy(
            approvalPolicy: .never,
            sandboxMode: .readOnly
        )

        #expect(policy.decision(for: "write_workspace_file") == .deny)
    }

    @Test
    func writeToolRequestsApprovalInOnRequestMode() {
        let policy = CodexExecutionPolicy(
            approvalPolicy: .onRequest,
            sandboxMode: .workspaceWrite
        )

        #expect(
            policy.decision(for: "write_workspace_file")
                == .requireApproval
        )
    }

    @Test
    func writeToolRunsDirectlyWhenApprovalIsNeverRequested() {
        let policy = CodexExecutionPolicy(
            approvalPolicy: .never,
            sandboxMode: .workspaceWrite
        )

        #expect(policy.decision(for: "write_workspace_file") == .allow)
    }

    @Test
    func applyPatchUsesTheSameWriteApprovalBoundary() {
        #expect(
            CodexExecutionPolicy(
                approvalPolicy: .never,
                sandboxMode: .readOnly
            ).decision(for: "apply_patch") == .deny
        )
        #expect(
            CodexExecutionPolicy(
                approvalPolicy: .onRequest,
                sandboxMode: .workspaceWrite
            ).decision(for: "apply_patch") == .requireApproval
        )
        #expect(
            CodexExecutionPolicy(
                approvalPolicy: .never,
                sandboxMode: .workspaceWrite
            ).decision(for: "apply_patch") == .allow
        )
    }

    @Test
    func unknownToolIsDenied() {
        let policy = CodexExecutionPolicy(
            approvalPolicy: .never,
            sandboxMode: .fullAccess
        )

        #expect(policy.decision(for: "unknown_tool") == .deny)
    }

    @Test
    func policyLabelsMatchRecoveredDesktopSettings() {
        #expect(CodexApprovalPolicy.untrusted.displayName == "Untrusted")
        #expect(CodexApprovalPolicy.onFailure.displayName == "On failure")
        #expect(CodexApprovalPolicy.onRequest.displayName == "On request")
        #expect(
            CodexApprovalPolicy.never.displayName
                == "Never ask for approval"
        )
        #expect(CodexSandboxMode.readOnly.displayName == "Read only")
        #expect(
            CodexSandboxMode.workspaceWrite.displayName == "Workspace write"
        )
        #expect(CodexSandboxMode.fullAccess.displayName == "Full access")
    }

    @Test
    func resumedPolicyControlsPersistedWorkspaceToolsExactly() {
        let granularWithoutSandboxPrompt = CodexExecutionPolicy(
            resumedApprovalPolicy: .granular(
                .init(
                    sandboxApproval: false,
                    rules: true,
                    mcpElicitations: true
                )
            ),
            resumedSandboxPolicy: .workspaceWrite(
                writableRoots: ["/project"],
                networkAccess: false,
                excludeTmpdirEnvVar: true,
                excludeSlashTmp: true
            )
        )
        #expect(
            granularWithoutSandboxPrompt.decision(
                for: "write_workspace_file"
            ) == .allow
        )

        let granularWithSandboxPrompt = CodexExecutionPolicy(
            resumedApprovalPolicy: .granular(
                .init(
                    sandboxApproval: true,
                    rules: false,
                    mcpElicitations: false
                )
            ),
            resumedSandboxPolicy: .workspaceWrite(
                writableRoots: [],
                networkAccess: false,
                excludeTmpdirEnvVar: false,
                excludeSlashTmp: false
            )
        )
        #expect(
            granularWithSandboxPrompt.decision(
                for: "write_workspace_file"
            ) == .requireApproval
        )

        let externalSandbox = CodexExecutionPolicy(
            resumedApprovalPolicy: .never,
            resumedSandboxPolicy: .externalSandbox(
                networkAccess: .restricted
            )
        )
        #expect(
            externalSandbox.decision(for: "write_workspace_file")
                == .deny
        )
    }

    @Test
    func granularPolicyPreservesEveryDesktopApprovalDimension() {
        let granular = CodexAppServerGranularApproval(
            sandboxApproval: false,
            rules: true,
            skillApproval: true,
            requestPermissions: true,
            mcpElicitations: false
        )
        let policy = CodexExecutionPolicy(
            resumedApprovalPolicy: .granular(granular),
            resumedSandboxPolicy: .dangerFullAccess
        )

        #expect(policy.granularApproval == granular)
        #expect(policy.allowsRequestPermissionsTool)
        #expect(policy.requiresRulesApproval)
        #expect(policy.requiresSkillApproval)
        #expect(!policy.requiresMCPElicitationApproval)
    }
}
