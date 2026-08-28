import CodexPadApplication
import CodexPadDomain
import CodexPadProtocolBridge
import Foundation
import Testing

private typealias SessionCatalogValue = CodexDesktopAppHostRPC.Value

@MainActor
@Test
func desktopLocalThreadCatalogSessionBackendPaginatesAndMapsRealThreads()
    async throws
{
    let transport = LocalThreadCatalogSessionTransport()
    let named = localCatalogStoredThread(
        id: "named",
        name: "  Named\n task  ",
        preview: "ignored preview",
        source: .custom("fixture"),
        createdAt: 100,
        updatedAt: 900,
        recencyAt: 1_000,
        gitBranch: "main"
    )
    let tieOlder = localCatalogStoredThread(
        id: "tie-older",
        name: nil,
        preview: "Older tie",
        source: .named(.vscode),
        createdAt: 300,
        updatedAt: 800,
        recencyAt: 900
    )
    let tieNewer = localCatalogStoredThread(
        id: "tie-newer",
        name: nil,
        preview: "Newer tie",
        source: .named(.appServer),
        createdAt: 500,
        updatedAt: 700,
        recencyAt: 900
    )
    let excludedExec = localCatalogStoredThread(
        id: "excluded-exec",
        source: .named(.exec),
        createdAt: 600,
        updatedAt: 1_100
    )
    let excludedEphemeral = localCatalogStoredThread(
        id: "excluded-ephemeral",
        ephemeral: true,
        createdAt: 700,
        updatedAt: 1_200
    )
    transport.replies = [
        .list(
            .init(
                data: [named, tieOlder, excludedExec],
                nextCursor: "server-page-2",
                backwardsCursor: nil
            )
        ),
        .list(
            .init(
                data: [tieNewer, excludedEphemeral],
                nextCursor: nil,
                backwardsCursor: nil
            )
        ),
    ]
    let store = CodexSessionStore(transport: transport)
    let backend = CodexDesktopLocalThreadCatalogSessionBackend(
        sessionStore: store,
        syncPageLimit: 3
    )

    try await backend.setPopulationEnabled(true, startup: "manual")
    try await backend.requestSync(hostIDs: nil, priority: "immediate")

    #expect(transport.requested.count == 2)
    guard case let .list(_, firstParams) = transport.requested[0],
          case let .list(_, secondParams) = transport.requested[1]
    else {
        Issue.record("Expected two real thread/list requests")
        return
    }
    #expect(firstParams.cursor == .omitted)
    #expect(secondParams.cursor == .value("server-page-2"))
    #expect(firstParams.limit == .value(3))
    #expect(firstParams.sortKey == .value(.updatedAt))
    #expect(firstParams.sortDirection == .value(.descending))
    #expect(firstParams.sourceKinds == .value([]))
    #expect(firstParams.archived == .value(false))
    #expect(firstParams.parentThreadID == .null)
    #expect(firstParams.useStateDbOnly == true)

    let firstPage = try await backend.readPage(
        .object([
            "hostId": .string("local"),
            "limit": .integer(2),
            "sortKey": .string("updated_at"),
        ])
    )
    guard case let .object(firstFields) = firstPage,
          case let .array(firstEntries)? = firstFields["entries"],
          case let .string(cursor)? = firstFields["nextCursor"],
          let cursorPayload = sessionCatalogCursorPayload(cursor)
    else {
        Issue.record("Expected a catalog page and opaque v3 cursor")
        return
    }
    #expect(firstEntries.map(sessionCatalogThreadID) == [
        "named",
        "tie-newer",
    ])
    #expect(cursorPayload.version == 3)
    #expect(cursorPayload.hostId == "local")
    #expect(cursorPayload.filterFingerprint == "all")
    #expect(cursorPayload.sortKey == "updated_at")
    #expect(cursorPayload.sourceRecencyAt == 900)
    #expect(cursorPayload.sourceCreatedAt == 500)
    #expect(cursorPayload.threadId == "tie-newer")

    let secondPage = try await backend.readPage(
        .object([
            "hostId": .string("local"),
            "limit": .integer(2),
            "sortKey": .string("updated_at"),
            "cursor": .string(cursor),
        ])
    )
    guard case let .object(secondFields) = secondPage,
          case let .array(secondEntries)? = secondFields["entries"]
    else {
        Issue.record("Expected the second catalog page")
        return
    }
    #expect(secondEntries.map(sessionCatalogThreadID) == ["tie-older"])
    #expect(secondFields["nextCursor"] == .null)

    guard case let .object(namedFields) = firstEntries[0] else {
        Issue.record("Expected a mapped catalog entry")
        return
    }
    #expect(namedFields == [
        "hostId": .string("local"),
        "threadId": .string("named"),
        "displayTitle": .string("Named task"),
        "sourceCreatedAt": .integer(100),
        "sourceUpdatedAt": .integer(900),
        "sourceRecencyAt": .integer(1_000),
        "cwd": .string("/workspace"),
        "sourceKind": .string("custom"),
        "sourceDetail": .string("fixture"),
        "threadSource": .null,
        "modelProvider": .string("openai"),
        "gitBranch": .string("main"),
    ])

    let createdPage = try await backend.readPage(
        .object([
            "hostId": .string("local"),
            "limit": .integer(10),
            "sortKey": .string("created_at"),
        ])
    )
    guard case let .object(createdFields) = createdPage,
          case let .array(createdEntries)? = createdFields["entries"]
    else {
        Issue.record("Expected a created_at page")
        return
    }
    #expect(createdEntries.map(sessionCatalogThreadID) == [
        "tie-newer",
        "tie-older",
        "named",
    ])
}

