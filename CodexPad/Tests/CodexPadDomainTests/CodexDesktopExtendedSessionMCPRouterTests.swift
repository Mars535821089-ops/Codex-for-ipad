import Testing

@testable import CodexPadApplication
@testable import CodexPadDomain
@testable import CodexPadProtocolBridge

@Test @MainActor
func desktopExtendedSessionMethodsForwardOpaqueContractsAndResults() async {
    let backend = ExtendedSessionBackendProbe()
    let cases: [(String, [String: CodexJSONValue])] = [
        (
            "thread/startAeon",
            [
                "threadId": .string("thread-aeon"),
                "desktopExtensionField": .string("preserve-me"),
            ]
        ),
        (
            "thread/stop",
            ["threadId": .string("thread-stop")]
        ),
        (
            "interactive/liveSessions/list",
            ["desktopExtensionField": .bool(true)]
        ),
        (
            "interactive/session/upload",
            [
                "sessionId": .string("session-upload"),
                "desktopExtensionField": .integer(7),
            ]
        ),
        (
            "interactive/sessionSandbox/list",
            [
                "sessionId": .string("session-list"),
                "path": .string("artifacts"),
            ]
        ),
        (
            "interactive/sessionSandbox/read",
            [
                "sessionId": .string("session-read"),
                "path": .string("artifacts/report.txt"),
            ]
        ),
    ]

    for (offset, entry) in cases.enumerated() {
        let id = CodexAppServerRequestID.integer(Int64(700 + offset))
        let response = await CodexDesktopInitialMCPRouter
            .responseIncludingFileSystem(
                to: extendedSessionRequest(
                    id: id,
                    method: entry.0,
                    params: .object(entry.1)
                ),
                state: extendedSessionState(),
                allowedFileSystemRoots: [],
                extendedSessionBackend: backend
            )

        #expect(
            response == extendedSessionResult(
                id: id,
                value: .object([
                    "forwardedMethod": .string(entry.0),
                    "forwardedParams": .object(entry.1),
                ])
            )
        )
    }

    let calls = await backend.calls
    #expect(calls.count == cases.count)
    for (offset, call) in calls.enumerated() {
        #expect(
            call.id
                == .integer(Int64(700 + offset))
        )
        #expect(call.method.rawValue == cases[offset].0)
        #expect(call.params == cases[offset].1)
    }
}

@Test @MainActor
func desktopExtendedSessionMethodsReportDisconnectedBackend() async {
    for (offset, method) in CodexDesktopExtendedSessionMethod
        .allCases
        .enumerated()
    {
        let id = CodexAppServerRequestID.integer(Int64(800 + offset))
        let params: CodexJSONValue =
            method == .threadStop
                ? .object(["threadId": .string("thread-stop")])
                : .object([:])
        let response = await CodexDesktopInitialMCPRouter
            .responseIncludingFileSystem(
                to: extendedSessionRequest(
                    id: id,
                    method: method.rawValue,
                    params: params
                ),
                state: extendedSessionState(),
                allowedFileSystemRoots: []
            )

        #expect(
            response == extendedSessionError(
                id: id,
                code: -32603,
                message:
                    "Desktop extended session service not connected"
            )
        )
    }
}

@Test @MainActor
func desktopThreadStopRequiresReleasedThreadIDContract() async {
    let backend = ExtendedSessionBackendProbe()
    for (offset, params) in [
        nil,
        CodexJSONValue.null,
        .object([:]),
        .object(["threadId": .string("")]),
        .object(["threadId": .integer(1)]),
    ].enumerated() {
        let id = CodexAppServerRequestID.integer(Int64(900 + offset))
        let response = await CodexDesktopInitialMCPRouter
            .responseIncludingFileSystem(
                to: extendedSessionRequest(
                    id: id,
                    method: "thread/stop",
                    params: params
                ),
                state: extendedSessionState(),
                allowedFileSystemRoots: [],
                extendedSessionBackend: backend
            )
        #expect(
            response == extendedSessionError(
                id: id,
                code: -32602,
                message: "Invalid params for thread/stop"
            )
        )
    }
    #expect(await backend.calls.isEmpty)
}

@Test
func desktopExtendedSessionDispatcherPreservesCompleteRequestEnvelope() async
    throws
{
    let request = CodexDesktopExtendedSessionRequest(
        id: .string("aeon-request-1"),
        method: .threadStartAeon,
        params: [
            "model": .string("gpt-test"),
            "desktopExtensionField": .integer(17),
        ]
    )
    let recorder = ExtendedSessionRequestRecorder()
    let backend = CodexDesktopExtendedSessionBackend(
        handlers: .init(
            threadStartAeon: { request in
                await recorder.record(request)
                return .object([
                    "requestId": extendedSessionIDValue(request.id),
                    "method": .string(request.method.rawValue),
                    "params": .object(request.params),
                ])
            }
        )
    )

    let result = try await backend.send(request)

    #expect(
        result == .object([
            "requestId": .string("aeon-request-1"),
            "method": .string("thread/startAeon"),
            "params": .object(request.params),
        ])
    )
    #expect(await recorder.requests == [request])
}

