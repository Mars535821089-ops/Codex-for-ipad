import CodexPadApplication
import CodexPadDomain
import CodexPadProtocolBridge
import Foundation
import Testing

@Test
func desktopTurnNotificationProjectorMatchesRendererLifecycle() throws {
    let threadID = CodexStoredThreadID("thread/raw")
    let turnID = "turn/raw"
    var projector = CodexDesktopTurnNotificationProjector(
        threadID: threadID,
        turnID: turnID,
        startedAtMs: 1_722_330_000_000
    )

    let initial = CodexStoredTurn(
        id: turnID,
        items: [],
        itemsView: .notLoaded,
        status: .inProgress,
        startedAt: 1_722_330_000_000
    )
    let started = projector.started(turn: initial)
    #expect(started.count == 1)
    guard case .turnStarted(let startedPayload) = started[0] else {
        Issue.record("expected turn/started")
        return
    }
    #expect(startedPayload.threadID == threadID)

    let deltas = projector.providerEvent(
        .assistantTextDelta(
            sequence: 1,
            requestID: turnID,
            delta: "完成"
        )
    )
    #expect(deltas.count == 2)
    guard case .itemStarted(let itemPayload) = deltas[0] else {
        Issue.record("expected deferred item/started")
        return
    }
    #expect(itemPayload.turnID == turnID)
    guard case .agentMessageDelta(let delta) = deltas[1] else {
        Issue.record("expected item/agentMessage/delta")
        return
    }
    #expect(delta.delta == "完成")

    let realtime = projector.providerEvent(
        .realtime(
            sequence: 2,
            requestID: turnID,
            eventType: "reasoning_summary_delta",
            payload: .object(["delta": .string("检查")])
        )
    )
    #expect(realtime.count == 1)
    guard case let .opaque(method, rawEnvelope) = realtime[0] else {
        Issue.record("expected provider realtime opaque notification")
        return
    }
    #expect(method == "provider/reasoning_summary_delta")
    #expect(
        rawEnvelope == .object([
            "method": .string("provider/reasoning_summary_delta"),
            "params": .object([
                "threadId": .string(threadID.rawValue),
                "turnId": .string(turnID),
                "eventType": .string("reasoning_summary_delta"),
                "payload": .object(["delta": .string("检查")]),
            ]),
        ])
    )

    let completion = projector.providerEvent(
        .responseCompleted(
            sequence: 2,
            requestID: turnID,
            responseID: "response/raw",
            usage: CodexTokenUsageBreakdown(
                totalTokens: 12,
                inputTokens: 4,
                cachedInputTokens: 0,
                outputTokens: 8,
                reasoningOutputTokens: 2
            ),
            endTurn: true
        )
    )
    #expect(completion.count == 4)
    guard case .turnCompleted(let completed) = completion.last else {
        Issue.record("expected turn/completed")
        return
    }
    #expect(completed.turn.status == .completed)
    #expect(completed.turn.items.count == 1)

    let duplicateCompletion = projector.providerEvent(
        .responseCompleted(
            sequence: 3,
            requestID: turnID,
            responseID: "response/raw",
            usage: nil,
            endTurn: true
        )
    )
    #expect(duplicateCompletion.isEmpty)
}

