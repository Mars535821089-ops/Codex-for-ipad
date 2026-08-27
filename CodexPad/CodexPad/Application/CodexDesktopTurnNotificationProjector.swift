#if SWIFT_PACKAGE
import CodexPadDomain
import CodexPadProtocolBridge
#endif
import Foundation

/// Projects the native persisted-provider stream onto the exact app-server
/// notification vocabulary consumed by the released desktop renderer.
public struct CodexDesktopTurnNotificationProjector: Sendable {
    public let threadID: CodexStoredThreadID
    public let turnID: String
    public let itemID: String
    public let startedAtMs: Int64

    public private(set) var currentText = ""
    private var agentItemStarted = false
    private var startedItemIDs: Set<String> = []
    private var completedNotificationItemIDs: Set<String> = []
    private var itemOrder: [String] = []
    private var completedItemsByID: [String: CodexStoredThreadItem] = [:]
    private var turnCompletionEmitted = false
    private var currentReasoningItemID: String?
    private enum PendingTool: Sendable {
        case mcp(server: String, tool: String, arguments: CodexJSONValue)
        case command(command: String, cwd: String)
        case fileChange(changes: [CodexJSONValue])
        case plan(text: String)
        case dynamic(namespace: String?, tool: String, arguments: CodexJSONValue)
    }

    private var pendingTools: [String: PendingTool] = [:]

    public init(
        threadID: CodexStoredThreadID,
        turnID: String,
        startedAtMs: Int64
    ) {
        self.threadID = threadID
        self.turnID = turnID
        self.itemID = "\(turnID)-agent-message"
        self.startedAtMs = startedAtMs
    }

    public mutating func started(
        turn: CodexStoredTurn
    ) -> [CodexAppServerTurnNotification] {
        return [
            .turnStarted(
                CodexTurnStartedNotification(
                    threadID: threadID,
                    turn: turn
                )
            )
        ]
    }

