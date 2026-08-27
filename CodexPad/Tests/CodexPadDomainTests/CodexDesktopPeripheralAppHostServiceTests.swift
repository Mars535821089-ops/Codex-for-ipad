import Foundation
import Testing

@testable import CodexPadApplication

@Test
func desktopAppshotForwardsLatestFinalUpdateRequest() async throws {
    let service = CodexDesktopPeripheralAppHostService(
        appshotHotkeyOperation: { method, arguments in
            #expect(method == "requestFinalUpdate")
            #expect(
                arguments == [
                    .object(["requestId": .string("request-1")])
                ]
            )
            return .bool(true)
        }
    )

    #expect(
        try await service.invoke(
            service: "appshot",
            method: "requestFinalUpdate",
            arguments: [
                .object(["requestId": .string("request-1")])
            ]
        ) == .bool(true)
    )
}

private typealias PeripheralService =
    CodexDesktopPeripheralAppHostService
private typealias PeripheralValue =
    CodexDesktopAppHostRPC.Value

@Test
func remoteControlEnvironmentRenameIfDefaultMatchesReleasedGuard() async throws {
    let transport = RemoteControlEnvironmentTransportStub(
        responses: [
            .init(
                status: 200,
                body: #"{"items":[{"env_id":"env-1","display_name":"Old Mac","host_name":"Old Mac"}],"cursor":null}"#
            ),
            .init(
                status: 200,
                body: #"{"env_id":"env-1","display_name":"Codex for ipad","host_name":"Old Mac"}"#
            ),
        ]
    )
    let backend = CodexDesktopRemoteControlEnvironmentBackend(
        credentialsProvider: {
            CodexOfficialCredentials(
                accessToken: "token",
                accountID: "account",
                authMethod: .chatGPT
            )
        },
        transport: transport
    )

    #expect(
        try await backend.invoke(
            method: "renameIfDefault",
            arguments: [.object([
                "envId": .string("env-1"),
                "name": .string("Codex for ipad"),
            ])]
        ) == .undefined
    )
    let requests = await transport.requests
    #expect(requests.map(\.method) == ["GET", "PATCH"])
    #expect(requests.last?.body == Data(#"{"name":"Codex for ipad"}"#.utf8))
}

@Test
func remoteControlEnvironmentRenameIfDefaultPreservesCustomName() async throws {
    let transport = RemoteControlEnvironmentTransportStub(
        responses: [
            .init(
                status: 200,
                body: #"{"items":[{"env_id":"env-1","display_name":"My Studio","host_name":"Old Mac"}],"cursor":null}"#
            )
        ]
    )
    let backend = CodexDesktopRemoteControlEnvironmentBackend(
        credentialsProvider: {
            CodexOfficialCredentials(
                accessToken: "token",
                accountID: "account",
                authMethod: .chatGPT
            )
        },
        transport: transport
    )

    _ = try await backend.invoke(
        method: "renameIfDefault",
        arguments: [.object([
            "envId": .string("env-1"),
            "name": .string("Codex for ipad"),
        ])]
    )
    #expect(await transport.requests.count == 1)
}

@Test
func desktopPeripheralUsesOfficialUnavailableAppshotState() async throws {
    let service = PeripheralService()

    #expect(
        try await service.invoke(
            service: "appshotHotkeys",
            method: "getState",
            arguments: []
        ) == .object([
            "supported": .bool(false),
            "configuredHotkey": .null,
            "isActive": .bool(false),
        ])
    )
    await #expect(
        throws: PeripheralService.Error.unavailable(
            service: "appshotHotkeys",
            method: "setHotkey"
        )
    ) {
        _ = try await service.invoke(
            service: "appshotHotkeys",
            method: "setHotkey",
            arguments: [.string("DoubleCommand")]
        )
    }
}

