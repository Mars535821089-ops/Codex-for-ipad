import Testing

@testable import CodexPadApplication

private typealias BrowsingStateValue = CodexDesktopAppHostRPC.Value
private typealias BrowsingStateRequest =
    CodexDesktopBrowsingStateAppHostService.Request

private actor BrowsingStateRequestRecorder {
    private var requests: [BrowsingStateRequest] = []
    private var responses: [BrowsingStateValue]

    init(responses: [BrowsingStateValue]) {
        self.responses = responses
    }

    func handle(_ request: BrowsingStateRequest) throws
        -> BrowsingStateValue
    {
        requests.append(request)
        guard !responses.isEmpty else {
            throw CodexDesktopBrowsingStateAppHostService.Error
                .unavailable(
                    service: request.service,
                    method: request.method
                )
        }
        return responses.removeFirst()
    }

    var recordedRequests: [BrowsingStateRequest] {
        requests
    }
}

private struct BrowsingStateCallbackCall: Equatable, Sendable {
    let callbackID: Int
    let arguments: [BrowsingStateValue]
}

private actor BrowsingStateCallbackRecorder {
    private var calls: [BrowsingStateCallbackCall] = []

    func record(
        callbackID: Int,
        arguments: [BrowsingStateValue]
    ) {
        calls.append(
            BrowsingStateCallbackCall(
                callbackID: callbackID,
                arguments: arguments
            )
        )
    }

    var recordedCalls: [BrowsingStateCallbackCall] {
        calls
    }
}

@Test
func desktopBrowsingHistoryForwardsReleasedRequestsAndResults()
    async throws
{
    let clearRequest: BrowsingStateValue = .object([
        "dataTypes": .array([
            .string("cache"),
            .string("cookies"),
            .string("downloads"),
            .string("formData"),
            .string("history"),
            .string("siteData"),
            .string("siteSettings"),
        ]),
        "timeRange": .string("lastWeek"),
    ])
    let removalEntries: BrowsingStateValue = .array([
        .object([
            "url": .string("https://example.com/one"),
            "visitTime": .integer(1_754_000_000_000),
        ]),
        .object([
            "url": .string("https://example.com/two"),
            "visitTime": .number(1_754_000_000_500.5),
        ]),
    ])
    let searchRequest: BrowsingStateValue = .object([
        "endTime": .integer(1_754_100_000_000),
        "maxResults": .integer(100),
        "offset": .integer(20),
        "startTime": .integer(0),
        "text": .string("openai"),
    ])
    let settings: BrowsingStateValue = .object([
        "dataRemovalPermitted": .object([
            "cache": .bool(true),
            "downloads": .bool(false),
            "history": .bool(true),
            "siteData": .bool(true),
        ])
    ])
    let summary: BrowsingStateValue = .object([
        "cache": .object(["sizeBytes": .integer(4_096)]),
        "downloads": .object(["count": .integer(2)]),
        "history": .object([
            "firstSite": .string("example.com"),
            "siteCount": .integer(3),
        ]),
        "siteData": .object(["siteCount": .integer(2)]),
    ])
    let historyEntries: BrowsingStateValue = .array([
        .object([
            "faviconDataURL": .null,
            "lastVisitTime": .integer(1_754_000_000_000),
            "title": .string("Example"),
            "url": .string("https://example.com/one"),
            "visitTime": .integer(1_754_000_000_000),
        ])
    ])
    let recorder = BrowsingStateRequestRecorder(
        responses: [
            .undefined,
            settings,
            summary,
            .undefined,
            historyEntries,
        ]
    )
    let service = CodexDesktopBrowsingStateAppHostService(
        provider: { request in
            try await recorder.handle(request)
        }
    )

    #expect(
        try await service.invoke(
            service: "browsingHistory",
            method: "clearBrowsingData",
            arguments: [clearRequest]
        ) == .undefined
    )
    #expect(
        try await service.invoke(
            service: "browsingHistory",
            method: "getBrowsingDataSettings",
            arguments: []
        ) == settings
    )
    #expect(
        try await service.invoke(
            service: "browsingHistory",
            method: "getBrowsingDataSummary",
            arguments: [.string("lastMonth")]
        ) == summary
    )
    #expect(
        try await service.invoke(
            service: "browsingHistory",
            method: "removeEntries",
            arguments: [removalEntries]
        ) == .undefined
    )
    #expect(
        try await service.invoke(
            service: "browsingHistory",
            method: "searchHistory",
            arguments: [searchRequest]
        ) == historyEntries
    )
    #expect(
        await recorder.recordedRequests == [
            .clearBrowsingData(clearRequest),
            .getBrowsingDataSettings,
            .getBrowsingDataSummary(timeRange: "lastMonth"),
            .removeBrowsingHistoryEntries(removalEntries),
            .searchBrowsingHistory(searchRequest),
        ]
    )
}