@Test
func desktopTurnNotificationProjectorProjectsReasoningRealtimeNotifications() {
    let threadID = CodexStoredThreadID("thread/reasoning-stream")
    let turnID = "turn/reasoning-stream"
    var projector = CodexDesktopTurnNotificationProjector(
        threadID: threadID,
        turnID: turnID,
        startedAtMs: 100
    )

    let added = projector.providerEvent(
        .realtime(
            sequence: 1,
            requestID: turnID,
            eventType: "output_item_added",
            payload: .object([
                "type": .string("reasoning"),
                "id": .string("reasoning-stream-1"),
                "summary": .array([]),
                "content": .array([]),
            ])
        )
    )
    #expect(added.count == 1)
    guard case .opaque = added[0] else {
        Issue.record("expected output_item_added to remain opaque")
        return
    }

    let summaryDelta = projector.providerEvent(
        .realtime(
            sequence: 2,
            requestID: turnID,
            eventType: "reasoning_summary_delta",
            payload: .object([
                "delta": .string("检查"),
                "summary_index": .integer(2),
            ])
        )
    )
    guard case let .reasoningSummaryTextDelta(summaryPayload) =
        summaryDelta.first
    else {
        Issue.record("expected item/reasoning/summaryTextDelta")
        return
    }
    #expect(summaryPayload.threadID == threadID)
    #expect(summaryPayload.turnID == turnID)
    #expect(summaryPayload.itemID == "reasoning-stream-1")
    #expect(summaryPayload.summaryIndex == 2)
    #expect(summaryPayload.delta == "检查")

    let partAdded = projector.providerEvent(
        .realtime(
            sequence: 3,
            requestID: turnID,
            eventType: "reasoning_summary_part_added",
            payload: .object(["summary_index": .integer(3)])
        )
    )
    guard case let .reasoningSummaryPartAdded(partPayload) =
        partAdded.first
    else {
        Issue.record("expected item/reasoning/summaryPartAdded")
        return
    }
    #expect(partPayload.itemID == "reasoning-stream-1")
    #expect(partPayload.summaryIndex == 3)

    let textDelta = projector.providerEvent(
        .realtime(
            sequence: 4,
            requestID: turnID,
            eventType: "reasoning_content_delta",
            payload: .object([
                "delta": .string("细节"),
                "content_index": .integer(1),
            ])
        )
    )
    guard case let .reasoningTextDelta(textPayload) = textDelta.first else {
        Issue.record("expected item/reasoning/textDelta")
        return
    }
    #expect(textPayload.itemID == "reasoning-stream-1")
    #expect(textPayload.contentIndex == 1)
    #expect(textPayload.delta == "细节")
}

@Test
func desktopTurnNotificationProjectorKeepsUnsafeReasoningRealtimeOpaque() {
    let cases: [(String, CodexJSONValue)] = [
        (
            "reasoning_summary_delta",
            .object([
                "delta": .string("missing item"),
                "summary_index": .integer(0),
            ])
        ),
        (
            "reasoning_summary_delta",
            .object([
                "delta": .string("negative"),
                "summary_index": .integer(-1),
            ])
        ),
        (
            "reasoning_content_delta",
            .object([
                "delta": .string("wrong type"),
                "content_index": .string("0"),
            ])
        ),
    ]

    for (offset, event) in cases.enumerated() {
        var projector = CodexDesktopTurnNotificationProjector(
            threadID: .init("thread/unsafe-\(offset)"),
            turnID: "turn/unsafe-\(offset)",
            startedAtMs: 100
        )
        if offset > 0 {
            _ = projector.providerEvent(
                .realtime(
                    sequence: 1,
                    requestID: "turn/unsafe-\(offset)",
                    eventType: "output_item_added",
                    payload: .object([
                        "type": .string("reasoning"),
                        "id": .string("reasoning-unsafe-\(offset)"),
                    ])
                )
            )
        }
        let notifications = projector.providerEvent(
            .realtime(
                sequence: UInt64(offset + 2),
                requestID: "turn/unsafe-\(offset)",
                eventType: event.0,
                payload: event.1
            )
        )
        #expect(notifications.count == 1)
        guard case .opaque = notifications[0] else {
            Issue.record("expected unsafe reasoning event to stay opaque")
            continue
        }
    }

    var emptyIDProjector = CodexDesktopTurnNotificationProjector(
        threadID: .init("thread/empty-id"),
        turnID: "turn/empty-id",
        startedAtMs: 100
    )
    _ = emptyIDProjector.providerEvent(
        .realtime(
            sequence: 1,
            requestID: "turn/empty-id",
            eventType: "output_item_added",
            payload: .object([
                "type": .string("reasoning"),
                "id": .string(""),
            ])
        )
    )
    let emptyIDDelta = emptyIDProjector.providerEvent(
        .realtime(
            sequence: 2,
            requestID: "turn/empty-id",
            eventType: "reasoning_summary_delta",
            payload: .object([
                "delta": .string("unsafe"),
                "summary_index": .integer(0),
            ])
        )
    )
    guard case .opaque = emptyIDDelta.first else {
        Issue.record("expected empty reasoning item id to stay opaque")
        return
    }
}

