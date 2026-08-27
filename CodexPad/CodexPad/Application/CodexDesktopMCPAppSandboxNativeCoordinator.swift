#if SWIFT_PACKAGE
    import CodexPadProtocolBridge
#endif
import Foundation

public enum CodexDesktopMCPAppSandboxNativeCoordinatorError:
    Error,
    Equatable,
    Sendable
{
    case invalidOwner
    case duplicateOwner
    case unknownOwner
    case ownerInvalidated
    case invalidGuest
    case duplicateGuest
    case unknownGuest
    case invalidPortIdentity
    case duplicatePortIdentity
    case portLeaseAlreadyActive
}

public struct CodexDesktopMCPAppSandboxNativeOwner:
    Equatable,
    Sendable
{
    public let ownerID: String
    public let appSessionID: String
    public let targetOrigin: String
    public let navigationID: String

    public init(
        ownerID: String,
        appSessionID: String,
        targetOrigin: String,
        navigationID: String
    ) {
        self.ownerID = ownerID
        self.appSessionID = appSessionID
        self.targetOrigin = targetOrigin
        self.navigationID = navigationID
    }
}

public struct CodexDesktopMCPAppSandboxNativeGuest:
    Equatable,
    Sendable
{
    public let guestID: String
    public let ownerID: String
    public let navigationID: String
    public let source: CodexDesktopMCPAppSandboxSource
    public let skybridgeCacheState:
        CodexDesktopMCPAppSandboxCacheState?

    public init(
        guestID: String,
        ownerID: String,
        navigationID: String,
        source: CodexDesktopMCPAppSandboxSource,
        skybridgeCacheState:
            CodexDesktopMCPAppSandboxCacheState?
    ) {
        self.guestID = guestID
        self.ownerID = ownerID
        self.navigationID = navigationID
        self.source = source
        self.skybridgeCacheState = skybridgeCacheState
    }
}

