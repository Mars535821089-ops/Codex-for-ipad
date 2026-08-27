import Foundation

/// Owns one AppHost service graph for every logical renderer MessagePort.
///
/// Cap'n Web import/export identifiers are session-local. Keeping a dedicated
/// router per port prevents callback identifiers reused by two renderer ports
/// from sharing subscription state. A document reload reconnects with the same
/// logical port identifier, so the controller explicitly resets that entry
/// from `portConnectedHandler` before the first invocation of the new session.
public final class CodexDesktopAppHostPortRouterStore:
    @unchecked Sendable
{
    public typealias RouterFactory =
        (String) -> CodexDesktopInitialAppHostRouter

    private let lock = NSLock()
    private let factory: RouterFactory
    private var routers: [
        String: CodexDesktopInitialAppHostRouter
    ] = [:]

    public init(factory: @escaping RouterFactory) {
        self.factory = factory
    }

    public var portIDs: [String] {
        lock.lock()
        defer { lock.unlock() }
        return routers.keys.sorted()
    }

    public func router(
        for portID: String
    ) -> CodexDesktopInitialAppHostRouter {
        lock.lock()
        defer { lock.unlock() }
        if let router = routers[portID] {
            return router
        }
        let router = factory(portID)
        routers[portID] = router
        return router
    }

    public func reset(portID: String) {
        lock.lock()
        routers.removeValue(forKey: portID)
        lock.unlock()
    }

    public func resetAll() {
        lock.lock()
        routers.removeAll()
        lock.unlock()
    }

    public func response(
        to context: CodexDesktopAppHostInvocationContext
    ) async throws -> CodexDesktopAppHostRPC.Value {
        let router = router(for: context.portID)
        return try await router.responseAsync(
            to: context.pipeline
        )
    }
}
