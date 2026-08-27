import Foundation
import Testing

@testable import CodexPadApplication
@testable import CodexPadDomain
@testable import CodexPadProtocolBridge

@Test
@MainActor
func desktopServerRequestBrokerUsesNativeHandlerWithoutRendererRoundTrip()
    async throws
{
    var sent: [CodexDesktopHostMessage] = []
    let broker = CodexDesktopServerRequestBroker(
        nativeHandler: { method, params in
            guard method == "currentTime/read" else { return nil }
            #expect(
                params
                    == .object(["threadId": .string("thread-native")])
            )
            return .object(["currentTimeAt": .integer(42)])
        },
        send: { sent.append($0) }
    )

    let result = try await broker.request(
        method: "currentTime/read",
        params: .object(["threadId": .string("thread-native")]),
        threadID: "thread-native"
    )

    #expect(result == .object(["currentTimeAt": .integer(42)]))
    #expect(sent.isEmpty)
}

@Test
@MainActor
func desktopServerRequestBrokerFallsBackForUnknownNativeRequest()
    async throws
{
    var sent: [CodexDesktopHostMessage] = []
    let broker = CodexDesktopServerRequestBroker(
        nativeHandler: { _, _ in nil },
        send: { sent.append($0) }
    )
    let task = Task { @MainActor in
        try await broker.request(
            method: "mcpServer/elicitation/request",
            params: .object(["threadId": .string("thread-fallback")]),
            threadID: "thread-fallback",
            timeoutNanoseconds: 10_000_000_000
        )
    }
    let request = try await waitForServerRequest(in: sent)
    let expected: CodexJSONValue = .object([
        "action": .string("accept"),
        "content": .null,
    ])

    #expect(
        broker.receive(
            hostID: "local",
            response: .init(
                id: request.message.id,
                result: expected,
                error: nil
            )
        )
    )
    #expect(try await task.value == expected)
}

@Test
@MainActor
func desktopServerRequestBrokerRoundTripsOfficialMcpElicitation()
    async throws
{
    var sent: [CodexDesktopHostMessage] = []
    let broker = CodexDesktopServerRequestBroker(
        hostID: "released-renderer",
        send: { sent.append($0) }
    )
    let params: CodexJSONValue = .object([
        "threadId": .string("thread-1"),
        "turnId": .string("turn-2"),
        "serverName": .string("codex_apps"),
        "mode": .string("form"),
        "_meta": .object(["trace": .string("keep")]),
        "message": .string("Allow this request?"),
        "requestedSchema": .object([
            "type": .string("object"),
            "properties": .object([
                "confirmed": .object(["type": .string("boolean")])
            ]),
            "required": .array([.string("confirmed")]),
        ]),
    ])

    let task = Task { @MainActor in
        try await broker.request(
            method: "mcpServer/elicitation/request",
            params: params,
            threadID: "thread-1",
            timeoutNanoseconds: 10_000_000_000
        )
    }
    let request = try await waitForServerRequest(in: sent)

    #expect(request.hostID == "released-renderer")
    #expect(request.message.method == "mcpServer/elicitation/request")
    #expect(request.message.params == params)
    #expect(
        broker.receive(
            hostID: "released-renderer",
            response: CodexDesktopMCPClientResponse(
                id: request.message.id,
                result: .object([
                    "action": .string("accept"),
                    "content": .object(["confirmed": .bool(true)]),
                    "_meta": .object(["persist": .bool(true)]),
                ]),
                error: nil
            )
        )
    )
    let expectedResult: CodexJSONValue = .object([
        "action": .string("accept"),
        "content": .object(["confirmed": .bool(true)]),
        "_meta": .object(["persist": .bool(true)]),
    ])
    #expect(try await task.value == expectedResult)
    let resolved = try await waitForResolvedServerRequest(
        in: sent,
        requestID: request.message.id
    )
    #expect(
        resolved.params
            == .object([
                "threadId": .string("thread-1"),
                "requestId": .string("server-request-1"),
            ])
    )
}

