#if SWIFT_PACKAGE
import CodexPadDomain
import CodexPadProtocolBridge
#endif

public enum CodexThreadResumePhase: Equatable, Sendable {
    case idle
    case resuming
    case resumed
    case failed
}

public enum CodexCollaborationModeWireResolver {
    public static func resolve(
        collaborationMode:
            CodexWireOptional<CodexCollaborationMode>,
        model: CodexWireOptional<String>,
        effort: CodexWireOptional<String>,
        stored: CodexCollaborationMode?,
        fallback: CodexCollaborationMode
    ) -> CodexCollaborationMode {
        switch collaborationMode {
        case let .value(value):
            return value
        case .null, .omitted:
            var resolved = stored ?? fallback
            if case let .value(value) = model {
                resolved.settings.model = value
            }
            if case let .value(value) = effort {
                resolved.settings.reasoningEffort = value
            }
            return resolved
        }
    }
}

public struct CodexThreadResumeRequest: Equatable, Sendable {
    public let params: CodexThreadResumeParams
    fileprivate let token: UInt64

    public var threadID: CodexStoredThreadID {
        params.threadID
    }
}

public enum CodexThreadResumeRequestFactory {
    public static func make(
        threadID: CodexStoredThreadID,
        model: String,
        modelProvider: String,
        reasoningEffort: String,
        cwd: String,
        approvalPolicy: CodexAppServerAskForApproval,
        approvalsReviewer: CodexAppServerApprovalsReviewer,
        sandbox: CodexAppServerSandboxMode
    ) -> CodexThreadResumeParams {
        CodexThreadResumeParams(
            threadID: threadID,
            model: .value(model),
            modelProvider: .value(modelProvider),
            cwd: .value(cwd),
            approvalPolicy: .value(approvalPolicy),
            approvalsReviewer: .value(approvalsReviewer),
            sandbox: .value(sandbox),
            config: .value([
                "model_reasoning_effort": .string(reasoningEffort)
            ])
        )
    }
}

public struct CodexThreadResumeViewState: Equatable, Sendable {
    public private(set) var selectedThreadID: CodexStoredThreadID?
    public private(set) var phase: CodexThreadResumePhase
    public private(set) var resumeResult: CodexThreadResumeResult?
    public private(set) var errorMessage: String?

    private var requestToken: UInt64

    public init() {
        selectedThreadID = nil
        phase = .idle
        resumeResult = nil
        errorMessage = nil
        requestToken = 0
    }

    public mutating func selectThread(_ threadID: CodexStoredThreadID) {
        requestToken &+= 1
        selectedThreadID = threadID
        phase = .idle
        resumeResult = nil
        errorMessage = nil
    }

    public mutating func clearSelection() {
        requestToken &+= 1
        selectedThreadID = nil
        phase = .idle
        resumeResult = nil
        errorMessage = nil
    }

    public mutating func beginResume(
        _ params: CodexThreadResumeParams
    ) -> CodexThreadResumeRequest? {
        guard let selectedThreadID,
              params.threadID.rawValue == selectedThreadID.rawValue
        else {
            return nil
        }
        requestToken &+= 1
        phase = .resuming
        resumeResult = nil
        errorMessage = nil
        return CodexThreadResumeRequest(
            params: params,
            token: requestToken
        )
    }

    public var resumedThread: CodexStoredThreadPresentation? {
        resumeResult.map {
            CodexStoredThreadPresentation(thread: $0.thread)
        }
    }

    public mutating func receiveResumeResult(
        _ result: CodexThreadResumeResult,
        for request: CodexThreadResumeRequest
    ) {
        guard accepts(request),
              result.thread.id == request.threadID
        else {
            return
        }
        resumeResult = result
        errorMessage = nil
        phase = .resumed
    }

    public mutating func failResume(
        _ message: String,
        for request: CodexThreadResumeRequest
    ) {
        guard accepts(request) else {
            return
        }
        resumeResult = nil
        errorMessage = message
        phase = .failed
    }

    @discardableResult
    public mutating func reconcileResumedThread(
        with presentation: CodexStoredThreadPresentation
    ) -> Bool {
        guard phase == .resumed,
              selectedThreadID == presentation.id,
              resumeResult?.thread.id == presentation.id
        else {
            return false
        }
        resumeResult?.thread = presentation.storedThread
        return true
    }

