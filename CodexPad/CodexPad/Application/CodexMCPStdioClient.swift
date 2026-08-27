#if SWIFT_PACKAGE
import CodexPadDomain
#endif
import Darwin
import Foundation

public enum CodexMCPStdioError:
    Error,
    Equatable,
    Sendable
{
    case unsupportedTransport
    case unsupportedPlatform
    case invalidConfiguration
    case runtimeUnavailable(
        command: String,
        reason: String
    )
    case processExited(Int32)
    case processExitedWithStderr(
        code: Int32,
        stderr: String
    )
    case invalidResponse
    case rpc(code: Int64, message: String)
    case paginationLoop
    case timedOut
}

func codexMCPReadByte(
    from output: FileHandle,
    deadlineUptimeNanoseconds: UInt64?
) throws -> Data? {
    if let deadlineUptimeNanoseconds {
        while true {
            let now = DispatchTime.now().uptimeNanoseconds
            guard deadlineUptimeNanoseconds > now else {
                throw CodexMCPStdioError.timedOut
            }
            let remaining = deadlineUptimeNanoseconds - now
            let roundedMilliseconds =
                (remaining + 999_999) / 1_000_000
            let timeoutMilliseconds = Int32(
                min(roundedMilliseconds, UInt64(Int32.max))
            )
            var descriptor = pollfd(
                fd: output.fileDescriptor,
                events: Int16(POLLIN | POLLHUP),
                revents: 0
            )
            let result = Darwin.poll(
                &descriptor,
                1,
                timeoutMilliseconds
            )
            if result > 0 {
                break
            }
            if result == 0 {
                throw CodexMCPStdioError.timedOut
            }
            if errno != EINTR {
                throw CodexMCPStdioError.invalidResponse
            }
        }
    }
    return try output.read(upToCount: 1)
}

func codexMCPDeadline(
    timeoutSeconds: Double?
) -> UInt64? {
    guard let timeoutSeconds,
          timeoutSeconds.isFinite,
          timeoutSeconds >= 0
    else {
        return nil
    }
    let nanoseconds = min(
        timeoutSeconds * 1_000_000_000,
        Double(UInt64.max)
    )
    let deadline = DispatchTime.now().uptimeNanoseconds
        .addingReportingOverflow(UInt64(nanoseconds))
    return deadline.overflow ? UInt64.max : deadline.partialValue
}

public protocol CodexMCPStdioTransport: Sendable {
    func writeLine(_ data: Data) async throws
    func readLine(timeoutSeconds: Double?) async throws -> Data
}

public struct CodexMCPStdioConnector:
    CodexMCPServerConnecting,
    CodexMCPServerRequestHandlingConnecting,
    Sendable
{
    public typealias EnvironmentProvider =
        @Sendable () -> [String: String]
    public typealias TransportProvider =
        @Sendable (
            String,
            [String],
            [String: String],
            String?
        ) throws -> any CodexMCPStdioTransport

    private let environmentProvider: EnvironmentProvider
    private let transportProvider: TransportProvider
    private let serverRequestHandler: CodexMCPServerRequestHandler?

    private static let defaultTransportProvider: TransportProvider = {
        command, arguments, environment, cwd in
#if os(macOS)
        return CodexMCPStdioProcessTransport(
            command: command,
            arguments: arguments,
            environment: environment,
            cwd: cwd
        )
#elseif os(iOS) && canImport(ios_system)
        return try CodexMCPEmbeddedTransportFactory.make(
            command: command,
            arguments: arguments,
            environment: environment,
            cwd: cwd
        )
#else
        throw CodexMCPStdioError.unsupportedPlatform
#endif
    }

    public init(
        environmentProvider:
            @escaping EnvironmentProvider = {
                ProcessInfo.processInfo.environment
            },
        transportProvider:
            TransportProvider? = nil,
        serverRequestHandler: CodexMCPServerRequestHandler? = nil
    ) {
        self.environmentProvider = environmentProvider
        self.transportProvider =
            transportProvider ?? Self.defaultTransportProvider
        self.serverRequestHandler = serverRequestHandler
    }

    public func connect(
        name: String,
        configuration: CodexMCPServerConfiguration,
        credential _: CodexMCPOAuthCredential?
    ) async throws -> CodexMCPConnectedServer {
        try await connect(
            name: name,
            configuration: configuration,
            credential: nil,
            serverRequestHandler: serverRequestHandler
        )
    }

    public func connect(
        name: String,
        configuration: CodexMCPServerConfiguration,
        credential _: CodexMCPOAuthCredential?,
        serverRequestHandler: CodexMCPServerRequestHandler?
    ) async throws -> CodexMCPConnectedServer {
        guard case let .stdio(
            command,
            arguments,
            configuredEnvironment,
            environmentVariables,
            cwd
        ) = configuration.transport else {
            throw CodexMCPStdioError.unsupportedTransport
        }
        guard !command.isEmpty else {
            throw CodexMCPStdioError.invalidConfiguration
        }
        let inherited = environmentProvider()
        var environment = inherited
        for (name, value) in configuredEnvironment ?? [:] {
            environment[name] = value
        }
        for variable in environmentVariables {
            let name: String
            switch variable {
            case let .name(value):
                name = value
            case let .config(value, _):
                name = value
            }
            if let value = inherited[name] {
                environment[name] = value
            }
        }
        let transport = try transportProvider(
            command,
            arguments,
            environment,
            cwd
        )
        let client = CodexMCPStdioClient(
            serverName: name,
            transport: transport,
            startupTimeoutSeconds:
                configuration.startupTimeoutSeconds,
            toolTimeoutSeconds:
                configuration.toolTimeoutSeconds,
            serverRequestHandler: serverRequestHandler
        )
        return try await client.connect()
    }
}

