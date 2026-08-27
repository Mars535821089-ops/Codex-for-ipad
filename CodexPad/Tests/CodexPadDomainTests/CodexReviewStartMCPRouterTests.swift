import CodexPadApplication
import CodexPadDomain
import CodexPadProtocolBridge
import Testing

@MainActor
private final class ReviewStartRecorder:
    CodexDesktopTurnSessionStarting,
    CodexDesktopReviewStarting
{
    private(set) var reviewID: CodexAppServerRequestID?
    private(set) var reviewParams: CodexReviewStartParams?

    func startDesktopTurn(
        id _: CodexAppServerRequestID,
        params _: CodexTurnStartParams
    ) throws -> CodexTurnStartResult {
        CodexTurnStartResult(
            turn: CodexStoredTurn(
                id: "ordinary-turn",
                items: [],
                status: .inProgress
            )
        )
    }

    func startDesktopReview(
        id: CodexAppServerRequestID,
        params: CodexReviewStartParams
    ) throws -> CodexReviewStartResult {
        reviewID = id
        reviewParams = params
        return CodexReviewStartResult(
            turn: CodexStoredTurn(
                id: "review-turn",
                items: [
                    .userMessage(
                        id: "review-turn",
                        clientID: nil,
                        content: [
                            .text(
                                text: "commit abcdef1: Fix race",
                                textElements: []
                            ),
                        ]
                    ),
                ],
                status: .inProgress
            ),
            reviewThreadID: .init("review-thread")
        )
    }
}

@Test
@MainActor
func reviewStartForwardsCleanedCommitAndDetachedDelivery()
    async
{
    let recorder = ReviewStartRecorder()
    let response = await CodexDesktopInitialMCPRouter
        .responseIncludingFileSystem(
            to: reviewRequest(
                params: .object([
                    "threadId": .string("parent-thread"),
                    "delivery": .string("detached"),
                    "target": .object([
                        "type": .string("commit"),
                        "sha": .string("  abcdef123456  "),
                        "title": .string("  Fix race  "),
                    ]),
                ])
            ),
            state: reviewState(),
            allowedFileSystemRoots: [],
            turnStarter: recorder
        )

    #expect(recorder.reviewID == .string("review-1"))
    #expect(
        recorder.reviewParams
            == CodexReviewStartParams(
                threadID: .init("parent-thread"),
                target: .commit(
                    sha: "abcdef123456",
                    title: "Fix race"
                ),
                delivery: .detached
            )
    )
    guard case let .mcpResponse(_, .object(envelope), _) =
        response,
        case let .object(result)? = envelope["result"],
        case let .object(turn)? = result["turn"]
    else {
        Issue.record("review/start response shape mismatch")
        return
    }
    #expect(result["reviewThreadId"] == .string("review-thread"))
    #expect(turn["id"] == .string("review-turn"))
    #expect(turn["status"] == .string("inProgress"))
}

@Test
@MainActor
func reviewStartDefaultsInlineAndCleansCustomInstructions()
    async
{
    let recorder = ReviewStartRecorder()
    _ = await CodexDesktopInitialMCPRouter
        .responseIncludingFileSystem(
            to: reviewRequest(
                params: .object([
                    "threadId": .string("parent-thread"),
                    "target": .object([
                        "type": .string("custom"),
                        "instructions": .string(
                            "  Review the state machine.  "
                        ),
                    ]),
                ])
            ),
            state: reviewState(),
            allowedFileSystemRoots: [],
            turnStarter: recorder
        )

    #expect(
        recorder.reviewParams
            == CodexReviewStartParams(
                threadID: .init("parent-thread"),
                target: .custom(
                    instructions: "Review the state machine."
                )
            )
    )
}

@Test(arguments: [
    CodexJSONValue.object([:]),
    .object([
        "threadId": .string("thread"),
        "delivery": .string("background"),
        "target": .object([
            "type": .string("uncommittedChanges")
        ]),
    ]),
    .object([
        "threadId": .string("thread"),
        "target": .object([
            "type": .string("baseBranch"),
            "branch": .string("   "),
        ]),
    ]),
    .object([
        "threadId": .string("thread"),
        "target": .object([
            "type": .string("commit"),
            "sha": .string("abc"),
        ]),
    ]),
])
@MainActor
func reviewStartRejectsInvalidOfficialShapes(
    params: CodexJSONValue
) async {
    let response = await CodexDesktopInitialMCPRouter
        .responseIncludingFileSystem(
            to: reviewRequest(params: params),
            state: reviewState(),
            allowedFileSystemRoots: [],
            turnStarter: ReviewStartRecorder()
        )
    guard case let .mcpResponse(_, .object(envelope), _) =
        response,
        case let .object(error)? = envelope["error"]
    else {
        Issue.record("expected invalid params")
        return
    }
    #expect(error["code"] == .integer(-32602))
}

private func reviewRequest(
    params: CodexJSONValue
) -> CodexDesktopMCPRequest {
    CodexDesktopMCPRequest(
        request: CodexDesktopMCPRequestMessage(
            id: .string("review-1"),
            method: "review/start",
            params: params,
            metadata: [:]
        ),
        hostID: "desktop-host-review",
        dispatchedAtMs: .integer(100),
        priority: .string("interactive"),
        source: .string("renderer"),
        timeoutMs: .integer(5_000),
        expiresAtMs: .integer(5_100),
        metadata: [:]
    )
}

private func reviewState() -> CodexDesktopInitialMCPState {
    .init(
        account: .init(
            account: nil,
            authMethod: nil,
            requiresOpenAIAuth: true
        ),
        config: .init(config: [:], origins: [:], layers: []),
        remoteControl: .init(
            status: .disabled,
            serverName: "Codex for ipad",
            installationID: "installation",
            environmentID: nil
        )
    )
}
