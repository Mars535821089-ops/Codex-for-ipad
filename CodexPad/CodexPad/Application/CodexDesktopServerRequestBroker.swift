#if SWIFT_PACKAGE
import CodexPadDomain
import CodexPadProtocolBridge
#endif
import Foundation

public enum CodexDesktopServerRequestBrokerError:
    Swift.Error,
    Equatable,
    Sendable
{
    case cancelled
    case invalidResponse
    case remoteError(CodexJSONValue)
}

/// Shared released-renderer bridge for app-server requests that suspend the
/// native runtime until the renderer returns the matching JSON-RPC result.
@MainActor
public final class CodexDesktopServerRequestBroker {
    public typealias Send = (CodexDesktopHostMessage) async -> Void
    public typealias NativeHandler =
        @MainActor (
            _ method: String,
            _ params: CodexJSONValue?
        ) async throws -> CodexJSONValue?

    private typealias Continuation = CheckedContinuation<
        CodexJSONValue,
        Swift.Error
    >

    private struct PendingRequest {
        let threadID: String?
        let continuation: Continuation
        var timeoutTask: Task<Void, Never>?
    }

    private let hostID: String
    private let nativeHandler: NativeHandler?
    private let send: Send
    private var sequence: Int64 = 0
    private var pending: [CodexAppServerRequestID: PendingRequest] = [:]

    public init(
        hostID: String = "local",
        nativeHandler: NativeHandler? = nil,
        send: @escaping Send
    ) {
        self.hostID = hostID
        self.nativeHandler = nativeHandler
        self.send = send
    }

    public func request(
        method: String,
        params: CodexJSONValue?,
        threadID: String? = nil,
        timeoutNanoseconds: UInt64 = 300_000_000_000
    ) async throws -> CodexJSONValue {
        if let nativeHandler,
           let result = try await nativeHandler(method, params)
        {
            return result
        }

        sequence &+= 1
        let id = CodexAppServerRequestID.string(
            "server-request-\(sequence)"
        )
        let message = CodexDesktopHostMessage.mcpRequest(
            hostID: hostID,
            request: CodexDesktopMCPRequestMessage(
                id: id,
                method: method,
                params: params,
                metadata: [:]
            ),
            metadata: [:]
        )

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending[id] = PendingRequest(
                    threadID: threadID,
                    continuation: continuation,
                    timeoutTask: nil
                )
                if Task.isCancelled {
                    resolve(
                        id: id,
                        result: .failure(
                            CodexDesktopServerRequestBrokerError.cancelled
                        )
                    )
                    return
                }
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    await self.send(message)
                }
                let timeoutTask = Task { @MainActor [weak self] in
                    do {
                        try await Task.sleep(
                            nanoseconds: timeoutNanoseconds
                        )
                    } catch {
                        return
                    }
                    self?.resolve(
                        id: id,
                        result: .failure(
                            CodexDesktopServerRequestBrokerError.cancelled
                        )
                    )
                }
                pending[id]?.timeoutTask = timeoutTask
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.resolve(
                    id: id,
                    result: .failure(
                        CodexDesktopServerRequestBrokerError.cancelled
                    )
                )
            }
        }
    }

    /// Returns `true` only when this broker owned and consumed the response.
    @discardableResult
    public func receive(
        hostID: String,
        response: CodexDesktopMCPClientResponse
    ) -> Bool {
        guard hostID == self.hostID, pending[response.id] != nil else {
            return false
        }
        if let error = response.error {
            resolve(
                id: response.id,
                result: .failure(
                    CodexDesktopServerRequestBrokerError.remoteError(error)
                )
            )
            return true
        }
        guard let result = response.result else {
            resolve(
                id: response.id,
                result: .failure(
                    CodexDesktopServerRequestBrokerError.invalidResponse
                )
            )
            return true
        }
        resolve(id: response.id, result: .success(result))
        return true
    }

    public func cancelAll() {
        let requests = pending
        pending.removeAll()
        for (id, request) in requests {
            finish(
                id: id,
                request: request,
                result: .failure(
                    CodexDesktopServerRequestBrokerError.cancelled
                )
            )
        }
    }

    private func resolve(
        id: CodexAppServerRequestID,
        result: Result<CodexJSONValue, Swift.Error>
    ) {
        guard let request = pending.removeValue(forKey: id) else {
            return
        }
        finish(id: id, request: request, result: result)
    }

    private func finish(
        id: CodexAppServerRequestID,
        request: PendingRequest,
        result: Result<CodexJSONValue, Swift.Error>
    ) {
        request.timeoutTask?.cancel()
        if let threadID = request.threadID {
            let notification = CodexDesktopHostMessage.mcpNotification(
                hostID: hostID,
                method: "serverRequest/resolved",
                params: .object([
                    "threadId": .string(threadID),
                    "requestId": Self.encode(id),
                ]),
                metadata: [:]
            )
            Task { @MainActor [send] in
                await send(notification)
                request.continuation.resume(with: result)
            }
        } else {
            request.continuation.resume(with: result)
        }
    }

    private static func encode(
        _ id: CodexAppServerRequestID
    ) -> CodexJSONValue {
        switch id {
        case let .string(value): .string(value)
        case let .integer(value): .integer(value)
        }
    }
}
