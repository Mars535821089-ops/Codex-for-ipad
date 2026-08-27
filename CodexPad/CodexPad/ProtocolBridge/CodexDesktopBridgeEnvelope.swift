#if SWIFT_PACKAGE
    import CodexPadDomain
#endif
import Foundation

public enum CodexDesktopBridgeError:
    Error,
    Equatable,
    Sendable
{
    case invalidPayload
    case unsupportedType(String)
    case invalidFetchURL
    case invalidHTTPMethod
    case invalidMCPRequest
    case invalidEventPayload
    case invalidSystemThemeVariant
}

public struct CodexDesktopLogMessage: Equatable, Sendable {
    public let level: String
    public let message: String
    public let tags: CodexJSONValue?

    public var diagnosticDescription: String {
        let base = "renderer[\(level)] \(message)"
        guard
            let tags,
            let data = try? JSONEncoder.sortedDiagnostic.encode(tags),
            let encodedTags = String(data: data, encoding: .utf8)
        else {
            return base
        }
        return "\(base) tags=\(encodedTags)"
    }

    public init(
        level: String,
        message: String,
        tags: CodexJSONValue?
    ) {
        self.level = level
        self.message = message
        self.tags = tags
    }
}

private extension JSONEncoder {
    static var sortedDiagnostic: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}

public struct CodexDesktopFetchRequest: Equatable, Sendable {
    public let requestID: String
    public let method: String
    public let url: String
    public let hostMethod: String
    public let headers: [String: String]?
    public let body: String?
    public let reportUploadProgress: Bool

    /// The released Electron bridge uses `vscode://codex/` only for local
    /// VS Code host RPC.  All HTTP(S) and relative URLs are ordinary network
    /// fetches and must be answered with a `fetch-response` message as well.
    public var isVSCodeHostRequest: Bool {
        url.hasPrefix("vscode://codex/")
    }

    public var isNetworkRequest: Bool {
        !isVSCodeHostRequest
    }

    public init(
        requestID: String,
        method: String,
        url: String,
        hostMethod: String,
        headers: [String: String]?,
        body: String?,
        reportUploadProgress: Bool
    ) {
        self.requestID = requestID
        self.method = method
        self.url = url
        self.hostMethod = hostMethod
        self.headers = headers
        self.body = body
        self.reportUploadProgress = reportUploadProgress
    }
}

public struct CodexDesktopFetchStreamRequest: Equatable, Sendable {
    public let requestID: String
    public let method: String
    public let url: String
    public let headers: [String: String]?
    public let body: String?
    public let format: String?

    public init(
        requestID: String,
        method: String,
        url: String,
        headers: [String: String]?,
        body: String?,
        format: String?
    ) {
        self.requestID = requestID
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
        self.format = format
    }
}

public struct CodexDesktopOpenInBrowserRequest: Equatable, Sendable {
    public let url: String
    public let initiator: String
    public let openTarget: String
    public let source: String

    public init(
        url: String,
        initiator: String,
        openTarget: String,
        source: String
    ) {
        self.url = url
        self.initiator = initiator
        self.openTarget = openTarget
        self.source = source
    }
}

public struct CodexDesktopMCPRequestMessage: Equatable, Sendable {
    public let id: CodexAppServerRequestID
    public let method: String
    public let params: CodexJSONValue?
    public let metadata: [String: CodexJSONValue]

    public init(
        id: CodexAppServerRequestID,
        method: String,
        params: CodexJSONValue?,
        metadata: [String: CodexJSONValue]
    ) {
        self.id = id
        self.method = method
        self.params = params
        self.metadata = metadata
    }
}

public struct CodexDesktopMCPRequest: Equatable, Sendable {
    public let request: CodexDesktopMCPRequestMessage
    public let hostID: String
    public let dispatchedAtMs: CodexJSONValue?
    public let priority: CodexJSONValue?
    public let source: CodexJSONValue?
    public let timeoutMs: CodexJSONValue?
    public let expiresAtMs: CodexJSONValue?
    public let metadata: [String: CodexJSONValue]

