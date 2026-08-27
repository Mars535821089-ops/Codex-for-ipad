import CodexPadApplication
import CodexPadDomain
import Testing

@Test
func threadDirectoryDefaultsToActiveRecencyDescendingList() {
    var state = CodexThreadDirectoryViewState()

    let request = state.beginInitialLoad()

    #expect(state.criteria.archiveScope == .active)
    #expect(state.criteria.sortKey == .recencyAt)
    #expect(state.criteria.sortDirection == .descending)
    #expect(state.criteria.limit == 25)
    #expect(state.loadPhase == .loadingInitial)
    #expect(
        request.query == .list(
            CodexThreadListParams(
                cursor: .omitted,
                limit: .value(25),
                sortKey: .value(.recencyAt),
                sortDirection: .value(.descending),
                sourceKinds: .value([.cli, .vscode, .appServer]),
                archived: .value(false)
            )
        )
    )
}

@Test
func threadDirectoryTreatsWhitespaceOnlySearchAsAList() {
    var state = CodexThreadDirectoryViewState()
    state.setSearchText(" \n\t ")

    let request = state.beginInitialLoad()

    #expect(
        request.query == .list(
            CodexThreadListParams(
                cursor: .omitted,
                limit: .value(25),
                sortKey: .value(.recencyAt),
                sortDirection: .value(.descending),
                sourceKinds: .value([.cli, .vscode, .appServer]),
                archived: .value(false)
            )
        )
    )
}

@Test
func threadDirectoryUsesTrimmedNonemptySearchAndExplicitArchiveFlag() {
    var state = CodexThreadDirectoryViewState()
    state.setSearchText("  protocol match  ")
    state.setArchiveScope(.archived)

    let request = state.beginInitialLoad()

    #expect(
        request.query == .search(
            CodexThreadSearchParams(
                cursor: .omitted,
                limit: .value(25),
                sortKey: .value(.recencyAt),
                sortDirection: .value(.descending),
                sourceKinds: .value([.cli, .vscode, .appServer]),
                archived: .value(true),
                searchTerm: "protocol match"
            )
        )
    )
}

@Test
func threadDirectoryIncludesDesktopAndIPadCreatedThreadSources() {
    var listState = CodexThreadDirectoryViewState()
    let listRequest = listState.beginInitialLoad()

    #expect(
        listRequest.query == .list(
            CodexThreadListParams(
                cursor: .omitted,
                limit: .value(25),
                sortKey: .value(.recencyAt),
                sortDirection: .value(.descending),
                sourceKinds: .value([.cli, .vscode, .appServer]),
                archived: .value(false)
            )
        )
    )

    var searchState = CodexThreadDirectoryViewState()
    searchState.setSearchText("ipad created")
    let searchRequest = searchState.beginInitialLoad()

    #expect(
        searchRequest.query == .search(
            CodexThreadSearchParams(
                cursor: .omitted,
                limit: .value(25),
                sortKey: .value(.recencyAt),
                sortDirection: .value(.descending),
                sourceKinds: .value([.cli, .vscode, .appServer]),
                archived: .value(false),
                searchTerm: "ipad created"
            )
        )
    )
}

@Test
func threadDirectoryPaginatesWithNextCursorAndKeepsFirstServerOrder() throws {
    var state = CodexThreadDirectoryViewState()
    let firstRequest = state.beginInitialLoad()
    state.receiveListPage(
        .init(
            data: [
                storedThread(id: "thread/A"),
                storedThread(id: "thread/B"),
            ],
            nextCursor: "cursor-2",
            backwardsCursor: nil
        ),
        for: firstRequest
    )

    let possibleNextRequest = state.beginNextPageLoad()
    let nextRequest = try #require(possibleNextRequest)
    #expect(
        nextRequest.query == .list(
            CodexThreadListParams(
                cursor: .value("cursor-2"),
                limit: .value(25),
                sortKey: .value(.recencyAt),
                sortDirection: .value(.descending),
                sourceKinds: .value([.cli, .vscode, .appServer]),
                archived: .value(false)
            )
        )
    )

    state.receiveListPage(
        .init(
            data: [
                storedThread(id: "thread/B"),
                storedThread(id: "thread/C"),
                storedThread(id: "thread/C"),
                storedThread(id: "thread/D"),
            ],
            nextCursor: nil,
            backwardsCursor: "cursor-1"
        ),
        for: nextRequest
    )

    #expect(
        state.rows.map(\.id.rawValue)
            == ["thread/A", "thread/B", "thread/C", "thread/D"]
    )
    #expect(state.nextCursor == nil)
    #expect(state.loadPhase == .loaded)
    #expect(state.loadErrorMessage == nil)
}

