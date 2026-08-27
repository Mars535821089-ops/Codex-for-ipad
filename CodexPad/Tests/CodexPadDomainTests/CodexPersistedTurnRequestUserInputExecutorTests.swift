import CodexPadApplication
import CodexPadDomain
import Foundation
import Testing

@MainActor
@Test
func persistedRequestUserInputExecutorPromptsAndReturnsOfficialRawOutput()
  async throws
{
  let request = persistedRequestUserInputToolRequest(
    arguments: """
      {
        "questions": [
          {
            "id": "delivery_mode",
            "header": "Delivery",
            "question": "How should this be delivered?",
            "options": [
              {
                "label": "Direct (Recommended)",
                "description": "Ship the focused change now."
              },
              {
                "label": "Review first",
                "description": "Pause for a review before shipping."
              }
            ]
          }
        ],
        "autoResolutionMs": 1000
      }
      """
  )
  var prompts: [CodexRequestUserInputPrompt] = []
  let executor = CodexPersistedTurnRequestUserInputExecutor { prompt in
    prompts.append(prompt)
    return CodexRequestUserInputAnswers(
      answers: [
        "delivery_mode": CodexRequestUserInputAnswer(
          answers: ["Direct (Recommended)"]
        )
      ]
    )
  }

  let output = try await executor.execute(
    request,
    cancellation: CodexTurnCancellation()
  )

  #expect(prompts == [
    CodexRequestUserInputPrompt(
      threadID: request.threadID.rawValue,
      turnID: request.turnID,
      itemID: request.callID,
      questions: [
        CodexRequestUserInputQuestion(
          id: "delivery_mode",
          header: "Delivery",
          question: "How should this be delivered?",
          options: [
            CodexRequestUserInputOption(
              label: "Direct (Recommended)",
              description: "Ship the focused change now."
            ),
            CodexRequestUserInputOption(
              label: "Review first",
              description: "Pause for a review before shipping."
            ),
          ]
        )
      ],
      autoResolutionMS: 60_000
    )
  ])
  let item = try persistedRequestUserInputObject(output.itemJSON)
  #expect(item["type"] as? String == "function_call_output")
  #expect(item["call_id"] as? String == request.callID)
  let rawOutput = try #require(item["output"] as? String)
  let answerObject = try persistedRequestUserInputObject(rawOutput)
  let answers = try #require(answerObject["answers"] as? [String: Any])
  let delivery = try #require(answers["delivery_mode"] as? [String: Any])
  #expect(delivery["answers"] as? [String] == ["Direct (Recommended)"])
  #expect(output.workspaceDiff == nil)
}

@MainActor
@Test(arguments: [
  (1, 60_000),
  (60_000, 60_000),
  (120_000, 120_000),
  (240_000, 240_000),
  (999_999, 240_000),
])
func persistedRequestUserInputExecutorClampsAutoResolution(
  supplied: Int,
  expected: Int
) async throws {
  var received: CodexRequestUserInputPrompt?
  let executor = CodexPersistedTurnRequestUserInputExecutor { prompt in
    received = prompt
    return CodexRequestUserInputAnswers(answers: [:])
  }

  _ = try await executor.execute(
    persistedRequestUserInputToolRequest(
      arguments: """
        {
          "questions": [{
            "id": "confirm",
            "header": "Confirm",
            "question": "Proceed?",
            "options": [
              {"label":"Yes", "description":"Proceed now."},
              {"label":"No", "description":"Stop here."}
            ]
          }],
          "autoResolutionMs": \(supplied)
        }
        """
    ),
    cancellation: CodexTurnCancellation()
  )

  #expect(received?.autoResolutionMS == expected)
}

@MainActor
@Test
func persistedRequestUserInputExecutorPreservesMissingAutoResolution()
  async throws
{
  var received: CodexRequestUserInputPrompt?
  let executor = CodexPersistedTurnRequestUserInputExecutor { prompt in
    received = prompt
    return CodexRequestUserInputAnswers(answers: [:])
  }

  _ = try await executor.execute(
    persistedRequestUserInputToolRequest(),
    cancellation: CodexTurnCancellation()
  )

  #expect(received?.autoResolutionMS == nil)
}

