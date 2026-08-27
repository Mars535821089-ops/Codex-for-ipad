import CodexPadDomain
import CodexPadProtocolBridge
import Foundation
import Testing

@testable import CodexPadApplication

private actor AsyncFetchEmbeddedGitProbe:
    CodexDesktopEmbeddedGitRequesting
{
    private var calls:
        [(method: String, params: CodexJSONValue)] = []

    func embeddedGitRead(
        method: String,
        params: CodexJSONValue
    ) async throws -> CodexJSONValue {
        calls.append((method, params))
        switch method {
        case "git-push":
            return .object([
                "status": .string("success"),
                "execOutput": .string("To https://example.invalid/repo.git"),
            ])
        case "git-create-branch":
            return .object([
                "status": .string("success"),
                "branch": .string("feature/ipad"),
            ])
        case "git-checkout-branch":
            return .object([
                "status": .string("success"),
                "branch": .string("feature/ipad"),
            ])
        case "git-merge-base":
            return .object([
                "mergeBaseSha": .string(
                    "0123456789012345678901234567890123456789"
                )
            ])
        case "worktree-shell-environment-config":
            return .object([
                "shellEnvironment": .object([
                    "version": .integer(1),
                    "set": .object([
                        "CODEX_ENV": .string("ipad")
                    ]),
                    "exclude": .array([
                        .string("TOKEN")
                    ]),
                ])
            ])
        case "prepare-worktree-snapshot":
            return .object([
                "repoName": .string("CodexPad"),
                "tarballFilename": .string(
                    "CodexPad-snapshot.tar.gz"
                ),
                "tarballSize": .integer(4096),
                "tarballPath": .string(
                    "/tmp/CodexPad-snapshot.tar.gz"
                ),
                "contentType": .string("application/gzip"),
                "remotes": .object([
                    "origin": .string(
                        "https://example.invalid/CodexPad.git"
                    )
                ]),
                "commitSha": .string(
                    "0123456789012345678901234567890123456789"
                ),
                "snapshotBranch": .string("feature/ipad"),
            ])
        default:
            break
        }
        return .object([
            "origins": .array([
                .object([
                    "dir": .string("/workspace/repo"),
                    "root": .string("/workspace/repo"),
                    "originUrl": .string(
                        "https://example.invalid/repo.git"
                    ),
                    "commonDir": .string(
                        "/workspace/repo/.git"
                    ),
                ])
            ])
        ])
    }

    func recordedCalls()
        -> [(method: String, params: CodexJSONValue)]
    {
        calls
    }
}

@MainActor
private final class AsyncFetchGitCredentialProbe:
    CodexDesktopGitCredentialProviding
{
    private(set) var requestedPaths: [String] = []

    func gitCredential(
        forRepositoryAt path: String
    ) throws -> CodexDesktopGitCredential? {
        requestedPaths.append(path)
        return .init(
            username: "git-user",
            password: "test-token"
        )
    }
}

@MainActor
private final class AsyncFetchArchivedThreadProbe:
    CodexDesktopArchivedThreadDeleting
{
    private(set) var deletedIDs: [CodexStoredThreadID] = []
    private(set) var deleteAllCalls = 0

    func deleteArchivedStoredThread(
        threadID: CodexStoredThreadID
    ) throws -> [CodexStoredThreadID] {
        deletedIDs.append(threadID)
        return [threadID]
    }

    func deleteAllArchivedStoredThreads()
        throws -> [CodexStoredThreadID]
    {
        deleteAllCalls += 1
        return [
            CodexStoredThreadID("archived-1"),
            CodexStoredThreadID("archived-2"),
        ]
    }
}

@MainActor
private final class AsyncFetchFileInteractionProbe:
    CodexDesktopFileInteracting
{
    struct PickCall: Equatable {
        let allowsMultipleSelection: Bool
        let imagesOnly: Bool
        let pickerTitle: String?
    }

    struct SaveCall: Equatable {
        let suggestedFilename: String
        let contents: Data
    }

    struct ContextCall: Equatable {
        let path: String
        let origin: CodexJSONValue
    }

    var pickedURLs: [URL] = []
    var savedURL: URL?
    private(set) var pickCalls: [PickCall] = []
    private(set) var releasedURLBatches: [[URL]] = []
    private(set) var saveCalls: [SaveCall] = []
    private(set) var contextCalls: [ContextCall] = []

    func pickDesktopFiles(
        allowsMultipleSelection: Bool,
        imagesOnly: Bool,
        pickerTitle: String?
    ) async throws -> [URL] {
        pickCalls.append(
            PickCall(
                allowsMultipleSelection:
                    allowsMultipleSelection,
                imagesOnly: imagesOnly,
                pickerTitle: pickerTitle
            )
        )
        return pickedURLs
    }

    func releaseDesktopFiles(_ urls: [URL]) {
        releasedURLBatches.append(urls)
    }

    func saveDesktopFile(
        suggestedFilename: String,
        contents: Data
    ) async throws -> URL? {
        saveCalls.append(
            SaveCall(
                suggestedFilename: suggestedFilename,
                contents: contents
            )
        )
        return savedURL
    }

    func addDesktopContextFile(
        path: String,
        origin: CodexJSONValue
    ) async throws {
        contextCalls.append(
            ContextCall(path: path, origin: origin)
        )
    }
}

