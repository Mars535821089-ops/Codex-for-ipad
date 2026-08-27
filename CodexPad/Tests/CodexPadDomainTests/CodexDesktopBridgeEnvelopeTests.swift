import CodexPadDomain
import Foundation
import Testing

@testable import CodexPadApplication
@testable import CodexPadProtocolBridge

@Test
func desktopBridgeDecodesRendererLifecycleMessages() throws {
    #expect(
        try CodexDesktopBridgeCodec.decodeViewPayload(
            Data(#"{"type":"ready"}"#.utf8)
        ) == .ready
    )
    #expect(
        try CodexDesktopBridgeCodec.decodeViewPayload(
            Data(#"{"type":"view-focused"}"#.utf8)
        ) == .viewFocused
    )
    #expect(
        try CodexDesktopBridgeCodec.decodeViewPayload(
            Data(
                #"""
                {
                  "type":"log-message",
                  "level":"info",
                  "message":"routes mounted",
                  "tags":{"surface":"home"}
                }
                """#.utf8
            )
        ) == .logMessage(
            CodexDesktopLogMessage(
                level: "info",
                message: "routes mounted",
                tags: .object(["surface": .string("home")])
            )
        )
    )
    #expect(
        try CodexDesktopBridgeCodec.decodeViewPayload(
            Data(#"{"type":"persisted-atom-sync-request"}"#.utf8)
        ) == .persistedAtomSyncRequest
    )
    #expect(
        try CodexDesktopBridgeCodec.decodeViewPayload(
            Data(
                #"""
                {
                  "type":"persisted-atom-update",
                  "key":"sidebar.open",
                  "value":true
                }
                """#.utf8
            )
        ) == .persistedAtomUpdate(
            CodexDesktopPersistedAtomUpdate(
                key: "sidebar.open",
                value: .bool(true),
                deleted: false
            )
        )
    )
    #expect(
        try CodexDesktopBridgeCodec.decodeViewPayload(
            Data(
                #"""
                {
                  "type":"shared-object-set",
                  "key":"selected-project"
                }
                """#.utf8
            )
        ) == .sharedObjectSet(key: "selected-project", value: nil)
    )
}

@Test
func desktopRendererLogDiagnosticDescriptionPreservesStructuredTags() {
    let message = CodexDesktopLogMessage(
        level: "error",
        message: "error boundary",
        tags: .object([
            "safe": .object([
                "name": .string("AppRoutesErrorBoundary")
            ]),
            "sensitive": .object([
                "error": .object([
                    "message": .string("Missing desktop host value")
                ])
            ]),
        ])
    )

    #expect(
        message.diagnosticDescription
            == #"renderer[error] error boundary tags={"safe":{"name":"AppRoutesErrorBoundary"},"sensitive":{"error":{"message":"Missing desktop host value"}}}"#
    )
}

@Test
func desktopBridgeDecodesExactReleasedRendererOpenInBrowserShape() throws {
    let decoded = try CodexDesktopBridgeCodec.decodeViewPayload(
        Data(
            #"""
            {
              "type":"open-in-browser",
              "url":"https://example.test/sites/project-1",
              "initiator":"sites_library",
              "openTarget":"in-app-browser",
              "source":"manual"
            }
            """#.utf8
        )
    )

    #expect(
        decoded == .openInBrowser(
            CodexDesktopOpenInBrowserRequest(
                url: "https://example.test/sites/project-1",
                initiator: "sites_library",
                openTarget: "in-app-browser",
                source: "manual"
            )
        )
    )
}

@Test
func desktopBridgePreservesSharedObjectSubscriptionAndWireValueSemantics() throws {
    #expect(
        try CodexDesktopBridgeCodec.decodeViewPayload(
            Data(
                #"{"type":"shared-object-subscribe","key":"selected-project"}"#
                    .utf8
            )
        ) == .sharedObjectSubscribe(key: "selected-project")
    )
    #expect(
        try CodexDesktopBridgeCodec.decodeViewPayload(
            Data(
                #"{"type":"shared-object-unsubscribe","key":"selected-project"}"#
                    .utf8
            )
        ) == .sharedObjectUnsubscribe(key: "selected-project")
    )
    #expect(
        try CodexDesktopBridgeCodec.decodeViewPayload(
            Data(
                #"{"type":"shared-object-set","key":"selected-project"}"#
                    .utf8
            )
        ) == .sharedObjectSet(key: "selected-project", value: nil)
    )
    #expect(
        try CodexDesktopBridgeCodec.decodeViewPayload(
            Data(
                #"{"type":"shared-object-set","key":"selected-project","value":null}"#
                    .utf8
            )
        ) == .sharedObjectSet(key: "selected-project", value: .null)
    )
}

@Test
func desktopBridgeDistinguishesPersistedAtomNullFromDeletion() throws {
    #expect(
        try CodexDesktopBridgeCodec.decodeViewPayload(
            Data(
                #"{"type":"persisted-atom-update","key":"sidebar.open","value":null,"deleted":false}"#
                    .utf8
            )
        ) == .persistedAtomUpdate(
            CodexDesktopPersistedAtomUpdate(
                key: "sidebar.open",
                value: .null,
                deleted: false
            )
        )
    )
    #expect(
        try CodexDesktopBridgeCodec.decodeViewPayload(
            Data(
                #"{"type":"persisted-atom-update","key":"sidebar.open","value":null,"deleted":true}"#
                    .utf8
            )
        ) == .persistedAtomUpdate(
            CodexDesktopPersistedAtomUpdate(
                key: "sidebar.open",
                value: .null,
                deleted: true
            )
        )
    )
    #expect(
        try CodexDesktopBridgeCodec.decodeViewPayload(
            Data(
                #"{"type":"persisted-atom-update","key":"sidebar.open","deleted":true}"#
                    .utf8
            )
        ) == .persistedAtomUpdate(
            CodexDesktopPersistedAtomUpdate(
                key: "sidebar.open",
                value: nil,
                deleted: true
            )
        )
    )
    #expect(
        try CodexDesktopBridgeCodec.decodeViewPayload(
            Data(
                #"{"type":"persisted-atom-update","key":"sidebar.open","value":null}"#
                    .utf8
            )
        ) == .persistedAtomUpdate(
            CodexDesktopPersistedAtomUpdate(
                key: "sidebar.open",
                value: .null,
                deleted: false
            )
        )
    )
}

@Test
func desktopBridgePreservesKnownFirstScreenViewEventPayloads() throws {
    let payload = try CodexDesktopBridgeCodec.decodeViewPayload(
        Data(
            #"""
            {
              "type":"browser-sidebar-owner-sync",
              "conversationId":"thread-1",
              "browserTabId":null,
              "ownerRoutePath":"/thread/thread-1"
            }
            """#.utf8
        )
    )

    #expect(
        payload == .viewEvent(
            type: "browser-sidebar-owner-sync",
            payload: .object([
                "conversationId": .string("thread-1"),
                "browserTabId": .null,
                "ownerRoutePath": .string("/thread/thread-1"),
            ])
        )
    )

    let otherKnownFirstScreenTypes = [
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
    ]
    for type in otherKnownFirstScreenTypes {
        let data = try JSONEncoder().encode(
            CodexJSONValue.object([
                "type": .string(type),
                "fixture": .integer(7),
            ])
        )
        #expect(
            try CodexDesktopBridgeCodec.decodeViewPayload(data)
                == .viewEvent(
                    type: type,
                    payload: .object(["fixture": .integer(7)])
                )
        )
    }
}

@Test
func desktopBridgePreservesReleasedAppShellShortcutState() throws {
    let payload = try CodexDesktopBridgeCodec.decodeViewPayload(
        Data(
            #"""
            {
              "type":"app-shell-shortcut-state-changed",
              "bottomPanelBrowserCanZoom":false,
              "bottomPanelBrowserConversationId":null,
              "bottomPanelBrowserTabId":null,
              "canAcceptAppshotShortcut":true,
              "canRedoAppAction":false,
              "canUndoAppAction":true,
              "bottomPanelCanCloseActiveTab":false,
              "focusArea":"main",
              "focusedEditable":"composer",
              "imagePreviewOpen":false,
              "isNewChatRoute":true,
              "terminalFocused":false,
              "threadNavigationShortcutLocked":true,
              "rightPanelBrowserCanZoom":false,
              "rightPanelBrowserConversationId":null,
              "rightPanelBrowserTabId":null,
              "rightPanelCanCloseActiveTab":false
            }
            """#.utf8
        )
    )

    guard case let .viewEvent(type, value) = payload,
          case let .object(fields) = value
    else {
        Issue.record("Expected released app-shell shortcut state event")
        return
    }
    #expect(type == "app-shell-shortcut-state-changed")
    #expect(fields["focusArea"] == .string("main"))
    #expect(fields["focusedEditable"] == .string("composer"))
    #expect(fields["threadNavigationShortcutLocked"] == .bool(true))
    #expect(fields["canAcceptAppshotShortcut"] == .bool(true))
}

@Test
func desktopBridgePreservesExactWorkspaceOnboardingCommands() throws {
    let fixtures: [(String, String, CodexJSONValue)] = [
        (
            "electron-add-new-workspace-root-option",
            #"{"type":"electron-add-new-workspace-root-option","root":"/Projects/Codex"}"#,
            .object(["root": .string("/Projects/Codex")])
        ),
        (
            "electron-create-new-workspace-root-option",
            #"{"type":"electron-create-new-workspace-root-option","initializeGitRepository":true,"projectName":"My project"}"#,
            .object([
                "initializeGitRepository": .bool(true),
                "projectName": .string("My project"),
            ])
        ),
        (
            "electron-pick-workspace-root-option",
            #"{"type":"electron-pick-workspace-root-option","allowMultiple":false}"#,
            .object(["allowMultiple": .bool(false)])
        ),
        (
            "electron-update-workspace-root-options",
            #"{"type":"electron-update-workspace-root-options","roots":["/Projects/Codex"]}"#,
            .object([
                "roots": .array([.string("/Projects/Codex")])
            ])
        ),
        (
            "electron-onboarding-skip-workspace",
            #"{"type":"electron-onboarding-skip-workspace","initializeGitRepository":true,"projectName":"My project"}"#,
            .object([
                "initializeGitRepository": .bool(true),
                "projectName": .string("My project"),
            ])
        ),
        (
            "electron-onboarding-pick-workspace-or-create-default",
            #"{"type":"electron-onboarding-pick-workspace-or-create-default","defaultProjectName":"My project","initializeGitRepository":true}"#,
            .object([
                "defaultProjectName": .string("My project"),
                "initializeGitRepository": .bool(true),
            ])
        ),
        (
            "electron-rename-workspace-root-option",
            #"{"type":"electron-rename-workspace-root-option","label":"Codex iPad","root":"/Projects/Codex"}"#,
            .object([
                "label": .string("Codex iPad"),
                "root": .string("/Projects/Codex"),
            ])
        ),
        (
            "electron-set-active-workspace-root",
            #"{"type":"electron-set-active-workspace-root","root":"/Projects/Codex"}"#,
            .object(["root": .string("/Projects/Codex")])
        ),
        (
            "electron-clear-active-workspace-root",
            #"{"type":"electron-clear-active-workspace-root"}"#,
            .object([:])
        ),
    ]

    for (type, json, expectedPayload) in fixtures {
        #expect(
            try CodexDesktopBridgeCodec.decodeViewPayload(Data(json.utf8))
                == .viewEvent(type: type, payload: expectedPayload)
        )
    }
}

@Test
func desktopBridgePreservesReleasedInboxReadCommands() throws {
    let fixtures: [(String, String, CodexJSONValue)] = [
        (
            "inbox-item-set-read-state",
            #"{"type":"inbox-item-set-read-state","id":"inbox-1","isRead":true}"#,
            .object([
                "id": .string("inbox-1"),
                "isRead": .bool(true),
            ])
        ),
        (
            "inbox-automation-runs-mark-all-read",
            #"{"type":"inbox-automation-runs-mark-all-read","readAt":1785686400000}"#,
            .object([
                "readAt": .integer(1_785_686_400_000)
            ])
        ),
    ]

    for (type, json, expectedPayload) in fixtures {
        #expect(
            try CodexDesktopBridgeCodec.decodeViewPayload(Data(json.utf8))
                == .viewEvent(type: type, payload: expectedPayload)
        )
    }
}

@Test
func desktopBridgePreservesReleasedAuxiliaryViewCommands() throws {
    let fixtures: [(String, String, CodexJSONValue)] = [
        (
            "reload-bundled-plugins",
            #"{"type":"reload-bundled-plugins"}"#,
            .object([:])
        ),
        (
            "browser-sidebar-attach-dragged-image",
            #"{"type":"browser-sidebar-attach-dragged-image","browserTabId":"tab-1","conversationId":"thread-1"}"#,
            .object([
                "browserTabId": .string("tab-1"),
                "conversationId": .string("thread-1"),
            ])
        ),
        (
            "debug-window-origin-conversation-changed",
            #"{"type":"debug-window-origin-conversation-changed","conversationId":null}"#,
            .object(["conversationId": .null])
        ),
        (
            "browser-settings-webview-mounted",
            #"{"type":"browser-settings-webview-mounted","mountId":"mount-1","themeVariant":"dark"}"#,
            .object([
                "mountId": .string("mount-1"),
                "themeVariant": .string("dark"),
            ])
        ),
        (
            "browser-settings-webview-unmounted",
            #"{"type":"browser-settings-webview-unmounted","mountId":"mount-1"}"#,
            .object(["mountId": .string("mount-1")])
        ),
        (
            "browser-settings-webview-theme-changed",
            #"{"type":"browser-settings-webview-theme-changed","themeVariant":"light"}"#,
            .object(["themeVariant": .string("light")])
        ),
    ]

    for (type, json, expectedPayload) in fixtures {
        #expect(
            try CodexDesktopBridgeCodec.decodeViewPayload(Data(json.utf8))
                == .viewEvent(type: type, payload: expectedPayload)
        )
    }
}

@Test
func desktopBridgeRoundTripsReleasedChatSearchCommandMenu() throws {
    let decoded = try CodexDesktopBridgeCodec.decodeViewPayload(
        Data(#"{"type":"chat-search-command-menu"}"#.utf8)
    )
    #expect(
        decoded == .viewEvent(
            type: "chat-search-command-menu",
            payload: .object([:])
        )
    )

    let response = CodexDesktopCommandMenuHostRouter.response(
        to: "chat-search-command-menu",
        payload: .object([:])
    )
    #expect(
        response == .event(
            type: "chat-search-command-menu",
            payload: .object([:])
        )
    )
    #expect(
        CodexDesktopCommandMenuHostRouter.response(
            to: "unrelated-view-event",
            payload: .object([:])
        ) == nil
    )

    let encoded = try CodexDesktopBridgeCodec.encodeHostPayload(
        #require(response)
    )
    #expect(
        try JSONDecoder().decode(CodexJSONValue.self, from: encoded)
            == .object(["type": .string("chat-search-command-menu")])
    )
}

@Test
func desktopBridgeDecodesTheExactRendererFetchShape() throws {
    let decoded = try CodexDesktopBridgeCodec.decodeViewPayload(
        Data(
            #"""
            {
              "type":"fetch",
              "requestId":"request-1",
              "method":"POST",
              "url":"vscode://codex/thread/list",
              "headers":{"x-codex-source":"electron"},
              "body":"{\"limit\":20}",
              "reportUploadProgress":true
            }
            """#.utf8
        )
    )

    #expect(
        decoded == .fetch(
            CodexDesktopFetchRequest(
                requestID: "request-1",
                method: "POST",
                url: "vscode://codex/thread/list",
                hostMethod: "thread/list",
                headers: ["x-codex-source": "electron"],
                body: #"{"limit":20}"#,
                reportUploadProgress: true
            )
        )
    )
}

@Test
func desktopBridgeDecodesReleasedRendererNetworkFetchShapes() throws {
    let relative = try CodexDesktopBridgeCodec.decodeViewPayload(
        Data(
            #"""
            {
              "type":"fetch",
              "requestId":"request-wham",
              "method":"POST",
              "url":"/wham/statsig/bootstrap",
              "headers":{"X-OpenAI-Attach-Auth":"1"},
              "body":"{}"
            }
            """#.utf8
        )
    )
    let absolute = try CodexDesktopBridgeCodec.decodeViewPayload(
        Data(
            #"""
            {
              "type":"fetch",
              "requestId":"request-statsig",
              "method":"POST",
              "url":"https://ab.chatgpt.com/v1/initialize",
              "body":"{}"
            }
            """#.utf8
        )
    )

    #expect(
        relative == .fetch(
            CodexDesktopFetchRequest(
                requestID: "request-wham",
                method: "POST",
                url: "/wham/statsig/bootstrap",
                hostMethod: "",
                headers: ["X-OpenAI-Attach-Auth": "1"],
                body: "{}",
                reportUploadProgress: false
            )
        )
    )
    #expect(
        absolute == .fetch(
            CodexDesktopFetchRequest(
                requestID: "request-statsig",
                method: "POST",
                url: "https://ab.chatgpt.com/v1/initialize",
                hostMethod: "",
                headers: nil,
                body: "{}",
                reportUploadProgress: false
            )
        )
    )
}

@Test
func desktopBridgeDecodesTheExactRendererMCPRequestShape() throws {
    let decoded = try CodexDesktopBridgeCodec.decodeViewPayload(
        Data(
            #"""
            {
              "type":"mcp-request",
              "request":{
                "id":"mcp-1",
                "method":"config/read",
                "params":{"includeLayers":false,"cwd":null},
                "traceId":"trace-1"
              },
              "hostId":"local",
              "dispatchedAtMs":1722330000123,
              "priority":"normal",
              "source":"renderer",
              "timeoutMs":30000,
              "expiresAtMs":1722330030123,
              "spanId":"span-1"
            }
            """#.utf8
        )
    )

    #expect(
        decoded == .mcpRequest(
            CodexDesktopMCPRequest(
                request: CodexDesktopMCPRequestMessage(
                    id: .string("mcp-1"),
                    method: "config/read",
                    params: .object([
                        "includeLayers": .bool(false),
                        "cwd": .null,
                    ]),
                    metadata: ["traceId": .string("trace-1")]
                ),
                hostID: "local",
                dispatchedAtMs: .integer(1_722_330_000_123),
                priority: .string("normal"),
                source: .string("renderer"),
                timeoutMs: .integer(30_000),
                expiresAtMs: .integer(1_722_330_030_123),
                metadata: ["spanId": .string("span-1")]
            )
        )
    )

    #expect(
        try CodexDesktopBridgeCodec.decodeViewPayload(
            Data(
                #"""
                {
                  "type":"mcp-request",
                  "request":{"id":7,"method":"remoteControl/status/read"},
                  "hostId":"local",
                  "priority":"high",
                  "source":"startup"
                }
                """#.utf8
            )
        ) == .mcpRequest(
            CodexDesktopMCPRequest(
                request: CodexDesktopMCPRequestMessage(
                    id: .integer(7),
                    method: "remoteControl/status/read",
                    params: nil,
                    metadata: [:]
                ),
                hostID: "local",
                dispatchedAtMs: nil,
                priority: .string("high"),
                source: .string("startup"),
                timeoutMs: nil,
                expiresAtMs: nil,
                metadata: [:]
            )
        )
    )
}

@Test
func desktopBridgeRejectsUnknownMessagesAndExecutableFetchSchemes() throws {
    #expect(throws: CodexDesktopBridgeError.unsupportedType("mystery")) {
        try CodexDesktopBridgeCodec.decodeViewPayload(
            Data(#"{"type":"mystery"}"#.utf8)
        )
    }
    for url in [
        "file:///tmp/secret",
        "javascript:alert(1)",
        "codex-unknown:fixture",
    ] {
        let payload = try JSONEncoder().encode(
            CodexJSONValue.object([
                "type": .string("fetch"),
                "requestId": .string("request-2"),
                "method": .string("POST"),
                "url": .string(url),
            ])
        )
        #expect(throws: CodexDesktopBridgeError.invalidFetchURL) {
            try CodexDesktopBridgeCodec.decodeViewPayload(payload)
        }
    }
}

@Test
func desktopBridgeRoutesReleasedThreadPrewarmStartAsMCPRequest() throws {
    let decoded = try CodexDesktopBridgeCodec.decodeViewPayload(
        Data(
            #"{"type":"thread-prewarm-start","hostId":"local","priority":"critical","source":"thread","timeoutMs":30000,"expiresAtMs":1722330030123,"request":{"id":"prewarm-1","method":"thread/start","params":{"cwd":"/workspace/project"}}}"#.utf8
        )
    )
    guard case let .mcpRequest(request) = decoded else {
        Issue.record("thread prewarm did not route as an MCP request")
        return
    }
    #expect(request.hostID == "local")
    #expect(request.request.id == .string("prewarm-1"))
    #expect(request.request.method == "thread/start")
    #expect(request.timeoutMs == .integer(30_000))
}

@Test
func desktopBridgeEncodesOfficialFetchSuccessAndFailureMessages() throws {
    let success = try CodexDesktopBridgeCodec.encodeHostPayload(
        .fetchSuccess(
            requestID: "request-1",
            status: 200,
            headers: ["content-type": "application/json"],
            body: .object([
                "data": .array([]),
                "nextCursor": .null,
            ])
        )
    )
    let failure = try CodexDesktopBridgeCodec.encodeHostPayload(
        .fetchFailure(
            requestID: "request-2",
            status: 503,
            error: "host temporarily unavailable",
            errorCode: "host_unavailable"
        )
    )

    #expect(
        success
            == Data(
                #"""
                {"bodyJsonString":"{\"data\":[],\"nextCursor\":null}","headers":{"content-type":"application/json"},"requestId":"request-1","responseType":"success","status":200,"type":"fetch-response"}
                """#.utf8
            )
    )
    #expect(
        failure
            == Data(
                #"""
                {"error":"host temporarily unavailable","errorCode":"host_unavailable","requestId":"request-2","responseType":"error","status":503,"type":"fetch-response"}
                """#.utf8
            )
    )
}

@Test
func desktopBridgeEncodesTheExactMainToRendererMCPResponseShape() throws {
    let encoded = try CodexDesktopBridgeCodec.encodeHostPayload(
        .mcpResponse(
            hostID: "local",
            message: .object([
                "id": .string("mcp-1"),
                "result": .object([
                    "config": .object([:]),
                    "origins": .object([:]),
                    "layers": .null,
                ]),
            ]),
            metadata: [
                "receivedAtMs": .integer(1_722_330_000_200),
                "requestMethod": .string("config/read"),
                "traceId": .string("trace-1"),
            ]
        )
    )

    #expect(
        encoded
            == Data(
                #"""
                {"hostId":"local","message":{"id":"mcp-1","result":{"config":{},"layers":null,"origins":{}}},"receivedAtMs":1722330000200,"requestMethod":"config/read","traceId":"trace-1","type":"mcp-response"}
                """#.utf8
            )
    )
}

@Test
func desktopBridgeEncodesTheExactMainToRendererMCPNotificationShape() throws {
    let encoded = try CodexDesktopBridgeCodec.encodeHostPayload(
        .mcpNotification(
            hostID: "local",
            method: "item/agentMessage/delta",
            params: .object([
                "threadId": .string("thread/raw"),
                "turnId": .string("turn/raw"),
                "itemId": .string("item/raw"),
                "delta": .string("增量"),
            ]),
            metadata: [
                "receivedAtMs": .integer(1_722_330_000_201),
                "trace": .string("trace-1"),
            ]
        )
    )

    #expect(
        encoded
            == Data(
                #"""
                {"hostId":"local","method":"item/agentMessage/delta","params":{"delta":"增量","itemId":"item/raw","threadId":"thread/raw","turnId":"turn/raw"},"receivedAtMs":1722330000201,"trace":"trace-1","type":"mcp-notification"}
                """#.utf8
            )
    )
}

@Test
func desktopBridgeEncodesArbitraryHostEventsWithoutChangingTheirPayload() throws {
    let encoded = try CodexDesktopBridgeCodec.encodeHostPayload(
        .event(
            type: "turn/diff/updated",
            payload: .object([
                "conversationId": .string("thread-1"),
                "version": .integer(7),
            ])
        )
    )

    #expect(
        encoded
            == Data(
                #"{"conversationId":"thread-1","type":"turn/diff/updated","version":7}"#
                    .utf8
            )
    )
}

@Test
func desktopBridgeEncodesPersistedAtomDeletionWithOfficialNullMarker() throws {
    let deletion = try CodexDesktopBridgeCodec.encodeHostPayload(
        .event(
            type: "persisted-atom-updated",
            payload: .object([
                "key": .string("sidebar.open"),
                "deleted": .bool(true),
            ])
        )
    )
    let explicitNull = try CodexDesktopBridgeCodec.encodeHostPayload(
        .event(
            type: "persisted-atom-updated",
            payload: .object([
                "key": .string("sidebar.open"),
                "value": .null,
                "deleted": .bool(false),
            ])
        )
    )

    #expect(
        deletion
            == Data(
                #"{"deleted":true,"key":"sidebar.open","type":"persisted-atom-updated","value":null}"#
                    .utf8
            )
    )
    #expect(
        explicitNull
            == Data(
                #"{"deleted":false,"key":"sidebar.open","type":"persisted-atom-updated","value":null}"#
                    .utf8
            )
    )
}

@Test
func desktopBridgeEncodesSharedObjectUndefinedAsOmittedAndNullAsNull() throws {
    let undefined = try CodexDesktopBridgeCodec.encodeHostPayload(
        .event(
            type: "shared-object-updated",
            payload: .object([
                "key": .string("selected-project")
            ])
        )
    )
    let explicitNull = try CodexDesktopBridgeCodec.encodeHostPayload(
        .event(
            type: "shared-object-updated",
            payload: .object([
                "key": .string("selected-project"),
                "value": .null,
            ])
        )
    )

    #expect(
        undefined
            == Data(
                #"{"key":"selected-project","type":"shared-object-updated"}"#
                    .utf8
            )
    )
    #expect(
        explicitNull
            == Data(
                #"{"key":"selected-project","type":"shared-object-updated","value":null}"#
                    .utf8
            )
    )
}

@Test
func desktopBridgeDocumentStartScriptExposesEveryReleasedPreloadMember() throws {
    let script = try CodexDesktopBridgeScript.make(
        bootstrap: CodexDesktopBridgeBootstrap(
            preloadStartedAtMs: 1_234,
            systemThemeVariant: "dark",
            initialSidebarBootstrap: .object([:]),
            sharedObjectSnapshot: [:],
            sentryInitOptions: .object([
                "codexAppSessionId": .string("session-1")
            ]),
            buildFlavor: "production",
            appSessionID: "session-1",
            usesOwlAppShell: false
        )
    )
    let releasedMembers = [
        "windowType",
        "getPreloadStartedAtMs",
        "sendMessageFromView",
        "getPathForFile",
        "startFileDrag",
        "sendWorkerMessageFromView",
        "subscribeToWorkerMessages",
        "showContextMenu",
        "getFastModeRolloutMetrics",
        "getSharedObjectSnapshotValue",
        "getInitialSidebarBootstrap",
        "getSystemThemeVariant",
        "subscribeToSystemThemeVariant",
        "triggerSentryTestError",
        "getSentryInitOptions",
        "getAppSessionId",
        "getBuildFlavor",
        "isDeviceCheckSupported",
        "isIntelMacBuild",
        "usesOwlAppShell",
    ]

    for member in releasedMembers {
        #expect(script.contains("\(member):"))
    }
    #expect(script.contains("window.codexWindowType = \"electron\""))
    #expect(script.contains("window.electronBridge = bridge"))
    #expect(script.contains("codexDesktopBridge"))
    #expect(script.contains("new MessageEvent(\"message\""))
    #expect(script.contains("window.__codexDesktopHost"))
    #expect(script.contains(#"window.location.origin === "null""#))
    #expect(
        script.contains(
            #"targetOrigin === "null" ? "*" : targetOrigin"#
        )
    )
    #expect(script.contains(#""systemThemeVariant":"dark""#))
    #expect(script.contains(#""appSessionID":"session-1""#))
    #expect(script.contains("normalizeViewMessageForNative"))
    #expect(
        script.contains(
            #"message.type === "persisted-atom-update""#
        )
    )
    #expect(script.contains("normalized.value = null"))
    #expect(script.contains("delete normalized.value"))
}

@Test
func desktopBridgeCoalescesDuplicateTerminalToggleAtRendererIngress() throws {
    let script = try CodexDesktopBridgeScript.make(
        bootstrap: CodexDesktopBridgeBootstrap(
            preloadStartedAtMs: 1,
            systemThemeVariant: "dark",
            initialSidebarBootstrap: .null,
            sharedObjectSnapshot: [:],
            sentryInitOptions: .object([:]),
            buildFlavor: "production",
            appSessionID: "terminal-shortcut-dedup-test",
            usesOwlAppShell: true
        )
    )

    #expect(script.contains("lastTerminalToggleReceivedAt"))
    #expect(script.contains(#"message?.type === "toggle-terminal""#))
    #expect(script.contains("terminalToggleDuplicateIntervalMs"))
    #expect(script.contains("now - lastTerminalToggleReceivedAt"))
}

@Test
func desktopBridgeScopesAppHostPortsPerRendererSurface() throws {
    let script = try CodexDesktopBridgeScript.make(
        bootstrap: CodexDesktopBridgeBootstrap(
            preloadStartedAtMs: 1,
            systemThemeVariant: "dark",
            initialSidebarBootstrap: .null,
            sharedObjectSnapshot: [:],
            sentryInitOptions: .object([:]),
            buildFlavor: "prod",
            appSessionID: "session-overlay",
            usesOwlAppShell: true,
            appHostPortIDPrefix: "avatar-overlay-app-host"
        )
    )

    #expect(
        script.contains(
            "const portID = `\u{24}{bootstrap.appHostPortIDPrefix}-\u{24}{nextAppHostPortID}`;"
        )
    )
    #expect(script.contains(#""appHostPortIDPrefix":"avatar-overlay-app-host""#))
}

@Test
func desktopBridgeUsesReleasedRendererContextMenuFallbackOnIPad() throws {
    let script = try makeDesktopBridgeScriptFixture()

    // The released renderer already contains its complete DOM/CSS context-menu
    // implementation and selects it when this preload member is null.
    #expect(script.contains("showContextMenu: null"))
    #expect(!script.contains(#"nativePost("show-context-menu""#))
}

@Test
func desktopBridgeStartsWebKitFileDragSynchronouslyWhenDataTransferExists()
    throws
{
    let script = try makeDesktopBridgeScriptFixture()

    #expect(script.contains("window.event?.dataTransfer ?? null"))
    #expect(script.contains(#"typeof payload?.path !== "string""#))
    #expect(script.contains(#"dataTransfer.setData("text/plain", path)"#))
    #expect(
        script.contains(
            #"dataTransfer.setData("text/uri-list", fileURL)"#
        )
    )
    #expect(script.contains(#"new URL(`file://${path}`).href"#))
    #expect(script.contains(#"nativePost("start-file-drag", payload)"#))
    #expect(script.contains("return true"))
    #expect(script.contains("return false"))
}

@Test
func desktopBridgePreservesNestedJavaScriptErrorDetailsInRendererLogs()
    throws
{
    let script = try CodexDesktopBridgeScript.make(
        bootstrap: CodexDesktopBridgeBootstrap(
            preloadStartedAtMs: 1_234,
            systemThemeVariant: "dark",
            initialSidebarBootstrap: .object([:]),
            sharedObjectSnapshot: [:],
            sentryInitOptions: .object([:]),
            buildFlavor: "production",
            appSessionID: "session-1",
            usesOwlAppShell: false
        )
    )

    #expect(script.contains("normalizeDiagnosticValue"))
    #expect(script.contains("value instanceof Error"))
    #expect(script.contains("message: value.message"))
    #expect(script.contains("stack: value.stack ?? null"))
    #expect(
        script.contains(
            #"message.type === "log-message""#
        )
    )
    #expect(script.contains("normalized.tags = normalizeDiagnosticValue"))
}

@Test
func desktopBridgeReleasedSentryOptionsMatchOfficialDesktopMainContract()
    throws
{
    let options =
        CodexDesktopBridgeBootstrap.releasedSentryInitOptions(
            appSessionID: "session-sentry",
            appVersion: "26.721.81911",
            buildNumber: "5973"
        )
    let expected: CodexJSONValue = .object([
        "appVersion": .string("26.721.81911"),
        "buildFlavor": .string("prod"),
        "buildNumber": .string("5973"),
        "codexAppSessionId": .string("session-sentry"),
        "desktopTraceSampleRate": .number(0),
    ])

    #expect(options == expected)

    let script = try CodexDesktopBridgeScript.make(
        bootstrap: CodexDesktopBridgeBootstrap(
            preloadStartedAtMs: 1_234,
            systemThemeVariant: "dark",
            initialSidebarBootstrap: .null,
            sharedObjectSnapshot: [:],
            sentryInitOptions: options,
            buildFlavor: "prod",
            appSessionID: "session-sentry",
            usesOwlAppShell: false
        )
    )

    #expect(script.contains(#""appVersion":"26.721.81911""#))
    #expect(script.contains(#""buildFlavor":"prod""#))
    #expect(script.contains(#""buildNumber":"5973""#))
    #expect(script.contains(#""codexAppSessionId":"session-sentry""#))
    #expect(script.contains(#""desktopTraceSampleRate":0"#))
}

@Test
func desktopBridgeReleasedShellDefaultMatchesOfficialDesktopMainContract()
    throws
{
    #expect(CodexDesktopBridgeBootstrap.releasedUsesOwlAppShell)

    let script = try CodexDesktopBridgeScript.make(
        bootstrap: CodexDesktopBridgeBootstrap(
            preloadStartedAtMs: 1_234,
            systemThemeVariant: "dark",
            initialSidebarBootstrap: .null,
            sharedObjectSnapshot: [:],
            sentryInitOptions: .object([:]),
            buildFlavor: "prod",
            appSessionID: "session-owl",
            usesOwlAppShell:
                CodexDesktopBridgeBootstrap
                    .releasedUsesOwlAppShell
        )
    )

    #expect(script.contains(#""usesOwlAppShell":true"#))
    #expect(script.contains("usesOwlAppShell: () => bootstrap.usesOwlAppShell"))
}

@Test
func desktopBridgeDocumentStartScriptProxiesTheOfficialAppHostMessageChannel() throws {
    let script = try CodexDesktopBridgeScript.make(
        bootstrap: CodexDesktopBridgeBootstrap(
            preloadStartedAtMs: 1_234,
            systemThemeVariant: "dark",
            initialSidebarBootstrap: .object([:]),
            sharedObjectSnapshot: [:],
            sentryInitOptions: .object([:]),
            buildFlavor: "production",
            appSessionID: "session-app-host",
            usesOwlAppShell: false
        )
    )

    #expect(script.contains("const appHostPorts = new Map();"))
    #expect(script.contains(#"message?.type !== "connect-app-host""#))
    #expect(script.contains("message.port ?? event.ports?.[0]"))
    #expect(script.contains(#"nativePost("app-host-connected", {portID})"#))
    #expect(
        script.contains(
            #"nativePost("app-host-message", {portID, frame})"#
        )
    )
    #expect(script.contains(#"typeof responseFrame === "string""#))
    #expect(script.contains("port.postMessage(responseFrame)"))
    #expect(script.contains("appHostPorts.get(message.portID)"))
    #expect(script.contains("port.postMessage(message.frame)"))
}

@Test
func desktopBridgeScriptRejectsBootstrapWithInvalidTheme() throws {
    #expect(throws: CodexDesktopBridgeError.invalidSystemThemeVariant) {
        try CodexDesktopBridgeScript.make(
            bootstrap: CodexDesktopBridgeBootstrap(
                preloadStartedAtMs: 1,
                systemThemeVariant: "sepia",
                initialSidebarBootstrap: .null,
                sharedObjectSnapshot: [:],
                sentryInitOptions: .object([:]),
                buildFlavor: "production",
                appSessionID: "session-2",
                usesOwlAppShell: false
            )
        )
    }
}

private func makeDesktopBridgeScriptFixture() throws -> String {
    try CodexDesktopBridgeScript.make(
        bootstrap: CodexDesktopBridgeBootstrap(
            preloadStartedAtMs: 1_234,
            systemThemeVariant: "dark",
            initialSidebarBootstrap: .object([:]),
            sharedObjectSnapshot: [:],
            sentryInitOptions: .object([:]),
            buildFlavor: "production",
            appSessionID: "session-1",
            usesOwlAppShell: false
        )
    )
}
