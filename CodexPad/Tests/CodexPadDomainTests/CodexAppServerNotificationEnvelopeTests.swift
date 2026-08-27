import CodexPadDomain
import CodexPadApplication
import CodexPadProtocolBridge
import Foundation
import Testing

private let officialNotificationSamples: [(String, String)] = [
    (
        "thread/started",
        #"{"thread":{"id":"thread-1","status":{"type":"idle"}}}"#
    ),
    (
        "thread/status/changed",
        #"{"threadId":"thread-1","status":{"type":"active","activeFlags":["waitingOnUserInput"]}}"#
    ),
    ("thread/archived", #"{"threadId":"thread-1"}"#),
    ("thread/deleted", #"{"threadId":"thread-1"}"#),
    ("thread/unarchived", #"{"threadId":"thread-1"}"#),
    ("thread/closed", #"{"threadId":"thread-1"}"#),
    (
        "thread/name/updated",
        #"{"threadId":"thread-1","threadName":"Renamed task"}"#
    ),
    (
        "thread/goal/updated",
        #"{"threadId":"thread-1","turnId":"turn-1","goal":{"threadId":"thread-1","objective":"Ship iPad parity","status":"active","tokenBudget":12000,"tokensUsed":320,"timeUsedSeconds":18,"createdAt":1722345600,"updatedAt":1722345618}}"#
    ),
    ("thread/goal/cleared", #"{"threadId":"thread-1"}"#),
    ("thread/queue/changed", #"{"threadId":"thread-1"}"#),
    ("thread/reverted", #"{"threadId":"thread-1"}"#),
    ("skills/changed", #"{}"#),
    (
        "thread/environment/connected",
        #"{"threadId":"thread-1","environmentId":"environment-1"}"#
    ),
    (
        "thread/environment/disconnected",
        #"{"threadId":"thread-1","environmentId":"environment-1"}"#
    ),
    (
        "mcpServer/startupStatus/updated",
        #"{"threadId":"thread-1","name":"github","status":"ready","error":null,"failureReason":null}"#
    ),
    (
        "account/rateLimits/updated",
        #"{"rateLimits":{"limitId":"codex","primary":{"usedPercent":12,"windowDurationMins":300,"resetsAt":1722345600}}}"#
    ),
    (
        "model/rerouted",
        #"{"threadId":"thread-1","turnId":"turn-1","fromModel":"gpt-5","toModel":"gpt-5.6","reason":"highRiskCyberActivity"}"#
    ),
    (
        "model/verification",
        #"{"threadId":"thread-1","turnId":"turn-1","verifications":["trustedAccessForCyber"]}"#
    ),
    (
        "turn/moderationMetadata",
        #"{"threadId":"thread-1","turnId":"turn-1","metadata":{"category":"cyber"}}"#
    ),
    (
        "model/safetyBuffering/updated",
        #"{"threadId":"thread-1","turnId":"turn-1","model":"gpt-5.6","useCases":["cyber"],"reasons":["verification"],"showBufferingUi":true,"fasterModel":"gpt-5.6-mini"}"#
    ),
    (
        "configWarning",
        #"{"summary":"Invalid setting","details":"Unknown key","path":"/tmp/config.toml","range":{"start":{"line":3,"column":1},"end":{"line":3,"column":8}}}"#
    ),
    (
        "warning",
        #"{"threadId":null,"message":"Careful"}"#
    ),
    (
        "guardianWarning",
        #"{"threadId":"thread-1","message":"Guardian review required"}"#
    ),
    (
        "deprecationNotice",
        #"{"summary":"Legacy method","details":"Use the replacement method"}"#
    ),
    (
        "item/fileChange/outputDelta",
        #"{"threadId":"thread-1","turnId":"turn-1","itemId":"item-1","delta":"patch"}"#
    ),
    (
        "thread/compacted",
        #"{"threadId":"thread-1","turnId":"turn-1"}"#
    ),
]

@Test
func appServerNotificationEnvelopeDecodesAndRoundTripsEveryOfficialMethod()
    throws
{
    for (method, params) in officialNotificationSamples {
        let data = Data(
            #"{"method":"\#(method)","params":\#(params)}"#.utf8
        )
        let notification = try CodexAppServerNotification(data: data)

        #expect(notification.method == method)
        #expect(try CodexAppServerNotification(
            data: notification.encodedData()
        ) == notification)
        #expect(
            try CodexCoreEvent(data: data)
                == .appServerNotification(notification)
        )
    }
}

@Test
func appServerNotificationEnvelopeDecodesThreadRevertedAsTypedNotification()
    throws
{
    let notification = try CodexAppServerNotification(
        data: Data(
            #"{"method":"thread/reverted","params":{"threadId":"thread-1"}}"#.utf8
        )
    )

    guard case let .threadReverted(value) = notification else {
        Issue.record("thread/reverted must not fall back to opaque")
        return
    }
    #expect(value.threadID == "thread-1")
    #expect(notification.method == "thread/reverted")
}

@Test
func appServerNotificationEnvelopePreservesFutureMethodsForForwardCompatibility()
    throws
{
    let data = Data(
        #"{"method":"future/widget/updated","params":{"value":7}}"#.utf8
    )

    let notification = try CodexAppServerNotification(data: data)

    #expect(notification.method == "future/widget/updated")
    #expect(notification.params == .object([
        "value": .integer(7),
    ]))
    #expect(try CodexAppServerNotification(
        data: notification.encodedData()
    ) == notification)
    #expect(
        try CodexCoreEvent(data: data)
            == .appServerNotification(notification)
    )
}

