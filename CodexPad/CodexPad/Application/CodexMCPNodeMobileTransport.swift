#if os(iOS) && canImport(ios_system)
import Darwin
import Foundation

enum CodexMCPEmbeddedTransportFactory {
    static func make(
        command: String,
        arguments: [String],
        environment: [String: String],
        cwd: String?
    ) throws -> any CodexMCPStdioTransport {
        let executable = URL(
            fileURLWithPath: command
        ).lastPathComponent
        let npxPackages =
            executable == "npx" && nodeRuntimeAvailable
            ? try vendoredNodePackages()
            : [:]
        let usesPython =
            executable == "python"
            || executable == "python3"
            || executable == "uv"
            || executable == "uvx"
        let pythonResources =
            usesPython && pythonRuntimeAvailable
            ? try vendoredPythonResources(
                command: executable
            )
            : nil
        let registry = CodexMCPEmbeddedRuntimeRegistry(
            nodeAvailable: nodeRuntimeAvailable,
            pythonAvailable:
                pythonRuntimeAvailable
                && pythonResources != nil,
            npxPackages: npxPackages,
            uvxPackages:
                pythonResources?.uvxRegistryEntries ?? [:]
        )
        switch registry.resolve(
            command: command,
            arguments: arguments
        ) {
        case let .available(route):
            return try make(
                route: route,
                environment: environment,
                cwd: cwd,
                pythonResources: pythonResources
            )
        case let .unavailable(unavailability):
            throw CodexMCPStdioError.runtimeUnavailable(
                command: unavailability.command,
                reason: diagnostic(
                    for: unavailability.reason
                )
            )
        }
    }

    private static var nodeRuntimeAvailable: Bool {
#if canImport(NodeMobile)
        true
#else
        false
#endif
    }

    private static var pythonRuntimeAvailable: Bool {
#if canImport(CodexPythonRuntimeBridge) || CODEX_EMBEDDED_PYTHON
        true
#else
        false
#endif
    }

    private static func make(
        route: CodexMCPEmbeddedRuntimeRoute,
        environment: [String: String],
        cwd: String?,
        pythonResources:
            CodexMCPPythonRuntimeResources?
    ) throws -> any CodexMCPStdioTransport {
        switch route {
        case let .iosSystem(command, arguments):
            return CodexMCPStdioEmbeddedTransport(
                command: command,
                arguments: arguments,
                environment: environment,
                cwd: cwd
            )
        case let .node(arguments):
#if canImport(NodeMobile)
            return CodexMCPNodeMobileTransport(
                arguments: arguments,
                environment: environment,
                cwd: cwd
            )
#else
            throw CodexMCPStdioError.runtimeUnavailable(
                command: "node",
                reason: "NodeMobile runtime is not linked"
            )
#endif
        case let .vendoredNodePackage(
            package,
            entrypoint,
            arguments
        ):
#if canImport(NodeMobile)
            guard let entrypointURL = nodeResourceURL(
                relativePath: entrypoint
            ) else {
                throw CodexMCPStdioError.runtimeUnavailable(
                    command: "npx",
                    reason:
                        "vendored package entrypoint is missing: "
                        + package
                )
            }
            return CodexMCPNodeMobileTransport(
                arguments: [entrypointURL.path] + arguments,
                environment: environment,
                cwd: cwd
            )
#else
            throw CodexMCPStdioError.runtimeUnavailable(
                command: "npx",
                reason: "NodeMobile runtime is not linked"
            )
#endif
        case let .python(arguments):
#if canImport(CodexPythonRuntimeBridge) || CODEX_EMBEDDED_PYTHON
            guard let pythonResources else {
                throw CodexMCPStdioError.runtimeUnavailable(
                    command: "python",
                    reason:
                        "embedded Python resources are missing"
                )
            }
            do {
                return CodexMCPPythonEmbeddedTransport(
                    invocation:
                        try CodexMCPPythonInvocation(
                            arguments: arguments,
                            cwd: cwd
                        ),
                    resources: pythonResources,
                    environment: environment,
                    cwd: cwd
                )
            } catch {
                throw CodexMCPStdioError.runtimeUnavailable(
                    command: "python",
                    reason:
                        "invalid embedded Python invocation: "
                        + String(describing: error)
                )
            }
#else
            throw CodexMCPStdioError.runtimeUnavailable(
                command: "python",
                reason: "embedded CPython runtime is not linked"
            )
#endif
        case let .vendoredPythonPackage(
            package,
            entrypoint,
            consoleScript,
            arguments
        ):
#if canImport(CodexPythonRuntimeBridge) || CODEX_EMBEDDED_PYTHON
            guard let pythonResources else {
                throw CodexMCPStdioError.runtimeUnavailable(
                    command: "uvx",
                    reason:
                        "embedded Python resources are missing"
                )
            }
            do {
                return CodexMCPPythonEmbeddedTransport(
                    invocation:
                        try CodexMCPPythonInvocation(
                            entrypoint: entrypoint,
                            consoleScript:
                                consoleScript
                                ?? pythonResources.consoleScript(
                                    package: package,
                                    entrypoint: entrypoint
                                ),
                            arguments: arguments,
                            resourceRoot:
                                pythonResources.resourceRoot
                        ),
                    resources: pythonResources,
                    environment: environment,
                    cwd: cwd
                )
            } catch {
                throw CodexMCPStdioError.runtimeUnavailable(
                    command: "uvx",
                    reason:
                        "invalid vendored Python entrypoint: "
                        + String(describing: error)
                )
            }
#else
            throw CodexMCPStdioError.runtimeUnavailable(
                command: "uvx",
                reason: "embedded CPython runtime is not linked"
            )
#endif
        }
    }