@Test
func desktopBrowserSidebarAutocompleteForwardsRequestAndCallback()
    async throws
{
    let startRequest: BrowsingStateValue = .object([
        "browserTabId": .string("tab-1"),
        "conversationId": .string("thread-1"),
        "editingSessionId": .string("editing-1"),
        "input": .object([
            "cursorPosition": .integer(17),
            "preventInlineAutocomplete": .bool(false),
            "text": .string("https://openai.com"),
        ]),
        "requestId": .string("request-1"),
    ])
    let stopRequest: BrowsingStateValue = .object([
        "browserTabId": .string("tab-1"),
        "conversationId": .string("thread-1"),
        "editingSessionId": .string("editing-1"),
        "reason": .string("interaction"),
        "requestId": .string("request-1"),
    ])
    let recorder = BrowsingStateRequestRecorder(
        responses: [.undefined, .undefined]
    )
    let service = CodexDesktopBrowsingStateAppHostService(
        provider: { request in
            try await recorder.handle(request)
        }
    )

    #expect(
        try await service.invoke(
            service: "browserSidebarAutocomplete",
            method: "start",
            arguments: [startRequest, .import(41)]
        ) == .undefined
    )
    #expect(
        try await service.invoke(
            service: "browserSidebarAutocomplete",
            method: "stop",
            arguments: [stopRequest]
        ) == .undefined
    )
    #expect(
        await recorder.recordedRequests == [
            .startBrowserSidebarAutocomplete(
                request: startRequest,
                callback: .import(41)
            ),
            .stopBrowserSidebarAutocomplete(stopRequest),
        ]
    )
}

@Test
func desktopBrowserSidebarAutocompleteForwardsInteractionMethods()
    async throws
{
    let identity: [String: BrowsingStateValue] = [
        "browserTabId": .string("tab-1"),
        "conversationId": .string("thread-1"),
        "editingSessionId": .string("editing-1"),
        "requestId": .string("request-1"),
    ]
    let accept = BrowsingStateValue.object(identity.merging([
        "acceptToken": .string("accept-1"),
        "disposition": .string("accept"),
    ]) { current, _ in current })
    let navigation = BrowsingStateValue.object(identity.merging([
        "destinationURL": .string("https://openai.com/docs"),
    ]) { current, _ in current })
    let deletion = BrowsingStateValue.object(identity.merging([
        "deleteToken": .string("delete-1"),
    ]) { current, _ in current })
    let recorder = BrowsingStateRequestRecorder(
        responses: [.undefined, .undefined, .undefined]
    )
    let service = CodexDesktopBrowsingStateAppHostService(
        provider: { request in
            try await recorder.handle(request)
        }
    )

    for (method, argument) in [
        ("accept", accept),
        ("recordNavigation", navigation),
        ("deleteMatch", deletion),
    ] {
        #expect(
            try await service.invoke(
                service: "browserSidebarAutocomplete",
                method: method,
                arguments: [argument]
            ) == .undefined
        )
    }

    #expect(
        await recorder.recordedRequests == [
            .acceptBrowserSidebarAutocomplete(accept),
            .recordBrowserSidebarAutocompleteNavigation(navigation),
            .deleteBrowserSidebarAutocompleteMatch(deletion),
        ]
    )
}

@Test
func desktopBrowserSidebarAutocompleteAcceptMatchesReleasedRendererShape()
    async throws
{
    let accept: BrowsingStateValue = .object([
        "acceptToken": .string("accept-1"),
        "browserTabId": .string("tab-1"),
        "conversationId": .string("thread-1"),
        "editingSessionId": .string("editing-1"),
        "requestId": .string("request-1"),
    ])
    let recorder = BrowsingStateRequestRecorder(
        responses: [.undefined]
    )
    let service = CodexDesktopBrowsingStateAppHostService(
        provider: { request in
            try await recorder.handle(request)
        }
    )

    #expect(
        try await service.invoke(
            service: "browserSidebarAutocomplete",
            method: "accept",
            arguments: [accept]
        ) == .undefined
    )
    #expect(
        await recorder.recordedRequests == [
            .acceptBrowserSidebarAutocomplete(accept)
        ]
    )
}

