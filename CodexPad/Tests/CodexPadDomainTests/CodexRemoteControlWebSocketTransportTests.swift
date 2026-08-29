import CodexPadDomain
import Foundation
import Testing

@testable import CodexPadApplication

private enum RemoteWebSocketProbeError: Error, Equatable, Sendable {
    case exhausted
    case connectFailed
}

private actor RemoteWebSocketSocketProbe: CodexRemoteControlWebSocketSocket {
    private var frames: [CodexRemoteControlWebSocketFrame]
    private var sent: [String] = []
    private var pingCount = 0
    private var closeCount = 0
    private let closeDelay: Duration?

    init(
        frames: [CodexRemoteControlWebSocketFrame] = [],
        closeDelay: Duration? = nil
    ) {
        self.frames = frames
        self.closeDelay = closeDelay
    }

    func send(text: String) async throws {
        sent.append(text)
    }

    func sendPing() async throws {
        pingCount += 1
    }

    func receive() async throws -> CodexRemoteControlWebSocketFrame {
        guard !frames.isEmpty else {
            throw RemoteWebSocketProbeError.exhausted
        }
        return frames.removeFirst()
    }

    func close() async {
        closeCount += 1
        if let closeDelay {
            try? await Task.sleep(for: closeDelay)
        }
    }

    func sentTexts() -> [String] { sent }
    func pings() -> Int { pingCount }
    func closes() -> Int { closeCount }
}

private actor RemoteWebSocketConnectorProbe:
    CodexRemoteControlWebSocketConnecting
{
    private let socket: any CodexRemoteControlWebSocketSocket
    private var requests: [URLRequest] = []
    private let connectDelay: Duration?

    init(
        socket: any CodexRemoteControlWebSocketSocket,
        connectDelay: Duration? = nil
    ) {
        self.socket = socket
        self.connectDelay = connectDelay
    }

    func connect(
        request: URLRequest
    ) async throws -> any CodexRemoteControlWebSocketSocket {
        requests.append(request)
        if let connectDelay {
            try await Task.sleep(for: connectDelay)
        }
        return socket
    }

    func recordedRequests() -> [URLRequest] { requests }
}

private struct RemoteWebSocketFailingConnector:
    CodexRemoteControlWebSocketConnecting,
    Sendable
{
    let error: CodexRemoteControlWebSocketFailure

    func connect(
        request _: URLRequest
    ) async throws -> any CodexRemoteControlWebSocketSocket {
        throw error
    }
}

private actor RemoteWebSocketScriptedConnector:
    CodexRemoteControlWebSocketConnecting
{
    private let socket: any CodexRemoteControlWebSocketSocket
    private var attempt = 0

    init(socket: any CodexRemoteControlWebSocketSocket) {
        self.socket = socket
    }

    func connect(
        request _: URLRequest
    ) async throws -> any CodexRemoteControlWebSocketSocket {
        attempt += 1
        if attempt == 1 {
            throw RemoteWebSocketProbeError.connectFailed
        }
        return socket
    }
}

private actor RemoteWebSocketInboundProbe {
    private var envelopes: [CodexRemoteControlClientEnvelope] = []

    func handle(_ envelope: CodexRemoteControlClientEnvelope) {
        envelopes.append(envelope)
    }

    func received() -> [CodexRemoteControlClientEnvelope] { envelopes }
}

private actor RemoteWebSocketStatusProbe {
    private var values: [CodexRemoteControlWebSocketStatus] = []

    func record(_ status: CodexRemoteControlWebSocketStatus) {
        values.append(status)
    }

    func reconnects() -> [(attempt: Int, delay: Duration)] {
        values.compactMap { status in
            guard case let .reconnecting(attempt, delay) = status else {
                return nil
            }
            return (attempt, delay)
        }
    }
}

private let remoteWebSocketEnrollment = CodexRemoteControlHTTPEnrollment(
    serverID: "server-1",
    environmentID: "environment-1",
    remoteControlToken: "remote-token",
    expiresAt: 4_102_444_800
)

