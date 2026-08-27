import Testing
@testable import CodexPadApplication

struct CodexUnifiedDiffTests {
    @Test
    func replacementProducesUnifiedHeadersAndChangedLines() {
        let diff = CodexUnifiedDiff.make(
            path: "Sources/App.swift",
            oldText: "let value = 1\nprint(value)\n",
            newText: "let value = 2\nprint(value)\n"
        )

        #expect(diff.contains("--- a/Sources/App.swift"))
        #expect(diff.contains("+++ b/Sources/App.swift"))
        #expect(diff.contains("-let value = 1"))
        #expect(diff.contains("+let value = 2"))
        #expect(diff.contains(" print(value)"))
    }

    @Test
    func newFileUsesDevNullAsOldPath() {
        let diff = CodexUnifiedDiff.make(
            path: "README.md",
            oldText: nil,
            newText: "Codex for ipad\n"
        )

        #expect(diff.contains("--- /dev/null"))
        #expect(diff.contains("+++ b/README.md"))
        #expect(diff.contains("+Codex for ipad"))
    }

    @Test
    func parserClassifiesUnifiedDiffLinesForPresentation() {
        let lines = CodexDiffLine.parse(
            """
            --- a/App.swift
            +++ b/App.swift
            @@ -1,1 +1,1 @@
            -old
            +new
             context
            """
        )

        #expect(lines.map(\.kind) == [
            .header,
            .header,
            .header,
            .deletion,
            .addition,
            .context,
        ])
    }
}
