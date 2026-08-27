import Foundation
import Testing
@testable import CodexPadApplication

private typealias TerminalValue = CodexDesktopAppHostRPC.Value
private typealias TerminalRequest = CodexDesktopTerminalAppHostService.SessionRequest
private typealias TerminalSnapshot = CodexDesktopTerminalAppHostService.ThreadSnapshot

@Test
func desktopTerminalCreateAndAttachForwardReleasedSessionRequest() async throws {
    let manager = RecordingTerminalManager()
    let service = CodexDesktopTerminalAppHostService(manager: manager)

    let createResult = try await service.invoke(
        service: "terminal",
        method: "create",
        arguments: [
            .object([
                "sessionId": .string("session-create"),
                "conversationId": .string("thread-create"),
                "conversationTitle": .string("Create title"),
                "hostId": .string("local"),
                "cwd": .string("/workspace/create"),
                "forceCwdSync": .bool(true),
                "cols": .integer(132),
                "rows": .integer(41),
                "preserveOnOwnerDestroy": .bool(true),
                "trace": .import(91),
                "type": .string("caller-must-not-select-operation"),
            ]),
        ]
    )
    let attachResult = try await service.invoke(
        service: "terminal",
        method: "attach",
        arguments: [
            .object([
                "sessionId": .string("session-attach"),
                "conversationId": .string("thread-attach"),
                "conversationTitle": .string("Attach title"),
                "hostId": .string("remote-host"),
                "cwd": .string("/workspace/attach"),
                "forceCwdSync": .bool(false),
                "cols": .integer(90),
                "rows": .integer(28),
                "preserveOnOwnerDestroy": .bool(false),
                "type": .string("caller-must-not-select-operation"),
            ]),
        ]
    )

    #expect(createResult == .undefined)
    #expect(attachResult == .undefined)
    #expect(
        await manager.sessionRequests == [
            TerminalRequest(
                kind: .create,
                sessionID: "session-create",
                conversationID: "thread-create",
                conversationTitle: "Create title",
                hostID: "local",
                cwd: "/workspace/create",
                forceCWDSync: true,
                columns: 132,
                rows: 41,
                preserveOnOwnerDestroy: true
            ),
            TerminalRequest(
                kind: .attach,
                sessionID: "session-attach",
                conversationID: "thread-attach",
                conversationTitle: "Attach title",
                hostID: "remote-host",
                cwd: "/workspace/attach",
                forceCWDSync: false,
                columns: 90,
                rows: 28,
                preserveOnOwnerDestroy: false
            ),
        ]
    )
}

@Test
func desktopTerminalRoutesReleasedSessionOperationsInOfficialArgumentOrder() async throws {
    let manager = RecordingTerminalManager(shellCWDResult: "/workspace/reported")
    let service = CodexDesktopTerminalAppHostService(manager: manager)

    let closeResult = try await service.invoke(
        service: "terminal",
        method: "close",
        arguments: [.string("session-1")]
    )
    let cwdResult = try await service.invoke(
        service: "terminal",
        method: "getShellCwd",
        arguments: [.string("session-1"), .string("/workspace/requested")]
    )
    let resizeResult = try await service.invoke(
        service: "terminal",
        method: "resize",
        arguments: [.string("session-1"), .integer(132), .integer(41), .bool(true)]
    )
    let actionResult = try await service.invoke(
        service: "terminal",
        method: "runAction",
        arguments: [
            .string("session-1"),
            .string("/workspace/action"),
            .string("printf hello"),
        ]
    )
    let writeResult = try await service.invoke(
        service: "terminal",
        method: "write",
        arguments: [.string("session-1"), .string("\u{1B}[A")]
    )

    #expect(closeResult == .undefined)
    #expect(cwdResult == .string("/workspace/reported"))
    #expect(resizeResult == .undefined)
    #expect(actionResult == .undefined)
    #expect(writeResult == .undefined)
    #expect(
        await manager.operations == [
            .close(sessionID: "session-1"),
            .getShellCWD(
                sessionID: "session-1",
                requestedCWD: "/workspace/requested"
            ),
            .resize(
                sessionID: "session-1",
                columns: 132,
                rows: 41,
                repaint: true
            ),
            .runAction(
                sessionID: "session-1",
                cwd: "/workspace/action",
                command: "printf hello"
            ),
            .write(sessionID: "session-1", data: "\u{1B}[A"),
        ]
    )
}

