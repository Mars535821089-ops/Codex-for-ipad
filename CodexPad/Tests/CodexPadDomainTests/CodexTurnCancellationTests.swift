import CodexPadDomain
import Testing

@Test
func turnCancellationIsObservableAndThrowsCancellationError() throws {
    let cancellation = CodexTurnCancellation()

    #expect(!cancellation.isCancelled)
    try cancellation.checkCancellation()

    cancellation.cancel()

    #expect(cancellation.isCancelled)
    #expect(throws: CancellationError.self) {
        try cancellation.checkCancellation()
    }
}
