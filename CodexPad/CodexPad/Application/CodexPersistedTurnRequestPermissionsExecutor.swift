import Foundation

#if SWIFT_PACKAGE
  import CodexPadDomain
#endif

public enum CodexPersistedTurnRequestPermissionsError:
  Error,
  Equatable,
  Sendable
{
  case unsupportedTool
  case invalidArguments
  case invalidApprovalResponse
}

public struct CodexPersistedTurnPermissionGrant:
  Equatable,
  Sendable
{
  public var networkEnabled: Bool
  public var readRoots: Set<String>
  public var writeRoots: Set<String>
  public var strictAutoReview: Bool

  public init(
    networkEnabled: Bool = false,
    readRoots: Set<String> = [],
    writeRoots: Set<String> = [],
    strictAutoReview: Bool = false
  ) {
    self.networkEnabled = networkEnabled
    self.readRoots = readRoots
    self.writeRoots = writeRoots
    self.strictAutoReview = strictAutoReview
  }

  fileprivate mutating func merge(
    _ other: CodexPersistedTurnPermissionGrant
  ) {
    networkEnabled = networkEnabled || other.networkEnabled
    readRoots.formUnion(other.readRoots)
    writeRoots.formUnion(other.writeRoots)
    strictAutoReview = strictAutoReview || other.strictAutoReview
  }
}

@MainActor
public final class CodexPersistedTurnPermissionGrantStore {
  private var sessionGrants:
    [String: CodexPersistedTurnPermissionGrant] = [:]
  private var turnGrants:
    [String: CodexPersistedTurnPermissionGrant] = [:]

  public init() {}

  public func grant(
    threadID: String,
    turnID: String
  ) -> CodexPersistedTurnPermissionGrant {
    var result = sessionGrants[threadID] ?? .init()
    if let turn = turnGrants[Self.turnKey(threadID, turnID)] {
      result.merge(turn)
    }
    return result
  }

  public func removeTurn(threadID: String, turnID: String) {
    turnGrants[Self.turnKey(threadID, turnID)] = nil
  }

  fileprivate func record(
    _ grant: CodexPersistedTurnPermissionGrant,
    scope: String,
    threadID: String,
    turnID: String
  ) {
    if scope == "session" {
      var current = sessionGrants[threadID] ?? .init()
      current.merge(grant)
      sessionGrants[threadID] = current
    } else {
      let key = Self.turnKey(threadID, turnID)
      var current = turnGrants[key] ?? .init()
      current.merge(grant)
      turnGrants[key] = current
    }
  }

  private static func turnKey(_ threadID: String, _ turnID: String) -> String {
    "\(threadID)\u{0}\(turnID)"
  }
}

