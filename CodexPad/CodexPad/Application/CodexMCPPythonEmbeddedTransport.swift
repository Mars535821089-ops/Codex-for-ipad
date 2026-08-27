import Foundation

enum CodexMCPPythonInvocationError:
    Error,
    Equatable,
    Sendable
{
    case missingTarget
    case missingOptionValue(String)
    case unsupportedInterpreterOption(String)
    case invalidTarget
}

struct CodexMCPPythonInvocation:
    Equatable,
    Sendable
{
    enum RunKind:
        Equatable,
        Sendable
    {
        case module
        case path
        case command
        case entrypoint
    }

    var runKind: RunKind
    var target: String
    var displayName: String
    var argv: [String]

    init(
        arguments: [String],
        cwd: String?
    ) throws {
        var index = 0
        while index < arguments.count,
              Self.isSupportedInterpreterFlag(
                  arguments[index]
              )
        {
            index += 1
        }
        guard index < arguments.count else {
            throw CodexMCPPythonInvocationError.missingTarget
        }

        var argument = arguments[index]
        if argument == "--" {
            index += 1
            guard index < arguments.count else {
                throw CodexMCPPythonInvocationError.missingTarget
            }
            argument = arguments[index]
        }

        switch argument {
        case "-m":
            guard index + 1 < arguments.count else {
                throw CodexMCPPythonInvocationError
                    .missingOptionValue("-m")
            }
            let module = arguments[index + 1]
            guard Self.isValidTarget(module) else {
                throw CodexMCPPythonInvocationError.invalidTarget
            }
            runKind = .module
            target = module
            displayName = "python -m \(module)"
            argv = [module]
                + Array(arguments.dropFirst(index + 2))

        case "-c":
            guard index + 1 < arguments.count else {
                throw CodexMCPPythonInvocationError
                    .missingOptionValue("-c")
            }
            let command = arguments[index + 1]
            guard Self.isValidTarget(command) else {
                throw CodexMCPPythonInvocationError.invalidTarget
            }
            runKind = .command
            target = command
            displayName = "python -c"
            argv = ["-c"]
                + Array(arguments.dropFirst(index + 2))

        default:
            guard !argument.hasPrefix("-") else {
                throw CodexMCPPythonInvocationError
                    .unsupportedInterpreterOption(argument)
            }
            guard Self.isValidTarget(argument) else {
                throw CodexMCPPythonInvocationError.invalidTarget
            }
            let path = Self.resolvedPath(
                argument,
                cwd: cwd
            )
            runKind = .path
            target = path
            displayName = path
            argv = [path]
                + Array(arguments.dropFirst(index + 1))
        }
    }

    init(
        entrypoint: String,
        consoleScript: String,
        arguments: [String],
        resourceRoot: URL? = nil
    ) throws {
        guard Self.isValidTarget(entrypoint),
              Self.isValidTarget(consoleScript)
        else {
            throw CodexMCPPythonInvocationError.invalidTarget
        }
        if entrypoint.hasPrefix("PythonPackages/") {
            guard let resourceRoot else {
                throw CodexMCPPythonInvocationError.invalidTarget
            }
            let path = resourceRoot
                .appendingPathComponent(entrypoint)
                .standardizedFileURL.path
            runKind = .path
            target = path
        } else {
            runKind = .entrypoint
            target = entrypoint
        }
        displayName = consoleScript
        argv = [consoleScript] + arguments
    }

    private static func isSupportedInterpreterFlag(
        _ value: String
    ) -> Bool {
        guard value.count >= 2,
              value.first == "-"
        else {
            return false
        }
        return value.dropFirst().allSatisfy {
            $0 == "B" || $0 == "u"
        }
    }

    private static func isValidTarget(
        _ value: String
    ) -> Bool {
        !value.isEmpty && !value.utf8.contains(0)
    }

    private static func resolvedPath(
        _ path: String,
        cwd: String?
    ) -> String {
        if path.hasPrefix("/") {
            return URL(fileURLWithPath: path)
                .standardizedFileURL.path
        }
        guard let cwd, !cwd.isEmpty else {
            return path
        }
        return URL(
            fileURLWithPath: cwd,
            isDirectory: true
        )
        .appendingPathComponent(path)
        .standardizedFileURL.path
    }
}

