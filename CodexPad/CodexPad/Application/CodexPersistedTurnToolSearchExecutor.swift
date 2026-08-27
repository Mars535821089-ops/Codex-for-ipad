import Foundation

#if SWIFT_PACKAGE
  import CodexPadDomain
#endif

/// The callback used by a deferred tool after the model has discovered it.
public typealias CodexDeferredToolInvocation =
  @MainActor (
    CodexPersistedTurnToolRequest,
    CodexTurnCancellation
  ) async throws -> CodexPersistedTurnLocalToolOutput

/// A function exposed by a deferred tool-search source.
public struct CodexDeferredToolSearchDefinition {
  public let name: String
  public let description: String
  public let parameters: CodexJSONValue
  public let searchText: String?
  public let namespace: String?
  public let invocation: CodexDeferredToolInvocation?

  public init(
    name: String,
    description: String,
    parameters: CodexJSONValue,
    searchText: String? = nil,
    namespace: String? = nil,
    invocation: CodexDeferredToolInvocation? = nil
  ) {
    self.name = name
    self.description = description
    self.parameters = parameters
    self.searchText = searchText
    self.namespace = namespace
    self.invocation = invocation
  }
}

/// A deferred source. A source namespace is applied to definitions that do not
/// provide an explicit namespace, matching the Responses API namespace shape.
public struct CodexDeferredToolSearchSource {
  public let namespace: String?
  public let description: String
  public let tools: [CodexDeferredToolSearchDefinition]

  public init(
    namespace: String?,
    description: String,
    tools: [CodexDeferredToolSearchDefinition]
  ) {
    self.namespace = namespace
    self.description = description
    self.tools = tools
  }
}

/// A narrow routing seam used by the persisted-turn router for names learned
/// from a previous `tool_search` response.
@MainActor
public protocol CodexPersistedTurnDynamicToolExecutor:
  CodexPersistedTurnToolExecutor
{
  func canExecute(toolName: String) -> Bool
  func canExecute(toolName: String, itemJSON: String) -> Bool
}

public enum CodexPersistedTurnToolSearchError:
  Error,
  Equatable,
  Sendable
{
  case invalidArguments
  case emptyQuery
  case invalidLimit
  case toolNotActivated
  case invocationUnavailable
}