@MainActor
private final class AsyncFetchManagedWorktreeProbe:
    CodexDesktopManagedWorktreeInteracting
{
    struct Call: Equatable {
        let workerMethod: String
        let params: CodexJSONValue
    }

    private(set) var calls: [Call] = []

    func performManagedWorktreeRequest(
        workerMethod: String,
        params: CodexJSONValue
    ) async throws -> CodexJSONValue {
        calls.append(
            Call(
                workerMethod: workerMethod,
                params: params
            )
        )
        switch workerMethod {
        case "create-worktree":
            return .object([
                "worktreeGitRoot":
                    .string("/worktrees/project/12345678"),
                "worktreeWorkspaceRoot":
                    .string("/worktrees/project/12345678"),
                "setupError": .null,
            ])
        case "delete-worktree":
            return .object([
                "success": .bool(true),
                "worktreeId": .string("12345678"),
            ])
        case "set-worktree-owner-thread":
            return .object([
                "success": .bool(true)
            ])
        default:
            return .object([:])
        }
    }
}

@MainActor
private final class AsyncFetchSnapshotUploadProbe:
    CodexDesktopWorktreeSnapshotUploading
{
    struct Call: Equatable {
        let tarballPath: String
        let uploadURL: URL
        let contentLength: Int64
        let contentType: String
    }

    private(set) var calls: [Call] = []
    var error: (any Error)?

    func uploadWorktreeSnapshot(
        tarballPath: String,
        uploadURL: URL,
        contentLength: Int64,
        contentType: String
    ) async throws {
        if let error {
            throw error
        }
        calls.append(
            Call(
                tarballPath: tarballPath,
                uploadURL: uploadURL,
                contentLength: contentLength,
                contentType: contentType
            )
        )
    }
}

private func asyncFetchRequest(
    _ hostMethod: String,
    requestID: String,
    body: String
) -> CodexDesktopFetchRequest {
    CodexDesktopFetchRequest(
        requestID: requestID,
        method: "POST",
        url: "vscode://codex/\(hostMethod)",
        hostMethod: hostMethod,
        headers: nil,
        body: body,
        reportUploadProgress: false
    )
}

private enum AsyncFetchAppshotProbeError: Error {
    case snapshotFailed
}

private actor AsyncFetchAppshotSnapshotProbe {
    private var snapshots: [CodexDesktopAppshotSnapshot?]
    private var calls = 0
    private let delayNanoseconds: UInt64

    init(
        snapshots: [CodexDesktopAppshotSnapshot?],
        delayNanoseconds: UInt64 = 0
    ) {
        self.snapshots = snapshots
        self.delayNanoseconds = delayNanoseconds
    }

    func takeSnapshot() async throws
        -> CodexDesktopAppshotSnapshot
    {
        calls += 1
        if delayNanoseconds > 0, calls > 1 {
            try await Task.sleep(
                nanoseconds: delayNanoseconds
            )
        }
        guard !snapshots.isEmpty,
              let snapshot = snapshots.removeFirst()
        else {
            throw AsyncFetchAppshotProbeError.snapshotFailed
        }
        return snapshot
    }

    func callCount() -> Int {
        calls
    }
}

private actor AsyncFetchAppshotEventProbe {
    private var messages: [CodexDesktopHostMessage] = []

    func append(_ message: CodexDesktopHostMessage) {
        messages.append(message)
    }

    func recordedMessages() -> [CodexDesktopHostMessage] {
        messages
    }
}

private func appshotSnapshot(
    _ value: String,
    height: Double = 900
) -> CodexDesktopAppshotSnapshot {
    CodexDesktopAppshotSnapshot(
        screenshotDataURL: "data:image/png;base64,\(value)",
        height: height
    )
}

@Test
func desktopAppshotCoordinatorRejectsInvalidAndDuplicateRequests()
    async
{
    let snapshots = AsyncFetchAppshotSnapshotProbe(
        snapshots: [appshotSnapshot("initial")]
    )
    let events = AsyncFetchAppshotEventProbe()
    let coordinator = CodexDesktopAppshotCaptureCoordinator(
        snapshotOperation: {
            try await snapshots.takeSnapshot()
        },
        eventSink: { message in
            await events.append(message)
        }
    )

    #expect(
        await coordinator.startCapture(
            requestID: " ",
            bundleIdentifier: "com.openai.codex"
        ) == nil
    )
    let started = await coordinator.startCapture(
        requestID: "capture-1",
        bundleIdentifier: "com.openai.codex"
    )
    #expect(
        started == .object([
            "result": .string("started"),
            "transitionSnapshotHeight": .number(900),
        ])
    )
    #expect(
        await coordinator.startCapture(
            requestID: "capture-1",
            bundleIdentifier: "com.openai.codex"
        ) == nil
    )
    #expect(await snapshots.callCount() == 1)
    #expect(await coordinator.contains("capture-1"))
}

