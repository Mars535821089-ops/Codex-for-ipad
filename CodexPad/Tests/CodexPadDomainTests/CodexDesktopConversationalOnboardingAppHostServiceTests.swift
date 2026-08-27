import Foundation
import Testing

@testable import CodexPadApplication

private typealias OnboardingValue = CodexDesktopAppHostRPC.Value

@Test
func conversationalOnboardingCreatesCollisionSafeDesktopNotes() async throws {
  let root = FileManager.default.temporaryDirectory
    .appendingPathComponent("codex-onboarding-\(UUID().uuidString)")
  try FileManager.default.createDirectory(
    at: root,
    withIntermediateDirectories: true
  )
  defer { try? FileManager.default.removeItem(at: root) }
  let existing = root.appendingPathComponent("note.txt")
  try Data("old".utf8).write(to: existing)
  let service = CodexDesktopConversationalOnboardingAppHostService(
    allowedWorkspaceRoots: [root]
  )

  let result = try await service.invoke(
    method: "createDesktopNote",
    arguments: [
      .object([
        "content": .string("new"),
        "fileStem": .string("note"),
        "parentPath": .string(root.path),
      ])
    ]
  )
  #expect(
    result
      == .object([
        "path": .string(root.appendingPathComponent("note (1).txt").path)
      ]))
  #expect(
    try String(
      contentsOf: root.appendingPathComponent("note (1).txt"),
      encoding: .utf8
    ) == "new"
  )
}

@Test
func conversationalOnboardingCreatesPngAndRejectsPathEscape() async throws {
  let root = FileManager.default.temporaryDirectory
    .appendingPathComponent("codex-onboarding-\(UUID().uuidString)")
  try FileManager.default.createDirectory(
    at: root,
    withIntermediateDirectories: true
  )
  defer { try? FileManager.default.removeItem(at: root) }
  let service = CodexDesktopConversationalOnboardingAppHostService(
    allowedWorkspaceRoots: [root]
  )

  let result = try await service.invoke(
    method: "createSampleChart",
    arguments: [
      .object([
        "bytes": .array([.integer(137), .integer(80), .integer(78), .integer(71)]),
        "fileStem": .string("chart"),
        "parentPath": .string(root.path),
      ])
    ]
  )
  #expect(
    result
      == .object([
        "path": .string(root.appendingPathComponent("chart.png").path)
      ]))
  #expect(
    try Data(contentsOf: root.appendingPathComponent("chart.png"))
      == Data([137, 80, 78, 71])
  )

  await #expect(throws: CodexDesktopConversationalOnboardingAppHostService.Error.invalidPath) {
    try await service.invoke(
      method: "createDesktopNote",
      arguments: [
        .object([
          "content": .string("escape"),
          "fileStem": .string("escape"),
          "parentPath": .string(root.appendingPathComponent("..").path),
        ])
      ]
    )
  }
}
