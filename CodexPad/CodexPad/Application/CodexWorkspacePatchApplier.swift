#if SWIFT_PACKAGE
import CodexPadDomain
import CodexPadProtocolBridge
#endif
import Foundation

public enum CodexWorkspacePatchError: Error, Equatable, Sendable {
    case invalidPatch(String)
    case invalidPath(String)
    case missingFile(String)
    case contextNotFound(path: String, context: String)
    case rollbackFailed(String)
}

public struct CodexWorkspacePatchResult: Equatable, Sendable {
    public let output: String
    public let combinedDiff: String
    public let fileChanges: [CodexFileUpdateChange]

    public init(
        output: String,
        combinedDiff: String,
        fileChanges: [CodexFileUpdateChange] = []
    ) {
        self.output = output
        self.combinedDiff = combinedDiff
        self.fileChanges = fileChanges
    }
}

public struct CodexWorkspacePatchApplier: Sendable {
    private let access: CodexWorkspaceAccess

    public init(access: CodexWorkspaceAccess = CodexWorkspaceAccess()) {
        self.access = access
    }

    public func apply(
        patch: String,
        bookmark: String,
        cancellation: CodexTurnCancellation? = nil
    ) throws -> CodexWorkspacePatchResult {
        try cancellation?.checkCancellation()
        let hunks = try PatchParser.parse(patch)
        let root = try access.resolve(bookmark)

        // Validate every path before reading or committing any hunk. This keeps
        // an escaping path later in a multi-hunk patch from partially applying
        // earlier, otherwise-valid file changes.
        for hunk in hunks {
            try validate(hunk.path, inside: root)
            if let movePath = hunk.movePath {
                try validate(movePath, inside: root)
            }
        }

        var workspace = VirtualWorkspace(
            root: root,
            bookmark: bookmark,
            access: access
        )
        var diffs: [String] = []
        var added: [String] = []
        var modified: [String] = []
        var deleted: [String] = []
        var fileChanges: [CodexFileUpdateChange] = []

        for hunk in hunks {
            try cancellation?.checkCancellation()
            switch hunk {
            case let .add(path, contents):
                let oldText = try workspace.contents(at: path)
                workspace.set(.present(contents), at: path)
                let diff = CodexUnifiedDiff.make(
                        oldPath: oldText == nil ? nil : path,
                        newPath: path,
                        oldText: oldText,
                        newText: contents
                    )
                diffs.append(diff)
                fileChanges.append(
                    CodexFileUpdateChange(
                        path: path,
                        kind: .add,
                        diff: contents
                    )
                )
                added.append(path)

            case let .delete(path):
                guard let oldText = try workspace.contents(at: path) else {
                    throw CodexWorkspacePatchError.missingFile(path)
                }
                workspace.set(.absent, at: path)
                let diff = CodexUnifiedDiff.make(
                        oldPath: path,
                        newPath: nil,
                        oldText: oldText,
                        newText: nil
                    )
                diffs.append(diff)
                fileChanges.append(
                    CodexFileUpdateChange(
                        path: path,
                        kind: .delete,
                        diff: oldText
                    )
                )
                deleted.append(path)

            case let .update(path, movePath, chunks):
                guard let oldText = try workspace.contents(at: path) else {
                    throw CodexWorkspacePatchError.missingFile(path)
                }
                let newText = try Self.applying(
                    chunks: chunks,
                    to: oldText,
                    path: path
                )
                if let movePath {
                    workspace.set(.absent, at: path)
                    workspace.set(.present(newText), at: movePath)
                    let diff = CodexUnifiedDiff.make(
                            oldPath: path,
                            newPath: movePath,
                            oldText: oldText,
                            newText: newText
                        )
                    diffs.append(diff)
                    fileChanges.append(
                        CodexFileUpdateChange(
                            path: path,
                            kind: .update(movePath: movePath),
                            diff: diff + "\n\nMoved to: \(movePath)"
                        )
                    )
                    modified.append(movePath)
                } else {
                    workspace.set(.present(newText), at: path)
                    let diff = CodexUnifiedDiff.make(
                            oldPath: path,
                            newPath: path,
                            oldText: oldText,
                            newText: newText
                        )
                    diffs.append(diff)
                    fileChanges.append(
                        CodexFileUpdateChange(
                            path: path,
                            kind: .update(movePath: nil),
                            diff: diff
                        )
                    )
                    modified.append(path)
                }
            }
        }

        try cancellation?.checkCancellation()
        try workspace.commit(cancellation: cancellation)
        let output = Self.summary(
            added: added,
            modified: modified,
            deleted: deleted
        )
        return CodexWorkspacePatchResult(
            output: output,
            combinedDiff: diffs.joined(),
            fileChanges: fileChanges.sorted { $0.path < $1.path }
        )
    }

