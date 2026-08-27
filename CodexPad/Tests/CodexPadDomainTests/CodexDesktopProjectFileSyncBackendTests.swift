import Foundation
import Testing

@testable import CodexPadApplication

private typealias ProjectFileValue = CodexDesktopAppHostRPC.Value

@Test
func projectFileSyncMirrorsRealFilesAndRemovesObsoleteSources() async throws {
    let fixture = ProjectFileSyncFixture()
    defer { fixture.cleanup() }
    let transport = ProjectFileDownloadTransport(
        payloads: [
            "brief": Data("first brief".utf8),
            "agent": Data("project-owned agents".utf8),
        ]
    )
    let backend = fixture.makeBackend(transport: transport)

    let firstResult = try await backend.sync(
        request: projectFileSyncRequest(
            files: [
                ("brief", "../brief?.md"),
                ("agent", "AGENTS.md"),
            ],
            instructions: "Prefer the supplied brief."
        )
    )
    let root = fixture.projectRoot
    #expect(
        firstResult
            == .object([
                "failedFiles": .array([]),
                "rootPath": .string(root.path),
            ])
    )
    #expect(
        try String(
            contentsOf: root.appendingPathComponent(
                "sources/brief_.md"
            ),
            encoding: .utf8
        ) == "first brief"
    )
    #expect(
        try String(
            contentsOf: root.appendingPathComponent(
                "sources/AGENTS (project file).md"
            ),
            encoding: .utf8
        ) == "project-owned agents"
    )
    let agents = try String(
        contentsOf: root.appendingPathComponent("AGENTS.md"),
        encoding: .utf8
    )
    #expect(agents.contains("Project One"))
    #expect(agents.contains("Prefer the supplied brief."))
    #expect(agents.contains("read-only reference material"))
    #expect(
        FileManager.default.fileExists(
            atPath: fixture.metadataFile.path
        )
    )

    await transport.setPayload(
        Data("replacement".utf8),
        for: "replacement"
    )
    _ = try await backend.sync(
        request: projectFileSyncRequest(
            files: [("replacement", "replacement.txt")]
        )
    )

    #expect(
        !FileManager.default.fileExists(
            atPath: root.appendingPathComponent(
                "sources/brief_.md"
            ).path
        )
    )
    #expect(
        !FileManager.default.fileExists(
            atPath: root.appendingPathComponent(
                "sources/AGENTS (project file).md"
            ).path
        )
    )
    #expect(
        try String(
            contentsOf: root.appendingPathComponent(
                "sources/replacement.txt"
            ),
            encoding: .utf8
        ) == "replacement"
    )
}

@Test
func projectFileSyncReusesVerifiedCachedContent() async throws {
    let fixture = ProjectFileSyncFixture()
    defer { fixture.cleanup() }
    let transport = ProjectFileDownloadTransport(
        payloads: ["brief": Data("cached brief".utf8)]
    )
    let backend = fixture.makeBackend(transport: transport)
    let request = projectFileSyncRequest(
        files: [("brief", "brief.md")]
    )

    _ = try await backend.sync(request: request)
    await transport.setPayload(Data("changed upstream".utf8), for: "brief")
    _ = try await backend.sync(request: request)

    #expect(await transport.resolveCount(for: "brief") == 1)
    #expect(await transport.downloadCount(for: "brief") == 1)
    #expect(
        try String(
            contentsOf: fixture.projectRoot.appendingPathComponent(
                "sources/brief.md"
            ),
            encoding: .utf8
        ) == "cached brief"
    )
}

@Test
func projectFileSyncReportsDownloadLinkAndDownloadFailures() async throws {
    let fixture = ProjectFileSyncFixture()
    defer { fixture.cleanup() }
    let transport = ProjectFileDownloadTransport(
        payloads: ["success": Data("available".utf8)]
    )
    await transport.failResolution(for: "link", status: 404)
    await transport.failDownload(for: "download", status: 503)
    let backend = fixture.makeBackend(transport: transport)

    let result = try await backend.sync(
        request: projectFileSyncRequest(
            files: [
                ("link", "link.txt"),
                ("download", "download.txt"),
                ("success", "success.txt"),
            ]
        )
    )

    #expect(
        result
            == .object([
                "failedFiles": .array([
                    .object([
                        "fileOrdinal": .integer(1),
                        "stage": .string("download-link"),
                        "status": .integer(404),
                    ]),
                    .object([
                        "fileOrdinal": .integer(2),
                        "stage": .string("download"),
                        "status": .integer(503),
                    ]),
                ]),
                "rootPath": .string(fixture.projectRoot.path),
            ])
    )
    #expect(
        FileManager.default.fileExists(
            atPath: fixture.projectRoot.appendingPathComponent(
                "sources/success.txt"
            ).path
        )
    )
    #expect(
        !FileManager.default.fileExists(
            atPath: fixture.projectRoot.appendingPathComponent(
                "sources/link.txt"
            ).path
        )
    )
    let agents = try String(
        contentsOf: fixture.projectRoot.appendingPathComponent(
            "AGENTS.md"
        ),
        encoding: .utf8
    )
    #expect(agents.contains("2 project sources could not be synced"))
}

