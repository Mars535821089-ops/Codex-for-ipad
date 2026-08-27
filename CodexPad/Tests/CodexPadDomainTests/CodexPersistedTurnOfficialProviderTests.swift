import CodexPadApplication
import CodexPadDomain
import CodexPadProtocolBridge
import Foundation
import Testing

@MainActor
private final class PersistedOfficialResponseStreamFixture:
  CodexPersistedTurnOfficialResponseStreaming
{
  let events: [CodexCoreProviderEvent]
  private(set) var requests: [CodexOfficialResponseRequest] = []
  private(set) var cancellations: [CodexTurnCancellation] = []

  init(events: [CodexCoreProviderEvent]) {
    self.events = events
  }

  func stream(
    _ request: CodexOfficialResponseRequest,
    cancellation: CodexTurnCancellation
  ) async -> AsyncThrowingStream<CodexCoreProviderEvent, Error> {
    requests.append(request)
    cancellations.append(cancellation)
    return AsyncThrowingStream { continuation in
      for event in events {
        continuation.yield(event)
      }
      continuation.finish()
    }
  }
}

@MainActor
@Test
func persistedOfficialProviderMapsExactHistoryAndForwardsExactEvents()
  async throws
{
  let priorItem =
    "{\n \"type\":\"message\",\"role\":\"assistant\","
    + "\"content\":[{\"type\":\"output_text\",\"text\":\"旧\"}] }"
  let currentItem =
    "{ \"type\":\"function_call_output\","
    + "\"call_id\":\"call/raw\",\"output\":\"line 1\\nline 2\" }"
  let responseItem =
    "{\n \"type\":\"message\",\"role\":\"assistant\","
    + "\"content\":[{\"type\":\"output_text\",\"text\":\"完成\"}] }"
  let events: [CodexCoreProviderEvent] = [
    .responseStarted(
      sequence: 41,
      requestID: "turn/raw",
      sourceCommit: "source/from-client"
    ),
    .assistantTextDelta(
      sequence: 42,
      requestID: "turn/raw",
      delta: "完成"
    ),
    .toolCallRequested(
      sequence: 43,
      requestID: "turn/raw",
      name: "provider_declared_tool",
      arguments: #"{"path":"README.md"}"#,
      callID: "call/raw",
      itemJSON:
        #"{"type":"function_call","name":"provider_declared_tool","call_id":"call/raw"}"#
    ),
    .responseItemDone(
      sequence: 44,
      requestID: "turn/raw",
      itemJSON: responseItem
    ),
    .responseCompleted(
      sequence: 45,
      requestID: "turn/raw",
      responseID: "response/raw",
      usage: nil,
      endTurn: true
    ),
  ]
  let streamClient = PersistedOfficialResponseStreamFixture(
    events: events
  )
  let provider = CodexPersistedTurnOfficialProvider(
    configuration: .init(
      accessToken: "fixture-token",
      accountID: "fixture-account",
      baseURL: "https://fixture.invalid/codex",
      model: "configured-model",
      reasoningEffort: .low,
      instructions: "Explicit persisted-turn instructions.",
      collaborationInstructions: "Exact collaboration instructions.",
      workspaceTools: false,
      requestUserInputTool: true,
      requestPermissionsTool: true,
      updatePlanTool: true,
      viewImageTool: true,
      mcpResourceTools: true,
      planMode: true,
      toolSearchSources: [
        CodexOfficialToolSearchSource(
          name: "docs",
          description: "Official documentation"
        )
      ],
      dynamicTools: [
        .object([
          "type": .string("function"),
          "name": .string("lookup_ticket"),
          "description": .string("Look up a ticket."),
          "inputSchema": .object([
            "type": .string("object"),
            "properties": .object([:]),
          ]),
        ])
      ]
    ),
    responseStream: streamClient
  )
  let cancellation = CodexTurnCancellation()
  let request = CodexPersistedTurnProviderRequest(
    requestID: "turn/raw",
    roundIndex: 3,
    threadID: CodexStoredThreadID("thread/raw"),
    turnID: "turn/raw",
    startParams: CodexTurnStartParams(
      threadID: CodexStoredThreadID("thread/raw"),
      input: [
        .text(
          text: "继续，原样发送。",
          textElements: [
            .object([
              "byteRange": .object([
                "start": .integer(0),
                "end": .integer(3),
              ]),
              "placeholder": .string("继续"),
            ]),
          ]
        ),
        .image(
          detail: .high,
          url: "data:image/png;base64,AAAA"
        ),
        .localImage(
          detail: .original,
          path: "/workspace/reference.heic"
        ),
        .audio(url: "data:audio/wav;base64,BBBB"),
        .localAudio(path: "/workspace/note.m4a"),
        .skill(name: "review", path: "/skills/review/SKILL.md"),
        .mention(name: "docs", path: "app://docs"),
      ],
      model: .value("request-model"),
      effort: .value("ultra")
    ),
    frozenPriorInputItems: [priorItem],
    currentTurnInputItems: [currentItem]
  )

  var received: [CodexCoreProviderEvent] = []
  let stream = await provider.stream(
    request,
    cancellation: cancellation
  )
  for try await event in stream {
    received.append(event)
  }

  #expect(received == events)
  #expect(streamClient.requests.count == 1)
  #expect(streamClient.cancellations.count == 1)
  #expect(streamClient.cancellations[0] === cancellation)
  #expect(
    streamClient.requests[0]
      == CodexOfficialResponseRequest(
        requestID: "turn/raw",
        accessToken: "fixture-token",
        accountID: "fixture-account",
        baseURL: "https://fixture.invalid/codex",
        model: "request-model",
        reasoningEffort: .ultra,
        instructions: "Explicit persisted-turn instructions.",
        collaborationInstructions:
          "Exact collaboration instructions.",
        input: [
          .text(
            text: "继续，原样发送。",
            textElements: [
              .object([
                "byteRange": .object([
                  "start": .integer(0),
                  "end": .integer(3),
                ]),
                "placeholder": .string("继续"),
              ]),
            ]
          ),
          .image(
            detail: .high,
            url: "data:image/png;base64,AAAA"
          ),
          .localImage(
            detail: .original,
            path: "/workspace/reference.heic"
          ),
          .audio(url: "data:audio/wav;base64,BBBB"),
          .localAudio(path: "/workspace/note.m4a"),
          .skill(
            name: "review",
            path: "/skills/review/SKILL.md"
          ),
          .mention(name: "docs", path: "app://docs"),
        ],
        workspaceTools: false,
        requestUserInputTool: true,
        requestPermissionsTool: true,
        updatePlanTool: true,
        viewImageTool: true,
        mcpResourceTools: true,
        planMode: true,
        toolSearchSources: [
          CodexOfficialToolSearchSource(
            name: "docs",
            description: "Official documentation"
          )
        ],
        dynamicTools: [
          .object([
            "type": .string("function"),
            "name": .string("lookup_ticket"),
            "description": .string("Look up a ticket."),
            "inputSchema": .object([
              "type": .string("object"),
              "properties": .object([:]),
            ]),
          ])
        ],
        priorInputItems: [priorItem],
        inputHistory: [currentItem]
      )
  )
}