@Test
func desktopExtendedSessionDispatcherRejectsMissingHandler() async {
    let backend = CodexDesktopExtendedSessionBackend(
        handlers: .init()
    )
    let request = CodexDesktopExtendedSessionRequest(
        id: .integer(1001),
        method: .interactiveSessionUpload,
        params: [:]
    )

    await #expect(
        throws: CodexDesktopExtendedSessionBackend.Error
            .handlerUnavailable(.interactiveSessionUpload)
    ) {
        try await backend.send(request)
    }
}

@Test @MainActor
func desktopExtendedSessionAdapterErrorsRetainRPCClassification() async {
    let malformedID = CodexAppServerRequestID.integer(1101)
    let malformed = await CodexDesktopInitialMCPRouter
        .responseIncludingFileSystem(
            to: extendedSessionRequest(
                id: malformedID,
                method: "interactive/sessionSandbox/read",
                params: .object([
                    "sessionId": .string("session-a"),
                ])
            ),
            state: extendedSessionState(),
            allowedFileSystemRoots: [],
            extendedSessionBackend:
                ExtendedSessionErrorBackend(
                    error: .malformedParams(
                        .interactiveSessionSandboxRead
                    )
                )
        )
    #expect(
        malformed == extendedSessionError(
            id: malformedID,
            code: -32602,
            message:
                "Invalid params for interactive/sessionSandbox/read"
        )
    )

    let unavailableID = CodexAppServerRequestID.integer(1102)
    let unavailable = await CodexDesktopInitialMCPRouter
        .responseIncludingFileSystem(
            to: extendedSessionRequest(
                id: unavailableID,
                method: "interactive/liveSessions/list",
                params: .object([:])
            ),
            state: extendedSessionState(),
            allowedFileSystemRoots: [],
            extendedSessionBackend:
                ExtendedSessionErrorBackend(
                    error: .capabilityUnavailable(
                        .interactiveLiveSessionsList
                    )
                )
        )
    #expect(
        unavailable == extendedSessionError(
            id: unavailableID,
            code: -32603,
            message:
                "Desktop extended session capability unavailable"
        )
    )
}

private actor ExtendedSessionRequestRecorder {
    private(set) var requests:
        [CodexDesktopExtendedSessionRequest] = []

    func record(_ request: CodexDesktopExtendedSessionRequest) {
        requests.append(request)
    }
}

private actor ExtendedSessionErrorBackend:
    CodexDesktopExtendedSessionRequesting
{
    let error: CodexDesktopExtendedSessionAdapter.Error

    init(error: CodexDesktopExtendedSessionAdapter.Error) {
        self.error = error
    }

    func send(
        _ request: CodexDesktopExtendedSessionRequest
    ) async throws -> CodexJSONValue {
        throw error
    }
}

private actor ExtendedSessionBackendProbe:
    CodexDesktopExtendedSessionRequesting
{
    private(set) var calls: [CodexDesktopExtendedSessionRequest] = []

    func send(
        _ request: CodexDesktopExtendedSessionRequest
    ) async throws -> CodexJSONValue {
        calls.append(request)
        return .object([
            "forwardedMethod": .string(request.method.rawValue),
            "forwardedParams": .object(request.params),
        ])
    }
}

private func extendedSessionState()
    -> CodexDesktopInitialMCPState
{
    CodexDesktopInitialMCPState(
        account: CodexDesktopMCPAccountState(
            account: nil,
            authMethod: nil,
            requiresOpenAIAuth: true
        ),
        config: CodexDesktopMCPConfigState(
            config: [:],
            origins: [:],
            layers: []
        ),
        remoteControl: CodexDesktopMCPRemoteControlState(
            status: .disabled,
            serverName: "Codex-for-iPad",
            installationID: "test-installation",
            environmentID: nil
        )
    )
}

private func extendedSessionRequest(
    id: CodexAppServerRequestID,
    method: String,
    params: CodexJSONValue?
) -> CodexDesktopMCPRequest {
    CodexDesktopMCPRequest(
        request: CodexDesktopMCPRequestMessage(
            id: id,
            method: method,
            params: params,
            metadata: [:]
        ),
        hostID: "desktop-host-1",
        dispatchedAtMs: nil,
        priority: nil,
        source: nil,
        timeoutMs: nil,
        expiresAtMs: nil,
        metadata: [:]
    )
}

private func extendedSessionResult(
    id: CodexAppServerRequestID,
    value: CodexJSONValue
) -> CodexDesktopHostMessage {
    .mcpResponse(
        hostID: "desktop-host-1",
        message: .object([
            "id": extendedSessionIDValue(id),
            "result": value,
        ]),
        metadata: [:]
    )
}

private func extendedSessionError(
    id: CodexAppServerRequestID,
    code: Int64,
    message: String
) -> CodexDesktopHostMessage {
    .mcpResponse(
        hostID: "desktop-host-1",
        message: .object([
            "id": extendedSessionIDValue(id),
            "error": .object([
                "code": .integer(code),
                "message": .string(message),
            ]),
        ]),
        metadata: [:]
    )
}

private func extendedSessionIDValue(
    _ id: CodexAppServerRequestID
) -> CodexJSONValue {
    switch id {
    case let .integer(value):
        return .integer(value)
    case let .string(value):
        return .string(value)
    }
}
