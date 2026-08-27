import Foundation
import Testing

@testable import CodexPadApplication

private typealias SubscriptionCatalogValue =
    CodexDesktopAppHostRPC.Value

@Test
func desktopLocalThreadCatalogFailedInitialReadsLeaveNoGhostCallbacks()
    async throws
{
    let backend = SubscriptionCatalogBackendFixture(
        failStatusRead: true,
        failSnapshotRead: true
    )
    let callbacks = SubscriptionCatalogCallbackRecorder()
    let service = CodexDesktopLocalThreadCatalogAppHostService(
        backend: backend,
        callbackHandler: {
            await callbacks.record(callbackID: $0, value: $1)
        }
    )

    await #expect(throws: SubscriptionCatalogFixtureError.initialRead) {
        _ = try await service.invoke(
            method: "subscribeStatus",
            arguments: [.import(101)]
        )
    }
    await #expect(throws: SubscriptionCatalogFixtureError.initialRead) {
        _ = try await service.invoke(
            method: "subscribe",
            arguments: [.import(102)]
        )
    }

    await service.publishStatus(.object([
        "revision": .integer(99),
    ]))
    await service.publishCatalogEvent(.object([
        "type": .string("snapshot"),
        "snapshot": .object([
            "revision": .integer(99),
            "hosts": .array([]),
            "entries": .array([]),
        ]),
    ]))
    await backend.emitStatus(.object(["revision": .integer(100)]))
    await backend.emitCatalog(.object([
        "type": .string("delta"),
        "delta": .object([
            "revision": .integer(100),
            "changedHosts": .array([]),
            "removedHostIds": .array([]),
            "changedEntries": .array([]),
            "removedEntries": .array([]),
        ]),
    ]))

    #expect(await callbacks.events.isEmpty)
    #expect(await backend.statusSubscriberCount == 0)
    #expect(await backend.catalogSubscriberCount == 0)
}

@Test
func desktopLocalThreadCatalogReplacesAndCancelsBackendSubscriptions()
    async throws
{
    let backend = SubscriptionCatalogBackendFixture()
    let callbacks = SubscriptionCatalogCallbackRecorder()
    let service = CodexDesktopLocalThreadCatalogAppHostService(
        backend: backend,
        callbackHandler: {
            await callbacks.record(callbackID: $0, value: $1)
        }
    )

    _ = try await service.invoke(
        method: "subscribeStatus",
        arguments: [.import(201)]
    )
    _ = try await service.invoke(
        method: "subscribeStatus",
        arguments: [.import(202)]
    )
    _ = try await service.invoke(
        method: "subscribe",
        arguments: [.import(203)]
    )
    _ = try await service.invoke(
        method: "subscribe",
        arguments: [.import(204)]
    )
    _ = try await service.invoke(
        method: "subscribeThreadObservations",
        arguments: [.import(205)]
    )
    _ = try await service.invoke(
        method: "subscribeThreadObservations",
        arguments: [.import(206)]
    )

    await backend.emitStatus(.object(["revision": .integer(2)]))
    await backend.emitCatalog(.object([
        "type": .string("delta"),
        "delta": .object([
            "revision": .integer(2),
            "changedHosts": .array([]),
            "removedHostIds": .array([]),
            "changedEntries": .array([
                .object(["threadId": .string("live")]),
            ]),
            "removedEntries": .array([]),
        ]),
    ]))
    await backend.emitThreadObservation(.object([
        "hostId": .string("local"),
        "threads": .array([]),
    ]))

    #expect(await callbacks.events[201]?.count == 1)
    #expect(await callbacks.events[202]?.last == .object([
        "revision": .integer(2),
    ]))
    #expect(await callbacks.events[203]?.count == 1)
    #expect(await callbacks.events[204]?.last == .object([
        "type": .string("delta"),
        "delta": .object([
            "baseRevision": .integer(1),
            "revision": .integer(2),
            "isComplete": .bool(false),
            "changedHosts": .array([]),
            "removedHostIds": .array([]),
            "changedEntries": .array([
                .object(["threadId": .string("live")]),
            ]),
            "removedEntries": .array([]),
        ]),
    ]))
    #expect(await callbacks.events[205] == nil)
    #expect(await callbacks.events[206] == [
        .object([
            "hostId": .string("local"),
            "threads": .array([]),
        ]),
    ])
    #expect(await backend.cancellationCount == 3)

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
    #expect(await backend.cancellationCount == 6)
    #expect(await backend.statusSubscriberCount == 0)
    #expect(await backend.catalogSubscriberCount == 0)
    #expect(await backend.threadSubscriberCount == 0)
}

@Test
func desktopLocalThreadCatalogSubscriptionGenerationRejectsLateInitialRead()
    async throws
{
    let gate = SubscriptionCatalogGate()
    let backend = SubscriptionCatalogBackendFixture(
        firstSnapshotGate: gate
    )
    let callbacks = SubscriptionCatalogCallbackRecorder()
    let service = CodexDesktopLocalThreadCatalogAppHostService(
        backend: backend,
        callbackHandler: {
            await callbacks.record(callbackID: $0, value: $1)
        }
    )

    let stale = Task {
        try await service.invoke(
            method: "subscribe",
            arguments: [.import(301)]
        )
    }
    while await backend.snapshotReadCount == 0 {
        await Task.yield()
    }
    let current = Task {
        try await service.invoke(
            method: "subscribe",
            arguments: [.import(302)]
        )
    }
    _ = try await current.value
    await gate.open()
    _ = try await stale.value
    await backend.emitCatalog(.object([
        "type": .string("delta"),
        "delta": .object([
            "revision": .integer(3),
            "changedHosts": .array([]),
            "removedHostIds": .array([]),
            "changedEntries": .array([
                .object(["threadId": .string("current")]),
            ]),
            "removedEntries": .array([]),
        ]),
    ]))

    #expect(await callbacks.events[301] == nil)
    #expect(await callbacks.events[302]?.count == 2)
    #expect(await backend.catalogSubscriberCount == 1)
}