@Test
func desktopBrowserSidebarAutocompleteLiveProviderUsesEmbeddedPagesAndDeletesMatches()
    async throws
{
    let restoreState = CodexDesktopBrowserPageRestoreState()
    await restoreState.recordDurableSnapshot(
        .object([
            "faviconUrl": .string(
                "https://example.com/favicon.ico"
            ),
            "title": .string("Codex documentation"),
            "url": .string("https://example.com/docs"),
        ]),
        browserStorageID: "storage-1",
        browserTabID: "page-tab-1",
        conversationID: "thread-1"
    )
    let callbackRecorder = BrowsingStateCallbackRecorder()
    let service = CodexDesktopBrowsingStateAppHostService(
        pageRestoreState: restoreState,
        callbackInvoker: { callbackID, arguments in
            await callbackRecorder.record(
                callbackID: callbackID,
                arguments: arguments
            )
        }
    )
    let startRequest: BrowsingStateValue = .object([
        "browserTabId": .string("composer-tab-1"),
        "conversationId": .string("thread-1"),
        "editingSessionId": .string("editing-1"),
        "input": .object([
            "cursorPosition": .integer(5),
            "preventInlineAutocomplete": .bool(false),
            "text": .string("Codex"),
        ]),
        "requestId": .string("request-1"),
    ])

    #expect(
        try await service.invoke(
            service: "browserSidebarAutocomplete",
            method: "start",
            arguments: [startRequest, .import(41)]
        ) == .undefined
    )

    let firstCalls = await callbackRecorder.recordedCalls
    #expect(firstCalls.count == 1)
    #expect(firstCalls.first?.callbackID == 41)
    guard case let .object(update)? = firstCalls.first?.arguments.first,
          case let .object(result)? = update["result"],
          case let .array(matches)? = result["matches"],
          case let .object(match)? = matches.first,
          case let .string(deleteToken)? = match["deleteToken"]
    else {
        Issue.record("Expected a released autocomplete result with a delete token")
        return
    }
    #expect(update["browserTabId"] == .string("composer-tab-1"))
    #expect(update["conversationId"] == .string("thread-1"))
    #expect(update["editingSessionId"] == .string("editing-1"))
    #expect(update["requestId"] == .string("request-1"))
    #expect(result["done"] == .bool(true))
    #expect(match["contents"] == .string("Codex documentation"))
    #expect(match["destinationURL"] == .string("https://example.com/docs"))

    let deleteRequest: BrowsingStateValue = .object([
        "browserTabId": .string("composer-tab-1"),
        "conversationId": .string("thread-1"),
        "deleteToken": .string(deleteToken),
        "editingSessionId": .string("editing-1"),
        "requestId": .string("request-1"),
    ])
    #expect(
        try await service.invoke(
            service: "browserSidebarAutocomplete",
            method: "deleteMatch",
            arguments: [deleteRequest]
        ) == .undefined
    )

    #expect(
        try await service.invoke(
            service: "browserSidebarAutocomplete",
            method: "start",
            arguments: [startRequest, .import(42)]
        ) == .undefined
    )
    let callsAfterDelete = await callbackRecorder.recordedCalls
    guard case let .object(secondUpdate) = callsAfterDelete.last?.arguments.first,
          case let .object(secondResult)? = secondUpdate["result"],
          case let .array(secondMatches)? = secondResult["matches"]
    else {
        Issue.record("Expected a second autocomplete result")
        return
    }
    #expect(callsAfterDelete.last?.callbackID == 42)
    #expect(secondMatches.isEmpty)
}