@MainActor
@Test
func desktopLocalThreadCatalogSessionBackendMatchesPublicFilterAndManualPageContract()
    async throws
{
    let transport = LocalThreadCatalogSessionTransport()
    let exact = localCatalogStoredThread(
        id: "exact",
        cwd: "/project",
        createdAt: 10,
        updatedAt: 100
    )
    let prefixed = localCatalogStoredThread(
        id: "prefixed",
        cwd: "/project/sub",
        createdAt: 20,
        updatedAt: 90
    )
    let included = localCatalogStoredThread(
        id: "included",
        cwd: "/elsewhere",
        createdAt: 30,
        updatedAt: 80
    )
    let excluded = localCatalogStoredThread(
        id: "excluded",
        cwd: "/project/excluded",
        createdAt: 40,
        updatedAt: 110
    )
    transport.replies = [
        .list(.init(
            data: [exact, prefixed, included, excluded],
            nextCursor: nil,
            backwardsCursor: nil
        )),
    ]
    let backend = CodexDesktopLocalThreadCatalogSessionBackend(
        sessionStore: CodexSessionStore(transport: transport)
    )
    try await backend.setPopulationEnabled(true, startup: "manual")
    try await backend.requestSync(hostIDs: nil, priority: "immediate")

    let filter: SessionCatalogValue = .object([
        "includeAll": .bool(false),
        "cwdValues": .array([.string("/project")]),
        "cwdPrefixes": .array([
            .string("/project/sub"),
            .string("/project"),
            .string("/project"),
        ]),
        "includeThreadIds": .array([
            .string("included"),
            .string("included"),
        ]),
        "excludeThreadIds": .array([
            .string("excluded"),
        ]),
    ])
    let firstPage = try await backend.readPage(.object([
        "hostId": .string("local"),
        "limit": .integer(2),
        "sortKey": .string("updated_at"),
        "filter": filter,
    ]))
    guard case let .object(firstFields) = firstPage,
          case let .array(firstEntries)? = firstFields["entries"],
          case let .string(cursor)? = firstFields["nextCursor"],
          let payload = sessionCatalogCursorPayload(cursor)
    else {
        Issue.record("Expected filtered page with opaque cursor")
        return
    }
    #expect(firstEntries.map(sessionCatalogThreadID) == [
        "exact",
        "prefixed",
    ])
    #expect(
        payload.filterFingerprint
            == "vhYiPgefbzkEVKKFwGAk5rTbVXyL7_g0OH37ISyOqdY"
    )

    let equivalentFilter: SessionCatalogValue = .object([
        "includeAll": .bool(false),
        "cwdValues": .array([.string("/project")]),
        "cwdPrefixes": .array([
            .string("/project/"),
            .string("/project/sub/"),
        ]),
        "includeThreadIds": .array([.string("included")]),
        "excludeThreadIds": .array([.string("excluded")]),
    ])
    let secondPage = try await backend.readPage(.object([
        "hostId": .string("local"),
        "limit": .integer(2),
        "sortKey": .string("updated_at"),
        "filter": equivalentFilter,
        "cursor": .string(cursor),
    ]))
    guard case let .object(secondFields) = secondPage,
          case let .array(secondEntries)? = secondFields["entries"]
    else {
        Issue.record("Expected second filtered page")
        return
    }
    #expect(secondEntries.map(sessionCatalogThreadID) == ["included"])
    #expect(secondFields["nextCursor"] == .null)

    let manualPage = try await backend.readPage(.object([
        "hostId": .string("local"),
        "limit": .integer(1),
        "sortKey": .string("updated_at"),
        "filter": filter,
        "manualOrder": .object([
            "threadIds": .array([
                .string("missing"),
                .string("excluded"),
                .string("included"),
                .string("exact"),
            ]),
            "startIndex": .integer(0),
        ]),
    ]))
    #expect(manualPage == .object([
        "entries": .array([
            sessionCatalogExpectedEntry(included),
        ]),
        "nextManualIndex": .integer(3),
        "nextCursor": .null,
    ]))

    await #expect(
        throws:
            CodexDesktopLocalThreadCatalogSessionBackend
                .Error.invalidCursor
    ) {
        _ = try await backend.readPage(.object([
            "hostId": .string("local"),
            "limit": .integer(2),
            "sortKey": .string("updated_at"),
            "filter": .object([
                "includeAll": .bool(true),
                "cwdValues": .array([]),
                "cwdPrefixes": .array([]),
                "includeThreadIds": .array([]),
                "excludeThreadIds": .array([]),
            ]),
            "cursor": .string(cursor),
        ]))
    }
    await #expect(
        throws:
            CodexDesktopLocalThreadCatalogSessionBackend
                .Error.invalidRequest("limit")
    ) {
        _ = try await backend.readPage(.object([
            "hostId": .string("local"),
            "limit": .integer(101),
            "sortKey": .string("updated_at"),
        ]))
    }
}