@Test
func desktopTerminalReturnsReleasedShellsAndThreadSnapshotShapes() async throws {
    let snapshot = TerminalSnapshot(
        cwd: "/workspace/thread",
        shell: "/bin/zsh",
        buffer: "terminal output",
        truncated: false
    )
    let manager = RecordingTerminalManager(snapshotResult: snapshot)
    let service = CodexDesktopTerminalAppHostService(manager: manager)

    let shells = try await service.invoke(
        service: "terminal",
        method: "getAvailableShells",
        arguments: []
    )
    let returnedSnapshot = try await service.invoke(
        service: "terminal",
        method: "getThreadSnapshot",
        arguments: [.string("thread-1")]
    )

    #expect(shells == .array([]))
    #expect(
        returnedSnapshot == .object([
            "cwd": .string("/workspace/thread"),
            "shell": .string("/bin/zsh"),
            "buffer": .string("terminal output"),
            "truncated": .bool(false),
        ])
    )
    #expect(
        await manager.operations == [
            .getThreadSnapshot(conversationID: "thread-1"),
        ]
    )

    await manager.setSnapshotResult(nil)
    let missingSnapshot = try await service.invoke(
        service: "terminal",
        method: "getThreadSnapshot",
        arguments: [.string("thread-without-terminal")]
    )
    #expect(missingSnapshot == .null)
}

@Test
func desktopTerminalSubscribeReplacesAndUnsubscribesReleasedCallback() async throws {
    let manager = RecordingTerminalManager()
    let recorder = TerminalSubscriptionRecorder()
    let service = CodexDesktopTerminalAppHostService(
        manager: manager,
        subscriptionEventHandler: { callbackID, event in
            await recorder.record(callbackID: callbackID, event: event)
        }
    )
    let firstEvent: TerminalValue = .object([
        "type": .string("data"),
        "sessionId": .string("session-1"),
        "data": .string("first"),
    ])
    let secondEvent: TerminalValue = .object([
        "type": .string("exit"),
        "sessionId": .string("session-1"),
        "code": .integer(0),
        "signal": .null,
    ])

    #expect(
        try await service.invoke(
            service: "terminal",
            method: "subscribe",
            arguments: [.import(7)]
        ) == .undefined
    )
    await manager.emit(firstEvent)
    #expect(
        await recorder.deliveries == [
            .init(callbackID: 7, event: firstEvent),
        ]
    )

    #expect(
        try await service.invoke(
            service: "terminal",
            method: "subscribe",
            arguments: [.import(8)]
        ) == .undefined
    )
    #expect(await manager.cancellationCount == 1)
    await manager.emit(secondEvent)
    #expect(
        await recorder.deliveries == [
            .init(callbackID: 7, event: firstEvent),
            .init(callbackID: 8, event: secondEvent),
        ]
    )

    #expect(
        try await service.invoke(
            service: "terminal",
            method: "unsubscribe",
            arguments: []
        ) == .undefined
    )
    #expect(await manager.cancellationCount == 2)
    await manager.emit(firstEvent)
    #expect(await recorder.deliveries.count == 2)
}

@Test
func desktopTerminalDefaultHandlerDoesNotFabricateSessions() async throws {
    let service = CodexDesktopTerminalAppHostService()

    #expect(
        try await service.invoke(
            service: "terminal",
            method: "getAvailableShells",
            arguments: []
        ) == .array([])
    )
    await #expect(
        throws: CodexDesktopTerminalAppHostService.Error.managerUnavailable
    ) {
        _ = try await service.invoke(
            service: "terminal",
            method: "create",
            arguments: [.object(["sessionId": .string("session-1")])]
        )
    }
}

