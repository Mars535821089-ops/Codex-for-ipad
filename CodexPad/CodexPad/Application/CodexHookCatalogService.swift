import CryptoKit
import Foundation

public enum CodexHookEventName: String, Equatable, Sendable {
    case preToolUse
    case permissionRequest
    case postToolUse
    case preCompact
    case postCompact
    case sessionStart
    case sessionEnd
    case userPromptSubmit
    case subagentStart
    case subagentStop
    case stop
}

public enum CodexHookHandlerType: String, Equatable, Sendable {
    case command
    case prompt
    case agent
}

public enum CodexHookExecutionMode: String, Equatable, Sendable {
    case sync
    case async
}

public enum CodexHookSource: String, Equatable, Sendable {
    case system
    case user
    case project
    case mdm
    case sessionFlags
    case plugin
    case cloudRequirements
    case cloudManagedConfig
    case legacyManagedConfigFile
    case legacyManagedConfigMdm
    case unknown
}

public enum CodexHookTrustStatus: String, Equatable, Sendable {
    case managed
    case untrusted
    case trusted
    case modified
}

public struct CodexHookMetadata: Equatable, Sendable {
    public let key: String
    public let eventName: CodexHookEventName
    public let handlerType: CodexHookHandlerType
    public let executionMode: CodexHookExecutionMode
    public let matcher: String?
    public let command: String?
    public let timeoutSec: UInt64
    public let statusMessage: String?
    public let additionalContextLimit: UInt64?
    public let sourcePath: String
    public let source: CodexHookSource
    public let pluginID: String?
    public let displayOrder: Int64
    public let enabled: Bool
    public let isManaged: Bool
    public let currentHash: String
    public let trustStatus: CodexHookTrustStatus
}

public struct CodexHookErrorInfo: Equatable, Sendable {
    public let path: String
    public let message: String
}

public struct CodexHooksListEntry: Equatable, Sendable {
    public let cwd: String
    public let hooks: [CodexHookMetadata]
    public let warnings: [String]
    public let errors: [CodexHookErrorInfo]
}

@MainActor
public final class CodexHookCatalogService {
    private struct Source {
        let path: URL
        let source: CodexHookSource
        let pluginID: String?
        let pluginRoot: URL?
        let sourceRelativePath: String?
        let inlineData: Data?
    }

    private static let events: [
        (wire: String, api: CodexHookEventName, key: String)
    ] = [
        ("PreToolUse", .preToolUse, "pre_tool_use"),
        ("PermissionRequest", .permissionRequest, "permission_request"),
        ("PostToolUse", .postToolUse, "post_tool_use"),
        ("PreCompact", .preCompact, "pre_compact"),
        ("PostCompact", .postCompact, "post_compact"),
        ("SessionStart", .sessionStart, "session_start"),
        ("SessionEnd", .sessionEnd, "session_end"),
        ("UserPromptSubmit", .userPromptSubmit, "user_prompt_submit"),
        ("SubagentStart", .subagentStart, "subagent_start"),
        ("SubagentStop", .subagentStop, "subagent_stop"),
        ("Stop", .stop, "stop"),
    ]

    private let codexHome: URL
    private let fileManager: FileManager

    public init(
        codexHome: URL,
        fileManager: FileManager = .default
    ) {
        self.codexHome = codexHome.standardizedFileURL
        self.fileManager = fileManager
    }

    public func listHooks(cwds: [String]) -> [CodexHooksListEntry] {
        let requested = cwds.isEmpty
            ? [fileManager.currentDirectoryPath] : cwds
        return requested.map(scan)
    }

