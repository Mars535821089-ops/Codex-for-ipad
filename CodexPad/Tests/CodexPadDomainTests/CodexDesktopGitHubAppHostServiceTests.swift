import Foundation
import Testing

@testable import CodexPadApplication

private typealias GitHubService = CodexDesktopGitHubAppHostService
private typealias GitHubValue = CodexDesktopAppHostRPC.Value

@Test
func desktopGitHubExportsAllOfficialRequestKinds() {
    #expect(
        GitHubService.RequestKind.allCases.map(\.rawValue) == [
            "gh-cli-status",
            "gh-current-user",
            "gh-user-search",
            "gh-pr-create",
            "gh-pr-board",
            "gh-pr-search",
            "gh-pr-media",
            "gh-pr-status",
            "gh-pr-diff",
            "gh-pr-comment",
            "gh-pr-review-thread-update",
            "gh-pr-merge",
            "gh-pr-submit-review",
            "gh-pr-update",
        ]
    )
}

@Test
func desktopGitHubForwardsEveryKindAndReturnsWaitResult()
    async throws
{
    let recorder = GitHubOperationRecorder()
    let service = GitHubService(
        requestOperation: { request in
            await recorder.recordRequest(request)
            return .init(rawValue: request.kind.rawValue)
        },
        requestWait: { operation in
            await recorder.recordWait(operation)
            return .object([
                "kind": .string(operation.rawValue),
                "status": .string("success"),
            ])
        },
        requestCancel: { operation in
            Task { await recorder.recordCancel(operation) }
        },
        requestDispose: { operation in
            Task { await recorder.recordDispose(operation) }
        }
    )
    let payload: GitHubValue = .object([
        "hostId": .string("local"),
        "hostname": .string("github.example"),
    ])

    for kind in GitHubService.RequestKind.allCases {
        #expect(
            try await service.invoke(
                service: "github",
                method: "request",
                arguments: [
                    .string(kind.rawValue),
                    payload,
                    .string("git_direct_call"),
                ]
            ) == .object([
                "kind": .string(kind.rawValue),
                "status": .string("success"),
            ])
        )
    }

    await recorder.waitForDisposeCount(
        GitHubService.RequestKind.allCases.count
    )
    #expect(
        await recorder.requests.map(\.kind)
            == GitHubService.RequestKind.allCases
    )
    #expect(await recorder.requests.allSatisfy {
        $0.payload == payload
            && $0.source == "git_direct_call"
    })
    #expect(
        await recorder.waitedOperations.map(\.rawValue)
            == GitHubService.RequestKind.allCases.map(\.rawValue)
    )
    let disposedRawValues = await recorder.disposedOperations
        .map(\.rawValue)
        .sorted()
    #expect(
        disposedRawValues
            == GitHubService.RequestKind.allCases
                .map(\.rawValue)
                .sorted()
    )
    #expect(await recorder.cancelledOperations.isEmpty)
}

@Test
func desktopGitHubReportsTruthfulCLIStatusWithoutDesktopBoundary()
    async throws
{
    let service = GitHubService()

    #expect(
        try await service.invoke(
            service: "github",
            method: "request",
            arguments: [
                .string("gh-cli-status"),
                .object(["hostId": .string("local")]),
                .string("git_direct_call"),
            ]
        ) == .object([
            "isInstalled": .bool(false),
            "isAuthenticated": .bool(false),
        ])
    )
}

@Test
func desktopGitHubRejectsUnknownKindsAndMalformedRequests()
    async throws
{
    let service = GitHubService(
        requestOperation: { _ in .init(rawValue: "unused") },
        requestWait: { _ in .undefined }
    )

    await #expect(
        throws: GitHubService.Error.unsupportedKind("gh-repo-delete")
    ) {
        _ = try await service.invoke(
            service: "github",
            method: "request",
            arguments: [
                .string("gh-repo-delete"),
                .object([:]),
                .string("git_direct_call"),
            ]
        )
    }
    await #expect(throws: GitHubService.Error.invalidArguments) {
        _ = try await service.invoke(
            service: "github",
            method: "request",
            arguments: [
                .string("gh-cli-status"),
                .string("not-an-object"),
                .string("git_direct_call"),
            ]
        )
    }
    await #expect(
        throws: GitHubService.Error.unsupportedMethod(
            service: "github",
            method: "deleteRepository"
        )
    ) {
        _ = try await service.invoke(
            service: "github",
            method: "deleteRepository",
            arguments: []
        )
    }
}

