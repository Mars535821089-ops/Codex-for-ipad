#if SWIFT_PACKAGE
import CodexPadDomain
import CodexPadProtocolBridge
#endif
import Foundation

/// Runs the released pull-request message generation request through the same
/// authenticated provider boundary used by ordinary desktop turns.
@MainActor
public final class CodexDesktopPullRequestMessageGenerator {
    public typealias Request =
        CodexDesktopPeripheralAppHostService
            .PullRequestGenerationRequest
    public typealias Operation =
        CodexDesktopPeripheralAppHostService
            .PullRequestGenerationOperation
    public typealias Message =
        CodexDesktopPeripheralAppHostService
            .PullRequestGeneratedMessage

    public enum Error: Swift.Error, Equatable, Sendable {
        case providerUnavailable
        case invalidOperation
        case providerRequestMismatch
        case toolCallNotAllowed
        case missingCompletion
        case incompleteResponse
        case invalidStructuredResponse
    }

    private struct ActiveOperation {
        let cancellation: CodexTurnCancellation
        let task: Task<Message?, Swift.Error>
    }

    private let providerFactory:
        CodexDesktopTurnSessionRunner.ProviderFactory
    private var operations: [Operation: ActiveOperation] = [:]

    public init(
        providerFactory:
            @escaping CodexDesktopTurnSessionRunner.ProviderFactory
    ) {
        self.providerFactory = providerFactory
    }

    public func start(
        _ request: Request,
        cwd: String
    ) throws -> Operation {
        let operation = Operation(
            rawValue: "pull-request-\(UUID().uuidString)"
        )
        let cancellation = CodexTurnCancellation()
        let task = Task { @MainActor [providerFactory] in
            try await Self.generate(
                request: request,
                cwd: cwd,
                providerFactory: providerFactory,
                cancellation: cancellation
            )
        }
        operations[operation] = ActiveOperation(
            cancellation: cancellation,
            task: task
        )
        return operation
    }

    public func wait(
        for operation: Operation
    ) async throws -> Message? {
        guard let active = operations[operation] else {
            throw Error.invalidOperation
        }
        return try await active.task.value
    }

    public func cancel(_ operation: Operation) {
        guard let active = operations[operation] else {
            return
        }
        active.cancellation.cancel()
        active.task.cancel()
    }

    public func release(_ operation: Operation) {
        guard let active = operations.removeValue(
            forKey: operation
        ) else {
            return
        }
        if !active.task.isCancelled {
            active.task.cancel()
        }
    }

    private static func generate(
        request: Request,
        cwd: String,
        providerFactory:
            CodexDesktopTurnSessionRunner.ProviderFactory,
        cancellation: CodexTurnCancellation
    ) async throws -> Message? {
        try Task.checkCancellation()
        try cancellation.checkCancellation()

        let requestID =
            "pull-request-message-\(UUID().uuidString)"
        let turnID =
            "pull-request-turn-\(UUID().uuidString)"
        let threadID = CodexStoredThreadID(
            "pull-request-thread-\(UUID().uuidString)"
        )
        let params = CodexTurnStartParams(
            threadID: threadID,
            input: [
                .text(
                    text: request.prompt,
                    textElements: []
                )
            ],
            cwd: .value(cwd),
            effort: .value("low"),
            outputSchema: .value(outputSchema)
        )
        guard let provider = providerFactory(params) else {
            throw Error.providerUnavailable
        }
        let providerRequest = CodexPersistedTurnProviderRequest(
            requestID: requestID,
            roundIndex: 0,
            threadID: threadID,
            turnID: turnID,
            startParams: params,
            frozenPriorInputItems: [],
            currentTurnInputItems: [],
            steeringInput: []
        )
        let stream = await provider.stream(
            providerRequest,
            cancellation: cancellation
        )
        var responseText = ""
        var completed = false
        var terminal = false
        for try await event in stream {
            try Task.checkCancellation()
            try cancellation.checkCancellation()
            switch event {
            case let .assistantTextDelta(
                _,
                eventRequestID,
                delta
            ):
                try requireRequestID(
                    eventRequestID,
                    expected: requestID
                )
                responseText += delta
            case let .responseItemDone(
                _,
                eventRequestID,
                itemJSON
            ):
                try requireRequestID(
                    eventRequestID,
                    expected: requestID
                )
                if responseText.isEmpty {
                    responseText =
                        assistantText(from: itemJSON) ?? ""
                }
            case let .responseCompleted(
                _,
                eventRequestID,
                _,
                _,
                endTurn
            ):
                try requireRequestID(
                    eventRequestID,
                    expected: requestID
                )
                completed = true
                terminal = endTurn != false
            case let .toolCallRequested(
                _,
                eventRequestID,
                _,
                _,
                _,
                _
            ):
                try requireRequestID(
                    eventRequestID,
                    expected: requestID
                )
                throw Error.toolCallNotAllowed
            case let .responseStarted(_, eventRequestID, _),
                 let .planStarted(_, eventRequestID, _),
                 let .planDelta(_, eventRequestID, _, _),
                 let .planCompleted(_, eventRequestID, _, _),
                 let .realtime(_, eventRequestID, _, _):
                try requireRequestID(
                    eventRequestID,
                    expected: requestID
                )
            }
        }
        try Task.checkCancellation()
        try cancellation.checkCancellation()
        guard completed else {
            throw Error.missingCompletion
        }
        guard terminal else {
            throw Error.incompleteResponse
        }
        guard let data = responseText.data(using: .utf8),
              let value = try? JSONDecoder().decode(
                  CodexJSONValue.self,
                  from: data
              ),
              case let .object(fields) = value,
              case let .string(title)? = fields["title"],
              case let .string(body)? = fields["body"]
        else {
            throw Error.invalidStructuredResponse
        }
        return Message(title: title, body: body)
    }

    private static func requireRequestID(
        _ actual: String,
        expected: String
    ) throws {
        guard actual == expected else {
            throw Error.providerRequestMismatch
        }
    }

    private static func assistantText(
        from itemJSON: String
    ) -> String? {
        guard let data = itemJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(
                  with: data
              ) as? [String: Any],
              object["role"] as? String == "assistant",
              let content = object["content"] as? [[String: Any]]
        else {
            return nil
        }
        return content.compactMap { $0["text"] as? String }
            .joined()
    }

    private static let outputSchema: CodexJSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "title": .object([
                "type": .string("string"),
                "minLength": .integer(8),
                "maxLength": .integer(120),
            ]),
            "body": .object([
                "type": .string("string"),
                "minLength": .integer(12),
                "maxLength": .integer(30_000),
            ]),
        ]),
        "required": .array([
            .string("title"),
            .string("body"),
        ]),
        "additionalProperties": .bool(false),
    ])
}
