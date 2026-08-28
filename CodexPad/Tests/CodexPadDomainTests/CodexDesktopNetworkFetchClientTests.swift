import CodexPadDomain
import Foundation
import Testing

@testable import CodexPadApplication
@testable import CodexPadProtocolBridge

@Test
func desktopProductNetworkConfigurationBoundsAndSharesNativeRoutingState() {
    let configuration = CodexDesktopProductURLSession.configuration()

    #expect(configuration.waitsForConnectivity)
    #expect(configuration.httpMaximumConnectionsPerHost == 4)
    #expect(configuration.httpShouldSetCookies)
    #expect(configuration.httpCookieStorage === HTTPCookieStorage.shared)
    #expect(configuration.connectionProxyDictionary == nil)
}

@Test
func desktopStreamTransportRetriesOnePreHeaderTLSFailure() async throws {
    let base = FlakyTLSNetworkStreamTransport(failuresBeforeSuccess: 1)
    let transport = CodexDesktopRetryingNetworkStreamTransport(
        base: base,
        maximumAttempts: 2,
        retryDelay: .zero
    )

    let response = try await transport.executeStream(
        CodexDesktopNetworkTransportRequest(
            url: try #require(URL(string: "https://example.test/stream")),
            method: "POST",
            headers: [:],
            body: Data("fixture".utf8)
        )
    )

    #expect(response.status == 200)
    #expect(await base.executionCount() == 2)
}

@Test
func desktopStreamTransportDoesNotRetryStartedStreamFailure() async throws {
    let base = StartedBodyFailureNetworkStreamTransport()
    let transport = CodexDesktopRetryingNetworkStreamTransport(
        base: base,
        maximumAttempts: 2,
        retryDelay: .zero
    )

    let response = try await transport.executeStream(
        CodexDesktopNetworkTransportRequest(
            url: try #require(URL(string: "https://example.test/stream")),
            method: "POST",
            headers: [:],
            body: Data("fixture".utf8)
        )
    )
    do {
        for try await _ in response.body {}
        Issue.record("Expected the started response body to fail")
    } catch let error as URLError {
        #expect(error.code == .networkConnectionLost)
    } catch {
        Issue.record("Unexpected body error: \(error)")
    }

    #expect(await base.executionCount() == 1)
}

@Test
func desktopStreamResponseHeadersHaveAHardDeadline() async throws {
    let base = SuspendedNetworkStreamTransport()
    let transport = CodexDesktopResponseHeaderDeadlineNetworkStreamTransport(
        base: base,
        deadline: .milliseconds(25)
    )
    let clock = ContinuousClock()
    let startedAt = clock.now

    do {
        _ = try await transport.executeStream(
            CodexDesktopNetworkTransportRequest(
                url: try #require(URL(string: "https://example.test/stream")),
                method: "POST",
                headers: [:],
                body: Data("fixture".utf8)
            )
        )
        Issue.record("Expected the response-header deadline to expire")
    } catch let error as URLError {
        #expect(error.code == .timedOut)
    } catch {
        Issue.record("Unexpected deadline error: \(error)")
    }

    #expect(clock.now - startedAt < .seconds(1))
    #expect(await base.executionCount() == 1)
}

@Test
func desktopStreamResponseHeaderDeadlineEmitsATerminalRendererError() async {
    let transport = CodexDesktopResponseHeaderDeadlineNetworkStreamTransport(
        base: SuspendedNetworkStreamTransport(),
        deadline: .milliseconds(25)
    )
    let client = CodexDesktopNetworkFetchClient(
        transport: NetworkFetchTransportRecorder(
            response: .init(status: 204, headers: [:], body: Data())
        ),
        streamTransport: transport
    )
    let messages = MessageCollector()

    await client.stream(
        CodexDesktopFetchStreamRequest(
            requestID: "stream-header-timeout",
            method: "POST",
            url: "/f/conversation",
            headers: nil,
            body: "{}",
            format: "sse"
        ),
        credentials: nil
    ) { message in
        await messages.append(message)
    }

    #expect(
        await messages.values() == [
            .event(
                type: "fetch-stream-error",
                payload: .object([
                    "requestId": .string("stream-header-timeout"),
                    "error": .string("Network stream failed (-1001)"),
                ])
            )
        ]
    )
}

@Test
func desktopTransportDiagnosticIncludesSafeUnderlyingCodes() {
    let underlying = NSError(
        domain: "kCFErrorDomainCFNetwork",
        code: -9800
    )
    let error = NSError(
        domain: NSURLErrorDomain,
        code: URLError.secureConnectionFailed.rawValue,
        userInfo: [NSUnderlyingErrorKey: underlying]
    )

    let summary = CodexDesktopNetworkTransportDiagnostic.errorSummary(error)

    #expect(summary.contains("domain=NSURLErrorDomain"))
    #expect(summary.contains("code=-1200"))
    #expect(summary.contains("underlyingDomain=kCFErrorDomainCFNetwork"))
    #expect(summary.contains("underlyingCode=-9800"))
    #expect(!summary.contains("https://"))
    #expect(!summary.contains("Authorization"))
}

@Test
func desktopBridgeDecodesFetchStreamAndCancellationShapes() throws {
    let stream = try CodexDesktopBridgeCodec.decodeViewPayload(
        Data(
            #"{"type":"fetch-stream","requestId":"stream-1","method":"POST","url":"/f/conversation","headers":{"X-OpenAI-Attach-Auth":"1"},"body":"{}","format":"sse"}"#
                .utf8
        )
    )
    #expect(
        stream == .fetchStream(
            CodexDesktopFetchStreamRequest(
                requestID: "stream-1",
                method: "POST",
                url: "/f/conversation",
                headers: ["X-OpenAI-Attach-Auth": "1"],
                body: "{}",
                format: "sse"
            )
        )
    )
    #expect(
        try CodexDesktopBridgeCodec.decodeViewPayload(
            Data(#"{"type":"cancel-fetch-stream","requestId":"stream-1"}"#.utf8)
        ) == .cancelFetchStream(requestID: "stream-1")
    )
}

@Test
func conversationAdapterExtractsPartialQueryAndPreservesModelSettings() {
    let request = CodexDesktopFetchStreamRequest(
        requestID: "conversation-1",
        method: "POST",
        url: "/f/conversation",
        headers: nil,
        body: """
        {
          "conversation_id": "thread-1",
          "model": "codex-fixture",
          "thinking_effort": "high",
          "messages": [
            {"id": "user-1", "author": {"role": "user"}, "content": {"parts": ["hello"]}}
          ],
          "partial_query": {
            "author": {"role": "user"},
            "content": {"content_type": "text", "parts": ["hello", " world"]}
          }
        }
        """,
        format: "sse"
    )
    #expect(
        CodexDesktopConversationStreamAdapter.isConversationRequest(request)
    )
    let parsed = CodexDesktopConversationStreamAdapter.parse(
        body: request.body,
        fallbackModel: "fallback"
    )
    #expect(parsed.conversationID == "thread-1")
    #expect(parsed.text == "hello world")
    #expect(parsed.model == "codex-fixture")
    #expect(parsed.reasoningEffort == "high")
    #expect(parsed.parentMessageID == "user-1")
}

@Test
func conversationAdapterAnchorsReplyToLatestPartialQueryMessage() {
    let request = CodexDesktopFetchStreamRequest(
        requestID: "conversation-latest-partial-query",
        method: "POST",
        url: "/f/conversation",
        headers: nil,
        body: """
        {
          "model": "gpt-5-6",
          "messages": [
            {
              "id": "older-user-message",
              "author": {"role": "user"},
              "content": {"parts": ["older prompt"]}
            }
          ],
          "partial_query": {
            "id": "latest-user-message",
            "author": {"role": "user"},
            "content": {
              "content_type": "text",
              "parts": ["latest prompt"]
            }
          }
        }
        """,
        format: "sse"
    )

    let parsed = CodexDesktopConversationStreamAdapter.parse(
        body: request.body,
        fallbackModel: "fallback"
    )

    #expect(parsed.text == "latest prompt")
    #expect(parsed.parentMessageID == "latest-user-message")
}

