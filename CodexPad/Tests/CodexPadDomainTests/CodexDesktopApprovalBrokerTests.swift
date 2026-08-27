import Foundation
import Testing

@testable import CodexPadApplication
@testable import CodexPadDomain
@testable import CodexPadProtocolBridge

@Test
func desktopApprovalRequestFactoriesMatchEveryReleasedMethod() {
    let command = CodexDesktopApprovalRequest.commandExecution(
        threadID: "thread-1",
        turnID: "turn-1",
        itemID: "item-1",
        startedAtMs: 10,
        approvalID: .null,
        environmentID: nil,
        reason: .value("network"),
        networkApprovalContext: .omitted,
        command: .value("curl example.test"),
        cwd: .null,
        commandActions: .value([.object(["type": .string("read")])]),
        proposedExecpolicyAmendment: .omitted,
        proposedNetworkPolicyAmendments: .null
    )
    #expect(command.method == "item/commandExecution/requestApproval")
    #expect(
        command.params
            == .object([
                "threadId": .string("thread-1"),
                "turnId": .string("turn-1"),
                "itemId": .string("item-1"),
                "startedAtMs": .integer(10),
                "approvalId": .null,
                "environmentId": .null,
                "reason": .string("network"),
                "command": .string("curl example.test"),
                "cwd": .null,
                "commandActions": .array([
                    .object(["type": .string("read")])
                ]),
                "proposedNetworkPolicyAmendments": .null,
            ])
    )

    let permissions = CodexDesktopApprovalRequest.permissions(
        threadID: "thread-1",
        turnID: "turn-1",
        itemID: "item-2",
        environmentID: nil,
        startedAtMs: 20,
        cwd: "/workspace",
        reason: nil,
        permissions: .object([
            "network": .object(["enabled": .bool(true)]),
            "fileSystem": .null,
        ])
    )
    #expect(permissions.method == "item/permissions/requestApproval")
    #expect(
        permissions.params
            == .object([
                "threadId": .string("thread-1"),
                "turnId": .string("turn-1"),
                "itemId": .string("item-2"),
                "environmentId": .null,
                "startedAtMs": .integer(20),
                "cwd": .string("/workspace"),
                "reason": .null,
                "permissions": .object([
                    "network": .object(["enabled": .bool(true)]),
                    "fileSystem": .null,
                ]),
            ])
    )

    #expect(
        CodexDesktopApprovalRequest.applyPatch(
            conversationID: "thread-1",
            callID: "call-1",
            fileChanges: ["a.txt": .object(["type": .string("add")])],
            reason: nil,
            grantRoot: nil
        ).method == "applyPatchApproval"
    )
    #expect(
        CodexDesktopApprovalRequest.execCommand(
            conversationID: "thread-1",
            callID: "call-2",
            approvalID: nil,
            command: ["pwd"],
            cwd: "/workspace",
            reason: nil,
            parsedCommand: []
        ).method == "execCommandApproval"
    )
}

@Test
@MainActor
func desktopApprovalBrokerReturnsExactRendererResultForAnyReleasedMethod()
    async throws
{
    var sent: [CodexDesktopHostMessage] = []
    let broker = CodexDesktopApprovalBroker(
        hostID: "released-renderer",
        send: { sent.append($0) }
    )
    let approval = CodexDesktopApprovalRequest.permissions(
        threadID: "thread-1",
        turnID: "turn-1",
        itemID: "item-1",
        environmentID: nil,
        startedAtMs: 30,
        cwd: "/workspace",
        reason: "Need network",
        permissions: .object([
            "network": .object(["enabled": .bool(true)]),
            "fileSystem": .null,
        ])
    )
    let task = Task { @MainActor in
        await broker.request(
            approval,
            timeoutNanoseconds: 10_000_000_000
        )
    }
    let request = try await waitForApprovalRequest(in: sent)
    let exactResult: CodexJSONValue = .object([
        "permissions": .object([
            "network": .object(["enabled": .bool(true)])
        ]),
        "scope": .string("turn"),
        "strictAutoReview": .bool(true),
    ])

    #expect(request.message.method == approval.method)
    #expect(request.message.params == approval.params)
    #expect(
        broker.receive(
            hostID: "released-renderer",
            response: .init(
                id: request.message.id,
                result: exactResult,
                error: nil
            )
        )
    )
    #expect(await task.value == exactResult)
}

