import CodexPadDomain
import Foundation
import Testing

@testable import CodexPadProtocolBridge

@Test
func desktopBridgeInstallsReleasedWebMCPAndSandboxHostContracts() throws {
    let script = try CodexDesktopBridgeScript.make(
        bootstrap: CodexDesktopBridgeBootstrap(
            preloadStartedAtMs: 1_234,
            systemThemeVariant: "dark",
            initialSidebarBootstrap: .object([:]),
            sharedObjectSnapshot: [:],
            sentryInitOptions: .object([:]),
            buildFlavor: "prod",
            appSessionID: "session-mcp-app",
            usesOwlAppShell: true
        )
    )

    #expect(script.contains("__codexWebMcpModelContext"))
    #expect(script.contains("codexExecuteTool"))
    #expect(script.contains("codexGetTools"))
    #expect(script.contains("for (const modelContextOwner of [document, navigator])"))
    #expect(
        script.contains(
            #"Object.defineProperty(modelContextOwner, "modelContext""#
        )
    )
    #expect(
        script.contains(
            "codex_desktop:mcp-app-sandbox-guest-message"
        )
    )
    #expect(
        script.contains(
            "codex_desktop:mcp-app-sandbox-host-message"
        )
    )
    #expect(script.contains("message.targetOrigin !== window.location.origin"))
    #expect(script.contains("message.appSessionID !== bootstrap.appSessionID"))
}

@Test
func mcpAppSandboxSourceMatchesReleasedSkybridgeURLContract() throws {
    let source = try CodexDesktopMCPAppSandboxSource(
        url: #require(
            URL(
                string:
                    "codex-sandbox://web-sandbox.oaiusercontent.com/?app=skybridge&locale=en-US&deviceType=desktop&unsafeSkipTargetOriginCheck=true#initId=init_1"
            )
        ),
        sandboxID: "sandbox_1"
    )

    #expect(
        source.origin
            == "codex-sandbox://web-sandbox.oaiusercontent.com"
    )
    #expect(source.initID == "init_1")
    #expect(source.sandboxID == "sandbox_1")

    #expect(throws: CodexDesktopMCPAppSandboxError.invalidSourceURL) {
        try CodexDesktopMCPAppSandboxSource(
            url: #require(
                URL(
                    string:
                        "https://web-sandbox.oaiusercontent.com/?app=skybridge&locale=en-US&deviceType=mobile&unsafeSkipTargetOriginCheck=true#initId=init_1"
                )
            ),
            sandboxID: "sandbox_1"
        )
    }
    #expect(throws: CodexDesktopMCPAppSandboxError.invalidInitID) {
        try CodexDesktopMCPAppSandboxSource(
            url: #require(
                URL(
                    string:
                        "https://web-sandbox.oaiusercontent.com/?app=skybridge&locale=en-US&deviceType=desktop&unsafeSkipTargetOriginCheck=true#initId=bad%20id"
                )
            ),
            sandboxID: "sandbox_1"
        )
    }
}

