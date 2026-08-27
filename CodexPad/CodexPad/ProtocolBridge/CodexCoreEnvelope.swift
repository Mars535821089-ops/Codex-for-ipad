#if SWIFT_PACKAGE
import CodexPadDomain
#endif
import Foundation

public enum CodexCoreEventDecodeDiagnostic {
    @discardableResult
    public static func record(
        data: Data,
        error: any Error,
        userDefaults: UserDefaults = .standard
    ) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data)
            as? [String: Any]
        else {
            let diagnostic =
                "event=invalid-json errorType=\(String(describing: type(of: error)))"
            userDefaults.set(
                diagnostic,
                forKey: "codex.desktop.last-core-event-decode-failure"
            )
            return diagnostic
        }
        let kind = object["kind"] as? String ?? "missing"
        let keys = object.keys.sorted().joined(separator: ",")
        var details = "event=\(kind) keys=\(keys) errorType=\(String(describing: type(of: error)))"
        if kind == "threadSettingsUpdated",
           let settings = object["threadSettings"] as? [String: Any]
        {
            details += " settings=" + settings.keys.sorted().joined(separator: ",")
            if let cwd = settings["cwd"] as? String {
                details += " cwd=" + ((cwd as NSString).isAbsolutePath ? "absolute" : "relative")
            }
            for key in [
                "approvalPolicy", "approvalsReviewer", "modelProvider",
                "effort", "collaborationMode", "sandboxPolicy",
            ] where settings[key] != nil {
                details += " \(key)=present"
            }
        }
        userDefaults.set(
            details,
            forKey: "codex.desktop.last-core-event-decode-failure"
        )
        return details
    }
}

/// Privacy-preserving shape capture for a `turn/start` request rejected by
/// the embedded core. It never records prompt text, paths, credentials, or
/// metadata values.
public enum CodexTurnStartInvalidArgumentDiagnostic {
    @discardableResult
    public static func record(
        requestData: Data,
        userDefaults: UserDefaults = .standard
    ) -> String? {
        guard let request = try? JSONSerialization.jsonObject(
            with: requestData
        ) as? [String: Any],
        request["method"] as? String == "turn/start",
        let params = request["params"] as? [String: Any]
        else {
            return nil
        }

        func shape(_ value: Any?) -> String {
            switch value {
            case nil: "omitted"
            case is NSNull: "null"
            case is String: "string"
            case is Bool: "bool"
            case is [Any]: "array"
            case is [String: Any]: "object"
            case is NSNumber: "number"
            default: "other"
            }
        }

        var diagnostic = "turn/start transport invalidArgument"
        diagnostic += " inputCount=" + String(
            (params["input"] as? [Any])?.count ?? -1
        )
        for key in ["cwd", "model", "effort", "permissions"] {
            diagnostic += " \(key)=\(shape(params[key]))"
        }
        if let sandbox = params["sandboxPolicy"] as? [String: Any] {
            diagnostic += " sandboxType=\(shape(sandbox["type"]))"
            diagnostic += " workspaceWriteRoots=" + String(
                (sandbox["writableRoots"] as? [Any])?.count ?? -1
            )
            let allAbsolute = (sandbox["writableRoots"] as? [String])?
                .allSatisfy { ($0 as NSString).isAbsolutePath }
            if let allAbsolute {
                diagnostic += " workspaceWriteRootsAbsolute=\(allAbsolute)"
            }
        } else {
            diagnostic += " sandboxPolicy=\(shape(params["sandboxPolicy"]))"
        }
        if let collaboration = params["collaborationMode"] as? [String: Any],
           let settings = collaboration["settings"] as? [String: Any]
        {
            diagnostic += " collaborationMode=object"
            diagnostic += " collaborationSettings=" + settings.keys.sorted().map {
                "\($0):\(shape(settings[$0]))"
            }.joined(separator: ",")
        } else {
            diagnostic += " collaborationMode=\(shape(params["collaborationMode"]))"
        }
        userDefaults.set(
            diagnostic,
            forKey: "codex.desktop.last-turn-start-invalid-argument"
        )
        return diagnostic
    }
}

public enum CodexCoreEnvelopeError: Error, Equatable, Sendable {
    case emptyRequestID
    case emptyText
    case invalidCommandPayload
    case invalidSequence
    case invalidEventPayload
    case unsupportedEventKind
}

public struct CodexOfficialToolSearchSource:
    Encodable,
    Equatable,
    Sendable
{
    public let name: String
    public let description: String?

    public init(
        name: String,
        description: String? = nil
    ) {
        self.name = name
        self.description = description
    }
}

public struct CodexOfficialResponseRequest: Encodable, Equatable, Sendable {
    public let requestID: String
    public let accessToken: String
    public let accountID: String?
    public let baseURL: String?
    public let proxyURL: String?
    public let model: String
    public let reasoningEffort: String
    public let instructions: String
    public let collaborationInstructions: String?
    public let outputSchema: CodexJSONValue?
    public let input: [CodexStoredUserInput]
    public let workspaceTools: Bool
    public let requestUserInputTool: Bool
    public let requestPermissionsTool: Bool
    public let updatePlanTool: Bool
    public let viewImageTool: Bool
    public let mcpResourceTools: Bool
    public let planMode: Bool
    public let toolSearchSources: [CodexOfficialToolSearchSource]
    public let dynamicTools: [CodexJSONValue]
    public let priorInputItems: [String]
    public let inputHistory: [String]

    public init(
        requestID: String,
        accessToken: String,
        accountID: String?,
        baseURL: String? = nil,
        proxyURL: String? = nil,
        model: String,
        reasoningEffort: CodexReasoningEffort = .medium,
        instructions: String,
        collaborationInstructions: String? = nil,
        outputSchema: CodexJSONValue? = nil,
        input: [CodexStoredUserInput],
        workspaceTools: Bool = false,
        requestUserInputTool: Bool = false,
        requestPermissionsTool: Bool = false,
        updatePlanTool: Bool = false,
        viewImageTool: Bool = false,
        mcpResourceTools: Bool = false,
        planMode: Bool = false,
        toolSearchSources: [CodexOfficialToolSearchSource] = [],
        dynamicTools: [CodexJSONValue] = [],
        priorInputItems: [String] = [],
        inputHistory: [String] = []
    ) {
        self.init(
            requestID: requestID,
            accessToken: accessToken,
            accountID: accountID,
            baseURL: baseURL,
            proxyURL: proxyURL,
            model: model,
            reasoningEffortRaw: reasoningEffort.rawValue,
            instructions: instructions,
            collaborationInstructions: collaborationInstructions,
            outputSchema: outputSchema,
            input: input,
            workspaceTools: workspaceTools,
            requestUserInputTool: requestUserInputTool,
            requestPermissionsTool: requestPermissionsTool,
            updatePlanTool: updatePlanTool,
            viewImageTool: viewImageTool,
            mcpResourceTools: mcpResourceTools,
            planMode: planMode,
            toolSearchSources: toolSearchSources,
            dynamicTools: dynamicTools,
            priorInputItems: priorInputItems,
            inputHistory: inputHistory
        )
    }

    public init(
        requestID: String,
        accessToken: String,
        accountID: String?,
        baseURL: String? = nil,
        proxyURL: String? = nil,
        model: String,
        reasoningEffort: String,
        instructions: String,
        collaborationInstructions: String? = nil,
        outputSchema: CodexJSONValue? = nil,
        input: [CodexStoredUserInput],
        workspaceTools: Bool = false,
        requestUserInputTool: Bool = false,
        requestPermissionsTool: Bool = false,
        updatePlanTool: Bool = false,
        viewImageTool: Bool = false,
        mcpResourceTools: Bool = false,
        planMode: Bool = false,
        toolSearchSources: [CodexOfficialToolSearchSource] = [],
        dynamicTools: [CodexJSONValue] = [],
        priorInputItems: [String] = [],
        inputHistory: [String] = []
    ) {
        self.init(
            requestID: requestID,
            accessToken: accessToken,
            accountID: accountID,
            baseURL: baseURL,
            proxyURL: proxyURL,
            model: model,
            reasoningEffortRaw: reasoningEffort,
            instructions: instructions,
            collaborationInstructions: collaborationInstructions,
            outputSchema: outputSchema,
            input: input,
            workspaceTools: workspaceTools,
            requestUserInputTool: requestUserInputTool,
            requestPermissionsTool: requestPermissionsTool,
            updatePlanTool: updatePlanTool,
            viewImageTool: viewImageTool,
            mcpResourceTools: mcpResourceTools,
            planMode: planMode,
            toolSearchSources: toolSearchSources,
            dynamicTools: dynamicTools,
            priorInputItems: priorInputItems,
            inputHistory: inputHistory
        )
    }