@Test
@MainActor
func desktopApprovalBrokerRoutesExecActivityToCommandApproval() async throws {
    var sent: [CodexDesktopHostMessage] = []
    let broker = CodexDesktopApprovalBroker(send: { sent.append($0) })
    let activity = CodexPersistedTurnWorkspaceToolActivity(
        request: .init(
            threadID: CodexStoredThreadID("thread-command"),
            turnID: "turn-command",
            roundIndex: 0,
            name: "exec_command",
            arguments:
                #"{"cmd":"pwd","workdir":"/workspace","tty":false}"#,
            callID: "call-command",
            itemJSON: "{}"
        ),
        decision: .requireApproval
    )
    let task = Task { @MainActor in
        await broker.requestApproval(
            activity,
            timeoutNanoseconds: 10_000_000_000
        )
    }
    let request = try await waitForApprovalRequest(in: sent)

    #expect(
        request.message.method
            == "item/commandExecution/requestApproval"
    )
    guard case let .object(params) = request.message.params else {
        Issue.record("expected command approval params")
        return
    }
    #expect(params["command"] == .string("pwd"))
    #expect(params["cwd"] == .string("/workspace"))
    #expect(params["environmentId"] == .null)
    #expect(
        broker.receive(
            hostID: "local",
            response: .init(
                id: request.message.id,
                result: .object(["decision": .string("accept")]),
                error: nil
            )
        )
    )
    #expect(await task.value)
}

@Test
@MainActor
func desktopApprovalBrokerRoutesRequestedProfileToPermissionsApproval()
    async throws
{
    var sent: [CodexDesktopHostMessage] = []
    let broker = CodexDesktopApprovalBroker(send: { sent.append($0) })
    let activity = CodexPersistedTurnWorkspaceToolActivity(
        request: .init(
            threadID: CodexStoredThreadID("thread-permissions"),
            turnID: "turn-permissions",
            roundIndex: 0,
            name: "exec_command",
            arguments: """
            {
              "cmd":"curl https://example.test",
              "workdir":"/workspace",
              "justification":"Allow this command to use the network",
              "permissions":{
                "network":{"enabled":true},
                "fileSystem":null
              }
            }
            """,
            callID: "call-permissions",
            itemJSON: "{}"
        ),
        decision: .requireApproval
    )
    let task = Task { @MainActor in
        await broker.requestApproval(
            activity,
            timeoutNanoseconds: 10_000_000_000
        )
    }
    let request = try await waitForApprovalRequest(in: sent)

    #expect(
        request.message.method
            == "item/permissions/requestApproval"
    )
    guard case let .object(params) = request.message.params else {
        Issue.record("expected permissions approval params")
        return
    }
    #expect(params["cwd"] == .string("/workspace"))
    #expect(
        params["reason"]
            == .string("Allow this command to use the network")
    )
    #expect(
        params["permissions"]
            == .object([
                "network": .object(["enabled": .bool(true)]),
                "fileSystem": .null,
            ])
    )
    #expect(
        broker.receive(
            hostID: "local",
            response: .init(
                id: request.message.id,
                result: .object([
                    "permissions": .object([
                        "network": .object(["enabled": .bool(true)]),
                        "fileSystem": .null,
                    ]),
                    "scope": .string("turn"),
                    "strictAutoReview": .bool(true),
                ]),
                error: nil
            )
        )
    )
    #expect(await task.value)
}

@MainActor
private func waitForApprovalRequest(
    in messages: @autoclosure () -> [CodexDesktopHostMessage]
) async throws -> (
    hostID: String,
    message: CodexDesktopMCPRequestMessage,
    metadata: [String: CodexJSONValue]
) {
    for _ in 0..<100 {
        for message in messages() {
            if case let .mcpRequest(hostID, request, metadata) = message {
                return (hostID, request, metadata)
            }
        }
        try await Task.sleep(nanoseconds: 1_000_000)
    }
    throw ApprovalTestError.requestNotSent
}

private enum ApprovalTestError: Error {
    case requestNotSent
}
