import Foundation
import Testing

@testable import CodexPadApplication
@testable import CodexPadProtocolBridge

private struct SecretBearingSurfaceError: Error, CustomStringConvertible {
    let description = "https://example.invalid/?token=super-secret Authorization: Bearer abc"
}

@Test
func surfaceDiagnosticErrorSummaryRedactsErrorDescription() {
    let summary = CodexDiagnosticSanitization.publicErrorSummary(
        SecretBearingSurfaceError()
    )

    #expect(summary.hasPrefix("SecretBearingSurfaceError"))
    #expect(!summary.contains("super-secret"))
    #expect(!summary.contains("Bearer"))
}

@Test
func surfaceDiagnosticErrorSummaryKeepsOnlyNSErrorCode() {
    let error = NSError(
        domain: "https://example.invalid/private?access_token=secret",
        code: 401,
        userInfo: [NSLocalizedDescriptionKey: "password=secret"]
    )

    let summary = CodexDiagnosticSanitization.publicErrorSummary(error)

    #expect(summary.contains("code=401"))
    #expect(!summary.contains("example.invalid"))
    #expect(!summary.contains("access_token"))
    #expect(!summary.contains("password"))
}

@Test
func surfaceNetworkFetchDiagnosticKeepsOnlyHostPathStatusAndSafeCode() {
    let diagnostic = CodexDiagnosticSanitization.networkFetchSummary(
        method: "POST",
        requestURL: "/wham/tasks/list?access_token=super-secret",
        status: 500,
        errorCode: "NSURLErrorDomain:-1003"
    )

    #expect(
        diagnostic
            == "fetch network POST chatgpt.com/backend-api/wham/tasks/list status=500 stage=transport errorCode=NSURLErrorDomain:-1003"
    )
    #expect(!diagnostic.contains("super-secret"))
    #expect(!diagnostic.contains("Bearer"))
    #expect(!diagnostic.contains("password"))
}

@Test
func fetchStreamDiagnosticTracksDeliveredLifecycle() {
    var diagnostic = CodexDesktopFetchStreamDiagnostic()
    diagnostic.start(requestID: "request-1")
    #expect(diagnostic.state == .started)

    diagnostic.observe(fetchStreamMessage("fetch-stream-response"))
    #expect(diagnostic.state == .response)

    diagnostic.observe(fetchStreamMessage("fetch-stream-event"))
    #expect(diagnostic.state == .streaming)

    diagnostic.observe(fetchStreamMessage("fetch-stream-complete"))
    #expect(diagnostic.state == .complete)
}

@Test
func fetchStreamDiagnosticPreservesTerminalFailure() {
    var diagnostic = CodexDesktopFetchStreamDiagnostic()
    diagnostic.start(requestID: "request-1")

    diagnostic.observe(fetchStreamMessage("fetch-stream-error"))
    diagnostic.observe(fetchStreamMessage("fetch-stream-complete"))

    #expect(diagnostic.state == .error)
}

@Test
func fetchStreamDiagnosticIgnoresStaleRequestMessages() {
    var diagnostic = CodexDesktopFetchStreamDiagnostic()
    diagnostic.start(requestID: "request-2")

    diagnostic.observe(
        .event(
            type: "fetch-stream-complete",
            payload: .object(["requestId": .string("request-1")])
        )
    )

    #expect(diagnostic.state == .started)
}

private func fetchStreamMessage(
    _ type: String
) -> CodexDesktopHostMessage {
    .event(
        type: type,
        payload: .object(["requestId": .string("request-1")])
    )
}
