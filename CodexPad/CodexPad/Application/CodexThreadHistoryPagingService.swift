#if SWIFT_PACKAGE
import CodexPadDomain
import CodexPadProtocolBridge
#endif
import Foundation

public enum CodexThreadHistoryPagingError:
    Error,
    Equatable,
    Sendable
{
    case invalidParams
    case invalidCursor
}

@MainActor
public protocol CodexDesktopThreadHistoryPaging: AnyObject {
    func listStoredThreadTurns(
        id: CodexAppServerRequestID,
        threadID: CodexStoredThreadID,
        cursor: String?,
        limit: UInt32?,
        sortDirection: CodexThreadSortDirection,
        itemsView: CodexStoredTurnItemsView
    ) throws -> CodexJSONValue

    func listStoredThreadItems(
        id: CodexAppServerRequestID,
        threadID: CodexStoredThreadID,
        turnID: String?,
        cursor: String?,
        limit: UInt32?,
        sortDirection: CodexThreadSortDirection
    ) throws -> CodexJSONValue

    func searchStoredThreadOccurrences(
        id: CodexAppServerRequestID,
        threadID: CodexStoredThreadID,
        searchTerm: String,
        cursor: String?,
        limit: UInt32?
    ) throws -> CodexJSONValue
}

@MainActor
extension CodexSessionStore: CodexDesktopThreadHistoryPaging {
    public func listStoredThreadTurns(
        id: CodexAppServerRequestID,
        threadID: CodexStoredThreadID,
        cursor: String?,
        limit: UInt32?,
        sortDirection: CodexThreadSortDirection,
        itemsView: CodexStoredTurnItemsView
    ) throws -> CodexJSONValue {
        let thread = try readThread(
            id: id,
            params: .init(
                threadID: threadID,
                includeTurns: true
            )
        ).thread
        var ordered = thread.turns
        if sortDirection == .descending {
            ordered.reverse()
        }
        let turns = ordered.map {
            Self.applying(itemsView, to: $0)
        }
        let page = try Self.page(
            turns,
            cursor: cursor,
            limit: limit,
            context: .init(
                kind: "turn",
                threadID: threadID.rawValue,
                turnID: nil
            ),
            identifier: \.id
        )
        return .object([
            "data": .array(
                try page.data.map(Self.jsonValue)
            ),
            "nextCursor":
                page.nextCursor.map(CodexJSONValue.string)
                    ?? .null,
            "backwardsCursor":
                page.backwardsCursor.map(
                    CodexJSONValue.string
                ) ?? .null,
        ])
    }

    public func listStoredThreadItems(
        id: CodexAppServerRequestID,
        threadID: CodexStoredThreadID,
        turnID: String?,
        cursor: String?,
        limit: UInt32?,
        sortDirection: CodexThreadSortDirection
    ) throws -> CodexJSONValue {
        let thread = try readThread(
            id: id,
            params: .init(
                threadID: threadID,
                includeTurns: true
            )
        ).thread
        var entries = thread.turns.flatMap { turn in
            turn.items.map {
                ItemEntry(turnID: turn.id, item: $0)
            }
        }
        if let turnID {
            entries = entries.filter {
                $0.turnID == turnID
            }
        }
        if sortDirection == .descending {
            entries.reverse()
        }
        let page = try Self.page(
            entries,
            cursor: cursor,
            limit: limit,
            context: .init(
                kind: "item",
                threadID: threadID.rawValue,
                turnID: turnID
            ),
            identifier: \.item.id
        )
        return .object([
            "data": .array(
                try page.data.map { entry in
                    .object([
                        "turnId": .string(entry.turnID),
                        "item": try Self.jsonValue(
                            entry.item
                        ),
                    ])
                }
            ),
            "nextCursor":
                page.nextCursor.map(CodexJSONValue.string)
                    ?? .null,
            "backwardsCursor":
                page.backwardsCursor.map(
                    CodexJSONValue.string
                ) ?? .null,
        ])
    }

