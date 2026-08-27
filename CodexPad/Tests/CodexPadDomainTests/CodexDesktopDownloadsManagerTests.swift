import Foundation
import Testing

@testable import CodexPadApplication

private typealias DownloadsManager = CodexDesktopDownloadsManager
private typealias DownloadsService = CodexDesktopDownloadsAppHostService

private actor DownloadControlProbe {
  private(set) var operations: [String] = []

  func record(_ operation: String) {
    operations.append(operation)
  }
}

private actor DownloadURLProbe {
  private(set) var opened: [URL] = []
  private(set) var revealed: [URL] = []

  func open(_ url: URL) -> Bool {
    opened.append(url)
    return true
  }

  func reveal(_ url: URL) -> Bool {
    revealed.append(url)
    return true
  }
}

private struct DownloadTestDirectory {
  let root: URL

  init() throws {
    root = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "CodexDesktopDownloadsManagerTests-\(UUID().uuidString)",
        isDirectory: true
      )
    try FileManager.default.createDirectory(
      at: root,
      withIntermediateDirectories: true
    )
  }

  func remove() {
    try? FileManager.default.removeItem(at: root)
  }
}

private func makeManager(
  root: URL,
  urlProbe: DownloadURLProbe = DownloadURLProbe(),
  picker: @escaping DownloadsManager.DirectoryPicker = { nil },
  now: @escaping @Sendable () -> Int64 = { 9_000 }
) throws -> DownloadsManager {
  try DownloadsManager(
    downloadsDirectory: root,
    openURL: { url in await urlProbe.open(url) },
    revealURL: { url in await urlProbe.reveal(url) },
    chooseDirectory: picker,
    now: now
  )
}

@Test
func downloadsManagerPersistsProgressCompletionAndAcknowledgement()
  async throws
{
  let directory = try DownloadTestDirectory()
  defer { directory.remove() }
  let destination = directory.root.appendingPathComponent("report.pdf")
  try Data("real file".utf8).write(to: destination)

  let controls = DownloadControlProbe()
  let manager = try makeManager(root: directory.root)
  try await manager.register(
    id: "download-1",
    sourceURL: URL(string: "https://example.invalid/report.pdf")!,
    destinationURL: destination,
    totalBytes: 100,
    startedAtMs: 1_000,
    task: .init(
      pause: { await controls.record("pause") },
      resume: { await controls.record("resume") },
      cancel: { await controls.record("cancel") }
    )
  )
  try await manager.update(
    id: "download-1",
    receivedBytes: 40,
    totalBytes: 100,
    updatedAtMs: 2_000
  )

  #expect(try await manager.pause(id: "download-1") == .success)
  #expect(try await manager.resume(id: "download-1") == .success)
  try await manager.complete(
    id: "download-1",
    receivedBytes: 100,
    updatedAtMs: 3_000
  )

  let snapshot = try await manager.getSnapshot()
  #expect(snapshot.capturedAtMs == 9_000)
  #expect(snapshot.unacknowledgedIDs == ["download-1"])
  #expect(
    snapshot.downloads == [
      .init(
        canCancel: false,
        canPause: false,
        canResume: false,
        fileExists: true,
        filename: "report.pdf",
        id: "download-1",
        path: destination.resolvingSymlinksInPath().path,
        receivedBytes: 100,
        startedAtMs: 1_000,
        status: .complete,
        totalBytes: 100,
        updatedAtMs: 3_000,
        url: "https://example.invalid/report.pdf"
      )
    ]
  )
  #expect(await controls.operations == ["pause", "resume"])

  let restored = try makeManager(root: directory.root)
  #expect(
    try await restored.searchHistory(
      .init(text: "REPORT", maxResults: 1, offset: 0)
    ).downloads.map(\.id) == ["download-1"]
  )
  try await restored.acknowledge(.ids(["download-1"]))

  let acknowledgedRestore = try makeManager(root: directory.root)
  #expect(
    try await acknowledgedRestore.getSnapshot()
      .unacknowledgedIDs.isEmpty
  )
}

