import Foundation
import Testing

@testable import CodexPadApplication
@testable import CodexPadDomain
@testable import CodexPadProtocolBridge

@Suite
@MainActor
struct CodexDesktopExtendedSessionAdapterTests {
    @Test
    func startAeonForwardsRequestIDAndDefaultsOmittedSources()
        async throws
    {
        let fixture = try ExtendedSessionAdapterFixture()
        defer { fixture.remove() }
        let resumeResult = extendedSessionResumeResult()
        let starter = ExtendedSessionThreadStarter(
            result: resumeResult
        )
        let adapter = CodexDesktopExtendedSessionAdapter(
            threadStarter: starter,
            sandboxStore: fixture.store
        )
        let request = CodexDesktopExtendedSessionRequest(
            id: .string("aeon-request"),
            method: .threadStartAeon,
            params: [
                "model": .string("gpt-test"),
                "ephemeral": .bool(true),
            ]
        )

        let value = try await adapter.handle(request)
        let expected =
            try CodexDesktopInitialMCPRouter.encodedThreadResult(
                resumeResult
            )

        #expect(value == expected)
        #expect(starter.receivedID == .string("aeon-request"))
        #expect(starter.receivedParams?.model == .value("gpt-test"))
        #expect(starter.receivedParams?.ephemeral == .value(true))
        #expect(
            starter.receivedParams?.sessionStartSource
                == .value("aeon")
        )
        #expect(
            starter.receivedParams?.threadSource == .value("aeon")
        )
    }

    @Test
    func stopAndLiveListReflectRealActiveTurnsInStableOrder()
        async throws
    {
        let fixture = try ExtendedSessionAdapterFixture()
        defer { fixture.remove() }
        let targetThreadID = CodexStoredThreadID("thread/zeta")
        let survivingThreadID = CodexStoredThreadID("thread/alpha")
        let transport = ExtendedSessionActivityTransport(
            pendingTurnIDs: [
                targetThreadID: ["turn/zeta-2", "turn/zeta-1"],
                survivingThreadID: ["turn/alpha"],
            ]
        )
        let provider = ExtendedSessionBlockingProvider()
        let runner = CodexDesktopTurnSessionRunner(
            sessionStore: CodexSessionStore(transport: transport),
            providerFactory: { _ in provider },
            notificationSink: { _ in }
        )
        let adapter = CodexDesktopExtendedSessionAdapter(
            threadStarter: ExtendedSessionThreadStarter(
                result: extendedSessionResumeResult()
            ),
            runner: runner,
            sandboxStore: fixture.store
        )
        defer {
            for snapshot in runner.activeTurnSnapshots() {
                runner.interrupt(turnID: snapshot.turnID)
            }
        }

        let targetSecond = try runner.startDesktopTurn(
            id: .string("target-second"),
            params: extendedSessionTurnParams(
                threadID: targetThreadID
            )
        )
        let survivor = try runner.startDesktopTurn(
            id: .string("survivor"),
            params: extendedSessionTurnParams(
                threadID: survivingThreadID
            )
        )
        let targetFirst = try runner.startDesktopTurn(
            id: .string("target-first"),
            params: extendedSessionTurnParams(
                threadID: targetThreadID
            )
        )
        #expect(
            await provider.waitUntilStarted([
                targetSecond.turn.id,
                survivor.turn.id,
                targetFirst.turn.id,
            ])
        )

        #expect(
            try await adapter.handle(
                extendedSessionAdapterRequest(
                    method: .interactiveLiveSessionsList
                )
            ) == .object([
                "data": .array([
                    .object([
                        "status": .string("active"),
                        "threadId": .string("thread/alpha"),
                        "turnId": .string("turn/alpha"),
                    ]),
                    .object([
                        "status": .string("active"),
                        "threadId": .string("thread/zeta"),
                        "turnId": .string("turn/zeta-1"),
                    ]),
                    .object([
                        "status": .string("active"),
                        "threadId": .string("thread/zeta"),
                        "turnId": .string("turn/zeta-2"),
                    ]),
                ])
            ])
        )

        #expect(
            try await adapter.handle(
                extendedSessionAdapterRequest(
                    method: .threadStop,
                    params: [
                        "threadId": .string(targetThreadID.rawValue)
                    ]
                )
            ) == .object([:])
        )
        #expect(
            try await adapter.handle(
                extendedSessionAdapterRequest(
                    method: .interactiveLiveSessionsList
                )
            ) == .object([
                "data": .array([
                    .object([
                        "status": .string("active"),
                        "threadId": .string("thread/alpha"),
                        "turnId": .string("turn/alpha"),
                    ])
                ])
            ])
        )
        #expect(
            try await adapter.handle(
                extendedSessionAdapterRequest(
                    method: .threadStop,
                    params: [
                        "threadId": .string(targetThreadID.rawValue)
                    ]
                )
            ) == .object([:])
        )

        await runner.waitForTurn(targetFirst.turn.id)
        await runner.waitForTurn(targetSecond.turn.id)
        _ = try await adapter.handle(
            extendedSessionAdapterRequest(
                method: .threadStop,
                params: [
                    "threadId": .string(survivingThreadID.rawValue)
                ]
            )
        )
        await runner.waitForTurn(survivor.turn.id)
    }

    @Test
    func uploadMapsSessionFieldsAndRealAttachmentsExactlyOnce()
        async throws
    {
        let fixture = try ExtendedSessionAdapterFixture()
        defer { fixture.remove() }
        let sessionID = "session-upload"
        try fixture.write(
            Data("first".utf8),
            sessionID: sessionID,
            relativePath: "a.log"
        )
        try fixture.write(
            Data("second".utf8),
            sessionID: sessionID,
            relativePath: "nested/b.json"
        )
        let expectedAttachments =
            try await fixture.store.attachmentURLs(
                sessionID: sessionID
            )
        let uploader = ExtendedSessionFeedbackUploader(
            trackingThreadID: "tracking-thread"
        )
        let adapter = CodexDesktopExtendedSessionAdapter(
            threadStarter: ExtendedSessionThreadStarter(
                result: extendedSessionResumeResult()
            ),
            feedbackUploader: uploader,
            sandboxStore: fixture.store
        )

        let value = try await adapter.handle(
            extendedSessionAdapterRequest(
                method: .interactiveSessionUpload,
                params: [
                    "sessionId": .string(sessionID),
                    "reason": .string("share diagnostics"),
                    "threadId": .string("source-thread"),
                    "includeLogs": .bool(true),
                    "tags": .object([
                        "surface": .string("inspector"),
                        "session_id": .string("stale"),
                    ]),
                ]
            )
        )

        #expect(
            value == .object([
                "sessionId": .string(sessionID),
                "threadId": .string("tracking-thread"),
            ])
        )
        #expect(uploader.received.count == 1)
        #expect(
            uploader.received.first
                == CodexFeedbackUploadParameters(
                    classification: "interactive_session",
                    reason: "share diagnostics",
                    threadID: "source-thread",
                    includeLogs: true,
                    extraLogFiles: expectedAttachments,
                    tags: [
                        "session_id": sessionID,
                        "surface": "inspector",
                    ]
                )
        )
    }

    @Test
    func sandboxListAndReadDelegateToTheRealSessionStore()
        async throws
    {
        let fixture = try ExtendedSessionAdapterFixture()
        defer { fixture.remove() }
        let payload = Data([0x00, 0x7f, 0x80, 0xff])
        try fixture.write(
            payload,
            sessionID: "session-sandbox",
            relativePath: "artifacts/report.bin"
        )
        try fixture.write(
            Data("outside".utf8),
            sessionID: "session-sandbox",
            relativePath: "outside.txt"
        )
        let adapter = CodexDesktopExtendedSessionAdapter(
            threadStarter: ExtendedSessionThreadStarter(
                result: extendedSessionResumeResult()
            ),
            sandboxStore: fixture.store
        )

        let listed = try await adapter.handle(
            extendedSessionAdapterRequest(
                method: .interactiveSessionSandboxList,
                params: [
                    "sessionId": .string("session-sandbox"),
                    "path": .string("artifacts"),
                ]
            )
        )
        guard case let .object(listFields) = listed,
              case let .array(entries)? = listFields["data"],
              case let .object(first)? = entries.first
        else {
            Issue.record("sandbox list response shape mismatch")
            return
        }
        #expect(entries.count == 1)
        #expect(first["path"] == .string("artifacts/report.bin"))

        #expect(
            try await adapter.handle(
                extendedSessionAdapterRequest(
                    method: .interactiveSessionSandboxRead,
                    params: [
                        "sessionId": .string("session-sandbox"),
                        "path": .string("artifacts/report.bin"),
                    ]
                )
            ) == .object([
                "dataBase64": .string(payload.base64EncodedString()),
                "path": .string("artifacts/report.bin"),
                "sizeBytes": .integer(Int64(payload.count)),
            ])
        )
    }

    @Test
    func malformedParametersAndMissingCapabilitiesUseEquatableErrors()
        async throws
    {
        let fixture = try ExtendedSessionAdapterFixture()
        defer { fixture.remove() }
        let adapter = CodexDesktopExtendedSessionAdapter(
            threadStarter: ExtendedSessionThreadStarter(
                result: extendedSessionResumeResult()
            ),
            sandboxStore: fixture.store
        )
        let malformedCases:
            [
                (
                    CodexDesktopExtendedSessionMethod,
                    [String: CodexJSONValue]
                )
            ] = [
                (.threadStartAeon, ["model": .integer(1)]),
                (.threadStop, [:]),
                (
                    .interactiveSessionUpload,
                    ["sessionId": .string("")]
                ),
                (
                    .interactiveSessionSandboxList,
                    ["sessionId": .string("session"), "path": .bool(true)]
                ),
                (
                    .interactiveSessionSandboxRead,
                    ["sessionId": .string("session")]
                ),
            ]

        for (method, params) in malformedCases {
            await #expect(
                throws: CodexDesktopExtendedSessionAdapter.Error
                    .malformedParams(method)
            ) {
                try await adapter.handle(
                    extendedSessionAdapterRequest(
                        method: method,
                        params: params
                    )
                )
            }
        }
        await #expect(
            throws: CodexDesktopExtendedSessionAdapter.Error
                .capabilityUnavailable(
                    .interactiveLiveSessionsList
                )
        ) {
            try await adapter.handle(
                extendedSessionAdapterRequest(
                    method: .interactiveLiveSessionsList
                )
            )
        }
    }
}