@Test
func desktopPeripheralValidatesAndForwardsAppshotHotkeys() async throws {
    let recorder = PeripheralOperationRecorder()
    let service = PeripheralService(
        appshotHotkeyOperation: { method, arguments in
            await recorder.record(
                service: "appshotHotkeys",
                method: method,
                arguments: arguments
            )
            return .object(["success": .bool(true)])
        }
    )

    for hotkey in [
        PeripheralValue.string("DoubleCommand"),
        .string("DoubleOption"),
        .string("DoubleShift"),
        .null,
    ] {
        #expect(
            try await service.invoke(
                service: "appshotHotkeys",
                method: "setHotkey",
                arguments: [hotkey]
            ) == .object(["success": .bool(true)])
        )
    }
    #expect(await recorder.events.count == 4)

    await #expect(throws: PeripheralService.Error.invalidArguments) {
        _ = try await service.invoke(
            service: "appshotHotkeys",
            method: "setHotkey",
            arguments: [.string("CommandOrControl+K")]
        )
    }
}

@Test
func desktopPeripheralRoutesBothHotkeyWindowAliasesThroughOneBoundary()
    async throws
{
    let recorder = PeripheralOperationRecorder()
    let service = PeripheralService(
        hotkeyWindowOperation: { method, arguments in
            await recorder.record(
                service: "hotkey-window",
                method: method,
                arguments: arguments
            )
            if method == "getState" {
                return .object([
                    "supported": .bool(true),
                    "configuredHotkey": .null,
                    "isActive": .bool(false),
                ])
            }
            return .undefined
        }
    )
    let invocations: [(String, [PeripheralValue])] = [
        ("getState", []),
        ("setEnabled", [.bool(true)]),
        ("toggle", []),
        ("open", [.object(["path": .string("/thread/1")])]),
        ("collapseToHome", []),
        ("dismiss", []),
        ("setHotkey", [.string("CommandOrControl+Space")]),
        ("setDevOverrideEnabled", [.bool(true)]),
        (
            "transitionDone",
            [
                .object([
                    "transitionId": .string("transition-1"),
                    "step": .string("raised"),
                ])
            ]
        ),
        (
            "homePointerInteractionChanged",
            [.object(["isInteractive": .bool(true)])]
        ),
        (
            "homeLayoutChanged",
            [
                .object([
                    "minimumComposerTopInsetPx": .integer(20),
                    "restingComposerTopInsetPx": .integer(40),
                ])
            ]
        ),
        (
            "homeDragStart",
            [
                .object([
                    "pointerWindowX": .number(10.5),
                    "pointerWindowY": .number(20.5),
                ])
            ]
        ),
        ("homeDragMove", []),
        ("homeDragEnd", []),
    ]

    for alias in ["hotkeyWindowCommands", "hotkeyWindowHotkeys"] {
        for (method, arguments) in invocations {
            _ = try await service.invoke(
                service: alias,
                method: method,
                arguments: arguments
            )
        }
    }

    let events = await recorder.events
    #expect(events.count == invocations.count * 2)
    #expect(
        events.map(\.method)
            == invocations.map(\.0) + invocations.map(\.0)
    )
}

@Test
func desktopPeripheralHotkeyWindowIsUnavailableWithoutPlatformHandler()
    async throws
{
    let service = PeripheralService()

    for alias in ["hotkeyWindowCommands", "hotkeyWindowHotkeys"] {
        await #expect(
            throws: PeripheralService.Error.unavailable(
                service: alias,
                method: "getState"
            )
        ) {
            _ = try await service.invoke(
                service: alias,
                method: "getState",
                arguments: []
            )
        }
    }
}

@Test
func desktopPeripheralRenamesRemoteEnvironmentIfDefault() async throws {
    let recorder = PeripheralOperationRecorder()
    let service = PeripheralService(
        remoteControlEnvironmentOperation: { method, arguments in
            await recorder.record(
                service: "remoteControlEnvironments",
                method: method,
                arguments: arguments
            )
            return .undefined
        }
    )
    let argument: PeripheralValue = .object([
        "envId": .string("env-1"),
        "name": .string("Development"),
    ])

    #expect(
        try await service.invoke(
            service: "remoteControlEnvironments",
            method: "renameIfDefault",
            arguments: [argument]
        ) == .undefined
    )
    #expect(
        await recorder.events.first?.arguments == [argument]
    )
}

