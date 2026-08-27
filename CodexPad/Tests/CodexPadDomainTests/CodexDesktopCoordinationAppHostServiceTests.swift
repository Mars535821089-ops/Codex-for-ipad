import Foundation
import Testing

@testable import CodexPadApplication

@Test
func desktopComputerUseSettingsPersistReleasedShapes() async throws {
    let suiteName = "CodexDesktopComputerUseSettings-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    defaults.set(
        ["com.example.Editor", "com.example.Terminal"],
        forKey: "CodexDesktopComputerUse.approvedBundleIdentifiers"
    )
    defaults.set(
        ["chat-b": "Beta", "chat-a": "Alpha"],
        forKey: "CodexDesktopComputerUse.approvedChats"
    )
    let service = CodexDesktopCoordinationAppHostService(
        userDefaultsSuiteName: suiteName
    )

    #expect(
        try await service.invoke(
            service: "computerUseSettings",
            method: "getAppApprovals",
            arguments: nil
        ) == .object([
            "approvedApps": .array([
                .object([
                    "bundleIdentifier": .string("com.example.Editor"),
                    "displayName": .string("com.example.Editor"),
                    "iconDataURL": .null,
                ]),
                .object([
                    "bundleIdentifier": .string("com.example.Terminal"),
                    "displayName": .string("com.example.Terminal"),
                    "iconDataURL": .null,
                ]),
            ]),
            "approvedBundleIdentifiers": .array([
                .string("com.example.Editor"),
                .string("com.example.Terminal"),
            ]),
        ])
    )
    #expect(
        try await service.invoke(
            service: "computerUseSettings",
            method: "getMessagesSendApprovals",
            arguments: nil
        ) == .object([
            "approvedChats": .array([
                .object([
                    "chatGUID": .string("chat-a"),
                    "displayName": .string("Alpha"),
                ]),
                .object([
                    "chatGUID": .string("chat-b"),
                    "displayName": .string("Beta"),
                ]),
            ])
        ])
    )
}

@Test
func desktopComputerUseSettingsMutateAndReloadState() async throws {
    let suiteName = "CodexDesktopComputerUseSettings-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    defaults.set(
        ["com.example.Editor"],
        forKey: "CodexDesktopComputerUse.approvedBundleIdentifiers"
    )
    defaults.set(
        ["chat-a": "Alpha"],
        forKey: "CodexDesktopComputerUse.approvedChats"
    )
    let service = CodexDesktopCoordinationAppHostService(
        userDefaultsSuiteName: suiteName
    )

    #expect(
        try await service.invoke(
            service: "computerUseSettings",
            method: "removeAppApproval",
            arguments: [.string("com.example.Editor")]
        ) == .object([
            "approvedApps": .array([]),
            "approvedBundleIdentifiers": .array([]),
        ])
    )
    #expect(
        try await service.invoke(
            service: "computerUseSettings",
            method: "removeMessagesSendApproval",
            arguments: [.string("chat-a")]
        ) == .object(["approvedChats": .array([])])
    )
    #expect(
        try await service.invoke(
            service: "computerUseSettings",
            method: "setSoundMode",
            arguments: [.string("off")]
        ) == .string("off")
    )
    #expect(
        try await service.invoke(
            service: "computerUseSettings",
            method: "setLockedUseEnabled",
            arguments: [.bool(true)]
        ) == .bool(true)
    )

    let reloaded = CodexDesktopCoordinationAppHostService(
        userDefaultsSuiteName: suiteName
    )
    #expect(
        try await reloaded.invoke(
            service: "computerUseSettings",
            method: "getSoundMode",
            arguments: nil
        ) == .string("off")
    )
    #expect(
        try await reloaded.invoke(
            service: "computerUseSettings",
            method: "getLockedUseState",
            arguments: nil
        ) == .object([
            "enabled": .bool(true),
            "computerIconDataURL": .null,
            "lockIconDataURL": .null,
        ])
    )
}

@Test
func desktopClientCoordinationTracksSingleSceneThreadState()
    async throws
{
    let service = CodexDesktopCoordinationAppHostService()
    let calls: [(String, [CodexDesktopAppHostRPC.Value])] = [
        (
            "threadStreamFollowingChanged",
            [
                .object([
                    "params": .object([
                        "conversationId": .string("thread-1"),
                        "hostId": .string("local"),
                        "following": .bool(true),
                    ]),
                    "targetClientIds": .array([.string("scene-1")]),
                ])
            ]
        ),
        (
            "threadReadStateChanged",
            [
                .object([
                    "conversationId": .string("thread-1"),
                    "hostId": .string("local"),
                    "hasUnreadTurn": .bool(true),
                ])
            ]
        ),
        (
            "threadArchived",
            [
                .object([
                    "conversationId": .string("thread-1"),
                    "hostId": .string("local"),
                ])
            ]
        ),
    ]

    for (method, arguments) in calls {
        #expect(
            try await service.invoke(
                service: "clientCoordination",
                method: method,
                arguments: arguments
            ) == .undefined
        )
    }
    #expect(
        await service.threadState(
            hostID: "local",
            conversationID: "thread-1"
        ) == .init(
            following: true,
            hasUnreadTurn: true,
            archived: true,
            streamChange: nil
        )
    )
}

