#if SWIFT_PACKAGE
import CodexPadDomain
#endif
import Foundation

public struct CodexEnvironmentAddParameters: Equatable, Sendable {
    public let environmentID: String
    public let execServerURL: URL
    public let connectTimeoutMs: UInt64?

    public init(
        environmentID: String,
        execServerURL: URL,
        connectTimeoutMs: UInt64?
    ) {
        self.environmentID = environmentID
        self.execServerURL = execServerURL
        self.connectTimeoutMs = connectTimeoutMs
    }
}

public struct CodexEnvironmentShellInfo: Equatable, Sendable {
    public let name: String
    public let path: String

    public init(name: String, path: String) {
        self.name = name
        self.path = path
    }
}

public struct CodexEnvironmentInfo: Equatable, Sendable {
    public let shell: CodexEnvironmentShellInfo
    public let cwd: String?

    public init(shell: CodexEnvironmentShellInfo, cwd: String?) {
        self.shell = shell
        self.cwd = cwd
    }
}

public enum CodexEnvironmentStatusKind:
    String,
    Equatable,
    Sendable
{
    case ready
    case pending
    case disconnected
    case unknown
}

public struct CodexEnvironmentStatus: Equatable, Sendable {
    public let status: CodexEnvironmentStatusKind
    public let error: String?

    public init(
        status: CodexEnvironmentStatusKind,
        error: String? = nil
    ) {
        self.status = status
        self.error = error
    }
}

public enum CodexEnvironmentServiceError:
    Error,
    Equatable,
    LocalizedError,
    Sendable
{
    case invalidEnvironmentID
    case reservedLocalEnvironmentID
    case invalidExecServerURL(String)
    case unknownEnvironment(String)
    case connectionFailed(environmentID: String, detail: String)
    case protocolFailure(String)
    case requestTimedOut(String)

    public var errorDescription: String? {
        switch self {
        case .invalidEnvironmentID:
            "environmentId must not be empty"
        case .reservedLocalEnvironmentID:
            "environment id `local` is reserved"
        case let .invalidExecServerURL(value):
            "invalid exec-server WebSocket URL `\(value)`"
        case let .unknownEnvironment(environmentID):
            "unknown environment id `\(environmentID)`"
        case let .connectionFailed(environmentID, detail):
            "failed to connect environment `\(environmentID)`: \(detail)"
        case let .protocolFailure(detail):
            "exec-server protocol failure: \(detail)"
        case let .requestTimedOut(method):
            "exec-server request `\(method)` timed out"
        }
    }
}

public protocol CodexDesktopEnvironmentManaging: Sendable {
    func addEnvironment(
        _ parameters: CodexEnvironmentAddParameters
    ) async throws
    func environmentInfo(
        environmentID: String
    ) async throws -> CodexEnvironmentInfo
    func environmentStatus(
        environmentID: String
    ) async -> CodexEnvironmentStatus
}