@Test
func desktopTurnNotificationProjectorKeepsRoundOpenWhenResponseDoesNotEndTurn() {
    let threadID = CodexStoredThreadID("thread/continuing")
    let turnID = "turn/continuing"
    var projector = CodexDesktopTurnNotificationProjector(
        threadID: threadID,
        turnID: turnID,
        startedAtMs: 1_722_330_000_000
    )
    let usage = CodexTokenUsageBreakdown(
        totalTokens: 21,
        inputTokens: 8,
        cachedInputTokens: 3,
        outputTokens: 10,
        reasoningOutputTokens: 4
    )

    let notifications = projector.providerEvent(
        .responseCompleted(
            sequence: 2,
            requestID: turnID,
            responseID: "response/continuing",
            usage: usage,
            endTurn: false
        )
    )

    #expect(notifications.count == 2)
    guard case let .threadTokenUsageUpdated(tokenPayload) = notifications[0]
    else {
        Issue.record("expected round usage without item completion")
        return
    }
    #expect(tokenPayload.threadID == threadID)
    #expect(tokenPayload.turnID == turnID)
    #expect(tokenPayload.tokenUsage.last == usage)

    guard case let .rawResponseCompleted(responsePayload) = notifications[1]
    else {
        Issue.record("expected raw response without turn completion")
        return
    }
    #expect(responsePayload.responseID == "response/continuing")
    #expect(responsePayload.usage == usage)
}

@Test
func desktopTurnNotificationProjectorEmitsProposedPlanDeltaWithoutAgentDelta() {
    let threadID = CodexStoredThreadID("thread/plan-stream")
    let turnID = "turn/plan-stream"
    let planItemID = "\(turnID)-plan"
    var projector = CodexDesktopTurnNotificationProjector(
        threadID: threadID,
        turnID: turnID,
        startedAtMs: 1_722_330_000_000
    )

    let notifications = projector.providerEvent(
        .planDelta(
            sequence: 1,
            requestID: turnID,
            itemID: planItemID,
            delta: "- inspect\n"
        )
    )

    #expect(notifications.count == 2)
    guard case let .itemStarted(startedPayload) = notifications[0],
          case let .plan(startedID, startedText) = startedPayload.item
    else {
        Issue.record("expected synthesized plan item/started")
        return
    }
    #expect(startedID == planItemID)
    #expect(startedText.isEmpty)

    guard case let .planDelta(payload) = notifications[1] else {
        Issue.record("expected item/plan/delta after item/started")
        return
    }
    #expect(payload.threadID == threadID)
    #expect(payload.turnID == turnID)
    #expect(payload.itemID == planItemID)
    #expect(payload.delta == "- inspect\n")
    #expect(projector.currentText.isEmpty)
}

@Test
func desktopTurnNotificationProjectorPreservesProposedPlanLifecycleAndCanonicalCompletion() {
    let threadID = CodexStoredThreadID("thread/plan-lifecycle")
    let turnID = "turn/plan-lifecycle"
    let planItemID = "\(turnID)-plan"
    var projector = CodexDesktopTurnNotificationProjector(
        threadID: threadID,
        turnID: turnID,
        startedAtMs: 1_722_330_000_000
    )

    let initial = CodexStoredTurn(
        id: turnID,
        items: [],
        itemsView: .notLoaded,
        status: .inProgress,
        startedAt: 1_722_330_000_000
    )
    #expect(projector.started(turn: initial).count == 1)

    let started = projector.providerEvent(
        .planStarted(
            sequence: 1,
            requestID: turnID,
            itemID: planItemID
        )
    )
    guard started.count == 1,
          case let .itemStarted(startedPayload) = started[0],
          case let .plan(startedID, startedText) = startedPayload.item
    else {
        Issue.record("expected proposed plan item/started")
        return
    }
    #expect(startedID == planItemID)
    #expect(startedText.isEmpty)

    let delta = projector.providerEvent(
        .planDelta(
            sequence: 2,
            requestID: turnID,
            itemID: planItemID,
            delta: "- inspect\n"
        )
    )
    guard delta.count == 1,
          case let .planDelta(deltaPayload) = delta[0]
    else {
        Issue.record("expected item/plan/delta")
        return
    }
    #expect(deltaPayload.delta == "- inspect\n")

    let authoritativeText = "- inspect\n- implement\n"
    let completed = projector.providerEvent(
        .planCompleted(
            sequence: 3,
            requestID: turnID,
            itemID: planItemID,
            text: authoritativeText
        )
    )
    guard completed.count == 1,
          case let .itemCompleted(completedPayload) = completed[0],
          case let .plan(completedID, completedText) = completedPayload.item
    else {
        Issue.record("expected proposed plan item/completed")
        return
    }
    #expect(completedID == planItemID)
    #expect(completedText == authoritativeText)
    #expect(projector.currentText.isEmpty)

    let duplicateCompleted = projector.providerEvent(
        .planCompleted(
            sequence: 4,
            requestID: turnID,
            itemID: planItemID,
            text: authoritativeText
        )
    )
    #expect(duplicateCompleted.isEmpty)

    let response = projector.providerEvent(
        .responseCompleted(
            sequence: 5,
            requestID: turnID,
            responseID: "response/plan",
            usage: nil,
            endTurn: true
        )
    )
    guard case let .turnCompleted(turnPayload) = response.last,
          turnPayload.turn.items.count == 1,
          case let .plan(finalID, finalText) = turnPayload.turn.items[0]
    else {
        Issue.record("expected canonical plan-only turn completion")
        return
    }
    #expect(finalID == planItemID)
    #expect(finalText == authoritativeText)
}

