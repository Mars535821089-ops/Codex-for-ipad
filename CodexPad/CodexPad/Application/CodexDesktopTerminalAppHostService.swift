import Foundation

public typealias CodexDesktopTerminalEventReceiver =
    @Sendable (CodexDesktopAppHostRPC.Value) async -> Void
public typealias CodexDesktopTerminalUnsubscribe =
    @Sendable () async -> Void

/// Application-owned terminal mechanism used by the desktop AppHost adapter.
///
/// `CodexDesktopWorkspaceCommandExecutor` intentionally implements buffered
/// command execution rather than interactive PTY ownership. Keeping the
/// terminal boundary separate preserves the released attach, snapshot, resize,
/// input, and subscription semantics without inventing sessions in this layer.
public protocol CodexDesktopTerminalAppHostManaging: Sendable {
    func createOrAttach(
        _ request: CodexDesktopTerminalAppHostService.SessionRequest
    ) async throws

    func close(sessionID: String) async throws

    func getShellCWD(
        sessionID: String,
        requestedCWD: String
    ) async throws -> String?

    func getThreadSnapshot(
        conversationID: String
    ) async throws -> CodexDesktopTerminalAppHostService.ThreadSnapshot?

    func resize(
        sessionID: String,
        columns: UInt32,
        rows: UInt32,
        repaint: Bool
    ) async throws

    func runAction(
        sessionID: String,
        cwd: String,
        command: String
    ) async throws

    func write(
        sessionID: String,
        data: String
    ) async throws

    func subscribe(
        _ receive: @escaping CodexDesktopTerminalEventReceiver
    ) async throws -> CodexDesktopTerminalUnsubscribe
}

