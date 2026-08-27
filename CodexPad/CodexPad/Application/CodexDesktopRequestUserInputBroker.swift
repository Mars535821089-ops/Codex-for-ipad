#if SWIFT_PACKAGE
import CodexPadDomain
import CodexPadProtocolBridge
#endif
import Foundation

public enum CodexDesktopRequestUserInputBrokerError:
    Swift.Error,
    Equatable,
    Sendable
{
    case cancelled
    case invalidResponse
    case remoteError(CodexJSONValue)
}

/// Routes app-server `request_user_input` prompts through the released
/// renderer and resumes only the matching suspended request.
@MainActor
public final class CodexDesktopRequestUserInputBroker {
    public typealias Send = (CodexDesktopHostMessage) async -> Void

    private typealias Continuation = CheckedContinuation<
        CodexRequestUserInputAnswers,
        Swift.Error
    >

    private struct PendingRequest {
        let threadID: String
        let continuation: Continuation
        var timeoutTask: Task<Void, Never>?
    }

    private let hostID: String
    private let send: Send
    private var sequence: Int64 = 0
    private var pending: [CodexAppServerRequestID: PendingRequest] = [:]

    public init(
        hostID: String = "local",
        send: @escaping Send
    ) {
        self.hostID = hostID
        self.send = send
    }

    public func request(
        _ prompt: CodexRequestUserInputPrompt,
        timeoutNanoseconds: UInt64 = 300_000_000_000
    ) async throws -> CodexRequestUserInputAnswers {
        sequence &+= 1
        let id = CodexAppServerRequestID.string(
            "request-user-input-\(sequence)"
        )
        let message = CodexDesktopHostMessage.mcpRequest(
            hostID: hostID,
            request: CodexDesktopMCPRequestMessage(
                id: id,
                method: "item/tool/requestUserInput",
                params: Self.encode(prompt),
                metadata: [:]
            ),
            metadata: [:]
        )
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending[id] = PendingRequest(
                    threadID: prompt.threadID,
                    continuation: continuation,
                    timeoutTask: nil
                )
                if Task.isCancelled {
                    resolve(
                        id: id,
                        result: .failure(
                            CodexDesktopRequestUserInputBrokerError.cancelled
                        )
                    )
                    return
                }
                Task { @MainActor [weak self] in
                    guard let self else {
                        return
                    }
                    await self.send(message)
                }
                let timeoutTask = Task { @MainActor [weak self] in
                    do {
                        try await Task.sleep(
                            nanoseconds: timeoutNanoseconds
                        )
                    } catch {
                        return
                    }
                    self?.resolve(
                        id: id,
                        result: .success(
                            CodexRequestUserInputAnswers(answers: [:])
                        )
                    )
                }
                pending[id]?.timeoutTask = timeoutTask
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.resolve(
                    id: id,
                    result: .failure(
                        CodexDesktopRequestUserInputBrokerError.cancelled
                    )
                )
            }
        }
    }

    /// Returns `true` only when this broker owned and consumed the response.
    @discardableResult
    public func receive(
        hostID: String,
        response: CodexDesktopMCPClientResponse
    ) -> Bool {
        guard hostID == self.hostID, pending[response.id] != nil else {
            return false
        }

        if let error = response.error {
            resolve(
                id: response.id,
                result: .failure(
                    CodexDesktopRequestUserInputBrokerError.remoteError(
                        error
                    )
                )
            )
            return true
        }

        guard let answers = Self.decode(response.result) else {
            resolve(
                id: response.id,
                result: .failure(
                    CodexDesktopRequestUserInputBrokerError.invalidResponse
                )
            )
            return true
        }

        resolve(id: response.id, result: .success(answers))
        return true
    }

    public func cancelAll() {
        let requests = pending
        pending.removeAll()
        for (id, request) in requests {
            finish(
                id: id,
                request: request,
                result: .failure(
                    CodexDesktopRequestUserInputBrokerError.cancelled
                )
            )
        }
    }

    private func resolve(
        id: CodexAppServerRequestID,
        result: Result<CodexRequestUserInputAnswers, Swift.Error>
    ) {
        guard let request = pending.removeValue(forKey: id) else {
            return
        }
        finish(id: id, request: request, result: result)
    }

    private func finish(
        id: CodexAppServerRequestID,
        request: PendingRequest,
        result: Result<CodexRequestUserInputAnswers, Swift.Error>
    ) {
        request.timeoutTask?.cancel()
        let notification = CodexDesktopHostMessage.mcpNotification(
            hostID: hostID,
            method: "serverRequest/resolved",
            params: .object([
                "threadId": .string(request.threadID),
                "requestId": Self.encode(id),
            ]),
            metadata: [:]
        )
        Task { @MainActor [send] in
            await send(notification)
            request.continuation.resume(with: result)
        }
    }

    private static func encode(
        _ id: CodexAppServerRequestID
    ) -> CodexJSONValue {
        switch id {
        case let .string(value):
            return .string(value)
        case let .integer(value):
            return .integer(value)
        }
    }

    private static func encode(
        _ prompt: CodexRequestUserInputPrompt
    ) -> CodexJSONValue {
        let questions: [CodexJSONValue] = prompt.questions.map { question in
            .object([
                "id": .string(question.id),
                "header": .string(question.header),
                "question": .string(question.question),
                "options": .array(
                    question.options.map { option in
                        .object([
                            "label": .string(option.label),
                            "description": .string(option.description),
                        ])
                    }
                ),
            ])
        }
        let autoResolution: CodexJSONValue
        if let autoResolutionMS = prompt.autoResolutionMS {
            autoResolution = .integer(Int64(autoResolutionMS))
        } else {
            autoResolution = .null
        }
        return .object([
            "threadId": .string(prompt.threadID),
            "turnId": .string(prompt.turnID),
            "itemId": .string(prompt.itemID),
            "questions": .array(questions),
            "autoResolutionMs": autoResolution,
        ])
    }

    private static func decode(
        _ result: CodexJSONValue?
    ) -> CodexRequestUserInputAnswers? {
        guard case let .object(resultObject)? = result,
              case let .object(answerObject)? = resultObject["answers"]
        else {
            return nil
        }

        var answers: [String: CodexRequestUserInputAnswer] = [:]
        answers.reserveCapacity(answerObject.count)
        for (questionID, value) in answerObject {
            guard case let .object(answer) = value,
                  case let .array(values)? = answer["answers"]
            else {
                return nil
            }
            var strings: [String] = []
            strings.reserveCapacity(values.count)
            for value in values {
                guard case let .string(string) = value else {
                    return nil
                }
                strings.append(string)
            }
            answers[questionID] = CodexRequestUserInputAnswer(
                answers: strings
            )
        }
        return CodexRequestUserInputAnswers(answers: answers)
    }
}

