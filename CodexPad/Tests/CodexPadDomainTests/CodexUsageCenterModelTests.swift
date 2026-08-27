import CodexPadDomain
import Testing
@testable import CodexPadApplication

@Test
func usageCenterMapsThreadCreditsAndBreakdowns() throws {
    let payload: CodexJSONValue = .object([
        "threadUsage": .object([
            "threadId": .string("thread-1"),
            "estimatedUsageCreditsMicros": .integer(46_000_000),
            "estimatedUsageUsdMicros": .integer(1_820_000),
            "groups": .array([
                .object(["model": .string("gpt-5.5"), "reasoningEffort": .string("high"), "speed": .string("fast"), "estimatedUsageCreditsMicros": .integer(40_000_000)]),
                .object(["model": .string("gpt-5.5"), "reasoningEffort": .string("high"), "speed": .string("slow"), "estimatedUsageCreditsMicros": .integer(6_000_000)]),
            ])
        ])
    ])

    let model = try #require(CodexUsageCenterModel(payload: payload))
    #expect(model.threadID == "thread-1")
    #expect(model.creditsMicros == 46_000_000)
    #expect(model.usdMicros == 1_820_000)
    #expect(model.breakdown(for: .model) == [.init(label: "gpt-5.5", micros: 46_000_000)])
    #expect(model.breakdown(for: .reasoningEffort) == [.init(label: "high", micros: 46_000_000)])
    #expect(model.breakdown(for: .speed) == [.init(label: "fast", micros: 40_000_000), .init(label: "slow", micros: 6_000_000)])
}

@Test
func usageCenterRejectsMissingThreadUsage() {
    #expect(CodexUsageCenterModel(payload: .object(["threadUsage": .null])) == nil)
}
