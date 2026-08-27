import CodexPadDomain
import CodexPadProtocolBridge
import Foundation
import Testing

@testable import CodexPadApplication

@MainActor
private final class AutomationSessionStub:
    CodexDesktopThreadSessionReading,
    CodexDesktopThreadSessionResuming,
    CodexDesktopThreadSessionStarting,
    CodexDesktopTurnSessionStarting,
    CodexDesktopThreadSettingsUpdating
{
    var readParams: CodexThreadReadParams?
    var resumeParams: CodexThreadResumeParams?
    var startParams: CodexThreadStartParams?
    var turnParams: CodexTurnStartParams?
    var settingsParams: CodexThreadSettingsUpdateParams?

    let readResult: CodexThreadReadResult
    let resumeResult: CodexThreadResumeResult
    let startResult: CodexThreadResumeResult

    init(
        readResult: CodexThreadReadResult,
        resumeResult: CodexThreadResumeResult,
        startResult: CodexThreadResumeResult
    ) {
        self.readResult = readResult
        self.resumeResult = resumeResult
        self.startResult = startResult
    }

    func readThread(
        id _: CodexAppServerRequestID,
        params: CodexThreadReadParams
    ) throws -> CodexThreadReadResult {
        readParams = params
        return readResult
    }

    func resumeThread(
        id _: CodexAppServerRequestID,
        params: CodexThreadResumeParams
    ) throws -> CodexThreadResumeResult {
        resumeParams = params
        return resumeResult
    }

    func startThread(
        id _: CodexAppServerRequestID,
        params: CodexThreadStartParams
    ) throws -> CodexThreadResumeResult {
        startParams = params
        return startResult
    }

    func startDesktopTurn(
        id _: CodexAppServerRequestID,
        params: CodexTurnStartParams
    ) throws -> CodexTurnStartResult {
        turnParams = params
        return CodexTurnStartResult(
            turn: CodexStoredTurn(
                id: "turn-automation",
                items: [],
                itemsView: .notLoaded,
                status: .inProgress
            )
        )
    }

    func updateThreadSettings(
        id _: CodexAppServerRequestID,
        params: CodexThreadSettingsUpdateParams
    ) throws -> CodexThreadSettingsUpdateResponse {
        settingsParams = params
        return CodexThreadSettingsUpdateResponse()
    }
}

private func automationSessionThread(
    id: String,
    cwd: String,
    status: CodexStoredThreadStatus = .idle
) -> CodexStoredThread {
    CodexStoredThread(
        id: CodexStoredThreadID(id),
        sessionID: "session-\(id)",
        preview: "",
        ephemeral: false,
        modelProvider: "openai",
        createdAt: 100,
        updatedAt: 200,
        status: status,
        path: "/rollouts/\(id).jsonl",
        cwd: cwd,
        cliVersion: "0.146.0",
        source: .named(.appServer),
        threadSource: "automation",
        turns: []
    )
}

private func automationSessionResumeResult(
    thread: CodexStoredThread,
    cwd: String,
    model: String,
    effort: String?
) -> CodexThreadResumeResult {
    CodexThreadResumeResult(
        thread: thread,
        model: model,
        modelProvider: "openai",
        serviceTier: nil,
        cwd: cwd,
        instructionSources: [],
        approvalPolicy: .onRequest,
        approvalsReviewer: .user,
        sandbox: .workspaceWrite(
            writableRoots: [cwd],
            networkAccess: true,
            excludeTmpdirEnvVar: false,
            excludeSlashTmp: false
        ),
        reasoningEffort: effort
    )
}

