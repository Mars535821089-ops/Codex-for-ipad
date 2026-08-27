import CodexPadDomain
import Foundation
import Testing

@testable import CodexPadApplication

private func automationTemporaryCodexHome() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent(
            "CodexDesktopAutomationStoreTests-\(UUID().uuidString)",
            isDirectory: true
        )
    try FileManager.default.createDirectory(
        at: url,
        withIntermediateDirectories: true
    )
    return url
}

private func automationUTCDate(
    _ year: Int,
    _ month: Int,
    _ day: Int,
    _ hour: Int,
    _ minute: Int
) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar.date(
        from: DateComponents(
            timeZone: calendar.timeZone,
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute
        )
    )!
}

private var automationUTCCalendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    calendar.firstWeekday = 1
    return calendar
}

private func automationObject(
    _ value: CodexJSONValue
) throws -> [String: CodexJSONValue] {
    guard case let .object(fields) = value else {
        throw CodexDesktopAutomationStoreError.invalidRequest(
            "expected_object"
        )
    }
    return fields
}

private func cronAutomationParams(
    rrule: String
) -> [String: CodexJSONValue] {
    [
        "kind": .string("cron"),
        "name": .string("Morning review"),
        "prompt": .string("Review the project and summarize changes."),
        "projectId": .string("project-codexpad"),
        "executionEnvironment": .string("local"),
        "localEnvironmentConfigPath": .null,
        "model": .string("gpt-5.3-codex"),
        "pluginTemplateId": .null,
        "reasoningEffort": .string("medium"),
        "rrule": .string(rrule),
    ]
}

@Test
func automationStoreCreatesReleasedItemAndRestoresItAfterRestart()
    throws
{
    let codexHome = try automationTemporaryCodexHome()
    defer { try? FileManager.default.removeItem(at: codexHome) }
    let now = automationUTCDate(2026, 8, 2, 10, 0)
    let store = try CodexDesktopAutomationStore(
        codexHome: codexHome,
        calendar: automationUTCCalendar
    )

    let created = try automationObject(
        store.create(
            params: cronAutomationParams(
                rrule:
                    "FREQ=WEEKLY;BYDAY=MO,WE,FR;BYHOUR=9;BYMINUTE=15"
            ),
            defaultCWDs: ["/private/Workspace/CodexPad"],
            now: now
        )
    )
    guard case let .string(id)? = created["id"] else {
        Issue.record("create must return an automation id")
        return
    }

    #expect(created["kind"] == .string("cron"))
    #expect(created["status"] == .string("ACTIVE"))
    #expect(
        created["target"] == .object([
            "type": .string("project"),
            "projectId": .string("project-codexpad"),
        ])
    )
    #expect(
        created["cwds"] == .array([
            .string("/private/Workspace/CodexPad")
        ])
    )
    #expect(id == "morning-review")
    #expect(
        created["nextRunAt"] == .integer(
            Int64(
                automationUTCDate(
                    2026,
                    8,
                    3,
                    9,
                    15
                ).timeIntervalSince1970 * 1_000
            )
        )
    )
    #expect(
        FileManager.default.fileExists(
            atPath: codexHome
                .appendingPathComponent("automations", isDirectory: true)
                .appendingPathComponent(id, isDirectory: true)
                .appendingPathComponent("automation.toml")
                .path
        )
    )

    let restored = try CodexDesktopAutomationStore(
        codexHome: codexHome,
        calendar: automationUTCCalendar
    )
    #expect(restored.snapshot().items == [.object(created)])
}

