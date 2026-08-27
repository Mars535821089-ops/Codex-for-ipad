import CodexPadApplication
import CodexPadDomain
import CodexPadProtocolBridge
import Foundation
import Testing

private enum PersistedTurnFixtureError: Error, Equatable {
  case providerStopped
  case toolStopped
}

@MainActor
private final class PersistedTurnHistoryFixture:
  CodexPersistedTurnHistory
{
  var startResults: [CodexTurnStartResult]
  var priorResults: [CodexPriorInputItemsResult]
  private(set) var starts: [(CodexAppServerRequestID, CodexTurnStartParams)] = []
  private(set) var priorQueries: [(CodexAppServerRequestID, CodexPriorInputItemsParams)] = []
  private(set) var commits: [CodexRawHistoryCommit] = []
  private var nextSequence: UInt64 = 100

  init(
    startResults: [CodexTurnStartResult],
    priorResults: [CodexPriorInputItemsResult]
  ) {
    self.startResults = startResults
    self.priorResults = priorResults
  }

  func startStableTurn(
    id: CodexAppServerRequestID,
    params: CodexTurnStartParams
  ) throws -> CodexTurnStartResult {
    starts.append((id, params))
    return startResults.removeFirst()
  }

  func priorInputItems(
    id: CodexAppServerRequestID,
    params: CodexPriorInputItemsParams
  ) throws -> CodexPriorInputItemsResult {
    priorQueries.append((id, params))
    return priorResults.removeFirst()
  }

  func commitRawHistory(
    _ command: CodexRawHistoryCommit
  ) throws -> CodexRawHistoryCommittedEvent {
    _ = try command.encodedData()
    commits.append(command)
    defer { nextSequence += 1 }
    return CodexRawHistoryCommittedEvent(
      sequence: nextSequence,
      threadID: command.threadID,
      turnID: command.turnID,
      expectedNextOrder: command.expectedNextOrder,
      entries: command.entries,
      completion: command.completion.concreteValue
    )
  }
}

private struct PersistedTurnProviderBatch: Sendable {
  let events: [CodexCoreProviderEvent]
  let failure: PersistedTurnFixtureError?

  init(
    events: [CodexCoreProviderEvent],
    failure: PersistedTurnFixtureError? = nil
  ) {
    self.events = events
    self.failure = failure
  }
}

@MainActor
private final class PersistedTurnProviderFixture:
  CodexPersistedTurnProvider
{
  var batches: [PersistedTurnProviderBatch]
  private(set) var requests: [CodexPersistedTurnProviderRequest] = []

  init(batches: [PersistedTurnProviderBatch]) {
    self.batches = batches
  }

  func stream(
    _ request: CodexPersistedTurnProviderRequest,
    cancellation: CodexTurnCancellation
  ) async -> AsyncThrowingStream<CodexCoreProviderEvent, Error> {
    requests.append(request)
    let batch = batches.removeFirst()
    return AsyncThrowingStream { continuation in
      for event in batch.events {
        continuation.yield(event)
      }
      if let failure = batch.failure {
        continuation.finish(throwing: failure)
      } else {
        continuation.finish()
      }
    }
  }
}

@MainActor
private final class PersistedTurnDelayedSilentProviderFixture:
  CodexPersistedTurnProvider
{
  let delay: Duration

  init(delay: Duration) {
    self.delay = delay
  }

  func stream(
    _ request: CodexPersistedTurnProviderRequest,
    cancellation: CodexTurnCancellation
  ) async -> AsyncThrowingStream<CodexCoreProviderEvent, Error> {
    AsyncThrowingStream { continuation in
      Task {
        try? await Task.sleep(for: delay)
        continuation.finish()
      }
    }
  }
}

@MainActor
private final class PersistedTurnStalledAfterStartProviderFixture:
  CodexPersistedTurnProvider
{
  func stream(
    _ request: CodexPersistedTurnProviderRequest,
    cancellation: CodexTurnCancellation
  ) async -> AsyncThrowingStream<CodexCoreProviderEvent, Error> {
    AsyncThrowingStream { continuation in
      continuation.yield(
        .responseStarted(
          sequence: 1,
          requestID: request.requestID,
          sourceCommit: "source"
        )
      )
    }
  }
}

