import Foundation
import Testing

@testable import CodexPadApplication
@testable import CodexPadDomain
@testable import CodexPadProtocolBridge

@MainActor
private final class ExternalAgentMigrationProbe:
    CodexDesktopExternalAgentConfigMigrating
{
    var detectedOptions: CodexExternalAgentDetectOptions?
    var importedItems: [CodexExternalAgentMigrationItem]?

    func detectExternalAgentConfiguration(
        options: CodexExternalAgentDetectOptions
    ) throws -> [CodexExternalAgentMigrationItem] {
        detectedOptions = options
        return [
            CodexExternalAgentMigrationItem(
                itemType: "AGENTS_MD",
                description: "fixture",
                cwd: nil,
                details: nil
            )
        ]
    }

    func startExternalAgentConfigurationImport(
        migrationItems: [CodexExternalAgentMigrationItem],
        source _: String?,
        providerID _: String?,
        migrationSource _: String?
    ) -> String {
        importedItems = migrationItems
        return "import-fixture"
    }

    func recordExternalAgentConfigurationImportHistory(
        providerID _: String,
        itemTypeResults _: [CodexJSONValue]
    ) throws -> String {
        "history-fixture"
    }

    func readExternalAgentConfigurationImportHistories()
        throws -> CodexJSONValue
    {
        .object([
            "data": .array([]),
            "connectors": .array([]),
        ])
    }
}

private final class MonotonicClockFixture: @unchecked Sendable {
    private var reads = 0

    func next() -> TimeInterval {
        defer { reads += 1 }
        return reads == 0 ? 0 : 11
    }
}

private func externalAgentMCPState()
    -> CodexDesktopInitialMCPState
{
    CodexDesktopInitialMCPState(
        account: CodexDesktopMCPAccountState(
            account: nil,
            authMethod: nil,
            requiresOpenAIAuth: true
        ),
        config: CodexDesktopMCPConfigState(
            config: [:],
            origins: [:],
            layers: []
        ),
        remoteControl: CodexDesktopMCPRemoteControlState(
            status: .connected,
            serverName: "Codex-for-iPad",
            installationID: "installation-fixture",
            environmentID: "environment-fixture"
        )
    )
}

private func externalAgentMCPRequest(
    id: CodexAppServerRequestID,
    method: String,
    params: CodexJSONValue?
) -> CodexDesktopMCPRequest {
    CodexDesktopMCPRequest(
        request: CodexDesktopMCPRequestMessage(
            id: id,
            method: method,
            params: params,
            metadata: [:]
        ),
        hostID: "desktop-host-external-agent",
        dispatchedAtMs: .integer(1),
        priority: .string("normal"),
        source: .string("renderer"),
        timeoutMs: .integer(5_000),
        expiresAtMs: .integer(5_001),
        metadata: [:]
    )
}

