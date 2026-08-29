#if SWIFT_PACKAGE
    import CodexPadDomain
    import CodexPadProtocolBridge
#endif
import CryptoKit
import Foundation

public enum CodexDesktopFetchStreamState:
    String, Equatable, Sendable
{
    case idle
    case started
    case response
    case streaming
    case complete
    case error
    case cancelled
}

public struct CodexDesktopFetchStreamDiagnostic: Equatable, Sendable {
    public private(set) var requestID: String? = nil
    public private(set) var state: CodexDesktopFetchStreamState = .idle

    public init() {}

    public mutating func start(requestID: String) {
        self.requestID = requestID
        state = .started
    }

    public mutating func cancel(requestID: String) {
        guard self.requestID == requestID else {
            return
        }
        state = .cancelled
    }

    public mutating func reset() {
        requestID = nil
        state = .idle
    }

    public mutating func observe(_ message: CodexDesktopHostMessage) {
        guard case let .event(type, payload) = message,
              type.hasPrefix("fetch-stream-"),
              case let .object(fields) = payload,
              case let .string(messageRequestID)? = fields["requestId"],
              messageRequestID == requestID
        else {
            return
        }

        switch type {
        case "fetch-stream-response":
            guard !isTerminal else { return }
            state = .response
        case "fetch-stream-event":
            guard !isTerminal else { return }
            state = .streaming
        case "fetch-stream-error":
            guard state != .cancelled else { return }
            state = .error
        case "fetch-stream-complete":
            guard state != .error, state != .cancelled else { return }
            state = .complete
        default:
            break
        }
    }

    private var isTerminal: Bool {
        state == .complete || state == .error || state == .cancelled
    }
}

public struct CodexDesktopNetworkTransportRequest:
    Equatable,
    Sendable
{
    public let url: URL
    public let method: String
    public let headers: [String: String]
    public let body: Data?
    public let timeoutInterval: TimeInterval?

    public init(
        url: URL,
        method: String,
        headers: [String: String],
        body: Data?,
        timeoutInterval: TimeInterval? = nil
    ) {
        self.url = url
        self.method = method
        self.headers = headers
        self.body = body
        self.timeoutInterval = timeoutInterval
    }
}

public struct CodexDesktopNetworkTransportResponse:
    Equatable,
    Sendable
{
    public let status: Int
    public let headers: [String: String]
    public let body: Data

    public init(
        status: Int,
        headers: [String: String],
        body: Data
    ) {
        self.status = status
        self.headers = headers
        self.body = body
    }
}

public protocol CodexDesktopNetworkFetchTransport: Sendable {
    func execute(
        _ request: CodexDesktopNetworkTransportRequest
    ) async throws -> CodexDesktopNetworkTransportResponse
}

public enum CodexDesktopProductURLSession {
    public static let shared = URLSession(configuration: configuration())

    public static func configuration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.default
        configuration.waitsForConnectivity = true
        configuration.allowsExpensiveNetworkAccess = true
        configuration.allowsConstrainedNetworkAccess = true
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpMaximumConnectionsPerHost = 4
        configuration.httpShouldSetCookies = true
        configuration.httpCookieStorage = .shared
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 180
        // Leave connectionProxyDictionary unset. URLSession must inherit the
        // iPad's system proxy/VPN route rather than bypassing it.
        return configuration
    }
}

public enum CodexDesktopNetworkTransportDiagnostic {
    public static func errorSummary(_ error: any Error) -> String {
        let root = error as NSError
        var components = [
            "domain=\(root.domain)",
            "code=\(root.code)",
        ]
        if let underlying = root.userInfo[NSUnderlyingErrorKey] as? NSError {
            components.append("underlyingDomain=\(underlying.domain)")
            components.append("underlyingCode=\(underlying.code)")
        }
        if let streamDomain = integerUserInfoValue(
            root.userInfo["_kCFStreamErrorDomainKey"]
        ) {
            components.append("streamDomain=\(streamDomain)")
        }
        if let streamCode = integerUserInfoValue(
            root.userInfo["_kCFStreamErrorCodeKey"]
        ) {
            components.append("streamCode=\(streamCode)")
        }
        return components.joined(separator: " ")
    }

    public static func isRetryablePreResponseTLSFailure(
        _ error: any Error
    ) -> Bool {
        if let urlError = error as? URLError {
            return urlError.code == .secureConnectionFailed
        }
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain
            && nsError.code == URLError.secureConnectionFailed.rawValue
    }

    private static func integerUserInfoValue(_ value: Any?) -> Int? {
        if let value = value as? NSNumber {
            return value.intValue
        }
        return value as? Int
    }
}

public struct CodexDesktopNetworkStreamTransportResponse: Sendable {
    public let status: Int
    public let headers: [String: String]
    public let body: AsyncThrowingStream<Data, any Error>

    public init(
        status: Int,
        headers: [String: String],
        body: AsyncThrowingStream<Data, any Error>
    ) {
        self.status = status
        self.headers = headers
        self.body = body
    }
}

public protocol CodexDesktopNetworkStreamTransport: Sendable {
    func executeStream(
        _ request: CodexDesktopNetworkTransportRequest
    ) async throws -> CodexDesktopNetworkStreamTransportResponse
}

