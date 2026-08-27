import Foundation

#if SWIFT_PACKAGE
    import CodexPadDomain
    import CodexPadProtocolBridge
#endif

@MainActor
public protocol CodexDesktopConversationHistoryPersisting: AnyObject {
    func startThread(
        id: CodexAppServerRequestID,
        params: CodexThreadStartParams
    ) throws -> CodexThreadResumeResult

    func startDesktopTurn(
        id: CodexAppServerRequestID,
        params: CodexTurnStartParams
    ) throws -> CodexTurnStartResult

    func priorInputItems(
        id: CodexAppServerRequestID,
        params: CodexPriorInputItemsParams
    ) throws -> CodexPriorInputItemsResult

    func commitRawHistory(
        _ command: CodexRawHistoryCommit
    ) throws -> CodexRawHistoryCommittedEvent
}

extension CodexSessionStore: CodexDesktopConversationHistoryPersisting {}

public struct CodexDesktopPersistedConversationContext:
    Equatable,
    Sendable
{
    public let threadID: CodexStoredThreadID
    public let turnID: String
    public let priorInputItems: [String]

    public init(
        threadID: CodexStoredThreadID,
        turnID: String,
        priorInputItems: [String]
    ) {
        self.threadID = threadID
        self.turnID = turnID
        self.priorInputItems = priorInputItems
    }
}

/// Persists the released renderer's `/f/conversation` compatibility stream
/// through the same durable app-server thread and raw-history contracts used
/// by native `thread/start` and `turn/start` calls.
@MainActor
public final class CodexDesktopConversationPersistenceBridge {
    private let store: any CodexDesktopConversationHistoryPersisting
    private let lastActiveLocalThreadStore:
        CodexDesktopLastActiveLocalThreadStore

    public init(
        store: any CodexDesktopConversationHistoryPersisting,
        lastActiveLocalThreadStore:
            CodexDesktopLastActiveLocalThreadStore =
                CodexDesktopLastActiveLocalThreadStore()
    ) {
        self.store = store
        self.lastActiveLocalThreadStore = lastActiveLocalThreadStore
    }

    public func begin(
        requestID: String,
        conversationID: String?,
        input: [CodexStoredUserInput],
        model: String,
        reasoningEffort: String,
        cwd: String?
    ) throws -> CodexDesktopPersistedConversationContext {
        let existingID = conversationID?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let threadID: CodexStoredThreadID
        if let existingID,
           !existingID.isEmpty,
           !Self.isLegacyConversationAnchor(existingID)
        {
            threadID = CodexStoredThreadID(existingID)
        } else {
            let started = try store.startThread(
                id: .string("\(requestID)-thread"),
                params: CodexThreadStartParams(
                    model: .value(model),
                    modelProvider: .value("openai"),
                    cwd: cwd.map(CodexWireOptional.value) ?? .omitted,
                    ephemeral: .value(false),
                    // The core supplies its stable startup default when this
                    // optional compatibility field is omitted.
                    sessionStartSource: .omitted,
                    threadSource: .value("app")
                )
            )
            threadID = started.thread.id
        }

        let turn = try store.startDesktopTurn(
            id: .string("\(requestID)-turn"),
            params: CodexTurnStartParams(
                threadID: threadID,
                input: input,
                model: .value(model),
                effort: .value(reasoningEffort)
            )
        )
        let prior = try store.priorInputItems(
            id: .string("\(requestID)-prior-input"),
            params: CodexPriorInputItemsParams(
                threadID: threadID,
                beforeTurnID: .value(turn.turn.id)
            )
        )
        guard prior.threadID == threadID else {
            throw CodexDesktopConversationPersistenceError
                .priorThreadIDMismatch
        }
        lastActiveLocalThreadStore.recordRendererPath(
            "/local/" + threadID.rawValue
        )
        return CodexDesktopPersistedConversationContext(
            threadID: threadID,
            turnID: turn.turn.id,
            priorInputItems: prior.items
        )
    }

    private static func isLegacyConversationAnchor(_ value: String) -> Bool {
        UUID(uuidString: value) != nil
            || value.caseInsensitiveCompare("uuid") == .orderedSame
    }

    public func commit(
        _ context: CodexDesktopPersistedConversationContext,
        responseItems: [String],
        responseID: String,
        usage: CodexTokenUsageBreakdown?,
        endTurn: Bool,
        fallbackAssistantText: String
    ) throws {
        let items: [String]
        if responseItems.isEmpty, !fallbackAssistantText.isEmpty {
            items = [try Self.assistantItemJSON(fallbackAssistantText)]
        } else {
            items = responseItems
        }
        let entries = items.enumerated().map { index, itemJSON in
            CodexRawHistoryEntry(
                order: UInt64(index),
                source: .provider,
                itemJSON: itemJSON
            )
        }
        _ = try store.commitRawHistory(
            CodexRawHistoryCommit(
                threadID: context.threadID,
                turnID: context.turnID,
                expectedNextOrder: 0,
                entries: entries,
                completion: .value(
                    CodexRawHistoryCompletion(
                        responseID: responseID,
                        usage: usage.map(CodexWireOptional.value)
                            ?? .omitted,
                        endTurn: .value(endTurn)
                    )
                )
            )
        )
        lastActiveLocalThreadStore.recordDurableThreadID(
            context.threadID.rawValue
        )
    }

    private static func assistantItemJSON(_ text: String) throws -> String {
        let value = CodexJSONValue.object([
            "type": .string("message"),
            "role": .string("assistant"),
            "content": .array([
                .object([
                    "type": .string("output_text"),
                    "text": .string(text),
                ]),
            ]),
        ])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }
}

public enum CodexDesktopConversationPersistenceError:
    Error,
    Equatable,
    Sendable
{
    case priorThreadIDMismatch
}
