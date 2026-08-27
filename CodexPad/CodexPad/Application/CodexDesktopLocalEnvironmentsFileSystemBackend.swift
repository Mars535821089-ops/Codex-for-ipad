import CryptoKit
import Foundation

/// A local-only filesystem implementation for the released
/// `localEnvironments` AppHost service.
///
/// Every operation is confined to an explicitly injected workspace root. The
/// actor also serializes compare-and-swap writes so a revision can only win
/// once, even when callers save concurrently.
public actor CodexDesktopLocalEnvironmentsFileSystemBackend {
    public typealias Value = CodexDesktopAppHostRPC.Value
    public typealias Host =
        CodexDesktopLocalEnvironmentsAppHostService.Host
    public typealias FileSystemOperation =
        CodexDesktopLocalEnvironmentsAppHostService.FileSystemOperation
    public typealias HostProvider =
        CodexDesktopLocalEnvironmentsAppHostService.HostProvider
    public typealias FileSystemHandler =
        CodexDesktopLocalEnvironmentsAppHostService.FileSystemHandler

    public enum Error: Swift.Error, Equatable, Sendable {
        case invalidHost(String)
        case invalidConfigPath(String)
        case invalidWorkspaceRoot(String)
        case unreadableFile(String)
        case unauthorizedPath(String)
    }

    private struct AuthorizedRoot: Sendable {
        let lexical: URL
        let resolved: URL
    }

    private let fileManager: FileManager
    private let authorizedRoots: [AuthorizedRoot]

    public init(
        authorizedWorkspaceRoots: [URL],
        fileManager: FileManager = .default
    ) {
        self.fileManager = fileManager
        authorizedRoots = authorizedWorkspaceRoots
            .map {
                let lexical = $0.standardizedFileURL
                return AuthorizedRoot(
                    lexical: lexical,
                    resolved: lexical.resolvingSymlinksInPath()
                )
            }
            .sorted {
                $0.resolved.path.count > $1.resolved.path.count
            }
    }

    /// Closure ready to inject into
    /// `CodexDesktopLocalEnvironmentsAppHostService`.
    public nonisolated var hostProvider: HostProvider {
        { hostID in
            hostID == "local" ? Host(id: "local") : nil
        }
    }

    /// Closure ready to inject into
    /// `CodexDesktopLocalEnvironmentsAppHostService`.
    public nonisolated var fileSystemHandler: FileSystemHandler {
        { [self] host, operation in
            try await handle(host: host, operation: operation)
        }
    }

    public func handle(
        host: Host,
        operation: FileSystemOperation
    ) throws -> Value {
        guard host.id == "local" else {
            throw Error.invalidHost(host.id)
        }

        switch operation {
        case let .list(workspaceRoot):
            return try list(workspaceRoot: workspaceRoot)
        case let .read(configPath):
            return try read(configPath: configPath)
        case let .saveConfig(configPath, expectedRevision, raw):
            return try saveConfig(
                configPath: configPath,
                expectedRevision: expectedRevision,
                raw: raw
            )
        }
    }

    private func list(workspaceRoot: String) throws -> Value {
        let requested = URL(fileURLWithPath: workspaceRoot)
            .standardizedFileURL
        let resolved = requested.resolvingSymlinksInPath()
        let root = try authorizedRoot(
            lexical: requested,
            resolved: resolved,
            reportedPath: workspaceRoot
        )

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(
            atPath: resolved.path,
            isDirectory: &isDirectory
        ), isDirectory.boolValue
        else {
            throw Error.invalidWorkspaceRoot(workspaceRoot)
        }

        var configs: [(url: URL, projectRoot: URL)] = []
        var projectRoot = resolved
        while Self.contains(root.resolved, projectRoot) {
            let environmentsDirectory = projectRoot
                .appendingPathComponent(".codex", isDirectory: true)
                .appendingPathComponent(
                    "environments",
                    isDirectory: true
                )
            if fileManager.fileExists(
                atPath: environmentsDirectory.path
            ) {
                let resolvedDirectory =
                    environmentsDirectory.resolvingSymlinksInPath()
                guard Self.contains(
                    root.resolved,
                    resolvedDirectory
                ) else {
                    throw Error.unauthorizedPath(
                        environmentsDirectory.path
                    )
                }
                let entries = try fileManager.contentsOfDirectory(
                    at: resolvedDirectory,
                    includingPropertiesForKeys: [
                        .isDirectoryKey,
                        .isRegularFileKey,
                    ],
                    options: [.skipsHiddenFiles]
                )
                for entry in entries
                where entry.pathExtension.lowercased() == "toml" {
                    let candidate = entry.standardizedFileURL
                    let candidateResolved =
                        candidate.resolvingSymlinksInPath()
                    guard Self.contains(
                        root.resolved,
                        candidateResolved
                    ) else {
                        throw Error.unauthorizedPath(candidate.path)
                    }
                    let values = try candidateResolved.resourceValues(
                        forKeys: [.isDirectoryKey, .isRegularFileKey]
                    )
                    guard values.isRegularFile == true,
                          values.isDirectory != true
                    else {
                        continue
                    }
                    configs.append(
                        (candidateResolved, projectRoot)
                    )
                }
            }

            if projectRoot.path == root.resolved.path {
                break
            }
            let parent = projectRoot.deletingLastPathComponent()
            guard parent.path != projectRoot.path else {
                break
            }
            projectRoot = parent
        }

        configs.sort { $0.url.path < $1.url.path }
        return .array(
            try configs.map {
                try environmentResult(
                    configURL: $0.url,
                    projectRoot: $0.projectRoot,
                    authorizedRoot: root.resolved
                )
            }
        )
    }

    private func read(configPath: String) throws -> Value {
        let target = try validatedConfigURL(
            configPath,
            allowMissing: true
        )
        guard fileManager.fileExists(atPath: target.url.path) else {
            return .object([
                "environment": .null,
                "exists": .bool(false),
                "raw": .null,
                "revision": .null,
            ])
        }

        let raw = try rawString(at: target.url)
        return .object([
            "environment": try environmentResult(
                configURL: target.url,
                projectRoot: target.projectRoot,
                authorizedRoot: target.authorizedRoot.resolved
            ),
            "exists": .bool(true),
            "raw": .string(raw),
            "revision": .string(Self.revision(for: raw)),
        ])
    }

    private func saveConfig(
        configPath: String,
        expectedRevision: String?,
        raw: String
    ) throws -> Value {
        let target = try validatedConfigURL(
            configPath,
            allowMissing: true
        )
        let exists = fileManager.fileExists(atPath: target.url.path)

        if exists {
            let currentRaw = try rawString(at: target.url)
            guard let expectedRevision,
                  Self.revision(for: currentRaw) == expectedRevision
            else {
                return .object(["type": .string("conflict")])
            }
        } else if expectedRevision != nil {
            return .object(["type": .string("conflict")])
        }

        let parent = target.url.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: parent,
            withIntermediateDirectories: true
        )
        let resolvedParent = parent.resolvingSymlinksInPath()
        guard Self.contains(
            target.authorizedRoot.resolved,
            resolvedParent
        ) else {
            throw Error.unauthorizedPath(configPath)
        }

        try Data(raw.utf8).write(to: target.url, options: .atomic)
        return .object(["type": .string("success")])
    }

    private func environmentResult(
        configURL: URL,
        projectRoot: URL,
        authorizedRoot: URL
    ) throws -> Value {
        let raw = try rawString(at: configURL)
        do {
            let environment = try EnvironmentTOMLParser(raw: raw)
                .parse()
            return .object([
                "configPath": .string(configURL.path),
                "cwdRelativeToGitRoot": .string(
                    Self.relativePath(
                        from: authorizedRoot,
                        to: projectRoot
                    )
                ),
                "environment": environment,
                "type": .string("success"),
            ])
        } catch {
            return .object([
                "configPath": .string(configURL.path),
                "cwdRelativeToGitRoot": .string(configURL.path),
                "error": .object([
                    "message": .string(
                        "Invalid local environment TOML"
                    )
                ]),
                "type": .string("error"),
            ])
        }
    }

    private func rawString(at url: URL) throws -> String {
        guard let raw = try? String(contentsOf: url, encoding: .utf8)
        else {
            throw Error.unreadableFile(url.path)
        }
        return raw
    }

    private func validatedConfigURL(
        _ path: String,
        allowMissing: Bool
    ) throws -> (
        url: URL,
        projectRoot: URL,
        authorizedRoot: AuthorizedRoot
    ) {
        let lexical = URL(fileURLWithPath: path).standardizedFileURL
        let components = lexical.pathComponents
        guard lexical.pathExtension.lowercased() == "toml",
              components.count >= 4,
              components[components.count - 3] == ".codex",
              components[components.count - 2] == "environments"
        else {
            throw Error.invalidConfigPath(path)
        }

        let projectRoot = lexical
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let resolvedProjectRoot =
            projectRoot.resolvingSymlinksInPath()
        let resolvedTarget = lexical.resolvingSymlinksInPath()
        let root = try authorizedRoot(
            lexical: lexical,
            resolved: resolvedTarget,
            reportedPath: path
        )
        guard Self.contains(root.resolved, resolvedProjectRoot)
        else {
            throw Error.unauthorizedPath(path)
        }

        if !allowMissing,
           !fileManager.fileExists(atPath: resolvedTarget.path) {
            throw Error.unreadableFile(path)
        }
        return (
            resolvedTarget,
            resolvedProjectRoot,
            root
        )
    }

    private func authorizedRoot(
        lexical: URL,
        resolved: URL,
        reportedPath: String
    ) throws -> AuthorizedRoot {
        guard let root = authorizedRoots.first(where: {
            Self.contains($0.lexical, lexical)
                && Self.contains($0.resolved, resolved)
        }) else {
            throw Error.unauthorizedPath(reportedPath)
        }
        return root
    }

    private static func contains(_ root: URL, _ candidate: URL) -> Bool {
        let rootPath = root.standardizedFileURL.path
        let candidatePath = candidate.standardizedFileURL.path
        return candidatePath == rootPath
            || candidatePath.hasPrefix(
                rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
            )
    }

    private static func relativePath(from root: URL, to child: URL) -> String {
        let rootComponents = root.standardizedFileURL.pathComponents
        let childComponents = child.standardizedFileURL.pathComponents
        guard childComponents.starts(with: rootComponents) else {
            return "."
        }
        let relative = childComponents.dropFirst(rootComponents.count)
            .joined(separator: "/")
        return relative.isEmpty ? "." : relative
    }

    private static func revision(for raw: String) -> String {
        let digest = SHA256.hash(data: Data(raw.utf8))
        return "sha256:" + digest.map {
            String(format: "%02x", $0)
        }.joined()
    }
}

