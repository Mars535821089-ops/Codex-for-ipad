import CoreFoundation
import CryptoKit
import Foundation

/// Released `appServerHistorySnapshots` AppHost behavior.
///
/// Desktop scopes every persisted history snapshot to both the signed-in
/// principal and the selected app-server host. A short-lived lease binds those
/// identities to each read/write/delete operation. The iPad implementation
/// preserves that boundary while storing the JSON snapshot in the app
/// container instead of Electron's process-global store.
public actor CodexDesktopHistorySnapshotsAppHostService {
    public typealias Value = CodexDesktopAppHostRPC.Value
    public typealias PrincipalProvider =
        @Sendable () async throws -> Principal?
    public typealias HostKeyProvider =
        @Sendable (String) -> String?
    public typealias InvalidationHandler =
        @Sendable (Int) async -> Void

    public struct Principal: Equatable, Sendable {
        public let userID: String
        public let accountID: String

        public init(userID: String, accountID: String) {
            self.userID = userID
            self.accountID = accountID
        }
    }

    public enum Error: Swift.Error, Equatable, Sendable {
        case invalidArguments
        case unsupportedMethod(String)
    }

    private struct Lease: Sendable {
        let token: String
        let principalKey: String
        let hostKey: String
    }

    /// Matches the released desktop helper name. The returned token is only
    /// issued after the current principal and host have been established.
    /// Storage operations still go through `runAuthorized` so a lease cannot
    /// be replayed after either identity changes.
    private func getAuthorizationLease(
        hostID: String,
        identity: Authorization
    ) -> String {
        if let current = leasesByHostID[hostID],
           current.principalKey == identity.principalKey,
           current.hostKey == identity.hostKey
        {
            return current.token
        }
        let token = UUID().uuidString.lowercased()
        leasesByHostID[hostID] = Lease(
            token: token,
            principalKey: identity.principalKey,
            hostKey: identity.hostKey
        )
        return token
    }

    private struct Authorization: Sendable {
        let principalKey: String
        let hostKey: String
    }

    private static let maximumSnapshotBytes = 1_048_576

    private let storeRoot: URL
    private let principalProvider: PrincipalProvider
    private let hostKeyProvider: HostKeyProvider
    private let invalidationHandler: InvalidationHandler
    private var leasesByHostID: [String: Lease] = [:]
    private var invalidationCallbacksByHostID:
        [String: Set<Int>] = [:]

    public init(
        storeRoot: URL,
        principalProvider: @escaping PrincipalProvider,
        hostKeyProvider: @escaping HostKeyProvider,
        invalidationHandler: @escaping InvalidationHandler = { _ in }
    ) {
        self.storeRoot = storeRoot.standardizedFileURL
        self.principalProvider = principalProvider
        self.hostKeyProvider = hostKeyProvider
        self.invalidationHandler = invalidationHandler
    }

    public func invoke(
        method: String,
        arguments: [Value]?
    ) async throws -> Value {
        switch method {
        case "acquireAuthorizationLease":
            let hostID = try Self.singleHostID(arguments)
            return await runAuthorized(hostID: hostID, token: nil) {
                identity in
                .string(
                    self.getAuthorizationLease(
                        hostID: hostID,
                        identity: identity
                    )
                )
            }

        case "getAuthorizationLease":
            let hostID = try Self.singleHostID(arguments)
            guard let identity = await currentIdentity(hostID: hostID)
            else {
                return Self.unavailable()
            }
            return .string(
                getAuthorizationLease(hostID: hostID, identity: identity)
            )

        case "invalidateHost":
            let hostID = try Self.singleHostID(arguments)
            await invalidateHost(hostID)
            return .undefined

        case "subscribeAuthorizationLeaseInvalidation":
            guard let values = arguments,
                  values.count == 2,
                  let hostID = Self.nonemptyString(values[0]),
                  case let .import(callbackID) = values[1],
                  callbackID >= 0
            else {
                throw Error.invalidArguments
            }
            invalidationCallbacksByHostID[
                hostID,
                default: []
            ].insert(callbackID)
            return .rpcObject([:])

        case "read":
            let request = try Self.storageRequest(arguments)
            guard let authorization = await authorize(
                hostID: request.hostID,
                token: request.token
            ) else {
                return Self.unavailable()
            }
            do {
                let fileURL = snapshotURL(
                    authorization: authorization,
                    threadID: request.threadID
                )
                guard FileManager.default.fileExists(
                    atPath: fileURL.path
                ) else {
                    return Self.ok(.null)
                }
                let data = try Data(contentsOf: fileURL)
                guard data.count <= Self.maximumSnapshotBytes,
                      let snapshot = String(
                        data: data,
                        encoding: .utf8
                      )
                else {
                    return Self.unavailable()
                }
                return Self.ok(.string(snapshot))
            } catch {
                return Self.unavailable()
            }

        case "write":
            guard let values = arguments,
                  values.count == 3,
                  let hostID = Self.nonemptyString(values[0]),
                  let token = Self.nonemptyString(values[1]),
                  case let .string(snapshot) = values[2]
            else {
                throw Error.invalidArguments
            }
            let validatedSnapshot = try Self.validateSnapshot(snapshot)
            guard let authorization = await authorize(
                hostID: hostID,
                token: token
            ) else {
                return Self.unavailable()
            }
            do {
                let fileURL = snapshotURL(
                    authorization: authorization,
                    threadID: validatedSnapshot.threadID
                )
                try Self.createPrivateDirectory(
                    fileURL.deletingLastPathComponent()
                )
                try validatedSnapshot.data.write(
                    to: fileURL,
                    options: .atomic
                )
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: fileURL.path
                )
                return Self.ok(.undefined)
            } catch {
                return Self.unavailable()
            }

        case "delete":
            let request = try Self.storageRequest(arguments)
            guard let authorization = await authorize(
                hostID: request.hostID,
                token: request.token
            ) else {
                return Self.unavailable()
            }
            do {
                let fileURL = snapshotURL(
                    authorization: authorization,
                    threadID: request.threadID
                )
                if FileManager.default.fileExists(
                    atPath: fileURL.path
                ) {
                    try FileManager.default.removeItem(at: fileURL)
                }
                return Self.ok(.undefined)
            } catch {
                return Self.unavailable()
            }

        default:
            throw Error.unsupportedMethod(method)
        }
    }

    /// Invalidates the current host lease and forwards every released
    /// subscription callback. Subscriptions intentionally survive the
    /// invalidation so the renderer can observe subsequent identity changes.
    public func invalidateHost(_ hostID: String) async {
        await invalidateLease(for: hostID)
    }

    public func invalidateAll() async {
        let hostIDs = Set(leasesByHostID.keys)
            .union(invalidationCallbacksByHostID.keys)
        for hostID in hostIDs.sorted() {
            await invalidateLease(for: hostID)
        }
    }

    private func runAuthorized(
        hostID: String,
        token: String?,
        operation: (Authorization) -> Value
    ) async -> Value {
        guard let identity = await currentIdentity(hostID: hostID)
        else {
            return Self.unavailable()
        }
        if let token {
            guard let lease = leasesByHostID[hostID],
                  lease.token == token,
                  lease.principalKey == identity.principalKey,
                  lease.hostKey == identity.hostKey
            else {
                await invalidateLease(for: hostID)
                return Self.unavailable()
            }
        }
        return Self.ok(operation(identity))
    }

    private func authorize(
        hostID: String,
        token: String
    ) async -> Authorization? {
        guard case let .object(fields) = await runAuthorized(
            hostID: hostID,
            token: token,
            operation: { identity in
                .object([
                    "principalKey": .string(identity.principalKey),
                    "hostKey": .string(identity.hostKey),
                ])
            }
        ),
        fields["status"] == .string("ok"),
        case let .object(identityFields)? = fields["value"],
        case let .string(principalKey)? = identityFields["principalKey"],
        case let .string(hostKey)? = identityFields["hostKey"]
        else {
            return nil
        }
        return Authorization(principalKey: principalKey, hostKey: hostKey)
    }

    private func currentIdentity(
        hostID: String
    ) async -> Authorization? {
        guard let hostKey = hostKeyProvider(hostID),
              !hostKey.isEmpty,
              let principal = try? await principalProvider(),
              !principal.userID.isEmpty,
              !principal.accountID.isEmpty
        else {
            return nil
        }
        return Authorization(
            principalKey: Self.sha256(
                principal.userID + "\u{0}" + principal.accountID
            ),
            hostKey: hostKey
        )
    }

    private func invalidateLease(for hostID: String) async {
        leasesByHostID.removeValue(forKey: hostID)
        let callbacks =
            invalidationCallbacksByHostID[hostID, default: []]
        for callbackID in callbacks.sorted() {
            await invalidationHandler(callbackID)
        }
    }

    private func snapshotURL(
        authorization: Authorization,
        threadID: String
    ) -> URL {
        storeRoot
            .appendingPathComponent(
                authorization.principalKey,
                isDirectory: true
            )
            .appendingPathComponent(
                Self.sha256(authorization.hostKey),
                isDirectory: true
            )
            .appendingPathComponent(
                Self.sha256(threadID) + ".json",
                isDirectory: false
            )
    }

    private static func singleHostID(
        _ arguments: [Value]?
    ) throws -> String {
        guard let arguments,
              arguments.count == 1,
              let hostID = nonemptyString(arguments[0])
        else {
            throw Error.invalidArguments
        }
        return hostID
    }

    private static func storageRequest(
        _ arguments: [Value]?
    ) throws -> (hostID: String, token: String, threadID: String) {
        guard let arguments,
              arguments.count == 3,
              let hostID = nonemptyString(arguments[0]),
              let token = nonemptyString(arguments[1]),
              let threadID = nonemptyString(arguments[2]),
              isSafeIdentifier(threadID)
        else {
            throw Error.invalidArguments
        }
        return (hostID, token, threadID)
    }

    private static func validateSnapshot(
        _ snapshot: String
    ) throws -> (threadID: String, data: Data) {
        let data = Data(snapshot.utf8)
        guard data.count <= maximumSnapshotBytes,
              let json = try? JSONSerialization.jsonObject(
                with: data
              ),
              let fields = json as? [String: Any],
              let threadID = fields["threadId"] as? String,
              !threadID.isEmpty,
              isSafeIdentifier(threadID),
              let version = fields["version"] as? NSNumber,
              CFGetTypeID(version) != CFBooleanGetTypeID(),
              version.doubleValue == 2,
              version.intValue == 2
        else {
            throw Error.invalidArguments
        }
        return (threadID, data)
    }

    private static func isSafeIdentifier(_ value: String) -> Bool {
        !value.isEmpty
            && value.count <= 512
            && !value.contains("..")
            && !value.contains("/")
            && !value.contains("\\")
            && value.unicodeScalars.allSatisfy {
                !CharacterSet.controlCharacters.contains($0)
            }
    }

    private static func nonemptyString(
        _ value: Value?
    ) -> String? {
        guard case let .string(raw)? = value,
              !raw.isEmpty
        else {
            return nil
        }
        return raw
    }

    private static func createPrivateDirectory(
        _ directory: URL
    ) throws {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directory.path
        )
    }

    private static func sha256(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map {
            String(format: "%02x", $0)
        }.joined()
    }

    private static func ok(_ value: Value) -> Value {
        .object([
            "status": .string("ok"),
            "value": value,
        ])
    }

    private static func unavailable() -> Value {
        .object(["status": .string("unavailable")])
    }
}
