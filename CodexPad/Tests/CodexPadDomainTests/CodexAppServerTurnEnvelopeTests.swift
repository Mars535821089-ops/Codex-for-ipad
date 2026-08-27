import CodexPadDomain
import Foundation
import Testing

@Test
func appServerReasoningNotificationsRoundTripOfficialMethods() throws {
    let notifications: [(CodexAppServerTurnNotification, String)] = [
        (
            .reasoningSummaryTextDelta(
                .init(
                    threadID: .init("thread-reasoning"),
                    turnID: "turn-reasoning",
                    itemID: "reasoning-1",
                    summaryIndex: 2,
                    delta: "summary"
                )
            ),
            "item/reasoning/summaryTextDelta"
        ),
        (
            .reasoningSummaryPartAdded(
                .init(
                    threadID: .init("thread-reasoning"),
                    turnID: "turn-reasoning",
                    itemID: "reasoning-1",
                    summaryIndex: 3
                )
            ),
            "item/reasoning/summaryPartAdded"
        ),
        (
            .reasoningTextDelta(
                .init(
                    threadID: .init("thread-reasoning"),
                    turnID: "turn-reasoning",
                    itemID: "reasoning-1",
                    contentIndex: 1,
                    delta: "detail"
                )
            ),
            "item/reasoning/textDelta"
        ),
    ]

    for (notification, expectedMethod) in notifications {
        let wire = try CodexAppServerTurnNotificationEncoder.wire(notification)
        #expect(wire.method == expectedMethod)
        let encoded = try JSONEncoder().encode(
            CodexJSONValue.object([
                "method": .string(wire.method),
                "params": wire.params,
            ])
        )
        let decoded = try JSONDecoder().decode(
            CodexAppServerTurnNotificationEnvelope.self,
            from: encoded
        )
        #expect(decoded.notification == notification)
    }
}

@testable import CodexPadProtocolBridge

private func decodeTurnNotification(
    _ json: String
) throws -> CodexAppServerTurnNotificationEnvelope {
    try JSONDecoder().decode(
        CodexAppServerTurnNotificationEnvelope.self,
        from: Data(json.utf8)
    )
}

@Test
func turnStartDecoderPreservesReleasedOmittedNullAndValueFields() throws {
    let decoded = try CodexAppServerTurnStartParamsDecoder.decode(
        .object([
            "threadId": .string("Thread/Raw"),
            "input": .array([
                .object([
                    "type": .string("text"),
                    "text": .string("Continue"),
                    "text_elements": .array([]),
                ])
            ]),
            "clientUserMessageId": .null,
            "cwd": .string("/Workspace"),
            "approvalPolicy": .string("never"),
            "model": .string("model-stable"),
            "collaborationMode": .object([
                "mode": .string("plan"),
                "settings": .object([
                    "model": .string("model-plan"),
                    "reasoning_effort": .string("medium"),
                    "developer_instructions": .null,
                ]),
            ]),
            "multiAgentMode": .string("proactive"),
            "outputSchema": .object(["type": .string("object")]),
        ])
    )

    #expect(decoded.threadID.rawValue == "Thread/Raw")
    #expect(
        decoded.input
            == [.text(text: "Continue", textElements: [])]
    )
    #expect(decoded.clientUserMessageID == .null)
    #expect(decoded.cwd == .value("/Workspace"))
    #expect(decoded.approvalPolicy == .value(.never))
    #expect(decoded.approvalsReviewer == .omitted)
    #expect(decoded.model == .value("model-stable"))
    #expect(
        decoded.collaborationMode
            == .value(
                CodexCollaborationMode(
                    mode: .plan,
                    settings: CodexCollaborationModeSettings(
                        model: "model-plan",
                        reasoningEffort: "medium",
                        developerInstructions: nil
                    )
                )
            )
    )
    #expect(decoded.multiAgentMode == .value(.proactive))
    #expect(
        decoded.outputSchema
            == .value(.object(["type": .string("object")]))
    )
}