@Test
func threadDirectoryCriteriaChangeClearsDirectoryAndSelectionState() {
    var state = CodexThreadDirectoryViewState()
    let request = state.beginInitialLoad()
    state.receiveListPage(
        .init(
            data: [storedThread(id: "opaque-thread-id")],
            nextCursor: "next-page",
            backwardsCursor: nil
        ),
        for: request
    )
    _ = state.selectThread(CodexStoredThreadID("opaque-thread-id"))

    state.setArchiveScope(.archived)

    #expect(state.rows.isEmpty)
    #expect(state.nextCursor == nil)
    #expect(state.selectedThreadID == nil)
    #expect(state.selectedThread == nil)
    #expect(state.loadPhase == .idle)
    #expect(state.loadErrorMessage == nil)
    #expect(state.selectionPhase == .idle)
    #expect(state.selectionErrorMessage == nil)
}

@Test
func threadDirectoryIgnoresReadResponseFromAnOlderSelection() {
    var state = CodexThreadDirectoryViewState()
    let first = state.selectThread(CodexStoredThreadID("thread:first"))
    let second = state.selectThread(CodexStoredThreadID("thread:second"))

    #expect(
        first.params
            == CodexThreadReadParams(
                threadID: CodexStoredThreadID("thread:first"),
                includeTurns: true
            )
    )
    #expect(second.params.includeTurns == true)

    state.receiveReadResult(
        .init(thread: storedThread(id: "thread:first")),
        for: first
    )

    #expect(state.selectedThreadID?.rawValue == "thread:second")
    #expect(state.selectedThread == nil)
    #expect(state.selectionPhase == .loading)

    state.receiveReadResult(
        .init(thread: storedThread(id: "thread:second")),
        for: second
    )

    #expect(state.selectedThreadID?.rawValue == "thread:second")
    #expect(state.selectedThread?.id.rawValue == "thread:second")
    #expect(state.selectionPhase == .loaded)
}

@Test
func threadDirectoryPublishesExplicitLoadAndSelectionErrors() {
    var state = CodexThreadDirectoryViewState()
    let load = state.beginInitialLoad()
    state.failLoad("directory offline", for: load)

    #expect(state.loadPhase == .failed)
    #expect(state.loadErrorMessage == "directory offline")

    let read = state.selectThread(CodexStoredThreadID("thread:error"))
    state.failSelection("read failed", for: read)

    #expect(state.selectionPhase == .failed)
    #expect(state.selectionErrorMessage == "read failed")
}

@Test
func storedThreadPresentationPreservesOpaqueIDAndUsesSearchSnippet() {
    let thread = storedThread(
        id: "thread:not-a-uuid",
        name: "Real persisted name",
        preview: "thread preview"
    )
    let hit = CodexThreadSearchHit(
        thread: thread,
        snippet: "server-provided snippet"
    )

    let listPresentation = CodexStoredThreadPresentation(thread: thread)
    let searchPresentation = CodexStoredThreadPresentation(searchHit: hit)

    #expect(listPresentation.id.rawValue == "thread:not-a-uuid")
    #expect(listPresentation.title == "Real persisted name")
    #expect(listPresentation.summary == "thread preview")
    #expect(searchPresentation.id.rawValue == "thread:not-a-uuid")
    #expect(searchPresentation.summary == "server-provided snippet")
}