    private init(
        requestID: String,
        accessToken: String,
        accountID: String?,
        baseURL: String?,
        proxyURL: String?,
        model: String,
        reasoningEffortRaw: String,
        instructions: String,
        collaborationInstructions: String?,
        outputSchema: CodexJSONValue?,
        input: [CodexStoredUserInput],
        workspaceTools: Bool,
        requestUserInputTool: Bool,
        requestPermissionsTool: Bool,
        updatePlanTool: Bool,
        viewImageTool: Bool,
        mcpResourceTools: Bool,
        planMode: Bool,
        toolSearchSources: [CodexOfficialToolSearchSource],
        dynamicTools: [CodexJSONValue],
        priorInputItems: [String],
        inputHistory: [String]
    ) {
        self.requestID = requestID
        self.accessToken = accessToken
        self.accountID = accountID
        self.baseURL = baseURL
        self.proxyURL = proxyURL
        self.model = model
        reasoningEffort = reasoningEffortRaw
        self.instructions = instructions
        self.collaborationInstructions = collaborationInstructions
        self.outputSchema = outputSchema
        self.input = input
        self.workspaceTools = workspaceTools
        self.requestUserInputTool = requestUserInputTool
        self.requestPermissionsTool = requestPermissionsTool
        self.updatePlanTool = updatePlanTool
        self.viewImageTool = viewImageTool
        self.mcpResourceTools = mcpResourceTools
        self.planMode = planMode
        self.toolSearchSources = toolSearchSources
        self.dynamicTools = dynamicTools
        self.priorInputItems = priorInputItems
        self.inputHistory = inputHistory
    }

    public func encodedData() throws -> Data {
        guard !requestID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !accessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !input.isEmpty,
              input.contains(where: Self.hasUsableContent),
              accountID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != true
        else {
            throw CodexCoreEnvelopeError.invalidCommandPayload
        }
        if let baseURL {
            guard baseURL.hasPrefix("https://"), !baseURL.hasSuffix("/") else {
                throw CodexCoreEnvelopeError.invalidCommandPayload
            }
        }
        if let proxyURL {
            guard Self.isValidProxyURL(proxyURL) else {
                throw CodexCoreEnvelopeError.invalidCommandPayload
            }
        }
        let encoded = try JSONEncoder().encode(self)
        // The ChatGPT OAuth route currently rejects the desktop catalog's
        // gpt-5.6 aliases. Keep the renderer and persisted thread identity
        // unchanged, but enforce the account-compatible provider model at the
        // final wire boundary so no caller can bypass normalization.
        guard baseURL == nil,
              model == "gpt-5-6" || model == "gpt-5.6-sol",
              var object = try JSONSerialization.jsonObject(
                with: encoded
              ) as? [String: Any]
        else {
            return encoded
        }
        object["model"] = "gpt-5.5"
        return try JSONSerialization.data(withJSONObject: object)
    }

    public func withProxyURL(_ proxyURL: String?) -> Self {
        Self(
            requestID: requestID,
            accessToken: accessToken,
            accountID: accountID,
            baseURL: baseURL,
            proxyURL: proxyURL,
            model: model,
            reasoningEffortRaw: reasoningEffort,
            instructions: instructions,
            collaborationInstructions: collaborationInstructions,
            outputSchema: outputSchema,
            input: input,
            workspaceTools: workspaceTools,
            requestUserInputTool: requestUserInputTool,
            requestPermissionsTool: requestPermissionsTool,
            updatePlanTool: updatePlanTool,
            viewImageTool: viewImageTool,
            mcpResourceTools: mcpResourceTools,
            planMode: planMode,
            toolSearchSources: toolSearchSources,
            dynamicTools: dynamicTools,
            priorInputItems: priorInputItems,
            inputHistory: inputHistory
        )
    }

    private static func isValidProxyURL(_ value: String) -> Bool {
        guard let components = URLComponents(string: value),
              components.scheme == "http" || components.scheme == "https",
              components.host?.isEmpty == false,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              components.path.isEmpty || components.path == "/"
        else {
            return false
        }
        return true
    }

    private static func hasUsableContent(
        _ input: CodexStoredUserInput
    ) -> Bool {
        switch input {
        case let .text(text, _):
            return !text.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).isEmpty
        case let .image(_, url), let .audio(url):
            return !url.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).isEmpty
        case let .localImage(_, path),
             let .localAudio(path):
            return !path.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).isEmpty
        case let .skill(name, path),
             let .mention(name, path):
            return !name.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).isEmpty
                && !path.trimmingCharacters(
                    in: .whitespacesAndNewlines
                ).isEmpty
        }
    }

    private enum CodingKeys: String, CodingKey {
        case requestID = "requestId"
        case accessToken
        case accountID = "accountId"
        case baseURL = "baseUrl"
        case proxyURL = "proxyUrl"
        case model
        case reasoningEffort
        case instructions
        case collaborationInstructions
        case outputSchema
        case input
        case workspaceTools
        case requestUserInputTool
        case requestPermissionsTool
        case updatePlanTool
        case viewImageTool
        case mcpResourceTools
        case planMode
        case toolSearchSources
        case dynamicTools
        case priorInputItems
        case inputHistory
    }
}

public enum CodexCoreCommand: Equatable, Sendable {
    case ping(requestID: String)
    case openStorage(databasePath: String, snapshotDirectory: String)
    case confirmStorage
    case restoreStorage(
        databasePath: String,
        snapshotDirectory: String,
        snapshotName: String
    )
    case openWorkspace(Workspace)
    case updateWorkspace(Workspace)
    case removeWorkspace(UUID)
    case startThread(
        CodexThread,
        metadata: CodexThreadCreateMetadata
    )
    case setThreadName(threadID: UUID, name: String)
    case archiveThread(threadID: UUID)
    case unarchiveThread(threadID: UUID)
    case deleteThread(threadID: UUID)
    case forkThread(
        threadID: UUID,
        newThreadID: UUID,
        title: String,
        lastTurnID: UUID?,
        turnIDMap: [UUID: UUID],
        itemIDMap: [UUID: UUID],
        timestamp: Int64
    )
    case setThreadGoal(ThreadGoal)
    case clearThreadGoal(threadID: UUID)
    case updateThreadSettings(ThreadSettings)
    case startTurn(Turn, userItem: ThreadItem, timestamp: Int64)
    case appendItem(ThreadItem)
    case completeTurn(
        turnID: UUID,
        assistantItem: ThreadItem,
        timestamp: Int64
    )
    case failTurn(
        turnID: UUID,
        errorItem: ThreadItem,
        timestamp: Int64
    )
    case cancelTurn(turnID: UUID, timestamp: Int64)
    case completeShellCommand(
        commandID: String,
        exitCode: Int64,
        durationMillis: UInt64,
        stdout: String,
        stderr: String
    )

