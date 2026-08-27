#if SWIFT_PACKAGE
import CodexPadDomain
import CodexPadProtocolBridge
#endif
import Foundation
import Observation

public enum CodexSessionStoreError: Error, Equatable, Sendable {
    case transportUnavailable
    case invalidReply
    case replyIDMismatch(
        expected: CodexAppServerRequestID,
        actual: CodexAppServerRequestID
    )
    case appServerError(
        code: Int64,
        message: String,
        data: CodexJSONValue?
    )
    case resumedThreadIDMismatch(
        expected: CodexStoredThreadID,
        actual: CodexStoredThreadID
    )
}

@Observable
@MainActor
public final class CodexSessionStore {
    public private(set) var state: CodexSessionState
    public private(set) var lastApplyProblem: ApplyResult?
    public private(set) var lastTransportProblem: String?
    public private(set) var threadListPage: CodexThreadPage?
    public private(set) var threadReadResult: CodexThreadReadResult?
    public private(set) var threadResumeResult: CodexThreadResumeResult?
    public private(set) var threadResumeResultsByThreadID:
        [CodexStoredThreadID: CodexThreadResumeResult]
    public private(set) var resumedTurnState: CodexResumedTurnViewState
    public private(set) var priorInputItemsResult:
        CodexPriorInputItemsResult?
    public private(set) var lastRawHistoryCommitEvent:
        CodexRawHistoryCommittedEvent?
    public private(set) var lastStableCompactStartedEvent:
        CodexStableCompactStartedEvent?
    public private(set) var lastShellCommandStartedEvent:
        CodexShellCommandStartedEvent?
    public private(set) var lastShellCommandCompletedEvent:
        CodexShellCommandCompletedEvent?
    public private(set) var threadSearchPage: CodexThreadSearchPage?
    public private(set) var threadSectionPage: CodexThreadSectionPage?
    public private(set) var threadMetadataUpdateResult:
        CodexThreadMetadataUpdateResult?
    public private(set) var appServerThreadSettings:
        [CodexStoredThreadID: CodexAppServerThreadSettings]
    public private(set) var lastThreadSettingsNotification:
        CodexThreadSettingsUpdatedNotification?
    public private(set) var pendingAppServerNotifications:
        [CodexAppServerNotification]
    public var selectedWorkspaceID: UUID? {
        didSet {
            guard selectedWorkspaceID != oldValue else {
                return
            }
            workspaceSelectionPersistence?(selectedWorkspaceID)
        }
    }
    public var selectedThreadID: UUID?
    private let transport: (any CodexCoreTransport)?
    private var subscribedStoredThreadIDs: Set<CodexStoredThreadID>
    private var workspaceSelectionPersistence:
        ((UUID?) -> Void)?

    public init(
        state: CodexSessionState = CodexSessionState(),
        transport: (any CodexCoreTransport)? = nil,
        initialTransportProblem: String? = nil
    ) {
        self.state = state
        self.transport = transport
        resumedTurnState = CodexResumedTurnViewState()
        appServerThreadSettings = [:]
        threadResumeResultsByThreadID = [:]
        pendingAppServerNotifications = []
        subscribedStoredThreadIDs = []
        lastTransportProblem = initialTransportProblem
    }

    public func setWorkspaceSelectionPersistence(
        _ persistence: @escaping (UUID?) -> Void
    ) {
        workspaceSelectionPersistence = persistence
        persistence(selectedWorkspaceID)
    }

    public func threadResumeResult(
        for threadID: CodexStoredThreadID
    ) -> CodexThreadResumeResult? {
        threadResumeResultsByThreadID[threadID]
    }

    @discardableResult
    public func listThreads(
        id: CodexAppServerRequestID,
        params: CodexThreadListParams
    ) throws -> CodexThreadPage {
        do {
            let result: CodexThreadPage = try performThreadRequest(
                .list(id: id, params: params),
                expectedID: id
            )
            threadListPage = result
            lastTransportProblem = nil
            return result
        } catch {
            lastTransportProblem = Self.publicTransportProblem(error)
            throw error
        }
    }

    public func loadedStoredThreads(
        cursor: String?,
        limit: Int?
    ) throws -> CodexDesktopLoadedThreadPage {
        let ids = subscribedStoredThreadIDs
            .map(\.rawValue)
            .sorted()
        let start: Int
        if let cursor {
            guard let cursorIndex = ids.firstIndex(of: cursor) else {
                throw CodexCoreEnvelopeError.invalidCommandPayload
            }
            start = ids.index(after: cursorIndex)
        } else {
            start = ids.startIndex
        }
        let pageLimit = limit ?? ids.count
        let end = min(ids.count, start + pageLimit)
        let pageIDs = ids[start..<end].map {
            CodexStoredThreadID(rawValue: $0)
        }
        let nextCursor = end < ids.count
            ? pageIDs.last?.rawValue
            : nil
        return CodexDesktopLoadedThreadPage(
            data: Array(pageIDs),
            nextCursor: nextCursor
        )
    }

    @discardableResult
    public func listModels(
        id: CodexAppServerRequestID,
        params: CodexModelListParams
    ) throws -> CodexModelListResponse {
        do {
            let result: CodexModelListResponse = try performModelRequest(
                .list(id: id, params: params),
                expectedID: id
            )
            lastTransportProblem = nil
            return result
        } catch {
            lastTransportProblem = Self.publicTransportProblem(error)
            throw error
        }
    }

    @discardableResult
    public func readThread(
        id: CodexAppServerRequestID,
        params: CodexThreadReadParams
    ) throws -> CodexThreadReadResult {
        do {
            let result: CodexThreadReadResult = try performThreadRequest(
                .read(id: id, params: params),
                expectedID: id
            )
            threadReadResult = result
            lastTransportProblem = nil
            return result
        } catch {
            lastTransportProblem = Self.publicTransportProblem(error)
            throw error
        }
    }

    @discardableResult
    public func resumeThread(
        id: CodexAppServerRequestID,
        params: CodexThreadResumeParams
    ) throws -> CodexThreadResumeResult {
        do {
            let result: CodexThreadResumeResult = try performThreadRequest(
                .resume(id: id, params: params),
                expectedID: id
            )
            guard result.thread.id.rawValue
                == params.threadID.rawValue
            else {
                throw CodexSessionStoreError.resumedThreadIDMismatch(
                    expected: params.threadID,
                    actual: result.thread.id
                )
            }
            threadResumeResult = result
            threadResumeResultsByThreadID[result.thread.id] = result
            subscribedStoredThreadIDs.insert(result.thread.id)
            lastTransportProblem = nil
            return result
        } catch {
            lastTransportProblem = Self.publicTransportProblem(error)
            throw error
        }
    }

