import Foundation
import Testing

@testable import CodexPadApplication
@testable import CodexPadDomain
@testable import CodexPadProtocolBridge

@Test @MainActor
func codexRealtimeServiceCoversThreadRealtimeErrorNotificationAndOfficialV2Wire() async throws {
    let socket = RealtimeMockSocket()
    let connector = RealtimeMockConnector(socket: socket)
    let notifications = RealtimeNotificationRecorder()
    let service = CodexRealtimeService(
        connector: connector,
        credentialsProvider: {
            CodexOfficialCredentials(accessToken: "fixture-token", accountID: "fixture-account")
        },
        notificationSink: { method, params in
            await notifications.append(method: method, params: params)
        }
    )

    try await service.start(.init(
        threadID: "thread-1",
        model: nil,
        outputModality: "audio",
        prompt: "fixture realtime prompt",
        realtimeSessionID: "realtime-1",
        transport: .websocket,
        version: "v2",
        voice: nil
    ))
    try await service.appendAudio(
        threadID: "thread-1",
        audio: .init(data: "AAEC", sampleRate: 24_000, numChannels: 1)
    )
    try await service.appendText(threadID: "thread-1", text: "hello", role: "developer")
    try await service.appendSpeech(threadID: "thread-1", text: "speak this")

    let request = try #require(await connector.requests.first)
    #expect(request.url?.absoluteString == "wss://chatgpt.com/backend-api/codex/realtime?model=gpt-realtime-1.5")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-token")
    #expect(request.value(forHTTPHeaderField: "ChatGPT-Account-ID") == "fixture-account")
    #expect(request.value(forHTTPHeaderField: "originator") == "codex_for_ipad")
    #expect(request.value(forHTTPHeaderField: "session-id") == "realtime-1")
    #expect(request.value(forHTTPHeaderField: "thread-id") == "thread-1")

    let messages = try await socket.decodedMessages()
    #expect(messages.count == 5)
    #expect(messages[0]["type"] == .string("session.update"))
    if case let .object(session)? = messages[0]["session"] {
        #expect(session["instructions"] == .string("fixture realtime prompt"))
        #expect(session["output_modalities"] == .array([.string("audio")]))
        #expect(session["tool_choice"] == .string("auto"))
    } else {
        Issue.record("missing session.update payload")
    }
    #expect(messages[1] == ["type": .string("input_audio_buffer.append"), "audio": .string("AAEC")])
    #expect(messages[2]["type"] == .string("conversation.item.create"))
    #expect(messages[3]["type"] == .string("conversation.item.create"))
    #expect(messages[4] == ["type": .string("response.create")])

    await socket.enqueueJSON(.object([
        "type": .string("session.updated"),
        "session": .object(["id": .string("server-session")]),
    ]))
    await socket.enqueueJSON(.object([
        "type": .string("response.output_text.delta"),
        "delta": .string("partial"),
    ]))
    await socket.enqueueJSON(.object([
        "type": .string("response.output_text.done"),
        "text": .string("complete"),
    ]))
    await socket.enqueueJSON(.object([
        "type": .string("response.output_audio.delta"),
        "delta": .string("AQID"),
        "item_id": .string("audio-item"),
    ]))
    await socket.enqueueJSON(.object([
        "type": .string("error"),
        "error": .object([
            "message": .string("fixture realtime failure")
        ]),
    ]))
    try await waitForRealtimeNotifications(5, recorder: notifications)
    try await service.stop(threadID: "thread-1")

    let recorded = await notifications.values
    #expect(recorded.map(\.0).contains("thread/realtime/started"))
    #expect(recorded.map(\.0).contains("thread/realtime/transcript/delta"))
    #expect(recorded.map(\.0).contains("thread/realtime/transcript/done"))
    #expect(recorded.map(\.0).contains("thread/realtime/outputAudio/delta"))
    #expect(
        recorded.contains {
            $0.0 == "thread/realtime/error"
                && $0.1 == .object([
                    "threadId": .string("thread-1"),
                    "message": .string("fixture realtime failure"),
                ])
        }
    )
    #expect(recorded.last?.0 == "thread/realtime/closed")
    #expect(await socket.isClosed)
}

