#if SWIFT_PACKAGE
    import CodexPadDomain
#endif
import Foundation

public struct CodexRecommendedSkillMetadata:
    Equatable,
    Sendable
{
    public let id: String
    public let name: String
    public let description: String
    public let shortDescription: String?
    public let iconSmall: String?
    public let iconLarge: String?
    public let repoPath: String

    public init(
        id: String,
        name: String,
        description: String,
        shortDescription: String?,
        iconSmall: String?,
        iconLarge: String?,
        repoPath: String
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.shortDescription = shortDescription
        self.iconSmall = iconSmall
        self.iconLarge = iconLarge
        self.repoPath = repoPath
    }

    public var jsonValue: CodexJSONValue {
        .object([
            "id": .string(id),
            "name": .string(name),
            "description": .string(description),
            "shortDescription":
                shortDescription.map(CodexJSONValue.string)
                ?? .null,
            "iconSmall":
                iconSmall.map(CodexJSONValue.string)
                ?? .null,
            "iconLarge":
                iconLarge.map(CodexJSONValue.string)
                ?? .null,
            "repoPath": .string(repoPath),
        ])
    }
}

public struct CodexRecommendedSkillsSnapshot:
    Equatable,
    Sendable
{
    public let skills: [CodexRecommendedSkillMetadata]
    public let fetchedAt: Int64?
    public let source: String
    public let repoRoot: String?
    public let error: String?

    public init(
        skills: [CodexRecommendedSkillMetadata],
        fetchedAt: Int64?,
        source: String,
        repoRoot: String?,
        error: String?
    ) {
        self.skills = skills
        self.fetchedAt = fetchedAt
        self.source = source
        self.repoRoot = repoRoot
        self.error = error
    }

    public var jsonValue: CodexJSONValue {
        .object([
            "skills": .array(skills.map(\.jsonValue)),
            "fetchedAt":
                fetchedAt.map(CodexJSONValue.integer)
                ?? .null,
            "source": .string(source),
            "repoRoot":
                repoRoot.map(CodexJSONValue.string)
                ?? .null,
            "error":
                error.map(CodexJSONValue.string)
                ?? .null,
        ])
    }
}

public struct CodexRecommendedSkillInstallResult:
    Equatable,
    Sendable
{
    public let success: Bool
    public let destination: String?
    public let error: String?

    public init(
        success: Bool,
        destination: String?,
        error: String?
    ) {
        self.success = success
        self.destination = destination
        self.error = error
    }

    public var jsonValue: CodexJSONValue {
        .object([
            "success": .bool(success),
            "destination":
                destination.map(CodexJSONValue.string)
                ?? .null,
            "error":
                error.map(CodexJSONValue.string)
                ?? .null,
        ])
    }
}

public struct CodexRecommendedSkillRemoveResult:
    Equatable,
    Sendable
{
    public let success: Bool
    public let deletedPath: String?
    public let error: String?

    public init(
        success: Bool,
        deletedPath: String?,
        error: String?
    ) {
        self.success = success
        self.deletedPath = deletedPath
        self.error = error
    }

    public var jsonValue: CodexJSONValue {
        .object([
            "success": .bool(success),
            "deletedPath":
                deletedPath.map(CodexJSONValue.string)
                ?? .null,
            "error":
                error.map(CodexJSONValue.string)
                ?? .null,
        ])
    }
}

public final class CodexRecommendedSkillService {
    private struct ParsedMetadata {
        var name: String?
        var description: String?
        var shortDescription: String?
        var iconSmall: String?
        var iconLarge: String?

        mutating func mergeInterfaceFallback(
            _ fallback: ParsedMetadata
        ) {
            shortDescription =
                shortDescription
                ?? fallback.shortDescription
            iconSmall = iconSmall ?? fallback.iconSmall
            iconLarge = iconLarge ?? fallback.iconLarge
        }
    }

    private enum ServiceError: Error {
        case invalidSkillID(String)
        case invalidRepoPath(String)
        case invalidInstallRoot(String)
        case missingRecommendedSkill(String)
        case emptyMarkdownOverride(String)
        case unremovableSkill(String)

