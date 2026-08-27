import CodexPadDomain
import Foundation
import Testing
@testable import CodexPadApplication

@Test @MainActor
func accountServiceMapsOfficialUsageAndRateLimitPayloads() async throws {
    let transport = AccountFixtureTransport(responses: [
        "/backend-api/wham/usage": #"{"plan_type":"pro","rate_limit":{"primary_window":{"used_percent":42,"limit_window_seconds":3600,"reset_at":1735689720}},"rate_limit_reached_type":{"type":"workspace_member_usage_limit_reached"},"rate_limit_reset_credits":{"available_count":3}}"#,
        "/backend-api/wham/profiles/me": #"{"stats":{"lifetime_tokens":1234,"peak_daily_tokens":90,"daily_usage_buckets":[{"start_date":"2026-07-30","tokens":44}]}}"#,
    ])
    let client = CodexAccountRateLimitsClient(
        credentialsProvider: { CodexOfficialCredentials(accessToken: "token", accountID: "account") },
        transport: transport,
        baseURL: URL(string: "https://chatgpt.com/backend-api")!
    )

    let limits = try await client.readAccountRateLimits()
    guard case let .object(limitRoot) = limits,
          case let .object(snapshot)? = limitRoot["rateLimits"],
          case let .object(primary)? = snapshot["primary"]
    else { Issue.record("rate-limit response shape mismatch"); return }
    #expect(snapshot["planType"] == .string("pro"))
    #expect(snapshot["rateLimitReachedType"] == .string("workspace_member_usage_limit_reached"))
    #expect(primary["usedPercent"] == .integer(42))
    #expect(primary["windowDurationMins"] == .integer(60))

    let usage = try await client.readAccountUsage()
    guard case let .object(usageRoot) = usage,
          case let .object(summary)? = usageRoot["summary"]
    else { Issue.record("usage response shape mismatch"); return }
    #expect(summary["lifetimeTokens"] == .integer(1234))
    #expect(usageRoot["dailyUsageBuckets"] != nil)

    let requests = await transport.requests
    #expect(requests.allSatisfy { $0.headers["Authorization"] == "Bearer token" })
    #expect(requests.allSatisfy { $0.headers["chatgpt-account-id"] == "account" })
}

@Test @MainActor
func accountServiceReadsThreadUsageWithOfficialBackendRequest() async throws {
    let transport = AccountFixtureTransport(responses: [
        "/backend-api/wham/usage/thread_usage/query": #"{"threads":[{"thread_id":"thread-1","estimated_usage_credits_micros":46000000,"estimated_usage_usd_micros":1820000,"groups":[{"model":"gpt-5.5","reasoning_effort":"high","speed":"fast","estimated_usage_credits_micros":46000000,"net_new_input_tokens":10,"cached_input_tokens":2,"input_tokens":12,"output_tokens":8,"total_tokens":20}]}]}"#,
    ])
    let client = CodexAccountRateLimitsClient(
        credentialsProvider: { CodexOfficialCredentials(accessToken: "token", accountID: "account") },
        transport: transport,
        baseURL: URL(string: "https://chatgpt.com/backend-api")!
    )

    let usage = try await client.readAccountUsage(threadID: "thread-1")
    #expect(usage == .object([
        "summary": .object([
            "lifetimeTokens": .null,
            "peakDailyTokens": .null,
            "longestRunningTurnSec": .null,
            "currentStreakDays": .null,
            "longestStreakDays": .null,
        ]),
        "dailyUsageBuckets": .null,
        "threadUsage": .object([
            "threadId": .string("thread-1"),
            "estimatedUsageCreditsMicros": .integer(46_000_000),
            "estimatedUsageUsdMicros": .integer(1_820_000),
            "groups": .array([.object([
                "model": .string("gpt-5.5"),
                "reasoningEffort": .string("high"),
                "speed": .string("fast"),
                "estimatedUsageCreditsMicros": .integer(46_000_000),
                "netNewInputTokens": .integer(10),
                "cachedInputTokens": .integer(2),
                "inputTokens": .integer(12),
                "outputTokens": .integer(8),
                "totalTokens": .integer(20),
            ])]),
        ]),
    ]))

    let request = try #require(await transport.requests.first)
    #expect(request.method == "POST")
    #expect(request.url.path == "/backend-api/wham/usage/thread_usage/query")
    let body = try #require(request.body)
    let bodyObject = try #require(JSONSerialization.jsonObject(with: body) as? [String: [String]])
    #expect(bodyObject == ["thread_ids": ["thread-1"]])
}

