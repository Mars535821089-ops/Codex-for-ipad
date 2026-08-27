import Foundation

/// Lightweight iPad host boundaries for released desktop peripheral services.
///
/// Platform behavior is injected by the iPad application. When no platform
/// implementation exists, the service reports an honest unavailable result
/// rather than simulating a successful desktop operation.
public actor CodexDesktopPeripheralAppHostService {
    public typealias Value = CodexDesktopAppHostRPC.Value
    public typealias Operation =
        @Sendable (String, [Value]?) async throws -> Value

    public struct PullRequestGenerationRequest:
        Equatable,
        Sendable
    {
        public let appServerVersion: String
        public let hostID: String
        public let prompt: String

        public init(
            appServerVersion: String,
            hostID: String,
            prompt: String
        ) {
            self.appServerVersion = appServerVersion
            self.hostID = hostID
            self.prompt = prompt
        }
    }

    public struct PullRequestGenerationOperation:
        Equatable,
        Hashable,
        RawRepresentable,
        Sendable
    {
        public let rawValue: String

        public init(rawValue: String) {
            self.rawValue = rawValue
        }
    }

    public struct PullRequestGeneratedMessage: Equatable, Sendable {
        public let title: String
        public let body: String

        public init(title: String, body: String) {
            self.title = title
            self.body = body
        }
    }

    public typealias PullRequestGenerationStart =
        @Sendable (
            PullRequestGenerationRequest
        ) async throws -> PullRequestGenerationOperation
    public typealias PullRequestGenerationWait =
        @Sendable (
            PullRequestGenerationOperation
        ) async throws -> PullRequestGeneratedMessage?
    public typealias PullRequestGenerationLifecycleHook =
        @Sendable (PullRequestGenerationOperation) -> Void

    public enum Error: Swift.Error, Equatable, Sendable {
        case invalidArguments
        case unavailable(service: String, method: String)
        case unsupportedMethod(service: String, method: String)
        case invalidGeneratedResult(field: String)
    }

    public static let unsupportedAppshotState: Value = .object([
        "supported": .bool(false),
        "configuredHotkey": .null,
        "isActive": .bool(false),
    ])

    private static let appshotHotkeys: Set<String> = [
        "DoubleCommand",
        "DoubleOption",
        "DoubleShift",
    ]

    private static let hotkeyWindowMethods: Set<String> = [
        "getState",
        "setEnabled",
        "toggle",
        "open",
        "collapseToHome",
        "dismiss",
        "setHotkey",
        "setDevOverrideEnabled",
        "transitionDone",
        "homePointerInteractionChanged",
        "homeLayoutChanged",
        "homeDragStart",
        "homeDragMove",
        "homeDragEnd",
    ]

    private let appshotHotkeyOperation: Operation?
    private let hotkeyWindowOperation: Operation?
    private let remoteControlEnvironmentOperation: Operation?
    private let pullRequestGenerationOperation:
        PullRequestGenerationStart?
    private let pullRequestGenerationWait: PullRequestGenerationWait?
    private let pullRequestGenerationCancel:
        PullRequestGenerationLifecycleHook?
    private let pullRequestGenerationRelease:
        PullRequestGenerationLifecycleHook?

    public init(
        appshotHotkeyOperation: Operation? = nil,
        hotkeyWindowOperation: Operation? = nil,
        remoteControlEnvironmentOperation: Operation? = nil,
        pullRequestGenerationOperation:
            PullRequestGenerationStart? = nil,
        pullRequestGenerationWait:
            PullRequestGenerationWait? = nil,
        pullRequestGenerationCancel:
            PullRequestGenerationLifecycleHook? = nil,
        pullRequestGenerationRelease:
            PullRequestGenerationLifecycleHook? = nil
    ) {
        self.appshotHotkeyOperation = appshotHotkeyOperation
        self.hotkeyWindowOperation = hotkeyWindowOperation
        self.remoteControlEnvironmentOperation =
            remoteControlEnvironmentOperation
        self.pullRequestGenerationOperation =
            pullRequestGenerationOperation
        self.pullRequestGenerationWait = pullRequestGenerationWait
        self.pullRequestGenerationCancel =
            pullRequestGenerationCancel
        self.pullRequestGenerationRelease =
            pullRequestGenerationRelease
    }

    public func invoke(
        service: String,
        method: String,
        arguments: [Value]?
    ) async throws -> Value {
        switch service {
        case "appshot", "appshotHotkeys":
            return try await invokeAppshot(
                service: service,
                method: method,
                arguments: arguments
            )
        case "hotkeyWindowCommands", "hotkeyWindowHotkeys":
            return try await invokeHotkeyWindow(
                service: service,
                method: method,
                arguments: arguments
            )
        case "remoteControlEnvironments":
            return try await invokeRemoteControlEnvironments(
                method: method,
                arguments: arguments
            )
        case "pullRequestMessageGeneration":
            return try await invokePullRequestMessageGeneration(
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

    private func invokeAppshot(
        service: String,
        method: String,
        arguments: [Value]?
    ) async throws -> Value {
        switch method {
        case "getState":
            if let appshotHotkeyOperation {
                return try await appshotHotkeyOperation(
                    method,
                    arguments
                )
            }
            return Self.unsupportedAppshotState

        case "setHotkey":
            guard let arguments,
                  arguments.count == 1,
                  Self.isAppshotHotkey(arguments[0])
            else {
                throw Error.invalidArguments
            }
            guard let appshotHotkeyOperation else {
                throw Error.unavailable(
                    service: service,
                    method: method
                )
            }
            return try await appshotHotkeyOperation(
                method,
                arguments
            )

        case "requestFinalUpdate":
            guard let arguments,
                  arguments.count == 1,
                  case let .object(fields) = arguments[0],
                  case let .string(requestID)? = fields["requestId"],
                  !requestID.isEmpty
            else {
                throw Error.invalidArguments
            }
            guard let appshotHotkeyOperation else {
                return .bool(false)
            }
            return try await appshotHotkeyOperation(
                method,
                arguments
            )

        default:
            throw Error.unsupportedMethod(
                service: service,
                method: method
            )
        }
    }

    private func invokeHotkeyWindow(
        service: String,
        method: String,
        arguments: [Value]?
    ) async throws -> Value {
        guard Self.hotkeyWindowMethods.contains(method) else {
            throw Error.unsupportedMethod(
                service: service,
                method: method
            )
        }
        try Self.validateHotkeyWindowArguments(
            method: method,
            arguments: arguments
        )
        guard let hotkeyWindowOperation else {
            throw Error.unavailable(
                service: service,
                method: method
            )
        }
        return try await hotkeyWindowOperation(method, arguments)
    }

    private func invokeRemoteControlEnvironments(
        method: String,
        arguments: [Value]?
    ) async throws -> Value {
        guard method == "renameIfDefault" else {
            throw Error.unsupportedMethod(
                service: "remoteControlEnvironments",
                method: method
            )
        }
        guard let arguments,
              arguments.count == 1,
              case let .object(argument) = arguments[0],
              case let .string(envID)? = argument["envId"],
              !envID.isEmpty,
              case let .string(name)? = argument["name"],
              !name.isEmpty
        else {
            throw Error.invalidArguments
        }
        guard let remoteControlEnvironmentOperation else {
            throw Error.unavailable(
                service: "remoteControlEnvironments",
                method: method
            )
        }
        return try await remoteControlEnvironmentOperation(
            method,
            arguments
        )
    }

    private func invokePullRequestMessageGeneration(
        method: String,
        arguments: [Value]?
    ) async throws -> Value {
        guard method == "generate" else {
            throw Error.unsupportedMethod(
                service: "pullRequestMessageGeneration",
                method: method
            )
        }
        let request = try Self.pullRequestGenerationRequest(
            arguments: arguments
        )
        guard !request.prompt.isEmpty else {
            return .null
        }
        guard let pullRequestGenerationOperation,
              let pullRequestGenerationWait
        else {
            throw Error.unavailable(
                service: "pullRequestMessageGeneration",
                method: method
            )
        }

        let operation = try await pullRequestGenerationOperation(
            request
        )
        let lifecycle = PullRequestGenerationLifecycle(
            operation: operation,
            cancel: pullRequestGenerationCancel,
            release: pullRequestGenerationRelease
        )

        do {
            let generated = try await withTaskCancellationHandler {
                try await pullRequestGenerationWait(operation)
            } onCancel: {
                lifecycle.cancel()
            }
            lifecycle.release()
            guard let generated else {
                return .null
            }
            try Self.validate(generated: generated)
            return .object([
                "title": .string(generated.title),
                "body": .string(generated.body),
            ])
        } catch {
            if error is CancellationError {
                lifecycle.cancel()
            }
            lifecycle.release()
            throw error
        }
    }

    private static func isAppshotHotkey(_ value: Value) -> Bool {
        if value == .null {
            return true
        }
        guard case let .string(hotkey) = value else {
            return false
        }
        return appshotHotkeys.contains(hotkey)
    }

    private static func validateHotkeyWindowArguments(
        method: String,
        arguments: [Value]?
    ) throws {
        switch method {
        case "setEnabled", "setDevOverrideEnabled":
            guard arguments?.count == 1,
                  case .bool? = arguments?.first
            else {
                throw Error.invalidArguments
            }
        case "setHotkey":
            guard arguments?.count == 1,
                  let value = arguments?.first,
                  value == .null || Self.string(value) != nil
            else {
                throw Error.invalidArguments
            }
        case "open",
             "transitionDone",
             "homePointerInteractionChanged",
             "homeLayoutChanged",
             "homeDragStart":
            guard arguments?.count == 1,
                  case .object? = arguments?.first
            else {
                throw Error.invalidArguments
            }
        default:
            break
        }
    }

    private static func pullRequestGenerationRequest(
        arguments: [Value]?
    ) throws -> PullRequestGenerationRequest {
        guard let arguments,
              arguments.count == 1,
              case let .object(argument) = arguments[0],
              case let .string(appServerVersion)? =
                  argument["appServerVersion"],
              case let .string(hostID)? = argument["hostId"],
              case let .string(untrimmedPrompt)? = argument["prompt"]
        else {
            throw Error.invalidArguments
        }

        let prompt = untrimmedPrompt
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return .init(
            appServerVersion: appServerVersion,
            hostID: hostID,
            prompt: String(prompt.prefix(30_000))
        )
    }

    private static func validate(
        generated: PullRequestGeneratedMessage
    ) throws {
        guard (8 ... 120).contains(generated.title.count) else {
            throw Error.invalidGeneratedResult(field: "title")
        }
        guard (12 ... 30_000).contains(generated.body.count) else {
            throw Error.invalidGeneratedResult(field: "body")
        }
    }

    private static func string(_ value: Value) -> String? {
        guard case let .string(string) = value else {
            return nil
        }
        return string
    }
}

/// Released `remoteControlEnvironments.renameIfDefault` behavior for iPad.
/// It refreshes the authoritative environment list, preserves custom names,
/// and only PATCHes a reported default host name.
public actor CodexDesktopRemoteControlEnvironmentBackend {
    public typealias Value = CodexDesktopAppHostRPC.Value
    public typealias CredentialsProvider =
        @Sendable () async throws -> CodexOfficialCredentials?

    public enum Error: Swift.Error, Equatable, Sendable {
        case invalidArguments
        case authenticationRequired
        case invalidResponse
        case httpStatus(Int)
    }

    private struct Environment: Sendable {
        let id: String
        let displayName: String
        let hostName: String
        let hasReportedHostName: Bool
    }

    private let credentialsProvider: CredentialsProvider
    private let transport: any CodexDesktopNetworkFetchTransport
    private let baseURL: URL

    public init(
        credentialsProvider: @escaping CredentialsProvider,
        transport: any CodexDesktopNetworkFetchTransport =
            CodexDesktopURLSessionNetworkFetchTransport(),
        baseURL: URL = CodexDesktopNetworkFetchClient
            .releasedProductAPIBaseURL
    ) {
        self.credentialsProvider = credentialsProvider
        self.transport = transport
        self.baseURL = baseURL
    }

    public func invoke(
        method: String,
        arguments: [Value]?
    ) async throws -> Value {
        guard method == "renameIfDefault",
              arguments?.count == 1,
              case let .object(fields)? = arguments?.first,
              case let .string(environmentID)? = fields["envId"],
              !environmentID.isEmpty,
              case let .string(requestedName)? = fields["name"]
        else {
            throw Error.invalidArguments
        }
        let name = requestedName.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !name.isEmpty else {
            throw Error.invalidArguments
        }
        let credentials = try await requiredCredentials()
        let environments = try await loadEnvironments(
            credentials: credentials
        )
        guard let environment = environments.first(where: {
            $0.id == environmentID
        }) else {
            return .undefined
        }
        guard environment.hasReportedHostName,
              environment.displayName == environment.hostName,
              environment.displayName != name
        else {
            return .undefined
        }
        try await rename(
            environmentID: environmentID,
            name: name,
            credentials: credentials
        )
        return .undefined
    }

    private func requiredCredentials() async throws
        -> CodexOfficialCredentials
    {
        guard let credentials = try await credentialsProvider(),
              credentials.authMethod == .chatGPT,
              credentials.accountID?.isEmpty == false
        else {
            throw Error.authenticationRequired
        }
        return credentials
    }

    private func loadEnvironments(
        credentials: CodexOfficialCredentials
    ) async throws -> [Environment] {
        var result: [Environment] = []
        var cursor: String?
        repeat {
            var components = URLComponents(
                url: baseURL.appendingPathComponent(
                    "codex/remote/control/environments"
                ),
                resolvingAgainstBaseURL: false
            )
            var query = [URLQueryItem(name: "limit", value: "100")]
            if let cursor {
                query.append(URLQueryItem(name: "cursor", value: cursor))
            }
            components?.queryItems = query
            guard let url = components?.url else {
                throw Error.invalidResponse
            }
            let response = try await execute(
                url: url,
                method: "GET",
                body: nil,
                credentials: credentials
            )
            guard let object = try JSONSerialization
                .jsonObject(with: response.body) as? [String: Any],
                  let items = object["items"] as? [[String: Any]]
            else {
                throw Error.invalidResponse
            }
            result.append(contentsOf: try items.map(Self.environment))
            cursor = object["cursor"] as? String
            if cursor?.isEmpty == true {
                cursor = nil
            }
        } while cursor != nil
        return result
    }

    private func rename(
        environmentID: String,
        name: String,
        credentials: CodexOfficialCredentials
    ) async throws {
        let url = baseURL
            .appendingPathComponent("codex/remote/control/environments")
            .appendingPathComponent(environmentID)
        let body = try JSONSerialization.data(
            withJSONObject: ["name": name],
            options: [.sortedKeys]
        )
        _ = try await execute(
            url: url,
            method: "PATCH",
            body: body,
            credentials: credentials
        )
    }

    private func execute(
        url: URL,
        method: String,
        body: Data?,
        credentials: CodexOfficialCredentials
    ) async throws -> CodexDesktopNetworkTransportResponse {
        var headers = [
            "Authorization": "Bearer \(credentials.accessToken)",
            "Originator": "Codex Desktop",
            "Accept": "application/json",
        ]
        if let accountID = credentials.accountID {
            headers["ChatGPT-Account-Id"] = accountID
        }
        if body != nil {
            headers["Content-Type"] = "application/json"
        }
        let response = try await transport.execute(
            .init(
                url: url,
                method: method,
                headers: headers,
                body: body,
                timeoutInterval: 30
            )
        )
        guard (200 ..< 300).contains(response.status) else {
            throw Error.httpStatus(response.status)
        }
        return response
    }

    private static func environment(
        _ object: [String: Any]
    ) throws -> Environment {
        guard let id = object["env_id"] as? String,
              !id.isEmpty
        else {
            throw Error.invalidResponse
        }
        let display = (object["display_name"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let legacyName = (object["name"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let reportedHost = (object["host_name"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = [display, legacyName, reportedHost, id]
            .compactMap { $0 }
            .first(where: { !$0.isEmpty }) ?? id
        let hostName = [reportedHost, legacyName, display, displayName]
            .compactMap { $0 }
            .first(where: { !$0.isEmpty }) ?? displayName
        return Environment(
            id: id,
            displayName: displayName,
            hostName: hostName,
            hasReportedHostName: reportedHost?.isEmpty == false
        )
    }
}

private final class PullRequestGenerationLifecycle:
    @unchecked Sendable
{
    typealias Operation =
        CodexDesktopPeripheralAppHostService
            .PullRequestGenerationOperation
    typealias Hook =
        CodexDesktopPeripheralAppHostService
            .PullRequestGenerationLifecycleHook

    private let operation: Operation
    private let cancelHook: Hook?
    private let releaseHook: Hook?
    private let lock = NSLock()
    private var didCancel = false
    private var didRelease = false

    init(
        operation: Operation,
        cancel: Hook?,
        release: Hook?
    ) {
        self.operation = operation
        self.cancelHook = cancel
        self.releaseHook = release
    }

    func cancel() {
        let shouldRun = lock.withLock {
            guard !didCancel else {
                return false
            }
            didCancel = true
            return true
        }
        if shouldRun {
            cancelHook?(operation)
        }
    }

    func release() {
        let shouldRun = lock.withLock {
            guard !didRelease else {
                return false
            }
            didRelease = true
            return true
        }
        if shouldRun {
            releaseHook?(operation)
        }
    }
}