    public mutating func providerEvent(
        _ event: CodexCoreProviderEvent
    ) -> [CodexAppServerTurnNotification] {
        switch event {
        case .responseStarted:
            return []
        case let .planStarted(_, _, planItemID):
            return ensurePlanStarted(planItemID)
        case let .realtime(_, _, eventType, payload):
            if eventType == "output_item_added" {
                currentReasoningItemID = Self.reasoningItemID(payload)
                return [opaqueRealtime(eventType: eventType, payload: payload)]
            }
            if let notification = reasoningRealtimeNotification(
                eventType: eventType,
                payload: payload
            ) {
                return [notification]
            }
            return [opaqueRealtime(eventType: eventType, payload: payload)]
        case let .planDelta(_, _, planItemID, delta):
            guard !delta.isEmpty else {
                return []
            }
            var notifications = ensurePlanStarted(planItemID)
            notifications.append(
                .planDelta(
                    CodexPlanDeltaNotification(
                        threadID: threadID,
                        turnID: turnID,
                        itemID: planItemID,
                        delta: delta
                    )
                )
            )
            return notifications
        case let .planCompleted(_, _, planItemID, text):
            let item = CodexStoredThreadItem.plan(
                id: planItemID,
                text: text
            )
            var notifications = ensurePlanStarted(planItemID)
            completedItemsByID[planItemID] = item
            if completedNotificationItemIDs.insert(planItemID).inserted {
                notifications.append(
                    .itemCompleted(
                        CodexItemCompletedNotification(
                            item: item,
                            threadID: threadID,
                            turnID: turnID,
                            completedAtMs: Self.now()
                        )
                    )
                )
            }
            return notifications
        case let .assistantTextDelta(_, _, delta):
            guard !delta.isEmpty else {
                return []
            }
            var notifications: [CodexAppServerTurnNotification] = []
            if !agentItemStarted {
                agentItemStarted = true
                if startedItemIDs.insert(itemID).inserted {
                    itemOrder.append(itemID)
                }
                notifications.append(
                    .itemStarted(
                        CodexItemStartedNotification(
                            item: CodexStoredThreadItem.agentMessage(
                                id: itemID,
                                text: "",
                                phase: .finalAnswer,
                                memoryCitation: nil
                            ),
                            threadID: threadID,
                            turnID: turnID,
                            startedAtMs: Self.now()
                        )
                    )
                )
            }
            currentText += delta
            notifications.append(
                .agentMessageDelta(
                    CodexAgentMessageDeltaNotification(
                        threadID: threadID,
                        turnID: turnID,
                        itemID: itemID,
                        delta: delta
                    )
                )
            )
            return notifications
        case let .toolCallRequested(
            _, _, name, arguments, callID, itemJSON
        ):
            var notifications: [CodexAppServerTurnNotification] = []
            let namespace = Self.namespace(itemJSON)
            let argumentsValue = Self.jsonValue(arguments)
            if let namespace, namespace.hasPrefix("mcp__") {
                let server = String(namespace.dropFirst("mcp__".count))
                pendingTools[callID] = .mcp(
                    server: server,
                    tool: name,
                    arguments: argumentsValue
                )
                notifications.append(
                    .itemStarted(
                        CodexItemStartedNotification(
                            item: .mcpToolCall(
                                id: callID,
                                server: server,
                                tool: name,
                                status: .inProgress,
                                arguments: argumentsValue,
                                appContext: nil,
                                mcpAppResourceURI: nil,
                                pluginID: nil,
                                result: nil,
                                error: nil,
                                durationMs: nil
                            ),
                            threadID: threadID,
                            turnID: turnID,
                            startedAtMs: Self.now()
                        )
                    )
                )
            } else if Self.isCommandTool(name) {
                let command = Self.command(argumentsValue, fallback: name)
                let cwd = Self.string("workdir", in: argumentsValue) ?? ""
                pendingTools[callID] = .command(command: command, cwd: cwd)
                notifications.append(
                    .itemStarted(
                        CodexItemStartedNotification(
                            item: .commandExecution(
                                id: callID,
                                command: command,
                                cwd: cwd,
                                processID: nil,
                                source: .agent,
                                status: .inProgress,
                                commandActions: [],
                                aggregatedOutput: nil,
                                exitCode: nil,
                                durationMs: nil
                            ),
                            threadID: threadID,
                            turnID: turnID,
                            startedAtMs: Self.now()
                        )
                    )
                )
            } else if name == "apply_patch" {
                let changes: [CodexJSONValue] = [
                    .object([
                        "type": .string("applyPatch"),
                        "patch": Self.value("patch", in: argumentsValue)
                            ?? argumentsValue,
                    ])
                ]
                pendingTools[callID] = .fileChange(changes: changes)
                notifications.append(
                    .itemStarted(
                        CodexItemStartedNotification(
                            item: .fileChange(
                                id: callID,
                                changes: changes,
                                status: .inProgress
                            ),
                            threadID: threadID,
                            turnID: turnID,
                            startedAtMs: Self.now()
                        )
                    )
                )
            } else if name == "update_plan" {
                let text = Self.outputText(argumentsValue)
                pendingTools[callID] = .plan(text: text)
                notifications.append(
                    .itemStarted(
                        CodexItemStartedNotification(
                            item: .plan(id: callID, text: text),
                            threadID: threadID,
                            turnID: turnID,
                            startedAtMs: Self.now()
                        )
                    )
                )
            } else {
                pendingTools[callID] = .dynamic(
                    namespace: namespace,
                    tool: name,
                    arguments: argumentsValue
                )
                notifications.append(
                    .itemStarted(
                        CodexItemStartedNotification(
                            item: .dynamicToolCall(
                                id: callID,
                                namespace: namespace,
                                tool: name,
                                arguments: argumentsValue,
                                status: .inProgress,
                                contentItems: nil,
                                success: nil,
                                durationMs: nil
                            ),
                            threadID: threadID,
                            turnID: turnID,
                            startedAtMs: Self.now()
                        )
                    )
                )
            }
            notifications.append(
                .rawResponseItemCompleted(
                    CodexRawResponseItemCompletedNotification(
                        threadID: threadID,
                        turnID: turnID,
                        item: Self.rawItem(itemJSON)
                    )
                )
            )
            return notifications
        case let .responseItemDone(_, _, itemJSON):
            var notifications: [CodexAppServerTurnNotification] = []
            if let reasoning = Self.reasoningItem(itemJSON) {
                notifications.append(
                    .itemCompleted(
                        CodexItemCompletedNotification(
                            item: reasoning,
                            threadID: threadID,
                            turnID: turnID,
                            completedAtMs: Self.now()
                        )
                    )
                )
            }
            notifications.append(
                .rawResponseItemCompleted(
                    CodexRawResponseItemCompletedNotification(
                        threadID: threadID,
                        turnID: turnID,
                        item: Self.rawItem(itemJSON)
                    )
                )
            )
            return notifications
        case let .responseCompleted(
            _, _, responseID, usage, endTurn
        ):
            if endTurn != false {
                guard !turnCompletionEmitted else {
                    return []
                }
                turnCompletionEmitted = true
            }
            let item = CodexStoredThreadItem.agentMessage(
                id: itemID,
                text: currentText,
                phase: .finalAnswer,
                memoryCitation: nil
            )
            var notifications: [CodexAppServerTurnNotification] = []
            if endTurn != false, agentItemStarted {
                completedItemsByID[itemID] = item
                if completedNotificationItemIDs.insert(itemID).inserted {
                    notifications.append(
                        .itemCompleted(
                            CodexItemCompletedNotification(
                                item: item,
                                threadID: threadID,
                                turnID: turnID,
                                completedAtMs: Self.now()
                            )
                        )
                    )
                }
            }
            if let usage {
                let tokenUsage = CodexThreadTokenUsage(
                    total: usage,
                    last: usage,
                    modelContextWindow: nil
                )
                notifications.append(
                    .threadTokenUsageUpdated(
                        CodexThreadTokenUsageUpdatedNotification(
                            threadID: threadID,
                            turnID: turnID,
                            tokenUsage: tokenUsage
                        )
                    )
                )
            }
            notifications.append(
                .rawResponseCompleted(
                    CodexRawResponseCompletedNotification(
                        threadID: threadID,
                        turnID: turnID,
                        responseID: responseID,
                        usage: usage
                    )
                )
            )
            if endTurn != false {
                notifications.append(
                    .turnCompleted(
                        CodexTurnCompletedNotification(
                            threadID: threadID,
                            turn: CodexStoredTurn(
                                id: turnID,
                                items: itemOrder.compactMap {
                                    completedItemsByID[$0]
                                },
                                status: .completed,
                                startedAt: startedAtMs,
                                completedAt: Self.now()
                            )
                        )
                    )
                )
            }
            return notifications
        }
    }

