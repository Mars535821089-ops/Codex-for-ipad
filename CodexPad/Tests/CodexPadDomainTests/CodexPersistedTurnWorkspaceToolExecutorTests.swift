import CodexPadApplication
import CodexPadDomain
import Foundation
import Testing

@MainActor
@Test
func persistedWorkspaceToolExecutorRunsAllowedToolAndPreservesRawOutput()
  async throws
{
  let workspace = Workspace(
    id: UUID(),
    displayName: "Real workspace",
    rootBookmarkID: "bookmark/raw"
  )
  let request = persistedWorkspaceToolRequest(
    name: "read_workspace_file",
    arguments: #"{"path":"Sources/应用.swift"}"#,
    callID: " call/原样\\value "
  )
  let rawOutput =
    "{\n \"path\":\"Sources/应用.swift\","
    + "\"text\":\"line 1\\nline 2 / 原样\" }"
  var executions:
    [(name: String, arguments: String, workspace: Workspace)] = []
  var approvalCount = 0
  var activities: [CodexPersistedTurnWorkspaceToolActivity] = []
  var results: [CodexPersistedTurnWorkspaceToolResult] = []
  let executor = CodexPersistedTurnWorkspaceToolExecutor(
    policy: CodexExecutionPolicy(
      approvalPolicy: .onRequest,
      sandboxMode: .readOnly
    ),
    expectedWorkspacePath: "/real/project",
    workspace: workspace,
    execute: { name, arguments, workspace in
      executions.append((name, arguments, workspace))
      return rawOutput
    },
    resolveBookmark: { bookmark in
      #expect(bookmark == "bookmark/raw")
      return URL(fileURLWithPath: "/real/project", isDirectory: true)
    },
    approval: { _ in
      approvalCount += 1
      return true
    },
    onActivity: { activities.append($0) },
    onResult: { results.append($0) }
  )

  let output = try await executor.execute(
    request,
    cancellation: CodexTurnCancellation()
  )

  #expect(executions.count == 1)
  #expect(executions.first?.name == request.name)
  #expect(executions.first?.arguments == request.arguments)
  #expect(executions.first?.workspace == workspace)
  #expect(approvalCount == 0)
  #expect(activities == [
    .init(request: request, decision: .allow)
  ])
  #expect(results == [
    .init(
      request: request,
      decision: .allow,
      output: rawOutput,
      itemJSON: output.itemJSON
    )
  ])

  let item = try persistedWorkspaceToolOutputObject(output.itemJSON)
  #expect(item["type"] as? String == "function_call_output")
  #expect(item["call_id"] as? String == request.callID)
  #expect(item["output"] as? String == rawOutput)
  #expect(output.workspaceDiff == nil)
}