@MainActor
@Test
func desktopLocalThreadCatalogSessionBackendUsesThreadReadForCacheMiss()
    async throws
{
    let transport = LocalThreadCatalogSessionTransport()
    let thread = localCatalogStoredThread(
        id: "read-through",
        name: nil,
        preview: """
        <codex_delegation>
          <source_thread_id>source-thread</source_thread_id>
          <input>  Delegated &amp; task  </input>
        </codex_delegation>
        """,
        source: .named(.cli),
        createdAt: 40,
        updatedAt: 50
    )
    transport.replies = [.read(.init(thread: thread))]
    let backend = CodexDesktopLocalThreadCatalogSessionBackend(
        sessionStore: CodexSessionStore(transport: transport)
    )
    let locator: SessionCatalogValue = .object([
        "hostId": .string("local"),
        "threadId": .string("read-through"),
    ])

    let entries = try await backend.readEntries([locator])

    #expect(entries.map(sessionCatalogThreadID) == ["read-through"])
    guard case let .object(entryFields) = entries.first else {
        Issue.record("Expected mapped read-through entry")
        return
    }
    #expect(
        entryFields["displayTitle"]
            == .string("Delegated & task")
    )
    #expect(transport.requested.count == 1)
    guard case let .read(_, params) = transport.requested[0] else {
        Issue.record("Expected a real thread/read request")
        return
    }
    #expect(params == .init(
        threadID: .init("read-through"),
        includeTurns: false
    ))
    #expect(
        try await backend.readEntries([locator])
            .map(sessionCatalogThreadID) == ["read-through"]
    )
    #expect(transport.requested.count == 1)
    guard case let .object(snapshot) = try await backend.readSnapshot() else {
        Issue.record("Expected a snapshot")
        return
    }
    #expect(snapshot["revision"] == .integer(1))
    #expect(snapshot["hosts"] == .array([
        .object([
            "hostId": .string("local"),
            "isComplete": .bool(false),
        ]),
    ]))
}

