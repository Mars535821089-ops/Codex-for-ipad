import Foundation
import Testing
@testable import CodexPadProtocolBridge

@Test
func gitCredentialRoundTripsWithoutDisclosingSecretInDescription()
    throws
{
    let credential = CodexGitCredential(
        username: "git-user",
        password: "test-token"
    )

    let encoded = try JSONEncoder().encode(credential)
    let decoded = try JSONDecoder().decode(
        CodexGitCredential.self,
        from: encoded
    )

    #expect(decoded == credential)
    #expect(!credential.description.contains("test-token"))
    #expect(credential.description.contains("<redacted>"))
}
