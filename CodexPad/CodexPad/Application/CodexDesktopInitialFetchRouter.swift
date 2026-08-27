#if SWIFT_PACKAGE
    import CodexPadDomain
    import CodexPadProtocolBridge
#endif
import Foundation

public struct CodexDesktopInitialHostState:
    Equatable,
    Sendable
{
    public let codexHome: String
    public let worktreesSegment: String
    public let platform: String
    public let osVersion: String
    public let osRelease: String
    public let isSystemBackdropSupported: Bool
    public let isVsCodeRunningInsideWsl: Bool
    public let windowsAccountType: String
    public let isCopilotAPIAvailable: Bool
    public let configuredSettings: [String: CodexJSONValue]
    public let effectiveSettings: [String: CodexJSONValue]
    public let globalState: [String: CodexJSONValue]
    public let ideLocale: String
    public let systemLocale: String
    public let automationItems: [CodexJSONValue]
    public let activeWorkspaceRoots: [String]
    public let workspaceRootOptions: [String]
    public let remoteControlConnections: [CodexJSONValue]
    public let inboxItems: [CodexJSONValue]
    public let unreadRunCount: Int64
    public let unreadAutomationIDs: [String]
    public let unreadRuns: [CodexJSONValue]
    public let commandKeymapPath: String
    public let commandKeyBindings: [CodexJSONValue]
    public let existingPaths: Set<String>
    public let pinnedThreadIDs: [String]
    public let accountInfo: CodexJSONValue?

    public init(
        codexHome: String,
        worktreesSegment: String,
        platform: String,
        osVersion: String,
        osRelease: String,
        isSystemBackdropSupported: Bool,
        isVsCodeRunningInsideWsl: Bool,
        windowsAccountType: String,
        isCopilotAPIAvailable: Bool,
        configuredSettings: [String: CodexJSONValue],
        effectiveSettings: [String: CodexJSONValue],
        globalState: [String: CodexJSONValue],
        ideLocale: String,
        systemLocale: String,
        automationItems: [CodexJSONValue],
        activeWorkspaceRoots: [String],
        workspaceRootOptions: [String]? = nil,
        remoteControlConnections: [CodexJSONValue],
        inboxItems: [CodexJSONValue],
        unreadRunCount: Int64,
        unreadAutomationIDs: [String],
        unreadRuns: [CodexJSONValue],
        commandKeymapPath: String,
        commandKeyBindings: [CodexJSONValue],
        existingPaths: Set<String>,
        pinnedThreadIDs: [String],
        accountInfo: CodexJSONValue? = nil
    ) {
        self.codexHome = codexHome
        self.worktreesSegment = worktreesSegment
        self.platform = platform
        self.osVersion = osVersion
        self.osRelease = osRelease
        self.isSystemBackdropSupported = isSystemBackdropSupported
        self.isVsCodeRunningInsideWsl = isVsCodeRunningInsideWsl
        self.windowsAccountType = windowsAccountType
        self.isCopilotAPIAvailable = isCopilotAPIAvailable
        self.configuredSettings = configuredSettings
        self.effectiveSettings = effectiveSettings
        self.globalState = globalState
        self.ideLocale = ideLocale
        self.systemLocale = systemLocale
        self.automationItems = automationItems
        self.activeWorkspaceRoots = activeWorkspaceRoots
        self.workspaceRootOptions =
            workspaceRootOptions ?? activeWorkspaceRoots
        self.remoteControlConnections = remoteControlConnections
        self.inboxItems = inboxItems
        self.unreadRunCount = unreadRunCount
        self.unreadAutomationIDs = unreadAutomationIDs
        self.unreadRuns = unreadRuns
        self.commandKeymapPath = commandKeymapPath
        self.commandKeyBindings = commandKeyBindings
        self.existingPaths = existingPaths
        self.pinnedThreadIDs = pinnedThreadIDs
        self.accountInfo = accountInfo
    }
}

public enum CodexDesktopInitialFetchRouter {
    private static let responseHeaders = [
        "content-type": "application/json"
    ]

