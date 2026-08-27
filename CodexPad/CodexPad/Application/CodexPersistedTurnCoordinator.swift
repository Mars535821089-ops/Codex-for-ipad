import Foundation

#if SWIFT_PACKAGE
  import CodexPadDomain
  import CodexPadProtocolBridge
#endif

@MainActor
public protocol CodexPersistedTurnHistory: AnyObject {
  func startStableTurn(
    id: CodexAppServerRequestID,
    params: CodexTurnStartParams
  ) throws -> CodexTurnStartResult

  func priorInputItems(
    id: CodexAppServerRequestID,
    params: CodexPriorInputItemsParams
  ) throws -> CodexPriorInputItemsResult

  func commitRawHistory(
    _ command: CodexRawHistoryCommit
  ) throws -> CodexRawHistoryCommittedEvent
}

extension CodexSessionStore: CodexPersistedTurnHistory {}

public struct CodexPersistedTurnProviderRequest:
  Equatable,
  Sendable
{
  public let requestID: String
  public let roundIndex: Int
  public let threadID: CodexStoredThreadID
  public let turnID: String
  public let startParams: CodexTurnStartParams
  public let frozenPriorInputItems: [String]
  public let currentTurnInputItems: [String]
  public let steeringInput: [CodexStoredUserInput]

  public init(
    requestID: String,
    roundIndex: Int,
    threadID: CodexStoredThreadID,
    turnID: String,
    startParams: CodexTurnStartParams,
    frozenPriorInputItems: [String],
    currentTurnInputItems: [String],
    steeringInput: [CodexStoredUserInput] = []
  ) {
    self.requestID = requestID
    self.roundIndex = roundIndex
    self.threadID = threadID
    self.turnID = turnID
    self.startParams = startParams
    self.frozenPriorInputItems = frozenPriorInputItems
    self.currentTurnInputItems = currentTurnInputItems
    self.steeringInput = steeringInput
  }
}

@MainActor
public protocol CodexPersistedTurnProvider: AnyObject {
  func stream(
    _ request: CodexPersistedTurnProviderRequest,
    cancellation: CodexTurnCancellation
  ) async -> AsyncThrowingStream<CodexCoreProviderEvent, Error>
}

public struct CodexPersistedTurnToolRequest:
  Equatable,
  Sendable
{
  public let threadID: CodexStoredThreadID
  public let turnID: String
  public let roundIndex: Int
  public let name: String
  public let arguments: String
  public let callID: String
  public let itemJSON: String

  public init(
    threadID: CodexStoredThreadID,
    turnID: String,
    roundIndex: Int,
    name: String,
    arguments: String,
    callID: String,
    itemJSON: String
  ) {
    self.threadID = threadID
    self.turnID = turnID
    self.roundIndex = roundIndex
    self.name = name
    self.arguments = arguments
    self.callID = callID
    self.itemJSON = itemJSON
  }
}

public struct CodexPersistedTurnLocalToolOutput:
  Equatable,
  Sendable
{
  public let itemJSON: String
  public let workspaceDiff: String?
  public let fileChanges: [CodexFileUpdateChange]?

  public init(
    itemJSON: String,
    workspaceDiff: String? = nil,
    fileChanges: [CodexFileUpdateChange]? = nil
  ) {
    self.itemJSON = itemJSON
    self.workspaceDiff = workspaceDiff
    self.fileChanges = fileChanges
  }
}

@MainActor
public protocol CodexPersistedTurnToolExecutor: AnyObject {
  func execute(
    _ request: CodexPersistedTurnToolRequest,
    cancellation: CodexTurnCancellation
  ) async throws -> CodexPersistedTurnLocalToolOutput
}

public struct CodexPersistedTurnResult:
  Equatable,
  Sendable
{
  public let threadID: CodexStoredThreadID
  public let turnID: String
  public let frozenPriorInputItems: [String]
  public let currentTurnInputItems: [String]
  public let completions: [CodexRawHistoryCompletion]

  public init(
    threadID: CodexStoredThreadID,
    turnID: String,
    frozenPriorInputItems: [String],
    currentTurnInputItems: [String],
    completions: [CodexRawHistoryCompletion]
  ) {
    self.threadID = threadID
    self.turnID = turnID
    self.frozenPriorInputItems = frozenPriorInputItems
    self.currentTurnInputItems = currentTurnInputItems
    self.completions = completions
  }
}

