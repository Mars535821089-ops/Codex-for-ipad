#if SWIFT_PACKAGE
    import CodexPadDomain
    import CodexPadProtocolBridge
#endif
import Foundation

@MainActor
public protocol CodexDesktopArchivedThreadDeleting:
    AnyObject
{
    func deleteArchivedStoredThread(
        threadID: CodexStoredThreadID
    ) throws -> [CodexStoredThreadID]

    func deleteAllArchivedStoredThreads()
        throws -> [CodexStoredThreadID]
}

@MainActor
public protocol CodexDesktopFileInteracting: AnyObject {
    func pickDesktopFiles(
        allowsMultipleSelection: Bool,
        imagesOnly: Bool,
        pickerTitle: String?
    ) async throws -> [URL]

    func releaseDesktopFiles(_ urls: [URL])

    func saveDesktopFile(
        suggestedFilename: String,
        contents: Data
    ) async throws -> URL?

    func addDesktopContextFile(
        path: String,
        origin: CodexJSONValue
    ) async throws
}

@MainActor
public protocol CodexDesktopManagedWorktreeInteracting:
    AnyObject
{
    func performManagedWorktreeRequest(
        workerMethod: String,
        params: CodexJSONValue
    ) async throws -> CodexJSONValue
}

@MainActor
public protocol CodexDesktopWorktreeSnapshotUploading:
    AnyObject
{
    func uploadWorktreeSnapshot(
        tarballPath: String,
        uploadURL: URL,
        contentLength: Int64,
        contentType: String
    ) async throws
}

public struct CodexDesktopGitCredential:
    Equatable, Sendable
{
    public let username: String
    public let password: String

    public init(username: String, password: String) {
        self.username = username
        self.password = password
    }
}

@MainActor
public protocol CodexDesktopGitCredentialProviding:
    AnyObject
{
    func gitCredential(
        forRepositoryAt path: String
    ) throws -> CodexDesktopGitCredential?
}

public struct CodexDesktopAppshotSnapshot:
    Equatable,
    Sendable
{
    public let screenshotDataURL: String
    public let height: Double

    public init(
        screenshotDataURL: String,
        height: Double
    ) {
        self.screenshotDataURL = screenshotDataURL
        self.height = height
    }
}

public protocol CodexDesktopAppshotCaptureStarting:
    Sendable
{
    func startCapture(
        requestID: String,
        bundleIdentifier: String
    ) async -> CodexJSONValue?
}

