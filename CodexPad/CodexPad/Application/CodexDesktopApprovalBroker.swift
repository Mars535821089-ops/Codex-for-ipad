#if SWIFT_PACKAGE
import CodexPadDomain
import CodexPadProtocolBridge
#endif
import Foundation

public struct CodexDesktopApprovalRequest: Equatable, Sendable {
    public let method: String
    public let params: CodexJSONValue

    private init(method: String, params: CodexJSONValue) {
        self.method = method
        self.params = params
    }

    public static func fileChange(
        threadID: String,
        turnID: String,
        itemID: String,
        startedAtMs: Int64,
        reason: CodexWireOptional<String> = .omitted,
        grantRoot: CodexWireOptional<String> = .omitted
    ) -> Self {
        var fields: [String: CodexJSONValue] = [
            "threadId": .string(threadID),
            "turnId": .string(turnID),
            "itemId": .string(itemID),
            "startedAtMs": .integer(startedAtMs),
        ]
        add(reason, as: "reason", to: &fields)
        add(grantRoot, as: "grantRoot", to: &fields)
        return Self(
            method: "item/fileChange/requestApproval",
            params: .object(fields)
        )
    }

    public static func commandExecution(
        threadID: String,
        turnID: String,
        itemID: String,
        startedAtMs: Int64,
        approvalID: CodexWireOptional<String> = .omitted,
        environmentID: String?,
        reason: CodexWireOptional<String> = .omitted,
        networkApprovalContext:
            CodexWireOptional<CodexJSONValue> = .omitted,
        command: CodexWireOptional<String> = .omitted,
        cwd: CodexWireOptional<String> = .omitted,
        commandActions:
            CodexWireOptional<[CodexJSONValue]> = .omitted,
        proposedExecpolicyAmendment:
            CodexWireOptional<CodexJSONValue> = .omitted,
        proposedNetworkPolicyAmendments:
            CodexWireOptional<[CodexJSONValue]> = .omitted
    ) -> Self {
        var fields: [String: CodexJSONValue] = [
            "threadId": .string(threadID),
            "turnId": .string(turnID),
            "itemId": .string(itemID),
            "startedAtMs": .integer(startedAtMs),
            "environmentId": environmentID.map(CodexJSONValue.string)
                ?? .null,
        ]
        add(approvalID, as: "approvalId", to: &fields)
        add(reason, as: "reason", to: &fields)
        add(
            networkApprovalContext,
            as: "networkApprovalContext",
            to: &fields
        )
        add(command, as: "command", to: &fields)
        add(cwd, as: "cwd", to: &fields)
        add(commandActions, as: "commandActions", to: &fields)
        add(
            proposedExecpolicyAmendment,
            as: "proposedExecpolicyAmendment",
            to: &fields
        )
        add(
            proposedNetworkPolicyAmendments,
            as: "proposedNetworkPolicyAmendments",
            to: &fields
        )
        return Self(
            method: "item/commandExecution/requestApproval",
            params: .object(fields)
        )
    }

    public static func permissions(
        threadID: String,
        turnID: String,
        itemID: String,
        environmentID: String?,
        startedAtMs: Int64,
        cwd: String,
        reason: String?,
        permissions: CodexJSONValue
    ) -> Self {
        Self(
            method: "item/permissions/requestApproval",
            params: .object([
                "threadId": .string(threadID),
                "turnId": .string(turnID),
                "itemId": .string(itemID),
                "environmentId":
                    environmentID.map(CodexJSONValue.string) ?? .null,
                "startedAtMs": .integer(startedAtMs),
                "cwd": .string(cwd),
                "reason": reason.map(CodexJSONValue.string) ?? .null,
                "permissions": permissions,
            ])
        )
    }

    public static func applyPatch(
        conversationID: String,
        callID: String,
        fileChanges: [String: CodexJSONValue],
        reason: String?,
        grantRoot: String?
    ) -> Self {
        Self(
            method: "applyPatchApproval",
            params: .object([
                "conversationId": .string(conversationID),
                "callId": .string(callID),
                "fileChanges": .object(fileChanges),
                "reason": reason.map(CodexJSONValue.string) ?? .null,
                "grantRoot": grantRoot.map(CodexJSONValue.string) ?? .null,
            ])
        )
    }

