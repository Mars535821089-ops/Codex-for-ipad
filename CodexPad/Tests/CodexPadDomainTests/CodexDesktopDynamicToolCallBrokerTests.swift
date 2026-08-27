import Foundation
import Testing

@testable import CodexPadApplication
@testable import CodexPadDomain
@testable import CodexPadProtocolBridge

@Test
@MainActor
func desktopDynamicToolCallBrokerPreservesNamespaceAndReturnsMultimodalOutput()
    async throws
{
    var sent: [CodexDesktopHostMessage] = []
    let broker = CodexDesktopDynamicToolCallBroker(
        hostID: "released-renderer",
        dynamicTools: [
            .object([
                "type": .string("namespace"),
                "name": .string("tickets"),
                "description": .string("Ticket tools."),
                "tools": .array([
                    CodexJSONValue.object([
                        "type": .string("function"),
                        "name": .string("lookup_ticket"),
                        "description": .string("Look up a ticket."),
                        "inputSchema": .object(["type": .string("object")]),
                    ])
                ]),
            ])
        ],
        send: { sent.append($0) }
    )
    let request = dynamicToolRequest(
        namespace: "tickets",
        name: "lookup_ticket",
        arguments: #"{"id":"ABC-123"}"#
    )

    #expect(
        broker.canExecute(
            toolName: request.name,
            itemJSON: request.itemJSON
        )
    )
    let task = Task { @MainActor in
        try await broker.execute(
            request,
            cancellation: CodexTurnCancellation()
        )
    }
    let message = try await waitForDynamicToolMessage(in: sent)

    #expect(message.hostID == "released-renderer")
    #expect(message.message.method == "item/tool/call")
    #expect(
        message.message.params == .object([
            "threadId": .string("thread-1"),
            "turnId": .string("turn-1"),
            "callId": .string("call-1"),
            "namespace": .string("tickets"),
            "tool": .string("lookup_ticket"),
            "arguments": .object(["id": .string("ABC-123")]),
        ])
    )

    #expect(
        broker.receive(
            hostID: "released-renderer",
            response: CodexDesktopMCPClientResponse(
                id: message.message.id,
                result: .object([
                    "contentItems": .array([
                        .object([
                            "type": .string("inputText"),
                            "text": .string("Ticket ABC-123 is open."),
                        ]),
                        .object([
                            "type": .string("inputImage"),
                            "imageUrl": .string("file:///tmp/ticket.png"),
                        ]),
                        .object([
                            "type": .string("inputAudio"),
                            "audioUrl": .string("data:audio/wav;base64,AAAA"),
                        ]),
                    ]),
                    "success": .bool(true),
                ]),
                error: nil
            )
        )
    )

    let output = try await task.value
    let object = try dynamicToolJSONObject(output.itemJSON)
    #expect(object["type"] as? String == "function_call_output")
    #expect(object["call_id"] as? String == "call-1")
    let items = try #require(object["output"] as? [[String: Any]])
    #expect(items.map { $0["type"] as? String } == [
        "input_text", "input_image", "input_audio",
    ])
    #expect(items[0]["text"] as? String == "Ticket ABC-123 is open.")
    #expect(items[1]["image_url"] as? String == "file:///tmp/ticket.png")
    #expect(items[2]["audio_url"] as? String == "data:audio/wav;base64,AAAA")
}

@Test
@MainActor
func desktopDynamicToolCallBrokerUsesNullNamespaceAndRejectsWrongIdentity()
    async throws
{
    var sent: [CodexDesktopHostMessage] = []
    let broker = CodexDesktopDynamicToolCallBroker(
        dynamicTools: [dynamicFunction(name: "lookup_ticket")],
        send: { sent.append($0) }
    )
    let request = dynamicToolRequest(
        namespace: nil,
        name: "lookup_ticket",
        arguments: #"{"id":"ABC-123"}"#
    )
    let task = Task { @MainActor in
        try await broker.execute(
            request,
            cancellation: CodexTurnCancellation()
        )
    }
    let message = try await waitForDynamicToolMessage(in: sent)
    guard case let .object(params) = message.message.params else {
        Issue.record("Expected item/tool/call params object")
        return
    }
    #expect(params["namespace"] == .null)

    let result: CodexJSONValue = .object([
        "contentItems": .array([
            .object([
                "type": .string("inputText"),
                "text": .string("done"),
            ])
        ]),
        "success": .bool(false),
    ])
    #expect(
        !broker.receive(
            hostID: "wrong-host",
            response: .init(id: message.message.id, result: result, error: nil)
        )
    )
    #expect(
        !broker.receive(
            hostID: "local",
            response: .init(
                id: .string("wrong-request"),
                result: result,
                error: nil
            )
        )
    )
    #expect(
        broker.receive(
            hostID: "local",
            response: .init(id: message.message.id, result: result, error: nil)
        )
    )
    let output = try await task.value
    let object = try dynamicToolJSONObject(output.itemJSON)
    let items = try #require(object["output"] as? [[String: Any]])
    #expect(items.first?["type"] as? String == "input_text")
    #expect(items.first?["text"] as? String == "done")
    #expect(
        !broker.receive(
            hostID: "local",
            response: .init(id: message.message.id, result: result, error: nil)
        )
    )
}

