import Foundation
import Network

public enum CodexLoopbackHTTPServerError:
    Error,
    Equatable,
    Sendable
{
    case addressUnavailable
    case canceled
    case invalidRequest
    case missingAuthorizationCode
    case oauthDenied(code: String, description: String?)
    case callbackUnavailable
}

public enum CodexLoopbackHTTPSuccessRedirect:
    Equatable,
    Sendable
{
    case hosted(URL)
    case local(URL, streamlined: Bool)
}

public enum CodexLoopbackHTTPCallbackFinish:
    Equatable,
    Sendable
{
    case success(CodexLoopbackHTTPSuccessRedirect)
    case failure(String)
}

public protocol CodexLoopbackHTTPServerSession: Sendable {
    var port: UInt16 { get }

    func waitForAuthorizationCode(
        expectedState: String
    ) async throws -> String

    func finish(
        _ result: CodexLoopbackHTTPCallbackFinish
    ) async throws

    func cancel() async
}

public protocol CodexLoopbackHTTPServerStarting: Sendable {
    func start(
        preferredPorts: [UInt16]
    ) async throws -> any CodexLoopbackHTTPServerSession
}

public struct CodexLoopbackHTTPServerFactory:
    CodexLoopbackHTTPServerStarting,
    Sendable
{
    public init() {}

    public func start(
        preferredPorts: [UInt16]
    ) async throws -> any CodexLoopbackHTTPServerSession {
        guard !preferredPorts.isEmpty else {
            throw CodexLoopbackHTTPServerError.addressUnavailable
        }
        for port in preferredPorts {
            do {
                return try await CodexLoopbackHTTPServer.start(
                    port: port
                )
            } catch CodexLoopbackHTTPServerError.addressUnavailable {
                continue
            } catch {
                throw error
            }
        }
        throw CodexLoopbackHTTPServerError.addressUnavailable
    }
}

enum CodexLoopbackHTTPRequestDecision:
    Equatable,
    Sendable
{
    case response(status: Int, body: String)
    case authorizationCode(String)
    case successPage(streamlined: Bool)
    case failure(CodexLoopbackHTTPServerError)
    case cancel
}

enum CodexLoopbackHTTPRequestParser {
    static func decision(
        target: String,
        expectedState: String
    ) -> CodexLoopbackHTTPRequestDecision {
        guard target.hasPrefix("/"),
              let components = URLComponents(
                  string: "http://localhost\(target)"
              )
        else {
            return .response(status: 400, body: "Bad Request")
        }

        var parameters: [String: String] = [:]
        for item in components.queryItems ?? [] {
            parameters[item.name] = item.value ?? ""
        }

        switch components.path {
        case "/auth/callback":
            guard parameters["state"] == expectedState else {
                return .response(
                    status: 400,
                    body: "State mismatch"
                )
            }
            if let error = parameters["error"] {
                return .failure(
                    .oauthDenied(
                        code: error,
                        description: parameters["error_description"]
                    )
                )
            }
            guard let code = parameters["code"], !code.isEmpty else {
                return .failure(.missingAuthorizationCode)
            }
            return .authorizationCode(code)

        case "/success":
            return .successPage(
                streamlined:
                    parameters["codex_streamlined_login"] == "true"
            )

        case "/cancel":
            return .cancel

        default:
            return .response(status: 404, body: "Not Found")
        }
    }
}

enum CodexLoopbackHTTPResponse {
    static func encode(
        status: Int,
        body: String,
        headers: [(String, String)] = []
    ) -> Data {
        let bodyData = Data(body.utf8)
        var lines = [
            "HTTP/1.1 \(status) \(reason(for: status))",
            "Content-Type: text/html; charset=utf-8",
            "Content-Length: \(bodyData.count)",
            "Connection: close",
        ]
        lines.append(
            contentsOf: headers.map { "\($0.0): \($0.1)" }
        )
        var response = Data(
            (lines.joined(separator: "\r\n") + "\r\n\r\n").utf8
        )
        response.append(bodyData)
        return response
    }