    public static func response(
        to request: CodexDesktopFetchRequest,
        state: CodexDesktopInitialHostState,
        automationStore: CodexDesktopAutomationStore? = nil,
        pinnedThreadStore: CodexDesktopPinnedThreadStore? = nil,
        globalStateStore: CodexDesktopPersistedAtomStore? = nil,
        configStore: CodexDesktopConfigStore? = nil,
        recommendedSkillService:
            CodexRecommendedSkillService? = nil,
        settingsFilePath: String? = nil,
        projectlessWorkspaceRootPath: String? = nil,
        fileManager: FileManager = .default,
        now: Date = Date()
    ) -> CodexDesktopHostMessage {
        guard request.method == "POST" else {
            return failure(
                request,
                message:
                    "Unsupported VS Code bridge HTTP method: \(request.method)",
                code: "unsupported_http_method"
            )
        }

        switch request.hostMethod {
        case "get-settings":
            let configured =
                configStore?.snapshot
                ?? state.configuredSettings
            let effective =
                configStore == nil
                    ? state.effectiveSettings
                    : CodexDesktopReleasedSettings
                        .effectiveValues(
                            configured: configured
                        )
            return success(
                request,
                body: .object([
                    "configuredValues": .object(
                        configured
                    ),
                    "values": .object(effective),
                ])
            )

        case "codex-home":
            guard let body = objectBody(request),
                  case let .string(hostID)? = body["hostId"],
                  !hostID.isEmpty
            else {
                return invalidBody(request)
            }
            return success(
                request,
                body: .object([
                    "codexHome": .string(state.codexHome),
                    "worktreesSegment": .string(
                        state.worktreesSegment
                    ),
                ])
            )

        case "codex-agents-md":
            guard let body = objectBody(request),
                  case let .string(hostID)? = body["hostId"],
                  !hostID.isEmpty
            else {
                return invalidBody(request)
            }
            do {
                let document =
                    try CodexDesktopHostConfigurationService
                        .readAgentsDocument(
                            codexHome: state.codexHome,
                            fileManager: fileManager
                        )
                return success(
                    request,
                    body: .object([
                        "path": .string(document.path),
                        "contents": .string(document.contents),
                    ])
                )
            } catch {
                return fileFailure(
                    request,
                    error: error,
                    code: "codex_agents_md_read_failed"
                )
            }

        case "codex-agents-md-save":
            guard let body = objectBody(request),
                  case let .string(hostID)? = body["hostId"],
                  !hostID.isEmpty,
                  case let .string(contents)? = body["contents"]
            else {
                return invalidBody(request)
            }
            do {
                let path =
                    try CodexDesktopHostConfigurationService
                        .writeAgentsDocument(
                            codexHome: state.codexHome,
                            contents: contents,
                            fileManager: fileManager
                        )
                return success(
                    request,
                    body: .object(["path": .string(path)])
                )
            } catch {
                return fileFailure(
                    request,
                    error: error,
                    code: "codex_agents_md_write_failed"
                )
            }

        case "os-info":
            let body: [String: CodexJSONValue] = [
                "platform": .string(state.platform),
                "osVersion": .string(state.osVersion),
                "osRelease": .string(state.osRelease),
                "isSystemBackdropSupported": .bool(
                    state.isSystemBackdropSupported
                ),
                "isVsCodeRunningInsideWsl": .bool(
                    state.isVsCodeRunningInsideWsl
                ),
                "windowsAccountType": .string(state.windowsAccountType),
            ]
            return success(request, body: .object(body))

        case "is-copilot-api-available":
            return success(
                request,
                body: .object([
                    "available": .bool(state.isCopilotAPIAvailable)
                ])
            )

        case "get-copilot-api-proxy-info":
            // The released renderer queries this before every local thread
            // start. iPad has no VS Code Copilot proxy, so JSON null keeps the
            // authenticated Codex provider selected, matching desktop.
            return success(request, body: .null)

        case "account-info":
            return success(
                request,
                body: state.accountInfo ?? .null
            )

        case "get-global-state":
            guard let body = objectBody(request),
                  case let .string(key)? = body["key"],
                  !key.isEmpty
            else {
                return invalidBody(request)
            }
            guard let value =
                globalStateStore?.snapshot[key]
                    ?? state.globalState[key]
            else {
                // Electron returns { value: undefined }; JSON.stringify drops
                // that property and therefore puts an empty object on the wire.
                return success(request, body: .object([:]))
            }
            return success(
                request,
                body: .object(["value": value])
            )

        case "set-global-state":
            guard let body = objectBody(request),
                  case let .string(key)? = body["key"],
                  !key.isEmpty,
                  let value = body["value"],
                  let globalStateStore
            else {
                return invalidBody(request)
            }
            _ = globalStateStore.update(
                key: key,
                value: value
            )
            if key
                == CodexDesktopPinnedThreadStore
                    .releasedStorageKey,
               case let .array(values) = value,
               let pinnedThreadStore
            {
                let threadIDs: [String] = values.compactMap {
                    value -> String? in
                    guard case let .string(threadID) = value,
                          !threadID.isEmpty
                    else {
                        return nil
                    }
                    return threadID
                }
                if threadIDs.count == values.count {
                    _ = pinnedThreadStore.setOrder(
                        threadIDs: threadIDs
                    )
                }
            }
            return success(
                request,
                body: .object(["success": .bool(true)])
            )

        case "get-configuration":
            guard let body = objectBody(request),
                  case let .string(key)? = body["key"],
                  !key.isEmpty
            else {
                return invalidBody(request)
            }
            guard let value =
                globalStateStore?.snapshot[key]
                    ?? state.globalState[key]
                    ?? configStore?.snapshot[key]
            else {
                return success(request, body: .object([:]))
            }
            return success(
                request,
                body: .object(["value": value])
            )

        case "set-configuration":
            guard let body = objectBody(request),
                  case let .string(key)? = body["key"],
                  !key.isEmpty,
                  let value = body["value"],
                  let globalStateStore
            else {
                return invalidBody(request)
            }
            _ = globalStateStore.update(
                key: key,
                value: value
            )
            if releasedSetting(for: key) != nil,
               let configStore
            {
                _ = configStore.write(
                    keyPath: key,
                    value: value,
                    mergeStrategy: "replace"
                )
                do {
                    try persistSettings(
                        configStore.snapshot,
                        filePath: settingsFilePath,
                        fileManager: fileManager
                    )
                } catch {
                    return fileFailure(
                        request,
                        error: error,
                        code: "settings_write_failed"
                    )
                }
            }
            return success(
                request,
                body: .object(["success": .bool(true)])
            )

        case "get-setting":
            guard let body = objectBody(request),
                  case let .string(key)? = body["key"],
                  !key.isEmpty
            else {
                return invalidBody(request)
            }
            let configured =
                configStore?.snapshot
                ?? state.configuredSettings
            guard let value =
                (
                    configStore == nil
                        ? state.effectiveSettings
                        : CodexDesktopReleasedSettings
                            .effectiveValues(
                                configured: configured
                            )
                )[key]
            else {
                return success(request, body: .object([:]))
            }
            return success(
                request,
                body: .object(["value": value])
            )

        case "set-setting":
            guard let body = objectBody(request),
                  case let .string(key)? = body["key"],
                  !key.isEmpty,
                  let value = body["value"],
                  let definition = releasedSetting(for: key),
                  settingValue(
                      value,
                      matches: definition
                  ),
                  let configStore
            else {
                return invalidBody(request)
            }
            _ = configStore.write(
                keyPath: key,
                value: value,
                mergeStrategy: "replace"
            )
            do {
                try persistSettings(
                    configStore.snapshot,
                    filePath: settingsFilePath,
                    fileManager: fileManager
                )
            } catch {
                return fileFailure(
                    request,
                    error: error,
                    code: "settings_write_failed"
                )
            }
            return success(
                request,
                body: .object(["success": .bool(true)])
            )

        case "settings-read":
            let configured =
                configStore?.snapshot
                ?? state.configuredSettings
            let effective =
                configStore == nil
                    ? state.effectiveSettings
                    : CodexDesktopReleasedSettings
                        .effectiveValues(
                            configured: configured
                        )
            return success(
                request,
                body: .object([
                    "filePath": .string(
                        settingsFilePath
                            ?? URL(
                                fileURLWithPath:
                                    state.codexHome,
                                isDirectory: true
                            )
                            .appendingPathComponent(
                                "settings.json"
                            ).path
                    ),
                    "settings": .object(
                        toolVisibleSettings(
                            configured
                        )
                    ),
                    "effectiveSettings": .object(
                        toolVisibleSettings(
                            effective
                        )
                    ),
                    "definitions": .array(
                        releasedSettingDefinitions()
                    ),
                ])
            )

        case "settings-write":
            guard let body = objectBody(request),
                  case let .object(settings)? =
                      body["settings"],
                  let configStore
            else {
                return invalidBody(request)
            }
            var edits:
                [(
                    keyPath: String,
                    value: CodexJSONValue,
                    mergeStrategy: String
                )] = []
            for (key, value) in settings {
                guard let definition =
                    releasedSetting(for: key),
                    definition.access == .writable,
                    settingValue(
                        value,
                        matches: definition
                    )
                else {
                    return failure(
                        request,
                        message:
                            "Setting cannot be written by Codex: \(key)",
                        code: "settings_validation_failed"
                    )
                }
                edits.append(
                    (
                        keyPath: key,
                        value: value,
                        mergeStrategy: "replace"
                    )
                )
            }
            _ = configStore.batchWrite(
                edits: edits
            )
            do {
                try persistSettings(
                    configStore.snapshot,
                    filePath: settingsFilePath,
                    fileManager: fileManager
                )
            } catch {
                return fileFailure(
                    request,
                    error: error,
                    code: "settings_write_failed"
                )
            }
            let configured = configStore.snapshot
            return success(
                request,
                body: .object([
                    "settings": .object(
                        toolVisibleSettings(configured)
                    ),
                    "effectiveSettings": .object(
                        toolVisibleSettings(
                            CodexDesktopReleasedSettings
                                .effectiveValues(
                                    configured: configured
                                )
                        )
                    ),
                ])
            )

        case "mcp-codex-config":
            guard let body = objectBody(request),
                  case let .string(cwd)? = body["cwd"],
                  !cwd.trimmingCharacters(
                      in: .whitespacesAndNewlines
                  ).isEmpty
            else {
                return invalidBody(request)
            }
            return success(
                request,
                body: .object([
                    "config":
                        CodexDesktopHostConfigurationService
                            .mcpCodexConfig(
                                configuredSettings:
                                    configStore?.snapshot
                                    ?? state.configuredSettings
                            )
                ])
            )

        case "developer-instructions":
            guard let body = objectBody(request),
                  isOptionalString(body["baseInstructions"]),
                  isOptionalString(body["cwd"]),
                  isOptionalString(body["hostId"]),
                  isOptionalBool(
                      body[
                          "includeProseDetailLevelInstructions"
                      ]
                  ),
                  isOptionalObject(body["instructionOverrides"]),
                  isOptionalBool(body["threadToolsEnabled"]),
                  isOptionalString(body["threadId"]),
                  optionalString(body["hostId"])?.isEmpty != true
            else {
                return invalidBody(request)
            }
            let configured =
                configStore?.snapshot
                ?? state.configuredSettings
            var effective = state.effectiveSettings
            for (key, value) in configured {
                effective[key] = value
            }
            return success(
                request,
                body: .object([
                    "instructions": .string(
                        CodexDesktopHostConfigurationService
                            .developerInstructions(
                                baseInstructions: optionalString(
                                    body["baseInstructions"]
                                ),
                                cwd: optionalString(body["cwd"]),
                                instructionOverrides:
                                    optionalObject(
                                        body[
                                            "instructionOverrides"
                                        ]
                                    ),
                                threadToolsEnabled:
                                    optionalBool(
                                        body["threadToolsEnabled"]
                                    ) ?? false,
                                includeProseDetailLevelInstructions:
                                    optionalBool(
                                        body[
                                            "includeProseDetailLevelInstructions"
                                        ]
                                    ) ?? false,
                                configuredSettings: effective,
                                fileManager: fileManager
                            )
                    )
                ])
            )

        case "list-automations":
            let items =
                automationStore?.snapshot().items
                ?? state.automationItems
            return success(
                request,
                body: .object([
                    "items": .array(items)
                ])
            )

        case "automation-create":
            guard let automationStore else {
                return failure(
                    request,
                    message: "Automation store is unavailable",
                    code: "store_unavailable"
                )
            }
            guard let params = objectBody(request) else {
                return invalidBody(request)
            }
            do {
                let defaultCWDs = try automationCompatibilityCWDs(
                    params: params,
                    state: state
                )
                return success(
                    request,
                    body: .object([
                        "item": try automationStore.create(
                            params: params,
                            defaultCWDs: defaultCWDs,
                            now: now
                        )
                    ])
                )
            } catch {
                return automationFailure(
                    request,
                    error: error
                )
            }

        case "automation-update":
            guard let automationStore else {
                return failure(
                    request,
                    message: "Automation store is unavailable",
                    code: "store_unavailable"
                )
            }
            guard let params = objectBody(request) else {
                return invalidBody(request)
            }
            do {
                let defaultCWDs = try automationCompatibilityCWDs(
                    params: params,
                    state: state
                )
                return success(
                    request,
                    body: .object([
                        "item": try automationStore.update(
                            params: params,
                            defaultCWDs: defaultCWDs,
                            now: now
                        )
                    ])
                )
            } catch {
                return automationFailure(
                    request,
                    error: error
                )
            }

        case "automation-delete":
            guard let automationStore else {
                return success(
                    request,
                    body: .object([
                        "item": .null,
                        "status": .string("store_unavailable"),
                        "success": .bool(false),
                    ])
                )
            }
            guard let params = objectBody(request),
                  case let .string(id)? = params["id"]
            else {
                return invalidBody(request)
            }
            let result = automationStore.delete(
                id: id,
                now: now
            )
            return success(
                request,
                body: .object([
                    "item": result.item ?? .null,
                    "status": .string(result.status),
                    "success": .bool(result.success),
                ])
            )

        case "automation-run-archive":
            guard let automationStore else {
                return failure(
                    request,
                    message: "Automation store is unavailable",
                    code: "store_unavailable"
                )
            }
            guard let params = objectBody(request),
                  case let .string(threadID)? = params["threadId"],
                  !threadID.isEmpty,
                  Self.isOptionalString(
                      params["archivedAssistantMessage"]
                  ),
                  Self.isOptionalString(
                      params["archivedUserMessage"]
                  ),
                  Self.isOptionalString(
                      params["archivedReason"]
                  )
            else {
                return invalidBody(request)
            }
            do {
                return success(
                    request,
                    body: .object([
                        "success": .bool(
                            try automationStore.archiveRun(
                                threadID: threadID,
                                archivedAssistantMessage:
                                    Self.optionalString(
                                        params[
                                            "archivedAssistantMessage"
                                        ]
                                    ),
                                archivedUserMessage:
                                    Self.optionalString(
                                        params[
                                            "archivedUserMessage"
                                        ]
                                    ),
                                reason: Self.optionalString(
                                    params["archivedReason"]
                                )
                            )
                        )
                    ])
                )
            } catch {
                return automationFailure(
                    request,
                    error: error
                )
            }

        case "automation-run-delete":
            guard let automationStore else {
                return failure(
                    request,
                    message: "Automation store is unavailable",
                    code: "store_unavailable"
                )
            }
            guard let params = objectBody(request),
                  case let .string(threadID)? = params["threadId"],
                  !threadID.isEmpty
            else {
                return invalidBody(request)
            }
            do {
                return success(
                    request,
                    body: .object([
                        "success": .bool(
                            try automationStore.deleteRun(
                                threadID: threadID
                            )
                        )
                    ])
                )
            } catch {
                return automationFailure(
                    request,
                    error: error
                )
            }

        case "projectless-thread-cwd":
            guard let params = optionalObjectBody(request) else {
                return invalidBody(request)
            }
            let createSplitDirectories: Bool
            switch params["createSplitDirectories"] {
            case let .bool(value)?:
                createSplitDirectories = value
            case nil, .null?:
                createSplitDirectories = true
            default:
                return invalidBody(request)
            }
            let directoryName: String?
            switch params["directoryName"] {
            case let .string(value)?:
                directoryName = value
            case nil, .null?:
                directoryName = nil
            default:
                return invalidBody(request)
            }
            let prompt: String?
            switch params["prompt"] {
            case let .string(value)?:
                prompt = value
            case nil, .null?:
                prompt = nil
            default:
                return invalidBody(request)
            }
            do {
                let paths = try createProjectlessThreadPaths(
                    createSplitDirectories:
                        createSplitDirectories,
                    directoryName: directoryName,
                    prompt: prompt,
                    now: now,
                    workspaceRootPath:
                        projectlessWorkspaceRootPath,
                    fileManager: fileManager
                )
                return success(
                    request,
                    body: .object([
                        "cwd": .string(paths.cwd),
                        "outputDirectory": .string(
                            paths.outputDirectory
                        ),
                        "workspaceRoot": .string(
                            paths.workspaceRoot
                        ),
                    ])
                )
            } catch {
                return fileFailure(
                    request,
                    error: error,
                    code: "projectless_directory_failed"
                )
            }

        case "projectless-workspace-root":
            do {
                let root = try projectlessWorkspaceRoot(
                    fileManager: fileManager,
                    createIfNeeded: false,
                    overridePath:
                        projectlessWorkspaceRootPath
                )
                return success(
                    request,
                    body: .object([
                        "workspaceRoot": .string(root.path)
                    ])
                )
            } catch {
                return fileFailure(
                    request,
                    error: error,
                    code: "projectless_directory_failed"
                )
            }

        case "home-directory":
            guard optionalObjectBody(request) != nil else {
                return invalidBody(request)
            }
            return success(
                request,
                body: .object([
                    "homeDirectory": .string(
                        homeDirectoryURL(
                            fileManager: fileManager
                        ).path
                    )
                ])
            )

        case "workspace-directory-entries":
            guard let body = objectBody(request),
                  case let .string(workspaceRoot)? =
                      body["workspaceRoot"],
                  !workspaceRoot.isEmpty
            else {
                return invalidBody(request)
            }
            let directoryPath: String
            switch body["directoryPath"] {
            case let .string(value)?:
                directoryPath = value
            case nil, .null?:
                directoryPath = ""
            default:
                return invalidBody(request)
            }
            let directoriesOnly: Bool
            switch body["directoriesOnly"] {
            case let .bool(value)?:
                directoriesOnly = value
            case nil, .null?:
                directoriesOnly = false
            default:
                return invalidBody(request)
            }
            let includeHidden: Bool
            switch body["includeHidden"] {
            case let .bool(value)?:
                includeHidden = value
            case nil, .null?:
                includeHidden = false
            default:
                return invalidBody(request)
            }
            do {
                return success(
                    request,
                    body: try workspaceDirectoryEntries(
                        workspaceRoot: workspaceRoot,
                        directoryPath: directoryPath,
                        directoriesOnly:
                            directoriesOnly,
                        includeHidden: includeHidden,
                        state: state,
                        fileManager: fileManager
                    )
                )
            } catch {
                return fileFailure(
                    request,
                    error: error,
                    code: "workspace_read_failed"
                )
            }

        case "read-file":
            guard let body = objectBody(request),
                  case let .string(path)? = body["path"],
                  !path.isEmpty
            else {
                return invalidBody(request)
            }
            do {
                let url = try resolvedExistingFileURL(
                    path,
                    state: state,
                    fileManager: fileManager
                )
                let contents = try String(
                    contentsOf: url,
                    encoding: .utf8
                )
                return success(
                    request,
                    body: .object([
                        "contents": .string(contents)
                    ])
                )
            } catch {
                return fileFailure(
                    request,
                    error: error,
                    code: "file_read_failed"
                )
            }

        case "read-file-metadata":
            guard let body = objectBody(request),
                  case let .string(path)? = body["path"],
                  !path.isEmpty
            else {
                return invalidBody(request)
            }
            let sampleByteLimit =
                optionalNonnegativeInteger(
                    body["contentSampleByteLimit"]
                )
            let sampleMaxFileBytes =
                optionalNonnegativeInteger(
                    body["contentSampleMaxFileBytes"]
                )
            if body["contentSampleByteLimit"] != nil,
               sampleByteLimit == nil,
               body["contentSampleByteLimit"] != .null
            {
                return invalidBody(request)
            }
            if body["contentSampleMaxFileBytes"] != nil,
               sampleMaxFileBytes == nil,
               body["contentSampleMaxFileBytes"] != .null
            {
                return invalidBody(request)
            }
            do {
                let url = try resolvedExistingURL(
                    path,
                    state: state,
                    fileManager: fileManager
                )
                let values = try url.resourceValues(
                    forKeys: [
                        .creationDateKey,
                        .contentModificationDateKey,
                        .fileSizeKey,
                        .isRegularFileKey,
                    ]
                )
                let isFile =
                    values.isRegularFile == true
                let sizeBytes = values.fileSize.map(Int64.init)
                var result:
                    [String: CodexJSONValue] = [
                        "createdAtMs": dateMilliseconds(
                            values.creationDate
                        ),
                        "isFile": .bool(isFile),
                        "mtimeMs": dateMilliseconds(
                            values.contentModificationDate
                        ),
                        "sizeBytes": sizeBytes.map(
                            CodexJSONValue.integer
                        ) ?? .null,
                    ]
                let isWithinSampleSizeLimit: Bool
                if let sampleMaxFileBytes,
                   let sizeBytes
                {
                    isWithinSampleSizeLimit =
                        sizeBytes
                        <= Int64(sampleMaxFileBytes)
                } else {
                    isWithinSampleSizeLimit = true
                }
                if isFile,
                   let sampleByteLimit,
                   sampleByteLimit > 0,
                   isWithinSampleSizeLimit
                {
                    let sample = try readPrefix(
                        url,
                        byteLimit: sampleByteLimit
                    )
                    result["contentKind"] = .string(
                        inferredContentKind(sample)
                    )
                }
                return success(
                    request,
                    body: .object(result)
                )
            } catch {
                return fileFailure(
                    request,
                    error: error,
                    code: "file_metadata_failed"
                )
            }

        case "write-file":
            guard let body = objectBody(request),
                  case let .string(path)? = body["path"],
                  !path.isEmpty,
                  case let .string(content)? =
                      body["content"],
                  body.keys.contains("expectedMtimeMs")
            else {
                return invalidBody(request)
            }
            let expectedMtime: Double?
            switch body["expectedMtimeMs"] {
            case .null?:
                expectedMtime = nil
            case let value?:
                guard let number = numericValue(value),
                      number.isFinite
                else {
                    return invalidBody(request)
                }
                expectedMtime = number
            case nil:
                return invalidBody(request)
            }
            do {
                let url = try resolvedWritableURL(
                    path,
                    state: state,
                    fileManager: fileManager
                )
                let actualMtime =
                    modificationMilliseconds(
                        at: url,
                        fileManager: fileManager
                    )
                guard sameOptionalMilliseconds(
                    expectedMtime,
                    actualMtime
                ) else {
                    return success(
                        request,
                        body: .object([
                            "outcome": .string("conflict"),
                            "mtimeMs":
                                actualMtime.map(
                                    CodexJSONValue.number
                                ) ?? .null,
                        ])
                    )
                }
                try content.write(
                    to: url,
                    atomically: true,
                    encoding: .utf8
                )
                let savedMtime =
                    modificationMilliseconds(
                        at: url,
                        fileManager: fileManager
                    )
                return success(
                    request,
                    body: .object([
                        "outcome": .string("saved"),
                        "mtimeMs":
                            savedMtime.map(
                                CodexJSONValue.number
                            ) ?? .null,
                    ])
                )
            } catch {
                return fileFailure(
                    request,
                    error: error,
                    code: "file_write_failed"
                )
            }

        case "ensure-directory":
            guard let body = objectBody(request),
                  case let .string(path)? = body["path"],
                  !path.isEmpty
            else {
                return invalidBody(request)
            }
            do {
                let url = try resolvedWritableURL(
                    path,
                    state: state,
                    fileManager: fileManager
                )
                try fileManager.createDirectory(
                    at: url,
                    withIntermediateDirectories: true
                )
                return success(
                    request,
                    body: .object([:])
                )
            } catch {
                return fileFailure(
                    request,
                    error: error,
                    code: "directory_write_failed"
                )
            }

        case "read-file-binary":
            guard let body = objectBody(request),
                  case let .string(path)? = body["path"],
                  !path.isEmpty
            else {
                return invalidBody(request)
            }
            let maxBytes =
                optionalNonnegativeInteger(body["maxBytes"])
            if body["maxBytes"] != nil,
               maxBytes == nil,
               body["maxBytes"] != .null
            {
                return invalidBody(request)
            }
            do {
                let url = try resolvedExistingFileURL(
                    path,
                    state: state,
                    fileManager: fileManager
                )
                if let maxBytes {
                    let values = try url.resourceValues(
                        forKeys: [.fileSizeKey]
                    )
                    if let size = values.fileSize,
                       size > maxBytes
                    {
                        return success(
                            request,
                            body: .object([
                                "contentsBase64": .null
                            ])
                        )
                    }
                }
                let data = try Data(
                    contentsOf: url,
                    options: [.mappedIfSafe]
                )
                if let maxBytes,
                   data.count > maxBytes
                {
                    return success(
                        request,
                        body: .object([
                            "contentsBase64": .null
                        ])
                    )
                }
                var result:
                    [String: CodexJSONValue] = [
                        "contentsBase64": .string(
                            data.base64EncodedString()
                        )
                    ]
                if let mimeType = mimeType(for: url) {
                    result["mimeType"] = .string(mimeType)
                }
                return success(
                    request,
                    body: .object(result)
                )
            } catch {
                return fileFailure(
                    request,
                    error: error,
                    code: "file_read_failed"
                )
            }

        case "find-files":
            guard let body = objectBody(request) else {
                return invalidBody(request)
            }
            let query: String
            switch body["query"] {
            case let .string(value)?:
                query = value
            case nil, .null?:
                query = ""
            default:
                return invalidBody(request)
            }
            let cwd: String?
            switch body["cwd"] {
            case let .string(value)?:
                cwd = value
            case nil, .null?:
                cwd = nil
            default:
                return invalidBody(request)
            }
            do {
                let files = try findFiles(
                    query: query,
                    cwd: cwd,
                    state: state,
                    fileManager: fileManager
                )
                return success(
                    request,
                    body: .object([
                        "files": .array(files)
                    ])
                )
            } catch {
                return fileFailure(
                    request,
                    error: error,
                    code: "file_search_failed"
                )
            }

        case "active-workspace-roots":
            return success(
                request,
                body: .object([
                    "roots": .array(
                        state.activeWorkspaceRoots.map(
                            CodexJSONValue.string
                        )
                    )
                ])
            )

        case "workspace-root-options":
            guard let body = objectBody(request),
                  case let .string(hostID)? = body["hostId"],
                  !hostID.isEmpty
            else {
                return invalidBody(request)
            }
            return success(
                request,
                body: .object([
                    "roots": .array(
                        state.workspaceRootOptions.map(
                            CodexJSONValue.string
                        )
                    ),
                    // The desktop main process only includes entries here
                    // when the user has explicitly renamed a project.
                    "labels": .object([:]),
                ])
            )

        case "set-remote-control-connections-enabled":
            guard let body = objectBody(request),
                  case let .bool(enabled)? = body["enabled"]
            else {
                return invalidBody(request)
            }
            return success(
                request,
                body: .object([
                    "remoteControlConnections": .array(
                        enabled
                            ? state.remoteControlConnections
                            : []
                    )
                ])
            )

        case "set-remote-wsl-connections-enabled":
            guard let body = objectBody(request),
                  case .bool = body["enabled"]
            else {
                return invalidBody(request)
            }
            return success(
                request,
                body: .object([
                    "remoteWslConnections": .array([])
                ])
            )

        case "inbox-items":
            let automationSnapshot =
                automationStore?.snapshot()
            return success(
                request,
                body: .object([
                    "items": .array(
                        automationSnapshot?.inboxItems
                            ?? state.inboxItems
                    ),
                    "unreadRunCounts": .object([
                        "total": .integer(
                            automationSnapshot?.unreadRunCount
                                ?? state.unreadRunCount
                        ),
                        "automationIds": .array(
                            (
                                automationSnapshot?
                                    .unreadAutomationIDs
                                    ?? state.unreadAutomationIDs
                            ).map(
                                CodexJSONValue.string
                            )
                        ),
                        "unreadRuns": .array(
                            automationSnapshot?.unreadRuns
                                ?? state.unreadRuns
                        ),
                    ]),
                ])
            )

        case "codex-command-keymap-state":
            return success(
                request,
                body: .object([
                    "supported": .bool(true),
                    "keymapPath": .string(
                        state.commandKeymapPath
                    ),
                    "bindings": .array(
                        state.commandKeyBindings
                    ),
                ])
            )

        case "paths-exist":
            guard let body = objectBody(request),
                  case let .string(hostID)? = body["hostId"],
                  !hostID.isEmpty,
                  case let .array(pathValues)? = body["paths"]
            else {
                return invalidBody(request)
            }
            let paths = pathValues.compactMap { value -> String? in
                guard case let .string(path) = value else {
                    return nil
                }
                return path
            }
            guard paths.count == pathValues.count else {
                return invalidBody(request)
            }
            return success(
                request,
                body: .object([
                    "existingPaths": .array(
                        paths
                            .filter(state.existingPaths.contains)
                            .map(CodexJSONValue.string)
                    )
                ])
            )

        case "recommended-skills":
            guard let recommendedSkillService else {
                return failure(
                    request,
                    message:
                        "Recommended skill service is unavailable",
                    code: "store_unavailable"
                )
            }
            guard let body = objectBody(request),
                  case let .string(hostID)? = body["hostId"],
                  !hostID.isEmpty
            else {
                return invalidBody(request)
            }
            let refresh: Bool
            switch body["refresh"] {
            case let .bool(value)?:
                refresh = value
            case nil, .null?:
                refresh = false
            default:
                return invalidBody(request)
            }
            return success(
                request,
                body: recommendedSkillService.list(
                    refresh: refresh
                ).jsonValue
            )

        case "local-custom-agents":
            guard let body = optionalObjectBody(request),
                  let roots = optionalStringArray(
                      body["roots"]
                  )
            else {
                return invalidBody(request)
            }
            return success(
                request,
                body: .object([
                    "agents": .array(
                        CodexDesktopHostConfigurationService
                            .localCustomAgents(
                                codexHome: state.codexHome,
                                roots: roots,
                                fileManager: fileManager
                            )
                    )
                ])
            )

        case "install-recommended-skill":
            guard let recommendedSkillService else {
                return failure(
                    request,
                    message:
                        "Recommended skill service is unavailable",
                    code: "store_unavailable"
                )
            }
            guard let body = objectBody(request),
                  case let .string(hostID)? = body["hostId"],
                  !hostID.isEmpty,
                  case let .string(skillID)? = body["skillId"],
                  !skillID.isEmpty,
                  case let .string(repoPath)? = body["repoPath"],
                  !repoPath.isEmpty,
                  isOptionalString(body["installRoot"]),
                  isOptionalString(
                      body["skillStatsigOverride"]
                  ),
                  isOptionalString(body["source"])
            else {
                return invalidBody(request)
            }
            let forceReinstall: Bool
            switch body["forceReinstall"] {
            case let .bool(value)?:
                forceReinstall = value
            case nil, .null?:
                forceReinstall = false
            default:
                return invalidBody(request)
            }
            return success(
                request,
                body: recommendedSkillService.install(
                    skillID: skillID,
                    repoPath: repoPath,
                    installRoot: optionalString(
                        body["installRoot"]
                    ),
                    markdownOverride: optionalString(
                        body["skillStatsigOverride"]
                    ),
                    forceReinstall: forceReinstall,
                    source: optionalString(body["source"]),
                    allowedInstallRoots:
                        recommendedSkillInstallRoots(
                            state
                        )
                ).jsonValue
            )

        case "remove-skill":
            guard let recommendedSkillService else {
                return failure(
                    request,
                    message:
                        "Recommended skill service is unavailable",
                    code: "store_unavailable"
                )
            }
            guard let body = objectBody(request),
                  case let .string(hostID)? = body["hostId"],
                  !hostID.isEmpty,
                  case let .string(skillPath)? = body["skillPath"],
                  !skillPath.isEmpty
            else {
                return invalidBody(request)
            }
            return success(
                request,
                body: recommendedSkillService.remove(
                    skillPath: skillPath,
                    allowedInstallRoots:
                        recommendedSkillInstallRoots(
                            state
                        )
                ).jsonValue
            )

        case "locale-info":
            return success(
                request,
                body: .object([
                    "ideLocale": .string(state.ideLocale),
                    "systemLocale": .string(
                        state.systemLocale
                    ),
                ])
            )

        case "list-pinned-threads":
            let threadIDs =
                pinnedThreadStore?.threadIDs
                ?? state.pinnedThreadIDs
            return success(
                request,
                body: .object([
                    "threadIds": .array(
                        threadIDs.map(
                            CodexJSONValue.string
                        )
                    )
                ])
            )

        case "set-thread-pinned":
            guard let pinnedThreadStore else {
                return failure(
                    request,
                    message: "Pinned thread store is unavailable",
                    code: "store_unavailable"
                )
            }
            guard let body = objectBody(request),
                  case let .string(threadID)? = body["threadId"],
                  !threadID.isEmpty,
                  case let .bool(pinned)? = body["pinned"]
            else {
                return invalidBody(request)
            }
            let beforeThreadID: String?
            switch body["beforeThreadId"] {
            case let .string(value)? where !value.isEmpty:
                beforeThreadID = value
            case nil, .null?:
                beforeThreadID = nil
            default:
                return invalidBody(request)
            }
            return success(
                request,
                body: .object([
                    "success": .bool(
                        pinnedThreadStore.setPinned(
                            threadID: threadID,
                            pinned: pinned,
                            beforeThreadID: beforeThreadID
                        )
                    )
                ])
            )

        case "set-pinned-threads-order":
            guard let pinnedThreadStore else {
                return failure(
                    request,
                    message: "Pinned thread store is unavailable",
                    code: "store_unavailable"
                )
            }
            guard let body = objectBody(request),
                  case let .array(values)? = body["threadIds"]
            else {
                return invalidBody(request)
            }
            let threadIDs = values.compactMap {
                value -> String? in
                guard case let .string(threadID) = value,
                      !threadID.isEmpty
                else {
                    return nil
                }
                return threadID
            }
            guard threadIDs.count == values.count else {
                return invalidBody(request)
            }
            return success(
                request,
                body: .object([
                    "success": .bool(
                        pinnedThreadStore.setOrder(
                            threadIDs: threadIDs
                        )
                    )
                ])
            )

        default:
            return failure(
                request,
                message:
                    "Unsupported VS Code bridge request: \(request.hostMethod)",
                code: "unsupported_host_method"
            )
        }
    }

