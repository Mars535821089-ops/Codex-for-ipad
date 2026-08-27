import Foundation

#if !SWIFT_PACKAGE
import CCodexCore

public enum CodexCoreClientError: Error, Equatable, Sendable {
    case unsupportedABIVersion(actual: UInt32)
    case coreCreationFailed
    case invalidArgument
    case invalidJSON
    case unsupportedCommand
    case storage
    case network
    case corePanic
    case unexpectedStatus(rawValue: Int32)
    case invalidEventBuffer
    case invalidResponseBuffer
    case eventDecodeFailure(diagnostic: String)
}

public enum CodexGitDiffWorkerError: Error, Equatable, Sendable {
    case invalidReply
    case replyIDMismatch(
        expected: CodexAppServerRequestID,
        actual: CodexAppServerRequestID
    )
    case appServerError(
        code: Int64,
        message: String,
        data: CodexJSONValue?
    )
}

@MainActor
public final class CodexCoreClient:
    CodexCoreTransport,
    CodexRemoteControlCoreEnrollmentTransport
{
    nonisolated public static let supportedABIVersion: UInt32 = 3

    nonisolated(unsafe) private let handle: OpaquePointer

    public init() throws {
        let actualVersion = codex_core_abi_version()
        guard actualVersion == Self.supportedABIVersion else {
            throw CodexCoreClientError.unsupportedABIVersion(
                actual: actualVersion
            )
        }
        guard let handle = codex_core_create() else {
            throw CodexCoreClientError.coreCreationFailed
        }
        self.handle = handle
    }

    deinit {
        codex_core_destroy(handle)
    }

    public func submit(_ command: CodexCoreCommand) throws {
        try submitData(command.encodedData())
    }

    public func submit(_ command: CodexRawHistoryCommit) throws {
        try submitData(command.encodedData())
    }

    public func submit(_ command: CodexCompactHistoryCommit) throws {
        try submitData(command.encodedData())
    }

    public func submit(_ command: CodexModelCatalogCommand) throws {
        try submitData(command.encodedData())
    }

    public func submit(
        _ command: CodexRemoteControlCoreEnrollmentCommand
    ) throws {
        try submitData(command.encodedData())
    }

    private func submitData(
        _ encodedData: @autoclosure () throws -> Data
    ) throws {
        let data = try encodedData()
        let status = data.withUnsafeBytes { bytes in
            codex_core_submit_json(
                handle,
                bytes.bindMemory(to: UInt8.self).baseAddress,
                bytes.count
            )
        }
        try Self.requireSuccess(status)
    }

    public func request(
        _ request: CodexAppServerThreadRequest
    ) throws -> Data {
        try requestData(request.encodedData())
    }

    public func request(
        _ request: CodexAppServerModelRequest
    ) throws -> Data {
        try requestData(request.encodedData())
    }

    public func request(
        _ request: CodexAppServerTurnRequest
    ) throws -> Data {
        try requestData(request.encodedData())
    }

    public func request(
        _ request: CodexRawHistoryRequest
    ) throws -> Data {
        try requestData(request.encodedData())
    }

    public func request(
        _ request: CodexRemoteControlCoreEnrollmentLoadRequest
    ) throws -> Data {
        try requestData(request.encodedData())
    }

    private func requestData(
        _ encodedData: @autoclosure () throws -> Data
    ) throws -> Data {
        let data = try encodedData()
        var buffer = CodexCoreBuffer(ptr: nil, len: 0, capacity: 0)
        let status = data.withUnsafeBytes { bytes in
            codex_core_request_json(
                handle,
                bytes.bindMemory(to: UInt8.self).baseAddress,
                bytes.count,
                &buffer
            )
        }
        if status.rawValue != 0 {
            let object = (try? JSONSerialization.jsonObject(with: data))
                as? [String: Any]
            let method = object?["method"] as? String ?? "unknown"
            let params = object?["params"] as? [String: Any]
            let keys = params.map { $0.keys.sorted().joined(separator: ",") }
                ?? "missing"
            let shape: String
            if let params {
                func valueShape(_ value: Any?) -> String {
                    switch value {
                    case nil: return "omitted"
                    case is NSNull: return "null"
                    case is String: return "string"
                    case is Bool: return "bool"
                    case is [Any]: return "array"
                    case is [String: Any]: return "object"
                    case is NSNumber: return "number"
                    default: return "other"
                    }
                }
                shape = params.keys.sorted().map {
                    "\($0):\(valueShape(params[$0]))"
                }.joined(separator: ";")
            } else {
                shape = "missing"
            }
            UserDefaults.standard.set(
                "request=\(method) statusRaw=\(status.rawValue) keys=\(keys) shape=\(shape)",
                forKey: "codex.desktop.last-core-request-json-status-diagnostic"
            )
        }
        defer {
            codex_core_buffer_free(&buffer)
        }
        if status.rawValue != 0 {
            let object = (try? JSONSerialization.jsonObject(with: data))
                as? [String: Any]
            let method = object?["method"] as? String ?? "unknown"
            let params = object?["params"] as? [String: Any]
            let keys = params.map { $0.keys.sorted().joined(separator: ",") }
                ?? "missing"
            UserDefaults.standard.set(
                "request=\(method) statusRaw=\(status.rawValue) keys=\(keys)",
                forKey: "codex.desktop.last-core-request-status-diagnostic"
            )
        }
        if status == CODEX_CORE_STATUS_INVALID_ARGUMENT {
            CodexTurnStartInvalidArgumentDiagnostic.record(
                requestData: data
            )
        }
        try Self.requireSuccess(status)
        guard let pointer = buffer.ptr, buffer.len > 0 else {
            throw CodexCoreClientError.invalidResponseBuffer
        }
        return Data(bytes: pointer, count: buffer.len)
    }

    public func nextEvent() throws -> CodexCoreEvent? {
        var buffer = CodexCoreBuffer(ptr: nil, len: 0, capacity: 0)
        let status = codex_core_next_event_json(handle, &buffer)
        defer {
            codex_core_buffer_free(&buffer)
        }

        // C enum imports have differed across Xcode SDKs. Match both the
        // imported constant and its ABI value so an empty event queue never
        // becomes a transport failure on a physical device.
        if status == CODEX_CORE_STATUS_NO_EVENT || status.rawValue == 4 {
            return nil
        }
        try Self.requireSuccess(status)
        guard let pointer = buffer.ptr, buffer.len > 0 else {
            throw CodexCoreClientError.invalidEventBuffer
        }

        let data = Data(bytes: pointer, count: buffer.len)
        do {
            return try CodexCoreEvent(data: data)
        } catch {
            let diagnostic = Self.recordEventDecodeFailure(
                data: data,
                error: error
            )
            throw CodexCoreClientError.eventDecodeFailure(
                diagnostic: diagnostic
            )
        }
    }

    @discardableResult
    nonisolated static func recordEventDecodeFailure(
        data: Data,
        error: any Error,
        userDefaults: UserDefaults = .standard
    ) -> String {
        CodexCoreEventDecodeDiagnostic.record(
            data: data,
            error: error,
            userDefaults: userDefaults
        )
    }

    public func executeOfficialResponse(
        _ request: CodexOfficialResponseRequest
    ) throws {
        let data = try request.encodedData()
        let status = data.withUnsafeBytes { bytes in
            codex_core_execute_official_response_json(
                handle,
                bytes.bindMemory(to: UInt8.self).baseAddress,
                bytes.count
            )
        }
        try Self.requireSuccess(status)
    }

    nonisolated fileprivate static func requireSuccess(
        _ status: CodexCoreStatus
    ) throws {
        // Use the C ABI values directly. Xcode has imported this enum with
        // inconsistent case values across SDKs, while the native library's
        // wire contract remains stable.
        switch status.rawValue {
        case 0:
            return
        case 1:
            throw CodexCoreClientError.invalidArgument
        case 2:
            throw CodexCoreClientError.invalidJSON
        case 3:
            throw CodexCoreClientError.unsupportedCommand
        case 5:
            throw CodexCoreClientError.storage
        case 6:
            throw CodexCoreClientError.network
        case 255:
            throw CodexCoreClientError.corePanic
        default:
            throw CodexCoreClientError.unexpectedStatus(
                rawValue: Int32(status.rawValue)
            )
        }
    }
}

