#if SWIFT_PACKAGE
    import CodexPadDomain
    import CodexPadProtocolBridge
#endif
import Foundation

public struct CodexDesktopAppHostOutboundFrame:
    Equatable,
    Sendable
{
    public let portID: String
    public let frame: String

    public init(
        portID: String,
        frame: String
    ) {
        self.portID = portID
        self.frame = frame
    }

    /// Event shape consumed by `CodexDesktopBridgeScript.receive`.
    public var hostMessage: CodexDesktopHostMessage {
        .event(
            type: CodexDesktopAppHostSessionStore.messageChannel,
            payload: .object([
                "portID": .string(portID),
                "frame": .string(frame),
            ])
        )
    }
}

public struct CodexDesktopAppHostHandledChannel:
    Equatable,
    Sendable
{
    /// The first response frame is returned directly from
    /// `WKScriptMessageHandlerWithReply`.
    public let reply: CodexJSONValue?

    /// Cap'n Web may produce further frames. Those travel back through
    /// `window.__codexDesktopHost.receive` rather than the one-shot WK reply.
    public let deferredFrames: [CodexDesktopAppHostOutboundFrame]

    public init(
        reply: CodexJSONValue?,
        deferredFrames: [CodexDesktopAppHostOutboundFrame]
    ) {
        self.reply = reply
        self.deferredFrames = deferredFrames
    }
}

public enum CodexDesktopAppHostNativeChannelResult:
    Equatable,
    Sendable
{
    case notHandled
    case handled(CodexDesktopAppHostHandledChannel)

    public var wkReply: CodexJSONValue? {
        guard case let .handled(response) = self else {
            return nil
        }
        return response.reply
    }
}

public struct CodexDesktopAppHostCallbackIdentity:
    Equatable,
    Hashable,
    Sendable
{
    public let portID: String
    public let callbackID: Int

    public init(
        portID: String,
        callbackID: Int
    ) {
        self.portID = portID
        self.callbackID = callbackID
    }
}

public struct CodexDesktopAppHostInvocationContext:
    Equatable,
    Sendable
{
    public let portID: String
    public let pipeline: CodexDesktopAppHostRPC.Pipeline

    public init(
        portID: String,
        pipeline: CodexDesktopAppHostRPC.Pipeline
    ) {
        self.portID = portID
        self.pipeline = pipeline
    }

    public func callbackIdentity(
        for callbackID: Int
    ) -> CodexDesktopAppHostCallbackIdentity {
        CodexDesktopAppHostCallbackIdentity(
            portID: portID,
            callbackID: callbackID
        )
    }
}

/// Owns one Cap'n Web session for every logical MessagePort created by the
/// document-start bridge.
///
/// The official host exposes `services` as a plain object. Most values are
/// RpcTargets represented by `.rpcObject`, but the released root also contains
/// literal capability flags such as `notificationPermissionsSupported`.
public final class CodexDesktopAppHostSessionStore {
    public typealias ServiceValue = CodexDesktopAppHostRPC.Value
    public typealias InvocationHandler =
        CodexDesktopAppHostRPC.InvocationHandler
    public typealias AsyncInvocationHandler =
        CodexDesktopAppHostRPC.AsyncInvocationHandler
    public typealias PortScopedInvocationHandler =
        (CodexDesktopAppHostInvocationContext) throws -> ServiceValue
    public typealias PortScopedAsyncInvocationHandler =
        (CodexDesktopAppHostInvocationContext) async throws -> ServiceValue
    public typealias DeferredFrameHandler =
        (CodexDesktopAppHostOutboundFrame) -> Void
    public typealias PortConnectedHandler =
        (String) -> Void
    public typealias ServicesResolvedHandler =
        (String) -> Void

    public enum Error:
        Swift.Error,
        Equatable,
        Sendable
    {
        case invalidServiceTarget(String)
        case invalidPayload(channel: String)
        case unknownPortID(String)
        case invalidCallbackID(Int)
        case outboundFrameHandlerUnavailable
    }

