import CodexPadApplication
import CodexPadDomain
import CodexPadProtocolBridge
import CryptoKit
import Foundation
import Testing

@Test
func desktopWorkerBusForwardsExactReleasedResponseEnvelope() async throws {
    let output = WorkerOutputProbe()
    let handler = WorkerHandlerProbe(result: .object([
        "branch": .string("main")
    ]))
    let bus = CodexDesktopWorkerBus(
        handlers: ["git": handler],
        output: { await output.append($0) }
    )

    try await bus.receive(
        workerID: "git",
        message: workerRequest(
            id: "request-1",
            method: "current-branch",
            params: .object(["cwd": .string("/workspace")])
        )
    )

    let messages = await output.waitForCount(1)
    #expect(
        messages == [
            .event(
                type: "worker-message",
                payload: .object([
                    "workerID": .string("git"),
                    "message": .object([
                        "type": .string("worker-response"),
                        "workerId": .string("git"),
                        "response": .object([
                            "id": .string("request-1"),
                            "method": .string("current-branch"),
                            "result": .object([
                                "type": .string("ok"),
                                "value": .object([
                                    "branch": .string("main")
                                ]),
                            ]),
                        ]),
                    ]),
                ])
            )
        ]
    )
    #expect(
        await handler.requests()
            == [
                CodexDesktopWorkerRequest(
                    workerID: "git",
                    id: "request-1",
                    method: "current-branch",
                    params: .object(["cwd": .string("/workspace")]),
                    trace: .object(["traceId": .string("trace-1")]),
                    enqueuedAtMs: .integer(123)
                )
            ]
    )
}

@Test
func desktopWorkerBusReportsStableMetadataRequestAndOutcomeWithoutPayload() async throws {
    let output = WorkerOutputProbe()
    let diagnostics = DiagnosticProbe()
    let bus = CodexDesktopWorkerBus(
        handlers: ["git": WorkerHandlerProbe(result: .object([
            "kind": .string("git")
        ]))],
        output: { await output.append($0) },
        diagnostic: { await diagnostics.append($0) }
    )

    try await bus.receive(
        workerID: "git",
        message: workerRequest(
            id: "stable-metadata-1",
            method: "stable-metadata",
            params: .object(["cwd": .string("/private/workspace")])
        )
    )
    _ = await output.waitForCount(1)

    #expect(await diagnostics.snapshot() == [
        .request(method: "stable-metadata"),
        .result(method: "stable-metadata", outcome: .value),
    ])
}

@Test(arguments: [
    (CodexJSONValue.null, CodexDesktopWorkerDiagnostic.Outcome.null),
])
func desktopWorkerBusClassifiesNullStableMetadataOutcome(
    result: CodexJSONValue,
    outcome: CodexDesktopWorkerDiagnostic.Outcome
) async throws {
    let output = WorkerOutputProbe()
    let diagnostics = DiagnosticProbe()
    let bus = CodexDesktopWorkerBus(
        handlers: ["git": WorkerHandlerProbe(result: result)],
        output: { await output.append($0) },
        diagnostic: { await diagnostics.append($0) }
    )

    try await bus.receive(
        workerID: "git",
        message: workerRequest(id: "metadata-null", method: "stable-metadata")
    )
    _ = await output.waitForCount(1)

    #expect(await diagnostics.snapshot().last == .result(
        method: "stable-metadata",
        outcome: outcome
    ))
}

@Test
func desktopWorkerBusClassifiesStableMetadataErrorWithoutErrorText() async throws {
    let output = WorkerOutputProbe()
    let diagnostics = DiagnosticProbe()
    let bus = CodexDesktopWorkerBus(
        handlers: ["git": ThrowingWorkerHandlerProbe()],
        output: { await output.append($0) },
        diagnostic: { await diagnostics.append($0) }
    )

    try await bus.receive(
        workerID: "git",
        message: workerRequest(id: "metadata-error", method: "stable-metadata")
    )
    _ = await output.waitForCount(1)

    #expect(await diagnostics.snapshot().last == .result(
        method: "stable-metadata",
        outcome: .error
    ))
}

@Test
func desktopWorkerBusCancellationSuppressesLateResponse() async throws {
    let output = WorkerOutputProbe()
    let handler = BlockingWorkerHandlerProbe()
    let bus = CodexDesktopWorkerBus(
        handlers: ["git": handler],
        output: { await output.append($0) }
    )

    try await bus.receive(
        workerID: "git",
        message: workerRequest(id: "request-2", method: "status-summary")
    )
    await handler.waitUntilStarted()
    try await bus.receive(
        workerID: "git",
        message: .object([
            "type": .string("worker-request-cancel"),
            "workerId": .string("git"),
            "id": .string("request-2"),
        ])
    )
    await handler.release()
    try await Task.sleep(for: .milliseconds(20))

    #expect(await output.snapshot().isEmpty)
    #expect(await handler.wasCancelled())
}

@Test
func desktopWorkerBusRejectsMismatchedWorkerIdentity() async {
    let bus = CodexDesktopWorkerBus(
        handlers: [:],
        output: { _ in }
    )

    await #expect(throws: CodexDesktopWorkerBusError.self) {
        try await bus.receive(
            workerID: "git",
            message: .object([
                "type": .string("worker-request"),
                "workerId": .string("other"),
                "request": .object([
                    "id": .string("request-3"),
                    "method": .string("status-summary"),
                ]),
            ])
        )
    }
}

@Test
func desktopWorkerBusReturnsStructuredErrorInsteadOfHanging() async throws {
    let output = WorkerOutputProbe()
    let bus = CodexDesktopWorkerBus(
        handlers: ["git": CodexDesktopUnsupportedGitWorker()],
        output: { await output.append($0) }
    )

    try await bus.receive(
        workerID: "git",
        message: workerRequest(id: "request-4", method: "future-method")
    )

    let messages = await output.waitForCount(1)
    guard case let .event(_, .object(outer)) = messages.first,
          case let .object(message)? = outer["message"],
          case let .object(response)? = message["response"],
          case let .object(result)? = response["result"]
    else {
        Issue.record("Missing released worker response envelope")
        return
    }
    #expect(result["type"] == .string("error"))
    #expect(
        result["error"]
            == .object([
                "message": .string(
                    "Unsupported git worker method: future-method"
                )
            ])
    )
}

@Test
func desktopWorkerBusForwardsExactReleasedWorkerEventEnvelope() async {
    let output = WorkerOutputProbe()
    let bus = CodexDesktopWorkerBus(
        handlers: [:],
        output: { await output.append($0) }
    )
    let event: CodexJSONValue = .object([
        "type": .string("git-repo-changed"),
        "changeType": .string("worktree"),
        "commonDir": .string("/workspace/.git"),
        "hostId": .string("local"),
        "rebaseInProgress": .bool(false),
        "root": .string("/workspace"),
        "changedPaths": .array([.string("README.md")]),
    ])

    await bus.publishEvent(workerID: "git", event: event)

    #expect(
        await output.snapshot()
            == [
                .event(
                    type: "worker-message",
                    payload: .object([
                        "workerID": .string("git"),
                        "message": .object([
                            "type": .string("worker-event"),
                            "workerId": .string("git"),
                            "event": event,
                        ]),
                    ])
                )
            ]
    )
}

@Test
func desktopGitWorkerKeepsLiveQueryOpenAndEmitsReleasedUpdate() async throws {
    let output = WorkerOutputProbe()
    let runner = GitRunnerProbe(results: [
        .init(
            exitCode: 0,
            stdout: " M README.md\n?? Notes/new.txt\n",
            stderr: ""
        )
    ])
    let worker = CodexDesktopGitWorker {
        try await runner.run(arguments: $0, cwd: $1)
    }
    let bus = CodexDesktopWorkerBus(
        handlers: ["git": worker],
        output: { await output.append($0) }
    )

    try await bus.receive(
        workerID: "git",
        message: workerRequest(
            id: "live-request",
            method: "subscribe-live-query",
            params: .object([
                "hostConfig": .object(["id": .string("local")]),
                "operationSource": .string("thread"),
                "subscriptionId": .string("live-status"),
                "query": .object([
                    "method": .string("status-summary"),
                    "params": .object([
                        "cwd": .string("/workspace"),
                        "includeUntrackedFiles": .bool(true),
                    ]),
                ]),
            ])
        )
    )

    let messages = await output.waitForCount(1)
    guard case let .event(_, .object(outer)) = messages.first,
          case let .object(message)? = outer["message"],
          case let .object(event)? = message["event"]
    else {
        Issue.record("Missing live query event")
        return
    }
    #expect(message["type"] == .string("worker-event"))
    #expect(event["type"] == .string("git-live-query-updated"))
    #expect(event["subscriptionId"] == .string("live-status"))
    #expect(event["generation"] == .integer(1))
    #expect(event["phase"] == .string("complete"))
    #expect(event["requiresRecovery"] == .bool(false))
    #expect(event["method"] == .string("status-summary"))
    #expect(
        event["result"] == .object([
            "type": .string("success"),
            "stagedCount": .integer(0),
            "unstagedCount": .integer(1),
            "untrackedCount": .integer(1),
        ])
    )

    try await bus.receive(
        workerID: "git",
        message: .object([
            "type": .string("worker-request-cancel"),
            "workerId": .string("git"),
            "id": .string("live-request"),
        ])
    )
    try await Task.sleep(for: .milliseconds(10))
    #expect(await output.snapshot().count == 1)
}

@Test
func desktopGitWorkerImplementsReleasedWatchLifecycleShapes() async throws {
    let worker = CodexDesktopGitWorker { _, _ in
        Issue.record("Watch lifecycle must not invoke git")
        return .init(exitCode: 1, stdout: "", stderr: "")
    }

    let watched = try await worker.handle(
        .init(
            workerID: "git",
            id: "watch",
            method: "watch-repo",
            params: .object([
                "root": .string("/workspace"),
                "commonDir": .string("/workspace/.git"),
            ])
        )
    )
    let recovered = try await worker.handle(
        .init(
            workerID: "git",
            id: "recover",
            method: "recover-live-queries",
            params: .object([
                "cwd": .string("/workspace"),
                "subscriptionIds": .array([.string("live-status")]),
            ])
        )
    )
    let unwatched = try await worker.handle(
        .init(
            workerID: "git",
            id: "unwatch",
            method: "unwatch-repo",
            params: .object(["root": .string("/workspace")])
        )
    )

    #expect(watched == .object(["success": .bool(true)]))
    #expect(recovered == .null)
    #expect(unwatched == .object(["success": .bool(true)]))
}

@Test
func desktopGitWorkerImplementsReleasedBranchAndConfigReads() async throws {
    let runner = GitRunnerProbe(results: [
        .init(exitCode: 0, stdout: "feature/ipad\n", stderr: ""),
        .init(exitCode: 0, stdout: "", stderr: ""),
        .init(exitCode: 0, stdout: "enabled\n", stderr: ""),
    ])
    let worker = CodexDesktopGitWorker {
        try await runner.run(arguments: $0, cwd: $1)
    }

    let branch = try await worker.handle(
        .init(
            workerID: "git",
            id: "git-1",
            method: "current-branch",
            params: .object(["root": .string("/workspace")])
        )
    )
    let exists = try await worker.handle(
        .init(
            workerID: "git",
            id: "git-2",
            method: "branch-exists",
            params: .object([
                "root": .string("/workspace"),
                "branch": .string("feature/ipad"),
            ])
        )
    )
    let config = try await worker.handle(
        .init(
            workerID: "git",
            id: "git-3",
            method: "config-value",
            params: .object([
                "root": .string("/workspace"),
                "key": .string("codex.enabled"),
                "scope": .string("worktree"),
            ])
        )
    )

    #expect(branch == .object(["branch": .string("feature/ipad")]))
    #expect(exists == .object(["exists": .bool(true)]))
    #expect(config == .object(["value": .string("enabled")]))
    #expect(
        await runner.calls()
            == [
                .init(
                    arguments: [
                        "git", "-C", "/workspace", "symbolic-ref",
                        "--short", "-q", "HEAD",
                    ],
                    cwd: "/workspace"
                ),
                .init(
                    arguments: [
                        "git", "-C", "/workspace", "show-ref",
                        "--verify", "--quiet", "refs/heads/feature/ipad",
                    ],
                    cwd: "/workspace"
                ),
                .init(
                    arguments: [
                        "git", "-C", "/workspace", "config",
                        "--worktree", "--get", "codex.enabled",
                    ],
                    cwd: "/workspace"
                ),
            ]
    )
}

@Test
func desktopGitWorkerPrefersEmbeddedReadsWithoutSpawningGit() async throws {
    let worker = CodexDesktopGitWorker(
        runWithEnvironment: { _, _, _ in
            Issue.record("Embedded Git reads must not spawn an external command")
            return .init(exitCode: 127, stdout: "", stderr: "")
        },
        embeddedReader: { method, params in
            #expect(method == "status-summary")
            #expect(
                params == .object([
                    "cwd": .string("/workspace"),
                    "includeUntrackedFiles": .bool(true),
                ])
            )
            return .object([
                "type": .string("success"),
                "stagedCount": .integer(1),
                "unstagedCount": .integer(2),
                "untrackedCount": .integer(3),
            ])
        }
    )

    let result = try await worker.handle(
        .init(
            workerID: "git",
            id: "embedded-status",
            method: "status-summary",
            params: .object([
                "cwd": .string("/workspace"),
                "includeUntrackedFiles": .bool(true),
            ])
        )
    )

    #expect(
        result == .object([
            "type": .string("success"),
            "stagedCount": .integer(1),
            "unstagedCount": .integer(2),
            "untrackedCount": .integer(3),
        ])
    )
}

