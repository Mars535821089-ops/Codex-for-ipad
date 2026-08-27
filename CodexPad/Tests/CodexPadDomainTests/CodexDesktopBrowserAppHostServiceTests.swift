import Foundation
import Testing

@testable import CodexPadApplication

@Test
func desktopLatestBrowserServicesExposeTabsAndIncompleteNavigation()
    async throws
{
    let service = CodexDesktopBrowserAppHostService()

    #expect(
        try await service.invoke(
            service: "browserTabs",
            method: "search",
            arguments: [
                .object([
                    "conversationId": .string("thread-1"),
                    "query": .string("docs"),
                ])
            ]
        ) == .object(["candidates": .array([])])
    )
    #expect(
        try await service.invoke(
            service: "browserTabs",
            method: "getChromeTabLiveness",
            arguments: [
                .object([
                    "extensionInstanceId": .string("chrome-1"),
                    "tabIds": .array([.integer(7)]),
                ])
            ]
        ) == .object(["status": .string("unavailable")])
    )
    #expect(
        try await service.invoke(
            service: "inAppBrowserIncompleteNavigation",
            method: "subscribe",
            arguments: [.import(41)]
        ) == .undefined
    )
    #expect(
        try await service.invoke(
            service: "inAppBrowserIncompleteNavigation",
            method: "unsubscribe",
            arguments: []
        ) == .undefined
    )
}

@Test
func desktopBrowserTabsSearchReturnsMatchingEmbeddedPages() async throws {
    let restoreState = CodexDesktopBrowserPageRestoreState()
    await restoreState.recordDurableSnapshot(
        .object([
            "faviconUrl": .string("https://example.com/favicon.ico"),
            "title": .string("Codex documentation"),
            "url": .string("https://example.com/docs"),
        ]),
        browserStorageID: "storage-1",
        browserTabID: "tab-1",
        conversationID: "thread-1"
    )
    let service = CodexDesktopBrowserAppHostService(
        pageRestoreState: restoreState
    )

    #expect(
        try await service.invoke(
            service: "browserTabs",
            method: "search",
            arguments: [
                .object([
                    "conversationId": .string("thread-1"),
                    "query": .string("documentation"),
                ])
            ]
        ) == .object([
            "candidates": .array([
                .object([
                    "browserId": .string("ipad-in-app-browser"),
                    "browserFamily": .string("in-app"),
                    "faviconUrl": .string(
                        "https://example.com/favicon.ico"
                    ),
                    "pluginId": .string("browser"),
                    "tabId": .string("tab-1"),
                    "snapshot": .object([
                        "title": .string("Codex documentation"),
                        "url": .string("https://example.com/docs"),
                    ]),
                    "source": .string("in-app"),
                ])
            ])
        ])
    )
}

@Test
func desktopBrowserSidebarRestoresDurablePageSnapshot() async throws {
    let restoreState = CodexDesktopBrowserPageRestoreState()
    let snapshot: CodexDesktopAppHostRPC.Value = .object([
        "canGoBack": .bool(true),
        "canGoForward": .bool(false),
        "committedUrl": .string("https://example.com/docs"),
        "faviconUrl": .string("https://example.com/favicon.ico"),
        "isSuspended": .bool(true),
        "tabType": .string("web"),
        "title": .string("Docs"),
        "url": .string("https://example.com/docs"),
    ])
    await restoreState.recordDurableSnapshot(
        snapshot,
        browserStorageID: "storage-1",
        browserTabID: "tab-1",
        conversationID: "thread-1"
    )
    let service = CodexDesktopBrowserAppHostService(
        pageRestoreState: restoreState
    )
    let pages: [CodexDesktopAppHostRPC.Value] = [
        .object([
            "browserStorageId": .string("storage-1"),
            "browserTabId": .string("tab-1"),
            "conversationId": .string("thread-1"),
        ]),
        .object([
            "browserStorageId": .string("storage-2"),
            "browserTabId": .string("tab-2"),
            "conversationId": .string("thread-1"),
        ]),
    ]

    #expect(
        try await service.invoke(
            service: "browserSidebar",
            method: "getPageRestoreResults",
            arguments: [.object(["pages": .array(pages)])]
        ) == .array([
            .object([
                "snapshot": snapshot,
                "status": .string("snapshot-ready"),
            ]),
            .object(["status": .string("missing")]),
        ])
    )
}

