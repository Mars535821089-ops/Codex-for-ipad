import Foundation
import Testing

@testable import CodexPadApplication

private typealias HistoryValue = CodexDesktopAppHostRPC.Value

@Test
func desktopHistorySnapshotsPersistsReleasedReadWriteDeleteFlow()
    async throws
{
    let fixture = try HistorySnapshotFixture()
    defer { fixture.remove() }
    let identity = HistoryIdentityState()
    let service = CodexDesktopHistorySnapshotsAppHostService(
        storeRoot: fixture.storeRoot,
        principalProvider: { await identity.principal },
        hostKeyProvider: { hostID in
            hostID == "local" ? "local:stable-host-key" : nil
        }
    )
    let lease = try await acquireHistoryLease(
        service,
        hostID: "local"
    )
    let snapshot = #"{"threadId":"thread-1","turns":[],"version":2}"#

    #expect(
        try await service.invoke(
            method: "write",
            arguments: [
                .string("local"),
                .string(lease),
                .string(snapshot),
            ]
        ) == .object([
            "status": .string("ok"),
            "value": .undefined,
        ])
    )
    #expect(
        try await service.invoke(
            method: "read",
            arguments: [
                .string("local"),
                .string(lease),
                .string("thread-1"),
            ]
        ) == .object([
            "status": .string("ok"),
            "value": .string(snapshot),
        ])
    )
    #expect(
        try await service.invoke(
            method: "delete",
            arguments: [
                .string("local"),
                .string(lease),
                .string("thread-1"),
            ]
        ) == .object([
            "status": .string("ok"),
            "value": .undefined,
        ])
    )
    #expect(
        try await service.invoke(
            method: "read",
            arguments: [
                .string("local"),
                .string(lease),
                .string("thread-1"),
            ]
        ) == .object([
            "status": .string("ok"),
            "value": .null,
        ])
    )
}

@Test
func desktopHistorySnapshotsInvalidatesLeaseOnPrincipalOrHostChange()
    async throws
{
    let fixture = try HistorySnapshotFixture()
    defer { fixture.remove() }
    let identity = HistoryIdentityState()
    let host = HistoryHostState()
    let service = CodexDesktopHistorySnapshotsAppHostService(
        storeRoot: fixture.storeRoot,
        principalProvider: { await identity.principal },
        hostKeyProvider: { _ in host.key }
    )
    let lease = try await acquireHistoryLease(
        service,
        hostID: "local"
    )

    await identity.set(
        .init(userID: "user-2", accountID: "account-2")
    )
    #expect(
        try await service.invoke(
            method: "read",
            arguments: [
                .string("local"),
                .string(lease),
                .string("thread-1"),
            ]
        ) == .object(["status": .string("unavailable")])
    )

    let replacement = try await acquireHistoryLease(
        service,
        hostID: "local"
    )
    #expect(replacement != lease)
    host.key = "local:replacement"
    #expect(
        try await service.invoke(
            method: "delete",
            arguments: [
                .string("local"),
                .string(replacement),
                .string("thread-1"),
            ]
        ) == .object(["status": .string("unavailable")])
    )
}

@Test
func desktopHistorySnapshotsExposesReleasedLeaseHelpers()
    async throws
{
    let fixture = try HistorySnapshotFixture()
    defer { fixture.remove() }
    let service = CodexDesktopHistorySnapshotsAppHostService(
        storeRoot: fixture.storeRoot,
        principalProvider: {
            .init(userID: "user-1", accountID: "account-1")
        },
        hostKeyProvider: { _ in "host-key" }
    )

    let acquired = try await acquireHistoryLease(service, hostID: "local")
    #expect(
        try await service.invoke(
            method: "getAuthorizationLease",
            arguments: [.string("local")]
        ) == .string(acquired)
    )
    #expect(
        try await service.invoke(
            method: "invalidateHost",
            arguments: [.string("local")]
        ) == .undefined
    )
    #expect(
        try await service.invoke(
            method: "read",
            arguments: [
                .string("local"),
                .string(acquired),
                .string("thread-1"),
            ]
        ) == .object(["status": .string("unavailable")])
    )
}

