import Foundation
import Testing

@testable import CodexPadApplication
@testable import CodexPadDomain
@testable import CodexPadProtocolBridge

@Test
func embeddedProcessCommandLinePreservesEveryArgvBoundary() {
    let command = CodexEmbeddedProcessCommandLine.shellCommand([
        "/bin/tool",
        "plain",
        "two words",
        "quote'and",
        "",
        "$HOME; rm -rf /",
    ])

    #expect(
        command
            == #"'/bin/tool' 'plain' 'two words' 'quote'\''and' '' '$HOME; rm -rf /'"#
    )
}

@Test
func embeddedProcessCommandLineRejectsEmptyAndNulArgv() {
    #expect(
        CodexEmbeddedProcessCommandLine.shellCommand([]) == nil
    )
    #expect(
        CodexEmbeddedProcessCommandLine.shellCommand([
            "printf",
            "bad\u{0}value",
        ]) == nil
    )
}

@Test
func desktopProcessSpawnDecoderMatchesOfficialDoubleOptionContract()
    throws
{
    let defaults = try CodexDesktopProcessSpawnDecoder.decode(
        .object([
            "command": .array([.string("echo"), .string("ready")]),
            "processHandle": .string("process-defaults"),
            "cwd": .string("/workspace"),
        ])
    )
    #expect(
        defaults.outputBytesCap
            == CodexDesktopProcessSpawnDecoder
                .defaultOutputBytesCap
    )
    #expect(defaults.disableOutputCap == false)
    #expect(defaults.timeoutMs == nil)
    #expect(defaults.disableTimeout == false)
    #expect(defaults.streamStdin == false)
    #expect(defaults.streamStdoutStderr == false)

    let unbounded = try CodexDesktopProcessSpawnDecoder.decode(
        .object([
            "command": .array([.string("cat")]),
            "processHandle": .string("process-unbounded"),
            "cwd": .string("/workspace"),
            "tty": .bool(true),
            "outputBytesCap": .null,
            "timeoutMs": .null,
            "env": .object([
                "SET": .string("value"),
                "UNSET": .null,
            ]),
            "size": .object([
                "rows": .integer(24),
                "cols": .integer(80),
            ]),
        ])
    )
    #expect(unbounded.disableOutputCap)
    #expect(unbounded.disableTimeout)
    #expect(unbounded.streamStdin)
    #expect(unbounded.streamStdoutStderr)
    #expect(unbounded.environment?["SET"] == "value")
    #expect(
        unbounded.environment?.keys.contains("UNSET")
            == true
    )
    if case .some(.none) =
        unbounded.environment?["UNSET"]
    {
        // An explicit null preserves the official "unset inherited
        // environment variable" instruction.
    } else {
        Issue.record("UNSET must preserve an explicit null value")
    }
    #expect(
        unbounded.size
            == CodexDesktopCommandTerminalSize(
                rows: 24,
                cols: 80
            )
    )
}

@Test
func desktopProcessDecodersRejectInvalidOfficialShapes() {
    #expect(throws: CodexDesktopCommandExecError.self) {
        try CodexDesktopProcessSpawnDecoder.decode(
            .object([
                "command": .array([]),
                "processHandle": .string("empty"),
                "cwd": .string("/workspace"),
            ])
        )
    }
    #expect(throws: CodexDesktopCommandExecError.self) {
        try CodexDesktopProcessSpawnDecoder.decode(
            .object([
                "command": .array([.string("echo")]),
                "processHandle": .string("relative"),
                "cwd": .string("workspace"),
            ])
        )
    }
    #expect(throws: CodexDesktopCommandExecError.self) {
        try CodexDesktopProcessSpawnDecoder.decode(
            .object([
                "command": .array([.string("echo")]),
                "processHandle": .string("size-without-tty"),
                "cwd": .string("/workspace"),
                "size": .object([
                    "rows": .integer(24),
                    "cols": .integer(80),
                ]),
            ])
        )
    }
    #expect(throws: CodexDesktopCommandExecError.self) {
        try CodexDesktopProcessSpawnDecoder.decode(
            .object([
                "command": .array([.string("echo")]),
                "processHandle": .string("oversized-pty"),
                "cwd": .string("/workspace"),
                "tty": .bool(true),
                "size": .object([
                    "rows": .integer(65_536),
                    "cols": .integer(80),
                ]),
            ])
        )
    }
}

