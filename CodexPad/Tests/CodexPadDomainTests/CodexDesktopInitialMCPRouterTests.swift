import Foundation
import Testing

@testable import CodexPadApplication
@testable import CodexPadDomain
@testable import CodexPadProtocolBridge

@Test
func desktopInitialMCPRouterReturnsRemoteControlStatusWithIntegerID() {
    let response = CodexDesktopInitialMCPRouter.response(
        to: initialMCPRequest(
            id: .integer(41),
            method: "remoteControl/status/read",
            params: nil
        ),
        state: initialMCPState()
    )

    #expect(
        response
            == .mcpResponse(
                hostID: "desktop-host-1",
                message: .object([
                    "id": .integer(41),
                    "result": .object([
                        "status": .string("connected"),
                        "serverName": .string("Codex-for-iPad"),
                        "installationId": .string("installation-1"),
                        "environmentId": .string("environment-1"),
                    ]),
                ]),
                metadata: [:]
            )
    )
}

@Test
func desktopInitialMCPRouterOmitsConfigLayersUnlessRequested() {
    let response = CodexDesktopInitialMCPRouter.response(
        to: initialMCPRequest(
            id: .string("config-string-id"),
            method: "config/read",
            params: .object([
                "includeLayers": .bool(false),
                "cwd": .null,
            ]),
            requestMetadata: [
                "trace": .object(["traceId": .string("trace-1")])
            ],
            envelopeMetadata: [
                "unrelated": .string("must-not-be-echoed")
            ]
        ),
        state: initialMCPState()
    )

    #expect(
        response
            == .mcpResponse(
                hostID: "desktop-host-1",
                message: .object([
                    "id": .string("config-string-id"),
                    "result": .object([
                        "config": .object([
                            "model": .string("model-1")
                        ]),
                        "origins": .object([
                            "model": .string("user")
                        ]),
                    ]),
                ]),
                metadata: [:]
            )
    )
}

@Test
func desktopInitialMCPRouterIncludesConfigLayersWhenRequested() {
    let response = CodexDesktopInitialMCPRouter.response(
        to: initialMCPRequest(
            id: .integer(7),
            method: "config/read",
            params: .object([
                "includeLayers": .bool(true),
                "cwd": .string("/workspace"),
            ])
        ),
        state: initialMCPState()
    )

    #expect(
        response
            == .mcpResponse(
                hostID: "desktop-host-1",
                message: .object([
                    "id": .integer(7),
                    "result": .object([
                        "config": .object([
                            "model": .string("model-1")
                        ]),
                        "origins": .object([
                            "model": .string("user")
                        ]),
                        "layers": .array([
                            .object([
                                "name": .string("user"),
                                "version": .integer(1),
                            ])
                        ]),
                    ]),
                ]),
                metadata: [:]
            )
    )
}

@Test
func desktopInitialMCPRouterReturnsNoManagedConfigRequirements() {
    for params in [
        nil,
        CodexJSONValue.null,
        .object([:]),
    ] {
        let response = CodexDesktopInitialMCPRouter.response(
            to: initialMCPRequest(
                id: .string("requirements"),
                method: "configRequirements/read",
                params: params
            ),
            state: initialMCPState()
        )

        #expect(
            response
                == .mcpResponse(
                    hostID: "desktop-host-1",
                    message: .object([
                        "id": .string("requirements"),
                        "result": .object([
                            "requirements": .null
                        ]),
                    ]),
                    metadata: [:]
                )
        )
    }
}

@Test
func desktopInitialMCPRouterReturnsOfficialProviderCapabilities() {
    let defaultResponse = CodexDesktopInitialMCPRouter.response(
        to: initialMCPRequest(
            id: .integer(71),
            method: "modelProvider/capabilities/read",
            params: .object([:])
        ),
        state: initialMCPState()
    )
    let bedrockResponse = CodexDesktopInitialMCPRouter.response(
        to: initialMCPRequest(
            id: .integer(72),
            method: "modelProvider/capabilities/read",
            params: .object([:])
        ),
        state: initialMCPState(
            config: [
                "model_provider": .string("amazon-bedrock")
            ]
        )
    )

    #expect(
        defaultResponse
            == .mcpResponse(
                hostID: "desktop-host-1",
                message: .object([
                    "id": .integer(71),
                    "result": .object([
                        "namespaceTools": .bool(true),
                        "imageGeneration": .bool(true),
                        "webSearch": .bool(true),
                    ]),
                ]),
                metadata: [:]
            )
    )
    #expect(
        bedrockResponse
            == .mcpResponse(
                hostID: "desktop-host-1",
                message: .object([
                    "id": .integer(72),
                    "result": .object([
                        "namespaceTools": .bool(true),
                        "imageGeneration": .bool(false),
                        "webSearch": .bool(false),
                    ]),
                ]),
                metadata: [:]
            )
    )
}

@Test
func desktopStartupCapabilityReadsRejectNonUnitParams() {
    for method in [
        "configRequirements/read",
        "modelProvider/capabilities/read",
    ] {
        let response = CodexDesktopInitialMCPRouter.response(
            to: initialMCPRequest(
                id: .string(method),
                method: method,
                params: .object(["unexpected": .bool(true)])
            ),
            state: initialMCPState()
        )

        #expect(
            response
                == initialMCPError(
                    id: .string(method),
                    code: -32602,
                    message: "Invalid params for \(method)"
                )
        )
    }
}

@Test
func desktopInitialMCPRouterReturnsSignedOutAccountAndAuthShapes() {
    let state = initialMCPState(
        account: nil,
        authMethod: nil,
        requiresOpenAIAuth: true
    )

    let accountResponse = CodexDesktopInitialMCPRouter.response(
        to: initialMCPRequest(
            id: .string("account-id"),
            method: "account/read",
            params: .object(["refreshToken": .bool(false)])
        ),
        state: state
    )
    let authResponse = CodexDesktopInitialMCPRouter.response(
        to: initialMCPRequest(
            id: .integer(9),
            method: "getAuthStatus",
            params: .object([
                "includeToken": .bool(false),
                "refreshToken": .bool(false),
            ])
        ),
        state: state
    )

    #expect(
        accountResponse
            == .mcpResponse(
                hostID: "desktop-host-1",
                message: .object([
                    "id": .string("account-id"),
                    "result": .object([
                        "account": .null,
                        "requiresOpenaiAuth": .bool(true),
                    ]),
                ]),
                metadata: [:]
            )
    )
    #expect(
        authResponse
            == .mcpResponse(
                hostID: "desktop-host-1",
                message: .object([
                    "id": .integer(9),
                    "result": .object([
                        "authMethod": .null,
                        "authToken": .null,
                        "requiresOpenaiAuth": .bool(true),
                    ]),
                ]),
                metadata: [:]
            )
    )
}

@Test
func desktopInitialMCPRouterReturnsAPIKeyAccountAndAuthShapes() {
    let state = initialMCPState(
        account: .apiKey,
        authMethod: .apiKey,
        requiresOpenAIAuth: true
    )

    let accountResponse = CodexDesktopInitialMCPRouter.response(
        to: initialMCPRequest(
            id: .string("api-key-account"),
            method: "account/read",
            params: .object(["refreshToken": .bool(false)])
        ),
        state: state
    )
    let authResponse = CodexDesktopInitialMCPRouter.response(
        to: initialMCPRequest(
            id: .string("api-key-auth"),
            method: "getAuthStatus",
            params: .object([
                "includeToken": .bool(false),
                "refreshToken": .bool(false),
            ])
        ),
        state: state
    )

    #expect(
        accountResponse
            == .mcpResponse(
                hostID: "desktop-host-1",
                message: .object([
                    "id": .string("api-key-account"),
                    "result": .object([
                        "account": .object([
                            "type": .string("apiKey")
                        ]),
                        "requiresOpenaiAuth": .bool(true),
                    ]),
                ]),
                metadata: [:]
            )
    )
    #expect(
        authResponse
            == .mcpResponse(
                hostID: "desktop-host-1",
                message: .object([
                    "id": .string("api-key-auth"),
                    "result": .object([
                        "authMethod": .string("apikey"),
                        "authToken": .null,
                        "requiresOpenaiAuth": .bool(true),
                    ]),
                ]),
                metadata: [:]
            )
    )
}

@Test
func desktopInitialMCPRouterReturnsMinimalSignedInAccountWithoutToken() {
    let state = initialMCPState(
        account: .chatGPT(
            email: "user@example.com",
            planType: .plus
        ),
        authMethod: .chatGPT,
        requiresOpenAIAuth: true
    )

    let accountResponse = CodexDesktopInitialMCPRouter.response(
        to: initialMCPRequest(
            id: .integer(10),
            method: "account/read",
            params: .object(["refreshToken": .bool(true)])
        ),
        state: state
    )
    let authResponse = CodexDesktopInitialMCPRouter.response(
        to: initialMCPRequest(
            id: .string("auth-id"),
            method: "getAuthStatus",
            params: .object([
                "includeToken": .bool(true),
                "refreshToken": .bool(true),
            ])
        ),
        state: state
    )

    #expect(
        accountResponse
            == .mcpResponse(
                hostID: "desktop-host-1",
                message: .object([
                    "id": .integer(10),
                    "result": .object([
                        "account": .object([
                            "type": .string("chatgpt"),
                            "email": .string("user@example.com"),
                            "planType": .string("plus"),
                        ]),
                        "requiresOpenaiAuth": .bool(true),
                    ]),
                ]),
                metadata: [:]
            )
    )
    #expect(
        authResponse
            == .mcpResponse(
                hostID: "desktop-host-1",
                message: .object([
                    "id": .string("auth-id"),
                    "result": .object([
                        "authMethod": .string("chatgpt"),
                        "authToken": .null,
                        "requiresOpenaiAuth": .bool(true),
                    ]),
                ]),
                metadata: [:]
            )
    )
}

@Test
func desktopInitialMCPRouterRejectsInvalidParamsWithSameID() {
    let invalidConfig = CodexDesktopInitialMCPRouter.response(
        to: initialMCPRequest(
            id: .string("invalid-config"),
            method: "config/read",
            params: nil
        ),
        state: initialMCPState()
    )
    let invalidAccount = CodexDesktopInitialMCPRouter.response(
        to: initialMCPRequest(
            id: .integer(12),
            method: "account/read",
            params: .object(["refreshToken": .null])
        ),
        state: initialMCPState()
    )

    #expect(
        invalidConfig
            == initialMCPError(
                id: .string("invalid-config"),
                code: -32602,
                message: "Invalid params for config/read"
            )
    )
    #expect(
        invalidAccount
            == initialMCPError(
                id: .integer(12),
                code: -32602,
                message: "Invalid params for account/read"
            )
    )
}

@Test
func desktopInitialMCPRouterReturnsMethodNotFoundWithSameStringID() {
    let response = CodexDesktopInitialMCPRouter.response(
        to: initialMCPRequest(
            id: .string("unknown-id"),
            method: "thread/unknown",
            params: .object([:])
        ),
        state: initialMCPState()
    )

    #expect(
        response
            == initialMCPError(
                id: .string("unknown-id"),
                code: -32601,
                message: "Method not found: thread/unknown"
            )
    )
}

@Test
func desktopInitialMCPRouterReadsAllowedFileAsReleasedBase64Shape()
    async throws
{
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(
            "codex-desktop-mcp-read-\(UUID().uuidString)",
            isDirectory: true
        )
    try FileManager.default.createDirectory(
        at: root,
        withIntermediateDirectories: true
    )
    defer {
        try? FileManager.default.removeItem(at: root)
    }
    let file = root.appendingPathComponent("registry.json")
    try Data("released-file".utf8).write(to: file)

    let response =
        await CodexDesktopInitialMCPRouter
            .responseIncludingFileSystem(
                to: initialMCPRequest(
                    id: .string("fs-read-success"),
                    method: "fs/readFile",
                    params: .object([
                        "path": .string(file.path)
                    ])
                ),
                state: initialMCPState(),
                allowedFileSystemRoots: [root.path]
            )

    #expect(
        response
            == .mcpResponse(
                hostID: "desktop-host-1",
                message: .object([
                    "id": .string("fs-read-success"),
                    "result": .object([
                        "dataBase64": .string(
                            Data("released-file".utf8)
                                .base64EncodedString()
                        )
                    ]),
                ]),
                metadata: [:]
            )
    )
}

@Test
func desktopInitialMCPRouterAcceptsReleasedUnknownReadFileParams()
    async throws
{
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(
            "codex-desktop-mcp-extra-param-\(UUID().uuidString)",
            isDirectory: true
        )
    try FileManager.default.createDirectory(
        at: root,
        withIntermediateDirectories: true
    )
    defer {
        try? FileManager.default.removeItem(at: root)
    }
    let file = root.appendingPathComponent("registry.json")
    try Data("released-extra-param".utf8).write(to: file)

    let response =
        await CodexDesktopInitialMCPRouter
            .responseIncludingFileSystem(
                to: initialMCPRequest(
                    id: .integer(52),
                    method: "fs/readFile",
                    params: .object([
                        "path": .string(file.path),
                        "futureField": .bool(true),
                    ])
                ),
                state: initialMCPState(),
                allowedFileSystemRoots: [root.path]
            )

    #expect(
        response
            == .mcpResponse(
                hostID: "desktop-host-1",
                message: .object([
                    "id": .integer(52),
                    "result": .object([
                        "dataBase64": .string(
                            Data("released-extra-param".utf8)
                                .base64EncodedString()
                        )
                    ]),
                ]),
                metadata: [:]
            )
    )
}

@Test
func desktopInitialMCPRouterReturnsReleasedMalformedReadFileError()
    async
{
    let response =
        await CodexDesktopInitialMCPRouter
            .responseIncludingFileSystem(
                to: initialMCPRequest(
                    id: .integer(53),
                    method: "fs/readFile",
                    params: .object([:])
                ),
                state: initialMCPState(),
                allowedFileSystemRoots: [
                    FileManager.default.temporaryDirectory.path
                ]
            )

    #expect(
        response
            == initialMCPError(
                id: .integer(53),
                code: -32600,
                message: "Invalid request: missing field `path`"
            )
    )
}

@Test
func desktopInitialMCPRouterReturnsReleasedMissingFileError()
    async throws
{
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(
            "codex-desktop-mcp-missing-\(UUID().uuidString)",
            isDirectory: true
        )
    try FileManager.default.createDirectory(
        at: root,
        withIntermediateDirectories: true
    )
    defer {
        try? FileManager.default.removeItem(at: root)
    }
    let missing = root.appendingPathComponent(
        "attachments/pasted-text-attachments.json"
    )

    let response =
        await CodexDesktopInitialMCPRouter
            .responseIncludingFileSystem(
                to: initialMCPRequest(
                    id: .integer(51),
                    method: "fs/readFile",
                    params: .object([
                        "path": .string(missing.path)
                    ])
                ),
                state: initialMCPState(),
                allowedFileSystemRoots: [root.path]
            )

    #expect(
        response
            == initialMCPError(
                id: .integer(51),
                code: -32603,
                message:
                    "No such file or directory (os error 2)"
            )
    )
}

