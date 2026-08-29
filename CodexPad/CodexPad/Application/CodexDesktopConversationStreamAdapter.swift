#if SWIFT_PACKAGE
import CodexPadDomain
import CodexPadProtocolBridge
#endif
import Foundation

public struct CodexDesktopParsedConversationRequest:
    Equatable,
    Sendable
{
    public let conversationID: String?
    public let text: String
    public let input: [CodexStoredUserInput]
    public let model: String
    public let reasoningEffort: String
    public let parentMessageID: String?

    public init(
        conversationID: String?,
        text: String,
        input: [CodexStoredUserInput],
        model: String,
        reasoningEffort: String,
        parentMessageID: String? = nil
    ) {
        self.conversationID = conversationID
        self.text = text
        self.input = input
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.parentMessageID = parentMessageID
    }
}

public enum CodexDesktopConversationStreamAdapter {
    public static func officialProviderModel(
        for rendererModel: String,
        baseURL: String? = nil
    ) -> String {
        // ChatGPT OAuth requests use the product Codex route (the factory
        // represents it with a nil base URL). That route currently rejects
        // the renderer's gpt-5.6 aliases, while API-key and custom routes
        // retain their provider-specific model names.
        guard baseURL == nil else {
            return rendererModel == "gpt-5-6"
                ? "gpt-5.6-sol"
                : rendererModel
        }
        switch rendererModel {
        case "auto", "gpt-5-6", "gpt-5.6-sol":
            return "gpt-5.5"
        default:
            return rendererModel
        }
    }

    public static func isConversationRequest(
        _ request: CodexDesktopFetchStreamRequest
    ) -> Bool {
        guard request.method.uppercased() == "POST" else {
            return false
        }
        let path = URL(string: request.url)?.path
            ?? request.url.split(separator: "?").first.map(String.init)
            ?? request.url
        return path.hasSuffix("/f/conversation")
            || path.hasSuffix("/conversation")
    }

    /// The native official-provider bridge can faithfully encode text and
    /// image asset pointers. Other ChatGPT file attachments live only in the
    /// released conversation message metadata, so those requests must retain
    /// their original body and use the authenticated product conversation
    /// endpoint instead of silently dropping the files.
    public static func shouldUseOfficialProvider(
        _ request: CodexDesktopFetchStreamRequest
    ) -> Bool {
        // `/f/conversation` is the released ChatGPT product contract. Keep
        // its model aliases, attachment metadata, account capability checks,
        // and SSE envelopes intact instead of translating it into the native
        // Responses bridge. The latter can turn a renderer alias such as
        // `gpt-5-6` into an account-incompatible Codex API request.
        false
    }

    public static func shouldUseOfficialProvider(
        _ request: CodexDesktopFetchStreamRequest,
        authMethod: CodexDesktopMCPAuthMethod?
    ) -> Bool {
        guard isConversationRequest(request) else {
            return false
        }
        // The released `/f/conversation` endpoint accepts ChatGPT account
        // credentials, but an OpenAI API key must use the native Responses
        // provider. Sending an API key through the product endpoint can end in
        // an empty `message_stream_complete`, leaving the renderer stuck after
        // it already accepted the turn.
        guard authMethod == .apiKey || authMethod == .chatGPT else {
            return false
        }
        // The native provider can faithfully encode ordinary text turns. Keep
        // file and image attachment requests on the released product endpoint,
        // where their asset metadata and upload session are preserved.
        return !containsAttachmentMetadata(request.body)
    }

