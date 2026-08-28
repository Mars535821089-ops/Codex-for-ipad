@testable import CodexPadApplication
import CodexPadDomain
import CodexPadProtocolBridge
import Foundation
import Testing

@MainActor
private final class ThreadReadResumeMCPTransport:
    CodexCoreTransport
{
    private(set) var requested: [CodexAppServerThreadRequest] = []
    var queuedReplies: [Data]

    init(queuedReplies: [Data] = []) {
        self.queuedReplies = queuedReplies
    }

    func submit(_ command: CodexCoreCommand) throws {}

    func request(
        _ request: CodexAppServerThreadRequest
    ) throws -> Data {
        requested.append(request)
        guard !queuedReplies.isEmpty else {
            throw CodexSessionStoreError.invalidReply
        }
        return queuedReplies.removeFirst()
    }

    func nextEvent() throws -> CodexCoreEvent? {
        nil
    }
}

@MainActor
private final class ThreadResumeHydrationFallbackTransport:
    CodexCoreTransport
{
    private enum Failure: Swift.Error {
        case rejectedVolatileSettings
    }

    private(set) var requested: [CodexAppServerThreadRequest] = []
    let reply: Data

    init(reply: Data) {
        self.reply = reply
    }

    func submit(_ command: CodexCoreCommand) throws {}

    func request(
        _ request: CodexAppServerThreadRequest
    ) throws -> Data {
        requested.append(request)
        if requested.count == 1 {
            throw Failure.rejectedVolatileSettings
        }
        return reply
    }

    func nextEvent() throws -> CodexCoreEvent? {
        nil
    }
}

@MainActor
private final class ThreadReadResumeMCPListOnlyBoundary:
    CodexDesktopThreadSessionListing
{
    func listThreads(
        id: CodexAppServerRequestID,
        params: CodexThreadListParams
    ) throws -> CodexThreadPage {
        .init(
            data: [],
            nextCursor: nil,
            backwardsCursor: nil
        )
    }
}

@Test
func desktopThreadResumeDiagnosticSummaryPreservesShapeAndRedactsValues() {
    let secretThreadID = "thread-private-123"
    let secretPath = "/private/device/container/Documents/project"
    let secretInstructions = "never log these instructions"
    let params = CodexJSONValue.object([
        "threadId": .string(secretThreadID),
        "model": .string("model-next"),
        "modelProvider": .null,
        "cwd": .string(secretPath),
        "approvalPolicy": .string("never"),
        "config": .object([
            "model": .string("gpt-5.6-sol"),
            "model_reasoning_effort": .string("low"),
            "z_private": .string("never log this config value"),
            "feature": .bool(true),
        ]),
        "developerInstructions": .string(secretInstructions),
        "personality": .string("friendly"),
        "futureField": .string("future-private-value"),
    ])

    let summary = CodexDesktopInitialMCPRouter
        .threadResumeDiagnosticSummary(params)

    #expect(
        summary
            == "keys=approvalPolicy,config,cwd,developerInstructions,"
                + "futureField,model,modelProvider,personality,threadId "
                + "cwd=absolute "
                + "optionals=model:value,modelProvider:null,"
                + "serviceTier:omitted,cwd:value,approvalPolicy:value,"
                + "approvalsReviewer:omitted,sandbox:omitted,config:value,"
                + "baseInstructions:omitted,developerInstructions:value,"
                + "personality:value configKeys=feature,model,"
                + "model_reasoning_effort,z_private model=gpt-5.6-sol "
                + "effort=low personality=friendly developerBytes=28 "
                + "developerSha256=2ebdff8093228c85 cwdBytes=43 "
                + "cwdSha256=438f0f34c288cf7f"
    )
    #expect(summary?.contains(secretThreadID) == false)
    #expect(summary?.contains(secretPath) == false)
    #expect(summary?.contains(secretInstructions) == false)
    #expect(summary?.contains("future-private-value") == false)
    #expect(summary?.contains("never log this config value") == false)
}