@Test
func desktopInitialMCPRouterClassifiesReadFileDiagnosticsWithoutExposingRoots()
{
    let containerID = "785A6A82-1C85-4873-88BC-F90BAF1E5881"
    let sessionID = "51CF5239-3E76-4F17-B99E-30671BE75C76"
    let applicationRoot =
        "/private/var/mobile/Containers/Data/Application/\(containerID)"
        + "/Library/Application Support/CodexPad"
    let codexHome = applicationRoot + "/CodexHome"
    let workspaceRoot =
        "/private/var/mobile/Containers/Shared/AppGroup/\(containerID)"
        + "/Workspace"

    #expect(
        CodexDesktopInitialMCPRouter.fileReadDiagnosticSummary(
            path: codexHome + "/AGENTS.override.md",
            applicationRoot: applicationRoot,
            codexHome: codexHome,
            workspaceRoots: [workspaceRoot]
        ) == "scope=codex-home path=AGENTS.override.md"
    )
    #expect(
        CodexDesktopInitialMCPRouter.fileReadDiagnosticSummary(
            path: workspaceRoot + "/Sources/Chat/Composer.swift",
            applicationRoot: applicationRoot,
            codexHome: codexHome,
            workspaceRoots: [workspaceRoot]
        ) == "scope=workspace path=Sources/Chat/Composer.swift"
    )
    #expect(
        CodexDesktopInitialMCPRouter.fileReadDiagnosticSummary(
            path: codexHome + "/sessions/\(sessionID)/state.json",
            applicationRoot: applicationRoot,
            codexHome: codexHome,
            workspaceRoots: [workspaceRoot]
        ) == "scope=codex-home path=sessions/[uuid]/state.json"
    )
    #expect(
        CodexDesktopInitialMCPRouter.fileReadDiagnosticSummary(
            path: applicationRoot + "/codex-command-keymap.json",
            applicationRoot: applicationRoot,
            codexHome: codexHome,
            workspaceRoots: [workspaceRoot]
        ) == "scope=application-root path=codex-command-keymap.json"
    )
    #expect(
        CodexDesktopInitialMCPRouter.fileReadDiagnosticSummary(
            path:
                "/private/var/mobile/Containers/Data/Application/"
                + "\(containerID)/Documents/private/account.json",
            applicationRoot: applicationRoot,
            codexHome: codexHome,
            workspaceRoots: [workspaceRoot]
        ) == "scope=outside-roots"
    )
    #expect(
        CodexDesktopInitialMCPRouter.fileReadDiagnosticSummary(
            path: "AGENTS.md",
            applicationRoot: applicationRoot,
            codexHome: codexHome,
            workspaceRoots: [workspaceRoot]
        ) == "scope=invalid-path"
    )
}

@Test
@MainActor
func desktopInitialMCPRouterForwardsModelListWithWireOptionality() async {
    let lister = RecordingDesktopModelLister()
    let response =
        await CodexDesktopInitialMCPRouter
            .responseIncludingFileSystem(
                to: initialMCPRequest(
                    id: .string("models-1"),
                    method: "model/list",
                    params: .object([
                        "cursor": .null,
                        "limit": .integer(25),
                        "includeHidden": .bool(true),
                    ])
                ),
                state: initialMCPState(),
                allowedFileSystemRoots: [],
                modelLister: lister
            )

    #expect(
        lister.received
            == CodexModelListParams(
                cursor: .null,
                limit: .value(25),
                includeHidden: .value(true)
            )
    )
    #expect(
        response
            == .mcpResponse(
                hostID: "desktop-host-1",
                message: .object([
                    "id": .string("models-1"),
                    "result": .object([
                        "data": .array([]),
                    ]),
                ]),
                metadata: [:]
            )
    )
}

@Test
@MainActor
func desktopInitialMCPRouterForwardsReleasedTurnStart() async {
    let starter = RecordingDesktopTurnStarter()
    let response =
        await CodexDesktopInitialMCPRouter
            .responseIncludingFileSystem(
                to: initialMCPRequest(
                    id: .integer(77),
                    method: "turn/start",
                    params: .object([
                        "threadId": .string("Thread/Raw"),
                        "input": .array([
                            .object([
                                "type": .string("text"),
                                "text": .string("Build it"),
                                "text_elements": .array([]),
                            ])
                        ]),
                        "model": .string("model-stable"),
                        "effort": .string("high"),
                        "additionalContext": .object([
                            "desktop": .object([
                                "kind": .string("application"),
                                "value": .string("context"),
                            ])
                        ]),
                        "environments": .array([
                            .object([
                                "environmentId": .string("local"),
                                "cwd": .string("/workspace"),
                            ])
                        ]),
                        "permissions": .string(":workspace"),
                        "responsesapiClientMetadata": .object([
                            "surface": .string("ipad")
                        ]),
                        "runtimeWorkspaceRoots": .array([
                            .string("/workspace")
                        ]),
                    ])
                ),
                state: initialMCPState(),
                allowedFileSystemRoots: [],
                turnStarter: starter
            )

    #expect(starter.receivedID == .integer(77))
    #expect(starter.receivedParams?.threadID.rawValue == "Thread/Raw")
    #expect(
        starter.receivedParams?.input
            == [.text(text: "Build it", textElements: [])]
    )
    #expect(starter.receivedParams?.model == .value("model-stable"))
    #expect(starter.receivedParams?.effort == .value("high"))
    #expect(
        starter.receivedParams?.additionalContext
            == .value([
                "desktop": .object([
                    "kind": .string("application"),
                    "value": .string("context"),
                ])
            ])
    )
    #expect(starter.receivedParams?.permissions == .value(":workspace"))
    #expect(
        starter.receivedParams?.environments
            == .value([
                .object([
                    "environmentId": .string("local"),
                    "cwd": .string("/workspace"),
                ])
            ])
    )
    #expect(
        starter.receivedParams?.responsesAPIClientMetadata
            == .value(["surface": "ipad"])
    )
    #expect(starter.receivedParams?.runtimeWorkspaceRoots == .value(["/workspace"]))

    guard case let .mcpResponse(hostID, message, metadata) = response,
          hostID == "desktop-host-1",
          metadata.isEmpty,
          case let .object(envelope) = message,
          envelope["id"] == .integer(77),
          case let .object(result)? = envelope["result"],
          case let .object(turn)? = result["turn"]
    else {
        Issue.record("Expected released turn/start response")
        return
    }
    #expect(turn["id"] == .string("turn-1"))
    #expect(turn["status"] == .string("inProgress"))
}

@Test
@MainActor
func desktopInitialMCPRouterForwardsReleasedThreadCompactStart() async {
    let starter = RecordingDesktopTurnStarter()
    let response =
        await CodexDesktopInitialMCPRouter
            .responseIncludingFileSystem(
                to: initialMCPRequest(
                    id: .string("compact-1"),
                    method: "thread/compact/start",
                    params: .object([
                        "threadId": .string("Thread/Raw")
                    ])
                ),
                state: initialMCPState(),
                allowedFileSystemRoots: [],
                turnStarter: starter
            )

    #expect(starter.compactID == .string("compact-1"))
    #expect(starter.compactThreadID?.rawValue == "Thread/Raw")
    #expect(
        response
            == .mcpResponse(
                hostID: "desktop-host-1",
                message: .object([
                    "id": .string("compact-1"),
                    "result": .object([:]),
                ]),
                metadata: [:]
            )
    )
}

@Test
@MainActor
func desktopInitialMCPRouterForwardsReleasedTurnInterrupt() async {
    let starter = RecordingDesktopTurnStarter()
    let response =
        await CodexDesktopInitialMCPRouter
            .responseIncludingFileSystem(
                to: initialMCPRequest(
                    id: .string("interrupt-1"),
                    method: "turn/interrupt",
                    params: .object([
                        "threadId": .string("Thread/Raw"),
                        "turnId": .string("turn-1"),
                    ])
                ),
                state: initialMCPState(),
                allowedFileSystemRoots: [],
                turnStarter: starter
            )

    #expect(starter.interruptedThreadID?.rawValue == "Thread/Raw")
    #expect(starter.interruptedTurnID == "turn-1")
    #expect(
        response
            == .mcpResponse(
                hostID: "desktop-host-1",
                message: .object([
                    "id": .string("interrupt-1"),
                    "result": .object([:]),
                ]),
                metadata: [:]
            )
    )
}

@Test
@MainActor
func desktopInitialMCPRouterRejectsMalformedTurnInterrupt() async {
    let starter = RecordingDesktopTurnStarter()
    let response =
        await CodexDesktopInitialMCPRouter
            .responseIncludingFileSystem(
                to: initialMCPRequest(
                    id: .integer(78),
                    method: "turn/interrupt",
                    params: .object([
                        "threadId": .string("Thread/Raw"),
                    ])
                ),
                state: initialMCPState(),
                allowedFileSystemRoots: [],
                turnStarter: starter
            )

    #expect(
        response
            == initialMCPError(
                id: .integer(78),
                code: -32602,
                message: "Invalid params for turn/interrupt"
            )
    )
}

@Test
@MainActor
func desktopInitialMCPRouterCoversTurnSteerParamsAndTurnSteerResponse() async {
    let starter = RecordingDesktopTurnStarter()
    let response = await CodexDesktopInitialMCPRouter
        .responseIncludingFileSystem(
            to: initialMCPRequest(
                id: .string("steer-1"),
                method: "turn/steer",
                params: .object([
                    "threadId": .string("Thread/Raw"),
                    "clientUserMessageId": .string("client-message-1"),
                    "input": .array([
                        .object([
                            "type": .string("text"),
                            "text": .string("Use the corrected approach"),
                            "text_elements": .array([]),
                        ])
                    ]),
                    "expectedTurnId": .string("turn-1"),
                ])
            ),
            state: initialMCPState(),
            allowedFileSystemRoots: [],
            turnStarter: starter
        )

    #expect(starter.steeredParams?.threadID.rawValue == "Thread/Raw")
    #expect(starter.steeredParams?.clientUserMessageID == .value("client-message-1"))
    #expect(starter.steeredParams?.expectedTurnID == "turn-1")
    #expect(
        starter.steeredParams?.input
            == [.text(text: "Use the corrected approach", textElements: [])]
    )
    #expect(
        response == .mcpResponse(
            hostID: "desktop-host-1",
            message: .object([
                "id": .string("steer-1"),
                "result": .object([
                    "turnId": .string("turn-2")
                ]),
            ]),
            metadata: [:]
        )
    )
}

@Test
@MainActor
func desktopInitialMCPRouterCoversConfigValueWriteParamsAndConfigWriteResponse() async {
    let store = RecordingDesktopConfigStore()
    let response = await CodexDesktopInitialMCPRouter
        .responseIncludingFileSystem(
            to: initialMCPRequest(
                id: .string("config-write-1"),
                method: "config/value/write",
                params: .object([
                    "keyPath": .string("features.experimental"),
                    "value": .bool(true),
                    "mergeStrategy": .string("upsert"),
                ])
            ),
            state: initialMCPState(),
            allowedFileSystemRoots: [],
            configStore: store
        )

    #expect(store.valueWrites.count == 1)
    #expect(store.valueWrites.first?.keyPath == "features.experimental")
    #expect(store.valueWrites.first?.value == .bool(true))
    #expect(store.valueWrites.first?.mergeStrategy == "upsert")
    #expect(
        response == .mcpResponse(
            hostID: "desktop-host-1",
            message: .object([
                "id": .string("config-write-1"),
                "result": .object([:]),
            ]),
            metadata: [:]
        )
    )
}

@Test
@MainActor
func desktopInitialMCPRouterCoversConfigBatchWriteParamsAndConfigWriteResponse() async {
    let store = RecordingDesktopConfigStore()
    let response = await CodexDesktopInitialMCPRouter
        .responseIncludingFileSystem(
            to: initialMCPRequest(
                id: .string("config-batch-1"),
                method: "config/batchWrite",
                params: .object([
                    "edits": .array([
                        .object([
                            "keyPath": .string("model"),
                            "value": .string("gpt-5.6-sol"),
                            "mergeStrategy": .string("replace"),
                        ]),
                        .object([
                            "keyPath": .string("features.remote"),
                            "value": .bool(true),
                            "mergeStrategy": .string("upsert"),
                        ]),
                    ])
                ])
            ),
            state: initialMCPState(),
            allowedFileSystemRoots: [],
            configStore: store
        )

    #expect(store.batchWrites.count == 2)
    #expect(store.batchWrites[0].keyPath == "model")
    #expect(store.batchWrites[0].value == .string("gpt-5.6-sol"))
    #expect(store.batchWrites[0].mergeStrategy == "replace")
    #expect(store.batchWrites[1].keyPath == "features.remote")
    #expect(store.batchWrites[1].value == .bool(true))
    #expect(store.batchWrites[1].mergeStrategy == "upsert")
    #expect(
        response == .mcpResponse(
            hostID: "desktop-host-1",
            message: .object([
                "id": .string("config-batch-1"),
                "result": .object([:]),
            ]),
            metadata: [:]
        )
    )
}

@Test
@MainActor
func desktopInitialMCPRouterCoversFsWatchParamsFsWatchResponseFsUnwatchParamsAndFsUnwatchResponse() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("codex-fs-watch-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let watcher = RecordingDesktopFileWatcher()
    let watchResponse = await CodexDesktopInitialMCPRouter
        .responseIncludingFileSystem(
            to: initialMCPRequest(
                id: .string("watch-1"),
                method: "fs/watch",
                params: .object([
                    "watchId": .string("workspace-watch"),
                    "path": .string(root.path),
                ])
            ),
            state: initialMCPState(),
            allowedFileSystemRoots: [root.path],
            fileWatcher: watcher
        )

    #expect(watcher.watchedID == "workspace-watch")
    #expect(watcher.watchedPath == root.standardizedFileURL.path)
    #expect(watcher.hostID == "desktop-host-1")
    #expect(
        watchResponse == .mcpResponse(
            hostID: "desktop-host-1",
            message: .object([
                "id": .string("watch-1"),
                "result": .object([
                    "path": .string(root.standardizedFileURL.path)
                ]),
            ]),
            metadata: [:]
        )
    )

    let unwatchResponse = await CodexDesktopInitialMCPRouter
        .responseIncludingFileSystem(
            to: initialMCPRequest(
                id: .string("unwatch-1"),
                method: "fs/unwatch",
                params: .object([
                    "watchId": .string("workspace-watch")
                ])
            ),
            state: initialMCPState(),
            allowedFileSystemRoots: [root.path],
            fileWatcher: watcher
        )

    #expect(watcher.unwatchedID == "workspace-watch")
    #expect(
        unwatchResponse == .mcpResponse(
            hostID: "desktop-host-1",
            message: .object([
                "id": .string("unwatch-1"),
                "result": .object([:]),
            ]),
            metadata: [:]
        )
    )
}

@Test
func desktopInitialMCPRouterRejectsReadOutsideAllowedRoots()
    async throws
{
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(
            "codex-desktop-mcp-root-\(UUID().uuidString)",
            isDirectory: true
        )
    try FileManager.default.createDirectory(
        at: root,
        withIntermediateDirectories: true
    )
    defer {
        try? FileManager.default.removeItem(at: root)
    }

    let response =
        await CodexDesktopInitialMCPRouter
            .responseIncludingFileSystem(
                to: initialMCPRequest(
                    id: .string("fs-read-outside"),
                    method: "fs/readFile",
                    params: .object([
                        "path": .string(
                            root.deletingLastPathComponent()
                                .appendingPathComponent("outside.txt")
                                .path
                        )
                    ])
                ),
                state: initialMCPState(),
                allowedFileSystemRoots: [root.path]
            )

    #expect(
        response
            == initialMCPError(
                id: .string("fs-read-outside"),
                code: -32602,
                message: "Invalid params for fs/readFile"
            )
    )
}