@Test
func appServerNotificationEnvelopeRejectsMalformedPayloads() {
    #expect(throws: CodexCoreEnvelopeError.invalidEventPayload) {
        try CodexAppServerNotification(
            data: Data(
                #"{"method":"thread/closed","params":{}}"#.utf8
            )
        )
    }
    #expect(throws: CodexCoreEnvelopeError.invalidEventPayload) {
        try CodexAppServerNotification(
            data: Data(
                #"{"method":"thread/goal/updated","params":{"threadId":"thread-1","turnId":null,"goal":null}}"#.utf8
            )
        )
    }
    #expect(throws: CodexCoreEnvelopeError.invalidEventPayload) {
        try CodexAppServerNotification(
            data: Data(
                #"{"method":"model/safetyBuffering/updated","params":{"threadId":"thread-1","turnId":"turn-1","model":"gpt-5.6","useCases":"cyber","reasons":[],"showBufferingUi":true}}"#.utf8
            )
        )
    }
    #expect(throws: CodexCoreEnvelopeError.invalidEventPayload) {
        try CodexAppServerNotification(
            data: Data(
                #"{"method":"future/scalar","params":7}"#.utf8
            )
        )
    }
    #expect(throws: CodexCoreEnvelopeError.invalidEventPayload) {
        try CodexAppServerNotification(
            data: Data(
                #"{"method":"","params":{}}"#.utf8
            )
        )
    }
}

@MainActor
private final class AppServerNotificationTransport: CodexCoreTransport {
    var events: [CodexCoreEvent] = []

    func submit(_ command: CodexCoreCommand) throws {}

    func request(_ request: CodexAppServerThreadRequest) throws -> Data {
        throw CodexCoreTransportError.unsupportedTurnRequest
    }

    func nextEvent() throws -> CodexCoreEvent? {
        events.isEmpty ? nil : events.removeFirst()
    }
}

@MainActor
@Test
func sessionStoreDrainsAppServerNotificationsExactlyOnceInTransportOrder()
    throws
{
    let first = try CodexAppServerNotification(
        data: Data(
            #"{"method":"skills/changed","params":{}}"#.utf8
        )
    )
    let second = try CodexAppServerNotification(
        data: Data(
            #"{"method":"thread/closed","params":{"threadId":"thread-1"}}"#.utf8
        )
    )
    let transport = AppServerNotificationTransport()
    transport.events = [
        .appServerNotification(first),
        .appServerNotification(second),
    ]
    let store = CodexSessionStore(transport: transport)

    try store.openWorkspace(
        id: UUID(),
        displayName: "Notification drain",
        rootBookmarkID: nil
    )

    #expect(store.takeAppServerNotifications() == [first, second])
    #expect(store.takeAppServerNotifications().isEmpty)
}

