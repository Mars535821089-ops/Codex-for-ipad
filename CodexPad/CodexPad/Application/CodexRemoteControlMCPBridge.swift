#if SWIFT_PACKAGE
    import CodexPadDomain
    import CodexPadProtocolBridge
#endif
import Foundation

/// Keeps one Remote Control service alive across renderer requests and maps
/// its validated status stream onto the released desktop MCP notification
/// envelope.
public actor CodexRemoteControlMCPBridge {
    public typealias NotificationStream = AsyncThrowingStream<
        CodexDesktopHostMessage,
        Error
    >

    private let service: CodexRemoteControlService

    public init(service: CodexRemoteControlService) {
        self.service = service
    }

    public init(backend: any CodexRemoteControlBackend) {
        service = CodexRemoteControlService(backend: backend)
    }

    /// Returns nil for non-Remote-Control methods so the released router chain
    /// can continue handling the request.
    public func response(
        to request: CodexDesktopMCPRequest
    ) async -> CodexDesktopHostMessage? {
        await CodexRemoteControlMCPRouter.response(
            to: request,
            service: service
        )
    }

    /// Produces the current released status notification for renderer-ready.
    /// A cached service status is preferred so a preceding RPC and renderer
    /// readiness share one coherent lifecycle snapshot.
    public func currentStatusNotification(
        hostID: String = "local"
    ) async throws -> CodexDesktopHostMessage {
        if let cached = await service.cachedStatus() {
            return try Self.statusMessage(cached, hostID: hostID)
        }
        let response = try await service.statusRead()
        return try Self.statusMessage(
            CodexRemoteControlStatusChangedNotification(
                status: response.status,
                serverName: response.serverName,
                installationId: response.installationId,
                environmentId: response.environmentId
            ),
            hostID: hostID
        )
    }

    /// Maps the service's single validated backend observation into desktop
    /// host messages while preserving source order, completion and failures.
    public func statusNotifications(
        hostID: String = "local"
    ) async -> NotificationStream {
        let source = await service.statusNotifications()
        let pair = NotificationStream.makeStream()
        let task = Task {
            do {
                for try await status in source {
                    try Task.checkCancellation()
                    pair.continuation.yield(
                        try Self.statusMessage(status, hostID: hostID)
                    )
                }
                pair.continuation.finish()
            } catch is CancellationError {
                pair.continuation.finish()
            } catch {
                pair.continuation.finish(throwing: error)
            }
        }
        pair.continuation.onTermination = { @Sendable _ in
            task.cancel()
        }
        return pair.stream
    }

    private nonisolated static func statusMessage(
        _ status: CodexRemoteControlStatusChangedNotification,
        hostID: String
    ) throws -> CodexDesktopHostMessage {
        let params = try JSONDecoder().decode(
            CodexJSONValue.self,
            from: JSONEncoder().encode(status)
        )
        return .mcpNotification(
            hostID: hostID,
            method: "remoteControl/status/changed",
            params: params,
            metadata: [:]
        )
    }
}
