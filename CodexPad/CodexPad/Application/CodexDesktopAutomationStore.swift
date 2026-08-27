#if SWIFT_PACKAGE
    import CodexPadDomain
#endif
import Foundation

public enum CodexDesktopAutomationStoreError:
    Error,
    Equatable,
    Sendable
{
    case invalidRequest(String)
    case automationNotFound(String)
    case scheduleHasNoFutureRun
    case storeUnavailable(String)
}

public struct CodexDesktopAutomationSnapshot:
    Equatable,
    Sendable
{
    public let items: [CodexJSONValue]
    public let inboxItems: [CodexJSONValue]
    public let unreadRunCount: Int64
    public let unreadAutomationIDs: [String]
    public let unreadRuns: [CodexJSONValue]

    public init(
        items: [CodexJSONValue],
        inboxItems: [CodexJSONValue],
        unreadRunCount: Int64,
        unreadAutomationIDs: [String],
        unreadRuns: [CodexJSONValue]
    ) {
        self.items = items
        self.inboxItems = inboxItems
        self.unreadRunCount = unreadRunCount
        self.unreadAutomationIDs = unreadAutomationIDs
        self.unreadRuns = unreadRuns
    }
}

public struct CodexDesktopAutomationDeleteResult:
    Equatable,
    Sendable
{
    public let item: CodexJSONValue?
    public let status: String
    public let success: Bool

    public init(
        item: CodexJSONValue?,
        status: String,
        success: Bool
    ) {
        self.item = item
        self.status = status
        self.success = success
    }
}

public struct CodexDesktopAutomationRunRequest:
    Equatable,
    Sendable
{
    public let automationID: String
    public let kind: String
    public let name: String
    public let prompt: String
    public let targetThreadID: String?
    public let projectID: String?
    public let cwd: String?
    public let model: String?
    public let reasoningEffort: String?
    public let lastRunAt: Int64?
    public let collaborationMode: CodexCollaborationMode?
    public let permissions: String?

    public init(
        automationID: String,
        kind: String,
        name: String,
        prompt: String,
        targetThreadID: String?,
        projectID: String?,
        cwd: String?,
        model: String?,
        reasoningEffort: String?,
        lastRunAt: Int64? = nil,
        collaborationMode: CodexCollaborationMode? = nil,
        permissions: String? = nil
    ) {
        self.automationID = automationID
        self.kind = kind
        self.name = name
        self.prompt = prompt
        self.targetThreadID = targetThreadID
        self.projectID = projectID
        self.cwd = cwd
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.lastRunAt = lastRunAt
        self.collaborationMode = collaborationMode
        self.permissions = permissions
    }

    public func applyingManualThreadSettings(
        collaborationMode: CodexCollaborationMode?,
        permissions: String?
    ) -> CodexDesktopAutomationRunRequest {
        CodexDesktopAutomationRunRequest(
            automationID: automationID,
            kind: kind,
            name: name,
            prompt: prompt,
            targetThreadID: targetThreadID,
            projectID: projectID,
            cwd: cwd,
            model: model,
            reasoningEffort: reasoningEffort,
            lastRunAt: lastRunAt,
            collaborationMode: collaborationMode,
            permissions: permissions
        )
    }
}

public struct CodexDesktopAutomationExecution:
    Equatable,
    Sendable
{
    public let threadID: String?
    public let status: String

    public init(
        threadID: String?,
        status: String
    ) {
        self.threadID = threadID
        self.status = status
    }
}

/// A file-backed store for the released desktop automation shapes.
///
/// The JSON state file is the transactional source of truth for scheduling
/// metadata and inbox runs. Each automation also gets the released
/// `$CODEX_HOME/automations/<id>/automation.toml` representation so agent
/// tools and users can inspect the persisted definition directly.
public final class CodexDesktopAutomationStore {
    private struct StoredTarget:
        Codable,
        Equatable,
        Sendable
    {
        var type: String
        var projectID: String?
    }

    private struct StoredAutomation:
        Codable,
        Equatable,
        Sendable
    {
        var version: Int
        var id: String
        var kind: String
        var name: String
        var prompt: String
        var status: String
        var rrule: String
        var executionEnvironment: String?
        var localEnvironmentConfigPath: String?
        var model: String?
        var reasoningEffort: String?
        var pluginTemplateID: String?
        var target: StoredTarget?
        var notificationPolicy: String?
        var cwds: [String]
        var targetThreadID: String?
        var createdAt: Int64
        var updatedAt: Int64
        var lastRunAt: Int64?
        var nextRunAt: Int64?
    }

    private struct StoredInboxItem:
        Codable,
        Equatable,
        Sendable
    {
        var id: String
        var automationID: String
        var automationName: String
        var title: String?
        var description: String?
        var archivedAssistantMessage: String?
        var archivedUserMessage: String?
        var archivedReason: String?
        var sourceCwd: String?
        var threadID: String?
        var status: String
        var readAt: Int64?
        var createdAt: Int64
    }

    private struct StoredState:
        Codable,
        Equatable,
        Sendable
    {
        var version: Int
        var automations: [StoredAutomation]
        var inboxItems: [StoredInboxItem]

        static let empty = StoredState(
            version: 1,
            automations: [],
            inboxItems: []
        )
    }

    private struct DecodedRequest {
        var kind: String
        var name: String
        var prompt: String
        var status: String
        var rrule: String
        var executionEnvironment: String?
        var localEnvironmentConfigPath: String?
        var model: String?
        var reasoningEffort: String?
        var pluginTemplateID: String?
        var notificationPolicy: String?
        var target: StoredTarget?
        var cwds: [String]
        var targetThreadID: String?
    }

    private let fileManager: FileManager
    private let calendar: Calendar
    private let automationsDirectory: URL
    private let stateURL: URL
    private var state: StoredState

    public init(
        codexHome: URL,
        fileManager: FileManager = .default,
        calendar: Calendar = .current
    ) throws {
        self.fileManager = fileManager
        self.calendar = calendar
        automationsDirectory = codexHome.appendingPathComponent(
            "automations",
            isDirectory: true
        )
        stateURL = automationsDirectory.appendingPathComponent(
            ".codexpad-automation-state.json"
        )

        do {
            try fileManager.createDirectory(
                at: automationsDirectory,
                withIntermediateDirectories: true
            )
            if fileManager.fileExists(atPath: stateURL.path) {
                let data = try Data(contentsOf: stateURL)
                state = try JSONDecoder().decode(
                    StoredState.self,
                    from: data
                )
            } else {
                state = .empty
            }
        } catch {
            throw CodexDesktopAutomationStoreError.storeUnavailable(
                String(describing: error)
            )
        }
    }