private func initialMCPState(
    account: CodexDesktopMCPAccount? = nil,
    authMethod: CodexDesktopMCPAuthMethod? = nil,
    requiresOpenAIAuth: Bool = true,
    config: [String: CodexJSONValue] = [
        "model": .string("model-1")
    ]
) -> CodexDesktopInitialMCPState {
    CodexDesktopInitialMCPState(
        account: CodexDesktopMCPAccountState(
            account: account,
            authMethod: authMethod,
            requiresOpenAIAuth: requiresOpenAIAuth
        ),
        config: CodexDesktopMCPConfigState(
            config: config,
            origins: ["model": .string("user")],
            layers: [
                .object([
                    "name": .string("user"),
                    "version": .integer(1),
                ])
            ]
        ),
        remoteControl: CodexDesktopMCPRemoteControlState(
            status: .connected,
            serverName: "Codex-for-iPad",
            installationID: "installation-1",
            environmentID: "environment-1"
        )
    )
}

@MainActor
private final class RecordingDesktopModelLister:
    CodexDesktopModelSessionListing
{
    var received: CodexModelListParams?

    func listModels(
        id: CodexAppServerRequestID,
        params: CodexModelListParams
    ) throws -> CodexModelListResponse {
        received = params
        return CodexModelListResponse(data: [], nextCursor: nil)
    }
}

@MainActor
private final class RecordingDesktopTurnStarter:
    CodexDesktopTurnSessionStarting,
    CodexDesktopTurnSessionInterrupting,
    CodexDesktopTurnSessionSteering,
    CodexDesktopThreadCompacting
{
    var receivedID: CodexAppServerRequestID?
    var receivedParams: CodexTurnStartParams?
    var interruptedThreadID: CodexStoredThreadID?
    var interruptedTurnID: String?
    var compactID: CodexAppServerRequestID?
    var compactThreadID: CodexStoredThreadID?
    var steeredParams: CodexTurnSteerParams?

    func startDesktopTurn(
        id: CodexAppServerRequestID,
        params: CodexTurnStartParams
    ) throws -> CodexTurnStartResult {
        receivedID = id
        receivedParams = params
        return CodexTurnStartResult(
            turn: CodexStoredTurn(
                id: "turn-1",
                items: [],
                itemsView: .notLoaded,
                status: .inProgress
            )
        )
    }

    func interruptDesktopTurn(
        threadID: CodexStoredThreadID,
        turnID: String
    ) throws {
        interruptedThreadID = threadID
        interruptedTurnID = turnID
    }

    func steerDesktopTurn(
        params: CodexTurnSteerParams
    ) throws -> CodexTurnSteerResult {
        steeredParams = params
        return CodexTurnSteerResult(turnID: "turn-2")
    }

    func startDesktopCompaction(
        id: CodexAppServerRequestID,
        threadID: CodexStoredThreadID
    ) throws {
        compactID = id
        compactThreadID = threadID
    }
}

private final class RecordingDesktopConfigStore: CodexDesktopConfigMutating {
    typealias Write = (
        keyPath: String,
        value: CodexJSONValue,
        mergeStrategy: String
    )

    var configSnapshot: [String: CodexJSONValue] = [:]
    var valueWrites: [Write] = []
    var batchWrites: [Write] = []

    func writeConfigValue(
        keyPath: String,
        value: CodexJSONValue,
        mergeStrategy: String
    ) {
        valueWrites.append((keyPath, value, mergeStrategy))
    }

    func batchWriteConfig(
        edits: [Write]
    ) {
        batchWrites = edits
    }
}

@MainActor
private final class RecordingDesktopFileWatcher: CodexDesktopFileWatching {
    var watchedID: String?
    var watchedPath: String?
    var hostID: String?
    var unwatchedID: String?

    func watch(
        watchID: String,
        path: URL,
        hostID: String
    ) throws -> String {
        watchedID = watchID
        watchedPath = path.standardizedFileURL.path
        self.hostID = hostID
        return path.standardizedFileURL.path
    }

    func unwatch(watchID: String) {
        unwatchedID = watchID
    }
}

private func initialMCPRequest(
    id: CodexAppServerRequestID,
    method: String,
    params: CodexJSONValue?,
    requestMetadata: [String: CodexJSONValue] = [:],
    envelopeMetadata: [String: CodexJSONValue] = [:]
) -> CodexDesktopMCPRequest {
    CodexDesktopMCPRequest(
        request: CodexDesktopMCPRequestMessage(
            id: id,
            method: method,
            params: params,
            metadata: requestMetadata
        ),
        hostID: "desktop-host-1",
        dispatchedAtMs: .integer(100),
        priority: .string("startup"),
        source: .string("renderer"),
        timeoutMs: .integer(5_000),
        expiresAtMs: .integer(5_100),
        metadata: envelopeMetadata
    )
}

private func initialMCPError(
    id: CodexAppServerRequestID,
    code: Int64,
    message: String
) -> CodexDesktopHostMessage {
    let responseID: CodexJSONValue
    switch id {
    case let .string(value):
        responseID = .string(value)
    case let .integer(value):
        responseID = .integer(value)
    }

    return .mcpResponse(
        hostID: "desktop-host-1",
        message: .object([
            "id": responseID,
            "error": .object([
                "code": .integer(code),
                "message": .string(message),
            ]),
        ]),
        metadata: [:]
    )
}

@MainActor
private final class AccountRateLimitsRouterProbe:
    CodexDesktopAccountRateLimitsReading
{
    var nudgeCreditType: String?

    func readAccountRateLimits() async throws -> CodexJSONValue {
        .object(["source": .string("rate-limits")])
    }

    var usageThreadID: String?

    func readAccountUsage(threadID: String?) async throws -> CodexJSONValue {
        usageThreadID = threadID
        return .object([
            "source": .string("usage"),
            "threadId": threadID.map(CodexJSONValue.string) ?? .null,
        ])
    }

    func readWorkspaceMessages() async throws -> CodexJSONValue {
        .object(["source": .string("workspace-messages")])
    }

    func consumeRateLimitResetCredit(
        idempotencyKey: String,
        creditID: String?
    ) async throws -> CodexJSONValue {
        .object([
            "idempotencyKey": .string(idempotencyKey),
            "creditId": creditID.map(CodexJSONValue.string) ?? .null,
        ])
    }

    func sendAddCreditsNudgeEmail(
        creditType: String
    ) async throws -> CodexJSONValue {
        nudgeCreditType = creditType
        return .object(["status": .string("cooldown_active")])
    }
}

@Test @MainActor
func desktopInitialMCPRouterValidatesOfficialAddCreditsType() async {
    let probe = AccountRateLimitsRouterProbe()
    let invalid = await CodexDesktopInitialMCPRouter
        .responseIncludingFileSystem(
            to: initialMCPRequest(
                id: .integer(84),
                method: "account/sendAddCreditsNudgeEmail",
                params: .object([
                    "creditType": .string("other"),
                ])
            ),
            state: initialMCPState(),
            allowedFileSystemRoots: [],
            rateLimitsReader: probe
        )

    #expect(
        invalid == initialMCPError(
            id: .integer(84),
            code: -32602,
            message:
                "Invalid params for account/sendAddCreditsNudgeEmail"
        )
    )
    #expect(probe.nudgeCreditType == nil)

    let valid = await CodexDesktopInitialMCPRouter
        .responseIncludingFileSystem(
            to: initialMCPRequest(
                id: .integer(85),
                method: "account/sendAddCreditsNudgeEmail",
                params: .object([
                    "creditType": .string("usage_limit"),
                ])
            ),
            state: initialMCPState(),
            allowedFileSystemRoots: [],
            rateLimitsReader: probe
        )

    #expect(probe.nudgeCreditType == "usage_limit")
    #expect(
        valid == .mcpResponse(
            hostID: "desktop-host-1",
            message: .object([
                "id": .integer(85),
                "result": .object([
                    "status": .string("cooldown_active"),
                ]),
            ]),
            metadata: [:]
        )
    )
}

@Test @MainActor
func desktopInitialMCPRouterPassesOptionalAccountUsageThreadID() async {
    let probe = AccountRateLimitsRouterProbe()
    let params: [CodexJSONValue?] = [
        nil,
        .null,
        .object([:]),
        .object(["threadId": .null]),
        .object([
            "threadId": .string("019fc8ab-1fb2-7000-8000-000000000789")
        ]),
    ]
    for (offset, params) in params.enumerated() {
        let response = await CodexDesktopInitialMCPRouter.responseIncludingFileSystem(
            to: initialMCPRequest(
                id: .integer(Int64(500 + offset)),
                method: "account/usage/read",
                params: params
            ),
            state: initialMCPState(),
            allowedFileSystemRoots: [],
            rateLimitsReader: probe
        )
        #expect(response != initialMCPError(
            id: .integer(Int64(500 + offset)),
            code: -32602,
            message: "Invalid params for account/usage/read"
        ))
    }
    #expect(probe.usageThreadID == "019fc8ab-1fb2-7000-8000-000000000789")

    let uppercaseResponse = await CodexDesktopInitialMCPRouter.responseIncludingFileSystem(
        to: initialMCPRequest(
            id: .integer(509),
            method: "account/usage/read",
            params: .object([
                "threadId": .string("019FC8AB-1FB2-7000-8000-000000000789")
            ])
        ),
        state: initialMCPState(),
        allowedFileSystemRoots: [],
        rateLimitsReader: probe
    )
    #expect(uppercaseResponse != initialMCPError(
        id: .integer(509),
        code: -32602,
        message: "Invalid params for account/usage/read"
    ))
    #expect(probe.usageThreadID == "019fc8ab-1fb2-7000-8000-000000000789")

    let invalidParams: [CodexJSONValue] = [
        .array([]),
        .object(["threadId": .integer(1)]),
        .object(["threadId": .string("not-a-thread-id")]),
        .object(["threadId": .string("")]),
        .object(["extra": .null]),
    ]
    for (offset, params) in invalidParams.enumerated() {
        let id = CodexAppServerRequestID.integer(Int64(510 + offset))
        let response = await CodexDesktopInitialMCPRouter.responseIncludingFileSystem(
            to: initialMCPRequest(
                id: id,
                method: "account/usage/read",
                params: params
            ),
            state: initialMCPState(),
            allowedFileSystemRoots: [],
            rateLimitsReader: probe
        )
        #expect(response == initialMCPError(
            id: id,
            code: -32602,
            message: "Invalid params for account/usage/read"
        ))
    }
}

@Test
func desktopInitialMCPRouterCompletesReleasedFileSystemMutationBatch() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("codex-fs-batch-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let folder = root.appendingPathComponent("nested", isDirectory: true)
    let file = folder.appendingPathComponent("source.txt")
    let copy = folder.appendingPathComponent("copy.txt")

    func call(_ id: Int64, _ method: String, _ params: [String: CodexJSONValue]) async -> CodexDesktopHostMessage {
        await CodexDesktopInitialMCPRouter.responseIncludingFileSystem(
            to: initialMCPRequest(id: .integer(id), method: method, params: .object(params)),
            state: initialMCPState(), allowedFileSystemRoots: [root.path]
        )
    }
    _ = await call(201, "fs/createDirectory", ["path": .string(folder.path), "recursive": .bool(true)])
    _ = await call(202, "fs/writeFile", ["path": .string(file.path), "dataBase64": .string(Data("desktop parity".utf8).base64EncodedString())])
    let metadata = await call(203, "fs/getMetadata", ["path": .string(file.path)])
    let directory = await call(204, "fs/readDirectory", ["path": .string(folder.path)])
    _ = await call(205, "fs/copy", ["sourcePath": .string(file.path), "destinationPath": .string(copy.path)])
    _ = await call(206, "fs/remove", ["path": .string(file.path)])

    #expect(try String(contentsOf: copy, encoding: .utf8) == "desktop parity")
    #expect(!FileManager.default.fileExists(atPath: file.path))
    guard case let .mcpResponse(_, .object(metaEnvelope), _) = metadata,
          case let .object(meta)? = metaEnvelope["result"] else {
        Issue.record("metadata response shape mismatch"); return
    }
    #expect(meta["isFile"] == .bool(true))
    guard case let .mcpResponse(_, .object(dirEnvelope), _) = directory,
          case let .object(dirResult)? = dirEnvelope["result"],
          case let .array(entries)? = dirResult["entries"] else {
        Issue.record("directory response shape mismatch"); return
    }
    #expect(entries.contains(.object(["fileName": .string("source.txt"), "isDirectory": .bool(false), "isFile": .bool(true)])))
}

@Test
@MainActor
func desktopInitialMCPRouterCompletesReleasedThreadGoalBatch() async {
    let threadID = UUID(
        uuidString: "019fab26-5c01-7562-97f1-0999adf15538"
    )!
    let manager = DesktopThreadGoalManagerStub()

    func call(
        _ id: Int64,
        _ method: String,
        _ params: [String: CodexJSONValue]
    ) async -> CodexDesktopHostMessage {
        await CodexDesktopInitialMCPRouter.responseIncludingFileSystem(
            to: initialMCPRequest(
                id: .integer(id),
                method: method,
                params: .object(params)
            ),
            state: initialMCPState(),
            allowedFileSystemRoots: [],
            threadLister: manager
        )
    }

    let set = await call(301, "thread/goal/set", [
        "threadId": .string(threadID.uuidString.lowercased()),
        "objective": .string("Finish exact desktop parity"),
        "status": .string("active"),
        "tokenBudget": .integer(9_000),
    ])
    #expect(
        set == goalResponse(
            id: 301,
            threadID: threadID,
            objective: "Finish exact desktop parity",
            status: "active",
            tokenBudget: 9_000
        )
    )

    let update = await call(302, "thread/goal/set", [
        "threadId": .string(threadID.uuidString.lowercased()),
        "status": .string("paused"),
        "tokenBudget": .null,
    ])
    #expect(
        update == goalResponse(
            id: 302,
            threadID: threadID,
            objective: "Finish exact desktop parity",
            status: "paused",
            tokenBudget: nil
        )
    )

    let read = await call(303, "thread/goal/get", [
        "threadId": .string(threadID.uuidString.lowercased())
    ])
    #expect(
        read == goalResponse(
            id: 303,
            threadID: threadID,
            objective: "Finish exact desktop parity",
            status: "paused",
            tokenBudget: nil
        )
    )

    let cleared = await call(304, "thread/goal/clear", [
        "threadId": .string(threadID.uuidString.lowercased())
    ])
    #expect(
        cleared == .mcpResponse(
            hostID: "desktop-host-1",
            message: .object([
                "id": .integer(304),
                "result": .object(["cleared": .bool(true)]),
            ]),
            metadata: [:]
        )
    )
    #expect(manager.goal == nil)
}