private struct ExternalAgentFixture {
    let root: URL
    let home: URL
    let codexHome: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        home = root.appendingPathComponent("home", isDirectory: true)
        codexHome = root.appendingPathComponent(
            "codex-home",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent(".claude/skills/review"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent(".claude/commands"),
            withIntermediateDirectories: true
        )
        try Data("# Claude instructions\nUse Claude tools.\n".utf8)
            .write(to: home.appendingPathComponent(".claude/CLAUDE.md"))
        try Data("# Review\nCheck the patch.\n".utf8)
            .write(
                to: home.appendingPathComponent(
                    ".claude/skills/review/SKILL.md"
                )
            )
        try Data("Summarize this repository.\n".utf8)
            .write(
                to: home.appendingPathComponent(
                    ".claude/commands/summarize.md"
                )
            )
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

private let coworkDeferredWarning =
    "Some Claude Cowork chats were deferred because history discovery reached its safety limits."

private func writeCoworkTranscript(
    _ fixture: ExternalAgentFixture,
    name: String,
    title: String,
    modifiedAt: Date,
    paddingBytes: Int = 0,
    messageCount: Int = 1
) throws -> URL {
    let project = fixture.home.appendingPathComponent(
        ".claude/projects/project-one",
        isDirectory: true
    )
    try FileManager.default.createDirectory(
        at: project,
        withIntermediateDirectories: true
    )
    let transcript = project.appendingPathComponent("\(name).jsonl")
    var data = Data()
    for _ in 0..<messageCount {
        data.append(
            Data(
                "{\"type\":\"user\",\"cwd\":\"/workspace\",\"title\":\"\(title)\"}\n".utf8
            )
        )
    }
    data.append(Data(repeating: 0x20, count: paddingBytes))
    try data.write(to: transcript)
    try FileManager.default.setAttributes(
        [.modificationDate: modifiedAt],
        ofItemAtPath: transcript.path
    )
    return transcript
}

private func detectedCoworkSessionPaths(
    _ items: [CodexExternalAgentMigrationItem]
) -> [String] {
    guard let sessionsItem = items.first(where: {
        $0.itemType == "SESSIONS"
    }),
        case let .object(details)? = sessionsItem.details,
        case let .array(sessions)? = details["sessions"]
    else { return [] }
    return sessions.compactMap { value in
        guard case let .object(fields) = value,
              case let .string(path)? = fields["path"]
        else { return nil }
        return URL(fileURLWithPath: path).standardizedFileURL.path
    }
}

private func coworkSessionDetails(
    _ items: [CodexExternalAgentMigrationItem]
) -> [[String: CodexJSONValue]] {
    guard let sessionsItem = items.first(where: {
        $0.itemType == "SESSIONS"
    }),
        case let .object(details)? = sessionsItem.details,
        case let .array(sessions)? = details["sessions"]
    else { return [] }
    return sessions.compactMap { value in
        guard case let .object(fields) = value else { return nil }
        return fields
    }
}

private func normalizedPath(_ url: URL) -> String {
    url.standardizedFileURL.path
}

@Test @MainActor
func externalAgentConfigDetectsRealHomeInstructionsSkillsAndCommands()
    throws
{
    let fixture = try ExternalAgentFixture()
    defer { fixture.remove() }
    let service = CodexExternalAgentConfigMigrationService(
        codexHome: fixture.codexHome,
        userHome: fixture.home,
        sendNotification: { _, _ in }
    )

    let items = try service.detectExternalAgentConfiguration(
        options: CodexExternalAgentDetectOptions(includeHome: true)
    )
    let types = Set(items.map(\.itemType))

    #expect(types.contains("AGENTS_MD"))
    #expect(types.contains("SKILLS"))
    #expect(types.contains("COMMANDS"))
    #expect(items.allSatisfy { $0.cwd == nil })
}

@Test @MainActor
func externalAgentConfigDefersCoworkDiscoveryAfterDirectoryEntryBudget()
    throws
{
    #expect(CodexCoworkDiscoveryLimits.desktop.directoryEntries == 20_000)
    let fixture = try ExternalAgentFixture()
    defer { fixture.remove() }
    let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
    let expected = try writeCoworkTranscript(
        fixture,
        name: "000-newest",
        title: "Newest",
        modifiedAt: timestamp
    )
    let project = expected.deletingLastPathComponent()
    try Data("noise".utf8).write(
        to: project.appendingPathComponent("zzz-noise-one.txt")
    )
    try Data("noise".utf8).write(
        to: project.appendingPathComponent("zzz-noise-two.txt")
    )
    let service = CodexExternalAgentConfigMigrationService(
        codexHome: fixture.codexHome,
        userHome: fixture.home,
        now: { timestamp.addingTimeInterval(60) },
        monotonicNow: { 0 },
        discoveryLimits: CodexCoworkDiscoveryLimits(
            duration: 10,
            directoryEntries: 3,
            sessionAttempts: 500,
            transcriptBytes: 64 * 1_024 * 1_024,
            transcriptFileBytes: 8 * 1_024 * 1_024
        ),
        sendNotification: { _, _ in }
    )

    let items = try service.detectExternalAgentConfiguration(
        options: CodexExternalAgentDetectOptions(
            includeHome: true,
            maxSessionAgeDays: 30,
            maxSessions: 50
        )
    )

    #expect(detectedCoworkSessionPaths(items) == [normalizedPath(expected)])
    #expect(service.lastDetectionWarnings == [coworkDeferredWarning])
}

@Test
func externalAgentConfigMatchesReleasedCoworkDiscoveryBudgetConstants() {
    let limits = CodexCoworkDiscoveryLimits.desktop
    #expect(limits.duration == 10)
    #expect(limits.directoryEntries == 20_000)
    #expect(limits.manifestAttempts == 2_000)
    #expect(limits.manifestBytes == 32 * 1_024 * 1_024)
    #expect(limits.manifestFileBytes == 4 * 1_024 * 1_024)
    #expect(limits.sessionAttempts == 500)
    #expect(limits.sessionBytes == 16 * 1_024 * 1_024)
    #expect(limits.sessionMessages == 10_000)
    #expect(limits.transcriptBytes == 64 * 1_024 * 1_024)
    #expect(limits.transcriptFileBytes == 8 * 1_024 * 1_024)
}

@Test @MainActor
func externalAgentConfigDefersCoworkDiscoveryAfterSessionAttemptBudget()
    throws
{
    #expect(CodexCoworkDiscoveryLimits.desktop.sessionAttempts == 500)
    let fixture = try ExternalAgentFixture()
    defer { fixture.remove() }
    let base = Date(timeIntervalSince1970: 1_700_000_000)
    let oldest = try writeCoworkTranscript(
        fixture,
        name: "oldest",
        title: "Oldest",
        modifiedAt: base
    )
    let middle = try writeCoworkTranscript(
        fixture,
        name: "middle",
        title: "Middle",
        modifiedAt: base.addingTimeInterval(10)
    )
    let newest = try writeCoworkTranscript(
        fixture,
        name: "newest",
        title: "Newest",
        modifiedAt: base.addingTimeInterval(20)
    )
    let service = CodexExternalAgentConfigMigrationService(
        codexHome: fixture.codexHome,
        userHome: fixture.home,
        now: { base.addingTimeInterval(60) },
        monotonicNow: { 0 },
        discoveryLimits: CodexCoworkDiscoveryLimits(
            duration: 10,
            directoryEntries: 20_000,
            sessionAttempts: 2,
            transcriptBytes: 64 * 1_024 * 1_024,
            transcriptFileBytes: 8 * 1_024 * 1_024
        ),
        sendNotification: { _, _ in }
    )

    let items = try service.detectExternalAgentConfiguration(
        options: CodexExternalAgentDetectOptions(
            includeHome: true,
            maxSessionAgeDays: 30,
            maxSessions: 50
        )
    )
    let paths = detectedCoworkSessionPaths(items)

    #expect(paths == [normalizedPath(newest), normalizedPath(middle)])
    #expect(!paths.contains(oldest.path))
    #expect(service.lastDetectionWarnings == [coworkDeferredWarning])
}

@Test @MainActor
func externalAgentConfigDefersCoworkDiscoveryAfterTranscriptByteBudget()
    throws
{
    #expect(
        CodexCoworkDiscoveryLimits.desktop.transcriptBytes
            == 64 * 1_024 * 1_024
    )
    let fixture = try ExternalAgentFixture()
    defer { fixture.remove() }
    let base = Date(timeIntervalSince1970: 1_700_000_000)
    let first = try writeCoworkTranscript(
        fixture,
        name: "first",
        title: "First",
        modifiedAt: base.addingTimeInterval(30),
        paddingBytes: 32
    )
    let second = try writeCoworkTranscript(
        fixture,
        name: "second",
        title: "Second",
        modifiedAt: base.addingTimeInterval(20),
        paddingBytes: 32
    )
    let third = try writeCoworkTranscript(
        fixture,
        name: "third",
        title: "Third",
        modifiedAt: base.addingTimeInterval(10),
        paddingBytes: 32
    )
    let firstSize = try first.resourceValues(
        forKeys: [.fileSizeKey]
    ).fileSize ?? 0
    let secondSize = try second.resourceValues(
        forKeys: [.fileSizeKey]
    ).fileSize ?? 0
    let service = CodexExternalAgentConfigMigrationService(
        codexHome: fixture.codexHome,
        userHome: fixture.home,
        now: { base.addingTimeInterval(60) },
        monotonicNow: { 0 },
        discoveryLimits: CodexCoworkDiscoveryLimits(
            duration: 10,
            directoryEntries: 20_000,
            sessionAttempts: 500,
            transcriptBytes: firstSize + secondSize,
            transcriptFileBytes: 8 * 1_024 * 1_024
        ),
        sendNotification: { _, _ in }
    )

    let items = try service.detectExternalAgentConfiguration(
        options: CodexExternalAgentDetectOptions(
            includeHome: true,
            maxSessionAgeDays: 30,
            maxSessions: 50
        )
    )
    let paths = detectedCoworkSessionPaths(items)

    #expect(paths == [normalizedPath(first), normalizedPath(second)])
    #expect(!paths.contains(third.path))
    #expect(service.lastDetectionWarnings == [coworkDeferredWarning])
}

@Test @MainActor
func externalAgentConfigDefersCoworkDiscoveryAfterSessionByteBudget()
    throws
{
    let fixture = try ExternalAgentFixture()
    defer { fixture.remove() }
    let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
    let transcript = try writeCoworkTranscript(
        fixture,
        name: "session-budget",
        title: "Session budget",
        modifiedAt: timestamp
    )
    let transcriptSize = try Data(contentsOf: transcript).count
    let service = CodexExternalAgentConfigMigrationService(
        codexHome: fixture.codexHome,
        userHome: fixture.home,
        now: { timestamp.addingTimeInterval(60) },
        discoveryLimits: CodexCoworkDiscoveryLimits(
            duration: 10,
            directoryEntries: 20_000,
            manifestAttempts: 2_000,
            manifestBytes: 32 * 1_024 * 1_024,
            manifestFileBytes: 4 * 1_024 * 1_024,
            sessionAttempts: 500,
            sessionBytes: transcriptSize - 1,
            sessionMessages: 10_000,
            transcriptBytes: 64 * 1_024 * 1_024,
            transcriptFileBytes: 8 * 1_024 * 1_024
        ),
        sendNotification: { _, _ in }
    )

    let items = try service.detectExternalAgentConfiguration(
        options: CodexExternalAgentDetectOptions(includeHome: true)
    )

    #expect(detectedCoworkSessionPaths(items).isEmpty)
    #expect(service.lastDetectionWarnings == [coworkDeferredWarning])
}

@Test @MainActor
func externalAgentConfigDefersCoworkDiscoveryAfterSessionMessageBudget()
    throws
{
    let fixture = try ExternalAgentFixture()
    defer { fixture.remove() }
    let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
    _ = try writeCoworkTranscript(
        fixture,
        name: "message-budget",
        title: "Message budget",
        modifiedAt: timestamp,
        messageCount: 2
    )
    let service = CodexExternalAgentConfigMigrationService(
        codexHome: fixture.codexHome,
        userHome: fixture.home,
        now: { timestamp.addingTimeInterval(60) },
        discoveryLimits: CodexCoworkDiscoveryLimits(
            duration: 10,
            directoryEntries: 20_000,
            manifestAttempts: 2_000,
            manifestBytes: 32 * 1_024 * 1_024,
            manifestFileBytes: 4 * 1_024 * 1_024,
            sessionAttempts: 500,
            sessionBytes: 16 * 1_024 * 1_024,
            sessionMessages: 1,
            transcriptBytes: 64 * 1_024 * 1_024,
            transcriptFileBytes: 8 * 1_024 * 1_024
        ),
        sendNotification: { _, _ in }
    )

    let items = try service.detectExternalAgentConfiguration(
        options: CodexExternalAgentDetectOptions(includeHome: true)
    )

    #expect(detectedCoworkSessionPaths(items).isEmpty)
    #expect(service.lastDetectionWarnings == [coworkDeferredWarning])
}

@Test @MainActor
func externalAgentConfigCountsOnlyProjectableCoworkMessages() throws {
    let fixture = try ExternalAgentFixture()
    defer { fixture.remove() }
    let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
    let project = fixture.home.appendingPathComponent(
        ".claude/projects/project-one",
        isDirectory: true
    )
    try FileManager.default.createDirectory(
        at: project,
        withIntermediateDirectories: true
    )
    let transcript = project.appendingPathComponent("projectable.jsonl")
    try Data(
        """
        {"type":"user","message":{"role":"user"}}
        {"type":"progress","isMeta":true}
        {"type":"assistant","message":{"role":"assistant"}}
        {"type":"user","isSidechain":true}

        """.utf8
    ).write(to: transcript)
    try FileManager.default.setAttributes(
        [.modificationDate: timestamp],
        ofItemAtPath: transcript.path
    )
    let service = CodexExternalAgentConfigMigrationService(
        codexHome: fixture.codexHome,
        userHome: fixture.home,
        now: { timestamp.addingTimeInterval(60) },
        discoveryLimits: CodexCoworkDiscoveryLimits(
            duration: 10,
            directoryEntries: 20_000,
            sessionAttempts: 500,
            sessionBytes: 16 * 1_024 * 1_024,
            sessionMessages: 2,
            transcriptBytes: 64 * 1_024 * 1_024,
            transcriptFileBytes: 8 * 1_024 * 1_024
        ),
        sendNotification: { _, _ in }
    )

    let items = try service.detectExternalAgentConfiguration(
        options: CodexExternalAgentDetectOptions(includeHome: true)
    )

    #expect(detectedCoworkSessionPaths(items) == [normalizedPath(transcript)])
    #expect(service.lastDetectionWarnings.isEmpty)
}

@Test @MainActor
func externalAgentConfigDiscoversCoworkManifestAndUsesManifestMetadata()
    throws
{
    let fixture = try ExternalAgentFixture()
    defer { fixture.remove() }

    let manifestDirectory = fixture.home.appendingPathComponent(
        ".claude/local-agent-mode-sessions/account/org",
        isDirectory: true
    )
    try FileManager.default.createDirectory(
        at: manifestDirectory,
        withIntermediateDirectories: true
    )
    let manifest = manifestDirectory.appendingPathComponent(
        "manifest-session.json"
    )
    try Data(
        "{\"sessionId\":\"manifest-session\",\"cwd\":\"/manifest-workspace\",\"title\":\"Manifest title\",\"updatedAt\":\"2026-08-19T10:00:00Z\"}".utf8
    ).write(to: manifest)

    let transcript = try writeCoworkTranscript(
        fixture,
        name: "manifest-session",
        title: "Transcript title",
        modifiedAt: Date(timeIntervalSince1970: 1_787_130_000)
    )

    let service = CodexExternalAgentConfigMigrationService(
        codexHome: fixture.codexHome,
        userHome: fixture.home,
        sendNotification: { _, _ in }
    )
    let items = try service.detectExternalAgentConfiguration(
        options: CodexExternalAgentDetectOptions(includeHome: true)
    )
    let sessions = coworkSessionDetails(items)

    #expect(sessions.contains { fields in
        fields["path"] == .string(normalizedPath(transcript))
            && fields["cwd"] == .string("/manifest-workspace")
            && fields["title"] == .string("Manifest title")
    })
}

