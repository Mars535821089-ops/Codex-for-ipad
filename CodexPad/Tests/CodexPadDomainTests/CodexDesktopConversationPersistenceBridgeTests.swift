import CodexPadApplication
import CodexPadDomain
import CodexPadProtocolBridge
import Foundation
import Testing

@MainActor
@Test
func desktopConversationPersistenceCreatesDurableThreadAndCommitsResponse()
    throws
{
    let suiteName =
        "CodexDesktopConversationPersistenceBridgeTests."
        + UUID().uuidString
    let defaults = try #require(
        UserDefaults(suiteName: suiteName)
    )
    defer {
        defaults.removePersistentDomain(forName: suiteName)
    }
    let lastActiveThreadStore =
        CodexDesktopLastActiveLocalThreadStore(userDefaults: defaults)
    let store = DesktopConversationPersistenceStoreFixture()
    let bridge = CodexDesktopConversationPersistenceBridge(
        store: store,
        lastActiveLocalThreadStore: lastActiveThreadStore
    )

    let context = try bridge.begin(
        requestID: "fetch-1",
        conversationID: nil,
        input: [
            .image(
                detail: nil,
                url: "file-service://file-image-1"
            ),
            .text(text: "Reply once", textElements: []),
        ],
        model: "gpt-5.6-sol",
        reasoningEffort: "high",
        cwd: "/workspace/project"
    )

    #expect(context.threadID == CodexStoredThreadID("thread-stable"))
    #expect(lastActiveThreadStore.threadID == context.threadID.rawValue)
    #expect(context.turnID == "turn/stable")
    #expect(context.priorInputItems == [store.priorItem])
    #expect(store.threadStarts.count == 1)
    #expect(store.threadStarts[0].ephemeral == .value(false))
    #expect(store.threadStarts[0].model == .value("gpt-5.6-sol"))
    #expect(store.threadStarts[0].modelProvider == .value("openai"))
    #expect(store.threadStarts[0].cwd == .value("/workspace/project"))
    #expect(store.turnStarts.count == 1)
    #expect(store.turnStarts[0].threadID == context.threadID)
    #expect(
        store.turnStarts[0].input
            == [
                .image(
                    detail: nil,
                    url: "file-service://file-image-1"
                ),
                .text(text: "Reply once", textElements: []),
            ]
    )
    #expect(store.priorInputRequests.count == 1)
    #expect(
        store.priorInputRequests[0]
            == CodexPriorInputItemsParams(
                threadID: context.threadID,
                beforeTurnID: .value(context.turnID)
            )
    )

    // The released renderer keeps its temporary home route while the
    // `/f/conversation` stream is in flight, which can clear the optimistic
    // anchor created by `begin`.
    lastActiveThreadStore.recordRendererPath("/")
    #expect(lastActiveThreadStore.threadID == nil)

    let assistantItem =
        #"{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Done"}]}"#
    try bridge.commit(
        context,
        responseItems: [assistantItem],
        responseID: "response/stable",
        usage: nil,
        endTurn: true,
        fallbackAssistantText: "Done"
    )

    #expect(store.commits.count == 1)
    let commit = store.commits[0]
    #expect(commit.threadID == context.threadID)
    #expect(commit.turnID == context.turnID)
    #expect(commit.expectedNextOrder == 0)
    #expect(commit.entries.map(\.itemJSON) == [assistantItem])
    #expect(commit.completion.concreteValue?.responseID == "response/stable")
    #expect(commit.completion.concreteValue?.endTurn == .value(true))
    #expect(lastActiveThreadStore.threadID == context.threadID.rawValue)
    #expect(
        defaults.string(
            forKey:
                CodexDesktopLastActiveLocalThreadStore.diagnosticKey
        ) == "source=conversation-commit path=local anchor=present"
    )
}

