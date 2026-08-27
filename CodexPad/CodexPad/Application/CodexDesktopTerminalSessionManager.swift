#if SWIFT_PACKAGE
import CodexPadDomain
#endif
import Foundation

public struct CodexDesktopTerminalProcessRequest:
    Equatable,
    Sendable
{
    public let processID: String
    public let hostID: String?
    public let command: [String]
    public let cwd: String
    public let columns: UInt32
    public let rows: UInt32
    public let environment: [String: String]
    public let allowedWorkspaceRoots: [String]

    public init(
        processID: String,
        hostID: String?,
        command: [String],
        cwd: String,
        columns: UInt32,
        rows: UInt32,
        environment: [String: String],
        allowedWorkspaceRoots: [String]
    ) {
        self.processID = processID
        self.hostID = hostID
        self.command = command
        self.cwd = cwd
        self.columns = columns
        self.rows = rows
        self.environment = environment
        self.allowedWorkspaceRoots = allowedWorkspaceRoots
    }
}

public struct CodexDesktopTerminalProcessExit:
    Equatable,
    Sendable
{
    public let code: Int64?
    public let signal: String?
    public let errorMessage: String?

    public init(
        code: Int64?,
        signal: String?,
        errorMessage: String?
    ) {
        self.code = code
        self.signal = signal
        self.errorMessage = errorMessage
    }
}

public protocol CodexDesktopTerminalProcessHandling: Sendable {
    func write(_ data: String) async throws
    func resize(columns: UInt32, rows: UInt32) async throws
    func terminate() async throws
}

public protocol CodexDesktopTerminalProcessDriving: Sendable {
    func start(
        _ request: CodexDesktopTerminalProcessRequest,
        onData: @escaping @Sendable (String) async -> Void,
        onExit:
            @escaping @Sendable (
                CodexDesktopTerminalProcessExit
            ) async -> Void
    ) async throws -> any CodexDesktopTerminalProcessHandling
}