@MainActor
private final class ExtendedSessionThreadStarter:
    CodexDesktopThreadSessionStarting
{
    let result: CodexThreadResumeResult
    private(set) var receivedID: CodexAppServerRequestID?
    private(set) var receivedParams: CodexThreadStartParams?

    init(result: CodexThreadResumeResult) {
        self.result = result
    }

    func startThread(
        id: CodexAppServerRequestID,
        params: CodexThreadStartParams
    ) throws -> CodexThreadResumeResult {
        receivedID = id
        receivedParams = params
        return result
    }
}

@MainActor
private final class ExtendedSessionFeedbackUploader:
    CodexDesktopFeedbackUploading
{
    let trackingThreadID: String
    private(set) var received: [CodexFeedbackUploadParameters] = []

    init(trackingThreadID: String) {
        self.trackingThreadID = trackingThreadID
    }

    func uploadFeedback(
        _ parameters: CodexFeedbackUploadParameters
    ) async throws -> String {
        received.append(parameters)
        return trackingThreadID
    }
}

@MainActor
private final class ExtendedSessionActivityTransport:
    CodexCoreTransport
{
    private var pendingTurnIDs:
        [CodexStoredThreadID: [String]]

    init(
        pendingTurnIDs: [CodexStoredThreadID: [String]]
    ) {
        self.pendingTurnIDs = pendingTurnIDs
    }

    func submit(_ command: CodexCoreCommand) throws {}

    func request(
        _ request: CodexAppServerThreadRequest
    ) throws -> Data {
        throw CodexCoreTransportError.unsupportedTurnRequest
    }

    func request(
        _ request: CodexAppServerTurnRequest
    ) throws -> Data {
        guard case let .start(id, params) = request,
              var turnIDs = pendingTurnIDs[params.threadID],
              !turnIDs.isEmpty
        else {
            throw CodexCoreTransportError.unsupportedTurnRequest
        }
        let turnID = turnIDs.removeFirst()
        pendingTurnIDs[params.threadID] = turnIDs
        return try JSONEncoder().encode(
            CodexAppServerReply<CodexTurnStartResult>.success(
                .init(
                    id: id,
                    result: CodexTurnStartResult(
                        turn: CodexStoredTurn(
                            id: turnID,
                            items: [],
                            itemsView: .notLoaded,
                            status: .inProgress
                        )
                    )
                )
            )
        )
    }

    func request(
        _ request: CodexRawHistoryRequest
    ) throws -> Data {
        guard case let .priorInputItems(id, params) = request else {
            throw CodexCoreTransportError
                .unsupportedRawHistoryRequest
        }
        return try JSONEncoder().encode(
            CodexAppServerReply<CodexPriorInputItemsResult>.success(
                .init(
                    id: id,
                    result: CodexPriorInputItemsResult(
                        threadID: params.threadID,
                        throughTurnID: nil,
                        items: [],
                        completeness: .complete
                    )
                )
            )
        )
    }

    func nextEvent() throws -> CodexCoreEvent? {
        nil
    }
}