@Test
func desktopGitWorkerCommitsAllChangesThroughEmbeddedCore() async throws {
    let expected: CodexJSONValue = .object([
        "status": .string("success"),
        "commitSha": .string("1234567890123456789012345678901234567890"),
    ])
    let worker = CodexDesktopGitWorker(
        runWithEnvironment: { _, _, _ in
            Issue.record("Embedded iPad commits must not spawn external Git")
            return .init(exitCode: 127, stdout: "", stderr: "")
        },
        embeddedReader: { method, params in
            #expect(method == "commit")
            #expect(
                params == .object([
                    "cwd": .string("/workspace"),
                    "message": .string("Commit on iPad"),
                    "includeUnstaged": .bool(true),
                ])
            )
            return expected
        }
    )
    let result = try await worker.handle(.init(
        workerID: "git",
        id: "embedded-commit",
        method: "commit",
        params: .object([
            "cwd": .string("/workspace"),
            "message": .string("Commit on iPad"),
            "includeUnstaged": .bool(true),
        ])
    ))
    #expect(result == expected)
}

@Test
func desktopGitWorkerPushesThroughEmbeddedCoreWithoutSpawningGit()
    async throws
{
    let params: CodexJSONValue = .object([
        "cwd": .string("/workspace"),
        "refspec": .string("feature/ipad:feature/ipad"),
        "force": .bool(false),
        "setUpstream": .bool(true),
    ])
    let expected: CodexJSONValue = .object([
        "status": .string("success"),
        "execOutput": .string("feature/ipad -> feature/ipad"),
    ])
    let worker = CodexDesktopGitWorker(
        runWithEnvironment: { _, _, _ in
            Issue.record(
                "Embedded iPad push must not spawn external Git"
            )
            return .init(exitCode: 127, stdout: "", stderr: "")
        },
        embeddedReader: { method, received in
            #expect(method == "git-push")
            #expect(received == params)
            return expected
        }
    )
    let result = try await worker.handle(.init(
        workerID: "git",
        id: "embedded-push",
        method: "git-push",
        params: params
    ))
    #expect(result == expected)
}

@Test
func desktopGitWorkerAppliesTextPatchThroughEmbeddedCore() async throws {
    let expected: CodexJSONValue = .object([
        "status": .string("success"),
        "appliedPaths": .array([.string("Sources/App.swift")]),
        "skippedPaths": .array([]),
        "conflictedPaths": .array([]),
        "execOutput": .object([
            "exitCode": .integer(0),
            "stdout": .string("Patch applied"),
            "stderr": .string(""),
            "command": .string("embedded git apply"),
        ]),
    ])
    let diff = """
        --- a/Sources/App.swift
        +++ b/Sources/App.swift
        @@ -1 +1 @@
        -old
        +new
        """
    let worker = CodexDesktopGitWorker(
        runWithEnvironment: { _, _, _ in
            Issue.record("Embedded iPad patching must not spawn external Git")
            return .init(exitCode: 127, stdout: "", stderr: "")
        },
        embeddedReader: { method, params in
            #expect(method == "apply-patch")
            #expect(
                params == .object([
                    "cwd": .string("/workspace"),
                    "diff": .string(diff),
                    "atomic": .bool(true),
                    "target": .string("unstaged"),
                ])
            )
            return expected
        }
    )
    let result = try await worker.handle(.init(
        workerID: "git",
        id: "embedded-apply-patch",
        method: "apply-patch",
        params: .object([
            "cwd": .string("/workspace"),
            "diff": .string(diff),
            "atomic": .bool(true),
            "target": .string("unstaged"),
        ])
    ))
    #expect(result == expected)
}

@Test
func desktopGitWorkerRoutesChangeAndReviewWritesThroughEmbeddedCore()
    async throws
{
    let success: CodexJSONValue = .object([
        "status": .string("success")
    ])
    let changeParams: CodexJSONValue = .object([
        "sourceHeadRef": .string("refs/heads/source"),
        "sourceTreeRef": .string("source-tree"),
        "destinationRoot": .string("/workspace"),
        "destinationHeadRef": .string("HEAD"),
    ])
    let changeWorker = CodexDesktopGitWorker(
        runWithEnvironment: { _, _, _ in
            Issue.record("Embedded iPad change application must not spawn Git")
            return .init(exitCode: 127, stdout: "", stderr: "")
        },
        embeddedReader: { method, params in
            #expect(method == "apply-changes")
            #expect(params == changeParams)
            return success
        }
    )
    #expect(
        try await changeWorker.handle(.init(
            workerID: "git",
            id: "embedded-apply-changes",
            method: "apply-changes",
            params: changeParams
        )) == success
    )

    let reviewParams: CodexJSONValue = .object([
        "action": .string("stage"),
        "cwd": .string("/workspace"),
        "source": .string("unstaged"),
        "files": .array([
            .object([
                "path": .string("Sources/App.swift"),
                "revision": .string("unstaged:M:100644:old:100644:new"),
                "changeKind": .string("modified"),
            ])
        ]),
    ])
    let reviewResult: CodexJSONValue = .object([
        "status": .string("success"),
        "appliedPaths": .array([.string("Sources/App.swift")]),
        "skippedPaths": .array([]),
        "conflictedPaths": .array([]),
    ])
    let reviewWorker = CodexDesktopGitWorker(
        runWithEnvironment: { _, _, _ in
            Issue.record("Embedded iPad review writes must not spawn Git")
            return .init(exitCode: 127, stdout: "", stderr: "")
        },
        embeddedReader: { method, params in
            #expect(method == "apply-review-section-changes")
            #expect(params == reviewParams)
            return reviewResult
        }
    )
    #expect(
        try await reviewWorker.handle(.init(
            workerID: "git",
            id: "embedded-review-write",
            method: "apply-review-section-changes",
            params: reviewParams
        )) == reviewResult
    )
}

@Test
func desktopGitWorkerRoutesTurnDiffAndRepositoryOverwriteThroughEmbeddedCore()
    async throws
{
    let startParams: CodexJSONValue = .object([
        "cwd": .string("/workspace"),
        "checkpointKey": .string("session"),
        "turnId": .string("turn-1"),
    ])
    let capture: CodexJSONValue = .object([
        "root": .string("/workspace"),
        "baseTreeSha": .string("base-tree"),
        "refPrefix": .string("refs/codex/capture"),
        "checkpointRefPrefix": .string("refs/codex/checkpoint"),
    ])
    let startWorker = CodexDesktopGitWorker(
        runWithEnvironment: { _, _, _ in
            Issue.record("Embedded iPad turn capture must not spawn Git")
            return .init(exitCode: 127, stdout: "", stderr: "")
        },
        embeddedReader: { method, params in
            #expect(method == "turn-diff-capture-start")
            #expect(params == startParams)
            return capture
        }
    )
    #expect(
        try await startWorker.handle(.init(
            workerID: "git",
            id: "turn-start",
            method: "turn-diff-capture-start",
            params: startParams
        )) == capture
    )

    let completeParams: CodexJSONValue = .object([
        "capture": capture,
        "retainCheckpoint": .bool(true),
    ])
    let completeResult: CodexJSONValue = .object([
        "headTreeSha": .string("head-tree"),
        "diff": .object(["type": .string("success")]),
    ])
    let completeWorker = CodexDesktopGitWorker(
        runWithEnvironment: { _, _, _ in
            Issue.record("Embedded iPad turn completion must not spawn Git")
            return .init(exitCode: 127, stdout: "", stderr: "")
        },
        embeddedReader: { method, params in
            #expect(method == "turn-diff-capture-complete")
            #expect(params == completeParams)
            return completeResult
        }
    )
    #expect(
        try await completeWorker.handle(.init(
            workerID: "git",
            id: "turn-complete",
            method: "turn-diff-capture-complete",
            params: completeParams
        )) == completeResult
    )

    let overwriteParams: CodexJSONValue = .object([
        "gitRoot": .string("/workspace"),
        "branchName": .string("main"),
        "headCommitSha": .string("head"),
        "treeSha": .string("tree"),
    ])
    let success: CodexJSONValue = .object(["status": .string("success")])
    let overwriteWorker = CodexDesktopGitWorker(
        runWithEnvironment: { _, _, _ in
            Issue.record("Embedded iPad repository overwrite must not spawn Git")
            return .init(exitCode: 127, stdout: "", stderr: "")
        },
        embeddedReader: { method, params in
            #expect(method == "overwrite-repo")
            #expect(params == overwriteParams)
            return success
        }
    )
    #expect(
        try await overwriteWorker.handle(.init(
            workerID: "git",
            id: "overwrite",
            method: "overwrite-repo",
            params: overwriteParams
        )) == success
    )
}

@Test
func desktopGitWorkerMovesThreadToLocalThroughEmbeddedCoreAndForwardsProgress()
    async throws
{
    let params: CodexJSONValue = .object([
        "sourceWorktreeCwd": .string("/worktree"),
        "sourceWorktreeRoot": .string("/worktree"),
        "localGitRoot": .string("/local"),
        "sourceBranch": .string("feature/ipad"),
        "operationId": .string("move-1"),
    ])
    let emitted = JSONValueProbe()
    let worker = CodexDesktopGitWorker(
        runWithEnvironment: { _, _, _ in
            Issue.record("Embedded iPad thread migration must not spawn Git")
            return .init(exitCode: 127, stdout: "", stderr: "")
        },
        embeddedReader: { method, received in
            #expect(method == "move-thread-to-local")
            #expect(received == params)
            return .object([
                "status": .string("success"),
                "warnings": .array([]),
                "_progress": .array([
                    .object([
                        "step": .string("stash-source-changes"),
                        "status": .string("completed"),
                    ]),
                    .object([
                        "step": .string("apply-changes-to-local"),
                        "status": .string("completed"),
                    ]),
                ]),
            ])
        }
    )
    let result = try await worker.handle(
        .init(
            workerID: "git",
            id: "move-request",
            method: "move-thread-to-local",
            params: params
        ),
        emit: { await emitted.append($0) }
    )
    #expect(result == .object([
        "status": .string("success"),
        "warnings": .array([]),
    ]))
    #expect(await emitted.snapshot() == [
        .object([
            "type": .string("thread-handoff-progress"),
            "operationId": .string("move-1"),
            "direction": .string("to-local"),
            "step": .string("stash-source-changes"),
            "status": .string("completed"),
        ]),
        .object([
            "type": .string("thread-handoff-progress"),
            "operationId": .string("move-1"),
            "direction": .string("to-local"),
            "step": .string("apply-changes-to-local"),
            "status": .string("completed"),
        ]),
    ])
}

@Test
func desktopGitWorkerMovesThreadToWorktreeThroughEmbeddedCoreAndForwardsProgress()
    async throws
{
    let params: CodexJSONValue = .object([
        "localCwd": .string("/local"),
        "sourceBranch": .string("feature/ipad"),
        "defaultBranch": .string("main"),
        "localCheckoutBranch": .string("main"),
        "worktreeCheckoutBranch": .string("feature/ipad"),
        "worktreeGitRoot": .string("/worktree"),
        "worktreeWorkspaceRoot": .string("/worktree"),
        "operationId": .string("move-2"),
    ])
    let emitted = JSONValueProbe()
    let worker = CodexDesktopGitWorker(
        runWithEnvironment: { _, _, _ in
            Issue.record("Embedded iPad worktree migration must not spawn Git")
            return .init(exitCode: 127, stdout: "", stderr: "")
        },
        embeddedReader: { method, received in
            #expect(method == "move-thread-to-worktree")
            #expect(received == params)
            return .object([
                "status": .string("success"),
                "warnings": .array([]),
                "_progress": .array([
                    .object([
                        "step": .string("checkout-worktree-branch"),
                        "status": .string("completed"),
                    ]),
                    .object([
                        "step": .string("apply-changes-to-worktree"),
                        "status": .string("completed"),
                    ]),
                ]),
            ])
        }
    )
    let result = try await worker.handle(
        .init(
            workerID: "git",
            id: "move-worktree-request",
            method: "move-thread-to-worktree",
            params: params
        ),
        emit: { await emitted.append($0) }
    )
    #expect(result == .object([
        "status": .string("success"),
        "warnings": .array([]),
    ]))
    #expect(await emitted.snapshot() == [
        .object([
            "type": .string("thread-handoff-progress"),
            "operationId": .string("move-2"),
            "direction": .string("to-worktree"),
            "step": .string("checkout-worktree-branch"),
            "status": .string("completed"),
        ]),
        .object([
            "type": .string("thread-handoff-progress"),
            "operationId": .string("move-2"),
            "direction": .string("to-worktree"),
            "step": .string("apply-changes-to-worktree"),
            "status": .string("completed"),
        ]),
    ])
}

