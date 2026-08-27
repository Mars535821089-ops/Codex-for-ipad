#if SWIFT_PACKAGE
    import CodexPadDomain
#endif
import Foundation

public enum CodexDesktopSharedObjectLookup:
    Equatable,
    Sendable
{
    case missing
    case value(CodexJSONValue)
}

public final class CodexDesktopSharedObjectStore {
    private var values: [String: CodexJSONValue]
    private var subscriberCounts: [String: Int] = [:]

    public init(
        initialValues: [String: CodexJSONValue]
    ) {
        self.values = initialValues
    }

    public var snapshot: [String: CodexJSONValue] {
        values
    }

    public static func releasedInitialSnapshot(
        installationID: String? = nil,
        environmentID: String? = nil,
        remoteControlEnabled: Bool? = nil
    ) -> [String: CodexJSONValue] {
        var snapshot: [String: CodexJSONValue] = [
            "host_config": .object([
                "id": .string("local"),
                "display_name": .string("Local"),
                "kind": .string("local"),
            ]),
            "remote_ssh_connections": .array([]),
            "remote_control_connections_state": .object([
                "available": .bool(false),
                "accessRequired": .bool(false),
                "authRequired": .bool(false),
                "clientAuthorized": .bool(false),
            ]),
            "local_remote_control_client_id": .null,
        ]
        if let installationID, !installationID.isEmpty {
            snapshot["local_remote_control_installation_id"] =
                .string(installationID)
        }
        if let environmentID, !environmentID.isEmpty {
            snapshot["local_remote_control_environment_id"] =
                .string(environmentID)
        }
        if let remoteControlEnabled {
            snapshot["local_remote_control_enabled"] =
                .bool(remoteControlEnabled)
        }
        return snapshot
    }

    public func lookup(
        _ key: String
    ) -> CodexDesktopSharedObjectLookup {
        guard let value = values[key] else {
            return .missing
        }
        return .value(value)
    }

    @discardableResult
    public func subscribe(
        _ key: String
    ) -> CodexDesktopSharedObjectLookup {
        guard !key.isEmpty else {
            return .missing
        }
        subscriberCounts[key, default: 0] += 1
        return lookup(key)
    }

    @discardableResult
    public func unsubscribe(
        _ key: String
    ) -> Int {
        guard let count = subscriberCounts[key] else {
            return 0
        }
        if count <= 1 {
            subscriberCounts.removeValue(forKey: key)
            return 0
        }
        let remaining = count - 1
        subscriberCounts[key] = remaining
        return remaining
    }

    public func set(
        _ value: CodexJSONValue?,
        for key: String
    ) -> CodexDesktopSharedObjectLookup {
        guard !key.isEmpty else {
            return .missing
        }
        if let value {
            values[key] = value
            return .value(value)
        }
        values.removeValue(forKey: key)
        return .missing
    }

    public func isSubscribed(
        to key: String
    ) -> Bool {
        (subscriberCounts[key] ?? 0) > 0
    }

    public func subscriptionCount(
        for key: String
    ) -> Int {
        subscriberCounts[key] ?? 0
    }

    public func resetSubscriptions() {
        subscriberCounts.removeAll(keepingCapacity: true)
    }
}
