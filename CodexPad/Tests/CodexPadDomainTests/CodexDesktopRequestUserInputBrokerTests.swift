import Foundation
import Testing

@testable import CodexPadApplication
@testable import CodexPadDomain
@testable import CodexPadProtocolBridge

@Test
@MainActor
func desktopRequestUserInputBrokerSendsOfficialRequestAndReturnsAnswers()
    async throws
{
    var sent: [CodexDesktopHostMessage] = []
    let broker = CodexDesktopRequestUserInputBroker(
        hostID: "released-renderer",
        send: { sent.append($0) }
    )
    let prompt = CodexRequestUserInputPrompt(
        threadID: "thread-1",
        turnID: "turn-2",
        itemID: "item-3",
        questions: [
            CodexRequestUserInputQuestion(
                id: "scope",
                header: "Scope",
                question: "Which scope?",
                options: [
                    CodexRequestUserInputOption(
                        label: "Current file",
                        description: "Only update the current file."
                    ),
                    CodexRequestUserInputOption(
                        label: "Workspace",
                        description: "Update the whole workspace."
                    ),
                ]
            )
        ],
        autoResolutionMS: 90_000
    )

    let requestTask = Task { @MainActor in
        try await broker.request(
            prompt,
            timeoutNanoseconds: 10_000_000_000
        )
    }
    let request = try await waitForRequestUserInputMessage(in: sent)

    #expect(request.hostID == "released-renderer")
    #expect(request.message.method == "item/tool/requestUserInput")
    #expect(request.message.metadata.isEmpty)
    #expect(request.metadata.isEmpty)
    #expect(
        request.message.params
            == .object([
                "threadId": .string("thread-1"),
                "turnId": .string("turn-2"),
                "itemId": .string("item-3"),
                "questions": .array([
                    .object([
                        "id": .string("scope"),
                        "header": .string("Scope"),
                        "question": .string("Which scope?"),
                        "options": .array([
                            .object([
                                "label": .string("Current file"),
                                "description": .string(
                                    "Only update the current file."
                                ),
                            ]),
                            .object([
                                "label": .string("Workspace"),
                                "description": .string(
                                    "Update the whole workspace."
                                ),
                            ]),
                        ]),
                    ])
                ]),
                "autoResolutionMs": .integer(90_000),
            ])
    )

    #expect(
        broker.receive(
            hostID: "released-renderer",
            response: CodexDesktopMCPClientResponse(
                id: request.message.id,
                result: .object([
                    "answers": .object([
                        "scope": .object([
                            "answers": .array([
                                .string("Current file")
                            ])
                        ])
                    ])
                ]),
                error: nil
            )
        )
    )
    #expect(
        try await requestTask.value
            == CodexRequestUserInputAnswers(
                answers: [
                    "scope": CodexRequestUserInputAnswer(
                        answers: ["Current file"]
                    )
                ]
            )
    )
    let resolved = try await waitForResolvedRequestMessage(
        in: sent,
        requestID: request.message.id
    )
    #expect(resolved.hostID == "released-renderer")
    #expect(resolved.method == "serverRequest/resolved")
    #expect(
        resolved.params
            == .object([
                "threadId": .string("thread-1"),
                "requestId": .string("request-user-input-1"),
            ])
    )
    #expect(resolved.metadata.isEmpty)
}

