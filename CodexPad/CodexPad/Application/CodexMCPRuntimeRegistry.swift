#if SWIFT_PACKAGE
    import CodexPadDomain
    import CodexPadProtocolBridge
#endif
import Foundation

public struct CodexMCPToolProgress: Equatable, Sendable {
    public let threadID: CodexStoredThreadID
    public let turnID: String
    public let itemID: String
    public let message: String

    public init(
        threadID: CodexStoredThreadID,
        turnID: String,
        itemID: String,
        message: String
    ) {
        self.threadID = threadID
        self.turnID = turnID
        self.itemID = itemID
        self.message = message
    }
}

/// Mutable app-server-facing snapshot of configured MCP servers.
///
/// The released desktop app rebuilds this snapshot after configuration reload
/// and after OAuth credentials change. Inventory is preserved when a refresh
/// only changes authentication/configuration state, then replaced by the MCP
/// connection layer when a server finishes initialization.
@MainActor
public final class CodexMCPRuntimeRegistry:
    CodexDesktopMCPServerStatusListing,
    CodexDesktopMCPServerRefreshing,
    CodexDesktopMCPResourceReading,
    CodexDesktopMCPToolCalling
{
    public typealias ConfigurationProvider =
        () throws -> [String: CodexMCPServerConfiguration]
    public typealias CredentialProvider =
        (String) throws -> CodexMCPOAuthCredential?
    public typealias ToolCaller =
        (
            CodexStoredThreadID,
            String,
            CodexJSONValue?,
            CodexJSONValue?
        ) async throws -> CodexDesktopMCPToolCallResult
    public typealias ResourceReader =
        (String) async throws -> [CodexMCPResourceContent]
    public typealias ProgressToolCaller =
        CodexMCPConnectedServer.ProgressToolCaller
    public typealias ProgressSink =
        @Sendable (CodexMCPToolProgress) async -> Void

    private let configurationProvider: ConfigurationProvider
    private let credentialProvider: CredentialProvider
    private let connector: (any CodexMCPServerConnecting)?
    private var statuses: [String: CodexMCPServerStatus] = [:]
    private var resourceContents:
        [String: [String: [CodexMCPResourceContent]]] = [:]
    private var toolCallers: [String: ToolCaller] = [:]
    private var progressToolCallers: [String: ProgressToolCaller] = [:]
    private var resourceReaders: [String: ResourceReader] = [:]
    private var progressSink: ProgressSink?
    public private(set) var revision: UInt64 = 0

    public init(
        configurationProvider:
            @escaping ConfigurationProvider,
        credentialProvider:
            @escaping CredentialProvider,
        connector: (any CodexMCPServerConnecting)? = nil
    ) {
        self.configurationProvider = configurationProvider
        self.credentialProvider = credentialProvider
        self.connector = connector
    }

    public func refreshMCPServers() async throws {
        let configurations = try configurationProvider()
        var refreshed: [String: CodexMCPServerStatus] = [:]
        refreshed.reserveCapacity(configurations.count)

        for (name, configuration) in configurations {
            let previous = statuses[name]
            let credential = try credentialProvider(name)
            let authStatus = try authenticationStatus(
                name: name,
                configuration: configuration,
                credential: credential
            )
            var status = CodexMCPServerStatus(
                name: name,
                serverInfo: previous?.serverInfo,
                tools: previous?.tools ?? [:],
                resources: previous?.resources ?? [],
                resourceTemplates:
                    previous?.resourceTemplates ?? [],
                authStatus: authStatus,
                startupState: previous?.startupState,
                error: previous?.error,
                failureReason: previous?.failureReason
            )
            if let connector,
               configuration.enabled,
               shouldConnect(
                   configuration: configuration,
                   credential: credential
               )
            {
                do {
                    let connected = try await connector.connect(
                        name: name,
                        configuration: configuration,
                        credential: credential
                    )
                    status = CodexMCPServerStatus(
                        name: name,
                        serverInfo: connected.serverInfo,
                        tools: connected.tools,
                        resources: connected.resources,
                        resourceTemplates:
                            connected.resourceTemplates,
                        authStatus: authStatus,
                        startupState: .ready
                    )
                    resourceContents[name] = [:]
                    resourceReaders[name] =
                        connected.resourceReader
                    toolCallers[name] = connected.toolCaller
                    progressToolCallers[name] =
                        connected.progressToolCaller
                } catch {
                    status = CodexMCPServerStatus(
                        name: name,
                        authStatus: authStatus,
                        startupState: .failed,
                        error: CodexDiagnosticSanitization.publicErrorSummary(error),
                        failureReason: "connectionFailed"
                    )
                    resourceContents[name] = nil
                    resourceReaders[name] = nil
                    toolCallers[name] = nil
                    progressToolCallers[name] = nil
                }
            }
            refreshed[name] = status
        }

        statuses = refreshed
        resourceContents = resourceContents.filter {
            refreshed[$0.key] != nil
        }
        toolCallers = toolCallers.filter {
            refreshed[$0.key] != nil
        }
        progressToolCallers = progressToolCallers.filter {
            refreshed[$0.key] != nil
        }
        resourceReaders = resourceReaders.filter {
            refreshed[$0.key] != nil
        }
        revision &+= 1
    }

    public func listMCPServerStatuses(
        cursor: String?,
        limit: Int?,
        detail: CodexMCPServerStatusDetail
    ) throws -> CodexMCPServerStatusPage {
        let service = try CodexMCPServerStatusService(
            statuses: Array(statuses.values)
        )
        return try service.list(
            cursor: cursor,
            limit: limit,
            detail: detail
        )
    }

    public func updateInventory(
        for name: String,
        serverInfo: CodexJSONValue?,
        tools: [String: CodexJSONValue],
        resources: [CodexMCPResource],
        resourceTemplates: [CodexMCPResourceTemplate],
        contentsByURI:
            [String: [CodexMCPResourceContent]] = [:],
        resourceReader: ResourceReader? = nil,
        toolCaller: ToolCaller? = nil,
        progressToolCaller: ProgressToolCaller? = nil
    ) {
        guard let current = statuses[name] else { return }
        statuses[name] = CodexMCPServerStatus(
            name: name,
            serverInfo: serverInfo,
            tools: tools,
            resources: resources,
            resourceTemplates: resourceTemplates,
            authStatus: current.authStatus
        )
        resourceContents[name] = contentsByURI
        resourceReaders[name] = resourceReader
        if let toolCaller {
            toolCallers[name] = toolCaller
        } else {
            toolCallers[name] = nil
        }
        if let progressToolCaller {
            progressToolCallers[name] = progressToolCaller
        } else {
            progressToolCallers[name] = nil
        }
        revision &+= 1
    }

    public func configureProgressSink(
        _ sink: ProgressSink?
    ) {
        progressSink = sink
    }

    public func readMCPResource(
        threadID _: CodexStoredThreadID?,
        server: String,
        uri: String
    ) async throws -> [CodexMCPResourceContent] {
        guard let status = statuses[server] else {
            throw CodexMCPResourceError.unknownServer(server)
        }
        guard status.resources.contains(where: { $0.uri == uri }) else {
            throw CodexMCPResourceError.unknownResource(
                server: server,
                uri: uri
            )
        }
        if let resourceReader = resourceReaders[server] {
            return try await resourceReader(uri)
        }
        if let contents = resourceContents[server]?[uri] {
            return contents
        }
        throw CodexMCPResourceError.resourceUnavailable(
            server: server,
            uri: uri
        )
    }

    public func callMCPTool(
        threadID: CodexStoredThreadID,
        server: String,
        tool: String,
        arguments: CodexJSONValue?,
        meta: CodexJSONValue?
    ) async throws -> CodexDesktopMCPToolCallResult {
        try await callMCPTool(
            threadID: threadID,
            server: server,
            tool: tool,
            arguments: arguments,
            meta: meta,
            progress: nil
        )
    }

    public func callMCPTool(
        threadID: CodexStoredThreadID,
        server: String,
        tool: String,
        arguments: CodexJSONValue?,
        meta: CodexJSONValue?,
        progress: CodexMCPToolProgressHandler?
    ) async throws -> CodexDesktopMCPToolCallResult {
        guard let status = statuses[server] else {
            throw CodexMCPResourceError.unknownServer(server)
        }
        guard status.tools[tool] != nil else {
            throw CodexMCPResourceError.unknownTool(
                server: server,
                tool: tool
            )
        }
        if let progress,
           let caller = progressToolCallers[server]
        {
            return try await caller(
                threadID,
                tool,
                arguments,
                meta,
                progress
            )
        }
        guard let caller = toolCallers[server] else {
            throw CodexMCPResourceError.toolUnavailable(
                server: server,
                tool: tool
            )
        }
        return try await caller(threadID, tool, arguments, meta)
    }

    public func makeResourceCatalogSnapshot()
        throws -> CodexMCPResourceCatalogService
    {
        let servers = statuses.values.map {
            CodexMCPResourceServer(
                name: $0.name,
                resources: $0.resources,
                resourceTemplates: $0.resourceTemplates
            )
        }
        return try CodexMCPResourceCatalogService(servers: servers)
    }

    public func officialToolSearchSources()
        -> [CodexOfficialToolSearchSource]
    {
        statuses.values
            .filter { !$0.tools.isEmpty }
            .sorted { $0.name < $1.name }
            .map {
                CodexOfficialToolSearchSource(
                    name: "mcp__\($0.name)",
                    description:
                        "Tools provided by the \($0.name) MCP server."
                )
            }
    }

    public func makeToolSearchExecutor(
        threadID: CodexStoredThreadID
    ) -> CodexPersistedTurnToolSearchExecutor {
        let sources = statuses.values
            .filter { !$0.tools.isEmpty }
            .sorted { $0.name < $1.name }
            .map { status in
                CodexDeferredToolSearchSource(
                    namespace: "mcp__\(status.name)",
                    description:
                        "Tools provided by the \(status.name) MCP server.",
                    tools: status.tools.keys.sorted().map { toolName in
                        let tool = status.tools[toolName]
                            ?? .object([:])
                        let description: String
                        let parameters: CodexJSONValue
                        if case let .object(object) = tool {
                            if case let .string(value)? =
                                object["description"]
                            {
                                description = value
                            } else {
                                description =
                                    "Call \(toolName) on \(status.name)."
                            }
                            parameters =
                                object["inputSchema"]
                                ?? object["input_schema"]
                                ?? .object([
                                    "type": .string("object"),
                                    "properties": .object([:]),
                                ])
                        } else {
                            description =
                                "Call \(toolName) on \(status.name)."
                            parameters = .object([
                                "type": .string("object"),
                                "properties": .object([:]),
                            ])
                        }
                        return CodexDeferredToolSearchDefinition(
                            name: toolName,
                            description: description,
                            parameters: parameters,
                            invocation: {
                                [weak self] request, cancellation in
                                try cancellation.checkCancellation()
                                guard let self else {
                                    throw CancellationError()
                                }
                                let arguments =
                                    try Self.decodeArguments(
                                        request.arguments
                                    )
                                let result = try await self.callMCPTool(
                                    threadID: threadID,
                                    server: status.name,
                                    tool: toolName,
                                    arguments: arguments,
                                    meta: .object([
                                        "threadId":
                                            .string(threadID.rawValue),
                                    ]),
                                    progress: {
                                        [weak self] message in
                                        guard let self else {
                                            return
                                        }
                                        await self.emitProgress(
                                            CodexMCPToolProgress(
                                                threadID: request.threadID,
                                                turnID: request.turnID,
                                                itemID: request.callID,
                                                message: message
                                            )
                                        )
                                    }
                                )
                                return CodexPersistedTurnLocalToolOutput(
                                    itemJSON: try Self.toolOutputItemJSON(
                                        callID: request.callID,
                                        result: result
                                    )
                                )
                            }
                        )
                    }
                )
            }
        return CodexPersistedTurnToolSearchExecutor(
            sources: sources
        )
    }

    private func emitProgress(
        _ progress: CodexMCPToolProgress
    ) async {
        guard let progressSink else {
            return
        }
        await progressSink(progress)
    }

    private static func decodeArguments(
        _ json: String
    ) throws -> CodexJSONValue? {
        let trimmed = json.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !trimmed.isEmpty else {
            return nil
        }
        guard let data = trimmed.data(using: .utf8) else {
            throw CodexPersistedTurnToolSearchError.invalidArguments
        }
        return try JSONDecoder().decode(
            CodexJSONValue.self,
            from: data
        )
    }

    private static func toolOutputItemJSON(
        callID: String,
        result: CodexDesktopMCPToolCallResult
    ) throws -> String {
        var payload: [String: CodexJSONValue] = [
            "content": .array(result.content),
        ]
        if let structuredContent = result.structuredContent {
            payload["structuredContent"] = structuredContent
        }
        if let isError = result.isError {
            payload["isError"] = .bool(isError)
        }
        if let meta = result.meta {
            payload["_meta"] = meta
        }
        let outputData = try JSONEncoder().encode(
            CodexJSONValue.object(payload)
        )
        guard let output = String(
            data: outputData,
            encoding: .utf8
        ) else {
            throw CodexMCPResourceError.invalidCatalog
        }
        let item = CodexRuntimeMCPFunctionCallOutput(
            type: "function_call_output",
            callID: callID,
            output: output
        )
        let itemData = try JSONEncoder().encode(item)
        guard let itemJSON = String(
            data: itemData,
            encoding: .utf8
        ) else {
            throw CodexMCPResourceError.invalidCatalog
        }
        return itemJSON
    }

    private func authenticationStatus(
        name: String,
        configuration: CodexMCPServerConfiguration,
        credential: CodexMCPOAuthCredential?
    ) throws -> CodexMCPAuthStatus {
        switch configuration.transport {
        case .stdio:
            return .unsupported

        case let .streamableHTTP(
            _,
            bearerTokenEnvironmentVariable,
            _,
            _
        ):
            if bearerTokenEnvironmentVariable != nil {
                return .bearerToken
            }
            return credential == nil
                ? .notLoggedIn
                : .oauth
        }
    }

    private func shouldConnect(
        configuration: CodexMCPServerConfiguration,
        credential _: CodexMCPOAuthCredential?
    ) -> Bool {
        switch configuration.transport {
        case .stdio:
            return true
        case .streamableHTTP(
            _,
            _,
            _,
            _
        ):
            return true
        }
    }
}

private struct CodexRuntimeMCPFunctionCallOutput: Encodable {
    let type: String
    let callID: String
    let output: String

    private enum CodingKeys: String, CodingKey {
        case type
        case callID = "call_id"
        case output
    }
}