    public static func execCommand(
        conversationID: String,
        callID: String,
        approvalID: String?,
        command: [String],
        cwd: String,
        reason: String?,
        parsedCommand: [CodexJSONValue]
    ) -> Self {
        Self(
            method: "execCommandApproval",
            params: .object([
                "conversationId": .string(conversationID),
                "callId": .string(callID),
                "approvalId":
                    approvalID.map(CodexJSONValue.string) ?? .null,
                "command": .array(command.map(CodexJSONValue.string)),
                "cwd": .string(cwd),
                "reason": reason.map(CodexJSONValue.string) ?? .null,
                "parsedCmd": .array(parsedCommand),
            ])
        )
    }

    private static func add(
        _ field: CodexWireOptional<String>,
        as key: String,
        to fields: inout [String: CodexJSONValue]
    ) {
        switch field {
        case .omitted:
            break
        case .null:
            fields[key] = .null
        case .value(let value):
            fields[key] = .string(value)
        }
    }

    private static func add(
        _ field: CodexWireOptional<CodexJSONValue>,
        as key: String,
        to fields: inout [String: CodexJSONValue]
    ) {
        switch field {
        case .omitted:
            break
        case .null:
            fields[key] = .null
        case .value(let value):
            fields[key] = value
        }
    }

    private static func add(
        _ field: CodexWireOptional<[CodexJSONValue]>,
        as key: String,
        to fields: inout [String: CodexJSONValue]
    ) {
        switch field {
        case .omitted:
            break
        case .null:
            fields[key] = .null
        case .value(let value):
            fields[key] = .array(value)
        }
    }
}

/// Routes app-server approval requests through the released renderer and
/// resumes the suspended workspace operation when its MCP response arrives.
@MainActor
public final class CodexDesktopApprovalBroker {
    public typealias Send = (CodexDesktopHostMessage) async -> Void

    private let hostID: String
    private let send: Send
    private var sequence: Int64 = 0
    private var pending:
        [
            CodexAppServerRequestID:
                CheckedContinuation<CodexJSONValue?, Never>
        ] = [:]

    public init(
        hostID: String = "local",
        send: @escaping Send
    ) {
        self.hostID = hostID
        self.send = send
    }

    public func requestFileChange(
        _ activity: CodexPersistedTurnWorkspaceToolActivity,
        timeoutNanoseconds: UInt64 = 300_000_000_000
    ) async -> Bool {
        let result = await request(
            .fileChange(
                threadID: activity.request.threadID.rawValue,
                turnID: activity.request.turnID,
                itemID: activity.request.callID,
                startedAtMs: Int64(
                    Date().timeIntervalSince1970 * 1_000
                ),
                reason: .value("Allow this workspace file change"),
                grantRoot: .null
            ),
            idPrefix: "file-approval",
            timeoutNanoseconds: timeoutNanoseconds
        )
        return Self.accepted(result)
    }