@MainActor
private final class PersistedTurnToolFixture:
  CodexPersistedTurnToolExecutor
{
  var outputs: [Result<CodexPersistedTurnLocalToolOutput, Error>]
  private(set) var requests: [CodexPersistedTurnToolRequest] = []

  init(
    outputs: [Result<CodexPersistedTurnLocalToolOutput, Error>]
  ) {
    self.outputs = outputs
  }

  func execute(
    _ request: CodexPersistedTurnToolRequest,
    cancellation: CodexTurnCancellation
  ) async throws -> CodexPersistedTurnLocalToolOutput {
    requests.append(request)
    return try outputs.removeFirst().get()
  }
}

@MainActor
@Test
func persistedTurnContinuesReleasedStartWithoutIssuingDuplicateStart()
  async throws
{
  let threadID = CodexStoredThreadID("thread/raw")
  let turnID = "turn/raw"
  let params = CodexTurnStartParams(
    threadID: threadID,
    input: [.text(text: "continue", textElements: [])]
  )
  let history = PersistedTurnHistoryFixture(
    startResults: [],
    priorResults: [
      .init(
        threadID: threadID,
        throughTurnID: nil,
        items: [],
        completeness: .complete
      )
    ]
  )
  let provider = PersistedTurnProviderFixture(
    batches: [
      .init(events: [
        .responseStarted(
          sequence: 1,
          requestID: turnID,
          sourceCommit: "source"
        ),
        .responseCompleted(
          sequence: 2,
          requestID: turnID,
          responseID: "response/raw",
          usage: nil,
          endTurn: true
        ),
      ])
    ]
  )
  let coordinator = CodexPersistedTurnCoordinator(
    history: history,
    provider: provider
  )

  let result = try await coordinator.continueRun(
    started: .init(turn: initialPersistedTurn(id: turnID)),
    priorRequestID: .string("prior/raw"),
    params: params,
    cancellation: CodexTurnCancellation()
  )

  #expect(result.turnID == turnID)
  #expect(history.starts.isEmpty)
  #expect(history.priorQueries.count == 1)
  #expect(history.commits.count == 1)
}

