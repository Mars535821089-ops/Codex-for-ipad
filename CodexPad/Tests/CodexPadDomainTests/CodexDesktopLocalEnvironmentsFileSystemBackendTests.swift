import CryptoKit
import Foundation
import Testing

@testable import CodexPadApplication

private typealias LocalEnvironmentFSValue =
    CodexDesktopAppHostRPC.Value

@Test
func desktopLocalEnvironmentFileSystemListsAndReadsRealConfigs()
    async throws
{
    let fixture = try LocalEnvironmentFileSystemFixture()
    defer { fixture.remove() }

    let nestedWorkspace = fixture.root
        .appendingPathComponent("Packages/App", isDirectory: true)
    try FileManager.default.createDirectory(
        at: nestedWorkspace,
        withIntermediateDirectories: true
    )
    let inheritedPath = try fixture.write(
        raw: inheritedEnvironmentRaw,
        projectRoot: fixture.root,
        name: "environment.toml"
    )
    let projectPath = try fixture.write(
        raw: projectEnvironmentRaw,
        projectRoot: nestedWorkspace,
        name: "project.toml"
    )
    let invalidPath = try fixture.write(
        raw: "version = 1\nname = \"Broken\"\n",
        projectRoot: nestedWorkspace,
        name: "broken.toml"
    )

    let backend =
        CodexDesktopLocalEnvironmentsFileSystemBackend(
            authorizedWorkspaceRoots: [fixture.root]
        )
    let service = CodexDesktopLocalEnvironmentsAppHostService(
        hostProvider: backend.hostProvider,
        fileSystemHandler: backend.fileSystemHandler
    )

    #expect(
        try await backend.hostProvider("local")
            == .init(id: "local")
    )
    #expect(try await backend.hostProvider("remote") == nil)

    let listed = try await service.invoke(
        service: "localEnvironments",
        method: "list",
        arguments: [
            .object([
                "hostId": .string("local"),
                "workspaceRoot": .string(nestedWorkspace.path),
            ]),
        ]
    )
    #expect(
        listed == .object([
            "environments": .array([
                successfulEnvironment(
                    configPath: inheritedPath.path,
                    cwdRelativeToGitRoot: ".",
                    environment: inheritedEnvironmentValue
                ),
                invalidEnvironment(configPath: invalidPath.path),
                successfulEnvironment(
                    configPath: projectPath.path,
                    cwdRelativeToGitRoot: "Packages/App",
                    environment: projectEnvironmentValue
                ),
            ])
        ])
    )

    let read = try await service.invoke(
        service: "localEnvironments",
        method: "read",
        arguments: [
            .object([
                "configPath": .string(projectPath.path),
                "hostId": .string("local"),
            ]),
        ]
    )
    #expect(
        read == .object([
            "environment": .object([
                "environment": successfulEnvironment(
                    configPath: projectPath.path,
                    cwdRelativeToGitRoot: "Packages/App",
                    environment: projectEnvironmentValue
                ),
                "exists": .bool(true),
                "raw": .string(projectEnvironmentRaw),
                "revision": .string(revision(projectEnvironmentRaw)),
            ])
        ])
    )

    let missingPath = nestedWorkspace
        .appendingPathComponent(
            ".codex/environments/missing.toml"
        )
    let missing = try await service.invoke(
        service: "localEnvironments",
        method: "read",
        arguments: [
            .object([
                "configPath": .string(missingPath.path),
                "hostId": .string("local"),
            ]),
        ]
    )
    #expect(
        missing == .object([
            "environment": .object([
                "environment": .null,
                "exists": .bool(false),
                "raw": .null,
                "revision": .null,
            ])
        ])
    )
}