@Test
func desktopHistorySnapshotsForwardsReleasedInvalidationSubscription()
    async throws
{
    let fixture = try HistorySnapshotFixture()
    defer { fixture.remove() }
    let recorder = HistoryInvalidationRecorder()
    let service = CodexDesktopHistorySnapshotsAppHostService(
        storeRoot: fixture.storeRoot,
        principalProvider: {
            .init(userID: "user-1", accountID: "account-1")
        },
        hostKeyProvider: { _ in "host-key" },
        invalidationHandler: { callbackID in
            await recorder.record(callbackID)
        }
    )

    #expect(
        try await service.invoke(
            method: "subscribeAuthorizationLeaseInvalidation",
            arguments: [.string("local"), .import(41)]
        ) == .rpcObject([:])
    )
    _ = try await acquireHistoryLease(service, hostID: "local")
    await service.invalidateHost("local")
    #expect(await recorder.callbackIDs == [41])
}

@Test
func desktopHistorySnapshotsRejectsMalformedAndOversizedSnapshots()
    async throws
{
    let fixture = try HistorySnapshotFixture()
    defer { fixture.remove() }
    let service = CodexDesktopHistorySnapshotsAppHostService(
        storeRoot: fixture.storeRoot,
        principalProvider: {
            .init(userID: "user-1", accountID: "account-1")
        },
        hostKeyProvider: { _ in "host-key" }
    )
    let lease = try await acquireHistoryLease(service, hostID: "local")

    for snapshot in [
        #"{"turns":[],"version":2}"#,
        #"{"threadId":"../escape","turns":[],"version":2}"#,
        #"{"threadId":"thread-1","turns":[],"version":1}"#,
        String(repeating: "x", count: 1_048_577),
    ] {
        await #expect(
            throws:
                CodexDesktopHistorySnapshotsAppHostService.Error
                    .invalidArguments
        ) {
            _ = try await service.invoke(
                method: "write",
                arguments: [
                    .string("local"),
                    .string(lease),
                    .string(snapshot),
                ]
            )
        }
    }
    await #expect(
        throws:
            CodexDesktopHistorySnapshotsAppHostService.Error
                .invalidArguments
    ) {
        _ = try await service.invoke(
            method: "read",
            arguments: [.string("local"), .string(lease)]
        )
    }
}

private func acquireHistoryLease(
    _ service: CodexDesktopHistorySnapshotsAppHostService,
    hostID: String
) async throws -> String {
    let value = try await service.invoke(
        method: "acquireAuthorizationLease",
        arguments: [.string(hostID)]
    )
    guard case let .object(fields) = value,
          fields["status"] == .string("ok"),
          case let .string(lease)? = fields["value"]
    else {
        throw HistoryTestError.missingLease
    }
    return lease
}

private enum HistoryTestError: Swift.Error {
    case missingLease
}

private final class HistorySnapshotFixture: @unchecked Sendable {
    let root: URL
    let storeRoot: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        storeRoot = root.appendingPathComponent("history", isDirectory: true)
        try FileManager.default.createDirectory(
            at: storeRoot,
            withIntermediateDirectories: true
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

private actor HistoryIdentityState {
    private(set) var principal =
        CodexDesktopHistorySnapshotsAppHostService.Principal(
            userID: "user-1",
            accountID: "account-1"
        )

    func set(
        _ value: CodexDesktopHistorySnapshotsAppHostService.Principal
    ) {
        principal = value
    }
}

private final class HistoryHostState: @unchecked Sendable {
    var key = "local:initial"
}

private actor HistoryInvalidationRecorder {
    private(set) var callbackIDs: [Int] = []

    func record(_ callbackID: Int) {
        callbackIDs.append(callbackID)
    }
}
