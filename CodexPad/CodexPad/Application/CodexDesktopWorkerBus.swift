#if SWIFT_PACKAGE
    import CodexPadDomain
    import CodexPadProtocolBridge
#endif
import CryptoKit
import Foundation

public struct CodexDesktopWorkerRequest: Equatable, Sendable {
    public let workerID: String
    public let id: String
    public let method: String
    public let params: CodexJSONValue
    public let trace: CodexJSONValue?
    public let enqueuedAtMs: CodexJSONValue?

    public init(
        workerID: String,
        id: String,
        method: String,
        params: CodexJSONValue,
        trace: CodexJSONValue? = nil,
        enqueuedAtMs: CodexJSONValue? = nil
    ) {
        self.workerID = workerID
        self.id = id
        self.method = method
        self.params = params
        self.trace = trace
        self.enqueuedAtMs = enqueuedAtMs
    }
}

public enum CodexDesktopWorkerBusError:
    Error,
    Equatable,
    Sendable,
    CustomStringConvertible
{
    case invalidEnvelope
    case workerIDMismatch(expected: String, actual: String)

    public var description: String {
        switch self {
        case .invalidEnvelope:
            return "Invalid worker message envelope"
        case let .workerIDMismatch(expected, actual):
            return "Mismatched worker id: expected \(expected), got \(actual)"
        }
    }
}

public struct CodexDesktopWorkerMethodError:
    Error,
    Equatable,
    Sendable,
    CustomStringConvertible
{
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var description: String {
        message
    }
}

public enum CodexDesktopWorkerDiagnostic: Equatable, Sendable {
    case request(method: String)
    case result(method: String, outcome: Outcome)

    public enum Outcome: Equatable, Sendable {
        case value
        case null
        case error
    }
}

public protocol CodexDesktopWorkerRequestHandling: Sendable {
    func handle(
        _ request: CodexDesktopWorkerRequest
    ) async throws -> CodexJSONValue
}

public protocol CodexDesktopWorkerEventRequestHandling:
    CodexDesktopWorkerRequestHandling
{
    func handle(
        _ request: CodexDesktopWorkerRequest,
        emit: @escaping @Sendable (CodexJSONValue) async -> Void
    ) async throws -> CodexJSONValue
}

/// Reproduces the released Electron main-process worker RPC boundary. Requests
/// and cancellations arrive on a dynamic worker channel; responses and events
/// are returned through the renderer's matching `for-view` subscription.
public actor CodexDesktopWorkerBus {
    public typealias Output =
        @Sendable (CodexDesktopHostMessage) async -> Void
    public typealias Diagnostic =
        @Sendable (CodexDesktopWorkerDiagnostic) async -> Void

    private struct InFlight {
        let token: UUID
        let task: Task<Void, Never>
    }

    private let handlers:
        [String: any CodexDesktopWorkerRequestHandling]
    private let output: Output
    private let diagnostic: Diagnostic?
    private var inFlight: [String: InFlight] = [:]

    public init(
        handlers: [String: any CodexDesktopWorkerRequestHandling],
        output: @escaping Output,
        diagnostic: Diagnostic? = nil
    ) {
        self.handlers = handlers
        self.output = output
        self.diagnostic = diagnostic
    }

    public func receive(
        workerID: String,
        message: CodexJSONValue
    ) async throws {
        guard !workerID.isEmpty,
              case let .object(fields) = message,
              case let .string(type)? = fields["type"],
              case let .string(innerWorkerID)? = fields["workerId"],
              !innerWorkerID.isEmpty
        else {
            throw CodexDesktopWorkerBusError.invalidEnvelope
        }
        guard innerWorkerID == workerID else {
            throw CodexDesktopWorkerBusError.workerIDMismatch(
                expected: workerID,
                actual: innerWorkerID
            )
        }

        switch type {
        case "worker-request":
            guard case let .object(requestFields)? = fields["request"],
                  case let .string(id)? = requestFields["id"],
                  !id.isEmpty,
                  case let .string(method)? = requestFields["method"],
                  !method.isEmpty
            else {
                throw CodexDesktopWorkerBusError.invalidEnvelope
            }
            let request = CodexDesktopWorkerRequest(
                workerID: workerID,
                id: id,
                method: method,
                params: requestFields["params"] ?? .null,
                trace: requestFields["trace"],
                enqueuedAtMs: requestFields["enqueuedAtMs"]
            )
            await diagnostic?(.request(method: method))
            start(request)

        case "worker-request-cancel":
            guard case let .string(id)? = fields["id"], !id.isEmpty else {
                throw CodexDesktopWorkerBusError.invalidEnvelope
            }
            cancel(requestID: id)

        default:
            throw CodexDesktopWorkerBusError.invalidEnvelope
        }
    }

    public func publishEvent(
        workerID: String,
        event: CodexJSONValue
    ) async {
        await output(
            .event(
                type: "worker-message",
                payload: .object([
                    "workerID": .string(workerID),
                    "message": .object([
                        "type": .string("worker-event"),
                        "workerId": .string(workerID),
                        "event": event,
                    ]),
                ])
            )
        )
    }

    public func cancelAll() {
        let pending = inFlight.values
        inFlight.removeAll()
        for request in pending {
            request.task.cancel()
        }
    }

    private func start(_ request: CodexDesktopWorkerRequest) {
        if let existing = inFlight.removeValue(forKey: request.id) {
            existing.task.cancel()
        }

        let token = UUID()
        let handler = handlers[request.workerID]
        let task = Task { [weak self] in
            let result: CodexJSONValue
            do {
                guard let handler else {
                    throw CodexDesktopWorkerMethodError(
                        "Unsupported worker: \(request.workerID)"
                    )
                }
                let value: CodexJSONValue
                if let eventHandler =
                    handler as? any CodexDesktopWorkerEventRequestHandling
                {
                    value = try await eventHandler.handle(
                        request,
                        emit: { [weak self] event in
                            await self?.publishEvent(
                                workerID: request.workerID,
                                event: event
                            )
                        }
                    )
                } else {
                    value = try await handler.handle(request)
                }
                result = .object([
                    "type": .string("ok"),
                    "value": value,
                ])
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else {
                    return
                }
                result = .object([
                    "type": .string("error"),
                    "error": .object([
                        "message": .string(String(describing: error))
                    ]),
                ])
            }
            await self?.reportResult(
                method: request.method,
                result: result
            )
            guard !Task.isCancelled else {
                return
            }
            await self?.finish(
                request: request,
                token: token,
                result: result
            )
        }
        inFlight[request.id] = InFlight(token: token, task: task)
    }

    private func reportResult(
        method: String,
        result: CodexJSONValue
    ) async {
        guard case let .object(fields) = result,
              case let .string(type)? = fields["type"]
        else {
            return
        }
        let outcome: CodexDesktopWorkerDiagnostic.Outcome
        switch type {
        case "ok":
            outcome = fields["value"] == .null ? .null : .value
        case "error":
            outcome = .error
        default:
            return
        }
        await diagnostic?(.result(method: method, outcome: outcome))
    }

    private func cancel(requestID: String) {
        inFlight.removeValue(forKey: requestID)?.task.cancel()
    }

    private func finish(
        request: CodexDesktopWorkerRequest,
        token: UUID,
        result: CodexJSONValue
    ) async {
        guard inFlight[request.id]?.token == token else {
            return
        }
        inFlight.removeValue(forKey: request.id)
        await output(
            .event(
                type: "worker-message",
                payload: .object([
                    "workerID": .string(request.workerID),
                    "message": .object([
                        "type": .string("worker-response"),
                        "workerId": .string(request.workerID),
                        "response": .object([
                            "id": .string(request.id),
                            "method": .string(request.method),
                            "result": result,
                        ]),
                    ]),
                ])
            )
        )
    }
}

public actor CodexDesktopUnsupportedGitWorker:
    CodexDesktopWorkerRequestHandling
{
    public init() {}

    public func handle(
        _ request: CodexDesktopWorkerRequest
    ) async throws -> CodexJSONValue {
        throw CodexDesktopWorkerMethodError(
            "Unsupported git worker method: \(request.method)"
        )
    }
}