    public static let connectedChannel = "app-host-connected"
    public static let messageChannel = "app-host-message"

    private let services: [String: ServiceValue]
    private let invocationHandler: InvocationHandler?
    private let asyncInvocationHandler: AsyncInvocationHandler?
    private let portScopedInvocationHandler:
        PortScopedInvocationHandler?
    private let portScopedAsyncInvocationHandler:
        PortScopedAsyncInvocationHandler?
    private let deferredFrameHandler: DeferredFrameHandler?
    private let portConnectedHandler: PortConnectedHandler?
    private let servicesResolvedHandler: ServicesResolvedHandler?
    private var sessions: [String: CodexDesktopAppHostRPC] = [:]
    private var pendingServicesPullIDs: [String: Int] = [:]
    public private(set) var servicesResolvedPortIDs =
        Set<String>()

    public init(
        services: [String: ServiceValue],
        invocationHandler: InvocationHandler? = nil,
        asyncInvocationHandler: AsyncInvocationHandler? = nil,
        portScopedInvocationHandler:
            PortScopedInvocationHandler? = nil,
        portScopedAsyncInvocationHandler:
            PortScopedAsyncInvocationHandler? = nil,
        deferredFrameHandler: DeferredFrameHandler? = nil,
        portConnectedHandler: PortConnectedHandler? = nil,
        servicesResolvedHandler: ServicesResolvedHandler? = nil
    ) throws {
        for (name, service) in services {
            guard !name.isEmpty,
                  Self.isSupportedRootServiceValue(service)
            else {
                throw Error.invalidServiceTarget(name)
            }
        }
        self.services = services
        self.invocationHandler = invocationHandler
        self.asyncInvocationHandler = asyncInvocationHandler
        self.portScopedInvocationHandler =
            portScopedInvocationHandler
        self.portScopedAsyncInvocationHandler =
            portScopedAsyncInvocationHandler
        self.deferredFrameHandler = deferredFrameHandler
        self.portConnectedHandler = portConnectedHandler
        self.servicesResolvedHandler = servicesResolvedHandler
    }

    public var portIDs: [String] {
        sessions.keys.sorted()
    }

    public func snapshot(
        for portID: String
    ) -> CodexDesktopAppHostRPC.Snapshot? {
        sessions[portID]?.snapshot
    }

    /// Routes only the two native channels owned by the app-host transport.
    /// Callers can explicitly fall through to their other native handlers when
    /// this returns `.notHandled`.
    @discardableResult
    public func handleNativeChannel(
        name: String,
        payload: CodexJSONValue
    ) throws -> CodexDesktopAppHostNativeChannelResult {
        switch name {
        case Self.connectedChannel:
            let portID = try Self.decodePortID(
                payload,
                channel: name
            )
            // A document reload restarts logical IDs at app-host-1. Replacing
            // the old session gives the new MessagePort a clean export table.
            // Terminate its native waiters first so delayed replies cannot
            // strand a task or cross into the replacement session.
            sessions[portID]?.invalidate()
            sessions[portID] = CodexDesktopAppHostRPC(
                services: services,
                invocationHandler: invocationHandler(
                    forPortID: portID
                ),
                asyncInvocationHandler: asyncInvocationHandler(
                    forPortID: portID
                )
            )
            pendingServicesPullIDs.removeValue(forKey: portID)
            servicesResolvedPortIDs.remove(portID)
            portConnectedHandler?(portID)
            return .handled(
                CodexDesktopAppHostHandledChannel(
                    reply: nil,
                    deferredFrames: []
                )
            )

        case Self.messageChannel:
            let message = try Self.decodeMessage(
                payload,
                channel: name
            )
            guard let session = sessions[message.portID] else {
                throw Error.unknownPortID(message.portID)
            }
            let frame = try CodexDesktopAppHostRPC.decode(
                message.frame
            )
            let pendingServicesPullID: Int?
            if Self.isRootServicesRequest(frame) {
                pendingServicesPullID =
                    session.snapshot.nextPipelineExportID
            } else {
                pendingServicesPullID = nil
            }
            let responseFrames = try session.receive(
                message.frame
            )
            if let pendingServicesPullID {
                pendingServicesPullIDs[message.portID] =
                    pendingServicesPullID
            }
            markServicesResolvedIfNeeded(
                incoming: frame,
                responseFrames: responseFrames,
                portID: message.portID
            )
            return .handled(
                routeResponseFrames(
                    responseFrames,
                    portID: message.portID
                )
            )

        default:
            return .notHandled
        }
    }

