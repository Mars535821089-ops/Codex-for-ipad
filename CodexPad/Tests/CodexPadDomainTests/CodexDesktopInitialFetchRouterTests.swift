import CodexPadDomain
import CodexPadProtocolBridge
import Foundation
import Testing

@testable import CodexPadApplication

private let desktopInitialHostState = CodexDesktopInitialHostState(
    codexHome: "/private/var/mobile/Containers/Data/Application/APP/Codex",
    worktreesSegment:
        "/private/var/mobile/Containers/Data/Application/APP/Codex/worktrees",
    platform: "darwin",
    osVersion: "18.5",
    osRelease: "24F74",
    isSystemBackdropSupported: false,
    isVsCodeRunningInsideWsl: false,
    windowsAccountType: "unknown",
    isCopilotAPIAvailable: false,
    configuredSettings: [
        "appearanceTheme": .string("dark")
    ],
    effectiveSettings: [
        "appearanceTheme": .string("dark"),
        "show-ultra-in-model-picker-slider": .bool(false),
    ],
    globalState: [
        "persisted": .bool(true)
    ],
    ideLocale: "zh-CN",
    systemLocale: "zh-Hans-CN",
    automationItems: [
        .object([
            "id": .string("automation-1"),
            "name": .string("Morning review"),
        ])
    ],
    activeWorkspaceRoots: [
        "/private/var/mobile/Containers/Data/Application/APP/Workspace"
    ],
    workspaceRootOptions: [
        "/private/var/mobile/Containers/Data/Application/APP/Workspace",
        "/private/var/mobile/Containers/Data/Application/APP/Other"
    ],
    remoteControlConnections: [
        .object([
            "hostId": .string("remote-host-1"),
            "online": .bool(true),
        ])
    ],
    inboxItems: [
        .object([
            "automationId": .string("automation-1"),
            "threadId": .string("thread-1"),
        ])
    ],
    unreadRunCount: 1,
    unreadAutomationIDs: ["automation-1"],
    unreadRuns: [
        .object([
            "automationId": .string("automation-1"),
            "threadId": .string("thread-1"),
        ])
    ],
    commandKeymapPath:
        "/private/var/mobile/Containers/Data/Application/APP/Codex/keybindings.json",
    commandKeyBindings: [
        .object([
            "command": .string("newTask"),
            "key": .string("Command+N"),
        ])
    ],
    existingPaths: [
        "/private/var/mobile/Containers/Data/Application/APP/Workspace",
        "/private/var/mobile/Containers/Data/Application/APP/Codex",
    ],
    pinnedThreadIDs: ["thread-pinned"],
    accountInfo: .object([
        "userId": .string("user-1"),
        "accountId": .string("account-1"),
        "email": .string("user@example.com"),
        "plan": .string("prolite"),
        "computeResidency": .null,
        "hasChatGptToken": .bool(true),
    ])
)

private let desktopEmptyCollectionHostState = CodexDesktopInitialHostState(
    codexHome: desktopInitialHostState.codexHome,
    worktreesSegment: desktopInitialHostState.worktreesSegment,
    platform: desktopInitialHostState.platform,
    osVersion: desktopInitialHostState.osVersion,
    osRelease: desktopInitialHostState.osRelease,
    isSystemBackdropSupported:
        desktopInitialHostState.isSystemBackdropSupported,
    isVsCodeRunningInsideWsl:
        desktopInitialHostState.isVsCodeRunningInsideWsl,
    windowsAccountType: desktopInitialHostState.windowsAccountType,
    isCopilotAPIAvailable:
        desktopInitialHostState.isCopilotAPIAvailable,
    configuredSettings: desktopInitialHostState.configuredSettings,
    effectiveSettings: desktopInitialHostState.effectiveSettings,
    globalState: desktopInitialHostState.globalState,
    ideLocale: desktopInitialHostState.ideLocale,
    systemLocale: desktopInitialHostState.systemLocale,
    automationItems: [],
    activeWorkspaceRoots: [],
    remoteControlConnections: [],
    inboxItems: [],
    unreadRunCount: 0,
    unreadAutomationIDs: [],
    unreadRuns: [],
    commandKeymapPath: desktopInitialHostState.commandKeymapPath,
    commandKeyBindings: [],
    existingPaths: [],
    pinnedThreadIDs: []
)

private func desktopInitialFetch(
    _ hostMethod: String,
    requestID: String = "request-1",
    body: String? = nil,
    method: String = "POST"
) -> CodexDesktopFetchRequest {
    CodexDesktopFetchRequest(
        requestID: requestID,
        method: method,
        url: "vscode://codex/\(hostMethod)",
        hostMethod: hostMethod,
        headers: nil,
        body: body,
        reportUploadProgress: false
    )
}

private func desktopFileHostState(
    codexHome: URL,
    workspaceRoot: URL
) -> CodexDesktopInitialHostState {
    CodexDesktopInitialHostState(
        codexHome: codexHome.path,
        worktreesSegment:
            codexHome.appendingPathComponent(
                "worktrees",
                isDirectory: true
            ).path,
        platform: desktopInitialHostState.platform,
        osVersion: desktopInitialHostState.osVersion,
        osRelease: desktopInitialHostState.osRelease,
        isSystemBackdropSupported:
            desktopInitialHostState
                .isSystemBackdropSupported,
        isVsCodeRunningInsideWsl:
            desktopInitialHostState
                .isVsCodeRunningInsideWsl,
        windowsAccountType:
            desktopInitialHostState.windowsAccountType,
        isCopilotAPIAvailable:
            desktopInitialHostState
                .isCopilotAPIAvailable,
        configuredSettings:
            desktopInitialHostState.configuredSettings,
        effectiveSettings:
            desktopInitialHostState.effectiveSettings,
        globalState:
            desktopInitialHostState.globalState,
        ideLocale: desktopInitialHostState.ideLocale,
        systemLocale:
            desktopInitialHostState.systemLocale,
        automationItems: [],
        activeWorkspaceRoots: [workspaceRoot.path],
        workspaceRootOptions: [workspaceRoot.path],
        remoteControlConnections: [],
        inboxItems: [],
        unreadRunCount: 0,
        unreadAutomationIDs: [],
        unreadRuns: [],
        commandKeymapPath:
            codexHome.appendingPathComponent(
                "keybindings.json"
            ).path,
        commandKeyBindings: [],
        existingPaths: [
            codexHome.path,
            workspaceRoot.path,
        ],
        pinnedThreadIDs: []
    )
}

@Test
func desktopInitialFetchRouterReturnsTheReleasedSettingsShape() {
    let response = CodexDesktopInitialFetchRouter.response(
        to: desktopInitialFetch("get-settings"),
        state: desktopInitialHostState
    )

    #expect(
        response == .fetchSuccess(
            requestID: "request-1",
            status: 200,
            headers: ["content-type": "application/json"],
            body: .object([
                "configuredValues": .object([
                    "appearanceTheme": .string("dark")
                ]),
                "values": .object([
                    "appearanceTheme": .string("dark"),
                    "show-ultra-in-model-picker-slider": .bool(false),
                ]),
            ])
        )
    )
}

@Test
func desktopInitialFetchRouterReturnsRealCodexHomeAndOSInformation() {
    let home = CodexDesktopInitialFetchRouter.response(
        to: desktopInitialFetch(
            "codex-home",
            body: #"{"hostId":"local"}"#
        ),
        state: desktopInitialHostState
    )
    let os = CodexDesktopInitialFetchRouter.response(
        to: desktopInitialFetch("os-info", requestID: "request-os"),
        state: desktopInitialHostState
    )

    #expect(
        home == .fetchSuccess(
            requestID: "request-1",
            status: 200,
            headers: ["content-type": "application/json"],
            body: .object([
                "codexHome": .string(desktopInitialHostState.codexHome),
                "worktreesSegment": .string(
                    desktopInitialHostState.worktreesSegment
                ),
            ])
        )
    )
    #expect(
        os == .fetchSuccess(
            requestID: "request-os",
            status: 200,
            headers: ["content-type": "application/json"],
            body: .object([
                "platform": .string("darwin"),
                "osVersion": .string("18.5"),
                "osRelease": .string("24F74"),
                "isSystemBackdropSupported": .bool(false),
                "isVsCodeRunningInsideWsl": .bool(false),
                "windowsAccountType": .string("unknown"),
            ])
        )
    )
}

