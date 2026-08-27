import Foundation

#if SWIFT_PACKAGE
  import CodexPadDomain
#endif

public enum CodexMCPResourceError:
  Error,
  Equatable,
  Sendable
{
  case invalidCatalog
  case invalidPageSize
  case invalidArguments
  case unsupportedTool
  case cursorRequiresServer
  case invalidCursor
  case unknownServer(String)
  case unknownResource(server: String, uri: String)
  case resourceUnavailable(server: String, uri: String)
  case unknownTool(server: String, tool: String)
  case toolUnavailable(server: String, tool: String)
}

public struct CodexMCPResource:
  Codable,
  Equatable,
  Sendable
{
  public let annotations: CodexJSONValue?
  public let description: String?
  public let mimeType: String?
  public let name: String
  public let size: Int64?
  public let title: String?
  public let uri: String
  public let icons: [CodexJSONValue]?
  public let meta: CodexJSONValue?

  public init(
    uri: String,
    name: String,
    annotations: CodexJSONValue? = nil,
    description: String? = nil,
    mimeType: String? = nil,
    size: Int64? = nil,
    title: String? = nil,
    icons: [CodexJSONValue]? = nil,
    meta: CodexJSONValue? = nil
  ) {
    self.annotations = annotations
    self.description = description
    self.mimeType = mimeType
    self.name = name
    self.size = size
    self.title = title
    self.uri = uri
    self.icons = icons
    self.meta = meta
  }

  private enum CodingKeys: String, CodingKey {
    case annotations
    case description
    case mimeType
    case name
    case size
    case title
    case uri
    case icons
    case meta = "_meta"
  }
}

public struct CodexMCPResourceTemplate:
  Codable,
  Equatable,
  Sendable
{
  public let annotations: CodexJSONValue?
  public let uriTemplate: String
  public let name: String
  public let title: String?
  public let description: String?
  public let mimeType: String?
  public let icons: [CodexJSONValue]?
  public let meta: CodexJSONValue?

  public init(
    uriTemplate: String,
    name: String,
    annotations: CodexJSONValue? = nil,
    title: String? = nil,
    description: String? = nil,
    mimeType: String? = nil,
    icons: [CodexJSONValue]? = nil,
    meta: CodexJSONValue? = nil
  ) {
    self.annotations = annotations
    self.uriTemplate = uriTemplate
    self.name = name
    self.title = title
    self.description = description
    self.mimeType = mimeType
    self.icons = icons
    self.meta = meta
  }

  private enum CodingKeys: String, CodingKey {
    case annotations
    case uriTemplate
    case name
    case title
    case description
    case mimeType
    case icons
    case meta = "_meta"
  }
}

public enum CodexMCPResourceContent:
  Codable,
  Equatable,
  Sendable
{
  case text(
    uri: String,
    mimeType: String? = nil,
    text: String,
    meta: CodexJSONValue? = nil
  )
  case blob(
    uri: String,
    mimeType: String? = nil,
    blob: String,
    meta: CodexJSONValue? = nil
  )

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let uri = try container.decode(String.self, forKey: .uri)
    let mimeType = try container.decodeIfPresent(
      String.self,
      forKey: .mimeType
    )
    let meta = try container.decodeIfPresent(
      CodexJSONValue.self,
      forKey: .meta
    )
    if container.contains(.text) {
      self = .text(
        uri: uri,
        mimeType: mimeType,
        text: try container.decode(String.self, forKey: .text),
        meta: meta
      )
    } else {
      self = .blob(
        uri: uri,
        mimeType: mimeType,
        blob: try container.decode(String.self, forKey: .blob),
        meta: meta
      )
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .text(let uri, let mimeType, let text, let meta):
      try container.encode(uri, forKey: .uri)
      try container.encodeIfPresent(mimeType, forKey: .mimeType)
      try container.encode(text, forKey: .text)
      try container.encodeIfPresent(meta, forKey: .meta)
    case .blob(let uri, let mimeType, let blob, let meta):
      try container.encode(uri, forKey: .uri)
      try container.encodeIfPresent(mimeType, forKey: .mimeType)
      try container.encode(blob, forKey: .blob)
      try container.encodeIfPresent(meta, forKey: .meta)
    }
  }

  fileprivate var uri: String {
    switch self {
    case .text(let uri, _, _, _), .blob(let uri, _, _, _):
      return uri
    }
  }

  private enum CodingKeys: String, CodingKey {
    case uri
    case mimeType
    case text
    case blob
    case meta = "_meta"
  }
}