@Test
func conversationAdapterPreservesLatestMultimodalUserInput() {
    let request = CodexDesktopFetchStreamRequest(
        requestID: "conversation-multimodal",
        method: "POST",
        url: "/f/conversation",
        headers: nil,
        body: """
        {
          "model": "gpt-5-6",
          "messages": [
            {
              "id": "multimodal-user-message",
              "author": {"role": "user"},
              "content": {
                "content_type": "multimodal_text",
                "parts": [
                  {
                    "content_type": "image_asset_pointer",
                    "asset_pointer": "file-service://file-image-1",
                    "height": 1536,
                    "size_bytes": 204800,
                    "width": 2048
                  },
                  "inspect this screenshot"
                ]
              }
            }
          ]
        }
        """,
        format: "sse"
    )

    let parsed = CodexDesktopConversationStreamAdapter.parse(
        body: request.body,
        fallbackModel: "fallback"
    )

    #expect(parsed.text == "inspect this screenshot")
    #expect(
        parsed.input
            == [
                .image(
                    detail: nil,
                    url: "file-service://file-image-1"
                ),
                .text(
                    text: "inspect this screenshot",
                    textElements: []
                ),
            ]
    )
    #expect(parsed.parentMessageID == "multimodal-user-message")
}

@Test
func conversationAdapterRoutesGenericFileAttachmentsToProductBackend() {
    let request = CodexDesktopFetchStreamRequest(
        requestID: "conversation-file-attachment",
        method: "POST",
        url: "/f/conversation",
        headers: ["X-OpenAI-Attach-Auth": "1"],
        body: """
        {
          "model": "gpt-5-6",
          "messages": [
            {
              "id": "file-user-message",
              "author": {"role": "user"},
              "content": {
                "content_type": "text",
                "parts": ["summarize this document"]
              },
              "metadata": {
                "attachments": [
                  {
                    "id": "file-document-1",
                    "name": "brief.pdf",
                    "mime_type": "application/pdf",
                    "size": 4096
                  }
                ]
              }
            }
          ]
        }
        """,
        format: "sse"
    )

    #expect(
        CodexDesktopConversationStreamAdapter
            .shouldUseOfficialProvider(request) == false
    )
}

@Test
func conversationAdapterKeepsReleasedChatGPTConversationOnProductBackend() {
    let request = CodexDesktopFetchStreamRequest(
        requestID: "conversation-image-attachment",
        method: "POST",
        url: "/f/conversation",
        headers: ["X-OpenAI-Attach-Auth": "1"],
        body: """
        {
          "model": "gpt-5-6",
          "messages": [
            {
              "id": "image-user-message",
              "author": {"role": "user"},
              "content": {
                "content_type": "multimodal_text",
                "parts": [
                  {
                    "content_type": "image_asset_pointer",
                    "asset_pointer": "file-service://file-image-1"
                  },
                  "inspect this screenshot"
                ]
              },
              "metadata": {
                "attachments": [
                  {
                    "id": "file-image-1",
                    "name": "screenshot.png",
                    "mime_type": "image/png",
                    "size": 204800
                  }
                ]
              }
            }
          ]
        }
        """,
        format: "sse"
    )

    #expect(
        CodexDesktopConversationStreamAdapter
            .shouldUseOfficialProvider(request) == false
    )
}

@Test
func conversationAdapterRoutesAPIKeyConversationToOfficialProvider() {
    let request = CodexDesktopFetchStreamRequest(
        requestID: "conversation-api-key",
        method: "POST",
        url: "/f/conversation",
        headers: nil,
        body: #"{"model":"gpt-5-6","prompt":"hello"}"#,
        format: "sse"
    )

    #expect(
        CodexDesktopConversationStreamAdapter.shouldUseOfficialProvider(
            request,
            authMethod: .apiKey
        )
    )
    #expect(
        CodexDesktopConversationStreamAdapter.shouldUseOfficialProvider(
            request,
            authMethod: .chatGPT
        )
    )
}

@Test
func conversationAdapterKeepsAttachmentTurnsOnProductBackend() {
    let request = CodexDesktopFetchStreamRequest(
        requestID: "conversation-file",
        method: "POST",
        url: "/f/conversation",
        headers: nil,
        body: #"{"model":"gpt-5-6","prompt":"summarize","attachments":[{"id":"file-1"}]}"#,
        format: "sse"
    )

    #expect(
        !CodexDesktopConversationStreamAdapter.shouldUseOfficialProvider(
            request,
            authMethod: .chatGPT
        )
    )
}

@Test
func conversationAdapterNormalizesDesktopAliasOnlyAtOfficialProviderBoundary() {
    #expect(
        CodexDesktopConversationStreamAdapter.officialProviderModel(
            for: "gpt-5-6",
            baseURL: "https://api.openai.com/v1"
        ) == "gpt-5.6-sol"
    )
    #expect(
        CodexDesktopConversationStreamAdapter.officialProviderModel(
            for: "gpt-5.6-sol",
            baseURL: "https://api.openai.com/v1"
        ) == "gpt-5.6-sol"
    )
    #expect(
        CodexDesktopConversationStreamAdapter.officialProviderModel(
            for: "custom-provider-model",
            baseURL: "https://provider.example/v1"
        ) == "custom-provider-model"
    )
    #expect(
        CodexDesktopConversationStreamAdapter.officialProviderModel(
            for: "gpt-5-6",
            baseURL: nil
        ) == "gpt-5.5"
    )
    #expect(
        CodexDesktopConversationStreamAdapter.officialProviderModel(
            for: "gpt-5.6-sol",
            baseURL: nil
        ) == "gpt-5.5"
    )
    #expect(
        CodexDesktopConversationStreamAdapter.officialProviderModel(
            for: "auto",
            baseURL: nil
        ) == "gpt-5.5"
    )
    #expect(
        CodexDesktopConversationStreamAdapter.officialProviderModel(
            for: "gpt-5-6",
            baseURL: "https://api.openai.com/v1"
        ) == "gpt-5.6-sol"
    )
}

@Test
func persistedChatGPTTurnUsesTheSameModelAliasNormalization() {
    let chatGPTRoute = CodexDesktopConversationStreamAdapter
        .officialProviderModel(for: "gpt-5.6-sol", baseURL: nil)
    #expect(chatGPTRoute == "gpt-5.5")
}

@Test
func conversationAdapterEmitsRendererCompatibleMessageAndCompletionJSON() throws {
    let message = CodexDesktopConversationStreamAdapter.messageData(
        conversationID: "thread-1",
        messageID: "message-1",
        text: "hello",
        completed: false,
        parentMessageID: "user-1"
    )
    let completion =
        CodexDesktopConversationStreamAdapter.completionData(
            conversationID: "thread-1"
        )
    let messageObject = try #require(
        JSONSerialization.jsonObject(
            with: Data(message.utf8)
        ) as? [String: Any]
    )
    #expect(messageObject["conversation_id"] as? String == "thread-1")
    #expect(messageObject["type"] as? String == "message")
    let messageFields = messageObject["message"] as? [String: Any]
    #expect(messageFields?["channel"] as? String == "final")
    #expect(
        (messageFields?["metadata"] as? [String: Any])?["parent_id"]
            as? String == "user-1"
    )
    #expect(
        ((messageObject["message"] as? [String: Any])?["content"]
            as? [String: Any])?["content_type"] as? String == "text"
    )
    let completionObject = try #require(
        JSONSerialization.jsonObject(
            with: Data(completion.utf8)
        ) as? [String: Any]
    )
    #expect(completionObject["type"] as? String == "message_stream_complete")
}

@Test
func conversationAdapterPayloadIsCanonicalEventBusShape() {
    let payload = CodexDesktopConversationStreamAdapter.messagePayloadValue(
        conversationID: "thread-1",
        messageID: "message-1",
        text: "hello",
        completed: true,
        parentMessageID: "user-1"
    )
    guard case let .object(fields) = payload else {
        Issue.record("payload must be an object")
        return
    }
    #expect(fields["conversation_id"] == .string("thread-1"))
    #expect(fields["type"] == nil)
    #expect(fields["data"] == nil)
    guard case let .object(message)? = fields["message"] else {
        Issue.record("payload.message must be an object")
        return
    }
    #expect(message["id"] == .string("message-1"))
    #expect(message["channel"] == .string("final"))
    #expect(message["end_turn"] == .bool(true))
    #expect(
        message["metadata"]
            == .object(["parent_id": .string("user-1")])
    )
}

@Test
func conversationAdapterDoesNotMigrateANewLocalThreadToAnEmptyServerID() {
    let completion =
        CodexDesktopConversationStreamAdapter.completionEvent(
            requestID: "stream-new-thread",
            conversationID: ""
        )
    #expect(
        completion == .event(
            type: "fetch-stream-event",
            payload: .object([
                "requestId": .string("stream-new-thread"),
                "event": .string("message_stream_complete"),
                "data": .object([
                    "type": .string("message_stream_complete"),
                ]),
            ])
        )
    )
}