@Test
@MainActor
func desktopCommandExecEnforcesTimeoutOutsideSpawnPath() async throws {
    #if os(macOS)
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(
            "codex-command-timeout-\(UUID().uuidString)",
            isDirectory: true
        )
    try FileManager.default.createDirectory(
        at: root,
        withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: root) }

    let executor = CodexDesktopWorkspaceCommandExecutor()
    let params = CodexDesktopCommandExecParams(
        command: ["/bin/sh", "-c", "sleep 2"],
        processID: nil,
        tty: false,
        streamStdin: false,
        streamStdoutStderr: false,
        outputBytesCap: nil,
        disableOutputCap: true,
        disableTimeout: false,
        timeoutMs: 25,
        cwd: root.path,
        environment: nil,
        size: nil,
        sandboxPolicy: nil
    )
    let startedAt = ContinuousClock.now
    await #expect(
        throws: CodexDesktopCommandExecError.timedOut
    ) {
        try await executor.execute(
            params,
            allowedRoots: [root.path]
        )
    }
    #expect(startedAt.duration(to: .now) < .seconds(1))
    #endif
}

@Test
@MainActor
func desktopProcessRouterCoversProcessOutputDeltaNotificationAndProcessExitedNotification()
    async throws
{
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(
            "codex-process-\(UUID().uuidString)",
            isDirectory: true
        )
    try FileManager.default.createDirectory(
        at: root,
        withIntermediateDirectories: true
    )
    defer {
        try? FileManager.default.removeItem(at: root)
    }

    var outputDeltas: [CodexDesktopCommandExecOutputDelta] = []
    var exits: [CodexDesktopProcessExited] = []
    let executor = CodexDesktopWorkspaceCommandExecutor(
        processOutputSink: { outputDeltas.append($0) },
        processExitSink: { exits.append($0) }
    )

    let spawn = await processRequest(
        id: 1,
        method: "process/spawn",
        params: [
            "command": .array([.string("cat")]),
            "processHandle": .string("interactive"),
            "cwd": .string(root.path),
            "tty": .bool(true),
            "size": .object([
                "rows": .integer(24),
                "cols": .integer(80),
            ]),
            "timeoutMs": .null,
        ],
        root: root,
        executor: executor
    )
    #expect(spawn == processSuccess(id: 1))

    let resize = await processRequest(
        id: 2,
        method: "process/resizePty",
        params: [
            "processHandle": .string("interactive"),
            "size": .object([
                "rows": .integer(40),
                "cols": .integer(120),
            ]),
        ],
        root: root,
        executor: executor
    )
    #expect(resize == processSuccess(id: 2))

    let write = await processRequest(
        id: 3,
        method: "process/writeStdin",
        params: [
            "processHandle": .string("interactive"),
            "deltaBase64":
                .string(Data("hello".utf8).base64EncodedString()),
            "closeStdin": .bool(true),
        ],
        root: root,
        executor: executor
    )
    #expect(write == processSuccess(id: 3))

    try await waitForProcessExit(
        "interactive",
        exits: { exits }
    )
    #expect(outputDeltas.count == 1)
    #expect(outputDeltas.first?.processID == "interactive")
    #expect(outputDeltas.first?.delta == Data("hello".utf8))
    let outputNotification = (
        method: "process/outputDelta",
        params: outputDeltas.first?.processJSON
    )
    let exitNotification = (
        method: "process/exited",
        params: exits.first?.json
    )
    #expect(outputNotification.method == "process/outputDelta")
    #expect(exitNotification.method == "process/exited")
    #expect(
        outputDeltas.first?.processJSON
            == .object([
                "processHandle": .string("interactive"),
                "stream": .string("stdout"),
                "deltaBase64":
                    .string(Data("hello".utf8).base64EncodedString()),
                "capReached": .bool(false),
            ])
    )
    #expect(
        exits.first?.json
            == .object([
                "processHandle": .string("interactive"),
                "exitCode": .integer(0),
                "stdout": .string(""),
                "stdoutCapReached": .bool(false),
                "stderr": .string(""),
                "stderrCapReached": .bool(false),
            ])
    )

    let secondSpawn = await processRequest(
        id: 4,
        method: "process/spawn",
        params: [
            "command": .array([.string("cat")]),
            "processHandle": .string("kill-me"),
            "cwd": .string(root.path),
            "streamStdin": .bool(true),
            "timeoutMs": .null,
        ],
        root: root,
        executor: executor
    )
    #expect(secondSpawn == processSuccess(id: 4))
    let killed = await processRequest(
        id: 5,
        method: "process/kill",
        params: [
            "processHandle": .string("kill-me")
        ],
        root: root,
        executor: executor
    )
    #expect(killed == processSuccess(id: 5))
    try await waitForProcessExit(
        "kill-me",
        exits: { exits }
    )
    #expect(
        exits.first(where: {
            $0.processHandle == "kill-me"
        })?.exitCode == -1
    )
}