@MainActor
@Test
func desktopLocalThreadCatalogSessionBackendPublishesMultipageDeltas()
    async throws
{
    let transport = LocalThreadCatalogSessionTransport()
    let first = localCatalogStoredThread(
        id: "first",
        createdAt: 10,
        updatedAt: 20
    )
    let second = localCatalogStoredThread(
        id: "second",
        createdAt: 30,
        updatedAt: 40
    )
    var updatedSecond = second
    updatedSecond.name = "Updated second"
    updatedSecond.updatedAt = 50
    transport.replies = [
        .list(.init(
            data: [first],
            nextCursor: "next",
            backwardsCursor: nil
        )),
        .list(.init(
            data: [second],
            nextCursor: nil,
            backwardsCursor: nil
        )),
        .list(.init(
            data: [updatedSecond],
            nextCursor: nil,
            backwardsCursor: nil
        )),
    ]
    let backend = CodexDesktopLocalThreadCatalogSessionBackend(
        sessionStore: CodexSessionStore(transport: transport),
        syncPageLimit: 1
    )
    let catalogEvents = SessionCatalogEventRecorder()
    let statusEvents = SessionCatalogEventRecorder()
    let observations = SessionCatalogEventRecorder()
    let catalogToken = await backend.subscribeCatalogEvents {
        await catalogEvents.record($0)
    }
    let statusToken = await backend.subscribeStatusEvents {
        await statusEvents.record($0)
    }
    let observationToken =
        await backend.subscribeThreadObservationEvents {
            await observations.record($0)
        }

    try await backend.setPopulationEnabled(true, startup: "manual")
    try await backend.requestSync(hostIDs: ["local"], priority: "immediate")

    guard case let .object(firstSnapshot) =
        try await backend.readSnapshot()
    else {
        Issue.record("Expected first snapshot")
        return
    }
    #expect(firstSnapshot["revision"] == .integer(1))
    #expect(firstSnapshot["isComplete"] == .bool(true))
    #expect(await observations.values.count == 2)
    #expect(await catalogEvents.values == [
        .object([
            "type": .string("delta"),
            "delta": .object([
                "revision": .integer(1),
                "changedHosts": .array([
                    .object([
                        "hostId": .string("local"),
                        "isComplete": .bool(true),
                    ]),
                ]),
                "removedHostIds": .array([]),
                "changedEntries": .array([
                    sessionCatalogExpectedEntry(second),
                    sessionCatalogExpectedEntry(first),
                ]),
                "removedEntries": .array([]),
            ]),
        ]),
    ])

    try await backend.requestSync(hostIDs: ["local"], priority: "immediate")

    guard case let .object(secondSnapshot) =
        try await backend.readSnapshot()
    else {
        Issue.record("Expected second snapshot")
        return
    }
    #expect(secondSnapshot["revision"] == .integer(2))
    #expect(await catalogEvents.values.last == .object([
        "type": .string("delta"),
        "delta": .object([
            "revision": .integer(2),
            "changedHosts": .array([
                .object([
                    "hostId": .string("local"),
                    "isComplete": .bool(true),
                ]),
            ]),
            "removedHostIds": .array([]),
            "changedEntries": .array([
                sessionCatalogExpectedEntry(updatedSecond),
            ]),
            "removedEntries": .array([
                .object([
                    "hostId": .string("local"),
                    "threadId": .string("first"),
                ]),
            ]),
        ]),
    ]))
    #expect(
        await statusEvents.values.last == .object([
            "revision": .integer(2),
            "populationEnabled": .bool(true),
            "hosts": .array([
                .object([
                    "hostId": .string("local"),
                    "isComplete": .bool(true),
                    "revision": .integer(2),
                ]),
            ]),
        ])
    )

    await catalogToken.cancel()
    await statusToken.cancel()
    await observationToken.cancel()
}

@MainActor
@Test
func desktopLocalThreadCatalogRemoveMissingOnlyChangesCatalogCache()
    async throws
{
    let transport = LocalThreadCatalogSessionTransport()
    let thread = localCatalogStoredThread(
        id: "missing",
        createdAt: 10,
        updatedAt: 20
    )
    transport.replies = [
        .list(.init(
            data: [thread],
            nextCursor: nil,
            backwardsCursor: nil
        )),
    ]
    let backend = CodexDesktopLocalThreadCatalogSessionBackend(
        sessionStore: CodexSessionStore(transport: transport)
    )
    let locator: SessionCatalogValue = .object([
        "hostId": .string("local"),
        "threadId": .string("missing"),
    ])
    try await backend.setPopulationEnabled(true, startup: "manual")
    try await backend.requestSync(hostIDs: nil, priority: "immediate")
    let requestCount = transport.requested.count

    #expect(try await backend.removeMissingEntry(locator))
    #expect(transport.requested.count == requestCount)
    #expect(try await backend.readPage(.object([
        "hostId": .string("local"),
        "limit": .integer(10),
        "sortKey": .string("updated_at"),
    ])) == .object([
        "entries": .array([]),
        "nextCursor": .null,
    ]))
    guard case let .object(snapshot) = try await backend.readSnapshot() else {
        Issue.record("Expected a snapshot")
        return
    }
    #expect(snapshot["revision"] == .integer(2))
}