    private func validate(_ path: String, inside root: URL) throws {
        do {
            _ = try CodexWorkspaceAccess.secureURL(
                relativePath: path,
                inside: root
            )
        } catch {
            throw CodexWorkspacePatchError.invalidPath(path)
        }
    }

    private static func applying(
        chunks: [PatchChunk],
        to text: String,
        path: String
    ) throws -> String {
        guard !chunks.isEmpty else {
            return text
        }
        var lines = splitLines(text)
        var cursor = 0

        for chunk in chunks {
            if let context = chunk.context {
                guard let contextIndex = find(
                    [context],
                    in: lines,
                    startingAt: cursor,
                    mustEndAtEOF: false
                ) else {
                    throw CodexWorkspacePatchError.contextNotFound(
                        path: path,
                        context: context
                    )
                }
                cursor = contextIndex + 1
            }

            if chunk.oldLines.isEmpty {
                lines.append(contentsOf: chunk.newLines)
                cursor = lines.count
                continue
            }

            guard let start = find(
                chunk.oldLines,
                in: lines,
                startingAt: cursor,
                mustEndAtEOF: chunk.isEndOfFile
            ) else {
                throw CodexWorkspacePatchError.contextNotFound(
                    path: path,
                    context: chunk.oldLines.joined(separator: "\n")
                )
            }
            lines.replaceSubrange(
                start ..< start + chunk.oldLines.count,
                with: chunk.newLines
            )
            cursor = start + chunk.newLines.count
        }

        return lines.joined(separator: "\n") + "\n"
    }

    private static func splitLines(_ text: String) -> [String] {
        guard !text.isEmpty else {
            return []
        }
        var lines = text.split(
            separator: "\n",
            omittingEmptySubsequences: false
        ).map(String.init)
        if text.hasSuffix("\n") {
            lines.removeLast()
        }
        return lines
    }

    private static func find(
        _ needle: [String],
        in haystack: [String],
        startingAt requestedStart: Int,
        mustEndAtEOF: Bool
    ) -> Int? {
        guard !needle.isEmpty, needle.count <= haystack.count else {
            return nil
        }
        let start = min(max(requestedStart, 0), haystack.count)
        let last = haystack.count - needle.count
        guard start <= last else {
            return nil
        }

        let normalizers: [(String) -> String] = [
            { $0 },
            { $0.trimmingCharacters(in: .whitespaces) },
        ]
        for normalize in normalizers {
            for index in start ... last {
                if mustEndAtEOF, index + needle.count != haystack.count {
                    continue
                }
                let candidate = haystack[index ..< index + needle.count]
                if zip(candidate, needle).allSatisfy({
                    normalize($0.0) == normalize($0.1)
                }) {
                    return index
                }
            }
        }
        return nil
    }

    private static func summary(
        added: [String],
        modified: [String],
        deleted: [String]
    ) -> String {
        var lines = ["Success. Updated the following files:"]
        lines.append(contentsOf: added.map { "A \($0)" })
        lines.append(contentsOf: modified.map { "M \($0)" })
        lines.append(contentsOf: deleted.map { "D \($0)" })
        return lines.joined(separator: "\n") + "\n"
    }
}

private enum VirtualFile {
    case absent
    case present(String)
}

private enum OriginalWorkspaceFile {
    case absent
    case present(Data)
}

private struct WorkspaceJournalEntry {
    let path: String
    let url: URL
    let original: OriginalWorkspaceFile
}

private struct VirtualWorkspace {
    let root: URL
    let bookmark: String
    let access: CodexWorkspaceAccess
    private var states: [String: VirtualFile] = [:]
    private var touchedPaths: [String] = []

    mutating func contents(at path: String) throws -> String? {
        switch try state(at: path) {
        case .absent:
            return nil
        case let .present(text):
            return text
        }
    }

    mutating func set(_ state: VirtualFile, at path: String) {
        if !touchedPaths.contains(path) {
            touchedPaths.append(path)
        }
        states[path] = state
    }