@Test
@MainActor
func desktopDynamicToolCallBrokerFallsBackForInvalidRendererContent()
    async throws
{
    for invalidResult: CodexJSONValue in [
        .object([
            "contentItems": .array([
                .object([
                    "type": .string("inputImage"),
                    "imageUrl": .string("https://example.test/image.png"),
                ])
            ]),
            "success": .bool(true),
        ]),
        .object([
            "contentItems": .array([
                .object([
                    "type": .string("inputAudio"),
                    "audioUrl": .string("file:///tmp/audio.wav"),
                ])
            ]),
            "success": .bool(true),
        ]),
        .object(["contentItems": .string("invalid")]),
    ] {
        var sent: [CodexDesktopHostMessage] = []
        let broker = CodexDesktopDynamicToolCallBroker(
            dynamicTools: [dynamicFunction(name: "lookup_ticket")],
            send: { sent.append($0) }
        )
        let task = Task { @MainActor in
            try await broker.execute(
                dynamicToolRequest(),
                cancellation: CodexTurnCancellation()
            )
        }
        let message = try await waitForDynamicToolMessage(in: sent)
        #expect(
            broker.receive(
                hostID: "local",
                response: .init(
                    id: message.message.id,
                    result: invalidResult,
                    error: nil
                )
            )
        )
        let output = try await task.value
        let object = try dynamicToolJSONObject(output.itemJSON)
        let items = try #require(object["output"] as? [[String: Any]])
        let fallbackText = items.first?["text"] as? String
        #expect(fallbackText == "dynamic tool response was invalid")
    }
}

@Test
@MainActor
func desktopDynamicToolCallBrokerRejectsUnregisteredOrMismatchedCalls()
    async
{
    let broker = CodexDesktopDynamicToolCallBroker(
        dynamicTools: [dynamicFunction(name: "lookup_ticket")],
        send: { _ in }
    )
    #expect(
        !broker.canExecute(
            toolName: "delete_ticket",
            itemJSON: dynamicToolRequest(name: "delete_ticket").itemJSON
        )
    )
    await #expect(throws: CodexDesktopDynamicToolCallBrokerError.unregisteredTool) {
        _ = try await broker.execute(
            dynamicToolRequest(name: "delete_ticket"),
            cancellation: CodexTurnCancellation()
        )
    }
    await #expect(throws: CodexDesktopDynamicToolCallBrokerError.invalidRequestIdentity) {
        _ = try await broker.execute(
            CodexPersistedTurnToolRequest(
                threadID: CodexStoredThreadID("thread-1"),
                turnID: "turn-1",
                roundIndex: 0,
                name: "lookup_ticket",
                arguments: "{}",
                callID: "call-1",
                itemJSON: #"{"type":"function_call","name":"lookup_ticket","arguments":"{}","call_id":"other-call"}"#
            ),
            cancellation: CodexTurnCancellation()
        )
    }
}

@Test
@MainActor
func desktopDynamicToolCallBrokerTimeoutReturnsOfficialFailureOutput()
    async throws
{
    var sent: [CodexDesktopHostMessage] = []
    let broker = CodexDesktopDynamicToolCallBroker(
        dynamicTools: [dynamicFunction(name: "lookup_ticket")],
        timeoutNanoseconds: 1_000_000,
        send: { sent.append($0) }
    )

    let output = try await broker.execute(
        dynamicToolRequest(),
        cancellation: CodexTurnCancellation()
    )

    #expect(sent.count == 1)
    let object = try dynamicToolJSONObject(output.itemJSON)
    #expect(object["type"] as? String == "function_call_output")
    #expect(object["call_id"] as? String == "call-1")
    let items = try #require(object["output"] as? [[String: Any]])
    #expect(items.first?["type"] as? String == "input_text")
    #expect(items.first?["text"] as? String == "dynamic tool request failed")
}

