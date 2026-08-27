import Foundation
import Testing

@testable import CodexPadApplication
@testable import CodexPadDomain
@testable import CodexPadProtocolBridge

@Test
func environmentServiceUsesReleasedExecServerHandshakeAndRPC()
    async throws
{
    let socket = EnvironmentMockSocket(
        responses: [
            "initialize": .object([
                "sessionId": .string("ipad-session"),
            ]),
            "environment/info": .object([
                "shell": .object([
                    "name": .string("zsh"),
                    "path": .string("/bin/zsh"),
                ]),
                "cwd": .string("file:///workspace"),
                "capabilities": .object([
                    "networkProxyLaunch": .bool(true),
                ]),
            ]),
            "environment/status": .object([
                "status": .string("ready"),
            ]),
        ]
    )
    let connector = EnvironmentMockConnector(socket: socket)
    let service = CodexEnvironmentService(
        connector: connector,
        defaultConnectTimeoutMs: 1_000
    )

    try await service.addEnvironment(
        CodexEnvironmentAddParameters(
            environmentID: "remote-a",
            execServerURL: URL(string: "ws://127.0.0.1:4510")!,
            connectTimeoutMs: 1_000
        )
    )
    let info = try await service.environmentInfo(
        environmentID: "remote-a"
    )
    let status = await service.environmentStatus(
        environmentID: "remote-a"
    )

    #expect(
        info == CodexEnvironmentInfo(
            shell: .init(name: "zsh", path: "/bin/zsh"),
            cwd: "file:///workspace"
        )
    )
    #expect(status == CodexEnvironmentStatus(status: .ready))
    #expect(
        await socket.sentMethods
            == [
                "initialize",
                "initialized",
                "environment/info",
                "environment/status",
            ]
    )
    let request = try #require(await connector.requests.first)
    #expect(request.url?.absoluteString == "ws://127.0.0.1:4510")
    #expect(request.timeoutInterval == 1)
}

@Test
func environmentServiceReportsPendingUnknownAndReplacement()
    async throws
{
    let first = EnvironmentMockSocket(responses: [:])
    let second = EnvironmentMockSocket(responses: [:])
    let connector = EnvironmentSequenceConnector(
        sockets: [first, second]
    )
    let service = CodexEnvironmentService(
        connector: connector,
        defaultConnectTimeoutMs: 5_000
    )
    let parameters = CodexEnvironmentAddParameters(
        environmentID: "remote-a",
        execServerURL: URL(string: "wss://executor.example/ws")!,
        connectTimeoutMs: nil
    )

    try await service.addEnvironment(parameters)
    try await waitForEnvironmentMethod(
        "initialize",
        socket: first
    )
    #expect(
        await service.environmentStatus(environmentID: "remote-a")
            == CodexEnvironmentStatus(status: .pending)
    )
    #expect(
        await service.environmentStatus(environmentID: "missing")
            == CodexEnvironmentStatus(
                status: .unknown,
                error: "unknown environment id `missing`"
            )
    )

    try await service.addEnvironment(parameters)
    #expect(await first.isClosed)
}

