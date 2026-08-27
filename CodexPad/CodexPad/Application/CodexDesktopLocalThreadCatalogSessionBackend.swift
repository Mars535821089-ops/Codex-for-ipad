import CryptoKit
import Foundation

#if SWIFT_PACKAGE
import CodexPadDomain
import CodexPadProtocolBridge
#endif

/// Production `local` host catalog backed by the app-server session store.
///
/// Release 26.730.61309 confirms the renderer-facing entry fields, opaque v3
/// public cursor (with a structural payload), filters/manual order, descending
/// `created_at` / `updated_at` ordering, and full-scan `thread/list` parameters
/// used below. The platform mapping is from `CodexStoredThread` because iPad
/// does not carry desktop's SQLite catalog.
@MainActor
public final class CodexDesktopLocalThreadCatalogSessionBackend:
    CodexDesktopLocalThreadCatalogBackend
{
    public typealias Value = CodexDesktopAppHostRPC.Value
    public typealias EventHandler =
        @Sendable (Value) async -> Void

    public enum Error: Swift.Error, Equatable, Sendable {
        case invalidRequest(String)
        case unsupportedHostID(String)
        case invalidCursor
        case threadIDMismatch(expected: String, actual: String)
        case repeatedServerCursor(String)
    }

    public nonisolated static let localHostID = "local"

    private enum SortKey: String {
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    private struct Entry: Equatable, Sendable {
        let threadID: String
        let displayTitle: String
        let sourceCreatedAt: Int64
        let sourceUpdatedAt: Int64
        let sourceRecencyAt: Int64
        let cwd: String
        let sourceKind: String
        let sourceDetail: String?
        let threadSource: String?
        let modelProvider: String
        let gitBranch: String?

        var value: Value {
            .object([
                "hostId": .string(
                    CodexDesktopLocalThreadCatalogSessionBackend
                        .localHostID
                ),
                "threadId": .string(threadID),
                "displayTitle": .string(displayTitle),
                "sourceCreatedAt": .integer(sourceCreatedAt),
                "sourceUpdatedAt": .integer(sourceUpdatedAt),
                "sourceRecencyAt": .integer(sourceRecencyAt),
                "cwd": .string(cwd),
                "sourceKind": .string(sourceKind),
                "sourceDetail":
                    sourceDetail.map(Value.string) ?? .null,
                "threadSource":
                    threadSource.map(Value.string) ?? .null,
                "modelProvider": .string(modelProvider),
                "gitBranch": gitBranch.map(Value.string) ?? .null,
            ])
        }
    }

    private struct Cursor: Equatable, Sendable {
        let sortKey: SortKey
        let sourceUpdatedAt: Int64
        let sourceRecencyAt: Int64
        let sourceCreatedAt: Int64
        let threadID: String
    }

    private struct CursorEnvelope: Codable {
        let version: Int
        let hostId: String
        let filterFingerprint: String
        let sortKey: String
        let sourceUpdatedAt: Int64
        let sourceRecencyAt: Int64
        let sourceCreatedAt: Int64
        let threadId: String
    }

    private struct Filter: Equatable, Sendable {
        let includeAll: Bool
        let cwdValues: [String]
        let cwdPrefixes: [String]
        let includeThreadIDs: [String]
        let excludeThreadIDs: [String]

        func includes(_ entry: Entry) -> Bool {
            guard !excludeThreadIDs.contains(entry.threadID) else {
                return false
            }
            guard !includeAll else {
                return true
            }
            return cwdValues.contains(entry.cwd)
                || cwdPrefixes.contains {
                    entry.cwd.hasPrefix($0)
                }
                || includeThreadIDs.contains(entry.threadID)
        }
    }

    private struct ManualOrder: Equatable, Sendable {
        let threadIDs: [String]
        let startIndex: Int
    }

    private struct PageRequest: Sendable {
        let limit: Int
        let sortKey: SortKey
        let cursor: Cursor?
        let filter: Filter?
        let filterFingerprint: String
        let manualOrder: ManualOrder?
    }

    private let sessionStore: CodexSessionStore
    private let syncPageLimit: UInt32
    private var entriesByThreadID: [String: Entry] = [:]
    private var revision: Int64 = 0
    private var isComplete = false
    private var populationEnabled = false
    private var nextRequestSequence: UInt64 = 0
    private var catalogHandlers: [UUID: EventHandler] = [:]
    private var statusHandlers: [UUID: EventHandler] = [:]
    private var threadObservationHandlers:
        [UUID: EventHandler] = [:]

    public init(
        sessionStore: CodexSessionStore,
        syncPageLimit: UInt32 = 100
    ) {
        precondition(syncPageLimit > 0)
        self.sessionStore = sessionStore
        self.syncPageLimit = syncPageLimit
    }

    public func readPage(_ request: Value) async throws -> Value {
        let page = try Self.pageRequest(request)
        if let manualOrder = page.manualOrder {
            return Self.manualPage(
                entriesByThreadID: entriesByThreadID,
                order: manualOrder,
                filter: page.filter,
                limit: page.limit
            )
        }

        let sorted = entriesByThreadID.values.filter {
            page.filter?.includes($0) ?? true
        }.sorted {
            Self.isOrderedBefore($0, $1, sortKey: page.sortKey)
        }
        let remaining: [Entry]
        if let cursor = page.cursor {
            remaining = sorted.filter {
                Self.isOrderedAfter(
                    $0,
                    cursor: cursor,
                    sortKey: page.sortKey
                )
            }
        } else {
            remaining = sorted
        }
        let selected = Array(remaining.prefix(page.limit))
        let nextCursor: Value
        if selected.count < remaining.count,
           let last = selected.last
        {
            let cursor = Cursor(
                sortKey: page.sortKey,
                sourceUpdatedAt: last.sourceUpdatedAt,
                sourceRecencyAt: last.sourceRecencyAt,
                sourceCreatedAt: last.sourceCreatedAt,
                threadID: last.threadID
            )
            nextCursor = .string(
                try Self.encodeCursor(
                    cursor,
                    filterFingerprint: page.filterFingerprint
                )
            )
        } else {
            nextCursor = .null
        }
        return .object([
            "entries": .array(selected.map(\.value)),
            "nextCursor": nextCursor,
        ])
    }

    public func readEntries(
        _ locators: [Value]
    ) async throws -> [Value] {
        guard locators.count <= 100 else {
            throw Error.invalidRequest("locators")
        }
        var values: [Value] = []
        values.reserveCapacity(locators.count)
        var changedByID: [String: Entry] = [:]

        for locator in locators {
            let threadID = try Self.threadID(from: locator)
            if let entry = entriesByThreadID[threadID] {
                values.append(entry.value)
                continue
            }

            let result = try sessionStore.readThread(
                id: nextRequestID(operation: "read"),
                params: .init(
                    threadID: .init(threadID),
                    includeTurns: false
                )
            )
            guard result.thread.id.rawValue == threadID else {
                throw Error.threadIDMismatch(
                    expected: threadID,
                    actual: result.thread.id.rawValue
                )
            }
            try await emitThreadObservation(
                threads: [result.thread]
            )
            guard let entry = Self.entry(from: result.thread) else {
                continue
            }
            if entriesByThreadID[threadID] != entry {
                entriesByThreadID[threadID] = entry
                changedByID[threadID] = entry
            }
            values.append(entry.value)
        }

        if !changedByID.isEmpty {
            try bumpRevision()
            await emitCatalogMutation(
                changedEntries: Array(changedByID.values),
                removedThreadIDs: []
            )
        }
        return values
    }

    /// Removes only the derived catalog cache row. It intentionally does not
    /// archive, delete, or otherwise mutate the persisted app-server thread.
    public func removeMissingEntry(
        _ locator: Value
    ) async throws -> Bool {
        let threadID = try Self.threadID(from: locator)
        guard entriesByThreadID.removeValue(
            forKey: threadID
        ) != nil else {
            return false
        }
        try bumpRevision()
        await emitCatalogMutation(
            changedEntries: [],
            removedThreadIDs: [threadID]
        )
        return true
    }

    public func readSnapshot() async throws -> Value {
        snapshotValue()
    }

    public func readStatus() async throws -> Value {
        statusValue()
    }

    public func setPopulationEnabled(
        _ enabled: Bool,
        startup: String
    ) async throws {
        guard startup == "idle" || startup == "manual" else {
            throw Error.invalidRequest("startup")
        }
        if populationEnabled != enabled {
            populationEnabled = enabled
            await emitStatus(statusValue())
        }
        if enabled, startup == "idle" {
            try await performFullSync()
        }
    }

    public func requestSync(
        hostIDs: [String]?,
        priority: String
    ) async throws {
        guard priority == "normal" || priority == "immediate" else {
            throw Error.invalidRequest("priority")
        }
        guard populationEnabled else {
            return
        }
        if let hostIDs,
           !hostIDs.contains(Self.localHostID)
        {
            return
        }
        try await performFullSync()
    }

    public func requestStartupSync() async throws {
        guard populationEnabled else {
            return
        }
        try await performFullSync()
    }

    public func subscribeCatalogEvents(
        _ handler: @escaping EventHandler
    ) async -> CodexDesktopLocalThreadCatalogBackendSubscription {
        let id = UUID()
        catalogHandlers[id] = handler
        return .init { [weak self] in
            await self?.removeCatalogHandler(id)
        }
    }

    public func subscribeStatusEvents(
        _ handler: @escaping EventHandler
    ) async -> CodexDesktopLocalThreadCatalogBackendSubscription {
        let id = UUID()
        statusHandlers[id] = handler
        return .init { [weak self] in
            await self?.removeStatusHandler(id)
        }
    }

    public func subscribeThreadObservationEvents(
        _ handler: @escaping EventHandler
    ) async -> CodexDesktopLocalThreadCatalogBackendSubscription {
        let id = UUID()
        threadObservationHandlers[id] = handler
        return .init { [weak self] in
            await self?.removeThreadObservationHandler(id)
        }
    }

    private func performFullSync() async throws {
        var cursor: String?
        var seenCursors: Set<String> = []
        var scannedEntries: [String: Entry] = [:]

        repeat {
            let page = try sessionStore.listThreads(
                id: nextRequestID(operation: "list"),
                params: .init(
                    cursor: cursor.map(CodexWireOptional.value)
                        ?? .omitted,
                    limit: .value(syncPageLimit),
                    sortKey: .value(.updatedAt),
                    sortDirection: .value(.descending),
                    // Empty means the official interactive source set, including ChatGPT.
                    sourceKinds: .value([]),
                    archived: .value(false),
                    useStateDbOnly: true,
                    parentThreadID: .null
                )
            )
            try await emitThreadObservation(threads: page.data)
            for thread in page.data {
                if let entry = Self.entry(from: thread) {
                    scannedEntries[entry.threadID] = entry
                }
            }
            cursor = page.nextCursor
            if let cursor, !seenCursors.insert(cursor).inserted {
                throw Error.repeatedServerCursor(cursor)
            }
        } while cursor != nil

        let changedEntries = scannedEntries.values.filter {
            entriesByThreadID[$0.threadID] != $0
        }
        let removedThreadIDs = entriesByThreadID.keys
            .filter { scannedEntries[$0] == nil }
        let completionChanged = !isComplete
        guard !changedEntries.isEmpty
                || !removedThreadIDs.isEmpty
                || completionChanged
        else {
            return
        }

        entriesByThreadID = scannedEntries
        isComplete = true
        try bumpRevision()
        await emitCatalogMutation(
            changedEntries: changedEntries,
            removedThreadIDs: removedThreadIDs
        )
    }

    private func snapshotValue() -> Value {
        let entries = entriesByThreadID.values.sorted {
            Self.isOrderedBefore(
                $0,
                $1,
                sortKey: .updatedAt
            )
        }
        return .object([
            "revision": .integer(revision),
            "isComplete": .bool(isComplete),
            "hosts": .array([hostSnapshotValue()]),
            "entries": .array(entries.map(\.value)),
        ])
    }

    private func statusValue() -> Value {
        .object([
            "revision": .integer(revision),
            "populationEnabled": .bool(populationEnabled),
            "hosts": .array([
                .object([
                    "hostId": .string(Self.localHostID),
                    "isComplete": .bool(isComplete),
                    "revision": .integer(revision),
                ]),
            ]),
        ])
    }

    private func hostSnapshotValue() -> Value {
        .object([
            "hostId": .string(Self.localHostID),
            "isComplete": .bool(isComplete),
        ])
    }

    private func emitCatalogMutation(
        changedEntries: [Entry],
        removedThreadIDs: [String]
    ) async {
        let sortedChanged = changedEntries.sorted {
            Self.isOrderedBefore(
                $0,
                $1,
                sortKey: .updatedAt
            )
        }
        let event: Value = .object([
            "type": .string("delta"),
            "delta": .object([
                "revision": .integer(revision),
                "changedHosts": .array([hostSnapshotValue()]),
                "removedHostIds": .array([]),
                "changedEntries": .array(
                    sortedChanged.map(\.value)
                ),
                "removedEntries": .array(
                    removedThreadIDs.sorted().map {
                        .object([
                            "hostId": .string(Self.localHostID),
                            "threadId": .string($0),
                        ])
                    }
                ),
            ]),
        ])
        let handlers = Array(catalogHandlers.values)
        for handler in handlers {
            await handler(event)
        }
        await emitStatus(statusValue())
    }

    private func emitStatus(_ status: Value) async {
        let handlers = Array(statusHandlers.values)
        for handler in handlers {
            await handler(status)
        }
    }

    private func emitThreadObservation(
        threads: [CodexStoredThread]
    ) async throws {
        let rawThreads = try threads.map(Self.rawThreadValue)
        let observation: Value = .object([
            "hostId": .string(Self.localHostID),
            "threads": .array(rawThreads),
        ])
        let handlers = Array(threadObservationHandlers.values)
        for handler in handlers {
            await handler(observation)
        }
    }

    private func removeCatalogHandler(_ id: UUID) {
        catalogHandlers.removeValue(forKey: id)
    }

    private func removeStatusHandler(_ id: UUID) {
        statusHandlers.removeValue(forKey: id)
    }

    private func removeThreadObservationHandler(_ id: UUID) {
        threadObservationHandlers.removeValue(forKey: id)
    }

    private func nextRequestID(
        operation: String
    ) -> CodexAppServerRequestID {
        nextRequestSequence &+= 1
        return .string(
            "app-host-local-thread-catalog:"
                + "\(operation):\(nextRequestSequence)"
        )
    }

    private func bumpRevision() throws {
        guard revision < Int64.max else {
            throw Error.invalidRequest("revision")
        }
        revision += 1
    }

    private static func pageRequest(
        _ value: Value
    ) throws -> PageRequest {
        guard case let .object(fields) = value else {
            throw Error.invalidRequest("request")
        }
        let hostID = try requiredString(
            fields["hostId"],
            field: "hostId"
        )
        guard hostID == localHostID else {
            throw Error.unsupportedHostID(hostID)
        }
        guard let limitValue = integer(fields["limit"]),
              let limit = Int(exactly: limitValue),
              (1...100).contains(limit)
        else {
            throw Error.invalidRequest("limit")
        }
        let sortKeyRaw = try requiredString(
            fields["sortKey"],
            field: "sortKey"
        )
        guard let sortKey = SortKey(rawValue: sortKeyRaw) else {
            throw Error.invalidRequest("sortKey")
        }

        let filter = try normalizedFilter(fields["filter"])
        let filterFingerprint = try fingerprint(for: filter)
        let manualOrder = try manualOrder(fields["manualOrder"])
        let cursor: Cursor?
        switch fields["cursor"] {
        case nil, .null?, .undefined?:
            cursor = nil
        case let .string(encoded)?:
            let envelope = try decodeCursor(encoded)
            guard envelope.hostId == localHostID,
                  envelope.filterFingerprint == filterFingerprint,
                  envelope.sortKey == sortKey.rawValue
            else {
                throw Error.invalidCursor
            }
            cursor = Cursor(
                sortKey: sortKey,
                sourceUpdatedAt: envelope.sourceUpdatedAt,
                sourceRecencyAt: envelope.sourceRecencyAt,
                sourceCreatedAt: envelope.sourceCreatedAt,
                threadID: envelope.threadId
            )
        default:
            throw Error.invalidCursor
        }
        guard cursor == nil || manualOrder == nil else {
            throw Error.invalidRequest("manualOrder.cursor")
        }
        return PageRequest(
            limit: limit,
            sortKey: sortKey,
            cursor: cursor,
            filter: filter,
            filterFingerprint: filterFingerprint,
            manualOrder: manualOrder
        )
    }

    private static func normalizedFilter(
        _ value: Value?
    ) throws -> Filter? {
        switch value {
        case nil, .null?, .undefined?:
            return nil
        case let .object(fields)?:
            guard case let .bool(includeAll)? = fields["includeAll"]
            else {
                throw Error.invalidRequest("filter.includeAll")
            }
            let cwdValues = try normalizedStrings(
                fields["cwdValues"],
                field: "filter.cwdValues"
            )
            let cwdPrefixes = try normalizedStrings(
                fields["cwdPrefixes"],
                field: "filter.cwdPrefixes"
            ).map(normalizedPrefix)
            var collapsedPrefixes: [String] = []
            for prefix in Array(Set(cwdPrefixes)).sorted()
            where !collapsedPrefixes.contains(
                where: prefix.hasPrefix
            ) {
                collapsedPrefixes.append(prefix)
            }
            return Filter(
                includeAll: includeAll,
                cwdValues: cwdValues,
                cwdPrefixes: collapsedPrefixes,
                includeThreadIDs: try normalizedStrings(
                    fields["includeThreadIds"],
                    field: "filter.includeThreadIds"
                ),
                excludeThreadIDs: try normalizedStrings(
                    fields["excludeThreadIds"],
                    field: "filter.excludeThreadIds"
                )
            )
        default:
            throw Error.invalidRequest("filter")
        }
    }

    private static func manualOrder(
        _ value: Value?
    ) throws -> ManualOrder? {
        switch value {
        case nil, .null?, .undefined?:
            return nil
        case let .object(fields)?:
            guard case let .array(threadIDValues)? =
                    fields["threadIds"],
                  threadIDValues.allSatisfy({
                      nonemptyString($0) != nil
                  }),
                  let startValue = integer(fields["startIndex"]),
                  let startIndex = Int(exactly: startValue),
                  startIndex >= 0,
                  startIndex <= threadIDValues.count
            else {
                throw Error.invalidRequest("manualOrder")
            }
            return ManualOrder(
                threadIDs: threadIDValues.compactMap {
                    nonemptyString($0)
                },
                startIndex: startIndex
            )
        default:
            throw Error.invalidRequest("manualOrder")
        }
    }

    private static func manualPage(
        entriesByThreadID: [String: Entry],
        order: ManualOrder,
        filter: Filter?,
        limit: Int
    ) -> Value {
        var selected: [Entry] = []
        selected.reserveCapacity(limit)
        var nextManualIndex: Int?
        for index in order.startIndex..<order.threadIDs.count {
            guard let entry = entriesByThreadID[
                order.threadIDs[index]
            ],
            filter?.includes(entry) ?? true
            else {
                continue
            }
            if selected.count == limit {
                nextManualIndex = index
                break
            }
            selected.append(entry)
        }
        return .object([
            "entries": .array(selected.map(\.value)),
            "nextManualIndex": nextManualIndex
                .map { .integer(Int64($0)) } ?? .null,
            "nextCursor": .null,
        ])
    }

    private static func encodeCursor(
        _ cursor: Cursor,
        filterFingerprint: String
    ) throws -> String {
        let envelope = CursorEnvelope(
            version: 3,
            hostId: localHostID,
            filterFingerprint: filterFingerprint,
            sortKey: cursor.sortKey.rawValue,
            sourceUpdatedAt: cursor.sourceUpdatedAt,
            sourceRecencyAt: cursor.sourceRecencyAt,
            sourceCreatedAt: cursor.sourceCreatedAt,
            threadId: cursor.threadID
        )
        return base64URLEncoded(
            try JSONEncoder().encode(envelope)
        )
    }

    private static func decodeCursor(
        _ encoded: String
    ) throws -> CursorEnvelope {
        guard let data = base64URLDecoded(encoded),
              let envelope = try? JSONDecoder().decode(
                  CursorEnvelope.self,
                  from: data
              ),
              envelope.version == 3,
              !envelope.hostId.isEmpty,
              !envelope.filterFingerprint.isEmpty,
              SortKey(rawValue: envelope.sortKey) != nil,
              !envelope.threadId.isEmpty
        else {
            throw Error.invalidCursor
        }
        return envelope
    }

    private static func fingerprint(
        for filter: Filter?
    ) throws -> String {
        guard let filter else {
            return "all"
        }
        // Match the release's JSON.stringify insertion order so public cursor
        // payloads retain the confirmed desktop fingerprint contract.
        let json = """
        {"includeAll":\(filter.includeAll ? "true" : "false"),"cwdValues":\(try jsonArray(filter.cwdValues)),"cwdPrefixes":\(try jsonArray(filter.cwdPrefixes)),"includeThreadIds":\(try jsonArray(filter.includeThreadIDs)),"excludeThreadIds":\(try jsonArray(filter.excludeThreadIDs))}
        """
        let digest = SHA256.hash(data: Data(json.utf8))
        return base64URLEncoded(Data(digest))
    }

    private static func jsonArray(
        _ values: [String]
    ) throws -> String {
        let data = try JSONSerialization.data(
            withJSONObject: values,
            options: [.withoutEscapingSlashes]
        )
        guard let result = String(data: data, encoding: .utf8) else {
            throw Error.invalidRequest("filter")
        }
        return result
    }

    private static func normalizedStrings(
        _ value: Value?,
        field: String
    ) throws -> [String] {
        guard case let .array(values)? = value,
              values.allSatisfy({
                  nonemptyString($0) != nil
              })
        else {
            throw Error.invalidRequest(field)
        }
        return Array(Set(values.compactMap {
            nonemptyString($0)
        })).sorted()
    }

    private static func normalizedPrefix(
        _ value: String
    ) -> String {
        guard !value.hasSuffix("/"),
              !value.hasSuffix("\\")
        else {
            return value
        }
        return value + (value.contains("\\") ? "\\" : "/")
    }

    private static func base64URLEncoded(
        _ data: Data
    ) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func base64URLDecoded(
        _ encoded: String
    ) -> Data? {
        let allowed = CharacterSet(
            charactersIn:
                "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
                + "abcdefghijklmnopqrstuvwxyz"
                + "0123456789-_"
        )
        guard !encoded.isEmpty,
              encoded.unicodeScalars.allSatisfy({
                  allowed.contains($0)
              })
        else {
            return nil
        }
        var standard = encoded
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = standard.utf8.count % 4
        guard remainder != 1 else {
            return nil
        }
        if remainder > 0 {
            standard.append(
                String(repeating: "=", count: 4 - remainder)
            )
        }
        return Data(base64Encoded: standard)
    }

    private static func threadID(
        from locator: Value
    ) throws -> String {
        guard case let .object(fields) = locator else {
            throw Error.invalidRequest("locator")
        }
        let hostID = try requiredString(
            fields["hostId"],
            field: "hostId"
        )
        guard hostID == localHostID else {
            throw Error.unsupportedHostID(hostID)
        }
        return try requiredString(
            fields["threadId"],
            field: "threadId"
        )
    }

    /// The released mapper filters non-top-level, ephemeral, automation, exec,
    /// and object-valued sub-agent sources before constructing these fields.
    /// `CodexStoredThread` already gives finite Int64 timestamps, so desktop's
    /// `createdAt -> updatedAt` non-finite fallback is not needed on iPad.
    private static func entry(
        from thread: CodexStoredThread
    ) -> Entry? {
        guard !thread.ephemeral,
              thread.parentThreadID == nil,
              thread.threadSource != "ambient_suggestions",
              thread.threadSource != "pull_request_fix_automation"
        else {
            return nil
        }

        let source: (kind: String, detail: String?)
        switch thread.source {
        case let .named(name):
            guard name != .exec else {
                return nil
            }
            source = (name.rawValue, nil)
        case let .custom(detail):
            source = ("custom", detail)
        case .subAgent:
            return nil
        }

        return Entry(
            threadID: thread.id.rawValue,
            displayTitle: displayTitle(for: thread),
            sourceCreatedAt: thread.createdAt,
            sourceUpdatedAt: thread.updatedAt,
            sourceRecencyAt:
                thread.recencyAt ?? thread.updatedAt,
            cwd: thread.cwd,
            sourceKind: source.kind,
            sourceDetail: source.detail,
            threadSource: thread.threadSource,
            modelProvider: thread.modelProvider,
            gitBranch: thread.gitInfo?.branch
        )
    }

    /// Desktop additionally runs its private markdown-to-plain-text helper.
    /// iPad maps the same confirmed candidate order and delegation suppression
    /// onto stored strings, normalizes whitespace, and keeps the confirmed
    /// 80-character ellipsis bound.
    private static func displayTitle(
        for thread: CodexStoredThread
    ) -> String {
        let preview: String
        if let delegationInput = delegationInput(
            from: thread.preview
        ) {
            preview = delegationInput
        } else if thread.preview
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .hasPrefix("<codex_delegation>")
        {
            preview = ""
        } else {
            preview = thread.preview
        }
        for candidate in [
            thread.name ?? "",
            preview,
            thread.cwd,
            thread.id.rawValue,
        ] {
            let normalized = candidate
                .split(whereSeparator: \.isWhitespace)
                .joined(separator: " ")
            guard !normalized.isEmpty else {
                continue
            }
            guard normalized.count > 80 else {
                return normalized
            }
            let prefix = normalized.prefix(79)
            return prefix
                .trimmingCharacters(in: .whitespacesAndNewlines)
                + "…"
        }
        return thread.id.rawValue
    }

    private static func delegationInput(
        from preview: String
    ) -> String? {
        let trimmed = preview.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard trimmed.hasPrefix("<codex_delegation>"),
              trimmed.hasSuffix("</codex_delegation>"),
              delegationField(
                  "source_thread_id",
                  in: trimmed
              ) != nil,
              let input = delegationField("input", in: trimmed)
        else {
            return nil
        }
        return input
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    private static func delegationField(
        _ field: String,
        in value: String
    ) -> String? {
        guard let expression = try? NSRegularExpression(
            pattern:
                "<\(field)>\\s*([\\s\\S]*?)\\s*</\(field)>",
            options: [.caseInsensitive]
        ) else {
            return nil
        }
        let range = NSRange(
            value.startIndex..<value.endIndex,
            in: value
        )
        guard let match = expression.firstMatch(
            in: value,
            range: range
        ),
        let captureRange = Range(match.range(at: 1), in: value)
        else {
            return nil
        }
        return String(value[captureRange])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isOrderedBefore(
        _ lhs: Entry,
        _ rhs: Entry,
        sortKey: SortKey
    ) -> Bool {
        switch sortKey {
        case .createdAt:
            if lhs.sourceCreatedAt != rhs.sourceCreatedAt {
                return lhs.sourceCreatedAt > rhs.sourceCreatedAt
            }
            if lhs.sourceUpdatedAt != rhs.sourceUpdatedAt {
                return lhs.sourceUpdatedAt > rhs.sourceUpdatedAt
            }
        case .updatedAt:
            if lhs.sourceRecencyAt != rhs.sourceRecencyAt {
                return lhs.sourceRecencyAt > rhs.sourceRecencyAt
            }
            if lhs.sourceCreatedAt != rhs.sourceCreatedAt {
                return lhs.sourceCreatedAt > rhs.sourceCreatedAt
            }
        }
        return lhs.threadID < rhs.threadID
    }

    private static func isOrderedAfter(
        _ entry: Entry,
        cursor: Cursor,
        sortKey: SortKey
    ) -> Bool {
        switch sortKey {
        case .createdAt:
            if entry.sourceCreatedAt != cursor.sourceCreatedAt {
                return entry.sourceCreatedAt
                    < cursor.sourceCreatedAt
            }
            if entry.sourceUpdatedAt != cursor.sourceUpdatedAt {
                return entry.sourceUpdatedAt
                    < cursor.sourceUpdatedAt
            }
        case .updatedAt:
            if entry.sourceRecencyAt != cursor.sourceRecencyAt {
                return entry.sourceRecencyAt
                    < cursor.sourceRecencyAt
            }
            if entry.sourceCreatedAt != cursor.sourceCreatedAt {
                return entry.sourceCreatedAt
                    < cursor.sourceCreatedAt
            }
        }
        return entry.threadID > cursor.threadID
    }

    private static func rawThreadValue(
        _ thread: CodexStoredThread
    ) throws -> Value {
        let data = try JSONEncoder().encode(thread)
        let json = try JSONDecoder().decode(
            CodexJSONValue.self,
            from: data
        )
        return rpcValue(from: json)
    }

    private static func rpcValue(
        from value: CodexJSONValue
    ) -> Value {
        switch value {
        case .null:
            return .null
        case let .bool(value):
            return .bool(value)
        case let .integer(value):
            return .integer(value)
        case let .number(value):
            return .number(value)
        case let .string(value):
            return .string(value)
        case let .array(values):
            return .array(values.map(rpcValue))
        case let .object(values):
            return .object(
                values.mapValues(rpcValue)
            )
        }
    }

    private static func integer(_ value: Value?) -> Int64? {
        switch value {
        case let .integer(raw):
            return raw
        case let .number(raw)
            where raw.isFinite
                && raw.rounded(.towardZero) == raw
                && raw >= Double(Int64.min)
                && raw <= Double(Int64.max):
            return Int64(raw)
        default:
            return nil
        }
    }

    private static func requiredString(
        _ value: Value?,
        field: String
    ) throws -> String {
        guard let value = nonemptyString(value) else {
            throw Error.invalidRequest(field)
        }
        return value
    }

    private static func nonemptyString(
        _ value: Value?
    ) -> String? {
        guard case let .string(raw)? = value,
              !raw.isEmpty
        else {
            return nil
        }
        return raw
    }
}