@MainActor
@Test
func persistedWorkspaceToolExecutorExposesOnlySuccessfulWriteDiff()
  async throws
{
  let workspace = persistedWorkspaceFixture()
  let diff =
    "--- a/README.md\n"
    + "+++ b/README.md\n"
    + "@@ -1 +1 @@\n"
    + "-old\n"
    + "+new\n"
  let successfulWrite = CodexPersistedTurnWorkspaceToolExecutor(
    policy: CodexExecutionPolicy(
      approvalPolicy: .never,
      sandboxMode: .workspaceWrite
    ),
    expectedWorkspacePath: "/real/project",
    workspace: workspace,
    execute: { _, _, _ in
      let data = try JSONSerialization.data(
        withJSONObject: [
          "path": "README.md",
          "bytesWritten": 4,
          "diff": diff,
        ],
        options: [.sortedKeys]
      )
      return String(decoding: data, as: UTF8.self)
    },
    resolveBookmark: persistedWorkspaceResolver,
    approval: { _ in true }
  )
  let readReturningADiffField = CodexPersistedTurnWorkspaceToolExecutor(
    policy: CodexExecutionPolicy(
      approvalPolicy: .never,
      sandboxMode: .readOnly
    ),
    expectedWorkspacePath: "/real/project",
    workspace: workspace,
    execute: { _, _, _ in #"{"diff":"not a write"}"# },
    resolveBookmark: persistedWorkspaceResolver,
    approval: { _ in true }
  )

  let writeOutput = try await successfulWrite.execute(
    persistedWorkspaceToolRequest(
      name: "write_workspace_file",
      arguments: #"{"path":"README.md","text":"new"}"#
    ),
    cancellation: CodexTurnCancellation()
  )
  let readOutput = try await readReturningADiffField.execute(
    persistedWorkspaceToolRequest(
      name: "read_workspace_file",
      arguments: #"{"path":"README.md"}"#
    ),
    cancellation: CodexTurnCancellation()
  )

  #expect(writeOutput.workspaceDiff == diff)
  #expect(readOutput.workspaceDiff == nil)
}

@MainActor
@Test
func persistedWorkspaceToolExecutorEmitsCustomApplyPatchOutput()
  async throws
{
  let rawOutput =
    "Success. Updated the following files:\n"
    + "M Sources/App.swift"
  let request = persistedWorkspaceToolRequest(
    name: "apply_patch",
    arguments: """
      *** Begin Patch
      *** Update File: Sources/App.swift
      @@
      -old
      +new
      *** End Patch
      """,
    callID: "patch-call",
    itemJSON: """
      {"type":"custom_tool_call","call_id":"patch-call",\
      "name":"apply_patch","input":"patch"}
      """
  )
  let executor = CodexPersistedTurnWorkspaceToolExecutor(
    policy: CodexExecutionPolicy(
      approvalPolicy: .never,
      sandboxMode: .workspaceWrite
    ),
    expectedWorkspacePath: "/real/project",
    workspace: persistedWorkspaceFixture(),
    execute: { name, arguments, _ in
      #expect(name == "apply_patch")
      #expect(arguments == request.arguments)
      return rawOutput
    },
    resolveBookmark: persistedWorkspaceResolver,
    approval: { _ in true }
  )

  let output = try await executor.execute(
    request,
    cancellation: CodexTurnCancellation()
  )
  let item = try persistedWorkspaceToolOutputObject(output.itemJSON)

  #expect(item["type"] as? String == "custom_tool_call_output")
  #expect(item["call_id"] as? String == request.callID)
  #expect(item["output"] as? String == rawOutput)
  #expect(item["name"] == nil)
}

@MainActor
@Test
func persistedWorkspaceToolExecutorUsesRequestItemTypeForApplyPatchOutput()
  async throws
{
  let request = persistedWorkspaceToolRequest(
    name: "apply_patch",
    arguments: "*** Begin Patch\n*** End Patch\n",
    callID: "legacy-function-call",
    itemJSON: """
      {"type":"function_call","call_id":"legacy-function-call",\
      "name":"apply_patch","arguments":"patch"}
      """
  )
  let executor = CodexPersistedTurnWorkspaceToolExecutor(
    policy: CodexExecutionPolicy(
      approvalPolicy: .never,
      sandboxMode: .workspaceWrite
    ),
    expectedWorkspacePath: "/real/project",
    workspace: persistedWorkspaceFixture(),
    execute: { _, _, _ in "legacy output" },
    resolveBookmark: persistedWorkspaceResolver,
    approval: { _ in true }
  )

  let output = try await executor.execute(
    request,
    cancellation: CodexTurnCancellation()
  )
  let item = try persistedWorkspaceToolOutputObject(output.itemJSON)

  #expect(item["type"] as? String == "function_call_output")
  #expect(item["call_id"] as? String == request.callID)
  #expect(item["output"] as? String == "legacy output")
}

@MainActor
@Test
func persistedWorkspaceToolExecutorProjectsRealApplyPatchDiff()
  async throws
{
  let root = FileManager.default.temporaryDirectory
    .appending(path: UUID().uuidString, directoryHint: .isDirectory)
  try FileManager.default.createDirectory(
    at: root,
    withIntermediateDirectories: true
  )
  defer { try? FileManager.default.removeItem(at: root) }
  let target = root.appending(path: "README.md")
  try Data("old\n".utf8).write(to: target)

  let access = CodexWorkspaceAccess()
  let workspace = Workspace(
    id: UUID(),
    displayName: "Patch workspace",
    rootBookmarkID: try access.bookmark(for: root)
  )
  let executor = CodexPersistedTurnWorkspaceToolExecutor(
    policy: CodexExecutionPolicy(
      approvalPolicy: .never,
      sandboxMode: .workspaceWrite
    ),
    expectedWorkspacePath: root.path,
    workspace: workspace,
    runner: CodexWorkspaceToolRunner(access: access),
    approval: { _ in true }
  )
  let request = persistedWorkspaceToolRequest(
    name: "apply_patch",
    arguments: """
      *** Begin Patch
      *** Update File: README.md
      @@
      -old
      +new
      *** End Patch
      """,
    callID: "patch-real",
    itemJSON: """
      {"type":"custom_tool_call","call_id":"patch-real",\
      "name":"apply_patch","input":"patch"}
      """
  )

  let output = try await executor.execute(
    request,
    cancellation: CodexTurnCancellation()
  )
  let item = try persistedWorkspaceToolOutputObject(output.itemJSON)

  #expect(item["type"] as? String == "custom_tool_call_output")
  #expect(
    item["output"] as? String
      == "Success. Updated the following files:\nM README.md\n"
  )
  #expect(try String(contentsOf: target, encoding: .utf8) == "new\n")
  let diff = try #require(output.workspaceDiff)
  #expect(diff.contains("--- a/README.md\n+++ b/README.md"))
  #expect(diff.contains("-old\n+new"))
  let changes = try #require(output.fileChanges)
  #expect(changes.count == 1)
  #expect(changes[0].path == "README.md")
  #expect(changes[0].kind == .update(movePath: nil))
  #expect(changes[0].diff == diff)
}