@Test @MainActor
func externalAgentConfigTreatsManifestFileBytesAsPerFileCap() throws {
    let fixture = try ExternalAgentFixture()
    defer { fixture.remove() }
    let manifestDirectory = fixture.home.appendingPathComponent(
        ".claude/local-agent-mode-sessions/account/org",
        isDirectory: true
    )
    try FileManager.default.createDirectory(
        at: manifestDirectory,
        withIntermediateDirectories: true
    )

    let manifestData = Data(
        "{\"sessionId\":\"manifest-one\",\"cwd\":\"/one\",\"title\":\"One\"}".utf8
    )
    let firstManifest = manifestDirectory.appendingPathComponent(
        "manifest-one.json"
    )
    let secondManifest = manifestDirectory.appendingPathComponent(
        "manifest-two.json"
    )
    try manifestData.write(to: firstManifest)
    try Data(
        "{\"sessionId\":\"manifest-two\",\"cwd\":\"/two\",\"title\":\"Two\"}".utf8
    ).write(to: secondManifest)

    _ = try writeCoworkTranscript(
        fixture,
        name: "manifest-one",
        title: "Transcript one",
        modifiedAt: Date(timeIntervalSince1970: 1_787_130_000)
    )
    _ = try writeCoworkTranscript(
        fixture,
        name: "manifest-two",
        title: "Transcript two",
        modifiedAt: Date(timeIntervalSince1970: 1_787_130_000)
    )

    let service = CodexExternalAgentConfigMigrationService(
        codexHome: fixture.codexHome,
        userHome: fixture.home,
        now: { Date(timeIntervalSince1970: 1_787_130_060) },
        discoveryLimits: CodexCoworkDiscoveryLimits(
            duration: 10,
            directoryEntries: 20_000,
            manifestAttempts: 2_000,
            manifestBytes: 1_024,
            manifestFileBytes: manifestData.count,
            sessionAttempts: 500,
            sessionBytes: 16 * 1_024 * 1_024,
            sessionMessages: 10_000,
            transcriptBytes: 64 * 1_024 * 1_024,
            transcriptFileBytes: 8 * 1_024 * 1_024
        ),
        sendNotification: { _, _ in }
    )

    let items = try service.detectExternalAgentConfiguration(
        options: CodexExternalAgentDetectOptions(includeHome: true)
    )
    let sessions = coworkSessionDetails(items)

    #expect(sessions.count == 2)
    #expect(service.lastDetectionWarnings.isEmpty)
}

