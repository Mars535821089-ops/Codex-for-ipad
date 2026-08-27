#if SWIFT_PACKAGE
import CodexPadDomain
import CodexPadProtocolBridge
#endif
import Foundation

public enum CodexDesktopSurfaceState:
    Equatable,
    Sendable
{
    case verifyingResources
    case loadingDocument
    case awaitingBridgeReady
    case awaitingHomeData
    case ready
    case failed(reason: String)
}

public enum CodexDesktopTurnStartFailureDiagnostic {
    public static func make(
        problem: String,
        params: CodexTurnStartParams,
        rawParams: CodexJSONValue? = nil
    ) -> String {
        let conflict = hasValue(params.permissions)
            && hasValue(params.sandboxPolicy)
            ? " conflict=permissions+sandboxPolicy"
            : ""
        return "turn/start transport \(safeProblem(problem)) "
            + "thread=\(threadKind(params.threadID)) "
            + "inputCount=\(params.input.count) "
            + "cwd=\(kind(params.cwd)) "
            + "model=\(kind(params.model)) "
            + "effort=\(kind(params.effort)) "
            + "permissions=\(kind(params.permissions)) "
            + "sandbox=\(kind(params.sandboxPolicy))"
            + conflict
            + schemaMismatch(rawParams)
            + wireTypes(rawParams)
    }

    private static func safeProblem(_ problem: String) -> String {
        let knownProblems = [
            "invalidArgument",
            "invalidReply",
            "transportUnavailable",
            "replyIDMismatch",
            "appServerError",
        ]
        return knownProblems.first(where: { problem.contains($0) })
            ?? "other"
    }

    private static func threadKind(
        _ threadID: CodexStoredThreadID
    ) -> String {
        UUID(uuidString: threadID.rawValue) == nil ? "opaque" : "uuid"
    }

    private static func kind<Value>(
        _ value: CodexWireOptional<Value>
    ) -> String where Value: Equatable & Sendable {
        switch value {
        case .omitted:
            "omitted"
        case .null:
            "null"
        case .value:
            "value"
        }
    }

    private static func hasValue<Value>(
        _ value: CodexWireOptional<Value>
    ) -> Bool where Value: Equatable & Sendable {
        if case .value = value {
            return true
        }
        return false
    }

    private static func schemaMismatch(
        _ rawParams: CodexJSONValue?
    ) -> String {
        guard case let .object(fields)? = rawParams else {
            return ""
        }
        let acceptedTurnKeys: Set<String> = [
            "threadId",
            "clientUserMessageId",
            "input",
            "attachments",
            "responsesapiClientMetadata",
            "additionalContext",
            "environments",
            "cwd",
            "runtimeWorkspaceRoots",
            "dynamicTools",
            "selectedCapabilityRoots",
            "approvalPolicy",
            "approvalsReviewer",
            "sandboxPolicy",
            "permissions",
            "model",
            "serviceTier",
            "effort",
            "summary",
            "collaborationMode",
            "multiAgentMode",
            "personality",
            "outputSchema",
        ]
        let unknownTurnKeys = Set(fields.keys)
            .subtracting(acceptedTurnKeys)
            .sorted()

        var unknownInputKeys = Set<String>()
        if case let .array(input)? = fields["input"] {
            for value in input {
                guard case let .object(item) = value,
                      case let .string(type)? = item["type"]
                else {
                    continue
                }
                let acceptedKeys: Set<String>
                switch type {
                case "text":
                    acceptedKeys = ["type", "text", "text_elements"]
                case "image":
                    acceptedKeys = ["type", "detail", "url"]
                case "localImage":
                    acceptedKeys = ["type", "detail", "path"]
                case "audio":
                    acceptedKeys = ["type", "url"]
                case "localAudio", "skill", "mention":
                    acceptedKeys = ["type", "name", "path"]
                default:
                    acceptedKeys = ["type"]
                }
                unknownInputKeys.formUnion(
                    Set(item.keys).subtracting(acceptedKeys)
                )
            }
        }

        var suffix = ""
        if !unknownTurnKeys.isEmpty {
            suffix += " unknownTurnKeys="
                + unknownTurnKeys.joined(separator: ",")
        }
        if !unknownInputKeys.isEmpty {
            suffix += " unknownInputKeys="
                + unknownInputKeys.sorted().joined(separator: ",")
        }
        return suffix
    }