@MainActor
@Test
func persistedWorkspaceToolExecutorReturnsDeniedOutputWhenApprovalRejects()
  async throws
{
  let workspace = persistedWorkspaceFixture()
  let request = persistedWorkspaceToolRequest(
    name: "write_workspace_file",
    arguments: #"{"path":"README.md","text":"changed"}"#
  )
  var executionCount = 0
  var approvals: [CodexPersistedTurnWorkspaceToolActivity] = []
  var results: [CodexPersistedTurnWorkspaceToolResult] = []
  let executor = CodexPersistedTurnWorkspaceToolExecutor(
    policy: CodexExecutionPolicy(
      approvalPolicy: .onRequest,
      sandboxMode: .workspaceWrite
    ),
    expectedWorkspacePath: "/real/project",
    workspace: workspace,
    execute: { _, _, _ in
      executionCount += 1
      return #"{"unexpected":true}"#
    },
    resolveBookmark: persistedWorkspaceResolver,
    approval: {
      approvals.append($0)
      return false
    },
    onResult: { results.append($0) }
  )

  let output = try await executor.execute(
    request,
    cancellation: CodexTurnCancellation()
  )

  #expect(executionCount == 0)
  #expect(approvals == [
    .init(request: request, decision: .requireApproval)
  ])
  let object = try persistedWorkspaceToolOutputObject(output.itemJSON)
  #expect(
    object["output"] as? String
      == #"{"error":"workspace change denied"}"#
  )
  #expect(results.count == 1)
  #expect(results.first?.decision == .requireApproval)
  #expect(results.first?.itemJSON == output.itemJSON)
  #expect(output.workspaceDiff == nil)
}

@MainActor
@Test
func persistedWorkspaceToolExecutorRunsWriteOnlyAfterApprovalAccepts()
  async throws
{
  let workspace = persistedWorkspaceFixture()
  let request = persistedWorkspaceToolRequest(
    name: "write_workspace_file",
    arguments: #"{"path":"README.md","text":"changed"}"#
  )
  var executionCount = 0
  var approvalCount = 0
  let executor = CodexPersistedTurnWorkspaceToolExecutor(
    policy: CodexExecutionPolicy(
      approvalPolicy: .untrusted,
      sandboxMode: .workspaceWrite
    ),
    expectedWorkspacePath: "/real/project/",
    workspace: workspace,
    execute: { _, _, _ in
      executionCount += 1
      return #"{"path":"README.md","bytesWritten":7}"#
    },
    resolveBookmark: persistedWorkspaceResolver,
    approval: { activity in
      approvalCount += 1
      #expect(activity.request == request)
      #expect(activity.decision == .requireApproval)
      return true
    }
  )

  let output = try await executor.execute(
    request,
    cancellation: CodexTurnCancellation()
  )

  #expect(approvalCount == 1)
  #expect(executionCount == 1)
  let object = try persistedWorkspaceToolOutputObject(output.itemJSON)
  #expect(
    object["output"] as? String
      == #"{"path":"README.md","bytesWritten":7}"#
  )
}

