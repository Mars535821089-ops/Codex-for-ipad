#if SWIFT_PACKAGE
    import CodexPadDomain
#endif
import Foundation

public enum CodexMCPStreamableHTTPError:
    Error,
    Equatable,
    Sendable
{
    case unsupportedTransport
    case invalidURL
    case missingBearerToken(String)
    case invalidResponse
    case httpStatus(Int)
    case rpc(code: Int64, message: String)
    case paginationLoop
}

public protocol CodexMCPStreamableHTTPTransport: Sendable {
    func data(
        for request: URLRequest
    ) async throws -> (Data, HTTPURLResponse)

    func streamingData(
        for request: URLRequest,
        receiveEvent:
            @escaping @Sendable (Data) async throws -> Void
    ) async throws -> (Data, HTTPURLResponse)
}

public extension CodexMCPStreamableHTTPTransport {
    func streamingData(
        for request: URLRequest,
        receiveEvent:
            @escaping @Sendable (Data) async throws -> Void
    ) async throws -> (Data, HTTPURLResponse) {
        let response = try await data(for: request)
        try await receiveEvent(response.0)
        return response
    }
}

public typealias CodexMCPToolProgressHandler =
    @Sendable (String) async -> Void

public struct CodexMCPStreamableURLSessionTransport:
    CodexMCPStreamableHTTPTransport,
    Sendable
{
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func data(
        for request: URLRequest
    ) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw CodexMCPStreamableHTTPError.invalidResponse
        }
        return (data, response)
    }

    public func streamingData(
        for request: URLRequest,
        receiveEvent:
            @escaping @Sendable (Data) async throws -> Void
    ) async throws -> (Data, HTTPURLResponse) {
        let (bytes, rawResponse) = try await session.bytes(
            for: request
        )
        guard let response = rawResponse as? HTTPURLResponse else {
            throw CodexMCPStreamableHTTPError.invalidResponse
        }
        let shouldDeliverEvents =
            (200..<300).contains(response.statusCode)
        let contentType = response.value(
            forHTTPHeaderField: "Content-Type"
        )?.lowercased() ?? ""
        guard contentType.contains("text/event-stream") else {
            var data = Data()
            for try await byte in bytes {
                data.append(byte)
            }
            if shouldDeliverEvents, !data.isEmpty {
                try await receiveEvent(data)
            }
            return (data, response)
        }

        var data = Data()
        var eventLines: [String] = []
        for try await line in bytes.lines {
            data.append(contentsOf: line.utf8)
            data.append(0x0A)
            if line.isEmpty {
                if shouldDeliverEvents,
                   let payload = Self.ssePayload(
                       eventLines
                   )
                {
                    try await receiveEvent(payload)
                }
                eventLines.removeAll(keepingCapacity: true)
            } else {
                eventLines.append(line)
            }
        }
        if !eventLines.isEmpty,
           shouldDeliverEvents,
           let payload = Self.ssePayload(eventLines)
        {
            try await receiveEvent(payload)
        }
        return (data, response)
    }

    private static func ssePayload(
        _ lines: [String]
    ) -> Data? {
        let payload = lines.compactMap { line -> String? in
            guard line.hasPrefix("data:") else {
                return nil
            }
            return String(line.dropFirst(5))
                .trimmingCharacters(in: .whitespaces)
        }
        .joined(separator: "\n")
        guard !payload.isEmpty else {
            return nil
        }
        return Data(payload.utf8)
    }
}

public struct CodexMCPConnectedServer: @unchecked Sendable {
    public typealias ResourceReader =
        @Sendable (String) async throws -> [CodexMCPResourceContent]
    public typealias ToolCaller =
        @Sendable (
            CodexStoredThreadID,
            String,
            CodexJSONValue?,
            CodexJSONValue?
        ) async throws -> CodexDesktopMCPToolCallResult
    public typealias ProgressToolCaller =
        @Sendable (
            CodexStoredThreadID,
            String,
            CodexJSONValue?,
            CodexJSONValue?,
            CodexMCPToolProgressHandler?
        ) async throws -> CodexDesktopMCPToolCallResult