@Test
func remoteControlWebSocketRequestUsesOfficialURLAndHeaders() throws {
    let request = try CodexRemoteControlWebSocketRequest.make(
        validatedHTTPBaseURL: URL(
            string: "https://chatgpt.com/backend-api/"
        )!,
        enrollment: remoteWebSocketEnrollment,
        serverName: "Example iPad",
        installationID: "installation-1",
        subscribeCursor: "cursor-7"
    )

    #expect(
        request.url?.absoluteString
            == "wss://chatgpt.com/backend-api/wham/remote/control/server"
    )
    #expect(request.httpMethod == "GET")
    #expect(
        request.value(forHTTPHeaderField: "x-codex-server-id")
            == "server-1"
    )
    #expect(
        request.value(forHTTPHeaderField: "x-codex-name")
            == Data("Example iPad".utf8).base64EncodedString()
    )
    #expect(
        request.value(forHTTPHeaderField: "x-codex-protocol-version")
            == "3"
    )
    #expect(
        request.value(forHTTPHeaderField: "Authorization")
            == "Bearer remote-token"
    )
    #expect(
        request.value(forHTTPHeaderField: "x-codex-installation-id")
            == "installation-1"
    )
    #expect(
        request.value(forHTTPHeaderField: "x-codex-subscribe-cursor")
            == "cursor-7"
    )
}

@Test
func remoteControlWebSocketRequestMapsHTTPAndHTTPSAndRejectsHeaders()
    throws
{
    let local = try CodexRemoteControlWebSocketRequest.make(
        validatedHTTPBaseURL: URL(
            string: "http://localhost:7443/backend-api/"
        )!,
        enrollment: remoteWebSocketEnrollment,
        serverName: "iPad",
        installationID: "installation",
        subscribeCursor: nil
    )
    #expect(
        local.url?.absoluteString
            == "ws://localhost:7443/backend-api/wham/remote/control/server"
    )
    #expect(
        local.value(forHTTPHeaderField: "x-codex-subscribe-cursor") == nil
    )

    #expect(throws: CodexRemoteControlWebSocketFailure.self) {
        _ = try CodexRemoteControlWebSocketRequest.make(
            validatedHTTPBaseURL: URL(
                string: "https://chatgpt.com/backend-api/"
            )!,
            enrollment: remoteWebSocketEnrollment,
            serverName: "bad\nname",
            installationID: "installation",
            subscribeCursor: nil
        )
    }
}