    private static func diagnostic(
        for reason: CodexMCPEmbeddedRuntimeUnavailableReason
    ) -> String {
        switch reason {
        case .unsupportedCommand:
            "command is absent from the embedded capability manifest"
        case let .runtimeMissing(runtime):
            "embedded \(runtime.rawValue) runtime is not linked"
        case .packageSpecifierMissing:
            "package specifier is missing"
        case let .invalidPackageInvocation(message):
            "invalid package invocation: \(message)"
        case let .packageSnapshotMissing(package):
            "vendored package snapshot is missing: \(package)"
        }
    }

    private static func nodeResourceURL(
        relativePath: String
    ) -> URL? {
        guard !relativePath.isEmpty,
              !relativePath.hasPrefix("/"),
              !relativePath.split(separator: "/").contains("..")
        else {
            return nil
        }
        guard let url = applicationResourceBundle.resourceURL?
            .appendingPathComponent(relativePath)
        else {
            return nil
        }
        guard FileManager.default.isReadableFile(
            atPath: url.path
        ) else {
            return nil
        }
        return url
    }

    private static func vendoredNodePackages() throws
        -> [String: String]
    {
        guard let lockURL = applicationResourceBundle.url(
            forResource: "runtime-lock",
            withExtension: "json",
            subdirectory: "MCPPackages"
        ) else {
            throw CodexMCPStdioError.runtimeUnavailable(
                command: "npx",
                reason: "vendored package snapshot lock is missing"
            )
        }
        do {
            let manifest =
                try CodexMCPNodePackageSnapshotManifest(
                    validating: Data(contentsOf: lockURL)
                )
            return manifest.npxRegistryEntries
        } catch {
            throw CodexMCPStdioError.runtimeUnavailable(
                command: "npx",
                reason:
                    "vendored package snapshot lock is invalid: "
                    + String(describing: error)
            )
        }
    }

    private static func vendoredPythonResources(
        command: String
    ) throws -> CodexMCPPythonRuntimeResources {
        guard let resourceURL =
            applicationResourceBundle.resourceURL
        else {
            throw CodexMCPStdioError.runtimeUnavailable(
                command: command,
                reason: "application resource bundle is missing"
            )
        }
        do {
            return try CodexMCPPythonRuntimeResources(
                validating: resourceURL
            )
        } catch {
            throw CodexMCPStdioError.runtimeUnavailable(
                command: command,
                reason:
                    "embedded Python snapshot is invalid: "
                    + String(describing: error)
            )
        }
    }

    private static var applicationResourceBundle: Bundle {
#if SWIFT_PACKAGE
        Bundle.module
#else
        Bundle.main
#endif
    }
}
#endif