    private static func objectBody(
        _ request: CodexDesktopFetchRequest
    ) -> [String: CodexJSONValue]? {
        guard let body = request.body,
              let data = body.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(
                  CodexJSONValue.self,
                  from: data
              ),
              case let .object(object) = decoded
        else {
            return nil
        }
        return object
    }

    private static func optionalObjectBody(
        _ request: CodexDesktopFetchRequest
    ) -> [String: CodexJSONValue]? {
        guard let body = request.body,
              !body.trimmingCharacters(
                  in: .whitespacesAndNewlines
              ).isEmpty
        else {
            return [:]
        }
        return objectBody(request)
    }

    private static func isOptionalString(
        _ value: CodexJSONValue?
    ) -> Bool {
        switch value {
        case nil, .null?, .string?:
            return true
        default:
            return false
        }
    }

    private static func isOptionalBool(
        _ value: CodexJSONValue?
    ) -> Bool {
        switch value {
        case nil, .null?, .bool?:
            return true
        default:
            return false
        }
    }

    private static func isOptionalObject(
        _ value: CodexJSONValue?
    ) -> Bool {
        switch value {
        case nil, .null?, .object?:
            return true
        default:
            return false
        }
    }

    private static func recommendedSkillInstallRoots(
        _ state: CodexDesktopInitialHostState
    ) -> [URL] {
        var visited: Set<String> = []
        return (
            state.activeWorkspaceRoots
                + state.workspaceRootOptions
        ).compactMap { path in
            guard !path.isEmpty,
                  !path.contains("\0")
            else {
                return nil
            }
            let root = URL(
                fileURLWithPath: path,
                isDirectory: true
            ).standardizedFileURL
            guard visited.insert(root.path).inserted else {
                return nil
            }
            return root
        }
    }

