import Foundation
import Testing

@testable import CodexPadApplication
@testable import CodexPadDomain
@testable import CodexPadProtocolBridge

@Test
func desktopSurfaceRequiresResourceDocumentBridgeAndHomeDataGates() throws {
    var machine = CodexDesktopSurfaceStateMachine()

    #expect(machine.state == .verifyingResources)
    try machine.apply(.resourcesVerified)
    #expect(machine.state == .loadingDocument)
    try machine.apply(.documentLoaded)
    #expect(machine.state == .awaitingBridgeReady)
    try machine.apply(.bridgeReady)
    #expect(machine.state == .awaitingHomeData)
    try machine.apply(.homeDataLoaded)
    #expect(machine.state == .ready)
}

@Test
func desktopSurfaceDoesNotTreatRendererReadyAsProductReady() throws {
    var machine = CodexDesktopSurfaceStateMachine()

    try machine.apply(.resourcesVerified)
    try machine.apply(.documentLoaded)
    try machine.apply(.bridgeReady)

    #expect(machine.state == .awaitingHomeData)
    #expect(machine.isBridgeReady)
    #expect(!machine.isSurfaceReady)
}

@Test
func desktopSurfaceRejectsOutOfOrderSuccessSignals() throws {
    var machine = CodexDesktopSurfaceStateMachine()

    #expect(
        throws: CodexDesktopSurfaceTransitionError.invalidTransition(
            from: .verifyingResources,
            event: .bridgeReady
        )
    ) {
        try machine.apply(.bridgeReady)
    }
    #expect(machine.state == .verifyingResources)
}

@Test
func desktopSurfaceFailuresRemainExplicitAndRecoverThroughVerification() throws {
    var machine = CodexDesktopSurfaceStateMachine()

    try machine.apply(.resourcesFailed("tree hash mismatch"))
    #expect(machine.state == .failed(reason: "tree hash mismatch"))
    #expect(!machine.isSurfaceReady)

    try machine.apply(.retry)
    #expect(machine.state == .verifyingResources)

    try machine.apply(.resourcesVerified)
    try machine.apply(.documentLoaded)
    try machine.apply(.webContentProcessTerminated)
    #expect(
        machine.state
            == .failed(reason: "desktop web content process terminated")
    )
}

@Test
func releasedStartupGateAcceptsTheObservedAppHostSequence() {
    var gate = CodexDesktopReleasedStartupGate()

    gate.observeDocumentLoaded()
    #expect(!gate.canMarkBridgeReady)
    #expect(!gate.canMarkStartupReady)

    gate.observeAppHostServicesResolved()
    #expect(gate.canMarkBridgeReady)
    #expect(gate.canMarkStartupReady)

    for method in ["codex-home", "get-settings", "os-info"] {
        gate.observeSuccessfulFetch(method)
    }
    for method in ["account/read", "config/read", "thread/list"] {
        gate.observeSuccessfulMCP(method)
    }

    #expect(!gate.canMarkHomeDataReady)
    gate.observeInteractiveSurfaceCommitted()
    #expect(gate.canMarkHomeDataReady)
    #expect(
        !CodexDesktopReleasedStartupGate
            .requiredFetchMethods
            .contains("locale-info")
    )
}

@Test
func releasedStartupGateWaitsForAccountAndConfig() {
    var gate = CodexDesktopReleasedStartupGate()

    gate.observeDocumentLoaded()
    gate.observeAppHostServicesResolved()
    for method in ["codex-home", "get-settings", "os-info"] {
        gate.observeSuccessfulFetch(method)
    }
    gate.observeSuccessfulMCP("config/read")

    #expect(!gate.canMarkHomeDataReady)

    gate.observeSuccessfulMCP("account/read")

    #expect(!gate.canMarkHomeDataReady)
    gate.observeInteractiveSurfaceCommitted()
    #expect(gate.canMarkHomeDataReady)
}

@Test
func releasedStartupGateAcceptsLatestPersistedHomeWithoutEagerThreadList() {
    var gate = CodexDesktopReleasedStartupGate()

    gate.observeDocumentLoaded()
    gate.observeAppHostServicesResolved()
    for method in ["get-settings", "codex-home", "os-info"] {
        gate.observeSuccessfulFetch(method)
    }
    for method in ["config/read", "account/read"] {
        gate.observeSuccessfulMCP(method)
    }

    // The released home can restore from persisted state without eagerly
    // issuing `thread/list`, but protocol completion alone must not promote
    // a splash-only renderer to Ready.
    #expect(!gate.canMarkHomeDataReady)

    gate.observeInteractiveSurfaceCommitted()
    #expect(gate.canMarkHomeDataReady)
}