@Test
@MainActor
func desktopRequestUserInputBrokerOnlyConsumesItsPendingHostAndID()
    async throws
{
    var sent: [CodexDesktopHostMessage] = []
    let broker = CodexDesktopRequestUserInputBroker(
        hostID: "expected-host",
        send: { sent.append($0) }
    )
    let task = Task { @MainActor in
        try await broker.request(
            requestUserInputPrompt(),
            timeoutNanoseconds: 10_000_000_000
        )
    }
    let request = try await waitForRequestUserInputMessage(in: sent)
    let answerResult: CodexJSONValue = .object([
        "answers": .object([
            "choice": .object([
                "answers": .array([.string("One")])
            ])
        ])
    ])

    #expect(
        !broker.receive(
            hostID: "other-host",
            response: CodexDesktopMCPClientResponse(
                id: request.message.id,
                result: answerResult,
                error: nil
            )
        )
    )
    #expect(
        !broker.receive(
            hostID: "expected-host",
            response: CodexDesktopMCPClientResponse(
                id: .string("not-pending"),
                result: answerResult,
                error: nil
            )
        )
    )
    #expect(
        broker.receive(
            hostID: "expected-host",
            response: CodexDesktopMCPClientResponse(
                id: request.message.id,
                result: answerResult,
                error: nil
            )
        )
    )
    #expect(try await task.value.answers["choice"]?.answers == ["One"])
    #expect(
        !broker.receive(
            hostID: "expected-host",
            response: CodexDesktopMCPClientResponse(
                id: request.message.id,
                result: answerResult,
                error: nil
            )
        )
    )
}

@Test
@MainActor
func desktopRequestUserInputBrokerReportsMalformedAndRemoteResponses()
    async throws
{
    var sent: [CodexDesktopHostMessage] = []
    let broker = CodexDesktopRequestUserInputBroker(
        send: { sent.append($0) }
    )

    let malformedTask = Task { @MainActor in
        try await broker.request(
            requestUserInputPrompt(itemID: "malformed"),
            timeoutNanoseconds: 10_000_000_000
        )
    }
    let malformedRequest = try await waitForRequestUserInputMessage(
        in: sent,
        at: 0
    )
    #expect(
        broker.receive(
            hostID: "local",
            response: CodexDesktopMCPClientResponse(
                id: malformedRequest.message.id,
                result: .object(["answers": .string("wrong-shape")]),
                error: nil
            )
        )
    )
    do {
        _ = try await malformedTask.value
        Issue.record("Malformed renderer result unexpectedly succeeded")
    } catch {
        #expect(
            error as? CodexDesktopRequestUserInputBrokerError
                == .invalidResponse
        )
    }
    _ = try await waitForResolvedRequestMessage(
        in: sent,
        requestID: malformedRequest.message.id
    )

    let remoteError: CodexJSONValue = .object([
        "code": .integer(-32_000),
        "message": .string("renderer rejected request"),
    ])
    let remoteTask = Task { @MainActor in
        try await broker.request(
            requestUserInputPrompt(itemID: "remote-error"),
            timeoutNanoseconds: 10_000_000_000
        )
    }
    let remoteRequest = try await waitForRequestUserInputMessage(
        in: sent,
        at: 1
    )
    #expect(
        broker.receive(
            hostID: "local",
            response: CodexDesktopMCPClientResponse(
                id: remoteRequest.message.id,
                result: nil,
                error: remoteError
            )
        )
    )
    do {
        _ = try await remoteTask.value
        Issue.record("Remote renderer error unexpectedly succeeded")
    } catch {
        #expect(
            error as? CodexDesktopRequestUserInputBrokerError
                == .remoteError(remoteError)
        )
    }
    _ = try await waitForResolvedRequestMessage(
        in: sent,
        requestID: remoteRequest.message.id
    )
}

@Test
@MainActor
func desktopRequestUserInputBrokerTimesOutWithEmptyDefaultAnswers()
    async throws
{
    var sent: [CodexDesktopHostMessage] = []
    let broker = CodexDesktopRequestUserInputBroker(
        send: { sent.append($0) }
    )
    let result = try await broker.request(
        requestUserInputPrompt(),
        timeoutNanoseconds: 1_000_000
    )
    let request = try await waitForRequestUserInputMessage(in: sent)

    #expect(result == CodexRequestUserInputAnswers(answers: [:]))
    _ = try await waitForResolvedRequestMessage(
        in: sent,
        requestID: request.message.id
    )
    #expect(
        !broker.receive(
            hostID: "local",
            response: CodexDesktopMCPClientResponse(
                id: request.message.id,
                result: .object(["answers": .object([:])]),
                error: nil
            )
        )
    )
}

