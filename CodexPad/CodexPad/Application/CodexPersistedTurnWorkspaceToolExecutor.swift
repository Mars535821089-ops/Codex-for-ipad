import Foundation

#if SWIFT_PACKAGE
  import CodexPadDomain
  import CodexPadProtocolBridge
#endif

public struct CodexPersistedTurnWorkspaceToolActivity:
  Equatable,
  Sendable
{
  public let request: CodexPersistedTurnToolRequest
  public let decision: CodexToolDecision

  public init(
    request: CodexPersistedTurnToolRequest,
    decision: CodexToolDecision
  ) {
    self.request = request
    self.decision = decision
  }
}

public struct CodexPersistedTurnWorkspaceToolResult:
  Equatable,
  Sendable
{
  public let request: CodexPersistedTurnToolRequest
  public let decision: CodexToolDecision
  public let output: String
  public let itemJSON: String

  public init(
    request: CodexPersistedTurnToolRequest,
    decision: CodexToolDecision,
    output: String,
    itemJSON: String
  ) {
    self.request = request
    self.decision = decision
    self.output = output
    self.itemJSON = itemJSON
  }
}

private enum CodexPersistedTurnWorkspaceToolBackend {
  case runner(CodexWorkspaceToolRunner)
  case injected((String, String, Workspace) throws -> String)
}

private struct CodexPersistedTurnWorkspaceToolExecution {
  let output: String
  let workspaceDiff: String?
  let fileChanges: [CodexFileUpdateChange]?

  init(
    output: String,
    workspaceDiff: String?,
    fileChanges: [CodexFileUpdateChange]? = nil
  ) {
    self.output = output
    self.workspaceDiff = workspaceDiff
    self.fileChanges = fileChanges
  }
}

