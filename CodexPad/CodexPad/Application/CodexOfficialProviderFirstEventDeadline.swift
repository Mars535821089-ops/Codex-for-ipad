import Foundation

public struct CodexOfficialProviderFirstEventTimeoutError:
    Error,
    Equatable,
    Sendable
{
    public init() {}
}

private final class CodexOfficialProviderFirstEventDeadlineState:
    @unchecked Sendable
{
    private let lock = NSLock()
    private var firstEventObserved = false
    private var terminal = false

    func observeFirstEvent() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !terminal else { return false }
        firstEventObserved = true
        return true
    }

    func claimUpstreamTerminal() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !terminal else { return false }
        terminal = true
        return true
    }

    func claimTimeout() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !terminal, !firstEventObserved else { return false }
        terminal = true
        return true
    }
}

/// Guarantees that a provider which blocks before producing its first event
/// cannot leave the released renderer in an unbounded Thinking state.
public enum CodexOfficialProviderFirstEventDeadline {
    public static func enforce<Element: Sendable>(
        _ upstream: AsyncThrowingStream<Element, Error>,
        timeout: Duration
    ) -> AsyncThrowingStream<Element, Error> {
        AsyncThrowingStream { continuation in
            let state = CodexOfficialProviderFirstEventDeadlineState()

            Task {
                do {
                    for try await event in upstream {
                        guard state.observeFirstEvent() else { return }
                        continuation.yield(event)
                    }
                    if state.claimUpstreamTerminal() {
                        continuation.finish()
                    }
                } catch {
                    if state.claimUpstreamTerminal() {
                        continuation.finish(throwing: error)
                    }
                }
            }

            Task {
                do {
                    try await Task.sleep(for: timeout)
                } catch {
                    return
                }
                if state.claimTimeout() {
                    continuation.finish(
                        throwing:
                            CodexOfficialProviderFirstEventTimeoutError()
                    )
                }
            }
        }
    }
}

public struct CodexOfficialProviderActivityTimeoutError:
    Error,
    Equatable,
    Sendable
{
    public init() {}
}

private final class CodexOfficialProviderActivityDeadlineState:
    @unchecked Sendable
{
    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var terminal = false

    func observeActivity() -> UInt64? {
        lock.lock()
        defer { lock.unlock() }
        guard !terminal else { return nil }
        generation &+= 1
        return generation
    }

    func claimUpstreamTerminal() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !terminal else { return false }
        terminal = true
        return true
    }

    func claimTimeout(expectedGeneration: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !terminal, generation == expectedGeneration else {
            return false
        }
        terminal = true
        return true
    }
}

/// Terminates a provider stream when it produces no event for the configured
/// interval, including both the initial wait and stalls after responseStarted.
public enum CodexOfficialProviderActivityDeadline {
    public static func enforce<Element: Sendable>(
        _ upstream: AsyncThrowingStream<Element, Error>,
        timeout: Duration
    ) -> AsyncThrowingStream<Element, Error> {
        AsyncThrowingStream { continuation in
            let state = CodexOfficialProviderActivityDeadlineState()

            func scheduleTimeout(for generation: UInt64) {
                Task {
                    do {
                        try await Task.sleep(for: timeout)
                    } catch {
                        return
                    }
                    if state.claimTimeout(
                        expectedGeneration: generation
                    ) {
                        continuation.finish(
                            throwing:
                                CodexOfficialProviderActivityTimeoutError()
                        )
                    }
                }
            }

            scheduleTimeout(for: 0)
            Task {
                do {
                    for try await event in upstream {
                        guard let generation = state.observeActivity()
                        else { return }
                        continuation.yield(event)
                        scheduleTimeout(for: generation)
                    }
                    if state.claimUpstreamTerminal() {
                        continuation.finish()
                    }
                } catch {
                    if state.claimUpstreamTerminal() {
                        continuation.finish(throwing: error)
                    }
                }
            }
        }
    }
}
