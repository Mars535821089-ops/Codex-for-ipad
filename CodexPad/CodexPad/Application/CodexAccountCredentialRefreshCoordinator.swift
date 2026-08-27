import Foundation

public enum CodexAccountCredentialRefreshError:
    Error,
    Equatable,
    Sendable
{
    case signedOut
}

/// Main-actor single-flight coordinator for account credential refresh.
/// `invalidate()` is called by login/sign-out mutations, cancelling the active
/// task and preventing a refresh that ignores cancellation from applying.
@MainActor
public final class CodexAccountCredentialRefreshCoordinator<
    Credential: Sendable
> {
    public typealias Operation =
        @Sendable (Credential) async throws -> Credential
    public typealias Apply =
        @MainActor (Credential) throws -> Void

    private struct ActiveRefresh {
        let id: UUID
        let generation: UInt64
        let task: Task<Credential, Error>
    }

    private var generation: UInt64 = 0
    private var activeRefresh: ActiveRefresh?

    public init() {}

    public func refresh(
        current: Credential,
        operation: @escaping Operation,
        apply: @escaping Apply
    ) async throws -> Credential {
        if let activeRefresh {
            return try await activeRefresh.task.value
        }

        let id = UUID()
        let startGeneration = generation
        let task = Task { @MainActor [weak self] in
            let refreshed = try await operation(current)
            try Task.checkCancellation()
            guard let self else {
                throw CancellationError()
            }
            return try self.finish(
                refreshed,
                id: id,
                generation: startGeneration,
                apply: apply
            )
        }
        activeRefresh = ActiveRefresh(
            id: id,
            generation: startGeneration,
            task: task
        )

        do {
            return try await task.value
        } catch {
            clearActiveRefresh(id: id)
            throw error
        }
    }

    public func invalidate() {
        generation &+= 1
        activeRefresh?.task.cancel()
        activeRefresh = nil
    }

    private func finish(
        _ refreshed: Credential,
        id: UUID,
        generation startGeneration: UInt64,
        apply: Apply
    ) throws -> Credential {
        guard generation == startGeneration,
              let activeRefresh,
              activeRefresh.id == id,
              activeRefresh.generation == startGeneration
        else {
            throw CancellationError()
        }
        try apply(refreshed)
        self.activeRefresh = nil
        return refreshed
    }

    private func clearActiveRefresh(id: UUID) {
        guard activeRefresh?.id == id else { return }
        activeRefresh = nil
    }
}