    public mutating func toolOutput(
        request: CodexPersistedTurnToolRequest,
        output: CodexPersistedTurnLocalToolOutput
    ) -> [CodexAppServerTurnNotification] {
        guard let pending = pendingTools.removeValue(forKey: request.callID)
        else {
            return [
                .rawResponseItemCompleted(
                    CodexRawResponseItemCompletedNotification(
                        threadID: threadID,
                        turnID: turnID,
                        item: Self.rawItem(output.itemJSON)
                    )
                )
            ]
        }
        let result = Self.outputResult(output.itemJSON)
        let completed: CodexStoredThreadItem
        switch pending {
        case let .mcp(server, tool, arguments):
            completed = .mcpToolCall(
                id: request.callID,
                server: server,
                tool: tool,
                status: result.isError ? .failed : .completed,
                arguments: arguments,
                appContext: nil,
                mcpAppResourceURI: nil,
                pluginID: nil,
                result: result.value,
                error: result.isError ? result.value : nil,
                durationMs: nil
            )
        case let .command(command, cwd):
            completed = .commandExecution(
                id: request.callID,
                command: command,
                cwd: cwd,
                processID: nil,
                source: .agent,
                status: result.isError ? .failed : .completed,
                commandActions: [],
                aggregatedOutput: Self.outputText(result.value),
                exitCode: result.isError ? 1 : 0,
                durationMs: nil
            )
        case let .fileChange(pendingChanges):
            let changes = output.fileChanges?.map(Self.fileChangeJSON)
                ?? pendingChanges
            completed = .fileChange(
                id: request.callID,
                changes: changes,
                status: result.isError ? .failed : .completed
            )
        case let .plan(text):
            completed = .plan(id: request.callID, text: text)
        case let .dynamic(namespace, tool, arguments):
            completed = .dynamicToolCall(
                id: request.callID,
                namespace: namespace,
                tool: tool,
                arguments: arguments,
                status: result.isError ? .failed : .completed,
                contentItems: [result.value],
                success: !result.isError,
                durationMs: nil
            )
        }
        var notifications: [CodexAppServerTurnNotification] = []
        if let changes = output.fileChanges, !changes.isEmpty {
            notifications.append(
                .fileChangePatchUpdated(
                    CodexFileChangePatchUpdatedNotification(
                        threadID: threadID,
                        turnID: turnID,
                        itemID: request.callID,
                        changes: changes
                    )
                )
            )
        }
        notifications.append(contentsOf: [
            .itemCompleted(
                CodexItemCompletedNotification(
                    item: completed,
                    threadID: threadID,
                    turnID: turnID,
                    completedAtMs: Self.now()
                )
            ),
            .rawResponseItemCompleted(
                CodexRawResponseItemCompletedNotification(
                    threadID: threadID,
                    turnID: turnID,
                    item: Self.rawItem(output.itemJSON)
                )
            ),
        ])
        if let diff = output.workspaceDiff {
            notifications.append(
                .turnDiffUpdated(
                    CodexTurnDiffUpdatedNotification(
                        threadID: threadID,
                        turnID: turnID,
                        diff: diff
                    )
                )
            )
        }
        return notifications
    }

