import CodexPadApplication
import CodexPadProtocolBridge
import Foundation
import Testing

private actor MCPAppSandboxNativeDeliveryRecorder {
    private(set) var deliveries:
        [CodexDesktopMCPAppSandboxNativeHostDelivery] = []

    func send(
        _ delivery: CodexDesktopMCPAppSandboxNativeHostDelivery
    ) {
        deliveries.append(delivery)
    }
}

private enum MCPAppSandboxNativeTestError: Error {
    case sendFailed
}

private func makeMCPAppSandboxSource(
    initID: String,
    sandboxID: String
) throws -> CodexDesktopMCPAppSandboxSource {
    try CodexDesktopMCPAppSandboxSource(
        url: #require(
            URL(
                string:
                    "https://widget.web-sandbox.oaiusercontent.com/?app=skybridge&locale=en-US&deviceType=desktop&unsafeSkipTargetOriginCheck=true#initId=\(initID)"
            )
        ),
        sandboxID: sandboxID
    )
}

private func makeMCPAppSandboxPortIdentities(
    count: Int = 13
) -> [CodexDesktopMCPAppSandboxNativePortIdentity] {
    (0 ..< count).map {
        CodexDesktopMCPAppSandboxNativePortIdentity(
            rawValue: "native-port-\($0)"
        )
    }
}

@Test
func mcpAppSandboxNativeCoordinatorDeliversAnIdentityLeaseToExactOwner()
    async throws
{
    let recorder = MCPAppSandboxNativeDeliveryRecorder()
    let coordinator = CodexDesktopMCPAppSandboxNativeCoordinator {
        delivery in
        await recorder.send(delivery)
    }
    try await coordinator.registerOwner(
        CodexDesktopMCPAppSandboxNativeOwner(
            ownerID: "owner-1",
            appSessionID: "app-session-1",
            targetOrigin: "app://-",
            navigationID: "owner-navigation-1"
        )
    )
    let source = try makeMCPAppSandboxSource(
        initID: "init-1",
        sandboxID: "sandbox-1"
    )
    try await coordinator.registerGuest(
        CodexDesktopMCPAppSandboxNativeGuest(
            guestID: "guest-1",
            ownerID: "owner-1",
            navigationID: "guest-navigation-1",
            source: source,
            skybridgeCacheState: .warm
        )
    )

    let portIdentities = makeMCPAppSandboxPortIdentities()
    let delivery = try await coordinator.receiveGuestMessage(
        guestID: "guest-1",
        appSessionID: "app-session-1",
        targetOrigin: "app://-",
        envelope: CodexDesktopMCPAppSandboxGuestEnvelope(
            origin: source.origin,
            initID: source.initID,
            portNames:
                CodexDesktopMCPAppSandboxProtocol.requiredPortNames
        ),
        portIdentities: portIdentities
    )

    #expect(delivery.ownerID == "owner-1")
    #expect(delivery.appSessionID == "app-session-1")
    #expect(delivery.targetOrigin == "app://-")
    #expect(
        delivery.channel
            == CodexDesktopMCPAppSandboxProtocol.hostMessageChannel
    )
    #expect(delivery.envelope.sandboxID == "sandbox-1")
    #expect(delivery.envelope.skybridgeCacheState == .warm)
    #expect(
        delivery.portLease.transferDisposition
            == .requiresPlatformMessagePortBinding
    )
    #expect(delivery.portLease.portNames
        == CodexDesktopMCPAppSandboxProtocol.requiredPortNames)
    #expect(delivery.portLease.namedPortIdentities
        == Array(portIdentities.dropLast()))
    #expect(delivery.portLease.replyPortIdentity
        == portIdentities.last)
    #expect(
        await coordinator.isPortLeaseActive(
            delivery.portLease.leaseID
        )
    )
    #expect(await recorder.deliveries == [delivery])

    await coordinator.releasePortLease(delivery.portLease.leaseID)
    #expect(
        await !coordinator.isPortLeaseActive(
            delivery.portLease.leaseID
        )
    )
}

