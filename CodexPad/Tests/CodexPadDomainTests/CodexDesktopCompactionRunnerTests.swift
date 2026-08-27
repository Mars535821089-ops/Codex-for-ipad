import CodexPadApplication
import CodexPadDomain
import CodexPadProtocolBridge
import Foundation
import Testing

@MainActor
private final class CompactRunnerTransport: CodexCoreTransport {
    let threadID = CodexStoredThreadID(
        "019fab26-5c01-7562-97f1-0999adf15538"
    )
    let turnID = "019fab26-5c01-7562-97f1-0999adf15539"
    let itemID = "019fab26-5c01-7562-97f1-0999adf15540"
    var events: [CodexCoreEvent] = []
    var compactCommits: [CodexCompactHistoryCommit] = []

    func submit(_ command: CodexCoreCommand) throws {}
    func submit(_ command: CodexRawHistoryCommit) throws {}

    func submit(_ command: CodexCompactHistoryCommit) throws {
        compactCommits.append(command)
    }

    func request(_ request: CodexAppServerThreadRequest) throws -> Data {
        guard case let .compactStart(id, requestedThreadID) = request,
              requestedThreadID == threadID
        else {
            throw CodexCoreTransportError.unsupportedTurnRequest
        }
        events.append(
            .stableCompactStarted(
                CodexStableCompactStartedEvent(
                    sequence: 1,
                    threadID: threadID,
                    turnID: turnID,
                    itemID: itemID
                )
            )
        )
        return try JSONEncoder().encode(
            CodexAppServerReply<CodexThreadEmptyResponse>.success(
                .init(id: id, result: .init())
            )
        )
    }

    func request(_ request: CodexRawHistoryRequest) throws -> Data {
        guard case let .priorInputItems(id, params) = request,
              params.threadID == threadID
        else {
            throw CodexCoreTransportError.unsupportedRawHistoryRequest
        }
        return try JSONEncoder().encode(
            CodexAppServerReply<CodexPriorInputItemsResult>.success(
                .init(
                    id: id,
                    result: .init(
                        threadID: threadID,
                        throughTurnID: "previous-turn",
                        items: [
                            #"{"type":"message","role":"user","content":[{"type":"input_text","text":"important prior fact"}]}"#,
                            #"{"type":"message","role":"assistant","content":[{"type":"output_text","text":"old answer"}]}"#,
                        ],
                        completeness: .complete
                    )
                )
            )
        )
    }

    func nextEvent() throws -> CodexCoreEvent? {
        events.isEmpty ? nil : events.removeFirst()
    }
}

@MainActor
private final class CompactRunnerProvider: CodexPersistedTurnProvider {
    func stream(
        _ request: CodexPersistedTurnProviderRequest,
        cancellation: CodexTurnCancellation
    ) async -> AsyncThrowingStream<CodexCoreProviderEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(
                .responseStarted(
                    sequence: 1,
                    requestID: request.requestID,
                    sourceCommit: "compact-source"
                )
            )
            continuation.yield(
                .assistantTextDelta(
                    sequence: 2,
                    requestID: request.requestID,
                    delta: "Current progress and next steps."
                )
            )
            continuation.yield(
                .responseCompleted(
                    sequence: 3,
                    requestID: request.requestID,
                    responseID: "response-compact",
                    usage: nil,
                    endTurn: true
                )
            )
            continuation.finish()
        }
    }
}

@MainActor
@Test
func desktopCompactionRunsProviderCommitsReplacementAndEmitsLifecycle()
    async throws
{
    let transport = CompactRunnerTransport()
    let store = CodexSessionStore(transport: transport)
    let provider = CompactRunnerProvider()
    var notifications: [CodexAppServerTurnNotification] = []
    let runner = CodexDesktopTurnSessionRunner(
        sessionStore: store,
        providerFactory: { _ in provider },
        notificationSink: { notifications.append($0) }
    )

    try runner.startDesktopCompaction(
        id: .string("compact-1"),
        threadID: transport.threadID
    )
    await runner.waitForTurn(transport.turnID)

    #expect(transport.compactCommits.count == 1)
    let commit = try #require(transport.compactCommits.first)
    #expect(commit.turnID == transport.turnID)
    #expect(commit.itemID == transport.itemID)
    #expect(commit.responseID == "response-compact")
    #expect(commit.replacementItems.count == 2)
    #expect(commit.replacementItems[0].contains("important prior fact"))
    #expect(commit.replacementItems[1].contains(
        "Current progress and next steps."
    ))
    #expect(notifications.count == 4)
    guard case .turnStarted = notifications[0],
          case .itemStarted = notifications[1],
          case .itemCompleted = notifications[2],
          case .turnCompleted = notifications[3]
    else {
        Issue.record("Expected compact turn lifecycle")
        return
    }
}
