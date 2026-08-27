import Foundation
import Testing
@testable import CodexPadApplication

private typealias SessionManagerValue = CodexDesktopAppHostRPC.Value
private typealias SessionManagerRequest =
    CodexDesktopTerminalAppHostService.SessionRequest

@MainActor
@Test
func desktopTerminalSessionManagerCreatesStreamsSnapshotsAndCloses() async throws {
    let fixture = try TerminalSessionFixture()
    defer { fixture.remove() }
    let driver = RecordingTerminalProcessDriver()
    let manager = CodexDesktopTerminalSessionManager(
        processDriver: driver,
        allowedWorkspaceRoots: [fixture.root]
    )
    let events = TerminalSessionEventRecorder()
    let unsubscribe = try await manager.subscribe {
        await events.record($0)
    }

    try await manager.createOrAttach(
        SessionManagerRequest(
            kind: .create,
            sessionID: "session-1",
            conversationID: "thread-1",
            conversationTitle: "Terminal title",
            hostID: "local",
            cwd: fixture.root,
            columns: 132,
            rows: 41
        )
    )

    let starts = await driver.recordedStarts
    #expect(starts.count == 1)
    #expect(starts[0].request.cwd == fixture.root)
    #expect(starts[0].request.columns == 132)
    #expect(starts[0].request.rows == 41)
    #expect(starts[0].request.environment["TERM"] == "xterm-256color")
    #expect(
        await events.values == [
            .object([
                "type": .string("attached"),
                "sessionId": .string("session-1"),
                "cwd": .string(fixture.root),
                "shell": .string("sh"),
            ]),
        ]
    )

    await driver.emitData(
        processID: starts[0].request.processID,
        data: "hello\n"
    )
    #expect(
        try await manager.getThreadSnapshot(
            conversationID: "thread-1"
        ) == .init(
            cwd: fixture.root,
            shell: "sh",
            buffer: "hello\n",
            truncated: false
        )
    )
    #expect(
        await events.values.last == .object([
            "type": .string("data"),
            "sessionId": .string("session-1"),
            "data": .string("hello\n"),
        ])
    )

    try await manager.close(sessionID: "session-1")
    #expect(await driver.terminatedProcessIDs == [starts[0].request.processID])
    #expect(
        await events.values.last == .object([
            "type": .string("exit"),
            "sessionId": .string("session-1"),
            "code": .null,
            "signal": .null,
        ])
    )
    #expect(
        try await manager.getThreadSnapshot(
            conversationID: "thread-1"
        ) == nil
    )
    await unsubscribe()
}

@MainActor
@Test
func desktopTerminalSessionManagerAttachUsesConversationFallbackAndReplaysBuffer()
    async throws
{
    let fixture = try TerminalSessionFixture()
    defer { fixture.remove() }
    let nested = fixture.rootURL.appendingPathComponent(
        "nested",
        isDirectory: true
    )
    try FileManager.default.createDirectory(
        at: nested,
        withIntermediateDirectories: true
    )
    let driver = RecordingTerminalProcessDriver()
    let manager = CodexDesktopTerminalSessionManager(
        processDriver: driver,
        allowedWorkspaceRoots: [fixture.root]
    )
    let events = TerminalSessionEventRecorder()
    _ = try await manager.subscribe {
        await events.record($0)
    }

    try await manager.createOrAttach(
        SessionManagerRequest(
            kind: .create,
            sessionID: "session-old",
            conversationID: "thread-1",
            cwd: fixture.root,
            columns: 80,
            rows: 24
        )
    )
    let processID = try #require(
        await driver.recordedStarts.first?.request.processID
    )
    await driver.emitData(processID: processID, data: "buffered")
    await events.removeAll()

    try await manager.createOrAttach(
        SessionManagerRequest(
            kind: .attach,
            sessionID: "session-new",
            conversationID: "thread-1",
            cwd: nested.path,
            forceCWDSync: true,
            columns: 100,
            rows: 30,
            preserveOnOwnerDestroy: true
        )
    )

    #expect(
        await events.values == [
            .object([
                "type": .string("init-log"),
                "sessionId": .string("session-new"),
                "log": .string("buffered"),
            ]),
            .object([
                "type": .string("attached"),
                "sessionId": .string("session-new"),
                "cwd": .string(nested.path),
                "shell": .string("sh"),
            ]),
        ]
    )
    #expect(
        await driver.resizeCalls == [
            .init(processID: processID, columns: 100, rows: 30),
        ]
    )
    let writes = await driver.writeCalls
    #expect(writes.count == 1)
    #expect(writes[0].processID == processID)
    #expect(writes[0].data.contains(nested.path))
    #expect(
        try await manager.getShellCWD(
            sessionID: "session-new",
            requestedCWD: nested.path
        ) == nested.path
    )
}

