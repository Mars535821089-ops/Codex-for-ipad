#if SWIFT_PACKAGE
import CodexPadDomain
#endif
import Foundation

public enum CodexThreadDirectoryArchiveScope:
    Equatable,
    Sendable
{
    case active
    case archived

    fileprivate var archivedValue: Bool {
        self == .archived
    }
}

public struct CodexThreadDirectoryCriteria: Equatable, Sendable {
    public var searchText: String
    public var archiveScope: CodexThreadDirectoryArchiveScope
    public var sortKey: CodexThreadSortKey
    public var sortDirection: CodexThreadSortDirection
    public var limit: UInt32

    public init(
        searchText: String = "",
        archiveScope: CodexThreadDirectoryArchiveScope = .active,
        sortKey: CodexThreadSortKey = .recencyAt,
        sortDirection: CodexThreadSortDirection = .descending,
        limit: UInt32 = 25
    ) {
        self.searchText = searchText
        self.archiveScope = archiveScope
        self.sortKey = sortKey
        self.sortDirection = sortDirection
        self.limit = limit
    }
}

public enum CodexThreadDirectoryQuery: Equatable, Sendable {
    case list(CodexThreadListParams)
    case search(CodexThreadSearchParams)
}

public enum CodexThreadDirectoryLoadKind: Equatable, Sendable {
    case initial
    case nextPage
}

public struct CodexThreadDirectoryLoadRequest: Equatable, Sendable {
    public let query: CodexThreadDirectoryQuery
    public let kind: CodexThreadDirectoryLoadKind
    fileprivate let token: UInt64

    fileprivate init(
        query: CodexThreadDirectoryQuery,
        kind: CodexThreadDirectoryLoadKind,
        token: UInt64
    ) {
        self.query = query
        self.kind = kind
        self.token = token
    }
}

public struct CodexThreadDirectoryReadRequest: Equatable, Sendable {
    public let params: CodexThreadReadParams
    fileprivate let token: UInt64

    fileprivate init(params: CodexThreadReadParams, token: UInt64) {
        self.params = params
        self.token = token
    }
}

public enum CodexThreadDirectoryLoadPhase: Equatable, Sendable {
    case idle
    case loadingInitial
    case loadingNextPage
    case loaded
    case failed
}

public enum CodexThreadDirectorySelectionPhase: Equatable, Sendable {
    case idle
    case loading
    case loaded
    case failed
}

public struct CodexThreadDirectoryViewState: Equatable, Sendable {
    public private(set) var criteria: CodexThreadDirectoryCriteria
    public private(set) var rows: [CodexStoredThreadPresentation]
    public private(set) var nextCursor: String?
    public private(set) var loadPhase: CodexThreadDirectoryLoadPhase
    public private(set) var loadErrorMessage: String?

    public private(set) var selectedThreadID: CodexStoredThreadID?
    public private(set) var selectedThread: CodexStoredThreadPresentation?
    public private(set) var selectionPhase:
        CodexThreadDirectorySelectionPhase
    public private(set) var selectionErrorMessage: String?

    private var loadToken: UInt64
    private var activeLoadToken: UInt64?
    private var selectionToken: UInt64

    public init(
        criteria: CodexThreadDirectoryCriteria = .init()
    ) {
        self.criteria = criteria
        rows = []
        nextCursor = nil
        loadPhase = .idle
        loadErrorMessage = nil
        selectedThreadID = nil
        selectedThread = nil
        selectionPhase = .idle
        selectionErrorMessage = nil
        loadToken = 0
        activeLoadToken = nil
        selectionToken = 0
    }

    public var canLoadNextPage: Bool {
        guard nextCursor != nil else {
            return false
        }
        switch loadPhase {
        case .loadingInitial, .loadingNextPage:
            return false
        case .idle, .loaded, .failed:
            return true
        }
    }

    public mutating func setCriteria(
        _ criteria: CodexThreadDirectoryCriteria
    ) {
        guard self.criteria != criteria else {
            return
        }
        self.criteria = criteria
        resetForCriteriaChange()
    }

    public mutating func setSearchText(_ searchText: String) {
        var updated = criteria
        updated.searchText = searchText
        setCriteria(updated)
    }

    public mutating func setArchiveScope(
        _ archiveScope: CodexThreadDirectoryArchiveScope
    ) {
        var updated = criteria
        updated.archiveScope = archiveScope
        setCriteria(updated)
    }

    public mutating func beginInitialLoad()
        -> CodexThreadDirectoryLoadRequest
    {
        let request = makeLoadRequest(cursor: nil, kind: .initial)
        activeLoadToken = request.token
        loadPhase = .loadingInitial
        loadErrorMessage = nil
        return request
    }

    public mutating func beginNextPageLoad()
        -> CodexThreadDirectoryLoadRequest?
    {
        guard canLoadNextPage, let nextCursor else {
            return nil
        }
        let request = makeLoadRequest(
            cursor: nextCursor,
            kind: .nextPage
        )
        activeLoadToken = request.token
        loadPhase = .loadingNextPage
        loadErrorMessage = nil
        return request
    }