@Test
func mcpAppSandboxNativeCoordinatorRejectsCrossSessionAndBadPorts()
    async throws
{
    let recorder = MCPAppSandboxNativeDeliveryRecorder()
    let coordinator = CodexDesktopMCPAppSandboxNativeCoordinator {
        delivery in
        await recorder.send(delivery)
    }
    try await coordinator.registerOwner(
        CodexDesktopMCPAppSandboxNativeOwner(
            ownerID: "owner-1",
            appSessionID: "app-session-1",
            targetOrigin: "app://-",
            navigationID: "owner-navigation-1"
        )
    )
    let source = try makeMCPAppSandboxSource(
        initID: "init-1",
        sandboxID: "sandbox-1"
    )
    try await coordinator.registerGuest(
        CodexDesktopMCPAppSandboxNativeGuest(
            guestID: "guest-1",
            ownerID: "owner-1",
            navigationID: "guest-navigation-1",
            source: source,
            skybridgeCacheState: nil
        )
    )
    let envelope = CodexDesktopMCPAppSandboxGuestEnvelope(
        origin: source.origin,
        initID: source.initID,
        portNames:
            CodexDesktopMCPAppSandboxProtocol.requiredPortNames
    )

    await #expect(
        throws:
            CodexDesktopMCPAppSandboxError.appSessionMismatch
    ) {
        try await coordinator.receiveGuestMessage(
            guestID: "guest-1",
            appSessionID: "other-session",
            targetOrigin: "app://-",
            envelope: envelope,
            portIdentities: makeMCPAppSandboxPortIdentities()
        )
    }
    await #expect(
        throws:
            CodexDesktopMCPAppSandboxError.targetOriginMismatch
    ) {
        try await coordinator.receiveGuestMessage(
            guestID: "guest-1",
            appSessionID: "app-session-1",
            targetOrigin: "https://renderer.example",
            envelope: envelope,
            portIdentities: makeMCPAppSandboxPortIdentities()
        )
    }
    await #expect(
        throws:
            CodexDesktopMCPAppSandboxError.originMismatch
    ) {
        try await coordinator.receiveGuestMessage(
            guestID: "guest-1",
            appSessionID: "app-session-1",
            targetOrigin: "app://-",
            envelope: CodexDesktopMCPAppSandboxGuestEnvelope(
                origin:
                    "https://other.web-sandbox.oaiusercontent.com",
                initID: source.initID,
                portNames:
                    CodexDesktopMCPAppSandboxProtocol
                    .requiredPortNames
            ),
            portIdentities: makeMCPAppSandboxPortIdentities()
        )
    }
    await #expect(
        throws:
            CodexDesktopMCPAppSandboxError.portCountMismatch
    ) {
        try await coordinator.receiveGuestMessage(
            guestID: "guest-1",
            appSessionID: "app-session-1",
            targetOrigin: "app://-",
            envelope: envelope,
            portIdentities:
                makeMCPAppSandboxPortIdentities(count: 12)
        )
    }

    var duplicatePorts = makeMCPAppSandboxPortIdentities()
    duplicatePorts[12] = duplicatePorts[0]
    await #expect(
        throws:
            CodexDesktopMCPAppSandboxNativeCoordinatorError
                .duplicatePortIdentity
    ) {
        try await coordinator.receiveGuestMessage(
            guestID: "guest-1",
            appSessionID: "app-session-1",
            targetOrigin: "app://-",
            envelope: envelope,
            portIdentities: duplicatePorts
        )
    }
    #expect(await recorder.deliveries.isEmpty)
    #expect(await coordinator.activePortLeaseCount == 0)
}

