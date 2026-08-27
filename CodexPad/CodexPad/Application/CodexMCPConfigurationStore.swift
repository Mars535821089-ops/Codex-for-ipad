#if SWIFT_PACKAGE
import CodexPadDomain
#endif
import Foundation

public enum CodexMCPServerConfigurationError: Error, Equatable, Sendable {
    case invalidShape(String), invalidTransport
    case unsupportedEnvironmentSource(String)
    case invalidServerName, encodingFailed
}

public enum CodexMCPServerEnvironmentVariable: Equatable, Sendable {
    case name(String)
    case config(name: String, source: String?)
}

public enum CodexMCPServerTransport: Equatable, Sendable {
    case stdio(command: String, args: [String], env: [String: String]?, envVars: [CodexMCPServerEnvironmentVariable], cwd: String?)
    case streamableHTTP(url: String, bearerTokenEnvVar: String?, httpHeaders: [String: String]?, envHTTPHeaders: [String: String]?)
}

public enum CodexMCPServerAuth: String, Equatable, Sendable { case oauth; case chatGPT = "chatgpt" }

public struct CodexMCPServerConfiguration: Equatable, Sendable {
    public let transport: CodexMCPServerTransport
    public let auth: CodexMCPServerAuth
    public let environmentID: String
    public let enabled: Bool
    public let required: Bool
    public let supportsParallelToolCalls: Bool
    public let startupTimeoutSeconds: Double?
    public let toolTimeoutSeconds: Double?
    public let defaultToolsApprovalMode: String?
    public let enabledTools: [String]?
    public let disabledTools: [String]?
    public let scopes: [String]?
    public let oauthClientID: String?
    public let oauthResource: String?
    public let toolApprovalModes: [String: String]

    public init(
        transport: CodexMCPServerTransport,
        auth: CodexMCPServerAuth = .oauth,
        environmentID: String = "local",
        enabled: Bool = true,
        required: Bool = false,
        supportsParallelToolCalls: Bool = false,
        startupTimeoutSeconds: Double? = nil,
        toolTimeoutSeconds: Double? = nil,
        defaultToolsApprovalMode: String? = nil,
        enabledTools: [String]? = nil,
        disabledTools: [String]? = nil,
        scopes: [String]? = nil,
        oauthClientID: String? = nil,
        oauthResource: String? = nil,
        toolApprovalModes: [String: String] = [:]
    ) {
        self.transport = transport
        self.auth = auth
        self.environmentID = environmentID
        self.enabled = enabled
        self.required = required
        self.supportsParallelToolCalls = supportsParallelToolCalls
        self.startupTimeoutSeconds = startupTimeoutSeconds
        self.toolTimeoutSeconds = toolTimeoutSeconds
        self.defaultToolsApprovalMode = defaultToolsApprovalMode
        self.enabledTools = enabledTools
        self.disabledTools = disabledTools
        self.scopes = scopes
        self.oauthClientID = oauthClientID
        self.oauthResource = oauthResource
        self.toolApprovalModes = toolApprovalModes
    }

    public init(json: CodexJSONValue) throws {
        guard case let .object(f) = json else { throw CodexMCPServerConfigurationError.invalidShape("server") }
        func s(_ k: String) -> String? { if case let .string(v) = f[k] { v } else { nil } }
        func b(_ k: String, _ d: Bool = false) -> Bool { if case let .bool(v) = f[k] { v } else { d } }
        func n(_ k: String) -> Double? { switch f[k] { case let .number(v): v; case let .integer(v): Double(v); default: nil } }
        func ss(_ k: String) -> [String]? { guard case let .array(a) = f[k] else { return nil }; return a.compactMap { if case let .string(v) = $0 { v } else { nil } } }
        func sm(_ k: String) -> [String: String]? { guard case let .object(o) = f[k] else { return nil }; return o.reduce(into: [:]) { if case let .string(v) = $1.value { $0[$1.key] = v } } }
        let command = s("command"), url = s("url")
        guard (command != nil) != (url != nil) else { throw CodexMCPServerConfigurationError.invalidTransport }
        if let command {
            guard !command.isEmpty, !["url","bearer_token","bearer_token_env_var","http_headers","env_http_headers","oauth","oauth_resource","auth"].contains(where: { f[$0] != nil }) else { throw CodexMCPServerConfigurationError.invalidTransport }
            var envVars: [CodexMCPServerEnvironmentVariable] = []
            if case let .array(raw)? = f["env_vars"] {
                for item in raw {
                    switch item {
                    case let .string(name): envVars.append(.name(name))
                    case let .object(o):
                        guard case let .string(name)? = o["name"] else { throw CodexMCPServerConfigurationError.invalidShape("env_vars.name") }
                        var source: String?
                        if case let .string(value)? = o["source"] { source = value }
                        guard source == nil || source == "local" || source == "remote" else { throw CodexMCPServerConfigurationError.unsupportedEnvironmentSource(source!) }
                        envVars.append(.config(name: name, source: source))
                    default: throw CodexMCPServerConfigurationError.invalidShape("env_vars")
                    }
                }
            }
            transport = .stdio(command: command, args: ss("args") ?? [], env: sm("env"), envVars: envVars, cwd: s("cwd"))
        } else if let url {
            guard !url.isEmpty, !["args","env","env_vars","cwd","bearer_token"].contains(where: { f[$0] != nil }) else { throw CodexMCPServerConfigurationError.invalidTransport }
            transport = .streamableHTTP(url: url, bearerTokenEnvVar: s("bearer_token_env_var"), httpHeaders: sm("http_headers"), envHTTPHeaders: sm("env_http_headers"))
        } else { throw CodexMCPServerConfigurationError.invalidTransport }
        auth = CodexMCPServerAuth(rawValue: s("auth") ?? "oauth") ?? .oauth
        environmentID = s("environment_id") ?? "local"
        enabled = b("enabled", true); required = b("required"); supportsParallelToolCalls = b("supports_parallel_tool_calls")
        startupTimeoutSeconds = n("startup_timeout_sec") ?? n("startup_timeout_ms").map { $0 / 1000 }
        toolTimeoutSeconds = n("tool_timeout_sec"); defaultToolsApprovalMode = s("default_tools_approval_mode")
        enabledTools = ss("enabled_tools"); disabledTools = ss("disabled_tools"); scopes = ss("scopes")
        if case let .object(o)? = f["oauth"], case let .string(v)? = o["client_id"] { oauthClientID = v } else { oauthClientID = nil }
        oauthResource = s("oauth_resource")
        if case let .object(o)? = f["tools"] {
            toolApprovalModes = o.reduce(into: [:]) { result, entry in
                if case let .object(tool) = entry.value, case let .string(mode)? = tool["approval_mode"] { result[entry.key] = mode }
            }
        } else { toolApprovalModes = [:] }
    }