@Test
func desktopBrowserSidebarRegistersLivePageWithReleasedContract()
    async throws
{
    let restoreState = CodexDesktopBrowserPageRestoreState()
    let snapshot: CodexDesktopAppHostRPC.Value = .object([
        "canGoBack": .bool(false),
        "canGoForward": .bool(false),
        "committedUrl": .string("https://example.com"),
        "faviconUrl": .null,
        "isSuspended": .bool(true),
        "tabType": .string("web"),
        "title": .string("Example"),
        "url": .string("https://example.com"),
    ])
    await restoreState.recordDurableSnapshot(
        snapshot,
        browserStorageID: "storage-1",
        browserTabID: "tab-1",
        conversationID: "thread-1"
    )
    let service = CodexDesktopBrowserAppHostService(
        pageRestoreState: restoreState
    )

    #expect(
        try await service.invoke(
            service: "browserSidebar",
            method: "registerWebviewHostSession",
            arguments: [
                .object([
                    "rendererInstanceId": .string("renderer-1")
                ])
            ]
        ) == .bool(true)
    )
    #expect(
        try await service.invoke(
            service: "browserSidebar",
            method: "registerWebviewHost",
            arguments: [
                .object([
                    "browserTabId": .string("tab-1"),
                    "conversationId": .string("thread-1"),
                    "hostGeneration": .integer(2),
                    "pagePersistence": .object([
                        "browserStorageId": .string("storage-1"),
                        "restore": .string("required"),
                    ]),
                    "rendererInstanceId": .string("renderer-1"),
                ])
            ]
        ) == .bool(true)
    )
    #expect(
        try await service.invoke(
            service: "browserSidebar",
            method: "getPageRestoreResults",
            arguments: [
                .object([
                    "pages": .array([
                        .object([
                            "browserStorageId": .string("storage-1"),
                            "browserTabId": .string("tab-1"),
                            "conversationId": .string("thread-1"),
                        ])
                    ])
                ])
            ]
        ) == .array([
            .object([
                "browserStorageId": .string("storage-1"),
                "snapshot": snapshot,
                "status": .string("already-live"),
            ])
        ])
    )
}

@Test
func desktopBrowserSidebarRejectsStaleOrConflictingHostRegistration()
    async throws
{
    let service = CodexDesktopBrowserAppHostService()

    #expect(
        try await service.invoke(
            service: "browserSidebar",
            method: "registerWebviewHost",
            arguments: [
                .object([
                    "browserTabId": .string("tab-1"),
                    "conversationId": .string("thread-1"),
                    "hostGeneration": .integer(1),
                    "pagePersistence": .object([
                        "browserStorageId": .string("storage-1"),
                        "restore": .string("none"),
                    ]),
                    "rendererInstanceId": .string("renderer-1"),
                ])
            ]
        ) == .bool(false)
    )
    #expect(
        try await service.invoke(
            service: "browserSidebar",
            method: "registerWebviewHostSession",
            arguments: [
                .object([
                    "rendererInstanceId": .string("renderer-1")
                ])
            ]
        ) == .bool(true)
    )
    #expect(
        try await service.invoke(
            service: "browserSidebar",
            method: "registerWebviewHost",
            arguments: [
                .object([
                    "browserTabId": .string("tab-1"),
                    "conversationId": .string("thread-1"),
                    "hostGeneration": .integer(2),
                    "pagePersistence": .object([
                        "browserStorageId": .string("storage-1"),
                        "restore": .string("none"),
                    ]),
                    "rendererInstanceId": .string("renderer-1"),
                ])
            ]
        ) == .bool(true)
    )
    #expect(
        try await service.invoke(
            service: "browserSidebar",
            method: "registerWebviewHost",
            arguments: [
                .object([
                    "browserTabId": .string("tab-1"),
                    "conversationId": .string("thread-1"),
                    "hostGeneration": .integer(1),
                    "pagePersistence": .object([
                        "browserStorageId": .string("storage-1"),
                        "restore": .string("none"),
                    ]),
                    "rendererInstanceId": .string("renderer-1"),
                ])
            ]
        ) == .bool(false)
    )
    #expect(
        try await service.invoke(
            service: "browserSidebar",
            method: "registerWebviewHost",
            arguments: [
                .object([
                    "browserTabId": .string("tab-2"),
                    "conversationId": .string("thread-1"),
                    "hostGeneration": .integer(1),
                    "pagePersistence": .object([
                        "browserStorageId": .string("storage-1"),
                        "restore": .string("none"),
                    ]),
                    "rendererInstanceId": .string("renderer-1"),
                ])
            ]
        ) == .bool(false)
    )
}