    public func snapshot() -> CodexDesktopAutomationSnapshot {
        let items = state.automations
            .sorted {
                if $0.updatedAt == $1.updatedAt {
                    return $0.id < $1.id
                }
                return $0.updatedAt > $1.updatedAt
            }
            .map(Self.jsonValue)
        let inboxItems = state.inboxItems
            .sorted {
                if $0.createdAt == $1.createdAt {
                    return $0.id < $1.id
                }
                return $0.createdAt > $1.createdAt
            }
        let unread = inboxItems.filter(Self.isUnreadAutomationRun)
        let unreadRuns = unread.compactMap {
            item -> CodexJSONValue? in
            guard let threadID = item.threadID else {
                return nil
            }
            return .object([
                "automationId": .string(item.automationID),
                "threadId": .string(threadID),
            ])
        }
        var seenAutomationIDs = Set<String>()
        let unreadAutomationIDs = unread.compactMap {
            item -> String? in
            guard seenAutomationIDs.insert(
                item.automationID
            ).inserted else {
                return nil
            }
            return item.automationID
        }
        return CodexDesktopAutomationSnapshot(
            items: items,
            inboxItems: inboxItems.map(Self.jsonValue),
            unreadRunCount: Int64(unread.count),
            unreadAutomationIDs: unreadAutomationIDs,
            unreadRuns: unreadRuns
        )
    }

    @discardableResult
    public func create(
        params: [String: CodexJSONValue],
        defaultCWDs: [String] = ["~"],
        now: Date = Date()
    ) throws -> CodexJSONValue {
        let decoded = try Self.decodeRequest(
            params,
            existing: nil,
            isCreate: true,
            defaultCWDs: defaultCWDs
        )
        guard decoded.status == "ACTIVE" else {
            throw CodexDesktopAutomationStoreError.invalidRequest(
                "create_status_must_be_active"
            )
        }
        try validateHeartbeatUniqueness(decoded)
        guard let nextRun = try CodexDesktopAutomationSchedule
            .nextRun(
                after: now,
                rrule: decoded.rrule,
                calendar: calendar
            )
        else {
            throw CodexDesktopAutomationStoreError
                .scheduleHasNoFutureRun
        }
        let timestamp = Self.milliseconds(now)
        let item = StoredAutomation(
            version: 1,
            id: uniqueAutomationID(for: decoded.name),
            kind: decoded.kind,
            name: decoded.name,
            prompt: decoded.prompt,
            status: decoded.status,
            rrule: decoded.rrule,
            executionEnvironment:
                decoded.executionEnvironment,
            localEnvironmentConfigPath:
                decoded.localEnvironmentConfigPath,
            model: decoded.model,
            reasoningEffort: decoded.reasoningEffort,
            pluginTemplateID: decoded.pluginTemplateID,
            target: decoded.target,
            notificationPolicy: decoded.notificationPolicy,
            cwds: decoded.cwds,
            targetThreadID: decoded.targetThreadID,
            createdAt: timestamp,
            updatedAt: timestamp,
            lastRunAt: nil,
            nextRunAt: Self.milliseconds(nextRun)
        )
        var nextState = state
        nextState.automations.append(item)
        try persist(nextState)
        state = nextState
        return Self.jsonValue(item)
    }

    @discardableResult
    public func update(
        params: [String: CodexJSONValue],
        defaultCWDs: [String] = ["~"],
        now: Date = Date()
    ) throws -> CodexJSONValue {
        let id = try Self.requiredString(params, "id")
        guard let index = state.automations.firstIndex(
            where: { $0.id == id }
        ) else {
            throw CodexDesktopAutomationStoreError
                .automationNotFound(id)
        }
        let existing = state.automations[index]
        let decoded = try Self.decodeRequest(
            params,
            existing: existing,
            isCreate: false,
            defaultCWDs: defaultCWDs
        )
        guard decoded.status == "ACTIVE"
                || decoded.status == "PAUSED"
        else {
            throw CodexDesktopAutomationStoreError.invalidRequest(
                "invalid_status"
            )
        }
        try validateHeartbeatUniqueness(
            decoded,
            excludingAutomationID: id
        )

        let nextRunAt: Int64?
        if decoded.status == "PAUSED" {
            nextRunAt = nil
        } else if existing.status == "ACTIVE",
                  existing.rrule == decoded.rrule
        {
            nextRunAt = existing.nextRunAt
        } else {
            guard let nextRun = try CodexDesktopAutomationSchedule
                .nextRun(
                    after: now,
                    rrule: decoded.rrule,
                    calendar: calendar
                )
            else {
                throw CodexDesktopAutomationStoreError
                    .scheduleHasNoFutureRun
            }
            nextRunAt = Self.milliseconds(nextRun)
        }

        var updated = existing
        updated.kind = decoded.kind
        updated.name = decoded.name
        updated.prompt = decoded.prompt
        updated.status = decoded.status
        updated.rrule = decoded.rrule
        updated.executionEnvironment =
            decoded.executionEnvironment
        updated.localEnvironmentConfigPath =
            decoded.localEnvironmentConfigPath
        updated.model = decoded.model
        updated.reasoningEffort = decoded.reasoningEffort
        updated.pluginTemplateID = decoded.pluginTemplateID
        updated.target = decoded.target
        updated.notificationPolicy = decoded.notificationPolicy
        updated.cwds = decoded.cwds
        updated.targetThreadID = decoded.targetThreadID
        updated.updatedAt = Self.milliseconds(now)
        updated.nextRunAt = nextRunAt

        var nextState = state
        nextState.automations[index] = updated
        try persist(nextState)
        state = nextState
        return Self.jsonValue(updated)
    }