@MainActor
public final class CodexPersistedTurnRequestPermissionsExecutor:
  CodexPersistedTurnToolExecutor
{
  public typealias Prompt =
    (CodexDesktopApprovalRequest) async -> CodexJSONValue?

  private let cwd: String
  private let grantStore: CodexPersistedTurnPermissionGrantStore
  private let prompt: Prompt
  private let now: () -> Int64

  public init(
    cwd: String,
    grantStore: CodexPersistedTurnPermissionGrantStore,
    prompt: @escaping Prompt,
    now: @escaping () -> Int64 = {
      Int64(Date().timeIntervalSince1970 * 1_000)
    }
  ) {
    self.cwd = cwd
    self.grantStore = grantStore
    self.prompt = prompt
    self.now = now
  }

  public func execute(
    _ request: CodexPersistedTurnToolRequest,
    cancellation: CodexTurnCancellation
  ) async throws -> CodexPersistedTurnLocalToolOutput {
    try Task.checkCancellation()
    try cancellation.checkCancellation()
    guard request.name == "request_permissions" else {
      throw CodexPersistedTurnRequestPermissionsError.unsupportedTool
    }

    let arguments = try Self.arguments(from: request.arguments)
    let approval = CodexDesktopApprovalRequest.permissions(
      threadID: request.threadID.rawValue,
      turnID: request.turnID,
      itemID: request.callID,
      environmentID: arguments.environmentID,
      startedAtMs: now(),
      cwd: cwd,
      reason: arguments.reason,
      permissions: arguments.permissions
    )
    let response = await prompt(approval)
    try Task.checkCancellation()
    try cancellation.checkCancellation()

    guard let response else {
      return CodexPersistedTurnLocalToolOutput(
        itemJSON: try Self.outputItemJSON(
          callID: request.callID,
          output: .object([
            "error": .string("permission request denied"),
          ])
        )
      )
    }
    let approved = try Self.approvedResponse(from: response)
    grantStore.record(
      approved.grant,
      scope: approved.scope,
      threadID: request.threadID.rawValue,
      turnID: request.turnID
    )
    return CodexPersistedTurnLocalToolOutput(
      itemJSON: try Self.outputItemJSON(
        callID: request.callID,
        output: approved.output
      )
    )
  }

  private static func arguments(
    from json: String
  ) throws -> (
    reason: String?,
    environmentID: String?,
    permissions: CodexJSONValue
  ) {
    guard
      let decoded = try? JSONDecoder().decode(
        CodexJSONValue.self,
        from: Data(json.utf8)
      ),
      case let .object(fields) = decoded,
      Set(fields.keys).isSubset(
        of: ["reason", "environment_id", "permissions"]
      ),
      case let .object(permissionFields)? = fields["permissions"],
      Set(permissionFields.keys).isSubset(of: ["network", "file_system"])
    else {
      throw CodexPersistedTurnRequestPermissionsError.invalidArguments
    }

    let reason = try optionalString(fields["reason"])
    let environmentID = try optionalString(fields["environment_id"])
    var translated: [String: CodexJSONValue] = [:]
    if let network = permissionFields["network"] {
      guard case let .object(networkFields) = network,
        Set(networkFields.keys).isSubset(of: ["enabled"]),
        case .bool? = networkFields["enabled"]
      else {
        throw CodexPersistedTurnRequestPermissionsError.invalidArguments
      }
      translated["network"] = network
    }
    if let fileSystem = permissionFields["file_system"] {
      guard case let .object(fileFields) = fileSystem,
        Set(fileFields.keys).isSubset(of: ["read", "write"])
      else {
        throw CodexPersistedTurnRequestPermissionsError.invalidArguments
      }
      for key in ["read", "write"] {
        if let value = fileFields[key] {
          _ = try roots(from: value)
        }
      }
      translated["fileSystem"] = fileSystem
    }
    guard !translated.isEmpty else {
      throw CodexPersistedTurnRequestPermissionsError.invalidArguments
    }
    return (reason, environmentID, .object(translated))
  }

  private static func approvedResponse(
    from response: CodexJSONValue
  ) throws -> (
    output: CodexJSONValue,
    scope: String,
    grant: CodexPersistedTurnPermissionGrant
  ) {
    guard case let .object(fields) = response,
      Set(fields.keys).isSubset(
        of: ["permissions", "scope", "strictAutoReview"]
      ),
      case let .object(permissions)? = fields["permissions"],
      Set(permissions.keys).isSubset(of: ["network", "fileSystem"])
    else {
      throw CodexPersistedTurnRequestPermissionsError
        .invalidApprovalResponse
    }
    let scope: String
    switch fields["scope"] {
    case nil:
      scope = "turn"
    case .string("turn"):
      scope = "turn"
    case .string("session"):
      scope = "session"
    default:
      throw CodexPersistedTurnRequestPermissionsError
        .invalidApprovalResponse
    }
    let strictAutoReview: Bool
    switch fields["strictAutoReview"] {
    case nil, .null:
      strictAutoReview = false
    case let .bool(value):
      strictAutoReview = value
    default:
      throw CodexPersistedTurnRequestPermissionsError
        .invalidApprovalResponse
    }

    var grant = CodexPersistedTurnPermissionGrant(
      strictAutoReview: strictAutoReview
    )
    if let network = permissions["network"] {
      guard case let .object(networkFields) = network,
        Set(networkFields.keys).isSubset(of: ["enabled"])
      else {
        throw CodexPersistedTurnRequestPermissionsError
          .invalidApprovalResponse
      }
      if case let .bool(enabled)? = networkFields["enabled"] {
        grant.networkEnabled = enabled
      } else if networkFields["enabled"] != nil {
        throw CodexPersistedTurnRequestPermissionsError
          .invalidApprovalResponse
      }
    }
    if let fileSystem = permissions["fileSystem"] {
      guard case let .object(fileFields) = fileSystem,
        Set(fileFields.keys).isSubset(of: ["read", "write"])
      else {
        throw CodexPersistedTurnRequestPermissionsError
          .invalidApprovalResponse
      }
      if let read = fileFields["read"] {
        grant.readRoots = Set(try roots(from: read))
      }
      if let write = fileFields["write"] {
        grant.writeRoots = Set(try roots(from: write))
      }
    }
    return (response, scope, grant)
  }

  private static func optionalString(
    _ value: CodexJSONValue?
  ) throws -> String? {
    switch value {
    case nil, .null:
      return nil
    case let .string(string)
      where !string.trimmingCharacters(
        in: .whitespacesAndNewlines
      ).isEmpty:
      return string
    default:
      throw CodexPersistedTurnRequestPermissionsError.invalidArguments
    }
  }

  private static func roots(
    from value: CodexJSONValue
  ) throws -> [String] {
    guard case let .array(values) = value else {
      throw CodexPersistedTurnRequestPermissionsError.invalidArguments
    }
    return try values.map { value in
      guard case let .string(root) = value,
        root.hasPrefix("/"),
        !root.trimmingCharacters(
          in: .whitespacesAndNewlines
        ).isEmpty
      else {
        throw CodexPersistedTurnRequestPermissionsError.invalidArguments
      }
      return root
    }
  }

  private static func outputItemJSON(
    callID: String,
    output: CodexJSONValue
  ) throws -> String {
    do {
      let outputData = try JSONEncoder().encode(output)
      guard let outputString = String(
        data: outputData,
        encoding: .utf8
      ) else {
        throw CodexPersistedTurnRequestPermissionsError
          .invalidApprovalResponse
      }
      let item = CodexPersistedTurnRequestPermissionsOutputItem(
        type: "function_call_output",
        callID: callID,
        output: outputString
      )
      let data = try JSONEncoder().encode(item)
      guard let json = String(data: data, encoding: .utf8) else {
        throw CodexPersistedTurnRequestPermissionsError
          .invalidApprovalResponse
      }
      return json
    } catch let error as CodexPersistedTurnRequestPermissionsError {
      throw error
    } catch {
      throw CodexPersistedTurnRequestPermissionsError
        .invalidApprovalResponse
    }
  }
}

private struct CodexPersistedTurnRequestPermissionsOutputItem: Encodable {
  let type: String
  let callID: String
  let output: String

  private enum CodingKeys: String, CodingKey {
    case type
    case callID = "call_id"
    case output
  }
}