@MainActor
public final class CodexPersistedTurnWorkspaceToolExecutor:
  CodexPersistedTurnToolExecutor
{
  private let policy: CodexExecutionPolicy
  private let expectedWorkspacePath: String
  private let workspace: Workspace?
  private let backend: CodexPersistedTurnWorkspaceToolBackend
  private let commandExecutor:
    CodexDesktopWorkspaceCommandExecutor?
  private let permissionGrantStore:
    CodexPersistedTurnPermissionGrantStore?
  private let resolveBookmark: (String) throws -> URL
  private let approval:
    (CodexPersistedTurnWorkspaceToolActivity) async -> Bool
  private let onActivity:
    (CodexPersistedTurnWorkspaceToolActivity) -> Void
  private let onResult:
    (CodexPersistedTurnWorkspaceToolResult) -> Void

  public convenience init(
    policy: CodexExecutionPolicy,
    expectedWorkspacePath: String,
    workspace: Workspace?,
    runner: CodexWorkspaceToolRunner,
    commandExecutor:
      CodexDesktopWorkspaceCommandExecutor? = nil,
    permissionGrantStore:
      CodexPersistedTurnPermissionGrantStore? = nil,
    resolveBookmark:
      @escaping (String) throws -> URL = {
        try CodexWorkspaceAccess().resolve($0)
      },
    approval:
      @escaping (CodexPersistedTurnWorkspaceToolActivity) async -> Bool,
    onActivity:
      @escaping (CodexPersistedTurnWorkspaceToolActivity) -> Void = { _ in },
    onResult:
      @escaping (CodexPersistedTurnWorkspaceToolResult) -> Void = { _ in }
  ) {
    self.init(
      policy: policy,
      expectedWorkspacePath: expectedWorkspacePath,
      workspace: workspace,
      backend: .runner(runner),
      commandExecutor: commandExecutor,
      permissionGrantStore: permissionGrantStore,
      resolveBookmark: resolveBookmark,
      approval: approval,
      onActivity: onActivity,
      onResult: onResult
    )
  }

  public convenience init(
    policy: CodexExecutionPolicy,
    expectedWorkspacePath: String,
    workspace: Workspace?,
    execute:
      @escaping (String, String, Workspace) throws -> String,
    permissionGrantStore:
      CodexPersistedTurnPermissionGrantStore? = nil,
    resolveBookmark:
      @escaping (String) throws -> URL = {
        try CodexWorkspaceAccess().resolve($0)
      },
    approval:
      @escaping (CodexPersistedTurnWorkspaceToolActivity) async -> Bool,
    onActivity:
      @escaping (CodexPersistedTurnWorkspaceToolActivity) -> Void = { _ in },
    onResult:
      @escaping (CodexPersistedTurnWorkspaceToolResult) -> Void = { _ in }
  ) {
    self.init(
      policy: policy,
      expectedWorkspacePath: expectedWorkspacePath,
      workspace: workspace,
      backend: .injected(execute),
      commandExecutor: nil,
      permissionGrantStore: permissionGrantStore,
      resolveBookmark: resolveBookmark,
      approval: approval,
      onActivity: onActivity,
      onResult: onResult
    )
  }

  private init(
    policy: CodexExecutionPolicy,
    expectedWorkspacePath: String,
    workspace: Workspace?,
    backend: CodexPersistedTurnWorkspaceToolBackend,
    commandExecutor:
      CodexDesktopWorkspaceCommandExecutor?,
    permissionGrantStore:
      CodexPersistedTurnPermissionGrantStore?,
    resolveBookmark: @escaping (String) throws -> URL,
    approval:
      @escaping (CodexPersistedTurnWorkspaceToolActivity) async -> Bool,
    onActivity:
      @escaping (CodexPersistedTurnWorkspaceToolActivity) -> Void,
    onResult:
      @escaping (CodexPersistedTurnWorkspaceToolResult) -> Void
  ) {
    self.policy = policy
    self.expectedWorkspacePath = expectedWorkspacePath
    self.workspace = workspace
    self.backend = backend
    self.commandExecutor = commandExecutor
    self.permissionGrantStore = permissionGrantStore
    self.resolveBookmark = resolveBookmark
    self.approval = approval
    self.onActivity = onActivity
    self.onResult = onResult
  }

  public func execute(
    _ request: CodexPersistedTurnToolRequest,
    cancellation: CodexTurnCancellation
  ) async throws -> CodexPersistedTurnLocalToolOutput {
    try cancellation.checkCancellation()
    let workspace = try matchingWorkspace()
    let decision = policy.decision(for: request.name)
    let activity = CodexPersistedTurnWorkspaceToolActivity(
      request: request,
      decision: decision
    )
    onActivity(activity)

    let execution: CodexPersistedTurnWorkspaceToolExecution
    switch decision {
    case .allow:
      execution = try await executeWorkspaceTool(
        request,
        workspace: workspace,
        cancellation: cancellation
      )
    case .requireApproval:
      if await approval(activity) {
        try cancellation.checkCancellation()
        execution = try await executeWorkspaceTool(
          request,
          workspace: workspace,
          cancellation: cancellation
        )
      } else {
        execution = CodexPersistedTurnWorkspaceToolExecution(
          output: #"{"error":"workspace change denied"}"#,
          workspaceDiff: nil
        )
      }
    case .deny:
      execution = CodexPersistedTurnWorkspaceToolExecution(
        output: #"{"error":"blocked by sandbox policy"}"#,
        workspaceDiff: nil
      )
    }

    try cancellation.checkCancellation()
    let itemJSON = try Self.outputItemJSON(
      request: request,
      output: execution.output
    )
    let result = CodexPersistedTurnWorkspaceToolResult(
      request: request,
      decision: decision,
      output: execution.output,
      itemJSON: itemJSON
    )
    onResult(result)
    return CodexPersistedTurnLocalToolOutput(
      itemJSON: itemJSON,
      workspaceDiff: execution.workspaceDiff,
      fileChanges: execution.fileChanges
    )
  }

  private func executeWorkspaceTool(
    _ request: CodexPersistedTurnToolRequest,
    workspace: Workspace,
    cancellation: CodexTurnCancellation
  ) async throws -> CodexPersistedTurnWorkspaceToolExecution {
    do {
      try Task.checkCancellation()
      try cancellation.checkCancellation()
      let execution: CodexPersistedTurnWorkspaceToolExecution
      if let commandExecutor,
        request.name == "exec_command"
          || request.name == "write_stdin"
      {
        execution = CodexPersistedTurnWorkspaceToolExecution(
          output: try await executeUnifiedExecTool(
            request,
            workspace: workspace,
            executor: commandExecutor
          ),
          workspaceDiff: nil
        )
        try cancellation.checkCancellation()
        try Task.checkCancellation()
        return execution
      }
      switch backend {
      case .runner(let runner):
        let name = request.name
        let arguments = request.arguments
        execution = try await Task.detached(priority: .userInitiated) {
          try cancellation.checkCancellation()
          let result = try runner.executeDetailed(
            name: name,
            arguments: arguments,
            workspace: workspace,
            cancellation: cancellation
          )
          try cancellation.checkCancellation()
          return CodexPersistedTurnWorkspaceToolExecution(
            output: result.output,
            workspaceDiff: result.workspaceDiff,
            fileChanges: result.fileChanges
          )
        }.value
      case .injected(let execute):
        let output = try execute(
          request.name,
          request.arguments,
          workspace
        )
        execution = CodexPersistedTurnWorkspaceToolExecution(
          output: output,
          workspaceDiff: Self.successfulWorkspaceDiff(
            request: request,
            output: output
          )
        )
      }
      try cancellation.checkCancellation()
      try Task.checkCancellation()
      return execution
    } catch CodexWorkspaceToolError.unavailableWorkspace {
      throw CodexWorkspaceToolError.unavailableWorkspace
    } catch CodexWorkspaceAccessError.invalidBookmark {
      throw CodexWorkspaceToolError.unavailableWorkspace
    } catch CodexWorkspaceAccessError.accessDenied {
      throw CodexWorkspaceToolError.unavailableWorkspace
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      return CodexPersistedTurnWorkspaceToolExecution(
        output: #"{"error":"workspace tool execution failed"}"#,
        workspaceDiff: nil
      )
    }
  }

  private func executeUnifiedExecTool(
    _ request: CodexPersistedTurnToolRequest,
    workspace: Workspace,
    executor: CodexDesktopWorkspaceCommandExecutor
  ) async throws -> String {
    guard let bookmark = workspace.rootBookmarkID else {
      throw CodexWorkspaceToolError.unavailableWorkspace
    }
    let root: URL
    do {
      root = try resolveBookmark(bookmark)
    } catch {
      throw CodexWorkspaceToolError.unavailableWorkspace
    }
    let arguments: [String: Any]
    do {
      guard let object = try JSONSerialization.jsonObject(
        with: Data(request.arguments.utf8)
      ) as? [String: Any]
      else {
        throw CodexWorkspaceToolError.invalidArguments
      }
      arguments = object
    } catch {
      throw CodexWorkspaceToolError.invalidArguments
    }

    let result: CodexDesktopUnifiedExecOutput
    switch request.name {
    case "exec_command":
      guard let command = arguments["cmd"] as? String,
        !command.trimmingCharacters(
          in: .whitespacesAndNewlines
        ).isEmpty
      else {
        throw CodexWorkspaceToolError.invalidArguments
      }
      let tty = arguments["tty"] as? Bool ?? false
      let yieldTimeMS = try Self.unifiedExecUInt(
        arguments["yield_time_ms"],
        default: 10_000,
        minimum: 250,
        maximum: 30_000
      )
      let maxOutputTokens = try Self.unifiedExecOptionalNonnegativeInt(
        arguments["max_output_tokens"]
      )
      let shell = try Self.unifiedExecOptionalString(
        arguments["shell"]
      )
      let login = try Self.unifiedExecOptionalBool(
        arguments["login"]
      ) ?? true
      let cwd = arguments["workdir"] as? String
        ?? expectedWorkspacePath
      result = try await executor.launchUnifiedCommand(
        command: command,
        threadID: request.threadID.rawValue,
        turnID: request.turnID,
        itemID: request.callID,
        cwd: cwd,
        allowedRoots: allowedRoots(
          workspaceRoot: root,
          request: request
        ),
        tty: tty,
        yieldTimeMS: yieldTimeMS,
        maxOutputTokens: maxOutputTokens,
        shell: shell,
        login: login
      )
    case "write_stdin":
      guard let sessionID = Self.unifiedExecSessionID(
        arguments["session_id"]
      ) else {
        throw CodexWorkspaceToolError.invalidArguments
      }
      let chars = arguments["chars"] as? String ?? ""
      let yieldTimeMS = try Self.unifiedExecUInt(
        arguments["yield_time_ms"],
        default: chars.isEmpty ? 5_000 : 250,
        minimum: chars.isEmpty ? 5_000 : 250,
        maximum: chars.isEmpty ? 300_000 : 30_000
      )
      let maxOutputTokens = try Self.unifiedExecOptionalNonnegativeInt(
        arguments["max_output_tokens"]
      )
      result = try await executor.continueUnifiedCommand(
        processID: sessionID,
        chars: chars,
        yieldTimeMS: yieldTimeMS,
        maxOutputTokens: maxOutputTokens
      )
    default:
      throw CodexWorkspaceToolError.unsupportedTool
    }
    return result.responseText
  }

  private func allowedRoots(
    workspaceRoot: URL,
    request: CodexPersistedTurnToolRequest
  ) -> [String] {
    var roots = Set([
      Self.canonicalPath(workspaceRoot),
    ])
    if let permissionGrantStore {
      let grant = permissionGrantStore.grant(
        threadID: request.threadID.rawValue,
        turnID: request.turnID
      )
      roots.formUnion(grant.readRoots.map(Self.canonicalPath))
      roots.formUnion(grant.writeRoots.map(Self.canonicalPath))
    }
    return roots.sorted()
  }

  private static func unifiedExecSessionID(
    _ value: Any?
  ) -> String? {
    guard let number = value as? NSNumber else {
      return nil
    }
    let double = number.doubleValue
    guard double.rounded() == double,
      double >= Double(Int32.min),
      double <= Double(Int32.max)
    else {
      return nil
    }
    return String(number.int32Value)
  }

  private static func unifiedExecUInt(
    _ value: Any?,
    default defaultValue: UInt64,
    minimum: UInt64,
    maximum: UInt64
  ) throws -> UInt64 {
    guard let value else {
      return defaultValue
    }
    guard let number = value as? NSNumber else {
      throw CodexWorkspaceToolError.invalidArguments
    }
    let double = number.doubleValue
    guard double.rounded() == double,
      double >= Double(minimum),
      double <= Double(maximum)
    else {
      throw CodexWorkspaceToolError.invalidArguments
    }
    return UInt64(double)
  }

  private static func unifiedExecOptionalNonnegativeInt(
    _ value: Any?
  ) throws -> Int? {
    guard let value else {
      return nil
    }
    guard let number = value as? NSNumber else {
      throw CodexWorkspaceToolError.invalidArguments
    }
    let double = number.doubleValue
    guard double.rounded() == double,
      double >= 0,
      double <= Double(Int.max)
    else {
      throw CodexWorkspaceToolError.invalidArguments
    }
    return Int(double)
  }

  private static func unifiedExecOptionalString(
    _ value: Any?
  ) throws -> String? {
    guard let value else {
      return nil
    }
    guard let string = value as? String,
      !string.trimmingCharacters(
        in: .whitespacesAndNewlines
      ).isEmpty,
      !string.contains("\u{0}")
    else {
      throw CodexWorkspaceToolError.invalidArguments
    }
    return string
  }

  private static func unifiedExecOptionalBool(
    _ value: Any?
  ) throws -> Bool? {
    guard let value else {
      return nil
    }
    guard let bool = value as? Bool else {
      throw CodexWorkspaceToolError.invalidArguments
    }
    return bool
  }

  private func matchingWorkspace() throws -> Workspace {
    guard expectedWorkspacePath.hasPrefix("/"),
      let workspace,
      let bookmark = workspace.rootBookmarkID,
      !bookmark.isEmpty
    else {
      throw CodexWorkspaceToolError.unavailableWorkspace
    }
    let actualURL: URL
    do {
      actualURL = try resolveBookmark(bookmark)
    } catch {
      throw CodexWorkspaceToolError.unavailableWorkspace
    }
    let expectedURL = URL(
      fileURLWithPath: expectedWorkspacePath,
      isDirectory: true
    )
    let actualPath = Self.canonicalPath(actualURL)
    let expectedPath = Self.canonicalPath(expectedURL)
    let actualPathPrefix = actualPath.hasSuffix("/")
      ? actualPath
      : actualPath + "/"
    guard expectedPath == actualPath
      || expectedPath.hasPrefix(actualPathPrefix)
    else {
      throw CodexWorkspaceToolError.unavailableWorkspace
    }
    return workspace
  }

  private static func canonicalPath(_ url: URL) -> String {
    url.standardizedFileURL.resolvingSymlinksInPath().path
  }

  private static func canonicalPath(_ path: String) -> String {
    canonicalPath(URL(fileURLWithPath: path))
  }

  private static func outputItemJSON(
    request: CodexPersistedTurnToolRequest,
    output: String
  ) throws -> String {
    let data = try JSONEncoder().encode(
      CodexPersistedTurnFunctionCallOutput(
        type: Self.outputItemType(for: request),
        callID: request.callID,
        output: output
      )
    )
    guard let itemJSON = String(data: data, encoding: .utf8) else {
      throw CodexWorkspaceToolError.invalidArguments
    }
    return itemJSON
  }

  private static func outputItemType(
    for request: CodexPersistedTurnToolRequest
  ) -> String {
    guard
      let object = try? JSONSerialization.jsonObject(
        with: Data(request.itemJSON.utf8)
      ) as? [String: Any],
      object["type"] as? String == "custom_tool_call"
    else {
      return "function_call_output"
    }
    return "custom_tool_call_output"
  }

  private static func successfulWorkspaceDiff(
    request: CodexPersistedTurnToolRequest,
    output: String
  ) -> String? {
    guard request.name == "write_workspace_file",
      let object = try? JSONSerialization.jsonObject(
        with: Data(output.utf8)
      ) as? [String: Any],
      object["error"] == nil,
      let diff = object["diff"] as? String,
      !diff.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      return nil
    }
    return diff
  }
}

private struct CodexPersistedTurnFunctionCallOutput: Encodable {
  let type: String
  let callID: String
  let output: String

  private enum CodingKeys: String, CodingKey {
    case type
    case callID = "call_id"
    case output
  }
}
