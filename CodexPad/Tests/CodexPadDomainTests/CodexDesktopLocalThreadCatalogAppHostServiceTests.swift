import Testing

@testable import CodexPadApplication

private typealias CatalogValue = CodexDesktopAppHostRPC.Value

@Test
func desktopLocalThreadCatalogForwardsReleasedReadSurface()
    async throws
{
    let backend = LocalThreadCatalogBackendFixture()
    let service = CodexDesktopLocalThreadCatalogAppHostService(
        backend: backend
    )
    let pageRequest: CatalogValue = .object([
        "hostId": .string("local"),
        "limit": .integer(25),
        "sortKey": .string("updated_at"),
    ])
    let locators: [CatalogValue] = [
        .object([
            "hostId": .string("local"),
            "threadId": .string("thread-1"),
        ]),
    ]
    let expectedPage = backend.page
    let expectedEntries = backend.entries
    let expectedStatus = backend.status

    #expect(
        try await service.invoke(
            method: "readPage",
            arguments: [pageRequest]
        ) == expectedPage
    )
    #expect(
        try await service.invoke(
            method: "readEntries",
            arguments: [.array(locators)]
        ) == .array(expectedEntries)
    )
    #expect(
        try await service.invoke(
            method: "removeMissingEntry",
            arguments: [locators[0]]
        ) == .bool(true)
    )
    #expect(
        try await service.invoke(
            method: "readSnapshot",
            arguments: []
        ) == .object([
            "revision": .integer(7),
            "isComplete": .bool(false),
            "hosts": .array([
                .object([
                    "hostId": .string("local"),
                    "isComplete": .bool(true),
                ]),
                .object([
                    "hostId": .string("remote"),
                    "isComplete": .bool(false),
                ]),
            ]),
            "entries": .array(expectedEntries),
        ])
    )
    #expect(
        try await service.invoke(
            method: "readStatus",
            arguments: []
        ) == expectedStatus
    )
    #expect(await backend.readPageRequests == [pageRequest])
    #expect(await backend.readEntriesRequests == [locators])
}

@Test
func desktopLocalThreadCatalogRunsPopulationAndSyncLifecycle()
    async throws
{
    let backend = LocalThreadCatalogBackendFixture()
    let service = CodexDesktopLocalThreadCatalogAppHostService(
        backend: backend
    )
    let expectedStatus = backend.status

    #expect(
        try await service.invoke(
            method: "setPopulationEnabled",
            arguments: [.bool(true), .string("manual")]
        ) == .undefined
    )
    #expect(
        try await service.invoke(
            method: "requestSync",
            arguments: [
                .array([.string("local"), .string("remote")]),
                .string("immediate"),
            ]
        ) == expectedStatus
    )
    #expect(
        try await service.invoke(
            method: "requestStartupSync",
            arguments: []
        ) == .undefined
    )
    #expect(
        await backend.populationRequests == [
            .init(enabled: true, startup: "manual"),
        ]
    )
    #expect(
        await backend.syncRequests == [
            .init(
                hostIDs: ["local", "remote"],
                priority: "immediate"
            ),
        ]
    )
    #expect(await backend.startupSyncCount == 1)
}

@Test
func desktopLocalThreadCatalogSubscriptionsForwardImmediateState()
    async throws
{
    let backend = LocalThreadCatalogBackendFixture()
    let callbacks = LocalThreadCatalogCallbackRecorder()
    let service = CodexDesktopLocalThreadCatalogAppHostService(
        backend: backend,
        callbackHandler: { callbackID, value in
            await callbacks.record(callbackID, value)
        }
    )
    let expectedStatus = backend.status
    let expectedEntries = backend.entries

    #expect(
        try await service.invoke(
            method: "subscribeStatus",
            arguments: [.import(11)]
        ) == .undefined
    )
    #expect(
        try await service.invoke(
            method: "subscribe",
            arguments: [.import(12)]
        ) == .undefined
    )
    #expect(
        try await service.invoke(
            method: "subscribeThreadObservations",
            arguments: [.import(13)]
        ) == .undefined
    )
    await service.publishStatus(.object(["revision": .integer(8)]))
    await service.publishThreadObservations(
        .array([.object(["threadId": .string("thread-1")])])
    )

    let events = await callbacks.events
    #expect(events[11] == [expectedStatus, .object([
        "revision": .integer(8),
    ])])
    #expect(events[12]?.first == .object([
        "type": .string("snapshot"),
        "snapshot": .object([
            "revision": .integer(7),
            "isComplete": .bool(false),
            "hosts": .array([
                .object([
                    "hostId": .string("local"),
                    "isComplete": .bool(true),
                ]),
                .object([
                    "hostId": .string("remote"),
                    "isComplete": .bool(false),
                ]),
            ]),
            "entries": .array(expectedEntries),
        ]),
    ]))
    #expect(events[13] == [
        .array([.object(["threadId": .string("thread-1")])]),
    ])

    _ = try await service.invoke(
        method: "unsubscribeStatus",
        arguments: []
    )
    _ = try await service.invoke(
        method: "unsubscribe",
        arguments: []
    )
    _ = try await service.invoke(
        method: "unsubscribeThreadObservations",
        arguments: []
    )
    await service.publishStatus(.object(["revision": .integer(9)]))
    await service.publishThreadObservations(.array([]))
    #expect(await callbacks.events == events)
}

