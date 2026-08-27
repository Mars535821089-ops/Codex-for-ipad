import Foundation
import Testing
@testable import CodexPadProtocolBridge

@Test
func officialDeviceLoginConstantsMatchImportedCodexSource() {
    #expect(
        CodexChatGPTAuthClient.clientID
            == "app_EMoamEEZ73f0CkXaXp7hrann"
    )
    #expect(
        CodexChatGPTAuthClient.issuer.absoluteString
            == "https://auth.openai.com"
    )
}

@Test
func authorizationCodeExchangeUsesExactFormEncoding() throws {
    let data = CodexChatGPTAuthClient.formEncoded([
        ("grant_type", "authorization_code"),
        ("redirect_uri", "https://auth.openai.com/deviceauth/callback"),
        ("code_verifier", "a+b/c="),
    ])
    let text = try #require(String(data: data, encoding: .utf8))
    #expect(text.contains("grant_type=authorization_code"))
    #expect(
        text.contains(
            "redirect_uri=https%3A%2F%2Fauth.openai.com%2Fdeviceauth%2Fcallback"
        )
    )
    #expect(text.contains("code_verifier=a%2Bb%2Fc%3D"))
}

@Test
func tokenDescriptionNeverPrintsCredentials() throws {
    let payload = Data(
        #"{"https://api.openai.com/auth":{"chatgpt_account_id":"account-1"}}"#.utf8
    )
    let encodedPayload = payload.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
    let token = "header.\(encodedPayload).signature"
    let tokens = try CodexChatGPTTokens(
        idToken: token,
        accessToken: "access-secret",
        refreshToken: "refresh-secret"
    )
    #expect(tokens.accountID == "account-1")
    #expect(!tokens.description.contains("access-secret"))
    #expect(!tokens.description.contains("refresh-secret"))
    #expect(tokens.description.contains("<redacted>"))
}