public struct CodexDesktopResponseHeaderDeadlineNetworkStreamTransport:
    CodexDesktopNetworkStreamTransport,
    Sendable
{
    private let base: any CodexDesktopNetworkStreamTransport
    private let deadline: Duration

    public init(
        base: any CodexDesktopNetworkStreamTransport,
        deadline: Duration = .seconds(120)
    ) {
        self.base = base
        self.deadline = deadline
    }

    public func executeStream(
        _ request: CodexDesktopNetworkTransportRequest
    ) async throws -> CodexDesktopNetworkStreamTransportResponse {
        let base = base
        let deadline = deadline
        let race = AsyncThrowingStream<
            CodexDesktopNetworkStreamTransportResponse,
            any Error
        > { continuation in
            let requestTask = Task {
                do {
                    continuation.yield(
                        try await base.executeStream(request)
                    )
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            let deadlineTask = Task {
                do {
                    try await ContinuousClock().sleep(for: deadline)
                    continuation.finish(
                        throwing: URLError(.timedOut)
                    )
                } catch is CancellationError {
                    // The response arrived or the caller cancelled first.
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                requestTask.cancel()
                deadlineTask.cancel()
            }
        }
        var iterator = race.makeAsyncIterator()
        guard let response = try await iterator.next() else {
            throw CancellationError()
        }
        return response
    }
}

public struct CodexDesktopRetryingNetworkStreamTransport:
    CodexDesktopNetworkStreamTransport,
    Sendable
{
    private let base: any CodexDesktopNetworkStreamTransport
    private let maximumAttempts: Int
    private let retryDelay: Duration

    public init(
        base: any CodexDesktopNetworkStreamTransport,
        maximumAttempts: Int = 2,
        retryDelay: Duration = .milliseconds(300)
    ) {
        self.base = base
        self.maximumAttempts = max(1, maximumAttempts)
        self.retryDelay = retryDelay
    }

    public func executeStream(
        _ request: CodexDesktopNetworkTransportRequest
    ) async throws -> CodexDesktopNetworkStreamTransportResponse {
        var attempt = 1
        while true {
            do {
                return try await base.executeStream(request)
            } catch {
                guard attempt < maximumAttempts,
                      CodexDesktopNetworkTransportDiagnostic
                          .isRetryablePreResponseTLSFailure(error)
                else {
                    throw error
                }
                attempt += 1
                if retryDelay > .zero {
                    try await ContinuousClock().sleep(for: retryDelay)
                }
            }
        }
    }
}

public struct CodexDesktopURLSessionNetworkStreamTransport:
    CodexDesktopNetworkStreamTransport,
    Sendable
{
    private let session: URLSession

    public init(session: URLSession = CodexDesktopProductURLSession.shared) {
        self.session = session
    }

    public func executeStream(
        _ request: CodexDesktopNetworkTransportRequest
    ) async throws -> CodexDesktopNetworkStreamTransportResponse {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body
        if let timeoutInterval = request.timeoutInterval {
            urlRequest.timeoutInterval = timeoutInterval
        }
        for (name, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }

        let (bytes, response): (URLSession.AsyncBytes, URLResponse)
        do {
            (bytes, response) = try await session.bytes(for: urlRequest)
        } catch let error as URLError {
            Self.recordTransportFailure(error, url: request.url)
            throw error
        } catch {
            Self.recordTransportFailure(error, url: request.url)
            throw error
        }
        guard let httpResponse = response as? HTTPURLResponse else {
            throw CodexDesktopNetworkFetchError.invalidHTTPResponse
        }
        var headers: [String: String] = [:]
        for (name, value) in httpResponse.allHeaderFields {
            headers[String(describing: name).lowercased()] =
                String(describing: value)
        }
        let body = AsyncThrowingStream<Data, any Error> {
            continuation in
            let task = Task {
                do {
                    var chunk = Data()
                    chunk.reserveCapacity(16_384)
                    for try await byte in bytes {
                        try Task.checkCancellation()
                        chunk.append(byte)
                        if byte == 0x0A || chunk.count >= 16_384 {
                            continuation.yield(chunk)
                            chunk.removeAll(keepingCapacity: true)
                        }
                    }
                    if !chunk.isEmpty {
                        continuation.yield(chunk)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
        return .init(
            status: httpResponse.statusCode,
            headers: headers,
            body: body
        )
    }

    private static func recordTransportFailure(
        _ error: Error,
        url: URL
    ) {
        let code: String
        if let urlError = error as? URLError {
            code = "NSURLErrorDomain:\(urlError.code.rawValue)"
        } else {
            code = String(describing: type(of: error))
        }
        let host = url.host ?? "unknown"
        let path = url.path.isEmpty ? "/" : url.path
        UserDefaults.standard.set(
            "stage=stream_headers host=\(host) path=\(path) error=\(code) "
                + CodexDesktopNetworkTransportDiagnostic.errorSummary(error),
            forKey: "codex.desktop.last-network-stream-transport-diagnostic"
        )
    }
}

public struct CodexDesktopURLSessionNetworkFetchTransport:
    CodexDesktopNetworkFetchTransport,
    Sendable
{
    private let session: URLSession

    public init(session: URLSession = CodexDesktopProductURLSession.shared) {
        self.session = session
    }

    public func execute(
        _ request: CodexDesktopNetworkTransportRequest
    ) async throws -> CodexDesktopNetworkTransportResponse {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body
        if let timeoutInterval = request.timeoutInterval {
            urlRequest.timeoutInterval = timeoutInterval
        }
        for (name, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }

        let (body, response) = try await session.data(for: urlRequest)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw CodexDesktopNetworkFetchError.invalidHTTPResponse
        }
        var headers: [String: String] = [:]
        for (name, value) in httpResponse.allHeaderFields {
            headers[String(describing: name)] = String(describing: value)
        }
        return CodexDesktopNetworkTransportResponse(
            status: httpResponse.statusCode,
            headers: headers,
            body: body
        )
    }
}

public enum CodexDesktopNetworkFetchError:
    Error,
    Equatable,
    Sendable
{
    case invalidURL
    case invalidHTTPResponse
    case invalidJSONResponse
    case invalidDataURL
    case timedOut
    case deviceCheckRegistrationFailed(status: Int, message: String)
}

/// Shares the authenticated product bootstrap across renderer windows.
///
/// Desktop Codex opens the realtime avatar in a second renderer. On iPad both
/// renderers traverse the native fetch bridge, and issuing the same short-lived
/// Statsig bootstrap twice can leave the overlay waiting after the primary
/// renderer has already received a valid response. Scope the cached response to
/// one ChatGPT account and keep it only briefly so feature changes are still
/// picked up without relaunching the app.
public actor CodexDesktopStatsigBootstrapResponseCache {
    private struct Entry: Sendable {
        let response: CodexDesktopNetworkTransportResponse
        let storedAt: Date
    }

    private let maximumAge: TimeInterval
    private var entries: [String: Entry] = [:]

    public init(maximumAge: TimeInterval = 300) {
        self.maximumAge = maximumAge
    }

    func response(
        for accountID: String?,
        requestBodyFingerprint: String
    ) -> CodexDesktopNetworkTransportResponse? {
        guard let accountID, !accountID.isEmpty,
              let entry = entries[cacheKey(
                  accountID: accountID,
                  requestBodyFingerprint: requestBodyFingerprint
              )]
        else {
            return nil
        }
        guard Date().timeIntervalSince(entry.storedAt) <= maximumAge else {
            entries.removeValue(
                forKey: cacheKey(
                    accountID: accountID,
                    requestBodyFingerprint: requestBodyFingerprint
                )
            )
            return nil
        }
        return entry.response
    }

    func store(
        _ response: CodexDesktopNetworkTransportResponse,
        for accountID: String?,
        requestBodyFingerprint: String
    ) {
        guard let accountID, !accountID.isEmpty,
              (200 ..< 300).contains(response.status)
        else {
            return
        }
        entries[
            cacheKey(
                accountID: accountID,
                requestBodyFingerprint: requestBodyFingerprint
            )
        ] = Entry(response: response, storedAt: Date())
    }

    private func cacheKey(
        accountID: String,
        requestBodyFingerprint: String
    ) -> String {
        "\(accountID):\(requestBodyFingerprint)"
    }
}

public struct CodexDesktopNetworkFetchClient: Sendable {
    public static let releasedProductAPIBaseURL =
        URL(string: "https://chatgpt.com/backend-api")!

    private static let attachAuthHeader =
        "X-OpenAI-Attach-Auth"
    private static let attachIntegrityStateHeader =
        "X-OpenAI-Attach-Integrity-State"
    private static let attachDesktopSurfaceHeader =
        "X-OpenAI-Attach-Desktop-Surface"
    private static let attachDeviceCheckTokenHeader =
        "X-OpenAI-Attach-DeviceCheck-Token"
    /// Electron's `deviceCheckCookieManager.attachToken` places the native
    /// token in this sentinel header as a JSON object.  The renderer-facing
    /// `X-OpenAI-Attach-DeviceCheck-Token` header is only a boolean request
    /// marker and must never be forwarded as the token itself.
    private static let deviceCheckTokenHeader = "x-sentinel-dc"
    private static let base64BodyHeader = "x-codex-base64"
    private static let binaryResponseHeader =
        "x-codex-binary-response"

    private let transport: any CodexDesktopNetworkFetchTransport
    private let streamTransport: any CodexDesktopNetworkStreamTransport
    private let deviceCheckTokenProvider:
        any CodexDesktopDeviceCheckTokenProviding
    private let statsigInitializeTimeout: Duration
    private let statsigBootstrapCache:
        CodexDesktopStatsigBootstrapResponseCache

    public init(
        transport:
            any CodexDesktopNetworkFetchTransport =
                CodexDesktopURLSessionNetworkFetchTransport(),
        streamTransport:
            any CodexDesktopNetworkStreamTransport =
                CodexDesktopRetryingNetworkStreamTransport(
                    base:
                        CodexDesktopResponseHeaderDeadlineNetworkStreamTransport(
                            base:
                                CodexDesktopURLSessionNetworkStreamTransport()
                        )
                ),
        deviceCheckTokenProvider:
            any CodexDesktopDeviceCheckTokenProviding =
                CodexDesktopPlatformDeviceCheckTokenProvider(),
        statsigInitializeTimeout: Duration = .seconds(5),
        statsigBootstrapCache:
            CodexDesktopStatsigBootstrapResponseCache =
                CodexDesktopStatsigBootstrapResponseCache()
    ) {
        self.transport = transport
        self.streamTransport = streamTransport
        self.deviceCheckTokenProvider = deviceCheckTokenProvider
        self.statsigInitializeTimeout = statsigInitializeTimeout
        self.statsigBootstrapCache = statsigBootstrapCache
    }

    public func stream(
        _ request: CodexDesktopFetchStreamRequest,
        credentials: CodexOfficialCredentials?,
        refreshCredentials:
            (@Sendable () async throws -> CodexOfficialCredentials)? = nil,
        send: @escaping @Sendable (CodexDesktopHostMessage) async -> Void
    ) async {
        do {
            let resolvedURL = try Self.resolve(request.url)
            guard resolvedURL.scheme?.lowercased() == "http"
                    || resolvedURL.scheme?.lowercased() == "https"
            else {
                throw CodexDesktopNetworkFetchError.invalidURL
            }
            var headers = request.headers ?? [:]
            let explicitAuth = Self.takeBooleanHeader(
                Self.attachAuthHeader,
                from: &headers
            )
            // The desktop renderer uses this marker for Electron's
            // integrity-state injector. iOS has no equivalent injector;
            // forwarding the marker verbatim makes the backend wait for a
            // state value that can never arrive.
            _ = Self.takeBooleanHeader(
                Self.attachIntegrityStateHeader,
                from: &headers
            )
            // This is another renderer-to-Electron control marker, not an
            // HTTP header understood by the product API.
            _ = Self.takeBooleanHeader(
                Self.attachDesktopSurfaceHeader,
                from: &headers
            )
            let wantsDeviceCheck = Self.takeBooleanHeader(
                Self.attachDeviceCheckTokenHeader,
                from: &headers
            )
            let hasAuthorization = Self.hasHeader(
                "Authorization",
                in: headers
            )
            let canRefreshChatGPTCredentials =
                !hasAuthorization
                    && credentials?.authMethod == .chatGPT
                    && refreshCredentials != nil
            let attachAuth =
                (explicitAuth || Self.shouldInferAuth(for: resolvedURL))
                    && !hasAuthorization
            if attachAuth {
                guard Self.isDesktopAuthAllowedURL(resolvedURL) else {
                    throw CodexDesktopNetworkFetchError.invalidURL
                }
                if Self.shouldInferAuth(for: resolvedURL) {
                    guard let credentials,
                          Self.canAttach(
                              credentials: credentials,
                              to: resolvedURL
                          )
                    else {
                        await send(Self.streamError(
                            requestID: request.requestID,
                            message: "ChatGPT authentication required"
                        ))
                        return
                    }
                    Self.setHeader(
                        "Authorization",
                        value: "Bearer \(credentials.accessToken)",
                        in: &headers
                    )
                    if let accountID = credentials.accountID,
                       !accountID.isEmpty
                    {
                        Self.setHeader(
                            "ChatGPT-Account-Id",
                            value: accountID,
                            in: &headers
                        )
                    }
                } else if let credentials,
                          Self.canAttach(
                              credentials: credentials,
                              to: resolvedURL
                          )
                {
                    Self.setHeader(
                        "Authorization",
                        value: "Bearer \(credentials.accessToken)",
                        in: &headers
                    )
                    if credentials.authMethod == .chatGPT,
                       let accountID = credentials.accountID,
                       !accountID.isEmpty
                    {
                        Self.setHeader(
                            "ChatGPT-Account-Id",
                            value: accountID,
                            in: &headers
                        )
                    }
                }
            }
            if wantsDeviceCheck {
                if let token = await deviceCheckTokenProvider.token(),
                   !token.isEmpty
                {
                    let payload = #"{"token":""# + token + #""}"#
                    Self.setHeader(
                        Self.deviceCheckTokenHeader,
                        value: payload,
                        in: &headers
                    )
                }
            }
            let sourceBody = Self.normalizedChatGPTConversationBody(
                request.body,
                url: resolvedURL,
                credentials: credentials
            )
            let body = sourceBody.map { Data($0.utf8) }
            if let sourceBody,
               Self.looksLikeJSON(sourceBody),
               !Self.hasHeader("Content-Type", in: headers)
            {
                Self.setHeader(
                    "Content-Type",
                    value: "application/json",
                    in: &headers
                )
            }
            if !Self.hasHeader("Accept", in: headers) {
                Self.setHeader(
                    "Accept",
                    value: request.format?.lowercased() == "ndjson"
                        ? "application/x-ndjson"
                        : "text/event-stream"
                        + ", application/json"
                        + ";q=0.9",
                    in: &headers
                )
            }
            if !Self.hasHeader("Originator", in: headers) {
                Self.setHeader(
                    "Originator",
                    value: "Codex Desktop",
                    in: &headers
                )
            }
            var transportRequest = CodexDesktopNetworkTransportRequest(
                url: resolvedURL,
                method: request.method,
                headers: headers,
                body: body,
                timeoutInterval: 120
            )
            var response = try await streamTransport.executeStream(
                transportRequest
            )
            if canRefreshChatGPTCredentials,
               response.status == 401,
               let refreshCredentials
            {
                let errorBody = try await Self.readStreamErrorBody(
                    response.body
                )
                if Self.isExpiredChatGPTTokenResponse(
                    status: response.status,
                    body: errorBody
                ) {
                    let refreshed = try await refreshCredentials()
                    guard refreshed.authMethod == .chatGPT,
                          Self.canAttach(
                              credentials: refreshed,
                              to: resolvedURL
                          )
                    else {
                        await send(Self.streamError(
                            requestID: request.requestID,
                            message: "ChatGPT authentication required"
                        ))
                        return
                    }
                    var refreshedHeaders = headers
                    Self.setHeader(
                        "Authorization",
                        value: "Bearer \(refreshed.accessToken)",
                        in: &refreshedHeaders
                    )
                    Self.removeHeader(
                        "ChatGPT-Account-Id",
                        from: &refreshedHeaders
                    )
                    if let accountID = refreshed.accountID,
                       !accountID.isEmpty
                    {
                        Self.setHeader(
                            "ChatGPT-Account-Id",
                            value: accountID,
                            in: &refreshedHeaders
                        )
                    }
                    transportRequest = .init(
                        url: resolvedURL,
                        method: request.method,
                        headers: refreshedHeaders,
                        body: body,
                        timeoutInterval: 120
                    )
                    response = try await streamTransport.executeStream(
                        transportRequest
                    )
                } else {
                    await send(Self.streamError(
                        requestID: request.requestID,
                        message: Self.publicStreamHTTPError(
                            status: response.status,
                            body: errorBody
                        )
                    ))
                    return
                }
            }
            guard (200 ..< 300).contains(response.status) else {
                let errorBody = try await Self.readStreamErrorBody(
                    response.body
                )
                await send(Self.streamError(
                    requestID: request.requestID,
                    message: Self.publicStreamHTTPError(
                        status: response.status,
                        body: errorBody
                    )
                ))
                return
            }
            await send(
                .event(
                    type: "fetch-stream-response",
                    payload: .object([
                        "requestId": .string(request.requestID),
                        "status": .integer(Int64(response.status)),
                        "headers": .object(
                            response.headers.mapValues {
                                .string($0)
                            }
                        ),
                    ])
                )
            )
            var parser = CodexDesktopFetchStreamParser(
                format: request.format ?? "sse"
            )
            for try await chunk in response.body {
                try Task.checkCancellation()
                for event in parser.append(chunk) {
                    await send(
                        Self.streamEvent(
                            requestID: request.requestID,
                            event: event
                        )
                    )
                }
            }
            for event in parser.finish() {
                await send(
                    Self.streamEvent(
                        requestID: request.requestID,
                        event: event
                    )
                )
            }
            await send(Self.streamComplete(request.requestID))
        } catch is CancellationError {
            await send(Self.streamComplete(request.requestID))
        } catch let error as URLError where error.code == .cancelled {
            await send(Self.streamComplete(request.requestID))
        } catch let error as URLError {
            await send(
                Self.streamError(
                    requestID: request.requestID,
                    message:
                        "Network stream failed (\(error.code.rawValue))"
                )
            )
        } catch let error as CodexDesktopNetworkFetchError {
            await send(
                Self.streamError(
                    requestID: request.requestID,
                    message: "Network stream failed (\(error))"
                )
            )
        } catch {
            await send(
                Self.streamError(
                    requestID: request.requestID,
                    message:
                        "Network stream failed ("
                        + String(describing: type(of: error))
                        + ")"
                )
            )
        }
    }

    private static func streamEvent(
        requestID: String,
        event: CodexDesktopParsedStreamEvent
    ) -> CodexDesktopHostMessage {
        var fields: [String: CodexJSONValue] = [
            "requestId": .string(requestID),
            "data": .string(event.data),
        ]
        if let name = event.event {
            fields["event"] = .string(name)
        }
        return .event(
            type: "fetch-stream-event",
            payload: .object(fields)
        )
    }

    private static func streamComplete(
        _ requestID: String
    ) -> CodexDesktopHostMessage {
        .event(
            type: "fetch-stream-complete",
            payload: .object(["requestId": .string(requestID)])
        )
    }

    private static func streamError(
        requestID: String,
        message: String
    ) -> CodexDesktopHostMessage {
        .event(
            type: "fetch-stream-error",
            payload: .object([
                "requestId": .string(requestID),
                "error": .string(message),
            ])
        )
    }

    private static func publicStreamHTTPError(
        status: Int,
        body: Data
    ) -> String {
        let fallback = "Request failed with status \(status)"
        guard !body.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: body)
        else {
            return fallback
        }

        func firstString(
            in value: Any,
            keys: Set<String>
        ) -> String? {
            if let dictionary = value as? [String: Any] {
                for key in keys {
                    if let string = dictionary[key] as? String,
                       !string.isEmpty
                    {
                        return String(string.prefix(160))
                    }
                }
                for nested in dictionary.values {
                    if let found = firstString(
                        in: nested,
                        keys: keys
                    ) {
                        return found
                    }
                }
            } else if let array = value as? [Any] {
                for nested in array {
                    if let found = firstString(
                        in: nested,
                        keys: keys
                    ) {
                        return found
                    }
                }
            }
            return nil
        }

        let code = firstString(
            in: object,
            keys: ["code", "error_code", "type"]
        )
        let message = firstString(
            in: object,
            keys: ["message", "detail", "error"]
        )
        let suffix = [code, message]
            .compactMap { $0 }
            .joined(separator: ": ")
        return suffix.isEmpty ? fallback : "\(fallback): \(suffix)"
    }

    private static func readStreamErrorBody(
        _ body: AsyncThrowingStream<Data, any Error>
    ) async throws -> Data {
        var errorBody = Data()
        for try await chunk in body {
            guard errorBody.count < 65_536 else {
                break
            }
            errorBody.append(
                chunk.prefix(65_536 - errorBody.count)
            )
        }
        return errorBody
    }

    public func response(
        to request: CodexDesktopFetchRequest,
        credentials: CodexOfficialCredentials?,
        refreshCredentials:
            (@Sendable () async throws -> CodexOfficialCredentials)? = nil
    ) async -> CodexDesktopHostMessage {
        guard request.isNetworkRequest else {
            return failure(
                request,
                status: 400,
                message: "Invalid network fetch URL"
            )
        }

        do {
            let resolvedURL = try Self.resolve(request.url)
            if resolvedURL.scheme?.lowercased() == "data" {
                let response = try Self.decodeDataURL(resolvedURL)
                return try Self.hostResponse(
                    for: request,
                    transportResponse: response,
                    binaryResponse: false
                )
            }

            var headers = request.headers ?? [:]
            let explicitAuth = Self.takeBooleanHeader(
                Self.attachAuthHeader,
                from: &headers
            )
            _ = Self.takeBooleanHeader(
                Self.attachIntegrityStateHeader,
                from: &headers
            )
            _ = Self.takeBooleanHeader(
                Self.attachDesktopSurfaceHeader,
                from: &headers
            )
            let wantsDeviceCheck = Self.takeBooleanHeader(
                Self.attachDeviceCheckTokenHeader,
                from: &headers
            )
            let hasAuthorization = Self.hasHeader(
                "Authorization",
                in: headers
            )
            let canRefreshChatGPTCredentials =
                !hasAuthorization
                    && credentials?.authMethod == .chatGPT
                    && refreshCredentials != nil
            let attachAuth =
                (explicitAuth || Self.shouldInferAuth(for: resolvedURL))
                    && !hasAuthorization
            if attachAuth {
                guard Self.isDesktopAuthAllowedURL(resolvedURL) else {
                    return failure(
                        request,
                        status: 400,
                        message:
                            "Refusing to attach authentication to non-OpenAI URL"
                    )
                }
                if Self.shouldInferAuth(for: resolvedURL) {
                    if let credentials {
                        guard Self.canAttach(
                            credentials: credentials,
                            to: resolvedURL
                        ) else {
                            return failure(
                                request,
                                status: 401,
                                message:
                                    "ChatGPT authentication required"
                            )
                        }
                        Self.setHeader(
                            "Authorization",
                            value: "Bearer \(credentials.accessToken)",
                            in: &headers
                        )
                        if let accountID = credentials.accountID,
                           !accountID.isEmpty
                        {
                            Self.setHeader(
                                "ChatGPT-Account-Id",
                                value: accountID,
                                in: &headers
                            )
                        }
                    } else if !Self.allowsUnauthenticatedAuthProbe(
                        resolvedURL
                    ) {
                        return failure(
                            request,
                            status: 401,
                            message: "ChatGPT authentication required"
                        )
                    }
                } else if let credentials,
                          Self.canAttach(
                              credentials: credentials,
                              to: resolvedURL
                          )
                {
                    Self.setHeader(
                        "Authorization",
                        value: "Bearer \(credentials.accessToken)",
                        in: &headers
                    )
                    if credentials.authMethod == .chatGPT,
                       let accountID = credentials.accountID,
                       !accountID.isEmpty
                    {
                        Self.setHeader(
                            "ChatGPT-Account-Id",
                            value: accountID,
                            in: &headers
                        )
                    }
                }
            }
            if wantsDeviceCheck,
               let token = await deviceCheckTokenProvider.token(),
               !token.isEmpty
            {
                try await registerDeviceCheckCookie(
                    token: token,
                    headers: headers
                )
                let payload = #"{"token":""# + token + #""}"#
                Self.setHeader(
                    Self.deviceCheckTokenHeader,
                    value: payload,
                    in: &headers
                )
            }

            let bodyIsBase64 = Self.takeBooleanHeader(
                Self.base64BodyHeader,
                from: &headers
            )
            let binaryResponse = Self.takeBooleanHeader(
                Self.binaryResponseHeader,
                from: &headers
            )
            let body = try Self.requestBody(
                request.body,
                isBase64: bodyIsBase64
            )
            if !bodyIsBase64,
               let sourceBody = request.body,
               Self.looksLikeJSON(sourceBody),
               !Self.hasHeader("Content-Type", in: headers)
            {
                Self.setHeader(
                    "Content-Type",
                    value: "application/json",
                    in: &headers
                )
            }

            var transportRequest = CodexDesktopNetworkTransportRequest(
                url: resolvedURL,
                method: request.method,
                headers: headers,
                body: body
            )
            var responseAccountID = credentials?.accountID
            var transportResponse: CodexDesktopNetworkTransportResponse
            let statsigRequestBodyFingerprint =
                Self.statsigRequestBodyFingerprint(body)
            if Self.isStatsigBootstrapURL(resolvedURL),
               let cached = await statsigBootstrapCache.response(
                   for: responseAccountID,
                   requestBodyFingerprint: statsigRequestBodyFingerprint
               )
            {
                transportResponse = cached
            } else {
                transportResponse = try await executeTransport(
                    transportRequest,
                    resolvedURL: resolvedURL
                )
                if Self.isStatsigBootstrapURL(resolvedURL) {
                    await statsigBootstrapCache.store(
                        transportResponse,
                        for: responseAccountID,
                        requestBodyFingerprint: statsigRequestBodyFingerprint
                    )
                }
            }
            if canRefreshChatGPTCredentials,
               Self.isExpiredChatGPTTokenResponse(transportResponse),
               let refreshCredentials
            {
                let refreshed = try await refreshCredentials()
                guard refreshed.authMethod == .chatGPT,
                      Self.canAttach(
                          credentials: refreshed,
                          to: resolvedURL
                      )
                else {
                    return failure(
                        request,
                        status: 401,
                        message: "ChatGPT authentication required"
                    )
                }
                var refreshedHeaders = headers
                Self.setHeader(
                    "Authorization",
                    value: "Bearer \(refreshed.accessToken)",
                    in: &refreshedHeaders
                )
                Self.removeHeader(
                    "ChatGPT-Account-Id",
                    from: &refreshedHeaders
                )
                if let accountID = refreshed.accountID,
                   !accountID.isEmpty
                {
                    Self.setHeader(
                        "ChatGPT-Account-Id",
                        value: accountID,
                        in: &refreshedHeaders
                    )
                }
                transportRequest = CodexDesktopNetworkTransportRequest(
                    url: resolvedURL,
                    method: request.method,
                    headers: refreshedHeaders,
                    body: body
                )
                transportResponse = try await executeTransport(
                    transportRequest,
                    resolvedURL: resolvedURL
                )
                responseAccountID = refreshed.accountID
                if Self.isStatsigBootstrapURL(resolvedURL) {
                    await statsigBootstrapCache.store(
                        transportResponse,
                        for: responseAccountID,
                        requestBodyFingerprint: statsigRequestBodyFingerprint
                    )
                }
            }
            return try Self.hostResponse(
                for: request,
                transportResponse: transportResponse,
                binaryResponse: binaryResponse
            )
        } catch CodexDesktopNetworkFetchError.timedOut {
            return failure(
                request,
                status: 499,
                message: "Network request timed out"
            )
        } catch is CancellationError {
            return failure(
                request,
                status: 499,
                message: "Network request cancelled"
            )
        } catch let error as URLError
            where error.code == .cancelled
        {
            return failure(
                request,
                status: 499,
                message: "Network request cancelled"
            )
        } catch {
            return failure(
                request,
                status: 500,
                message: Self.publicErrorMessage(for: error),
                errorCode: Self.publicErrorCode(for: error)
            )
        }
    }

    private static func statsigRequestBodyFingerprint(
        _ body: Data?
    ) -> String {
        SHA256.hash(data: body ?? Data()).map {
            String(format: "%02x", $0)
        }.joined()
    }

    /// Mirrors Electron's `deviceCheckCookieManager.ensureCookie` before the
    /// iOS attestation challenge. URLSession's shared cookie store retains the
    /// `_devicecheck` cookie returned by this endpoint for the subsequent
    /// challenge and conversation requests.
    private func registerDeviceCheckCookie(
        token: String,
        headers: [String: String]
    ) async throws {
        let bundleID =
            Bundle.main.bundleIdentifier ?? "com.mars.codexpad"
        let body = try JSONSerialization.data(
            withJSONObject: [
                "bundle_id": bundleID,
                "device_token": token,
            ]
        )
        var registrationHeaders = headers
        Self.setHeader(
            "Content-Type",
            value: "application/json",
            in: &registrationHeaders
        )
        let response = try await transport.execute(
            .init(
                url: Self.releasedProductAPIBaseURL
                    .appendingPathComponent("devicecheck"),
                method: "POST",
                headers: registrationHeaders,
                body: body,
                timeoutInterval: 30
            )
        )
        guard (200 ..< 300).contains(response.status) else {
            throw CodexDesktopNetworkFetchError
                .deviceCheckRegistrationFailed(
                    status: response.status,
                    message: Self.publicStreamHTTPError(
                        status: response.status,
                        body: response.body
                    )
                )
        }
    }

    /// Downloads one renderer-resolved ChatGPT project file through the same
    /// injectable transport used by the released network bridge.
    ///
    /// Relative Codex API URLs receive official credentials, while absolute
    /// third-party URLs are treated as pre-signed downloads and never inherit
    /// the user's Codex bearer token.
    public func downloadProjectFile(
        downloadURL: String,
        requestHeaders: [String: String],
        credentials: CodexOfficialCredentials?
    ) async throws -> Data {
        let resolvedURL =
            try Self.resolveProjectFileDownloadURL(downloadURL)
        var headers = requestHeaders
        if Self.isOfficialProjectFileAuthURL(resolvedURL),
           !Self.hasHeader("Authorization", in: headers),
           let credentials,
           Self.canAttach(credentials: credentials, to: resolvedURL)
        {
            Self.setHeader(
                "Authorization",
                value: "Bearer \(credentials.accessToken)",
                in: &headers
            )
            if let accountID = credentials.accountID,
               !accountID.isEmpty
            {
                Self.setHeader(
                    "ChatGPT-Account-Id",
                    value: accountID,
                    in: &headers
                )
            }
        }

        let response = try await transport.execute(
            CodexDesktopNetworkTransportRequest(
                url: resolvedURL,
                method: "GET",
                headers: headers,
                body: nil,
                timeoutInterval: 60
            )
        )
        guard (200 ..< 300).contains(response.status) else {
            throw CodexDesktopProjectFileSyncBackend.TransferError(
                status: response.status
            )
        }
        return response.body
    }

    private func executeTransport(
        _ request: CodexDesktopNetworkTransportRequest,
        resolvedURL: URL
    ) async throws -> CodexDesktopNetworkTransportResponse {
        guard Self.isStartupCriticalURL(resolvedURL) else {
            return try await transport.execute(request)
        }

        return try await withThrowingTaskGroup(
            of: CodexDesktopNetworkTransportResponse.self
        ) { group in
            group.addTask {
                try await transport.execute(request)
            }
            group.addTask {
                try await Task.sleep(for: statsigInitializeTimeout)
                throw CodexDesktopNetworkFetchError.timedOut
            }
            defer {
                group.cancelAll()
            }
            guard let response = try await group.next() else {
                throw CodexDesktopNetworkFetchError.timedOut
            }
            return response
        }
    }

    private static func isStartupCriticalURL(
        _ url: URL
    ) -> Bool {
        guard url.scheme?.lowercased() == "https",
              url.port == nil
        else {
            return false
        }

        let host = url.host?.lowercased()
        if host == "ab.chatgpt.com" {
            return url.path == "/v1/initialize"
        }

        guard host == "chatgpt.com" else {
            return false
        }
        return url.path == "/backend-api/wham/statsig/bootstrap"
            || url.path == "/backend-api/wham/accounts/check"
    }

    private static func isStatsigBootstrapURL(
        _ url: URL
    ) -> Bool {
        guard url.scheme?.lowercased() == "https",
              url.port == nil,
              url.host?.lowercased() == "chatgpt.com"
        else {
            return false
        }
        return url.path == "/backend-api/wham/statsig/bootstrap"
    }

    private static func resolve(_ value: String) throws -> URL {
        guard !value.isEmpty else {
            throw CodexDesktopNetworkFetchError.invalidURL
        }
        if let components = URLComponents(string: value),
           let scheme = components.scheme?.lowercased()
        {
            guard scheme == "http"
                    || scheme == "https"
                    || scheme == "data",
                  let url = components.url
            else {
                throw CodexDesktopNetworkFetchError.invalidURL
            }
            if scheme == "http" || scheme == "https" {
                guard url.host != nil else {
                    throw CodexDesktopNetworkFetchError.invalidURL
                }
            }
            return url
        }

        let suffix = value.drop(while: { $0 == "/" })
        guard !suffix.isEmpty,
              let resolved = URL(
                  string:
                      releasedProductAPIBaseURL.absoluteString
                          + "/"
                          + suffix
              )
        else {
            throw CodexDesktopNetworkFetchError.invalidURL
        }
        return resolved
    }

    private static func resolveProjectFileDownloadURL(
        _ value: String
    ) throws -> URL {
        guard !value.isEmpty else {
            throw CodexDesktopNetworkFetchError.invalidURL
        }
        if let components = URLComponents(string: value),
           let scheme = components.scheme?.lowercased()
        {
            guard scheme == "http" || scheme == "https",
                  let url = components.url,
                  url.host != nil
            else {
                throw CodexDesktopNetworkFetchError.invalidURL
            }
            return url
        }

        if value == "/backend-api"
            || value.hasPrefix("/backend-api/")
            || value.hasPrefix("/backend-api?")
        {
            guard let url = URL(
                string: "https://chatgpt.com\(value)"
            ) else {
                throw CodexDesktopNetworkFetchError.invalidURL
            }
            return url
        }

        if value == "/__codex-api"
            || value.hasPrefix("/__codex-api/")
            || value.hasPrefix("/__codex-api?")
        {
            var suffix = String(
                value.dropFirst("/__codex-api".count)
            )
            while suffix.hasPrefix("/") {
                suffix.removeFirst()
            }
            let separator =
                suffix.isEmpty || suffix.hasPrefix("?")
                    ? "" : "/"
            guard let url = URL(
                string:
                    releasedProductAPIBaseURL.absoluteString
                        + separator + suffix
            ) else {
                throw CodexDesktopNetworkFetchError.invalidURL
            }
            return url
        }

        let resolved = try resolve(value)
        guard resolved.scheme?.lowercased() == "http"
                || resolved.scheme?.lowercased() == "https"
        else {
            throw CodexDesktopNetworkFetchError.invalidURL
        }
        return resolved
    }

    private static func isOfficialProjectFileAuthURL(
        _ url: URL
    ) -> Bool {
        guard url.scheme?.lowercased() == "https",
              url.port == nil,
              let host = url.host?.lowercased()
        else {
            return false
        }
        return host == "openai.com"
            || host.hasSuffix(".openai.com")
            || host == "chatgpt.com"
            || host.hasSuffix(".chatgpt.com")
    }

    private static func canAttach(
        credentials: CodexOfficialCredentials,
        to url: URL
    ) -> Bool {
        switch credentials.authMethod {
        case .apiKey:
            guard url.scheme?.lowercased() == "https",
                  url.port == nil,
                  let host = url.host?.lowercased()
            else {
                return false
            }
            return host == "api.openai.com"

        case .chatGPT:
            return isDesktopAuthAllowedURL(url)

        default:
            return false
        }
    }

    private static func shouldInferAuth(for url: URL) -> Bool {
        guard isDesktopAuthAllowedURL(url) else {
            return false
        }
        let path = url.path.replacingOccurrences(
            of: #"/+$"#,
            with: "",
            options: .regularExpression
        )
        return path == "/wham"
            || path.hasPrefix("/wham/")
            || path == "/api/wham"
            || path.hasPrefix("/api/wham/")
            || path == "/backend-api/wham"
            || path.hasPrefix("/backend-api/wham/")
    }

    private static func allowsUnauthenticatedAuthProbe(
        _ url: URL
    ) -> Bool {
        let path = url.path.replacingOccurrences(
            of: #"/+$"#,
            with: "",
            options: .regularExpression
        )
        return path == "/wham/statsig/bootstrap"
            || path == "/api/wham/statsig/bootstrap"
            || path == "/backend-api/wham/statsig/bootstrap"
    }

    private static func isExpiredChatGPTTokenResponse(
        _ response: CodexDesktopNetworkTransportResponse
    ) -> Bool {
        isExpiredChatGPTTokenResponse(
            status: response.status,
            body: response.body
        )
    }

    private static func isExpiredChatGPTTokenResponse(
        status: Int,
        body: Data
    ) -> Bool {
        guard status == 401,
              !body.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: body)
        else {
            return false
        }

        func containsTokenExpired(_ value: Any) -> Bool {
            if let dictionary = value as? [String: Any] {
                return dictionary.contains { key, value in
                    let normalizedKey = key.lowercased()
                    if ["code", "error_code", "type"].contains(normalizedKey),
                       let string = value as? String,
                       string.lowercased() == "token_expired"
                    {
                        return true
                    }
                    return containsTokenExpired(value)
                }
            }
            if let array = value as? [Any] {
                return array.contains(where: containsTokenExpired)
            }
            return false
        }

        return containsTokenExpired(object)
    }

    private static func isConversationStreamURL(_ url: URL) -> Bool {
        let path = url.path
        return path.hasSuffix("/f/conversation")
            || path.hasSuffix("/conversation")
    }

    private static func normalizedChatGPTConversationBody(
        _ body: String?,
        url: URL,
        credentials: CodexOfficialCredentials?
    ) -> String? {
        guard credentials?.authMethod == .chatGPT,
              isConversationStreamURL(url),
              let body,
              let data = body.data(using: .utf8),
              var object = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any],
              let rendererModel = object["model"] as? String,
              rendererModel == "gpt-5-6" || rendererModel == "gpt-5.6-sol"
        else {
            return body
        }
        // ChatGPT-account conversation requests currently reject the desktop
        // catalog aliases. Keep the renderer catalog unchanged while sending
        // the account-supported model on the product conversation route.
        object["model"] = "gpt-5.5"
        guard let normalized = try? JSONSerialization.data(
            withJSONObject: object
        ) else {
            return body
        }
        return String(data: normalized, encoding: .utf8) ?? body
    }

    private static func isDesktopAuthAllowedURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let hostname = url.host?.lowercased()
        else {
            return false
        }

        let hostWithPort: String
        if let port = url.port {
            hostWithPort = "\(hostname):\(port)"
        } else {
            hostWithPort = hostname
        }
        return hostWithPort == "localhost"
            || hostWithPort == "localhost:8000"
            || hostWithPort == "openai.com"
            || hostWithPort.hasSuffix(".openai.com")
            || hostWithPort == "chatgpt.com"
            || (
                hostWithPort.hasSuffix(".chatgpt.com")
                    && !hostWithPort.hasPrefix("ab.")
            )
    }

    private static func requestBody(
        _ body: String?,
        isBase64: Bool
    ) throws -> Data? {
        guard let body else {
            return nil
        }
        if isBase64 {
            guard let decoded = Data(base64Encoded: body) else {
                throw CodexDesktopNetworkFetchError.invalidDataURL
            }
            return decoded
        }
        return Data(body.utf8)
    }

    private static func looksLikeJSON(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard trimmed.hasPrefix("{") || trimmed.hasPrefix("[") else {
            return false
        }
        return (try? JSONSerialization.jsonObject(
            with: Data(value.utf8)
        )) != nil
    }

    private static func hostResponse(
        for request: CodexDesktopFetchRequest,
        transportResponse: CodexDesktopNetworkTransportResponse,
        binaryResponse: Bool
    ) throws -> CodexDesktopHostMessage {
        let headers = normalizedHeaders(transportResponse.headers)
        guard (200 ..< 300).contains(transportResponse.status) else {
            let message =
                String(
                    data: transportResponse.body,
                    encoding: .utf8
                )
                .flatMap { $0.isEmpty ? nil : $0 }
                ?? "Request failed with status \(transportResponse.status)"
            return failure(
                request,
                status: transportResponse.status,
                message: message
            )
        }

        let body: CodexJSONValue
        if transportResponse.status == 204 {
            body = .null
        } else {
            let contentType =
                headerValue("content-type", in: headers) ?? ""
            if contentType.lowercased().contains("application/json"),
               !binaryResponse
            {
                do {
                    let decoded = try JSONDecoder().decode(
                        CodexJSONValue.self,
                        from: transportResponse.body
                    )
                    body = try statsigLookupCompatibleBody(
                        decoded,
                        requestURL: request.url
                    )
                } catch {
                    throw CodexDesktopNetworkFetchError
                        .invalidJSONResponse
                }
            } else {
                body = .object([
                    "base64": .string(
                        transportResponse.body
                            .base64EncodedString()
                    ),
                    "contentType": .string(contentType),
                ])
            }
        }
        return .fetchSuccess(
            requestID: request.requestID,
            status: transportResponse.status,
            headers: headers,
            body: body
        )
    }

    /// Statsig's released v2 bootstrap may expose the realtime-voice config
    /// only under its hashed key and keep the actual value in the top-level
    /// `values` table. The desktop SDK resolves that representation inside
    /// Electron, while the WKWebView path can otherwise return an empty
    /// DynamicConfig for the original key. Preserve the released entry and
    /// add an equivalent original-key/value view for the renderer lookup.
    private static func statsigLookupCompatibleBody(
        _ body: CodexJSONValue,
        requestURL: String
    ) throws -> CodexJSONValue {
        let path = requestURL.split(separator: "?", maxSplits: 1)[0]
        guard path.hasSuffix("/wham/statsig/bootstrap"),
              case var .object(responseFields) = body,
              case let .string(payload)? = responseFields["statsigPayload"],
              let payloadData = payload.data(using: .utf8),
              case var .object(payloadFields) = try JSONDecoder().decode(
                  CodexJSONValue.self,
                  from: payloadData
              ),
              case var .object(configs)? = payloadFields["dynamic_configs"]
        else {
            return body
        }

        let originalID = "1193530394"
        let releasedHashedID = "729731510"
        guard let released = configs[originalID]
                ?? configs[releasedHashedID],
              case var .object(releasedFields) = released
        else {
            return body
        }

        let resolvedValue: CodexJSONValue?
        if let directValue = releasedFields["value"] {
            resolvedValue = directValue
        } else if let pointer = releasedFields["v"],
                  case let .object(values)? = payloadFields["values"]
        {
            let pointerKey: String?
            switch pointer {
            case let .string(value):
                pointerKey = value
            case let .integer(value):
                pointerKey = String(value)
            default:
                pointerKey = nil
            }
            resolvedValue = pointerKey.flatMap { values[$0] }
        } else {
            resolvedValue = nil
        }
        guard let resolvedValue else {
            return body
        }

        releasedFields["value"] = resolvedValue
        let compatibleEntry = CodexJSONValue.object(releasedFields)
        configs[originalID] = compatibleEntry
        if configs[releasedHashedID] != nil {
            configs[releasedHashedID] = compatibleEntry
        }
        payloadFields["dynamic_configs"] = .object(configs)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let compatiblePayload = try encoder.encode(
            CodexJSONValue.object(payloadFields)
        )
        guard let compatiblePayloadString = String(
            data: compatiblePayload,
            encoding: .utf8
        ) else {
            return body
        }
        responseFields["statsigPayload"] = .string(
            compatiblePayloadString
        )
        return .object(responseFields)
    }

    private static func decodeDataURL(
        _ url: URL
    ) throws -> CodexDesktopNetworkTransportResponse {
        let absolute = url.absoluteString
        guard absolute.hasPrefix("data:"),
              let comma = absolute.firstIndex(of: ",")
        else {
            throw CodexDesktopNetworkFetchError.invalidDataURL
        }
        let metadata = String(absolute[absolute.index(
            absolute.startIndex,
            offsetBy: 5
        ) ..< comma])
        let encoded = String(absolute[absolute.index(after: comma)...])
        let parts = metadata.split(
            separator: ";",
            omittingEmptySubsequences: false
        )
        let isBase64 = parts.last?.lowercased() == "base64"
        let contentType =
            parts.first.flatMap { $0.isEmpty ? nil : String($0) }
                ?? "text/plain;charset=US-ASCII"
        let body: Data
        if isBase64 {
            guard let decoded = Data(base64Encoded: encoded) else {
                throw CodexDesktopNetworkFetchError.invalidDataURL
            }
            body = decoded
        } else {
            guard let decoded = encoded.removingPercentEncoding else {
                throw CodexDesktopNetworkFetchError.invalidDataURL
            }
            body = Data(decoded.utf8)
        }
        return CodexDesktopNetworkTransportResponse(
            status: 200,
            headers: ["content-type": contentType],
            body: body
        )
    }

    private static func normalizedHeaders(
        _ headers: [String: String]
    ) -> [String: String] {
        var normalized: [String: String] = [:]
        for (name, value) in headers {
            normalized[name.lowercased()] = value
        }
        return normalized
    }

    private static func headerValue(
        _ name: String,
        in headers: [String: String]
    ) -> String? {
        let target = name.lowercased()
        return headers.first {
            $0.key.lowercased() == target
        }?.value
    }

    private static func hasHeader(
        _ name: String,
        in headers: [String: String]
    ) -> Bool {
        headerValue(name, in: headers) != nil
    }

    private static func setHeader(
        _ name: String,
        value: String,
        in headers: inout [String: String]
    ) {
        if let existing = headers.keys.first(where: {
            $0.caseInsensitiveCompare(name) == .orderedSame
        }) {
            headers.removeValue(forKey: existing)
        }
        headers[name] = value
    }

    private static func removeHeader(
        _ name: String,
        from headers: inout [String: String]
    ) {
        if let existing = headers.keys.first(where: {
            $0.caseInsensitiveCompare(name) == .orderedSame
        }) {
            headers.removeValue(forKey: existing)
        }
    }

    private static func takeBooleanHeader(
        _ name: String,
        from headers: inout [String: String]
    ) -> Bool {
        guard let key = headers.keys.first(where: {
            $0.caseInsensitiveCompare(name) == .orderedSame
        }), let value = headers.removeValue(forKey: key)
        else {
            return false
        }
        return value != "0"
            && value.lowercased() != "false"
    }

    private static func failure(
        _ request: CodexDesktopFetchRequest,
        status: Int,
        message: String,
        errorCode: String? = nil
    ) -> CodexDesktopHostMessage {
        .fetchFailure(
            requestID: request.requestID,
            status: status,
            error: message,
            errorCode: errorCode
        )
    }

    private func failure(
        _ request: CodexDesktopFetchRequest,
        status: Int,
        message: String,
        errorCode: String? = nil
    ) -> CodexDesktopHostMessage {
        Self.failure(
            request,
            status: status,
            message: message,
            errorCode: errorCode
        )
    }

    /// Keep URLSession failure diagnostics stable while never exposing a URL,
    /// response body, header, or localized error text to the renderer.
    private static func publicErrorCode(for error: Error) -> String? {
        guard let urlError = error as? URLError else {
            return nil
        }
        return "NSURLErrorDomain:\(urlError.code.rawValue)"
    }

    private static func publicErrorMessage(for error: Error) -> String {
        switch error {
        case CodexDesktopNetworkFetchError.invalidURL:
            "Invalid network fetch URL"
        case CodexDesktopNetworkFetchError.invalidHTTPResponse:
            "Network fetch returned an invalid HTTP response"
        case CodexDesktopNetworkFetchError.invalidJSONResponse:
            "Network fetch returned invalid JSON"
        case CodexDesktopNetworkFetchError.invalidDataURL:
            "Network fetch payload was invalid"
        case CodexDesktopNetworkFetchError.timedOut:
            "Network request timed out"
        case let CodexDesktopNetworkFetchError
            .deviceCheckRegistrationFailed(status, message):
            "DeviceCheck registration failed (\(status)): \(message)"
        default:
            "Network request failed"
        }
    }
}
