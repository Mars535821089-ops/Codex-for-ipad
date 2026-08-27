#if SWIFT_PACKAGE
    import CodexPadDomain
#endif
import Foundation

public enum CodexDesktopMCPAppSandboxError: Error, Equatable, Sendable {
    case invalidSourceURL
    case invalidInitID
    case invalidSandboxID
    case invalidPortNames
    case portCountMismatch
    case invalidSession
    case duplicateGuest
    case duplicateOwnerSandbox
    case unknownGuest
    case originMismatch
    case initIDMismatch
    case appSessionMismatch
    case targetOriginMismatch
}

public enum CodexDesktopMCPAppSandboxCacheState:
    String,
    Codable,
    Equatable,
    Sendable
{
    case cold
    case warming
    case warm
}

public enum CodexDesktopMCPAppSandboxProtocol {
    public static let guestMessageChannel =
        "codex_desktop:mcp-app-sandbox-guest-message"
    public static let hostMessageChannel =
        "codex_desktop:mcp-app-sandbox-host-message"
    public static let modelContextGlobal =
        "__codexWebMcpModelContext"
    public static let sandboxPartitionPrefix =
        "codex-mcp-app-sandbox:"

    /// The released sandbox preload rejects initialization unless every one
    /// of these MessagePorts is present exactly once.
    public static let requiredPortNames = [
        "navigate",
        "notifyMcpAppsHostContext",
        "notifyMcpAppsToolCancelled",
        "notifyMcpAppsToolInput",
        "notifyMcpAppsToolResult",
        "requestMcpAppsResourceTeardown",
        "runWidgetCode",
        "setAdditionalGlobals",
        "setSafeArea",
        "setTheme",
        "setWidgetData",
        "setWidgetView",
    ]

    /// Desktop 26.730.61309 accepts this port when supplied but does not
    /// require it for the initial handshake.
    public static let optionalPortNames = [
        "notifyMcpAppsMcpNotification"
    ]

    public static func validatePortNames(
        _ portNames: [String]
    ) throws {
        let names = Set(portNames)
        let allowed = Set(requiredPortNames + optionalPortNames)
        guard names.count == portNames.count,
              Set(requiredPortNames).isSubset(of: names),
              names.isSubset(of: allowed)
        else {
            throw CodexDesktopMCPAppSandboxError.invalidPortNames
        }
    }

    public static func isValidIdentifier(_ value: String) -> Bool {
        guard (1 ... 128).contains(value.utf8.count) else {
            return false
        }
        return value.utf8.allSatisfy { byte in
            (65 ... 90).contains(byte)
                || (97 ... 122).contains(byte)
                || (48 ... 57).contains(byte)
                || byte == 95
                || byte == 45
        }
    }
}

public struct CodexDesktopMCPAppSandboxSource:
    Equatable,
    Sendable
{
    public let url: URL
    public let origin: String
    public let initID: String
    public let sandboxID: String

    public init(
        url: URL,
        sandboxID: String
    ) throws {
        guard
            CodexDesktopMCPAppSandboxProtocol
                .isValidIdentifier(sandboxID)
        else {
            throw CodexDesktopMCPAppSandboxError.invalidSandboxID
        }
        guard let components = URLComponents(
            url: url,
            resolvingAgainstBaseURL: false
        ),
            let rawScheme = components.scheme,
            let rawHost = components.host
        else {
            throw CodexDesktopMCPAppSandboxError.invalidSourceURL
        }

        let scheme = rawScheme.lowercased()
        let host = rawHost.lowercased()
        let releasedHost = "web-sandbox.oaiusercontent.com"
        guard ["https", "codex-sandbox"].contains(scheme),
              components.port == nil,
              components.user == nil,
              components.password == nil,
              host == releasedHost
                || host.hasSuffix(".\(releasedHost)"),
              components.path == "/",
              let queryItems = components.queryItems,
              queryItems.count == 4
        else {
            throw CodexDesktopMCPAppSandboxError.invalidSourceURL
        }

        var query: [String: String] = [:]
        for item in queryItems {
            guard query[item.name] == nil, let value = item.value else {
                throw CodexDesktopMCPAppSandboxError.invalidSourceURL
            }
            query[item.name] = value
        }
        guard Set(query.keys)
            == Set([
                "app",
                "locale",
                "deviceType",
                "unsafeSkipTargetOriginCheck",
            ]),
            query["app"] == "skybridge",
            query["locale"]?.isEmpty == false,
            query["deviceType"] == "desktop",
            query["unsafeSkipTargetOriginCheck"] == "true"
        else {
            throw CodexDesktopMCPAppSandboxError.invalidSourceURL
        }

        guard let fragment = components.percentEncodedFragment,
              !fragment.isEmpty,
              let fragmentComponents = URLComponents(
                  string: "https://fragment.invalid/?\(fragment)"
              ),
              let initID = fragmentComponents.queryItems?
              .first(where: { $0.name == "initId" })?.value,
              CodexDesktopMCPAppSandboxProtocol
              .isValidIdentifier(initID)
        else {
            throw CodexDesktopMCPAppSandboxError.invalidInitID
        }

        self.url = url
        self.origin = "\(scheme)://\(host)"
        self.initID = initID
        self.sandboxID = sandboxID
    }
}

