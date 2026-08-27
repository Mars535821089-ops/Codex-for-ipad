#if os(iOS) && canImport(ios_system)
import Darwin
import Foundation
import ios_system

/// iPadOS stdio transport backed by an isolated ios_system session.
///
/// iPadOS does not expose macOS Process/fork execution to App Store apps.
/// ios_system executes the bundled command implementations in-process while
/// retaining the newline-delimited stdin/stdout contract expected by MCP.
public actor CodexMCPStdioEmbeddedTransport:
    CodexMCPStdioTransport
{
    private let command: String
    private let arguments: [String]
    private let environment: [String: String]
    private let cwd: String?
    private var invocation: EmbeddedInvocation?
    private var input: FileHandle?
    private var output: FileHandle?
    private var readBuffer = Data()

    public init(
        command: String,
        arguments: [String],
        environment: [String: String],
        cwd: String?
    ) {
        self.command = command
        self.arguments = arguments
        self.environment = environment
        self.cwd = cwd
    }

    deinit {
        try? input?.close()
        invocation?.terminate()
    }

    public func writeLine(_ data: Data) async throws {
        try startIfNeeded()
        guard let input else {
            throw CodexMCPStdioError.invalidConfiguration
        }
        try input.write(contentsOf: data)
    }

    public func readLine(
        timeoutSeconds: Double?
    ) async throws -> Data {
        try startIfNeeded()
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
            guard let byte = try codexMCPReadByte(
                from: output,
                deadlineUptimeNanoseconds: deadline
            ),
                  !byte.isEmpty
            else {
                throw CodexMCPStdioError.processExited(
                    invocation?.exitCode ?? -1
                )
            }
            readBuffer.append(byte)
        }
    }

    private func startIfNeeded() throws {
        guard invocation == nil else {
            return
        }
        guard let shellCommand = shellCommand() else {
            throw CodexMCPStdioError.invalidConfiguration
        }
        var stdinDescriptors = [Int32](repeating: -1, count: 2)
        var stdoutDescriptors = [Int32](repeating: -1, count: 2)
        guard makePipe(&stdinDescriptors) == 0,
              makePipe(&stdoutDescriptors) == 0,
              let childInput = fdopen(stdinDescriptors[0], "r"),
              let childOutput = fdopen(stdoutDescriptors[1], "w"),
              let childError = tmpfile()
        else {
            stdinDescriptors.filter { $0 >= 0 }.forEach { close($0) }
            stdoutDescriptors.filter { $0 >= 0 }.forEach { close($0) }
            throw CodexMCPStdioError.invalidConfiguration
        }
        setvbuf(childOutput, nil, _IONBF, 0)

        let invocation = EmbeddedInvocation(
            command: shellCommand,
            environment: environment,
            cwd: cwd,
            input: childInput,
            output: childOutput,
            error: childError
        )
        self.invocation = invocation
        input = FileHandle(
            fileDescriptor: stdinDescriptors[1],
            closeOnDealloc: true
        )
        output = FileHandle(
            fileDescriptor: stdoutDescriptors[0],
            closeOnDealloc: true
        )
        Task.detached {
            invocation.run()
        }
    }

    private func makePipe(
        _ descriptors: inout [Int32]
    ) -> Int32 {
        descriptors.withUnsafeMutableBufferPointer {
            Darwin.pipe($0.baseAddress!)
        }
    }

    private func shellCommand() -> String? {
        CodexEmbeddedProcessCommandLine.shellCommand(
            [command] + arguments
        )
    }
}

private final class EmbeddedInvocation:
    @unchecked Sendable
{
    private let command: String
    private let environment: [String: String]
    private let cwd: String?
    private let input: UnsafeMutablePointer<FILE>
    private let output: UnsafeMutablePointer<FILE>
    private let error: UnsafeMutablePointer<FILE>
    private let session = NSObject()
    private let lock = NSLock()
    private var pid: pid_t?
    private var status: Int32?

    init(
        command: String,
        environment: [String: String],
        cwd: String?,
        input: UnsafeMutablePointer<FILE>,
        output: UnsafeMutablePointer<FILE>,
        error: UnsafeMutablePointer<FILE>
    ) {
        self.command = command
        self.environment = environment
        self.cwd = cwd
        self.input = input
        self.output = output
        self.error = error
    }

    var exitCode: Int32? {
        lock.withLock { status }
    }

    func run() {
        let sessionID = Unmanaged.passUnretained(session).toOpaque()
        initializeEnvironment()
        ios_switchSession(sessionID)
        ios_setStreams(input, output, error)
        if let cwd {
            ios_setDirectoryURL(
                URL(fileURLWithPath: cwd, isDirectory: true)
            )
        }
        for (name, value) in environment {
            name.withCString { variable in
                value.withCString { contents in
                    _ = ios_setenv(variable, contents, 1)
                }
            }
        }
        lock.withLock {
            pid = ios_currentPid()
        }
        let result = command.withCString {
            ios_system($0)
        }
        fflush(output)
        fflush(error)
        fclose(input)
        fclose(output)
        fclose(error)
        ios_closeSession(sessionID)
        lock.withLock {
            status = Int32(result)
            pid = nil
        }
    }

    func terminate() {
        let currentPID = lock.withLock { pid }
        if let currentPID {
            _ = ios_killpid(currentPID, SIGTERM)
        }
    }
}
#endif