@Test
func desktopFetchStreamPreservesSSEEventsAndCompletion() async {
    let transport = NetworkStreamTransportRecorder()
    let client = CodexDesktopNetworkFetchClient(
        transport: NetworkFetchTransportRecorder(
            response: .init(status: 204, headers: [:], body: Data())
        ),
        streamTransport: transport
    )
    let messages = MessageCollector()
    let task = Task {
        await client.stream(
            CodexDesktopFetchStreamRequest(
                requestID: "stream-sse",
                method: "POST",
                url: "/f/conversation",
                headers: ["X-OpenAI-Attach-Auth": "1"],
                body: "{}",
                format: "sse"
            ),
            credentials: CodexOfficialCredentials(
                accessToken: "fixture-token",
                accountID: "fixture-account"
            )
        ) { message in
            await messages.append(message)
        }
    }
    await transport.emit(Data("event: delta\ndata: one\n\n".utf8))
    await transport.emit(Data("data: two\n\n".utf8))
    await transport.finish()
    await task.value
    let captured = await messages.values()
    #expect(captured.count == 4)
    #expect(
        captured[1] == .event(
            type: "fetch-stream-event",
            payload: .object([
                "requestId": .string("stream-sse"),
                "event": .string("delta"),
                "data": .string("one"),
            ])
        )
    )
    #expect(
        captured[2] == .event(
            type: "fetch-stream-event",
            payload: .object([
                "requestId": .string("stream-sse"),
                "data": .string("two"),
            ])
        )
    )
    #expect(
        captured[3] == .event(
            type: "fetch-stream-complete",
            payload: .object(["requestId": .string("stream-sse")])
        )
    )
    let request = await transport.capturedRequest()
    #expect(request?.headers["Authorization"] == "Bearer fixture-token")
    #expect(request?.headers["ChatGPT-Account-Id"] == "fixture-account")
}

@Test
func desktopChatGPTConversationNormalizesLegacyRendererModelAlias() async throws {
    let transport = NetworkStreamTransportRecorder()
    let client = CodexDesktopNetworkFetchClient(
        transport: NetworkFetchTransportRecorder(
            response: .init(status: 204, headers: [:], body: Data())
        ),
        streamTransport: transport
    )
    let task = Task {
        await client.stream(
            CodexDesktopFetchStreamRequest(
                requestID: "stream-legacy-model-alias",
                method: "POST",
                url: "/f/conversation",
                headers: ["X-OpenAI-Attach-Auth": "1"],
                body: #"{"model":"gpt-5-6","prompt":"hello"}"#,
                format: "sse"
            ),
            credentials: CodexOfficialCredentials(
                accessToken: "fixture-token",
                accountID: "fixture-account"
            )
        ) { _ in }
    }
    await transport.finish()
    await task.value

    let request = try #require(await transport.capturedRequest())
    let body = try #require(request.body)
    let object = try #require(
        JSONSerialization.jsonObject(with: body) as? [String: Any]
    )
    #expect(object["model"] as? String == "gpt-5.5")
}

@Test
func desktopWhamStreamDoesNotCallAccountRouteWhileSignedOut() async {
    let transport = NetworkStreamTransportRecorder()
    let client = CodexDesktopNetworkFetchClient(
        transport: NetworkFetchTransportRecorder(
            response: .init(status: 204, headers: [:], body: Data())
        ),
        streamTransport: transport
    )
    let messages = MessageCollector()

    await client.stream(
        CodexDesktopFetchStreamRequest(
            requestID: "stream-signed-out-wham",
            method: "GET",
            url: "/wham/tasks/task-1/turns/turn-1/stream",
            headers: nil,
            body: nil,
            format: "sse"
        ),
        credentials: nil
    ) { message in
        await messages.append(message)
    }

    #expect(await transport.capturedRequest() == nil)
    #expect(
        await messages.values() == [
            .event(
                type: "fetch-stream-error",
                payload: .object([
                    "requestId": .string("stream-signed-out-wham"),
                    "error": .string("ChatGPT authentication required"),
                ])
            )
        ]
    )
}

@Test
func desktopConversationStreamDoesNotInventDeviceCheckToken() async {
    let transport = NetworkStreamTransportRecorder()
    let client = CodexDesktopNetworkFetchClient(
        transport: NetworkFetchTransportRecorder(
            response: .init(status: 204, headers: [:], body: Data())
        ),
        streamTransport: transport,
        deviceCheckTokenProvider:
            FixtureDeviceCheckTokenProvider(tokenValue: "device-token")
    )
    let task = Task {
        await client.stream(
            CodexDesktopFetchStreamRequest(
                requestID: "stream-device-check",
                method: "POST",
                url: "/f/conversation",
                headers: [
                    "X-OpenAI-Attach-Auth": "1",
                ],
                body: "{}",
                format: "sse"
            ),
            credentials: CodexOfficialCredentials(
                accessToken: "fixture-token",
                accountID: "fixture-account"
            )
        ) { _ in }
    }
    await transport.finish()
    await task.value

    let request = await transport.capturedRequest()
    #expect(request?.headers["x-sentinel-dc"] == nil)
}

@Test
func desktopAttestationChallengeInjectsNativeDeviceCheckToken() async {
    let transport = NetworkFetchTransportRecorder(
        response: .init(
            status: 200,
            headers: ["content-type": "application/json"],
            body: Data(#"{"attestation_challenge":"fixture"}"#.utf8)
        )
    )
    let client = CodexDesktopNetworkFetchClient(
        transport: transport,
        deviceCheckTokenProvider:
            FixtureDeviceCheckTokenProvider(tokenValue: "device-token")
    )

    _ = await client.response(
        to: networkFetchRequest(
            requestID: "attestation-challenge",
            url: "/ios/attestation_challenge",
            headers: [
                "X-OpenAI-Attach-Auth": "1",
                "X-OpenAI-Attach-Desktop-Surface": "1",
                "X-OpenAI-Attach-DeviceCheck-Token": "1",
            ]
        ),
        credentials: CodexOfficialCredentials(
            accessToken: "fixture-token",
            accountID: "fixture-account"
        )
    )

    let requests = await transport.capturedRequests()
    #expect(requests.count == 2)
    let registration = requests.first
    #expect(registration?.url.path.hasSuffix("/devicecheck") == true)
    #expect(registration?.method == "POST")
    let request = requests.last
    #expect(
        request?.headers["x-sentinel-dc"]
            == #"{"token":"device-token"}"#
    )
    #expect(
        request?.headers["X-OpenAI-Attach-DeviceCheck-Token"]
            == nil
    )
    #expect(
        request?.headers["X-OpenAI-Attach-Desktop-Surface"]
            == nil
    )
}

@Test
func desktopFetchStreamMapsNDJSONAndHTTPFailureWithoutSensitiveBody() async {
    let transport = NetworkStreamTransportRecorder(status: 502)
    let client = CodexDesktopNetworkFetchClient(
        transport: NetworkFetchTransportRecorder(
            response: .init(status: 204, headers: [:], body: Data())
        ),
        streamTransport: transport
    )
    let messages = MessageCollector()
    await client.stream(
        CodexDesktopFetchStreamRequest(
            requestID: "stream-error",
            method: "POST",
            url: "/f/conversation",
            headers: nil,
            body: #"{"secret":"fixture"}"#,
            format: "ndjson"
        ),
        credentials: nil
    ) { message in
        await messages.append(message)
    }
    let captured = await messages.values()
    #expect(captured.count == 1)
    #expect(
        captured.first == .event(
            type: "fetch-stream-error",
            payload: .object([
                "requestId": .string("stream-error"),
                "error": .string("Request failed with status 502"),
            ])
        )
    )
    #expect(
        !(String(describing: captured).contains("fixture"))
    )
}