@Test
@MainActor
func desktopInitialMCPRouterPagesLoadedThreads() async {
    let manager = DesktopThreadGoalManagerStub()
    manager.loadedIDs = [
        CodexStoredThreadID(rawValue: "thread-a"),
        CodexStoredThreadID(rawValue: "thread-b"),
        CodexStoredThreadID(rawValue: "thread-c"),
    ]

    let first = await CodexDesktopInitialMCPRouter
        .responseIncludingFileSystem(
            to: initialMCPRequest(
                id: .integer(310),
                method: "thread/loaded/list",
                params: .object(["limit": .integer(2)])
            ),
            state: initialMCPState(),
            allowedFileSystemRoots: [],
            threadLister: manager
        )
    #expect(
        first == .mcpResponse(
            hostID: "desktop-host-1",
            message: .object([
                "id": .integer(310),
                "result": .object([
                    "data": .array([
                        .string("thread-a"),
                        .string("thread-b"),
                    ]),
                    "nextCursor": .string("thread-b"),
                ]),
            ]),
            metadata: [:]
        )
    )

    let second = await CodexDesktopInitialMCPRouter
        .responseIncludingFileSystem(
            to: initialMCPRequest(
                id: .integer(311),
                method: "thread/loaded/list",
                params: .object([
                    "cursor": .string("thread-b"),
                    "limit": .integer(2),
                ])
            ),
            state: initialMCPState(),
            allowedFileSystemRoots: [],
            threadLister: manager
        )
    #expect(
        second == .mcpResponse(
            hostID: "desktop-host-1",
            message: .object([
                "id": .integer(311),
                "result": .object([
                    "data": .array([.string("thread-c")]),
                    "nextCursor": .null,
                ]),
            ]),
            metadata: [:]
        )
    )
}

@Test
@MainActor
func desktopInitialMCPRouterUnsubscribesWithOfficialStatus() async {
    let manager = DesktopThreadGoalManagerStub()
    manager.unsubscribeStatus = .unsubscribed
    let response = await CodexDesktopInitialMCPRouter
        .responseIncludingFileSystem(
            to: initialMCPRequest(
                id: .integer(312),
                method: "thread/unsubscribe",
                params: .object(["threadId": .string("thread-a")])
            ),
            state: initialMCPState(),
            allowedFileSystemRoots: [],
            threadLister: manager
        )
    #expect(manager.unsubscribedID?.rawValue == "thread-a")
    #expect(
        response == .mcpResponse(
            hostID: "desktop-host-1",
            message: .object([
                "id": .integer(312),
                "result": .object([
                    "status": .string("unsubscribed")
                ]),
            ]),
            metadata: [:]
        )
    )
}

@Test
@MainActor
func desktopInitialMCPRouterRollsBackThreadThroughSessionBoundary() async {
    let threadID = CodexStoredThreadID(
        rawValue: "019fab26-5c01-7562-97f1-0999adf15538"
    )
    let manager = DesktopThreadMutationStub(threadID: threadID)
    let response = await CodexDesktopInitialMCPRouter
        .responseIncludingFileSystem(
            to: initialMCPRequest(
                id: .integer(320),
                method: "thread/rollback",
                params: .object([
                    "threadId": .string(threadID.rawValue),
                    "numTurns": .integer(2),
                ])
            ),
            state: initialMCPState(),
            allowedFileSystemRoots: [],
            threadLister: manager
        )

    #expect(manager.rollback?.0 == threadID)
    #expect(manager.rollback?.1 == 2)
    guard case let .mcpResponse(_, .object(envelope), _) = response,
          case let .object(result)? = envelope["result"],
          case let .object(thread)? = result["thread"]
    else {
        Issue.record("thread rollback response shape mismatch")
        return
    }
    #expect(envelope["id"] == .integer(320))
    #expect(thread["id"] == .string(threadID.rawValue))
    #expect(thread["turns"] == .array([]))
}

@Test
@MainActor
func desktopInitialMCPRouterRevertsThreadThroughSessionBoundary() async {
    let threadID = CodexStoredThreadID(
        rawValue: "019fab26-5c01-7562-97f1-0999adf15538"
    )
    let beforeTurnID = "019fab26-5c01-7562-97f1-0999adf15539"
    let manager = DesktopThreadMutationStub(threadID: threadID)
    let response = await CodexDesktopInitialMCPRouter
        .responseIncludingFileSystem(
            to: initialMCPRequest(
                id: .integer(321),
                method: "thread/revert",
                params: .object([
                    "threadId": .string(threadID.rawValue),
                    "beforeTurnId": .string(beforeTurnID),
                ])
            ),
            state: initialMCPState(),
            allowedFileSystemRoots: [],
            threadLister: manager
        )

    #expect(manager.revert?.0 == threadID)
    #expect(manager.revert?.1 == beforeTurnID)
    guard case let .mcpResponse(_, .object(envelope), _) = response,
          case let .object(result)? = envelope["result"],
          case let .object(thread)? = result["thread"]
    else {
        Issue.record("thread revert response shape mismatch")
        return
    }
    #expect(envelope["id"] == .integer(321))
    #expect(thread["id"] == .string(threadID.rawValue))
    #expect(result["turnsBackwardsCursor"] == nil)
    #expect(result["itemsBackwardsCursor"] == nil)
}

@Test
@MainActor
func desktopInitialMCPRouterCoversThreadUnarchiveResponse() async {
    let threadID = CodexStoredThreadID(
        rawValue: "019fab26-5c01-7562-97f1-0999adf15538"
    )
    let manager = DesktopThreadMutationStub(threadID: threadID)
    let response = await CodexDesktopInitialMCPRouter
        .responseIncludingFileSystem(
            to: initialMCPRequest(
                id: .integer(3201),
                method: "thread/unarchive",
                params: .object([
                    "threadId": .string(threadID.rawValue)
                ])
            ),
            state: initialMCPState(),
            allowedFileSystemRoots: [],
            threadLister: manager
        )

    guard case let .mcpResponse(_, .object(envelope), _) = response,
          case let .object(result)? = envelope["result"],
          case let .object(thread)? = result["thread"]
    else {
        Issue.record("thread unarchive response shape mismatch")
        return
    }
    #expect(envelope["id"] == .integer(3201))
    #expect(thread["id"] == .string(threadID.rawValue))
    #expect(thread["status"] == .object(["type": .string("active"), "activeFlags": .array([])]))
}

@Test
@MainActor
func desktopInitialMCPRouterForksThreadThroughSessionBoundary() async {
    let sourceID = CodexStoredThreadID(
        rawValue: "019fab26-5c01-7562-97f1-0999adf15538"
    )
    let manager = DesktopThreadForkStub(sourceID: sourceID)
    let response = await CodexDesktopInitialMCPRouter
        .responseIncludingFileSystem(
            to: initialMCPRequest(
                id: .integer(321),
                method: "thread/fork",
                params: .object([
                    "threadId": .string(sourceID.rawValue),
                    "lastTurnId": .string("turn-1"),
                    "path": .null,
                    "model": .string("gpt-5.5"),
                    "modelProvider": .string("openai"),
                    "cwd": .string("/workspace/fork"),
                    "runtimeWorkspaceRoots": .array([
                        .string("/workspace/fork")
                    ]),
                    "approvalPolicy": .string("never"),
                    "approvalsReviewer": .string("user"),
                    "sandbox": .string("danger-full-access"),
                    "config": .object([
                        "model_reasoning_effort": .string("high")
                    ]),
                    "developerInstructions": .string(
                        "Side conversation instructions"
                    ),
                    "ephemeral": .bool(true),
                    "threadSource": .string("automation"),
                    "excludeTurns": .bool(true),
                ])
            ),
            state: initialMCPState(),
            allowedFileSystemRoots: [],
            threadLister: manager
        )

    #expect(manager.params?.threadID == sourceID)
    #expect(manager.params?.lastTurnID == .value("turn-1"))
    #expect(manager.params?.ephemeral == true)
    #expect(manager.params?.threadSource == .value("automation"))
    if let params = manager.params {
        let forwardedRequest = CodexAppServerThreadRequest.fork(
            id: .string("fork-forward"),
            params: params
        )
        #expect(
            (try? forwardedRequest.encodedData())
                == Data(
                    #"{"id":"fork-forward","method":"thread/fork","params":{"approvalPolicy":"never","approvalsReviewer":"user","config":{"model_reasoning_effort":"high"},"cwd":"/workspace/fork","developerInstructions":"Side conversation instructions","ephemeral":true,"excludeTurns":true,"lastTurnId":"turn-1","model":"gpt-5.5","modelProvider":"openai","path":null,"sandbox":"danger-full-access","threadId":"019fab26-5c01-7562-97f1-0999adf15538","threadSource":"automation"}}"#.utf8
                )
        )
    } else {
        Issue.record("thread fork params did not reach the session boundary")
    }
    guard case let .mcpResponse(_, .object(envelope), _) = response,
          case let .object(result)? = envelope["result"],
          case let .object(thread)? = result["thread"]
    else {
        Issue.record("thread fork response shape mismatch")
        return
    }
    #expect(envelope["id"] == .integer(321))
    #expect(
        thread["forkedFromId"] == .string(sourceID.rawValue)
    )
    #expect(result["model"] == .string("gpt-5.5"))
    #expect(result["cwd"] == .string("/workspace/fork"))
}

@Test
@MainActor
func desktopInitialMCPRouterInjectsRawItemsThroughSessionBoundary() async {
    let threadID = CodexStoredThreadID(
        rawValue: "019fab26-5c01-7562-97f1-0999adf15538"
    )
    let manager = DesktopThreadInjectionStub()
    let item = CodexJSONValue.object([
        "type": .string("message"),
        "role": .string("user"),
        "content": .array([
            .object([
                "type": .string("input_text"),
                "text": .string("side conversation context"),
            ])
        ]),
    ])
    let response = await CodexDesktopInitialMCPRouter
        .responseIncludingFileSystem(
            to: initialMCPRequest(
                id: .integer(322),
                method: "thread/inject_items",
                params: .object([
                    "threadId": .string(threadID.rawValue),
                    "items": .array([item]),
                ])
            ),
            state: initialMCPState(),
            allowedFileSystemRoots: [],
            threadLister: manager
        )

    #expect(manager.threadID == threadID)
    #expect(manager.items == [item])
    #expect(
        response == .mcpResponse(
            hostID: "desktop-host-1",
            message: .object([
                "id": .integer(322),
                "result": .object([:]),
            ]),
            metadata: [:]
        )
    )
}

@Test
@MainActor
func desktopInitialMCPRouterApprovesGuardianDenialThroughSessionBoundary()
    async
{
    let threadID = CodexStoredThreadID(
        rawValue: "019fab26-5c01-7562-97f1-0999adf15538"
    )
    let manager = DesktopThreadGuardianApprovalStub()
    let event = CodexJSONValue.object([
        "id": .string("review-command-1"),
        "status": .string("denied"),
        "action": .object([
            "type": .string("command"),
            "source": .string("shell"),
            "command": .string("printf approved"),
            "cwd": .string("/workspace"),
        ]),
    ])
    let response = await CodexDesktopInitialMCPRouter
        .responseIncludingFileSystem(
            to: initialMCPRequest(
                id: .integer(323),
                method: "thread/approveGuardianDeniedAction",
                params: .object([
                    "threadId": .string(threadID.rawValue),
                    "event": event,
                ])
            ),
            state: initialMCPState(),
            allowedFileSystemRoots: [],
            threadLister: manager
        )

    #expect(manager.threadID == threadID)
    #expect(manager.event == event)
    #expect(
        response == .mcpResponse(
            hostID: "desktop-host-1",
            message: .object([
                "id": .integer(323),
                "result": .object([:]),
            ]),
            metadata: [:]
        )
    )
}

@MainActor
private final class DesktopThreadInjectionStub:
    CodexDesktopThreadSessionListing,
    CodexDesktopThreadItemsInjecting
{
    var threadID: CodexStoredThreadID?
    var items: [CodexJSONValue]?

    func listThreads(
        id _: CodexAppServerRequestID,
        params _: CodexThreadListParams
    ) throws -> CodexThreadPage {
        throw CodexSessionStoreError.invalidReply
    }

    func injectStoredThreadItems(
        id _: CodexAppServerRequestID,
        threadID: CodexStoredThreadID,
        items: [CodexJSONValue]
    ) throws {
        self.threadID = threadID
        self.items = items
    }
}

@MainActor
private final class DesktopThreadGuardianApprovalStub:
    CodexDesktopThreadSessionListing,
    CodexDesktopGuardianDeniedActionApproving
{
    var threadID: CodexStoredThreadID?
    var event: CodexJSONValue?

    func listThreads(
        id _: CodexAppServerRequestID,
        params _: CodexThreadListParams
    ) throws -> CodexThreadPage {
        throw CodexSessionStoreError.invalidReply
    }

    func approveGuardianDeniedAction(
        id _: CodexAppServerRequestID,
        threadID: CodexStoredThreadID,
        event: CodexJSONValue
    ) throws {
        self.threadID = threadID
        self.event = event
    }
}

@MainActor
private final class DesktopThreadForkStub:
    CodexDesktopThreadSessionListing,
    CodexDesktopThreadSessionForking
{
    let sourceID: CodexStoredThreadID
    var params: CodexThreadForkParams?

    init(sourceID: CodexStoredThreadID) {
        self.sourceID = sourceID
    }

    func listThreads(
        id _: CodexAppServerRequestID,
        params _: CodexThreadListParams
    ) throws -> CodexThreadPage {
        throw CodexSessionStoreError.invalidReply
    }

    func forkThread(
        id _: CodexAppServerRequestID,
        params: CodexThreadForkParams
    ) throws -> CodexThreadResumeResult {
        self.params = params
        let forkedID = CodexStoredThreadID(
            rawValue: "019fab26-5c01-7562-97f1-0999adf15539"
        )
        return CodexThreadResumeResult(
            thread: CodexStoredThread(
                id: forkedID,
                sessionID: forkedID.rawValue,
                forkedFromID: sourceID,
                preview: "",
                ephemeral: true,
                modelProvider: "openai",
                createdAt: 100,
                updatedAt: 100,
                status: .idle,
                cwd: "/workspace/fork",
                cliVersion: "0.146.0",
                source: .named(.appServer),
                threadSource: "automation",
                turns: []
            ),
            model: "gpt-5.5",
            modelProvider: "openai",
            serviceTier: nil,
            cwd: "/workspace/fork",
            instructionSources: [],
            approvalPolicy: .never,
            approvalsReviewer: .user,
            sandbox: .dangerFullAccess,
            reasoningEffort: nil
        )
    }
}

