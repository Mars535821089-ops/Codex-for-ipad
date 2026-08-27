#if SWIFT_PACKAGE
import CodexPadDomain
import CodexPadProtocolBridge
#endif
import Foundation
#if os(iOS) && canImport(ios_system)
import Darwin
import ios_system
#endif

enum CodexEmbeddedProcessCommandLine {
    static func shellCommand(_ argv: [String]) -> String? {
        guard !argv.isEmpty,
              argv.allSatisfy({ !$0.contains("\u{0}") })
        else {
            return nil
        }
        return argv
            .map(shellQuote)
            .joined(separator: " ")
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(
            of: "'",
            with: "'\\''"
        ) + "'"
    }
}

public struct CodexDesktopCommandTerminalSize:
    Equatable,
    Sendable
{
    public let rows: UInt32
    public let cols: UInt32
}

public struct CodexDesktopBackgroundCommandMetadata:
    Equatable,
    Sendable
{
    public let threadID: String
    public let itemID: String
    public let command: String

    public init(
        threadID: String,
        itemID: String,
        command: String
    ) {
        self.threadID = threadID
        self.itemID = itemID
        self.command = command
    }
}

public struct CodexDesktopCommandExecParams:
    Equatable,
    Sendable
{
    public let command: [String]
    public let processID: String?
    public let tty: Bool
    public let streamStdin: Bool
    public let streamStdoutStderr: Bool
    public let outputBytesCap: UInt64?
    public let disableOutputCap: Bool
    public let disableTimeout: Bool
    public let timeoutMs: UInt64?
    public let cwd: String?
    public let environment: [String: String?]?
    public let size: CodexDesktopCommandTerminalSize?
    public let sandboxPolicy: CodexJSONValue?
    public let backgroundTerminal:
        CodexDesktopBackgroundCommandMetadata?

    public init(
        command: [String],
        processID: String?,
        tty: Bool,
        streamStdin: Bool,
        streamStdoutStderr: Bool,
        outputBytesCap: UInt64?,
        disableOutputCap: Bool,
        disableTimeout: Bool,
        timeoutMs: UInt64?,
        cwd: String?,
        environment: [String: String?]?,
        size: CodexDesktopCommandTerminalSize?,
        sandboxPolicy: CodexJSONValue?,
        backgroundTerminal:
            CodexDesktopBackgroundCommandMetadata? = nil
    ) {
        self.command = command
        self.processID = processID
        self.tty = tty
        self.streamStdin = streamStdin
        self.streamStdoutStderr = streamStdoutStderr
        self.outputBytesCap = outputBytesCap
        self.disableOutputCap = disableOutputCap
        self.disableTimeout = disableTimeout
        self.timeoutMs = timeoutMs
        self.cwd = cwd
        self.environment = environment
        self.size = size
        self.sandboxPolicy = sandboxPolicy
        self.backgroundTerminal = backgroundTerminal
    }
}

#if os(iOS) && canImport(ios_system)
private final class CodexEmbeddedProcessInvocation:
    @unchecked Sendable
{
    private let command: String
    private let environment: [String: String?]
    private let cwd: URL
    private let allowedRoots: [String]
    private let tty: Bool
    private let initialSize: CodexDesktopCommandTerminalSize?
    private let childInput: UnsafeMutablePointer<FILE>
    private let childOutput: UnsafeMutablePointer<FILE>
    private let childError: UnsafeMutablePointer<FILE>
    private let session = NSObject()
    private let lock = NSLock()
    private var pid: pid_t?
    private var status: Int32?
    private var inputClosed = false
    private var terminationRequested = false

    let input: FileHandle
    let output: FileHandle
    let error: FileHandle

    init(
        command: String,
        environment: [String: String?],
        cwd: URL,
        allowedRoots: [String],
        tty: Bool,
        size: CodexDesktopCommandTerminalSize?
    ) throws {
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        let childInputDescriptor = Darwin.dup(
            inputPipe.fileHandleForReading.fileDescriptor
        )
        let childOutputDescriptor = Darwin.dup(
            outputPipe.fileHandleForWriting.fileDescriptor
        )
        let childErrorDescriptor = Darwin.dup(
            errorPipe.fileHandleForWriting.fileDescriptor
        )
        guard childInputDescriptor >= 0,
              childOutputDescriptor >= 0,
              childErrorDescriptor >= 0
        else {
            Self.closeDescriptors([
                childInputDescriptor,
                childOutputDescriptor,
                childErrorDescriptor,
            ])
            throw CodexDesktopCommandExecError.invalidParams
        }
        let openedInput = fdopen(childInputDescriptor, "r")
        let openedOutput = fdopen(childOutputDescriptor, "w")
        let openedError = fdopen(childErrorDescriptor, "w")
        guard let childInput = openedInput,
              let childOutput = openedOutput,
              let childError = openedError
        else {
            Self.closeStreamOrDescriptor(
                openedInput,
                descriptor: childInputDescriptor
            )
            Self.closeStreamOrDescriptor(
                openedOutput,
                descriptor: childOutputDescriptor
            )
            Self.closeStreamOrDescriptor(
                openedError,
                descriptor: childErrorDescriptor
            )
            throw CodexDesktopCommandExecError.invalidParams
        }
        setvbuf(childOutput, nil, _IONBF, 0)
        setvbuf(childError, nil, _IONBF, 0)
        try? inputPipe.fileHandleForReading.close()
        try? outputPipe.fileHandleForWriting.close()
        try? errorPipe.fileHandleForWriting.close()

        self.command = command
        self.environment = environment
        self.cwd = cwd
        self.allowedRoots = allowedRoots
        self.tty = tty
        initialSize = size
        self.childInput = childInput
        self.childOutput = childOutput
        self.childError = childError
        input = inputPipe.fileHandleForWriting
        output = outputPipe.fileHandleForReading
        error = errorPipe.fileHandleForReading
    }

    var exitCode: Int32? {
        lock.withLock { status }
    }

    func run() -> Int32 {
        let sessionID = identifier
        initializeEnvironment()
        ios_switchSession(sessionID)
        ios_setAllowedPaths(allowedRoots)
        ios_setStreams(childInput, childOutput, childError)
        if tty {
            ios_settty(childOutput)
        }
        if let initialSize {
            resize(initialSize)
        }
        ios_setDirectoryURL(cwd)
        for (name, value) in environment {
            name.withCString { variable in
                if let value {
                    value.withCString { contents in
                        _ = ios_setenv(variable, contents, 1)
                    }
                } else {
                    _ = ios_unsetenv(variable)
                }
            }
        }
        let shouldTerminate = lock.withLock {
            pid = ios_currentPid()
            return terminationRequested
        }
        if shouldTerminate,
           let currentPID = lock.withLock({ pid })
        {
            _ = ios_killpid(currentPID, SIGTERM)
        }
        let result = command.withCString { ios_system($0) }
        fflush(childOutput)
        fflush(childError)
        fclose(childInput)
        fclose(childOutput)
        fclose(childError)
        ios_closeSession(sessionID)
        lock.withLock {
            status = Int32(result)
            pid = nil
        }
        closeInput()
        return Int32(result)
    }

    func write(_ data: Data) throws {
        try input.write(contentsOf: data)
    }

    func closeInput() {
        let shouldClose = lock.withLock {
            guard !inputClosed else {
                return false
            }
            inputClosed = true
            return true
        }
        if shouldClose {
            try? input.close()
        }
    }

    func resize(_ size: CodexDesktopCommandTerminalSize) {
        ios_setWindowSize(
            Int32(clamping: size.cols),
            Int32(clamping: size.rows),
            identifier
        )
    }

    func terminate() {
        closeInput()
        let currentPID = lock.withLock {
            terminationRequested = true
            return pid
        }
        if let currentPID {
            _ = ios_killpid(currentPID, SIGTERM)
        }
    }

    private var identifier: UnsafeMutableRawPointer {
        Unmanaged.passUnretained(session).toOpaque()
    }

    private static func closeDescriptors(_ descriptors: [Int32]) {
        descriptors.filter { $0 >= 0 }.forEach {
            Darwin.close($0)
        }
    }

    private static func closeStreamOrDescriptor(
        _ stream: UnsafeMutablePointer<FILE>?,
        descriptor: Int32
    ) {
        if let stream {
            fclose(stream)
        } else if descriptor >= 0 {
            Darwin.close(descriptor)
        }
    }
}
#endif

