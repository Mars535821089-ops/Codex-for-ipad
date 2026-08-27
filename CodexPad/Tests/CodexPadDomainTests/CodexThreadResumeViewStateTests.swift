import CodexPadApplication
import CodexPadDomain
import CodexPadProtocolBridge
import Foundation
import Testing

@Test
func threadResumeBuildsACompleteModelOverrideBoundary() {
    let params = CodexThreadResumeRequestFactory.make(
        threadID: CodexStoredThreadID("thread/raw-ID"),
        model: "selected-model",
        modelProvider: "persisted-provider",
        reasoningEffort: "high",
        cwd: "/persisted/cwd",
        approvalPolicy: .onRequest,
        approvalsReviewer: .user,
        sandbox: .workspaceWrite
    )

    #expect(params.model == .value("selected-model"))
    #expect(params.modelProvider == .value("persisted-provider"))
    #expect(
        params.config
            == .value(["model_reasoning_effort": .string("high")])
    )
}

@Test
func threadResumePreservesCallerPreparedRuntimeOverrides() throws {
    let rawID = CodexStoredThreadID(" 任务/thread-Ω/../原样 ")
    let params = explicitResumeParams(
        threadID: rawID,
        model: "selected-model",
        modelProvider: "persisted-provider",
        cwd: "/persisted/项目"
    )
    var state = CodexThreadResumeViewState()
    state.selectThread(rawID)

    let possibleRequest = state.beginResume(params)
    let request = try #require(possibleRequest)

    #expect(request.threadID == rawID)
    #expect(request.params == params)
    #expect(request.params.model == .value("selected-model"))
    #expect(request.params.modelProvider == .value("persisted-provider"))
    #expect(request.params.cwd == .value("/persisted/项目"))
    #expect(request.params.approvalPolicy == .value(.onRequest))
    #expect(request.params.sandbox == .value(.workspaceWrite))
    #expect(request.params.serviceTier == .omitted)
    #expect(request.params.approvalsReviewer == .value(.user))
    #expect(request.params.config == .omitted)
    #expect(request.params.baseInstructions == .omitted)
    #expect(request.params.developerInstructions == .omitted)
    #expect(request.params.personality == .omitted)
    #expect(state.phase == .resuming)
}

@Test
func threadResumeRejectsParamsWhoseRawIDDiffersFromSelection() {
    let selectedID = CodexStoredThreadID("thread/raw-ID")
    let differentRawID = CodexStoredThreadID("thread/raw-id")
    var state = CodexThreadResumeViewState()
    state.selectThread(selectedID)

    let request = state.beginResume(
        explicitResumeParams(threadID: differentRawID)
    )

    #expect(request == nil)
    #expect(state.selectedThreadID == selectedID)
    #expect(state.phase == .idle)
    #expect(state.resumeResult == nil)
    #expect(state.errorMessage == nil)
}

@Test
func threadResumeBeginsWithTheSelectedRawOpaqueID() throws {
    let rawID = CodexStoredThreadID(" 任务/thread-Ω/../原样 ")
    var state = CodexThreadResumeViewState()
    state.selectThread(rawID)
    let params = explicitResumeParams(threadID: rawID)

    let possibleRequest = state.beginResume(params)
    let request = try #require(possibleRequest)

    #expect(request.threadID == rawID)
    #expect(request.threadID.rawValue == " 任务/thread-Ω/../原样 ")
    #expect(request.params == params)
    #expect(state.selectedThreadID == rawID)
    #expect(state.phase == .resuming)
}

@Test
func threadResumePublishesTheReturnedThreadAndRuntimeMetadata() throws {
    let rawID = CodexStoredThreadID("thread/returned-source")
    let returnedThread = resumeStoredThread(
        id: rawID,
        name: "Returned thread title",
        preview: "Returned server preview",
        modelProvider: "thread-provider",
        cwd: "/returned/thread/cwd"
    )
    let result = CodexThreadResumeResult(
        thread: returnedThread,
        model: "returned-model",
        modelProvider: "returned-runtime-provider",
        serviceTier: "returned-tier",
        cwd: "/returned/runtime/cwd",
        instructionSources: ["/returned/runtime/cwd/AGENTS.md"],
        approvalPolicy: .onRequest,
        approvalsReviewer: .user,
        sandbox: .readOnly(networkAccess: false),
        reasoningEffort: "returned-effort"
    )
    var state = CodexThreadResumeViewState()
    state.selectThread(rawID)
    let possibleRequest = state.beginResume(
        explicitResumeParams(threadID: rawID)
    )
    let request = try #require(possibleRequest)

    state.receiveResumeResult(result, for: request)

    #expect(state.phase == .resumed)
    #expect(state.resumeResult == result)
    #expect(state.resumedThread?.storedThread == returnedThread)
    #expect(state.resumedThread?.title == "Returned thread title")
    #expect(state.resumeResult?.model == "returned-model")
    #expect(
        state.resumeResult?.modelProvider
            == "returned-runtime-provider"
    )
    #expect(state.resumeResult?.cwd == "/returned/runtime/cwd")
}