@Test
func desktopBrowserSidebarAutocompleteRecordsReleasedDirectNavigation()
    async throws
{
    let callbackRecorder = BrowsingStateCallbackRecorder()
    let service = CodexDesktopBrowsingStateAppHostService(
        pageRestoreState: CodexDesktopBrowserPageRestoreState(),
        callbackInvoker: { callbackID, arguments in
            await callbackRecorder.record(
                callbackID: callbackID,
                arguments: arguments
            )
        }
    )
    let directURL = "https://example.com/docs"
    let directStart: BrowsingStateValue = .object([
        "browserTabId": .string("composer-tab-1"),
        "conversationId": .string("thread-1"),
        "editingSessionId": .string("editing-1"),
        "input": .object([
            "cursorPosition": .integer(200),
            "preventInlineAutocomplete": .bool(false),
            "text": .string(directURL),
        ]),
        "requestId": .string("request-1"),
    ])

    #expect(
        try await service.invoke(
            service: "browserSidebarAutocomplete",
            method: "start",
            arguments: [directStart, .import(51)]
        ) == .undefined
    )
    let initialCalls = await callbackRecorder.recordedCalls
    guard case let .object(initialUpdate)? = initialCalls.first?.arguments.first,
          case let .object(initialResult)? = initialUpdate["result"],
          case let .array(initialMatches)? = initialResult["matches"],
          case let .object(initialMatch)? = initialMatches.first
    else {
        Issue.record("Expected a direct URL autocomplete match")
        return
    }
    #expect(initialMatch["destinationURL"] == .string(directURL))
    #expect(initialMatch["type"] == .string("url"))
    #expect(initialMatch["acceptToken"] == nil)

    let recordNavigation: BrowsingStateValue = .object([
        "browserTabId": .string("composer-tab-1"),
        "conversationId": .string("thread-1"),
        "destinationURL": .string(directURL),
        "editingSessionId": .string("editing-1"),
        "requestId": .string("request-1"),
    ])
    #expect(
        try await service.invoke(
            service: "browserSidebarAutocomplete",
            method: "recordNavigation",
            arguments: [recordNavigation]
        ) == .undefined
    )

    let historyStart: BrowsingStateValue = .object([
        "browserTabId": .string("composer-tab-1"),
        "conversationId": .string("thread-1"),
        "editingSessionId": .string("editing-1"),
        "input": .object([
            "cursorPosition": .integer(7),
            "preventInlineAutocomplete": .bool(false),
            "text": .string("example"),
        ]),
        "requestId": .string("request-2"),
    ])
    #expect(
        try await service.invoke(
            service: "browserSidebarAutocomplete",
            method: "start",
            arguments: [historyStart, .import(52)]
        ) == .undefined
    )
    let callsAfterNavigation = await callbackRecorder.recordedCalls
    guard case let .object(historyUpdate) = callsAfterNavigation.last?.arguments.first,
          case let .object(historyResult)? = historyUpdate["result"],
          case let .array(historyMatches)? = historyResult["matches"],
          case let .object(historyMatch)? = historyMatches.first
    else {
        Issue.record("Expected the recorded navigation in later results")
        return
    }
    #expect(callsAfterNavigation.last?.callbackID == 52)
    #expect(historyMatch["destinationURL"] == .string(directURL))
    #expect(historyMatch["type"] == .string("history"))
    #expect(historyMatch["acceptToken"] != nil)
}

