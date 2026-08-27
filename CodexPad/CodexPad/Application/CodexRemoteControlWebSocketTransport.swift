#if SWIFT_PACKAGE
import CodexPadDomain
#endif
import Foundation

public struct CodexRemoteControlWebSocketConfiguration:
    Equatable,
    Sendable
{
    public let pingInterval: Duration
    public let pongTimeout: Duration
    public let connectTimeout: Duration
    public let shutdownTimeout: Duration
    public let reconnectBackoffCap: Duration

    public init(
        pingInterval: Duration = .seconds(10),
        pongTimeout: Duration = .seconds(60),
        connectTimeout: Duration = .seconds(30),
        shutdownTimeout: Duration = .seconds(5),
        reconnectBackoffCap: Duration = .seconds(30)
    ) {
        self.pingInterval = pingInterval
        self.pongTimeout = pongTimeout
        self.connectTimeout = connectTimeout
        self.shutdownTimeout = shutdownTimeout
        self.reconnectBackoffCap = reconnectBackoffCap
    }
}

public enum CodexRemoteControlWebSocketStatus: Equatable, Sendable {
    case disconnected
    case connecting
    case connected
    case reconnecting(attempt: Int, delay: Duration)
    case stopped
}

public enum CodexRemoteControlWebSocketFrame: Equatable, Sendable {
    case text(String)
    case binary(Data)
    case ping(Data)
    case pong(Data)
    case closed(code: Int?, reason: String?)
}

public protocol CodexRemoteControlWebSocketSocket: Sendable {
    func send(text: String) async throws

    /// Returns only after the peer's WebSocket Pong confirms this Ping.
    func sendPing() async throws

    func receive() async throws -> CodexRemoteControlWebSocketFrame
    func close() async
}

public protocol CodexRemoteControlWebSocketConnecting: Sendable {
    /// Completes only after the HTTP Upgrade handshake has succeeded.
    func connect(
        request: URLRequest
    ) async throws -> any CodexRemoteControlWebSocketSocket
}

public enum CodexRemoteControlWebSocketHTTPClassification:
    String,
    Codable,
    Equatable,
    Sendable
{
    case permissionDenied
    case missingRemoteAppServer
    case other
}

public struct CodexRemoteControlWebSocketHTTPFailure:
    Error,
    Equatable,
    Sendable
{
    public static let remoteAppServerNotFoundDetail =
        "Remote app server not found"

    public let statusCode: Int
    public let classification: CodexRemoteControlWebSocketHTTPClassification
    public let headers: [String: String]
    public let bodyPreview: String?

    public init(
        statusCode: Int,
        classification: CodexRemoteControlWebSocketHTTPClassification,
        headers: [String: String],
        bodyPreview: String?
    ) {
        self.statusCode = statusCode
        self.classification = classification
        self.headers = headers
        self.bodyPreview = bodyPreview
    }

    public static func classify(
        statusCode: Int,
        headers: [String: String],
        body: Data?
    ) -> Self {
        let preview = body.flatMap(Self.bodyPreview)
        let classification: CodexRemoteControlWebSocketHTTPClassification
        if statusCode == 401 || statusCode == 403 {
            classification = .permissionDenied
        } else if statusCode == 404,
                  body.flatMap(Self.detail) == remoteAppServerNotFoundDetail
        {
            classification = .missingRemoteAppServer
        } else {
            classification = .other
        }
        return Self(
            statusCode: statusCode,
            classification: classification,
            headers: headers,
            bodyPreview: preview
        )
    }

    private static func detail(_ data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data)
            as? [String: Any]
        else {
            return nil
        }
        return object["detail"] as? String
    }

    private static func bodyPreview(_ data: Data) -> String? {
        let prefix = data.prefix(4_096)
        guard !prefix.isEmpty else {
            return nil
        }
        return String(decoding: prefix, as: UTF8.self)
    }
}

