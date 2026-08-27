import CodexPadApplication
import CodexPadDomain
import Foundation
import Testing

@MainActor
@Test
func viewImageExecutorReturnsStructuredInputImageOutput() async throws {
  let root = FileManager.default.temporaryDirectory
    .appendingPathComponent("view-image-test-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: root) }
  let imageURL = root.appendingPathComponent("frame.png")
  try Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00]).write(to: imageURL)

  let request = CodexPersistedTurnToolRequest(
    threadID: CodexStoredThreadID("thread-view-image"),
    turnID: "turn-1",
    roundIndex: 0,
    name: "view_image",
    arguments: #"{"path":"frame.png"}"#,
    callID: "call-view-image",
    itemJSON: "{}"
  )
  let output = try await CodexPersistedTurnViewImageExecutor(workspaceRoot: root).execute(
    request,
    cancellation: CodexTurnCancellation()
  )

  let object = try #require(JSONSerialization.jsonObject(with: Data(output.itemJSON.utf8)) as? [String: Any])
  #expect(object["type"] as? String == "function_call_output")
  #expect(object["call_id"] as? String == request.callID)
  let contents = try #require(object["output"] as? [[String: Any]])
  #expect(contents.count == 1)
  #expect(contents[0]["type"] as? String == "input_image")
  #expect(contents[0]["detail"] as? String == "high")
  #expect((contents[0]["image_url"] as? String)?.hasPrefix("data:image/png;base64,") == true)
  #expect(output.workspaceDiff == nil)
}

@MainActor
@Test
func viewImageExecutorKeepsOriginalDetailWhenCapabilityIsAvailable() async throws {
  let root = FileManager.default.temporaryDirectory
    .appendingPathComponent("view-image-original-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: root) }
  try Data([0xff, 0xd8, 0xff, 0x00]).write(to: root.appendingPathComponent("frame.jpg"))

  let request = CodexPersistedTurnToolRequest(
    threadID: CodexStoredThreadID("thread-view-image"), turnID: "turn-1", roundIndex: 0,
    name: "view_image", arguments: #"{"path":"frame.jpg","detail":"original"}"#,
    callID: "call-original", itemJSON: "{}"
  )
  let output = try await CodexPersistedTurnViewImageExecutor(
    workspaceRoot: root, supportsOriginalDetail: true
  ).execute(request, cancellation: CodexTurnCancellation())
  let object = try #require(JSONSerialization.jsonObject(with: Data(output.itemJSON.utf8)) as? [String: Any])
  let contents = try #require(object["output"] as? [[String: Any]])
  #expect(contents[0]["detail"] as? String == "original")
  #expect((contents[0]["image_url"] as? String)?.hasPrefix("data:image/jpeg;base64,") == true)
}

@MainActor
@Test
func viewImageExecutorRejectsInvalidDetailOutsidePathAndNonImage() async throws {
  let root = FileManager.default.temporaryDirectory
    .appendingPathComponent("view-image-errors-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: root) }
  try Data("not an image".utf8).write(to: root.appendingPathComponent("notes.txt"))
  let executor = CodexPersistedTurnViewImageExecutor(workspaceRoot: root)

  do {
    _ = try await executor.execute(viewImageRequest(path: "notes.txt", detail: "low"), cancellation: CodexTurnCancellation())
    Issue.record("invalid detail should throw")
  } catch let error as CodexPersistedTurnViewImageError {
    #expect(error == .unsupportedDetail("low"))
  }
  do {
    _ = try await executor.execute(viewImageRequest(path: "notes.txt"), cancellation: CodexTurnCancellation())
    Issue.record("non-image should throw")
  } catch let error as CodexPersistedTurnViewImageError {
    #expect(error == .unsupportedImageType)
  }
  do {
    _ = try await executor.execute(viewImageRequest(path: "../notes.txt"), cancellation: CodexTurnCancellation())
    Issue.record("outside path should throw")
  } catch let error as CodexPersistedTurnViewImageError {
    #expect(error == .pathOutsideWorkspace)
  }
}

private func viewImageRequest(path: String, detail: String? = nil) -> CodexPersistedTurnToolRequest {
  let detailJSON = detail.map { ",\"detail\":\"\($0)\"" } ?? ""
  return CodexPersistedTurnToolRequest(
    threadID: CodexStoredThreadID("thread-view-image"), turnID: "turn-1", roundIndex: 0,
    name: "view_image", arguments: "{\"path\":\"\(path)\"\(detailJSON)}",
    callID: "call-error", itemJSON: "{}"
  )
}