    public init(
        request: CodexDesktopMCPRequestMessage,
        hostID: String,
        dispatchedAtMs: CodexJSONValue?,
        priority: CodexJSONValue?,
        source: CodexJSONValue?,
        timeoutMs: CodexJSONValue?,
        expiresAtMs: CodexJSONValue?,
        metadata: [String: CodexJSONValue]
    ) {
        self.request = request
        self.hostID = hostID
        self.dispatchedAtMs = dispatchedAtMs
        self.priority = priority
        self.source = source
        self.timeoutMs = timeoutMs
        self.expiresAtMs = expiresAtMs
        self.metadata = metadata
    }
}

public struct CodexDesktopMCPClientResponse: Equatable, Sendable {
    public let id: CodexAppServerRequestID
    public let result: CodexJSONValue?
    public let error: CodexJSONValue?

    public init(
        id: CodexAppServerRequestID,
        result: CodexJSONValue?,
        error: CodexJSONValue?
    ) {
        self.id = id
        self.result = result
        self.error = error
    }
}

public struct CodexDesktopPersistedAtomUpdate: Equatable, Sendable {
    public let key: String
    public let value: CodexJSONValue?
    public let deleted: Bool

    public init(
        key: String,
        value: CodexJSONValue?,
        deleted: Bool
    ) {
        self.key = key
        self.value = value
        self.deleted = deleted
    }
}

public enum CodexDesktopViewMessage: Equatable, Sendable {
    case ready
    case viewFocused
    case logMessage(CodexDesktopLogMessage)
    case fetch(CodexDesktopFetchRequest)
    case fetchStream(CodexDesktopFetchStreamRequest)
    case cancelFetchStream(requestID: String)
    case openInBrowser(CodexDesktopOpenInBrowserRequest)
    case mcpRequest(CodexDesktopMCPRequest)
    case mcpResponse(
        hostID: String,
        response: CodexDesktopMCPClientResponse
    )
    case persistedAtomSyncRequest
    case persistedAtomUpdate(CodexDesktopPersistedAtomUpdate)
    case sharedObjectSubscribe(key: String)
    case sharedObjectUnsubscribe(key: String)
    case sharedObjectSet(key: String, value: CodexJSONValue?)
    case viewEvent(type: String, payload: CodexJSONValue)
}

public enum CodexDesktopHostMessage: Equatable, Sendable {
    case fetchSuccess(
        requestID: String,
        status: Int,
        headers: [String: String],
        body: CodexJSONValue
    )
    case fetchFailure(
        requestID: String,
        status: Int,
        error: String,
        errorCode: String?
    )
    case mcpResponse(
        hostID: String,
        message: CodexJSONValue,
        metadata: [String: CodexJSONValue]
    )
    case mcpNotification(
        hostID: String,
        method: String,
        params: CodexJSONValue,
        metadata: [String: CodexJSONValue]
    )
    case mcpRequest(
        hostID: String,
        request: CodexDesktopMCPRequestMessage,
        metadata: [String: CodexJSONValue]
    )
    case event(type: String, payload: CodexJSONValue)
}

public enum CodexDesktopBridgeCodec {
    private static let hostRPCPrefix = "vscode://codex/"