@Test @MainActor
func environmentRouterMatchesOfficialResultAndErrorShapes()
    async
{
    let manager = EnvironmentRecordingManager()
    let state = environmentRouterState()

    let add = await CodexDesktopInitialMCPRouter
        .responseIncludingFileSystem(
            to: environmentRequest(
                id: 1,
                method: "environment/add",
                params: .object([
                    "environmentId": .string("remote-a"),
                    "execServerUrl": .string(
                        "ws://127.0.0.1:4510"
                    ),
                    "connectTimeoutMs": .integer(2_500),
                ])
            ),
            state: state,
            allowedFileSystemRoots: [],
            environmentManager: manager
        )
    let info = await CodexDesktopInitialMCPRouter
        .responseIncludingFileSystem(
            to: environmentRequest(
                id: 2,
                method: "environment/info",
                params: .object([
                    "environmentId": .string("remote-a"),
                ])
            ),
            state: state,
            allowedFileSystemRoots: [],
            environmentManager: manager
        )
    let unknown = await CodexDesktopInitialMCPRouter
        .responseIncludingFileSystem(
            to: environmentRequest(
                id: 3,
                method: "environment/info",
                params: .object([
                    "environmentId": .string("missing"),
                ])
            ),
            state: state,
            allowedFileSystemRoots: [],
            environmentManager: manager
        )

    #expect(
        add == environmentResponse(
            id: 1,
            payload: .object([:])
        )
    )
    #expect(
        await manager.added
            == CodexEnvironmentAddParameters(
                environmentID: "remote-a",
                execServerURL: URL(
                    string: "ws://127.0.0.1:4510"
                )!,
                connectTimeoutMs: 2_500
            )
    )
    #expect(
        info == environmentResponse(
            id: 2,
            payload: .object([
                "shell": .object([
                    "name": .string("fish"),
                    "path": .string("/opt/homebrew/bin/fish"),
                ]),
                "cwd": .null,
            ])
        )
    )
    #expect(
        unknown == .mcpResponse(
            hostID: "environment-host",
            message: .object([
                "id": .integer(3),
                "error": .object([
                    "code": .integer(-32600),
                    "message": .string(
                        "unknown environment id `missing`"
                    ),
                ]),
            ]),
            metadata: [:]
        )
    )
}

@Test @MainActor
func realtimeVoiceListMatchesReleasedBuiltinCatalog() async {
    let response = await CodexDesktopInitialMCPRouter
        .responseIncludingFileSystem(
            to: environmentRequest(
                id: 4,
                method: "thread/realtime/listVoices",
                params: .object([:])
            ),
            state: environmentRouterState(),
            allowedFileSystemRoots: []
        )

    #expect(
        response == environmentResponse(
            id: 4,
            payload: .object([
                "voices": .object([
                    "v1": .array(
                        [
                            "juniper", "maple", "spruce",
                            "ember", "vale", "breeze",
                            "arbor", "sol", "cove",
                        ].map(CodexJSONValue.string)
                    ),
                    "v2": .array(
                        [
                            "alloy", "ash", "ballad",
                            "coral", "echo", "sage",
                            "shimmer", "verse", "marin",
                            "cedar",
                        ].map(CodexJSONValue.string)
                    ),
                    "defaultV1": .string("cove"),
                    "defaultV2": .string("marin"),
                ]),
            ])
        )
    )
}

private actor EnvironmentMockConnector:
    CodexRemoteControlWebSocketConnecting
{
    let socket: EnvironmentMockSocket
    private(set) var requests: [URLRequest] = []

    init(socket: EnvironmentMockSocket) {
        self.socket = socket
    }

    func connect(
        request: URLRequest
    ) async throws -> any CodexRemoteControlWebSocketSocket {
        requests.append(request)
        return socket
    }
}

private actor EnvironmentSequenceConnector:
    CodexRemoteControlWebSocketConnecting
{
    private var sockets: [EnvironmentMockSocket]

    init(sockets: [EnvironmentMockSocket]) {
        self.sockets = sockets
    }

    func connect(
        request _: URLRequest
    ) async throws -> any CodexRemoteControlWebSocketSocket {
        guard !sockets.isEmpty else {
            throw CodexEnvironmentServiceError.protocolFailure(
                "no mock socket"
            )
        }
        return sockets.removeFirst()
    }
}