    @discardableResult
    public mutating func reconcileThreadSettings(
        _ notification: CodexThreadSettingsUpdatedNotification
    ) -> Bool {
        guard phase == .resumed,
              selectedThreadID == notification.threadID,
              resumeResult?.thread.id == notification.threadID
        else {
            return false
        }
        let settings = notification.threadSettings
        resumeResult?.model = settings.model
        resumeResult?.modelProvider = settings.modelProvider
        resumeResult?.serviceTier = settings.serviceTier
        resumeResult?.cwd = settings.cwd
        resumeResult?.approvalPolicy = settings.approvalPolicy
        resumeResult?.approvalsReviewer = settings.approvalsReviewer
        resumeResult?.sandbox = settings.sandboxPolicy
        resumeResult?.reasoningEffort = settings.effort
        return true
    }

    private func accepts(_ request: CodexThreadResumeRequest) -> Bool {
        request.token == requestToken
            && selectedThreadID == request.threadID
    }
}

public struct CodexResumedThreadRuntimeSettings:
    Equatable,
    Sendable
{
    public let model: String
    public let modelProvider: String
    public let serviceTier: String?
    public let cwd: String
    public let approvalPolicy: CodexAppServerAskForApproval
    public let approvalsReviewer: CodexAppServerApprovalsReviewer
    public let sandboxPolicy: CodexAppServerSandboxPolicy
    public let effort: String?
    public let summary: CodexAppServerReasoningSummary?
    public let personality: CodexAppServerPersonality?
    public let collaborationMode: CodexCollaborationMode?
    public let multiAgentMode: CodexMultiAgentMode?

    public var proposedPlanStreamingEnabled: Bool {
        collaborationMode?.mode == .plan
    }

    private let hasAuthoritativeSettings: Bool

    public init(
        resumeResult: CodexThreadResumeResult,
        authoritativeSettings: CodexAppServerThreadSettings?
    ) {
        if let authoritativeSettings {
            model = authoritativeSettings.model
            modelProvider = authoritativeSettings.modelProvider
            serviceTier = authoritativeSettings.serviceTier
            cwd = authoritativeSettings.cwd
            approvalPolicy = authoritativeSettings.approvalPolicy
            approvalsReviewer =
                authoritativeSettings.approvalsReviewer
            sandboxPolicy = authoritativeSettings.sandboxPolicy
            effort = authoritativeSettings.effort
            summary = authoritativeSettings.summary
            personality = authoritativeSettings.personality
            collaborationMode = authoritativeSettings.collaborationMode
            multiAgentMode = authoritativeSettings.multiAgentMode
            hasAuthoritativeSettings = true
        } else {
            model = resumeResult.model
            modelProvider = resumeResult.modelProvider
            serviceTier = resumeResult.serviceTier
            cwd = resumeResult.cwd
            approvalPolicy = resumeResult.approvalPolicy
            approvalsReviewer = resumeResult.approvalsReviewer
            sandboxPolicy = resumeResult.sandbox
            effort = resumeResult.reasoningEffort
            summary = nil
            personality = nil
            collaborationMode = nil
            multiAgentMode = nil
            hasAuthoritativeSettings = false
        }
    }

    public func makeTurnStartParams(
        threadID: CodexStoredThreadID,
        input: [CodexStoredUserInput],
        clientUserMessageID: String?,
        modelOverride: String? = nil
    ) -> CodexTurnStartParams {
        CodexTurnStartParams(
            threadID: threadID,
            input: input,
            clientUserMessageID: clientUserMessageID.map(
                CodexWireOptional.value
            ) ?? .omitted,
            cwd: .value(cwd),
            approvalPolicy: .value(approvalPolicy),
            approvalsReviewer: .value(approvalsReviewer),
            sandboxPolicy: .value(sandboxPolicy),
            model: .value(modelOverride ?? model),
            serviceTier: serviceTier.map(CodexWireOptional.value)
                ?? (hasAuthoritativeSettings ? .null : .omitted),
            effort: effort.map(CodexWireOptional.value)
                ?? (hasAuthoritativeSettings ? .null : .omitted),
            summary: hasAuthoritativeSettings
                ? summary.map(CodexWireOptional.value) ?? .null
                : .omitted,
            collaborationMode: hasAuthoritativeSettings
                ? collaborationMode.map(CodexWireOptional.value) ?? .null
                : .omitted,
            multiAgentMode: hasAuthoritativeSettings
                ? multiAgentMode.map(CodexWireOptional.value) ?? .null
                : .omitted,
            personality: hasAuthoritativeSettings
                ? personality.map(CodexWireOptional.value) ?? .null
                : .omitted
        )
    }
}