@MainActor
@Test
func persistedTurnFreezesPriorAndCommitsExactRoundHistory() async throws {
  let threadID = CodexStoredThreadID(" thread/原样 ")
  let turnID = "turn/原样"
  let priorItem =
    "{\n \"type\":\"message\",\"role\":\"assistant\","
    + "\"content\":[{\"type\":\"output_text\",\"text\":\"old\"}] }"
  let reasoningItem =
    #"{"type":"reasoning","summary":[{"type":"summary_text","text":"inspect"}]}"#
  let toolCallItem =
    "{\n \"type\":\"function_call\",\"name\":\"read_workspace_file\","
    + "\"arguments\":\"{\\\"path\\\":\\\"README.md\\\"}\","
    + "\"call_id\":\"call/raw\" }"
  let toolOutputItem =
    "{ \"type\":\"function_call_output\","
    + "\"call_id\":\"call/raw\",\"output\":\"line 1\\nline 2\" }"
  let assistantItem =
    "{\n \"type\":\"message\",\"role\":\"assistant\","
    + "\"content\":[{\"type\":\"output_text\",\"text\":\"done\"}] }"
  let usage = CodexTokenUsageBreakdown(
    totalTokens: 34,
    inputTokens: 21,
    cachedInputTokens: 5,
    cacheWriteInputTokens: 2,
    outputTokens: 13,
    reasoningOutputTokens: 3
  )
  let startParams = CodexTurnStartParams(
    threadID: threadID,
    input: [.text(text: "continue", textElements: [])]
  )
  let history = PersistedTurnHistoryFixture(
    startResults: [
      .init(turn: initialPersistedTurn(id: turnID))
    ],
    priorResults: [
      .init(
        threadID: threadID,
        throughTurnID: "turn/previous",
        items: [priorItem],
        completeness: .complete
      )
    ]
  )
  let provider = PersistedTurnProviderFixture(
    batches: [
      .init(events: [
        .responseStarted(
          sequence: 1,
          requestID: turnID,
          sourceCommit: "source"
        ),
        .responseItemDone(
          sequence: 2,
          requestID: turnID,
          itemJSON: reasoningItem
        ),
        .toolCallRequested(
          sequence: 3,
          requestID: turnID,
          name: "read_workspace_file",
          arguments: #"{"path":"README.md"}"#,
          callID: "call/raw",
          itemJSON: toolCallItem
        ),
        .responseCompleted(
          sequence: 4,
          requestID: turnID,
          responseID: "response/one",
          usage: usage,
          endTurn: false
        ),
      ]),
      .init(events: [
        .responseStarted(
          sequence: 5,
          requestID: turnID,
          sourceCommit: "source"
        ),
        .responseItemDone(
          sequence: 6,
          requestID: turnID,
          itemJSON: assistantItem
        ),
        .responseCompleted(
          sequence: 7,
          requestID: turnID,
          responseID: "response/two",
          usage: nil,
          endTurn: true
        ),
      ]),
    ]
  )
  let tools = PersistedTurnToolFixture(
    outputs: [
      .success(.init(itemJSON: toolOutputItem))
    ]
  )
  let coordinator = CodexPersistedTurnCoordinator(
    history: history,
    provider: provider,
    toolExecutor: tools
  )

  let result = try await coordinator.run(
    startRequestID: .string("start/raw"),
    priorRequestID: .integer(700),
    params: startParams,
    cancellation: CodexTurnCancellation()
  )

  #expect(result.threadID == threadID)
  #expect(result.turnID == turnID)
  #expect(result.frozenPriorInputItems == [priorItem])
  #expect(
    result.currentTurnInputItems
      == [reasoningItem, toolCallItem, toolOutputItem, assistantItem]
  )
  #expect(
    result.completions.map(\.responseID)
      == ["response/one", "response/two"]
  )
  #expect(result.completions[0].usage == .value(usage))
  #expect(result.completions[0].endTurn == .value(false))
  #expect(result.completions[1].usage == .omitted)
  #expect(result.completions[1].endTurn == .value(true))

  #expect(history.starts.count == 1)
  #expect(history.starts[0].0 == .string("start/raw"))
  #expect(history.starts[0].1 == startParams)
  #expect(history.priorQueries.count == 1)
  #expect(history.priorQueries[0].0 == .integer(700))
  #expect(history.priorQueries[0].1.threadID == threadID)
  #expect(
    history.priorQueries[0].1.beforeTurnID
      == .value(turnID)
  )

  #expect(provider.requests.count == 2)
  #expect(
    provider.requests.map(\.frozenPriorInputItems)
      == [[priorItem], [priorItem]]
  )
  #expect(provider.requests[0].currentTurnInputItems.isEmpty)
  #expect(
    provider.requests[1].currentTurnInputItems
      == [reasoningItem, toolCallItem, toolOutputItem]
  )
  #expect(provider.requests.map(\.requestID) == [turnID, turnID])

  #expect(history.commits.count == 3)
  #expect(history.commits[0].expectedNextOrder == 0)
  #expect(
    history.commits[0].entries
      == [
        .init(
          order: 0,
          source: .provider,
          itemJSON: reasoningItem
        ),
        .init(
          order: 1,
          source: .provider,
          itemJSON: toolCallItem
        ),
      ]
  )
  #expect(
    history.commits[0].completion
      == .value(
        .init(
          responseID: "response/one",
          usage: .value(usage),
          endTurn: .value(false)
        )
      )
  )
  #expect(history.commits[1].expectedNextOrder == 2)
  #expect(
    history.commits[1].entries
      == [
        .init(
          order: 2,
          source: .localTool,
          itemJSON: toolOutputItem
        )
      ]
  )
  #expect(history.commits[1].completion == .omitted)
  #expect(history.commits[2].expectedNextOrder == 3)
  #expect(
    history.commits[2].entries
      == [
        .init(
          order: 3,
          source: .provider,
          itemJSON: assistantItem
        )
      ]
  )
  #expect(
    history.commits[2].completion
      == .value(
        .init(
          responseID: "response/two",
          endTurn: .value(true)
        )
      )
  )
}