@Test
func desktopPeripheralReportsUnavailableForMissingOperations()
    async throws
{
    let service = PeripheralService()
    let remoteArgument: PeripheralValue = .object([
        "envId": .string("env-1"),
        "name": .string("Development"),
    ])
    await #expect(
        throws: PeripheralService.Error.unavailable(
            service: "remoteControlEnvironments",
            method: "renameIfDefault"
        )
    ) {
        _ = try await service.invoke(
            service: "remoteControlEnvironments",
            method: "renameIfDefault",
            arguments: [remoteArgument]
        )
    }

    let generationArgument: PeripheralValue = .object([
        "appServerVersion": .string("0.0.0"),
        "hostId": .string("local"),
        "prompt": .string("generate"),
    ])
    await #expect(
        throws: PeripheralService.Error.unavailable(
            service: "pullRequestMessageGeneration",
            method: "generate"
        )
    ) {
        _ = try await service.invoke(
            service: "pullRequestMessageGeneration",
            method: "generate",
            arguments: [generationArgument]
        )
    }
}

@Test
func desktopPeripheralWaitsForAndReleasesPullRequestGeneration()
    async throws
{
    let recorder = PullRequestGenerationRecorder()
    let service = PeripheralService(
        pullRequestGenerationOperation: { request in
            await recorder.recordRequest(request)
            return .init(rawValue: "generation-1")
        },
        pullRequestGenerationWait: { operation in
            await recorder.recordWait(operation)
            return .init(
                title: "Improve peripheral AppHost bridge",
                body: "## Summary\n- Add released service parity"
            )
        },
        pullRequestGenerationCancel: { operation in
            Task { await recorder.recordCancel(operation) }
        },
        pullRequestGenerationRelease: { operation in
            Task { await recorder.recordRelease(operation) }
        }
    )

    #expect(
        try await service.invoke(
            service: "pullRequestMessageGeneration",
            method: "generate",
            arguments: [
                .object([
                    "appServerVersion": .string("0.0.0"),
                    "hostId": .string("local"),
                    "prompt": .string("  describe the changes  "),
                ])
            ]
        ) == .object([
            "title": .string("Improve peripheral AppHost bridge"),
            "body": .string(
                "## Summary\n- Add released service parity"
            ),
        ])
    )
    await recorder.waitForReleaseCount(1)
    #expect(
        await recorder.requests == [
            .init(
                appServerVersion: "0.0.0",
                hostID: "local",
                prompt: "describe the changes"
            )
        ]
    )
    #expect(
        await recorder.waitedOperations
            == [.init(rawValue: "generation-1")]
    )
    #expect(
        await recorder.releasedOperations
            == [.init(rawValue: "generation-1")]
    )
    #expect(await recorder.cancelledOperations.isEmpty)
}

@Test
func desktopPeripheralClampsPromptAndValidatesGeneratedMessageBounds()
    async throws
{
    let recorder = PullRequestGenerationRecorder()
    let longPrompt = String(repeating: "p", count: 30_001)
    let service = PeripheralService(
        pullRequestGenerationOperation: { request in
            await recorder.recordRequest(request)
            return .init(rawValue: "generation-2")
        },
        pullRequestGenerationWait: { _ in
            .init(
                title: String(repeating: "t", count: 120),
                body: String(repeating: "b", count: 30_000)
            )
        }
    )

    _ = try await service.invoke(
        service: "pullRequestMessageGeneration",
        method: "generate",
        arguments: [
            .object([
                "appServerVersion": .string("0.0.0"),
                "hostId": .string("local"),
                "prompt": .string(longPrompt),
            ])
        ]
    )
    #expect(await recorder.requests.first?.prompt.count == 30_000)

    let invalid = PeripheralService(
        pullRequestGenerationOperation: { _ in
            .init(rawValue: "generation-invalid")
        },
        pullRequestGenerationWait: { _ in
            .init(title: "short", body: "also short")
        }
    )
    await #expect(
        throws: PeripheralService.Error.invalidGeneratedResult(
            field: "title"
        )
    ) {
        _ = try await invalid.invoke(
            service: "pullRequestMessageGeneration",
            method: "generate",
            arguments: [
                .object([
                    "appServerVersion": .string("0.0.0"),
                    "hostId": .string("local"),
                    "prompt": .string("generate"),
                ])
            ]
        )
    }
}

