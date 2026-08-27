import CodexPadApplication
import CodexPadDomain
import CodexPadProtocolBridge
import Testing

private let sourceA = CodexModelCatalogSource(
    modelProvider: "provider-a",
    accountIdentity: "account-a"
)
private let sourceB = CodexModelCatalogSource(
    modelProvider: "provider-b",
    accountIdentity: "account-b"
)
private let sourceC = CodexModelCatalogSource(
    modelProvider: "provider-c",
    accountIdentity: nil
)

@Test
func modelCatalogLoadsAllOpaquePagesBeforePublishingWithCapabilities() throws {
    var state = CodexModelCatalogViewState()
    let load = state.beginLoad(source: sourceA, pageLimit: 2)

    #expect(state.phase == .loading)
    #expect(state.models.isEmpty)
    #expect(state.source == nil)
    #expect(state.requestedSource == sourceA)
    #expect(load.firstPage.params.cursor == .omitted)
    #expect(load.firstPage.params.limit == .value(2))
    #expect(load.firstPage.params.includeHidden == .value(false))

    let secondRequestResult = state.receive(
        .init(
            data: [
                model(
                    id: "secondary",
                    effort: "focused",
                    isDefault: false
                ),
            ],
            nextCursor: "opaque-next"
        ),
        for: load.firstPage
    )
    let secondRequest = try #require(secondRequestResult)
    #expect(secondRequest.params.cursor == .value("opaque-next"))
    #expect(state.models.isEmpty)

    let noThirdRequest = state.receive(
        .init(
            data: [
                model(
                    id: "server-default",
                    effort: "max",
                    isDefault: true
                ),
            ],
            nextCursor: nil
        ),
        for: secondRequest
    )
    #expect(noThirdRequest == nil)
    #expect(state.models.isEmpty)

    state.receive(
        .init(
            namespaceTools: true,
            imageGeneration: false,
            webSearch: true
        ),
        for: load.capabilities
    )

    #expect(state.phase == .loaded)
    #expect(state.models.map(\.id) == ["secondary", "server-default"])
    #expect(state.defaultModel?.id == "server-default")
    #expect(state.capabilities?.namespaceTools == true)
    #expect(state.capabilities?.imageGeneration == false)
    #expect(state.capabilities?.webSearch == true)
    #expect(state.source == sourceA)
    #expect(state.requestedSource == sourceA)
    #expect(state.lastGood?.source == sourceA)
    #expect(state.isStale == false)
    #expect(state.canRunModelOperations)
}

@Test
func modelCatalogGuardsRepeatedOpaqueCursorsAndKeepsLastGoodSnapshot() throws {
    var state = CodexModelCatalogViewState()
    loadSuccessfully(
        &state,
        source: sourceA,
        models: [model(id: "last-good", isDefault: true)]
    )
    let lastGood = try #require(state.lastGood)
    let reload = state.beginLoad(source: sourceB, pageLimit: 1)

    let nextResult = state.receive(
        .init(
            data: [model(id: "incomplete", isDefault: true)],
            nextCursor: "repeat"
        ),
        for: reload.firstPage
    )
    let next = try #require(nextResult)
    let repeated = state.receive(
        .init(
            data: [model(id: "duplicate-page", isDefault: false)],
            nextCursor: "repeat"
        ),
        for: next
    )

    #expect(repeated == nil)
    #expect(state.phase == .failed)
    #expect(state.problem == .repeatedCursor("repeat"))
    #expect(state.models.map(\.id) == ["last-good"])
    #expect(state.source == sourceA)
    #expect(state.requestedSource == sourceB)
    #expect(state.lastGood == lastGood)
    #expect(state.isStale)
}