public enum CodexDesktopDynamicToolCallBrokerError:
    Swift.Error,
    Equatable,
    Sendable
{
    case cancelled
    case invalidArguments
    case invalidRequestIdentity
    case duplicateCallID
    case unregisteredTool
}

/// Sends thread-scoped dynamic tools to the released renderer using the
/// app-server `item/tool/call` contract and converts the response back into a
/// Responses API function-call output for the same persisted turn.
@MainActor
public final class CodexDesktopDynamicToolCallBroker:
    CodexPersistedTurnDynamicToolExecutor
{
    public typealias Send = (CodexDesktopHostMessage) async -> Void

    private struct ToolIdentity: Hashable {
        let namespace: String?
        let tool: String
    }

    private struct RequestIdentity {
        let namespace: String?
        let tool: String
        let callID: String
    }

    private typealias Continuation = CheckedContinuation<
        CodexPersistedTurnLocalToolOutput,
        Swift.Error
    >

    private struct PendingRequest {
        let callID: String
        let continuation: Continuation
        var timeoutTask: Task<Void, Never>?
    }

    private let hostID: String
    private let registeredTools: Set<ToolIdentity>
    private let timeoutNanoseconds: UInt64
    private let send: Send
    private var sequence: Int64 = 0
    private var pending: [CodexAppServerRequestID: PendingRequest] = [:]
    private var pendingCallIDs: Set<String> = []

    public init(
        hostID: String = "local",
        dynamicTools: [CodexJSONValue],
        timeoutNanoseconds: UInt64 = 300_000_000_000,
        send: @escaping Send
    ) {
        self.hostID = hostID
        registeredTools = Self.registeredToolIdentities(dynamicTools)
        self.timeoutNanoseconds = timeoutNanoseconds
        self.send = send
    }

    public func canExecute(toolName: String) -> Bool {
        registeredTools.contains(
            ToolIdentity(namespace: nil, tool: toolName)
        )
    }

    public func canExecute(toolName: String, itemJSON: String) -> Bool {
        guard let identity = Self.requestIdentity(
            itemJSON: itemJSON,
            fallbackToolName: toolName
        ) else {
            return false
        }
        return identity.tool == toolName
            && registeredTools.contains(
                ToolIdentity(
                    namespace: identity.namespace,
                    tool: identity.tool
                )
            )
    }

    public func execute(
        _ request: CodexPersistedTurnToolRequest,
        cancellation: CodexTurnCancellation
    ) async throws -> CodexPersistedTurnLocalToolOutput {
        try Task.checkCancellation()
        try cancellation.checkCancellation()
        guard let identity = Self.requestIdentity(
            itemJSON: request.itemJSON,
            fallbackToolName: request.name
        ), identity.tool == request.name,
        identity.callID == request.callID
        else {
            throw CodexDesktopDynamicToolCallBrokerError
                .invalidRequestIdentity
        }
        guard registeredTools.contains(
            ToolIdentity(
                namespace: identity.namespace,
                tool: identity.tool
            )
        ) else {
            throw CodexDesktopDynamicToolCallBrokerError.unregisteredTool
        }
        guard !pendingCallIDs.contains(request.callID) else {
            throw CodexDesktopDynamicToolCallBrokerError.duplicateCallID
        }
        guard let arguments = Self.decodeJSON(request.arguments) else {
            throw CodexDesktopDynamicToolCallBrokerError.invalidArguments
        }

        sequence &+= 1
        let id = CodexAppServerRequestID.string(
            "dynamic-tool-call-\(sequence)"
        )
        let namespace: CodexJSONValue = identity.namespace
            .map(CodexJSONValue.string) ?? .null
        let message = CodexDesktopHostMessage.mcpRequest(
            hostID: hostID,
            request: CodexDesktopMCPRequestMessage(
                id: id,
                method: "item/tool/call",
                params: .object([
                    "threadId": .string(request.threadID.rawValue),
                    "turnId": .string(request.turnID),
                    "callId": .string(request.callID),
                    "namespace": namespace,
                    "tool": .string(identity.tool),
                    "arguments": arguments,
                ]),
                metadata: [:]
            ),
            metadata: [:]
        )
        let timeoutNanoseconds = self.timeoutNanoseconds

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pendingCallIDs.insert(request.callID)
                pending[id] = PendingRequest(
                    callID: request.callID,
                    continuation: continuation,
                    timeoutTask: nil
                )
                if Task.isCancelled {
                    resolve(
                        id: id,
                        result: .failure(
                            CodexDesktopDynamicToolCallBrokerError.cancelled
                        )
                    )
                    return
                }
                Task { @MainActor [weak self] in
                    guard let self else {
                        return
                    }
                    await self.send(message)
                }
                let timeoutTask = Task { @MainActor [weak self] in
                    do {
                        try await Task.sleep(
                            nanoseconds: timeoutNanoseconds
                        )
                    } catch {
                        return
                    }
                    self?.resolve(
                        id: id,
                        result: .success(
                            Self.fallbackOutput(
                                callID: request.callID,
                                message: "dynamic tool request failed"
                            )
                        )
                    )
                }
                pending[id]?.timeoutTask = timeoutTask
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.resolve(
                    id: id,
                    result: .failure(
                        CodexDesktopDynamicToolCallBrokerError.cancelled
                    )
                )
            }
        }
    }

    /// Returns `true` only when this broker owned and consumed the response.
    @discardableResult
    public func receive(
        hostID: String,
        response: CodexDesktopMCPClientResponse
    ) -> Bool {
        guard hostID == self.hostID,
              let request = pending[response.id]
        else {
            return false
        }

        let output: CodexPersistedTurnLocalToolOutput
        if response.error != nil {
            output = Self.fallbackOutput(
                callID: request.callID,
                message: "dynamic tool request failed"
            )
        } else if let decoded = Self.decodeResponse(
            response.result,
            callID: request.callID
        ) {
            output = decoded
        } else {
            output = Self.fallbackOutput(
                callID: request.callID,
                message: "dynamic tool response was invalid"
            )
        }
        resolve(id: response.id, result: .success(output))
        return true
    }

    public func cancelAll() {
        let requests = Array(pending.values)
        pending.removeAll()
        pendingCallIDs.removeAll()
        for request in requests {
            request.timeoutTask?.cancel()
            request.continuation.resume(
                throwing: CodexDesktopDynamicToolCallBrokerError.cancelled
            )
        }
    }

    private func resolve(
        id: CodexAppServerRequestID,
        result: Result<CodexPersistedTurnLocalToolOutput, Swift.Error>
    ) {
        guard let request = pending.removeValue(forKey: id) else {
            return
        }
        pendingCallIDs.remove(request.callID)
        request.timeoutTask?.cancel()
        request.continuation.resume(with: result)
    }

    private static func registeredToolIdentities(
        _ values: [CodexJSONValue]
    ) -> Set<ToolIdentity> {
        var result: Set<ToolIdentity> = []
        for value in values {
            guard case let .object(object) = value else {
                continue
            }
            if case .string("namespace")? = object["type"],
               case let .string(namespace)? = object["name"],
               case let .array(tools)? = object["tools"]
            {
                for tool in tools {
                    guard case let .object(toolObject) = tool,
                          case .string("function")? = toolObject["type"],
                          case let .string(name)? = toolObject["name"]
                    else {
                        continue
                    }
                    result.insert(
                        ToolIdentity(namespace: namespace, tool: name)
                    )
                }
                continue
            }

            guard case let .string(name)? = object["name"] else {
                continue
            }
            let namespace: String?
            if case let .string(value)? = object["namespace"] {
                namespace = value
            } else {
                namespace = nil
            }
            if object["type"] == nil
                || object["type"] == .string("function")
            {
                result.insert(
                    ToolIdentity(namespace: namespace, tool: name)
                )
            }
        }
        return result
    }

    private static func requestIdentity(
        itemJSON: String,
        fallbackToolName: String
    ) -> RequestIdentity? {
        guard let data = itemJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any],
              let type = object["type"] as? String,
              type == "function_call" || type == "custom_tool_call",
              let callID = object["call_id"] as? String
        else {
            return nil
        }
        let tool = object["name"] as? String ?? fallbackToolName
        return RequestIdentity(
            namespace: object["namespace"] as? String,
            tool: tool,
            callID: callID
        )
    }

    private static func decodeJSON(_ raw: String) -> CodexJSONValue? {
        guard let data = raw.data(using: .utf8) else {
            return nil
        }
        return try? JSONDecoder().decode(CodexJSONValue.self, from: data)
    }

    private static func decodeResponse(
        _ result: CodexJSONValue?,
        callID: String
    ) -> CodexPersistedTurnLocalToolOutput? {
        guard case let .object(object)? = result,
              case let .array(items)? = object["contentItems"],
              case .bool? = object["success"]
        else {
            return nil
        }

        var outputItems: [CodexJSONValue] = []
        outputItems.reserveCapacity(items.count)
        for item in items {
            guard case let .object(value) = item,
                  case let .string(type)? = value["type"]
            else {
                return nil
            }
            switch type {
            case "inputText":
                guard case let .string(text)? = value["text"] else {
                    return nil
                }
                outputItems.append(
                    .object([
                        "type": .string("input_text"),
                        "text": .string(text),
                    ])
                )
            case "inputImage":
                guard case let .string(imageURL)? = value["imageUrl"],
                      !isRemoteURL(imageURL)
                else {
                    return nil
                }
                outputItems.append(
                    .object([
                        "type": .string("input_image"),
                        "image_url": .string(imageURL),
                    ])
                )
            case "inputAudio":
                guard case let .string(audioURL)? = value["audioUrl"],
                      audioURL.lowercased().hasPrefix("data:")
                else {
                    return nil
                }
                outputItems.append(
                    .object([
                        "type": .string("input_audio"),
                        "audio_url": .string(audioURL),
                    ])
                )
            default:
                return nil
            }
        }
        return output(callID: callID, items: outputItems)
    }

    private static func isRemoteURL(_ value: String) -> Bool {
        let lowercased = value.lowercased()
        return lowercased.hasPrefix("http://")
            || lowercased.hasPrefix("https://")
    }

    private static func fallbackOutput(
        callID: String,
        message: String
    ) -> CodexPersistedTurnLocalToolOutput {
        output(
            callID: callID,
            items: [
                .object([
                    "type": .string("input_text"),
                    "text": .string(message),
                ])
            ]
        )
    }

    private static func output(
        callID: String,
        items: [CodexJSONValue]
    ) -> CodexPersistedTurnLocalToolOutput {
        let value = CodexJSONValue.object([
            "type": .string("function_call_output"),
            "call_id": .string(callID),
            "output": .array(items),
        ])
        let data = (try? JSONEncoder().encode(value)) ?? Data()
        return CodexPersistedTurnLocalToolOutput(
            itemJSON: String(decoding: data, as: UTF8.self)
        )
    }
}
