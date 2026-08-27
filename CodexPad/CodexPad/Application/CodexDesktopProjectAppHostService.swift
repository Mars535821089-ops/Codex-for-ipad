import Foundation

/// Released AppHost adapters for local project mutations, thread/project
/// relationships, inactive-thread archival, and ChatGPT project-file sync.
///
/// The desktop implementations delegate these operations to process-global
/// Electron managers. iPadOS wires the same JSON contracts to the app's real
/// workspace, app-server, and download stores through the injected handlers.
/// Keeping those boundaries injected avoids manufacturing renderer state when
/// a platform mechanism is not connected yet.
public actor CodexDesktopProjectAppHostService {
    public typealias Value = CodexDesktopAppHostRPC.Value
    public typealias LocalProjectHandler =
        @Sendable (String, Value) async throws -> Value
    public typealias RemoteProjectHandler =
        @Sendable (String, Value) async throws -> Value
    public typealias ProjectQueryHandler =
        @Sendable (String, Value?) async throws -> Value
    public typealias ThreadProjectAssignmentHandler =
        @Sendable (Value) async throws -> Void
    public typealias ThreadArchiveHandler =
        @Sendable (Value) async throws -> Bool
    public typealias ChatGPTProjectFileSyncHandler =
        @Sendable (Value) async throws -> Value

    public enum Error: Swift.Error, Equatable, Sendable {
        case invalidArguments
        case invalidResponse
        case platformHandlerUnavailable(
            service: String,
            method: String
        )
        case unsupportedMethod(service: String, method: String)
    }

    private let localProjectHandler: LocalProjectHandler?
    private let remoteProjectHandler: RemoteProjectHandler?
    private let projectQueryHandler: ProjectQueryHandler?
    private let threadProjectAssignmentHandler:
        ThreadProjectAssignmentHandler?
    private let threadArchiveHandler: ThreadArchiveHandler?
    private let chatGptProjectFileSyncHandler:
        ChatGPTProjectFileSyncHandler?

    public init(
        localProjectHandler: LocalProjectHandler? = nil,
        remoteProjectHandler: RemoteProjectHandler? = nil,
        projectQueryHandler: ProjectQueryHandler? = nil,
        threadProjectAssignmentHandler:
            ThreadProjectAssignmentHandler? = nil,
        threadArchiveHandler: ThreadArchiveHandler? = nil,
        chatGptProjectFileSyncHandler:
            ChatGPTProjectFileSyncHandler? = nil
    ) {
        self.localProjectHandler = localProjectHandler
        self.remoteProjectHandler = remoteProjectHandler
        self.projectQueryHandler = projectQueryHandler
        self.threadProjectAssignmentHandler =
            threadProjectAssignmentHandler
        self.threadArchiveHandler = threadArchiveHandler
        self.chatGptProjectFileSyncHandler =
            chatGptProjectFileSyncHandler
    }

    public func invoke(
        service: String,
        method: String,
        arguments: [Value]?
    ) async throws -> Value {
        switch (service, method) {
        case ("projects", let projectMethod)
            where Self.projectLocalMutationMethods.contains(projectMethod):
            let request = try Self.projectLocalMutationRequest(
                method: projectMethod,
                arguments: arguments
            )
            guard let localProjectHandler else {
                throw Error.platformHandlerUnavailable(
                    service: service,
                    method: method
                )
            }
            let response = try await localProjectHandler(
                Self.canonicalLocalProjectMethod(projectMethod),
                request
            )
            if projectMethod == "createLocal" {
                try Self.validateLocalProjectCreateResponse(response)
                return response
            }
            return .undefined

        case ("projects", let projectMethod)
            where Self.projectQueryMethods.contains(projectMethod):
            let request = try Self.projectQueryRequest(
                method: projectMethod,
                arguments: arguments
            )
            guard let projectQueryHandler else {
                throw Error.platformHandlerUnavailable(
                    service: service,
                    method: method
                )
            }
            return try await projectQueryHandler(projectMethod, request)

        case ("projects", let projectMethod)
            where Self.remoteProjectMethods.contains(projectMethod):
            let request = try Self.remoteProjectRequest(
                method: projectMethod,
                arguments: arguments
            )
            guard let remoteProjectHandler else {
                throw Error.platformHandlerUnavailable(
                    service: service,
                    method: method
                )
            }
            let response = try await remoteProjectHandler(
                projectMethod,
                request
            )
            if projectMethod == "createRemote" {
                try Self.validateRemoteProjectCreateResponse(response)
                return response
            }
            return .undefined

        case ("localProjects", let projectMethod)
            where Self.localProjectMethods.contains(projectMethod):
            let request = try Self.localProjectRequest(
                method: projectMethod,
                arguments: arguments
            )
            guard let localProjectHandler else {
                throw Error.platformHandlerUnavailable(
                    service: service,
                    method: method
                )
            }
            let response = try await localProjectHandler(
                projectMethod,
                request
            )
            if projectMethod == "create" {
                try Self.validateLocalProjectCreateResponse(response)
                return response
            }
            return .undefined

        case (
            "threadProjectAssignments",
            "setAssignment"
        ):
            let request = try Self.threadAssignmentRequest(arguments)
            guard let threadProjectAssignmentHandler else {
                throw Error.platformHandlerUnavailable(
                    service: service,
                    method: method
                )
            }
            try await threadProjectAssignmentHandler(request)
            return .undefined

        case ("threadArchive", "archiveInactiveThread"):
            let request = try Self.threadArchiveRequest(arguments)
            guard let threadArchiveHandler else {
                throw Error.platformHandlerUnavailable(
                    service: service,
                    method: method
                )
            }
            return .object([
                "success": .bool(
                    try await threadArchiveHandler(request)
                ),
            ])

        case ("chatGptProjectFiles", "sync"):
            let request = try Self.chatGptProjectSyncRequest(arguments)
            guard let chatGptProjectFileSyncHandler else {
                throw Error.platformHandlerUnavailable(
                    service: service,
                    method: method
                )
            }
            let response = try await chatGptProjectFileSyncHandler(
                request
            )
            try Self.validateChatGptProjectSyncResponse(response)
            return response

        default:
            throw Error.unsupportedMethod(
                service: service,
                method: method
            )
        }
    }

    private static let localProjectMethods: Set<String> = [
        "create",
        "edit",
        "remove",
        "rename",
        "upsert",
    ]

    private static let projectLocalMutationMethods: Set<String> = [
        "createLocal",
        "editLocal",
        "removeLocal",
        "renameLocal",
        "upsertLocal",
    ]

    private static let projectQueryMethods: Set<String> = [
        "assignUnassignedThreadsBeforeProjectRootsChange",
        "createOrSelectLocalProjects",
        "createProjectForRoot",
        "getActiveWorkspaceRoots",
        "getProjectAppearances",
        "getProjectRootPathsForHost",
        "getLocalProjectsForDesktopState",
        "getLocalProjects",
        "getLocalProjectsForRenderer",
        "getLocalWorkspaceRootOptionsSync",
        "getRemoteProjects",
        "getWorkspaceRootOptions",
        "hasProjectNamed",
    ]

    private static let remoteProjectMethods: Set<String> = [
        "createRemote",
        "editRemote",
        "removeRemote",
        "renameRemote",
        "setAppearance",
        "upsertRemote",
    ]

    private static func canonicalLocalProjectMethod(
        _ method: String
    ) -> String {
        switch method {
        case "createLocal": return "create"
        case "editLocal": return "edit"
        case "removeLocal": return "remove"
        case "renameLocal": return "rename"
        case "upsertLocal": return "upsert"
        default: return method
        }
    }

    private static func projectLocalMutationRequest(
        method: String,
        arguments: [Value]?
    ) throws -> Value {
        try localProjectRequest(
            method: canonicalLocalProjectMethod(method),
            arguments: arguments
        )
    }

    private static func projectQueryRequest(
        method: String,
        arguments: [Value]?
    ) throws -> Value? {
        switch method {
        case "assignUnassignedThreadsBeforeProjectRootsChange",
             "createOrSelectLocalProjects":
            guard let arguments, arguments.count == 1,
                  case let .array(roots) = arguments[0]
            else {
                throw Error.invalidArguments
            }
            guard roots.allSatisfy({ nonemptyString($0) != nil }) else {
                throw Error.invalidArguments
            }
            return .array(
                roots.compactMap { value in
                    guard let root = nonemptyString(value) else {
                        return nil
                    }
                    return .string(root)
                }
            )
        case "createProjectForRoot":
            guard let arguments,
                  arguments.count == 1 || arguments.count == 2,
                  let root = nonemptyString(arguments[0])
            else {
                throw Error.invalidArguments
            }
            var fields: [String: Value] = [
                "root": .string(root),
            ]
            if arguments.count == 2 {
                guard let name = string(arguments[1]) else {
                    throw Error.invalidArguments
                }
                fields["name"] = .string(name)
            }
            return .object(fields)
        case "getProjectRootPathsForHost":
            guard let arguments, arguments.count == 1,
                  let hostID = nonemptyString(arguments[0])
            else {
                throw Error.invalidArguments
            }
            return .string(hostID)
        case "getRemoteProjects", "getProjectAppearances":
            guard arguments == nil || arguments?.isEmpty == true else {
                throw Error.invalidArguments
            }
            return nil
        case "getActiveWorkspaceRoots",
             "getLocalProjects",
             "getLocalProjectsForRenderer",
             "getLocalWorkspaceRootOptionsSync":
            guard arguments == nil || arguments?.isEmpty == true else {
                throw Error.invalidArguments
            }
            return nil
        case "getLocalProjectsForDesktopState":
            guard let arguments, arguments.count == 1 else {
                throw Error.invalidArguments
            }
            guard case .object = arguments[0] else {
                throw Error.invalidArguments
            }
            return arguments[0]
        case "getWorkspaceRootOptions":
            guard let arguments, arguments.count == 1 else {
                throw Error.invalidArguments
            }
            guard case .object = arguments[0] else {
                throw Error.invalidArguments
            }
            return arguments[0]
        case "hasProjectNamed":
            guard let arguments, arguments.count == 1,
                  case let .string(name) = arguments[0],
                  !name.trimmingCharacters(
                      in: .whitespacesAndNewlines
                  ).isEmpty
            else {
                throw Error.invalidArguments
            }
            return arguments[0]
        default:
            throw Error.unsupportedMethod(
                service: "projects",
                method: method
            )
        }
    }

    private static func remoteProjectRequest(
        method: String,
        arguments: [Value]?
    ) throws -> Value {
        if method == "removeRemote" {
            guard let arguments, arguments.count == 1,
                  let projectID = nonemptyString(arguments[0])
            else {
                throw Error.invalidArguments
            }
            return .string(projectID)
        }
        let fields = try argumentObject(arguments)
        switch method {
        case "createRemote":
            guard let hostID = nonemptyString(fields["hostId"]),
                  let label = string(fields["label"]),
                  let remotePath = nonemptyString(fields["remotePath"]),
                  let appearance = fields["appearance"],
                  let normalizedAppearance =
                      normalizedProjectAppearance(appearance)
            else {
                throw Error.invalidArguments
            }
            return .object([
                "appearance": normalizedAppearance,
                "hostId": .string(hostID),
                "label": .string(label),
                "remotePath": .string(remotePath),
            ])

        case "setAppearance":
            guard let projectID = nonemptyString(fields["projectId"]),
                  let appearance = fields["appearance"],
                  let normalizedAppearance =
                      normalizedProjectAppearance(appearance)
            else {
                throw Error.invalidArguments
            }
            return .object([
                "appearance": normalizedAppearance,
                "projectId": .string(projectID),
            ])

        case "renameRemote", "editRemote":
            guard let projectID = nonemptyString(fields["projectId"]),
                  let name = nonemptyString(fields["name"])
            else {
                throw Error.invalidArguments
            }
            return .object([
                "name": .string(name),
                "projectId": .string(projectID),
            ])

        case "upsertRemote":
            guard case let .integer(index)? = fields["index"], index >= 0,
                  let project = fields["project"],
                  case let .object(projectFields) = project,
                  let hostID = nonemptyString(projectFields["hostId"]),
                  let projectID = nonemptyString(projectFields["id"]),
                  let label = nonemptyString(projectFields["label"]),
                  let remotePath = nonemptyString(projectFields["remotePath"])
            else {
                throw Error.invalidArguments
            }
            return .object([
                "index": .integer(index),
                "project": .object([
                    "hostId": .string(hostID),
                    "id": .string(projectID),
                    "label": .string(label),
                    "remotePath": .string(remotePath),
                ]),
            ])

        default:
            throw Error.unsupportedMethod(
                service: "projects",
                method: method
            )
        }
    }

    private static func localProjectRequest(
        method: String,
        arguments: [Value]?
    ) throws -> Value {
        if method == "remove" {
            guard let projectID = string(arguments?.first) else {
                throw Error.invalidArguments
            }
            return .string(projectID)
        }

        let fields = try argumentObject(arguments)
        switch method {
        case "create":
            guard let name = string(fields["name"]),
                  let sources = stringArray(fields["sources"]),
                  case let .bool(initializeGit)? =
                      fields[
                          "initializeDefaultWorkspaceGitRepository"
                      ],
                  let appearance = fields["appearance"],
                  let normalizedAppearance =
                      normalizedProjectAppearance(appearance)
            else {
                throw Error.invalidArguments
            }
            return .object([
                "appearance": normalizedAppearance,
                "initializeDefaultWorkspaceGitRepository":
                    .bool(initializeGit),
                "name": .string(name),
                "sources": .array(sources.map(Value.string)),
            ])

        case "edit", "upsert":
            guard let projectID = string(fields["projectId"]),
                  let name = string(fields["name"]),
                  let sources = stringArray(fields["sources"])
            else {
                throw Error.invalidArguments
            }
            return .object([
                "name": .string(name),
                "projectId": .string(projectID),
                "sources": .array(sources.map(Value.string)),
            ])

        case "rename":
            guard let projectID = string(fields["projectId"]),
                  let name = string(fields["name"])
            else {
                throw Error.invalidArguments
            }
            return .object([
                "name": .string(name),
                "projectId": .string(projectID),
            ])

        default:
            throw Error.unsupportedMethod(
                service: "localProjects",
                method: method
            )
        }
    }

    private static func threadAssignmentRequest(
        _ arguments: [Value]?
    ) throws -> Value {
        let fields = try argumentObject(arguments)
        guard let threadID = nonemptyString(fields["threadId"]),
              let rawAssignment = fields["assignment"]
        else {
            throw Error.invalidArguments
        }
        let assignment: Value
        if rawAssignment == .null {
            assignment = .null
        } else {
            assignment = try normalizedAssignment(rawAssignment)
        }
        return .object([
            "assignment": assignment,
            "threadId": .string(threadID),
        ])
    }

    private static func normalizedAssignment(
        _ value: Value
    ) throws -> Value {
        guard case let .object(fields) = value,
              let kind = string(fields["projectKind"]),
              let projectID = nonemptyString(fields["projectId"])
        else {
            throw Error.invalidArguments
        }
        let pendingCoreUpdate: Bool
        if let rawPendingCoreUpdate = fields["pendingCoreUpdate"] {
            guard case let .bool(value) = rawPendingCoreUpdate else {
                throw Error.invalidArguments
            }
            pendingCoreUpdate = value
        } else {
            pendingCoreUpdate = false
        }
        var normalized: [String: Value] = [
            "pendingCoreUpdate": .bool(pendingCoreUpdate),
            "projectId": .string(projectID),
            "projectKind": .string(kind),
        ]
        switch kind {
        case "local":
            if let rawOrigin = fields["projectOrigin"] {
                guard case let .string(origin) = rawOrigin,
                      origin == "chatgpt"
                else {
                    throw Error.invalidArguments
                }
                normalized["projectOrigin"] = .string(origin)
            }
            try copyOptionalString(
                "path",
                from: fields,
                to: &normalized
            )
            try copyOptionalString(
                "cwd",
                from: fields,
                to: &normalized
            )
        case "remote":
            guard let path = string(fields["path"]) else {
                throw Error.invalidArguments
            }
            normalized["path"] = .string(path)
            try copyOptionalString(
                "cwd",
                from: fields,
                to: &normalized
            )
            try copyOptionalString(
                "hostId",
                from: fields,
                to: &normalized
            )
        default:
            throw Error.invalidArguments
        }
        return .object(normalized)
    }

    private static func threadArchiveRequest(
        _ arguments: [Value]?
    ) throws -> Value {
        let fields = try argumentObject(arguments)
        guard let hostID = nonemptyString(fields["hostId"]),
              let threadID = nonemptyString(fields["threadId"])
        else {
            throw Error.invalidArguments
        }
        var normalized: [String: Value] = [
            "hostId": .string(hostID),
            "threadId": .string(threadID),
        ]
        if let rawRemove = fields["removeCatalogEntryIfMissing"] {
            guard case let .bool(remove) = rawRemove else {
                throw Error.invalidArguments
            }
            normalized["removeCatalogEntryIfMissing"] = .bool(remove)
        }
        return .object(normalized)
    }

    private static func chatGptProjectSyncRequest(
        _ arguments: [Value]?
    ) throws -> Value {
        let fields = try argumentObject(arguments)
        guard case let .array(rawFiles)? = fields["files"],
              let instructions = string(fields["instructions"]),
              let projectID = string(fields["projectId"]),
              isValidChatGptProjectID(projectID),
              let projectName = string(fields["projectName"]),
              let callback = fields["getFileDownloadRequest"],
              isRPCTarget(callback)
        else {
            throw Error.invalidArguments
        }
        let files = try rawFiles.map { file -> Value in
            guard case let .object(fields) = file,
                  let fileID = nonemptyString(fields["fileId"]),
                  let name = nonemptyString(fields["name"])
            else {
                throw Error.invalidArguments
            }
            return .object([
                "fileId": .string(fileID),
                "name": .string(name),
            ])
        }
        return .object([
            "files": .array(files),
            "getFileDownloadRequest": callback,
            "instructions": .string(instructions),
            "projectId": .string(projectID),
            "projectName": .string(projectName),
        ])
    }

    private static func validateLocalProjectCreateResponse(
        _ value: Value
    ) throws {
        guard case let .object(fields) = value,
              nonemptyString(fields["projectId"]) != nil,
              stringArray(fields["rootPaths"]) != nil
        else {
            throw Error.invalidResponse
        }
    }

    private static func validateRemoteProjectCreateResponse(
        _ value: Value
    ) throws {
        guard case let .object(fields) = value,
              nonemptyString(fields["id"]) != nil,
              nonemptyString(fields["hostId"]) != nil,
              string(fields["label"]) != nil,
              nonemptyString(fields["remotePath"]) != nil
        else {
            throw Error.invalidResponse
        }
    }

    private static func validateChatGptProjectSyncResponse(
        _ value: Value
    ) throws {
        guard case let .object(fields) = value,
              let rootPath = nonemptyString(fields["rootPath"]),
              !rootPath.isEmpty,
              case let .array(failures)? = fields["failedFiles"]
        else {
            throw Error.invalidResponse
        }
        for failure in failures {
            guard case let .object(fields) = failure,
                  case let .integer(fileOrdinal)? =
                      fields["fileOrdinal"],
                  fileOrdinal > 0,
                  let stage = string(fields["stage"]),
                  [
                      "download-link",
                      "download",
                      "filesystem",
                  ].contains(stage)
            else {
                throw Error.invalidResponse
            }
            if let rawStatus = fields["status"] {
                guard case let .integer(status) = rawStatus,
                      (100 ... 599).contains(status)
                else {
                    throw Error.invalidResponse
                }
            }
        }
    }

    private static func argumentObject(
        _ arguments: [Value]?
    ) throws -> [String: Value] {
        guard case let .object(fields)? = arguments?.first else {
            throw Error.invalidArguments
        }
        return fields
    }

    private static let projectAppearanceColors: Set<String> = [
        "black",
        "blue",
        "green",
        "orange",
        "pink",
        "purple",
        "red",
        "yellow",
    ]

    private static let projectAppearanceIcons: Set<String> = [
        "folder",
        "currency-dollar",
        "book",
        "graduation-cap",
        "edit",
        "writing",
        "function",
        "terminal",
        "music",
        "popcorn",
        "customize",
        "palette",
        "stethoscope",
        "health",
        "lotus",
        "suitcase",
        "bar-chart",
        "kettlebell",
        "dumbbell",
        "logs",
        "scale",
        "desk-globe",
        "plane",
        "globe",
        "wrench",
        "paw",
        "flask",
        "brain",
        "heart",
        "plant",
    ]

    private static let projectAppearanceIconAliases: [String: String] = [
        "balancing-scale": "scale",
        "building": "folder",
        "bug": "folder",
        "cat": "paw",
        "code": "function",
        "code-brackets": "function",
        "cube": "folder",
        "gift": "folder",
        "globe-spin": "desk-globe",
        "graduation": "graduation-cap",
        "lightbulb": "brain",
        "lightning": "folder",
        "lite": "lotus",
        "network": "brain",
        "notebook": "logs",
        "openai": "folder",
        "pencil": "edit",
        "pens": "customize",
        "pointer": "folder",
        "presentation": "bar-chart",
        "puzzle": "customize",
        "search": "globe",
        "star": "folder",
        "target": "folder",
        "waveform": "music",
    ]

    private static func normalizedProjectAppearance(
        _ value: Value
    ) -> Value? {
        guard case let .object(fields) = value else {
            return value == .null ? .null : nil
        }
        guard case let .string(color)? = fields["color"],
              projectAppearanceColors.contains(color),
              case let .object(markerFields)? = fields["marker"],
              case let .string(kind)? = markerFields["kind"]
        else {
            return nil
        }

        switch kind {
        case "emoji":
            guard case let .string(emoji)? = markerFields["emoji"],
                  !emoji.isEmpty
            else {
                return nil
            }
            return .object([
                "color": .string(color),
                "marker": .object([
                    "kind": .string("emoji"),
                    "emoji": .string(emoji),
                ]),
            ])

        case "icon":
            guard case let .string(icon)? = markerFields["icon"] else {
                return nil
            }
            let normalizedIcon =
                projectAppearanceIconAliases[icon] ?? icon
            guard projectAppearanceIcons.contains(normalizedIcon) else {
                return nil
            }
            return .object([
                "color": .string(color),
                "marker": .object([
                    "kind": .string("icon"),
                    "icon": .string(normalizedIcon),
                ]),
            ])

        default:
            return nil
        }
    }

    private static func isRPCTarget(_ value: Value) -> Bool {
        switch value {
        case .rpcObject, .export, .import:
            true
        default:
            false
        }
    }

    private static func isValidChatGptProjectID(
        _ value: String
    ) -> Bool {
        guard !value.isEmpty,
              value != ".",
              value != "..",
              value.lowercased() != ".metadata"
        else {
            return false
        }
        return value.range(
            of: #"^[A-Za-z0-9._-]+$"#,
            options: .regularExpression
        ) != nil
    }

    private static func string(_ value: Value?) -> String? {
        guard case let .string(string)? = value else {
            return nil
        }
        return string
    }

    private static func nonemptyString(
        _ value: Value?
    ) -> String? {
        guard let value = string(value),
              !value.trimmingCharacters(
                  in: .whitespacesAndNewlines
              ).isEmpty
        else {
            return nil
        }
        return value
    }

    private static func stringArray(
        _ value: Value?
    ) -> [String]? {
        guard case let .array(values)? = value else {
            return nil
        }
        var strings: [String] = []
        strings.reserveCapacity(values.count)
        for value in values {
            guard case let .string(string) = value else {
                return nil
            }
            strings.append(string)
        }
        return strings
    }

    private static func copyOptionalString(
        _ key: String,
        from fields: [String: Value],
        to normalized: inout [String: Value]
    ) throws {
        guard let rawValue = fields[key] else {
            return
        }
        guard case let .string(value) = rawValue else {
            throw Error.invalidArguments
        }
        normalized[key] = .string(value)
    }
}