    public func encodedData() throws -> Data {
        switch self {
        case let .ping(requestID):
            guard !requestID.isEmpty else {
                throw CodexCoreEnvelopeError.emptyRequestID
            }
            let encodedRequestID = try JSONEncoder().encode(requestID)
            var data = Data(#"{"kind":"ping","requestId":"#.utf8)
            data.append(encodedRequestID)
            data.append(Data("}".utf8))
            return data

        case let .openStorage(databasePath, snapshotDirectory):
            try requireAbsolutePath(databasePath)
            try requireAbsolutePath(snapshotDirectory)
            return try encode(
                StorageOpenCommand(
                    kind: "storage.open",
                    databasePath: databasePath,
                    snapshotDirectory: snapshotDirectory
                )
            )

        case .confirmStorage:
            return Data(#"{"kind":"storage.confirm"}"#.utf8)

        case let .restoreStorage(
            databasePath,
            snapshotDirectory,
            snapshotName
        ):
            try requireAbsolutePath(databasePath)
            try requireAbsolutePath(snapshotDirectory)
            guard snapshotName == (snapshotName as NSString).lastPathComponent,
                  (snapshotName as NSString).pathExtension == "sqlite"
            else {
                throw CodexCoreEnvelopeError.invalidCommandPayload
            }
            return try encode(
                StorageRestoreCommand(
                    kind: "storage.restore",
                    databasePath: databasePath,
                    snapshotDirectory: snapshotDirectory,
                    snapshotName: snapshotName
                )
            )

        case let .openWorkspace(workspace):
            try requireText(workspace.displayName)
            return try encode(
                WorkspaceOpenCommand(
                    kind: "workspace.open",
                    workspace: WorkspaceWire(workspace)
                )
            )

        case let .updateWorkspace(workspace):
            try requireText(workspace.displayName)
            return try encode(
                WorkspaceOpenCommand(
                    kind: "workspace.update",
                    workspace: WorkspaceWire(workspace)
                )
            )

        case let .removeWorkspace(workspaceID):
            return try encode(
                WorkspaceIDCommand(
                    kind: "workspace.remove",
                    workspaceID: workspaceID.uuidString.lowercased()
                )
            )

        case let .startThread(thread, metadata):
            try requireText(thread.title)
            try validateThreadCreateMetadata(metadata)
            return try encode(
                ThreadStartCommand(
                    kind: "thread.start",
                    thread: ThreadWire(thread),
                    metadata: metadata
                )
            )

        case let .setThreadName(threadID, name):
            try requireText(name)
            return try encode(
                ThreadSetNameCommand(
                    kind: "thread.set-name",
                    threadID: threadID.uuidString.lowercased(),
                    name: name.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            )

        case let .archiveThread(threadID):
            return try encode(
                ThreadIDCommand(
                    kind: "thread.archive",
                    threadID: threadID.uuidString.lowercased()
                )
            )

        case let .unarchiveThread(threadID):
            return try encode(
                ThreadIDCommand(
                    kind: "thread.unarchive",
                    threadID: threadID.uuidString.lowercased()
                )
            )

        case let .deleteThread(threadID):
            return try encode(
                ThreadIDCommand(
                    kind: "thread.delete",
                    threadID: threadID.uuidString.lowercased()
                )
            )

        case let .forkThread(
            threadID,
            newThreadID,
            title,
            lastTurnID,
            turnIDMap,
            itemIDMap,
            timestamp
        ):
            try requireText(title)
            try requireTimestamp(timestamp)
            return try encode(
                ThreadForkCommand(
                    kind: "thread.fork",
                    threadID: threadID.uuidString.lowercased(),
                    newThreadID: newThreadID.uuidString.lowercased(),
                    title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                    lastTurnID: lastTurnID?.uuidString.lowercased(),
                    turnIDMap: Dictionary(
                        uniqueKeysWithValues: turnIDMap.map {
                            (
                                $0.key.uuidString.lowercased(),
                                $0.value.uuidString.lowercased()
                            )
                        }
                    ),
                    itemIDMap: Dictionary(
                        uniqueKeysWithValues: itemIDMap.map {
                            (
                                $0.key.uuidString.lowercased(),
                                $0.value.uuidString.lowercased()
                            )
                        }
                    ),
                    timestamp: timestamp
                )
            )

        case let .setThreadGoal(goal):
            try requireText(goal.objective)
            guard goal.tokenBudget.map({ $0 > 0 }) ?? true,
                  goal.tokensUsed >= 0,
                  goal.timeUsedSeconds >= 0,
                  goal.createdAt >= 0,
                  goal.updatedAt >= goal.createdAt
            else {
                throw CodexCoreEnvelopeError.invalidCommandPayload
            }
            return try encode(
                ThreadGoalSetCommand(
                    kind: "thread.goal.set",
                    threadID: goal.threadID.uuidString.lowercased(),
                    objective: goal.objective,
                    status: goal.status.rawValue,
                    tokenBudget: goal.tokenBudget
                )
            )

        case let .clearThreadGoal(threadID):
            return try encode(
                ThreadIDCommand(
                    kind: "thread.goal.clear",
                    threadID: threadID.uuidString.lowercased()
                )
            )

        case let .updateThreadSettings(settings):
            try requireAbsolutePath(settings.cwd)
            try requireText(settings.model)
            return try encode(
                ThreadSettingsUpdateCommand(
                    kind: "thread.settings-update",
                    threadID: settings.threadID.uuidString.lowercased(),
                    cwd: settings.cwd,
                    model: settings.model,
                    effort: settings.effort?.rawValue,
                    approvalPolicy: settings.approvalPolicy.rawValue,
                    sandboxPolicy: SandboxPolicyWire(settings.sandboxPolicy)
                )
            )

        case let .startTurn(turn, userItem, timestamp):
            try requireText(userItem.text)
            try requireTimestamp(timestamp)
            guard turn.status == .running,
                  userItem.kind == .userMessage,
                  turn.id == userItem.turnID,
                  turn.threadID == userItem.threadID
            else {
                throw CodexCoreEnvelopeError.invalidCommandPayload
            }
            return try encode(
                TurnStartCommand(
                    kind: "turn.start",
                    turn: TurnWire(turn),
                    userItem: ThreadItemWire(userItem),
                    timestamp: timestamp
                )
            )

        case let .appendItem(item):
            try requireText(item.text)
            guard [
                ThreadItemKind.reasoning,
                .toolCall,
                .toolResult,
                .approval,
                .fileChange,
                .terminal,
            ].contains(item.kind) else {
                throw CodexCoreEnvelopeError.invalidCommandPayload
            }
            return try encode(
                ItemAppendCommand(
                    kind: "item.append",
                    item: ThreadItemWire(item)
                )
            )

        case let .completeTurn(turnID, assistantItem, timestamp):
            try requireText(assistantItem.text)
            try requireTimestamp(timestamp)
            guard assistantItem.kind == .assistantMessage,
                  turnID == assistantItem.turnID
            else {
                throw CodexCoreEnvelopeError.invalidCommandPayload
            }
            return try encode(
                TurnCompleteCommand(
                    kind: "turn.complete",
                    turnID: turnID.uuidString.lowercased(),
                    assistantItem: ThreadItemWire(assistantItem),
                    timestamp: timestamp
                )
            )

        case let .failTurn(turnID, errorItem, timestamp):
            try requireText(errorItem.text)
            try requireTimestamp(timestamp)
            guard errorItem.kind == .error,
                  turnID == errorItem.turnID
            else {
                throw CodexCoreEnvelopeError.invalidCommandPayload
            }
            return try encode(
                TurnFailCommand(
                    kind: "turn.fail",
                    turnID: turnID.uuidString.lowercased(),
                    errorItem: ThreadItemWire(errorItem),
                    timestamp: timestamp
                )
            )

        case let .cancelTurn(turnID, timestamp):
            try requireTimestamp(timestamp)
            return try encode(
                TurnCancelCommand(
                    kind: "turn.cancel",
                    turnID: turnID.uuidString.lowercased(),
                    timestamp: timestamp
                )
            )

        case let .completeShellCommand(
            commandID,
            exitCode,
            durationMillis,
            stdout,
            stderr
        ):
            guard !commandID.isEmpty else {
                throw CodexCoreEnvelopeError.invalidCommandPayload
            }
            return try encode(
                ShellCommandCompleteCommand(
                    kind: "thread.shell-command.complete",
                    commandID: commandID,
                    exitCode: exitCode,
                    durationMillis: durationMillis,
                    stdout: stdout,
                    stderr: stderr
                )
            )
        }
    }
}

private struct StorageOpenCommand: Encodable {
    let kind: String
    let databasePath: String
    let snapshotDirectory: String
}

private struct StorageRestoreCommand: Encodable {
    let kind: String
    let databasePath: String
    let snapshotDirectory: String
    let snapshotName: String
}

private struct TurnFailCommand: Encodable {
    let kind: String
    let turnID: String
    let errorItem: ThreadItemWire
    let timestamp: Int64

    private enum CodingKeys: String, CodingKey {
        case kind
        case turnID = "turnId"
        case errorItem
        case timestamp
    }
}

private struct TurnCancelCommand: Encodable {
    let kind: String
    let turnID: String
    let timestamp: Int64

    private enum CodingKeys: String, CodingKey {
        case kind
        case turnID = "turnId"
        case timestamp
    }
}

private struct ItemAppendCommand: Encodable {
    let kind: String
    let item: ThreadItemWire
}

private struct ShellCommandCompleteCommand: Encodable {
    let kind: String
    let commandID: String
    let exitCode: Int64
    let durationMillis: UInt64
    let stdout: String
    let stderr: String

    private enum CodingKeys: String, CodingKey {
        case kind
        case commandID = "commandId"
        case exitCode
        case durationMillis
        case stdout
        case stderr
    }
}

public struct CodexShellCommandStartedEvent:
    Codable,
    Equatable,
    Sendable
{
    public let sequence: UInt64
    public let commandID: String
    public let threadID: CodexStoredThreadID
    public let turnID: String
    public let command: String
    public let cwd: String
    public let standaloneTurn: Bool

    private enum CodingKeys: String, CodingKey {
        case sequence
        case commandID = "commandId"
        case threadID = "threadId"
        case turnID = "turnId"
        case command
        case cwd
        case standaloneTurn
    }
}

public struct CodexShellCommandCompletedEvent:
    Codable,
    Equatable,
    Sendable
{
    public let sequence: UInt64
    public let commandID: String
    public let threadID: CodexStoredThreadID
    public let turnID: String
    public let command: String
    public let cwd: String
    public let exitCode: Int64
    public let durationMillis: UInt64
    public let stdout: String
    public let stderr: String
    public let standaloneTurn: Bool

    private enum CodingKeys: String, CodingKey {
        case sequence
        case commandID = "commandId"
        case threadID = "threadId"
        case turnID = "turnId"
        case command
        case cwd
        case exitCode
        case durationMillis
        case stdout
        case stderr
        case standaloneTurn
    }
}

public enum CodexCoreProviderEvent: Equatable, Sendable {
    case responseStarted(
        sequence: UInt64,
        requestID: String,
        sourceCommit: String
    )
    case assistantTextDelta(
        sequence: UInt64,
        requestID: String,
        delta: String
    )
    case planStarted(
        sequence: UInt64,
        requestID: String,
        itemID: String
    )
    case planDelta(
        sequence: UInt64,
        requestID: String,
        itemID: String,
        delta: String
    )
    case planCompleted(
        sequence: UInt64,
        requestID: String,
        itemID: String,
        text: String
    )
    case toolCallRequested(
        sequence: UInt64,
        requestID: String,
        name: String,
        arguments: String,
        callID: String,
        itemJSON: String
    )
    case responseItemDone(
        sequence: UInt64,
        requestID: String,
        itemJSON: String
    )
    case realtime(
        sequence: UInt64,
        requestID: String,
        eventType: String,
        payload: CodexJSONValue
    )
    case responseCompleted(
        sequence: UInt64,
        requestID: String,
        responseID: String,
        usage: CodexTokenUsageBreakdown?,
        endTurn: Bool?
    )
}

public enum CodexCoreEvent: Equatable, Sendable {
    case pong(sequence: UInt64, requestID: String)
    case stableTurnStarted(CodexStableTurnStartedEvent)
    case stableCompactStarted(CodexStableCompactStartedEvent)
    case compactionCommitted(CodexCompactionCommittedEvent)
    case rawHistoryCommitted(CodexRawHistoryCommittedEvent)
    case shellCommandStarted(CodexShellCommandStartedEvent)
    case shellCommandCompleted(CodexShellCommandCompletedEvent)
    case threadItemsInjected(
        sequence: UInt64,
        threadID: CodexStoredThreadID,
        afterTurnID: String?,
        items: [String]
    )
    case threadSettingsUpdated(CodexThreadSettingsUpdatedNotification)
    case appServerNotification(CodexAppServerNotification)
    case threadMemoryModeUpdated(
        sequence: UInt64,
        threadID: CodexStoredThreadID,
        mode: CodexThreadMemoryMode
    )
    case threadQueueChanged(
        sequence: UInt64,
        threadID: CodexStoredThreadID,
        queuedSubmissions: [CodexQueuedSubmission]
    )
    case domain(DomainEvent)
    case provider(CodexCoreProviderEvent)

    public var sequence: UInt64? {
        switch self {
        case let .pong(sequence, _),
             let .threadItemsInjected(sequence, _, _, _),
             let .threadMemoryModeUpdated(sequence, _, _),
             let .threadQueueChanged(sequence, _, _):
            return sequence
        case let .stableTurnStarted(event):
            return event.sequence
        case let .stableCompactStarted(event):
            return event.sequence
        case let .compactionCommitted(event):
            return event.sequence
        case let .rawHistoryCommitted(event):
            return event.sequence
        case let .shellCommandStarted(event):
            return event.sequence
        case let .shellCommandCompleted(event):
            return event.sequence
        case let .domain(event):
            return UInt64(event.sequence)
        case let .provider(event):
            switch event {
            case let .responseStarted(sequence, _, _),
                 let .assistantTextDelta(sequence, _, _),
                 let .planStarted(sequence, _, _),
                 let .planDelta(sequence, _, _, _),
                 let .planCompleted(sequence, _, _, _),
                 let .toolCallRequested(sequence, _, _, _, _, _),
                 let .responseItemDone(sequence, _, _),
                 let .realtime(sequence, _, _, _),
                 let .responseCompleted(sequence, _, _, _, _):
                return sequence
            }
        case .threadSettingsUpdated, .appServerNotification:
            return nil
        }
    }

    public init(data: Data) throws {
        let decoder = JSONDecoder()
        if let notificationHeader = try? decoder.decode(
            AppServerNotificationHeader.self,
            from: data
        ), notificationHeader.method == "thread/settings/updated" {
            let envelope: ThreadSettingsUpdatedNotificationEnvelope
            do {
                envelope = try decoder.decode(
                    ThreadSettingsUpdatedNotificationEnvelope.self,
                    from: data
                )
            } catch {
                throw CodexCoreEnvelopeError.invalidEventPayload
            }
            guard !envelope.params.threadID.rawValue.isEmpty else {
                throw CodexCoreEnvelopeError.invalidEventPayload
            }
            self = .threadSettingsUpdated(envelope.params)
            return
        }
        if let notification = try? CodexAppServerNotification(data: data) {
            self = .appServerNotification(notification)
            return
        }
        let header: EventHeader
        do {
            header = try decoder.decode(EventHeader.self, from: data)
        } catch {
            throw CodexCoreEnvelopeError.invalidEventPayload
        }
        guard header.sequence > 0, header.sequence <= UInt64(Int64.max) else {
            throw CodexCoreEnvelopeError.invalidSequence
        }

        if header.kind == "pong" {
            let event: PongEvent = try decodeEvent(data, using: decoder)
            guard !event.requestID.isEmpty else {
                throw CodexCoreEnvelopeError.invalidEventPayload
            }
            self = .pong(
                sequence: header.sequence,
                requestID: event.requestID
            )
            return
        }

        let sequence = Int64(header.sequence)
        switch header.kind {
        case "stableTurnStarted":
            let event: CodexStableTurnStartedEvent = try decodeEvent(
                data,
                using: decoder
            )
            guard !event.threadID.rawValue.isEmpty,
                  !event.turnID.isEmpty,
                  !event.userItemID.isEmpty
            else {
                throw CodexCoreEnvelopeError.invalidEventPayload
            }
            self = .stableTurnStarted(event)

        case "stableCompactStarted":
            let event: CodexStableCompactStartedEvent = try decodeEvent(
                data,
                using: decoder
            )
            guard !event.threadID.rawValue.isEmpty,
                  !event.turnID.isEmpty,
                  !event.itemID.isEmpty
            else {
                throw CodexCoreEnvelopeError.invalidEventPayload
            }
            self = .stableCompactStarted(event)

        case "turnCompactionCommitted":
            let event: CodexCompactionCommittedEvent = try decodeEvent(
                data,
                using: decoder
            )
            guard !event.threadID.rawValue.isEmpty,
                  !event.turnID.isEmpty,
                  !event.itemID.isEmpty,
                  !event.replacementItems.isEmpty,
                  !event.responseID.isEmpty
            else {
                throw CodexCoreEnvelopeError.invalidEventPayload
            }
            self = .compactionCommitted(event)

        case "turnRawHistoryCommitted":
            let event: CodexRawHistoryCommittedEvent = try decodeEvent(
                data,
                using: decoder
            )
            guard !event.threadID.rawValue.isEmpty,
                  !event.turnID.isEmpty,
                  rawHistoryEntriesAreContiguous(
                      event.entries,
                      startingAt: event.expectedNextOrder
                  ),
                  event.entries.allSatisfy(\.containsJSONObject),
                  event.completion?.responseID
                    .trimmingCharacters(
                        in: .whitespacesAndNewlines
                    ).isEmpty != true
            else {
                throw CodexCoreEnvelopeError.invalidEventPayload
            }
            self = .rawHistoryCommitted(event)

        case "shellCommandStarted":
            let event: CodexShellCommandStartedEvent = try decodeEvent(
                data,
                using: decoder
            )
            guard !event.commandID.isEmpty,
                  !event.threadID.rawValue.isEmpty,
                  !event.turnID.isEmpty,
                  !event.command.trimmingCharacters(
                    in: .whitespacesAndNewlines
                  ).isEmpty,
                  (event.cwd as NSString).isAbsolutePath
            else {
                throw CodexCoreEnvelopeError.invalidEventPayload
            }
            self = .shellCommandStarted(event)

        case "shellCommandCompleted":
            let event: CodexShellCommandCompletedEvent = try decodeEvent(
                data,
                using: decoder
            )
            guard !event.commandID.isEmpty,
                  !event.threadID.rawValue.isEmpty,
                  !event.turnID.isEmpty,
                  !event.command.trimmingCharacters(
                    in: .whitespacesAndNewlines
                  ).isEmpty,
                  (event.cwd as NSString).isAbsolutePath
            else {
                throw CodexCoreEnvelopeError.invalidEventPayload
            }
            self = .shellCommandCompleted(event)

        case "threadItemsInjected":
            let event: ThreadItemsInjectedEvent = try decodeEvent(
                data,
                using: decoder
            )
            guard !event.threadID.rawValue.isEmpty,
                  !event.items.isEmpty,
                  event.items.allSatisfy({
                      guard let data = $0.data(using: .utf8),
                            let object = try? JSONSerialization.jsonObject(
                                with: data
                            )
                      else {
                          return false
                      }
                      return object is [String: Any]
                  })
            else {
                throw CodexCoreEnvelopeError.invalidEventPayload
            }
            self = .threadItemsInjected(
                sequence: header.sequence,
                threadID: event.threadID,
                afterTurnID: event.afterTurnID,
                items: event.items
            )

        case "providerResponseStarted":
            let event: ProviderResponseStartedEvent = try decodeEvent(
                data,
                using: decoder
            )
            guard !event.requestID.isEmpty, !event.sourceCommit.isEmpty else {
                throw CodexCoreEnvelopeError.invalidEventPayload
            }
            self = .provider(
                .responseStarted(
                    sequence: header.sequence,
                    requestID: event.requestID,
                    sourceCommit: event.sourceCommit
                )
            )

        case "assistantTextDelta":
            let event: AssistantTextDeltaEvent = try decodeEvent(
                data,
                using: decoder
            )
            guard !event.requestID.isEmpty else {
                throw CodexCoreEnvelopeError.invalidEventPayload
            }
            self = .provider(
                .assistantTextDelta(
                    sequence: header.sequence,
                    requestID: event.requestID,
                    delta: event.delta
                )
            )

        case "planStarted":
            let event: ProviderPlanStartedEvent = try decodeEvent(
                data,
                using: decoder
            )
            guard !event.requestID.isEmpty, !event.itemID.isEmpty else {
                throw CodexCoreEnvelopeError.invalidEventPayload
            }
            self = .provider(
                .planStarted(
                    sequence: header.sequence,
                    requestID: event.requestID,
                    itemID: event.itemID
                )
            )

        case "planDelta":
            let event: ProviderPlanDeltaEvent = try decodeEvent(
                data,
                using: decoder
            )
            guard !event.requestID.isEmpty, !event.itemID.isEmpty else {
                throw CodexCoreEnvelopeError.invalidEventPayload
            }
            self = .provider(
                .planDelta(
                    sequence: header.sequence,
                    requestID: event.requestID,
                    itemID: event.itemID,
                    delta: event.delta
                )
            )

        case "planCompleted":
            let event: ProviderPlanCompletedEvent = try decodeEvent(
                data,
                using: decoder
            )
            guard !event.requestID.isEmpty, !event.itemID.isEmpty else {
                throw CodexCoreEnvelopeError.invalidEventPayload
            }
            self = .provider(
                .planCompleted(
                    sequence: header.sequence,
                    requestID: event.requestID,
                    itemID: event.itemID,
                    text: event.text
                )
            )

        case "toolCallRequested":
            let event: ToolCallRequestedEvent = try decodeEvent(
                data,
                using: decoder
            )
            guard !event.requestID.isEmpty,
                  !event.name.isEmpty,
                  !event.callID.isEmpty,
                  !event.itemJSON.isEmpty
            else {
                throw CodexCoreEnvelopeError.invalidEventPayload
            }
            self = .provider(
                .toolCallRequested(
                    sequence: header.sequence,
                    requestID: event.requestID,
                    name: event.name,
                    arguments: event.arguments,
                    callID: event.callID,
                    itemJSON: event.itemJSON
                )
            )

        case "providerResponseItemDone":
            let event: ProviderResponseItemDoneEvent = try decodeEvent(
                data,
                using: decoder
            )
            guard !event.requestID.isEmpty, !event.itemJSON.isEmpty else {
                throw CodexCoreEnvelopeError.invalidEventPayload
            }
            self = .provider(
                .responseItemDone(
                    sequence: header.sequence,
                    requestID: event.requestID,
                    itemJSON: event.itemJSON
                )
            )

        case "providerRealtimeEvent":
            let event: ProviderRealtimeEvent = try decodeEvent(
                data,
                using: decoder
            )
            guard !event.requestID.isEmpty, !event.eventType.isEmpty else {
                throw CodexCoreEnvelopeError.invalidEventPayload
            }
            self = .provider(
                .realtime(
                    sequence: header.sequence,
                    requestID: event.requestID,
                    eventType: event.eventType,
                    payload: event.payload
                )
            )

        case "providerResponseCompleted":
            let event: ProviderResponseCompletedEvent = try decodeEvent(
                data,
                using: decoder
            )
            guard !event.requestID.isEmpty, !event.responseID.isEmpty else {
                throw CodexCoreEnvelopeError.invalidEventPayload
            }
            self = .provider(
                .responseCompleted(
                    sequence: header.sequence,
                    requestID: event.requestID,
                    responseID: event.responseID,
                    usage: event.usage,
                    endTurn: event.endTurn
                )
            )

        case "workspaceUpserted":
            let event: WorkspaceEvent = try decodeEvent(data, using: decoder)
            self = .domain(
                DomainEvent(
                    sequence: sequence,
                    payload: .workspaceUpserted(try event.workspace.domain())
                )
            )

        case "workspaceRemoved":
            let event: WorkspaceLifecycleEvent = try decodeEvent(
                data,
                using: decoder
            )
            guard let workspaceID = UUID(uuidString: event.workspaceID) else {
                throw CodexCoreEnvelopeError.invalidEventPayload
            }
            self = .domain(
                DomainEvent(
                    sequence: sequence,
                    payload: .workspaceRemoved(
                        workspaceID: workspaceID
                    )
                )
            )

        case "threadUpserted":
            let event: ThreadEvent = try decodeEvent(data, using: decoder)
            self = .domain(
                DomainEvent(
                    sequence: sequence,
                    payload: .threadUpserted(try event.thread.domain())
                )
            )

        case "threadNameUpdated":
            let event: ThreadNameUpdatedEvent = try decodeEvent(
                data,
                using: decoder
            )
            guard let threadID = UUID(uuidString: event.threadID),
                  !event.name.trimmingCharacters(in: .whitespacesAndNewlines)
                    .isEmpty
            else {
                throw CodexCoreEnvelopeError.invalidEventPayload
            }
            self = .domain(
                DomainEvent(
                    sequence: sequence,
                    payload: .threadNameUpdated(
                        threadID: threadID,
                        name: event.name
                    )
                )
            )

        case "threadArchived", "threadUnarchived", "threadDeleted":
            let event: ThreadLifecycleEvent = try decodeEvent(
                data,
                using: decoder
            )
            guard let threadID = UUID(uuidString: event.threadID) else {
                throw CodexCoreEnvelopeError.invalidEventPayload
            }
            let payload: DomainEvent.Payload
            switch header.kind {
            case "threadArchived":
                payload = .threadArchived(threadID: threadID)
            case "threadUnarchived":
                payload = .threadUnarchived(threadID: threadID)
            default:
                payload = .threadDeleted(threadID: threadID)
            }
            self = .domain(
                DomainEvent(
                    sequence: sequence,
                    payload: payload
                )
            )

        case "threadGoalUpdated":
            let event: ThreadGoalUpdatedEvent = try decodeEvent(
                data,
                using: decoder
            )
            let goal = try event.goal.domain()
            let validTurnID = event.turnID.map {
                UUID(uuidString: $0) != nil
            } ?? true
            guard UUID(uuidString: event.threadID) == goal.threadID,
                  validTurnID else {
                throw CodexCoreEnvelopeError.invalidEventPayload
            }
            self = .domain(
                DomainEvent(
                    sequence: sequence,
                    payload: .threadGoalUpdated(goal)
                )
            )

        case "threadGoalCleared":
            let event: ThreadLifecycleEvent = try decodeEvent(
                data,
                using: decoder
            )
            guard let threadID = UUID(uuidString: event.threadID) else {
                throw CodexCoreEnvelopeError.invalidEventPayload
            }
            self = .domain(
                DomainEvent(
                    sequence: sequence,
                    payload: .threadGoalCleared(threadID: threadID)
                )
            )

        case "threadMetadataChanged":
            let event: ThreadLifecycleEvent = try decodeEvent(
                data,
                using: decoder
            )
            guard !event.threadID.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).isEmpty else {
                throw CodexCoreEnvelopeError.invalidEventPayload
            }
            self = .domain(
                DomainEvent(
                    sequence: sequence,
                    payload: .threadMetadataChanged(
                        threadID: CodexStoredThreadID(event.threadID)
                    )
                )
            )

        case "threadMemoryModeUpdated":
            let event: ThreadMemoryModeUpdatedEvent = try decodeEvent(
                data,
                using: decoder
            )
            guard !event.threadID.isEmpty else {
                throw CodexCoreEnvelopeError.invalidEventPayload
            }
            self = .threadMemoryModeUpdated(
                sequence: header.sequence,
                threadID: CodexStoredThreadID(event.threadID),
                mode: event.mode
            )

        case "threadQueueChanged":
            let event: ThreadQueueChangedEvent = try decodeEvent(
                data,
                using: decoder
            )
            guard !event.threadID.isEmpty else {
                throw CodexCoreEnvelopeError.invalidEventPayload
            }
            self = .threadQueueChanged(
                sequence: header.sequence,
                threadID: CodexStoredThreadID(event.threadID),
                queuedSubmissions: event.queuedSubmissions
            )

        case "threadRolledBack":
            let event: ThreadRolledBackEvent = try decodeEvent(
                data,
                using: decoder
            )
            guard let threadID = UUID(uuidString: event.threadID),
                  !event.removedTurnIDs.isEmpty
            else {
                throw CodexCoreEnvelopeError.invalidEventPayload
            }
            let removedTurnIDs = try event.removedTurnIDs.map {
                guard let turnID = UUID(uuidString: $0) else {
                    throw CodexCoreEnvelopeError.invalidEventPayload
                }
                return turnID
            }
            self = .domain(
                DomainEvent(
                    sequence: sequence,
                    payload: .threadRolledBack(
                        threadID: threadID,
                        removedTurnIDs: removedTurnIDs
                    )
                )
            )

        case "threadReverted":
            let event: ThreadRevertedEvent = try decodeEvent(
                data,
                using: decoder
            )
            guard let threadID = UUID(uuidString: event.threadID),
                  UUID(uuidString: event.beforeTurnID) != nil,
                  !event.removedTurnIDs.isEmpty
            else {
                throw CodexCoreEnvelopeError.invalidEventPayload
            }
            let removedTurnIDs = try event.removedTurnIDs.map {
                guard let turnID = UUID(uuidString: $0) else {
                    throw CodexCoreEnvelopeError.invalidEventPayload
                }
                return turnID
            }
            self = .domain(
                DomainEvent(
                    sequence: sequence,
                    payload: .threadRolledBack(
                        threadID: threadID,
                        removedTurnIDs: removedTurnIDs
                    )
                )
            )

        case "threadSettingsUpdated":
            let event: ThreadSettingsUpdatedEvent = try decodeEvent(
                data,
                using: decoder
            )
            let settings = try event.threadSettings.domain(
                threadID: event.threadID
            )
            self = .domain(
                DomainEvent(
                    sequence: sequence,
                    payload: .threadSettingsUpdated(settings)
                )
            )

        case "turnStarted":
            let event: TurnEvent = try decodeEvent(data, using: decoder)
            self = .domain(
                DomainEvent(
                    sequence: sequence,
                    payload: .turnStarted(try event.turn.domain())
                )
            )

        case "itemAppended":
            let event: ItemEvent = try decodeEvent(data, using: decoder)
            self = .domain(
                DomainEvent(
                    sequence: sequence,
                    payload: .itemAppended(try event.item.domain())
                )
            )

        case "turnStatusChanged":
            let event: TurnStatusEvent = try decodeEvent(
                data,
                using: decoder
            )
            guard let turnID = UUID(uuidString: event.turnID),
                  let status = TurnStatus(rawValue: event.status)
            else {
                throw CodexCoreEnvelopeError.invalidEventPayload
            }
            self = .domain(
                DomainEvent(
                    sequence: sequence,
                    payload: .turnStatusChanged(
                        turnID: turnID,
                        status: status
                    )
                )
            )

        default:
            throw CodexCoreEnvelopeError.unsupportedEventKind
        }
    }
}

private struct WorkspaceOpenCommand: Encodable {
    let kind: String
    let workspace: WorkspaceWire
}

private struct WorkspaceIDCommand: Encodable {
    let kind: String
    let workspaceID: String

    private enum CodingKeys: String, CodingKey {
        case kind
        case workspaceID = "workspaceId"
    }
}

private struct ThreadStartCommand: Encodable {
    let kind: String
    let thread: ThreadWire
    let metadata: CodexThreadCreateMetadata
}

private struct ThreadSetNameCommand: Encodable {
    let kind: String
    let threadID: String
    let name: String

    private enum CodingKeys: String, CodingKey {
        case kind
        case threadID = "threadId"
        case name
    }
}

private struct ThreadIDCommand: Encodable {
    let kind: String
    let threadID: String

    private enum CodingKeys: String, CodingKey {
        case kind
        case threadID = "threadId"
    }
}

private struct ThreadForkCommand: Encodable {
    let kind: String
    let threadID: String
    let newThreadID: String
    let title: String
    let lastTurnID: String?
    let turnIDMap: [String: String]
    let itemIDMap: [String: String]
    let timestamp: Int64

    private enum CodingKeys: String, CodingKey {
        case kind
        case threadID = "threadId"
        case newThreadID = "newThreadId"
        case title
        case lastTurnID = "lastTurnId"
        case turnIDMap = "turnIdMap"
        case itemIDMap = "itemIdMap"
        case timestamp
    }
}

private struct ThreadGoalSetCommand: Encodable {
    let kind: String
    let threadID: String
    let objective: String
    let status: String
    let tokenBudget: Int64?

    private enum CodingKeys: String, CodingKey {
        case kind
        case threadID = "threadId"
        case objective
        case status
        case tokenBudget
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        try container.encode(threadID, forKey: .threadID)
        try container.encode(objective, forKey: .objective)
        try container.encode(status, forKey: .status)
        if let tokenBudget {
            try container.encode(tokenBudget, forKey: .tokenBudget)
        } else {
            try container.encodeNil(forKey: .tokenBudget)
        }
    }
}

private struct ThreadSettingsUpdateCommand: Encodable {
    let kind: String
    let threadID: String
    let cwd: String
    let model: String
    let effort: String?
    let approvalPolicy: String
    let sandboxPolicy: SandboxPolicyWire

    private enum CodingKeys: String, CodingKey {
        case kind
        case threadID = "threadId"
        case cwd
        case model
        case effort
        case approvalPolicy
        case sandboxPolicy
    }
}

private struct TurnStartCommand: Encodable {
    let kind: String
    let turn: TurnWire
    let userItem: ThreadItemWire
    let timestamp: Int64
}

private struct TurnCompleteCommand: Encodable {
    let kind: String
    let turnID: String
    let assistantItem: ThreadItemWire
    let timestamp: Int64

    private enum CodingKeys: String, CodingKey {
        case kind
        case turnID = "turnId"
        case assistantItem
        case timestamp
    }
}

private struct EventHeader: Decodable {
    let sequence: UInt64
    let kind: String
}

private struct AppServerNotificationHeader: Decodable {
    let method: String
}

private struct ThreadSettingsUpdatedNotificationEnvelope: Decodable {
    let method: String
    let params: CodexThreadSettingsUpdatedNotification
}

private struct PongEvent: Decodable {
    let requestID: String

    private enum CodingKeys: String, CodingKey {
        case requestID = "requestId"
    }
}

private struct ThreadItemsInjectedEvent: Decodable {
    let threadID: CodexStoredThreadID
    let afterTurnID: String?
    let items: [String]

    private enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case afterTurnID = "afterTurnId"
        case items
    }
}

private struct ProviderResponseStartedEvent: Decodable {
    let requestID: String
    let sourceCommit: String