@MainActor
@Test
func persistedTurnPublishesAggregatedDiffSnapshotsAfterSuccessfulWrites()
  async throws
{
  let threadID = CodexStoredThreadID("thread/diff")
  let turnID = "turn/diff"
  let firstCall =
    #"{"type":"function_call","name":"write_workspace_file","arguments":"{}","call_id":"call-a"}"#
  let secondCall =
    #"{"type":"function_call","name":"write_workspace_file","arguments":"{}","call_id":"call-b"}"#
  let firstOutput =
    #"{"type":"function_call_output","call_id":"call-a","output":"ok"}"#
  let secondOutput =
    #"{"type":"function_call_output","call_id":"call-b","output":"ok"}"#
  let assistantItem =
    #"{"type":"message","role":"assistant","content":[{"type":"output_text","text":"done"}]}"#
  let firstDiff =
    "--- a/One.swift\n+++ b/One.swift\n@@ -1 +1 @@\n-old\n+one\n"
  let secondDiff =
    "--- a/Two.swift\n+++ b/Two.swift\n@@ -1 +1 @@\n-old\n+two\n"
  let history = PersistedTurnHistoryFixture(
    startResults: [
      .init(turn: initialPersistedTurn(id: turnID))
    ],
    priorResults: [
      .init(
        threadID: threadID,
        throughTurnID: nil,
        items: [],
        completeness: .complete
      )
    ]
  )
  let provider = PersistedTurnProviderFixture(
    batches: [
      .init(events: [
        .toolCallRequested(
          sequence: 1,
          requestID: turnID,
          name: "write_workspace_file",
          arguments: #"{"path":"One.swift","text":"one"}"#,
          callID: "call-a",
          itemJSON: firstCall
        ),
        .toolCallRequested(
          sequence: 2,
          requestID: turnID,
          name: "write_workspace_file",
          arguments: #"{"path":"Two.swift","text":"two"}"#,
          callID: "call-b",
          itemJSON: secondCall
        ),
        .responseCompleted(
          sequence: 3,
          requestID: turnID,
          responseID: "response/tools",
          usage: nil,
          endTurn: false
        ),
      ]),
      .init(events: [
        .responseItemDone(
          sequence: 4,
          requestID: turnID,
          itemJSON: assistantItem
        ),
        .responseCompleted(
          sequence: 5,
          requestID: turnID,
          responseID: "response/done",
          usage: nil,
          endTurn: true
        ),
      ]),
    ]
  )
  let tools = PersistedTurnToolFixture(
    outputs: [
      .success(
        .init(
          itemJSON: firstOutput,
          workspaceDiff: firstDiff
        )
      ),
      .success(
        .init(
          itemJSON: secondOutput,
          workspaceDiff: secondDiff
        )
      ),
    ]
  )
  let coordinator = CodexPersistedTurnCoordinator(
    history: history,
    provider: provider,
    toolExecutor: tools
  )
  var notifications: [CodexAppServerTurnNotification] = []

  _ = try await coordinator.run(
    startRequestID: .string("start/diff"),
    priorRequestID: .string("prior/diff"),
    params: .init(
      threadID: threadID,
      input: [.text(text: "change both", textElements: [])]
    ),
    cancellation: CodexTurnCancellation(),
    onTurnNotification: { notifications.append($0) }
  )

  #expect(
    notifications == [
      .turnDiffUpdated(
        .init(
          threadID: threadID,
          turnID: turnID,
          diff: firstDiff
        )
      ),
      .turnDiffUpdated(
        .init(
          threadID: threadID,
          turnID: turnID,
          diff: firstDiff + "\n" + secondDiff
        )
      ),
    ]
  )
}

@MainActor
@Test
func persistedTurnDoesNotCommitProviderItemsBeforeCompletion() async {
  let threadID = CodexStoredThreadID("thread/failure")
  let partialItem =
    #"{"type":"message","role":"assistant","content":[]}"#
  let history = PersistedTurnHistoryFixture(
    startResults: [
      .init(turn: initialPersistedTurn(id: "turn/failure"))
    ],
    priorResults: [
      .init(
        threadID: threadID,
        throughTurnID: nil,
        items: [],
        completeness: .complete
      )
    ]
  )
  let provider = PersistedTurnProviderFixture(
    batches: [
      .init(
        events: [
          .responseItemDone(
            sequence: 1,
            requestID: "turn/failure",
            itemJSON: partialItem
          )
        ],
        failure: .providerStopped
      )
    ]
  )
  let coordinator = CodexPersistedTurnCoordinator(
    history: history,
    provider: provider
  )

  do {
    _ = try await coordinator.run(
      startRequestID: .integer(1),
      priorRequestID: .integer(2),
      params: .init(
        threadID: threadID,
        input: [.text(text: "continue", textElements: [])]
      ),
      cancellation: CodexTurnCancellation()
    )
    Issue.record("Expected provider failure")
  } catch let error as PersistedTurnFixtureError {
    #expect(error == .providerStopped)
  } catch {
    Issue.record("Unexpected error: \(error)")
  }

  #expect(history.priorQueries.count == 1)
  #expect(history.commits.isEmpty)
}