    public mutating func receiveListPage(
        _ page: CodexThreadPage,
        for request: CodexThreadDirectoryLoadRequest
    ) {
        guard accepts(request), case .list = request.query else {
            return
        }
        apply(
            page.data.map {
                CodexStoredThreadPresentation(thread: $0)
            },
            replacingRows: request.kind == .initial
        )
        finishLoad(nextCursor: page.nextCursor)
    }

    public mutating func receiveSearchPage(
        _ page: CodexThreadSearchPage,
        for request: CodexThreadDirectoryLoadRequest
    ) {
        guard accepts(request), case .search = request.query else {
            return
        }
        apply(
            page.data.map(CodexStoredThreadPresentation.init(searchHit:)),
            replacingRows: request.kind == .initial
        )
        finishLoad(nextCursor: page.nextCursor)
    }

    public mutating func failLoad(
        _ message: String,
        for request: CodexThreadDirectoryLoadRequest
    ) {
        guard accepts(request) else {
            return
        }
        activeLoadToken = nil
        loadPhase = .failed
        loadErrorMessage = message
    }

    public mutating func selectThread(
        _ threadID: CodexStoredThreadID
    ) -> CodexThreadDirectoryReadRequest {
        selectionToken &+= 1
        selectedThreadID = threadID
        selectedThread = nil
        selectionPhase = .loading
        selectionErrorMessage = nil
        return CodexThreadDirectoryReadRequest(
            params: .init(threadID: threadID, includeTurns: true),
            token: selectionToken
        )
    }

    public mutating func clearSelection() {
        selectionToken &+= 1
        selectedThreadID = nil
        selectedThread = nil
        selectionPhase = .idle
        selectionErrorMessage = nil
    }

    public mutating func receiveReadResult(
        _ result: CodexThreadReadResult,
        for request: CodexThreadDirectoryReadRequest
    ) {
        guard request.token == selectionToken,
              selectedThreadID == request.params.threadID,
              result.thread.id == request.params.threadID
        else {
            return
        }
        selectedThread = CodexStoredThreadPresentation(
            thread: result.thread
        )
        selectionPhase = .loaded
        selectionErrorMessage = nil
    }

    public mutating func failSelection(
        _ message: String,
        for request: CodexThreadDirectoryReadRequest
    ) {
        guard request.token == selectionToken,
              selectedThreadID == request.params.threadID
        else {
            return
        }
        selectedThread = nil
        selectionPhase = .failed
        selectionErrorMessage = message
    }

    private mutating func makeLoadRequest(
        cursor: String?,
        kind: CodexThreadDirectoryLoadKind
    ) -> CodexThreadDirectoryLoadRequest {
        loadToken &+= 1
        return CodexThreadDirectoryLoadRequest(
            query: makeQuery(cursor: cursor),
            kind: kind,
            token: loadToken
        )
    }

    private func makeQuery(cursor: String?)
        -> CodexThreadDirectoryQuery
    {
        let cursorValue: CodexWireOptional<String> =
            cursor.map(CodexWireOptional.value) ?? .omitted
        let searchTerm = criteria.searchText.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        if searchTerm.isEmpty {
            return .list(
                CodexThreadListParams(
                    cursor: cursorValue,
                    limit: .value(criteria.limit),
                    sortKey: .value(criteria.sortKey),
                    sortDirection: .value(criteria.sortDirection),
                    sourceKinds: .value([
                        .cli,
                        .vscode,
                        .appServer,
                    ]),
                    archived: .value(criteria.archiveScope.archivedValue)
                )
            )
        }
        return .search(
            CodexThreadSearchParams(
                cursor: cursorValue,
                limit: .value(criteria.limit),
                sortKey: .value(criteria.sortKey),
                sortDirection: .value(criteria.sortDirection),
                sourceKinds: .value([
                    .cli,
                    .vscode,
                    .appServer,
                ]),
                archived: .value(criteria.archiveScope.archivedValue),
                searchTerm: searchTerm
            )
        )
    }

    private func accepts(
        _ request: CodexThreadDirectoryLoadRequest
    ) -> Bool {
        activeLoadToken == request.token
    }

    private mutating func apply(
        _ incoming: [CodexStoredThreadPresentation],
        replacingRows: Bool
    ) {
        var merged = replacingRows ? [] : rows
        var seen = Set(merged.map(\.id))
        for row in incoming where seen.insert(row.id).inserted {
            merged.append(row)
        }
        rows = merged
    }

    private mutating func finishLoad(nextCursor: String?) {
        self.nextCursor = nextCursor
        activeLoadToken = nil
        loadPhase = .loaded
        loadErrorMessage = nil
    }

    private mutating func resetForCriteriaChange() {
        loadToken &+= 1
        activeLoadToken = nil
        rows = []
        nextCursor = nil
        loadPhase = .idle
        loadErrorMessage = nil
        clearSelection()
    }
}
