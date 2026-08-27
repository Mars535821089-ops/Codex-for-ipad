#if SWIFT_PACKAGE
    import CodexPadDomain
#endif
import Foundation

enum CodexIOSAppContainerPathMigrator {
    private static let containerPrefix = [
        "/", "var", "mobile", "Containers", "Data", "Application",
    ]

    static func currentPath(
        for path: String,
        fileManager: FileManager
    ) -> String {
        guard !path.isEmpty,
              !fileManager.fileExists(atPath: path),
              let documents = fileManager.urls(
                  for: .documentDirectory,
                  in: .userDomainMask
              ).first
        else {
            return path
        }

        let components = (path as NSString).pathComponents
        let prefixCount = containerPrefix.count
        guard components.count >= prefixCount + 2,
              Array(components.prefix(prefixCount)) == containerPrefix,
              UUID(uuidString: components[prefixCount]) != nil,
              components[prefixCount + 1] == "Documents"
        else {
            return path
        }

        let relativeComponents = Array(
            components.dropFirst(prefixCount + 2)
        )
        guard relativeComponents.allSatisfy({
            !$0.isEmpty && $0 != "." && $0 != ".." && $0 != "/"
        }) else {
            return path
        }

        let documentsURL = documents.standardizedFileURL
        let candidate = relativeComponents.reduce(documentsURL) {
            $0.appendingPathComponent($1)
        }.standardizedFileURL
        let documentsPath = documentsURL.path
        guard candidate.path == documentsPath
                || candidate.path.hasPrefix(documentsPath + "/"),
              fileManager.fileExists(atPath: candidate.path)
        else {
            return path
        }
        return candidate.path
    }

    static func currentPath(
        for path: CodexWireOptional<String>,
        fileManager: FileManager
    ) -> CodexWireOptional<String> {
        guard case let .value(value) = path else {
            return path
        }
        return .value(currentPath(for: value, fileManager: fileManager))
    }
}

/// Native iPad implementations for the released desktop host configuration
/// routes.  The service reads the same on-disk files as desktop Codex instead
/// of synthesizing renderer fixtures.
enum CodexDesktopHostConfigurationService {
    struct AgentsDocument: Equatable, Sendable {
        let path: String
        let contents: String
    }

    private struct CustomAgent: Equatable, Sendable {
        let roleName: String
        let description: String?
        let configFile: String?
        let nicknameCandidates: [String]

        var json: CodexJSONValue {
            .object([
                "roleName": .string(roleName),
                "description":
                    description.map(CodexJSONValue.string) ?? .null,
                "configFile":
                    configFile.map(CodexJSONValue.string) ?? .null,
                "nicknameCandidates": .array(
                    nicknameCandidates.map(CodexJSONValue.string)
                ),
            ])
        }

        /// Matches the desktop merge helper: the newly discovered entry wins
        /// for populated fields and the earlier entry supplies fallbacks.
        func mergingFallback(_ previous: CustomAgent) -> CustomAgent {
            CustomAgent(
                roleName: roleName,
                description: description ?? previous.description,
                configFile: configFile ?? previous.configFile,
                nicknameCandidates:
                    nicknameCandidates.isEmpty
                        ? previous.nicknameCandidates
                        : nicknameCandidates
            )
        }
    }

    private struct ParsedAgentTOML {
        var root: [String: TOMLValue] = [:]
        var declarations: [String: [String: TOMLValue]] = [:]
    }

    private enum TOMLValue: Equatable {
        case string(String)
        case strings([String])
    }