    private static func containsAttachmentMetadata(_ body: String?) -> Bool {
        guard let body,
              let data = body.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data)
        else {
            return false
        }
        return containsAttachmentMetadata(in: object)
    }

    private static func containsAttachmentMetadata(in value: Any) -> Bool {
        if let object = value as? [String: Any] {
            if object["attachments"] != nil
                || object["asset_pointer"] != nil
                || object["file_service"] != nil
                || object["image_asset_pointer"] != nil
            {
                return true
            }
            return object.values.contains {
                containsAttachmentMetadata(in: $0)
            }
        }
        if let array = value as? [Any] {
            return array.contains {
                containsAttachmentMetadata(in: $0)
            }
        }
        return false
    }

    public static func parse(
        body: String?,
        fallbackModel: String
    ) -> CodexDesktopParsedConversationRequest {
        guard let body,
              let data = body.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(
                with: data
              ) as? [String: Any]
        else {
            return .init(
                conversationID: nil,
                text: body ?? "",
                input: [
                    .text(text: body ?? "", textElements: [])
                ],
                model: fallbackModel,
                reasoningEffort: "medium",
                parentMessageID: nil
            )
        }
        let conversationID =
            (object["conversation_id"] as? String)
            ?? (object["conversationId"] as? String)
            ?? nestedConversationID(in: object)
        let text = (object["partial_query"] as? [String: Any])
            .flatMap(userText(in:))
            ?? latestUserText(in: object)
            ?? (object["prompt"] as? String)
            ?? (object["input"] as? String)
            ?? ""
        let model = (object["model"] as? String) ?? fallbackModel
        let effort =
            (object["reasoning_effort"] as? String)
            ?? (object["reasoningEffort"] as? String)
            ?? (object["thinking_effort"] as? String)
            ?? "medium"
        let input = latestUserInput(in: object)
            ?? [.text(text: text, textElements: [])]
        let parentMessageID = latestUserMessageID(in: object)
        return .init(
            conversationID: conversationID,
            text: text,
            input: input,
            model: model,
            reasoningEffort: effort,
            parentMessageID: parentMessageID
        )
    }

    public static func messageData(
        conversationID: String,
        messageID: String,
        text: String,
        completed: Bool,
        parentMessageID: String? = nil
    ) -> String {
        sseJSON(messageValue(
            conversationID: conversationID,
            messageID: messageID,
            text: text,
            completed: completed,
            parentMessageID: parentMessageID
        ))
    }

    public static func messageValue(
        conversationID: String,
        messageID: String,
        text: String,
        completed: Bool,
        parentMessageID: String? = nil
    ) -> CodexJSONValue {
        let message: CodexJSONValue = .object([
                    "id": .string(messageID),
                    "author": .object(["role": .string("assistant")]),
                    "channel": .string("final"),
                    "metadata": .object(
                        parentMessageID.map {
                            ["parent_id": .string($0)]
                        } ?? [:]
                    ),
                    "content": .object([
                        "content_type": .string("text"),
                        "parts": .array([.string(text)]),
                    ]),
                    "status": .string(
                        completed
                            ? "finished_successfully"
                            : "in_progress"
                    ),
                    "end_turn": .bool(completed),
                    "recipient": .string("all"),
                    "weight": .number(1.0),
                    "create_time": .number(Date().timeIntervalSince1970),
                ])
        // The released desktop has used both SSE envelopes over time:
        // `{type:"message", message:...}` and `{type:"message", data:...}`.
        // Keep both fields so the recovered renderer's decoders converge on
        // the same native message while preserving the canonical `message`
        // shape consumed by OKr.
        var envelope: [String: CodexJSONValue] = [
            "type": .string("message"),
            "message": message,
            "data": message,
        ]
        if !conversationID.isEmpty {
            envelope["conversation_id"] = .string(conversationID)
        }
        return .object(envelope)
    }

    /// Decoded payload delivered with a `fetch-stream-event`.  The desktop
    /// event bus keeps the SSE event name outside the payload, so its
    /// non-delta decoder expects the canonical `{conversation_id, message}`
    /// object rather than the wire envelope used by `messageData`.
    public static func messagePayloadValue(
        conversationID: String,
        messageID: String,
        text: String,
        completed: Bool,
        parentMessageID: String? = nil
    ) -> CodexJSONValue {
        let message = messageValue(
            conversationID: "",
            messageID: messageID,
            text: text,
            completed: completed,
            parentMessageID: parentMessageID
        )
        guard case let .object(fields) = message,
              let canonical = fields["message"]
        else {
            return .object([:])
        }
        var payload: [String: CodexJSONValue] = ["message": canonical]
        if !conversationID.isEmpty {
            payload["conversation_id"] = .string(conversationID)
        }
        return .object(payload)
    }

    public static func completionData(
        conversationID: String
    ) -> String {
        sseJSON(completionValue(conversationID: conversationID))
    }

    /// Builds the renderer event-bus completion envelope. A local-only
    /// conversation has no server identity yet, so the payload must omit
    /// `conversation_id` rather than sending an empty string. The released
    /// renderer treats any non-null value as a migration target.
    public static func completionEvent(
        requestID: String,
        conversationID: String
    ) -> CodexDesktopHostMessage {
        .event(
            type: "fetch-stream-event",
            payload: .object([
                "requestId": .string(requestID),
                "event": .string("message_stream_complete"),
                "data": completionValue(conversationID: conversationID),
            ])
        )
    }

    public static func completionValue(
        conversationID: String
    ) -> CodexJSONValue {
        .object(
            conversationID.isEmpty
                ? ["type": .string("message_stream_complete")]
                : [
                    "conversation_id": .string(conversationID),
                    "type": .string("message_stream_complete"),
                ]
        )
    }

    private static func latestUserText(
        in object: [String: Any]
    ) -> String? {
        if let messages = object["messages"] as? [[String: Any]] {
            for message in messages.reversed() {
                let role =
                    (message["role"] as? String)
                    ?? ((message["author"] as? [String: Any])?["role"]
                        as? String)
                guard role == "user" else { continue }
                if let text = userText(in: message) {
                    return text
                }
            }
        }
        return nil
    }

    private static func userText(
        in message: [String: Any]
    ) -> String? {
        guard let input = userInput(in: message) else {
            return nil
        }
        let text = input.compactMap { item -> String? in
            guard case let .text(value, _) = item else { return nil }
            return value
        }.joined()
        return text.isEmpty ? nil : text
    }

    private static func latestUserInput(
        in object: [String: Any]
    ) -> [CodexStoredUserInput]? {
        if let partialQuery = object["partial_query"] as? [String: Any],
           isUserMessage(partialQuery),
           let input = userInput(in: partialQuery),
           !input.isEmpty
        {
            return input
        }
        guard let messages = object["messages"] as? [[String: Any]] else {
            return nil
        }
        for message in messages.reversed() where isUserMessage(message) {
            if let input = userInput(in: message), !input.isEmpty {
                return input
            }
        }
        return nil
    }

    private static func attachmentObjects(
        in message: [String: Any]
    ) -> [[String: Any]] {
        guard let metadata = message["metadata"] as? [String: Any] else {
            return []
        }
        return metadata["attachments"] as? [[String: Any]] ?? []
    }

    private static func imageAssetPointers(
        in message: [String: Any]
    ) -> [String] {
        guard let content = message["content"] as? [String: Any],
              let parts = content["parts"] as? [Any]
        else {
            return []
        }
        return parts.compactMap { part in
            guard let fields = part as? [String: Any],
                  fields["content_type"] as? String
                    == "image_asset_pointer"
            else {
                return nil
            }
            let nested = fields["image_asset_pointer"]
                as? [String: Any]
            return (fields["asset_pointer"] as? String)
                ?? (nested?["asset_pointer"] as? String)
        }
    }

    private static func isUserMessage(_ message: [String: Any]) -> Bool {
        let role =
            (message["role"] as? String)
            ?? ((message["author"] as? [String: Any])?["role"]
                as? String)
        return role == "user"
    }

    private static func userInput(
        in message: [String: Any]
    ) -> [CodexStoredUserInput]? {
        guard let content = message["content"] as? [String: Any] else {
            if let text = message["text"] as? String {
                return [.text(text: text, textElements: [])]
            }
            return nil
        }
        let rawParts = content["parts"] as? [Any]
            ?? content["text"].map { [$0] }
            ?? []
        let input = rawParts.compactMap { part -> CodexStoredUserInput? in
            if let text = part as? String {
                return .text(text: text, textElements: [])
            }
            guard let fields = part as? [String: Any],
                  fields["content_type"] as? String
                    == "image_asset_pointer"
            else {
                return nil
            }
            let nested = fields["image_asset_pointer"]
                as? [String: Any]
            guard let url =
                (fields["asset_pointer"] as? String)
                ?? (nested?["asset_pointer"] as? String),
                !url.isEmpty
            else {
                return nil
            }
            return .image(detail: nil, url: url)
        }
        return input.isEmpty ? nil : input
    }

    private static func nestedConversationID(
        in value: Any
    ) -> String? {
        if let text = value as? String,
           let data = text.data(using: .utf8),
           let decoded = try? JSONSerialization.jsonObject(with: data)
        {
            return nestedConversationID(in: decoded)
        }
        if let fields = value as? [String: Any] {
            for key in ["conversation_id", "conversationId", "thread_id", "threadId"] {
                if let id = fields[key] as? String, !id.isEmpty {
                    return id
                }
            }
            for child in fields.values {
                if let id = nestedConversationID(in: child) {
                    return id
                }
            }
        } else if let values = value as? [Any] {
            for child in values {
                if let id = nestedConversationID(in: child) {
                    return id
                }
            }
        }
        return nil
    }

    private static func latestUserMessageID(
        in object: [String: Any]
    ) -> String? {
        if let partialQuery = object["partial_query"]
            as? [String: Any],
           let role =
            (partialQuery["author"] as? [String: Any])?["role"]
                as? String,
           role == "user",
           let id = partialQuery["id"] as? String,
           !id.isEmpty
        {
            return id
        }
        guard let messages = object["messages"] as? [[String: Any]] else {
            return nil
        }
        for message in messages.reversed() {
            let role =
                (message["role"] as? String)
                ?? ((message["author"] as? [String: Any])?["role"] as? String)
            if role == "user", let id = message["id"] as? String, !id.isEmpty {
                return id
            }
        }
        return nil
    }

    private static func textContent(in value: Any) -> String? {
        if let string = value as? String, !string.isEmpty {
            return string
        }
        if let dictionary = value as? [String: Any] {
            for key in ["parts", "text", "content", "message", "input"] {
                if let candidate = dictionary[key],
                   let text = textContent(in: candidate),
                   !text.isEmpty
                {
                    return text
                }
            }
            for candidate in dictionary.values {
                if let text = textContent(in: candidate),
                   !text.isEmpty
                {
                    return text
                }
            }
        }
        if let array = value as? [Any] {
            let parts = array.compactMap { textContent(in: $0) }
            return parts.isEmpty ? nil : parts.joined()
        }
        return nil
    }

    private static func sseJSON(_ value: CodexJSONValue) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let json = String(data: data, encoding: .utf8)
        else {
            return "{}"
        }
        return json
    }
}
