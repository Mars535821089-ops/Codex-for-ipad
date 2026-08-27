import CodexPadApplication
import CodexPadDomain
import CodexPadProtocolBridge
import Foundation
import Testing

@MainActor
private final class RequestUserInputTurnTransport: CodexCoreTransport {
    let threadID = CodexStoredThreadID("thread/request-user-input")
    let turnID = "turn/request-user-input"
    private(set) var commits: [CodexRawHistoryCommit] = []
    private var events: [CodexCoreEvent] = []
    private var sequence: UInt64 = 1
    private let emitsTerminalIdleStatus: Bool

    init(emitsTerminalIdleStatus: Bool = false) {
        self.emitsTerminalIdleStatus = emitsTerminalIdleStatus
    }

    func submit(_ command: CodexCoreCommand) throws {}

    func submit(_ command: CodexRawHistoryCommit) throws {
        commits.append(command)
        events.append(
            .rawHistoryCommitted(
                CodexRawHistoryCommittedEvent(
                    sequence: sequence,
                    threadID: command.threadID,
                    turnID: command.turnID,
                    expectedNextOrder: command.expectedNextOrder,
                    entries: command.entries,
                    completion: command.completion.concreteValue
                )
            )
        )
        sequence += 1
        if emitsTerminalIdleStatus,
           command.completion.concreteValue?.endTurn == .value(true)
        {
            events.append(
                .appServerNotification(
                    .threadStatusChanged(
                        CodexThreadStatusChangedNotification(
                            threadID: command.threadID.rawValue,
                            status: .idle
                        )
                    )
                )
            )
        }
    }

    func submit(_ command: CodexCompactHistoryCommit) throws {}

    func request(_ request: CodexAppServerThreadRequest) throws -> Data {
        throw CodexCoreTransportError.unsupportedTurnRequest
    }

    func request(_ request: CodexAppServerTurnRequest) throws -> Data {
        guard case let .start(id, params) = request,
              params.threadID == threadID
        else {
            throw CodexCoreTransportError.unsupportedTurnRequest
        }
        return try JSONEncoder().encode(
            CodexAppServerReply<CodexTurnStartResult>.success(
                .init(
                    id: id,
                    result: CodexTurnStartResult(
                        turn: CodexStoredTurn(
                            id: turnID,
                            items: [],
                            itemsView: .notLoaded,
                            status: .inProgress
                        )
                    )
                )
            )
        )
    }

    func request(_ request: CodexRawHistoryRequest) throws -> Data {
        guard case let .priorInputItems(id, params) = request,
              params.threadID == threadID
        else {
            throw CodexCoreTransportError.unsupportedRawHistoryRequest
        }
        return try JSONEncoder().encode(
            CodexAppServerReply<CodexPriorInputItemsResult>.success(
                .init(
                    id: id,
                    result: CodexPriorInputItemsResult(
                        threadID: threadID,
                        throughTurnID: nil,
                        items: [],
                        completeness: .complete
                    )
                )
            )
        )
    }

    func nextEvent() throws -> CodexCoreEvent? {
        events.isEmpty ? nil : events.removeFirst()
    }
}

@MainActor
private final class RequestUserInputTurnProvider:
    CodexPersistedTurnProvider
{
    private(set) var requests: [CodexPersistedTurnProviderRequest] = []

    func stream(
        _ request: CodexPersistedTurnProviderRequest,
        cancellation: CodexTurnCancellation
    ) async -> AsyncThrowingStream<CodexCoreProviderEvent, Error> {
        requests.append(request)
        let events: [CodexCoreProviderEvent]
        if request.roundIndex == 0 {
            let arguments = """
            {"questions":[{"id":"scope","header":"Scope",\
            "question":"Which scope should be used?",\
            "options":[{"label":"Current","description":"Use current scope."},\
            {"label":"All","description":"Use every scope."}]}]}
            """
            let item = """
            {"type":"function_call","name":"request_user_input",\
            "arguments":\(Self.jsonString(arguments)),\
            "call_id":"call-request-user-input"}
            """
            events = [
                .toolCallRequested(
                    sequence: 1,
                    requestID: request.requestID,
                    name: "request_user_input",
                    arguments: arguments,
                    callID: "call-request-user-input",
                    itemJSON: item
                ),
                .responseCompleted(
                    sequence: 2,
                    requestID: request.requestID,
                    responseID: "response/questions",
                    usage: nil,
                    endTurn: false
                ),
            ]
        } else {
            events = [
                .responseItemDone(
                    sequence: 3,
                    requestID: request.requestID,
                    itemJSON: """
                    {"type":"message","role":"assistant","content":[{\
                    "type":"output_text","text":"Using current scope."}]}
                    """
                ),
                .responseCompleted(
                    sequence: 4,
                    requestID: request.requestID,
                    responseID: "response/final",
                    usage: nil,
                    endTurn: true
                ),
            ]
        }
        return AsyncThrowingStream { continuation in
            for event in events {
                continuation.yield(event)
            }
            continuation.finish()
        }
    }

    private static func jsonString(_ value: String) -> String {
        let data = try! JSONEncoder().encode(value)
        return String(decoding: data, as: UTF8.self)
    }
}