@Test
func desktopLocalThreadCatalogNormalizesReleasedDelta()
    async throws
{
    let backend = LocalThreadCatalogBackendFixture()
    let callbacks = LocalThreadCatalogCallbackRecorder()
    let service = CodexDesktopLocalThreadCatalogAppHostService(
        backend: backend,
        callbackHandler: { callbackID, value in
            await callbacks.record(callbackID, value)
        }
    )
    _ = try await service.invoke(
        method: "subscribe",
        arguments: [.import(21)]
    )

    await service.publishCatalogEvent(
        .object([
            "type": .string("delta"),
            "delta": .object([
                "revision": .integer(8),
                "changedHosts": .array([
                    .object([
                        "hostId": .string("remote"),
                        "isComplete": .bool(true),
                    ]),
                ]),
                "removedHostIds": .array([]),
                "changedEntries": .array([
                    .object(["threadId": .string("thread-2")]),
                ]),
                "removedEntries": .array([]),
            ]),
        ])
    )

    #expect(await callbacks.events[21]?.last == .object([
        "type": .string("delta"),
        "delta": .object([
            "baseRevision": .integer(7),
            "revision": .integer(8),
            "isComplete": .bool(true),
            "changedHosts": .array([
                .object([
                    "hostId": .string("remote"),
                    "isComplete": .bool(true),
                ]),
            ]),
            "removedHostIds": .array([]),
            "changedEntries": .array([
                .object(["threadId": .string("thread-2")]),
            ]),
            "removedEntries": .array([]),
        ]),
    ]))
}

@Test
func desktopLocalThreadCatalogRejectsInvalidReleasedRequests()
    async throws
{
    let backend = LocalThreadCatalogBackendFixture()
    let service = CodexDesktopLocalThreadCatalogAppHostService(
        backend: backend
    )

    for invocation in [
        CatalogInvocation(
            method: "readPage",
            arguments: [.object([
                "hostId": .string("local"),
                "limit": .integer(0),
                "sortKey": .string("updated_at"),
            ])]
        ),
        CatalogInvocation(
            method: "readEntries",
            arguments: [.array([
                .object([
                    "hostId": .string("local"),
                    "threadId": .string(""),
                ]),
            ])]
        ),
        CatalogInvocation(
            method: "setPopulationEnabled",
            arguments: [.bool(true), .string("later")]
        ),
        CatalogInvocation(
            method: "requestSync",
            arguments: [.null, .string("slow")]
        ),
    ] {
        await #expect(
            throws:
                CodexDesktopLocalThreadCatalogAppHostService.Error
                    .invalidArguments
        ) {
            _ = try await service.invoke(
                method: invocation.method,
                arguments: invocation.arguments
            )
        }
    }
}

private struct CatalogInvocation {
    let method: String
    let arguments: [CatalogValue]
}

private actor LocalThreadCatalogBackendFixture:
    CodexDesktopLocalThreadCatalogBackend
{
    struct PopulationRequest: Equatable, Sendable {
        let enabled: Bool
        let startup: String
    }

    struct SyncRequest: Equatable, Sendable {
        let hostIDs: [String]?
        let priority: String
    }

    let entries: [CatalogValue] = [
        .object([
            "hostId": .string("local"),
            "threadId": .string("thread-1"),
            "cwd": .string("/workspace"),
        ]),
    ]
    let page: CatalogValue = .object([
        "entries": .array([
            .object([
                "hostId": .string("local"),
                "threadId": .string("thread-1"),
                "cwd": .string("/workspace"),
            ]),
        ]),
        "nextCursor": .null,
    ])
    let status: CatalogValue = .object([
        "revision": .integer(7),
        "populationEnabled": .bool(false),
        "hosts": .array([]),
    ])
    private(set) var readPageRequests: [CatalogValue] = []
    private(set) var readEntriesRequests: [[CatalogValue]] = []
    private(set) var populationRequests: [PopulationRequest] = []
    private(set) var syncRequests: [SyncRequest] = []
    private(set) var startupSyncCount = 0

    func readPage(_ request: CatalogValue) async throws
        -> CatalogValue
    {
        readPageRequests.append(request)
        return page
    }

    func readEntries(_ locators: [CatalogValue]) async throws
        -> [CatalogValue]
    {
        readEntriesRequests.append(locators)
        return entries
    }

    func removeMissingEntry(_ locator: CatalogValue) async throws
        -> Bool
    {
        true
    }

    func readSnapshot() async throws -> CatalogValue {
        .object([
            "revision": .integer(7),
            "hosts": .array([
                .object([
                    "hostId": .string("local"),
                    "isComplete": .bool(true),
                ]),
                .object([
                    "hostId": .string("remote"),
                    "isComplete": .bool(false),
                ]),
            ]),
            "entries": .array(entries),
        ])
    }

    func readStatus() async throws -> CatalogValue {
        status
    }

    func setPopulationEnabled(
        _ enabled: Bool,
        startup: String
    ) async throws {
        populationRequests.append(
            .init(enabled: enabled, startup: startup)
        )
    }

    func requestSync(
        hostIDs: [String]?,
        priority: String
    ) async throws {
        syncRequests.append(
            .init(hostIDs: hostIDs, priority: priority)
        )
    }

    func requestStartupSync() async throws {
        startupSyncCount += 1
    }
}

private actor LocalThreadCatalogCallbackRecorder {
    private(set) var events: [Int: [CatalogValue]] = [:]

    func record(_ callbackID: Int, _ value: CatalogValue) {
        events[callbackID, default: []].append(value)
    }
}
