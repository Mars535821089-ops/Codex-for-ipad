import Foundation

/// Persistent iPad implementation of the released desktop downloads manager.
///
/// Download transports register their real task controls and report lifecycle
/// changes through `register`, `update`, `complete`, and `fail`. History is
/// atomically persisted under the injected downloads directory.
public actor CodexDesktopDownloadsManager:
  CodexDesktopDownloadsAppHostManaging
{
  public typealias Service = CodexDesktopDownloadsAppHostService
  public typealias DirectoryPicker =
    @Sendable () async throws -> URL?
  public typealias URLOperation =
    @Sendable (URL) async throws -> Bool
  public typealias Clock = @Sendable () -> Int64

  public enum Error: Swift.Error, Equatable, Sendable {
    case duplicateDownload(String)
    case inactiveDownload(String)
    case invalidByteCount
    case invalidDirectory(String)
    case invalidIdentifier
    case missingDownload(String)
    case pathOutsideDownloadsDirectory(String)
  }

  /// Real transport controls retained only while a task is registered.
  public struct ActiveTask: Sendable {
    public typealias Operation =
      @Sendable () async throws -> Void

    fileprivate let pauseOperation: Operation?
    fileprivate let resumeOperation: Operation?
    fileprivate let cancelOperation: Operation

    public init(
      pause: Operation? = nil,
      resume: Operation? = nil,
      cancel: @escaping Operation
    ) {
      pauseOperation = pause
      resumeOperation = resume
      cancelOperation = cancel
    }
  }

  private enum StoredStatus: String, Codable, Sendable {
    case started
    case inProgress = "in_progress"
    case paused
    case canceled
    case complete
    case failed

    var serviceStatus: Service.DownloadStatus {
      switch self {
      case .started: .started
      case .inProgress: .inProgress
      case .paused: .paused
      case .canceled: .canceled
      case .complete: .complete
      case .failed: .failed
      }
    }

    var isActive: Bool {
      switch self {
      case .started, .inProgress, .paused:
        true
      case .canceled, .complete, .failed:
        false
      }
    }
  }

  private struct StoredDownload: Codable, Sendable {
    var filename: String
    var id: String
    var path: String
    var receivedBytes: Int64
    var startedAtMs: Int64
    var status: StoredStatus
    var totalBytes: Int64
    var updatedAtMs: Int64
    var url: String
  }

  private struct PersistedState: Codable, Sendable {
    static let currentVersion = 1

    var downloads: [StoredDownload]
    var unacknowledgedIDs: [String]
    var version: Int
  }

  private let downloadsDirectory: URL
  private let persistenceURL: URL
  private let openURL: URLOperation
  private let revealURL: URLOperation
  private let chooseDirectoryOperation: DirectoryPicker
  private let now: Clock

  private var downloadsByID: [String: StoredDownload]
  private var unacknowledgedIDs: Set<String>
  private var activeTasks: [String: ActiveTask] = [:]

  public init(
    downloadsDirectory: URL,
    persistenceURL: URL? = nil,
    openURL: @escaping URLOperation,
    revealURL: @escaping URLOperation,
    chooseDirectory: @escaping DirectoryPicker,
    now: @escaping Clock = {
      Int64(Date().timeIntervalSince1970 * 1_000)
    }
  ) throws {
    guard downloadsDirectory.isFileURL else {
      throw Error.invalidDirectory(
        downloadsDirectory.absoluteString
      )
    }
    try FileManager.default.createDirectory(
      at: downloadsDirectory,
      withIntermediateDirectories: true
    )
    let root = downloadsDirectory.resolvingSymlinksInPath()
    var isDirectory: ObjCBool = false
    guard
      FileManager.default.fileExists(
        atPath: root.path,
        isDirectory: &isDirectory
      ), isDirectory.boolValue
    else {
      throw Error.invalidDirectory(root.path)
    }

    let requestedPersistenceURL =
      persistenceURL
      ?? root.appendingPathComponent(
        ".codex-downloads-history.json"
      )
    let canonicalPersistenceURL = try Self.canonicalURL(
      requestedPersistenceURL,
      under: root,
      allowRoot: false
    )

    self.downloadsDirectory = root
    self.persistenceURL = canonicalPersistenceURL
    self.openURL = openURL
    self.revealURL = revealURL
    chooseDirectoryOperation = chooseDirectory
    self.now = now

    if FileManager.default.fileExists(
      atPath: canonicalPersistenceURL.path
    ) {
      let data = try Data(contentsOf: canonicalPersistenceURL)
      let state = try JSONDecoder().decode(
        PersistedState.self,
        from: data
      )
      guard state.version == PersistedState.currentVersion else {
        throw Error.invalidDirectory(
          canonicalPersistenceURL.path
        )
      }

      var loaded: [String: StoredDownload] = [:]
      var loadedUnacknowledged = Set(
        state.unacknowledgedIDs
      )
      for var download in state.downloads {
        guard
          !download.id.trimmingCharacters(
            in: .whitespacesAndNewlines
          ).isEmpty
        else {
          throw Error.invalidIdentifier
        }
        let canonicalPath = try Self.canonicalURL(
          URL(fileURLWithPath: download.path),
          under: root,
          allowRoot: false
        )
        download.path = canonicalPath.path
        if download.status.isActive {
          download.status = .failed
          loadedUnacknowledged.insert(download.id)
        }
        guard
          loaded.updateValue(
            download,
            forKey: download.id
          ) == nil
        else {
          throw Error.duplicateDownload(download.id)
        }
      }
      downloadsByID = loaded
      unacknowledgedIDs =
        loadedUnacknowledged
        .intersection(loaded.keys)
    } else {
      downloadsByID = [:]
      unacknowledgedIDs = []
    }
  }

  // MARK: - Download transport integration

  public func register(
    id: String,
    sourceURL: URL,
    destinationURL: URL,
    totalBytes: Int64,
    startedAtMs: Int64? = nil,
    task: ActiveTask
  ) throws {
    guard
      !id.trimmingCharacters(
        in: .whitespacesAndNewlines
      ).isEmpty
    else {
      throw Error.invalidIdentifier
    }
    guard downloadsByID[id] == nil else {
      throw Error.duplicateDownload(id)
    }
    guard totalBytes >= 0 else {
      throw Error.invalidByteCount
    }
    let destination = try Self.canonicalURL(
      destinationURL,
      under: downloadsDirectory,
      allowRoot: false
    )
    let timestamp = startedAtMs ?? now()
    let download = StoredDownload(
      filename: destination.lastPathComponent,
      id: id,
      path: destination.path,
      receivedBytes: 0,
      startedAtMs: timestamp,
      status: .started,
      totalBytes: totalBytes,
      updatedAtMs: timestamp,
      url: sourceURL.absoluteString
    )

    downloadsByID[id] = download
    activeTasks[id] = task
    do {
      try persist()
    } catch {
      downloadsByID[id] = nil
      activeTasks[id] = nil
      throw error
    }
  }

  public func update(
    id: String,
    receivedBytes: Int64,
    totalBytes: Int64? = nil,
    updatedAtMs: Int64? = nil
  ) throws {
    guard var download = downloadsByID[id] else {
      throw Error.missingDownload(id)
    }
    guard activeTasks[id] != nil, download.status.isActive else {
      throw Error.inactiveDownload(id)
    }
    let nextTotal = totalBytes ?? download.totalBytes
    guard receivedBytes >= 0, nextTotal >= 0 else {
      throw Error.invalidByteCount
    }
    let previous = download
    download.receivedBytes = receivedBytes
    download.totalBytes = nextTotal
    download.updatedAtMs = updatedAtMs ?? now()
    if download.status != .paused {
      download.status = .inProgress
    }
    downloadsByID[id] = download
    do {
      try persist()
    } catch {
      downloadsByID[id] = previous
      throw error
    }
  }

  public func complete(
    id: String,
    receivedBytes: Int64,
    updatedAtMs: Int64? = nil
  ) throws {
    try finish(
      id: id,
      status: .complete,
      receivedBytes: receivedBytes,
      updatedAtMs: updatedAtMs
    )
  }

  public func fail(
    id: String,
    updatedAtMs: Int64? = nil
  ) throws {
    guard let download = downloadsByID[id] else {
      throw Error.missingDownload(id)
    }
    try finish(
      id: id,
      status: .failed,
      receivedBytes: download.receivedBytes,
      updatedAtMs: updatedAtMs
    )
  }

  // MARK: - AppHost manager

  public func acknowledge(
    _ acknowledgement: Service.Acknowledgement
  ) async throws {
    let previous = unacknowledgedIDs
    switch acknowledgement {
    case .all:
      unacknowledgedIDs.removeAll()
    case .ids(let ids):
      for id in ids {
        unacknowledgedIDs.remove(id)
      }
    }
    do {
      try persist()
    } catch {
      unacknowledgedIDs = previous
      throw error
    }
  }

  public func cancel(id: String) async throws
    -> Service.ActionResult
  {
    guard var download = downloadsByID[id],
      let task = activeTasks[id],
      download.status.isActive
    else {
      return .failure(reason: .missingDownload)
    }

    try await task.cancelOperation()
    let previous = download
    download.status = .canceled
    download.updatedAtMs = now()
    downloadsByID[id] = download
    activeTasks[id] = nil
    unacknowledgedIDs.insert(id)
    do {
      try persist()
    } catch {
      downloadsByID[id] = previous
      activeTasks[id] = task
      unacknowledgedIDs.remove(id)
      throw error
    }
    return .success
  }

  public func chooseDownloadDirectory() async throws -> String? {
    guard let selected = try await chooseDirectoryOperation()
    else {
      return nil
    }
    let canonical = try Self.canonicalURL(
      selected,
      under: downloadsDirectory,
      allowRoot: true
    )
    var isDirectory: ObjCBool = false
    guard
      FileManager.default.fileExists(
        atPath: canonical.path,
        isDirectory: &isDirectory
      ), isDirectory.boolValue
    else {
      throw Error.invalidDirectory(canonical.path)
    }
    return canonical.path
  }

  public func clearHistory() async throws {
    let previousDownloads = downloadsByID
    let previousUnacknowledged = unacknowledgedIDs
    downloadsByID = downloadsByID.filter {
      $0.value.status.isActive
    }
    unacknowledgedIDs.formIntersection(downloadsByID.keys)
    do {
      try persist()
    } catch {
      downloadsByID = previousDownloads
      unacknowledgedIDs = previousUnacknowledged
      throw error
    }
  }

  public func getSnapshot() async throws -> Service.Snapshot {
    snapshot(for: sortedDownloads())
  }

  public func open(id: String) async throws
    -> Service.ActionResult
  {
    guard let download = downloadsByID[id] else {
      return .failure(reason: .missingDownload)
    }
    let url = URL(fileURLWithPath: download.path)
    guard FileManager.default.fileExists(atPath: url.path)
    else {
      return .failure(
        reason: .openFailed,
        message: "Downloaded file is missing"
      )
    }
    return try await openURL(url)
      ? .success
      : .failure(reason: .openFailed)
  }

  public func pause(id: String) async throws
    -> Service.ActionResult
  {
    guard var download = downloadsByID[id] else {
      return .failure(reason: .missingDownload)
    }
    guard
      download.status == .started
        || download.status == .inProgress,
      let task = activeTasks[id],
      let pause = task.pauseOperation
    else {
      return .failure(reason: .downloadNotPausable)
    }

    try await pause()
    let previous = download
    download.status = .paused
    download.updatedAtMs = now()
    downloadsByID[id] = download
    do {
      try persist()
    } catch {
      downloadsByID[id] = previous
      throw error
    }
    return .success
  }

  public func removeFromHistory(id: String) async throws
    -> Service.ActionResult
  {
    guard let download = downloadsByID[id] else {
      return .failure(reason: .missingDownload)
    }
    guard !download.status.isActive else {
      return .failure(reason: .downloadNotRemovable)
    }

    downloadsByID[id] = nil
    let wasUnacknowledged = unacknowledgedIDs.remove(id) != nil
    do {
      try persist()
    } catch {
      downloadsByID[id] = download
      if wasUnacknowledged {
        unacknowledgedIDs.insert(id)
      }
      throw error
    }
    return .success
  }

  public func resume(id: String) async throws
    -> Service.ActionResult
  {
    guard var download = downloadsByID[id] else {
      return .failure(reason: .missingDownload)
    }
    guard download.status == .paused,
      let task = activeTasks[id],
      let resume = task.resumeOperation
    else {
      return .failure(reason: .downloadNotResumable)
    }

    try await resume()
    let previous = download
    download.status = .inProgress
    download.updatedAtMs = now()
    downloadsByID[id] = download
    do {
      try persist()
    } catch {
      downloadsByID[id] = previous
      throw error
    }
    return .success
  }

  public func searchHistory(
    _ request: Service.SearchRequest
  ) async throws -> Service.Snapshot {
    let query = request.text.trimmingCharacters(
      in: .whitespacesAndNewlines
    ).lowercased()
    let matches = sortedDownloads().filter { download in
      query.isEmpty
        || download.filename.lowercased().contains(query)
        || download.path.lowercased().contains(query)
        || download.url.lowercased().contains(query)
    }
    let offset = Self.clampedInt(request.offset ?? 0)
    guard offset < matches.count else {
      return snapshot(for: [])
    }
    let available = matches.count - offset
    let count = min(
      available,
      request.maxResults.map(Self.clampedInt)
        ?? available
    )
    return snapshot(
      for: Array(matches[offset..<(offset + count)])
    )
  }

  public func showDownloadsFolder() async throws
    -> Service.ActionResult
  {
    try await revealURL(downloadsDirectory)
      ? .success
      : .failure(reason: .showInFolderFailed)
  }

  public func showInFolder(id: String) async throws
    -> Service.ActionResult
  {
    guard let download = downloadsByID[id] else {
      return .failure(reason: .missingDownload)
    }
    let url = URL(fileURLWithPath: download.path)
    guard FileManager.default.fileExists(atPath: url.path)
    else {
      return .failure(
        reason: .showInFolderFailed,
        message: "Downloaded file is missing"
      )
    }
    return try await revealURL(url)
      ? .success
      : .failure(reason: .showInFolderFailed)
  }

  // MARK: - State

  private func finish(
    id: String,
    status: StoredStatus,
    receivedBytes: Int64,
    updatedAtMs: Int64?
  ) throws {
    guard var download = downloadsByID[id] else {
      throw Error.missingDownload(id)
    }
    guard activeTasks[id] != nil, download.status.isActive else {
      throw Error.inactiveDownload(id)
    }
    guard receivedBytes >= 0 else {
      throw Error.invalidByteCount
    }
    let previous = download
    let previousTask = activeTasks[id]
    let wasUnacknowledged = unacknowledgedIDs.contains(id)
    download.receivedBytes = receivedBytes
    download.status = status
    download.updatedAtMs = updatedAtMs ?? now()
    downloadsByID[id] = download
    activeTasks[id] = nil
    unacknowledgedIDs.insert(id)
    do {
      try persist()
    } catch {
      downloadsByID[id] = previous
      activeTasks[id] = previousTask
      if !wasUnacknowledged {
        unacknowledgedIDs.remove(id)
      }
      throw error
    }
  }

  private func snapshot(
    for downloads: [StoredDownload]
  ) -> Service.Snapshot {
    let visibleIDs = Set(downloads.map(\.id))
    return Service.Snapshot(
      capturedAtMs: now(),
      downloads: downloads.map(serviceDownload),
      unacknowledgedIDs:
        unacknowledgedIDs
        .intersection(visibleIDs)
        .sorted()
    )
  }

  private func serviceDownload(
    _ download: StoredDownload
  ) -> Service.Download {
    let task = activeTasks[download.id]
    let isRunning =
      download.status == .started
      || download.status == .inProgress
    return Service.Download(
      canCancel: download.status.isActive && task != nil,
      canPause: isRunning && task?.pauseOperation != nil,
      canResume:
        download.status == .paused
        && task?.resumeOperation != nil,
      fileExists: FileManager.default.fileExists(
        atPath: download.path
      ),
      filename: download.filename,
      id: download.id,
      path: download.path,
      receivedBytes: download.receivedBytes,
      startedAtMs: download.startedAtMs,
      status: download.status.serviceStatus,
      totalBytes: download.totalBytes,
      updatedAtMs: download.updatedAtMs,
      url: download.url
    )
  }

  private func sortedDownloads() -> [StoredDownload] {
    downloadsByID.values.sorted {
      if $0.updatedAtMs != $1.updatedAtMs {
        return $0.updatedAtMs > $1.updatedAtMs
      }
      return $0.id < $1.id
    }
  }

  private func persist() throws {
    let state = PersistedState(
      downloads: sortedDownloads(),
      unacknowledgedIDs: unacknowledgedIDs.sorted(),
      version: PersistedState.currentVersion
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(state)
    try data.write(to: persistenceURL, options: .atomic)
  }

  private static func canonicalURL(
    _ candidate: URL,
    under root: URL,
    allowRoot: Bool
  ) throws -> URL {
    guard candidate.isFileURL else {
      throw Error.pathOutsideDownloadsDirectory(
        candidate.absoluteString
      )
    }
    let canonicalRoot = root.resolvingSymlinksInPath()
    let canonicalCandidate = candidate
      .standardizedFileURL
      .resolvingSymlinksInPath()
    let rootComponents = canonicalRoot.pathComponents
    let candidateComponents = canonicalCandidate.pathComponents
    guard candidateComponents.starts(with: rootComponents),
      allowRoot || candidateComponents.count > rootComponents.count
    else {
      throw Error.pathOutsideDownloadsDirectory(
        canonicalCandidate.path
      )
    }
    return canonicalCandidate
  }

  private static func clampedInt(_ value: Int64) -> Int {
    guard value > 0 else {
      return 0
    }
    return value > Int64(Int.max) ? Int.max : Int(value)
  }
}