@Test
func desktopLocalEnvironmentFileSystemReadsReleasedMultilineBasicString()
    async throws
{
    let fixture = try LocalEnvironmentFileSystemFixture()
    defer { fixture.remove() }
    let raw = #"""
        version = 1
        name = "Quoted"

        [setup]
        script = """echo '''marker'''
        echo \"""quoted\""""""
        """#
    let configPath = try fixture.write(
        raw: raw,
        projectRoot: fixture.root,
        name: "quoted.toml"
    )
    let backend =
        CodexDesktopLocalEnvironmentsFileSystemBackend(
            authorizedWorkspaceRoots: [fixture.root]
        )

    let result = try await backend.fileSystemHandler(
        .init(id: "local"),
        .read(configPath: configPath.path)
    )
    #expect(
        result == .object([
            "environment": successfulEnvironment(
                configPath: configPath.path,
                cwdRelativeToGitRoot: ".",
                environment: .object([
                    "name": .string("Quoted"),
                    "setup": .object([
                        "script": .string(
                            "echo '''marker'''\necho \"\"\"quoted\"\"\""
                        )
                    ]),
                    "version": .integer(1),
                ])
            ),
            "exists": .bool(true),
            "raw": .string(raw),
            "revision": .string(revision(raw)),
        ])
    )
}

@Test
func desktopLocalEnvironmentFileSystemSavesAtomicallyWithRevisionCAS()
    async throws
{
    let fixture = try LocalEnvironmentFileSystemFixture()
    defer { fixture.remove() }
    let configPath = fixture.root
        .appendingPathComponent(".codex/environments")
        .appendingPathComponent("environment.toml")
    let backend =
        CodexDesktopLocalEnvironmentsFileSystemBackend(
            authorizedWorkspaceRoots: [fixture.root]
        )
    let handler = backend.fileSystemHandler
    let host = CodexDesktopLocalEnvironmentsAppHostService.Host(
        id: "local"
    )

    #expect(
        try await handler(
            host,
            .saveConfig(
                configPath: configPath.path,
                expectedRevision: nil,
                raw: inheritedEnvironmentRaw
            )
        ) == .object(["type": .string("success")])
    )
    #expect(
        try String(contentsOf: configPath, encoding: .utf8)
            == inheritedEnvironmentRaw
    )

    #expect(
        try await handler(
            host,
            .saveConfig(
                configPath: configPath.path,
                expectedRevision: nil,
                raw: projectEnvironmentRaw
            )
        ) == .object(["type": .string("conflict")])
    )
    #expect(
        try String(contentsOf: configPath, encoding: .utf8)
            == inheritedEnvironmentRaw
    )

    let expectedRevision = revision(inheritedEnvironmentRaw)
    async let first = handler(
        host,
        .saveConfig(
            configPath: configPath.path,
            expectedRevision: expectedRevision,
            raw: projectEnvironmentRaw
        )
    )
    async let second = handler(
        host,
        .saveConfig(
            configPath: configPath.path,
            expectedRevision: expectedRevision,
            raw: alternateEnvironmentRaw
        )
    )
    let concurrentResults = try await [first, second]
    #expect(
        concurrentResults.filter {
            $0 == .object(["type": .string("success")])
        }.count == 1
    )
    #expect(
        concurrentResults.filter {
            $0 == .object(["type": .string("conflict")])
        }.count == 1
    )
    let finalRaw = try String(
        contentsOf: configPath,
        encoding: .utf8
    )
    #expect(
        finalRaw == projectEnvironmentRaw
            || finalRaw == alternateEnvironmentRaw
    )
    let directoryEntries = try FileManager.default.contentsOfDirectory(
        atPath: configPath.deletingLastPathComponent().path
    )
    #expect(directoryEntries == ["environment.toml"])
}

@Test
func desktopLocalEnvironmentFileSystemConfinesEveryOperationToRoots()
    async throws
{
    let fixture = try LocalEnvironmentFileSystemFixture()
    defer { fixture.remove() }
    let outside = try LocalEnvironmentFileSystemFixture()
    defer { outside.remove() }

    let backend =
        CodexDesktopLocalEnvironmentsFileSystemBackend(
            authorizedWorkspaceRoots: [fixture.root]
        )
    let handler = backend.fileSystemHandler
    let host = CodexDesktopLocalEnvironmentsAppHostService.Host(
        id: "local"
    )
    let outsideConfig = outside.root
        .appendingPathComponent(".codex/environments/environment.toml")

    await #expect(
        throws:
            CodexDesktopLocalEnvironmentsFileSystemBackend.Error
                .unauthorizedPath(outside.root.path)
    ) {
        _ = try await handler(
            host,
            .list(workspaceRoot: outside.root.path)
        )
    }
    await #expect(
        throws:
            CodexDesktopLocalEnvironmentsFileSystemBackend.Error
                .unauthorizedPath(outsideConfig.path)
    ) {
        _ = try await handler(
            host,
            .read(configPath: outsideConfig.path)
        )
    }
    await #expect(
        throws:
            CodexDesktopLocalEnvironmentsFileSystemBackend.Error
                .unauthorizedPath(outsideConfig.path)
    ) {
        _ = try await handler(
            host,
            .saveConfig(
                configPath: outsideConfig.path,
                expectedRevision: nil,
                raw: inheritedEnvironmentRaw
            )
        )
    }
    await #expect(
        throws:
            CodexDesktopLocalEnvironmentsFileSystemBackend.Error
                .invalidHost("remote")
    ) {
        _ = try await handler(
            .init(id: "remote"),
            .list(workspaceRoot: fixture.root.path)
        )
    }

    let link = fixture.root.appendingPathComponent(
        "linked",
        isDirectory: true
    )
    try FileManager.default.createSymbolicLink(
        at: link,
        withDestinationURL: outside.root
    )
    await #expect(
        throws:
            CodexDesktopLocalEnvironmentsFileSystemBackend.Error
                .unauthorizedPath(link.path)
    ) {
        _ = try await handler(
            host,
            .list(workspaceRoot: link.path)
        )
    }

    let linkedConfig = link
        .appendingPathComponent(
            ".codex/environments/environment.toml"
        )
    await #expect(
        throws:
            CodexDesktopLocalEnvironmentsFileSystemBackend.Error
                .unauthorizedPath(linkedConfig.path)
    ) {
        _ = try await handler(
            host,
            .saveConfig(
                configPath: linkedConfig.path,
                expectedRevision: nil,
                raw: inheritedEnvironmentRaw
            )
        )
    }
}

private struct LocalEnvironmentFileSystemFixture {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "CodexDesktopLocalEnvironments-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
    }

    func write(
        raw: String,
        projectRoot: URL,
        name: String
    ) throws -> URL {
        let directory = projectRoot
            .appendingPathComponent(
                ".codex/environments",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let url = directory.appendingPathComponent(name)
        try Data(raw.utf8).write(to: url, options: .atomic)
        return url
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

private let inheritedEnvironmentRaw = """
    # THIS IS AUTOGENERATED. DO NOT EDIT MANUALLY
    version = 1
    name = "Inherited"

    [setup]
    script = '''
    swift package resolve
    swift build'''

    [setup.darwin]
    script = "swift build --target App"
    """

private let projectEnvironmentRaw = """
    # THIS IS AUTOGENERATED. DO NOT EDIT MANUALLY
    version = 1
    name = "iPad"

    [setup]
    script = "swift package resolve"

    [cleanup]
    script = "rm -rf .build"

    [[actions]]
    name = "Test"
    icon = "test"
    command = "swift test"
    platform = "darwin"
    """

private let alternateEnvironmentRaw = """
    version = 1
    name = "Alternate"

    [setup]
    script = "swift build"
    """

private let inheritedEnvironmentValue =
    LocalEnvironmentFSValue.object([
        "name": .string("Inherited"),
        "setup": .object([
            "darwin": .object([
                "script": .string("swift build --target App")
            ]),
            "script": .string(
                "swift package resolve\nswift build"
            ),
        ]),
        "version": .integer(1),
    ])

private let projectEnvironmentValue =
    LocalEnvironmentFSValue.object([
        "actions": .array([
            .object([
                "command": .string("swift test"),
                "icon": .string("test"),
                "name": .string("Test"),
                "platform": .string("darwin"),
            ])
        ]),
        "cleanup": .object([
            "script": .string("rm -rf .build")
        ]),
        "name": .string("iPad"),
        "setup": .object([
            "script": .string("swift package resolve")
        ]),
        "version": .integer(1),
    ])

private func successfulEnvironment(
    configPath: String,
    cwdRelativeToGitRoot: String,
    environment: LocalEnvironmentFSValue
) -> LocalEnvironmentFSValue {
    .object([
        "configPath": .string(configPath),
        "cwdRelativeToGitRoot": .string(cwdRelativeToGitRoot),
        "environment": environment,
        "type": .string("success"),
    ])
}

private func invalidEnvironment(
    configPath: String
) -> LocalEnvironmentFSValue {
    .object([
        "configPath": .string(configPath),
        "cwdRelativeToGitRoot": .string(configPath),
        "error": .object([
            "message": .string("Invalid local environment TOML")
        ]),
        "type": .string("error"),
    ])
}

private func revision(_ raw: String) -> String {
    let digest = SHA256.hash(data: Data(raw.utf8))
    return "sha256:" + digest.map {
        String(format: "%02x", $0)
    }.joined()
}
