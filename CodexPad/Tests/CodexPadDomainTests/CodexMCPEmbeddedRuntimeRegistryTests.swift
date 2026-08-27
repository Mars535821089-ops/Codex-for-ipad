import Foundation
import Testing

@testable import CodexPadApplication

@Test
func embeddedMCPRuntimeRoutesOnlyPhysicallyBundledIOSSystemCommands() {
    let registry = CodexMCPEmbeddedRuntimeRegistry()

    #expect(
        CodexMCPEmbeddedRuntimeRegistry.iosSystemCommands.count == 58
    )
    #expect(
        registry.resolve(command: "cat", arguments: ["README.md"])
            == .available(
                .iosSystem(
                    command: "cat",
                    arguments: ["README.md"]
                )
            )
    )
    #expect(
        registry.resolve(command: "/bin/grep", arguments: ["Codex"])
            == .available(
                .iosSystem(
                    command: "grep",
                    arguments: ["Codex"]
                )
            )
    )
    #expect(
        registry.resolve(command: "ssh", arguments: ["HOST"])
            == .unavailable(
                .init(
                    command: "ssh",
                    reason: .unsupportedCommand
                )
            )
    )
}

@Test
func embeddedMCPRuntimeReportsMissingInterpreterBeforeLaunch() {
    let registry = CodexMCPEmbeddedRuntimeRegistry()

    #expect(
        registry.resolve(command: "node", arguments: ["server.js"])
            == .unavailable(
                .init(
                    command: "node",
                    reason: .runtimeMissing(.node)
                )
            )
    )
    #expect(
        registry.resolve(command: "python3", arguments: ["server.py"])
            == .unavailable(
                .init(
                    command: "python3",
                    reason: .runtimeMissing(.python)
                )
            )
    )
}

@Test
func embeddedMCPRuntimeRoutesNodeAndPythonWhenBundled() {
    let registry = CodexMCPEmbeddedRuntimeRegistry(
        nodeAvailable: true,
        pythonAvailable: true
    )

    #expect(
        registry.resolve(
            command: "/usr/local/bin/node",
            arguments: ["server.js", "--stdio"]
        )
            == .available(
                .node(arguments: ["server.js", "--stdio"])
            )
    )
    #expect(
        registry.resolve(
            command: "python",
            arguments: ["server.py", "--stdio"]
        )
            == .available(
                .python(arguments: ["server.py", "--stdio"])
            )
    )
}

@Test
func embeddedMCPRuntimeMapsNpxToVersionedVendoredSnapshot() {
    let registry = CodexMCPEmbeddedRuntimeRegistry(
        nodeAvailable: true,
        npxPackages: [
            "@modelcontextprotocol/server-filesystem":
                "MCPPackages/server-filesystem/index.js",
            "@modelcontextprotocol/server-filesystem@2026.7.10":
                "MCPPackages/server-filesystem/index.js",
            "@modelcontextprotocol/server-filesystem@latest":
                "MCPPackages/server-filesystem/index.js",
        ]
    )

    #expect(
        registry.resolve(
            command: "npx",
            arguments: [
                "-y",
                "@modelcontextprotocol/server-filesystem",
                "/workspace",
            ]
        )
            == .available(
                .vendoredNodePackage(
                    package:
                        "@modelcontextprotocol/server-filesystem",
                    entrypoint:
                        "MCPPackages/server-filesystem/index.js",
                    arguments: ["/workspace"]
                )
            )
    )
    #expect(
        registry.resolve(
            command: "npx",
            arguments: [
                "-y",
                "@modelcontextprotocol/server-filesystem@2026.7.10",
                "/workspace",
            ]
        )
            == .available(
                .vendoredNodePackage(
                    package:
                        "@modelcontextprotocol/server-filesystem",
                    entrypoint:
                        "MCPPackages/server-filesystem/index.js",
                    arguments: ["/workspace"]
                )
            )
    )
    #expect(
        registry.resolve(
            command: "npx",
            arguments: [
                "-y",
                "@modelcontextprotocol/server-filesystem@latest",
                "/workspace",
            ]
        )
            == .available(
                .vendoredNodePackage(
                    package:
                        "@modelcontextprotocol/server-filesystem",
                    entrypoint:
                        "MCPPackages/server-filesystem/index.js",
                    arguments: ["/workspace"]
                )
            )
    )
    #expect(
        registry.resolve(
            command: "npx",
            arguments: [
                "-y",
                "@modelcontextprotocol/server-filesystem@2025.1.1",
            ]
        )
            == .unavailable(
                .init(
                    command: "npx",
                    reason: .packageSnapshotMissing(
                        "@modelcontextprotocol/server-filesystem@2025.1.1"
                    )
                )
            )
    )
    #expect(
        registry.resolve(
            command: "npx",
            arguments: ["-y", "@fixture/missing"]
        )
            == .unavailable(
                .init(
                    command: "npx",
                    reason: .packageSnapshotMissing(
                        "@fixture/missing"
                    )
                )
            )
    )
}

@Test
func embeddedMCPRuntimeMapsUvxToVersionedVendoredSnapshot() {
    let registry = CodexMCPEmbeddedRuntimeRegistry(
        pythonAvailable: true,
        uvxPackages: [
            "fixture-server": "MCPPackages/fixture_server/__main__.py",
        ]
    )

    #expect(
        registry.resolve(
            command: "uvx",
            arguments: ["fixture-server", "--stdio"]
        )
            == .available(
                .vendoredPythonPackage(
                    package: "fixture-server",
                    entrypoint:
                        "MCPPackages/fixture_server/__main__.py",
                    consoleScript: nil,
                    arguments: ["--stdio"]
                )
            )
    )
    #expect(
        registry.resolve(command: "uvx", arguments: [])
            == .unavailable(
                .init(
                    command: "uvx",
                    reason: .packageSpecifierMissing
                )
            )
    )
}