@Test(arguments: ["accept", "decline", "cancel"])
@MainActor
func desktopServerRequestBrokerPreservesEveryElicitationAction(
    action: String
) async throws {
    var sent: [CodexDesktopHostMessage] = []
    let broker = CodexDesktopServerRequestBroker(
        send: { sent.append($0) }
    )
    let task = Task { @MainActor in
        try await broker.request(
            method: "mcpServer/elicitation/request",
            params: .object([
                "threadId": .string("thread-actions"),
                "turnId": .null,
                "serverName": .string("fixture"),
                "mode": .string("url"),
                "_meta": .null,
                "message": .string("Finish sign-in"),
                "url": .string("https://example.test/complete"),
                "elicitationId": .string("elicitation-1"),
            ]),
            threadID: "thread-actions",
            timeoutNanoseconds: 10_000_000_000
        )
    }
    let request = try await waitForServerRequest(in: sent)
    let result: CodexJSONValue = .object([
        "action": .string(action),
        "content": .null,
        "_meta": .null,
    ])
    #expect(
        broker.receive(
            hostID: "local",
            response: .init(
                id: request.message.id,
                result: result,
                error: nil
            )
        )
    )
    #expect(try await task.value == result)
}

@Test
@MainActor
func desktopServerRequestBrokerRejectsWrongIdentityAndRemoteErrors()
    async throws
{
    var sent: [CodexDesktopHostMessage] = []
    let broker = CodexDesktopServerRequestBroker(
        hostID: "expected-host",
        send: { sent.append($0) }
    )
    let task = Task { @MainActor in
        try await broker.request(
            method: "mcpServer/elicitation/request",
            params: .object(["threadId": .string("thread-errors")]),
            threadID: "thread-errors",
            timeoutNanoseconds: 10_000_000_000
        )
    }
    let request = try await waitForServerRequest(in: sent)
    #expect(
        !broker.receive(
            hostID: "wrong-host",
            response: .init(
                id: request.message.id,
                result: .object([:]),
                error: nil
            )
        )
    )
    let remoteError: CodexJSONValue = .object([
        "code": .integer(-32_603),
        "message": .string("renderer failed"),
    ])
    #expect(
        broker.receive(
            hostID: "expected-host",
            response: .init(
                id: request.message.id,
                result: nil,
                error: remoteError
            )
        )
    )
    await #expect(
        throws: CodexDesktopServerRequestBrokerError.remoteError(
            remoteError
        )
    ) {
        try await task.value
    }
}

private struct ServerRequestMessage {
    let hostID: String
    let message: CodexDesktopMCPRequestMessage
}

private struct ResolvedServerRequestMessage {
    let params: CodexJSONValue
}

@MainActor
private func waitForServerRequest(
    in sent: @autoclosure () -> [CodexDesktopHostMessage]
) async throws -> ServerRequestMessage {
    for _ in 0..<200 {
        if let value = sent().compactMap({ message -> ServerRequestMessage? in
            guard case let .mcpRequest(hostID, request, _) = message
            else { return nil }
            return .init(hostID: hostID, message: request)
        }).first {
            return value
        }
        await Task.yield()
    }
    throw CodexDesktopServerRequestBrokerError.cancelled
}

@MainActor
private func waitForResolvedServerRequest(
    in sent: @autoclosure () -> [CodexDesktopHostMessage],
    requestID: CodexAppServerRequestID
) async throws -> ResolvedServerRequestMessage {
    for _ in 0..<200 {
        for message in sent() {
            guard case let .mcpNotification(
                _, method, params, _
            ) = message,
            method == "serverRequest/resolved",
            case let .object(fields) = params
            else { continue }
            let expected: CodexJSONValue = switch requestID {
            case let .string(value): .string(value)
            case let .integer(value): .integer(value)
            }
            guard fields["requestId"] == expected else { continue }
            return .init(params: params)
        }
        await Task.yield()
    }
    throw CodexDesktopServerRequestBrokerError.cancelled
}