/// Owns the released desktop Appshot request lifecycle on iPad.
///
/// The renderer creates the request ID, the initial VS Code fetch registers
/// it here, and `appshot.requestFinalUpdate` can only act on that active ID.
/// This mirrors the official desktop registry rather than acknowledging a
/// final update for an unknown request.
public actor CodexDesktopAppshotCaptureCoordinator:
    CodexDesktopAppshotCaptureStarting
{
    public typealias SnapshotOperation =
        @MainActor @Sendable () async throws
            -> CodexDesktopAppshotSnapshot
    public typealias EventSink =
        @MainActor @Sendable (CodexDesktopHostMessage) async -> Void

    private enum Phase: Sendable {
        case awaitingFinalUpdate
        case finalizing
    }

    private let snapshotOperation: SnapshotOperation
    private let eventSink: EventSink
    private var requests: [String: Phase] = [:]

    public init(
        snapshotOperation: @escaping SnapshotOperation,
        eventSink: @escaping EventSink
    ) {
        self.snapshotOperation = snapshotOperation
        self.eventSink = eventSink
    }

    /// Returns the live capture capability/state shape consumed by the
    /// released renderer.  Unlike the desktop hotkey registry, iPad capture
    /// is driven by the web view snapshot coordinator itself.
    public func state() -> CodexJSONValue {
        .object([
            "supported": .bool(true),
            "configuredHotkey": .null,
            "isActive": .bool(!requests.isEmpty),
        ])
    }

    public func appHostState() -> CodexDesktopAppHostRPC.Value {
        .object([
            "supported": .bool(true),
            "configuredHotkey": .null,
            "isActive": .bool(!requests.isEmpty),
        ])
    }

    public func startCapture(
        requestID: String,
        bundleIdentifier: String
    ) async -> CodexJSONValue? {
        let requestID = requestID.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let bundleIdentifier = bundleIdentifier
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !requestID.isEmpty,
              !bundleIdentifier.isEmpty,
              requests[requestID] == nil
        else {
            return nil
        }

        requests[requestID] = .awaitingFinalUpdate
        do {
            let snapshot = try await snapshotOperation()
            guard snapshot.height > 0,
                  !snapshot.screenshotDataURL.isEmpty,
                  requests[requestID] != nil
            else {
                requests.removeValue(forKey: requestID)
                return nil
            }
            await emit(
                requestID: requestID,
                update: .object([
                    "type": .string("metadata"),
                    "app": .object([
                        "bundleIdentifier":
                            .string(bundleIdentifier)
                    ]),
                ])
            )
            await emit(
                requestID: requestID,
                update: .object([
                    "type": .string("screenshot"),
                    "screenshotDataURL":
                        .string(snapshot.screenshotDataURL),
                    "transitionSnapshotDataURL":
                        .string(snapshot.screenshotDataURL),
                ])
            )
            return .object([
                "result": .string("started"),
                "transitionSnapshotHeight":
                    .number(snapshot.height),
            ])
        } catch {
            guard requests.removeValue(forKey: requestID) != nil else {
                return nil
            }
            await emitFailure(
                requestID: requestID,
                reason: "start_request_failed"
            )
            return nil
        }
    }

    public func requestFinalUpdate(
        requestID: String
    ) async -> Bool {
        guard requests[requestID] == .awaitingFinalUpdate else {
            return false
        }
        requests[requestID] = .finalizing
        do {
            let snapshot = try await snapshotOperation()
            guard snapshot.height > 0,
                  !snapshot.screenshotDataURL.isEmpty,
                  requests[requestID] == .finalizing
            else {
                throw CancellationError()
            }
            await emit(
                requestID: requestID,
                update: .object([
                    "type": .string("screenshot"),
                    "screenshotDataURL":
                        .string(snapshot.screenshotDataURL),
                ])
            )
            await emit(
                requestID: requestID,
                update: .object([
                    "type": .string("completed")
                ])
            )
            requests.removeValue(forKey: requestID)
            return true
        } catch {
            guard requests.removeValue(forKey: requestID) != nil else {
                return false
            }
            await emitFailure(
                requestID: requestID,
                reason: "final_update_request_failed"
            )
            return false
        }
    }

    public func cancel(requestID: String) {
        requests.removeValue(forKey: requestID)
    }

    public func contains(_ requestID: String) -> Bool {
        requests[requestID] != nil
    }

    private func emitFailure(
        requestID: String,
        reason: String
    ) async {
        await emit(
            requestID: requestID,
            update: .object([
                "type": .string("failed"),
                "failureReason": .string(reason),
            ])
        )
    }

    private func emit(
        requestID: String,
        update: CodexJSONValue
    ) async {
        await eventSink(
            .event(
                type: "computer-use-capture-updated",
                payload: .object([
                    "requestId": .string(requestID),
                    "update": update,
                ])
            )
        )
    }
}

/// Async VS Code host methods that cross actor or real execution boundaries.
///
/// Returning `nil` means the method is not owned here and lets the synchronous
/// released-surface router handle it.
public enum CodexDesktopAsyncFetchRouter {
    private static let responseHeaders = [
        "content-type": "application/json"
    ]

