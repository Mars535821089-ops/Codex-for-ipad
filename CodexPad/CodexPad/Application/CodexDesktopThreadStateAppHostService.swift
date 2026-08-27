import Foundation

/// Persistent iPad implementation of the desktop pinned-thread and turn-summary
/// AppHost contracts. State is scoped to the app's Codex home and written
/// atomically so an interrupted launch cannot leave a partial document.
public actor CodexDesktopThreadStateAppHostService {
    public typealias Value = CodexDesktopAppHostRPC.Value
    public typealias EventHandler =
        @Sendable (String, String, [Value]?) async -> Void

    public enum Error: Swift.Error, Equatable, Sendable {
        case invalidArguments
        case unsupportedMethod(service: String, method: String)
    }

    private struct Summary: Codable, Equatable, Sendable {
        let hostID: String
        let threadID: String
        let summary: String
        let compactSummary: String?
        let compactSummaryTurnKey: String?
        let revision: Int64
    }

    private struct Document: Codable, Sendable {
        var pinnedThreadIDs: [String] = []
        var summaries: [String: Summary] = [:]
    }

    private let storeURL: URL
    private let principalIdentity: String
    private let eventHandler: EventHandler
    private let summaryDiagnostic: CodexDesktopSummaryDiagnosticSink
    private var document: Document
    /// Mirrors the desktop service's in-memory visibility and tombstone maps.
    /// Persisted summaries remain in `document`; these maps prevent stale
    /// writes from reappearing after deletion or invalidation.
    private var visibleSummaries: [String: Summary] = [:]
    private var deletedRevisions: [String: Int64] = [:]
    private var isDisposed = false

    public init(
        codexHome: URL,
        principalIdentity: String? = nil,
        eventHandler: EventHandler? = nil,
        summaryDiagnostic: CodexDesktopSummaryDiagnosticSink? = nil
    ) {
        storeURL = codexHome.appendingPathComponent(
            "thread-state.json"
        )
        let identityURL = codexHome.appendingPathComponent(
            "thread-state-principal"
        )
        if let principalIdentity {
            self.principalIdentity = principalIdentity
        } else if let stored = try? String(
            contentsOf: identityURL,
            encoding: .utf8
        ), !stored.isEmpty {
            self.principalIdentity = stored
        } else {
            let generated = UUID().uuidString.lowercased()
            self.principalIdentity = generated
            try? FileManager.default.createDirectory(
                at: codexHome,
                withIntermediateDirectories: true
            )
            try? generated.write(
                to: identityURL,
                atomically: true,
                encoding: .utf8
            )
        }
        self.eventHandler = eventHandler ?? { _, _, _ in }
        self.summaryDiagnostic = summaryDiagnostic ?? { key, value in
            UserDefaults.standard.set(value, forKey: key)
        }
        document = (try? Data(contentsOf: storeURL))
            .flatMap { try? JSONDecoder().decode(Document.self, from: $0) }
            ?? Document()
    }

    public func invoke(
        service: String,
        method: String,
        arguments: [Value]?
    ) async throws -> Value {
        guard !isDisposed else {
            throw Error.unsupportedMethod(service: service, method: method)
        }
        switch (service, method) {
        case ("pinnedThreads", "list"):
            return .object([
                "threadIds": .array(
                    document.pinnedThreadIDs.map(Value.string)
                )
            ])
        case ("pinnedThreads", "set"):
            let fields = try object(arguments?.first)
            guard let threadID = nonempty(fields["threadId"]),
                  case let .bool(pinned)? = fields["pinned"]
            else { throw Error.invalidArguments }
            var pins = document.pinnedThreadIDs.filter { $0 != threadID }
            if pinned {
                if let before = string(fields["beforeThreadId"]),
                   let index = pins.firstIndex(of: before)
                {
                    pins.insert(threadID, at: index)
                } else {
                    pins.append(threadID)
                }
            }
            let changed = pins != document.pinnedThreadIDs
            document.pinnedThreadIDs = pins
            if changed { try persist() }
            await eventHandler(service, method, arguments)
            return .object(["success": .bool(changed)])
        case ("pinnedThreads", "setOrder"):
            let fields = try object(arguments?.first)
            guard case let .array(values)? = fields["threadIds"] else {
                throw Error.invalidArguments
            }
            let pins = values.compactMap(string)
            guard pins.count == values.count else {
                throw Error.invalidArguments
            }
            let deduplicated = pins.reduce(into: [String]()) {
                if !$0.contains($1) { $0.append($1) }
            }
            let changed = deduplicated != document.pinnedThreadIDs
            document.pinnedThreadIDs = deduplicated
            if changed { try persist() }
            await eventHandler(service, method, arguments)
            return .object(["success": .bool(changed)])

        case ("threadTurnSummaries", "getPrincipalIdentity"):
            _ = try object(arguments?.first)
            await summaryDiagnostic(
                "codex.desktop.last-summary-principal-diagnostic",
                "called=true result=succeeded"
            )
            return .string(principalIdentity)
        case ("threadTurnSummaries", "readMany"):
            let fields = try object(arguments?.first)
            guard let hostID = nonempty(fields["hostId"]),
                  case let .array(threadValues)? = fields["threadIds"]
            else { throw Error.invalidArguments }
            return .array(threadValues.compactMap { value in
                guard let threadID = string(value),
                      let summary = document.summaries[key(hostID, threadID)],
                      (deletedRevisions[key(hostID, "\u{0}" + threadID)] ?? -1) < summary.revision
                else { return nil }
                visibleSummaries[key(hostID, threadID)] = summary
                return summaryValue(summary)
            })
        case ("threadTurnSummaries", "setSummary"):
            let fields = try object(arguments?.first)
            let diagnosticKey =
                "codex.desktop.last-summary-persistence-diagnostic"
            let rawRevision = integer(fields["revision"])
            let rawSummaryLength = string(fields["summary"])?.count ?? 0
            let rawCompactLength = string(fields["compactSummary"])?.count ?? 0
            let diagnosticPrefix =
                "called=true revision=\(rawRevision.map(String.init) ?? "invalid") "
                + "summaryLength=\(rawSummaryLength) "
                + "compactLength=\(rawCompactLength)"
            await summaryDiagnostic(
                diagnosticKey,
                diagnosticPrefix + " result=pending"
            )
            guard let hostID = nonempty(fields["hostId"]),
                  let threadID = nonempty(fields["threadId"]),
                  let rawSummary = string(fields["summary"]),
                  let revision = integer(fields["revision"]), revision >= 0,
                  string(fields["principalIdentity"]) == principalIdentity
            else {
                await summaryDiagnostic(
                    diagnosticKey,
                    diagnosticPrefix + " result=rejected"
                )
                return .bool(false)
            }
            let summary = normalized(rawSummary, limit: 280)
            let compact = string(fields["compactSummary"])
                .map { normalized($0, limit: 60) }
            let turnKey = string(fields["compactSummaryTurnKey"])
            guard !summary.isEmpty,
                  compact == nil || !(compact?.isEmpty ?? true),
                  (compact == nil) == (turnKey == nil)
            else {
                await summaryDiagnostic(
                    diagnosticKey,
                    diagnosticPrefix + " result=rejected"
                )
                return .bool(false)
            }
            let storageKey = key(hostID, threadID)
            let tombstoneKey = key(principalIdentity, key(hostID, threadID))
            if (deletedRevisions[tombstoneKey] ?? -1) >= revision {
                await summaryDiagnostic(
                    diagnosticKey,
                    diagnosticPrefix + " result=rejected"
                )
                return .bool(false)
            }
            if let old = document.summaries[storageKey],
               old.revision >= revision
            {
                await summaryDiagnostic(
                    diagnosticKey,
                    diagnosticPrefix + " result=rejected"
                )
                return .bool(false)
            }
            let item = Summary(
                hostID: hostID,
                threadID: threadID,
                summary: summary,
                compactSummary: compact,
                compactSummaryTurnKey: turnKey,
                revision: revision
            )
            document.summaries[storageKey] = item
            deletedRevisions.removeValue(forKey: tombstoneKey)
            visibleSummaries[storageKey] = item
            do {
                try persist()
            } catch {
                await summaryDiagnostic(
                    diagnosticKey,
                    diagnosticPrefix + " result=failed"
                )
                throw error
            }
            await eventHandler(service, method, [summaryValue(item)])
            await summaryDiagnostic(
                diagnosticKey,
                diagnosticPrefix + " result=succeeded"
            )
            return .bool(true)
        case ("threadTurnSummaries", "subscribe"):
            await eventHandler(service, method, arguments)
            return .rpcObject([:])
        case ("threadTurnSummaries", "delete"):
            let fields = try object(arguments?.first)
            guard let hostID = nonempty(fields["hostId"]),
                  let threadID = nonempty(fields["threadId"])
            else { throw Error.invalidArguments }
            let storageKey = key(hostID, threadID)
            let oldRevision = document.summaries[storageKey]?.revision ?? -1
            document.summaries.removeValue(forKey: storageKey)
            visibleSummaries.removeValue(forKey: storageKey)
            let tombstoneKey = key(principalIdentity, storageKey)
            deletedRevisions[tombstoneKey] = max(
                deletedRevisions[tombstoneKey] ?? -1,
                oldRevision + 1
            )
            try persist()
            await eventHandler(service, method, arguments)
            return .undefined
        case ("threadTurnSummaries", "invalidateSummaries"):
            let fields = try object(arguments?.first ?? .object([:]))
            let hostFilter = string(fields["hostId"])
            await invalidateSummaries { summary in
                hostFilter == nil || summary.hostID == hostFilter
            }
            return .undefined
        case ("threadTurnSummaries", "dispose"):
            dispose()
            return .undefined
        default:
            throw Error.unsupportedMethod(service: service, method: method)
        }
    }

    /// Invalidates the currently visible summaries without deleting persisted
    /// data. This matches desktop host/principal change behavior and publishes
    /// tombstone revisions so a late setSummary cannot resurrect stale data.
    public func invalidateSummaries(
        where predicate: (SummarySnapshot) -> Bool
    ) async {
        guard !isDisposed else { return }
        for (storageKey, summary) in visibleSummaries {
            let snapshot = SummarySnapshot(
                hostID: summary.hostID,
                threadID: summary.threadID,
                revision: summary.revision
            )
            guard predicate(snapshot) else { continue }
            visibleSummaries.removeValue(forKey: storageKey)
            let tombstoneKey = key(principalIdentity, storageKey)
            let nextRevision = max(
                summary.revision + 1,
                deletedRevisions[tombstoneKey] ?? -1
            )
            deletedRevisions[tombstoneKey] = nextRevision
            await eventHandler(
                "threadTurnSummaries",
                "invalidateSummaries",
                [.object([
                    "hostId": .string(summary.hostID),
                    "threadId": .string(summary.threadID),
                    "summary": .null,
                    "revision": .integer(nextRevision),
                ])]
            )
        }
        try? persist()
    }

    public struct SummarySnapshot: Equatable, Sendable {
        public let hostID: String
        public let threadID: String
        public let revision: Int64

        public init(hostID: String, threadID: String, revision: Int64) {
            self.hostID = hostID
            self.threadID = threadID
            self.revision = revision
        }
    }

    /// Stops listeners and in-memory caches. Persisted state is intentionally
    /// retained so a subsequent service instance can restore it.
    public func dispose() {
        guard !isDisposed else { return }
        isDisposed = true
        visibleSummaries.removeAll()
        deletedRevisions.removeAll()
    }

    private func persist() throws {
        try FileManager.default.createDirectory(
            at: storeURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try JSONEncoder().encode(document).write(
            to: storeURL,
            options: .atomic
        )
    }

    private func summaryValue(_ value: Summary) -> Value {
        var fields: [String: Value] = [
            "hostId": .string(value.hostID),
            "threadId": .string(value.threadID),
            "summary": .string(value.summary),
            "revision": .integer(value.revision),
        ]
        if let compact = value.compactSummary,
           let turnKey = value.compactSummaryTurnKey
        {
            fields["compactSummary"] = .string(compact)
            fields["compactSummaryTurnKey"] = .string(turnKey)
        }
        return .object(fields)
    }

    private func key(_ hostID: String, _ threadID: String) -> String {
        hostID + "\u{0}" + threadID
    }

    private func object(_ value: Value?) throws -> [String: Value] {
        guard case let .object(fields)? = value else {
            throw Error.invalidArguments
        }
        return fields
    }

    private func string(_ value: Value?) -> String? {
        guard case let .string(value)? = value else { return nil }
        return value
    }

    private func nonempty(_ value: Value?) -> String? {
        guard let value = string(value), !value.isEmpty else { return nil }
        return value
    }

    private func integer(_ value: Value?) -> Int64? {
        switch value {
        case let .integer(value): return value
        case let .number(value) where value.rounded() == value:
            return Int64(value)
        default: return nil
        }
    }

    private func normalized(_ value: String, limit: Int) -> String {
        String(
            value.split(whereSeparator: { $0.isWhitespace })
                .joined(separator: " ").prefix(limit)
        ).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
