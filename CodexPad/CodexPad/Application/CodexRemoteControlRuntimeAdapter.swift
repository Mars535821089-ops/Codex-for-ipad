#if SWIFT_PACKAGE
import CodexPadDomain
#endif
import Foundation

public struct CodexRemoteControlWebSocketRuntimeContext:
    Equatable,
    Sendable
{
    public let validatedHTTPBaseURL: URL
    public let enrollment: CodexRemoteControlHTTPEnrollment
    public let serverName: String
    public let installationID: String

    public init(
        validatedHTTPBaseURL: URL,
        enrollment: CodexRemoteControlHTTPEnrollment,
        serverName: String,
        installationID: String
    ) {
        self.validatedHTTPBaseURL = validatedHTTPBaseURL
        self.enrollment = enrollment
        self.serverName = serverName
        self.installationID = installationID
    }
}

public protocol CodexRemoteControlWebSocketRunning: Sendable {
    func run() async throws

    func send(
        event: CodexRemoteControlServerEvent,
        clientID: String,
        streamID: String
    ) async throws

    func disconnect() async throws
}

extension CodexRemoteControlWebSocketTransport:
    CodexRemoteControlWebSocketRunning
{}

/// Owns the concrete socket transport required by the lifecycle backend and
/// connects its inbound envelopes to the exact virtual desktop session.
public actor CodexRemoteControlWebSocketLifecycleAdapter:
    CodexRemoteControlWebSocketLifecycle
{
    public typealias MakeTransport = @Sendable (
        CodexRemoteControlWebSocketRuntimeContext,
        @escaping CodexRemoteControlInboundHandler,
        @escaping CodexRemoteControlWebSocketStatusHandler
    ) throws -> any CodexRemoteControlWebSocketRunning

    private let router: CodexRemoteControlVirtualSessionRouter
    private let makeTransport: MakeTransport

    private var transport: (any CodexRemoteControlWebSocketRunning)?
    private var runTask: Task<Void, Never>?
    private var statusContinuation:
        AsyncThrowingStream<
            CodexRemoteControlConnectionStatus,
            Error
        >.Continuation?
    private var generation: UInt64 = 0

    public init(
        router: CodexRemoteControlVirtualSessionRouter,
        connector: any CodexRemoteControlWebSocketConnecting =
            CodexRemoteControlURLSessionWebSocketConnector(),
        configuration: CodexRemoteControlWebSocketConfiguration = .init()
    ) {
        self.router = router
        makeTransport = { context, inbound, status in
            try CodexRemoteControlWebSocketTransport(
                validatedHTTPBaseURL:
                    context.validatedHTTPBaseURL,
                enrollment: context.enrollment,
                serverName: context.serverName,
                installationID: context.installationID,
                connector: connector,
                configuration: configuration,
                inboundHandler: inbound,
                statusHandler: status
            )
        }
    }

    public init(
        router: CodexRemoteControlVirtualSessionRouter,
        makeTransport: @escaping MakeTransport
    ) {
        self.router = router
        self.makeTransport = makeTransport
    }

    public func connect(
        target: String,
        installationID: String,
        accountID: String,
        serverID: String,
        environmentID: String,
        serverName: String,
        token: String
    ) async throws -> AsyncThrowingStream<
        CodexRemoteControlConnectionStatus,
        Error
    > {
        await disconnect()

        guard let requestedURL = URL(string: target) else {
            throw CodexRemoteControlLifecycleError.invalidTarget
        }
        let validatedBaseURL = try CodexRemoteControlHTTPTransport(
            baseURL: requestedURL
        ).baseURL
        let context = CodexRemoteControlWebSocketRuntimeContext(
            validatedHTTPBaseURL: validatedBaseURL,
            enrollment: .init(
                serverID: serverID,
                environmentID: environmentID,
                remoteControlToken: token,
                expiresAt: .max,
                accountID: accountID
            ),
            serverName: serverName,
            installationID: installationID
        )
        let stream = AsyncThrowingStream<
            CodexRemoteControlConnectionStatus,
            Error
        >.makeStream()
        let ingress = CodexRemoteControlVirtualSessionIngress(
            router: router,
            send: { [weak self] event, clientID, streamID in
                guard let self else {
                    throw CancellationError()
                }
                try await self.send(
                    event: event,
                    clientID: clientID,
                    streamID: streamID
                )
            }
        )
        let created = try makeTransport(
            context,
            { envelope in
                try await ingress.handle(envelope)
            },
            { status in
                stream.continuation.yield(
                    Self.lifecycleStatus(status)
                )
            }
        )

        generation = generation == UInt64.max ? 1 : generation + 1
        let activeGeneration = generation
        transport = created
        statusContinuation = stream.continuation
        runTask = Task { [weak self] in
            do {
                try await created.run()
                await self?.finishRun(
                    generation: activeGeneration,
                    error: nil
                )
            } catch is CancellationError {
                await self?.finishRun(
                    generation: activeGeneration,
                    error: nil
                )
            } catch {
                await self?.finishRun(
                    generation: activeGeneration,
                    error: error
                )
            }
        }
        return stream.stream
    }

    public func disconnect() async {
        generation = generation == UInt64.max ? 1 : generation + 1
        runTask?.cancel()
        runTask = nil
        let activeTransport = transport
        transport = nil
        let continuation = statusContinuation
        statusContinuation = nil
        if let activeTransport {
            try? await activeTransport.disconnect()
        }
        continuation?.finish()
        await router.transportConnectionDidReset()
    }

    private func send(
        event: CodexRemoteControlServerEvent,
        clientID: String,
        streamID: String
    ) async throws {
        guard let transport else {
            throw CancellationError()
        }
        try await transport.send(
            event: event,
            clientID: clientID,
            streamID: streamID
        )
    }

    private func finishRun(
        generation expectedGeneration: UInt64,
        error: (any Error)?
    ) {
        guard expectedGeneration == generation else { return }
        runTask = nil
        let continuation = statusContinuation
        statusContinuation = nil
        if let error {
            continuation?.finish(throwing: error)
        } else {
            continuation?.finish()
        }
    }

    private nonisolated static func lifecycleStatus(
        _ status: CodexRemoteControlWebSocketStatus
    ) -> CodexRemoteControlConnectionStatus {
        switch status {
        case .connected:
            .connected
        case .disconnected, .connecting, .reconnecting, .stopped:
            .connecting
        }
    }
}