@Test
func desktopGitWorkerTransfersAndCleansHostHandoffThroughEmbeddedCore()
    async throws
{
    let transferParams: CodexJSONValue = .object([
        "sourceCwd": .string("/source"),
        "sourceBranch": .string("feature/host"),
        "sourceRolloutPath": .string("/source/rollout.jsonl"),
        "destinationWorkspaceRoot": .string("/destination"),
        "destinationWorktreeGitRoot": .null,
        "destinationWorktreeWorkspaceRoot": .null,
        "operationId": .string("host-1"),
    ])
    let cleanupParams: CodexJSONValue = .object([
        "rolloutPath": .string("/codex/handoffs/id/rollout.jsonl"),
        "codexHome": .string("/codex"),
    ])
    let emitted = JSONValueProbe()
    let worker = CodexDesktopGitWorker(
        runWithEnvironment: { _, _, _ in
            Issue.record("Embedded iPad host handoff must not spawn Git")
            return .init(exitCode: 127, stdout: "", stderr: "")
        },
        embeddedReader: { method, received in
            switch method {
            case "move-thread-to-host-worktree":
                #expect(received == transferParams)
                return .object([
                    "status": .string("success"),
                    "rolloutPath": .string(
                        "/codex/handoffs/id/rollout.jsonl"
                    ),
                    "worktreeGitRoot": .string("/worktree"),
                    "worktreeWorkspaceRoot": .string("/worktree"),
                    "_progress": .array([
                        .object([
                            "step": .string("transfer-host-artifacts"),
                            "status": .string("completed"),
                        ]),
                    ]),
                ])
            case "cleanup-host-handoff-transfer":
                #expect(received == cleanupParams)
                return .object(["success": .bool(true)])
            default:
                Issue.record("Unexpected embedded method: \(method)")
                return .null
            }
        }
    )
    let transfer = try await worker.handle(
        .init(
            workerID: "git",
            id: "host-transfer",
            method: "move-thread-to-host-worktree",
            params: transferParams
        ),
        emit: { await emitted.append($0) }
    )
    #expect(transfer == .object([
        "status": .string("success"),
        "rolloutPath": .string("/codex/handoffs/id/rollout.jsonl"),
        "worktreeGitRoot": .string("/worktree"),
        "worktreeWorkspaceRoot": .string("/worktree"),
    ]))
    #expect(await emitted.snapshot() == [
        .object([
            "type": .string("thread-handoff-progress"),
            "operationId": .string("host-1"),
            "direction": .string("to-host-worktree"),
            "step": .string("transfer-host-artifacts"),
            "status": .string("completed"),
        ]),
    ])
    #expect(
        try await worker.handle(.init(
            workerID: "git",
            id: "host-cleanup",
            method: "cleanup-host-handoff-transfer",
            params: cleanupParams
        )) == .object(["success": .bool(true)])
    )
}

@Test
func desktopGitWorkerImplementsCloneCommitAndSubmoduleReads() async throws {
    let runner = GitRunnerProbe(results: [
        .init(exitCode: 0, stdout: "true\n", stderr: ""),
        .init(
            exitCode: 0,
            stdout: "remote.origin.promisor true\n",
            stderr: ""
        ),
        .init(
            exitCode: 0,
            stdout: """
            abc123\u{0}2026-08-02T12:00:00+08:00\u{0}First\u{0}First body\u{1e}
            def456\u{0}2026-08-02T11:00:00+08:00\u{0}Second\u{0}Second body\u{1e}
            """,
            stderr: ""
        ),
        .init(
            exitCode: 0,
            stdout: """
            submodule.Core.path Vendor/Core
            submodule.UI.path Vendor/UI
            submodule.CoreAgain.path Vendor/Core
            """,
            stderr: ""
        ),
    ])
    let worker = CodexDesktopGitWorker {
        try await runner.run(arguments: $0, cwd: $1)
    }

    let clone = try await worker.handle(
        .init(
            workerID: "git",
            id: "clone",
            method: "clone-state",
            params: .object(["root": .string("/workspace")])
        )
    )
    let commits = try await worker.handle(
        .init(
            workerID: "git",
            id: "commits",
            method: "branch-commits",
            params: .object([
                "root": .string("/workspace"),
                "baseBranch": .string("main"),
            ])
        )
    )
    let submodules = try await worker.handle(
        .init(
            workerID: "git",
            id: "submodules",
            method: "submodule-paths",
            params: .object(["root": .string("/workspace")])
        )
    )

    #expect(
        clone == .object([
            "isShallow": .bool(true),
            "isPartialClone": .bool(true),
        ])
    )
    #expect(
        commits == .object([
            "commits": .array([
                .object([
                    "sha": .string("abc123"),
                    "committedAt": .string(
                        "2026-08-02T12:00:00+08:00"
                    ),
                    "subject": .string("First"),
                    "message": .string("First body"),
                ]),
                .object([
                    "sha": .string("def456"),
                    "committedAt": .string(
                        "2026-08-02T11:00:00+08:00"
                    ),
                    "subject": .string("Second"),
                    "message": .string("Second body"),
                ]),
            ])
        ])
    )
    #expect(
        submodules == .object([
            "paths": .array([
                .string("Vendor/Core"),
                .string("Vendor/UI"),
            ])
        ])
    )
}

@Test
func desktopGitWorkerProducesReleasedStatusSummaryShape() async throws {
    let runner = GitRunnerProbe(results: [
        .init(
            exitCode: 0,
            stdout: """
             M README.md
            M  Sources/App.swift
            MM Sources/Shared.swift
            ?? Notes/new.txt
            ?? Notes/second.txt
            """,
            stderr: ""
        )
    ])
    let worker = CodexDesktopGitWorker {
        try await runner.run(arguments: $0, cwd: $1)
    }

    let result = try await worker.handle(
        .init(
            workerID: "git",
            id: "git-status",
            method: "status-summary",
            params: .object([
                "cwd": .string("/workspace"),
                "includeUntrackedFiles": .bool(true),
            ])
        )
    )

    #expect(
        result == .object([
            "type": .string("success"),
            "stagedCount": .integer(2),
            "unstagedCount": .integer(2),
            "untrackedCount": .integer(2),
        ])
    )
    #expect(
        await runner.calls().first?.arguments
            == [
                "git", "-C", "/workspace", "status", "--renames",
                "--porcelain=v1", "--untracked-files=all",
            ]
    )
}

@Test
func desktopGitWorkerResolvesOfficialOriginMetadata() async throws {
    let runner = GitRunnerProbe(results: [
        .init(exitCode: 0, stdout: "/workspace\n", stderr: ""),
        .init(exitCode: 0, stdout: ".git\n", stderr: ""),
        .init(
            exitCode: 0,
            stdout: "https://example.test/org/repo.git\n",
            stderr: ""
        ),
    ])
    let worker = CodexDesktopGitWorker {
        try await runner.run(arguments: $0, cwd: $1)
    }

    let result = try await worker.handle(
        .init(
            workerID: "git",
            id: "git-origins",
            method: "git-origins",
            params: .object([
                "dirs": .array([
                    .string("/workspace"),
                    .string("/workspace"),
                ])
            ])
        )
    )

    #expect(
        result == .object([
            "origins": .array([
                .object([
                    "dir": .string("/workspace"),
                    "root": .string("/workspace"),
                    "originUrl": .string(
                        "https://example.test/org/repo.git"
                    ),
                    "commonDir": .string("/workspace/.git"),
                ])
            ])
        ])
    )
    #expect(await runner.calls().count == 3)
}

@Test
func desktopGitWorkerParsesReleasedWorktreeShape() async throws {
    let runner = GitRunnerProbe(results: [
        .init(
            exitCode: 0,
            stdout: """
            worktree /workspace
            HEAD 0123456789abcdef
            branch refs/heads/main

            worktree /workspace/.codex/worktrees/thread-1
            HEAD fedcba9876543210
            detached
            locked maintenance

            """,
            stderr: ""
        )
    ])
    let worker = CodexDesktopGitWorker {
        try await runner.run(arguments: $0, cwd: $1)
    }

    let result = try await worker.handle(
        .init(
            workerID: "git",
            id: "worktrees",
            method: "list-worktrees",
            params: .object(["cwd": .string("/workspace")])
        )
    )

    #expect(
        result == .object([
            "worktrees": .array([
                .object([
                    "root": .string("/workspace"),
                    "prunable": .bool(false),
                    "locked": .bool(false),
                    "headRef": .object([
                        "sha": .string("0123456789abcdef"),
                        "type": .string("branch"),
                        "string": .string("main"),
                    ]),
                ]),
                .object([
                    "root": .string(
                        "/workspace/.codex/worktrees/thread-1"
                    ),
                    "prunable": .bool(false),
                    "locked": .bool(true),
                    "headRef": .object([
                        "sha": .string("fedcba9876543210"),
                        "type": .string("detached"),
                    ]),
                ]),
            ])
        ])
    )
}

@Test
func desktopGitWorkerCommitsWithReleasedSuccessShape() async throws {
    let runner = GitRunnerProbe(results: [
        .init(exitCode: 0, stdout: "", stderr: ""),
        .init(
            exitCode: 0,
            stdout: "[main abc1234] Finish iPad worker\n",
            stderr: ""
        ),
        .init(exitCode: 0, stdout: "abc123456789\n", stderr: ""),
    ])
    let worker = CodexDesktopGitWorker {
        try await runner.run(arguments: $0, cwd: $1)
    }

    let result = try await worker.handle(
        .init(
            workerID: "git",
            id: "commit",
            method: "commit",
            params: .object([
                "cwd": .string("/workspace"),
                "message": .string("Finish iPad worker"),
                "includeUnstaged": .bool(true),
            ])
        )
    )

    #expect(
        result == .object([
            "status": .string("success"),
            "commitSha": .string("abc123456789"),
        ])
    )
    #expect(
        await runner.calls().map(\.arguments)
            == [
                ["git", "-C", "/workspace", "add", "-A"],
                [
                    "git", "-C", "/workspace", "commit", "-m",
                    "Finish iPad worker",
                ],
                ["git", "-C", "/workspace", "rev-parse", "HEAD"],
            ]
    )
}

@Test
func desktopGitWorkerAppliesPatchAndRemovesTemporaryPatch() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("codexpad-worker-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
        at: root,
        withIntermediateDirectories: true
    )
    defer {
        try? FileManager.default.removeItem(at: root)
    }
    let runner = GitRunnerProbe(results: [
        .init(
            exitCode: 0,
            stdout: "Applied patch to 'README.md' cleanly.\n",
            stderr: ""
        )
    ])
    let worker = CodexDesktopGitWorker {
        try await runner.run(arguments: $0, cwd: $1)
    }
    let diff = """
    diff --git a/README.md b/README.md
    --- a/README.md
    +++ b/README.md
    @@ -1 +1 @@
    -old
    +new
    """

    let result = try await worker.handle(
        .init(
            workerID: "git",
            id: "apply",
            method: "apply-patch",
            params: .object([
                "cwd": .string(root.path),
                "diff": .string(diff),
                "atomic": .bool(false),
                "target": .string("unstaged"),
            ])
        )
    )

    guard case let .object(fields) = result else {
        Issue.record("Missing apply-patch result")
        return
    }
    #expect(fields["status"] == .string("success"))
    #expect(
        fields["appliedPaths"] == .array([.string("README.md")])
    )
    let calls = await runner.calls()
    #expect(calls.count == 1)
    #expect(calls[0].arguments.prefix(5) == [
        "git", "-C", root.path, "apply", "--3way",
    ])
    #expect(
        try FileManager.default.contentsOfDirectory(atPath: root.path)
            .filter { $0.hasPrefix(".codex-apply-") }
            .isEmpty
    )
}

@Test
func desktopGitWorkerCreatesWorkingTreeAndEmitsAllocatedPath() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("codexpad-worktree-\(UUID().uuidString)")
    let source = root.appendingPathComponent("source")
    let worktrees = root.appendingPathComponent("managed")
    try FileManager.default.createDirectory(
        at: source,
        withIntermediateDirectories: true
    )
    defer {
        try? FileManager.default.removeItem(at: root)
    }
    let runner = GitRunnerProbe(results: [
        .init(exitCode: 0, stdout: "", stderr: ""),
        .init(exitCode: 0, stdout: "", stderr: ""),
        .init(exitCode: 0, stdout: "", stderr: ""),
    ])
    let events = JSONValueProbe()
    let worker = CodexDesktopGitWorker {
        try await runner.run(arguments: $0, cwd: $1)
    }

    let result = try await worker.handle(
        .init(
            workerID: "git",
            id: "create-1",
            method: "create-worktree",
            params: .object([
                "cwd": .string(source.path),
                "worktreesRoot": .string(worktrees.path),
                "streamId": .string("stream-1"),
                "hostConfig": .object(["id": .string("local")]),
                "startingState": .object([
                    "type": .string("working-tree")
                ]),
            ])
        ),
        emit: { await events.append($0) }
    )

    guard case let .object(fields) = result,
          case let .string(worktree)? = fields["worktreeGitRoot"]
    else {
        Issue.record("Missing created worktree roots")
        return
    }
    #expect(fields["worktreeWorkspaceRoot"] == .string(worktree))
    #expect(fields["setupError"] == .null)
    #expect(
        await events.snapshot() == [
            .object([
                "type": .string("create-worktree-path"),
                "hostId": .string("local"),
                "streamId": .string("stream-1"),
                "worktreeGitRoot": .string(worktree),
            ])
        ]
    )
    let calls = await runner.calls()
    #expect(calls.count == 3)
    #expect(calls[0].arguments.prefix(5) == [
        "git", "-C", source.path, "worktree", "add",
    ])
    #expect(
        calls[1].arguments
            == ["git", "-C", source.path, "diff", "--binary", "HEAD"]
    )
    #expect(
        calls[2].arguments == [
            "git", "-C", source.path, "ls-files", "--others",
            "--exclude-standard", "-z",
        ]
    )
}

