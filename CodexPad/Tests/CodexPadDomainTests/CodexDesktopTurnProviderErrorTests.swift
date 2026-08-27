import Foundation
import Testing

@testable import CodexPadApplication
@testable import CodexPadDomain
@testable import CodexPadProtocolBridge

@Suite
@MainActor
struct CodexDesktopTurnProviderErrorTests {
    @Test
    func mapsHTTP401TransportFailureWithoutExposingRawDiagnostic() {
        let original = TestProviderFailure.network
        let displayed = CodexDesktopTurnSessionRunner
            .displayedProviderError(
                original: original,
                transportPayload: .object([
                    "message": .string(
                        "Transport(Http { status: 401, "
                            + "url: https://api.openai.com/v1/responses, "
                            + "authorization: secret-fixture })"
                    )
                ])
            )
        let message = String(describing: displayed)

        #expect(
            message
                == "Your saved sign-in credential was rejected (HTTP 401). "
                    + "Open Settings and sign in again."
        )
        #expect(!message.contains("secret-fixture"))
        #expect(!message.contains("api.openai.com"))
    }

    @Test
    func mapsHTTP400TransportFailureWithoutExposingRawDiagnostic() {
        let displayed = CodexDesktopTurnSessionRunner
            .displayedProviderError(
                original: TestProviderFailure.network,
                transportPayload: .object([
                    "status": .integer(400),
                    "message": .string(
                        "unsupported model; authorization=secret-fixture"
                    ),
                ])
            )
        let message = String(describing: displayed)

        #expect(
            message
                == "The provider rejected the request (HTTP 400). "
                    + "Check the selected model and account configuration."
        )
        #expect(!message.contains("secret-fixture"))
        #expect(!message.contains("authorization"))
    }

    @Test
    func preservesOriginalFailureWithoutRecognizedHTTPStatus() {
        let original = TestProviderFailure.network
        let displayed = CodexDesktopTurnSessionRunner
            .displayedProviderError(
                original: original,
                transportPayload: .object([
                    "message": .string("connection reset")
                ])
            )

        #expect(String(describing: displayed) == "network")
    }

    @Test
    func mapsFirstEventTimeoutToTerminalUserMessage() {
        let displayed = CodexDesktopTurnSessionRunner
            .displayedProviderError(
                original: CodexOfficialProviderFirstEventTimeoutError(),
                transportPayload: nil
            )

        #expect(
            String(describing: displayed)
                == "The provider request timed out before a response was "
                    + "received. Check the network connection and try again."
        )
    }

    @Test
    func mapsProviderActivityTimeoutToTerminalUserMessage() {
        let displayed = CodexDesktopTurnSessionRunner
            .displayedProviderError(
                original: CodexOfficialProviderActivityTimeoutError(),
                transportPayload: nil
            )

        #expect(
            String(describing: displayed)
                == "The provider request timed out before a response was "
                    + "received. Check the network connection and try again."
        )
    }

    @Test
    func streamDiagnosticIncludesIdentityAndExcludesSensitivePayload() {
        let diagnostic = CodexOfficialProviderStreamDiagnostic.make(
            runID: "run-fixture",
            startedAtMs: 1_723_456_789_000,
            rendererModel: "gpt-5-6",
            providerModel: "gpt-5.6-sol",
            authMethod: .apiKey,
            terminalReason: "provider_transport_error"
        )

        #expect(diagnostic.contains("run=run-fixture"))
        #expect(diagnostic.contains("startedAt=1723456789000"))
        #expect(diagnostic.contains("rendererModel=gpt-5-6"))
        #expect(diagnostic.contains("providerModel=gpt-5.6-sol"))
        #expect(diagnostic.contains("authMethod=apiKey"))
        #expect(
            diagnostic.contains("terminalReason=provider_transport_error")
        )
        #expect(!diagnostic.contains("token"))
        #expect(!diagnostic.contains("authorization"))
    }

    @Test
    func transportDiagnosticKeepsOnlySafeStatusCodeAndStage() {
        let diagnostic = CodexOfficialProviderTransportDiagnostic.make(
            payload: .object([
                "status": .integer(400),
                "code": .string("invalid_argument"),
                "stage": .string("response_headers"),
                "message": .string(
                    "authorization=secret-fixture https://chatgpt.com"
                ),
            ])
        )

        #expect(
            diagnostic
                == " transport=status=400,code=invalid_argument,"
                    + "stage=response_headers"
        )
        #expect(!diagnostic.contains("secret-fixture"))
        #expect(!diagnostic.contains("chatgpt.com"))
        #expect(!diagnostic.contains("message"))
    }

    @Test
    func transportDiagnosticRejectsUnsafeStructuredFields() {
        let diagnostic = CodexOfficialProviderTransportDiagnostic.make(
            payload: .object([
                "status": .integer(401),
                "code": .string("bad code; authorization=secret"),
                "stage": .string("headers/body"),
            ])
        )

        #expect(diagnostic == " transport=status=401")
    }

    @Test
    func transportDiagnosticIncludesBoundedStructuredDetail() {
        let diagnostic = CodexOfficialProviderTransportDiagnostic.make(
            payload: .object([
                "status": .integer(400),
                "code": .string("invalid_request"),
                "detail": .string("Invalid model: gpt-test"),
                "secret": .string("must-not-appear"),
            ])
        )

        #expect(diagnostic.contains("status=400"))
        #expect(diagnostic.contains("code=invalid_request"))
        #expect(diagnostic.contains("detail=Invalid model: gpt-test"))
        #expect(!diagnostic.contains("must-not-appear"))
    }

    @Test
    func finalProviderFailurePersistsExactlyOneFailedStableTurn()
        async throws
    {
        let transport = ProviderFailureTurnTransport()
        let provider = ImmediateFailureTurnProvider()
        var appServerNotifications: [CodexAppServerNotification] = []
        let runner = CodexDesktopTurnSessionRunner(
            sessionStore: CodexSessionStore(transport: transport),
            providerFactory: { _ in provider },
            notificationSink: { _ in },
            appServerNotificationSink: {
                appServerNotifications.append(contentsOf: $0)
            }
        )

        let started = try runner.startDesktopTurn(
            id: .string("turn/provider-final-failure"),
            params: Self.params(threadID: transport.threadID)
        )
        await runner.waitForTurn(started.turn.id)

        #expect(provider.requestCount == 2)
        let failures = transport.failedTurns
        #expect(failures.count == 1)
        let failure = try #require(failures.first)
        #expect(failure.turnID.uuidString.lowercased() == transport.turnID)
        #expect(
            failure.errorItem.threadID.uuidString.lowercased()
                == transport.threadID.rawValue
        )
        #expect(failure.errorItem.turnID == failure.turnID)
        #expect(failure.errorItem.kind == .error)
        #expect(failure.errorItem.text == "network")
        #expect(appServerNotifications == [transport.terminalIdle])
    }

    @Test
    func retryableProviderFailureDoesNotPersistTerminalStateEarly()
        async throws
    {
        let transport = ProviderFailureTurnTransport()
        let provider = RetryThenBlockingFailureTurnProvider()
        let runner = CodexDesktopTurnSessionRunner(
            sessionStore: CodexSessionStore(transport: transport),
            providerFactory: { _ in provider },
            notificationSink: { _ in }
        )

        let started = try runner.startDesktopTurn(
            id: .string("turn/provider-retry"),
            params: Self.params(threadID: transport.threadID)
        )
        let reachedRetry = await provider.waitForRequestCount(2)

        #expect(reachedRetry)
        #expect(transport.failedTurns.isEmpty)

        provider.failBlockedRequest()
        await runner.waitForTurn(started.turn.id)

        #expect(transport.failedTurns.count == 1)
    }

    @Test
    func providerTransportEventTerminatesTurnWithoutWaitingForStreamEnd()
        async throws
    {
        let diagnosticKey =
            "codex.desktop.last-turn-provider-transport-diagnostic"
        UserDefaults.standard.removeObject(forKey: diagnosticKey)
        defer { UserDefaults.standard.removeObject(forKey: diagnosticKey) }

        let transport = ProviderFailureTurnTransport()
        let provider = BlockingTransportEventTurnProvider()
        let runner = CodexDesktopTurnSessionRunner(
            sessionStore: CodexSessionStore(transport: transport),
            providerFactory: { _ in provider },
            notificationSink: { _ in }
        )

        let started = try runner.startDesktopTurn(
            id: .string("turn/provider-transport-event"),
            params: Self.params(threadID: transport.threadID)
        )
        await runner.waitForTurn(started.turn.id)

        #expect(provider.requestCount == 1)
        let failure = try #require(transport.failedTurns.first)
        #expect(
            failure.errorItem.text
                == "Your saved sign-in credential was rejected (HTTP 401). "
                    + "Open Settings and sign in again."
        )
        let diagnostic = try #require(
            UserDefaults.standard.string(forKey: diagnosticKey)
        )
        #expect(diagnostic.contains("status=401"))
        #expect(diagnostic.contains("code=invalid_api_key"))
        #expect(!diagnostic.contains("authorization"))
        #expect(!diagnostic.contains("https://"))
    }

    private static func params(
        threadID: CodexStoredThreadID
    ) -> CodexTurnStartParams {
        CodexTurnStartParams(
            threadID: threadID,
            input: [.text(text: "Open side chat", textElements: [])]
        )
    }
}

