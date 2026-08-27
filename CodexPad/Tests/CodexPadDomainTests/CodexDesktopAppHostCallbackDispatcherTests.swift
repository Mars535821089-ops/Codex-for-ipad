import Testing

@testable import CodexPadApplication

@Test
func desktopAppHostCallbackDispatcherPreservesPortScopedIdentity() async throws {
    let recorder = CallbackDispatchRecorder()
    let dispatcher = CodexDesktopAppHostCallbackDispatcher()

    await #expect(throws: CodexDesktopAppHostCallbackDispatcher.Error.handlerUnavailable) {
        try await dispatcher.send(
            portID: "app-host-1",
            callbackID: 7,
            arguments: [.string("before-install")]
        )
    }

    dispatcher.install { identity, arguments in
        await recorder.record(
            identity: identity,
            arguments: arguments
        )
    }
    try await dispatcher.send(
        portID: "app-host-2",
        callbackID: 7,
        arguments: [.string("snapshot")]
    )

    let recorded = await recorder.recorded
    #expect(recorded.count == 1)
    #expect(recorded.first?.0.portID == "app-host-2")
    #expect(recorded.first?.0.callbackID == 7)
    #expect(recorded.first?.1 == [.string("snapshot")])
}

private actor CallbackDispatchRecorder {
    private(set) var recorded: [
        (
            CodexDesktopAppHostCallbackIdentity,
            [CodexDesktopAppHostRPC.Value]
        )
    ] = []

    func record(
        identity: CodexDesktopAppHostCallbackIdentity,
        arguments: [CodexDesktopAppHostRPC.Value]
    ) {
        recorded.append((identity, arguments))
    }
}
