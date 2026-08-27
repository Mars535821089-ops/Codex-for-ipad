public enum CodexUnifiedDiff {
    public static func make(
        path: String,
        oldText: String?,
        newText: String
    ) -> String {
        make(
            oldPath: oldText == nil ? nil : path,
            newPath: path,
            oldText: oldText,
            newText: newText
        )
    }

    public static func make(
        oldPath: String?,
        newPath: String?,
        oldText: String?,
        newText: String?
    ) -> String {
        let oldLines = lines(in: oldText ?? "")
        let newLines = lines(in: newText ?? "")
        let oldHeader = oldPath.map { "a/\($0)" } ?? "/dev/null"
        let newHeader = newPath.map { "b/\($0)" } ?? "/dev/null"
        var output = [
            "--- \(oldHeader)",
            "+++ \(newHeader)",
            "@@ -1,\(oldLines.count) +1,\(newLines.count) @@",
        ]
        output.append(contentsOf: operations(old: oldLines, new: newLines))
        return output.joined(separator: "\n") + "\n"
    }

    private static func lines(in text: String) -> [String] {
        guard !text.isEmpty else {
            return []
        }
        var result = text.split(
            separator: "\n",
            omittingEmptySubsequences: false
        ).map(String.init)
        if text.hasSuffix("\n") {
            result.removeLast()
        }
        return result
    }

    private static func operations(
        old: [String],
        new: [String]
    ) -> [String] {
        guard old.count * new.count <= 1_000_000 else {
            return old.map { "-\($0)" } + new.map { "+\($0)" }
        }
        var lengths = Array(
            repeating: Array(repeating: 0, count: new.count + 1),
            count: old.count + 1
        )
        if !old.isEmpty, !new.isEmpty {
            for oldIndex in stride(from: old.count - 1, through: 0, by: -1) {
                for newIndex in stride(
                    from: new.count - 1,
                    through: 0,
                    by: -1
                ) {
                    if old[oldIndex] == new[newIndex] {
                        lengths[oldIndex][newIndex] =
                            lengths[oldIndex + 1][newIndex + 1] + 1
                    } else {
                        lengths[oldIndex][newIndex] = max(
                            lengths[oldIndex + 1][newIndex],
                            lengths[oldIndex][newIndex + 1]
                        )
                    }
                }
            }
        }

        var output: [String] = []
        var oldIndex = 0
        var newIndex = 0
        while oldIndex < old.count || newIndex < new.count {
            if oldIndex < old.count,
               newIndex < new.count,
               old[oldIndex] == new[newIndex]
            {
                output.append(" \(old[oldIndex])")
                oldIndex += 1
                newIndex += 1
            } else if newIndex < new.count,
                      oldIndex == old.count
                        || lengths[oldIndex][newIndex + 1]
                            > lengths[oldIndex + 1][newIndex]
            {
                output.append("+\(new[newIndex])")
                newIndex += 1
            } else {
                output.append("-\(old[oldIndex])")
                oldIndex += 1
            }
        }
        return output
    }
}

public struct CodexDiffLine: Equatable, Identifiable, Sendable {
    public enum Kind: Equatable, Sendable {
        case header
        case addition
        case deletion
        case context
    }

    public let id: Int
    public let text: String
    public let kind: Kind

    public static func parse(_ diff: String) -> [CodexDiffLine] {
        diff.split(separator: "\n", omittingEmptySubsequences: false)
            .dropLast(diff.hasSuffix("\n") ? 1 : 0)
            .enumerated()
            .map { index, line in
                let text = String(line)
                let kind: Kind
                if text.hasPrefix("--- ")
                    || text.hasPrefix("+++ ")
                    || text.hasPrefix("@@")
                {
                    kind = .header
                } else if text.hasPrefix("+") {
                    kind = .addition
                } else if text.hasPrefix("-") {
                    kind = .deletion
                } else {
                    kind = .context
                }
                return CodexDiffLine(id: index, text: text, kind: kind)
            }
    }
}