@MainActor
@Test
func persistedTurnTreatsProviderTransportEventAsTerminalFailure() async {
  let threadID = CodexStoredThreadID("thread/transport-failure")
  let turnID = "turn/transport-failure"
  let history = PersistedTurnHistoryFixture(
    startResults: [
      .init(turn: initialPersistedTurn(id: turnID))
    ],
    priorResults: [
      .init(
        threadID: threadID,
        throughTurnID: nil,
        items: [],
        completeness: .complete
      )
    ]
  )
  let provider = PersistedTurnProviderFixture(
    batches: [
      .init(events: [
        .realtime(
          sequence: 1,
          requestID: turnID,
          eventType: "provider_transport_error",
          payload: .object([
            "status": .integer(401),
            "code": .string("invalid_api_key"),
          ])
        )
      ])
    ]
  )
  let coordinator = CodexPersistedTurnCoordinator(
    history: history,
    provider: provider
  )
  var observedEvents: [CodexCoreProviderEvent] = []

  do {
    _ = try await coordinator.run(
      startRequestID: .string("start/transport-failure"),
      priorRequestID: .string("prior/transport-failure"),
      params: .init(
        threadID: threadID,
        input: [.text(text: "continue", textElements: [])]
      ),
      cancellation: CodexTurnCancellation(),
      onProviderEvent: { observedEvents.append($0) }
    )
    Issue.record("Expected provider transport failure")
  } catch let error as CodexPersistedTurnCoordinatorError {
    #expect(error == .providerTransportFailure)
  } catch {
    Issue.record("Unexpected error: \(error)")
  }

  #expect(observedEvents.count == 1)
  #expect(history.commits.isEmpty)
}

@MainActor
@Test
func persistedTurnTimesOutWhenProviderProducesNoFirstEvent() async {
  let threadID = CodexStoredThreadID("thread/first-event-timeout")
  let turnID = "turn/first-event-timeout"
  let history = PersistedTurnHistoryFixture(
    startResults: [
      .init(turn: initialPersistedTurn(id: turnID))
    ],
    priorResults: [
      .init(
        threadID: threadID,
        throughTurnID: nil,
        items: [],
        completeness: .complete
      )
    ]
  )
  let coordinator = CodexPersistedTurnCoordinator(
    history: history,
    provider: PersistedTurnDelayedSilentProviderFixture(
      delay: .milliseconds(200)
    ),
    providerActivityTimeout: .milliseconds(10)
  )

  do {
    _ = try await coordinator.run(
      startRequestID: .string("start/first-event-timeout"),
      priorRequestID: .string("prior/first-event-timeout"),
      params: .init(
        threadID: threadID,
        input: [.text(text: "continue", textElements: [])]
      ),
      cancellation: CodexTurnCancellation()
    )
    Issue.record("Expected first provider event timeout")
  } catch is CodexOfficialProviderActivityTimeoutError {
  } catch {
    Issue.record("Unexpected error: \(error)")
  }

  #expect(history.commits.isEmpty)
}

@MainActor
@Test
func persistedTurnTimesOutAfterResponseStartedBecomesInactive() async {
  let threadID = CodexStoredThreadID("thread/activity-timeout")
  let turnID = "turn/activity-timeout"
  let history = PersistedTurnHistoryFixture(
    startResults: [.init(turn: initialPersistedTurn(id: turnID))],
    priorResults: [
      .init(
        threadID: threadID,
        throughTurnID: nil,
        items: [],
        completeness: .complete
      )
    ]
  )
  let coordinator = CodexPersistedTurnCoordinator(
    history: history,
    provider: PersistedTurnStalledAfterStartProviderFixture(),
    providerActivityTimeout: .milliseconds(10)
  )

  do {
    _ = try await coordinator.run(
      startRequestID: .string("start/activity-timeout"),
      priorRequestID: .string("prior/activity-timeout"),
      params: .init(
        threadID: threadID,
        input: [.text(text: "continue", textElements: [])]
      ),
      cancellation: CodexTurnCancellation()
    )
    Issue.record("Expected provider activity timeout")
  } catch is CodexOfficialProviderActivityTimeoutError {
  } catch {
    Issue.record("Unexpected error: \(error)")
  }

  #expect(history.commits.isEmpty)
}