    mutating func commit(
        cancellation: CodexTurnCancellation?
    ) throws {
        let granted = root.startAccessingSecurityScopedResource()
        defer {
            if granted {
                root.stopAccessingSecurityScopedResource()
            }
        }

        let journal = try makeJournal()
        let missingDirectories = try missingParentDirectories()
        do {
            // Write destinations before removals so a move never loses its
            // source if creating the destination fails.
            for path in touchedPaths {
                try cancellation?.checkCancellation()
                guard case let .present(text) = states[path] else {
                    continue
                }
                try access.writeText(
                    bookmark: bookmark,
                    relativePath: path,
                    text: text
                )
            }
            for path in touchedPaths {
                try cancellation?.checkCancellation()
                guard case .absent = states[path] else {
                    continue
                }
                let url = try CodexWorkspaceAccess.secureURL(
                    relativePath: path,
                    inside: root
                )
                if FileManager.default.fileExists(atPath: url.path) {
                    try FileManager.default.removeItem(at: url)
                }
            }
        } catch {
            do {
                try rollback(
                    journal: journal,
                    missingDirectories: missingDirectories
                )
            } catch let rollbackError {
                throw CodexWorkspacePatchError.rollbackFailed(
                    "\(error); rollback: \(rollbackError)"
                )
            }
            throw error
        }
    }

    private func makeJournal() throws -> [WorkspaceJournalEntry] {
        try touchedPaths.map { path in
            let url = try CodexWorkspaceAccess.secureURL(
                relativePath: path,
                inside: root
            )
            let original: OriginalWorkspaceFile
            if FileManager.default.fileExists(atPath: url.path) {
                let values = try url.resourceValues(
                    forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
                )
                guard values.isRegularFile == true,
                      values.isSymbolicLink != true
                else {
                    throw CodexWorkspaceAccessError.invalidRelativePath
                }
                original = .present(try Data(contentsOf: url))
            } else {
                original = .absent
            }
            return WorkspaceJournalEntry(
                path: path,
                url: url,
                original: original
            )
        }
    }

    private func missingParentDirectories() throws -> [URL] {
        let canonicalRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        var missing: [URL] = []
        for path in touchedPaths {
            guard case .present = states[path] else {
                continue
            }
            var parent = try CodexWorkspaceAccess.secureURL(
                relativePath: path,
                inside: root
            ).deletingLastPathComponent()
            while parent.path != canonicalRoot.path {
                if !FileManager.default.fileExists(atPath: parent.path),
                   !missing.contains(parent)
                {
                    missing.append(parent)
                }
                parent = parent.deletingLastPathComponent()
            }
        }
        return missing
    }

    private func rollback(
        journal: [WorkspaceJournalEntry],
        missingDirectories: [URL]
    ) throws {
        var firstError: Error?
        for entry in journal.reversed() {
            do {
                switch entry.original {
                case .absent:
                    if FileManager.default.fileExists(atPath: entry.url.path) {
                        try FileManager.default.removeItem(at: entry.url)
                    }
                case let .present(data):
                    try FileManager.default.createDirectory(
                        at: entry.url.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    try data.write(to: entry.url, options: .atomic)
                }
            } catch {
                if firstError == nil {
                    firstError = error
                }
            }
        }
        for directory in missingDirectories.sorted(
            by: { $0.pathComponents.count > $1.pathComponents.count }
        ) {
            do {
                guard FileManager.default.fileExists(
                    atPath: directory.path
                ) else {
                    continue
                }
                let children = try FileManager.default.contentsOfDirectory(
                    at: directory,
                    includingPropertiesForKeys: nil
                )
                if children.isEmpty {
                    try FileManager.default.removeItem(at: directory)
                }
            } catch {
                if firstError == nil {
                    firstError = error
                }
            }
        }
        if let firstError {
            throw firstError
        }
    }

    private mutating func state(at path: String) throws -> VirtualFile {
        if let state = states[path] {
            return state
        }
        let url = try CodexWorkspaceAccess.secureURL(
            relativePath: path,
            inside: root
        )
        let state: VirtualFile
        if FileManager.default.fileExists(atPath: url.path) {
            state = .present(
                try access.readText(
                    bookmark: bookmark,
                    relativePath: path
                )
            )
        } else {
            state = .absent
        }
        states[path] = state
        return state
    }
}

private enum PatchHunk {
    case add(path: String, contents: String)
    case delete(path: String)
    case update(path: String, movePath: String?, chunks: [PatchChunk])

    var path: String {
        switch self {
        case let .add(path, _),
             let .delete(path),
             let .update(path, _, _):
            return path
        }
    }

    var movePath: String? {
        guard case let .update(_, movePath, _) = self else {
            return nil
        }
        return movePath
    }
}

private struct PatchChunk {
    let context: String?
    var oldLines: [String]
    var newLines: [String]
    var isEndOfFile: Bool
}

private enum PatchParser {
    private static let begin = "*** Begin Patch"
    private static let end = "*** End Patch"
    private static let add = "*** Add File: "
    private static let delete = "*** Delete File: "
    private static let update = "*** Update File: "
    private static let move = "*** Move to: "

