import Testing
@testable import CodexPadApplication
@testable import CodexPadDomain
@testable import CodexPadProtocolBridge

struct CodexOfficialProviderCredentialRetryGateTests {
    @Test
    func chatGPTTokenExpiredRetriesOnlyOnceBeforeVisibleOutput() {
        var gate = CodexOfficialProviderCredentialRetryGate()
        gate.observe(tokenExpiredEvent())

        let firstRetry = gate.consumeRetryIfEligible(
            credentials: credentials(authMethod: .chatGPT)
        )
        let secondRetry = gate.consumeRetryIfEligible(
            credentials: credentials(authMethod: .chatGPT)
        )
        #expect(firstRetry)
        #expect(!secondRetry)
    }

    @Test
    func apiKeyNeverRefreshesForTokenExpiredProviderError() {
        var gate = CodexOfficialProviderCredentialRetryGate()
        gate.observe(tokenExpiredEvent())

        let shouldRetry = gate.consumeRetryIfEligible(
            credentials: credentials(authMethod: .apiKey)
        )
        #expect(!shouldRetry)
    }

    @Test
    func apiKeyTransportErrorFailsImmediately() {
        var gate = CodexOfficialProviderCredentialRetryGate()
        let event = transportErrorEvent(status: 400, code: "bad_request")

        let action = gate.transportAction(
            for: event,
            credentials: credentials(authMethod: .apiKey)
        )

        #expect(action == .fail)
    }

    @Test
    func chatGPTTokenExpiryRefreshesImmediately() {
        var gate = CodexOfficialProviderCredentialRetryGate()

        let action = gate.transportAction(
            for: tokenExpiredEvent(),
            credentials: credentials(authMethod: .chatGPT)
        )

        #expect(action == .refreshCredentials)
    }

    @Test
    func nonRefreshableChatGPTTransportErrorFailsImmediately() {
        var gate = CodexOfficialProviderCredentialRetryGate()
        let event = transportErrorEvent(status: 403, code: "forbidden")

        let action = gate.transportAction(
            for: event,
            credentials: credentials(authMethod: .chatGPT)
        )

        #expect(action == .fail)
    }

    @Test
    func visibleProviderOutputPreventsCredentialRetry() {
        for event in [
            CodexCoreProviderEvent.assistantTextDelta(
                sequence: 1,
                requestID: "request",
                delta: "visible"
            ),
            .responseItemDone(
                sequence: 1,
                requestID: "request",
                itemJSON: #"{"type":"message"}"#
            ),
            .responseCompleted(
                sequence: 1,
                requestID: "request",
                responseID: "response",
                usage: nil,
                endTurn: true
            ),
        ] {
            var gate = CodexOfficialProviderCredentialRetryGate()
            gate.observe(event)
            gate.observe(tokenExpiredEvent(sequence: 2))

            let shouldRetry = gate.consumeRetryIfEligible(
                credentials: credentials(authMethod: .chatGPT)
            )
            #expect(!shouldRetry)
        }
    }

    @Test
    func unstructuredOrDifferentProviderErrorsDoNotRefresh() {
        let payloads: [CodexJSONValue] = [
            CodexJSONValue.object([
                "status": .integer(401),
                "message": .string("token expired"),
            ]),
            .object([
                "status": .integer(403),
                "code": .string("token_expired"),
            ]),
            .object([
                "status": .integer(401),
                "code": .string("invalid_grant"),
            ]),
        ]
        for payload in payloads {
            var gate = CodexOfficialProviderCredentialRetryGate()
            gate.observe(
                .realtime(
                    sequence: 1,
                    requestID: "request",
                    eventType: "provider_transport_error",
                    payload: payload
                )
            )

            let shouldRetry = gate.consumeRetryIfEligible(
                credentials: credentials(authMethod: .chatGPT)
            )
            #expect(!shouldRetry)
        }
    }

    private func tokenExpiredEvent(
        sequence: UInt64 = 1
    ) -> CodexCoreProviderEvent {
        .realtime(
            sequence: sequence,
            requestID: "request",
            eventType: "provider_transport_error",
            payload: .object([
                "status": .integer(401),
                "code": .string("token_expired"),
                "message": .string("Official provider HTTP request failed."),
            ])
        )
    }

    private func transportErrorEvent(
        status: Int64,
        code: String
    ) -> CodexCoreProviderEvent {
        .realtime(
            sequence: 1,
            requestID: "request",
            eventType: "provider_transport_error",
            payload: .object([
                "status": .integer(status),
                "code": .string(code),
                "message": .string("sensitive upstream response"),
            ])
        )
    }

    private func credentials(
        authMethod: CodexDesktopMCPAuthMethod
    ) -> CodexOfficialCredentials {
        CodexOfficialCredentials(
            accessToken: "test-token",
            accountID: authMethod == .chatGPT ? "account" : nil,
            baseURL: authMethod == .apiKey
                ? CodexOfficialCredentials.openAIAPIBaseURL
                : nil,
            authMethod: authMethod
        )
    }
}
