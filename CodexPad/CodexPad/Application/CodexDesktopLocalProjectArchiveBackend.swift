import Foundation

#if SWIFT_PACKAGE
  import CodexPadDomain
  import CodexPadProtocolBridge
#endif

/// Connects the released AppHost `threadArchive` request to the app-server's
/// real persisted-thread mutation boundary.
///
/// The desktop renderer routes only the `local` host through this service.
/// Missing inactive-thread catalog entries remain an upstream concern: this
/// adapter reports success only after the injected app-server mutator returns.
@MainActor
public final class CodexDesktopLocalProjectArchiveBackend {
  public typealias Value = CodexDesktopAppHostRPC.Value

  public enum Error: Swift.Error, Equatable, Sendable {
    case expectedObject
    case invalidField(String)
    case unexpectedFields([String])
    case unsupportedHostID(String)
  }

  public static let localHostID = "local"

  private static let allowedFields: Set<String> = [
    "hostId",
    "removeCatalogEntryIfMissing",
    "threadId",
  ]

  private let threadMutator: any CodexDesktopThreadSessionMutating

  public init(
    threadMutator: any CodexDesktopThreadSessionMutating
  ) {
    self.threadMutator = threadMutator
  }

  /// Handler ready for `CodexDesktopProjectAppHostService`.
  public var threadArchiveHandler: CodexDesktopProjectAppHostService.ThreadArchiveHandler {
    { request in
      try await self.archive(request)
    }
  }

  /// Archives one service-normalized local thread request.
  ///
  /// The optional catalog-removal flag is type-checked but never converted
  /// into synthetic success. An app-server "thread not found" failure is
  /// propagated unchanged from the injected mutator.
  @discardableResult
  public func archive(_ request: Value) throws -> Bool {
    guard case .object(let fields) = request else {
      throw Error.expectedObject
    }

    let unexpectedFields = fields.keys
      .filter { !Self.allowedFields.contains($0) }
      .sorted()
    guard unexpectedFields.isEmpty else {
      throw Error.unexpectedFields(unexpectedFields)
    }

    let hostID = try Self.nonemptyString(
      fields["hostId"],
      field: "hostId"
    )
    guard hostID == Self.localHostID else {
      throw Error.unsupportedHostID(hostID)
    }

    let rawThreadID = try Self.nonemptyString(
      fields["threadId"],
      field: "threadId"
    )

    if let removeCatalogEntryIfMissing =
      fields["removeCatalogEntryIfMissing"]
    {
      guard case .bool = removeCatalogEntryIfMissing else {
        throw Error.invalidField(
          "removeCatalogEntryIfMissing"
        )
      }
    }

    let threadID = CodexStoredThreadID(rawThreadID)
    try threadMutator.archiveStoredThread(
      id: Self.requestID(for: threadID),
      threadID: threadID
    )
    return true
  }

  private static func requestID(
    for threadID: CodexStoredThreadID
  ) -> CodexAppServerRequestID {
    .string(
      "app-host-thread-archive:\(localHostID):\(threadID.rawValue)"
    )
  }

  private static func nonemptyString(
    _ value: Value?,
    field: String
  ) throws -> String {
    guard case .string(let string)? = value,
      !string.trimmingCharacters(
        in: .whitespacesAndNewlines
      ).isEmpty
    else {
      throw Error.invalidField(field)
    }
    return string
  }
}