#if os(iOS) && canImport(NodeMobile)
import NodeMobile

public actor CodexMCPNodeMobileTransport:
    CodexMCPStdioTransport
{
    private let arguments: [String]
    private let environment: [String: String]
    private let cwd: String?
    private var sessionID: String?
    private var output: CodexNodeSessionOutput?
    private var readBuffer = Data()

    public init(
        arguments: [String],
        environment: [String: String],
        cwd: String?
    ) {
        self.arguments = arguments
        self.environment = environment
        self.cwd = cwd
    }

    deinit {
        if let sessionID {
            Task {
                await CodexNodeMobileRuntime.shared.stopSession(
                    sessionID
                )
            }
        }
    }

    public func writeLine(_ data: Data) async throws {
        try await startIfNeeded()
        guard let sessionID else {
            throw CodexMCPStdioError.invalidConfiguration
        }
        try await CodexNodeMobileRuntime.shared.sendInput(
            data,
            sessionID: sessionID
        )
    }

    public func readLine(
        timeoutSeconds: Double?
    ) async throws -> Data {
        try await startIfNeeded()
        guard let output else {
            throw CodexMCPStdioError.invalidConfiguration
        }
        let deadline = codexMCPDeadline(
            timeoutSeconds: timeoutSeconds
        )
        while true {
            if let newline = readBuffer.firstIndex(of: 0x0A) {
                let line = Data(readBuffer[..<newline])
                readBuffer.removeSubrange(...newline)
                return line
            }
            guard let block = try await nextOutput(
                from: output,
                deadlineUptimeNanoseconds: deadline
            ) else {
                throw CodexMCPStdioError.processExited(-1)
            }
            readBuffer.append(block)
        }
    }

    private func startIfNeeded() async throws {
        guard sessionID == nil else {
            return
        }
        let session = try await CodexNodeMobileRuntime.shared
            .startSession(
                arguments: arguments,
                environment: environment,
                cwd: cwd
            )
        sessionID = session.id
        output = session.output
    }

    private func nextOutput(
        from output: CodexNodeSessionOutput,
        deadlineUptimeNanoseconds: UInt64?
    ) async throws -> Data? {
        guard let deadlineUptimeNanoseconds else {
            return try await output.next()
        }
        let now = DispatchTime.now().uptimeNanoseconds
        guard deadlineUptimeNanoseconds > now else {
            throw CodexMCPStdioError.timedOut
        }
        let remaining = deadlineUptimeNanoseconds - now
        return try await withThrowingTaskGroup(
            of: Data?.self
        ) { group in
            group.addTask {
                try await output.next()
            }
            group.addTask {
                try await Task.sleep(
                    nanoseconds: remaining
                )
                throw CodexMCPStdioError.timedOut
            }
            guard let result = try await group.next() else {
                throw CodexMCPStdioError.invalidResponse
            }
            group.cancelAll()
            return result
        }
    }
}

private actor CodexNodeSessionOutput {
    private var pending = [Data]()
    private var waiter:
        CheckedContinuation<Data?, Error>?
    private var stderr = Data()
    private var finished = false
    private var terminalError: CodexMCPStdioError?

    func next() async throws -> Data? {
        try Task.checkCancellation()
        if !pending.isEmpty {
            return pending.removeFirst()
        }
        if let terminalError {
            throw terminalError
        }
        guard !finished, waiter == nil else {
            throw CodexMCPStdioError.invalidResponse
        }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await
                withCheckedThrowingContinuation {
                    waiter = $0
                }
        } onCancel: {
            Task {
                await self.cancelWaitingRead()
            }
        }
    }

    func receiveStdout(_ data: Data) {
        guard !finished else {
            return
        }
        if let waiter {
            self.waiter = nil
            waiter.resume(returning: data)
        } else {
            pending.append(data)
        }
    }

    func receiveStderr(_ data: Data) {
        guard !finished else {
            return
        }
        stderr.append(data)
        let maximumBytes = 64 * 1024
        if stderr.count > maximumBytes {
            stderr.removeFirst(stderr.count - maximumBytes)
        }
    }

    func receiveFailure(_ message: String) {
        receiveStderr(Data(message.utf8))
    }

    func finish(exitCode: Int32) {
        guard !finished else {
            return
        }
        finished = true
        let diagnostic = String(
            data: stderr,
            encoding: .utf8
        )?.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let error: CodexMCPStdioError
        if let diagnostic, !diagnostic.isEmpty {
            error = .processExitedWithStderr(
                code: exitCode,
                stderr: diagnostic
            )
        } else {
            error = .processExited(exitCode)
        }
        terminalError = error
        if let waiter {
            self.waiter = nil
            waiter.resume(throwing: error)
        }
    }

    private func cancelWaitingRead() {
        guard let waiter else {
            return
        }
        self.waiter = nil
        waiter.resume(throwing: CancellationError())
    }
}

