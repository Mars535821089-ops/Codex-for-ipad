import Foundation
import CodexPadApplication
import CodexPadDomain
import Testing

@MainActor
@Test
func persistedTurnToolSearchUsesBM25AndEmitsDeferredFunctionSpecs()
  async throws
{
  let source = CodexDeferredToolSearchSource(
    namespace: "mcp__calendar",
    description: "Calendar tools.",
    tools: [
      .init(
        name: "create_event",
        description: "Create a calendar event.",
        parameters: .object([
          "type": .string("object"),
          "properties": .object([
            "title": .object(["type": .string("string")]),
          ]),
        ])
      ),
      .init(
        name: "list_events",
        description: "List calendar events.",
        parameters: .object([
          "type": .string("object"),
          "properties": .object([
            "after": .object(["type": .string("string")]),
          ]),
        ])
      ),
      .init(
        name: "set_timezone",
        description: "Set the calendar timezone.",
        parameters: .object([
          "type": .string("object"),
          "properties": .object([
            "timezone": .object(["type": .string("string")]),
          ]),
        ])
      ),
    ]
  )
  let executor = CodexPersistedTurnToolSearchExecutor(sources: [source])

  let output = try await executor.execute(
    persistedTurnToolSearchRequest(
      name: "tool_search",
      arguments: #"{"query":"create calendar event","limit":2}"#
    ),
    cancellation: CodexTurnCancellation()
  )

  let object = try persistedTurnToolSearchJSONObject(output.itemJSON)
  #expect(object["type"] as? String == "tool_search_output")
  #expect(object["call_id"] as? String == "call/tool-search")
  #expect(object["status"] as? String == "completed")
  #expect(object["execution"] as? String == "client")

  let namespaces = try #require(object["tools"] as? [[String: Any]])
  let functions = try #require(namespaces.first?["tools"] as? [[String: Any]])
  #expect(namespaces.first?["type"] as? String == "namespace")
  #expect(namespaces.first?["name"] as? String == "mcp__calendar")
  #expect(functions.count == 2)
  #expect(functions.first?["name"] as? String == "create_event")
  #expect(functions.first?["defer_loading"] as? Bool == true)
  #expect(executor.activatedToolNames.first == "mcp__calendarcreate_event")
  #expect(executor.activatedToolNames.count == 2)
}

@MainActor
@Test
func persistedTurnToolSearchHonorsDefaultLimitAndNoSourceBoundary()
  async throws
{
  let tools = (0..<10).map { index in
    CodexDeferredToolSearchDefinition(
      name: "tool_\(index)",
      description: "A searchable tool \(index).",
      parameters: .object(["type": .string("object")])
    )
  }
  let executor = CodexPersistedTurnToolSearchExecutor(
    sources: [
      CodexDeferredToolSearchSource(
        namespace: nil,
        description: "Local tools.",
        tools: tools
      ),
    ]
  )

  let output = try await executor.execute(
    persistedTurnToolSearchRequest(
      name: "tool_search",
      arguments: #"{"query":"searchable"}"#
    ),
    cancellation: CodexTurnCancellation()
  )
  let object = try persistedTurnToolSearchJSONObject(output.itemJSON)
  let results = try #require(object["tools"] as? [[String: Any]])
  #expect(results.count == 8)
  #expect(results.allSatisfy { ($0["type"] as? String) == "function" })

  let emptyExecutor = CodexPersistedTurnToolSearchExecutor(sources: [])
  let emptyOutput = try await emptyExecutor.execute(
    persistedTurnToolSearchRequest(
      name: "tool_search",
      arguments: #"{"query":"anything","limit":1}"#
    ),
    cancellation: CodexTurnCancellation()
  )
  let emptyObject = try persistedTurnToolSearchJSONObject(emptyOutput.itemJSON)
  #expect((emptyObject["tools"] as? [[String: Any]])?.isEmpty == true)
}

@MainActor
@Test
func persistedTurnToolSearchRejectsTrimmedEmptyQueryAndNonPositiveLimit()
  async
{
  let executor = CodexPersistedTurnToolSearchExecutor(sources: [])

  await #expect(throws: CodexPersistedTurnToolSearchError.emptyQuery) {
    _ = try await executor.execute(
      persistedTurnToolSearchRequest(
        name: "tool_search",
        arguments: #"{"query":"   "}"#
      ),
      cancellation: CodexTurnCancellation()
    )
  }
  await #expect(throws: CodexPersistedTurnToolSearchError.invalidLimit) {
    _ = try await executor.execute(
      persistedTurnToolSearchRequest(
        name: "tool_search",
        arguments: #"{"query":"calendar","limit":0}"#
      ),
      cancellation: CodexTurnCancellation()
    )
  }
  await #expect(throws: CodexPersistedTurnToolSearchError.invalidArguments) {
    _ = try await executor.execute(
      persistedTurnToolSearchRequest(
        name: "tool_search",
        arguments: #"{"query":"calendar","unexpected":true}"#
      ),
      cancellation: CodexTurnCancellation()
    )
  }
}