@MainActor
private final class ExtendedSessionBlockingProvider:
    CodexPersistedTurnProvider
{
    private var cancellations:
        [String: CodexTurnCancellation] = [:]

    func stream(
        _ request: CodexPersistedTurnProviderRequest,
        cancellation: CodexTurnCancellation
    ) async -> AsyncThrowingStream<CodexCoreProviderEvent, Error> {
        cancellations[request.turnID] = cancellation
        return AsyncThrowingStream { _ in }
    }

    func waitUntilStarted(
        _ expectedTurnIDs: Set<String>
    ) async -> Bool {
        for _ in 0..<1_000 {
            if Set(cancellations.keys) == expectedTurnIDs {
                return true
            }
            await Task.yield()
        }
        return false
    }
}

private final class ExtendedSessionAdapterFixture {
    let root: URL
    let store: CodexDesktopInteractiveSessionSandboxStore

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "CodexDesktopExtendedSessionAdapter-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        store = CodexDesktopInteractiveSessionSandboxStore(root: root)
    }

    func write(
        _ data: Data,
        sessionID: String,
        relativePath: String
    ) throws {
        let url = root
            .appendingPathComponent(sessionID, isDirectory: true)
            .appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

private func extendedSessionAdapterRequest(
    method: CodexDesktopExtendedSessionMethod,
    params: [String: CodexJSONValue] = [:]
) -> CodexDesktopExtendedSessionRequest {
    CodexDesktopExtendedSessionRequest(
        id: .integer(77),
        method: method,
        params: params
    )
}

private func extendedSessionTurnParams(
    threadID: CodexStoredThreadID
) -> CodexTurnStartParams {
    CodexTurnStartParams(
        threadID: threadID,
        input: [
            .text(
                text: "Keep this turn active",
                textElements: []
            )
        ]
    )
}

private func extendedSessionResumeResult()
    -> CodexThreadResumeResult
{
    let threadID = CodexStoredThreadID(
        "019fab26-5c01-7562-97f1-0999adf15540"
    )
    return CodexThreadResumeResult(
        thread: CodexStoredThread(
            id: threadID,
            sessionID: threadID.rawValue,
            preview: "",
            ephemeral: true,
            modelProvider: "openai",
            createdAt: 100,
            updatedAt: 100,
            status: .idle,
            cwd: "/workspace/project",
            cliVersion: "0.146.0",
            source: .named(.appServer),
            threadSource: "aeon",
            turns: []
        ),
        model: "gpt-test",
        modelProvider: "openai",
        serviceTier: nil,
        cwd: "/workspace/project",
        instructionSources: [],
        approvalPolicy: .onRequest,
        approvalsReviewer: .user,
        sandbox: .workspaceWrite(
            writableRoots: [],
            networkAccess: false,
            excludeTmpdirEnvVar: false,
            excludeSlashTmp: false
        ),
        reasoningEffort: "high"
    )
}