@MainActor
@Test
func persistedTurnDoesNotPromoteFailedTurnItemsIntoLaterRun() async throws {
  let threadID = CodexStoredThreadID("thread/retry")
  let frozenPrior =
    #"{"type":"message","role":"assistant","content":[{"type":"output_text","text":"stable"}]}"#
  let firstProviderItem =
    #"{"type":"function_call","name":"tool","arguments":"{}","call_id":"call-1"}"#
  let firstToolOutput =
    #"{"type":"function_call_output","call_id":"call-1","output":"ok"}"#
  let failedPartialItem =
    #"{"type":"message","role":"assistant","content":[{"type":"output_text","text":"partial"}]}"#
  let finalItem =
    #"{"type":"message","role":"assistant","content":[{"type":"output_text","text":"fresh"}]}"#
  let history = PersistedTurnHistoryFixture(
    startResults: [
      .init(turn: initialPersistedTurn(id: "turn/failed")),
      .init(turn: initialPersistedTurn(id: "turn/retry")),
    ],
    priorResults: [
      .init(
        threadID: threadID,
        throughTurnID: "turn/stable",
        items: [frozenPrior],
        completeness: .complete
      ),
      .init(
        threadID: threadID,
        throughTurnID: "turn/stable",
        items: [frozenPrior],
        completeness: .complete
      ),
    ]
  )
  let provider = PersistedTurnProviderFixture(
    batches: [
      .init(events: [
        .toolCallRequested(
          sequence: 1,
          requestID: "turn/failed",
          name: "tool",
          arguments: "{}",
          callID: "call-1",
          itemJSON: firstProviderItem
        ),
        .responseCompleted(
          sequence: 2,
          requestID: "turn/failed",
          responseID: "response/nonterminal",
          usage: nil,
          endTurn: false
        ),
      ]),
      .init(
        events: [
          .responseItemDone(
            sequence: 3,
            requestID: "turn/failed",
            itemJSON: failedPartialItem
          )
        ],
        failure: .providerStopped
      ),
      .init(events: [
        .responseItemDone(
          sequence: 4,
          requestID: "turn/retry",
          itemJSON: finalItem
        ),
        .responseCompleted(
          sequence: 5,
          requestID: "turn/retry",
          responseID: "response/terminal",
          usage: nil,
          endTurn: true
        ),
      ]),
    ]
  )
  let tools = PersistedTurnToolFixture(
    outputs: [
      .success(.init(itemJSON: firstToolOutput))
    ]
  )
  let coordinator = CodexPersistedTurnCoordinator(
    history: history,
    provider: provider,
    toolExecutor: tools
  )

  do {
    _ = try await coordinator.run(
      startRequestID: .string("start/failed"),
      priorRequestID: .string("prior/failed"),
      params: .init(
        threadID: threadID,
        input: [.text(text: "first", textElements: [])]
      ),
      cancellation: CodexTurnCancellation()
    )
    Issue.record("Expected first run to fail")
  } catch let error as PersistedTurnFixtureError {
    #expect(error == .providerStopped)
  }

  let retry = try await coordinator.run(
    startRequestID: .string("start/retry"),
    priorRequestID: .string("prior/retry"),
    params: .init(
      threadID: threadID,
      input: [.text(text: "retry", textElements: [])]
    ),
    cancellation: CodexTurnCancellation()
  )

  #expect(retry.turnID == "turn/retry")
  #expect(retry.frozenPriorInputItems == [frozenPrior])
  #expect(retry.currentTurnInputItems == [finalItem])
  #expect(provider.requests.count == 3)
  #expect(
    provider.requests[2].frozenPriorInputItems
      == [frozenPrior]
  )
  #expect(provider.requests[2].currentTurnInputItems.isEmpty)
  #expect(
    !provider.requests[2].frozenPriorInputItems
      .contains(firstProviderItem)
  )
  #expect(
    !provider.requests[2].frozenPriorInputItems
      .contains(firstToolOutput)
  )
  #expect(
    !provider.requests[2].frozenPriorInputItems
      .contains(failedPartialItem)
  )
}