@MainActor
@Test
func persistedWorkspaceToolExecutorReturnsSandboxOutputForDeniedTool()
  async throws
{
  let request = persistedWorkspaceToolRequest(
    name: "write_workspace_file"
  )
  var executionCount = 0
  var approvalCount = 0
  var activities: [CodexPersistedTurnWorkspaceToolActivity] = []
  var results: [CodexPersistedTurnWorkspaceToolResult] = []
  let executor = CodexPersistedTurnWorkspaceToolExecutor(
    policy: CodexExecutionPolicy(
      approvalPolicy: .never,
      sandboxMode: .readOnly
    ),
    expectedWorkspacePath: "/real/project",
    workspace: persistedWorkspaceFixture(),
    execute: { _, _, _ in
      executionCount += 1
      return #"{"unexpected":true}"#
    },
    resolveBookmark: persistedWorkspaceResolver,
    approval: { _ in
      approvalCount += 1
      return true
    },
    onActivity: { activities.append($0) },
    onResult: { results.append($0) }
  )

  let output = try await executor.execute(
    request,
    cancellation: CodexTurnCancellation()
  )

  #expect(executionCount == 0)
  #expect(approvalCount == 0)
  #expect(activities == [
    .init(request: request, decision: .deny)
  ])
  let object = try persistedWorkspaceToolOutputObject(output.itemJSON)
  #expect(
    object["output"] as? String
      == #"{"error":"blocked by sandbox policy"}"#
  )
  #expect(results.first?.decision == .deny)
  #expect(results.first?.output == #"{"error":"blocked by sandbox policy"}"#)
}

@MainActor
@Test
func persistedWorkspaceToolExecutorReturnsExecutionFailureAsToolOutput()
  async throws
{
  let request = persistedWorkspaceToolRequest(
    name: "read_workspace_file",
    arguments: #"{"missing":"path"}"#
  )
  var results: [CodexPersistedTurnWorkspaceToolResult] = []
  let executor = CodexPersistedTurnWorkspaceToolExecutor(
    policy: CodexExecutionPolicy(
      approvalPolicy: .never,
      sandboxMode: .workspaceWrite
    ),
    expectedWorkspacePath: "/real/project",
    workspace: persistedWorkspaceFixture(),
    execute: { _, _, _ in
      throw CodexWorkspaceToolError.invalidArguments
    },
    resolveBookmark: persistedWorkspaceResolver,
    approval: { _ in true },
    onResult: { results.append($0) }
  )

  let output = try await executor.execute(
    request,
    cancellation: CodexTurnCancellation()
  )

  let object = try persistedWorkspaceToolOutputObject(output.itemJSON)
  #expect(
    object["output"] as? String
      == #"{"error":"workspace tool execution failed"}"#
  )
  #expect(
    results.first?.output
      == #"{"error":"workspace tool execution failed"}"#
  )
}

@MainActor
@Test
func persistedWorkspaceToolExecutorRejectsUnavailableWorkspaceStates()
  async
{
  let policy = CodexExecutionPolicy(
    approvalPolicy: .never,
    sandboxMode: .workspaceWrite
  )
  let noWorkspace = CodexPersistedTurnWorkspaceToolExecutor(
    policy: policy,
    expectedWorkspacePath: "/real/project",
    workspace: nil,
    execute: persistedUnexpectedWorkspaceExecution,
    resolveBookmark: persistedUnexpectedBookmarkResolution,
    approval: { _ in true }
  )
  let noBookmark = CodexPersistedTurnWorkspaceToolExecutor(
    policy: policy,
    expectedWorkspacePath: "/real/project",
    workspace: persistedWorkspaceFixture(bookmark: nil),
    execute: persistedUnexpectedWorkspaceExecution,
    resolveBookmark: persistedUnexpectedBookmarkResolution,
    approval: { _ in true }
  )
  let unresolvedBookmark = CodexPersistedTurnWorkspaceToolExecutor(
    policy: policy,
    expectedWorkspacePath: "/real/project",
    workspace: persistedWorkspaceFixture(),
    execute: persistedUnexpectedWorkspaceExecution,
    resolveBookmark: { _ in
      throw CodexWorkspaceAccessError.invalidBookmark
    },
    approval: { _ in true }
  )
  let mismatchedWorkspace =
    CodexPersistedTurnWorkspaceToolExecutor(
      policy: policy,
      expectedWorkspacePath: "/real/project",
      workspace: persistedWorkspaceFixture(),
      execute: persistedUnexpectedWorkspaceExecution,
      resolveBookmark: { _ in
        URL(fileURLWithPath: "/other/project", isDirectory: true)
      },
      approval: { _ in true }
    )

  for executor in [
    noWorkspace,
    noBookmark,
    unresolvedBookmark,
    mismatchedWorkspace,
  ] {
    await expectPersistedWorkspaceUnavailable(executor)
  }
}