@MainActor
@Test
func desktopThreadReadMCPRouterUsesRealStoreAndPreservesIntegerID()
    async throws
{
    let requestID = CodexAppServerRequestID.integer(4_101)
    let thread = threadReadResumeMCPStoredThread()
    let params = CodexThreadReadParams(
        threadID: thread.id,
        includeTurns: true
    )
    let result = CodexThreadReadResult(thread: thread)
    let reply =
        CodexAppServerReply<CodexThreadReadResult>.success(
            .init(id: requestID, result: result)
        )
    let transport = ThreadReadResumeMCPTransport(
        queuedReplies: [try JSONEncoder().encode(reply)]
    )
    let store = CodexSessionStore(transport: transport)

    let response =
        await CodexDesktopInitialMCPRouter
            .responseIncludingFileSystem(
                to: threadReadResumeMCPRequest(
                    id: requestID,
                    method: "thread/read",
                    params: .object([
                        "threadId": .string(thread.id.rawValue),
                        "includeTurns": .bool(true),
                        "futureField": .string("ignored"),
                    ])
                ),
                state: threadReadResumeMCPState(),
                allowedFileSystemRoots: [],
                threadLister: store
            )

    #expect(
        transport.requested == [
            .read(id: requestID, params: params)
        ]
    )
    #expect(store.threadReadResult == result)
    #expect(
        response
            == threadReadResumeMCPResult(
                id: requestID,
                value: try threadReadResumeMCPJSONValue(result)
            )
    )
}

@MainActor
@Test
func desktopThreadReadMCPRouterRejectsMalformedParamsBeforeStore()
    async
{
    let transport = ThreadReadResumeMCPTransport()
    let store = CodexSessionStore(transport: transport)
    let malformed: [CodexJSONValue?] = [
        nil,
        .null,
        .string("not-an-object"),
        .object([:]),
        .object(["threadId": .integer(1)]),
        .object([
            "threadId": .string("thread"),
            "includeTurns": .null,
        ]),
        .object([
            "threadId": .string("thread"),
            "includeTurns": .string("true"),
        ]),
    ]

    for (offset, params) in malformed.enumerated() {
        let id = CodexAppServerRequestID.integer(
            Int64(4_200 + offset)
        )
        let response =
            await CodexDesktopInitialMCPRouter
                .responseIncludingFileSystem(
                    to: threadReadResumeMCPRequest(
                        id: id,
                        method: "thread/read",
                        params: params
                    ),
                    state: threadReadResumeMCPState(),
                    allowedFileSystemRoots: [],
                    threadLister: store
                )

        #expect(
            response
                == threadReadResumeMCPError(
                    id: id,
                    code: -32602,
                    message: "Invalid params for thread/read"
                )
        )
    }

    #expect(transport.requested.isEmpty)
}