@Test @MainActor
func codexRealtimeServiceCreatesWebRTCCallAndJoinsSideband()
    async throws
{
    let socket = RealtimeMockSocket()
    let connector = RealtimeMockConnector(socket: socket)
    let transport = RealtimeHTTPTransport()
    let notifications = RealtimeNotificationRecorder()
    let service = CodexRealtimeService(
        connector: connector,
        httpTransport: transport,
        credentialsProvider: {
            CodexOfficialCredentials(
                accessToken: "fixture-token",
                accountID: "fixture-account"
            )
        },
        notificationSink: { method, params in
            await notifications.append(
                method: method,
                params: params
            )
        }
    )

    try await service.start(
        .init(
            threadID: "thread-webrtc",
            model: "gpt-realtime-fixture",
            outputModality: "audio",
            prompt: "webrtc prompt",
            realtimeSessionID: nil,
            transport: .webrtc(sdp: "v=0\r\no=offer\r\n"),
            version: "v1",
            voice: nil
        )
    )

    let call = try #require(await transport.requests.first)
    #expect(call.method == "POST")
    #expect(
        call.url.absoluteString
            == "https://chatgpt.com/backend-api/codex/realtime/calls?intent=quicksilver&architecture=avas"
    )
    #expect(call.headers["Content-Type"] == "application/json")
    let body = try #require(call.body)
    let bodyValue = try JSONDecoder().decode(
        CodexJSONValue.self,
        from: body
    )
    guard case let .object(callFields) = bodyValue,
          case let .object(session)? = callFields["session"]
    else {
        Issue.record("missing WebRTC call session")
        return
    }
    #expect(
        callFields["sdp"]
            == .string("v=0\r\no=offer\r\n")
    )
    #expect(session["type"] == .string("quicksilver"))
    #expect(
        session["model"]
            == .string("gpt-realtime-fixture")
    )

    let sideband = try #require(
        await connector.requests.first
    )
    #expect(
        sideband.url?.absoluteString
            == "wss://chatgpt.com/backend-api/codex/realtime?intent=quicksilver&call_id=call-fixture"
    )
    let recorded = await notifications.values
    #expect(
        recorded.map(\.0).prefix(2)
            == [
                "thread/realtime/sdp",
                "thread/realtime/started",
            ]
    )
    #expect(
        recorded.first?.1
            == .object([
                "threadId": .string("thread-webrtc"),
                "sdp": .string("v=0\r\no=answer\r\n"),
            ])
    )

    try await service.appendSpeech(
        threadID: "thread-webrtc",
        text: "speak"
    )
    let messages = try await socket.decodedMessages()
    #expect(messages[0]["type"] == .string("session.update"))
    #expect(
        messages[1]
            == [
                "type":
                    .string(
                        "conversation.handoff.append"
                    ),
                "handoff_id": .string("codex"),
                "output_text": .string("speak"),
            ]
    )
    try await service.stop(threadID: "thread-webrtc")
}