    @discardableResult
    public func startThread(
        id: CodexAppServerRequestID,
        params: CodexThreadStartParams
    ) throws -> CodexThreadResumeResult {
        do {
            let result: CodexThreadResumeResult = try performThreadRequest(
                .start(id: id, params: params),
                expectedID: id
            )
            guard result.thread.forkedFromID == nil else {
                throw CodexSessionStoreError.invalidReply
            }
            try drainPendingEvents()
            threadResumeResult = result
            threadResumeResultsByThreadID[result.thread.id] = result
            subscribedStoredThreadIDs.insert(result.thread.id)
            lastTransportProblem = nil
            return result
        } catch {
            lastTransportProblem = Self.publicTransportProblem(error)
            throw error
        }
    }

    @discardableResult
    public func forkThread(
        id: CodexAppServerRequestID,
        params: CodexThreadForkParams
    ) throws -> CodexThreadResumeResult {
        do {
            let result: CodexThreadResumeResult = try performThreadRequest(
                .fork(id: id, params: params),
                expectedID: id
            )
            guard result.thread.forkedFromID == params.threadID else {
                throw CodexSessionStoreError.invalidReply
            }
            try drainPendingEvents()
            threadResumeResult = result
            threadResumeResultsByThreadID[result.thread.id] = result
            subscribedStoredThreadIDs.insert(result.thread.id)
            lastTransportProblem = nil
            return result
        } catch {
            lastTransportProblem = Self.publicTransportProblem(error)
            throw error
        }
    }

    public func selectResumedTurnThread(
        _ threadID: CodexStoredThreadID
    ) {
        resumedTurnState.selectThread(threadID)
    }

    public func clearResumedTurnSelection() {
        resumedTurnState.clearSelection()
    }

    @discardableResult
    public func startStableTurn(
        id: CodexAppServerRequestID,
        params: CodexTurnStartParams
    ) throws -> CodexTurnStartResult {
        guard let request = resumedTurnState.beginStart(
            id: id,
            params: params
        ) else {
            let error = CodexSessionStoreError.invalidReply
            lastTransportProblem = Self.publicTransportProblem(error)
            throw error
        }

        do {
            let result = try performTurnStartRequest(
                .start(id: id, params: params),
                expectedID: id
            )
            guard CodexResumedTurnViewState.isInitial(result.turn) else {
                resumedTurnState.failStart(
                    .invalidInitialTurn,
                    for: request
                )
                throw CodexSessionStoreError.invalidReply
            }
            resumedTurnState.receiveStartResult(result, for: request)
            try drainPendingEvents()
            lastTransportProblem = nil
            return result
        } catch {
            failStableTurnIfCurrent(error, request: request)
            lastTransportProblem = Self.publicTransportProblem(error)
            throw error
        }
    }

    /// Entry point for the released desktop Composer. Each submitted turn
    /// establishes the exact opaque thread selection before using the stable
    /// app-server `turn/start` request.
    @discardableResult
    public func startDesktopTurn(
        id: CodexAppServerRequestID,
        params: CodexTurnStartParams
    ) throws -> CodexTurnStartResult {
        // The released desktop renderer can carry both the legacy
        // permissions profile and the newer sandbox policy on turn/start.
        // The embedded core intentionally rejects that ambiguous pair;
        // permissions is the authoritative legacy anchor, so omit only the
        // redundant sandbox field at this transport boundary.
        var normalizedParams = params
        if case .value = normalizedParams.permissions,
           case .value = normalizedParams.sandboxPolicy
        {
            normalizedParams.sandboxPolicy = .omitted
        }
        selectResumedTurnThread(normalizedParams.threadID)
        return try startStableTurn(id: id, params: normalizedParams)
    }

    @discardableResult
    public func startStableCompaction(
        id: CodexAppServerRequestID,
        threadID: CodexStoredThreadID
    ) throws -> CodexStableCompactStartedEvent {
        lastStableCompactStartedEvent = nil
        let _: CodexThreadEmptyResponse = try performThreadRequest(
            .compactStart(id: id, threadID: threadID),
            expectedID: id
        )
        try drainPendingEvents()
        guard let started = lastStableCompactStartedEvent,
              started.threadID == threadID
        else {
            throw CodexSessionStoreError.invalidReply
        }
        lastTransportProblem = nil
        return started
    }

    public func receiveTurnNotification(
        _ notification: CodexAppServerTurnNotification,
        selectionGeneration: UInt64
    ) {
        resumedTurnState.receive(
            notification,
            selectionGeneration: selectionGeneration
        )
    }

    @discardableResult
    public func priorInputItems(
        id: CodexAppServerRequestID,
        params: CodexPriorInputItemsParams
    ) throws -> CodexPriorInputItemsResult {
        do {
            let result: CodexPriorInputItemsResult =
                try performRawHistoryRequest(
                    .priorInputItems(id: id, params: params),
                    expectedID: id
                )
            guard result.threadID == params.threadID else {
                throw CodexSessionStoreError.resumedThreadIDMismatch(
                    expected: params.threadID,
                    actual: result.threadID
                )
            }
            priorInputItemsResult = result
            lastTransportProblem = nil
            return result
        } catch {
            lastTransportProblem = Self.publicTransportProblem(error)
            throw error
        }
    }

    @discardableResult
    public func commitRawHistory(
        _ command: CodexRawHistoryCommit
    ) throws -> CodexRawHistoryCommittedEvent {
        guard let transport else {
            let error = CodexSessionStoreError.transportUnavailable
            lastTransportProblem = Self.publicTransportProblem(error)
            throw error
        }
        lastRawHistoryCommitEvent = nil
        do {
            try transport.submit(command)
            let rawEvents = try drainPendingEvents(from: transport)
            guard let committed = rawEvents.last(where: {
                Self.matches($0, command: command)
            }) else {
                throw CodexSessionStoreError.invalidReply
            }
            lastRawHistoryCommitEvent = committed
            lastTransportProblem = nil
            return committed
        } catch {
            lastTransportProblem = Self.publicTransportProblem(error)
            throw error
        }
    }

    public func commitCompaction(
        _ command: CodexCompactHistoryCommit
    ) throws {
        guard let transport else {
            throw CodexSessionStoreError.transportUnavailable
        }
        do {
            try transport.submit(command)
            try drainPendingEvents(from: transport)
            lastTransportProblem = nil
        } catch {
            lastTransportProblem = Self.publicTransportProblem(error)
            throw error
        }
    }

    @discardableResult
    public func searchThreads(
        id: CodexAppServerRequestID,
        params: CodexThreadSearchParams
    ) throws -> CodexThreadSearchPage {
        do {
            let result: CodexThreadSearchPage = try performThreadRequest(
                .search(id: id, params: params),
                expectedID: id
            )
            threadSearchPage = result
            lastTransportProblem = nil
            return result
        } catch {
            lastTransportProblem = Self.publicTransportProblem(error)
            throw error
        }
    }