private enum TestProviderFailure: Error {
    case network
}

@MainActor
private final class ProviderFailureTurnTransport: CodexCoreTransport {
    let threadID = CodexStoredThreadID(
        "019ff400-c97f-7fd0-9ef1-6ab9498bc663"
    )
    let turnID = "019ff400-d242-7db0-be37-d7e2f75f5b0d"
    private(set) var submitted: [CodexCoreCommand] = []
    private var events: [CodexCoreEvent] = []

    var terminalIdle: CodexAppServerNotification {
        .threadStatusChanged(
            CodexThreadStatusChangedNotification(
                threadID: threadID.rawValue,
                status: .idle
            )
        )
    }

    var failedTurns: [(
        turnID: UUID,
        errorItem: ThreadItem,
        timestamp: Int64
    )] {
        submitted.compactMap { command in
            guard case let .failTurn(turnID, errorItem, timestamp) = command
            else {
                return nil
            }
            return (turnID, errorItem, timestamp)
        }
    }

    func submit(_ command: CodexCoreCommand) throws {
        submitted.append(command)
        if case .failTurn = command {
            events.append(.appServerNotification(terminalIdle))
        }
    }

    func request(_ request: CodexAppServerThreadRequest) throws -> Data {
        throw CodexCoreTransportError.unsupportedTurnRequest
    }

