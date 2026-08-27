#if SWIFT_PACKAGE
    import CodexPadDomain
    import CodexPadProtocolBridge
#endif
import Foundation

public struct CodexRemoteControlVirtualSessionIdentity:
    Hashable,
    Equatable,
    Sendable
{
    public let clientID: String
    public let streamID: String

    public init(clientID: String, streamID: String) {
        self.clientID = clientID
        self.streamID = streamID
    }

    public var desktopHostID: String {
        "remote:\(clientID):\(streamID)"
    }
}

public struct CodexRemoteControlVirtualSessionOutput: Equatable, Sendable {
    public let identity: CodexRemoteControlVirtualSessionIdentity
    public let event: CodexRemoteControlServerEvent

    public init(
        identity: CodexRemoteControlVirtualSessionIdentity,
        event: CodexRemoteControlServerEvent
    ) {
        self.identity = identity
        self.event = event
    }
}

public protocol CodexRemoteControlVirtualSession: Sendable {
    func receive(_ message: CodexJSONValue) async -> CodexJSONValue?
    func close() async
}

public actor CodexRemoteControlVirtualSessionRouter {
    public typealias SessionFactory = @Sendable (
        CodexRemoteControlVirtualSessionIdentity
    ) async -> any CodexRemoteControlVirtualSession

    private let makeSession: SessionFactory
    private var sessions: [
        CodexRemoteControlVirtualSessionIdentity:
            any CodexRemoteControlVirtualSession
    ] = [:]
    private var generations: [
        CodexRemoteControlVirtualSessionIdentity: UInt64
    ] = [:]

    public init(makeSession: @escaping SessionFactory) {
        self.makeSession = makeSession
    }

    public var activeSessionCount: Int { sessions.count }

    public func receive(
        _ envelope: CodexRemoteControlClientEnvelope
    ) async -> CodexRemoteControlVirtualSessionOutput? {
        switch envelope.event {
        case let .clientMessage(message):
            guard let streamID = envelope.streamID else { return nil }
            let identity = CodexRemoteControlVirtualSessionIdentity(
                clientID: envelope.clientID,
                streamID: streamID
            )
            return await receive(message, identity: identity)

        case .clientClosed:
            guard let streamID = envelope.streamID else { return nil }
            await close(
                identity: .init(
                    clientID: envelope.clientID,
                    streamID: streamID
                )
            )
            return nil

        case .clientMessageChunk, .ack, .ping:
            return nil
        }
    }

    /// Socket reconnects and enable/disable cycles retain logical sessions.
    /// Only an exact `client_closed`, reinitialize, or full shutdown tears down
    /// a virtual session.
    public func transportConnectionDidReset() {}

    public func shutdown() async {
        let active = Array(sessions.values)
        let identities = Array(sessions.keys)
        sessions.removeAll(keepingCapacity: true)
        for identity in identities {
            advanceGeneration(for: identity)
        }
        for session in active {
            await session.close()
        }
    }

    private func receive(
        _ message: CodexJSONValue,
        identity: CodexRemoteControlVirtualSessionIdentity
    ) async -> CodexRemoteControlVirtualSessionOutput? {
        let shape = CodexRemoteControlJSONRPCShape(message)
        if shape.isInitializeNotification {
            return nil
        }
        if shape.isInitializeRequest {
            return await replaceSessionAndReceiveInitialize(
                message,
                identity: identity
            )
        }
        guard let session = sessions[identity] else { return nil }
        let generation = generations[identity] ?? 0
        let response = await session.receive(message)
        guard generations[identity] == generation,
              sessions[identity] != nil,
              let response
        else { return nil }
        return .init(identity: identity, event: .serverMessage(response))
    }

    private func replaceSessionAndReceiveInitialize(
        _ message: CodexJSONValue,
        identity: CodexRemoteControlVirtualSessionIdentity
    ) async -> CodexRemoteControlVirtualSessionOutput? {
        let generation = advanceGeneration(for: identity)
        if let old = sessions.removeValue(forKey: identity) {
            await old.close()
        }

        let session = await makeSession(identity)
        guard generations[identity] == generation,
              sessions[identity] == nil
        else {
            await session.close()
            return nil
        }
        sessions[identity] = session
        let response = await session.receive(message)
        guard generations[identity] == generation,
              sessions[identity] != nil,
              let response
        else { return nil }
        return .init(identity: identity, event: .serverMessage(response))
    }

    private func close(
        identity: CodexRemoteControlVirtualSessionIdentity
    ) async {
        advanceGeneration(for: identity)
        guard let session = sessions.removeValue(forKey: identity) else {
            return
        }
        await session.close()
    }

    @discardableResult
    private func advanceGeneration(
        for identity: CodexRemoteControlVirtualSessionIdentity
    ) -> UInt64 {
        let current = generations[identity] ?? 0
        let next = current == UInt64.max ? 0 : current + 1
        generations[identity] = next
        return next
    }
}