@Test
func desktopInitialFetchRouterMatchesCopilotAndGlobalStateSemantics() {
    let copilot = CodexDesktopInitialFetchRouter.response(
        to: desktopInitialFetch("is-copilot-api-available"),
        state: desktopInitialHostState
    )
    let copilotProxy = CodexDesktopInitialFetchRouter.response(
        to: desktopInitialFetch(
            "get-copilot-api-proxy-info",
            requestID: "request-copilot-proxy"
        ),
        state: desktopInitialHostState
    )
    let present = CodexDesktopInitialFetchRouter.response(
        to: desktopInitialFetch(
            "get-global-state",
            requestID: "request-present",
            body: #"{"key":"persisted"}"#
        ),
        state: desktopInitialHostState
    )
    let missing = CodexDesktopInitialFetchRouter.response(
        to: desktopInitialFetch(
            "get-global-state",
            requestID: "request-missing",
            body: #"{"key":"missing"}"#
        ),
        state: desktopInitialHostState
    )

    #expect(
        copilot == .fetchSuccess(
            requestID: "request-1",
            status: 200,
            headers: ["content-type": "application/json"],
            body: .object(["available": .bool(false)])
        )
    )
    #expect(
        copilotProxy == .fetchSuccess(
            requestID: "request-copilot-proxy",
            status: 200,
            headers: ["content-type": "application/json"],
            body: .null
        )
    )
    #expect(
        present == .fetchSuccess(
            requestID: "request-present",
            status: 200,
            headers: ["content-type": "application/json"],
            body: .object(["value": .bool(true)])
        )
    )
    #expect(
        missing == .fetchSuccess(
            requestID: "request-missing",
            status: 200,
            headers: ["content-type": "application/json"],
            body: .object([:])
        )
    )
}

@Test
func desktopInitialFetchRouterReturnsReleasedChatGPTAccountInfoShape() {
    let response = CodexDesktopInitialFetchRouter.response(
        to: desktopInitialFetch(
            "account-info",
            requestID: "request-account-info"
        ),
        state: desktopInitialHostState
    )

    #expect(
        response == .fetchSuccess(
            requestID: "request-account-info",
            status: 200,
            headers: ["content-type": "application/json"],
            body: .object([
                "userId": .string("user-1"),
                "accountId": .string("account-1"),
                "email": .string("user@example.com"),
                "plan": .string("prolite"),
                "computeResidency": .null,
                "hasChatGptToken": .bool(true),
            ])
        )
    )
}

@Test
func desktopInitialFetchRouterReturnsSettingAndLocaleProviderValues() {
    let setting = CodexDesktopInitialFetchRouter.response(
        to: desktopInitialFetch(
            "get-setting",
            requestID: "request-setting",
            body: #"{"key":"show-ultra-in-model-picker-slider"}"#
        ),
        state: desktopInitialHostState
    )
    let missingSetting = CodexDesktopInitialFetchRouter.response(
        to: desktopInitialFetch(
            "get-setting",
            requestID: "request-setting-missing",
            body: #"{"key":"not-configured"}"#
        ),
        state: desktopInitialHostState
    )
    let locale = CodexDesktopInitialFetchRouter.response(
        to: desktopInitialFetch("locale-info", requestID: "request-locale"),
        state: desktopInitialHostState
    )

    #expect(
        setting == .fetchSuccess(
            requestID: "request-setting",
            status: 200,
            headers: ["content-type": "application/json"],
            body: .object(["value": .bool(false)])
        )
    )
    #expect(
        missingSetting == .fetchSuccess(
            requestID: "request-setting-missing",
            status: 200,
            headers: ["content-type": "application/json"],
            body: .object([:])
        )
    )
    #expect(
        locale == .fetchSuccess(
            requestID: "request-locale",
            status: 200,
            headers: ["content-type": "application/json"],
            body: .object([
                "ideLocale": .string("zh-CN"),
                "systemLocale": .string("zh-Hans-CN"),
            ])
        )
    )
}

@Test
func desktopInitialFetchRouterReturnsReleasedCollectionShapes() {
    let automations = CodexDesktopInitialFetchRouter.response(
        to: desktopInitialFetch(
            "list-automations",
            requestID: "request-automations"
        ),
        state: desktopInitialHostState
    )
    let workspaceRoots = CodexDesktopInitialFetchRouter.response(
        to: desktopInitialFetch(
            "active-workspace-roots",
            requestID: "request-roots"
        ),
        state: desktopInitialHostState
    )
    let workspaceOptions = CodexDesktopInitialFetchRouter.response(
        to: desktopInitialFetch(
            "workspace-root-options",
            requestID: "request-root-options",
            body: #"{"hostId":"local"}"#
        ),
        state: desktopInitialHostState
    )
    let inbox = CodexDesktopInitialFetchRouter.response(
        to: desktopInitialFetch(
            "inbox-items",
            requestID: "request-inbox",
            body: #"{"limit":200}"#
        ),
        state: desktopInitialHostState
    )
    let keymap = CodexDesktopInitialFetchRouter.response(
        to: desktopInitialFetch(
            "codex-command-keymap-state",
            requestID: "request-keymap"
        ),
        state: desktopInitialHostState
    )
    let pinnedThreads = CodexDesktopInitialFetchRouter.response(
        to: desktopInitialFetch(
            "list-pinned-threads",
            requestID: "request-pinned"
        ),
        state: desktopInitialHostState
    )

    #expect(
        automations == .fetchSuccess(
            requestID: "request-automations",
            status: 200,
            headers: ["content-type": "application/json"],
            body: .object([
                "items": .array([
                    .object([
                        "id": .string("automation-1"),
                        "name": .string("Morning review"),
                    ])
                ])
            ])
        )
    )
    #expect(
        workspaceRoots == .fetchSuccess(
            requestID: "request-roots",
            status: 200,
            headers: ["content-type": "application/json"],
            body: .object([
                "roots": .array([
                    .string(
                        "/private/var/mobile/Containers/Data/Application/APP/Workspace"
                    )
                ])
            ])
        )
    )
    #expect(
        workspaceOptions == .fetchSuccess(
            requestID: "request-root-options",
            status: 200,
            headers: ["content-type": "application/json"],
            body: .object([
                "roots": .array([
                    .string(
                        "/private/var/mobile/Containers/Data/Application/APP/Workspace"
                    ),
                    .string(
                        "/private/var/mobile/Containers/Data/Application/APP/Other"
                    ),
                ]),
                "labels": .object([:]),
            ])
        )
    )
    #expect(
        inbox == .fetchSuccess(
            requestID: "request-inbox",
            status: 200,
            headers: ["content-type": "application/json"],
            body: .object([
                "items": .array([
                    .object([
                        "automationId": .string("automation-1"),
                        "threadId": .string("thread-1"),
                    ])
                ]),
                "unreadRunCounts": .object([
                    "total": .integer(1),
                    "automationIds": .array([
                        .string("automation-1")
                    ]),
                    "unreadRuns": .array([
                        .object([
                            "automationId": .string("automation-1"),
                            "threadId": .string("thread-1"),
                        ])
                    ]),
                ]),
            ])
        )
    )
    #expect(
        keymap == .fetchSuccess(
            requestID: "request-keymap",
            status: 200,
            headers: ["content-type": "application/json"],
            body: .object([
                "supported": .bool(true),
                "keymapPath": .string(
                    "/private/var/mobile/Containers/Data/Application/APP/Codex/keybindings.json"
                ),
                "bindings": .array([
                    .object([
                        "command": .string("newTask"),
                        "key": .string("Command+N"),
                    ])
                ]),
            ])
        )
    )
    #expect(
        pinnedThreads == .fetchSuccess(
            requestID: "request-pinned",
            status: 200,
            headers: ["content-type": "application/json"],
            body: .object([
                "threadIds": .array([
                    .string("thread-pinned")
                ])
            ])
        )
    )
}

