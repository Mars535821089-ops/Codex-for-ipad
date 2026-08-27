import Testing
@testable import CodexPadDomain

@Test
func recoveredModelCatalogPreservesTheCompleteOfficialSnapshotAndDefaults()
    throws
{
    #expect(
        CodexModelCatalog.current.map(\.id) == [
            "gpt-5.6-sol",
            "gpt-5.6-terra",
            "gpt-5.6-luna",
            "gpt-5.5",
            "gpt-5.4",
            "gpt-5.4-mini",
            "gpt-5.2",
            "codex-auto-review",
        ]
    )
    let sol = try #require(
        CodexModelCatalog.current.first { $0.id == "gpt-5.6-sol" }
    )
    #expect(sol.displayName == "GPT-5.6-Sol")
    #expect(sol.defaultReasoningEffort == .low)
    #expect(sol.supportedReasoningEfforts == [
        .low, .medium, .high, .xhigh, .max, .ultra,
    ])

    let luna = try #require(
        CodexModelCatalog.current.first { $0.id == "gpt-5.6-luna" }
    )
    #expect(luna.defaultReasoningEffort == .medium)
    #expect(!luna.supportedReasoningEfforts.contains(.ultra))
}

@Test
func reasoningEffortUsesOfficialWireValuesAndLabels() {
    #expect(CodexReasoningEffort.allCases.map(\.rawValue) == [
        "none", "minimal", "low", "medium", "high", "xhigh", "max", "ultra",
    ])
    #expect(CodexReasoningEffort.low.displayName == "Light")
    #expect(CodexReasoningEffort.xhigh.displayName == "Extra High")
    let custom = CodexReasoningEffort(rawValue: "focused")
    #expect(custom?.rawValue == "focused")
    #expect(custom?.displayName == "focused")
    #expect(CodexReasoningEffort(rawValue: "") == nil)
}

@Test
func bundledModelCatalogDoesNotReplaceAnUnknownPersistedModel() {
    #expect(
        CodexModelCatalog.reasoningEffort(
            rawValue: "ultra",
            forModelID: "gpt-5.6-luna"
        ) == .medium
    )
    #expect(
        CodexModelCatalog.reasoningEffort(
            rawValue: "xhigh",
            forModelID: "gpt-5.6-luna"
        ) == .xhigh
    )
    #expect(
        CodexModelCatalog.model(id: "missing") == nil
    )
}