@Test
func mcpAppSandboxNativeCoordinatorTearsDownMatchingNavigations()
    async throws
{
    let recorder = MCPAppSandboxNativeDeliveryRecorder()
    let coordinator = CodexDesktopMCPAppSandboxNativeCoordinator {
        delivery in
        await recorder.send(delivery)
    }
    try await coordinator.registerOwner(
        CodexDesktopMCPAppSandboxNativeOwner(
            ownerID: "owner-1",
            appSessionID: "app-session-1",
            targetOrigin: "app://-",
            navigationID: "owner-navigation-1"
        )
    )
    let source = try makeMCPAppSandboxSource(
        initID: "init-1",
        sandboxID: "sandbox-1"
    )
    try await coordinator.registerGuest(
        CodexDesktopMCPAppSandboxNativeGuest(
            guestID: "guest-1",
            ownerID: "owner-1",
            navigationID: "guest-navigation-1",
            source: source,
            skybridgeCacheState: .cold
        )
    )
    let envelope = CodexDesktopMCPAppSandboxGuestEnvelope(
        origin: source.origin,
        initID: source.initID,
        portNames:
            CodexDesktopMCPAppSandboxProtocol.requiredPortNames
    )
    let delivery = try await coordinator.receiveGuestMessage(
        guestID: "guest-1",
        appSessionID: "app-session-1",
        targetOrigin: "app://-",
        envelope: envelope,
        portIdentities: makeMCPAppSandboxPortIdentities()
    )

    await coordinator.teardownGuestNavigation(
        guestID: "guest-1",
        navigationID: "stale-navigation"
    )
    #expect(
        await coordinator.isPortLeaseActive(
            delivery.portLease.leaseID
        )
    )

    await coordinator.teardownGuestNavigation(
        guestID: "guest-1",
        navigationID: "guest-navigation-1"
    )
    #expect(
        await !coordinator.isPortLeaseActive(
            delivery.portLease.leaseID
        )
    )
    await #expect(
        throws:
            CodexDesktopMCPAppSandboxNativeCoordinatorError
                .unknownGuest
    ) {
        try await coordinator.receiveGuestMessage(
            guestID: "guest-1",
            appSessionID: "app-session-1",
            targetOrigin: "app://-",
            envelope: envelope,
            portIdentities: makeMCPAppSandboxPortIdentities()
        )
    }

    try await coordinator.registerGuest(
        CodexDesktopMCPAppSandboxNativeGuest(
            guestID: "guest-2",
            ownerID: "owner-1",
            navigationID: "guest-navigation-2",
            source: try makeMCPAppSandboxSource(
                initID: "init-2",
                sandboxID: "sandbox-2"
            ),
            skybridgeCacheState: .warming
        )
    )
    await coordinator.teardownOwnerNavigation(
        ownerID: "owner-1",
        navigationID: "owner-navigation-1"
    )
    #expect(await coordinator.registeredOwnerCount == 0)
    #expect(await coordinator.registeredGuestCount == 0)
}

@Test
func mcpAppSandboxNativeCoordinatorReleasesLeaseWhenSendFails()
    async throws
{
    let coordinator = CodexDesktopMCPAppSandboxNativeCoordinator {
        _ in
        throw MCPAppSandboxNativeTestError.sendFailed
    }
    try await coordinator.registerOwner(
        CodexDesktopMCPAppSandboxNativeOwner(
            ownerID: "owner-1",
            appSessionID: "app-session-1",
            targetOrigin: "app://-",
            navigationID: "owner-navigation-1"
        )
    )
    let source = try makeMCPAppSandboxSource(
        initID: "init-1",
        sandboxID: "sandbox-1"
    )
    try await coordinator.registerGuest(
        CodexDesktopMCPAppSandboxNativeGuest(
            guestID: "guest-1",
            ownerID: "owner-1",
            navigationID: "guest-navigation-1",
            source: source,
            skybridgeCacheState: nil
        )
    )

    await #expect(throws: MCPAppSandboxNativeTestError.sendFailed) {
        try await coordinator.receiveGuestMessage(
            guestID: "guest-1",
            appSessionID: "app-session-1",
            targetOrigin: "app://-",
            envelope: CodexDesktopMCPAppSandboxGuestEnvelope(
                origin: source.origin,
                initID: source.initID,
                portNames:
                    CodexDesktopMCPAppSandboxProtocol
                    .requiredPortNames
            ),
            portIdentities: makeMCPAppSandboxPortIdentities()
        )
    }
    #expect(await coordinator.activePortLeaseCount == 0)
}