    @discardableResult
    public func listThreadSections(
        id: CodexAppServerRequestID,
        params: CodexThreadSectionListParams
    ) throws -> CodexThreadSectionPage {
        do {
            let result: CodexThreadSectionPage = try performThreadRequest(
                .sectionList(id: id, params: params),
                expectedID: id
            )
            threadSectionPage = result
            lastTransportProblem = nil
            return result
        } catch {
            lastTransportProblem = Self.publicTransportProblem(error)
            throw error
        }
    }

    @discardableResult
    public func createThreadSection(
        id: CodexAppServerRequestID,
        params: CodexThreadSectionCreateParams
    ) throws -> CodexThreadSectionCreateResult {
        do {
            let result: CodexThreadSectionCreateResult =
                try performThreadRequest(
                    .sectionCreate(id: id, params: params),
                    expectedID: id
                )
            lastTransportProblem = nil
            return result
        } catch {
            lastTransportProblem = Self.publicTransportProblem(error)
            throw error
        }
    }

    @discardableResult
    public func updateThreadSection(
        id: CodexAppServerRequestID,
        params: CodexThreadSectionUpdateParams
    ) throws -> CodexThreadSectionUpdateResult {
        do {
            let result: CodexThreadSectionUpdateResult =
                try performThreadRequest(
                    .sectionUpdate(id: id, params: params),
                    expectedID: id
                )
            lastTransportProblem = nil
            return result
        } catch {
            lastTransportProblem = Self.publicTransportProblem(error)
            throw error
        }
    }

    public func deleteThreadSection(
        id: CodexAppServerRequestID,
        params: CodexThreadSectionDeleteParams
    ) throws {
        do {
            let _: CodexThreadEmptyResponse = try performThreadRequest(
                .sectionDelete(id: id, params: params),
                expectedID: id
            )
            lastTransportProblem = nil
        } catch {
            lastTransportProblem = Self.publicTransportProblem(error)
            throw error
        }
    }

    public func moveThreadSection(
        id: CodexAppServerRequestID,
        params: CodexThreadSectionMoveParams
    ) throws {
        do {
            let _: CodexThreadEmptyResponse = try performThreadRequest(
                .sectionMove(id: id, params: params),
                expectedID: id
            )
            lastTransportProblem = nil
        } catch {
            lastTransportProblem = Self.publicTransportProblem(error)
            throw error
        }
    }

    @discardableResult
    public func updateThreadMetadata(
        id: CodexAppServerRequestID,
        params: CodexThreadMetadataUpdateParams
    ) throws -> CodexThreadMetadataUpdateResult {
        do {
            let result: CodexThreadMetadataUpdateResult =
                try performThreadRequest(
                    .metadataUpdate(id: id, params: params),
                    expectedID: id
                )
            threadMetadataUpdateResult = result
            try drainPendingEvents()
            lastTransportProblem = nil
            return result
        } catch {
            lastTransportProblem = Self.publicTransportProblem(error)
            throw error
        }
    }

    public func archiveStoredThread(
        id: CodexAppServerRequestID,
        threadID: CodexStoredThreadID
    ) throws {
        let _: CodexThreadEmptyResponse = try performThreadRequest(
            .archive(id: id, threadID: threadID),
            expectedID: id
        )
        try drainPendingEvents()
        lastTransportProblem = nil
    }

    @discardableResult
    public func unsubscribeStoredThread(
        id: CodexAppServerRequestID,
        threadID: CodexStoredThreadID
    ) throws -> CodexThreadUnsubscribeResponse {
        let response: CodexThreadUnsubscribeResponse =
            try performThreadRequest(
                .unsubscribe(id: id, threadID: threadID),
                expectedID: id
            )
        if response.status != .notSubscribed {
            subscribedStoredThreadIDs.remove(threadID)
        }
        lastTransportProblem = nil
        return response
    }

    public func injectStoredThreadItems(
        id: CodexAppServerRequestID,
        threadID: CodexStoredThreadID,
        items: [CodexJSONValue]
    ) throws {
        let _: CodexThreadEmptyResponse = try performThreadRequest(
            .injectItems(id: id, threadID: threadID, items: items),
            expectedID: id
        )
        try drainPendingEvents()
        lastTransportProblem = nil
    }

    public func approveGuardianDeniedAction(
        id: CodexAppServerRequestID,
        threadID: CodexStoredThreadID,
        event: CodexJSONValue
    ) throws {
        let _: CodexThreadEmptyResponse = try performThreadRequest(
            .approveGuardianDeniedAction(
                id: id,
                threadID: threadID,
                event: event
            ),
            expectedID: id
        )
        try drainPendingEvents()
        lastTransportProblem = nil
    }

    public func beginShellCommand(
        id: CodexAppServerRequestID,
        threadID: CodexStoredThreadID,
        command: String
    ) throws -> CodexShellCommandStartedEvent {
        lastShellCommandStartedEvent = nil
        let _: CodexThreadEmptyResponse = try performThreadRequest(
            .shellCommand(
                id: id,
                threadID: threadID,
                command: command
            ),
            expectedID: id
        )
        try drainPendingEvents()
        guard let event = lastShellCommandStartedEvent,
              event.threadID == threadID,
              event.command == command.trimmingCharacters(
                in: .whitespacesAndNewlines
              )
        else {
            throw CodexSessionStoreError.invalidReply
        }
        lastTransportProblem = nil
        return event
    }

    public func completeShellCommand(
        commandID: String,
        result: CodexDesktopCommandExecResult,
        durationMillis: UInt64
    ) throws {
        try submitAndDrain(
            .completeShellCommand(
                commandID: commandID,
                exitCode: result.exitCode,
                durationMillis: durationMillis,
                stdout: result.stdout,
                stderr: result.stderr
            )
        )
    }

    public func unarchiveStoredThread(
        id: CodexAppServerRequestID,
        threadID: CodexStoredThreadID
    ) throws -> CodexThreadUnarchiveResponse {
        let response: CodexThreadUnarchiveResponse =
            try performThreadRequest(
                .unarchive(id: id, threadID: threadID),
                expectedID: id
            )
        try drainPendingEvents()
        lastTransportProblem = nil
        return response
    }

    public func deleteStoredThread(
        id: CodexAppServerRequestID,
        threadID: CodexStoredThreadID
    ) throws {
        let _: CodexThreadEmptyResponse = try performThreadRequest(
            .delete(id: id, threadID: threadID),
            expectedID: id
        )
        try drainPendingEvents()
        lastTransportProblem = nil
    }