@Test
func projectFileSyncContainsNamesAndRejectsUnsafeProjectIDs() async throws {
    let fixture = ProjectFileSyncFixture()
    defer { fixture.cleanup() }
    let transport = ProjectFileDownloadTransport(
        payloads: [
            "one": Data("one".utf8),
            "two": Data("two".utf8),
            "reserved": Data("reserved".utf8),
        ]
    )
    let backend = fixture.makeBackend(transport: transport)

    for projectID in ["../escape", ".metadata", "", "bad/id"] {
        await #expect(
            throws: CodexDesktopProjectFileSyncBackend.Error
                .invalidProjectID
        ) {
            _ = try await backend.sync(
                request: projectFileSyncRequest(
                    projectID: projectID,
                    files: []
                )
            )
        }
    }

    _ = try await backend.sync(
        request: projectFileSyncRequest(
            files: [
                ("one", "../../same?.txt"),
                ("two", "SAME?.TXT"),
                ("reserved", "con.txt"),
            ]
        )
    )

    let sources = fixture.projectRoot.appendingPathComponent("sources")
    #expect(
        FileManager.default.fileExists(
            atPath: sources.appendingPathComponent("same_.txt").path
        )
    )
    #expect(
        FileManager.default.fileExists(
            atPath: sources.appendingPathComponent(
                "SAME_ (2).TXT"
            ).path
        )
    )
    #expect(
        FileManager.default.fileExists(
            atPath: sources.appendingPathComponent("_con.txt").path
        )
    )
    #expect(
        !FileManager.default.fileExists(
            atPath: fixture.root.appendingPathComponent("escape").path
        )
    )
}

private final class ProjectFileSyncFixture: @unchecked Sendable {
    let root: URL
    let codexHome: URL
    let projectRoot: URL
    let metadataFile: URL

    init() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "CodexProjectFileSyncTests-\(UUID().uuidString)",
            isDirectory: true
        )
        codexHome = root.appendingPathComponent(
            "codex-home",
            isDirectory: true
        )
        projectRoot = codexHome.appendingPathComponent(
            ".chatgpt-projects/project-1",
            isDirectory: true
        )
        metadataFile = codexHome.appendingPathComponent(
            ".chatgpt-projects/.metadata/project-1.json"
        )
    }

    func makeBackend(
        transport: ProjectFileDownloadTransport
    ) -> CodexDesktopProjectFileSyncBackend {
        CodexDesktopProjectFileSyncBackend(
            codexHome: codexHome,
            resolveDownloadRequest: { callback, fileID in
                try await transport.resolve(
                    callback: callback,
                    fileID: fileID
                )
            },
            download: { request in
                try await transport.download(request: request)
            }
        )
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}

private actor ProjectFileDownloadTransport {
    private var payloads: [String: Data]
    private var resolutionStatuses: [String: Int] = [:]
    private var downloadStatuses: [String: Int] = [:]
    private var resolutionCounts: [String: Int] = [:]
    private var downloadCounts: [String: Int] = [:]

    init(payloads: [String: Data]) {
        self.payloads = payloads
    }

    func setPayload(_ payload: Data, for fileID: String) {
        payloads[fileID] = payload
    }

    func failResolution(for fileID: String, status: Int) {
        resolutionStatuses[fileID] = status
    }

    func failDownload(for fileID: String, status: Int) {
        downloadStatuses[fileID] = status
    }

    func resolve(
        callback: ProjectFileValue,
        fileID: String
    ) throws -> ProjectFileValue {
        resolutionCounts[fileID, default: 0] += 1
        guard callback == .import(7) else {
            throw CodexDesktopProjectFileSyncBackend.TransferError()
        }
        if let status = resolutionStatuses[fileID] {
            throw CodexDesktopProjectFileSyncBackend.TransferError(
                status: status
            )
        }
        return .object(["fileId": .string(fileID)])
    }

    func download(request: ProjectFileValue) throws -> Data {
        guard case let .object(fields) = request,
              case let .string(fileID)? = fields["fileId"]
        else {
            throw CodexDesktopProjectFileSyncBackend.TransferError()
        }
        downloadCounts[fileID, default: 0] += 1
        if let status = downloadStatuses[fileID] {
            throw CodexDesktopProjectFileSyncBackend.TransferError(
                status: status
            )
        }
        guard let payload = payloads[fileID] else {
            throw CodexDesktopProjectFileSyncBackend.TransferError(
                status: 404
            )
        }
        return payload
    }

    func resolveCount(for fileID: String) -> Int {
        resolutionCounts[fileID, default: 0]
    }

    func downloadCount(for fileID: String) -> Int {
        downloadCounts[fileID, default: 0]
    }
}

private func projectFileSyncRequest(
    projectID: String = "project-1",
    files: [(String, String)],
    instructions: String = ""
) -> ProjectFileValue {
    .object([
        "files": .array(
            files.map { fileID, name in
                .object([
                    "fileId": .string(fileID),
                    "name": .string(name),
                ])
            }
        ),
        "getFileDownloadRequest": .import(7),
        "instructions": .string(instructions),
        "projectId": .string(projectID),
        "projectName": .string("Project One"),
    ])
}