@Test
func releasedStartupGateRejectsSplashAfterProtocolCompletion() {
    var gate = CodexDesktopReleasedStartupGate()

    gate.observeDocumentLoaded()
    gate.observeAppHostServicesResolved()
    for method in ["codex-home", "get-settings", "os-info"] {
        gate.observeSuccessfulFetch(method)
    }
    for method in ["account/read", "config/read"] {
        gate.observeSuccessfulMCP(method)
    }

    #expect(gate.canMarkBridgeReady)
    #expect(!gate.canMarkHomeDataReady)
}

@Test
func releasedStartupGateAcceptsARealBridgeMessageWithoutLegacyReady() {
    var gate = CodexDesktopReleasedStartupGate()

    gate.observeBridgeMessage()
    #expect(!gate.canMarkBridgeReady)

    gate.observeDocumentLoaded()
    #expect(gate.canMarkBridgeReady)
}

@Test
@MainActor
func desktopSceneRuntimeFactoryCreatesAnIndependentControllerPerWindow() {
#if os(iOS)
    let accountStore = CodexAccountStore()
    let sessionStore = CodexSessionStore(
        initialTransportProblem: "scene factory test"
    )
    let factory = CodexDesktopSceneRuntimeFactory(
        accountStore: accountStore,
        sessionStore: sessionStore,
        officialProvider: nil,
        coreClient: nil,
        gitDiffer: nil
    )

    let first = factory.makeRuntime()
    let second = factory.makeRuntime()

    #expect(first !== second)
    #expect(first.controller !== second.controller)
#endif
}

@Test
@MainActor
func desktopSceneRuntimeFactoryPreservesAPIKeyProviderBaseURL() {
    let credentials = CodexOfficialCredentials(
        accessToken: "TEST_API_KEY",
        accountID: nil,
        baseURL: CodexOfficialCredentials.openAIAPIBaseURL,
        authMethod: .apiKey
    )

    let configuration =
        CodexDesktopSceneRuntimeProviderConfigurationFactory
            .make(
                credentials: credentials,
                model: "fixture-model",
                reasoningEffort: .medium,
                collaborationInstructions: nil,
                workspaceTools: false,
                requestPermissionsTool: true,
                mcpResourceTools: false,
                planMode: false,
                toolSearchSources: []
            )

    #expect(configuration.accessToken == "TEST_API_KEY")
    #expect(configuration.accountID == nil)
    #expect(
        configuration.baseURL
            == CodexOfficialCredentials.openAIAPIBaseURL
    )
    #expect(!configuration.workspaceTools)
    #expect(!configuration.requestPermissionsTool)
}

@Test
@MainActor
func providerConfigurationDerivesRouteFromAuthMethodNotStaleBaseURL() {
    let oauth = CodexOfficialCredentials(
        accessToken: "TEST_OAUTH_TOKEN",
        accountID: "account-1",
        baseURL: CodexOfficialCredentials.openAIAPIBaseURL,
        authMethod: .chatGPT
    )
    let oauthConfiguration =
        CodexDesktopSceneRuntimeProviderConfigurationFactory
            .make(
                credentials: oauth,
                model: "fixture-model",
                reasoningEffort: .medium,
                collaborationInstructions: nil,
                workspaceTools: false,
                requestPermissionsTool: false,
                mcpResourceTools: false,
                planMode: false,
                toolSearchSources: []
            )

    #expect(oauthConfiguration.baseURL == nil)

    let apiKey = CodexOfficialCredentials(
        accessToken: "TEST_API_KEY",
        accountID: "stale-account-id",
        baseURL: nil,
        authMethod: .apiKey
    )
    let apiKeyConfiguration =
        CodexDesktopSceneRuntimeProviderConfigurationFactory
            .make(
                credentials: apiKey,
                model: "fixture-model",
                reasoningEffort: .medium,
                collaborationInstructions: nil,
                workspaceTools: false,
                requestPermissionsTool: false,
                mcpResourceTools: false,
                planMode: false,
                toolSearchSources: []
            )

    #expect(
        apiKeyConfiguration.baseURL
            == CodexOfficialCredentials.openAIAPIBaseURL
    )
    #expect(apiKeyConfiguration.accountID == nil)
}

@Test
@MainActor
func desktopSceneRuntimeFactoryResolvesCollaborationModePrecedenceExactly() {
    let stored = CodexCollaborationMode(
        mode: .plan,
        settings: CodexCollaborationModeSettings(
            model: "stored-model",
            reasoningEffort: "stored-effort",
            developerInstructions: "stored"
        )
    )
    let explicit = CodexCollaborationMode(
        mode: .default,
        settings: CodexCollaborationModeSettings(
            model: "explicit-model",
            reasoningEffort: "explicit-effort",
            developerInstructions: "explicit"
        )
    )
    let fallback = CodexCollaborationMode(
        mode: .default,
        settings: CodexCollaborationModeSettings(
            model: "fallback-model",
            reasoningEffort: "fallback-effort",
            developerInstructions: nil
        )
    )

    #expect(
        CodexCollaborationModeWireResolver.resolve(
            collaborationMode: .value(explicit),
            model: .value("ignored-model"),
            effort: .value("ignored-effort"),
            stored: stored,
            fallback: fallback
        ) == explicit
    )
    #expect(
        CodexCollaborationModeWireResolver.resolve(
            collaborationMode: .null,
            model: .value("updated-model"),
            effort: .value("updated-effort"),
            stored: stored,
            fallback: fallback
        ) == CodexCollaborationMode(
            mode: .plan,
            settings: CodexCollaborationModeSettings(
                model: "updated-model",
                reasoningEffort: "updated-effort",
                developerInstructions: "stored"
            )
        )
    )
    #expect(
        CodexCollaborationModeWireResolver.resolve(
            collaborationMode: .omitted,
            model: .omitted,
            effort: .omitted,
            stored: nil,
            fallback: fallback
        ) == fallback
    )
}

