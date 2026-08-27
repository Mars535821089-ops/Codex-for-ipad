import CodexPadApplication
import CodexPadDomain
import CodexPadProtocolBridge
import Foundation
import Testing

@MainActor
private final class ThreadMetadataProviderFixture:
    CodexPersistedTurnProvider
{
    let response: String
    private(set) var requests: [CodexPersistedTurnProviderRequest] = []

    init(response: String) {
        self.response = response
    }

    func stream(
        _ request: CodexPersistedTurnProviderRequest,
        cancellation _: CodexTurnCancellation
    ) async -> AsyncThrowingStream<CodexCoreProviderEvent, Error> {
        requests.append(request)
        return AsyncThrowingStream { continuation in
            continuation.yield(
                .assistantTextDelta(
                    sequence: 1,
                    requestID: request.requestID,
                    delta: response
                )
            )
            continuation.yield(
                .responseCompleted(
                    sequence: 2,
                    requestID: request.requestID,
                    responseID: "response-metadata",
                    usage: nil,
                    endTurn: true
                )
            )
            continuation.finish()
        }
    }
}

@MainActor
private final class ThreadMetadataHistoryFixture:
    CodexDesktopThreadMetadataHistoryProviding
{
    let items: [String]
    private(set) var requestedThreadIDs: [CodexStoredThreadID] = []

    init(items: [String]) {
        self.items = items
    }

    func allPriorInputItems(
        for threadID: CodexStoredThreadID
    ) throws -> [String] {
        requestedThreadIDs.append(threadID)
        return items
    }
}

@MainActor
@Test
func desktopThreadMetadataGeneratorUsesLowEffortStructuredTitleRequest()
    async throws
{
    let provider = ThreadMetadataProviderFixture(
        response: #"{"title":"Fix account refresh","description":"account refresh Keychain"}"#
    )
    let generator = CodexDesktopThreadMetadataGenerator(
        providerFactory: { _ in provider }
    )

    let result = try await generator.generateTitle(
        .init(
            hostID: "local",
            prompt: "Repair account refresh",
            cwd: "/workspace",
            readOnlyAppToolAllowlist: [],
            threadStartKind: "new",
            serviceName: "desktop"
        )
    )

    #expect(
        result == .init(
            title: "Fix account refresh",
            description: "account refresh Keychain"
        )
    )
    let request = try #require(provider.requests.first)
    #expect(request.startParams.effort == .value("low"))
    #expect(request.startParams.cwd == .value("/workspace"))
    #expect(request.startParams.outputSchema != .omitted)
    #expect(request.frozenPriorInputItems.isEmpty)
    guard case let .text(prompt, _) = request.startParams.input.first else {
        Issue.record("Expected metadata prompt text")
        return
    }
    #expect(prompt.contains("Generate a concise UI title"))
    #expect(prompt.hasSuffix("User prompt:\nRepair account refresh"))
}


@MainActor
@Test
func desktopThreadMetadataGeneratorReconsidersTitleUsingThreadHistory()
    async throws
{
    let historyItems = [
        #"{"type":"message","role":"user","content":[{"type":"input_text","text":"Repair updater transaction"}]}"#
    ]
    let history = ThreadMetadataHistoryFixture(items: historyItems)
    let provider = ThreadMetadataProviderFixture(
        response: #"{"title":"Repair updater commit","description":"updater commit flow"}"#
    )
    let generator = CodexDesktopThreadMetadataGenerator(
        providerFactory: { _ in provider },
        history: history
    )

    let result = try await generator.reconsiderTitle(
        .init(
            hostID: "local",
            threadID: "thread-source",
            currentTitle: "Repair updater",
            cwd: "/workspace",
            serviceName: "desktop"
        )
    )

    #expect(
        result == .init(
            title: "Repair updater commit",
            description: "updater commit flow"
        )
    )
    #expect(history.requestedThreadIDs == [CodexStoredThreadID("thread-source")])
    let request = try #require(provider.requests.first)
    #expect(request.threadID == CodexStoredThreadID("thread-source"))
    #expect(request.frozenPriorInputItems == historyItems)
    guard case let .text(prompt, _) = request.startParams.input.first else {
        Issue.record("Expected metadata prompt text")
        return
    }
    #expect(prompt.contains("Reconsider"))
    #expect(prompt.contains("Current title: Repair updater"))
}

@MainActor
@Test
func desktopThreadMetadataGeneratorCarriesSourceHistoryForDescription()
    async throws
{
    let historyItems = [
        #"{"type":"message","role":"user","content":[{"type":"input_text","text":"Repair updater transaction"}]}"#
    ]
    let history = ThreadMetadataHistoryFixture(items: historyItems)
    let provider = ThreadMetadataProviderFixture(
        response: #"{"description":"updater transaction archive manifest"}"#
    )
    let generator = CodexDesktopThreadMetadataGenerator(
        providerFactory: { _ in provider },
        history: history
    )

    let description = try await generator.generateDescription(
        .init(
            hostID: "local",
            threadID: "thread-source",
            title: "Repair updater",
            cwd: "/workspace",
            serviceName: "desktop"
        )
    )

    #expect(description == "updater transaction archive manifest")
    #expect(
        history.requestedThreadIDs == [
            CodexStoredThreadID("thread-source")
        ]
    )
    let request = try #require(provider.requests.first)
    #expect(request.threadID == CodexStoredThreadID("thread-source"))
    #expect(request.frozenPriorInputItems == historyItems)
    guard case let .text(prompt, _) = request.startParams.input.first else {
        Issue.record("Expected metadata prompt text")
        return
    }
    #expect(prompt.contains("fork of an existing Codex thread"))
    #expect(prompt.contains("Current title: Repair updater"))
}

@MainActor
@Test
func desktopThreadMetadataGeneratorUsesReleasedStructuredSummaryContract()
    async throws
{
    let provider = ThreadMetadataProviderFixture(
        response: #"{"summary":"Fixed provider routing; real chat passes","compactSummary":"Real chat passes"}"#
    )
    let generator = CodexDesktopThreadMetadataGenerator(
        providerFactory: { _ in provider }
    )

    let result = try await generator.generateSummary(
        .init(
            hostID: "local",
            threadID: "thread-source",
            title: "Repair provider",
            previousUserMessage: "Fix chat",
            previousAssistantMessage: "Investigating provider routing",
            latestMessage: "Fixed provider routing; real chat passes",
            phase: "assistant",
            cwd: "/workspace",
            includeCompactSummary: true,
            serviceName: "desktop"
        )
    )

    #expect(
        result == .init(
            summary: "Fixed provider routing; real chat passes",
            compactSummary: "Real chat passes"
        )
    )
    let request = try #require(provider.requests.first)
    #expect(request.startParams.effort == .value("low"))
    #expect(request.startParams.cwd == .value("/workspace"))
    #expect(request.startParams.outputSchema != .omitted)
    #expect(request.frozenPriorInputItems.isEmpty)
    guard case let .text(prompt, _) = request.startParams.input.first else {
        Issue.record("Expected metadata prompt text")
        return
    }
    #expect(prompt.contains("one-line activity update"))
    #expect(prompt.contains("Previous user message: Fix chat"))
    #expect(prompt.contains("Latest message:\nFixed provider routing"))
    #expect(prompt.contains("compactSummary"))
}