@Test
func desktopAppshotCoordinatorCompletesFinalSnapshotAndCleansUp()
    async
{
    let snapshots = AsyncFetchAppshotSnapshotProbe(
        snapshots: [
            appshotSnapshot("initial", height: 800),
            appshotSnapshot("final", height: 810),
        ]
    )
    let events = AsyncFetchAppshotEventProbe()
    let coordinator = CodexDesktopAppshotCaptureCoordinator(
        snapshotOperation: {
            try await snapshots.takeSnapshot()
        },
        eventSink: { message in
            await events.append(message)
        }
    )

    _ = await coordinator.startCapture(
        requestID: "capture-final",
        bundleIdentifier: "com.openai.codex"
    )
    #expect(
        await coordinator.requestFinalUpdate(
            requestID: "capture-final"
        )
    )
    #expect(!(await coordinator.contains("capture-final")))
    #expect(await snapshots.callCount() == 2)

    let messages = await events.recordedMessages()
    #expect(messages.count == 4)
    #expect(
        messages[2] == .event(
            type: "computer-use-capture-updated",
            payload: .object([
                "requestId": .string("capture-final"),
                "update": .object([
                    "type": .string("screenshot"),
                    "screenshotDataURL":
                        .string("data:image/png;base64,final"),
                ]),
            ])
        )
    )
    #expect(
        messages[3] == .event(
            type: "computer-use-capture-updated",
            payload: .object([
                "requestId": .string("capture-final"),
                "update": .object([
                    "type": .string("completed")
                ]),
            ])
        )
    )
}

@Test
func desktopAppshotCoordinatorFailsAndCleansUpFinalSnapshot()
    async
{
    let snapshots = AsyncFetchAppshotSnapshotProbe(
        snapshots: [appshotSnapshot("initial"), nil]
    )
    let events = AsyncFetchAppshotEventProbe()
    let coordinator = CodexDesktopAppshotCaptureCoordinator(
        snapshotOperation: {
            try await snapshots.takeSnapshot()
        },
        eventSink: { message in
            await events.append(message)
        }
    )

    _ = await coordinator.startCapture(
        requestID: "capture-failure",
        bundleIdentifier: "com.openai.codex"
    )
    #expect(
        !(await coordinator.requestFinalUpdate(
            requestID: "capture-failure"
        ))
    )
    #expect(!(await coordinator.contains("capture-failure")))
    let messages = await events.recordedMessages()
    #expect(
        messages.last == .event(
            type: "computer-use-capture-updated",
            payload: .object([
                "requestId": .string("capture-failure"),
                "update": .object([
                    "type": .string("failed"),
                    "failureReason":
                        .string("final_update_request_failed"),
                ]),
            ])
        )
    )
}

@Test
func desktopAppshotCoordinatorRejectsUnknownAndConcurrentFinalUpdates()
    async
{
    let snapshots = AsyncFetchAppshotSnapshotProbe(
        snapshots: [
            appshotSnapshot("initial"),
            appshotSnapshot("final"),
        ],
        delayNanoseconds: 50_000_000
    )
    let coordinator = CodexDesktopAppshotCaptureCoordinator(
        snapshotOperation: {
            try await snapshots.takeSnapshot()
        },
        eventSink: { _ in }
    )

    #expect(
        !(await coordinator.requestFinalUpdate(
            requestID: "unknown"
        ))
    )
    _ = await coordinator.startCapture(
        requestID: "capture-concurrent",
        bundleIdentifier: "com.openai.codex"
    )
    async let first = coordinator.requestFinalUpdate(
        requestID: "capture-concurrent"
    )
    async let second = coordinator.requestFinalUpdate(
        requestID: "capture-concurrent"
    )
    let results = await [first, second]
    #expect(results.filter { $0 }.count == 1)
    #expect(await snapshots.callCount() == 2)
}

@Test @MainActor
func desktopAsyncFetchRouterStartsAppshotCaptureWithReleasedShape()
    async
{
    let snapshots = AsyncFetchAppshotSnapshotProbe(
        snapshots: [appshotSnapshot("router", height: 768)]
    )
    let coordinator = CodexDesktopAppshotCaptureCoordinator(
        snapshotOperation: {
            try await snapshots.takeSnapshot()
        },
        eventSink: { _ in }
    )
    let response = await CodexDesktopAsyncFetchRouter.response(
        to: asyncFetchRequest(
            "computer-use-start-capture",
            requestID: "fetch-appshot",
            body:
                #"{"params":{"animationDestination":{"x":1,"y":2,"width":300,"height":400},"bundleIdentifier":"com.openai.codex","requestId":"capture-router"}}"#
        ),
        state: asyncFetchHostState(activeRoots: []),
        appshotCaptureStarter: coordinator
    )

    #expect(
        response == .fetchSuccess(
            requestID: "fetch-appshot",
            status: 200,
            headers: ["content-type": "application/json"],
            body: .object([
                "result": .string("started"),
                "transitionSnapshotHeight": .number(768),
            ])
        )
    )
}

@Test @MainActor
func desktopAsyncFetchRouterRejectsUnavailableAndInvalidAppshotCapture()
    async
{
    let state = asyncFetchHostState(activeRoots: [])
    let unavailable = await CodexDesktopAsyncFetchRouter.response(
        to: asyncFetchRequest(
            "computer-use-start-capture",
            requestID: "appshot-unavailable",
            body:
                #"{"params":{"bundleIdentifier":"com.openai.codex","requestId":"capture-1"}}"#
        ),
        state: state
    )
    let invalid = await CodexDesktopAsyncFetchRouter.response(
        to: asyncFetchRequest(
            "computer-use-start-capture",
            requestID: "appshot-invalid",
            body:
                #"{"params":{"bundleIdentifier":"","requestId":"capture-2"}}"#
        ),
        state: state
    )

    #expect(
        unavailable == .fetchFailure(
            requestID: "appshot-unavailable",
            status: 432,
            error: "Appshot capture is unavailable",
            errorCode: "appshot_capture_unavailable"
        )
    )
    #expect(
        invalid == .fetchFailure(
            requestID: "appshot-invalid",
            status: 432,
            error:
                "Invalid VS Code bridge request body: computer-use-start-capture",
            errorCode: "invalid_request_body"
        )
    )
}