@Test
func desktopBrowserSidebarAutocompleteWrongIdentityPreservesActiveRequest()
    async throws
{
    let restoreState = CodexDesktopBrowserPageRestoreState()
    await restoreState.recordDurableSnapshot(
        .object([
            "title": .string("Codex documentation"),
            "url": .string("https://example.com/docs"),
        ]),
        browserStorageID: "storage-1",
        browserTabID: "page-tab-1",
        conversationID: "thread-1"
    )
    let callbackRecorder = BrowsingStateCallbackRecorder()
    let service = CodexDesktopBrowsingStateAppHostService(
        pageRestoreState: restoreState,
        callbackInvoker: { callbackID, arguments in
            await callbackRecorder.record(
                callbackID: callbackID,
                arguments: arguments
            )
        }
    )
    let startRequest: BrowsingStateValue = .object([
        "browserTabId": .string("composer-tab-1"),
        "conversationId": .string("thread-1"),
        "editingSessionId": .string("editing-1"),
        "input": .object([
            "cursorPosition": .integer(5),
            "preventInlineAutocomplete": .bool(false),
            "text": .string("Codex"),
        ]),
        "requestId": .string("request-1"),
    ])
    #expect(
        try await service.invoke(
            service: "browserSidebarAutocomplete",
            method: "start",
            arguments: [startRequest, .import(61)]
        ) == .undefined
    )
    let initialCalls = await callbackRecorder.recordedCalls
    guard case let .object(initialUpdate)? = initialCalls.first?.arguments.first,
          case let .object(initialResult)? = initialUpdate["result"],
          case let .array(initialMatches)? = initialResult["matches"],
          case let .object(initialMatch)? = initialMatches.first,
          case let .string(acceptToken)? = initialMatch["acceptToken"],
          case let .string(deleteToken)? = initialMatch["deleteToken"]
    else {
        Issue.record("Expected an active released autocomplete match")
        return
    }

    let wrongIdentity: [String: BrowsingStateValue] = [
        "browserTabId": .string("composer-tab-1"),
        "conversationId": .string("thread-1"),
        "editingSessionId": .string("editing-1"),
        "requestId": .string("wrong-request"),
    ]
    #expect(
        try await service.invoke(
            service: "browserSidebarAutocomplete",
            method: "stop",
            arguments: [.object(wrongIdentity.merging([
                "reason": .string("input_changed")
            ]) { _, new in new })]
        ) == .undefined
    )
    #expect(
        try await service.invoke(
            service: "browserSidebarAutocomplete",
            method: "accept",
            arguments: [.object(wrongIdentity.merging([
                "acceptToken": .string(acceptToken)
            ]) { _, new in new })]
        ) == .undefined
    )
    #expect(
        try await service.invoke(
            service: "browserSidebarAutocomplete",
            method: "deleteMatch",
            arguments: [.object(wrongIdentity.merging([
                "deleteToken": .string(deleteToken)
            ]) { _, new in new })]
        ) == .undefined
    )
    #expect(await callbackRecorder.recordedCalls.count == 1)

    let deleteRequest: BrowsingStateValue = .object([
        "browserTabId": .string("composer-tab-1"),
        "conversationId": .string("thread-1"),
        "deleteToken": .string(deleteToken),
        "editingSessionId": .string("editing-1"),
        "requestId": .string("request-1"),
    ])
    #expect(
        try await service.invoke(
            service: "browserSidebarAutocomplete",
            method: "deleteMatch",
            arguments: [deleteRequest]
        ) == .undefined
    )
    #expect(await callbackRecorder.recordedCalls.count == 2)
}

@Test
func desktopBrowserSidebarAutocompleteAcceptTerminatesMatchingActiveRequest()
    async throws
{
    let restoreState = CodexDesktopBrowserPageRestoreState()
    await restoreState.recordDurableSnapshot(
        .object([
            "title": .string("Codex documentation"),
            "url": .string("https://example.com/docs"),
        ]),
        browserStorageID: "storage-1",
        browserTabID: "page-tab-1",
        conversationID: "thread-1"
    )
    let callbackRecorder = BrowsingStateCallbackRecorder()
    let service = CodexDesktopBrowsingStateAppHostService(
        pageRestoreState: restoreState,
        callbackInvoker: { callbackID, arguments in
            await callbackRecorder.record(
                callbackID: callbackID,
                arguments: arguments
            )
        }
    )
    let startRequest: BrowsingStateValue = .object([
        "browserTabId": .string("composer-tab-1"),
        "conversationId": .string("thread-1"),
        "editingSessionId": .string("editing-1"),
        "input": .object([
            "cursorPosition": .integer(5),
            "preventInlineAutocomplete": .bool(false),
            "text": .string("Codex"),
        ]),
        "requestId": .string("request-1"),
    ])
    #expect(
        try await service.invoke(
            service: "browserSidebarAutocomplete",
            method: "start",
            arguments: [startRequest, .import(71)]
        ) == .undefined
    )
    let initialCalls = await callbackRecorder.recordedCalls
    guard case let .object(initialUpdate)? = initialCalls.first?.arguments.first,
          case let .object(initialResult)? = initialUpdate["result"],
          case let .array(initialMatches)? = initialResult["matches"],
          case let .object(initialMatch)? = initialMatches.first,
          case let .string(acceptToken)? = initialMatch["acceptToken"],
          case let .string(deleteToken)? = initialMatch["deleteToken"]
    else {
        Issue.record("Expected an active released autocomplete match")
        return
    }

    let acceptRequest: BrowsingStateValue = .object([
        "acceptToken": .string(acceptToken),
        "browserTabId": .string("composer-tab-1"),
        "conversationId": .string("thread-1"),
        "editingSessionId": .string("editing-1"),
        "requestId": .string("request-1"),
    ])
    #expect(
        try await service.invoke(
            service: "browserSidebarAutocomplete",
            method: "accept",
            arguments: [acceptRequest]
        ) == .undefined
    )
    let deleteAfterAccept: BrowsingStateValue = .object([
        "browserTabId": .string("composer-tab-1"),
        "conversationId": .string("thread-1"),
        "deleteToken": .string(deleteToken),
        "editingSessionId": .string("editing-1"),
        "requestId": .string("request-1"),
    ])
    #expect(
        try await service.invoke(
            service: "browserSidebarAutocomplete",
            method: "deleteMatch",
            arguments: [deleteAfterAccept]
        ) == .undefined
    )
    #expect(await callbackRecorder.recordedCalls.count == 1)
}