/// iPad application adapter for the released desktop `terminal` AppHost
/// service.
///
/// The argument order and request fields mirror the `Fye` service in desktop
/// release 26.730.61309: notably resize is `(sessionId, cols, rows, repaint)`,
/// runAction is `(sessionId, cwd, command)`, and create removes `trace` before
/// handing the request to the terminal manager.
public actor CodexDesktopTerminalAppHostService {
    public typealias Value = CodexDesktopAppHostRPC.Value
    public typealias SubscriptionEventHandler =
        @Sendable (_ callbackID: Int, _ event: Value) async -> Void

    public enum Error: Swift.Error, Equatable, Sendable {
        case invalidArguments
        case managerUnavailable
        case subscriptionEventHandlerUnavailable
        case unsupportedMethod(service: String, method: String)
    }

    public struct SessionRequest: Equatable, Sendable {
        public enum Kind: Equatable, Sendable {
            case create
            case attach
        }

        public let kind: Kind
        public let sessionID: String?
        public let conversationID: String?
        public let conversationTitle: String?
        public let hostID: String?
        public let cwd: String?
        public let forceCWDSync: Bool?
        public let columns: UInt32?
        public let rows: UInt32?
        public let preserveOnOwnerDestroy: Bool?

        public init(
            kind: Kind,
            sessionID: String? = nil,
            conversationID: String? = nil,
            conversationTitle: String? = nil,
            hostID: String? = nil,
            cwd: String? = nil,
            forceCWDSync: Bool? = nil,
            columns: UInt32? = nil,
            rows: UInt32? = nil,
            preserveOnOwnerDestroy: Bool? = nil
        ) {
            self.kind = kind
            self.sessionID = sessionID
            self.conversationID = conversationID
            self.conversationTitle = conversationTitle
            self.hostID = hostID
            self.cwd = cwd
            self.forceCWDSync = forceCWDSync
            self.columns = columns
            self.rows = rows
            self.preserveOnOwnerDestroy = preserveOnOwnerDestroy
        }
    }

    public struct ThreadSnapshot: Equatable, Sendable {
        public let cwd: String
        public let shell: String
        public let buffer: String
        public let truncated: Bool

        public init(
            cwd: String,
            shell: String,
            buffer: String,
            truncated: Bool
        ) {
            self.cwd = cwd
            self.shell = shell
            self.buffer = buffer
            self.truncated = truncated
        }

        fileprivate var value: Value {
            .object([
                "cwd": .string(cwd),
                "shell": .string(shell),
                "buffer": .string(buffer),
                "truncated": .bool(truncated),
            ])
        }
    }

    private let manager:
        (any CodexDesktopTerminalAppHostManaging)?
    private let subscriptionEventHandler:
        SubscriptionEventHandler?

    private var nextSubscriptionGeneration: UInt64 = 0
    private var activeSubscriptionGeneration: UInt64?
    private var managerUnsubscribe:
        CodexDesktopTerminalUnsubscribe?

    public init(
        manager:
            (any CodexDesktopTerminalAppHostManaging)? = nil,
        subscriptionEventHandler:
            SubscriptionEventHandler? = nil
    ) {
        self.manager = manager
        self.subscriptionEventHandler =
            subscriptionEventHandler
    }

    public func invoke(
        service: String,
        method: String,
        arguments: [Value]?
    ) async throws -> Value {
        guard service == "terminal" else {
            throw Error.unsupportedMethod(
                service: service,
                method: method
            )
        }

        switch method {
        case "attach":
            let request = try sessionRequest(
                kind: .attach,
                arguments: arguments
            )
            try await requiredManager()
                .createOrAttach(request)
            return .undefined

        case "close":
            let sessionID = try onlyString(arguments)
            try await requiredManager().close(
                sessionID: sessionID
            )
            return .undefined

        case "create":
            let request = try sessionRequest(
                kind: .create,
                arguments: arguments
            )
            try await requiredManager()
                .createOrAttach(request)
            return .undefined

        case "getAvailableShells":
            try validateNoArguments(arguments)
            // The released helper only returns named shell choices on
            // Windows. iPadOS follows its non-Windows result exactly.
            return .array([])

        case "getShellCwd":
            let values = try exactArguments(
                arguments,
                count: 2
            )
            guard let sessionID = Self.string(values[0]),
                  let requestedCWD = Self.string(values[1])
            else {
                throw Error.invalidArguments
            }
            let cwd = try await requiredManager()
                .getShellCWD(
                    sessionID: sessionID,
                    requestedCWD: requestedCWD
                )
            return cwd.map(Value.string) ?? .null

        case "getThreadSnapshot":
            let conversationID = try onlyString(arguments)
            let snapshot = try await requiredManager()
                .getThreadSnapshot(
                    conversationID: conversationID
                )
            return snapshot?.value ?? .null

        case "resize":
            let values = try exactArguments(
                arguments,
                count: 4
            )
            guard let sessionID = Self.string(values[0]),
                  let columns = Self.positiveUInt32(values[1]),
                  let rows = Self.positiveUInt32(values[2]),
                  case let .bool(repaint) = values[3]
            else {
                throw Error.invalidArguments
            }
            try await requiredManager().resize(
                sessionID: sessionID,
                columns: columns,
                rows: rows,
                repaint: repaint
            )
            return .undefined

        case "runAction":
            let values = try exactArguments(
                arguments,
                count: 3
            )
            guard let sessionID = Self.string(values[0]),
                  let cwd = Self.string(values[1]),
                  let command = Self.string(values[2])
            else {
                throw Error.invalidArguments
            }
            try await requiredManager().runAction(
                sessionID: sessionID,
                cwd: cwd,
                command: command
            )
            return .undefined

        case "subscribe":
            let callback = try onlyArgument(arguments)
            guard case let .import(callbackID) = callback else {
                throw Error.invalidArguments
            }
            try await replaceSubscription(
                callbackID: callbackID
            )
            return .undefined

        case "unsubscribe":
            try validateNoArguments(arguments)
            await clearSubscription()
            return .undefined

        case "write":
            let values = try exactArguments(
                arguments,
                count: 2
            )
            guard let sessionID = Self.string(values[0]),
                  let data = Self.string(values[1])
            else {
                throw Error.invalidArguments
            }
            try await requiredManager().write(
                sessionID: sessionID,
                data: data
            )
            return .undefined

        default:
            throw Error.unsupportedMethod(
                service: service,
                method: method
            )
        }
    }

    private func replaceSubscription(
        callbackID: Int
    ) async throws {
        let manager = try requiredManager()
        guard subscriptionEventHandler != nil else {
            throw Error.subscriptionEventHandlerUnavailable
        }

        // Released Fye semantics replace the prior subscription before
        // registering the next listener.
        await clearSubscription()
        nextSubscriptionGeneration &+= 1
        let generation = nextSubscriptionGeneration
        activeSubscriptionGeneration = generation

        let unsubscribe: CodexDesktopTerminalUnsubscribe
        do {
            unsubscribe = try await manager.subscribe {
                [weak self] event in
                await self?.deliver(
                    event,
                    callbackID: callbackID,
                    generation: generation
                )
            }
        } catch {
            if activeSubscriptionGeneration == generation {
                activeSubscriptionGeneration = nil
            }
            throw error
        }

        guard activeSubscriptionGeneration == generation else {
            await unsubscribe()
            return
        }
        managerUnsubscribe = unsubscribe
    }

    private func deliver(
        _ event: Value,
        callbackID: Int,
        generation: UInt64
    ) async {
        guard activeSubscriptionGeneration == generation,
              let subscriptionEventHandler
        else {
            return
        }
        await subscriptionEventHandler(callbackID, event)
    }

    private func clearSubscription() async {
        activeSubscriptionGeneration = nil
        let unsubscribe = managerUnsubscribe
        managerUnsubscribe = nil
        if let unsubscribe {
            await unsubscribe()
        }
    }

    private func requiredManager()
        throws -> any CodexDesktopTerminalAppHostManaging
    {
        guard let manager else {
            throw Error.managerUnavailable
        }
        return manager
    }

    private func sessionRequest(
        kind: SessionRequest.Kind,
        arguments: [Value]?
    ) throws -> SessionRequest {
        let argument = try onlyArgument(arguments)
        guard case let .object(fields) = argument else {
            throw Error.invalidArguments
        }

        return SessionRequest(
            kind: kind,
            sessionID: try Self.optionalString(
                fields["sessionId"]
            ),
            conversationID: try Self.optionalString(
                fields["conversationId"]
            ),
            conversationTitle: try Self.optionalString(
                fields["conversationTitle"]
            ),
            hostID: try Self.optionalString(fields["hostId"]),
            cwd: try Self.optionalString(fields["cwd"]),
            forceCWDSync: try Self.optionalBool(
                fields["forceCwdSync"]
            ),
            columns: try Self.optionalPositiveUInt32(
                fields["cols"]
            ),
            rows: try Self.optionalPositiveUInt32(
                fields["rows"]
            ),
            preserveOnOwnerDestroy: try Self.optionalBool(
                fields["preserveOnOwnerDestroy"]
            )
        )
    }

    private func onlyArgument(
        _ arguments: [Value]?
    ) throws -> Value {
        try exactArguments(arguments, count: 1)[0]
    }

    private func onlyString(
        _ arguments: [Value]?
    ) throws -> String {
        let argument = try onlyArgument(arguments)
        guard let string = Self.string(argument) else {
            throw Error.invalidArguments
        }
        return string
    }

    private func exactArguments(
        _ arguments: [Value]?,
        count: Int
    ) throws -> [Value] {
        guard let arguments,
              arguments.count == count
        else {
            throw Error.invalidArguments
        }
        return arguments
    }

    private func validateNoArguments(
        _ arguments: [Value]?
    ) throws {
        guard arguments?.isEmpty ?? true else {
            throw Error.invalidArguments
        }
    }

    private static func string(_ value: Value) -> String? {
        guard case let .string(string) = value else {
            return nil
        }
        return string
    }

    private static func optionalString(
        _ value: Value?
    ) throws -> String? {
        guard let value else {
            return nil
        }
        switch value {
        case .null, .undefined:
            return nil
        case let .string(string):
            return string
        default:
            throw Error.invalidArguments
        }
    }

    private static func optionalBool(
        _ value: Value?
    ) throws -> Bool? {
        guard let value else {
            return nil
        }
        switch value {
        case .null, .undefined:
            return nil
        case let .bool(bool):
            return bool
        default:
            throw Error.invalidArguments
        }
    }

    private static func optionalPositiveUInt32(
        _ value: Value?
    ) throws -> UInt32? {
        guard let value else {
            return nil
        }
        switch value {
        case .null, .undefined:
            return nil
        default:
            guard let dimension = positiveUInt32(value) else {
                throw Error.invalidArguments
            }
            return dimension
        }
    }

    private static func positiveUInt32(
        _ value: Value
    ) -> UInt32? {
        switch value {
        case let .integer(integer):
            guard integer > 0,
                  integer <= Int64(UInt32.max)
            else {
                return nil
            }
            return UInt32(integer)

        case let .number(number):
            guard number.isFinite,
                  number > 0,
                  number <= Double(UInt32.max),
                  number.rounded(.towardZero) == number
            else {
                return nil
            }
            return UInt32(number)

        default:
            return nil
        }
    }
}