@Test @MainActor
func desktopAsyncFetchRouterCreatesManagedWorktreeWithReleasedParams()
    async
{
    let probe = AsyncFetchManagedWorktreeProbe()
    let response =
        await CodexDesktopAsyncFetchRouter.response(
            to: asyncFetchRequest(
                "worktree-create-managed",
                requestID: "worktree-create",
                body:
                    #"{"hostId":"local","cwd":"/workspace/repo","startingState":{"type":"branch","branch":"feature/ipad"},"localEnvironmentConfigPath":"/workspace/repo/.codex/environment.json","streamId":"stream-1"}"#
            ),
            state: asyncFetchHostState(
                activeRoots: ["/workspace/repo"]
            ),
            managedWorktreeInteractor: probe
        )

    #expect(
        response == .fetchSuccess(
            requestID: "worktree-create",
            status: 200,
            headers: ["content-type": "application/json"],
            body: .object([
                "worktreeGitRoot":
                    .string("/worktrees/project/12345678"),
                "worktreeWorkspaceRoot":
                    .string("/worktrees/project/12345678"),
                "setupError": .null,
            ])
        )
    )
    #expect(probe.calls.count == 1)
    #expect(probe.calls[0].workerMethod == "create-worktree")
    #expect(
        probe.calls[0].params == .object([
            "hostId": .string("local"),
            "cwd": .string("/workspace/repo"),
            "startingState": .object([
                "type": .string("branch"),
                "branch": .string("feature/ipad"),
            ]),
            "localEnvironmentConfigPath":
                .string(
                    "/workspace/repo/.codex/environment.json"
                ),
            "streamId": .string("stream-1"),
            "worktreesRoot":
                .string("/app/CodexHome/worktrees"),
        ])
    )
}

@Test @MainActor
func desktopAsyncFetchRouterDeletesManagedWorktreeWithForce()
    async
{
    let probe = AsyncFetchManagedWorktreeProbe()
    let response =
        await CodexDesktopAsyncFetchRouter.response(
            to: asyncFetchRequest(
                "worktree-delete",
                requestID: "worktree-delete",
                body:
                    #"{"hostId":"local","worktree":"/worktrees/project/12345678","reason":"settings-delete-targeted"}"#
            ),
            state: asyncFetchHostState(activeRoots: []),
            managedWorktreeInteractor: probe
        )

    #expect(
        response == .fetchSuccess(
            requestID: "worktree-delete",
            status: 200,
            headers: ["content-type": "application/json"],
            body: .null
        )
    )
    #expect(probe.calls.count == 1)
    #expect(probe.calls[0].workerMethod == "delete-worktree")
    #expect(
        probe.calls[0].params == .object([
            "hostId": .string("local"),
            "worktree":
                .string("/worktrees/project/12345678"),
            "reason": .string("settings-delete-targeted"),
            "force": .bool(true),
        ])
    )
}

@Test @MainActor
func desktopAsyncFetchRouterSetsManagedWorktreeOwnerThread()
    async
{
    let probe = AsyncFetchManagedWorktreeProbe()
    let response =
        await CodexDesktopAsyncFetchRouter.response(
            to: asyncFetchRequest(
                "worktree-set-owner-thread",
                requestID: "worktree-owner",
                body:
                    #"{"hostId":"local","worktree":"/worktrees/project/12345678","conversationId":"thread-1"}"#
            ),
            state: asyncFetchHostState(activeRoots: []),
            managedWorktreeInteractor: probe
        )

    #expect(
        response == .fetchSuccess(
            requestID: "worktree-owner",
            status: 200,
            headers: ["content-type": "application/json"],
            body: .null
        )
    )
    #expect(probe.calls.count == 1)
    #expect(
        probe.calls[0] == .init(
            workerMethod: "set-worktree-owner-thread",
            params: .object([
                "hostId": .string("local"),
                "worktree":
                    .string("/worktrees/project/12345678"),
                "conversationId": .string("thread-1"),
            ])
        )
    )
}

@Test @MainActor
func desktopAsyncFetchRouterReportsUnavailableManagedWorktreeService()
    async
{
    let response =
        await CodexDesktopAsyncFetchRouter.response(
            to: asyncFetchRequest(
                "worktree-delete",
                requestID: "worktree-unavailable",
                body:
                    #"{"hostId":"local","worktree":"/worktrees/project/12345678","reason":"new-branch-cleanup"}"#
            ),
            state: asyncFetchHostState(activeRoots: [])
        )

    guard case .fetchFailure(
        "worktree-unavailable",
        432,
        _,
        "worktree_service_unavailable"
    )? = response
    else {
        Issue.record(
            "missing service must return worktree_service_unavailable"
        )
        return
    }
}

