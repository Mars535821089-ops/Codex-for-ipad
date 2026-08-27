#if SWIFT_PACKAGE
  import CodexPadDomain
#endif

@MainActor
public final class CodexPersistedTurnToolRouter:
  CodexPersistedTurnToolExecutor
{
  private let interactionExecutor: any CodexPersistedTurnToolExecutor
  private let requestPermissionsExecutor:
    (any CodexPersistedTurnToolExecutor)?
  private let workspaceExecutor: (any CodexPersistedTurnToolExecutor)?
  private let updatePlanExecutor: (any CodexPersistedTurnToolExecutor)?
  private let viewImageExecutor: (any CodexPersistedTurnToolExecutor)?
  private let mcpResourceExecutor: (any CodexPersistedTurnToolExecutor)?
  private let toolSearchExecutor: (any CodexPersistedTurnToolExecutor)?
  private let dynamicToolExecutor:
    (any CodexPersistedTurnDynamicToolExecutor)?

  public init(
    interactionExecutor: any CodexPersistedTurnToolExecutor,
    requestPermissionsExecutor:
      (any CodexPersistedTurnToolExecutor)? = nil,
    workspaceExecutor: (any CodexPersistedTurnToolExecutor)?,
    updatePlanExecutor: (any CodexPersistedTurnToolExecutor)? = nil,
    viewImageExecutor: (any CodexPersistedTurnToolExecutor)? = nil,
    mcpResourceExecutor: (any CodexPersistedTurnToolExecutor)? = nil,
    toolSearchExecutor: (any CodexPersistedTurnToolExecutor)? = nil,
    dynamicToolExecutor:
      (any CodexPersistedTurnDynamicToolExecutor)? = nil
  ) {
    self.interactionExecutor = interactionExecutor
    self.requestPermissionsExecutor = requestPermissionsExecutor
    self.workspaceExecutor = workspaceExecutor
    self.updatePlanExecutor = updatePlanExecutor
    self.viewImageExecutor = viewImageExecutor
    self.mcpResourceExecutor = mcpResourceExecutor
    self.toolSearchExecutor = toolSearchExecutor
    self.dynamicToolExecutor = dynamicToolExecutor
  }

  public func execute(
    _ request: CodexPersistedTurnToolRequest,
    cancellation: CodexTurnCancellation
  ) async throws -> CodexPersistedTurnLocalToolOutput {
    try Task.checkCancellation()
    try cancellation.checkCancellation()
    let executor: any CodexPersistedTurnToolExecutor
    switch request.name {
    case "request_user_input":
      executor = interactionExecutor
    case "request_permissions":
      guard let requestPermissionsExecutor else {
        throw CodexPersistedTurnToolRouterError
          .requestPermissionsUnavailable
      }
      executor = requestPermissionsExecutor
    case "update_plan":
      guard let updatePlanExecutor = updatePlanExecutor ?? workspaceExecutor
      else {
        throw CodexPersistedTurnToolRouterError.workspaceUnavailable
      }
      executor = updatePlanExecutor
    case "view_image":
      guard let viewImageExecutor = viewImageExecutor ?? workspaceExecutor
      else {
        throw CodexPersistedTurnToolRouterError.workspaceUnavailable
      }
      executor = viewImageExecutor
    case "list_mcp_resources",
      "list_mcp_resource_templates",
      "read_mcp_resource":
      guard let mcpResourceExecutor else {
        throw CodexPersistedTurnToolRouterError.mcpResourcesUnavailable
      }
      executor = mcpResourceExecutor
    case "tool_search":
      guard let toolSearchExecutor else {
        throw CodexPersistedTurnToolRouterError.toolSearchUnavailable
      }
      executor = toolSearchExecutor
    default:
      if let dynamicToolExecutor,
        dynamicToolExecutor.canExecute(
          toolName: request.name,
          itemJSON: request.itemJSON
        )
      {
        executor = dynamicToolExecutor
        break
      }
      if let dynamicToolExecutor = toolSearchExecutor
        as? any CodexPersistedTurnDynamicToolExecutor,
        dynamicToolExecutor.canExecute(
          toolName: request.name,
          itemJSON: request.itemJSON
        )
      {
        executor = dynamicToolExecutor
        break
      }
      guard let workspaceExecutor else {
        throw CodexPersistedTurnToolRouterError.workspaceUnavailable
      }
      executor = workspaceExecutor
    }
    let output = try await executor.execute(
      request,
      cancellation: cancellation
    )
    try Task.checkCancellation()
    try cancellation.checkCancellation()
    return output
  }
}

public enum CodexPersistedTurnToolRouterError:
  Error,
  Equatable,
  Sendable
{
  case workspaceUnavailable
  case requestPermissionsUnavailable
  case mcpResourcesUnavailable
  case toolSearchUnavailable
}