    public let serverInfo: CodexJSONValue?
    public let tools: [String: CodexJSONValue]
    public let resources: [CodexMCPResource]
    public let resourceTemplates: [CodexMCPResourceTemplate]
    public let resourceReader: ResourceReader
    public let toolCaller: ToolCaller
    public let progressToolCaller: ProgressToolCaller?

    public init(
        serverInfo: CodexJSONValue?,
        tools: [String: CodexJSONValue],
        resources: [CodexMCPResource],
        resourceTemplates: [CodexMCPResourceTemplate],
        resourceReader: @escaping ResourceReader,
        toolCaller: @escaping ToolCaller,
        progressToolCaller: ProgressToolCaller? = nil
    ) {
        self.serverInfo = serverInfo
        self.tools = tools
        self.resources = resources
        self.resourceTemplates = resourceTemplates
        self.resourceReader = resourceReader
        self.toolCaller = toolCaller
        self.progressToolCaller = progressToolCaller
    }
}

public protocol CodexMCPServerConnecting: Sendable {
    func connect(
        name: String,
        configuration: CodexMCPServerConfiguration,
        credential: CodexMCPOAuthCredential?
    ) async throws -> CodexMCPConnectedServer
}

public protocol CodexMCPServerRequestHandlingConnecting:
    CodexMCPServerConnecting
{
    func connect(
        name: String,
        configuration: CodexMCPServerConfiguration,
        credential: CodexMCPOAuthCredential?,
        serverRequestHandler: CodexMCPServerRequestHandler?
    ) async throws -> CodexMCPConnectedServer
}

public struct CodexMCPStreamableHTTPConnector:
    CodexMCPServerConnecting,
    CodexMCPServerRequestHandlingConnecting,
    Sendable
{
    public typealias EnvironmentProvider =
        @Sendable () -> [String: String]
    public typealias TransportProvider =
        @Sendable () -> any CodexMCPStreamableHTTPTransport

    private let environmentProvider: EnvironmentProvider
    private let transportProvider: TransportProvider
    private let serverRequestHandler: CodexMCPServerRequestHandler?

    public init(
        environmentProvider:
            @escaping EnvironmentProvider = {
                ProcessInfo.processInfo.environment
            },
        transportProvider:
            @escaping TransportProvider = {
                CodexMCPStreamableURLSessionTransport()
            },
        serverRequestHandler: CodexMCPServerRequestHandler? = nil
    ) {
        self.environmentProvider = environmentProvider
        self.transportProvider = transportProvider
        self.serverRequestHandler = serverRequestHandler
    }

    public func connect(
        name: String,
        configuration: CodexMCPServerConfiguration,
        credential: CodexMCPOAuthCredential?
    ) async throws -> CodexMCPConnectedServer {
        try await connect(
            name: name,
            configuration: configuration,
            credential: credential,
            serverRequestHandler: serverRequestHandler
        )
    }

    public func connect(
        name: String,
        configuration: CodexMCPServerConfiguration,
        credential: CodexMCPOAuthCredential?,
        serverRequestHandler: CodexMCPServerRequestHandler?
    ) async throws -> CodexMCPConnectedServer {
        guard case let .streamableHTTP(
            rawURL,
            bearerTokenEnvironmentVariable,
            configuredHeaders,
            environmentHeaders
        ) = configuration.transport else {
            throw CodexMCPStreamableHTTPError.unsupportedTransport
        }
        guard let url = URL(string: rawURL),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme)
        else {
            throw CodexMCPStreamableHTTPError.invalidURL
        }

        let environment = environmentProvider()
        var headers = configuredHeaders ?? [:]
        for (header, variable) in environmentHeaders ?? [:] {
            if let value = environment[variable], !value.isEmpty {
                headers[header] = value
            }
        }
        if let variable = bearerTokenEnvironmentVariable {
            guard let token = environment[variable], !token.isEmpty else {
                throw CodexMCPStreamableHTTPError
                    .missingBearerToken(variable)
            }
            headers["Authorization"] = "Bearer \(token)"
        } else if let credential {
            let tokenType = credential.tokenType?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            headers["Authorization"] =
                "\((tokenType?.isEmpty == false) ? tokenType! : "Bearer") \(credential.accessToken)"
        }

        let client = CodexMCPStreamableHTTPClient(
            endpoint: url,
            serverName: name,
            headers: headers,
            startupTimeoutSeconds:
                configuration.startupTimeoutSeconds,
            toolTimeoutSeconds:
                configuration.toolTimeoutSeconds,
            transport: transportProvider(),
            serverRequestHandler: serverRequestHandler
        )
        return try await client.connect()
    }
}