@Test
func desktopNetworkFetchForwardsInferredAuthRequestWithoutToken() async {
    let transport = NetworkFetchTransportRecorder(
        response: .init(
            status: 200,
            headers: ["content-type": "application/json"],
            body: Data(#"{"signed_out":true}"#.utf8)
        )
    )
    let client = CodexDesktopNetworkFetchClient(transport: transport)

    let response = await client.response(
        to: networkFetchRequest(
            requestID: "request-signed-out",
            url: "/wham/statsig/bootstrap"
        ),
        credentials: nil
    )

    #expect(
        response == .fetchSuccess(
            requestID: "request-signed-out",
            status: 200,
            headers: ["content-type": "application/json"],
            body: .object(["signed_out": .bool(true)])
        )
    )
    let captured = await transport.capturedRequests()
    #expect(captured.count == 1)
    #expect(captured.first?.headers["Authorization"] == nil)
    #expect(captured.first?.headers["ChatGPT-Account-Id"] == nil)
}

@Test
func desktopNetworkFetchStripsExplicitAuthMarkerWithoutToken() async {
    let transport = NetworkFetchTransportRecorder(
        response: .init(status: 204, headers: [:], body: Data())
    )
    let client = CodexDesktopNetworkFetchClient(transport: transport)

    let response = await client.response(
        to: networkFetchRequest(
            requestID: "request-explicit-signed-out",
            url: "/wham/statsig/bootstrap",
            headers: ["x-openai-attach-auth": "1"]
        ),
        credentials: nil
    )

    #expect(
        response == .fetchSuccess(
            requestID: "request-explicit-signed-out",
            status: 204,
            headers: [:],
            body: .null
        )
    )
    let captured = await transport.capturedRequests()
    #expect(captured.count == 1)
    #expect(captured.first?.headers["Authorization"] == nil)
    #expect(captured.first?.headers["ChatGPT-Account-Id"] == nil)
    #expect(captured.first?.headers["x-openai-attach-auth"] == nil)
}

@Test
func desktopNetworkFetchResolvesProductPathAndAttachesOfficialHeaders() async {
    let transport = NetworkFetchTransportRecorder(
        response: .init(
            status: 200,
            headers: [
                "Content-Type": "application/json",
                "X-Fixture": "ok",
            ],
            body: Data(#"{"feature":"enabled"}"#.utf8)
        )
    )
    let client = CodexDesktopNetworkFetchClient(transport: transport)

    let response = await client.response(
        to: networkFetchRequest(
            requestID: "request-authenticated",
            url: "/wham/statsig/bootstrap",
            headers: ["X-OpenAI-Attach-Auth": "1"],
            body: "{}"
        ),
        credentials: CodexOfficialCredentials(
            accessToken: "fixture-access-token",
            accountID: "fixture-account"
        )
    )

    #expect(
        response == .fetchSuccess(
            requestID: "request-authenticated",
            status: 200,
            headers: [
                "content-type": "application/json",
                "x-fixture": "ok",
            ],
            body: .object(["feature": .string("enabled")])
        )
    )
    let captured = await transport.capturedRequests()
    #expect(captured.count == 1)
    #expect(
        captured.first?.url.absoluteString
            == "https://chatgpt.com/backend-api/wham/statsig/bootstrap"
    )
    #expect(captured.first?.method == "POST")
    #expect(
        captured.first?.headers["Authorization"]
            == "Bearer fixture-access-token"
    )
    #expect(
        captured.first?.headers["ChatGPT-Account-Id"]
            == "fixture-account"
    )
    #expect(captured.first?.headers["Content-Type"] == "application/json")
    #expect(captured.first?.headers["X-OpenAI-Attach-Auth"] == nil)
    #expect(captured.first?.body == Data("{}".utf8))
}

@Test
func desktopNetworkFetchRefreshesExpiredChatGPTTokenAndRetriesOnce() async {
    let transport = NetworkFetchTransportRecorder(
        responses: [
            .init(
                status: 401,
                headers: ["content-type": "application/json"],
                body: Data(
                    #"{"error":{"code":"token_expired","message":"Provided authentication token is expired."}}"#
                        .utf8
                )
            ),
            .init(
                status: 200,
                headers: ["content-type": "application/json"],
                body: Data(#"{"authenticated":true}"#.utf8)
            ),
        ]
    )
    let refresh = CredentialRefreshRecorder(
        result: .success(
            CodexOfficialCredentials(
                accessToken: "refreshed-access-token",
                accountID: "refreshed-account"
            )
        )
    )
    let client = CodexDesktopNetworkFetchClient(transport: transport)

    let response = await client.response(
        to: networkFetchRequest(
            requestID: "request-expired-chatgpt",
            url: "/wham/usage"
        ),
        credentials: CodexOfficialCredentials(
            accessToken: "expired-access-token",
            accountID: "expired-account"
        ),
        refreshCredentials: {
            try await refresh.refresh()
        }
    )

    #expect(
        response == .fetchSuccess(
            requestID: "request-expired-chatgpt",
            status: 200,
            headers: ["content-type": "application/json"],
            body: .object(["authenticated": .bool(true)])
        )
    )
    #expect(await refresh.callCount() == 1)
    let requests = await transport.capturedRequests()
    #expect(requests.count == 2)
    #expect(
        requests[0].headers["Authorization"]
            == "Bearer expired-access-token"
    )
    #expect(
        requests[0].headers["ChatGPT-Account-Id"]
            == "expired-account"
    )
    #expect(
        requests[1].headers["Authorization"]
            == "Bearer refreshed-access-token"
    )
    #expect(
        requests[1].headers["ChatGPT-Account-Id"]
            == "refreshed-account"
    )
}

@Test
func desktopNetworkFetchDoesNotRefreshAPIKeyOnTokenExpiredResponse() async {
    let transport = NetworkFetchTransportRecorder(
        response: .init(
            status: 401,
            headers: ["content-type": "application/json"],
            body: Data(
                #"{"error":{"code":"token_expired","message":"Expired."}}"#
                    .utf8
            )
        )
    )
    let refresh = CredentialRefreshRecorder(
        result: .success(
            CodexOfficialCredentials(
                accessToken: "must-not-be-used",
                accountID: nil
            )
        )
    )
    let client = CodexDesktopNetworkFetchClient(transport: transport)

    _ = await client.response(
        to: networkFetchRequest(
            requestID: "request-api-key-expired",
            url: "https://api.openai.com/v1/models",
            headers: ["X-OpenAI-Attach-Auth": "1"]
        ),
        credentials: CodexOfficialCredentials(
            accessToken: "fixture-api-key",
            accountID: nil,
            baseURL: CodexOfficialCredentials.openAIAPIBaseURL,
            authMethod: .apiKey
        ),
        refreshCredentials: {
            try await refresh.refresh()
        }
    )

    #expect(await refresh.callCount() == 0)
    #expect(await transport.capturedRequests().count == 1)
}

@Test
func desktopFetchStreamRefreshesExpiredChatGPTTokenBeforeEmittingResult()
    async
{
    let transport = SequencedNetworkStreamTransportRecorder(
        responses: [
            .init(
                status: 401,
                headers: ["content-type": "application/json"],
                chunks: [
                    Data(
                        #"{"error":{"code":"token_expired","message":"Provided authentication token is expired."}}"#
                            .utf8
                    )
                ]
            ),
            .init(
                status: 200,
                headers: ["content-type": "text/event-stream"],
                chunks: [
                    Data("event: delta\ndata: refreshed\n\n".utf8)
                ]
            ),
        ]
    )
    let refresh = CredentialRefreshRecorder(
        result: .success(
            CodexOfficialCredentials(
                accessToken: "stream-refreshed-token",
                accountID: "stream-refreshed-account"
            )
        )
    )
    let messages = MessageCollector()
    let client = CodexDesktopNetworkFetchClient(
        transport: NetworkFetchTransportRecorder(
            response: .init(status: 204, headers: [:], body: Data())
        ),
        streamTransport: transport
    )

    await client.stream(
        CodexDesktopFetchStreamRequest(
            requestID: "stream-expired-chatgpt",
            method: "GET",
            url: "/wham/tasks/task-1/turns/turn-1/stream",
            headers: nil,
            body: nil,
            format: "sse"
        ),
        credentials: CodexOfficialCredentials(
            accessToken: "stream-expired-token",
            accountID: "stream-expired-account"
        ),
        refreshCredentials: {
            try await refresh.refresh()
        }
    ) { message in
        await messages.append(message)
    }

    #expect(await refresh.callCount() == 1)
    let requests = await transport.capturedRequests()
    #expect(requests.count == 2)
    #expect(
        requests[0].headers["Authorization"]
            == "Bearer stream-expired-token"
    )
    #expect(
        requests[1].headers["Authorization"]
            == "Bearer stream-refreshed-token"
    )
    #expect(
        await messages.values() == [
            .event(
                type: "fetch-stream-response",
                payload: .object([
                    "requestId": .string("stream-expired-chatgpt"),
                    "status": .integer(200),
                    "headers": .object([
                        "content-type": .string("text/event-stream")
                    ]),
                ])
            ),
            .event(
                type: "fetch-stream-event",
                payload: .object([
                    "requestId": .string("stream-expired-chatgpt"),
                    "event": .string("delta"),
                    "data": .string("refreshed"),
                ])
            ),
            .event(
                type: "fetch-stream-complete",
                payload: .object([
                    "requestId": .string("stream-expired-chatgpt")
                ])
            ),
        ]
    )
}