    private static func wireTypes(
        _ rawParams: CodexJSONValue?
    ) -> String {
        guard case let .object(fields)? = rawParams else {
            return ""
        }
        let rendered = fields.keys.sorted().map { key in
            "\(key):\(kind(fields[key]))"
        }
        return rendered.isEmpty
            ? ""
            : " wireTypes=" + rendered.joined(separator: ",")
    }

    private static func kind(_ value: CodexJSONValue?) -> String {
        switch value {
        case .null?: "null"
        case .bool?: "bool"
        case .integer?: "integer"
        case .number?: "number"
        case .string?: "string"
        case .array?: "array"
        case .object?: "object"
        case nil: "missing"
        }
    }
}

public enum CodexOfficialProviderTransportDiagnostic {
    /// Returns only stable, non-sensitive transport fields. Provider messages,
    /// URLs, headers, and response bodies are intentionally excluded.
    public static func make(payload: CodexJSONValue?) -> String {
        guard case let .object(fields)? = payload else {
            return ""
        }
        var parts: [String] = []
        if case let .integer(status)? = fields["status"] {
            parts.append("status=\(status)")
        }
        if case let .string(code)? = fields["code"], isSafeToken(code) {
            parts.append("code=\(code)")
        }
        if case let .string(detail)? = fields["detail"], isSafeDetail(detail) {
            parts.append("detail=\(detail)")
        }
        if case let .string(stage)? = fields["stage"], isSafeToken(stage) {
            parts.append("stage=\(stage)")
        }
        return parts.isEmpty ? "" : " transport=" + parts.joined(separator: ",")
    }

    private static func isSafeToken(_ value: String) -> Bool {
        !value.isEmpty
            && value.utf8.count <= 80
            && value.unicodeScalars.allSatisfy {
                let scalar = $0.value
                return (scalar >= 48 && scalar <= 57)
                    || (scalar >= 65 && scalar <= 90)
                    || (scalar >= 97 && scalar <= 122)
                    || scalar == 95
                    || scalar == 45
            }
    }

    private static func isSafeDetail(_ value: String) -> Bool {
        !value.isEmpty
            && value.utf8.count <= 240
            && value.unicodeScalars.allSatisfy { scalar in
                scalar.value >= 32 && scalar.value <= 126
            }
    }
}

public enum CodexDesktopTurnStartDiagnosticStore {
    public static let key =
        "codex.desktop.last-turn-start-diagnostic"

    public static func persist(
        _ diagnostic: String,
        to userDefaults: UserDefaults
    ) {
        userDefaults.set(diagnostic, forKey: key)
    }
}

public enum CodexDesktopSurfaceEvent:
    Equatable,
    Sendable
{
    case resourcesVerified
    case resourcesFailed(String)
    case documentLoaded
    case bridgeReady
    case homeDataLoaded
    case rendererFailed(String)
    case webContentProcessTerminated
    case retry
}

public enum CodexDesktopSurfaceTransitionError:
    Error,
    Equatable,
    Sendable
{
    case invalidTransition(
        from: CodexDesktopSurfaceState,
        event: CodexDesktopSurfaceEvent
    )
}