    public static func decodeViewPayload(
        _ data: Data
    ) throws -> CodexDesktopViewMessage {
        let wire: ViewMessageWire
        do {
            wire = try JSONDecoder().decode(ViewMessageWire.self, from: data)
        } catch {
            throw CodexDesktopBridgeError.invalidPayload
        }

        switch wire.type {
        case "ready":
            return .ready
        case "view-focused":
            return .viewFocused
        case "log-message":
            guard let level = wire.level, let message = wire.message else {
                throw CodexDesktopBridgeError.invalidPayload
            }
            return .logMessage(
                CodexDesktopLogMessage(
                    level: level,
                    message: message,
                    tags: wire.tags
                )
            )
        case "persisted-atom-sync-request":
            return .persistedAtomSyncRequest
        case "persisted-atom-update":
            let fields = try decodeObject(data)
            guard case let .string(key)? = fields["key"], !key.isEmpty else {
                throw CodexDesktopBridgeError.invalidPayload
            }
            let hasValue = fields.keys.contains("value")
            let value = fields["value"]
            let deleted: Bool
            switch fields["deleted"] {
            case let .bool(flag)?:
                // The released renderer marks an undefined value as a
                // deletion. An omitted value has the same effect even when
                // a legacy caller omitted the explicit marker.
                deleted = flag || !hasValue
            case nil:
                deleted = !hasValue
            default:
                throw CodexDesktopBridgeError.invalidPayload
            }
            return .persistedAtomUpdate(
                CodexDesktopPersistedAtomUpdate(
                    key: key,
                    value: value,
                    deleted: deleted
                )
            )
        case "shared-object-subscribe":
            guard let key = wire.key, !key.isEmpty else {
                throw CodexDesktopBridgeError.invalidPayload
            }
            return .sharedObjectSubscribe(key: key)
        case "shared-object-unsubscribe":
            guard let key = wire.key, !key.isEmpty else {
                throw CodexDesktopBridgeError.invalidPayload
            }
            return .sharedObjectUnsubscribe(key: key)
        case "shared-object-set":
            guard let key = wire.key, !key.isEmpty else {
                throw CodexDesktopBridgeError.invalidPayload
            }
            // Optional CodexJSONValue preserves the distinction required by
            // the released preload: an omitted value is JavaScript
            // `undefined` (delete), while an explicit JSON null is retained.
            let fields = try decodeObject(data)
            return .sharedObjectSet(key: key, value: fields["value"])
        case "fetch":
            guard let requestID = wire.requestID,
                  !requestID.isEmpty,
                  let method = wire.method,
                  !method.isEmpty,
                  let url = wire.url
            else {
                throw CodexDesktopBridgeError.invalidPayload
            }
            guard method == method.uppercased() else {
                throw CodexDesktopBridgeError.invalidHTTPMethod
            }
            let hostMethod: String
            if url.hasPrefix(hostRPCPrefix) {
                hostMethod = String(url.dropFirst(hostRPCPrefix.count))
                guard !hostMethod.isEmpty else {
                    throw CodexDesktopBridgeError.invalidFetchURL
                }
            } else {
                // The desktop renderer emits both absolute product URLs
                // (for example Statsig) and relative product API paths
                // (for example `/wham/...`).  Leave full URL policy and
                // resolution to the network fetch client, but reject
                // obviously executable/non-network schemes at the bridge
                // boundary so they can never reach URLSession.
                guard Self.isPotentialNetworkURL(url) else {
                    throw CodexDesktopBridgeError.invalidFetchURL
                }
                hostMethod = ""
            }
            return .fetch(
                CodexDesktopFetchRequest(
                    requestID: requestID,
                    method: method,
                    url: url,
                    hostMethod: hostMethod,
                    headers: wire.headers,
                    body: wire.body,
                    reportUploadProgress:
                        wire.reportUploadProgress ?? false
                )
            )
        case "fetch-stream":
            guard let requestID = wire.requestID,
                  !requestID.isEmpty,
                  let method = wire.method,
                  method == method.uppercased(),
                  let url = wire.url,
                  Self.isPotentialNetworkURL(url),
                  wire.format == nil
                    || wire.format == "sse"
                    || wire.format == "ndjson"
            else {
                throw CodexDesktopBridgeError.invalidPayload
            }
            return .fetchStream(
                CodexDesktopFetchStreamRequest(
                    requestID: requestID,
                    method: method,
                    url: url,
                    headers: wire.headers,
                    body: wire.body,
                    format: wire.format
                )
            )
        case "cancel-fetch-stream":
            guard let requestID = wire.requestID,
                  !requestID.isEmpty
            else {
                throw CodexDesktopBridgeError.invalidPayload
            }
            return .cancelFetchStream(requestID: requestID)
        case "open-in-browser":
            guard let url = wire.url,
                  !url.isEmpty,
                  let initiator = wire.initiator,
                  !initiator.isEmpty,
                  let openTarget = wire.openTarget,
                  !openTarget.isEmpty,
                  let source = wire.source,
                  !source.isEmpty
            else {
                throw CodexDesktopBridgeError.invalidPayload
            }
            return .openInBrowser(
                CodexDesktopOpenInBrowserRequest(
                    url: url,
                    initiator: initiator,
                    openTarget: openTarget,
                    source: source
                )
            )
        case "mcp-request", "thread-prewarm-start":
            return .mcpRequest(try decodeMCPRequest(data))
        case "mcp-response":
            return try decodeMCPResponse(data)
        default:
            guard Self.knownNoOpViewMessageTypes.contains(wire.type) else {
                throw CodexDesktopBridgeError.unsupportedType(wire.type)
            }
            var fields = try decodeObject(data)
            fields.removeValue(forKey: "type")
            return .viewEvent(
                type: wire.type,
                payload: .object(fields)
            )
        }
    }