@MainActor
@Test
func desktopThreadResumeMCPRouterPreservesEveryOverrideState()
    async throws
{
    let thread = threadReadResumeMCPStoredThread()
    let valueID = CodexAppServerRequestID.string("resume-values")
    let nullID = CodexAppServerRequestID.integer(4_301)
    let valueParams = CodexThreadResumeParams(
        threadID: thread.id,
        model: .value("model-next"),
        modelProvider: .value("provider-next"),
        serviceTier: .value("priority"),
        cwd: .value("/workspace/项目"),
        approvalPolicy: .value(
            .granular(
                .init(
                    sandboxApproval: true,
                    rules: false,
                    skillApproval: true,
                    requestPermissions: false,
                    mcpElicitations: true
                )
            )
        ),
        approvalsReviewer: .value(.autoReview),
        sandbox: .value(.workspaceWrite),
        config: .value([
            "nested": .object([
                "enabled": .bool(true),
                "items": .array([.integer(1), .null]),
            ]),
        ]),
        baseInstructions: .value("base"),
        developerInstructions: .value("developer"),
        personality: .value(.pragmatic)
    )
    let nullParams = CodexThreadResumeParams(
        threadID: thread.id,
        model: .null,
        modelProvider: .null,
        serviceTier: .null,
        cwd: .null,
        approvalPolicy: .null,
        approvalsReviewer: .null,
        sandbox: .null,
        config: .null,
        baseInstructions: .null,
        developerInstructions: .null,
        personality: .null
    )
    let result = threadReadResumeMCPResumeResult(thread: thread)
    let valueReply =
        CodexAppServerReply<CodexThreadResumeResult>.success(
            .init(id: valueID, result: result)
        )
    let nullReply =
        CodexAppServerReply<CodexThreadResumeResult>.success(
            .init(id: nullID, result: result)
        )
    let transport = ThreadReadResumeMCPTransport(
        queuedReplies: [
            try JSONEncoder().encode(valueReply),
            try JSONEncoder().encode(nullReply),
        ]
    )
    let store = CodexSessionStore(transport: transport)

    let valueResponse =
        await CodexDesktopInitialMCPRouter
            .responseIncludingFileSystem(
                to: threadReadResumeMCPRequest(
                    id: valueID,
                    method: "thread/resume",
                    params: .object([
                        "threadId": .string(thread.id.rawValue),
                        "model": .string("model-next"),
                        "modelProvider": .string("provider-next"),
                        "serviceTier": .string("priority"),
                        "cwd": .string("/workspace/项目"),
                        "approvalPolicy": .object([
                            "granular": .object([
                                "sandbox_approval": .bool(true),
                                "rules": .bool(false),
                                "skill_approval": .bool(true),
                                "request_permissions": .bool(false),
                                "mcp_elicitations": .bool(true),
                            ]),
                        ]),
                        "approvalsReviewer": .string("auto_review"),
                        "sandbox": .string("workspace-write"),
                        "config": .object([
                            "nested": .object([
                                "enabled": .bool(true),
                                "items": .array([
                                    .integer(1),
                                    .null,
                                ]),
                            ]),
                        ]),
                        "baseInstructions": .string("base"),
                        "developerInstructions":
                            .string("developer"),
                        "personality": .string("pragmatic"),
                        "futureField": .string("ignored"),
                    ])
                ),
                state: threadReadResumeMCPState(),
                allowedFileSystemRoots: [],
                threadLister: store
            )
    let nullResponse =
        await CodexDesktopInitialMCPRouter
            .responseIncludingFileSystem(
                to: threadReadResumeMCPRequest(
                    id: nullID,
                    method: "thread/resume",
                    params: .object([
                        "threadId": .string(thread.id.rawValue),
                        "model": .null,
                        "modelProvider": .null,
                        "serviceTier": .null,
                        "cwd": .null,
                        "approvalPolicy": .null,
                        "approvalsReviewer": .null,
                        "sandbox": .null,
                        "config": .null,
                        "baseInstructions": .null,
                        "developerInstructions": .null,
                        "personality": .null,
                    ])
                ),
                state: threadReadResumeMCPState(),
                allowedFileSystemRoots: [],
                threadLister: store
            )

    #expect(
        transport.requested == [
            .resume(id: valueID, params: valueParams),
            .resume(id: nullID, params: nullParams),
        ]
    )
    #expect(store.threadResumeResult == result)
    let expectedValue = try threadReadResumeMCPJSONValue(result)
    #expect(
        valueResponse
            == threadReadResumeMCPResult(
                id: valueID,
                value: expectedValue
            )
    )
    #expect(
        nullResponse
            == threadReadResumeMCPResult(
                id: nullID,
                value: expectedValue
            )
    )
}

@MainActor
@Test
func desktopThreadResumeRetriesReleasedHydrationWithPersistedVolatileSettings()
    async throws
{
    let thread = threadReadResumeMCPStoredThread()
    let requestID = CodexAppServerRequestID.string(
        "resume-renderer-hydration"
    )
    let result = threadReadResumeMCPResumeResult(thread: thread)
    let reply = CodexAppServerReply<CodexThreadResumeResult>.success(
        .init(id: requestID, result: result)
    )
    let transport = ThreadResumeHydrationFallbackTransport(
        reply: try JSONEncoder().encode(reply)
    )
    let store = CodexSessionStore(transport: transport)

    let response = await CodexDesktopInitialMCPRouter
        .responseIncludingFileSystem(
            to: threadReadResumeMCPRequest(
                id: requestID,
                method: "thread/resume",
                params: .object([
                    "threadId": .string(thread.id.rawValue),
                    "model": .null,
                    "modelProvider": .null,
                    "cwd": .string("/workspace/current"),
                    "config": .object([
                        "features.realtime_conversation": .bool(true)
                    ]),
                    "developerInstructions": .string(
                        "Current released renderer instructions"
                    ),
                    "personality": .string("friendly"),
                ])
            ),
            state: threadReadResumeMCPState(),
            allowedFileSystemRoots: [],
            threadLister: store
        )

    #expect(response == threadReadResumeMCPResult(
        id: requestID,
        value: try threadReadResumeMCPJSONValue(result)
    ))
    #expect(transport.requested.count == 2)
    guard transport.requested.count == 2,
          case let .resume(_, first) = transport.requested[0],
          case let .resume(_, fallback) = transport.requested[1]
    else {
        Issue.record("Expected original and hydration fallback resumes")
        return
    }
    #expect(first.developerInstructions == .value(
        "Current released renderer instructions"
    ))
    #expect(first.personality == .value(.friendly))
    #expect(fallback.developerInstructions == .omitted)
    #expect(fallback.personality == .omitted)
    #expect(fallback.threadID == first.threadID)
    #expect(fallback.cwd == first.cwd)
    #expect(fallback.config == first.config)
}

