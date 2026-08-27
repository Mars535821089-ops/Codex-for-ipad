import Foundation
import Testing
@testable import CodexPadApplication

private typealias DownloadsValue = CodexDesktopAppHostRPC.Value
private typealias DownloadsService = CodexDesktopDownloadsAppHostService

@Test
func desktopDownloadsRoutesReleasedCommandsAndReturnsExactActionShapes()
    async throws
{
    let manager = RecordingDownloadsManager(
        actionResults: [
            .cancel: .success,
            .open: .failure(
                reason: .openFailed,
                message: "The file could not be opened"
            ),
            .pause: .failure(reason: .downloadNotPausable),
            .removeFromHistory: .failure(
                reason: .downloadNotRemovable
            ),
            .resume: .failure(
                reason: .downloadNotResumable
            ),
            .showDownloadsFolder: .success,
            .showInFolder: .failure(
                reason: .showInFolderFailed,
                message: "The file could not be revealed"
            ),
        ]
    )
    let service = DownloadsService(manager: manager)

    #expect(
        try await service.invoke(
            service: "downloads",
            method: "cancel",
            arguments: [.object(["id": .string("cancel-id")])]
        ) == .object(["ok": .bool(true)])
    )
    #expect(
        try await service.invoke(
            service: "downloads",
            method: "open",
            arguments: [.object(["id": .string("open-id")])]
        ) == .object([
            "message": .string("The file could not be opened"),
            "ok": .bool(false),
            "reason": .string("open-failed"),
        ])
    )
    #expect(
        try await service.invoke(
            service: "downloads",
            method: "pause",
            arguments: [.object(["id": .string("pause-id")])]
        ) == .object([
            "ok": .bool(false),
            "reason": .string("download-not-pausable"),
        ])
    )
    #expect(
        try await service.invoke(
            service: "downloads",
            method: "removeFromHistory",
            arguments: [.object(["id": .string("remove-id")])]
        ) == .object([
            "ok": .bool(false),
            "reason": .string("download-not-removable"),
        ])
    )
    #expect(
        try await service.invoke(
            service: "downloads",
            method: "resume",
            arguments: [.object(["id": .string("resume-id")])]
        ) == .object([
            "ok": .bool(false),
            "reason": .string("download-not-resumable"),
        ])
    )
    #expect(
        try await service.invoke(
            service: "downloads",
            method: "showDownloadsFolder",
            arguments: nil
        ) == .object(["ok": .bool(true)])
    )
    #expect(
        try await service.invoke(
            service: "downloads",
            method: "showInFolder",
            arguments: [.object(["id": .string("show-id")])]
        ) == .object([
            "message": .string("The file could not be revealed"),
            "ok": .bool(false),
            "reason": .string("show-in-folder-failed"),
        ])
    )

    #expect(
        await manager.operations == [
            .cancel(id: "cancel-id"),
            .open(id: "open-id"),
            .pause(id: "pause-id"),
            .removeFromHistory(id: "remove-id"),
            .resume(id: "resume-id"),
            .showDownloadsFolder,
            .showInFolder(id: "show-id"),
        ]
    )
}

@Test
func desktopDownloadsRoutesReleasedAcknowledgementDirectoryAndHistoryCalls()
    async throws
{
    let snapshot = releasedDownloadsSnapshot()
    let manager = RecordingDownloadsManager(
        chosenDirectory: "/Downloads/Selected",
        snapshot: snapshot,
        searchSnapshot: snapshot
    )
    let service = DownloadsService(manager: manager)

    #expect(
        try await service.invoke(
            service: "downloads",
            method: "acknowledge",
            arguments: [
                .object([
                    "ids": .array([
                        .string("download-1"),
                        .string("download-2"),
                    ])
                ])
            ]
        ) == .undefined
    )
    #expect(
        try await service.invoke(
            service: "downloads",
            method: "acknowledge",
            arguments: [.object(["all": .bool(true)])]
        ) == .undefined
    )
    #expect(
        try await service.invoke(
            service: "downloads",
            method: "chooseDownloadDirectory",
            arguments: []
        ) == .string("/Downloads/Selected")
    )
    #expect(
        try await service.invoke(
            service: "downloads",
            method: "clearHistory",
            arguments: nil
        ) == .undefined
    )
    #expect(
        try await service.invoke(
            service: "downloads",
            method: "getSnapshot",
            arguments: []
        ) == releasedDownloadsSnapshotValue()
    )
    #expect(
        try await service.invoke(
            service: "downloads",
            method: "searchHistory",
            arguments: [
                .object([
                    "maxResults": .integer(100),
                    "offset": .integer(200),
                    "text": .string("report"),
                ])
            ]
        ) == releasedDownloadsSnapshotValue()
    )

    #expect(
        await manager.operations == [
            .acknowledge(.ids(["download-1", "download-2"])),
            .acknowledge(.all),
            .chooseDownloadDirectory,
            .clearHistory,
            .getSnapshot,
            .searchHistory(
                .init(
                    text: "report",
                    maxResults: 100,
                    offset: 200
                )
            ),
        ]
    )

    await manager.setChosenDirectory(nil)
    #expect(
        try await service.invoke(
            service: "downloads",
            method: "chooseDownloadDirectory",
            arguments: nil
        ) == .null
    )
}