@MainActor
private final class UpdatePlanTurnProvider:
    CodexPersistedTurnProvider
{
    func stream(
        _ request: CodexPersistedTurnProviderRequest,
        cancellation: CodexTurnCancellation
    ) async -> AsyncThrowingStream<CodexCoreProviderEvent, Error> {
        let events: [CodexCoreProviderEvent]
        if request.roundIndex == 0 {
            let arguments = """
            {"explanation":"Executing batch","plan":[\
            {"step":"Wire tools","status":"in_progress"},\
            {"step":"Verify","status":"pending"}]}
            """
            let item = """
            {"type":"function_call","name":"update_plan",\
            "arguments":\(Self.jsonString(arguments)),\
            "call_id":"call-update-plan"}
            """
            events = [
                .toolCallRequested(
                    sequence: 1,
                    requestID: request.requestID,
                    name: "update_plan",
                    arguments: arguments,
                    callID: "call-update-plan",
                    itemJSON: item
                ),
                .responseCompleted(
                    sequence: 2,
                    requestID: request.requestID,
                    responseID: "response/plan",
                    usage: nil,
                    endTurn: false
                ),
            ]
        } else {
            events = [
                .responseItemDone(
                    sequence: 3,
                    requestID: request.requestID,
                    itemJSON: """
                    {"type":"message","role":"assistant","content":[{\
                    "type":"output_text","text":"Batch wired."}]}
                    """
                ),
                .responseCompleted(
                    sequence: 4,
                    requestID: request.requestID,
                    responseID: "response/final",
                    usage: nil,
                    endTurn: true
                ),
            ]
        }
        return AsyncThrowingStream { continuation in
            for event in events {
                continuation.yield(event)
            }
            continuation.finish()
        }
    }

    private static func jsonString(_ value: String) -> String {
        let data = try! JSONEncoder().encode(value)
        return String(decoding: data, as: UTF8.self)
    }
}

@MainActor
private final class ConcurrentWaitController {
    private(set) var approvalStarted = false
    private(set) var userInputStarted = false
    private(set) var approvalReturned = false
    private(set) var userInputReturned = false
    private var approvalContinuation:
        CheckedContinuation<Bool, Never>?
    private var userInputContinuation:
        CheckedContinuation<CodexRequestUserInputAnswers, any Error>?

    func requestApproval(
        _ activity: CodexPersistedTurnWorkspaceToolActivity
    ) async -> Bool {
        approvalStarted = true
        return await withCheckedContinuation { continuation in
            approvalContinuation = continuation
        }
    }

    func requestUserInput(
        _ prompt: CodexRequestUserInputPrompt
    ) async throws -> CodexRequestUserInputAnswers {
        userInputStarted = true
        return try await withCheckedThrowingContinuation { continuation in
            userInputContinuation = continuation
        }
    }

    func resumeApproval() {
        approvalContinuation?.resume(returning: true)
        approvalContinuation = nil
    }

    func resumeUserInput() {
        userInputContinuation?.resume(
            returning: CodexRequestUserInputAnswers(answers: [:])
        )
        userInputContinuation = nil
    }

    func markApprovalReturned() {
        approvalReturned = true
    }

    func markUserInputReturned() {
        userInputReturned = true
    }
}