@MainActor
@Test
func desktopLocalThreadCatalogSessionBackendRunsStartupPopulationLifecycle()
    async throws
{
    let transport = LocalThreadCatalogSessionTransport()
    transport.replies = [
        .list(.init(
            data: [],
            nextCursor: nil,
            backwardsCursor: nil
        )),
        .list(.init(
            data: [],
            nextCursor: nil,
            backwardsCursor: nil
        )),
    ]
    let backend = CodexDesktopLocalThreadCatalogSessionBackend(
        sessionStore: CodexSessionStore(transport: transport)
    )

    try await backend.requestStartupSync()
    #expect(transport.requested.isEmpty)

    try await backend.setPopulationEnabled(true, startup: "idle")
    #expect(transport.requested.count == 1)
    guard case let .object(firstStatus) =
        try await backend.readStatus()
    else {
        Issue.record("Expected status after startup population")
        return
    }
    #expect(firstStatus["revision"] == .integer(1))
    #expect(firstStatus["populationEnabled"] == .bool(true))
    #expect(firstStatus["hosts"] == .array([
        .object([
            "hostId": .string("local"),
            "isComplete": .bool(true),
            "revision": .integer(1),
        ]),
    ]))

    try await backend.requestStartupSync()
    #expect(transport.requested.count == 2)
    guard case let .object(unchangedStatus) =
        try await backend.readStatus()
    else {
        Issue.record("Expected unchanged status")
        return
    }
    #expect(unchangedStatus["revision"] == .integer(1))

    try await backend.setPopulationEnabled(false, startup: "manual")
    try await backend.requestSync(
        hostIDs: ["local"],
        priority: "immediate"
    )
    #expect(transport.requested.count == 2)
    guard case let .object(disabledStatus) =
        try await backend.readStatus()
    else {
        Issue.record("Expected disabled status")
        return
    }
    #expect(disabledStatus["revision"] == .integer(1))
    #expect(disabledStatus["populationEnabled"] == .bool(false))
}

@MainActor
@Test
func desktopLocalThreadCatalogStartupPurgesPersistedArchivedRendererEntries()
    async throws
{
    let archivedThreadID = UUID(
        uuidString: "01A046EB-6B60-7E23-B31F-9931CE222197"
    )!
    let transport = LocalThreadCatalogSessionTransport()
    transport.replies = [
        .list(.init(
            data: [],
            nextCursor: nil,
            backwardsCursor: nil
        )),
        .list(.init(
            data: [],
            nextCursor: nil,
            backwardsCursor: nil
        )),
    ]
    let store = CodexSessionStore(
        state: CodexSessionState(
            archivedThreadIDs: [archivedThreadID]
        ),
        transport: transport
    )
    let backend = CodexDesktopLocalThreadCatalogSessionBackend(
        sessionStore: store
    )
    let catalogEvents = SessionCatalogEventRecorder()
    let token = await backend.subscribeCatalogEvents {
        await catalogEvents.record($0)
    }

    try await backend.setPopulationEnabled(true, startup: "manual")
    try await backend.requestSync(
        hostIDs: ["local"],
        priority: "immediate"
    )
    #expect(await catalogEvents.values == [
        .object([
            "type": .string("delta"),
            "delta": .object([
                "revision": .integer(1),
                "changedHosts": .array([
                    .object([
                        "hostId": .string("local"),
                        "isComplete": .bool(true),
                    ]),
                ]),
                "removedHostIds": .array([]),
                "changedEntries": .array([]),
                "removedEntries": .array([
                    .object([
                        "hostId": .string("local"),
                        "threadId": .string(
                            archivedThreadID.uuidString.lowercased()
                        ),
                    ]),
                ]),
            ]),
        ]),
    ])

    try await backend.requestSync(
        hostIDs: ["local"],
        priority: "immediate"
    )
    #expect(await catalogEvents.values.count == 1)

    await token.cancel()
}

