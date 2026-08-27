import Foundation

/// iPadOS counterparts for released desktop services whose implementation is
/// optional or platform-specific in the desktop host.
///
/// The public Codex build exports these service names even when the underlying
/// macOS-only recorder, memory diagnostics, or Codex Micro device is absent.
/// Callers can inject real iPad platform operations while the defaults expose
/// the same honest "not available/not detected" state as the desktop host.
public actor CodexDesktopOptionalPlatformAppHostService {
    public typealias Value = CodexDesktopAppHostRPC.Value
    public typealias Operation =
        @Sendable (String, [Value]?) async throws -> Value
    public typealias AvatarInputShapeHandler =
        @Sendable ([CodexDesktopAvatarOverlayInputRegion]) async -> Void

    public enum Error: Swift.Error, Equatable, Sendable {
        case invalidArguments
        case unavailable(service: String, method: String)
        case unsupportedMethod(service: String, method: String)
    }

    public static let notDetectedCodexMicroState: Value = .object([
        "status": .string("not-detected"),
        "transport": .null,
        "model": .null,
        "error": .null,
        "battery": .null,
    ])

    private static let disabledChronicleState: Value = .object([
        "enabled": .bool(false),
        "recorderState": .string("stopped"),
        "activationState": .string("idle"),
    ])

    private let chronicleOperation: Operation?
    private let codexMicroOperation: Operation?
    private let debugOperation: Operation?
    private let avatarInputShapeHandler: AvatarInputShapeHandler?
    private var remoteHostedPIPRevision: Int64 = 0
    private var remoteHostedPIPGlobalHidden = true
    private var remoteHostedPIPTaskVisibilities: [String: String] = [:]
    public private(set) var avatarInputShape: Value?

    public init(
        chronicleOperation: Operation? = nil,
        codexMicroOperation: Operation? = nil,
        debugOperation: Operation? = nil,
        avatarInputShapeHandler: AvatarInputShapeHandler? = nil
    ) {
        self.chronicleOperation = chronicleOperation
        self.codexMicroOperation = codexMicroOperation
        self.debugOperation = debugOperation
        self.avatarInputShapeHandler = avatarInputShapeHandler
    }

    public func invoke(
        service: String,
        method: String,
        arguments: [Value]?
    ) async throws -> Value {
        switch service {
        case "avatarOverlay":
            guard method == "setInputShape" else {
                throw Error.unsupportedMethod(
                    service: service,
                    method: method
                )
            }
            guard let shape = arguments?.first else {
                throw Error.invalidArguments
            }
            let regions: [CodexDesktopAvatarOverlayInputRegion]
            do {
                regions = try CodexDesktopAvatarOverlayInputRegion
                    .decode(shape)
            } catch {
                throw Error.invalidArguments
            }
            avatarInputShape = shape
            await avatarInputShapeHandler?(regions)
            return .undefined
        case "chronicle":
            return try await invokeChronicle(
                method: method,
                arguments: arguments
            )
        case "codexMicro":
            return try await invokeCodexMicro(
                method: method,
                arguments: arguments
            )
        case "debug":
            return try await invokeDebug(
                method: method,
                arguments: arguments
            )
        case "owlBrowserCrashCounter":
            return try invokeOwlBrowserCrashCounter(method: method)
        case "remoteHostedPIP":
            return try invokeRemoteHostedPIP(
                method: method,
                arguments: arguments
            )
        default:
            throw Error.unsupportedMethod(
                service: service,
                method: method
            )
        }
    }

    private func invokeChronicle(
        method: String,
        arguments: [Value]?
    ) async throws -> Value {
        let methods: Set<String> = [
            "clearHistory",
            "getSettings",
            "getState",
            "listApplications",
            "listHistory",
            "listHistorySuggestions",
            "listHistorySummaryIntervals",
            "pause",
            "resolveApplications",
            "resume",
            "retryActivation",
            "setEnabled",
            "updateSettings",
        ]
        guard methods.contains(method) else {
            throw Error.unsupportedMethod(
                service: "chronicle",
                method: method
            )
        }
        switch method {
        case "setEnabled":
            guard case .bool? = arguments?.first else {
                throw Error.invalidArguments
            }
        case "updateSettings":
            guard case .object? = arguments?.first else {
                throw Error.invalidArguments
            }
        case "resolveApplications":
            guard case .array? = arguments?.first else {
                throw Error.invalidArguments
            }
        case "listHistorySummaryIntervals":
            guard case let .object(argument)? = arguments?.first,
                  let sinceMs = argument["sinceMs"],
                  Self.isNumber(sinceMs)
            else {
                throw Error.invalidArguments
            }
        default:
            break
        }

        if let chronicleOperation {
            return try await chronicleOperation(method, arguments)
        }
        switch method {
        case "getState", "retryActivation", "pause", "resume":
            return Self.disabledChronicleState
        case "setEnabled":
            guard arguments?.first == .bool(false) else {
                throw Error.unavailable(
                    service: "chronicle",
                    method: method
                )
            }
            return Self.disabledChronicleState
        case "getSettings":
            return .object([:])
        case "updateSettings":
            return arguments?.first ?? .object([:])
        case "listApplications", "resolveApplications", "listHistory":
            return .array([])
        case "listHistorySuggestions", "listHistorySummaryIntervals":
            // Chronicle's recorder is macOS-only, but the released renderer
            // expects these queries to resolve to arrays when the service is
            // present.  Returning an empty, schema-valid result keeps the
            // iPad surface deterministic without fabricating history data;
            // a real recorder can still be injected through the operation.
            return .array([])
        case "clearHistory":
            return .undefined
        default:
            fatalError("validated chronicle method")
        }
    }

    private func invokeCodexMicro(
        method: String,
        arguments: [Value]?
    ) async throws -> Value {
        let methods: Set<String> = [
            "getInputMonitoringPermissionStatus",
            "getState",
            "openInputMonitoringSettings",
            "ownsPrimaryWindow",
            "updateAgentThreadKeys",
            "updateLighting",
        ]
        guard methods.contains(method) else {
            throw Error.unsupportedMethod(
                service: "codexMicro",
                method: method
            )
        }
        switch method {
        case "updateAgentThreadKeys":
            guard let arguments,
                  arguments.count >= 2,
                  case .array = arguments[0],
                  case .array = arguments[1],
                  arguments.count < 3
                    || Self.bool(arguments[2]) != nil
            else {
                throw Error.invalidArguments
            }
        case "updateLighting":
            guard arguments?.first != nil else {
                throw Error.invalidArguments
            }
        default:
            break
        }

        if let codexMicroOperation {
            let value = try await codexMicroOperation(
                method,
                arguments
            )
            if method != "getState" || value != .undefined {
                return value
            }
        }
        switch method {
        case "getState":
            return Self.notDetectedCodexMicroState
        case "getInputMonitoringPermissionStatus":
            // iPadOS has no process-wide input-monitoring permission gate;
            // physical-keyboard events are delivered directly to the app.
            return .string("unavailable")
        case "ownsPrimaryWindow":
            return .bool(true)
        case "updateAgentThreadKeys", "updateLighting":
            return .bool(false)
        case "openInputMonitoringSettings":
            return .undefined
        default:
            fatalError("validated Codex Micro method")
        }
    }

    private func invokeDebug(
        method: String,
        arguments: [Value]?
    ) async throws -> Value {
        let unavailableMethods: Set<String> = [
            "captureMemoryAllocationProfiles",
            "captureMemoryHeapSnapshots",
            "getMemoryDiagnosticsStatus",
            "revealMemoryDiagnosticsDirectory",
            "setMemoryDiagnosticsConfig",
        ]
        if unavailableMethods.contains(method) {
            throw Error.unavailable(
                service: "debug",
                method: method
            )
        }
        let methods: Set<String> = [
            "exportLogs",
            "getBrowserSnapshot",
            "openBrowserTabOwner",
            "openWindow",
            "resetUpdateSsoState",
        ]
        guard methods.contains(method) else {
            throw Error.unsupportedMethod(
                service: "debug",
                method: method
            )
        }
        if method == "exportLogs" {
            guard case .object? = arguments?.first else {
                throw Error.invalidArguments
            }
        }
        if let debugOperation {
            return try await debugOperation(method, arguments)
        }
        switch method {
        case "getBrowserSnapshot":
            return .object([
                "tabs": .array([]),
                "windows": .array([]),
            ])
        default:
            return .undefined
        }
    }

    private func invokeOwlBrowserCrashCounter(
        method: String
    ) throws -> Value {
        guard method == "subscribe" || method == "unsubscribe" else {
            throw Error.unsupportedMethod(
                service: "owlBrowserCrashCounter",
                method: method
            )
        }
        // iPad WebKit does not expose Chromium child-process crash counters.
        // Keeping the subscription alive with no emitted events matches a
        // primary desktop renderer that has observed zero Owl crashes.
        return .undefined
    }

    private func invokeRemoteHostedPIP(
        method: String,
        arguments: [Value]?
    ) throws -> Value {
        switch method {
        case "getState":
            break
        case "showTask", "hideTask":
            guard let conversationID = Self.string(arguments?.first) else {
                throw Error.invalidArguments
            }
            let visibility = method == "showTask" ? "shown" : "hidden"
            if method == "showTask" {
                remoteHostedPIPGlobalHidden = false
            }
            if remoteHostedPIPTaskVisibilities[conversationID]
                != visibility
            {
                remoteHostedPIPTaskVisibilities[conversationID] = visibility
                remoteHostedPIPRevision += 1
            }
        case "hideForAllActiveTasks":
            if !remoteHostedPIPGlobalHidden {
                remoteHostedPIPGlobalHidden = true
                remoteHostedPIPRevision += 1
            }
        case "importLegacyHiddenTaskIds":
            guard case let .array(values)? = arguments?.first else {
                throw Error.invalidArguments
            }
            for value in values {
                guard let conversationID = Self.string(value) else {
                    throw Error.invalidArguments
                }
                if remoteHostedPIPTaskVisibilities[conversationID]
                    != "hidden"
                {
                    remoteHostedPIPTaskVisibilities[conversationID] =
                        "hidden"
                    remoteHostedPIPRevision += 1
                }
            }
        case "completeTurn":
            guard let conversationID = Self.string(arguments?.first) else {
                throw Error.invalidArguments
            }
            if remoteHostedPIPTaskVisibilities.removeValue(
                forKey: conversationID
            ) != nil {
                remoteHostedPIPRevision += 1
            }
        default:
            throw Error.unsupportedMethod(
                service: "remoteHostedPIP",
                method: method
            )
        }
        return remoteHostedPIPState()
    }

    private func remoteHostedPIPState() -> Value {
        .object([
            // The desktop renderer treats this field as a required array and
            // calls `includes` on it without guarding the property itself.
            // iPad currently has no browser/computer-use PiP activity source,
            // so the truthful platform state is an empty active-task set.
            "activeTaskIds": .array([]),
            "globalHidden": .bool(remoteHostedPIPGlobalHidden),
            "revision": .integer(remoteHostedPIPRevision),
            "taskVisibilities": .object(
                remoteHostedPIPTaskVisibilities.mapValues(Value.string)
            ),
        ])
    }

    private static func bool(_ value: Value) -> Bool? {
        guard case let .bool(bool) = value else {
            return nil
        }
        return bool
    }

    private static func isNumber(_ value: Value) -> Bool {
        switch value {
        case .integer, .number:
            return true
        default:
            return false
        }
    }

    private static func string(_ value: Value?) -> String? {
        guard case let .string(string)? = value else {
            return nil
        }
        return string
    }
}