@Test
func failedThreadResumePublishesErrorAndRetriesTheRawOpaqueID() throws {
    let rawID = CodexStoredThreadID("任务/失败后重试/原始-id")
    var state = CodexThreadResumeViewState()
    state.selectThread(rawID)
    let params = explicitResumeParams(threadID: rawID)
    let possibleFirstRequest = state.beginResume(params)
    let firstRequest = try #require(possibleFirstRequest)

    state.failResume("transport closed", for: firstRequest)

    #expect(state.phase == .failed)
    #expect(state.errorMessage == "transport closed")
    #expect(state.resumeResult == nil)

    let possibleRetryRequest = state.beginResume(params)
    let retryRequest = try #require(possibleRetryRequest)

    #expect(retryRequest.threadID == rawID)
    #expect(retryRequest.params == params)
    #expect(state.phase == .resuming)
    #expect(state.errorMessage == nil)
}

@Test
func clearingSelectionInvalidatesAnInFlightThreadResume() throws {
    let rawID = CodexStoredThreadID("thread/in-flight-before-close")
    var state = CodexThreadResumeViewState()
    state.selectThread(rawID)
    let possibleRequest = state.beginResume(
        explicitResumeParams(threadID: rawID)
    )
    let request = try #require(possibleRequest)

    state.clearSelection()
    state.receiveResumeResult(
        resumeResult(id: rawID, model: "stale-model"),
        for: request
    )
    state.failResume("stale failure", for: request)

    #expect(state.selectedThreadID == nil)
    #expect(state.phase == .idle)
    #expect(state.resumeResult == nil)
    #expect(state.errorMessage == nil)
}

@Test
func changingSelectionIgnoresStaleResumeSuccessAndFailure() throws {
    let firstID = CodexStoredThreadID("thread/first")
    let secondID = CodexStoredThreadID("thread/second")
    var state = CodexThreadResumeViewState()
    state.selectThread(firstID)
    let possibleFirstRequest = state.beginResume(
        explicitResumeParams(threadID: firstID)
    )
    let firstRequest = try #require(possibleFirstRequest)

    state.selectThread(secondID)
    let possibleSecondRequest = state.beginResume(
        explicitResumeParams(threadID: secondID)
    )
    let secondRequest = try #require(possibleSecondRequest)
    state.receiveResumeResult(
        resumeResult(id: firstID, model: "stale-model"),
        for: firstRequest
    )
    state.failResume("stale failure", for: firstRequest)

    #expect(state.selectedThreadID == secondID)
    #expect(state.phase == .resuming)
    #expect(state.resumeResult == nil)
    #expect(state.errorMessage == nil)

    let secondResult = resumeResult(
        id: secondID,
        model: "current-model"
    )
    state.receiveResumeResult(secondResult, for: secondRequest)

    #expect(state.phase == .resumed)
    #expect(state.resumeResult == secondResult)
}