@Test
@MainActor
func desktopInitialMCPRouterStartsThreadThroughSessionBoundary() async {
    let manager = DesktopThreadStartStub()
    let response = await CodexDesktopInitialMCPRouter
        .responseIncludingFileSystem(
            to: initialMCPRequest(
                id: .integer(322),
                method: "thread/start",
                params: .object([
                    "cwd": .string("~"),
                    "modelProvider": .string("openai"),
                    "approvalPolicy": .string("on-request"),
                    "approvalsReviewer": .string("user"),
                    "sandbox": .string("workspace-write"),
                    "ephemeral": .bool(true),
                    "sessionStartSource": .string("startup"),
                    "threadSource": .string("app"),
                    "allowProviderModelFallback": .bool(true),
                    "dynamicTools": .array([]),
                    "environments": .array([
                        .object([
                            "environmentId": .string("local"),
                            "cwd": .string("/workspace"),
                        ])
                    ]),
                    "experimentalRawEvents": .bool(false),
                    "historyMode": .string("paginated"),
                    "mockExperimentalField": .null,
                    "mode": .string("default"),
                    "multiAgentMode": .string("explicitRequestOnly"),
                    "permissions": .string(":workspace"),
                    "runtimeWorkspaceRoots": .array([
                        .string("/workspace")
                    ]),
                    "selectedCapabilityRoots": .array([
                        .object([
                            "id": .string("github@openai"),
                            "location": .object([
                                "type": .string("environment"),
                                "environmentId": .string("local"),
                                "path": .string("/capabilities/github"),
                            ]),
                        ])
                    ]),
                    "threadStartKind": .string("default"),
                ])
            ),
            state: initialMCPState(),
            allowedFileSystemRoots: [],
            threadLister: manager
        )
    #expect(
        manager.params?.cwd
            == .value(FileManager.default.homeDirectoryForCurrentUser.path)
    )
    #expect(manager.params?.ephemeral == .value(true))
    #expect(manager.params?.sessionStartSource == .value("startup"))
    #expect(manager.params?.allowProviderModelFallback == .value(true))
    #expect(manager.params?.historyMode == .value(.paginated))
    #expect(manager.params?.mode == .value("default"))
    #expect(manager.params?.multiAgentMode == .value(.explicitRequestOnly))
    #expect(manager.params?.permissions == .value(":workspace"))
    #expect(manager.params?.runtimeWorkspaceRoots == .value(["/workspace"]))
    #expect(manager.params?.dynamicTools == .value([]))
    #expect(manager.params?.experimentalRawEvents == .value(false))
    #expect(manager.params?.mockExperimentalField == .null)
    #expect(manager.params?.threadStartKind == .value("default"))
    #expect(
        manager.params?.environments
            == .value([
                .object([
                    "environmentId": .string("local"),
                    "cwd": .string("/workspace"),
                ])
            ])
    )
    #expect(
        manager.params?.selectedCapabilityRoots
            == .value([
                .object([
                    "id": .string("github@openai"),
                    "location": .object([
                        "type": .string("environment"),
                        "environmentId": .string("local"),
                        "path": .string("/capabilities/github"),
                    ]),
                ])
            ])
    )
    guard case let .mcpResponse(_, .object(envelope), _) = response,
          case let .object(result)? = envelope["result"],
          case let .object(thread)? = result["thread"]
    else {
        Issue.record("thread start response shape mismatch")
        return
    }
    #expect(envelope["id"] == .integer(322))
    #expect(thread["forkedFromId"] == nil)
    #expect(result["model"] == .string("gpt-5.6-sol"))
}

@MainActor
private final class DesktopThreadStartStub:
    CodexDesktopThreadSessionListing,
    CodexDesktopThreadSessionStarting
{
    var params: CodexThreadStartParams?

    func listThreads(
        id _: CodexAppServerRequestID,
        params _: CodexThreadListParams
    ) throws -> CodexThreadPage {
        throw CodexSessionStoreError.invalidReply
    }

    func startThread(
        id _: CodexAppServerRequestID,
        params: CodexThreadStartParams
    ) throws -> CodexThreadResumeResult {
        self.params = params
        let id = CodexStoredThreadID(
            rawValue: "019fab26-5c01-7562-97f1-0999adf15540"
        )
        return CodexThreadResumeResult(
            thread: CodexStoredThread(
                id: id,
                sessionID: id.rawValue,
                preview: "",
                ephemeral: true,
                modelProvider: "openai",
                createdAt: 100,
                updatedAt: 100,
                status: .idle,
                cwd: "/workspace/project",
                cliVersion: "0.146.0",
                source: .named(.appServer),
                threadSource: "app",
                turns: []
            ),
            model: "gpt-5.6-sol",
            modelProvider: "openai",
            serviceTier: nil,
            cwd: "/workspace/project",
            instructionSources: [],
            approvalPolicy: .onRequest,
            approvalsReviewer: .user,
            sandbox: .workspaceWrite(
                writableRoots: [],
                networkAccess: false,
                excludeTmpdirEnvVar: false,
                excludeSlashTmp: false
            ),
            reasoningEffort: "high"
        )
    }
}

@MainActor
private final class DesktopThreadMutationStub:
    CodexDesktopThreadSessionListing,
    CodexDesktopThreadSessionMutating
{
    let threadID: CodexStoredThreadID
    var rollback: (CodexStoredThreadID, UInt32)?
    var revert: (CodexStoredThreadID, String)?

    init(threadID: CodexStoredThreadID) {
        self.threadID = threadID
    }

    func listThreads(
        id _: CodexAppServerRequestID,
        params _: CodexThreadListParams
    ) throws -> CodexThreadPage {
        throw CodexSessionStoreError.invalidReply
    }

    func archiveStoredThread(
        id _: CodexAppServerRequestID,
        threadID _: CodexStoredThreadID
    ) throws {}

    func unarchiveStoredThread(
        id _: CodexAppServerRequestID,
        threadID _: CodexStoredThreadID
    ) throws -> CodexThreadUnarchiveResponse {
        CodexThreadUnarchiveResponse(thread: storedThread())
    }

    func deleteStoredThread(
        id _: CodexAppServerRequestID,
        threadID _: CodexStoredThreadID
    ) throws {}

    func rollbackStoredThread(
        id _: CodexAppServerRequestID,
        threadID: CodexStoredThreadID,
        numTurns: UInt32
    ) throws -> CodexThreadReadResult {
        rollback = (threadID, numTurns)
        return CodexThreadReadResult(thread: storedThread())
    }

    func revertStoredThread(
        id _: CodexAppServerRequestID,
        threadID: CodexStoredThreadID,
        beforeTurnID: String
    ) throws -> CodexThreadRevertResult {
        revert = (threadID, beforeTurnID)
        return CodexThreadRevertResult(
            thread: storedThread(),
            turnsBackwardsCursor: nil,
            itemsBackwardsCursor: nil
        )
    }

    func setStoredThreadName(
        id _: CodexAppServerRequestID,
        threadID _: CodexStoredThreadID,
        name _: String
    ) throws {}

    private func storedThread() -> CodexStoredThread {
        CodexStoredThread(
            id: threadID,
            sessionID: threadID.rawValue,
            preview: "",
            ephemeral: false,
            modelProvider: "openai",
            createdAt: 100,
            updatedAt: 100,
            status: .active([]),
            cwd: "/workspace",
            cliVersion: "0.146.0",
            source: .named(.appServer),
            turns: []
        )
    }
}

@MainActor
private final class DesktopThreadGoalManagerStub:
    CodexDesktopThreadSessionListing,
    CodexDesktopThreadGoalManaging,
    CodexDesktopLoadedThreadListing,
    CodexDesktopThreadUnsubscribing
{
    var goal: ThreadGoal?
    var loadedIDs: [CodexStoredThreadID] = []
    var unsubscribeStatus: CodexThreadUnsubscribeStatus = .notSubscribed
    var unsubscribedID: CodexStoredThreadID?

    func listThreads(
        id _: CodexAppServerRequestID,
        params _: CodexThreadListParams
    ) throws -> CodexThreadPage {
        throw CodexSessionStoreError.invalidReply
    }

    func storedThreadGoal(
        threadID _: CodexStoredThreadID
    ) throws -> ThreadGoal? {
        goal
    }

    func setStoredThreadGoal(
        threadID: CodexStoredThreadID,
        objective: String?,
        status: ThreadGoalStatus?,
        tokenBudget: CodexWireOptional<Int64>
    ) throws -> ThreadGoal {
        let id = UUID(uuidString: threadID.rawValue)!
        let budget: Int64?
        switch tokenBudget {
        case .omitted:
            budget = goal?.tokenBudget
        case .null:
            budget = nil
        case let .value(value):
            budget = value
        }
        let next = ThreadGoal(
            threadID: id,
            objective: objective ?? goal?.objective ?? "",
            status: status ?? goal?.status ?? .active,
            tokenBudget: budget,
            tokensUsed: goal?.tokensUsed ?? 120,
            timeUsedSeconds: goal?.timeUsedSeconds ?? 45,
            createdAt: goal?.createdAt ?? 100,
            updatedAt: goal == nil ? 100 : 101
        )
        goal = next
        return next
    }

    func clearStoredThreadGoal(
        threadID _: CodexStoredThreadID
    ) throws -> Bool {
        let existed = goal != nil
        goal = nil
        return existed
    }

    func loadedStoredThreads(
        cursor: String?,
        limit: Int?
    ) throws -> CodexDesktopLoadedThreadPage {
        let start = cursor.flatMap { cursor in
            loadedIDs.firstIndex {
                $0.rawValue == cursor
            }.map { $0 + 1 }
        } ?? 0
        let end = min(loadedIDs.count, start + (limit ?? loadedIDs.count))
        let page = Array(loadedIDs[start..<end])
        return CodexDesktopLoadedThreadPage(
            data: page,
            nextCursor: end < loadedIDs.count
                ? page.last?.rawValue
                : nil
        )
    }

    func unsubscribeStoredThread(
        id _: CodexAppServerRequestID,
        threadID: CodexStoredThreadID
    ) throws -> CodexThreadUnsubscribeResponse {
        unsubscribedID = threadID
        return CodexThreadUnsubscribeResponse(status: unsubscribeStatus)
    }
}

private func goalResponse(
    id: Int64,
    threadID: UUID,
    objective: String,
    status: String,
    tokenBudget: Int64?
) -> CodexDesktopHostMessage {
    .mcpResponse(
        hostID: "desktop-host-1",
        message: .object([
            "id": .integer(id),
            "result": .object([
                "goal": .object([
                    "threadId": .string(
                        threadID.uuidString.lowercased()
                    ),
                    "objective": .string(objective),
                    "status": .string(status),
                    "tokenBudget": tokenBudget.map(
                        CodexJSONValue.integer
                    ) ?? .null,
                    "tokensUsed": .integer(120),
                    "timeUsedSeconds": .integer(45),
                    "createdAt": .integer(100),
                    "updatedAt": .integer(
                        status == "active" ? 100 : 101
                    ),
                ])
            ]),
        ]),
        metadata: [:]
    )
}

@Test @MainActor
func desktopInitialMCPRouterListsOfficialMCPServerStatusShape() async throws {
    let service = try CodexMCPServerStatusService(statuses: [CodexMCPServerStatus(
        name: "calendar",
        serverInfo: .object(["name": .string("Calendar MCP")]),
        tools: ["create": .object(["name": .string("create")])],
        resources: [CodexMCPResource(uri: "calendar://today", name: "today")],
        authStatus: .oauth
    )])
    let request = CodexDesktopMCPRequest(
        request: CodexDesktopMCPRequestMessage(id: .integer(92), method: "mcpServerStatus/list", params: .object(["cursor": .null, "limit": .integer(10), "detail": .string("full"), "threadId": .null]), metadata: [:]),
        hostID: "desktop-host-1", dispatchedAtMs: nil, priority: nil, source: nil, timeoutMs: nil, expiresAtMs: nil, metadata: [:]
    )
    let response = await CodexDesktopInitialMCPRouter.responseIncludingFileSystem(to: request, state: initialMCPState(), allowedFileSystemRoots: [], mcpStatusLister: service)
    guard case let .mcpResponse(_, message, _) = response,
          case let .object(envelope) = message,
          case let .object(result)? = envelope["result"],
          case let .array(data)? = result["data"], data.count == 1,
          case let .object(status) = data[0]
    else { Issue.record("missing MCP status response"); return }
    #expect(status["name"] == .string("calendar"))
    #expect(status["authStatus"] == .string("oauth"))
    #expect(result["nextCursor"] == .null)
}

@MainActor
private final class MCPRefreshProbe: CodexDesktopMCPServerRefreshing {
    var calls = 0
    var shouldFail = false

    func refreshMCPServers() async throws {
        calls += 1
        if shouldFail { throw NSError(domain: "probe", code: 1) }
    }
}

@MainActor
private final class MCPOAuthProbe: CodexDesktopMCPOAuthLoggingIn {
    var received: (String, String, String?, [String]?, Int64?)?
    var shouldFail = false

    func loginMCPServer(
        hostID: String,
        name: String,
        threadID: String?,
        scopes: [String]?,
        timeoutSeconds: Int64?
    ) async throws -> CodexDesktopMCPOAuthLoginResult {
        received = (
            hostID,
            name,
            threadID,
            scopes,
            timeoutSeconds
        )
        if shouldFail { throw NSError(domain: "probe", code: 2) }
        return CodexDesktopMCPOAuthLoginResult(
            authorizationURL: "https://mcp.example.test/oauth/authorize"
        )
    }
}

@Test @MainActor
func desktopInitialMCPRouterReloadsMCPConfigurationWithEmptyResult() async {
    let probe = MCPRefreshProbe()
    let request = initialMCPRequest(
        id: .string("reload-1"),
        method: "config/mcpServer/reload",
        params: .object([:])
    )
    let response = await CodexDesktopInitialMCPRouter.responseIncludingFileSystem(
        to: request,
        state: initialMCPState(),
        allowedFileSystemRoots: [],
        mcpRefresher: probe
    )
    #expect(probe.calls == 1)
    #expect(response == .mcpResponse(
        hostID: "desktop-host-1",
        message: .object([
            "id": .string("reload-1"),
            "result": .object([:])
        ]),
        metadata: [:]
    ))
}

@Test @MainActor
func desktopInitialMCPRouterStartsOfficialMCPOAuthLogin() async {
    let probe = MCPOAuthProbe()
    let request = initialMCPRequest(
        id: .integer(93),
        method: "mcpServer/oauth/login",
        params: .object([
            "name": .string("calendar"),
            "threadId": .string("thread-1"),
            "scopes": .array([.string("calendar.read"), .string("calendar.write")]),
            "timeoutSecs": .integer(45)
        ])
    )
    let response = await CodexDesktopInitialMCPRouter.responseIncludingFileSystem(
        to: request,
        state: initialMCPState(),
        allowedFileSystemRoots: [],
        mcpOAuthLogin: probe
    )
    #expect(probe.received?.0 == "desktop-host-1")
    #expect(probe.received?.1 == "calendar")
    #expect(probe.received?.2 == "thread-1")
    #expect(probe.received?.3 == ["calendar.read", "calendar.write"])
    #expect(probe.received?.4 == 45)
    #expect(response == .mcpResponse(
        hostID: "desktop-host-1",
        message: .object([
            "id": .integer(93),
            "result": .object([
                "authorizationUrl": .string("https://mcp.example.test/oauth/authorize")
            ])
        ]),
        metadata: [:]
    ))
}

@MainActor
private final class SkillCatalogRouterProbe:
    CodexDesktopSkillCataloging
{
    var extraRoots: [String] = []
    var enablement:
        (path: String?, name: String?, enabled: Bool)?

    func listSkills(
        cwds: [String],
        forceReload _: Bool
    ) throws -> [CodexSkillsListEntry] {
        [
            CodexSkillsListEntry(
                cwd: cwds.first ?? "/workspace",
                skills: [
                    CodexSkillMetadata(
                        name: "calendar",
                        description: "Calendar tools",
                        shortDescription: nil,
                        path: "/skills/calendar/SKILL.md",
                        scope: .user,
                        enabled: true
                    ),
                ],
                errors: []
            ),
        ]
    }

    func setSkillExtraRoots(_ roots: [String]) {
        extraRoots = roots
    }

    func setSkillEnabled(
        path: String?,
        name: String?,
        enabled: Bool
    ) throws -> Bool {
        enablement = (path, name, enabled)
        return enabled
    }
}