@Test
func embeddedMCPRuntimeParsesUvxOptionsAndExplicitFromPackage() {
    let registry = CodexMCPEmbeddedRuntimeRegistry(
        pythonAvailable: true,
        uvxPackages: [
            "fixture-server":
                "MCPPackages/fixture_server/__main__.py",
        ]
    )

    #expect(
        registry.resolve(
            command: "uvx",
            arguments: [
                "--python",
                "3.13",
                "--isolated",
                "fixture-server",
                "--stdio",
            ]
        )
            == .available(
                .vendoredPythonPackage(
                    package: "fixture-server",
                    entrypoint:
                        "MCPPackages/fixture_server/__main__.py",
                    consoleScript: nil,
                    arguments: ["--stdio"]
                )
            )
    )
    #expect(
        registry.resolve(
            command: "uvx",
            arguments: [
                "--from=fixture-server",
                "fixture-command",
                "--stdio",
            ]
        )
            == .available(
                .vendoredPythonPackage(
                    package: "fixture-server",
                    entrypoint:
                        "MCPPackages/fixture_server/__main__.py",
                    consoleScript: "fixture-command",
                    arguments: ["--stdio"]
                )
            )
    )
}

@Test
func embeddedMCPRuntimeParsesUvToolRunAlias() {
    let registry = CodexMCPEmbeddedRuntimeRegistry(
        pythonAvailable: true,
        uvxPackages: [
            "fixture-server":
                "MCPPackages/fixture_server/__main__.py",
        ]
    )

    #expect(
        registry.resolve(
            command: "uv",
            arguments: [
                "--offline",
                "tool",
                "run",
                "--from",
                "fixture-server",
                "fixture-command",
                "--stdio",
            ]
        )
            == .available(
                .vendoredPythonPackage(
                    package: "fixture-server",
                    entrypoint:
                        "MCPPackages/fixture_server/__main__.py",
                    consoleScript: "fixture-command",
                    arguments: ["--stdio"]
                )
            )
    )
}

@Test
func embeddedMCPRuntimeRejectsMalformedUvPackageInvocation() {
    let registry = CodexMCPEmbeddedRuntimeRegistry(
        pythonAvailable: true,
        uvxPackages: [
            "fixture-server":
                "MCPPackages/fixture_server/__main__.py",
        ]
    )

    #expect(
        registry.resolve(
            command: "uvx",
            arguments: ["--python"]
        )
            == .unavailable(
                .init(
                    command: "uvx",
                    reason: .invalidPackageInvocation(
                        "option requires a value: --python"
                    )
                )
            )
    )
    #expect(
        registry.resolve(
            command: "uvx",
            arguments: ["--from", "fixture-server"]
        )
            == .unavailable(
                .init(
                    command: "uvx",
                    reason: .invalidPackageInvocation(
                        "command is missing after --from"
                    )
                )
            )
    )
    #expect(
        registry.resolve(
            command: "uv",
            arguments: ["run", "fixture-server"]
        )
            == .unavailable(
                .init(
                    command: "uv",
                    reason: .invalidPackageInvocation(
                        "expected `uv tool run`, found subcommand run"
                    )
                )
            )
    )
}

@Test
func nodeMCPPackageSnapshotManifestBuildsExactNpxRegistryEntries()
    throws
{
    let data = Data(
        """
        {
          "schemaVersion": 1,
          "runtime": {
            "name": "NodeMobile",
            "version": "18.20.4"
          },
          "packageLockSha256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
          "tree": {
            "sha256": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
            "fileCount": 4,
            "totalBytes": 128
          },
          "packages": [
            {
              "name": "@modelcontextprotocol/server-filesystem",
              "version": "2026.7.10",
              "entrypoint": "MCPPackages/node_modules/@modelcontextprotocol/server-filesystem/dist/index.js"
            }
          ]
        }
        """.utf8
    )

    let manifest = try CodexMCPNodePackageSnapshotManifest(
        validating: data
    )

    #expect(
        manifest.npxRegistryEntries
            == [
                "@modelcontextprotocol/server-filesystem":
                    "MCPPackages/node_modules/"
                    + "@modelcontextprotocol/server-filesystem/"
                    + "dist/index.js",
                "@modelcontextprotocol/server-filesystem@2026.7.10":
                    "MCPPackages/node_modules/"
                    + "@modelcontextprotocol/server-filesystem/"
                    + "dist/index.js",
                "@modelcontextprotocol/server-filesystem@latest":
                    "MCPPackages/node_modules/"
                    + "@modelcontextprotocol/server-filesystem/"
                    + "dist/index.js",
            ]
    )
}

@Test
func nodeMCPPackageSnapshotManifestRejectsRuntimeVersionDrift() {
    let data = Data(
        """
        {
          "schemaVersion": 1,
          "runtime": {
            "name": "NodeMobile",
            "version": "99.0.0"
          },
          "packageLockSha256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
          "tree": {
            "sha256": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
            "fileCount": 1,
            "totalBytes": 1
          },
          "packages": [
            {
              "name": "@fixture/server",
              "version": "1.0.0",
              "entrypoint": "MCPPackages/node_modules/@fixture/server/index.js"
            }
          ]
        }
        """.utf8
    )

    #expect(throws: CodexMCPNodePackageSnapshotManifestError.self) {
        try CodexMCPNodePackageSnapshotManifest(
            validating: data
        )
    }
}
