#if SWIFT_PACKAGE
import CodexPadDomain
#endif
import Foundation

public typealias CodexMCPServerRequestHandler =
    @Sendable (
        _ method: String,
        _ params: CodexJSONValue?
    ) async throws -> CodexJSONValue

enum CodexMCPServerRequestError: Swift.Error, Equatable, Sendable {
    case invalidRequest
}

enum CodexMCPServerRequest {
    static func response(
        for value: CodexJSONValue,
        serverName: String,
        contextMeta: CodexJSONValue?,
        handler: CodexMCPServerRequestHandler?
    ) async throws -> CodexJSONValue? {
        guard let handler,
              case let .object(fields) = value,
              let id = fields["id"],
              case let .string(method)? = fields["method"],
              method == "elicitation/create" || method == "openai/form"
        else {
            return nil
        }
        guard case let .object(rawParams)? = fields["params"] else {
            throw CodexMCPServerRequestError.invalidRequest
        }
        let params = try normalizedParams(
            rawParams,
            method: method,
            serverName: serverName,
            contextMeta: contextMeta
        )
        let result = try await handler(
            "mcpServer/elicitation/request",
            .object(params)
        )
        return .object([
            "jsonrpc": .string("2.0"),
            "id": id,
            "result": result,
        ])
    }

    private static func normalizedParams(
        _ rawParams: [String: CodexJSONValue],
        method: String,
        serverName: String,
        contextMeta: CodexJSONValue?
    ) throws -> [String: CodexJSONValue] {
        guard case let .object(context)? = contextMeta,
              case let .string(threadID)? = context["threadId"],
              !threadID.isEmpty
        else {
            throw CodexMCPServerRequestError.invalidRequest
        }
        var params = rawParams
        params["threadId"] = .string(threadID)
        params["turnId"] = context["turnId"] ?? .null
        params["serverName"] = .string(serverName)
        if method == "openai/form" {
            params["mode"] = .string("openai/form")
        } else if params["mode"] == nil {
            params["mode"] = .string("form")
        }
        return params
    }
}
