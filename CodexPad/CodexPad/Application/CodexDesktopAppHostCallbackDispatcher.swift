import Foundation

/// Late-bound bridge from per-port AppHost service callbacks to the renderer
/// session that owns the imported callback target.
///
/// Service graphs are created before the session store is assigned to the
/// surface controller. Installing the sink after that assignment avoids a
/// strong reference cycle while preserving the `(portID, callbackID)` scope
/// required by Cap'n Web.
public final class CodexDesktopAppHostCallbackDispatcher:
    @unchecked Sendable
{
    public typealias Value = CodexDesktopAppHostRPC.Value
    public typealias Handler =
        @Sendable (
            CodexDesktopAppHostCallbackIdentity,
            [Value]
        ) async throws -> Void

    public enum Error: Swift.Error, Equatable, Sendable {
        case handlerUnavailable
    }

    private let lock = NSLock()
    private var handler: Handler?

    public init() {}

    public func install(_ handler: @escaping Handler) {
        lock.withLock {
            self.handler = handler
        }
    }

    public func removeHandler() {
        lock.withLock {
            handler = nil
        }
    }

    public func send(
        portID: String,
        callbackID: Int,
        arguments: [Value]
    ) async throws {
        let current = lock.withLock { handler }
        guard let current else {
            throw Error.handlerUnavailable
        }
        try await current(
            CodexDesktopAppHostCallbackIdentity(
                portID: portID,
                callbackID: callbackID
            ),
            arguments
        )
    }
}