@Test
func releasedStartupGateResetClearsNavigationSpecificEvidence() {
    var gate = CodexDesktopReleasedStartupGate()
    gate.observeDocumentLoaded()
    gate.observeBridgeMessage()
    gate.observeAppHostServicesResolved()
    gate.observeSuccessfulFetch("codex-home")
    gate.observeSuccessfulMCP("account/read")

    gate.reset()

    #expect(gate == CodexDesktopReleasedStartupGate())
    #expect(!gate.canMarkBridgeReady)
    #expect(!gate.canMarkHomeDataReady)
}

@Test
func turnStartFailureDiagnosticPreservesSafeRootCauseShape() {
    let params = CodexTurnStartParams(
        threadID: CodexStoredThreadID(
            rawValue: "00000000-0000-0000-0000-000000000002"
        ),
        input: [.text(text: "private user text", textElements: [])],
        cwd: .value("/private/workspace"),
        sandboxPolicy: .value(
            .workspaceWrite(
                writableRoots: [],
                networkAccess: false,
                excludeTmpdirEnvVar: false,
                excludeSlashTmp: false
            )
        ),
        model: .value("gpt-test"),
        effort: .value("high"),
        permissions: .value(":workspace")
    )

    let diagnostic = CodexDesktopTurnStartFailureDiagnostic.make(
        problem: "invalidArgument",
        params: params,
        rawParams: .object([
            "threadId": .string(
                "00000000-0000-0000-0000-000000000002"
            ),
            "input": .array([
                .object([
                    "type": .string("text"),
                    "text": .string("private user text"),
                    "text_elements": .array([]),
                    "newInputField": .string("private input value"),
                ]),
            ]),
            "attachments": .array([]),
            "cwd": .string("/private/workspace"),
            "sandboxPolicy": .object([
                "type": .string("workspaceWrite"),
            ]),
            "newDesktopField": .string("private desktop value"),
        ])
    )

    #expect(
        diagnostic
            == "turn/start transport invalidArgument thread=uuid inputCount=1 "
                + "cwd=value model=value effort=value permissions=value "
                + "sandbox=value conflict=permissions+sandboxPolicy "
                + "unknownTurnKeys=newDesktopField "
                + "unknownInputKeys=newInputField "
                + "wireTypes=attachments:array,cwd:string,input:array,"
                + "newDesktopField:string,sandboxPolicy:object,"
                + "threadId:string"
    )
    #expect(!diagnostic.contains("private user text"))
    #expect(!diagnostic.contains("/private/workspace"))
    #expect(!diagnostic.contains("gpt-test"))
    #expect(!diagnostic.contains("private input value"))
    #expect(!diagnostic.contains("private desktop value"))
}

@Test
func turnStartFailureDiagnosticClassifiesAttachmentContainerWithoutLeakingValues() {
    let params = CodexTurnStartParams(
        threadID: CodexStoredThreadID(
            rawValue: "00000000-0000-0000-0000-000000000002"
        ),
        input: [.text(text: "private user text", textElements: [])]
    )

    let diagnostic = CodexDesktopTurnStartFailureDiagnostic.make(
        problem: "invalidArgument",
        params: params,
        rawParams: .object([
            "threadId": .string(
                "00000000-0000-0000-0000-000000000002"
            ),
            "input": .array([]),
            "attachments": .object([
                "private": .string("private attachment value"),
            ]),
        ])
    )

    #expect(diagnostic.contains("wireTypes=attachments:object,input:array,threadId:string"))
    #expect(!diagnostic.contains("private attachment value"))
}

@Test
func turnStartFailureDiagnosticUsesDedicatedPersistentAnchor() throws {
    let suiteName = "CodexDesktopTurnStartDiagnosticStoreTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    CodexDesktopTurnStartDiagnosticStore.persist(
        "turn/start transport invalidArgument",
        to: defaults
    )

    #expect(
        defaults.string(
            forKey: "codex.desktop.last-turn-start-diagnostic"
        ) == "turn/start transport invalidArgument"
    )
}