private actor RemoteControlEnvironmentTransportStub:
    CodexDesktopNetworkFetchTransport
{
    struct Response: Sendable {
        let status: Int
        let body: String
    }

    private var responses: [Response]
    private(set) var requests: [CodexDesktopNetworkTransportRequest] = []

    init(responses: [Response]) {
        self.responses = responses
    }

    func execute(
        _ request: CodexDesktopNetworkTransportRequest
    ) async throws -> CodexDesktopNetworkTransportResponse {
        requests.append(request)
        let response = responses.removeFirst()
        return .init(
            status: response.status,
            headers: [:],
            body: Data(response.body.utf8)
        )
    }
}

@Test
func desktopPeripheralCancelsAndReleasesFailedPullRequestGeneration()
    async throws
{
    let recorder = PullRequestGenerationRecorder()
    let service = PeripheralService(
        pullRequestGenerationOperation: { _ in
            .init(rawValue: "generation-cancelled")
        },
        pullRequestGenerationWait: { _ in
            throw CancellationError()
        },
        pullRequestGenerationCancel: { operation in
            Task { await recorder.recordCancel(operation) }
        },
        pullRequestGenerationRelease: { operation in
            Task { await recorder.recordRelease(operation) }
        }
    )

    await #expect(throws: CancellationError.self) {
        _ = try await service.invoke(
            service: "pullRequestMessageGeneration",
            method: "generate",
            arguments: [
                .object([
                    "appServerVersion": .string("0.0.0"),
                    "hostId": .string("local"),
                    "prompt": .string("generate"),
                ])
            ]
        )
    }
    await recorder.waitForCancelAndRelease()
    #expect(
        await recorder.cancelledOperations
            == [.init(rawValue: "generation-cancelled")]
    )
    #expect(
        await recorder.releasedOperations
            == [.init(rawValue: "generation-cancelled")]
    )
}

private actor PeripheralOperationRecorder {
    struct Event: Sendable {
        let service: String
        let method: String
        let arguments: [PeripheralValue]?
    }

    private(set) var events: [Event] = []

    func record(
        service: String,
        method: String,
        arguments: [PeripheralValue]?
    ) {
        events.append(
            .init(
                service: service,
                method: method,
                arguments: arguments
            )
        )
    }
}

private actor PullRequestGenerationRecorder {
    private(set) var requests:
        [PeripheralService.PullRequestGenerationRequest] = []
    private(set) var waitedOperations:
        [PeripheralService.PullRequestGenerationOperation] = []
    private(set) var cancelledOperations:
        [PeripheralService.PullRequestGenerationOperation] = []
    private(set) var releasedOperations:
        [PeripheralService.PullRequestGenerationOperation] = []

    func recordRequest(
        _ request: PeripheralService.PullRequestGenerationRequest
    ) {
        requests.append(request)
    }

    func recordWait(
        _ operation: PeripheralService.PullRequestGenerationOperation
    ) {
        waitedOperations.append(operation)
    }

    func recordCancel(
        _ operation: PeripheralService.PullRequestGenerationOperation
    ) {
        cancelledOperations.append(operation)
    }

    func recordRelease(
        _ operation: PeripheralService.PullRequestGenerationOperation
    ) {
        releasedOperations.append(operation)
    }

    func waitForReleaseCount(_ count: Int) async {
        while releasedOperations.count < count {
            await Task.yield()
        }
    }

    func waitForCancelAndRelease() async {
        while cancelledOperations.isEmpty
            || releasedOperations.isEmpty
        {
            await Task.yield()
        }
    }
}