@Test
func desktopNetworkFetchNeverSendsAPIKeyToChatGPTAccountRoutes() async {
    let transport = NetworkFetchTransportRecorder(
        response: .init(
            status: 200,
            headers: ["Content-Type": "application/json"],
            body: Data("{}".utf8)
        )
    )
    let client = CodexDesktopNetworkFetchClient(transport: transport)

    let response = await client.response(
        to: networkFetchRequest(
            requestID: "request-api-key-chatgpt",
            url: "/wham/usage",
            headers: ["X-OpenAI-Attach-Auth": "1"]
        ),
        credentials: CodexOfficialCredentials(
            accessToken: "fixture-api-key",
            accountID: nil,
            baseURL: CodexOfficialCredentials.openAIAPIBaseURL,
            authMethod: .apiKey
        )
    )

    #expect(
        response == .fetchFailure(
            requestID: "request-api-key-chatgpt",
            status: 401,
            error: "ChatGPT authentication required",
            errorCode: nil
        )
    )
    #expect(await transport.capturedRequests().isEmpty)
}

@Test
func desktopNetworkFetchDoesNotCallChatGPTAccountRoutesWhileSignedOut() async {
    let transport = NetworkFetchTransportRecorder(
        response: .init(
            status: 200,
            headers: ["Content-Type": "application/json"],
            body: Data("{}".utf8)
        )
    )
    let client = CodexDesktopNetworkFetchClient(transport: transport)

    let response = await client.response(
        to: networkFetchRequest(
            requestID: "request-signed-out-chatgpt",
            url: "/wham/tasks/list?limit=20"
        ),
        credentials: nil
    )

    #expect(
        response == .fetchFailure(
            requestID: "request-signed-out-chatgpt",
            status: 401,
            error: "ChatGPT authentication required",
            errorCode: nil
        )
    )
    #expect(await transport.capturedRequests().isEmpty)
}

@Test
func desktopNetworkFetchAttachesAPIKeyOnlyToOpenAIAPIHost() async {
    let transport = NetworkFetchTransportRecorder(
        response: .init(
            status: 200,
            headers: ["Content-Type": "application/json"],
            body: Data("{}".utf8)
        )
    )
    let client = CodexDesktopNetworkFetchClient(transport: transport)

    _ = await client.response(
        to: networkFetchRequest(
            requestID: "request-api-key-openai",
            url: "https://api.openai.com/v1/models",
            headers: ["X-OpenAI-Attach-Auth": "1"]
        ),
        credentials: CodexOfficialCredentials(
            accessToken: "fixture-api-key",
            accountID: nil,
            baseURL: CodexOfficialCredentials.openAIAPIBaseURL,
            authMethod: .apiKey
        )
    )

    let request = await transport.capturedRequests().first
    #expect(
        request?.headers["Authorization"]
            == "Bearer fixture-api-key"
    )
    #expect(request?.headers["ChatGPT-Account-Id"] == nil)
}

@Test
func desktopNetworkFetchForwardsReleasedStatsigRequestWithoutAuth() async {
    let transport = NetworkFetchTransportRecorder(
        response: .init(
            status: 200,
            headers: ["content-type": "application/json; charset=utf-8"],
            body: Data(#"{"has_updates":false}"#.utf8)
        )
    )
    let client = CodexDesktopNetworkFetchClient(transport: transport)

    let response = await client.response(
        to: networkFetchRequest(
            requestID: "request-statsig",
            url: "https://ab.chatgpt.com/v1/initialize",
            body: #"{"sdkKey":"fixture"}"#
        ),
        credentials: CodexOfficialCredentials(
            accessToken: "fixture-access-token",
            accountID: "fixture-account"
        )
    )

    #expect(
        response == .fetchSuccess(
            requestID: "request-statsig",
            status: 200,
            headers: [
                "content-type": "application/json; charset=utf-8"
            ],
            body: .object(["has_updates": .bool(false)])
        )
    )
    let captured = await transport.capturedRequests()
    #expect(captured.count == 1)
    #expect(
        captured.first?.url.absoluteString
            == "https://ab.chatgpt.com/v1/initialize"
    )
    #expect(captured.first?.headers["Authorization"] == nil)
    #expect(captured.first?.headers["ChatGPT-Account-Id"] == nil)
    #expect(captured.first?.headers["Content-Type"] == "application/json")
}

@Test
func desktopNetworkFetchPreservesNestedStatsigPayloadString() async {
    let nestedPayload = #"{"user":{"userID":"fixture-user"}}"#
    let outerPayload = try! JSONSerialization.data(
        withJSONObject: ["statsigPayload": nestedPayload],
        options: [.sortedKeys]
    )
    let transport = NetworkFetchTransportRecorder(
        response: .init(
            status: 200,
            headers: ["content-type": "application/json"],
            body: outerPayload
        )
    )
    let client = CodexDesktopNetworkFetchClient(transport: transport)

    let response = await client.response(
        to: networkFetchRequest(
            requestID: "request-statsig-bootstrap",
            url: "/wham/statsig/bootstrap"
        ),
        credentials: nil
    )

    #expect(
        response == .fetchSuccess(
            requestID: "request-statsig-bootstrap",
            status: 200,
            headers: ["content-type": "application/json"],
            body: .object([
                "statsigPayload": .string(nestedPayload)
            ])
        )
    )
}

@Test
func desktopNetworkFetchExpandsReleasedVoiceConfigForStatsigLookup() async {
    let nestedPayload = #"{"dynamic_configs":{"729731510":{"v":"voice-value"}},"values":{"voice-value":{"greeting_enabled":true,"prompt":"fixture-prompt"}}}"#
    let outerPayload = try! JSONSerialization.data(
        withJSONObject: ["statsigPayload": nestedPayload],
        options: [.sortedKeys]
    )
    let transport = NetworkFetchTransportRecorder(
        response: .init(
            status: 200,
            headers: ["content-type": "application/json"],
            body: outerPayload
        )
    )
    let client = CodexDesktopNetworkFetchClient(transport: transport)

    let response = await client.response(
        to: networkFetchRequest(
            requestID: "request-voice-statsig-bootstrap",
            url: "/wham/statsig/bootstrap"
        ),
        credentials: nil
    )

    guard case let .fetchSuccess(_, _, _, .object(fields)) = response,
          case let .string(payload)? = fields["statsigPayload"],
          let payloadData = payload.data(using: .utf8),
          let decoded = try? JSONDecoder().decode(
              CodexJSONValue.self,
              from: payloadData
          ),
          case let .object(payloadFields) = decoded,
          case let .object(configs)? = payloadFields["dynamic_configs"],
          case let .object(released)? = configs["729731510"],
          case let .object(alias)? = configs["1193530394"]
    else {
        Issue.record("Released voice config was not made lookup-compatible")
        return
    }

    let expectedValue: CodexJSONValue = .object([
        "greeting_enabled": .bool(true),
        "prompt": .string("fixture-prompt"),
    ])
    #expect(released["value"] == expectedValue)
    #expect(alias["value"] == expectedValue)
    #expect(alias["v"] == .string("voice-value"))
}