@Test @MainActor
func codexRealtimeServiceUsesOfficialV3FramelessWire()
    async throws
{
    let socket = RealtimeMockSocket()
    let connector = RealtimeMockConnector(socket: socket)
    let notifications = RealtimeNotificationRecorder()
    let service = CodexRealtimeService(
        connector: connector,
        credentialsProvider: {
            CodexOfficialCredentials(
                accessToken: "fixture-token",
                accountID: "fixture-account"
            )
        },
        notificationSink: { method, params in
            await notifications.append(
                method: method,
                params: params
            )
        }
    )

    try await service.start(
        .init(
            threadID: "thread-v3",
            model: "gpt-realtime-fixture",
            outputModality: "audio",
            prompt: "frameless prompt",
            realtimeSessionID: "realtime-v3",
            transport: .websocket,
            version: "v3",
            voice: "cove",
            initialItems: [
                .init(
                    role: "developer",
                    text: "Remember this."
                ),
                .init(
                    role: "assistant",
                    text: "Understood."
                ),
            ]
        )
    )
    try await service.appendAudio(
        threadID: "thread-v3",
        audio: .init(
            data: "AAEC",
            sampleRate: 24_000,
            numChannels: 1
        )
    )
    try await service.appendText(
        threadID: "thread-v3",
        text: "context",
        role: "developer"
    )
    try await service.appendSpeech(
        threadID: "thread-v3",
        text: "speak"
    )

    let request = try #require(
        await connector.requests.first
    )
    #expect(
        request.url?.absoluteString
            == "wss://chatgpt.com/backend-api/codex/live?model=gpt-realtime-fixture"
    )
    #expect(
        request.value(
            forHTTPHeaderField: "openai-alpha"
        ) == "quicksilver=v2"
    )
    let messages = try await socket.decodedMessages()
    #expect(messages[0]["type"] == .string("session.update"))
    guard case let .object(session)? =
        messages[0]["session"]
    else {
        Issue.record("missing V3 session")
        return
    }
    #expect(
        session["delegation"]
            == .object(["type": .string("client")])
    )
    if case let .array(items)? =
        session["initial_items"]
    {
        #expect(items.count == 2)
    } else {
        Issue.record("missing V3 initial items")
    }
    #expect(
        messages[1]
            == [
                "type": .string("input_audio.append"),
                "audio": .string("AAEC"),
            ]
    )
    #expect(
        messages[2]["type"]
            == .string("session.context.append")
    )
    #expect(messages[2]["channel"] == nil)
    #expect(
        messages[3]["channel"]
            == .string("speakable")
    )

    #expect((await notifications.values).isEmpty)
    await socket.enqueueJSON(.object([
        "type": .string("session.started"),
    ]))
    await socket.enqueueJSON(.object([
        "type": .string("input_transcript.added"),
        "item": .object(["text": .string("user delta")]),
    ]))
    await socket.enqueueJSON(.object([
        "type": .string("turn.done"),
        "turn": .object([
            "role": .string("assistant"),
            "transcript": .string("done"),
        ]),
    ]))
    await socket.enqueueJSON(.object([
        "type": .string("delegation.created"),
        "item": .object([
            "type": .string("delegation"),
            "target": .string("client"),
            "id": .string("delegate-1"),
            "content": .array([
                .object([
                    "type": .string("input_text"),
                    "text": .string("do work"),
                ]),
            ]),
        ]),
    ]))
    try await waitForRealtimeNotifications(
        4,
        recorder: notifications
    )
    try await service.stop(threadID: "thread-v3")
    let finalMessages = try await socket.decodedMessages()
    #expect(
        finalMessages.last
            == ["type": .string("session.close")]
    )
    let methods = await notifications.values.map(\.0)
    #expect(
        methods.contains(
            "thread/realtime/transcript/delta"
        )
    )
    #expect(
        methods.contains(
            "thread/realtime/transcript/done"
        )
    )
    #expect(
        methods.contains("thread/realtime/itemAdded")
    )
}

@Test @MainActor
func codexRealtimeServiceCreatesV3WebRTCCallWithoutSecondSessionUpdate()
    async throws
{
    let socket = RealtimeMockSocket()
    let connector = RealtimeMockConnector(socket: socket)
    let transport = RealtimeHTTPTransport()
    let notifications = RealtimeNotificationRecorder()
    let service = CodexRealtimeService(
        connector: connector,
        httpTransport: transport,
        credentialsProvider: {
            CodexOfficialCredentials(
                accessToken: "fixture-token",
                accountID: "fixture-account"
            )
        },
        notificationSink: { method, params in
            await notifications.append(
                method: method,
                params: params
            )
        }
    )
    try await service.start(
        .init(
            threadID: "thread-v3-webrtc",
            model: "gpt-realtime-fixture",
            outputModality: "audio",
            prompt: "frameless call",
            realtimeSessionID: nil,
            transport: .webrtc(
                sdp: "v=0\r\no=offer\r\n"
            ),
            version: "v3",
            voice: "cove",
            initialItems: [
                .init(
                    role: "user",
                    text: "Prior context"
                ),
            ]
        )
    )

    let sideband = try #require(
        await connector.requests.first
    )
    #expect(
        sideband.url?.absoluteString
            == "wss://chatgpt.com/backend-api/codex/live/call-fixture"
    )
    #expect(
        sideband.value(
            forHTTPHeaderField: "openai-alpha"
        ) == "quicksilver=v2"
    )
    #expect((try await socket.decodedMessages()).isEmpty)
    let call = try #require(await transport.requests.first)
    let callBody = try #require(call.body)
    let value = try JSONDecoder().decode(
        CodexJSONValue.self,
        from: callBody
    )
    guard case let .object(fields) = value,
          case let .object(session)? = fields["session"],
          case let .array(items)? =
              session["initial_items"]
    else {
        Issue.record("missing V3 WebRTC session")
        return
    }
    #expect(
        session["delegation"]
            == .object(["type": .string("client")])
    )
    #expect(items.count == 1)
    let methods = await notifications.values.map(\.0)
    #expect(
        methods.prefix(2)
            == [
                "thread/realtime/sdp",
                "thread/realtime/started",
            ]
    )
    try await service.stop(
        threadID: "thread-v3-webrtc"
    )
}

