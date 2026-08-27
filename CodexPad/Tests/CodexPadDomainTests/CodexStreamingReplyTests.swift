import Testing
@testable import CodexPadApplication

struct CodexStreamingReplyTests {
    @Test
    func appendsDeltasAndResetsBetweenTurns() {
        var reply = CodexStreamingReply()

        reply.append("Hello")
        reply.append(", iPad")

        #expect(reply.text == "Hello, iPad")
        #expect(reply.isEmpty == false)

        reply.reset()

        #expect(reply.text.isEmpty)
        #expect(reply.isEmpty)
    }
}
