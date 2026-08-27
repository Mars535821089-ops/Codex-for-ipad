import Foundation
import Testing

@testable import CodexPadApplication
@testable import CodexPadDomain
@testable import CodexPadProtocolBridge

private actor MCPOAuthSessionDriverProbe:
    CodexDesktopMCPOAuthSessionDriving
{
    struct Invocation: Equatable, Sendable {
        let name: String
        let threadID: String?
        let scopes: [String]?
        let timeoutSeconds: Int64?
    }

    private(set) var invocation: Invocation?
    private var completion:
        (@Sendable (CodexDesktopMCPOAuthSessionCompletion) async -> Void)?

    func startMCPOAuthLogin(
        name: String,
        threadID: String?,
        scopes: [String]?,
        timeoutSeconds: Int64?,
        completion:
            @escaping @Sendable
            (CodexDesktopMCPOAuthSessionCompletion) async -> Void
    ) async throws -> CodexDesktopMCPOAuthSessionStart {
        invocation = Invocation(
            name: name,
            threadID: threadID,
            scopes: scopes,
            timeoutSeconds: timeoutSeconds
        )
        self.completion = completion
        return CodexDesktopMCPOAuthSessionStart(
            authorizationURL: "https://mcp.example.test/authorize"
        )
    }

    func finish(_ result: CodexDesktopMCPOAuthSessionCompletion) async {
        await completion?(result)
    }
}

private actor MCPNotificationRecorder {
    private(set) var messages: [CodexDesktopHostMessage] = []
    func append(_ message: CodexDesktopHostMessage) {
        messages.append(message)
    }
}

@Test
func mcpOAuthCoordinatorReturnsURLAndSendsOfficialSuccessNotification()
    async throws
{
    let driver = MCPOAuthSessionDriverProbe()
    let recorder = MCPNotificationRecorder()
    let coordinator = CodexDesktopMCPOAuthCoordinator(
        driver: driver,
        sendNotification: { message in
            await recorder.append(message)
        }
    )

    let result = try await coordinator.loginMCPServer(
        hostID: "host-7",
        name: "calendar",
        threadID: "thread-9",
        scopes: ["calendar.read"],
        timeoutSeconds: 30
    )
    #expect(
        result.authorizationURL
            == "https://mcp.example.test/authorize"
    )
    #expect(
        await driver.invocation
            == .init(
                name: "calendar",
                threadID: "thread-9",
                scopes: ["calendar.read"],
                timeoutSeconds: 30
            )
    )

    await driver.finish(.succeeded)
    #expect(
        await recorder.messages
            == [
                .mcpNotification(
                    hostID: "host-7",
                    method: "mcpServer/oauthLogin/completed",
                    params: .object([
                        "name": .string("calendar"),
                        "threadId": .string("thread-9"),
                        "success": .bool(true),
                    ]),
                    metadata: [:]
                )
            ]
    )
}

@Test
func mcpOAuthCoordinatorPreservesFailureAndAbsentThread()
    async throws
{
    let driver = MCPOAuthSessionDriverProbe()
    let recorder = MCPNotificationRecorder()
    let coordinator = CodexDesktopMCPOAuthCoordinator(
        driver: driver,
        sendNotification: { message in
            await recorder.append(message)
        }
    )

    _ = try await coordinator.loginMCPServer(
        hostID: "host-8",
        name: "documents",
        threadID: nil,
        scopes: nil,
        timeoutSeconds: nil
    )
    await driver.finish(.failed("authorization denied"))

    #expect(
        await recorder.messages
            == [
                .mcpNotification(
                    hostID: "host-8",
                    method: "mcpServer/oauthLogin/completed",
                    params: .object([
                        "name": .string("documents"),
                        "threadId": .null,
                        "success": .bool(false),
                        "error": .string("authorization denied"),
                    ]),
                    metadata: [:]
                )
            ]
    )
}