@MainActor
@Test
func desktopTerminalSessionManagerRunActionRestartsAndIgnoresPriorExit()
    async throws
{
    let fixture = try TerminalSessionFixture()
    defer { fixture.remove() }
    let driver = RecordingTerminalProcessDriver()
    let manager = CodexDesktopTerminalSessionManager(
        processDriver: driver,
        allowedWorkspaceRoots: [fixture.root]
    )
    let events = TerminalSessionEventRecorder()
    _ = try await manager.subscribe {
        await events.record($0)
    }
    try await manager.createOrAttach(
        SessionManagerRequest(
            kind: .create,
            sessionID: "session-1",
            conversationID: "thread-1",
            cwd: fixture.root
        )
    )
    let firstProcessID = try #require(
        await driver.recordedStarts.first?.request.processID
    )
    await driver.emitData(
        processID: firstProcessID,
        data: "old output"
    )
    await events.removeAll()

    try await manager.runAction(
        sessionID: "session-1",
        cwd: fixture.root,
        command: "printf hello"
    )

    let starts = await driver.recordedStarts
    #expect(starts.count == 2)
    #expect(await driver.terminatedProcessIDs == [firstProcessID])
    #expect(
        await events.values == [
            .object([
                "type": .string("init-log"),
                "sessionId": .string("session-1"),
                "log": .string(""),
            ]),
            .object([
                "type": .string("attached"),
                "sessionId": .string("session-1"),
                "cwd": .string(fixture.root),
                "shell": .string("sh"),
            ]),
        ]
    )
    let actionWrite = try #require(await driver.writeCalls.last)
    #expect(actionWrite.processID == starts[1].request.processID)
    #expect(actionWrite.data.contains("printf hello"))

    await driver.emitExit(
        processID: firstProcessID,
        exit: .init(code: 0, signal: nil, errorMessage: nil)
    )
    #expect(
        try await manager.getThreadSnapshot(
            conversationID: "thread-1"
        ) != nil
    )
}

@MainActor
@Test
func desktopTerminalSessionManagerCapsSnapshotAndRejectsOutsideWorkspace()
    async throws
{
    let fixture = try TerminalSessionFixture()
    defer { fixture.remove() }
    let driver = RecordingTerminalProcessDriver()
    let manager = CodexDesktopTerminalSessionManager(
        processDriver: driver,
        allowedWorkspaceRoots: [fixture.root]
    )
    let events = TerminalSessionEventRecorder()
    _ = try await manager.subscribe {
        await events.record($0)
    }
    try await manager.createOrAttach(
        SessionManagerRequest(
            kind: .create,
            sessionID: "session-1",
            conversationID: "thread-1",
            cwd: fixture.root
        )
    )
    let processID = try #require(
        await driver.recordedStarts.first?.request.processID
    )
    await driver.emitData(
        processID: processID,
        data: String(repeating: "x", count: 16_100)
    )
    let snapshot = try #require(
        try await manager.getThreadSnapshot(
            conversationID: "thread-1"
        )
    )
    #expect(snapshot.buffer.count == 16_000)
    #expect(snapshot.truncated)

    try await manager.createOrAttach(
        SessionManagerRequest(
            kind: .create,
            sessionID: "outside",
            cwd: "/private/outside-workspace"
        )
    )
    #expect(await driver.recordedStarts.count == 1)
    #expect(
        await events.values.last == .object([
            "type": .string("error"),
            "sessionId": .string("outside"),
            "message": .string("Terminal cwd is outside the authorized workspace"),
        ])
    )
}

