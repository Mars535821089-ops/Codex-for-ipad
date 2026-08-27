import CryptoKit
import Foundation

/// Native boundary for the released `localEnvironments` AppHost service.
///
/// The service validates renderer and filesystem DTOs, while the injected
/// handlers remain responsible for resolving a real execution host and
/// performing filesystem operations on that host.
public actor CodexDesktopLocalEnvironmentsAppHostService {
    public typealias Value = CodexDesktopAppHostRPC.Value

    public struct Host: Equatable, Sendable {
        public let id: String

        public init(id: String) {
            self.id = id
        }
    }

    public enum FileSystemOperation: Equatable, Sendable {
        case list(workspaceRoot: String)
        case read(configPath: String)
        case saveConfig(
            configPath: String,
            expectedRevision: String?,
            raw: String
        )
    }

    public typealias HostProvider =
        @Sendable (String) async throws -> Host?
    public typealias FileSystemHandler =
        @Sendable (Host, FileSystemOperation) async throws -> Value

    public enum Error: Swift.Error, Equatable, Sendable {
        case invalidArguments
        case invalidPath
        case invalidResponse
        case unavailable(service: String, method: String)
        case unknownHost(String)
        case unsupportedMethod(service: String, method: String)
    }

    private let hostProvider: HostProvider?
    private let fileSystemHandler: FileSystemHandler?

    public init(
        hostProvider: HostProvider? = nil,
        fileSystemHandler: FileSystemHandler? = nil
    ) {
        self.hostProvider = hostProvider
        self.fileSystemHandler = fileSystemHandler
    }

    public func invoke(
        service: String,
        method: String,
        arguments: [Value]?
    ) async throws -> Value {
        guard service == "localEnvironments" else {
            throw Error.unsupportedMethod(
                service: service,
                method: method
            )
        }
        guard ["list", "read", "saveConfig"].contains(method) else {
            throw Error.unsupportedMethod(
                service: service,
                method: method
            )
        }
        guard let hostProvider, let fileSystemHandler else {
            throw Error.unavailable(
                service: service,
                method: method
            )
        }

        switch method {
        case "list":
            let fields = try Self.argumentObject(
                arguments,
                keys: ["hostId", "workspaceRoot"]
            )
            let host = try await Self.host(
                fields["hostId"],
                using: hostProvider
            )
            let workspaceRoot = try Self.absolutePath(
                fields["workspaceRoot"]
            )
            let result = try await fileSystemHandler(
                host,
                .list(workspaceRoot: workspaceRoot)
            )
            guard case let .array(environments) = result else {
                throw Error.invalidResponse
            }
            return .object([
                "environments": .array(
                    try environments.map(Self.environmentResult)
                )
            ])

        case "read":
            let fields = try Self.argumentObject(
                arguments,
                keys: ["configPath", "hostId"]
            )
            let host = try await Self.host(
                fields["hostId"],
                using: hostProvider
            )
            let configPath = try Self.absolutePath(
                fields["configPath"]
            )
            let result = try await fileSystemHandler(
                host,
                .read(configPath: configPath)
            )
            return .object([
                "environment": try Self.readState(
                    result,
                    configPath: configPath
                )
            ])

        case "saveConfig":
            let fields = try Self.argumentObject(
                arguments,
                keys: [
                    "configPath",
                    "expectedRevision",
                    "hostId",
                    "raw",
                ]
            )
            let host = try await Self.host(
                fields["hostId"],
                using: hostProvider
            )
            let configPath = try Self.absolutePath(
                fields["configPath"]
            )
            let expectedRevision = try Self.expectedRevision(
                fields["expectedRevision"]
            )
            guard case let .string(raw)? = fields["raw"] else {
                throw Error.invalidArguments
            }
            let result = try await fileSystemHandler(
                host,
                .saveConfig(
                    configPath: configPath,
                    expectedRevision: expectedRevision,
                    raw: raw
                )
            )
            guard case let .object(resultFields) = result,
                  Set(resultFields.keys) == ["type"],
                  case let .string(type)? = resultFields["type"],
                  ["success", "conflict"].contains(type)
            else {
                throw Error.invalidResponse
            }
            return .object([
                "configPath": .string(configPath),
                "type": .string(type),
            ])

        default:
            fatalError("validated localEnvironments method")
        }
    }

    private static func host(
        _ value: Value?,
        using provider: HostProvider
    ) async throws -> Host {
        let hostID = try nonemptyString(value)
        guard let host = try await provider(hostID) else {
            throw Error.unknownHost(hostID)
        }
        guard host.id == hostID else {
            throw Error.invalidResponse
        }
        return host
    }

    private static func argumentObject(
        _ arguments: [Value]?,
        keys: Set<String>
    ) throws -> [String: Value] {
        guard arguments?.count == 1,
              case let .object(fields)? = arguments?.first,
              Set(fields.keys) == keys
        else {
            throw Error.invalidArguments
        }
        return fields
    }

    private static func nonemptyString(
        _ value: Value?
    ) throws -> String {
        guard case let .string(string)? = value,
              !string.isEmpty,
              string == string.trimmingCharacters(
                  in: .whitespacesAndNewlines
              )
        else {
            throw Error.invalidArguments
        }
        return string
    }

    private static func absolutePath(
        _ value: Value?
    ) throws -> String {
        guard case let .string(path)? = value,
              !path.isEmpty,
              !path.contains("\0"),
              isAbsolutePath(path)
        else {
            throw Error.invalidPath
        }
        return path
    }

    private static func expectedRevision(
        _ value: Value?
    ) throws -> String? {
        if value == .null {
            return nil
        }
        guard case let .string(revision)? = value,
              revision.hasPrefix("sha256:"),
              revision.count == 71,
              revision.dropFirst(7).allSatisfy({
                  $0.isNumber || ("a" ... "f").contains($0)
              })
        else {
            throw Error.invalidArguments
        }
        return revision
    }

    private static func isAbsolutePath(_ path: String) -> Bool {
        if path.hasPrefix("/") {
            return true
        }
        let scalars = Array(path.unicodeScalars)
        if scalars.count >= 3,
           scalars[0].properties.isAlphabetic,
           scalars[1] == ":",
           scalars[2] == "\\" || scalars[2] == "/"
        {
            return true
        }
        return path.hasPrefix("\\\\")
    }

    private static func environmentResult(
        _ value: Value
    ) throws -> Value {
        guard case let .object(fields) = value,
              case let .string(type)? = fields["type"]
        else {
            throw Error.invalidResponse
        }
        switch type {
        case "success":
            guard Set(fields.keys)
                == [
                    "configPath",
                    "cwdRelativeToGitRoot",
                    "environment",
                    "type",
                ],
                case let .string(configPath)? =
                    fields["configPath"],
                isAbsolutePath(configPath),
                case let .string(cwd)? =
                    fields["cwdRelativeToGitRoot"],
                !cwd.isEmpty,
                case let .object(environment)? =
                    fields["environment"]
            else {
                throw Error.invalidResponse
            }
            return .object([
                "configPath": .string(configPath),
                "cwdRelativeToGitRoot": .string(cwd),
                "environment":
                    try normalizedEnvironment(environment),
                "type": .string("success"),
            ])

        case "error":
            guard Set(fields.keys)
                == [
                    "configPath",
                    "cwdRelativeToGitRoot",
                    "error",
                    "type",
                ],
                case let .string(configPath)? =
                    fields["configPath"],
                isAbsolutePath(configPath),
                case let .string(cwd)? =
                    fields["cwdRelativeToGitRoot"],
                cwd == configPath,
                case let .object(error)? = fields["error"],
                Set(error.keys) == ["message"],
                case let .string(message)? = error["message"],
                !message.isEmpty
            else {
                throw Error.invalidResponse
            }
            return .object([
                "configPath": .string(configPath),
                "cwdRelativeToGitRoot": .string(cwd),
                "error": .object(["message": .string(message)]),
                "type": .string("error"),
            ])

        default:
            throw Error.invalidResponse
        }
    }

    private static func readState(
        _ value: Value,
        configPath: String
    ) throws -> Value {
        guard case let .object(fields) = value,
              Set(fields.keys)
                == ["environment", "exists", "raw", "revision"],
              case let .bool(exists)? = fields["exists"]
        else {
            throw Error.invalidResponse
        }
        if !exists {
            guard fields["environment"] == .null,
                  fields["raw"] == .null,
                  fields["revision"] == .null
            else {
                throw Error.invalidResponse
            }
            return .object([
                "environment": .null,
                "exists": .bool(false),
                "raw": .null,
                "revision": .null,
            ])
        }

        guard case let .string(raw)? = fields["raw"],
              case let .string(revision)? = fields["revision"],
              revision == revisionForRaw(raw),
              let environment = fields["environment"]
        else {
            throw Error.invalidResponse
        }
        let normalized = try environmentResult(environment)
        guard case let .object(environmentFields) = normalized,
              environmentFields["configPath"]
                == .string(configPath)
        else {
            throw Error.invalidResponse
        }
        return .object([
            "environment": normalized,
            "exists": .bool(true),
            "raw": .string(raw),
            "revision": .string(revision),
        ])
    }

    private static func revisionForRaw(_ raw: String) -> String {
        let digest = SHA256.hash(data: Data(raw.utf8))
        return "sha256:" + digest.map {
            String(format: "%02x", $0)
        }.joined()
    }

    private static func normalizedEnvironment(
        _ fields: [String: Value]
    ) throws -> Value {
        let allowed: Set<String> = [
            "actions",
            "cleanup",
            "name",
            "setup",
            "version",
        ]
        guard Set(fields.keys).isSubset(of: allowed),
              case let .integer(version)? = fields["version"],
              version >= 1,
              case let .string(name)? = fields["name"],
              case let .object(setup)? = fields["setup"]
        else {
            throw Error.invalidResponse
        }
        var normalized: [String: Value] = [
            "name": .string(
                name.trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
            ),
            "setup": try normalizedScript(setup),
            "version": .integer(version),
        ]
        if case let .object(cleanup)? = fields["cleanup"] {
            normalized["cleanup"] =
                try normalizedScript(cleanup)
        } else if fields["cleanup"] != nil {
            throw Error.invalidResponse
        }
        if case let .array(actions)? = fields["actions"] {
            normalized["actions"] = .array(
                try actions.compactMap(normalizedAction)
            )
        } else if fields["actions"] != nil {
            throw Error.invalidResponse
        }
        return .object(normalized)
    }

    private static func normalizedScript(
        _ fields: [String: Value]
    ) throws -> Value {
        let allowed: Set<String> = [
            "darwin",
            "linux",
            "script",
            "win32",
        ]
        guard Set(fields.keys).isSubset(of: allowed),
              case let .string(script)? = fields["script"]
        else {
            throw Error.invalidResponse
        }
        var normalized: [String: Value] = [
            "script": .string(
                script.trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
            )
        ]
        for platform in ["darwin", "linux", "win32"] {
            guard let value = fields[platform] else {
                continue
            }
            guard case let .object(override) = value,
                  Set(override.keys) == ["script"],
                  case let .string(script)? = override["script"]
            else {
                throw Error.invalidResponse
            }
            normalized[platform] = .object([
                "script": .string(
                    script.trimmingCharacters(
                        in: .whitespacesAndNewlines
                    )
                )
            ])
        }
        return .object(normalized)
    }

    private static func normalizedAction(
        _ value: Value
    ) throws -> Value? {
        guard case let .object(fields) = value else {
            return nil
        }
        let allowed: Set<String> = [
            "command",
            "icon",
            "name",
            "platform",
        ]
        guard Set(fields.keys).isSubset(of: allowed),
              case let .string(name)? = fields["name"],
              case let .string(command)? = fields["command"]
        else {
            return nil
        }
        let trimmedName = name.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let trimmedCommand = command.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !trimmedName.isEmpty, !trimmedCommand.isEmpty else {
            return nil
        }
        var normalized: [String: Value] = [
            "command": .string(trimmedCommand),
            "icon": .null,
            "name": .string(trimmedName),
        ]
        if let icon = fields["icon"] {
            switch icon {
            case .null:
                normalized["icon"] = .null
            case let .string(value)
                where ["tool", "run", "debug", "test"]
                    .contains(value):
                normalized["icon"] = .string(value)
            default:
                normalized["icon"] = .null
            }
        }
        if let platform = fields["platform"] {
            guard case let .string(value) = platform,
                  ["darwin", "linux", "win32"].contains(value)
            else {
                throw Error.invalidResponse
            }
            normalized["platform"] = .string(value)
        }
        return .object(normalized)
    }
}