    private static func isPotentialNetworkURL(_ value: String) -> Bool {
        guard !value.isEmpty else {
            return false
        }
        if value.hasPrefix("/") {
            return true
        }
        guard let components = URLComponents(string: value) else {
            return false
        }
        guard let scheme = components.scheme?.lowercased() else {
            // A bare relative path is accepted by Electron's URL resolver.
            return !value.contains(":")
        }
        return scheme == "http" || scheme == "https" || scheme == "data"
    }

    public static func encodeHostPayload(
        _ message: CodexDesktopHostMessage
    ) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]

        switch message {
        case let .fetchSuccess(requestID, status, headers, body):
            let bodyData = try encoder.encode(body)
            guard let bodyJSON = String(data: bodyData, encoding: .utf8) else {
                throw CodexDesktopBridgeError.invalidPayload
            }
            return try encoder.encode(
                FetchSuccessWire(
                    type: "fetch-response",
                    requestID: requestID,
                    responseType: "success",
                    status: status,
                    headers: headers,
                    bodyJSON: bodyJSON
                )
            )
        case let .fetchFailure(requestID, status, error, errorCode):
            return try encoder.encode(
                FetchFailureWire(
                    type: "fetch-response",
                    requestID: requestID,
                    responseType: "error",
                    status: status,
                    error: error,
                    errorCode: errorCode
                )
            )
        case let .mcpResponse(hostID, message, metadata):
            guard !hostID.isEmpty, case .object = message else {
                throw CodexDesktopBridgeError.invalidPayload
            }
            var fields = metadata
            fields["type"] = .string("mcp-response")
            fields["hostId"] = .string(hostID)
            fields["message"] = message
            return try encoder.encode(CodexJSONValue.object(fields))
        case let .mcpNotification(hostID, method, params, metadata):
            guard !hostID.isEmpty,
                  !method.isEmpty,
                  case .object = params
            else {
                throw CodexDesktopBridgeError.invalidPayload
            }
            var fields = metadata
            fields["type"] = .string("mcp-notification")
            fields["hostId"] = .string(hostID)
            fields["method"] = .string(method)
            fields["params"] = params
            return try encoder.encode(CodexJSONValue.object(fields))
        case let .mcpRequest(hostID, request, metadata):
            guard !hostID.isEmpty, !request.method.isEmpty else {
                throw CodexDesktopBridgeError.invalidPayload
            }
            var requestFields = request.metadata
            requestFields["id"] = requestIDJSON(request.id)
            requestFields["method"] = .string(request.method)
            if let params = request.params {
                requestFields["params"] = params
            }
            var fields = metadata
            fields["type"] = .string("mcp-request")
            fields["hostId"] = .string(hostID)
            fields["request"] = .object(requestFields)
            return try encoder.encode(CodexJSONValue.object(fields))
        case let .event(type, payload):
            guard case var .object(fields) = payload else {
                throw CodexDesktopBridgeError.invalidEventPayload
            }
            // Electron's persisted-atom broadcaster always includes
            // `value: null` when `deleted` is true. Keep that marker on the
            // WKWebView wire even though the native store represents the
            // deletion as an absent value.
            if type == "persisted-atom-updated",
               fields["deleted"] == .bool(true)
            {
                fields["value"] = .null
            }
            fields["type"] = .string(type)
            return try encoder.encode(CodexJSONValue.object(fields))
        }
    }

    private static let knownNoOpViewMessageTypes: Set<String> = [
        // The released renderer sends these host commands through the
        // preload bridge when the sidebar New Chat action is tapped. They
        // are decoded as view events so the native host can route them.
        "new-chat",
        "new-projectless-task",
        "remote-hosted-pip-active-thread-changed",
        "remote-hosted-pip-host-layout-changed",
        "browser-use-session-route-capture",
        "browser-sidebar-annotation-multi-select-enabled-changed",
        "browser-sidebar-tweaks-enabled-changed",
        "electron-app-state-snapshot-trigger",
        "electron-set-window-mode",
        "workspace-settings-webview-presentation-changed",
        "electron-window-focus-request",
        "electron-window-zoom-changed",
        "local-thread-activity-changed",
        "avatar-overlay-open-state-request",
        "avatar-overlay-open",
        "avatar-overlay-close",
        "avatar-overlay-hide",
        "avatar-overlay-drag-start",
        "avatar-overlay-drag-move",
        "avatar-overlay-drag-end",
        "avatar-overlay-drag-release",
        "avatar-overlay-mascot-resize-start",
        "avatar-overlay-mascot-resize-move",
        "avatar-overlay-mascot-resize-end",
        "avatar-overlay-element-size-changed",
        "avatar-overlay-composition-changed",
        "avatar-overlay-composition-surface-action",
        "avatar-overlay-pointer-interaction-changed",
        "avatar-overlay-keyboard-interaction-changed",
        "browser-sidebar-owner-sync",
        "checkout-webview-presentation-changed",
        "codex-runtimes-config-changed",
        "keyboard-layout-map-changed",
        "mac-menu-bar-enabled-changed",
        "electron-set-badge-count",
        "power-save-blocker-set",
        "remote-hosted-pip-hidden-thread-ids-changed",
        "tray-menu-threads-changed",
        "electron-avatar-overlay-restore-ready",
        "electron-avatar-overlay-feedback-diagnostics-changed",
        "electron-sparkle-gates-changed",
        "electron-desktop-features-changed",
        "global-dictation-enabled-changed",
        "heartbeat-automations-enabled-changed",
        "set-telemetry-user",
        "heartbeat-automation-thread-state-changed",
        "app-shell-shortcut-state-changed",
        "inbox-item-set-read-state",
        "inbox-automation-runs-mark-all-read",
        "reload-bundled-plugins",
        "browser-sidebar-attach-dragged-image",
        "debug-window-origin-conversation-changed",
        "browser-settings-webview-mounted",
        "browser-settings-webview-unmounted",
        "browser-settings-webview-theme-changed",
        "electron-add-new-workspace-root-option",
        "electron-create-new-workspace-root-option",
        "electron-pick-workspace-root-option",
        "electron-update-workspace-root-options",
        "electron-onboarding-skip-workspace",
        "electron-onboarding-pick-workspace-or-create-default",
        "electron-rename-workspace-root-option",
        "electron-set-active-workspace-root",
        "electron-clear-active-workspace-root",
        // The released sidebar asks Electron to reopen the renderer-owned
        // combined chat search / command menu. Electron answers by sending
        // this exact event back to the same window.
        "chat-search-command-menu",
    ]

    private static func decodeObject(
        _ data: Data
    ) throws -> [String: CodexJSONValue] {
        let root: CodexJSONValue
        do {
            root = try JSONDecoder().decode(CodexJSONValue.self, from: data)
        } catch {
            throw CodexDesktopBridgeError.invalidPayload
        }
        guard case let .object(fields) = root else {
            throw CodexDesktopBridgeError.invalidPayload
        }
        return fields
    }

    private static func decodeMCPRequest(
        _ data: Data
    ) throws -> CodexDesktopMCPRequest {
        let root: CodexJSONValue
        do {
            root = try JSONDecoder().decode(CodexJSONValue.self, from: data)
        } catch {
            throw CodexDesktopBridgeError.invalidMCPRequest
        }
        guard case var .object(fields) = root,
              case let .string(messageType)? =
                  fields.removeValue(forKey: "type"),
              messageType == "mcp-request"
                  || messageType == "thread-prewarm-start",
              case let .string(hostID)? =
                  fields.removeValue(forKey: "hostId"),
              !hostID.isEmpty,
              case var .object(requestFields)? =
                  fields.removeValue(forKey: "request")
        else {
            throw CodexDesktopBridgeError.invalidMCPRequest
        }

        let id: CodexAppServerRequestID
        switch requestFields.removeValue(forKey: "id") {
        case let .string(value)?:
            id = .string(value)
        case let .integer(value)?:
            id = .integer(value)
        default:
            throw CodexDesktopBridgeError.invalidMCPRequest
        }
        guard case let .string(method)? =
            requestFields.removeValue(forKey: "method"),
            !method.isEmpty
        else {
            throw CodexDesktopBridgeError.invalidMCPRequest
        }
        let params = requestFields.removeValue(forKey: "params")
        let dispatchedAtMs = fields.removeValue(
            forKey: "dispatchedAtMs"
        )
        let priority = fields.removeValue(forKey: "priority")
        let source = fields.removeValue(forKey: "source")
        let timeoutMs = fields.removeValue(forKey: "timeoutMs")
        let expiresAtMs = fields.removeValue(forKey: "expiresAtMs")

        return CodexDesktopMCPRequest(
            request: CodexDesktopMCPRequestMessage(
                id: id,
                method: method,
                params: params,
                metadata: requestFields
            ),
            hostID: hostID,
            dispatchedAtMs: dispatchedAtMs,
            priority: priority,
            source: source,
            timeoutMs: timeoutMs,
            expiresAtMs: expiresAtMs,
            metadata: fields
        )
    }

    private static func decodeMCPResponse(
        _ data: Data
    ) throws -> CodexDesktopViewMessage {
        var fields = try decodeObject(data)
        guard fields.removeValue(forKey: "type") ==
                .string("mcp-response"),
              case let .string(hostID)? =
                fields.removeValue(forKey: "hostId"),
              !hostID.isEmpty,
              case var .object(response)? =
                fields.removeValue(forKey: "response")
        else {
            throw CodexDesktopBridgeError.invalidPayload
        }
        let id: CodexAppServerRequestID
        switch response.removeValue(forKey: "id") {
        case let .string(value)?:
            id = .string(value)
        case let .integer(value)?:
            id = .integer(value)
        default:
            throw CodexDesktopBridgeError.invalidPayload
        }
        let result = response.removeValue(forKey: "result")
        let error = response.removeValue(forKey: "error")
        guard (result != nil) != (error != nil),
              response.isEmpty
        else {
            throw CodexDesktopBridgeError.invalidPayload
        }
        return .mcpResponse(
            hostID: hostID,
            response: CodexDesktopMCPClientResponse(
                id: id,
                result: result,
                error: error
            )
        )
    }

    private static func requestIDJSON(
        _ id: CodexAppServerRequestID
    ) -> CodexJSONValue {
        switch id {
        case let .string(value):
            return .string(value)
        case let .integer(value):
            return .integer(value)
        }
    }
}