@MainActor
private final class ConcurrentWaitToolExecutor:
    CodexPersistedTurnToolExecutor
{
    private let controller: ConcurrentWaitController
    private let approval:
        (CodexPersistedTurnWorkspaceToolActivity) async -> Bool
    private let requestUserInput:
        (CodexRequestUserInputPrompt) async throws
            -> CodexRequestUserInputAnswers

    init(
        controller: ConcurrentWaitController,
        approval:
            @escaping (
                CodexPersistedTurnWorkspaceToolActivity
            ) async -> Bool,
        requestUserInput:
            @escaping (
                CodexRequestUserInputPrompt
            ) async throws -> CodexRequestUserInputAnswers
    ) {
        self.controller = controller
        self.approval = approval
        self.requestUserInput = requestUserInput
    }

    func execute(
        _ request: CodexPersistedTurnToolRequest,
        cancellation: CodexTurnCancellation
    ) async throws -> CodexPersistedTurnLocalToolOutput {
        let activity = CodexPersistedTurnWorkspaceToolActivity(
            request: request,
            decision: .requireApproval
        )
        let approvalTask = Task { @MainActor in
            await approval(activity)
        }
        while !controller.approvalStarted {
            await Task.yield()
        }

        let prompt = CodexRequestUserInputPrompt(
            threadID: request.threadID.rawValue,
            turnID: request.turnID,
            itemID: request.callID,
            questions: [],
            autoResolutionMS: nil
        )
        let userInputTask = Task { @MainActor in
            try await requestUserInput(prompt)
        }
        while !controller.userInputStarted {
            await Task.yield()
        }

        _ = await approvalTask.value
        controller.markApprovalReturned()
        _ = try await userInputTask.value
        controller.markUserInputReturned()
        return CodexPersistedTurnLocalToolOutput(
            itemJSON: """
            {"type":"function_call_output",\
            "call_id":"\(request.callID)","output":"continued"}
            """
        )
    }
}

@MainActor
@Test
func desktopTurnRequestsUserInputWithoutAWorkspaceAndResumesSameCall()
    async throws
{
    let transport = RequestUserInputTurnTransport()
    let provider = RequestUserInputTurnProvider()
    let store = CodexSessionStore(transport: transport)
    var prompts: [CodexRequestUserInputPrompt] = []
    let runner = CodexDesktopTurnSessionRunner(
        sessionStore: store,
        providerFactory: { _ in provider },
        toolExecutorFactory: {
            _, _, requestUserInput, _ in
            CodexPersistedTurnRequestUserInputExecutor(
                prompt: requestUserInput
            )
        },
        requestUserInputRequester: { prompt in
            prompts.append(prompt)
            return CodexRequestUserInputAnswers(
                answers: [
                    "scope": CodexRequestUserInputAnswer(
                        answers: ["Current"]
                    )
                ]
            )
        },
        notificationSink: { _ in }
    )

    let started = try runner.startDesktopTurn(
        id: .string("start/request-user-input"),
        params: CodexTurnStartParams(
            threadID: transport.threadID,
            input: [.text(text: "Continue", textElements: [])]
        )
    )
    await runner.waitForTurn(started.turn.id)

    #expect(prompts.count == 1)
    #expect(prompts[0].threadID == transport.threadID.rawValue)
    #expect(prompts[0].turnID == transport.turnID)
    #expect(prompts[0].itemID == "call-request-user-input")
    #expect(provider.requests.count == 2)
    let secondRound = try #require(provider.requests.last)
    #expect(secondRound.currentTurnInputItems.count == 2)
    let outputData = Data(secondRound.currentTurnInputItems[1].utf8)
    let output = try #require(
        JSONSerialization.jsonObject(with: outputData)
            as? [String: Any]
    )
    #expect(output["type"] as? String == "function_call_output")
    #expect(output["call_id"] as? String == "call-request-user-input")
    let rawAnswers = try #require(output["output"] as? String)
    let answers = try JSONDecoder().decode(
        CodexRequestUserInputAnswers.self,
        from: Data(rawAnswers.utf8)
    )
    #expect(answers.answers["scope"]?.answers == ["Current"])
    #expect(transport.commits.count == 3)
}