@Test
func desktopNetworkFetchDoesNotReuseStatsigBootstrapAcrossDifferentContexts()
    async
{
    let nestedPayload = #"{"dynamic_configs":{"1193530394":{"value":{"enabled":true}}}}"#
    let outerPayload = try! JSONSerialization.data(
        withJSONObject: ["statsigPayload": nestedPayload],
        options: [.sortedKeys]
    )
    let transport = NetworkFetchTransportRecorder(
        response: .init(
            status: 200,
            headers: ["content-type": "application/json"],
            body: outerPayload
        )
    )
    let client = CodexDesktopNetworkFetchClient(transport: transport)
    let credentials = CodexOfficialCredentials(
        accessToken: "fixture-access-token",
        accountID: "fixture-account"
    )

    let primary = await client.response(
        to: networkFetchRequest(
            requestID: "primary-statsig",
            url: "/wham/statsig/bootstrap",
            body: #"{"renderer":"primary"}"#
        ),
        credentials: credentials
    )
    let overlay = await client.response(
        to: networkFetchRequest(
            requestID: "overlay-statsig",
            url: "/wham/statsig/bootstrap",
            body: #"{"renderer":"overlay"}"#
        ),
        credentials: credentials
    )

    #expect(await transport.capturedRequests().count == 2)
    #expect(
        primary == .fetchSuccess(
            requestID: "primary-statsig",
            status: 200,
            headers: ["content-type": "application/json"],
            body: .object(["statsigPayload": .string(nestedPayload)])
        )
    )
    #expect(
        overlay == .fetchSuccess(
            requestID: "overlay-statsig",
            status: 200,
            headers: ["content-type": "application/json"],
            body: .object(["statsigPayload": .string(nestedPayload)])
        )
    )
}

@Test
func desktopNetworkFetchReusesAuthenticatedStatsigBootstrapForSameContext()
    async
{
    let nestedPayload = #"{"dynamic_configs":{"1193530394":{"value":{"enabled":true}}}}"#
    let outerPayload = try! JSONSerialization.data(
        withJSONObject: ["statsigPayload": nestedPayload],
        options: [.sortedKeys]
    )
    let transport = NetworkFetchTransportRecorder(
        response: .init(
            status: 200,
            headers: ["content-type": "application/json"],
            body: outerPayload
        )
    )
    let client = CodexDesktopNetworkFetchClient(transport: transport)
    let credentials = CodexOfficialCredentials(
        accessToken: "fixture-access-token",
        accountID: "fixture-account"
    )
    let requestBody = #"{"stableID":"fixture-renderer"}"#

    _ = await client.response(
        to: networkFetchRequest(
            requestID: "primary-statsig",
            url: "/wham/statsig/bootstrap",
            body: requestBody
        ),
        credentials: credentials
    )
    _ = await client.response(
        to: networkFetchRequest(
            requestID: "same-context-statsig",
            url: "/wham/statsig/bootstrap",
            body: requestBody
        ),
        credentials: credentials
    )

    #expect(await transport.capturedRequests().count == 1)
}

@Test
func desktopNetworkFetchBoundsReleasedStatsigInitializeAndCancelsTransport()
    async
{
    let transport = DelayingNetworkFetchTransport(
        delay: .seconds(5)
    )
    let client = CodexDesktopNetworkFetchClient(
        transport: transport,
        statsigInitializeTimeout: .milliseconds(20)
    )

    let response = await client.response(
        to: networkFetchRequest(
            requestID: "request-statsig-timeout",
            url: "https://ab.chatgpt.com/v1/initialize",
            body: #"{"sdkKey":"fixture"}"#
        ),
        credentials: nil
    )

    #expect(
        response == .fetchFailure(
            requestID: "request-statsig-timeout",
            status: 499,
            error: "Network request timed out",
            errorCode: nil
        )
    )
    #expect(await transport.executionCount() == 1)
    #expect(await transport.wasCancelled())
}

@Test(
    arguments: [
        (
            requestID: "request-statsig-bootstrap-timeout",
            url: "/wham/statsig/bootstrap"
        ),
        (
            requestID: "request-account-check-timeout",
            url: "/wham/accounts/check"
        ),
    ]
)
func desktopNetworkFetchBoundsStartupCriticalProductRequestsAndCancelsTransport(
    requestID: String,
    url: String
) async {
    let transport = DelayingNetworkFetchTransport(
        delay: .seconds(5)
    )
    let client = CodexDesktopNetworkFetchClient(
        transport: transport,
        statsigInitializeTimeout: .milliseconds(20)
    )

    let response = await client.response(
        to: networkFetchRequest(
            requestID: requestID,
            url: url
        ),
        credentials: CodexOfficialCredentials(
            accessToken: "fixture-access-token",
            accountID: "fixture-account"
        )
    )

    #expect(
        response == .fetchFailure(
            requestID: requestID,
            status: 499,
            error: "Network request timed out",
            errorCode: nil
        )
    )
    #expect(await transport.executionCount() == 1)
    #expect(await transport.wasCancelled())
}

@Test
func desktopNetworkFetchLeavesOtherNetworkEndpointsUnbounded() async {
    let transport = DelayingNetworkFetchTransport(
        delay: .milliseconds(40)
    )
    let client = CodexDesktopNetworkFetchClient(
        transport: transport,
        statsigInitializeTimeout: .milliseconds(5)
    )

    let response = await client.response(
        to: networkFetchRequest(
            requestID: "request-statsig-other-path",
            url: "https://ab.chatgpt.com/v1/rgstr"
        ),
        credentials: nil
    )

    #expect(
        response == .fetchSuccess(
            requestID: "request-statsig-other-path",
            status: 204,
            headers: [:],
            body: .null
        )
    )
    #expect(await transport.executionCount() == 1)
    #expect(!(await transport.wasCancelled()))
}

@Test
func desktopNetworkFetchMapsCallerCancellationToReleased499() async {
    let client = CodexDesktopNetworkFetchClient(
        transport: CancellationErrorNetworkFetchTransport()
    )

    let response = await client.response(
        to: networkFetchRequest(
            requestID: "request-cancelled-task",
            url: "https://example.test/data"
        ),
        credentials: nil
    )

    #expect(
        response == .fetchFailure(
            requestID: "request-cancelled-task",
            status: 499,
            error: "Network request cancelled",
            errorCode: nil
        )
    )
}

@Test
func desktopNetworkFetchMapsURLSessionCancellationToReleased499() async {
    let client = CodexDesktopNetworkFetchClient(
        transport: URLCancelledNetworkFetchTransport()
    )

    let response = await client.response(
        to: networkFetchRequest(
            requestID: "request-cancelled-url-session",
            url: "https://example.test/data"
        ),
        credentials: nil
    )

    #expect(
        response == .fetchFailure(
            requestID: "request-cancelled-url-session",
            status: 499,
            error: "Network request cancelled",
            errorCode: nil
        )
    )
}

@Test
func desktopNetworkFetchPreservesSafeURLSessionFailureCodes() async {
    let cases: [(URLError.Code, Int)] = [
        (.notConnectedToInternet, -1009),
        (.cannotFindHost, -1003),
        (.secureConnectionFailed, -1200),
    ]

    for (urlErrorCode, rawValue) in cases {
        let client = CodexDesktopNetworkFetchClient(
            transport: ThrowingNetworkFetchTransport(
                urlErrorCode: urlErrorCode
            )
        )

        let response = await client.response(
            to: networkFetchRequest(
                requestID: "request-url-error-\(rawValue)",
                url: "https://example.test/network"
            ),
            credentials: nil
        )

        #expect(
            response == .fetchFailure(
                requestID: "request-url-error-\(rawValue)",
                status: 500,
                error: "Network request failed",
                errorCode: "NSURLErrorDomain:\(rawValue)"
            )
        )
    }
}

@Test
func desktopNetworkFetchTaskListResolvesAuthAndKeepsSafeURLSessionCode()
    async throws
{
    let transport = ThrowingNetworkFetchTransportRecorder(
        urlErrorCode: .cannotFindHost
    )
    let client = CodexDesktopNetworkFetchClient(transport: transport)

    let response = await client.response(
        to: networkFetchRequest(
            requestID: "request-task-list-url-error",
            url: "/wham/tasks/list?limit=20",
            headers: [
                "X-OpenAI-Attach-Auth": "1",
                "X-OpenAI-Attach-Integrity-State": "1",
                "X-OpenAI-Attach-Desktop-Surface": "1",
            ]
        ),
        credentials: CodexOfficialCredentials(
            accessToken: "fixture-access-token",
            accountID: "fixture-account"
        )
    )

    #expect(
        response == .fetchFailure(
            requestID: "request-task-list-url-error",
            status: 500,
            error: "Network request failed",
            errorCode: "NSURLErrorDomain:-1003"
        )
    )
    let request = try #require(await transport.capturedRequest())
    #expect(
        request.url.absoluteString
            == "https://chatgpt.com/backend-api/wham/tasks/list?limit=20"
    )
    #expect(request.headers["Authorization"] == "Bearer fixture-access-token")
    #expect(request.headers["ChatGPT-Account-Id"] == "fixture-account")
    #expect(request.headers["X-OpenAI-Attach-Auth"] == nil)
    #expect(request.headers["X-OpenAI-Attach-Integrity-State"] == nil)
    #expect(request.headers["X-OpenAI-Attach-Desktop-Surface"] == nil)
}