public enum CodexRemoteControlWebSocketFailure:
    Error,
    Equatable,
    LocalizedError,
    Sendable
{
    case invalidBaseURL(String)
    case invalidHeader(name: String)
    case missingRemoteControlToken
    case connectTimedOut
    case shutdownTimedOut
    case http(CodexRemoteControlWebSocketHTTPFailure)
    case protocolFailure(CodexRemoteControlWebSocketProtocolError)
    case transport(String)
    case inboundHandler(String)
    case pongTimedOut
    case disconnected(code: Int?, reason: String?)

    public var errorDescription: String? {
        switch self {
        case let .invalidBaseURL(value):
            "Invalid remote-control WebSocket base URL: \(value)"
        case let .invalidHeader(name):
            "Invalid remote-control WebSocket header: \(name)"
        case .missingRemoteControlToken:
            "Missing remote-control server token"
        case .connectTimedOut:
            "Remote-control WebSocket handshake timed out"
        case .shutdownTimedOut:
            "Remote-control WebSocket shutdown timed out"
        case let .http(failure):
            "Remote-control WebSocket handshake returned HTTP \(failure.statusCode)"
        case let .protocolFailure(error):
            error.localizedDescription
        case let .transport(message):
            "Remote-control WebSocket transport failed: \(message)"
        case let .inboundHandler(message):
            "Remote-control inbound delivery failed: \(message)"
        case .pongTimedOut:
            "Remote-control WebSocket Pong deadline expired"
        case let .disconnected(code, reason):
            "Remote-control WebSocket disconnected (code: \(code.map(String.init) ?? "unknown"), reason: \(reason ?? "unknown"))"
        }
    }

    public var requiresUpperLayerRecovery: Bool {
        guard case let .http(failure) = self else {
            return false
        }
        return failure.classification == .permissionDenied
            || failure.classification == .missingRemoteAppServer
    }
}

public enum CodexRemoteControlWebSocketRequest {
    public static let protocolVersion = "3"
    public static let endpointPath = "wham/remote/control/server"

    public static func make(
        validatedHTTPBaseURL: URL,
        enrollment: CodexRemoteControlHTTPEnrollment,
        serverName: String,
        installationID: String,
        subscribeCursor: String?
    ) throws -> URLRequest {
        guard var baseComponents = URLComponents(
            url: validatedHTTPBaseURL,
            resolvingAgainstBaseURL: true
        ), baseComponents.scheme == "http" || baseComponents.scheme == "https",
        baseComponents.host != nil
        else {
            throw CodexRemoteControlWebSocketFailure.invalidBaseURL(
                validatedHTTPBaseURL.absoluteString
            )
        }
        if !baseComponents.path.hasSuffix("/") {
            baseComponents.path += "/"
        }
        guard let normalizedBase = baseComponents.url,
              let joined = URL(
                  string: endpointPath,
                  relativeTo: normalizedBase
              )?.absoluteURL,
              var webSocketComponents = URLComponents(
                  url: joined,
                  resolvingAgainstBaseURL: true
              )
        else {
            throw CodexRemoteControlWebSocketFailure.invalidBaseURL(
                validatedHTTPBaseURL.absoluteString
            )
        }
        webSocketComponents.scheme = baseComponents.scheme == "https"
            ? "wss"
            : "ws"
        guard let webSocketURL = webSocketComponents.url else {
            throw CodexRemoteControlWebSocketFailure.invalidBaseURL(
                validatedHTTPBaseURL.absoluteString
            )
        }

        guard !enrollment.remoteControlToken.isEmpty else {
            throw CodexRemoteControlWebSocketFailure
                .missingRemoteControlToken
        }
        try validateHeader(enrollment.serverID, name: "x-codex-server-id")
        try validateHeader(serverName, name: "x-codex-name")
        try validateHeader(
            enrollment.remoteControlToken,
            name: "authorization"
        )
        try validateHeader(
            installationID,
            name: "x-codex-installation-id"
        )
        if let subscribeCursor {
            try validateHeader(
                subscribeCursor,
                name: "x-codex-subscribe-cursor"
            )
        }

        var request = URLRequest(url: webSocketURL)
        request.httpMethod = "GET"
        request.setValue(
            enrollment.serverID,
            forHTTPHeaderField: "x-codex-server-id"
        )
        request.setValue(
            Data(serverName.utf8).base64EncodedString(),
            forHTTPHeaderField: "x-codex-name"
        )
        request.setValue(
            protocolVersion,
            forHTTPHeaderField: "x-codex-protocol-version"
        )
        request.setValue(
            "Bearer \(enrollment.remoteControlToken)",
            forHTTPHeaderField: "authorization"
        )
        request.setValue(
            installationID,
            forHTTPHeaderField: "x-codex-installation-id"
        )
        if let subscribeCursor {
            request.setValue(
                subscribeCursor,
                forHTTPHeaderField: "x-codex-subscribe-cursor"
            )
        }
        return request
    }

    private static func validateHeader(
        _ value: String,
        name: String
    ) throws {
        guard !value.isEmpty,
              value.unicodeScalars.allSatisfy({ scalar in
                  let code = scalar.value
                  return code >= 0x20 && code != 0x7F
              })
        else {
            throw CodexRemoteControlWebSocketFailure.invalidHeader(name: name)
        }
    }
}