@Test
func desktopInitialFetchRouterPreservesReleasedEmptyCollectionShapes() {
    let cases: [
        (
            request: CodexDesktopFetchRequest,
            expectedBody: CodexJSONValue
        )
    ] = [
        (
            desktopInitialFetch(
                "list-automations",
                requestID: "empty-automations"
            ),
            .object(["items": .array([])])
        ),
        (
            desktopInitialFetch(
                "active-workspace-roots",
                requestID: "empty-roots"
            ),
            .object(["roots": .array([])])
        ),
        (
            desktopInitialFetch(
                "set-remote-control-connections-enabled",
                requestID: "empty-remote",
                body: #"{"enabled":true}"#
            ),
            .object(["remoteControlConnections": .array([])])
        ),
        (
            desktopInitialFetch(
                "inbox-items",
                requestID: "empty-inbox",
                body: #"{"limit":200}"#
            ),
            .object([
                "items": .array([]),
                "unreadRunCounts": .object([
                    "total": .integer(0),
                    "automationIds": .array([]),
                    "unreadRuns": .array([]),
                ]),
            ])
        ),
        (
            desktopInitialFetch(
                "codex-command-keymap-state",
                requestID: "empty-keymap"
            ),
            .object([
                "supported": .bool(true),
                "keymapPath": .string(
                    desktopEmptyCollectionHostState.commandKeymapPath
                ),
                "bindings": .array([]),
            ])
        ),
        (
            desktopInitialFetch(
                "paths-exist",
                requestID: "empty-paths",
                body: #"{"hostId":"local","paths":[]}"#
            ),
            .object(["existingPaths": .array([])])
        ),
        (
            desktopInitialFetch(
                "list-pinned-threads",
                requestID: "empty-pinned"
            ),
            .object(["threadIds": .array([])])
        ),
    ]

    for testCase in cases {
        #expect(
            CodexDesktopInitialFetchRouter.response(
                to: testCase.request,
                state: desktopEmptyCollectionHostState
            ) == .fetchSuccess(
                requestID: testCase.request.requestID,
                status: 200,
                headers: ["content-type": "application/json"],
                body: testCase.expectedBody
            )
        )
    }
}

@Test
func desktopInitialFetchRouterOwnsReleasedPinnedThreadMutations() {
    let suiteName =
        "CodexDesktopInitialFetchPinnedTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer {
        defaults.removePersistentDomain(forName: suiteName)
    }
    let store = CodexDesktopPinnedThreadStore(
        userDefaults: defaults
    )

    let pinSecond = CodexDesktopInitialFetchRouter.response(
        to: desktopInitialFetch(
            "set-thread-pinned",
            requestID: "pin-second",
            body:
                #"{"threadId":"thread-2","pinned":true}"#
        ),
        state: desktopInitialHostState,
        pinnedThreadStore: store
    )
    let pinFirstBeforeSecond =
        CodexDesktopInitialFetchRouter.response(
            to: desktopInitialFetch(
                "set-thread-pinned",
                requestID: "pin-first",
                body:
                    #"{"threadId":"thread-1","pinned":true,"beforeThreadId":"thread-2"}"#
            ),
            state: desktopInitialHostState,
            pinnedThreadStore: store
        )
    let listBeforeReorder =
        CodexDesktopInitialFetchRouter.response(
            to: desktopInitialFetch(
                "list-pinned-threads",
                requestID: "list-before-reorder"
            ),
            state: desktopInitialHostState,
            pinnedThreadStore: store
        )
    let reorder = CodexDesktopInitialFetchRouter.response(
        to: desktopInitialFetch(
            "set-pinned-threads-order",
            requestID: "reorder",
            body:
                #"{"threadIds":["thread-2","thread-1"]}"#
        ),
        state: desktopInitialHostState,
        pinnedThreadStore: store
    )
    let unpinFirst = CodexDesktopInitialFetchRouter.response(
        to: desktopInitialFetch(
            "set-thread-pinned",
            requestID: "unpin-first",
            body:
                #"{"threadId":"thread-1","pinned":false}"#
        ),
        state: desktopInitialHostState,
        pinnedThreadStore: store
    )
    let listFinal = CodexDesktopInitialFetchRouter.response(
        to: desktopInitialFetch(
            "list-pinned-threads",
            requestID: "list-final"
        ),
        state: desktopInitialHostState,
        pinnedThreadStore: store
    )

    for (requestID, response) in [
        ("pin-second", pinSecond),
        ("pin-first", pinFirstBeforeSecond),
        ("reorder", reorder),
        ("unpin-first", unpinFirst),
    ] {
        #expect(
            response == .fetchSuccess(
                requestID: requestID,
                status: 200,
                headers: ["content-type": "application/json"],
                body: .object(["success": .bool(true)])
            )
        )
    }
    #expect(
        listBeforeReorder == .fetchSuccess(
            requestID: "list-before-reorder",
            status: 200,
            headers: ["content-type": "application/json"],
            body: .object([
                "threadIds": .array([
                    .string("thread-1"),
                    .string("thread-2"),
                ])
            ])
        )
    )
    #expect(
        listFinal == .fetchSuccess(
            requestID: "list-final",
            status: 200,
            headers: ["content-type": "application/json"],
            body: .object([
                "threadIds": .array([
                    .string("thread-2")
                ])
            ])
        )
    )
}

@Test
func desktopInitialFetchRouterFiltersPathsAndRemoteConnections() {
    let existingPaths = CodexDesktopInitialFetchRouter.response(
        to: desktopInitialFetch(
            "paths-exist",
            requestID: "request-paths",
            body:
                #"{"hostId":"local","paths":["/private/var/mobile/Containers/Data/Application/APP/Workspace","/missing"]}"#
        ),
        state: desktopInitialHostState
    )
    let enabledConnections = CodexDesktopInitialFetchRouter.response(
        to: desktopInitialFetch(
            "set-remote-control-connections-enabled",
            requestID: "request-remote-enabled",
            body: #"{"enabled":true}"#
        ),
        state: desktopInitialHostState
    )
    let disabledConnections = CodexDesktopInitialFetchRouter.response(
        to: desktopInitialFetch(
            "set-remote-control-connections-enabled",
            requestID: "request-remote-disabled",
            body: #"{"enabled":false}"#
        ),
        state: desktopInitialHostState
    )

    #expect(
        existingPaths == .fetchSuccess(
            requestID: "request-paths",
            status: 200,
            headers: ["content-type": "application/json"],
            body: .object([
                "existingPaths": .array([
                    .string(
                        "/private/var/mobile/Containers/Data/Application/APP/Workspace"
                    )
                ])
            ])
        )
    )
    #expect(
        enabledConnections == .fetchSuccess(
            requestID: "request-remote-enabled",
            status: 200,
            headers: ["content-type": "application/json"],
            body: .object([
                "remoteControlConnections": .array([
                    .object([
                        "hostId": .string("remote-host-1"),
                        "online": .bool(true),
                    ])
                ])
            ])
        )
    )
    #expect(
        disabledConnections == .fetchSuccess(
            requestID: "request-remote-disabled",
            status: 200,
            headers: ["content-type": "application/json"],
            body: .object([
                "remoteControlConnections": .array([])
            ])
        )
    )
}

@Test
func desktopInitialFetchRouterImplementsTheReleasedWSLConnectionsContract() {
    let enabled = CodexDesktopInitialFetchRouter.response(
        to: desktopInitialFetch(
            "set-remote-wsl-connections-enabled",
            requestID: "request-wsl-enabled",
            body: #"{"enabled":true}"#
        ),
        state: desktopInitialHostState
    )
    let disabled = CodexDesktopInitialFetchRouter.response(
        to: desktopInitialFetch(
            "set-remote-wsl-connections-enabled",
            requestID: "request-wsl-disabled",
            body: #"{"enabled":false}"#
        ),
        state: desktopInitialHostState
    )
    let invalid = CodexDesktopInitialFetchRouter.response(
        to: desktopInitialFetch(
            "set-remote-wsl-connections-enabled",
            requestID: "request-wsl-invalid",
            body: #"{"enabled":"yes"}"#
        ),
        state: desktopInitialHostState
    )

    for (requestID, response) in [
        ("request-wsl-enabled", enabled),
        ("request-wsl-disabled", disabled),
    ] {
        #expect(
            response == .fetchSuccess(
                requestID: requestID,
                status: 200,
                headers: ["content-type": "application/json"],
                body: .object([
                    "remoteWslConnections": .array([])
                ])
            )
        )
    }
    #expect(
        invalid == .fetchFailure(
            requestID: "request-wsl-invalid",
            status: 432,
            error:
                "Invalid VS Code bridge request body: set-remote-wsl-connections-enabled",
            errorCode: "invalid_request_body"
        )
    )
}