    public func searchStoredThreadOccurrences(
        id: CodexAppServerRequestID,
        threadID: CodexStoredThreadID,
        searchTerm: String,
        cursor: String?,
        limit: UInt32?
    ) throws -> CodexJSONValue {
        guard !searchTerm.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty else {
            throw CodexThreadHistoryPagingError.invalidParams
        }
        let thread = try readThread(
            id: id,
            params: .init(
                threadID: threadID,
                includeTurns: true
            )
        ).thread
        let candidates = thread.turns.flatMap {
            Self.searchCandidates(in: $0)
        }
        let decodedCursor = try cursor.map {
            try Self.decodeSearchCursor($0)
        }
        if let decodedCursor {
            guard decodedCursor.threadID == threadID.rawValue,
                  decodedCursor.searchTerm == searchTerm,
                  decodedCursor.nextRolloutOrdinal >= 0,
                  decodedCursor.nextOccurrenceIndex >= 0,
                  decodedCursor.nextRolloutOrdinal < candidates.count
            else {
                throw CodexThreadHistoryPagingError.invalidCursor
            }
        }
        let pageSize = min(max(Int(limit ?? 50), 1), 250)
        var occurrences: [CodexJSONValue] = []
        var nextCursor: String?
        let startOrdinal = decodedCursor?.nextRolloutOrdinal ?? 0

        candidateLoop: for ordinal in startOrdinal..<candidates.count {
            let candidate = candidates[ordinal]
            let ranges = Self.literalRanges(
                of: searchTerm,
                in: candidate.text
            )
            let startOccurrence =
                ordinal == decodedCursor?.nextRolloutOrdinal
                    ? decodedCursor?.nextOccurrenceIndex ?? 0
                    : 0
            guard startOccurrence <= ranges.count else {
                throw CodexThreadHistoryPagingError.invalidCursor
            }
            for occurrenceIndex in startOccurrence..<ranges.count {
                if occurrences.count == pageSize {
                    nextCursor = try Self.encodeSearchCursor(
                        .init(
                            threadID: threadID.rawValue,
                            searchTerm: searchTerm,
                            nextRolloutOrdinal: ordinal,
                            nextOccurrenceIndex: occurrenceIndex
                        )
                    )
                    break candidateLoop
                }
                let snippet = Self.searchSnippet(
                    text: candidate.text,
                    match: ranges[occurrenceIndex]
                )
                occurrences.append(
                    .object([
                        "turnId": .string(candidate.turnID),
                        "itemId": .string(candidate.itemID),
                        "snippet": .string(snippet.text),
                        "snippetMatchRange": .object([
                            "start": .integer(
                                Int64(snippet.matchStart)
                            ),
                            "end": .integer(
                                Int64(snippet.matchEnd)
                            ),
                        ]),
                        "turnCursor": .string(
                            try Self.encodeCursor(
                                context: .init(
                                    kind: "turn",
                                    threadID: threadID.rawValue,
                                    turnID: nil
                                ),
                                anchorID: candidate.turnID,
                                includeAnchor: true
                            )
                        ),
                    ])
                )
            }
        }
        return .object([
            "data": .array(occurrences),
            "nextCursor":
                nextCursor.map(CodexJSONValue.string) ?? .null,
        ])
    }

    private struct ItemEntry {
        let turnID: String
        let item: CodexStoredThreadItem
    }

    private struct SearchCandidate {
        let turnID: String
        let itemID: String
        let text: String
    }

    private struct SearchCursor: Codable {
        let threadID: String
        let searchTerm: String
        let nextRolloutOrdinal: Int
        let nextOccurrenceIndex: Int
    }

    private struct SearchSnippet {
        let text: String
        let matchStart: Int
        let matchEnd: Int
    }

    private struct CursorContext:
        Equatable
    {
        let kind: String
        let threadID: String
        let turnID: String?
    }

    private struct Cursor:
        Codable
    {
        let version: Int
        let kind: String
        let threadID: String
        let turnID: String?
        let anchorID: String
        let includeAnchor: Bool
    }

    private struct Page<Value> {
        let data: [Value]
        let nextCursor: String?
        let backwardsCursor: String?
    }

    private static func page<Value>(
        _ values: [Value],
        cursor: String?,
        limit: UInt32?,
        context: CursorContext,
        identifier: KeyPath<Value, String>
    ) throws -> Page<Value> {
        let pageSize = min(
            max(Int(limit ?? 25), 1),
            100
        )
        let start: Int
        if let cursor {
            let decoded = try decodeCursor(cursor)
            guard decoded.version == 1,
                  decoded.kind == context.kind,
                  decoded.threadID == context.threadID,
                  decoded.turnID == context.turnID,
                  let anchor = values.firstIndex(
                      where: {
                          $0[keyPath: identifier]
                              == decoded.anchorID
                      }
                  )
            else {
                throw CodexThreadHistoryPagingError
                    .invalidCursor
            }
            start = decoded.includeAnchor
                ? anchor
                : anchor + 1
        } else {
            start = 0
        }
        let end = min(start + pageSize, values.count)
        let data = start < end
            ? Array(values[start..<end])
            : []
        let next = end < values.count
            ? try encodeCursor(
                context: context,
                anchorID:
                    data.last![keyPath: identifier],
                includeAnchor: false
            )
            : nil
        let backwards: String?
        if let first = data.first {
            backwards = try encodeCursor(
                context: context,
                anchorID: first[keyPath: identifier],
                includeAnchor: true
            )
        } else {
            backwards = nil
        }
        return .init(
            data: data,
            nextCursor: next,
            backwardsCursor: backwards
        )
    }

    private static func encodeCursor(
        context: CursorContext,
        anchorID: String,
        includeAnchor: Bool
    ) throws -> String {
        try JSONEncoder().encode(
            Cursor(
                version: 1,
                kind: context.kind,
                threadID: context.threadID,
                turnID: context.turnID,
                anchorID: anchorID,
                includeAnchor: includeAnchor
            )
        ).base64EncodedString()
    }

    private static func decodeCursor(
        _ cursor: String
    ) throws -> Cursor {
        guard let data = Data(base64Encoded: cursor),
              let decoded = try? JSONDecoder().decode(
                  Cursor.self,
                  from: data
              )
        else {
            throw CodexThreadHistoryPagingError
                .invalidCursor
        }
        return decoded
    }