public actor CodexEnvironmentService:
    CodexDesktopEnvironmentManaging
{
    private let connector:
        any CodexRemoteControlWebSocketConnecting
    private let defaultConnectTimeoutMs: UInt64
    private var connections:
        [String: CodexEnvironmentConnection] = [:]

    public init(
        connector:
            any CodexRemoteControlWebSocketConnecting =
                CodexRemoteControlURLSessionWebSocketConnector(),
        defaultConnectTimeoutMs: UInt64 = 30_000
    ) {
        self.connector = connector
        self.defaultConnectTimeoutMs = defaultConnectTimeoutMs
    }

    public func addEnvironment(
        _ parameters: CodexEnvironmentAddParameters
    ) async throws {
        let environmentID = parameters.environmentID
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !environmentID.isEmpty else {
            throw CodexEnvironmentServiceError.invalidEnvironmentID
        }
        guard environmentID != "local" else {
            throw CodexEnvironmentServiceError
                .reservedLocalEnvironmentID
        }
        guard let scheme = parameters.execServerURL.scheme?.lowercased(),
              scheme == "ws" || scheme == "wss",
              parameters.execServerURL.host != nil
        else {
            throw CodexEnvironmentServiceError.invalidExecServerURL(
                parameters.execServerURL.absoluteString
            )
        }

        let timeoutMs =
            parameters.connectTimeoutMs ?? defaultConnectTimeoutMs
        let replacement = CodexEnvironmentConnection(
            environmentID: environmentID,
            url: parameters.execServerURL,
            connectTimeoutMs: timeoutMs,
            connector: connector
        )
        if let previous = connections.updateValue(
            replacement,
            forKey: environmentID
        ) {
            await previous.close()
        }
        Task {
            await replacement.start()
        }
    }

    public func environmentInfo(
        environmentID: String
    ) async throws -> CodexEnvironmentInfo {
        guard let connection = connections[environmentID] else {
            throw CodexEnvironmentServiceError
                .unknownEnvironment(environmentID)
        }
        do {
            return try await connection.info()
        } catch let error as CodexEnvironmentServiceError {
            throw error
        } catch {
            throw CodexEnvironmentServiceError.connectionFailed(
                environmentID: environmentID,
                detail: error.localizedDescription
            )
        }
    }

    public func environmentStatus(
        environmentID: String
    ) async -> CodexEnvironmentStatus {
        guard let connection = connections[environmentID] else {
            return CodexEnvironmentStatus(
                status: .unknown,
                error: "unknown environment id `\(environmentID)`"
            )
        }
        return await connection.status()
    }
}