public struct CodexDesktopCommandExecResult:
    Equatable,
    Sendable
{
    public let exitCode: Int64
    public let stdout: String
    public let stderr: String

    public init(
        exitCode: Int64,
        stdout: String,
        stderr: String
    ) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }

    public var json: CodexJSONValue {
        .object([
            "exitCode": .integer(exitCode),
            "stdout": .string(stdout),
            "stderr": .string(stderr),
        ])
    }
}

public struct CodexDesktopCommandExecWriteParams:
    Equatable,
    Sendable
{
    public let processID: String
    public let delta: Data?
    public let closeStdin: Bool
}

public struct CodexDesktopCommandExecResizeParams:
    Equatable,
    Sendable
{
    public let processID: String
    public let size: CodexDesktopCommandTerminalSize
}

public struct CodexDesktopCommandExecTerminateParams:
    Equatable,
    Sendable
{
    public let processID: String
}

public struct CodexDesktopCommandExecOutputDelta:
    Equatable,
    Sendable
{
    public enum Stream:
        String,
        Equatable,
        Sendable
    {
        case stdout
        case stderr
    }

    public let processID: String
    public let stream: Stream
    public let delta: Data
    public let capReached: Bool

    public var json: CodexJSONValue {
        .object([
            "processId": .string(processID),
            "stream": .string(stream.rawValue),
            "deltaBase64": .string(delta.base64EncodedString()),
            "capReached": .bool(capReached),
        ])
    }

    public var processJSON: CodexJSONValue {
        .object([
            "processHandle": .string(processID),
            "stream": .string(stream.rawValue),
            "deltaBase64": .string(delta.base64EncodedString()),
            "capReached": .bool(capReached),
        ])
    }
}

public struct CodexDesktopProcessExited:
    Equatable,
    Sendable
{
    public let processHandle: String
    public let exitCode: Int32
    public let stdout: String
    public let stdoutCapReached: Bool
    public let stderr: String
    public let stderrCapReached: Bool

    public var json: CodexJSONValue {
        .object([
            "processHandle": .string(processHandle),
            "exitCode": .integer(Int64(exitCode)),
            "stdout": .string(stdout),
            "stdoutCapReached": .bool(stdoutCapReached),
            "stderr": .string(stderr),
            "stderrCapReached": .bool(stderrCapReached),
        ])
    }
}

public enum CodexDesktopCommandExecError:
    Error,
    Equatable,
    Sendable
{
    case invalidParams
    case cwdOutsideWorkspace
    case duplicateProcessID
    case processNotFound
    case processTerminated
    case timedOut
}