@MainActor
@Test
func persistedTurnToolSearchActivatesAndInvokesASelectedDynamicTool()
  async throws
{
  var invokedRequest: CodexPersistedTurnToolRequest?
  let source = CodexDeferredToolSearchSource(
    namespace: "mcp__calendar",
    description: "Calendar tools.",
    tools: [
      .init(
        name: "create_event",
        description: "Create a calendar event.",
        parameters: .object(["type": .string("object")]),
        invocation: { request, _ in
          invokedRequest = request
          return .init(
            itemJSON: #"{"type":"function_call_output","output":"created"}"#
          )
        }
      ),
    ]
  )
  let executor = CodexPersistedTurnToolSearchExecutor(sources: [source])
  _ = try await executor.execute(
    persistedTurnToolSearchRequest(
      name: "tool_search",
      arguments: #"{"query":"create event"}"#
    ),
    cancellation: CodexTurnCancellation()
  )

  #expect(executor.canExecute(toolName: "mcp__calendarcreate_event"))
  let invocationRequest = persistedTurnToolSearchRequest(
    name: "mcp__calendarcreate_event",
    arguments: #"{"title":"Launch"}"#
  )
  let output = try await executor.execute(
    invocationRequest,
    cancellation: CodexTurnCancellation()
  )

  #expect(output.itemJSON.contains(#""output":"created""#))
  #expect(invokedRequest == invocationRequest)
}

@MainActor
@Test
func persistedTurnToolRouterRoutesToolSearchAndActivatedDynamicName()
  async throws
{
  let interaction = PersistedTurnRoutingSearchTestExecutor(
    output: .init(itemJSON: #"{"output":"interaction"}"#)
  )
  let workspace = PersistedTurnRoutingSearchTestExecutor(
    output: .init(itemJSON: #"{"output":"workspace"}"#)
  )
  let source = CodexDeferredToolSearchSource(
    namespace: "mcp__calendar",
    description: "Calendar tools.",
    tools: [
      .init(
        name: "create_event",
        description: "Create a calendar event.",
        parameters: .object(["type": .string("object")]),
        invocation: { _, _ in
          .init(itemJSON: #"{"output":"dynamic"}"#)
        }
      ),
    ]
  )
  let search = CodexPersistedTurnToolSearchExecutor(sources: [source])
  let router = CodexPersistedTurnToolRouter(
    interactionExecutor: interaction,
    workspaceExecutor: workspace,
    toolSearchExecutor: search
  )

  let searchOutput = try await router.execute(
    persistedTurnToolSearchRequest(
      name: "tool_search",
      arguments: #"{"query":"create event"}"#
    ),
    cancellation: CodexTurnCancellation()
  )
  #expect(searchOutput.itemJSON.contains(#""type":"tool_search_output""#))

  let dynamicOutput = try await router.execute(
    persistedTurnToolSearchRequest(
      name: "mcp__calendarcreate_event",
      arguments: #"{"title":"Launch"}"#
    ),
    cancellation: CodexTurnCancellation()
  )
  #expect(dynamicOutput.itemJSON == #"{"output":"dynamic"}"#)
  #expect(workspace.requests.isEmpty)
}

private func persistedTurnToolSearchRequest(
  name: String,
  arguments: String
) -> CodexPersistedTurnToolRequest {
  CodexPersistedTurnToolRequest(
    threadID: CodexStoredThreadID("thread/tool-search"),
    turnID: "turn/tool-search",
    roundIndex: 1,
    name: name,
    arguments: arguments,
    callID: "call/tool-search",
    itemJSON: #"{"type":"function_call"}"#
  )
}

private func persistedTurnToolSearchJSONObject(
  _ itemJSON: String
) throws -> [String: Any] {
  let data = try #require(itemJSON.data(using: .utf8))
  return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

@MainActor
private final class PersistedTurnRoutingSearchTestExecutor:
  CodexPersistedTurnToolExecutor
{
  let output: CodexPersistedTurnLocalToolOutput
  private(set) var requests: [CodexPersistedTurnToolRequest] = []

  init(output: CodexPersistedTurnLocalToolOutput) {
    self.output = output
  }

  func execute(
    _ request: CodexPersistedTurnToolRequest,
    cancellation: CodexTurnCancellation
  ) async throws -> CodexPersistedTurnLocalToolOutput {
    requests.append(request)
    try cancellation.checkCancellation()
    return output
  }
}