public enum CodexRemoteControlReconnectBackoff {
    public static func delay(
        attempt: Int,
        cap: Duration = .seconds(30)
    ) -> Duration {
        var result = Duration.milliseconds(200)
        guard attempt > 0 else {
            return min(result, cap)
        }
        for _ in 0 ..< attempt {
            guard result < cap else {
                return cap
            }
            result += result
        }
        return min(result, cap)
    }
}

public final class CodexRemoteControlURLSessionWebSocketConnector:
    CodexRemoteControlWebSocketConnecting,
    @unchecked Sendable
{
    private let configuration: URLSessionConfiguration

    public init(configuration: URLSessionConfiguration = .default) {
        self.configuration = configuration
    }

    public func connect(
        request: URLRequest
    ) async throws -> any CodexRemoteControlWebSocketSocket {
        let delegate = CodexRemoteControlURLSessionHandshakeDelegate()
        let session = URLSession(
            configuration: configuration,
            delegate: delegate,
            delegateQueue: nil
        )
        let task = session.webSocketTask(with: request)
        do {
            try await delegate.waitForOpen(task: task)
            return CodexRemoteControlURLSessionWebSocketSocket(
                task: task,
                session: session
            )
        } catch {
            task.cancel(with: .goingAway, reason: nil)
            session.invalidateAndCancel()
            throw error
        }
    }
}

private final class CodexRemoteControlURLSessionHandshakeDelegate:
    NSObject,
    URLSessionWebSocketDelegate,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, any Error>?
    private var completedResult: Result<Void, any Error>?

    func waitForOpen(task: URLSessionWebSocketTask) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if let completedResult {
                    lock.unlock()
                    continuation.resume(with: completedResult)
                    return
                }
                self.continuation = continuation
                lock.unlock()
                task.resume()
            }
        } onCancel: {
            task.cancel(with: .goingAway, reason: nil)
        }
    }

    func urlSession(
        _: URLSession,
        webSocketTask _: URLSessionWebSocketTask,
        didOpenWithProtocol _: String?
    ) {
        finish(.success(()))
    }

    func urlSession(
        _: URLSession,
        webSocketTask _: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        finish(
            .failure(
                CodexRemoteControlWebSocketFailure.disconnected(
                    code: Int(closeCode.rawValue),
                    reason: reason.map {
                        String(decoding: $0, as: UTF8.self)
                    }
                )
            )
        )
    }

    func urlSession(
        _: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: (any Error)?
    ) {
        if let response = task.response as? HTTPURLResponse,
           response.statusCode != 101
        {
            let headers = response.allHeaderFields.reduce(
                into: [String: String]()
            ) { result, field in
                result[String(describing: field.key)] =
                    String(describing: field.value)
            }
            finish(
                .failure(
                    CodexRemoteControlWebSocketFailure.http(
                        .classify(
                            statusCode: response.statusCode,
                            headers: headers,
                            body: nil
                        )
                    )
                )
            )
        } else if let error {
            finish(
                .failure(
                    CodexRemoteControlWebSocketFailure.transport(
                        String(describing: error)
                    )
                )
            )
        } else {
            finish(
                .failure(
                    CodexRemoteControlWebSocketFailure.transport(
                        "handshake ended before HTTP Upgrade"
                    )
                )
            )
        }
    }

    private func finish(_ result: Result<Void, any Error>) {
        lock.lock()
        guard completedResult == nil else {
            lock.unlock()
            return
        }
        completedResult = result
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}

private final class CodexRemoteControlURLSessionWebSocketSocket:
    CodexRemoteControlWebSocketSocket,
    @unchecked Sendable
{
    private let task: URLSessionWebSocketTask
    private let session: URLSession

    init(task: URLSessionWebSocketTask, session: URLSession) {
        self.task = task
        self.session = session
    }

    func send(text: String) async throws {
        try await task.send(.string(text))
    }

    func sendPing() async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, any Error>) in
            task.sendPing { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }

    func receive() async throws -> CodexRemoteControlWebSocketFrame {
        switch try await task.receive() {
        case let .string(text):
            .text(text)
        case let .data(data):
            .binary(data)
        @unknown default:
            throw CodexRemoteControlWebSocketFailure.transport(
                "unsupported URLSession WebSocket message"
            )
        }
    }

    func close() async {
        task.cancel(with: .goingAway, reason: nil)
        session.finishTasksAndInvalidate()
    }
}