public actor CodexMCPStreamableHTTPClient {
    private let endpoint: URL
    private let serverName: String
    private let headers: [String: String]
    private let startupTimeoutSeconds: Double?
    private let toolTimeoutSeconds: Double?
    private let transport: any CodexMCPStreamableHTTPTransport
    private let serverRequestHandler: CodexMCPServerRequestHandler?
    private var sessionID: String?
    private var protocolVersion = "2025-06-18"
    private var nextRequestID: Int64 = 1
    private var nextProgressToken: Int64 = 1

    public init(
        endpoint: URL,
        serverName: String = "",
        headers: [String: String] = [:],
        startupTimeoutSeconds: Double? = nil,
        toolTimeoutSeconds: Double? = nil,
        transport: any CodexMCPStreamableHTTPTransport =
            CodexMCPStreamableURLSessionTransport(),
        serverRequestHandler: CodexMCPServerRequestHandler? = nil
    ) {
        self.endpoint = endpoint
        self.serverName = serverName
        self.headers = headers
        self.startupTimeoutSeconds = startupTimeoutSeconds
        self.toolTimeoutSeconds = toolTimeoutSeconds
        self.transport = transport
        self.serverRequestHandler = serverRequestHandler
    }

    public func connect() async throws -> CodexMCPConnectedServer {
        let initialize = try await call(
            method: "initialize",
            params: .object([
                "protocolVersion": .string(protocolVersion),
                "capabilities": .object([:]),
                "clientInfo": .object([
                    "name": .string("Codex for ipad"),
                    "version": .string("1.0"),
                ]),
            ]),
            timeoutSeconds: startupTimeoutSeconds
        )
        guard case let .object(fields) = initialize else {
            throw CodexMCPStreamableHTTPError.invalidResponse
        }
        if case let .string(version)? = fields["protocolVersion"],
           !version.isEmpty
        {
            protocolVersion = version
        }
        try await notify(
            method: "notifications/initialized",
            params: nil
        )

        let capabilities: [String: CodexJSONValue]
        if case let .object(value)? = fields["capabilities"] {
            capabilities = value
        } else {
            capabilities = [:]
        }
        let toolValues: [CodexJSONValue]
        if capabilities["tools"] != nil {
            toolValues = try await listObjects(
                method: "tools/list",
                field: "tools",
                timeoutSeconds: startupTimeoutSeconds
            )
        } else {
            toolValues = []
        }
        let resourceValues: [CodexMCPResource] =
            if capabilities["resources"] != nil {
                try await listDecodable(
                    method: "resources/list",
                    field: "resources",
                    type: CodexMCPResource.self,
                    timeoutSeconds: startupTimeoutSeconds
                )
            } else {
                []
            }
        let templateValues: [CodexMCPResourceTemplate] =
            if capabilities["resources"] != nil {
                try await listDecodable(
                    method: "resources/templates/list",
                    field: "resourceTemplates",
                    type: CodexMCPResourceTemplate.self,
                    timeoutSeconds: startupTimeoutSeconds
                )
            } else {
                []
            }
        var toolsByName: [String: CodexJSONValue] = [:]
        for tool in toolValues {
            guard case let .object(toolFields) = tool,
                  case let .string(name)? = toolFields["name"],
                  !name.isEmpty
            else {
                throw CodexMCPStreamableHTTPError.invalidResponse
            }
            toolsByName[name] = tool
        }

        return CodexMCPConnectedServer(
            serverInfo: fields["serverInfo"],
            tools: toolsByName,
            resources: resourceValues,
            resourceTemplates: templateValues,
            resourceReader: { [self] uri in
                try await readResource(uri: uri)
            },
            toolCaller: { [self] threadID, tool, arguments, meta in
                try await callTool(
                    tool: tool,
                    arguments: arguments,
                    meta: Self.contextMeta(threadID: threadID, meta: meta)
                )
            },
            progressToolCaller: { [self] threadID, tool, arguments, meta, progress in
                try await callTool(
                    tool: tool,
                    arguments: arguments,
                    meta: Self.contextMeta(threadID: threadID, meta: meta),
                    progress: progress
                )
            }
        )
    }

    private static func contextMeta(
        threadID: CodexStoredThreadID,
        meta: CodexJSONValue?
    ) -> CodexJSONValue {
        var fields: [String: CodexJSONValue]
        if case let .object(existing)? = meta {
            fields = existing
        } else {
            fields = [:]
        }
        fields["threadId"] = .string(threadID.rawValue)
        return .object(fields)
    }

    public func readResource(
        uri: String
    ) async throws -> [CodexMCPResourceContent] {
        let result = try await call(
            method: "resources/read",
            params: .object(["uri": .string(uri)]),
            timeoutSeconds: toolTimeoutSeconds
        )
        guard case let .object(fields) = result,
              let contents = fields["contents"]
        else {
            throw CodexMCPStreamableHTTPError.invalidResponse
        }
        return try decode(
            [CodexMCPResourceContent].self,
            from: contents
        )
    }

    public func callTool(
        tool: String,
        arguments: CodexJSONValue?,
        meta: CodexJSONValue?,
        progress: CodexMCPToolProgressHandler? = nil
    ) async throws -> CodexDesktopMCPToolCallResult {
        var params: [String: CodexJSONValue] = [
            "name": .string(tool),
        ]
        if let arguments {
            params["arguments"] = arguments
        }
        if let progress {
            let token = "progress-\(nextProgressToken)"
            nextProgressToken &+= 1
            params["_meta"] = Self.meta(
                meta,
                addingProgressToken: token
            )
            let result = try await call(
                method: "tools/call",
                params: .object(params),
                timeoutSeconds: toolTimeoutSeconds,
                progressToken: token,
                progress: progress,
                contextMeta: meta
            )
            return try decodeToolCallResult(result)
        } else if let meta {
            params["_meta"] = meta
        }
        let result = try await call(
            method: "tools/call",
            params: .object(params),
            timeoutSeconds: toolTimeoutSeconds,
            contextMeta: meta
        )
        return try decodeToolCallResult(result)
    }

    private func decodeToolCallResult(
        _ result: CodexJSONValue
    ) throws -> CodexDesktopMCPToolCallResult {
        guard case let .object(fields) = result,
              case let .array(content)? = fields["content"]
        else {
            throw CodexMCPStreamableHTTPError.invalidResponse
        }
        let isError: Bool?
        switch fields["isError"] {
        case let .bool(value)?: isError = value
        case nil, .null?: isError = nil
        default:
            throw CodexMCPStreamableHTTPError.invalidResponse
        }
        return CodexDesktopMCPToolCallResult(
            content: content,
            structuredContent: fields["structuredContent"],
            isError: isError,
            meta: fields["_meta"]
        )
    }

    private func listObjects(
        method: String,
        field: String,
        timeoutSeconds: Double?
    ) async throws -> [CodexJSONValue] {
        var values: [CodexJSONValue] = []
        var cursor: String?
        var seen: Set<String> = []
        repeat {
            let params = cursor.map {
                CodexJSONValue.object(["cursor": .string($0)])
            } ?? .object([:])
            let result = try await call(
                method: method,
                params: params,
                timeoutSeconds: timeoutSeconds
            )
            guard case let .object(fields) = result,
                  case let .array(page)? = fields[field]
            else {
                throw CodexMCPStreamableHTTPError.invalidResponse
            }
            values.append(contentsOf: page)
            cursor = optionalString(
                fields["nextCursor"]
            )
            if let cursor, !seen.insert(cursor).inserted {
                throw CodexMCPStreamableHTTPError.paginationLoop
            }
        } while cursor != nil
        return values
    }

    private func listDecodable<Value: Decodable & Sendable>(
        method: String,
        field: String,
        type _: Value.Type,
        timeoutSeconds: Double?
    ) async throws -> [Value] {
        let values = try await listObjects(
            method: method,
            field: field,
            timeoutSeconds: timeoutSeconds
        )
        return try values.map {
            try decode(Value.self, from: $0)
        }
    }

    private func call(
        method: String,
        params: CodexJSONValue?,
        timeoutSeconds: Double?,
        progressToken: String? = nil,
        progress: CodexMCPToolProgressHandler? = nil,
        contextMeta: CodexJSONValue? = nil
    ) async throws -> CodexJSONValue {
        let id = nextRequestID
        nextRequestID &+= 1
        var fields: [String: CodexJSONValue] = [
            "jsonrpc": .string("2.0"),
            "id": .integer(id),
            "method": .string(method),
        ]
        if let params { fields["params"] = params }
        let receiveEvent:
            (@Sendable (Data) async throws -> Void)?
        if (progressToken != nil && progress != nil)
            || serverRequestHandler != nil
        {
            receiveEvent = { [self] data in
                if let progressToken, let progress {
                    try await forwardProgress(
                        data: data,
                        token: progressToken,
                        progress: progress
                    )
                }
                try await forwardServerRequests(
                    data: data,
                    contextMeta: contextMeta
                )
            }
        } else {
            receiveEvent = nil
        }
        let (data, _) = try await send(
            .object(fields),
            timeoutSeconds: timeoutSeconds,
            receiveEvent: receiveEvent
        )
        guard let message = try await responseMessage(
            data: data,
            requestID: id,
            progressToken: nil,
            progress: nil
        ) else {
            throw CodexMCPStreamableHTTPError.invalidResponse
        }
        return try result(from: message, requestID: id)
    }

    private func notify(
        method: String,
        params: CodexJSONValue?
    ) async throws {
        var fields: [String: CodexJSONValue] = [
            "jsonrpc": .string("2.0"),
            "method": .string(method),
        ]
        if let params { fields["params"] = params }
        _ = try await send(
            .object(fields),
            timeoutSeconds: startupTimeoutSeconds
        )
    }

    private func send(
        _ body: CodexJSONValue,
        timeoutSeconds: Double?,
        receiveEvent:
            (@Sendable (Data) async throws -> Void)? = nil
    ) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue(
            "application/json",
            forHTTPHeaderField: "Content-Type"
        )
        request.setValue(
            "application/json, text/event-stream",
            forHTTPHeaderField: "Accept"
        )
        request.setValue(
            protocolVersion,
            forHTTPHeaderField: "MCP-Protocol-Version"
        )
        if let sessionID {
            request.setValue(
                sessionID,
                forHTTPHeaderField: "Mcp-Session-Id"
            )
        }
        for (header, value) in headers {
            request.setValue(value, forHTTPHeaderField: header)
        }
        if let timeoutSeconds, timeoutSeconds > 0 {
            request.timeoutInterval = timeoutSeconds
        }
        request.httpBody = try JSONEncoder().encode(body)
        let (data, response):
            (Data, HTTPURLResponse)
        if let receiveEvent {
            (data, response) = try await transport.streamingData(
                for: request,
                receiveEvent: receiveEvent
            )
        } else {
            (data, response) = try await transport.data(for: request)
        }
        guard (200..<300).contains(response.statusCode) else {
            throw CodexMCPStreamableHTTPError
                .httpStatus(response.statusCode)
        }
        if let newSessionID = response.value(
            forHTTPHeaderField: "Mcp-Session-Id"
        ), !newSessionID.isEmpty {
            sessionID = newSessionID
        }
        return (data, response)
    }

    private func forwardProgress(
        data: Data,
        token: String,
        progress: CodexMCPToolProgressHandler
    ) async throws {
        for value in try messages(data: data) {
            guard let message = progressMessage(
                value,
                token: token
            ) else {
                continue
            }
            await progress(message)
        }
    }

    private func forwardServerRequests(
        data: Data,
        contextMeta: CodexJSONValue?
    ) async throws {
        for value in try messages(data: data) {
            guard let response = try await CodexMCPServerRequest.response(
                for: value,
                serverName: serverName,
                contextMeta: contextMeta,
                handler: serverRequestHandler
            ) else {
                continue
            }
            _ = try await send(
                response,
                timeoutSeconds: toolTimeoutSeconds
            )
        }
    }

    private func responseMessage(
        data: Data,
        requestID: Int64,
        progressToken: String?,
        progress: CodexMCPToolProgressHandler?
    ) async throws -> CodexJSONValue? {
        let values = try messages(data: data)
        for value in values {
            if let progressToken,
               let message = progressMessage(
                   value,
                   token: progressToken
               )
            {
                await progress?(message)
            }
            if let matching = matchingMessage(value, requestID: requestID) {
                return matching
            }
        }
        return nil
    }

    private func messages(
        data: Data
    ) throws -> [CodexJSONValue] {
        guard !data.isEmpty else { return [] }
        if let direct = try? JSONDecoder().decode(
            CodexJSONValue.self,
            from: data
        ) {
            if case let .array(values) = direct {
                return values
            }
            return [direct]
        }
        guard let rawText = String(data: data, encoding: .utf8) else {
            throw CodexMCPStreamableHTTPError.invalidResponse
        }
        var values: [CodexJSONValue] = []
        let text = rawText.replacingOccurrences(
            of: "\r\n",
            with: "\n"
        )
        for event in text.components(separatedBy: "\n\n") {
            let payload = event.split(
                whereSeparator: \.isNewline
            )
            .compactMap { line -> String? in
                guard line.hasPrefix("data:") else { return nil }
                return String(line.dropFirst(5))
                    .trimmingCharacters(in: .whitespaces)
            }
            .joined(separator: "\n")
            guard !payload.isEmpty,
                  let eventData = payload.data(using: .utf8),
                  let value = try? JSONDecoder().decode(
                      CodexJSONValue.self,
                      from: eventData
                  )
            else { continue }
            if case let .array(messages) = value {
                values.append(contentsOf: messages)
            } else {
                values.append(value)
            }
        }
        return values
    }

    private func matchingMessage(
        _ value: CodexJSONValue,
        requestID: Int64
    ) -> CodexJSONValue? {
        if case let .array(messages) = value {
            return messages.first {
                messageID($0) == requestID
            }
        }
        return messageID(value) == requestID ? value : nil
    }

    private func messageID(
        _ value: CodexJSONValue
    ) -> Int64? {
        guard case let .object(fields) = value else { return nil }
        switch fields["id"] {
        case let .integer(value)?: return value
        case let .number(value)? where value.rounded() == value:
            return Int64(value)
        default: return nil
        }
    }

    private func progressMessage(
        _ value: CodexJSONValue,
        token: String
    ) -> String? {
        guard case let .object(fields) = value,
              fields["method"] == .string("notifications/progress"),
              case let .object(params)? = fields["params"],
              params["progressToken"] == .string(token),
              case let .string(message)? = params["message"]
        else {
            return nil
        }
        return message
    }

    private static func meta(
        _ value: CodexJSONValue?,
        addingProgressToken token: String
    ) -> CodexJSONValue {
        guard case let .object(existingFields)? = value else {
            return .object([
                "progressToken": .string(token),
            ])
        }
        var fields = existingFields
        fields["progressToken"] = .string(token)
        return .object(fields)
    }

    private func result(
        from message: CodexJSONValue,
        requestID: Int64
    ) throws -> CodexJSONValue {
        guard case let .object(fields) = message,
              messageID(message) == requestID
        else {
            throw CodexMCPStreamableHTTPError.invalidResponse
        }
        if case let .object(error)? = fields["error"] {
            let code: Int64
            switch error["code"] {
            case let .integer(value)?: code = value
            case let .number(value)?: code = Int64(value)
            default: code = -32603
            }
            let message: String
            if case let .string(value)? = error["message"] {
                message = value
            } else {
                message = "MCP request failed"
            }
            throw CodexMCPStreamableHTTPError.rpc(
                code: code,
                message: message
            )
        }
        guard let result = fields["result"] else {
            throw CodexMCPStreamableHTTPError.invalidResponse
        }
        return result
    }

    private func optionalString(
        _ value: CodexJSONValue?
    ) -> String? {
        switch value {
        case let .string(value) where !value.isEmpty: return value
        case nil, .null?: return nil
        default: return nil
        }
    }

    private func decode<Value: Decodable>(
        _ type: Value.Type,
        from value: CodexJSONValue
    ) throws -> Value {
        do {
            let data = try JSONEncoder().encode(value)
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw CodexMCPStreamableHTTPError.invalidResponse
        }
    }
}
