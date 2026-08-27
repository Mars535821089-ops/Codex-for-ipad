import Foundation

public struct CodexDesktopLocalThreadCatalogBackendSubscription:
    Sendable
{
    public typealias Cancellation = @Sendable () async -> Void

    private let cancellation: Cancellation

    public init(_ cancellation: @escaping Cancellation) {
        self.cancellation = cancellation
    }

    public func cancel() async {
        await cancellation()
    }
}

/// Platform backend used by the released `localThreadCatalog` AppHost target.
///
/// The concrete iPad host can bridge these calls to its app-server/session
/// database while the service owns the renderer-facing validation,
/// subscription replacement, and aggregate delta semantics.
public protocol CodexDesktopLocalThreadCatalogBackend: Sendable {
    func readPage(
        _ request: CodexDesktopAppHostRPC.Value
    ) async throws -> CodexDesktopAppHostRPC.Value

    func readEntries(
        _ locators: [CodexDesktopAppHostRPC.Value]
    ) async throws -> [CodexDesktopAppHostRPC.Value]

    func removeMissingEntry(
        _ locator: CodexDesktopAppHostRPC.Value
    ) async throws -> Bool

    func readSnapshot() async throws
        -> CodexDesktopAppHostRPC.Value

    func readStatus() async throws
        -> CodexDesktopAppHostRPC.Value

    func setPopulationEnabled(
        _ enabled: Bool,
        startup: String
    ) async throws

    func requestSync(
        hostIDs: [String]?,
        priority: String
    ) async throws

    func requestStartupSync() async throws

    func subscribeCatalogEvents(
        _ handler: @escaping @Sendable (
            CodexDesktopAppHostRPC.Value
        ) async -> Void
    ) async -> CodexDesktopLocalThreadCatalogBackendSubscription

    func subscribeStatusEvents(
        _ handler: @escaping @Sendable (
            CodexDesktopAppHostRPC.Value
        ) async -> Void
    ) async -> CodexDesktopLocalThreadCatalogBackendSubscription

    func subscribeThreadObservationEvents(
        _ handler: @escaping @Sendable (
            CodexDesktopAppHostRPC.Value
        ) async -> Void
    ) async -> CodexDesktopLocalThreadCatalogBackendSubscription
}

public extension CodexDesktopLocalThreadCatalogBackend {
    func subscribeCatalogEvents(
        _ handler: @escaping @Sendable (
            CodexDesktopAppHostRPC.Value
        ) async -> Void
    ) async -> CodexDesktopLocalThreadCatalogBackendSubscription {
        .init {}
    }

    func subscribeStatusEvents(
        _ handler: @escaping @Sendable (
            CodexDesktopAppHostRPC.Value
        ) async -> Void
    ) async -> CodexDesktopLocalThreadCatalogBackendSubscription {
        .init {}
    }

    func subscribeThreadObservationEvents(
        _ handler: @escaping @Sendable (
            CodexDesktopAppHostRPC.Value
        ) async -> Void
    ) async -> CodexDesktopLocalThreadCatalogBackendSubscription {
        .init {}
    }
}