@Test @MainActor
func desktopInitialMCPRouterServesOfficialSkillsMethods() async {
    let probe = SkillCatalogRouterProbe()
    let list = await CodexDesktopInitialMCPRouter
        .responseIncludingFileSystem(
            to: initialMCPRequest(
                id: .integer(301),
                method: "skills/list",
                params: .object([
                    "cwds": .array([.string("/workspace")]),
                    "forceReload": .bool(true),
                ])
            ),
            state: initialMCPState(),
            allowedFileSystemRoots: [],
            skillCatalog: probe
        )
    guard case let .mcpResponse(_, listMessage, _) = list,
          case let .object(listEnvelope) = listMessage,
          case let .object(listResult)? = listEnvelope["result"],
          case let .array(data)? = listResult["data"],
          case let .object(entry) = data.first,
          case let .array(skills)? = entry["skills"],
          case let .object(skill) = skills.first
    else {
        Issue.record("missing skills/list result")
        return
    }
    #expect(entry["cwd"] == .string("/workspace"))
    #expect(skill["name"] == .string("calendar"))
    #expect(skill["scope"] == .string("user"))
    #expect(skill["enabled"] == .bool(true))

    let roots = await CodexDesktopInitialMCPRouter
        .responseIncludingFileSystem(
            to: initialMCPRequest(
                id: .integer(302),
                method: "skills/extraRoots/set",
                params: .object([
                    "extraRoots": .array([
                        .string("/workspace/.skills"),
                    ]),
                ])
            ),
            state: initialMCPState(),
            allowedFileSystemRoots: [],
            skillCatalog: probe
        )
    #expect(probe.extraRoots == ["/workspace/.skills"])
    #expect(
        roots == .mcpResponse(
            hostID: "desktop-host-1",
            message: .object([
                "id": .integer(302),
                "result": .object([:]),
            ]),
            metadata: [:]
        )
    )

    let config = await CodexDesktopInitialMCPRouter
        .responseIncludingFileSystem(
            to: initialMCPRequest(
                id: .integer(303),
                method: "skills/config/write",
                params: .object([
                    "path": .null,
                    "name": .string("calendar"),
                    "enabled": .bool(false),
                ])
            ),
            state: initialMCPState(),
            allowedFileSystemRoots: [],
            skillCatalog: probe
        )
    #expect(probe.enablement?.name == "calendar")
    #expect(probe.enablement?.enabled == false)
    #expect(
        config == .mcpResponse(
            hostID: "desktop-host-1",
            message: .object([
                "id": .integer(303),
                "result": .object([
                    "effectiveEnabled": .bool(false),
                ]),
            ]),
            metadata: [:]
        )
    )
}

@MainActor
private final class PluginCatalogRouterProbe:
    CodexDesktopPluginCataloging
{
    var uninstalledID: String?

    func listPlugins() -> CodexPluginListResponse {
        CodexPluginListResponse(
            marketplaces: [
                CodexPluginMarketplaceEntry(
                    name: "local-tools",
                    path: "/marketplace.json",
                    displayName: "Local tools",
                    plugins: [
                        CodexPluginSummary(
                            id: "calendar@local-tools",
                            name: "calendar",
                            version: "1.2.3",
                            localVersion: nil,
                            sourcePath: "/plugins/calendar",
                            installed: false,
                            enabled: false,
                            installPolicy: "AVAILABLE",
                            authPolicy: "ON_USE",
                            availability: "AVAILABLE",
                            keywords: ["calendar"]
                        ),
                    ]
                ),
            ],
            marketplaceLoadErrors: [],
            featuredPluginIDs: []
        )
    }

    func readPlugin(
        marketplacePath: String,
        pluginName: String
    ) throws -> CodexPluginDetail {
        let summary = listPlugins().marketplaces[0].plugins[0]
        return CodexPluginDetail(
            marketplaceName: "local-tools",
            marketplacePath: marketplacePath,
            summary: summary,
            description: "\(pluginName) details",
            skillNames: ["events"],
            hookKeys: [
                "calendar@local-tools:hooks/hooks.json:pre_tool_use:0:0",
            ],
            appIDs: [],
            mcpServerNames: []
        )
    }

    func installPlugin(
        marketplacePath _: String,
        pluginName _: String
    ) throws -> CodexPluginInstallResult {
        CodexPluginInstallResult(
            authPolicy: "ON_USE",
            appsNeedingAuth: []
        )
    }

    func uninstallPlugin(pluginID: String) throws {
        uninstalledID = pluginID
    }
}

@MainActor
private final class RemotePluginCatalogRouterProbe:
    CodexDesktopRemotePluginCataloging,
    CodexDesktopRemotePluginSharing
{
    var listedKinds: [String] = []
    var readID: String?
    var installedID: String?
    var uninstalledID: String?
    var skillRequest: (pluginID: String, name: String)?
    var shareUpdate:
        (pluginID: String, discoverability: String)?
    var deletedShareID: String?
    var failRemoteList = false

    private var summary: CodexRemotePluginSummary {
        CodexRemotePluginSummary(
            id: "calendar@openai-curated-remote",
            remotePluginID: "plugin_remote_1",
            version: "2.0.0",
            localVersion: nil,
            name: "calendar",
            installed: false,
            enabled: false,
            installPolicy: "AVAILABLE",
            installPolicySource: nil,
            mustShowInstallationInterstitial: nil,
            authPolicy: "ON_USE",
            availability: "AVAILABLE",
            interface: .object([
                "shortDescription": .string("Manage events"),
            ]),
            keywords: ["calendar"]
        )
    }

    func listRemotePlugins(
        marketplaceKinds: [String],
        forceRefetch _: Bool
    ) async throws -> CodexRemotePluginListResponse {
        listedKinds = marketplaceKinds
        if failRemoteList {
            throw NSError(
                domain: "RemotePluginCatalogRouterProbe",
                code: 1
            )
        }
        return CodexRemotePluginListResponse(
            marketplaces: [
                CodexRemotePluginMarketplace(
                    name: "openai-curated-remote",
                    displayName: "OpenAI Curated Remote",
                    plugins: [summary]
                ),
            ],
            featuredPluginIDs: ["plugin_remote_1"]
        )
    }

    func searchRemotePlugins(
        searchTerm: String,
        scope: String?,
        cwds: [String]?,
        cursor: String?,
        limit: Int?
    ) async throws -> CodexRemotePluginSearchResponse {
        listedKinds = [
            searchTerm,
            scope ?? "nil",
            cwds?.joined(separator: ",") ?? "nil",
            cursor ?? "nil",
            limit.map(String.init) ?? "nil",
        ]
        return CodexRemotePluginSearchResponse(
            data: [
                CodexRemotePluginSearchResult(
                    plugin: summary,
                    marketplaceName: "openai-curated-remote",
                    marketplacePath: nil
                ),
            ],
            nextCursor: "next-cursor"
        )
    }

    func listInstalledRemotePlugins() async throws
        -> [CodexRemotePluginMarketplace]
    {
        []
    }

    func readRemotePlugin(
        marketplaceName _: String,
        remotePluginID: String
    ) async throws -> CodexRemotePluginDetail {
        readID = remotePluginID
        return CodexRemotePluginDetail(
            marketplaceName: "openai-curated-remote",
            marketplaceDisplayName: "OpenAI Curated Remote",
            summary: summary,
            shareURL: nil,
            description: "Calendar integration",
            releaseVersion: "2.0.0",
            bundleDownloadURL: nil,
            appManifest: nil,
            skills: [
                CodexRemotePluginSkill(
                    name: "calendar",
                    description: "Manage calendars",
                    interface: nil,
                    enabled: true
                ),
            ],
            appIDs: ["app_calendar"],
            appTemplates: [],
            mcpServerNames: ["calendar"],
            scheduledTasks: nil
        )
    }

    func installRemotePlugin(
        marketplaceName _: String,
        remotePluginID: String
    ) async throws -> CodexPluginInstallResult {
        installedID = remotePluginID
        return CodexPluginInstallResult(
            authPolicy: "ON_USE",
            appsNeedingAuth: ["app_calendar"]
        )
    }

    func uninstallRemotePlugin(
        pluginID: String
    ) async throws {
        uninstalledID = pluginID
    }

    func readRemotePluginSkill(
        remotePluginID: String,
        skillName: String
    ) async throws -> String? {
        skillRequest = (remotePluginID, skillName)
        return "# Calendar"
    }

    func saveRemotePluginShare(
        pluginPath _: URL,
        remotePluginID: String?,
        discoverability _: String?,
        shareTargets _: [CodexRemotePluginShareTarget]?
    ) async throws -> CodexRemotePluginShareSaveResult {
        CodexRemotePluginShareSaveResult(
            remotePluginID: remotePluginID ?? "plugin_shared_1",
            shareURL: "https://chatgpt.example/share/1",
            canPublishToWorkspace: true
        )
    }

    func checkoutRemotePluginShare(
        remotePluginID: String
    ) async throws -> CodexRemotePluginShareCheckoutResult {
        CodexRemotePluginShareCheckoutResult(
            remotePluginID: remotePluginID,
            pluginID: "calendar@codex-curated",
            pluginName: "calendar",
            pluginPath: "/plugins/calendar",
            marketplaceName: "codex-curated",
            marketplacePath:
                "/home/.agents/plugins/marketplace.json",
            remoteVersion: "2.0.0"
        )
    }

    func updateRemotePluginShareTargets(
        remotePluginID: String,
        discoverability: String,
        shareTargets _: [CodexRemotePluginShareTarget]
    ) async throws -> CodexRemotePluginShareUpdateResult {
        shareUpdate = (remotePluginID, discoverability)
        return CodexRemotePluginShareUpdateResult(
            principals: [
                CodexRemotePluginSharePrincipal(
                    principalType: "user",
                    principalID: "user-1",
                    role: "owner",
                    name: "Mars"
                ),
            ],
            discoverability: discoverability
        )
    }

    func listRemotePluginShares() async throws
        -> [CodexRemotePluginShareListItem]
    {
        [
            CodexRemotePluginShareListItem(
                plugin: summary,
                localPluginPath: "/plugins/calendar"
            ),
        ]
    }

    func deleteRemotePluginShare(
        remotePluginID: String
    ) async throws {
        deletedShareID = remotePluginID
    }
}

@Test @MainActor
func desktopInitialMCPRouterServesOfficialPluginSearch()
    async
{
    let probe = RemotePluginCatalogRouterProbe()
    let response = await CodexDesktopInitialMCPRouter
        .responseIncludingFileSystem(
            to: initialMCPRequest(
                id: .integer(323),
                method: "plugin/search",
                params: .object([
                    "searchTerm": .string("linear"),
                    "scope": .string("global"),
                    "cwds": .array([
                        .string("/workspace/project"),
                    ]),
                    "cursor": .string("cursor-1"),
                    "limit": .integer(32),
                ])
            ),
            state: initialMCPState(),
            allowedFileSystemRoots: [],
            remotePluginCatalog: probe
        )

    #expect(
        probe.listedKinds
            == [
                "linear",
                "global",
                "/workspace/project",
                "cursor-1",
                "32",
            ]
    )
    guard case let .mcpResponse(_, message, _) = response,
          case let .object(envelope) = message,
          case let .object(result)? = envelope["result"],
          case let .array(data)? = result["data"],
          case let .object(searchResult) = data.first
    else {
        Issue.record("missing plugin/search result")
        return
    }
    #expect(
        searchResult["marketplaceName"]
            == .string("openai-curated-remote")
    )
    #expect(searchResult["marketplacePath"] == .null)
    #expect(
        result["nextCursor"]
            == .string("next-cursor")
    )
}

@Test @MainActor
func desktopInitialMCPRouterKeepsLocalPluginsWhenRemoteListFails()
    async
{
    let local = PluginCatalogRouterProbe()
    let remote = RemotePluginCatalogRouterProbe()
    remote.failRemoteList = true

    let response = await CodexDesktopInitialMCPRouter
        .responseIncludingFileSystem(
            to: initialMCPRequest(
                id: .integer(320),
                method: "plugin/list",
                params: .object([
                    "cwds": .null,
                    "marketplaceKinds": .array([
                        .string("local"),
                        .string("vertical"),
                    ]),
                    "forceRefetch": .bool(true),
                ])
            ),
            state: initialMCPState(),
            allowedFileSystemRoots: [],
            pluginCatalog: local,
            remotePluginCatalog: remote
        )

    guard case let .mcpResponse(_, message, _) = response,
          case let .object(envelope) = message,
          case let .object(result)? = envelope["result"],
          case let .array(marketplaces)? = result["marketplaces"],
          case let .object(marketplace) = marketplaces.first,
          case let .array(plugins)? = marketplace["plugins"],
          case let .object(plugin) = plugins.first
    else {
        Issue.record(
            "remote plugin failure must return the local catalog result"
        )
        return
    }
    #expect(remote.listedKinds == ["vertical"])
    #expect(marketplaces.count == 1)
    #expect(plugin["id"] == .string("calendar@local-tools"))
    #expect(result["marketplaceLoadErrors"] == .array([]))
    #expect(result["featuredPluginIds"] == .array([]))
}