@Test
func desktopGitWorkerCreatesWorkingTreeThroughEmbeddedCoreAndEmitsPath()
    async throws
{
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("codexpad-embedded-worktree-\(UUID().uuidString)")
    let source = root.appendingPathComponent("source")
    let worktrees = root.appendingPathComponent("managed")
    try FileManager.default.createDirectory(
        at: source,
        withIntermediateDirectories: true
    )
    defer {
        try? FileManager.default.removeItem(at: root)
    }
    let events = JSONValueProbe()
    let worker = CodexDesktopGitWorker(
        runWithEnvironment: { _, _, _ in
            Issue.record("Embedded iPad worktree creation must not spawn Git")
            return .init(exitCode: 127, stdout: "", stderr: "")
        },
        embeddedReader: { method, params in
            #expect(method == "create-worktree")
            guard case let .object(fields) = params,
                  fields["cwd"] == .string(source.path),
                  fields["startingState"] == .object([
                      "type": .string("working-tree")
                  ]),
                  case let .string(worktreeRoot)? = fields["worktreeRoot"]
            else {
                throw CodexDesktopWorkerMethodError(
                    "Missing embedded worktree allocation"
                )
            }
            return .object([
                "worktreeGitRoot": .string(worktreeRoot),
                "worktreeWorkspaceRoot": .string(worktreeRoot),
                "setupError": .null,
            ])
        }
    )
    let result = try await worker.handle(
        .init(
            workerID: "git",
            id: "embedded-create",
            method: "create-worktree",
            params: .object([
                "cwd": .string(source.path),
                "worktreesRoot": .string(worktrees.path),
                "streamId": .string("stream-embedded"),
                "hostConfig": .object(["id": .string("local")]),
                "startingState": .object([
                    "type": .string("working-tree")
                ]),
            ])
        ),
        emit: { await events.append($0) }
    )
    guard case let .object(fields) = result,
          case let .string(worktree)? = fields["worktreeGitRoot"]
    else {
        Issue.record("Missing embedded worktree result")
        return
    }
    #expect(fields["worktreeWorkspaceRoot"] == .string(worktree))
    #expect(
        await events.snapshot() == [
            .object([
                "type": .string("create-worktree-path"),
                "hostId": .string("local"),
                "streamId": .string("stream-embedded"),
                "worktreeGitRoot": .string(worktree),
            ])
        ]
    )
}

@Test
func desktopGitWorkerDeletesRestoresAndAssignsWorktreeOwner() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("codexpad-owner-\(UUID().uuidString)")
    let worktree = root.appendingPathComponent("thread-42")
    let gitConfig = root
        .appendingPathComponent("gitdirs/thread-42/codex-thread.json")
    try FileManager.default.createDirectory(
        at: worktree,
        withIntermediateDirectories: true
    )
    defer {
        try? FileManager.default.removeItem(at: root)
    }
    let runner = GitRunnerProbe(results: [
        .init(exitCode: 0, stdout: "", stderr: ""),
        .init(exitCode: 0, stdout: "", stderr: ""),
        .init(exitCode: 0, stdout: "\(gitConfig.path)\n", stderr: ""),
    ])
    let worker = CodexDesktopGitWorker {
        try await runner.run(arguments: $0, cwd: $1)
    }

    let deleted = try await worker.handle(
        .init(
            workerID: "git",
            id: "delete",
            method: "delete-worktree",
            params: .object([
                "worktree": .string(worktree.path),
                "force": .bool(true),
            ])
        )
    )
    let restored = try await worker.handle(
        .init(
            workerID: "git",
            id: "restore",
            method: "restore-worktree",
            params: .object([
                "repoRoot": .string(root.path),
                "worktreePath": .string(worktree.path),
                "cwd": .string(worktree.path),
            ])
        )
    )
    let owned = try await worker.handle(
        .init(
            workerID: "git",
            id: "owner",
            method: "set-worktree-owner-thread",
            params: .object([
                "worktree": .string(worktree.path),
                "conversationId": .string("thread-42"),
            ])
        )
    )

    #expect(
        deleted == .object([
            "success": .bool(true),
            "worktreeId": .string(
                Insecure.SHA1.hash(data: Data(worktree.path.utf8))
                    .map { String(format: "%02x", $0) }
                    .joined()
            ),
        ])
    )
    #expect(restored == .object(["success": .bool(true)]))
    #expect(owned == .object(["success": .bool(true)]))
    let ownerData = try Data(contentsOf: gitConfig)
    let owner = try JSONSerialization.jsonObject(with: ownerData)
        as? [String: Any]
    #expect(owner?["version"] as? Int == 1)
    #expect(owner?["ownerThreadId"] as? String == "thread-42")
}

@Test
func desktopGitWorkerEnumeratesAndResolvesOwnedWorktrees() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("codexpad-resolve-\(UUID().uuidString)")
    let managed = root
        .appendingPathComponent("managed/project/thread-owned")
    let ownerConfig = root
        .appendingPathComponent("gitdirs/thread-owned/codex-thread.json")
    try FileManager.default.createDirectory(
        at: managed,
        withIntermediateDirectories: true
    )
    let canonicalManagedPath = try #require(
        FileManager.default.contentsOfDirectory(
            at: managed.deletingLastPathComponent(),
            includingPropertiesForKeys: nil
        ).first
    ).path
    try FileManager.default.createDirectory(
        at: ownerConfig.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try """
    {
      "version": 1,
      "ownerThreadId": "thread-owned"
    }
    """.write(to: ownerConfig, atomically: true, encoding: .utf8)
    defer {
        try? FileManager.default.removeItem(at: root)
    }
    let runner = GitRunnerProbe(results: [
        .init(
            exitCode: 0,
            stdout: "\(root.path)/gitdirs/thread-owned\n",
            stderr: ""
        ),
        .init(
            exitCode: 0,
            stdout: """
            worktree \(managed.path)
            HEAD abc123
            branch refs/heads/feature

            """,
            stderr: ""
        ),
        .init(
            exitCode: 0,
            stdout: "\(ownerConfig.path)\n",
            stderr: ""
        ),
        .init(exitCode: 0, stdout: " M README.md\n", stderr: ""),
    ])
    let worker = CodexDesktopGitWorker {
        try await runner.run(arguments: $0, cwd: $1)
    }

    let enumerated = try await worker.handle(
        .init(
            workerID: "git",
            id: "enumerate",
            method: "codex-worktrees",
            params: .object([
                "worktreesRoot": .string(
                    root.appendingPathComponent("managed").path
                )
            ])
        )
    )
    let resolved = try await worker.handle(
        .init(
            workerID: "git",
            id: "resolve",
            method: "resolve-worktree-for-thread",
            params: .object([
                "cwd": .string(root.path),
                "conversationId": .string("thread-owned"),
            ])
        )
    )

    #expect(
        enumerated == .object([
            "worktrees": .array([
                .object([
                    "dir": .string(canonicalManagedPath),
                    "gitDir": .string(
                        "\(root.path)/gitdirs/thread-owned"
                    ),
                ])
            ])
        ])
    )
    #expect(
        resolved == .object([
            "worktreeGitRoot": .string(managed.path),
            "worktreeWorkspaceRoot": .string(managed.path),
            "hasUncommittedChanges": .bool(true),
        ])
    )
}

@Test
func desktopGitWorkerImplementsReleasedRepositoryMetadataReads() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("codexpad-metadata-\(UUID().uuidString)")
    let index = root.appendingPathComponent("index")
    try FileManager.default.createDirectory(
        at: root,
        withIntermediateDirectories: true
    )
    try Data("index".utf8).write(to: index)
    defer {
        try? FileManager.default.removeItem(at: root)
    }
    let runner = GitRunnerProbe(results: [
        .init(exitCode: 0, stdout: "0\t3\n", stderr: ""),
        .init(exitCode: 0, stdout: "0\t1\n", stderr: ""),
        .init(exitCode: 0, stdout: "\(root.path)\n", stderr: ""),
        .init(exitCode: 0, stdout: "feature\n", stderr: ""),
        .init(
            exitCode: 0,
            stdout: "refs/heads/main\n",
            stderr: ""
        ),
        .init(exitCode: 0, stdout: "origin\n", stderr: ""),
        .init(
            exitCode: 0,
            stdout: "diff --git a/a b/a\n",
            stderr: ""
        ),
        .init(exitCode: 0, stdout: "\(index.path)\n", stderr: ""),
    ])
    let worker = CodexDesktopGitWorker {
        try await runner.run(arguments: $0, cwd: $1)
    }

    let nearest = try await worker.handle(.init(
        workerID: "git",
        id: "nearest",
        method: "nearest-ancestor-branch",
        params: .object([
            "root": .string(root.path),
            "currentBranch": .string("feature"),
            "candidates": .array([
                .string("feature"),
                .string("main"),
                .string("release"),
                .string("main"),
            ]),
        ])
    ))
    let metadata = try await worker.handle(.init(
        workerID: "git",
        id: "metadata",
        method: "branch-metadata",
        params: .object(["cwd": .string(root.path)])
    ))
    let diff = try await worker.handle(.init(
        workerID: "git",
        id: "diff",
        method: "commit-message-diff",
        params: .object([
            "cwd": .string(root.path),
            "includeUnstaged": .bool(true),
        ])
    ))
    let indexInfo = try await worker.handle(.init(
        workerID: "git",
        id: "index",
        method: "index-info",
        params: .object(["cwd": .string(root.path)])
    ))

    #expect(nearest == .object(["branch": .string("release")]))
    #expect(metadata == .object([
        "gitRoot": .string(root.path),
        "branch": .string("feature"),
        "baseBranch": .string("main"),
        "baseBranchRemote": .string("origin"),
    ]))
    #expect(diff == .object([
        "type": .string("success"),
        "unifiedDiff": .string("diff --git a/a b/a\n"),
        "unifiedDiffBytes": .integer(19),
    ]))
    guard case let .object(indexFields) = indexInfo,
          case let .number(lastModified)? = indexFields["lastModified"]
    else {
        Issue.record("index-info did not return a numeric mtime")
        return
    }
    #expect(lastModified > 0)
}

@Test
func desktopGitWorkerReadsReleasedFileObjectsWithDiskFallback() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("codexpad-cat-file-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
        at: root,
        withIntermediateDirectories: true
    )
    try "disk one\ndisk two\n".write(
        to: root.appendingPathComponent("fallback.txt"),
        atomically: true,
        encoding: .utf8
    )
    defer {
        try? FileManager.default.removeItem(at: root)
    }
    let runner = GitRunnerProbe(results: [
        .init(exitCode: 0, stdout: "git one\ngit two\n", stderr: ""),
        .init(exitCode: 128, stdout: "", stderr: "missing"),
    ])
    let worker = CodexDesktopGitWorker {
        try await runner.run(arguments: $0, cwd: $1)
    }

    let result = try await worker.handle(.init(
        workerID: "git",
        id: "cat",
        method: "cat-file",
        params: .object([
            "cwd": .string(root.path),
            "maxObjectBytes": .integer(1_024),
            "requests": .array([
                .object(["oid": .string("abc123")]),
                .object([
                    "oid": .string("def456"),
                    "fallbackToDisk": .bool(true),
                    "path": .string("fallback.txt"),
                ]),
            ]),
        ])
    ))

    #expect(result == .array([
        .object([
            "type": .string("success"),
            "lines": .array([.string("git one"), .string("git two")]),
        ]),
        .object([
            "type": .string("success"),
            "lines": .array([.string("disk one"), .string("disk two")]),
        ]),
    ]))
}