    /// Async native-channel route for services backed by app-server, files,
    /// permissions, or other actor-isolated iPadOS APIs.
    @discardableResult
    @MainActor
    public func handleNativeChannelAsync(
        name: String,
        payload: CodexJSONValue
    ) async throws -> CodexDesktopAppHostNativeChannelResult {
        switch name {
        case Self.connectedChannel:
            return try handleNativeChannel(
                name: name,
                payload: payload
            )

        case Self.messageChannel:
            let message = try Self.decodeMessage(
                payload,
                channel: name
            )
            guard let session = sessions[message.portID] else {
                throw Error.unknownPortID(message.portID)
            }
            let frame = try CodexDesktopAppHostRPC.decode(
                message.frame
            )
            let pendingServicesPullID: Int?
            if Self.isRootServicesRequest(frame) {
                pendingServicesPullID =
                    session.snapshot.nextPipelineExportID
            } else {
                pendingServicesPullID = nil
            }
            let responseFrames = try await session.receiveAsync(
                message.frame
            )
            if let pendingServicesPullID {
                pendingServicesPullIDs[message.portID] =
                    pendingServicesPullID
            }
            markServicesResolvedIfNeeded(
                incoming: frame,
                responseFrames: responseFrames,
                portID: message.portID
            )
            return .handled(
                routeResponseFrames(
                    responseFrames,
                    portID: message.portID
                )
            )

        default:
            return .notHandled
        }
    }

    public var hasResolvedServices: Bool {
        !servicesResolvedPortIDs.isEmpty
    }

    /// Invokes a renderer-owned Cap'n Web import on its originating logical
    /// MessagePort. Import IDs are scoped to one session, so the port is part
    /// of the callback identity even when two ports reuse the same integer ID.
    @discardableResult
    public func sendImportCall(
        to callback: CodexDesktopAppHostCallbackIdentity,
        arguments: [ServiceValue]
    ) throws -> CodexDesktopAppHostOutboundFrame {
        guard let session = sessions[callback.portID] else {
            throw Error.unknownPortID(callback.portID)
        }
        // Renderer-owned exports are negative in released Cap'n Web frames.
        // Zero is the session root, not a callable renderer callback.
        guard callback.callbackID != 0 else {
            throw Error.invalidCallbackID(callback.callbackID)
        }
        guard let deferredFrameHandler else {
            throw Error.outboundFrameHandlerUnavailable
        }

        let call = try session.prepareImportCall(
            targetID: callback.callbackID,
            arguments: arguments,
            awaitsResult: false
        )
        let outboundFrame = CodexDesktopAppHostOutboundFrame(
            portID: callback.portID,
            frame: call.frames[0]
        )
        deferredFrameHandler(outboundFrame)
        return outboundFrame
    }

    /// Calls a renderer-owned import on one logical MessagePort and awaits the
    /// matching Cap'n Web `resolve` or `reject`.
    @MainActor
    public func callImport(
        onPortID portID: String,
        callbackID: Int,
        arguments: [ServiceValue]
    ) async throws -> ServiceValue {
        guard let session = sessions[portID] else {
            throw Error.unknownPortID(portID)
        }
        guard callbackID != 0 else {
            throw Error.invalidCallbackID(callbackID)
        }
        guard let deferredFrameHandler else {
            throw Error.outboundFrameHandlerUnavailable
        }

        let call = try session.prepareImportCall(
            targetID: callbackID,
            arguments: arguments,
            awaitsResult: true
        )
        for frame in call.frames {
            deferredFrameHandler(
                CodexDesktopAppHostOutboundFrame(
                    portID: portID,
                    frame: frame
                )
            )
        }
        return try await session.awaitImportResult(
            call.resultID
        )
    }