    @MainActor
    public static func response(
        to request: CodexDesktopFetchRequest,
        state: CodexDesktopInitialHostState,
        automationScheduler:
            CodexDesktopAutomationScheduler? = nil,
        embeddedGitRequester:
            (any CodexDesktopEmbeddedGitRequesting)? = nil,
        archivedThreadStore:
            (any CodexDesktopArchivedThreadDeleting)? = nil,
        fileInteractor:
            (any CodexDesktopFileInteracting)? = nil,
        managedWorktreeInteractor:
            (any CodexDesktopManagedWorktreeInteracting)? =
                nil,
        worktreeSnapshotUploader:
            (any CodexDesktopWorktreeSnapshotUploading)? =
                nil,
        gitCredentialProvider:
            (any CodexDesktopGitCredentialProviding)? = nil,
        appshotCaptureStarter:
            (any CodexDesktopAppshotCaptureStarting)? = nil,
        homeDirectory: String = NSHomeDirectory(),
        now: Date = Date()
    ) async -> CodexDesktopHostMessage? {
        switch request.hostMethod {
        case "computer-use-start-capture":
            guard request.method == "POST" else {
                return unsupportedHTTPMethod(request)
            }
            guard let body = objectBody(request),
                  case let .object(params)? = body["params"],
                  case let .string(bundleIdentifier)? =
                    params["bundleIdentifier"],
                  !bundleIdentifier.isEmpty,
                  case let .string(requestID)? = params["requestId"],
                  !requestID.isEmpty
            else {
                return invalidBody(request)
            }
            guard let appshotCaptureStarter else {
                return failure(
                    request,
                    message: "Appshot capture is unavailable",
                    code: "appshot_capture_unavailable"
                )
            }
            let result = await appshotCaptureStarter.startCapture(
                requestID: requestID,
                bundleIdentifier: bundleIdentifier
            )
            return success(request, body: result ?? .null)

        case "automation-run-now":
            guard request.method == "POST" else {
                return failure(
                    request,
                    message:
                        "Unsupported VS Code bridge HTTP method: \(request.method)",
                    code: "unsupported_http_method"
                )
            }
            guard let body = objectBody(request),
                  case let .string(automationID)? = body["id"],
                  !automationID.isEmpty,
                  let collaborationMode =
                    decodeOptionalCollaborationMode(
                        body["collaborationMode"]
                    ),
                  let permissions =
                    decodeOptionalString(
                        body["permissions"]
                    )
            else {
                return invalidBody(request)
            }
            guard let automationScheduler else {
                return failure(
                    request,
                    message: "Automation scheduler is unavailable",
                    code: "store_unavailable"
                )
            }
            do {
                try await automationScheduler.runNow(
                    automationID: automationID,
                    collaborationMode:
                        collaborationMode.value,
                    permissions: permissions.value,
                    at: now
                )
                return success(
                    request,
                    body: .object([
                        "success": .bool(true)
                    ])
                )
            } catch {
                return failure(
                    request,
                    message: String(describing: error),
                    code: automationErrorCode(error)
                )
            }

        case "git-origins":
            guard request.method == "POST" else {
                return failure(
                    request,
                    message:
                        "Unsupported VS Code bridge HTTP method: \(request.method)",
                    code: "unsupported_http_method"
                )
            }
            guard let body = objectBody(request),
                  case let .string(hostID)? = body["hostId"],
                  !hostID.isEmpty,
                  let explicitDirectories =
                    decodeOptionalStringArray(body["dirs"])
            else {
                return invalidBody(request)
            }
            guard let embeddedGitRequester else {
                return failure(
                    request,
                    message: "Embedded Git reader is unavailable",
                    code: "git_worker_unavailable"
                )
            }
            let directories: [String]
            if let explicit = explicitDirectories.value,
               !explicit.isEmpty
            {
                directories = uniquePaths(explicit)
            } else {
                directories = uniquePaths(
                    state.activeWorkspaceRoots.filter {
                        $0 != "~"
                    }
                )
            }
            do {
                let result =
                    try await embeddedGitRequester
                        .embeddedGitRead(
                            method: "git-origins",
                            params: .object([
                                "dirs": .array(
                                    directories.map(
                                        CodexJSONValue.string
                                    )
                                )
                            ])
                        )
                guard case var .object(fields) = result,
                      case .array? = fields["origins"]
                else {
                    return failure(
                        request,
                        message:
                            "Embedded Git returned an invalid git-origins response",
                        code: "invalid_git_worker_response"
                    )
                }
                fields["homeDir"] = .string(homeDirectory)
                return success(
                    request,
                    body: .object(fields)
                )
            } catch {
                return failure(
                    request,
                    message: String(describing: error),
                    code: "git_origins_failed"
                )
            }

        case "git-create-branch":
            guard request.method == "POST" else {
                return unsupportedHTTPMethod(request)
            }
            guard let body = objectBody(request),
                  validHostID(body),
                  case let .string(cwd)? = body["cwd"],
                  !cwd.isEmpty,
                  case let .string(branch)? = body["branch"],
                  !branch.isEmpty,
                  let failIfExists =
                    decodeOptionalBool(body["failIfExists"]),
                  let mode =
                    decodeOptionalString(body["mode"])
            else {
                return invalidBody(request)
            }
            var params: [String: CodexJSONValue] = [
                "cwd": .string(cwd),
                "branch": .string(branch),
            ]
            if let value = failIfExists.value {
                params["failIfExists"] = .bool(value)
            }
            if let value = mode.value {
                params["mode"] = .string(value)
            }
            return await embeddedGitResponse(
                request,
                requester: embeddedGitRequester,
                workerMethod: "git-create-branch",
                params: params,
                requiredResultField: "status"
            )

        case "git-push":
            guard request.method == "POST" else {
                return unsupportedHTTPMethod(request)
            }
            guard let body = objectBody(request),
                  validHostID(body),
                  case let .string(cwd)? = body["cwd"],
                  !cwd.isEmpty,
                  let refspec = decodeOptionalString(
                      body["refspec"]
                  ),
                  let force = decodeOptionalBool(body["force"]),
                  let setUpstream =
                    decodeOptionalBool(body["setUpstream"])
            else {
                return invalidBody(request)
            }
            var params: [String: CodexJSONValue] = [
                "cwd": .string(cwd)
            ]
            if let value = refspec.value {
                params["refspec"] = .string(value)
            }
            if let value = force.value {
                params["force"] = .bool(value)
            }
            if let value = setUpstream.value {
                params["setUpstream"] = .bool(value)
            }
            do {
                if let credential = try gitCredentialProvider?
                    .gitCredential(forRepositoryAt: cwd)
                {
                    params["username"] = .string(
                        credential.username
                    )
                    params["password"] = .string(
                        credential.password
                    )
                }
            } catch {
                return failure(
                    request,
                    message:
                        "Git credential lookup failed",
                    code: "git_credential_failed"
                )
            }
            return await embeddedGitResponse(
                request,
                requester: embeddedGitRequester,
                workerMethod: "git-push",
                params: params,
                requiredResultField: "status"
            )

        case "git-checkout-branch":
            guard request.method == "POST" else {
                return unsupportedHTTPMethod(request)
            }
            guard let body = objectBody(request),
                  validHostID(body),
                  case let .string(cwd)? = body["cwd"],
                  !cwd.isEmpty,
                  case let .string(branch)? = body["branch"],
                  !branch.isEmpty
            else {
                return invalidBody(request)
            }
            return await embeddedGitResponse(
                request,
                requester: embeddedGitRequester,
                workerMethod: "git-checkout-branch",
                params: [
                    "cwd": .string(cwd),
                    "branch": .string(branch),
                ],
                requiredResultField: "status"
            )

        case "git-merge-base":
            guard request.method == "POST" else {
                return unsupportedHTTPMethod(request)
            }
            guard let body = objectBody(request),
                  validHostID(body),
                  case let .string(gitRoot)? = body["gitRoot"],
                  !gitRoot.isEmpty,
                  case let .string(baseBranch)? = body["baseBranch"],
                  !baseBranch.isEmpty
            else {
                return invalidBody(request)
            }
            return await embeddedGitResponse(
                request,
                requester: embeddedGitRequester,
                workerMethod: "git-merge-base",
                params: [
                    "gitRoot": .string(gitRoot),
                    "baseBranch": .string(baseBranch),
                ],
                requiredResultField: "mergeBaseSha"
            )

        case "worktree-shell-environment-config":
            guard request.method == "POST" else {
                return unsupportedHTTPMethod(request)
            }
            guard let body = objectBody(request),
                  validHostID(body),
                  case let .string(cwd)? = body["cwd"],
                  !cwd.isEmpty
            else {
                return invalidBody(request)
            }
            return await embeddedGitResponse(
                request,
                requester: embeddedGitRequester,
                workerMethod:
                    "worktree-shell-environment-config",
                params: ["cwd": .string(cwd)],
                requiredResultField: "shellEnvironment"
            )

        case "pick-file":
            guard request.method == "POST" else {
                return unsupportedHTTPMethod(request)
            }
            guard let body = objectBody(request),
                  let pickerTitle =
                    decodeOptionalString(body["pickerTitle"])
            else {
                return invalidBody(request)
            }
            guard let fileInteractor else {
                return fileInteractionUnavailable(request)
            }
            do {
                let urls = try await fileInteractor
                    .pickDesktopFiles(
                        allowsMultipleSelection: false,
                        imagesOnly: false,
                        pickerTitle: pickerTitle.value
                    )
                let file = try urls.first.map(fileValue(for:))
                    ?? .null
                return success(
                    request,
                    body: .object(["file": file])
                )
            } catch {
                return fileInteractionFailure(
                    request,
                    operation: "pick_file",
                    error: error
                )
            }

        case "pick-files":
            guard request.method == "POST" else {
                return unsupportedHTTPMethod(request)
            }
            guard let body = objectBody(request),
                  case let .bool(imagesOnly)? =
                    body["imagesOnly"],
                  let pickerTitle =
                    decodeOptionalString(body["pickerTitle"])
            else {
                return invalidBody(request)
            }
            guard let fileInteractor else {
                return fileInteractionUnavailable(request)
            }
            do {
                let urls = try await fileInteractor
                    .pickDesktopFiles(
                        allowsMultipleSelection: true,
                        imagesOnly: imagesOnly,
                        pickerTitle: pickerTitle.value
                    )
                let files = try urls.map(fileValue(for:))
                return success(
                    request,
                    body: .object([
                        "files": .array(files)
                    ])
                )
            } catch {
                return fileInteractionFailure(
                    request,
                    operation: "pick_files",
                    error: error
                )
            }

        case "save-file":
            guard request.method == "POST" else {
                return unsupportedHTTPMethod(request)
            }
            guard let body = objectBody(request),
                  case let .string(suggestedFilename)? =
                    body["suggestedFilename"],
                  !suggestedFilename.isEmpty,
                  case let .string(kind)? = body["kind"]
            else {
                return invalidBody(request)
            }
            guard let fileInteractor else {
                return fileInteractionUnavailable(request)
            }
            let contents: Data
            if kind == "contents" {
                guard case let .string(contentsBase64)? =
                    body["contentsBase64"],
                    let decoded = Data(
                        base64Encoded: contentsBase64
                    )
                else {
                    return invalidBody(request)
                }
                contents = decoded
            } else {
                guard validHostID(body),
                      case let .string(sourcePath)? =
                        body["sourcePath"],
                      !sourcePath.isEmpty
                else {
                    return invalidBody(request)
                }
                do {
                    contents = try Data(
                        contentsOf: URL(
                            fileURLWithPath: sourcePath
                        )
                    )
                } catch {
                    return fileInteractionFailure(
                        request,
                        operation: "read_source_file",
                        error: error
                    )
                }
            }
            do {
                let destination = try await fileInteractor
                    .saveDesktopFile(
                        suggestedFilename:
                            suggestedFilename,
                        contents: contents
                    )
                return success(
                    request,
                    body: .object([
                        "path": destination.map {
                            .string(
                                $0.standardizedFileURL.path
                            )
                        } ?? .null
                    ])
                )
            } catch {
                return fileInteractionFailure(
                    request,
                    operation: "save_file",
                    error: error
                )
            }

        case "add-context-file":
            guard request.method == "POST" else {
                return unsupportedHTTPMethod(request)
            }
            guard let body = objectBody(request),
                  validHostID(body),
                  case let .string(path)? = body["path"],
                  !path.isEmpty,
                  let origin = body["origin"],
                  origin != .null
            else {
                return invalidBody(request)
            }
            guard let fileInteractor else {
                return fileInteractionUnavailable(request)
            }
            do {
                try await fileInteractor.addDesktopContextFile(
                    path: path,
                    origin: origin
                )
                return success(
                    request,
                    body: .object(["success": .bool(true)])
                )
            } catch {
                return fileInteractionFailure(
                    request,
                    operation: "add_context_file",
                    error: error
                )
            }

        case "worktree-create-managed":
            guard request.method == "POST" else {
                return unsupportedHTTPMethod(request)
            }
            guard let body = objectBody(request),
                  validHostID(body),
                  case let .string(cwd)? = body["cwd"],
                  !cwd.isEmpty,
                  case .object? = body["startingState"],
                  let localEnvironmentConfigPath =
                    decodeOptionalString(
                        body["localEnvironmentConfigPath"]
                    ),
                  case let .string(streamID)? =
                    body["streamId"],
                  !streamID.isEmpty
            else {
                return invalidBody(request)
            }
            var params = body
            params["worktreesRoot"] = .string(
                state.worktreesSegment
            )
            params["localEnvironmentConfigPath"] =
                localEnvironmentConfigPath.value.map(
                    CodexJSONValue.string
                ) ?? .null
            return await managedWorktreeResponse(
                request,
                interactor: managedWorktreeInteractor,
                workerMethod: "create-worktree",
                params: params,
                requiredResultFields: [
                    "worktreeGitRoot",
                    "worktreeWorkspaceRoot",
                    "setupError",
                ]
            )

        case "worktree-delete":
            guard request.method == "POST" else {
                return unsupportedHTTPMethod(request)
            }
            guard let body = objectBody(request),
                  validHostID(body),
                  case let .string(worktree)? =
                    body["worktree"],
                  !worktree.isEmpty,
                  case let .string(reason)? = body["reason"],
                  !reason.isEmpty
            else {
                return invalidBody(request)
            }
            var params = body
            params["force"] = .bool(true)
            let result = await managedWorktreeResponse(
                request,
                interactor: managedWorktreeInteractor,
                workerMethod: "delete-worktree",
                params: params,
                requiredResultFields: ["success"]
            )
            guard case .fetchSuccess = result else {
                return result
            }
            return success(request, body: .null)

        case "worktree-set-owner-thread":
            guard request.method == "POST" else {
                return unsupportedHTTPMethod(request)
            }
            guard let body = objectBody(request),
                  validHostID(body),
                  case let .string(worktree)? =
                    body["worktree"],
                  !worktree.isEmpty,
                  case let .string(conversationID)? =
                    body["conversationId"],
                  !conversationID.isEmpty
            else {
                return invalidBody(request)
            }
            let result = await managedWorktreeResponse(
                request,
                interactor: managedWorktreeInteractor,
                workerMethod: "set-worktree-owner-thread",
                params: body,
                requiredResultFields: ["success"]
            )
            guard case .fetchSuccess = result else {
                return result
            }
            return success(request, body: .null)

        case "prepare-worktree-snapshot":
            guard request.method == "POST" else {
                return unsupportedHTTPMethod(request)
            }
            guard let body = objectBody(request),
                  case let .string(gitRoot)? = body["gitRoot"],
                  !gitRoot.isEmpty,
                  let snapshotBranch =
                    decodeOptionalString(body["snapshotBranch"])
            else {
                return invalidBody(request)
            }
            return await embeddedGitResponse(
                request,
                requester: embeddedGitRequester,
                workerMethod: "prepare-worktree-snapshot",
                params: [
                    "gitRoot": .string(gitRoot),
                    "snapshotBranch":
                        snapshotBranch.value.map(
                            CodexJSONValue.string
                        ) ?? .null,
                ],
                requiredResultField: "tarballPath"
            )

        case "upload-worktree-snapshot":
            guard request.method == "POST" else {
                return unsupportedHTTPMethod(request)
            }
            guard let body = objectBody(request),
                  case let .string(tarballPath)? =
                    body["tarballPath"],
                  !tarballPath.isEmpty,
                  case let .string(uploadURLString)? =
                    body["uploadUrl"],
                  let uploadURL = URL(
                    string: uploadURLString
                  ),
                  uploadURL.scheme == "https",
                  case let .integer(contentLength)? =
                    body["contentLength"],
                  contentLength >= 0,
                  case let .string(contentType)? =
                    body["contentType"],
                  !contentType.isEmpty
            else {
                return invalidBody(request)
            }
            guard let worktreeSnapshotUploader else {
                return success(
                    request,
                    body: .object(["success": .bool(false)])
                )
            }
            do {
                try await worktreeSnapshotUploader
                    .uploadWorktreeSnapshot(
                        tarballPath: tarballPath,
                        uploadURL: uploadURL,
                        contentLength: contentLength,
                        contentType: contentType
                    )
                return success(
                    request,
                    body: .object(["success": .bool(true)])
                )
            } catch {
                return success(
                    request,
                    body: .object(["success": .bool(false)])
                )
            }

        case "delete-archived-thread":
            guard request.method == "POST" else {
                return unsupportedHTTPMethod(request)
            }
            guard let body = objectBody(request),
                  validHostID(body),
                  case let .string(threadID)? = body["threadId"],
                  !threadID.isEmpty
            else {
                return invalidBody(request)
            }
            guard let archivedThreadStore else {
                return failure(
                    request,
                    message:
                        "Archived thread store is unavailable",
                    code: "store_unavailable"
                )
            }
            do {
                let deleted = try archivedThreadStore
                    .deleteArchivedStoredThread(
                        threadID: CodexStoredThreadID(threadID)
                    )
                return success(
                    request,
                    body: .object([
                        "deletedThreadIds": .array(
                            deleted.map {
                                .string($0.rawValue)
                            }
                        )
                    ])
                )
            } catch {
                return failure(
                    request,
                    message: String(describing: error),
                    code: "delete_archived_thread_failed"
                )
            }

        case "delete-all-archived-threads":
            guard request.method == "POST" else {
                return unsupportedHTTPMethod(request)
            }
            guard let body = objectBody(request),
                  validHostID(body)
            else {
                return invalidBody(request)
            }
            guard let archivedThreadStore else {
                return failure(
                    request,
                    message:
                        "Archived thread store is unavailable",
                    code: "store_unavailable"
                )
            }
            do {
                let deleted = try archivedThreadStore
                    .deleteAllArchivedStoredThreads()
                return success(
                    request,
                    body: .object([
                        "deletedThreadIds": .array(
                            deleted.map {
                                .string($0.rawValue)
                            }
                        )
                    ])
                )
            } catch {
                return failure(
                    request,
                    message: String(describing: error),
                    code: "delete_archived_threads_failed"
                )
            }

        default:
            return nil
        }
    }

