import Foundation
import Testing

@testable import CodexPadApplication
@testable import CodexPadDomain
@testable import CodexPadProtocolBridge

@Test
func memoryResetClearsBothOfficialRootsAndPreservesDirectories() throws {
    let home = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: home) }
    let memories = home.appendingPathComponent(
        "memories",
        isDirectory: true
    )
    let extensions = home.appendingPathComponent(
        "memories_extensions",
        isDirectory: true
    )
    try FileManager.default.createDirectory(
        at: memories.appendingPathComponent(
            "rollout_summaries",
            isDirectory: true
        ),
        withIntermediateDirectories: true
    )
    try Data("index".utf8).write(
        to: memories.appendingPathComponent("MEMORY.md")
    )
    try Data("rollout".utf8).write(
        to: memories.appendingPathComponent(
            "rollout_summaries/one.md"
        )
    )
    try FileManager.default.createDirectory(
        at: extensions,
        withIntermediateDirectories: true
    )
    try Data("extension".utf8).write(
        to: extensions.appendingPathComponent("extension.md")
    )

    try CodexDesktopMemoryResetService(
        codexHome: home
    ).resetMemory()

    for root in [memories, extensions] {
        var isDirectory: ObjCBool = false
        #expect(
            FileManager.default.fileExists(
                atPath: root.path,
                isDirectory: &isDirectory
            )
        )
        #expect(isDirectory.boolValue)
        #expect(
            try FileManager.default.contentsOfDirectory(
                atPath: root.path
            ).isEmpty
        )
    }
}

@Test
func memoryResetRejectsSymlinkedRootWithoutTouchingTarget() throws {
    let home = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: home) }
    let target = home.appendingPathComponent(
        "outside",
        isDirectory: true
    )
    try FileManager.default.createDirectory(
        at: target,
        withIntermediateDirectories: true
    )
    let keep = target.appendingPathComponent("keep.txt")
    try Data("keep".utf8).write(to: keep)
    try FileManager.default.createSymbolicLink(
        at: home.appendingPathComponent("memories"),
        withDestinationURL: target
    )

    #expect(
        throws: CodexDesktopMemoryResetError.symlinkedRoot(
            home.appendingPathComponent("memories").path
        )
    ) {
        try CodexDesktopMemoryResetService(
            codexHome: home
        ).resetMemory()
    }
    #expect(FileManager.default.fileExists(atPath: keep.path))
}

@MainActor
@Test
func memoryResetRouterUsesOfficialUnitRequestAndEmptyResponse() async {
    let resetter = RecordingMemoryResetter()
    let response = await CodexDesktopInitialMCPRouter
        .responseIncludingFileSystem(
            to: memoryResetRequest(params: nil),
            state: memoryResetState(),
            allowedFileSystemRoots: [],
            memoryResetter: resetter
        )

    #expect(resetter.resetCount == 1)
    #expect(
        response
            == .mcpResponse(
                hostID: "local",
                message: .object([
                    "id": .integer(91),
                    "result": .object([:]),
                ]),
                metadata: [:]
            )
    )
}

@MainActor
@Test
func memoryResetRouterRejectsFieldsAndReportsServiceFailure() async {
    let invalid = await CodexDesktopInitialMCPRouter
        .responseIncludingFileSystem(
            to: memoryResetRequest(
                params: .object(["unexpected": .bool(true)])
            ),
            state: memoryResetState(),
            allowedFileSystemRoots: [],
            memoryResetter: RecordingMemoryResetter()
        )
    let failed = await CodexDesktopInitialMCPRouter
        .responseIncludingFileSystem(
            to: memoryResetRequest(params: nil),
            state: memoryResetState(),
            allowedFileSystemRoots: [],
            memoryResetter: RecordingMemoryResetter(shouldFail: true)
        )

    #expect(
        invalid
            == memoryResetError(
                code: -32602,
                message: "Invalid params for memory/reset"
            )
    )
    #expect(
        failed
            == memoryResetError(
                code: -32603,
                message: "Memory reset failed"
            )
    )
}

private final class RecordingMemoryResetter:
    CodexDesktopMemoryResetting
{
    var resetCount = 0
    let shouldFail: Bool

    init(shouldFail: Bool = false) {
        self.shouldFail = shouldFail
    }

    func resetMemory() throws {
        resetCount += 1
        if shouldFail {
            throw CocoaError(.fileWriteUnknown)
        }
    }
}

private func memoryResetRequest(
    params: CodexJSONValue?
) -> CodexDesktopMCPRequest {
    CodexDesktopMCPRequest(
        request: CodexDesktopMCPRequestMessage(
            id: .integer(91),
            method: "memory/reset",
            params: params,
            metadata: [:]
        ),
        hostID: "local",
        dispatchedAtMs: nil,
        priority: nil,
        source: nil,
        timeoutMs: nil,
        expiresAtMs: nil,
        metadata: [:]
    )
}

private func memoryResetState() -> CodexDesktopInitialMCPState {
    CodexDesktopInitialMCPState(
        account: .init(
            account: nil,
            authMethod: nil,
            requiresOpenAIAuth: true
        ),
        config: .init(config: [:], origins: [:], layers: []),
        remoteControl: .init(
            status: .disabled,
            serverName: "Codex for ipad",
            installationID: "installation",
            environmentID: nil
        )
    )
}

private func memoryResetError(
    code: Int64,
    message: String
) -> CodexDesktopHostMessage {
    .mcpResponse(
        hostID: "local",
        message: .object([
            "id": .integer(91),
            "error": .object([
                "code": .integer(code),
                "message": .string(message),
            ]),
        ]),
        metadata: [:]
    )
}