@Test @MainActor
func desktopAsyncFetchRouterPreparesReleasedWorktreeSnapshot()
    async
{
    let probe = AsyncFetchEmbeddedGitProbe()
    let response =
        await CodexDesktopAsyncFetchRouter.response(
            to: asyncFetchRequest(
                "prepare-worktree-snapshot",
                requestID: "snapshot-prepare",
                body:
                    #"{"gitRoot":"/workspace/repo","snapshotBranch":"feature/ipad"}"#
            ),
            state: asyncFetchHostState(
                activeRoots: ["/workspace/repo"]
            ),
            embeddedGitRequester: probe
        )

    guard case let .fetchSuccess(
        "snapshot-prepare",
        200,
        _,
        .object(body)
    )? = response
    else {
        Issue.record("snapshot preparation must return metadata")
        return
    }
    #expect(
        body["tarballPath"]
            == .string("/tmp/CodexPad-snapshot.tar.gz")
    )
    let calls = await probe.recordedCalls()
    #expect(calls.count == 1)
    #expect(calls[0].method == "prepare-worktree-snapshot")
    #expect(
        calls[0].params == .object([
            "gitRoot": .string("/workspace/repo"),
            "snapshotBranch": .string("feature/ipad"),
        ])
    )
}

@Test @MainActor
func desktopAsyncFetchRouterUploadsReleasedWorktreeSnapshot()
    async
{
    let probe = AsyncFetchSnapshotUploadProbe()
    let response =
        await CodexDesktopAsyncFetchRouter.response(
            to: asyncFetchRequest(
                "upload-worktree-snapshot",
                requestID: "snapshot-upload",
                body:
                    #"{"tarballPath":"/tmp/CodexPad-snapshot.tar.gz","uploadUrl":"https://uploads.example.invalid/snapshot","contentLength":4096,"contentType":"application/gzip"}"#
            ),
            state: asyncFetchHostState(activeRoots: []),
            worktreeSnapshotUploader: probe
        )

    #expect(
        response == .fetchSuccess(
            requestID: "snapshot-upload",
            status: 200,
            headers: ["content-type": "application/json"],
            body: .object(["success": .bool(true)])
        )
    )
    #expect(
        probe.calls == [
            .init(
                tarballPath:
                    "/tmp/CodexPad-snapshot.tar.gz",
                uploadURL: URL(
                    string:
                        "https://uploads.example.invalid/snapshot"
                )!,
                contentLength: 4096,
                contentType: "application/gzip"
            )
        ]
    )
}

@Test @MainActor
func desktopAsyncFetchRouterRoutesReleasedGitBranchOperations()
    async
{
    let probe = AsyncFetchEmbeddedGitProbe()
    let state = asyncFetchHostState(
        activeRoots: ["/workspace/repo"]
    )
    let create =
        await CodexDesktopAsyncFetchRouter.response(
            to: asyncFetchRequest(
                "git-create-branch",
                requestID: "git-create",
                body:
                    #"{"hostId":"local","cwd":"/workspace/repo","branch":"feature/ipad","failIfExists":true,"mode":"head"}"#
            ),
            state: state,
            embeddedGitRequester: probe
        )
    let checkout =
        await CodexDesktopAsyncFetchRouter.response(
            to: asyncFetchRequest(
                "git-checkout-branch",
                requestID: "git-checkout",
                body:
                    #"{"hostId":"local","cwd":"/workspace/repo","branch":"feature/ipad"}"#
            ),
            state: state,
            embeddedGitRequester: probe
        )
    let mergeBase =
        await CodexDesktopAsyncFetchRouter.response(
            to: asyncFetchRequest(
                "git-merge-base",
                requestID: "git-merge-base",
                body:
                    #"{"hostId":"local","gitRoot":"/workspace/repo","baseBranch":"main"}"#
            ),
            state: state,
            embeddedGitRequester: probe
        )

    #expect(
        create == .fetchSuccess(
            requestID: "git-create",
            status: 200,
            headers: ["content-type": "application/json"],
            body: .object([
                "status": .string("success"),
                "branch": .string("feature/ipad"),
            ])
        )
    )
    #expect(
        checkout == .fetchSuccess(
            requestID: "git-checkout",
            status: 200,
            headers: ["content-type": "application/json"],
            body: .object([
                "status": .string("success"),
                "branch": .string("feature/ipad"),
            ])
        )
    )
    #expect(
        mergeBase == .fetchSuccess(
            requestID: "git-merge-base",
            status: 200,
            headers: ["content-type": "application/json"],
            body: .object([
                "mergeBaseSha": .string(
                    "0123456789012345678901234567890123456789"
                )
            ])
        )
    )

    let calls = await probe.recordedCalls()
    #expect(calls.count == 3)
    #expect(calls[0].method == "git-create-branch")
    #expect(
        calls[0].params == .object([
            "cwd": .string("/workspace/repo"),
            "branch": .string("feature/ipad"),
            "failIfExists": .bool(true),
            "mode": .string("head"),
        ])
    )
    #expect(calls[1].method == "git-checkout-branch")
    #expect(
        calls[1].params == .object([
            "cwd": .string("/workspace/repo"),
            "branch": .string("feature/ipad"),
        ])
    )
    #expect(calls[2].method == "git-merge-base")
    #expect(
        calls[2].params == .object([
            "gitRoot": .string("/workspace/repo"),
            "baseBranch": .string("main"),
        ])
    )
}

