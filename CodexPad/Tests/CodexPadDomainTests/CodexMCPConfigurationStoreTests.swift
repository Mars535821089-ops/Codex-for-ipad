import Foundation
import Testing
@testable import CodexPadApplication
@testable import CodexPadDomain

@Test
func mcpConfigurationParsesOfficialStdioFieldsAndDefaults() throws {
    let config = try CodexMCPServerConfiguration(json: .object([
        "command": .string("sample-mcp"), "args": .array([.string("--stdio")]),
        "env": .object(["MODE": .string("local")]),
        "env_vars": .array([.string("TOKEN"), .object(["name": .string("REMOTE_TOKEN"), "source": .string("remote")])]),
        "cwd": .string("/workspace"), "startup_timeout_sec": .number(4.5),
        "tool_timeout_sec": .number(12), "enabled": .bool(false), "required": .bool(true),
        "enabled_tools": .array([.string("list")]), "disabled_tools": .array([.string("delete")]),
    ]))
    #expect(config.transport == .stdio(command: "sample-mcp", args: ["--stdio"], env: ["MODE": "local"], envVars: [.name("TOKEN"), .config(name: "REMOTE_TOKEN", source: "remote")], cwd: "/workspace"))
    #expect(config.environmentID == "local")
    #expect(config.startupTimeoutSeconds == 4.5)
    #expect(config.toolTimeoutSeconds == 12)
    #expect(config.enabled == false)
    #expect(config.required == true)
    #expect(config.enabledTools == ["list"])
    #expect(config.disabledTools == ["delete"])
}

@Test
func mcpConfigurationParsesOfficialStreamableHTTPWithoutSecrets() throws {
    let config = try CodexMCPServerConfiguration(json: .object([
        "url": .string("https://mcp.sample.test"), "bearer_token_env_var": .string("SAMPLE_TOKEN"),
        "http_headers": .object(["X-Client": .string("ipad")]),
        "env_http_headers": .object(["Authorization": .string("AUTH_HEADER")]),
        "auth": .string("chatgpt"), "supports_parallel_tool_calls": .bool(true),
    ]))
    #expect(config.transport == .streamableHTTP(url: "https://mcp.sample.test", bearerTokenEnvVar: "SAMPLE_TOKEN", httpHeaders: ["X-Client": "ipad"], envHTTPHeaders: ["Authorization": "AUTH_HEADER"]))
    #expect(config.auth == .chatGPT)
    #expect(config.supportsParallelToolCalls)
}

@Test
func mcpConfigurationRejectsInvalidTransportAndEnvironmentSource() {
    #expect(throws: CodexMCPServerConfigurationError.self) {
        try CodexMCPServerConfiguration(json: .object(["command": .string("a"), "url": .string("https://b")]))
    }
    #expect(throws: CodexMCPServerConfigurationError.self) {
        try CodexMCPServerConfiguration(json: .object(["command": .string("a"), "env_vars": .array([.object(["name": .string("X"), "source": .string("other")])])]))
    }
}

@Test
func mcpConfigurationStoreRoundTripsThroughPersistedConfig() throws {
    let suite = "mcp-config-" + UUID().uuidString
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let configStore = CodexDesktopConfigStore(userDefaults: defaults, storageKey: "fixture-config")
    let store = CodexMCPConfigurationStore(configStore: configStore)
    let config = try CodexMCPServerConfiguration(json: .object(["command": .string("sample")]))
    try store.write(config, for: "calendar")
    let loaded = try store.readAll()
    #expect(loaded["calendar"] == config)
    #expect(configStore.snapshot["mcp_servers"] != nil)
}
