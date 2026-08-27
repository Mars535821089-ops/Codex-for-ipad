import Foundation

#if !SWIFT_PACKAGE
import CCodexCore

private struct CodexPreparedOfficialHeader: Decodable {
    let name: String
    let value: String
}

private struct CodexPreparedOfficialRequest: Decodable {
    let url: String
    let method: String
    let headers: [CodexPreparedOfficialHeader]
    let proxyURL: String?
    let bodyBase64: String

    private enum CodingKeys: String, CodingKey {
        case url
        case method
        case headers
        case proxyURL = "proxyUrl"
        case bodyBase64
    }
}

private enum CodexOfficialProviderHTTPDiagnostic {
    static func summary(status: Int, bytes: Int, body: Data) -> String {
        var fields = [
            "status=\(status)",
            "stage=body_complete",
            "bytes=\(bytes)",
        ]
        if let object = try? JSONSerialization.jsonObject(with: body),
           let value = firstString(in: object, keys: ["code", "error_code", "type"]),
           isSafeToken(value)
        {
            fields.append("code=\(value)")
        }
        if let value = try? JSONSerialization.jsonObject(with: body),
           let detail = firstString(in: value, keys: ["message", "detail", "error"]),
           isSafeDetail(detail)
        {
            fields.append("detail=\(detail)")
        }
        return fields.joined(separator: " ")
    }

    private static func firstString(in value: Any, keys: [String]) -> String? {
        if let object = value as? [String: Any] {
            for key in keys {
                if let string = object[key] as? String, !string.isEmpty {
                    return string
                }
            }
            for nested in object.values {
                if let found = firstString(in: nested, keys: keys) {
                    return found
                }
            }
        } else if let array = value as? [Any] {
            for nested in array {
                if let found = firstString(in: nested, keys: keys) {
                    return found
                }
            }
        }
        return nil
    }

    private static func isSafeToken(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 80
            && value.unicodeScalars.allSatisfy { scalar in
                (scalar.value >= 48 && scalar.value <= 57)
                    || (scalar.value >= 65 && scalar.value <= 90)
                    || (scalar.value >= 97 && scalar.value <= 122)
                    || scalar.value == 95 || scalar.value == 45
            }
    }

    private static func isSafeDetail(_ value: String) -> Bool {
        let lowered = value.lowercased()
        let sensitive = [
            "token", "authorization", "secret", "cookie", "password",
            "credential", "api_key", "access_key", "refresh_token",
        ]
        return !value.isEmpty && value.utf8.count <= 240
            && !sensitive.contains(where: lowered.contains)
            && value.unicodeScalars.allSatisfy { scalar in
                scalar.value >= 32 && scalar.value <= 126
            }
    }
}

private final class CodexProviderStreamContext: @unchecked Sendable {
    private let continuation:
        AsyncThrowingStream<CodexCoreProviderEvent, Error>.Continuation
    private let lock = NSLock()
    private var decodingError: Error?
    private var receivedEventCount = 0
    private var receivedEventKinds: [String: Int] = [:]
    private let cancellation: CodexTurnCancellation

    init(
        continuation:
            AsyncThrowingStream<CodexCoreProviderEvent, Error>.Continuation,
        cancellation: CodexTurnCancellation
    ) {
        self.continuation = continuation
        self.cancellation = cancellation
    }

    func receive(
        bytes: UnsafePointer<UInt8>?,
        length: Int
    ) -> Bool {
        if cancellation.isCancelled {
            return false
        }
        guard length > 0 else {
            return true
        }
        guard let bytes, length > 0 else {
            record(error: CodexCoreClientError.invalidEventBuffer)
            return false
        }
        do {
            let event = try CodexCoreEvent(
                data: Data(bytes: bytes, count: length)
            )
            if case let .provider(providerEvent) = event {
                recordProviderEvent(providerEvent)
                continuation.yield(providerEvent)
            }
            return !cancellation.isCancelled
        } catch {
            Self.recordDecodeFailure(
                data: Data(bytes: bytes, count: length),
                error: error
            )
            record(error: error)
            return false
        }
    }

