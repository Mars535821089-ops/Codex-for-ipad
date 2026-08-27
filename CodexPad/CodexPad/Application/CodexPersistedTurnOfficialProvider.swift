import Foundation

#if SWIFT_PACKAGE
  import CodexPadDomain
  import CodexPadProtocolBridge
#endif

public struct CodexPersistedTurnOfficialProviderConfiguration:
  Equatable,
  Sendable
{
  public let accessToken: String
  public let accountID: String?
  public let baseURL: String?
  public let model: String
  public let reasoningEffort: CodexReasoningEffort
  public let instructions: String
  public let collaborationInstructions: String?
  public let workspaceTools: Bool
  public let requestUserInputTool: Bool
  public let requestPermissionsTool: Bool
  public let updatePlanTool: Bool
  public let viewImageTool: Bool
  public let mcpResourceTools: Bool
  public let planMode: Bool
  public let toolSearchSources: [CodexOfficialToolSearchSource]
  public let dynamicTools: [CodexJSONValue]

  public init(
    accessToken: String,
    accountID: String?,
    baseURL: String? = nil,
    model: String,
    reasoningEffort: CodexReasoningEffort,
    instructions: String,
    collaborationInstructions: String? = nil,
    workspaceTools: Bool,
    requestUserInputTool: Bool = false,
    requestPermissionsTool: Bool = false,
    updatePlanTool: Bool = false,
    viewImageTool: Bool = false,
    mcpResourceTools: Bool = false,
    planMode: Bool = false,
    toolSearchSources: [CodexOfficialToolSearchSource] = [],
    dynamicTools: [CodexJSONValue] = []
  ) {
    self.accessToken = accessToken
    self.accountID = accountID
    self.baseURL = baseURL
    self.model = model
    self.reasoningEffort = reasoningEffort
    self.instructions = instructions
    self.collaborationInstructions = collaborationInstructions
    self.workspaceTools = workspaceTools
    self.requestUserInputTool = requestUserInputTool
    self.requestPermissionsTool = requestPermissionsTool
    self.updatePlanTool = updatePlanTool
    self.viewImageTool = viewImageTool
    self.mcpResourceTools = mcpResourceTools
    self.planMode = planMode
    self.toolSearchSources = toolSearchSources
    self.dynamicTools = dynamicTools
  }
}

public enum CodexDesktopSceneRuntimeProviderConfigurationFactory {
  public static func make(
    credentials: CodexOfficialCredentials,
    model: String,
    reasoningEffort: CodexReasoningEffort,
    collaborationInstructions: String?,
    workspaceTools: Bool,
    requestPermissionsTool: Bool,
    mcpResourceTools: Bool,
    planMode: Bool,
    toolSearchSources: [CodexOfficialToolSearchSource],
    dynamicTools: [CodexJSONValue] = []
  ) -> CodexPersistedTurnOfficialProviderConfiguration {
    let routeBaseURL: String?
    let routeAccountID: String?
    switch credentials.authMethod {
    case .chatGPT, .chatGPTAuthTokens:
      // OAuth turns always use the ChatGPT Codex backend. Do not allow a
      // stale API-key base URL or account id from an older persisted record
      // to silently route the request through api.openai.com.
      routeBaseURL = nil
      routeAccountID = credentials.accountID
    case .apiKey:
      // API-key turns always use the OpenAI Responses endpoint. The account
      // id belongs to ChatGPT OAuth and must never be forwarded with a key.
      routeBaseURL = CodexOfficialCredentials.openAIAPIBaseURL
      routeAccountID = nil
    default:
      // Preserve custom provider routes that are outside the two released
      // official modes; they are not eligible for the OAuth/API-key
      // normalization above.
      routeBaseURL = credentials.baseURL
      routeAccountID = credentials.accountID
    }
    return CodexPersistedTurnOfficialProviderConfiguration(
      accessToken: credentials.accessToken,
      accountID: routeAccountID,
      baseURL: routeBaseURL,
      model: model,
      reasoningEffort: reasoningEffort,
      instructions: """
      You are Codex, a coding agent. Be precise and practical. \
      Use the selected project when the request requires it.
      """,
      collaborationInstructions: collaborationInstructions,
      workspaceTools: workspaceTools,
      requestUserInputTool: true,
      requestPermissionsTool:
        workspaceTools && requestPermissionsTool,
      updatePlanTool: true,
      viewImageTool: workspaceTools,
      mcpResourceTools: mcpResourceTools,
      planMode: planMode,
      toolSearchSources: toolSearchSources,
      dynamicTools: dynamicTools
    )
  }
}