@Test
func modelCatalogIgnoresOldProviderAndAccountRepliesAfterSourceChanges() {
    var state = CodexModelCatalogViewState()
    let loadA = state.beginLoad(source: sourceA)
    let loadB = state.beginLoad(source: sourceB)

    state.receive(
        .init(
            namespaceTools: true,
            imageGeneration: true,
            webSearch: true
        ),
        for: loadA.capabilities
    )
    _ = state.receive(
        .init(
            data: [model(id: "stale-a", isDefault: true)],
            nextCursor: nil
        ),
        for: loadA.firstPage
    )

    #expect(state.phase == .loading)
    #expect(state.models.isEmpty)
    #expect(state.requestedSource == sourceB)

    state.receive(
        .init(
            namespaceTools: false,
            imageGeneration: true,
            webSearch: false
        ),
        for: loadB.capabilities
    )
    _ = state.receive(
        .init(
            data: [model(id: "current-b", isDefault: true)],
            nextCursor: nil
        ),
        for: loadB.firstPage
    )

    #expect(state.phase == .loaded)
    #expect(state.models.map(\.id) == ["current-b"])
    #expect(state.source == sourceB)
    #expect(state.capabilities?.namespaceTools == false)
}

@Test
func modelCatalogFailureMarksLastGoodStaleWithoutPublishingPartialData() {
    var state = CodexModelCatalogViewState()
    loadSuccessfully(
        &state,
        source: sourceA,
        models: [model(id: "kept", isDefault: true)]
    )
    let reload = state.beginLoad(source: sourceC)

    _ = state.receive(
        .init(
            data: [model(id: "partial", isDefault: true)],
            nextCursor: nil
        ),
        for: reload.firstPage
    )
    state.fail(.transport("connection closed"), for: reload.capabilities)

    #expect(state.phase == .failed)
    #expect(state.problem == .transport("connection closed"))
    #expect(state.models.map(\.id) == ["kept"])
    #expect(state.source == sourceA)
    #expect(state.requestedSource == sourceC)
    #expect(state.isStale)
}

@Test
func emptyServerCatalogPublishesNoPlaceholdersAndDisablesModelOperations() {
    var state = CodexModelCatalogViewState()
    let load = state.beginLoad(source: sourceA)

    state.receive(
        .init(
            namespaceTools: false,
            imageGeneration: false,
            webSearch: false
        ),
        for: load.capabilities
    )
    _ = state.receive(
        .init(data: [], nextCursor: nil),
        for: load.firstPage
    )

    #expect(state.phase == .loaded)
    #expect(state.models.isEmpty)
    #expect(state.defaultModel == nil)
    #expect(state.model(id: "invented-placeholder") == nil)
    #expect(state.canRunModelOperations == false)
    #expect(state.capabilityGate(.namespaceTools) == false)
    #expect(state.capabilityGate(.imageGeneration) == false)
    #expect(state.capabilityGate(.webSearch) == false)
}

@Test
func incoherentServerDefaultEffortDisablesModelOperations() {
    var state = CodexModelCatalogViewState()
    let incoherent = CodexModelConfiguration(
        id: "incoherent-default",
        model: "provider-incoherent-default",
        displayName: "Incoherent",
        description: "Default effort is absent from the supported options.",
        hidden: false,
        reasoningEffortOptions: [
            .init(reasoningEffort: .low, description: "Low"),
        ],
        defaultReasoningEffort: .high,
        isDefault: true
    )
    loadSuccessfully(&state, source: sourceA, models: [incoherent])

    #expect(state.phase == .loaded)
    #expect(state.defaultModel?.id == "incoherent-default")
    #expect(state.selection(modelID: nil, reasoningEffortRaw: nil).isAvailable == false)
    #expect(state.canRunModelOperations == false)
}