    func finish(with error: Error?) {
        lock.lock()
        let finalError = decodingError ?? error
        lock.unlock()
        let summary: String
        lock.lock()
        let kinds = receivedEventKinds.keys.sorted().compactMap { kind in
            guard let count = receivedEventKinds[kind] else { return nil }
            return "\(kind)=\(count)"
        }.joined(separator: ",")
        let terminal = finalError == nil ? "completed" : "error"
        summary = "events=\(receivedEventCount) kinds=\(kinds) terminal=\(terminal)"
        lock.unlock()
        UserDefaults.standard.set(
            summary,
            forKey: "codex.desktop.last-official-provider-event-diagnostic"
        )
        if let finalError {
            continuation.finish(throwing: finalError)
        } else {
            continuation.finish()
        }
    }

    private func record(error: Error) {
        lock.lock()
        if decodingError == nil {
            decodingError = error
        }
        lock.unlock()
    }

    private func recordProviderEvent(_ event: CodexCoreProviderEvent) {
        let kind: String
        switch event {
        case .responseStarted: kind = "responseStarted"
        case .assistantTextDelta: kind = "assistantTextDelta"
        case .planStarted: kind = "planStarted"
        case .planDelta: kind = "planDelta"
        case .planCompleted: kind = "planCompleted"
        case .toolCallRequested: kind = "toolCallRequested"
        case .responseItemDone: kind = "responseItemDone"
        case let .realtime(_, _, eventType, _): kind = "realtime:\(eventType)"
        case .responseCompleted: kind = "responseCompleted"
        }
        lock.lock()
        receivedEventCount += 1
        receivedEventKinds[kind, default: 0] += 1
        lock.unlock()
    }

    private static func recordDecodeFailure(
        data: Data,
        error: any Error
    ) {
        let object = try? JSONSerialization.jsonObject(with: data)
            as? [String: Any]
        let kind = object?["kind"] as? String ?? "invalid-json"
        let keys = object?.keys.sorted().joined(separator: ",") ?? "none"
        UserDefaults.standard.set(
            "provider-event-decode kind=\(kind) keys=\(keys)"
                + " errorType=\(String(describing: type(of: error)))",
            forKey: "codex.desktop.last-provider-event-decode-failure"
        )
    }
}

private let codexProviderStreamCallback:
    @convention(c) (
        UnsafePointer<UInt8>?,
        Int,
        UnsafeMutableRawPointer?
    ) -> Int32 = { bytes, length, opaqueContext in
        guard let opaqueContext else { return 0 }
        let context = Unmanaged<CodexProviderStreamContext>
            .fromOpaque(opaqueContext)
            .takeUnretainedValue()
        return context.receive(bytes: bytes, length: length) ? 1 : 0
    }