@Test
func desktopInitialFetchRouterUsesTheReleased432FailureContract() {
    let unsupported = CodexDesktopInitialFetchRouter.response(
        to: desktopInitialFetch("unknown-host-method"),
        state: desktopInitialHostState
    )
    let invalidSetting = CodexDesktopInitialFetchRouter.response(
        to: desktopInitialFetch(
            "get-setting",
            requestID: "request-invalid-setting",
            body: #"{"key":""}"#
        ),
        state: desktopInitialHostState
    )
    let invalidRemoteConnections = CodexDesktopInitialFetchRouter.response(
        to: desktopInitialFetch(
            "set-remote-control-connections-enabled",
            requestID: "request-invalid-remote",
            body: #"{"enabled":"yes"}"#
        ),
        state: desktopInitialHostState
    )
    let invalidPaths = CodexDesktopInitialFetchRouter.response(
        to: desktopInitialFetch(
            "paths-exist",
            requestID: "request-invalid-paths",
            body: #"{"hostId":"local","paths":[1]}"#
        ),
        state: desktopInitialHostState
    )
    let invalidBody = CodexDesktopInitialFetchRouter.response(
        to: desktopInitialFetch(
            "get-global-state",
            requestID: "request-invalid",
            body: #"{"wrong":"field"}"#
        ),
        state: desktopInitialHostState
    )

    #expect(
        unsupported == .fetchFailure(
            requestID: "request-1",
            status: 432,
            error: "Unsupported VS Code bridge request: unknown-host-method",
            errorCode: "unsupported_host_method"
        )
    )
    #expect(
        invalidBody == .fetchFailure(
            requestID: "request-invalid",
            status: 432,
            error: "Invalid VS Code bridge request body: get-global-state",
            errorCode: "invalid_request_body"
        )
    )
    #expect(
        invalidSetting == .fetchFailure(
            requestID: "request-invalid-setting",
            status: 432,
            error: "Invalid VS Code bridge request body: get-setting",
            errorCode: "invalid_request_body"
        )
    )
    #expect(
        invalidRemoteConnections == .fetchFailure(
            requestID: "request-invalid-remote",
            status: 432,
            error:
                "Invalid VS Code bridge request body: set-remote-control-connections-enabled",
            errorCode: "invalid_request_body"
        )
    )
    #expect(
        invalidPaths == .fetchFailure(
            requestID: "request-invalid-paths",
            status: 432,
            error: "Invalid VS Code bridge request body: paths-exist",
            errorCode: "invalid_request_body"
        )
    )
}

@Test
func desktopInitialFetchRouterOwnsTheReleasedAutomationCRUDContract()
    throws
{
    let codexHome = FileManager.default.temporaryDirectory
        .appendingPathComponent(
            "CodexDesktopInitialFetchAutomationTests-\(UUID().uuidString)",
            isDirectory: true
        )
    defer { try? FileManager.default.removeItem(at: codexHome) }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let now = calendar.date(
        from: DateComponents(
            timeZone: calendar.timeZone,
            year: 2026,
            month: 8,
            day: 2,
            hour: 10
        )
    )!
    let store = try CodexDesktopAutomationStore(
        codexHome: codexHome,
        calendar: calendar
    )
    let create = CodexDesktopInitialFetchRouter.response(
        to: desktopInitialFetch(
            "automation-create",
            requestID: "request-create",
            body:
                #"{"kind":"heartbeat","name":"Follow up","prompt":"Check the latest result.","targetThreadId":"thread-1","model":null,"reasoningEffort":null,"rrule":"FREQ=MINUTELY;INTERVAL=30"}"#
        ),
        state: desktopInitialHostState,
        automationStore: store,
        now: now
    )
    guard case let .fetchSuccess(
        requestID,
        status,
        headers,
        .object(createBody)
    ) = create,
          case let .object(item)? = createBody["item"],
          case let .string(id)? = item["id"]
    else {
        Issue.record("automation-create must return { item }")
        return
    }
    #expect(requestID == "request-create")
    #expect(status == 200)
    #expect(headers == ["content-type": "application/json"])
    #expect(item["status"] == .string("ACTIVE"))

    let list = CodexDesktopInitialFetchRouter.response(
        to: desktopInitialFetch(
            "list-automations",
            requestID: "request-list"
        ),
        state: desktopInitialHostState,
        automationStore: store,
        now: now
    )
    #expect(
        list == .fetchSuccess(
            requestID: "request-list",
            status: 200,
            headers: ["content-type": "application/json"],
            body: .object([
                "items": .array([.object(item)])
            ])
        )
    )

    let updateBody = """
    {"id":"\(id)","kind":"heartbeat","name":"Follow up","prompt":"Check the latest result.","status":"PAUSED","targetThreadId":"thread-1","model":null,"reasoningEffort":null,"notificationPolicy":null,"rrule":"FREQ=MINUTELY;INTERVAL=30"}
    """
    let update = CodexDesktopInitialFetchRouter.response(
        to: desktopInitialFetch(
            "automation-update",
            requestID: "request-update",
            body: updateBody
        ),
        state: desktopInitialHostState,
        automationStore: store,
        now: now
    )
    guard case let .fetchSuccess(
        _,
        _,
        _,
        .object(updateResponse)
    ) = update,
          case let .object(updatedItem)? =
              updateResponse["item"]
    else {
        Issue.record("automation-update must return { item }")
        return
    }
    #expect(updatedItem["status"] == .string("PAUSED"))
    #expect(updatedItem["nextRunAt"] == .null)

    let delete = CodexDesktopInitialFetchRouter.response(
        to: desktopInitialFetch(
            "automation-delete",
            requestID: "request-delete",
            body: #"{"id":"\#(id)"}"#
        ),
        state: desktopInitialHostState,
        automationStore: store,
        now: now
    )
    #expect(
        delete == .fetchSuccess(
            requestID: "request-delete",
            status: 200,
            headers: ["content-type": "application/json"],
            body: .object([
                "item": .object(updatedItem),
                "status": .string("deleted"),
                "success": .bool(true),
            ])
        )
    )
}