public struct CodexDesktopSurfaceStateMachine:
    Equatable,
    Sendable
{
    public private(set) var state: CodexDesktopSurfaceState

    public init(
        state: CodexDesktopSurfaceState = .verifyingResources
    ) {
        self.state = state
    }

    public var isBridgeReady: Bool {
        switch state {
        case .awaitingHomeData, .ready:
            true
        default:
            false
        }
    }

    public var isSurfaceReady: Bool {
        state == .ready
    }

    public mutating func apply(
        _ event: CodexDesktopSurfaceEvent
    ) throws {
        let previous = state
        switch (state, event) {
        case (.verifyingResources, .resourcesVerified):
            state = .loadingDocument
        case (.verifyingResources, .resourcesFailed(let reason)):
            state = .failed(reason: reason)
        case (.loadingDocument, .documentLoaded):
            state = .awaitingBridgeReady
        case (.awaitingBridgeReady, .bridgeReady):
            state = .awaitingHomeData
        case (.awaitingHomeData, .homeDataLoaded):
            state = .ready
        case (_, .rendererFailed(let reason)):
            state = .failed(reason: reason)
        case (_, .webContentProcessTerminated):
            state = .failed(
                reason: "desktop web content process terminated"
            )
        case (.failed, .retry):
            state = .verifyingResources
        default:
            throw CodexDesktopSurfaceTransitionError.invalidTransition(
                from: previous,
                event: event
            )
        }
    }

    private static func isSafeDetail(_ value: String) -> Bool {
        !value.isEmpty
            && value.utf8.count <= 240
            && value.unicodeScalars.allSatisfy { scalar in
                scalar.value >= 32 && scalar.value <= 126
            }
    }
}

/// Tracks the checkpoints the released renderer actually emits while it
/// starts. The current desktop bundle does not send a top-level `ready`
/// message and requests locale information lazily, so neither signal is a
/// startup prerequisite.
public struct CodexDesktopReleasedStartupGate:
    Equatable,
    Sendable
{
    public static let requiredFetchMethods: Set<String> = [
        "codex-home",
        "get-settings",
        "os-info",
    ]
    public static let requiredMCPMethods: Set<String> = [
        "account/read",
        "config/read",
    ]

    public private(set) var didLoadDocument = false
    public private(set) var didObserveBridgeMessage = false
    public private(set) var didResolveAppHostServices = false
    public private(set) var didCommitInteractiveSurface = false
    public private(set) var completedFetchMethods = Set<String>()
    public private(set) var completedMCPMethods = Set<String>()

    public init() {}

    public var canMarkBridgeReady: Bool {
        didLoadDocument
            && (
                didObserveBridgeMessage
                    || didResolveAppHostServices
            )
    }

    /// Mirrors the released desktop `startup.whenReady()` promise. The
    /// renderer invokes it while constructing the first React tree; it must
    /// wait for the native AppHost export handshake, but not for the later
    /// home-data gate (which itself depends on the rendered surface).
    public var canMarkStartupReady: Bool {
        didResolveAppHostServices
    }

    public var canMarkHomeDataReady: Bool {
        canMarkBridgeReady
            && didCommitInteractiveSurface
            && completedFetchMethods.isSuperset(
                of: Self.requiredFetchMethods
            )
            && completedMCPMethods.isSuperset(
                of: Self.requiredMCPMethods
            )
    }

    public mutating func observeDocumentLoaded() {
        didLoadDocument = true
    }

    public mutating func observeBridgeMessage() {
        didObserveBridgeMessage = true
    }

    public mutating func observeAppHostServicesResolved() {
        didResolveAppHostServices = true
    }

    public mutating func resetAppHostServices() {
        didResolveAppHostServices = false
    }

    public mutating func observeInteractiveSurfaceCommitted() {
        didCommitInteractiveSurface = true
    }

    public mutating func observeSuccessfulFetch(
        _ method: String
    ) {
        completedFetchMethods.insert(method)
    }

    public mutating func observeSuccessfulMCP(
        _ method: String
    ) {
        completedMCPMethods.insert(method)
    }

    public mutating func reset() {
        self = Self()
    }
}