@Test @MainActor
func externalAgentConfigProjectsManifestActivityMetadataAndSourceIdentity()
    throws
{
    let fixture = try ExternalAgentFixture()
    defer { fixture.remove() }
    let manifestDirectory = fixture.home.appendingPathComponent(
        ".claude/local-agent-mode-sessions/account/org/agent",
        isDirectory: true
    )
    try FileManager.default.createDirectory(
        at: manifestDirectory,
        withIntermediateDirectories: true
    )
    let manifest = manifestDirectory.appendingPathComponent(
        "activity-session.json"
    )
    try Data(
        """
        {"id":"activity-session","cwd":"/manifest-cwd","title":"Manifest title","createdAt":"2026-08-19T09:00:00Z","updatedAt":"2026-08-19T10:00:00Z","lastActivityAt":"2026-08-19T11:00:00Z","cliSessionId":"cli-123","fsDetectedFiles":["/manifest-cwd/one.swift"]}
        """.utf8
    ).write(to: manifest)
    let transcript = try writeCoworkTranscript(
        fixture,
        name: "activity-session",
        title: "Transcript title",
        modifiedAt: Date(timeIntervalSince1970: 1_787_130_000)
    )

    let service = CodexExternalAgentConfigMigrationService(
        codexHome: fixture.codexHome,
        userHome: fixture.home,
        now: { Date(timeIntervalSince1970: 1_787_130_060) },
        sendNotification: { _, _ in }
    )
    let items = try service.detectExternalAgentConfiguration(
        options: CodexExternalAgentDetectOptions(includeHome: true)
    )
    let sessions = coworkSessionDetails(items)

    #expect(sessions.count == 1)
    #expect(sessions[0]["sourceJsonlPath"] == .string(normalizedPath(transcript)))
    #expect(sessions[0]["sourceJsonlPaths"] == .array([.string(normalizedPath(transcript))]))
    #expect(sessions[0]["sourceId"] == .string("cli-123"))
    #expect(sessions[0]["workspaceKind"] == .string("project"))
    #expect(sessions[0]["projectRoot"] == .string("/manifest-cwd"))
    #expect(sessions[0]["lastActivityAtMs"] == .integer(1_787_137_200_000))
    #expect(sessions[0]["fsDetectedFiles"] == .array([.string("/manifest-cwd/one.swift")]))
}

