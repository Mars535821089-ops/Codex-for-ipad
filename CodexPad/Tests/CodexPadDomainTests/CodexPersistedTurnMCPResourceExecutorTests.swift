import CodexPadApplication
import CodexPadDomain
import Foundation
import Testing

@MainActor
@Test
func persistedTurnMCPResourcesListsAnEmptyCatalogWithoutInventingEntries()
  async throws
{
  let executor = CodexPersistedTurnMCPResourceExecutor(
    service: try CodexMCPResourceCatalogService(servers: [])
  )

  let output = try await executor.execute(
    mcpResourceRequest(name: "list_mcp_resources", arguments: "{}"),
    cancellation: CodexTurnCancellation()
  )
  let (item, payload) = try mcpResourceOutput(output)

  #expect(item["type"] as? String == "function_call_output")
  #expect(item["call_id"] as? String == "call/mcp-resource")
  #expect((payload["resources"] as? [Any])?.isEmpty == true)
  #expect(payload["server"] == nil)
  #expect(payload["nextCursor"] == nil)
}

@MainActor
@Test
func persistedTurnMCPResourcesPagesOneExactServerWithOpaqueCursor()
  async throws
{
  let service = try CodexMCPResourceCatalogService(
    servers: [
      CodexMCPResourceServer(
        name: "docs",
        resources: [
          CodexMCPResource(
            uri: "docs://alpha",
            name: "alpha",
            mimeType: "text/markdown"
          ),
          CodexMCPResource(uri: "docs://beta", name: "beta"),
        ]
      )
    ],
    pageSize: 1
  )
  let executor = CodexPersistedTurnMCPResourceExecutor(service: service)

  let first = try await executor.execute(
    mcpResourceRequest(
      name: "list_mcp_resources",
      arguments: #"{"server":" docs "}"#
    ),
    cancellation: CodexTurnCancellation()
  )
  let (_, firstPayload) = try mcpResourceOutput(first)
  let firstResources = try #require(firstPayload["resources"] as? [[String: Any]])
  let cursor = try #require(firstPayload["nextCursor"] as? String)

  #expect(firstPayload["server"] as? String == "docs")
  #expect(firstResources.count == 1)
  #expect(firstResources[0]["server"] as? String == "docs")
  #expect(firstResources[0]["uri"] as? String == "docs://alpha")
  #expect(firstResources[0]["mimeType"] as? String == "text/markdown")

  let second = try await executor.execute(
    mcpResourceRequest(
      name: "list_mcp_resources",
      arguments: #"{"server":"docs","cursor":"\#(cursor)"}"#
    ),
    cancellation: CodexTurnCancellation()
  )
  let (_, secondPayload) = try mcpResourceOutput(second)
  let secondResources = try #require(secondPayload["resources"] as? [[String: Any]])

  #expect(secondResources.map { $0["uri"] as? String } == ["docs://beta"])
  #expect(secondPayload["nextCursor"] == nil)
}

@MainActor
@Test
func persistedTurnMCPResourcesListsAllServersInStableOrder()
  async throws
{
  let executor = CodexPersistedTurnMCPResourceExecutor(
    service: try CodexMCPResourceCatalogService(
      servers: [
        CodexMCPResourceServer(
          name: "zeta",
          resources: [
            CodexMCPResource(uri: "zeta://one", name: "zeta one")
          ]
        ),
        CodexMCPResourceServer(
          name: "alpha",
          resources: [
            CodexMCPResource(uri: "alpha://one", name: "alpha one"),
            CodexMCPResource(uri: "alpha://two", name: "alpha two"),
          ]
        ),
      ],
      pageSize: 1
    )
  )

  let output = try await executor.execute(
    mcpResourceRequest(name: "list_mcp_resources", arguments: ""),
    cancellation: CodexTurnCancellation()
  )
  let (_, payload) = try mcpResourceOutput(output)
  let resources = try #require(payload["resources"] as? [[String: Any]])

  #expect(
    resources.map { $0["uri"] as? String }
      == ["alpha://one", "alpha://two", "zeta://one"]
  )
  #expect(payload["server"] == nil)
  #expect(payload["nextCursor"] == nil)
}