@Test
func desktopTurnNotificationProjectorEmitsInterruptedCompletion() {
    var projector = CodexDesktopTurnNotificationProjector(
        threadID: CodexStoredThreadID(rawValue: "Thread-A"),
        turnID: "turn-1",
        startedAtMs: 100
    )

    guard case let .turnCompleted(payload) = projector.interrupted()
    else {
        Issue.record("expected interrupted turn completion")
        return
    }
    #expect(payload.threadID.rawValue == "Thread-A")
    #expect(payload.turn.id == "turn-1")
    #expect(payload.turn.status == CodexStoredTurnStatus.interrupted)
    #expect(payload.turn.error == nil)
}

@Test
func desktopTurnNotificationProjectorMarksTransientFailureForRetry() {
    var projector = CodexDesktopTurnNotificationProjector(
        threadID: CodexStoredThreadID(rawValue: "Thread-A"),
        turnID: "turn-retry",
        startedAtMs: 100
    )

    let notifications = projector.failed(
        NSError(domain: "network", code: -1),
        willRetry: true
    )
    #expect(notifications.count == 1)
    guard case let .error(payload) = notifications[0] else {
        Issue.record("expected retry error")
        return
    }
    #expect(payload.willRetry)
    #expect(payload.turnID == "turn-retry")
}

@Test
func desktopTurnNotificationProjectorEmitsMCPItemLifecycle() {
    var projector = CodexDesktopTurnNotificationProjector(
        threadID: .init("thread-mcp"),
        turnID: "turn-mcp",
        startedAtMs: 100
    )
    let request = CodexPersistedTurnToolRequest(
        threadID: .init("thread-mcp"),
        turnID: "turn-mcp",
        roundIndex: 1,
        name: "echo",
        arguments: #"{"message":"hello"}"#,
        callID: "call-mcp",
        itemJSON:
            #"{"type":"function_call","namespace":"mcp__sample","name":"echo","call_id":"call-mcp"}"#
    )

    let started = projector.providerEvent(
        .toolCallRequested(
            sequence: 1,
            requestID: "turn-mcp",
            name: request.name,
            arguments: request.arguments,
            callID: request.callID,
            itemJSON: request.itemJSON
        )
    )
    #expect(started.count == 2)
    guard case let .itemStarted(payload) = started[0],
          case let .mcpToolCall(
              id, server, tool, status, arguments,
              _, _, _, _, _, _
          ) = payload.item
    else {
        Issue.record("expected MCP item/started")
        return
    }
    #expect(id == "call-mcp")
    #expect(server == "sample")
    #expect(tool == "echo")
    #expect(status == .inProgress)
    #expect(arguments == .object(["message": .string("hello")]))

    let completed = projector.toolOutput(
        request: request,
        output: .init(
            itemJSON:
                #"{"type":"function_call_output","call_id":"call-mcp","output":"{\"content\":[{\"type\":\"text\",\"text\":\"echoed\"}],\"isError\":false}"}"#
        )
    )
    #expect(completed.count == 2)
    guard case let .itemCompleted(payload) = completed[0],
          case let .mcpToolCall(
              _, _, _, status, _, _, _, _, result, error, _
          ) = payload.item
    else {
        Issue.record("expected MCP item/completed")
        return
    }
    #expect(status == .completed)
    #expect(result != nil)
    #expect(error == nil)
}