@Test
func desktopInitialFetchRouterPersistsReleasedGlobalConfigurationAndSettings()
    throws
{
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(
            "CodexDesktopInitialFetchSettingsTests-\(UUID().uuidString)",
            isDirectory: true
        )
    let codexHome = root.appendingPathComponent(
        "Codex",
        isDirectory: true
    )
    let workspace = root.appendingPathComponent(
        "Workspace",
        isDirectory: true
    )
    try FileManager.default.createDirectory(
        at: workspace,
        withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: root) }

    let suite =
        "CodexDesktopInitialFetchSettingsTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defaults.removePersistentDomain(forName: suite)
    defer { defaults.removePersistentDomain(forName: suite) }

    let globalState = CodexDesktopPersistedAtomStore(
        userDefaults: defaults,
        storageKey: "global-state"
    )
    let config = CodexDesktopConfigStore(
        userDefaults: defaults,
        storageKey: "configuration"
    )
    let settingsPath = codexHome
        .appendingPathComponent("settings.json").path
    let state = desktopFileHostState(
        codexHome: codexHome,
        workspaceRoot: workspace
    )

    let setGlobal = CodexDesktopInitialFetchRouter.response(
        to: desktopInitialFetch(
            "set-global-state",
            requestID: "set-global",
            body: #"{"key":"sidebar-density","value":"compact"}"#
        ),
        state: state,
        globalStateStore: globalState,
        configStore: config,
        settingsFilePath: settingsPath
    )
    #expect(
        setGlobal == .fetchSuccess(
            requestID: "set-global",
            status: 200,
            headers: ["content-type": "application/json"],
            body: .object(["success": .bool(true)])
        )
    )
    #expect(
        globalState.snapshot["sidebar-density"]
            == .string("compact")
    )

    let getGlobal = CodexDesktopInitialFetchRouter.response(
        to: desktopInitialFetch(
            "get-global-state",
            requestID: "get-global",
            body: #"{"key":"sidebar-density"}"#
        ),
        state: state,
        globalStateStore: globalState
    )
    #expect(
        getGlobal == .fetchSuccess(
            requestID: "get-global",
            status: 200,
            headers: ["content-type": "application/json"],
            body: .object(["value": .string("compact")])
        )
    )

    let setConfiguration =
        CodexDesktopInitialFetchRouter.response(
            to: desktopInitialFetch(
                "set-configuration",
                requestID: "set-configuration",
                body:
                    #"{"key":"appearanceTheme","value":"light"}"#
            ),
            state: state,
            globalStateStore: globalState,
            configStore: config,
            settingsFilePath: settingsPath
        )
    #expect(
        setConfiguration == .fetchSuccess(
            requestID: "set-configuration",
            status: 200,
            headers: ["content-type": "application/json"],
            body: .object(["success": .bool(true)])
        )
    )
    #expect(
        globalState.snapshot["appearanceTheme"]
            == .string("light")
    )
    #expect(
        config.snapshot["appearanceTheme"]
            == .string("light")
    )

    let setSetting = CodexDesktopInitialFetchRouter.response(
        to: desktopInitialFetch(
            "set-setting",
            requestID: "set-setting",
            body: #"{"key":"codeFontSize","value":15}"#
        ),
        state: state,
        configStore: config,
        settingsFilePath: settingsPath
    )
    #expect(
        setSetting == .fetchSuccess(
            requestID: "set-setting",
            status: 200,
            headers: ["content-type": "application/json"],
            body: .object(["success": .bool(true)])
        )
    )

    let read = CodexDesktopInitialFetchRouter.response(
        to: desktopInitialFetch(
            "settings-read",
            requestID: "settings-read"
        ),
        state: state,
        configStore: config,
        settingsFilePath: settingsPath
    )
    guard case let .fetchSuccess(
        _,
        200,
        _,
        .object(readBody)
    ) = read,
          case let .object(settings)? = readBody["settings"],
          case let .object(effective)? =
              readBody["effectiveSettings"],
          case let .array(definitions)? =
              readBody["definitions"]
    else {
        Issue.record("settings-read must return the released shape")
        return
    }
    #expect(settings["appearanceTheme"] == .string("light"))
    #expect(settings["codeFontSize"] == .integer(15))
    #expect(effective["appearanceTheme"] == .string("light"))
    #expect(effective["sansFontSize"] == .integer(14))
    #expect(!definitions.isEmpty)
    #expect(
        definitions.contains {
            guard case let .object(definition) = $0 else {
                return false
            }
            return definition["key"]
                    == .string("git-commit-instructions")
                && definition["agentAccess"]
                    == .string("read-only")
        }
    )

    let write = CodexDesktopInitialFetchRouter.response(
        to: desktopInitialFetch(
            "settings-write",
            requestID: "settings-write",
            body:
                #"{"settings":{"followUpQueueMode":"queue","preventSleepWhileRunning":true}}"#
        ),
        state: state,
        configStore: config,
        settingsFilePath: settingsPath
    )
    guard case let .fetchSuccess(
        _,
        200,
        _,
        .object(writeBody)
    ) = write,
          case let .object(writtenSettings)? =
              writeBody["settings"]
    else {
        Issue.record("settings-write must persist writable definitions")
        return
    }
    #expect(
        writtenSettings["followUpQueueMode"]
            == .string("queue")
    )
    #expect(
        writtenSettings["preventSleepWhileRunning"]
            == .bool(true)
    )

    let rejected = CodexDesktopInitialFetchRouter.response(
        to: desktopInitialFetch(
            "settings-write",
            requestID: "settings-rejected",
            body:
                #"{"settings":{"git-commit-instructions":"override"}}"#
        ),
        state: state,
        configStore: config,
        settingsFilePath: settingsPath
    )
    #expect(
        rejected == .fetchFailure(
            requestID: "settings-rejected",
            status: 432,
            error:
                "Setting cannot be written by Codex: git-commit-instructions",
            errorCode: "settings_validation_failed"
        )
    )

    let persistedData = try Data(
        contentsOf: URL(fileURLWithPath: settingsPath)
    )
    let persisted = try JSONDecoder().decode(
        CodexJSONValue.self,
        from: persistedData
    )
    guard case let .object(persistedSettings) = persisted else {
        Issue.record("settings.json must contain a JSON object")
        return
    }
    #expect(
        persistedSettings["followUpQueueMode"]
            == .string("queue")
    )
    #expect(
        persistedSettings["preventSleepWhileRunning"]
            == .bool(true)
    )
}