@Test
@MainActor
func automationSessionRunnerStartsCronThreadAndRealTurn() throws {
    let cronThread = automationSessionThread(
        id: "thread-cron",
        cwd: "/workspace/resolved"
    )
    let heartbeatThread = automationSessionThread(
        id: "thread-heartbeat",
        cwd: "/workspace/heartbeat"
    )
    let stub = AutomationSessionStub(
        readResult: CodexThreadReadResult(thread: heartbeatThread),
        resumeResult: automationSessionResumeResult(
            thread: heartbeatThread,
            cwd: heartbeatThread.cwd,
            model: "heartbeat-model",
            effort: "medium"
        ),
        startResult: automationSessionResumeResult(
            thread: cronThread,
            cwd: cronThread.cwd,
            model: "resolved-model",
            effort: "medium"
        )
    )
    let runner = CodexDesktopAutomationSessionRunner(
        threadReader: stub,
        threadResumer: stub,
        threadStarter: stub,
        turnStarter: stub,
        threadSettingsUpdater: stub
    )

    let result = try runner.run(
        CodexDesktopAutomationRunRequest(
            automationID: "morning-review",
            kind: "cron",
            name: "Morning review",
            prompt: "Review the project.",
            targetThreadID: nil,
            projectID: "project-1",
            cwd: "/workspace/requested",
            model: "requested-model",
            reasoningEffort: "high",
            lastRunAt: nil
        ),
        now: Date(timeIntervalSince1970: 1_785_686_400)
    )

    #expect(stub.readParams == nil)
    #expect(stub.resumeParams == nil)
    #expect(stub.startParams?.model == .value("requested-model"))
    #expect(stub.startParams?.cwd == .value("/workspace/requested"))
    #expect(stub.startParams?.threadSource == .value("automation"))
    #expect(stub.turnParams?.threadID == cronThread.id)
    #expect(stub.turnParams?.cwd == .value("/workspace/resolved"))
    #expect(stub.turnParams?.model == .value("resolved-model"))
    #expect(stub.turnParams?.effort == .value("high"))
    guard case let .text(text, textElements)? =
        stub.turnParams?.input.first
    else {
        Issue.record("cron automation must submit a text turn")
        return
    }
    #expect(textElements.isEmpty)
    #expect(text.contains("Automation ID: morning-review"))
    #expect(text.contains("Last run: never"))
    #expect(text.hasSuffix("Review the project."))
    #expect(
        result == CodexDesktopAutomationExecution(
            threadID: "thread-cron",
            status: "PENDING_REVIEW"
        )
    )
}

@Test
@MainActor
func automationSessionRunnerResumesHeartbeatWithResolvedConfiguration()
    throws
{
    let target = automationSessionThread(
        id: "thread-heartbeat",
        cwd: "/workspace/original"
    )
    let resumed = automationSessionResumeResult(
        thread: target,
        cwd: "/workspace/resumed",
        model: "thread-model",
        effort: "xhigh"
    )
    let stub = AutomationSessionStub(
        readResult: CodexThreadReadResult(thread: target),
        resumeResult: resumed,
        startResult: resumed
    )
    let runner = CodexDesktopAutomationSessionRunner(
        threadReader: stub,
        threadResumer: stub,
        threadStarter: stub,
        turnStarter: stub,
        threadSettingsUpdater: stub
    )

    let result = try runner.run(
        CodexDesktopAutomationRunRequest(
            automationID: "heartbeat-check",
            kind: "heartbeat",
            name: "Heartbeat check",
            prompt: "Check whether the task needs attention.",
            targetThreadID: target.id.rawValue,
            projectID: nil,
            cwd: nil,
            model: nil,
            reasoningEffort: nil,
            lastRunAt: nil,
            collaborationMode: CodexCollaborationMode(
                mode: .plan,
                settings: CodexCollaborationModeSettings(
                    model: "thread-model",
                    reasoningEffort: "xhigh",
                    developerInstructions:
                        "Continue the heartbeat carefully."
                )
            ),
            permissions: "full"
        ),
        now: Date(timeIntervalSince1970: 1_785_686_400)
    )

    #expect(stub.startParams == nil)
    #expect(
        stub.readParams
            == CodexThreadReadParams(
                threadID: target.id,
                includeTurns: false
            )
    )
    #expect(stub.resumeParams?.threadID == target.id)
    #expect(stub.resumeParams?.cwd == .value("/workspace/original"))
    #expect(stub.settingsParams?.threadID == target.id)
    #expect(stub.settingsParams?.permissions == .value("full"))
    guard case let .value(collaborationMode)? =
        stub.settingsParams?.collaborationMode
    else {
        Issue.record(
            "manual heartbeat must update collaboration mode"
        )
        return
    }
    #expect(collaborationMode.mode == .plan)
    #expect(stub.turnParams?.threadID == target.id)
    #expect(stub.turnParams?.cwd == .value("/workspace/resumed"))
    #expect(stub.turnParams?.model == .value("thread-model"))
    #expect(stub.turnParams?.effort == .value("xhigh"))
    guard case let .text(text, _)? = stub.turnParams?.input.first else {
        Issue.record("heartbeat automation must submit a text turn")
        return
    }
    #expect(text.contains("<automation_id>heartbeat-check</automation_id>"))
    #expect(
        text.contains(
            "<instructions>\nCheck whether the task needs attention."
        )
    )
    #expect(
        result == CodexDesktopAutomationExecution(
            threadID: target.id.rawValue,
            status: "PENDING_REVIEW"
        )
    )
}