@MainActor
@Test
func persistedTurnRequiresTrueEndTurnToFinish() async {
  let threadID = CodexStoredThreadID("thread/nonterminal")
  let history = PersistedTurnHistoryFixture(
    startResults: [
      .init(turn: initialPersistedTurn(id: "turn/nonterminal"))
    ],
    priorResults: [
      .init(
        threadID: threadID,
        throughTurnID: nil,
        items: [],
        completeness: .complete
      )
    ]
  )
  let provider = PersistedTurnProviderFixture(
    batches: [
      .init(events: [
        .responseCompleted(
          sequence: 1,
          requestID: "turn/nonterminal",
          responseID: "response/nonterminal",
          usage: nil,
          endTurn: nil
        )
      ])
    ]
  )
  let coordinator = CodexPersistedTurnCoordinator(
    history: history,
    provider: provider
  )

  do {
    _ = try await coordinator.run(
      startRequestID: .integer(10),
      priorRequestID: .integer(11),
      params: .init(
        threadID: threadID,
        input: [.text(text: "continue", textElements: [])]
      ),
      cancellation: CodexTurnCancellation()
    )
    Issue.record("Expected a nonterminal completion failure")
  } catch let error as CodexPersistedTurnCoordinatorError {
    #expect(error == .nonTerminalCompletionWithoutToolRequest)
  } catch {
    Issue.record("Unexpected error: \(error)")
  }

  #expect(history.commits.count == 1)
  #expect(
    history.commits[0].completion
      == .value(
        .init(responseID: "response/nonterminal")
      )
  )
}

@MainActor
@Test
func persistedTurnPairsToolExecutionFailuresWithFunctionAndCustomOutputs()
  async throws
{
  let threadID = CodexStoredThreadID("thread/tool-errors")
  let turnID = "turn/tool-errors"
  let functionCall =
    #"{"type":"function_call","name":"exec_command","arguments":"{}","call_id":"call-function"}"#
  let customCall =
    #"{"type":"custom_tool_call","name":"apply_patch","input":"patch","call_id":"call-custom"}"#
  let assistantItem =
    #"{"type":"message","role":"assistant","content":[{"type":"output_text","text":"handled"}]}"#
  let history = PersistedTurnHistoryFixture(
    startResults: [
      .init(turn: initialPersistedTurn(id: turnID))
    ],
    priorResults: [
      .init(
        threadID: threadID,
        throughTurnID: nil,
        items: [],
        completeness: .complete
      )
    ]
  )
  let provider = PersistedTurnProviderFixture(
    batches: [
      .init(events: [
        .toolCallRequested(
          sequence: 1,
          requestID: turnID,
          name: "exec_command",
          arguments: "{}",
          callID: "call-function",
          itemJSON: functionCall
        ),
        .toolCallRequested(
          sequence: 2,
          requestID: turnID,
          name: "apply_patch",
          arguments: "patch",
          callID: "call-custom",
          itemJSON: customCall
        ),
        .responseCompleted(
          sequence: 3,
          requestID: turnID,
          responseID: "response/tools",
          usage: nil,
          endTurn: false
        ),
      ]),
      .init(events: [
        .responseItemDone(
          sequence: 4,
          requestID: turnID,
          itemJSON: assistantItem
        ),
        .responseCompleted(
          sequence: 5,
          requestID: turnID,
          responseID: "response/done",
          usage: nil,
          endTurn: true
        ),
      ]),
    ]
  )
  let tools = PersistedTurnToolFixture(
    outputs: [
      .failure(PersistedTurnFixtureError.toolStopped),
      .failure(PersistedTurnFixtureError.toolStopped),
    ]
  )
  let coordinator = CodexPersistedTurnCoordinator(
    history: history,
    provider: provider,
    toolExecutor: tools
  )

  let result = try await coordinator.run(
    startRequestID: .string("start/tool-errors"),
    priorRequestID: .string("prior/tool-errors"),
    params: .init(
      threadID: threadID,
      input: [.text(text: "run tools", textElements: [])]
    ),
    cancellation: CodexTurnCancellation()
  )

  #expect(provider.requests.count == 2)
  let followUpItems = provider.requests[1].currentTurnInputItems
  #expect(followUpItems.count == 4)
  #expect(followUpItems[0] == functionCall)
  #expect(followUpItems[1] == customCall)
  let functionOutput = try persistedTurnToolOutput(followUpItems[2])
  let customOutput = try persistedTurnToolOutput(followUpItems[3])
  #expect(
    functionOutput
      == .init(
        type: "function_call_output",
        callID: "call-function",
        output: "Tool execution failed: toolStopped"
      )
  )
  #expect(
    customOutput
      == .init(
        type: "custom_tool_call_output",
        callID: "call-custom",
        output: "Tool execution failed: toolStopped"
      )
  )
  #expect(
    result.currentTurnInputItems
      == followUpItems + [assistantItem]
  )
  #expect(history.commits.count == 4)
  #expect(history.commits[1].entries[0].source == .localTool)
  #expect(history.commits[1].entries[0].itemJSON == followUpItems[2])
  #expect(history.commits[2].entries[0].source == .localTool)
  #expect(history.commits[2].entries[0].itemJSON == followUpItems[3])
}