    func request(_ request: CodexAppServerTurnRequest) throws -> Data {
        guard case let .start(id, params) = request,
              params.threadID == threadID
        else {
            throw CodexCoreTransportError.unsupportedTurnRequest
        }
        return try JSONEncoder().encode(
            CodexAppServerReply<CodexTurnStartResult>.success(
                .init(
                    id: id,
                    result: CodexTurnStartResult(
                        turn: CodexStoredTurn(
                            id: turnID,
                            items: [],
                            itemsView: .notLoaded,
                            status: .inProgress
                        )
                    )
                )
            )
        )
    }

    func request(_ request: CodexRawHistoryRequest) throws -> Data {
        guard case let .priorInputItems(id, params) = request,
              params.threadID == threadID
        else {
            throw CodexCoreTransportError.unsupportedRawHistoryRequest
        }
        return try JSONEncoder().encode(
            CodexAppServerReply<CodexPriorInputItemsResult>.success(
                .init(
                    id: id,
                    result: CodexPriorInputItemsResult(
                        threadID: threadID,
                        throughTurnID: nil,
                        items: [],
                        completeness: .complete
                    )
                )
            )
        )
    }

    func nextEvent() throws -> CodexCoreEvent? {
        guard !events.isEmpty else {
            return nil
        }
        return events.removeFirst()
    }
}

@MainActor
private final class ImmediateFailureTurnProvider:
    CodexPersistedTurnProvider
{
    private(set) var requestCount = 0

    func stream(
        _ request: CodexPersistedTurnProviderRequest,
        cancellation: CodexTurnCancellation
    ) async -> AsyncThrowingStream<CodexCoreProviderEvent, Error> {
        requestCount += 1
        return AsyncThrowingStream { continuation in
            continuation.finish(throwing: TestProviderFailure.network)
        }
    }
}

@MainActor
private final class RetryThenBlockingFailureTurnProvider:
    CodexPersistedTurnProvider
{
    private(set) var requestCount = 0
    private var blockedContinuation:
        AsyncThrowingStream<CodexCoreProviderEvent, Error>.Continuation?

    func stream(
        _ request: CodexPersistedTurnProviderRequest,
        cancellation: CodexTurnCancellation
    ) async -> AsyncThrowingStream<CodexCoreProviderEvent, Error> {
        requestCount += 1
        if requestCount == 1 {
            return AsyncThrowingStream { continuation in
                continuation.finish(throwing: TestProviderFailure.network)
            }
        }
        return AsyncThrowingStream { continuation in
            blockedContinuation = continuation
        }
    }

    func waitForRequestCount(_ expected: Int) async -> Bool {
        for _ in 0..<2_000 {
            if requestCount >= expected {
                return true
            }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        return false
    }

    func failBlockedRequest() {
        blockedContinuation?.finish(
            throwing: TestProviderFailure.network
        )
        blockedContinuation = nil
    }
}

@MainActor
private final class BlockingTransportEventTurnProvider:
    CodexPersistedTurnProvider
{
    private(set) var requestCount = 0
    private var continuation:
        AsyncThrowingStream<CodexCoreProviderEvent, Error>.Continuation?

    func stream(
        _ request: CodexPersistedTurnProviderRequest,
        cancellation: CodexTurnCancellation
    ) async -> AsyncThrowingStream<CodexCoreProviderEvent, Error> {
        requestCount += 1
        return AsyncThrowingStream { continuation in
            self.continuation = continuation
            continuation.yield(
                .realtime(
                    sequence: 1,
                    requestID: request.requestID,
                    eventType: "provider_transport_error",
                    payload: .object([
                        "status": .integer(401),
                        "code": .string("invalid_api_key"),
                    ])
                )
            )
        }
    }
}