@Test @MainActor
func externalAgentConfigMergesAccountAndAgentManifestMetadataForOneSession()
    throws
{
    let fixture = try ExternalAgentFixture()
    defer { fixture.remove() }
    let root = fixture.home.appendingPathComponent(
        ".claude/local-agent-mode-sessions/account/org",
        isDirectory: true
    )
    let agent = root.appendingPathComponent("agent", isDirectory: true)
    try FileManager.default.createDirectory(at: agent, withIntermediateDirectories: true)
    try Data(
        #"{"sessionId":"merge-session","cwd":"/account-cwd","updatedAt":"2026-08-19T10:00:00Z"}"#.utf8
    ).write(to: root.appendingPathComponent("merge-session.json"))
    try Data(
        #"{"sessionId":"merge-session","title":"Agent title","lastActivityAt":"2026-08-19T11:00:00Z","cliSessionId":"cli-merge"}"#.utf8
    ).write(to: agent.appendingPathComponent("merge-session-agent.json"))
    let transcript = try writeCoworkTranscript(
        fixture,
        name: "merge-session",
        title: "Transcript title",
        modifiedAt: Date(timeIntervalSince1970: 1_787_130_000)
    )

    let service = CodexExternalAgentConfigMigrationService(
        codexHome: fixture.codexHome,
        userHome: fixture.home,
        now: { Date(timeIntervalSince1970: 1_787_130_060) },
        sendNotification: { _, _ in }
    )
    let items = try service.detectExternalAgentConfiguration(
        options: CodexExternalAgentDetectOptions(includeHome: true)
    )
    let sessions = coworkSessionDetails(items)

    #expect(sessions.count == 1)
    #expect(sessions[0]["sourceJsonlPath"] == .string(normalizedPath(transcript)))
    #expect(sessions[0]["cwd"] == .string("/account-cwd"))
    #expect(sessions[0]["title"] == .string("Agent title"))
    #expect(sessions[0]["sourceId"] == .string("cli-merge"))
    #expect(sessions[0]["lastActivityAtMs"] == .integer(1_787_137_200_000))
}

