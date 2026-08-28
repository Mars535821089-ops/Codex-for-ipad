#if SWIFT_PACKAGE
import CodexPadDomain
#endif
import Foundation

public struct CodexRealtimeAudioChunk: Equatable, Sendable {
    public let data: String
    public let sampleRate: UInt32
    public let numChannels: UInt16
    public let samplesPerChannel: UInt32?
    public let itemID: String?

    public init(data: String, sampleRate: UInt32, numChannels: UInt16, samplesPerChannel: UInt32? = nil, itemID: String? = nil) {
        self.data = data
        self.sampleRate = sampleRate
        self.numChannels = numChannels
        self.samplesPerChannel = samplesPerChannel
        self.itemID = itemID
    }
}

public enum CodexRealtimeTransport: Equatable, Sendable {
    case websocket
    case webrtc(sdp: String)
}

public struct CodexRealtimeInitialItem: Equatable, Sendable {
    public let role: String
    public let text: String

    public init(role: String, text: String) {
        self.role = role
        self.text = text
    }
}

public struct CodexRealtimeStartParameters: Equatable, Sendable {
    public let threadID: String
    public let model: String?
    public let outputModality: String
    public let prompt: String?
    public let realtimeSessionID: String?
    public let transport: CodexRealtimeTransport
    public let version: String
    public let voice: String?
    public let initialItems: [CodexRealtimeInitialItem]

    public init(threadID: String, model: String?, outputModality: String, prompt: String?, realtimeSessionID: String?, transport: CodexRealtimeTransport, version: String, voice: String?, initialItems: [CodexRealtimeInitialItem] = []) {
        self.threadID = threadID
        self.model = model
        self.outputModality = outputModality
        self.prompt = prompt
        self.realtimeSessionID = realtimeSessionID
        self.transport = transport
        self.version = version
        self.voice = voice
        self.initialItems = initialItems
    }
}

public enum CodexRealtimeServiceError: Error, Equatable, LocalizedError, Sendable {
    case signedOut
    case invalidParameters(String)
    case sessionNotRunning(String)
    case unsupportedTransport(String)
    case connectionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .signedOut: "ChatGPT sign-in is required for realtime"
        case let .invalidParameters(message): message
        case let .sessionNotRunning(threadID): "realtime conversation is not running for thread `\(threadID)`"
        case let .unsupportedTransport(message): message
        case let .connectionFailed(message): "realtime connection failed: \(message)"
        }
    }
}

public protocol CodexDesktopRealtimeManaging: Sendable {
    func start(_ parameters: CodexRealtimeStartParameters) async throws
    func appendAudio(threadID: String, audio: CodexRealtimeAudioChunk) async throws
    func appendText(threadID: String, text: String, role: String) async throws
    func appendSpeech(threadID: String, text: String) async throws
    func stop(threadID: String) async throws
}