@Test
@MainActor
func desktopProcessRunsArbitraryArgvWithEnvironmentCWDAndStreams()
    async throws
{
    #if os(macOS)
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(
            "codex-native-process-\(UUID().uuidString)",
            isDirectory: true
        )
    try FileManager.default.createDirectory(
        at: root,
        withIntermediateDirectories: true
    )
    defer {
        try? FileManager.default.removeItem(at: root)
    }

    var outputDeltas: [CodexDesktopCommandExecOutputDelta] = []
    var exits: [CodexDesktopProcessExited] = []
    let executor = CodexDesktopWorkspaceCommandExecutor(
        processOutputSink: { outputDeltas.append($0) },
        processExitSink: { exits.append($0) }
    )
    let spawn = await processRequest(
        id: 20,
        method: "process/spawn",
        params: [
            "command": .array([
                .string("/bin/sh"),
                .string("-c"),
                .string(
                    #"printf '%s\n' "$CODEX_NATIVE"; pwd; printf 'native-error\n' >&2"#
                ),
            ]),
            "processHandle": .string("native"),
            "cwd": .string(root.path),
            "env": .object([
                "CODEX_NATIVE": .string("native-ready"),
            ]),
            "streamStdoutStderr": .bool(true),
            "timeoutMs": .integer(5_000),
        ],
        root: root,
        executor: executor
    )
    #expect(spawn == processSuccess(id: 20))

    try await waitForProcessExit("native", exits: { exits })
    let stdout = outputDeltas
        .filter { $0.processID == "native" && $0.stream == .stdout }
        .reduce(into: Data()) { $0.append($1.delta) }
    let stderr = outputDeltas
        .filter { $0.processID == "native" && $0.stream == .stderr }
        .reduce(into: Data()) { $0.append($1.delta) }
    let stdoutLines = String(decoding: stdout, as: UTF8.self)
        .split(separator: "\n")
        .map(String.init)
    #expect(stdoutLines.first == "native-ready")
    #expect(stdoutLines.last?.hasSuffix(root.path) == true)
    #expect(String(decoding: stderr, as: UTF8.self) == "native-error\n")
    #expect(
        exits.first(where: { $0.processHandle == "native" })?
            .exitCode == 0
    )
    #endif
}

@Test
@MainActor
func desktopNativeProcessStreamingNeverEmitsPastOutputCap()
    async throws
{
    #if os(macOS)
    let root = FileManager.default.temporaryDirectory
    var outputDeltas: [CodexDesktopCommandExecOutputDelta] = []
    var exits: [CodexDesktopProcessExited] = []
    let executor = CodexDesktopWorkspaceCommandExecutor(
        processOutputSink: { outputDeltas.append($0) },
        processExitSink: { exits.append($0) }
    )
    let spawn = await processRequest(
        id: 21,
        method: "process/spawn",
        params: [
            "command": .array([
                .string("/usr/bin/printf"),
                .string("abcdefghij"),
            ]),
            "processHandle": .string("native-capped"),
            "cwd": .string(root.path),
            "streamStdoutStderr": .bool(true),
            "outputBytesCap": .integer(5),
            "timeoutMs": .integer(5_000),
        ],
        root: root,
        executor: executor
    )
    #expect(spawn == processSuccess(id: 21))

    try await waitForProcessExit("native-capped", exits: { exits })
    let deltas = outputDeltas.filter {
        $0.processID == "native-capped" && $0.stream == .stdout
    }
    let output = deltas.reduce(into: Data()) {
        $0.append($1.delta)
    }
    #expect(String(decoding: output, as: UTF8.self) == "abcde")
    #expect(deltas.last?.capReached == true)
    #endif
}

@MainActor
private func waitForProcessExit(
    _ handle: String,
    exits: @escaping @MainActor () -> [CodexDesktopProcessExited]
) async throws {
    for _ in 0..<100 {
        if exits().contains(where: {
            $0.processHandle == handle
        }) {
            return
        }
        try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("missing process/exited for \(handle)")
}

@MainActor
private func processRequest(
    id: Int64,
    method: String,
    params: [String: CodexJSONValue],
    root: URL,
    executor: CodexDesktopWorkspaceCommandExecutor
) async -> CodexDesktopHostMessage {
    await CodexDesktopInitialMCPRouter
        .responseIncludingFileSystem(
            to: CodexDesktopMCPRequest(
                request: .init(
                    id: .integer(id),
                    method: method,
                    params: .object(params),
                    metadata: [:]
                ),
                hostID: "desktop-host-1",
                dispatchedAtMs: nil,
                priority: nil,
                source: nil,
                timeoutMs: nil,
                expiresAtMs: nil,
                metadata: [:]
            ),
            state: .init(
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
                    serverName: "Codex for ipad",
                    installationID: "installation-1",
                    environmentID: nil
                )
            ),
            allowedFileSystemRoots: [root.path],
            commandExecutor: executor
        )
}

private func processSuccess(
    id: Int64
) -> CodexDesktopHostMessage {
    .mcpResponse(
        hostID: "desktop-host-1",
        message: .object([
            "id": .integer(id),
            "result": .object([:]),
        ]),
        metadata: [:]
    )
}