@MainActor
@Test
func persistedTurnToolCancellationDoesNotBecomeToolOutput() async {
  let threadID = CodexStoredThreadID("thread/tool-cancel")
  let turnID = "turn/tool-cancel"
  let toolCall =
    #"{"type":"function_call","name":"exec_command","arguments":"{}","call_id":"call-cancel"}"#
  let history = PersistedTurnHistoryFixture(
    startResults: [
      .init(turn: initialPersistedTurn(id: turnID))
    ],
    priorResults: [
      .init(
        threadID: threadID,
        throughTurnID: nil,
        items: [],
        completeness: .complete
      )
    ]
  )
  let provider = PersistedTurnProviderFixture(
    batches: [
      .init(events: [
        .toolCallRequested(
          sequence: 1,
          requestID: turnID,
          name: "exec_command",
          arguments: "{}",
          callID: "call-cancel",
          itemJSON: toolCall
        ),
        .responseCompleted(
          sequence: 2,
          requestID: turnID,
          responseID: "response/tools",
          usage: nil,
          endTurn: false
        ),
      ])
    ]
  )
  let tools = PersistedTurnToolFixture(
    outputs: [.failure(CancellationError())]
  )
  let coordinator = CodexPersistedTurnCoordinator(
    history: history,
    provider: provider,
    toolExecutor: tools
  )

  do {
    _ = try await coordinator.run(
      startRequestID: .string("start/tool-cancel"),
      priorRequestID: .string("prior/tool-cancel"),
      params: .init(
        threadID: threadID,
        input: [.text(text: "cancel tool", textElements: [])]
      ),
      cancellation: CodexTurnCancellation()
    )
    Issue.record("Expected cancellation")
  } catch is CancellationError {
  } catch {
    Issue.record("Unexpected error: \(error)")
  }

  #expect(provider.requests.count == 1)
  #expect(history.commits.count == 1)
  #expect(history.commits[0].entries.map(\.itemJSON) == [toolCall])
}

private struct PersistedTurnToolOutputFixture:
  Decodable,
  Equatable
{
  let type: String
  let callID: String
  let output: String

  enum CodingKeys: String, CodingKey {
    case type
    case callID = "call_id"
    case output
  }
}

private func persistedTurnToolOutput(
  _ itemJSON: String
) throws -> PersistedTurnToolOutputFixture {
  try JSONDecoder().decode(
    PersistedTurnToolOutputFixture.self,
    from: Data(itemJSON.utf8)
  )
}

private func initialPersistedTurn(id: String) -> CodexStoredTurn {
  CodexStoredTurn(
    id: id,
    items: [],
    itemsView: .notLoaded,
    status: .inProgress
  )
}

extension CodexWireOptional {
  fileprivate var concreteValue: Value? {
    if case .value(let value) = self {
      return value
    }
    return nil
  }
}