        var message: String {
            switch self {
            case let .invalidSkillID(value):
                return "Invalid skill id: \(value)"
            case let .invalidRepoPath(value):
                return "Invalid skill repo path: \(value)"
            case let .invalidInstallRoot(value):
                return "Invalid skill install root: \(value)"
            case let .missingRecommendedSkill(value):
                return "Recommended skill not found at \(value)"
            case let .emptyMarkdownOverride(value):
                return
                    "Recommended skill markdown override is empty: \(value)"
            case let .unremovableSkill(value):
                return "Skill path is not removable: \(value)"
            }
        }
    }

    private static let recommendedPathComponents = [
        ["skills", ".curated"],
        ["skills", ".experimental"],
    ]

    private static let frontmatterAliases = [
        "name": "name",
        "description": "description",
        "short-description": "shortDescription",
        "short_description": "shortDescription",
        "shortDescription": "shortDescription",
        "icon-small": "iconSmall",
        "icon_small": "iconSmall",
        "iconSmall": "iconSmall",
        "icon-large": "iconLarge",
        "icon_large": "iconLarge",
        "iconLarge": "iconLarge",
    ]

    private static let interfaceAliases = [
        "short_description": "shortDescription",
        "shortDescription": "shortDescription",
        "short-description": "shortDescription",
        "icon_small": "iconSmall",
        "iconSmall": "iconSmall",
        "icon-small": "iconSmall",
        "icon_large": "iconLarge",
        "iconLarge": "iconLarge",
        "icon-large": "iconLarge",
    ]

    private let bundledRepoRoot: URL?
    private let vendorRepoRoot: URL?
    private let defaultInstallRoot: URL
    private let fileManager: FileManager
    private let now: () -> Date

    public init(
        bundledRepoRoot: URL?,
        vendorRepoRoot: URL? = nil,
        defaultInstallRoot: URL,
        fileManager: FileManager = .default,
        now: @escaping () -> Date = Date.init
    ) {
        self.bundledRepoRoot =
            bundledRepoRoot?.standardizedFileURL
        self.vendorRepoRoot =
            vendorRepoRoot?.standardizedFileURL
        self.defaultInstallRoot =
            defaultInstallRoot.standardizedFileURL
        self.fileManager = fileManager
        self.now = now
    }

    public func list(
        refresh _: Bool
    ) -> CodexRecommendedSkillsSnapshot {
        guard let bundledRepoRoot,
              isDirectory(bundledRepoRoot)
        else {
            return CodexRecommendedSkillsSnapshot(
                skills: [],
                fetchedAt: nil,
                source: "cache",
                repoRoot: bundledRepoRoot?.path,
                error: "Bundled recommended skills are unavailable"
            )
        }

        var skillsByID:
            [String: CodexRecommendedSkillMetadata] = [:]
        for components in Self.recommendedPathComponents {
            let recommendedRoot = components.reduce(
                bundledRepoRoot
            ) {
                $0.appendingPathComponent(
                    $1,
                    isDirectory: true
                )
            }
            for skill in scanRecommendedRoot(
                recommendedRoot,
                repoRoot: bundledRepoRoot
            ) where skillsByID[skill.id] == nil {
                skillsByID[skill.id] = skill
            }
        }

        let skills = skillsByID.values.sorted {
            let comparison = $0.name.localizedCompare($1.name)
            if comparison != .orderedSame {
                return comparison == .orderedAscending
            }
            return $0.id < $1.id
        }
        return CodexRecommendedSkillsSnapshot(
            skills: skills,
            fetchedAt: Int64(
                (now().timeIntervalSince1970 * 1_000).rounded()
            ),
            source: "bundled",
            repoRoot: bundledRepoRoot.path,
            error: nil
        )
    }

