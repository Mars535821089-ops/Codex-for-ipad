#if SWIFT_PACKAGE
import CodexPadDomain
#endif
import Foundation

private let codexFuzzyFileSearchMatchLimit = 50
private let codexFuzzyFileSearchSkippedDirectoryNames:
    Set<String> = [
        ".build",
        ".git",
        ".swiftpm",
        "DerivedData",
        "node_modules",
    ]

public enum CodexDesktopFuzzyFileSearchError:
    Error,
    Equatable
{
    case invalidParams
    case invalidRoot(String)
    case sessionNotFound(String)
}

public struct CodexDesktopFuzzyFileSearchResult:
    Equatable,
    Sendable
{
    public enum MatchType: String, Equatable, Sendable {
        case file
        case directory
    }

    public let root: String
    public let path: String
    public let matchType: MatchType
    public let fileName: String
    public let score: UInt32
    public let indices: [UInt32]?

    public var json: CodexJSONValue {
        .object([
            "root": .string(root),
            "path": .string(path),
            "match_type": .string(matchType.rawValue),
            "file_name": .string(fileName),
            "score": .integer(Int64(score)),
            "indices": indices.map {
                .array($0.map { .integer(Int64($0)) })
            } ?? .null,
        ])
    }
}

@MainActor
public protocol CodexDesktopFuzzyFileSearching: AnyObject {
    func search(
        query: String,
        roots: [String],
        cancellationToken: String?,
        allowedRoots: [String]
    ) async throws -> [CodexDesktopFuzzyFileSearchResult]

    func startSession(
        sessionID: String,
        roots: [String],
        allowedRoots: [String]
    ) throws

    func updateSession(
        sessionID: String,
        query: String
    ) async throws

    func stopSession(sessionID: String)
}