@Test
func desktopGitWorkerImplementsReleasedReviewPatchDiffAndBlame() async throws {
    let sha = String(repeating: "a", count: 40)
    let runner = GitRunnerProbe(results: [
        .init(exitCode: 0, stdout: "base123\n", stderr: ""),
        .init(exitCode: 0, stdout: "patch\n", stderr: ""),
        .init(exitCode: 0, stdout: "file diff\n", stderr: ""),
        .init(
            exitCode: 0,
            stdout: """
            \(sha) 1 7 1
            author Ada
            author-mail <123+ada@users.noreply.github.com>
            author-time 100
            summary Test commit
            filename Sources/App.swift
            \tlet value = 1

            """,
            stderr: ""
        ),
        .init(
            exitCode: 0,
            stdout: "git@github.com:openai/codex.git\n",
            stderr: ""
        ),
    ])
    let worker = CodexDesktopGitWorker {
        try await runner.run(arguments: $0, cwd: $1)
    }

    let patch = try await worker.handle(.init(
        workerID: "git",
        id: "patch",
        method: "review-patch",
        params: .object([
            "cwd": .string("/repo"),
            "source": .string("branch"),
            "baseBranch": .string("main"),
        ])
    ))
    let diff = try await worker.handle(.init(
        workerID: "git",
        id: "review-diff",
        method: "review-diff",
        params: .object([
            "cwd": .string("/repo"),
            "source": .string("staged"),
            "files": .array([
                .object(["path": .string("Sources/App.swift")])
            ]),
        ])
    ))
    let blame = try await worker.handle(.init(
        workerID: "git",
        id: "blame",
        method: "blame-file",
        params: .object([
            "cwd": .string("/repo"),
            "path": .string("Sources/App.swift"),
        ])
    ))

    #expect(patch == .object([
        "source": .string("branch"),
        "diff": .object([
            "type": .string("success"),
            "unifiedDiff": .string("patch\n"),
            "unifiedDiffBytes": .integer(6),
        ]),
    ]))
    #expect(diff == .object([
        "type": .string("success"),
        "source": .string("staged"),
        "diffs": .object([
            "Sources/App.swift": .object([
                "type": .string("success"),
                "diff": .string("file diff\n"),
                "diffBytes": .integer(10),
            ])
        ]),
    ]))
    #expect(blame == .object([
        "type": .string("success"),
        "lines": .array([
            .object([
                "author": .string("Ada"),
                "authorLogin": .string("ada"),
                "authorTime": .integer(100),
                "commitSha": .string(sha),
                "lineNumber": .integer(7),
                "summary": .string("Test commit"),
            ])
        ]),
        "repositoryWebUrl": .string("https://github.com/openai/codex"),
    ]))
}

@Test
func desktopGitWorkerImplementsReleasedReviewSummaryAndBranchStats() async throws {
    let runner = GitRunnerProbe(results: [
        .init(exitCode: 0, stdout: "base123\n", stderr: ""),
        .init(
            exitCode: 0,
            stdout: "3\t1\tSources/App.swift\n2\t0\tREADME.md\n",
            stderr: ""
        ),
        .init(
            exitCode: 0,
            stdout: "M\tSources/App.swift\n",
            stderr: ""
        ),
        .init(
            exitCode: 0,
            stdout: "3\t1\tSources/App.swift\n",
            stderr: ""
        ),
        .init(
            exitCode: 0,
            stdout: """
            :100644 100644 1111111111111111111111111111111111111111 2222222222222222222222222222222222222222 M\tSources/App.swift

            """,
            stderr: ""
        ),
        .init(
            exitCode: 0,
            stdout: "M  Sources/App.swift\n M README.md\n",
            stderr: ""
        ),
    ])
    let worker = CodexDesktopGitWorker {
        try await runner.run(arguments: $0, cwd: $1)
    }

    let stats = try await worker.handle(.init(
        workerID: "git",
        id: "stats",
        method: "branch-diff-stats",
        params: .object([
            "cwd": .string("/repo"),
            "baseBranch": .string("main"),
            "includeUntrackedFiles": .bool(false),
        ])
    ))
    let summary = try await worker.handle(.init(
        workerID: "git",
        id: "summary",
        method: "review-summary",
        params: .object([
            "cwd": .string("/repo"),
            "source": .string("staged"),
            "includeUntrackedFiles": .bool(false),
        ])
    ))

    #expect(stats == .object([
        "additions": .integer(5),
        "deletions": .integer(1),
        "fileCount": .integer(2),
    ]))
    guard case let .object(fields) = summary,
          case .string("success")? = fields["type"],
          case .string("staged")? = fields["source"],
          case let .integer(generation)? = fields["snapshotGeneration"]
    else {
        Issue.record("review-summary did not return the released shape")
        return
    }
    #expect(generation > 0)
    #expect(fields["files"] == .array([
        .object([
            "additions": .integer(3),
            "changeKind": .string("modified"),
            "deletions": .integer(1),
            "path": .string("Sources/App.swift"),
            "previousPath": .null,
            "revision": .string(
                "staged:M:100644:"
                    + "1111111111111111111111111111111111111111:"
                    + "100644:"
                    + "2222222222222222222222222222222222222222"
            ),
        ])
    ]))
    #expect(fields["stageCounts"] == .object([
        "stagedFileCount": .integer(1),
        "unstagedFileCount": .integer(1),
        "untrackedFileCount": .integer(0),
    ]))
}

@Test
func desktopGitWorkerImplementsReleasedReviewSearch() async throws {
    let runner = GitRunnerProbe(results: [
        .init(
            exitCode: 0,
            stdout: """
            diff --git a/Sources/App.swift b/Sources/App.swift
            --- a/Sources/App.swift
            +++ b/Sources/App.swift
            @@ -10,2 +10,2 @@
            -old value
            +new needle value
             context needle

            """,
            stderr: ""
        )
    ])
    let worker = CodexDesktopGitWorker {
        try await runner.run(arguments: $0, cwd: $1)
    }

    let result = try await worker.handle(.init(
        workerID: "git",
        id: "search",
        method: "review-search",
        params: .object([
            "cwd": .string("/repo"),
            "source": .string("staged"),
            "query": .string(" needle "),
        ])
    ))

    guard case let .object(fields) = result,
          case .string("success")? = fields["type"],
          case .string("needle")? = fields["query"],
          case .integer(2)? = fields["totalMatches"],
          case .bool(false)? = fields["isCapped"],
          case let .array(matches)? = fields["matches"]
    else {
        Issue.record("review-search did not return the released shape")
        return
    }
    #expect(matches.count == 2)
    for match in matches {
        guard case let .object(value) = match else {
            Issue.record("review-search match was not an object")
            continue
        }
        #expect(value["path"] == .string("Sources/App.swift"))
        #expect(value["hunkId"] == .string("0"))
        #expect(value["lineStart"] == .integer(10))
        #expect(value["lineEnd"] == .integer(11))
    }
}

@Test
func desktopGitWorkerImplementsStableMetadataAndSyncedBranch() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("codexpad-synced-\(UUID().uuidString)")
    let gitDir = root.appendingPathComponent(".git/worktrees/ipad")
    try FileManager.default.createDirectory(
        at: gitDir,
        withIntermediateDirectories: true
    )
    try """
    {
      "branch": "refs/heads/codex/ipad",
      "lastSyncedTreeRef": "tree123"
    }
    """.write(
        to: gitDir.appendingPathComponent("codex-synced-branch.json"),
        atomically: true,
        encoding: .utf8
    )
    defer {
        try? FileManager.default.removeItem(at: root)
    }
    let runner = GitRunnerProbe(results: [
        .init(exitCode: 0, stdout: "\(root.path)\n", stderr: ""),
        .init(exitCode: 0, stdout: ".git\n", stderr: ""),
        .init(exitCode: 0, stdout: "\(gitDir.path)\n", stderr: ""),
        .init(
            exitCode: 0,
            stdout: "100644 abc 1\tSources/App.swift\u{0}",
            stderr: ""
        ),
    ])
    let worker = CodexDesktopGitWorker {
        try await runner.run(arguments: $0, cwd: $1)
    }

    let metadata = try await worker.handle(.init(
        workerID: "git",
        id: "stable",
        method: "stable-metadata",
        params: .object(["cwd": .string(root.path)])
    ))
    let synced = try await worker.handle(.init(
        workerID: "git",
        id: "synced",
        method: "synced-branch",
        params: .object(["cwd": .string(root.path)])
    ))

    #expect(metadata == .object([
        "commonDir": .string(root.appendingPathComponent(".git").path),
        "root": .string(root.path),
    ]))
    #expect(synced == .object([
        "branch": .string("codex/ipad"),
        "base": .string("tree123"),
        "hasConflicts": .bool(true),
    ]))
}

@Test
func desktopGitWorkerImplementsSyncedBranchState() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("codexpad-synced-state-\(UUID().uuidString)")
    let gitDir = root.appendingPathComponent(".git/worktrees/ipad")
    try FileManager.default.createDirectory(
        at: gitDir,
        withIntermediateDirectories: true
    )
    try """
    {
      "branch": "refs/heads/codex/ipad",
      "lastSyncedTreeRef": "tree123"
    }
    """.write(
        to: gitDir.appendingPathComponent("codex-synced-branch.json"),
        atomically: true,
        encoding: .utf8
    )
    defer {
        try? FileManager.default.removeItem(at: root)
    }
    let runner = GitRunnerProbe(results: [
        .init(exitCode: 0, stdout: "\(gitDir.path)\n", stderr: ""),
        .init(exitCode: 0, stdout: "\(root.path)\n", stderr: ""),
        .init(exitCode: 0, stdout: "worktreeHead\n", stderr: ""),
        .init(exitCode: 0, stdout: "branchHead\n", stderr: ""),
        .init(
            exitCode: 0,
            stdout: """
            worktree \(root.path)
            HEAD worktreeHead
            detached

            """,
            stderr: ""
        ),
        .init(exitCode: 0, stdout: "2\t3\n", stderr: ""),
        .init(
            exitCode: 0,
            stdout: "4\t1\tSources/App.swift\n",
            stderr: ""
        ),
    ])
    let worker = CodexDesktopGitWorker {
        try await runner.run(arguments: $0, cwd: $1)
    }

    let state = try await worker.handle(.init(
        workerID: "git",
        id: "synced-state",
        method: "synced-branch-state",
        params: .object(["cwd": .string(root.path)])
    ))

    #expect(state == .object([
        "branch": .string("refs/heads/codex/ipad"),
        "worktreeSnapshot": .object([
            "root": .string(root.path),
            "headCommitSha": .string("worktreeHead"),
        ]),
        "branchSnapshot": .object([
            "checkedOut": .bool(false),
            "headCommitSha": .string("branchHead"),
        ]),
        "localCommitsAhead": .integer(2),
        "worktreeCommitsAhead": .integer(3),
        "localUncommittedDiffStats": .object([
            "leftRef": .string("branchHead"),
            "rightRef": .string("branchHead"),
            "filesChanged": .integer(0),
            "linesAdded": .integer(0),
            "linesRemoved": .integer(0),
        ]),
        "worktreeUncommittedDiffStats": .object([
            "leftRef": .string("worktreeHead"),
            "rightRef": .string("WORKTREE"),
            "filesChanged": .integer(1),
            "linesAdded": .integer(4),
            "linesRemoved": .integer(1),
        ]),
    ]))
}

@Test
func desktopGitWorkerResolvesManagedWorktreeSnapshotState() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("codexpad-managed-root-\(UUID().uuidString)")
    let missingWorktree = root
        .deletingLastPathComponent()
        .appendingPathComponent("codexpad-missing-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
        at: root,
        withIntermediateDirectories: true
    )
    defer {
        try? FileManager.default.removeItem(at: root)
    }
    let worktreePath = (missingWorktree.path as NSString).standardizingPath
    let worktreeID = Insecure.SHA1.hash(data: Data(worktreePath.utf8))
        .map { String(format: "%02x", $0) }
        .joined()
    let snapshotRef = "refs/codex/snapshots/\(worktreeID)"
    let runner = GitRunnerProbe(results: [
        .init(exitCode: 0, stdout: "\(root.path)\n", stderr: ""),
        .init(exitCode: 0, stdout: ".git\n", stderr: ""),
        .init(exitCode: 0, stdout: "snapshotCommit\n", stderr: ""),
        .init(exitCode: 0, stdout: "\(root.path)\n", stderr: ""),
        .init(exitCode: 0, stdout: ".git\n", stderr: ""),
        .init(exitCode: 0, stdout: "snapshotCommit\n", stderr: ""),
    ])
    let worker = CodexDesktopGitWorker {
        try await runner.run(arguments: $0, cwd: $1)
    }
    let params: CodexJSONValue = .object([
        "candidateRoots": .array([.string(root.path)]),
        "worktreePath": .string(worktreePath),
    ])

    let snapshot = try await worker.handle(.init(
        workerID: "git",
        id: "snapshot-ref",
        method: "worktree-snapshot-ref",
        params: params
    ))
    let managed = try await worker.handle(.init(
        workerID: "git",
        id: "managed-state",
        method: "managed-worktree-state",
        params: .object([
            "candidateRoots": .array([.string(root.path)]),
            "cwd": .string(worktreePath),
            "worktreePath": .string(worktreePath),
        ])
    ))
    let expectedSnapshot: CodexJSONValue = .object([
        "snapshotRef": .string(snapshotRef),
        "worktreeId": .string(worktreeID),
        "repoRoot": .string(root.path),
        "commonDir": .string(root.appendingPathComponent(".git").path),
        "exists": .bool(true),
        "commitSha": .string("snapshotCommit"),
    ])

    #expect(snapshot == expectedSnapshot)
    #expect(managed == .object([
        "kind": .string("restorable"),
        "snapshot": expectedSnapshot,
    ]))
}

