import CodexPadApplication
import CodexPadProtocolBridge
import Foundation
import Testing

private enum CorePersistenceTestError: Error {
    case missingResponse
}

@MainActor
private final class CoreEnrollmentTransportProbe:
    CodexRemoteControlCoreEnrollmentTransport
{
    var submitted: [CodexRemoteControlCoreEnrollmentCommand] = []
    var requested: [CodexRemoteControlCoreEnrollmentLoadRequest] = []
    var response:
        ((CodexRemoteControlCoreEnrollmentLoadRequest) throws -> Data)?

    func submit(
        _ command: CodexRemoteControlCoreEnrollmentCommand
    ) throws {
        submitted.append(command)
    }

    func request(
        _ request: CodexRemoteControlCoreEnrollmentLoadRequest
    ) throws -> Data {
        requested.append(request)
        guard let response else {
            throw CorePersistenceTestError.missingResponse
        }
        return try response(request)
    }
}

private let corePersistenceKey = CodexRemoteControlPersistenceKey(
    target: "wss://chatgpt.test/backend-api/wham/remote/control/server",
    accountID: "account-1",
    appServerClientName: ""
)

private let corePersistedEnrollment = CodexRemoteControlPersistedEnrollment(
    serverID: "server-1",
    environmentID: "environment-1",
    serverName: "Codex for ipad",
    enabled: true
)

private func coreResponse(
    id: String,
    enrollment: Any?
) throws -> Data {
    try JSONSerialization.data(withJSONObject: [
        "id": id,
        "result": [
            "enrollment": enrollment ?? NSNull(),
        ],
    ])
}

private func coreStoredEnrollment(
    key: CodexRemoteControlPersistenceKey = corePersistenceKey,
    serverID: String = "server-1",
    environmentID: String = "environment-1",
    serverName: String = "Codex for ipad",
    updatedAt: Int64 = 101,
    enabled: Any = true
) -> [String: Any] {
    [
        "websocketUrl": key.target,
        "accountId": key.accountID,
        "appServerClientName": key.appServerClientName,
        "serverId": serverID,
        "environmentId": environmentID,
        "serverName": serverName,
        "updatedAt": updatedAt,
        "remoteControlEnabled": enabled,
        // A hostile/mismatched core must never make transient values durable.
        "remoteControlToken": "TRANSIENT_TOKEN",
        "expiresAt": 999,
        "refreshToken": "TRANSIENT_REFRESH",
        "cursor": "TRANSIENT_CURSOR",
        "tasks": ["TRANSIENT_TASK"],
    ]
}

private func jsonObject(
    _ data: Data
) throws -> [String: Any] {
    try #require(
        JSONSerialization.jsonObject(with: data) as? [String: Any]
    )
}

@Test
@MainActor
func corePersistenceLoadUsesExactCompositeKeyAndMapsOnlyDurableState()
    async throws
{
    let transport = CoreEnrollmentTransportProbe()
    transport.response = { request in
        try coreResponse(
            id: request.requestID,
            enrollment: coreStoredEnrollment()
        )
    }
    let adapter = CodexRemoteControlCorePersistenceAdapter(
        transport: transport,
        now: { 123 },
        requestID: { "load-1" }
    )

    let loaded = try await adapter.load(for: corePersistenceKey)

    #expect(loaded == corePersistedEnrollment)
    #expect(transport.requested.count == 1)
    let request = transport.requested[0]
    #expect(request.requestID == "load-1")
    let wire = try jsonObject(request.encodedData())
    #expect(wire["id"] as? String == "load-1")
    #expect(
        wire["method"] as? String
            == "remote_control.enrollment.load"
    )
    let params = try #require(wire["params"] as? [String: Any])
    #expect(params["websocketUrl"] as? String == corePersistenceKey.target)
    #expect(params["accountId"] as? String == corePersistenceKey.accountID)
    #expect(params["appServerClientName"] as? String == "")
}

@Test
@MainActor
func corePersistenceRejectsResponseIDAndEnrollmentIdentityMismatch()
    async throws
{
    let wrongIDTransport = CoreEnrollmentTransportProbe()
    wrongIDTransport.response = { _ in
        try coreResponse(
            id: "wrong-id",
            enrollment: coreStoredEnrollment()
        )
    }
    let wrongIDAdapter = CodexRemoteControlCorePersistenceAdapter(
        transport: wrongIDTransport,
        requestID: { "expected-id" }
    )
    await #expect(throws: CodexRemoteControlCorePersistenceError.self) {
        try await wrongIDAdapter.load(for: corePersistenceKey)
    }

    let wrongIdentityTransport = CoreEnrollmentTransportProbe()
    wrongIdentityTransport.response = { request in
        try coreResponse(
            id: request.requestID,
            enrollment: coreStoredEnrollment(
                key: .init(
                    target: corePersistenceKey.target,
                    accountID: "other-account",
                    appServerClientName: ""
                )
            )
        )
    }
    let wrongIdentityAdapter = CodexRemoteControlCorePersistenceAdapter(
        transport: wrongIdentityTransport,
        requestID: { "identity-id" }
    )
    do {
        _ = try await wrongIdentityAdapter.load(for: corePersistenceKey)
        Issue.record("Expected exact composite-key validation")
    } catch let error as CodexRemoteControlCorePersistenceError {
        #expect(
            error == .mismatchedIdentity(
                expected: corePersistenceKey,
                actual: .init(
                    target: corePersistenceKey.target,
                    accountID: "other-account",
                    appServerClientName: ""
                )
            )
        )
    }
}

