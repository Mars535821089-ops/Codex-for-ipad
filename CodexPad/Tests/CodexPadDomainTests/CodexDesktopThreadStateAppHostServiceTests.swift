import Foundation
import Testing

@testable import CodexPadApplication

private typealias ThreadStateValue = CodexDesktopAppHostRPC.Value

@Test
func desktopThreadStatePersistsPinsAndTurnSummaries() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let service = CodexDesktopThreadStateAppHostService(
        codexHome: root,
        principalIdentity: "principal-1"
    )

    #expect(
        try await service.invoke(
            service: "pinnedThreads",
            method: "set",
            arguments: [.object([
                "threadId": .string("thread-1"),
                "pinned": .bool(true),
            ])]
        ) == ThreadStateValue.object(["success": .bool(true)])
    )
    #expect(
        try await service.invoke(
            service: "pinnedThreads",
            method: "list",
            arguments: [.object([:])]
        ) == ThreadStateValue.object([
            "threadIds": .array([.string("thread-1")])
        ])
    )
    #expect(
        try await service.invoke(
            service: "threadTurnSummaries",
            method: "setSummary",
            arguments: [.object([
                "hostId": .string("local"),
                "threadId": .string("thread-1"),
                "summary": .string("  First   summary  "),
                "compactSummary": .string(" First "),
                "compactSummaryTurnKey": .string("turn-1"),
                "revision": .integer(1),
                "principalIdentity": .string("principal-1"),
            ])]
        ) == ThreadStateValue.bool(true)
    )
    #expect(
        try await service.invoke(
            service: "threadTurnSummaries",
            method: "readMany",
            arguments: [.object([
                "hostId": .string("local"),
                "threadIds": .array([.string("thread-1")]),
            ])]
        ) == ThreadStateValue.array([.object([
            "hostId": .string("local"),
            "threadId": .string("thread-1"),
            "summary": .string("First summary"),
            "compactSummary": .string("First"),
            "compactSummaryTurnKey": .string("turn-1"),
            "revision": .integer(1),
        ])])
    )
}

@Test
func desktopThreadStatePersistsRedactedSummaryCallDiagnostics()
    async throws
{
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let diagnostics = ThreadStateSummaryDiagnosticRecorder()
    let service = CodexDesktopThreadStateAppHostService(
        codexHome: root,
        principalIdentity: "private-principal",
        summaryDiagnostic: { key, value in
            await diagnostics.record(key: key, value: value)
        }
    )

    _ = try await service.invoke(
        service: "threadTurnSummaries",
        method: "getPrincipalIdentity",
        arguments: [.object([:])]
    )
    _ = try await service.invoke(
        service: "threadTurnSummaries",
        method: "setSummary",
        arguments: [.object([
            "hostId": .string("private-host"),
            "threadId": .string("private-thread"),
            "summary": .string("private summary"),
            "revision": .integer(1),
            "principalIdentity": .string("private-principal"),
        ])]
    )

    let values = await diagnostics.values
    #expect(
        values["codex.desktop.last-summary-principal-diagnostic"]
            == "called=true result=succeeded"
    )
    #expect(
        values["codex.desktop.last-summary-persistence-diagnostic"]
            == "called=true revision=1 summaryLength=15 compactLength=0 "
                + "result=succeeded"
    )
    #expect(!String(describing: values).contains("private"))
}

private actor ThreadStateSummaryDiagnosticRecorder {
    private(set) var values: [String: String] = [:]

    func record(key: String, value: String) {
        values[key] = value
    }
}

@Test
func desktopThreadStateInvalidationPublishesTombstoneAndPreservesDiskSummary()
    async throws
{
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let events = ThreadStateEventRecorder()
    let service = CodexDesktopThreadStateAppHostService(
        codexHome: root,
        principalIdentity: "principal-1",
        eventHandler: { service, method, arguments in
            await events.record(service: service, method: method, arguments: arguments)
        }
    )
    let summaryArguments: [String: ThreadStateValue] = [
        "hostId": .string("local"),
        "threadId": .string("thread-1"),
        "summary": .string("Summary"),
        "revision": .integer(3),
        "principalIdentity": .string("principal-1"),
    ]
    #expect(
        try await service.invoke(
            service: "threadTurnSummaries",
            method: "setSummary",
            arguments: [.object(summaryArguments)]
        ) == .bool(true)
    )
    try await service.invoke(
        service: "threadTurnSummaries",
        method: "invalidateSummaries",
        arguments: [.object(["hostId": .string("local")])]
    )
    let eventsAfterInvalidation = await events.values
    #expect(eventsAfterInvalidation.contains { event in
        event.service == "threadTurnSummaries"
            && event.method == "invalidateSummaries"
    })
    #expect(
        try await service.invoke(
            service: "threadTurnSummaries",
            method: "readMany",
            arguments: [.object([
                "hostId": .string("local"),
                "threadIds": .array([.string("thread-1")]),
            ])]
        ) == .array([.object([
            "hostId": .string("local"),
            "threadId": .string("thread-1"),
            "summary": .string("Summary"),
            "revision": .integer(3),
        ])])
    )
    #expect(
        try await service.invoke(
            service: "threadTurnSummaries",
            method: "setSummary",
            arguments: [.object([
                "hostId": .string("local"),
                "threadId": .string("thread-1"),
                "summary": .string("Stale"),
                "revision": .integer(3),
                "principalIdentity": .string("principal-1"),
            ])]
        ) == .bool(false)
    )
}

@Test
func desktopThreadStateDisposeRetainsPersistedStateAndRejectsCalls()
    async throws
{
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let service = CodexDesktopThreadStateAppHostService(
        codexHome: root,
        principalIdentity: "principal-1"
    )
    _ = try await service.invoke(
        service: "pinnedThreads",
        method: "set",
        arguments: [.object([
            "threadId": .string("thread-1"),
            "pinned": .bool(true),
        ])]
    )
    await service.dispose()
    do {
        _ = try await service.invoke(
            service: "pinnedThreads",
            method: "list",
            arguments: [.object([:])]
        )
        Issue.record("disposed service unexpectedly accepted an invocation")
    } catch let error as CodexDesktopThreadStateAppHostService.Error {
        #expect(
            error == .unsupportedMethod(
                service: "pinnedThreads",
                method: "list"
            )
        )
    }
    let restored = CodexDesktopThreadStateAppHostService(
        codexHome: root,
        principalIdentity: "principal-1"
    )
    #expect(
        try await restored.invoke(
            service: "pinnedThreads",
            method: "list",
            arguments: [.object([:])]
        ) == .object(["threadIds": .array([.string("thread-1")])])
    )
}

private actor ThreadStateEventRecorder {
    struct Event: Sendable {
        let service: String
        let method: String
        let arguments: [ThreadStateValue]?
    }

    private(set) var values: [Event] = []

    func record(service: String, method: String, arguments: [ThreadStateValue]?) {
        values.append(Event(service: service, method: method, arguments: arguments))
    }
}
