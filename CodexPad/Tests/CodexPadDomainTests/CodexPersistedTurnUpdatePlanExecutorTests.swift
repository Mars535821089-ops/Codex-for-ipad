import CodexPadApplication
import CodexPadDomain
import Foundation
import Testing

@MainActor
@Test
func persistedUpdatePlanExecutorPublishesOfficialPlanAndRawOutput()
  async throws
{
  let request = persistedUpdatePlanToolRequest(
    arguments: """
      {
        "explanation": "Start with the contract",
        "plan": [
          {"step": "Inspect contract", "status": "completed"},
          {"step": "Implement executor", "status": "in_progress"},
          {"step": "Verify behavior", "status": "pending"}
        ]
      }
      """
  )
  var updates: [CodexUpdatePlan] = []
  let executor = CodexPersistedTurnUpdatePlanExecutor { update in
    updates.append(update)
  }

  let output = try await executor.execute(
    request,
    cancellation: CodexTurnCancellation()
  )

  #expect(updates == [
    CodexUpdatePlan(
      explanation: "Start with the contract",
      plan: [
        CodexUpdatePlanItem(
          step: "Inspect contract",
          status: .completed
        ),
        CodexUpdatePlanItem(
          step: "Implement executor",
          status: .inProgress
        ),
        CodexUpdatePlanItem(
          step: "Verify behavior",
          status: .pending
        ),
      ]
    )
  ])
  let item = try persistedUpdatePlanObject(output.itemJSON)
  #expect(item["type"] as? String == "function_call_output")
  #expect(item["call_id"] as? String == request.callID)
  #expect(item["output"] as? String == "Plan updated")
  #expect(output.workspaceDiff == nil)
}

@MainActor
@Test
func persistedUpdatePlanExecutorAcceptsMissingExplanationAndEmptyPlan()
  async throws
{
  var received: CodexUpdatePlan?
  let executor = CodexPersistedTurnUpdatePlanExecutor { update in
    received = update
  }

  _ = try await executor.execute(
    persistedUpdatePlanToolRequest(arguments: #"{"plan":[]}"#),
    cancellation: CodexTurnCancellation()
  )

  #expect(received == CodexUpdatePlan(explanation: nil, plan: []))
}

@MainActor
@Test(arguments: [
  #"{}"#,
  #"{"plan":"not-an-array"}"#,
  #"{"plan":[{"step":"One"}]}"#,
  #"{"plan":[{"step":"One","status":"blocked"}]}"#,
  #"{"plan":[{"step":"One","status":"pending","extra":true}]}"#,
  #"{"plan":[],"extra":true}"#,
  #"{"plan":[{"step":"One","status":"in_progress"},{"step":"Two","status":"in_progress"}]}"#,
  #"not-json"#,
])
func persistedUpdatePlanExecutorRejectsInvalidArguments(
  arguments: String
) async {
  var updateCount = 0
  let executor = CodexPersistedTurnUpdatePlanExecutor { _ in
    updateCount += 1
  }

  await #expect(throws: CodexPersistedTurnUpdatePlanError.invalidArguments) {
    _ = try await executor.execute(
      persistedUpdatePlanToolRequest(arguments: arguments),
      cancellation: CodexTurnCancellation()
    )
  }
  #expect(updateCount == 0)
}

@MainActor
@Test
func persistedUpdatePlanExecutorRejectsOtherTools() async {
  let executor = CodexPersistedTurnUpdatePlanExecutor { _ in
    Issue.record("unsupported tools must not publish plan updates")
  }

  await #expect(throws: CodexPersistedTurnUpdatePlanError.unsupportedTool) {
    _ = try await executor.execute(
      persistedUpdatePlanToolRequest(name: "read_workspace_file"),
      cancellation: CodexTurnCancellation()
    )
  }
}

@MainActor
@Test
func persistedUpdatePlanExecutorPropagatesCancellation() async {
  let cancellation = CodexTurnCancellation()
  cancellation.cancel()
  let executor = CodexPersistedTurnUpdatePlanExecutor { _ in
    Issue.record("cancelled plan updates must not be published")
  }

  await #expect(throws: CancellationError.self) {
    _ = try await executor.execute(
      persistedUpdatePlanToolRequest(),
      cancellation: cancellation
    )
  }
}

private func persistedUpdatePlanToolRequest(
  name: String = "update_plan",
  arguments: String = """
    {
      "plan": [
        {"step": "Inspect contract", "status": "in_progress"},
        {"step": "Report results", "status": "pending"}
      ]
    }
    """
) -> CodexPersistedTurnToolRequest {
  CodexPersistedTurnToolRequest(
    threadID: CodexStoredThreadID("thread/update-plan"),
    turnID: "turn/update-plan",
    roundIndex: 3,
    name: name,
    arguments: arguments,
    callID: "call/update-plan",
    itemJSON: #"{"type":"function_call","name":"update_plan"}"#
  )
}

private func persistedUpdatePlanObject(
  _ json: String
) throws -> [String: Any] {
  try #require(
    JSONSerialization.jsonObject(with: Data(json.utf8))
      as? [String: Any]
  )
}
