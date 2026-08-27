import Foundation
import Network
import Testing

@testable import CodexPadApplication

@Suite(.serialized)
struct CodexLoopbackHTTPServerTests {
    @Test
    func parserAcceptsOnlyExactCallbackPathStateAndNonemptyCode() {
        #expect(
            CodexLoopbackHTTPRequestParser.decision(
                target:
                    "/auth/callback?code=code%20value&state=expected",
                expectedState: "expected"
            )
                == .authorizationCode("code value")
        )
        #expect(
            CodexLoopbackHTTPRequestParser.decision(
                target:
                    "/auth/callback/extra?code=code&state=expected",
                expectedState: "expected"
            )
                == .response(status: 404, body: "Not Found")
        )
        #expect(
            CodexLoopbackHTTPRequestParser.decision(
                target: "/auth/callback?code=code&state=wrong",
                expectedState: "expected"
            )
                == .response(status: 400, body: "State mismatch")
        )
        #expect(
            CodexLoopbackHTTPRequestParser.decision(
                target: "/auth/callback?code=&state=expected",
                expectedState: "expected"
            )
                == .failure(.missingAuthorizationCode)
        )
    }

    @Test
    func parserUsesLastDuplicateQueryValueLikeOfficialHashMap() {
        #expect(
            CodexLoopbackHTTPRequestParser.decision(
                target:
                    "/auth/callback?code=old&code=new&state=wrong&state=expected",
                expectedState: "expected"
            )
                == .authorizationCode("new")
        )
    }

    @Test
    func parserPreservesOAuthDenialWithoutAnyCredentialValues() {
        #expect(
            CodexLoopbackHTTPRequestParser.decision(
                target:
                    "/auth/callback?state=expected&error=access_denied&error_description=missing_codex_entitlement",
                expectedState: "expected"
            )
                == .failure(
                    .oauthDenied(
                        code: "access_denied",
                        description: "missing_codex_entitlement"
                    )
                )
        )
    }

    @Test
    func parserRecognizesOfficialCancelAndRejectsMalformedTargets() {
        #expect(
            CodexLoopbackHTTPRequestParser.decision(
                target: "/cancel",
                expectedState: "expected"
            ) == .cancel
        )
        #expect(
            CodexLoopbackHTTPRequestParser.decision(
                target: "not a target",
                expectedState: "expected"
            )
                == .response(status: 400, body: "Bad Request")
        )
    }

    @Test
    func encodedHTTPResponseAlwaysClosesConnection() {
        let response = CodexLoopbackHTTPResponse.encode(
            status: 200,
            body: "Done"
        )
        let rendered = String(decoding: response, as: UTF8.self)

        #expect(rendered.hasPrefix("HTTP/1.1 200 OK\r\n"))
        #expect(rendered.contains("Content-Length: 4\r\n"))
        #expect(rendered.contains("Connection: close\r\n"))
        #expect(rendered.hasSuffix("\r\n\r\nDone"))
    }

    @Test
    func realListenerCompletesCallbackRoundTripWithoutOpeningAnyApp()
        async throws
    {
        let port = try await reserveAvailableLoopbackPort()
        let server = try await CodexLoopbackHTTPServerFactory()
            .start(preferredPorts: [port])
        let redirect = try #require(
            URL(string: "https://example.test/login-complete")
        )
        let delegate = LoopbackNoRedirectDelegate()
        let session = URLSession(
            configuration: .ephemeral,
            delegate: delegate,
            delegateQueue: nil
        )

        defer {
            session.invalidateAndCancel()
            Task { await server.cancel() }
        }

        let requestTask = Task {
            try await session.data(
                from: try #require(
                    URL(
                        string:
                            "http://localhost:\(port)"
                            + "/auth/callback"
                            + "?code=socket-code"
                            + "&state=socket-state"
                    )
                )
            )
        }
        let callbackTask = Task {
            try await server.waitForAuthorizationCode(
                expectedState: "socket-state"
            )
        }

        #expect(try await callbackTask.value == "socket-code")
        try await server.finish(.success(.hosted(redirect)))

        let (body, response) = try await requestTask.value
        let httpResponse = try #require(
            response as? HTTPURLResponse
        )
        #expect(httpResponse.statusCode == 302)
        #expect(
            httpResponse.value(
                forHTTPHeaderField: "Location"
            ) == redirect.absoluteString
        )
        #expect(body.isEmpty)
    }

    @Test
    func realListenerAcceptsIPv4AndIPv6LoopbackCallbacks() async throws {
        let port = try await reserveAvailableLoopbackPort()
        let server = try await CodexLoopbackHTTPServerFactory()
            .start(preferredPorts: [port])
        let session = URLSession(configuration: .ephemeral)
        let callbackTask = Task {
            try await server.waitForAuthorizationCode(
                expectedState: "expected-state"
            )
        }

        defer {
            session.invalidateAndCancel()
            callbackTask.cancel()
            Task { await server.cancel() }
        }

        for host in ["127.0.0.1", "[::1]"] {
            let (_, response) = try await session.data(
                from: try #require(
                    URL(
                        string:
                            "http://\(host):\(port)"
                            + "/auth/callback"
                            + "?code=ignored"
                            + "&state=wrong-state"
                    )
                )
            )
            let httpResponse = try #require(
                response as? HTTPURLResponse
            )
            #expect(httpResponse.statusCode == 400)
        }

        await server.cancel()
        do {
            _ = try await callbackTask.value
            Issue.record("Canceled loopback wait unexpectedly succeeded")
        } catch let error as CodexLoopbackHTTPServerError {
            #expect(error == .canceled)
        }
    }

    @Test
    func realListenerFallsBackToSecondPreferredPortWhenFirstIsOccupied()
        async throws
    {
        let occupied = try await startBlockingListener(port: 0)
        let fallbackReservation = try await startBlockingListener(port: 0)
        let occupiedPort = try #require(occupied.port?.rawValue)
        let fallbackPort = try #require(
            fallbackReservation.port?.rawValue
        )
        try await cancelAndWait(fallbackReservation)
        defer { occupied.cancel() }

        let server = try await CodexLoopbackHTTPServerFactory()
            .start(preferredPorts: [occupiedPort, fallbackPort])
        defer { Task { await server.cancel() } }

        #expect(server.port == fallbackPort)
        await server.cancel()
    }

    private func reserveAvailableLoopbackPort() async throws -> UInt16 {
        let listener = try await startBlockingListener(port: 0)
        let assignedPort = try #require(listener.port?.rawValue)
        listener.cancel()
        return assignedPort
    }

    private func startBlockingListener(
        port: UInt16
    ) async throws -> NWListener {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = false
        let networkPort = try #require(
            NWEndpoint.Port(rawValue: port)
        )
        let listener = try NWListener(
            using: parameters,
            on: networkPort
        )
        let queue = DispatchQueue(
            label: "CodexForIPad.tests.blocking-listener.\(port)"
        )

        try await withCheckedThrowingContinuation {
            continuation in
            listener.newConnectionHandler = { connection in
                connection.cancel()
            }
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    listener.stateUpdateHandler = nil
                    continuation.resume()
                case let .failed(error):
                    listener.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                case .cancelled:
                    listener.stateUpdateHandler = nil
                    continuation.resume(
                        throwing:
                            CodexLoopbackHTTPServerError.canceled
                    )
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
        return listener
    }

    private func cancelAndWait(
        _ listener: NWListener
    ) async throws {
        try await withCheckedThrowingContinuation {
            continuation in
            listener.stateUpdateHandler = { state in
                switch state {
                case .cancelled:
                    listener.stateUpdateHandler = nil
                    continuation.resume()
                case let .failed(error):
                    listener.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            listener.cancel()
        }
    }
}

private final class LoopbackNoRedirectDelegate:
    NSObject,
    URLSessionTaskDelegate,
    @unchecked Sendable
{
    func urlSession(
        _: URLSession,
        task _: URLSessionTask,
        willPerformHTTPRedirection _: HTTPURLResponse,
        newRequest _: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