    private func scan(cwd: String) -> CodexHooksListEntry {
        let cwdURL = URL(
            fileURLWithPath: cwd,
            isDirectory: true
        ).standardizedFileURL
        var sources = [
            Source(
                path: codexHome.appendingPathComponent("hooks.json"),
                source: .user,
                pluginID: nil,
                pluginRoot: nil,
                sourceRelativePath: nil,
                inlineData: nil
            ),
            Source(
                path: cwdURL.appendingPathComponent(
                    ".codex/hooks.json"
                ),
                source: .project,
                pluginID: nil,
                pluginRoot: nil,
                sourceRelativePath: nil,
                inlineData: nil
            ),
        ]
        sources += pluginHookSources()

        var hooks: [CodexHookMetadata] = []
        var warnings: [String] = []
        var visited: Set<String> = []
        for source in sources
        where source.inlineData != nil
            || fileManager.fileExists(atPath: source.path.path)
        {
            let path = source.path.standardizedFileURL.path
            let identity = source.sourceRelativePath.map {
                "\(path)#\($0)"
            } ?? path
            guard visited.insert(identity).inserted else { continue }
            append(
                source,
                hooks: &hooks,
                warnings: &warnings
            )
        }
        return CodexHooksListEntry(
            cwd: cwd,
            hooks: hooks,
            warnings: warnings,
            errors: []
        )
    }

    private func append(
        _ source: Source,
        hooks: inout [CodexHookMetadata],
        warnings: inout [String]
    ) {
        let root: [String: Any]
        do {
            let data = try source.inlineData
                ?? Data(contentsOf: source.path)
            guard let object = try JSONSerialization
                .jsonObject(with: data) as? [String: Any],
                Set(object.keys).isSubset(of: ["description", "hooks"]),
                let events = object["hooks"] as? [String: Any]
            else {
                throw NSError(
                    domain: "CodexHookCatalog",
                    code: 1,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "expected a hooks object",
                    ]
                )
            }
            root = events
        } catch {
            warnings.append(
                "failed to parse hooks config \(source.path.path): \(error.localizedDescription)"
            )
            return
        }