@Test
func desktopTurnNotificationProjectorEmitsCommandLifecycle() {
    var projector = CodexDesktopTurnNotificationProjector(
        threadID: .init("thread-command"),
        turnID: "turn-command",
        startedAtMs: 100
    )
    let request = CodexPersistedTurnToolRequest(
        threadID: .init("thread-command"),
        turnID: "turn-command",
        roundIndex: 1,
        name: "exec_command",
        arguments: #"{"cmd":"pwd","workdir":"/workspace"}"#,
        callID: "call-command",
        itemJSON:
            #"{"type":"function_call","name":"exec_command","call_id":"call-command"}"#
    )

    let started = projector.providerEvent(
        .toolCallRequested(
            sequence: 1,
            requestID: "turn-command",
            name: request.name,
            arguments: request.arguments,
            callID: request.callID,
            itemJSON: request.itemJSON
        )
    )
    guard case let .itemStarted(payload) = started[0],
          case let .commandExecution(
              _, command, cwd, _, _, status, _, _, _, _
          ) = payload.item
    else {
        Issue.record("expected command item/started")
        return
    }
    #expect(command == "pwd")
    #expect(cwd == "/workspace")
    #expect(status == .inProgress)

    let completed = projector.toolOutput(
        request: request,
        output: .init(
            itemJSON:
                #"{"type":"function_call_output","call_id":"call-command","output":"done"}"#
        )
    )
    guard case let .itemCompleted(payload) = completed[0],
          case let .commandExecution(
              _, _, _, _, _, status, _, output, exitCode, _
          ) = payload.item
    else {
        Issue.record("expected command item/completed")
        return
    }
    #expect(status == .completed)
    #expect(output == "done")
    #expect(exitCode == 0)
}

@Test
func desktopTurnNotificationProjectorEmitsFileChangeAndDiff() {
    var projector = CodexDesktopTurnNotificationProjector(
        threadID: .init("thread-patch"),
        turnID: "turn-patch",
        startedAtMs: 100
    )
    let request = CodexPersistedTurnToolRequest(
        threadID: .init("thread-patch"),
        turnID: "turn-patch",
        roundIndex: 1,
        name: "apply_patch",
        arguments: #"{"patch":"*** Begin Patch"}"#,
        callID: "call-patch",
        itemJSON:
            #"{"type":"function_call","name":"apply_patch","call_id":"call-patch"}"#
    )
    let started = projector.providerEvent(
        .toolCallRequested(
            sequence: 1,
            requestID: "turn-patch",
            name: request.name,
            arguments: request.arguments,
            callID: request.callID,
            itemJSON: request.itemJSON
        )
    )
    guard case let .itemStarted(payload) = started[0],
          case let .fileChange(_, _, status) = payload.item
    else {
        Issue.record("expected fileChange item/started")
        return
    }
    #expect(status == .inProgress)

    let completed = projector.toolOutput(
        request: request,
        output: .init(
            itemJSON:
                #"{"type":"function_call_output","call_id":"call-patch","output":"Success"}"#,
            workspaceDiff: "diff --git a/a b/a"
        )
    )
    #expect(completed.count == 3)
    guard case let .itemCompleted(payload) = completed[0],
          case let .fileChange(_, _, status) = payload.item,
          case let .turnDiffUpdated(diff) = completed[2]
    else {
        Issue.record("expected completed fileChange and turn diff")
        return
    }
    #expect(status == .completed)
    #expect(diff.diff == "diff --git a/a b/a")
}