@MainActor
@Test
func desktopTurnPublishesAndRetainsUpdatePlanInTerminalTurn()
    async throws
{
    let transport = RequestUserInputTurnTransport()
    let provider = UpdatePlanTurnProvider()
    let store = CodexSessionStore(transport: transport)
    var notifications: [CodexAppServerTurnNotification] = []
    let runner = CodexDesktopTurnSessionRunner(
        sessionStore: store,
        providerFactory: { _ in provider },
        toolExecutorFactory: {
            _, _, _, publishPlan in
            CodexPersistedTurnUpdatePlanExecutor(
                publish: publishPlan
            )
        },
        notificationSink: {
            notifications.append($0)
        }
    )

    let started = try runner.startDesktopTurn(
        id: .string("start/update-plan"),
        params: CodexTurnStartParams(
            threadID: transport.threadID,
            input: [.text(text: "Continue", textElements: [])]
        )
    )
    await runner.waitForTurn(started.turn.id)

    let planUpdateWires = try notifications
        .map(CodexAppServerTurnNotificationEncoder.wire)
        .filter { $0.method == "turn/plan/updated" }
    let planUpdate = try #require(planUpdateWires.last)
    #expect(
        planUpdate.params == .object([
            "threadId": .string(transport.threadID.rawValue),
            "turnId": .string(transport.turnID),
            "explanation": .string("Executing batch"),
            "plan": .array([
                .object([
                    "step": .string("Wire tools"),
                    "status": .string("in_progress"),
                ]),
                .object([
                    "step": .string("Verify"),
                    "status": .string("pending"),
                ]),
            ]),
        ])
    )

    let completedPlans: [String] =
        notifications.compactMap { notification -> String? in
            guard case let .itemCompleted(payload) = notification,
                  case let .plan(_, text) = payload.item
            else {
                return nil
            }
            return text
        }
    let completedPlan = try #require(
        completedPlans.last { $0.contains("[>] Wire tools") }
    )
    #expect(completedPlan.contains("Executing batch"))
    #expect(completedPlan.contains("[>] Wire tools"))
    #expect(completedPlan.contains("[ ] Verify"))

    let terminalTurns: [CodexStoredTurn] =
        notifications.compactMap { notification -> CodexStoredTurn? in
            guard case let .turnCompleted(payload) = notification else {
                return nil
            }
            return payload.turn
        }
    let terminal = try #require(terminalTurns.last)
    #expect(terminal.status == .completed)
    #expect(terminal.items.contains { item in
        guard case .plan = item else {
            return false
        }
        return true
    })
}

@MainActor
@Test
func desktopTurnForwardsTerminalCoreIdleWithoutAnotherMCPRequest()
    async throws
{
    let transport = RequestUserInputTurnTransport(
        emitsTerminalIdleStatus: true
    )
    let provider = UpdatePlanTurnProvider()
    let store = CodexSessionStore(transport: transport)
    var appServerNotifications: [CodexAppServerNotification] = []
    let runner = CodexDesktopTurnSessionRunner(
        sessionStore: store,
        providerFactory: { _ in provider },
        toolExecutorFactory: {
            _, _, _, publishPlan in
            CodexPersistedTurnUpdatePlanExecutor(
                publish: publishPlan
            )
        },
        notificationSink: { _ in },
        appServerNotificationSink: {
            appServerNotifications.append(contentsOf: $0)
        }
    )

    let started = try runner.startDesktopTurn(
        id: .string("start/terminal-idle"),
        params: CodexTurnStartParams(
            threadID: transport.threadID,
            input: [.text(text: "Continue", textElements: [])]
        )
    )
    await runner.waitForTurn(started.turn.id)

    #expect(
        appServerNotifications == [
            .threadStatusChanged(
                CodexThreadStatusChangedNotification(
                    threadID: transport.threadID.rawValue,
                    status: .idle
                )
            )
        ]
    )
    #expect(store.takeAppServerNotifications().isEmpty)
}