private struct TerminalSessionFixture {
    let rootURL: URL
    var root: String { rootURL.path }

    init() throws {
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "codex-terminal-manager-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: rootURL)
    }
}

private actor TerminalSessionEventRecorder {
    private(set) var values: [SessionManagerValue] = []

    func record(_ value: SessionManagerValue) {
        values.append(value)
    }

    func removeAll() {
        values.removeAll()
    }
}

private actor RecordingTerminalProcessDriver:
    CodexDesktopTerminalProcessDriving
{
    struct Start: Sendable {
        let request: CodexDesktopTerminalProcessRequest
    }

    struct WriteCall: Equatable, Sendable {
        let processID: String
        let data: String
    }

    struct ResizeCall: Equatable, Sendable {
        let processID: String
        let columns: UInt32
        let rows: UInt32
    }

    enum DriverError: Swift.Error {
        case missingProcess
    }

    private(set) var recordedStarts: [Start] = []
    private(set) var writeCalls: [WriteCall] = []
    private(set) var resizeCalls: [ResizeCall] = []
    private(set) var terminatedProcessIDs: [String] = []
    private var dataReceivers:
        [String: @Sendable (String) async -> Void] = [:]
    private var exitReceivers:
        [
            String:
                @Sendable (CodexDesktopTerminalProcessExit) async -> Void
        ] = [:]

    func start(
        _ request: CodexDesktopTerminalProcessRequest,
        onData: @escaping @Sendable (String) async -> Void,
        onExit:
            @escaping @Sendable (
                CodexDesktopTerminalProcessExit
            ) async -> Void
    ) async throws -> any CodexDesktopTerminalProcessHandling {
        recordedStarts.append(.init(request: request))
        dataReceivers[request.processID] = onData
        exitReceivers[request.processID] = onExit
        return RecordingTerminalProcess(
            processID: request.processID,
            driver: self
        )
    }

    func emitData(processID: String, data: String) async {
        await dataReceivers[processID]?(data)
    }

    func emitExit(
        processID: String,
        exit: CodexDesktopTerminalProcessExit
    ) async {
        await exitReceivers[processID]?(exit)
    }

    func recordWrite(processID: String, data: String) throws {
        guard dataReceivers[processID] != nil else {
            throw DriverError.missingProcess
        }
        writeCalls.append(
            .init(processID: processID, data: data)
        )
    }

    func recordResize(
        processID: String,
        columns: UInt32,
        rows: UInt32
    ) throws {
        guard dataReceivers[processID] != nil else {
            throw DriverError.missingProcess
        }
        resizeCalls.append(
            .init(
                processID: processID,
                columns: columns,
                rows: rows
            )
        )
    }

    func recordTerminate(processID: String) {
        terminatedProcessIDs.append(processID)
    }
}

private struct RecordingTerminalProcess:
    CodexDesktopTerminalProcessHandling
{
    let processID: String
    let driver: RecordingTerminalProcessDriver

    func write(_ data: String) async throws {
        try await driver.recordWrite(
            processID: processID,
            data: data
        )
    }

    func resize(columns: UInt32, rows: UInt32) async throws {
        try await driver.recordResize(
            processID: processID,
            columns: columns,
            rows: rows
        )
    }

    func terminate() async throws {
        await driver.recordTerminate(processID: processID)
    }
}