@MainActor
@Test
func persistedWorkspaceToolExecutorAllowsTurnCWDInsideBookmarkRoot()
  async throws
{
  var executionCount = 0
  let executor = CodexPersistedTurnWorkspaceToolExecutor(
    policy: CodexExecutionPolicy(
      approvalPolicy: .never,
      sandboxMode: .workspaceWrite
    ),
    expectedWorkspacePath: "/real/project/packages/app",
    workspace: persistedWorkspaceFixture(),
    execute: { _, _, _ in
      executionCount += 1
      return #"{"path":"README.md","text":"contents"}"#
    },
    resolveBookmark: persistedWorkspaceResolver,
    approval: { _ in true }
  )

  let output = try await executor.execute(
    persistedWorkspaceToolRequest(
      name: "read_workspace_file",
      arguments: #"{"path":"README.md"}"#
    ),
    cancellation: CodexTurnCancellation()
  )

  #expect(executionCount == 1)
  let object = try persistedWorkspaceToolOutputObject(output.itemJSON)
  #expect(
    object["output"] as? String
      == #"{"path":"README.md","text":"contents"}"#
  )
}

@MainActor
@Test
func persistedWorkspaceToolExecutorRejectsSiblingWithSharedRootPrefix()
  async
{
  let executor = CodexPersistedTurnWorkspaceToolExecutor(
    policy: CodexExecutionPolicy(
      approvalPolicy: .never,
      sandboxMode: .workspaceWrite
    ),
    expectedWorkspacePath: "/real/project-copy",
    workspace: persistedWorkspaceFixture(),
    execute: persistedUnexpectedWorkspaceExecution,
    resolveBookmark: persistedWorkspaceResolver,
    approval: { _ in true }
  )

  await expectPersistedWorkspaceUnavailable(executor)
}

@MainActor
@Test
func persistedWorkspaceToolExecutorRejectsRelativeExpectedWorkspacePath()
  async
{
  let currentDirectory = URL(
    fileURLWithPath: FileManager.default.currentDirectoryPath,
    isDirectory: true
  )
  let executor = CodexPersistedTurnWorkspaceToolExecutor(
    policy: CodexExecutionPolicy(
      approvalPolicy: .never,
      sandboxMode: .workspaceWrite
    ),
    expectedWorkspacePath: ".",
    workspace: persistedWorkspaceFixture(),
    execute: persistedUnexpectedWorkspaceExecution,
    resolveBookmark: { _ in currentDirectory },
    approval: { _ in true }
  )

  await expectPersistedWorkspaceUnavailable(executor)
}

@MainActor
@Test
func persistedWorkspaceToolExecutorPropagatesRunnerWorkspaceUnavailable()
  async
{
  let executor = CodexPersistedTurnWorkspaceToolExecutor(
    policy: CodexExecutionPolicy(
      approvalPolicy: .never,
      sandboxMode: .workspaceWrite
    ),
    expectedWorkspacePath: "/real/project",
    workspace: persistedWorkspaceFixture(),
    execute: { _, _, _ in
      throw CodexWorkspaceToolError.unavailableWorkspace
    },
    resolveBookmark: persistedWorkspaceResolver,
    approval: { _ in true }
  )

  await expectPersistedWorkspaceUnavailable(executor)
}

@MainActor
@Test
func persistedWorkspaceToolExecutorMapsLostBookmarkAccessToUnavailable()
  async
{
  for runnerError in [
    CodexWorkspaceAccessError.invalidBookmark,
    CodexWorkspaceAccessError.accessDenied,
  ] {
    let executor = CodexPersistedTurnWorkspaceToolExecutor(
      policy: CodexExecutionPolicy(
        approvalPolicy: .never,
        sandboxMode: .workspaceWrite
      ),
      expectedWorkspacePath: "/real/project",
      workspace: persistedWorkspaceFixture(),
      execute: { _, _, _ in throw runnerError },
      resolveBookmark: persistedWorkspaceResolver,
      approval: { _ in true }
    )

    await expectPersistedWorkspaceUnavailable(executor)
  }
}

