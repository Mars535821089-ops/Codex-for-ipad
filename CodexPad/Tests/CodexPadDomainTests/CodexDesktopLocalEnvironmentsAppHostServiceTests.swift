import Testing

@testable import CodexPadApplication

private typealias LocalEnvironmentValue =
    CodexDesktopAppHostRPC.Value

@Test
func desktopLocalEnvironmentsRoutesListThroughResolvedHost()
    async throws
{
    let recorder = LocalEnvironmentFileSystemRecorder()
    let service = CodexDesktopLocalEnvironmentsAppHostService(
        hostProvider: { hostID in
            .init(id: hostID)
        },
        fileSystemHandler: { host, operation in
            await recorder.record(host: host, operation: operation)
            return .array([releasedEnvironment()])
        }
    )

    let result = try await service.invoke(
        service: "localEnvironments",
        method: "list",
        arguments: [
            .object([
                "hostId": .string("local"),
                "workspaceRoot": .string("/workspace/project"),
            ]),
        ]
    )

    #expect(
        result == .object([
            "environments": .array([releasedEnvironment()])
        ])
    )
    #expect(
        await recorder.hosts
            == [
                CodexDesktopLocalEnvironmentsAppHostService.Host(
                    id: "local"
                ),
            ]
    )
    #expect(
        await recorder.operations
            == [
                .list(workspaceRoot: "/workspace/project"),
            ]
    )
}

@Test
func desktopLocalEnvironmentsReadsRevisionedConfigThroughHandler()
    async throws
{
    let recorder = LocalEnvironmentFileSystemRecorder()
    let raw = """
        version = 1
        name = "iPad"
        [setup]
        script = "setup"

        """
    let configPath =
        "/workspace/project/.codex/environments/environment.toml"
    let revision =
        "sha256:adc3785c90053c51c2542358d27bc5d4d20469638ad1dc8a160c315843c64e5e"
    let readState = LocalEnvironmentValue.object([
        "environment": releasedEnvironment(
            configPath: configPath
        ),
        "exists": .bool(true),
        "raw": .string(raw),
        "revision": .string(revision),
    ])
    let service = CodexDesktopLocalEnvironmentsAppHostService(
        hostProvider: { .init(id: $0) },
        fileSystemHandler: { host, operation in
            await recorder.record(host: host, operation: operation)
            return readState
        }
    )

    #expect(
        try await service.invoke(
            service: "localEnvironments",
            method: "read",
            arguments: [
                .object([
                    "configPath": .string(configPath),
                    "hostId": .string("local"),
                ]),
            ]
        ) == .object(["environment": readState])
    )
    #expect(
        await recorder.operations
            == [.read(configPath: configPath)]
    )
}

@Test
func desktopLocalEnvironmentsSavesWithRevisionAndReturnsConflict()
    async throws
{
    let recorder = LocalEnvironmentFileSystemRecorder()
    let configPath =
        "/workspace/project/.codex/environments/environment.toml"
    let revision =
        "sha256:adc3785c90053c51c2542358d27bc5d4d20469638ad1dc8a160c315843c64e5e"
    let service = CodexDesktopLocalEnvironmentsAppHostService(
        hostProvider: { .init(id: $0) },
        fileSystemHandler: { host, operation in
            await recorder.record(host: host, operation: operation)
            guard case let .saveConfig(_, _, raw) = operation else {
                return .undefined
            }
            return .object([
                "type": .string(
                    raw == "updated" ? "success" : "conflict"
                )
            ])
        }
    )

    #expect(
        try await service.invoke(
            service: "localEnvironments",
            method: "saveConfig",
            arguments: [
                .object([
                    "configPath": .string(configPath),
                    "expectedRevision": .string(revision),
                    "hostId": .string("local"),
                    "raw": .string("updated"),
                ]),
            ]
        ) == .object([
            "configPath": .string(configPath),
            "type": .string("success"),
        ])
    )
    #expect(
        try await service.invoke(
            service: "localEnvironments",
            method: "saveConfig",
            arguments: [
                .object([
                    "configPath": .string(configPath),
                    "expectedRevision": .null,
                    "hostId": .string("local"),
                    "raw": .string("stale"),
                ]),
            ]
        ) == .object([
            "configPath": .string(configPath),
            "type": .string("conflict"),
        ])
    )
    #expect(
        await recorder.operations
            == [
                .saveConfig(
                    configPath: configPath,
                    expectedRevision: revision,
                    raw: "updated"
                ),
                .saveConfig(
                    configPath: configPath,
                    expectedRevision: nil,
                    raw: "stale"
                ),
            ]
    )
}

