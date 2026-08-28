import CodexPadProtocolBridge
import Foundation
import Testing

private enum DiagnosticFixtureError: Error {
    case secretPayload
}

@Test
func coreEventDecodeDiagnosticRedactsErrorAndSettingsValues() {
    let defaults = UserDefaults(suiteName: "CodexCoreClientDiagnosticTests")!
    defaults.removeObject(forKey: "codex.desktop.last-core-event-decode-failure")
    let data = Data(
        #"{"kind":"threadSettingsUpdated","threadSettings":{"modelProvider":"https://api.example.test/?token=redact-me","approvalPolicy":"Bearer secret-value","cwd":"/Users/example/project"}}"#.utf8
    )

    let diagnostic = CodexCoreEventDecodeDiagnostic.record(
        data: data,
        error: DiagnosticFixtureError.secretPayload,
        userDefaults: defaults
    )

    #expect(diagnostic.contains("errorType=DiagnosticFixtureError"))
    #expect(diagnostic.contains("modelProvider=present"))
    #expect(diagnostic.contains("approvalPolicy=present"))
    #expect(diagnostic.contains("cwd=absolute"))
    #expect(!diagnostic.contains("redact-me"))
    #expect(!diagnostic.contains("secret-value"))
    #expect(defaults.string(forKey: "codex.desktop.last-core-event-decode-failure") == diagnostic)
}

@Test
func turnStartInvalidArgumentDiagnosticCapturesOnlyShape() {
    let defaults = UserDefaults(suiteName: "CodexCoreClientDiagnosticTests.turnStart")!
    defaults.removeObject(
        forKey: "codex.desktop.last-turn-start-invalid-argument"
    )
    let request = Data(
        #"{"method":"turn/start","params":{"threadId":"secret-thread","input":[{"type":"text","text":"secret prompt"}],"cwd":"/Users/example/secret","model":null,"effort":null,"permissions":null,"sandboxPolicy":{"type":"workspaceWrite","writableRoots":["/Users/example/project"],"networkAccess":true},"collaborationMode":{"mode":"default","settings":{"model":"gpt-5.6-sol","reasoning_effort":null,"developer_instructions":"secret instruction"}},"responsesapiClientMetadata":{"secret":"value"}}}"#.utf8
    )

    let diagnostic = CodexTurnStartInvalidArgumentDiagnostic.record(
        requestData: request,
        userDefaults: defaults
    )

    #expect(diagnostic?.contains("inputCount=1") == true)
    #expect(diagnostic?.contains("sandboxType=string") == true)
    #expect(diagnostic?.contains("workspaceWriteRoots=1") == true)
    #expect(diagnostic?.contains("workspaceWriteRootsAbsolute=true") == true)
    #expect(diagnostic?.contains("collaborationSettings=developer_instructions:string,model:string,reasoning_effort:null") == true)
    #expect(!diagnostic!.contains("secret-thread"))
    #expect(!diagnostic!.contains("secret prompt"))
    #expect(!diagnostic!.contains("/Users/example/secret"))
    #expect(!diagnostic!.contains("secret instruction"))
    #expect(!diagnostic!.contains("value"))
    #expect(
        defaults.string(
            forKey: "codex.desktop.last-turn-start-invalid-argument"
        ) == diagnostic
    )
}