@Test
func desktopBrowserSidebarForwardsWebMcpInspectorIdentityAndShape()
    async throws
{
    let service = CodexDesktopBrowserAppHostService(
        webMcpInspectorDataProvider: { conversationID, browserTabID in
            #expect(conversationID == "thread-1")
            #expect(browserTabID == "tab-1")
            return .object([
                "recentToolCalls": .array([
                    .object(["name": .string("search")])
                ]),
                "tools": .array([
                    .object(["name": .string("lookup")])
                ]),
            ])
        }
    )

    #expect(
        try await service.invoke(
            service: "browserSidebar",
            method: "getWebMcpInspectorData",
            arguments: [
                .object([
                    "browserTabId": .string("tab-1"),
                    "conversationId": .string("thread-1"),
                ])
            ]
        ) == .object([
            "recentToolCalls": .array([
                .object(["name": .string("search")])
            ]),
            "tools": .array([
                .object(["name": .string("lookup")])
            ]),
        ])
    )
}

@Test
func desktopBrowserSidebarRejectsMalformedWebMcpInspectorRequests()
    async throws
{
    let service = CodexDesktopBrowserAppHostService(
        webMcpInspectorDataProvider: { _, _ in .null }
    )
    let malformed: [[CodexDesktopAppHostRPC.Value]] = [
        [],
        [.object(["browserTabId": .string("tab-1")])],
        [.object(["conversationId": .string("thread-1")])],
        [.object([
            "browserTabId": .string("tab-1"),
            "conversationId": .string("thread-1"),
        ]), .null],
    ]
    for arguments in malformed {
        await #expect(throws: CodexDesktopBrowserAppHostService.Error.invalidArguments) {
            try await service.invoke(
                service: "browserSidebar",
                method: "getWebMcpInspectorData",
                arguments: arguments
            )
        }
    }
}

@Test
func desktopBrowserSidebarAllowsMissingWebMcpInspectorData()
    async throws
{
    let service = CodexDesktopBrowserAppHostService(
        webMcpInspectorDataProvider: { _, _ in .null }
    )
    #expect(
        try await service.invoke(
            service: "browserSidebar",
            method: "getWebMcpInspectorData",
            arguments: [.object([
                "browserTabId": .string("tab-1"),
                "conversationId": .string("thread-1"),
            ])]
        ) == .null
    )
}

@Test
func desktopBrowserSidebarReturnsReleasedExtensionShape() async throws {
    let service = CodexDesktopBrowserAppHostService()

    #expect(
        try await service.invoke(
            service: "browserSidebar",
            method: "getExtensionActions",
            arguments: [
                .object([
                    "browserTabId": .string("tab-1"),
                    "conversationId": .string("thread-1"),
                ])
            ]
        ) == .object([
            "status": .string("unsupported"),
            "actions": .array([]),
        ])
    )
}