public struct CodexMCPResourceServer:
  Equatable,
  Sendable
{
  public let name: String
  public let resources: [CodexMCPResource]
  public let resourceTemplates: [CodexMCPResourceTemplate]
  public let contentsByURI: [String: [CodexMCPResourceContent]]

  public init(
    name: String,
    resources: [CodexMCPResource] = [],
    resourceTemplates: [CodexMCPResourceTemplate] = [],
    contentsByURI: [String: [CodexMCPResourceContent]] = [:]
  ) {
    self.name = name
    self.resources = resources
    self.resourceTemplates = resourceTemplates
    self.contentsByURI = contentsByURI
  }
}

public struct CodexMCPResourcePage:
  Equatable,
  Sendable
{
  public let server: String?
  public let resources: [(server: String, resource: CodexMCPResource)]
  public let nextCursor: String?

  public static func == (
    lhs: CodexMCPResourcePage,
    rhs: CodexMCPResourcePage
  ) -> Bool {
    lhs.server == rhs.server
      && lhs.resources.elementsEqual(rhs.resources) {
        $0.server == $1.server && $0.resource == $1.resource
      }
      && lhs.nextCursor == rhs.nextCursor
  }
}

public struct CodexMCPResourceTemplatePage:
  Equatable,
  Sendable
{
  public let server: String?
  public let resourceTemplates:
    [(server: String, template: CodexMCPResourceTemplate)]
  public let nextCursor: String?

  public static func == (
    lhs: CodexMCPResourceTemplatePage,
    rhs: CodexMCPResourceTemplatePage
  ) -> Bool {
    lhs.server == rhs.server
      && lhs.resourceTemplates.elementsEqual(rhs.resourceTemplates) {
        $0.server == $1.server && $0.template == $1.template
      }
      && lhs.nextCursor == rhs.nextCursor
  }
}

public struct CodexMCPResourceReadResult:
  Equatable,
  Sendable
{
  public let server: String
  public let uri: String
  public let contents: [CodexMCPResourceContent]
}

/// An immutable snapshot of resources reported by configured local MCP servers.
///
/// The service never manufactures entries: every list and read result comes
/// from the server snapshots supplied by the MCP connection layer.
public final class CodexMCPResourceCatalogService: @unchecked Sendable {
  private enum CursorKind: String, Codable {
    case resources
    case resourceTemplates
  }

  private struct Cursor: Codable {
    let version: Int
    let kind: CursorKind
    let server: String
    let offset: Int
  }

  private let serversByName: [String: CodexMCPResourceServer]
  private let pageSize: Int

  public init(
    servers: [CodexMCPResourceServer],
    pageSize: Int = 100
  ) throws {
    guard pageSize > 0 else {
      throw CodexMCPResourceError.invalidPageSize
    }

    var indexed: [String: CodexMCPResourceServer] = [:]
    for server in servers {
      guard Self.isCanonicalNonempty(server.name),
        indexed[server.name] == nil,
        Self.isValid(server)
      else {
        throw CodexMCPResourceError.invalidCatalog
      }
      indexed[server.name] = server
    }
    self.serversByName = indexed
    self.pageSize = pageSize
  }

  public func listResources(
    server: String?,
    cursor: String?
  ) throws -> CodexMCPResourcePage {
    guard let server else {
      guard cursor == nil else {
        throw CodexMCPResourceError.cursorRequiresServer
      }
      let resources = serversByName.keys.sorted().flatMap { serverName in
        // Iterating dictionary keys guarantees this lookup exists.
        serversByName[serverName]!.resources.map { (serverName, $0) }
      }
      return CodexMCPResourcePage(
        server: nil,
        resources: resources,
        nextCursor: nil
      )
    }

    let registered = try registeredServer(named: server)
    let offset = try offset(
      cursor: cursor,
      kind: .resources,
      server: server,
      count: registered.resources.count
    )
    let end = min(offset + pageSize, registered.resources.count)
    let resources = registered.resources[offset..<end].map { (server, $0) }
    let nextCursor = end < registered.resources.count
      ? try encodeCursor(kind: .resources, server: server, offset: end)
      : nil
    return CodexMCPResourcePage(
      server: server,
      resources: resources,
      nextCursor: nextCursor
    )
  }