private enum SubscriptionCatalogFixtureError: Error {
    case initialRead
}

private actor SubscriptionCatalogGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isOpen = false

    func wait() async {
        guard !isOpen else {
            return
        }
        await withCheckedContinuation {
            continuation = $0
        }
    }

    func open() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}

private actor SubscriptionCatalogBackendFixture:
    CodexDesktopLocalThreadCatalogBackend
{
    typealias Handler =
        @Sendable (SubscriptionCatalogValue) async -> Void

    private let failStatusRead: Bool
    private let failSnapshotRead: Bool
    private let firstSnapshotGate: SubscriptionCatalogGate?
    private var statusHandlers: [UUID: Handler] = [:]
    private var catalogHandlers: [UUID: Handler] = [:]
    private var threadHandlers: [UUID: Handler] = [:]
    private(set) var snapshotReadCount = 0
    private(set) var cancellationCount = 0

    init(
        failStatusRead: Bool = false,
        failSnapshotRead: Bool = false,
        firstSnapshotGate: SubscriptionCatalogGate? = nil
    ) {
        self.failStatusRead = failStatusRead
        self.failSnapshotRead = failSnapshotRead
        self.firstSnapshotGate = firstSnapshotGate
    }

    var statusSubscriberCount: Int {
        statusHandlers.count
    }

    var catalogSubscriberCount: Int {
        catalogHandlers.count
    }

    var threadSubscriberCount: Int {
        threadHandlers.count
    }

    func readPage(_ request: SubscriptionCatalogValue) async throws
        -> SubscriptionCatalogValue
    {
        .object(["entries": .array([]), "nextCursor": .null])
    }

    func readEntries(
        _ locators: [SubscriptionCatalogValue]
    ) async throws -> [SubscriptionCatalogValue] {
        []
    }

    func removeMissingEntry(
        _ locator: SubscriptionCatalogValue
    ) async throws -> Bool {
        false
    }

    func readSnapshot() async throws -> SubscriptionCatalogValue {
        snapshotReadCount += 1
        if snapshotReadCount == 1, let firstSnapshotGate {
            await firstSnapshotGate.wait()
        }
        if failSnapshotRead {
            throw SubscriptionCatalogFixtureError.initialRead
        }
        return .object([
            "revision": .integer(1),
            "hosts": .array([
                .object([
                    "hostId": .string("local"),
                    "isComplete": .bool(false),
                ]),
            ]),
            "entries": .array([]),
        ])
    }

    func readStatus() async throws -> SubscriptionCatalogValue {
        if failStatusRead {
            throw SubscriptionCatalogFixtureError.initialRead
        }
        return .object([
            "revision": .integer(1),
            "populationEnabled": .bool(false),
            "hosts": .array([]),
        ])
    }

    func setPopulationEnabled(
        _ enabled: Bool,
        startup: String
    ) async throws {}

    func requestSync(
        hostIDs: [String]?,
        priority: String
    ) async throws {}

    func requestStartupSync() async throws {}

    func subscribeCatalogEvents(
        _ handler: @escaping Handler
    ) async -> CodexDesktopLocalThreadCatalogBackendSubscription {
        let id = UUID()
        catalogHandlers[id] = handler
        return .init { [weak self] in
            await self?.cancelCatalog(id)
        }
    }

    func subscribeStatusEvents(
        _ handler: @escaping Handler
    ) async -> CodexDesktopLocalThreadCatalogBackendSubscription {
        let id = UUID()
        statusHandlers[id] = handler
        return .init { [weak self] in
            await self?.cancelStatus(id)
        }
    }

    func subscribeThreadObservationEvents(
        _ handler: @escaping Handler
    ) async -> CodexDesktopLocalThreadCatalogBackendSubscription {
        let id = UUID()
        threadHandlers[id] = handler
        return .init { [weak self] in
            await self?.cancelThread(id)
        }
    }

    func emitCatalog(_ value: SubscriptionCatalogValue) async {
        let handlers = Array(catalogHandlers.values)
        for handler in handlers {
            await handler(value)
        }
    }

    func emitStatus(_ value: SubscriptionCatalogValue) async {
        let handlers = Array(statusHandlers.values)
        for handler in handlers {
            await handler(value)
        }
    }

    func emitThreadObservation(
        _ value: SubscriptionCatalogValue
    ) async {
        let handlers = Array(threadHandlers.values)
        for handler in handlers {
            await handler(value)
        }
    }

    private func cancelCatalog(_ id: UUID) {
        if catalogHandlers.removeValue(forKey: id) != nil {
            cancellationCount += 1
        }
    }

    private func cancelStatus(_ id: UUID) {
        if statusHandlers.removeValue(forKey: id) != nil {
            cancellationCount += 1
        }
    }

    private func cancelThread(_ id: UUID) {
        if threadHandlers.removeValue(forKey: id) != nil {
            cancellationCount += 1
        }
    }
}

private actor SubscriptionCatalogCallbackRecorder {
    private(set) var events:
        [Int: [SubscriptionCatalogValue]] = [:]

    func record(
        callbackID: Int,
        value: SubscriptionCatalogValue
    ) {
        events[callbackID, default: []].append(value)
    }
}