@Test
func downloadsManagerRunsOnlyRegisteredActiveTaskControls()
  async throws
{
  let directory = try DownloadTestDirectory()
  defer { directory.remove() }
  let manager = try makeManager(root: directory.root)

  #expect(
    try await manager.pause(id: "missing")
      == .failure(reason: .missingDownload)
  )
  #expect(
    try await manager.resume(id: "missing")
      == .failure(reason: .missingDownload)
  )
  #expect(
    try await manager.cancel(id: "missing")
      == .failure(reason: .missingDownload)
  )

  let destination = directory.root.appendingPathComponent("active.bin")
  let controls = DownloadControlProbe()
  try await manager.register(
    id: "active",
    sourceURL: URL(string: "https://example.invalid/active.bin")!,
    destinationURL: destination,
    totalBytes: 10,
    startedAtMs: 1,
    task: .init(
      cancel: { await controls.record("cancel") }
    )
  )

  #expect(
    try await manager.pause(id: "active")
      == .failure(reason: .downloadNotPausable)
  )
  #expect(
    try await manager.resume(id: "active")
      == .failure(reason: .downloadNotResumable)
  )
  #expect(try await manager.cancel(id: "active") == .success)
  #expect(await controls.operations == ["cancel"])
  #expect(
    try await manager.cancel(id: "active")
      == .failure(reason: .missingDownload)
  )
  #expect(
    try await manager.getSnapshot().downloads.first?.status
      == .canceled
  )

  try await manager.register(
    id: "failed",
    sourceURL: URL(string: "https://example.invalid/failed.bin")!,
    destinationURL: directory.root.appendingPathComponent("failed.bin"),
    totalBytes: 20,
    startedAtMs: 2,
    task: .init(cancel: {})
  )
  try await manager.fail(id: "failed", updatedAtMs: 3)
  #expect(
    try await manager.getSnapshot().downloads
      .first(where: { $0.id == "failed" })?.status == .failed
  )

  try await manager.clearHistory()
  #expect(try await manager.getSnapshot().downloads.isEmpty)
}

@Test
func downloadsManagerRestrictsPathsAndUsesInjectedPlatformOperations()
  async throws
{
  let directory = try DownloadTestDirectory()
  defer { directory.remove() }
  let chosen = directory.root.appendingPathComponent(
    "chosen",
    isDirectory: true
  )
  try FileManager.default.createDirectory(
    at: chosen,
    withIntermediateDirectories: true
  )
  let urlProbe = DownloadURLProbe()
  let manager = try makeManager(
    root: directory.root,
    urlProbe: urlProbe,
    picker: { chosen }
  )
  let destination = directory.root.appendingPathComponent("finished.txt")
  try Data("finished".utf8).write(to: destination)

  try await manager.register(
    id: "finished",
    sourceURL: URL(string: "https://example.invalid/finished.txt")!,
    destinationURL: destination,
    totalBytes: 8,
    startedAtMs: 10,
    task: .init(cancel: {})
  )
  #expect(
    try await manager.removeFromHistory(id: "finished")
      == .failure(reason: .downloadNotRemovable)
  )
  try await manager.complete(
    id: "finished",
    receivedBytes: 8,
    updatedAtMs: 20
  )

  #expect(try await manager.open(id: "finished") == .success)
  #expect(try await manager.showInFolder(id: "finished") == .success)
  #expect(try await manager.showDownloadsFolder() == .success)
  #expect(
    try await manager.chooseDownloadDirectory()
      == chosen.resolvingSymlinksInPath().path
  )
  #expect(await urlProbe.opened == [destination.resolvingSymlinksInPath()])
  #expect(
    await urlProbe.revealed == [
      destination.resolvingSymlinksInPath(),
      directory.root.resolvingSymlinksInPath(),
    ]
  )

  #expect(
    try await manager.removeFromHistory(id: "finished") == .success
  )
  #expect(try await manager.getSnapshot().downloads.isEmpty)

  let outside = FileManager.default.temporaryDirectory
    .appendingPathComponent("outside-\(UUID().uuidString)")
  await #expect(throws: DownloadsManager.Error.self) {
    try await manager.register(
      id: "outside",
      sourceURL: URL(string: "https://example.invalid/outside")!,
      destinationURL: outside,
      totalBytes: 1,
      startedAtMs: 1,
      task: .init(cancel: {})
    )
  }
}