@Test
func turnStartDecoderRejectsMalformedReleasedParams() {
    #expect(throws: CodexAppServerTurnEnvelopeError.invalidTurnStartParams) {
        try CodexAppServerTurnStartParamsDecoder.decode(
            .object(["input": .array([])])
        )
    }
    #expect(
        throws:
            CodexAppServerTurnEnvelopeError
                .invalidTurnStartParam("input")
    ) {
        try CodexAppServerTurnStartParamsDecoder.decode(
            .object([
                "threadId": .string("Thread/Raw"),
                "input": .string("not-an-array"),
            ])
        )
    }
}

@Test
func turnStartEncodesRawThreadIDAndEveryStableInputVariant() throws {
    let request = CodexAppServerTurnRequest.start(
        id: .string("turn-start-1"),
        params: CodexTurnStartParams(
            threadID: CodexStoredThreadID("  Thread/Ω/CaseSensitive  "),
            input: [
                .text(
                    text: "Look [here]",
                    textElements: [
                        .object([
                            "byteRange": .object([
                                "start": .number(5),
                                "end": .number(11),
                            ]),
                            "placeholder": .string("[here]"),
                        ])
                    ]
                ),
                .image(detail: .original, url: "data:image/png;base64,AA=="),
                .localImage(detail: .high, path: "/tmp/Local Image.PNG"),
                .audio(url: "data:audio/wav;base64,AQ=="),
                .localAudio(path: "/tmp/Local Audio.wav"),
                .skill(name: "review", path: "/skills/review/SKILL.md"),
                .mention(name: "APP", path: "app://connector-ID"),
            ],
            clientUserMessageID: .value("client-message-1"),
            cwd: .value("/Workspace/Mixed Case"),
            approvalPolicy: .value(.onRequest),
            approvalsReviewer: .value(.autoReview),
            sandboxPolicy: .value(
                .workspaceWrite(
                    writableRoots: ["/Workspace/Mixed Case"],
                    networkAccess: true,
                    excludeTmpdirEnvVar: false,
                    excludeSlashTmp: true
                )
            ),
            model: .value("model-stable"),
            serviceTier: .value("priority"),
            effort: .value("high"),
            summary: .value(.concise),
            collaborationMode: .value(
                CodexCollaborationMode(
                    mode: .plan,
                    settings: CodexCollaborationModeSettings(
                        model: "model-plan",
                        reasoningEffort: "medium",
                        developerInstructions: nil
                    )
                )
            ),
            multiAgentMode: .value(.explicitRequestOnly),
            personality: .value(.pragmatic),
            outputSchema: .value(
                .object(["type": .string("object")])
            )
        )
    )

    #expect(
        try request.encodedData()
            == Data(
                #"{"id":"turn-start-1","method":"turn/start","params":{"approvalPolicy":"on-request","approvalsReviewer":"auto_review","clientUserMessageId":"client-message-1","collaborationMode":{"mode":"plan","settings":{"developer_instructions":null,"model":"model-plan","reasoning_effort":"medium"}},"cwd":"/Workspace/Mixed Case","effort":"high","input":[{"text":"Look [here]","text_elements":[{"byteRange":{"end":11,"start":5},"placeholder":"[here]"}],"type":"text"},{"detail":"original","type":"image","url":"data:image/png;base64,AA=="},{"detail":"high","path":"/tmp/Local Image.PNG","type":"localImage"},{"type":"audio","url":"data:audio/wav;base64,AQ=="},{"path":"/tmp/Local Audio.wav","type":"localAudio"},{"name":"review","path":"/skills/review/SKILL.md","type":"skill"},{"name":"APP","path":"app://connector-ID","type":"mention"}],"model":"model-stable","multiAgentMode":"explicitRequestOnly","outputSchema":{"type":"object"},"personality":"pragmatic","sandboxPolicy":{"excludeSlashTmp":true,"excludeTmpdirEnvVar":false,"networkAccess":true,"type":"workspaceWrite","writableRoots":["/Workspace/Mixed Case"]},"serviceTier":"priority","summary":"concise","threadId":"  Thread/Ω/CaseSensitive  "}}"#
                    .utf8
            )
    )
}

