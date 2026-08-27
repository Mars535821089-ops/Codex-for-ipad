#if SWIFT_PACKAGE
    import CodexPadDomain
    import CodexPadProtocolBridge
#endif

/// Desktop-extension request names exposed by the released renderer but not
/// described by the bundled app-server's generated protocol schema.
public enum CodexDesktopExtendedSessionMethod:
    String,
    CaseIterable,
    Equatable,
    Sendable
{
    case threadStartAeon = "thread/startAeon"
    case threadStop = "thread/stop"
    case interactiveLiveSessionsList =
        "interactive/liveSessions/list"
    case interactiveSessionUpload =
        "interactive/session/upload"
    case interactiveSessionSandboxList =
        "interactive/sessionSandbox/list"
    case interactiveSessionSandboxRead =
        "interactive/sessionSandbox/read"
}

/// Lossless request envelope for a desktop session backend.
///
/// Params deliberately remain JSON objects: the released renderer forwards
/// these extension contracts without a public generated schema, so retaining
/// unknown fields is required for desktop parity.
public struct CodexDesktopExtendedSessionRequest:
    Equatable,
    Sendable
{
    public let id: CodexAppServerRequestID
    public let method: CodexDesktopExtendedSessionMethod
    public let params: [String: CodexJSONValue]

    public init(
        id: CodexAppServerRequestID,
        method: CodexDesktopExtendedSessionMethod,
        params: [String: CodexJSONValue]
    ) {
        self.id = id
        self.method = method
        self.params = params
    }
}

/// Injectable bridge to a real desktop session implementation.
///
/// The returned JSON is sent to the renderer unchanged. A host that has no
/// such implementation leaves this dependency unset and receives an explicit
/// not-connected error instead of synthesized session data.
public protocol CodexDesktopExtendedSessionRequesting: Sendable {
    func send(
        _ request: CodexDesktopExtendedSessionRequest
    ) async throws -> CodexJSONValue
}

/// A production-ready dispatcher for the six renderer-only session
/// extensions.  The released renderer sends these methods through one
/// request boundary, while the iPad implementation owns the actual session
/// state (and therefore must not synthesize a response when a capability is
/// missing).  Each operation is injected as an async, sendable handler so the
/// dispatcher can safely cross from the WebView task into MainActor-owned
/// stores without retaining an actor-isolated object directly.
public actor CodexDesktopExtendedSessionBackend:
    CodexDesktopExtendedSessionRequesting
{
    public typealias Handler =
        @Sendable (
            _ request: CodexDesktopExtendedSessionRequest
        ) async throws -> CodexJSONValue

    public struct Handlers: Sendable {
        public let threadStartAeon: Handler?
        public let threadStop: Handler?
        public let interactiveLiveSessionsList: Handler?
        public let interactiveSessionUpload: Handler?
        public let interactiveSessionSandboxList: Handler?
        public let interactiveSessionSandboxRead: Handler?

        public init(
            threadStartAeon: Handler? = nil,
            threadStop: Handler? = nil,
            interactiveLiveSessionsList: Handler? = nil,
            interactiveSessionUpload: Handler? = nil,
            interactiveSessionSandboxList: Handler? = nil,
            interactiveSessionSandboxRead: Handler? = nil
        ) {
            self.threadStartAeon = threadStartAeon
            self.threadStop = threadStop
            self.interactiveLiveSessionsList =
                interactiveLiveSessionsList
            self.interactiveSessionUpload = interactiveSessionUpload
            self.interactiveSessionSandboxList =
                interactiveSessionSandboxList
            self.interactiveSessionSandboxRead =
                interactiveSessionSandboxRead
        }
    }

    public enum Error: Swift.Error, Equatable, Sendable {
        case handlerUnavailable(CodexDesktopExtendedSessionMethod)
    }

    private let handlers: Handlers

    public init(handlers: Handlers) {
        self.handlers = handlers
    }

    public func send(
        _ request: CodexDesktopExtendedSessionRequest
    ) async throws -> CodexJSONValue {
        guard let handler = handler(for: request.method) else {
            throw Error.handlerUnavailable(request.method)
        }
        return try await handler(request)
    }

    private func handler(
        for method: CodexDesktopExtendedSessionMethod
    ) -> Handler? {
        switch method {
        case .threadStartAeon:
            handlers.threadStartAeon
        case .threadStop:
            handlers.threadStop
        case .interactiveLiveSessionsList:
            handlers.interactiveLiveSessionsList
        case .interactiveSessionUpload:
            handlers.interactiveSessionUpload
        case .interactiveSessionSandboxList:
            handlers.interactiveSessionSandboxList
        case .interactiveSessionSandboxRead:
            handlers.interactiveSessionSandboxRead
        }
    }
}