@Test
func desktopBrowserTabMentionsForwardsSearchAndSubscription()
    async throws
{
    let searchRequest: BrowsingStateValue = .object([
        "conversationId": .string("thread-1"),
        "query": .string("docs"),
    ])
    let searchResult: BrowsingStateValue = .object([
        "candidates": .array([
            .object([
                "browserFamily": .string("chrome"),
                "browserId": .string("browser-1"),
                "faviconUrl": .null,
                "pluginId": .string("browser@openai-bundled"),
                "recency": .number(0.8),
                "snapshot": .object([
                    "title": .string("Docs"),
                    "url": .string("https://example.com/docs"),
                ]),
                "source": .string("iab"),
                "tabId": .string("tab-1"),
            ])
        ])
    ])
    let subscriptionTarget: BrowsingStateValue = .rpcObject([:])
    let recorder = BrowsingStateRequestRecorder(
        responses: [searchResult, subscriptionTarget]
    )
    let service = CodexDesktopBrowsingStateAppHostService(
        provider: { request in
            try await recorder.handle(request)
        }
    )

    #expect(
        try await service.invoke(
            service: "browserTabMentions",
            method: "search",
            arguments: [searchRequest]
        ) == searchResult
    )
    #expect(
        try await service.invoke(
            service: "browserTabMentions",
            method: "subscribeInvalidations",
            arguments: [.import(42)]
        ) == subscriptionTarget
    )
    #expect(
        await recorder.recordedRequests == [
            .searchBrowserTabMentions(searchRequest),
            .subscribeBrowserTabMentionInvalidations(
                callback: .import(42)
            ),
        ]
    )
}

@Test
func desktopCustomAvatarsForwardsLoadRequestsAndReleasedShapes()
    async throws
{
    let avatar: BrowsingStateValue = .object([
        "description": .string("An owl avatar"),
        "directoryPath": .string("/avatars/owl"),
        "displayName": .string("Owl"),
        "id": .string("custom:owl"),
        "spritesheetDataUrl": .string(
            "data:image/webp;base64,UklGRg=="
        ),
        "spriteVersionNumber": .integer(2),
    ])
    let avatarList: BrowsingStateValue = .object([
        "avatarDirectory": .string("/avatars"),
        "avatars": .array([avatar]),
    ])
    let recorder = BrowsingStateRequestRecorder(
        responses: [avatarList, avatar, .null, .object(["preview": .bool(true)]), .object(["installed": .bool(true)])]
    )
    let service = CodexDesktopBrowsingStateAppHostService(
        provider: { request in
            try await recorder.handle(request)
        }
    )

    #expect(
        try await service.invoke(
            service: "customAvatars",
            method: "load",
            arguments: nil
        ) == avatarList
    )
    #expect(
        try await service.invoke(
            service: "customAvatars",
            method: "loadAvatar",
            arguments: [.string("custom:owl")]
        ) == avatar
    )
    #expect(
        try await service.invoke(
            service: "customAvatars",
            method: "loadAvatar",
            arguments: [.string("not-custom")]
        ) == .null
    )
    let installRequest: BrowsingStateValue = .object([
        "name": .string("Owl"),
        "description": .string("An owl avatar"),
        "imageUrl": .string("https://example.com/owl.webp"),
        "spriteVersionNumber": .integer(2)
    ])
    #expect(
        try await service.invoke(
            service: "customAvatars",
            method: "previewPetInstall",
            arguments: [installRequest]
        ) == .object(["preview": .bool(true)])
    )
    #expect(
        try await service.invoke(
            service: "customAvatars",
            method: "installPet",
            arguments: [installRequest]
        ) == .object(["installed": .bool(true)])
    )
    #expect(
        await recorder.recordedRequests == [
            .loadCustomAvatars,
            .loadCustomAvatar(id: "custom:owl"),
            .loadCustomAvatar(id: "not-custom"),
            .previewCustomAvatarInstall(installRequest),
            .installCustomAvatar(installRequest),
        ]
    )
}