public enum CodexPersistedTurnCoordinatorError:
  Error,
  Equatable,
  Sendable
{
  case invalidMaximumProviderRounds
  case invalidInitialTurn
  case priorThreadIDMismatch(
    expected: CodexStoredThreadID,
    actual: CodexStoredThreadID
  )
  case providerRequestIDMismatch(expected: String, actual: String)
  case providerTransportFailure
  case multipleResponseCompletions
  case providerEventAfterCompletion
  case missingResponseCompletion
  case terminalCompletionWithToolRequest
  case nonTerminalCompletionWithoutToolRequest
  case toolExecutorUnavailable
  case rawCommitMismatch
  case providerRoundLimitReached
}

@MainActor
public final class CodexPersistedTurnCoordinator {
  private let history: any CodexPersistedTurnHistory
  private let provider: any CodexPersistedTurnProvider
  private let toolExecutor: (any CodexPersistedTurnToolExecutor)?
  private let maximumProviderRounds: Int
  private let providerActivityTimeout: Duration

  public init(
    history: any CodexPersistedTurnHistory,
    provider: any CodexPersistedTurnProvider,
    toolExecutor: (any CodexPersistedTurnToolExecutor)? = nil,
    maximumProviderRounds: Int = 8,
    providerActivityTimeout: Duration = .seconds(30)
  ) {
    self.history = history
    self.provider = provider
    self.toolExecutor = toolExecutor
    self.maximumProviderRounds = maximumProviderRounds
    self.providerActivityTimeout = providerActivityTimeout
  }

  public func run(
    startRequestID: CodexAppServerRequestID,
    priorRequestID: CodexAppServerRequestID,
    params: CodexTurnStartParams,
    cancellation: CodexTurnCancellation,
    onTurnNotification:
      (CodexAppServerTurnNotification) -> Void = { _ in },
    onProviderEvent:
      (CodexCoreProviderEvent) -> Void = { _ in },
    onToolOutput:
      (
        CodexPersistedTurnToolRequest,
        CodexPersistedTurnLocalToolOutput
      ) -> Void = { _, _ in },
    takeSteeringInput:
      () -> [CodexStoredUserInput] = { [] }
  ) async throws -> CodexPersistedTurnResult {
    guard maximumProviderRounds > 0 else {
      throw CodexPersistedTurnCoordinatorError
        .invalidMaximumProviderRounds
    }
    try cancellation.checkCancellation()

    let started = try history.startStableTurn(
      id: startRequestID,
      params: params
    )
    return try await continueRun(
      started: started,
      priorRequestID: priorRequestID,
      params: params,
      cancellation: cancellation,
      onTurnNotification: onTurnNotification,
      onProviderEvent: onProviderEvent,
      onToolOutput: onToolOutput,
      takeSteeringInput: takeSteeringInput
    )
  }