public actor CodexRealtimeService: CodexDesktopRealtimeManaging {
    public typealias CredentialsProvider = @MainActor @Sendable () -> CodexOfficialCredentials?
    public typealias NotificationSink = @Sendable (String, CodexJSONValue) async -> Void

    private struct Session {
        let token: UUID
        let socket: any CodexRemoteControlWebSocketSocket
        let realtimeSessionID: String
        let version: String
    }

    private let connector: any CodexRemoteControlWebSocketConnecting
    private let httpTransport:
        any CodexDesktopNetworkFetchTransport
    private let credentialsProvider: CredentialsProvider
    private let notificationSink: NotificationSink
    private let baseURL: URL
    private let webRTCSidebandBaseURL: URL
    private var sessions: [String: Session] = [:]

    public init(
        connector: any CodexRemoteControlWebSocketConnecting = CodexRemoteControlURLSessionWebSocketConnector(),
        httpTransport:
            any CodexDesktopNetworkFetchTransport =
                CodexDesktopURLSessionNetworkFetchTransport(),
        baseURL: URL = URL(string: "https://chatgpt.com/backend-api/codex")!,
        webRTCSidebandBaseURL: URL = URL(string: "https://api.openai.com/v1")!,
        credentialsProvider: @escaping CredentialsProvider,
        notificationSink: @escaping NotificationSink
    ) {
        self.connector = connector
        self.httpTransport = httpTransport
        self.baseURL = baseURL
        self.webRTCSidebandBaseURL = webRTCSidebandBaseURL
        self.credentialsProvider = credentialsProvider
        self.notificationSink = notificationSink
    }

    public func start(_ parameters: CodexRealtimeStartParameters) async throws {
        guard parameters.version == "v1"
            || parameters.version == "v2"
            || parameters.version == "v3"
        else {
            throw CodexRealtimeServiceError.invalidParameters(
                "realtime version must be `v1`, `v2`, or `v3`"
            )
        }
        guard parameters.outputModality == "audio" || parameters.outputModality == "text" else {
            throw CodexRealtimeServiceError.invalidParameters("outputModality must be `audio` or `text`")
        }
        if case .webrtc = parameters.transport,
           parameters.version == "v2"
        {
            throw CodexRealtimeServiceError.unsupportedTransport(
                "AVAS realtime calls support realtime v1 or v3"
            )
        }
        guard parameters.initialItems.count <= 128,
              parameters.initialItems.allSatisfy({
                  ["user", "assistant", "developer"].contains($0.role)
                      && !$0.text.isEmpty
              })
        else {
            throw CodexRealtimeServiceError.invalidParameters(
                "initialItems must contain at most 128 role-bearing text items"
            )
        }
        if parameters.version != "v3",
           !parameters.initialItems.isEmpty
        {
            throw CodexRealtimeServiceError.invalidParameters(
                "initialItems are only supported by realtime v3"
            )
        }
        guard let credentials = await credentialsProvider() else {
            throw CodexRealtimeServiceError.signedOut
        }

        if let previous = sessions.removeValue(forKey: parameters.threadID) {
            await previous.socket.close()
        }

        let model = parameters.model ?? "gpt-realtime-1.5"
        let sessionID = parameters.realtimeSessionID ?? parameters.threadID
        let sessionUpdate = Self.sessionUpdate(parameters)
        let connection:
            (
                request: URLRequest,
                remoteSDP: String?
            )
        switch parameters.transport {
        case .websocket:
            connection = (
                try websocketRequest(
                    model: model,
                    callID: nil,
                    parameters: parameters,
                    credentials: credentials,
                    sessionID: sessionID
                ),
                nil
            )
        case let .webrtc(sdp):
            let call = try await createWebRTCCall(
                sdp: sdp,
                sessionUpdate: sessionUpdate,
                model: model,
                credentials: credentials,
                parameters: parameters,
                sessionID: sessionID
            )
            connection = (
                try websocketRequest(
                    model: nil,
                    callID: call.callID,
                    parameters: parameters,
                    credentials: credentials,
                    sessionID: sessionID
                ),
                call.sdp
            )
        }
        let request = connection.request

        let socket: any CodexRemoteControlWebSocketSocket
        do {
            socket = try await connector.connect(request: request)
            if !(
                parameters.version == "v3"
                    && {
                        if case .webrtc = parameters.transport {
                            return true
                        }
                        return false
                    }()
            ) {
                try await socket.send(
                    text: try Self.encode(sessionUpdate)
                )
            }
        } catch {
            throw CodexRealtimeServiceError.connectionFailed(
                error.localizedDescription
            )
        }

        let token = UUID()
        sessions[parameters.threadID] = Session(token: token, socket: socket, realtimeSessionID: sessionID, version: parameters.version)
        if let sdp = connection.remoteSDP {
            await notificationSink(
                "thread/realtime/sdp",
                .object([
                    "threadId": .string(parameters.threadID),
                    "sdp": .string(sdp),
                ])
            )
        }
        if parameters.version != "v3"
            || {
                if case .webrtc = parameters.transport {
                    return true
                }
                return false
            }()
        {
            await emitStarted(
                threadID: parameters.threadID,
                realtimeSessionID: sessionID,
                version: parameters.version
            )
        }
        Task { await self.receiveFrames(threadID: parameters.threadID, token: token, socket: socket) }
    }

    private func websocketRequest(
        model: String?,
        callID: String?,
        parameters: CodexRealtimeStartParameters,
        credentials: CodexOfficialCredentials,
        sessionID: String
    ) throws -> URLRequest {
        // Codex creates WebRTC calls through the ChatGPT backend, but the
        // authenticated AVAS sideband socket is hosted on the direct realtime
        // API endpoint. Standalone WebSocket sessions continue to use baseURL.
        let endpointBaseURL = callID == nil ? baseURL : webRTCSidebandBaseURL
        var components = URLComponents(
            url: endpointBaseURL,
            resolvingAgainstBaseURL: false
        )
        components?.scheme =
            endpointBaseURL.scheme == "http" ? "ws" : "wss"
        let normalizedPath = endpointBaseURL.path.hasSuffix("/")
            ? String(endpointBaseURL.path.dropLast())
            : endpointBaseURL.path
        components?.path =
            normalizedPath
            + (
                parameters.version == "v3"
                    ? "/live"
                    : "/realtime"
            )
        var query: [URLQueryItem] = []
        // Standalone V1 realtime sessions declare their intent. A WebRTC
        // sideband joins an already-created call and, like desktop Codex,
        // must replace that standalone query shape with only `call_id`.
        if parameters.version == "v1", callID == nil {
            query.append(
                URLQueryItem(
                    name: "intent",
                    value: "quicksilver"
                )
            )
        }
        if let model {
            query.append(
                URLQueryItem(name: "model", value: model)
            )
        }
        if let callID {
            if parameters.version == "v3" {
                components?.path += "/\(callID)"
            } else {
                query.append(
                    URLQueryItem(name: "call_id", value: callID)
                )
            }
        }
        components?.queryItems =
            query.isEmpty ? nil : query
        guard let url = components?.url else {
            throw CodexRealtimeServiceError.invalidParameters(
                "invalid realtime endpoint"
            )
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        if let accountID = credentials.accountID, !accountID.isEmpty {
            request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-ID")
        }
        request.setValue("codex_for_ipad", forHTTPHeaderField: "originator")
        request.setValue(sessionID, forHTTPHeaderField: "x-session-id")
        request.setValue(sessionID, forHTTPHeaderField: "session-id")
        request.setValue(parameters.threadID, forHTTPHeaderField: "thread-id")
        if parameters.version == "v1" {
            request.setValue(
                "quicksilver=v1",
                forHTTPHeaderField: "openai-alpha"
            )
        } else if parameters.version == "v3" {
            request.setValue(
                "quicksilver=v2",
                forHTTPHeaderField: "openai-alpha"
            )
        }
        return request
    }

    private func createWebRTCCall(
        sdp: String,
        sessionUpdate: CodexJSONValue,
        model: String,
        credentials: CodexOfficialCredentials,
        parameters: CodexRealtimeStartParameters,
        sessionID: String
    ) async throws -> (sdp: String, callID: String) {
        guard !sdp.isEmpty,
              var components = URLComponents(
                url: baseURL,
                resolvingAgainstBaseURL: false
              )
        else {
            throw CodexRealtimeServiceError.invalidParameters(
                "WebRTC transport requires a non-empty SDP offer"
            )
        }
        let normalizedPath = baseURL.path.hasSuffix("/")
            ? String(baseURL.path.dropLast())
            : baseURL.path
        components.path = normalizedPath + "/realtime/calls"
        components.queryItems = [
            URLQueryItem(name: "intent", value: "quicksilver"),
            URLQueryItem(name: "architecture", value: "avas"),
        ]
        guard let url = components.url,
              case let .object(update) = sessionUpdate,
              case let .object(session)? = update["session"]
        else {
            throw CodexRealtimeServiceError.invalidParameters(
                "invalid realtime call endpoint"
            )
        }
        var callSession = session
        callSession["model"] = .string(model)
        let body = try JSONEncoder().encode(
            CodexJSONValue.object([
                "sdp": .string(sdp),
                "session": .object(callSession),
            ])
        )
        var headers = [
            "Authorization":
                "Bearer \(credentials.accessToken)",
            "Content-Type": "application/json",
            "OpenAI-Alpha": "quicksilver=v2",
            "originator": "codex_for_ipad",
            "x-session-id": sessionID,
            "session-id": sessionID,
            "thread-id": parameters.threadID,
        ]
        if let accountID = credentials.accountID,
           !accountID.isEmpty
        {
            headers["ChatGPT-Account-ID"] = accountID
        }
        let response = try await httpTransport.execute(
            .init(
                url: url,
                method: "POST",
                headers: headers,
                body: body
            )
        )
        guard (200 ..< 300).contains(response.status) else {
            let detail = Self.responseDiagnosticDetail(
                response.body
            )
            let suffix = detail.map { ": \($0)" } ?? ""
            throw CodexRealtimeServiceError.connectionFailed(
                "realtime call returned HTTP \(response.status)"
                    + suffix
            )
        }
        let location = response.headers.first {
            $0.key.caseInsensitiveCompare("Location")
                == .orderedSame
        }?.value
        guard let location,
              let callID = location
                .split(separator: "/")
                .last
                .map(String.init),
              !callID.isEmpty
        else {
            throw CodexRealtimeServiceError.connectionFailed(
                "realtime call response is missing its call id"
            )
        }
        return (
            String(decoding: response.body, as: UTF8.self),
            callID
        )
    }

    private static func responseDiagnosticDetail(
        _ body: Data
    ) -> String? {
        let text = String(decoding: body, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return String(text.prefix(1_024))
    }

    public func appendAudio(threadID: String, audio: CodexRealtimeAudioChunk) async throws {
        guard let session = sessions[threadID] else {
            throw CodexRealtimeServiceError
                .sessionNotRunning(threadID)
        }
        try await send(threadID: threadID, value: .object([
            "type":
                .string(
                    session.version == "v3"
                        ? "input_audio.append"
                        : "input_audio_buffer.append"
                ),
            "audio": .string(audio.data),
        ]))
    }

    public func appendText(threadID: String, text: String, role: String) async throws {
        guard ["user", "assistant", "developer"].contains(role) else {
            throw CodexRealtimeServiceError.invalidParameters("role must be `user`, `assistant`, or `developer`")
        }
        guard let session = sessions[threadID] else {
            throw CodexRealtimeServiceError
                .sessionNotRunning(threadID)
        }
        if session.version == "v3" {
            try await send(
                threadID: threadID,
                value: Self.framelessContextAppend(text: text)
            )
        } else {
            let contentType =
                role == "assistant"
                    ? "output_text"
                    : "input_text"
            try await send(
                threadID: threadID,
                value: Self.conversationItem(
                    text: text,
                    role: role,
                    contentType: contentType
                )
            )
        }
    }

    public func appendSpeech(threadID: String, text: String) async throws {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard let session = sessions[threadID] else {
            throw CodexRealtimeServiceError
                .sessionNotRunning(threadID)
        }
        if session.version == "v1" {
            try await send(
                threadID: threadID,
                value: .object([
                    "type":
                        .string(
                            "conversation.handoff.append"
                        ),
                    "handoff_id": .string("codex"),
                    "output_text": .string(text),
                ])
            )
            return
        }
        if session.version == "v3" {
            try await send(
                threadID: threadID,
                value: Self.framelessContextAppend(
                    text: text,
                    channel: "speakable"
                )
            )
            return
        }
        try await send(threadID: threadID, value: Self.conversationItem(text: text, role: "user", contentType: "input_text"))
        try await send(threadID: threadID, value: .object(["type": .string("response.create")]))
    }

    public func stop(threadID: String) async throws {
        guard let session = sessions.removeValue(forKey: threadID) else {
            throw CodexRealtimeServiceError.sessionNotRunning(threadID)
        }
        if session.version == "v3" {
            try? await session.socket.send(
                text: try Self.encode(
                    .object(["type": .string("session.close")])
                )
            )
        }
        await session.socket.close()
        await emitClosed(threadID: threadID, reason: "requested")
    }

    private func send(threadID: String, value: CodexJSONValue) async throws {
        guard let session = sessions[threadID] else {
            throw CodexRealtimeServiceError.sessionNotRunning(threadID)
        }
        do {
            try await session.socket.send(text: try Self.encode(value))
        } catch {
            throw CodexRealtimeServiceError.connectionFailed(error.localizedDescription)
        }
    }

    private func receiveFrames(threadID: String, token: UUID, socket: any CodexRemoteControlWebSocketSocket) async {
        var closeReason = "transport closed"
        do {
            while sessions[threadID]?.token == token {
                switch try await socket.receive() {
                case let .text(text):
                    try await handleInbound(text, threadID: threadID)
                case let .binary(data):
                    guard let text = String(data: data, encoding: .utf8) else { continue }
                    try await handleInbound(text, threadID: threadID)
                case let .closed(_, reason):
                    closeReason = reason ?? closeReason
                    throw CancellationError()
                case .ping, .pong:
                    continue
                }
            }
        } catch is CancellationError {
        } catch {
            closeReason = error.localizedDescription
            await notificationSink("thread/realtime/error", .object([
                "threadId": .string(threadID),
                "message": .string(error.localizedDescription),
            ]))
        }
        guard sessions[threadID]?.token == token else { return }
        sessions.removeValue(forKey: threadID)
        await socket.close()
        await emitClosed(threadID: threadID, reason: closeReason)
    }

    private func handleInbound(_ text: String, threadID: String) async throws {
        let data = Data(text.utf8)
        let value = try JSONDecoder().decode(CodexJSONValue.self, from: data)
        guard case let .object(fields) = value, case let .string(type)? = fields["type"] else { return }
        switch type {
        case "session.started":
            if let session = sessions[threadID],
               session.version == "v3"
            {
                await emitStarted(
                    threadID: threadID,
                    realtimeSessionID:
                        session.realtimeSessionID,
                    version: session.version
                )
            }
            return
        case "session.updated":
            return
        case "response.output_audio.delta",
             "response.audio.delta",
             "conversation.output_audio.delta",
             "output_audio.delta":
            let delta: String
            if case let .string(value)? = fields["delta"] {
                delta = value
            } else if case let .string(value)? = fields["data"] {
                delta = value
            } else if case let .string(value)? = fields["audio"] {
                delta = value
            } else {
                return
            }
            let sampleRate =
                fields["sample_rate"] ?? .integer(24_000)
            let numChannels =
                fields["channels"]
                    ?? fields["num_channels"]
                    ?? .integer(1)
            var audio: [String: CodexJSONValue] = [
                "data": .string(delta),
                "sampleRate": sampleRate,
                "numChannels": numChannels,
            ]
            if case let .string(itemID)? = fields["item_id"] { audio["itemId"] = .string(itemID) }
            if let samples = fields["samples_per_channel"] {
                audio["samplesPerChannel"] = samples
            }
            await notificationSink("thread/realtime/outputAudio/delta", .object([
                "threadId": .string(threadID), "audio": .object(audio),
            ]))
        case "conversation.item.input_audio_transcription.delta",
             "conversation.input_transcript.delta",
             "input_transcript.added":
            if type == "input_transcript.added",
               case let .object(item)? = fields["item"]
            {
                await emitTranscript(
                    method:
                        "thread/realtime/transcript/delta",
                    threadID: threadID,
                    role: "user",
                    key: "text",
                    fields: item
                )
                return
            }
            await emitTranscript(method: "thread/realtime/transcript/delta", threadID: threadID, role: "user", key: "delta", fields: fields)
        case "conversation.item.input_audio_transcription.completed",
             "conversation.input_transcript.turn_marked":
            await emitTranscript(method: "thread/realtime/transcript/done", threadID: threadID, role: "user", key: "transcript", fields: fields)
        case "response.output_text.delta",
             "response.output_audio_transcript.delta",
             "conversation.output_transcript.delta",
             "output_transcript.added":
            if type == "output_transcript.added",
               case let .object(item)? = fields["item"]
            {
                await emitTranscript(
                    method:
                        "thread/realtime/transcript/delta",
                    threadID: threadID,
                    role: "assistant",
                    key: "text",
                    fields: item
                )
                return
            }
            await emitTranscript(method: "thread/realtime/transcript/delta", threadID: threadID, role: "assistant", key: "delta", fields: fields)
        case "response.output_text.done":
            await emitTranscript(method: "thread/realtime/transcript/done", threadID: threadID, role: "assistant", key: "text", fields: fields)
        case "response.output_audio_transcript.done":
            await emitTranscript(method: "thread/realtime/transcript/done", threadID: threadID, role: "assistant", key: "transcript", fields: fields)
        case "input_audio_buffer.speech_started":
            var item: [String: CodexJSONValue] = ["type": .string(type)]
            if let id = fields["item_id"] { item["item_id"] = id }
            await emitItem(threadID: threadID, item: .object(item))
        case "conversation.item.added", "conversation.item.created":
            if let item = fields["item"] { await emitItem(threadID: threadID, item: item) }
        case "response.cancelled":
            var item: [String: CodexJSONValue] = ["type": .string(type)]
            if let id = fields["response_id"] { item["response_id"] = id }
            await emitItem(threadID: threadID, item: .object(item))
        case "conversation.handoff.requested":
            var item: [String: CodexJSONValue] = [
                "type": .string("handoff_request"),
            ]
            if let value = fields["handoff_id"] {
                item["handoff_id"] = value
            }
            if let value = fields["item_id"] {
                item["item_id"] = value
            }
            if let value = fields["input_transcript"] {
                item["input_transcript"] = value
            }
            item["active_transcript"] = .array([])
            await emitItem(
                threadID: threadID,
                item: .object(item)
            )
        case "delegation.created":
            guard case let .object(delegation)? =
                fields["item"],
                case let .string(kind)? =
                    delegation["type"],
                kind == "delegation",
                case let .string(target)? =
                    delegation["target"],
                target == "client",
                case let .string(itemID)? =
                    delegation["id"]
            else {
                return
            }
            var transcript = ""
            if case let .array(content)? =
                delegation["content"]
            {
                for value in content {
                    guard case let .object(part) = value,
                          part["type"]
                            == .string("input_text"),
                          case let .string(text)? =
                              part["text"]
                    else {
                        continue
                    }
                    transcript += text
                }
            }
            await emitItem(
                threadID: threadID,
                item: .object([
                    "type": .string("handoff_request"),
                    "handoff_id": .string(itemID),
                    "item_id": .string(itemID),
                    "input_transcript": .string(
                        transcript
                    ),
                    "active_transcript": .array([]),
                ])
            )
        case "turn.done":
            guard case let .object(turn)? =
                fields["turn"],
                case let .string(role)? = turn["role"],
                ["user", "assistant"].contains(role)
            else {
                return
            }
            await emitTranscript(
                method: "thread/realtime/transcript/done",
                threadID: threadID,
                role: role,
                key: "transcript",
                fields: turn
            )
        case "error":
            let message: String
            if case let .object(error)? = fields["error"], case let .string(value)? = error["message"] { message = value }
            else if case let .string(value)? = fields["message"] { message = value }
            else { message = "realtime server error" }
            await notificationSink("thread/realtime/error", .object(["threadId": .string(threadID), "message": .string(message)]))
        default:
            return
        }
    }

    private func emitTranscript(method: String, threadID: String, role: String, key: String, fields: [String: CodexJSONValue]) async {
        guard case let .string(text)? = fields[key] else { return }
        let textKey = method.hasSuffix("/done") ? "text" : "delta"
        await notificationSink(method, .object(["threadId": .string(threadID), "role": .string(role), textKey: .string(text)]))
    }

    private func emitItem(threadID: String, item: CodexJSONValue) async {
        await notificationSink("thread/realtime/itemAdded", .object(["threadId": .string(threadID), "item": item]))
    }

    private func emitClosed(threadID: String, reason: String) async {
        await notificationSink("thread/realtime/closed", .object(["threadId": .string(threadID), "reason": .string(reason)]))
    }

    private func emitStarted(
        threadID: String,
        realtimeSessionID: String,
        version: String
    ) async {
        await notificationSink(
            "thread/realtime/started",
            .object([
                "threadId": .string(threadID),
                "realtimeSessionId":
                    .string(realtimeSessionID),
                "version": .string(version),
            ])
        )
    }

    private static func conversationItem(text: String, role: String, contentType: String) -> CodexJSONValue {
        .object([
            "type": .string("conversation.item.create"),
            "item": .object([
                "type": .string("message"), "role": .string(role),
                "content": .array([.object(["type": .string(contentType), "text": .string(text)])]),
            ]),
        ])
    }

    private static func framelessContextAppend(
        text: String,
        channel: String? = nil
    ) -> CodexJSONValue {
        var fields: [String: CodexJSONValue] = [
            "type": .string("session.context.append"),
            "content": .array([
                .object([
                    "type": .string("input_text"),
                    "text": .string(text),
                ]),
            ]),
        ]
        if let channel {
            fields["channel"] = .string(channel)
        }
        return .object(fields)
    }

    private static func sessionUpdate(_ parameters: CodexRealtimeStartParameters) -> CodexJSONValue {
        if parameters.version == "v1" {
            return .object([
                "type": .string("session.update"),
                "session": .object([
                    "type": .string("quicksilver"),
                    "instructions": .string(
                        parameters.prompt
                            ?? "You are Codex, a coding agent."
                    ),
                    "audio": .object([
                        "input": .object([
                            "format": .object([
                                "type":
                                    .string("audio/pcm"),
                                "rate": .integer(24_000),
                            ]),
                        ]),
                        "output": .object([
                            "voice": .string(
                                parameters.voice ?? "cove"
                            ),
                        ]),
                    ]),
                ]),
            ])
        }
        if parameters.version == "v3" {
            var session: [String: CodexJSONValue] = [
                "instructions": .string(
                    parameters.prompt
                        ?? "You are Codex, a coding agent."
                ),
                "audio": .object([
                    "output": .object([
                        "voice": .string(
                            parameters.voice ?? "cove"
                        ),
                    ]),
                ]),
                "delegation": .object([
                    "type": .string("client"),
                ]),
            ]
            if !parameters.initialItems.isEmpty {
                session["initial_items"] = .array(
                    parameters.initialItems.map { item in
                        .object([
                            "type": .string("message"),
                            "role": .string(item.role),
                            "content": .array([
                                .object([
                                    "type":
                                        .string(
                                            item.role
                                                == "assistant"
                                                ? "output_text"
                                                : "input_text"
                                        ),
                                    "text":
                                        .string(item.text),
                                ]),
                            ]),
                        ])
                    }
                )
            }
            return .object([
                "type": .string("session.update"),
                "session": .object(session),
            ])
        }
        let backgroundDescription = "Send a user request to the background agent. Use this as the default action. Do not rephrase the user's ask or rewrite it in your own words; pass along the user's own words. If the background agent is idle, this starts a new task and returns the final result to the user. If the background agent is already working on a task, this sends the request as guidance to steer that previous task. If the user asks to do something next, later, after this, or once current work finishes, call this tool so the work is actually queued instead of merely promising to do it later."
        let silenceDescription = "Call this when the best response is to say nothing. Use it instead of speaking after hidden system/control messages, after background agent updates in silent modes, or whenever acknowledging aloud would be distracting. This tool has no user-visible effect."
        let prompt = parameters.prompt ?? "You are Codex, a coding agent. Use the background_agent tool for coding work and report concise progress to the user."
        let voice = parameters.voice ?? "marin"
        return .object([
            "type": .string("session.update"),
            "session": .object([
                "type": .string("realtime"), "instructions": .string(prompt),
                "output_modalities": .array([.string(parameters.outputModality)]),
                "audio": .object([
                    "input": .object([
                        "format": .object(["type": .string("audio/pcm"), "rate": .integer(24_000)]),
                        "noise_reduction": .object(["type": .string("near_field")]),
                        "transcription": .object(["model": .string("gpt-4o-mini-transcribe")]),
                        "turn_detection": .object(["type": .string("server_vad"), "interrupt_response": .bool(true), "create_response": .bool(true), "silence_duration_ms": .integer(500)]),
                    ]),
                    "output": .object([
                        "format": .object(["type": .string("audio/pcm"), "rate": .integer(24_000)]), "voice": .string(voice),
                    ]),
                ]),
                "tools": .array([
                    .object(["type": .string("function"), "name": .string("background_agent"), "description": .string(backgroundDescription), "parameters": .object(["type": .string("object"), "properties": .object(["prompt": .object(["type": .string("string"), "description": .string("The user request to delegate to the background agent.")])]), "required": .array([.string("prompt")]), "additionalProperties": .bool(false)])]),
                    .object(["type": .string("function"), "name": .string("remain_silent"), "description": .string(silenceDescription), "parameters": .object(["type": .string("object"), "properties": .object([:]), "additionalProperties": .bool(false)])]),
                ]),
                "tool_choice": .string("auto"),
            ]),
        ])
    }

    private static func encode(_ value: CodexJSONValue) throws -> String {
        String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
    }
}