@MainActor
@Test
func persistedOfficialProviderKeepsExplicitCollaborationModeAuthoritative()
  async throws
{
  let streamClient = PersistedOfficialResponseStreamFixture(events: [])
  let provider = CodexPersistedTurnOfficialProvider(
    configuration: .init(
      accessToken: "fixture-token",
      accountID: "fixture-account",
      model: "collaboration-model",
      reasoningEffort: .high,
      instructions: "Base instructions.",
      collaborationInstructions: "Plan instructions.",
      workspaceTools: false,
      planMode: true
    ),
    responseStream: streamClient
  )
  let request = CodexPersistedTurnProviderRequest(
    requestID: "turn/collaboration",
    roundIndex: 0,
    threadID: CodexStoredThreadID("thread/collaboration"),
    turnID: "turn/collaboration",
    startParams: CodexTurnStartParams(
      threadID: CodexStoredThreadID("thread/collaboration"),
      input: [.text(text: "Plan this.", textElements: [])],
      model: .value("ordinary-model-must-not-win"),
      effort: .value("ultra"),
      collaborationMode: .value(
        CodexCollaborationMode(
          mode: .plan,
          settings: CodexCollaborationModeSettings(
            model: "collaboration-model",
            reasoningEffort: "high",
            developerInstructions: "Plan instructions."
          )
        )
      )
    ),
    frozenPriorInputItems: [],
    currentTurnInputItems: []
  )

  let stream = await provider.stream(
    request,
    cancellation: CodexTurnCancellation()
  )
  for try await _ in stream {}

  #expect(streamClient.requests.count == 1)
  #expect(streamClient.requests[0].model == "collaboration-model")
  #expect(streamClient.requests[0].reasoningEffort == "high")
  #expect(streamClient.requests[0].planMode)
  #expect(
    streamClient.requests[0].collaborationInstructions
      == "Plan instructions."
  )
}

