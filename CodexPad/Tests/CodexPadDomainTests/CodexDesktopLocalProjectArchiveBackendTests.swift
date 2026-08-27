import Foundation
import Testing

@testable import CodexPadApplication
@testable import CodexPadDomain
@testable import CodexPadProtocolBridge

private typealias ArchiveBackend =
  CodexDesktopLocalProjectArchiveBackend

private enum ArchiveMutatorProbeError: Swift.Error, Equatable {
  case archiveFailed
  case unexpectedMutation
}

private struct ArchiveMutation: Equatable {
  let id: CodexAppServerRequestID
  let threadID: CodexStoredThreadID
}

@MainActor
private final class ArchiveMutatorProbe:
  CodexDesktopThreadSessionMutating
{
  var archiveError: ArchiveMutatorProbeError?
  private(set) var archiveMutations: [ArchiveMutation] = []

  func archiveStoredThread(
    id: CodexAppServerRequestID,
    threadID: CodexStoredThreadID
  ) throws {
    archiveMutations.append(
      ArchiveMutation(id: id, threadID: threadID)
    )
    if let archiveError {
      throw archiveError
    }
  }

  func unarchiveStoredThread(
    id _: CodexAppServerRequestID,
    threadID _: CodexStoredThreadID
  ) throws -> CodexThreadUnarchiveResponse {
    throw ArchiveMutatorProbeError.unexpectedMutation
  }

  func deleteStoredThread(
    id _: CodexAppServerRequestID,
    threadID _: CodexStoredThreadID
  ) throws {
    throw ArchiveMutatorProbeError.unexpectedMutation
  }

  func rollbackStoredThread(
    id _: CodexAppServerRequestID,
    threadID _: CodexStoredThreadID,
    numTurns _: UInt32
  ) throws -> CodexThreadReadResult {
    throw ArchiveMutatorProbeError.unexpectedMutation
  }

  func revertStoredThread(
    id _: CodexAppServerRequestID,
    threadID _: CodexStoredThreadID,
    beforeTurnID _: String
  ) throws -> CodexThreadRevertResult {
    throw ArchiveMutatorProbeError.unexpectedMutation
  }

  func setStoredThreadName(
    id _: CodexAppServerRequestID,
    threadID _: CodexStoredThreadID,
    name _: String
  ) throws {
    throw ArchiveMutatorProbeError.unexpectedMutation
  }
}

@Test
@MainActor
func localProjectArchiveBackendArchivesTheRealStoredThread()
  async throws
{
  let mutator = ArchiveMutatorProbe()
  let backend = ArchiveBackend(threadMutator: mutator)

  let success = try await backend.threadArchiveHandler(
    .object([
      "hostId": .string("local"),
      "removeCatalogEntryIfMissing": .bool(true),
      "threadId": .string("thread/opaque-1"),
    ])
  )

  #expect(success)
  #expect(
    mutator.archiveMutations == [
      ArchiveMutation(
        id: .string(
          "app-host-thread-archive:local:thread/opaque-1"
        ),
        threadID: CodexStoredThreadID("thread/opaque-1")
      )
    ]
  )
}

@Test
@MainActor
func localProjectArchiveBackendRejectsRemoteAndMalformedRequests()
  async
{
  let mutator = ArchiveMutatorProbe()
  let backend = ArchiveBackend(threadMutator: mutator)

  await #expect(
    throws: ArchiveBackend.Error.unsupportedHostID("remote-1")
  ) {
    _ = try await backend.threadArchiveHandler(
      .object([
        "hostId": .string("remote-1"),
        "threadId": .string("thread-1"),
      ])
    )
  }

  await #expect(
    throws: ArchiveBackend.Error.invalidField("threadId")
  ) {
    _ = try await backend.threadArchiveHandler(
      .object([
        "hostId": .string("local"),
        "threadId": .string(" \n "),
      ])
    )
  }

  await #expect(
    throws: ArchiveBackend.Error.unexpectedFields(["success"])
  ) {
    _ = try await backend.threadArchiveHandler(
      .object([
        "hostId": .string("local"),
        "success": .bool(true),
        "threadId": .string("thread-1"),
      ])
    )
  }

  #expect(mutator.archiveMutations.isEmpty)
}

@Test
@MainActor
func localProjectArchiveBackendPropagatesArchiveFailure()
  async
{
  let mutator = ArchiveMutatorProbe()
  mutator.archiveError = .archiveFailed
  let backend = ArchiveBackend(threadMutator: mutator)

  await #expect(throws: ArchiveMutatorProbeError.archiveFailed) {
    _ = try await backend.threadArchiveHandler(
      .object([
        "hostId": .string("local"),
        "removeCatalogEntryIfMissing": .bool(false),
        "threadId": .string("thread-2"),
      ])
    )
  }

  #expect(mutator.archiveMutations.count == 1)
}