@Test
func automationStorePauseAndResumeRecomputesTheRealNextRun()
    throws
{
    let codexHome = try automationTemporaryCodexHome()
    defer { try? FileManager.default.removeItem(at: codexHome) }
    let store = try CodexDesktopAutomationStore(
        codexHome: codexHome,
        calendar: automationUTCCalendar
    )
    let created = try automationObject(
        store.create(
            params: cronAutomationParams(
                rrule:
                    "FREQ=WEEKLY;BYDAY=MO,WE,FR;BYHOUR=9;BYMINUTE=15"
            ),
            defaultCWDs: ["/private/Workspace/CodexPad"],
            now: automationUTCDate(2026, 8, 2, 10, 0)
        )
    )
    guard case let .string(id)? = created["id"] else {
        Issue.record("create must return an automation id")
        return
    }

    var pausedParams = cronAutomationParams(
        rrule: "FREQ=WEEKLY;BYDAY=MO,WE,FR;BYHOUR=9;BYMINUTE=15"
    )
    pausedParams["id"] = .string(id)
    pausedParams["status"] = .string("PAUSED")
    let paused = try automationObject(
        store.update(
            params: pausedParams,
            defaultCWDs: ["/private/Workspace/CodexPad"],
            now: automationUTCDate(2026, 8, 2, 11, 0)
        )
    )
    #expect(paused["status"] == .string("PAUSED"))
    #expect(paused["nextRunAt"] == .null)
    #expect(paused["createdAt"] == created["createdAt"])

    pausedParams["status"] = .string("ACTIVE")
    let resumed = try automationObject(
        store.update(
            params: pausedParams,
            defaultCWDs: ["/private/Workspace/CodexPad"],
            now: automationUTCDate(2026, 8, 3, 10, 0)
        )
    )
    #expect(resumed["status"] == .string("ACTIVE"))
    #expect(
        resumed["nextRunAt"] == .integer(
            Int64(
                automationUTCDate(
                    2026,
                    8,
                    5,
                    9,
                    15
                ).timeIntervalSince1970 * 1_000
            )
        )
    )
}

@Test
func automationStoreDeleteUsesReleasedStatusContract() throws {
    let codexHome = try automationTemporaryCodexHome()
    defer { try? FileManager.default.removeItem(at: codexHome) }
    let store = try CodexDesktopAutomationStore(
        codexHome: codexHome,
        calendar: automationUTCCalendar
    )
    let created = try automationObject(
        store.create(
            params: cronAutomationParams(
                rrule: "FREQ=HOURLY;INTERVAL=1;BYMINUTE=0"
            ),
            defaultCWDs: ["/private/Workspace/CodexPad"],
            now: automationUTCDate(2026, 8, 2, 10, 15)
        )
    )
    guard case let .string(id)? = created["id"] else {
        Issue.record("create must return an automation id")
        return
    }

    let deleted = store.delete(
        id: id,
        now: automationUTCDate(2026, 8, 2, 10, 20)
    )
    #expect(deleted.success)
    #expect(deleted.status == "deleted")
    #expect(deleted.item == .object(created))
    #expect(store.snapshot().items.isEmpty)

    let missing = store.delete(
        id: id,
        now: automationUTCDate(2026, 8, 2, 10, 21)
    )
    #expect(missing.success)
    #expect(missing.status == "not_found")
    #expect(missing.item == nil)
}

@Test
func automationStoreEnforcesHeartbeatUniquenessAndReleasedUnionShape()
    throws
{
    let codexHome = try automationTemporaryCodexHome()
    defer { try? FileManager.default.removeItem(at: codexHome) }
    let store = try CodexDesktopAutomationStore(
        codexHome: codexHome,
        calendar: automationUTCCalendar
    )
    let params: [String: CodexJSONValue] = [
        "kind": .string("heartbeat"),
        "name": .string("Thread follow-up"),
        "prompt": .string("Check the latest result and follow up."),
        "targetThreadId": .string("thread-existing"),
        "model": .string("gpt-5.3-codex"),
        "reasoningEffort": .string("high"),
        "rrule": .string("FREQ=MINUTELY;INTERVAL=30"),
    ]
    let created = try automationObject(
        store.create(
            params: params,
            now: automationUTCDate(2026, 8, 2, 10, 0)
        )
    )

    #expect(created["id"] == .string("thread-follow-up"))
    #expect(created["model"] == .string("gpt-5.3-codex"))
    #expect(created["reasoningEffort"] == .string("high"))
    #expect(created["targetThreadId"] == .string("thread-existing"))
    #expect(created["cwds"] == nil)
    #expect(created["target"] == nil)

    #expect(throws: CodexDesktopAutomationStoreError.self) {
        try store.create(
            params: params.merging([
                "name": .string("Second follow-up")
            ]) { _, replacement in replacement },
            now: automationUTCDate(2026, 8, 2, 10, 1)
        )
    }
}