    @discardableResult
    public func rollbackStoredThread(
        id: CodexAppServerRequestID,
        threadID: CodexStoredThreadID,
        numTurns: UInt32
    ) throws -> CodexThreadReadResult {
        do {
            let response: CodexThreadReadResult =
                try performThreadRequest(
                    .rollback(
                        id: id,
                        threadID: threadID,
                        numTurns: numTurns
                    ),
                    expectedID: id
                )
            try drainPendingEvents()
            threadReadResult = response
            lastTransportProblem = nil
            return response
        } catch {
            lastTransportProblem = Self.publicTransportProblem(error)
            throw error
        }
    }

    @discardableResult
    public func revertStoredThread(
        id: CodexAppServerRequestID,
        threadID: CodexStoredThreadID,
        beforeTurnID: String
    ) throws -> CodexThreadRevertResult {
        do {
            let response: CodexThreadRevertResult =
                try performThreadRequest(
                    .revert(
                        id: id,
                        threadID: threadID,
                        beforeTurnID: beforeTurnID
                    ),
                    expectedID: id
                )
            try drainPendingEvents()
            threadReadResult = CodexThreadReadResult(thread: response.thread)
            lastTransportProblem = nil
            return response
        } catch {
            lastTransportProblem = Self.publicTransportProblem(error)
            throw error
        }
    }

    public func setStoredThreadName(
        id: CodexAppServerRequestID,
        threadID: CodexStoredThreadID,
        name: String
    ) throws {
        let _: CodexThreadEmptyResponse = try performThreadRequest(
            .setName(
                id: id,
                threadID: threadID,
                name: name
            ),
            expectedID: id
        )
        try drainPendingEvents()
        lastTransportProblem = nil
    }

    @discardableResult
    public func addQueuedSubmission(
        id: CodexAppServerRequestID,
        params: CodexThreadQueueAddParams
    ) throws -> CodexThreadQueueAddResponse {
        do {
            let response: CodexThreadQueueAddResponse = try performThreadRequest(
                .queueAdd(id: id, params: params),
                expectedID: id
            )
            try drainPendingEvents()
            lastTransportProblem = nil
            return response
        } catch {
            lastTransportProblem = Self.publicTransportProblem(error)
            throw error
        }
    }

    @discardableResult
    public func listQueuedSubmissions(
        id: CodexAppServerRequestID,
        params: CodexThreadQueueListParams
    ) throws -> CodexThreadQueueListResponse {
        do {
            let response: CodexThreadQueueListResponse = try performThreadRequest(
                .queueList(id: id, params: params),
                expectedID: id
            )
            lastTransportProblem = nil
            return response
        } catch {
            lastTransportProblem = Self.publicTransportProblem(error)
            throw error
        }
    }

    @discardableResult
    public func updateQueuedSubmission(
        id: CodexAppServerRequestID,
        params: CodexThreadQueueUpdateParams
    ) throws -> CodexThreadQueueUpdateResponse {
        do {
            let response: CodexThreadQueueUpdateResponse = try performThreadRequest(
                .queueUpdate(id: id, params: params),
                expectedID: id
            )
            try drainPendingEvents()
            lastTransportProblem = nil
            return response
        } catch {
            lastTransportProblem = Self.publicTransportProblem(error)
            throw error
        }
    }

    @discardableResult
    public func deleteQueuedSubmission(
        id: CodexAppServerRequestID,
        params: CodexThreadQueueDeleteParams
    ) throws -> CodexThreadQueueDeleteResponse {
        do {
            let response: CodexThreadQueueDeleteResponse = try performThreadRequest(
                .queueDelete(id: id, params: params),
                expectedID: id
            )
            try drainPendingEvents()
            lastTransportProblem = nil
            return response
        } catch {
            lastTransportProblem = Self.publicTransportProblem(error)
            throw error
        }
    }

    public func reorderQueuedSubmissions(
        id: CodexAppServerRequestID,
        params: CodexThreadQueueReorderParams
    ) throws {
        do {
            let _: CodexThreadQueueReorderResponse = try performThreadRequest(
                .queueReorder(id: id, params: params),
                expectedID: id
            )
            try drainPendingEvents()
            lastTransportProblem = nil
        } catch {
            lastTransportProblem = Self.publicTransportProblem(error)
            throw error
        }
    }

    @discardableResult
    public func startQueuedSubmission(
        id: CodexAppServerRequestID,
        params: CodexThreadQueueStartParams
    ) throws -> CodexThreadQueueStartResponse {
        do {
            let response: CodexThreadQueueStartResponse = try performThreadRequest(
                .queueStart(id: id, params: params),
                expectedID: id
            )
            try drainPendingEvents()
            lastTransportProblem = nil
            return response
        } catch {
            lastTransportProblem = Self.publicTransportProblem(error)
            throw error
        }
    }

    @discardableResult
    public func apply(_ event: DomainEvent) -> ApplyResult {
        let result = CodexSessionReducer.apply(event, to: &state)
        switch result {
        case .applied, .duplicate:
            lastApplyProblem = nil
        case .gap, .invalidReference:
            lastApplyProblem = result
        }
        return result
    }

    public func openWorkspace(
        id: UUID,
        displayName: String,
        rootBookmarkID: String?
    ) throws {
        let workspace = Workspace(
            id: id,
            displayName: displayName,
            rootBookmarkID: rootBookmarkID
        )
        try submitAndDrain(.openWorkspace(workspace))
        if state.workspaces.contains(where: { $0.id == id }) {
            selectedWorkspaceID = id
        }
    }

    public func updateWorkspace(
        id: UUID,
        displayName: String,
        rootBookmarkID: String?
    ) throws {
        guard state.workspaces.contains(where: { $0.id == id }) else {
            throw CodexCoreEnvelopeError.invalidCommandPayload
        }
        let workspace = Workspace(
            id: id,
            displayName: displayName,
            rootBookmarkID: rootBookmarkID
        )
        try submitAndDrain(.updateWorkspace(workspace))
    }

    public func removeWorkspace(id: UUID) throws {
        guard state.workspaces.contains(where: { $0.id == id }) else {
            throw CodexCoreEnvelopeError.invalidCommandPayload
        }
        try submitAndDrain(.removeWorkspace(id))
        guard !state.workspaces.contains(where: { $0.id == id }),
              selectedWorkspaceID == id
        else {
            return
        }
        selectedWorkspaceID = nil
        selectedThreadID = nil
    }

    public func openStorage(
        databasePath: String,
        snapshotDirectory: String
    ) throws {
        try submitAndDrain(
            .openStorage(
                databasePath: databasePath,
                snapshotDirectory: snapshotDirectory
            )
        )
        selectRecoveredSession()
    }

    public func confirmStorage() throws {
        try submitAndDrain(.confirmStorage)
    }