@Test @MainActor
func externalAgentConfigDefersCoworkDiscoveryAtDesktopDeadline()
    throws
{
    #expect(CodexCoworkDiscoveryLimits.desktop.duration == 10)
    let fixture = try ExternalAgentFixture()
    defer { fixture.remove() }
    let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
    _ = try writeCoworkTranscript(
        fixture,
        name: "deadline",
        title: "Deadline",
        modifiedAt: timestamp
    )
    let clock = MonotonicClockFixture()
    let service = CodexExternalAgentConfigMigrationService(
        codexHome: fixture.codexHome,
        userHome: fixture.home,
        now: { timestamp.addingTimeInterval(60) },
        monotonicNow: { clock.next() },
        discoveryLimits: .desktop,
        sendNotification: { _, _ in }
    )

    let items = try service.detectExternalAgentConfiguration(
        options: CodexExternalAgentDetectOptions(
            includeHome: true,
            maxSessionAgeDays: 30,
            maxSessions: 50
        )
    )

    #expect(detectedCoworkSessionPaths(items).isEmpty)
    #expect(service.lastDetectionWarnings == [coworkDeferredWarning])
}

@Test @MainActor
func externalAgentConfigImportsDetectedFilesAndEmitsCompletion()
    async throws
{
    let fixture = try ExternalAgentFixture()
    defer { fixture.remove() }
    var notifications: [(String, CodexJSONValue)] = []
    let service = CodexExternalAgentConfigMigrationService(
        codexHome: fixture.codexHome,
        userHome: fixture.home,
        sendNotification: { method, params in
            notifications.append((method, params))
        }
    )
    let detected = try service.detectExternalAgentConfiguration(
        options: CodexExternalAgentDetectOptions(includeHome: true)
    ).filter {
        ["AGENTS_MD", "SKILLS", "COMMANDS"].contains($0.itemType)
    }

    let importID = service.startExternalAgentConfigurationImport(
        migrationItems: detected,
        source: "settings",
        providerID: "fixture-provider",
        migrationSource: nil
    )
    for _ in 0..<100 where
        !notifications.contains(where: {
            $0.0 == "externalAgentConfig/import/completed"
        })
    {
        await Task.yield()
    }

    #expect(!importID.isEmpty)
    #expect(
        notifications.filter {
            $0.0 == "externalAgentConfig/import/progress"
        }.count == detected.count
    )
    #expect(
        notifications.contains {
            $0.0 == "externalAgentConfig/import/completed"
        }
    )
    let agents = fixture.codexHome.appendingPathComponent("AGENTS.md")
    let review = fixture.codexHome.appendingPathComponent(
        "skills/review/SKILL.md"
    )
    let command = fixture.codexHome.appendingPathComponent(
        "skills/summarize/SKILL.md"
    )
    #expect(FileManager.default.fileExists(atPath: agents.path))
    #expect(FileManager.default.fileExists(atPath: review.path))
    #expect(FileManager.default.fileExists(atPath: command.path))
    #expect(
        try String(contentsOf: agents, encoding: .utf8)
            .contains("Codex")
    )
}

@Test @MainActor
func externalAgentConfigRejectsCoworkTranscriptOverDesktopLimitBeforeCopy()
    async throws
{
    let fixture = try ExternalAgentFixture()
    defer { fixture.remove() }
    let projects = fixture.home.appendingPathComponent(
        ".claude/projects/project-one",
        isDirectory: true
    )
    try FileManager.default.createDirectory(
        at: projects,
        withIntermediateDirectories: true
    )
    let transcript = projects.appendingPathComponent("oversized.jsonl")
    try Data(count: 8 * 1_024 * 1_024 + 1).write(to: transcript)
    var notifications: [(String, CodexJSONValue)] = []
    let service = CodexExternalAgentConfigMigrationService(
        codexHome: fixture.codexHome,
        userHome: fixture.home,
        sendNotification: { method, params in
            notifications.append((method, params))
        }
    )

    _ = service.startExternalAgentConfigurationImport(
        migrationItems: [
            CodexExternalAgentMigrationItem(
                itemType: "SESSIONS",
                description: "oversized Cowork transcript",
                cwd: nil,
                details: .object([
                    "sessions": .array([
                        .object([
                            "path": .string(transcript.path),
                            "cwd": .string("/workspace"),
                            "title": .string("Oversized"),
                        ])
                    ])
                ])
            )
        ],
        source: "settings",
        providerID: "fixture-provider",
        migrationSource: nil
    )
    for _ in 0..<100 where
        !notifications.contains(where: {
            $0.0 == "externalAgentConfig/import/completed"
        })
    {
        await Task.yield()
    }

    guard let progress = notifications.first(where: {
        $0.0 == "externalAgentConfig/import/progress"
    }),
        case let .object(progressFields) = progress.1,
        case let .array(results)? = progressFields["itemTypeResults"],
        case let .object(result)? = results.first,
        case let .array(failures)? = result["failures"],
        case let .object(failure)? = failures.first
    else {
        Issue.record("Expected a bounded Cowork import failure")
        return
    }
    #expect(failure["errorType"] == .string("cowork-history-limit"))
    #expect(
        failure["message"]
            == .string(
                "The selected Claude Cowork history exceeds the safe import limit."
            )
    )
    #expect(
        !FileManager.default.fileExists(
            atPath: fixture.codexHome.appendingPathComponent(
                "sessions/imported/oversized.jsonl"
            ).path
        )
    )
}