@MainActor
@Test
func desktopThreadResumeRetriesReleasedHydrationWhenPersonalityIsNull()
    async throws
{
    let thread = threadReadResumeMCPStoredThread()
    let requestID = CodexAppServerRequestID.string(
        "resume-renderer-hydration-null-personality"
    )
    let result = threadReadResumeMCPResumeResult(thread: thread)
    let reply = CodexAppServerReply<CodexThreadResumeResult>.success(
        .init(id: requestID, result: result)
    )
    let transport = ThreadResumeHydrationFallbackTransport(
        reply: try JSONEncoder().encode(reply)
    )
    let store = CodexSessionStore(transport: transport)

    let response = await CodexDesktopInitialMCPRouter
        .responseIncludingFileSystem(
            to: threadReadResumeMCPRequest(
                id: requestID,
                method: "thread/resume",
                params: .object([
                    "threadId": .string(thread.id.rawValue),
                    "model": .null,
                    "modelProvider": .null,
                    "cwd": .string("/workspace/current"),
                    "config": .object([
                        "features.realtime_conversation": .bool(true)
                    ]),
                    "developerInstructions": .string(
                        "Current released renderer instructions"
                    ),
                    "personality": .null,
                ])
            ),
            state: threadReadResumeMCPState(),
            allowedFileSystemRoots: [],
            threadLister: store
        )

    #expect(response == threadReadResumeMCPResult(
        id: requestID,
        value: try threadReadResumeMCPJSONValue(result)
    ))
    #expect(transport.requested.count == 2)
    guard transport.requested.count == 2,
          case let .resume(_, first) = transport.requested[0],
          case let .resume(_, fallback) = transport.requested[1]
    else {
        Issue.record("Expected original and null-personality fallback resumes")
        return
    }
    #expect(first.personality == .null)
    #expect(fallback.developerInstructions == .omitted)
    #expect(fallback.personality == .omitted)
    #expect(fallback.threadID == first.threadID)
    #expect(fallback.cwd == first.cwd)
    #expect(fallback.config == first.config)
}

@MainActor
@Test
func desktopThreadReadMigratesStaleIOSContainerCWDInRendererResponse()
    async throws
{
    let fileManager = FileManager.default
    let documents = try #require(
        fileManager.urls(for: .documentDirectory, in: .userDomainMask).first
    )
    let workspace = documents.appendingPathComponent(
        "codexpad-thread-read-\(UUID().uuidString)",
        isDirectory: true
    )
    try fileManager.createDirectory(at: workspace, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: workspace) }

    var thread = threadReadResumeMCPStoredThread()
    thread.cwd = staleIOSContainerPath(relativePath: workspace.lastPathComponent)
    let requestID = CodexAppServerRequestID.integer(4_111)
    let reply = CodexAppServerReply<CodexThreadReadResult>.success(
        .init(id: requestID, result: .init(thread: thread))
    )
    let transport = ThreadReadResumeMCPTransport(
        queuedReplies: [try JSONEncoder().encode(reply)]
    )
    let store = CodexSessionStore(transport: transport)

    let response = await CodexDesktopInitialMCPRouter
        .responseIncludingFileSystem(
            to: threadReadResumeMCPRequest(
                id: requestID,
                method: "thread/read",
                params: .object([
                    "threadId": .string(thread.id.rawValue),
                    "includeTurns": .bool(true),
                ])
            ),
            state: threadReadResumeMCPState(),
            allowedFileSystemRoots: [],
            threadLister: store
        )

    var migrated = thread
    migrated.cwd = workspace.standardizedFileURL.path
    #expect(
        response == threadReadResumeMCPResult(
            id: requestID,
            value: try threadReadResumeMCPJSONValue(
                CodexThreadReadResult(thread: migrated)
            )
        )
    )
}