@Test
func desktopURLSessionTransportCancelsHangingStatsigBodyAtDeadline()
    async
{
    HangingBodyURLProtocol.stopState.reset()
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [HangingBodyURLProtocol.self]
    let session = URLSession(configuration: configuration)
    let client = CodexDesktopNetworkFetchClient(
        transport:
            CodexDesktopURLSessionNetworkFetchTransport(
                session: session
            ),
        statsigInitializeTimeout: .milliseconds(20)
    )

    let response = await client.response(
        to: networkFetchRequest(
            requestID: "request-hanging-body",
            url: "https://ab.chatgpt.com/v1/initialize",
            body: #"{"sdkKey":"fixture"}"#
        ),
        credentials: nil
    )
    session.invalidateAndCancel()

    #expect(
        response == .fetchFailure(
            requestID: "request-hanging-body",
            status: 499,
            error: "Network request timed out",
            errorCode: nil
        )
    )
    #expect(
        await HangingBodyURLProtocol.stopState.waitUntilStopped(
            timeout: .seconds(1)
        )
    )
}

@Test
func desktopNetworkFetchRejectsAuthAttachmentToNonProductOrigin() async {
    let transport = NetworkFetchTransportRecorder(
        response: .init(status: 204, headers: [:], body: Data())
    )
    let client = CodexDesktopNetworkFetchClient(transport: transport)

    let response = await client.response(
        to: networkFetchRequest(
            requestID: "request-untrusted",
            url: "https://example.test/data",
            headers: ["X-OpenAI-Attach-Auth": "true"]
        ),
        credentials: CodexOfficialCredentials(
            accessToken: "fixture-access-token",
            accountID: nil
        )
    )

    #expect(
        response == .fetchFailure(
            requestID: "request-untrusted",
            status: 400,
            error: "Refusing to attach authentication to non-OpenAI URL",
            errorCode: nil
        )
    )
    #expect(await transport.capturedRequests().isEmpty)
}

@Test
func desktopNetworkFetchReturnsReleasedHTTPFailureShape() async {
    let transport = NetworkFetchTransportRecorder(
        response: .init(
            status: 503,
            headers: ["content-type": "text/plain"],
            body: Data("temporarily unavailable".utf8)
        )
    )
    let client = CodexDesktopNetworkFetchClient(transport: transport)

    let response = await client.response(
        to: networkFetchRequest(
            requestID: "request-failure",
            url: "https://example.test/data"
        ),
        credentials: nil
    )

    #expect(
        response == .fetchFailure(
            requestID: "request-failure",
            status: 503,
            error: "temporarily unavailable",
            errorCode: nil
        )
    )
}

@Test
func desktopProjectFileDownloadResolvesInternalURLsAndAttachesAuth()
    async throws
{
    let transport = NetworkFetchTransportRecorder(
        response: .init(
            status: 200,
            headers: [:],
            body: Data("project-file".utf8)
        )
    )
    let client = CodexDesktopNetworkFetchClient(transport: transport)
    let credentials = CodexOfficialCredentials(
        accessToken: "fixture-access-token",
        accountID: "fixture-account"
    )

    let first = try await client.downloadProjectFile(
        downloadURL: "/backend-api/files/one?download=1",
        requestHeaders: ["X-Project": "one"],
        credentials: credentials
    )
    let second = try await client.downloadProjectFile(
        downloadURL: "/__codex-api/files/two",
        requestHeaders: [:],
        credentials: credentials
    )

    #expect(first == Data("project-file".utf8))
    #expect(second == first)
    let captured = await transport.capturedRequests()
    #expect(captured.count == 2)
    #expect(
        captured[0].url.absoluteString
            == "https://chatgpt.com/backend-api/files/one?download=1"
    )
    #expect(
        captured[1].url.absoluteString
            == "https://chatgpt.com/backend-api/files/two"
    )
    #expect(captured.allSatisfy { $0.method == "GET" })
    #expect(captured.allSatisfy { $0.body == nil })
    #expect(captured.allSatisfy { $0.timeoutInterval == 60 })
    #expect(captured[0].headers["X-Project"] == "one")
    #expect(
        captured[0].headers["Authorization"]
            == "Bearer fixture-access-token"
    )
    #expect(
        captured[0].headers["ChatGPT-Account-Id"]
            == "fixture-account"
    )
}

@Test
func desktopProjectFileDownloadNeverLeaksAuthToPresignedHost()
    async throws
{
    let transport = NetworkFetchTransportRecorder(
        response: .init(
            status: 200,
            headers: [:],
            body: Data([0x01, 0x02])
        )
    )
    let client = CodexDesktopNetworkFetchClient(transport: transport)

    _ = try await client.downloadProjectFile(
        downloadURL:
            "https://files.example.test/signed?id=fixture",
        requestHeaders: [
            "Authorization": "Signed fixture-signature",
            "X-Download": "fixture",
        ],
        credentials: CodexOfficialCredentials(
            accessToken: "must-not-leak",
            accountID: "must-not-leak"
        )
    )

    let request = try #require(
        await transport.capturedRequests().first
    )
    #expect(
        request.headers["Authorization"]
            == "Signed fixture-signature"
    )
    #expect(request.headers["ChatGPT-Account-Id"] == nil)
    #expect(request.headers["X-Download"] == "fixture")
}

@Test
func desktopProjectFileDownloadPreservesExplicitOfficialAuthorization()
    async throws
{
    let transport = NetworkFetchTransportRecorder(
        response: .init(
            status: 204,
            headers: [:],
            body: Data()
        )
    )
    let client = CodexDesktopNetworkFetchClient(transport: transport)

    _ = try await client.downloadProjectFile(
        downloadURL: "relative/project-file",
        requestHeaders: [
            "authorization": "Bearer renderer-token"
        ],
        credentials: CodexOfficialCredentials(
            accessToken: "fixture-access-token",
            accountID: "fixture-account"
        )
    )

    let request = try #require(
        await transport.capturedRequests().first
    )
    #expect(
        request.url.absoluteString
            == "https://chatgpt.com/backend-api/relative/project-file"
    )
    #expect(
        request.headers["authorization"]
            == "Bearer renderer-token"
    )
    #expect(request.headers["Authorization"] == nil)
    #expect(request.headers["ChatGPT-Account-Id"] == nil)
}

@Test
func desktopProjectFileDownloadSurfacesHTTPStatus() async {
    let transport = NetworkFetchTransportRecorder(
        response: .init(
            status: 403,
            headers: [:],
            body: Data("denied".utf8)
        )
    )
    let client = CodexDesktopNetworkFetchClient(transport: transport)

    do {
        _ = try await client.downloadProjectFile(
            downloadURL: "/backend-api/files/denied",
            requestHeaders: [:],
            credentials: nil
        )
        Issue.record("Expected project file download to fail")
    } catch let error as
        CodexDesktopProjectFileSyncBackend.TransferError
    {
        #expect(error.status == 403)
    } catch {
        Issue.record("Unexpected error: \(error)")
    }
}

private func networkFetchRequest(
    requestID: String,
    url: String,
    headers: [String: String]? = nil,
    body: String? = nil
) -> CodexDesktopFetchRequest {
    CodexDesktopFetchRequest(
        requestID: requestID,
        method: "POST",
        url: url,
        hostMethod: "",
        headers: headers,
        body: body,
        reportUploadProgress: false
    )
}

private actor MessageCollector {
    private var messages: [CodexDesktopHostMessage] = []

    func append(_ message: CodexDesktopHostMessage) {
        messages.append(message)
    }

    func values() -> [CodexDesktopHostMessage] {
        messages
    }
}

private struct FixtureDeviceCheckTokenProvider:
    CodexDesktopDeviceCheckTokenProviding
{
    let tokenValue: String?

    func token() async -> String? {
        tokenValue
    }
}