@Test
func storedThreadPresentationUsesTrimmedNonemptyFallbacks() {
    let named = CodexStoredThreadPresentation(
        thread: storedThread(
            id: "thread:named",
            name: "  Real persisted name  ",
            preview: "  real preview  ",
            cwd: "  /real/named-workspace  "
        )
    )
    let previewed = CodexStoredThreadPresentation(
        thread: storedThread(
            id: "thread:previewed",
            name: " \n\t ",
            preview: "  preview fallback  ",
            cwd: "  /real/preview-workspace  "
        ),
        searchSnippet: " \t "
    )
    let cwdFallback = CodexStoredThreadPresentation(
        thread: storedThread(
            id: "thread:cwd-fallback",
            name: "",
            preview: " \n ",
            cwd: "  /real/cwd-fallback  "
        )
    )
    let idFallback = CodexStoredThreadPresentation(
        thread: storedThread(
            id: "thread:raw-id-fallback",
            name: " ",
            preview: "\t",
            cwd: "\n"
        )
    )
    let searchHit = CodexStoredThreadPresentation(
        searchHit: CodexThreadSearchHit(
            thread: storedThread(
                id: "thread:search",
                name: nil,
                preview: "preview behind snippet"
            ),
            snippet: "  server snippet  "
        )
    )

    #expect(named.title == "Real persisted name")
    #expect(named.summary == "real preview")
    #expect(previewed.title == "preview fallback")
    #expect(previewed.summary == "preview fallback")
    #expect(cwdFallback.title == "thread:cwd-fallback")
    #expect(cwdFallback.summary == "/real/cwd-fallback")
    #expect(idFallback.title == "thread:raw-id-fallback")
    #expect(idFallback.summary == "thread:raw-id-fallback")
    #expect(searchHit.summary == "server snippet")
}

@Test
func storedUserMessagePresentationKeepsClientIDOutOfVisibleText() {
    let presentation = CodexStoredThreadItemPresentation(
        item: .userMessage(
            id: "user-message",
            clientID: "client-id-is-metadata",
            content: [
                .text(text: "visible user text", textElements: []),
            ]
        ),
        turnID: "turn-real"
    )

    #expect(presentation.textFragments == ["visible user text"])
    #expect(!presentation.textFragments.contains("client-id-is-metadata"))
}