@MainActor
@Test
func desktopThreadResumeMigratesOnlyExistingStaleIOSContainerCWD()
    async throws
{
    let fileManager = FileManager.default
    let documents = try #require(
        fileManager.urls(for: .documentDirectory, in: .userDomainMask).first
    )
    let workspace = documents.appendingPathComponent(
        "codexpad-thread-resume-\(UUID().uuidString)",
        isDirectory: true
    )
    try fileManager.createDirectory(at: workspace, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: workspace) }

    let thread = threadReadResumeMCPStoredThread()
    let requestIDs: [CodexAppServerRequestID] = [
        .integer(4_311), .integer(4_312), .integer(4_313),
    ]
    let result = threadReadResumeMCPResumeResult(thread: thread)
    let transport = ThreadReadResumeMCPTransport(
        queuedReplies: try requestIDs.map { id in
            try JSONEncoder().encode(
                CodexAppServerReply<CodexThreadResumeResult>.success(
                    .init(id: id, result: result)
                )
            )
        }
    )
    let store = CodexSessionStore(transport: transport)
    let staleExisting = staleIOSContainerPath(relativePath: workspace.lastPathComponent)
    let arbitraryOldPath = "/old/container/Documents/keep-me"
    let staleMissing = staleIOSContainerPath(relativePath: "missing-\(UUID().uuidString)")

    for (id, cwd) in zip(requestIDs, [staleExisting, arbitraryOldPath, staleMissing]) {
        _ = await CodexDesktopInitialMCPRouter
            .responseIncludingFileSystem(
                to: threadReadResumeMCPRequest(
                    id: id,
                    method: "thread/resume",
                    params: .object([
                        "threadId": .string(thread.id.rawValue),
                        "cwd": .string(cwd),
                    ])
                ),
                state: threadReadResumeMCPState(),
                allowedFileSystemRoots: [],
                threadLister: store
            )
    }

    #expect(transport.requested.count == 3)
    guard transport.requested.count == 3 else { return }
    guard case let .resume(_, migratedParams) = transport.requested[0],
          case let .resume(_, arbitraryParams) = transport.requested[1],
          case let .resume(_, missingParams) = transport.requested[2]
    else {
        Issue.record("Expected three thread/resume requests")
        return
    }
    #expect(migratedParams.cwd == .value(workspace.standardizedFileURL.path))
    #expect(arbitraryParams.cwd == .value(arbitraryOldPath))
    #expect(missingParams.cwd == .value(staleMissing))
}