    static func parse(_ source: String) throws -> [PatchHunk] {
        let normalized = source.replacingOccurrences(of: "\r\n", with: "\n")
        let trimmed = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
        let lines = trimmed.split(
            separator: "\n",
            omittingEmptySubsequences: false
        ).map(String.init)
        guard lines.first?.trimmingCharacters(in: .whitespaces) == begin,
              lines.last?.trimmingCharacters(in: .whitespaces) == end
        else {
            throw CodexWorkspacePatchError.invalidPatch(
                "patch must start with \(begin) and end with \(end)"
            )
        }

        var hunks: [PatchHunk] = []
        var index = 1
        let finalIndex = lines.count - 1
        while index < finalIndex {
            let line = lines[index]
            if line.hasPrefix(add) {
                let path = try filename(after: add, in: line)
                index += 1
                var addedLines: [String] = []
                while index < finalIndex, lines[index].hasPrefix("+") {
                    addedLines.append(String(lines[index].dropFirst()))
                    index += 1
                }
                guard !addedLines.isEmpty else {
                    throw invalidHunk(line: index + 1, "add file needs + lines")
                }
                hunks.append(
                    .add(
                        path: path,
                        contents: addedLines.joined(separator: "\n") + "\n"
                    )
                )
            } else if line.hasPrefix(delete) {
                hunks.append(
                    .delete(path: try filename(after: delete, in: line))
                )
                index += 1
            } else if line.hasPrefix(update) {
                let path = try filename(after: update, in: line)
                index += 1
                var movePath: String?
                if index < finalIndex, lines[index].hasPrefix(move) {
                    movePath = try filename(after: move, in: lines[index])
                    index += 1
                }
                let parsed = try parseChunks(
                    lines,
                    startingAt: index,
                    finalIndex: finalIndex
                )
                hunks.append(
                    .update(
                        path: path,
                        movePath: movePath,
                        chunks: parsed.chunks
                    )
                )
                index = parsed.nextIndex
            } else {
                throw invalidHunk(
                    line: index + 1,
                    "expected Add File, Delete File, or Update File"
                )
            }
        }
        guard !hunks.isEmpty else {
            throw CodexWorkspacePatchError.invalidPatch(
                "patch must contain at least one hunk"
            )
        }
        return hunks
    }

    private static func parseChunks(
        _ lines: [String],
        startingAt start: Int,
        finalIndex: Int
    ) throws -> (chunks: [PatchChunk], nextIndex: Int) {
        var chunks: [PatchChunk] = []
        var current: PatchChunk?
        var index = start

        func finishesUpdate(_ line: String) -> Bool {
            line.hasPrefix(add)
                || line.hasPrefix(delete)
                || line.hasPrefix(update)
                || line == end
        }

        func flush(_ chunk: inout PatchChunk?) {
            if let chunk {
                chunks.append(chunk)
            }
            chunk = nil
        }

        while index < finalIndex, !finishesUpdate(lines[index]) {
            let line = lines[index]
            if line == "@@" || line.hasPrefix("@@ ") {
                flush(&current)
                let context = line == "@@"
                    ? nil
                    : String(line.dropFirst(3))
                current = PatchChunk(
                    context: context,
                    oldLines: [],
                    newLines: [],
                    isEndOfFile: false
                )
            } else if line == "*** End of File" {
                guard current != nil else {
                    throw invalidHunk(
                        line: index + 1,
                        "End of File must follow change lines"
                    )
                }
                current?.isEndOfFile = true
                flush(&current)
                index += 1
                if index < finalIndex, !finishesUpdate(lines[index]) {
                    throw invalidHunk(
                        line: index + 1,
                        "unexpected content after End of File"
                    )
                }
                break
            } else if let prefix = line.first,
                      prefix == "+" || prefix == "-" || prefix == " "
            {
                if current == nil {
                    current = PatchChunk(
                        context: nil,
                        oldLines: [],
                        newLines: [],
                        isEndOfFile: false
                    )
                }
                let content = String(line.dropFirst())
                if prefix == "-" || prefix == " " {
                    current?.oldLines.append(content)
                }
                if prefix == "+" || prefix == " " {
                    current?.newLines.append(content)
                }
            } else {
                throw invalidHunk(
                    line: index + 1,
                    "expected @@ or a line starting with +, -, or space"
                )
            }
            index += 1
        }
        flush(&current)
        return (chunks, index)
    }

    private static func filename(
        after marker: String,
        in line: String
    ) throws -> String {
        let path = String(line.dropFirst(marker.count))
        guard !path.isEmpty else {
            throw CodexWorkspacePatchError.invalidPatch(
                "file path must not be empty"
            )
        }
        return path
    }

    private static func invalidHunk(
        line: Int,
        _ message: String
    ) -> CodexWorkspacePatchError {
        .invalidPatch("invalid hunk at line \(line): \(message)")
    }
}