private actor CodexRemoteControlWebSocketWriter {
    let socket: any CodexRemoteControlWebSocketSocket

    init(socket: any CodexRemoteControlWebSocketSocket) {
        self.socket = socket
    }

    func send(
        envelopes: [CodexRemoteControlServerEnvelope]
    ) async throws {
        for envelope in envelopes {
            let data: Data
            do {
                data = try CodexRemoteControlWebSocketCodec.encode(envelope)
            } catch let error as CodexRemoteControlWebSocketProtocolError {
                throw error
            } catch {
                throw CodexRemoteControlWebSocketProtocolError.encodingFailed(
                    String(describing: error)
                )
            }
            try await socket.send(
                text: String(decoding: data, as: UTF8.self)
            )
        }
    }
}

private struct CodexRemoteControlWireCursor: Hashable, Sendable {
    let clientID: String
    let streamID: String
    let sequenceID: UInt64
    let segmentID: Int

    init(_ envelope: CodexRemoteControlServerEnvelope) {
        clientID = envelope.clientID
        streamID = envelope.streamID
        sequenceID = envelope.seqID
        segmentID = envelope.event.segmentID ?? 0
    }
}

private enum CodexRemoteControlTimeoutMarker: Error {
    case elapsed
}

public typealias CodexRemoteControlInboundHandler =
    @Sendable (CodexRemoteControlClientEnvelope) async throws -> Void
public typealias CodexRemoteControlWebSocketStatusHandler =
    @Sendable (CodexRemoteControlWebSocketStatus) async -> Void