    public func install(
        skillID: String,
        repoPath: String,
        installRoot: String?,
        markdownOverride: String?,
        forceReinstall: Bool,
        source: String?,
        allowedInstallRoots: [URL]
    ) -> CodexRecommendedSkillInstallResult {
        do {
            try validateSkillID(skillID)
            let destinationRoot = try resolvedInstallRoot(
                installRoot,
                allowedInstallRoots: allowedInstallRoots
            )
            let destination = destinationRoot
                .appendingPathComponent(
                    skillID,
                    isDirectory: true
                )
                .standardizedFileURL
            guard contains(
                destination,
                in: destinationRoot,
                allowEqual: false
            ) else {
                throw ServiceError.invalidSkillID(skillID)
            }

            if let markdownOverride {
                guard !markdownOverride.trimmingCharacters(
                    in: .whitespacesAndNewlines
                ).isEmpty
                else {
                    throw ServiceError.emptyMarkdownOverride(
                        skillID
                    )
                }
                if source == nil {
                    try fileManager.createDirectory(
                        at: destination,
                        withIntermediateDirectories: true
                    )
                    try Data(markdownOverride.utf8).write(
                        to: destination.appendingPathComponent(
                            "SKILL.md",
                            isDirectory: false
                        ),
                        options: [.atomic]
                    )
                    return CodexRecommendedSkillInstallResult(
                        success: true,
                        destination: destination.path,
                        error: nil
                    )
                }
            }

            let sourceURL = try recommendedSource(
                repoPath: repoPath,
                source: source
            )
            if fileManager.fileExists(
                atPath: destination.path
            ),
               !forceReinstall,
               markdownOverride == nil
            {
                return CodexRecommendedSkillInstallResult(
                    success: true,
                    destination: destination.path,
                    error: nil
                )
            }

            try installAtomically(
                source: sourceURL,
                destination: destination,
                markdownOverride: markdownOverride
            )
            return CodexRecommendedSkillInstallResult(
                success: true,
                destination: destination.path,
                error: nil
            )
        } catch {
            return CodexRecommendedSkillInstallResult(
                success: false,
                destination: nil,
                error: errorMessage(error)
            )
        }
    }

    public func remove(
        skillPath: String,
        allowedInstallRoots: [URL]
    ) -> CodexRecommendedSkillRemoveResult {
        do {
            let removable = try removableSkillURL(
                skillPath,
                allowedInstallRoots: allowedInstallRoots
            )
            try fileManager.removeItem(at: removable)
            return CodexRecommendedSkillRemoveResult(
                success: true,
                deletedPath: removable.path,
                error: nil
            )
        } catch {
            return CodexRecommendedSkillRemoveResult(
                success: false,
                deletedPath: nil,
                error: errorMessage(error)
            )
        }
    }

    private func scanRecommendedRoot(
        _ root: URL,
        repoRoot: URL
    ) -> [CodexRecommendedSkillMetadata] {
        guard isDirectory(root),
              let entries =
                  try? fileManager.contentsOfDirectory(
                      at: root,
                      includingPropertiesForKeys: [
                          .isDirectoryKey,
                          .isRegularFileKey,
                      ],
                      options: []
                  )
        else {
            return []
        }

        return entries.compactMap { entry in
            guard !entry.lastPathComponent.hasPrefix("."),
                  let values = try? entry.resourceValues(
                      forKeys: [
                          .isDirectoryKey,
                          .isRegularFileKey,
                      ]
                  )
            else {
                return nil
            }
            let isDirectory = values.isDirectory == true
            let markdownURL =
                isDirectory
                    ? entry.appendingPathComponent(
                        "SKILL.md",
                        isDirectory: false
                    )
                    : entry
            guard fileManager.fileExists(
                atPath: markdownURL.path
            ),
                  let contents = try? String(
                      contentsOf: markdownURL,
                      encoding: .utf8
                  )
            else {
                return nil
            }

            var metadata = parseFrontmatter(contents)
            if isDirectory {
                let agentFile = entry
                    .appendingPathComponent(
                        "agents",
                        isDirectory: true
                    )
                    .appendingPathComponent(
                        "openai.yaml",
                        isDirectory: false
                    )
                if let agentContents = try? String(
                    contentsOf: agentFile,
                    encoding: .utf8
                ) {
                    metadata.mergeInterfaceFallback(
                        parseAgentInterface(agentContents)
                    )
                }
            }

            let id =
                isDirectory
                    ? entry.lastPathComponent
                    : entry.deletingPathExtension()
                        .lastPathComponent
            let icons = resolvedIcons(
                skillRoot: entry,
                skillID: id,
                isDirectory: isDirectory,
                iconSmall: metadata.iconSmall,
                iconLarge: metadata.iconLarge
            )
            let repoTarget =
                isDirectory ? entry : markdownURL
            guard let repoPath = relativePath(
                repoTarget,
                root: repoRoot
            ) else {
                return nil
            }
            let shortDescription =
                nonempty(metadata.shortDescription)
            return CodexRecommendedSkillMetadata(
                id: id,
                name: nonempty(metadata.name) ?? id,
                description:
                    nonempty(metadata.description)
                    ?? shortDescription
                    ?? id,
                shortDescription: shortDescription,
                iconSmall: icons.small,
                iconLarge: icons.large,
                repoPath: repoPath
            )
        }
    }