/// Port-scoped terminal owner matching the released `Jye` session lifecycle.
///
/// Public terminal IDs are isolated from the process executor IDs so two
/// renderer ports may use the same session ID without sharing ownership.
/// Conversation fallback, buffer replay, action restart, repaint resize, and
/// the five released event shapes are all owned here rather than in the RPC
/// adapter.
public actor CodexDesktopTerminalSessionManager:
    CodexDesktopTerminalAppHostManaging
{
    public enum Error: Swift.Error, Equatable, Sendable {
        case noAuthorizedWorkspace
    }

    private final class Session: @unchecked Sendable {
        var id: String
        var generation: UUID
        var process:
            any CodexDesktopTerminalProcessHandling
        var conversationID: String?
        var conversationTitle: String?
        var hostID: String?
        var cwd: String
        var shell: String
        var columns: UInt32
        var rows: UInt32
        var buffer = ""
        var truncated = false
        var attached = true
        var preserveOnOwnerDestroy: Bool

        init(
            id: String,
            generation: UUID,
            process:
                any CodexDesktopTerminalProcessHandling,
            conversationID: String?,
            conversationTitle: String?,
            hostID: String?,
            cwd: String,
            shell: String,
            columns: UInt32,
            rows: UInt32,
            preserveOnOwnerDestroy: Bool
        ) {
            self.id = id
            self.generation = generation
            self.process = process
            self.conversationID = conversationID
            self.conversationTitle = conversationTitle
            self.hostID = hostID
            self.cwd = cwd
            self.shell = shell
            self.columns = columns
            self.rows = rows
            self.preserveOnOwnerDestroy =
                preserveOnOwnerDestroy
        }
    }

    private static let bufferLimit = 16_000
    private static let defaultColumns: UInt32 = 80
    private static let defaultRows: UInt32 = 24

    private let processDriver:
        any CodexDesktopTerminalProcessDriving
    private let allowedWorkspaceRoots: [URL]
    private let processNamespace = UUID().uuidString
    private var sessions: [String: Session] = [:]
    private var conversationSessions: [String: String] = [:]
    private var subscribers:
        [UUID: CodexDesktopTerminalEventReceiver] = [:]

    public init(
        processDriver:
            any CodexDesktopTerminalProcessDriving,
        allowedWorkspaceRoots: [String]
    ) {
        self.processDriver = processDriver
        self.allowedWorkspaceRoots =
            allowedWorkspaceRoots.map {
                URL(
                    fileURLWithPath: $0,
                    isDirectory: true
                ).standardizedFileURL
                    .resolvingSymlinksInPath()
            }
    }

    public func createOrAttach(
        _ request:
            CodexDesktopTerminalAppHostService.SessionRequest
    ) async throws {
        if let existing = existingSession(for: request) {
            await attach(existing, request: request)
        } else {
            await create(request)
        }
    }

    public func close(sessionID: String) async throws {
        guard let session = sessions[sessionID] else {
            return
        }
        remove(session)
        do {
            try await session.process.terminate()
        } catch {
            await sendError(
                sessionID: session.id,
                message: String(describing: error)
            )
        }
        await sendExit(
            sessionID: session.id,
            code: nil,
            signal: nil
        )
    }

    public func getShellCWD(
        sessionID: String,
        requestedCWD: String
    ) async throws -> String? {
        guard sessions[sessionID] != nil else {
            return nil
        }
        return requestedCWD
    }

    public func getThreadSnapshot(
        conversationID: String
    ) async throws
        -> CodexDesktopTerminalAppHostService.ThreadSnapshot?
    {
        guard let sessionID =
                conversationSessions[conversationID],
              let session = sessions[sessionID]
        else {
            return nil
        }
        return .init(
            cwd: session.cwd,
            shell: session.shell,
            buffer: session.buffer,
            truncated: session.truncated
                || session.buffer.count
                    >= Self.bufferLimit
        )
    }

    public func resize(
        sessionID: String,
        columns: UInt32,
        rows: UInt32,
        repaint: Bool
    ) async throws {
        guard let session = sessions[sessionID] else {
            await sendError(
                sessionID: sessionID,
                message: "Session missing"
            )
            return
        }
        let unchanged =
            session.columns == columns
            && session.rows == rows
        do {
            if repaint, unchanged {
                try await session.process.resize(
                    columns: columns == 1 ? 2 : columns - 1,
                    rows: rows
                )
                try await Task.sleep(
                    for: .milliseconds(100)
                )
                guard sessions[session.id] === session else {
                    return
                }
            } else if !repaint, unchanged {
                return
            }
            session.columns = columns
            session.rows = rows
            try await session.process.resize(
                columns: columns,
                rows: rows
            )
        } catch {
            await failAndDestroy(
                session,
                error: error
            )
        }
    }

    public func runAction(
        sessionID: String,
        cwd: String,
        command: String
    ) async throws {
        guard let session = sessions[sessionID] else {
            await sendError(
                sessionID: sessionID,
                message: "Session missing"
            )
            return
        }
        guard let resolvedCWD = confinedCWD(cwd) else {
            await sendError(
                sessionID: sessionID,
                message:
                    "Terminal cwd is outside the authorized workspace"
            )
            return
        }

        let priorProcess = session.process
        let nextGeneration = UUID()
        do {
            try await priorProcess.terminate()
            let nextProcess = try await startProcess(
                publicSessionID: session.id,
                generation: nextGeneration,
                hostID: session.hostID,
                cwd: resolvedCWD,
                columns: session.columns,
                rows: session.rows
            )
            guard sessions[session.id] === session else {
                try? await nextProcess.terminate()
                return
            }
            session.generation = nextGeneration
            session.process = nextProcess
            session.cwd = resolvedCWD
            session.buffer = ""
            session.truncated = false
            session.attached = true
            await send(.object([
                "type": .string("init-log"),
                "sessionId": .string(session.id),
                "log": .string(""),
            ]))
            await sendAttached(session)
            try await nextProcess.write(
                Self.actionCommand(
                    cwd: resolvedCWD,
                    command: command
                )
            )
        } catch {
            await failAndDestroy(
                session,
                error: error
            )
        }
    }

    public func write(
        sessionID: String,
        data: String
    ) async throws {
        guard let session = sessions[sessionID] else {
            await sendError(
                sessionID: sessionID,
                message: "Session missing"
            )
            return
        }
        do {
            try await session.process.write(data)
        } catch {
            await failAndDestroy(
                session,
                error: error
            )
        }
    }

    public func subscribe(
        _ receive:
            @escaping CodexDesktopTerminalEventReceiver
    ) async throws -> CodexDesktopTerminalUnsubscribe {
        let token = UUID()
        subscribers[token] = receive
        return { [weak self] in
            await self?.removeSubscriber(token)
        }
    }

    private func create(
        _ request:
            CodexDesktopTerminalAppHostService.SessionRequest
    ) async {
        let sessionID = Self.nonempty(request.sessionID)
            ?? UUID().uuidString
        guard let cwd = confinedCWD(request.cwd) else {
            await sendError(
                sessionID: sessionID,
                message:
                    "Terminal cwd is outside the authorized workspace"
            )
            return
        }
        let columns =
            request.columns ?? Self.defaultColumns
        let rows = request.rows ?? Self.defaultRows
        let generation = UUID()
        do {
            let process = try await startProcess(
                publicSessionID: sessionID,
                generation: generation,
                hostID: request.hostID,
                cwd: cwd,
                columns: columns,
                rows: rows
            )
            let session = Session(
                id: sessionID,
                generation: generation,
                process: process,
                conversationID: request.conversationID,
                conversationTitle:
                    request.conversationTitle,
                hostID: request.hostID,
                cwd: cwd,
                shell: "sh",
                columns: columns,
                rows: rows,
                preserveOnOwnerDestroy:
                    request.preserveOnOwnerDestroy
                    ?? false
            )
            sessions[sessionID] = session
            if let conversationID =
                request.conversationID
            {
                conversationSessions[conversationID] =
                    sessionID
            }
            await sendAttached(session)
        } catch {
            await sendError(
                sessionID: sessionID,
                message: String(describing: error)
            )
        }
    }

    private func attach(
        _ session: Session,
        request:
            CodexDesktopTerminalAppHostService.SessionRequest
    ) async {
        let priorConversationID = session.conversationID
        if let conversationID = request.conversationID {
            session.conversationID = conversationID
        }
        if let conversationTitle =
            request.conversationTitle
        {
            session.conversationTitle = conversationTitle
        }
        if let hostID = request.hostID {
            session.hostID = hostID
        }
        if let preserve =
            request.preserveOnOwnerDestroy
        {
            session.preserveOnOwnerDestroy = preserve
        }

        if let columns = request.columns,
           let rows = request.rows
        {
            do {
                if session.columns != columns
                    || session.rows != rows
                {
                    try await session.process.resize(
                        columns: columns,
                        rows: rows
                    )
                    session.columns = columns
                    session.rows = rows
                }
            } catch {
                await failAndDestroy(
                    session,
                    error: error
                )
                return
            }
        }

        if request.forceCWDSync == true,
           let requestedCWD = request.cwd
        {
            guard let cwd = confinedCWD(requestedCWD) else {
                await sendError(
                    sessionID: session.id,
                    message:
                        "Terminal cwd is outside the authorized workspace"
                )
                return
            }
            do {
                try await session.process.write(
                    "cd \(Self.shellQuote(cwd))\n"
                )
                session.cwd = cwd
            } catch {
                await failAndDestroy(
                    session,
                    error: error
                )
                return
            }
        }

        if let nextID = Self.nonempty(request.sessionID),
           nextID != session.id
        {
            sessions.removeValue(forKey: session.id)
            session.id = nextID
            sessions[nextID] = session
        }
        if let priorConversationID,
           priorConversationID != session.conversationID
        {
            conversationSessions.removeValue(
                forKey: priorConversationID
            )
        }
        if let conversationID = session.conversationID {
            conversationSessions[conversationID] =
                session.id
        }

        if !session.buffer.isEmpty {
            await send(.object([
                "type": .string("init-log"),
                "sessionId": .string(session.id),
                "log": .string(
                    Self.stripTerminalStatusQueries(
                        session.buffer
                    )
                ),
            ]))
        }
        session.attached = true
        await sendAttached(session)
    }

    private func startProcess(
        publicSessionID: String,
        generation: UUID,
        hostID: String?,
        cwd: String,
        columns: UInt32,
        rows: UInt32
    ) async throws
        -> any CodexDesktopTerminalProcessHandling
    {
        let processID =
            "\(processNamespace):\(generation.uuidString)"
        return try await processDriver.start(
            .init(
                processID: processID,
                hostID: hostID,
                command: ["sh"],
                cwd: cwd,
                columns: columns,
                rows: rows,
                environment: [
                    "TERM": "xterm-256color",
                ],
                allowedWorkspaceRoots:
                    allowedWorkspaceRoots.map(\.path)
            ),
            onData: { [weak self] data in
                await self?.receiveData(
                    generation: generation,
                    data: data
                )
            },
            onExit: { [weak self] exit in
                await self?.receiveExit(
                    generation: generation,
                    exit: exit
                )
            }
        )
    }

    private func receiveData(
        generation: UUID,
        data: String
    ) async {
        guard let session = session(
            generation: generation
        ) else {
            return
        }
        let combined = session.buffer + data
        if combined.count >= Self.bufferLimit {
            session.truncated = true
            session.buffer = String(
                combined.suffix(Self.bufferLimit)
            )
        } else {
            session.buffer = combined
        }
        guard session.attached else {
            return
        }
        await send(.object([
            "type": .string("data"),
            "sessionId": .string(session.id),
            "data": .string(data),
        ]))
    }

    private func receiveExit(
        generation: UUID,
        exit: CodexDesktopTerminalProcessExit
    ) async {
        guard let session = session(
            generation: generation
        ) else {
            return
        }
        remove(session)
        if let errorMessage = exit.errorMessage {
            await sendError(
                sessionID: session.id,
                message: errorMessage
            )
        }
        await sendExit(
            sessionID: session.id,
            code: exit.code,
            signal: exit.signal
        )
    }

    private func failAndDestroy(
        _ session: Session,
        error: Swift.Error
    ) async {
        guard sessions[session.id] === session else {
            return
        }
        remove(session)
        await sendError(
            sessionID: session.id,
            message: String(describing: error)
        )
        try? await session.process.terminate()
        await sendExit(
            sessionID: session.id,
            code: nil,
            signal: nil
        )
    }

    private func existingSession(
        for request:
            CodexDesktopTerminalAppHostService.SessionRequest
    ) -> Session? {
        if let sessionID = Self.nonempty(
            request.sessionID
        ), let session = sessions[sessionID] {
            return session
        }
        guard request.kind == .attach,
              let conversationID =
                request.conversationID,
              let sessionID =
                conversationSessions[conversationID]
        else {
            return nil
        }
        return sessions[sessionID]
    }

    private func session(
        generation: UUID
    ) -> Session? {
        sessions.values.first {
            $0.generation == generation
        }
    }

    private func remove(_ session: Session) {
        guard sessions[session.id] === session else {
            return
        }
        sessions.removeValue(forKey: session.id)
        if let conversationID = session.conversationID,
           conversationSessions[conversationID]
            == session.id
        {
            conversationSessions.removeValue(
                forKey: conversationID
            )
        }
    }

    private func confinedCWD(_ requested: String?) -> String? {
        guard let firstRoot =
            allowedWorkspaceRoots.first
        else {
            return nil
        }
        let target = URL(
            fileURLWithPath: requested ?? firstRoot.path,
            isDirectory: true
        ).standardizedFileURL.resolvingSymlinksInPath()
        let allowed = allowedWorkspaceRoots.contains {
            root in
            target.path == root.path
                || target.path.hasPrefix(root.path + "/")
        }
        return allowed ? target.path : nil
    }

    private func sendAttached(_ session: Session) async {
        await send(.object([
            "type": .string("attached"),
            "sessionId": .string(session.id),
            "cwd": .string(session.cwd),
            "shell": .string(session.shell),
        ]))
    }

    private func sendExit(
        sessionID: String,
        code: Int64?,
        signal: String?
    ) async {
        await send(.object([
            "type": .string("exit"),
            "sessionId": .string(sessionID),
            "code": code.map {
                CodexDesktopAppHostRPC.Value.integer($0)
            } ?? .null,
            "signal": signal.map {
                CodexDesktopAppHostRPC.Value.string($0)
            } ?? .null,
        ]))
    }

    private func sendError(
        sessionID: String,
        message: String
    ) async {
        await send(.object([
            "type": .string("error"),
            "sessionId": .string(sessionID),
            "message": .string(message),
        ]))
    }

    private func send(
        _ event: CodexDesktopAppHostRPC.Value
    ) async {
        let receivers = Array(subscribers.values)
        for receive in receivers {
            await receive(event)
        }
    }

    private func removeSubscriber(_ token: UUID) {
        subscribers.removeValue(forKey: token)
    }

    private static func nonempty(
        _ value: String?
    ) -> String? {
        guard let value else {
            return nil
        }
        let trimmed = value.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func actionCommand(
        cwd: String,
        command: String
    ) -> String {
        let normalized = command.replacingOccurrences(
            of: "\r\n",
            with: "\n"
        ).replacingOccurrences(of: "\r", with: "\n")
        return "cd \(shellQuote(cwd)) && \(normalized)\n"
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(
            of: "'",
            with: "'\\''"
        ) + "'"
    }

    /// The released manager strips terminal device-status query sequences
    /// before replaying an init log into xterm.
    private static func stripTerminalStatusQueries(
        _ value: String
    ) -> String {
        value.replacingOccurrences(
            of: "\u{1B}\\[[0-9;]*n",
            with: "",
            options: .regularExpression
        )
    }
}

/// Production process bridge. It uses the existing isolated command executor
/// rather than starting a second global ios_system environment, and attaches a
/// non-destructive observer so MCP/process output sinks remain intact.
public actor CodexDesktopTerminalCommandProcessDriver:
    CodexDesktopTerminalProcessDriving
{
    private struct Callbacks: Sendable {
        let onData: @Sendable (String) async -> Void
        let onExit:
            @Sendable (
                CodexDesktopTerminalProcessExit
            ) async -> Void
    }

    private let commandExecutor:
        CodexDesktopWorkspaceCommandExecutor
    private var callbacks: [String: Callbacks] = [:]
    private var observerToken: UUID?

    public init(
        commandExecutor:
            CodexDesktopWorkspaceCommandExecutor
    ) {
        self.commandExecutor = commandExecutor
    }

    public func start(
        _ request: CodexDesktopTerminalProcessRequest,
        onData: @escaping @Sendable (String) async -> Void,
        onExit:
            @escaping @Sendable (
                CodexDesktopTerminalProcessExit
            ) async -> Void
    ) async throws -> any CodexDesktopTerminalProcessHandling {
        if let hostID = request.hostID,
           !hostID.isEmpty,
           hostID != "local"
        {
            throw DriverError.remoteHostUnavailable(hostID)
        }
        await installObserverIfNeeded()
        callbacks[request.processID] = .init(
            onData: onData,
            onExit: onExit
        )
        let executor = commandExecutor
        let params = CodexDesktopCommandExecParams(
            command: request.command,
            processID: request.processID,
            tty: true,
            streamStdin: true,
            streamStdoutStderr: true,
            outputBytesCap: nil,
            disableOutputCap: true,
            disableTimeout: true,
            timeoutMs: nil,
            cwd: request.cwd,
            environment: request.environment.mapValues {
                Optional($0)
            },
            size: .init(
                rows: request.rows,
                cols: request.columns
            ),
            sandboxPolicy: nil
        )
        Task { [weak self] in
            do {
                let result = try await executor.execute(
                    params,
                    allowedRoots:
                        request.allowedWorkspaceRoots
                )
                await self?.finish(
                    processID: request.processID,
                    exit: .init(
                        code: result.exitCode,
                        signal: nil,
                        errorMessage: nil
                    )
                )
            } catch {
                await self?.finish(
                    processID: request.processID,
                    exit: .init(
                        code: nil,
                        signal: nil,
                        errorMessage:
                            String(describing: error)
                    )
                )
            }
        }
        return CodexDesktopTerminalCommandProcess(
            processID: request.processID,
            driver: self
        )
    }

    fileprivate func write(
        processID: String,
        data: String
    ) async throws {
        try await commandExecutor.write(
            .init(
                processID: processID,
                delta: Data(data.utf8),
                closeStdin: false
            )
        )
    }

    fileprivate func resize(
        processID: String,
        columns: UInt32,
        rows: UInt32
    ) async throws {
        try await commandExecutor.resize(
            .init(
                processID: processID,
                size: .init(
                    rows: rows,
                    cols: columns
                )
            )
        )
    }

    fileprivate func terminate(
        processID: String
    ) async throws {
        try await commandExecutor.terminate(
            .init(processID: processID)
        )
    }

    private func installObserverIfNeeded() async {
        guard observerToken == nil else {
            return
        }
        observerToken =
            await commandExecutor.addOutputObserver {
                [weak self] output in
                await self?.receive(output)
            }
    }

    private func receive(
        _ output: CodexDesktopCommandExecOutputDelta
    ) async {
        guard let callback =
                callbacks[output.processID]
        else {
            return
        }
        await callback.onData(
            String(decoding: output.delta, as: UTF8.self)
        )
    }

    private func finish(
        processID: String,
        exit: CodexDesktopTerminalProcessExit
    ) async {
        guard let callback =
                callbacks.removeValue(forKey: processID)
        else {
            return
        }
        await callback.onExit(exit)
    }

    public enum DriverError:
        Swift.Error,
        Equatable,
        Sendable
    {
        case remoteHostUnavailable(String)
    }
}

private struct CodexDesktopTerminalCommandProcess:
    CodexDesktopTerminalProcessHandling
{
    let processID: String
    let driver: CodexDesktopTerminalCommandProcessDriver

    func write(_ data: String) async throws {
        try await driver.write(
            processID: processID,
            data: data
        )
    }

    func resize(
        columns: UInt32,
        rows: UInt32
    ) async throws {
        try await driver.resize(
            processID: processID,
            columns: columns,
            rows: rows
        )
    }

    func terminate() async throws {
        try await driver.terminate(
            processID: processID
        )
    }
}