private actor CodexNodeMobileRuntime {
    struct Session: Sendable {
        var id: String
        var output: CodexNodeSessionOutput
    }

    static let shared = CodexNodeMobileRuntime()

    private var control: FileHandle?
    private var invocation: CodexNodeMobileInvocation?
    private var nodeThread: Thread?
    private var readTask: Task<Void, Never>?
    private var incoming = Data()
    private var ready = false
    private var failure: CodexMCPStdioError?
    private var sessions: [String: CodexNodeSessionOutput] = [:]

    func startSession(
        arguments: [String],
        environment: [String: String],
        cwd: String?
    ) async throws -> Session {
        try await ensureReady()
        let id = UUID().uuidString.lowercased()
        let output = CodexNodeSessionOutput()
        sessions[id] = output
        do {
            try send([
                "op": "start",
                "id": id,
                "arguments": arguments,
                "environment": environment,
                "cwd": cwd as Any,
            ])
        } catch {
            sessions.removeValue(forKey: id)
            throw error
        }
        return Session(id: id, output: output)
    }

    func sendInput(
        _ data: Data,
        sessionID: String
    ) throws {
        guard sessions[sessionID] != nil else {
            throw CodexMCPStdioError.processExited(-1)
        }
        try send([
            "op": "stdin",
            "id": sessionID,
            "data": data.base64EncodedString(),
        ])
    }

    func stopSession(_ sessionID: String) {
        guard sessions.removeValue(forKey: sessionID) != nil else {
            return
        }
        try? send([
            "op": "stop",
            "id": sessionID,
        ])
    }

    private func ensureReady() async throws {
        if let failure {
            throw failure
        }
        if control == nil {
            try start()
        }
        let deadline = DispatchTime.now().uptimeNanoseconds
            + 10_000_000_000
        while !ready {
            if let failure {
                throw failure
            }
            guard DispatchTime.now().uptimeNanoseconds < deadline else {
                throw CodexMCPStdioError.timedOut
            }
            try await Task.sleep(
                nanoseconds: 10_000_000
            )
        }
    }

    private func start() throws {
        guard let host = Self.hostScriptURL else {
            throw CodexMCPStdioError.runtimeUnavailable(
                command: "node",
                reason: "bundled Node MCP host is missing"
            )
        }
        var descriptors = [Int32](repeating: -1, count: 2)
        guard socketpair(
            AF_UNIX,
            SOCK_STREAM,
            0,
            &descriptors
        ) == 0 else {
            throw CodexMCPStdioError.invalidConfiguration
        }
        let nativeControl = FileHandle(
            fileDescriptor: descriptors[0],
            closeOnDealloc: true
        )
        let invocation = CodexNodeMobileInvocation(
            arguments: [
                "node",
                host.path,
                "--control-fd",
                String(descriptors[1]),
            ]
        )
        let runtime = self
        let reader = Task.detached {
            await Self.readControl(
                nativeControl,
                runtime: runtime
            )
        }
        let thread = Thread {
            invocation.run()
        }
        thread.name = "CodexNodeMobile"
        thread.stackSize = 2 * 1024 * 1024
        control = nativeControl
        self.invocation = invocation
        nodeThread = thread
        readTask = reader
        thread.start()
    }

    private static func readControl(
        _ handle: FileHandle,
        runtime: CodexNodeMobileRuntime
    ) async {
        do {
            while let data = try handle.read(
                upToCount: 64 * 1024
            ),
                !data.isEmpty
            {
                await runtime.receive(data)
            }
            await runtime.controlClosed()
        } catch {
            await runtime.controlClosed()
        }
    }

    private func receive(_ data: Data) async {
        incoming.append(data)
        while let newline = incoming.firstIndex(of: 0x0A) {
            let line = Data(incoming[..<newline])
            incoming.removeSubrange(...newline)
            guard !line.isEmpty,
                  let object = try? JSONSerialization.jsonObject(
                      with: line
                  ) as? [String: Any]
            else {
                continue
            }
            await handle(object)
        }
    }

    private func handle(_ message: [String: Any]) async {
        switch message["type"] as? String {
        case "runtimeReady":
            ready = true
        case "runtimeError":
            let diagnostic =
                message["message"] as? String
                ?? "Node runtime error"
            if !ready {
                failure = .runtimeUnavailable(
                    command: "node",
                    reason: diagnostic
                )
            }
        case "stream":
            guard let id = message["id"] as? String,
                  let stream = message["stream"] as? String,
                  let encoded = message["data"] as? String,
                  let data = Data(base64Encoded: encoded),
                  let session = sessions[id]
            else {
                return
            }
            if stream == "stdout" {
                await session.receiveStdout(data)
            } else if stream == "stderr" {
                await session.receiveStderr(data)
            }
        case "sessionState":
            guard message["state"] as? String == "failed",
                  let id = message["id"] as? String,
                  let session = sessions[id]
            else {
                return
            }
            await session.receiveFailure(
                message["message"] as? String
                    ?? "Node MCP worker failed"
            )
        case "sessionExit":
            guard let id = message["id"] as? String,
                  let session = sessions.removeValue(
                      forKey: id
                  )
            else {
                return
            }
            let code = (message["code"] as? NSNumber)?
                .int32Value ?? -1
            await session.finish(exitCode: code)
        default:
            break
        }
    }

    private func controlClosed() async {
        guard failure == nil else {
            return
        }
        let runtimeFailure =
            CodexMCPStdioError.runtimeUnavailable(
                command: "node",
                reason: "Node MCP host exited"
            )
        failure = runtimeFailure
        ready = false
        let active = sessions
        sessions.removeAll()
        for session in active.values {
            await session.receiveFailure(
                "Node MCP host exited"
            )
            await session.finish(exitCode: -1)
        }
    }

    private func send(_ message: [String: Any]) throws {
        guard let control else {
            throw CodexMCPStdioError.runtimeUnavailable(
                command: "node",
                reason: "Node MCP host is not running"
            )
        }
        var data = try JSONSerialization.data(
            withJSONObject: message,
            options: [.sortedKeys]
        )
        data.append(0x0A)
        try control.write(contentsOf: data)
    }

    private static var hostScriptURL: URL? {
#if SWIFT_PACKAGE
        let bundle = Bundle.module
#else
        let bundle = Bundle.main
#endif
        return bundle.url(
            forResource: "codex-node-mcp-host",
            withExtension: "js",
            subdirectory: "NodeRuntime"
        ) ?? bundle.url(
            forResource: "codex-node-mcp-host",
            withExtension: "js"
        )
    }
}

private final class CodexNodeMobileInvocation:
    @unchecked Sendable
{
    private let arguments: [String]

    init(arguments: [String]) {
        self.arguments = arguments
    }

    func run() {
        let encoded = arguments.map {
            Array($0.utf8) + [0]
        }
        let byteCount = encoded.reduce(0) {
            $0 + $1.count
        }
        let buffer = UnsafeMutablePointer<CChar>.allocate(
            capacity: max(byteCount, 1)
        )
        let argv = UnsafeMutablePointer<
            UnsafeMutablePointer<CChar>?
        >.allocate(capacity: max(arguments.count, 1))
        defer {
            argv.deallocate()
            buffer.deallocate()
        }
        var offset = 0
        for (index, bytes) in encoded.enumerated() {
            for (byteOffset, byte) in bytes.enumerated() {
                buffer[offset + byteOffset] = CChar(
                    bitPattern: byte
                )
            }
            argv[index] = buffer.advanced(by: offset)
            offset += bytes.count
        }
        _ = node_start(Int32(arguments.count), argv)
    }
}
#endif
