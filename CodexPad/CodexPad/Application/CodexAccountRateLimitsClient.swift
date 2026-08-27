#if SWIFT_PACKAGE
import CodexPadDomain
import CodexPadProtocolBridge
#endif
import Foundation

@MainActor
public protocol CodexDesktopAccountRateLimitsReading: AnyObject {
    func readAccountRateLimits() async throws -> CodexJSONValue
    func readAccountUsage(threadID: String?) async throws -> CodexJSONValue
    func readWorkspaceMessages() async throws -> CodexJSONValue
    func consumeRateLimitResetCredit(
        idempotencyKey: String,
        creditID: String?
    ) async throws -> CodexJSONValue
    func sendAddCreditsNudgeEmail(
        creditType: String
    ) async throws -> CodexJSONValue
}

@MainActor
public final class CodexAccountRateLimitsClient: CodexDesktopAccountRateLimitsReading {
    private let credentialsProvider:
        @MainActor () -> CodexOfficialCredentials?
    private let transport: any CodexDesktopNetworkFetchTransport
    private let baseURL: URL

    public init(accountStore: CodexAccountStore,
                transport: any CodexDesktopNetworkFetchTransport = CodexDesktopURLSessionNetworkFetchTransport(),
                baseURL: URL = CodexDesktopNetworkFetchClient.releasedProductAPIBaseURL) {
        // `wham/*` is a ChatGPT-account service. OpenAI API keys do not have
        // a ChatGPT account identity and must never be sent to this route.
        credentialsProvider = { accountStore.chatGPTCredentials() }
        self.transport = transport
        self.baseURL = baseURL
    }

    public init(
        credentialsProvider:
            @escaping @MainActor () -> CodexOfficialCredentials?,
        transport: any CodexDesktopNetworkFetchTransport,
        baseURL: URL
    ) {
        self.credentialsProvider = credentialsProvider
        self.transport = transport
        self.baseURL = baseURL
    }

    public func readAccountRateLimits() async throws -> CodexJSONValue {
        let response = try await execute(path: "wham/usage")
        guard let object = try JSONSerialization.jsonObject(with: response.body) as? [String: Any] else { throw RateLimitError.invalidPayload }
        return Self.mapPayload(object)
    }

    public func readAccountUsage(threadID: String? = nil) async throws -> CodexJSONValue {
        if let threadID {
            let body = try JSONSerialization.data(
                withJSONObject: ["thread_ids": [threadID]]
            )
            let response: CodexDesktopNetworkTransportResponse
            do {
                response = try await execute(
                    path: Self.threadUsagePath(for: baseURL),
                    method: "POST",
                    body: body
                )
            } catch RateLimitError.http(401),
                      RateLimitError.http(403),
                      RateLimitError.http(404),
                      RateLimitError.http(503) {
                return Self.emptyThreadUsageResponse()
            }
            guard case let .object(root) = try Self.camelCaseJSON(response.body),
                  case let .array(threads)? = root["threads"]
            else { throw RateLimitError.invalidPayload }
            let matchingThread = threads.first { thread in
                guard case let .object(thread) = thread,
                      case let .string(responseThreadID)? = thread["threadId"]
                else { return false }
                return responseThreadID == threadID
            }
            return .object([
                "summary": Self.emptyThreadUsageResponseSummary(),
                "dailyUsageBuckets": .null,
                "threadUsage": matchingThread ?? .null,
            ])
        }
        let response = try await execute(path: "wham/profiles/me")
        guard case let .object(root) = try Self.camelCaseJSON(response.body),
              case let .object(stats)? = root["stats"]
        else { throw RateLimitError.invalidPayload }
        var summary = stats
        let buckets = summary.removeValue(forKey: "dailyUsageBuckets")
        return .object([
            "summary": .object(summary),
            "dailyUsageBuckets": buckets ?? .null,
        ])
    }

    private static func emptyThreadUsageResponse() -> CodexJSONValue {
        .object([
            "summary": emptyThreadUsageResponseSummary(),
            "dailyUsageBuckets": .null,
            "threadUsage": .null,
        ])
    }

    private static func emptyThreadUsageResponseSummary() -> CodexJSONValue {
        .object([
            "lifetimeTokens": .null,
            "peakDailyTokens": .null,
            "longestRunningTurnSec": .null,
            "currentStreakDays": .null,
            "longestStreakDays": .null,
        ])
    }

