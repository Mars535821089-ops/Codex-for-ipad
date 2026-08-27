import Foundation
import Testing
@testable import CodexPadApplication

private actor CallRecorder {
    private(set) var calls: [String] = []

    func append(_ call: String) {
        calls.append(call)
    }
}

@Test
@MainActor
func nativeSurfaceReviewActionsForwardToTheRealActionHandlers() async throws {
    let recorder = CallRecorder()
    let bridge = CodexNativeSurfaceActionBridge(
        revert: { cwd in
            await recorder.append("revert:\(cwd)")
            return .object(["status": .string("success")])
        },
        commit: { cwd, message in
            await recorder.append("commit:\(cwd):\(message)")
            return .object(["status": .string("success")])
        },
        terminal: { cwd, command in
            await recorder.append("terminal:\(cwd):\(command)")
            return .string("output")
        }
    )

    #expect(
        try await bridge.revert("/workspace")
            == .object(["status": .string("success")])
    )
    #expect(
        try await bridge.commit(
            "/workspace",
            "Commit reviewed changes"
        ) == .object(["status": .string("success")])
    )
    #expect(
        try await bridge.terminal(
            "/workspace",
            "printf hello"
        ) == .string("output")
    )
    #expect(
        await recorder.calls == [
            "revert:/workspace",
            "commit:/workspace:Commit reviewed changes",
            "terminal:/workspace:printf hello",
        ]
    )
}

@Test
@MainActor
func nativeSurfaceActionBridgeDoesNotHideBackendErrors() async throws {
    enum Failure: Error, Equatable { case backend }
    let bridge = CodexNativeSurfaceActionBridge(
        revert: { _ in throw Failure.backend },
        commit: { _, _ in throw Failure.backend },
        terminal: { _, _ in throw Failure.backend }
    )

    await #expect(throws: Failure.backend) {
        try await bridge.revert("/workspace")
    }
    await #expect(throws: Failure.backend) {
        try await bridge.commit("/workspace", "x")
    }
    await #expect(throws: Failure.backend) {
        try await bridge.terminal("/workspace", "true")
    }
}