    public func restoreStorage(
        databasePath: String,
        snapshotDirectory: String,
        snapshotName: String
    ) throws {
        try submitAndDrain(
            .restoreStorage(
                databasePath: databasePath,
                snapshotDirectory: snapshotDirectory,
                snapshotName: snapshotName
            )
        )
        selectRecoveredSession()
    }

    public func recordStartupProblem(_ error: any Error) {
        lastTransportProblem = Self.publicTransportProblem(error)
    }

    public func startThread(
        id: UUID,
        workspaceID: UUID,
        title: String,
        metadata: CodexThreadCreateMetadata
    ) throws {
        let thread = CodexThread(
            id: id,
            workspaceID: workspaceID,
            title: title
        )
        try submitAndDrain(.startThread(thread, metadata: metadata))
        if state.threads.contains(where: { $0.id == id }) {
            selectedWorkspaceID = workspaceID
            selectedThreadID = id
        }
    }

    public func setThreadName(id: UUID, name: String) throws {
        guard state.threads.contains(where: { $0.id == id }) else {
            throw CodexCoreEnvelopeError.invalidCommandPayload
        }
        try submitAndDrain(.setThreadName(threadID: id, name: name))
    }

    public func archiveThread(id: UUID) throws {
        try submitAndDrain(.archiveThread(threadID: id))
        if selectedThreadID == id {
            selectedThreadID = nil
        }
    }

    public func unarchiveThread(id: UUID) throws {
        try submitAndDrain(.unarchiveThread(threadID: id))
    }

    public func deleteThread(id: UUID) throws {
        guard state.threads.contains(where: { $0.id == id }) else {
            throw CodexCoreEnvelopeError.invalidCommandPayload
        }
        try submitAndDrain(.deleteThread(threadID: id))
        if selectedThreadID == id {
            selectedThreadID = nil
        }
    }

    public func threadGoal(for threadID: UUID) -> ThreadGoal? {
        state.threadGoals.first { $0.threadID == threadID }
    }

    public func setThreadGoal(
        threadID: UUID,
        objective: String,
        status: ThreadGoalStatus = .active,
        tokenBudget: Int64?,
        updatedAt: Int64 = Int64(Date().timeIntervalSince1970)
    ) throws {
        guard state.threads.contains(where: { $0.id == threadID }),
              !objective.trimmingCharacters(
                in: .whitespacesAndNewlines
              ).isEmpty,
              tokenBudget.map({ $0 > 0 }) ?? true
        else {
            throw CodexCoreEnvelopeError.invalidCommandPayload
        }
        let existing = threadGoal(for: threadID)
        let goal = ThreadGoal(
            threadID: threadID,
            objective: objective.trimmingCharacters(
                in: .whitespacesAndNewlines
            ),
            status: status,
            tokenBudget: tokenBudget,
            tokensUsed: existing?.tokensUsed ?? 0,
            timeUsedSeconds: existing?.timeUsedSeconds ?? 0,
            createdAt: existing?.createdAt ?? updatedAt,
            updatedAt: updatedAt
        )
        try submitAndDrain(.setThreadGoal(goal))
    }

    public func clearThreadGoal(threadID: UUID) throws {
        guard threadGoal(for: threadID) != nil else {
            throw CodexCoreEnvelopeError.invalidCommandPayload
        }
        try submitAndDrain(.clearThreadGoal(threadID: threadID))
    }

    public func storedThreadGoal(
        threadID: CodexStoredThreadID
    ) throws -> ThreadGoal? {
        guard let id = UUID(uuidString: threadID.rawValue) else {
            throw CodexCoreEnvelopeError.invalidCommandPayload
        }
        return threadGoal(for: id)
    }

    @discardableResult
    public func setStoredThreadGoal(
        threadID: CodexStoredThreadID,
        objective: String?,
        status: ThreadGoalStatus?,
        tokenBudget: CodexWireOptional<Int64>
    ) throws -> ThreadGoal {
        guard let id = UUID(uuidString: threadID.rawValue) else {
            throw CodexCoreEnvelopeError.invalidCommandPayload
        }
        let existing = threadGoal(for: id)
        guard let effectiveObjective = objective ?? existing?.objective
        else {
            throw CodexCoreEnvelopeError.invalidCommandPayload
        }
        let effectiveBudget: Int64?
        switch tokenBudget {
        case .omitted:
            effectiveBudget = existing?.tokenBudget
        case .null:
            effectiveBudget = nil
        case let .value(value):
            effectiveBudget = value
        }
        try setThreadGoal(
            threadID: id,
            objective: effectiveObjective,
            status: status ?? existing?.status ?? .active,
            tokenBudget: effectiveBudget
        )
        guard let goal = threadGoal(for: id) else {
            throw CodexSessionStoreError.invalidReply
        }
        return goal
    }

    @discardableResult
    public func clearStoredThreadGoal(
        threadID: CodexStoredThreadID
    ) throws -> Bool {
        guard let id = UUID(uuidString: threadID.rawValue) else {
            throw CodexCoreEnvelopeError.invalidCommandPayload
        }
        guard threadGoal(for: id) != nil else {
            return false
        }
        try clearThreadGoal(threadID: id)
        return true
    }

    public func threadSettings(for threadID: UUID) -> ThreadSettings? {
        state.threadSettings.first { $0.threadID == threadID }
    }

    public func threadSettings(
        for threadID: CodexStoredThreadID
    ) -> CodexAppServerThreadSettings? {
        appServerThreadSettings[threadID]
    }

    public func updateThreadSettings(_ settings: ThreadSettings) throws {
        guard state.threads.contains(where: { $0.id == settings.threadID })
        else {
            throw CodexCoreEnvelopeError.invalidCommandPayload
        }
        try submitAndDrain(.updateThreadSettings(settings))
    }

    @discardableResult
    public func updateThreadSettings(
        id: CodexAppServerRequestID,
        params: CodexThreadSettingsUpdateParams
    ) throws -> CodexThreadSettingsUpdateResponse {
        do {
            let result: CodexThreadSettingsUpdateResponse =
                try performThreadRequest(
                    .settingsUpdate(id: id, params: params),
                    expectedID: id
                )
            try drainPendingEvents()
            lastTransportProblem = nil
            return result
        } catch {
            lastTransportProblem = Self.publicTransportProblem(error)
            throw error
        }
    }

    public func setThreadMemoryMode(
        id: CodexAppServerRequestID,
        params: CodexThreadMemoryModeSetParams
    ) throws {
        do {
            let _: CodexThreadEmptyResponse = try performThreadRequest(
                .memoryModeSet(id: id, params: params),
                expectedID: id
            )
            try drainPendingEvents()
            lastTransportProblem = nil
        } catch {
            lastTransportProblem = Self.publicTransportProblem(error)
            throw error
        }
    }