  /// Continues a turn whose released `turn/start` response has already been
  /// returned to the desktop renderer. This keeps the renderer request/response
  /// timing exact while reusing the same persisted provider and raw-history
  /// pipeline without issuing a second `turn/start`.
  public func continueRun(
    started: CodexTurnStartResult,
    priorRequestID: CodexAppServerRequestID,
    params: CodexTurnStartParams,
    cancellation: CodexTurnCancellation,
    onTurnNotification:
      (CodexAppServerTurnNotification) -> Void = { _ in },
    onProviderEvent:
      (CodexCoreProviderEvent) -> Void = { _ in },
    onToolOutput:
      (
        CodexPersistedTurnToolRequest,
        CodexPersistedTurnLocalToolOutput
      ) -> Void = { _, _ in },
    takeSteeringInput:
      () -> [CodexStoredUserInput] = { [] }
  ) async throws -> CodexPersistedTurnResult {
    guard maximumProviderRounds > 0 else {
      throw CodexPersistedTurnCoordinatorError
        .invalidMaximumProviderRounds
    }
    try cancellation.checkCancellation()
    guard CodexResumedTurnViewState.isInitial(started.turn) else {
      throw CodexPersistedTurnCoordinatorError.invalidInitialTurn
    }
    let turnID = started.turn.id

    try cancellation.checkCancellation()
    let prior = try history.priorInputItems(
      id: priorRequestID,
      params: CodexPriorInputItemsParams(
        threadID: params.threadID,
        beforeTurnID: .value(turnID)
      )
    )
    guard prior.threadID == params.threadID else {
      throw CodexPersistedTurnCoordinatorError.priorThreadIDMismatch(
        expected: params.threadID,
        actual: prior.threadID
      )
    }

    let frozenPriorInputItems = prior.items
    var currentTurnInputItems: [String] = []
    var completions: [CodexRawHistoryCompletion] = []
    var workspaceDiffs: [String] = []
    var nextOrder: UInt64 = 0
    var nextSteeringInput: [CodexStoredUserInput] = []

    for roundIndex in 0..<maximumProviderRounds {
      try cancellation.checkCancellation()
      let steeringInput = nextSteeringInput.isEmpty
        ? takeSteeringInput()
        : nextSteeringInput
      nextSteeringInput = []
      let providerRequest = CodexPersistedTurnProviderRequest(
        requestID: turnID,
        roundIndex: roundIndex,
        threadID: params.threadID,
        turnID: turnID,
        startParams: params,
        frozenPriorInputItems: frozenPriorInputItems,
        currentTurnInputItems: currentTurnInputItems,
        steeringInput: steeringInput
      )
      let upstream = await provider.stream(
        providerRequest,
        cancellation: cancellation
      )
      // The native provider can block while waiting for response headers. The
      // activity deadline only starts after the stream yields its first
      // element, so guard that initial phase separately to prevent a stalled
      // request from leaving the renderer in Thinking indefinitely.
      let firstEventStream = CodexOfficialProviderFirstEventDeadline.enforce(
        upstream,
        timeout: providerActivityTimeout
      )
      let stream = CodexOfficialProviderActivityDeadline.enforce(
        firstEventStream,
        timeout: providerActivityTimeout
      )
      var providerItemJSON: [String] = []
      var toolRequests: [CodexPersistedTurnToolRequest] = []
      var roundCompletion: CodexRawHistoryCompletion?

      for try await event in stream {
        try cancellation.checkCancellation()
        if roundCompletion != nil {
          throw CodexPersistedTurnCoordinatorError
            .providerEventAfterCompletion
        }
        try Self.requireRequestID(
          event,
          expected: providerRequest.requestID
        )
        onProviderEvent(event)
        if case let .realtime(_, _, eventType, _) = event,
          eventType == "provider_transport_error"
        {
          throw CodexPersistedTurnCoordinatorError
            .providerTransportFailure
        }

        switch event {
        case .responseStarted,
          .assistantTextDelta,
          .planStarted,
          .planDelta,
          .planCompleted,
          .realtime:
          break

        case .toolCallRequested(
          _,
          _,
          let
            name,
          let
            arguments,
          let
            callID,
          let
            itemJSON
        ):
          providerItemJSON.append(itemJSON)
          toolRequests.append(
            CodexPersistedTurnToolRequest(
              threadID: params.threadID,
              turnID: turnID,
              roundIndex: roundIndex,
              name: name,
              arguments: arguments,
              callID: callID,
              itemJSON: itemJSON
            )
          )

        case .responseItemDone(_, _, let itemJSON):
          providerItemJSON.append(itemJSON)

        case .responseCompleted(
          _,
          _,
          let
            responseID,
          let
            usage,
          let
            endTurn
        ):
          guard roundCompletion == nil else {
            throw CodexPersistedTurnCoordinatorError
              .multipleResponseCompletions
          }
          roundCompletion = CodexRawHistoryCompletion(
            responseID: responseID,
            usage: usage.map(CodexWireOptional.value)
              ?? .omitted,
            endTurn: endTurn.map(CodexWireOptional.value)
              ?? .omitted
          )
        }
      }

      try cancellation.checkCancellation()
      guard let roundCompletion else {
        throw CodexPersistedTurnCoordinatorError
          .missingResponseCompletion
      }
      let isTerminal = roundCompletion.endTurn == .value(true)
      if isTerminal, !toolRequests.isEmpty {
        throw CodexPersistedTurnCoordinatorError
          .terminalCompletionWithToolRequest
      }
      if !isTerminal, toolRequests.isEmpty {
        let command = CodexRawHistoryCommit(
          threadID: params.threadID,
          turnID: turnID,
          expectedNextOrder: nextOrder,
          entries: Self.entries(
            providerItemJSON,
            source: .provider,
            startingAt: nextOrder
          ),
          completion: .value(roundCompletion)
        )
        try commit(command)
        currentTurnInputItems.append(
          contentsOf: providerItemJSON
        )
        completions.append(roundCompletion)
        throw CodexPersistedTurnCoordinatorError
          .nonTerminalCompletionWithoutToolRequest
      }

      let providerCommand = CodexRawHistoryCommit(
        threadID: params.threadID,
        turnID: turnID,
        expectedNextOrder: nextOrder,
        entries: Self.entries(
          providerItemJSON,
          source: .provider,
          startingAt: nextOrder
        ),
        completion: .value(roundCompletion)
      )
      try commit(providerCommand)
      nextOrder += UInt64(providerItemJSON.count)
      currentTurnInputItems.append(contentsOf: providerItemJSON)
      completions.append(roundCompletion)

      if isTerminal {
        let lateSteeringInput = takeSteeringInput()
        if lateSteeringInput.isEmpty {
          return CodexPersistedTurnResult(
            threadID: params.threadID,
            turnID: turnID,
            frozenPriorInputItems: frozenPriorInputItems,
            currentTurnInputItems: currentTurnInputItems,
            completions: completions
          )
        }
        nextSteeringInput = lateSteeringInput
        continue
      }

      guard let toolExecutor else {
        throw CodexPersistedTurnCoordinatorError
          .toolExecutorUnavailable
      }
      for request in toolRequests {
        try cancellation.checkCancellation()
        let output: CodexPersistedTurnLocalToolOutput
        do {
          output = try await toolExecutor.execute(
            request,
            cancellation: cancellation
          )
        } catch is CancellationError {
          throw CancellationError()
        } catch {
          try Task.checkCancellation()
          try cancellation.checkCancellation()
          output = try Self.toolFailureOutput(
            request: request,
            error: error
          )
        }
        try cancellation.checkCancellation()
        onToolOutput(request, output)
        if let workspaceDiff = output.workspaceDiff {
          workspaceDiffs.append(workspaceDiff)
          onTurnNotification(
            .turnDiffUpdated(
              CodexTurnDiffUpdatedNotification(
                threadID: params.threadID,
                turnID: turnID,
                diff: workspaceDiffs.joined(separator: "\n")
              )
            )
          )
        }
        let command = CodexRawHistoryCommit(
          threadID: params.threadID,
          turnID: turnID,
          expectedNextOrder: nextOrder,
          entries: [
            CodexRawHistoryEntry(
              order: nextOrder,
              source: .localTool,
              itemJSON: output.itemJSON
            )
          ]
        )
        try commit(command)
        nextOrder += 1
        currentTurnInputItems.append(output.itemJSON)
      }
    }

    throw CodexPersistedTurnCoordinatorError
      .providerRoundLimitReached
  }