@Test @MainActor
func externalAgentConfigImportBudgetIgnoresNonProjectableCoworkRecords()
    async throws
{
    let fixture = try ExternalAgentFixture()
    defer { fixture.remove() }
    let projects = fixture.home.appendingPathComponent(
        ".claude/projects/project-one",
        isDirectory: true
    )
    try FileManager.default.createDirectory(
        at: projects,
        withIntermediateDirectories: true
    )
    let transcript = projects.appendingPathComponent("meta-heavy.jsonl")
    var data = Data()
    for _ in 0..<10_001 {
        data.append(Data("{\"type\":\"progress\",\"isMeta\":true}\n".utf8))
    }
    data.append(Data("{\"type\":\"user\",\"cwd\":\"/workspace\"}\n".utf8))
    try data.write(to: transcript)
    var notifications: [(String, CodexJSONValue)] = []
    let service = CodexExternalAgentConfigMigrationService(
        codexHome: fixture.codexHome,
        userHome: fixture.home,
        sendNotification: { method, params in
            notifications.append((method, params))
        }
    )

    _ = service.startExternalAgentConfigurationImport(
        migrationItems: [
            CodexExternalAgentMigrationItem(
                itemType: "SESSIONS",
                description: "meta-heavy Cowork history",
                cwd: nil,
                details: .object([
                    "sessions": .array([
                        .object([
                            "path": .string(transcript.path),
                            "cwd": .string("/workspace"),
                            "title": .string("Meta heavy"),
                        ])
                    ])
                ])
            )
        ],
        source: "settings",
        providerID: "fixture-provider",
        migrationSource: nil
    )
    for _ in 0..<100 where
        !notifications.contains(where: {
            $0.0 == "externalAgentConfig/import/completed"
        })
    {
        await Task.yield()
    }

    guard let progress = notifications.first(where: {
        $0.0 == "externalAgentConfig/import/progress"
    }),
        case let .object(progressFields) = progress.1,
        case let .array(results)? = progressFields["itemTypeResults"],
        case let .object(result)? = results.first
    else {
        Issue.record("Expected a bounded Cowork import result")
        return
    }
    #expect(result["failures"] == .array([]))
    #expect(result["successes"] != .array([]))
}

@Test @MainActor
func externalAgentConfigMapsUnreadableCoworkSelectionToStableSafeFailure()
    async throws
{
    let fixture = try ExternalAgentFixture()
    defer { fixture.remove() }
    let projects = fixture.home.appendingPathComponent(
        ".claude/projects/project-secret-marker",
        isDirectory: true
    )
    let transcriptDirectory = projects.appendingPathComponent(
        "unreadable-secret-marker.jsonl",
        isDirectory: true
    )
    try FileManager.default.createDirectory(
        at: transcriptDirectory,
        withIntermediateDirectories: true
    )
    var notifications: [(String, CodexJSONValue)] = []
    let service = CodexExternalAgentConfigMigrationService(
        codexHome: fixture.codexHome,
        userHome: fixture.home,
        sendNotification: { method, params in
            notifications.append((method, params))
        }
    )

    _ = service.startExternalAgentConfigurationImport(
        migrationItems: [
            CodexExternalAgentMigrationItem(
                itemType: "SESSIONS",
                description: "unreadable Cowork transcript",
                cwd: nil,
                details: .object([
                    "sessions": .array([
                        .object([
                            "path": .string(transcriptDirectory.path),
                            "cwd": .string("/workspace"),
                            "title": .string("Unreadable"),
                        ])
                    ])
                ])
            )
        ],
        source: "settings",
        providerID: "fixture-provider",
        migrationSource: nil
    )
    for _ in 0..<100 where
        !notifications.contains(where: {
            $0.0 == "externalAgentConfig/import/completed"
        })
    {
        await Task.yield()
    }

    guard let progress = notifications.first(where: {
        $0.0 == "externalAgentConfig/import/progress"
    }),
        case let .object(progressFields) = progress.1,
        case let .array(results)? = progressFields["itemTypeResults"],
        case let .object(result)? = results.first,
        case let .array(failures)? = result["failures"],
        case let .object(failure)? = failures.first
    else {
        Issue.record("Expected an unreadable Cowork import failure")
        return
    }
    #expect(failure["errorType"] == .string("cowork-history-unreadable"))
    #expect(
        failure["message"]
            == .string("Could not read the selected Claude Cowork history.")
    )
    #expect(!String(describing: failure).contains("secret-marker"))
}