@Test
func storedThreadItemProjectionUsesRealFieldsForAllEighteenCases() {
    let fixtures: [(CodexStoredThreadItem, [String])] = [
        (
            .userMessage(
                id: "user",
                clientID: "client-real",
                content: [
                    .text(text: "real user text", textElements: []),
                    .localImage(detail: .original, path: "/real/user.png"),
                ]
            ),
            ["real user text", "/real/user.png"]
        ),
        (
            .hookPrompt(
                id: "hook",
                fragments: [.string("real hook fragment")]
            ),
            ["real hook fragment"]
        ),
        (
            .agentMessage(
                id: "agent",
                text: "real agent text",
                phase: .finalAnswer,
                memoryCitation: nil
            ),
            ["real agent text"]
        ),
        (.plan(id: "plan", text: "real plan text"), ["real plan text"]),
        (
            .reasoning(
                id: "reasoning",
                summary: ["real reasoning summary"],
                content: ["real reasoning content"]
            ),
            ["real reasoning summary", "real reasoning content"]
        ),
        (
            .commandExecution(
                id: "command",
                command: "swift test --filter RealCase",
                cwd: "/real/workspace",
                processID: "process-real",
                source: .agent,
                status: .completed,
                commandActions: [.string("real command action")],
                aggregatedOutput: "real command output",
                exitCode: 0,
                durationMs: 125
            ),
            [
                "swift test --filter RealCase",
                "/real/workspace",
                "real command output",
            ]
        ),
        (
            .fileChange(
                id: "file",
                changes: [
                    .object([
                        "path": .string("/real/Changed.swift"),
                        "change": .string("+real change"),
                    ]),
                ],
                status: .completed
            ),
            ["/real/Changed.swift", "+real change"]
        ),
        (
            .mcpToolCall(
                id: "mcp",
                server: "real-server",
                tool: "real-tool",
                status: .completed,
                arguments: .object(["path": .string("/real/mcp-input")]),
                appContext: nil,
                mcpAppResourceURI: "resource://real",
                pluginID: "plugin-real",
                result: .string("real mcp result"),
                error: nil,
                durationMs: 45
            ),
            ["real-server", "real-tool", "/real/mcp-input", "real mcp result"]
        ),
        (
            .dynamicToolCall(
                id: "dynamic",
                namespace: "real-namespace",
                tool: "real-dynamic-tool",
                arguments: .string("real dynamic arguments"),
                status: .completed,
                contentItems: [.string("real dynamic content")],
                success: true,
                durationMs: 46
            ),
            [
                "real-namespace",
                "real-dynamic-tool",
                "real dynamic arguments",
                "real dynamic content",
            ]
        ),
        (
            .collabAgentToolCall(
                id: "collab",
                tool: .spawnAgent,
                status: .completed,
                senderThreadID: "real-sender",
                receiverThreadIDs: ["real-receiver"],
                prompt: "real collab prompt",
                model: "real-model",
                reasoningEffort: "real-effort",
                agentsStates: ["real-agent": .string("real-state")]
            ),
            ["real-sender", "real-receiver", "real collab prompt", "real-state"]
        ),
        (
            .subAgentActivity(
                id: "subagent",
                kind: .interacted,
                agentThreadID: "real-agent-thread",
                agentPath: "/real/agent/path"
            ),
            ["real-agent-thread", "/real/agent/path"]
        ),
        (
            .webSearch(
                id: "web",
                query: "real web query",
                action: .string("real web action"),
                results: [.string("real web result")]
            ),
            ["real web query", "real web result"]
        ),
        (
            .imageView(id: "image-view", path: "/real/view.png"),
            ["/real/view.png"]
        ),
        (.sleep(id: "sleep", durationMs: 2_500), ["2500"]),
        (
            .imageGeneration(
                id: "image-generation",
                status: "real generation status",
                revisedPrompt: "real revised prompt",
                result: "real generation result",
                savedPath: "/real/generated.png"
            ),
            [
                "real generation status",
                "real revised prompt",
                "real generation result",
                "/real/generated.png",
            ]
        ),
        (
            .enteredReviewMode(id: "entered-review", review: "real review in"),
            ["real review in"]
        ),
        (
            .exitedReviewMode(id: "exited-review", review: "real review out"),
            ["real review out"]
        ),
        (.contextCompaction(id: "compaction"), []),
    ]

    let projections = fixtures.map {
        CodexStoredThreadItemPresentation(
            item: $0.0,
            turnID: "turn-real"
        )
    }

    #expect(
        projections.map(\.kind) == [
            .userMessage,
            .hookPrompt,
            .agentMessage,
            .plan,
            .reasoning,
            .commandExecution,
            .fileChange,
            .mcpToolCall,
            .dynamicToolCall,
            .collabAgentToolCall,
            .subAgentActivity,
            .webSearch,
            .imageView,
            .sleep,
            .imageGeneration,
            .enteredReviewMode,
            .exitedReviewMode,
            .contextCompaction,
        ]
    )

    for (index, expectedFragments) in fixtures.map(\.1).enumerated() {
        let displayed = projections[index].textFragments.joined(separator: "\n")
        for expected in expectedFragments {
            #expect(displayed.contains(expected))
        }
    }
    #expect(projections.last?.textFragments == [])
    #expect(projections.allSatisfy { $0.turnID == "turn-real" })
}

private func storedThread(
    id: String,
    name: String? = nil,
    preview: String = "real preview",
    cwd: String = "/real/workspace",
    items: [CodexStoredThreadItem] = []
) -> CodexStoredThread {
    CodexStoredThread(
        id: CodexStoredThreadID(id),
        sessionID: "session-for-\(id)",
        forkedFromID: nil,
        parentThreadID: nil,
        preview: preview,
        ephemeral: false,
        modelProvider: "real-provider",
        createdAt: 100,
        updatedAt: 200,
        recencyAt: 201,
        status: .idle,
        path: "/real/rollout/\(id)",
        cwd: cwd,
        cliVersion: "real-version",
        source: .named("cli"),
        threadSource: "real-source",
        agentNickname: nil,
        agentRole: nil,
        gitInfo: nil,
        name: name,
        turns: items.isEmpty
            ? []
            : [
                CodexStoredTurn(
                    id: "turn-real",
                    items: items,
                    itemsView: .full,
                    status: .completed,
                    error: nil,
                    startedAt: 101,
                    completedAt: 199,
                    durationMs: 98
                ),
            ]
    )
}