    private enum CodingKeys: String, CodingKey {
        case requestID = "requestId"
        case sourceCommit
    }
}

private struct ToolCallRequestedEvent: Decodable {
    let requestID: String
    let name: String
    let arguments: String
    let callID: String
    let itemJSON: String

    private enum CodingKeys: String, CodingKey {
        case requestID = "requestId"
        case name
        case arguments
        case callID = "callId"
        case itemJSON = "itemJson"
    }
}

private struct ProviderResponseItemDoneEvent: Decodable {
    let requestID: String
    let itemJSON: String

    private enum CodingKeys: String, CodingKey {
        case requestID = "requestId"
        case itemJSON = "itemJson"
    }
}

private struct ProviderRealtimeEvent: Decodable {
    let requestID: String
    let eventType: String
    let payload: CodexJSONValue

    private enum CodingKeys: String, CodingKey {
        case requestID = "requestId"
        case eventType
        case payload
    }
}

private struct AssistantTextDeltaEvent: Decodable {
    let requestID: String
    let delta: String

    private enum CodingKeys: String, CodingKey {
        case requestID = "requestId"
        case delta
    }
}

private struct ProviderPlanDeltaEvent: Decodable {
    let requestID: String
    let itemID: String
    let delta: String

    private enum CodingKeys: String, CodingKey {
        case requestID = "requestId"
        case itemID = "itemId"
        case delta
    }
}

private struct ProviderPlanStartedEvent: Decodable {
    let requestID: String
    let itemID: String