@Test
func desktopLocalEnvironmentsIsHonestlyUnavailableWithoutHandlers()
    async
{
    let service = CodexDesktopLocalEnvironmentsAppHostService()

    await #expect(
        throws:
            CodexDesktopLocalEnvironmentsAppHostService.Error
                .unavailable(
                    service: "localEnvironments",
                    method: "list"
                )
    ) {
        _ = try await service.invoke(
            service: "localEnvironments",
            method: "list",
            arguments: [
                .object([
                    "hostId": .string("local"),
                    "workspaceRoot": .string("/workspace"),
                ]),
            ]
        )
    }
}

@Test
func desktopLocalEnvironmentsRejectsRelativePathsAndBadRevision()
    async
{
    let service = CodexDesktopLocalEnvironmentsAppHostService(
        hostProvider: { .init(id: $0) },
        fileSystemHandler: { _, _ in .undefined }
    )

    await #expect(
        throws:
            CodexDesktopLocalEnvironmentsAppHostService.Error
                .invalidPath
    ) {
        _ = try await service.invoke(
            service: "localEnvironments",
            method: "list",
            arguments: [
                .object([
                    "hostId": .string("local"),
                    "workspaceRoot": .string("relative/project"),
                ]),
            ]
        )
    }
    await #expect(
        throws:
            CodexDesktopLocalEnvironmentsAppHostService.Error
                .invalidArguments
    ) {
        _ = try await service.invoke(
            service: "localEnvironments",
            method: "saveConfig",
            arguments: [
                .object([
                    "configPath": .string(
                        "/workspace/.codex/environments/environment.toml"
                    ),
                    "expectedRevision": .string("sha256:NOT-A-HASH"),
                    "hostId": .string("local"),
                    "raw": .string("version = 1"),
                ]),
            ]
        )
    }
}

@Test
func desktopLocalEnvironmentsRejectsInvalidVersionAndForgedReadRevision()
    async
{
    let configPath =
        "/workspace/.codex/environments/environment.toml"
    let malformedEnvironment = LocalEnvironmentValue.object([
        "configPath": .string(configPath),
        "cwdRelativeToGitRoot": .string("."),
        "environment": .object([
            "name": .string("Invalid"),
            "setup": .object(["script": .string("")]),
            "version": .integer(0),
        ]),
        "type": .string("success"),
    ])
    let listService =
        CodexDesktopLocalEnvironmentsAppHostService(
            hostProvider: { .init(id: $0) },
            fileSystemHandler: { _, _ in
                .array([malformedEnvironment])
            }
        )

    await #expect(
        throws:
            CodexDesktopLocalEnvironmentsAppHostService.Error
                .invalidResponse
    ) {
        _ = try await listService.invoke(
            service: "localEnvironments",
            method: "list",
            arguments: [
                .object([
                    "hostId": .string("local"),
                    "workspaceRoot": .string("/workspace"),
                ]),
            ]
        )
    }

    let readService =
        CodexDesktopLocalEnvironmentsAppHostService(
            hostProvider: { .init(id: $0) },
            fileSystemHandler: { _, _ in
                .object([
                    "environment": releasedEnvironment(
                        configPath: configPath
                    ),
                    "exists": .bool(true),
                    "raw": .string("version = 1"),
                    "revision": .string(
                        "sha256:0000000000000000000000000000000000000000000000000000000000000000"
                    ),
                ])
            }
        )

    await #expect(
        throws:
            CodexDesktopLocalEnvironmentsAppHostService.Error
                .invalidResponse
    ) {
        _ = try await readService.invoke(
            service: "localEnvironments",
            method: "read",
            arguments: [
                .object([
                    "configPath": .string(configPath),
                    "hostId": .string("local"),
                ]),
            ]
        )
    }
}

private func releasedEnvironment(
    configPath: String =
        "/workspace/project/.codex/environments/environment.toml"
) -> LocalEnvironmentValue {
    .object([
        "configPath": .string(configPath),
        "cwdRelativeToGitRoot": .string("."),
        "environment": .object([
            "actions": .array([
                .object([
                    "command": .string("swift test"),
                    "icon": .string("test"),
                    "name": .string("Test"),
                    "platform": .string("darwin"),
                ]),
            ]),
            "name": .string("iPad"),
            "setup": .object([
                "darwin": .object([
                    "script": .string("setup-darwin")
                ]),
                "script": .string("setup"),
            ]),
            "version": .integer(1),
        ]),
        "type": .string("success"),
    ])
}

private actor LocalEnvironmentFileSystemRecorder {
    private(set) var hosts:
        [CodexDesktopLocalEnvironmentsAppHostService.Host] = []
    private(set) var operations:
        [CodexDesktopLocalEnvironmentsAppHostService.FileSystemOperation] =
            []

    func record(
        host: CodexDesktopLocalEnvironmentsAppHostService.Host,
        operation:
            CodexDesktopLocalEnvironmentsAppHostService.FileSystemOperation
    ) {
        hosts.append(host)
        operations.append(operation)
    }
}