@Test
func resumedThreadReconcilesAnExactCanonicalReadWithoutReplacingRuntimeState()
    throws
{
    let rawID = CodexStoredThreadID("thread/精确-raw-ID")
    var state = CodexThreadResumeViewState()
    state.selectThread(rawID)
    let possibleRequest = state.beginResume(
        explicitResumeParams(threadID: rawID)
    )
    let request = try #require(possibleRequest)
    let originalResult = CodexThreadResumeResult(
        thread: resumeStoredThread(
            id: rawID,
            name: "Resume snapshot",
            preview: "Resume preview",
            modelProvider: "thread-provider",
            cwd: "/resume/thread/cwd"
        ),
        model: "runtime-model",
        modelProvider: "runtime-provider",
        serviceTier: "runtime-tier",
        cwd: "/runtime/cwd",
        instructionSources: ["/runtime/cwd/AGENTS.md"],
        approvalPolicy: .onRequest,
        approvalsReviewer: .user,
        sandbox: .readOnly(networkAccess: false),
        reasoningEffort: "runtime-effort"
    )
    state.receiveResumeResult(originalResult, for: request)
    let canonicalThread = resumeStoredThread(
        id: rawID,
        name: "Canonical read title",
        preview: "Canonical read preview",
        modelProvider: "canonical-thread-provider",
        cwd: "/canonical/thread/cwd"
    )

    let didReconcile = state.reconcileResumedThread(
        with: CodexStoredThreadPresentation(thread: canonicalThread)
    )

    #expect(didReconcile)
    #expect(state.phase == .resumed)
    #expect(state.selectedThreadID == rawID)
    #expect(state.resumeResult?.thread == canonicalThread)
    #expect(state.resumedThread?.title == "Canonical read title")
    #expect(state.resumeResult?.model == originalResult.model)
    #expect(
        state.resumeResult?.modelProvider
            == originalResult.modelProvider
    )
    #expect(state.resumeResult?.serviceTier == originalResult.serviceTier)
    #expect(state.resumeResult?.cwd == originalResult.cwd)
    #expect(
        state.resumeResult?.instructionSources
            == originalResult.instructionSources
    )
    #expect(
        state.resumeResult?.approvalPolicy
            == originalResult.approvalPolicy
    )
    #expect(
        state.resumeResult?.approvalsReviewer
            == originalResult.approvalsReviewer
    )
    #expect(state.resumeResult?.sandbox == originalResult.sandbox)
    #expect(
        state.resumeResult?.reasoningEffort
            == originalResult.reasoningEffort
    )
    #expect(state.errorMessage == nil)
}

@Test
func resumedThreadIgnoresCanonicalReadForADifferentRawID() throws {
    let selectedID = CodexStoredThreadID("thread/selected-RAW")
    var state = CodexThreadResumeViewState()
    state.selectThread(selectedID)
    let possibleRequest = state.beginResume(
        explicitResumeParams(threadID: selectedID)
    )
    let request = try #require(possibleRequest)
    let originalResult = resumeResult(
        id: selectedID,
        model: "runtime-model"
    )
    state.receiveResumeResult(originalResult, for: request)

    let didReconcile = state.reconcileResumedThread(
        with: CodexStoredThreadPresentation(
            thread: resumeStoredThread(
                id: CodexStoredThreadID("thread/selected-raw"),
                name: "Different raw ID",
                preview: "Must be ignored",
                modelProvider: "different-provider",
                cwd: "/different/cwd"
            )
        )
    )

    #expect(!didReconcile)
    #expect(state.phase == .resumed)
    #expect(state.resumeResult == originalResult)
}

@Test
func nonResumedThreadIgnoresCanonicalReadForTheSelectedRawID() throws {
    let rawID = CodexStoredThreadID("thread/still-resuming")
    var state = CodexThreadResumeViewState()
    state.selectThread(rawID)
    let possibleRequest = state.beginResume(
        explicitResumeParams(threadID: rawID)
    )
    _ = try #require(possibleRequest)
    let snapshot = state

    let didReconcile = state.reconcileResumedThread(
        with: CodexStoredThreadPresentation(
            thread: resumeStoredThread(
                id: rawID,
                name: "Canonical while resuming",
                preview: "Must be ignored",
                modelProvider: "canonical-provider",
                cwd: "/canonical/cwd"
            )
        )
    )

    #expect(!didReconcile)
    #expect(state == snapshot)
    #expect(state.phase == .resuming)
}

@Test
func resumedThreadAppliesTheAuthoritativeSettingsNotification() throws {
    let rawID = CodexStoredThreadID("thread/settings/raw")
    var state = CodexThreadResumeViewState()
    state.selectThread(rawID)
    let possibleRequest = state.beginResume(
        explicitResumeParams(threadID: rawID)
    )
    let request = try #require(possibleRequest)
    let original = resumeResult(id: rawID, model: "resume-model")
    state.receiveResumeResult(original, for: request)
    let settings = completeThreadSettings(
        model: "updated-model",
        modelProvider: "updated-provider",
        effort: "future-super-deep-v9"
    )

    let applied = state.reconcileThreadSettings(
        CodexThreadSettingsUpdatedNotification(
            threadID: rawID,
            threadSettings: settings
        )
    )

    #expect(applied)
    #expect(state.resumeResult?.model == "updated-model")
    #expect(state.resumeResult?.modelProvider == "updated-provider")
    #expect(state.resumeResult?.serviceTier == "priority")
    #expect(state.resumeResult?.cwd == "/updated/cwd")
    #expect(state.resumeResult?.approvalPolicy == .never)
    #expect(state.resumeResult?.approvalsReviewer == .autoReview)
    #expect(
        state.resumeResult?.sandbox
            == .externalSandbox(networkAccess: .enabled)
    )
    #expect(
        state.resumeResult?.reasoningEffort == "future-super-deep-v9"
    )
    #expect(
        state.resumeResult?.instructionSources
            == original.instructionSources
    )
    #expect(state.resumeResult?.thread == original.thread)
}

