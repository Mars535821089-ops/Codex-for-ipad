#if SWIFT_PACKAGE
import CodexPadProtocolBridge
#endif
import Foundation

public enum CodexRemoteControlCorePersistenceError:
    Error,
    Equatable,
    Sendable
{
    case malformedResponse
    case responseIDMismatch(expected: String, actual: String)
    case mismatchedIdentity(
        expected: CodexRemoteControlPersistenceKey,
        actual: CodexRemoteControlPersistenceKey
    )
    case invalidEnrollment
}

@MainActor
public final class CodexRemoteControlCorePersistenceAdapter:
    CodexRemoteControlLifecyclePersisting
{
    private let transport: any CodexRemoteControlCoreEnrollmentTransport
    private let now: @Sendable () -> Int64
    private let requestID: @Sendable () -> String

    public init(
        transport: any CodexRemoteControlCoreEnrollmentTransport,
        now: @escaping @Sendable () -> Int64 = {
            Int64(Date().timeIntervalSince1970)
        },
        requestID: @escaping @Sendable () -> String = {
            UUID().uuidString.lowercased()
        }
    ) {
        self.transport = transport
        self.now = now
        self.requestID = requestID
    }

    public func load(
        for key: CodexRemoteControlPersistenceKey
    ) async throws -> CodexRemoteControlPersistedEnrollment? {
        try loadSynchronously(for: key)
    }

    public func upsert(
        _ enrollment: CodexRemoteControlPersistedEnrollment,
        for key: CodexRemoteControlPersistenceKey,
        enabled: Bool?
    ) async throws {
        try transport.submit(
            .upsert(
                key: coreKey(key),
                serverID: enrollment.serverID,
                environmentID: enrollment.environmentID,
                serverName: enrollment.serverName,
                updatedAt: now(),
                remoteControlEnabled: enabled
            )
        )
    }

    public func setEnabled(
        _ enabled: Bool,
        for key: CodexRemoteControlPersistenceKey
    ) async throws -> Bool {
        // Keep existence check + mutation in one MainActor turn so two
        // lifecycle transitions cannot interleave between these operations.
        guard try loadSynchronously(for: key) != nil else {
            return false
        }
        try transport.submit(
            .setEnabled(
                key: coreKey(key),
                enabled: enabled,
                updatedAt: now()
            )
        )
        return true
    }

    public func delete(
        for key: CodexRemoteControlPersistenceKey
    ) async throws {
        try transport.submit(.delete(key: coreKey(key)))
    }

    private func loadSynchronously(
        for key: CodexRemoteControlPersistenceKey
    ) throws -> CodexRemoteControlPersistedEnrollment? {
        let expectedRequestID = requestID()
        let request = CodexRemoteControlCoreEnrollmentLoadRequest(
            requestID: expectedRequestID,
            key: coreKey(key)
        )
        let data = try transport.request(request)
        let response: LoadResponse
        do {
            response = try JSONDecoder().decode(
                LoadResponse.self,
                from: data
            )
        } catch {
            throw CodexRemoteControlCorePersistenceError.malformedResponse
        }
        guard response.id == expectedRequestID else {
            throw CodexRemoteControlCorePersistenceError
                .responseIDMismatch(
                    expected: expectedRequestID,
                    actual: response.id
                )
        }
        guard let stored = response.result.enrollment else {
            return nil
        }
        let actualKey = CodexRemoteControlPersistenceKey(
            target: stored.websocketURL,
            accountID: stored.accountID,
            appServerClientName: stored.appServerClientName
        )
        guard actualKey == key else {
            throw CodexRemoteControlCorePersistenceError
                .mismatchedIdentity(
                    expected: key,
                    actual: actualKey
                )
        }
        guard !stored.serverID.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty,
              !stored.environmentID.trimmingCharacters(
                  in: .whitespacesAndNewlines
              ).isEmpty,
              !stored.serverName.trimmingCharacters(
                  in: .whitespacesAndNewlines
              ).isEmpty
        else {
            throw CodexRemoteControlCorePersistenceError.invalidEnrollment
        }
        return CodexRemoteControlPersistedEnrollment(
            serverID: stored.serverID,
            environmentID: stored.environmentID,
            serverName: stored.serverName,
            enabled: stored.remoteControlEnabled
        )
    }

    private func coreKey(
        _ key: CodexRemoteControlPersistenceKey
    ) -> CodexRemoteControlCoreEnrollmentKey {
        CodexRemoteControlCoreEnrollmentKey(
            websocketURL: key.target,
            accountID: key.accountID,
            appServerClientName: key.appServerClientName
        )
    }
}

private struct LoadResponse: Decodable {
    let id: String
    let result: LoadResult
}

private struct LoadResult: Decodable {
    let enrollment: StoredEnrollment?
}

private struct StoredEnrollment: Decodable {
    let websocketURL: String
    let accountID: String
    let appServerClientName: String
    let serverID: String
    let environmentID: String
    let serverName: String
    let updatedAt: Int64
    let remoteControlEnabled: Bool?

    enum CodingKeys: String, CodingKey {
        case websocketURL = "websocketUrl"
        case accountID = "accountId"
        case appServerClientName
        case serverID = "serverId"
        case environmentID = "environmentId"
        case serverName
        case updatedAt
        case remoteControlEnabled
    }
}