private struct EnvironmentTOMLParser {
    typealias Value = CodexDesktopAppHostRPC.Value

    private enum Section: Equatable {
        case root
        case setup
        case setupPlatform(String)
        case cleanup
        case cleanupPlatform(String)
        case action(Int)
    }

    private struct Script {
        var script: String?
        var platforms: [String: String] = [:]
    }

    private struct Action {
        var name: String?
        var icon: String?
        var command: String?
        var platform: String?
    }

    private enum ParseError: Swift.Error {
        case invalid
    }

    let raw: String

    func parse() throws -> Value {
        var lines = raw.components(separatedBy: .newlines)
        var index = 0
        var section = Section.root
        var version: Int64?
        var name: String?
        var setup = Script()
        var cleanup: Script?
        var actions: [Action] = []
        var assigned: Set<String> = []

        while index < lines.count {
            let trimmed = lines[index]
                .trimmingCharacters(in: .whitespaces)
            index += 1
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                continue
            }

            if trimmed.hasPrefix("[[") {
                guard trimmed == "[[actions]]" else {
                    throw ParseError.invalid
                }
                actions.append(Action())
                section = .action(actions.count - 1)
                continue
            }
            if trimmed.hasPrefix("[") {
                section = try Self.section(for: trimmed)
                if section == .cleanup, cleanup == nil {
                    cleanup = Script()
                }
                continue
            }

            guard let equals = trimmed.firstIndex(of: "=") else {
                throw ParseError.invalid
            }
            let key = trimmed[..<equals]
                .trimmingCharacters(in: .whitespaces)
            let token = String(trimmed[trimmed.index(after: equals)...])
                .trimmingCharacters(in: .whitespaces)
            let value: String
            if token.hasPrefix("'''") || token.hasPrefix("\"\"\"") {
                value = try Self.multilineString(
                    token: token,
                    lines: &lines,
                    index: &index
                )
            } else {
                value = try Self.basicString(token)
            }

            let assignmentKey = "\(section).\(key)"
            guard assigned.insert(assignmentKey).inserted else {
                throw ParseError.invalid
            }

            switch section {
            case .root:
                switch key {
                case "version":
                    guard let integer = Int64(token),
                          integer >= 1
                    else {
                        throw ParseError.invalid
                    }
                    version = integer
                case "name":
                    name = value
                default:
                    throw ParseError.invalid
                }

            case .setup:
                guard key == "script" else {
                    throw ParseError.invalid
                }
                setup.script = value

            case let .setupPlatform(platform):
                guard key == "script" else {
                    throw ParseError.invalid
                }
                setup.platforms[platform] = value

            case .cleanup:
                guard key == "script" else {
                    throw ParseError.invalid
                }
                cleanup?.script = value

            case let .cleanupPlatform(platform):
                guard key == "script" else {
                    throw ParseError.invalid
                }
                if cleanup == nil {
                    cleanup = Script()
                }
                cleanup?.platforms[platform] = value

            case let .action(actionIndex):
                switch key {
                case "name":
                    actions[actionIndex].name = value
                case "icon":
                    guard ["tool", "run", "debug", "test"]
                        .contains(value)
                    else {
                        throw ParseError.invalid
                    }
                    actions[actionIndex].icon = value
                case "command":
                    actions[actionIndex].command = value
                case "platform":
                    guard ["darwin", "linux", "win32"]
                        .contains(value)
                    else {
                        throw ParseError.invalid
                    }
                    actions[actionIndex].platform = value
                default:
                    throw ParseError.invalid
                }
            }
        }

