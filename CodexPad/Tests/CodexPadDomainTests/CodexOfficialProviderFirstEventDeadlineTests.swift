import Foundation
import Testing
@testable import CodexPadApplication
@testable import CodexPadProtocolBridge

struct CodexOfficialProviderFirstEventDeadlineTests {
    @Test
    func silentProviderStreamFailsAtFirstEventDeadline() async {
        let upstream = AsyncThrowingStream<
            CodexCoreProviderEvent,
            Error
        > { _ in }

        let guarded = CodexOfficialProviderFirstEventDeadline.enforce(
            upstream,
            timeout: .milliseconds(25)
        )

        do {
            for try await _ in guarded {}
            Issue.record("A silent provider stream completed without timeout")
        } catch is CodexOfficialProviderFirstEventTimeoutError {
            // Expected terminal failure.
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test
    func firstProviderEventDisarmsDeadlineAndPreservesCompletion() async {
        let expected = CodexCoreProviderEvent.responseStarted(
            sequence: 1,
            requestID: "request",
            sourceCommit: "source"
        )
        let upstream = AsyncThrowingStream<
            CodexCoreProviderEvent,
            Error
        > { continuation in
            continuation.yield(expected)
            continuation.finish()
        }

        let guarded = CodexOfficialProviderFirstEventDeadline.enforce(
            upstream,
            timeout: .milliseconds(25)
        )
        var received: [CodexCoreProviderEvent] = []

        do {
            for try await event in guarded {
                received.append(event)
            }
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(received == [expected])
    }
}

struct CodexOfficialProviderActivityDeadlineTests {
    @Test
    func activityDeadlineFailsAfterResponseStartedWithoutCompletion() async {
        let upstream = AsyncThrowingStream<
            CodexCoreProviderEvent,
            Error
        > { continuation in
            continuation.yield(
                .responseStarted(
                    sequence: 1,
                    requestID: "request",
                    sourceCommit: "source"
                )
            )
        }
        let guarded = CodexOfficialProviderActivityDeadline.enforce(
            upstream,
            timeout: .milliseconds(25)
        )
        var received: [CodexCoreProviderEvent] = []

        do {
            for try await event in guarded {
                received.append(event)
            }
            Issue.record("An inactive provider stream completed without timeout")
        } catch is CodexOfficialProviderActivityTimeoutError {
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(received.count == 1)
    }
}