@Test
func turnStartProjectsDesktopExtensionsBeforePortableCoreTransport() throws {
    let request = CodexAppServerTurnRequest.start(
        id: .string("turn-experimental"),
        params: CodexTurnStartParams(
            threadID: CodexStoredThreadID("Thread-Raw"),
            input: [],
            additionalContext: .value([
                "desktop": .object([
                    "kind": .string("application"),
                    "value": .string("context"),
                ])
            ]),
            environments: .value([
                .object([
                    "environmentId": .string("local"),
                    "cwd": .string("/workspace"),
                ])
            ]),
            permissions: .value(":workspace"),
            responsesAPIClientMetadata: .value(["surface": "ipad"]),
            runtimeWorkspaceRoots: .value(["/workspace"]),
            dynamicTools: .value([
                .object([
                    "type": .string("function"),
                    "name": .string("lookup_ticket"),
                    "description": .string("Look up a ticket."),
                    "inputSchema": .object(["type": .string("object")]),
                ])
            ]),
            selectedCapabilityRoots: .value([
                .object(["id": .string("github@openai")])
            ])
        )
    )

    // The embedded core follows the same released turn/start contract. These
    // fields must reach Rust rather than being silently discarded at the
    // renderer boundary.
    #expect(
        try request.encodedData()
            == Data(
                #"{"id":"turn-experimental","method":"turn/start","params":{"additionalContext":{"desktop":{"kind":"application","value":"context"}},"dynamicTools":[{"description":"Look up a ticket.","inputSchema":{"type":"object"},"name":"lookup_ticket","type":"function"}],"environments":[{"cwd":"/workspace","environmentId":"local"}],"input":[],"permissions":":workspace","responsesapiClientMetadata":{"surface":"ipad"},"runtimeWorkspaceRoots":["/workspace"],"selectedCapabilityRoots":[{"id":"github@openai"}],"threadId":"Thread-Raw"}}"#.utf8
            )
    )
}

@Test
func turnStartPreservesOmittedNullAndIntegerRequestID() throws {
    let omitted = CodexAppServerTurnRequest.start(
        id: .integer(41),
        params: CodexTurnStartParams(
            threadID: CodexStoredThreadID("Thread-Raw"),
            input: []
        )
    )
    let null = CodexAppServerTurnRequest.start(
        id: .integer(42),
        params: CodexTurnStartParams(
            threadID: CodexStoredThreadID("Thread-Raw"),
            input: [],
            clientUserMessageID: .null,
            cwd: .null,
            approvalPolicy: .null,
            approvalsReviewer: .null,
            sandboxPolicy: .null,
            model: .null,
            serviceTier: .null,
            effort: .null,
            summary: .null,
            collaborationMode: .null,
            multiAgentMode: .null,
            personality: .null,
            outputSchema: .null
        )
    )

    #expect(
        try omitted.encodedData()
            == Data(
                #"{"id":41,"method":"turn/start","params":{"input":[],"threadId":"Thread-Raw"}}"#
                    .utf8
            )
    )
    #expect(
        try null.encodedData()
            == Data(
                #"{"id":42,"method":"turn/start","params":{"approvalPolicy":null,"approvalsReviewer":null,"clientUserMessageId":null,"collaborationMode":null,"cwd":null,"effort":null,"input":[],"model":null,"multiAgentMode":null,"outputSchema":null,"personality":null,"sandboxPolicy":null,"serviceTier":null,"summary":null,"threadId":"Thread-Raw"}}"#
                    .utf8
            )
    )
}