@MainActor
public final class CodexDesktopFuzzyFileSearchService:
    CodexDesktopFuzzyFileSearching
{
    public typealias NotificationSink =
        @MainActor @Sendable (String, CodexJSONValue) -> Void

    private struct Session {
        let roots: [URL]
        var generation: UInt64
        var task:
            Task<[CodexDesktopFuzzyFileSearchResult], Never>?
    }

    private struct PendingSearch {
        let generation: UInt64
        let task:
            Task<[CodexDesktopFuzzyFileSearchResult], Never>
    }

    private let notificationSink: NotificationSink
    private var sessions: [String: Session] = [:]
    private var pendingSearches: [String: PendingSearch] = [:]
    private var nextGeneration: UInt64 = 0

    public init(
        notificationSink: @escaping NotificationSink
    ) {
        self.notificationSink = notificationSink
    }

    public func search(
        query: String,
        roots: [String],
        cancellationToken: String?,
        allowedRoots: [String]
    ) async throws -> [CodexDesktopFuzzyFileSearchResult] {
        let resolvedRoots = try Self.resolveRoots(
            roots,
            allowedRoots: allowedRoots
        )
        guard !query.isEmpty, !resolvedRoots.isEmpty else {
            return []
        }

        let generation = allocateGeneration()
        let task = Self.makeSearchTask(
            query: query,
            roots: resolvedRoots
        )
        if let cancellationToken {
            pendingSearches[cancellationToken]?.task.cancel()
            pendingSearches[cancellationToken] = PendingSearch(
                generation: generation,
                task: task
            )
        }

        let results = await task.value
        if let cancellationToken,
           pendingSearches[cancellationToken]?.generation
               == generation
        {
            pendingSearches.removeValue(
                forKey: cancellationToken
            )
        }
        return results
    }

    public func startSession(
        sessionID: String,
        roots: [String],
        allowedRoots: [String]
    ) throws {
        guard !sessionID.isEmpty else {
            throw CodexDesktopFuzzyFileSearchError.invalidParams
        }
        let resolvedRoots = try Self.resolveRoots(
            roots,
            allowedRoots: allowedRoots
        )
        sessions.removeValue(forKey: sessionID)?.task?.cancel()
        sessions[sessionID] = Session(
            roots: resolvedRoots,
            generation: allocateGeneration(),
            task: nil
        )
    }

    public func updateSession(
        sessionID: String,
        query: String
    ) async throws {
        guard var session = sessions[sessionID] else {
            throw CodexDesktopFuzzyFileSearchError
                .sessionNotFound(sessionID)
        }
        session.task?.cancel()
        let generation = allocateGeneration()
        let task = Self.makeSearchTask(
            query: query,
            roots: session.roots
        )
        session.generation = generation
        session.task = task
        sessions[sessionID] = session

        let results = query.isEmpty ? [] : await task.value
        guard let current = sessions[sessionID],
              current.generation == generation,
              !task.isCancelled
        else {
            return
        }
        sessions[sessionID]?.task = nil
        notificationSink(
            "fuzzyFileSearch/sessionUpdated",
            .object([
                "sessionId": .string(sessionID),
                "query": .string(query),
                "files": .array(results.map(\.json)),
            ])
        )
        notificationSink(
            "fuzzyFileSearch/sessionCompleted",
            .object(["sessionId": .string(sessionID)])
        )
    }

    public func stopSession(sessionID: String) {
        sessions.removeValue(forKey: sessionID)?.task?.cancel()
    }

    private func allocateGeneration() -> UInt64 {
        nextGeneration &+= 1
        return nextGeneration
    }

    private static func makeSearchTask(
        query: String,
        roots: [URL]
    ) -> Task<[CodexDesktopFuzzyFileSearchResult], Never> {
        Task.detached(priority: .userInitiated) {
            Self.collectMatches(query: query, roots: roots)
        }
    }

    private nonisolated static func collectMatches(
        query: String,
        roots: [URL]
    ) -> [CodexDesktopFuzzyFileSearchResult] {
        guard !query.isEmpty else { return [] }
        let manager = FileManager.default
        var matches: [CodexDesktopFuzzyFileSearchResult] = []

        for root in roots {
            guard !Task.isCancelled else { return [] }
            guard let enumerator = manager.enumerator(
                at: root,
                includingPropertiesForKeys: [
                    .isDirectoryKey,
                    .isRegularFileKey,
                    .isSymbolicLinkKey,
                ],
                options: [
                    .skipsHiddenFiles,
                    .skipsPackageDescendants,
                ]
            ) else {
                continue
            }

            for case let item as URL in enumerator {
                guard !Task.isCancelled else { return [] }
                let name = item.lastPathComponent
                let values = try? item.resourceValues(
                    forKeys: [
                        .isDirectoryKey,
                        .isRegularFileKey,
                        .isSymbolicLinkKey,
                    ]
                )
                if values?.isSymbolicLink == true {
                    if values?.isDirectory == true {
                        enumerator.skipDescendants()
                    }
                    continue
                }
                if values?.isDirectory == true,
                   codexFuzzyFileSearchSkippedDirectoryNames
                       .contains(name)
                {
                    enumerator.skipDescendants()
                    continue
                }
                guard values?.isDirectory == true
                        || values?.isRegularFile == true
                else {
                    continue
                }

                let relativePath = relativePath(
                    item,
                    root: root
                )
                guard let fuzzy = fuzzyMatch(
                    query: query,
                    candidate: relativePath
                ) else {
                    continue
                }
                matches.append(
                    CodexDesktopFuzzyFileSearchResult(
                        root: root.path,
                        path: relativePath,
                        matchType:
                            values?.isDirectory == true
                                ? .directory : .file,
                        fileName: name,
                        score: fuzzy.score,
                        indices: fuzzy.indices
                    )
                )
            }
        }

        matches.sort {
            if $0.score != $1.score {
                return $0.score > $1.score
            }
            return $0.path < $1.path
        }
        return Array(
            matches.prefix(codexFuzzyFileSearchMatchLimit)
        )
    }

    private nonisolated static func relativePath(
        _ item: URL,
        root: URL
    ) -> String {
        let canonicalItem =
            item.standardizedFileURL.resolvingSymlinksInPath()
        let canonicalRoot =
            root.standardizedFileURL.resolvingSymlinksInPath()
        let rootPath = canonicalRoot.path.hasSuffix("/")
            ? canonicalRoot.path : canonicalRoot.path + "/"
        guard canonicalItem.path.hasPrefix(rootPath) else {
            return canonicalItem.lastPathComponent
        }
        return String(
            canonicalItem.path.dropFirst(rootPath.count)
        )
    }

    private nonisolated static func fuzzyMatch(
        query: String,
        candidate: String
    ) -> (score: UInt32, indices: [UInt32])? {
        let queryCharacters = Array(query.lowercased())
        let candidateCharacters = Array(candidate.lowercased())
        guard !queryCharacters.isEmpty else { return nil }

        var indices: [UInt32] = []
        var queryOffset = 0
        for (candidateOffset, character)
            in candidateCharacters.enumerated()
        {
            guard queryOffset < queryCharacters.count else {
                break
            }
            if character == queryCharacters[queryOffset] {
                indices.append(UInt32(candidateOffset))
                queryOffset += 1
            }
        }
        guard queryOffset == queryCharacters.count else {
            return nil
        }

        var score = UInt32(queryCharacters.count * 16)
        if indices.first == 0 { score &+= 12 }
        for pair in zip(indices, indices.dropFirst())
            where pair.1 == pair.0 + 1
        {
            score &+= 8
        }
        let spread = Int(indices.last ?? 0)
            - Int(indices.first ?? 0)
        score &+= UInt32(
            max(0, 24 - spread)
        )
        score &+= UInt32(
            max(0, 16 - candidateCharacters.count / 4)
        )
        return (score, indices)
    }

    private static func resolveRoots(
        _ roots: [String],
        allowedRoots: [String]
    ) throws -> [URL] {
        try roots.map { rawRoot in
            guard !rawRoot.isEmpty,
                  !rawRoot.contains("\0"),
                  (rawRoot as NSString).isAbsolutePath
            else {
                throw CodexDesktopFuzzyFileSearchError
                    .invalidRoot(rawRoot)
            }
            let lexical = URL(
                fileURLWithPath: rawRoot,
                isDirectory: true
            ).standardizedFileURL
            let resolved =
                lexical.resolvingSymlinksInPath()
            guard allowedRoots.contains(where: {
                contains(
                    lexical,
                    in: URL(
                        fileURLWithPath: $0,
                        isDirectory: true
                    ).standardizedFileURL
                )
                && contains(
                    resolved,
                    in: URL(
                        fileURLWithPath: $0,
                        isDirectory: true
                    ).standardizedFileURL
                        .resolvingSymlinksInPath()
                )
            }) else {
                throw CodexDesktopFuzzyFileSearchError
                    .invalidRoot(rawRoot)
            }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(
                atPath: resolved.path,
                isDirectory: &isDirectory
            ), isDirectory.boolValue else {
                throw CodexDesktopFuzzyFileSearchError
                    .invalidRoot(rawRoot)
            }
            return resolved
        }
    }

    private static func contains(
        _ candidate: URL,
        in root: URL
    ) -> Bool {
        let candidatePath = candidate.path
        let rootPath = root.path
        return candidatePath == rootPath
            || candidatePath.hasPrefix(
                rootPath.hasSuffix("/")
                    ? rootPath : rootPath + "/"
            )
    }
}