@Test
func desktopGitWorkerClassifiesManagedWorktreeAvailability() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("codexpad-managed-live-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
        at: root,
        withIntermediateDirectories: true
    )
    defer {
        try? FileManager.default.removeItem(at: root)
    }
    let worker = CodexDesktopGitWorker { _, _ in
        Issue.record("Availability classification must not invoke git")
        return .init(exitCode: 1, stdout: "", stderr: "")
    }

    let available = try await worker.handle(.init(
        workerID: "git",
        id: "managed-available",
        method: "managed-worktree-state",
        params: .object([
            "candidateRoots": .array([]),
            "cwd": .string(root.path),
            "worktreePath": .string(root.path),
        ])
    ))
    let unavailable = try await worker.handle(.init(
        workerID: "git",
        id: "managed-unavailable",
        method: "managed-worktree-state",
        params: .object([
            "candidateRoots": .array([]),
            "cwd": .string(root.appendingPathComponent("missing").path),
            "worktreePath": .string(root.appendingPathComponent("missing").path),
        ])
    ))

    #expect(available == .object(["kind": .string("available")]))
    #expect(unavailable == .object([
        "kind": .string("unavailable"),
        "reason": .string("no-candidate-roots"),
    ]))
}

@Test
func desktopGitWorkerCapturesAndCompletesTurnDiffs() async throws {
    let runner = GitRunnerProbe(results: [
        .init(exitCode: 0, stdout: "/repo\n", stderr: ""),
        .init(exitCode: 0, stdout: "", stderr: ""),
        .init(exitCode: 0, stdout: "", stderr: ""),
        .init(exitCode: 0, stdout: "baseTree\n", stderr: ""),
        .init(exitCode: 0, stdout: "", stderr: ""),
        .init(exitCode: 0, stdout: "sessionCommit\n", stderr: ""),
        .init(exitCode: 0, stdout: "session diff\n", stderr: ""),
        .init(exitCode: 0, stdout: "", stderr: ""),
        .init(exitCode: 0, stdout: "", stderr: ""),
        .init(exitCode: 0, stdout: "headTree\n", stderr: ""),
        .init(exitCode: 0, stdout: "", stderr: ""),
        .init(exitCode: 0, stdout: "turn diff\n", stderr: ""),
        .init(exitCode: 0, stdout: "", stderr: ""),
        .init(exitCode: 0, stdout: "", stderr: ""),
    ])
    let worker = CodexDesktopGitWorker {
        try await runner.run(arguments: $0, cwd: $1)
    }

    let capture = try await worker.handle(.init(
        workerID: "git",
        id: "turn-start",
        method: "turn-diff-capture-start",
        params: .object([
            "checkpointKey": .string("thread-1"),
            "cwd": .string("/repo"),
            "turnId": .string("turn-1"),
        ])
    ))
    guard case let .object(captureFields) = capture,
          case let .string(refPrefix)? = captureFields["refPrefix"],
          case let .string(checkpointRef)? =
              captureFields["checkpointRefPrefix"]
    else {
        Issue.record("turn-diff-capture-start did not return a capture")
        return
    }
    #expect(refPrefix.hasPrefix("refs/codex/turn-diffs/captures/"))
    #expect(
        checkpointRef.hasPrefix("refs/codex/turn-diffs/checkpoints/")
    )
    #expect(captureFields["baseTreeSha"] == .string("baseTree"))
    #expect(captureFields["sessionStartCommitSha"] == .string("sessionCommit"))
    #expect(captureFields["sessionStartDiff"] == .object([
        "type": .string("success"),
        "unifiedDiff": .string("session diff\n"),
        "unifiedDiffBytes": .integer(13),
    ]))

    let completed = try await worker.handle(.init(
        workerID: "git",
        id: "turn-complete",
        method: "turn-diff-capture-complete",
        params: .object([
            "capture": capture,
            "retainCheckpoint": .bool(false),
        ])
    ))
    #expect(completed == .object([
        "baseTreeSha": .string("baseTree"),
        "baseTurnHeadTreeSha": .null,
        "betweenTurnDiff": .null,
        "sessionStartCommitSha": .string("sessionCommit"),
        "sessionStartDiff": .object([
            "type": .string("success"),
            "unifiedDiff": .string("session diff\n"),
            "unifiedDiffBytes": .integer(13),
        ]),
        "headTreeSha": .string("headTree"),
        "diff": .object([
            "type": .string("success"),
            "unifiedDiff": .string("turn diff\n"),
            "unifiedDiffBytes": .integer(10),
        ]),
    ]))
}

@Test
func desktopGitWorkerSnapshotsDirtyTreesAndLinksTurnCheckpoints()
    async throws
{
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(
            "codexpad-turn-snapshot-\(UUID().uuidString)"
        )
    try FileManager.default.createDirectory(
        at: root,
        withIntermediateDirectories: true
    )
    defer {
        try? FileManager.default.removeItem(at: root)
    }
    func git(_ arguments: [String]) throws -> String {
        let result = try runWorkerCommand(
            arguments: ["git", "-C", root.path] + arguments,
            cwd: root.path
        )
        guard result.exitCode == 0 else {
            throw CodexDesktopWorkerMethodError(result.stderr)
        }
        return result.stdout.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
    }
    func field(
        _ value: CodexJSONValue,
        _ key: String
    ) -> CodexJSONValue? {
        guard case let .object(fields) = value else {
            return nil
        }
        return fields[key]
    }
    func unifiedDiff(_ value: CodexJSONValue?) -> String? {
        guard case let .object(fields)? = value,
              fields["type"] == .string("success"),
              case let .string(diff)? = fields["unifiedDiff"]
        else {
            return nil
        }
        return diff
    }

    _ = try git(["init", "-b", "main"])
    _ = try git(["config", "user.name", "Codex Test"])
    _ = try git(["config", "user.email", "codex@example.invalid"])
    let readme = root.appendingPathComponent("README.md")
    try "base\n".write(to: readme, atomically: true, encoding: .utf8)
    _ = try git(["add", "README.md"])
    _ = try git(["commit", "-m", "base"])
    try "session file\n".write(
        to: root.appendingPathComponent("SESSION.md"),
        atomically: true,
        encoding: .utf8
    )
    let worker = CodexDesktopGitWorker(
        runWithEnvironment: { arguments, cwd, environment in
            try runWorkerCommand(
                arguments: arguments,
                cwd: cwd,
                environment: environment
            )
        }
    )

    let firstCapture = try await worker.handle(.init(
        workerID: "git",
        id: "turn-one-start",
        method: "turn-diff-capture-start",
        params: .object([
            "checkpointKey": .string("thread-real"),
            "cwd": .string(root.path),
            "turnId": .string("turn-one"),
        ])
    ))
    guard case let .string(firstBase)? = field(
        firstCapture,
        "baseTreeSha"
    ) else {
        Issue.record("Missing first working tree snapshot")
        return
    }
    #expect(
        unifiedDiff(field(firstCapture, "sessionStartDiff"))?
            .contains("SESSION.md") == true
    )
    try "turn one\n".write(
        to: readme,
        atomically: true,
        encoding: .utf8
    )
    try "created in turn\n".write(
        to: root.appendingPathComponent("TURN.md"),
        atomically: true,
        encoding: .utf8
    )
    let firstComplete = try await worker.handle(.init(
        workerID: "git",
        id: "turn-one-complete",
        method: "turn-diff-capture-complete",
        params: .object([
            "capture": firstCapture,
            "retainCheckpoint": .bool(true),
        ])
    ))
    guard case let .string(firstHead)? = field(
        firstComplete,
        "headTreeSha"
    ) else {
        Issue.record("Missing first turn head tree")
        return
    }
    #expect(firstHead != firstBase)
    let firstDiff = unifiedDiff(field(firstComplete, "diff"))
    #expect(firstDiff?.contains("README.md") == true)
    #expect(firstDiff?.contains("TURN.md") == true)

    try "between turns\n".write(
        to: root.appendingPathComponent("BETWEEN.md"),
        atomically: true,
        encoding: .utf8
    )
    let secondCapture = try await worker.handle(.init(
        workerID: "git",
        id: "turn-two-start",
        method: "turn-diff-capture-start",
        params: .object([
            "baseTurnId": .string("turn-one"),
            "checkpointKey": .string("thread-real"),
            "cwd": .string(root.path),
            "turnId": .string("turn-two"),
        ])
    ))
    #expect(
        field(secondCapture, "baseTurnHeadTreeSha")
            == .string(firstHead)
    )
    #expect(field(secondCapture, "sessionStartCommitSha") == .null)
    #expect(field(secondCapture, "sessionStartDiff") == .null)
    let secondComplete = try await worker.handle(.init(
        workerID: "git",
        id: "turn-two-complete",
        method: "turn-diff-capture-complete",
        params: .object([
            "capture": secondCapture,
            "retainCheckpoint": .bool(false),
        ])
    ))
    #expect(
        unifiedDiff(field(secondComplete, "betweenTurnDiff"))?
            .contains("BETWEEN.md") == true
    )
    #expect(unifiedDiff(field(secondComplete, "diff")) == "")
    #expect(try git(["diff", "--cached", "--name-only"]).isEmpty)
    let status = try git(["status", "--porcelain"])
        #expect(status.contains("M README.md"))
    #expect(status.contains("?? SESSION.md"))
    #expect(status.contains("?? TURN.md"))
    #expect(status.contains("?? BETWEEN.md"))
    #expect(
        try git([
            "for-each-ref",
            "--format=%(refname)",
            "refs/codex/turn-diffs/captures",
        ]).isEmpty
    )
}

@Test
func desktopGitWorkerAppliesChangesFromReleasedTreeRefs() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("codexpad-apply-changes-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
        at: root,
        withIntermediateDirectories: true
    )
    defer {
        try? FileManager.default.removeItem(at: root)
    }
    let diff = """
    diff --git a/Sources/App.swift b/Sources/App.swift
    --- a/Sources/App.swift
    +++ b/Sources/App.swift
    @@ -1 +1 @@
    -old
    +new
    """
    let runner = GitRunnerProbe(results: [
        .init(exitCode: 0, stdout: "base123\n", stderr: ""),
        .init(exitCode: 1, stdout: diff, stderr: ""),
        .init(exitCode: 0, stdout: "", stderr: ""),
        .init(exitCode: 0, stdout: "", stderr: ""),
        .init(exitCode: 0, stdout: "", stderr: ""),
    ])
    let worker = CodexDesktopGitWorker {
        try await runner.run(arguments: $0, cwd: $1)
    }

    let result = try await worker.handle(
        .init(
            workerID: "git",
            id: "apply-changes",
            method: "apply-changes",
            params: .object([
                "sourceHeadRef": .string("source-head"),
                "sourceTreeRef": .string("source-tree"),
                "destinationRoot": .string(root.path),
                "destinationHeadRef": .string("destination-head"),
            ])
        )
    )

    #expect(result == .object(["status": .string("success")]))
    let calls = await runner.calls()
    #expect(
        calls.map(\.arguments).prefix(2)
            == [
                [
                    "git", "-C", root.path, "merge-base",
                    "source-head", "destination-head",
                ],
                [
                    "git", "-C", root.path, "diff", "--binary",
                    "--full-index", "base123", "source-tree",
                ],
            ]
    )
    #expect(calls[2].arguments == [
        "git", "-C", root.path, "diff", "--cached", "--binary",
        "--full-index",
    ])
    #expect(calls[3].arguments.prefix(6) == [
        "git", "-C", root.path, "apply", "--binary", "--3way",
    ])
    #expect(calls[4].arguments == [
        "git", "-C", root.path, "reset", "--mixed", "HEAD",
    ])
    #expect(
        try FileManager.default.contentsOfDirectory(atPath: root.path)
            .filter { $0.hasPrefix(".codex-apply-") }
            .isEmpty
    )
}

@Test
func desktopGitWorkerAppliesReleasedReviewSectionActions() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("codexpad-review-action-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
        at: root,
        withIntermediateDirectories: true
    )
    defer {
        try? FileManager.default.removeItem(at: root)
    }
    let diff = """
    diff --git a/README.md b/README.md
    --- a/README.md
    +++ b/README.md
    @@ -1 +1 @@
    -before
    +after
    """
    let revision =
        "unstaged:M:100644:1111111111111111111111111111111111111111:"
        + "100644:2222222222222222222222222222222222222222"
    let runner = GitRunnerProbe(results: [
        .init(exitCode: 0, stdout: "\(root.path)\n", stderr: ""),
        .init(
            exitCode: 0,
            stdout: """
            :100644 100644 1111111111111111111111111111111111111111 2222222222222222222222222222222222222222 M\tREADME.md

            """,
            stderr: ""
        ),
        .init(exitCode: 0, stdout: diff, stderr: ""),
        .init(exitCode: 0, stdout: "", stderr: ""),
    ])
    let worker = CodexDesktopGitWorker {
        try await runner.run(arguments: $0, cwd: $1)
    }

    let result = try await worker.handle(
        .init(
            workerID: "git",
            id: "stage-review",
            method: "apply-review-section-changes",
            params: .object([
                "action": .string("stage"),
                "cwd": .string(root.path),
                "source": .string("unstaged"),
                "files": .array([
                    .object([
                        "path": .string("README.md"),
                        "revision": .string(revision),
                        "changeKind": .string("modified"),
                    ])
                ]),
            ])
        )
    )

    guard case let .object(fields) = result else {
        Issue.record("Missing review action result")
        return
    }
    #expect(fields["status"] == .string("success"))
    #expect(fields["appliedPaths"] == .array([.string("README.md")]))
    let calls = await runner.calls()
    #expect(calls[0].arguments == [
        "git", "-C", root.path, "rev-parse", "--show-toplevel",
    ])
    #expect(calls[1].arguments == [
        "git", "-C", root.path, "diff", "--raw", "--no-abbrev",
        "--", "README.md",
    ])
    #expect(calls[2].arguments == [
        "git", "-C", root.path, "diff", "--binary", "--full-index",
        "--", "README.md",
    ])
    #expect(calls[3].arguments.contains("--cached"))
}