@Test
func mcpAppSandboxRouterProducesExactIsolatedHostEnvelope() async throws {
    let source = try CodexDesktopMCPAppSandboxSource(
        url: #require(
            URL(
                string:
                    "https://widget.web-sandbox.oaiusercontent.com/?app=skybridge&locale=en-US&deviceType=desktop&unsafeSkipTargetOriginCheck=true#initId=init-1"
            )
        ),
        sandboxID: "sandbox-1"
    )
    let session = CodexDesktopMCPAppSandboxSession(
        appSessionID: "app-session-1",
        ownerID: "owner-1",
        guestID: "guest-1",
        targetOrigin: "app://-",
        source: source,
        skybridgeCacheState: .warm
    )
    let router = CodexDesktopMCPAppSandboxRouter()
    try await router.register(session)

    let guestEnvelope = CodexDesktopMCPAppSandboxGuestEnvelope(
        origin: source.origin,
        initID: source.initID,
        portNames: CodexDesktopMCPAppSandboxProtocol.requiredPortNames
    )
    let route = try await router.routeGuestMessage(
        guestID: "guest-1",
        envelope: guestEnvelope,
        transferredPortCount: guestEnvelope.portNames.count + 1
    )

    #expect(
        route.channel
            == "codex_desktop:mcp-app-sandbox-host-message"
    )
    #expect(route.appSessionID == "app-session-1")
    #expect(route.ownerID == "owner-1")
    #expect(route.targetOrigin == "app://-")
    #expect(route.expectedTransferredPortCount == 13)
    #expect(
        route.envelope
            == CodexDesktopMCPAppSandboxHostEnvelope(
                origin: source.origin,
                initID: source.initID,
                portNames:
                    CodexDesktopMCPAppSandboxProtocol.requiredPortNames,
                sandboxID: "sandbox-1",
                skybridgeCacheState: .warm
            )
    )

    await #expect(
        throws: CodexDesktopMCPAppSandboxError.originMismatch
    ) {
        try await router.routeGuestMessage(
            guestID: "guest-1",
            envelope: CodexDesktopMCPAppSandboxGuestEnvelope(
                origin: "https://other.web-sandbox.oaiusercontent.com",
                initID: source.initID,
                portNames:
                    CodexDesktopMCPAppSandboxProtocol.requiredPortNames
            ),
            transferredPortCount: 13
        )
    }
    await #expect(
        throws: CodexDesktopMCPAppSandboxError.unknownGuest
    ) {
        try await router.routeGuestMessage(
            guestID: "guest-2",
            envelope: guestEnvelope,
            transferredPortCount: 13
        )
    }
}

@Test
func mcpAppSandboxRejectsInvalidPortSetsAndCrossSessionHostDelivery()
    throws
{
    let invalidPorts =
        CodexDesktopMCPAppSandboxProtocol.requiredPortNames
            + ["navigate"]
    #expect(throws: CodexDesktopMCPAppSandboxError.invalidPortNames) {
        try CodexDesktopMCPAppSandboxProtocol.validatePortNames(
            invalidPorts
        )
    }

    let route = CodexDesktopMCPAppSandboxHostRoute(
        appSessionID: "app-session-1",
        ownerID: "owner-1",
        targetOrigin: "app://-",
        envelope: CodexDesktopMCPAppSandboxHostEnvelope(
            origin: "https://web-sandbox.oaiusercontent.com",
            initID: "init-1",
            portNames:
                CodexDesktopMCPAppSandboxProtocol.requiredPortNames,
            sandboxID: "sandbox-1",
            skybridgeCacheState: nil
        )
    )

    #expect(throws: CodexDesktopMCPAppSandboxError.appSessionMismatch) {
        try route.validateDelivery(
            appSessionID: "app-session-2",
            targetOrigin: "app://-"
        )
    }
    #expect(throws: CodexDesktopMCPAppSandboxError.targetOriginMismatch) {
        try route.validateDelivery(
            appSessionID: "app-session-1",
            targetOrigin: "https://renderer.example"
        )
    }
}

@Test
func mcpAppSandboxEnvelopesUseReleasedWireFieldNames() throws {
    let guestData = try JSONEncoder().encode(
        CodexDesktopMCPAppSandboxGuestEnvelope(
            origin: "https://web-sandbox.oaiusercontent.com",
            initID: "init-1",
            portNames: ["navigate"]
        )
    )
    let guest = try #require(
        JSONSerialization.jsonObject(with: guestData)
            as? [String: Any]
    )
    #expect(guest["type"] as? String == "init")
    #expect(guest["initId"] as? String == "init-1")
    #expect(guest["origin"] as? String
        == "https://web-sandbox.oaiusercontent.com")
    #expect(guest["portNames"] as? [String] == ["navigate"])
    #expect(guest["initID"] == nil)

    let hostData = try JSONEncoder().encode(
        CodexDesktopMCPAppSandboxHostEnvelope(
            origin: "https://web-sandbox.oaiusercontent.com",
            initID: "init-1",
            portNames: ["navigate"],
            sandboxID: "sandbox-1",
            skybridgeCacheState: .warming
        )
    )
    let host = try #require(
        JSONSerialization.jsonObject(with: hostData)
            as? [String: Any]
    )
    #expect(host["type"] as? String == "init")
    #expect(host["initId"] as? String == "init-1")
    #expect(host["sandboxId"] as? String == "sandbox-1")
    #expect(host["skybridgeCacheState"] as? String == "warming")
    #expect(host["initID"] == nil)
    #expect(host["sandboxID"] == nil)
}