@Test
func desktopClientCoordinationTracksReleasedThreadOwnership()
    async throws
{
    let service = CodexDesktopCoordinationAppHostService()

    #expect(
        try await service.invoke(
            service: "clientCoordination",
            method: "setThreadOwnership",
            arguments: [
                .object([
                    "hostId": .string("local"),
                    "conversationId": .string("thread-1"),
                    "ownsThread": .bool(true),
                ])
            ]
        ) == .undefined
    )
    #expect(
        await service.threadState(
            hostID: "local",
            conversationID: "thread-1"
        ) == .init(ownsThread: true)
    )
}

@Test
func desktopClientCoordinationForwardsReleasedPayloads()
    async throws
{
    actor Events {
        var values: [(String, [CodexDesktopAppHostRPC.Value]?)] = []
        func append(
            _ method: String,
            _ arguments: [CodexDesktopAppHostRPC.Value]?
        ) {
            values.append((method, arguments))
        }
    }
    let events = Events()
    let service = CodexDesktopCoordinationAppHostService(
        eventHandler: {
        _, method, arguments in
        await events.append(method, arguments)
        }
    )

    for method in [
        "threadStreamFollowingStatusRequested",
        "threadStreamStateChanged",
        "threadUnarchived",
    ] {
        let arguments: [CodexDesktopAppHostRPC.Value] = [
            .object([
                "conversationId": .string("thread-1"),
                "hostId": .string("local"),
            ])
        ]
        #expect(
            try await service.invoke(
                service: "clientCoordination",
                method: method,
                arguments: arguments
            ) == .undefined
        )
    }
    #expect(
        try await service.invoke(
            service: "clientCoordination",
            method: "threadQueuedFollowUpsChanged",
            arguments: [
                .object([
                    "conversationId": .string("thread-1"),
                    "messages": .array([
                        .object(["id": .string("queued-1")])
                    ]),
                ])
            ]
        ) == .undefined
    )
    #expect(
        try await service.invoke(
            service: "clientCoordination",
            method: "invalidateQueryCache",
            arguments: [
                .object([
                    "queryKey": .array([
                        .string("thread"),
                        .string("thread-1"),
                    ])
                ])
            ]
        ) == .undefined
    )

    #expect(await events.values.map(\.0) == [
        "threadStreamFollowingStatusRequested",
        "threadStreamStateChanged",
        "threadUnarchived",
        "threadQueuedFollowUpsChanged",
        "invalidateQueryCache",
    ])
    #expect(
        await service.queuedFollowUps(
            conversationID: "thread-1"
        ) == .array([
            .object(["id": .string("queued-1")])
        ])
    )
}

@Test
func desktopClientCoordinationReportsNoCompetingOwnerInSingleScene()
    async throws
{
    let service = CodexDesktopCoordinationAppHostService()

    #expect(
        try await service.invoke(
            service: "clientCoordination",
            method: "findThreadOwner",
            arguments: [
                .object([
                    "hostId": .string("local"),
                    "conversationId": .string("thread-1"),
                ])
            ]
        ) == .null
    )
}

@Test
func desktopClientCoordinationReturnsIPadIDEContextForWorkspace()
    async throws
{
    let service = CodexDesktopCoordinationAppHostService()

    #expect(
        try await service.invoke(
            service: "clientCoordination",
            method: "getIdeContext",
            arguments: [
                .object([
                    "workspaceRoot": .string("/workspace/project")
                ])
            ]
        ) == .object([
            "workspaceRoot": .string("/workspace/project")
        ])
    )
}

@Test
func desktopClientCoordinationProjectsQueryCacheInvalidationToRenderer()
    throws
{
    let arguments: [CodexDesktopAppHostRPC.Value] = [
        .object([
            "queryKey": .array([
                .array([
                    .string("vscode"),
                    .string("get-global-state"),
                    .string("{\"key\":\"selected-project\"}"),
                ])
            ])
        ])
    ]

    #expect(
        try CodexDesktopCoordinationAppHostService.rendererEvent(
            method: "invalidateQueryCache",
            arguments: arguments
        ) == .event(
            type: "query-cache-invalidate",
            payload: .object([
                "queryKey": .array([
                    .array([
                        .string("vscode"),
                        .string("get-global-state"),
                        .string("{\"key\":\"selected-project\"}"),
                    ])
                ])
            ])
        )
    )
}

@Test
func desktopClientCoordinationRejectsInvalidQueryCacheEvents() {
    let invalidArguments: [[CodexDesktopAppHostRPC.Value]?] = [
        nil,
        [],
        [.object([:])],
        [.object(["queryKey": .string("thread")])],
        [.object(["queryKey": .array([.undefined])])],
    ]

    for arguments in invalidArguments {
        #expect(throws: CodexDesktopCoordinationAppHostService.Error.self) {
            try CodexDesktopCoordinationAppHostService.rendererEvent(
                method: "invalidateQueryCache",
                arguments: arguments
            )
        }
    }
}