@Test
@MainActor
func corePersistenceUpsertWritesOptionalEnabledAndNoTransientSecrets()
    async throws
{
    let transport = CoreEnrollmentTransportProbe()
    let adapter = CodexRemoteControlCorePersistenceAdapter(
        transport: transport,
        now: { 123 },
        requestID: { "unused" }
    )

    try await adapter.upsert(
        corePersistedEnrollment,
        for: corePersistenceKey,
        enabled: false
    )
    try await adapter.upsert(
        corePersistedEnrollment,
        for: corePersistenceKey,
        enabled: nil
    )

    #expect(transport.submitted.count == 2)
    let inserted = try jsonObject(transport.submitted[0].encodedData())
    #expect(
        inserted["kind"] as? String
            == "remote_control.enrollment.upsert"
    )
    #expect(inserted["websocketUrl"] as? String == corePersistenceKey.target)
    #expect(inserted["accountId"] as? String == corePersistenceKey.accountID)
    #expect(inserted["appServerClientName"] as? String == "")
    #expect(inserted["serverId"] as? String == "server-1")
    #expect(inserted["environmentId"] as? String == "environment-1")
    #expect(inserted["serverName"] as? String == "Codex for ipad")
    #expect(inserted["updatedAt"] as? Int == 123)
    #expect(inserted["remoteControlEnabled"] as? Bool == false)
    for forbidden in [
        "remoteControlToken", "expiresAt", "refreshToken", "cursor", "tasks",
    ] {
        #expect(inserted[forbidden] == nil)
    }

    let preserving = try jsonObject(
        transport.submitted[1].encodedData()
    )
    #expect(preserving["remoteControlEnabled"] == nil)
}

@Test
@MainActor
func corePersistenceSetEnabledLoadsBeforeSubmitAndReportsMissingRow()
    async throws
{
    let missingTransport = CoreEnrollmentTransportProbe()
    missingTransport.response = { request in
        try coreResponse(id: request.requestID, enrollment: nil)
    }
    let missingAdapter = CodexRemoteControlCorePersistenceAdapter(
        transport: missingTransport,
        now: { 200 },
        requestID: { "missing-load" }
    )
    #expect(
        try await missingAdapter.setEnabled(
            true,
            for: corePersistenceKey
        ) == false
    )
    #expect(missingTransport.requested.count == 1)
    #expect(missingTransport.submitted.isEmpty)

    let existingTransport = CoreEnrollmentTransportProbe()
    existingTransport.response = { request in
        try coreResponse(
            id: request.requestID,
            enrollment: coreStoredEnrollment()
        )
    }
    let existingAdapter = CodexRemoteControlCorePersistenceAdapter(
        transport: existingTransport,
        now: { 201 },
        requestID: { "existing-load" }
    )
    #expect(
        try await existingAdapter.setEnabled(
            false,
            for: corePersistenceKey
        )
    )
    #expect(existingTransport.requested.count == 1)
    #expect(existingTransport.submitted.count == 1)
    let command = existingTransport.submitted[0]
    let wire = try jsonObject(command.encodedData())
    #expect(
        wire["kind"] as? String
            == "remote_control.enrollment.set_enabled"
    )
    #expect(wire["enabled"] as? Bool == false)
    #expect(wire["updatedAt"] as? Int == 201)
}

@Test
@MainActor
func corePersistenceDeleteUsesAllThreeIdentityFields() async throws {
    let transport = CoreEnrollmentTransportProbe()
    let adapter = CodexRemoteControlCorePersistenceAdapter(
        transport: transport,
        requestID: { "unused" }
    )

    try await adapter.delete(for: corePersistenceKey)

    #expect(transport.submitted.count == 1)
    let command = transport.submitted[0]
    let wire = try jsonObject(command.encodedData())
    #expect(
        wire["kind"] as? String
            == "remote_control.enrollment.delete"
    )
    #expect(wire["websocketUrl"] as? String == corePersistenceKey.target)
    #expect(wire["accountId"] as? String == corePersistenceKey.accountID)
    #expect(wire["appServerClientName"] as? String == "")
}