private actor EnvironmentMockSocket:
    CodexRemoteControlWebSocketSocket
{
    private let responses: [String: CodexJSONValue]
    private var frames:
        [CodexRemoteControlWebSocketFrame] = []
    private var receiver:
        CheckedContinuation<
            CodexRemoteControlWebSocketFrame,
            any Error
        >?
    private(set) var sentMethods: [String] = []
    private(set) var isClosed = false

    init(responses: [String: CodexJSONValue]) {
        self.responses = responses
    }

    func send(text: String) async throws {
        let value = try JSONDecoder().decode(
            CodexJSONValue.self,
            from: Data(text.utf8)
        )
        guard case let .object(message) = value,
              case let .string(method)? = message["method"]
        else {
            throw CodexEnvironmentServiceError.protocolFailure(
                "invalid mock request"
            )
        }
        sentMethods.append(method)
        guard case let .integer(requestID)? = message["id"],
              let result = responses[method]
        else {
            return
        }
        let response = CodexJSONValue.object([
            "jsonrpc": .string("2.0"),
            "id": .integer(requestID),
            "result": result,
        ])
        let data = try JSONEncoder().encode(response)
        enqueue(.text(String(decoding: data, as: UTF8.self)))
    }

    func sendPing() async throws {}

    func receive() async throws
        -> CodexRemoteControlWebSocketFrame
    {
        if !frames.isEmpty {
            return frames.removeFirst()
        }
        return try await withCheckedThrowingContinuation {
            receiver = $0
        }
    }

    func close() async {
        isClosed = true
        enqueue(.closed(code: 1000, reason: "closed"))
    }

    private func enqueue(
        _ frame: CodexRemoteControlWebSocketFrame
    ) {
        if let receiver {
            self.receiver = nil
            receiver.resume(returning: frame)
        } else {
            frames.append(frame)
        }
    }
}

private actor EnvironmentRecordingManager:
    CodexDesktopEnvironmentManaging
{
    private(set) var added: CodexEnvironmentAddParameters?

    func addEnvironment(
        _ parameters: CodexEnvironmentAddParameters
    ) async throws {
        added = parameters
    }

    func environmentInfo(
        environmentID: String
    ) async throws -> CodexEnvironmentInfo {
        guard environmentID != "missing" else {
            throw CodexEnvironmentServiceError
                .unknownEnvironment(environmentID)
        }
        return CodexEnvironmentInfo(
            shell: .init(
                name: "fish",
                path: "/opt/homebrew/bin/fish"
            ),
            cwd: nil
        )
    }

    func environmentStatus(
        environmentID _: String
    ) async -> CodexEnvironmentStatus {
        CodexEnvironmentStatus(status: .ready)
    }
}

private func waitForEnvironmentMethod(
    _ method: String,
    socket: EnvironmentMockSocket
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(1))
    while !(await socket.sentMethods.contains(method)) {
        guard clock.now < deadline else {
            throw CodexEnvironmentServiceError.requestTimedOut(
                method
            )
        }
        try await Task.sleep(for: .milliseconds(5))
    }
}

private func environmentRequest(
    id: Int64,
    method: String,
    params: CodexJSONValue
) -> CodexDesktopMCPRequest {
    CodexDesktopMCPRequest(
        request: .init(
            id: .integer(id),
            method: method,
            params: params,
            metadata: [:]
        ),
        hostID: "environment-host",
        dispatchedAtMs: nil,
        priority: nil,
        source: nil,
        timeoutMs: nil,
        expiresAtMs: nil,
        metadata: [:]
    )
}

private func environmentResponse(
    id: Int64,
    payload: CodexJSONValue
) -> CodexDesktopHostMessage {
    .mcpResponse(
        hostID: "environment-host",
        message: .object([
            "id": .integer(id),
            "result": payload,
        ]),
        metadata: [:]
    )
}

private func environmentRouterState()
    -> CodexDesktopInitialMCPState
{
    .init(
        account: .init(
            account: nil,
            authMethod: nil,
            requiresOpenAIAuth: true
        ),
        config: .init(
            config: [:],
            origins: [:],
            layers: []
        ),
        remoteControl: .init(
            status: .disabled,
            serverName: "Codex",
            installationID: "installation",
            environmentID: nil
        )
    )
}