  public func listResourceTemplates(
    server: String?,
    cursor: String?
  ) throws -> CodexMCPResourceTemplatePage {
    guard let server else {
      guard cursor == nil else {
        throw CodexMCPResourceError.cursorRequiresServer
      }
      let templates = serversByName.keys.sorted().flatMap { serverName in
        // Iterating dictionary keys guarantees this lookup exists.
        serversByName[serverName]!.resourceTemplates.map {
          (serverName, $0)
        }
      }
      return CodexMCPResourceTemplatePage(
        server: nil,
        resourceTemplates: templates,
        nextCursor: nil
      )
    }

    let registered = try registeredServer(named: server)
    let offset = try offset(
      cursor: cursor,
      kind: .resourceTemplates,
      server: server,
      count: registered.resourceTemplates.count
    )
    let end = min(offset + pageSize, registered.resourceTemplates.count)
    let templates = registered.resourceTemplates[offset..<end]
      .map { (server, $0) }
    let nextCursor = end < registered.resourceTemplates.count
      ? try encodeCursor(
        kind: .resourceTemplates,
        server: server,
        offset: end
      )
      : nil
    return CodexMCPResourceTemplatePage(
      server: server,
      resourceTemplates: templates,
      nextCursor: nextCursor
    )
  }

  public func readResource(
    server: String,
    uri: String
  ) throws -> CodexMCPResourceReadResult {
    let registered = try registeredServer(named: server)
    guard registered.resources.contains(where: { $0.uri == uri }) else {
      throw CodexMCPResourceError.unknownResource(
        server: server,
        uri: uri
      )
    }
    guard let contents = registered.contentsByURI[uri] else {
      throw CodexMCPResourceError.resourceUnavailable(
        server: server,
        uri: uri
      )
    }
    return CodexMCPResourceReadResult(
      server: server,
      uri: uri,
      contents: contents
    )
  }

  private func registeredServer(
    named name: String
  ) throws -> CodexMCPResourceServer {
    guard let server = serversByName[name] else {
      throw CodexMCPResourceError.unknownServer(name)
    }
    return server
  }

  private func offset(
    cursor: String?,
    kind: CursorKind,
    server: String,
    count: Int
  ) throws -> Int {
    guard let cursor else {
      return 0
    }
    guard
      let data = Data(base64Encoded: cursor),
      let decoded = try? JSONDecoder().decode(Cursor.self, from: data),
      decoded.version == 1,
      decoded.kind == kind,
      decoded.server == server,
      decoded.offset > 0,
      decoded.offset < count
    else {
      throw CodexMCPResourceError.invalidCursor
    }
    return decoded.offset
  }

  private func encodeCursor(
    kind: CursorKind,
    server: String,
    offset: Int
  ) throws -> String {
    do {
      return try JSONEncoder().encode(
        Cursor(
          version: 1,
          kind: kind,
          server: server,
          offset: offset
        )
      ).base64EncodedString()
    } catch {
      throw CodexMCPResourceError.invalidCursor
    }
  }

  private static func isValid(
    _ server: CodexMCPResourceServer
  ) -> Bool {
    var resourceURIs = Set<String>()
    for resource in server.resources {
      guard isCanonicalNonempty(resource.uri),
        isCanonicalNonempty(resource.name),
        resourceURIs.insert(resource.uri).inserted
      else {
        return false
      }
    }

    var templateURIs = Set<String>()
    for template in server.resourceTemplates {
      guard isCanonicalNonempty(template.uriTemplate),
        isCanonicalNonempty(template.name),
        templateURIs.insert(template.uriTemplate).inserted
      else {
        return false
      }
    }

    for (uri, contents) in server.contentsByURI {
      guard resourceURIs.contains(uri),
        contents.allSatisfy({ $0.uri == uri })
      else {
        return false
      }
    }
    return true
  }

  private static func isCanonicalNonempty(_ value: String) -> Bool {
    let trimmed = value.trimmingCharacters(
      in: .whitespacesAndNewlines
    )
    return !trimmed.isEmpty && trimmed == value
  }
}