    private static func optionalString(
        _ value: CodexJSONValue?
    ) -> String? {
        guard case let .string(string)? = value else {
            return nil
        }
        return string
    }

    private static func optionalBool(
        _ value: CodexJSONValue?
    ) -> Bool? {
        guard case let .bool(bool)? = value else {
            return nil
        }
        return bool
    }

    private static func optionalObject(
        _ value: CodexJSONValue?
    ) -> [String: CodexJSONValue]? {
        guard case let .object(object)? = value else {
            return nil
        }
        return object
    }

    private static func optionalStringArray(
        _ value: CodexJSONValue?
    ) -> [String]? {
        switch value {
        case nil, .null?:
            return []
        case let .array(values)?:
            var strings: [String] = []
            strings.reserveCapacity(values.count)
            for value in values {
                guard case let .string(string) = value,
                      !string.trimmingCharacters(
                          in: .whitespacesAndNewlines
                      ).isEmpty
                else {
                    return nil
                }
                strings.append(string)
            }
            return strings
        default:
            return nil
        }
    }

    private static func releasedSetting(
        for key: String
    ) -> CodexDesktopReleasedSetting? {
        CodexDesktopReleasedSettings.all.first {
            $0.key == key
        }
    }

    private static func settingValue(
        _ value: CodexJSONValue,
        matches definition: CodexDesktopReleasedSetting
    ) -> Bool {
        guard let defaultValue = definition.defaultValue else {
            return true
        }
        switch (defaultValue, value) {
        case (.null, _):
            return true
        case (.bool, .bool),
             (.string, .string),
             (.array, .array),
             (.object, .object):
            return true
        case (.integer, .integer),
             (.integer, .number),
             (.number, .integer),
             (.number, .number):
            return true
        default:
            return false
        }
    }

