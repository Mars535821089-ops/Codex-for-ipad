import CodexPadApplication
import CodexPadDomain
import CodexPadProtocolBridge
import Foundation
import Testing

@MainActor
@Test
func fuzzyFileSearchReturnsRealRelativeMatchesAndOfficialFields()
    async throws
{
    let root = try fuzzySearchTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try Data("a".utf8).write(
        to: root.appendingPathComponent("alpha.txt")
    )
    let nested = root.appendingPathComponent(
        "Sources",
        isDirectory: true
    )
    try FileManager.default.createDirectory(
        at: nested,
        withIntermediateDirectories: true
    )
    try Data("b".utf8).write(
        to: nested.appendingPathComponent("Alphabet.swift")
    )
    try Data("z".utf8).write(
        to: root.appendingPathComponent("unrelated.txt")
    )

    let service = CodexDesktopFuzzyFileSearchService {
        _, _ in
    }
    let matches = try await service.search(
        query: "alp",
        roots: [root.path],
        cancellationToken: "picker",
        allowedRoots: [root.path]
    )

    #expect(matches.count == 2)
    #expect(matches.allSatisfy { $0.root == root.path })
    #expect(
        Set(matches.map(\.path))
            == ["alpha.txt", "Sources/Alphabet.swift"]
    )
    #expect(matches.allSatisfy { $0.matchType == .file })
    #expect(matches.allSatisfy { $0.indices?.count == 3 })
    #expect(
        matches.map(\.score)
            == matches.map(\.score).sorted(by: >)
    )
    guard case let .object(firstJSON) =
        try #require(matches.first?.json)
    else {
        Issue.record("missing official fuzzy result")
        return
    }
    #expect(firstJSON["match_type"] == .string("file"))
    #expect(firstJSON["file_name"] != nil)
    #expect(firstJSON["indices"] != nil)
}

@MainActor
@Test
func fuzzyFileSearchConfinesRootsAndHonorsEmptyQuery()
    async throws
{
    let allowed = try fuzzySearchTemporaryRoot()
    let outside = try fuzzySearchTemporaryRoot()
    defer {
        try? FileManager.default.removeItem(at: allowed)
        try? FileManager.default.removeItem(at: outside)
    }
    let service = CodexDesktopFuzzyFileSearchService {
        _, _ in
    }

    let empty = try await service.search(
        query: "",
        roots: [allowed.path],
        cancellationToken: nil,
        allowedRoots: [allowed.path]
    )
    #expect(empty.isEmpty)

    await #expect(throws: CodexDesktopFuzzyFileSearchError.self) {
        _ = try await service.search(
            query: "secret",
            roots: [outside.path],
            cancellationToken: nil,
            allowedRoots: [allowed.path]
        )
    }
}

@MainActor
@Test
func fuzzyFileSearchSessionEmitsUpdatedThenCompletedAndStops()
    async throws
{
    let root = try fuzzySearchTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try Data("a".utf8).write(
        to: root.appendingPathComponent("alpha.txt")
    )
    var notifications:
        [(method: String, params: CodexJSONValue)] = []
    let service = CodexDesktopFuzzyFileSearchService {
        method, params in
        notifications.append((method, params))
    }

    try service.startSession(
        sessionID: "picker-1",
        roots: [root.path],
        allowedRoots: [root.path]
    )
    try await service.updateSession(
        sessionID: "picker-1",
        query: "ALP"
    )
    #expect(
        notifications.map(\.method)
            == [
                "fuzzyFileSearch/sessionUpdated",
                "fuzzyFileSearch/sessionCompleted",
            ]
    )
    guard case let .object(updated) =
        notifications.first?.params,
        case let .array(files)? = updated["files"]
    else {
        Issue.record("missing fuzzy session snapshot")
        return
    }
    #expect(updated["sessionId"] == .string("picker-1"))
    #expect(updated["query"] == .string("ALP"))
    #expect(files.count == 1)

    notifications.removeAll()
    try await service.updateSession(
        sessionID: "picker-1",
        query: ""
    )
    guard case let .object(cleared) =
        notifications.first?.params
    else {
        Issue.record("missing cleared fuzzy snapshot")
        return
    }
    #expect(cleared["files"] == .array([]))

    service.stopSession(sessionID: "picker-1")
    service.stopSession(sessionID: "does-not-exist")
    await #expect(throws: CodexDesktopFuzzyFileSearchError.self) {
        try await service.updateSession(
            sessionID: "picker-1",
            query: "alp"
        )
    }
}