public actor CodexOfficialProviderClient {
    nonisolated(unsafe) private let handle: OpaquePointer
    private var providerStreamTail: Task<Void, Never>?

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

    public func stream(
        _ request: CodexOfficialResponseRequest,
        cancellation: CodexTurnCancellation
    ) -> AsyncThrowingStream<CodexCoreProviderEvent, Error> {
        AsyncThrowingStream { continuation in
            let previousStream = providerStreamTail
            let currentStream = Task {
                await previousStream?.value
                await self.performStream(
                    request,
                    cancellation: cancellation,
                    continuation: continuation
                )
            }
            providerStreamTail = currentStream
        }
    }

    private func performStream(
        _ request: CodexOfficialResponseRequest,
        cancellation: CodexTurnCancellation,
        continuation:
            AsyncThrowingStream<CodexCoreProviderEvent, Error>.Continuation
    ) async {
        let context = CodexProviderStreamContext(
            continuation: continuation,
            cancellation: cancellation
        )
        let opaqueContext = Unmanaged.passRetained(context).toOpaque()
        let contextAddress = UInt(bitPattern: opaqueContext)
        defer {
            let retainedContext = UnsafeMutableRawPointer(
                bitPattern: contextAddress
            )!
            Unmanaged<CodexProviderStreamContext>
                .fromOpaque(retainedContext)
                .release()
        }
        var nativeStream: OpaquePointer?
        var didFinishNativeStream = false
        defer {
            if let nativeStream, !didFinishNativeStream {
                _ = codex_core_native_official_stream_finish(handle, nativeStream)
            }
        }
        do {
            let requestData = try request.encodedData()
            let created = requestData.withUnsafeBytes { bytes in
                var preparedBuffer = CodexCoreBuffer(
                    ptr: nil,
                    len: 0,
                    capacity: 0
                )
                var nativeStream: OpaquePointer?
                let status = codex_core_native_official_stream_create(
                    handle,
                    bytes.bindMemory(to: UInt8.self).baseAddress,
                    bytes.count,
                    codexProviderStreamCallback,
                    UnsafeMutableRawPointer(bitPattern: contextAddress),
                    &preparedBuffer,
                    &nativeStream
                )
                return (status, preparedBuffer, nativeStream)
            }
            let status = created.0
            var preparedBuffer = created.1
            nativeStream = created.2
            defer {
                codex_core_buffer_free(&preparedBuffer)
            }
            // Some Xcode SDKs import the core status enum with a stale case
            // mapping. The native stream creator returns an initialized
            // stream and prepared payload even when that imported value is
            // surfaced as ABI raw value 4; validate the outputs below before
            // treating it as a failure.
            if status != CODEX_CORE_STATUS_NO_EVENT,
               status.rawValue != 4
            {
                try requireSuccess(status)
            }
            guard let stream = nativeStream else {
                throw CodexCoreClientError.network
            }
            let preparedData: Data
            if let pointer = preparedBuffer.ptr, preparedBuffer.len > 0 {
                preparedData = Data(bytes: pointer, count: preparedBuffer.len)
            } else {
                throw CodexCoreClientError.invalidResponseBuffer
            }
            let prepared = try JSONDecoder().decode(
                CodexPreparedOfficialRequest.self,
                from: preparedData
            )
            guard let url = URL(string: prepared.url),
                  let body = Data(base64Encoded: prepared.bodyBase64)
            else {
                throw CodexCoreClientError.invalidArgument
            }
            var urlRequest = URLRequest(url: url)
            urlRequest.httpMethod = prepared.method
            urlRequest.httpBody = body
            for header in prepared.headers {
                urlRequest.addValue(header.value, forHTTPHeaderField: header.name)
            }
            let session = Self.makeSession(proxyURL: prepared.proxyURL)
            let (bytes, response) = try await session.bytes(for: urlRequest)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw CodexCoreClientError.network
            }
            UserDefaults.standard.set(
                "status=\(httpResponse.statusCode) stage=response_headers",
                forKey: "codex.desktop.last-official-provider-http-diagnostic"
            )
            let responseHeaders = httpResponse.allHeaderFields.compactMap {
                key,
                value -> [String: String]?
                in
                guard let name = key as? String else { return nil }
                return ["name": name, "value": String(describing: value)]
            }
            let responseHeadersJSON = try JSONSerialization.data(
                withJSONObject: responseHeaders
            )
            let beginStatus = responseHeadersJSON.withUnsafeBytes { headerBytes in
                codex_core_native_official_stream_begin_response_json(
                    stream,
                    UInt16(clamping: httpResponse.statusCode),
                    headerBytes.bindMemory(to: UInt8.self).baseAddress,
                    headerBytes.count
                )
            }
            try requireSuccess(beginStatus)

            var chunk = Data()
            chunk.reserveCapacity(16 * 1024)
            var bodyBytesReceived = 0
            var diagnosticBody = Data()
            for try await byte in bytes {
                try Task.checkCancellation()
                try cancellation.checkCancellation()
                chunk.append(byte)
                if diagnosticBody.count < 4096 {
                    diagnosticBody.append(byte)
                }
                bodyBytesReceived += 1
                if byte == 0x0A || chunk.count >= 16 * 1024 {
                    let pushStatus = chunk.withUnsafeBytes { bodyBytes in
                        codex_core_native_official_stream_push_body(
                            stream,
                            bodyBytes.bindMemory(to: UInt8.self).baseAddress,
                            bodyBytes.count
                        )
                    }
                    try requireSuccess(pushStatus)
                    chunk.removeAll(keepingCapacity: true)
                }
            }
            if !chunk.isEmpty {
                let pushStatus = chunk.withUnsafeBytes { bodyBytes in
                    codex_core_native_official_stream_push_body(
                        stream,
                        bodyBytes.bindMemory(to: UInt8.self).baseAddress,
                        bodyBytes.count
                    )
                }
                try requireSuccess(pushStatus)
            }
            UserDefaults.standard.set(
                "status=\(httpResponse.statusCode) stage=body_complete bytes=\(bodyBytesReceived)",
                forKey: "codex.desktop.last-official-provider-http-diagnostic"
            )
            if !(200..<300).contains(httpResponse.statusCode) {
                UserDefaults.standard.set(
                    CodexOfficialProviderHTTPDiagnostic.summary(
                        status: httpResponse.statusCode,
                        bytes: bodyBytesReceived,
                        body: diagnosticBody
                    ),
                    forKey: "codex.desktop.last-official-provider-http-diagnostic"
                )
            }
            try cancellation.checkCancellation()
            let endStatus = codex_core_native_official_stream_end_body(stream)
            try requireSuccess(endStatus)
            let finishStatus = codex_core_native_official_stream_finish(
                handle,
                stream
            )
            didFinishNativeStream = true
            try requireSuccess(finishStatus)
            context.finish(with: nil)
        } catch let error as URLError where error.code == .timedOut {
            // URLSession can outlive the renderer's turn budget when a
            // provider never sends response headers. Normalize that native
            // timeout to the same terminal error used by the stream deadline
            // so the turn runner stops Thinking instead of retrying forever.
            if let stream = nativeStream, !didFinishNativeStream {
                _ = codex_core_native_official_stream_cancel(stream)
                _ = codex_core_native_official_stream_finish(handle, stream)
                didFinishNativeStream = true
            }
            context.finish(with: CodexOfficialProviderActivityTimeoutError())
        } catch is CancellationError {
            if let stream = nativeStream, !didFinishNativeStream {
                _ = codex_core_native_official_stream_cancel(stream)
                let status = codex_core_native_official_stream_finish(
                    handle,
                    stream
                )
                didFinishNativeStream = true
                _ = status
            }
            context.finish(with: CancellationError())
        } catch {
            let diagnosticKey =
                "codex.desktop.last-official-provider-http-diagnostic"
            if UserDefaults.standard.string(forKey: diagnosticKey) == nil {
                UserDefaults.standard.set(
                    "stage=client_error type=\(String(describing: type(of: error)))",
                    forKey: diagnosticKey
                )
            }
            if let stream = nativeStream, !didFinishNativeStream {
                _ = codex_core_native_official_stream_finish(handle, stream)
                didFinishNativeStream = true
            }
            context.finish(with: error)
        }
    }

    private func requireSuccess(_ status: CodexCoreStatus) throws {
        switch status {
        case CODEX_CORE_STATUS_OK:
            return
        case CODEX_CORE_STATUS_INVALID_ARGUMENT:
            throw CodexCoreClientError.invalidArgument
        case CODEX_CORE_STATUS_INVALID_JSON:
            throw CodexCoreClientError.invalidJSON
        case CODEX_CORE_STATUS_UNSUPPORTED_COMMAND:
            throw CodexCoreClientError.unsupportedCommand
        case CODEX_CORE_STATUS_PANIC:
            throw CodexCoreClientError.corePanic
        case CODEX_CORE_STATUS_STORAGE:
            throw CodexCoreClientError.storage
        case CODEX_CORE_STATUS_NETWORK:
            throw CodexCoreClientError.network
        case CODEX_CORE_STATUS_CANCELLED:
            throw CancellationError()
        default:
            throw CodexCoreClientError.unexpectedStatus(
                rawValue: Int32(status.rawValue)
            )
        }
    }

    static func makeSession(proxyURL: String?) -> URLSession {
        // The native core may include the desktop process' local proxy in its
        // prepared request. That endpoint is meaningful on macOS only, so do
        // not apply proxyURL here. Leave the configuration's proxy dictionary
        // untouched so URLSession can still use the iPadOS system proxy or VPN.
        let configuration = URLSessionConfiguration.ephemeral
        // Keep transport failure bounded at the same order as the released
        // turn activity budget. A stalled provider must reach the UI's
        // terminal error state promptly rather than hold a turn open for
        // several minutes after the stream deadline has elapsed.
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 90
        configuration.waitsForConnectivity = true
        configuration.allowsExpensiveNetworkAccess = true
        configuration.allowsConstrainedNetworkAccess = true
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        // The preparation request may establish the device-check/session
        // cookie that the streaming endpoint requires. Keep the session
        // isolated from cache while sharing the product cookie jar.
        configuration.httpShouldSetCookies = true
        configuration.httpCookieStorage = HTTPCookieStorage.shared
        configuration.httpCookieAcceptPolicy = .always
        return URLSession(configuration: configuration)
    }
}
#endif
