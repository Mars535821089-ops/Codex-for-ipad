#if SWIFT_PACKAGE
import CodexPadDomain
#endif
import Foundation

public struct CodexStoredThreadPresentation:
    Equatable,
    Identifiable,
    Sendable
{
    public let id: CodexStoredThreadID
    public let storedThread: CodexStoredThread
    public let title: String
    public let summary: String
    public let items: [CodexStoredThreadItemPresentation]

    public init(
        thread: CodexStoredThread,
        searchSnippet: String? = nil
    ) {
        id = thread.id
        storedThread = thread
        title =
            thread.name?.trimmedNonempty
            ?? thread.preview.trimmedNonempty
            ?? thread.id.rawValue
        summary =
            searchSnippet?.trimmedNonempty
            ?? thread.preview.trimmedNonempty
            ?? thread.cwd.trimmedNonempty
            ?? thread.id.rawValue
        items = thread.turns.flatMap { turn in
            turn.items.map {
                CodexStoredThreadItemPresentation(
                    item: $0,
                    turnID: turn.id
                )
            }
        }
    }

    public init(searchHit: CodexThreadSearchHit) {
        self.init(
            thread: searchHit.thread,
            searchSnippet: searchHit.snippet
        )
    }
}

public struct CodexStoredThreadItemPresentation:
    Equatable,
    Identifiable,
    Sendable
{
    public struct ID: Equatable, Hashable, Sendable {
        public let turnID: String
        public let itemID: String

        public init(turnID: String, itemID: String) {
            self.turnID = turnID
            self.itemID = itemID
        }
    }

    public let id: ID
    public let itemID: String
    public let turnID: String
    public let kind: CodexStoredThreadItemKind
    public let textFragments: [String]

    public init(item: CodexStoredThreadItem, turnID: String) {
        id = ID(turnID: turnID, itemID: item.id)
        itemID = item.id
        self.turnID = turnID
        kind = item.kind

        switch item {
        case let .userMessage(_, _, content):
            textFragments = content.flatMap(\.presentationFragments)

        case let .hookPrompt(_, fragments):
            textFragments = fragments.map(\.presentationFragment)

        case let .agentMessage(_, text, phase, memoryCitation):
            textFragments =
                [text]
                + optional(phase?.rawValue)
                + optional(memoryCitation?.presentationFragment)

        case let .plan(_, text):
            textFragments = [text]

        case let .reasoning(_, summary, content):
            textFragments = summary + content

        case let .commandExecution(
            _,
            command,
            cwd,
            processID,
            source,
            status,
            commandActions,
            aggregatedOutput,
            exitCode,
            durationMs
        ):
            var fragments = [command, cwd]
            fragments += optional(processID)
            fragments += [source.rawValue, status.rawValue]
            fragments += commandActions.map(\.presentationFragment)
            fragments += optional(aggregatedOutput)
            fragments += optional(exitCode.map { String($0) })
            fragments += optional(durationMs.map { String($0) })
            textFragments = fragments

        case let .fileChange(_, changes, status):
            textFragments =
                changes.map(\.presentationFragment)
                + [status.rawValue]

        case let .mcpToolCall(
            _,
            server,
            tool,
            status,
            arguments,
            appContext,
            mcpAppResourceURI,
            pluginID,
            result,
            error,
            durationMs
        ):
            var fragments = [
                server,
                tool,
                status.rawValue,
                arguments.presentationFragment,
            ]
            fragments += optional(appContext?.presentationFragment)
            fragments += optional(mcpAppResourceURI)
            fragments += optional(pluginID)
            fragments += optional(result?.presentationFragment)
            fragments += optional(error?.presentationFragment)
            fragments += optional(durationMs.map { String($0) })
            textFragments = fragments

        case let .dynamicToolCall(
            _,
            namespace,
            tool,
            arguments,
            status,
            contentItems,
            success,
            durationMs
        ):
            var fragments = optional(namespace)
            fragments += [
                tool,
                arguments.presentationFragment,
                status.rawValue,
            ]
            fragments += (contentItems ?? []).map(\.presentationFragment)
            fragments += optional(success.map { String($0) })
            fragments += optional(durationMs.map { String($0) })
            textFragments = fragments

        case let .collabAgentToolCall(
            _,
            tool,
            status,
            senderThreadID,
            receiverThreadIDs,
            prompt,
            model,
            reasoningEffort,
            agentsStates
        ):
            textFragments =
                [tool.rawValue, status.rawValue, senderThreadID]
                + receiverThreadIDs
                + optional(prompt)
                + optional(model)
                + optional(reasoningEffort)
                + [
                    CodexJSONValue.object(agentsStates).presentationFragment,
                ]

        case let .subAgentActivity(
            _,
            kind,
            agentThreadID,
            agentPath
        ):
            textFragments = [kind.rawValue, agentThreadID, agentPath]

        case let .webSearch(_, query, action, results):
            textFragments =
                [query]
                + optional(action?.presentationFragment)
                + (results ?? []).map(\.presentationFragment)

        case let .imageView(_, path):
            textFragments = [path]

        case let .sleep(_, durationMs):
            textFragments = [String(durationMs)]

        case let .imageGeneration(
            _,
            status,
            revisedPrompt,
            result,
            savedPath
        ):
            textFragments =
                [status]
                + optional(revisedPrompt)
                + [result]
                + optional(savedPath)

        case let .enteredReviewMode(_, review):
            textFragments = [review]

        case let .exitedReviewMode(_, review):
            textFragments = [review]

        case .contextCompaction:
            textFragments = []
        }
    }
}

private func optional<Value>(_ value: Value?) -> [Value] {
    value.map { [$0] } ?? []
}

private extension String {
    var trimmedNonempty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private extension CodexStoredUserInput {
    var presentationFragments: [String] {
        switch self {
        case let .text(text, textElements):
            [text] + textElements.map(\.presentationFragment)

        case let .image(detail, url):
            [url] + optional(detail?.rawValue)

        case let .localImage(detail, path):
            [path] + optional(detail?.rawValue)

        case let .audio(url):
            [url]

        case let .localAudio(path):
            [path]

        case let .skill(name, path):
            [name, path]

        case let .mention(name, path):
            [name, path]
        }
    }
}

private extension CodexJSONValue {
    var presentationFragment: String {
        switch self {
        case .null:
            "null"

        case let .bool(value):
            String(value)

        case let .integer(value):
            String(value)

        case let .number(value):
            String(value)

        case let .string(value):
            value

        case let .array(values):
            "["
                + values.map(\.presentationFragment).joined(separator: ", ")
                + "]"

        case let .object(values):
            "{"
                + values.keys.sorted().map { key in
                    "\(key): \(values[key]!.presentationFragment)"
                }.joined(separator: ", ")
                + "}"
        }
    }
}