    private struct OptionalValue<Value> {
        let value: Value?
    }

    private static func decodeOptionalString(
        _ value: CodexJSONValue?
    ) -> OptionalValue<String>? {
        switch value {
        case nil, .null?:
            return OptionalValue(value: nil)
        case let .string(string)?:
            return OptionalValue(value: string)
        default:
            return nil
        }
    }

    private static func decodeOptionalBool(
        _ value: CodexJSONValue?
    ) -> OptionalValue<Bool>? {
        switch value {
        case nil, .null?:
            return OptionalValue(value: nil)
        case let .bool(value)?:
            return OptionalValue(value: value)
        default:
            return nil
        }
    }

    private static func decodeOptionalStringArray(
        _ value: CodexJSONValue?
    ) -> OptionalValue<[String]>? {
        switch value {
        case nil, .null?:
            return OptionalValue(value: nil)
        case let .array(values)?:
            var strings: [String] = []
            for value in values {
                guard case let .string(string) = value,
                      !string.isEmpty
                else {
                    return nil
                }
                strings.append(string)
            }
            return OptionalValue(value: strings)
        default:
            return nil
        }
    }

    private static func decodeOptionalCollaborationMode(
        _ value: CodexJSONValue?
    ) -> OptionalValue<CodexCollaborationMode>? {
        switch value {
        case nil, .null?:
            return OptionalValue(value: nil)
        case let value?:
            do {
                let encoded = try JSONEncoder().encode(value)
                return OptionalValue(
                    value: try JSONDecoder().decode(
                        CodexCollaborationMode.self,
                        from: encoded
                    )
                )
            } catch {
                return nil
            }
        }
    }