    public func readWorkspaceMessages() async throws -> CodexJSONValue {
        let response: CodexDesktopNetworkTransportResponse
        do {
            response = try await execute(
                path: "wham/workspace-messages",
                extraHeaders: ["Cache-Control": "no-store"]
            )
        } catch RateLimitError.http(404) {
            return .object([
                "featureEnabled": .bool(false),
                "messages": .array([]),
            ])
        }
        guard let root = try JSONSerialization.jsonObject(
            with: response.body
        ) as? [String: Any],
              let messages = root["messages"] as? [[String: Any]]
        else { throw RateLimitError.invalidPayload }
        let mapped = try messages.map(Self.workspaceMessage)
        return .object([
            "featureEnabled": .bool(true),
            "messages": .array(mapped),
        ])
    }

    public func consumeRateLimitResetCredit(
        idempotencyKey: String,
        creditID: String?
    ) async throws -> CodexJSONValue {
        var body: [String: Any] = ["redeem_request_id": idempotencyKey]
        if let creditID { body["credit_id"] = creditID }
        let response = try await execute(
            path: "wham/rate-limit-reset-credits/consume",
            method: "POST",
            body: try JSONSerialization.data(withJSONObject: body)
        )
        guard case let .object(root) = try Self.camelCaseJSON(response.body),
              case let .string(code)? = root["code"]
        else { throw RateLimitError.invalidPayload }
        let outcome: String
        switch code {
        case "reset": outcome = "reset"
        case "nothing_to_reset": outcome = "nothingToReset"
        case "no_credit": outcome = "noCredit"
        case "already_redeemed": outcome = "alreadyRedeemed"
        default: throw RateLimitError.invalidPayload
        }
        return .object(["outcome": .string(outcome)])
    }

    public func sendAddCreditsNudgeEmail(
        creditType: String
    ) async throws -> CodexJSONValue {
        do {
            _ = try await execute(
                path: "wham/accounts/send_add_credits_nudge_email",
                method: "POST",
                body: try JSONSerialization.data(
                    withJSONObject: ["credit_type": creditType]
                )
            )
            return .object(["status": .string("sent")])
        } catch RateLimitError.http(429) {
            return .object(["status": .string("cooldown_active")])
        }
    }

    public enum RateLimitError: Error, Equatable { case signedOut, http(Int), invalidPayload }

    private static func threadUsagePath(for baseURL: URL) -> String {
        baseURL.path.contains("/backend-api")
            ? "wham/usage/thread_usage/query"
            : "api/codex/usage/thread_usage/query"
    }

    private func execute(
        path: String,
        method: String = "GET",
        extraHeaders: [String: String] = [:],
        body: Data? = nil
    ) async throws -> CodexDesktopNetworkTransportResponse {
        guard let credentials = credentialsProvider()
        else { throw RateLimitError.signedOut }
        var headers = [
            "Authorization": "Bearer \(credentials.accessToken)",
            "Accept": "application/json",
        ]
        if body != nil { headers["Content-Type"] = "application/json" }
        if let accountID = credentials.accountID {
            headers["chatgpt-account-id"] = accountID
        }
        headers.merge(extraHeaders) { _, new in new }
        let response = try await transport.execute(
            CodexDesktopNetworkTransportRequest(
                url: baseURL.appendingPathComponent(path),
                method: method,
                headers: headers,
                body: body
            )
        )
        guard (200..<300).contains(response.status)
        else { throw RateLimitError.http(response.status) }
        return response
    }