    private static func encodeSearchCursor(
        _ cursor: SearchCursor
    ) throws -> String {
        let data = try JSONEncoder().encode(cursor)
        guard let value = String(data: data, encoding: .utf8)
        else {
            throw CodexThreadHistoryPagingError.invalidCursor
        }
        return value
    }

    private static func decodeSearchCursor(
        _ cursor: String
    ) throws -> SearchCursor {
        guard let data = cursor.data(using: .utf8),
              let value = try? JSONDecoder().decode(
                  SearchCursor.self,
                  from: data
              )
        else {
            throw CodexThreadHistoryPagingError.invalidCursor
        }
        return value
    }

    private static func searchCandidates(
        in turn: CodexStoredTurn
    ) -> [SearchCandidate] {
        var candidates = turn.items.compactMap {
            item -> SearchCandidate? in
            guard case let .userMessage(id, _, content) = item
            else { return nil }
            let text = content.compactMap {
                input -> String? in
                guard case let .text(text, _) = input
                else { return nil }
                return stripUserMessagePrefix(text)
            }.filter { !$0.isEmpty }.joined()
            guard !text.isEmpty else { return nil }
            return .init(
                turnID: turn.id,
                itemID: id,
                text: text
            )
        }
        if let finalAgent = turn.items.last(where: {
            $0.kind == .agentMessage
        }), case let .agentMessage(id, text, _, _) = finalAgent {
            let searchable = markdownSearchText(text)
            if !searchable.isEmpty {
                candidates.append(
                    .init(
                        turnID: turn.id,
                        itemID: id,
                        text: searchable
                    )
                )
            }
        }
        return candidates
    }

    private static func stripUserMessagePrefix(
        _ text: String
    ) -> String {
        let marker = "## My request for Codex:"
        let visible = text.range(of: marker).map {
            String(text[$0.upperBound...])
        } ?? text
        return visible.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
    }

    private static func markdownSearchText(
        _ markdown: String
    ) -> String {
        var text = markdown.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let replacements: [(String, String)] = [
            (#"!\[[^\]]*\]\([^)]+\)"#, ""),
            (#"\[([^\]]+)\]\([^)]+\)"#, "$1"),
            (#"<[^>]+>"#, ""),
            (#"(?m)^\s{0,3}(?:#{1,6}|>|[-+*]|\d+\.)\s+"#, ""),
            (#"[*_~`]+"#, ""),
        ]
        for (pattern, replacement) in replacements {
            text = text.replacingOccurrences(
                of: pattern,
                with: replacement,
                options: .regularExpression
            )
        }
        return text.split(
            whereSeparator: \.isWhitespace
        ).joined(separator: " ")
    }

    private static func literalRanges(
        of needle: String,
        in text: String
    ) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var remaining = text.startIndex..<text.endIndex
        while let match = text.range(
            of: needle,
            options: [.caseInsensitive],
            range: remaining
        ) {
            ranges.append(match)
            guard match.upperBound < text.endIndex else {
                break
            }
            remaining = match.upperBound..<text.endIndex
        }
        return ranges
    }

    private static func searchSnippet(
        text: String,
        match: Range<String.Index>
    ) -> SearchSnippet {
        let start = text.index(
            match.lowerBound,
            offsetBy: -48,
            limitedBy: text.startIndex
        ) ?? text.startIndex
        let end = text.index(
            match.upperBound,
            offsetBy: 96,
            limitedBy: text.endIndex
        ) ?? text.endIndex
        let leading = start > text.startIndex
        let trailing = end < text.endIndex
        let core = String(text[start..<end])
        let snippet =
            (leading ? "... " : "")
            + core
            + (trailing ? " ..." : "")
        let before = String(text[start..<match.lowerBound])
        let matchText = String(text[match])
        let matchStart =
            (leading ? 4 : 0)
            + before.utf16.count
        return .init(
            text: snippet,
            matchStart: matchStart,
            matchEnd: matchStart + matchText.utf16.count
        )
    }

    private static func applying(
        _ view: CodexStoredTurnItemsView,
        to turn: CodexStoredTurn
    ) -> CodexStoredTurn {
        let items: [CodexStoredThreadItem]
        switch view {
        case .notLoaded:
            items = []
        case .summary:
            let firstUser = turn.items.first {
                $0.kind == .userMessage
            }
            let finalAgent = turn.items.last {
                $0.kind == .agentMessage
            }
            if let firstUser, let finalAgent,
               firstUser.id != finalAgent.id
            {
                items = [firstUser, finalAgent]
            } else {
                items = [firstUser, finalAgent]
                    .compactMap { $0 }
            }
        case .full:
            items = turn.items
        }
        return .init(
            id: turn.id,
            items: items,
            itemsView: view,
            status: turn.status,
            error: turn.error,
            startedAt: turn.startedAt,
            completedAt: turn.completedAt,
            durationMs: turn.durationMs
        )
    }

    private static func jsonValue<Value: Encodable>(
        _ value: Value
    ) throws -> CodexJSONValue {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(
            CodexJSONValue.self,
            from: data
        )
    }
}