private actor FlakyTLSNetworkStreamTransport:
    CodexDesktopNetworkStreamTransport
{
    private let failuresBeforeSuccess: Int
    private var executions = 0

    init(failuresBeforeSuccess: Int) {
        self.failuresBeforeSuccess = failuresBeforeSuccess
    }

    func executeStream(
        _ request: CodexDesktopNetworkTransportRequest
    ) async throws -> CodexDesktopNetworkStreamTransportResponse {
        executions += 1
        if executions <= failuresBeforeSuccess {
            throw URLError(.secureConnectionFailed)
        }
        return .init(
            status: 200,
            headers: [:],
            body: AsyncThrowingStream { continuation in
                continuation.finish()
            }
        )
    }

    func executionCount() -> Int {
        executions
    }
}

private actor StartedBodyFailureNetworkStreamTransport:
    CodexDesktopNetworkStreamTransport
{
    private var executions = 0

    func executeStream(
        _ request: CodexDesktopNetworkTransportRequest
    ) async throws -> CodexDesktopNetworkStreamTransportResponse {
        executions += 1
        return .init(
            status: 200,
            headers: [:],
            body: AsyncThrowingStream { continuation in
                continuation.finish(
                    throwing: URLError(.networkConnectionLost)
                )
            }
        )
    }

    func executionCount() -> Int {
        executions
    }
}

private actor SuspendedNetworkStreamTransport:
    CodexDesktopNetworkStreamTransport
{
    private var executions = 0

    func executeStream(
        _ request: CodexDesktopNetworkTransportRequest
    ) async throws -> CodexDesktopNetworkStreamTransportResponse {
        executions += 1
        // Model a URL loading stack that has not delivered response headers
        // and does not promptly cooperate with task cancellation.
        await withUnsafeContinuation { (_: UnsafeContinuation<Void, Never>) in
        }
        throw CancellationError()
    }

    func executionCount() -> Int {
        executions
    }
}

private actor NetworkStreamTransportRecorder:
    CodexDesktopNetworkStreamTransport
{
    private let status: Int
    private var continuation:
        AsyncThrowingStream<Data, any Error>.Continuation?
    private var request: CodexDesktopNetworkTransportRequest?

    init(status: Int = 200) {
        self.status = status
    }

    func executeStream(
        _ request: CodexDesktopNetworkTransportRequest
    ) async throws -> CodexDesktopNetworkStreamTransportResponse {
        self.request = request
        let stream = AsyncThrowingStream<Data, any Error> {
            continuation in
            self.continuation = continuation
            if !(200 ..< 300).contains(status) {
                continuation.finish()
            }
        }
        return .init(
            status: status,
            headers: ["content-type": "text/event-stream"],
            body: stream
        )
    }

    func emit(_ data: Data) async {
        while continuation == nil {
            await Task.yield()
        }
        continuation?.yield(data)
    }

    func finish() async {
        while continuation == nil {
            await Task.yield()
        }
        continuation?.finish()
    }

    func capturedRequest() -> CodexDesktopNetworkTransportRequest? {
        request
    }
}

private actor SequencedNetworkStreamTransportRecorder:
    CodexDesktopNetworkStreamTransport
{
    struct Response: Sendable {
        let status: Int
        let headers: [String: String]
        let chunks: [Data]
    }

    private let responses: [Response]
    private var requests: [CodexDesktopNetworkTransportRequest] = []

    init(responses: [Response]) {
        self.responses = responses
    }

    func executeStream(
        _ request: CodexDesktopNetworkTransportRequest
    ) async throws -> CodexDesktopNetworkStreamTransportResponse {
        requests.append(request)
        let response = responses[
            min(requests.count - 1, responses.count - 1)
        ]
        return .init(
            status: response.status,
            headers: response.headers,
            body: AsyncThrowingStream { continuation in
                for chunk in response.chunks {
                    continuation.yield(chunk)
                }
                continuation.finish()
            }
        )
    }

    func capturedRequests() -> [CodexDesktopNetworkTransportRequest] {
        requests
    }
}

private actor NetworkFetchTransportRecorder:
    CodexDesktopNetworkFetchTransport
{
    private let responses: [CodexDesktopNetworkTransportResponse]
    private var requests: [CodexDesktopNetworkTransportRequest] = []

    init(response: CodexDesktopNetworkTransportResponse) {
        responses = [response]
    }

    init(responses: [CodexDesktopNetworkTransportResponse]) {
        self.responses = responses
    }

    func execute(
        _ request: CodexDesktopNetworkTransportRequest
    ) async throws -> CodexDesktopNetworkTransportResponse {
        requests.append(request)
        let index = min(requests.count - 1, responses.count - 1)
        return responses[index]
    }

    func capturedRequests() -> [CodexDesktopNetworkTransportRequest] {
        requests
    }
}

private actor CredentialRefreshRecorder {
    private let result: Result<CodexOfficialCredentials, any Error>
    private var calls = 0

    init(result: Result<CodexOfficialCredentials, any Error>) {
        self.result = result
    }

    func refresh() throws -> CodexOfficialCredentials {
        calls += 1
        return try result.get()
    }

    func callCount() -> Int {
        calls
    }
}

private actor DelayingNetworkFetchTransport:
    CodexDesktopNetworkFetchTransport
{
    private let delay: Duration
    private var executions = 0
    private var cancelled = false

    init(delay: Duration) {
        self.delay = delay
    }

    func execute(
        _ request: CodexDesktopNetworkTransportRequest
    ) async throws -> CodexDesktopNetworkTransportResponse {
        executions += 1
        do {
            try await Task.sleep(for: delay)
        } catch {
            if error is CancellationError {
                cancelled = true
            }
            throw error
        }
        return .init(status: 204, headers: [:], body: Data())
    }

    func executionCount() -> Int {
        executions
    }

    func wasCancelled() -> Bool {
        cancelled
    }
}

private struct CancellationErrorNetworkFetchTransport:
    CodexDesktopNetworkFetchTransport
{
    func execute(
        _ request: CodexDesktopNetworkTransportRequest
    ) async throws -> CodexDesktopNetworkTransportResponse {
        throw CancellationError()
    }
}

private struct URLCancelledNetworkFetchTransport:
    CodexDesktopNetworkFetchTransport
{
    func execute(
        _ request: CodexDesktopNetworkTransportRequest
    ) async throws -> CodexDesktopNetworkTransportResponse {
        throw URLError(.cancelled)
    }
}

private struct ThrowingNetworkFetchTransport:
    CodexDesktopNetworkFetchTransport
{
    let urlErrorCode: URLError.Code

    func execute(
        _ request: CodexDesktopNetworkTransportRequest
    ) async throws -> CodexDesktopNetworkTransportResponse {
        throw URLError(urlErrorCode)
    }
}

private actor ThrowingNetworkFetchTransportRecorder:
    CodexDesktopNetworkFetchTransport
{
    private let urlErrorCode: URLError.Code
    private var request: CodexDesktopNetworkTransportRequest?

    init(urlErrorCode: URLError.Code) {
        self.urlErrorCode = urlErrorCode
    }

    func execute(
        _ request: CodexDesktopNetworkTransportRequest
    ) async throws -> CodexDesktopNetworkTransportResponse {
        self.request = request
        throw URLError(urlErrorCode)
    }

    func capturedRequest() -> CodexDesktopNetworkTransportRequest? {
        request
    }
}

private final class URLProtocolStopState: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false

    func reset() {
        lock.lock()
        stopped = false
        lock.unlock()
    }

    func markStopped() {
        lock.lock()
        stopped = true
        lock.unlock()
    }

    func wasStopped() -> Bool {
        lock.lock()
        defer {
            lock.unlock()
        }
        return stopped
    }

    func waitUntilStopped(timeout: Duration) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)

        while !wasStopped() {
            guard clock.now < deadline else {
                return false
            }
            try? await Task.sleep(for: .milliseconds(1))
        }

        return true
    }
}

private final class HangingBodyURLProtocol: URLProtocol {
    static let stopState = URLProtocolStopState()

    override class func canInit(
        with request: URLRequest
    ) -> Bool {
        request.url?.host == "ab.chatgpt.com"
    }

    override class func canonicalRequest(
        for request: URLRequest
    ) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url,
              let response = HTTPURLResponse(
                  url: url,
                  statusCode: 200,
                  httpVersion: "HTTP/1.1",
                  headerFields: [
                      "Content-Type": "application/json",
                      "Content-Length": "1024",
                  ]
              )
        else {
            return
        }
        client?.urlProtocol(
            self,
            didReceive: response,
            cacheStoragePolicy: .notAllowed
        )
        client?.urlProtocol(
            self,
            didLoad: Data(#"{"partial":"body""#.utf8)
        )
    }

    override func stopLoading() {
        Self.stopState.markStopped()
    }
}