enum CodexMCPPythonRuntimeResourceError:
    Error,
    Equatable,
    Sendable
{
    case componentMissing(String)
    case snapshotLockInvalid(String)
    case entrypointMissing(String)
}

struct CodexMCPPythonRuntimeResources:
    Equatable,
    Sendable
{
    let resourceRoot: URL
    let pythonHome: URL
    let moduleSearchPaths: [URL]
    let manifest: CodexMCPPythonPackageSnapshotManifest

    init(validating resourceRoot: URL) throws {
        let root = resourceRoot.standardizedFileURL
        let home = root.appendingPathComponent(
            "python",
            isDirectory: true
        )
        let standardLibrary = home.appendingPathComponent(
            "lib/python3.13",
            isDirectory: true
        )
        let dynamicLibraries = standardLibrary
            .appendingPathComponent(
                "lib-dynload",
                isDirectory: true
            )
        let sitePackages = root.appendingPathComponent(
            "PythonPackages/site-packages",
            isDirectory: true
        )
        let requiredDirectories = [
            ("python", home),
            ("python/lib/python3.13", standardLibrary),
            (
                "python/lib/python3.13/lib-dynload",
                dynamicLibraries
            ),
            (
                "PythonPackages/site-packages",
                sitePackages
            ),
        ]
        for (relativePath, url) in requiredDirectories {
            guard Self.isDirectory(url) else {
                throw CodexMCPPythonRuntimeResourceError
                    .componentMissing(relativePath)
            }
        }

        let lockURL = root.appendingPathComponent(
            "PythonPackages/runtime-lock.json"
        )
        let snapshot: CodexMCPPythonPackageSnapshotManifest
        do {
            snapshot =
                try CodexMCPPythonPackageSnapshotManifest(
                    validating: Data(contentsOf: lockURL)
                )
        } catch {
            throw CodexMCPPythonRuntimeResourceError
                .snapshotLockInvalid(
                    String(describing: error)
                )
        }

        for package in snapshot.packages {
            guard Self.entrypointExists(
                package.entrypoint,
                resourceRoot: root,
                sitePackages: sitePackages
            ) else {
                throw CodexMCPPythonRuntimeResourceError
                    .entrypointMissing(package.entrypoint)
            }
        }

        self.resourceRoot = root
        pythonHome = home
        moduleSearchPaths = [
            standardLibrary,
            dynamicLibraries,
            sitePackages,
        ]
        manifest = snapshot
    }

    var uvxRegistryEntries: [String: String] {
        manifest.uvxRegistryEntries
    }

    func consoleScript(
        package: String,
        entrypoint: String
    ) -> String {
        let canonicalPackage = Self.canonicalPackageName(
            package
        )
        return manifest.packages.first {
            Self.canonicalPackageName($0.name)
                == canonicalPackage
                && $0.entrypoint == entrypoint
        }?.consoleScript ?? package
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(
            atPath: url.path,
            isDirectory: &isDirectory
        ) && isDirectory.boolValue
    }

    private static func entrypointExists(
        _ entrypoint: String,
        resourceRoot: URL,
        sitePackages: URL
    ) -> Bool {
        if entrypoint.hasPrefix("PythonPackages/") {
            let candidate = resourceRoot
                .appendingPathComponent(entrypoint)
                .standardizedFileURL
            guard candidate.path.hasPrefix(
                resourceRoot.path + "/"
            ) else {
                return false
            }
            return FileManager.default.isReadableFile(
                atPath: candidate.path
            )
        }

        let module = entrypoint.split(
            separator: ":",
            maxSplits: 1
        ).first.map(String.init) ?? ""
        guard !module.isEmpty else {
            return false
        }
        let relativePath = module.replacingOccurrences(
            of: ".",
            with: "/"
        )
        let moduleFile = sitePackages
            .appendingPathComponent(relativePath)
            .appendingPathExtension("py")
        let packageFile = sitePackages
            .appendingPathComponent(
                relativePath,
                isDirectory: true
            )
            .appendingPathComponent("__init__.py")
        return FileManager.default.isReadableFile(
            atPath: moduleFile.path
        ) || FileManager.default.isReadableFile(
            atPath: packageFile.path
        )
    }

    private static func canonicalPackageName(
        _ value: String
    ) -> String {
        value
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
            .replacingOccurrences(of: ".", with: "-")
    }
}