  private static func toolFailureOutput(
    request: CodexPersistedTurnToolRequest,
    error: any Error
  ) throws -> CodexPersistedTurnLocalToolOutput {
    let item = CodexPersistedTurnToolFailureOutput(
      type: outputItemType(for: request),
      callID: request.callID,
      output: "Tool execution failed: \(String(describing: error))"
    )
    let data = try JSONEncoder().encode(item)
    return CodexPersistedTurnLocalToolOutput(
      itemJSON: String(decoding: data, as: UTF8.self)
    )
  }

  private static func outputItemType(
    for request: CodexPersistedTurnToolRequest
  ) -> String {
    guard
      let object = try? JSONSerialization.jsonObject(
        with: Data(request.itemJSON.utf8)
      ) as? [String: Any],
      object["type"] as? String == "custom_tool_call"
    else {
      return "function_call_output"
    }
    return "custom_tool_call_output"
  }

  private func commit(
    _ command: CodexRawHistoryCommit
  ) throws {
    _ = try command.encodedData()
    let event = try history.commitRawHistory(command)
    let completion: CodexRawHistoryCompletion?
    if case .value(let value) = command.completion {
      completion = value
    } else {
      completion = nil
    }
    guard event.threadID == command.threadID,
      event.turnID == command.turnID,
      event.expectedNextOrder == command.expectedNextOrder,
      event.entries == command.entries,
      event.completion == completion
    else {
      throw CodexPersistedTurnCoordinatorError
        .rawCommitMismatch
    }
  }

  private static func entries(
    _ itemJSON: [String],
    source: CodexRawHistorySource,
    startingAt firstOrder: UInt64
  ) -> [CodexRawHistoryEntry] {
    itemJSON.enumerated().map { offset, itemJSON in
      CodexRawHistoryEntry(
        order: firstOrder + UInt64(offset),
        source: source,
        itemJSON: itemJSON
      )
    }
  }

  private static func requireRequestID(
    _ event: CodexCoreProviderEvent,
    expected: String
  ) throws {
    let actual: String
    switch event {
    case .responseStarted(_, let requestID, _),
      .assistantTextDelta(_, let requestID, _),
      .planStarted(_, let requestID, _),
      .planDelta(_, let requestID, _, _),
      .planCompleted(_, let requestID, _, _),
      .toolCallRequested(_, let requestID, _, _, _, _),
      .responseItemDone(_, let requestID, _),
      .realtime(_, let requestID, _, _),
      .responseCompleted(_, let requestID, _, _, _):
      actual = requestID
    }
    guard actual == expected else {
      throw
        CodexPersistedTurnCoordinatorError
        .providerRequestIDMismatch(
          expected: expected,
          actual: actual
        )
    }
  }
}

private struct CodexPersistedTurnToolFailureOutput: Encodable {
  let type: String
  let callID: String
  let output: String

  enum CodingKeys: String, CodingKey {
    case type
    case callID = "call_id"
    case output
  }
}