@Test
func desktopGitWorkerUsesExactRevisionsForUntrackedReviewActions()
    async throws
{
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(
            "codexpad-untracked-review-\(UUID().uuidString)"
        )
    try FileManager.default.createDirectory(
        at: root,
        withIntermediateDirectories: true
    )
    defer {
        try? FileManager.default.removeItem(at: root)
    }
    func git(_ arguments: [String]) throws -> String {
        let result = try runWorkerCommand(
            arguments: ["git", "-C", root.path] + arguments,
            cwd: root.path
        )
        guard result.exitCode == 0 else {
            throw CodexDesktopWorkerMethodError(result.stderr)
        }
        return result.stdout.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
    }
    func revision(
        _ summary: CodexJSONValue,
        path: String
    ) -> String? {
        guard case let .object(fields) = summary,
              case let .array(files)? = fields["files"]
        else {
            return nil
        }
        for value in files {
            guard case let .object(file) = value,
                  file["path"] == .string(path),
                  case let .string(value)? = file["revision"]
            else {
                continue
            }
            return value
        }
        return nil
    }
    func requestFile(
        path: String,
        revision: String
    ) -> CodexJSONValue {
        .object([
            "path": .string(path),
            "revision": .string(revision),
            "changeKind": .string("untracked"),
        ])
    }

    _ = try git(["init", "-b", "main"])
    _ = try git(["config", "user.name", "Codex Test"])
    _ = try git(["config", "user.email", "codex@example.invalid"])
    let readme = root.appendingPathComponent("README.md")
    try "base\n".write(to: readme, atomically: true, encoding: .utf8)
    _ = try git(["add", "README.md"])
    _ = try git(["commit", "-m", "base"])
    let draft = root.appendingPathComponent("DRAFT.md")
    try "first\n".write(to: draft, atomically: true, encoding: .utf8)
    let worker = CodexDesktopGitWorker { arguments, cwd in
        try runWorkerCommand(arguments: arguments, cwd: cwd)
    }
    func summary() async throws -> CodexJSONValue {
        try await worker.handle(.init(
            workerID: "git",
            id: UUID().uuidString,
            method: "review-summary",
            params: .object([
                "cwd": .string(root.path),
                "source": .string("unstaged"),
                "includeUntrackedFiles": .bool(true),
            ])
        ))
    }
    func apply(
        action: String,
        path: String,
        revision: String
    ) async throws -> CodexJSONValue {
        try await worker.handle(.init(
            workerID: "git",
            id: UUID().uuidString,
            method: "apply-review-section-changes",
            params: .object([
                "action": .string(action),
                "cwd": .string(root.path),
                "source": .string("unstaged"),
                "files": .array([
                    requestFile(path: path, revision: revision)
                ]),
            ])
        ))
    }

    let firstSummary = try await summary()
    guard let firstRevision = revision(firstSummary, path: "DRAFT.md")
    else {
        Issue.record("Missing exact untracked revision")
        return
    }
    #expect(
        firstRevision.range(
            of: #"^untracked:100644:[0-9a-f]{40,64}$"#,
            options: .regularExpression
        ) != nil
    )
    try "changed\n".write(
        to: draft,
        atomically: true,
        encoding: .utf8
    )
    let stale = try await apply(
        action: "stage",
        path: "DRAFT.md",
        revision: firstRevision
    )
    guard case let .object(staleFields) = stale else {
        Issue.record("Missing stale revision result")
        return
    }
    #expect(staleFields["status"] == .string("error"))
    #expect(try git(["diff", "--cached", "--name-only"]).isEmpty)

    let refreshed = try await summary()
    guard let refreshedRevision = revision(refreshed, path: "DRAFT.md")
    else {
        Issue.record("Missing refreshed untracked revision")
        return
    }
    #expect(refreshedRevision != firstRevision)
    let staged = try await apply(
        action: "stage",
        path: "DRAFT.md",
        revision: refreshedRevision
    )
    guard case let .object(stagedFields) = staged else {
        Issue.record("Missing untracked stage result")
        return
    }
    #expect(stagedFields["status"] == .string("success"))
    #expect(try git(["diff", "--cached", "--name-only"]) == "DRAFT.md")
    #expect(
        try git(["show", ":DRAFT.md"]) == "changed"
    )

    let disposable = root.appendingPathComponent("DISPOSABLE.md")
    try "remove me\n".write(
        to: disposable,
        atomically: true,
        encoding: .utf8
    )
    let disposableSummary = try await summary()
    guard let disposableRevision = revision(
        disposableSummary,
        path: "DISPOSABLE.md"
    ) else {
        Issue.record("Missing disposable untracked revision")
        return
    }
    let reverted = try await apply(
        action: "revert",
        path: "DISPOSABLE.md",
        revision: disposableRevision
    )
    guard case let .object(revertedFields) = reverted else {
        Issue.record("Missing untracked revert result")
        return
    }
    #expect(revertedFields["status"] == .string("success"))
    #expect(!FileManager.default.fileExists(atPath: disposable.path))
    #expect(try git(["diff", "--cached", "--name-only"]) == "DRAFT.md")
}

@Test
func desktopGitWorkerOverwritesReleasedSyncedBranch() async throws {
    let runner = GitRunnerProbe(results: [
        .init(exitCode: 0, stdout: "tree123\n", stderr: ""),
        .init(exitCode: 0, stdout: "", stderr: ""),
    ])
    let worker = CodexDesktopGitWorker {
        try await runner.run(arguments: $0, cwd: $1)
    }

    let result = try await worker.handle(
        .init(
            workerID: "git",
            id: "overwrite",
            method: "overwrite-repo",
            params: .object([
                "gitRoot": .string("/source"),
                "targetRoot": .null,
                "branchName": .string("codex/synced"),
                "headCommitSha": .string("commit123"),
                "treeSha": .string("tree123"),
                "targetCurrentBranch": .null,
            ])
        )
    )

    #expect(result == .object(["status": .string("success")]))
    #expect(
        await runner.calls().map(\.arguments)
            == [
                [
                    "git", "-C", "/source", "rev-parse", "--verify",
                    "commit123^{tree}",
                ],
                [
                    "git", "-C", "/source", "branch", "-f",
                    "codex/synced", "commit123",
                ],
            ]
    )
}

@Test
func desktopGitWorkerAppliesChangesInRealRepository() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("codexpad-real-apply-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
        at: root,
        withIntermediateDirectories: true
    )
    defer {
        try? FileManager.default.removeItem(at: root)
    }
    func git(_ arguments: [String]) throws -> String {
        let result = try runWorkerCommand(
            arguments: ["git", "-C", root.path] + arguments,
            cwd: root.path
        )
        guard result.exitCode == 0 else {
            throw CodexDesktopWorkerMethodError(result.stderr)
        }
        return result.stdout.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
    }
    _ = try git(["init", "-b", "main"])
    _ = try git(["config", "user.name", "Codex Test"])
    _ = try git(["config", "user.email", "codex@example.invalid"])
    let file = root.appendingPathComponent("README.md")
    try "base\n".write(to: file, atomically: true, encoding: .utf8)
    _ = try git(["add", "README.md"])
    _ = try git(["commit", "-m", "base"])
    let base = try git(["rev-parse", "HEAD"])
    _ = try git(["checkout", "-b", "source"])
    try "source change\n".write(
        to: file,
        atomically: true,
        encoding: .utf8
    )
    _ = try git(["commit", "-am", "source"])
    let sourceHead = try git(["rev-parse", "HEAD"])
    let sourceTree = try git(["rev-parse", "HEAD^{tree}"])
    _ = try git(["checkout", "main"])
    let stagedFile = root.appendingPathComponent("LOCAL.md")
    try "keep staged\n".write(
        to: stagedFile,
        atomically: true,
        encoding: .utf8
    )
    _ = try git(["add", "LOCAL.md"])

    let worker = CodexDesktopGitWorker { arguments, cwd in
        try runWorkerCommand(arguments: arguments, cwd: cwd)
    }
    let result = try await worker.handle(
        .init(
            workerID: "git",
            id: "real-apply",
            method: "apply-changes",
            params: .object([
                "sourceHeadRef": .string(sourceHead),
                "sourceTreeRef": .string(sourceTree),
                "destinationRoot": .string(root.path),
                "destinationHeadRef": .string(base),
            ])
        )
    )

    #expect(result == .object(["status": .string("success")]))
    #expect(
        try String(contentsOf: file, encoding: .utf8) == "source change\n"
    )
    #expect(try git(["diff", "--name-only"]) == "README.md")
    #expect(try git(["diff", "--cached", "--name-only"]) == "LOCAL.md")
}

@Test
func desktopGitWorkerMovesThreadChangesToLocalCheckout() async throws {
    let sandbox = FileManager.default.temporaryDirectory
        .appendingPathComponent("codexpad-move-local-\(UUID().uuidString)")
    let root = sandbox.appendingPathComponent("repo")
    let source = sandbox.appendingPathComponent("source-worktree")
    try FileManager.default.createDirectory(
        at: root,
        withIntermediateDirectories: true
    )
    defer {
        try? FileManager.default.removeItem(at: sandbox)
    }
    func git(_ cwd: URL, _ arguments: [String]) throws -> String {
        let result = try runWorkerCommand(
            arguments: ["git", "-C", cwd.path] + arguments,
            cwd: cwd.path
        )
        guard result.exitCode == 0 else {
            throw CodexDesktopWorkerMethodError(result.stderr)
        }
        return result.stdout.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
    }
    _ = try git(root, ["init", "-b", "main"])
    _ = try git(root, ["config", "user.name", "Codex Test"])
    _ = try git(
        root,
        ["config", "user.email", "codex@example.invalid"]
    )
    let readme = root.appendingPathComponent("README.md")
    try "base\n".write(to: readme, atomically: true, encoding: .utf8)
    _ = try git(root, ["add", "README.md"])
    _ = try git(root, ["commit", "-m", "base"])
    _ = try git(root, ["branch", "feature"])
    _ = try git(
        root,
        ["worktree", "add", source.path, "feature"]
    )
    try "moved change\n".write(
        to: source.appendingPathComponent("README.md"),
        atomically: true,
        encoding: .utf8
    )
    try "new file\n".write(
        to: source.appendingPathComponent("NOTES.md"),
        atomically: true,
        encoding: .utf8
    )
    let events = JSONValueProbe()
    let worker = CodexDesktopGitWorker { arguments, cwd in
        try runWorkerCommand(arguments: arguments, cwd: cwd)
    }

    let result = try await worker.handle(
        .init(
            workerID: "git",
            id: "move-local",
            method: "move-thread-to-local",
            params: .object([
                "operationId": .string("handoff-local"),
                "sourceWorktreeCwd": .string(source.path),
                "sourceWorktreeRoot": .string(source.path),
                "localGitRoot": .string(root.path),
                "sourceBranch": .string("feature"),
            ])
        ),
        emit: { await events.append($0) }
    )

    guard case let .object(fields) = result else {
        Issue.record("Missing move-to-local result")
        return
    }
    #expect(fields["status"] == .string("success"))
    #expect(try git(root, ["branch", "--show-current"]) == "feature")
    #expect(try git(source, ["branch", "--show-current"]).isEmpty)
    #expect(
        try String(
            contentsOf: root.appendingPathComponent("README.md"),
            encoding: .utf8
        ) == "moved change\n"
    )
    #expect(
        try String(
            contentsOf: root.appendingPathComponent("NOTES.md"),
            encoding: .utf8
        ) == "new file\n"
    )
    #expect(try git(source, ["status", "--porcelain"]).isEmpty)
    #expect(try git(root, ["stash", "list"]).isEmpty)
    let progress = await events.snapshot()
    #expect(progress.contains(.object([
        "type": .string("thread-handoff-progress"),
        "operationId": .string("handoff-local"),
        "direction": .string("to-local"),
        "step": .string("apply-changes-to-local"),
        "status": .string("completed"),
    ])))
}

