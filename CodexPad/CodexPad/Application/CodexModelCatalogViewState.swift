#if SWIFT_PACKAGE
import CodexPadDomain
import CodexPadProtocolBridge
#endif
import Foundation

public struct CodexModelCatalogSource:
    Equatable,
    Hashable,
    Sendable
{
    public let modelProvider: String
    public let accountIdentity: String?
    public let chatGPTAuthenticated: Bool

    public init(
        modelProvider: String,
        accountIdentity: String?,
        chatGPTAuthenticated: Bool = false
    ) {
        self.modelProvider = modelProvider
        self.accountIdentity = accountIdentity
        self.chatGPTAuthenticated = chatGPTAuthenticated
    }
}

public enum CodexModelProviderCapability:
    Equatable,
    Sendable
{
    case namespaceTools
    case imageGeneration
    case webSearch
}

public enum CodexModelCatalogPhase:
    Equatable,
    Sendable
{
    case loading
    case loaded
    case failed
}

public enum CodexModelCatalogProblem:
    Error,
    Equatable,
    Sendable
{
    case repeatedCursor(String)
    case transport(String)
    case server(code: Int64, message: String)
    case invalidResponse(String)

    public var message: String {
        switch self {
        case let .repeatedCursor(cursor):
            "The model catalog repeated cursor \(cursor)."
        case let .transport(message):
            message
        case let .server(code, message):
            "App server error \(code): \(message)"
        case let .invalidResponse(message):
            message
        }
    }
}

public struct CodexModelCatalogPageRequest:
    Equatable,
    Sendable
{
    public let source: CodexModelCatalogSource
    public let loadID: UInt64
    public let pageIndex: UInt32
    public let params: CodexModelListParams

    fileprivate init(
        source: CodexModelCatalogSource,
        loadID: UInt64,
        pageIndex: UInt32,
        params: CodexModelListParams
    ) {
        self.source = source
        self.loadID = loadID
        self.pageIndex = pageIndex
        self.params = params
    }
}

public struct CodexModelCatalogCapabilitiesRequest:
    Equatable,
    Sendable
{
    public let source: CodexModelCatalogSource
    public let loadID: UInt64

    fileprivate init(source: CodexModelCatalogSource, loadID: UInt64) {
        self.source = source
        self.loadID = loadID
    }
}

public struct CodexModelCatalogLoad:
    Equatable,
    Sendable
{
    public let firstPage: CodexModelCatalogPageRequest
    public let capabilities: CodexModelCatalogCapabilitiesRequest
}

public struct CodexModelCatalogSnapshot: Equatable, Sendable {
    public let source: CodexModelCatalogSource
    public let models: [CodexModelConfiguration]
    public let capabilities: CodexModelProviderCapabilities

    public init(
        source: CodexModelCatalogSource,
        models: [CodexModelConfiguration],
        capabilities: CodexModelProviderCapabilities
    ) {
        self.source = source
        self.models = models
        self.capabilities = capabilities
    }
}

public struct CodexModelSelection: Equatable, Sendable {
    public let modelID: String?
    public let reasoningEffortRaw: String?
    public let model: CodexModelConfiguration?
    public let isAvailable: Bool

    public init(
        modelID: String?,
        reasoningEffortRaw: String?,
        model: CodexModelConfiguration?,
        isAvailable: Bool
    ) {
        self.modelID = modelID
        self.reasoningEffortRaw = reasoningEffortRaw
        self.model = model
        self.isAvailable = isAvailable
    }

    /// Provider-facing runtime slug. Persisted selections retain their
    /// original stable catalog id, while requests use the provider's current
    /// model identifier only after the catalog has validated the selection.
    public var providerModelID: String? {
        guard isAvailable else {
            return nil
        }
        return model?.model
    }
}

/// Value-typed editor buffer kept separate from the persisted defaults used
/// when creating future tasks.
public struct CodexAgentSettingsDraft: Equatable, Sendable {
    public var approvalPolicyRaw: String
    public var sandboxModeRaw: String
    public var modelID: String
    public var reasoningEffortRaw: String