    public mutating func failed(
        _ error: Error,
        willRetry: Bool = false
    ) -> [CodexAppServerTurnNotification] {
        let turnError = CodexStoredTurnError(
            message: String(describing: error)
        )
        var notifications: [CodexAppServerTurnNotification] = [
            .error(
                CodexTurnErrorNotification(
                    error: turnError,
                    willRetry: willRetry,
                    threadID: threadID,
                    turnID: turnID
                )
            ),
        ]
        if !willRetry {
            notifications.append(
                .turnCompleted(
                    CodexTurnCompletedNotification(
                        threadID: threadID,
                        turn: CodexStoredTurn(
                            id: turnID,
                            items: [],
                            status: .failed,
                            error: turnError,
                            startedAt: startedAtMs,
                            completedAt: Self.now()
                        )
                    )
                )
            )
        }
        return notifications
    }

    public mutating func interrupted()
        -> CodexAppServerTurnNotification
    {
        .turnCompleted(
            CodexTurnCompletedNotification(
                threadID: threadID,
                turn: CodexStoredTurn(
                    id: turnID,
                    items: [],
                    status: .interrupted,
                    startedAt: startedAtMs,
                    completedAt: Self.now()
                )
            )
        )
    }

    private mutating func ensurePlanStarted(
        _ planItemID: String
    ) -> [CodexAppServerTurnNotification] {
        guard startedItemIDs.insert(planItemID).inserted else {
            return []
        }
        itemOrder.append(planItemID)
        return [
            .itemStarted(
                CodexItemStartedNotification(
                    item: .plan(id: planItemID, text: ""),
                    threadID: threadID,
                    turnID: turnID,
                    startedAtMs: Self.now()
                )
            )
        ]
    }

    private static func rawItem(
        _ itemJSON: String
    ) -> CodexRawResponseItem {
        guard let data = itemJSON.data(using: .utf8),
              let value = try? JSONDecoder().decode(
                  CodexJSONValue.self,
                  from: data
              ),
              case let .object(values) = value
        else {
            return CodexRawResponseItem(values: [:])
        }
        return CodexRawResponseItem(values: values)
    }

    private static func namespace(_ itemJSON: String) -> String? {
        guard let data = itemJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(
                  with: data
              ) as? [String: Any]
        else {
            return nil
        }
        return object["namespace"] as? String
    }

    private static func isCommandTool(_ name: String) -> Bool {
        [
            "exec_command", "write_stdin", "process/spawn",
            "process/write", "process/resize", "process/kill",
        ].contains(name)
    }

    private static func value(
        _ key: String,
        in value: CodexJSONValue
    ) -> CodexJSONValue? {
        guard case let .object(object) = value else { return nil }
        return object[key]
    }

    private static func string(
        _ key: String,
        in value: CodexJSONValue
    ) -> String? {
        guard case let .string(text)? = self.value(key, in: value) else {
            return nil
        }
        return text
    }

    private static func command(
        _ arguments: CodexJSONValue,
        fallback: String
    ) -> String {
        string("cmd", in: arguments)
            ?? string("command", in: arguments)
            ?? string("chars", in: arguments)
            ?? fallback
    }

    private static func outputText(_ value: CodexJSONValue) -> String {
        if case let .string(text) = value {
            return text
        }
        guard let data = try? JSONEncoder().encode(value) else {
            return String(describing: value)
        }
        return String(decoding: data, as: UTF8.self)
    }