@MainActor
@Test
func desktopTurnPublishesOrderedActiveFlagsForConcurrentWaits()
    async throws
{
    let transport = RequestUserInputTurnTransport(
        emitsTerminalIdleStatus: true
    )
    let provider = UpdatePlanTurnProvider()
    let store = CodexSessionStore(transport: transport)
    let controller = ConcurrentWaitController()
    var statuses: [CodexStoredThreadStatus] = []
    let runner = CodexDesktopTurnSessionRunner(
        sessionStore: store,
        providerFactory: { _ in provider },
        toolExecutorFactory: {
            _, approval, requestUserInput, _ in
            ConcurrentWaitToolExecutor(
                controller: controller,
                approval: approval,
                requestUserInput: requestUserInput
            )
        },
        approvalRequester: {
            await controller.requestApproval($0)
        },
        requestUserInputRequester: {
            try await controller.requestUserInput($0)
        },
        notificationSink: { _ in },
        appServerNotificationSink: { notifications in
            statuses.append(
                contentsOf: notifications.compactMap { notification in
                    guard case let .threadStatusChanged(payload) =
                        notification,
                          payload.threadID
                            == transport.threadID.rawValue
                    else {
                        return nil
                    }
                    return payload.status
                }
            )
        }
    )

    let started = try runner.startDesktopTurn(
        id: .string("start/concurrent-active-flags"),
        params: CodexTurnStartParams(
            threadID: transport.threadID,
            input: [.text(text: "Continue", textElements: [])]
        )
    )
    while !controller.approvalStarted
        || !controller.userInputStarted
    {
        await Task.yield()
    }
    #expect(
        statuses == [
            .active([.waitingOnApproval]),
            .active([
                .waitingOnApproval,
                .waitingOnUserInput,
            ]),
        ]
    )

    controller.resumeApproval()
    while !controller.approvalReturned {
        await Task.yield()
    }
    #expect(statuses.last == .active([.waitingOnUserInput]))

    controller.resumeUserInput()
    await runner.waitForTurn(started.turn.id)
    #expect(controller.userInputReturned)
    #expect(
        statuses == [
            .active([.waitingOnApproval]),
            .active([
                .waitingOnApproval,
                .waitingOnUserInput,
            ]),
            .active([.waitingOnUserInput]),
            .active([]),
            .idle,
        ]
    )
}

@MainActor
@Test
func desktopTurnRunnerEmitsMCPProgressOnlyForMatchingActiveTurn()
    async throws
{
    let transport = RequestUserInputTurnTransport()
    let provider = RequestUserInputTurnProvider()
    let store = CodexSessionStore(transport: transport)
    var notifications: [CodexAppServerTurnNotification] = []
    let runner = CodexDesktopTurnSessionRunner(
        sessionStore: store,
        providerFactory: { _ in provider },
        notificationSink: {
            notifications.append($0)
        }
    )
    let started = try runner.startDesktopTurn(
        id: .string("start/mcp-progress"),
        params: CodexTurnStartParams(
            threadID: transport.threadID,
            input: [.text(text: "Continue", textElements: [])]
        )
    )
    let countBeforeProgress = notifications.count

    runner.emitMCPToolProgress(
        CodexMCPToolProgress(
            threadID: transport.threadID,
            turnID: started.turn.id,
            itemID: "call-progress",
            message: "halfway"
        )
    )
    #expect(notifications.count == countBeforeProgress + 1)
    guard case let .mcpToolCallProgress(progress) =
        notifications.last
    else {
        Issue.record("expected item/mcpToolCall/progress")
        runner.interrupt(turnID: started.turn.id)
        await runner.waitForTurn(started.turn.id)
        return
    }
    #expect(progress.threadID == transport.threadID)
    #expect(progress.turnID == started.turn.id)
    #expect(progress.itemID == "call-progress")
    #expect(progress.message == "halfway")

    runner.emitMCPToolProgress(
        CodexMCPToolProgress(
            threadID: .init("thread/other"),
            turnID: started.turn.id,
            itemID: "call-progress",
            message: "must be ignored"
        )
    )
    runner.emitMCPToolProgress(
        CodexMCPToolProgress(
            threadID: transport.threadID,
            turnID: "turn/not-active",
            itemID: "call-progress",
            message: "must be ignored"
        )
    )
    #expect(notifications.count == countBeforeProgress + 1)

    runner.interrupt(turnID: started.turn.id)
    runner.emitMCPToolProgress(
        CodexMCPToolProgress(
            threadID: transport.threadID,
            turnID: started.turn.id,
            itemID: "call-progress",
            message: "late"
        )
    )
    #expect(notifications.count == countBeforeProgress + 1)
    await runner.waitForTurn(started.turn.id)
}

private extension CodexWireOptional {
    var concreteValue: Value? {
        if case let .value(value) = self {
            return value
        }
        return nil
    }
}
