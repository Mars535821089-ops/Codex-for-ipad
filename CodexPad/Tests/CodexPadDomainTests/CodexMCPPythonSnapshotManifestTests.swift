import Foundation
import Testing

@testable import CodexPadApplication

@Test
func pythonMCPPackageSnapshotBuildsVersionedUvxEntries()
    throws
{
    let manifest = try CodexMCPPythonPackageSnapshotManifest(
        validating: validPythonSnapshot(
            entrypoint: "mcp_server_time:main"
        )
    )

    #expect(
        manifest.uvxRegistryEntries
            == [
                "mcp-server-time": "mcp_server_time:main",
                "mcp-server-time@0.6.2":
                    "mcp_server_time:main",
                "mcp-server-time@latest":
                    "mcp_server_time:main",
            ]
    )
    #expect(manifest.runtime.version == "3.13.14")
    #expect(manifest.runtime.abi == "cp313")
}

@Test
func pythonMCPPackageSnapshotAcceptsDistinctConsoleScript()
    throws
{
    let manifest = try CodexMCPPythonPackageSnapshotManifest(
        validating: validPythonSnapshot(
            name: "example-server",
            version: "1.2.3",
            entrypoint: "example_server.__main__",
            consoleScript: "example-mcp"
        )
    )

    #expect(
        manifest.uvxRegistryEntries
            == [
                "example-server": "example_server.__main__",
                "example-server@1.2.3":
                    "example_server.__main__",
                "example-server@latest":
                    "example_server.__main__",
                "example-mcp": "example_server.__main__",
                "example-mcp@1.2.3":
                    "example_server.__main__",
                "example-mcp@latest":
                    "example_server.__main__",
            ]
    )
}

@Test(
    arguments: [
        ("CPython", "99.0.0", "cp313", "3.13-b14"),
        ("CPython", "3.13.14", "cp312", "3.13-b14"),
        ("OtherPython", "3.13.14", "cp313", "3.13-b14"),
    ]
)
func pythonMCPPackageSnapshotRejectsRuntimeDrift(
    name: String,
    version: String,
    abi: String,
    tag: String
) {
    let data = validPythonSnapshot(
        runtimeName: name,
        runtimeVersion: version,
        runtimeABI: abi,
        sourceTag: tag
    )

    #expect(
        throws:
            CodexMCPPythonPackageSnapshotManifestError.self
    ) {
        try CodexMCPPythonPackageSnapshotManifest(
            validating: data
        )
    }
}

@Test(
    arguments: [
        "",
        "/tmp/server.py",
        "../server.py",
        "PythonPackages/../server.py",
        "PythonPackages/server.txt",
        "bad module",
        "bad-module",
        "module:",
        ":main",
        "module:bad-attribute",
        "module:one:two",
    ]
)
func pythonMCPPackageSnapshotRejectsUnsafeEntrypoint(
    entrypoint: String
) {
    #expect(
        throws:
            CodexMCPPythonPackageSnapshotManifestError.self
    ) {
        try CodexMCPPythonPackageSnapshotManifest(
            validating: validPythonSnapshot(
                entrypoint: entrypoint
            )
        )
    }
}

@Test
func pythonMCPPackageSnapshotRejectsDuplicateCanonicalNames() {
    let data = Data(
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
            "fileCount": 2,
            "totalBytes": 2
          },
          "packages": [
            {
              "name": "example_server",
              "version": "1.0.0",
              "entrypoint": "example_server",
              "consoleScript": "example-server"
            },
            {
              "name": "example-server",
              "version": "2.0.0",
              "entrypoint": "example_server_v2",
              "consoleScript": "example-server-v2"
            }
          ]
        }
        """.utf8
    )

    #expect(
        throws:
            CodexMCPPythonPackageSnapshotManifestError.self
    ) {
        try CodexMCPPythonPackageSnapshotManifest(
            validating: data
        )
    }
}

private func validPythonSnapshot(
    runtimeName: String = "CPython",
    runtimeVersion: String = "3.13.14",
    runtimeABI: String = "cp313",
    sourceTag: String = "3.13-b14",
    name: String = "mcp-server-time",
    version: String = "0.6.2",
    entrypoint: String = "mcp_server_time",
    consoleScript: String = "mcp-server-time"
) -> Data {
    Data(
        """
        {
          "schemaVersion": 1,
          "runtime": {
            "name": "\(runtimeName)",
            "version": "\(runtimeVersion)",
            "abi": "\(runtimeABI)",
            "sourceTag": "\(sourceTag)",
            "sourceCommit": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
          },
          "requirementsLockSha256": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
          "tree": {
            "sha256": "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
            "fileCount": 42,
            "totalBytes": 2048
          },
          "packages": [
            {
              "name": "\(name)",
              "version": "\(version)",
              "entrypoint": "\(entrypoint)",
              "consoleScript": "\(consoleScript)"
            }
          ]
        }
        """.utf8
    )
}