    public init(
        approvalPolicyRaw: String,
        sandboxModeRaw: String,
        modelID: String,
        reasoningEffortRaw: String
    ) {
        self.approvalPolicyRaw = approvalPolicyRaw
        self.sandboxModeRaw = sandboxModeRaw
        self.modelID = modelID
        self.reasoningEffortRaw = reasoningEffortRaw
    }
}

public struct CodexModelCatalogViewState: Equatable, Sendable {
    public private(set) var phase: CodexModelCatalogPhase
    public private(set) var problem: CodexModelCatalogProblem?
    public private(set) var models: [CodexModelConfiguration]
    public private(set) var capabilities: CodexModelProviderCapabilities?
    public private(set) var source: CodexModelCatalogSource?
    public private(set) var requestedSource: CodexModelCatalogSource?
    public private(set) var lastGood: CodexModelCatalogSnapshot?

    private var nextLoadID: UInt64
    private var active: ActiveLoad?

    public init() {
        phase = .loading
        problem = nil
        models = []
        capabilities = nil
        source = nil
        requestedSource = nil
        lastGood = nil
        nextLoadID = 0
        active = nil
    }

    public var defaultModel: CodexModelConfiguration? {
        models.first(where: \.isDefault)
    }

    public var canRunModelOperations: Bool {
        phase == .loaded
            && selection(
                modelID: nil,
                reasoningEffortRaw: nil
            ).isAvailable
    }

    public var isStale: Bool {
        guard lastGood != nil else {
            return false
        }
        return phase != .loaded || source != requestedSource
    }

    public func model(id: String) -> CodexModelConfiguration? {
        models.first { $0.id == id }
    }

    /// Resolves the runtime model slug used by thread and turn settings. The
    /// stable catalog id is accepted as well for older persisted clients, but
    /// the caller's original value is never rewritten implicitly.
    public func model(selectionID: String) -> CodexModelConfiguration? {
        models.first {
            $0.model == selectionID || $0.id == selectionID
        }
    }

    public func capabilityGate(
        _ capability: CodexModelProviderCapability
    ) -> Bool {
        guard phase == .loaded, let capabilities else {
            return false
        }
        switch capability {
        case .namespaceTools:
            return capabilities.namespaceTools
        case .imageGeneration:
            return capabilities.imageGeneration
        case .webSearch:
            return capabilities.webSearch
        }
    }

    public func selection(
        modelID: String?,
        reasoningEffortRaw: String?
    ) -> CodexModelSelection {
        guard let modelID else {
            guard let model = defaultModel else {
                return CodexModelSelection(
                    modelID: nil,
                    reasoningEffortRaw: nil,
                    model: nil,
                    isAvailable: false
                )
            }
            return CodexModelSelection(
                modelID: model.model,
                reasoningEffortRaw: model.defaultReasoningEffort.rawValue,
                model: model,
                isAvailable: model.supportedReasoningEfforts.contains(
                    model.defaultReasoningEffort
                )
            )
        }

        guard let model = model(selectionID: modelID) else {
            return CodexModelSelection(
                modelID: modelID,
                reasoningEffortRaw: reasoningEffortRaw,
                model: nil,
                isAvailable: false
            )
        }

        let effortRaw =
            reasoningEffortRaw ?? model.defaultReasoningEffort.rawValue
        let effort = CodexReasoningEffort(rawValue: effortRaw)
        return CodexModelSelection(
            modelID: modelID,
            reasoningEffortRaw: effortRaw,
            model: model,
            isAvailable: effort.map {
                model.supportedReasoningEfforts.contains($0)
            } ?? false
        )
    }