@Test @MainActor
func codexRealtimeRouterForwardsAllFiveRequests() async {
    let manager = RealtimeRecordingManager()
    let state = realtimeRouterState()
    let requests: [(String, CodexJSONValue)] = [
        ("thread/realtime/start", .object([
            "threadId": .string("thread-1"), "outputModality": .string("text"),
            "version": .string("v3"), "transport": .object(["type": .string("websocket")]),
            "initialItems": .array([.object(["role": .string("developer"), "text": .string("context")])]),
        ])),
        ("thread/realtime/appendAudio", .object([
            "threadId": .string("thread-1"),
            "audio": .object(["data": .string("AAEC"), "sampleRate": .integer(24_000), "numChannels": .integer(1)]),
        ])),
        ("thread/realtime/appendText", .object(["threadId": .string("thread-1"), "text": .string("hello")])),
        ("thread/realtime/appendSpeech", .object(["threadId": .string("thread-1"), "text": .string("speak")])) ,
        ("thread/realtime/stop", .object(["threadId": .string("thread-1")])) ,
    ]

    for (offset, entry) in requests.enumerated() {
        let response = await CodexDesktopInitialMCPRouter.responseIncludingFileSystem(
            to: realtimeRequest(id: Int64(offset + 1), method: entry.0, params: entry.1),
            state: state,
            allowedFileSystemRoots: [],
            realtimeManager: manager
        )
        #expect(response == realtimeResponse(id: Int64(offset + 1)))
    }

    #expect(await manager.calls == ["start", "audio", "text:user", "speech", "stop"])
    #expect(await manager.startParameters?.version == "v3")
    #expect(await manager.startParameters?.initialItems.count == 1)
    #expect(await manager.audio?.sampleRate == 24_000)
}

@Test @MainActor
func codexRealtimeRouterRejectsMalformedParametersBeforeService() async {
    let manager = RealtimeRecordingManager()
    let request = realtimeRequest(
        id: 7,
        method: "thread/realtime/appendAudio",
        params: .object([
            "threadId": .string("thread-1"),
            "audio": .object(["data": .string("AAEC"), "sampleRate": .integer(0), "numChannels": .integer(1)]),
        ])
    )
    let response = await CodexDesktopInitialMCPRouter.responseIncludingFileSystem(
        to: request,
        state: realtimeRouterState(),
        allowedFileSystemRoots: [],
        realtimeManager: manager
    )
    #expect(await manager.calls.isEmpty)
    #expect(response == .mcpResponse(hostID: "realtime-host", message: .object([
        "id": .integer(7),
        "error": .object(["code": .integer(-32602), "message": .string("Invalid params for thread/realtime/appendAudio")]),
    ]), metadata: [:]))
}

private actor RealtimeMockConnector: CodexRemoteControlWebSocketConnecting {
    let socket: RealtimeMockSocket
    private(set) var requests: [URLRequest] = []
    init(socket: RealtimeMockSocket) { self.socket = socket }
    func connect(request: URLRequest) async throws -> any CodexRemoteControlWebSocketSocket {
        requests.append(request)
        return socket
    }
}