@Test @MainActor
func desktopAsyncFetchRouterRoutesReleasedGitPush() async {
    let probe = AsyncFetchEmbeddedGitProbe()
    let response =
        await CodexDesktopAsyncFetchRouter.response(
            to: asyncFetchRequest(
                "git-push",
                requestID: "git-push",
                body:
                    #"{"hostId":"local","cwd":"/workspace/repo","refspec":"feature/ipad:feature/ipad","force":true,"setUpstream":true}"#
            ),
            state: asyncFetchHostState(
                activeRoots: ["/workspace/repo"]
            ),
            embeddedGitRequester: probe
        )

    #expect(
        response == .fetchSuccess(
            requestID: "git-push",
            status: 200,
            headers: ["content-type": "application/json"],
            body: .object([
                "status": .string("success"),
                "execOutput": .string(
                    "To https://example.invalid/repo.git"
                ),
            ])
        )
    )
    let calls = await probe.recordedCalls()
    #expect(calls.count == 1)
    guard calls.count == 1 else {
        return
    }
    #expect(calls[0].method == "git-push")
    #expect(
        calls[0].params == .object([
            "cwd": .string("/workspace/repo"),
            "refspec": .string(
                "feature/ipad:feature/ipad"
            ),
            "force": .bool(true),
            "setUpstream": .bool(true),
        ])
    )
}

@Test @MainActor
func desktopAsyncFetchRouterInjectsGitCredentialOnlyIntoEmbeddedPush()
    async
{
    let git = AsyncFetchEmbeddedGitProbe()
    let credentials = AsyncFetchGitCredentialProbe()
    _ = await CodexDesktopAsyncFetchRouter.response(
        to: asyncFetchRequest(
            "git-push",
            requestID: "git-private-push",
            body:
                #"{"hostId":"local","cwd":"/workspace/private","refspec":"main:main"}"#
        ),
        state: asyncFetchHostState(
            activeRoots: ["/workspace/private"]
        ),
        embeddedGitRequester: git,
        gitCredentialProvider: credentials
    )

    #expect(credentials.requestedPaths == ["/workspace/private"])
    let calls = await git.recordedCalls()
    guard calls.count == 1,
          case let .object(params) = calls[0].params
    else {
        Issue.record("git-push must reach embedded Git once")
        return
    }
    #expect(params["username"] == .string("git-user"))
    #expect(params["password"] == .string("test-token"))
}

@Test @MainActor
func desktopAsyncFetchRouterRoutesWorktreeShellEnvironmentConfig()
    async
{
    let probe = AsyncFetchEmbeddedGitProbe()
    let response =
        await CodexDesktopAsyncFetchRouter.response(
            to: asyncFetchRequest(
                "worktree-shell-environment-config",
                requestID: "shell-environment",
                body:
                    #"{"hostId":"local","cwd":"/workspace/repo"}"#
            ),
            state: asyncFetchHostState(
                activeRoots: ["/workspace/repo"]
            ),
            embeddedGitRequester: probe
        )

    #expect(
        response == .fetchSuccess(
            requestID: "shell-environment",
            status: 200,
            headers: ["content-type": "application/json"],
            body: .object([
                "shellEnvironment": .object([
                    "version": .integer(1),
                    "set": .object([
                        "CODEX_ENV": .string("ipad")
                    ]),
                    "exclude": .array([
                        .string("TOKEN")
                    ]),
                ])
            ])
        )
    )
    let calls = await probe.recordedCalls()
    #expect(calls.count == 1)
    #expect(
        calls[0].method
            == "worktree-shell-environment-config"
    )
    #expect(
        calls[0].params == .object([
            "cwd": .string("/workspace/repo")
        ])
    )
}

@Test @MainActor
func desktopAsyncFetchRouterRoutesReleasedFilePickers()
    async throws
{
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(
            "CodexDesktopFilePicker-\(UUID().uuidString)",
            isDirectory: true
        )
    let file = root.appendingPathComponent("image.png")
    let folder = root.appendingPathComponent(
        "Folder",
        isDirectory: true
    )
    try FileManager.default.createDirectory(
        at: folder,
        withIntermediateDirectories: true
    )
    try Data("image".utf8).write(to: file)
    defer { try? FileManager.default.removeItem(at: root) }

    let probe = AsyncFetchFileInteractionProbe()
    probe.pickedURLs = [file]
    let one =
        await CodexDesktopAsyncFetchRouter.response(
            to: asyncFetchRequest(
                "pick-file",
                requestID: "pick-one",
                body: #"{"pickerTitle":"Choose context"}"#
            ),
            state: asyncFetchHostState(activeRoots: []),
            fileInteractor: probe
        )
    #expect(
        one == .fetchSuccess(
            requestID: "pick-one",
            status: 200,
            headers: ["content-type": "application/json"],
            body: .object([
                "file": .object([
                    "label": .string("image.png"),
                    "path": .string(file.path),
                    "fsPath": .string(file.path),
                ])
            ])
        )
    )

    probe.pickedURLs = [file, folder]
    let many =
        await CodexDesktopAsyncFetchRouter.response(
            to: asyncFetchRequest(
                "pick-files",
                requestID: "pick-many",
                body:
                    #"{"imagesOnly":false,"pickerTitle":"Choose files"}"#
            ),
            state: asyncFetchHostState(activeRoots: []),
            fileInteractor: probe
        )
    #expect(
        many == .fetchSuccess(
            requestID: "pick-many",
            status: 200,
            headers: ["content-type": "application/json"],
            body: .object([
                "files": .array([
                    .object([
                        "label": .string("image.png"),
                        "path": .string(file.path),
                        "fsPath": .string(file.path),
                    ]),
                    .object([
                        "label": .string("Folder"),
                        "path": .string(folder.path + "/"),
                        "fsPath": .string(folder.path),
                    ]),
                ])
            ])
        )
    )

    probe.pickedURLs = []
    let cancelled =
        await CodexDesktopAsyncFetchRouter.response(
            to: asyncFetchRequest(
                "pick-file",
                requestID: "pick-cancelled",
                body: #"{}"#
            ),
            state: asyncFetchHostState(activeRoots: []),
            fileInteractor: probe
        )
    #expect(
        cancelled == .fetchSuccess(
            requestID: "pick-cancelled",
            status: 200,
            headers: ["content-type": "application/json"],
            body: .object(["file": .null])
        )
    )
    #expect(
        probe.pickCalls == [
            .init(
                allowsMultipleSelection: false,
                imagesOnly: false,
                pickerTitle: "Choose context"
            ),
            .init(
                allowsMultipleSelection: true,
                imagesOnly: false,
                pickerTitle: "Choose files"
            ),
            .init(
                allowsMultipleSelection: false,
                imagesOnly: false,
                pickerTitle: nil
            ),
        ]
    )
    // The renderer consumes the returned fsPath after this fetch completes.
    // Security-scoped leases therefore live with the scene controller rather
    // than being released before the response reaches the renderer.
    #expect(probe.releasedURLBatches.isEmpty)
}