    private enum CodingKeys: String, CodingKey {
        case requestID = "requestId"
        case itemID = "itemId"
    }
}

private struct ProviderPlanCompletedEvent: Decodable {
    let requestID: String
    let itemID: String
    let text: String

    private enum CodingKeys: String, CodingKey {
        case requestID = "requestId"
        case itemID = "itemId"
        case text
    }
}

private struct ProviderResponseCompletedEvent: Decodable {
    let requestID: String
    let responseID: String
    let usage: CodexTokenUsageBreakdown?
    let endTurn: Bool?

    private enum CodingKeys: String, CodingKey {
        case requestID = "requestId"
        case responseID = "responseId"
        case usage
        case endTurn
    }
}

private struct WorkspaceEvent: Decodable {
    let workspace: WorkspaceWire
}

private struct WorkspaceLifecycleEvent: Decodable {
    let workspaceID: String

    private enum CodingKeys: String, CodingKey {
        case workspaceID = "workspaceId"
    }
}

private struct ThreadEvent: Decodable {
    let thread: ThreadWire
}

private struct ThreadNameUpdatedEvent: Decodable {
    let threadID: String
    let name: String

    private enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case name
    }
}

private struct ThreadLifecycleEvent: Decodable {
    let threadID: String

    private enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
    }
}