@Test
@MainActor
func desktopRequestUserInputBrokerCancelAllResumesEveryPendingRequestOnce()
    async throws
{
    var sent: [CodexDesktopHostMessage] = []
    let broker = CodexDesktopRequestUserInputBroker(
        send: { sent.append($0) }
    )
    let first = Task { @MainActor in
        try await broker.request(
            requestUserInputPrompt(itemID: "first"),
            timeoutNanoseconds: 10_000_000_000
        )
    }
    let second = Task { @MainActor in
        try await broker.request(
            requestUserInputPrompt(itemID: "second"),
            timeoutNanoseconds: 10_000_000_000
        )
    }
    let firstRequest = try await waitForRequestUserInputMessage(in: sent)
    let secondRequest = try await waitForRequestUserInputMessage(
        in: sent,
        at: 1
    )

    broker.cancelAll()

    for task in [first, second] {
        do {
            _ = try await task.value
            Issue.record("Cancelled request unexpectedly succeeded")
        } catch {
            #expect(
                error as? CodexDesktopRequestUserInputBrokerError
                    == .cancelled
            )
        }
    }
    for request in [firstRequest, secondRequest] {
        _ = try await waitForResolvedRequestMessage(
            in: sent,
            requestID: request.message.id
        )
        #expect(
            !broker.receive(
                hostID: "local",
                response: CodexDesktopMCPClientResponse(
                    id: request.message.id,
                    result: .object(["answers": .object([:])]),
                    error: nil
                )
            )
        )
    }
}

private struct RequestUserInputMessage {
    let hostID: String
    let message: CodexDesktopMCPRequestMessage
    let metadata: [String: CodexJSONValue]
}

private struct ResolvedRequestMessage {
    let hostID: String
    let method: String
    let params: CodexJSONValue
    let metadata: [String: CodexJSONValue]
}

@MainActor
private func waitForRequestUserInputMessage(
    in messages: @autoclosure () -> [CodexDesktopHostMessage],
    at index: Int = 0
) async throws -> RequestUserInputMessage {
    for _ in 0..<1_000 {
        let requests: [RequestUserInputMessage] = messages().compactMap {
            message -> RequestUserInputMessage? in
            guard case let .mcpRequest(hostID, request, metadata) = message
            else {
                return nil
            }
            return RequestUserInputMessage(
                hostID: hostID,
                message: request,
                metadata: metadata
            )
        }
        if requests.indices.contains(index)
        {
            return requests[index]
        }
        await Task.yield()
    }
    throw RequestUserInputTestError.messageNotSent
}

@MainActor
private func waitForResolvedRequestMessage(
    in messages: @autoclosure () -> [CodexDesktopHostMessage],
    requestID: CodexAppServerRequestID
) async throws -> ResolvedRequestMessage {
    let encodedRequestID: CodexJSONValue
    switch requestID {
    case let .string(value):
        encodedRequestID = .string(value)
    case let .integer(value):
        encodedRequestID = .integer(value)
    }

    for _ in 0..<1_000 {
        for message in messages() {
            guard case let .mcpNotification(
                hostID,
                method,
                params,
                metadata
            ) = message,
            method == "serverRequest/resolved",
            case let .object(object) = params,
            object["requestId"] == encodedRequestID
            else {
                continue
            }
            return ResolvedRequestMessage(
                hostID: hostID,
                method: method,
                params: params,
                metadata: metadata
            )
        }
        await Task.yield()
    }
    throw RequestUserInputTestError.messageNotSent
}

private func requestUserInputPrompt(
    itemID: String = "item"
) -> CodexRequestUserInputPrompt {
    CodexRequestUserInputPrompt(
        threadID: "thread",
        turnID: "turn",
        itemID: itemID,
        questions: [
            CodexRequestUserInputQuestion(
                id: "choice",
                header: "Choice",
                question: "Choose one",
                options: [
                    CodexRequestUserInputOption(
                        label: "One",
                        description: "The first option."
                    )
                ]
            )
        ],
        autoResolutionMS: nil
    )
}

private enum RequestUserInputTestError: Error {
    case messageNotSent
}
