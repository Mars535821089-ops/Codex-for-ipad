import Foundation

public enum CodexSkillScope: String, Equatable, Sendable {
    case user
    case repo
    case system
    case admin
}

public struct CodexSkillMetadata: Equatable, Sendable {
    public let name: String
    public let description: String
    public let shortDescription: String?
    public let path: String
    public let scope: CodexSkillScope
    public let enabled: Bool
}

public struct CodexSkillErrorInfo: Equatable, Sendable {
    public let path: String
    public let message: String
}

public struct CodexSkillsListEntry: Equatable, Sendable {
    public let cwd: String
    public let skills: [CodexSkillMetadata]
    public let errors: [CodexSkillErrorInfo]
}

public enum CodexSkillCatalogError: Error, Equatable, Sendable {
    case invalidSelector
    case unreadableRoot(String)
}

@MainActor
public final class CodexSkillCatalogService {
    private let fileManager: FileManager
    private let userRoots: [URL]
    private let systemRoots: [URL]
    private let userDefaults: UserDefaults
    private let enablementKey: String
    private var extraRoots: [URL] = []
    private var pluginCacheRoots: [URL] = []

    public init(
        userRoots: [URL],
        systemRoots: [URL],
        userDefaults: UserDefaults = .standard,
        enablementKey: String =
            "codex.desktop.skills.enablement.v1",
        fileManager: FileManager = .default
    ) {
        self.userRoots = userRoots
        self.systemRoots = systemRoots
        self.userDefaults = userDefaults
        self.enablementKey = enablementKey
        self.fileManager = fileManager
    }

    public func setExtraRoots(_ paths: [String]) {
        extraRoots = paths.map {
            URL(fileURLWithPath: $0, isDirectory: true)
                .standardizedFileURL
        }
    }

    public func setPluginCacheRoots(_ paths: [String]) {
        var visited: Set<String> = []
        pluginCacheRoots = paths.map {
            URL(fileURLWithPath: $0, isDirectory: true)
                .standardizedFileURL
        }.filter {
            visited.insert($0.path).inserted
        }
    }

    public func setEnabled(
        path: String?,
        name: String?,
        enabled: Bool
    ) throws -> Bool {
        guard (path != nil) != (name != nil),
              name?.trimmingCharacters(
                  in: .whitespacesAndNewlines
              ).isEmpty != true
        else {
            throw CodexSkillCatalogError.invalidSelector
        }
        var values = persistedEnablement()
        if let path {
            values["path:\(standardized(path))"] = enabled
        } else if let name {
            values["name:\(name)"] = enabled
        }
        userDefaults.set(values, forKey: enablementKey)
        return enabled
    }

    public func list(
        cwds: [String],
        forceReload _: Bool
    ) throws -> [CodexSkillsListEntry] {
        let requestedCWDs = cwds.isEmpty
            ? [fileManager.currentDirectoryPath]
            : cwds
        let enablement = persistedEnablement()
        return requestedCWDs.map { cwd in
            scan(cwd: cwd, enablement: enablement)
        }
    }

    private func scan(
        cwd: String,
        enablement: [String: Bool]
    ) -> CodexSkillsListEntry {
        var roots: [
            (
                path: URL,
                scope: CodexSkillScope,
                namespace: String?
            )
        ] = userRoots.map { ($0, .user, nil) }
            + systemRoots.map { ($0, .system, nil) }
            + extraRoots.map { ($0, .repo, nil) }
        for cacheRoot in pluginCacheRoots {
            for plugin in CodexInstalledPluginInventory.discover(
                cacheRoot: cacheRoot,
                fileManager: fileManager
            ) {
                roots += plugin.skillRoots.map {
                    (
                        path: $0,
                        scope: .user,
                        namespace: plugin.namespace
                    )
                }
            }
        }
        let repoRoot = URL(
            fileURLWithPath: cwd,
            isDirectory: true
        )
        .appendingPathComponent(".codex/skills", isDirectory: true)
        roots.append((repoRoot, .repo, nil))

        var visited: Set<String> = []
        var skills: [CodexSkillMetadata] = []
        var errors: [CodexSkillErrorInfo] = []
        for root in roots {
            guard let enumerator = fileManager.enumerator(
                at: root.path,
                includingPropertiesForKeys: [
                    .isRegularFileKey,
                ],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else {
                continue
            }
            for case let file as URL in enumerator
            where file.lastPathComponent == "SKILL.md" {
                let canonical = file.standardizedFileURL.path
                guard visited.insert(canonical).inserted else {
                    continue
                }
                do {
                    let fields = try parseFrontmatter(file)
                    guard let name = fields["name"],
                          !name.isEmpty,
                          let description = fields["description"],
                          !description.isEmpty
                    else {
                        throw CodexSkillCatalogError
                            .unreadableRoot(
                                "missing name or description frontmatter"
                            )
                    }
                    let exposedName = root.namespace.map {
                        "\($0):\(name)"
                    } ?? name
                    let enabled =
                        enablement["path:\(canonical)"]
                        ?? enablement["name:\(exposedName)"]
                        ?? true
                    skills.append(
                        CodexSkillMetadata(
                            name: exposedName,
                            description: description,
                            shortDescription:
                                fields["short-description"]
                                ?? fields["short_description"],
                            path: canonical,
                            scope: root.scope,
                            enabled: enabled
                        )
                    )
                } catch {
                    errors.append(
                        CodexSkillErrorInfo(
                            path: canonical,
                            message: String(describing: error)
                        )
                    )
                }
            }
        }
        skills.sort {
            ($0.name, $0.path) < ($1.name, $1.path)
        }
        errors.sort { $0.path < $1.path }
        return CodexSkillsListEntry(
            cwd: cwd,
            skills: skills,
            errors: errors
        )
    }

    private func parseFrontmatter(
        _ file: URL
    ) throws -> [String: String] {
        let text = try String(contentsOf: file, encoding: .utf8)
        let lines = text.components(separatedBy: .newlines)
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
            throw CodexSkillCatalogError.unreadableRoot(
                "missing YAML frontmatter"
            )
        }
        var result: [String: String] = [:]
        for line in lines[1..<end] {
            guard let separator = line.firstIndex(of: ":")
            else { continue }
            let key = line[..<separator]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            var value = line[line.index(after: separator)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if value.count >= 2,
               (value.first == "\"" && value.last == "\"")
                || (value.first == "'" && value.last == "'")
            {
                value.removeFirst()
                value.removeLast()
            }
            result[key] = value
        }
        return result
    }

    private func persistedEnablement() -> [String: Bool] {
        userDefaults.dictionary(
            forKey: enablementKey
        ) as? [String: Bool] ?? [:]
    }

    private func standardized(_ path: String) -> String {
        URL(fileURLWithPath: path)
            .standardizedFileURL.path
    }
}