@Test
func unknownPersistedModelRemainsSelectedButUnavailable() {
    var state = CodexModelCatalogViewState()
    loadSuccessfully(
        &state,
        source: sourceA,
        models: [model(id: "server-default", isDefault: true)]
    )

    let persisted = state.selection(
        modelID: "retired-persisted-model",
        reasoningEffortRaw: "retired-effort"
    )
    let fresh = state.selection(
        modelID: nil,
        reasoningEffortRaw: nil
    )

    #expect(persisted.modelID == "retired-persisted-model")
    #expect(persisted.reasoningEffortRaw == "retired-effort")
    #expect(persisted.model == nil)
    #expect(persisted.isAvailable == false)
    #expect(fresh.modelID == "provider-server-default")
    #expect(fresh.reasoningEffortRaw == "medium")
    #expect(fresh.model?.id == "server-default")
    #expect(fresh.isAvailable)

    let stableCatalogID = state.selection(
        modelID: "server-default",
        reasoningEffortRaw: nil
    )
    #expect(stableCatalogID.modelID == "server-default")
    #expect(stableCatalogID.model?.model == "provider-server-default")
    #expect(stableCatalogID.providerModelID == "provider-server-default")
    #expect(stableCatalogID.isAvailable)
    #expect(persisted.providerModelID == nil)
}

@Test
func agentSettingsDraftDoesNotRewriteFutureTaskDefaultsWhileEditing() {
    let defaults = CodexAgentSettingsDraft(
        approvalPolicyRaw: "on-request",
        sandboxModeRaw: "workspace-write",
        modelID: "future-default-model",
        reasoningEffortRaw: "medium"
    )
    var editor = defaults

    editor.approvalPolicyRaw = "never"
    editor.sandboxModeRaw = "read-only"
    editor.modelID = "selected-thread-model"
    editor.reasoningEffortRaw = "high"

    #expect(defaults.approvalPolicyRaw == "on-request")
    #expect(defaults.sandboxModeRaw == "workspace-write")
    #expect(defaults.modelID == "future-default-model")
    #expect(defaults.reasoningEffortRaw == "medium")
    #expect(editor.modelID == "selected-thread-model")
}

@Test
func modelCatalogUsesServerDescriptionsAndCapabilityFlagsWithoutReordering() {
    var state = CodexModelCatalogViewState()
    let configured = CodexModelConfiguration(
        id: "described",
        model: "provider-described",
        displayName: "Described",
        description: "Model description",
        hidden: false,
        reasoningEffortOptions: [
            .init(
                reasoningEffort: CodexReasoningEffort(rawValue: "focused")!,
                description: "Focus on correctness"
            ),
            .init(
                reasoningEffort: .low,
                description: "Respond faster"
            ),
        ],
        defaultReasoningEffort: CodexReasoningEffort(rawValue: "focused")!,
        isDefault: true
    )
    let load = state.beginLoad(source: sourceA)
    state.receive(
        .init(
            namespaceTools: true,
            imageGeneration: false,
            webSearch: true
        ),
        for: load.capabilities
    )
    _ = state.receive(
        .init(data: [configured], nextCursor: nil),
        for: load.firstPage
    )

    #expect(
        state.defaultModel?.reasoningEffortOptions.map(\.description) == [
            "Focus on correctness",
            "Respond faster",
        ]
    )
    #expect(
        state.defaultModel?.supportedReasoningEfforts.map(\.rawValue) == [
            "focused",
            "low",
        ]
    )
    #expect(state.capabilityGate(.namespaceTools))
    #expect(state.capabilityGate(.imageGeneration) == false)
    #expect(state.capabilityGate(.webSearch))
}

private func loadSuccessfully(
    _ state: inout CodexModelCatalogViewState,
    source: CodexModelCatalogSource,
    models: [CodexModelConfiguration]
) {
    let load = state.beginLoad(source: source)
    state.receive(
        .init(
            namespaceTools: true,
            imageGeneration: true,
            webSearch: true
        ),
        for: load.capabilities
    )
    _ = state.receive(
        .init(data: models, nextCursor: nil),
        for: load.firstPage
    )
}

private func model(
    id: String,
    effort: String = "medium",
    isDefault: Bool
) -> CodexModelConfiguration {
    let effort = CodexReasoningEffort(rawValue: effort)!
    return CodexModelConfiguration(
        id: id,
        model: "provider-\(id)",
        displayName: id,
        description: "Description for \(id)",
        hidden: false,
        reasoningEffortOptions: [
            .init(
                reasoningEffort: effort,
                description: "Server description for \(effort.rawValue)"
            ),
        ],
        defaultReasoningEffort: effort,
        isDefault: isDefault
    )
}
