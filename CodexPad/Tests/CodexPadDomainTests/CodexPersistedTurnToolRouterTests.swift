import CodexPadApplication
import CodexPadDomain
import Testing

@MainActor
@Test
func persistedTurnToolRouterRoutesInteractionWithoutWorkspacePrecondition()
  async throws
{
  let interaction = PersistedTurnRoutingExecutor(
    output: .init(
      itemJSON: #"{"type":"function_call_output","output":"interaction"}"#
    )
  )
  let workspace = PersistedTurnRoutingExecutor(
    output: .init(itemJSON: #"{"output":"workspace"}"#)
  )
  let router = CodexPersistedTurnToolRouter(
    interactionExecutor: interaction,
    workspaceExecutor: workspace
  )
  let request = persistedTurnRoutingRequest(name: "request_user_input")
  let cancellation = CodexTurnCancellation()

  let output = try await router.execute(
    request,
    cancellation: cancellation
  )

  #expect(output == interaction.output)
  #expect(interaction.requests == [request])
  #expect(interaction.cancellations.first === cancellation)
  #expect(workspace.requests.isEmpty)
}

@MainActor
@Test
func persistedTurnToolRouterRoutesPermissionsToDedicatedExecutor()
  async throws
{
  let interaction = PersistedTurnRoutingExecutor(
    output: .init(itemJSON: #"{"output":"interaction"}"#)
  )
  let permissions = PersistedTurnRoutingExecutor(
    output: .init(itemJSON: #"{"output":"permissions"}"#)
  )
  let workspace = PersistedTurnRoutingExecutor(
    output: .init(itemJSON: #"{"output":"workspace"}"#)
  )
  let router = CodexPersistedTurnToolRouter(
    interactionExecutor: interaction,
    requestPermissionsExecutor: permissions,
    workspaceExecutor: workspace
  )
  let request = persistedTurnRoutingRequest(name: "request_permissions")

  let output = try await router.execute(
    request,
    cancellation: CodexTurnCancellation()
  )

  #expect(output == permissions.output)
  #expect(permissions.requests == [request])
  #expect(interaction.requests.isEmpty)
  #expect(workspace.requests.isEmpty)
}

@MainActor
@Test
func persistedTurnToolRouterRoutesEveryOtherToolToWorkspace() async throws {
  let interaction = PersistedTurnRoutingExecutor(
    output: .init(itemJSON: #"{"output":"interaction"}"#)
  )
  let workspace = PersistedTurnRoutingExecutor(
    output: .init(
      itemJSON: #"{"type":"function_call_output","output":"workspace"}"#,
      workspaceDiff: "diff"
    )
  )
  let router = CodexPersistedTurnToolRouter(
    interactionExecutor: interaction,
    workspaceExecutor: workspace
  )
  let request = persistedTurnRoutingRequest(name: "write_workspace_file")
  let cancellation = CodexTurnCancellation()

  let output = try await router.execute(
    request,
    cancellation: cancellation
  )

  #expect(output == workspace.output)
  #expect(workspace.requests == [request])
  #expect(workspace.cancellations.first === cancellation)
  #expect(interaction.requests.isEmpty)
}

@MainActor
@Test
func persistedTurnToolRouterPrefersRegisteredDynamicToolOverWorkspace()
  async throws
{
  let interaction = PersistedTurnRoutingExecutor(
    output: .init(itemJSON: #"{"output":"interaction"}"#)
  )
  let workspace = PersistedTurnRoutingExecutor(
    output: .init(itemJSON: #"{"output":"workspace"}"#)
  )
  let dynamic = PersistedTurnRoutingDynamicExecutor(
    acceptedName: "lookup_ticket",
    output: .init(
      itemJSON:
        #"{"type":"function_call_output","call_id":"call","output":"dynamic"}"#
    )
  )
  let router = CodexPersistedTurnToolRouter(
    interactionExecutor: interaction,
    workspaceExecutor: workspace,
    dynamicToolExecutor: dynamic
  )
  let request = persistedTurnRoutingRequest(name: "lookup_ticket")

  let output = try await router.execute(
    request,
    cancellation: CodexTurnCancellation()
  )

  #expect(output == dynamic.output)
  #expect(dynamic.requests == [request])
  #expect(workspace.requests.isEmpty)
}

@MainActor
@Test
func persistedTurnToolRouterRoutesPlanAndImageToDedicatedExecutors()
  async throws
{
  let interaction = PersistedTurnRoutingExecutor(
    output: .init(itemJSON: #"{"output":"interaction"}"#)
  )
  let workspace = PersistedTurnRoutingExecutor(
    output: .init(itemJSON: #"{"output":"workspace"}"#)
  )
  let plan = PersistedTurnRoutingExecutor(
    output: .init(itemJSON: #"{"output":"plan"}"#)
  )
  let image = PersistedTurnRoutingExecutor(
    output: .init(itemJSON: #"{"output":"image"}"#)
  )
  let router = CodexPersistedTurnToolRouter(
    interactionExecutor: interaction,
    workspaceExecutor: workspace,
    updatePlanExecutor: plan,
    viewImageExecutor: image
  )

  let planOutput = try await router.execute(
    persistedTurnRoutingRequest(name: "update_plan"),
    cancellation: CodexTurnCancellation()
  )
  let imageOutput = try await router.execute(
    persistedTurnRoutingRequest(name: "view_image"),
    cancellation: CodexTurnCancellation()
  )

  #expect(planOutput == plan.output)
  #expect(imageOutput == image.output)
  #expect(plan.requests.count == 1)
  #expect(image.requests.count == 1)
  #expect(workspace.requests.isEmpty)
  #expect(interaction.requests.isEmpty)
}

@MainActor
@Test
func persistedTurnToolRouterKeepsPlanAvailableWithoutWorkspace()
  async throws
{
  let interaction = PersistedTurnRoutingExecutor(
    output: .init(itemJSON: #"{"output":"interaction"}"#)
  )
  let plan = PersistedTurnRoutingExecutor(
    output: .init(itemJSON: #"{"output":"plan"}"#)
  )
  let router = CodexPersistedTurnToolRouter(
    interactionExecutor: interaction,
    workspaceExecutor: nil,
    updatePlanExecutor: plan
  )

  let output = try await router.execute(
    persistedTurnRoutingRequest(name: "update_plan"),
    cancellation: CodexTurnCancellation()
  )

  #expect(output == plan.output)
  #expect(plan.requests.count == 1)
  await #expect(throws: CodexPersistedTurnToolRouterError.workspaceUnavailable) {
    _ = try await router.execute(
      persistedTurnRoutingRequest(name: "write_workspace_file"),
      cancellation: CodexTurnCancellation()
    )
  }
}

@MainActor
@Test
func persistedTurnToolRouterRoutesMCPResourcesWithoutWorkspace()
  async throws
{
  let interaction = PersistedTurnRoutingExecutor(
    output: .init(itemJSON: #"{"output":"interaction"}"#)
  )
  let mcpResources = PersistedTurnRoutingExecutor(
    output: .init(
      itemJSON: #"{"type":"function_call_output","output":"mcp-resource"}"#
    )
  )
  let router = CodexPersistedTurnToolRouter(
    interactionExecutor: interaction,
    workspaceExecutor: nil,
    mcpResourceExecutor: mcpResources
  )

  for name in [
    "list_mcp_resources",
    "list_mcp_resource_templates",
    "read_mcp_resource",
  ] {
    let output = try await router.execute(
      persistedTurnRoutingRequest(name: name),
      cancellation: CodexTurnCancellation()
    )
    #expect(output == mcpResources.output)
  }

  #expect(
    mcpResources.requests.map(\.name)
      == [
        "list_mcp_resources",
        "list_mcp_resource_templates",
        "read_mcp_resource",
      ]
  )
  #expect(interaction.requests.isEmpty)
}

@MainActor
@Test
func persistedTurnToolRouterPropagatesCancellationBeforeRouting() async {
  let interaction = PersistedTurnRoutingExecutor(
    output: .init(itemJSON: #"{"output":"interaction"}"#)
  )
  let workspace = PersistedTurnRoutingExecutor(
    output: .init(itemJSON: #"{"output":"workspace"}"#)
  )
  let router = CodexPersistedTurnToolRouter(
    interactionExecutor: interaction,
    workspaceExecutor: workspace
  )
  let cancellation = CodexTurnCancellation()
  cancellation.cancel()

  await #expect(throws: CancellationError.self) {
    _ = try await router.execute(
      persistedTurnRoutingRequest(name: "request_user_input"),
      cancellation: cancellation
    )
  }
  #expect(interaction.requests.isEmpty)
  #expect(workspace.requests.isEmpty)
}

@MainActor
@Test
func persistedTurnToolRouterPropagatesCancellationDuringRouting() async {
  let interaction = PersistedTurnRoutingExecutor(
    output: .init(itemJSON: #"{"output":"interaction"}"#),
    cancelDuringExecution: true
  )
  let workspace = PersistedTurnRoutingExecutor(
    output: .init(itemJSON: #"{"output":"workspace"}"#)
  )
  let router = CodexPersistedTurnToolRouter(
    interactionExecutor: interaction,
    workspaceExecutor: workspace
  )

  await #expect(throws: CancellationError.self) {
    _ = try await router.execute(
      persistedTurnRoutingRequest(name: "request_user_input"),
      cancellation: CodexTurnCancellation()
    )
  }
  #expect(interaction.requests.count == 1)
  #expect(workspace.requests.isEmpty)
}

@MainActor
private final class PersistedTurnRoutingExecutor:
  CodexPersistedTurnToolExecutor
{
  let output: CodexPersistedTurnLocalToolOutput
  let cancelDuringExecution: Bool
  private(set) var requests: [CodexPersistedTurnToolRequest] = []
  private(set) var cancellations: [CodexTurnCancellation] = []

  init(
    output: CodexPersistedTurnLocalToolOutput,
    cancelDuringExecution: Bool = false
  ) {
    self.output = output
    self.cancelDuringExecution = cancelDuringExecution
  }

  func execute(
    _ request: CodexPersistedTurnToolRequest,
    cancellation: CodexTurnCancellation
  ) async throws -> CodexPersistedTurnLocalToolOutput {
    requests.append(request)
    cancellations.append(cancellation)
    try cancellation.checkCancellation()
    if cancelDuringExecution {
      cancellation.cancel()
    }
    return output
  }
}

@MainActor
private final class PersistedTurnRoutingDynamicExecutor:
  CodexPersistedTurnDynamicToolExecutor
{
  let acceptedName: String
  let output: CodexPersistedTurnLocalToolOutput
  private(set) var requests: [CodexPersistedTurnToolRequest] = []

  init(
    acceptedName: String,
    output: CodexPersistedTurnLocalToolOutput
  ) {
    self.acceptedName = acceptedName
    self.output = output
  }

  func canExecute(toolName: String) -> Bool {
    toolName == acceptedName
  }

  func canExecute(toolName: String, itemJSON: String) -> Bool {
    canExecute(toolName: toolName)
  }

  func execute(
    _ request: CodexPersistedTurnToolRequest,
    cancellation: CodexTurnCancellation
  ) async throws -> CodexPersistedTurnLocalToolOutput {
    try cancellation.checkCancellation()
    requests.append(request)
    return output
  }
}

private func persistedTurnRoutingRequest(
  name: String
) -> CodexPersistedTurnToolRequest {
  CodexPersistedTurnToolRequest(
    threadID: CodexStoredThreadID("thread/router"),
    turnID: "turn/router",
    roundIndex: 1,
    name: name,
    arguments: #"{"value":true}"#,
    callID: "call/router",
    itemJSON: #"{"type":"function_call"}"#
  )
}
