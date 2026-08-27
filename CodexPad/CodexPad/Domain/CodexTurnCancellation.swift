import Foundation

public final class CodexTurnCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    public init() {}

    public var isCancelled: Bool {
        lock.withLock { cancelled }
    }

    public func cancel() {
        lock.withLock {
            cancelled = true
        }
    }

    public func checkCancellation() throws {
        if isCancelled {
            throw CancellationError()
        }
    }
}