    func routeResponseFrames(
        _ frames: [String],
        portID: String
    ) -> CodexDesktopAppHostHandledChannel {
        let deferredFrames = frames.dropFirst().map {
            CodexDesktopAppHostOutboundFrame(
                portID: portID,
                frame: $0
            )
        }
        for frame in deferredFrames {
            deferredFrameHandler?(frame)
        }
        return CodexDesktopAppHostHandledChannel(
            reply: frames.first.map(CodexJSONValue.string),
            deferredFrames: deferredFrames
        )
    }

    private static func decodePortID(
        _ payload: CodexJSONValue,
        channel: String
    ) throws -> String {
        guard case let .object(fields) = payload,
              case let .string(portID)? = fields["portID"],
              !portID.isEmpty
        else {
            throw Error.invalidPayload(channel: channel)
        }
        return portID
    }

    private static func decodeMessage(
        _ payload: CodexJSONValue,
        channel: String
    ) throws -> (portID: String, frame: String) {
        guard case let .object(fields) = payload,
              case let .string(portID)? = fields["portID"],
              !portID.isEmpty,
              case let .string(frame)? = fields["frame"]
        else {
            throw Error.invalidPayload(channel: channel)
        }
        return (portID, frame)
    }

    private static func isRootServicesRequest(
        _ frame: CodexDesktopAppHostRPC.Frame
    ) -> Bool {
        guard case let .push(pipeline) = frame,
              pipeline.targetID == 0,
              pipeline.path == [.key("services")],
              pipeline.arguments == nil
        else {
            return false
        }
        return true
    }

    private static func isSupportedRootServiceValue(
        _ value: ServiceValue
    ) -> Bool {
        switch value {
        case .rpcObject,
             .null,
             .bool,
             .integer,
             .number,
             .string:
            return true
        default:
            return false
        }
    }

    private func invocationHandler(
        forPortID portID: String
    ) -> InvocationHandler? {
        if let portScopedInvocationHandler {
            return { pipeline in
                try portScopedInvocationHandler(
                    CodexDesktopAppHostInvocationContext(
                        portID: portID,
                        pipeline: pipeline
                    )
                )
            }
        }
        return invocationHandler
    }

    private func asyncInvocationHandler(
        forPortID portID: String
    ) -> AsyncInvocationHandler? {
        if let portScopedAsyncInvocationHandler {
            return { pipeline in
                try await portScopedAsyncInvocationHandler(
                    CodexDesktopAppHostInvocationContext(
                        portID: portID,
                        pipeline: pipeline
                    )
                )
            }
        }
        return asyncInvocationHandler
    }

    private func markServicesResolvedIfNeeded(
        incoming: CodexDesktopAppHostRPC.Frame,
        responseFrames: [String],
        portID: String
    ) {
        guard case let .pull(pullID) = incoming,
              pendingServicesPullIDs[portID] == pullID
        else {
            return
        }
        let didResolveServices = responseFrames.contains { frame in
            guard let decoded = try? CodexDesktopAppHostRPC.decode(
                frame
            ), case let .resolve(id, value) = decoded,
                id == pullID,
                case .object = value
            else {
                return false
            }
            return true
        }
        guard didResolveServices else {
            return
        }
        pendingServicesPullIDs.removeValue(forKey: portID)
        let inserted = servicesResolvedPortIDs.insert(
            portID
        ).inserted
        if inserted {
            servicesResolvedHandler?(portID)
        }
    }
}