@Test
func desktopBrowserSidebarForwardsExtensionActionsProvider() async throws {
    let service = CodexDesktopBrowserAppHostService(
        extensionActionsProvider: { conversationID, browserTabID in
            #expect(conversationID == "thread-1")
            #expect(browserTabID == "tab-1")
            return .object([
                "status": .string("available"),
                "actions": .array([
                    .object(["id": .string("inspect")])
                ]),
            ])
        }
    )

    #expect(
        try await service.invoke(
            service: "browserSidebar",
            method: "getExtensionActions",
            arguments: [.object([
                "browserTabId": .string("tab-1"),
                "conversationId": .string("thread-1"),
            ])]
        ) == .object([
            "status": .string("available"),
            "actions": .array([
                .object(["id": .string("inspect")])
            ]),
        ])
    )
}

@Test
func desktopBrowserServicesForwardReleasedRequests() async throws {
    actor Events {
        var values: [
            (
                String,
                String,
                [CodexDesktopAppHostRPC.Value]?
            )
        ] = []

        func append(
            _ service: String,
            _ method: String,
            _ arguments: [CodexDesktopAppHostRPC.Value]?
        ) {
            values.append((service, method, arguments))
        }
    }

    let events = Events()
    let service = CodexDesktopBrowserAppHostService(
        installedBrowserFamilies: { ["chrome", "edge"] },
        eventHandler: { service, method, arguments in
            await events.append(service, method, arguments)
        }
    )
    let calls: [
        (
            String,
            String,
            [CodexDesktopAppHostRPC.Value]
        )
    ] = [
        (
            "browserSidebar",
            "prepareLocalWorkSessionRoute",
            [
                .object([
                    "browserConversationId": .string("thread-1")
                ])
            ]
        ),
        (
            "browserSidebar",
            "triggerExtensionAction",
            [
                .object([
                    "actionId": .string("extension-action"),
                    "browserTabId": .string("tab-1"),
                    "conversationId": .string("thread-1"),
                ])
            ]
        ),
        (
            "browserSidebar",
            "setAudioMuted",
            [
                .object([
                    "browserTabId": .string("tab-1"),
                    "conversationId": .string("thread-1"),
                    "muted": .bool(true),
                ])
            ]
        ),
        (
            "chromeNativeHost",
            "install",
            [
                .object([
                    "hostId": .string("local"),
                    "marketplacePath": .null,
                    "pluginName": .string("chrome"),
                ])
            ]
        ),
        (
            "chromeNativeHost",
            "uninstall",
            [
                .object([
                    "hostId": .string("local"),
                    "marketplaceName": .string("openai"),
                    "pluginName": .string("chrome"),
                ])
            ]
        ),
        (
            "chromiumBrowser",
            "openUrl",
            [
                .object([
                    "browserFamily": .string("chrome"),
                    "url": .string("https://example.com/extension"),
                ])
            ]
        ),
    ]

    for (serviceName, method, arguments) in calls {
        #expect(
            try await service.invoke(
                service: serviceName,
                method: method,
                arguments: arguments
            ) == (
                serviceName == "browserSidebar"
                    && method == "triggerExtensionAction"
                ? .bool(false)
                : .undefined
            )
        )
    }
    #expect(
        try await service.invoke(
            service: "chromiumBrowser",
            method: "getInstalledBrowserFamilies",
            arguments: nil
        ) == .array([.string("chrome"), .string("edge")])
    )
    #expect(await events.values.count == calls.count)
}

@Test
func desktopBrowserSidebarDeletesConversationState() async throws {
    let service = CodexDesktopBrowserAppHostService()

    #expect(
        try await service.invoke(
            service: "browserSidebar",
            method: "prepareLocalWorkSessionRoute",
            arguments: [
                .object([
                    "browserConversationId": .string("thread-1")
                ])
            ]
        ) == .undefined
    )
    #expect(await service.preparedConversationIDs == ["thread-1"])

    #expect(
        try await service.invoke(
            service: "browserSidebar",
            method: "deleteConversation",
            arguments: [
                .object([
                    "browserConversationId": .string("thread-1"),
                    "conversationId": .string("thread-1"),
                ])
            ]
        ) == .undefined
    )
    #expect(await service.preparedConversationIDs.isEmpty)
}