/// Released AppHost adapter for the cross-host local thread catalog.
///
/// Desktop exposes a single replaceable callback for catalog updates, status,
/// and raw thread observations. Snapshot and delta aggregation is performed at
/// this boundary, including the derived all-host `isComplete` field.
public actor CodexDesktopLocalThreadCatalogAppHostService {
    public typealias Value = CodexDesktopAppHostRPC.Value
    public typealias CallbackHandler =
        @Sendable (Int, Value) async -> Void

    public enum Error: Swift.Error, Equatable, Sendable {
        case invalidArguments
        case invalidResponse
        case platformBackendUnavailable
        case unsupportedMethod(String)
    }

    private let backend:
        (any CodexDesktopLocalThreadCatalogBackend)?
    private let callbackHandler: CallbackHandler
    private var updateCallbackID: Int?
    private var statusCallbackID: Int?
    private var threadObservationCallbackID: Int?
    private var updateSubscription:
        CodexDesktopLocalThreadCatalogBackendSubscription?
    private var statusSubscription:
        CodexDesktopLocalThreadCatalogBackendSubscription?
    private var threadObservationSubscription:
        CodexDesktopLocalThreadCatalogBackendSubscription?
    private var updateSubscriptionGeneration: UInt64 = 0
    private var statusSubscriptionGeneration: UInt64 = 0
    private var threadObservationSubscriptionGeneration: UInt64 = 0
    private var lastRevision: Int64 = 0
    private var lastIsComplete = false
    private var hostsByID: [String: Bool] = [:]

    public init(
        backend:
            (any CodexDesktopLocalThreadCatalogBackend)? = nil,
        callbackHandler: @escaping CallbackHandler = { _, _ in }
    ) {
        self.backend = backend
        self.callbackHandler = callbackHandler
    }

    public func invoke(
        method: String,
        arguments: [Value]?
    ) async throws -> Value {
        switch method {
        case "readPage":
            let request = try Self.pageRequest(arguments)
            let backend = try requireBackend()
            let response = try await backend.readPage(request)
            guard case .object = response else {
                throw Error.invalidResponse
            }
            return response

        case "readEntries":
            let locators = try Self.locatorList(arguments)
            let backend = try requireBackend()
            return .array(
                try await backend.readEntries(locators)
            )

        case "removeMissingEntry":
            let locator = try Self.singleLocator(arguments)
            let backend = try requireBackend()
            return .bool(
                try await backend.removeMissingEntry(locator)
            )

        case "readSnapshot":
            try Self.requireNoArguments(arguments)
            let backend = try requireBackend()
            return try Self.normalizedSnapshot(
                try await backend.readSnapshot()
            )

        case "readStatus":
            try Self.requireNoArguments(arguments)
            return try await readStatus()

        case "subscribeStatus":
            let callbackID = try Self.singleCallbackID(arguments)
            let backend = try requireBackend()
            statusSubscriptionGeneration &+= 1
            let generation = statusSubscriptionGeneration
            let priorSubscription = statusSubscription
            statusSubscription = nil
            statusCallbackID = nil
            await priorSubscription?.cancel()
            guard generation == statusSubscriptionGeneration else {
                return .undefined
            }
            let subscription = await backend.subscribeStatusEvents {
                [weak self] status in
                await self?.receiveStatus(
                    status,
                    generation: generation
                )
            }
            guard generation == statusSubscriptionGeneration else {
                await subscription.cancel()
                return .undefined
            }
            statusSubscription = subscription
            let status: Value
            do {
                status = try await readStatus()
            } catch {
                if generation == statusSubscriptionGeneration {
                    statusSubscription = nil
                    statusCallbackID = nil
                }
                await subscription.cancel()
                throw error
            }
            guard generation == statusSubscriptionGeneration else {
                return .undefined
            }
            statusCallbackID = callbackID
            await callbackHandler(
                callbackID,
                status
            )
            guard generation == statusSubscriptionGeneration,
                  statusCallbackID == callbackID
            else {
                return .undefined
            }
            return .undefined

        case "unsubscribeStatus":
            try Self.requireNoArguments(arguments)
            statusSubscriptionGeneration &+= 1
            let subscription = statusSubscription
            statusSubscription = nil
            statusCallbackID = nil
            await subscription?.cancel()
            return .undefined

        case "setPopulationEnabled":
            let request = try Self.populationRequest(arguments)
            let backend = try requireBackend()
            try await backend.setPopulationEnabled(
                request.enabled,
                startup: request.startup
            )
            return .undefined

        case "subscribe":
            let callbackID = try Self.singleCallbackID(arguments)
            let backend = try requireBackend()
            updateSubscriptionGeneration &+= 1
            let generation = updateSubscriptionGeneration
            let priorSubscription = updateSubscription
            updateSubscription = nil
            updateCallbackID = nil
            await priorSubscription?.cancel()
            guard generation == updateSubscriptionGeneration else {
                return .undefined
            }
            let subscription = await backend.subscribeCatalogEvents {
                [weak self] event in
                await self?.receiveCatalogEvent(
                    event,
                    generation: generation
                )
            }
            guard generation == updateSubscriptionGeneration else {
                await subscription.cancel()
                return .undefined
            }
            updateSubscription = subscription
            let snapshot: Value
            do {
                snapshot = try Self.normalizedSnapshot(
                    try await backend.readSnapshot()
                )
            } catch {
                if generation == updateSubscriptionGeneration {
                    updateSubscription = nil
                    updateCallbackID = nil
                }
                await subscription.cancel()
                throw error
            }
            guard generation == updateSubscriptionGeneration else {
                return .undefined
            }
            updateCallbackID = callbackID
            updateAggregateState(from: snapshot)
            await callbackHandler(
                callbackID,
                .object([
                    "type": .string("snapshot"),
                    "snapshot": snapshot,
                ])
            )
            guard generation == updateSubscriptionGeneration,
                  updateCallbackID == callbackID
            else {
                return .undefined
            }
            return .undefined

        case "unsubscribe":
            try Self.requireNoArguments(arguments)
            updateSubscriptionGeneration &+= 1
            let subscription = updateSubscription
            updateSubscription = nil
            updateCallbackID = nil
            await subscription?.cancel()
            return .undefined

        case "subscribeThreadObservations":
            let callbackID = try Self.singleCallbackID(arguments)
            let backend = try requireBackend()
            threadObservationSubscriptionGeneration &+= 1
            let generation =
                threadObservationSubscriptionGeneration
            let priorSubscription = threadObservationSubscription
            threadObservationSubscription = nil
            threadObservationCallbackID = callbackID
            await priorSubscription?.cancel()
            guard generation
                    == threadObservationSubscriptionGeneration,
                  threadObservationCallbackID == callbackID
            else {
                return .undefined
            }
            let subscription =
                await backend.subscribeThreadObservationEvents {
                    [weak self] observations in
                    await self?.receiveThreadObservations(
                        observations,
                        generation: generation
                    )
                }
            if generation
                    == threadObservationSubscriptionGeneration,
               threadObservationCallbackID == callbackID
            {
                threadObservationSubscription = subscription
            } else {
                await subscription.cancel()
            }
            return .undefined

        case "unsubscribeThreadObservations":
            try Self.requireNoArguments(arguments)
            threadObservationSubscriptionGeneration &+= 1
            let subscription = threadObservationSubscription
            threadObservationSubscription = nil
            threadObservationCallbackID = nil
            await subscription?.cancel()
            return .undefined

        case "requestSync":
            let request = try Self.syncRequest(arguments)
            let backend = try requireBackend()
            try await backend.requestSync(
                hostIDs: request.hostIDs,
                priority: request.priority
            )
            return try await readStatus()

        case "requestStartupSync":
            try Self.requireNoArguments(arguments)
            let backend = try requireBackend()
            try await backend.requestStartupSync()
            return .undefined

        default:
            throw Error.unsupportedMethod(method)
        }
    }

    private func receiveStatus(
        _ status: Value,
        generation: UInt64
    ) async {
        guard generation == statusSubscriptionGeneration else {
            return
        }
        await publishStatus(status)
    }

    private func receiveCatalogEvent(
        _ event: Value,
        generation: UInt64
    ) async {
        guard generation == updateSubscriptionGeneration else {
            return
        }
        await publishCatalogEvent(event)
    }

    private func receiveThreadObservations(
        _ observations: Value,
        generation: UInt64
    ) async {
        guard generation
                == threadObservationSubscriptionGeneration
        else {
            return
        }
        await publishThreadObservations(observations)
    }

    /// Forwards the manager's latest status to the currently subscribed
    /// renderer callback.
    public func publishStatus(_ status: Value) async {
        guard let callbackID = statusCallbackID else {
            return
        }
        await callbackHandler(callbackID, status)
    }

    /// Forwards the manager's raw thread observations to the released
    /// observation callback.
    public func publishThreadObservations(
        _ observations: Value
    ) async {
        guard let callbackID = threadObservationCallbackID else {
            return
        }
        await callbackHandler(callbackID, observations)
    }

    /// Accepts the aggregate manager event shape and applies the exact desktop
    /// snapshot/delta coalescing rules before invoking the renderer callback.
    public func publishCatalogEvent(_ event: Value) async {
        guard let callbackID = updateCallbackID,
              case let .object(fields) = event,
              case let .string(type)? = fields["type"]
        else {
            return
        }

        if type == "snapshot",
           let rawSnapshot = fields["snapshot"],
           let snapshot = try? Self.normalizedSnapshot(rawSnapshot)
        {
            updateAggregateState(from: snapshot)
            await callbackHandler(
                callbackID,
                .object([
                    "type": .string("snapshot"),
                    "snapshot": snapshot,
                ])
            )
            return
        }

        guard type == "delta",
              case let .object(delta)? = fields["delta"],
              let revision = Self.integer(delta["revision"]),
              revision >= lastRevision,
              let changedHosts = Self.array(
                delta["changedHosts"]
              ),
              let removedHostIDs = Self.stringArray(
                delta["removedHostIds"]
              ),
              let changedEntries = Self.array(
                delta["changedEntries"]
              ),
              let removedEntries = Self.array(
                delta["removedEntries"]
              )
        else {
            return
        }

        let priorHosts = hostsByID
        var nextHosts = priorHosts
        for host in changedHosts {
            guard case let .object(hostFields) = host,
                  let hostID = Self.nonemptyString(
                    hostFields["hostId"]
                  ),
                  case let .bool(isComplete)? =
                    hostFields["isComplete"]
            else {
                return
            }
            nextHosts[hostID] = isComplete
        }
        for hostID in removedHostIDs {
            nextHosts.removeValue(forKey: hostID)
        }

        let isComplete = nextHosts.values.allSatisfy { $0 }
        let hostsChanged = nextHosts != priorHosts
        let entriesChanged =
            !changedEntries.isEmpty || !removedEntries.isEmpty
        let completionChanged = isComplete != lastIsComplete
        if (!entriesChanged && !completionChanged && !hostsChanged)
            || (
                revision == lastRevision
                    && !completionChanged
                    && !hostsChanged
            )
        {
            return
        }

        let baseRevision = lastRevision
        hostsByID = nextHosts
        lastRevision = revision
        lastIsComplete = isComplete
        await callbackHandler(
            callbackID,
            .object([
                "type": .string("delta"),
                "delta": .object([
                    "baseRevision": .integer(baseRevision),
                    "revision": .integer(revision),
                    "isComplete": .bool(isComplete),
                    "changedHosts": .array(changedHosts),
                    "removedHostIds": .array(
                        removedHostIDs.map(Value.string)
                    ),
                    "changedEntries": .array(changedEntries),
                    "removedEntries": .array(removedEntries),
                ]),
            ])
        )
    }

    private func requireBackend() throws
        -> any CodexDesktopLocalThreadCatalogBackend
    {
        guard let backend else {
            throw Error.platformBackendUnavailable
        }
        return backend
    }

    private func readStatus() async throws -> Value {
        let backend = try requireBackend()
        let status = try await backend.readStatus()
        guard case .object = status else {
            throw Error.invalidResponse
        }
        return status
    }

    private func updateAggregateState(from snapshot: Value) {
        guard case let .object(fields) = snapshot,
              let revision = Self.integer(fields["revision"]),
              case let .bool(isComplete)? = fields["isComplete"],
              let hosts = Self.array(fields["hosts"])
        else {
            return
        }
        var nextHosts: [String: Bool] = [:]
        for host in hosts {
            guard case let .object(hostFields) = host,
                  let hostID = Self.nonemptyString(
                    hostFields["hostId"]
                  ),
                  case let .bool(hostComplete)? =
                    hostFields["isComplete"]
            else {
                continue
            }
            nextHosts[hostID] = hostComplete
        }
        lastRevision = revision
        lastIsComplete = isComplete
        hostsByID = nextHosts
    }

    private static func normalizedSnapshot(
        _ value: Value
    ) throws -> Value {
        guard case let .object(fields) = value,
              let revision = integer(fields["revision"]),
              let hosts = array(fields["hosts"]),
              let entries = array(fields["entries"])
        else {
            throw Error.invalidResponse
        }
        var isComplete = true
        for host in hosts {
            guard case let .object(hostFields) = host,
                  nonemptyString(hostFields["hostId"]) != nil,
                  case let .bool(hostComplete)? =
                    hostFields["isComplete"]
            else {
                throw Error.invalidResponse
            }
            isComplete = isComplete && hostComplete
        }
        return .object([
            "revision": .integer(revision),
            "isComplete": .bool(isComplete),
            "hosts": .array(hosts),
            "entries": .array(entries),
        ])
    }

    private static func pageRequest(
        _ arguments: [Value]?
    ) throws -> Value {
        guard let arguments,
              arguments.count == 1,
              case let .object(fields) = arguments[0],
              nonemptyString(fields["hostId"]) != nil,
              let limit = integer(fields["limit"]),
              (1...100).contains(limit),
              let sortKey = nonemptyString(fields["sortKey"]),
              ["created_at", "updated_at"].contains(sortKey)
        else {
            throw Error.invalidArguments
        }
        return arguments[0]
    }

    private static func locatorList(
        _ arguments: [Value]?
    ) throws -> [Value] {
        guard let arguments,
              arguments.count == 1,
              case let .array(locators) = arguments[0],
              locators.count <= 100
        else {
            throw Error.invalidArguments
        }
        for locator in locators {
            try validateLocator(locator)
        }
        return locators
    }

    private static func singleLocator(
        _ arguments: [Value]?
    ) throws -> Value {
        guard let arguments, arguments.count == 1 else {
            throw Error.invalidArguments
        }
        try validateLocator(arguments[0])
        return arguments[0]
    }

    private static func validateLocator(_ value: Value) throws {
        guard case let .object(fields) = value,
              nonemptyString(fields["hostId"]) != nil,
              nonemptyString(fields["threadId"]) != nil
        else {
            throw Error.invalidArguments
        }
    }

    private static func singleCallbackID(
        _ arguments: [Value]?
    ) throws -> Int {
        guard let arguments,
              arguments.count == 1,
              case let .import(callbackID) = arguments[0],
              callbackID >= 0
        else {
            throw Error.invalidArguments
        }
        return callbackID
    }

    private static func populationRequest(
        _ arguments: [Value]?
    ) throws -> (enabled: Bool, startup: String) {
        guard let arguments,
              (1...2).contains(arguments.count),
              case let .bool(enabled) = arguments[0]
        else {
            throw Error.invalidArguments
        }
        let startup: String
        if arguments.count == 1 {
            startup = "idle"
        } else {
            guard case let .string(value) = arguments[1],
                  ["idle", "manual"].contains(value)
            else {
                throw Error.invalidArguments
            }
            startup = value
        }
        return (enabled, startup)
    }

    private static func syncRequest(
        _ arguments: [Value]?
    ) throws -> (hostIDs: [String]?, priority: String) {
        let arguments = arguments ?? []
        guard arguments.count <= 2 else {
            throw Error.invalidArguments
        }

        let hostIDs: [String]?
        if let first = arguments.first {
            switch first {
            case .undefined, .null:
                hostIDs = nil
            case let .array(values):
                guard let strings = stringArray(.array(values)) else {
                    throw Error.invalidArguments
                }
                hostIDs = strings
            default:
                throw Error.invalidArguments
            }
        } else {
            hostIDs = nil
        }

        let priority: String
        if arguments.count == 2 {
            guard case let .string(raw) = arguments[1],
                  ["normal", "immediate"].contains(raw)
            else {
                throw Error.invalidArguments
            }
            priority = raw
        } else {
            priority = "normal"
        }
        return (hostIDs, priority)
    }

    private static func requireNoArguments(
        _ arguments: [Value]?
    ) throws {
        guard arguments == nil || arguments?.isEmpty == true else {
            throw Error.invalidArguments
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

    private static func array(_ value: Value?) -> [Value]? {
        guard case let .array(values)? = value else {
            return nil
        }
        return values
    }

    private static func stringArray(
        _ value: Value?
    ) -> [String]? {
        guard let values = array(value) else {
            return nil
        }
        var strings: [String] = []
        strings.reserveCapacity(values.count)
        for value in values {
            guard let string = nonemptyString(value) else {
                return nil
            }
            strings.append(string)
        }
        return strings
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