public struct CodexDesktopMCPAppSandboxGuestEnvelope:
    Codable,
    Equatable,
    Sendable
{
    public let origin: String
    public let initID: String
    public let portNames: [String]

    public init(
        origin: String,
        initID: String,
        portNames: [String]
    ) {
        self.origin = origin
        self.initID = initID
        self.portNames = portNames
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case origin
        case initID = "initId"
        case portNames
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard try container.decode(String.self, forKey: .type) == "init"
        else {
            throw CodexDesktopMCPAppSandboxError.invalidSession
        }
        origin = try container.decode(String.self, forKey: .origin)
        initID = try container.decode(String.self, forKey: .initID)
        portNames = try container.decode([String].self, forKey: .portNames)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("init", forKey: .type)
        try container.encode(origin, forKey: .origin)
        try container.encode(initID, forKey: .initID)
        try container.encode(portNames, forKey: .portNames)
    }
}

public struct CodexDesktopMCPAppSandboxHostEnvelope:
    Codable,
    Equatable,
    Sendable
{
    public let origin: String
    public let initID: String
    public let portNames: [String]
    public let sandboxID: String
    public let skybridgeCacheState:
        CodexDesktopMCPAppSandboxCacheState?

    public init(
        origin: String,
        initID: String,
        portNames: [String],
        sandboxID: String,
        skybridgeCacheState:
            CodexDesktopMCPAppSandboxCacheState?
    ) {
        self.origin = origin
        self.initID = initID
        self.portNames = portNames
        self.sandboxID = sandboxID
        self.skybridgeCacheState = skybridgeCacheState
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case origin
        case initID = "initId"
        case portNames
        case sandboxID = "sandboxId"
        case skybridgeCacheState
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard try container.decode(String.self, forKey: .type) == "init"
        else {
            throw CodexDesktopMCPAppSandboxError.invalidSession
        }
        origin = try container.decode(String.self, forKey: .origin)
        initID = try container.decode(String.self, forKey: .initID)
        portNames = try container.decode([String].self, forKey: .portNames)
        sandboxID = try container.decode(String.self, forKey: .sandboxID)
        skybridgeCacheState = try container.decodeIfPresent(
            CodexDesktopMCPAppSandboxCacheState.self,
            forKey: .skybridgeCacheState
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("init", forKey: .type)
        try container.encode(origin, forKey: .origin)
        try container.encode(initID, forKey: .initID)
        try container.encode(portNames, forKey: .portNames)
        try container.encode(sandboxID, forKey: .sandboxID)
        try container.encodeIfPresent(
            skybridgeCacheState,
            forKey: .skybridgeCacheState
        )
    }
}

public struct CodexDesktopMCPAppSandboxSession:
    Equatable,
    Sendable
{
    public let appSessionID: String
    public let ownerID: String
    public let guestID: String
    public let targetOrigin: String
    public let source: CodexDesktopMCPAppSandboxSource
    public let skybridgeCacheState:
        CodexDesktopMCPAppSandboxCacheState?

    public init(
        appSessionID: String,
        ownerID: String,
        guestID: String,
        targetOrigin: String,
        source: CodexDesktopMCPAppSandboxSource,
        skybridgeCacheState:
            CodexDesktopMCPAppSandboxCacheState?
    ) {
        self.appSessionID = appSessionID
        self.ownerID = ownerID
        self.guestID = guestID
        self.targetOrigin = targetOrigin
        self.source = source
        self.skybridgeCacheState = skybridgeCacheState
    }
}

public struct CodexDesktopMCPAppSandboxHostRoute:
    Equatable,
    Sendable
{
    public let channel: String
    public let appSessionID: String
    public let ownerID: String
    public let targetOrigin: String
    public let envelope: CodexDesktopMCPAppSandboxHostEnvelope

    public var expectedTransferredPortCount: Int {
        envelope.portNames.count + 1
    }

    public init(
        appSessionID: String,
        ownerID: String,
        targetOrigin: String,
        envelope: CodexDesktopMCPAppSandboxHostEnvelope
    ) {
        channel =
            CodexDesktopMCPAppSandboxProtocol.hostMessageChannel
        self.appSessionID = appSessionID
        self.ownerID = ownerID
        self.targetOrigin = targetOrigin
        self.envelope = envelope
    }

    public func validateDelivery(
        appSessionID: String,
        targetOrigin: String
    ) throws {
        guard self.appSessionID == appSessionID else {
            throw CodexDesktopMCPAppSandboxError.appSessionMismatch
        }
        guard self.targetOrigin == targetOrigin else {
            throw CodexDesktopMCPAppSandboxError.targetOriginMismatch
        }
    }
}

public actor CodexDesktopMCPAppSandboxRouter {
    private struct OwnerSandboxKey: Hashable {
        let ownerID: String
        let sandboxID: String
    }

    private var sessionsByGuest:
        [String: CodexDesktopMCPAppSandboxSession] = [:]
    private var guestByOwnerSandbox:
        [OwnerSandboxKey: String] = [:]

    public init() {}

    public func register(
        _ session: CodexDesktopMCPAppSandboxSession
    ) throws {
        guard !session.appSessionID.isEmpty,
              !session.ownerID.isEmpty,
              !session.guestID.isEmpty,
              !session.targetOrigin.isEmpty
        else {
            throw CodexDesktopMCPAppSandboxError.invalidSession
        }
        guard sessionsByGuest[session.guestID] == nil else {
            throw CodexDesktopMCPAppSandboxError.duplicateGuest
        }
        let key = OwnerSandboxKey(
            ownerID: session.ownerID,
            sandboxID: session.source.sandboxID
        )
        guard guestByOwnerSandbox[key] == nil else {
            throw CodexDesktopMCPAppSandboxError
                .duplicateOwnerSandbox
        }
        sessionsByGuest[session.guestID] = session
        guestByOwnerSandbox[key] = session.guestID
    }

    public func unregister(guestID: String) {
        guard let session = sessionsByGuest.removeValue(
            forKey: guestID
        ) else {
            return
        }
        guestByOwnerSandbox.removeValue(
            forKey: OwnerSandboxKey(
                ownerID: session.ownerID,
                sandboxID: session.source.sandboxID
            )
        )
    }

    public func routeGuestMessage(
        guestID: String,
        envelope: CodexDesktopMCPAppSandboxGuestEnvelope,
        transferredPortCount: Int
    ) throws -> CodexDesktopMCPAppSandboxHostRoute {
        guard let session = sessionsByGuest[guestID] else {
            throw CodexDesktopMCPAppSandboxError.unknownGuest
        }
        guard envelope.origin == session.source.origin else {
            throw CodexDesktopMCPAppSandboxError.originMismatch
        }
        guard envelope.initID == session.source.initID else {
            throw CodexDesktopMCPAppSandboxError.initIDMismatch
        }
        try CodexDesktopMCPAppSandboxProtocol.validatePortNames(
            envelope.portNames
        )
        guard transferredPortCount == envelope.portNames.count + 1
        else {
            throw CodexDesktopMCPAppSandboxError.portCountMismatch
        }

        return CodexDesktopMCPAppSandboxHostRoute(
            appSessionID: session.appSessionID,
            ownerID: session.ownerID,
            targetOrigin: session.targetOrigin,
            envelope: CodexDesktopMCPAppSandboxHostEnvelope(
                origin: envelope.origin,
                initID: envelope.initID,
                portNames: envelope.portNames,
                sandboxID: session.source.sandboxID,
                skybridgeCacheState:
                    session.skybridgeCacheState
            )
        )
    }
}