private actor CodexEnvironmentConnection {
    private enum ConnectionState: Equatable {
        case pending
        case ready
        case disconnected(String)
    }

    private let environmentID: String
    private let url: URL
    private let connectTimeoutMs: UInt64
    private let connector:
        any CodexRemoteControlWebSocketConnecting
    private var state = ConnectionState.pending
    private var socket:
        (any CodexRemoteControlWebSocketSocket)?
    private var receiveTask: Task<Void, Never>?
    private var nextRequestID: Int64 = 1
    private var pendingRequests:
        [Int64: CheckedContinuation<CodexJSONValue, any Error>] = [:]
    private var requestTimeoutTasks:
        [Int64: Task<Void, Never>] = [:]

    init(
        environmentID: String,
        url: URL,
        connectTimeoutMs: UInt64,
        connector: any CodexRemoteControlWebSocketConnecting
    ) {
        self.environmentID = environmentID
        self.url = url
        self.connectTimeoutMs = connectTimeoutMs
        self.connector = connector
    }

    func start() async {
        guard state == .pending, socket == nil else {
            return
        }
        do {
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.timeoutInterval =
                TimeInterval(connectTimeoutMs) / 1_000
            let connectedSocket = try await connect(request: request)
            socket = connectedSocket
            receiveTask = Task {
                await self.receiveFrames(from: connectedSocket)
            }

            let initializeResult = try await rpcRequest(
                method: "initialize",
                params: .object([
                    "clientName": .string("codex-ipad"),
                    "resumeSessionId": .null,
                ])
            )
            guard case let .object(response) = initializeResult,
                  case let .string(sessionID)? = response["sessionId"],
                  !sessionID.isEmpty
            else {
                throw CodexEnvironmentServiceError.protocolFailure(
                    "initialize response is missing sessionId"
                )
            }
            try await sendNotification(
                method: "initialized",
                params: .object([:])
            )
            state = .ready
        } catch {
            await disconnect(
                detail: Self.describe(error)
            )
        }
    }

    func info() async throws -> CodexEnvironmentInfo {
        try await waitUntilReady()
        do {
            let value = try await rpcRequest(
                method: "environment/info",
                params: .object([:])
            )
            guard case let .object(info) = value,
                  case let .object(shell)? = info["shell"],
                  case let .string(name)? = shell["name"],
                  case let .string(path)? = shell["path"]
            else {
                throw CodexEnvironmentServiceError.protocolFailure(
                    "environment/info response has an invalid shell"
                )
            }
            let cwd: String?
            switch info["cwd"] {
            case nil, .some(.null):
                cwd = nil
            case let .some(.string(value)):
                cwd = value
            default:
                throw CodexEnvironmentServiceError.protocolFailure(
                    "environment/info response has an invalid cwd"
                )
            }
            return CodexEnvironmentInfo(
                shell: CodexEnvironmentShellInfo(
                    name: name,
                    path: path
                ),
                cwd: cwd
            )
        } catch {
            let detail = Self.describe(error)
            await disconnect(detail: detail)
            throw CodexEnvironmentServiceError.connectionFailed(
                environmentID: environmentID,
                detail: detail
            )
        }
    }

    func status() async -> CodexEnvironmentStatus {
        switch state {
        case .pending:
            return CodexEnvironmentStatus(status: .pending)
        case let .disconnected(detail):
            return CodexEnvironmentStatus(
                status: .disconnected,
                error: detail
            )
        case .ready:
            do {
                let value = try await rpcRequest(
                    method: "environment/status",
                    params: .object([:])
                )
                guard case let .object(result) = value,
                      case .string("ready")? = result["status"]
                else {
                    throw CodexEnvironmentServiceError.protocolFailure(
                        "environment/status response is not ready"
                    )
                }
                return CodexEnvironmentStatus(status: .ready)
            } catch {
                let detail = Self.describe(error)
                await disconnect(detail: detail)
                return CodexEnvironmentStatus(
                    status: .disconnected,
                    error: detail
                )
            }
        }
    }

    func close() async {
        receiveTask?.cancel()
        receiveTask = nil
        if let socket {
            await socket.close()
        }
        self.socket = nil
        failAllPending(
            CodexEnvironmentServiceError.connectionFailed(
                environmentID: environmentID,
                detail: "environment was replaced"
            )
        )
        state = .disconnected("environment was replaced")
    }

    private func connect(
        request: URLRequest
    ) async throws -> any CodexRemoteControlWebSocketSocket {
        let connector = self.connector
        let timeoutMs = connectTimeoutMs
        return try await withThrowingTaskGroup(
            of: (any CodexRemoteControlWebSocketSocket).self
        ) { group in
            group.addTask {
                try await connector.connect(request: request)
            }
            group.addTask {
                try await Task.sleep(
                    for: .milliseconds(Int64(timeoutMs))
                )
                throw CodexEnvironmentServiceError.requestTimedOut(
                    "connect"
                )
            }
            guard let first = try await group.next() else {
                throw CodexEnvironmentServiceError.requestTimedOut(
                    "connect"
                )
            }
            group.cancelAll()
            return first
        }
    }

    private func waitUntilReady() async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(
            by: .milliseconds(Int64(connectTimeoutMs))
        )
        while true {
            switch state {
            case .ready:
                return
            case let .disconnected(detail):
                throw CodexEnvironmentServiceError.connectionFailed(
                    environmentID: environmentID,
                    detail: detail
                )
            case .pending:
                guard clock.now < deadline else {
                    throw CodexEnvironmentServiceError.requestTimedOut(
                        "initialize"
                    )
                }
                try await Task.sleep(for: .milliseconds(10))
            }
        }
    }

    private func rpcRequest(
        method: String,
        params: CodexJSONValue
    ) async throws -> CodexJSONValue {
        guard let socket else {
            throw CodexEnvironmentServiceError.connectionFailed(
                environmentID: environmentID,
                detail: "WebSocket is not connected"
            )
        }
        let requestID = nextRequestID
        nextRequestID += 1
        let payload = CodexJSONValue.object([
            "jsonrpc": .string("2.0"),
            "id": .integer(requestID),
            "method": .string(method),
            "params": params,
        ])
        return try await withCheckedThrowingContinuation {
            continuation in
            pendingRequests[requestID] = continuation
            requestTimeoutTasks[requestID] = Task {
                try? await Task.sleep(
                    for: .milliseconds(
                        Int64(self.connectTimeoutMs)
                    )
                )
                self.expireRequest(
                    requestID,
                    method: method
                )
            }
            Task {
                do {
                    try await socket.send(
                        text: Self.encode(payload)
                    )
                } catch {
                    self.failRequest(
                        requestID,
                        error: error
                    )
                }
            }
        }
    }

    private func sendNotification(
        method: String,
        params: CodexJSONValue
    ) async throws {
        guard let socket else {
            throw CodexEnvironmentServiceError.connectionFailed(
                environmentID: environmentID,
                detail: "WebSocket is not connected"
            )
        }
        try await socket.send(
            text: Self.encode(
                .object([
                    "jsonrpc": .string("2.0"),
                    "method": .string(method),
                    "params": params,
                ])
            )
        )
    }

    private func receiveFrames(
        from socket: any CodexRemoteControlWebSocketSocket
    ) async {
        do {
            while !Task.isCancelled {
                switch try await socket.receive() {
                case let .text(text):
                    try handleIncoming(Data(text.utf8))
                case let .binary(data):
                    try handleIncoming(data)
                case .ping, .pong:
                    continue
                case let .closed(code, reason):
                    throw CodexRemoteControlWebSocketFailure
                        .disconnected(code: code, reason: reason)
                }
            }
        } catch is CancellationError {
            return
        } catch {
            await disconnect(detail: Self.describe(error))
        }
    }

    private func handleIncoming(_ data: Data) throws {
        let value = try JSONDecoder().decode(
            CodexJSONValue.self,
            from: data
        )
        guard case let .object(message) = value,
              case let .integer(requestID)? = message["id"],
              let continuation = pendingRequests.removeValue(
                  forKey: requestID
              )
        else {
            return
        }
        requestTimeoutTasks.removeValue(forKey: requestID)?.cancel()
        if let error = message["error"] {
            continuation.resume(
                throwing: CodexEnvironmentServiceError.protocolFailure(
                    "request returned \(Self.describeJSON(error))"
                )
            )
        } else if let result = message["result"] {
            continuation.resume(returning: result)
        } else {
            continuation.resume(
                throwing: CodexEnvironmentServiceError.protocolFailure(
                    "response is missing result"
                )
            )
        }
    }

    private func expireRequest(
        _ requestID: Int64,
        method: String
    ) {
        guard let continuation = pendingRequests.removeValue(
            forKey: requestID
        ) else {
            return
        }
        requestTimeoutTasks.removeValue(forKey: requestID)
        continuation.resume(
            throwing: CodexEnvironmentServiceError
                .requestTimedOut(method)
        )
    }

    private func failRequest(
        _ requestID: Int64,
        error: any Error
    ) {
        guard let continuation = pendingRequests.removeValue(
            forKey: requestID
        ) else {
            return
        }
        requestTimeoutTasks.removeValue(forKey: requestID)?.cancel()
        continuation.resume(throwing: error)
    }

    private func disconnect(detail: String) async {
        guard case .disconnected = state else {
            state = .disconnected(detail)
            receiveTask?.cancel()
            receiveTask = nil
            if let socket {
                await socket.close()
            }
            socket = nil
            failAllPending(
                CodexEnvironmentServiceError.connectionFailed(
                    environmentID: environmentID,
                    detail: detail
                )
            )
            return
        }
    }

    private func failAllPending(_ error: any Error) {
        let continuations = pendingRequests.values
        pendingRequests.removeAll()
        for task in requestTimeoutTasks.values {
            task.cancel()
        }
        requestTimeoutTasks.removeAll()
        continuations.forEach {
            $0.resume(throwing: error)
        }
    }

    private static func encode(
        _ value: CodexJSONValue
    ) throws -> String {
        let data = try JSONEncoder().encode(value)
        guard let text = String(data: data, encoding: .utf8) else {
            throw CodexEnvironmentServiceError.protocolFailure(
                "failed to encode JSON-RPC message"
            )
        }
        return text
    }

    private static func describe(_ error: any Error) -> String {
        (error as? LocalizedError)?.errorDescription
            ?? error.localizedDescription
    }

    private static func describeJSON(
        _ value: CodexJSONValue
    ) -> String {
        guard let data = try? JSONEncoder().encode(value) else {
            return "an invalid JSON-RPC error"
        }
        return String(decoding: data, as: UTF8.self)
    }
}