    public func receiveThreadSettingsNotification(
        _ notification: CodexThreadSettingsUpdatedNotification
    ) {
        appServerThreadSettings[notification.threadID] =
            notification.threadSettings
        lastThreadSettingsNotification = notification
    }

    /// Returns server notifications in transport order and atomically clears
    /// the queue. The desktop surface calls this after each MCP response so
    /// notifications cannot be duplicated across renderer hosts.
    public func takeAppServerNotifications()
        -> [CodexAppServerNotification]
    {
        let notifications = pendingAppServerNotifications
        pendingAppServerNotifications.removeAll(keepingCapacity: true)
        return notifications
    }

    /// Removes only terminal idle notifications for the requested thread.
    /// Other app-server notifications remain queued for the MCP response path.
    public func takeTerminalIdleNotifications(
        for threadID: CodexStoredThreadID
    ) -> [CodexAppServerNotification] {
        var terminalIdle: [CodexAppServerNotification] = []
        var retained: [CodexAppServerNotification] = []
        retained.reserveCapacity(pendingAppServerNotifications.count)

        for notification in pendingAppServerNotifications {
            if case let .threadStatusChanged(status) = notification,
               status.threadID == threadID.rawValue,
               status.status == .idle
            {
                terminalIdle.append(notification)
            } else {
                retained.append(notification)
            }
        }
        pendingAppServerNotifications = retained
        return terminalIdle
    }

    public func forkThread(
        id: UUID,
        newThreadID: UUID,
        title: String,
        timestamp: Int64,
        lastTurnID: UUID? = nil
    ) throws {
        let sourceTurns = try forkableTurns(
            threadID: id,
            lastTurnID: lastTurnID
        )
        let sourceTurnIDs = Set(sourceTurns.map(\.id))
        let sourceItems = state.items.filter {
            sourceTurnIDs.contains($0.turnID)
        }
        try forkThread(
            id: id,
            newThreadID: newThreadID,
            title: title,
            lastTurnID: lastTurnID,
            turnIDMap: Dictionary(
                uniqueKeysWithValues: sourceTurns.map { ($0.id, UUID()) }
            ),
            itemIDMap: Dictionary(
                uniqueKeysWithValues: sourceItems.map { ($0.id, UUID()) }
            ),
            timestamp: timestamp
        )
    }