@Test @MainActor
func desktopAsyncFetchRouterRoutesReleasedSaveFileShapes()
    async throws
{
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(
            "CodexDesktopSaveFile-\(UUID().uuidString)",
            isDirectory: true
        )
    try FileManager.default.createDirectory(
        at: root,
        withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("source.bin")
    try Data([0, 1, 2, 255]).write(to: source)
    let destination = root.appendingPathComponent("saved.bin")

    let probe = AsyncFetchFileInteractionProbe()
    probe.savedURL = destination
    let contents =
        await CodexDesktopAsyncFetchRouter.response(
            to: asyncFetchRequest(
                "save-file",
                requestID: "save-contents",
                body:
                    #"{"kind":"contents","suggestedFilename":"notes.txt","contentsBase64":"aXBhZA=="}"#
            ),
            state: asyncFetchHostState(activeRoots: []),
            fileInteractor: probe
        )
    let remote =
        await CodexDesktopAsyncFetchRouter.response(
            to: asyncFetchRequest(
                "save-file",
                requestID: "save-remote",
                body:
                    #"{"kind":"remote-file","hostId":"local","suggestedFilename":"source.bin","sourcePath":"\#(source.path)"}"#
            ),
            state: asyncFetchHostState(activeRoots: []),
            fileInteractor: probe
        )

    for (response, requestID) in [
        (contents, "save-contents"),
        (remote, "save-remote"),
    ] {
        #expect(
            response == .fetchSuccess(
                requestID: requestID,
                status: 200,
                headers: [
                    "content-type": "application/json"
                ],
                body: .object([
                    "path": .string(destination.path)
                ])
            )
        )
    }
    #expect(
        probe.saveCalls == [
            .init(
                suggestedFilename: "notes.txt",
                contents: Data("ipad".utf8)
            ),
            .init(
                suggestedFilename: "source.bin",
                contents: Data([0, 1, 2, 255])
            ),
        ]
    )
}

@Test @MainActor
func desktopAsyncFetchRouterRoutesReleasedAddContextFile()
    async
{
    let probe = AsyncFetchFileInteractionProbe()
    let response =
        await CodexDesktopAsyncFetchRouter.response(
            to: asyncFetchRequest(
                "add-context-file",
                requestID: "add-context",
                body:
                    #"{"hostId":"local","path":"/workspace/shot.png","origin":"main-view"}"#
            ),
            state: asyncFetchHostState(activeRoots: []),
            fileInteractor: probe
        )

    #expect(
        response == .fetchSuccess(
            requestID: "add-context",
            status: 200,
            headers: ["content-type": "application/json"],
            body: .object(["success": .bool(true)])
        )
    )
    #expect(
        probe.contextCalls == [
            .init(
                path: "/workspace/shot.png",
                origin: .string("main-view")
            )
        ]
    )
}

@Test @MainActor
func desktopAsyncFetchRouterDeletesArchivedThreadsWithReleasedShape()
    async
{
    let store = AsyncFetchArchivedThreadProbe()
    let state = asyncFetchHostState(activeRoots: [])
    let one =
        await CodexDesktopAsyncFetchRouter.response(
            to: asyncFetchRequest(
                "delete-archived-thread",
                requestID: "delete-one",
                body:
                    #"{"hostId":"local","threadId":"archived-1"}"#
            ),
            state: state,
            archivedThreadStore: store
        )
    let all =
        await CodexDesktopAsyncFetchRouter.response(
            to: asyncFetchRequest(
                "delete-all-archived-threads",
                requestID: "delete-all",
                body: #"{"hostId":"local"}"#
            ),
            state: state,
            archivedThreadStore: store
        )

    #expect(
        one == .fetchSuccess(
            requestID: "delete-one",
            status: 200,
            headers: ["content-type": "application/json"],
            body: .object([
                "deletedThreadIds": .array([
                    .string("archived-1")
                ])
            ])
        )
    )
    #expect(
        all == .fetchSuccess(
            requestID: "delete-all",
            status: 200,
            headers: ["content-type": "application/json"],
            body: .object([
                "deletedThreadIds": .array([
                    .string("archived-1"),
                    .string("archived-2"),
                ])
            ])
        )
    )
    #expect(
        store.deletedIDs == [
            CodexStoredThreadID("archived-1")
        ]
    )
    #expect(store.deleteAllCalls == 1)
}