@Test
func desktopTerminalRejectsMalformedReleasedCalls() async throws {
    let manager = RecordingTerminalManager()
    let service = CodexDesktopTerminalAppHostService(manager: manager)

    await #expect(
        throws: CodexDesktopTerminalAppHostService.Error.invalidArguments
    ) {
        _ = try await service.invoke(
            service: "terminal",
            method: "resize",
            arguments: [
                .string("session-1"),
                .integer(132),
                .integer(41),
                .string("true"),
            ]
        )
    }
    await #expect(
        throws: CodexDesktopTerminalAppHostService.Error.invalidArguments
    ) {
        _ = try await service.invoke(
            service: "terminal",
            method: "subscribe",
            arguments: [.string("callback-7")]
        )
    }
    await #expect(
        throws: CodexDesktopTerminalAppHostService.Error.invalidArguments
    ) {
        _ = try await service.invoke(
            service: "terminal",
            method: "create",
            arguments: [
                .object([
                    "sessionId": .string("session-1"),
                    "cols": .integer(0),
                ]),
            ]
        )
    }
    await #expect(
        throws: CodexDesktopTerminalAppHostService.Error.unsupportedMethod(
            service: "terminal",
            method: "unknown"
        )
    ) {
        _ = try await service.invoke(
            service: "terminal",
            method: "unknown",
            arguments: []
        )
    }
}

private actor RecordingTerminalManager: CodexDesktopTerminalAppHostManaging {
    enum Operation: Equatable, Sendable {
        case close(sessionID: String)
        case getShellCWD(sessionID: String, requestedCWD: String)
        case getThreadSnapshot(conversationID: String)
        case resize(sessionID: String, columns: UInt32, rows: UInt32, repaint: Bool)
        case runAction(sessionID: String, cwd: String, command: String)
        case write(sessionID: String, data: String)
    }

    private(set) var sessionRequests: [TerminalRequest] = []
    private(set) var operations: [Operation] = []
    private(set) var cancellationCount = 0

    private var shellCWDResult: String?
    private var snapshotResult: TerminalSnapshot?
    private var subscriptions: [UUID: CodexDesktopTerminalEventReceiver] = [:]

    init(
        shellCWDResult: String? = nil,
        snapshotResult: TerminalSnapshot? = nil
    ) {
        self.shellCWDResult = shellCWDResult
        self.snapshotResult = snapshotResult
    }

    func createOrAttach(_ request: TerminalRequest) async throws {
        sessionRequests.append(request)
    }

    func close(sessionID: String) async throws {
        operations.append(.close(sessionID: sessionID))
    }

    func getShellCWD(
        sessionID: String,
        requestedCWD: String
    ) async throws -> String? {
        operations.append(
            .getShellCWD(
                sessionID: sessionID,
                requestedCWD: requestedCWD
            )
        )
        return shellCWDResult
    }

    func getThreadSnapshot(
        conversationID: String
    ) async throws -> TerminalSnapshot? {
        operations.append(.getThreadSnapshot(conversationID: conversationID))
        return snapshotResult
    }

    func resize(
        sessionID: String,
        columns: UInt32,
        rows: UInt32,
        repaint: Bool
    ) async throws {
        operations.append(
            .resize(
                sessionID: sessionID,
                columns: columns,
                rows: rows,
                repaint: repaint
            )
        )
    }

    func runAction(
        sessionID: String,
        cwd: String,
        command: String
    ) async throws {
        operations.append(
            .runAction(sessionID: sessionID, cwd: cwd, command: command)
        )
    }

    func write(sessionID: String, data: String) async throws {
        operations.append(.write(sessionID: sessionID, data: data))
    }

    func subscribe(
        _ receive: @escaping CodexDesktopTerminalEventReceiver
    ) async throws -> CodexDesktopTerminalUnsubscribe {
        let token = UUID()
        subscriptions[token] = receive
        return { [weak self] in
            if let self {
                await self.cancelSubscription(token)
            }
        }
    }

    func emit(_ event: TerminalValue) async {
        let receivers = Array(subscriptions.values)
        for receive in receivers {
            await receive(event)
        }
    }

    func setSnapshotResult(_ result: TerminalSnapshot?) {
        snapshotResult = result
    }

    private func cancelSubscription(_ token: UUID) {
        if subscriptions.removeValue(forKey: token) != nil {
            cancellationCount += 1
        }
    }
}

private actor TerminalSubscriptionRecorder {
    struct Delivery: Equatable, Sendable {
        let callbackID: Int
        let event: TerminalValue
    }

    private(set) var deliveries: [Delivery] = []

    func record(callbackID: Int, event: TerminalValue) {
        deliveries.append(.init(callbackID: callbackID, event: event))
    }
}