@MainActor
public protocol CodexPersistedTurnOfficialResponseStreaming: AnyObject {
  func stream(
    _ request: CodexOfficialResponseRequest,
    cancellation: CodexTurnCancellation
  ) async -> AsyncThrowingStream<CodexCoreProviderEvent, Error>
}

@MainActor
public final class CodexPersistedTurnOfficialProvider:
  CodexPersistedTurnProvider
{
  private let configuration:
    CodexPersistedTurnOfficialProviderConfiguration
  private let responseStream:
    any CodexPersistedTurnOfficialResponseStreaming

  public init(
    configuration:
      CodexPersistedTurnOfficialProviderConfiguration,
    responseStream:
      any CodexPersistedTurnOfficialResponseStreaming
  ) {
    self.configuration = configuration
    self.responseStream = responseStream
  }

  public func stream(
    _ request: CodexPersistedTurnProviderRequest,
    cancellation: CodexTurnCancellation
  ) async -> AsyncThrowingStream<CodexCoreProviderEvent, Error> {
    let input = request.steeringInput.isEmpty
      ? request.startParams.input
      : request.steeringInput
    let hasExplicitCollaborationMode: Bool
    if case .value = request.startParams.collaborationMode {
      hasExplicitCollaborationMode = true
    } else {
      hasExplicitCollaborationMode = false
    }
    let rendererModel = hasExplicitCollaborationMode
      ? configuration.model
      : Self.value(
        request.startParams.model,
        defaultingTo: configuration.model
      )
    let model = CodexDesktopConversationStreamAdapter
      .officialProviderModel(
        for: rendererModel,
        baseURL: configuration.baseURL
      )
    let reasoningEffort = hasExplicitCollaborationMode
      ? configuration.reasoningEffort.rawValue
      : Self.value(
        request.startParams.effort,
        defaultingTo: configuration.reasoningEffort.rawValue
      )
    let dynamicTools = Self.value(
      request.startParams.dynamicTools,
      defaultingTo: configuration.dynamicTools
    )
    let outputSchema: CodexJSONValue?
    if case .value(let schema) = request.startParams.outputSchema {
      outputSchema = schema
    } else {
      outputSchema = nil
    }

    let officialRequest = CodexOfficialResponseRequest(
      requestID: request.requestID,
      accessToken: configuration.accessToken,
      accountID: configuration.accountID,
      baseURL: configuration.baseURL,
      model: model,
      reasoningEffort: reasoningEffort,
      instructions: configuration.instructions,
      collaborationInstructions:
        configuration.collaborationInstructions,
      outputSchema: outputSchema,
      input: input,
      workspaceTools: configuration.workspaceTools,
      requestUserInputTool: configuration.requestUserInputTool,
      requestPermissionsTool: configuration.requestPermissionsTool,
      updatePlanTool: configuration.updatePlanTool,
      viewImageTool: configuration.viewImageTool,
      mcpResourceTools: configuration.mcpResourceTools,
      planMode: configuration.planMode,
      toolSearchSources: configuration.toolSearchSources,
      dynamicTools: dynamicTools,
      priorInputItems: request.frozenPriorInputItems,
      inputHistory: request.currentTurnInputItems
    )
    return await responseStream.stream(
      officialRequest,
      cancellation: cancellation
    )
  }

  private static func value<Value>(
    _ wire: CodexWireOptional<Value>,
    defaultingTo fallback: Value
  ) -> Value {
    guard case .value(let value) = wire else {
      return fallback
    }
    return value
  }
}

#if !SWIFT_PACKAGE
  @MainActor
  private final class CodexOfficialProviderResponseStream:
    CodexPersistedTurnOfficialResponseStreaming
  {
    private let client: CodexOfficialProviderClient

    init(client: CodexOfficialProviderClient) {
      self.client = client
    }

    func stream(
      _ request: CodexOfficialResponseRequest,
      cancellation: CodexTurnCancellation
    ) async -> AsyncThrowingStream<CodexCoreProviderEvent, Error> {
      await client.stream(request, cancellation: cancellation)
    }
  }

  extension CodexPersistedTurnOfficialProvider {
    public convenience init(
      configuration:
        CodexPersistedTurnOfficialProviderConfiguration,
      client: CodexOfficialProviderClient
    ) {
      self.init(
        configuration: configuration,
        responseStream:
          CodexOfficialProviderResponseStream(client: client)
      )
    }
  }
#endif