    static func readAgentsDocument(
        codexHome: String,
        fileManager: FileManager
    ) throws -> AgentsDocument {
        let path = agentsDocumentURL(codexHome: codexHome)
        try fileManager.createDirectory(
            at: path.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if !fileManager.fileExists(atPath: path.path) {
            try Data().write(to: path, options: [.atomic])
        }
        let data = try Data(contentsOf: path)
        guard let contents = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        return AgentsDocument(path: path.path, contents: contents)
    }

    static func writeAgentsDocument(
        codexHome: String,
        contents: String,
        fileManager: FileManager
    ) throws -> String {
        let path = agentsDocumentURL(codexHome: codexHome)
        try fileManager.createDirectory(
            at: path.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(contents.utf8).write(to: path, options: [.atomic])
        return path.path
    }

    static func localCustomAgents(
        codexHome: String,
        roots: [String],
        fileManager: FileManager
    ) -> [CodexJSONValue] {
        var seenRoots = Set<String>()
        let candidateRoots = (
            [URL(fileURLWithPath: codexHome, isDirectory: true)]
                + roots.map {
                    URL(fileURLWithPath: $0, isDirectory: true)
                        .appendingPathComponent(".codex", isDirectory: true)
                }
        ).compactMap { candidate -> URL? in
            let normalized = candidate.standardizedFileURL
            guard seenRoots.insert(normalized.path).inserted else {
                return nil
            }
            return normalized
        }

        var merged: [String: CustomAgent] = [:]
        for root in candidateRoots {
            for agent in agents(
                in: root,
                fileManager: fileManager
            ) {
                if let previous = merged[agent.roleName] {
                    merged[agent.roleName] =
                        agent.mergingFallback(previous)
                } else {
                    merged[agent.roleName] = agent
                }
            }
        }
        return merged.values
            .sorted {
                $0.roleName.localizedStandardCompare($1.roleName)
                    == .orderedAscending
            }
            .map(\.json)
    }

    static func mcpCodexConfig(
        configuredSettings: [String: CodexJSONValue]
    ) -> CodexJSONValue {
        // The app-server config/read result is represented by the persisted
        // Codex config object on iPad.  Returning it intact preserves all real
        // MCP server fields and avoids renderer-only defaults.
        .object(configuredSettings)
    }

    static func developerInstructions(
        baseInstructions: String?,
        cwd: String?,
        instructionOverrides: [String: CodexJSONValue]?,
        threadToolsEnabled: Bool,
        includeProseDetailLevelInstructions: Bool,
        configuredSettings: [String: CodexJSONValue],
        fileManager: FileManager
    ) -> String {
        var appSections: [String] = []

        if let overridden = string(
            "desktopContextSection",
            in: instructionOverrides
        ) {
            appendSection(overridden, to: &appSections)
        } else {
            appendSection(
                """
                # Codex desktop context
                - You are running inside the Codex app. Use absolute local paths for files and preserve the current task state across host operations.

                ### Images/Visuals/Files
                - Render local media with an absolute filesystem path.
                - Use Mermaid for complex diagrams and Markdown links for web URLs.
                """,
                to: &appSections
            )
        }

        if let workspaceDependencies = string(
            "workspaceDependenciesSection",
            in: instructionOverrides
        ) {
            appendSection(workspaceDependencies, to: &appSections)
        } else {
            appendSection(
                """
                ### Workspace Dependencies
                - Load the bundled workspace dependency runtime before creating or editing spreadsheets, slides, documents, or PDFs.
                """,
                to: &appSections
            )
        }

        let effectiveCWD = cwd.map {
            CodexIOSAppContainerPathMigrator.currentPath(
                for: $0,
                fileManager: fileManager
            )
        }
        if isGitWorkspace(effectiveCWD, fileManager: fileManager) {
            appendSection(
                gitInstructions(configuredSettings),
                to: &appSections
            )
        }

        appendSection(
            """
            ### Automations
            - Use the automation host tools for recurring automations, reminders, monitors, follow-ups, and task wakeups.
            """,
            to: &appSections
        )

        if threadToolsEnabled {
            appendSection(
                """
                ### Thread Coordination
                - Treat task, thread, chat, and conversation as synonyms when they refer to Codex.
                - Use task-management host tools for creating, reading, continuing, handing off, pinning, archiving, renaming, and waiting on Codex tasks.
                - Create a user-owned task only when the user explicitly asks for one; use collaborating agents for bounded subtasks.
                """,
                to: &appSections
            )
        }

        if includeProseDetailLevelInstructions {
            appendSection(
                """
                ### Non-technical UI
                - Prefer user-facing descriptions of results over implementation noise, while retaining technical detail when it is needed to debug.
                """,
                to: &appSections
            )
        }

        appendSection(
            """
            ### Inline Code Comments
            - Attach actionable review findings to the narrowest relevant source lines and omit inline comments when there are no findings.
            """,
            to: &appSections
        )
        let appContext =
            "<app-context>\n"
            + appSections.joined(separator: "\n\n")
            + "\n</app-context>"
        var output: [String] = []
        appendSection(baseInstructions, to: &output)
        output.append(appContext)
        return output.joined(separator: "\n\n")
    }

    private static func agentsDocumentURL(
        codexHome: String
    ) -> URL {
        URL(fileURLWithPath: codexHome, isDirectory: true)
            .standardizedFileURL
            .appendingPathComponent("AGENTS.md", isDirectory: false)
    }

    private static func agents(
        in codexRoot: URL,
        fileManager: FileManager
    ) -> [CustomAgent] {
        var result: [String: CustomAgent] = [:]
        var declaredConfigFiles = Set<String>()
        let config = codexRoot.appendingPathComponent(
            "config.toml",
            isDirectory: false
        )
        if let parsed = parseTOML(at: config) {
            for roleName in parsed.declarations.keys.sorted() {
                guard let values = parsed.declarations[roleName] else {
                    continue
                }
                let rawConfigFile = string(
                    "config_file",
                    in: values
                )
                let configFile = rawConfigFile.map {
                    resolvedPath(
                        $0,
                        relativeTo: config.deletingLastPathComponent()
                    )
                }
                var declaration = CustomAgent(
                    roleName: roleName,
                    description: string("description", in: values),
                    configFile: configFile,
                    nicknameCandidates:
                        strings("nickname_candidates", in: values) ?? []
                )
                if let configFile {
                    declaredConfigFiles.insert(configFile)
                    if let fileAgent = agent(
                        at: URL(fileURLWithPath: configFile),
                        roleNameHint: roleName
                    ) {
                        declaration =
                            fileAgent.mergingFallback(declaration)
                    }
                }
                result[declaration.roleName] = declaration
            }
        }

        let directory = codexRoot.appendingPathComponent(
            "agents",
            isDirectory: true
        )
        guard let names = try? fileManager.contentsOfDirectory(
            atPath: directory.path
        ) else {
            return Array(result.values)
        }
        for name in names.sorted()
        where name.lowercased().hasSuffix(".toml") {
            let path = directory.appendingPathComponent(
                name,
                isDirectory: false
            ).standardizedFileURL
            guard !declaredConfigFiles.contains(path.path),
                  let standalone = agent(
                      at: path,
                      roleNameHint: nil
                  )
            else {
                continue
            }
            result[standalone.roleName] = standalone
        }
        return Array(result.values)
    }

    private static func agent(
        at path: URL,
        roleNameHint: String?
    ) -> CustomAgent? {
        guard let parsed = parseTOML(at: path) else {
            return nil
        }
        let declaredName = string("name", in: parsed.root)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let hintedName = roleNameHint?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let roleName =
            (declaredName?.isEmpty == false ? declaredName : nil)
            ?? (hintedName?.isEmpty == false ? hintedName : nil)
            ?? ""
        guard !roleName.isEmpty else {
            return nil
        }
        return CustomAgent(
            roleName: roleName,
            description: string("description", in: parsed.root),
            configFile: path.standardizedFileURL.path,
            nicknameCandidates:
                strings(
                    "nickname_candidates",
                    in: parsed.root
                ) ?? []
        )
    }

    private static func parseTOML(
        at path: URL
    ) -> ParsedAgentTOML? {
        guard let data = try? Data(contentsOf: path),
              let source = String(data: data, encoding: .utf8)
        else {
            return nil
        }
        var parsed = ParsedAgentTOML()
        var currentRole: String?
        for statement in statements(source) {
            let trimmed = statement.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            guard !trimmed.isEmpty else {
                continue
            }
            if trimmed.hasPrefix("["),
               trimmed.hasSuffix("]")
            {
                let table = String(trimmed.dropFirst().dropLast())
                let components = dottedComponents(table)
                if components.count == 2,
                   components[0] == "agents",
                   !components[1].isEmpty
                {
                    currentRole = components[1]
                    if parsed.declarations[currentRole!] == nil {
                        parsed.declarations[currentRole!] = [:]
                    }
                } else {
                    currentRole = nil
                }
                continue
            }
            guard let equals = unquotedIndex(
                of: "=",
                in: trimmed
            ) else {
                continue
            }
            let rawKey = String(trimmed[..<equals])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let rawValue = String(trimmed[trimmed.index(after: equals)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let key = parseTOMLStringOrBare(rawKey),
                  let value = parseTOMLValue(rawValue)
            else {
                continue
            }
            if let currentRole {
                parsed.declarations[currentRole, default: [:]][key] =
                    value
            } else {
                parsed.root[key] = value
            }
        }
        return parsed
    }

    private static func statements(
        _ source: String
    ) -> [String] {
        var output: [String] = []
        var pending = ""
        var arrayDepth = 0
        for rawLine in source.components(separatedBy: .newlines) {
            let line = removingComment(rawLine)
            if pending.isEmpty {
                pending = line
            } else {
                pending += "\n" + line
            }
            arrayDepth += bracketDelta(line)
            if arrayDepth <= 0 {
                output.append(pending)
                pending = ""
                arrayDepth = 0
            }
        }
        if !pending.isEmpty {
            output.append(pending)
        }
        return output
    }

    private static func removingComment(
        _ line: String
    ) -> String {
        var quote: Character?
        var escaping = false
        for index in line.indices {
            let character = line[index]
            if quote == "\"" && escaping {
                escaping = false
                continue
            }
            if quote == "\"", character == "\\" {
                escaping = true
                continue
            }
            if character == "\"" || character == "'" {
                if quote == character {
                    quote = nil
                } else if quote == nil {
                    quote = character
                }
                continue
            }
            if character == "#", quote == nil {
                return String(line[..<index])
            }
        }
        return line
    }

    private static func bracketDelta(
        _ value: String
    ) -> Int {
        var result = 0
        var quote: Character?
        var escaping = false
        for character in value {
            if quote == "\"" && escaping {
                escaping = false
                continue
            }
            if quote == "\"", character == "\\" {
                escaping = true
                continue
            }
            if character == "\"" || character == "'" {
                if quote == character {
                    quote = nil
                } else if quote == nil {
                    quote = character
                }
            } else if quote == nil {
                if character == "[" {
                    result += 1
                } else if character == "]" {
                    result -= 1
                }
            }
        }
        return result
    }

    private static func dottedComponents(
        _ value: String
    ) -> [String] {
        splitUnquoted(value, separator: ".").compactMap {
            parseTOMLStringOrBare(
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
    }

    private static func parseTOMLValue(
        _ value: String
    ) -> TOMLValue? {
        let trimmed = value.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        if trimmed.hasPrefix("["),
           trimmed.hasSuffix("]")
        {
            let body = String(trimmed.dropFirst().dropLast())
            let values = splitUnquoted(body, separator: ",")
                .map {
                    $0.trimmingCharacters(
                        in: .whitespacesAndNewlines
                    )
                }
                .filter { !$0.isEmpty }
            var strings: [String] = []
            for value in values {
                guard let string = parseQuotedTOMLString(value) else {
                    return nil
                }
                strings.append(string)
            }
            return .strings(strings)
        }
        return parseQuotedTOMLString(trimmed).map(TOMLValue.string)
    }

    private static func parseTOMLStringOrBare(
        _ value: String
    ) -> String? {
        let trimmed = value.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        if trimmed.hasPrefix("\"") || trimmed.hasPrefix("'") {
            return parseQuotedTOMLString(trimmed)
        }
        guard !trimmed.isEmpty,
              trimmed.allSatisfy({
                  $0.isLetter || $0.isNumber
                      || $0 == "_" || $0 == "-"
              })
        else {
            return nil
        }
        return trimmed
    }

    private static func parseQuotedTOMLString(
        _ value: String
    ) -> String? {
        guard value.count >= 2,
              let first = value.first,
              value.last == first,
              first == "\"" || first == "'"
        else {
            return nil
        }
        let body = String(value.dropFirst().dropLast())
        if first == "'" {
            return body
        }
        guard let data = value.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(
                  String.self,
                  from: data
              )
        else {
            return nil
        }
        return decoded
    }

    private static func splitUnquoted(
        _ value: String,
        separator: Character
    ) -> [String] {
        var result: [String] = []
        var start = value.startIndex
        var quote: Character?
        var escaping = false
        for index in value.indices {
            let character = value[index]
            if quote == "\"" && escaping {
                escaping = false
                continue
            }
            if quote == "\"", character == "\\" {
                escaping = true
                continue
            }
            if character == "\"" || character == "'" {
                if quote == character {
                    quote = nil
                } else if quote == nil {
                    quote = character
                }
                continue
            }
            if character == separator, quote == nil {
                result.append(String(value[start..<index]))
                start = value.index(after: index)
            }
        }
        result.append(String(value[start...]))
        return result
    }

    private static func unquotedIndex(
        of character: Character,
        in value: String
    ) -> String.Index? {
        var quote: Character?
        var escaping = false
        for index in value.indices {
            let current = value[index]
            if quote == "\"" && escaping {
                escaping = false
                continue
            }
            if quote == "\"", current == "\\" {
                escaping = true
                continue
            }
            if current == "\"" || current == "'" {
                if quote == current {
                    quote = nil
                } else if quote == nil {
                    quote = current
                }
                continue
            }
            if current == character, quote == nil {
                return index
            }
        }
        return nil
    }

    private static func string(
        _ key: String,
        in values: [String: TOMLValue]
    ) -> String? {
        guard case let .string(value)? = values[key] else {
            return nil
        }
        return value
    }

    private static func strings(
        _ key: String,
        in values: [String: TOMLValue]
    ) -> [String]? {
        guard case let .strings(value)? = values[key] else {
            return nil
        }
        return value
    }

    private static func string(
        _ key: String,
        in values: [String: CodexJSONValue]?
    ) -> String? {
        guard case let .string(value)? = values?[key] else {
            return nil
        }
        return value
    }

    private static func resolvedPath(
        _ value: String,
        relativeTo directory: URL
    ) -> String {
        let expanded = (value as NSString).expandingTildeInPath
        let url =
            expanded.hasPrefix("/")
                ? URL(fileURLWithPath: expanded)
                : directory.appendingPathComponent(expanded)
        return url.standardizedFileURL.path
    }

    private static func appendSection(
        _ section: String?,
        to output: inout [String]
    ) {
        guard let section else {
            return
        }
        let trimmed = section.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !trimmed.isEmpty else {
            return
        }
        output.append(trimmed)
    }

    private static func isGitWorkspace(
        _ cwd: String?,
        fileManager: FileManager
    ) -> Bool {
        guard let cwd,
              !cwd.trimmingCharacters(
                  in: .whitespacesAndNewlines
              ).isEmpty
        else {
            return false
        }
        var current = URL(
            fileURLWithPath: cwd,
            isDirectory: true
        ).standardizedFileURL
        while true {
            if fileManager.fileExists(
                atPath: current.appendingPathComponent(".git").path
            ) {
                return true
            }
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path {
                return false
            }
            current = parent
        }
    }

    private static func gitInstructions(
        _ settings: [String: CodexJSONValue]
    ) -> String {
        var lines: [String] = []
        if let prefix = string(
            "git-branch-prefix",
            in: settings
        )?.trimmingCharacters(in: .whitespacesAndNewlines),
           !prefix.isEmpty
        {
            lines.append(
                "- Use branch prefix `\(prefix)` by default unless the user requests a different prefix."
            )
        }
        if let commit = string(
            "git-commit-instructions",
            in: settings
        )?.trimmingCharacters(in: .whitespacesAndNewlines),
           !commit.isEmpty
        {
            lines.append("- Commit instructions: \(commit)")
        }
        if let pullRequest = string(
            "git-pr-instructions",
            in: settings
        )?.trimmingCharacters(in: .whitespacesAndNewlines),
           !pullRequest.isEmpty
        {
            lines.append(
                "- Pull request instructions: \(pullRequest)"
            )
        }
        lines.append(
            "- Emit the matching Git result directive only after its stage, commit, branch, push, or pull-request action has succeeded."
        )
        return "### Git\n" + lines.joined(separator: "\n")
    }
}