@Test
func desktopGitHubCancelsAndDisposesCancelledOperation()
    async throws
{
    let recorder = GitHubOperationRecorder()
    let service = GitHubService(
        requestOperation: { _ in
            .init(rawValue: "cancelled-operation")
        },
        requestWait: { _ in
            throw CancellationError()
        },
        requestCancel: { operation in
            Task { await recorder.recordCancel(operation) }
        },
        requestDispose: { operation in
            Task { await recorder.recordDispose(operation) }
        }
    )

    await #expect(throws: CancellationError.self) {
        _ = try await service.invoke(
            service: "github",
            method: "request",
            arguments: [
                .string("gh-pr-board"),
                .object(["hostId": .string("local")]),
                .string("pull_requests_page"),
            ]
        )
    }
    await recorder.waitForCancelAndDispose()
    #expect(
        await recorder.cancelledOperations
            == [.init(rawValue: "cancelled-operation")]
    )
    #expect(
        await recorder.disposedOperations
            == [.init(rawValue: "cancelled-operation")]
    )
}

@Test
func desktopGitHubDisposesAndPropagatesOperationErrors()
    async throws
{
    let recorder = GitHubOperationRecorder()
    let service = GitHubService(
        requestOperation: { _ in
            .init(rawValue: "failed-operation")
        },
        requestWait: { _ in
            throw GitHubTestFailure.transport
        },
        requestCancel: { operation in
            Task { await recorder.recordCancel(operation) }
        },
        requestDispose: { operation in
            Task { await recorder.recordDispose(operation) }
        }
    )

    await #expect(throws: GitHubTestFailure.transport) {
        _ = try await service.invoke(
            service: "github",
            method: "request",
            arguments: [
                .string("gh-pr-search"),
                .object(["account": .object(["hostId": .string("local")])]),
                .string("pull_requests_page"),
            ]
        )
    }
    await recorder.waitForDisposeCount(1)
    #expect(await recorder.cancelledOperations.isEmpty)
    #expect(
        await recorder.disposedOperations
            == [.init(rawValue: "failed-operation")]
    )
}

@Test
func desktopGitHubPreservesStructuredErrorResults() async throws {
    let expected: GitHubValue = .object([
        "status": .string("error"),
        "error": .string("GitHub request failed"),
    ])
    let service = GitHubService(
        requestOperation: { _ in
            .init(rawValue: "structured-error")
        },
        requestWait: { _ in expected }
    )

    #expect(
        try await service.invoke(
            service: "github",
            method: "request",
            arguments: [
                .string("gh-pr-update"),
                .object([
                    "account": .object(["hostId": .string("local")]),
                    "action": .string("close"),
                ]),
                .string("pull_requests_page"),
            ]
        ) == expected
    )
}

@Test
func desktopGitHubExternalTaskCancellationIsIdempotent()
    async throws
{
    let recorder = GitHubOperationRecorder()
    let service = GitHubService(
        requestOperation: { _ in
            .init(rawValue: "external-cancellation")
        },
        requestWait: { operation in
            await recorder.recordWait(operation)
            try await Task.sleep(nanoseconds: 30_000_000_000)
            return .undefined
        },
        requestCancel: { operation in
            Task { await recorder.recordCancel(operation) }
        },
        requestDispose: { operation in
            Task { await recorder.recordDispose(operation) }
        }
    )
    let task = Task {
        try await service.invoke(
            service: "github",
            method: "request",
            arguments: [
                .string("gh-pr-diff"),
                .object(["hostId": .string("local")]),
                .string("pull_requests_page"),
            ]
        )
    }

    await recorder.waitForWaitCount(1)
    task.cancel()
    await #expect(throws: CancellationError.self) {
        _ = try await task.value
    }
    await recorder.waitForCancelAndDispose()
    #expect(await recorder.cancelledOperations.count == 1)
    #expect(await recorder.disposedOperations.count == 1)
}

private enum GitHubTestFailure: Swift.Error, Equatable, Sendable {
    case transport
}

private actor GitHubOperationRecorder {
    private(set) var requests: [GitHubService.Request] = []
    private(set) var waitedOperations: [GitHubService.Operation] = []
    private(set) var cancelledOperations: [GitHubService.Operation] = []
    private(set) var disposedOperations: [GitHubService.Operation] = []

    func recordRequest(_ request: GitHubService.Request) {
        requests.append(request)
    }

    func recordWait(_ operation: GitHubService.Operation) {
        waitedOperations.append(operation)
    }

    func recordCancel(_ operation: GitHubService.Operation) {
        cancelledOperations.append(operation)
    }

    func recordDispose(_ operation: GitHubService.Operation) {
        disposedOperations.append(operation)
    }

    func waitForWaitCount(_ count: Int) async {
        while waitedOperations.count < count {
            await Task.yield()
        }
    }

    func waitForDisposeCount(_ count: Int) async {
        while disposedOperations.count < count {
            await Task.yield()
        }
    }

    func waitForCancelAndDispose() async {
        while cancelledOperations.isEmpty
            || disposedOperations.isEmpty
        {
            await Task.yield()
        }
    }
}