@Test
func desktopInitialFetchRouterOwnsReleasedWorkspaceFileOperations()
    throws
{
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(
            "CodexDesktopInitialFetchFileTests-\(UUID().uuidString)",
            isDirectory: true
        )
    let codexHome = root.appendingPathComponent(
        "Codex",
        isDirectory: true
    )
    let workspace = root.appendingPathComponent(
        "Workspace",
        isDirectory: true
    )
    let subdirectory = workspace.appendingPathComponent(
        "Sources",
        isDirectory: true
    )
    try FileManager.default.createDirectory(
        at: codexHome,
        withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
        at: subdirectory,
        withIntermediateDirectories: true
    )
    let readme = workspace.appendingPathComponent("README.md")
    let hidden = workspace.appendingPathComponent(".secret")
    let binary = workspace.appendingPathComponent("pixel.png")
    try "Codex for ipad\n".write(
        to: readme,
        atomically: true,
        encoding: .utf8
    )
    try "hidden".write(
        to: hidden,
        atomically: true,
        encoding: .utf8
    )
    try Data([0x89, 0x50, 0x4E, 0x47]).write(to: binary)
    defer { try? FileManager.default.removeItem(at: root) }

    let state = desktopFileHostState(
        codexHome: codexHome,
        workspaceRoot: workspace
    )
    let list = CodexDesktopInitialFetchRouter.response(
        to: desktopInitialFetch(
            "workspace-directory-entries",
            requestID: "workspace-list",
            body:
                #"{"workspaceRoot":"\#(workspace.path)","directoryPath":"","directoriesOnly":false,"includeHidden":false}"#
        ),
        state: state
    )
    guard case let .fetchSuccess(
        _,
        200,
        _,
        .object(listBody)
    ) = list,
          case let .array(entries)? = listBody["entries"]
    else {
        Issue.record("workspace listing must return entries")
        return
    }
    #expect(entries.count == 3)
    #expect(
        entries.first == .object([
            "isSymlink": .bool(false),
            "name": .string("Sources"),
            "path": .string("Sources"),
            "type": .string("directory"),
        ])
    )
    #expect(
        !entries.contains {
            guard case let .object(entry) = $0 else {
                return false
            }
            return entry["name"] == .string(".secret")
        }
    )

    let read = CodexDesktopInitialFetchRouter.response(
        to: desktopInitialFetch(
            "read-file",
            requestID: "read-file",
            body: #"{"path":"\#(readme.path)"}"#
        ),
        state: state
    )
    #expect(
        read == .fetchSuccess(
            requestID: "read-file",
            status: 200,
            headers: ["content-type": "application/json"],
            body: .object([
                "contents": .string("Codex for ipad\n")
            ])
        )
    )

    let metadata = CodexDesktopInitialFetchRouter.response(
        to: desktopInitialFetch(
            "read-file-metadata",
            requestID: "metadata",
            body:
                #"{"path":"\#(readme.path)","contentSampleByteLimit":64,"contentSampleMaxFileBytes":1024}"#
        ),
        state: state
    )
    guard case let .fetchSuccess(
        _,
        200,
        _,
        .object(metadataBody)
    ) = metadata
    else {
        Issue.record("read-file-metadata must return metadata")
        return
    }
    #expect(metadataBody["isFile"] == .bool(true))
    #expect(metadataBody["sizeBytes"] == .integer(15))
    #expect(metadataBody["contentKind"] == .string("text"))

    let conflict = CodexDesktopInitialFetchRouter.response(
        to: desktopInitialFetch(
            "write-file",
            requestID: "write-conflict",
            body:
                #"{"path":"\#(readme.path)","content":"replacement","expectedMtimeMs":0}"#
        ),
        state: state
    )
    guard case let .fetchSuccess(
        _,
        200,
        _,
        .object(conflictBody)
    ) = conflict
    else {
        Issue.record("write-file conflict must be data, not an error")
        return
    }
    #expect(conflictBody["outcome"] == .string("conflict"))
    guard case let .number(actualMtime)? =
        conflictBody["mtimeMs"]
    else {
        Issue.record("existing file conflict must include mtimeMs")
        return
    }

    let save = CodexDesktopInitialFetchRouter.response(
        to: desktopInitialFetch(
            "write-file",
            requestID: "write-save",
            body:
                #"{"path":"\#(readme.path)","content":"replacement","expectedMtimeMs":\#(actualMtime)}"#
        ),
        state: state
    )
    guard case let .fetchSuccess(
        _,
        200,
        _,
        .object(saveBody)
    ) = save
    else {
        Issue.record("write-file must save when mtime matches")
        return
    }
    #expect(saveBody["outcome"] == .string("saved"))
    #expect(
        try String(contentsOf: readme, encoding: .utf8)
            == "replacement"
    )

    let newFile = workspace.appendingPathComponent("notes.txt")
    let createFile = CodexDesktopInitialFetchRouter.response(
        to: desktopInitialFetch(
            "write-file",
            requestID: "write-new",
            body:
                #"{"path":"\#(newFile.path)","content":"new","expectedMtimeMs":null}"#
        ),
        state: state
    )
    guard case let .fetchSuccess(
        _,
        200,
        _,
        .object(createBody)
    ) = createFile
    else {
        Issue.record("write-file must create a new file")
        return
    }
    #expect(createBody["outcome"] == .string("saved"))

    let ensured = workspace.appendingPathComponent(
        "Generated/Nested",
        isDirectory: true
    )
    let ensure = CodexDesktopInitialFetchRouter.response(
        to: desktopInitialFetch(
            "ensure-directory",
            requestID: "ensure-directory",
            body: #"{"path":"\#(ensured.path)"}"#
        ),
        state: state
    )
    #expect(
        ensure == .fetchSuccess(
            requestID: "ensure-directory",
            status: 200,
            headers: ["content-type": "application/json"],
            body: .object([:])
        )
    )
    #expect(
        FileManager.default.fileExists(atPath: ensured.path)
    )

    let tooLarge = CodexDesktopInitialFetchRouter.response(
        to: desktopInitialFetch(
            "read-file-binary",
            requestID: "binary-too-large",
            body: #"{"path":"\#(binary.path)","maxBytes":2}"#
        ),
        state: state
    )
    #expect(
        tooLarge == .fetchSuccess(
            requestID: "binary-too-large",
            status: 200,
            headers: ["content-type": "application/json"],
            body: .object(["contentsBase64": .null])
        )
    )

    let binaryRead = CodexDesktopInitialFetchRouter.response(
        to: desktopInitialFetch(
            "read-file-binary",
            requestID: "binary-read",
            body: #"{"path":"\#(binary.path)","maxBytes":64}"#
        ),
        state: state
    )
    #expect(
        binaryRead == .fetchSuccess(
            requestID: "binary-read",
            status: 200,
            headers: ["content-type": "application/json"],
            body: .object([
                "contentsBase64": .string(
                    Data([0x89, 0x50, 0x4E, 0x47])
                        .base64EncodedString()
                ),
                "mimeType": .string("image/png"),
            ])
        )
    )

    let outside = root.appendingPathComponent("outside.txt")
    try "outside".write(
        to: outside,
        atomically: true,
        encoding: .utf8
    )
    let blocked = CodexDesktopInitialFetchRouter.response(
        to: desktopInitialFetch(
            "read-file",
            requestID: "read-outside",
            body: #"{"path":"\#(outside.path)"}"#
        ),
        state: state
    )
    guard case let .fetchFailure(
        "read-outside",
        432,
        _,
        "file_read_failed"
    ) = blocked
    else {
        Issue.record("filesystem routes must reject paths outside host roots")
        return
    }
}

@Test
func desktopInitialFetchRouterCreatesProjectlessWorkspacesAndFindsFiles()
    throws
{
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(
            "CodexDesktopInitialFetchProjectlessTests-\(UUID().uuidString)",
            isDirectory: true
        )
    let codexHome = root.appendingPathComponent(
        "Codex",
        isDirectory: true
    )
    let workspace = root.appendingPathComponent(
        "Workspace",
        isDirectory: true
    )
    let projectless = root.appendingPathComponent(
        "Documents/Codex",
        isDirectory: true
    )
    try FileManager.default.createDirectory(
        at: codexHome,
        withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
        at: workspace,
        withIntermediateDirectories: true
    )
    let searchable = workspace.appendingPathComponent(
        "ReleaseNotes.swift"
    )
    try "let release = true\n".write(
        to: searchable,
        atomically: true,
        encoding: .utf8
    )
    defer { try? FileManager.default.removeItem(at: root) }

    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let now = try #require(
        calendar.date(
            from: DateComponents(
                timeZone: calendar.timeZone,
                year: 2026,
                month: 8,
                day: 2,
                hour: 12
            )
        )
    )
    let state = desktopFileHostState(
        codexHome: codexHome,
        workspaceRoot: workspace
    )
    let created = CodexDesktopInitialFetchRouter.response(
        to: desktopInitialFetch(
            "projectless-thread-cwd",
            requestID: "projectless-create",
            body:
                #"{"createSplitDirectories":true,"prompt":"Build Codex for ipad now please"}"#
        ),
        state: state,
        projectlessWorkspaceRootPath: projectless.path,
        now: now
    )
    guard case let .fetchSuccess(
        _,
        200,
        _,
        .object(createdBody)
    ) = created,
          case let .string(cwd)? = createdBody["cwd"],
          case let .string(outputDirectory)? =
              createdBody["outputDirectory"]
    else {
        Issue.record("projectless-thread-cwd must create the released paths")
        return
    }
    #expect(
        cwd.hasSuffix(
            "/2026-08-02/build-codex-for-ipad-now-please"
        )
    )
    #expect(outputDirectory == cwd + "/outputs")
    #expect(
        FileManager.default.fileExists(
            atPath: cwd + "/work"
        )
    )
    #expect(
        FileManager.default.fileExists(
            atPath: cwd + "/outputs"
        )
    )

    let rootResponse = CodexDesktopInitialFetchRouter.response(
        to: desktopInitialFetch(
            "projectless-workspace-root",
            requestID: "projectless-root"
        ),
        state: state,
        projectlessWorkspaceRootPath: projectless.path
    )
    #expect(
        rootResponse == .fetchSuccess(
            requestID: "projectless-root",
            status: 200,
            headers: ["content-type": "application/json"],
            body: .object([
                "workspaceRoot": .string(projectless.path)
            ])
        )
    )

    let home = CodexDesktopInitialFetchRouter.response(
        to: desktopInitialFetch(
            "home-directory",
            requestID: "home-directory",
            body: #"{"hostId":"local"}"#
        ),
        state: state
    )
    #expect(
        home == .fetchSuccess(
            requestID: "home-directory",
            status: 200,
            headers: ["content-type": "application/json"],
            body: .object([
                "homeDirectory": .string(
                    FileManager.default
                        .homeDirectoryForCurrentUser.path
                )
            ])
        )
    )

    let found = CodexDesktopInitialFetchRouter.response(
        to: desktopInitialFetch(
            "find-files",
            requestID: "find-files",
            body:
                #"{"query":"reln","cwd":"\#(workspace.path)"}"#
        ),
        state: state
    )
    guard case let .fetchSuccess(
        _,
        200,
        _,
        .object(foundBody)
    ) = found,
          case let .array(files)? = foundBody["files"],
          case let .object(match)? = files.first
    else {
        Issue.record("find-files must return fuzzy results")
        return
    }
    #expect(match["root"] == .string(workspace.path))
    #expect(match["path"] == .string("ReleaseNotes.swift"))
    guard case let .string(fsPath)? = match["fsPath"] else {
        Issue.record("find-files must return an absolute filesystem path")
        return
    }
    #expect(fsPath.hasSuffix("/Workspace/ReleaseNotes.swift"))
    #expect(
        FileManager.default.contentsEqual(
            atPath: fsPath,
            andPath: searchable.path
        )
    )
    #expect(match["match_type"] == .string("file"))
    #expect(match["file_name"] == .string("ReleaseNotes.swift"))
    guard case let .integer(score)? = match["score"],
          case let .array(indices)? = match["indices"]
    else {
        Issue.record("find-files must return score and indices")
        return
    }
    #expect(score > 0)
    #expect(indices.count == 4)
}