@Test
func desktopDownloadsSnapshotMatchesReleasedItemFieldsAndStatuses()
    async throws
{
    let manager = RecordingDownloadsManager(
        snapshot: releasedDownloadsSnapshot()
    )
    let service = DownloadsService(manager: manager)

    let value = try await service.invoke(
        service: "downloads",
        method: "getSnapshot",
        arguments: nil
    )

    #expect(value == releasedDownloadsSnapshotValue())
}

@Test
func desktopDownloadsRejectsMalformedReleasedArguments() async throws {
    let service = DownloadsService(
        manager: RecordingDownloadsManager()
    )

    for (method, arguments) in [
        ("cancel", [DownloadsValue.string("download-1")]),
        (
            "acknowledge",
            [DownloadsValue.object([
                "ids": .array([.integer(1)])
            ])]
        ),
        (
            "acknowledge",
            [DownloadsValue.object(["all": .bool(false)])]
        ),
        (
            "searchHistory",
            [DownloadsValue.object([
                "maxResults": .integer(-1),
                "text": .string(""),
            ])]
        ),
        (
            "searchHistory",
            [DownloadsValue.object(["text": .integer(1)])]
        ),
    ] {
        await #expect(throws: DownloadsService.Error.invalidArguments) {
            _ = try await service.invoke(
                service: "downloads",
                method: method,
                arguments: arguments
            )
        }
    }

    await #expect(
        throws: DownloadsService.Error.unsupportedMethod(
            service: "downloads",
            method: "unknown"
        )
    ) {
        _ = try await service.invoke(
            service: "downloads",
            method: "unknown",
            arguments: nil
        )
    }
}

@Test
func desktopDownloadsReportsUnavailableManagerWithoutInventingData()
    async throws
{
    let service = DownloadsService()

    await #expect(
        throws: DownloadsService.Error.unavailable(
            service: "downloads",
            method: "getSnapshot"
        )
    ) {
        _ = try await service.invoke(
            service: "downloads",
            method: "getSnapshot",
            arguments: nil
        )
    }
    await #expect(
        throws: DownloadsService.Error.unavailable(
            service: "downloads",
            method: "chooseDownloadDirectory"
        )
    ) {
        _ = try await service.invoke(
            service: "downloads",
            method: "chooseDownloadDirectory",
            arguments: nil
        )
    }
}

private func releasedDownloadsSnapshot() -> DownloadsService.Snapshot {
    .init(
        capturedAtMs: 1_754_342_100_000,
        downloads: [
            .init(
                canCancel: false,
                canPause: false,
                canResume: false,
                fileExists: true,
                filename: "report.pdf",
                id: "download-complete",
                path: "/Downloads/report.pdf",
                receivedBytes: 4_096,
                startedAtMs: 1_754_342_000_000,
                status: .complete,
                totalBytes: 4_096,
                updatedAtMs: 1_754_342_005_000,
                url: "https://example.invalid/report.pdf"
            ),
            .init(
                canCancel: true,
                canPause: false,
                canResume: true,
                fileExists: true,
                filename: "archive.zip",
                id: "download-paused",
                path: "/Downloads/archive.zip",
                receivedBytes: 512,
                startedAtMs: 1_754_342_010_000,
                status: .paused,
                totalBytes: 1_024,
                updatedAtMs: 1_754_342_011_000,
                url: "https://example.invalid/archive.zip"
            ),
        ],
        unacknowledgedIDs: ["download-complete"]
    )
}