    private static func uniquePaths(
        _ paths: [String]
    ) -> [String] {
        var seen = Set<String>()
        return paths.compactMap { path in
            let canonical = URL(
                fileURLWithPath:
                    (path as NSString).expandingTildeInPath
            ).standardizedFileURL.path
            guard seen.insert(canonical).inserted else {
                return nil
            }
            return canonical
        }
    }

    private static func fileValue(
        for url: URL
    ) throws -> CodexJSONValue {
        let standardized = url.standardizedFileURL
        let resourceValues = try standardized.resourceValues(
            forKeys: [.isDirectoryKey]
        )
        let fsPath = standardized.path
        let path: String
        if resourceValues.isDirectory == true,
           !fsPath.hasSuffix("/")
        {
            path = fsPath + "/"
        } else {
            path = fsPath
        }
        return .object([
            "label": .string(standardized.lastPathComponent),
            "path": .string(path),
            "fsPath": .string(fsPath),
        ])
    }

    private static func objectBody(
        _ request: CodexDesktopFetchRequest
    ) -> [String: CodexJSONValue]? {
        guard let body = request.body,
              let data = body.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(
                  CodexJSONValue.self,
                  from: data
              ),
              case let .object(object) = decoded
        else {
            return nil
        }
        return object
    }

    private static func validHostID(
        _ body: [String: CodexJSONValue]
    ) -> Bool {
        guard case let .string(hostID)? = body["hostId"] else {
            return false
        }
        return !hostID.isEmpty
    }