    public func forkThread(
        id: UUID,
        newThreadID: UUID,
        title: String,
        lastTurnID: UUID?,
        turnIDMap: [UUID: UUID],
        itemIDMap: [UUID: UUID],
        timestamp: Int64
    ) throws {
        guard let source = state.threads.first(where: { $0.id == id }),
              !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw CodexCoreEnvelopeError.invalidCommandPayload
        }
        let sourceTurns = try forkableTurns(
            threadID: id,
            lastTurnID: lastTurnID
        )
        let turnIDs = Set(sourceTurns.map(\.id))
        let itemIDs = Set(
            state.items
                .filter { turnIDs.contains($0.turnID) }
                .map(\.id)
        )
        guard Set(turnIDMap.keys) == turnIDs,
              Set(itemIDMap.keys) == itemIDs,
              Set(turnIDMap.values).count == turnIDMap.count,
              Set(itemIDMap.values).count == itemIDMap.count,
              Set(turnIDMap.values).isDisjoint(with: itemIDMap.values),
              !turnIDMap.values.contains(newThreadID),
              !itemIDMap.values.contains(newThreadID)
        else {
            throw CodexCoreEnvelopeError.invalidCommandPayload
        }
        try submitAndDrain(
            .forkThread(
                threadID: id,
                newThreadID: newThreadID,
                title: title,
                lastTurnID: lastTurnID,
                turnIDMap: turnIDMap,
                itemIDMap: itemIDMap,
                timestamp: timestamp
            )
        )
        if state.threads.contains(where: { $0.id == newThreadID }) {
            selectedWorkspaceID = source.workspaceID
            selectedThreadID = newThreadID
        }
    }

    public func startTurn(
        id: UUID,
        threadID: UUID,
        itemID: UUID,
        text: String,
        timestamp: Int64
    ) throws {
        let turn = Turn(id: id, threadID: threadID, status: .running)
        let userItem = ThreadItem(
            id: itemID,
            threadID: threadID,
            turnID: id,
            kind: .userMessage,
            text: text
        )
        try submitAndDrain(
            .startTurn(
                turn,
                userItem: userItem,
                timestamp: timestamp
            )
        )
    }

    public func completeTurn(
        id: UUID,
        itemID: UUID,
        text: String,
        timestamp: Int64
    ) throws {
        guard let turn = state.turns.first(where: { $0.id == id }) else {
            throw CodexCoreEnvelopeError.invalidCommandPayload
        }
        let assistantItem = ThreadItem(
            id: itemID,
            threadID: turn.threadID,
            turnID: id,
            kind: .assistantMessage,
            text: text
        )
        try submitAndDrain(
            .completeTurn(
                turnID: id,
                assistantItem: assistantItem,
                timestamp: timestamp
            )
        )
    }

    public func appendItem(
        id: UUID,
        turnID: UUID,
        kind: ThreadItemKind,
        text: String
    ) throws {
        guard let turn = state.turns.first(where: { $0.id == turnID }) else {
            throw CodexCoreEnvelopeError.invalidCommandPayload
        }
        try submitAndDrain(
            .appendItem(
                ThreadItem(
                    id: id,
                    threadID: turn.threadID,
                    turnID: turnID,
                    kind: kind,
                    text: text
                )
            )
        )
    }

    public func failTurn(
        id: UUID,
        itemID: UUID,
        message: String,
        timestamp: Int64
    ) throws {
        guard let turn = state.turns.first(where: { $0.id == id }) else {
            throw CodexCoreEnvelopeError.invalidCommandPayload
        }
        let errorItem = ThreadItem(
            id: itemID,
            threadID: turn.threadID,
            turnID: id,
            kind: .error,
            text: message
        )
        try submitAndDrain(
            .failTurn(
                turnID: id,
                errorItem: errorItem,
                timestamp: timestamp
            )
        )
    }

    public func failStableTurn(
        turnID: String,
        threadID: CodexStoredThreadID,
        message: String,
        timestamp: Int64
    ) throws {
        guard let resolvedTurnID = UUID(uuidString: turnID),
              let resolvedThreadID = UUID(uuidString: threadID.rawValue)
        else {
            throw CodexCoreEnvelopeError.invalidCommandPayload
        }
        try submitAndDrain(
            .failTurn(
                turnID: resolvedTurnID,
                errorItem: ThreadItem(
                    id: UUID(),
                    threadID: resolvedThreadID,
                    turnID: resolvedTurnID,
                    kind: .error,
                    text: message
                ),
                timestamp: timestamp
            )
        )
    }

    public func cancelTurn(id: UUID, timestamp: Int64) throws {
        guard state.turns.contains(where: { $0.id == id }) else {
            throw CodexCoreEnvelopeError.invalidCommandPayload
        }
        try submitAndDrain(
            .cancelTurn(turnID: id, timestamp: timestamp)
        )
    }

    /// Produces a bounded diagnostic for UI/log surfaces. App-server error
    /// messages and payloads may contain URLs, headers, or response content,
    /// so they must never be copied into the session diagnostic.
    private static func requestIDKind(
        _ id: CodexAppServerRequestID
    ) -> String {
        switch id {
        case .string:
            return "string"
        case .integer:
            return "integer"
        }
    }

    private static func publicTransportProblem(_ error: any Error) -> String {
        if let error = error as? CodexSessionStoreError {
            switch error {
            case .transportUnavailable:
                return "transportUnavailable"
            case .invalidReply:
                return "invalidReply"
            case let .replyIDMismatch(expected, actual):
                return "replyIDMismatch expected=\(requestIDKind(expected)) actual=\(requestIDKind(actual))"
            case let .appServerError(code, _, _):
                return "appServerError code=\(code)"
            case .resumedThreadIDMismatch:
                return "resumedThreadIDMismatch"
            }
        }
        return String(describing: type(of: error))
    }

    private func submitAndDrain(_ command: CodexCoreCommand) throws {
        guard let transport else {
            let error = CodexSessionStoreError.transportUnavailable
            lastTransportProblem = Self.publicTransportProblem(error)
            throw error
        }

        do {
            try transport.submit(command)
            try drainPendingEvents(from: transport)
            lastTransportProblem = nil
        } catch {
            lastTransportProblem = Self.publicTransportProblem(error)
            throw error
        }
    }

    private func performThreadRequest<Result>(
        _ request: CodexAppServerThreadRequest,
        expectedID: CodexAppServerRequestID
    ) throws -> Result
    where Result: Codable & Equatable & Sendable {
        guard let transport else {
            throw CodexSessionStoreError.transportUnavailable
        }
        let data = try transport.request(request)
        let reply: CodexAppServerReply<Result>
        do {
            reply = try JSONDecoder().decode(
                CodexAppServerReply<Result>.self,
                from: data
            )
        } catch {
            throw CodexSessionStoreError.invalidReply
        }

        switch reply {
        case let .success(response):
            guard response.id == expectedID else {
                throw CodexSessionStoreError.replyIDMismatch(
                    expected: expectedID,
                    actual: response.id
                )
            }
            return response.result

        case let .failure(response):
            guard response.id == expectedID else {
                throw CodexSessionStoreError.replyIDMismatch(
                    expected: expectedID,
                    actual: response.id
                )
            }
            throw CodexSessionStoreError.appServerError(
                code: response.error.code,
                message: response.error.message,
                data: response.error.data
            )
        }
    }

    private func performModelRequest<Result>(
        _ request: CodexAppServerModelRequest,
        expectedID: CodexAppServerRequestID
    ) throws -> Result
    where Result: Codable & Equatable & Sendable {
        guard let transport else {
            throw CodexSessionStoreError.transportUnavailable
        }
        let data = try transport.request(request)
        let reply: CodexAppServerReply<Result>
        do {
            reply = try JSONDecoder().decode(
                CodexAppServerReply<Result>.self,
                from: data
            )
        } catch {
            throw CodexSessionStoreError.invalidReply
        }

        switch reply {
        case let .success(response):
            guard response.id == expectedID else {
                throw CodexSessionStoreError.replyIDMismatch(
                    expected: expectedID,
                    actual: response.id
                )
            }
            return response.result

        case let .failure(response):
            guard response.id == expectedID else {
                throw CodexSessionStoreError.replyIDMismatch(
                    expected: expectedID,
                    actual: response.id
                )
            }
            throw CodexSessionStoreError.appServerError(
                code: response.error.code,
                message: response.error.message,
                data: response.error.data
            )
        }
    }

    private func performTurnStartRequest(
        _ request: CodexAppServerTurnRequest,
        expectedID: CodexAppServerRequestID
    ) throws -> CodexTurnStartResult {
        guard let transport else {
            throw CodexSessionStoreError.transportUnavailable
        }
        let data = try transport.request(request)
        let reply: CodexAppServerReply<CodexTurnStartResult>
        do {
            reply = try JSONDecoder().decode(
                CodexAppServerReply<CodexTurnStartResult>.self,
                from: data
            )
        } catch {
            throw CodexSessionStoreError.invalidReply
        }

        switch reply {
        case .success(let response):
            guard response.id == expectedID else {
                throw CodexSessionStoreError.replyIDMismatch(
                    expected: expectedID,
                    actual: response.id
                )
            }
            return response.result

        case .failure(let response):
            guard response.id == expectedID else {
                throw CodexSessionStoreError.replyIDMismatch(
                    expected: expectedID,
                    actual: response.id
                )
            }
            throw CodexSessionStoreError.appServerError(
                code: response.error.code,
                message: response.error.message,
                data: response.error.data
            )
        }
    }

    private func performRawHistoryRequest<Result>(
        _ request: CodexRawHistoryRequest,
        expectedID: CodexAppServerRequestID
    ) throws -> Result
    where Result: Codable & Equatable & Sendable {
        guard let transport else {
            throw CodexSessionStoreError.transportUnavailable
        }
        let data = try transport.request(request)
        let reply: CodexAppServerReply<Result>
        do {
            reply = try JSONDecoder().decode(
                CodexAppServerReply<Result>.self,
                from: data
            )
        } catch {
            throw CodexSessionStoreError.invalidReply
        }
        switch reply {
        case .success(let response):
            guard response.id == expectedID else {
                throw CodexSessionStoreError.replyIDMismatch(
                    expected: expectedID,
                    actual: response.id
                )
            }
            return response.result

        case .failure(let response):
            guard response.id == expectedID else {
                throw CodexSessionStoreError.replyIDMismatch(
                    expected: expectedID,
                    actual: response.id
                )
            }
            throw CodexSessionStoreError.appServerError(
                code: response.error.code,
                message: response.error.message,
                data: response.error.data
            )
        }
    }

    private func failStableTurnIfCurrent(
        _ source: any Error,
        request: CodexResumedTurnStartRequest
    ) {
        let failure: CodexResumedTurnError
        switch source {
        case CodexSessionStoreError.invalidReply:
            failure = .invalidInitialTurn
        case let CodexSessionStoreError.appServerError(
            code,
            message,
            _
        ):
            failure = .appServer(code: code, message: message)
        default:
            failure = .transport(String(describing: source))
        }
        resumedTurnState.failStart(failure, for: request)
    }

    @discardableResult
    private func drainPendingEvents() throws
        -> [CodexRawHistoryCommittedEvent]
    {
        guard let transport else {
            throw CodexSessionStoreError.transportUnavailable
        }
        return try drainPendingEvents(from: transport)
    }

    @discardableResult
    private func drainPendingEvents(
        from transport: any CodexCoreTransport
    ) throws -> [CodexRawHistoryCommittedEvent] {
        var rawHistoryEvents: [CodexRawHistoryCommittedEvent] = []
        while let event = try transport.nextEvent() {
            if case .domain = event {
                // Domain events advance the same cursor while applying their
                // payload below.
            } else if case .threadQueueChanged = event {
                // Queue events are projected into the domain reducer below.
            } else if case .stableTurnStarted(let stableEvent) = event {
                let result: ApplyResult
                if let threadID = UUID(
                    uuidString: stableEvent.threadID.rawValue
                ), let turnID = UUID(uuidString: stableEvent.turnID) {
                    result = apply(.init(
                        sequence: Int64(stableEvent.sequence),
                        payload: .turnStarted(.init(
                            id: turnID,
                            threadID: threadID,
                            status: .running
                        ))
                    ))
                } else {
                    result = .invalidReference("stable-turn")
                    lastApplyProblem = result
                }
                if result == .applied || result == .duplicate {
                    lastApplyProblem = nil
                }
            } else if case .threadSettingsUpdated = event {
                let result = CodexSessionReducer.consumeSequence(
                    state.lastAppliedSequence + 1,
                    in: &state
                )
                switch result {
                case .applied, .duplicate:
                    lastApplyProblem = nil
                case .gap, .invalidReference:
                    lastApplyProblem = result
                }
            } else if let sequence = event.sequence {
                let result = CodexSessionReducer.consumeSequence(
                    Int64(sequence),
                    in: &state
                )
                switch result {
                case .applied, .duplicate:
                    lastApplyProblem = nil
                case .gap, .invalidReference:
                    lastApplyProblem = result
                }
            }
            switch event {
            case .domain(let domainEvent):
                _ = apply(domainEvent)
            case .threadQueueChanged(let sequence, let threadID, let queuedSubmissions):
                guard let uuid = UUID(uuidString: threadID.rawValue) else {
                    lastApplyProblem = .invalidReference("thread-queue")
                    continue
                }
                _ = apply(.init(
                    sequence: Int64(sequence),
                    payload: .threadQueueChanged(
                        threadID: uuid,
                        submissions: queuedSubmissions
                    )
                ))
            case .rawHistoryCommitted(let rawEvent):
                rawHistoryEvents.append(rawEvent)
            case .threadSettingsUpdated(let notification):
                receiveThreadSettingsNotification(notification)
            case .appServerNotification(let notification):
                pendingAppServerNotifications.append(notification)
            case .stableCompactStarted(let event):
                lastStableCompactStartedEvent = event
            case .shellCommandStarted(let event):
                lastShellCommandStartedEvent = event
            case .shellCommandCompleted(let event):
                lastShellCommandCompletedEvent = event
            case .threadItemsInjected:
                break
            case .pong,
                 .provider,
                 .stableTurnStarted,
                 .compactionCommitted,
                 .threadMemoryModeUpdated:
                break
            }
        }
        return rawHistoryEvents
    }

    private static func matches(
        _ event: CodexRawHistoryCommittedEvent,
        command: CodexRawHistoryCommit
    ) -> Bool {
        let expectedCompletion: CodexRawHistoryCompletion?
        switch command.completion {
        case .value(let completion):
            expectedCompletion = completion
        case .omitted, .null:
            expectedCompletion = nil
        }
        return event.threadID == command.threadID
            && event.turnID == command.turnID
            && event.expectedNextOrder == command.expectedNextOrder
            && event.entries == command.entries
            && event.completion == expectedCompletion
    }

    private func forkableTurns(
        threadID: UUID,
        lastTurnID: UUID?
    ) throws -> [Turn] {
        let sourceTurns = state.turns.filter { $0.threadID == threadID }
        let included: [Turn]
        if let lastTurnID {
            guard let index = sourceTurns.firstIndex(where: {
                $0.id == lastTurnID
            }) else {
                throw CodexCoreEnvelopeError.invalidCommandPayload
            }
            included = Array(sourceTurns[...index])
        } else {
            included = sourceTurns
        }
        guard included.allSatisfy({ $0.status != .running }) else {
            throw CodexCoreEnvelopeError.invalidCommandPayload
        }
        return included
    }

    private func selectRecoveredSession() {
        guard selectedWorkspaceID == nil,
              let workspace = state.workspaces.first
        else {
            return
        }
        selectedWorkspaceID = workspace.id
        selectedThreadID = state.threads.first(where: {
            $0.workspaceID == workspace.id
        })?.id
    }
}

