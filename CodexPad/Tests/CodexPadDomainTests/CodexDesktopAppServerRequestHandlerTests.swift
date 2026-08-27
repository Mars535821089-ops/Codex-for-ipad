import Foundation
import Testing

@testable import CodexPadApplication
@testable import CodexPadDomain

@Test
@MainActor
func desktopAppServerRequestHandlerReadsWholeUnixSeconds() async throws {
    let handler = CodexDesktopAppServerRequestHandler(
        refreshCredentials: { _ in
            throw TestFailure.unexpectedRefresh
        },
        planType: { nil },
        attestationProvider: StaticAttestationProvider(token: nil),
        now: { Date(timeIntervalSince1970: 1_739_999_999.875) }
    )

    let response = try await handler.handle(
        method: "currentTime/read",
        params: .object(["threadId": .string("thread-clock")])
    )

    #expect(
        response == .object(["currentTimeAt": .integer(1_739_999_999)])
    )
}

@Test(arguments: [
    CodexJSONValue?.none,
    .object([:]),
    .object(["threadId": .string("")]),
    .object(["threadId": .integer(7)]),
])
@MainActor
func desktopAppServerRequestHandlerRejectsInvalidCurrentTimeParams(
    params: CodexJSONValue?
) async {
    let handler = makeHandler()

    await #expect(
        throws: CodexDesktopAppServerRequestError.invalidParams(
            method: "currentTime/read"
        )
    ) {
        try await handler.handle(
            method: "currentTime/read",
            params: params
        )
    }
}

@Test
@MainActor
func desktopAppServerRequestHandlerRefreshesRequestedAccount() async throws {
    var requestedAccountID: String?
    let handler = CodexDesktopAppServerRequestHandler(
        refreshCredentials: { previousAccountID in
            requestedAccountID = previousAccountID
            return CodexOfficialCredentials(
                accessToken: "fresh-access-token",
                accountID: "account-after-refresh"
            )
        },
        planType: { "team" },
        attestationProvider: StaticAttestationProvider(token: nil)
    )

    let response = try await handler.handle(
        method: "account/chatgptAuthTokens/refresh",
        params: .object([
            "reason": .string("unauthorized"),
            "previousAccountId": .string("account-before-refresh"),
        ])
    )

    #expect(requestedAccountID == "account-before-refresh")
    #expect(
        response == .object([
            "accessToken": .string("fresh-access-token"),
            "chatgptAccountId": .string("account-after-refresh"),
            "chatgptPlanType": .string("team"),
        ])
    )
}

@Test
@MainActor
func desktopAppServerRequestHandlerPreservesNullRefreshHintAndPlan()
    async throws
{
    var refreshWasCalled = false
    let handler = CodexDesktopAppServerRequestHandler(
        refreshCredentials: { previousAccountID in
            #expect(previousAccountID == nil)
            refreshWasCalled = true
            return CodexOfficialCredentials(
                accessToken: "token",
                accountID: "account"
            )
        },
        planType: { nil },
        attestationProvider: StaticAttestationProvider(token: nil)
    )

    let response = try await handler.handle(
        method: "account/chatgptAuthTokens/refresh",
        params: .object([
            "reason": .string("unauthorized"),
            "previousAccountId": .null,
        ])
    )

    #expect(refreshWasCalled)
    #expect(
        response == .object([
            "accessToken": .string("token"),
            "chatgptAccountId": .string("account"),
            "chatgptPlanType": .null,
        ])
    )
}

@Test(arguments: [
    CodexJSONValue?.none,
    .object([:]),
    .object(["reason": .string("manual")]),
    .object([
        "reason": .string("unauthorized"),
        "previousAccountId": .integer(4),
    ]),
])
@MainActor
func desktopAppServerRequestHandlerRejectsInvalidRefreshParams(
    params: CodexJSONValue?
) async {
    let handler = makeHandler()

    await #expect(
        throws: CodexDesktopAppServerRequestError.invalidParams(
            method: "account/chatgptAuthTokens/refresh"
        )
    ) {
        try await handler.handle(
            method: "account/chatgptAuthTokens/refresh",
            params: params
        )
    }
}

@Test
@MainActor
func desktopAppServerRequestHandlerRejectsRefreshWithoutAccountID() async {
    let handler = CodexDesktopAppServerRequestHandler(
        refreshCredentials: { _ in
            CodexOfficialCredentials(
                accessToken: "token-without-account",
                accountID: nil
            )
        },
        planType: { "pro" },
        attestationProvider: StaticAttestationProvider(token: nil)
    )

    await #expect(
        throws: CodexDesktopAppServerRequestError.missingAccountID
    ) {
        try await handler.handle(
            method: "account/chatgptAuthTokens/refresh",
            params: .object(["reason": .string("unauthorized")])
        )
    }
}

@Test
@MainActor
func desktopAppServerRequestHandlerReturnsRealAttestationToken() async throws {
    let handler = CodexDesktopAppServerRequestHandler(
        refreshCredentials: { _ in
            throw TestFailure.unexpectedRefresh
        },
        planType: { nil },
        attestationProvider: StaticAttestationProvider(
            token: "opaque-device-token"
        )
    )

    let response = try await handler.handle(
        method: "attestation/generate",
        params: .object([:])
    )

    #expect(
        response == .object(["token": .string("opaque-device-token")])
    )
}

@Test(arguments: [String?.none, "", "   "])
@MainActor
func desktopAppServerRequestHandlerRejectsUnavailableAttestation(
    token: String?
) async {
    let handler = CodexDesktopAppServerRequestHandler(
        refreshCredentials: { _ in
            throw TestFailure.unexpectedRefresh
        },
        planType: { nil },
        attestationProvider: StaticAttestationProvider(token: token)
    )

    await #expect(
        throws: CodexDesktopAppServerRequestError.attestationUnavailable
    ) {
        try await handler.handle(
            method: "attestation/generate",
            params: .object([:])
        )
    }
}

@Test
@MainActor
func desktopAppServerRequestHandlerLeavesUnknownRequestsUnconsumed()
    async throws
{
    let response = try await makeHandler().handle(
        method: "mcpServer/elicitation/request",
        params: .object(["threadId": .string("thread-1")])
    )

    #expect(response == nil)
}

@MainActor
private func makeHandler() -> CodexDesktopAppServerRequestHandler {
    CodexDesktopAppServerRequestHandler(
        refreshCredentials: { _ in
            throw TestFailure.unexpectedRefresh
        },
        planType: { nil },
        attestationProvider: StaticAttestationProvider(token: nil),
        now: { Date(timeIntervalSince1970: 0) }
    )
}

private struct StaticAttestationProvider:
    CodexDesktopDeviceCheckTokenProviding
{
    let tokenValue: String?

    init(token: String?) {
        tokenValue = token
    }

    func token() async -> String? {
        tokenValue
    }
}

private enum TestFailure: Swift.Error {
    case unexpectedRefresh
}