private struct ViewMessageWire: Decodable {
    let type: String
    let level: String?
    let message: String?
    let tags: CodexJSONValue?
    let requestID: String?
    let method: String?
    let url: String?
    let initiator: String?
    let openTarget: String?
    let source: String?
    let headers: [String: String]?
    let body: String?
    let reportUploadProgress: Bool?
    let format: String?
    let key: String?
    let value: CodexJSONValue?
    let deleted: Bool?

    private enum CodingKeys: String, CodingKey {
        case type
        case level
        case message
        case tags
        case requestID = "requestId"
        case method
        case url
        case initiator
        case openTarget
        case source
        case headers
        case body
        case reportUploadProgress
        case format
        case key
        case value
        case deleted
    }
}

private struct FetchSuccessWire: Encodable {
    let type: String
    let requestID: String
    let responseType: String
    let status: Int
    let headers: [String: String]
    let bodyJSON: String

    private enum CodingKeys: String, CodingKey {
        case type
        case requestID = "requestId"
        case responseType
        case status
        case headers
        case bodyJSON = "bodyJsonString"
    }
}

private struct FetchFailureWire: Encodable {
    let type: String
    let requestID: String
    let responseType: String
    let status: Int
    let error: String
    let errorCode: String?

    private enum CodingKeys: String, CodingKey {
        case type
        case requestID = "requestId"
        case responseType
        case status
        case error
        case errorCode
    }
}
