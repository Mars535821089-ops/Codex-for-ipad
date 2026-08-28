import Foundation

/// Native implementation of the released renderer's six realtime AppHost
/// services. The actual audio transport remains in `CodexRealtimeService`;
/// this actor owns the desktop-compatible coordination, presentation,
/// continuity, and memory contracts around that transport.
public actor CodexDesktopRealtimeAppHostService {
    public typealias Value = CodexDesktopAppHostRPC.Value
    public typealias EventHandler =
        @Sendable (String, String, [Value]?) async -> Void
    public typealias CallbackInvoker =
        @Sendable (Int, [Value]) async throws -> Void

    /// The desktop main process coordinates realtime startup across two
    /// renderer AppHost ports: the primary surface requests a launch and the
    /// avatar-overlay surface later registers the callback that creates the
    /// session. Keep that state outside either port-scoped service instance.
    public actor RuntimeCoordinator {
        public init() {}

        private struct Starter: Sendable {
            let request: Int
            let cancel: Int
            let ready: Bool
            let callbackInvoker: CallbackInvoker
        }

        private struct PendingStart: Sendable {
            let request: Value
            let launchID: String?
            let eventHandler: EventHandler
        }

        private var starter: Starter?
        private var pendingStart: PendingStart?

        func register(
            request: Int,
            cancel: Int,
            ready: Bool,
            callbackInvoker: @escaping CallbackInvoker
        ) {
            starter = Starter(
                request: request,
                cancel: cancel,
                ready: ready,
                callbackInvoker: callbackInvoker
            )
            startPendingIfReady()
        }

        func unregister(request: Int, cancel: Int) {
            guard starter?.request == request,
                  starter?.cancel == cancel
            else {
                return
            }
            starter = nil
        }

        func requestStart(
            request: Value,
            launchID: String?,
            eventHandler: @escaping EventHandler
        ) async throws {
            if let starter, starter.ready {
                try await run(
                    starter: starter,
                    pending: PendingStart(
                        request: request,
                        launchID: launchID,
                        eventHandler: eventHandler
                    )
                )
                return
            }
            pendingStart = PendingStart(
                request: request,
                launchID: launchID,
                eventHandler: eventHandler
            )
            await eventHandler(
                "realtimeVoiceRuntime",
                "requestRealtimeStart",
                [request] + (launchID.map { [.string($0)] } ?? [])
            )
        }

        func cancel(
            eventHandler: @escaping EventHandler
        ) async throws {
            pendingStart = nil
            guard let starter else {
                await eventHandler(
                    "realtimeVoiceRuntime",
                    "cancelRealtimeSessionStart",
                    []
                )
                return
            }
            try await starter.callbackInvoker(starter.cancel, [])
        }

        private func startPendingIfReady() {
            guard let starter, starter.ready, let pendingStart else {
                return
            }
            self.pendingStart = nil
            Task {
                try? await self.run(
                    starter: starter,
                    pending: pendingStart
                )
            }
        }

        private func run(
            starter: Starter,
            pending: PendingStart
        ) async throws {
            do {
                try await starter.callbackInvoker(
                    starter.request,
                    [pending.request]
                )
                await publishLaunchState(
                    phase: "connected",
                    pending: pending,
                    error: nil
                )
            } catch {
                await publishLaunchState(
                    phase: "failed",
                    pending: pending,
                    error: String(describing: error)
                )
                throw error
            }
        }

        private func publishLaunchState(
            phase: String,
            pending: PendingStart,
            error: String?
        ) async {
            guard let launchID = pending.launchID else {
                return
            }
            var payload: [String: Value] = [
                "launchId": .string(launchID),
                "phase": .string(phase),
            ]
            payload["error"] = error.map(Value.string) ?? .null
            await pending.eventHandler(
                "realtimeVoiceRuntime",
                "launchStateChanged",
                [.object(payload)]
            )
        }
    }

    public enum Error: Swift.Error, Equatable, Sendable {
        case invalidArguments
        case unsupportedMethod(service: String, method: String)
    }

    public static let inactiveVoiceSnapshot: Value = .object([
        "activity": .string("idle"),
        "locator": .null,
        "microphoneMuted": .bool(false),
        "outputMuted": .bool(false),
        "phase": .string("inactive"),
        "preferredPresentationSurface": .null,
        "sessionId": .null,
    ])

    private struct ContinuityItem: Codable, Sendable {
        let role: String
        let text: String
    }

    private struct ContinuityThread: Codable, Sendable {
        var items: [ContinuityItem]
    }

    private struct ContinuityDocument: Codable, Sendable {
        var version: Int
        var threads: [String: ContinuityThread]

        static let empty = ContinuityDocument(
            version: 1,
            threads: [:]
        )
    }

    private struct VoiceClaim: Sendable {
        let id: String
        var locator: Value
        let preferredPresentationSurface: Value
        var snapshot: Value
        var published: Bool
    }

    private let codexHome: URL
    private let eventHandler: EventHandler
    private let callbackInvoker: CallbackInvoker?
    private let runtimeCoordinator: RuntimeCoordinator
    private var voiceClaim: VoiceClaim?
    private var voiceSubscribers: Set<Int> = []
    private var multiAgentActivities: [String: [Value]] = [:]
    private var registeredPresentationSurfaces: Set<String> = []
    private var requestedPresentation: Value?
    private var realtimeStarter: (request: Int, cancel: Int)?

    public init(
        codexHome: URL,
        eventHandler: EventHandler? = nil,
        callbackInvoker: CallbackInvoker? = nil,
        runtimeCoordinator: RuntimeCoordinator = RuntimeCoordinator()
    ) {
        self.codexHome = codexHome
        self.eventHandler = eventHandler ?? { _, _, _ in }
        self.callbackInvoker = callbackInvoker
        self.runtimeCoordinator = runtimeCoordinator
    }

    public func invoke(
        service: String,
        method: String,
        arguments: [Value]?
    ) async throws -> Value {
        switch (service, method) {
        case ("realtimeContinuity", "read"):
            return try readContinuity(arguments)
        case ("realtimeContinuity", "record"):
            try recordContinuity(arguments)
            return .undefined
        case ("realtimeMemory", "readSummary"):
            return readMemorySummary()

        case ("realtimeVoice", "claim"):
            return try claimVoice(arguments)
        case ("realtimeVoice", "publish"):
            try await publishVoice(arguments)
            return .undefined
        case ("realtimeVoice", "transfer"):
            return try await transferVoice(arguments)
        case ("realtimeVoice", "cancelTransfer"):
            _ = try locator(arguments?.first)
            voiceClaim = nil
            requestedPresentation = nil
            await notifyVoiceSubscribers()
            await eventHandler(service, method, arguments)
            return .undefined
        case ("realtimeVoice", "setDictationActive"):
            guard case .bool? = arguments?.first else {
                throw Error.invalidArguments
            }
            await eventHandler(service, method, arguments)
            return .undefined
        case ("realtimeVoice", "release"):
            try await releaseVoice(arguments)
            return .undefined
        case ("realtimeVoice", "control"):
            return try await controlVoice(arguments)
        case ("realtimeVoice", "controlActive"):
            return try await controlActiveVoice(arguments)
        case ("realtimeVoice", "recordRealDelegation"):
            return try await recordRealDelegation(arguments)
        case ("realtimeVoice", "getSnapshot"):
            return voiceSnapshot()
        case ("realtimeVoice", "subscribe"):
            try await subscribeToVoice(arguments)
            await eventHandler(service, method, arguments)
            return subscriptionTarget()

        case ("realtimeVoiceMultiAgentActivity", "publish"):
            try publishMultiAgentActivity(arguments)
            await eventHandler(service, method, arguments)
            return .undefined
        case ("realtimeVoiceMultiAgentActivity", "subscribe"):
            _ = try locator(arguments?.first)
            await eventHandler(service, method, arguments)
            return subscriptionTarget()

        case ("realtimeVoicePresentation", "getSnapshot"):
            return presentationSnapshot()
        case ("realtimeVoicePresentation", "registerSurface"):
            try registerPresentationSurface(arguments)
            await eventHandler(service, method, arguments)
            return .rpcObject([:])
        case ("realtimeVoicePresentation", "reportToast"):
            return try await reportToast(arguments)
        case ("realtimeVoicePresentation", "requestSurface"):
            try requestSurface(arguments)
            await eventHandler(service, method, arguments)
            return .undefined
        case ("realtimeVoicePresentation", "subscribe"):
            await eventHandler(service, method, arguments)
            return subscriptionTarget()

        case ("realtimeVoiceRuntime", "registerRealtimeStarter"):
            try await registerRealtimeStarter(arguments)
            await eventHandler(service, method, arguments)
            return .undefined
        case ("realtimeVoiceRuntime", "requestRealtimeStart"):
            try await requestRealtimeStart(arguments)
            return .undefined
        case ("realtimeVoiceRuntime", "cancelRealtimeSessionStart"):
            try await cancelRealtimeSessionStart(arguments)
            return .undefined
        case ("realtimeVoiceRuntime", "completeRealtimeSession"):
            await eventHandler(service, method, arguments)
            return .undefined
        case ("realtimeVoiceRuntime", "unregisterRealtimeStarter"):
            if let realtimeStarter {
                await runtimeCoordinator.unregister(
                    request: realtimeStarter.request,
                    cancel: realtimeStarter.cancel
                )
            }
            realtimeStarter = nil
            await eventHandler(service, method, arguments)
            return .undefined

        default:
            throw Error.unsupportedMethod(
                service: service,
                method: method
            )
        }
    }

    public func voiceSnapshot() -> Value {
        guard let claim = voiceClaim, claim.published else {
            return Self.inactiveVoiceSnapshot
        }
        return claim.snapshot
    }

    public func activities(for locator: Value) -> [Value] {
        guard let key = locatorKey(locator) else {
            return []
        }
        return multiAgentActivities[key] ?? []
    }

    private var continuityURL: URL {
        codexHome.appendingPathComponent(
            "realtime-voice-continuity.json"
        )
    }

    private func readContinuity(
        _ arguments: [Value]?
    ) throws -> Value {
        let fields = try argumentObject(arguments?.first)
        guard let threadID = nonemptyString(fields["threadId"]),
              let maxItems = positiveInt(fields["maxItems"])
        else {
            throw Error.invalidArguments
        }
        let document = loadContinuity()
        let items = Array(
            (document.threads[threadID]?.items ?? [])
                .suffix(maxItems)
        )
        return .array(
            items.map {
                .object([
                    "role": .string($0.role),
                    "text": .string($0.text),
                ])
            }
        )
    }

    private func recordContinuity(
        _ arguments: [Value]?
    ) throws {
        let fields = try argumentObject(arguments?.first)
        let itemFields = try argumentObject(fields["item"])
        guard let threadID = nonemptyString(fields["threadId"]),
              let role = string(itemFields["role"]),
              role == "user" || role == "assistant",
              let rawText = string(itemFields["text"]),
              let maxItems = positiveInt(fields["maxItems"]),
              let maxTextLength =
                positiveInt(fields["maxTextLength"])
        else {
            throw Error.invalidArguments
        }
        let trimmed = rawText.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let text = String(trimmed.prefix(maxTextLength))
        guard !text.isEmpty else {
            return
        }

        var document = loadContinuity()
        var items = document.threads[threadID]?.items ?? []
        items.append(ContinuityItem(role: role, text: text))
        document.threads[threadID] = ContinuityThread(
            items: Array(items.suffix(maxItems))
        )
        try persistContinuity(document)
    }

    private func loadContinuity() -> ContinuityDocument {
        guard let data = try? Data(contentsOf: continuityURL),
              let document = try? JSONDecoder().decode(
                ContinuityDocument.self,
                from: data
              ),
              document.version == 1
        else {
            return .empty
        }
        return document
    }

    private func persistContinuity(
        _ document: ContinuityDocument
    ) throws {
        try FileManager.default.createDirectory(
            at: codexHome,
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var data = try encoder.encode(document)
        data.append(0x0A)
        try data.write(to: continuityURL, options: .atomic)
    }

    private func readMemorySummary() -> Value {
        let url = codexHome
            .appendingPathComponent("memories", isDirectory: true)
            .appendingPathComponent("memory_summary.md")
        guard let text = try? String(contentsOf: url, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty
        else {
            return .null
        }
        return .string(text)
    }

    private func claimVoice(
        _ arguments: [Value]?
    ) throws -> Value {
        guard voiceClaim == nil,
              let arguments,
              arguments.count >= 3
        else {
            return .null
        }
        let locator = try locator(arguments[0])
        guard case .import = arguments[1] else {
            throw Error.invalidArguments
        }
        let preferredSurface = arguments[2]
        guard preferredSurface == .null
                || string(preferredSurface) != nil
        else {
            throw Error.invalidArguments
        }
        let claimID = UUID().uuidString.lowercased()
        voiceClaim = VoiceClaim(
            id: claimID,
            locator: locator,
            preferredPresentationSurface: preferredSurface,
            snapshot: .object([
                "activity": .string("idle"),
                "locator": locator,
                "microphoneMuted": .bool(false),
                "outputMuted": .bool(false),
                "phase": .string("starting"),
                "preferredPresentationSurface": preferredSurface,
                "sessionId": .null,
            ]),
            published: false
        )
        return .string(claimID)
    }

    private func publishVoice(
        _ arguments: [Value]?
    ) async throws {
        guard let arguments,
              arguments.count >= 2,
              let claimID = string(arguments[0]),
              var claim = voiceClaim,
              claim.id == claimID,
              case let .object(fields) = arguments[1],
              let activity = string(fields["activity"]),
              let microphoneMuted = bool(fields["microphoneMuted"]),
              let outputMuted = bool(fields["outputMuted"]),
              let phase = string(fields["phase"])
        else {
            throw Error.invalidArguments
        }
        let oldFields: [String: Value]
        if case let .object(existing) = claim.snapshot {
            oldFields = existing
        } else {
            oldFields = [:]
        }
        claim.snapshot = .object([
            "activity": .string(activity),
            "locator": claim.locator,
            "microphoneMuted": .bool(microphoneMuted),
            "outputMuted": .bool(outputMuted),
            "phase": .string(phase),
            "preferredPresentationSurface":
                claim.preferredPresentationSurface,
            "sessionId": oldFields["sessionId"] ?? .null,
        ])
        claim.published = true
        voiceClaim = claim
        await notifyVoiceSubscribers()
    }

    private func releaseVoice(
        _ arguments: [Value]?
    ) async throws {
        guard let claimID = string(arguments?.first) else {
            throw Error.invalidArguments
        }
        if voiceClaim?.id == claimID {
            voiceClaim = nil
            requestedPresentation = nil
            await notifyVoiceSubscribers()
        }
    }

    private func transferVoice(
        _ arguments: [Value]?
    ) async throws -> Value {
        guard let arguments, arguments.count >= 2 else {
            throw Error.invalidArguments
        }
        let source = try locator(arguments[0])
        let destination: Value?
        if arguments[1] == .null {
            destination = nil
        } else {
            destination = try locator(arguments[1])
        }
        if arguments.count > 2,
           arguments[2] != .null,
           string(arguments[2]) == nil
        {
            throw Error.invalidArguments
        }
        guard var claim = voiceClaim,
              claim.published,
              claim.locator == source
        else {
            return .bool(false)
        }
        guard let destination else {
            voiceClaim = nil
            requestedPresentation = nil
            await notifyVoiceSubscribers()
            await eventHandler("realtimeVoice", "transfer", arguments)
            return .bool(true)
        }
        claim.locator = destination
        if case var .object(snapshot) = claim.snapshot {
            snapshot["locator"] = destination
            claim.snapshot = .object(snapshot)
        }
        voiceClaim = claim
        await notifyVoiceSubscribers()
        await eventHandler("realtimeVoice", "transfer", arguments)
        return .bool(true)
    }

    private func controlVoice(
        _ arguments: [Value]?
    ) async throws -> Value {
        guard let arguments,
              arguments.count >= 2
        else {
            throw Error.invalidArguments
        }
        let requestedLocator = try locator(arguments[0])
        let control = try argumentObject(arguments[1])
        guard var claim = voiceClaim,
              claim.published,
              claim.locator == requestedLocator,
              case let .object(snapshotFields) = claim.snapshot,
              snapshotFields["phase"] != .string("stopping")
        else {
            return .bool(false)
        }
        claim.snapshot = try applying(
            control: control,
            to: claim.snapshot
        )
        voiceClaim = claim
        await notifyVoiceSubscribers()
        await eventHandler(
            "realtimeVoice",
            "control",
            [requestedLocator, .object(control)]
        )
        return .bool(true)
    }

    private func subscribeToVoice(
        _ arguments: [Value]?
    ) async throws {
        guard case let .import(callbackID)? = arguments?.first,
              callbackID != 0,
              let callbackInvoker
        else {
            throw Error.invalidArguments
        }
        voiceSubscribers.insert(callbackID)
        do {
            try await callbackInvoker(callbackID, [voiceSnapshot()])
        } catch {
            voiceSubscribers.remove(callbackID)
            throw error
        }
    }

    private func notifyVoiceSubscribers() async {
        guard let callbackInvoker, !voiceSubscribers.isEmpty else {
            return
        }
        let snapshot = voiceSnapshot()
        var failed: [Int] = []
        for callbackID in voiceSubscribers {
            do {
                try await callbackInvoker(callbackID, [snapshot])
            } catch {
                failed.append(callbackID)
            }
        }
        voiceSubscribers.subtract(failed)
    }

    private func controlActiveVoice(
        _ arguments: [Value]?
    ) async throws -> Value {
        let control = try argumentObject(arguments?.first)
        guard let claim = voiceClaim, claim.published else {
            return .bool(false)
        }
        guard let type = string(control["type"]) else {
            throw Error.invalidArguments
        }
        var resolved = control
        if case let .object(snapshot) = claim.snapshot {
            if type == "toggle-microphone-mute" {
                resolved = [
                    "type": .string("set-microphone-muted"),
                    "muted": .bool(
                        !(bool(snapshot["microphoneMuted"]) ?? false)
                    ),
                ]
            } else if type == "toggle-output-mute" {
                resolved = [
                    "type": .string("set-output-muted"),
                    "muted": .bool(
                        !(bool(snapshot["outputMuted"]) ?? false)
                    ),
                ]
            }
        }
        return try await controlVoice([
            claim.locator,
            .object(resolved),
        ])
    }

    private func applying(
        control: [String: Value],
        to snapshot: Value
    ) throws -> Value {
        guard var fields = object(snapshot),
              let type = string(control["type"])
        else {
            throw Error.invalidArguments
        }
        switch type {
        case "stop":
            fields["phase"] = .string("stopping")
            fields["activity"] = .string("idle")
        case "set-microphone-muted":
            guard let muted = bool(control["muted"]) else {
                throw Error.invalidArguments
            }
            fields["microphoneMuted"] = .bool(muted)
        case "set-output-muted":
            guard let muted = bool(control["muted"]) else {
                throw Error.invalidArguments
            }
            fields["outputMuted"] = .bool(muted)
        case "simulate-usage-limit-approaching-for-debug":
            break
        default:
            throw Error.invalidArguments
        }
        return .object(fields)
    }

    private func recordRealDelegation(
        _ arguments: [Value]?
    ) async throws -> Value {
        guard let arguments,
              arguments.count >= 2
        else {
            throw Error.invalidArguments
        }
        let requestedLocator = try locator(arguments[0])
        guard let claim = voiceClaim,
              claim.published,
              claim.locator == requestedLocator
        else {
            return .undefined
        }
        await eventHandler(
            "realtimeVoice",
            "recordRealDelegation",
            arguments
        )
        return .undefined
    }

    private func publishMultiAgentActivity(
        _ arguments: [Value]?
    ) throws {
        guard let activity = arguments?.first,
              let fields = object(activity),
              let id = nonemptyString(fields["id"]),
              let thread = fields["realtimeThread"],
              let key = locatorKey(thread)
        else {
            throw Error.invalidArguments
        }
        var activities = multiAgentActivities[key] ?? []
        guard !activities.contains(where: {
            guard let fields = object($0) else { return false }
            return string(fields["id"]) == id
        }) else {
            return
        }
        activities.insert(activity, at: 0)
        multiAgentActivities[key] = Array(activities.prefix(100))
    }

    private func registerPresentationSurface(
        _ arguments: [Value]?
    ) throws {
        guard let arguments,
              arguments.count >= 5,
              let surface = nonemptyString(arguments[1]),
              bool(arguments[2]) != nil,
              bool(arguments[3]) != nil
        else {
            throw Error.invalidArguments
        }
        let locator = try locator(arguments[0])
        guard case .import = arguments[4],
              let key = locatorKey(locator)
        else {
            throw Error.invalidArguments
        }
        registeredPresentationSurfaces.insert("\(key)|\(surface)")
    }

    private func reportToast(
        _ arguments: [Value]?
    ) async throws -> Value {
        guard let arguments,
              arguments.count >= 2
        else {
            throw Error.invalidArguments
        }
        let requestedLocator = try locator(arguments[0])
        guard let active = activePresentation(),
              active.locator == requestedLocator,
              let key = locatorKey(active.locator),
              registeredPresentationSurfaces.contains(
                "\(key)|\(active.surface)"
              )
        else {
            return .bool(false)
        }
        await eventHandler(
            "realtimeVoicePresentation",
            "reportToast",
            arguments
        )
        return .bool(true)
    }

    private func requestSurface(
        _ arguments: [Value]?
    ) throws {
        guard let arguments,
              arguments.count >= 2,
              let surface = nonemptyString(arguments[1])
        else {
            throw Error.invalidArguments
        }
        let requestedLocator = try locator(arguments[0])
        if let claim = voiceClaim,
           claim.published,
           claim.locator == requestedLocator
        {
            requestedPresentation = .object([
                "locator": requestedLocator,
                "surface": .string(surface),
            ])
        }
    }

    private func registerRealtimeStarter(
        _ arguments: [Value]?
    ) async throws {
        guard let arguments,
              arguments.count >= 2,
              case let .import(requestCallback) = arguments[0],
              case let .import(cancelCallback) = arguments[1],
              requestCallback != 0,
              cancelCallback != 0
        else {
            throw Error.invalidArguments
        }
        let ready: Bool
        if arguments.count > 2 {
            guard case let .bool(workspaceReady) = arguments[2] else {
                throw Error.invalidArguments
            }
            ready = workspaceReady
        } else {
            ready = true
        }
        realtimeStarter = (
            request: requestCallback,
            cancel: cancelCallback
        )
        if let callbackInvoker {
            await runtimeCoordinator.register(
                request: requestCallback,
                cancel: cancelCallback,
                ready: ready,
                callbackInvoker: callbackInvoker
            )
        }
    }

    private func requestRealtimeStart(
        _ arguments: [Value]?
    ) async throws {
        guard let arguments,
              let request = arguments.first,
              arguments.count <= 2,
              arguments.dropFirst().allSatisfy({
                  $0 == .undefined || $0 == .null || string($0) != nil
              })
        else {
            throw Error.invalidArguments
        }
        let launchID = arguments.dropFirst().first.flatMap(string)
        try await runtimeCoordinator.requestStart(
            request: request,
            launchID: launchID,
            eventHandler: eventHandler
        )
    }

    private func cancelRealtimeSessionStart(
        _ arguments: [Value]?
    ) async throws {
        guard arguments == nil || arguments?.isEmpty == true else {
            throw Error.invalidArguments
        }
        try await runtimeCoordinator.cancel(
            eventHandler: eventHandler
        )
    }

    private func presentationSnapshot() -> Value {
        guard let active = activePresentation() else {
            return .object(["active": .null])
        }
        return .object([
            "active": .object([
                "locator": active.locator,
                "surface": .string(active.surface),
                "handoff": .null,
            ])
        ])
    }

    private func activePresentation()
        -> (locator: Value, surface: String)?
    {
        if let requestedPresentation,
           let fields = object(requestedPresentation),
           let locator = fields["locator"],
           let surface = string(fields["surface"])
        {
            return (locator, surface)
        }
        guard let claim = voiceClaim,
              claim.published,
              let surface = string(
                claim.preferredPresentationSurface
              )
        else {
            return nil
        }
        return (claim.locator, surface)
    }

    private func subscriptionTarget() -> Value {
        .rpcObject(["unsubscribe": .rpcObject([:])])
    }

    @discardableResult
    private func locator(_ value: Value?) throws -> Value {
        guard let value,
              let fields = object(value),
              nonemptyString(fields["hostId"]) != nil,
              nonemptyString(fields["conversationId"]) != nil
        else {
            throw Error.invalidArguments
        }
        return value
    }

    private func locatorKey(_ value: Value?) -> String? {
        guard let fields = object(value),
              let hostID = nonemptyString(fields["hostId"]),
              let conversationID =
                nonemptyString(fields["conversationId"])
        else {
            return nil
        }
        return "\(hostID)\u{0}\(conversationID)"
    }

    private func argumentObject(
        _ value: Value?
    ) throws -> [String: Value] {
        guard let fields = object(value) else {
            throw Error.invalidArguments
        }
        return fields
    }

    private func object(_ value: Value?) -> [String: Value]? {
        guard case let .object(fields)? = value else {
            return nil
        }
        return fields
    }

    private func string(_ value: Value?) -> String? {
        guard case let .string(value)? = value else {
            return nil
        }
        return value
    }

    private func nonemptyString(_ value: Value?) -> String? {
        guard let value = string(value)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty
        else {
            return nil
        }
        return value
    }

    private func bool(_ value: Value?) -> Bool? {
        guard case let .bool(value)? = value else {
            return nil
        }
        return value
    }

    private func positiveInt(_ value: Value?) -> Int? {
        guard case let .integer(raw)? = value,
              raw > 0,
              raw <= Int64(Int.max)
        else {
            return nil
        }
        return Int(raw)
    }
}