public actor CodexRemoteControlWebSocketTransport {
    private let validatedHTTPBaseURL: URL
    private let enrollment: CodexRemoteControlHTTPEnrollment
    private let serverName: String
    private let installationID: String
    private let connector: any CodexRemoteControlWebSocketConnecting
    private let configuration: CodexRemoteControlWebSocketConfiguration
    private let inboundHandler: CodexRemoteControlInboundHandler
    private let statusHandler: CodexRemoteControlWebSocketStatusHandler
    private let clock = ContinuousClock()

    private var protocolState: CodexRemoteControlWebSocketProtocolState
    private var socket: (any CodexRemoteControlWebSocketSocket)?
    private var writer: CodexRemoteControlWebSocketWriter?
    private var connectionGeneration: UInt64 = 0
    private var stopRequested = false

    public private(set) var status: CodexRemoteControlWebSocketStatus =
        .disconnected
    public private(set) var pongDeadline: ContinuousClock.Instant?
    public private(set) var lastFailure: CodexRemoteControlWebSocketFailure?

    public init(
        validatedHTTPBaseURL: URL,
        enrollment: CodexRemoteControlHTTPEnrollment,
        serverName: String,
        installationID: String,
        connector: any CodexRemoteControlWebSocketConnecting =
            CodexRemoteControlURLSessionWebSocketConnector(),
        configuration: CodexRemoteControlWebSocketConfiguration = .init(),
        initialSubscribeCursor: String? = nil,
        inboundHandler: @escaping CodexRemoteControlInboundHandler = { _ in },
        statusHandler: @escaping CodexRemoteControlWebSocketStatusHandler = {
            _ in
        }
    ) throws {
        _ = try CodexRemoteControlWebSocketRequest.make(
            validatedHTTPBaseURL: validatedHTTPBaseURL,
            enrollment: enrollment,
            serverName: serverName,
            installationID: installationID,
            subscribeCursor: initialSubscribeCursor
        )
        self.validatedHTTPBaseURL = validatedHTTPBaseURL
        self.enrollment = enrollment
        self.serverName = serverName
        self.installationID = installationID
        self.connector = connector
        self.configuration = configuration
        protocolState = CodexRemoteControlWebSocketProtocolState(
            subscribeCursor: initialSubscribeCursor
        )
        self.inboundHandler = inboundHandler
        self.statusHandler = statusHandler
    }

    public var subscribeCursor: String? {
        protocolState.subscribeCursor
    }

    public var replayEnvelopes: [CodexRemoteControlServerEnvelope] {
        protocolState.replayEnvelopes
    }

    public func connectOnce() async throws {
        guard socket == nil, status != .connecting else {
            throw CodexRemoteControlWebSocketFailure.transport(
                "remote-control WebSocket is already connecting"
            )
        }
        stopRequested = false
        let attemptGeneration = connectionGeneration
        await publish(.connecting)
        guard !stopRequested, connectionGeneration == attemptGeneration else {
            throw CancellationError()
        }
        let request = try CodexRemoteControlWebSocketRequest.make(
            validatedHTTPBaseURL: validatedHTTPBaseURL,
            enrollment: enrollment,
            serverName: serverName,
            installationID: installationID,
            subscribeCursor: protocolState.subscribeCursor
        )

        do {
            let connectedSocket: any CodexRemoteControlWebSocketSocket =
                try await withTimeout(configuration.connectTimeout) {
                    try await self.connector.connect(request: request)
                }
            guard !stopRequested, connectionGeneration == attemptGeneration else {
                await connectedSocket.close()
                throw CancellationError()
            }
            connectionGeneration = connectionGeneration == UInt64.max
                ? 1
                : connectionGeneration + 1
            let activeGeneration = connectionGeneration
            let candidateWriter = CodexRemoteControlWebSocketWriter(
                socket: connectedSocket
            )
            socket = connectedSocket
            writer = candidateWriter
            pongDeadline = clock.now.advanced(by: configuration.pongTimeout)
            try await replayUntilCaughtUp(using: candidateWriter)
            guard !stopRequested,
                  connectionGeneration == activeGeneration,
                  socket != nil
            else {
                throw CancellationError()
            }
            lastFailure = nil
            await publish(.connected)
        } catch CodexRemoteControlTimeoutMarker.elapsed {
            await abandonConnection()
            let failure = CodexRemoteControlWebSocketFailure.connectTimedOut
            lastFailure = failure
            await publish(.disconnected)
            throw failure
        } catch {
            await abandonConnection()
            let failure = mapFailure(error)
            lastFailure = failure
            await publish(.disconnected)
            throw failure
        }
    }

    public func send(
        event: CodexRemoteControlServerEvent,
        clientID: String,
        streamID: String
    ) async throws {
        let envelopes: [CodexRemoteControlServerEnvelope]
        do {
            envelopes = try protocolState.prepareOutbound(
                event: event,
                clientID: clientID,
                streamID: streamID
            )
        } catch let error as CodexRemoteControlWebSocketProtocolError {
            throw CodexRemoteControlWebSocketFailure.protocolFailure(error)
        }
        guard status == .connected, let writer else {
            return
        }
        do {
            try await writer.send(envelopes: envelopes)
        } catch {
            let failure = mapFailure(error)
            lastFailure = failure
            await abandonConnection()
            await publish(.disconnected)
            throw failure
        }
    }

    @discardableResult
    public func processInboundFrame(
        _ frame: CodexRemoteControlWebSocketFrame
    ) async throws -> CodexRemoteControlInboundAction {
        switch frame {
        case let .text(text):
            let action = protocolState.observeInboundText(text)
            guard case let .deliver(delivery) = action else {
                return action
            }
            do {
                try await inboundHandler(delivery.envelope)
            } catch {
                throw CodexRemoteControlWebSocketFailure.inboundHandler(
                    String(describing: error)
                )
            }
            protocolState.confirmDelivered(delivery)
            return action
        case .pong:
            recordConfirmedPong(generation: connectionGeneration)
            return .ignored
        case .ping, .binary:
            return .ignored
        case let .closed(code, reason):
            throw CodexRemoteControlWebSocketFailure.disconnected(
                code: code,
                reason: reason
            )
        }
    }

    public func run() async throws {
        stopRequested = false
        var reconnectAttempt = 0
        while !stopRequested && !Task.isCancelled {
            do {
                try await connectOnce()
                reconnectAttempt = 0
                let generation = connectionGeneration
                try await runConnected(generation: generation)
            } catch {
                let failure = mapFailure(error)
                lastFailure = failure
                if failure.requiresUpperLayerRecovery {
                    await abandonConnection()
                    await publish(.disconnected)
                    throw failure
                }
            }
            await abandonConnection()
            if stopRequested || Task.isCancelled {
                break
            }
            let delay = CodexRemoteControlReconnectBackoff.delay(
                attempt: reconnectAttempt,
                cap: configuration.reconnectBackoffCap
            )
            await publish(
                .reconnecting(attempt: reconnectAttempt, delay: delay)
            )
            do {
                try await Task.sleep(for: delay)
            } catch {
                break
            }
            reconnectAttempt = delay >= configuration.reconnectBackoffCap
                ? 0
                : (reconnectAttempt == Int.max ? Int.max : reconnectAttempt + 1)
        }
        await abandonConnection()
        await publish(.stopped)
    }

    public func disconnect() async throws {
        stopRequested = true
        let socketToClose = socket
        socket = nil
        writer = nil
        pongDeadline = nil
        connectionGeneration = connectionGeneration == UInt64.max
            ? 1
            : connectionGeneration + 1
        await publish(.disconnected)
        guard let socketToClose else {
            return
        }
        do {
            try await withTimeout(configuration.shutdownTimeout) {
                await socketToClose.close()
            }
        } catch CodexRemoteControlTimeoutMarker.elapsed {
            let failure = CodexRemoteControlWebSocketFailure.shutdownTimedOut
            lastFailure = failure
            throw failure
        } catch {
            let failure = mapFailure(error)
            lastFailure = failure
            throw failure
        }
    }

    private func runConnected(generation: UInt64) async throws {
        guard let socket else {
            throw CodexRemoteControlWebSocketFailure.transport(
                "connected loop started without a socket"
            )
        }
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    while !Task.isCancelled {
                        let frame = try await socket.receive()
                        _ = try await self.processInboundFrame(frame)
                    }
                }
                group.addTask {
                    while !Task.isCancelled {
                        try await Task.sleep(for: self.configuration.pingInterval)
                        try await socket.sendPing()
                        await self.recordConfirmedPong(generation: generation)
                    }
                }
                group.addTask {
                    let interval = min(
                        Duration.seconds(1),
                        self.configuration.pingInterval
                    )
                    while !Task.isCancelled {
                        try await Task.sleep(for: interval)
                        try await self.checkPongDeadline(generation: generation)
                    }
                }
                do {
                    _ = try await group.next()
                    throw CodexRemoteControlWebSocketFailure.transport(
                        "remote-control connection worker ended"
                    )
                } catch {
                    group.cancelAll()
                    do {
                        try await withTimeout(configuration.shutdownTimeout) {
                            await socket.close()
                        }
                    } catch CodexRemoteControlTimeoutMarker.elapsed {
                        throw CodexRemoteControlWebSocketFailure
                            .shutdownTimedOut
                    } catch {
                        throw mapFailure(error)
                    }
                    throw error
                }
            }
        } catch {
            throw mapFailure(error)
        }
    }

    private func checkPongDeadline(generation: UInt64) throws {
        guard generation == connectionGeneration,
              let pongDeadline
        else {
            return
        }
        if clock.now >= pongDeadline {
            throw CodexRemoteControlWebSocketFailure.pongTimedOut
        }
    }

    private func recordConfirmedPong(generation: UInt64) {
        guard generation == connectionGeneration else {
            return
        }
        pongDeadline = clock.now.advanced(by: configuration.pongTimeout)
    }

    private func replayUntilCaughtUp(
        using writer: CodexRemoteControlWebSocketWriter
    ) async throws {
        var sent = Set<CodexRemoteControlWireCursor>()
        while true {
            let pending = protocolState.replayEnvelopes.filter {
                !sent.contains(CodexRemoteControlWireCursor($0))
            }
            guard !pending.isEmpty else {
                return
            }
            try await writer.send(envelopes: pending)
            sent.formUnion(pending.map(CodexRemoteControlWireCursor.init))
        }
    }

    private func abandonConnection() async {
        let socketToClose = socket
        socket = nil
        writer = nil
        pongDeadline = nil
        connectionGeneration = connectionGeneration == UInt64.max
            ? 1
            : connectionGeneration + 1
        if let socketToClose {
            do {
                try await withTimeout(configuration.shutdownTimeout) {
                    await socketToClose.close()
                }
            } catch {
                // The connection is already detached. Preserve the original
                // failure while enforcing the bounded shutdown wait.
            }
        }
    }

    private func publish(
        _ newStatus: CodexRemoteControlWebSocketStatus
    ) async {
        status = newStatus
        await statusHandler(newStatus)
    }

    private func mapFailure(
        _ error: any Error
    ) -> CodexRemoteControlWebSocketFailure {
        if let failure = error as? CodexRemoteControlWebSocketFailure {
            return failure
        }
        if let protocolError = error
            as? CodexRemoteControlWebSocketProtocolError
        {
            return .protocolFailure(protocolError)
        }
        return .transport(String(describing: error))
    }

    private func withTimeout<T: Sendable>(
        _ timeout: Duration,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw CodexRemoteControlTimeoutMarker.elapsed
            }
            guard let first = try await group.next() else {
                throw CodexRemoteControlTimeoutMarker.elapsed
            }
            group.cancelAll()
            return first
        }
    }
}