@MainActor
@Test
func fuzzyFileSearchRouterMatchesFourRequestContracts()
    async throws
{
    let root = try fuzzySearchTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try Data("a".utf8).write(
        to: root.appendingPathComponent("alpha.txt")
    )
    var notifications:
        [(String, CodexJSONValue)] = []
    let service = CodexDesktopFuzzyFileSearchService {
        notifications.append(($0, $1))
    }

    let legacy = await fuzzySearchRouterRequest(
        id: 8_001,
        method: "fuzzyFileSearch",
        params: [
            "query": .string("alp"),
            "roots": .array([.string(root.path)]),
            "cancellationToken": .null,
        ],
        root: root,
        service: service
    )
    guard case let .object(legacyResult) =
        fuzzySearchResult(legacy),
        case let .array(files)? = legacyResult["files"]
    else {
        Issue.record("invalid fuzzy legacy response")
        return
    }
    #expect(files.count == 1)

    let started = await fuzzySearchRouterRequest(
        id: 8_002,
        method: "fuzzyFileSearch/sessionStart",
        params: [
            "sessionId": .string("picker-router"),
            "roots": .array([.string(root.path)]),
        ],
        root: root,
        service: service
    )
    #expect(fuzzySearchResult(started) == .object([:]))

    let updated = await fuzzySearchRouterRequest(
        id: 8_003,
        method: "fuzzyFileSearch/sessionUpdate",
        params: [
            "sessionId": .string("picker-router"),
            "query": .string("alp"),
        ],
        root: root,
        service: service
    )
    #expect(fuzzySearchResult(updated) == .object([:]))
    #expect(notifications.count == 2)

    let stopped = await fuzzySearchRouterRequest(
        id: 8_004,
        method: "fuzzyFileSearch/sessionStop",
        params: ["sessionId": .string("picker-router")],
        root: root,
        service: service
    )
    #expect(fuzzySearchResult(stopped) == .object([:]))

    let invalid = await fuzzySearchRouterRequest(
        id: 8_005,
        method: "fuzzyFileSearch",
        params: [
            "query": .string("alp"),
            "roots": .array([.integer(1)]),
        ],
        root: root,
        service: service
    )
    #expect(fuzzySearchErrorCode(invalid) == -32602)
}

private func fuzzySearchTemporaryRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(
            "codex-fuzzy-\(UUID().uuidString)",
            isDirectory: true
        )
    try FileManager.default.createDirectory(
        at: root,
        withIntermediateDirectories: true
    )
    return root.resolvingSymlinksInPath().standardizedFileURL
}

@MainActor
private func fuzzySearchRouterRequest(
    id: Int64,
    method: String,
    params: [String: CodexJSONValue],
    root: URL,
    service: CodexDesktopFuzzyFileSearchService
) async -> CodexDesktopHostMessage {
    await CodexDesktopInitialMCPRouter
        .responseIncludingFileSystem(
            to: .init(
                request: .init(
                    id: .integer(id),
                    method: method,
                    params: .object(params),
                    metadata: [:]
                ),
                hostID: "desktop-host-fuzzy",
                dispatchedAtMs: nil,
                priority: nil,
                source: nil,
                timeoutMs: nil,
                expiresAtMs: nil,
                metadata: [:]
            ),
            state: .init(
                account: .init(
                    account: nil,
                    authMethod: nil,
                    requiresOpenAIAuth: true
                ),
                config: .init(
                    config: [:],
                    origins: [:],
                    layers: []
                ),
                remoteControl: .init(
                    status: .disabled,
                    serverName: "Codex for ipad",
                    installationID: "fuzzy",
                    environmentID: nil
                )
            ),
            allowedFileSystemRoots: [root.path],
            fuzzyFileSearch: service
        )
}

private func fuzzySearchResult(
    _ message: CodexDesktopHostMessage
) -> CodexJSONValue? {
    guard case let .mcpResponse(_, payload, _) = message,
          case let .object(envelope) = payload
    else { return nil }
    return envelope["result"]
}

private func fuzzySearchErrorCode(
    _ message: CodexDesktopHostMessage
) -> Int64? {
    guard case let .mcpResponse(_, payload, _) = message,
          case let .object(envelope) = payload,
          case let .object(error)? = envelope["error"],
          case let .integer(code)? = error["code"]
    else { return nil }
    return code
}