@Test @MainActor
func accountServiceUsesOnlyTheRequestedThreadFromBackendResponse() async throws {
    let transport = AccountFixtureTransport(responses: [
        "/backend-api/wham/usage/thread_usage/query": #"{"threads":[{"thread_id":"other","estimated_usage_credits_micros":1,"estimated_usage_usd_micros":null,"groups":[]},{"thread_id":"target","estimated_usage_credits_micros":2,"estimated_usage_usd_micros":null,"groups":[]}] }"#,
    ])
    let client = CodexAccountRateLimitsClient(
        credentialsProvider: { CodexOfficialCredentials(accessToken: "token", accountID: nil) },
        transport: transport,
        baseURL: URL(string: "https://chatgpt.com/backend-api")!
    )

    let usage = try await client.readAccountUsage(threadID: "target")
    guard case let .object(root) = usage,
          case let .object(thread)? = root["threadUsage"]
    else { Issue.record("thread usage response shape mismatch"); return }
    #expect(thread["threadId"] == .string("target"))
    #expect(thread["estimatedUsageCreditsMicros"] == .integer(2))
}

@Test @MainActor
func accountServiceMapsWorkspaceMessagesAndFeatureDisabledResponse()
    async throws
{
    let transport = AccountSequenceTransport(responses: [
        .init(
            status: 200,
            headers: [:],
            body: Data(
                """
                {"messages":[{"message_id":"message-1","message_type":"announcement","message_body":"Maintenance","created_at":"2026-07-30T12:34:56Z","archived_at":null}]}
                """.utf8
            )
        ),
        .init(status: 404, headers: [:], body: Data()),
    ])
    let client = CodexAccountRateLimitsClient(
        credentialsProvider: {
            CodexOfficialCredentials(
                accessToken: "token",
                accountID: "account"
            )
        },
        transport: transport,
        baseURL: URL(string: "https://chatgpt.com/backend-api")!
    )

    let enabled = try await client.readWorkspaceMessages()
    guard case let .object(enabledRoot) = enabled,
          case let .array(messages)? = enabledRoot["messages"],
          case let .object(message) = messages.first
    else {
        Issue.record("workspace-message response shape mismatch")
        return
    }
    #expect(enabledRoot["featureEnabled"] == .bool(true))
    #expect(message["messageId"] == .string("message-1"))
    #expect(message["messageType"] == .string("announcement"))
    #expect(message["messageBody"] == .string("Maintenance"))
    #expect(message["createdAt"] == .integer(1_785_414_896))
    #expect(message["archivedAt"] == .null)

    let disabled = try await client.readWorkspaceMessages()
    #expect(
        disabled == .object([
            "featureEnabled": .bool(false),
            "messages": .array([]),
        ])
    )
}

@Test @MainActor
func accountServiceUsesOfficialNudgeStatusAndBackendCreditType()
    async throws
{
    let transport = AccountSequenceTransport(responses: [
        .init(status: 429, headers: [:], body: Data()),
    ])
    let client = CodexAccountRateLimitsClient(
        credentialsProvider: {
            CodexOfficialCredentials(
                accessToken: "token",
                accountID: nil
            )
        },
        transport: transport,
        baseURL: URL(string: "https://chatgpt.com/backend-api")!
    )

    let result = try await client.sendAddCreditsNudgeEmail(
        creditType: "usage_limit"
    )

    #expect(
        result == .object([
            "status": .string("cooldown_active"),
        ])
    )
    let requests = await transport.requests
    let body = try #require(requests.first?.body)
    let object = try #require(
        JSONSerialization.jsonObject(with: body) as? [String: String]
    )
    #expect(object == ["credit_type": "usage_limit"])
}

private actor AccountFixtureTransport: CodexDesktopNetworkFetchTransport {
    let responses: [String: String]
    private(set) var requests: [CodexDesktopNetworkTransportRequest] = []
    init(responses: [String: String]) { self.responses = responses }
    func execute(_ request: CodexDesktopNetworkTransportRequest) async throws -> CodexDesktopNetworkTransportResponse {
        requests.append(request)
        let body = responses[request.url.path] ?? "{}"
        return .init(status: 200, headers: ["content-type": "application/json"], body: Data(body.utf8))
    }
}

private actor AccountSequenceTransport:
    CodexDesktopNetworkFetchTransport
{
    private var responses: [CodexDesktopNetworkTransportResponse]
    private(set) var requests:
        [CodexDesktopNetworkTransportRequest] = []

    init(responses: [CodexDesktopNetworkTransportResponse]) {
        self.responses = responses
    }

    func execute(
        _ request: CodexDesktopNetworkTransportRequest
    ) async throws -> CodexDesktopNetworkTransportResponse {
        requests.append(request)
        return responses.removeFirst()
    }
}
