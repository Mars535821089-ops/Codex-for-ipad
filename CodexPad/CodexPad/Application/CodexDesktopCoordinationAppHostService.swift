#if SWIFT_PACKAGE
import CodexPadDomain
import CodexPadProtocolBridge
#endif
import Foundation

/// iPad-native persistence for the released Computer Use preferences and the
/// single-scene equivalent of the desktop renderer coordination bus.
public actor CodexDesktopCoordinationAppHostService {
    public typealias Value = CodexDesktopAppHostRPC.Value
    public typealias EventHandler =
        @Sendable (String, String, [Value]?) async -> Void

    public struct ThreadState: Equatable, Sendable {
        public var ownsThread: Bool?
        public var following: Bool?
        public var hasUnreadTurn: Bool?
        public var archived: Bool?
        public var streamChange: Value?

        public init(
            ownsThread: Bool? = nil,
            following: Bool? = nil,
            hasUnreadTurn: Bool? = nil,
            archived: Bool? = nil,
            streamChange: Value? = nil
        ) {
            self.ownsThread = ownsThread
            self.following = following
            self.hasUnreadTurn = hasUnreadTurn
            self.archived = archived
            self.streamChange = streamChange
        }
    }

    public enum Error: Swift.Error, Equatable, Sendable {
        case invalidArguments
        case unsupportedMethod(service: String, method: String)
    }

    private enum Key {
        static let approvedBundleIdentifiers =
            "CodexDesktopComputerUse.approvedBundleIdentifiers"
        static let approvedChats =
            "CodexDesktopComputerUse.approvedChats"
        static let soundMode =
            "CodexDesktopComputerUse.soundMode"
        static let lockedUseEnabled =
            "CodexDesktopComputerUse.lockedUseEnabled"
    }

    private let userDefaults: UserDefaults
    private let eventHandler: EventHandler
    private var threadStates: [String: ThreadState] = [:]
    private var queuedFollowUpsByConversationID:
        [String: Value] = [:]

    public init(
        userDefaultsSuiteName: String? = nil,
        eventHandler: EventHandler? = nil
    ) {
        userDefaults = userDefaultsSuiteName.flatMap(UserDefaults.init(
            suiteName:
        )) ?? .standard
        self.eventHandler = eventHandler ?? { _, _, _ in }
    }

    public func invoke(
        service: String,
        method: String,
        arguments: [Value]?
    ) async throws -> Value {
        switch (service, method) {
        case ("computerUseSettings", "getAppApprovals"):
            return appApprovals()

        case ("computerUseSettings", "removeAppApproval"):
            guard let bundleIdentifier = Self.string(
                arguments?.first
            ) else {
                throw Error.invalidArguments
            }
            let identifiers = approvedBundleIdentifiers().filter {
                $0 != bundleIdentifier
            }
            userDefaults.set(
                identifiers,
                forKey: Key.approvedBundleIdentifiers
            )
            return appApprovals(identifiers)

        case ("computerUseSettings", "getMessagesSendApprovals"):
            return messagesSendApprovals()

        case (
            "computerUseSettings",
            "removeMessagesSendApproval"
        ):
            guard let chatGUID = Self.string(arguments?.first) else {
                throw Error.invalidArguments
            }
            var chats = approvedChats()
            chats.removeValue(forKey: chatGUID)
            userDefaults.set(chats, forKey: Key.approvedChats)
            return messagesSendApprovals(chats)

        case ("computerUseSettings", "getSoundMode"):
            return userDefaults.string(forKey: Key.soundMode)
                .map(Value.string) ?? .null

        case ("computerUseSettings", "setSoundMode"):
            guard let soundMode = Self.string(arguments?.first) else {
                throw Error.invalidArguments
            }
            userDefaults.set(soundMode, forKey: Key.soundMode)
            return .string(soundMode)

        case ("computerUseSettings", "getLockedUseState"):
            return lockedUseState()

        case ("computerUseSettings", "setLockedUseEnabled"):
            guard case let .bool(enabled)? = arguments?.first else {
                throw Error.invalidArguments
            }
            userDefaults.set(enabled, forKey: Key.lockedUseEnabled)
            return .bool(enabled)

        case (
            "computerUseSettings",
            "openChromeExtensionInstallPage"
        ):
            await eventHandler(service, method, arguments)
            return .undefined

        case ("clientCoordination", "findThreadOwner"):
            let fields = try Self.argumentObject(arguments)
            guard Self.string(fields["hostId"]) != nil,
                  Self.string(fields["conversationId"]) != nil
            else {
                throw Error.invalidArguments
            }
            // One iPad scene has no competing renderer client. Desktop
            // returns null when its owner-discovery request finds no client.
            return .null

        case ("clientCoordination", "getIdeContext"):
            let fields = try Self.argumentObject(arguments)
            guard let workspaceRoot = Self.string(
                fields["workspaceRoot"]
            ) else {
                throw Error.invalidArguments
            }
            // There is no external IDE process on iPad. Preserve the active
            // workspace identity used by the released composer context.
            return .object([
                "workspaceRoot": .string(workspaceRoot)
            ])

        case ("clientCoordination", "invalidateQueryCache"):
            _ = try Self.rendererEvent(
                method: method,
                arguments: arguments
            )
            await eventHandler(service, method, arguments)
            return .undefined

        case (
            "clientCoordination",
            "threadQueuedFollowUpsChanged"
        ):
            let fields = try Self.argumentObject(arguments)
            guard let conversationID = Self.string(
                fields["conversationId"]
            ),
            case let .array(messages)? = fields["messages"]
            else {
                throw Error.invalidArguments
            }
            queuedFollowUpsByConversationID[conversationID] =
                .array(messages)
            await eventHandler(service, method, arguments)
            return .undefined

        case ("clientCoordination", let coordinationMethod):
            try updateThreadState(
                method: coordinationMethod,
                arguments: arguments
            )
            await eventHandler(service, method, arguments)
            return .undefined

        default:
            throw Error.unsupportedMethod(
                service: service,
                method: method
            )
        }
    }

    public func threadState(
        hostID: String,
        conversationID: String
    ) -> ThreadState? {
        threadStates[Self.threadKey(
            hostID: hostID,
            conversationID: conversationID
        )]
    }

    public func queuedFollowUps(
        conversationID: String
    ) -> Value? {
        queuedFollowUpsByConversationID[conversationID]
    }

    /// Projects renderer-facing coordination broadcasts using the same event
    /// name and payload shape as the released desktop AppHost.
    public static func rendererEvent(
        method: String,
        arguments: [Value]?
    ) throws -> CodexDesktopHostMessage? {
        guard method == "invalidateQueryCache" else {
            return nil
        }
        let fields = try argumentObject(arguments)
        guard case .array? = fields["queryKey"] else {
            throw Error.invalidArguments
        }
        return .event(
            type: "query-cache-invalidate",
            payload: try jsonValue(.object(fields))
        )
    }

    private func approvedBundleIdentifiers() -> [String] {
        let values = userDefaults.stringArray(
            forKey: Key.approvedBundleIdentifiers
        ) ?? []
        var seen: Set<String> = []
        return values.compactMap { value in
            let normalized = value.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            guard !normalized.isEmpty,
                  seen.insert(normalized).inserted
            else {
                return nil
            }
            return normalized
        }
    }

    private func appApprovals(
        _ identifiers: [String]? = nil
    ) -> Value {
        let identifiers = identifiers ?? approvedBundleIdentifiers()
        return .object([
            "approvedApps": .array(
                identifiers.map { identifier in
                    .object([
                        "bundleIdentifier": .string(identifier),
                        "displayName": .string(identifier),
                        "iconDataURL": .null,
                    ])
                }
            ),
            "approvedBundleIdentifiers": .array(
                identifiers.map(Value.string)
            ),
        ])
    }

    private func approvedChats() -> [String: String] {
        userDefaults.dictionary(
            forKey: Key.approvedChats
        )?.compactMapValues { $0 as? String } ?? [:]
    }

    private func messagesSendApprovals(
        _ chats: [String: String]? = nil
    ) -> Value {
        let chats = chats ?? approvedChats()
        let unsortedValues: [(guid: String, displayName: String)] =
            chats.map { entry in
                (
                    guid: entry.key,
                    displayName: entry.value
                )
            }
        let values = unsortedValues.sorted { lhs, rhs in
            let comparison = lhs.displayName.localizedCompare(
                rhs.displayName
            )
            if comparison == .orderedSame {
                return lhs.guid < rhs.guid
            }
            return comparison == .orderedAscending
        }
        let approvalValues: [Value] = values.map { value in
            .object([
                "chatGUID": .string(value.guid),
                "displayName": .string(value.displayName),
            ])
        }
        return .object([
            "approvedChats": .array(approvalValues)
        ])
    }

    private func lockedUseState() -> Value {
        .object([
            "enabled": .bool(
                userDefaults.bool(forKey: Key.lockedUseEnabled)
            ),
            "computerIconDataURL": .null,
            "lockIconDataURL": .null,
        ])
    }

    private func updateThreadState(
        method: String,
        arguments: [Value]?
    ) throws {
        let outer = try Self.argumentObject(arguments)
        let fields: [String: Value]
        if case let .object(params)? = outer["params"] {
            fields = params
        } else {
            fields = outer
        }
        guard let hostID = Self.string(fields["hostId"]),
              let conversationID = Self.string(
                  fields["conversationId"]
              )
        else {
            throw Error.invalidArguments
        }
        let key = Self.threadKey(
            hostID: hostID,
            conversationID: conversationID
        )
        var state = threadStates[key] ?? ThreadState()
        switch method {
        case "setThreadOwnership":
            guard case let .bool(ownsThread)? = fields["ownsThread"] else {
                throw Error.invalidArguments
            }
            state.ownsThread = ownsThread
        case "threadStreamFollowingStatusRequested":
            break
        case "threadStreamFollowingChanged":
            guard case let .bool(following)? = fields["following"] else {
                throw Error.invalidArguments
            }
            state.following = following
        case "threadReadStateChanged":
            guard case let .bool(hasUnreadTurn)? =
                fields["hasUnreadTurn"]
            else {
                throw Error.invalidArguments
            }
            state.hasUnreadTurn = hasUnreadTurn
        case "threadStreamStateChanged":
            state.streamChange = fields["change"]
        case "threadArchived":
            state.archived = true
        case "threadUnarchived":
            state.archived = false
        default:
            throw Error.unsupportedMethod(
                service: "clientCoordination",
                method: method
            )
        }
        threadStates[key] = state
    }

    private static func argumentObject(
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

    private static func jsonValue(
        _ value: Value
    ) throws -> CodexJSONValue {
        switch value {
        case .null:
            return .null
        case let .bool(value):
            return .bool(value)
        case let .integer(value):
            return .integer(value)
        case let .number(value) where value.isFinite:
            return .number(value)
        case let .string(value):
            return .string(value)
        case let .array(values):
            return .array(try values.map(jsonValue))
        case let .object(fields):
            return .object(
                try fields.mapValues(jsonValue)
            )
        case .undefined,
             .number,
             .rpcObject,
             .export,
             .promise,
             .import,
             .error,
             .bigInt,
             .positiveInfinity,
             .negativeInfinity,
             .nan:
            throw Error.invalidArguments
        }
    }

    private static func threadKey(
        hostID: String,
        conversationID: String
    ) -> String {
        "\(hostID)\u{0}\(conversationID)"
    }
}
