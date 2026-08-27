#if SWIFT_PACKAGE
    import CodexPadDomain
#endif
import Foundation

public enum CodexExternalAgentMigrationError:
    Error,
    Equatable,
    Sendable
{
    case invalidParameters
    case invalidMigrationItem
    case unsafePath(String)
    case invalidSource(String)
    case targetExists(String)
    case malformedConfiguration(String)
    case coworkHistoryLimit
    case coworkHistoryUnreadable
}

public struct CodexExternalAgentDetectOptions:
    Equatable,
    Sendable
{
    public let includeHome: Bool
    public let cwds: [String]
    public let maxSessionAgeDays: Int
    public let maxSessions: Int
    public let migrationSource: String?

    public init(
        includeHome: Bool = false,
        cwds: [String] = [],
        maxSessionAgeDays: Int = 30,
        maxSessions: Int = 50,
        migrationSource: String? = nil
    ) {
        self.includeHome = includeHome
        self.cwds = cwds
        self.maxSessionAgeDays = maxSessionAgeDays
        self.maxSessions = maxSessions
        self.migrationSource = migrationSource
    }
}

public struct CodexCoworkDiscoveryLimits:
    Equatable,
    Sendable
{
    public let duration: TimeInterval
    public let directoryEntries: Int
    public let manifestAttempts: Int
    public let manifestBytes: Int
    public let manifestFileBytes: Int
    public let sessionAttempts: Int
    public let sessionBytes: Int
    public let sessionMessages: Int
    public let transcriptBytes: Int
    public let transcriptFileBytes: Int

    public init(
        duration: TimeInterval,
        directoryEntries: Int,
        manifestAttempts: Int = 2_000,
        manifestBytes: Int = 32 * 1_024 * 1_024,
        manifestFileBytes: Int = 4 * 1_024 * 1_024,
        sessionAttempts: Int,
        sessionBytes: Int = 16 * 1_024 * 1_024,
        sessionMessages: Int = 10_000,
        transcriptBytes: Int,
        transcriptFileBytes: Int
    ) {
        self.duration = duration
        self.directoryEntries = directoryEntries
        self.manifestAttempts = manifestAttempts
        self.manifestBytes = manifestBytes
        self.manifestFileBytes = manifestFileBytes
        self.sessionAttempts = sessionAttempts
        self.sessionBytes = sessionBytes
        self.sessionMessages = sessionMessages
        self.transcriptBytes = transcriptBytes
        self.transcriptFileBytes = transcriptFileBytes
    }

    public static let desktop = CodexCoworkDiscoveryLimits(
        duration: 10,
        directoryEntries: 20_000,
        manifestAttempts: 2_000,
        manifestBytes: 32 * 1_024 * 1_024,
        manifestFileBytes: 4 * 1_024 * 1_024,
        sessionAttempts: 500,
        sessionBytes: 16 * 1_024 * 1_024,
        sessionMessages: 10_000,
        transcriptBytes: 64 * 1_024 * 1_024,
        transcriptFileBytes: 8 * 1_024 * 1_024
    )
}

public struct CodexExternalAgentMigrationItem:
    Equatable,
    Sendable
{
    public let itemType: String
    public let description: String
    public let cwd: String?
    public let details: CodexJSONValue?

    public init(
        itemType: String,
        description: String,
        cwd: String?,
        details: CodexJSONValue?
    ) {
        self.itemType = itemType
        self.description = description
        self.cwd = cwd
        self.details = details
    }

    public var wireValue: CodexJSONValue {
        .object([
            "itemType": .string(itemType),
            "description": .string(description),
            "cwd": cwd.map(CodexJSONValue.string) ?? .null,
            "details": details ?? .null,
        ])
    }
}

@MainActor
public protocol CodexDesktopExternalAgentConfigMigrating: AnyObject {
    func detectExternalAgentConfiguration(
        options: CodexExternalAgentDetectOptions
    ) throws -> [CodexExternalAgentMigrationItem]

    func startExternalAgentConfigurationImport(
        migrationItems: [CodexExternalAgentMigrationItem],
        source: String?,
        providerID: String?,
        migrationSource: String?
    ) -> String

    func recordExternalAgentConfigurationImportHistory(
        providerID: String,
        itemTypeResults: [CodexJSONValue]
    ) throws -> String

    func readExternalAgentConfigurationImportHistories()
        throws -> CodexJSONValue
}