    private static func toolVisibleSettings(
        _ values: [String: CodexJSONValue]
    ) -> [String: CodexJSONValue] {
        values.filter {
            !CodexDesktopReleasedSettings
                .hiddenKeys.contains($0.key)
        }
    }

    private static func releasedSettingDefinitions()
        -> [CodexJSONValue]
    {
        CodexDesktopReleasedSettings.all.compactMap {
            setting in
            guard !setting.isHidden else {
                return nil
            }
            var definition:
                [String: CodexJSONValue] = [
                    "agentAccess": .string(
                        setting.access == .writable
                            ? "read-write" : "read-only"
                    ),
                    "key": .string(setting.key),
                    "schema": settingSchema(
                        for: setting.defaultValue
                    ),
                ]
            if let defaultValue = setting.defaultValue {
                definition["default"] = defaultValue
            }
            return .object(definition)
        }
    }

    private static func settingSchema(
        for value: CodexJSONValue?
    ) -> CodexJSONValue {
        let type: String?
        switch value {
        case .bool?:
            type = "boolean"
        case .integer?:
            type = "integer"
        case .number?:
            type = "number"
        case .string?:
            type = "string"
        case .array?:
            type = "array"
        case .object?:
            type = "object"
        case .null?, nil:
            type = nil
        }
        guard let type else {
            return .object([:])
        }
        return .object(["type": .string(type)])
    }

