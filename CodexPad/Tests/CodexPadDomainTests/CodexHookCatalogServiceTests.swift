import Foundation
import Testing

@testable import CodexPadApplication
@testable import CodexPadDomain
@testable import CodexPadProtocolBridge

private func writeHooksFixture(
    _ url: URL,
    command: String = "python3 check.py",
    matcher: String = "^shell$"
) throws {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    let object: [String: Any] = [
        "description": "fixture",
        "hooks": [
            "PreToolUse": [
                [
                    "matcher": matcher,
                    "hooks": [
                        [
                            "type": "command",
                            "command": command,
                            "timeout": 12,
                            "statusMessage": "checking",
                            "additionalContextLimit": 4096,
                        ],
                    ],
                ],
            ],
        ],
    ]
    try JSONSerialization.data(
        withJSONObject: object,
        options: [.sortedKeys]
    ).write(to: url)
}

@Test @MainActor
func hookCatalogListsUserProjectAndPluginHooks() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(
            "codex-hooks-\(UUID().uuidString)",
            isDirectory: true
        )
    defer { try? FileManager.default.removeItem(at: root) }
    let home = root.appendingPathComponent("home", isDirectory: true)
    let workspace = root.appendingPathComponent(
        "workspace",
        isDirectory: true
    )
    let plugin = home.appendingPathComponent(
        "plugins/cache/demo-market/demo/1.0.0",
        isDirectory: true
    )
    try writeHooksFixture(home.appendingPathComponent("hooks.json"))
    try writeHooksFixture(
        workspace.appendingPathComponent(".codex/hooks.json"),
        command: "python3 project.py"
    )
    try writeHooksFixture(
        plugin.appendingPathComponent("hooks/hooks.json"),
        command: "${PLUGIN_ROOT}/bin/check"
    )
    let manifest = plugin.appendingPathComponent(
        ".codex-plugin/plugin.json"
    )
    try FileManager.default.createDirectory(
        at: manifest.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try JSONSerialization.data(
        withJSONObject: [
            "name": "demo",
            "hooks": "./hooks/hooks.json",
        ],
        options: [.sortedKeys]
    ).write(to: manifest)

    let service = CodexHookCatalogService(codexHome: home)
    let entries = service.listHooks(cwds: [workspace.path])
    let entry = try #require(entries.first)

    #expect(entry.cwd == workspace.path)
    #expect(entry.errors.isEmpty)
    #expect(entry.hooks.count == 3)
    #expect(entry.hooks.map(\.source) == [.user, .project, .plugin])
    #expect(entry.hooks.map(\.displayOrder) == [0, 1, 2])
    #expect(entry.hooks.allSatisfy { $0.eventName == .preToolUse })
    #expect(entry.hooks.allSatisfy { $0.handlerType == .command })
    #expect(entry.hooks.allSatisfy { $0.timeoutSec == 12 })
    #expect(entry.hooks.allSatisfy { $0.trustStatus == .untrusted })
    #expect(
        entry.hooks.last?.command
            == "\(plugin.path)/bin/check"
    )
    #expect(entry.hooks.last?.pluginID == "demo@demo-market")
    #expect(
        entry.hooks.allSatisfy {
            $0.currentHash.hasPrefix("sha256:")
        }
    )
}