@MainActor
@Test
func persistedTurnMCPResourceTemplatesPreserveOfficialFieldNames()
  async throws
{
  let executor = CodexPersistedTurnMCPResourceExecutor(
    service: try CodexMCPResourceCatalogService(
      servers: [
        CodexMCPResourceServer(
          name: "docs",
          resourceTemplates: [
            CodexMCPResourceTemplate(
              uriTemplate: "docs://pages/{id}",
              name: "page",
              title: "Page",
              description: "A page by ID",
              mimeType: "text/markdown"
            )
          ]
        )
      ]
    )
  )

  let output = try await executor.execute(
    mcpResourceRequest(
      name: "list_mcp_resource_templates",
      arguments: #"{"server":"docs"}"#
    ),
    cancellation: CodexTurnCancellation()
  )
  let (_, payload) = try mcpResourceOutput(output)
  let templates = try #require(
    payload["resourceTemplates"] as? [[String: Any]]
  )

  #expect(payload["server"] as? String == "docs")
  #expect(templates.count == 1)
  #expect(templates[0]["server"] as? String == "docs")
  #expect(templates[0]["uriTemplate"] as? String == "docs://pages/{id}")
  #expect(templates[0]["mimeType"] as? String == "text/markdown")
}

@MainActor
@Test
func persistedTurnMCPResourceReadsOnlyCataloguedURIWithTextAndBlobContents()
  async throws
{
  let uri = "docs://asset"
  let executor = CodexPersistedTurnMCPResourceExecutor(
    service: try CodexMCPResourceCatalogService(
      servers: [
        CodexMCPResourceServer(
          name: "docs",
          resources: [CodexMCPResource(uri: uri, name: "asset")],
          contentsByURI: [
            uri: [
              .text(uri: uri, mimeType: "text/plain", text: "hello"),
              .blob(uri: uri, mimeType: "image/png", blob: "aGVsbG8="),
            ]
          ]
        )
      ]
    )
  )

  let output = try await executor.execute(
    mcpResourceRequest(
      name: "read_mcp_resource",
      arguments: #"{"server":" docs ","uri":" docs://asset "}"#
    ),
    cancellation: CodexTurnCancellation()
  )
  let (_, payload) = try mcpResourceOutput(output)
  let contents = try #require(payload["contents"] as? [[String: Any]])

  #expect(payload["server"] as? String == "docs")
  #expect(payload["uri"] as? String == uri)
  #expect(contents.count == 2)
  #expect(contents[0]["text"] as? String == "hello")
  #expect(contents[0]["mimeType"] as? String == "text/plain")
  #expect(contents[1]["blob"] as? String == "aGVsbG8=")
}