public struct CodexMCPCompositeConnector:
    CodexMCPServerConnecting,
    Sendable
{
    private let http: any CodexMCPServerConnecting
    private let stdio: any CodexMCPServerConnecting
    private let serverRequestHandler: CodexMCPServerRequestHandler?

    public init(
        http: any CodexMCPServerConnecting =
            CodexMCPStreamableHTTPConnector(),
        stdio: any CodexMCPServerConnecting =
            CodexMCPStdioConnector(),
        serverRequestHandler: CodexMCPServerRequestHandler? = nil
    ) {
        self.http = http
        self.stdio = stdio
        self.serverRequestHandler = serverRequestHandler
    }

    public func connect(
        name: String,
        configuration: CodexMCPServerConfiguration,
        credential: CodexMCPOAuthCredential?
    ) async throws -> CodexMCPConnectedServer {
        switch configuration.transport {
        case .stdio:
            return try await connect(
                connector: stdio,
                name: name,
                configuration: configuration,
                credential: credential
            )
        case .streamableHTTP:
            return try await connect(
                connector: http,
                name: name,
                configuration: configuration,
                credential: credential
            )
        }
    }

    private func connect(
        connector: any CodexMCPServerConnecting,
        name: String,
        configuration: CodexMCPServerConfiguration,
        credential: CodexMCPOAuthCredential?
    ) async throws -> CodexMCPConnectedServer {
        if let connector = connector as?
            any CodexMCPServerRequestHandlingConnecting
        {
            return try await connector.connect(
                name: name,
                configuration: configuration,
                credential: credential,
                serverRequestHandler: serverRequestHandler
            )
        }
        return try await connector.connect(
            name: name,
            configuration: configuration,
            credential: credential
        )
    }
}