extension CodexSessionStore:
    CodexDesktopArchivedThreadDeleting
{
    public func deleteArchivedStoredThread(
        threadID: CodexStoredThreadID
    ) throws -> [CodexStoredThreadID] {
        let archived = try archivedStoredThreadIDs()
        guard archived.contains(threadID) else {
            return []
        }
        try deleteStoredThread(
            id: .string(
                "delete-archived-\(UUID().uuidString)"
            ),
            threadID: threadID
        )
        return [threadID]
    }

    public func deleteAllArchivedStoredThreads()
        throws -> [CodexStoredThreadID]
    {
        let archived = try archivedStoredThreadIDs()
        for threadID in archived {
            try deleteStoredThread(
                id: .string(
                    "delete-archived-\(UUID().uuidString)"
                ),
                threadID: threadID
            )
        }
        return archived
    }

    private func archivedStoredThreadIDs()
        throws -> [CodexStoredThreadID]
    {
        var cursor: String?
        var seenCursors = Set<String>()
        var seenIDs = Set<CodexStoredThreadID>()
        var result: [CodexStoredThreadID] = []
        repeat {
            let page = try listThreads(
                id: .string(
                    "list-archived-\(UUID().uuidString)"
                ),
                params: CodexThreadListParams(
                    cursor:
                        cursor.map(CodexWireOptional.value)
                        ?? .omitted,
                    limit: .value(100),
                    sortKey: .value(.updatedAt),
                    sortDirection: .value(.descending),
                    archived: .value(true)
                )
            )
            for thread in page.data
            where seenIDs.insert(thread.id).inserted {
                result.append(thread.id)
            }
            cursor = page.nextCursor
            if let cursor,
               !seenCursors.insert(cursor).inserted
            {
                throw CodexSessionStoreError.invalidReply
            }
        } while cursor != nil
        return result
    }
}