    private static func reason(for status: Int) -> String {
        switch status {
        case 200:
            return "OK"
        case 302:
            return "Found"
        case 400:
            return "Bad Request"
        case 404:
            return "Not Found"
        default:
            return "Error"
        }
    }
}

public actor CodexLoopbackHTTPServer:
    CodexLoopbackHTTPServerSession
{
    /// Browser resolution of `localhost` is not stable across iPadOS network
    /// configurations. Listen on both loopback families so the released HTTP
    /// redirect works whether Safari chooses IPv4 or IPv6, without exposing
    /// the callback listener on a Wi-Fi or cellular interface.
    static let loopbackHosts = ["127.0.0.1", "::1"]

    public nonisolated let port: UInt16

    private struct Request: Sendable {
        let target: String
        let responder: Responder
    }

    private actor Responder {
        private let connection: NWConnection
        private var didRespond = false

        init(connection: NWConnection) {
            self.connection = connection
        }

        func respond(
            status: Int,
            body: String,
            headers: [(String, String)] = []
        ) async {
            guard !didRespond else { return }
            didRespond = true
            let data = CodexLoopbackHTTPResponse.encode(
                status: status,
                body: body,
                headers: headers
            )
            await withCheckedContinuation { continuation in
                connection.send(
                    content: data,
                    completion: .contentProcessed { _ in
                        self.connection.cancel()
                        continuation.resume()
                    }
                )
            }
        }

        func cancel() {
            connection.cancel()
        }
    }

    private let listeners: [NWListener]
    private let queue: DispatchQueue
    private var startContinuation:
        CheckedContinuation<Void, any Error>?
    private var readyListenerIDs = Set<ObjectIdentifier>()
    private var requestContinuation:
        CheckedContinuation<Request, any Error>?
    private var queuedRequests: [Request] = []
    private var pendingCallbackResponder: Responder?
    private var terminalError: CodexLoopbackHTTPServerError?
    private var isClosed = false

    private init(
        listeners: [NWListener],
        port: UInt16
    ) {
        self.listeners = listeners
        self.port = port
        queue = DispatchQueue(
            label: "CodexForIPad.loopback-oauth.\(port)"
        )
    }

    static func start(
        port: UInt16
    ) async throws -> CodexLoopbackHTTPServer {
        guard let networkPort = NWEndpoint.Port(rawValue: port) else {
            throw CodexLoopbackHTTPServerError.addressUnavailable
        }
        var listeners: [NWListener] = []
        do {
            for host in Self.loopbackHosts {
                let parameters = NWParameters.tcp
                // The IPv4 and IPv6 listeners intentionally share one
                // numeric port while remaining bound to distinct loopback
                // addresses.
                parameters.allowLocalEndpointReuse = true
                parameters.requiredLocalEndpoint = .hostPort(
                    host: NWEndpoint.Host(host),
                    port: networkPort
                )
                listeners.append(
                    try NWListener(using: parameters)
                )
            }
        } catch {
            listeners.forEach { $0.cancel() }
            throw CodexLoopbackHTTPServerError.addressUnavailable
        }
        let server = CodexLoopbackHTTPServer(
            listeners: listeners,
            port: port
        )
        try await server.begin()
        return server
    }

    private func begin() async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                continuation in
                startContinuation = continuation
                for listener in listeners {
                    let listenerID = ObjectIdentifier(listener)
                    listener.stateUpdateHandler = {
                        [weak self] state in
                        Task {
                            await self?.listenerStateChanged(
                                state,
                                listenerID: listenerID
                            )
                        }
                    }
                    listener.newConnectionHandler = {
                        [weak self] connection in
                        Task {
                            await self?.accept(connection)
                        }
                    }
                    listener.start(queue: queue)
                }
            }
        } onCancel: {
            Task { await self.cancel() }
        }
    }

    private func listenerStateChanged(
        _ state: NWListener.State,
        listenerID: ObjectIdentifier
    ) {
        switch state {
        case .ready:
            readyListenerIDs.insert(listenerID)
            if readyListenerIDs.count == listeners.count {
                startContinuation?.resume()
                startContinuation = nil
            }

        case .failed:
            terminate(with: .addressUnavailable)

        case .cancelled:
            if !isClosed, startContinuation != nil {
                terminate(with: .canceled)
            }

        default:
            break
        }
    }

    private func accept(_ connection: NWConnection) {
        guard !isClosed else {
            connection.cancel()
            return
        }
        connection.start(queue: queue)
        receive(
            from: connection,
            accumulated: Data()
        )
    }

    private func receive(
        from connection: NWConnection,
        accumulated: Data
    ) {
        connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: 8_192
        ) { [weak self] data, _, isComplete, error in
            Task {
                await self?.received(
                    data: data,
                    isComplete: isComplete,
                    error: error,
                    from: connection,
                    accumulated: accumulated
                )
            }
        }
    }

    private func received(
        data: Data?,
        isComplete: Bool,
        error: NWError?,
        from connection: NWConnection,
        accumulated: Data
    ) {
        guard !isClosed else {
            connection.cancel()
            return
        }
        if error != nil {
            connection.cancel()
            return
        }
        var bytes = accumulated
        if let data {
            bytes.append(data)
        }
        guard bytes.count <= 16_384 else {
            let responder = Responder(connection: connection)
            Task {
                await responder.respond(
                    status: 400,
                    body: "Bad Request"
                )
            }
            return
        }
        if let headerEnd = bytes.range(
            of: Data("\r\n\r\n".utf8)
        ) {
            let header = bytes[..<headerEnd.lowerBound]
            guard let requestText = String(
                data: header,
                encoding: .utf8
            ),
                  let firstLine =
                      requestText
                      .split(
                          separator: "\r\n",
                          maxSplits: 1,
                          omittingEmptySubsequences: false
                      )
                      .first
            else {
                let responder = Responder(connection: connection)
                Task {
                    await responder.respond(
                        status: 400,
                        body: "Bad Request"
                    )
                }
                return
            }
            let parts = firstLine.split(
                separator: " ",
                maxSplits: 2,
                omittingEmptySubsequences: true
            )
            guard parts.count == 3, parts[0] == "GET" else {
                let responder = Responder(connection: connection)
                Task {
                    await responder.respond(
                        status: 400,
                        body: "Bad Request"
                    )
                }
                return
            }
            enqueue(
                Request(
                    target: String(parts[1]),
                    responder: Responder(connection: connection)
                )
            )
            return
        }
        guard !isComplete else {
            let responder = Responder(connection: connection)
            Task {
                await responder.respond(
                    status: 400,
                    body: "Bad Request"
                )
            }
            return
        }
        receive(from: connection, accumulated: bytes)
    }

    private func enqueue(_ request: Request) {
        if let continuation = requestContinuation {
            requestContinuation = nil
            continuation.resume(returning: request)
        } else {
            queuedRequests.append(request)
        }
    }

    private func nextRequest() async throws -> Request {
        if let terminalError {
            throw terminalError
        }
        if !queuedRequests.isEmpty {
            return queuedRequests.removeFirst()
        }
        return try await withCheckedThrowingContinuation {
            requestContinuation = $0
        }
    }

    public func waitForAuthorizationCode(
        expectedState: String
    ) async throws -> String {
        while true {
            let request = try await nextRequest()
            switch CodexLoopbackHTTPRequestParser.decision(
                target: request.target,
                expectedState: expectedState
            ) {
            case let .response(status, body):
                await request.responder.respond(
                    status: status,
                    body: body
                )

            case let .authorizationCode(code):
                pendingCallbackResponder = request.responder
                return code

            case .successPage:
                await request.responder.respond(
                    status: 404,
                    body: "Not Found"
                )

            case let .failure(error):
                await request.responder.respond(
                    status: 200,
                    body: Self.failurePage(for: error)
                )
                terminate(with: error)
                throw error

            case .cancel:
                await request.responder.respond(
                    status: 200,
                    body: "Login cancelled"
                )
                terminate(with: .canceled)
                throw CodexLoopbackHTTPServerError.canceled
            }
        }
    }

    public func finish(
        _ result: CodexLoopbackHTTPCallbackFinish
    ) async throws {
        guard let callbackResponder =
            pendingCallbackResponder
        else {
            throw CodexLoopbackHTTPServerError
                .callbackUnavailable
        }
        pendingCallbackResponder = nil

        switch result {
        case let .failure(message):
            await callbackResponder.respond(
                status: 200,
                body: Self.failurePage(message: message)
            )
            terminate(with: .callbackUnavailable)

        case let .success(redirect):
            let url: URL
            switch redirect {
            case let .hosted(hostedURL):
                url = hostedURL
            case let .local(localURL, _):
                url = localURL
            }
            await callbackResponder.respond(
                status: 302,
                body: "",
                headers: [("Location", url.absoluteString)]
            )

            switch redirect {
            case .hosted:
                terminate(with: .callbackUnavailable)

            case let .local(_, expectedStreamlined):
                try await waitForLocalSuccessPage(
                    expectedStreamlined: expectedStreamlined
                )
            }
        }
    }

    private func waitForLocalSuccessPage(
        expectedStreamlined: Bool
    ) async throws {
        while true {
            let request = try await nextRequest()
            switch CodexLoopbackHTTPRequestParser.decision(
                target: request.target,
                expectedState: ""
            ) {
            case let .successPage(streamlined):
                await request.responder.respond(
                    status: 200,
                    body: Self.successPage(
                        streamlined:
                            expectedStreamlined || streamlined
                    )
                )
                terminate(with: .callbackUnavailable)
                return

            case let .response(status, body):
                await request.responder.respond(
                    status: status,
                    body: body
                )

            case .cancel:
                await request.responder.respond(
                    status: 200,
                    body: "Login cancelled"
                )
                terminate(with: .canceled)
                throw CodexLoopbackHTTPServerError.canceled

            default:
                await request.responder.respond(
                    status: 404,
                    body: "Not Found"
                )
            }
        }
    }

    public func cancel() async {
        if let pendingCallbackResponder {
            await pendingCallbackResponder.respond(
                status: 200,
                body: "Login cancelled"
            )
        }
        self.pendingCallbackResponder = nil
        terminate(with: .canceled)
    }

    private func terminate(
        with error: CodexLoopbackHTTPServerError
    ) {
        guard !isClosed else { return }
        isClosed = true
        terminalError = error
        if let continuation = startContinuation {
            startContinuation = nil
            continuation.resume(throwing: error)
        }
        for listener in listeners {
            listener.stateUpdateHandler = nil
            listener.newConnectionHandler = nil
            listener.cancel()
        }
        readyListenerIDs.removeAll()
        if let continuation = requestContinuation {
            requestContinuation = nil
            continuation.resume(throwing: error)
        }
        for request in queuedRequests {
            Task { await request.responder.cancel() }
        }
        queuedRequests.removeAll()
    }

    private static func failurePage(
        for error: CodexLoopbackHTTPServerError
    ) -> String {
        switch error {
        case let .oauthDenied(code, description):
            let detail = description.flatMap {
                $0.isEmpty ? nil : $0
            } ?? code
            return failurePage(
                message: "Sign-in failed: \(detail)"
            )
        case .missingAuthorizationCode:
            return failurePage(
                message:
                    "Missing authorization code. Sign-in could not be completed."
            )
        default:
            return failurePage(
                message: "Sign-in could not be completed."
            )
        }
    }

    private static func failurePage(message: String) -> String {
        """
        <!doctype html><html><body>
        <h1>Sign-in could not be completed</h1>
        <p>\(escapedHTML(message))</p>
        <p>Return to Codex to retry.</p>
        </body></html>
        """
    }

    private static func successPage(
        streamlined: Bool
    ) -> String {
        let detail = streamlined
            ? "You can return to Codex."
            : "Sign-in completed. You can return to Codex."
        return """
        <!doctype html><html><body>
        <h1>Sign-in complete</h1><p>\(detail)</p>
        </body></html>
        """
    }

    private static func escapedHTML(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
}
