import Foundation
import Testing

@testable import CodexPadApplication
@testable import CodexPadDomain
@testable import CodexPadProtocolBridge

private func appCatalogFixture(at home: URL) throws {
    let plugin = home.appendingPathComponent(
        "plugins/cache/team-tools/calendar/1.0.0",
        isDirectory: true
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
            "name": "calendar",
            "displayName": "Calendar Toolkit",
            "apps": "./apps/app.json",
        ],
        options: [.sortedKeys]
    ).write(to: manifest)
    let apps = plugin.appendingPathComponent("apps/app.json")
    try FileManager.default.createDirectory(
        at: apps.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try JSONSerialization.data(
        withJSONObject: [
            "apps": [
                "Calendar": [
                    "id": "connector_calendar",
                    "category": "Productivity",
                ],
                "Mail": [
                    "id": "connector_mail",
                ],
            ],
        ],
        options: [.sortedKeys]
    ).write(to: apps)
}

@Test @MainActor
func appCatalogListsReadsAndReportsInstalledPluginApps() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(
            "codex-apps-\(UUID().uuidString)",
            isDirectory: true
        )
    defer { try? FileManager.default.removeItem(at: root) }
    try appCatalogFixture(at: root)
    let service = CodexAppCatalogService(codexHome: root)

    let page = try service.listApps(
        cursor: nil,
        limit: 1,
        forceRefetch: false
    )
    #expect(page.data.map(\.id) == ["connector_calendar"])
    #expect(page.nextCursor == "1")
    #expect(page.data[0].category == "Productivity")
    #expect(
        page.data[0].pluginDisplayNames
            == ["Calendar Toolkit"]
    )
    let read = try service.readApps(
        appIDs: [
            "connector_mail", "missing", "connector_mail",
        ],
        includeTools: true
    )
    #expect(read.apps.map(\.id) == ["connector_mail"])
    #expect(read.missingAppIDs == ["missing"])
    #expect(
        service.installedApps(forceRefresh: false).count == 2
    )

    let zeroLimitPage = try service.listApps(
        cursor: nil,
        limit: 0,
        forceRefetch: false
    )
    #expect(zeroLimitPage.data.map(\.id) == ["connector_calendar"])
    #expect(zeroLimitPage.nextCursor == "1")

    let terminalPage = try service.listApps(
        cursor: "2",
        limit: 1,
        forceRefetch: false
    )
    #expect(terminalPage.data.isEmpty)
    #expect(terminalPage.nextCursor == nil)

    #expect(throws: CodexAppCatalogError.invalidCursor) {
        _ = try service.listApps(
            cursor: "3",
            limit: 1,
            forceRefetch: false
        )
    }
}

@Test @MainActor
func desktopInitialMCPRouterServesAppsListReadAndInstalled()
    async throws
{
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(
            "codex-apps-router-\(UUID().uuidString)",
            isDirectory: true
        )
    defer { try? FileManager.default.removeItem(at: root) }
    try appCatalogFixture(at: root)
    let service = CodexAppCatalogService(codexHome: root)

    let list = await routeApps(
        method: "app/list",
        params: .object([
            "cursor": .null,
            "limit": .number(20),
            "threadId": .null,
            "forceRefetch": .bool(false),
        ]),
        service: service
    )
    guard case let .mcpResponse(_, .object(listEnvelope), _) = list,
          case let .object(listResult)? = listEnvelope["result"],
          case let .array(data)? = listResult["data"],
          case let .object(calendar)? = data.first
    else {
        Issue.record("expected app/list result")
        return
    }
    #expect(calendar["id"] == .string("connector_calendar"))
    #expect(calendar["isEnabled"] == .bool(true))

    let read = await routeApps(
        method: "app/read",
        params: .object([
            "appIds": .array([
                .string("connector_mail"),
                .string("missing"),
            ]),
            "includeTools": .bool(true),
        ]),
        service: service
    )
    guard case let .mcpResponse(_, .object(readEnvelope), _) = read,
          case let .object(readResult)? = readEnvelope["result"],
          case let .array(missing)? =
            readResult["missingAppIds"]
    else {
        Issue.record("expected app/read result")
        return
    }
    #expect(missing == [.string("missing")])

    let installed = await routeApps(
        method: "app/installed",
        params: .object([
            "threadId": .null,
            "forceRefresh": .bool(false),
        ]),
        service: service
    )
    guard case let .mcpResponse(
        _,
        .object(installedEnvelope),
        _
    ) = installed,
        case let .object(installedResult)? =
            installedEnvelope["result"],
        case let .array(installedApps)? =
            installedResult["apps"]
    else {
        Issue.record("expected app/installed result")
        return
    }
    #expect(installedApps.count == 2)
}