    private static func mapPayload(_ p: [String: Any]) -> CodexJSONValue {
        func n(_ x: Any?) -> CodexJSONValue {
            guard let v = x as? NSNumber else { return .null }
            let d = v.doubleValue
            return d.rounded() == d ? .integer(v.int64Value) : .number(d)
        }
        func s(_ x: Any?) -> CodexJSONValue { (x as? String).map(CodexJSONValue.string) ?? .null }
        func window(_ x: Any?) -> CodexJSONValue {
            guard let d = x as? [String: Any] else { return .null }
            let secs = (d["limit_window_seconds"] as? NSNumber)?.int64Value
            return .object(["usedPercent": n(d["used_percent"]), "windowDurationMins": secs.map { .integer(($0 + 59) / 60) } ?? .null, "resetsAt": n(d["reset_at"])])
        }
        func snapshot(_ limitID: String?, _ limitName: String?, _ d: [String: Any]?) -> CodexJSONValue {
            let r = d?["rate_limit"] as? [String: Any]
            let spend = d?["spend_control"] as? [String: Any]
            let individual = spend?["individual_limit"] as? [String: Any]
            let reached = (d?["rate_limit_reached_type"] as? [String: Any])?["type"]
            var o: [String: CodexJSONValue] = ["limitId": s(limitID), "limitName": s(limitName), "primary": window(r?["primary_window"]), "secondary": window(r?["secondary_window"]), "planType": s(d?["plan_type"] ?? p["plan_type"]), "rateLimitReachedType": s(reached), "spendControlReached": (spend?["reached"] as? Bool).map(CodexJSONValue.bool) ?? .null]
            if let c = d?["credits"] as? [String: Any] { o["credits"] = .object(["hasCredits": (c["has_credits"] as? Bool).map(CodexJSONValue.bool) ?? .null, "unlimited": (c["unlimited"] as? Bool).map(CodexJSONValue.bool) ?? .null, "balance": s(c["balance"])]) }
            if let i = individual { o["individualLimit"] = .object(["limit": s(i["limit"]), "used": s(i["used"]), "remainingPercent": n(i["remaining_percent"]), "resetsAt": n(i["reset_at"])]) }
            return .object(o)
        }
        let primary = snapshot("codex", nil, p)
        var by: [String: CodexJSONValue] = ["codex": primary]
        if let additional = p["additional_rate_limits"] as? [[String: Any]] { for d in additional { let id = d["metered_feature"] as? String ?? "unknown"; by[id] = snapshot(id, d["limit_name"] as? String, d) } }
        var out: [String: CodexJSONValue] = ["rateLimits": primary, "rateLimitsByLimitId": .object(by)]
        if let credits = p["rate_limit_reset_credits"] as? [String: Any] { out["rateLimitResetCredits"] = .object(["availableCount": n(credits["available_count"])]) }
        return .object(out)
    }

    private static func camelCaseJSON(_ data: Data) throws -> CodexJSONValue {
        guard let raw = try? JSONSerialization.jsonObject(with: data)
        else { throw RateLimitError.invalidPayload }
        func camel(_ key: String) -> String {
            let parts = key.split(separator: "_")
            guard let first = parts.first else { return key }
            return String(first) + parts.dropFirst().map {
                $0.prefix(1).uppercased() + $0.dropFirst()
            }.joined()
        }
        func convert(_ value: Any) -> CodexJSONValue {
            if value is NSNull { return .null }
            if let b = value as? Bool { return .bool(b) }
            if let n = value as? NSNumber {
                let d = n.doubleValue
                return d.rounded() == d ? .integer(n.int64Value) : .number(d)
            }
            if let s = value as? String { return .string(s) }
            if let a = value as? [Any] { return .array(a.map(convert)) }
            if let o = value as? [String: Any] {
                return .object(
                    o.reduce(into: [String: CodexJSONValue]()) {
                        $0[camel($1.key)] = convert($1.value)
                    }
                )
            }
            return .null
        }
        return convert(raw)
    }

    private static func workspaceMessage(
        _ raw: [String: Any]
    ) throws -> CodexJSONValue {
        guard let messageID = raw["message_id"] as? String,
              !messageID.isEmpty,
              let messageBody = raw["message_body"] as? String,
              let backendType = raw["message_type"] as? String
        else { throw RateLimitError.invalidPayload }
        let messageType: String
        switch backendType {
        case "headline", "announcement":
            messageType = backendType
        default:
            messageType = "unknown"
        }
        return .object([
            "messageId": .string(messageID),
            "messageType": .string(messageType),
            "messageBody": .string(messageBody),
            "createdAt": try workspaceMessageTimestamp(
                raw["created_at"]
            ),
            "archivedAt": try workspaceMessageTimestamp(
                raw["archived_at"]
            ),
        ])
    }

    private static func workspaceMessageTimestamp(
        _ raw: Any?
    ) throws -> CodexJSONValue {
        guard let raw, !(raw is NSNull) else { return .null }
        guard let timestamp = raw as? String else {
            throw RateLimitError.invalidPayload
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [
            .withInternetDateTime,
            .withFractionalSeconds,
        ]
        let date = formatter.date(from: timestamp) ?? {
            formatter.formatOptions = [.withInternetDateTime]
            return formatter.date(from: timestamp)
        }()
        guard let date else { throw RateLimitError.invalidPayload }
        return .integer(Int64(date.timeIntervalSince1970))
    }
}