@Test
func automationStorePreservesOmittedCronLocalConfigAndAcceptsNullModel()
    throws
{
    let codexHome = try automationTemporaryCodexHome()
    defer { try? FileManager.default.removeItem(at: codexHome) }
    let store = try CodexDesktopAutomationStore(
        codexHome: codexHome,
        calendar: automationUTCCalendar
    )
    var createParams = cronAutomationParams(
        rrule: "FREQ=HOURLY;INTERVAL=1;BYMINUTE=0"
    )
    createParams["localEnvironmentConfigPath"] =
        .string("/private/config/local.toml")
    createParams["model"] = .null
    let created = try automationObject(
        store.create(
            params: createParams,
            defaultCWDs: ["/private/Workspace/CodexPad"],
            now: automationUTCDate(2026, 8, 2, 10, 15)
        )
    )
    guard case let .string(id)? = created["id"] else {
        Issue.record("create must return an automation id")
        return
    }

    var updateParams = createParams
    updateParams["id"] = .string(id)
    updateParams["status"] = .string("ACTIVE")
    updateParams.removeValue(forKey: "localEnvironmentConfigPath")
    let updated = try automationObject(
        store.update(
            params: updateParams,
            defaultCWDs: ["/private/Workspace/CodexPad"],
            now: automationUTCDate(2026, 8, 2, 10, 20)
        )
    )
    #expect(updated["model"] == .null)
    #expect(
        updated["localEnvironmentConfigPath"]
            == .string("/private/config/local.toml")
    )
}

@Test @MainActor
func automationSchedulerRunsDueItemAndPersistsInboxState() async throws {
    let codexHome = try automationTemporaryCodexHome()
    defer { try? FileManager.default.removeItem(at: codexHome) }
    let store = try CodexDesktopAutomationStore(
        codexHome: codexHome,
        calendar: automationUTCCalendar
    )
    let created = try automationObject(
        store.create(
            params: [
                "kind": .string("heartbeat"),
                "name": .string("Thread follow-up"),
                "prompt": .string("Check the latest result and follow up."),
                "targetThreadId": .string("thread-existing"),
                "model": .null,
                "reasoningEffort": .null,
                "rrule": .string("FREQ=MINUTELY;INTERVAL=30"),
            ],
            now: automationUTCDate(2026, 8, 2, 10, 0)
        )
    )
    guard case let .string(id)? = created["id"] else {
        Issue.record("create must return an automation id")
        return
    }
    var requestedAutomationIDs: [String] = []
    let scheduler = CodexDesktopAutomationScheduler(
        store: store,
        runner: { request in
            requestedAutomationIDs.append(request.automationID)
            return CodexDesktopAutomationExecution(
                threadID: request.targetThreadID,
                status: "PENDING_REVIEW"
            )
        }
    )

    await scheduler.runDue(
        at: automationUTCDate(2026, 8, 2, 10, 30)
    )

    #expect(requestedAutomationIDs == [id])
    let snapshot = store.snapshot()
    let updated = try automationObject(snapshot.items[0])
    #expect(
        updated["lastRunAt"] == .integer(
            Int64(
                automationUTCDate(
                    2026,
                    8,
                    2,
                    10,
                    30
                ).timeIntervalSince1970 * 1_000
            )
        )
    )
    #expect(
        updated["nextRunAt"] == .integer(
            Int64(
                automationUTCDate(
                    2026,
                    8,
                    2,
                    11,
                    0
                ).timeIntervalSince1970 * 1_000
            )
        )
    )
    #expect(snapshot.inboxItems.count == 1)
    let inboxItem = try automationObject(snapshot.inboxItems[0])
    #expect(
        Set(inboxItem.keys) == Set([
            "id",
            "automationId",
            "automationName",
            "title",
            "description",
            "archivedAssistantMessage",
            "archivedUserMessage",
            "archivedReason",
            "sourceCwd",
            "threadId",
            "readAt",
            "createdAt",
            "status",
        ])
    )
    #expect(
        inboxItem["description"]
            == .string("Check the latest result and follow up.")
    )
    #expect(snapshot.unreadRunCount == 1)
    #expect(snapshot.unreadAutomationIDs == [id])
    #expect(
        snapshot.unreadRuns == [
            .object([
                "automationId": .string(id),
                "threadId": .string("thread-existing"),
            ])
        ]
    )

    let restored = try CodexDesktopAutomationStore(
        codexHome: codexHome,
        calendar: automationUTCCalendar
    )
    #expect(restored.snapshot() == snapshot)
}