    @discardableResult
    public func delete(
        id: String,
        now: Date = Date()
    ) -> CodexDesktopAutomationDeleteResult {
        guard Self.isValidAutomationID(id) else {
            return CodexDesktopAutomationDeleteResult(
                item: nil,
                status: "invalid_id",
                success: false
            )
        }
        guard let index = state.automations.firstIndex(
            where: { $0.id == id }
        ) else {
            return CodexDesktopAutomationDeleteResult(
                item: nil,
                status: "not_found",
                success: true
            )
        }

        _ = now
        let deleted = state.automations[index]
        var nextState = state
        nextState.automations.remove(at: index)
        do {
            try persist(nextState)
            state = nextState
        } catch {
            return CodexDesktopAutomationDeleteResult(
                item: Self.jsonValue(deleted),
                status: "state_cleanup_failed",
                success: false
            )
        }

        let directory = automationDirectory(id: id)
        if fileManager.fileExists(atPath: directory.path) {
            do {
                try fileManager.removeItem(at: directory)
            } catch {
                return CodexDesktopAutomationDeleteResult(
                    item: Self.jsonValue(deleted),
                    status: "remove_failed",
                    success: false
                )
            }
        }
        return CodexDesktopAutomationDeleteResult(
            item: Self.jsonValue(deleted),
            status: "deleted",
            success: true
        )
    }

    public func dueRunRequests(
        at now: Date = Date()
    ) -> [CodexDesktopAutomationRunRequest] {
        let timestamp = Self.milliseconds(now)
        return state.automations
            .filter {
                $0.status == "ACTIVE"
                    && ($0.nextRunAt ?? Int64.max) <= timestamp
            }
            .sorted {
                let lhs = $0.nextRunAt ?? Int64.max
                let rhs = $1.nextRunAt ?? Int64.max
                return lhs == rhs ? $0.id < $1.id : lhs < rhs
            }
            .map(Self.runRequest)
    }

    /// Resolves a released automation id to the same executable request used
    /// by the due-run scheduler. Manual runs intentionally use the persisted
    /// definition rather than a renderer-supplied copy.
    public func runRequest(
        automationID: String
    ) throws -> CodexDesktopAutomationRunRequest {
        guard Self.isValidAutomationID(automationID) else {
            throw CodexDesktopAutomationStoreError.invalidRequest(
                "invalid_automation_id"
            )
        }
        guard let automation = state.automations.first(
            where: { $0.id == automationID }
        ) else {
            throw CodexDesktopAutomationStoreError
                .automationNotFound(automationID)
        }
        return Self.runRequest(automation)
    }

    /// Persists the renderer's explicit archive payload against the run
    /// identified by its thread. The inbox item remains available for history
    /// and stops contributing to unread-review state.
    @discardableResult
    public func archiveRun(
        threadID: String,
        archivedAssistantMessage: String?,
        archivedUserMessage: String?,
        reason: String?
    ) throws -> Bool {
        guard !threadID.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty else {
            throw CodexDesktopAutomationStoreError.invalidRequest(
                "invalid_thread_id"
            )
        }
        guard let index = state.inboxItems.firstIndex(
            where: { $0.threadID == threadID }
        ) else {
            return false
        }
        var nextState = state
        nextState.inboxItems[index].archivedAssistantMessage =
            archivedAssistantMessage
        nextState.inboxItems[index].archivedUserMessage =
            archivedUserMessage
        nextState.inboxItems[index].archivedReason = reason
        nextState.inboxItems[index].status = "ARCHIVED"
        try persist(nextState)
        state = nextState
        return true
    }

    /// Deletes the persisted inbox run selected by the released renderer.
    @discardableResult
    public func deleteRun(
        threadID: String
    ) throws -> Bool {
        guard !threadID.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty else {
            throw CodexDesktopAutomationStoreError.invalidRequest(
                "invalid_thread_id"
            )
        }
        guard let index = state.inboxItems.firstIndex(
            where: { $0.threadID == threadID }
        ) else {
            return false
        }
        var nextState = state
        nextState.inboxItems.remove(at: index)
        try persist(nextState)
        state = nextState
        return true
    }

    public func secondsUntilNextRun(
        after now: Date = Date()
    ) -> TimeInterval? {
        let timestamp = Self.milliseconds(now)
        let next = state.automations
            .filter { $0.status == "ACTIVE" }
            .compactMap(\.nextRunAt)
            .min()
        guard let next else {
            return nil
        }
        return max(
            0,
            TimeInterval(next - timestamp) / 1_000
        )
    }

    public func recordRun(
        automationID: String,
        execution: CodexDesktopAutomationExecution,
        error: String? = nil,
        now: Date = Date()
    ) throws {
        guard let index = state.automations.firstIndex(
            where: { $0.id == automationID }
        ) else {
            throw CodexDesktopAutomationStoreError
                .automationNotFound(automationID)
        }
        var automation = state.automations[index]
        let timestamp = Self.milliseconds(now)
        automation.lastRunAt = timestamp
        automation.updatedAt = timestamp
        automation.nextRunAt =
            try CodexDesktopAutomationSchedule
                .nextRun(
                    after: now,
                    rrule: automation.rrule,
                    calendar: calendar
                )
                .map(Self.milliseconds)

        let inboxItem = StoredInboxItem(
            id: UUID().uuidString.lowercased(),
            automationID: automation.id,
            automationName: automation.name,
            title: automation.name,
            description: automation.prompt,
            archivedAssistantMessage: nil,
            archivedUserMessage: nil,
            archivedReason: error,
            sourceCwd: automation.cwds.first,
            threadID: execution.threadID,
            status: execution.status,
            readAt: nil,
            createdAt: timestamp
        )
        var nextState = state
        nextState.automations[index] = automation
        nextState.inboxItems.insert(inboxItem, at: 0)
        if nextState.inboxItems.count > 200 {
            nextState.inboxItems.removeLast(
                nextState.inboxItems.count - 200
            )
        }
        try persist(nextState)
        state = nextState
    }

    @discardableResult
    public func setInboxItemRead(
        id: String,
        isRead: Bool,
        now: Date = Date()
    ) throws -> Bool {
        guard let index = state.inboxItems.firstIndex(
            where: { $0.id == id }
        ) else {
            return false
        }
        var nextState = state
        nextState.inboxItems[index].readAt =
            isRead ? Self.milliseconds(now) : nil
        try persist(nextState)
        state = nextState
        return true
    }

    public func markAllAutomationRunsRead(
        at timestamp: Int64? = nil,
        now: Date = Date()
    ) throws {
        let readAt = timestamp ?? Self.milliseconds(now)
        var nextState = state
        for index in nextState.inboxItems.indices
        where nextState.inboxItems[index].readAt == nil
            && (
                nextState.inboxItems[index].status
                    == "PENDING_REVIEW"
                    || nextState.inboxItems[index].status
                    == "ACCEPTED"
                    || nextState.inboxItems[index].status
                    == "ARCHIVED"
            )
        {
            nextState.inboxItems[index].readAt = readAt
        }
        try persist(nextState)
        state = nextState
    }