    public func requestApproval(
        _ activity: CodexPersistedTurnWorkspaceToolActivity,
        timeoutNanoseconds: UInt64 = 300_000_000_000
    ) async -> Bool {
        guard activity.request.name == "exec_command" else {
            return await requestFileChange(
                activity,
                timeoutNanoseconds: timeoutNanoseconds
            )
        }
        guard
            let data = activity.request.arguments.data(using: .utf8),
            let decoded =
                try? JSONDecoder().decode(
                    CodexJSONValue.self,
                    from: data
                ),
            case let .object(fields) = decoded,
            case let .string(command)? = fields["cmd"],
            !command.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).isEmpty
        else {
            return false
        }
        let cwdValue: String
        if case let .string(workdir)? = fields["workdir"] {
            cwdValue = workdir
        } else {
            cwdValue = "/"
        }
        if let permissions = fields["permissions"] {
            guard case .object = permissions else {
                return false
            }
            let reason: String?
            if case let .string(value)? = fields["justification"] {
                reason = value
            } else {
                reason = nil
            }
            let result = await request(
                .permissions(
                    threadID: activity.request.threadID.rawValue,
                    turnID: activity.request.turnID,
                    itemID: activity.request.callID,
                    environmentID: nil,
                    startedAtMs: Int64(
                        Date().timeIntervalSince1970 * 1_000
                    ),
                    cwd: cwdValue,
                    reason: reason,
                    permissions: permissions
                ),
                idPrefix: "permissions-approval",
                timeoutNanoseconds: timeoutNanoseconds
            )
            return Self.accepted(result)
        }
        let cwd: CodexWireOptional<String>
        if case let .string(workdir)? = fields["workdir"] {
            cwd = .value(workdir)
        } else {
            cwd = .null
        }
        let result = await request(
            .commandExecution(
                threadID: activity.request.threadID.rawValue,
                turnID: activity.request.turnID,
                itemID: activity.request.callID,
                startedAtMs: Int64(
                    Date().timeIntervalSince1970 * 1_000
                ),
                approvalID: .null,
                environmentID: nil,
                reason: .omitted,
                networkApprovalContext: .omitted,
                command: .value(command),
                cwd: cwd,
                commandActions: .omitted,
                proposedExecpolicyAmendment: .omitted,
                proposedNetworkPolicyAmendments: .omitted
            ),
            idPrefix: "command-approval",
            timeoutNanoseconds: timeoutNanoseconds
        )
        return Self.accepted(result)
    }

    public func request(
        _ approval: CodexDesktopApprovalRequest,
        timeoutNanoseconds: UInt64 = 300_000_000_000
    ) async -> CodexJSONValue? {
        await request(
            approval,
            idPrefix: "approval",
            timeoutNanoseconds: timeoutNanoseconds
        )
    }

    private func request(
        _ approval: CodexDesktopApprovalRequest,
        idPrefix: String,
        timeoutNanoseconds: UInt64
    ) async -> CodexJSONValue? {
        sequence &+= 1
        let id = CodexAppServerRequestID.string(
            "\(idPrefix)-\(sequence)"
        )
        return await withCheckedContinuation { continuation in
            pending[id] = continuation
            Task { @MainActor [weak self] in
                guard let self else {
                    continuation.resume(returning: nil)
                    return
                }
                await self.send(
                    .mcpRequest(
                        hostID: self.hostID,
                        request: CodexDesktopMCPRequestMessage(
                            id: id,
                            method: approval.method,
                            params: approval.params,
                            metadata: [:]
                        ),
                        metadata: [:]
                    )
                )
            }
            Task { @MainActor [weak self] in
                try? await Task.sleep(
                    nanoseconds: timeoutNanoseconds
                )
                self?.resolve(id: id, result: nil)
            }
        }
    }

    @discardableResult
    public func receive(
        hostID: String,
        response: CodexDesktopMCPClientResponse
    ) -> Bool {
        guard hostID == self.hostID, pending[response.id] != nil else {
            return false
        }
        resolve(
            id: response.id,
            result: response.error == nil ? response.result : nil
        )
        return true
    }

    public func cancelAll() {
        let continuations = Array(pending.values)
        pending.removeAll()
        for continuation in continuations {
            continuation.resume(returning: nil)
        }
    }

    private func resolve(
        id: CodexAppServerRequestID,
        result: CodexJSONValue?
    ) {
        guard let continuation = pending.removeValue(forKey: id)
        else {
            return
        }
        continuation.resume(returning: result)
    }

    private static func accepted(_ result: CodexJSONValue?) -> Bool {
        guard case let .object(fields)? = result
        else {
            return false
        }
        if case .object? = fields["permissions"],
           case let .string(scope)? = fields["scope"],
           ["turn", "session"].contains(scope)
        {
            return true
        }
        guard let decision = fields["decision"] else {
            return false
        }
        switch decision {
        case .string("accept"),
            .string("acceptForSession"),
            .string("approved"),
            .string("approved_for_session"):
            return true
        case .object(let value):
            return value["acceptWithExecpolicyAmendment"] != nil
                || value["applyNetworkPolicyAmendment"] != nil
                || value["approved_execpolicy_amendment"] != nil
                || value["network_policy_amendment"] != nil
        default:
            return false
        }
    }
}