@Test @MainActor
func automationSchedulerRunsPersistedAutomationImmediately() async throws {
    let codexHome = try automationTemporaryCodexHome()
    defer { try? FileManager.default.removeItem(at: codexHome) }
    let store = try CodexDesktopAutomationStore(
        codexHome: codexHome,
        calendar: automationUTCCalendar
    )
    let created = try automationObject(
        store.create(
            params: cronAutomationParams(
                rrule: "FREQ=DAILY;BYHOUR=9;BYMINUTE=0"
            ),
            defaultCWDs: ["/private/Workspace/CodexPad"],
            now: automationUTCDate(2026, 8, 2, 10, 0)
        )
    )
    guard case let .string(id)? = created["id"] else {
        Issue.record("create must return an automation id")
        return
    }
    var requests: [CodexDesktopAutomationRunRequest] = []
    var stateChangeCount = 0
    let scheduler = CodexDesktopAutomationScheduler(
        store: store,
        onStateChange: {
            stateChangeCount += 1
        },
        runner: { request in
            requests.append(request)
            return CodexDesktopAutomationExecution(
                threadID: "thread-manual",
                status: "PENDING_REVIEW"
            )
        }
    )

    try await scheduler.runNow(
        automationID: id,
        at: automationUTCDate(2026, 8, 2, 10, 5)
    )

    #expect(requests.map(\.automationID) == [id])
    #expect(requests.first?.cwd == "/private/Workspace/CodexPad")
    #expect(stateChangeCount == 1)
    let snapshot = store.snapshot()
    #expect(snapshot.inboxItems.count == 1)
    let run = try automationObject(snapshot.inboxItems[0])
    #expect(run["threadId"] == .string("thread-manual"))
    #expect(run["status"] == .string("PENDING_REVIEW"))
}

@Test
func automationStoreArchivesAndDeletesRunByThreadID() throws {
    let codexHome = try automationTemporaryCodexHome()
    defer { try? FileManager.default.removeItem(at: codexHome) }
    let store = try CodexDesktopAutomationStore(
        codexHome: codexHome,
        calendar: automationUTCCalendar
    )
    let created = try automationObject(
        store.create(
            params: cronAutomationParams(
                rrule: "FREQ=HOURLY;INTERVAL=1;BYMINUTE=0"
            ),
            defaultCWDs: ["/private/Workspace/CodexPad"],
            now: automationUTCDate(2026, 8, 2, 10, 0)
        )
    )
    guard case let .string(id)? = created["id"] else {
        Issue.record("create must return an automation id")
        return
    }
    try store.recordRun(
        automationID: id,
        execution: CodexDesktopAutomationExecution(
            threadID: "thread-archive",
            status: "PENDING_REVIEW"
        ),
        now: automationUTCDate(2026, 8, 2, 10, 10)
    )

    #expect(
        try store.archiveRun(
            threadID: "thread-archive",
            archivedAssistantMessage: "Archived result",
            archivedUserMessage: "Run the review",
            reason: "user_archived"
        )
    )
    let archived = try automationObject(
        store.snapshot().inboxItems[0]
    )
    #expect(archived["status"] == .string("ARCHIVED"))
    #expect(
        archived["archivedAssistantMessage"]
            == .string("Archived result")
    )
    #expect(
        archived["archivedUserMessage"]
            == .string("Run the review")
    )
    #expect(
        archived["archivedReason"]
            == .string("user_archived")
    )
    #expect(store.snapshot().unreadRunCount == 0)

    #expect(try store.deleteRun(threadID: "thread-archive"))
    #expect(store.snapshot().inboxItems.isEmpty)
    #expect(
        try !store.deleteRun(threadID: "thread-archive")
    )
}