    @discardableResult
    public mutating func beginLoad(
        source: CodexModelCatalogSource,
        pageLimit: UInt32 = 100
    ) -> CodexModelCatalogLoad {
        nextLoadID &+= 1
        let loadID = nextLoadID
        let params = CodexModelListParams(
            cursor: .omitted,
            limit: .value(pageLimit),
            includeHidden: .value(false)
        )
        let firstPage = CodexModelCatalogPageRequest(
            source: source,
            loadID: loadID,
            pageIndex: 0,
            params: params
        )
        let capabilities = CodexModelCatalogCapabilitiesRequest(
            source: source,
            loadID: loadID
        )

        requestedSource = source
        phase = .loading
        problem = nil
        active = ActiveLoad(
            source: source,
            loadID: loadID,
            pageLimit: pageLimit,
            pendingPage: firstPage,
            capabilitiesRequest: capabilities
        )
        return CodexModelCatalogLoad(
            firstPage: firstPage,
            capabilities: capabilities
        )
    }

    /// Accepts one page only when it belongs to the currently active source
    /// and is the exact page that is pending. Returns the next opaque page
    /// request, if any.
    @discardableResult
    public mutating func receive(
        _ response: CodexModelListResponse,
        for request: CodexModelCatalogPageRequest
    ) -> CodexModelCatalogPageRequest? {
        guard var active,
              active.matches(request),
              active.pendingPage == request
        else {
            return nil
        }

        active.models.append(contentsOf: response.data)
        if let nextCursor = response.nextCursor {
            if active.seenCursors.contains(nextCursor) {
                self.active = active
                failActive(.repeatedCursor(nextCursor))
                return nil
            }
            active.seenCursors.insert(nextCursor)
            let nextPage = CodexModelCatalogPageRequest(
                source: active.source,
                loadID: active.loadID,
                pageIndex: request.pageIndex &+ 1,
                params: CodexModelListParams(
                    cursor: .value(nextCursor),
                    limit: .value(active.pageLimit),
                    includeHidden: .value(false)
                )
            )
            active.pendingPage = nextPage
            self.active = active
            return nextPage
        }

        active.pendingPage = nil
        active.didFinishPages = true
        self.active = active
        commitIfComplete()
        return nil
    }

    public mutating func receive(
        _ response: CodexModelProviderCapabilities,
        for request: CodexModelCatalogCapabilitiesRequest
    ) {
        guard var active,
              active.matches(request),
              active.capabilitiesRequest == request
        else {
            return
        }
        active.capabilities = response
        self.active = active
        commitIfComplete()
    }

    public mutating func fail(
        _ problem: CodexModelCatalogProblem,
        for request: CodexModelCatalogPageRequest
    ) {
        guard let active,
              active.matches(request),
              active.pendingPage == request
        else {
            return
        }
        failActive(problem)
    }

    public mutating func fail(
        _ problem: CodexModelCatalogProblem,
        for request: CodexModelCatalogCapabilitiesRequest
    ) {
        guard let active,
              active.matches(request),
              active.capabilitiesRequest == request
        else {
            return
        }
        failActive(problem)
    }

    private mutating func commitIfComplete() {
        guard let active,
              active.didFinishPages,
              let capabilities = active.capabilities
        else {
            return
        }

        let snapshot = CodexModelCatalogSnapshot(
            source: active.source,
            models: active.models,
            capabilities: capabilities
        )
        models = snapshot.models
        self.capabilities = snapshot.capabilities
        source = snapshot.source
        requestedSource = snapshot.source
        lastGood = snapshot
        phase = .loaded
        problem = nil
        self.active = nil
    }

    private mutating func failActive(
        _ problem: CodexModelCatalogProblem
    ) {
        phase = .failed
        self.problem = problem
        active = nil
    }

    private struct ActiveLoad: Equatable, Sendable {
        let source: CodexModelCatalogSource
        let loadID: UInt64
        let pageLimit: UInt32
        var pendingPage: CodexModelCatalogPageRequest?
        let capabilitiesRequest: CodexModelCatalogCapabilitiesRequest
        var models: [CodexModelConfiguration] = []
        var capabilities: CodexModelProviderCapabilities?
        var didFinishPages = false
        var seenCursors: Set<String> = []

        func matches(_ request: CodexModelCatalogPageRequest) -> Bool {
            request.loadID == loadID && request.source == source
        }

        func matches(
            _ request: CodexModelCatalogCapabilitiesRequest
        ) -> Bool {
            request.loadID == loadID && request.source == source
        }
    }
}