private func releasedDownloadsSnapshotValue() -> DownloadsValue {
    .object([
        "capturedAtMs": .integer(1_754_342_100_000),
        "downloads": .array([
            .object([
                "canCancel": .bool(false),
                "canPause": .bool(false),
                "canResume": .bool(false),
                "fileExists": .bool(true),
                "filename": .string("report.pdf"),
                "id": .string("download-complete"),
                "path": .string("/Downloads/report.pdf"),
                "receivedBytes": .integer(4_096),
                "startedAtMs": .integer(1_754_342_000_000),
                "status": .string("complete"),
                "totalBytes": .integer(4_096),
                "updatedAtMs": .integer(1_754_342_005_000),
                "url": .string("https://example.invalid/report.pdf"),
            ]),
            .object([
                "canCancel": .bool(true),
                "canPause": .bool(false),
                "canResume": .bool(true),
                "fileExists": .bool(true),
                "filename": .string("archive.zip"),
                "id": .string("download-paused"),
                "path": .string("/Downloads/archive.zip"),
                "receivedBytes": .integer(512),
                "startedAtMs": .integer(1_754_342_010_000),
                "status": .string("paused"),
                "totalBytes": .integer(1_024),
                "updatedAtMs": .integer(1_754_342_011_000),
                "url": .string("https://example.invalid/archive.zip"),
            ]),
        ]),
        "unacknowledgedIds": .array([
            .string("download-complete")
        ]),
    ])
}

private actor RecordingDownloadsManager:
    CodexDesktopDownloadsAppHostManaging
{
    enum Action: Hashable, Sendable {
        case cancel
        case open
        case pause
        case removeFromHistory
        case resume
        case showDownloadsFolder
        case showInFolder
    }

    enum Operation: Equatable, Sendable {
        case acknowledge(DownloadsService.Acknowledgement)
        case cancel(id: String)
        case chooseDownloadDirectory
        case clearHistory
        case getSnapshot
        case open(id: String)
        case pause(id: String)
        case removeFromHistory(id: String)
        case resume(id: String)
        case searchHistory(DownloadsService.SearchRequest)
        case showDownloadsFolder
        case showInFolder(id: String)
    }

    private(set) var operations: [Operation] = []
    private let actionResults:
        [Action: DownloadsService.ActionResult]
    private var chosenDirectory: String?
    private let snapshot: DownloadsService.Snapshot
    private let searchSnapshot: DownloadsService.Snapshot

    init(
        actionResults:
            [Action: DownloadsService.ActionResult] = [:],
        chosenDirectory: String? = nil,
        snapshot: DownloadsService.Snapshot = .init(
            capturedAtMs: 0,
            downloads: [],
            unacknowledgedIDs: []
        ),
        searchSnapshot: DownloadsService.Snapshot = .init(
            capturedAtMs: 0,
            downloads: [],
            unacknowledgedIDs: []
        )
    ) {
        self.actionResults = actionResults
        self.chosenDirectory = chosenDirectory
        self.snapshot = snapshot
        self.searchSnapshot = searchSnapshot
    }

    func acknowledge(
        _ acknowledgement: DownloadsService.Acknowledgement
    ) async throws {
        operations.append(.acknowledge(acknowledgement))
    }

    func cancel(id: String) async throws
        -> DownloadsService.ActionResult
    {
        operations.append(.cancel(id: id))
        return actionResults[.cancel] ?? .success
    }

    func chooseDownloadDirectory() async throws -> String? {
        operations.append(.chooseDownloadDirectory)
        return chosenDirectory
    }

    func clearHistory() async throws {
        operations.append(.clearHistory)
    }

    func getSnapshot() async throws -> DownloadsService.Snapshot {
        operations.append(.getSnapshot)
        return snapshot
    }

    func open(id: String) async throws
        -> DownloadsService.ActionResult
    {
        operations.append(.open(id: id))
        return actionResults[.open] ?? .success
    }

    func pause(id: String) async throws
        -> DownloadsService.ActionResult
    {
        operations.append(.pause(id: id))
        return actionResults[.pause] ?? .success
    }

    func removeFromHistory(id: String) async throws
        -> DownloadsService.ActionResult
    {
        operations.append(.removeFromHistory(id: id))
        return actionResults[.removeFromHistory] ?? .success
    }

    func resume(id: String) async throws
        -> DownloadsService.ActionResult
    {
        operations.append(.resume(id: id))
        return actionResults[.resume] ?? .success
    }

    func searchHistory(
        _ request: DownloadsService.SearchRequest
    ) async throws -> DownloadsService.Snapshot {
        operations.append(.searchHistory(request))
        return searchSnapshot
    }

    func showDownloadsFolder() async throws
        -> DownloadsService.ActionResult
    {
        operations.append(.showDownloadsFolder)
        return actionResults[.showDownloadsFolder] ?? .success
    }

    func showInFolder(id: String) async throws
        -> DownloadsService.ActionResult
    {
        operations.append(.showInFolder(id: id))
        return actionResults[.showInFolder] ?? .success
    }

    func setChosenDirectory(_ chosenDirectory: String?) {
        self.chosenDirectory = chosenDirectory
    }
}