@Test
@MainActor
func desktopDynamicToolCallBrokerCancelAllResumesEveryPendingCallOnce()
    async throws
{
    var sent: [CodexDesktopHostMessage] = []
    let broker = CodexDesktopDynamicToolCallBroker(
        dynamicTools: [dynamicFunction(name: "lookup_ticket")],
        send: { sent.append($0) }
    )
    let first = Task { @MainActor in
        try await broker.execute(
            dynamicToolRequest(callID: "call-1"),
            cancellation: CodexTurnCancellation()
        )
    }
    let second = Task { @MainActor in
        try await broker.execute(
            dynamicToolRequest(callID: "call-2"),
            cancellation: CodexTurnCancellation()
        )
    }
    let firstMessage = try await waitForDynamicToolMessage(in: sent, at: 0)
    let secondMessage = try await waitForDynamicToolMessage(in: sent, at: 1)

    broker.cancelAll()

    for task in [first, second] {
        do {
            _ = try await task.value
            Issue.record("Cancelled dynamic tool call unexpectedly succeeded")
        } catch {
            #expect(
                error as? CodexDesktopDynamicToolCallBrokerError == .cancelled
            )
        }
    }
    for message in [firstMessage, secondMessage] {
        #expect(
            !broker.receive(
                hostID: "local",
                response: .init(
                    id: message.message.id,
                    result: .object([
                        "contentItems": .array([
                            .object([
                                "type": .string("inputText"),
                                "text": .string("late"),
                            ])
                        ]),
                        "success": .bool(true),
                    ]),
                    error: nil
                )
            )
        )
    }
}

@Test
@MainActor
func desktopDynamicToolCallBrokerTaskCancellationReleasesPendingCall()
    async throws
{
    var sent: [CodexDesktopHostMessage] = []
    let broker = CodexDesktopDynamicToolCallBroker(
        dynamicTools: [dynamicFunction(name: "lookup_ticket")],
        send: { sent.append($0) }
    )
    let task = Task { @MainActor in
        try await broker.execute(
            dynamicToolRequest(),
            cancellation: CodexTurnCancellation()
        )
    }
    let message = try await waitForDynamicToolMessage(in: sent)

    task.cancel()

    do {
        _ = try await task.value
        Issue.record("Cancelled dynamic tool call unexpectedly succeeded")
    } catch {
        #expect(
            error as? CodexDesktopDynamicToolCallBrokerError == .cancelled
        )
    }
    #expect(
        !broker.receive(
            hostID: "local",
            response: .init(
                id: message.message.id,
                result: .object([
                    "contentItems": .array([
                        .object([
                            "type": .string("inputText"),
                            "text": .string("late"),
                        ])
                    ]),
                    "success": .bool(true),
                ]),
                error: nil
            )
        )
    )
}

private func dynamicFunction(name: String) -> CodexJSONValue {
    .object([
        "type": .string("function"),
        "name": .string(name),
        "description": .string("Dynamic function."),
        "inputSchema": .object(["type": .string("object")]),
    ])
}

private func dynamicToolRequest(
    namespace: String? = nil,
    name: String = "lookup_ticket",
    arguments: String = "{}",
    callID: String = "call-1"
) -> CodexPersistedTurnToolRequest {
    var item: [String: Any] = [
        "type": "function_call",
        "name": name,
        "arguments": arguments,
        "call_id": callID,
    ]
    if let namespace {
        item["namespace"] = namespace
    }
    let data = try! JSONSerialization.data(withJSONObject: item, options: [.sortedKeys])
    return CodexPersistedTurnToolRequest(
        threadID: CodexStoredThreadID("thread-1"),
        turnID: "turn-1",
        roundIndex: 0,
        name: name,
        arguments: arguments,
        callID: callID,
        itemJSON: String(decoding: data, as: UTF8.self)
    )
}

private struct DynamicToolMessage {
    let hostID: String
    let message: CodexDesktopMCPRequestMessage
}

@MainActor
private func waitForDynamicToolMessage(
    in messages: @autoclosure () -> [CodexDesktopHostMessage],
    at index: Int = 0
) async throws -> DynamicToolMessage {
    for _ in 0..<1_000 {
        let messages = messages()
        if messages.indices.contains(index),
           case let .mcpRequest(hostID, message, _) = messages[index]
        {
            return DynamicToolMessage(hostID: hostID, message: message)
        }
        await Task.yield()
    }
    throw DynamicToolTestError.messageNotSent
}

private func dynamicToolJSONObject(_ itemJSON: String) throws -> [String: Any] {
    try #require(
        JSONSerialization.jsonObject(with: Data(itemJSON.utf8))
            as? [String: Any]
    )
}

private enum DynamicToolTestError: Error {
    case messageNotSent
}