@Test @MainActor
func hookCatalogPreservesPromptAgentAndAsyncCommandMetadata()
    async throws
{
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(
            "codex-hooks-modes-\(UUID().uuidString)",
            isDirectory: true
        )
    defer { try? FileManager.default.removeItem(at: root) }
    let home = root.appendingPathComponent("home", isDirectory: true)
    let workspace = root.appendingPathComponent(
        "workspace",
        isDirectory: true
    )
    let config = workspace.appendingPathComponent(
        ".codex/hooks.json"
    )
    try FileManager.default.createDirectory(
        at: config.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try JSONSerialization.data(
        withJSONObject: [
            "hooks": [
                "PreToolUse": [[
                    "matcher": "^shell$",
                    "hooks": [
                        [
                            "type": "command",
                            "command": "python3 async-check.py",
                            "async": true,
                        ],
                        ["type": "prompt"],
                        ["type": "agent"],
                    ],
                ]],
            ],
        ],
        options: [.sortedKeys]
    ).write(to: config)

    let service = CodexHookCatalogService(codexHome: home)
    let entry = try #require(
        service.listHooks(cwds: [workspace.path]).first
    )

    #expect(entry.warnings.isEmpty)
    #expect(entry.hooks.count == 3)
    #expect(
        entry.hooks.map(\.handlerType)
            == [.command, .prompt, .agent]
    )
    #expect(
        entry.hooks.map(\.command)
            == ["python3 async-check.py", nil, nil]
    )

    let request = CodexDesktopMCPRequest(
        request: CodexDesktopMCPRequestMessage(
            id: .integer(82),
            method: "hooks/list",
            params: .object([
                "cwds": .array([.string(workspace.path)]),
            ]),
            metadata: [:]
        ),
        hostID: "host-hooks-modes",
        dispatchedAtMs: nil,
        priority: nil,
        source: nil,
        timeoutMs: nil,
        expiresAtMs: nil,
        metadata: [:]
    )
    let response =
        await CodexDesktopInitialMCPRouter
            .responseIncludingFileSystem(
                to: request,
                state: .fixture,
                allowedFileSystemRoots: [],
                hookCatalog: service
            )
    guard case let .mcpResponse(_, .object(envelope), _) = response,
          case let .object(result)? = envelope["result"],
          case let .array(data)? = result["data"],
          case let .object(encodedEntry)? = data.first,
          case let .array(encodedHooks)? = encodedEntry["hooks"]
    else {
        Issue.record("expected hooks/list success response")
        return
    }
    #expect(
        encodedHooks.compactMap { value -> CodexJSONValue? in
            guard case let .object(fields) = value else { return nil }
            return fields["executionMode"]
        } == [.string("async"), .string("sync"), .string("sync")]
    )
}

@Test @MainActor
func hookCatalogReturnsMalformedFileAsWarning() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(
            "codex-hooks-bad-\(UUID().uuidString)",
            isDirectory: true
        )
    defer { try? FileManager.default.removeItem(at: root) }
    let home = root.appendingPathComponent("home", isDirectory: true)
    let workspace = root.appendingPathComponent(
        "workspace",
        isDirectory: true
    )
    try FileManager.default.createDirectory(
        at: workspace.appendingPathComponent(".codex"),
        withIntermediateDirectories: true
    )
    try Data("{broken".utf8).write(
        to: workspace.appendingPathComponent(
            ".codex/hooks.json"
        )
    )

    let entry = try #require(
        CodexHookCatalogService(codexHome: home)
            .listHooks(cwds: [workspace.path])
            .first
    )
    #expect(entry.hooks.isEmpty)
    #expect(entry.errors.isEmpty)
    #expect(entry.warnings.count == 1)
    #expect(entry.warnings[0].contains("failed to parse hooks config"))
}

