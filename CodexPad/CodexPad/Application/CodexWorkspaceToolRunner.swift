#if SWIFT_PACKAGE
import CodexPadDomain
import CodexPadProtocolBridge
#endif
import Foundation

public enum CodexWorkspaceToolError: Error, Equatable, Sendable {
    case unsupportedTool
    case invalidArguments
    case unavailableWorkspace
}

public struct CodexWorkspaceToolExecution: Equatable, Sendable {
    public let output: String
    public let workspaceDiff: String?
    public let fileChanges: [CodexFileUpdateChange]?

    public init(
        output: String,
        workspaceDiff: String?,
        fileChanges: [CodexFileUpdateChange]? = nil
    ) {
        self.output = output
        self.workspaceDiff = workspaceDiff
        self.fileChanges = fileChanges
    }
}

public struct CodexWorkspaceToolRunner: Sendable {
    private let access: CodexWorkspaceAccess

    public init(access: CodexWorkspaceAccess = CodexWorkspaceAccess()) {
        self.access = access
    }

    public func execute(
        name: String,
        arguments: String,
        workspace: Workspace,
        cancellation: CodexTurnCancellation? = nil
    ) throws -> String {
        try executeDetailed(
            name: name,
            arguments: arguments,
            workspace: workspace,
            cancellation: cancellation
        ).output
    }

    public func executeDetailed(
        name: String,
        arguments: String,
        workspace: Workspace,
        cancellation: CodexTurnCancellation? = nil
    ) throws -> CodexWorkspaceToolExecution {
        try cancellation?.checkCancellation()
        guard let bookmark = workspace.rootBookmarkID else {
            throw CodexWorkspaceToolError.unavailableWorkspace
        }
        let data = Data(arguments.utf8)
        let decoder = JSONDecoder()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        switch name {
        case "list_workspace_files":
            let request = try decode(ListArguments.self, from: data, using: decoder)
            try cancellation?.checkCancellation()
            let files = try access.listFiles(
                bookmark: bookmark,
                limit: min(max(request.limit ?? 500, 1), 2_000)
            )
            try cancellation?.checkCancellation()
            return CodexWorkspaceToolExecution(
                output: try encodedString(
                    ListResult(
                        files: files.map {
                            ListResult.Entry(
                                path: $0.relativePath,
                                isDirectory: $0.isDirectory
                            )
                        }
                    ),
                    using: encoder
                ),
                workspaceDiff: nil
            )

        case "read_workspace_file":
            let request = try decode(PathArguments.self, from: data, using: decoder)
            try cancellation?.checkCancellation()
            let text = try access.readText(
                bookmark: bookmark,
                relativePath: request.path
            )
            try cancellation?.checkCancellation()
            return CodexWorkspaceToolExecution(
                output: try encodedString(
                    ReadResult(path: request.path, text: text),
                    using: encoder
                ),
                workspaceDiff: nil
            )

        case "search_workspace_text":
            let request = try decode(
                SearchArguments.self,
                from: data,
                using: decoder
            )
            guard !request.query.isEmpty else {
                throw CodexWorkspaceToolError.invalidArguments
            }
            let maximum = min(max(request.limit ?? 100, 1), 500)
            var matches: [SearchResult.Match] = []
            try cancellation?.checkCancellation()
            let files = try access.listFiles(bookmark: bookmark)
            for file in files where !file.isDirectory {
                try cancellation?.checkCancellation()
                guard let text = try? access.readText(
                    bookmark: bookmark,
                    relativePath: file.relativePath
                ) else {
                    continue
                }
                for (index, line) in text.split(
                    separator: "\n",
                    omittingEmptySubsequences: false
                ).enumerated()
                where line.localizedCaseInsensitiveContains(request.query) {
                    try cancellation?.checkCancellation()
                    matches.append(
                        SearchResult.Match(
                            path: file.relativePath,
                            line: index + 1,
                            text: String(line)
                        )
                    )
                    if matches.count == maximum {
                        break
                    }
                }
                if matches.count == maximum {
                    break
                }
            }
            try cancellation?.checkCancellation()
            return CodexWorkspaceToolExecution(
                output: try encodedString(
                    SearchResult(matches: matches),
                    using: encoder
                ),
                workspaceDiff: nil
            )

        case "write_workspace_file":
            let request = try decode(WriteArguments.self, from: data, using: decoder)
            try cancellation?.checkCancellation()
            let oldText = try? access.readText(
                bookmark: bookmark,
                relativePath: request.path
            )
            try cancellation?.checkCancellation()
            try access.writeText(
                bookmark: bookmark,
                relativePath: request.path,
                text: request.text
            )
            try cancellation?.checkCancellation()
            let diff = CodexUnifiedDiff.make(
                path: request.path,
                oldText: oldText,
                newText: request.text
            )
            return CodexWorkspaceToolExecution(
                output: try encodedString(
                    WriteResult(
                        path: request.path,
                        bytesWritten: request.text.utf8.count,
                        diff: diff
                    ),
                    using: encoder
                ),
                workspaceDiff: diff
            )

        case "apply_patch":
            let result = try CodexWorkspacePatchApplier(access: access).apply(
                patch: arguments,
                bookmark: bookmark,
                cancellation: cancellation
            )
            return CodexWorkspaceToolExecution(
                output: result.output,
                workspaceDiff: result.combinedDiff,
                fileChanges: result.fileChanges
            )

        default:
            throw CodexWorkspaceToolError.unsupportedTool
        }
    }

    private func decode<Value: Decodable>(
        _ type: Value.Type,
        from data: Data,
        using decoder: JSONDecoder
    ) throws -> Value {
        do {
            return try decoder.decode(type, from: data)
        } catch {
            throw CodexWorkspaceToolError.invalidArguments
        }
    }

    private func encodedString<Value: Encodable>(
        _ value: Value,
        using encoder: JSONEncoder
    ) throws -> String {
        let data = try encoder.encode(value)
        guard let string = String(data: data, encoding: .utf8) else {
            throw CodexWorkspaceToolError.invalidArguments
        }
        return string
    }
}

private struct ListArguments: Decodable {
    let limit: Int?
}

private struct PathArguments: Decodable {
    let path: String
}

private struct WriteArguments: Decodable {
    let path: String
    let text: String
}

private struct SearchArguments: Decodable {
    let query: String
    let limit: Int?
}

private struct ListResult: Encodable {
    struct Entry: Encodable {
        let path: String
        let isDirectory: Bool
    }

    let files: [Entry]
}

private struct ReadResult: Encodable {
    let path: String
    let text: String
}

private struct WriteResult: Encodable {
    let path: String
    let bytesWritten: Int
    let diff: String
}

private struct SearchResult: Encodable {
    struct Match: Encodable {
        let path: String
        let line: Int
        let text: String
    }

    let matches: [Match]
}