/// Local implementation of the official deferred-tool search handler.
///
/// The official client uses an English BM25 index and returns at most eight
/// loadable specs by default. This executor keeps the same boundary semantics
/// while retaining the selected definitions for the next persisted-turn round.
@MainActor
public final class CodexPersistedTurnToolSearchExecutor:
  CodexPersistedTurnDynamicToolExecutor
{
  public static let defaultLimit = 8

  public private(set) var activatedToolNames: [String] = []

  private struct IndexedTool {
    let definition: CodexDeferredToolSearchDefinition
    let namespace: String?
    let namespaceDescription: String
    let canonicalName: String
    let searchText: String
    let terms: [String: Int]
    let documentLength: Int
  }

  private struct BM25Index {
    let documents: [IndexedTool]
    let documentFrequency: [String: Int]
    let averageDocumentLength: Double

    func search(query: String, limit: Int) -> [IndexedTool] {
      guard !documents.isEmpty else {
        return []
      }
      let queryTerms = Set(Self.tokenize(query))
      guard !queryTerms.isEmpty else {
        return []
      }

      let count = Double(documents.count)
      let averageLength = max(averageDocumentLength, 1)
      let scored = documents.enumerated().compactMap { index, document
        -> (Int, Double, IndexedTool)? in
        var score = 0.0
        for term in queryTerms {
          guard let termFrequency = document.terms[term],
                let frequency = documentFrequency[term]
          else {
            continue
          }
          let inverseDocumentFrequency = log(
            1 + (count - Double(frequency) + 0.5)
              / (Double(frequency) + 0.5)
          )
          let tf = Double(termFrequency)
          let length = Double(document.documentLength)
          let normalization = 1.2
            * (1 - 0.75 + 0.75 * length / averageLength)
          score += inverseDocumentFrequency * (tf * 2.2) / (tf + normalization)
        }
        return score > 0 ? (index, score, document) : nil
      }

      return scored
        .sorted { lhs, rhs in
          if lhs.1 == rhs.1 {
            return lhs.0 < rhs.0
          }
          return lhs.1 > rhs.1
        }
        .prefix(limit)
        .map(\.2)
    }

    static func tokenize(_ text: String) -> [String] {
      var tokens: [String] = []
      var current = ""
      for scalar in text.unicodeScalars {
        if CharacterSet.alphanumerics.contains(scalar) {
          current += String(scalar).lowercased()
        } else if !current.isEmpty {
          tokens.append(current)
          current.removeAll(keepingCapacity: true)
        }
      }
      if !current.isEmpty {
        tokens.append(current)
      }
      return tokens
    }
  }

  private struct SearchArguments: Decodable {
    let query: String?
    let limit: Int?
  }

  private struct FunctionSpec: Encodable {
    let type = "function"
    let name: String
    let description: String
    let strict = false
    let deferLoading = true
    let parameters: CodexJSONValue

    enum CodingKeys: String, CodingKey {
      case type
      case name
      case description
      case strict
      case deferLoading = "defer_loading"
      case parameters
    }
  }

  private struct NamespaceSpec: Encodable {
    let type = "namespace"
    let name: String
    let description: String
    var tools: [FunctionSpec]
  }

  private enum OutputSpec: Encodable {
    case function(FunctionSpec)
    case namespace(NamespaceSpec)

    func encode(to encoder: Encoder) throws {
      switch self {
      case let .function(spec):
        try spec.encode(to: encoder)
      case let .namespace(spec):
        try spec.encode(to: encoder)
      }
    }
  }

  private struct ToolSearchOutput: Encodable {
    let type = "tool_search_output"
    let callID: String
    let status = "completed"
    let execution = "client"
    let tools: [CodexJSONValue]

    enum CodingKeys: String, CodingKey {
      case type
      case callID = "call_id"
      case status
      case execution
      case tools
    }
  }

  private let index: BM25Index
  private let toolsByCanonicalName: [String: IndexedTool]
  private let uniqueToolsByPlainName: [String: IndexedTool]
  private var activatedCanonicalNames: Set<String> = []

  public init(sources: [CodexDeferredToolSearchSource]) {
    var indexed: [IndexedTool] = []
    for source in sources {
      for definition in source.tools {
        let namespace = definition.namespace ?? source.namespace
        let canonicalName = (namespace ?? "") + definition.name
        let searchText = definition.searchText
          ?? Self.defaultSearchText(for: definition, namespace: namespace)
        let tokens = BM25Index.tokenize(searchText)
        var termCounts: [String: Int] = [:]
        for token in tokens {
          termCounts[token, default: 0] += 1
        }
        indexed.append(
          IndexedTool(
            definition: definition,
            namespace: namespace,
            namespaceDescription: source.description.trimmingCharacters(
              in: .whitespacesAndNewlines
            ).isEmpty
              ? "Tools in \(namespace ?? "default") namespace."
              : source.description,
            canonicalName: canonicalName,
            searchText: searchText,
            terms: termCounts,
            documentLength: max(tokens.count, 1)
          )
        )
      }
    }

    var documentFrequency: [String: Int] = [:]
    for document in indexed {
      for term in document.terms.keys {
        documentFrequency[term, default: 0] += 1
      }
    }
    let totalLength = indexed.reduce(0) { $0 + $1.documentLength }
    let averageLength = indexed.isEmpty
      ? 0
      : Double(totalLength) / Double(indexed.count)
    self.index = BM25Index(
      documents: indexed,
      documentFrequency: documentFrequency,
      averageDocumentLength: averageLength
    )

    var canonical: [String: IndexedTool] = [:]
    var plainCandidates: [String: [IndexedTool]] = [:]
    for tool in indexed {
      canonical[tool.canonicalName] = tool
      plainCandidates[tool.definition.name, default: []].append(tool)
    }
    self.toolsByCanonicalName = canonical
    self.uniqueToolsByPlainName = plainCandidates.reduce(into: [:]) { result, entry in
      if entry.value.count == 1, let tool = entry.value.first {
        result[entry.key] = tool
      }
    }
  }

  public func canExecute(toolName: String) -> Bool {
    guard let tool = resolveActiveTool(toolName: toolName) else {
      return false
    }
    return activatedCanonicalNames.contains(tool.canonicalName)
  }

  public func canExecute(toolName: String, itemJSON: String) -> Bool {
    guard let tool = resolveActiveTool(
      toolName: toolName,
      itemJSON: itemJSON
    ) else {
      return false
    }
    return activatedCanonicalNames.contains(tool.canonicalName)
  }

  public func execute(
    _ request: CodexPersistedTurnToolRequest,
    cancellation: CodexTurnCancellation
  ) async throws -> CodexPersistedTurnLocalToolOutput {
    try Task.checkCancellation()
    try cancellation.checkCancellation()

    if request.name == "tool_search" {
      let arguments = try parseArguments(request.arguments)
      let matches = index.search(
        query: arguments.query,
        limit: arguments.limit
      )
      for match in matches where !activatedCanonicalNames.contains(match.canonicalName) {
        activatedCanonicalNames.insert(match.canonicalName)
        activatedToolNames.append(match.canonicalName)
      }
      return try makeSearchOutput(callID: request.callID, matches: matches)
    }

    guard let tool = resolveActiveTool(
      toolName: request.name,
      itemJSON: request.itemJSON
    ), activatedCanonicalNames.contains(tool.canonicalName)
    else {
      throw CodexPersistedTurnToolSearchError.toolNotActivated
    }
    guard let invocation = tool.definition.invocation else {
      throw CodexPersistedTurnToolSearchError.invocationUnavailable
    }
    let output = try await invocation(request, cancellation)
    try Task.checkCancellation()
    try cancellation.checkCancellation()
    return output
  }

  private func parseArguments(
    _ rawArguments: String
  ) throws -> (query: String, limit: Int) {
    guard let data = rawArguments.data(using: .utf8) else {
      throw CodexPersistedTurnToolSearchError.invalidArguments
    }
    guard let object = try? JSONSerialization.jsonObject(with: data)
      as? [String: Any],
      object.keys.allSatisfy({ $0 == "query" || $0 == "limit" })
    else {
      throw CodexPersistedTurnToolSearchError.invalidArguments
    }
    guard let decoded = try? JSONDecoder().decode(
      SearchArguments.self,
      from: data
    ), let query = decoded.query
    else {
      throw CodexPersistedTurnToolSearchError.invalidArguments
    }
    let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedQuery.isEmpty else {
      throw CodexPersistedTurnToolSearchError.emptyQuery
    }
    let limit = decoded.limit ?? Self.defaultLimit
    guard limit > 0 else {
      throw CodexPersistedTurnToolSearchError.invalidLimit
    }
    return (trimmedQuery, limit)
  }

  private func makeSearchOutput(
    callID: String,
    matches: [IndexedTool]
  ) throws -> CodexPersistedTurnLocalToolOutput {
    var specs: [OutputSpec] = []
    var namespaceIndices: [String: Int] = [:]
    for match in matches {
      if let namespace = match.namespace {
        let function = FunctionSpec(
          name: match.definition.name,
          description: match.definition.description,
          parameters: match.definition.parameters
        )
        if let index = namespaceIndices[namespace],
           case .namespace(var namespaceSpec) = specs[index]
        {
          namespaceSpec.tools.append(function)
          specs[index] = .namespace(namespaceSpec)
        } else {
          namespaceIndices[namespace] = specs.count
          specs.append(
            .namespace(
              NamespaceSpec(
                name: namespace,
                description: match.namespaceDescription,
                tools: [function]
              )
            )
          )
        }
      } else {
        specs.append(
          .function(
            FunctionSpec(
              name: match.definition.name,
              description: match.definition.description,
              parameters: match.definition.parameters
            )
          )
        )
      }
    }
    let values = try specs.map { spec in
      let data = try JSONEncoder().encode(spec)
      return try JSONDecoder().decode(CodexJSONValue.self, from: data)
    }
    let output = ToolSearchOutput(callID: callID, tools: values)
    let data = try JSONEncoder().encode(output)
    guard let itemJSON = String(data: data, encoding: .utf8) else {
      throw CodexPersistedTurnToolSearchError.invalidArguments
    }
    return CodexPersistedTurnLocalToolOutput(itemJSON: itemJSON)
  }

  private func resolveActiveTool(
    toolName: String,
    itemJSON: String? = nil
  ) -> IndexedTool? {
    if let direct = toolsByCanonicalName[toolName] {
      return direct
    }
    if let plain = uniqueToolsByPlainName[toolName] {
      return plain
    }
    if let itemJSON,
       let data = itemJSON.data(using: .utf8),
       let object = try? JSONSerialization.jsonObject(with: data)
         as? [String: Any],
       let namespace = object["namespace"] as? String,
       let namespaced = toolsByCanonicalName[namespace + toolName]
    {
      return namespaced
    }
    return nil
  }

  private static func defaultSearchText(
    for definition: CodexDeferredToolSearchDefinition,
    namespace: String?
  ) -> String {
    var parts = [
      namespace ?? "",
      definition.name,
      definition.name.replacingOccurrences(of: "_", with: " "),
      definition.description,
    ]
    appendSchemaSearchText(definition.parameters, to: &parts)
    return parts.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
      .joined(separator: " ")
  }

  private static func appendSchemaSearchText(
    _ value: CodexJSONValue,
    to parts: inout [String]
  ) {
    switch value {
    case let .object(object):
      for (key, child) in object {
        parts.append(key)
        appendSchemaSearchText(child, to: &parts)
      }
    case let .array(array):
      for child in array {
        appendSchemaSearchText(child, to: &parts)
      }
    case let .string(string):
      parts.append(string)
    case .null, .bool, .integer, .number:
      break
    }
  }
}