@Test
func desktopInitialFetchRouterArchivesAndDeletesAutomationRuns()
    throws
{
    let codexHome = FileManager.default.temporaryDirectory
        .appendingPathComponent(
            "CodexDesktopAutomationFetchTests-\(UUID().uuidString)",
            isDirectory: true
        )
    defer { try? FileManager.default.removeItem(at: codexHome) }
    let store = try CodexDesktopAutomationStore(
        codexHome: codexHome
    )
    let item = try store.create(
        params: [
            "kind": .string("cron"),
            "name": .string("Archive route"),
            "prompt": .string("Review the current workspace."),
            "executionEnvironment": .string("local"),
            "rrule": .string(
                "FREQ=DAILY;BYHOUR=9;BYMINUTE=0"
            ),
        ],
        defaultCWDs: ["/private/Workspace/CodexPad"]
    )
    guard case let .object(fields) = item,
          case let .string(automationID)? = fields["id"]
    else {
        Issue.record("automation create must return an id")
        return
    }
    try store.recordRun(
        automationID: automationID,
        execution: CodexDesktopAutomationExecution(
            threadID: "thread-run-route",
            status: "PENDING_REVIEW"
        )
    )

    let archived = CodexDesktopInitialFetchRouter.response(
        to: desktopInitialFetch(
            "automation-run-archive",
            requestID: "archive-run",
            body:
                #"{"threadId":"thread-run-route","archivedAssistantMessage":"Finished","archivedUserMessage":"Review","archivedReason":"dismissed"}"#
        ),
        state: desktopInitialHostState,
        automationStore: store
    )
    #expect(
        archived == .fetchSuccess(
            requestID: "archive-run",
            status: 200,
            headers: ["content-type": "application/json"],
            body: .object(["success": .bool(true)])
        )
    )
    guard case let .object(archivedRun)? =
        store.snapshot().inboxItems.first
    else {
        Issue.record("archive route must retain the inbox run")
        return
    }
    #expect(archivedRun["status"] == .string("ARCHIVED"))
    #expect(
        archivedRun["archivedAssistantMessage"]
            == .string("Finished")
    )

    let deleted = CodexDesktopInitialFetchRouter.response(
        to: desktopInitialFetch(
            "automation-run-delete",
            requestID: "delete-run",
            body: #"{"threadId":"thread-run-route"}"#
        ),
        state: desktopInitialHostState,
        automationStore: store
    )
    #expect(
        deleted == .fetchSuccess(
            requestID: "delete-run",
            status: 200,
            headers: ["content-type": "application/json"],
            body: .object(["success": .bool(true)])
        )
    )
    #expect(store.snapshot().inboxItems.isEmpty)
}

@Test
func desktopInitialFetchRouterListsInstallsAndRemovesRecommendedSkills()
    throws
{
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(
            "RecommendedSkillFetchRoutes-\(UUID().uuidString)",
            isDirectory: true
        )
    defer { try? FileManager.default.removeItem(at: root) }
    let bundled = root.appendingPathComponent(
        "bundle",
        isDirectory: true
    )
    let source = bundled.appendingPathComponent(
        "skills/.curated/review",
        isDirectory: true
    )
    try FileManager.default.createDirectory(
        at: source,
        withIntermediateDirectories: true
    )
    try Data(
        """
        ---
        name: review
        description: Review the current workspace
        ---
        """.utf8
    ).write(to: source.appendingPathComponent("SKILL.md"))
    let installRoot = root.appendingPathComponent(
        "CodexHome/skills",
        isDirectory: true
    )
    let service = CodexRecommendedSkillService(
        bundledRepoRoot: bundled,
        defaultInstallRoot: installRoot,
        now: {
            Date(timeIntervalSince1970: 1_725_000_000)
        }
    )

    let list = CodexDesktopInitialFetchRouter.response(
        to: desktopInitialFetch(
            "recommended-skills",
            requestID: "recommended-list",
            body: #"{"hostId":"local","refresh":false}"#
        ),
        state: desktopInitialHostState,
        recommendedSkillService: service
    )
    #expect(
        list == .fetchSuccess(
            requestID: "recommended-list",
            status: 200,
            headers: ["content-type": "application/json"],
            body: .object([
                "skills": .array([
                    .object([
                        "id": .string("review"),
                        "name": .string("review"),
                        "description": .string(
                            "Review the current workspace"
                        ),
                        "shortDescription": .null,
                        "iconSmall": .null,
                        "iconLarge": .null,
                        "repoPath": .string(
                            "skills/.curated/review"
                        ),
                    ])
                ]),
                "fetchedAt": .integer(1_725_000_000_000),
                "source": .string("bundled"),
                "repoRoot": .string(bundled.path),
                "error": .null,
            ])
        )
    )

    let install = CodexDesktopInitialFetchRouter.response(
        to: desktopInitialFetch(
            "install-recommended-skill",
            requestID: "recommended-install",
            body:
                #"{"hostId":"local","skillId":"review","repoPath":"skills/.curated/review","installRoot":null,"skillStatsigOverride":null,"forceReinstall":false,"source":null}"#
        ),
        state: desktopInitialHostState,
        recommendedSkillService: service
    )
    let destination = installRoot.appendingPathComponent(
        "review",
        isDirectory: true
    )
    #expect(
        install == .fetchSuccess(
            requestID: "recommended-install",
            status: 200,
            headers: ["content-type": "application/json"],
            body: .object([
                "success": .bool(true),
                "destination": .string(destination.path),
                "error": .null,
            ])
        )
    )
    #expect(
        FileManager.default.fileExists(
            atPath: destination.appendingPathComponent(
                "SKILL.md"
            ).path
        )
    )

    let remove = CodexDesktopInitialFetchRouter.response(
        to: desktopInitialFetch(
            "remove-skill",
            requestID: "recommended-remove",
            body:
                #"{"hostId":"local","skillPath":"\#(destination.path)/SKILL.md"}"#
        ),
        state: desktopInitialHostState,
        recommendedSkillService: service
    )
    #expect(
        remove == .fetchSuccess(
            requestID: "recommended-remove",
            status: 200,
            headers: ["content-type": "application/json"],
            body: .object([
                "success": .bool(true),
                "deletedPath": .string(destination.path),
                "error": .null,
            ])
        )
    )
    #expect(
        !FileManager.default.fileExists(
            atPath: destination.path
        )
    )
}

@Test
func desktopInitialFetchRouterCreatesSavesAndReadsAgentsDocument()
    throws
{
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(
            "CodexAgentsDocumentRoutes-\(UUID().uuidString)",
            isDirectory: true
        )
    let codexHome = root.appendingPathComponent(
        "CodexHome",
        isDirectory: true
    )
    let workspace = root.appendingPathComponent(
        "Workspace",
        isDirectory: true
    )
    try FileManager.default.createDirectory(
        at: workspace,
        withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: root) }
    let state = desktopFileHostState(
        codexHome: codexHome,
        workspaceRoot: workspace
    )
    let agentsPath = codexHome.appendingPathComponent(
        "AGENTS.md"
    ).path

    let initial = CodexDesktopInitialFetchRouter.response(
        to: desktopInitialFetch(
            "codex-agents-md",
            requestID: "agents-read",
            body: #"{"hostId":"local"}"#
        ),
        state: state
    )
    #expect(
        initial == .fetchSuccess(
            requestID: "agents-read",
            status: 200,
            headers: ["content-type": "application/json"],
            body: .object([
                "path": .string(agentsPath),
                "contents": .string(""),
            ])
        )
    )
    #expect(FileManager.default.fileExists(atPath: agentsPath))

    let savedContents =
        "# Codex for ipad\n\nPreserve desktop parity.\n"
    let encoded = try JSONEncoder().encode([
        "hostId": "local",
        "contents": savedContents,
    ])
    let save = CodexDesktopInitialFetchRouter.response(
        to: desktopInitialFetch(
            "codex-agents-md-save",
            requestID: "agents-save",
            body: String(decoding: encoded, as: UTF8.self)
        ),
        state: state
    )
    #expect(
        save == .fetchSuccess(
            requestID: "agents-save",
            status: 200,
            headers: ["content-type": "application/json"],
            body: .object(["path": .string(agentsPath)])
        )
    )

    let reread = CodexDesktopInitialFetchRouter.response(
        to: desktopInitialFetch(
            "codex-agents-md",
            requestID: "agents-reread",
            body: #"{"hostId":"local"}"#
        ),
        state: state
    )
    #expect(
        reread == .fetchSuccess(
            requestID: "agents-reread",
            status: 200,
            headers: ["content-type": "application/json"],
            body: .object([
                "path": .string(agentsPath),
                "contents": .string(savedContents),
            ])
        )
    )
}