@MainActor
@Test
func sessionStorePreservesTypedThreadRevertedNotificationForRenderer() throws {
    let reverted = CodexAppServerNotification.threadReverted(
        CodexThreadRevertedNotification(threadID: "thread-1")
    )
    let transport = AppServerNotificationTransport()
    transport.events = [.appServerNotification(reverted)]
    let store = CodexSessionStore(transport: transport)

    try store.openWorkspace(
        id: UUID(),
        displayName: "Thread reverted notification",
        rootBookmarkID: nil
    )

    #expect(store.takeAppServerNotifications() == [reverted])
    #expect(store.takeAppServerNotifications().isEmpty)
}

@MainActor
@Test
func sessionStoreTakesOnlyMatchingTerminalIdleNotifications() throws {
    let matchingIdle = CodexAppServerNotification.threadStatusChanged(
        CodexThreadStatusChangedNotification(
            threadID: "thread-1",
            status: .idle
        )
    )
    let matchingActive = CodexAppServerNotification.threadStatusChanged(
        CodexThreadStatusChangedNotification(
            threadID: "thread-1",
            status: .active([.waitingOnUserInput])
        )
    )
    let otherIdle = CodexAppServerNotification.threadStatusChanged(
        CodexThreadStatusChangedNotification(
            threadID: "thread-2",
            status: .idle
        )
    )
    let skillsChanged = CodexAppServerNotification.skillsChanged(
        CodexSkillsChangedNotification()
    )
    let transport = AppServerNotificationTransport()
    transport.events = [
        .appServerNotification(matchingActive),
        .appServerNotification(matchingIdle),
        .appServerNotification(otherIdle),
        .appServerNotification(skillsChanged),
    ]
    let store = CodexSessionStore(transport: transport)

    try store.openWorkspace(
        id: UUID(),
        displayName: "Terminal idle drain",
        rootBookmarkID: nil
    )

    #expect(
        store.takeTerminalIdleNotifications(
            for: CodexStoredThreadID("thread-1")
        ) == [matchingIdle]
    )
    #expect(
        store.takeAppServerNotifications()
            == [matchingActive, otherIdle, skillsChanged]
    )
}

@Test
func desktopNotificationProjectorPreservesMethodParamsHostAndOrder() throws {
    let notifications = try officialNotificationSamples.prefix(3).map {
        method, params in
        try CodexAppServerNotification(
            data: Data(
                #"{"method":"\#(method)","params":\#(params)}"#.utf8
            )
        )
    }

    let messages = CodexDesktopAppServerNotificationProjector.messages(
        notifications,
        hostID: "renderer-7"
    )

    #expect(messages.count == 3)
    for (index, message) in messages.enumerated() {
        guard case let .mcpNotification(
            hostID,
            method,
            params,
            metadata
        ) = message else {
            Issue.record("Expected an MCP notification")
            continue
        }
        #expect(hostID == "renderer-7")
        #expect(method == notifications[index].method)
        #expect(params == notifications[index].params)
        #expect(metadata.isEmpty)
    }
}

@Test
func desktopNotificationProjectorForwardsOfficialOpaqueDeprecatedAndFutureMethods()
    throws
{
    let samples = Array(officialNotificationSamples.suffix(5)) + [
        (
            "future/widget/updated",
            #"{"value":7}"#
        ),
    ]
    let notifications = try samples.map { method, params in
        try CodexAppServerNotification(
            data: Data(
                #"{"method":"\#(method)","params":\#(params)}"#.utf8
            )
        )
    }

    let messages = CodexDesktopAppServerNotificationProjector.messages(
        notifications,
        hostID: "renderer-opaque"
    )

    #expect(messages.count == samples.count)
    for (index, message) in messages.enumerated() {
        guard case let .mcpNotification(
            hostID,
            method,
            params,
            metadata
        ) = message else {
            Issue.record("Expected an MCP notification")
            continue
        }
        #expect(hostID == "renderer-opaque")
        #expect(method == notifications[index].method)
        #expect(params == notifications[index].params)
        #expect(metadata.isEmpty)
    }
}