@MainActor
@Test
func persistedTurnMCPResourcesRejectsInvalidServerURIAndCursorScope()
  async throws
{
  let service = try CodexMCPResourceCatalogService(
    servers: [
      CodexMCPResourceServer(
        name: "alpha",
        resources: [
          CodexMCPResource(uri: "alpha://one", name: "one"),
          CodexMCPResource(uri: "alpha://two", name: "two"),
        ],
        resourceTemplates: [
          CodexMCPResourceTemplate(
            uriTemplate: "alpha://{id}",
            name: "alpha"
          )
        ],
        contentsByURI: [
          "alpha://one": [.text(uri: "alpha://one", text: "one")]
        ]
      ),
      CodexMCPResourceServer(name: "beta"),
    ],
    pageSize: 1
  )
  let executor = CodexPersistedTurnMCPResourceExecutor(service: service)

  await #expect(throws: CodexMCPResourceError.cursorRequiresServer) {
    _ = try await executor.execute(
      mcpResourceRequest(
        name: "list_mcp_resources",
        arguments: #"{"cursor":"opaque"}"#
      ),
      cancellation: CodexTurnCancellation()
    )
  }
  await #expect(throws: CodexMCPResourceError.unknownServer("missing")) {
    _ = try await executor.execute(
      mcpResourceRequest(
        name: "list_mcp_resources",
        arguments: #"{"server":"missing"}"#
      ),
      cancellation: CodexTurnCancellation()
    )
  }
  await #expect(
    throws: CodexMCPResourceError.unknownResource(
      server: "alpha",
      uri: "alpha://missing"
    )
  ) {
    _ = try await executor.execute(
      mcpResourceRequest(
        name: "read_mcp_resource",
        arguments: #"{"server":"alpha","uri":"alpha://missing"}"#
      ),
      cancellation: CodexTurnCancellation()
    )
  }

  let first = try await executor.execute(
    mcpResourceRequest(
      name: "list_mcp_resources",
      arguments: #"{"server":"alpha"}"#
    ),
    cancellation: CodexTurnCancellation()
  )
  let (_, payload) = try mcpResourceOutput(first)
  let resourceCursor = try #require(payload["nextCursor"] as? String)

  await #expect(throws: CodexMCPResourceError.invalidCursor) {
    _ = try await executor.execute(
      mcpResourceRequest(
        name: "list_mcp_resource_templates",
        arguments: #"{"server":"alpha","cursor":"\#(resourceCursor)"}"#
      ),
      cancellation: CodexTurnCancellation()
    )
  }
  await #expect(throws: CodexMCPResourceError.invalidCursor) {
    _ = try await executor.execute(
      mcpResourceRequest(
        name: "list_mcp_resources",
        arguments: #"{"server":"beta","cursor":"\#(resourceCursor)"}"#
      ),
      cancellation: CodexTurnCancellation()
    )
  }
}

@MainActor
@Test
func persistedTurnMCPResourcesRejectsMalformedOrUnsupportedCalls()
  async throws
{
  let executor = CodexPersistedTurnMCPResourceExecutor(
    service: try CodexMCPResourceCatalogService(servers: [])
  )

  for (name, arguments) in [
    ("list_mcp_resources", #"{"server":1}"#),
    ("list_mcp_resources", #"{"extra":true}"#),
    ("read_mcp_resource", #"{"server":"","uri":"docs://one"}"#),
    ("read_mcp_resource", #"{"server":"docs"}"#),
  ] {
    await #expect(throws: CodexMCPResourceError.invalidArguments) {
      _ = try await executor.execute(
        mcpResourceRequest(name: name, arguments: arguments),
        cancellation: CodexTurnCancellation()
      )
    }
  }

  await #expect(throws: CodexMCPResourceError.unsupportedTool) {
    _ = try await executor.execute(
      mcpResourceRequest(name: "call_mcp_tool", arguments: "{}"),
      cancellation: CodexTurnCancellation()
    )
  }
}

private func mcpResourceRequest(
  name: String,
  arguments: String
) -> CodexPersistedTurnToolRequest {
  CodexPersistedTurnToolRequest(
    threadID: CodexStoredThreadID("thread/mcp-resource"),
    turnID: "turn/mcp-resource",
    roundIndex: 1,
    name: name,
    arguments: arguments,
    callID: "call/mcp-resource",
    itemJSON: #"{"type":"function_call"}"#
  )
}

private func mcpResourceOutput(
  _ output: CodexPersistedTurnLocalToolOutput
) throws -> ([String: Any], [String: Any]) {
  let item = try #require(
    JSONSerialization.jsonObject(with: Data(output.itemJSON.utf8))
      as? [String: Any]
  )
  let payloadJSON = try #require(item["output"] as? String)
  let payload = try #require(
    JSONSerialization.jsonObject(with: Data(payloadJSON.utf8))
      as? [String: Any]
  )
  return (item, payload)
}