@MainActor
@Test
func desktopThreadResumeMCPRouterRejectsMalformedParamsBeforeStore()
    async
{
    let transport = ThreadReadResumeMCPTransport()
    let store = CodexSessionStore(transport: transport)
    let validThreadID = CodexJSONValue.string("thread")
    let malformed: [CodexJSONValue?] = [
        nil,
        .null,
        .array([]),
        .object([:]),
        .object(["threadId": .bool(true)]),
        .object([
            "threadId": validThreadID,
            "model": .integer(1),
        ]),
        .object([
            "threadId": validThreadID,
            "modelProvider": .array([]),
        ]),
        .object([
            "threadId": validThreadID,
            "serviceTier": .bool(false),
        ]),
        .object([
            "threadId": validThreadID,
            "cwd": .object([:]),
        ]),
        .object([
            "threadId": validThreadID,
            "approvalPolicy": .string("sometimes"),
        ]),
        .object([
            "threadId": validThreadID,
            "approvalPolicy": .object([
                "granular": .object([
                    "sandbox_approval": .bool(true)
                ])
            ]),
        ]),
        .object([
            "threadId": validThreadID,
            "approvalsReviewer": .string("future-reviewer"),
        ]),
        .object([
            "threadId": validThreadID,
            "sandbox": .string("container"),
        ]),
        .object([
            "threadId": validThreadID,
            "config": .array([]),
        ]),
        .object([
            "threadId": validThreadID,
            "baseInstructions": .bool(true),
        ]),
        .object([
            "threadId": validThreadID,
            "developerInstructions": .integer(1),
        ]),
        .object([
            "threadId": validThreadID,
            "personality": .string("future"),
        ]),
    ]

    for (offset, params) in malformed.enumerated() {
        let id = CodexAppServerRequestID.integer(
            Int64(4_400 + offset)
        )
        let response =
            await CodexDesktopInitialMCPRouter
                .responseIncludingFileSystem(
                    to: threadReadResumeMCPRequest(
                        id: id,
                        method: "thread/resume",
                        params: params
                    ),
                    state: threadReadResumeMCPState(),
                    allowedFileSystemRoots: [],
                    threadLister: store
                )

        #expect(
            response
                == threadReadResumeMCPError(
                    id: id,
                    code: -32602,
                    message: "Invalid params for thread/resume"
                )
        )
    }

    #expect(transport.requested.isEmpty)
}

@MainActor
@Test
func desktopThreadReadResumeMCPRouterPreservesBackendErrors()
    async throws
{
    let thread = threadReadResumeMCPStoredThread()
    let readID = CodexAppServerRequestID.string("read-error")
    let resumeID = CodexAppServerRequestID.integer(4_501)
    let errorData = CodexJSONValue.object([
        "field": .string("threadId"),
        "retryable": .bool(false),
    ])
    let readReply =
        CodexAppServerReply<CodexThreadReadResult>.failure(
            .init(
                id: readID,
                error: .init(
                    code: -32_070,
                    message: "thread read failed",
                    data: errorData
                )
            )
        )
    let resumeReply =
        CodexAppServerReply<CodexThreadResumeResult>.failure(
            .init(
                id: resumeID,
                error: .init(
                    code: -32_071,
                    message: "thread resume failed",
                    data: errorData
                )
            )
        )
    let transport = ThreadReadResumeMCPTransport(
        queuedReplies: [
            try JSONEncoder().encode(readReply),
            try JSONEncoder().encode(resumeReply),
        ]
    )
    let store = CodexSessionStore(transport: transport)

    let readResponse =
        await CodexDesktopInitialMCPRouter
            .responseIncludingFileSystem(
                to: threadReadResumeMCPRequest(
                    id: readID,
                    method: "thread/read",
                    params: .object([
                        "threadId": .string(thread.id.rawValue)
                    ])
                ),
                state: threadReadResumeMCPState(),
                allowedFileSystemRoots: [],
                threadLister: store
            )
    let resumeResponse =
        await CodexDesktopInitialMCPRouter
            .responseIncludingFileSystem(
                to: threadReadResumeMCPRequest(
                    id: resumeID,
                    method: "thread/resume",
                    params: .object([
                        "threadId": .string(thread.id.rawValue)
                    ])
                ),
                state: threadReadResumeMCPState(),
                allowedFileSystemRoots: [],
                threadLister: store
            )

    #expect(
        readResponse
            == threadReadResumeMCPError(
                id: readID,
                code: -32_070,
                message: "thread read failed",
                data: errorData
            )
    )
    #expect(
        resumeResponse
            == threadReadResumeMCPError(
                id: resumeID,
                code: -32_071,
                message: "thread resume failed",
                data: errorData
            )
    )
}

@MainActor
@Test
func desktopThreadReadResumeMCPRouterDoesNotFakeUnavailableSuccess()
    async
{
    let boundary = ThreadReadResumeMCPListOnlyBoundary()
    let cases: [
        (
            method: String,
            id: CodexAppServerRequestID,
            unavailableMessage: String
        )
    ] = [
        (
            "thread/read",
            .string("read-unavailable"),
            "Thread session reading unavailable"
        ),
        (
            "thread/resume",
            .integer(4_601),
            "Thread session resuming unavailable"
        ),
    ]

    for item in cases {
        let response =
            await CodexDesktopInitialMCPRouter
                .responseIncludingFileSystem(
                    to: threadReadResumeMCPRequest(
                        id: item.id,
                        method: item.method,
                        params: .object([
                            "threadId": .string("thread")
                        ])
                    ),
                    state: threadReadResumeMCPState(),
                    allowedFileSystemRoots: [],
                    threadLister: boundary
                )
        #expect(
            response
                == threadReadResumeMCPError(
                    id: item.id,
                    code: -32603,
                    message: item.unavailableMessage
                )
        )
    }
}