@MainActor
private final class LocalThreadCatalogSessionTransport:
    CodexCoreTransport
{
    enum Reply {
        case list(CodexThreadPage)
        case read(CodexThreadReadResult)
    }

    enum Failure: Error {
        case missingReply
        case replyKindMismatch
    }

    private(set) var requested: [CodexAppServerThreadRequest] = []
    var replies: [Reply] = []

    func submit(_ command: CodexCoreCommand) throws {}

    func request(_ request: CodexAppServerThreadRequest) throws -> Data {
        requested.append(request)
        guard !replies.isEmpty else {
            throw Failure.missingReply
        }
        let reply = replies.removeFirst()
        switch (request, reply) {
        case let (.list(id, _), .list(page)):
            return try JSONEncoder().encode(
                CodexAppServerReply<CodexThreadPage>.success(
                    .init(id: id, result: page)
                )
            )
        case let (.read(id, _), .read(result)):
            return try JSONEncoder().encode(
                CodexAppServerReply<CodexThreadReadResult>.success(
                    .init(id: id, result: result)
                )
            )
        default:
            throw Failure.replyKindMismatch
        }
    }

    func nextEvent() throws -> CodexCoreEvent? {
        nil
    }
}

private actor SessionCatalogEventRecorder {
    private(set) var values: [SessionCatalogValue] = []

    func record(_ value: SessionCatalogValue) {
        values.append(value)
    }
}

private func localCatalogStoredThread(
    id: String,
    name: String? = "Task",
    preview: String = "Preview",
    cwd: String = "/workspace",
    source: CodexThreadSessionSource = .named(.cli),
    ephemeral: Bool = false,
    parentThreadID: String? = nil,
    threadSource: String? = nil,
    createdAt: Int64,
    updatedAt: Int64,
    recencyAt: Int64? = nil,
    gitBranch: String? = nil
) -> CodexStoredThread {
    CodexStoredThread(
        id: .init(id),
        sessionID: "session-\(id)",
        parentThreadID: parentThreadID.map {
            CodexStoredThreadID($0)
        },
        preview: preview,
        ephemeral: ephemeral,
        modelProvider: "openai",
        createdAt: createdAt,
        updatedAt: updatedAt,
        recencyAt: recencyAt,
        status: .idle,
        path: "/tmp/\(id).jsonl",
        cwd: cwd,
        cliVersion: "1.0.0",
        source: source,
        threadSource: threadSource,
        gitInfo: gitBranch.map {
            .init(sha: nil, branch: $0, originURL: nil)
        },
        name: name,
        turns: []
    )
}

private func sessionCatalogThreadID(
    _ value: SessionCatalogValue
) -> String {
    guard case let .object(fields) = value,
          case let .string(threadID)? = fields["threadId"]
    else {
        return ""
    }
    return threadID
}

private struct SessionCatalogCursorPayload: Decodable {
    let version: Int
    let hostId: String
    let filterFingerprint: String
    let sortKey: String
    let sourceUpdatedAt: Int64
    let sourceRecencyAt: Int64
    let sourceCreatedAt: Int64
    let threadId: String
}

private func sessionCatalogCursorPayload(
    _ encoded: String
) -> SessionCatalogCursorPayload? {
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
    guard let data = Data(base64Encoded: standard) else {
        return nil
    }
    return try? JSONDecoder().decode(
        SessionCatalogCursorPayload.self,
        from: data
    )
}

private func sessionCatalogExpectedEntry(
    _ thread: CodexStoredThread
) -> SessionCatalogValue {
    let source: (String, SessionCatalogValue)
    switch thread.source {
    case let .named(name):
        source = (name.rawValue, .null)
    case let .custom(detail):
        source = ("custom", .string(detail))
    case .subAgent:
        source = ("unknown", .null)
    }
    let title = (thread.name ?? thread.preview)
        .split(whereSeparator: \.isWhitespace)
        .joined(separator: " ")
    return .object([
        "hostId": .string("local"),
        "threadId": .string(thread.id.rawValue),
        "displayTitle": .string(title),
        "sourceCreatedAt": .integer(thread.createdAt),
        "sourceUpdatedAt": .integer(thread.updatedAt),
        "sourceRecencyAt": .integer(
            thread.recencyAt ?? thread.updatedAt
        ),
        "cwd": .string(thread.cwd),
        "sourceKind": .string(source.0),
        "sourceDetail": source.1,
        "threadSource":
            thread.threadSource.map(SessionCatalogValue.string) ?? .null,
        "modelProvider": .string(thread.modelProvider),
        "gitBranch":
            thread.gitInfo?.branch.map(SessionCatalogValue.string) ?? .null,
    ])
}