private actor RealtimeHTTPTransport:
    CodexDesktopNetworkFetchTransport
{
    private(set) var requests:
        [CodexDesktopNetworkTransportRequest] = []

    func execute(
        _ request: CodexDesktopNetworkTransportRequest
    ) async throws -> CodexDesktopNetworkTransportResponse {
        requests.append(request)
        return .init(
            status: 200,
            headers: [
                "Location":
                    "/backend-api/codex/realtime/calls/call-fixture",
            ],
            body: Data("v=0\r\no=answer\r\n".utf8)
        )
    }
}

private actor RealtimeMockSocket: CodexRemoteControlWebSocketSocket {
    private(set) var sent: [String] = []
    private var frames: [CodexRemoteControlWebSocketFrame] = []
    private var receiver: CheckedContinuation<CodexRemoteControlWebSocketFrame, any Error>?
    private(set) var isClosed = false

    func send(text: String) async throws { sent.append(text) }
    func sendPing() async throws {}
    func receive() async throws -> CodexRemoteControlWebSocketFrame {
        if !frames.isEmpty { return frames.removeFirst() }
        return try await withCheckedThrowingContinuation { receiver = $0 }
    }
    func close() async {
        isClosed = true
        enqueue(.closed(code: 1000, reason: "closed"))
    }
    func enqueueJSON(_ value: CodexJSONValue) {
        let data = try! JSONEncoder().encode(value)
        enqueue(.text(String(decoding: data, as: UTF8.self)))
    }
    func decodedMessages() throws -> [[String: CodexJSONValue]] {
        try sent.map {
            let value = try JSONDecoder().decode(CodexJSONValue.self, from: Data($0.utf8))
            guard case let .object(fields) = value else { throw CodexRealtimeServiceError.invalidParameters("mock message") }
            return fields
        }
    }
    private func enqueue(_ frame: CodexRemoteControlWebSocketFrame) {
        if let receiver { self.receiver = nil; receiver.resume(returning: frame) }
        else { frames.append(frame) }
    }
}

private actor RealtimeNotificationRecorder {
    private(set) var values: [(String, CodexJSONValue)] = []
    func append(method: String, params: CodexJSONValue) { values.append((method, params)) }
}

private actor RealtimeRecordingManager: CodexDesktopRealtimeManaging {
    private(set) var calls: [String] = []
    private(set) var startParameters: CodexRealtimeStartParameters?
    private(set) var audio: CodexRealtimeAudioChunk?
    func start(_ parameters: CodexRealtimeStartParameters) async throws { startParameters = parameters; calls.append("start") }
    func appendAudio(threadID _: String, audio: CodexRealtimeAudioChunk) async throws { self.audio = audio; calls.append("audio") }
    func appendText(threadID _: String, text _: String, role: String) async throws { calls.append("text:\(role)") }
    func appendSpeech(threadID _: String, text _: String) async throws { calls.append("speech") }
    func stop(threadID _: String) async throws { calls.append("stop") }
}

private func waitForRealtimeNotifications(_ count: Int, recorder: RealtimeNotificationRecorder) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(1))
    while await recorder.values.count < count {
        guard clock.now < deadline else { throw CodexRealtimeServiceError.connectionFailed("notification timeout") }
        try await Task.sleep(for: .milliseconds(5))
    }
}

private func realtimeRequest(id: Int64, method: String, params: CodexJSONValue) -> CodexDesktopMCPRequest {
    .init(request: .init(id: .integer(id), method: method, params: params, metadata: [:]), hostID: "realtime-host", dispatchedAtMs: nil, priority: nil, source: nil, timeoutMs: nil, expiresAtMs: nil, metadata: [:])
}

private func realtimeResponse(id: Int64) -> CodexDesktopHostMessage {
    .mcpResponse(hostID: "realtime-host", message: .object(["id": .integer(id), "result": .object([:])]), metadata: [:])
}

private func realtimeRouterState() -> CodexDesktopInitialMCPState {
    .init(account: .init(account: nil, authMethod: nil, requiresOpenAIAuth: true), config: .init(config: [:], origins: [:], layers: []), remoteControl: .init(status: .disabled, serverName: "Codex", installationID: "installation", environmentID: nil))
}
