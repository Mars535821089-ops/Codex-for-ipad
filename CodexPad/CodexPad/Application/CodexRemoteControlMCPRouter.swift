#if SWIFT_PACKAGE
    import CodexPadDomain
    import CodexPadProtocolBridge
#endif
import Foundation

/// Routes the seven released remote-control MCP methods to the long-lived
/// service actor. Unknown methods deliberately fall through to the remaining
/// desktop router chain.
public enum CodexRemoteControlMCPRouter {
    private enum ParamsError: Error {
        case invalid
    }

    public static func response(
        to request: CodexDesktopMCPRequest,
        service: CodexRemoteControlService
    ) async -> CodexDesktopHostMessage? {
        guard isRemoteControlMethod(request.request.method) else {
            return nil
        }

        do {
            let value: CodexJSONValue
            switch request.request.method {
            case "remoteControl/enable":
                let params: CodexRemoteControlEnableParams = try decodeOptionalObject(
                    request.request.params,
                    default: .init()
                )
                value = try encodeResult(await service.enable(params))

            case "remoteControl/disable":
                let params: CodexRemoteControlDisableParams = try decodeOptionalObject(
                    request.request.params,
                    default: .init()
                )
                value = try encodeResult(await service.disable(params))

            case "remoteControl/status/read":
                guard hasUnitParams(request.request.params) else {
                    throw ParamsError.invalid
                }
                value = try encodeResult(await service.statusRead())

            case "remoteControl/pairing/start":
                let params: CodexRemoteControlPairingStartParams = try decodeRequiredObject(
                    request.request.params
                )
                value = try encodeResult(await service.pairingStart(params))

            case "remoteControl/pairing/status":
                let params: CodexRemoteControlPairingStatusParams = try decodeRequiredObject(
                    request.request.params
                )
                guard (params.pairingCode == nil) != (params.manualPairingCode == nil) else {
                    throw ParamsError.invalid
                }
                value = try encodeResult(await service.pairingStatus(params))

            case "remoteControl/client/list":
                let params: CodexRemoteControlClientsListParams = try decodeRequiredObject(
                    request.request.params
                )
                guard !params.environmentId.isEmpty,
                      params.limit.map({ (1 ... 100).contains($0) }) ?? true
                else {
                    throw ParamsError.invalid
                }
                value = try encodeResult(await service.clientsList(params))

            case "remoteControl/client/revoke":
                let params: CodexRemoteControlClientsRevokeParams = try decodeRequiredObject(
                    request.request.params
                )
                guard !params.environmentId.isEmpty, !params.clientId.isEmpty else {
                    throw ParamsError.invalid
                }
                value = try encodeResult(await service.clientsRevoke(params))

            default:
                return nil
            }
            return result(request, value: value)
        } catch is ParamsError {
            return invalidParams(request)
        } catch is DecodingError {
            return invalidParams(request)
        } catch {
            return internalError(request)
        }
    }

    private static func isRemoteControlMethod(_ method: String) -> Bool {
        switch method {
        case "remoteControl/enable",
             "remoteControl/disable",
             "remoteControl/status/read",
             "remoteControl/pairing/start",
             "remoteControl/pairing/status",
             "remoteControl/client/list",
             "remoteControl/client/revoke":
            return true
        default:
            return false
        }
    }

    private static func decodeOptionalObject<Value: Decodable>(
        _ params: CodexJSONValue?,
        default defaultValue: @autoclosure () -> Value
    ) throws -> Value {
        switch params {
        case nil, .null:
            return defaultValue()
        case .object:
            return try decodeRequiredObject(params)
        default:
            throw ParamsError.invalid
        }
    }

    private static func decodeRequiredObject<Value: Decodable>(
        _ params: CodexJSONValue?
    ) throws -> Value {
        guard case .object? = params, let params else {
            throw ParamsError.invalid
        }
        return try JSONDecoder().decode(
            Value.self,
            from: JSONEncoder().encode(params)
        )
    }

    private static func hasUnitParams(_ params: CodexJSONValue?) -> Bool {
        switch params {
        case nil, .null:
            return true
        case let .object(fields):
            return fields.isEmpty
        default:
            return false
        }
    }

    private static func encodeResult<Value: Encodable>(
        _ value: Value
    ) throws -> CodexJSONValue {
        try JSONDecoder().decode(
            CodexJSONValue.self,
            from: JSONEncoder().encode(value)
        )
    }

    private static func result(
        _ request: CodexDesktopMCPRequest,
        value: CodexJSONValue
    ) -> CodexDesktopHostMessage {
        .mcpResponse(
            hostID: request.hostID,
            message: .object([
                "id": requestIDValue(request.request.id),
                "result": value,
            ]),
            metadata: [:]
        )
    }

    private static func invalidParams(
        _ request: CodexDesktopMCPRequest
    ) -> CodexDesktopHostMessage {
        error(
            request,
            code: -32602,
            message: "Invalid params for \(request.request.method)"
        )
    }

    private static func internalError(
        _ request: CodexDesktopMCPRequest
    ) -> CodexDesktopHostMessage {
        error(
            request,
            code: -32603,
            message: "Remote control request failed"
        )
    }

    private static func error(
        _ request: CodexDesktopMCPRequest,
        code: Int64,
        message: String
    ) -> CodexDesktopHostMessage {
        .mcpResponse(
            hostID: request.hostID,
            message: .object([
                "id": requestIDValue(request.request.id),
                "error": .object([
                    "code": .integer(code),
                    "message": .string(message),
                ]),
            ]),
            metadata: [:]
        )
    }

    private static func requestIDValue(
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
