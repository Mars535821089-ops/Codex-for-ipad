import Foundation
import Testing

@testable import CodexPadApplication

private typealias UtilityValue = CodexDesktopAppHostRPC.Value

@Test
func desktopUtilityWritesClipboardThroughPlatformHandler() async throws {
    let recorder = UtilityRecorder()
    let service = CodexDesktopUtilityAppHostService(
        codexHome: FileManager.default.temporaryDirectory,
        clipboardWriter: { text in await recorder.recordText(text) }
    )

    #expect(
        try await service.invoke(
            service: "clipboard",
            method: "writeText",
            arguments: [.string("copied")]
        ) == .undefined
    )
    #expect(await recorder.texts == ["copied"])
}

@Test
func desktopUtilityPersistsReleasedBrowserPermissionShape() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let service = CodexDesktopUtilityAppHostService(codexHome: root)

    let approval = try await service.invoke(
        service: "browserUsePermissions",
        method: "updateIabHistoryApprovalMode",
        arguments: [.string("neverAsk")]
    )
    #expect(
        approval.objectFields?["iabHistoryApprovalMode"]
            == .string("neverAsk")
    )

    let updated = try await service.invoke(
        service: "browserUsePermissions",
        method: "updateOriginRules",
        arguments: [
            .array([
                .object([
                    "action": .string("add"),
                    "kind": .string("allowed"),
                    "origin": .string("example.com/path"),
                    "resource": .string("navigation"),
                ]),
            ])
        ]
    )
    #expect(
        updated.objectFields?["allowedOrigins"]
            == .array([.string("https://example.com")])
    )

    let reloaded = CodexDesktopUtilityAppHostService(codexHome: root)
    let persisted = try await reloaded.invoke(
        service: "browserUsePermissions",
        method: "updateOriginRules",
        arguments: [.array([])]
    )
    #expect(
        persisted.objectFields?["iabHistoryApprovalMode"]
            == .string("neverAsk")
    )
}

@Test
func desktopUtilityPersistsAndRestoresWebMcpEnabledState() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }

    let service = CodexDesktopUtilityAppHostService(codexHome: root)
    let enabled = try await service.invoke(
        service: "browserUsePermissions",
        method: "updateWebMcpEnabled",
        arguments: [.bool(true)]
    )
    #expect(enabled.objectFields?["webMcpEnabled"] == .bool(true))

    let reloaded = CodexDesktopUtilityAppHostService(codexHome: root)
    let disabled = try await reloaded.invoke(
        service: "browserUsePermissions",
        method: "updateWebMcpEnabled",
        arguments: [.bool(false)]
    )
    #expect(disabled.objectFields?["webMcpEnabled"] == .bool(false))
}

@Test
func desktopUtilityAcceptsLegacyPermissionStateWithoutWebMcpField()
    async throws
{
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(
        at: root,
        withIntermediateDirectories: true
    )
    let legacy = Data(#"{"iabHistoryApprovalMode":"neverAsk","origins":{}}"#.utf8)
    try legacy.write(
        to: root.appendingPathComponent("browser-use-permissions.json")
    )

    let service = CodexDesktopUtilityAppHostService(codexHome: root)
    let snapshot = try await service.invoke(
        service: "browserUsePermissions",
        method: "updateWebMcpEnabled",
        arguments: [.bool(true)]
    )
    #expect(snapshot.objectFields?["iabHistoryApprovalMode"] == .string("neverAsk"))
    #expect(snapshot.objectFields?["webMcpEnabled"] == .bool(true))
}

@Test
func desktopUtilityRejectsMalformedWebMcpEnabledArguments() async throws {
    let service = CodexDesktopUtilityAppHostService(
        codexHome: FileManager.default.temporaryDirectory
    )
    let malformedArguments: [[UtilityValue]] = [
        [],
        [.string("true")],
        [.bool(true), .bool(false)],
    ]
    for arguments in malformedArguments {
        await #expect(throws: CodexDesktopUtilityAppHostService.Error.invalidArguments) {
            try await service.invoke(
                service: "browserUsePermissions",
                method: "updateWebMcpEnabled",
                arguments: arguments
            )
        }
    }
}

@Test
func desktopUtilityRoutesBrowserProfileAndScheduledTaskProviders()
    async throws
{
    let recorder = UtilityRecorder()
    let profiles: [UtilityValue] = [
        .object([
            "source": .string("safari"),
            "profilePath": .string("default"),
        ]),
    ]
    let service = CodexDesktopUtilityAppHostService(
        codexHome: FileManager.default.temporaryDirectory,
        listBrowserProfiles: { profiles },
        importBrowserProfile: { request in
            await recorder.recordProfile(request)
            return .object(["imported": .bool(true)])
        },
        listPluginScheduledTasks: { request in
            await recorder.recordScheduledTaskRequest(request)
            return .object(["groups": .array([])])
        }
    )

    #expect(
        try await service.invoke(
            service: "browserProfileImport",
            method: "listImportableBrowserProfiles",
            arguments: []
        ) == .array(profiles)
    )
    let request = UtilityValue.object([
        "source": .string("safari"),
        "profilePath": .string("default"),
        "importCookies": .bool(true),
    ])
    #expect(
        try await service.invoke(
            service: "browserProfileImport",
            method: "importBrowserProfile",
            arguments: [request]
        ) == .object(["imported": .bool(true)])
    )
    let scheduledRequest = UtilityValue.object([
        "buildFlavor": .string("prod"),
        "cwds": .array([]),
        "hiddenMarketplaceNames": .array([]),
    ])
    #expect(
        try await service.invoke(
            service: "pluginScheduledTasks",
            method: "list",
            arguments: [scheduledRequest]
        ) == .object(["groups": .array([])])
    )
    #expect(await recorder.profiles == [request])
    #expect(await recorder.scheduledRequests == [scheduledRequest])
}

@Test
func desktopUtilityTracksPerformanceSamplingLifecycle() async throws {
    let recorder = UtilityRecorder()
    let service = CodexDesktopUtilityAppHostService(
        codexHome: FileManager.default.temporaryDirectory,
        performanceOperation: { method, value in
            await recorder.recordPerformance(method, value)
            return method == "finishSpanCpuSampling"
                ? .object(["samples": .integer(4)])
                : .undefined
        }
    )

    for method in [
        "startSpanCpuSampling",
        "cancelSpanCpuSampling",
        "finishSpanCpuSampling",
    ] {
        _ = try await service.invoke(
            service: "performanceTelemetry",
            method: method,
            arguments: [.string("span-1")]
        )
    }
    #expect(
        await recorder.performanceMethods == [
            "startSpanCpuSampling",
            "cancelSpanCpuSampling",
            "finishSpanCpuSampling",
        ]
    )
}

private actor UtilityRecorder {
    private(set) var texts: [String] = []
    private(set) var profiles: [UtilityValue] = []
    private(set) var scheduledRequests: [UtilityValue] = []
    private(set) var performanceMethods: [String] = []

    func recordText(_ text: String) { texts.append(text) }
    func recordProfile(_ value: UtilityValue) { profiles.append(value) }
    func recordScheduledTaskRequest(_ value: UtilityValue) {
        scheduledRequests.append(value)
    }
    func recordPerformance(_ method: String, _ value: UtilityValue) {
        _ = value
        performanceMethods.append(method)
    }
}

private extension CodexDesktopAppHostRPC.Value {
    var objectFields: [String: Self]? {
        guard case let .object(fields) = self else { return nil }
        return fields
    }
}