    fileprivate var json: CodexJSONValue {
        var f: [String: CodexJSONValue] = ["environment_id": .string(environmentID), "enabled": .bool(enabled), "required": .bool(required), "supports_parallel_tool_calls": .bool(supportsParallelToolCalls)]
        if auth != .oauth { f["auth"] = .string(auth.rawValue) }
        switch transport {
        case let .stdio(command, args, env, vars, cwd):
            f["command"] = .string(command); f["args"] = .array(args.map(CodexJSONValue.string)); if let env { f["env"] = .object(env.mapValues(CodexJSONValue.string)) }
            if !vars.isEmpty { f["env_vars"] = .array(vars.map { item in switch item { case let .name(name): .string(name); case let .config(name, source): .object(["name": .string(name), "source": source.map(CodexJSONValue.string) ?? .null]) } }) }
            if let cwd { f["cwd"] = .string(cwd) }
        case let .streamableHTTP(url, bearer, headers, envHeaders):
            f["url"] = .string(url); if let bearer { f["bearer_token_env_var"] = .string(bearer) }; if let headers { f["http_headers"] = .object(headers.mapValues(CodexJSONValue.string)) }; if let envHeaders { f["env_http_headers"] = .object(envHeaders.mapValues(CodexJSONValue.string)) }
        }
        if let v = startupTimeoutSeconds { f["startup_timeout_sec"] = .number(v) }; if let v = toolTimeoutSeconds { f["tool_timeout_sec"] = .number(v) }
        if let v = defaultToolsApprovalMode { f["default_tools_approval_mode"] = .string(v) }; if let v = enabledTools { f["enabled_tools"] = .array(v.map(CodexJSONValue.string)) }; if let v = disabledTools { f["disabled_tools"] = .array(v.map(CodexJSONValue.string)) }; if let v = scopes { f["scopes"] = .array(v.map(CodexJSONValue.string)) }; if let v = oauthClientID { f["oauth"] = .object(["client_id": .string(v)]) }; if let v = oauthResource { f["oauth_resource"] = .string(v) }
        if !toolApprovalModes.isEmpty { f["tools"] = .object(toolApprovalModes.mapValues { .object(["approval_mode": .string($0)]) }) }
        return .object(f)
    }
}

public final class CodexMCPConfigurationStore: @unchecked Sendable {
    private let configStore: CodexDesktopConfigStore
    public init(configStore: CodexDesktopConfigStore) { self.configStore = configStore }
    public func readAll() throws -> [String: CodexMCPServerConfiguration] {
        guard case let .object(raw)? = configStore.snapshot["mcp_servers"] else { return [:] }
        return try raw.reduce(into: [:]) { $0[$1.key] = try CodexMCPServerConfiguration(json: $1.value) }
    }
    public func write(_ config: CodexMCPServerConfiguration, for name: String) throws {
        guard !name.isEmpty, !name.contains(".") else { throw CodexMCPServerConfigurationError.invalidServerName }
        var raw: [String: CodexJSONValue] = [:]
        if case let .object(existing)? = configStore.snapshot["mcp_servers"] { raw = existing }
        raw[name] = config.json
        _ = configStore.write(keyPath: "mcp_servers", value: .object(raw), mergeStrategy: "replace")
    }
}
