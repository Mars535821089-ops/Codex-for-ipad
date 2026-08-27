import CodexPadApplication
import CodexPadDomain
import CodexPadProtocolBridge
import Foundation
import Testing

@MainActor
private final class PullRequestProviderFixture:
    CodexPersistedTurnProvider
{
    let response: String
    private(set) var requests: [CodexPersistedTurnProviderRequest] = []

    init(response: String) {
        self.response = response
    }

    func stream(
        _ request: CodexPersistedTurnProviderRequest,
        cancellation _: CodexTurnCancellation
    ) async -> AsyncThrowingStream<CodexCoreProviderEvent, Error> {
        requests.append(request)
        return AsyncThrowingStream { continuation in
            continuation.yield(
                .assistantTextDelta(
                    sequence: 1,
                    requestID: request.requestID,
                    delta: response
                )
            )
            continuation.yield(
                .responseCompleted(
                    sequence: 2,
                    requestID: request.requestID,
                    responseID: "response-pull-request",
                    usage: nil,
                    endTurn: true
                )
            )
            continuation.finish()
        }
    }
}

@MainActor
@Test
func desktopPullRequestGeneratorUsesReleasedStructuredProviderRequest()
    async throws
{
    let provider = PullRequestProviderFixture(
        response:
            "{\"title\":\"Update projectless output files\","
            + "\"body\":\"## Summary\\n- Persist real output directories\"}"
    )
    let generator = CodexDesktopPullRequestMessageGenerator(
        providerFactory: { _ in provider }
    )
    let prompt =
        "Use the canonical diff and generate the pull request message."
    let operation = try generator.start(
        .init(
            appServerVersion: "0.146.0",
            hostID: "local",
            prompt: prompt
        ),
        cwd: "/workspace/project"
    )

    let result = try await generator.wait(for: operation)
    #expect(
        result == .init(
            title: "Update projectless output files",
            body: "## Summary\n- Persist real output directories"
        )
    )

    let request = try #require(provider.requests.first)
    #expect(request.startParams.cwd == .value("/workspace/project"))
    #expect(request.startParams.effort == .value("low"))
    #expect(request.frozenPriorInputItems.isEmpty)
    #expect(request.currentTurnInputItems.isEmpty)
    guard case let .text(actualPrompt, textElements) =
        request.startParams.input.first
    else {
        Issue.record("Expected pull-request prompt text")
        return
    }
    #expect(actualPrompt == prompt)
    #expect(textElements.isEmpty)
    #expect(
        request.startParams.outputSchema
            == .value(.object([
                "type": .string("object"),
                "properties": .object([
                    "title": .object([
                        "type": .string("string"),
                        "minLength": .integer(8),
                        "maxLength": .integer(120),
                    ]),
                    "body": .object([
                        "type": .string("string"),
                        "minLength": .integer(12),
                        "maxLength": .integer(30_000),
                    ]),
                ]),
                "required": .array([
                    .string("title"),
                    .string("body"),
                ]),
                "additionalProperties": .bool(false),
            ]))
    )

    generator.release(operation)
    await #expect(
        throws:
            CodexDesktopPullRequestMessageGenerator
                .Error.invalidOperation
    ) {
        _ = try await generator.wait(for: operation)
    }
}

@MainActor
@Test
func desktopPullRequestGeneratorRejectsIncompleteStructuredResponse()
    async throws
{
    let provider = PullRequestProviderFixture(
        response: #"{"title":"Only a title"}"#
    )
    let generator = CodexDesktopPullRequestMessageGenerator(
        providerFactory: { _ in provider }
    )
    let operation = try generator.start(
        .init(
            appServerVersion: "0.146.0",
            hostID: "local",
            prompt: "Generate both fields"
        ),
        cwd: "/workspace/project"
    )

    await #expect(
        throws:
            CodexDesktopPullRequestMessageGenerator
                .Error.invalidStructuredResponse
    ) {
        _ = try await generator.wait(for: operation)
    }
    generator.release(operation)
}