/// Adapts the WebSocket transport's inbound callback to the logical-session
/// router and emits any JSON-RPC response through the transport's send path.
public struct CodexRemoteControlVirtualSessionIngress: Sendable {
    public typealias Send = @Sendable (
        CodexRemoteControlServerEvent,
        String,
        String
    ) async throws -> Void

    private let router: CodexRemoteControlVirtualSessionRouter
    private let send: Send

    public init(
        router: CodexRemoteControlVirtualSessionRouter,
        send: @escaping Send
    ) {
        self.router = router
        self.send = send
    }

    public func handle(
        _ envelope: CodexRemoteControlClientEnvelope
    ) async throws {
        guard let output = await router.receive(envelope) else { return }
        try await send(
            output.event,
            output.identity.clientID,
            output.identity.streamID
        )
    }
}

public actor CodexRemoteControlDesktopSemanticSession:
    CodexRemoteControlVirtualSession
{
    public typealias RequestRoute = @Sendable (
        CodexDesktopMCPRequest
    ) async -> CodexDesktopHostMessage?
    public typealias NonRequestReceiver = @Sendable (
        CodexJSONValue
    ) async -> Void
    public typealias CloseHandler = @Sendable () async -> Void

    private let identity: CodexRemoteControlVirtualSessionIdentity
    private let routeRequest: RequestRoute
    private let receiveNonRequest: NonRequestReceiver
    private let closeHandler: CloseHandler
    private var isClosed = false

    public init(
        identity: CodexRemoteControlVirtualSessionIdentity,
        routeRequest: @escaping RequestRoute,
        receiveNonRequest: @escaping NonRequestReceiver = { _ in },
        close: @escaping CloseHandler = {}
    ) {
        self.identity = identity
        self.routeRequest = routeRequest
        self.receiveNonRequest = receiveNonRequest
        closeHandler = close
    }

    public func receive(_ message: CodexJSONValue) async -> CodexJSONValue? {
        guard !isClosed else { return nil }
        guard let request = CodexRemoteControlJSONRPCShape(message)
            .desktopRequest(identity: identity)
        else {
            await receiveNonRequest(message)
            return nil
        }
        guard let response = await routeRequest(request) else { return nil }
        guard case let .mcpResponse(hostID, responseMessage, _) = response,
              hostID == request.hostID
        else { return nil }
        return responseMessage
    }

    public func close() async {
        guard !isClosed else { return }
        isClosed = true
        await closeHandler()
    }
}

private struct CodexRemoteControlJSONRPCShape {
    let fields: [String: CodexJSONValue]?
    let method: String?
    let id: CodexAppServerRequestID?

    init(_ message: CodexJSONValue) {
        guard case let .object(fields) = message,
              fields["jsonrpc"] == .string("2.0")
        else {
            self.fields = nil
            method = nil
            id = nil
            return
        }
        self.fields = fields
        if case let .string(value)? = fields["method"] {
            method = value
        } else {
            method = nil
        }
        switch fields["id"] {
        case let .string(value)?: id = .string(value)
        case let .integer(value)?: id = .integer(value)
        default: id = nil
        }
    }

    var isInitializeRequest: Bool {
        method == "initialize" && id != nil
    }

    var isInitializeNotification: Bool {
        method == "initialize" && id == nil
    }

    func desktopRequest(
        identity: CodexRemoteControlVirtualSessionIdentity
    ) -> CodexDesktopMCPRequest? {
        guard let fields, let method, let id else { return nil }
        let params = fields["params"]
        return .init(
            request: .init(
                id: id,
                method: method,
                params: params,
                metadata: [:]
            ),
            hostID: identity.desktopHostID,
            dispatchedAtMs: nil,
            priority: nil,
            source: .string("remoteControl"),
            timeoutMs: nil,
            expiresAtMs: nil,
            metadata: [
                "remoteClientId": .string(identity.clientID),
                "remoteStreamId": .string(identity.streamID),
            ]
        )
    }
}