private func threadReadResumeMCPRequest(
    id: CodexAppServerRequestID,
    method: String,
    params: CodexJSONValue?
) -> CodexDesktopMCPRequest {
    CodexDesktopMCPRequest(
        request: .init(
            id: id,
            method: method,
            params: params,
            metadata: [:]
        ),
        hostID: "desktop-host-thread-read-resume",
        dispatchedAtMs: .integer(100),
        priority: .string("startup"),
        source: .string("renderer"),
        timeoutMs: .integer(5_000),
        expiresAtMs: .integer(5_100),
        metadata: [:]
    )
}

private func threadReadResumeMCPState()
    -> CodexDesktopInitialMCPState
{
    CodexDesktopInitialMCPState(
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
            status: .connected,
            serverName: "Codex-for-iPad",
            installationID: "installation",
            environmentID: nil
        )
    )
}

private func threadReadResumeMCPStoredThread() -> CodexStoredThread {
    CodexStoredThread(
        id: .init(" 任务/thread-Ω/../原样 "),
        sessionID: "session-read-resume",
        preview: "Real persisted thread",
        ephemeral: false,
        modelProvider: "openai",
        createdAt: 100,
        updatedAt: 200,
        recencyAt: 200,
        status: .idle,
        path: "/tmp/rollout.jsonl",
        cwd: "/workspace",
        cliVersion: "1.0.0",
        source: .named("cli"),
        name: "Persisted task",
        turns: []
    )
}

private func staleIOSContainerPath(relativePath: String) -> String {
    "/var/mobile/Containers/Data/Application/"
        + "11111111-2222-3333-4444-555555555555/Documents/"
        + relativePath
}

private func threadReadResumeMCPResumeResult(
    thread: CodexStoredThread
) -> CodexThreadResumeResult {
    CodexThreadResumeResult(
        thread: thread,
        model: "model-next",
        modelProvider: "provider-next",
        serviceTier: nil,
        cwd: "/workspace",
        instructionSources: ["base", "developer"],
        approvalPolicy: .onRequest,
        approvalsReviewer: .user,
        sandbox: .workspaceWrite(
            writableRoots: ["/workspace"],
            networkAccess: false,
            excludeTmpdirEnvVar: false,
            excludeSlashTmp: false
        ),
        reasoningEffort: "high"
    )
}

private func threadReadResumeMCPJSONValue<Value: Encodable>(
    _ value: Value
) throws -> CodexJSONValue {
    try JSONDecoder().decode(
        CodexJSONValue.self,
        from: JSONEncoder().encode(value)
    )
}

private func threadReadResumeMCPResult(
    id: CodexAppServerRequestID,
    value: CodexJSONValue
) -> CodexDesktopHostMessage {
    .mcpResponse(
        hostID: "desktop-host-thread-read-resume",
        message: .object([
            "id": threadReadResumeMCPIDValue(id),
            "result": value,
        ]),
        metadata: [:]
    )
}

private func threadReadResumeMCPError(
    id: CodexAppServerRequestID,
    code: Int64,
    message: String,
    data: CodexJSONValue? = nil
) -> CodexDesktopHostMessage {
    var payload: [String: CodexJSONValue] = [
        "code": .integer(code),
        "message": .string(message),
    ]
    if let data {
        payload["data"] = data
    }
    return .mcpResponse(
        hostID: "desktop-host-thread-read-resume",
        message: .object([
            "id": threadReadResumeMCPIDValue(id),
            "error": .object(payload),
        ]),
        metadata: [:]
    )
}

private func threadReadResumeMCPIDValue(
    _ id: CodexAppServerRequestID
) -> CodexJSONValue {
    switch id {
    case let .string(value):
        return .string(value)
    case let .integer(value):
        return .integer(value)
    }
}