@Test
func resumedTurnRuntimeUsesEveryUpdatedNextTurnOverride() throws {
    let rawID = CodexStoredThreadID("thread/settings/runtime")
    let original = resumeResult(id: rawID, model: "resume-model")
    var settings = completeThreadSettings(
        model: "updated-model",
        modelProvider: "updated-provider",
        effort: "future-super-deep-v9"
    )
    settings.collaborationMode = .init(
        mode: .plan,
        settings: settings.collaborationMode.settings
    )
    let runtime = CodexResumedThreadRuntimeSettings(
        resumeResult: original,
        authoritativeSettings: settings
    )
    let params = runtime.makeTurnStartParams(
        threadID: rawID,
        input: [.text(text: "Continue", textElements: [])],
        clientUserMessageID: "client-settings-1"
    )
    let request = CodexAppServerTurnRequest.start(
        id: .integer(91),
        params: params
    )

    #expect(runtime.model == "updated-model")
    #expect(runtime.modelProvider == "updated-provider")
    #expect(runtime.cwd == "/updated/cwd")
    #expect(runtime.approvalPolicy == .never)
    #expect(runtime.approvalsReviewer == .autoReview)
    #expect(
        runtime.sandboxPolicy
            == .externalSandbox(networkAccess: .enabled)
    )
    #expect(runtime.effort == "future-super-deep-v9")
    #expect(runtime.collaborationMode?.mode == .plan)
    #expect(runtime.multiAgentMode == .explicitRequestOnly)
    #expect(runtime.proposedPlanStreamingEnabled)
    #expect(params.serviceTier == .value("priority"))
    #expect(params.effort == .value("future-super-deep-v9"))
    #expect(params.summary == .value(.detailed))
    #expect(params.collaborationMode == .value(settings.collaborationMode))
    #expect(params.multiAgentMode == .value(.explicitRequestOnly))
    #expect(params.personality == .value(.pragmatic))
    #expect(
        try request.encodedData()
            == Data(
                #"{"id":91,"method":"turn/start","params":{"approvalPolicy":"never","approvalsReviewer":"auto_review","clientUserMessageId":"client-settings-1","collaborationMode":{"mode":"plan","settings":{"developer_instructions":"Keep continuity.","model":"updated-model","reasoning_effort":"future-super-deep-v9"}},"cwd":"/updated/cwd","effort":"future-super-deep-v9","input":[{"text":"Continue","text_elements":[],"type":"text"}],"model":"updated-model","multiAgentMode":"explicitRequestOnly","personality":"pragmatic","sandboxPolicy":{"networkAccess":"enabled","type":"externalSandbox"},"serviceTier":"priority","summary":"detailed","threadId":"thread/settings/runtime"}}"#
                    .utf8
            )
    )
}

@Test
func resumedTurnRuntimeFallsBackToResumeSnapshotBeforeNotification() {
    let rawID = CodexStoredThreadID("thread/settings/fallback")
    let original = resumeResult(id: rawID, model: "resume-model")
    let runtime = CodexResumedThreadRuntimeSettings(
        resumeResult: original,
        authoritativeSettings: nil
    )
    let params = runtime.makeTurnStartParams(
        threadID: rawID,
        input: [],
        clientUserMessageID: nil
    )

    #expect(runtime.model == original.model)
    #expect(runtime.modelProvider == original.modelProvider)
    #expect(runtime.cwd == original.cwd)
    #expect(runtime.collaborationMode == nil)
    #expect(runtime.multiAgentMode == nil)
    #expect(!runtime.proposedPlanStreamingEnabled)
    #expect(params.serviceTier == .omitted)
    #expect(params.effort == .omitted)
    #expect(params.summary == .omitted)
    #expect(params.collaborationMode == .omitted)
    #expect(params.multiAgentMode == .omitted)
    #expect(params.personality == .omitted)
}