@MainActor
@Test(arguments: [
  #"{"questions":[]}"#,
  #"{"questions":[{"id":"one","header":"One","question":"One?","options":[{"label":"A","description":"A."},{"label":"B","description":"B."}]},{"id":"two","header":"Two","question":"Two?","options":[{"label":"A","description":"A."},{"label":"B","description":"B."}]},{"id":"three","header":"Three","question":"Three?","options":[{"label":"A","description":"A."},{"label":"B","description":"B."}]},{"id":"four","header":"Four","question":"Four?","options":[{"label":"A","description":"A."},{"label":"B","description":"B."}]}]}"#,
  #"{"questions":[{"id":"","header":"Header","question":"Question?","options":[{"label":"A","description":"A."},{"label":"B","description":"B."}]}]}"#,
  #"{"questions":[{"id":"same","header":"Header","question":"Question?","options":[{"label":"A","description":"A."},{"label":"B","description":"B."}]},{"id":"same","header":"Again","question":"Again?","options":[{"label":"A","description":"A."},{"label":"B","description":"B."}]}]}"#,
  #"{"questions":[{"id":"one","header":" ","question":"Question?","options":[{"label":"A","description":"A."},{"label":"B","description":"B."}]}]}"#,
  #"{"questions":[{"id":"one","header":"Header","question":"\n","options":[{"label":"A","description":"A."},{"label":"B","description":"B."}]}]}"#,
  #"{"questions":[{"id":"one","header":"Header","question":"Question?","options":[{"label":"A","description":"A."}]}]}"#,
  #"{"questions":[{"id":"one","header":"Header","question":"Question?","options":[{"label":"A","description":"A."},{"label":"B","description":"B."},{"label":"C","description":"C."},{"label":"D","description":"D."}]}]}"#,
  #"{"questions":[{"id":"one","header":"Header","question":"Question?","options":[{"label":" ","description":"A."},{"label":"B","description":"B."}]}]}"#,
  #"{"questions":[{"id":"one","header":"Header","question":"Question?","options":[{"label":"A","description":""},{"label":"B","description":"B."}]}]}"#,
  #"{"questions":"not-an-array"}"#,
  #"not-json"#,
])
func persistedRequestUserInputExecutorRejectsInvalidArguments(
  arguments: String
) async {
  var promptCount = 0
  let executor = CodexPersistedTurnRequestUserInputExecutor { _ in
    promptCount += 1
    return CodexRequestUserInputAnswers(answers: [:])
  }

  await #expect(throws: CodexPersistedTurnRequestUserInputError.invalidArguments) {
    _ = try await executor.execute(
      persistedRequestUserInputToolRequest(arguments: arguments),
      cancellation: CodexTurnCancellation()
    )
  }
  #expect(promptCount == 0)
}

@MainActor
@Test
func persistedRequestUserInputExecutorRejectsOtherTools() async {
  let executor = CodexPersistedTurnRequestUserInputExecutor { _ in
    Issue.record("unsupported tools must not prompt")
    return CodexRequestUserInputAnswers(answers: [:])
  }

  await #expect(throws: CodexPersistedTurnRequestUserInputError.unsupportedTool) {
    _ = try await executor.execute(
      persistedRequestUserInputToolRequest(name: "read_workspace_file"),
      cancellation: CodexTurnCancellation()
    )
  }
}

@MainActor
@Test
func persistedRequestUserInputExecutorPropagatesCancellation() async {
  let cancellation = CodexTurnCancellation()
  cancellation.cancel()
  let executor = CodexPersistedTurnRequestUserInputExecutor { _ in
    Issue.record("cancelled prompts must not be presented")
    return CodexRequestUserInputAnswers(answers: [:])
  }

  await #expect(throws: CancellationError.self) {
    _ = try await executor.execute(
      persistedRequestUserInputToolRequest(),
      cancellation: cancellation
    )
  }
}

private func persistedRequestUserInputToolRequest(
  name: String = "request_user_input",
  arguments: String = """
    {
      "questions": [{
        "id": "confirm",
        "header": "Confirm",
        "question": "Proceed?",
        "options": [
          {"label":"Yes", "description":"Proceed now."},
          {"label":"No", "description":"Stop here."}
        ]
      }]
    }
    """
) -> CodexPersistedTurnToolRequest {
  CodexPersistedTurnToolRequest(
    threadID: CodexStoredThreadID("thread/interaction"),
    turnID: "turn/interaction",
    roundIndex: 2,
    name: name,
    arguments: arguments,
    callID: "call/interaction",
    itemJSON: #"{"type":"function_call","name":"request_user_input"}"#
  )
}

private func persistedRequestUserInputObject(
  _ json: String
) throws -> [String: Any] {
  try #require(
    JSONSerialization.jsonObject(with: Data(json.utf8))
      as? [String: Any]
  )
}