@Test @MainActor
func hookCatalogUsesActiveInstalledVersionAndInlineManifestHooks()
    throws
{
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(
            "codex-hooks-installed-\(UUID().uuidString)",
            isDirectory: true
        )
    defer { try? FileManager.default.removeItem(at: root) }
    let home = root.appendingPathComponent("home", isDirectory: true)
    let workspace = root.appendingPathComponent(
        "workspace",
        isDirectory: true
    )
    try FileManager.default.createDirectory(
        at: workspace,
        withIntermediateDirectories: true
    )
    let service = CodexHookCatalogService(codexHome: home)
    #expect(
        service.listHooks(cwds: [workspace.path])[0].hooks.isEmpty
    )

    let base = home.appendingPathComponent(
        "plugins/cache/curated/calendar-tools",
        isDirectory: true
    )
    let old = base.appendingPathComponent(
        "1.0.0",
        isDirectory: true
    )
    try writeHooksFixture(
        old.appendingPathComponent("hooks/hooks.json"),
        command: "python3 old.py"
    )
    let oldManifest = old.appendingPathComponent(
        ".codex-plugin/plugin.json"
    )
    try FileManager.default.createDirectory(
        at: oldManifest.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try Data(#"{"name":"calendar-tools"}"#.utf8)
        .write(to: oldManifest)

    let active = base.appendingPathComponent(
        "local",
        isDirectory: true
    )
    let activeManifest = active.appendingPathComponent(
        ".codex-plugin/plugin.json"
    )
    try FileManager.default.createDirectory(
        at: activeManifest.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    let inline: [String: Any] = [
        "name": "calendar-tools",
        "hooks": [
            "description": "inline fixture",
            "hooks": [
                "PreToolUse": [
                    [
                        "matcher": "^shell$",
                        "hooks": [
                            [
                                "type": "command",
                                "command":
                                    "${PLUGIN_ROOT}/bin/check",
                                "timeout": 12,
                            ],
                        ],
                    ],
                ],
            ],
        ],
    ]
    try JSONSerialization.data(
        withJSONObject: inline,
        options: [.sortedKeys]
    ).write(to: activeManifest)

    let entry = service.listHooks(cwds: [workspace.path])[0]
    let hook = try #require(entry.hooks.first)
    #expect(entry.hooks.count == 1)
    #expect(entry.warnings.isEmpty)
    #expect(hook.command == "\(active.path)/bin/check")
    #expect(hook.sourcePath == activeManifest.path)
    #expect(hook.pluginID == "calendar-tools@curated")
    #expect(
        hook.key
            == "calendar-tools@curated:plugin.json#hooks[0]:pre_tool_use:0:0"
    )
}

@Test @MainActor
func desktopInitialMCPRouterServesHooksList() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(
            "codex-hooks-router-\(UUID().uuidString)",
            isDirectory: true
        )
    defer { try? FileManager.default.removeItem(at: root) }
    let home = root.appendingPathComponent("home", isDirectory: true)
    let workspace = root.appendingPathComponent(
        "workspace",
        isDirectory: true
    )
    try writeHooksFixture(
        workspace.appendingPathComponent(".codex/hooks.json")
    )
    let service = CodexHookCatalogService(codexHome: home)
    let request = CodexDesktopMCPRequest(
        request: CodexDesktopMCPRequestMessage(
            id: .integer(81),
            method: "hooks/list",
            params: .object([
                "cwds": .array([.string(workspace.path)]),
            ]),
            metadata: [:]
        ),
        hostID: "host-hooks",
        dispatchedAtMs: nil,
        priority: nil,
        source: nil,
        timeoutMs: nil,
        expiresAtMs: nil,
        metadata: [:]
    )
    let response =
        await CodexDesktopInitialMCPRouter
            .responseIncludingFileSystem(
                to: request,
                state: .fixture,
                allowedFileSystemRoots: [],
                hookCatalog: service
            )
    guard case let .mcpResponse(_, .object(envelope), _) = response,
          case let .object(result)? = envelope["result"],
          case let .array(data)? = result["data"],
          case let .object(entry)? = data.first,
          case let .array(hooks)? = entry["hooks"],
          case let .object(hook)? = hooks.first
    else {
        Issue.record("expected hooks/list success response")
        return
    }
    #expect(entry["cwd"] == .string(workspace.path))
    #expect(hook["eventName"] == .string("preToolUse"))
    #expect(hook["handlerType"] == .string("command"))
    #expect(hook["source"] == .string("project"))
    #expect(hook["timeoutSec"] == .number(12))
    #expect(hook["additionalContextLimit"] == .number(4096))
}

private extension CodexDesktopInitialMCPState {
    static let fixture = CodexDesktopInitialMCPState(
        account: CodexDesktopMCPAccountState(
            account: nil,
            authMethod: nil,
            requiresOpenAIAuth: false
        ),
        config: CodexDesktopMCPConfigState(
            config: [:],
            origins: [:],
            layers: []
        ),
        remoteControl: CodexDesktopMCPRemoteControlState(
            status: .disabled,
            serverName: "",
            installationID: "",
            environmentID: nil
        )
    )
}