@Test @MainActor
func desktopInitialMCPRouterCoversPluginInstalledParamsAndPluginInstalledResponse() async {
    let probe = PluginCatalogRouterProbe()
    let list = await CodexDesktopInitialMCPRouter
        .responseIncludingFileSystem(
            to: initialMCPRequest(
                id: .integer(311),
                method: "plugin/list",
                params: .object([
                    "cwds": .null,
                    "marketplaceKinds": .array([
                        .string("local")
                    ]),
                    "forceRefetch": .bool(false),
                ])
            ),
            state: initialMCPState(),
            allowedFileSystemRoots: [],
            pluginCatalog: probe
        )
    guard case let .mcpResponse(_, listMessage, _) = list,
          case let .object(listEnvelope) = listMessage,
          case let .object(result)? = listEnvelope["result"],
          case let .array(marketplaces)? = result["marketplaces"],
          case let .object(marketplace) = marketplaces.first,
          case let .array(plugins)? = marketplace["plugins"],
          case let .object(plugin) = plugins.first
    else {
        Issue.record("missing plugin/list result")
        return
    }
    #expect(plugin["id"] == .string("calendar@local-tools"))
    #expect(plugin["source"] == .object([
        "type": .string("local"),
        "path": .string("/plugins/calendar"),
    ]))

    let installed = await CodexDesktopInitialMCPRouter
        .responseIncludingFileSystem(
            to: initialMCPRequest(
                id: .integer(3111),
                method: "plugin/installed",
                params: .object([:])
            ),
            state: initialMCPState(),
            allowedFileSystemRoots: [],
            pluginCatalog: probe
        )
    guard case let .mcpResponse(_, installedMessage, _) = installed,
          case let .object(installedEnvelope) = installedMessage,
          case let .object(installedResult)? = installedEnvelope["result"],
          case let .array(installedMarketplaces)? = installedResult["marketplaces"]
    else {
        Issue.record("missing plugin/installed result")
        return
    }
    #expect(installedEnvelope["id"] == .integer(3111))
    #expect(installedMarketplaces.count == 1)
    #expect(installedResult["marketplaceLoadErrors"] == .array([]))

    let read = await CodexDesktopInitialMCPRouter
        .responseIncludingFileSystem(
            to: initialMCPRequest(
                id: .integer(319),
                method: "plugin/read",
                params: .object([
                    "marketplacePath": .string(
                        "/marketplace.json"
                    ),
                    "remoteMarketplaceName": .null,
                    "pluginName": .string("calendar"),
                ])
            ),
            state: initialMCPState(),
            allowedFileSystemRoots: [],
            pluginCatalog: probe
        )
    guard case let .mcpResponse(_, readMessage, _) = read,
          case let .object(readEnvelope) = readMessage,
          case let .object(readResult)? =
            readEnvelope["result"],
          case let .object(detail)? =
            readResult["plugin"],
          case let .array(skills)? =
            detail["skills"],
          case let .object(skill) = skills.first,
          case let .array(hooks)? =
            detail["hooks"],
          case let .object(hook) = hooks.first
    else {
        Issue.record(
            "local plugin/read must expose declared skills and hooks"
        )
        return
    }
    #expect(skill["name"] == .string("events"))
    #expect(skill["path"] == .null)
    #expect(skill["enabled"] == .bool(false))
    #expect(
        hook["key"]
            == .string(
                "calendar@local-tools:hooks/hooks.json:pre_tool_use:0:0"
            )
    )

    let install = await CodexDesktopInitialMCPRouter
        .responseIncludingFileSystem(
            to: initialMCPRequest(
                id: .integer(312),
                method: "plugin/install",
                params: .object([
                    "marketplacePath": .string("/marketplace.json"),
                    "remoteMarketplaceName": .null,
                    "pluginName": .string("calendar"),
                ])
            ),
            state: initialMCPState(),
            allowedFileSystemRoots: [],
            pluginCatalog: probe
        )
    #expect(
        install == .mcpResponse(
            hostID: "desktop-host-1",
            message: .object([
                "id": .integer(312),
                "result": .object([
                    "authPolicy": .string("ON_USE"),
                    "appsNeedingAuth": .array([]),
                ]),
            ]),
            metadata: [:]
        )
    )

    _ = await CodexDesktopInitialMCPRouter
        .responseIncludingFileSystem(
            to: initialMCPRequest(
                id: .integer(313),
                method: "plugin/uninstall",
                params: .object([
                    "pluginId": .string(
                        "calendar@local-tools"
                    ),
                ])
            ),
            state: initialMCPState(),
            allowedFileSystemRoots: [],
            pluginCatalog: probe
        )
    #expect(probe.uninstalledID == "calendar@local-tools")
}

@Test @MainActor
func desktopInitialMCPRouterServesOfficialRemotePluginMethods()
    async
{
    let probe = RemotePluginCatalogRouterProbe()
    let save = await CodexDesktopInitialMCPRouter
        .responseIncludingFileSystem(
            to: initialMCPRequest(
                id: .integer(318),
                method: "plugin/share/save",
                params: .object([
                    "pluginPath": .string("/plugins/calendar"),
                    "discoverability": .string("PRIVATE"),
                    "shareTargets": .array([]),
                ])
            ),
            state: initialMCPState(),
            allowedFileSystemRoots: [],
            remotePluginCatalog: probe
        )
    guard case let .mcpResponse(_, saveMessage, _) = save,
          case let .object(saveEnvelope) = saveMessage,
          case let .object(saveResult)? = saveEnvelope["result"]
    else {
        Issue.record("missing plugin/share/save result")
        return
    }
    #expect(
        saveResult["remotePluginId"]
            == .string("plugin_shared_1")
    )

    let list = await CodexDesktopInitialMCPRouter
        .responseIncludingFileSystem(
            to: initialMCPRequest(
                id: .integer(314),
                method: "plugin/list",
                params: .object([
                    "cwds": .null,
                    "marketplaceKinds": .array([
                        .string("vertical"),
                    ]),
                    "forceRefetch": .bool(true),
                ])
            ),
            state: initialMCPState(),
            allowedFileSystemRoots: [],
            remotePluginCatalog: probe
        )
    guard case let .mcpResponse(_, listMessage, _) = list,
          case let .object(listEnvelope) = listMessage,
          case let .object(listResult)? = listEnvelope["result"],
          case let .array(marketplaces)? =
            listResult["marketplaces"],
          case let .object(marketplace) = marketplaces.first,
          case let .array(plugins)? = marketplace["plugins"],
          case let .object(plugin) = plugins.first
    else {
        Issue.record("missing remote plugin/list result")
        return
    }
    #expect(probe.listedKinds == ["vertical"])
    #expect(plugin["remotePluginId"] == .string("plugin_remote_1"))
    #expect(plugin["source"] == .object([
        "type": .string("remote"),
    ]))
    #expect(
        listResult["featuredPluginIds"]
            == .array([.string("plugin_remote_1")])
    )

    let read = await CodexDesktopInitialMCPRouter
        .responseIncludingFileSystem(
            to: initialMCPRequest(
                id: .integer(315),
                method: "plugin/read",
                params: .object([
                    "marketplacePath": .null,
                    "remoteMarketplaceName":
                        .string("openai-curated-remote"),
                    "pluginName": .string("plugin_remote_1"),
                ])
            ),
            state: initialMCPState(),
            allowedFileSystemRoots: [],
            remotePluginCatalog: probe
        )
    #expect(probe.readID == "plugin_remote_1")
    guard case let .mcpResponse(_, readMessage, _) = read,
          case let .object(readEnvelope) = readMessage,
          case let .object(readResult)? = readEnvelope["result"],
          case let .object(detail)? = readResult["plugin"],
          case let .array(skills)? = detail["skills"]
    else {
        Issue.record("missing remote plugin/read result")
        return
    }
    #expect(skills.count == 1)

    let install = await CodexDesktopInitialMCPRouter
        .responseIncludingFileSystem(
            to: initialMCPRequest(
                id: .integer(316),
                method: "plugin/install",
                params: .object([
                    "marketplacePath": .null,
                    "remoteMarketplaceName":
                        .string("openai-curated-remote"),
                    "pluginName": .string("plugin_remote_1"),
                ])
            ),
            state: initialMCPState(),
            allowedFileSystemRoots: [],
            remotePluginCatalog: probe
        )
    #expect(probe.installedID == "plugin_remote_1")
    guard case let .mcpResponse(_, installMessage, _) = install,
          case let .object(installEnvelope) = installMessage,
          case let .object(installResult)? =
            installEnvelope["result"]
    else {
        Issue.record("missing remote plugin/install result")
        return
    }
    #expect(
        installResult["appsNeedingAuth"]
            == .array([
                .object(["id": .string("app_calendar")]),
            ])
    )

    _ = await CodexDesktopInitialMCPRouter
        .responseIncludingFileSystem(
            to: initialMCPRequest(
                id: .integer(317),
                method: "plugin/skill/read",
                params: .object([
                    "remoteMarketplaceName":
                        .string("openai-curated-remote"),
                    "remotePluginId":
                        .string("plugin_remote_1"),
                    "skillName": .string("calendar"),
                ])
            ),
            state: initialMCPState(),
            allowedFileSystemRoots: [],
            remotePluginCatalog: probe
        )
    #expect(probe.skillRequest?.pluginID == "plugin_remote_1")

    _ = await CodexDesktopInitialMCPRouter
        .responseIncludingFileSystem(
            to: initialMCPRequest(
                id: .integer(318),
                method: "plugin/uninstall",
                params: .object([
                    "pluginId":
                        .string(
                            "calendar@openai-curated-remote"
                        ),
                ])
            ),
            state: initialMCPState(),
            allowedFileSystemRoots: [],
            remotePluginCatalog: probe
        )
    #expect(
        probe.uninstalledID
            == "calendar@openai-curated-remote"
    )
}

@Test @MainActor
func desktopInitialMCPRouterServesRemotePluginSharingMethods()
    async
{
    let probe = RemotePluginCatalogRouterProbe()
    let update = await CodexDesktopInitialMCPRouter
        .responseIncludingFileSystem(
            to: initialMCPRequest(
                id: .integer(319),
                method: "plugin/share/updateTargets",
                params: .object([
                    "remotePluginId":
                        .string("plugin_remote_1"),
                    "discoverability": .string("PRIVATE"),
                    "shareTargets": .array([]),
                ])
            ),
            state: initialMCPState(),
            allowedFileSystemRoots: [],
            remotePluginCatalog: probe
        )
    #expect(probe.shareUpdate?.pluginID == "plugin_remote_1")
    guard case let .mcpResponse(_, updateMessage, _) = update,
          case let .object(updateEnvelope) = updateMessage,
          case let .object(updateResult)? =
            updateEnvelope["result"]
    else {
        Issue.record("missing plugin/share/updateTargets result")
        return
    }
    #expect(
        updateResult["discoverability"] == .string("PRIVATE")
    )

    let list = await CodexDesktopInitialMCPRouter
        .responseIncludingFileSystem(
            to: initialMCPRequest(
                id: .integer(320),
                method: "plugin/share/list",
                params: .object([:])
            ),
            state: initialMCPState(),
            allowedFileSystemRoots: [],
            remotePluginCatalog: probe
        )
    guard case let .mcpResponse(_, listMessage, _) = list,
          case let .object(listEnvelope) = listMessage,
          case let .object(listResult)? = listEnvelope["result"],
          case let .array(data)? = listResult["data"],
          case let .object(item) = data.first
    else {
        Issue.record("missing plugin/share/list result")
        return
    }
    #expect(
        item["localPluginPath"] == .string("/plugins/calendar")
    )

    let checkout = await CodexDesktopInitialMCPRouter
        .responseIncludingFileSystem(
            to: initialMCPRequest(
                id: .integer(321),
                method: "plugin/share/checkout",
                params: .object([
                    "remotePluginId":
                        .string("plugin_remote_1"),
                ])
            ),
            state: initialMCPState(),
            allowedFileSystemRoots: [],
            remotePluginCatalog: probe
        )
    guard case let .mcpResponse(_, checkoutMessage, _) = checkout,
          case let .object(checkoutEnvelope) = checkoutMessage,
          case let .object(checkoutResult)? =
            checkoutEnvelope["result"]
    else {
        Issue.record("missing plugin/share/checkout result")
        return
    }
    #expect(
        checkoutResult["pluginId"]
            == .string("calendar@codex-curated")
    )

    _ = await CodexDesktopInitialMCPRouter
        .responseIncludingFileSystem(
            to: initialMCPRequest(
                id: .integer(322),
                method: "plugin/share/delete",
                params: .object([
                    "remotePluginId":
                        .string("plugin_remote_1"),
                ])
            ),
            state: initialMCPState(),
            allowedFileSystemRoots: [],
            remotePluginCatalog: probe
        )
    #expect(probe.deletedShareID == "plugin_remote_1")
}

@Test @MainActor
func desktopInitialMCPRouterRejectsMalformedMCPOAuthParams() async {
    let probe = MCPOAuthProbe()
    let response = await CodexDesktopInitialMCPRouter.responseIncludingFileSystem(
        to: initialMCPRequest(
            id: .integer(94),
            method: "mcpServer/oauth/login",
            params: .object([
                "name": .string("calendar"),
                "scopes": .array([.integer(1)])
            ])
        ),
        state: initialMCPState(),
        allowedFileSystemRoots: [],
        mcpOAuthLogin: probe
    )
    #expect(response == .mcpResponse(
        hostID: "desktop-host-1",
        message: .object([
            "id": .integer(94),
            "error": .object([
                "code": .integer(-32602),
                "message": .string("Invalid params for mcpServer/oauth/login")
            ])
        ]),
        metadata: [:]
    ))
}

@MainActor
private final class DesktopThreadMemoryModeUpdaterProbe:
    CodexDesktopThreadSessionListing,
    CodexDesktopThreadMemoryModeUpdating
{
    private(set) var requestID: CodexAppServerRequestID?
    private(set) var params: CodexThreadMemoryModeSetParams?
    private(set) var callCount = 0

    func listThreads(
        id _: CodexAppServerRequestID,
        params _: CodexThreadListParams
    ) throws -> CodexThreadPage {
        throw CodexSessionStoreError.invalidReply
    }

    func setThreadMemoryMode(
        id: CodexAppServerRequestID,
        params: CodexThreadMemoryModeSetParams
    ) throws {
        requestID = id
        self.params = params
        callCount += 1
    }
}

@Test
@MainActor
func desktopInitialMCPRouterServesStrictThreadMemoryModeSet() async {
    let probe = DesktopThreadMemoryModeUpdaterProbe()
    let validID = CodexAppServerRequestID.integer(401)
    let valid = await CodexDesktopInitialMCPRouter
        .responseIncludingFileSystem(
            to: initialMCPRequest(
                id: validID,
                method: "thread/memoryMode/set",
                params: .object([
                    "threadId": .string("Thread/Raw/Ω"),
                    "mode": .string("disabled"),
                ])
            ),
            state: initialMCPState(),
            allowedFileSystemRoots: [],
            threadLister: probe
        )

    #expect(probe.requestID == validID)
    #expect(
        probe.params == CodexThreadMemoryModeSetParams(
            threadID: CodexStoredThreadID("Thread/Raw/Ω"),
            mode: .disabled
        )
    )
    #expect(probe.callCount == 1)
    #expect(
        valid == .mcpResponse(
            hostID: "desktop-host-1",
            message: .object([
                "id": .integer(401),
                "result": .object([:]),
            ]),
            metadata: [:]
        )
    )

    let invalidParams: [CodexJSONValue?] = [
        .object(["threadId": .string("Thread/Raw/Ω")]),
        .object([
            "threadId": .string("Thread/Raw/Ω"),
            "mode": .string("enabled"),
            "extra": .bool(true),
        ]),
        .object([
            "threadId": .string(""),
            "mode": .string("enabled"),
        ]),
        .object([
            "threadId": .string("Thread/Raw/Ω"),
            "mode": .string("future"),
        ]),
        .object([
            "threadId": .integer(1),
            "mode": .string("enabled"),
        ]),
        .object([
            "threadId": .string("Thread/Raw/Ω"),
            "mode": .bool(true),
        ]),
        nil,
    ]

    for (offset, params) in invalidParams.enumerated() {
        let id = CodexAppServerRequestID.integer(Int64(402 + offset))
        let response = await CodexDesktopInitialMCPRouter
            .responseIncludingFileSystem(
                to: initialMCPRequest(
                    id: id,
                    method: "thread/memoryMode/set",
                    params: params
                ),
                state: initialMCPState(),
                allowedFileSystemRoots: [],
                threadLister: probe
            )
        #expect(
            response == initialMCPError(
                id: id,
                code: -32602,
                message: "Invalid params for thread/memoryMode/set"
            )
        )
    }
    #expect(probe.callCount == 1)
}

private enum DesktopGitDiffProbeError: Error {
    case forced
}

private actor DesktopGitDiffProbe: CodexDesktopGitDiffing {
    private let response: CodexGitDiffToRemoteResponse
    private let shouldFail: Bool
    private var requestID: CodexAppServerRequestID?
    private var params: CodexGitDiffToRemoteParams?
    private var callCount = 0

    init(
        response: CodexGitDiffToRemoteResponse,
        shouldFail: Bool = false
    ) {
        self.response = response
        self.shouldFail = shouldFail
    }

    func gitDiffToRemote(
        id: CodexAppServerRequestID,
        params: CodexGitDiffToRemoteParams
    ) async throws -> CodexGitDiffToRemoteResponse {
        requestID = id
        self.params = params
        callCount += 1
        if shouldFail {
            throw DesktopGitDiffProbeError.forced
        }
        return response
    }

    func snapshot() -> (
        CodexAppServerRequestID?,
        CodexGitDiffToRemoteParams?,
        Int
    ) {
        (requestID, params, callCount)
    }
}