    private static func persistSettings(
        _ settings: [String: CodexJSONValue],
        filePath: String?,
        fileManager: FileManager
    ) throws {
        guard let filePath, !filePath.isEmpty else {
            return
        }
        let url = URL(fileURLWithPath: filePath)
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [
            .prettyPrinted,
            .sortedKeys,
            .withoutEscapingSlashes,
        ]
        var data = try encoder.encode(
            CodexJSONValue.object(settings)
        )
        data.append(0x0A)
        try data.write(
            to: url,
            options: [.atomic]
        )
    }

    private static func projectlessWorkspaceRoot(
        fileManager: FileManager,
        createIfNeeded: Bool,
        overridePath: String? = nil
    ) throws -> URL {
        if let overridePath,
           !overridePath.isEmpty
        {
            let root = URL(
                fileURLWithPath: overridePath,
                isDirectory: true
            ).standardizedFileURL
            if createIfNeeded {
                try fileManager.createDirectory(
                    at: root,
                    withIntermediateDirectories: true
                )
            }
            return root
        }
        let documents =
            fileManager.urls(
                for: .documentDirectory,
                in: .userDomainMask
            ).first
            ?? homeDirectoryURL(fileManager: fileManager)
                .appendingPathComponent(
                    "Documents",
                    isDirectory: true
                )
        let root = documents.appendingPathComponent(
            "Codex",
            isDirectory: true
        ).standardizedFileURL
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(
            atPath: root.path,
            isDirectory: &isDirectory
        ) {
            let values = try root.resourceValues(
                forKeys: [
                    .isDirectoryKey,
                    .isSymbolicLinkKey,
                ]
            )
            guard isDirectory.boolValue,
                  values.isDirectory == true,
                  values.isSymbolicLink != true
            else {
                throw NSError(
                    domain: "CodexDesktopProjectless",
                    code: 1,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "Projectless thread directory must be a real directory"
                    ]
                )
            }
        } else if createIfNeeded {
            try fileManager.createDirectory(
                at: root,
                withIntermediateDirectories: true
            )
        }
        return root
    }

    private static func homeDirectoryURL(
        fileManager: FileManager
    ) -> URL {
        #if os(macOS)
            fileManager.homeDirectoryForCurrentUser
        #else
            URL(
                fileURLWithPath: NSHomeDirectory(),
                isDirectory: true
            )
        #endif
    }

    private static func createProjectlessThreadPaths(
        createSplitDirectories: Bool,
        directoryName: String?,
        prompt: String?,
        now: Date,
        workspaceRootPath: String?,
        fileManager: FileManager
    ) throws -> (
        cwd: String,
        outputDirectory: String,
        workspaceRoot: String
    ) {
        let workspaceRoot = try projectlessWorkspaceRoot(
            fileManager: fileManager,
            createIfNeeded: true,
            overridePath: workspaceRootPath
        )
        let components = Calendar(
            identifier: .gregorian
        ).dateComponents(
            [.year, .month, .day],
            from: now
        )
        let dateName = String(
            format: "%04d-%02d-%02d",
            components.year ?? 1970,
            components.month ?? 1,
            components.day ?? 1
        )
        let dateDirectory =
            workspaceRoot.appendingPathComponent(
                dateName,
                isDirectory: true
            )
        try fileManager.createDirectory(
            at: dateDirectory,
            withIntermediateDirectories: true
        )

        let baseName = projectlessDirectoryName(
            directoryName: directoryName,
            prompt: prompt
        )
        for attempt in 0 ..< 101 {
            let name =
                attempt == 0
                    ? baseName
                    : "\(baseName)-\(attempt + 1)"
            let threadDirectory =
                dateDirectory.appendingPathComponent(
                    name,
                    isDirectory: true
                )
            do {
                try fileManager.createDirectory(
                    at: threadDirectory,
                    withIntermediateDirectories: false
                )
            } catch CocoaError.fileWriteFileExists {
                continue
            } catch {
                if fileManager.fileExists(
                    atPath: threadDirectory.path
                ) {
                    continue
                }
                throw error
            }

            let outputDirectory: URL
            if createSplitDirectories {
                let outputs =
                    threadDirectory.appendingPathComponent(
                        "outputs",
                        isDirectory: true
                    )
                let work =
                    threadDirectory.appendingPathComponent(
                        "work",
                        isDirectory: true
                    )
                do {
                    try fileManager.createDirectory(
                        at: outputs,
                        withIntermediateDirectories: false
                    )
                    try fileManager.createDirectory(
                        at: work,
                        withIntermediateDirectories: false
                    )
                    outputDirectory = outputs
                } catch {
                    outputDirectory = threadDirectory
                }
            } else {
                outputDirectory = threadDirectory
            }
            return (
                cwd: threadDirectory.path,
                outputDirectory:
                    outputDirectory.path,
                workspaceRoot: workspaceRoot.path
            )
        }

        let fallback =
            dateDirectory.appendingPathComponent(
                "\(baseName)-\(UUID().uuidString.lowercased())",
                isDirectory: true
            )
        try fileManager.createDirectory(
            at: fallback,
            withIntermediateDirectories: false
        )
        return (
            cwd: fallback.path,
            outputDirectory: fallback.path,
            workspaceRoot: workspaceRoot.path
        )
    }

    private static func projectlessDirectoryName(
        directoryName: String?,
        prompt: String?
    ) -> String {
        let source = directoryName ?? prompt ?? ""
        var words: [String] = []
        var current = ""
        for scalar in source.lowercased()
            .unicodeScalars
        {
            let isASCIIAlphanumeric =
                scalar.value >= 48
                    && scalar.value <= 57
                || scalar.value >= 97
                    && scalar.value <= 122
            if isASCIIAlphanumeric {
                current.unicodeScalars.append(scalar)
            } else if !current.isEmpty {
                words.append(current)
                current = ""
            }
        }
        if !current.isEmpty {
            words.append(current)
        }
        if directoryName == nil {
            words = Array(words.prefix(6))
        }
        let joined = words.joined(separator: "-")
        guard !joined.isEmpty else {
            return "new-chat"
        }
        return String(joined.prefix(80))
    }

    private static func workspaceDirectoryEntries(
        workspaceRoot: String,
        directoryPath: String,
        directoriesOnly: Bool,
        includeHidden: Bool,
        state: CodexDesktopInitialHostState,
        fileManager: FileManager
    ) throws -> CodexJSONValue {
        guard !directoryPath.contains("\0"),
              !(directoryPath as NSString)
                  .isAbsolutePath
        else {
            throw invalidPathError(directoryPath)
        }
        let root = try resolvedExistingDirectoryURL(
            workspaceRoot,
            state: state,
            fileManager: fileManager
        )
        let directory =
            root.appendingPathComponent(
                directoryPath,
                isDirectory: true
            ).standardizedFileURL
                .resolvingSymlinksInPath()
        guard contains(directory, in: root) else {
            throw invalidPathError(directoryPath)
        }
        let directoryValues = try directory.resourceValues(
            forKeys: [.isDirectoryKey]
        )
        guard directoryValues.isDirectory == true else {
            throw invalidPathError(directoryPath)
        }

        let children = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [
                .isDirectoryKey,
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .nameKey,
            ],
            options: []
        )
        var entries:
            [(
                isDirectory: Bool,
                name: String,
                value: CodexJSONValue
            )] = []
        for child in children {
            let name = child.lastPathComponent
            if !includeHidden, name.hasPrefix(".") {
                continue
            }
            let lexicalValues = try child.resourceValues(
                forKeys: [
                    .isDirectoryKey,
                    .isRegularFileKey,
                    .isSymbolicLinkKey,
                ]
            )
            let isSymlink =
                lexicalValues.isSymbolicLink == true
            let resolved =
                child.resolvingSymlinksInPath()
            guard contains(resolved, in: root) else {
                continue
            }
            let resolvedValues = try resolved.resourceValues(
                forKeys: [
                    .isDirectoryKey,
                    .isRegularFileKey,
                ]
            )
            let isDirectory =
                resolvedValues.isDirectory == true
            let isFile =
                resolvedValues.isRegularFile == true
            guard isDirectory || isFile,
                  !directoriesOnly || isDirectory
            else {
                continue
            }
            let path = relativePath(
                child.standardizedFileURL,
                root: root
            )
            entries.append(
                (
                    isDirectory: isDirectory,
                    name: name,
                    value: .object([
                        "isSymlink": .bool(isSymlink),
                        "name": .string(name),
                        "path": .string(path),
                        "type": .string(
                            isDirectory
                                ? "directory" : "file"
                        ),
                    ])
                )
            )
        }
        entries.sort {
            if $0.isDirectory != $1.isDirectory {
                return $0.isDirectory
            }
            return $0.name.localizedStandardCompare(
                $1.name
            ) == .orderedAscending
        }
        let normalizedDirectoryPath =
            relativePath(directory, root: root)
        let parentPath: CodexJSONValue
        if normalizedDirectoryPath.isEmpty {
            parentPath = .null
        } else {
            let parent = directory
                .deletingLastPathComponent()
            let relativeParent = relativePath(
                parent,
                root: root
            )
            parentPath = .string(relativeParent)
        }
        return .object([
            "workspaceRoot": .string(root.path),
            "directoryPath": .string(
                normalizedDirectoryPath
            ),
            "parentPath": parentPath,
            "entries": .array(entries.map(\.value)),
        ])
    }

    private static func allowedRootURLs(
        state: CodexDesktopInitialHostState,
        fileManager: FileManager
    ) -> [URL] {
        let projectless =
            try? projectlessWorkspaceRoot(
                fileManager: fileManager,
                createIfNeeded: false
            )
        let raw =
            [state.codexHome]
            + state.activeWorkspaceRoots
            + state.workspaceRootOptions
            + [projectless?.path].compactMap { $0 }
        var seen = Set<String>()
        return raw.compactMap { path in
            guard !path.isEmpty,
                  !path.contains("\0")
            else {
                return nil
            }
            let url = URL(
                fileURLWithPath: path,
                isDirectory: true
            ).standardizedFileURL
            guard seen.insert(url.path).inserted else {
                return nil
            }
            return url
        }
    }

    private static func lexicalURL(
        _ path: String,
        state: CodexDesktopInitialHostState
    ) throws -> URL {
        guard !path.isEmpty,
              !path.contains("\0")
        else {
            throw invalidPathError(path)
        }
        if (path as NSString).isAbsolutePath {
            return URL(
                fileURLWithPath: path
            ).standardizedFileURL
        }
        let base =
            state.activeWorkspaceRoots.first
            ?? state.codexHome
        return URL(
            fileURLWithPath: base,
            isDirectory: true
        ).appendingPathComponent(path)
            .standardizedFileURL
    }

    private static func resolvedExistingURL(
        _ path: String,
        state: CodexDesktopInitialHostState,
        fileManager: FileManager
    ) throws -> URL {
        let lexical = try lexicalURL(
            path,
            state: state
        )
        guard let root = allowedRootURLs(
            state: state,
            fileManager: fileManager
        ).first(where: {
            contains(lexical, in: $0)
        }) else {
            throw invalidPathError(path)
        }
        guard fileManager.fileExists(
            atPath: lexical.path
        ) else {
            throw CocoaError(.fileNoSuchFile)
        }
        let resolved =
            lexical.resolvingSymlinksInPath()
        let resolvedRoot =
            root.resolvingSymlinksInPath()
        guard contains(resolved, in: resolvedRoot)
        else {
            throw invalidPathError(path)
        }
        return resolved
    }

    private static func resolvedExistingFileURL(
        _ path: String,
        state: CodexDesktopInitialHostState,
        fileManager: FileManager
    ) throws -> URL {
        let url = try resolvedExistingURL(
            path,
            state: state,
            fileManager: fileManager
        )
        let values = try url.resourceValues(
            forKeys: [.isRegularFileKey]
        )
        guard values.isRegularFile == true else {
            throw invalidPathError(path)
        }
        return url
    }

    private static func resolvedExistingDirectoryURL(
        _ path: String,
        state: CodexDesktopInitialHostState,
        fileManager: FileManager
    ) throws -> URL {
        let url = try resolvedExistingURL(
            path,
            state: state,
            fileManager: fileManager
        )
        let values = try url.resourceValues(
            forKeys: [.isDirectoryKey]
        )
        guard values.isDirectory == true else {
            throw invalidPathError(path)
        }
        return url
    }

    private static func resolvedWritableURL(
        _ path: String,
        state: CodexDesktopInitialHostState,
        fileManager: FileManager
    ) throws -> URL {
        let lexical = try lexicalURL(
            path,
            state: state
        )
        let roots = allowedRootURLs(
            state: state,
            fileManager: fileManager
        )
        guard let root = roots.first(where: {
            contains(lexical, in: $0)
        }) else {
            throw invalidPathError(path)
        }
        if fileManager.fileExists(
            atPath: lexical.path
        ) {
            let resolved =
                lexical.resolvingSymlinksInPath()
            guard contains(
                resolved,
                in: root.resolvingSymlinksInPath()
            ) else {
                throw invalidPathError(path)
            }
            return resolved
        }

        var ancestor =
            lexical.deletingLastPathComponent()
        while !fileManager.fileExists(
            atPath: ancestor.path
        ), ancestor.path != "/"
        {
            let parent =
                ancestor.deletingLastPathComponent()
            if parent.path == ancestor.path {
                break
            }
            ancestor = parent
        }
        let resolvedAncestor =
            ancestor.resolvingSymlinksInPath()
        guard contains(
            resolvedAncestor,
            in: root.resolvingSymlinksInPath()
        ) else {
            throw invalidPathError(path)
        }
        return lexical
    }

    private static func contains(
        _ candidate: URL,
        in root: URL
    ) -> Bool {
        let candidatePath =
            candidate.standardizedFileURL.path
        let rootPath = root.standardizedFileURL.path
        return candidatePath == rootPath
            || candidatePath.hasPrefix(
                rootPath.hasSuffix("/")
                    ? rootPath : rootPath + "/"
            )
    }

    private static func relativePath(
        _ candidate: URL,
        root: URL
    ) -> String {
        let candidatePath =
            candidate.standardizedFileURL.path
        let rootPath =
            root.standardizedFileURL.path
        guard candidatePath != rootPath else {
            return ""
        }
        let prefix =
            rootPath.hasSuffix("/")
                ? rootPath : rootPath + "/"
        guard candidatePath.hasPrefix(prefix) else {
            return candidate.lastPathComponent
        }
        return String(
            candidatePath.dropFirst(prefix.count)
        )
    }

    private static func invalidPathError(
        _ path: String
    ) -> NSError {
        NSError(
            domain: "CodexDesktopHostFilesystem",
            code: 1,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "Path is outside the released host roots: \(path)"
            ]
        )
    }

    private static func optionalNonnegativeInteger(
        _ value: CodexJSONValue?
    ) -> Int? {
        switch value {
        case nil, .null?:
            return nil
        case let .integer(number)?
            where number >= 0
                && number <= Int64(Int.max):
            return Int(number)
        case let .number(number)?
            where number.isFinite
                && number >= 0
                && number.rounded() == number
                && number <= Double(Int.max):
            return Int(number)
        default:
            return nil
        }
    }

    private static func numericValue(
        _ value: CodexJSONValue
    ) -> Double? {
        switch value {
        case let .integer(number):
            return Double(number)
        case let .number(number):
            return number
        default:
            return nil
        }
    }

    private static func dateMilliseconds(
        _ date: Date?
    ) -> CodexJSONValue {
        guard let date else {
            return .null
        }
        return .number(
            date.timeIntervalSince1970 * 1_000
        )
    }

    private static func modificationMilliseconds(
        at url: URL,
        fileManager: FileManager
    ) -> Double? {
        guard fileManager.fileExists(atPath: url.path),
              let attributes =
                  try? fileManager.attributesOfItem(
                      atPath: url.path
                  ),
              let date =
                  attributes[.modificationDate] as? Date
        else {
            return nil
        }
        return date.timeIntervalSince1970 * 1_000
    }

    private static func sameOptionalMilliseconds(
        _ lhs: Double?,
        _ rhs: Double?
    ) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil):
            return true
        case let (.some(lhs), .some(rhs)):
            return abs(lhs - rhs) < 0.5
        default:
            return false
        }
    }

    private static func readPrefix(
        _ url: URL,
        byteLimit: Int
    ) throws -> Data {
        let handle = try FileHandle(
            forReadingFrom: url
        )
        defer {
            try? handle.close()
        }
        return try handle.read(
            upToCount: byteLimit
        ) ?? Data()
    }

    private static func inferredContentKind(
        _ data: Data
    ) -> String {
        if data.contains(0)
            || String(data: data, encoding: .utf8) == nil
        {
            return "binary"
        }
        return "text"
    }

    private static func mimeType(
        for url: URL
    ) -> String? {
        switch url.pathExtension.lowercased() {
        case "png":
            return "image/png"
        case "jpg", "jpeg":
            return "image/jpeg"
        case "gif":
            return "image/gif"
        case "webp":
            return "image/webp"
        case "svg":
            return "image/svg+xml"
        case "pdf":
            return "application/pdf"
        case "json":
            return "application/json"
        case "md", "markdown":
            return "text/markdown"
        case "txt", "log":
            return "text/plain"
        case "html", "htm":
            return "text/html"
        case "css":
            return "text/css"
        case "js", "mjs":
            return "text/javascript"
        case "swift":
            return "text/x-swift"
        default:
            return nil
        }
    }

    private static func findFiles(
        query: String,
        cwd: String?,
        state: CodexDesktopInitialHostState,
        fileManager: FileManager
    ) throws -> [CodexJSONValue] {
        let trimmedQuery = query.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !trimmedQuery.isEmpty else {
            return []
        }
        let rawRoot =
            cwd?.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).isEmpty == false
                ? cwd!
                : (
                    state.activeWorkspaceRoots.first
                        ?? state.codexHome
                )
        let root = try resolvedExistingDirectoryURL(
            rawRoot,
            state: state,
            fileManager: fileManager
        )
        let skipped:
            Set<String> = [
                ".build",
                ".git",
                ".swiftpm",
                "DerivedData",
                "node_modules",
            ]
        let keys: [URLResourceKey] = [
            .isDirectoryKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .nameKey,
        ]
        guard let enumerator =
            fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: keys,
                options: [],
                errorHandler: { _, _ in true }
            )
        else {
            return []
        }
        var matches:
            [(
                score: Int64,
                path: String,
                value: CodexJSONValue
            )] = []
        while let item = enumerator.nextObject()
            as? URL
        {
            if matches.count >= 2_000 {
                break
            }
            let values = try? item.resourceValues(
                forKeys: Set(keys)
            )
            let name = item.lastPathComponent
            if name.hasPrefix(".") {
                if values?.isDirectory == true {
                    enumerator.skipDescendants()
                }
                continue
            }
            if values?.isSymbolicLink == true {
                if values?.isDirectory == true {
                    enumerator.skipDescendants()
                }
                continue
            }
            if values?.isDirectory == true,
               skipped.contains(name)
            {
                enumerator.skipDescendants()
                continue
            }
            let isDirectory =
                values?.isDirectory == true
            guard isDirectory
                    || values?.isRegularFile == true
            else {
                continue
            }
            let path = relativePath(
                item,
                root: root
            )
            guard let fuzzy = fuzzyMatch(
                query: trimmedQuery,
                candidate: path
            ) else {
                continue
            }
            let indices = fuzzy.indices.map {
                CodexJSONValue.integer(Int64($0))
            }
            matches.append(
                (
                    score: Int64(fuzzy.score),
                    path: path,
                    value: .object([
                        "root": .string(root.path),
                        "path": .string(path),
                        "fsPath": .string(item.path),
                        "match_type": .string(
                            isDirectory
                                ? "directory" : "file"
                        ),
                        "file_name": .string(name),
                        "score": .integer(
                            Int64(fuzzy.score)
                        ),
                        "indices": .array(indices),
                    ])
                )
            )
        }
        matches.sort {
            if $0.score != $1.score {
                return $0.score > $1.score
            }
            return $0.path < $1.path
        }
        return Array(
            matches.prefix(50).map(\.value)
        )
    }

    private static func fuzzyMatch(
        query: String,
        candidate: String
    ) -> (score: UInt32, indices: [UInt32])? {
        let queryCharacters =
            Array(query.lowercased())
        let candidateCharacters =
            Array(candidate.lowercased())
        guard !queryCharacters.isEmpty else {
            return nil
        }
        var indices: [UInt32] = []
        var queryOffset = 0
        for (candidateOffset, character)
            in candidateCharacters.enumerated()
        {
            guard queryOffset
                    < queryCharacters.count
            else {
                break
            }
            if character
                == queryCharacters[queryOffset]
            {
                indices.append(
                    UInt32(candidateOffset)
                )
                queryOffset += 1
            }
        }
        guard queryOffset == queryCharacters.count
        else {
            return nil
        }

        var score =
            UInt32(queryCharacters.count * 16)
        if indices.first == 0 {
            score &+= 12
        }
        for pair in zip(
            indices,
            indices.dropFirst()
        ) where pair.1 == pair.0 + 1 {
            score &+= 8
        }
        let spread =
            Int(indices.last ?? 0)
            - Int(indices.first ?? 0)
        score &+= UInt32(max(0, 24 - spread))
        score &+= UInt32(
            max(
                0,
                16
                    - candidateCharacters.count / 4
            )
        )
        return (score, indices)
    }

    private static func success(
        _ request: CodexDesktopFetchRequest,
        body: CodexJSONValue
    ) -> CodexDesktopHostMessage {
        .fetchSuccess(
            requestID: request.requestID,
            status: 200,
            headers: responseHeaders,
            body: body
        )
    }

    private static func fileFailure(
        _ request: CodexDesktopFetchRequest,
        error: any Error,
        code: String
    ) -> CodexDesktopHostMessage {
        failure(
            request,
            message: String(describing: error),
            code: code
        )
    }

    private static func invalidBody(
        _ request: CodexDesktopFetchRequest
    ) -> CodexDesktopHostMessage {
        failure(
            request,
            message:
                "Invalid VS Code bridge request body: \(request.hostMethod)",
            code: "invalid_request_body"
        )
    }

    private static func automationFailure(
        _ request: CodexDesktopFetchRequest,
        error: any Error
    ) -> CodexDesktopHostMessage {
        guard let error =
            error as? CodexDesktopAutomationStoreError
        else {
            return failure(
                request,
                message: String(describing: error),
                code: "automation_store_error"
            )
        }
        switch error {
        case let .invalidRequest(reason):
            return failure(
                request,
                message: "Invalid automation request: \(reason)",
                code: "invalid_request_body"
            )
        case let .automationNotFound(id):
            return failure(
                request,
                message: "Automation does not exist: \(id)",
                code: "automation_not_found"
            )
        case .scheduleHasNoFutureRun:
            return failure(
                request,
                message:
                    "Automation schedule has no future runs",
                code: "schedule_has_no_future_run"
            )
        case let .storeUnavailable(message):
            return failure(
                request,
                message: message,
                code: "store_unavailable"
            )
        }
    }

    private static func automationCompatibilityCWDs(
        params: [String: CodexJSONValue],
        state: CodexDesktopInitialHostState
    ) throws -> [String] {
        guard params["kind"] == .string("cron") else {
            return []
        }
        if params.keys.contains("cwds") {
            return []
        }
        guard let projectIDValue = params["projectId"] else {
            return ["~"]
        }
        if projectIDValue == .null {
            return ["~"]
        }
        guard case let .string(projectID) = projectIDValue,
              case let .object(projects)? =
                  state.globalState["local-projects"],
              case let .object(project)? = projects[projectID],
              case let .array(rootValues)? = project["rootPaths"]
        else {
            throw CodexDesktopAutomationStoreError.invalidRequest(
                "automation_project_not_found"
            )
        }
        return try rootValues.map { value in
            guard case let .string(root) = value,
                  !root.trimmingCharacters(
                      in: .whitespacesAndNewlines
                  ).isEmpty
            else {
                throw CodexDesktopAutomationStoreError.invalidRequest(
                    "invalid_project_root"
                )
            }
            return root
        }
    }

    private static func failure(
        _ request: CodexDesktopFetchRequest,
        message: String,
        code: String
    ) -> CodexDesktopHostMessage {
        .fetchFailure(
            requestID: request.requestID,
            status: 432,
            error: message,
            errorCode: code
        )
    }
}
