import Foundation
import Testing
@testable import CodexPadApplication
@testable import CodexPadDomain
@testable import CodexPadProtocolBridge

private actor VirtualSessionProbe: CodexRemoteControlVirtualSession {
    let identity: CodexRemoteControlVirtualSessionIdentity
    private var messages: [CodexJSONValue] = []
    private var closeCount = 0

    init(identity: CodexRemoteControlVirtualSessionIdentity) {
        self.identity = identity
    }

    func receive(_ message: CodexJSONValue) async -> CodexJSONValue? {
        messages.append(message)
        guard case let .object(fields) = message,
              let id = fields["id"]
        else { return nil }
        return .object(["jsonrpc": .string("2.0"), "id": id, "result": .object(["ok": .bool(true)])])
    }

    func close() async { closeCount += 1 }

    func snapshot() -> (messages: [CodexJSONValue], closeCount: Int) {
        (messages, closeCount)
    }
}

private actor VirtualSessionFactoryProbe {
    private var sessions: [VirtualSessionProbe] = []

    func make(identity: CodexRemoteControlVirtualSessionIdentity) -> any CodexRemoteControlVirtualSession {
        let session = VirtualSessionProbe(identity: identity)
        sessions.append(session)
        return session
    }

    func allSessions() -> [VirtualSessionProbe] { sessions }
}

private func clientMessage(
    _ message: CodexJSONValue,
    clientID: String = "client-1",
    streamID: String? = "stream-1"
) -> CodexRemoteControlClientEnvelope {
    .init(event: .clientMessage(message), clientID: clientID, streamID: streamID, seqID: 1, cursor: nil)
}

private func requestMessage(
    id: CodexJSONValue = .integer(1),
    method: String,
    params: CodexJSONValue = .object([:])
) -> CodexJSONValue {
    .object(["jsonrpc": .string("2.0"), "id": id, "method": .string(method), "params": params])
}

private func notificationMessage(method: String) -> CodexJSONValue {
    .object(["jsonrpc": .string("2.0"), "method": .string(method), "params": .object([:])])
}

private func makeRouter(_ factory: VirtualSessionFactoryProbe) -> CodexRemoteControlVirtualSessionRouter {
    CodexRemoteControlVirtualSessionRouter { identity in
        await factory.make(identity: identity)
    }
}

@Test
func requestInitializeCreatesExactVirtualSessionAndReturnsOnSameStream() async throws {
    let factory = VirtualSessionFactoryProbe()
    let router = makeRouter(factory)
    let output = await router.receive(clientMessage(requestMessage(method: "initialize")))

    #expect(output == .init(
        identity: .init(clientID: "client-1", streamID: "stream-1"),
        event: .serverMessage(.object([
            "jsonrpc": .string("2.0"), "id": .integer(1),
            "result": .object(["ok": .bool(true)]),
        ]))
    ))
    #expect(await router.activeSessionCount == 1)
    let sessions = await factory.allSessions()
    #expect(sessions.count == 1)
    #expect(await sessions[0].snapshot().messages == [requestMessage(method: "initialize")])
}

@Test
func initializeNotificationNeverCreatesSession() async {
    let factory = VirtualSessionFactoryProbe()
    let router = makeRouter(factory)
    #expect(await router.receive(clientMessage(notificationMessage(method: "initialize"))) == nil)
    #expect(await router.activeSessionCount == 0)
    #expect(await factory.allSessions().isEmpty)
}

@Test
func preInitializeTrafficIsSilentlyDropped() async {
    let factory = VirtualSessionFactoryProbe()
    let router = makeRouter(factory)
    let fixtures: [CodexJSONValue] = [
        requestMessage(method: "thread/list"),
        notificationMessage(method: "initialized"),
        .object(["jsonrpc": .string("2.0"), "id": .integer(7), "result": .object([:])]),
    ]
    for fixture in fixtures {
        #expect(await router.receive(clientMessage(fixture)) == nil)
    }
    #expect(await factory.allSessions().isEmpty)
}

@Test
func reinitializeClosesOldSessionBeforeReplacingIt() async {
    let factory = VirtualSessionFactoryProbe()
    let router = makeRouter(factory)
    _ = await router.receive(clientMessage(requestMessage(id: .integer(1), method: "initialize")))
    _ = await router.receive(clientMessage(requestMessage(id: .integer(2), method: "initialize")))

    let sessions = await factory.allSessions()
    #expect(sessions.count == 2)
    #expect(await sessions[0].snapshot().closeCount == 1)
    #expect(await sessions[1].snapshot().closeCount == 0)
    #expect(await router.activeSessionCount == 1)
}

@Test
func streamsForSameClientRemainIndependent() async {
    let factory = VirtualSessionFactoryProbe()
    let router = makeRouter(factory)
    _ = await router.receive(clientMessage(requestMessage(method: "initialize"), streamID: "stream-a"))
    _ = await router.receive(clientMessage(requestMessage(method: "initialize"), streamID: "stream-b"))
    _ = await router.receive(clientMessage(requestMessage(id: .integer(3), method: "thread/list"), streamID: "stream-b"))

    #expect(await router.activeSessionCount == 2)
    let sessions = await factory.allSessions()
    #expect(await sessions[0].snapshot().messages.count == 1)
    #expect(await sessions[1].snapshot().messages.count == 2)
}

