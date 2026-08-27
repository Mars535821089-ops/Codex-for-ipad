import Foundation
import Testing

@testable import CodexPadApplication
@testable import CodexPadProtocolBridge

@Test @MainActor
func accountStoreDerivesDesktopSurfacePlanFromAccessToken() throws {
    let tokens = try CodexChatGPTTokens(
        idToken: try jwt([
            "https://api.openai.com/auth": [
                "chatgpt_account_id": "account-1",
                "chatgpt_plan_type": "enterprise",
            ]
        ]),
        accessToken: try jwt([
            "https://api.openai.com/auth": [
                "chatgpt_plan_type": "plus"
            ]
        ]),
        refreshToken: "SAMPLE_REFRESH"
    )

    #expect(CodexAccountStore.planType(from: tokens) == .plus)
}

@Test @MainActor
func accountStoreDerivesHistorySnapshotPrincipalUserIDFromIDToken() throws {
    let idToken = try jwt([
        "sub": "user-123",
        "email": "mars@example.test",
    ])

    #expect(CodexAccountStore.userID(fromIDToken: idToken) == "user-123")
    #expect(
        CodexAccountStore.userID(
            fromIDToken: try jwt(["sub": "   "])
        ) == nil
    )
    #expect(CodexAccountStore.userID(fromIDToken: "not-a-jwt") == nil)
}

private func jwt(_ claims: [String: Any]) throws -> String {
    let data = try JSONSerialization.data(withJSONObject: claims)
    let payload = data
        .base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
    return "header.\(payload).signature"
}