@MainActor
@Test
func desktopConversationPersistenceReplacesLegacyUUIDAnchor()
    throws
{
    let suiteName =
        "CodexDesktopConversationPersistenceBridgeTests."
        + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = DesktopConversationPersistenceStoreFixture()
    let bridge = CodexDesktopConversationPersistenceBridge(
        store: store,
        lastActiveLocalThreadStore:
            CodexDesktopLastActiveLocalThreadStore(userDefaults: defaults)
    )

    let context = try bridge.begin(
        requestID: "fetch-legacy",
        conversationID: "uuid",
        input: [.text(text: "Hello", textElements: [])],
        model: "gpt-5.5",
        reasoningEffort: "medium",
        cwd: nil
    )

    #expect(context.threadID == CodexStoredThreadID("thread-stable"))
    #expect(store.threadStarts.count == 1)
    #expect(store.turnStarts.count == 1)
    #expect(store.turnStarts[0].threadID == context.threadID)
}

@MainActor
@Test
func desktopConversationPersistenceCanAnchorNativeTurnLifecycle()
    throws
{
    let suiteName =
        "CodexDesktopConversationPersistenceBridgeTests."
        + UUID().uuidString
    let defaults = try #require(
        UserDefaults(suiteName: suiteName)
    )
    defer {
        defaults.removePersistentDomain(forName: suiteName)
    }
    let store =
        CodexDesktopLastActiveLocalThreadStore(userDefaults: defaults)
    let lifecycle =
        CodexDesktopConversationLifecycleAnchor(store: store)

    lifecycle.threadStarted(CodexStoredThreadID("thread-native"))
    #expect(store.threadID == "thread-native")

    store.recordRendererPath("/")
    #expect(store.threadID == nil)

    lifecycle.turnStarted(CodexStoredThreadID("thread-native"))
    #expect(store.threadID == "thread-native")
    #expect(
        defaults.string(
            forKey:
                CodexDesktopLastActiveLocalThreadStore.diagnosticKey
        ) == "source=turn-start path=local anchor=present"
    )
}

@MainActor
private final class DesktopConversationPersistenceStoreFixture:
    CodexDesktopConversationHistoryPersisting
{
    var threadStarts: [CodexThreadStartParams] = []
    var turnStarts: [CodexTurnStartParams] = []
    var priorInputRequests: [CodexPriorInputItemsParams] = []
    var commits: [CodexRawHistoryCommit] = []
    let priorItem =
        #"{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Earlier answer"}]}"#

    func startThread(
        id _: CodexAppServerRequestID,
        params: CodexThreadStartParams
    ) throws -> CodexThreadResumeResult {
        threadStarts.append(params)
        let id = CodexStoredThreadID("thread-stable")
        return CodexThreadResumeResult(
            thread: CodexStoredThread(
                id: id,
                sessionID: id.rawValue,
                preview: "",
                ephemeral: false,
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

    func startDesktopTurn(
        id _: CodexAppServerRequestID,
        params: CodexTurnStartParams
    ) throws -> CodexTurnStartResult {
        turnStarts.append(params)
        return CodexTurnStartResult(
            turn: CodexStoredTurn(
                id: "turn/stable",
                items: [],
                itemsView: .notLoaded,
                status: .inProgress
            )
        )
    }

    func priorInputItems(
        id _: CodexAppServerRequestID,
        params: CodexPriorInputItemsParams
    ) throws -> CodexPriorInputItemsResult {
        priorInputRequests.append(params)
        return CodexPriorInputItemsResult(
            threadID: params.threadID,
            throughTurnID: "turn/earlier",
            items: [priorItem],
            completeness: .complete
        )
    }

    func commitRawHistory(
        _ command: CodexRawHistoryCommit
    ) throws -> CodexRawHistoryCommittedEvent {
        commits.append(command)
        return CodexRawHistoryCommittedEvent(
            sequence: 1,
            threadID: command.threadID,
            turnID: command.turnID,
            expectedNextOrder: command.expectedNextOrder,
            entries: command.entries,
            completion: command.completion.concreteValue
                ?? CodexRawHistoryCompletion(responseID: "missing")
        )
    }
}

extension CodexWireOptional {
    fileprivate var concreteValue: Value? {
        guard case let .value(value) = self else { return nil }
        return value
    }
}