@Test @MainActor
func externalAgentConfigImportHistoryPersistsAcrossServiceInstances()
    throws
{
    let fixture = try ExternalAgentFixture()
    defer { fixture.remove() }
    let success: CodexJSONValue = .object([
        "itemType": .string("SKILLS"),
        "successes": .array([
            .object([
                "itemType": .string("SKILLS"),
                "cwd": .null,
                "source": .string("review"),
                "target": .string("review"),
            ])
        ]),
        "failures": .array([]),
    ])
    let first = CodexExternalAgentConfigMigrationService(
        codexHome: fixture.codexHome,
        userHome: fixture.home,
        now: { Date(timeIntervalSince1970: 1_700_000_000) },
        sendNotification: { _, _ in }
    )
    let importID =
        try first.recordExternalAgentConfigurationImportHistory(
            providerID: "fixture-provider",
            itemTypeResults: [success]
        )
    let second = CodexExternalAgentConfigMigrationService(
        codexHome: fixture.codexHome,
        userHome: fixture.home,
        sendNotification: { _, _ in }
    )

    guard case let .object(response) =
        try second.readExternalAgentConfigurationImportHistories(),
        case let .array(histories)? = response["data"],
        case let .object(record)? = histories.first
    else {
        Issue.record("Expected persisted external-agent import history")
        return
    }
    #expect(record["importId"] == .string(importID))
    #expect(record["providerId"] == .string("fixture-provider"))
    #expect(record["completedAtMs"] == .integer(1_700_000_000_000))
}

@Test @MainActor
func externalAgentConfigRejectsRelativeWorkspaceDetection() {
    let service = CodexExternalAgentConfigMigrationService(
        codexHome: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString),
        sendNotification: { _, _ in }
    )

    #expect(throws: CodexExternalAgentMigrationError.self) {
        try service.detectExternalAgentConfiguration(
            options: CodexExternalAgentDetectOptions(
                cwds: ["relative/workspace"]
            )
        )
    }
}

@Test @MainActor
func externalAgentConfigDetectRouteAcceptsOfficialNullableLimits()
    async
{
    let probe = ExternalAgentMigrationProbe()
    let response = await CodexDesktopInitialMCPRouter
        .responseIncludingFileSystem(
            to: externalAgentMCPRequest(
                id: .string("detect-nullable"),
                method: "externalAgentConfig/detect",
                params: .object([
                    "includeHome": .bool(true),
                    "cwds": .null,
                    "maxSessionAgeDays": .null,
                    "maxSessions": .null,
                    "source": .string("cursor"),
                    "migrationSource": .string("unknown-source"),
                ])
            ),
            state: externalAgentMCPState(),
            allowedFileSystemRoots: [],
            externalAgentConfig: probe
        )

    #expect(
        probe.detectedOptions
            == CodexExternalAgentDetectOptions(
                includeHome: true,
                cwds: [],
                maxSessionAgeDays: 30,
                maxSessions: 50,
                migrationSource: "unknown-source"
            )
    )
    #expect(
        response
            == .mcpResponse(
                hostID: "desktop-host-external-agent",
                message: .object([
                    "id": .string("detect-nullable"),
                    "result": .object([
                        "items": .array([
                            CodexExternalAgentMigrationItem(
                                itemType: "AGENTS_MD",
                                description: "fixture",
                                cwd: nil,
                                details: nil
                            ).wireValue
                        ])
                    ]),
                ]),
                metadata: [:]
            )
    )
}

@Test @MainActor
func externalAgentConfigImportRouteTreatsEmptyCWDAsHomeScope()
    async
{
    let probe = ExternalAgentMigrationProbe()
    let response = await CodexDesktopInitialMCPRouter
        .responseIncludingFileSystem(
            to: externalAgentMCPRequest(
                id: .integer(71),
                method: "externalAgentConfig/import",
                params: .object([
                    "migrationItems": .array([
                        .object([
                            "itemType": .string("AGENTS_MD"),
                            "description": .string("home instructions"),
                            "cwd": .string(""),
                            "details": .null,
                        ])
                    ]),
                    "source": .null,
                    "providerId": .null,
                    "migrationSource": .null,
                ])
            ),
            state: externalAgentMCPState(),
            allowedFileSystemRoots: [],
            externalAgentConfig: probe
        )

    #expect(probe.importedItems?.count == 1)
    #expect(probe.importedItems?.first?.cwd == nil)
    #expect(
        response
            == .mcpResponse(
                hostID: "desktop-host-external-agent",
                message: .object([
                    "id": .integer(71),
                    "result": .object([
                        "importId": .string("import-fixture")
                    ]),
                ]),
                metadata: [:]
            )
    )
}

@Test @MainActor
func externalAgentConfigImportRouteRejectsMalformedDetails()
    async
{
    let probe = ExternalAgentMigrationProbe()
    let response = await CodexDesktopInitialMCPRouter
        .responseIncludingFileSystem(
            to: externalAgentMCPRequest(
                id: .string("malformed-details"),
                method: "externalAgentConfig/import",
                params: .object([
                    "migrationItems": .array([
                        .object([
                            "itemType": .string("SKILLS"),
                            "description": .string("skills"),
                            "cwd": .null,
                            "details": .object([
                                "skills": .array([
                                    .object(["name": .integer(3)])
                                ])
                            ]),
                        ])
                    ])
                ])
            ),
            state: externalAgentMCPState(),
            allowedFileSystemRoots: [],
            externalAgentConfig: probe
        )

    #expect(probe.importedItems == nil)
    #expect(
        response
            == .mcpResponse(
                hostID: "desktop-host-external-agent",
                message: .object([
                    "id": .string("malformed-details"),
                    "error": .object([
                        "code": .integer(-32602),
                        "message": .string(
                            "Invalid params for externalAgentConfig/import"
                        ),
                    ]),
                ]),
                metadata: [:]
            )
    )
}