/// Native iPad implementation of the released app-server
/// `externalAgentConfig/*` surface.
///
/// Detection always derives paths from the configured source home and the
/// caller's absolute repo roots. Import never trusts a renderer-supplied path
/// hidden inside `details`; it recalculates every source and target path from
/// the item type and scope before touching the filesystem.
@MainActor
public final class CodexExternalAgentConfigMigrationService:
    CodexDesktopExternalAgentConfigMigrating
{
    public typealias NotificationSink =
        @MainActor @Sendable (String, CodexJSONValue) async -> Void

    private enum MigrationSource: Equatable {
        case claude
        case cursor

        init(_ value: String?) {
            self = value?.lowercased() == "cursor" ? .cursor : .claude
        }

        var configDirectoryName: String {
            switch self {
            case .claude: ".claude"
            case .cursor: ".cursor"
            }
        }
    }

    private struct HistoryRecord: Codable {
        let importId: String
        let providerId: String?
        let completedAtMs: Int64
        let successes: [CodexJSONValue]
        let failures: [CodexJSONValue]
    }

    private static let supportedItemTypes: Set<String> = [
        "AGENTS_MD",
        "CONFIG",
        "SKILLS",
        "PLUGINS",
        "MCP_SERVER_CONFIG",
        "SUBAGENTS",
        "HOOKS",
        "COMMANDS",
        "MEMORY",
        "SESSIONS",
    ]

    // These are the safety budgets used by the desktop Claude Cowork history
    // importer. Keep them explicit so detection and import can share the same
    // contract without trusting renderer-provided limits.
    private static let coworkMaxSessions = 500
    private static let coworkMaxTranscriptFileBytes = 8 * 1_024 * 1_024
    private static let coworkMaxTranscriptBytes = 16 * 1_024 * 1_024
    private static let coworkMaxSessionMessages = 10_000

    private let codexHome: URL
    private let userHome: URL
    private let configStore: CodexDesktopConfigStore?
    private let fileManager: FileManager
    private let now: @Sendable () -> Date
    private let monotonicNow: @Sendable () -> TimeInterval
    private let discoveryLimits: CodexCoworkDiscoveryLimits
    private let sendNotification: NotificationSink

    public private(set) var lastDetectionWarnings: [String] = []

    public init(
        codexHome: URL,
        userHome: URL? = nil,
        configStore: CodexDesktopConfigStore? = nil,
        fileManager: FileManager = .default,
        now: @escaping @Sendable () -> Date = Date.init,
        monotonicNow: @escaping @Sendable () -> TimeInterval = {
            ProcessInfo.processInfo.systemUptime
        },
        discoveryLimits: CodexCoworkDiscoveryLimits = .desktop,
        sendNotification: @escaping NotificationSink
    ) {
        self.codexHome = codexHome.standardizedFileURL
        self.userHome = (
            userHome ?? URL(
                fileURLWithPath: NSHomeDirectory(),
                isDirectory: true
            )
        ).standardizedFileURL
        self.configStore = configStore
        self.fileManager = fileManager
        self.now = now
        self.monotonicNow = monotonicNow
        self.discoveryLimits = discoveryLimits
        self.sendNotification = sendNotification
    }

    public func detectExternalAgentConfiguration(
        options: CodexExternalAgentDetectOptions
    ) throws -> [CodexExternalAgentMigrationItem] {
        lastDetectionWarnings = []
        guard options.maxSessionAgeDays >= 0,
              options.maxSessions >= 0
        else {
            throw CodexExternalAgentMigrationError.invalidParameters
        }

        let source = MigrationSource(options.migrationSource)
        var items: [CodexExternalAgentMigrationItem] = []
        if options.includeHome {
            try detect(
                scope: nil,
                source: source,
                options: options,
                into: &items
            )
        }
        for rawCWD in options.cwds {
            let cwd = try absoluteDirectory(rawCWD)
            guard !samePath(cwd, userHome) else {
                continue
            }
            try detect(
                scope: cwd,
                source: source,
                options: options,
                into: &items
            )
        }
        return items
    }

    public func startExternalAgentConfigurationImport(
        migrationItems: [CodexExternalAgentMigrationItem],
        source: String?,
        providerID: String?,
        migrationSource: String?
    ) -> String {
        let importID = UUID().uuidString.lowercased()
        let selectedSource = MigrationSource(migrationSource)
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.runImport(
                importID: importID,
                migrationItems: migrationItems,
                attributionSource: source,
                providerID: providerID,
                migrationSource: selectedSource
            )
        }
        return importID
    }

    public func recordExternalAgentConfigurationImportHistory(
        providerID: String,
        itemTypeResults: [CodexJSONValue]
    ) throws -> String {
        guard !providerID.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty else {
            throw CodexExternalAgentMigrationError.invalidParameters
        }
        let importID = UUID().uuidString.lowercased()
        let split = try splitResults(itemTypeResults)
        try appendHistory(
            HistoryRecord(
                importId: importID,
                providerId: providerID,
                completedAtMs: timestampMilliseconds(),
                successes: split.successes,
                failures: split.failures
            )
        )
        return importID
    }

    public func readExternalAgentConfigurationImportHistories()
        throws -> CodexJSONValue
    {
        let histories = try loadHistories()
            .sorted { $0.completedAtMs > $1.completedAtMs }
            .map { record in
                CodexJSONValue.object([
                    "importId": .string(record.importId),
                    "providerId":
                        record.providerId.map(CodexJSONValue.string)
                        ?? .null,
                    "completedAtMs": .integer(record.completedAtMs),
                    "successes": .array(record.successes),
                    "failures": .array(record.failures),
                ])
            }
        return .object([
            "data": .array(histories),
            "connectors": .array(readConnectorCandidates()),
        ])
    }

    private func detect(
        scope: URL?,
        source: MigrationSource,
        options: CodexExternalAgentDetectOptions,
        into items: inout [CodexExternalAgentMigrationItem]
    ) throws {
        let sourceHome = userHome.appendingPathComponent(
            source.configDirectoryName,
            isDirectory: true
        )
        let sourceDirectory = scope?.appendingPathComponent(
            source.configDirectoryName,
            isDirectory: true
        ) ?? sourceHome
        let targetRoot = scope ?? codexHome
        let itemCWD = scope?.path

        if let instruction = try instructionSource(
            scope: scope,
            source: source,
            sourceHome: sourceHome
        ) {
            let target = targetRoot.appendingPathComponent("AGENTS.md")
            if try isMissingOrEmpty(target) {
                items.append(
                    item(
                        "AGENTS_MD",
                        "Migrate \(instruction.path) to \(target.path)",
                        cwd: itemCWD
                    )
                )
            }
        }

        let settings = settingsFile(
            sourceDirectory: sourceDirectory,
            source: source,
            scope: scope
        )
        if try containsMigratableConfig(settings, source: source) {
            let target = targetRoot
                .appendingPathComponent(
                    scope == nil ? "config.toml" : ".codex/config.toml"
                )
            items.append(
                item(
                    "CONFIG",
                    "Migrate \(settings.path) into \(target.path)",
                    cwd: itemCWD
                )
            )
        }

        let skillSource = sourceDirectory.appendingPathComponent(
            "skills",
            isDirectory: true
        )
        let skillTarget = targetSkillsRoot(scope: scope)
        let skills = try missingDirectories(
            source: skillSource,
            target: skillTarget
        )
        if !skills.isEmpty {
            items.append(
                item(
                    "SKILLS",
                    "Migrate skills from \(skillSource.path) to \(skillTarget.path)",
                    cwd: itemCWD,
                    details: details(
                        "skills",
                        names: skills
                    )
                )
            )
        }

        let commandSource = sourceDirectory.appendingPathComponent(
            "commands",
            isDirectory: true
        )
        let commands = try missingMarkdownNames(
            source: commandSource,
            target: skillTarget,
            targetIsDirectory: true
        )
        if !commands.isEmpty {
            items.append(
                item(
                    "COMMANDS",
                    "Migrate commands from \(commandSource.path) to \(skillTarget.path)",
                    cwd: itemCWD,
                    details: details(
                        "commands",
                        names: commands
                    )
                )
            )
        }

        let subagentSource = sourceDirectory.appendingPathComponent(
            "agents",
            isDirectory: true
        )
        let subagentTarget = targetRoot.appendingPathComponent(
            scope == nil ? "agents" : ".codex/agents",
            isDirectory: true
        )
        let subagents = try missingMarkdownNames(
            source: subagentSource,
            target: subagentTarget,
            targetIsDirectory: false,
            targetExtension: "toml"
        )
        if !subagents.isEmpty {
            items.append(
                item(
                    "SUBAGENTS",
                    "Migrate subagents from \(subagentSource.path) to \(subagentTarget.path)",
                    cwd: itemCWD,
                    details: details(
                        "subagents",
                        names: subagents
                    )
                )
            )
        }

        let hookNames = try detectedHookNames(
            sourceDirectory: sourceDirectory,
            source: source
        )
        let hooksTarget = targetRoot.appendingPathComponent(
            scope == nil ? "hooks.json" : ".codex/hooks.json"
        )
        if !hookNames.isEmpty, try isMissingOrEmpty(hooksTarget) {
            items.append(
                item(
                    "HOOKS",
                    "Migrate hooks from \(sourceDirectory.path) to \(hooksTarget.path)",
                    cwd: itemCWD,
                    details: details("hooks", names: hookNames)
                )
            )
        }

        let mcp = try detectedMCPServers(
            sourceDirectory: sourceDirectory,
            scope: scope,
            source: source
        )
        if !mcp.names.isEmpty {
            items.append(
                item(
                    "MCP_SERVER_CONFIG",
                    "Migrate MCP servers from \(mcp.source.path) into \(targetRoot.path)",
                    cwd: itemCWD,
                    details: details(
                        "mcpServers",
                        names: mcp.names
                    )
                )
            )
        }

        let plugins = try detectedPlugins(
            sourceHome: sourceHome,
            sourceDirectory: sourceDirectory
        )
        if !plugins.isEmpty {
            var fields = emptyDetailsFields()
            fields["plugins"] = .array(
                plugins.map {
                    .object([
                        "marketplaceName": .string("local"),
                        "pluginNames": .array([
                            .string($0),
                        ]),
                    ])
                }
            )
            items.append(
                item(
                    "PLUGINS",
                    "Migrate plugins from \(sourceDirectory.path)",
                    cwd: itemCWD,
                    details: .object(fields)
                )
            )
        }

        guard scope == nil else {
            return
        }

        if source == .claude {
            let memoryProjects = try detectedMemoryProjects(
                sourceHome: sourceHome
            )
            if !memoryProjects.isEmpty {
                var fields = emptyDetailsFields()
                fields["memory"] = .array(
                    memoryProjects.map(CodexJSONValue.string)
                )
                items.append(
                    item(
                        "MEMORY",
                        "Migrate project memory from \(sourceHome.path)",
                        cwd: nil,
                        details: .object(fields)
                    )
                )
            }
        }

        var deferred = false
        let sessions = try detectedSessions(
            sourceHome: sourceHome,
            maxAgeDays: options.maxSessionAgeDays,
            maxSessions: options.maxSessions,
            deferred: &deferred
        )
        if !sessions.isEmpty {
            var fields = emptyDetailsFields()
            fields["sessions"] = .array(
                sessions.map { session in
                    .object([
                        "path": .string(session.path),
                        "sourceJsonlPath": .string(session.path),
                        "sourceJsonlPaths": .array([
                            .string(session.path),
                        ]),
                        "cwd": .string(session.cwd),
                        "title":
                            session.title.map(CodexJSONValue.string)
                            ?? .null,
                        "projectRoot": .string(session.cwd),
                        "workspaceKind": .string("project"),
                        "sourceId":
                            session.sourceID.map(CodexJSONValue.string)
                            ?? .null,
                        "lastActivityAtMs":
                            session.lastActivityAtMs.map(CodexJSONValue.integer)
                            ?? .null,
                        "fsDetectedFiles": .array(
                            session.fsDetectedFiles.map(CodexJSONValue.string)
                        ),
                    ])
                }
            )
            items.append(
                item(
                    "SESSIONS",
                    "Migrate recent sessions from \(sourceHome.path)",
                    cwd: nil,
                    details: .object(fields)
                )
            )
        }
        if deferred {
            lastDetectionWarnings = [
                "Some Claude Cowork chats were deferred because history discovery reached its safety limits."
            ]
        }
    }

    private func runImport(
        importID: String,
        migrationItems: [CodexExternalAgentMigrationItem],
        attributionSource _: String?,
        providerID: String?,
        migrationSource: MigrationSource
    ) async {
        var results: [CodexJSONValue] = []
        for item in migrationItems {
            let result = importItem(
                item,
                source: migrationSource
            )
            results.append(result)
            await sendNotification(
                "externalAgentConfig/import/progress",
                .object([
                    "importId": .string(importID),
                    "itemTypeResults": .array([result]),
                ])
            )
        }

        let split = (try? splitResults(results))
            ?? (successes: [], failures: [])
        try? appendHistory(
            HistoryRecord(
                importId: importID,
                providerId: providerID,
                completedAtMs: timestampMilliseconds(),
                successes: split.successes,
                failures: split.failures
            )
        )
        await sendNotification(
            "externalAgentConfig/import/completed",
            .object([
                "importId": .string(importID),
                "itemTypeResults": .array(results),
            ])
        )
    }

    private func importItem(
        _ item: CodexExternalAgentMigrationItem,
        source: MigrationSource
    ) -> CodexJSONValue {
        let result: Result<[(String?, String?)], Error>
        do {
            guard Self.supportedItemTypes.contains(item.itemType)
            else {
                throw CodexExternalAgentMigrationError
                    .invalidMigrationItem
            }
            result = .success(
                try performImport(item, source: source)
            )
        } catch {
            result = .failure(error)
        }

        switch result {
        case let .success(paths):
            return .object([
                "itemType": .string(item.itemType),
                "successes": .array(
                    paths.map { source, target in
                        .object([
                            "itemType": .string(item.itemType),
                            "cwd":
                                item.cwd.map(CodexJSONValue.string)
                                ?? .null,
                            "source":
                                source.map(CodexJSONValue.string)
                                ?? .null,
                            "target":
                                target.map(CodexJSONValue.string)
                                ?? .null,
                        ])
                    }
                ),
                "failures": .array([]),
            ])
        case let .failure(error):
            let projection: (String, String) = {
                switch error as? CodexExternalAgentMigrationError {
                case .some(.coworkHistoryLimit):
                    return (
                        "cowork-history-limit",
                        "The selected Claude Cowork history exceeds the safe import limit."
                    )
                case .some(.coworkHistoryUnreadable):
                    return (
                        "cowork-history-unreadable",
                        "Could not read the selected Claude Cowork history."
                    )
                default:
                    return (
                        String(describing: type(of: error)),
                        String(describing: error)
                    )
                }
            }()
            return .object([
                "itemType": .string(item.itemType),
                "successes": .array([]),
                "failures": .array([
                    .object([
                        "itemType": .string(item.itemType),
                        "errorType": .string(projection.0),
                        "subErrorType": .null,
                        "failureStage": .string("sync_import"),
                        "message": .string(projection.1),
                        "cwd":
                            item.cwd.map(CodexJSONValue.string)
                            ?? .null,
                        "source": .null,
                    ]),
                ]),
            ])
        }
    }

    private func performImport(
        _ item: CodexExternalAgentMigrationItem,
        source: MigrationSource
    ) throws -> [(String?, String?)] {
        let scope: URL?
        if let cwd = item.cwd {
            scope = try absoluteDirectory(cwd)
        } else {
            scope = nil
        }
        let sourceHome = userHome.appendingPathComponent(
            source.configDirectoryName,
            isDirectory: true
        )
        let sourceDirectory = scope?.appendingPathComponent(
            source.configDirectoryName,
            isDirectory: true
        ) ?? sourceHome
        let targetRoot = scope ?? codexHome

        switch item.itemType {
        case "AGENTS_MD":
            guard let sourceFile = try instructionSource(
                scope: scope,
                source: source,
                sourceHome: sourceHome
            ) else {
                throw CodexExternalAgentMigrationError.invalidSource(
                    "instruction file"
                )
            }
            let target = targetRoot.appendingPathComponent("AGENTS.md")
            try copyTextFile(
                source: sourceFile,
                target: target,
                rewriteExternalAgentTerms: true
            )
            return [(sourceFile.path, target.path)]

        case "SKILLS":
            return try importDirectories(
                names: detailNames(item.details, key: "skills"),
                sourceRoot: sourceDirectory.appendingPathComponent(
                    "skills",
                    isDirectory: true
                ),
                targetRoot: targetSkillsRoot(scope: scope)
            )

        case "COMMANDS":
            return try importCommands(
                names: detailNames(item.details, key: "commands"),
                sourceRoot: sourceDirectory.appendingPathComponent(
                    "commands",
                    isDirectory: true
                ),
                targetRoot: targetSkillsRoot(scope: scope)
            )

        case "SUBAGENTS":
            return try importSubagents(
                names: detailNames(item.details, key: "subagents"),
                sourceRoot: sourceDirectory.appendingPathComponent(
                    "agents",
                    isDirectory: true
                ),
                targetRoot: targetRoot.appendingPathComponent(
                    scope == nil ? "agents" : ".codex/agents",
                    isDirectory: true
                )
            )

        case "CONFIG":
            return try importConfiguration(
                sourceDirectory: sourceDirectory,
                scope: scope,
                source: source
            )

        case "MCP_SERVER_CONFIG":
            return try importMCPConfiguration(
                selectedNames: detailNames(
                    item.details,
                    key: "mcpServers"
                ),
                sourceDirectory: sourceDirectory,
                scope: scope,
                source: source
            )

        case "HOOKS":
            return try importHooks(
                sourceDirectory: sourceDirectory,
                targetRoot: targetRoot,
                scope: scope,
                source: source
            )

        case "PLUGINS":
            return try importPlugins(
                item.details,
                sourceDirectory: sourceDirectory,
                sourceHome: sourceHome,
                targetRoot: codexHome.appendingPathComponent(
                    "plugins/imported",
                    isDirectory: true
                )
            )

        case "MEMORY":
            return try importMemory(
                projects: detailStrings(
                    item.details,
                    key: "memory"
                ),
                sourceHome: sourceHome
            )

        case "SESSIONS":
            return try importSessions(
                item.details,
                sourceHome: sourceHome
            )

        default:
            throw CodexExternalAgentMigrationError
                .invalidMigrationItem
        }
    }

    private func importConfiguration(
        sourceDirectory: URL,
        scope: URL?,
        source: MigrationSource
    ) throws -> [(String?, String?)] {
        let sourceFile = settingsFile(
            sourceDirectory: sourceDirectory,
            source: source,
            scope: scope
        )
        let object = try readJSONObject(sourceFile)
        var migrated: [String: CodexJSONValue] = [:]
        switch source {
        case .claude:
            if case let .object(sandbox)? = object["sandbox"],
               sandbox["enabled"] == .bool(true)
            {
                migrated["sandbox_mode"] =
                    .string("workspace-write")
            }
        case .cursor:
            let sandboxFile = sourceDirectory
                .appendingPathComponent("sandbox.json")
            if let sandbox = try? readJSONObject(sandboxFile),
               case let .string(type)? = sandbox["type"]
            {
                if type == "workspace_readwrite" {
                    migrated["sandbox_mode"] =
                        .string("workspace-write")
                } else if type == "read_only" {
                    migrated["sandbox_mode"] =
                        .string("read-only")
                }
            }
        }
        guard !migrated.isEmpty else {
            return []
        }
        if scope == nil, let configStore {
            for (key, value) in migrated {
                _ = configStore.write(
                    keyPath: key,
                    value: value,
                    mergeStrategy: "replace"
                )
            }
        }
        let target = (scope ?? codexHome).appendingPathComponent(
            scope == nil ? "config.toml" : ".codex/config.toml"
        )
        try mergeTOMLScalars(migrated, into: target)
        return [(sourceFile.path, target.path)]
    }

    private func importMCPConfiguration(
        selectedNames: [String],
        sourceDirectory: URL,
        scope: URL?,
        source: MigrationSource
    ) throws -> [(String?, String?)] {
        let detected = try detectedMCPServers(
            sourceDirectory: sourceDirectory,
            scope: scope,
            source: source
        )
        let selected = Set(selectedNames)
        let servers = detected.servers.filter {
            selected.isEmpty || selected.contains($0.key)
        }
        guard !servers.isEmpty else {
            return []
        }

        var successes: [(String?, String?)] = []
        let target = (scope ?? codexHome).appendingPathComponent(
            scope == nil ? "config.toml" : ".codex/config.toml"
        )
        var sections = ""
        for name in servers.keys.sorted() {
            guard let raw = servers[name],
                  let normalized = normalizedMCPServer(raw)
            else {
                continue
            }
            if scope == nil, let configStore,
               let configuration =
                   try? CodexMCPServerConfiguration(json: normalized)
            {
                try CodexMCPConfigurationStore(
                    configStore: configStore
                ).write(configuration, for: name)
            }
            sections += renderMCPServerTOML(
                name: name,
                value: normalized
            )
            successes.append((name, name))
        }
        if !sections.isEmpty {
            try appendTOMLSections(sections, into: target)
        }
        return successes
    }

    private func importHooks(
        sourceDirectory: URL,
        targetRoot: URL,
        scope: URL?,
        source: MigrationSource
    ) throws -> [(String?, String?)] {
        let sourceFile: URL
        let hooks: CodexJSONValue
        switch source {
        case .claude:
            sourceFile = sourceDirectory
                .appendingPathComponent("settings.json")
            let settings = try readJSONObject(sourceFile)
            hooks = settings["hooks"] ?? .object([:])
        case .cursor:
            sourceFile = sourceDirectory
                .appendingPathComponent("hooks.json")
            hooks = .object(try readJSONObject(sourceFile))
        }
        guard case let .object(events) = hooks, !events.isEmpty
        else {
            return []
        }
        let target = targetRoot.appendingPathComponent(
            scope == nil ? "hooks.json" : ".codex/hooks.json"
        )
        try atomicWriteJSON(.object(events), to: target)
        return events.keys.sorted().map {
            ($0, target.path)
        }
    }

    private func importPlugins(
        _ details: CodexJSONValue?,
        sourceDirectory: URL,
        sourceHome: URL,
        targetRoot: URL
    ) throws -> [(String?, String?)] {
        let names = detailPluginNames(details)
        let candidates = [
            sourceDirectory.appendingPathComponent(
                "plugins",
                isDirectory: true
            ),
            sourceHome.appendingPathComponent(
                "plugins",
                isDirectory: true
            ),
        ]
        var result: [(String?, String?)] = []
        for name in names {
            guard safeComponent(name) else { continue }
            guard let source = candidates
                .map({ $0.appendingPathComponent(name) })
                .first(where: {
                    fileManager.fileExists(atPath: $0.path)
                })
            else { continue }
            let target = targetRoot.appendingPathComponent(name)
            try copyDirectory(source: source, target: target)
            result.append((source.path, target.path))
        }
        return result
    }

    private func importMemory(
        projects: [String],
        sourceHome: URL
    ) throws -> [(String?, String?)] {
        let sourceProjects = sourceHome.appendingPathComponent(
            "projects",
            isDirectory: true
        )
        let target = codexHome.appendingPathComponent(
            "memories/extensions/external_agent_import/resources",
            isDirectory: true
        )
        var result: [(String?, String?)] = []
        for project in projects where safeComponent(project) {
            let source = sourceProjects
                .appendingPathComponent(project)
                .appendingPathComponent("memory")
            guard fileManager.fileExists(atPath: source.path)
            else { continue }
            let destination = target.appendingPathComponent(project)
            try replaceDirectory(
                source: source,
                target: destination
            )
            result.append((project, destination.path))
        }
        return result
    }

    private func importSessions(
        _ details: CodexJSONValue?,
        sourceHome: URL
    ) throws -> [(String?, String?)] {
        guard case let .object(fields)? = details,
              case let .array(sessions)? = fields["sessions"]
        else {
            throw CodexExternalAgentMigrationError
                .invalidMigrationItem
        }
        let projectsRoot = sourceHome.appendingPathComponent(
            "projects",
            isDirectory: true
        )
        guard sessions.count <= Self.coworkMaxSessions else {
            throw CodexExternalAgentMigrationError.coworkHistoryLimit
        }
        let targetRoot = codexHome.appendingPathComponent(
            "sessions/imported",
            isDirectory: true
        )
        var prepared: [(source: URL, target: URL, data: Data)] = []
        var totalBytes = 0
        var totalMessages = 0
        for session in sessions {
            guard case let .object(item) = session,
                  case let .string(path)? = item["path"]
            else {
                throw CodexExternalAgentMigrationError.coworkHistoryUnreadable
            }
            let source = URL(fileURLWithPath: path)
                .standardizedFileURL
            do {
                try requireRegularFile(source, beneath: projectsRoot)
            } catch {
                throw CodexExternalAgentMigrationError.coworkHistoryUnreadable
            }
            let data: Data
            do {
                data = try readCoworkTranscript(source)
            } catch let error as CodexExternalAgentMigrationError {
                throw error
            } catch {
                throw CodexExternalAgentMigrationError.coworkHistoryUnreadable
            }
            let messageCount = coworkSessionMessageCount(data)
            guard data.count <= Self.coworkMaxTranscriptFileBytes,
                  totalBytes <= Self.coworkMaxTranscriptBytes - data.count,
                  totalMessages <= Self.coworkMaxSessionMessages - messageCount
            else {
                throw CodexExternalAgentMigrationError.coworkHistoryLimit
            }
            totalBytes += data.count
            totalMessages += messageCount
            let target = targetRoot.appendingPathComponent(
                source.lastPathComponent
            )
            if fileManager.fileExists(atPath: target.path) {
                continue
            }
            prepared.append((source: source, target: target, data: data))
        }
        // No destination directory or file is created until every selected
        // transcript has passed the complete safety preflight above.
        try createDirectory(targetRoot)
        var result: [(String?, String?)] = []
        for entry in prepared {
            try atomicWrite(entry.data, to: entry.target)
            result.append((entry.source.path, entry.target.path))
        }
        return result
    }

    private func readCoworkTranscript(_ source: URL) throws -> Data {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: source)
        } catch {
            throw CodexExternalAgentMigrationError.coworkHistoryUnreadable
        }
        defer { try? handle.close() }

        var data = Data()
        let chunkSize = 64 * 1_024
        while true {
            let chunk: Data
            do {
                chunk = try handle.read(upToCount: chunkSize) ?? Data()
            } catch {
                throw CodexExternalAgentMigrationError.coworkHistoryUnreadable
            }
            if chunk.isEmpty { break }
            guard data.count <= Self.coworkMaxTranscriptFileBytes - chunk.count
            else { throw CodexExternalAgentMigrationError.coworkHistoryLimit }
            data.append(chunk)
        }
        return data
    }

    private func importDirectories(
        names: [String],
        sourceRoot: URL,
        targetRoot: URL
    ) throws -> [(String?, String?)] {
        var result: [(String?, String?)] = []
        for name in names where safeComponent(name) {
            let source = sourceRoot.appendingPathComponent(name)
            let target = targetRoot.appendingPathComponent(name)
            try copyDirectory(source: source, target: target)
            result.append((source.path, target.path))
        }
        return result
    }

    private func importCommands(
        names: [String],
        sourceRoot: URL,
        targetRoot: URL
    ) throws -> [(String?, String?)] {
        var result: [(String?, String?)] = []
        for name in names where safeComponent(name) {
            let source = sourceRoot.appendingPathComponent(
                "\(name).md"
            )
            try requireRegularFile(source, beneath: sourceRoot)
            let targetDirectory = targetRoot
                .appendingPathComponent(name, isDirectory: true)
            let target = targetDirectory
                .appendingPathComponent("SKILL.md")
            try createDirectory(targetDirectory)
            guard !fileManager.fileExists(atPath: target.path)
            else { continue }
            let body = try String(
                contentsOf: source,
                encoding: .utf8
            )
            let rendered = """
            ---
            name: \(name)
            description: Imported external-agent command \(name)
            ---

            \(rewriteTerms(body))
            """
            try atomicWrite(
                Data(rendered.utf8),
                to: target
            )
            result.append((source.path, target.path))
        }
        return result
    }

    private func importSubagents(
        names: [String],
        sourceRoot: URL,
        targetRoot: URL
    ) throws -> [(String?, String?)] {
        var result: [(String?, String?)] = []
        for name in names where safeComponent(name) {
            let source = sourceRoot.appendingPathComponent(
                "\(name).md"
            )
            try requireRegularFile(source, beneath: sourceRoot)
            let target = targetRoot.appendingPathComponent(
                "\(name).toml"
            )
            guard !fileManager.fileExists(atPath: target.path)
            else { continue }
            let raw = try String(
                contentsOf: source,
                encoding: .utf8
            )
            let parsed = parseFrontmatter(raw)
            let agentName = parsed.fields["name"] ?? name
            let description =
                parsed.fields["description"]
                ?? "Imported external-agent subagent"
            var rendered = """
            name = \(tomlString(agentName))
            description = \(tomlString(rewriteTerms(description)))
            """
            if parsed.fields["effort"] == "max" {
                rendered += "\nmodel_reasoning_effort = \"xhigh\""
            } else if let effort = parsed.fields["effort"],
                      [
                          "none", "minimal", "low", "medium",
                          "high", "xhigh",
                      ].contains(effort)
            {
                rendered +=
                    "\nmodel_reasoning_effort = \(tomlString(effort))"
            }
            if parsed.fields["permissionMode"] == "acceptEdits" {
                rendered += "\nsandbox_mode = \"workspace-write\""
            } else if parsed.fields["permissionMode"] == "readOnly" {
                rendered += "\nsandbox_mode = \"read-only\""
            }
            rendered +=
                "\ndeveloper_instructions = "
                + tomlString(rewriteTerms(parsed.body))
                + "\n"
            try createDirectory(targetRoot)
            try atomicWrite(Data(rendered.utf8), to: target)
            result.append((source.path, target.path))
        }
        return result
    }

    private func detectedMCPServers(
        sourceDirectory: URL,
        scope: URL?,
        source: MigrationSource
    ) throws -> (
        source: URL,
        names: [String],
        servers: [String: CodexJSONValue]
    ) {
        let candidates: [URL]
        switch source {
        case .claude:
            candidates = [
                (scope ?? userHome).appendingPathComponent(
                    ".mcp.json"
                ),
                userHome.appendingPathComponent(".claude.json"),
            ]
        case .cursor:
            candidates = [
                sourceDirectory.appendingPathComponent("mcp.json"),
            ]
        }
        var servers: [String: CodexJSONValue] = [:]
        var usedSource = candidates[0]
        for candidate in candidates
            where fileManager.fileExists(atPath: candidate.path)
        {
            let object = try readJSONObject(candidate)
            if case let .object(found)? = object["mcpServers"] {
                servers.merge(found) { _, new in new }
                usedSource = candidate
            }
            if source == .claude,
               let scope,
               case let .object(projects)? = object["projects"],
               case let .object(project)? = projects[scope.path],
               case let .object(found)? = project["mcpServers"]
            {
                servers.merge(found) { _, new in new }
                usedSource = candidate
            }
        }
        return (usedSource, servers.keys.sorted(), servers)
    }

    private func normalizedMCPServer(
        _ raw: CodexJSONValue
    ) -> CodexJSONValue? {
        guard case let .object(fields) = raw else { return nil }
        var normalized: [String: CodexJSONValue] = [:]
        if case let .string(command)? = fields["command"],
           !command.contains("${")
        {
            normalized["command"] = .string(command)
            if case let .array(args)? = fields["args"],
               args.allSatisfy({
                   if case let .string(value) = $0 {
                       return !value.contains("${")
                   }
                   return false
               })
            {
                normalized["args"] = .array(args)
            }
            if case let .object(environment)? = fields["env"] {
                var literals: [String: CodexJSONValue] = [:]
                var references: [CodexJSONValue] = []
                for (key, value) in environment {
                    guard case let .string(text) = value else {
                        continue
                    }
                    if text == "${\(key)}" {
                        references.append(.string(key))
                    } else if !looksSecret(key), !text.contains("${") {
                        literals[key] = .string(text)
                    }
                }
                if !literals.isEmpty {
                    normalized["env"] = .object(literals)
                }
                if !references.isEmpty {
                    normalized["env_vars"] = .array(references)
                }
            }
        } else if case let .string(url)? = fields["url"],
                  !url.contains("${")
        {
            normalized["url"] = .string(url)
            if case let .object(headers)? = fields["headers"] {
                var staticHeaders: [String: CodexJSONValue] = [:]
                var envHeaders: [String: CodexJSONValue] = [:]
                for (key, value) in headers {
                    guard case let .string(text) = value else {
                        continue
                    }
                    if text.hasPrefix("${"), text.hasSuffix("}") {
                        envHeaders[key] = .string(
                            String(text.dropFirst(2).dropLast())
                        )
                    } else if text.hasPrefix("Bearer ${"),
                              text.hasSuffix("}")
                    {
                        normalized["bearer_token_env_var"] =
                            .string(
                                String(
                                    text.dropFirst(9).dropLast()
                                )
                            )
                    } else if !looksSecret(key) {
                        staticHeaders[key] = .string(text)
                    }
                }
                if !staticHeaders.isEmpty {
                    normalized["http_headers"] =
                        .object(staticHeaders)
                }
                if !envHeaders.isEmpty {
                    normalized["env_http_headers"] =
                        .object(envHeaders)
                }
            }
        }
        guard !normalized.isEmpty else { return nil }
        normalized["enabled"] = .bool(true)
        return .object(normalized)
    }

    private func detectedHookNames(
        sourceDirectory: URL,
        source: MigrationSource
    ) throws -> [String] {
        let file = sourceDirectory.appendingPathComponent(
            source == .claude ? "settings.json" : "hooks.json"
        )
        guard fileManager.fileExists(atPath: file.path)
        else { return [] }
        let object = try readJSONObject(file)
        let hooks: CodexJSONValue?
        if source == .claude {
            hooks = object["hooks"]
        } else {
            hooks = .object(object)
        }
        guard case let .object(events)? = hooks else {
            return []
        }
        return events.keys.sorted()
    }

    private func detectedPlugins(
        sourceHome: URL,
        sourceDirectory: URL
    ) throws -> [String] {
        var names = Set<String>()
        for root in [
            sourceDirectory.appendingPathComponent("plugins"),
            sourceHome.appendingPathComponent("plugins"),
        ] {
            for name in try directoryNames(root) {
                names.insert(name)
            }
        }
        return names.sorted()
    }

    private struct DetectedSession {
        let path: String
        let cwd: String
        let title: String?
        let modifiedAt: Date
        let sourceID: String?
        let lastActivityAtMs: Int64?
        let fsDetectedFiles: [String]
    }

    private struct DetectedCoworkManifest {
        let sessionID: String
        let cwd: String?
        let title: String?
        let modifiedAt: Date
        let activityAt: Date?
        let cliSessionID: String?
        let fsDetectedFiles: [String]

        var effectiveActivityAt: Date { activityAt ?? modifiedAt }

        func merging(_ other: DetectedCoworkManifest)
            -> DetectedCoworkManifest
        {
            let preferred = other.effectiveActivityAt >= effectiveActivityAt
                ? other
                : self
            let mergedFiles = Array(
                Set(fsDetectedFiles + other.fsDetectedFiles)
            ).sorted()
            return DetectedCoworkManifest(
                sessionID: sessionID,
                cwd: other.cwd ?? cwd,
                title: other.title ?? title,
                modifiedAt: preferred.modifiedAt,
                activityAt: preferred.activityAt ?? activityAt,
                cliSessionID: other.cliSessionID ?? cliSessionID,
                fsDetectedFiles: mergedFiles
            )
        }
    }

    private func detectedSessions(
        sourceHome: URL,
        maxAgeDays: Int,
        maxSessions: Int,
        deferred: inout Bool
    ) throws -> [DetectedSession] {
        guard maxSessions > 0 else { return [] }
        let root = sourceHome.appendingPathComponent(
            "projects",
            isDirectory: true
        )
        guard fileManager.fileExists(atPath: root.path)
        else { return [] }
        let cutoff = now().addingTimeInterval(
            -Double(maxAgeDays) * 86_400
        )
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .contentModificationDateKey,
            ],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }
        let startedAt = monotonicNow()
        var remainingDirectoryEntries = discoveryLimits.directoryEntries
        var remainingSessionAttempts = discoveryLimits.sessionAttempts
        var remainingSessionBytes = discoveryLimits.sessionBytes
        var remainingSessionMessages = discoveryLimits.sessionMessages
        var remainingTranscriptBytes = discoveryLimits.transcriptBytes
        var remainingManifestAttempts = discoveryLimits.manifestAttempts
        var remainingManifestBytes = discoveryLimits.manifestBytes

        func consume(
            _ amount: Int,
            remaining: inout Int
        ) -> Bool {
            guard monotonicNow() - startedAt < discoveryLimits.duration,
                  amount >= 0,
                  remaining >= amount
            else {
                deferred = true
                return false
            }
            remaining -= amount
            return true
        }

        var candidates: [(url: URL, modified: Date)] = []
        for case let url as URL in enumerator {
            guard consume(1, remaining: &remainingDirectoryEntries)
            else { break }
            let values = try url.resourceValues(
                forKeys: [
                    .isRegularFileKey,
                    .isSymbolicLinkKey,
                    .contentModificationDateKey,
                ]
            )
            if values.isSymbolicLink == true {
                enumerator.skipDescendants()
                continue
            }
            guard values.isRegularFile == true,
                  url.pathExtension == "jsonl",
                  let modified = values.contentModificationDate,
                  modified >= cutoff
            else { continue }
            candidates.append((url: url, modified: modified))
        }

        var sessions: [DetectedSession] = []
        for candidate in candidates.sorted(by: { $0.modified > $1.modified }) {
            guard consume(1, remaining: &remainingSessionAttempts)
            else { break }
            let fileSize = (try? candidate.url.resourceValues(
                forKeys: [.fileSizeKey]
            ).fileSize) ?? 0
            guard let messageCount = coworkSessionMessageCount(
                candidate.url
            ) else {
                deferred = true
                break
            }
            guard fileSize <= discoveryLimits.transcriptFileBytes,
                  consume(fileSize, remaining: &remainingSessionBytes),
                  consume(messageCount, remaining: &remainingSessionMessages),
                  consume(fileSize, remaining: &remainingTranscriptBytes)
            else {
                deferred = true
                break
            }
            let metadata = sessionMetadata(candidate.url)
            sessions.append(
                DetectedSession(
                    path: canonicalPath(candidate.url),
                    cwd: metadata.cwd ?? userHome.path,
                    title: metadata.title,
                    modifiedAt: candidate.modified,
                    sourceID: nil,
                    lastActivityAtMs: Int64(candidate.modified.timeIntervalSince1970 * 1_000),
                    fsDetectedFiles: []
                )
            )
        }

        // Claude Cowork keeps a session manifest beside the account/org
        // storage roots and uses it to provide the canonical session id,
        // title, and cwd. The desktop then resolves that id to the matching
        // JSONL transcript. Keep the same two-level account/org + agent scan
        // and apply the released manifest budgets independently.
        let manifestRoot = sourceHome.appendingPathComponent(
            "local-agent-mode-sessions",
            isDirectory: true
        )
        let excludedManifestNames: Set<String> = [
            "spaces.json",
            "scheduled-tasks.json",
            "artifacts.json",
            "mcp.json",
            "mcp-servers.json",
            "plugins.json",
            "plugins-mcp-skills.json",
            "skills.json",
            "agents.json",
            "cowork_settings.json",
            "cowork_account_settings.json",
            "cowork-clientdata-cache.json",
            "cowork-gb-cache.json",
            "remote-session-spaces.json",
        ]
        var manifestCandidatesBySessionID: [String: DetectedCoworkManifest] = [:]
        if fileManager.fileExists(atPath: manifestRoot.path),
           let accountDirectories = try? fileManager.contentsOfDirectory(
               at: manifestRoot,
               includingPropertiesForKeys: [.isDirectoryKey],
               options: [.skipsHiddenFiles]
           ) {
            manifestScan: for accountDirectory in accountDirectories {
                guard (try? accountDirectory.resourceValues(
                    forKeys: [.isDirectoryKey]
                ).isDirectory) == true else { continue }
                guard let orgDirectories = try? fileManager
                    .contentsOfDirectory(
                        at: accountDirectory,
                        includingPropertiesForKeys: [.isDirectoryKey],
                        options: [.skipsHiddenFiles]
                    ) else { continue }
                for orgDirectory in orgDirectories {
                    guard (try? orgDirectory.resourceValues(
                        forKeys: [.isDirectoryKey]
                    ).isDirectory) == true else { continue }
                    let roots = [
                        orgDirectory,
                        orgDirectory.appendingPathComponent(
                            "agent",
                            isDirectory: true
                        ),
                    ]
                    for root in roots {
                        guard let entries = try? fileManager
                            .contentsOfDirectory(
                                at: root,
                                includingPropertiesForKeys: [
                                    .isRegularFileKey,
                                    .fileSizeKey,
                                    .contentModificationDateKey,
                                ],
                                options: [.skipsHiddenFiles]
                            ) else { continue }
                        for entry in entries.sorted(by: {
                            $0.lastPathComponent < $1.lastPathComponent
                        }) {
                            guard consume(1, remaining: &remainingDirectoryEntries)
                            else { break manifestScan }
                            guard entry.pathExtension == "json",
                                  !excludedManifestNames.contains(
                                      entry.lastPathComponent
                                  ),
                                  (try? entry.resourceValues(
                                      forKeys: [.isRegularFileKey]
                                  ).isRegularFile) == true
                            else { continue }
                            guard consume(
                                1,
                                remaining: &remainingManifestAttempts
                            ) else { break manifestScan }
                            let fileSize = (try? entry.resourceValues(
                                forKeys: [.fileSizeKey]
                            ).fileSize) ?? 0
                            // `manifestFileBytes` is the per-file safety cap;
                            // the aggregate cap is tracked separately by
                            // `remainingManifestBytes`.
                            guard fileSize <= discoveryLimits.manifestFileBytes,
                                  consume(
                                      fileSize,
                                      remaining: &remainingManifestBytes
                                  )
                            else {
                                deferred = true
                                continue
                            }
                            guard let data = try? Data(contentsOf: entry),
                                  let object = try? JSONSerialization
                                      .jsonObject(with: data)
                                      as? [String: Any]
                            else { continue }
                            let sessionID = (object["sessionId"] as? String)
                                ?? (object["id"] as? String)
                                ?? entry.deletingPathExtension()
                                    .lastPathComponent
                            guard !sessionID.isEmpty else { continue }
                            let modified = (try? entry.resourceValues(
                                forKeys: [.contentModificationDateKey]
                            ).contentModificationDate) ?? now()
                            let manifest = DetectedCoworkManifest(
                                sessionID: sessionID,
                                cwd: object["cwd"] as? String,
                                title: object["title"] as? String,
                                modifiedAt: modified,
                                activityAt: manifestActivityDate(object),
                                cliSessionID: object["cliSessionId"] as? String,
                                fsDetectedFiles: (object["fsDetectedFiles"] as? [String]) ?? []
                            )
                            if let existing = manifestCandidatesBySessionID[sessionID] {
                                manifestCandidatesBySessionID[sessionID] = existing.merging(manifest)
                            } else {
                                manifestCandidatesBySessionID[sessionID] = manifest
                            }
                        }
                    }
                }
            }
        }
        for manifest in manifestCandidatesBySessionID.values {
            guard manifest.effectiveActivityAt >= cutoff else { continue }
            guard let candidate = candidates.first(where: {
                $0.url.deletingPathExtension().lastPathComponent
                    == manifest.sessionID
            }) else { continue }
            let transcriptMetadata = sessionMetadata(candidate.url)
            let cwd = manifest.cwd ?? transcriptMetadata.cwd ?? userHome.path
            let title = manifest.title ?? transcriptMetadata.title
            let path = canonicalPath(candidate.url)
            sessions.removeAll { $0.path == path }
            sessions.append(
                DetectedSession(
                    path: path,
                    cwd: cwd,
                    title: title,
                    modifiedAt: manifest.effectiveActivityAt,
                    sourceID: manifest.cliSessionID,
                    lastActivityAtMs: Int64(
                        manifest.effectiveActivityAt.timeIntervalSince1970 * 1_000
                    ),
                    fsDetectedFiles: manifest.fsDetectedFiles
                )
            )
        }
        return sessions.sorted {
            $0.modifiedAt > $1.modifiedAt
        }.prefix(maxSessions).map { $0 }
    }

    private func coworkSessionMessageCount(_ file: URL) -> Int? {
        guard let handle = try? FileHandle(forReadingFrom: file)
        else { return nil }
        defer { try? handle.close() }
        var messageCount = 0
        var pending = Data()
        do {
            while let chunk = try handle.read(upToCount: 64 * 1_024),
                  !chunk.isEmpty
            {
                pending.append(chunk)
                while let newline = pending.firstIndex(of: 0x0A) {
                    let line = pending[..<newline]
                    pending.removeSubrange(...newline)
                    if coworkSessionLineIsProjectable(line) {
                        messageCount += 1
                    }
                }
            }
        } catch {
            return nil
        }
        if !pending.isEmpty, coworkSessionLineIsProjectable(pending) {
            messageCount += 1
        }
        return messageCount
    }

    private func coworkSessionMessageCount(_ data: Data) -> Int {
        var messageCount = 0
        for line in data.split(separator: 0x0A, omittingEmptySubsequences: false) {
            if coworkSessionLineIsProjectable(line) {
                messageCount += 1
            }
        }
        return messageCount
    }

    private func coworkSessionLineIsProjectable(
        _ line: Data.SubSequence
    ) -> Bool {
        guard !line.isEmpty,
              let value = try? JSONDecoder().decode(
                  CodexJSONValue.self,
                  from: Data(line)
              ),
              case let .object(fields) = value
        else { return false }
        if fields["isMeta"] == .bool(true)
            || fields["isSidechain"] == .bool(true)
        {
            return false
        }
        if case let .string(type)? = fields["type"],
           type == "user" || type == "assistant"
        {
            return true
        }
        if case let .object(message)? = fields["message"],
           case let .string(role)? = message["role"],
           role == "user" || role == "assistant"
        {
            return true
        }
        return false
    }

    private func canonicalPath(_ url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    private func manifestActivityDate(_ object: [String: Any]) -> Date? {
        for key in ["lastActivityAt", "updatedAt", "createdAt"] {
            guard let value = object[key] else { continue }
            if let string = value as? String,
               let date = ISO8601DateFormatter().date(from: string)
            {
                return date
            }
            if let number = value as? NSNumber {
                let raw = number.doubleValue
                let seconds = raw > 100_000_000_000 ? raw / 1_000 : raw
                return Date(timeIntervalSince1970: seconds)
            }
        }
        return nil
    }

    private func sessionMetadata(
        _ file: URL
    ) -> (cwd: String?, title: String?) {
        guard let handle = try? FileHandle(
            forReadingFrom: file
        ) else { return (nil, nil) }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: 64 * 1_024))
            ?? Data()
        guard let text = String(data: data, encoding: .utf8)
        else { return (nil, nil) }
        var cwd: String?
        var title: String?
        for line in text.split(separator: "\n").prefix(40) {
            guard let data = line.data(using: .utf8),
                  let value = try? JSONDecoder().decode(
                      CodexJSONValue.self,
                      from: data
                  ),
                  case let .object(fields) = value
            else { continue }
            if case let .string(value)? = fields["cwd"] {
                cwd = value
            }
            if case let .string(value)? =
                fields["customTitle"]
                    ?? fields["title"]
            {
                title = value
            }
            if case let .object(payload)? = fields["payload"] {
                if cwd == nil,
                   case let .string(value)? = payload["cwd"]
                {
                    cwd = value
                }
                if title == nil,
                   case let .string(value)? =
                       payload["title"]
                {
                    title = value
                }
            }
        }
        return (cwd, title)
    }

    private func detectedMemoryProjects(
        sourceHome: URL
    ) throws -> [String] {
        let projects = sourceHome.appendingPathComponent(
            "projects",
            isDirectory: true
        )
        var result: [String] = []
        for project in try directoryNames(projects) {
            let memory = projects.appendingPathComponent(project)
                .appendingPathComponent("memory")
            if try directoryContainsMarkdown(memory) {
                result.append(project)
            }
        }
        return result.sorted()
    }

    private func instructionSource(
        scope: URL?,
        source: MigrationSource,
        sourceHome: URL
    ) throws -> URL? {
        let candidates: [URL]
        switch (source, scope) {
        case let (.claude, .some(scope)):
            candidates = [
                scope.appendingPathComponent("CLAUDE.md"),
                scope.appendingPathComponent(
                    ".claude/CLAUDE.md"
                ),
            ]
        case (.claude, nil):
            candidates = [
                sourceHome.appendingPathComponent("CLAUDE.md"),
            ]
        case let (.cursor, .some(scope)):
            candidates = [
                scope.appendingPathComponent(".cursorrules"),
            ]
        case (.cursor, nil):
            candidates = []
        }
        for candidate in candidates
            where !(try isMissingOrEmpty(candidate))
        {
            return candidate
        }
        return nil
    }

    private func settingsFile(
        sourceDirectory: URL,
        source: MigrationSource,
        scope: URL?
    ) -> URL {
        switch source {
        case .claude:
            sourceDirectory.appendingPathComponent("settings.json")
        case .cursor:
            sourceDirectory.appendingPathComponent(
                scope == nil ? "cli-config.json" : "cli.json"
            )
        }
    }

    private func containsMigratableConfig(
        _ file: URL,
        source: MigrationSource
    ) throws -> Bool {
        guard fileManager.fileExists(atPath: file.path)
        else { return false }
        let object = try readJSONObject(file)
        switch source {
        case .claude:
            if case let .object(sandbox)? = object["sandbox"],
               sandbox["enabled"] == .bool(true)
            {
                return true
            }
        case .cursor:
            return fileManager.fileExists(
                atPath: file.deletingLastPathComponent()
                    .appendingPathComponent("sandbox.json").path
            )
        }
        return false
    }

    private func targetSkillsRoot(scope: URL?) -> URL {
        if let scope {
            return scope.appendingPathComponent(
                ".agents/skills",
                isDirectory: true
            )
        }
        return codexHome.appendingPathComponent(
            "skills",
            isDirectory: true
        )
    }

    private func item(
        _ type: String,
        _ description: String,
        cwd: String?,
        details: CodexJSONValue? = nil
    ) -> CodexExternalAgentMigrationItem {
        CodexExternalAgentMigrationItem(
            itemType: type,
            description: description,
            cwd: cwd,
            details: details
        )
    }

    private func details(
        _ key: String,
        names: [String]
    ) -> CodexJSONValue {
        var fields = emptyDetailsFields()
        fields[key] = .array(
            names.map {
                .object(["name": .string($0)])
            }
        )
        return .object(fields)
    }

    private func emptyDetailsFields()
        -> [String: CodexJSONValue]
    {
        [
            "plugins": .array([]),
            "skills": .array([]),
            "sessions": .array([]),
            "mcpServers": .array([]),
            "hooks": .array([]),
            "subagents": .array([]),
            "commands": .array([]),
        ]
    }

    private func detailNames(
        _ details: CodexJSONValue?,
        key: String
    ) -> [String] {
        guard case let .object(fields)? = details,
              case let .array(items)? = fields[key]
        else { return [] }
        return items.compactMap {
            guard case let .object(item) = $0,
                  case let .string(name)? = item["name"]
            else { return nil }
            return name
        }
    }

    private func detailStrings(
        _ details: CodexJSONValue?,
        key: String
    ) -> [String] {
        guard case let .object(fields)? = details,
              case let .array(items)? = fields[key]
        else { return [] }
        return items.compactMap {
            if case let .string(value) = $0 { value } else { nil }
        }
    }

    private func detailPluginNames(
        _ details: CodexJSONValue?
    ) -> [String] {
        guard case let .object(fields)? = details,
              case let .array(groups)? = fields["plugins"]
        else { return [] }
        return groups.flatMap { group -> [String] in
            guard case let .object(fields) = group,
                  case let .array(names)? = fields["pluginNames"]
            else { return [] }
            return names.compactMap {
                if case let .string(value) = $0 { value }
                else { nil }
            }
        }
    }

    private func missingDirectories(
        source: URL,
        target: URL
    ) throws -> [String] {
        try directoryNames(source).filter {
            !fileManager.fileExists(
                atPath: target.appendingPathComponent($0).path
            )
        }
    }

    private func missingMarkdownNames(
        source: URL,
        target: URL,
        targetIsDirectory: Bool,
        targetExtension: String? = nil
    ) throws -> [String] {
        guard fileManager.fileExists(atPath: source.path)
        else { return [] }
        let entries = try fileManager.contentsOfDirectory(
            at: source,
            includingPropertiesForKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey,
            ],
            options: [.skipsHiddenFiles]
        )
        return try entries.compactMap { file in
            let values = try file.resourceValues(
                forKeys: [
                    .isRegularFileKey,
                    .isSymbolicLinkKey,
                ]
            )
            guard values.isRegularFile == true,
                  values.isSymbolicLink != true,
                  file.pathExtension.lowercased() == "md"
            else { return nil }
            let name = file.deletingPathExtension()
                .lastPathComponent
            let targetFile: URL
            if targetIsDirectory {
                targetFile = target.appendingPathComponent(
                    name,
                    isDirectory: true
                )
            } else {
                targetFile = target.appendingPathComponent(
                    name
                        + "."
                        + (targetExtension ?? file.pathExtension)
                )
            }
            return fileManager.fileExists(atPath: targetFile.path)
                ? nil : name
        }.sorted()
    }

    private func directoryNames(_ root: URL) throws -> [String] {
        guard fileManager.fileExists(atPath: root.path)
        else { return [] }
        return try fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [
                .isDirectoryKey,
                .isSymbolicLinkKey,
            ],
            options: [.skipsHiddenFiles]
        ).compactMap { url in
            let values = try url.resourceValues(
                forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
            )
            return values.isDirectory == true
                && values.isSymbolicLink != true
                ? url.lastPathComponent : nil
        }.sorted()
    }

    private func directoryContainsMarkdown(
        _ root: URL
    ) throws -> Bool {
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey,
            ],
            options: [.skipsHiddenFiles]
        ) else { return false }
        for case let file as URL in enumerator {
            let values = try file.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
            )
            if values.isSymbolicLink == true {
                enumerator.skipDescendants()
                continue
            }
            if values.isRegularFile == true,
               file.pathExtension.lowercased() == "md"
            {
                return true
            }
        }
        return false
    }

    private func readJSONObject(
        _ file: URL
    ) throws -> [String: CodexJSONValue] {
        try requireRegularFile(
            file,
            beneath: file.deletingLastPathComponent()
        )
        let data = try Data(contentsOf: file)
        guard case let .object(object) =
            try JSONDecoder().decode(
                CodexJSONValue.self,
                from: data
            )
        else {
            throw CodexExternalAgentMigrationError
                .malformedConfiguration(file.path)
        }
        return object
    }

    private func absoluteDirectory(_ path: String) throws -> URL {
        guard (path as NSString).isAbsolutePath else {
            throw CodexExternalAgentMigrationError
                .unsafePath(path)
        }
        let url = URL(fileURLWithPath: path)
            .standardizedFileURL
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(
            atPath: url.path,
            isDirectory: &isDirectory
        ), isDirectory.boolValue else {
            throw CodexExternalAgentMigrationError
                .unsafePath(path)
        }
        let values = try url.resourceValues(
            forKeys: [.isSymbolicLinkKey]
        )
        guard values.isSymbolicLink != true else {
            throw CodexExternalAgentMigrationError
                .unsafePath(path)
        }
        return url
    }

    private func requireRegularFile(
        _ file: URL,
        beneath root: URL
    ) throws {
        let candidate = file.standardizedFileURL
        let root = root.standardizedFileURL
        guard isDescendant(candidate, of: root) else {
            throw CodexExternalAgentMigrationError
                .unsafePath(file.path)
        }
        let values = try candidate.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
        )
        guard values.isRegularFile == true,
              values.isSymbolicLink != true
        else {
            throw CodexExternalAgentMigrationError
                .unsafePath(file.path)
        }
    }

    private func copyTextFile(
        source: URL,
        target: URL,
        rewriteExternalAgentTerms: Bool
    ) throws {
        try requireRegularFile(
            source,
            beneath: source.deletingLastPathComponent()
        )
        guard try isMissingOrEmpty(target) else {
            throw CodexExternalAgentMigrationError
                .targetExists(target.path)
        }
        let raw = try String(
            contentsOf: source,
            encoding: .utf8
        )
        try atomicWrite(
            Data(
                (
                    rewriteExternalAgentTerms
                    ? rewriteTerms(raw)
                    : raw
                ).utf8
            ),
            to: target
        )
    }

    private func copyDirectory(
        source: URL,
        target: URL
    ) throws {
        let values = try source.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        )
        guard values.isDirectory == true,
              values.isSymbolicLink != true
        else {
            throw CodexExternalAgentMigrationError
                .unsafePath(source.path)
        }
        guard !fileManager.fileExists(atPath: target.path)
        else { return }
        try createDirectory(target)
        for entry in try fileManager.contentsOfDirectory(
            at: source,
            includingPropertiesForKeys: [
                .isDirectoryKey,
                .isRegularFileKey,
                .isSymbolicLinkKey,
            ],
            options: [.skipsHiddenFiles]
        ) {
            let resource = try entry.resourceValues(
                forKeys: [
                    .isDirectoryKey,
                    .isRegularFileKey,
                    .isSymbolicLinkKey,
                ]
            )
            guard resource.isSymbolicLink != true else {
                continue
            }
            let childTarget = target.appendingPathComponent(
                entry.lastPathComponent,
                isDirectory: resource.isDirectory == true
            )
            if resource.isDirectory == true {
                try copyDirectory(
                    source: entry,
                    target: childTarget
                )
            } else if resource.isRegularFile == true {
                try fileManager.copyItem(
                    at: entry,
                    to: childTarget
                )
            }
        }
    }

    private func replaceDirectory(
        source: URL,
        target: URL
    ) throws {
        let staging = target.deletingLastPathComponent()
            .appendingPathComponent(
                ".\(target.lastPathComponent).\(UUID().uuidString).tmp",
                isDirectory: true
            )
        if fileManager.fileExists(atPath: staging.path) {
            try fileManager.removeItem(at: staging)
        }
        try copyDirectory(source: source, target: staging)
        try createDirectory(target.deletingLastPathComponent())
        if fileManager.fileExists(atPath: target.path) {
            try fileManager.removeItem(at: target)
        }
        try fileManager.moveItem(at: staging, to: target)
    }

    private func createDirectory(_ directory: URL) throws {
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
    }

    private func atomicWriteJSON(
        _ value: CodexJSONValue,
        to target: URL
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try atomicWrite(try encoder.encode(value), to: target)
    }

    private func atomicWrite(
        _ data: Data,
        to target: URL
    ) throws {
        try createDirectory(target.deletingLastPathComponent())
        let temporary = target.deletingLastPathComponent()
            .appendingPathComponent(
                ".\(target.lastPathComponent).\(UUID().uuidString).tmp"
            )
        try data.write(to: temporary, options: .atomic)
        if fileManager.fileExists(atPath: target.path) {
            _ = try fileManager.replaceItemAt(
                target,
                withItemAt: temporary
            )
        } else {
            try fileManager.moveItem(
                at: temporary,
                to: target
            )
        }
    }

    private func mergeTOMLScalars(
        _ values: [String: CodexJSONValue],
        into target: URL
    ) throws {
        var current = (
            try? String(contentsOf: target, encoding: .utf8)
        ) ?? ""
        for key in values.keys.sorted() {
            guard !current.split(separator: "\n").contains(
                where: {
                    $0.trimmingCharacters(
                        in: .whitespaces
                    ).hasPrefix("\(key) =")
                }
            ), let value = values[key]
            else { continue }
            switch value {
            case let .string(text):
                current +=
                    (current.isEmpty || current.hasSuffix("\n")
                        ? "" : "\n")
                    + "\(key) = \(tomlString(text))\n"
            case let .bool(flag):
                current +=
                    (current.isEmpty || current.hasSuffix("\n")
                        ? "" : "\n")
                    + "\(key) = \(flag ? "true" : "false")\n"
            default:
                continue
            }
        }
        try atomicWrite(Data(current.utf8), to: target)
    }

    private func appendTOMLSections(
        _ sections: String,
        into target: URL
    ) throws {
        var current = (
            try? String(contentsOf: target, encoding: .utf8)
        ) ?? ""
        if !current.isEmpty, !current.hasSuffix("\n") {
            current += "\n"
        }
        current += sections
        try atomicWrite(Data(current.utf8), to: target)
    }

    private func renderMCPServerTOML(
        name: String,
        value: CodexJSONValue
    ) -> String {
        guard case let .object(fields) = value else { return "" }
        var output = "\n[mcp_servers.\(tomlKey(name))]\n"
        for key in [
            "command", "url", "bearer_token_env_var",
        ] {
            if case let .string(value)? = fields[key] {
                output += "\(key) = \(tomlString(value))\n"
            }
        }
        if case let .array(args)? = fields["args"] {
            let strings = args.compactMap {
                if case let .string(value) = $0 {
                    return tomlString(value)
                }
                return nil
            }
            if !strings.isEmpty {
                output += "args = [\(strings.joined(separator: ", "))]\n"
            }
        }
        for key in ["env", "http_headers", "env_http_headers"] {
            guard case let .object(values)? = fields[key],
                  !values.isEmpty
            else { continue }
            output +=
                "\n[mcp_servers.\(tomlKey(name)).\(key)]\n"
            for child in values.keys.sorted() {
                if case let .string(value)? = values[child] {
                    output +=
                        "\(tomlKey(child)) = \(tomlString(value))\n"
                }
            }
        }
        return output
    }

    private func splitResults(
        _ results: [CodexJSONValue]
    ) throws -> (
        successes: [CodexJSONValue],
        failures: [CodexJSONValue]
    ) {
        var successes: [CodexJSONValue] = []
        var failures: [CodexJSONValue] = []
        for result in results {
            guard case let .object(fields) = result,
                  case let .string(type)? = fields["itemType"],
                  Self.supportedItemTypes.contains(type),
                  case let .array(ok)? = fields["successes"],
                  case let .array(failed)? = fields["failures"]
            else {
                throw CodexExternalAgentMigrationError
                    .invalidParameters
            }
            successes.append(contentsOf: ok)
            failures.append(contentsOf: failed)
        }
        return (successes, failures)
    }

    private var historyFile: URL {
        codexHome.appendingPathComponent(
            "state/external-agent-import-histories.json"
        )
    }

    private func loadHistories() throws -> [HistoryRecord] {
        guard fileManager.fileExists(atPath: historyFile.path)
        else { return [] }
        return try JSONDecoder().decode(
            [HistoryRecord].self,
            from: Data(contentsOf: historyFile)
        )
    }

    private func appendHistory(_ record: HistoryRecord) throws {
        var records = try loadHistories()
        records.append(record)
        if records.count > 200 {
            records.removeFirst(records.count - 200)
        }
        try createDirectory(
            historyFile.deletingLastPathComponent()
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try atomicWrite(
            try encoder.encode(records),
            to: historyFile
        )
    }

    private func readConnectorCandidates()
        -> [CodexJSONValue]
    {
        let file = codexHome.appendingPathComponent(
            "state/imported-session-connectors.json"
        )
        guard let data = try? Data(contentsOf: file),
              let value = try? JSONDecoder().decode(
                  CodexJSONValue.self,
                  from: data
              ),
              case let .object(counts) = value
        else { return [] }
        return counts.keys.sorted().compactMap { name in
            guard case let .integer(count) = counts[name],
                  count > 0
            else { return nil }
            return .object([
                "name": .string(name),
                "sessionCount": .integer(count),
                "source": .string("remoteMcpServersConfig"),
            ])
        }
    }

    private func timestampMilliseconds() -> Int64 {
        Int64((now().timeIntervalSince1970 * 1_000).rounded())
    }

    private func isMissingOrEmpty(_ file: URL) throws -> Bool {
        guard fileManager.fileExists(atPath: file.path)
        else { return true }
        let values = try file.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
        )
        guard values.isRegularFile == true,
              values.isSymbolicLink != true
        else { return true }
        return try Data(contentsOf: file)
            .allSatisfy { byte in
                byte == 0x20 || byte == 0x09
                    || byte == 0x0A || byte == 0x0D
            }
    }

    private func samePath(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.standardizedFileURL.path
            == rhs.standardizedFileURL.path
    }

    private func isDescendant(_ child: URL, of root: URL) -> Bool {
        let childParts = child.standardizedFileURL.pathComponents
        let rootParts = root.standardizedFileURL.pathComponents
        return childParts.count >= rootParts.count
            && Array(childParts.prefix(rootParts.count))
                == rootParts
    }

    private func safeComponent(_ value: String) -> Bool {
        !value.isEmpty
            && value != "."
            && value != ".."
            && !value.contains("/")
            && !value.contains("\\")
            && !value.contains("\0")
    }

    private func looksSecret(_ key: String) -> Bool {
        let normalized = key.uppercased()
        return [
            "KEY", "TOKEN", "SECRET", "PASSWORD",
            "AUTHORIZATION",
        ].contains { normalized.contains($0) }
    }

    private func rewriteTerms(_ text: String) -> String {
        var rewritten = text
        for term in [
            "CLAUDE.md", "Claude Code", "claude-code",
            "claude_code", "Claude",
        ] {
            rewritten = rewritten.replacingOccurrences(
                of: term,
                with: term == "CLAUDE.md"
                    ? "AGENTS.md" : "Codex",
                options: [.caseInsensitive]
            )
        }
        return rewritten
    }

    private func tomlString(_ value: String) -> String {
        let data = try? JSONEncoder().encode(value)
        return data.flatMap {
            String(data: $0, encoding: .utf8)
        } ?? "\"\""
    }

    private func tomlKey(_ value: String) -> String {
        if !value.isEmpty,
           value.allSatisfy({
               $0.isLetter || $0.isNumber
                   || $0 == "_" || $0 == "-"
           })
        {
            return value
        }
        return tomlString(value)
    }

    private func parseFrontmatter(
        _ text: String
    ) -> (fields: [String: String], body: String) {
        let normalized = text.replacingOccurrences(
            of: "\r\n",
            with: "\n"
        )
        guard normalized.hasPrefix("---\n"),
              let end = normalized.range(
                  of: "\n---\n",
                  range: normalized.index(
                      normalized.startIndex,
                      offsetBy: 4
                  )..<normalized.endIndex
              )
        else { return ([:], text) }
        let rawFields = normalized[
            normalized.index(
                normalized.startIndex,
                offsetBy: 4
            )..<end.lowerBound
        ]
        var fields: [String: String] = [:]
        for line in rawFields.split(separator: "\n") {
            guard let colon = line.firstIndex(of: ":")
            else { continue }
            let key = line[..<colon].trimmingCharacters(
                in: .whitespaces
            )
            let value = line[line.index(after: colon)...]
                .trimmingCharacters(
                    in: .whitespaces
                )
                .trimmingCharacters(
                    in: CharacterSet(
                        charactersIn: "\"'"
                    )
                )
            if !key.isEmpty {
                fields[key] = value
            }
        }
        return (
            fields,
            String(normalized[end.upperBound...])
                .trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
        )
    }
}