private struct ThreadMemoryModeUpdatedEvent: Decodable {
    let threadID: String
    let mode: CodexThreadMemoryMode

    private enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case mode
    }
}

private struct ThreadQueueChangedEvent: Decodable {
    let threadID: String
    let queuedSubmissions: [CodexQueuedSubmission]

    private enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case queuedSubmissions
    }
}

private struct ThreadRolledBackEvent: Decodable {
    let threadID: String
    let removedTurnIDs: [String]

    private enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case removedTurnIDs = "removedTurnIds"
    }
}

private struct ThreadRevertedEvent: Decodable {
    let threadID: String
    let beforeTurnID: String
    let removedTurnIDs: [String]

    private enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case beforeTurnID = "beforeTurnId"
        case removedTurnIDs = "removedTurnIds"
    }
}

private struct ThreadGoalUpdatedEvent: Decodable {
    let threadID: String
    let turnID: String?
    let goal: ThreadGoalWire

    private enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case turnID = "turnId"
        case goal
    }
}

private struct ThreadSettingsUpdatedEvent: Decodable {
    let threadID: String
    let threadSettings: ThreadSettingsWire

    private enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case threadSettings
    }
}

private struct TurnEvent: Decodable {
    let turn: TurnWire
}

private struct ItemEvent: Decodable {
    let item: ThreadItemWire
}