    @MainActor
    private static func embeddedGitResponse(
        _ request: CodexDesktopFetchRequest,
        requester:
            (any CodexDesktopEmbeddedGitRequesting)?,
        workerMethod: String,
        params: [String: CodexJSONValue],
        requiredResultField: String
    ) async -> CodexDesktopHostMessage {
        guard let requester else {
            return failure(
                request,
                message: "Embedded Git reader is unavailable",
                code: "git_worker_unavailable"
            )
        }
        do {
            let result = try await requester.embeddedGitRead(
                method: workerMethod,
                params: .object(params)
            )
            guard case let .object(fields) = result,
                  fields.keys.contains(requiredResultField)
            else {
                return failure(
                    request,
                    message:
                        "Embedded Git returned an invalid \(workerMethod) response",
                    code: "invalid_git_worker_response"
                )
            }
            return success(request, body: result)
        } catch {
            return failure(
                request,
                message: String(describing: error),
                code: "\(workerMethod.replacingOccurrences(of: "-", with: "_"))_failed"
            )
        }
    }

    @MainActor
    private static func managedWorktreeResponse(
        _ request: CodexDesktopFetchRequest,
        interactor:
            (any CodexDesktopManagedWorktreeInteracting)?,
        workerMethod: String,
        params: [String: CodexJSONValue],
        requiredResultFields: Set<String>
    ) async -> CodexDesktopHostMessage {
        guard let interactor else {
            return failure(
                request,
                message:
                    "Managed worktree service is unavailable",
                code: "worktree_service_unavailable"
            )
        }
        do {
            let result =
                try await interactor
                    .performManagedWorktreeRequest(
                        workerMethod: workerMethod,
                        params: .object(params)
                    )
            guard case let .object(fields) = result,
                  requiredResultFields.isSubset(
                    of: Set(fields.keys)
                  )
            else {
                return failure(
                    request,
                    message:
                        "Managed worktree service returned an invalid \(workerMethod) response",
                    code: "invalid_worktree_response"
                )
            }
            return success(request, body: result)
        } catch {
            return failure(
                request,
                message: String(describing: error),
                code:
                    "\(workerMethod.replacingOccurrences(of: "-", with: "_"))_failed"
            )
        }
    }

