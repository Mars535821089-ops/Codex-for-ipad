import Foundation
import Testing

@testable import CodexPadApplication
@testable import CodexPadDomain
@testable import CodexPadProtocolBridge

@Test @MainActor
func feedbackUploadServiceSendsReleasedSentryEnvelopeAndAttachments()
    async throws
{
    let transport = FeedbackRecordingTransport()
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
        at: root,
        withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: root) }
    let extraLog = root.appendingPathComponent("runner.log")
    try Data("runner-output".utf8).write(to: extraLog)
    let threadID = "018f47a7-7f4e-7c00-8000-000000000001"
    let service = CodexFeedbackUploadService(
        transport: transport,
        endpoint: URL(string: "https://feedback.example/envelope")!,
        diagnosticsProvider: { ["bridge-ready", "turn-started"] }
    )

    let returnedThreadID = try await service.uploadFeedback(
        CodexFeedbackUploadParameters(
            classification: "bad_result",
            reason: "unexpected output",
            threadID: threadID,
            includeLogs: true,
            extraLogFiles: [extraLog],
            tags: ["surface": "conversation"],
        )
    )

    #expect(returnedThreadID == threadID)
    let request = try #require(await transport.requests.first)
    #expect(request.method == "POST")
    #expect(
        request.headers["Content-Type"]
            == "application/x-sentry-envelope"
    )
    let envelope = try #require(
        request.body.flatMap { String(data: $0, encoding: .utf8) }
    )
    #expect(envelope.contains(#""type":"event""#))
    #expect(envelope.contains(#""classification":"bad_result""#))
    #expect(envelope.contains(#""thread_id":"018f47a7-7f4e-7c00-8000-000000000001""#))
    #expect(envelope.contains(#""filename":"codex-logs.log""#))
    #expect(envelope.contains("bridge-ready\nturn-started"))
    #expect(envelope.contains(#""filename":"runner.log""#))
    #expect(envelope.contains("runner-output"))
}

@Test @MainActor
func feedbackUploadRouterForwardsOfficialParametersAndResult() async {
    let uploader = FeedbackRecordingUploader()
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try? FileManager.default.createDirectory(
        at: root,
        withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("trace.jsonl")
    try? Data("{}".utf8).write(to: file)
    let threadID = "018f47a7-7f4e-7c00-8000-000000000001"
    let request = feedbackRequest(
        params: .object([
            "classification": .string("bug"),
            "reason": .string("details"),
            "threadId": .string(threadID),
            "includeLogs": .bool(true),
            "extraLogFiles": .array([.string(file.path)]),
            "tags": .object(["screen": .string("review")]),
        ])
    )

    let response = await CodexDesktopInitialMCPRouter
        .responseIncludingFileSystem(
            to: request,
            state: feedbackState(),
            allowedFileSystemRoots: [root.path],
            feedbackUploader: uploader
        )

    #expect(
        response == .mcpResponse(
            hostID: "feedback-host",
            message: .object([
                "id": .integer(91),
                "result": .object([
                    "threadId": .string(threadID),
                ]),
            ]),
            metadata: [:]
        )
    )
    #expect(
        uploader.received
            == CodexFeedbackUploadParameters(
                classification: "bug",
                reason: "details",
                threadID: threadID,
                includeLogs: true,
                extraLogFiles: [file.standardizedFileURL],
                tags: ["screen": "review"]
            )
    )
}

@Test @MainActor
func feedbackUploadRouterRejectsFilesOutsideWorkspace() async {
    let uploader = FeedbackRecordingUploader()
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let outside = FileManager.default.temporaryDirectory
        .appendingPathComponent("outside-\(UUID().uuidString).log")
    let response = await CodexDesktopInitialMCPRouter
        .responseIncludingFileSystem(
            to: feedbackRequest(
                params: .object([
                    "classification": .string("bug"),
                    "extraLogFiles": .array([
                        .string(outside.path)
                    ]),
                ])
            ),
            state: feedbackState(),
            allowedFileSystemRoots: [root.path],
            feedbackUploader: uploader
        )

    #expect(uploader.received == nil)
    #expect(
        response == .mcpResponse(
            hostID: "feedback-host",
            message: .object([
                "id": .integer(91),
                "error": .object([
                    "code": .integer(-32602),
                    "message": .string(
                        "Invalid params for feedback/upload"
                    ),
                ]),
            ]),
            metadata: [:]
        )
    )
}

private actor FeedbackRecordingTransport:
    CodexDesktopNetworkFetchTransport
{
    private(set) var requests:
        [CodexDesktopNetworkTransportRequest] = []

    func execute(
        _ request: CodexDesktopNetworkTransportRequest
    ) async throws -> CodexDesktopNetworkTransportResponse {
        requests.append(request)
        return .init(status: 200, headers: [:], body: Data())
    }
}

@MainActor
private final class FeedbackRecordingUploader:
    CodexDesktopFeedbackUploading
{
    var received: CodexFeedbackUploadParameters?

    func uploadFeedback(
        _ parameters: CodexFeedbackUploadParameters
    ) async throws -> String {
        received = parameters
        return parameters.threadID ?? "generated-thread"
    }
}

private func feedbackRequest(
    params: CodexJSONValue
) -> CodexDesktopMCPRequest {
    CodexDesktopMCPRequest(
        request: .init(
            id: .integer(91),
            method: "feedback/upload",
            params: params,
            metadata: [:]
        ),
        hostID: "feedback-host",
        dispatchedAtMs: nil,
        priority: nil,
        source: nil,
        timeoutMs: nil,
        expiresAtMs: nil,
        metadata: [:]
    )
}

private func feedbackState() -> CodexDesktopInitialMCPState {
    .init(
        account: .init(
            account: nil,
            authMethod: nil,
            requiresOpenAIAuth: true
        ),
        config: .init(
            config: [:],
            origins: [:],
            layers: []
        ),
        remoteControl: .init(
            status: .disabled,
            serverName: "Codex",
            installationID: "installation",
            environmentID: nil
        )
    )
}
