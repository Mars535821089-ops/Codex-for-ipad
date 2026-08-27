import Foundation
import Testing
@testable import CodexPadApplication
@testable import CodexPadDomain

@MainActor
@Test
func requestPermissionsExecutorTranslatesApprovalAndPersistsTurnGrant() async throws {
  let store = CodexPersistedTurnPermissionGrantStore()
  var approvals: [CodexDesktopApprovalRequest] = []
  let executor = CodexPersistedTurnRequestPermissionsExecutor(
    cwd: "/workspace/App",
    grantStore: store,
    prompt: { approval in
      approvals.append(approval)
      return .object([
        "permissions": .object([
          "network": .object(["enabled": .bool(true)]),
          "fileSystem": .object([
            "read": .array([.string("/external/read")]),
            "write": .array([.string("/external/write")]),
          ]),
        ]),
        "scope": .string("turn"),
        "strictAutoReview": .bool(true),
      ])
    }
  )

  let output = try await executor.execute(
    CodexPersistedTurnToolRequest(
      threadID: CodexStoredThreadID("thread-1"),
      turnID: "turn-1",
      roundIndex: 1,
      name: "request_permissions",
      arguments: """
      {"reason":"Need generated assets","environment_id":"env-1",\
      "permissions":{"network":{"enabled":true},"file_system":{\
      "read":["/external/read"],"write":["/external/write"]}}}
      """,
      callID: "call-1",
      itemJSON: "{}"
    ),
    cancellation: CodexTurnCancellation()
  )

  #expect(approvals.count == 1)
  #expect(
    approvals[0]
      == .permissions(
        threadID: "thread-1",
        turnID: "turn-1",
        itemID: "call-1",
        environmentID: "env-1",
        startedAtMs: approvals[0].startedAtMsForTesting,
        cwd: "/workspace/App",
        reason: "Need generated assets",
        permissions: .object([
          "network": .object(["enabled": .bool(true)]),
          "fileSystem": .object([
            "read": .array([.string("/external/read")]),
            "write": .array([.string("/external/write")]),
          ]),
        ])
      )
  )
  #expect(output.itemJSON.contains(#""call_id":"call-1""#))
  #expect(output.itemJSON.contains(#"\"scope\":\"turn\""#))

  let grant = store.grant(threadID: "thread-1", turnID: "turn-1")
  #expect(grant.networkEnabled)
  #expect(grant.readRoots == ["/external/read"])
  #expect(grant.writeRoots == ["/external/write"])
  #expect(grant.strictAutoReview)
}

@MainActor
@Test
func requestPermissionsExecutorRejectsMalformedArgumentsBeforePrompt() async {
  var promptCount = 0
  let executor = CodexPersistedTurnRequestPermissionsExecutor(
    cwd: "/workspace/App",
    grantStore: CodexPersistedTurnPermissionGrantStore(),
    prompt: { _ in
      promptCount += 1
      return nil
    }
  )

  await #expect(throws: CodexPersistedTurnRequestPermissionsError.invalidArguments) {
    _ = try await executor.execute(
      CodexPersistedTurnToolRequest(
        threadID: CodexStoredThreadID("thread-1"),
        turnID: "turn-1",
        roundIndex: 1,
        name: "request_permissions",
        arguments: #"{"permissions":{"file_system":{"write":[""]}}}"#,
        callID: "call-1",
        itemJSON: "{}"
      ),
      cancellation: CodexTurnCancellation()
    )
  }
  #expect(promptCount == 0)
}

private extension CodexDesktopApprovalRequest {
  var startedAtMsForTesting: Int64 {
    guard case let .object(fields) = params,
      case let .integer(value)? = fields["startedAtMs"]
    else {
      return -1
    }
    return value
  }
}