@Test
func desktopInitialFetchRouterDiscoversAndMergesLocalCustomAgents()
    throws
{
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(
            "CodexLocalCustomAgentsRoutes-\(UUID().uuidString)",
            isDirectory: true
        )
    let codexHome = root.appendingPathComponent(
        "CodexHome",
        isDirectory: true
    )
    let workspace = root.appendingPathComponent(
        "Workspace",
        isDirectory: true
    )
    let homeAgents = codexHome.appendingPathComponent(
        "agents",
        isDirectory: true
    )
    let workspaceCodex = workspace.appendingPathComponent(
        ".codex",
        isDirectory: true
    )
    let workspaceAgents = workspaceCodex.appendingPathComponent(
        "agents",
        isDirectory: true
    )
    for directory in [
        homeAgents,
        workspaceAgents,
    ] {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
    }
    defer { try? FileManager.default.removeItem(at: root) }

    try Data(
        """
        [agents.reviewer]
        description = "Global reviewer"
        config_file = "agents/reviewer.toml"
        nickname_candidates = ["Review", "Audit"]
        """.utf8
    ).write(to: codexHome.appendingPathComponent("config.toml"))
    try Data(
        """
        description = "File reviewer"
        """.utf8
    ).write(to: homeAgents.appendingPathComponent("reviewer.toml"))
    try Data(
        """
        [agents.reviewer]
        description = "Workspace reviewer"
        """.utf8
    ).write(to: workspaceCodex.appendingPathComponent("config.toml"))
    try Data(
        """
        name = "builder"
        description = "Build the iPad app"
        nickname_candidates = [
          "Build",
          "Compile"
        ]
        """.utf8
    ).write(to: workspaceAgents.appendingPathComponent("builder.toml"))

    let state = desktopFileHostState(
        codexHome: codexHome,
        workspaceRoot: workspace
    )
    let body = try JSONEncoder().encode([
        "roots": [workspace.path]
    ])
    let response = CodexDesktopInitialFetchRouter.response(
        to: desktopInitialFetch(
            "local-custom-agents",
            requestID: "custom-agents",
            body: String(decoding: body, as: UTF8.self)
        ),
        state: state
    )
    #expect(
        response == .fetchSuccess(
            requestID: "custom-agents",
            status: 200,
            headers: ["content-type": "application/json"],
            body: .object([
                "agents": .array([
                    .object([
                        "roleName": .string("builder"),
                        "description": .string(
                            "Build the iPad app"
                        ),
                        "configFile": .string(
                            workspaceAgents
                                .appendingPathComponent(
                                    "builder.toml"
                                ).path
                        ),
                        "nicknameCandidates": .array([
                            .string("Build"),
                            .string("Compile"),
                        ]),
                    ]),
                    .object([
                        "roleName": .string("reviewer"),
                        "description": .string(
                            "Workspace reviewer"
                        ),
                        "configFile": .string(
                            homeAgents
                                .appendingPathComponent(
                                    "reviewer.toml"
                                ).path
                        ),
                        "nicknameCandidates": .array([
                            .string("Review"),
                            .string("Audit"),
                        ]),
                    ]),
                ])
            ])
        )
    )
}

@Test
func desktopInitialFetchRouterReturnsMCPConfigAndDeveloperAppContext()
    throws
{
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(
            "CodexDeveloperInstructionsRoutes-\(UUID().uuidString)",
            isDirectory: true
        )
    let codexHome = root.appendingPathComponent(
        "CodexHome",
        isDirectory: true
    )
    let workspace = root.appendingPathComponent(
        "Workspace",
        isDirectory: true
    )
    try FileManager.default.createDirectory(
        at: workspace.appendingPathComponent(".git"),
        withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: root) }
    let state = desktopFileHostState(
        codexHome: codexHome,
        workspaceRoot: workspace
    )
    let cwdBody = try JSONEncoder().encode([
        "cwd": workspace.path
    ])
    let mcp = CodexDesktopInitialFetchRouter.response(
        to: desktopInitialFetch(
            "mcp-codex-config",
            requestID: "mcp-config",
            body: String(decoding: cwdBody, as: UTF8.self)
        ),
        state: state
    )
    #expect(
        mcp == .fetchSuccess(
            requestID: "mcp-config",
            status: 200,
            headers: ["content-type": "application/json"],
            body: .object([
                "config": .object([
                    "appearanceTheme": .string("dark")
                ])
            ])
        )
    )

    let developerBody = try JSONSerialization.data(
        withJSONObject: [
            "baseInstructions": "Base instructions.",
            "cwd": workspace.path,
            "hostId": "local",
            "threadToolsEnabled": true,
            "includeProseDetailLevelInstructions": true,
        ]
    )
    let developer = CodexDesktopInitialFetchRouter.response(
        to: desktopInitialFetch(
            "developer-instructions",
            requestID: "developer-instructions",
            body: String(
                decoding: developerBody,
                as: UTF8.self
            )
        ),
        state: state
    )
    guard case let .fetchSuccess(
        _,
        200,
        _,
        .object(fields)
    ) = developer,
          case let .string(instructions)? =
              fields["instructions"]
    else {
        Issue.record(
            "developer-instructions must return an instructions string"
        )
        return
    }
    #expect(instructions.hasPrefix("Base instructions.\n\n"))
    #expect(instructions.contains("<app-context>"))
    #expect(instructions.contains("# Codex desktop context"))
    #expect(instructions.contains("### Workspace Dependencies"))
    #expect(instructions.contains("### Git"))
    #expect(instructions.contains("### Automations"))
    #expect(instructions.contains("### Thread Coordination"))
    #expect(instructions.contains("### Non-technical UI"))
    #expect(instructions.contains("### Inline Code Comments"))
    #expect(instructions.hasSuffix("</app-context>"))
}

@Test
func desktopDeveloperInstructionsRecognizeGitWorkspaceAfterIOSContainerReplacement()
    throws
{
    let fileManager = FileManager.default
    let documents = try #require(
        fileManager.urls(for: .documentDirectory, in: .userDomainMask).first
    )
    let workspace = documents.appendingPathComponent(
        "codexpad-stale-container-\(UUID().uuidString)",
        isDirectory: true
    )
    try fileManager.createDirectory(
        at: workspace.appendingPathComponent(".git", isDirectory: true),
        withIntermediateDirectories: true
    )
    defer { try? fileManager.removeItem(at: workspace) }

    let staleCWD =
        "/var/mobile/Containers/Data/Application/"
        + "11111111-2222-3333-4444-555555555555/Documents/"
        + workspace.lastPathComponent
    let body = try JSONSerialization.data(
        withJSONObject: [
            "cwd": staleCWD,
            "hostId": "local",
            "threadToolsEnabled": false,
            "includeProseDetailLevelInstructions": false,
        ]
    )
    let response = CodexDesktopInitialFetchRouter.response(
        to: desktopInitialFetch(
            "developer-instructions",
            requestID: "stale-container-developer-instructions",
            body: String(decoding: body, as: UTF8.self)
        ),
        state: desktopFileHostState(
            codexHome: documents,
            workspaceRoot: workspace
        ),
        fileManager: fileManager
    )

    guard case let .fetchSuccess(_, 200, _, .object(fields)) = response,
          case let .string(instructions)? = fields["instructions"]
    else {
        Issue.record("Expected developer instructions response")
        return
    }
    #expect(instructions.contains("### Git"))
}