    private func parseFrontmatter(
        _ contents: String
    ) -> ParsedMetadata {
        let lines = contents.components(separatedBy: .newlines)
        guard lines.first?.trimmingCharacters(
            in: .whitespacesAndNewlines
        ) == "---",
              let end = lines.dropFirst().firstIndex(
                  where: {
                      $0.trimmingCharacters(
                          in: .whitespacesAndNewlines
                      ) == "---"
                  }
              )
        else {
            return ParsedMetadata()
        }

        var result = ParsedMetadata()
        var nestedSection: String?
        for line in lines[1..<end] {
            guard !line.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).isEmpty
            else {
                continue
            }
            let isIndented =
                line.first?.isWhitespace == true
            if !isIndented {
                nestedSection = nil
                guard let pair = yamlPair(line) else {
                    continue
                }
                if let field =
                    Self.frontmatterAliases[pair.key]
                {
                    assign(
                        pair.value,
                        field: field,
                        to: &result
                    )
                } else if pair.key == "metadata"
                    || pair.key == "interface"
                {
                    nestedSection = pair.key
                }
                continue
            }
            guard nestedSection != nil,
                  let pair = yamlPair(
                      line.trimmingCharacters(
                          in: .whitespacesAndNewlines
                      )
                  ),
                  let field =
                      Self.frontmatterAliases[pair.key],
                  field != "name",
                  field != "description"
            else {
                continue
            }
            assign(
                pair.value,
                field: field,
                to: &result
            )
        }
        return result
    }

    private func parseAgentInterface(
        _ contents: String
    ) -> ParsedMetadata {
        var result = ParsedMetadata()
        var inInterface = false
        for line in contents.components(
            separatedBy: .newlines
        ) {
            if !inInterface {
                if line.trimmingCharacters(
                    in: .whitespacesAndNewlines
                ) == "interface:" {
                    inInterface = true
                }
                continue
            }
            if line.first?.isWhitespace != true {
                break
            }
            guard let pair = yamlPair(
                line.trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
            ),
                  let field =
                      Self.interfaceAliases[pair.key],
                  !pair.value.isEmpty
            else {
                continue
            }
            assign(
                pair.value,
                field: field,
                to: &result
            )
        }
        return result
    }

    private func yamlPair(
        _ line: String
    ) -> (key: String, value: String)? {
        guard let separator = line.firstIndex(of: ":") else {
            return nil
        }
        let key = line[..<separator].trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let rawValue = line[
            line.index(after: separator)...
        ].trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        return (key, unquoted(rawValue))
    }

    private func assign(
        _ value: String,
        field: String,
        to metadata: inout ParsedMetadata
    ) {
        switch field {
        case "name":
            metadata.name = value
        case "description":
            metadata.description = value
        case "shortDescription":
            metadata.shortDescription = value
        case "iconSmall":
            metadata.iconSmall = value
        case "iconLarge":
            metadata.iconLarge = value
        default:
            break
        }
    }

    private func unquoted(_ value: String) -> String {
        var result = value
        if result.count >= 2,
           (result.first == "\"" && result.last == "\"")
            || (result.first == "'" && result.last == "'")
        {
            result.removeFirst()
            result.removeLast()
        }
        return result
            .replacingOccurrences(of: "\\\"", with: "\"")
            .replacingOccurrences(of: "\\\\", with: "\\")
    }

    private func resolvedIcons(
        skillRoot: URL,
        skillID: String,
        isDirectory: Bool,
        iconSmall: String?,
        iconLarge: String?
    ) -> (small: String?, large: String?) {
        guard isDirectory else {
            return (iconSmall, iconLarge)
        }
        let assets = skillRoot.appendingPathComponent(
            "assets",
            isDirectory: true
        )
        guard self.isDirectory(assets) else {
            return (iconSmall, iconLarge)
        }
        let small = iconSmall ?? firstExistingPath(
            in: assets,
            names: [
                "\(skillID)-small.svg",
                "\(skillID)-small.png",
                "small.svg",
                "small.png",
                "\(skillID).svg",
                "\(skillID).png",
                "icon-small.svg",
                "icon-small.png",
            ]
        )
        let large = iconLarge ?? firstExistingPath(
            in: assets,
            names: [
                "\(skillID).png",
                "\(skillID).svg",
                "icon.png",
                "icon.svg",
                "\(skillID)-large.png",
                "\(skillID)-large.svg",
            ]
        )
        return (small, large)
    }

    private func firstExistingPath(
        in directory: URL,
        names: [String]
    ) -> String? {
        names.lazy.map {
            directory.appendingPathComponent(
                $0,
                isDirectory: false
            )
        }.first {
            fileManager.fileExists(atPath: $0.path)
        }?.path
    }

    private func recommendedSource(
        repoPath: String,
        source: String?
    ) throws -> URL {
        if source == nil,
           let vendorRepoRoot,
           let candidate = try? safeDescendant(
               root: vendorRepoRoot,
               relativePath: repoPath,
               error: ServiceError.invalidRepoPath(
                   repoPath
               )
           ),
           fileManager.fileExists(atPath: candidate.path)
        {
            return candidate
        }
        guard let bundledRepoRoot else {
            throw ServiceError.missingRecommendedSkill(
                repoPath
            )
        }
        let candidate = try safeDescendant(
            root: bundledRepoRoot,
            relativePath: repoPath,
            error: ServiceError.invalidRepoPath(repoPath)
        )
        guard fileManager.fileExists(atPath: candidate.path)
        else {
            throw ServiceError.missingRecommendedSkill(
                repoPath
            )
        }
        return candidate
    }

    private func resolvedInstallRoot(
        _ requestedRoot: String?,
        allowedInstallRoots: [URL]
    ) throws -> URL {
        let installRoot: URL
        let containmentRoot: URL
        if let requestedRoot {
            guard !requestedRoot.isEmpty,
                  !requestedRoot.contains("\0"),
                  (requestedRoot as NSString).isAbsolutePath
            else {
                throw ServiceError.invalidInstallRoot(
                    requestedRoot
                )
            }
            let projectRoot = URL(
                fileURLWithPath: requestedRoot,
                isDirectory: true
            ).standardizedFileURL
            let allowed = allowedInstallRoots.map {
                $0.standardizedFileURL
            }
            guard allowed.contains(where: {
                contains(
                    projectRoot,
                    in: $0,
                    allowEqual: true
                )
            }) else {
                throw ServiceError.invalidInstallRoot(
                    requestedRoot
                )
            }
            containmentRoot = projectRoot
            installRoot = projectRoot
                .appendingPathComponent(
                    ".codex",
                    isDirectory: true
                )
                .appendingPathComponent(
                    "skills",
                    isDirectory: true
                )
        } else {
            installRoot = defaultInstallRoot
            containmentRoot =
                defaultInstallRoot.deletingLastPathComponent()
        }
        try fileManager.createDirectory(
            at: installRoot,
            withIntermediateDirectories: true
        )
        let resolvedInstallRoot =
            installRoot.resolvingSymlinksInPath()
        let resolvedContainmentRoot =
            containmentRoot.resolvingSymlinksInPath()
        guard contains(
            resolvedInstallRoot,
            in: resolvedContainmentRoot,
            allowEqual: false
        ) else {
            throw ServiceError.invalidInstallRoot(
                requestedRoot ?? installRoot.path
            )
        }
        return installRoot.standardizedFileURL
    }

    private func installAtomically(
        source: URL,
        destination: URL,
        markdownOverride: String?
    ) throws {
        let parent = destination.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: parent,
            withIntermediateDirectories: true
        )
        let staging = parent.appendingPathComponent(
            ".\(destination.lastPathComponent).staging-\(UUID().uuidString)",
            isDirectory: true
        )
        let backup = parent.appendingPathComponent(
            ".\(destination.lastPathComponent).backup-\(UUID().uuidString)",
            isDirectory: true
        )
        try? fileManager.removeItem(at: staging)
        defer {
            try? fileManager.removeItem(at: staging)
            try? fileManager.removeItem(at: backup)
        }

        let values = try source.resourceValues(
            forKeys: [
                .isDirectoryKey,
                .isRegularFileKey,
            ]
        )
        if values.isDirectory == true {
            try fileManager.copyItem(
                at: source,
                to: staging
            )
        } else if values.isRegularFile == true {
            try fileManager.createDirectory(
                at: staging,
                withIntermediateDirectories: false
            )
            try fileManager.copyItem(
                at: source,
                to: staging.appendingPathComponent(
                    "SKILL.md",
                    isDirectory: false
                )
            )
        } else {
            throw ServiceError.missingRecommendedSkill(
                source.path
            )
        }

        if let markdownOverride {
            try Data(markdownOverride.utf8).write(
                to: staging.appendingPathComponent(
                    "SKILL.md",
                    isDirectory: false
                ),
                options: [.atomic]
            )
        }

        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.moveItem(
                at: destination,
                to: backup
            )
            do {
                try fileManager.moveItem(
                    at: staging,
                    to: destination
                )
            } catch {
                try? fileManager.moveItem(
                    at: backup,
                    to: destination
                )
                throw error
            }
            try? fileManager.removeItem(at: backup)
        } else {
            try fileManager.moveItem(
                at: staging,
                to: destination
            )
        }
    }

    private func removableSkillURL(
        _ skillPath: String,
        allowedInstallRoots: [URL]
    ) throws -> URL {
        guard !skillPath.isEmpty,
              !skillPath.contains("\0")
        else {
            throw ServiceError.unremovableSkill(skillPath)
        }
        let codexHome =
            defaultInstallRoot.deletingLastPathComponent()
        let customSkillRoots = allowedInstallRoots.map {
            $0.standardizedFileURL
                .appendingPathComponent(
                    ".codex",
                    isDirectory: true
                )
                .appendingPathComponent(
                    "skills",
                    isDirectory: true
                )
        }
        let skillRoots =
            [defaultInstallRoot.standardizedFileURL]
            + customSkillRoots
        var candidates: [URL] = []
        let normalized =
            skillPath.replacingOccurrences(of: "\\", with: "/")
                .trimmingCharacters(
                    in: CharacterSet(charactersIn: "/")
                )
        if (skillPath as NSString).isAbsolutePath {
            candidates.append(
                URL(fileURLWithPath: skillPath)
                    .standardizedFileURL
            )
        }
        if normalized.hasPrefix("skills/") {
            candidates.append(
                defaultInstallRoot.appendingPathComponent(
                    String(normalized.dropFirst(7))
                )
            )
        }
        candidates.append(
            codexHome.appendingPathComponent(skillPath)
        )
        candidates.append(
            defaultInstallRoot.appendingPathComponent(
                skillPath
            )
        )
        for projectRoot in allowedInstallRoots {
            candidates.append(
                projectRoot.appendingPathComponent(skillPath)
            )
            candidates.append(
                projectRoot
                    .appendingPathComponent(
                        ".codex/skills",
                        isDirectory: true
                    )
                    .appendingPathComponent(skillPath)
            )
        }

        var visited: Set<String> = []
        for rawCandidate in candidates {
            let candidate =
                rawCandidate.standardizedFileURL
            guard visited.insert(candidate.path).inserted,
                  fileManager.fileExists(
                      atPath: candidate.path
                  )
            else {
                continue
            }
            let values = try? candidate.resourceValues(
                forKeys: [
                    .isDirectoryKey,
                    .isRegularFileKey,
                ]
            )
            let directory =
                values?.isDirectory == true
                    ? candidate
                    : candidate.lastPathComponent == "SKILL.md"
                        && values?.isRegularFile == true
                        ? candidate.deletingLastPathComponent()
                        : nil
            guard let directory else {
                continue
            }
            for root in skillRoots {
                guard contains(
                    directory,
                    in: root,
                    allowEqual: false
                ) else {
                    continue
                }
                let resolvedDirectory =
                    directory.resolvingSymlinksInPath()
                let resolvedRoot =
                    root.resolvingSymlinksInPath()
                guard contains(
                    resolvedDirectory,
                    in: resolvedRoot,
                    allowEqual: false
                ) else {
                    continue
                }
                return directory
            }
        }
        throw ServiceError.unremovableSkill(skillPath)
    }

    private func validateSkillID(
        _ skillID: String
    ) throws {
        guard !skillID.isEmpty,
              !skillID.contains("\0"),
              skillID != ".",
              skillID != "..",
              !skillID.contains("/"),
              !skillID.contains("\\")
        else {
            throw ServiceError.invalidSkillID(skillID)
        }
    }

    private func safeDescendant(
        root: URL,
        relativePath: String,
        error: Error
    ) throws -> URL {
        guard !relativePath.isEmpty,
              !relativePath.contains("\0"),
              !(relativePath as NSString).isAbsolutePath
        else {
            throw error
        }
        let normalized = relativePath.replacingOccurrences(
            of: "\\",
            with: "/"
        )
        let candidate = normalized
            .split(separator: "/", omittingEmptySubsequences: false)
            .reduce(root.standardizedFileURL) {
                $0.appendingPathComponent(String($1))
            }
            .standardizedFileURL
        guard contains(
            candidate,
            in: root,
            allowEqual: false
        ) else {
            throw error
        }
        return candidate
    }

    private func contains(
        _ candidate: URL,
        in root: URL,
        allowEqual: Bool
    ) -> Bool {
        let candidatePath =
            candidate.standardizedFileURL.path
        let rootPath = root.standardizedFileURL.path
        if candidatePath == rootPath {
            return allowEqual
        }
        return candidatePath.hasPrefix(
            rootPath.hasSuffix("/")
                ? rootPath : rootPath + "/"
        )
    }

    private func relativePath(
        _ candidate: URL,
        root: URL
    ) -> String? {
        let candidatePath =
            candidate.standardizedFileURL.path
        let rootPath = root.standardizedFileURL.path
        let prefix =
            rootPath.hasSuffix("/")
                ? rootPath : rootPath + "/"
        guard candidatePath.hasPrefix(prefix) else {
            return nil
        }
        return String(
            candidatePath.dropFirst(prefix.count)
        ).replacingOccurrences(of: "\\", with: "/")
    }

    private func isDirectory(_ url: URL) -> Bool {
        var value: ObjCBool = false
        return fileManager.fileExists(
            atPath: url.path,
            isDirectory: &value
        ) && value.boolValue
    }

    private func nonempty(
        _ value: String?
    ) -> String? {
        guard let value,
              !value.isEmpty
        else {
            return nil
        }
        return value
    }

    private func errorMessage(_ error: Error) -> String {
        if let serviceError = error as? ServiceError {
            return serviceError.message
        }
        return String(describing: error)
    }
}