/// Stable identity supplied by the platform integration for one live
/// transferable MessagePort.
///
/// This value is an identity lease key, not a serialized MessagePort and not
/// evidence that WebKit transferred a port. The Surface/WebView integration
/// must retain and resolve the corresponding platform object while its lease
/// is active.
public struct CodexDesktopMCPAppSandboxNativePortIdentity:
    Hashable,
    Sendable
{
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

public enum CodexDesktopMCPAppSandboxNativePortTransferDisposition:
    Equatable,
    Sendable
{
    /// The native coordinator validated and leased identities. A platform
    /// adapter still has to bind them to live transferable MessagePorts.
    case requiresPlatformMessagePortBinding
}

public struct CodexDesktopMCPAppSandboxNativePortLease:
    Equatable,
    Sendable
{
    public let leaseID: String
    public let guestID: String
    public let ownerID: String
    public let portNames: [String]
    public let namedPortIdentities:
        [CodexDesktopMCPAppSandboxNativePortIdentity]
    public let replyPortIdentity:
        CodexDesktopMCPAppSandboxNativePortIdentity
    public let transferDisposition:
        CodexDesktopMCPAppSandboxNativePortTransferDisposition

    public var orderedPortIdentities:
        [CodexDesktopMCPAppSandboxNativePortIdentity]
    {
        namedPortIdentities + [replyPortIdentity]
    }

    public init(
        leaseID: String,
        guestID: String,
        ownerID: String,
        portNames: [String],
        namedPortIdentities:
            [CodexDesktopMCPAppSandboxNativePortIdentity],
        replyPortIdentity:
            CodexDesktopMCPAppSandboxNativePortIdentity
    ) {
        self.leaseID = leaseID
        self.guestID = guestID
        self.ownerID = ownerID
        self.portNames = portNames
        self.namedPortIdentities = namedPortIdentities
        self.replyPortIdentity = replyPortIdentity
        transferDisposition = .requiresPlatformMessagePortBinding
    }
}

/// A validated delivery instruction for the owner renderer.
///
/// `sendHostDelivery` receives this value only after the protocol router has
/// checked the registered guest, source, init ID, port names/count, app
/// session, and target origin. Its platform adapter must resolve
/// `portLease.orderedPortIdentities` to the original live MessagePorts and
/// preserve that order when posting the host envelope.
public struct CodexDesktopMCPAppSandboxNativeHostDelivery:
    Equatable,
    Sendable
{
    public let channel: String
    public let ownerID: String
    public let appSessionID: String
    public let targetOrigin: String
    public let envelope: CodexDesktopMCPAppSandboxHostEnvelope
    public let portLease: CodexDesktopMCPAppSandboxNativePortLease

    public init(
        channel: String,
        ownerID: String,
        appSessionID: String,
        targetOrigin: String,
        envelope: CodexDesktopMCPAppSandboxHostEnvelope,
        portLease: CodexDesktopMCPAppSandboxNativePortLease
    ) {
        self.channel = channel
        self.ownerID = ownerID
        self.appSessionID = appSessionID
        self.targetOrigin = targetOrigin
        self.envelope = envelope
        self.portLease = portLease
    }
}

/// Owns native MCP Apps sandbox registration, isolation, and port leases.
///
/// The coordinator deliberately does not model identity keys as transferred
/// MessagePorts. The injected sender is the explicit platform integration
/// point that must retain and resolve the live WebKit objects.
public actor CodexDesktopMCPAppSandboxNativeCoordinator {
    public typealias HostDeliverySender =
        @Sendable
        (CodexDesktopMCPAppSandboxNativeHostDelivery) async throws -> Void

    private struct PortLeaseRecord: Sendable {
        let lease: CodexDesktopMCPAppSandboxNativePortLease
    }

    private let router: CodexDesktopMCPAppSandboxRouter
    private let sendHostDelivery: HostDeliverySender
    private var owners:
        [String: CodexDesktopMCPAppSandboxNativeOwner] = [:]
    private var guests:
        [String: CodexDesktopMCPAppSandboxNativeGuest] = [:]
    private var guestIDsByOwner: [String: Set<String>] = [:]
    private var leasesByID: [String: PortLeaseRecord] = [:]
    private var leaseIDByGuest: [String: String] = [:]
    private var nextLeaseSequence = 1

    public init(
        router: CodexDesktopMCPAppSandboxRouter =
            CodexDesktopMCPAppSandboxRouter(),
        sendHostDelivery: @escaping HostDeliverySender
    ) {
        self.router = router
        self.sendHostDelivery = sendHostDelivery
    }

    public var registeredOwnerCount: Int {
        owners.count
    }

    public var registeredGuestCount: Int {
        guests.count
    }

    public var activePortLeaseCount: Int {
        leasesByID.count
    }

    public func registerOwner(
        _ owner: CodexDesktopMCPAppSandboxNativeOwner
    ) throws {
        guard !owner.ownerID.isEmpty,
              !owner.appSessionID.isEmpty,
              !owner.targetOrigin.isEmpty,
              !owner.navigationID.isEmpty
        else {
            throw CodexDesktopMCPAppSandboxNativeCoordinatorError
                .invalidOwner
        }
        guard owners[owner.ownerID] == nil else {
            throw CodexDesktopMCPAppSandboxNativeCoordinatorError
                .duplicateOwner
        }
        owners[owner.ownerID] = owner
        guestIDsByOwner[owner.ownerID] = []
    }

    public func registerGuest(
        _ guest: CodexDesktopMCPAppSandboxNativeGuest
    ) async throws {
        guard !guest.guestID.isEmpty,
              !guest.ownerID.isEmpty,
              !guest.navigationID.isEmpty
        else {
            throw CodexDesktopMCPAppSandboxNativeCoordinatorError
                .invalidGuest
        }
        guard guests[guest.guestID] == nil else {
            throw CodexDesktopMCPAppSandboxNativeCoordinatorError
                .duplicateGuest
        }
        guard let owner = owners[guest.ownerID] else {
            throw CodexDesktopMCPAppSandboxNativeCoordinatorError
                .unknownOwner
        }

        try await router.register(
            CodexDesktopMCPAppSandboxSession(
                appSessionID: owner.appSessionID,
                ownerID: owner.ownerID,
                guestID: guest.guestID,
                targetOrigin: owner.targetOrigin,
                source: guest.source,
                skybridgeCacheState: guest.skybridgeCacheState
            )
        )

        guard owners[owner.ownerID] == owner else {
            await router.unregister(guestID: guest.guestID)
            throw CodexDesktopMCPAppSandboxNativeCoordinatorError
                .ownerInvalidated
        }
        guests[guest.guestID] = guest
        guestIDsByOwner[owner.ownerID, default: []]
            .insert(guest.guestID)
    }

    public func unregisterGuest(guestID: String) async {
        guard let guest = guests.removeValue(forKey: guestID) else {
            return
        }
        guestIDsByOwner[guest.ownerID]?.remove(guestID)
        releasePortLeaseForGuest(guestID)
        await router.unregister(guestID: guestID)
    }

    public func unregisterOwner(ownerID: String) async {
        guard owners.removeValue(forKey: ownerID) != nil else {
            return
        }
        let guestIDs = guestIDsByOwner.removeValue(
            forKey: ownerID
        ) ?? []
        for guestID in guestIDs {
            guard guests.removeValue(forKey: guestID) != nil else {
                continue
            }
            releasePortLeaseForGuest(guestID)
            await router.unregister(guestID: guestID)
        }
    }

    public func teardownGuestNavigation(
        guestID: String,
        navigationID: String
    ) async {
        guard guests[guestID]?.navigationID == navigationID else {
            return
        }
        await unregisterGuest(guestID: guestID)
    }

    public func teardownOwnerNavigation(
        ownerID: String,
        navigationID: String
    ) async {
        guard owners[ownerID]?.navigationID == navigationID else {
            return
        }
        await unregisterOwner(ownerID: ownerID)
    }

    @discardableResult
    public func receiveGuestMessage(
        guestID: String,
        appSessionID: String,
        targetOrigin: String,
        envelope: CodexDesktopMCPAppSandboxGuestEnvelope,
        portIdentities:
            [CodexDesktopMCPAppSandboxNativePortIdentity]
    ) async throws -> CodexDesktopMCPAppSandboxNativeHostDelivery {
        guard let guest = guests[guestID] else {
            throw CodexDesktopMCPAppSandboxNativeCoordinatorError
                .unknownGuest
        }
        guard let owner = owners[guest.ownerID] else {
            throw CodexDesktopMCPAppSandboxNativeCoordinatorError
                .unknownOwner
        }
        guard owner.appSessionID == appSessionID else {
            throw CodexDesktopMCPAppSandboxError.appSessionMismatch
        }
        guard owner.targetOrigin == targetOrigin else {
            throw CodexDesktopMCPAppSandboxError.targetOriginMismatch
        }

        let route = try await router.routeGuestMessage(
            guestID: guestID,
            envelope: envelope,
            transferredPortCount: portIdentities.count
        )
        try route.validateDelivery(
            appSessionID: appSessionID,
            targetOrigin: targetOrigin
        )
        guard route.ownerID == owner.ownerID else {
            throw CodexDesktopMCPAppSandboxNativeCoordinatorError
                .ownerInvalidated
        }
        guard leaseIDByGuest[guestID] == nil else {
            throw CodexDesktopMCPAppSandboxNativeCoordinatorError
                .portLeaseAlreadyActive
        }
        guard portIdentities.allSatisfy({
            !$0.rawValue.isEmpty
        }) else {
            throw CodexDesktopMCPAppSandboxNativeCoordinatorError
                .invalidPortIdentity
        }
        guard Set(portIdentities).count == portIdentities.count else {
            throw CodexDesktopMCPAppSandboxNativeCoordinatorError
                .duplicatePortIdentity
        }

        let namedPortCount = route.envelope.portNames.count
        let leaseID = makeLeaseID()
        let lease = CodexDesktopMCPAppSandboxNativePortLease(
            leaseID: leaseID,
            guestID: guestID,
            ownerID: owner.ownerID,
            portNames: route.envelope.portNames,
            namedPortIdentities:
                Array(portIdentities.prefix(namedPortCount)),
            replyPortIdentity: portIdentities[namedPortCount]
        )
        let delivery = CodexDesktopMCPAppSandboxNativeHostDelivery(
            channel: route.channel,
            ownerID: route.ownerID,
            appSessionID: route.appSessionID,
            targetOrigin: route.targetOrigin,
            envelope: route.envelope,
            portLease: lease
        )
        leasesByID[leaseID] = PortLeaseRecord(lease: lease)
        leaseIDByGuest[guestID] = leaseID

        do {
            try await sendHostDelivery(delivery)
            return delivery
        } catch {
            releasePortLease(leaseID)
            throw error
        }
    }

    public func isPortLeaseActive(_ leaseID: String) -> Bool {
        leasesByID[leaseID] != nil
    }

    public func releasePortLease(_ leaseID: String) {
        guard let record = leasesByID.removeValue(forKey: leaseID)
        else {
            return
        }
        if leaseIDByGuest[record.lease.guestID] == leaseID {
            leaseIDByGuest.removeValue(
                forKey: record.lease.guestID
            )
        }
    }

    private func releasePortLeaseForGuest(_ guestID: String) {
        guard let leaseID = leaseIDByGuest[guestID] else {
            return
        }
        releasePortLease(leaseID)
    }

    private func makeLeaseID() -> String {
        defer { nextLeaseSequence += 1 }
        return "mcp-app-port-lease-\(nextLeaseSequence)"
    }
}