    private static func success(
        _ request: CodexDesktopFetchRequest,
        body: CodexJSONValue
    ) -> CodexDesktopHostMessage {
        .fetchSuccess(
            requestID: request.requestID,
            status: 200,
            headers: responseHeaders,
            body: body
        )
    }

    private static func invalidBody(
        _ request: CodexDesktopFetchRequest
    ) -> CodexDesktopHostMessage {
        failure(
            request,
            message:
                "Invalid VS Code bridge request body: \(request.hostMethod)",
            code: "invalid_request_body"
        )
    }

    private static func unsupportedHTTPMethod(
        _ request: CodexDesktopFetchRequest
    ) -> CodexDesktopHostMessage {
        failure(
            request,
            message:
                "Unsupported VS Code bridge HTTP method: \(request.method)",
            code: "unsupported_http_method"
        )
    }

    private static func fileInteractionUnavailable(
        _ request: CodexDesktopFetchRequest
    ) -> CodexDesktopHostMessage {
        failure(
            request,
            message: "Desktop file interaction is unavailable",
            code: "file_interaction_unavailable"
        )
    }

    private static func fileInteractionFailure(
        _ request: CodexDesktopFetchRequest,
        operation: String,
        error: any Error
    ) -> CodexDesktopHostMessage {
        failure(
            request,
            message: String(describing: error),
            code: "\(operation)_failed"
        )
    }

    private static func automationErrorCode(
        _ error: any Error
    ) -> String {
        guard let error =
            error as? CodexDesktopAutomationStoreError
        else {
            return "automation_run_failed"
        }
        switch error {
        case .invalidRequest:
            return "invalid_request_body"
        case .automationNotFound:
            return "automation_not_found"
        case .scheduleHasNoFutureRun:
            return "schedule_has_no_future_run"
        case .storeUnavailable:
            return "store_unavailable"
        }
    }

    private static func failure(
        _ request: CodexDesktopFetchRequest,
        message: String,
        code: String
    ) -> CodexDesktopHostMessage {
        .fetchFailure(
            requestID: request.requestID,
            status: 432,
            error: message,
            errorCode: code
        )
    }
}