/// Owns a dedicated embedded-core handle so repository traversal never
/// occupies the renderer/controller MainActor.
public actor CodexGitDiffWorker {
    nonisolated(unsafe) private let handle: OpaquePointer

    public init() throws {
        let actualVersion = codex_core_abi_version()
        guard actualVersion == CodexCoreClient.supportedABIVersion else {
            throw CodexCoreClientError.unsupportedABIVersion(
                actual: actualVersion
            )
        }
        guard let handle = codex_core_create() else {
            throw CodexCoreClientError.coreCreationFailed
        }
        self.handle = handle
    }

    deinit {
        codex_core_destroy(handle)
    }

    public func gitDiffToRemote(
        id: CodexAppServerRequestID,
        params: CodexGitDiffToRemoteParams
    ) async throws -> CodexGitDiffToRemoteResponse {
        let request = CodexAppServerThreadRequest.gitDiffToRemote(
            id: id,
            params: params
        )
        let responseData = try Self.requestJSON(
            handle: handle,
            data: request.encodedData()
        )

        let reply: CodexAppServerReply<CodexGitDiffToRemoteResponse>
        do {
            reply = try JSONDecoder().decode(
                CodexAppServerReply<CodexGitDiffToRemoteResponse>.self,
                from: responseData
            )
        } catch {
            throw CodexGitDiffWorkerError.invalidReply
        }

        switch reply {
        case let .success(response):
            guard response.id == id else {
                throw CodexGitDiffWorkerError.replyIDMismatch(
                    expected: id,
                    actual: response.id
                )
            }
            return response.result
        case let .failure(response):
            guard response.id == id else {
                throw CodexGitDiffWorkerError.replyIDMismatch(
                    expected: id,
                    actual: response.id
                )
            }
            throw CodexGitDiffWorkerError.appServerError(
                code: response.error.code,
                message: response.error.message,
                data: response.error.data
            )
        }
    }

    public func embeddedGitRead(
        method: String,
        params: CodexJSONValue
    ) async throws -> CodexJSONValue {
        struct Request: Encodable {
            let id: String
            let method: String
            let params: Parameters

            struct Parameters: Encodable {
                let method: String
                let params: CodexJSONValue
            }
        }

        let id = UUID().uuidString
        let request = Request(
            id: id,
            method: "gitWorker/read",
            params: .init(method: method, params: params)
        )
        let responseData = try Self.requestJSON(
            handle: handle,
            data: JSONEncoder().encode(request)
        )
        let reply: CodexAppServerReply<CodexJSONValue>
        do {
            reply = try JSONDecoder().decode(
                CodexAppServerReply<CodexJSONValue>.self,
                from: responseData
            )
        } catch {
            throw CodexGitDiffWorkerError.invalidReply
        }
        switch reply {
        case let .success(response):
            guard response.id == .string(id) else {
                throw CodexGitDiffWorkerError.invalidReply
            }
            return response.result
        case let .failure(response):
            throw CodexGitDiffWorkerError.appServerError(
                code: response.error.code,
                message: response.error.message,
                data: response.error.data
            )
        }
    }

    nonisolated private static func requestJSON(
        handle: OpaquePointer,
        data: Data
    ) throws -> Data {
        var buffer = CodexCoreBuffer(ptr: nil, len: 0, capacity: 0)
        let status = data.withUnsafeBytes { bytes in
            codex_core_request_json(
                handle,
                bytes.bindMemory(to: UInt8.self).baseAddress,
                bytes.count,
                &buffer
            )
        }
        if status.rawValue == 4 {
            let method = (try? JSONSerialization.jsonObject(with: data))
                .flatMap { $0 as? [String: Any] }?["method"] as? String
                ?? "unknown"
            UserDefaults.standard.set(
                "request=\(method) statusRaw=4",
                forKey: "codex.desktop.last-core-request-json-status-diagnostic"
            )
        }
        defer {
            codex_core_buffer_free(&buffer)
        }
        try CodexCoreClient.requireSuccess(status)
        guard let pointer = buffer.ptr, buffer.len > 0 else {
            throw CodexCoreClientError.invalidResponseBuffer
        }
        return Data(bytes: pointer, count: buffer.len)
    }
}
#endif
