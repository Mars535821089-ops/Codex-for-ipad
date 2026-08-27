import Foundation

/// Stateful AppHost behavior for desktop window concepts that map onto the
/// single iPad scene, plus the released dynamic-tool execution claim guard.
public actor CodexDesktopInteractionAppHostService {
    public typealias Value = CodexDesktopAppHostRPC.Value
    public typealias EventHandler =
        @Sendable (String, String, [Value]?) async -> Void
    public typealias ApplicationMenuSnapshot = Value?
    public typealias PrimaryWindowActionRunner =
        @Sendable (Value, String?, String?) async throws -> Value
    public typealias PrimaryThreadEnqueuer =
        @Sendable (Value) async throws -> Void

    public enum Error: Swift.Error, Equatable, Sendable {
        case invalidArguments
        case unsupportedMethod(service: String, method: String)
    }

    public private(set) var hotkeyWindowEnabled = false
    public private(set) var hotkeyWindowPath: String?
    public private(set) var hotkeyWindowConfiguredHotkey: String?
    public private(set) var hotkeyWindowDevOverrideEnabled = false
    public private(set) var quickChatPrewarmed = false
    public private(set) var quickChatConversationID: String?
    public private(set) var quickChatRendererReadyConversationID: String?
    public private(set) var quickChatPrewarmedRendererReady = false

    private let primaryRuntimeVersion: String?
    private let primaryRuntimeInstalled: Bool
    private let applicationMenuSnapshot: ApplicationMenuSnapshot
    private let runPrimaryWindowAction: PrimaryWindowActionRunner
    private let enqueuePrimaryThreadAction: PrimaryThreadEnqueuer
    private let eventHandler: EventHandler
    private var claimedCallKeys: Set<String> = []
    private var claimedCallOrder: [String] = []

    public init(
        primaryRuntimeVersion: String? = nil,
        primaryRuntimeInstalled: Bool = false,
        applicationMenuSnapshot: ApplicationMenuSnapshot = .object([
            "file": .array([]),
            "edit": .array([]),
            "view": .array([]),
            "help": .array([]),
        ]),
        runPrimaryWindowAction: PrimaryWindowActionRunner? = nil,
        enqueuePrimaryThreadAction: PrimaryThreadEnqueuer? = nil,
        eventHandler: EventHandler? = nil
    ) {
        self.primaryRuntimeVersion = primaryRuntimeVersion
        self.primaryRuntimeInstalled = primaryRuntimeInstalled
        self.applicationMenuSnapshot = applicationMenuSnapshot
        self.runPrimaryWindowAction = runPrimaryWindowAction ?? { _, _, _ in
            .undefined
        }
        self.enqueuePrimaryThreadAction = enqueuePrimaryThreadAction ?? { _ in }
        self.eventHandler = eventHandler ?? { _, _, _ in }
    }

    public func invoke(
        service: String,
        method: String,
        arguments: [Value]?
    ) async throws -> Value {
        switch (service, method) {
        case ("dynamicToolCalls", "tryClaimExecution"):
            let fields = try argumentObject(arguments)
            guard let callID = Self.string(fields["callId"]),
                  let hostID = Self.string(fields["hostId"]),
                  let threadID = Self.string(fields["threadId"]),
                  let turnID = Self.string(fields["turnId"])
            else {
                throw Error.invalidArguments
            }
            let key = "\(hostID):\(threadID):\(turnID):\(callID)"
            guard claimedCallKeys.insert(key).inserted else {
                return .bool(false)
            }
            claimedCallOrder.append(key)
            if claimedCallOrder.count > 1_024 {
                let oldest = claimedCallOrder.removeFirst()
                claimedCallKeys.remove(oldest)
            }
            return .bool(true)

        case ("hotkeyWindowHotkeys", "getState"):
            // iPadOS has no process-global desktop hotkey. The renderer
            // expects the complete released state shape even when unsupported.
            return .object([
                "supported": .bool(false),
                "configuredHotkey": hotkeyWindowConfiguredHotkey
                    .map(Value.string) ?? .null,
                "isGateEnabled": .bool(false),
                "isDevMode": .bool(false),
                "isDevOverrideEnabled":
                    .bool(hotkeyWindowDevOverrideEnabled),
                "isActive": .bool(false),
            ])

        case ("hotkeyWindowHotkeys", "setEnabled"):
            guard case let .bool(enabled)? = arguments?.first else {
                throw Error.invalidArguments
            }
            hotkeyWindowEnabled = enabled
            await eventHandler(service, method, arguments)
            return .undefined

        case ("hotkeyWindowHotkeys", "toggle"):
            hotkeyWindowEnabled.toggle()
            await eventHandler(service, method, arguments)
            return .undefined

        case ("hotkeyWindowHotkeys", "setHotkey"):
            guard arguments?.count == 1 else {
                throw Error.invalidArguments
            }
            switch arguments?[0] {
            case .null:
                hotkeyWindowConfiguredHotkey = nil
            case let .string(value) where !value.isEmpty:
                hotkeyWindowConfiguredHotkey = value
            default:
                throw Error.invalidArguments
            }
            await eventHandler(service, method, arguments)
            return .undefined

        case ("hotkeyWindowHotkeys", "setDevOverrideEnabled"):
            guard case let .bool(enabled)? = arguments?.first,
                  arguments?.count == 1
            else {
                throw Error.invalidArguments
            }
            hotkeyWindowDevOverrideEnabled = enabled
            await eventHandler(service, method, arguments)
            return .undefined

        case ("hotkeyWindowHotkeys", "open"):
            let fields = try argumentObject(arguments)
            guard let path = Self.string(fields["path"]) else {
                throw Error.invalidArguments
            }
            hotkeyWindowPath = path
            await eventHandler(service, method, arguments)
            return .undefined

        case ("hotkeyWindowHotkeys", "collapseToHome"):
            hotkeyWindowPath = "/"
            await eventHandler(service, method, arguments)
            return .undefined

        case ("hotkeyWindowHotkeys", "dismiss"):
            hotkeyWindowPath = nil
            await eventHandler(service, method, arguments)
            return .undefined

        case ("hotkeyWindowHotkeys", "transitionDone"):
            _ = try argumentObject(arguments)
            await eventHandler(service, method, arguments)
            return .undefined

        case ("hotkeyWindowHotkeys", "homeDragStart"),
             ("hotkeyWindowHotkeys", "homeDragMove"),
             ("hotkeyWindowHotkeys", "homeDragEnd"),
             ("hotkeyWindowHotkeys", "homeLayoutChanged"),
             ("hotkeyWindowHotkeys", "homePointerInteractionChanged"):
            _ = try argumentObject(arguments)
            await eventHandler(service, method, arguments)
            return .undefined

        case ("quickChatWindow", "prewarm"):
            quickChatPrewarmed = true
            await eventHandler(service, method, arguments)
            return .undefined

        case ("quickChatWindow", "clearPrewarm"):
            quickChatPrewarmed = false
            await eventHandler(service, method, arguments)
            return .undefined

        case ("quickChatWindow", "open"):
            let fields = try argumentObject(arguments)
            quickChatConversationID = Self.string(
                fields["conversationId"]
            )
            quickChatPrewarmed = false
            await eventHandler(service, method, arguments)
            return .undefined

        case ("quickChatWindow", "addToComposer"):
            let fields = try argumentObject(arguments)
            guard arguments?.count == 1,
                  let conversationID = Self.string(
                    fields["conversationId"]
                  ),
                  !conversationID.isEmpty
            else {
                throw Error.invalidArguments
            }
            // The released renderer sends the current title, which may be
            // absent while a new Quick Chat is still being titled. Preserve
            // that nullable string shape instead of inventing a title.
            switch fields["title"] {
            case nil, .null, .string:
                break
            default:
                throw Error.invalidArguments
            }
            quickChatConversationID = conversationID
            await eventHandler(service, method, arguments)
            return .undefined

        case ("quickChatWindow", "rendererReady"):
            guard arguments?.count == 1 else {
                throw Error.invalidArguments
            }
            switch arguments?[0] {
            case .null:
                quickChatRendererReadyConversationID = nil
                quickChatPrewarmedRendererReady = true
            case let .string(conversationID):
                guard !conversationID.isEmpty else {
                    throw Error.invalidArguments
                }
                quickChatRendererReadyConversationID = conversationID
                quickChatPrewarmedRendererReady = false
            default:
                throw Error.invalidArguments
            }
            await eventHandler(service, method, arguments)
            return .undefined

        case ("primaryRuntime", "getInstalledBundleVersion"):
            return primaryRuntimeVersion.map(Value.string) ?? .null

        case ("primaryRuntime", "diagnoseDependencies"):
            let fields = try argumentObject(arguments)
            guard Self.string(fields["hostId"]) == "local" else {
                throw Error.invalidArguments
            }
            return .object([
                "artifactToolVersion": .null,
                "bundleVersion":
                    primaryRuntimeVersion.map(Value.string) ?? .null,
                "installed": .bool(primaryRuntimeInstalled),
                "libreOfficeVersion": .null,
                "problems": .array([]),
            ])

        case ("primaryRuntime", "finishInstall"):
            let fields = try argumentObject(arguments)
            guard Self.string(fields["hostId"]) == "local",
                  let release = Self.string(fields["release"]),
                  !release.isEmpty,
                  primaryRuntimeInstalled,
                  let bundleVersion = primaryRuntimeVersion,
                  !bundleVersion.isEmpty
            else {
                throw Error.invalidArguments
            }
            // The iPad runtime is shipped inside the signed application
            // bundle, so there is no separate desktop archive to install.
            // Preserve the released AppHost result shape while reporting the
            // real state: the requested runtime is already present.
            return .object([
                "bundleVersion": .string(bundleVersion),
                "status": .string("already-current"),
            ])

        case ("appActions", "enqueueForThreadInPrimaryWindow"):
            guard let action = arguments?.first, arguments?.count == 1 else {
                throw Error.invalidArguments
            }
            try await enqueuePrimaryThreadAction(action)
            await eventHandler(service, method, arguments)
            return .undefined

        case ("appActions", "runInPrimaryWindow"):
            let fields = try argumentObject(arguments)
            guard arguments?.count == 1,
                  let action = fields["action"],
                  case .object = action
            else {
                throw Error.invalidArguments
            }
            let result = try await runPrimaryWindowAction(
                action,
                Self.string(fields["sourceHostId"]),
                Self.string(fields["sourceThreadId"])
            )
            await eventHandler(service, method, arguments)
            return result

        case ("appActions", "getPrimaryAppView"):
            // Electron exposes the primary AppView object internally. iPadOS
            // has a single native surface, so return a stable capability
            // marker rather than fabricating a second desktop window.
            return .object([
                "available": .bool(true),
                "platform": .string("ipad"),
            ])

        case ("applicationMenu", "getSnapshot"):
            return applicationMenuSnapshot ?? .null

        case ("applicationMenu", "invokeItem"):
            guard case .integer? = arguments?.first else {
                throw Error.invalidArguments
            }
            await eventHandler(service, method, arguments)
            return .undefined

        case ("fileDrags", "prepareDrag"):
            let fields = try argumentObject(arguments)
            guard Self.string(fields["hostId"]) != nil,
                  Self.string(fields["path"]) != nil
            else {
                throw Error.invalidArguments
            }
            await eventHandler(service, method, arguments)
            return .undefined

        case ("keyboardModifiers", "watchMetaRelease"):
            // iPad keyboards do not retain a process-global Command-key
            // latch; resolving immediately represents the released state.
            return .undefined

        default:
            throw Error.unsupportedMethod(
                service: service,
                method: method
            )
        }
    }

    private func argumentObject(
        _ arguments: [Value]?
    ) throws -> [String: Value] {
        guard case let .object(fields)? = arguments?.first else {
            throw Error.invalidArguments
        }
        return fields
    }

    private static func string(_ value: Value?) -> String? {
        guard case let .string(string)? = value else {
            return nil
        }
        return string
    }
}