        for event in Self.events {
            guard let groups = root[event.wire] as? [Any] else {
                continue
            }
            for (groupIndex, rawGroup) in groups.enumerated() {
                guard let group = rawGroup as? [String: Any],
                      let handlers = group["hooks"] as? [Any]
                else {
                    warnings.append(
                        "failed to parse hooks config \(source.path.path): invalid \(event.wire) matcher group"
                    )
                    continue
                }
                let matcher = group["matcher"] as? String
                if let matcher,
                   (try? NSRegularExpression(pattern: matcher)) == nil
                {
                    warnings.append(
                        "invalid matcher \"\(matcher)\" in \(source.path.path)"
                    )
                    continue
                }
                for (handlerIndex, rawHandler) in handlers.enumerated() {
                    guard let handler =
                        rawHandler as? [String: Any],
                        let type = handler["type"] as? String,
                        let handlerType =
                            CodexHookHandlerType(rawValue: type)
                    else {
                        warnings.append(
                            "failed to parse hooks config \(source.path.path): invalid hook handler"
                        )
                        continue
                    }
                    var command: String?
                    let executionMode: CodexHookExecutionMode
                    if handlerType == .command {
                        guard var resolvedCommand =
                            handler["command"] as? String,
                            !resolvedCommand.trimmingCharacters(
                                in: .whitespacesAndNewlines
                            ).isEmpty
                        else {
                            warnings.append(
                                "skipping empty hook command in \(source.path.path)"
                            )
                            continue
                        }
                        if let pluginRoot = source.pluginRoot {
                            resolvedCommand = resolvedCommand
                                .replacingOccurrences(
                                    of: "${PLUGIN_ROOT}",
                                    with: pluginRoot.path
                                )
                                .replacingOccurrences(
                                    of: "${CLAUDE_PLUGIN_ROOT}",
                                    with: pluginRoot.path
                                )
                        }
                        command = resolvedCommand
                        executionMode = handler["async"] as? Bool == true
                            ? .async : .sync
                    } else {
                        command = nil
                        executionMode = .sync
                    }
                    let timeout = normalizedTimeout(
                        handler["timeout"],
                        event: event.api,
                        sourcePath: source.path.path,
                        warnings: &warnings
                    )
                    let additionalContextLimit =
                        additionalContextLimit(
                            handler["additionalContextLimit"],
                            event: event.api,
                            sourcePath: source.path.path,
                            warnings: &warnings
                        )
                    let keySource: String
                    if let pluginID = source.pluginID,
                       let pluginRoot = source.pluginRoot
                    {
                        let relative =
                            source.sourceRelativePath
                            ?? source.path.path
                                .replacingOccurrences(
                                    of: pluginRoot.path + "/",
                                    with: ""
                                )
                        keySource = "\(pluginID):\(relative)"
                    } else {
                        keySource = source.path.path
                    }
                    let key =
                        "\(keySource):\(event.key):\(groupIndex):\(handlerIndex)"
                    hooks.append(
                        CodexHookMetadata(
                            key: key,
                            eventName: event.api,
                            handlerType: handlerType,
                            executionMode: executionMode,
                            matcher: matcher,
                            command: command,
                            timeoutSec: timeout,
                            statusMessage:
                                handler["statusMessage"] as? String,
                            additionalContextLimit:
                                additionalContextLimit,
                            sourcePath: source.path.path,
                            source: source.source,
                            pluginID: source.pluginID,
                            displayOrder: Int64(hooks.count),
                            enabled: true,
                            isManaged: false,
                            currentHash: currentHash(
                                eventKey: event.key,
                                handlerType: handlerType,
                                matcher: matcher,
                                command: handler["command"] as? String
                                    ?? command,
                                timeout: timeout,
                                executionMode: executionMode,
                                statusMessage:
                                    handler["statusMessage"] as? String,
                                additionalContextLimit:
                                    additionalContextLimit
                            ),
                            trustStatus: .untrusted
                        )
                    )
                }
            }
        }
    }

    private func pluginHookSources() -> [Source] {
        let cache = codexHome.appendingPathComponent(
            "plugins/cache",
            isDirectory: true
        )
        return CodexInstalledPluginInventory.discover(
            cacheRoot: cache,
            fileManager: fileManager
        ).flatMap { plugin in
            plugin.hookSources.map { hook in
                Source(
                    path: hook.path,
                    source: .plugin,
                    pluginID: plugin.pluginID,
                    pluginRoot: plugin.root,
                    sourceRelativePath:
                        hook.sourceRelativePath,
                    inlineData: hook.inlineData
                )
            }
        }.sorted {
            (
                $0.pluginID ?? "",
                $0.sourceRelativePath ?? $0.path.path
            ) < (
                $1.pluginID ?? "",
                $1.sourceRelativePath ?? $1.path.path
            )
        }
    }

    private func normalizedTimeout(
        _ value: Any?,
        event: CodexHookEventName,
        sourcePath: String,
        warnings: inout [String]
    ) -> UInt64 {
        let raw = (value as? NSNumber)?.uint64Value
        if event != .sessionEnd {
            return max(raw ?? 600, 1)
        }
        if let raw, raw > 3 {
            warnings.append(
                "clamping SessionEnd hook timeout to 3s in \(sourcePath)"
            )
        }
        return min(max(raw ?? 1, 1), 3)
    }

    private func additionalContextLimit(
        _ value: Any?,
        event: CodexHookEventName,
        sourcePath: String,
        warnings: inout [String]
    ) -> UInt64? {
        guard let number = value as? NSNumber else { return nil }
        let supported: Set<CodexHookEventName> = [
            .preToolUse, .postToolUse, .sessionStart,
            .userPromptSubmit, .subagentStart,
        ]
        guard supported.contains(event) else {
            warnings.append(
                "ignoring additionalContextLimit for \(event.rawValue) hook in \(sourcePath): this event cannot emit additionalContext"
            )
            return nil
        }
        return number.uint64Value
    }

    private func currentHash(
        eventKey: String,
        handlerType: CodexHookHandlerType,
        matcher: String?,
        command: String?,
        timeout: UInt64,
        executionMode: CodexHookExecutionMode,
        statusMessage: String?,
        additionalContextLimit: UInt64?
    ) -> String {
        var object: [String: Any] = [
            "event_name": eventKey,
            "handler_type": handlerType.rawValue,
            "timeout": timeout,
            "execution_mode": executionMode.rawValue,
        ]
        if let command { object["command"] = command }
        if let matcher { object["matcher"] = matcher }
        if let statusMessage {
            object["statusMessage"] = statusMessage
        }
        if let additionalContextLimit {
            object["additionalContextLimit"] =
                additionalContextLimit
        }
        let data = (try? JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys]
        )) ?? Data()
        let digest = SHA256.hash(data: data).map {
            String(format: "%02x", $0)
        }.joined()
        return "sha256:\(digest)"
    }
}