@MainActor
@Test
func persistedOfficialProviderNormalizesReleasedRendererModelAlias()
  async throws
{
  let streamClient = PersistedOfficialResponseStreamFixture(events: [])
  let provider = CodexPersistedTurnOfficialProvider(
    configuration: .init(
      accessToken: "fixture-token",
      accountID: "fixture-account",
      model: "gpt-5.6-sol",
      reasoningEffort: .low,
      instructions: "Base instructions.",
      workspaceTools: false
    ),
    responseStream: streamClient
  )
  let request = CodexPersistedTurnProviderRequest(
    requestID: "turn/model-alias",
    roundIndex: 0,
    threadID: CodexStoredThreadID("thread/model-alias"),
    turnID: "turn/model-alias",
    startParams: CodexTurnStartParams(
      threadID: CodexStoredThreadID("thread/model-alias"),
      input: [.text(text: "Continue.", textElements: [])],
      model: .value("gpt-5-6")
    ),
    frozenPriorInputItems: [],
    currentTurnInputItems: []
  )

  let stream = await provider.stream(
    request,
    cancellation: CodexTurnCancellation()
  )
  for try await _ in stream {}

  #expect(streamClient.requests.count == 1)
  #expect(streamClient.requests[0].model == "gpt-5.5")
}

@MainActor
@Test
func persistedOfficialProviderForwardsOutputSchema() async throws {
  let outputSchema: CodexJSONValue = .object([
    "type": .string("object"),
    "properties": .object([
      "summary": .object(["type": .string("string")])
    ]),
    "required": .array([.string("summary")]),
    "additionalProperties": .bool(false),
  ])
  let streamClient = PersistedOfficialResponseStreamFixture(events: [])
  let provider = CodexPersistedTurnOfficialProvider(
    configuration: .init(
      accessToken: "fixture-token",
      accountID: "fixture-account",
      model: "gpt-5.6-sol",
      reasoningEffort: .low,
      instructions: "Base instructions.",
      workspaceTools: false
    ),
    responseStream: streamClient
  )
  let request = CodexPersistedTurnProviderRequest(
    requestID: "turn/output-schema",
    roundIndex: 0,
    threadID: CodexStoredThreadID("thread/output-schema"),
    turnID: "turn/output-schema",
    startParams: CodexTurnStartParams(
      threadID: CodexStoredThreadID("thread/output-schema"),
      input: [.text(text: "Summarize.", textElements: [])],
      outputSchema: .value(outputSchema)
    ),
    frozenPriorInputItems: [],
    currentTurnInputItems: []
  )

  let stream = await provider.stream(
    request,
    cancellation: CodexTurnCancellation()
  )
  for try await _ in stream {}

  #expect(streamClient.requests.count == 1)
  let encoded = try streamClient.requests[0].encodedData()
  let object = try #require(
    JSONSerialization.jsonObject(with: encoded) as? [String: Any]
  )
  let expectedData = try JSONEncoder().encode(outputSchema)
  let expected = try JSONSerialization.jsonObject(with: expectedData)
  #expect(
    NSDictionary(dictionary: object["outputSchema"] as? [String: Any] ?? [:])
      == NSDictionary(dictionary: expected as? [String: Any] ?? [:])
  )
}