        guard let version, let name, let setupScript = setup.script
        else {
            throw ParseError.invalid
        }
        var environment: [String: Value] = [
            "name": .string(name),
            "setup": Self.scriptValue(
                setup,
                requiredScript: setupScript
            ),
            "version": .integer(version),
        ]
        if let cleanup {
            guard let cleanupScript = cleanup.script else {
                throw ParseError.invalid
            }
            environment["cleanup"] = Self.scriptValue(
                cleanup,
                requiredScript: cleanupScript
            )
        }
        if !actions.isEmpty {
            environment["actions"] = .array(
                try actions.map { action in
                    guard let name = action.name,
                          let command = action.command
                    else {
                        throw ParseError.invalid
                    }
                    var fields: [String: Value] = [
                        "command": .string(command),
                        "name": .string(name),
                    ]
                    if let icon = action.icon {
                        fields["icon"] = .string(icon)
                    }
                    if let platform = action.platform {
                        fields["platform"] = .string(platform)
                    }
                    return .object(fields)
                }
            )
        }
        return .object(environment)
    }

    private static func section(for header: String) throws -> Section {
        switch header {
        case "[setup]":
            return .setup
        case "[cleanup]":
            return .cleanup
        case "[setup.darwin]":
            return .setupPlatform("darwin")
        case "[setup.linux]":
            return .setupPlatform("linux")
        case "[setup.win32]":
            return .setupPlatform("win32")
        case "[cleanup.darwin]":
            return .cleanupPlatform("darwin")
        case "[cleanup.linux]":
            return .cleanupPlatform("linux")
        case "[cleanup.win32]":
            return .cleanupPlatform("win32")
        default:
            throw ParseError.invalid
        }
    }

    private static func basicString(_ token: String) throws -> String {
        if token.hasPrefix("\"") {
            guard let data = token.data(using: .utf8),
                  let decoded = try? JSONSerialization.jsonObject(
                    with: data,
                    options: [.fragmentsAllowed]
                  ) as? String
            else {
                throw ParseError.invalid
            }
            return decoded
        }
        // Integer parsing is handled by the root version assignment.
        return token
    }

    private static func multilineString(
        token: String,
        lines: inout [String],
        index: inout Int
    ) throws -> String {
        let literal = token.hasPrefix("'''")
        let delimiter = literal ? "'''" : "\"\"\""
        var remainder = String(token.dropFirst(3))
        var collected: [String] = []

        while true {
            if let range = closingDelimiter(
                in: remainder,
                delimiter: delimiter,
                literal: literal
            ) {
                collected.append(String(remainder[..<range.lowerBound]))
                let suffix = remainder[range.upperBound...]
                    .trimmingCharacters(in: .whitespaces)
                guard suffix.isEmpty || suffix.hasPrefix("#") else {
                    throw ParseError.invalid
                }
                break
            }
            if !remainder.isEmpty {
                collected.append(remainder)
            }
            guard index < lines.count else {
                throw ParseError.invalid
            }
            remainder = lines[index]
            index += 1
        }

        let joined = collected.joined(separator: "\n")
        return literal ? joined : try decodeBasicMultiline(joined)
    }

    private static func closingDelimiter(
        in value: String,
        delimiter: String,
        literal: Bool
    ) -> Range<String.Index>? {
        var searchStart = value.startIndex
        while searchStart < value.endIndex,
              let range = value.range(
                of: delimiter,
                range: searchStart..<value.endIndex
              ) {
            if literal || !isEscaped(range.lowerBound, in: value) {
                return range
            }
            searchStart = range.upperBound
        }
        return nil
    }

    private static func isEscaped(
        _ index: String.Index,
        in value: String
    ) -> Bool {
        var cursor = index
        var backslashCount = 0
        while cursor > value.startIndex {
            let previous = value.index(before: cursor)
            guard value[previous] == "\\" else {
                break
            }
            backslashCount += 1
            cursor = previous
        }
        return backslashCount.isMultiple(of: 2) == false
    }

    private static func decodeBasicMultiline(
        _ value: String
    ) throws -> String {
        var decoded = ""
        var index = value.startIndex
        while index < value.endIndex {
            let character = value[index]
            index = value.index(after: index)
            guard character == "\\" else {
                decoded.append(character)
                continue
            }
            guard index < value.endIndex else {
                throw ParseError.invalid
            }
            let escaped = value[index]
            index = value.index(after: index)
            switch escaped {
            case "\\":
                decoded.append("\\")
            case "\"":
                decoded.append("\"")
            case "b":
                decoded.append("\u{08}")
            case "f":
                decoded.append("\u{0C}")
            case "n":
                decoded.append("\n")
            case "r":
                decoded.append("\r")
            case "t":
                decoded.append("\t")
            default:
                throw ParseError.invalid
            }
        }
        return decoded
    }

    private static func scriptValue(
        _ script: Script,
        requiredScript: String
    ) -> Value {
        var fields: [String: Value] = [
            "script": .string(requiredScript)
        ]
        for platform in ["darwin", "linux", "win32"] {
            if let override = script.platforms[platform] {
                fields[platform] = .object([
                    "script": .string(override)
                ])
            }
        }
        return .object(fields)
    }
}