actor CodexMCPPythonSessionOutput {
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

    func finish(
        exitCode: Int32,
        runtimeError: String?
    ) {
        guard !finished else {
            return
        }
        finished = true
        var diagnostic = String(
            data: stderr,
            encoding: .utf8
        )?.trimmingCharacters(
            in: .whitespacesAndNewlines
        ) ?? ""
        if let runtimeError {
            let runtimeError = runtimeError
                .trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
            if !runtimeError.isEmpty {
                if !diagnostic.isEmpty {
                    diagnostic.append("\n")
                }
                diagnostic.append(runtimeError)
            }
        }
        let error: CodexMCPStdioError
        if diagnostic.isEmpty {
            error = .processExited(exitCode)
        } else {
            error = .processExitedWithStderr(
                code: exitCode,
                stderr: diagnostic
            )
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

#if os(iOS) && canImport(CodexPythonRuntimeBridge)
import CodexPythonRuntimeBridge
#endif

#if os(iOS) && (canImport(CodexPythonRuntimeBridge) || CODEX_EMBEDDED_PYTHON)
public actor CodexMCPPythonEmbeddedTransport:
    CodexMCPStdioTransport
{
    private let invocation: CodexMCPPythonInvocation
    private let resources: CodexMCPPythonRuntimeResources
    private let environment: [String: String]
    private let cwd: String?
    private var session: CodexMCPPythonSessionHandle?
    private var output: CodexMCPPythonSessionOutput?
    private var readBuffer = Data()

    init(
        invocation: CodexMCPPythonInvocation,
        resources: CodexMCPPythonRuntimeResources,
        environment: [String: String],
        cwd: String?
    ) {
        self.invocation = invocation
        self.resources = resources
        self.environment = environment
        self.cwd = cwd
    }

    public func writeLine(_ data: Data) async throws {
        try await startIfNeeded()
        guard let session else {
            throw CodexMCPStdioError.invalidConfiguration
        }
        try session.write(data)
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
        guard session == nil else {
            return
        }
        let output = CodexMCPPythonSessionOutput()
        let session = try CodexMCPPythonSessionHandle(
            invocation: invocation,
            resources: resources,
            environment: environment,
            cwd: cwd,
            output: output
        )
        self.output = output
        self.session = session
    }

    private func nextOutput(
        from output: CodexMCPPythonSessionOutput,
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

private final class CodexMCPPythonSessionHandle:
    @unchecked Sendable
{
    private let session: CodexPythonSessionRef

    init(
        invocation: CodexMCPPythonInvocation,
        resources: CodexMCPPythonRuntimeResources,
        environment: [String: String],
        cwd: String?,
        output: CodexMCPPythonSessionOutput
    ) throws {
        try Self.initializeRuntime(resources)

        let callbackContext =
            CodexMCPPythonCallbackContext(output: output)
        let retainedContext = Unmanaged.passRetained(
            callbackContext
        )
        var callbacks = CodexPythonCallbacks()
        callbacks.context = retainedContext.toOpaque()
        callbacks.stdout_callback = codexPythonStdoutCallback
        callbacks.stderr_callback = codexPythonStderrCallback
        callbacks.termination_callback =
            codexPythonTerminationCallback

        var createdSession: CodexPythonSessionRef?
        do {
            try Self.withSessionConfig(
                invocation: invocation,
                environment: environment,
                cwd: cwd
            ) { config in
                var config = config
                try Self.check(
                    codex_python_session_create(
                        &config,
                        &callbacks,
                        &createdSession,
                        nil
                    ),
                    operation: "create Python session"
                )
            }
            guard let createdSession else {
                throw CodexMCPStdioError
                    .invalidConfiguration
            }
            do {
                try Self.check(
                    codex_python_session_start(
                        createdSession,
                        nil
                    ),
                    operation: "start Python session"
                )
            } catch {
                codex_python_session_release(createdSession)
                retainedContext.release()
                throw error
            }
            session = createdSession
        } catch {
            if createdSession == nil {
                retainedContext.release()
            }
            throw error
        }
    }

    deinit {
        _ = codex_python_session_cancel(session)
        codex_python_session_release(session)
    }

    func write(_ data: Data) throws {
        let status = data.withUnsafeBytes { bytes in
            codex_python_session_write(
                session,
                bytes.bindMemory(to: UInt8.self).baseAddress,
                bytes.count
            )
        }
        switch status {
        case CODEX_PYTHON_OK:
            return
        case CODEX_PYTHON_INPUT_CLOSED:
            throw CodexMCPStdioError.processExited(-1)
        default:
            throw CodexMCPStdioError.runtimeUnavailable(
                command: "python",
                reason: "embedded Python stdin write failed"
            )
        }
    }

    private static func initializeRuntime(
        _ resources: CodexMCPPythonRuntimeResources
    ) throws {
        try resources.pythonHome.path.withCString {
            pythonHome in
            try withCStringArray(
                resources.moduleSearchPaths.map(\.path)
            ) { searchPaths in
                var config = CodexPythonRuntimeConfig()
                config.python_home_utf8 = pythonHome
                config.module_search_paths_utf8 =
                    searchPaths.baseAddress
                config.module_search_path_count =
                    searchPaths.count
                try check(
                    codex_python_runtime_initialize(
                        &config,
                        nil
                    ),
                    operation: "initialize embedded Python"
                )
            }
        }
    }

    private static func withSessionConfig<Result>(
        invocation: CodexMCPPythonInvocation,
        environment: [String: String],
        cwd: String?,
        _ body: (CodexPythonSessionConfig) throws -> Result
    ) throws -> Result {
        let environmentPairs = environment.sorted {
            $0.key < $1.key
        }
        let keys = environmentPairs.map(\.key)
        let values = environmentPairs.map(\.value)
        return try invocation.target.withCString { target in
            try invocation.displayName.withCString {
                displayName in
                try withOptionalCString(cwd) {
                    workingDirectory in
                    try withCStringArray(invocation.argv) {
                        argv in
                        try withCStringArray(keys) {
                            environmentKeys in
                            try withCStringArray(values) {
                                environmentValues in
                                var config =
                                    CodexPythonSessionConfig()
                                config.run_kind =
                                    invocation.runKind
                                        .bridgeValue
                                config.target_utf8 = target
                                config.display_name_utf8 =
                                    displayName
                                config.working_directory_utf8 =
                                    workingDirectory
                                config.argv_utf8 =
                                    argv.baseAddress
                                config.argc = argv.count
                                config.environment_keys_utf8 =
                                    environmentKeys.baseAddress
                                config.environment_values_utf8 =
                                    environmentValues.baseAddress
                                config.environment_count =
                                    environmentKeys.count
                                return try body(config)
                            }
                        }
                    }
                }
            }
        }
    }

    private static func withCStringArray<Result>(
        _ values: [String],
        _ body: (
            UnsafeBufferPointer<UnsafePointer<CChar>?>
        ) throws -> Result
    ) rethrows -> Result {
        let copies = values.map { strdup($0) }
        defer {
            for copy in copies {
                free(copy)
            }
        }
        let pointers: [UnsafePointer<CChar>?] = copies.map {
            pointer in
            guard let pointer else {
                return nil
            }
            return UnsafePointer<CChar>(pointer)
        }
        return try pointers.withUnsafeBufferPointer(body)
    }

    private static func withOptionalCString<Result>(
        _ value: String?,
        _ body: (UnsafePointer<CChar>?) throws -> Result
    ) rethrows -> Result {
        guard let value else {
            return try body(nil)
        }
        return try value.withCString(body)
    }

    private static func check(
        _ status: CodexPythonStatus,
        operation: String
    ) throws {
        guard status == CODEX_PYTHON_OK else {
            throw CodexMCPStdioError.runtimeUnavailable(
                command: "python",
                reason: "\(operation) failed (status \(status.rawValue))"
            )
        }
    }
}

private extension CodexMCPPythonInvocation.RunKind {
    var bridgeValue: CodexPythonRunKind {
        switch self {
        case .module:
            CODEX_PYTHON_RUN_MODULE
        case .path:
            CODEX_PYTHON_RUN_PATH
        case .command:
            CODEX_PYTHON_RUN_COMMAND
        case .entrypoint:
            CODEX_PYTHON_RUN_ENTRYPOINT
        }
    }
}

private enum CodexMCPPythonCallbackEvent:
    Sendable
{
    case stdout(Data)
    case stderr(Data)
    case termination(Int32, String?)
}

private final class CodexMCPPythonCallbackContext:
    @unchecked Sendable
{
    private let continuation:
        AsyncStream<CodexMCPPythonCallbackEvent>.Continuation

    init(output: CodexMCPPythonSessionOutput) {
        var captured:
            AsyncStream<
                CodexMCPPythonCallbackEvent
            >.Continuation?
        let stream =
            AsyncStream<CodexMCPPythonCallbackEvent> {
                captured = $0
            }
        continuation = captured!
        Task {
            for await event in stream {
                switch event {
                case let .stdout(data):
                    await output.receiveStdout(data)
                case let .stderr(data):
                    await output.receiveStderr(data)
                case let .termination(code, error):
                    await output.finish(
                        exitCode: code,
                        runtimeError: error
                    )
                }
            }
        }
    }

    func receiveStdout(_ data: Data) {
        continuation.yield(.stdout(data))
    }

    func receiveStderr(_ data: Data) {
        continuation.yield(.stderr(data))
    }

    func terminate(
        exitCode: Int32,
        runtimeError: String?
    ) {
        continuation.yield(
            .termination(exitCode, runtimeError)
        )
        continuation.finish()
    }
}

private func codexPythonStdoutCallback(
    _ opaqueContext: UnsafeMutableRawPointer?,
    _ bytes: UnsafePointer<UInt8>?,
    _ length: Int
) {
    guard let opaqueContext,
          let bytes,
          length > 0
    else {
        return
    }
    let context = Unmanaged<
        CodexMCPPythonCallbackContext
    >.fromOpaque(opaqueContext).takeUnretainedValue()
    context.receiveStdout(
        Data(bytes: bytes, count: length)
    )
}

private func codexPythonStderrCallback(
    _ opaqueContext: UnsafeMutableRawPointer?,
    _ bytes: UnsafePointer<UInt8>?,
    _ length: Int
) {
    guard let opaqueContext,
          let bytes,
          length > 0
    else {
        return
    }
    let context = Unmanaged<
        CodexMCPPythonCallbackContext
    >.fromOpaque(opaqueContext).takeUnretainedValue()
    context.receiveStderr(
        Data(bytes: bytes, count: length)
    )
}

private func codexPythonTerminationCallback(
    _ opaqueContext: UnsafeMutableRawPointer?,
    _ exitCode: Int32,
    _ error: UnsafePointer<CChar>?
) {
    guard let opaqueContext else {
        return
    }
    let context = Unmanaged<
        CodexMCPPythonCallbackContext
    >.fromOpaque(opaqueContext).takeRetainedValue()
    context.terminate(
        exitCode: exitCode,
        runtimeError: error.map(String.init(cString:))
    )
}
#endif