public actor CodexDesktopGitWorker:
    CodexDesktopWorkerEventRequestHandling
{
    public typealias Runner =
        @Sendable (
            _ arguments: [String],
            _ cwd: String
        ) async throws -> CodexDesktopCommandExecResult
    public typealias EnvironmentRunner =
        @Sendable (
            _ arguments: [String],
            _ cwd: String,
            _ environment: [String: String?]?
        ) async throws -> CodexDesktopCommandExecResult
    public typealias EmbeddedReader =
        @Sendable (
            _ method: String,
            _ params: CodexJSONValue
        ) async throws -> CodexJSONValue

    private let run: Runner
    private let runWithEnvironment: EnvironmentRunner?
    private let embeddedReader: EmbeddedReader?

    public init(run: @escaping Runner) {
        self.run = run
        runWithEnvironment = nil
        embeddedReader = nil
    }

    public init(
        runWithEnvironment: @escaping EnvironmentRunner,
        embeddedReader: EmbeddedReader? = nil
    ) {
        self.runWithEnvironment = runWithEnvironment
        self.embeddedReader = embeddedReader
        self.run = { arguments, cwd in
            try await runWithEnvironment(arguments, cwd, nil)
        }
    }

    public func handle(
        _ request: CodexDesktopWorkerRequest
    ) async throws -> CodexJSONValue {
        try await handle(request, emit: { _ in })
    }

    public func handle(
        _ request: CodexDesktopWorkerRequest,
        emit: @escaping @Sendable (CodexJSONValue) async -> Void
    ) async throws -> CodexJSONValue {
        guard case let .object(params) = request.params else {
            throw CodexDesktopWorkerMethodError(
                "Invalid params for git worker method: \(request.method)"
            )
        }

        if Self.embeddedReadMethods.contains(request.method),
           let embeddedReader
        {
            do {
                return try await embeddedReader(
                    request.method,
                    request.params
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // macOS/package callers retain the released external-Git
                // execution path when no embedded implementation is present.
            }
        }

        switch request.method {
        case "watch-repo", "unwatch-repo":
            _ = try requiredString("root", in: params)
            return .object(["success": .bool(true)])

        case "invalidate-stable-metadata":
            return .object(["success": .bool(true)])

        case "invalidate-git-read-caches":
            _ = try requiredString("root", in: params)
            _ = try optionalBool("clearUntrackedPathsCache", in: params)
            return .object(["success": .bool(true)])

        case "dispose-git-init-watch":
            _ = try requiredString("cwd", in: params)
            return .object(["success": .bool(true)])

        case "recover-live-queries":
            if let cwd = try optionalString("cwd", in: params) {
                _ = cwd
            }
            guard case let .array(subscriptionIDs)? =
                params["subscriptionIds"],
                subscriptionIDs.allSatisfy({
                    if case let .string(value) = $0 {
                        return !value.isEmpty
                    }
                    return false
                })
            else {
                throw CodexDesktopWorkerMethodError(
                    "Invalid git worker parameter: subscriptionIds"
                )
            }
            return .null

        case "subscribe-live-query":
            return try await subscribeLiveQuery(
                request: request,
                params: params,
                emit: emit
            )

        case "availability":
            let result = try await run(["git", "--version"], "/")
            return .object(["available": .bool(result.exitCode == 0)])

        case "stable-metadata":
            let cwd = try requiredString("cwd", in: params)
            let rootResult = try await run(
                ["git", "-C", cwd, "rev-parse", "--show-toplevel"],
                cwd
            )
            guard rootResult.exitCode == 0 else {
                return .null
            }
            let root = trimmed(rootResult.stdout)
            let commonResult = try await run(
                ["git", "-C", root, "rev-parse", "--git-common-dir"],
                root
            )
            guard commonResult.exitCode == 0 else {
                return .null
            }
            let rawCommon = trimmed(commonResult.stdout)
            let commonDir = (rawCommon as NSString).isAbsolutePath
                ? (rawCommon as NSString).standardizingPath
                : ((root as NSString).appendingPathComponent(rawCommon)
                    as NSString).standardizingPath
            return .object([
                "commonDir": .string(commonDir),
                "root": .string(root),
            ])

        case "current-branch", "current-branch-snapshot":
            let root = try requiredString("root", in: params)
            let result = try await run(
                ["git", "-C", root, "symbolic-ref", "--short", "-q", "HEAD"],
                root
            )
            return .object([
                "branch": result.exitCode == 0
                    ? .string(trimmed(result.stdout))
                    : .null
            ])

        case "clone-state":
            let root = try requiredString("root", in: params)
            let shallow = try await run(
                [
                    "git", "-C", root, "rev-parse",
                    "--is-shallow-repository",
                ],
                root
            )
            let partial = try await run(
                [
                    "git", "-C", root, "config", "--get-regexp",
                    "^(extensions\\.partialclone|remote\\..*\\.(promisor|partialclonefilter))$",
                ],
                root
            )
            return .object([
                "isShallow": .bool(
                    shallow.exitCode == 0
                        && trimmed(shallow.stdout) == "true"
                ),
                "isPartialClone": .bool(
                    partial.exitCode == 0
                        && hasPartialCloneConfiguration(partial.stdout)
                ),
            ])

        case "branch-exists":
            let root = try requiredString("root", in: params)
            let branch = try requiredString("branch", in: params)
            let result = try await run(
                [
                    "git", "-C", root, "show-ref", "--verify", "--quiet",
                    "refs/heads/\(branch)",
                ],
                root
            )
            return .object(["exists": .bool(result.exitCode == 0)])

        case "config-value":
            let root = try requiredString("root", in: params)
            let key = try requiredString("key", in: params)
            let scope = try optionalString("scope", in: params)
            let scopeArgument: String?
            switch scope {
            case "global":
                scopeArgument = "--global"
            case "worktree":
                scopeArgument = "--worktree"
            case "local", nil:
                scopeArgument = "--local"
            default:
                throw CodexDesktopWorkerMethodError(
                    "Invalid git config scope: \(scope ?? "")"
                )
            }
            let result = try await run(
                ["git", "-C", root, "config", scopeArgument!, "--get", key],
                root
            )
            return .object([
                "value": result.exitCode == 0
                    ? .string(trimmed(result.stdout))
                    : .null
            ])

        case "status-summary":
            let cwd = try requiredString("cwd", in: params)
            let includeUntracked =
                try optionalBool(
                    "includeUntrackedFiles",
                    in: params
                ) ?? true
            let result = try await run(
                [
                    "git", "-C", cwd, "status", "--renames",
                    "--porcelain=v1",
                    includeUntracked
                        ? "--untracked-files=all"
                        : "--untracked-files=no",
                ],
                cwd
            )
            guard result.exitCode == 0 else {
                return .object([
                    "type": .string("error"),
                    "failureReason": .string("repository_unavailable"),
                ])
            }
            return statusSummary(result.stdout)

        case "upstream-branch":
            let root = try requiredString("root", in: params)
            let branchResult = try await run(
                ["git", "-C", root, "symbolic-ref", "--short", "-q", "HEAD"],
                root
            )
            let branch = branchResult.exitCode == 0
                ? trimmed(branchResult.stdout)
                : ""
            let upstreamResult = try await run(
                [
                    "git", "-C", root, "rev-parse", "--abbrev-ref",
                    "--symbolic-full-name", "@{upstream}",
                ],
                root
            )
            return .object([
                "branch": branch.isEmpty ? .null : .string(branch),
                "upstream": upstreamResult.exitCode == 0
                    ? .object([
                        "branch": .string(trimmed(upstreamResult.stdout))
                    ])
                    : .null,
            ])

        case "default-branch":
            let root = try requiredString("root", in: params)
            let remoteHead = try await run(
                [
                    "git", "-C", root, "symbolic-ref", "--short", "-q",
                    "refs/remotes/origin/HEAD",
                ],
                root
            )
            if remoteHead.exitCode == 0 {
                let value = trimmed(remoteHead.stdout)
                return .object([
                    "branch": .string(
                        value.hasPrefix("origin/")
                            ? String(value.dropFirst("origin/".count))
                            : value
                    )
                ])
            }
            for candidate in ["main", "master"] {
                let exists = try await run(
                    [
                        "git", "-C", root, "show-ref", "--verify", "--quiet",
                        "refs/heads/\(candidate)",
                    ],
                    root
                )
                if exists.exitCode == 0 {
                    return .object(["branch": .string(candidate)])
                }
            }
            return .object(["branch": .null])

        case "base-branch":
            let root = try requiredString("root", in: params)
            let branchResult = try await run(
                ["git", "-C", root, "symbolic-ref", "--short", "-q", "HEAD"],
                root
            )
            guard branchResult.exitCode == 0 else {
                return .object(["local": .null, "remote": .null])
            }
            let branch = trimmed(branchResult.stdout)
            let merge = try await run(
                [
                    "git", "-C", root, "config", "--get",
                    "branch.\(branch).merge",
                ],
                root
            )
            let remote = try await run(
                [
                    "git", "-C", root, "config", "--get",
                    "branch.\(branch).remote",
                ],
                root
            )
            let mergeValue = trimmed(merge.stdout)
            return .object([
                "local": merge.exitCode == 0
                    ? .string(
                        mergeValue.hasPrefix("refs/heads/")
                            ? String(
                                mergeValue.dropFirst("refs/heads/".count)
                            )
                            : mergeValue
                    )
                    : .null,
                "remote": remote.exitCode == 0
                    ? .string(trimmed(remote.stdout))
                    : .null,
            ])

        case "recent-branches":
            let root = try requiredString("root", in: params)
            let limit = try boundedInteger(
                "limit",
                in: params,
                defaultValue: 10,
                range: 1 ... 100
            )
            let result = try await run(
                [
                    "git", "-C", root, "for-each-ref",
                    "--sort=-committerdate",
                    "--format=%(refname:short)",
                    "--count=\(limit)",
                    "refs/heads", "refs/remotes",
                ],
                root
            )
            guard result.exitCode == 0 else {
                throw gitCommandError(result)
            }
            return .object([
                "branches": .array(
                    lines(result.stdout).map(CodexJSONValue.string)
                )
            ])

        case "search-branches":
            let root = try requiredString("root", in: params)
            let query = try requiredString("query", in: params)
                .lowercased()
            let limit = try boundedInteger(
                "limit",
                in: params,
                defaultValue: 20,
                range: 1 ... 20
            )
            let preserveRemoteRefs =
                try optionalBool("preserveRemoteRefs", in: params) ?? false
            let result = try await run(
                [
                    "git", "-C", root, "for-each-ref",
                    "--sort=-committerdate",
                    "--format=%(refname)",
                    "refs/heads", "refs/remotes",
                ],
                root
            )
            guard result.exitCode == 0 else {
                throw gitCommandError(result)
            }
            return searchBranches(
                lines(result.stdout),
                query: query,
                limit: limit,
                preserveRemoteRefs: preserveRemoteRefs
            )

        case "git-origins":
            guard case let .array(dirValues)? = params["dirs"] else {
                throw CodexDesktopWorkerMethodError(
                    "Invalid git worker parameter: dirs"
                )
            }
            var seen: Set<String> = []
            var origins: [CodexJSONValue] = []
            for value in dirValues {
                guard case let .string(dir) = value,
                      !dir.isEmpty,
                      !dir.contains("\u{0}"),
                      seen.insert(
                        (dir as NSString).standardizingPath
                      ).inserted
                else {
                    continue
                }
                if let origin = try await resolveOrigin(dir: dir) {
                    origins.append(origin)
                }
            }
            return .object(["origins": .array(origins)])

        case "branch-ahead-count":
            let root = try requiredString("root", in: params)
            let result = try await run(
                [
                    "git", "-C", root, "rev-list", "--count",
                    "@{upstream}..HEAD",
                ],
                root
            )
            let count = result.exitCode == 0
                ? Int64(trimmed(result.stdout)) ?? 0
                : 0
            return .object(["commitsAhead": .integer(count)])

        case "branch-commits":
            let root = try requiredString("root", in: params)
            let baseBranch = try requiredString("baseBranch", in: params)
            let result = try await run(
                [
                    "git", "-C", root, "log", "--max-count=100",
                    "--format=%H%x00%cI%x00%s%x00%B%x1e",
                    "\(baseBranch)..HEAD",
                ],
                root
            )
            return .object([
                "commits": .array(
                    result.exitCode == 0
                        ? parseBranchCommits(result.stdout)
                        : []
                )
            ])

        case "nearest-ancestor-branch":
            let root = try requiredString("root", in: params)
            let currentBranch = try optionalString(
                "currentBranch",
                in: params
            )
            guard case let .array(candidateValues)? = params["candidates"]
            else {
                throw CodexDesktopWorkerMethodError(
                    "Invalid git worker parameter: candidates"
                )
            }
            var nearest: (branch: String, distance: Int64)?
            var seen: Set<String> = []
            for value in candidateValues {
                guard case let .string(candidate) = value else {
                    continue
                }
                let branch = candidate.trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
                guard !branch.isEmpty,
                      branch != currentBranch,
                      seen.insert(branch).inserted
                else {
                    continue
                }
                let comparison = try await run(
                    [
                        "git", "-C", root, "rev-list", "--left-right",
                        "--count", "\(branch)...HEAD",
                    ],
                    root
                )
                guard comparison.exitCode == 0,
                      let counts = parseAheadBehind(comparison.stdout),
                      counts.left == 0,
                      counts.right > 0,
                      nearest == nil || counts.right < nearest!.distance
                else {
                    continue
                }
                nearest = (branch, counts.right)
            }
            return .object([
                "branch": nearest.map { .string($0.branch) } ?? .null
            ])

        case "branch-metadata":
            let cwd = try requiredString("cwd", in: params)
            let rootResult = try await run(
                ["git", "-C", cwd, "rev-parse", "--show-toplevel"],
                cwd
            )
            guard rootResult.exitCode == 0 else {
                return emptyBranchMetadata()
            }
            let root = trimmed(rootResult.stdout)
            let branchResult = try await run(
                ["git", "-C", root, "symbolic-ref", "--short", "-q", "HEAD"],
                root
            )
            let branch = branchResult.exitCode == 0
                ? trimmed(branchResult.stdout)
                : ""
            var baseBranch: CodexJSONValue = .null
            var baseRemote: CodexJSONValue = .null
            if !branch.isEmpty {
                let merge = try await run(
                    [
                        "git", "-C", root, "config", "--get",
                        "branch.\(branch).merge",
                    ],
                    root
                )
                let remote = try await run(
                    [
                        "git", "-C", root, "config", "--get",
                        "branch.\(branch).remote",
                    ],
                    root
                )
                if merge.exitCode == 0 {
                    let value = trimmed(merge.stdout)
                    baseBranch = .string(
                        value.hasPrefix("refs/heads/")
                            ? String(value.dropFirst("refs/heads/".count))
                            : value
                    )
                }
                if remote.exitCode == 0 {
                    baseRemote = .string(trimmed(remote.stdout))
                }
            }
            return .object([
                "gitRoot": .string(root),
                "branch": branch.isEmpty ? .null : .string(branch),
                "baseBranch": baseBranch,
                "baseBranchRemote": baseRemote,
            ])

        case "commit-message-diff":
            let cwd = try requiredString("cwd", in: params)
            let includeUnstaged =
                try optionalBool("includeUnstaged", in: params) ?? false
            let arguments = includeUnstaged
                ? ["git", "-C", cwd, "diff", "--binary", "HEAD"]
                : ["git", "-C", cwd, "diff", "--binary", "--cached"]
            let result = try await run(arguments, cwd)
            guard result.exitCode == 0 else {
                return unknownDiffError()
            }
            return successfulUnifiedDiff(result.stdout)

        case "review-patch":
            let cwd = try requiredString("cwd", in: params)
            let source = try requiredString("source", in: params)
            guard let comparison = try await reviewComparisonArguments(
                source: source,
                params: params,
                cwd: cwd
            ) else {
                return .object([
                    "source": .string(source),
                    "diff": unknownDiffError(),
                ])
            }
            var arguments = ["git", "-C", cwd, "diff", "--binary"]
            arguments.append(contentsOf: comparison)
            let result = try await run(arguments, cwd)
            return .object([
                "source": .string(source),
                "diff": result.exitCode == 0
                    ? successfulUnifiedDiff(result.stdout)
                    : unknownDiffError(),
            ])

        case "review-diff":
            let cwd = try requiredString("cwd", in: params)
            let source = try requiredString("source", in: params)
            guard case let .array(fileValues)? = params["files"],
                  let comparison = try await reviewComparisonArguments(
                      source: source,
                      params: params,
                      cwd: cwd
                  )
            else {
                return staleOrUnknownReviewDiff(
                    source: source,
                    files: params["files"]
                )
            }
            let hideWhitespace =
                try optionalBool("hideWhitespace", in: params) ?? false
            var diffs: [String: CodexJSONValue] = [:]
            for fileValue in fileValues {
                guard case let .object(file) = fileValue,
                      case let .string(path)? = file["path"],
                      isSafeRelativeGitPath(path)
                else {
                    continue
                }
                var arguments = [
                    "git", "-C", cwd, "diff", "--binary", "--full-index",
                    "--find-renames",
                ]
                if hideWhitespace {
                    arguments.append("--ignore-all-space")
                }
                arguments.append(contentsOf: comparison)
                arguments.append("--")
                if case let .string(previousPath)? = file["previousPath"],
                   isSafeRelativeGitPath(previousPath)
                {
                    arguments.append(previousPath)
                }
                arguments.append(path)
                let result = try await run(arguments, cwd)
                diffs[path] = result.exitCode == 0
                    ? successfulFileDiff(result.stdout)
                    : unknownDiffError()
            }
            return .object([
                "type": .string("success"),
                "source": .string(source),
                "diffs": .object(diffs),
            ])

        case "branch-diff-stats":
            let cwd = try requiredString("cwd", in: params)
            guard let comparison = try await reviewComparisonArguments(
                source: "branch",
                params: params,
                cwd: cwd
            ) else {
                return .null
            }
            var arguments = ["git", "-C", cwd, "diff", "--numstat"]
            if try optionalBool("hideWhitespace", in: params) == true {
                arguments.append("--ignore-all-space")
            }
            arguments.append(contentsOf: comparison)
            let diff = try await run(arguments, cwd)
            guard diff.exitCode == 0 else {
                return .null
            }
            var stats = parseNumstat(diff.stdout)
            let includeUntracked =
                try optionalBool("includeUntrackedFiles", in: params) ?? true
            if includeUntracked {
                let untracked = try await untrackedPaths(cwd: cwd)
                guard untracked.success else {
                    return .null
                }
                let limit = 512
                if untracked.paths.count > limit {
                    return .object([
                        "additions": .integer(
                            Int64(stats.reduce(0) { $0 + $1.additions })
                        ),
                        "deletions": .integer(
                            Int64(stats.reduce(0) { $0 + $1.deletions })
                        ),
                        "fileCount": .integer(Int64(stats.count)),
                        "untrackedFilesOmitted": .object([
                            "count": .integer(Int64(untracked.paths.count)),
                            "limit": .integer(Int64(limit)),
                        ]),
                    ])
                }
                stats.append(contentsOf: untracked.paths.map {
                    untrackedFileStat(cwd: cwd, path: $0)
                })
            }
            return branchDiffStats(stats)

        case "review-summary":
            return try await reviewSummary(params)

        case "review-search":
            let cwd = try requiredString("cwd", in: params)
            let source = try requiredString("source", in: params)
            let query = try requiredString("query", in: params)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if query.isEmpty {
                return emptyReviewSearch(source: source, query: query)
            }
            guard let comparison = try await reviewComparisonArguments(
                source: source,
                params: params,
                cwd: cwd
            ) else {
                return reviewSearchError(source: source, query: query)
            }
            var arguments = [
                "git", "-C", cwd, "diff", "--find-renames", "--unified=3",
            ]
            arguments.append(contentsOf: comparison)
            let diff = try await run(arguments, cwd)
            guard diff.exitCode == 0 else {
                return reviewSearchError(source: source, query: query)
            }
            let search = searchReviewDiff(diff.stdout, query: query)
            return .object([
                "type": .string("success"),
                "source": .string(source),
                "query": .string(query),
                "matches": .array(search.matches),
                "totalMatches": .integer(Int64(search.total)),
                "isCapped": .bool(search.capped),
            ])

        case "cat-file":
            let cwd = try requiredString("cwd", in: params)
            guard case let .array(requests)? = params["requests"] else {
                throw CodexDesktopWorkerMethodError(
                    "Invalid git worker parameter: requests"
                )
            }
            let maxBytes = try boundedInteger(
                "maxObjectBytes",
                in: params,
                defaultValue: 5 * 1_024 * 1_024,
                range: 0 ... 20 * 1_024 * 1_024
            )
            if requests.count > 4 {
                return .array(requests.map { _ in unknownDiffError() })
            }
            var objects: [CodexJSONValue] = []
            for requestValue in requests {
                guard case let .object(objectRequest) = requestValue,
                      case let .string(oid)? = objectRequest["oid"],
                      isGitObjectID(oid)
                else {
                    objects.append(notFoundObjectError())
                    continue
                }
                let object = try await run(
                    ["git", "-C", cwd, "cat-file", "-p", oid],
                    cwd
                )
                if object.exitCode == 0 {
                    objects.append(
                        fileObjectResult(object.stdout, maxBytes: maxBytes)
                    )
                    continue
                }
                let fallback = objectRequest["fallbackToDisk"] == .bool(true)
                guard fallback,
                      case let .string(path)? = objectRequest["path"],
                      isSafeRelativeGitPath(path)
                else {
                    objects.append(notFoundObjectError())
                    continue
                }
                let fileURL = URL(fileURLWithPath: cwd)
                    .appendingPathComponent(path)
                guard let data = try? Data(contentsOf: fileURL) else {
                    objects.append(notFoundObjectError())
                    continue
                }
                objects.append(
                    fileObjectResult(data, maxBytes: maxBytes)
                )
            }
            return .array(objects)

        case "blame-file":
            let cwd = try requiredString("cwd", in: params)
            let path = try requiredString("path", in: params)
            guard isSafeRelativeGitPath(path) else {
                return blameError("not-found")
            }
            let blame = try await run(
                [
                    "git", "-C", cwd, "blame", "--porcelain", "--",
                    path,
                ],
                cwd
            )
            guard blame.exitCode == 0 else {
                return blameError(
                    blame.exitCode == 128 ? "not-found" : "unknown"
                )
            }
            let origin = try await run(
                ["git", "-C", cwd, "remote", "get-url", "origin"],
                cwd
            )
            return .object([
                "type": .string("success"),
                "lines": .array(parseBlameLines(blame.stdout)),
                "repositoryWebUrl": origin.exitCode == 0
                    ? repositoryWebURL(trimmed(origin.stdout))
                        .map(CodexJSONValue.string) ?? .null
                    : .null,
            ])

        case "synced-branch":
            let cwd = try requiredString("cwd", in: params)
            guard let config = try await syncedBranchConfig(cwd: cwd) else {
                return .object([
                    "branch": .null,
                    "base": .null,
                    "hasConflicts": .bool(false),
                ])
            }
            let conflicts = try await run(
                ["git", "-C", cwd, "ls-files", "-u", "-z"],
                cwd
            )
            return .object([
                "branch": .string(shortBranchName(config.branch)),
                "base": .string(config.lastSyncedTreeRef),
                "hasConflicts": .bool(
                    conflicts.exitCode == 0 && !conflicts.stdout.isEmpty
                ),
            ])

        case "synced-branch-state":
            return try await syncedBranchState(params)

        case "index-info":
            let cwd = try requiredString("cwd", in: params)
            let result = try await run(
                ["git", "-C", cwd, "rev-parse", "--git-path", "index"],
                cwd
            )
            guard result.exitCode == 0 else {
                return .object(["lastModified": .integer(0)])
            }
            let rawPath = trimmed(result.stdout)
            let indexPath = (rawPath as NSString).isAbsolutePath
                ? rawPath
                : (cwd as NSString).appendingPathComponent(rawPath)
            let attributes = try? FileManager.default.attributesOfItem(
                atPath: indexPath
            )
            let modified = (
                attributes?[.modificationDate] as? Date
            )?.timeIntervalSince1970 ?? 0
            return .object([
                "lastModified": .number(modified * 1_000)
            ])

        case "submodule-paths":
            let root = try requiredString("root", in: params)
            let result = try await run(
                [
                    "git", "-C", root, "config", "--file", ".gitmodules",
                    "--get-regexp", "path",
                ],
                root
            )
            var seen: Set<String> = []
            let paths = result.exitCode == 0
                ? lines(result.stdout).compactMap { line -> String? in
                    guard let value = line.split(
                        whereSeparator: \.isWhitespace
                    ).last.map(String.init),
                        !value.isEmpty,
                        seen.insert(value).inserted
                    else {
                        return nil
                    }
                    return value
                }
                : []
            return .object([
                "paths": .array(paths.map(CodexJSONValue.string))
            ])

        case "create-worktree":
            return try await createWorktree(
                request: request,
                params: params,
                emit: emit
            )

        case "delete-worktree":
            return try await deleteWorktree(params)

        case "restore-worktree":
            return try await restoreWorktree(params)

        case "set-worktree-owner-thread":
            return try await setWorktreeOwnerThread(params)

        case "codex-worktrees":
            return try await codexWorktrees(params)

        case "resolve-worktree-for-thread":
            return try await resolveWorktreeForThread(params)

        case "move-thread-to-local":
            return try await moveThreadToLocal(
                request: request,
                params: params,
                emit: emit
            )

        case "move-thread-to-worktree":
            return try await moveThreadToWorktree(
                request: request,
                params: params,
                emit: emit
            )

        case "move-thread-to-host-worktree":
            return try await moveThreadToHostWorktree(
                request: request,
                params: params,
                emit: emit
            )

        case "cleanup-host-handoff-transfer":
            if let embeddedReader {
                do {
                    return try await embeddedReader(
                        "cleanup-host-handoff-transfer",
                        .object(params)
                    )
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    // macOS/package callers retain the released filesystem path.
                }
            }
            return try cleanupHostHandoffTransfer(params)

        case "worktree-snapshot-ref":
            return try await worktreeSnapshotRef(params)

        case "managed-worktree-state":
            return try await managedWorktreeState(params)

        case "turn-diff-capture-start":
            return try await turnDiffCaptureStart(params)

        case "turn-diff-capture-complete":
            return try await turnDiffCaptureComplete(params)

        case "list-worktrees":
            let cwd = try requiredString("cwd", in: params)
            let result = try await run(
                ["git", "-C", cwd, "worktree", "list", "--porcelain"],
                cwd
            )
            guard result.exitCode == 0 else {
                throw gitCommandError(result)
            }
            return .object([
                "worktrees": .array(parseWorktrees(result.stdout))
            ])

        case "git-init-repo":
            let cwd = try requiredString("cwd", in: params)
            let result = try await run(
                ["git", "-C", cwd, "init"],
                cwd
            )
            guard result.exitCode == 0 else {
                throw gitCommandError(result)
            }
            return .object(["success": .bool(true)])

        case "set-config-value":
            let root = try requiredString("root", in: params)
            let key = try requiredString("key", in: params)
            let scope = try optionalString("scope", in: params)
            let scopeArgument: String
            switch scope {
            case "global":
                scopeArgument = "--global"
            case "worktree":
                scopeArgument = "--worktree"
            case "local", nil:
                scopeArgument = "--local"
            default:
                throw CodexDesktopWorkerMethodError(
                    "Invalid git config scope: \(scope ?? "")"
                )
            }
            let arguments: [String]
            switch params["value"] {
            case let .string(value)?:
                arguments = [
                    "git", "-C", root, "config", scopeArgument, key, value,
                ]
            case nil, .null?:
                arguments = [
                    "git", "-C", root, "config", scopeArgument, "--unset",
                    key,
                ]
            default:
                throw CodexDesktopWorkerMethodError(
                    "Invalid git worker parameter: value"
                )
            }
            let result = try await run(arguments, root)
            return .object([
                "success": .bool(
                    result.exitCode == 0
                        || (
                            result.exitCode == 5
                                && params["value"] == .null
                        )
                )
            ])

        case "commit":
            let cwd = try requiredString("cwd", in: params)
            let message = try requiredString("message", in: params)
            let includeUnstaged =
                try optionalBool("includeUnstaged", in: params) ?? false
            if includeUnstaged {
                let stage = try await run(
                    ["git", "-C", cwd, "add", "-A"],
                    cwd
                )
                guard stage.exitCode == 0 else {
                    let error = commandErrorText(
                        stage,
                        fallback: "Failed to stage changes"
                    )
                    return .object([
                        "status": .string("error"),
                        "error": .string(error),
                        "execOutput": execOutput(
                            stage,
                            command: "git add -A",
                            fallback: error
                        ),
                    ])
                }
            }
            let commit = try await run(
                ["git", "-C", cwd, "commit", "-m", message],
                cwd
            )
            guard commit.exitCode == 0 else {
                let error = commandErrorText(
                    commit,
                    fallback: "Failed to commit changes"
                )
                let stagedDiff = try await run(
                    [
                        "git", "-C", cwd, "diff", "--cached", "--quiet",
                        "--exit-code",
                    ],
                    cwd
                )
                var response: [String: CodexJSONValue] = [
                    "status": .string("error"),
                    "error": .string(error),
                    "execOutput": execOutput(
                        commit,
                        command: "git commit -m",
                        fallback: error
                    ),
                ]
                if stagedDiff.exitCode == 0 {
                    response["errorType"] = .string("nothing-to-commit")
                }
                return .object(response)
            }
            let revision = try await run(
                ["git", "-C", cwd, "rev-parse", "HEAD"],
                cwd
            )
            return .object([
                "status": .string("success"),
                "commitSha": revision.exitCode == 0
                    ? .string(trimmed(revision.stdout))
                    : .null,
            ])

        case "apply-patch":
            return try await applyPatch(params)

        case "apply-changes":
            return try await applyChanges(params)

        case "apply-review-section-changes":
            return try await applyReviewSectionChanges(params)

        case "overwrite-repo":
            return try await overwriteRepository(params)

        default:
            throw CodexDesktopWorkerMethodError(
                "Unsupported git worker method: \(request.method)"
            )
        }
    }

    private static let embeddedReadMethods: Set<String> = [
        "availability",
        "stable-metadata",
        "current-branch",
        "current-branch-snapshot",
        "clone-state",
        "branch-exists",
        "config-value",
        "status-summary",
        "upstream-branch",
        "default-branch",
        "base-branch",
        "branch-metadata",
        "git-origins",
        "index-info",
        "submodule-paths",
        "recent-branches",
        "search-branches",
        "branch-ahead-count",
        "branch-commits",
        "commit-message-diff",
        "review-patch",
        "review-diff",
        "review-search",
        "branch-diff-stats",
        "review-summary",
        "blame-file",
        "synced-branch",
        "synced-branch-state",
        "worktree-snapshot-ref",
        "managed-worktree-state",
        "list-worktrees",
        "codex-worktrees",
        "git-init-repo",
        "git-push",
        "prepare-worktree-snapshot",
        "set-config-value",
        "commit",
        "apply-patch",
        "apply-changes",
        "apply-review-section-changes",
        "delete-worktree",
        "restore-worktree",
        "turn-diff-capture-start",
        "turn-diff-capture-complete",
        "overwrite-repo",
        "set-worktree-owner-thread",
        "resolve-worktree-for-thread",
        "cat-file",
    ]

    private func subscribeLiveQuery(
        request: CodexDesktopWorkerRequest,
        params: [String: CodexJSONValue],
        emit: @escaping @Sendable (CodexJSONValue) async -> Void
    ) async throws -> CodexJSONValue {
        let subscriptionID = try requiredString(
            "subscriptionId",
            in: params
        )
        guard case let .object(query)? = params["query"],
              case let .string(method)? = query["method"],
              !method.isEmpty,
              method != "subscribe-live-query"
        else {
            throw CodexDesktopWorkerMethodError(
                "Invalid git worker parameter: query"
            )
        }
        let queryRequest = CodexDesktopWorkerRequest(
            workerID: request.workerID,
            id: "\(request.id):live",
            method: method,
            params: query["params"] ?? .object([:]),
            trace: request.trace,
            enqueuedAtMs: request.enqueuedAtMs
        )
        var generation: Int64 = 1
        var previous: CodexJSONValue?

        while !Task.isCancelled {
            do {
                let result = try await handle(
                    queryRequest,
                    emit: { _ in }
                )
                if previous != result {
                    await emit(
                        liveQueryEvent(
                            type: "git-live-query-updated",
                            subscriptionID: subscriptionID,
                            generation: generation,
                            method: method,
                            result: result,
                            trace: request.trace
                        )
                    )
                    previous = result
                    generation += 1
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                await emit(
                    liveQueryEvent(
                        type: "git-live-query-failed",
                        subscriptionID: subscriptionID,
                        generation: generation,
                        method: method,
                        result: nil,
                        trace: request.trace
                    )
                )
            }
            try await Task.sleep(for: .milliseconds(750))
        }
        throw CancellationError()
    }

    private func liveQueryEvent(
        type: String,
        subscriptionID: String,
        generation: Int64,
        method: String,
        result: CodexJSONValue?,
        trace: CodexJSONValue?
    ) -> CodexJSONValue {
        var fields: [String: CodexJSONValue] = [
            "type": .string(type),
            "emittedAtMs": .integer(
                Int64(Date().timeIntervalSince1970 * 1_000)
            ),
            "generation": .integer(generation),
            "method": .string(method),
            "subscriptionId": .string(subscriptionID),
        ]
        if type == "git-live-query-updated", let result {
            fields["requiresRecovery"] = .bool(false)
            fields["phase"] = .string("complete")
            fields["result"] = result
        }
        if let trace {
            fields["trace"] = trace
        }
        return .object(fields)
    }

    private func createWorktree(
        request: CodexDesktopWorkerRequest,
        params: [String: CodexJSONValue],
        emit: @escaping @Sendable (CodexJSONValue) async -> Void
    ) async throws -> CodexJSONValue {
        let cwd = try requiredString("cwd", in: params)
        let streamID =
            try optionalString("streamId", in: params) ?? request.id
        let worktreesRoot =
            try optionalString("worktreesRoot", in: params)
                ?? URL(fileURLWithPath: cwd)
                .appendingPathComponent(".codex/worktrees")
                .path
        let projectName = URL(fileURLWithPath: cwd)
            .lastPathComponent
            .replacingOccurrences(of: "/", with: "-")
        let worktreeRoot = URL(fileURLWithPath: worktreesRoot)
            .appendingPathComponent(projectName)
            .appendingPathComponent(
                UUID().uuidString.lowercased().prefix(8).description
            )
        try FileManager.default.createDirectory(
            at: worktreeRoot.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let startingRef: String
        let copyWorkingTree: Bool
        switch params["startingState"] {
        case let .object(state)?:
            guard case let .string(type)? = state["type"] else {
                throw CodexDesktopWorkerMethodError(
                    "Invalid git worker parameter: startingState"
                )
            }
            switch type {
            case "branch":
                startingRef =
                    try optionalString("branchName", in: state)
                        ?? optionalString("remoteRef", in: state)
                        ?? "HEAD"
                copyWorkingTree = false
            case "working-tree":
                startingRef = "HEAD"
                copyWorkingTree = true
            default:
                throw CodexDesktopWorkerMethodError(
                    "Invalid git worktree starting state: \(type)"
                )
            }
        case nil, .null?:
            startingRef = "HEAD"
            copyWorkingTree = false
        default:
            throw CodexDesktopWorkerMethodError(
                "Invalid git worker parameter: startingState"
            )
        }

        await emit(.object([
            "type": .string("create-worktree-path"),
            "hostId": .string(hostID(in: params)),
            "streamId": .string(streamID),
            "worktreeGitRoot": .string(worktreeRoot.path),
        ]))

        if let embeddedReader {
            var embeddedParams = params
            embeddedParams["worktreeRoot"] = .string(worktreeRoot.path)
            do {
                return try await embeddedReader(
                    "create-worktree",
                    .object(embeddedParams)
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // macOS/package callers retain the released external-Git path.
            }
        }

        let add = try await run(
            [
                "git", "-C", cwd, "worktree", "add", "--detach",
                worktreeRoot.path, startingRef,
            ],
            cwd
        )
        guard add.exitCode == 0 else {
            try? FileManager.default.removeItem(at: worktreeRoot)
            throw gitCommandError(add)
        }

        do {
            if copyWorkingTree {
                try await copyWorkingTreeState(
                    from: cwd,
                    to: worktreeRoot.path
                )
            }
        } catch {
            _ = try? await run(
                [
                    "git", "-C", cwd, "worktree", "remove", "--force",
                    worktreeRoot.path,
                ],
                cwd
            )
            throw error
        }

        return .object([
            "worktreeGitRoot": .string(worktreeRoot.path),
            "worktreeWorkspaceRoot": .string(worktreeRoot.path),
            "setupError": .null,
        ])
    }

    private func copyWorkingTreeState(
        from source: String,
        to destination: String
    ) async throws {
        let diff = try await run(
            ["git", "-C", source, "diff", "--binary", "HEAD"],
            source
        )
        guard diff.exitCode == 0 else {
            throw gitCommandError(diff)
        }
        if !diff.stdout.isEmpty {
            let patchURL = URL(fileURLWithPath: destination)
                .appendingPathComponent(
                    ".codex-worktree-\(UUID().uuidString).patch"
                )
            try Data(diff.stdout.utf8).write(
                to: patchURL,
                options: .atomic
            )
            defer {
                try? FileManager.default.removeItem(at: patchURL)
            }
            let applied = try await run(
                [
                    "git", "-C", destination, "apply", "--binary",
                    patchURL.path,
                ],
                destination
            )
            guard applied.exitCode == 0 else {
                throw gitCommandError(applied)
            }
        }

        let untracked = try await run(
            [
                "git", "-C", source, "ls-files", "--others",
                "--exclude-standard", "-z",
            ],
            source
        )
        guard untracked.exitCode == 0 else {
            throw gitCommandError(untracked)
        }
        let sourceURL = URL(fileURLWithPath: source)
        let destinationURL = URL(fileURLWithPath: destination)
        for relativePath in untracked.stdout.split(
            separator: "\u{0}",
            omittingEmptySubsequences: true
        ).map(String.init) {
            guard isSafeRelativeGitPath(relativePath) else {
                continue
            }
            let input = sourceURL.appendingPathComponent(relativePath)
            let output = destinationURL
                .appendingPathComponent(relativePath)
            guard FileManager.default.fileExists(atPath: input.path) else {
                continue
            }
            try FileManager.default.createDirectory(
                at: output.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if FileManager.default.fileExists(atPath: output.path) {
                try FileManager.default.removeItem(at: output)
            }
            try FileManager.default.copyItem(at: input, to: output)
        }
    }

    private func deleteWorktree(
        _ params: [String: CodexJSONValue]
    ) async throws -> CodexJSONValue {
        let worktree = try requiredString("worktree", in: params)
        let force = try optionalBool("force", in: params) ?? false
        let cwd = URL(fileURLWithPath: worktree)
            .deletingLastPathComponent().path
        var arguments = [
            "git", "-C", worktree, "worktree", "remove",
        ]
        if force {
            arguments.append("--force")
        }
        arguments.append(worktree)
        let result = try await run(arguments, cwd)
        guard result.exitCode == 0 else {
            throw gitCommandError(result)
        }
        return .object([
            "success": .bool(true),
            "worktreeId": .string(sha1(worktree)),
        ])
    }

    private func restoreWorktree(
        _ params: [String: CodexJSONValue]
    ) async throws -> CodexJSONValue {
        let repoRoot = try requiredString("repoRoot", in: params)
        let worktreePath = try requiredString("worktreePath", in: params)
        _ = try optionalString("cwd", in: params)
        let result = try await run(
            [
                "git", "-C", repoRoot, "worktree", "repair",
                worktreePath,
            ],
            repoRoot
        )
        return .object(["success": .bool(result.exitCode == 0)])
    }

    private func setWorktreeOwnerThread(
        _ params: [String: CodexJSONValue]
    ) async throws -> CodexJSONValue {
        let worktree = try requiredString("worktree", in: params)
        let conversationID = try requiredString(
            "conversationId",
            in: params
        )
        let pathResult = try await run(
            [
                "git", "-C", worktree, "rev-parse", "--git-path",
                "codex-thread.json",
            ],
            worktree
        )
        guard pathResult.exitCode == 0 else {
            throw gitCommandError(pathResult)
        }
        var configURL = URL(fileURLWithPath: trimmed(pathResult.stdout))
        if !configURL.path.hasPrefix("/") {
            configURL = URL(fileURLWithPath: worktree)
                .appendingPathComponent(configURL.path)
        }
        let data = try JSONSerialization.data(
            withJSONObject: [
                "version": 1,
                "ownerThreadId": conversationID,
            ],
            options: [.prettyPrinted, .sortedKeys]
        )
        try FileManager.default.createDirectory(
            at: configURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try (data + Data([0x0A])).write(to: configURL, options: .atomic)
        return .object(["success": .bool(true)])
    }

    private func codexWorktrees(
        _ params: [String: CodexJSONValue]
    ) async throws -> CodexJSONValue {
        let configuredRoot = try optionalString(
            "worktreesRoot",
            in: params
        )
        let root = URL(
            fileURLWithPath:
                configuredRoot
                    ?? NSHomeDirectory() + "/.codex/worktrees"
        )
        guard let parents = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return .object(["worktrees": .array([])])
        }
        var entries: [CodexJSONValue] = []
        for parent in parents.sorted(by: { $0.path < $1.path }) {
            guard (try? parent.resourceValues(
                forKeys: [.isDirectoryKey]
            ).isDirectory) == true,
                let children =
                    try? FileManager.default.contentsOfDirectory(
                        at: parent,
                        includingPropertiesForKeys: [.isDirectoryKey],
                        options: [.skipsHiddenFiles]
                    )
            else {
                continue
            }
            for child in children.sorted(by: { $0.path < $1.path }) {
                guard (try? child.resourceValues(
                    forKeys: [.isDirectoryKey]
                ).isDirectory) == true
                else {
                    continue
                }
                let result = try await run(
                    [
                        "git", "-C", child.path, "rev-parse",
                        "--absolute-git-dir",
                    ],
                    child.path
                )
                guard result.exitCode == 0 else {
                    continue
                }
                entries.append(.object([
                    "dir": .string(child.path),
                    "gitDir": .string(trimmed(result.stdout)),
                ]))
            }
        }
        return .object(["worktrees": .array(entries)])
    }

    private func resolveWorktreeForThread(
        _ params: [String: CodexJSONValue]
    ) async throws -> CodexJSONValue {
        let cwd = try requiredString("cwd", in: params)
        let conversationID = try requiredString(
            "conversationId",
            in: params
        )
        let listed = try await run(
            ["git", "-C", cwd, "worktree", "list", "--porcelain"],
            cwd
        )
        guard listed.exitCode == 0 else {
            return emptyResolvedWorktree()
        }
        var matches:
            [(root: String, timestamp: TimeInterval)] = []
        for worktree in parseWorktrees(listed.stdout) {
            guard case let .object(fields) = worktree,
                  case let .string(root)? = fields["root"]
            else {
                continue
            }
            let path = try await run(
                [
                    "git", "-C", root, "rev-parse", "--git-path",
                    "codex-thread.json",
                ],
                root
            )
            guard path.exitCode == 0 else {
                continue
            }
            var configURL = URL(
                fileURLWithPath: trimmed(path.stdout)
            )
            if !configURL.path.hasPrefix("/") {
                configURL = URL(fileURLWithPath: root)
                    .appendingPathComponent(configURL.path)
            }
            guard let data = try? Data(contentsOf: configURL),
                  let object = try? JSONSerialization.jsonObject(
                      with: data
                  ) as? [String: Any],
                  object["version"] as? Int == 1,
                  object["ownerThreadId"] as? String
                    == conversationID
            else {
                continue
            }
            let attributes = try? FileManager.default.attributesOfItem(
                atPath: root
            )
            let timestamp = (
                attributes?[.modificationDate] as? Date
            )?.timeIntervalSince1970 ?? 0
            matches.append((root, timestamp))
        }
        guard let match = matches.max(by: {
            if $0.timestamp == $1.timestamp {
                return $0.root < $1.root
            }
            return $0.timestamp < $1.timestamp
        }) else {
            return emptyResolvedWorktree()
        }
        let status = try await run(
            [
                "git", "-C", match.root, "status", "--porcelain=v1",
                "--untracked-files=all",
            ],
            match.root
        )
        return .object([
            "worktreeGitRoot": .string(match.root),
            "worktreeWorkspaceRoot": .string(match.root),
            "hasUncommittedChanges": .bool(
                status.exitCode == 0 && !trimmed(status.stdout).isEmpty
            ),
        ])
    }

    private func emptyResolvedWorktree() -> CodexJSONValue {
        .object([
            "worktreeGitRoot": .null,
            "worktreeWorkspaceRoot": .null,
            "hasUncommittedChanges": .bool(false),
        ])
    }

    private func moveThreadToLocal(
        request: CodexDesktopWorkerRequest,
        params: [String: CodexJSONValue],
        emit: @escaping @Sendable (CodexJSONValue) async -> Void
    ) async throws -> CodexJSONValue {
        if let embeddedReader {
            do {
                let embedded = try await embeddedReader(
                    "move-thread-to-local",
                    .object(params)
                )
                if case var .object(fields) = embedded {
                    if case let .array(events)? =
                        fields.removeValue(forKey: "_progress")
                    {
                        let progress = handoffProgressEmitter(
                            request: request,
                            params: params,
                            direction: "to-local",
                            emit: emit
                        )
                        for event in events {
                            guard case let .object(eventFields) = event,
                                  case let .string(step)? =
                                    eventFields["step"],
                                  case let .string(status)? =
                                    eventFields["status"]
                            else {
                                continue
                            }
                            await progress(step, status)
                        }
                    }
                    return .object(fields)
                }
                return embedded
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // macOS/package callers retain the released external-Git path.
            }
        }
        let sourceCWD = try requiredString(
            "sourceWorktreeCwd",
            in: params
        )
        let sourceRoot = try requiredString(
            "sourceWorktreeRoot",
            in: params
        )
        let localRoot = try requiredString("localGitRoot", in: params)
        let sourceBranch = try requiredString("sourceBranch", in: params)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let progress = handoffProgressEmitter(
            request: request,
            params: params,
            direction: "to-local",
            emit: emit
        )
        guard !sourceBranch.isEmpty else {
            return handoffError(
                "invalid-params",
                message: "Missing source branch"
            )
        }

        let sourceRepository = try await repositoryRoot(for: sourceCWD)
        let localRepository = try await repositoryRoot(for: localRoot)
        guard sourceRepository != nil, localRepository != nil else {
            return handoffError(
                "unexpected-error",
                message: "Unable to resolve move-to-local repositories"
            )
        }
        let sourceOriginalBranch = try await currentBranch(cwd: sourceCWD)
        let localOriginalBranch = try await currentBranch(cwd: localRoot)
        let listed = try await run(
            [
                "git", "-C", localRoot, "worktree", "list",
                "--porcelain",
            ],
            localRoot
        )
        if listed.exitCode == 0 {
            let sourcePath = (sourceRoot as NSString).standardizingPath
            let localPath = (localRoot as NSString).standardizingPath
            for value in parseWorktrees(listed.stdout) {
                guard case let .object(fields) = value,
                      case let .string(root)? = fields["root"],
                      case let .object(head)? = fields["headRef"],
                      head["type"] == .string("branch"),
                      head["string"] == .string(sourceBranch)
                else {
                    continue
                }
                let path = (root as NSString).standardizingPath
                if path != sourcePath, path != localPath {
                    return handoffError(
                        "branch-checked-out-elsewhere",
                        message:
                            "Branch is already checked out in another worktree"
                    )
                }
            }
        }
        let sourceHead = try await run(
            ["git", "-C", sourceCWD, "rev-parse", "HEAD"],
            sourceCWD
        )
        guard sourceHead.exitCode == 0,
              !trimmed(sourceHead.stdout).isEmpty
        else {
            return handoffError(
                "source-detach-failed",
                message: "Unable to resolve worktree HEAD commit"
            )
        }
        let head = trimmed(sourceHead.stdout)
        var sourceStash: String?
        var sourceDetached = false
        var localCheckedOut = false

        do {
            sourceStash = try await stashChanges(
                cwd: sourceCWD,
                step: "stash-source-changes",
                progress: progress
            )
            let detach = try await checkout(
                cwd: sourceCWD,
                arguments: ["checkout", "--detach", head],
                step: "detach-worktree-branch",
                progress: progress
            )
            guard detach.exitCode == 0 else {
                return handoffError(
                    "source-detach-failed",
                    message: commandErrorText(
                        detach,
                        fallback: "Failed to detach source worktree"
                    ),
                    result: detach
                )
            }
            sourceDetached = true

            let localStatus = try await statusPorcelain(cwd: localRoot)
            guard localStatus.result.exitCode == 0 else {
                let rollback = try await restoreCheckout(
                    cwd: sourceCWD,
                    branch: sourceOriginalBranch,
                    stash: sourceStash
                )
                return handoffError(
                    "local-status-check-failed",
                    message: "Failed to read destination local status",
                    rollbackErrors: rollback
                )
            }
            guard !localStatus.dirty else {
                let rollback = try await restoreCheckout(
                    cwd: sourceCWD,
                    branch: sourceOriginalBranch,
                    stash: sourceStash
                )
                return handoffError(
                    "local-destination-has-tracked-changes",
                    message:
                        "You have uncommitted local changes. Commit or stash them first.",
                    rollbackErrors: rollback
                )
            }

            if localOriginalBranch != sourceBranch {
                let branchHead = try await run(
                    [
                        "git", "-C", localRoot, "rev-parse", "--verify",
                        "--quiet", "refs/heads/\(sourceBranch)",
                    ],
                    localRoot
                )
                if branchHead.exitCode == 0,
                   trimmed(branchHead.stdout) != head
                {
                    let rollback = try await restoreCheckout(
                        cwd: sourceCWD,
                        branch: sourceOriginalBranch,
                        stash: sourceStash
                    )
                    return handoffError(
                        "local-branch-head-mismatch",
                        message:
                            "Destination branch does not match the source worktree HEAD",
                        rollbackErrors: rollback,
                        result: branchHead
                    )
                }
                let checkoutArguments = branchHead.exitCode == 0
                    ? ["checkout", sourceBranch]
                    : ["checkout", "-b", sourceBranch, head]
                let checkedOut = try await checkout(
                    cwd: localRoot,
                    arguments: checkoutArguments,
                    step: "checkout-local-branch",
                    progress: progress
                )
                guard checkedOut.exitCode == 0 else {
                    let rollback = try await restoreCheckout(
                        cwd: sourceCWD,
                        branch: sourceOriginalBranch,
                        stash: sourceStash
                    )
                    return handoffError(
                        "checkout-local-failed",
                        message: commandErrorText(
                            checkedOut,
                            fallback: "Failed to check out local branch"
                        ),
                        rollbackErrors: rollback,
                        result: checkedOut
                    )
                }
                localCheckedOut = true
            } else {
                await progress("checkout-local-branch", "skipped")
            }

            if let sourceStash {
                await progress("apply-changes-to-local", "started")
                let applied = try await run(
                    [
                        "git", "-C", localRoot, "stash", "apply",
                        sourceStash,
                    ],
                    localRoot
                )
                guard applied.exitCode == 0 else {
                    await progress("apply-changes-to-local", "failed")
                    var rollback: [String] = []
                    if localCheckedOut {
                        rollback += try await restoreCheckout(
                            cwd: localRoot,
                            branch: localOriginalBranch,
                            stash: nil
                        )
                    }
                    rollback += try await restoreCheckout(
                        cwd: sourceCWD,
                        branch: sourceOriginalBranch,
                        stash: sourceStash
                    )
                    return handoffError(
                        "apply-source-stash-failed",
                        message: commandErrorText(
                            applied,
                            fallback: "Failed to apply source changes"
                        ),
                        rollbackErrors: rollback,
                        result: applied
                    )
                }
                await progress("apply-changes-to-local", "completed")
                let dropped = try await dropStash(
                    cwd: localRoot,
                    sha: sourceStash
                )
                let warnings = dropped
                    ? []
                    : ["drop-source-stash-failed"]
                return handoffSuccess(warnings: warnings)
            }
            await progress("apply-changes-to-local", "skipped")
            return handoffSuccess()
        } catch {
            var rollback: [String] = []
            if localCheckedOut {
                rollback += try await restoreCheckout(
                    cwd: localRoot,
                    branch: localOriginalBranch,
                    stash: nil
                )
            }
            if sourceDetached {
                rollback += try await restoreCheckout(
                    cwd: sourceCWD,
                    branch: sourceOriginalBranch,
                    stash: sourceStash
                )
            }
            return handoffError(
                "unexpected-error",
                message: "Failed to move thread to local",
                rollbackErrors: rollback
            )
        }
    }

    private func moveThreadToWorktree(
        request: CodexDesktopWorkerRequest,
        params: [String: CodexJSONValue],
        emit: @escaping @Sendable (CodexJSONValue) async -> Void
    ) async throws -> CodexJSONValue {
        if let embeddedReader {
            do {
                let embedded = try await embeddedReader(
                    "move-thread-to-worktree",
                    .object(params)
                )
                if case var .object(fields) = embedded {
                    if case let .array(events)? =
                        fields.removeValue(forKey: "_progress")
                    {
                        let progress = handoffProgressEmitter(
                            request: request,
                            params: params,
                            direction: "to-worktree",
                            emit: emit
                        )
                        for event in events {
                            guard case let .object(eventFields) = event,
                                  case let .string(step)? =
                                    eventFields["step"],
                                  case let .string(status)? =
                                    eventFields["status"]
                            else {
                                continue
                            }
                            await progress(step, status)
                        }
                    }
                    return .object(fields)
                }
                return embedded
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // macOS/package callers retain the released external-Git path.
            }
        }
        let localCWD = try requiredString("localCwd", in: params)
        let sourceBranch = try requiredString("sourceBranch", in: params)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let defaultBranch = try optionalString("defaultBranch", in: params)
        let targetBranch = (
            try optionalString("worktreeCheckoutBranch", in: params)
                ?? sourceBranch
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        let worktreeRoot = try requiredString(
            "worktreeWorkspaceRoot",
            in: params
        )
        let worktreeGitRoot = try requiredString(
            "worktreeGitRoot",
            in: params
        )
        let stashTarget =
            try optionalBool("stashTargetWorktree", in: params) ?? false
        let createdWorktree =
            try optionalBool("createdWorktree", in: params) ?? false
        let progress = handoffProgressEmitter(
            request: request,
            params: params,
            direction: "to-worktree",
            emit: emit
        )
        guard !sourceBranch.isEmpty else {
            return handoffError(
                "invalid-params",
                message: "Missing source branch"
            )
        }
        guard !targetBranch.isEmpty else {
            return handoffError(
                "invalid-params",
                message: "Missing worktree checkout branch"
            )
        }
        guard defaultBranch != targetBranch else {
            return handoffError(
                "default-branch-blocked",
                message:
                    "Move to worktree is not available on the default branch"
            )
        }
        guard try await repositoryRoot(for: localCWD) != nil else {
            return handoffError(
                "unexpected-error",
                message: "Unable to resolve move-to-worktree local repository"
            )
        }
        guard let localOriginalBranch = try await currentBranch(cwd: localCWD)
        else {
            return handoffError(
                "local-not-on-branch",
                message:
                    "Local repository must be on a branch to move to a worktree"
            )
        }

        var sourceStash: String?
        var targetStash: String?
        var localMoved = false
        var targetCheckedOut = false
        let targetOriginalBranch = try await currentBranch(cwd: worktreeRoot)
        do {
            if localOriginalBranch == sourceBranch {
                let localCheckout = try optionalString(
                    "localCheckoutBranch",
                    in: params
                )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !localCheckout.isEmpty else {
                    return handoffError(
                        "invalid-params",
                        message: "Missing local checkout branch"
                    )
                }
                sourceStash = try await stashChanges(
                    cwd: localCWD,
                    step: "stash-source-changes",
                    progress: progress
                )
                let checkedOut = try await checkout(
                    cwd: localCWD,
                    arguments: ["checkout", localCheckout],
                    step: "checkout-local-branch",
                    progress: progress
                )
                guard checkedOut.exitCode == 0 else {
                    return handoffError(
                        "checkout-local-failed",
                        message: commandErrorText(
                            checkedOut,
                            fallback: "Failed to check out local branch"
                        ),
                        result: checkedOut
                    )
                }
                localMoved = true
            } else {
                await progress("stash-source-changes", "skipped")
                await progress("checkout-local-branch", "skipped")
            }

            if stashTarget {
                targetStash = try await stashChanges(
                    cwd: worktreeRoot,
                    step: "stash-target-worktree-changes",
                    progress: progress
                )
            } else {
                await progress("stash-target-worktree-changes", "skipped")
            }
            let checkedOut = try await checkout(
                cwd: worktreeRoot,
                arguments: ["checkout", targetBranch],
                step: "checkout-worktree-branch",
                progress: progress
            )
            guard checkedOut.exitCode == 0 else {
                var rollback: [String] = []
                if localMoved {
                    rollback += try await restoreCheckout(
                        cwd: localCWD,
                        branch: localOriginalBranch,
                        stash: sourceStash
                    )
                }
                if createdWorktree {
                    let removed = try await run(
                        [
                            "git", "-C", worktreeGitRoot, "worktree",
                            "remove", "--force", worktreeGitRoot,
                        ],
                        worktreeGitRoot
                    )
                    if removed.exitCode != 0 {
                        rollback.append("cleanup-created-worktree-failed")
                    }
                }
                return handoffError(
                    "checkout-worktree-failed",
                    message: commandErrorText(
                        checkedOut,
                        fallback: "Failed to check out worktree branch"
                    ),
                    rollbackErrors: rollback,
                    result: checkedOut
                )
            }
            targetCheckedOut = true

            if let targetStash {
                let restored = try await run(
                    [
                        "git", "-C", worktreeRoot, "stash", "apply",
                        targetStash,
                    ],
                    worktreeRoot
                )
                guard restored.exitCode == 0 else {
                    return handoffError(
                        "checkout-worktree-failed",
                        message: commandErrorText(
                            restored,
                            fallback:
                                "Failed to restore target worktree changes"
                        ),
                        result: restored
                    )
                }
            }
            if let sourceStash {
                await progress("apply-changes-to-worktree", "started")
                let applied = try await run(
                    [
                        "git", "-C", worktreeRoot, "stash", "apply",
                        sourceStash,
                    ],
                    worktreeRoot
                )
                guard applied.exitCode == 0 else {
                    await progress("apply-changes-to-worktree", "failed")
                    var rollback: [String] = []
                    if localMoved {
                        rollback += try await restoreCheckout(
                            cwd: localCWD,
                            branch: localOriginalBranch,
                            stash: sourceStash
                        )
                    }
                    return handoffError(
                        "apply-source-stash-failed",
                        message: commandErrorText(
                            applied,
                            fallback: "Failed to apply source changes"
                        ),
                        rollbackErrors: rollback,
                        result: applied
                    )
                }
                await progress("apply-changes-to-worktree", "completed")
            } else {
                await progress("apply-changes-to-worktree", "skipped")
            }
            var warnings: [String] = []
            if targetStash != nil {
                warnings.append("stashed-target-worktree-changes")
            }
            if let targetStash,
               !(try await dropStash(
                   cwd: worktreeRoot,
                   sha: targetStash
               ))
            {
                warnings.append("drop-target-stash-failed")
            }
            if let sourceStash,
               !(try await dropStash(
                   cwd: worktreeRoot,
                   sha: sourceStash
               ))
            {
                warnings.append("drop-source-stash-failed")
            }
            return handoffSuccess(warnings: warnings)
        } catch {
            var rollback: [String] = []
            if targetCheckedOut, let targetOriginalBranch {
                rollback += try await restoreCheckout(
                    cwd: worktreeRoot,
                    branch: targetOriginalBranch,
                    stash: targetStash
                )
            }
            if localMoved {
                rollback += try await restoreCheckout(
                    cwd: localCWD,
                    branch: localOriginalBranch,
                    stash: sourceStash
                )
            }
            return handoffError(
                "unexpected-error",
                message: "Failed to move thread to worktree",
                rollbackErrors: rollback
            )
        }
    }

    private func moveThreadToHostWorktree(
        request: CodexDesktopWorkerRequest,
        params: [String: CodexJSONValue],
        emit: @escaping @Sendable (CodexJSONValue) async -> Void
    ) async throws -> CodexJSONValue {
        if let embeddedReader {
            do {
                let embedded = try await embeddedReader(
                    "move-thread-to-host-worktree",
                    .object(params)
                )
                if case var .object(fields) = embedded {
                    if case let .array(events)? =
                        fields.removeValue(forKey: "_progress")
                    {
                        let progress = handoffProgressEmitter(
                            request: request,
                            params: params,
                            direction: "to-host-worktree",
                            emit: emit
                        )
                        for event in events {
                            guard case let .object(eventFields) = event,
                                  case let .string(step)? =
                                    eventFields["step"],
                                  case let .string(status)? =
                                    eventFields["status"]
                            else {
                                continue
                            }
                            await progress(step, status)
                        }
                    }
                    return .object(fields)
                }
                return embedded
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // macOS/package callers retain the released external-Git path.
            }
        }
        let sourceCWD = try requiredString("sourceCwd", in: params)
        let sourceBranch = try requiredString("sourceBranch", in: params)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let sourceRollout = try requiredString(
            "sourceRolloutPath",
            in: params
        )
        let destinationWorkspace = try requiredString(
            "destinationWorkspaceRoot",
            in: params
        )
        let destinationGitRoot = try optionalString(
            "destinationWorktreeGitRoot",
            in: params
        )
        let destinationWorktreeRoot = try optionalString(
            "destinationWorktreeWorkspaceRoot",
            in: params
        )
        let progress = handoffProgressEmitter(
            request: request,
            params: params,
            direction: "to-host-worktree",
            emit: emit
        )
        guard !sourceRollout.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty else {
            return hostHandoffError(
                "invalid-params",
                message: "Missing source rollout path"
            )
        }
        guard !sourceBranch.isEmpty else {
            return hostHandoffError(
                "invalid-params",
                message: "Missing source branch"
            )
        }
        guard (destinationGitRoot == nil)
            == (destinationWorktreeRoot == nil)
        else {
            return hostHandoffError(
                "invalid-params",
                message:
                    "Destination worktree roots must be provided together"
            )
        }
        guard FileManager.default.fileExists(atPath: sourceRollout) else {
            return hostHandoffError(
                "invalid-params",
                message: "Missing source rollout path"
            )
        }
        guard let sourceRoot = try await repositoryRoot(for: sourceCWD)
        else {
            return hostHandoffError(
                "source-not-in-repository",
                message: "Source thread is not in a git repository"
            )
        }
        guard let destinationRoot = try await repositoryRoot(
            for: destinationWorkspace
        ) else {
            return hostHandoffError(
                "destination-not-in-repository",
                message:
                    "Destination workspace is not in a git repository"
            )
        }

        let operationID = UUID().uuidString.lowercased()
        let codexHome = (
            try optionalString("codexHome", in: params)
                ?? NSHomeDirectory() + "/.codex"
        )
        let handoffRoot = URL(fileURLWithPath: codexHome)
            .appendingPathComponent("handoffs")
            .appendingPathComponent(operationID)
        let bundleURL = handoffRoot.appendingPathComponent("handoff.bundle")
        let rolloutURL = handoffRoot.appendingPathComponent("rollout.jsonl")
        let sourceRef = "refs/codex/handoff/source/\(operationID)"
        let destinationRef =
            "refs/codex/handoff/destination/\(operationID)"
        var completed = false
        var activeStep: String?
        var createdWorktree = false
        var resolvedWorktreeRoot = destinationWorktreeRoot
        defer {
            if !completed {
                try? FileManager.default.removeItem(at: handoffRoot)
            } else {
                try? FileManager.default.removeItem(at: bundleURL)
            }
        }

        do {
            activeStep = "prepare-host-transfer"
            await progress(activeStep!, "started")
            let headResult = try await run(
                ["git", "-C", sourceRoot, "rev-parse", "HEAD"],
                sourceRoot
            )
            guard headResult.exitCode == 0,
                  !trimmed(headResult.stdout).isEmpty
            else {
                await progress(activeStep!, "failed")
                return hostHandoffError(
                    "snapshot-failed",
                    message: "Unable to resolve source HEAD commit",
                    result: headResult
                )
            }
            let head = trimmed(headResult.stdout)
            let existingDestinationBranch = try await run(
                [
                    "git", "-C", destinationRoot, "rev-parse", "--verify",
                    "--quiet", "refs/heads/\(sourceBranch)",
                ],
                destinationRoot
            )
            if existingDestinationBranch.exitCode == 0,
               trimmed(existingDestinationBranch.stdout) != head,
               destinationWorktreeRoot == nil
            {
                await progress(activeStep!, "failed")
                return hostHandoffError(
                    "destination-branch-exists",
                    message:
                        "Destination branch exists at a different commit",
                    result: existingDestinationBranch
                )
            }
            let snapshot = try await run(
                [
                    "git", "-C", sourceRoot, "stash", "create",
                    "Codex host handoff snapshot",
                ],
                sourceRoot
            )
            let snapshotCommit = snapshot.exitCode == 0
                && !trimmed(snapshot.stdout).isEmpty
                ? trimmed(snapshot.stdout)
                : head
            let retainSource = try await run(
                [
                    "git", "-C", sourceRoot, "update-ref", sourceRef,
                    snapshotCommit,
                ],
                sourceRoot
            )
            guard retainSource.exitCode == 0 else {
                await progress(activeStep!, "failed")
                return hostHandoffError(
                    "snapshot-failed",
                    message: "Failed to prepare host handoff snapshot ref",
                    result: retainSource
                )
            }
            try FileManager.default.createDirectory(
                at: handoffRoot,
                withIntermediateDirectories: true
            )
            let destinationHasCommit = try await run(
                [
                    "git", "-C", destinationRoot, "cat-file", "-e",
                    "\(snapshotCommit)^{commit}",
                ],
                destinationRoot
            )
            if destinationHasCommit.exitCode != 0 {
                let bundled = try await run(
                    [
                        "git", "-C", sourceRoot, "bundle", "create",
                        bundleURL.path, sourceRef,
                    ],
                    sourceRoot
                )
                guard bundled.exitCode == 0 else {
                    await progress(activeStep!, "failed")
                    return hostHandoffError(
                        "bundle-export-failed",
                        message: "Failed to export git handoff bundle",
                        result: bundled
                    )
                }
                await progress(activeStep!, "completed")
                activeStep = "transfer-host-artifacts"
                await progress(activeStep!, "started")
                let imported = try await run(
                    [
                        "git", "-C", destinationRoot, "bundle",
                        "unbundle", bundleURL.path,
                    ],
                    destinationRoot
                )
                guard imported.exitCode == 0 else {
                    await progress(activeStep!, "failed")
                    return hostHandoffError(
                        "bundle-import-failed",
                        message: "Failed to import git handoff bundle",
                        result: imported
                    )
                }
            } else {
                await progress(activeStep!, "completed")
                activeStep = "transfer-host-artifacts"
                await progress(activeStep!, "started")
            }
            let retainDestination = try await run(
                [
                    "git", "-C", destinationRoot, "update-ref",
                    destinationRef, snapshotCommit,
                ],
                destinationRoot
            )
            guard retainDestination.exitCode == 0 else {
                await progress(activeStep!, "failed")
                return hostHandoffError(
                    "bundle-import-failed",
                    message: "Failed to prepare destination handoff ref",
                    result: retainDestination
                )
            }
            try FileManager.default.copyItem(
                at: URL(fileURLWithPath: sourceRollout),
                to: rolloutURL
            )
            await progress(activeStep!, "completed")
            activeStep = nil

            if resolvedWorktreeRoot == nil {
                activeStep = "create-new-worktree"
                await progress(activeStep!, "started")
                let newRoot = URL(fileURLWithPath: codexHome)
                    .appendingPathComponent("worktrees")
                    .appendingPathComponent(
                        URL(fileURLWithPath: destinationRoot)
                            .lastPathComponent
                    )
                    .appendingPathComponent(operationID)
                try FileManager.default.createDirectory(
                    at: newRoot.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                let added = try await run(
                    [
                        "git", "-C", destinationRoot, "worktree", "add",
                        "--detach", newRoot.path, destinationRef,
                    ],
                    destinationRoot
                )
                guard added.exitCode == 0 else {
                    await progress(activeStep!, "failed")
                    return hostHandoffError(
                        "create-worktree-failed",
                        message: "Failed to create destination worktree",
                        result: added
                    )
                }
                resolvedWorktreeRoot = newRoot.path
                createdWorktree = true
                await progress(activeStep!, "completed")
                activeStep = nil
            }
            guard let worktreeRoot = resolvedWorktreeRoot else {
                return hostHandoffError(
                    "create-worktree-failed",
                    message: "Failed to resolve destination worktree"
                )
            }

            activeStep = "apply-changes-to-worktree"
            await progress(activeStep!, "started")
            if let destinationBranch = try await currentBranch(
                cwd: destinationRoot
            ), destinationBranch == sourceBranch {
                let detached = try await run(
                    [
                        "git", "-C", destinationRoot, "checkout",
                        "--detach",
                    ],
                    destinationRoot
                )
                guard detached.exitCode == 0 else {
                    await progress(activeStep!, "failed")
                    return hostHandoffError(
                        "restore-worktree-state-failed",
                        message:
                            "Failed to release destination branch checkout",
                        result: detached
                    )
                }
            }
            var reusedStash: String?
            if !createdWorktree,
               try optionalBool(
                   "stashDestinationWorktree",
                   in: params
               ) == true
            {
                reusedStash = try await stashChanges(
                    cwd: worktreeRoot,
                    step: "stash-target-worktree-changes",
                    progress: progress
                )
            }
            let checkoutBranch = try await run(
                [
                    "git", "-C", worktreeRoot, "checkout", "-B",
                    sourceBranch, head,
                ],
                worktreeRoot
            )
            guard checkoutBranch.exitCode == 0 else {
                await progress(activeStep!, "failed")
                return hostHandoffError(
                    "restore-worktree-state-failed",
                    message: "Failed to check out transferred branch",
                    result: checkoutBranch
                )
            }
            let reset = try await run(
                ["git", "-C", worktreeRoot, "reset", "--mixed", head],
                worktreeRoot
            )
            guard reset.exitCode == 0 else {
                await progress(activeStep!, "failed")
                return hostHandoffError(
                    "restore-worktree-state-failed",
                    message:
                        "Failed to restore transferred git state in the worktree",
                    result: reset
                )
            }
            if snapshotCommit != head {
                let restore = try await run(
                    [
                        "git", "-C", worktreeRoot, "restore", "--source",
                        snapshotCommit, "--worktree", "--", ".",
                    ],
                    worktreeRoot
                )
                guard restore.exitCode == 0 else {
                    await progress(activeStep!, "failed")
                    return hostHandoffError(
                        "restore-worktree-state-failed",
                        message:
                            "Failed to restore transferred git state in the worktree",
                        result: restore
                    )
                }
            }
            try await copyUntrackedFiles(
                from: sourceRoot,
                to: worktreeRoot
            )
            if let reusedStash {
                _ = try await run(
                    [
                        "git", "-C", worktreeRoot, "stash", "apply",
                        reusedStash,
                    ],
                    worktreeRoot
                )
                _ = try await dropStash(
                    cwd: worktreeRoot,
                    sha: reusedStash
                )
            }
            await progress(activeStep!, "completed")
            activeStep = nil
            completed = true
            _ = try await run(
                [
                    "git", "-C", sourceRoot, "update-ref", "-d",
                    sourceRef,
                ],
                sourceRoot
            )
            _ = try await run(
                [
                    "git", "-C", destinationRoot, "update-ref", "-d",
                    destinationRef,
                ],
                destinationRoot
            )
            _ = try await run(
                [
                    "git", "-C", destinationRoot, "update-ref", "-d",
                    sourceRef,
                ],
                destinationRoot
            )
            return .object([
                "status": .string("success"),
                "rolloutPath": .string(rolloutURL.path),
                "worktreeGitRoot": .string(worktreeRoot),
                "worktreeWorkspaceRoot": .string(worktreeRoot),
            ])
        } catch {
            if let activeStep {
                await progress(activeStep, "failed")
            }
            return hostHandoffError(
                "unexpected-error",
                message: error.localizedDescription
            )
        }
    }

    private func cleanupHostHandoffTransfer(
        _ params: [String: CodexJSONValue]
    ) throws -> CodexJSONValue {
        let rolloutPath = try requiredString("rolloutPath", in: params)
        let codexHome = (
            try optionalString("codexHome", in: params)
                ?? NSHomeDirectory() + "/.codex"
        )
        let rolloutURL = URL(fileURLWithPath: rolloutPath)
            .standardizedFileURL
        let handoffsURL = URL(fileURLWithPath: codexHome)
            .appendingPathComponent("handoffs")
            .standardizedFileURL
        let parent = rolloutURL.deletingLastPathComponent()
        let relative = String(
            parent.path.dropFirst(handoffsURL.path.count)
        ).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard rolloutURL.lastPathComponent == "rollout.jsonl",
              parent.deletingLastPathComponent() == handoffsURL,
              !relative.isEmpty,
              !relative.contains("/")
        else {
            throw CodexDesktopWorkerMethodError(
                "Host handoff cleanup requires a copied rollout path"
            )
        }
        if FileManager.default.fileExists(atPath: parent.path) {
            try FileManager.default.removeItem(at: parent)
        }
        return .object(["success": .bool(true)])
    }

    private func repositoryRoot(for cwd: String) async throws -> String? {
        let result = try await run(
            ["git", "-C", cwd, "rev-parse", "--show-toplevel"],
            cwd
        )
        guard result.exitCode == 0 else {
            return nil
        }
        let root = trimmed(result.stdout)
        return root.isEmpty ? nil : root
    }

    private func currentBranch(cwd: String) async throws -> String? {
        let result = try await run(
            [
                "git", "-C", cwd, "symbolic-ref", "--short", "-q",
                "HEAD",
            ],
            cwd
        )
        guard result.exitCode == 0 else {
            return nil
        }
        let branch = trimmed(result.stdout)
        return branch.isEmpty ? nil : branch
    }

    private func statusPorcelain(
        cwd: String
    ) async throws -> (
        result: CodexDesktopCommandExecResult,
        dirty: Bool
    ) {
        let result = try await run(
            [
                "git", "-C", cwd, "status", "--porcelain=v1",
                "--untracked-files=all",
            ],
            cwd
        )
        return (
            result,
            result.exitCode == 0 && !trimmed(result.stdout).isEmpty
        )
    }

    private func stashChanges(
        cwd: String,
        step: String,
        progress: @escaping @Sendable (String, String) async -> Void
    ) async throws -> String? {
        let status = try await statusPorcelain(cwd: cwd)
        guard status.result.exitCode == 0 else {
            throw gitCommandError(status.result)
        }
        guard status.dirty else {
            await progress(step, "skipped")
            return nil
        }
        await progress(step, "started")
        let stash = try await run(
            [
                "git", "-C", cwd, "stash", "push", "--include-untracked",
                "-m", "Codex thread handoff",
            ],
            cwd
        )
        guard stash.exitCode == 0 else {
            await progress(step, "failed")
            throw gitCommandError(stash)
        }
        let resolved = try await run(
            ["git", "-C", cwd, "rev-parse", "refs/stash"],
            cwd
        )
        guard resolved.exitCode == 0,
              !trimmed(resolved.stdout).isEmpty
        else {
            await progress(step, "failed")
            throw gitCommandError(resolved)
        }
        await progress(step, "completed")
        return trimmed(resolved.stdout)
    }

    private func checkout(
        cwd: String,
        arguments: [String],
        step: String,
        progress: @escaping @Sendable (String, String) async -> Void
    ) async throws -> CodexDesktopCommandExecResult {
        await progress(step, "started")
        let result = try await run(["git", "-C", cwd] + arguments, cwd)
        await progress(step, result.exitCode == 0 ? "completed" : "failed")
        return result
    }

    private func restoreCheckout(
        cwd: String,
        branch: String?,
        stash: String?
    ) async throws -> [String] {
        var errors: [String] = []
        if let branch {
            let checkout = try await run(
                ["git", "-C", cwd, "checkout", branch],
                cwd
            )
            if checkout.exitCode != 0 {
                errors.append("restore-source-branch-failed")
            }
        }
        if let stash {
            let restored = try await run(
                ["git", "-C", cwd, "stash", "apply", stash],
                cwd
            )
            if restored.exitCode != 0 {
                errors.append("restore-source-stash-failed")
            } else {
                _ = try await dropStash(cwd: cwd, sha: stash)
            }
        }
        return errors
    }

    private func dropStash(cwd: String, sha: String) async throws -> Bool {
        let list = try await run(
            [
                "git", "-C", cwd, "stash", "list", "--format=%H %gd",
            ],
            cwd
        )
        guard list.exitCode == 0 else {
            return false
        }
        let selector = lines(list.stdout).compactMap { line -> String? in
            let parts = line.split(
                maxSplits: 1,
                whereSeparator: \.isWhitespace
            ).map(String.init)
            guard parts.count == 2, parts[0] == sha else {
                return nil
            }
            return parts[1]
        }.first
        guard let selector else {
            return false
        }
        let result = try await run(
            ["git", "-C", cwd, "stash", "drop", selector],
            cwd
        )
        return result.exitCode == 0
    }

    private func copyUntrackedFiles(
        from source: String,
        to destination: String
    ) async throws {
        let result = try await run(
            [
                "git", "-C", source, "ls-files", "--others",
                "--exclude-standard", "-z",
            ],
            source
        )
        guard result.exitCode == 0 else {
            return
        }
        let paths = result.stdout
            .split(separator: "\u{0}", omittingEmptySubsequences: true)
            .map(String.init)
            .filter(isSafeRelativeGitPath)
        let sourceURL = URL(fileURLWithPath: source)
        let destinationURL = URL(fileURLWithPath: destination)
        for path in paths {
            let input = sourceURL.appendingPathComponent(path)
            let output = destinationURL.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: output.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if FileManager.default.fileExists(atPath: output.path) {
                try FileManager.default.removeItem(at: output)
            }
            try FileManager.default.copyItem(at: input, to: output)
        }
    }

    private func handoffProgressEmitter(
        request: CodexDesktopWorkerRequest,
        params: [String: CodexJSONValue],
        direction: String,
        emit: @escaping @Sendable (CodexJSONValue) async -> Void
    ) -> @Sendable (String, String) async -> Void {
        let operationID: String
        if case let .string(value)? = params["operationId"],
           !value.isEmpty
        {
            operationID = value
        } else {
            operationID = request.id
        }
        return { step, status in
            await emit(.object([
                "type": .string("thread-handoff-progress"),
                "operationId": .string(operationID),
                "direction": .string(direction),
                "step": .string(step),
                "status": .string(status),
            ]))
        }
    }

    private func handoffSuccess(
        warnings: [String] = []
    ) -> CodexJSONValue {
        .object([
            "status": .string("success"),
            "warnings": .array(warnings.map(CodexJSONValue.string)),
        ])
    }

    private func handoffError(
        _ code: String,
        message: String,
        rollbackErrors: [String] = [],
        warnings: [String] = [],
        result: CodexDesktopCommandExecResult? = nil
    ) -> CodexJSONValue {
        var fields: [String: CodexJSONValue] = [
            "status": .string("error"),
            "error": .string(code),
            "message": .string(message),
            "rollbackErrors": .array(
                rollbackErrors.map(CodexJSONValue.string)
            ),
            "warnings": .array(warnings.map(CodexJSONValue.string)),
        ]
        if let result {
            fields["execOutput"] = execOutput(
                result,
                command: "git",
                fallback: message
            )
        }
        return .object(fields)
    }

    private func hostHandoffError(
        _ code: String,
        message: String,
        result: CodexDesktopCommandExecResult? = nil
    ) -> CodexJSONValue {
        var fields: [String: CodexJSONValue] = [
            "status": .string("error"),
            "error": .string(code),
            "message": .string(message),
        ]
        if let result {
            fields["execOutput"] = execOutput(
                result,
                command: "git",
                fallback: message
            )
        }
        return .object(fields)
    }

    private func worktreeSnapshotRef(
        _ params: [String: CodexJSONValue]
    ) async throws -> CodexJSONValue {
        guard case let .array(candidateValues)? = params["candidateRoots"]
        else {
            throw CodexDesktopWorkerMethodError(
                "Invalid git worker parameter: candidateRoots"
            )
        }
        let worktreePath = try requiredString("worktreePath", in: params)
        let candidateRoots: [String] = candidateValues.compactMap {
            guard case let .string(path) = $0, isDirectory(path) else {
                return nil
            }
            return path
        }
        guard !candidateRoots.isEmpty else {
            throw CodexDesktopWorkerMethodError(
                "No candidate workspace roots exist on disk"
            )
        }
        return try await worktreeSnapshotRef(
            candidateRoots: candidateRoots,
            worktreePath: worktreePath
        )
    }

    private func worktreeSnapshotRef(
        candidateRoots: [String],
        worktreePath: String
    ) async throws -> CodexJSONValue {
        let standardizedWorktreePath =
            (worktreePath as NSString).standardizingPath
        let worktreeID = sha1(standardizedWorktreePath)
        let snapshotRef = "refs/codex/snapshots/\(worktreeID)"
        var validRepositoryFound = false
        for candidate in candidateRoots {
            let rootResult = try await run(
                ["git", "-C", candidate, "rev-parse", "--show-toplevel"],
                candidate
            )
            guard rootResult.exitCode == 0 else {
                continue
            }
            validRepositoryFound = true
            let root = trimmed(rootResult.stdout)
            let commonResult = try await run(
                ["git", "-C", root, "rev-parse", "--git-common-dir"],
                root
            )
            let commitResult = try await run(
                ["git", "-C", root, "rev-parse", "--verify", snapshotRef],
                root
            )
            guard commitResult.exitCode == 0 else {
                continue
            }
            let rawCommon = commonResult.exitCode == 0
                ? trimmed(commonResult.stdout)
                : ""
            let commonDir = (rawCommon as NSString).isAbsolutePath
                ? (rawCommon as NSString).standardizingPath
                : ((root as NSString).appendingPathComponent(rawCommon)
                    as NSString).standardizingPath
            return .object([
                "snapshotRef": .string(snapshotRef),
                "worktreeId": .string(worktreeID),
                "repoRoot": .string(root),
                "commonDir": .string(commonDir),
                "exists": .bool(true),
                "commitSha": .string(trimmed(commitResult.stdout)),
            ])
        }
        guard validRepositoryFound else {
            throw CodexDesktopWorkerMethodError(
                "No candidate workspace roots are valid git repositories"
            )
        }
        return .object([
            "snapshotRef": .string(snapshotRef),
            "worktreeId": .string(worktreeID),
            "exists": .bool(false),
            "commitSha": .null,
        ])
    }

    private func managedWorktreeState(
        _ params: [String: CodexJSONValue]
    ) async throws -> CodexJSONValue {
        let cwd = try requiredString("cwd", in: params)
        let worktreePath = try requiredString("worktreePath", in: params)
        if isDirectory(cwd) {
            return .object(["kind": .string("available")])
        }
        if cwd != worktreePath, isDirectory(worktreePath) {
            return .object(["kind": .string("gone")])
        }
        guard case let .array(candidateValues)? = params["candidateRoots"]
        else {
            throw CodexDesktopWorkerMethodError(
                "Invalid git worker parameter: candidateRoots"
            )
        }
        let candidateRoots: [String] = candidateValues.compactMap {
            guard case let .string(path) = $0, isDirectory(path) else {
                return nil
            }
            return path
        }
        guard !candidateRoots.isEmpty else {
            return .object([
                "kind": .string("unavailable"),
                "reason": .string("no-candidate-roots"),
            ])
        }
        do {
            let snapshot = try await worktreeSnapshotRef(
                candidateRoots: candidateRoots,
                worktreePath: worktreePath
            )
            guard case let .object(fields) = snapshot,
                  fields["exists"] == CodexJSONValue.bool(true)
            else {
                return .object(["kind": .string("gone")])
            }
            return .object([
                "kind": .string("restorable"),
                "snapshot": snapshot,
            ])
        } catch {
            return .object([
                "kind": .string("unavailable"),
                "reason": .string("inspection-failed"),
            ])
        }
    }

    private func turnDiffCaptureStart(
        _ params: [String: CodexJSONValue]
    ) async throws -> CodexJSONValue {
        let cwd = try requiredString("cwd", in: params)
        let checkpointKey = try requiredString("checkpointKey", in: params)
        let turnID = try requiredString("turnId", in: params)
        let rootResult = try await run(
            ["git", "-C", cwd, "rev-parse", "--show-toplevel"],
            cwd
        )
        guard rootResult.exitCode == 0 else {
            return .null
        }
        let root = trimmed(rootResult.stdout)
        let baseTurnID = try optionalString("baseTurnId", in: params)
        let baseTree = try await workingTreeTree(root: root)
        let timestamp = Int64(Date().timeIntervalSince1970 * 1_000)
        let refPrefix =
            "refs/codex/turn-diffs/captures/\(timestamp)/\(UUID().uuidString)"
        let checkpointScope =
            "refs/codex/turn-diffs/checkpoints/\(sha256(checkpointKey))"
        let checkpointRef = "\(checkpointScope)/\(sha256(turnID))"
        let baseTurnHeadTree: String?
        if let baseTurnID {
            baseTurnHeadTree = try await latestTurnCheckpoint(
                root: root,
                refPrefix: "\(checkpointScope)/\(sha256(baseTurnID))",
                nowMs: timestamp
            )
        } else {
            baseTurnHeadTree = nil
        }
        let retain = try await run(
            [
                "git", "-C", root, "update-ref", "\(refPrefix)/base",
                baseTree,
            ],
            root
        )
        guard retain.exitCode == 0 else {
            throw CodexDesktopWorkerMethodError(
                "Failed to retain a turn diff tree snapshot"
            )
        }
        let sessionStartCommit: CodexJSONValue
        let sessionStartDiff: CodexJSONValue
        if baseTurnID == nil {
            let headResult = try await run(
                ["git", "-C", root, "rev-parse", "--verify", "HEAD"],
                root
            )
            if headResult.exitCode == 0 {
                let head = trimmed(headResult.stdout)
                sessionStartCommit = .string(head)
                let sessionDiff = try await treeDiff(
                    root: root,
                    base: head,
                    head: baseTree
                )
                sessionStartDiff = sessionDiff
            } else {
                sessionStartCommit = .null
                sessionStartDiff = .null
            }
        } else {
            sessionStartCommit = .null
            sessionStartDiff = .null
        }
        return .object([
            "baseTreeSha": .string(baseTree),
            "baseTurnHeadTreeSha": baseTurnHeadTree
                .map(CodexJSONValue.string) ?? .null,
            "sessionStartCommitSha": sessionStartCommit,
            "sessionStartDiff": sessionStartDiff,
            "checkpointRefPrefix": .string(checkpointRef),
            "checkpointScopeRefPrefix": .string(checkpointScope),
            "refPrefix": .string(refPrefix),
            "root": .string(root),
        ])
    }

    private func turnDiffCaptureComplete(
        _ params: [String: CodexJSONValue]
    ) async throws -> CodexJSONValue {
        guard case let .object(capture)? = params["capture"] else {
            throw CodexDesktopWorkerMethodError(
                "Invalid git worker parameter: capture"
            )
        }
        let root = try requiredString("root", in: capture)
        let baseTree = try requiredString("baseTreeSha", in: capture)
        let refPrefix = try requiredString("refPrefix", in: capture)
        let checkpointRef = try requiredString(
            "checkpointRefPrefix",
            in: capture
        )
        let headTreeSHA = try await workingTreeTree(root: root)
        let retainHead = try await run(
            [
                "git", "-C", root, "update-ref", "\(refPrefix)/head",
                headTreeSHA,
            ],
            root
        )
        guard retainHead.exitCode == 0 else {
            throw CodexDesktopWorkerMethodError(
                "Failed to retain a turn diff tree snapshot"
            )
        }
        let diff = try await treeDiff(
            root: root,
            base: baseTree,
            head: headTreeSHA
        )
        let betweenTurnDiff: CodexJSONValue
        if case let .string(baseTurnTree)? =
            capture["baseTurnHeadTreeSha"]
        {
            betweenTurnDiff = try await treeDiff(
                root: root,
                base: baseTurnTree,
                head: baseTree
            )
        } else {
            betweenTurnDiff = .null
        }
        if try optionalBool("retainCheckpoint", in: params) == true,
           case .object(let diffFields) = diff,
           diffFields["type"] == .string("success")
        {
            _ = try await run(
                [
                    "git", "-C", root, "update-ref",
                    "\(checkpointRef)/\(Int64(Date().timeIntervalSince1970 * 1_000))/\(UUID().uuidString)",
                    headTreeSHA,
                ],
                root
            )
        }
        _ = try await run(
            ["git", "-C", root, "update-ref", "-d", "\(refPrefix)/head"],
            root
        )
        _ = try await run(
            ["git", "-C", root, "update-ref", "-d", "\(refPrefix)/base"],
            root
        )
        return .object([
            "baseTreeSha": .string(baseTree),
            "baseTurnHeadTreeSha": capture["baseTurnHeadTreeSha"] ?? .null,
            "betweenTurnDiff": betweenTurnDiff,
            "sessionStartCommitSha":
                capture["sessionStartCommitSha"] ?? .null,
            "sessionStartDiff": capture["sessionStartDiff"] ?? .null,
            "headTreeSha": .string(headTreeSHA),
            "diff": diff,
        ])
    }

    private func workingTreeTree(root: String) async throws -> String {
        let temporaryIndex = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "codex-turn-index-\(UUID().uuidString)"
            )
        defer {
            try? FileManager.default.removeItem(at: temporaryIndex)
        }
        let environment: [String: String?] = [
            "GIT_INDEX_FILE": temporaryIndex.path
        ]
        var readTree = try await runCommand(
            ["git", "-C", root, "read-tree", "HEAD"],
            root,
            environment: environment
        )
        if readTree.exitCode != 0 {
            readTree = try await runCommand(
                ["git", "-C", root, "read-tree", "--empty"],
                root,
                environment: environment
            )
        }
        guard readTree.exitCode == 0 else {
            throw gitCommandError(readTree)
        }
        let stage = try await runCommand(
            ["git", "-C", root, "add", "-A", "--", "."],
            root,
            environment: environment
        )
        guard stage.exitCode == 0 else {
            throw gitCommandError(stage)
        }
        let writeTree = try await runCommand(
            ["git", "-C", root, "write-tree"],
            root,
            environment: environment
        )
        guard writeTree.exitCode == 0,
              !trimmed(writeTree.stdout).isEmpty
        else {
            throw gitCommandError(writeTree)
        }
        return trimmed(writeTree.stdout)
    }

    private func latestTurnCheckpoint(
        root: String,
        refPrefix: String,
        nowMs: Int64
    ) async throws -> String? {
        let refs = try await run(
            [
                "git", "-C", root, "for-each-ref", "--sort=-refname",
                "--format=%(refname) %(objectname)", refPrefix,
            ],
            root
        )
        guard refs.exitCode == 0 else {
            return nil
        }
        for line in lines(refs.stdout) {
            let fields = line.split(separator: " ", maxSplits: 1)
            guard fields.count == 2 else {
                continue
            }
            let ref = String(fields[0])
            let oid = String(fields[1])
            let suffix = ref.dropFirst(refPrefix.count)
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard let timestampText = suffix.split(separator: "/").first,
                  let timestamp = Int64(timestampText),
                  nowMs - timestamp <= 7 * 24 * 60 * 60 * 1_000
            else {
                continue
            }
            return oid
        }
        return nil
    }

    private func treeDiff(
        root: String,
        base: String,
        head: String
    ) async throws -> CodexJSONValue {
        let result = try await run(
            ["git", "-C", root, "diff", "--binary", base, head],
            root
        )
        return result.exitCode == 0 || result.exitCode == 1
            ? successfulUnifiedDiff(result.stdout)
            : unknownDiffError()
    }

    private func runCommand(
        _ arguments: [String],
        _ cwd: String,
        environment: [String: String?]?
    ) async throws -> CodexDesktopCommandExecResult {
        if let runWithEnvironment {
            return try await runWithEnvironment(
                arguments,
                cwd,
                environment
            )
        }
        return try await run(arguments, cwd)
    }

    private func isDirectory(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(
            atPath: path,
            isDirectory: &isDirectory
        ) && isDirectory.boolValue
    }

    private func sha1(_ value: String) -> String {
        Insecure.SHA1.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private func sha256(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private func hostID(
        in params: [String: CodexJSONValue]
    ) -> String {
        guard case let .object(host)? = params["hostConfig"],
              case let .string(id)? = host["id"],
              !id.isEmpty
        else {
            return "local"
        }
        return id
    }

    private func isSafeRelativeGitPath(_ path: String) -> Bool {
        guard !path.isEmpty,
              !path.hasPrefix("/"),
              !path.contains("\u{0}")
        else {
            return false
        }
        return !path.split(separator: "/").contains("..")
    }

    private func requiredString(
        _ key: String,
        in fields: [String: CodexJSONValue]
    ) throws -> String {
        guard case let .string(value)? = fields[key],
              !value.isEmpty,
              !value.contains("\u{0}")
        else {
            throw CodexDesktopWorkerMethodError(
                "Invalid git worker parameter: \(key)"
            )
        }
        return value
    }

    private func optionalString(
        _ key: String,
        in fields: [String: CodexJSONValue]
    ) throws -> String? {
        switch fields[key] {
        case nil, .null?:
            return nil
        case let .string(value)? where !value.isEmpty:
            return value
        default:
            throw CodexDesktopWorkerMethodError(
                "Invalid git worker parameter: \(key)"
            )
        }
    }

    private func optionalBool(
        _ key: String,
        in fields: [String: CodexJSONValue]
    ) throws -> Bool? {
        switch fields[key] {
        case nil, .null?:
            return nil
        case let .bool(value)?:
            return value
        default:
            throw CodexDesktopWorkerMethodError(
                "Invalid git worker parameter: \(key)"
            )
        }
    }

    private func boundedInteger(
        _ key: String,
        in fields: [String: CodexJSONValue],
        defaultValue: Int,
        range: ClosedRange<Int>
    ) throws -> Int {
        let raw: Int
        switch fields[key] {
        case nil, .null?:
            raw = defaultValue
        case let .integer(value)?
        where value >= Int64(Int.min) && value <= Int64(Int.max):
            raw = Int(value)
        default:
            throw CodexDesktopWorkerMethodError(
                "Invalid git worker parameter: \(key)"
            )
        }
        return min(max(raw, range.lowerBound), range.upperBound)
    }

    private func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func lines(_ value: String) -> [String] {
        value.split(whereSeparator: \.isNewline).map(String.init)
    }

    private func gitCommandError(
        _ result: CodexDesktopCommandExecResult
    ) -> CodexDesktopWorkerMethodError {
        CodexDesktopWorkerMethodError(
            trimmed(result.stderr).isEmpty
                ? "Git command failed with exit code \(result.exitCode)"
                : trimmed(result.stderr)
        )
    }

    private func commandErrorText(
        _ result: CodexDesktopCommandExecResult,
        fallback: String
    ) -> String {
        let stderr = trimmed(result.stderr)
        if !stderr.isEmpty {
            return stderr
        }
        let stdout = trimmed(result.stdout)
        return stdout.isEmpty ? fallback : stdout
    }

    private func execOutput(
        _ result: CodexDesktopCommandExecResult,
        command: String,
        fallback: String
    ) -> CodexJSONValue {
        let combined = [result.stdout, result.stderr]
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        return .object([
            "command": .string(command),
            "output": .string(combined.isEmpty ? fallback : combined),
        ])
    }

    private func statusSummary(_ output: String) -> CodexJSONValue {
        var staged = 0
        var unstaged = 0
        var untracked = 0
        for line in lines(output) where line.count >= 2 {
            let status = Array(line.prefix(2))
            if status[0] == "?" && status[1] == "?" {
                untracked += 1
            } else {
                if status[0] != " " {
                    staged += 1
                }
                if status[1] != " " {
                    unstaged += 1
                }
            }
        }
        return .object([
            "type": .string("success"),
            "stagedCount": .integer(Int64(staged)),
            "unstagedCount": .integer(Int64(unstaged)),
            "untrackedCount": .integer(Int64(untracked)),
        ])
    }

    private func hasPartialCloneConfiguration(_ output: String) -> Bool {
        lines(output).contains { line in
            let components = line.split(
                maxSplits: 1,
                whereSeparator: \.isWhitespace
            )
            guard let key = components.first.map(String.init) else {
                return false
            }
            let value = components.count > 1
                ? String(components[1]).lowercased()
                : ""
            return key == "extensions.partialclone"
                || key.hasSuffix(".partialclonefilter")
                || (
                    key.hasSuffix(".promisor")
                        && ["", "1", "on", "true", "yes"].contains(value)
                )
        }
    }

    private func parseBranchCommits(
        _ output: String
    ) -> [CodexJSONValue] {
        output.split(separator: "\u{1e}", omittingEmptySubsequences: true)
            .compactMap { record in
                let fields = record.trimmingCharacters(
                    in: .whitespacesAndNewlines
                ).split(
                    separator: "\u{0}",
                    maxSplits: 3,
                    omittingEmptySubsequences: false
                )
                guard fields.count == 4,
                      !fields[0].isEmpty,
                      !fields[1].isEmpty
                else {
                    return nil
                }
                return .object([
                    "sha": .string(String(fields[0])),
                    "committedAt": .string(String(fields[1])),
                    "subject": .string(String(fields[2])),
                    "message": .string(String(fields[3])),
                ])
            }
    }

    private func searchBranches(
        _ refs: [String],
        query: String,
        limit: Int,
        preserveRemoteRefs: Bool
    ) -> CodexJSONValue {
        let terms = query.split(whereSeparator: \.isWhitespace)
            .map(String.init)
        var local: [String] = []
        var remote: [String] = []
        var seen: Set<String> = []
        for ref in refs {
            let isRemote = ref.hasPrefix("refs/remotes/")
            let name: String
            if ref.hasPrefix("refs/heads/") {
                name = String(ref.dropFirst("refs/heads/".count))
            } else if isRemote {
                name = String(ref.dropFirst("refs/remotes/".count))
            } else {
                continue
            }
            guard !name.hasSuffix("/HEAD"),
                  terms.allSatisfy({
                      name.lowercased().contains($0)
                  })
            else {
                continue
            }
            let display = isRemote && !preserveRemoteRefs
                ? name.split(separator: "/", maxSplits: 1)
                    .dropFirst().first.map(String.init) ?? name
                : name
            guard seen.insert(display).inserted else {
                continue
            }
            if isRemote {
                remote.append(display)
            } else {
                local.append(display)
            }
            if local.count >= limit {
                break
            }
        }
        let localResult = Array(local.prefix(limit))
        let remaining = max(limit - localResult.count, 0)
        let remoteResult = Array(remote.prefix(remaining))
        return .object([
            "branches": .array(
                (preserveRemoteRefs
                    ? localResult
                    : localResult + remoteResult
                ).map(CodexJSONValue.string)
            ),
            "remoteBranchRefs": .array(
                (preserveRemoteRefs ? remoteResult : [])
                    .map(CodexJSONValue.string)
            ),
        ])
    }

    private func resolveOrigin(
        dir: String
    ) async throws -> CodexJSONValue? {
        let rootResult = try await run(
            ["git", "-C", dir, "rev-parse", "--show-toplevel"],
            dir
        )
        guard rootResult.exitCode == 0 else {
            return nil
        }
        let root = trimmed(rootResult.stdout)
        let commonResult = try await run(
            ["git", "-C", root, "rev-parse", "--git-common-dir"],
            root
        )
        guard commonResult.exitCode == 0 else {
            return nil
        }
        let rawCommon = trimmed(commonResult.stdout)
        let commonDir = (rawCommon as NSString).isAbsolutePath
            ? (rawCommon as NSString).standardizingPath
            : ((root as NSString).appendingPathComponent(rawCommon)
                as NSString).standardizingPath
        let originResult = try await run(
            ["git", "-C", root, "remote", "get-url", "origin"],
            root
        )
        return .object([
            "dir": .string(dir),
            "root": .string(root),
            "originUrl": originResult.exitCode == 0
                ? .string(trimmed(originResult.stdout))
                : .null,
            "commonDir": .string(commonDir),
        ])
    }

    private func parseWorktrees(
        _ output: String
    ) -> [CodexJSONValue] {
        struct Entry {
            var root = ""
            var sha = ""
            var branch: String?
            var prunable = false
            var locked = false
        }
        var entries: [Entry] = []
        var current: Entry?

        func encode(_ entry: Entry) -> CodexJSONValue? {
            guard !entry.root.isEmpty else {
                return nil
            }
            var headRef: [String: CodexJSONValue] = [
                "sha": .string(entry.sha),
                "type": .string(
                    entry.branch == nil ? "detached" : "branch"
                ),
            ]
            if let branch = entry.branch {
                headRef["string"] = .string(branch)
            }
            return .object([
                "root": .string(entry.root),
                "prunable": .bool(entry.prunable),
                "locked": .bool(entry.locked),
                "headRef": .object(headRef),
            ])
        }

        for rawLine in output.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            if line.isEmpty {
                if let current, let encoded = encode(current) {
                    entries.append(current)
                    _ = encoded
                }
                current = nil
            } else if line.hasPrefix("worktree ") {
                if let current, encode(current) != nil {
                    entries.append(current)
                }
                current = Entry(
                    root: String(line.dropFirst("worktree ".count))
                )
            } else if line.hasPrefix("HEAD ") {
                current?.sha = String(line.dropFirst("HEAD ".count))
            } else if line.hasPrefix("branch ") {
                let ref = String(line.dropFirst("branch ".count))
                current?.branch = ref.hasPrefix("refs/heads/")
                    ? String(ref.dropFirst("refs/heads/".count))
                    : ref
            } else if line == "detached" {
                current?.branch = nil
            } else if line.hasPrefix("prunable") {
                current?.prunable = true
            } else if line.hasPrefix("locked") {
                current?.locked = true
            }
        }
        if let current, encode(current) != nil {
            entries.append(current)
        }
        return entries.compactMap(encode)
    }

    private func applyPatch(
        _ params: [String: CodexJSONValue]
    ) async throws -> CodexJSONValue {
        let cwd = try requiredString("cwd", in: params)
        let diff = try requiredString("diff", in: params)
        let atomic = try optionalBool("atomic", in: params) ?? false
        let revert = try optionalBool("revert", in: params) ?? false
        let allowBinary =
            try optionalBool("allowBinary", in: params) ?? false
        let target = try optionalString("target", in: params) ?? "unstaged"
        guard ["unstaged", "staged", "staged-and-unstaged"]
            .contains(target)
        else {
            throw CodexDesktopWorkerMethodError(
                "Invalid git worker parameter: target"
            )
        }

        let patchURL = URL(fileURLWithPath: cwd)
            .appendingPathComponent(
                ".codex-apply-\(UUID().uuidString).patch"
            )
        try Data(diff.utf8).write(to: patchURL, options: .atomic)
        defer {
            try? FileManager.default.removeItem(at: patchURL)
        }

        var arguments = ["git", "-C", cwd, "apply"]
        if revert {
            arguments.append("-R")
        }
        if allowBinary {
            arguments.append("--binary")
        }
        if !atomic {
            arguments.append("--3way")
        }
        switch target {
        case "staged":
            arguments.append("--cached")
        case "staged-and-unstaged":
            arguments.append("--index")
        default:
            break
        }
        arguments.append(patchURL.path)
        let result = try await run(arguments, cwd)
        let paths = patchPaths(diff)
        let success = result.exitCode == 0
        let partial = result.exitCode == 1 && !atomic
        return .object([
            "status": .string(
                success
                    ? "success"
                    : (partial ? "partial-success" : "error")
            ),
            "appliedPaths": .array(
                (success ? paths : []).map(CodexJSONValue.string)
            ),
            "skippedPaths": .array([]),
            "conflictedPaths": .array(
                (partial ? paths : []).map(CodexJSONValue.string)
            ),
            "execOutput": execOutput(
                result,
                command: arguments.joined(separator: " "),
                fallback: success
                    ? "Patch applied"
                    : "Failed to apply patch"
            ),
        ])
    }

    private func applyChanges(
        _ params: [String: CodexJSONValue]
    ) async throws -> CodexJSONValue {
        let sourceHeadRef = try requiredString(
            "sourceHeadRef",
            in: params
        )
        let sourceTreeRef = try requiredString(
            "sourceTreeRef",
            in: params
        )
        let destinationRoot = try requiredString(
            "destinationRoot",
            in: params
        )
        let destinationHeadRef = try requiredString(
            "destinationHeadRef",
            in: params
        )
        let mergeBase = try await run(
            [
                "git", "-C", destinationRoot, "merge-base",
                sourceHeadRef, destinationHeadRef,
            ],
            destinationRoot
        )
        guard mergeBase.exitCode == 0,
              !trimmed(mergeBase.stdout).isEmpty
        else {
            return .object([
                "status": .string("command-error"),
                "execOutput": execOutput(
                    mergeBase,
                    command: "git merge-base",
                    fallback: "Failed to resolve merge base"
                ),
            ])
        }

        let base = trimmed(mergeBase.stdout)
        let diff = try await run(
            [
                "git", "-C", destinationRoot, "diff", "--binary",
                "--full-index", base, sourceTreeRef,
            ],
            destinationRoot
        )
        guard diff.exitCode == 0 || diff.exitCode == 1 else {
            return .object([
                "status": .string("command-error"),
                "execOutput": execOutput(
                    diff,
                    command: "git diff --binary",
                    fallback: "Failed to compute source changes"
                ),
            ])
        }
        guard !diff.stdout.isEmpty else {
            return .object(["status": .string("success")])
        }

        let stagedSnapshot = try await run(
            [
                "git", "-C", destinationRoot, "diff", "--cached",
                "--binary", "--full-index",
            ],
            destinationRoot
        )
        guard stagedSnapshot.exitCode == 0
            || stagedSnapshot.exitCode == 1
        else {
            return .object([
                "status": .string("command-error"),
                "execOutput": execOutput(
                    stagedSnapshot,
                    command: "git diff --cached --binary",
                    fallback: "Failed to preserve destination index"
                ),
            ])
        }
        if !stagedSnapshot.stdout.isEmpty {
            let clearIndex = try await run(
                [
                    "git", "-C", destinationRoot, "reset", "--mixed",
                    "HEAD",
                ],
                destinationRoot
            )
            guard clearIndex.exitCode == 0 else {
                return .object([
                    "status": .string("command-error"),
                    "execOutput": execOutput(
                        clearIndex,
                        command: "git reset --mixed HEAD",
                        fallback: "Failed to prepare destination index"
                    ),
                ])
            }
        }
        let applied = try await applyPatch([
            "cwd": .string(destinationRoot),
            "diff": .string(diff.stdout),
            "allowBinary": .bool(true),
            "atomic": .bool(false),
            "target": .string("unstaged"),
        ])
        guard case let .object(fields) = applied else {
            return .object(["status": .string("command-error")])
        }
        switch fields["status"] {
        case .string("success")?:
            let resetIndex = try await run(
                [
                    "git", "-C", destinationRoot, "reset", "--mixed",
                    "HEAD",
                ],
                destinationRoot
            )
            guard resetIndex.exitCode == 0 else {
                return .object([
                    "status": .string("command-error"),
                    "execOutput": execOutput(
                        resetIndex,
                        command: "git reset --mixed HEAD",
                        fallback: "Failed to restore destination index"
                    ),
                ])
            }
            if !stagedSnapshot.stdout.isEmpty {
                let restoreStaged = try await applyPatch([
                    "cwd": .string(destinationRoot),
                    "diff": .string(stagedSnapshot.stdout),
                    "allowBinary": .bool(true),
                    "atomic": .bool(true),
                    "target": .string("staged"),
                ])
                guard case let .object(restored) = restoreStaged,
                      restored["status"] == .string("success")
                else {
                    return .object([
                        "status": .string("command-error"),
                        "execOutput": .object([
                            "command": .string("git apply --cached"),
                            "output": .string(
                                "Failed to restore destination index"
                            ),
                        ]),
                    ])
                }
            }
            return .object(["status": .string("success")])
        case .string("partial-success")?:
            return .object([
                "status": .string("partial-success"),
                "appliedPaths": fields["appliedPaths"] ?? .array([]),
                "skippedPaths": fields["skippedPaths"] ?? .array([]),
                "conflictedPaths": fields["conflictedPaths"] ?? .array([]),
            ])
        default:
            return .object([
                "status": .string("command-error"),
                "execOutput": fields["execOutput"] ?? .null,
            ])
        }
    }

    private func applyReviewSectionChanges(
        _ params: [String: CodexJSONValue]
    ) async throws -> CodexJSONValue {
        let action = try requiredString("action", in: params)
        let cwd = try requiredString("cwd", in: params)
        let source = try requiredString("source", in: params)
        guard ["stage", "unstage", "revert"].contains(action),
              ["staged", "unstaged", "uncommitted"].contains(source)
        else {
            throw CodexDesktopWorkerMethodError(
                "Invalid review section operation"
            )
        }
        guard case let .array(rawFiles)? = params["files"] else {
            throw CodexDesktopWorkerMethodError(
                "Invalid git worker parameter: files"
            )
        }
        struct RequestedReviewFile {
            let path: String
            let previousPath: String?
            let revision: String
            let changeKind: String
        }
        var files: [RequestedReviewFile] = []
        var paths: [String] = []
        for rawFile in rawFiles {
            guard case let .object(file) = rawFile,
                  case let .string(path)? = file["path"],
                  case let .string(revision)? = file["revision"],
                  case let .string(changeKind)? = file["changeKind"],
                  isSafeRelativeGitPath(path),
                  !revision.isEmpty
            else {
                throw CodexDesktopWorkerMethodError(
                    "Invalid review section file"
                )
            }
            let previousPath: String?
            if case let .string(value)? = file["previousPath"] {
                guard isSafeRelativeGitPath(value) else {
                    throw CodexDesktopWorkerMethodError(
                        "Invalid review section previous path"
                    )
                }
                previousPath = value
            } else {
                previousPath = nil
            }
            files.append(
                .init(
                    path: path,
                    previousPath: previousPath,
                    revision: revision,
                    changeKind: changeKind
                )
            )
            if !paths.contains(path) {
                paths.append(path)
            }
            if let previousPath,
               !paths.contains(previousPath)
            {
                paths.append(previousPath)
            }
        }
        guard !paths.isEmpty else {
            return reviewApplyError()
        }

        let rootResult = try await run(
            ["git", "-C", cwd, "rev-parse", "--show-toplevel"],
            cwd
        )
        guard rootResult.exitCode == 0 else {
            return reviewApplyError(errorCode: "not-git-repo")
        }
        let root = trimmed(rootResult.stdout)
        let trackedFiles = files.filter { $0.changeKind != "untracked" }
        let untrackedFiles = files.filter { $0.changeKind == "untracked" }
        var trackedPaths: [String] = []
        for file in trackedFiles {
            if !trackedPaths.contains(file.path) {
                trackedPaths.append(file.path)
            }
            if let previousPath = file.previousPath,
               !trackedPaths.contains(previousPath)
            {
                trackedPaths.append(previousPath)
            }
        }
        var comparison: [String] = []
        if source == "staged" {
            comparison.append("--cached")
        } else if source == "uncommitted" {
            comparison.append("HEAD")
        }
        var currentRevisions: [String: String] = [:]
        if !trackedPaths.isEmpty {
            let revisionResult = try await run(
                [
                    "git", "-C", root, "diff", "--raw", "--no-abbrev",
                ] + comparison + ["--"] + trackedPaths,
                root
            )
            guard revisionResult.exitCode == 0
                    || revisionResult.exitCode == 1
            else {
                return reviewApplyError()
            }
            currentRevisions = reviewRevisions(
                revisionResult.stdout,
                source: source
            )
        }
        for file in untrackedFiles {
            guard let revision = try await untrackedRevision(
                cwd: root,
                path: file.path
            ),
            revision == file.revision else {
                return reviewApplyError()
            }
        }
        guard trackedFiles.allSatisfy({
            currentRevisions[$0.path] == $0.revision
        }) else {
            return reviewApplyError()
        }

        var binaryDiffs: [String] = []
        if !trackedPaths.isEmpty {
            var diffArguments = [
                "git", "-C", root, "diff", "--binary", "--full-index",
            ]
            diffArguments.append(contentsOf: comparison)
            diffArguments.append("--")
            diffArguments.append(contentsOf: trackedPaths)
            let diff = try await run(diffArguments, root)
            guard diff.exitCode == 0 || diff.exitCode == 1,
                  !diff.stdout.trimmingCharacters(
                    in: .whitespacesAndNewlines
                  ).isEmpty
            else {
                return reviewApplyError()
            }
            binaryDiffs.append(diff.stdout)
        }
        for file in untrackedFiles {
            let diff = try await run(
                [
                    "git", "-C", root, "diff", "--no-index", "--binary",
                    "--", "/dev/null", file.path,
                ],
                root
            )
            guard diff.exitCode == 1,
                  !diff.stdout.trimmingCharacters(
                    in: .whitespacesAndNewlines
                  ).isEmpty
            else {
                return reviewApplyError()
            }
            binaryDiffs.append(diff.stdout)
        }
        guard !binaryDiffs.isEmpty else {
            return reviewApplyError()
        }
        let binaryDiff = binaryDiffs.joined(separator: "\n")

        func perform(
            target: String,
            revert: Bool
        ) async throws -> CodexJSONValue {
            try await applyPatch([
                "cwd": .string(root),
                "diff": .string(binaryDiff),
                "allowBinary": .bool(true),
                "atomic": .bool(true),
                "revert": .bool(revert),
                "target": .string(target),
            ])
        }

        switch action {
        case "stage":
            return try await perform(target: "staged", revert: false)
        case "unstage":
            return try await perform(target: "staged", revert: true)
        default:
            if source == "staged" {
                let unstagedIndex = try await perform(
                    target: "staged",
                    revert: true
                )
                guard case let .object(first) = unstagedIndex,
                      first["status"] == .string("success")
                else {
                    return unstagedIndex
                }
                let revertedWorktree = try await perform(
                    target: "unstaged",
                    revert: true
                )
                guard case let .object(second) = revertedWorktree,
                      second["status"] != .string("success")
                else {
                    return revertedWorktree
                }
                var partial = second
                partial["status"] = .string("partial-success")
                return .object(partial)
            }
            return try await perform(target: "unstaged", revert: true)
        }
    }

    private func overwriteRepository(
        _ params: [String: CodexJSONValue]
    ) async throws -> CodexJSONValue {
        let gitRoot = try requiredString("gitRoot", in: params)
        let targetRoot = try optionalString("targetRoot", in: params)
        let branchName = try requiredString("branchName", in: params)
        let headCommit = try requiredString("headCommitSha", in: params)
        let requestedTree = try optionalString("treeSha", in: params)
        let targetBranch = try optionalString(
            "targetCurrentBranch",
            in: params
        )
        let headTreeResult = try await run(
            [
                "git", "-C", gitRoot, "rev-parse", "--verify",
                "\(headCommit)^{tree}",
            ],
            gitRoot
        )
        guard headTreeResult.exitCode == 0,
              !trimmed(headTreeResult.stdout).isEmpty
        else {
            return overwriteCommandError(
                headTreeResult,
                command: "git rev-parse",
                fallback: "Failed to resolve source tree"
            )
        }
        let headTree = trimmed(headTreeResult.stdout)
        let shouldCreateSyntheticCommit =
            requestedTree != nil
                && requestedTree != headTree
                && (
                    targetRoot == nil
                        || targetBranch == nil
                        || targetBranch == branchName
                )
        var commitToApply = headCommit
        if shouldCreateSyntheticCommit, let requestedTree {
            let commitTree = try await run(
                [
                    "git", "-C", gitRoot, "commit-tree", requestedTree,
                    "-p", headCommit, "-m",
                    "Codex synchronized working tree",
                ],
                gitRoot
            )
            guard commitTree.exitCode == 0,
                  !trimmed(commitTree.stdout).isEmpty
            else {
                return overwriteCommandError(
                    commitTree,
                    command: "git commit-tree",
                    fallback: "Failed to create synthetic commit"
                )
            }
            commitToApply = trimmed(commitTree.stdout)
            let resetSource = try await run(
                ["git", "-C", gitRoot, "reset", "--hard", commitToApply],
                gitRoot
            )
            guard resetSource.exitCode == 0 else {
                return overwriteCommandError(
                    resetSource,
                    command: "git reset --hard",
                    fallback: "Failed to reset source checkout"
                )
            }
        }

        guard let targetRoot else {
            let updateBranch = try await run(
                [
                    "git", "-C", gitRoot, "branch", "-f", branchName,
                    commitToApply,
                ],
                gitRoot
            )
            guard updateBranch.exitCode == 0 else {
                return overwriteCommandError(
                    updateBranch,
                    command: "git branch -f",
                    fallback: "Failed to reset branch"
                )
            }
            return .object(["status": .string("success")])
        }

        let oldHeadResult = try await run(
            [
                "git", "-C", targetRoot, "rev-parse", "--verify",
                "--quiet", "HEAD",
            ],
            targetRoot
        )
        let ref = targetBranch.map { "refs/heads/\($0)" } ?? "HEAD"
        let updateRef = try await run(
            [
                "git", "-C", targetRoot, "update-ref", ref,
                commitToApply,
            ],
            targetRoot
        )
        guard updateRef.exitCode == 0 else {
            return overwriteCommandError(
                updateRef,
                command: "git update-ref",
                fallback: "Failed to reset branch"
            )
        }
        let resetIndex = try await run(
            ["git", "-C", targetRoot, "reset", "--mixed", "HEAD"],
            targetRoot
        )
        guard resetIndex.exitCode == 0 else {
            return overwriteCommandError(
                resetIndex,
                command: "git reset --mixed",
                fallback: "Failed to reset index"
            )
        }

        let treeToRestore = requestedTree ?? headTree
        if oldHeadResult.exitCode == 0,
           !trimmed(oldHeadResult.stdout).isEmpty
        {
            let deleted = try await run(
                [
                    "git", "-C", targetRoot, "diff", "--name-only",
                    "--diff-filter=D", "--no-renames",
                    trimmed(oldHeadResult.stdout), treeToRestore,
                ],
                targetRoot
            )
            if deleted.exitCode == 0 || deleted.exitCode == 1 {
                let deletedPaths = lines(deleted.stdout)
                    .filter(isSafeRelativeGitPath)
                if !deletedPaths.isEmpty {
                    _ = try await run(
                        [
                            "git", "-C", targetRoot, "clean", "-fd", "--",
                        ] + deletedPaths,
                        targetRoot
                    )
                }
            }
        }
        let restore = try await run(
            [
                "git", "-C", targetRoot, "restore", "--source",
                treeToRestore, "--worktree", "--", ".",
            ],
            targetRoot
        )
        guard restore.exitCode == 0 else {
            return overwriteCommandError(
                restore,
                command: "git restore",
                fallback: "Failed to restore working tree"
            )
        }
        return .object(["status": .string("success")])
    }

    private func reviewApplyError(
        errorCode: String? = nil
    ) -> CodexJSONValue {
        var fields: [String: CodexJSONValue] = [
            "status": .string("error"),
            "appliedPaths": .array([]),
            "skippedPaths": .array([]),
            "conflictedPaths": .array([]),
        ]
        if let errorCode {
            fields["errorCode"] = .string(errorCode)
        }
        return .object(fields)
    }

    private func reviewRevisions(
        _ output: String,
        source: String
    ) -> [String: String] {
        let pattern =
            #"^:(\d{6}) (\d{6}) ([0-9a-f]+) ([0-9a-f]+) ([A-Z])(?:\d+)?\t(.+)$"#
        guard let regex = try? NSRegularExpression(
            pattern: pattern,
            options: [.anchorsMatchLines]
        ) else {
            return [:]
        }
        let nsOutput = output as NSString
        var revisions: [String: String] = [:]
        for match in regex.matches(
            in: output,
            range: NSRange(location: 0, length: nsOutput.length)
        ) {
            let oldMode = nsOutput.substring(with: match.range(at: 1))
            let newMode = nsOutput.substring(with: match.range(at: 2))
            let oldOID = nsOutput.substring(with: match.range(at: 3))
            let newOID = nsOutput.substring(with: match.range(at: 4))
            let status = nsOutput.substring(with: match.range(at: 5))
            let rawPaths = nsOutput.substring(with: match.range(at: 6))
                .components(separatedBy: "\t")
            guard let path = rawPaths.last, isSafeRelativeGitPath(path) else {
                continue
            }
            revisions[path] = [
                source, status, oldMode, oldOID, newMode, newOID,
            ].joined(separator: ":")
        }
        return revisions
    }

    private func untrackedRevision(
        cwd: String,
        path: String
    ) async throws -> String? {
        guard isSafeRelativeGitPath(path) else {
            return nil
        }
        let fileURL = URL(fileURLWithPath: cwd)
            .appendingPathComponent(path)
        guard let attributes = try? FileManager.default.attributesOfItem(
            atPath: fileURL.path
        ) else {
            return nil
        }
        let mode: String
        if attributes[.type] as? FileAttributeType == .typeSymbolicLink {
            mode = "120000"
        } else {
            let permissions = (
                attributes[.posixPermissions] as? NSNumber
            )?.intValue ?? 0
            mode = permissions & 0o111 == 0 ? "100644" : "100755"
        }
        let hash = try await run(
            [
                "git", "-C", cwd, "hash-object", "--no-filters",
                "--", path,
            ],
            cwd
        )
        guard hash.exitCode == 0 else {
            return nil
        }
        let oid = trimmed(hash.stdout)
        guard oid.range(
            of: #"^[0-9a-f]{40,64}$"#,
            options: .regularExpression
        ) != nil else {
            return nil
        }
        return "untracked:\(mode):\(oid)"
    }

    private func overwriteCommandError(
        _ result: CodexDesktopCommandExecResult,
        command: String,
        fallback: String
    ) -> CodexJSONValue {
        .object([
            "status": .string("command-error"),
            "execOutput": execOutput(
                result,
                command: command,
                fallback: fallback
            ),
        ])
    }

    private func patchPaths(_ diff: String) -> [String] {
        let pattern = #"^diff --git a/(.*?) b/(.*)$"#
        guard let regex = try? NSRegularExpression(
            pattern: pattern,
            options: [.anchorsMatchLines]
        ) else {
            return []
        }
        let nsDiff = diff as NSString
        var seen: Set<String> = []
        var paths: [String] = []
        for match in regex.matches(
            in: diff,
            range: NSRange(location: 0, length: nsDiff.length)
        ) {
            for index in 1 ... 2 {
                let range = match.range(at: index)
                guard range.location != NSNotFound else {
                    continue
                }
                let path = nsDiff.substring(with: range)
                guard path != "/dev/null",
                      seen.insert(path).inserted
                else {
                    continue
                }
                paths.append(path)
            }
        }
        return paths
    }

    private func parseAheadBehind(
        _ output: String
    ) -> (left: Int64, right: Int64)? {
        let values = output.split(whereSeparator: \.isWhitespace)
        guard values.count >= 2,
              let left = Int64(values[0]),
              let right = Int64(values[1])
        else {
            return nil
        }
        return (left, right)
    }

    private func emptyBranchMetadata() -> CodexJSONValue {
        .object([
            "gitRoot": .null,
            "branch": .null,
            "baseBranch": .null,
            "baseBranchRemote": .null,
        ])
    }

    private func unknownDiffError() -> CodexJSONValue {
        .object([
            "type": .string("error"),
            "error": .object(["type": .string("unknown")]),
        ])
    }

    private func successfulUnifiedDiff(
        _ diff: String
    ) -> CodexJSONValue {
        .object([
            "type": .string("success"),
            "unifiedDiff": .string(diff),
            "unifiedDiffBytes": .integer(Int64(Data(diff.utf8).count)),
        ])
    }

    private func successfulFileDiff(
        _ diff: String
    ) -> CodexJSONValue {
        .object([
            "type": .string("success"),
            "diff": .string(diff),
            "diffBytes": .integer(Int64(Data(diff.utf8).count)),
        ])
    }

    private struct ReviewStat {
        let path: String
        let additions: Int
        let deletions: Int
    }

    private struct ReviewChange {
        let path: String
        let previousPath: String?
        let kind: String
        let status: String
    }

    private func reviewSummary(
        _ params: [String: CodexJSONValue]
    ) async throws -> CodexJSONValue {
        let cwd = try requiredString("cwd", in: params)
        let source = try requiredString("source", in: params)
        guard let comparison = try await reviewComparisonArguments(
            source: source,
            params: params,
            cwd: cwd
        ) else {
            return reviewSummaryError(
                source: source,
                reason: "review_comparison"
            )
        }
        let hideWhitespace =
            try optionalBool("hideWhitespace", in: params) ?? false
        let includeUntracked =
            try optionalBool("includeUntrackedFiles", in: params) ?? true
        var nameArguments = [
            "git", "-C", cwd, "diff", "--name-status", "--find-renames",
        ]
        var statArguments = [
            "git", "-C", cwd, "diff", "--numstat", "--find-renames",
        ]
        var rawArguments = [
            "git", "-C", cwd, "diff", "--raw", "--no-abbrev",
            "--find-renames",
        ]
        if hideWhitespace {
            nameArguments.append("--ignore-all-space")
            statArguments.append("--ignore-all-space")
            rawArguments.append("--ignore-all-space")
        }
        nameArguments.append(contentsOf: comparison)
        statArguments.append(contentsOf: comparison)
        rawArguments.append(contentsOf: comparison)
        let requestedPaths: [String]
        if case let .array(values)? = params["paths"] {
            requestedPaths = values.compactMap {
                guard case let .string(path) = $0,
                      isSafeRelativeGitPath(path)
                else {
                    return nil
                }
                return path
            }
        } else {
            requestedPaths = []
        }
        if !requestedPaths.isEmpty {
            nameArguments.append("--")
            nameArguments.append(contentsOf: requestedPaths)
            statArguments.append("--")
            statArguments.append(contentsOf: requestedPaths)
            rawArguments.append("--")
            rawArguments.append(contentsOf: requestedPaths)
        }
        let names = try await run(nameArguments, cwd)
        let numstat = try await run(statArguments, cwd)
        let raw = try await run(rawArguments, cwd)
        guard names.exitCode == 0,
              numstat.exitCode == 0,
              raw.exitCode == 0
        else {
            return reviewSummaryError(
                source: source,
                reason: "review_files"
            )
        }
        var changes = parseReviewChanges(names.stdout)
        var stats = parseNumstat(numstat.stdout)
        var untrackedCount = 0
        var omitted: CodexJSONValue?
        if includeUntracked,
           ["branch", "uncommitted", "unstaged"].contains(source)
        {
            let untracked = try await untrackedPaths(cwd: cwd)
            guard untracked.success else {
                return reviewSummaryError(
                    source: source,
                    reason: "untracked_paths"
                )
            }
            let filtered = requestedPaths.isEmpty
                ? untracked.paths
                : untracked.paths.filter(requestedPaths.contains)
            untrackedCount = filtered.count
            let limit = 512
            if filtered.count > limit {
                omitted = .object([
                    "count": .integer(Int64(filtered.count)),
                    "limit": .integer(Int64(limit)),
                ])
            } else {
                for path in filtered {
                    changes.append(.init(
                        path: path,
                        previousPath: nil,
                        kind: "untracked",
                        status: "A"
                    ))
                    stats.append(untrackedFileStat(cwd: cwd, path: path))
                }
            }
        }
        var revisionByPath = reviewRevisions(raw.stdout, source: source)
        for change in changes where change.kind == "untracked" {
            if let revision = try await untrackedRevision(
                cwd: cwd,
                path: change.path
            ) {
                revisionByPath[change.path] = revision
            }
        }
        let statByPath = Dictionary(
            stats.map { ($0.path, $0) },
            uniquingKeysWith: { _, latest in latest }
        )
        let files = changes
            .map { change -> CodexJSONValue in
                let stat = statByPath[change.path]
                let revision = revisionByPath[change.path] ?? [
                        source,
                        change.status,
                        change.previousPath ?? "",
                        change.path,
                        String(stat?.additions ?? 0),
                        String(stat?.deletions ?? 0),
                    ].joined(separator: ":")
                return .object([
                    "additions": stat.map {
                        .integer(Int64($0.additions))
                    } ?? .null,
                    "changeKind": .string(change.kind),
                    "deletions": stat.map {
                        .integer(Int64($0.deletions))
                    } ?? .null,
                    "path": .string(change.path),
                    "previousPath": change.previousPath
                        .map(CodexJSONValue.string) ?? .null,
                    "revision": .string(revision),
                ])
            }
            .sorted {
                guard case let .object(left) = $0,
                      case let .object(right) = $1,
                      case let .string(leftPath)? = left["path"],
                      case let .string(rightPath)? = right["path"]
                else {
                    return false
                }
                return leftPath < rightPath
            }
        let status = try await run(
            [
                "git", "-C", cwd, "status", "--porcelain=v1",
                includeUntracked
                    ? "--untracked-files=all"
                    : "--untracked-files=no",
            ],
            cwd
        )
        guard status.exitCode == 0 else {
            return reviewSummaryError(
                source: source,
                reason: "stage_counts"
            )
        }
        let counts = reviewStageCounts(status.stdout)
        var response: [String: CodexJSONValue] = [
            "type": .string("success"),
            "files": .array(files),
            "snapshotGeneration": .integer(
                Int64(Date().timeIntervalSince1970 * 1_000)
            ),
            "source": .string(source),
            "stageCounts": .object([
                "stagedFileCount": .integer(Int64(counts.staged)),
                "unstagedFileCount": .integer(Int64(counts.unstaged)),
                "untrackedFileCount": .integer(
                    Int64(max(counts.untracked, untrackedCount))
                ),
            ]),
        ]
        if let omitted {
            response["untrackedFilesOmitted"] = omitted
        }
        return .object(response)
    }

    private func reviewSummaryError(
        source: String,
        reason: String
    ) -> CodexJSONValue {
        .object([
            "type": .string("error"),
            "source": .string(source),
            "failureReason": .string(reason),
        ])
    }

    private func parseReviewChanges(_ output: String) -> [ReviewChange] {
        lines(output).compactMap { line in
            let fields = line.split(
                separator: "\t",
                omittingEmptySubsequences: false
            ).map(String.init)
            guard let rawStatus = fields.first,
                  let code = rawStatus.first
            else {
                return nil
            }
            let kind: String
            switch code {
            case "A": kind = "added"
            case "D": kind = "deleted"
            case "R": kind = "renamed"
            case "C": kind = "copied"
            case "T": kind = "type-changed"
            case "U": kind = "unmerged"
            default: kind = "modified"
            }
            if ["R", "C"].contains(code), fields.count >= 3 {
                return ReviewChange(
                    path: fields[2],
                    previousPath: fields[1],
                    kind: kind,
                    status: String(code)
                )
            }
            guard fields.count >= 2 else {
                return nil
            }
            return ReviewChange(
                path: fields[1],
                previousPath: nil,
                kind: kind,
                status: String(code)
            )
        }
    }

    private func parseNumstat(_ output: String) -> [ReviewStat] {
        lines(output).compactMap { line in
            let fields = line.split(
                separator: "\t",
                omittingEmptySubsequences: false
            ).map(String.init)
            guard fields.count >= 3 else {
                return nil
            }
            let additions = fields[0] == "-" ? 0 : Int(fields[0]) ?? 0
            let deletions = fields[1] == "-" ? 0 : Int(fields[1]) ?? 0
            return ReviewStat(
                path: fields.last ?? "",
                additions: additions,
                deletions: deletions
            )
        }
    }

    private func untrackedPaths(
        cwd: String
    ) async throws -> (success: Bool, paths: [String]) {
        let result = try await run(
            [
                "git", "-C", cwd, "ls-files", "--others",
                "--exclude-standard", "-z",
            ],
            cwd
        )
        return (
            result.exitCode == 0,
            result.exitCode == 0
                ? result.stdout.split(
                    separator: "\u{0}",
                    omittingEmptySubsequences: true
                ).map(String.init).filter(isSafeRelativeGitPath)
                : []
        )
    }

    private func untrackedFileStat(
        cwd: String,
        path: String
    ) -> ReviewStat {
        let url = URL(fileURLWithPath: cwd).appendingPathComponent(path)
        guard let data = try? Data(contentsOf: url) else {
            return .init(path: path, additions: 0, deletions: 0)
        }
        let text = String(decoding: data, as: UTF8.self)
        let count = text.isEmpty
            ? 0
            : text.split(
                separator: "\n",
                omittingEmptySubsequences: false
            ).count - (text.hasSuffix("\n") ? 1 : 0)
        return .init(path: path, additions: count, deletions: 0)
    }

    private func branchDiffStats(
        _ stats: [ReviewStat]
    ) -> CodexJSONValue {
        .object([
            "additions": .integer(
                Int64(stats.reduce(0) { $0 + $1.additions })
            ),
            "deletions": .integer(
                Int64(stats.reduce(0) { $0 + $1.deletions })
            ),
            "fileCount": .integer(Int64(stats.count)),
        ])
    }

    private func reviewStageCounts(
        _ output: String
    ) -> (staged: Int, unstaged: Int, untracked: Int) {
        var staged = 0
        var unstaged = 0
        var untracked = 0
        for line in lines(output) where line.count >= 2 {
            let status = Array(line.prefix(2))
            if status[0] == "?", status[1] == "?" {
                untracked += 1
            } else {
                if status[0] != " " {
                    staged += 1
                }
                if status[1] != " " {
                    unstaged += 1
                }
            }
        }
        return (staged, unstaged, untracked)
    }

    private func emptyReviewSearch(
        source: String,
        query: String
    ) -> CodexJSONValue {
        .object([
            "type": .string("success"),
            "source": .string(source),
            "query": .string(query),
            "matches": .array([]),
            "totalMatches": .integer(0),
            "isCapped": .bool(false),
        ])
    }

    private func reviewSearchError(
        source: String,
        query: String
    ) -> CodexJSONValue {
        .object([
            "type": .string("error"),
            "source": .string(source),
            "query": .string(query),
        ])
    }

    private func searchReviewDiff(
        _ diff: String,
        query: String
    ) -> (matches: [CodexJSONValue], total: Int, capped: Bool) {
        let loweredQuery = query.lowercased()
        var path: String?
        var hunkID: String?
        var hunkSequence = 0
        var lineStart = 1
        var lineEnd = 1
        var offset = 0
        var matches: [CodexJSONValue] = []
        var total = 0
        let cap = 250
        let hunkPattern =
            #"^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@"#
        let hunkRegex = try? NSRegularExpression(pattern: hunkPattern)

        func appendMatches(
            text: String,
            currentPath: String,
            currentHunk: String,
            currentOffset: Int,
            currentLineStart: Int,
            currentLineEnd: Int
        ) {
            let lowered = text.lowercased()
            var searchStart = lowered.startIndex
            while searchStart < lowered.endIndex,
                  let range = lowered.range(
                      of: loweredQuery,
                      range: searchStart ..< lowered.endIndex
                  )
            {
                total += 1
                let start = lowered.distance(
                    from: lowered.startIndex,
                    to: range.lowerBound
                )
                let end = lowered.distance(
                    from: lowered.startIndex,
                    to: range.upperBound
                )
                if matches.count < cap {
                    let beforeStart = max(0, start - 24)
                    let afterEnd = min(text.count, end + 24)
                    let before = String(
                        text[
                            text.index(
                                text.startIndex,
                                offsetBy: beforeStart
                            )
                            ..< text.index(
                                text.startIndex,
                                offsetBy: start
                            )
                        ]
                    )
                    let match = String(
                        text[
                            text.index(text.startIndex, offsetBy: start)
                            ..< text.index(text.startIndex, offsetBy: end)
                        ]
                    )
                    let after = String(
                        text[
                            text.index(text.startIndex, offsetBy: end)
                            ..< text.index(
                                text.startIndex,
                                offsetBy: afterEnd
                            )
                        ]
                    )
                    matches.append(.object([
                        "path": .string(currentPath),
                        "hunkId": .string(currentHunk),
                        "lineStart": .integer(Int64(currentLineStart)),
                        "lineEnd": .integer(Int64(currentLineEnd)),
                        "start": .integer(Int64(currentOffset + start)),
                        "end": .integer(Int64(currentOffset + end)),
                        "snippet": .object([
                            "before": .string(before),
                            "match": .string(match),
                            "after": .string(after),
                        ]),
                    ]))
                }
                searchStart = range.upperBound
            }
        }

        for line in diff.components(separatedBy: "\n") {
            if line.hasPrefix("diff --git ") {
                let fields = line.split(separator: " ")
                if fields.count >= 4 {
                    let oldPath = String(fields[2]).replacingOccurrences(
                        of: "a/",
                        with: "",
                        options: [.anchored]
                    )
                    let newPath = String(fields[3]).replacingOccurrences(
                        of: "b/",
                        with: "",
                        options: [.anchored]
                    )
                    path = newPath
                    hunkID = nil
                    offset = 0
                    let display = oldPath == newPath
                        ? newPath
                        : "\(oldPath) -> \(newPath)"
                    appendMatches(
                        text: display,
                        currentPath: newPath,
                        currentHunk: "path",
                        currentOffset: 0,
                        currentLineStart: 1,
                        currentLineEnd: 1
                    )
                }
                continue
            }
            if line.hasPrefix("@@"),
               let hunkRegex,
               let match = hunkRegex.firstMatch(
                   in: line,
                   range: NSRange(line.startIndex..., in: line)
               )
            {
                func number(_ index: Int, default fallback: Int) -> Int {
                    guard let range = Range(
                        match.range(at: index),
                        in: line
                    ) else {
                        return fallback
                    }
                    return Int(line[range]) ?? fallback
                }
                let deletionStart = number(1, default: 1)
                let deletionCount = number(2, default: 1)
                let additionStart = number(3, default: 1)
                let additionCount = number(4, default: 1)
                lineStart = max(1, min(deletionStart, additionStart))
                lineEnd = max(
                    lineStart,
                    max(
                        deletionStart + max(deletionCount, 0) - 1,
                        additionStart + max(additionCount, 0) - 1
                    )
                )
                hunkID = String(hunkSequence)
                hunkSequence += 1
                offset = 0
                continue
            }
            guard let path, let hunkID,
                  let prefix = line.first,
                  [" ", "+", "-"].contains(prefix),
                  !line.hasPrefix("+++"),
                  !line.hasPrefix("---")
            else {
                continue
            }
            let text = String(line.dropFirst())
            appendMatches(
                text: text,
                currentPath: path,
                currentHunk: hunkID,
                currentOffset: offset,
                currentLineStart: lineStart,
                currentLineEnd: lineEnd
            )
            offset += text.count + 1
        }
        return (matches, total, total > cap)
    }

    private func reviewComparisonArguments(
        source: String,
        params: [String: CodexJSONValue],
        cwd: String
    ) async throws -> [String]? {
        switch source {
        case "staged":
            return ["--cached"]
        case "unstaged":
            return []
        case "uncommitted":
            return ["HEAD"]
        case "commit":
            guard let sha = try optionalString("commitSha", in: params),
                  isGitObjectID(sha)
            else {
                return nil
            }
            let parent = try await run(
                ["git", "-C", cwd, "rev-parse", "\(sha)^"],
                cwd
            )
            return [
                parent.exitCode == 0
                    ? trimmed(parent.stdout)
                    : "4b825dc642cb6eb9a060e54bf8d69288fbee4904",
                sha,
            ]
        case "branch":
            let baseBranch =
                try optionalString("baseBranch", in: params) ?? "main"
            let mergeBase = try await run(
                ["git", "-C", cwd, "merge-base", baseBranch, "HEAD"],
                cwd
            )
            guard mergeBase.exitCode == 0 else {
                return nil
            }
            return [trimmed(mergeBase.stdout)]
        default:
            throw CodexDesktopWorkerMethodError(
                "Invalid review source: \(source)"
            )
        }
    }

    private func staleOrUnknownReviewDiff(
        source: String,
        files: CodexJSONValue?
    ) -> CodexJSONValue {
        var diffs: [String: CodexJSONValue] = [:]
        if case let .array(values)? = files {
            for value in values {
                guard case let .object(file) = value,
                      case let .string(path)? = file["path"]
                else {
                    continue
                }
                diffs[path] = unknownDiffError()
            }
        }
        return .object([
            "type": .string("success"),
            "source": .string(source),
            "diffs": .object(diffs),
        ])
    }

    private func blameError(_ type: String) -> CodexJSONValue {
        .object([
            "type": .string("error"),
            "error": .object(["type": .string(type)]),
        ])
    }

    private func parseBlameLines(
        _ output: String
    ) -> [CodexJSONValue] {
        struct Metadata {
            var author: String?
            var authorLogin: String?
            var authorTime: Int64?
            var summary: String?
        }
        struct Pending {
            var sha: String
            var lineNumber: Int64
            var metadata: Metadata
        }
        var cache: [String: Metadata] = [:]
        var pending: Pending?
        var result: [CodexJSONValue] = []
        for rawLine in output.components(separatedBy: "\n") {
            if rawLine.hasPrefix("\t"), let current = pending {
                result.append(.object([
                    "author": current.metadata.author
                        .map(CodexJSONValue.string) ?? .null,
                    "authorLogin": current.metadata.authorLogin
                        .map(CodexJSONValue.string) ?? .null,
                    "authorTime": current.metadata.authorTime
                        .map(CodexJSONValue.integer) ?? .null,
                    "commitSha": .string(current.sha),
                    "lineNumber": .integer(current.lineNumber),
                    "summary": current.metadata.summary
                        .map(CodexJSONValue.string) ?? .null,
                ]))
                cache[current.sha] = current.metadata
                pending = nil
                continue
            }
            let header = rawLine.split(separator: " ")
            if pending == nil,
               header.count >= 3,
               isGitObjectID(String(header[0])),
               let lineNumber = Int64(header[2])
            {
                let sha = String(header[0])
                pending = Pending(
                    sha: sha,
                    lineNumber: lineNumber,
                    metadata: cache[sha] ?? Metadata()
                )
                continue
            }
            guard var current = pending,
                  let separator = rawLine.firstIndex(of: " ")
            else {
                continue
            }
            let key = String(rawLine[..<separator])
            let value = String(rawLine[rawLine.index(after: separator)...])
            switch key {
            case "author":
                current.metadata.author = value.isEmpty ? nil : value
            case "author-mail":
                current.metadata.authorLogin = githubLogin(from: value)
            case "author-time":
                current.metadata.authorTime = Int64(value)
            case "summary":
                current.metadata.summary = value.isEmpty ? nil : value
            default:
                break
            }
            pending = current
        }
        return result
    }

    private func githubLogin(from email: String) -> String? {
        let cleaned = email.trimmingCharacters(
            in: CharacterSet(charactersIn: "<> ")
        )
        let pattern =
            #"^(?:\d+\+)?([^@]+)@users\.noreply\.github\.com$"#
        guard let regex = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive]
        ) else {
            return nil
        }
        let range = NSRange(cleaned.startIndex..., in: cleaned)
        guard let match = regex.firstMatch(in: cleaned, range: range),
              let loginRange = Range(match.range(at: 1), in: cleaned)
        else {
            return nil
        }
        return String(cleaned[loginRange])
    }

    private func repositoryWebURL(_ origin: String) -> String? {
        var value = origin.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasSuffix(".git") {
            value.removeLast(4)
        }
        if value.hasPrefix("git@") {
            let remainder = value.dropFirst(4)
            guard let separator = remainder.firstIndex(of: ":") else {
                return nil
            }
            let host = remainder[..<separator]
            let path = remainder[remainder.index(after: separator)...]
            guard host == "github.com"
                    || host.hasSuffix(".github.com")
            else {
                return nil
            }
            return "https://\(host)/\(path)"
        }
        guard let components = URLComponents(string: value),
              let host = components.host,
              host == "github.com" || host.hasSuffix(".github.com")
        else {
            return nil
        }
        return "https://\(host)\(components.path)"
    }

    private struct SyncedBranchConfig: Decodable {
        let branch: String
        let lastSyncedTreeRef: String
    }

    private func syncedBranchState(
        _ params: [String: CodexJSONValue]
    ) async throws -> CodexJSONValue {
        let cwd = try requiredString("cwd", in: params)
        guard let config = try await syncedBranchConfig(cwd: cwd) else {
            throw CodexDesktopWorkerMethodError(
                "No synced branch config found for the current worktree."
            )
        }
        let rootResult = try await run(
            ["git", "-C", cwd, "rev-parse", "--show-toplevel"],
            cwd
        )
        guard rootResult.exitCode == 0 else {
            throw gitCommandError(rootResult)
        }
        let root = trimmed(rootResult.stdout)
        let headResult = try await run(
            ["git", "-C", root, "rev-parse", "HEAD"],
            root
        )
        let branchHeadResult = try await run(
            ["git", "-C", root, "rev-parse", config.branch],
            root
        )
        guard headResult.exitCode == 0,
              branchHeadResult.exitCode == 0
        else {
            throw CodexDesktopWorkerMethodError(
                "Unable to resolve synced branch head state."
            )
        }
        let head = trimmed(headResult.stdout)
        let branchHead = trimmed(branchHeadResult.stdout)
        let worktreesResult = try await run(
            ["git", "-C", root, "worktree", "list", "--porcelain"],
            root
        )
        let branchName = shortBranchName(config.branch)
        let checkedOutRoot = worktreesResult.exitCode == 0
            ? worktreeRoot(
                forBranch: branchName,
                porcelain: worktreesResult.stdout
            )
            : nil
        let divergence = try await run(
            [
                "git", "-C", root, "rev-list", "--left-right", "--count",
                "\(branchHead)...\(head)",
            ],
            root
        )
        let counts = divergence.exitCode == 0
            ? parseAheadBehind(divergence.stdout)
            : nil
        let worktreeDiff = try await run(
            ["git", "-C", root, "diff", "--numstat", "HEAD"],
            root
        )
        let worktreeStats = worktreeDiff.exitCode == 0
            ? parseNumstat(worktreeDiff.stdout)
            : []
        var localStats: [ReviewStat] = []
        if let checkedOutRoot, checkedOutRoot != root {
            let localDiff = try await run(
                [
                    "git", "-C", checkedOutRoot, "diff", "--numstat",
                    "HEAD",
                ],
                checkedOutRoot
            )
            if localDiff.exitCode == 0 {
                localStats = parseNumstat(localDiff.stdout)
            }
        }
        let localDiffEnvelope = syncedDiffStats(
            localStats,
            leftRef: branchHead,
            rightRef: localStats.isEmpty ? branchHead : "WORKTREE"
        )
        let worktreeDiffEnvelope = syncedDiffStats(
            worktreeStats,
            leftRef: head,
            rightRef: worktreeStats.isEmpty ? head : "WORKTREE"
        )
        let branchSnapshot: CodexJSONValue
        if let checkedOutRoot {
            branchSnapshot = .object([
                "checkedOut": .bool(true),
                "snapshot": .object([
                    "root": .string(checkedOutRoot),
                    "headCommitSha": .string(branchHead),
                ]),
            ])
        } else {
            branchSnapshot = .object([
                "checkedOut": .bool(false),
                "headCommitSha": .string(branchHead),
            ])
        }
        return .object([
            "branch": .string(config.branch),
            "worktreeSnapshot": .object([
                "root": .string(root),
                "headCommitSha": .string(head),
            ]),
            "branchSnapshot": branchSnapshot,
            "localCommitsAhead": .integer(counts?.left ?? 0),
            "worktreeCommitsAhead": .integer(counts?.right ?? 0),
            "localUncommittedDiffStats": localDiffEnvelope,
            "worktreeUncommittedDiffStats": worktreeDiffEnvelope,
        ])
    }

    private func worktreeRoot(
        forBranch branch: String,
        porcelain: String
    ) -> String? {
        var root: String?
        for rawLine in porcelain.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            if line.hasPrefix("worktree ") {
                root = String(line.dropFirst("worktree ".count))
            } else if line == "branch refs/heads/\(branch)" {
                return root
            } else if line.isEmpty {
                root = nil
            }
        }
        return nil
    }

    private func syncedDiffStats(
        _ stats: [ReviewStat],
        leftRef: String,
        rightRef: String
    ) -> CodexJSONValue {
        .object([
            "leftRef": .string(leftRef),
            "rightRef": .string(rightRef),
            "filesChanged": .integer(Int64(stats.count)),
            "linesAdded": .integer(
                Int64(stats.reduce(0) { $0 + $1.additions })
            ),
            "linesRemoved": .integer(
                Int64(stats.reduce(0) { $0 + $1.deletions })
            ),
        ])
    }

    private func syncedBranchConfig(
        cwd: String
    ) async throws -> SyncedBranchConfig? {
        let gitDirResult = try await run(
            ["git", "-C", cwd, "rev-parse", "--absolute-git-dir"],
            cwd
        )
        guard gitDirResult.exitCode == 0 else {
            return nil
        }
        let url = URL(fileURLWithPath: trimmed(gitDirResult.stdout))
            .appendingPathComponent("codex-synced-branch.json")
        guard let data = try? Data(contentsOf: url),
              let config = try? JSONDecoder().decode(
                  SyncedBranchConfig.self,
                  from: data
              ),
              !config.branch.isEmpty,
              !config.lastSyncedTreeRef.isEmpty
        else {
            return nil
        }
        return config
    }

    private func shortBranchName(_ value: String) -> String {
        value.hasPrefix("refs/heads/")
            ? String(value.dropFirst("refs/heads/".count))
            : value
    }

    private func isGitObjectID(_ value: String) -> Bool {
        guard !value.isEmpty,
              value.count <= 64,
              !value.allSatisfy({ $0 == "0" })
        else {
            return false
        }
        return value.unicodeScalars.allSatisfy {
            CharacterSet(charactersIn: "0123456789abcdefABCDEF")
                .contains($0)
        }
    }

    private func notFoundObjectError() -> CodexJSONValue {
        .object([
            "type": .string("error"),
            "error": .object(["type": .string("not-found")]),
        ])
    }

    private func fileObjectResult(
        _ text: String,
        maxBytes: Int
    ) -> CodexJSONValue {
        fileObjectResult(Data(text.utf8), maxBytes: maxBytes)
    }

    private func fileObjectResult(
        _ data: Data,
        maxBytes: Int
    ) -> CodexJSONValue {
        guard data.count <= maxBytes else {
            return .object([
                "type": .string("error"),
                "error": .object([
                    "type": .string("too-large"),
                    "limitBytes": .integer(Int64(maxBytes)),
                ]),
            ])
        }
        let text = String(decoding: data, as: UTF8.self)
        var lines = text.components(separatedBy: .newlines)
        if text.hasSuffix("\n") {
            lines.removeLast()
        }
        return .object([
            "type": .string("success"),
            "lines": .array(lines.map(CodexJSONValue.string)),
        ])
    }
}