@Test
func desktopTurnNotificationProjectorEmitsCanonicalPatchUpdateBeforeCompletion() {
    var projector = CodexDesktopTurnNotificationProjector(
        threadID: .init("thread-patch-update"),
        turnID: "turn-patch-update",
        startedAtMs: 100
    )
    let request = CodexPersistedTurnToolRequest(
        threadID: .init("thread-patch-update"),
        turnID: "turn-patch-update",
        roundIndex: 1,
        name: "apply_patch",
        arguments: #"{"patch":"*** Begin Patch"}"#,
        callID: "call-patch-update",
        itemJSON:
            #"{"type":"function_call","name":"apply_patch","call_id":"call-patch-update"}"#
    )
    _ = projector.providerEvent(
        .toolCallRequested(
            sequence: 1,
            requestID: request.turnID,
            name: request.name,
            arguments: request.arguments,
            callID: request.callID,
            itemJSON: request.itemJSON
        )
    )

    let notifications = projector.toolOutput(
        request: request,
        output: .init(
            itemJSON:
                #"{"type":"function_call_output","call_id":"call-patch-update","output":"Success"}"#,
            workspaceDiff: "diff --git a/a.txt b/a.txt",
            fileChanges: [
                CodexFileUpdateChange(
                    path: "a.txt",
                    kind: .update(movePath: nil),
                    diff: "@@ -1 +1 @@\n-old\n+new\n"
                )
            ]
        )
    )

    #expect(notifications.count == 4)
    guard case let .fileChangePatchUpdated(patch) = notifications[0],
          case let .itemCompleted(completed) = notifications[1],
          case let .fileChange(_, changes, status) = completed.item
    else {
        Issue.record("expected patch update before completed fileChange")
        return
    }
    #expect(patch.threadID == request.threadID)
    #expect(patch.turnID == request.turnID)
    #expect(patch.itemID == request.callID)
    #expect(patch.changes[0].path == "a.txt")
    #expect(patch.changes[0].kind == .update(movePath: nil))
    #expect(status == .completed)
    #expect(changes == [
        .object([
            "path": .string("a.txt"),
            "kind": .object([
                "type": .string("update"),
                "move_path": .null,
            ]),
            "diff": .string("@@ -1 +1 @@\n-old\n+new\n"),
        ])
    ])
}

@Test
func desktopTurnNotificationProjectorProjectsReasoningResponseItem() {
    var projector = CodexDesktopTurnNotificationProjector(
        threadID: .init("thread-reasoning"),
        turnID: "turn-reasoning",
        startedAtMs: 100
    )
    let notifications = projector.providerEvent(
        .responseItemDone(
            sequence: 1,
            requestID: "turn-reasoning",
            itemJSON:
                #"{"type":"reasoning","id":"reasoning-1","summary":[{"type":"summary_text","text":"分析"}],"content":[{"type":"reasoning_text","text":"细节"}]}"#
        )
    )
    #expect(notifications.count == 2)
    guard case let .itemCompleted(payload) = notifications[0],
          case let .reasoning(id, summary, content) = payload.item
    else {
        Issue.record("expected reasoning item/completed")
        return
    }
    #expect(id == "reasoning-1")
    #expect(summary == ["分析"])
    #expect(content == ["细节"])
}

@Test
func desktopTurnNotificationProjectorEmitsPlanLifecycle() {
    var projector = CodexDesktopTurnNotificationProjector(
        threadID: .init("thread-plan"),
        turnID: "turn-plan",
        startedAtMs: 100
    )
    let request = CodexPersistedTurnToolRequest(
        threadID: .init("thread-plan"),
        turnID: "turn-plan",
        roundIndex: 1,
        name: "update_plan",
        arguments:
            #"{"plan":[{"step":"实现","status":"in_progress"}]}"#,
        callID: "call-plan",
        itemJSON:
            #"{"type":"function_call","name":"update_plan","call_id":"call-plan"}"#
    )
    let started = projector.providerEvent(
        .toolCallRequested(
            sequence: 1,
            requestID: "turn-plan",
            name: request.name,
            arguments: request.arguments,
            callID: request.callID,
            itemJSON: request.itemJSON
        )
    )
    guard case let .itemStarted(payload) = started[0],
          case let .plan(id, text) = payload.item
    else {
        Issue.record("expected plan item/started")
        return
    }
    #expect(id == "call-plan")
    #expect(text.contains("in_progress"))

    let completed = projector.toolOutput(
        request: request,
        output: .init(
            itemJSON:
                #"{"type":"function_call_output","call_id":"call-plan","output":"updated"}"#
        )
    )
    guard case let .itemCompleted(payload) = completed[0],
          case .plan = payload.item
    else {
        Issue.record("expected plan item/completed")
        return
    }
}
