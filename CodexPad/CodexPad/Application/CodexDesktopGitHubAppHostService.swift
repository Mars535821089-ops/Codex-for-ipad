import Foundation

/// iPad host boundary for the released desktop `github` AppHost service.
///
/// The desktop service delegates each request to the Git manager and the
/// request's app-server client. iPad callers inject those native boundaries;
/// this service never substitutes shell Git or fabricates GitHub results.
public actor CodexDesktopGitHubAppHostService {
    public typealias Value = CodexDesktopAppHostRPC.Value

    public enum RequestKind: String, CaseIterable, Sendable {
        case ghCLIStatus = "gh-cli-status"
        case ghCurrentUser = "gh-current-user"
        case ghUserSearch = "gh-user-search"
        case ghPRCreate = "gh-pr-create"
        case ghPRBoard = "gh-pr-board"
        case ghPRSearch = "gh-pr-search"
        case ghPRMedia = "gh-pr-media"
        case ghPRStatus = "gh-pr-status"
        case ghPRDiff = "gh-pr-diff"
        case ghPRComment = "gh-pr-comment"
        case ghPRReviewThreadUpdate = "gh-pr-review-thread-update"
        case ghPRMerge = "gh-pr-merge"
        case ghPRSubmitReview = "gh-pr-submit-review"
        case ghPRUpdate = "gh-pr-update"
    }

    public struct Request: Equatable, Sendable {
        public let kind: RequestKind
        public let payload: Value
        public let source: String

        public init(
            kind: RequestKind,
            payload: Value,
            source: String
        ) {
            self.kind = kind
            self.payload = payload
            self.source = source
        }
    }

    public struct Operation:
        Equatable,
        Hashable,
        RawRepresentable,
        Sendable
    {
        public let rawValue: String

        public init(rawValue: String) {
            self.rawValue = rawValue
        }
    }

    public typealias RequestStart =
        @Sendable (Request) async throws -> Operation
    public typealias RequestWait =
        @Sendable (Operation) async throws -> Value
    public typealias OperationHook =
        @Sendable (Operation) -> Void

    public enum Error: Swift.Error, Equatable, Sendable {
        case invalidArguments
        case unsupportedKind(String)
        case unavailable(service: String, method: String)
        case unsupportedMethod(service: String, method: String)
    }

    private let requestOperation: RequestStart?
    private let requestWait: RequestWait?
    private let requestCancel: OperationHook?
    private let requestDispose: OperationHook?

    public init(
        requestOperation: RequestStart? = nil,
        requestWait: RequestWait? = nil,
        requestCancel: OperationHook? = nil,
        requestDispose: OperationHook? = nil
    ) {
        self.requestOperation = requestOperation
        self.requestWait = requestWait
        self.requestCancel = requestCancel
        self.requestDispose = requestDispose
    }

    public func invoke(
        service: String,
        method: String,
        arguments: [Value]?
    ) async throws -> Value {
        guard service == "github", method == "request" else {
            throw Error.unsupportedMethod(
                service: service,
                method: method
            )
        }
        let request = try Self.request(arguments: arguments)
        guard let requestOperation, let requestWait else {
            if request.kind == .ghCLIStatus {
                // The iPad host does not bundle the desktop `gh` executable.
                // Report that capability boundary without claiming auth.
                return .object([
                    "isInstalled": .bool(false),
                    "isAuthenticated": .bool(false),
                ])
            }
            throw Error.unavailable(
                service: service,
                method: method
            )
        }

        let operation = try await requestOperation(request)
        let lifecycle = GitHubOperationLifecycle(
            operation: operation,
            cancel: requestCancel,
            dispose: requestDispose
        )
        do {
            let result = try await withTaskCancellationHandler {
                try await requestWait(operation)
            } onCancel: {
                lifecycle.cancel()
            }
            lifecycle.dispose()
            return result
        } catch {
            if error is CancellationError {
                lifecycle.cancel()
            }
            lifecycle.dispose()
            throw error
        }
    }

    private static func request(
        arguments: [Value]?
    ) throws -> Request {
        guard let arguments,
              arguments.count == 3,
              case let .string(rawKind) = arguments[0],
              case .object = arguments[1],
              case let .string(source) = arguments[2],
              !source.isEmpty
        else {
            throw Error.invalidArguments
        }
        guard let kind = RequestKind(rawValue: rawKind) else {
            throw Error.unsupportedKind(rawKind)
        }
        return .init(
            kind: kind,
            payload: arguments[1],
            source: source
        )
    }
}

private final class GitHubOperationLifecycle: @unchecked Sendable {
    typealias Operation = CodexDesktopGitHubAppHostService.Operation
    typealias Hook = CodexDesktopGitHubAppHostService.OperationHook

    private let operation: Operation
    private let cancelHook: Hook?
    private let disposeHook: Hook?
    private let lock = NSLock()
    private var didCancel = false
    private var didDispose = false

    init(
        operation: Operation,
        cancel: Hook?,
        dispose: Hook?
    ) {
        self.operation = operation
        self.cancelHook = cancel
        self.disposeHook = dispose
    }

    func cancel() {
        let shouldRun = lock.withLock {
            guard !didCancel else {
                return false
            }
            didCancel = true
            return true
        }
        if shouldRun {
            cancelHook?(operation)
        }
    }

    func dispose() {
        let shouldRun = lock.withLock {
            guard !didDispose else {
                return false
            }
            didDispose = true
            return true
        }
        if shouldRun {
            disposeHook?(operation)
        }
    }
}