@Test
func desktopBrowsingStateRejectsMalformedReleasedArguments()
    async throws
{
    let service = CodexDesktopBrowsingStateAppHostService(
        provider: { _ in .undefined }
    )
    let validAutocompleteRequest: BrowsingStateValue = .object([
        "browserTabId": .string("tab-1"),
        "conversationId": .string("thread-1"),
        "editingSessionId": .string("editing-1"),
        "input": .object([
            "cursorPosition": .integer(0),
            "preventInlineAutocomplete": .bool(false),
            "text": .string(""),
        ]),
        "requestId": .string("request-1"),
    ])

    await #expect(throws: CodexDesktopBrowsingStateAppHostService.Error.invalidArguments) {
        try await service.invoke(
            service: "browsingHistory",
            method: "clearBrowsingData",
            arguments: [
                .object([
                    "dataTypes": .array([.string("made-up")]),
                    "timeRange": .string("lastHour"),
                ])
            ]
        )
    }
    await #expect(throws: CodexDesktopBrowsingStateAppHostService.Error.invalidArguments) {
        try await service.invoke(
            service: "browsingHistory",
            method: "getBrowsingDataSummary",
            arguments: [.string("lastYear")]
        )
    }
    await #expect(throws: CodexDesktopBrowsingStateAppHostService.Error.invalidArguments) {
        try await service.invoke(
            service: "browserSidebarAutocomplete",
            method: "start",
            arguments: [validAutocompleteRequest]
        )
    }
    await #expect(throws: CodexDesktopBrowsingStateAppHostService.Error.invalidArguments) {
        try await service.invoke(
            service: "browserSidebarAutocomplete",
            method: "accept",
            arguments: [validAutocompleteRequest]
        )
    }
    await #expect(throws: CodexDesktopBrowsingStateAppHostService.Error.invalidArguments) {
        try await service.invoke(
            service: "browserTabMentions",
            method: "search",
            arguments: [
                .object([
                    "conversationId": .string("thread-1"),
                    "query": .integer(7),
                ])
            ]
        )
    }
    await #expect(throws: CodexDesktopBrowsingStateAppHostService.Error.invalidArguments) {
        try await service.invoke(
            service: "customAvatars",
            method: "load",
            arguments: [.null]
        )
    }
    await #expect(throws: CodexDesktopBrowsingStateAppHostService.Error.invalidArguments) {
        try await service.invoke(
            service: "customAvatars",
            method: "previewPetInstall",
            arguments: [.object([
                "name": .string("Owl"),
                "imageUrl": .string("http://example.com/owl.webp")
            ])]
        )
    }
    await #expect(throws: CodexDesktopBrowsingStateAppHostService.Error.invalidArguments) {
        try await service.invoke(
            service: "customAvatars",
            method: "installPet",
            arguments: [.object([
                "name": .string("Owl"),
                "imageUrl": .string("https://localhost/owl.webp")
            ])]
        )
    }
}

@Test
func desktopBrowsingStateDoesNotFabricateUnavailableProviderData()
    async throws
{
    let service = CodexDesktopBrowsingStateAppHostService()

    await #expect(
        throws: CodexDesktopBrowsingStateAppHostService.Error.unavailable(
            service: "customAvatars",
            method: "load"
        )
    ) {
        try await service.invoke(
            service: "customAvatars",
            method: "load",
            arguments: nil
        )
    }
    await #expect(
        throws:
            CodexDesktopBrowsingStateAppHostService.Error
            .unsupportedMethod(
                service: "browserTabMentions",
                method: "unknown"
            )
    ) {
        try await service.invoke(
            service: "browserTabMentions",
            method: "unknown",
            arguments: nil
        )
    }
}
