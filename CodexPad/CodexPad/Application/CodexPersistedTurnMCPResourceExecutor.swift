import Foundation

#if SWIFT_PACKAGE
  import CodexPadDomain
#endif

@MainActor
public final class CodexPersistedTurnMCPResourceExecutor:
  CodexPersistedTurnToolExecutor
{
  private let service: CodexMCPResourceCatalogService?
  private let runtimeRegistry: CodexMCPRuntimeRegistry?

  public init(service: CodexMCPResourceCatalogService) {
    self.service = service
    runtimeRegistry = nil
  }

  public init(runtimeRegistry: CodexMCPRuntimeRegistry) {
    service = nil
    self.runtimeRegistry = runtimeRegistry
  }

  public func execute(
    _ request: CodexPersistedTurnToolRequest,
    cancellation: CodexTurnCancellation
  ) async throws -> CodexPersistedTurnLocalToolOutput {
    try Task.checkCancellation()
    try cancellation.checkCancellation()

    let payload: String
    switch request.name {
    case "list_mcp_resources":
      let arguments = try Self.listArguments(from: request.arguments)
      let page = try catalogService().listResources(
        server: arguments.server,
        cursor: arguments.cursor
      )
      payload = try Self.resourcePayload(page)
    case "list_mcp_resource_templates":
      let arguments = try Self.listArguments(from: request.arguments)
      let page = try catalogService().listResourceTemplates(
        server: arguments.server,
        cursor: arguments.cursor
      )
      payload = try Self.resourceTemplatePayload(page)
    case "read_mcp_resource":
      let arguments = try Self.readArguments(from: request.arguments)
      let result: CodexMCPResourceReadResult
      if let runtimeRegistry {
        result = CodexMCPResourceReadResult(
          server: arguments.server,
          uri: arguments.uri,
          contents: try await runtimeRegistry.readMCPResource(
            threadID: nil,
            server: arguments.server,
            uri: arguments.uri
          )
        )
      } else if let service {
        result = try service.readResource(
          server: arguments.server,
          uri: arguments.uri
        )
      } else {
        throw CodexMCPResourceError.invalidCatalog
      }
      payload = try Self.readPayload(result)
    default:
      throw CodexMCPResourceError.unsupportedTool
    }

    try Task.checkCancellation()
    try cancellation.checkCancellation()
    return CodexPersistedTurnLocalToolOutput(
      itemJSON: try Self.outputItemJSON(
        callID: request.callID,
        payload: payload
      )
    )
  }

  private func catalogService() throws -> CodexMCPResourceCatalogService {
    if let service {
      return service
    }
    guard let runtimeRegistry else {
      throw CodexMCPResourceError.invalidCatalog
    }
    return try runtimeRegistry.makeResourceCatalogSnapshot()
  }

  private struct ListArguments {
    let server: String?
    let cursor: String?
  }

  private struct ReadArguments {
    let server: String
    let uri: String
  }

  private static func listArguments(
    from json: String
  ) throws -> ListArguments {
    let object = try argumentObject(from: json, emptyIsObject: true)
    guard Set(object.keys).isSubset(of: ["server", "cursor"]) else {
      throw CodexMCPResourceError.invalidArguments
    }
    let server = try normalizedOptionalString(
      object["server"],
      keyPresent: object.keys.contains("server")
    )
    let cursor = try normalizedOptionalString(
      object["cursor"],
      keyPresent: object.keys.contains("cursor")
    )
    guard server != nil || cursor == nil else {
      throw CodexMCPResourceError.cursorRequiresServer
    }
    return ListArguments(server: server, cursor: cursor)
  }

  private static func readArguments(
    from json: String
  ) throws -> ReadArguments {
    let object = try argumentObject(from: json, emptyIsObject: false)
    guard Set(object.keys) == ["server", "uri"],
      let server = try normalizedRequiredString(object["server"]),
      let uri = try normalizedRequiredString(object["uri"])
    else {
      throw CodexMCPResourceError.invalidArguments
    }
    return ReadArguments(server: server, uri: uri)
  }

  private static func argumentObject(
    from json: String,
    emptyIsObject: Bool
  ) throws -> [String: Any] {
    let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty || trimmed == "null" {
      guard emptyIsObject else {
        throw CodexMCPResourceError.invalidArguments
      }
      return [:]
    }
    do {
      guard
        let object = try JSONSerialization.jsonObject(
          with: Data(trimmed.utf8)
        ) as? [String: Any]
      else {
        throw CodexMCPResourceError.invalidArguments
      }
      return object
    } catch let error as CodexMCPResourceError {
      throw error
    } catch {
      throw CodexMCPResourceError.invalidArguments
    }
  }

  private static func normalizedOptionalString(
    _ value: Any?,
    keyPresent: Bool
  ) throws -> String? {
    guard keyPresent, !(value is NSNull) else {
      return nil
    }
    guard let value = value as? String else {
      throw CodexMCPResourceError.invalidArguments
    }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  private static func normalizedRequiredString(
    _ value: Any?
  ) throws -> String? {
    guard let value = value as? String else {
      throw CodexMCPResourceError.invalidArguments
    }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  private static func resourcePayload(
    _ page: CodexMCPResourcePage
  ) throws -> String {
    var payload: [String: Any] = [
      "resources": try page.resources.map { entry in
        var resource = try dictionary(entry.resource)
        resource["server"] = entry.server
        return resource
      }
    ]
    payload["server"] = page.server
    payload["nextCursor"] = page.nextCursor
    return try jsonString(payload)
  }

  private static func resourceTemplatePayload(
    _ page: CodexMCPResourceTemplatePage
  ) throws -> String {
    var payload: [String: Any] = [
      "resourceTemplates": try page.resourceTemplates.map { entry in
        var template = try dictionary(entry.template)
        template["server"] = entry.server
        return template
      }
    ]
    payload["server"] = page.server
    payload["nextCursor"] = page.nextCursor
    return try jsonString(payload)
  }

  private static func readPayload(
    _ result: CodexMCPResourceReadResult
  ) throws -> String {
    try jsonString([
      "server": result.server,
      "uri": result.uri,
      "contents": try result.contents.map(dictionary),
    ])
  }

  private static func dictionary<T: Encodable>(
    _ value: T
  ) throws -> [String: Any] {
    do {
      let data = try JSONEncoder().encode(value)
      guard
        let object = try JSONSerialization.jsonObject(with: data)
          as? [String: Any]
      else {
        throw CodexMCPResourceError.invalidCatalog
      }
      return object
    } catch let error as CodexMCPResourceError {
      throw error
    } catch {
      throw CodexMCPResourceError.invalidCatalog
    }
  }

  private static func jsonString(
    _ object: [String: Any]
  ) throws -> String {
    do {
      let data = try JSONSerialization.data(
        withJSONObject: object,
        options: [.sortedKeys]
      )
      guard let json = String(data: data, encoding: .utf8) else {
        throw CodexMCPResourceError.invalidCatalog
      }
      return json
    } catch let error as CodexMCPResourceError {
      throw error
    } catch {
      throw CodexMCPResourceError.invalidCatalog
    }
  }

  private static func outputItemJSON(
    callID: String,
    payload: String
  ) throws -> String {
    do {
      let data = try JSONEncoder().encode(
        CodexPersistedTurnMCPResourceOutputItem(
          type: "function_call_output",
          callID: callID,
          output: payload
        )
      )
      guard let json = String(data: data, encoding: .utf8) else {
        throw CodexMCPResourceError.invalidCatalog
      }
      return json
    } catch let error as CodexMCPResourceError {
      throw error
    } catch {
      throw CodexMCPResourceError.invalidCatalog
    }
  }
}

private struct CodexPersistedTurnMCPResourceOutputItem: Encodable {
  let type: String
  let callID: String
  let output: String

  private enum CodingKeys: String, CodingKey {
    case type
    case callID = "call_id"
    case output
  }
}