private func asyncFetchHostState(
    activeRoots: [String]
) -> CodexDesktopInitialHostState {
    CodexDesktopInitialHostState(
        codexHome: "/app/CodexHome",
        worktreesSegment: "/app/CodexHome/worktrees",
        platform: "darwin",
        osVersion: "18.5",
        osRelease: "24F74",
        isSystemBackdropSupported: false,
        isVsCodeRunningInsideWsl: false,
        windowsAccountType: "unknown",
        isCopilotAPIAvailable: false,
        configuredSettings: [:],
        effectiveSettings: [:],
        globalState: [:],
        ideLocale: "zh-CN",
        systemLocale: "zh-Hans-CN",
        automationItems: [],
        activeWorkspaceRoots: activeRoots,
        remoteControlConnections: [],
        inboxItems: [],
        unreadRunCount: 0,
        unreadAutomationIDs: [],
        unreadRuns: [],
        commandKeymapPath: "/app/keymap.json",
        commandKeyBindings: [],
        existingPaths: Set(activeRoots),
        pinnedThreadIDs: []
    )
}

@Test @MainActor
func desktopAsyncFetchRouterRunsAutomationWithThreadSettings()
    async throws
{
    let codexHome = FileManager.default.temporaryDirectory
        .appendingPathComponent(
            "CodexDesktopAsyncAutomationTests-\(UUID().uuidString)",
            isDirectory: true
        )
    defer { try? FileManager.default.removeItem(at: codexHome) }
    let store = try CodexDesktopAutomationStore(
        codexHome: codexHome
    )
    let created = try store.create(
        params: [
            "kind": .string("heartbeat"),
            "name": .string("Run now"),
            "prompt": .string("Continue the active task."),
            "targetThreadId": .string("thread-target"),
            "model": .null,
            "reasoningEffort": .null,
            "rrule": .string("FREQ=HOURLY;INTERVAL=1"),
        ]
    )
    guard case let .object(fields) = created,
          case let .string(automationID)? = fields["id"]
    else {
        Issue.record("automation create must return an id")
        return
    }
    var received: CodexDesktopAutomationRunRequest?
    let scheduler = CodexDesktopAutomationScheduler(
        store: store,
        runner: { request in
            received = request
            return CodexDesktopAutomationExecution(
                threadID: "thread-target",
                status: "PENDING_REVIEW"
            )
        }
    )
    let response =
        await CodexDesktopAsyncFetchRouter.response(
            to: asyncFetchRequest(
                "automation-run-now",
                requestID: "run-now",
                body:
                    #"{"id":"\#(automationID)","collaborationMode":{"mode":"plan","settings":{"model":"gpt-5.3-codex","reasoning_effort":"high","developer_instructions":"Plan carefully"}},"permissions":"full"}"#
            ),
            state: asyncFetchHostState(activeRoots: []),
            automationScheduler: scheduler,
            now: Date(timeIntervalSince1970: 1_785_686_400)
        )

    #expect(
        response == .fetchSuccess(
            requestID: "run-now",
            status: 200,
            headers: ["content-type": "application/json"],
            body: .object(["success": .bool(true)])
        )
    )
    #expect(received?.automationID == automationID)
    #expect(received?.permissions == "full")
    #expect(received?.collaborationMode?.mode == .plan)
    #expect(
        received?.collaborationMode?
            .settings.developerInstructions == "Plan carefully"
    )
    #expect(store.snapshot().inboxItems.count == 1)
}

@Test @MainActor
func desktopAsyncFetchRouterUsesEmbeddedGitForOrigins() async {
    let probe = AsyncFetchEmbeddedGitProbe()
    let response =
        await CodexDesktopAsyncFetchRouter.response(
            to: asyncFetchRequest(
                "git-origins",
                requestID: "git-origins",
                body:
                    #"{"hostId":"local","dirs":["/workspace/repo","/workspace/repo"]}"#
            ),
            state: asyncFetchHostState(
                activeRoots: ["/workspace/default"]
            ),
            embeddedGitRequester: probe,
            homeDirectory: "/app/home"
        )

    guard case let .fetchSuccess(
        "git-origins",
        200,
        headers,
        .object(body)
    )? = response
    else {
        Issue.record("git-origins must return the embedded result")
        return
    }
    #expect(headers == ["content-type": "application/json"])
    #expect(body["homeDir"] == .string("/app/home"))
    guard case let .array(origins)? = body["origins"] else {
        Issue.record("git-origins must preserve origins")
        return
    }
    #expect(origins.count == 1)
    let calls = await probe.recordedCalls()
    #expect(calls.count == 1)
    #expect(calls[0].method == "git-origins")
    #expect(
        calls[0].params == .object([
            "dirs": .array([
                .string("/workspace/repo")
            ])
        ])
    )
}