public actor CodexMCPStdioClient {
    private let serverName: String
    private let transport: any CodexMCPStdioTransport
    private let serverRequestHandler: CodexMCPServerRequestHandler?
    private let startupTimeoutSeconds: Double?
    private let toolTimeoutSeconds: Double?
    private var protocolVersion = "2025-06-18"
    private var nextRequestID: Int64 = 1
    private var nextProgressToken: Int64 = 1

    public init(
        serverName: String = "",
        transport: any CodexMCPStdioTransport,
        startupTimeoutSeconds: Double? = nil,
        toolTimeoutSeconds: Double? = nil,
        serverRequestHandler: CodexMCPServerRequestHandler? = nil
    ) {
        self.serverName = serverName
        self.transport = transport
        self.startupTimeoutSeconds = startupTimeoutSeconds
        self.toolTimeoutSeconds = toolTimeoutSeconds
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
            throw CodexMCPStdioError.invalidResponse
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
        let toolValues = capabilities["tools"] == nil
            ? []
            : try await listObjects(
                method: "tools/list",
                field: "tools",
                timeoutSeconds: startupTimeoutSeconds
            )
        let resources: [CodexMCPResource] =
            capabilities["resources"] == nil
            ? []
            : try await listDecodable(
                method: "resources/list",
                field: "resources",
                type: CodexMCPResource.self,
                timeoutSeconds: startupTimeoutSeconds
            )
        let templates: [CodexMCPResourceTemplate] =
            capabilities["resources"] == nil
            ? []
            : try await listDecodable(
                method: "resources/templates/list",
                field: "resourceTemplates",
                type: CodexMCPResourceTemplate.self,
                timeoutSeconds: startupTimeoutSeconds
            )
        var tools: [String: CodexJSONValue] = [:]
        for tool in toolValues {
            guard case let .object(toolFields) = tool,
                  case let .string(name)? = toolFields["name"],
                  !name.isEmpty
            else {
                throw CodexMCPStdioError.invalidResponse
            }
            tools[name] = tool
        }
        return CodexMCPConnectedServer(
            serverInfo: fields["serverInfo"],
            tools: tools,
            resources: resources,
            resourceTemplates: templates,
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
            throw CodexMCPStdioError.invalidResponse
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
            throw CodexMCPStdioError.invalidResponse
        }
        let isError: Bool?
        switch fields["isError"] {
        case let .bool(value)?:
            isError = value
        case nil, .null?:
            isError = nil
        default:
            throw CodexMCPStdioError.invalidResponse
        }
        return CodexDesktopMCPToolCallResult(
            content: content,
            structuredContent: fields["structuredContent"],
            isError: isError,
            meta: fields["_meta"]
        )
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
        var message: [String: CodexJSONValue] = [
            "jsonrpc": .string("2.0"),
            "id": .integer(id),
            "method": .string(method),
        ]
        if let params {
            message["params"] = params
        }
        var data = try JSONEncoder().encode(
            CodexJSONValue.object(message)
        )
        data.append(0x0A)
        try await transport.writeLine(data)
        while true {
            let response = try await transport.readLine(
                timeoutSeconds: timeoutSeconds
            )
            guard let value = try? JSONDecoder().decode(
                CodexJSONValue.self,
                from: response
            ), case let .object(fields) = value
            else {
                throw CodexMCPStdioError.invalidResponse
            }
            if let progressToken,
               fields["method"] == .string("notifications/progress"),
               let params = fields["params"],
               let message = Self.progressMessage(
                   params,
                   token: progressToken
               )
            {
                await progress?(message)
                continue
            }
            if let serverResponse = try await CodexMCPServerRequest.response(
                for: value,
                serverName: serverName,
                contextMeta: contextMeta,
                handler: serverRequestHandler
            ) {
                var responseData = try JSONEncoder().encode(serverResponse)
                responseData.append(0x0A)
                try await transport.writeLine(responseData)
                continue
            }
            guard fields["id"] == .integer(id) else {
                continue
            }
            if case let .object(error)? = fields["error"],
               case let .integer(code)? = error["code"],
               case let .string(message)? = error["message"]
            {
                throw CodexMCPStdioError.rpc(
                    code: code,
                    message: message
                )
            }
            guard let result = fields["result"] else {
                throw CodexMCPStdioError.invalidResponse
            }
            return result
        }
    }

    private func notify(
        method: String,
        params: CodexJSONValue?
    ) async throws {
        var message: [String: CodexJSONValue] = [
            "jsonrpc": .string("2.0"),
            "method": .string(method),
        ]
        if let params {
            message["params"] = params
        }
        var data = try JSONEncoder().encode(
            CodexJSONValue.object(message)
        )
        data.append(0x0A)
        try await transport.writeLine(data)
    }

    private static func progressMessage(
        _ value: CodexJSONValue,
        token: String
    ) -> String? {
        guard case let .object(params) = value,
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
                throw CodexMCPStdioError.invalidResponse
            }
            values.append(contentsOf: page)
            if case let .string(value)? = fields["nextCursor"],
               !value.isEmpty
            {
                cursor = value
                if !seen.insert(value).inserted {
                    throw CodexMCPStdioError.paginationLoop
                }
            } else {
                cursor = nil
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
        try await listObjects(
            method: method,
            field: field,
            timeoutSeconds: timeoutSeconds
        ).map {
            try decode(Value.self, from: $0)
        }
    }

    private func decode<Value: Decodable>(
        _ type: Value.Type,
        from value: CodexJSONValue
    ) throws -> Value {
        try JSONDecoder().decode(
            type,
            from: JSONEncoder().encode(value)
        )
    }
}

#if os(macOS)
public actor CodexMCPStdioProcessTransport:
    CodexMCPStdioTransport
{
    private let command: String
    private let arguments: [String]
    private let environment: [String: String]
    private let cwd: String?
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var readBuffer = Data()

    public init(
        command: String,
        arguments: [String],
        environment: [String: String],
        cwd: String?
    ) {
        self.command = command
        self.arguments = arguments
        self.environment = environment
        self.cwd = cwd
    }

    deinit {
        try? input?.close()
        if process?.isRunning == true {
            process?.terminate()
        }
    }

    public func writeLine(_ data: Data) async throws {
        try startIfNeeded()
        guard let input else {
            throw CodexMCPStdioError.invalidConfiguration
        }
        try input.write(contentsOf: data)
    }

    public func readLine(
        timeoutSeconds: Double?
    ) async throws -> Data {
        try startIfNeeded()
        guard let output else {
            throw CodexMCPStdioError.invalidConfiguration
        }
        let deadline = codexMCPDeadline(
            timeoutSeconds: timeoutSeconds
        )
        while true {
            if let newline = readBuffer.firstIndex(of: 0x0A) {
                let line = Data(readBuffer[..<newline])
                readBuffer.removeSubrange(...newline)
                return line
            }
            guard let byte = try codexMCPReadByte(
                from: output,
                deadlineUptimeNanoseconds: deadline
            ),
                  !byte.isEmpty
            else {
                throw CodexMCPStdioError.processExited(
                    process?.terminationStatus ?? -1
                )
            }
            readBuffer.append(byte)
        }
    }

    private func startIfNeeded() throws {
        guard process == nil else {
            return
        }
        let process = Process()
        if command.contains("/") {
            process.executableURL = URL(fileURLWithPath: command)
            process.arguments = arguments
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [command] + arguments
        }
        process.environment = environment
        if let cwd {
            process.currentDirectoryURL = URL(
                fileURLWithPath: cwd,
                isDirectory: true
            )
        }
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        self.process = process
        self.input = input.fileHandleForWriting
        self.output = output.fileHandleForReading
    }
}
#endif