@Test
func turnStartResponseDecodesCurrentTurnAndLegacyItemsView() throws {
    let current = try JSONDecoder().decode(
        CodexAppServerResponse<CodexTurnStartResult>.self,
        from: Data(
            #"""
            {
              "id":"turn-start-1",
              "result":{
                "turn":{
                  "id":"Turn-Raw",
                  "items":[{
                    "type":"agentMessage",
                    "id":"item-1",
                    "text":"Done",
                    "phase":"final_answer",
                    "memoryCitation":null
                  }],
                  "itemsView":"summary",
                  "status":"failed",
                  "error":{
                    "message":"Provider stopped",
                    "codexErrorInfo":"serverOverloaded",
                    "additionalDetails":"retry later"
                  },
                  "startedAt":100,
                  "completedAt":102,
                  "durationMs":2000
                }
              }
            }
            """#.utf8
        )
    )
    let legacy = try JSONDecoder().decode(
        CodexAppServerResponse<CodexTurnStartResult>.self,
        from: Data(
            #"{"id":9,"result":{"turn":{"id":"legacy","items":[],"status":"completed","error":null,"startedAt":null,"completedAt":null,"durationMs":null}}}"#
                .utf8
        )
    )

    #expect(current.id == .string("turn-start-1"))
    #expect(current.result.turn.id == "Turn-Raw")
    #expect(current.result.turn.itemsView == .summary)
    #expect(current.result.turn.status == .failed)
    #expect(current.result.turn.error?.message == "Provider stopped")
    #expect(current.result.turn.error?.codexErrorInfo == .serverOverloaded)
    #expect(current.result.turn.error?.additionalDetails == "retry later")
    #expect(current.result.turn.startedAt == 100)
    #expect(current.result.turn.completedAt == 102)
    #expect(current.result.turn.durationMs == 2_000)
    #expect(legacy.id == .integer(9))
    #expect(legacy.result.turn.itemsView == .full)
}

@Test
func notificationEnvelopeDecodesTurnStartedWithoutJSONRPCMetadata() throws {
    let envelope = try decodeTurnNotification(
        #"""
        {
          "method":"turn/started",
          "params":{
            "threadId":"  Thread/Raw  ",
            "turn":{
              "id":"Turn-1",
              "items":[],
              "status":"inProgress",
              "error":null,
              "startedAt":200,
              "completedAt":null,
              "durationMs":null
            }
          }
        }
        """#
    )

    #expect(envelope.emittedAtMs == nil)
    guard case .turnStarted(let payload) = envelope.notification else {
        Issue.record("Expected turn/started")
        return
    }
    #expect(payload.threadID.rawValue == "  Thread/Raw  ")
    #expect(payload.turn.id == "Turn-1")
    #expect(payload.turn.itemsView == .full)
    #expect(payload.turn.status == .inProgress)
}

@Test
func notificationEnvelopeDecodesAndEncodesItemPlanDeltaWithCanonicalWireShape()
    throws
{
    let envelope = try decodeTurnNotification(
        #"{"method":"item/plan/delta","params":{"threadId":"thread/plan","turnId":"turn/plan","itemId":"turn/plan-plan","delta":"- inspect\n"}}"#
    )
    guard case let .planDelta(payload) = envelope.notification else {
        Issue.record("expected item/plan/delta")
        return
    }
    #expect(payload.threadID == CodexStoredThreadID("thread/plan"))
    #expect(payload.turnID == "turn/plan")
    #expect(payload.itemID == "turn/plan-plan")
    #expect(payload.delta == "- inspect\n")

    let wire = try CodexAppServerTurnNotificationEncoder.wire(
        .planDelta(
            CodexPlanDeltaNotification(
                threadID: .init("thread/plan"),
                turnID: "turn/plan",
                itemID: "turn/plan-plan",
                delta: "- inspect\n"
            )
        )
    )
    #expect(
        wire
            == CodexAppServerTurnNotificationWire(
                method: "item/plan/delta",
                params: .object([
                    "threadId": .string("thread/plan"),
                    "turnId": .string("turn/plan"),
                    "itemId": .string("turn/plan-plan"),
                    "delta": .string("- inspect\n"),
                ])
            )
    )
}

@Test
func notificationEnvelopeDecodesItemLifecycleAndAgentDelta() throws {
    let started = try decodeTurnNotification(
        #"""
        {
          "method":"item/started",
          "params":{
            "threadId":"Thread-A",
            "turnId":"Turn-A",
            "item":{
              "type":"agentMessage",
              "id":"Item-A",
              "text":"",
              "phase":null,
              "memoryCitation":null
            },
            "startedAtMs":300
          },
          "emittedAtMs":301
        }
        """#
    )
    let delta = try decodeTurnNotification(
        #"{"method":"item/agentMessage/delta","params":{"threadId":"Thread-A","turnId":"Turn-A","itemId":"Item-A","delta":"next"},"emittedAtMs":302}"#
    )
    let completed = try decodeTurnNotification(
        #"""
        {
          "method":"item/completed",
          "params":{
            "threadId":"Thread-A",
            "turnId":"Turn-A",
            "item":{
              "type":"agentMessage",
              "id":"Item-A",
              "text":"next",
              "phase":"final_answer",
              "memoryCitation":null
            },
            "completedAtMs":303
          },
          "emittedAtMs":304
        }
        """#
    )

    guard case .itemStarted(let startedPayload) = started.notification else {
        Issue.record("Expected item/started")
        return
    }
    #expect(started.emittedAtMs == 301)
    #expect(startedPayload.threadID.rawValue == "Thread-A")
    #expect(startedPayload.turnID == "Turn-A")
    #expect(startedPayload.item.id == "Item-A")
    #expect(startedPayload.startedAtMs == 300)

    guard case .agentMessageDelta(let deltaPayload) = delta.notification else {
        Issue.record("Expected item/agentMessage/delta")
        return
    }
    #expect(deltaPayload.itemID == "Item-A")
    #expect(deltaPayload.delta == "next")

    guard
        case .itemCompleted(let completedPayload) =
            completed.notification
    else {
        Issue.record("Expected item/completed")
        return
    }
    #expect(completedPayload.item.id == "Item-A")
    #expect(completedPayload.completedAtMs == 303)
}

@Test
func notificationEnvelopeDecodesTokenUsageAndTurnCompleted() throws {
    let usage = try decodeTurnNotification(
        #"""
        {
          "method":"thread/tokenUsage/updated",
          "params":{
            "threadId":"Thread-U",
            "turnId":"Turn-U",
            "tokenUsage":{
              "total":{
                "totalTokens":100,
                "inputTokens":60,
                "cachedInputTokens":20,
                "cacheWriteInputTokens":5,
                "outputTokens":40,
                "reasoningOutputTokens":10
              },
              "last":{
                "totalTokens":30,
                "inputTokens":20,
                "cachedInputTokens":4,
                "cacheWriteInputTokens":2,
                "outputTokens":10,
                "reasoningOutputTokens":3
              },
              "modelContextWindow":200000
            }
          },
          "emittedAtMs":400
        }
        """#
    )
    let completed = try decodeTurnNotification(
        #"""
        {
          "method":"turn/completed",
          "params":{
            "threadId":"Thread-U",
            "turn":{
              "id":"Turn-U",
              "items":[],
              "itemsView":"full",
              "status":"completed",
              "error":null,
              "startedAt":390,
              "completedAt":401,
              "durationMs":11000
            }
          },
          "emittedAtMs":402
        }
        """#
    )

    guard case .threadTokenUsageUpdated(let payload) = usage.notification else {
        Issue.record("Expected thread/tokenUsage/updated")
        return
    }
    #expect(payload.tokenUsage.total.totalTokens == 100)
    #expect(payload.tokenUsage.total.cacheWriteInputTokens == 5)
    #expect(payload.tokenUsage.last.cacheWriteInputTokens == 2)
    #expect(payload.tokenUsage.modelContextWindow == 200_000)

    guard case .turnCompleted(let payload) = completed.notification else {
        Issue.record("Expected turn/completed")
        return
    }
    #expect(payload.threadID.rawValue == "Thread-U")
    #expect(payload.turn.id == "Turn-U")
    #expect(payload.turn.status == .completed)
    #expect(payload.turn.durationMs == 11_000)
}

@Test
func notificationEnvelopeDecodesTurnDiffUpdatedSnapshot() throws {
    let envelope = try decodeTurnNotification(
        #"""
        {
          "method":"turn/diff/updated",
          "params":{
            "threadId":" Thread/Diff/原样 ",
            "turnId":"Turn-Diff",
            "diff":"diff --git a/A.swift b/A.swift\n--- a/A.swift\n+++ b/A.swift\n@@ -1 +1 @@\n-old\n+new\n"
          },
          "emittedAtMs":450
        }
        """#
    )

    guard case .turnDiffUpdated(let payload) = envelope.notification else {
        Issue.record("Expected turn/diff/updated")
        return
    }
    #expect(envelope.emittedAtMs == 450)
    #expect(payload.threadID.rawValue == " Thread/Diff/原样 ")
    #expect(payload.turnID == "Turn-Diff")
    #expect(
        payload.diff
            == "diff --git a/A.swift b/A.swift\n--- a/A.swift\n+++ b/A.swift\n@@ -1 +1 @@\n-old\n+new\n"
    )
}

@Test
func notificationEncoderPreservesReleasedMethodAndParamsShape() throws {
    let wire = try CodexAppServerTurnNotificationEncoder.wire(
        .agentMessageDelta(
            CodexAgentMessageDeltaNotification(
                threadID: CodexStoredThreadID("thread/raw"),
                turnID: "turn/raw",
                itemID: "item/raw",
                delta: "增量"
            )
        )
    )

    #expect(
        wire
            == CodexAppServerTurnNotificationWire(
                method: "item/agentMessage/delta",
                params: .object([
                    "threadId": .string("thread/raw"),
                    "turnId": .string("turn/raw"),
                    "itemId": .string("item/raw"),
                    "delta": .string("增量"),
                ])
            )
    )
}

@Test
func turnPlanUpdatedEncoderPreservesExplicitNullExplanation() throws {
    let wire = try CodexAppServerTurnNotificationEncoder.wire(
        .turnPlanUpdated(
            CodexTurnPlanUpdatedNotification(
                threadID: CodexStoredThreadID("thread/plan"),
                turnID: "turn/plan",
                explanation: nil,
                plan: [
                    CodexTurnPlanStep(
                        step: "Verify",
                        status: "in_progress"
                    )
                ]
            )
        )
    )

    #expect(
        wire.params == .object([
            "threadId": .string("thread/plan"),
            "turnId": .string("turn/plan"),
            "explanation": .null,
            "plan": .array([
                .object([
                    "step": .string("Verify"),
                    "status": .string("in_progress"),
                ])
            ]),
        ])
    )
}

@Test
func commandExecutionRealtimeNotificationsPreserveReleasedParams() throws {
    let fixtures: [(
        CodexAppServerTurnNotification,
        CodexAppServerTurnNotificationWire
    )] = [
        (
            .commandExecutionOutputDelta(
                CodexCommandExecutionOutputDeltaNotification(
                    threadID: CodexStoredThreadID("thread/exec"),
                    turnID: "turn/exec",
                    itemID: "item/exec",
                    delta: "stdout\n"
                )
            ),
            CodexAppServerTurnNotificationWire(
                method: "item/commandExecution/outputDelta",
                params: .object([
                    "threadId": .string("thread/exec"),
                    "turnId": .string("turn/exec"),
                    "itemId": .string("item/exec"),
                    "delta": .string("stdout\n"),
                ])
            )
        ),
        (
            .terminalInteraction(
                CodexTerminalInteractionNotification(
                    threadID: CodexStoredThreadID("thread/exec"),
                    turnID: "turn/exec",
                    itemID: "item/exec",
                    processID: "42",
                    stdin: "continue\n"
                )
            ),
            CodexAppServerTurnNotificationWire(
                method:
                    "item/commandExecution/terminalInteraction",
                params: .object([
                    "threadId": .string("thread/exec"),
                    "turnId": .string("turn/exec"),
                    "itemId": .string("item/exec"),
                    "processId": .string("42"),
                    "stdin": .string("continue\n"),
                ])
            )
        ),
    ]

    for (notification, expected) in fixtures {
        #expect(
            try CodexAppServerTurnNotificationEncoder.wire(
                notification
            ) == expected
        )
    }
}

@Test
func notificationEnvelopeDecodesBothRawResponseCompletionEvents() throws {
    let item = try decodeTurnNotification(
        #"""
        {
          "method":"rawResponseItem/completed",
          "params":{
            "threadId":"Thread-R",
            "turnId":"Turn-R",
            "item":{
              "type":"message",
              "role":"assistant",
              "content":[{"type":"output_text","text":"raw"}]
            }
          }
        }
        """#
    )
    let response = try decodeTurnNotification(
        #"""
        {
          "method":"rawResponse/completed",
          "params":{
            "threadId":"Thread-R",
            "turnId":"Turn-R",
            "responseId":"resp_Raw",
            "usage":{
              "totalTokens":12,
              "inputTokens":7,
              "cachedInputTokens":2,
              "cacheWriteInputTokens":1,
              "outputTokens":5,
              "reasoningOutputTokens":3
            }
          },
          "emittedAtMs":500
        }
        """#
    )

    guard case .rawResponseItemCompleted(let payload) = item.notification else {
        Issue.record("Expected rawResponseItem/completed")
        return
    }
    #expect(payload.threadID.rawValue == "Thread-R")
    #expect(payload.item.values["type"] == .string("message"))

    guard case .rawResponseCompleted(let payload) = response.notification else {
        Issue.record("Expected rawResponse/completed")
        return
    }
    #expect(payload.responseID == "resp_Raw")
    #expect(payload.usage?.reasoningOutputTokens == 3)
}

@Test
func unknownNotificationPreservesTheOpaqueRawEnvelope() throws {
    let json =
        #"{"method":"future/event","params":{"nested":[1,{"Case":"Exact"}]},"emittedAtMs":600,"futureTopLevel":true}"#
    let envelope = try decodeTurnNotification(json)
    let expected = try JSONDecoder().decode(
        CodexJSONValue.self,
        from: Data(json.utf8)
    )

    guard case .opaque(let method, let rawEnvelope) = envelope.notification else {
        Issue.record("Expected opaque notification")
        return
    }
    #expect(method == "future/event")
    #expect(rawEnvelope == expected)
    #expect(envelope.rawValue == expected)
}

@Test
func fileChangePatchUpdatedPreservesReleasedWireShape() throws {
    let json =
        #"{"method":"item/fileChange/patchUpdated","params":{"threadId":"Thread-P","turnId":"Turn-P","itemId":"Item-P","changes":[{"path":"A.swift","kind":{"type":"add"},"diff":"new\n"},{"path":"B.swift","kind":{"type":"update","move_path":null},"diff":"@@\n"},{"path":"C.swift","kind":{"type":"update","move_path":"D.swift"},"diff":"@@\n\nMoved to: D.swift"},{"path":"E.swift","kind":{"type":"delete"},"diff":"old\n"}]}}"#
    let envelope = try decodeTurnNotification(json)
    guard case let .fileChangePatchUpdated(payload) =
        envelope.notification
    else {
        Issue.record("Expected item/fileChange/patchUpdated")
        return
    }

    #expect(payload.threadID.rawValue == "Thread-P")
    #expect(payload.turnID == "Turn-P")
    #expect(payload.itemID == "Item-P")
    #expect(payload.changes.map(\.path) == [
        "A.swift", "B.swift", "C.swift", "E.swift",
    ])
    #expect(payload.changes[0].kind == .add)
    #expect(payload.changes[1].kind == .update(movePath: nil))
    #expect(payload.changes[2].kind == .update(movePath: "D.swift"))
    #expect(payload.changes[3].kind == .delete)

    let wire = try CodexAppServerTurnNotificationEncoder.wire(
        envelope.notification
    )
    let expected = try JSONDecoder().decode(
        CodexJSONValue.self,
        from: Data(json.utf8)
    )
    guard case let .object(raw) = expected,
          let params = raw["params"]
    else {
        Issue.record("Expected notification params")
        return
    }
    #expect(wire.method == "item/fileChange/patchUpdated")
    #expect(wire.params == params)
}

@Test
func mcpToolCallProgressPreservesReleasedWireShape() throws {
    let json =
        #"{"method":"item/mcpToolCall/progress","params":{"threadId":"Thread-M","turnId":"Turn-M","itemId":"Item-M","message":"halfway"}}"#
    let envelope = try decodeTurnNotification(json)
    guard case let .mcpToolCallProgress(payload) =
        envelope.notification
    else {
        Issue.record("Expected item/mcpToolCall/progress")
        return
    }
    #expect(payload.threadID == .init("Thread-M"))
    #expect(payload.turnID == "Turn-M")
    #expect(payload.itemID == "Item-M")
    #expect(payload.message == "halfway")

    let wire = try CodexAppServerTurnNotificationEncoder.wire(
        envelope.notification
    )
    #expect(wire.method == "item/mcpToolCall/progress")
    #expect(
        wire.params == .object([
            "threadId": .string("Thread-M"),
            "turnId": .string("Turn-M"),
            "itemId": .string("Item-M"),
            "message": .string("halfway"),
        ])
    )
}

@Test
func approvalReviewAndHookNotificationsAreStronglyTypedAndRoundTrip() throws {
    let fixtures = [
        #"{"method":"hook/started","params":{"threadId":"Thread-H","turnId":"Turn-H","run":{"id":"hook-1","eventName":"preToolUse","status":"running"}}}"#,
        #"{"method":"hook/completed","params":{"threadId":"Thread-H","turnId":null,"run":{"id":"hook-1","eventName":"preToolUse","status":"completed"}}}"#,
        #"{"method":"item/autoApprovalReview/started","params":{"threadId":"Thread-A","turnId":"Turn-A","startedAtMs":100,"reviewId":"review-1","targetItemId":"item-1","review":{"status":"inProgress","riskLevel":null},"action":{"type":"command","command":"pwd","cwd":"/workspace"}}}"#,
        #"{"method":"item/autoApprovalReview/completed","params":{"threadId":"Thread-A","turnId":"Turn-A","startedAtMs":100,"completedAtMs":125,"reviewId":"review-1","targetItemId":null,"decisionSource":"agent","review":{"status":"approved","riskLevel":"low"},"action":{"type":"networkAccess","host":"example.test","port":443}}}"#,
    ]

    for fixture in fixtures {
        let envelope = try decodeTurnNotification(fixture)
        switch envelope.notification {
        case .hookStarted, .hookCompleted,
             .autoApprovalReviewStarted, .autoApprovalReviewCompleted:
            break
        default:
            Issue.record("expected a strongly typed approval/hook notification")
        }
        let wire = try CodexAppServerTurnNotificationEncoder.wire(
            envelope.notification
        )
        guard case let .object(raw) = envelope.rawValue,
              case let .string(method) = raw["method"],
              let params = raw["params"]
        else {
            Issue.record("expected raw notification envelope")
            continue
        }
        #expect(wire.method == method)
        #expect(wire.params == params)
    }
}

@Test
func knownMalformedNotificationsFailInsteadOfBecomingOpaque() {
    let fixtures = [
        #"{"method":"turn/started","params":{"threadId":"Thread-A"}}"#,
        #"{"method":"item/started","params":{"threadId":"Thread-A","turnId":"Turn-A","item":{},"startedAtMs":1}}"#,
        #"{"method":"item/agentMessage/delta","params":{"threadId":"Thread-A","turnId":"Turn-A","itemId":"Item-A","delta":7}}"#,
        #"{"method":"item/completed","params":{"threadId":"Thread-A","turnId":"Turn-A","completedAtMs":1}}"#,
        #"{"method":"thread/tokenUsage/updated","params":{"threadId":"Thread-A","turnId":"Turn-A","tokenUsage":{"total":{},"last":{},"modelContextWindow":null}}}"#,
        #"{"method":"rawResponse/completed","params":{"threadId":"Thread-A","turnId":"Turn-A","responseId":"response-A","usage":{"totalTokens":1,"inputTokens":1,"cachedInputTokens":0,"outputTokens":0,"reasoningOutputTokens":0}}}"#,
        #"{"method":"turn/completed","params":{"threadId":"Thread-A","turn":{"id":"Turn-A","items":[],"status":"unknown"}}}"#,
        #"{"method":"rawResponseItem/completed","params":{"threadId":"Thread-A","turnId":"Turn-A","item":"not-an-object"}}"#,
        #"{"method":"rawResponse/completed","params":{"threadId":"Thread-A","turnId":"Turn-A","responseId":3,"usage":null}}"#,
        #"{"method":"hook/started","params":{"threadId":"Thread-A","run":{}}}"#,
        #"{"method":"hook/completed","params":{"threadId":"Thread-A","turnId":null}}"#,
        #"{"method":"item/autoApprovalReview/started","params":{"threadId":"Thread-A","turnId":"Turn-A","startedAtMs":1,"reviewId":"review-1","review":{},"action":{}}}"#,
        #"{"method":"item/autoApprovalReview/completed","params":{"threadId":"Thread-A","turnId":"Turn-A","startedAtMs":1,"completedAtMs":2,"reviewId":"review-1","decisionSource":"agent","review":{},"action":{}}}"#,
        #"{"method":"item/mcpToolCall/progress","params":{"threadId":"Thread-A","turnId":"Turn-A","itemId":"Item-A"}}"#,
    ]

    for fixture in fixtures {
        #expect(throws: (any Error).self) {
            try decodeTurnNotification(fixture)
        }
    }
}