private final class CodexDesktopCommandTimeoutState:
    @unchecked Sendable
{
    private let lock = NSLock()
    private var value = false

    func markTimedOut() {
        lock.lock()
        value = true
        lock.unlock()
    }

    var didTimeOut: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

public enum CodexDesktopCommandExecDecoder {
    public static func decode(
        _ value: CodexJSONValue?
    ) throws -> CodexDesktopCommandExecParams {
        guard case let .object(fields)? = value,
              case let .array(commandValues)? = fields["command"],
              !commandValues.isEmpty
        else {
            throw CodexDesktopCommandExecError.invalidParams
        }
        let command = try commandValues.map { value in
            guard case let .string(argument) = value,
                  !argument.contains("\u{0}")
            else {
                throw CodexDesktopCommandExecError.invalidParams
            }
            return argument
        }
        let processID = try optionalString(fields["processId"])
        let tty = try optionalBool(fields["tty"]) ?? false
        let streamStdin =
            try optionalBool(fields["streamStdin"]) ?? false
        let streamOutput =
            try optionalBool(fields["streamStdoutStderr"]) ?? false
        let outputBytesCap =
            try optionalUInt(fields["outputBytesCap"])
        let disableOutputCap =
            try optionalBool(fields["disableOutputCap"]) ?? false
        let disableTimeout =
            try optionalBool(fields["disableTimeout"]) ?? false
        let timeoutMs = try optionalUInt(fields["timeoutMs"])
        let cwd = try optionalString(fields["cwd"])
        let environment = try optionalEnvironment(fields["env"])
        let size = try optionalSize(fields["size"])

        guard !(outputBytesCap != nil && disableOutputCap),
              !(timeoutMs != nil && disableTimeout),
              size == nil || tty,
              !tty || processID != nil,
              !streamStdin || processID != nil,
              !streamOutput || processID != nil
        else {
            throw CodexDesktopCommandExecError.invalidParams
        }

        return CodexDesktopCommandExecParams(
            command: command,
            processID: processID,
            tty: tty,
            streamStdin: tty || streamStdin,
            streamStdoutStderr: tty || streamOutput,
            outputBytesCap: outputBytesCap,
            disableOutputCap: disableOutputCap,
            disableTimeout: disableTimeout,
            timeoutMs: timeoutMs,
            cwd: cwd,
            environment: environment,
            size: size,
            sandboxPolicy: fields["sandboxPolicy"],
            backgroundTerminal: nil
        )
    }

    private static func optionalString(
        _ value: CodexJSONValue?
    ) throws -> String? {
        switch value {
        case nil, .null?:
            return nil
        case let .string(value)?:
            return value
        default:
            throw CodexDesktopCommandExecError.invalidParams
        }
    }

    private static func optionalBool(
        _ value: CodexJSONValue?
    ) throws -> Bool? {
        switch value {
        case nil, .null?:
            return nil
        case let .bool(value)?:
            return value
        default:
            throw CodexDesktopCommandExecError.invalidParams
        }
    }

    private static func optionalUInt(
        _ value: CodexJSONValue?
    ) throws -> UInt64? {
        switch value {
        case nil, .null?:
            return nil
        case let .integer(value)? where value >= 0:
            return UInt64(value)
        default:
            throw CodexDesktopCommandExecError.invalidParams
        }
    }

    private static func optionalEnvironment(
        _ value: CodexJSONValue?
    ) throws -> [String: String?]? {
        switch value {
        case nil, .null?:
            return nil
        case let .object(fields)?:
            return try fields.mapValues { value in
                switch value {
                case .null:
                    return nil
                case let .string(value):
                    return value
                default:
                    throw CodexDesktopCommandExecError.invalidParams
                }
            }
        default:
            throw CodexDesktopCommandExecError.invalidParams
        }
    }

    private static func optionalSize(
        _ value: CodexJSONValue?
    ) throws -> CodexDesktopCommandTerminalSize? {
        switch value {
        case nil, .null?:
            return nil
        case let .object(fields)?:
            guard case let .integer(rows)? = fields["rows"],
                  case let .integer(cols)? = fields["cols"],
                  rows > 0, cols > 0,
                  rows <= Int64(UInt32.max),
                  cols <= Int64(UInt32.max)
            else {
                throw CodexDesktopCommandExecError.invalidParams
            }
            return CodexDesktopCommandTerminalSize(
                rows: UInt32(rows),
                cols: UInt32(cols)
            )
        default:
            throw CodexDesktopCommandExecError.invalidParams
        }
    }
}

public enum CodexDesktopCommandExecWriteDecoder {
    public static func decode(
        _ value: CodexJSONValue?
    ) throws -> CodexDesktopCommandExecWriteParams {
        guard case let .object(fields)? = value,
              case let .string(processID)? = fields["processId"],
              !processID.isEmpty
        else {
            throw CodexDesktopCommandExecError.invalidParams
        }
        let delta: Data?
        switch fields["deltaBase64"] {
        case nil, .null?:
            delta = nil
        case let .string(encoded)?:
            guard let decoded = Data(
                base64Encoded: encoded,
                options: []
            ) else {
                throw CodexDesktopCommandExecError.invalidParams
            }
            delta = decoded
        default:
            throw CodexDesktopCommandExecError.invalidParams
        }
        let close: Bool
        switch fields["closeStdin"] {
        case nil:
            close = false
        case let .bool(value)?:
            close = value
        default:
            throw CodexDesktopCommandExecError.invalidParams
        }
        guard delta != nil || close else {
            throw CodexDesktopCommandExecError.invalidParams
        }
        return .init(
            processID: processID,
            delta: delta,
            closeStdin: close
        )
    }
}

public enum CodexDesktopCommandExecResizeDecoder {
    public static func decode(
        _ value: CodexJSONValue?
    ) throws -> CodexDesktopCommandExecResizeParams {
        guard case let .object(fields)? = value,
              case let .string(processID)? = fields["processId"],
              !processID.isEmpty,
              case let .object(size)? = fields["size"],
              case let .integer(rows)? = size["rows"],
              case let .integer(cols)? = size["cols"],
              rows > 0, cols > 0,
              rows <= Int64(UInt32.max),
              cols <= Int64(UInt32.max)
        else {
            throw CodexDesktopCommandExecError.invalidParams
        }
        return .init(
            processID: processID,
            size: .init(rows: UInt32(rows), cols: UInt32(cols))
        )
    }
}

public enum CodexDesktopCommandExecTerminateDecoder {
    public static func decode(
        _ value: CodexJSONValue?
    ) throws -> CodexDesktopCommandExecTerminateParams {
        guard case let .object(fields)? = value,
              case let .string(processID)? = fields["processId"],
              !processID.isEmpty
        else {
            throw CodexDesktopCommandExecError.invalidParams
        }
        return .init(processID: processID)
    }
}

public enum CodexDesktopProcessSpawnDecoder {
    public static let defaultOutputBytesCap: UInt64 =
        1_024 * 1_024

    public static func decode(
        _ value: CodexJSONValue?
    ) throws -> CodexDesktopCommandExecParams {
        guard case let .object(fields)? = value,
              case let .array(commandValues)? = fields["command"],
              !commandValues.isEmpty,
              case let .string(processHandle)? =
                  fields["processHandle"],
              !processHandle.isEmpty,
              case let .string(cwd)? = fields["cwd"],
              cwd.hasPrefix("/")
        else {
            throw CodexDesktopCommandExecError.invalidParams
        }
        let command = try commandValues.map { value in
            guard case let .string(argument) = value,
                  !argument.contains("\u{0}")
            else {
                throw CodexDesktopCommandExecError.invalidParams
            }
            return argument
        }
        let tty = try optionalBool(fields["tty"]) ?? false
        let streamStdin =
            try optionalBool(fields["streamStdin"]) ?? false
        let streamOutput =
            try optionalBool(fields["streamStdoutStderr"]) ?? false
        let environment =
            try optionalEnvironment(fields["env"])
        let size = try optionalSize(fields["size"])

        let outputBytesCap: UInt64?
        let disableOutputCap: Bool
        switch fields["outputBytesCap"] {
        case nil:
            outputBytesCap = defaultOutputBytesCap
            disableOutputCap = false
        case .null?:
            outputBytesCap = nil
            disableOutputCap = true
        case let .integer(value)? where value >= 0:
            outputBytesCap = UInt64(value)
            disableOutputCap = false
        default:
            throw CodexDesktopCommandExecError.invalidParams
        }

        let timeoutMs: UInt64?
        let disableTimeout: Bool
        switch fields["timeoutMs"] {
        case nil:
            timeoutMs = nil
            disableTimeout = false
        case .null?:
            timeoutMs = nil
            disableTimeout = true
        case let .integer(value)? where value >= 0:
            timeoutMs = UInt64(value)
            disableTimeout = false
        default:
            throw CodexDesktopCommandExecError.invalidParams
        }

        guard size == nil || tty else {
            throw CodexDesktopCommandExecError.invalidParams
        }
        return .init(
            command: command,
            processID: processHandle,
            tty: tty,
            streamStdin: tty || streamStdin,
            streamStdoutStderr: tty || streamOutput,
            outputBytesCap: outputBytesCap,
            disableOutputCap: disableOutputCap,
            disableTimeout: disableTimeout,
            timeoutMs: timeoutMs,
            cwd: cwd,
            environment: environment,
            size: size,
            sandboxPolicy: nil
        )
    }

    private static func optionalBool(
        _ value: CodexJSONValue?
    ) throws -> Bool? {
        switch value {
        case nil:
            return nil
        case let .bool(value)?:
            return value
        default:
            throw CodexDesktopCommandExecError.invalidParams
        }
    }

    private static func optionalEnvironment(
        _ value: CodexJSONValue?
    ) throws -> [String: String?]? {
        switch value {
        case nil, .null?:
            return nil
        case let .object(fields)?:
            return try fields.mapValues { value in
                switch value {
                case .null:
                    return nil
                case let .string(value):
                    return value
                default:
                    throw CodexDesktopCommandExecError.invalidParams
                }
            }
        default:
            throw CodexDesktopCommandExecError.invalidParams
        }
    }

    private static func optionalSize(
        _ value: CodexJSONValue?
    ) throws -> CodexDesktopCommandTerminalSize? {
        switch value {
        case nil, .null?:
            return nil
        case let .object(fields)?:
            guard case let .integer(rows)? = fields["rows"],
                  case let .integer(cols)? = fields["cols"],
                  rows > 0, cols > 0,
                  rows <= Int64(UInt16.max),
                  cols <= Int64(UInt16.max)
            else {
                throw CodexDesktopCommandExecError.invalidParams
            }
            return .init(
                rows: UInt32(rows),
                cols: UInt32(cols)
            )
        default:
            throw CodexDesktopCommandExecError.invalidParams
        }
    }
}

public enum CodexDesktopProcessWriteDecoder {
    public static func decode(
        _ value: CodexJSONValue?
    ) throws -> CodexDesktopCommandExecWriteParams {
        try CodexDesktopCommandExecWriteDecoder.decode(
            remapProcessHandle(value)
        )
    }
}

public enum CodexDesktopProcessResizeDecoder {
    public static func decode(
        _ value: CodexJSONValue?
    ) throws -> CodexDesktopCommandExecResizeParams {
        try CodexDesktopCommandExecResizeDecoder.decode(
            remapProcessHandle(value)
        )
    }
}

public enum CodexDesktopProcessKillDecoder {
    public static func decode(
        _ value: CodexJSONValue?
    ) throws -> CodexDesktopCommandExecTerminateParams {
        try CodexDesktopCommandExecTerminateDecoder.decode(
            remapProcessHandle(value)
        )
    }
}

private func remapProcessHandle(
    _ value: CodexJSONValue?
) throws -> CodexJSONValue? {
    guard case var .object(fields)? = value,
          case let .string(handle)? = fields["processHandle"],
          !handle.isEmpty
    else {
        throw CodexDesktopCommandExecError.invalidParams
    }
    fields.removeValue(forKey: "processHandle")
    fields["processId"] = .string(handle)
    return .object(fields)
}

@MainActor
public protocol CodexDesktopCommandExecuting: AnyObject {
    func execute(
        _ params: CodexDesktopCommandExecParams,
        allowedRoots: [String]
    ) async throws -> CodexDesktopCommandExecResult

    func write(
        _ params: CodexDesktopCommandExecWriteParams
    ) throws

    func resize(
        _ params: CodexDesktopCommandExecResizeParams
    ) throws

    func terminate(
        _ params: CodexDesktopCommandExecTerminateParams
    ) throws
}

@MainActor
public protocol CodexDesktopProcessManaging: AnyObject {
    func spawnProcess(
        _ params: CodexDesktopCommandExecParams,
        allowedRoots: [String]
    ) throws

    func writeProcess(
        _ params: CodexDesktopCommandExecWriteParams
    ) throws

    func resizeProcess(
        _ params: CodexDesktopCommandExecResizeParams
    ) throws

    func killProcess(
        _ params: CodexDesktopCommandExecTerminateParams
    ) throws
}

public struct CodexDesktopBackgroundTerminal:
    Equatable,
    Sendable
{
    public let itemID: String
    public let processID: String
    public let command: String
    public let cwd: String
    public let osPID: UInt32?
    public let cpuPercent: Double?
    public let rssKB: UInt64?

    public var json: CodexJSONValue {
        .object([
            "itemId": .string(itemID),
            "processId": .string(processID),
            "command": .string(command),
            "cwd": .string(cwd),
            "osPid": osPID.map {
                .integer(Int64($0))
            } ?? .null,
            "cpuPercent": cpuPercent.map {
                .number($0)
            } ?? .null,
            "rssKb": rssKB.map {
                $0 > UInt64(Int64.max)
                    ? .integer(Int64.max)
                    : .integer(Int64($0))
            } ?? .null,
        ])
    }
}

public struct CodexDesktopBackgroundTerminalPage:
    Equatable,
    Sendable
{
    public let data: [CodexDesktopBackgroundTerminal]
    public let nextCursor: String?
}

public struct CodexDesktopUnifiedExecOutput:
    Equatable,
    Sendable
{
    public let chunkID: String
    public let wallTimeSeconds: Double
    public let processID: String?
    public let exitCode: Int64?
    public let originalTokenCount: Int?
    public let output: String
    public let maxOutputTokens: Int?

    public init(
        chunkID: String = "",
        wallTimeSeconds: Double,
        processID: String?,
        exitCode: Int64?,
        originalTokenCount: Int? = nil,
        output: String,
        maxOutputTokens: Int? = nil
    ) {
        self.chunkID = chunkID
        self.wallTimeSeconds = wallTimeSeconds
        self.processID = processID
        self.exitCode = exitCode
        self.originalTokenCount = originalTokenCount
        self.output = output
        self.maxOutputTokens = maxOutputTokens
    }

    public var responseText: String {
        var sections: [String] = []
        if !chunkID.isEmpty {
            sections.append("Chunk ID: \(chunkID)")
        }
        sections.append(
            String(
                format: "Wall time: %.4f seconds",
                wallTimeSeconds
            )
        )
        if let exitCode {
            sections.append("Process exited with code \(exitCode)")
        }
        if let processID {
            sections.append(
                "Process running with session ID \(processID)"
            )
        }
        if let originalTokenCount {
            sections.append(
                "Original token count: \(originalTokenCount)"
            )
        }
        sections.append("Output:")
        sections.append(Self.formattedOutput(
            output,
            maxTokens: maxOutputTokens
        ))
        return sections.joined(separator: "\n")
    }

    private static func formattedOutput(
        _ content: String,
        maxTokens: Int?
    ) -> String {
        let effectiveTokens = max(maxTokens ?? 10_000, 0)
        let byteBudget = effectiveTokens > Int.max / 4
            ? Int.max
            : effectiveTokens * 4
        let originalByteCount = content.utf8.count
        guard originalByteCount > byteBudget else {
            return content
        }

        let originalTokens = approximateTokenCount(
            byteCount: originalByteCount
        )
        let totalLines = lineCount(content)
        let truncated = truncateMiddle(
            content,
            byteBudget: byteBudget
        )
        return """
            Warning: truncated output (original token count: \(originalTokens))
            Total output lines: \(totalLines)

            \(truncated)
            """
    }

    private static func truncateMiddle(
        _ content: String,
        byteBudget: Int
    ) -> String {
        let utf8 = content.utf8
        let totalBytes = utf8.count
        let leftBudget = byteBudget / 2
        let rightBudget = byteBudget - leftBudget
        let tailStartTarget = max(totalBytes - rightBudget, 0)

        var prefixEnd = 0
        var suffixStart = totalBytes
        var suffixStarted = false
        var byteOffset = 0
        for scalar in content.unicodeScalars {
            let scalarBytes = String(scalar).utf8.count
            let scalarEnd = byteOffset + scalarBytes
            if scalarEnd <= leftBudget {
                prefixEnd = scalarEnd
            } else if byteOffset >= tailStartTarget,
                      !suffixStarted {
                suffixStart = byteOffset
                suffixStarted = true
            }
            byteOffset = scalarEnd
        }
        suffixStart = max(suffixStart, prefixEnd)

        let prefix = String(
            decoding: utf8.prefix(prefixEnd),
            as: UTF8.self
        )
        let suffix = String(
            decoding: utf8.dropFirst(suffixStart),
            as: UTF8.self
        )
        let removedTokens = approximateTokenCount(
            byteCount: max(totalBytes - byteBudget, 0)
        )
        return "\(prefix)…\(removedTokens) tokens truncated…\(suffix)"
    }

    private static func approximateTokenCount(
        byteCount: Int
    ) -> Int {
        byteCount > Int.max - 3
            ? Int.max / 4
            : (byteCount + 3) / 4
    }

    private static func lineCount(
        _ content: String
    ) -> Int {
        guard !content.isEmpty else {
            return 0
        }
        let segments = content.split(
            separator: "\n",
            omittingEmptySubsequences: false
        )
        return content.last == "\n"
            ? max(segments.count - 1, 0)
            : segments.count
    }
}

public enum CodexDesktopUnifiedExecTiming {
    public static func initialYield(_ value: UInt64) -> UInt64 {
        min(max(value, 250), 30_000)
    }

    public static func stdinWriteYield(_ value: UInt64) -> UInt64 {
        min(max(value, 250), 30_000)
    }

    public static func backgroundPollYield(_ value: UInt64) -> UInt64 {
        min(max(value, 5_000), 300_000)
    }
}

@MainActor
public protocol CodexDesktopBackgroundTerminalManaging: AnyObject {
    func listBackgroundTerminals(
        threadID: String,
        cursor: String?,
        limit: UInt32?
    ) throws -> CodexDesktopBackgroundTerminalPage

    func terminateBackgroundTerminal(
        threadID: String,
        processID: String
    ) throws -> Bool

    func cleanBackgroundTerminals(
        threadID: String
    )
}

/// iPad-native buffered command adapter for the filesystem commands used by
/// the released project surface. Interactive PTY sessions use a separate
/// session backend.
@MainActor
public final class CodexDesktopWorkspaceCommandExecutor:
    CodexDesktopCommandExecuting,
    CodexDesktopProcessManaging,
    CodexDesktopBackgroundTerminalManaging
{
    public typealias OutputSink =
        @MainActor @Sendable (CodexDesktopCommandExecOutputDelta) async -> Void
    public typealias ProcessOutputSink =
        @MainActor @Sendable (CodexDesktopCommandExecOutputDelta) async -> Void
    public typealias ProcessExitSink =
        @MainActor @Sendable (CodexDesktopProcessExited) async -> Void
    public typealias UnifiedOutputSink =
        @MainActor @Sendable (
            CodexCommandExecutionOutputDeltaNotification
        ) async -> Void
    public typealias UnifiedTerminalInteractionSink =
        @MainActor @Sendable (
            CodexTerminalInteractionNotification
        ) async -> Void

    private struct UnifiedContext {
        let threadID: CodexStoredThreadID
        let turnID: String
        let itemID: String
    }

    private final class Session {
        let processID: String
        let backgroundTerminal:
            CodexDesktopBackgroundCommandMetadata?
        let cwd: String
        let commandName: String
        let tty: Bool
        let streamsStdin: Bool
        var size: CodexDesktopCommandTerminalSize?
        var input = Data()
        var pendingOutput = Data()
        var isInputClosed = false
        var isTerminated = false
        var inputWaiters: [CheckedContinuation<Void, Never>] = []
#if os(macOS)
        var nativeProcess: Process?
        var nativeInput: FileHandle?
#endif
#if os(iOS) && canImport(ios_system)
        var embeddedInvocation: CodexEmbeddedProcessInvocation?
#endif

        init(
            processID: String,
            size: CodexDesktopCommandTerminalSize?,
            backgroundTerminal:
                CodexDesktopBackgroundCommandMetadata?,
            cwd: String,
            commandName: String,
            tty: Bool,
            streamsStdin: Bool
        ) {
            self.processID = processID
            self.size = size
            self.backgroundTerminal = backgroundTerminal
            self.cwd = cwd
            self.commandName = commandName
            self.tty = tty
            self.streamsStdin = streamsStdin
        }

        func drainPendingOutput() -> String {
            guard !pendingOutput.isEmpty else {
                return ""
            }
            let output = String(decoding: pendingOutput, as: UTF8.self)
            pendingOutput.removeAll(keepingCapacity: true)
            return output
        }

        func wakeInputWaiters() {
            let waiters = inputWaiters
            inputWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }
    }

    private struct UnifiedCompletion {
        let result: CodexDesktopCommandExecResult
        let wallTimeSeconds: Double
    }

    private var sessions: [String: Session] = [:]
    private var unifiedCompletions:
        [String: UnifiedCompletion] = [:]
    private var unifiedProcessIDs: Set<String> = []
    private var nextUnifiedProcessID: Int32 = 1
    private var outputSink: OutputSink?
    private var outputObservers: [UUID: OutputSink] = [:]
    private var processOutputSink: ProcessOutputSink?
    private var processExitSink: ProcessExitSink?
    private var unifiedOutputSink: UnifiedOutputSink?
    private var unifiedTerminalInteractionSink:
        UnifiedTerminalInteractionSink?
    private var unifiedContexts: [String: UnifiedContext] = [:]
    private var appServerProcessHandles: Set<String> = []

    public init(
        outputSink: OutputSink? = nil,
        processOutputSink: ProcessOutputSink? = nil,
        processExitSink: ProcessExitSink? = nil
    ) {
        self.outputSink = outputSink
        self.processOutputSink = processOutputSink
        self.processExitSink = processExitSink
    }

    public func configureOutputSink(
        _ outputSink: OutputSink?
    ) {
        self.outputSink = outputSink
    }

    /// Adds a secondary command-output observer without replacing the
    /// application/MCP sink configured by `configureOutputSink`.
    @discardableResult
    public func addOutputObserver(
        _ observer: @escaping OutputSink
    ) -> UUID {
        let token = UUID()
        outputObservers[token] = observer
        return token
    }

    public func removeOutputObserver(_ token: UUID) {
        outputObservers.removeValue(forKey: token)
    }

    public func configureProcessSinks(
        output: ProcessOutputSink?,
        exited: ProcessExitSink?
    ) {
        processOutputSink = output
        processExitSink = exited
    }

    public func configureUnifiedOutputSink(
        _ sink: UnifiedOutputSink?
    ) {
        unifiedOutputSink = sink
    }

    public func configureUnifiedTerminalInteractionSink(
        _ sink: UnifiedTerminalInteractionSink?
    ) {
        unifiedTerminalInteractionSink = sink
    }

    public func execute(
        _ params: CodexDesktopCommandExecParams,
        allowedRoots: [String]
    ) async throws -> CodexDesktopCommandExecResult {
        let prepared = try prepare(
            params,
            allowedRoots: allowedRoots
        )
        defer {
            if let processID = params.processID,
               !unifiedProcessIDs.contains(processID)
            {
                sessions.removeValue(forKey: processID)
            }
        }
        return try await executePrepared(
            params,
            cwd: prepared.cwd,
            session: prepared.session,
            allowedRoots: allowedRoots
        )
    }

    private func executePrepared(
        _ params: CodexDesktopCommandExecParams,
        cwd: URL,
        session: Session?,
        allowedRoots: [String]
    ) async throws -> CodexDesktopCommandExecResult {
        let name = URL(fileURLWithPath: params.command[0])
            .lastPathComponent
#if os(iOS) && canImport(ios_system)
        return try await executeEmbeddedProcess(
            params,
            cwd: cwd,
            session: session,
            allowedRoots: allowedRoots
        )
#endif
#if os(macOS)
        if params.command[0].contains("/")
            || !["pwd", "ls", "cat", "echo", "printf"].contains(name)
        {
            return try await executeNativeProcess(
                params,
                cwd: cwd,
                session: session
            )
        }
#endif
        let produced: CodexDesktopCommandExecResult
        switch name {
        case "pwd":
            produced = result(cwd.path + "\n", params: params)
        case "ls":
            let target = params.command.dropFirst().first
                .map { cwd.appendingPathComponent($0) } ?? cwd
            _ = try confinedCWD(
                target.path,
                allowedRoots: allowedRoots
            )
            let names = try FileManager.default
                .contentsOfDirectory(atPath: target.path)
                .sorted()
                .joined(separator: "\n")
            produced = result(
                names + (names.isEmpty ? "" : "\n"),
                params: params
            )
        case "cat":
            if let path = params.command.dropFirst().first {
                let url = cwd.appendingPathComponent(path)
                _ = try confinedCWD(
                    url.deletingLastPathComponent().path,
                    allowedRoots: allowedRoots
                )
                let text = try String(
                    contentsOf: url,
                    encoding: .utf8
                )
                produced = result(text, params: params)
            } else if params.streamStdin, let session {
                while !session.isInputClosed,
                      !session.isTerminated
                {
                    await withCheckedContinuation { continuation in
                        session.inputWaiters.append(continuation)
                    }
                }
                guard !session.isTerminated else {
                    throw CodexDesktopCommandExecError.processTerminated
                }
                produced = result(
                    session.drainPendingOutput(),
                    params: params
                )
            } else {
                produced = .init(
                    exitCode: 1,
                    stdout: "",
                    stderr: "cat: missing file operand\n"
                )
            }
        case "echo":
            produced = result(
                params.command.dropFirst().joined(separator: " ") + "\n",
                params: params
            )
        case "printf":
            produced = result(
                params.command.dropFirst().joined(),
                params: params
            )
        default:
            produced = .init(
                exitCode: 127,
                stdout: "",
                stderr: "\(name): command not found\n"
            )
        }

        if let session, session.isTerminated {
            throw CodexDesktopCommandExecError.processTerminated
        }
        if !params.streamStdoutStderr,
           let processID = params.processID,
           unifiedContexts[processID] != nil
        {
            if !produced.stdout.isEmpty {
                await emitUnifiedOutput(
                    processID: processID,
                    data: Data(produced.stdout.utf8)
                )
            }
            if !produced.stderr.isEmpty {
                await emitUnifiedOutput(
                    processID: processID,
                    data: Data(produced.stderr.utf8)
                )
            }
        }
        guard params.streamStdoutStderr,
              let processID = params.processID
        else {
            return produced
        }
        if !produced.stdout.isEmpty {
            await emit(
                processID: processID,
                stream: .stdout,
                text: produced.stdout,
                capReached: didReachCap(
                    produced.stdout,
                    params: params
                )
            )
        }
        if !produced.stderr.isEmpty {
            await emit(
                processID: processID,
                stream: .stderr,
                text: produced.stderr,
                capReached: didReachCap(
                    produced.stderr,
                    params: params
                )
            )
        }
        return .init(
            exitCode: produced.exitCode,
            stdout: "",
            stderr: ""
        )
    }

    public func spawnProcess(
        _ params: CodexDesktopCommandExecParams,
        allowedRoots: [String]
    ) throws {
        guard let processHandle = params.processID else {
            throw CodexDesktopCommandExecError.invalidParams
        }
        let prepared = try prepare(
            params,
            allowedRoots: allowedRoots
        )
        appServerProcessHandles.insert(processHandle)

        if !params.disableTimeout {
            let timeout = params.timeoutMs ?? 600_000
            Task { @MainActor [weak self] in
                try? await Task.sleep(
                    for: .milliseconds(timeout)
                )
                guard let self,
                      self.appServerProcessHandles
                        .contains(processHandle),
                      let session =
                          self.sessions[processHandle],
                      !session.isTerminated
                else {
                    return
                }
                self.terminateSession(session)
            }
        }

        Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            let result: CodexDesktopCommandExecResult
            do {
                result = try await self.executePrepared(
                    params,
                    cwd: prepared.cwd,
                    session: prepared.session,
                    allowedRoots: allowedRoots
                )
            } catch {
                result = .init(
                    exitCode: -1,
                    stdout: "",
                    stderr: String(describing: error)
                )
            }
            let streamed = params.streamStdoutStderr
            let exited = CodexDesktopProcessExited(
                processHandle: processHandle,
                exitCode: Self.int32ExitCode(
                    result.exitCode
                ),
                stdout: streamed ? "" : result.stdout,
                stdoutCapReached: self.didReachCap(
                    result.stdout,
                    params: params
                ),
                stderr: streamed ? "" : result.stderr,
                stderrCapReached: self.didReachCap(
                    result.stderr,
                    params: params
                )
            )
            self.sessions.removeValue(
                forKey: processHandle
            )
            self.appServerProcessHandles.remove(
                processHandle
            )
            if let processExitSink =
                self.processExitSink
            {
                await processExitSink(exited)
            }
        }
    }

    public func writeProcess(
        _ params: CodexDesktopCommandExecWriteParams
    ) throws {
        guard appServerProcessHandles
            .contains(params.processID),
              sessions[params.processID]?.streamsStdin == true
        else {
            throw CodexDesktopCommandExecError.processNotFound
        }
        try write(params)
    }

    public func resizeProcess(
        _ params: CodexDesktopCommandExecResizeParams
    ) throws {
        guard appServerProcessHandles
            .contains(params.processID),
              sessions[params.processID]?.tty == true
        else {
            throw CodexDesktopCommandExecError.processNotFound
        }
        try resize(params)
    }

    public func killProcess(
        _ params: CodexDesktopCommandExecTerminateParams
    ) throws {
        guard appServerProcessHandles
            .contains(params.processID)
        else {
            throw CodexDesktopCommandExecError.processNotFound
        }
        try terminate(params)
    }

#if os(iOS) && canImport(ios_system)
    private func executeEmbeddedProcess(
        _ params: CodexDesktopCommandExecParams,
        cwd: URL,
        session: Session?,
        allowedRoots: [String]
    ) async throws -> CodexDesktopCommandExecResult {
        let name = URL(fileURLWithPath: params.command[0])
            .lastPathComponent
        let command: String?
        if ["sh", "bash", "zsh"].contains(name),
           params.command.count == 3,
           ["-lc", "-c"].contains(params.command[1])
        {
            let script = params.command[2]
            command = script.isEmpty || script.contains("\u{0}")
                ? nil
                : script
        } else {
            command = CodexEmbeddedProcessCommandLine
                .shellCommand(params.command)
        }
        guard let command
        else {
            throw CodexDesktopCommandExecError.invalidParams
        }

        let invocation = try CodexEmbeddedProcessInvocation(
            command: command,
            environment: params.environment ?? [:],
            cwd: cwd,
            allowedRoots: allowedRoots,
            tty: params.tty,
            size: params.size
        )
        let timeoutState = CodexDesktopCommandTimeoutState()
        let timeoutTask = Self.timeoutTask(
            params: params,
            state: timeoutState
        ) {
            invocation.terminate()
        }
        defer { timeoutTask?.cancel() }
        session?.embeddedInvocation = invocation
        if let session {
            if !session.input.isEmpty {
                try invocation.write(session.input)
                session.input.removeAll(keepingCapacity: false)
            }
            if session.isInputClosed {
                invocation.closeInput()
            }
            if session.isTerminated {
                invocation.terminate()
                throw CodexDesktopCommandExecError.processTerminated
            }
        }

        async let stdout = readEmbeddedStream(
            invocation.output,
            processID: params.processID,
            stream: .stdout,
            params: params
        )
        async let stderr = readEmbeddedStream(
            invocation.error,
            processID: params.processID,
            stream: .stderr,
            params: params
        )
        let status = await Task.detached {
            invocation.run()
        }.value
        let (stdoutData, stderrData) = try await (stdout, stderr)
        session?.embeddedInvocation = nil

        if timeoutState.didTimeOut {
            throw CodexDesktopCommandExecError.timedOut
        }
        if session?.isTerminated == true {
            throw CodexDesktopCommandExecError.processTerminated
        }
        if params.streamStdoutStderr {
            return .init(
                exitCode: Int64(status),
                stdout: "",
                stderr: ""
            )
        }
        return .init(
            exitCode: Int64(status),
            stdout: cappedEmbeddedText(
                stdoutData,
                params: params
            ),
            stderr: cappedEmbeddedText(
                stderrData,
                params: params
            )
        )
    }

    private func readEmbeddedStream(
        _ handle: FileHandle,
        processID: String?,
        stream: CodexDesktopCommandExecOutputDelta.Stream,
        params: CodexDesktopCommandExecParams
    ) async throws -> Data {
        var captured = Data()
        let outputCap: Int?
        if !params.disableOutputCap,
           let cap = params.outputBytesCap
        {
            outputCap = cap > UInt64(Int.max)
                ? Int.max
                : Int(cap)
        } else {
            outputCap = nil
        }
        while let chunk = try await Task.detached(
            operation: {
                try handle.read(upToCount: 16 * 1_024)
            }
        ).value, !chunk.isEmpty {
            let accepted: Data
            if let outputCap {
                let remaining = max(outputCap - captured.count, 0)
                accepted = Data(chunk.prefix(remaining))
            } else {
                accepted = chunk
            }
            captured.append(accepted)
            if params.streamStdoutStderr,
               let processID,
               !accepted.isEmpty
            {
                await emit(
                    processID: processID,
                    stream: stream,
                    data: accepted,
                    capReached:
                        outputCap.map { captured.count >= $0 }
                        ?? false
                )
            } else if let processID, !accepted.isEmpty {
                await emitUnifiedOutput(
                    processID: processID,
                    data: accepted
                )
            }
        }
        return captured
    }

    private func cappedEmbeddedText(
        _ data: Data,
        params: CodexDesktopCommandExecParams
    ) -> String {
        guard !params.disableOutputCap,
              let cap = params.outputBytesCap,
              data.count > cap
        else {
            return String(decoding: data, as: UTF8.self)
        }
        let boundedCap = cap > UInt64(Int.max)
            ? Int.max
            : Int(cap)
        return String(
            decoding: data.prefix(boundedCap),
            as: UTF8.self
        )
    }
#endif

#if os(macOS)
    private func executeNativeProcess(
        _ params: CodexDesktopCommandExecParams,
        cwd: URL,
        session: Session?
    ) async throws -> CodexDesktopCommandExecResult {
        let process = Process()
        if params.command[0].contains("/") {
            let executable = URL(
                fileURLWithPath: params.command[0],
                relativeTo: cwd
            ).standardizedFileURL
            process.executableURL = executable
            process.arguments = Array(params.command.dropFirst())
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = params.command
        }
        process.currentDirectoryURL = cwd
        var environment = ProcessInfo.processInfo.environment
        for (name, value) in params.environment ?? [:] {
            if let value {
                environment[name] = value
            } else {
                environment.removeValue(forKey: name)
            }
        }
        process.environment = environment

        let input = Pipe()
        let output = Pipe()
        let error = Pipe()
        process.standardInput = params.streamStdin
            ? input
            : FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = error
        session?.nativeProcess = process
        session?.nativeInput = params.streamStdin
            ? input.fileHandleForWriting
            : nil

        try process.run()
        let processReference = NativeProcessReference(process)
        let timeoutState = CodexDesktopCommandTimeoutState()
        let timeoutTask = Self.timeoutTask(
            params: params,
            state: timeoutState
        ) {
            if processReference.process.isRunning {
                processReference.process.terminate()
            }
        }
        defer { timeoutTask?.cancel() }
        async let stdout = readNativeStream(
            output.fileHandleForReading,
            processID: params.processID,
            stream: .stdout,
            params: params
        )
        async let stderr = readNativeStream(
            error.fileHandleForReading,
            processID: params.processID,
            stream: .stderr,
            params: params
        )
        async let exitCode: Int32 = Task.detached {
            processReference.process.waitUntilExit()
            return processReference.process.terminationStatus
        }.value
        let (stdoutData, stderrData, status) =
            try await (stdout, stderr, exitCode)
        session?.nativeInput = nil
        session?.nativeProcess = nil

        if timeoutState.didTimeOut {
            throw CodexDesktopCommandExecError.timedOut
        }
        if params.streamStdoutStderr {
            return .init(
                exitCode: Int64(status),
                stdout: "",
                stderr: ""
            )
        }
        return .init(
            exitCode: Int64(status),
            stdout: cappedNativeText(stdoutData, params: params),
            stderr: cappedNativeText(stderrData, params: params)
        )
    }

    private func readNativeStream(
        _ handle: FileHandle,
        processID: String?,
        stream: CodexDesktopCommandExecOutputDelta.Stream,
        params: CodexDesktopCommandExecParams
    ) async throws -> Data {
        var captured = Data()
        let outputCap: Int?
        if !params.disableOutputCap,
           let cap = params.outputBytesCap
        {
            outputCap = cap > UInt64(Int.max)
                ? Int.max
                : Int(cap)
        } else {
            outputCap = nil
        }
        while let chunk = try await Task.detached(
            operation: {
                try handle.read(upToCount: 16 * 1_024)
            }
        ).value, !chunk.isEmpty {
            let accepted: Data
            if let outputCap {
                let remaining = max(outputCap - captured.count, 0)
                accepted = Data(chunk.prefix(remaining))
            } else {
                accepted = chunk
            }
            captured.append(accepted)
            if params.streamStdoutStderr,
               let processID,
               !accepted.isEmpty
            {
                await emit(
                    processID: processID,
                    stream: stream,
                    data: accepted,
                    capReached:
                        outputCap.map { captured.count >= $0 }
                        ?? false
                )
            } else if let processID, !accepted.isEmpty {
                await emitUnifiedOutput(
                    processID: processID,
                    data: accepted
                )
            }
        }
        return captured
    }

    private func cappedNativeText(
        _ data: Data,
        params: CodexDesktopCommandExecParams
    ) -> String {
        guard !params.disableOutputCap,
              let cap = params.outputBytesCap,
              data.count > cap
        else {
            return String(decoding: data, as: UTF8.self)
        }
        let boundedCap = cap > UInt64(Int.max)
            ? Int.max
            : Int(cap)
        return String(
            decoding: data.prefix(boundedCap),
            as: UTF8.self
        )
    }
#endif

    private static func timeoutTask(
        params: CodexDesktopCommandExecParams,
        state: CodexDesktopCommandTimeoutState,
        terminate: @escaping @Sendable () -> Void
    ) -> Task<Void, Never>? {
        guard !params.disableTimeout else {
            return nil
        }
        let timeout = params.timeoutMs ?? 600_000
        return Task.detached {
            do {
                try await Task.sleep(for: .milliseconds(timeout))
            } catch {
                return
            }
            guard !Task.isCancelled else {
                return
            }
            state.markTimedOut()
            terminate()
        }
    }

    public func write(
        _ params: CodexDesktopCommandExecWriteParams
    ) throws {
        guard let session = sessions[params.processID] else {
            throw CodexDesktopCommandExecError.processNotFound
        }
        guard !session.isTerminated,
              !session.isInputClosed
        else {
            throw CodexDesktopCommandExecError.processTerminated
        }
#if os(macOS)
        if let nativeInput = session.nativeInput {
            if let delta = params.delta {
                try nativeInput.write(contentsOf: delta)
            }
            if params.closeStdin {
                try nativeInput.close()
                session.nativeInput = nil
                session.isInputClosed = true
            }
            return
        }
#endif
#if os(iOS) && canImport(ios_system)
        if let invocation = session.embeddedInvocation {
            if let delta = params.delta {
                try invocation.write(delta)
            }
            if params.closeStdin {
                invocation.closeInput()
                session.isInputClosed = true
            }
            return
        }
#endif
        if let delta = params.delta {
            session.input.append(delta)
#if !os(iOS)
            if session.commandName == "cat" {
                session.pendingOutput.append(delta)
            }
#endif
        }
        if params.closeStdin {
            session.isInputClosed = true
        }
        session.wakeInputWaiters()
    }

    public func resize(
        _ params: CodexDesktopCommandExecResizeParams
    ) throws {
        guard let session = sessions[params.processID] else {
            throw CodexDesktopCommandExecError.processNotFound
        }
        guard !session.isTerminated else {
            throw CodexDesktopCommandExecError.processTerminated
        }
        session.size = params.size
#if os(iOS) && canImport(ios_system)
        session.embeddedInvocation?.resize(params.size)
#endif
    }

    public func terminate(
        _ params: CodexDesktopCommandExecTerminateParams
    ) throws {
        guard let session = sessions[params.processID] else {
            throw CodexDesktopCommandExecError.processNotFound
        }
        terminateSession(session)
    }

    public func listBackgroundTerminals(
        threadID: String,
        cursor: String?,
        limit: UInt32?
    ) throws -> CodexDesktopBackgroundTerminalPage {
        let cursorProcessID: Int32?
        if let cursor {
            guard let parsed = Int32(cursor) else {
                throw CodexDesktopCommandExecError.invalidParams
            }
            cursorProcessID = parsed
        } else {
            cursorProcessID = nil
        }

        let terminals = sessions.values.compactMap { session
            -> CodexDesktopBackgroundTerminal? in
            guard !session.isTerminated,
                  let metadata = session.backgroundTerminal,
                  metadata.threadID == threadID,
                  Int32(session.processID) != nil
            else {
                return nil
            }
            return CodexDesktopBackgroundTerminal(
                itemID: metadata.itemID,
                processID: session.processID,
                command: metadata.command,
                cwd: session.cwd,
                osPID: nil,
                cpuPercent: nil,
                rssKB: nil
            )
        }.sorted {
            Int32($0.processID)! < Int32($1.processID)!
        }

        let start: Int
        if let cursorProcessID {
            start = terminals.firstIndex {
                Int32($0.processID).map {
                    $0 > cursorProcessID
                } ?? false
            } ?? terminals.endIndex
        } else {
            start = terminals.startIndex
        }
        let effectiveLimit = max(Int(limit ?? UInt32(terminals.count)), 1)
        let proposedEnd = start.addingReportingOverflow(effectiveLimit)
        let end = proposedEnd.overflow
            ? terminals.endIndex
            : min(terminals.endIndex, proposedEnd.partialValue)
        let page = Array(terminals[start..<end])
        return CodexDesktopBackgroundTerminalPage(
            data: page,
            nextCursor: end < terminals.endIndex
                ? page.last?.processID
                : nil
        )
    }

    public func terminateBackgroundTerminal(
        threadID: String,
        processID: String
    ) throws -> Bool {
        guard Int32(processID) != nil else {
            throw CodexDesktopCommandExecError.invalidParams
        }
        guard let session = sessions[processID],
              !session.isTerminated,
              session.backgroundTerminal?.threadID == threadID
        else {
            return false
        }
        terminateSession(session)
        return true
    }

    public func cleanBackgroundTerminals(
        threadID: String
    ) {
        for session in sessions.values
        where !session.isTerminated
            && session.backgroundTerminal?.threadID == threadID
        {
            terminateSession(session)
        }
    }

    public func launchUnifiedCommand(
        command: String,
        threadID: String,
        turnID: String,
        itemID: String,
        cwd: String,
        allowedRoots: [String],
        tty: Bool,
        yieldTimeMS: UInt64,
        maxOutputTokens: Int? = nil,
        shell: String? = nil,
        login: Bool = true
    ) async throws -> CodexDesktopUnifiedExecOutput {
        guard !command.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty, !command.contains("\u{0}")
        else {
            throw CodexDesktopCommandExecError.invalidParams
        }
        let processID = allocateUnifiedProcessID()
        unifiedProcessIDs.insert(processID)
        unifiedContexts[processID] = UnifiedContext(
            threadID: CodexStoredThreadID(rawValue: threadID),
            turnID: turnID,
            itemID: itemID
        )
        let startedAt = Date()
        let params = CodexDesktopCommandExecParams(
            command: unifiedCommandArguments(
                command,
                shell: shell,
                login: login
            ),
            processID: processID,
            tty: tty,
            streamStdin: true,
            streamStdoutStderr: false,
            outputBytesCap: nil,
            disableOutputCap: true,
            disableTimeout: true,
            timeoutMs: nil,
            cwd: cwd,
            environment: nil,
            size: tty
                ? CodexDesktopCommandTerminalSize(rows: 24, cols: 80)
                : nil,
            sandboxPolicy: nil,
            backgroundTerminal:
                CodexDesktopBackgroundCommandMetadata(
                    threadID: threadID,
                    itemID: itemID,
                    command: command
                )
        )
        Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            let result: CodexDesktopCommandExecResult
            do {
                result = try await execute(
                    params,
                    allowedRoots: allowedRoots
                )
            } catch {
                result = .init(
                    exitCode: 1,
                    stdout: "",
                    stderr: String(describing: error)
                )
            }
            unifiedCompletions[processID] =
                UnifiedCompletion(
                    result: result,
                    wallTimeSeconds:
                        Date().timeIntervalSince(startedAt)
                )
        }
        return try await waitForUnifiedOutput(
            processID: processID,
            yieldTimeMS: CodexDesktopUnifiedExecTiming.initialYield(
                yieldTimeMS
            ),
            preferCompletion: false,
            maxOutputTokens: maxOutputTokens
        )
    }

    public func continueUnifiedCommand(
        processID: String,
        chars: String,
        yieldTimeMS: UInt64,
        maxOutputTokens: Int? = nil
    ) async throws -> CodexDesktopUnifiedExecOutput {
        guard Int32(processID) != nil else {
            throw CodexDesktopCommandExecError.invalidParams
        }
        if let completed = takeUnifiedCompletion(processID) {
            return unifiedOutput(
                completed,
                maxOutputTokens: maxOutputTokens
            )
        }
        let endOfTransmission = chars.contains("\u{4}")
        let bytes = chars.replacingOccurrences(
            of: "\u{4}",
            with: ""
        )
        if !bytes.isEmpty, let context = unifiedContexts[processID] {
            await unifiedTerminalInteractionSink?(
                CodexTerminalInteractionNotification(
                    threadID: context.threadID,
                    turnID: context.turnID,
                    itemID: context.itemID,
                    processID: processID,
                    stdin: bytes
                )
            )
        }
        try write(
            .init(
                processID: processID,
                delta: bytes.isEmpty ? nil : Data(bytes.utf8),
                closeStdin: endOfTransmission
            )
        )
        return try await waitForUnifiedOutput(
            processID: processID,
            yieldTimeMS: bytes.isEmpty
                ? CodexDesktopUnifiedExecTiming.backgroundPollYield(
                    yieldTimeMS
                )
                : CodexDesktopUnifiedExecTiming.stdinWriteYield(
                    yieldTimeMS
                ),
            preferCompletion: endOfTransmission,
            maxOutputTokens: maxOutputTokens
        )
    }

    private func terminateSession(
        _ session: Session
    ) {
        session.isTerminated = true
        session.isInputClosed = true
#if os(macOS)
        try? session.nativeInput?.close()
        session.nativeInput = nil
        if session.nativeProcess?.isRunning == true {
            session.nativeProcess?.terminate()
        }
#endif
#if os(iOS) && canImport(ios_system)
        session.embeddedInvocation?.terminate()
#endif
        session.wakeInputWaiters()
    }

    private func allocateUnifiedProcessID() -> String {
        while sessions[String(nextUnifiedProcessID)] != nil
            || unifiedCompletions[String(nextUnifiedProcessID)] != nil
        {
            nextUnifiedProcessID =
                nextUnifiedProcessID == Int32.max
                    ? 1
                    : nextUnifiedProcessID + 1
        }
        let allocated = String(nextUnifiedProcessID)
        nextUnifiedProcessID =
            nextUnifiedProcessID == Int32.max
                ? 1
                : nextUnifiedProcessID + 1
        return allocated
    }

    private func waitForUnifiedOutput(
        processID: String,
        yieldTimeMS: UInt64,
        preferCompletion: Bool,
        maxOutputTokens: Int?
    ) async throws -> CodexDesktopUnifiedExecOutput {
        let boundedMS = min(max(yieldTimeMS, 250), 300_000)
        let deadline = Date().addingTimeInterval(
            Double(boundedMS) / 1_000
        )
        repeat {
            if let completed = takeUnifiedCompletion(processID) {
                return unifiedOutput(
                    completed,
                    maxOutputTokens: maxOutputTokens
                )
            }
            if !preferCompletion,
               let session = sessions[processID],
               !session.pendingOutput.isEmpty
            {
                return CodexDesktopUnifiedExecOutput(
                    chunkID: unifiedChunkID(),
                    wallTimeSeconds: 0,
                    processID: processID,
                    exitCode: nil,
                    output: session.drainPendingOutput(),
                    maxOutputTokens: maxOutputTokens
                )
            }
            try await Task.sleep(for: .milliseconds(10))
        } while Date() < deadline
        if let completed = takeUnifiedCompletion(processID) {
            return unifiedOutput(
                completed,
                maxOutputTokens: maxOutputTokens
            )
        }
        guard let session = sessions[processID],
              !session.isTerminated
        else {
            throw CodexDesktopCommandExecError.processNotFound
        }
        return CodexDesktopUnifiedExecOutput(
            chunkID: unifiedChunkID(),
            wallTimeSeconds: 0,
            processID: processID,
            exitCode: nil,
            output: session.drainPendingOutput(),
            maxOutputTokens: maxOutputTokens
        )
    }

    private func takeUnifiedCompletion(
        _ processID: String
    ) -> UnifiedCompletion? {
        guard var completion = unifiedCompletions.removeValue(
            forKey: processID
        ) else {
            return nil
        }
        if let session = sessions.removeValue(forKey: processID) {
            let pending = session.drainPendingOutput()
            if !pending.isEmpty {
                completion = UnifiedCompletion(
                    result: .init(
                        exitCode: completion.result.exitCode,
                        stdout: pending + completion.result.stdout,
                        stderr: completion.result.stderr
                    ),
                    wallTimeSeconds: completion.wallTimeSeconds
                )
            }
        }
        unifiedProcessIDs.remove(processID)
        unifiedContexts.removeValue(forKey: processID)
        return completion
    }

    private func unifiedOutput(
        _ completion: UnifiedCompletion,
        maxOutputTokens: Int?
    ) -> CodexDesktopUnifiedExecOutput {
        CodexDesktopUnifiedExecOutput(
            chunkID: unifiedChunkID(),
            wallTimeSeconds: completion.wallTimeSeconds,
            processID: nil,
            exitCode: completion.result.exitCode,
            output:
                completion.result.stdout
                + completion.result.stderr,
            maxOutputTokens: maxOutputTokens
        )
    }

    private func unifiedChunkID() -> String {
        String(
            format: "%06x",
            Int.random(in: 0...0xFF_FFFF)
        )
    }

    private func unifiedCommandArguments(
        _ command: String,
        shell: String?,
        login: Bool
    ) -> [String] {
        let arguments = command.split(
            whereSeparator: \.isWhitespace
        ).map(String.init)
        if shell == nil, login,
           let name = arguments.first,
           ["pwd", "ls", "cat", "echo", "printf"].contains(name) {
            return arguments
        }
        return [
            shell ?? "sh",
            login ? "-lc" : "-c",
            command,
        ]
    }

    private func prepare(
        _ params: CodexDesktopCommandExecParams,
        allowedRoots: [String]
    ) throws -> (cwd: URL, session: Session?) {
        let cwd = try confinedCWD(
            params.cwd,
            allowedRoots: allowedRoots
        )
        guard let processID = params.processID else {
            return (cwd, nil)
        }
        guard sessions[processID] == nil else {
            throw CodexDesktopCommandExecError
                .duplicateProcessID
        }
        let session = Session(
            processID: processID,
            size: params.size,
            backgroundTerminal: params.backgroundTerminal,
            cwd: cwd.path,
            commandName:
                URL(fileURLWithPath: params.command[0])
                    .lastPathComponent,
            tty: params.tty,
            streamsStdin: params.streamStdin
        )
        sessions[processID] = session
        return (cwd, session)
    }

    private func confinedCWD(
        _ requested: String?,
        allowedRoots: [String]
    ) throws -> URL {
        guard let firstRoot = allowedRoots.first else {
            throw CodexDesktopCommandExecError.cwdOutsideWorkspace
        }
        let target = URL(
            fileURLWithPath: requested ?? firstRoot,
            isDirectory: true
        ).standardizedFileURL.resolvingSymlinksInPath()
        let allowed = allowedRoots.contains { root in
            let root = URL(
                fileURLWithPath: root,
                isDirectory: true
            ).standardizedFileURL.resolvingSymlinksInPath().path
            return target.path == root
                || target.path.hasPrefix(root + "/")
        }
        guard allowed else {
            throw CodexDesktopCommandExecError.cwdOutsideWorkspace
        }
        return target
    }

    private func result(
        _ stdout: String,
        params: CodexDesktopCommandExecParams
    ) -> CodexDesktopCommandExecResult {
        guard !params.disableOutputCap,
              let cap = params.outputBytesCap,
              stdout.utf8.count > cap
        else {
            return .init(
                exitCode: 0,
                stdout: stdout,
                stderr: ""
            )
        }
        let boundedCap = cap > UInt64(Int.max)
            ? Int.max
            : Int(cap)
        let bytes = Array(stdout.utf8.prefix(boundedCap))
        return .init(
            exitCode: 0,
            stdout: String(decoding: bytes, as: UTF8.self),
            stderr: ""
        )
    }

    private func didReachCap(
        _ text: String,
        params: CodexDesktopCommandExecParams
    ) -> Bool {
        guard !params.disableOutputCap,
              let cap = params.outputBytesCap
        else {
            return false
        }
        return text.utf8.count >= cap
    }

    private static func int32ExitCode(
        _ value: Int64
    ) -> Int32 {
        if value < Int64(Int32.min) {
            return Int32.min
        }
        if value > Int64(Int32.max) {
            return Int32.max
        }
        return Int32(value)
    }

    private func emit(
        processID: String,
        stream: CodexDesktopCommandExecOutputDelta.Stream,
        text: String,
        capReached: Bool
    ) async {
        await emit(
            processID: processID,
            stream: stream,
            data: Data(text.utf8),
            capReached: capReached
        )
    }

    private func emit(
        processID: String,
        stream: CodexDesktopCommandExecOutputDelta.Stream,
        data: Data,
        capReached: Bool
    ) async {
        let delta = CodexDesktopCommandExecOutputDelta(
            processID: processID,
            stream: stream,
            delta: data,
            capReached: capReached
        )
        if appServerProcessHandles.contains(processID) {
            await processOutputSink?(delta)
        } else {
            await outputSink?(delta)
            let observers = Array(outputObservers.values)
            for observer in observers {
                await observer(delta)
            }
        }
        await emitUnifiedOutput(processID: processID, data: data)
    }

    private func emitUnifiedOutput(
        processID: String,
        data: Data
    ) async {
        if let context = unifiedContexts[processID], !data.isEmpty {
            await unifiedOutputSink?(
                CodexCommandExecutionOutputDeltaNotification(
                    threadID: context.threadID,
                    turnID: context.turnID,
                    itemID: context.itemID,
                    delta: String(decoding: data, as: UTF8.self)
                )
            )
        }
    }
}

#if os(macOS)
private final class NativeProcessReference: @unchecked Sendable {
    let process: Process

    init(_ process: Process) {
        self.process = process
    }
}
#endif