private struct TurnStatusEvent: Decodable {
    let turnID: String
    let status: String

    private enum CodingKeys: String, CodingKey {
        case turnID = "turnId"
        case status
    }
}

private struct WorkspaceWire: Codable {
    let id: String
    let displayName: String
    let rootBookmarkID: String?

    init(_ workspace: Workspace) {
        id = workspace.id.uuidString.lowercased()
        displayName = workspace.displayName
        rootBookmarkID = workspace.rootBookmarkID
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case displayName
        case rootBookmarkID = "rootBookmarkId"
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(displayName, forKey: .displayName)
        if let rootBookmarkID {
            try container.encode(rootBookmarkID, forKey: .rootBookmarkID)
        } else {
            try container.encodeNil(forKey: .rootBookmarkID)
        }
    }

    func domain() throws -> Workspace {
        guard let id = UUID(uuidString: id),
              !displayName.trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty
        else {
            throw CodexCoreEnvelopeError.invalidEventPayload
        }
        return Workspace(
            id: id,
            displayName: displayName,
            rootBookmarkID: rootBookmarkID
        )
    }
}

private struct ThreadWire: Codable {
    let id: String
    let workspaceID: String
    let title: String

    init(_ thread: CodexThread) {
        id = thread.id.uuidString.lowercased()
        workspaceID = thread.workspaceID.uuidString.lowercased()
        title = thread.title
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case workspaceID = "workspaceId"
        case title
    }