@MainActor
@Test
func persistedWorkspaceToolExecutorRunsRealWorkspaceRunner()
  async throws
{
  let root = FileManager.default.temporaryDirectory
    .appending(path: UUID().uuidString, directoryHint: .isDirectory)
  try FileManager.default.createDirectory(
    at: root,
    withIntermediateDirectories: true
  )
  defer { try? FileManager.default.removeItem(at: root) }
  try Data("real contents".utf8).write(
    to: root.appending(path: "README.md")
  )
  let access = CodexWorkspaceAccess()
  let workspace = Workspace(
    id: UUID(),
    displayName: "Real workspace",
    rootBookmarkID: try access.bookmark(for: root)
  )
  let executor = CodexPersistedTurnWorkspaceToolExecutor(
    policy: CodexExecutionPolicy(
      approvalPolicy: .onRequest,
      sandboxMode: .readOnly
    ),
    expectedWorkspacePath: root.path,
    workspace: workspace,
    runner: CodexWorkspaceToolRunner(access: access),
    approval: { activity in
      Issue.record(
        "Unexpected approval for \(activity.request.name)"
      )
      return false
    }
  )

  let output = try await executor.execute(
    persistedWorkspaceToolRequest(
      name: "read_workspace_file",
      arguments: #"{"path":"README.md"}"#
    ),
    cancellation: CodexTurnCancellation()
  )

  let item = try persistedWorkspaceToolOutputObject(output.itemJSON)
  let rawOutput = try #require(item["output"] as? String)
  let runnerObject = try #require(
    JSONSerialization.jsonObject(with: Data(rawOutput.utf8))
      as? [String: Any]
  )
  #expect(runnerObject["path"] as? String == "README.md")
  #expect(runnerObject["text"] as? String == "real contents")
}

@MainActor
@Test
func persistedWorkspaceToolExecutorStopsAfterCancellationDuringApproval()
  async
{
  let cancellation = CodexTurnCancellation()
  var executionCount = 0
  var resultCount = 0
  let executor = CodexPersistedTurnWorkspaceToolExecutor(
    policy: CodexExecutionPolicy(
      approvalPolicy: .onRequest,
      sandboxMode: .workspaceWrite
    ),
    expectedWorkspacePath: "/real/project",
    workspace: persistedWorkspaceFixture(),
    execute: { _, _, _ in
      executionCount += 1
      return "{}"
    },
    resolveBookmark: persistedWorkspaceResolver,
    approval: { _ in
      cancellation.cancel()
      return true
    },
    onResult: { _ in resultCount += 1 }
  )

  do {
    _ = try await executor.execute(
      persistedWorkspaceToolRequest(name: "write_workspace_file"),
      cancellation: cancellation
    )
    #expect(Bool(false), "Expected cancellation")
  } catch {
    #expect(error is CancellationError)
  }
  #expect(executionCount == 0)
  #expect(resultCount == 0)
}

private func persistedWorkspaceToolRequest(
  name: String,
  arguments: String = "{}",
  callID: String = "call-1",
  itemJSON: String = #"{"type":"function_call"}"#
) -> CodexPersistedTurnToolRequest {
  CodexPersistedTurnToolRequest(
    threadID: CodexStoredThreadID("thread/raw"),
    turnID: "turn/raw",
    roundIndex: 0,
    name: name,
    arguments: arguments,
    callID: callID,
    itemJSON: itemJSON
  )
}

private func persistedWorkspaceFixture(
  bookmark: String? = "bookmark/raw"
) -> Workspace {
  Workspace(
    id: UUID(),
    displayName: "Real workspace",
    rootBookmarkID: bookmark
  )
}

private func persistedWorkspaceResolver(_ bookmark: String) throws -> URL {
  #expect(bookmark == "bookmark/raw")
  return URL(fileURLWithPath: "/real/project", isDirectory: true)
}

private func persistedUnexpectedBookmarkResolution(
  _ bookmark: String
) throws -> URL {
  Issue.record("Unexpected bookmark resolution for \(bookmark)")
  return URL(fileURLWithPath: "/unexpected", isDirectory: true)
}

private func persistedUnexpectedWorkspaceExecution(
  name: String,
  arguments: String,
  workspace: Workspace
) throws -> String {
  Issue.record(
    "Unexpected execution of \(name) \(arguments) in \(workspace.displayName)"
  )
  return "{}"
}

@MainActor
private func expectPersistedWorkspaceUnavailable(
  _ executor: CodexPersistedTurnWorkspaceToolExecutor
) async {
  do {
    _ = try await executor.execute(
      persistedWorkspaceToolRequest(name: "read_workspace_file"),
      cancellation: CodexTurnCancellation()
    )
    #expect(Bool(false), "Expected unavailable workspace")
  } catch {
    #expect(
      error as? CodexWorkspaceToolError
        == CodexWorkspaceToolError.unavailableWorkspace
    )
  }
}

private func persistedWorkspaceToolOutputObject(
  _ itemJSON: String
) throws -> [String: Any] {
  try #require(
    JSONSerialization.jsonObject(with: Data(itemJSON.utf8))
      as? [String: Any]
  )
}