    private static func reasoningItem(
        _ itemJSON: String
    ) -> CodexStoredThreadItem? {
        guard let data = itemJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any],
              object["type"] as? String == "reasoning"
        else {
            return nil
        }
        let id = object["id"] as? String ?? "reasoning-\(UUID().uuidString)"
        return .reasoning(
            id: id,
            summary: textParts(object["summary"]),
            content: textParts(object["content"])
        )
    }

    private mutating func reasoningRealtimeNotification(
        eventType: String,
        payload: CodexJSONValue
    ) -> CodexAppServerTurnNotification? {
        guard let itemID = currentReasoningItemID else {
            return nil
        }
        switch eventType {
        case "reasoning_summary_delta":
            guard let delta = Self.string("delta", in: payload),
                  !delta.isEmpty,
                  let summaryIndex = Self.nonnegativeInteger(
                      "summary_index",
                      in: payload
                  )
            else {
                return nil
            }
            return .reasoningSummaryTextDelta(
                CodexReasoningSummaryTextDeltaNotification(
                    threadID: threadID,
                    turnID: turnID,
                    itemID: itemID,
                    summaryIndex: summaryIndex,
                    delta: delta
                )
            )
        case "reasoning_summary_part_added":
            guard let summaryIndex = Self.nonnegativeInteger(
                "summary_index",
                in: payload
            ) else {
                return nil
            }
            return .reasoningSummaryPartAdded(
                CodexReasoningSummaryPartAddedNotification(
                    threadID: threadID,
                    turnID: turnID,
                    itemID: itemID,
                    summaryIndex: summaryIndex
                )
            )
        case "reasoning_content_delta":
            guard let delta = Self.string("delta", in: payload),
                  !delta.isEmpty,
                  let contentIndex = Self.nonnegativeInteger(
                      "content_index",
                      in: payload
                  )
            else {
                return nil
            }
            return .reasoningTextDelta(
                CodexReasoningTextDeltaNotification(
                    threadID: threadID,
                    turnID: turnID,
                    itemID: itemID,
                    contentIndex: contentIndex,
                    delta: delta
                )
            )
        default:
            return nil
        }
    }

    private func opaqueRealtime(
        eventType: String,
        payload: CodexJSONValue
    ) -> CodexAppServerTurnNotification {
        let method = "provider/\(eventType)"
        return .opaque(
            method: method,
            rawEnvelope: .object([
                "method": .string(method),
                "params": .object([
                    "threadId": .string(threadID.rawValue),
                    "turnId": .string(turnID),
                    "eventType": .string(eventType),
                    "payload": payload,
                ]),
            ])
        )
    }

    private static func reasoningItemID(
        _ payload: CodexJSONValue
    ) -> String? {
        guard string("type", in: payload) == "reasoning",
              let id = string("id", in: payload),
              !id.isEmpty
        else {
            return nil
        }
        return id
    }

    private static func nonnegativeInteger(
        _ key: String,
        in value: CodexJSONValue
    ) -> Int64? {
        guard case let .integer(number)? = self.value(key, in: value),
              number >= 0
        else {
            return nil
        }
        return number
    }

    private static func textParts(_ value: Any?) -> [String] {
        guard let values = value as? [Any] else { return [] }
        return values.compactMap { element in
            if let text = element as? String {
                return text
            }
            if let object = element as? [String: Any] {
                return object["text"] as? String
            }
            return nil
        }
    }

    private static func jsonValue(_ json: String) -> CodexJSONValue {
        guard let data = json.data(using: .utf8),
              let value = try? JSONDecoder().decode(
                  CodexJSONValue.self,
                  from: data
              )
        else {
            return .string(json)
        }
        return value
    }

    private static func fileChangeJSON(
        _ change: CodexFileUpdateChange
    ) -> CodexJSONValue {
        guard let data = try? JSONEncoder().encode(change),
              let value = try? JSONDecoder().decode(
                  CodexJSONValue.self,
                  from: data
              )
        else {
            return .null
        }
        return value
    }

    private static func outputResult(
        _ itemJSON: String
    ) -> (value: CodexJSONValue, isError: Bool) {
        guard let data = itemJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(
                  with: data
              ) as? [String: Any],
              let output = object["output"] as? String
        else {
            return (.string(itemJSON), true)
        }
        let value = jsonValue(output)
        let isError: Bool
        if output.hasPrefix("Tool execution failed:") {
            isError = true
        } else if case let .object(payload) = value,
           case let .bool(flag)? = payload["isError"]
        {
            isError = flag
        } else {
            isError = false
        }
        return (value, isError)
    }

    private static func now() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }
}
