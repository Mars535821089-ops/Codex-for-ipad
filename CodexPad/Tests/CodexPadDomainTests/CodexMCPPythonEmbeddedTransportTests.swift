import Foundation
import Testing

@testable import CodexPadApplication

@Test
func embeddedPythonInvocationParsesModuleAndCommandModes() throws {
    let module = try CodexMCPPythonInvocation(
        arguments: [
            "-u",
            "-B",
            "-m",
            "mcp_server_time",
            "--stdio",
        ],
        cwd: "/workspace"
    )
    #expect(module.runKind == .module)
    #expect(module.target == "mcp_server_time")
    #expect(module.displayName == "python -m mcp_server_time")
    #expect(module.argv == ["mcp_server_time", "--stdio"])

    let command = try CodexMCPPythonInvocation(
        arguments: [
            "-Bu",
            "-c",
            "print('ready')",
            "fixture",
        ],
        cwd: nil
    )
    #expect(command.runKind == .command)
    #expect(command.target == "print('ready')")
    #expect(command.displayName == "python -c")
    #expect(command.argv == ["-c", "fixture"])
}

@Test
func embeddedPythonInvocationResolvesScriptAgainstWorkingDirectory()
    throws
{
    let invocation = try CodexMCPPythonInvocation(
        arguments: [
            "--",
            "servers/time_server.py",
            "--stdio",
        ],
        cwd: "/workspace/project"
    )

    #expect(invocation.runKind == .path)
    #expect(
        invocation.target
            == "/workspace/project/servers/time_server.py"
    )
    #expect(
        invocation.argv
            == [
                "/workspace/project/servers/time_server.py",
                "--stdio",
            ]
    )
}

@Test
func embeddedPythonInvocationBuildsVendoredEntrypoint() throws {
    let invocation = try CodexMCPPythonInvocation(
        entrypoint: "mcp_server_time:main",
        consoleScript: "mcp-server-time",
        arguments: ["--local-timezone", "Asia/Shanghai"]
    )

    #expect(invocation.runKind == .entrypoint)
    #expect(invocation.target == "mcp_server_time:main")
    #expect(invocation.displayName == "mcp-server-time")
    #expect(
        invocation.argv
            == [
                "mcp-server-time",
                "--local-timezone",
                "Asia/Shanghai",
            ]
    )
}

@Test
func embeddedPythonInvocationRejectsIncompleteOrUnsupportedCLI() {
    #expect(
        throws: CodexMCPPythonInvocationError.missingOptionValue("-m")
    ) {
        try CodexMCPPythonInvocation(
            arguments: ["-m"],
            cwd: nil
        )
    }
    #expect(
        throws:
            CodexMCPPythonInvocationError
                .unsupportedInterpreterOption("-I")
    ) {
        try CodexMCPPythonInvocation(
            arguments: ["-I", "server.py"],
            cwd: nil
        )
    }
}

@Test
func embeddedPythonResourcesValidateRuntimeAndSnapshotLayout()
    throws
{
    let fixture = try PythonBundleFixture()
    defer { fixture.remove() }

    let resources = try CodexMCPPythonRuntimeResources(
        validating: fixture.root
    )

    #expect(resources.pythonHome == fixture.root.appendingPathComponent(
        "python",
        isDirectory: true
    ))
    #expect(
        resources.moduleSearchPaths
            == [
                fixture.root.appendingPathComponent(
                    "python/lib/python3.13",
                    isDirectory: true
                ),
                fixture.root.appendingPathComponent(
                    "python/lib/python3.13/lib-dynload",
                    isDirectory: true
                ),
                fixture.root.appendingPathComponent(
                    "PythonPackages/site-packages",
                    isDirectory: true
                ),
            ]
    )
    #expect(
        resources.uvxRegistryEntries["mcp-server-time"]
            == "mcp_server_time"
    )
}

@Test
func embeddedPythonResourcesRejectMissingEntrypoint() throws {
    let fixture = try PythonBundleFixture(
        includeEntrypoint: false
    )
    defer { fixture.remove() }

    #expect(
        throws:
            CodexMCPPythonRuntimeResourceError
                .entrypointMissing("mcp_server_time")
    ) {
        try CodexMCPPythonRuntimeResources(
            validating: fixture.root
        )
    }
}

@Test
func embeddedPythonSessionOutputPreservesStdoutAndExitDiagnostic()
    async throws
{
    let output = CodexMCPPythonSessionOutput()
    let stdout = Data("{\"jsonrpc\":\"2.0\"}\n".utf8)

    await output.receiveStdout(stdout)
    #expect(try await output.next() == stdout)

    await output.receiveStderr(
        Data("fixture stderr".utf8)
    )
    await output.finish(
        exitCode: 7,
        runtimeError: "runtime fixture"
    )
    await #expect(
        throws:
            CodexMCPStdioError.processExitedWithStderr(
                code: 7,
                stderr: "fixture stderr\nruntime fixture"
            )
    ) {
        try await output.next()
    }
}

@Test
func embeddedPythonSessionOutputHonorsWaitingReadCancellation()
    async throws
{
    let output = CodexMCPPythonSessionOutput()
    let waitingRead = Task {
        try await output.next()
    }
    try await Task.sleep(for: .milliseconds(10))

    waitingRead.cancel()
    try await Task.sleep(for: .milliseconds(10))
    let subsequent = Data("next\n".utf8)
    await output.receiveStdout(subsequent)

    await #expect(throws: CancellationError.self) {
        try await waitingRead.value
    }
    #expect(try await output.next() == subsequent)
}

private struct PythonBundleFixture {
    let root: URL

    init(includeEntrypoint: Bool = true) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "codex-python-transport-\(UUID().uuidString)",
                isDirectory: true
            )
        let standardLibrary = root.appendingPathComponent(
            "python/lib/python3.13",
            isDirectory: true
        )
        let dynamicLibraries = standardLibrary
            .appendingPathComponent(
                "lib-dynload",
                isDirectory: true
            )
        let packages = root.appendingPathComponent(
            "PythonPackages/site-packages",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: dynamicLibraries,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: packages,
            withIntermediateDirectories: true
        )
        try Data().write(
            to: standardLibrary.appendingPathComponent(
                "os.py"
            )
        )
        if includeEntrypoint {
            let package = packages.appendingPathComponent(
                "mcp_server_time",
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: package,
                withIntermediateDirectories: true
            )
            try Data("def main(): pass\n".utf8).write(
                to: package.appendingPathComponent("__init__.py")
            )
        }
        try runtimeLock.write(
            to: root.appendingPathComponent(
                "PythonPackages/runtime-lock.json"
            )
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    private var runtimeLock: Data {
        Data(
            """
            {
              "schemaVersion": 1,
              "runtime": {
                "name": "CPython",
                "version": "3.13.14",
                "abi": "cp313",
                "sourceTag": "3.13-b14",
                "sourceCommit": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
              },
              "requirementsLockSha256": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
              "tree": {
                "sha256": "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
                "fileCount": 1,
                "totalBytes": 1
              },
              "packages": [
                {
                  "name": "mcp-server-time",
                  "version": "0.6.2",
                  "entrypoint": "mcp_server_time",
                  "consoleScript": "mcp-server-time"
                }
              ]
            }
            """.utf8
        )
    }
}