@Test
func clientClosedClosesOnlyExactStream() async {
    let factory = VirtualSessionFactoryProbe()
    let router = makeRouter(factory)
    _ = await router.receive(clientMessage(requestMessage(method: "initialize"), streamID: "stream-a"))
    _ = await router.receive(clientMessage(requestMessage(method: "initialize"), streamID: "stream-b"))
    let closed = CodexRemoteControlClientEnvelope(event: .clientClosed, clientID: "client-1", streamID: "stream-a", seqID: nil, cursor: nil)
    #expect(await router.receive(closed) == nil)

    let sessions = await factory.allSessions()
    #expect(await sessions[0].snapshot().closeCount == 1)
    #expect(await sessions[1].snapshot().closeCount == 0)
    #expect(await router.activeSessionCount == 1)
}

@Test
func missingStreamIdentityDoesNotCreateOrCloseSessions() async {
    let factory = VirtualSessionFactoryProbe()
    let router = makeRouter(factory)
    #expect(await router.receive(clientMessage(requestMessage(method: "initialize"), streamID: nil)) == nil)
    let closed = CodexRemoteControlClientEnvelope(event: .clientClosed, clientID: "client-1", streamID: nil, seqID: nil, cursor: nil)
    #expect(await router.receive(closed) == nil)
    #expect(await router.activeSessionCount == 0)
}

@Test
func transportReconnectDoesNotTearDownLogicalSessionsButShutdownDoes() async {
    let factory = VirtualSessionFactoryProbe()
    let router = makeRouter(factory)
    _ = await router.receive(clientMessage(requestMessage(method: "initialize")))
    await router.transportConnectionDidReset()
    #expect(await router.activeSessionCount == 1)
    let sessions = await factory.allSessions()
    #expect(await sessions[0].snapshot().closeCount == 0)

    await router.shutdown()
    #expect(await router.activeSessionCount == 0)
    #expect(await sessions[0].snapshot().closeCount == 1)
}

private actor DesktopSemanticProbe {
    private var requests: [CodexDesktopMCPRequest] = []
    private var inboundMessages: [CodexJSONValue] = []

    func route(_ request: CodexDesktopMCPRequest) -> CodexDesktopHostMessage? {
        requests.append(request)
        return .mcpResponse(
            hostID: request.hostID,
            message: .object(["jsonrpc": .string("2.0"), "id": .integer(44), "result": .string("shared-router")]),
            metadata: [:]
        )
    }

    func consume(_ message: CodexJSONValue) { inboundMessages.append(message) }
    func snapshot() -> (requests: [CodexDesktopMCPRequest], inbound: [CodexJSONValue]) { (requests, inboundMessages) }
}

@Test
func desktopSemanticSessionMapsRequestsAndConsumesNotificationsAndResponses() async {
    let probe = DesktopSemanticProbe()
    let identity = CodexRemoteControlVirtualSessionIdentity(clientID: "client-x", streamID: "stream-y")
    let session = CodexRemoteControlDesktopSemanticSession(
        identity: identity,
        routeRequest: { request in await probe.route(request) },
        receiveNonRequest: { message in await probe.consume(message) }
    )

    let routed = await session.receive(requestMessage(id: .integer(44), method: "thread/read", params: .object(["threadId": .string("t-1")])))
    #expect(routed == .object(["jsonrpc": .string("2.0"), "id": .integer(44), "result": .string("shared-router")]))
    _ = await session.receive(notificationMessage(method: "initialized"))
    let response: CodexJSONValue = .object(["jsonrpc": .string("2.0"), "id": .integer(9), "result": .null])
    _ = await session.receive(response)

    let snapshot = await probe.snapshot()
    #expect(snapshot.requests.count == 1)
    #expect(snapshot.requests[0].hostID == "remote:client-x:stream-y")
    #expect(snapshot.requests[0].request.method == "thread/read")
    #expect(snapshot.requests[0].request.id == .integer(44))
    #expect(snapshot.inbound == [notificationMessage(method: "initialized"), response])
}

private actor VirtualSessionSendProbe {
    private var values: [(CodexRemoteControlServerEvent, String, String)] = []
    func send(_ event: CodexRemoteControlServerEvent, clientID: String, streamID: String) {
        values.append((event, clientID, streamID))
    }
    func snapshot() -> [(CodexRemoteControlServerEvent, String, String)] { values }
}

@Test
func ingressBridgesRouterResponseToTransportSendIdentity() async throws {
    let factory = VirtualSessionFactoryProbe()
    let router = makeRouter(factory)
    let sent = VirtualSessionSendProbe()
    let ingress = CodexRemoteControlVirtualSessionIngress(
        router: router,
        send: { event, clientID, streamID in
            await sent.send(event, clientID: clientID, streamID: streamID)
        }
    )

    try await ingress.handle(clientMessage(
        requestMessage(id: .string("init-x"), method: "initialize"),
        clientID: "client-x",
        streamID: "stream-y"
    ))
    let values = await sent.snapshot()
    #expect(values.count == 1)
    #expect(values[0].1 == "client-x")
    #expect(values[0].2 == "stream-y")
    #expect(values[0].0 == .serverMessage(.object([
        "jsonrpc": .string("2.0"), "id": .string("init-x"),
        "result": .object(["ok": .bool(true)]),
    ])))
}