@Test
@MainActor
func desktopInitialMCPRouterServesStrictGitDiffToRemote() async throws {
    let fileManager = FileManager.default
    let fixtureRoot = fileManager.temporaryDirectory
        .appendingPathComponent(
            "codexpad-gitdiff-\(UUID().uuidString)",
            isDirectory: true
        )
    let allowedRoot = fixtureRoot.appendingPathComponent(
        "allowed",
        isDirectory: true
    )
    let repository = allowedRoot.appendingPathComponent(
        "repository",
        isDirectory: true
    )
    let outside = fixtureRoot.appendingPathComponent(
        "outside",
        isDirectory: true
    )
    try fileManager.createDirectory(
        at: repository,
        withIntermediateDirectories: true
    )
    try fileManager.createDirectory(
        at: outside,
        withIntermediateDirectories: true
    )
    let regularFile = allowedRoot.appendingPathComponent("file.txt")
    try Data("not a directory".utf8).write(to: regularFile)
    let symlink = allowedRoot.appendingPathComponent("escaped-link")
    try fileManager.createSymbolicLink(
        at: symlink,
        withDestinationURL: outside
    )
    defer {
        try? fileManager.removeItem(at: fixtureRoot)
    }

    let sha = "fedcba9876543210fedcba9876543210fedcba98"
    let diff = """
    diff --git a/file.txt b/file.txt
    --- a/file.txt
    +++ b/file.txt
    """
    let probe = DesktopGitDiffProbe(
        response: CodexGitDiffToRemoteResponse(
            sha: sha,
            diff: diff
        )
    )
    let validID = CodexAppServerRequestID.integer(501)
    let valid = await CodexDesktopInitialMCPRouter
        .responseIncludingFileSystem(
            to: initialMCPRequest(
                id: validID,
                method: "gitDiffToRemote",
                params: .object([
                    "cwd": .string(repository.path)
                ])
            ),
            state: initialMCPState(),
            allowedFileSystemRoots: [allowedRoot.path],
            gitDiffer: probe
        )
    #expect(
        valid == .mcpResponse(
            hostID: "desktop-host-1",
            message: .object([
                "id": .integer(501),
                "result": .object([
                    "sha": .string(sha),
                    "diff": .string(diff),
                ]),
            ]),
            metadata: [:]
        )
    )
    let validSnapshot = await probe.snapshot()
    #expect(validSnapshot.0 == validID)
    #expect(
        validSnapshot.1
            == CodexGitDiffToRemoteParams(
                cwd: repository.resolvingSymlinksInPath().path
            )
    )
    #expect(validSnapshot.2 == 1)

    let invalidParams: [CodexJSONValue?] = [
        nil,
        .object([:]),
        .object([
            "cwd": .string(repository.path),
            "extra": .bool(true),
        ]),
        .object(["cwd": .string("")]),
        .object(["cwd": .string("relative/repository")]),
        .object(["cwd": .integer(1)]),
        .object(["cwd": .string(regularFile.path)]),
        .object([
            "cwd": .string(
                allowedRoot
                    .appendingPathComponent("missing")
                    .path
            )
        ]),
        .object(["cwd": .string(outside.path)]),
        .object(["cwd": .string(symlink.path)]),
    ]
    for (offset, params) in invalidParams.enumerated() {
        let id = CodexAppServerRequestID.integer(
            Int64(502 + offset)
        )
        let response = await CodexDesktopInitialMCPRouter
            .responseIncludingFileSystem(
                to: initialMCPRequest(
                    id: id,
                    method: "gitDiffToRemote",
                    params: params
                ),
                state: initialMCPState(),
                allowedFileSystemRoots: [allowedRoot.path],
                gitDiffer: probe
            )
        #expect(
            response == initialMCPError(
                id: id,
                code: -32602,
                message: "Invalid params for gitDiffToRemote"
            )
        )
    }
    let finalSnapshot = await probe.snapshot()
    #expect(finalSnapshot.2 == 1)
}

@Test
@MainActor
func desktopInitialMCPRouterMapsGitDiffToRemoteFailure() async throws {
    let fileManager = FileManager.default
    let repository = fileManager.temporaryDirectory
        .appendingPathComponent(
            "codexpad-gitdiff-failure-\(UUID().uuidString)",
            isDirectory: true
        )
    try fileManager.createDirectory(
        at: repository,
        withIntermediateDirectories: true
    )
    defer {
        try? fileManager.removeItem(at: repository)
    }
    let probe = DesktopGitDiffProbe(
        response: CodexGitDiffToRemoteResponse(
            sha: "",
            diff: ""
        ),
        shouldFail: true
    )
    let id = CodexAppServerRequestID.integer(520)
    let response = await CodexDesktopInitialMCPRouter
        .responseIncludingFileSystem(
            to: initialMCPRequest(
                id: id,
                method: "gitDiffToRemote",
                params: .object([
                    "cwd": .string(repository.path)
                ])
            ),
            state: initialMCPState(),
            allowedFileSystemRoots: [repository.path],
            gitDiffer: probe
        )

    #expect(
        response == initialMCPError(
            id: id,
            code: -32600,
            message:
                "failed to compute git diff to remote for cwd: "
                + String(
                    reflecting:
                        repository.resolvingSymlinksInPath().path
                )
        )
    )
}

@MainActor
private final class DesktopThreadSectionMutationStub:
    CodexDesktopThreadSessionListing,
    CodexDesktopThreadSectionListing,
    CodexDesktopThreadSectionMutating
{
    var listParams: CodexThreadSectionListParams?
    var createParams: CodexThreadSectionCreateParams?
    var updateParams: CodexThreadSectionUpdateParams?
    var deleteParams: CodexThreadSectionDeleteParams?
    var moveParams: CodexThreadSectionMoveParams?

    func listThreads(
        id _: CodexAppServerRequestID,
        params _: CodexThreadListParams
    ) throws -> CodexThreadPage {
        throw CodexSessionStoreError.invalidReply
    }

    func createThreadSection(
        id _: CodexAppServerRequestID,
        params: CodexThreadSectionCreateParams
    ) throws -> CodexThreadSectionCreateResult {
        createParams = params
        return CodexThreadSectionCreateResult(
            section: CodexThreadSection(id: "section-1", name: params.name)
        )
    }

    func listThreadSections(
        id _: CodexAppServerRequestID,
        params: CodexThreadSectionListParams
    ) throws -> CodexThreadSectionPage {
        listParams = params
        return CodexThreadSectionPage(
            data: [
                CodexThreadSection(id: "section-1", name: "Pinned work")
            ],
            nextCursor: "section-cursor-2"
        )
    }

    func updateThreadSection(
        id _: CodexAppServerRequestID,
        params: CodexThreadSectionUpdateParams
    ) throws -> CodexThreadSectionUpdateResult {
        updateParams = params
        return CodexThreadSectionUpdateResult(
            section: CodexThreadSection(
                id: params.sectionID,
                name: params.name
            )
        )
    }

    func deleteThreadSection(
        id _: CodexAppServerRequestID,
        params: CodexThreadSectionDeleteParams
    ) throws {
        deleteParams = params
    }

    func moveThreadSection(
        id _: CodexAppServerRequestID,
        params: CodexThreadSectionMoveParams
    ) throws {
        moveParams = params
    }
}

@MainActor
private final class DesktopThreadQueueStub: CodexDesktopThreadSessionListing, CodexDesktopThreadQueueManaging {
    let threadID = CodexStoredThreadID("thread-queue-1")
    let queuedID = "queued-1"
    var calls: [String] = []
    var receivedStart: CodexThreadQueueStartParams?

    func listThreads(id _: CodexAppServerRequestID, params _: CodexThreadListParams) throws -> CodexThreadPage {
        throw CodexSessionStoreError.invalidReply
    }

    private func submission(text: String = "queued") -> CodexQueuedSubmission {
        CodexQueuedSubmission(
            id: queuedID,
            input: [.text(text: text, textElements: [])],
            clientUserMessageID: "client-1"
        )
    }

    func addQueuedSubmission(id _: CodexAppServerRequestID, params _: CodexThreadQueueAddParams) throws -> CodexThreadQueueAddResponse {
        calls.append("add")
        return CodexThreadQueueAddResponse(queuedSubmission: submission())
    }

    func listQueuedSubmissions(id _: CodexAppServerRequestID, params _: CodexThreadQueueListParams) throws -> CodexThreadQueueListResponse {
        calls.append("list")
        return CodexThreadQueueListResponse(data: [submission()], nextCursor: nil)
    }

    func updateQueuedSubmission(id _: CodexAppServerRequestID, params _: CodexThreadQueueUpdateParams) throws -> CodexThreadQueueUpdateResponse {
        calls.append("update")
        return CodexThreadQueueUpdateResponse(queuedSubmission: submission(text: "updated"))
    }

    func deleteQueuedSubmission(id _: CodexAppServerRequestID, params _: CodexThreadQueueDeleteParams) throws -> CodexThreadQueueDeleteResponse {
        calls.append("delete")
        return CodexThreadQueueDeleteResponse(deleted: true)
    }

    func reorderQueuedSubmissions(id _: CodexAppServerRequestID, params _: CodexThreadQueueReorderParams) throws {
        calls.append("reorder")
    }

    func startQueuedSubmission(id _: CodexAppServerRequestID, params: CodexThreadQueueStartParams) throws -> CodexThreadQueueStartResponse {
        calls.append("start")
        receivedStart = params
        return CodexThreadQueueStartResponse(
            turn: CodexStoredTurn(id: "turn-1", items: [], status: .inProgress)
        )
    }
}

@Test
@MainActor
func desktopInitialMCPRouterCompletesReleasedThreadQueueOperations() async {
    let stub = DesktopThreadQueueStub()
    let threadID = stub.threadID.rawValue
    let calls: [(String, CodexJSONValue, CodexJSONValue)] = [
        (
            "thread/queue/add",
            .object([
                "threadId": .string(threadID),
                "input": .array([.object(["type": .string("text"), "text": .string("queued"), "text_elements": .array([])])]),
                "clientUserMessageId": .string("client-1"),
            ]),
            .object(["queuedSubmission": .object(["id": .string("queued-1"), "input": .array([.object(["type": .string("text"), "text": .string("queued"), "text_elements": .array([])])]), "clientUserMessageId": .string("client-1")])])
        ),
        (
            "thread/queue/list",
            .object(["threadId": .string(threadID), "cursor": .null, "limit": .integer(20)]),
            .object(["data": .array([.object(["id": .string("queued-1"), "input": .array([.object(["type": .string("text"), "text": .string("queued"), "text_elements": .array([])])]), "clientUserMessageId": .string("client-1")])])])
        ),
        (
            "thread/queue/update",
            .object(["threadId": .string(threadID), "queuedSubmissionId": .string("queued-1"), "input": .array([.object(["type": .string("text"), "text": .string("updated"), "text_elements": .array([])])])]),
            .object(["queuedSubmission": .object(["id": .string("queued-1"), "input": .array([.object(["type": .string("text"), "text": .string("updated"), "text_elements": .array([])])]), "clientUserMessageId": .string("client-1")])])
        ),
        (
            "thread/queue/delete",
            .object(["threadId": .string(threadID), "queuedSubmissionId": .string("queued-1")]),
            .object(["deleted": .bool(true)])
        ),
        (
            "thread/queue/reorder",
            .object(["threadId": .string(threadID), "queuedSubmissionIds": .array([.string("queued-1")])]),
            .object([:])
        ),
        (
            "thread/queue/start",
            .object(["threadId": .string(threadID), "queuedSubmissionId": .string("queued-1")]),
            .object(["turn": .object(["id": .string("turn-1"), "items": .array([]), "itemsView": .string("full"), "status": .string("inProgress")])])
        ),
    ]

    for (offset, call) in calls.enumerated() {
        let response = await CodexDesktopInitialMCPRouter.responseIncludingFileSystem(
            to: initialMCPRequest(
                id: .integer(Int64(900 + offset)),
                method: call.0,
                params: call.1
            ),
            state: initialMCPState(),
            allowedFileSystemRoots: [],
            threadLister: stub
        )
        #expect(response == .mcpResponse(
            hostID: "desktop-host-1",
            message: .object(["id": .integer(Int64(900 + offset)), "result": call.2]),
            metadata: [:]
        ))
    }

    #expect(stub.calls == ["add", "list", "update", "delete", "reorder", "start"])
    #expect(stub.receivedStart?.queuedSubmissionID == .value("queued-1"))
}

@Test
@MainActor
func desktopInitialMCPRouterCompletesReleasedThreadSectionMutations()
    async
{
    let stub = DesktopThreadSectionMutationStub()
    let calls: [(String, CodexJSONValue, CodexJSONValue)] = [
        (
            "threadSection/list",
            .object([
                "cursor": .string("section-cursor-1"),
                "limit": .integer(20),
            ]),
            .object([
                "data": .array([
                    .object([
                        "id": .string("section-1"),
                        "name": .string("Pinned work"),
                    ])
                ]),
                "nextCursor": .string("section-cursor-2"),
            ])
        ),
        (
            "threadSection/create",
            .object(["name": .string("Pinned work")]),
            .object([
                "section": .object([
                    "id": .string("section-1"),
                    "name": .string("Pinned work"),
                ])
            ])
        ),
        (
            "threadSection/update",
            .object([
                "sectionId": .string("section-1"),
                "name": .string("Today"),
            ]),
            .object([
                "section": .object([
                    "id": .string("section-1"),
                    "name": .string("Today"),
                ])
            ])
        ),
        (
            "threadSection/delete",
            .object(["sectionId": .string("section-1")]),
            .object([:])
        ),
        (
            "thread/section/move",
            .object([
                "threadId": .string("thread-1"),
                "sectionId": .null,
                "beforeThreadId": .null,
            ]),
            .object([:])
        ),
    ]

    for (offset, call) in calls.enumerated() {
        let id = CodexAppServerRequestID.integer(Int64(800 + offset))
        let response = await CodexDesktopInitialMCPRouter
            .responseIncludingFileSystem(
                to: initialMCPRequest(
                    id: id,
                    method: call.0,
                    params: call.1
                ),
                state: initialMCPState(),
                allowedFileSystemRoots: [],
                threadLister: stub
            )
        #expect(
            response == .mcpResponse(
                hostID: "desktop-host-1",
                message: .object([
                    "id": .integer(Int64(800 + offset)),
                    "result": call.2,
                ]),
                metadata: [:]
            )
        )
    }

    #expect(stub.createParams?.name == "Pinned work")
    #expect(stub.listParams?.cursor == .value("section-cursor-1"))
    #expect(stub.listParams?.limit == .value(20))
    #expect(stub.updateParams?.sectionID == "section-1")
    #expect(stub.updateParams?.name == "Today")
    #expect(stub.deleteParams?.sectionID == "section-1")
    #expect(stub.moveParams?.threadID == CodexStoredThreadID("thread-1"))
    #expect(stub.moveParams?.sectionID == .null)
    #expect(stub.moveParams?.beforeThreadID == .null)
}