    func domain() throws -> CodexThread {
        guard let id = UUID(uuidString: id),
              let workspaceID = UUID(uuidString: workspaceID),
              !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw CodexCoreEnvelopeError.invalidEventPayload
        }
        return CodexThread(id: id, workspaceID: workspaceID, title: title)
    }
}

private struct TurnWire: Codable {
    let id: String
    let threadID: String
    let status: String

    init(_ turn: Turn) {
        id = turn.id.uuidString.lowercased()
        threadID = turn.threadID.uuidString.lowercased()
        status = turn.status.rawValue
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case threadID = "threadId"
        case status
    }

    func domain() throws -> Turn {
        guard let id = UUID(uuidString: id),
              let threadID = UUID(uuidString: threadID),
              let status = TurnStatus(rawValue: status)
        else {
            throw CodexCoreEnvelopeError.invalidEventPayload
        }
        return Turn(id: id, threadID: threadID, status: status)
    }
}

private struct ThreadItemWire: Codable {
    let id: String
    let threadID: String
    let turnID: String
    let kind: String
    let text: String

    init(_ item: ThreadItem) {
        id = item.id.uuidString.lowercased()
        threadID = item.threadID.uuidString.lowercased()
        turnID = item.turnID.uuidString.lowercased()
        kind = item.kind.rawValue
        text = item.text
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case threadID = "threadId"
        case turnID = "turnId"
        case kind
        case text
    }

    func domain() throws -> ThreadItem {
        guard let id = UUID(uuidString: id),
              let threadID = UUID(uuidString: threadID),
              let turnID = UUID(uuidString: turnID),
              let kind = ThreadItemKind(rawValue: kind),
              kind == .contextCompaction
                || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw CodexCoreEnvelopeError.invalidEventPayload
        }
        return ThreadItem(
            id: id,
            threadID: threadID,
            turnID: turnID,
            kind: kind,
            text: text
        )
    }
}

private struct ThreadGoalWire: Codable {
    let threadID: String
    let objective: String
    let status: String
    let tokenBudget: Int64?
    let tokensUsed: Int64
    let timeUsedSeconds: Int64
    let createdAt: Int64
    let updatedAt: Int64

    init(_ goal: ThreadGoal) {
        threadID = goal.threadID.uuidString.lowercased()
        objective = goal.objective
        status = goal.status.rawValue
        tokenBudget = goal.tokenBudget
        tokensUsed = goal.tokensUsed
        timeUsedSeconds = goal.timeUsedSeconds
        createdAt = goal.createdAt
        updatedAt = goal.updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case objective
        case status
        case tokenBudget
        case tokensUsed
        case timeUsedSeconds
        case createdAt
        case updatedAt
    }

    func domain() throws -> ThreadGoal {
        guard let threadID = UUID(uuidString: threadID),
              let status = ThreadGoalStatus(rawValue: status),
              !objective.trimmingCharacters(
                in: .whitespacesAndNewlines
              ).isEmpty,
              tokenBudget.map({ $0 > 0 }) ?? true,
              tokensUsed >= 0,
              timeUsedSeconds >= 0,
              createdAt >= 0,
              updatedAt >= createdAt
        else {
            throw CodexCoreEnvelopeError.invalidEventPayload
        }
        return ThreadGoal(
            threadID: threadID,
            objective: objective,
            status: status,
            tokenBudget: tokenBudget,
            tokensUsed: tokensUsed,
            timeUsedSeconds: timeUsedSeconds,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }
}

private struct SandboxPolicyWire: Codable {
    let type: String
    let writableRoots: [String]?
    let networkAccess: Bool?
    let excludeTmpdirEnvVar: Bool?
    let excludeSlashTmp: Bool?

    init(_ policy: ThreadSandboxPolicy) {
        type = policy.rawValue
        switch policy {
        case .dangerFullAccess:
            writableRoots = nil
            networkAccess = nil
            excludeTmpdirEnvVar = nil
            excludeSlashTmp = nil
        case .readOnly:
            writableRoots = nil
            networkAccess = false
            excludeTmpdirEnvVar = nil
            excludeSlashTmp = nil
        case .workspaceWrite:
            writableRoots = []
            networkAccess = false
            excludeTmpdirEnvVar = false
            excludeSlashTmp = false
        }
    }
}

private struct CollaborationModeWire: Codable {
    let mode: String
}

private struct ThreadSettingsWire: Codable {
    let approvalPolicy: CodexAppServerAskForApproval
    let approvalsReviewer: String
    let collaborationMode: CollaborationModeWire
    let cwd: String
    let effort: String?
    let model: String
    let modelProvider: String
    let sandboxPolicy: SandboxPolicyWire

    func domain(threadID rawThreadID: String) throws -> ThreadSettings {
        let parsedEffort = effort.flatMap(CodexReasoningEffort.init(rawValue:))
        let parsedApprovalPolicy: ThreadApprovalPolicy = switch approvalPolicy {
        case .untrusted:
            .untrusted
        case .onRequest, .granular:
            .onRequest
        case .never:
            .never
        }
        guard let threadID = UUID(uuidString: rawThreadID),
              cwd.hasPrefix("/"),
              !model.isEmpty,
              !modelProvider.isEmpty,
              let sandboxPolicy = ThreadSandboxPolicy(
                rawValue: sandboxPolicy.type
              ),
              parsedEffort != nil || effort == nil
        else {
            throw CodexCoreEnvelopeError.invalidEventPayload
        }
        return ThreadSettings(
            threadID: threadID,
            cwd: cwd,
            model: model,
            modelProvider: modelProvider,
            effort: parsedEffort,
            approvalPolicy: parsedApprovalPolicy,
            approvalsReviewer: approvalsReviewer,
            collaborationMode: collaborationMode.mode,
            sandboxPolicy: sandboxPolicy
        )
    }
}

private func encode(_ value: some Encodable) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(value)
}

private func decodeEvent<Value: Decodable>(
    _ data: Data,
    using decoder: JSONDecoder
) throws -> Value {
    do {
        return try decoder.decode(Value.self, from: data)
    } catch {
        throw CodexCoreEnvelopeError.invalidEventPayload
    }
}

private func requireText(_ value: String) throws {
    if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        throw CodexCoreEnvelopeError.emptyText
    }
}

private func requireAbsolutePath(_ value: String) throws {
    guard !value.isEmpty, (value as NSString).isAbsolutePath else {
        throw CodexCoreEnvelopeError.invalidCommandPayload
    }
}

private func requireTimestamp(_ value: Int64) throws {
    guard value >= 0 else {
        throw CodexCoreEnvelopeError.invalidCommandPayload
    }
}

private func validateThreadCreateMetadata(
    _ metadata: CodexThreadCreateMetadata
) throws {
    try requireText(metadata.sessionID)
    try requireText(metadata.modelProvider)
    try requireAbsolutePath(metadata.cwd)
    try requireText(metadata.cliVersion)
    try requireTimestamp(metadata.createdAt)
    guard metadata.updatedAt >= metadata.createdAt,
          metadata.recencyAt.map({ $0 >= metadata.createdAt }) ?? true
    else {
        throw CodexCoreEnvelopeError.invalidCommandPayload
    }

    for identifier in [
        metadata.forkedFromID?.rawValue,
        metadata.parentThreadID?.rawValue,
    ].compactMap({ $0 }) {
        try requireText(identifier)
    }
    for text in [
        metadata.threadSource,
        metadata.agentNickname,
        metadata.agentRole,
        metadata.gitInfo?.sha,
        metadata.gitInfo?.branch,
        metadata.gitInfo?.originURL,
    ].compactMap({ $0 }) {
        try requireText(text)
    }
    if let path = metadata.path {
        try requireAbsolutePath(path)
    }
    if case let .custom(name) = metadata.source {
        try requireText(name)
    }
}
