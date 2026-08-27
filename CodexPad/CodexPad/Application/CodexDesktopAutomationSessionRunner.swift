#if SWIFT_PACKAGE
    import CodexPadDomain
    import CodexPadProtocolBridge
#endif
import Foundation

/// Executes a due desktop automation through the same persisted thread and
/// turn boundaries used by the released Composer.
@MainActor
public final class CodexDesktopAutomationSessionRunner {
    private let threadReader: any CodexDesktopThreadSessionReading
    private let threadResumer: any CodexDesktopThreadSessionResuming
    private let threadStarter: any CodexDesktopThreadSessionStarting
    private let turnStarter: any CodexDesktopTurnSessionStarting
    private let threadSettingsUpdater:
        (any CodexDesktopThreadSettingsUpdating)?

    public init(
        threadReader: any CodexDesktopThreadSessionReading,
        threadResumer: any CodexDesktopThreadSessionResuming,
        threadStarter: any CodexDesktopThreadSessionStarting,
        turnStarter: any CodexDesktopTurnSessionStarting,
        threadSettingsUpdater:
            (any CodexDesktopThreadSettingsUpdating)? = nil
    ) {
        self.threadReader = threadReader
        self.threadResumer = threadResumer
        self.threadStarter = threadStarter
        self.turnStarter = turnStarter
        self.threadSettingsUpdater = threadSettingsUpdater
    }

    @discardableResult
    public func run(
        _ request: CodexDesktopAutomationRunRequest,
        now: Date = Date()
    ) throws -> CodexDesktopAutomationExecution {
        switch request.kind {
        case "cron":
            return try runCron(request, now: now)
        case "heartbeat":
            return try runHeartbeat(request, now: now)
        default:
            throw CodexDesktopAutomationStoreError.invalidRequest(
                "unsupported_automation_kind"
            )
        }
    }

    private func runCron(
        _ request: CodexDesktopAutomationRunRequest,
        now: Date
    ) throws -> CodexDesktopAutomationExecution {
        guard let requestedCWD = Self.nonempty(request.cwd) else {
            throw CodexDesktopAutomationStoreError.invalidRequest(
                "cron_cwd_required"
            )
        }
        let cwd = (requestedCWD as NSString).expandingTildeInPath
        let started = try threadStarter.startThread(
            id: requestID(phase: "thread-start"),
            params: CodexThreadStartParams(
                model: Self.wireValue(request.model),
                cwd: .value(cwd),
                threadSource: .value("automation")
            )
        )
        try applyManualThreadSettings(
            request,
            threadID: started.thread.id
        )

        _ = try turnStarter.startDesktopTurn(
            id: requestID(phase: "turn-start"),
            params: CodexTurnStartParams(
                threadID: started.thread.id,
                input: [
                    .text(
                        text: Self.cronPrompt(
                            request,
                            now: now
                        ),
                        textElements: []
                    ),
                ],
                cwd: .value(started.cwd),
                model: .value(started.model),
                effort: Self.wireValue(
                    request.reasoningEffort
                        ?? started.reasoningEffort
                )
            )
        )
        return CodexDesktopAutomationExecution(
            threadID: started.thread.id.rawValue,
            status: "PENDING_REVIEW"
        )
    }

    private func runHeartbeat(
        _ request: CodexDesktopAutomationRunRequest,
        now: Date
    ) throws -> CodexDesktopAutomationExecution {
        guard let targetThreadID = Self.nonempty(
            request.targetThreadID
        ) else {
            throw CodexDesktopAutomationStoreError.invalidRequest(
                "heartbeat_target_thread_id_required"
            )
        }
        let threadID = CodexStoredThreadID(targetThreadID)
        let read = try threadReader.readThread(
            id: requestID(phase: "thread-read"),
            params: CodexThreadReadParams(
                threadID: threadID,
                includeTurns: false
            )
        )
        if case let .active(flags) = read.thread.status,
           !flags.isEmpty
        {
            throw CodexDesktopAutomationStoreError.invalidRequest(
                "heartbeat_target_thread_busy"
            )
        }

        let resumed = try threadResumer.resumeThread(
            id: requestID(phase: "thread-resume"),
            params: CodexThreadResumeParams(
                threadID: threadID,
                cwd: .value(read.thread.cwd)
            )
        )
        try applyManualThreadSettings(
            request,
            threadID: resumed.thread.id
        )
        _ = try turnStarter.startDesktopTurn(
            id: requestID(phase: "turn-start"),
            params: CodexTurnStartParams(
                threadID: resumed.thread.id,
                input: [
                    .text(
                        text: Self.heartbeatPrompt(
                            request,
                            now: now
                        ),
                        textElements: []
                    ),
                ],
                cwd: .value(resumed.cwd),
                model: .value(resumed.model),
                effort: Self.wireValue(
                    resumed.reasoningEffort
                )
            )
        )
        return CodexDesktopAutomationExecution(
            threadID: resumed.thread.id.rawValue,
            status: "PENDING_REVIEW"
        )
    }

    private func applyManualThreadSettings(
        _ request: CodexDesktopAutomationRunRequest,
        threadID: CodexStoredThreadID
    ) throws {
        guard request.collaborationMode != nil
                || request.permissions != nil
        else {
            return
        }
        guard let threadSettingsUpdater else {
            throw CodexDesktopAutomationStoreError.invalidRequest(
                "automation_thread_settings_updater_unavailable"
            )
        }
        _ = try threadSettingsUpdater.updateThreadSettings(
            id: requestID(phase: "thread-settings-update"),
            params: CodexThreadSettingsUpdateParams(
                threadID: threadID,
                permissions: request.permissions.map(
                    CodexWireOptional.value
                ) ?? .omitted,
                collaborationMode:
                    request.collaborationMode.map(
                        CodexWireOptional.value
                    ) ?? .omitted
            )
        )
    }

    private func requestID(
        phase: String
    ) -> CodexAppServerRequestID {
        .string(
            "automation-\(phase)-"
                + UUID().uuidString.lowercased()
        )
    }

    private static func wireValue(
        _ value: String?
    ) -> CodexWireOptional<String> {
        guard let value = nonempty(value) else {
            return .omitted
        }
        return .value(value)
    }

    private static func nonempty(_ value: String?) -> String? {
        guard
            let value = value?.trimmingCharacters(
                in: .whitespacesAndNewlines
            ),
            !value.isEmpty
        else {
            return nil
        }
        return value
    }

    private static func cronPrompt(
        _ request: CodexDesktopAutomationRunRequest,
        now _: Date
    ) -> String {
        let memoryPath =
            "$CODEX_HOME/automations/"
            + request.automationID
            + "/memory.md"
        let lastRun = request.lastRunAt.map {
            iso8601(
                Date(
                    timeIntervalSince1970:
                        TimeInterval($0) / 1_000
                )
            )
        } ?? "never"
        return """
        Automation: \(request.name)
        Automation ID: \(request.automationID)
        Automation memory: \(memoryPath)
        Last run: \(lastRun)

        \(request.prompt)
        """
    }

    private static func heartbeatPrompt(
        _ request: CodexDesktopAutomationRunRequest,
        now: Date
    ) -> String {
        """
        <heartbeat>
          <automation_id>\(request.automationID)</automation_id>
          <current_time_iso>\(iso8601(now))</current_time_iso>
          <instructions>
        \(request.prompt)
          </instructions>
        </heartbeat>
        """
    }

    private static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [
            .withInternetDateTime,
            .withFractionalSeconds,
        ]
        return formatter.string(from: date)
    }
}
