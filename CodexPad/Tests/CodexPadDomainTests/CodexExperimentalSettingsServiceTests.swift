import Foundation
import Testing

@testable import CodexPadApplication
@testable import CodexPadDomain
@testable import CodexPadProtocolBridge

@Test @MainActor
func experimentalFeatureCatalogMatchesReleasedRegistryAndPersistsSupportedOverrides()
    throws
{
    let suite = "codex-experimental-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let config = CodexDesktopConfigStore(
        userDefaults: defaults,
        storageKey: "config"
    )
    let service = CodexExperimentalSettingsService(
        configStore: config
    )

    #expect(
        service.listCollaborationModes()
            == [
                CodexCollaborationModeMask(
                    name: "Plan",
                    mode: "plan",
                    model: nil,
                    reasoningEffort: "medium"
                ),
                CodexCollaborationModeMask(
                    name: "Default",
                    mode: "default",
                    model: nil,
                    reasoningEffort: nil
                ),
            ]
    )

    let first = try service.listExperimentalFeatures(
        cursor: nil,
        limit: 1
    )
    #expect(first.data.map(\.name) == ["undo"])
    #expect(first.nextCursor == "1")

    service.setExperimentalFeatureEnablement([
        "memories": true,
        "remote_control": true,
        "unified_exec": false,
        "unknown_future_flag": true,
    ])
    let all = try service.listExperimentalFeatures(
        cursor: nil,
        limit: nil
    )
    #expect(service.releasedFeatureCount == all.data.count)
    #expect(service.releasedFeatureCount > 0)
    #expect(Set(all.data.map(\.name)).count == all.data.count)
    #expect(all.data.first { $0.name == "memories" }?.enabled == true)
    #expect(
        all.data.first { $0.name == "remote_control" }?.enabled
            == true
    )
    #expect(
        all.data.first { $0.name == "unified_exec" }?.enabled
            == true
    )
    guard case let .object(features)? = config.snapshot["features"]
    else {
        Issue.record("expected persisted features object")
        return
    }
    #expect(features["memories"] == .bool(true))
    #expect(features["remote_control"] == .bool(true))
    #expect(features["unified_exec"] == nil)
    #expect(features["unknown_future_flag"] == nil)

    #expect(throws: CodexSettingsCatalogError.self) {
        _ = try service.listExperimentalFeatures(
            cursor: "not-a-number",
            limit: 10
        )
    }
}

@Test @MainActor
func permissionProfileCatalogIncludesBuiltinsCustomProfilesRestrictionsAndPagination()
    throws
{
    let suite = "codex-permissions-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let config = CodexDesktopConfigStore(
        userDefaults: defaults,
        storageKey: "config"
    )
    _ = config.write(
        keyPath: "permissions",
        value: .object([
            "developer": .object([
                "description": .string("Developer workspace"),
                "extends": .string(":workspace"),
            ]),
            "network-audit": .object([
                "description": .string("Network audit"),
                "extends": .string(":read-only"),
            ]),
        ]),
        mergeStrategy: "replace"
    )
    let service = CodexExperimentalSettingsService(
        configStore: config,
        allowedPermissionProfiles: [
            ":read-only", ":workspace", "developer",
        ]
    )

    let first = try service.listPermissionProfiles(
        cursor: nil,
        limit: 4,
        cwd: "/fixture/workspace"
    )
    #expect(
        first.data.map(\.id)
            == [
                ":read-only",
                ":workspace",
                ":danger-full-access",
                "developer",
            ]
    )
    #expect(first.data.map(\.allowed) == [true, true, false, true])
    #expect(first.nextCursor == "4")
    let second = try service.listPermissionProfiles(
        cursor: first.nextCursor,
        limit: 4,
        cwd: nil
    )
    #expect(second.data.map(\.id) == ["network-audit"])
    #expect(second.data[0].description == "Network audit")
    #expect(second.data[0].allowed == false)
    #expect(second.nextCursor == nil)
}

@Test @MainActor
func desktopInitialMCPRouterServesExperimentalAndPermissionSettings()
    async throws
{
    let suite = "codex-settings-router-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let service = CodexExperimentalSettingsService(
        configStore: CodexDesktopConfigStore(
            userDefaults: defaults,
            storageKey: "config"
        )
    )

    let enable = await routeSettings(
        method: "experimentalFeature/enablement/set",
        params: .object([
            "enablement": .object([
                "memories": .bool(true),
            ]),
        ]),
        service: service
    )
    guard case let .mcpResponse(_, .object(enableEnvelope), _) =
        enable
    else {
        Issue.record("expected enablement response")
        return
    }
    #expect(enableEnvelope["result"] == .object([:]))

    let collaborationModes = await routeSettings(
        method: "collaborationMode/list",
        params: .object([:]),
        service: service
    )
    guard case let .mcpResponse(
        _,
        .object(collaborationEnvelope),
        _
    ) = collaborationModes,
        case let .object(collaborationResult)? =
            collaborationEnvelope["result"],
        case let .array(modes)? = collaborationResult["data"]
    else {
        Issue.record("expected collaboration mode list")
        return
    }
    #expect(
        modes == [
            .object([
                "name": .string("Plan"),
                "mode": .string("plan"),
                "model": .null,
                "reasoning_effort": .string("medium"),
            ]),
            .object([
                "name": .string("Default"),
                "mode": .string("default"),
                "model": .null,
                "reasoning_effort": .null,
            ]),
        ]
    )

    let list = await routeSettings(
        method: "experimentalFeature/list",
        params: .object([
            "cursor": .null,
            "limit": .integer(1000),
            "threadId": .null,
        ]),
        service: service
    )
    guard case let .mcpResponse(_, .object(listEnvelope), _) = list,
          case let .object(listResult)? = listEnvelope["result"],
          case let .array(features)? = listResult["data"],
          case let .object(memory)? = features.first(where: {
              guard case let .object(fields) = $0
              else { return false }
              return fields["name"] == .string("memories")
          })
    else {
        Issue.record("expected feature list response")
        return
    }
    #expect(memory["stage"] == .string("stable"))
    #expect(memory["enabled"] == .bool(true))
    #expect(memory["defaultEnabled"] == .bool(false))

    let permissions = await routeSettings(
        method: "permissionProfile/list",
        params: .object([
            "cursor": .null,
            "limit": .integer(10),
            "cwd": .null,
        ]),
        service: service
    )
    guard case let .mcpResponse(
        _,
        .object(permissionEnvelope),
        _
    ) = permissions,
        case let .object(permissionResult)? =
            permissionEnvelope["result"],
        case let .array(profiles)? = permissionResult["data"]
    else {
        Issue.record("expected permission profile list")
        return
    }
    #expect(profiles.count == 3)
}

@MainActor
private func routeSettings(
    method: String,
    params: CodexJSONValue,
    service: CodexExperimentalSettingsService
) async -> CodexDesktopHostMessage {
    await CodexDesktopInitialMCPRouter.responseIncludingFileSystem(
        to: CodexDesktopMCPRequest(
            request: CodexDesktopMCPRequestMessage(
                id: .integer(611),
                method: method,
                params: params,
                metadata: [:]
            ),
            hostID: "settings-host",
            dispatchedAtMs: nil,
            priority: nil,
            source: nil,
            timeoutMs: nil,
            expiresAtMs: nil,
            metadata: [:]
        ),
        state: CodexDesktopInitialMCPState(
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
        ),
        allowedFileSystemRoots: [],
        settingsCatalog: service
    )
}