@Test
func resumedTurnRuntimeCanUseValidatedProviderSlugWithoutRewritingSnapshot() {
    let rawID = CodexStoredThreadID("thread/settings/stable-catalog-id")
    let original = resumeResult(id: rawID, model: "stable-catalog-id")
    let runtime = CodexResumedThreadRuntimeSettings(
        resumeResult: original,
        authoritativeSettings: nil
    )

    let params = runtime.makeTurnStartParams(
        threadID: rawID,
        input: [],
        clientUserMessageID: nil,
        modelOverride: "provider-runtime-slug"
    )

    #expect(runtime.model == "stable-catalog-id")
    #expect(params.model == .value("provider-runtime-slug"))
}

@Test
func resumedTurnRuntimePreservesAuthoritativeExplicitNulls() {
    let rawID = CodexStoredThreadID("thread/settings/authoritative-nulls")
    let original = resumeResult(id: rawID, model: "resume-model")
    var settings = completeThreadSettings(
        model: "updated-model",
        modelProvider: "updated-provider",
        effort: nil
    )
    settings.serviceTier = nil
    settings.summary = nil
    settings.personality = nil
    let runtime = CodexResumedThreadRuntimeSettings(
        resumeResult: original,
        authoritativeSettings: settings
    )
    let params = runtime.makeTurnStartParams(
        threadID: rawID,
        input: [],
        clientUserMessageID: nil
    )

    #expect(params.serviceTier == .null)
    #expect(params.effort == .null)
    #expect(params.summary == .null)
    #expect(params.personality == .null)
}

private func explicitResumeParams(
    threadID: CodexStoredThreadID,
    model: String = "selected-model",
    modelProvider: String = "persisted-provider",
    cwd: String = "/persisted/cwd"
) -> CodexThreadResumeParams {
    CodexThreadResumeParams(
        threadID: threadID,
        model: .value(model),
        modelProvider: .value(modelProvider),
        cwd: .value(cwd),
        approvalPolicy: .value(.onRequest),
        approvalsReviewer: .value(.user),
        sandbox: .value(.workspaceWrite)
    )
}

private func resumeResult(
    id: CodexStoredThreadID,
    model: String
) -> CodexThreadResumeResult {
    CodexThreadResumeResult(
        thread: resumeStoredThread(
            id: id,
            name: "Returned \(id.rawValue)",
            preview: "Returned preview",
            modelProvider: "thread-provider",
            cwd: "/returned/thread/cwd"
        ),
        model: model,
        modelProvider: "runtime-provider",
        serviceTier: nil,
        cwd: "/returned/runtime/cwd",
        instructionSources: [],
        approvalPolicy: .onRequest,
        approvalsReviewer: .user,
        sandbox: .readOnly(networkAccess: false),
        reasoningEffort: nil
    )
}

private func completeThreadSettings(
    model: String,
    modelProvider: String,
    effort: String?
) -> CodexAppServerThreadSettings {
    CodexAppServerThreadSettings(
        cwd: "/updated/cwd",
        approvalPolicy: .never,
        approvalsReviewer: .autoReview,
        sandboxPolicy: .externalSandbox(networkAccess: .enabled),
        activePermissionProfile: .init(
            id: "profile-updated",
            extends: ":workspace"
        ),
        model: model,
        modelProvider: modelProvider,
        serviceTier: "priority",
        effort: effort,
        summary: .detailed,
        collaborationMode: .init(
            mode: .default,
            settings: .init(
                model: model,
                reasoningEffort: effort,
                developerInstructions: "Keep continuity."
            )
        ),
        multiAgentMode: .explicitRequestOnly,
        personality: .pragmatic
    )
}

private func resumeStoredThread(
    id: CodexStoredThreadID,
    name: String?,
    preview: String,
    modelProvider: String,
    cwd: String
) -> CodexStoredThread {
    CodexStoredThread(
        id: id,
        sessionID: "returned-session",
        preview: preview,
        ephemeral: false,
        modelProvider: modelProvider,
        createdAt: 10,
        updatedAt: 20,
        recencyAt: 21,
        status: .idle,
        path: "/returned/rollout.jsonl",
        cwd: cwd,
        cliVersion: "returned-cli",
        source: .named("cli"),
        threadSource: "returned-source",
        name: name,
        turns: []
    )
}