@Test
func desktopGitWorkerMovesThreadChangesIntoWorktree() async throws {
    let sandbox = FileManager.default.temporaryDirectory
        .appendingPathComponent(
            "codexpad-move-worktree-\(UUID().uuidString)"
        )
    let root = sandbox.appendingPathComponent("repo")
    let target = sandbox.appendingPathComponent("target-worktree")
    try FileManager.default.createDirectory(
        at: root,
        withIntermediateDirectories: true
    )
    defer {
        try? FileManager.default.removeItem(at: sandbox)
    }
    func git(_ cwd: URL, _ arguments: [String]) throws -> String {
        let result = try runWorkerCommand(
            arguments: ["git", "-C", cwd.path] + arguments,
            cwd: cwd.path
        )
        guard result.exitCode == 0 else {
            throw CodexDesktopWorkerMethodError(result.stderr)
        }
        return result.stdout.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
    }
    _ = try git(root, ["init", "-b", "main"])
    _ = try git(root, ["config", "user.name", "Codex Test"])
    _ = try git(
        root,
        ["config", "user.email", "codex@example.invalid"]
    )
    let readme = root.appendingPathComponent("README.md")
    try "base\n".write(to: readme, atomically: true, encoding: .utf8)
    _ = try git(root, ["add", "README.md"])
    _ = try git(root, ["commit", "-m", "base"])
    _ = try git(root, ["checkout", "-b", "feature"])
    _ = try git(
        root,
        ["worktree", "add", "--detach", target.path, "HEAD"]
    )
    try "worktree-bound\n".write(
        to: readme,
        atomically: true,
        encoding: .utf8
    )
    try "untracked\n".write(
        to: root.appendingPathComponent("THREAD.md"),
        atomically: true,
        encoding: .utf8
    )
    let events = JSONValueProbe()
    let worker = CodexDesktopGitWorker { arguments, cwd in
        try runWorkerCommand(arguments: arguments, cwd: cwd)
    }

    let result = try await worker.handle(
        .init(
            workerID: "git",
            id: "move-worktree",
            method: "move-thread-to-worktree",
            params: .object([
                "operationId": .string("handoff-worktree"),
                "localCwd": .string(root.path),
                "sourceBranch": .string("feature"),
                "defaultBranch": .string("main"),
                "localCheckoutBranch": .string("main"),
                "worktreeCheckoutBranch": .string("feature"),
                "worktreeGitRoot": .string(target.path),
                "worktreeWorkspaceRoot": .string(target.path),
                "stashTargetWorktree": .bool(false),
                "createdWorktree": .bool(false),
            ])
        ),
        emit: { await events.append($0) }
    )

    guard case let .object(fields) = result else {
        Issue.record("Missing move-to-worktree result")
        return
    }
    #expect(fields["status"] == .string("success"))
    #expect(try git(root, ["branch", "--show-current"]) == "main")
    #expect(try git(target, ["branch", "--show-current"]) == "feature")
    #expect(
        try String(
            contentsOf: target.appendingPathComponent("README.md"),
            encoding: .utf8
        ) == "worktree-bound\n"
    )
    #expect(
        try String(
            contentsOf: target.appendingPathComponent("THREAD.md"),
            encoding: .utf8
        ) == "untracked\n"
    )
    #expect(try git(root, ["status", "--porcelain"]).isEmpty)
    #expect(try git(root, ["stash", "list"]).isEmpty)
    let progress = await events.snapshot()
    #expect(progress.contains(.object([
        "type": .string("thread-handoff-progress"),
        "operationId": .string("handoff-worktree"),
        "direction": .string("to-worktree"),
        "step": .string("apply-changes-to-worktree"),
        "status": .string("completed"),
    ])))
}

@Test
func desktopGitWorkerTransfersHostHandoffAndCleansCopiedRollout()
    async throws
{
    let sandbox = FileManager.default.temporaryDirectory
        .appendingPathComponent("codexpad-host-handoff-\(UUID().uuidString)")
    let source = sandbox.appendingPathComponent("source")
    let destination = sandbox.appendingPathComponent("destination")
    let codexHome = sandbox.appendingPathComponent("codex-home")
    try FileManager.default.createDirectory(
        at: source,
        withIntermediateDirectories: true
    )
    defer {
        try? FileManager.default.removeItem(at: sandbox)
    }
    func git(_ cwd: URL, _ arguments: [String]) throws -> String {
        let result = try runWorkerCommand(
            arguments: ["git", "-C", cwd.path] + arguments,
            cwd: cwd.path
        )
        guard result.exitCode == 0 else {
            throw CodexDesktopWorkerMethodError(result.stderr)
        }
        return result.stdout.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
    }
    _ = try git(source, ["init", "-b", "main"])
    _ = try git(source, ["config", "user.name", "Codex Test"])
    _ = try git(
        source,
        ["config", "user.email", "codex@example.invalid"]
    )
    let readme = source.appendingPathComponent("README.md")
    try "base\n".write(to: readme, atomically: true, encoding: .utf8)
    _ = try git(source, ["add", "README.md"])
    _ = try git(source, ["commit", "-m", "base"])
    _ = try git(source, ["checkout", "-b", "feature"])
    try "host dirty\n".write(
        to: readme,
        atomically: true,
        encoding: .utf8
    )
    try "host untracked\n".write(
        to: source.appendingPathComponent("HOST.md"),
        atomically: true,
        encoding: .utf8
    )
    let clone = try runWorkerCommand(
        arguments: [
            "git", "clone", "--branch", "main", source.path,
            destination.path,
        ],
        cwd: sandbox.path
    )
    #expect(clone.exitCode == 0)
    let rollout = sandbox.appendingPathComponent("source-rollout.jsonl")
    try #"{"type":"session_meta"}"#.appending("\n").write(
        to: rollout,
        atomically: true,
        encoding: .utf8
    )
    let events = JSONValueProbe()
    let worker = CodexDesktopGitWorker { arguments, cwd in
        try runWorkerCommand(arguments: arguments, cwd: cwd)
    }

    let result = try await worker.handle(
        .init(
            workerID: "git",
            id: "move-host",
            method: "move-thread-to-host-worktree",
            params: .object([
                "operationId": .string("handoff-host"),
                "sourceCwd": .string(source.path),
                "sourceBranch": .string("feature"),
                "sourceRolloutPath": .string(rollout.path),
                "destinationWorkspaceRoot": .string(destination.path),
                "destinationWorktreeGitRoot": .null,
                "destinationWorktreeWorkspaceRoot": .null,
                "stashDestinationWorktree": .bool(false),
                "codexHome": .string(codexHome.path),
            ])
        ),
        emit: { await events.append($0) }
    )

    guard case let .object(fields) = result,
          fields["status"] == .string("success"),
          case let .string(copiedRollout)? = fields["rolloutPath"],
          case let .string(worktree)? = fields["worktreeWorkspaceRoot"]
    else {
        Issue.record("Missing successful host handoff result: \(result)")
        return
    }
    #expect(FileManager.default.fileExists(atPath: copiedRollout))
    #expect(
        try String(
            contentsOf:
                URL(fileURLWithPath: worktree)
                .appendingPathComponent("README.md"),
            encoding: .utf8
        ) == "host dirty\n"
    )
    #expect(
        try String(
            contentsOf:
                URL(fileURLWithPath: worktree)
                .appendingPathComponent("HOST.md"),
            encoding: .utf8
        ) == "host untracked\n"
    )
    let cleanup = try await worker.handle(
        .init(
            workerID: "git",
            id: "cleanup-host",
            method: "cleanup-host-handoff-transfer",
            params: .object([
                "rolloutPath": .string(copiedRollout),
                "codexHome": .string(codexHome.path),
            ])
        )
    )
    #expect(cleanup == .object(["success": .bool(true)]))
    #expect(
        !FileManager.default.fileExists(
            atPath:
                URL(fileURLWithPath: copiedRollout)
                .deletingLastPathComponent().path
        )
    )
    let progress = await events.snapshot()
    #expect(progress.contains(.object([
        "type": .string("thread-handoff-progress"),
        "operationId": .string("handoff-host"),
        "direction": .string("to-host-worktree"),
        "step": .string("transfer-host-artifacts"),
        "status": .string("completed"),
    ])))
}

@Test
func desktopGitWorkerRejectsUnsafeHostHandoffCleanupPath() async throws {
    let worker = CodexDesktopGitWorker { arguments, cwd in
        try runWorkerCommand(arguments: arguments, cwd: cwd)
    }

    await #expect(throws: CodexDesktopWorkerMethodError.self) {
        try await worker.handle(
            .init(
                workerID: "git",
                id: "unsafe-cleanup",
                method: "cleanup-host-handoff-transfer",
                params: .object([
                    "rolloutPath": .string("/tmp/rollout.jsonl"),
                    "codexHome": .string("/tmp/codex-home"),
                ])
            )
        )
    }
}

private func workerRequest(
    id: String,
    method: String,
    params: CodexJSONValue = .null
) -> CodexJSONValue {
    .object([
        "type": .string("worker-request"),
        "workerId": .string("git"),
        "request": .object([
            "enqueuedAtMs": .integer(123),
            "id": .string(id),
            "method": .string(method),
            "params": params,
            "trace": .object(["traceId": .string("trace-1")]),
        ]),
    ])
}

private actor WorkerOutputProbe {
    private var values: [CodexDesktopHostMessage] = []

    func append(_ value: CodexDesktopHostMessage) {
        values.append(value)
    }

    func snapshot() -> [CodexDesktopHostMessage] {
        values
    }

    func waitForCount(_ count: Int) async -> [CodexDesktopHostMessage] {
        for _ in 0 ..< 200 {
            if values.count >= count {
                break
            }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return values
    }
}

private actor JSONValueProbe {
    private var values: [CodexJSONValue] = []

    func append(_ value: CodexJSONValue) {
        values.append(value)
    }

    func snapshot() -> [CodexJSONValue] {
        values
    }
}

private actor DiagnosticProbe {
    private var values: [CodexDesktopWorkerDiagnostic] = []

    func append(_ value: CodexDesktopWorkerDiagnostic) {
        values.append(value)
    }

    func snapshot() -> [CodexDesktopWorkerDiagnostic] {
        values
    }
}

private actor WorkerHandlerProbe: CodexDesktopWorkerRequestHandling {
    private let result: CodexJSONValue
    private var received: [CodexDesktopWorkerRequest] = []

    init(result: CodexJSONValue) {
        self.result = result
    }

    func handle(
        _ request: CodexDesktopWorkerRequest
    ) async throws -> CodexJSONValue {
        received.append(request)
        return result
    }

    func requests() -> [CodexDesktopWorkerRequest] {
        received
    }
}

private actor ThrowingWorkerHandlerProbe: CodexDesktopWorkerRequestHandling {
    func handle(
        _: CodexDesktopWorkerRequest
    ) async throws -> CodexJSONValue {
        throw CodexDesktopWorkerMethodError("private failure details")
    }
}

private actor BlockingWorkerHandlerProbe:
    CodexDesktopWorkerRequestHandling
{
    private var started = false
    private var cancelled = false
    private var shouldRelease = false

    func handle(
        _: CodexDesktopWorkerRequest
    ) async throws -> CodexJSONValue {
        started = true
        while !shouldRelease {
            do {
                try await Task.sleep(for: .milliseconds(2))
            } catch is CancellationError {
                cancelled = true
                throw CancellationError()
            }
        }
        return .null
    }

    func waitUntilStarted() async {
        while !started {
            await Task.yield()
        }
    }

    func release() {
        shouldRelease = true
    }

    func wasCancelled() -> Bool {
        cancelled
    }
}

private actor GitRunnerProbe {
    struct Call: Equatable, Sendable {
        let arguments: [String]
        let cwd: String
    }

    private var remaining: [CodexDesktopCommandExecResult]
    private var received: [Call] = []

    init(results: [CodexDesktopCommandExecResult]) {
        remaining = results
    }

    func run(
        arguments: [String],
        cwd: String
    ) throws -> CodexDesktopCommandExecResult {
        received.append(.init(arguments: arguments, cwd: cwd))
        guard !remaining.isEmpty else {
            throw CodexDesktopWorkerMethodError("Missing runner result")
        }
        return remaining.removeFirst()
    }

    func calls() -> [Call] {
        received
    }
}

private func runWorkerCommand(
    arguments: [String],
    cwd: String,
    environment: [String: String?]? = nil
) throws -> CodexDesktopCommandExecResult {
    guard let executable = arguments.first else {
        throw CodexDesktopWorkerMethodError("Missing executable")
    }
    let process = Process()
    process.executableURL = URL(
        fileURLWithPath: executable == "git"
            ? "/usr/bin/git"
            : executable
    )
    process.arguments = Array(arguments.dropFirst())
    process.currentDirectoryURL = URL(fileURLWithPath: cwd)
    if let environment {
        var merged = ProcessInfo.processInfo.environment
        for (key, value) in environment {
            if let value {
                merged[key] = value
            } else {
                merged.removeValue(forKey: key)
            }
        }
        process.environment = merged
    }
    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr
    try process.run()
    process.waitUntilExit()
    return .init(
        exitCode: Int64(process.terminationStatus),
        stdout: String(
            data: stdout.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? "",
        stderr: String(
            data: stderr.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
    )
}