@Test
func remoteControlHandshakeFailurePreservesRecoveryEvidence() {
    let unauthorized = CodexRemoteControlWebSocketHTTPFailure.classify(
        statusCode: 401,
        headers: ["request-id": "request-401", "cf-ray": "ray-1"],
        body: Data("expired token".utf8)
    )
    #expect(unauthorized.statusCode == 401)
    #expect(unauthorized.classification == .permissionDenied)
    #expect(unauthorized.headers["request-id"] == "request-401")
    #expect(unauthorized.bodyPreview == "expired token")

    let missing = CodexRemoteControlWebSocketHTTPFailure.classify(
        statusCode: 404,
        headers: ["request-id": "request-404"],
        body: Data(#"{"detail":"Remote app server not found"}"#.utf8)
    )
    #expect(missing.classification == .missingRemoteAppServer)
    #expect(missing.statusCode == 404)

    let other404 = CodexRemoteControlWebSocketHTTPFailure.classify(
        statusCode: 404,
        headers: [:],
        body: Data(#"{"detail":"different"}"#.utf8)
    )
    #expect(other404.classification == .other)
    #expect(other404.bodyPreview == #"{"detail":"different"}"#)
}

@Test
func remoteControlConnectBecomesConnectedOnlyAfterHandshakeAndReplaysFirst()
    async throws
{
    let socket = RemoteWebSocketSocketProbe()
    let connector = RemoteWebSocketConnectorProbe(socket: socket)
    let transport = try CodexRemoteControlWebSocketTransport(
        validatedHTTPBaseURL: URL(
            string: "http://localhost:7443/backend-api/"
        )!,
        enrollment: remoteWebSocketEnrollment,
        serverName: "iPad",
        installationID: "installation",
        connector: connector
    )

    try await transport.send(
        event: .serverMessage(.string("buffered-before-connect")),
        clientID: "client",
        streamID: "stream"
    )
    #expect(await transport.status == .disconnected)
    #expect(await socket.sentTexts().isEmpty)

    try await transport.connectOnce()
    #expect(await transport.status == .connected)
    let replayed = await socket.sentTexts()
    #expect(replayed.count == 1)
    let replayEnvelope = try CodexRemoteControlWebSocketCodec
        .decodeServerEnvelope(Data(try #require(replayed.first).utf8))
    #expect(
        replayEnvelope.event
            == .serverMessage(.string("buffered-before-connect"))
    )

    try await transport.send(
        event: .serverMessage(.string("new-after-replay")),
        clientID: "client",
        streamID: "stream"
    )
    let allSent = await socket.sentTexts()
    #expect(allSent.count == 2)
    let request = try #require(await connector.recordedRequests().first)
    #expect(
        request.url?.absoluteString
            == "ws://localhost:7443/backend-api/wham/remote/control/server"
    )
}

@Test
func remoteControlFailedHandshakeNeverPublishesConnected() async throws {
    let evidence = CodexRemoteControlWebSocketHTTPFailure.classify(
        statusCode: 403,
        headers: ["request-id": "denied"],
        body: Data("denied".utf8)
    )
    let transport = try CodexRemoteControlWebSocketTransport(
        validatedHTTPBaseURL: URL(
            string: "http://localhost:7443/backend-api/"
        )!,
        enrollment: remoteWebSocketEnrollment,
        serverName: "iPad",
        installationID: "installation",
        connector: RemoteWebSocketFailingConnector(error: .http(evidence))
    )

    do {
        try await transport.connectOnce()
        Issue.record("Expected handshake failure")
    } catch let error as CodexRemoteControlWebSocketFailure {
        #expect(error == .http(evidence))
    }
    #expect(await transport.status == .disconnected)
}

@Test
func remoteControlCursorAdvancesOnlyAfterInboundHandlerSucceeds()
    async throws
{
    let socket = RemoteWebSocketSocketProbe()
    let connector = RemoteWebSocketConnectorProbe(socket: socket)
    let inbound = RemoteWebSocketInboundProbe()
    let transport = try CodexRemoteControlWebSocketTransport(
        validatedHTTPBaseURL: URL(
            string: "http://localhost:7443/backend-api/"
        )!,
        enrollment: remoteWebSocketEnrollment,
        serverName: "iPad",
        installationID: "installation",
        connector: connector,
        inboundHandler: { envelope in
            await inbound.handle(envelope)
        }
    )
    try await transport.connectOnce()

    let envelope = CodexRemoteControlClientEnvelope(
        event: .ping,
        clientID: "client",
        streamID: "stream",
        seqID: 3,
        cursor: "cursor-after-delivery"
    )
    let text = String(
        decoding: try CodexRemoteControlWebSocketCodec.encode(envelope),
        as: UTF8.self
    )
    let action = try await transport.processInboundFrame(.text(text))
    guard case .deliver = action else {
        Issue.record("Expected delivery")
        return
    }
    #expect(await inbound.received() == [envelope])
    #expect(await transport.subscribeCursor == "cursor-after-delivery")
}

@Test
func remoteControlOnlyActualPongExtendsDeadline() async throws {
    let socket = RemoteWebSocketSocketProbe()
    let connector = RemoteWebSocketConnectorProbe(socket: socket)
    let transport = try CodexRemoteControlWebSocketTransport(
        validatedHTTPBaseURL: URL(
            string: "http://localhost:7443/backend-api/"
        )!,
        enrollment: remoteWebSocketEnrollment,
        serverName: "iPad",
        installationID: "installation",
        connector: connector,
        configuration: .init(
            pingInterval: .seconds(10),
            pongTimeout: .seconds(60),
            connectTimeout: .seconds(30),
            shutdownTimeout: .seconds(5),
            reconnectBackoffCap: .seconds(30)
        )
    )
    try await transport.connectOnce()
    let initial = try #require(await transport.pongDeadline)

    let text = String(
        decoding: try CodexRemoteControlWebSocketCodec.encode(
            CodexRemoteControlClientEnvelope(
                event: .ping,
                clientID: "client",
                streamID: nil,
                seqID: nil,
                cursor: nil
            )
        ),
        as: UTF8.self
    )
    _ = try await transport.processInboundFrame(.text(text))
    #expect(await transport.pongDeadline == initial)

    try await Task.sleep(for: .milliseconds(2))
    _ = try await transport.processInboundFrame(.pong(Data()))
    let afterPong = try #require(await transport.pongDeadline)
    #expect(afterPong > initial)

    _ = try await transport.processInboundFrame(.ping(Data()))
    #expect(await transport.pongDeadline == afterPong)
    _ = try await transport.processInboundFrame(.binary(Data([0, 1])))
    #expect(await transport.pongDeadline == afterPong)
}

@Test
func remoteControlUsesOfficialTimeoutsAndCappedExponentialBackoff() {
    let configuration = CodexRemoteControlWebSocketConfiguration()
    #expect(configuration.pingInterval == .seconds(10))
    #expect(configuration.pongTimeout == .seconds(60))
    #expect(configuration.connectTimeout == .seconds(30))
    #expect(configuration.shutdownTimeout == .seconds(5))
    #expect(configuration.reconnectBackoffCap == .seconds(30))

    let delays = (0 ... 10).map {
        CodexRemoteControlReconnectBackoff.delay(
            attempt: $0,
            cap: configuration.reconnectBackoffCap
        )
    }
    #expect(delays[0] == .milliseconds(200))
    #expect(delays[1] == .milliseconds(400))
    #expect(delays[2] == .milliseconds(800))
    #expect(delays[8] == .seconds(30))
    #expect(delays[10] == .seconds(30))
}

@Test
func remoteControlConnectAndShutdownTimeoutsAreHardBoundaries()
    async throws
{
    let slowSocket = RemoteWebSocketSocketProbe(closeDelay: .seconds(1))
    let slowConnector = RemoteWebSocketConnectorProbe(
        socket: slowSocket,
        connectDelay: .seconds(1)
    )
    let short = CodexRemoteControlWebSocketConfiguration(
        pingInterval: .seconds(10),
        pongTimeout: .seconds(60),
        connectTimeout: .milliseconds(20),
        shutdownTimeout: .milliseconds(20),
        reconnectBackoffCap: .seconds(30)
    )
    let connectTransport = try CodexRemoteControlWebSocketTransport(
        validatedHTTPBaseURL: URL(
            string: "http://localhost:7443/backend-api/"
        )!,
        enrollment: remoteWebSocketEnrollment,
        serverName: "iPad",
        installationID: "installation",
        connector: slowConnector,
        configuration: short
    )
    do {
        try await connectTransport.connectOnce()
        Issue.record("Expected connect timeout")
    } catch let error as CodexRemoteControlWebSocketFailure {
        #expect(error == .connectTimedOut)
    }
    #expect(await connectTransport.status == .disconnected)

    let connectedSocket = RemoteWebSocketSocketProbe(closeDelay: .seconds(1))
    let connectedTransport = try CodexRemoteControlWebSocketTransport(
        validatedHTTPBaseURL: URL(
            string: "http://localhost:7443/backend-api/"
        )!,
        enrollment: remoteWebSocketEnrollment,
        serverName: "iPad",
        installationID: "installation",
        connector: RemoteWebSocketConnectorProbe(socket: connectedSocket),
        configuration: short
    )
    try await connectedTransport.connectOnce()
    do {
        try await connectedTransport.disconnect()
        Issue.record("Expected shutdown timeout")
    } catch let error as CodexRemoteControlWebSocketFailure {
        #expect(error == .shutdownTimedOut)
    }
    #expect(await connectedTransport.status == .disconnected)
}

@Test
func remoteControlRejectedInboundDeliveryDoesNotAdvanceCursor() async throws {
    let socket = RemoteWebSocketSocketProbe()
    let transport = try CodexRemoteControlWebSocketTransport(
        validatedHTTPBaseURL: URL(
            string: "http://localhost:7443/backend-api/"
        )!,
        enrollment: remoteWebSocketEnrollment,
        serverName: "iPad",
        installationID: "installation",
        connector: RemoteWebSocketConnectorProbe(socket: socket),
        inboundHandler: { _ in
            throw RemoteWebSocketProbeError.connectFailed
        }
    )
    try await transport.connectOnce()
    let envelope = CodexRemoteControlClientEnvelope(
        event: .ping,
        clientID: "client",
        streamID: "stream",
        seqID: 3,
        cursor: "rejected-cursor"
    )
    let text = String(
        decoding: try CodexRemoteControlWebSocketCodec.encode(envelope),
        as: UTF8.self
    )
    do {
        _ = try await transport.processInboundFrame(.text(text))
        Issue.record("Expected the inbound handler to fail")
    } catch let error as CodexRemoteControlWebSocketFailure {
        guard case .inboundHandler = error else {
            Issue.record("Unexpected failure: \(error)")
            return
        }
    }
    #expect(await transport.subscribeCursor == nil)
}

@Test
func remoteControlReconnectReplaysBeforeNewMessagesAndResubscribesCursor()
    async throws
{
    let socket = RemoteWebSocketSocketProbe()
    let connector = RemoteWebSocketConnectorProbe(socket: socket)
    let transport = try CodexRemoteControlWebSocketTransport(
        validatedHTTPBaseURL: URL(
            string: "http://localhost:7443/backend-api/"
        )!,
        enrollment: remoteWebSocketEnrollment,
        serverName: "iPad",
        installationID: "installation",
        connector: connector
    )
    try await transport.send(
        event: .serverMessage(.string("unacked")),
        clientID: "client",
        streamID: "stream"
    )
    try await transport.connectOnce()
    let inbound = CodexRemoteControlClientEnvelope(
        event: .ping,
        clientID: "client",
        streamID: "stream",
        seqID: nil,
        cursor: "resume-cursor"
    )
    _ = try await transport.processInboundFrame(
        .text(
            String(
                decoding: try CodexRemoteControlWebSocketCodec.encode(inbound),
                as: UTF8.self
            )
        )
    )
    try await transport.disconnect()
    try await transport.connectOnce()
    try await transport.send(
        event: .serverMessage(.string("new")),
        clientID: "client",
        streamID: "stream"
    )

    let sent = await socket.sentTexts()
    #expect(sent.count == 3)
    let decoded = try sent.map { text in
        try CodexRemoteControlWebSocketCodec.decodeServerEnvelope(
            Data(text.utf8)
        )
    }
    #expect(decoded[0] == decoded[1])
    #expect(decoded[2].seqID == 2)
    #expect(decoded[2].event == .serverMessage(.string("new")))
    let requests = await connector.recordedRequests()
    #expect(requests.count == 2)
    #expect(
        requests[1].value(
            forHTTPHeaderField: "x-codex-subscribe-cursor"
        ) == "resume-cursor"
    )
}

@Test
func remoteControlSuccessfulHandshakeResetsReconnectAttempt() async throws {
    let socket = RemoteWebSocketSocketProbe()
    let connector = RemoteWebSocketScriptedConnector(socket: socket)
    let statuses = RemoteWebSocketStatusProbe()
    let transport = try CodexRemoteControlWebSocketTransport(
        validatedHTTPBaseURL: URL(
            string: "http://localhost:7443/backend-api/"
        )!,
        enrollment: remoteWebSocketEnrollment,
        serverName: "iPad",
        installationID: "installation",
        connector: connector,
        statusHandler: { status in
            await statuses.record(status)
        }
    )

    let runTask = Task {
        try await transport.run()
    }
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(2))
    while await statuses.reconnects().count < 2, clock.now < deadline {
        try await Task.sleep(for: .milliseconds(5))
    }
    let reconnects = await statuses.reconnects()
    runTask.cancel()
    _ = try? await runTask.value

    #expect(reconnects.count >= 2)
    if reconnects.count >= 2 {
        #expect(reconnects[0].attempt == 0)
        #expect(reconnects[0].delay == .milliseconds(200))
        #expect(reconnects[1].attempt == 0)
        #expect(reconnects[1].delay == .milliseconds(200))
    }
}