@Test @MainActor
func desktopInitialMCPRouterPublishesFullAppListUpdateBeforeReturningPage()
    async throws
{
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(
            "codex-apps-update-\(UUID().uuidString)",
            isDirectory: true
        )
    defer { try? FileManager.default.removeItem(at: root) }
    try appCatalogFixture(at: root)
    let service = CodexAppCatalogService(codexHome: root)
    var updates: [CodexDesktopHostMessage] = []

    let response = await routeApps(
        method: "app/list",
        params: .object([
            "cursor": .null,
            "limit": .number(1),
            "threadId": .null,
            "forceRefetch": .bool(false),
        ]),
        service: service,
        appListUpdated: { updates.append($0) }
    )

    guard case let .mcpResponse(_, .object(envelope), _) = response,
          case let .object(result)? = envelope["result"],
          case let .array(page)? = result["data"]
    else {
        Issue.record("expected paged app/list result")
        return
    }
    #expect(page.count == 1)
    guard case let .mcpNotification(
        hostID,
        method,
        .object(params),
        metadata
    ) = updates.first,
        case let .array(data)? = params["data"]
    else {
        Issue.record("expected app/list/updated notification")
        return
    }
    #expect(updates.count == 1)
    #expect(hostID == "desktop-host-apps")
    #expect(method == "app/list/updated")
    #expect(data.count == 2)
    #expect(metadata.isEmpty)
}

@Test @MainActor
func desktopInitialMCPRouterNormalizesZeroAppListLimitToOne()
    async throws
{
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(
            "codex-apps-zero-limit-\(UUID().uuidString)",
            isDirectory: true
        )
    defer { try? FileManager.default.removeItem(at: root) }
    try appCatalogFixture(at: root)
    let service = CodexAppCatalogService(codexHome: root)

    let response = await routeApps(
        method: "app/list",
        params: .object([
            "cursor": .null,
            "limit": .number(0),
            "threadId": .null,
            "forceRefetch": .bool(false),
        ]),
        service: service
    )

    guard case let .mcpResponse(_, .object(envelope), _) = response,
          case let .object(result)? = envelope["result"],
          case let .array(page)? = result["data"]
    else {
        Issue.record("expected app/list result for limit zero")
        return
    }
    #expect(page.count == 1)
    #expect(result["nextCursor"] == .string("1"))
}

@Test @MainActor
func desktopInitialMCPRouterSkipsUnchangedContinuationUpdateUnlessForced()
    async throws
{
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(
            "codex-apps-continuation-\(UUID().uuidString)",
            isDirectory: true
        )
    defer { try? FileManager.default.removeItem(at: root) }
    try appCatalogFixture(at: root)
    let service = CodexAppCatalogService(codexHome: root)
    var updates: [CodexDesktopHostMessage] = []

    _ = await routeApps(
        method: "app/list",
        params: .object([
            "cursor": .string("1"),
            "limit": .number(1),
            "threadId": .null,
            "forceRefetch": .bool(false),
        ]),
        service: service,
        appListUpdated: { updates.append($0) }
    )
    #expect(updates.isEmpty)

    _ = await routeApps(
        method: "app/list",
        params: .object([
            "cursor": .string("1"),
            "limit": .number(1),
            "threadId": .null,
            "forceRefetch": .bool(true),
        ]),
        service: service,
        appListUpdated: { updates.append($0) }
    )
    #expect(updates.count == 1)
}

@MainActor
private func routeApps(
    method: String,
    params: CodexJSONValue,
    service: CodexAppCatalogService,
    appListUpdated: @escaping (CodexDesktopHostMessage) -> Void = { _ in }
) async -> CodexDesktopHostMessage {
    let request = CodexDesktopMCPRequest(
        request: CodexDesktopMCPRequestMessage(
            id: .integer(501),
            method: method,
            params: params,
            metadata: [:]
        ),
        hostID: "desktop-host-apps",
        dispatchedAtMs: nil,
        priority: nil,
        source: nil,
        timeoutMs: nil,
        expiresAtMs: nil,
        metadata: [:]
    )
    return await CodexDesktopInitialMCPRouter
        .responseIncludingFileSystem(
            to: request,
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
                remoteControl:
                    CodexDesktopMCPRemoteControlState(
                        status: .disabled,
                        serverName: "",
                        installationID: "",
                        environmentID: nil
                    )
            ),
            allowedFileSystemRoots: [],
            appCatalog: service,
            appListUpdated: appListUpdated
        )
}