    private func persist(_ nextState: StoredState) throws {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(nextState)
            try data.write(to: stateURL, options: .atomic)
            for automation in nextState.automations {
                let directory = automationDirectory(
                    id: automation.id
                )
                try fileManager.createDirectory(
                    at: directory,
                    withIntermediateDirectories: true
                )
                let toml = try Self.toml(automation)
                try Data(toml.utf8).write(
                    to: directory.appendingPathComponent(
                        "automation.toml"
                    ),
                    options: .atomic
                )
            }
        } catch {
            throw CodexDesktopAutomationStoreError.storeUnavailable(
                String(describing: error)
            )
        }
    }

    private func automationDirectory(id: String) -> URL {
        automationsDirectory.appendingPathComponent(
            id,
            isDirectory: true
        )
    }

    private func uniqueAutomationID(for name: String) -> String {
        var slug = name
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(
                of: "[^a-z0-9]+",
                with: "-",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: "-+",
                with: "-",
                options: .regularExpression
            )
            .trimmingCharacters(
                in: CharacterSet(charactersIn: "-")
            )
        if slug.isEmpty || slug == "." || slug == ".." {
            slug = "automation"
        }

        var existingIDs = Set(state.automations.map(\.id))
        if let entries = try? fileManager.contentsOfDirectory(
            at: automationsDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            for entry in entries {
                guard
                    (try? entry.resourceValues(
                        forKeys: [.isDirectoryKey]
                    ).isDirectory) == true
                else {
                    continue
                }
                existingIDs.insert(entry.lastPathComponent)
            }
        }
        guard existingIDs.contains(slug) else {
            return slug
        }
        for suffix in 2 ... 20 {
            let candidate = "\(slug)-\(suffix)"
            if !existingIDs.contains(candidate) {
                return candidate
            }
        }
        return "\(slug)-\(UUID().uuidString.lowercased().prefix(8))"
    }

    private func validateHeartbeatUniqueness(
        _ request: DecodedRequest,
        excludingAutomationID: String? = nil
    ) throws {
        guard request.kind == "heartbeat",
              request.status == "ACTIVE",
              let targetThreadID = request.targetThreadID,
              state.automations.contains(where: {
                  $0.id != excludingAutomationID
                      && $0.kind == "heartbeat"
                      && $0.status == "ACTIVE"
                      && $0.targetThreadID == targetThreadID
              })
        else {
            return
        }
        throw CodexDesktopAutomationStoreError.invalidRequest(
            "active_heartbeat_already_exists"
        )
    }

    private static func isValidAutomationID(_ id: String) -> Bool {
        !id.isEmpty
            && id != "."
            && id != ".."
            && !id.contains("/")
            && !id.contains("\\")
    }

    private static func decodeRequest(
        _ params: [String: CodexJSONValue],
        existing: StoredAutomation?,
        isCreate: Bool,
        defaultCWDs: [String]
    ) throws -> DecodedRequest {
        let kind = try requiredString(params, "kind")
        guard kind == "cron" || kind == "heartbeat" else {
            throw CodexDesktopAutomationStoreError.invalidRequest(
                "invalid_kind"
            )
        }
        let name = try requiredString(params, "name")
        let prompt = try requiredString(params, "prompt")
        let rrule = try requiredString(params, "rrule")
        let status: String
        if isCreate {
            status = "ACTIVE"
        } else {
            status = try requiredString(params, "status")
        }
        let notificationPolicy: String?
        if params.keys.contains("notificationPolicy") {
            notificationPolicy = try optionalString(
                params,
                "notificationPolicy"
            )
        } else {
            notificationPolicy = existing?.notificationPolicy
        }
        if let notificationPolicy,
           notificationPolicy != "failed_runs_only"
        {
            throw CodexDesktopAutomationStoreError.invalidRequest(
                "invalid_notification_policy"
            )
        }
        let model = try nullableTrimmedString(params, "model")
        let reasoningEffort = try optionalString(
            params,
            "reasoningEffort"
        )
        if let reasoningEffort,
           ![
               "none",
               "minimal",
               "low",
               "medium",
               "high",
               "xhigh",
               "max",
               "ultra",
           ].contains(reasoningEffort)
        {
            throw CodexDesktopAutomationStoreError.invalidRequest(
                "invalid_reasoningEffort"
            )
        }

        if kind == "heartbeat" {
            let targetThreadID = try requiredString(
                params,
                "targetThreadId"
            )
            return DecodedRequest(
                kind: kind,
                name: name,
                prompt: prompt,
                status: status,
                rrule: rrule,
                executionEnvironment: nil,
                localEnvironmentConfigPath: nil,
                model: model,
                reasoningEffort: reasoningEffort,
                pluginTemplateID: nil,
                notificationPolicy: notificationPolicy,
                target: nil,
                cwds: [],
                targetThreadID: targetThreadID
            )
        }

        let executionEnvironment = try requiredString(
            params,
            "executionEnvironment"
        )
        guard executionEnvironment == "local"
                || (!isCreate
                    && executionEnvironment == "worktree")
        else {
            throw CodexDesktopAutomationStoreError.invalidRequest(
                "invalid_execution_environment"
            )
        }
        let projectID = try optionalString(params, "projectId")
        let explicitCWDs: [String]?
        if params.keys.contains("cwds") {
            explicitCWDs = try stringArray(params, "cwds")
        } else {
            explicitCWDs = nil
        }
        let target = explicitCWDs == nil
            ? StoredTarget(
                type: projectID == nil
                    ? "projectless"
                    : "project",
                projectID: projectID
            )
            : nil
        let cwds = explicitCWDs ?? defaultCWDs
        let pluginTemplateID: String?
        if params.keys.contains("pluginTemplateId") {
            pluginTemplateID = try nullableTrimmedString(
                params,
                "pluginTemplateId"
            )
        } else {
            pluginTemplateID = existing?.pluginTemplateID
        }
        return DecodedRequest(
            kind: kind,
            name: name,
            prompt: prompt,
            status: status,
            rrule: rrule,
            executionEnvironment: executionEnvironment,
            localEnvironmentConfigPath: params.keys.contains(
                "localEnvironmentConfigPath"
            )
                ? try nullableTrimmedString(
                    params,
                    "localEnvironmentConfigPath"
                )
                : existing?.localEnvironmentConfigPath,
            model: model,
            reasoningEffort: reasoningEffort,
            pluginTemplateID: pluginTemplateID,
            notificationPolicy: notificationPolicy,
            target: target,
            cwds: cwds,
            targetThreadID: nil
        )
    }

    private static func requiredString(
        _ params: [String: CodexJSONValue],
        _ key: String
    ) throws -> String {
        guard case let .string(value)? = params[key],
              !value.trimmingCharacters(
                  in: .whitespacesAndNewlines
              ).isEmpty
        else {
            throw CodexDesktopAutomationStoreError.invalidRequest(
                "invalid_\(key)"
            )
        }
        return value
    }

    private static func optionalString(
        _ params: [String: CodexJSONValue],
        _ key: String
    ) throws -> String? {
        guard let value = params[key] else {
            return nil
        }
        switch value {
        case .null:
            return nil
        case let .string(string):
            guard !string.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).isEmpty else {
                throw CodexDesktopAutomationStoreError
                    .invalidRequest("invalid_\(key)")
            }
            return string
        default:
            throw CodexDesktopAutomationStoreError.invalidRequest(
                "invalid_\(key)"
            )
        }
    }

    private static func nullableTrimmedString(
        _ params: [String: CodexJSONValue],
        _ key: String
    ) throws -> String? {
        guard let value = params[key] else {
            return nil
        }
        switch value {
        case .null:
            return nil
        case let .string(string):
            let trimmed = string.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            return trimmed.isEmpty ? nil : trimmed
        default:
            throw CodexDesktopAutomationStoreError.invalidRequest(
                "invalid_\(key)"
            )
        }
    }

    private static func stringArray(
        _ params: [String: CodexJSONValue],
        _ key: String
    ) throws -> [String] {
        guard case let .array(values)? = params[key] else {
            throw CodexDesktopAutomationStoreError.invalidRequest(
                "invalid_\(key)"
            )
        }
        return try values.map { value in
            guard case let .string(string) = value,
                  !string.trimmingCharacters(
                      in: .whitespacesAndNewlines
                  ).isEmpty
            else {
                throw CodexDesktopAutomationStoreError.invalidRequest(
                    "invalid_\(key)"
                )
            }
            return string
        }
    }

    private static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000).rounded())
    }

    private static func jsonValue(
        _ item: StoredAutomation
    ) -> CodexJSONValue {
        var fields: [String: CodexJSONValue] = [
            "id": .string(item.id),
            "kind": .string(item.kind),
            "name": .string(item.name),
            "prompt": .string(item.prompt),
            "status": .string(item.status),
            "rrule": .string(item.rrule),
            "createdAt": .integer(item.createdAt),
            "updatedAt": .integer(item.updatedAt),
            "lastRunAt": item.lastRunAt.map(
                CodexJSONValue.integer
            ) ?? .null,
            "nextRunAt": item.nextRunAt.map(
                CodexJSONValue.integer
            ) ?? .null,
        ]
        if let notificationPolicy = item.notificationPolicy {
            fields["notificationPolicy"] =
                .string(notificationPolicy)
        }
        if item.kind == "heartbeat" {
            fields["targetThreadId"] = item.targetThreadID.map(
                CodexJSONValue.string
            ) ?? .null
            fields["model"] = item.model.map(
                CodexJSONValue.string
            ) ?? .null
            fields["reasoningEffort"] =
                item.reasoningEffort.map(
                    CodexJSONValue.string
                ) ?? .null
        } else {
            fields["cwds"] = .array(
                item.cwds.map(CodexJSONValue.string)
            )
            fields["executionEnvironment"] =
                item.executionEnvironment.map(
                    CodexJSONValue.string
                ) ?? .null
            fields["localEnvironmentConfigPath"] =
                item.localEnvironmentConfigPath.map(
                    CodexJSONValue.string
                ) ?? .null
            fields["model"] = item.model.map(
                CodexJSONValue.string
            ) ?? .null
            fields["reasoningEffort"] =
                item.reasoningEffort.map(
                    CodexJSONValue.string
                ) ?? .null
            fields["pluginTemplateId"] =
                item.pluginTemplateID.map(
                    CodexJSONValue.string
                ) ?? .null
            if let target = item.target {
                var targetFields: [String: CodexJSONValue] = [
                    "type": .string(target.type)
                ]
                if let projectID = target.projectID {
                    targetFields["projectId"] = .string(projectID)
                }
                fields["target"] = .object(targetFields)
            } else {
                fields["target"] = .null
            }
        }
        return .object(fields)
    }

    private static func runRequest(
        _ item: StoredAutomation
    ) -> CodexDesktopAutomationRunRequest {
        CodexDesktopAutomationRunRequest(
            automationID: item.id,
            kind: item.kind,
            name: item.name,
            prompt: item.prompt,
            targetThreadID: item.targetThreadID,
            projectID: item.target?.projectID,
            cwd: item.cwds.first,
            model: item.model,
            reasoningEffort: item.reasoningEffort,
            lastRunAt: item.lastRunAt
        )
    }

    private static func jsonValue(
        _ item: StoredInboxItem
    ) -> CodexJSONValue {
        .object([
            "id": .string(item.id),
            "automationId": .string(item.automationID),
            "automationName": .string(item.automationName),
            "title": .string(item.title ?? item.automationName),
            "description": item.description.map(
                CodexJSONValue.string
            ) ?? .null,
            "archivedAssistantMessage":
                item.archivedAssistantMessage.map(
                    CodexJSONValue.string
                ) ?? .null,
            "archivedUserMessage":
                item.archivedUserMessage.map(
                    CodexJSONValue.string
                ) ?? .null,
            "archivedReason": item.archivedReason.map(
                CodexJSONValue.string
            ) ?? .null,
            "sourceCwd": item.sourceCwd.map(
                CodexJSONValue.string
            ) ?? .null,
            "threadId": item.threadID.map(
                CodexJSONValue.string
            ) ?? .null,
            "status": .string(item.status),
            "readAt": item.readAt.map(
                CodexJSONValue.integer
            ) ?? .null,
            "createdAt": .integer(item.createdAt),
        ])
    }

    private static func isUnreadAutomationRun(
        _ item: StoredInboxItem
    ) -> Bool {
        item.readAt == nil
            && (
                item.status == "PENDING_REVIEW"
                    || item.status == "ACCEPTED"
            )
    }

    private static func toml(
        _ item: StoredAutomation
    ) throws -> String {
        var lines = [
            "version = \(item.version)",
            "id = \(try tomlString(item.id))",
            "kind = \(try tomlString(item.kind))",
            "name = \(try tomlString(item.name))",
            "prompt = \(try tomlString(item.prompt))",
            "status = \(try tomlString(item.status))",
            "rrule = \(try tomlString(item.rrule))",
        ]
        if let value = item.executionEnvironment {
            lines.append(
                "execution_environment = \(try tomlString(value))"
            )
        }
        if let value = item.localEnvironmentConfigPath {
            lines.append(
                "local_environment_config_path = \(try tomlString(value))"
            )
        }
        if let value = item.model {
            lines.append("model = \(try tomlString(value))")
        }
        if let value = item.reasoningEffort {
            lines.append(
                "reasoning_effort = \(try tomlString(value))"
            )
        }
        if let value = item.pluginTemplateID {
            lines.append(
                "plugin_template_id = \(try tomlString(value))"
            )
        }
        if let value = item.notificationPolicy {
            lines.append(
                "notification_policy = \(try tomlString(value))"
            )
        }
        if let value = item.targetThreadID {
            lines.append(
                "target_thread_id = \(try tomlString(value))"
            )
        }
        lines.append(
            "cwds = [\(try item.cwds.map(tomlString).joined(separator: ", "))]"
        )
        lines.append("created_at = \(item.createdAt)")
        lines.append("updated_at = \(item.updatedAt)")
        if let target = item.target {
            lines.append("")
            lines.append("[target]")
            lines.append(
                "type = \(try tomlString(target.type))"
            )
            if let projectID = target.projectID {
                lines.append(
                    "project_id = \(try tomlString(projectID))"
                )
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func tomlString(_ value: String) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let data = try encoder.encode(value)
        guard let string = String(data: data, encoding: .utf8) else {
            throw CodexDesktopAutomationStoreError
                .storeUnavailable("toml_string_encoding")
        }
        return string
    }
}

public enum CodexDesktopAutomationSchedule {
    private struct Rule {
        var frequency: String
        var interval: Int
        var weekdays: Set<Int>?
        var hours: [Int]?
        var minutes: [Int]?
        var monthDays: [Int]?
        var months: [Int]?
        var until: Date?
        var start: Date?
    }

    public static func nextRun(
        after date: Date,
        rrule: String,
        calendar: Calendar = .current
    ) throws -> Date? {
        let rule = try parse(rrule, calendar: calendar)
        let next: Date?
        switch rule.frequency {
        case "MINUTELY":
            next = nextMinutely(
                after: date,
                rule: rule,
                calendar: calendar
            )
        case "HOURLY":
            next = nextHourly(
                after: date,
                rule: rule,
                calendar: calendar
            )
        case "DAILY":
            next = nextDaily(
                after: date,
                rule: rule,
                calendar: calendar
            )
        case "WEEKLY":
            next = nextWeekly(
                after: date,
                rule: rule,
                calendar: calendar
            )
        case "MONTHLY":
            next = nextMonthly(
                after: date,
                rule: rule,
                calendar: calendar
            )
        case "YEARLY":
            next = nextYearly(
                after: date,
                rule: rule,
                calendar: calendar
            )
        default:
            throw CodexDesktopAutomationStoreError.invalidRequest(
                "unsupported_rrule_frequency"
            )
        }
        guard let next else {
            return nil
        }
        if let until = rule.until, next > until {
            return nil
        }
        return next
    }

    private static func parse(
        _ text: String,
        calendar: Calendar
    ) throws -> Rule {
        var fields: [String: String] = [:]
        var start: Date?
        for rawLine in text
            .replacingOccurrences(of: "\r", with: "")
            .split(separator: "\n")
        {
            var line = String(rawLine)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if line.uppercased().hasPrefix("DTSTART") {
                guard let separator = line.firstIndex(of: ":") else {
                    throw CodexDesktopAutomationStoreError
                        .invalidRequest("invalid_dtstart")
                }
                start = parseDate(
                    String(line[line.index(after: separator)...]),
                    calendar: calendar
                )
                guard start != nil else {
                    throw CodexDesktopAutomationStoreError
                        .invalidRequest("invalid_dtstart")
                }
                continue
            }
            if line.uppercased().hasPrefix("RRULE:") {
                line = String(line.dropFirst("RRULE:".count))
            }
            for pair in line.split(separator: ";") {
                let pieces = pair.split(
                    separator: "=",
                    maxSplits: 1
                )
                guard pieces.count == 2 else {
                    throw CodexDesktopAutomationStoreError
                        .invalidRequest("invalid_rrule")
                }
                fields[String(pieces[0]).uppercased()] =
                    String(pieces[1]).uppercased()
            }
        }
        guard let frequency = fields["FREQ"] else {
            throw CodexDesktopAutomationStoreError.invalidRequest(
                "missing_rrule_frequency"
            )
        }
        let interval = Int(fields["INTERVAL"] ?? "1") ?? 0
        guard interval > 0 else {
            throw CodexDesktopAutomationStoreError.invalidRequest(
                "invalid_rrule_interval"
            )
        }
        let weekdays = try fields["BYDAY"].map(
            parseWeekdays
        )
        return Rule(
            frequency: frequency,
            interval: interval,
            weekdays: weekdays,
            hours: try fields["BYHOUR"].map {
                try parseIntegers(
                    $0,
                    range: 0 ... 23,
                    key: "BYHOUR"
                )
            },
            minutes: try fields["BYMINUTE"].map {
                try parseIntegers(
                    $0,
                    range: 0 ... 59,
                    key: "BYMINUTE"
                )
            },
            monthDays: try fields["BYMONTHDAY"].map {
                try parseIntegers(
                    $0,
                    range: 1 ... 31,
                    key: "BYMONTHDAY"
                )
            },
            months: try fields["BYMONTH"].map {
                try parseIntegers(
                    $0,
                    range: 1 ... 12,
                    key: "BYMONTH"
                )
            },
            until: fields["UNTIL"].flatMap {
                parseDate($0, calendar: calendar)
            },
            start: start
        )
    }

    private static func parseIntegers(
        _ value: String,
        range: ClosedRange<Int>,
        key: String
    ) throws -> [Int] {
        let values = value.split(separator: ",").compactMap {
            Int($0)
        }
        guard !values.isEmpty,
              values.allSatisfy(range.contains)
        else {
            throw CodexDesktopAutomationStoreError.invalidRequest(
                "invalid_\(key.lowercased())"
            )
        }
        return Array(Set(values)).sorted()
    }

    private static func parseWeekdays(
        _ value: String
    ) throws -> Set<Int> {
        let mapping = [
            "SU": 1,
            "MO": 2,
            "TU": 3,
            "WE": 4,
            "TH": 5,
            "FR": 6,
            "SA": 7,
        ]
        let tokens = value.split(separator: ",").map(String.init)
        let days = tokens.compactMap { mapping[$0] }
        guard !days.isEmpty, days.count == tokens.count else {
            throw CodexDesktopAutomationStoreError.invalidRequest(
                "invalid_byday"
            )
        }
        return Set(days)
    }

    private static func parseDate(
        _ value: String,
        calendar: Calendar
    ) -> Date? {
        let formats = [
            "yyyyMMdd'T'HHmmss'Z'",
            "yyyyMMdd'T'HHmmss",
            "yyyyMMdd",
        ]
        for format in formats {
            let formatter = DateFormatter()
            formatter.calendar = calendar
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone =
                value.hasSuffix("Z")
                ? TimeZone(secondsFromGMT: 0)
                : calendar.timeZone
            formatter.dateFormat = format
            if let date = formatter.date(from: value) {
                return date
            }
        }
        return nil
    }

    private static func nextMinutely(
        after date: Date,
        rule: Rule,
        calendar: Calendar
    ) -> Date? {
        let anchor = rule.start ?? date
        let candidateValue = rule.start ?? calendar.date(
            byAdding: .minute,
            value: rule.interval,
            to: date
        )
        guard var candidate = candidateValue else {
            return nil
        }
        if rule.start != nil, candidate <= date {
            let elapsed = max(
                0,
                Int(date.timeIntervalSince(anchor) / 60)
            )
            let steps = elapsed / rule.interval + 1
            guard let advanced = calendar.date(
                byAdding: .minute,
                value: steps * rule.interval,
                to: anchor
            ) else {
                return nil
            }
            candidate = advanced
        }
        for _ in 0 ..< 5_300_000 {
            if matches(candidate, rule: rule, calendar: calendar) {
                return candidate
            }
            guard let advanced = calendar.date(
                byAdding: .minute,
                value: rule.interval,
                to: candidate
            ) else {
                return nil
            }
            candidate = advanced
        }
        return nil
    }

    private static func nextHourly(
        after date: Date,
        rule: Rule,
        calendar: Calendar
    ) -> Date? {
        let anchor = calendar.dateInterval(
            of: .hour,
            for: rule.start ?? date
        )?.start ?? date
        let minuteValues = rule.minutes ?? [
            calendar.component(.minute, from: rule.start ?? date)
        ]
        for hourOffset in 0 ..< 87_600 {
            guard hourOffset % rule.interval == 0,
                  let hour = calendar.date(
                      byAdding: .hour,
                      value: hourOffset,
                      to: anchor
                  )
            else {
                continue
            }
            for minute in minuteValues {
                guard let candidate = calendar.date(
                    bySetting: .minute,
                    value: minute,
                    of: hour
                ), candidate > date else {
                    continue
                }
                if matches(
                    candidate,
                    rule: rule,
                    calendar: calendar
                ) {
                    return candidate
                }
            }
        }
        return nil
    }

    private static func nextDaily(
        after date: Date,
        rule: Rule,
        calendar: Calendar
    ) -> Date? {
        let anchor = calendar.startOfDay(
            for: rule.start ?? date
        )
        for dayOffset in 0 ..< 3_660
        where dayOffset % rule.interval == 0 {
            guard let day = calendar.date(
                byAdding: .day,
                value: dayOffset,
                to: anchor
            ) else {
                continue
            }
            if let candidate = firstCandidate(
                on: day,
                after: date,
                rule: rule,
                calendar: calendar
            ) {
                return candidate
            }
        }
        return nil
    }

    private static func nextWeekly(
        after date: Date,
        rule: Rule,
        calendar: Calendar
    ) -> Date? {
        var weekCalendar = calendar
        weekCalendar.firstWeekday = 1
        let anchorDate = rule.start ?? date
        let anchorWeek = weekCalendar.dateInterval(
            of: .weekOfYear,
            for: anchorDate
        )?.start ?? weekCalendar.startOfDay(for: anchorDate)
        let defaultWeekday = weekCalendar.component(
            .weekday,
            from: anchorDate
        )
        let weekdays = rule.weekdays ?? [defaultWeekday]
        for weekOffset in 0 ..< 522
        where weekOffset % rule.interval == 0 {
            guard let week = weekCalendar.date(
                byAdding: .weekOfYear,
                value: weekOffset,
                to: anchorWeek
            ) else {
                continue
            }
            for weekday in weekdays.sorted() {
                let dayOffset = (
                    weekday - weekCalendar.firstWeekday + 7
                ) % 7
                guard let day = weekCalendar.date(
                    byAdding: .day,
                    value: dayOffset,
                    to: week
                ) else {
                    continue
                }
                if let candidate = firstCandidate(
                    on: day,
                    after: date,
                    rule: rule,
                    calendar: weekCalendar
                ) {
                    return candidate
                }
            }
        }
        return nil
    }

    private static func nextMonthly(
        after date: Date,
        rule: Rule,
        calendar: Calendar
    ) -> Date? {
        let anchor = calendar.date(
            from: calendar.dateComponents(
                [.year, .month],
                from: rule.start ?? date
            )
        ) ?? date
        let defaultDay = calendar.component(
            .day,
            from: rule.start ?? date
        )
        let monthDays = rule.monthDays ?? [defaultDay]
        for monthOffset in 0 ..< 120
        where monthOffset % rule.interval == 0 {
            guard let month = calendar.date(
                byAdding: .month,
                value: monthOffset,
                to: anchor
            ) else {
                continue
            }
            for monthDay in monthDays {
                var components = calendar.dateComponents(
                    [.year, .month],
                    from: month
                )
                components.day = monthDay
                guard let day = calendar.date(from: components),
                      calendar.component(.day, from: day)
                        == monthDay
                else {
                    continue
                }
                if let candidate = firstCandidate(
                    on: day,
                    after: date,
                    rule: rule,
                    calendar: calendar
                ) {
                    return candidate
                }
            }
        }
        return nil
    }

    private static func nextYearly(
        after date: Date,
        rule: Rule,
        calendar: Calendar
    ) -> Date? {
        let reference = rule.start ?? date
        let anchorYear = calendar.component(.year, from: reference)
        let months = rule.months ?? [
            calendar.component(.month, from: reference)
        ]
        let monthDays = rule.monthDays ?? [
            calendar.component(.day, from: reference)
        ]
        for yearOffset in 0 ..< 50
        where yearOffset % rule.interval == 0 {
            for month in months {
                for day in monthDays {
                    let components = DateComponents(
                        timeZone: calendar.timeZone,
                        year: anchorYear + yearOffset,
                        month: month,
                        day: day
                    )
                    guard let dateInYear = calendar.date(
                        from: components
                    ), calendar.component(.month, from: dateInYear)
                        == month,
                        calendar.component(.day, from: dateInYear)
                            == day
                    else {
                        continue
                    }
                    if let candidate = firstCandidate(
                        on: dateInYear,
                        after: date,
                        rule: rule,
                        calendar: calendar
                    ) {
                        return candidate
                    }
                }
            }
        }
        return nil
    }

    private static func firstCandidate(
        on day: Date,
        after date: Date,
        rule: Rule,
        calendar: Calendar
    ) -> Date? {
        guard matchesDay(day, rule: rule, calendar: calendar)
        else {
            return nil
        }
        let reference = rule.start ?? date
        let hours = rule.hours ?? [
            calendar.component(.hour, from: reference)
        ]
        let minutes = rule.minutes ?? [
            calendar.component(.minute, from: reference)
        ]
        for hour in hours.sorted() {
            for minute in minutes.sorted() {
                var components = calendar.dateComponents(
                    [.year, .month, .day],
                    from: day
                )
                components.timeZone = calendar.timeZone
                components.hour = hour
                components.minute = minute
                components.second =
                    rule.start.map {
                        calendar.component(.second, from: $0)
                    } ?? 0
                guard let candidate = calendar.date(
                    from: components
                ), candidate > date else {
                    continue
                }
                if matches(
                    candidate,
                    rule: rule,
                    calendar: calendar
                ) {
                    return candidate
                }
            }
        }
        return nil
    }

    private static func matches(
        _ date: Date,
        rule: Rule,
        calendar: Calendar
    ) -> Bool {
        guard matchesDay(
            date,
            rule: rule,
            calendar: calendar
        ) else {
            return false
        }
        if let hours = rule.hours,
           !hours.contains(calendar.component(.hour, from: date))
        {
            return false
        }
        if let minutes = rule.minutes,
           !minutes.contains(calendar.component(.minute, from: date))
        {
            return false
        }
        return true
    }

    private static func matchesDay(
        _ date: Date,
        rule: Rule,
        calendar: Calendar
    ) -> Bool {
        if let weekdays = rule.weekdays,
           !weekdays.contains(
               calendar.component(.weekday, from: date)
           )
        {
            return false
        }
        if let monthDays = rule.monthDays,
           !monthDays.contains(
               calendar.component(.day, from: date)
           )
        {
            return false
        }
        if let months = rule.months,
           !months.contains(
               calendar.component(.month, from: date)
           )
        {
            return false
        }
        return true
    }
}

/// Runs due automations serially while the app process is active.
///
/// The runner is injected so the scheduler records a run only after the app
/// has actually started the corresponding local Codex thread/turn.
@MainActor
public final class CodexDesktopAutomationScheduler {
    public typealias Runner =
        (CodexDesktopAutomationRunRequest) async throws
            -> CodexDesktopAutomationExecution

    private let store: CodexDesktopAutomationStore
    private let runner: Runner
    private let now: () -> Date
    private let onStateChange: (() async -> Void)?
    private var loopTask: Task<Void, Never>?
    private var runningAutomationIDs = Set<String>()

    public init(
        store: CodexDesktopAutomationStore,
        now: @escaping () -> Date = Date.init,
        onStateChange: (() async -> Void)? = nil,
        runner: @escaping Runner
    ) {
        self.store = store
        self.now = now
        self.onStateChange = onStateChange
        self.runner = runner
    }

    deinit {
        loopTask?.cancel()
    }

    public func start() {
        guard loopTask == nil else {
            return
        }
        loopTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else {
                    return
                }
                await runDue(at: now())
                let delay = store.secondsUntilNextRun(
                    after: now()
                ) ?? 60
                do {
                    try await Task.sleep(
                        for: .seconds(
                            max(1, min(delay, 60))
                        )
                    )
                } catch {
                    return
                }
            }
        }
    }

    public func stop() {
        loopTask?.cancel()
        loopTask = nil
    }

    public func runDue(
        at date: Date = Date()
    ) async {
        let requests = store.dueRunRequests(at: date)
        for request in requests {
            try? await execute(
                request,
                at: date
            )
        }
    }

    /// Executes the current persisted automation immediately through the same
    /// real thread/turn runner used by scheduled runs.
    public func runNow(
        automationID: String,
        collaborationMode: CodexCollaborationMode? = nil,
        permissions: String? = nil,
        at date: Date = Date()
    ) async throws {
        let request = try store.runRequest(
            automationID: automationID
        ).applyingManualThreadSettings(
            collaborationMode: collaborationMode,
            permissions: permissions
        )
        try await execute(
            request,
            at: date
        )
    }

    private func execute(
        _ request: CodexDesktopAutomationRunRequest,
        at date: Date
    ) async throws {
        guard runningAutomationIDs.insert(
            request.automationID
        ).inserted else {
            throw CodexDesktopAutomationStoreError.invalidRequest(
                "automation_already_running"
            )
        }
        defer {
            runningAutomationIDs.remove(
                request.automationID
            )
        }
        do {
            let execution = try await runner(request)
            try store.recordRun(
                automationID: request.automationID,
                execution: execution,
                now: date
            )
            await onStateChange?()
        } catch {
            try? store.recordRun(
                automationID: request.automationID,
                execution: CodexDesktopAutomationExecution(
                    threadID: nil,
                    status: "ARCHIVED"
                ),
                error: String(describing: error),
                now: date
            )
            await onStateChange?()
            throw error
        }
    }
}
