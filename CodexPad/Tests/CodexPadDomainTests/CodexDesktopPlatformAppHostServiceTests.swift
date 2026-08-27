import Foundation
import Testing

@testable import CodexPadApplication

@Test
func desktopPlatformAppHostRoutesNotificationShowAndHide() async throws {
    let recorder = AppHostNotificationRecorder()
    let service = CodexDesktopPlatformAppHostService(
        notificationOperation: { operation in
            await recorder.append(operation)
        },
        settingsOperation: { _ in }
    )

    #expect(
        try await service.invoke(
            service: "notifications",
            method: "show",
            arguments: [
                .object([
                    "id": .string("turn-1"),
                    "kind": .string("turn-complete"),
                    "title": .string("Finished"),
                    "body": .string("Task completed"),
                ])
            ]
        ) == .undefined
    )
    #expect(
        try await service.invoke(
            service: "notifications",
            method: "hide",
            arguments: [
                .object(["notificationId": .string("turn-1")])
            ]
        ) == .undefined
    )

    #expect(
        await recorder.operations == [
            .show(
                id: "turn-1",
                title: "Finished",
                body: "Task completed"
            ),
            .hide(
                notificationID: "turn-1",
                conversationID: nil,
                navigationPath: nil
            ),
        ]
    )
}

@Test
func desktopPlatformAppHostRoutesAllReleasedPermissionEntrypoints()
    async throws
{
    let recorder = AppHostSettingsRecorder()
    let service = CodexDesktopPlatformAppHostService(
        notificationOperation: { _ in },
        settingsOperation: { operation in
            await recorder.append(operation)
        }
    )
    for method in [
        "openAccessibilitySettings",
        "openMicrophoneSettings",
        "openNotificationSettings",
        "openScreenRecordingSettings",
        "requestMicrophoneAccess",
        "showPermissionSettingsAppInFinder",
    ] {
        #expect(
            try await service.invoke(
                service: "systemPermissions",
                method: method,
                arguments: []
            ) == .undefined
        )
    }
    #expect(
        await recorder.operations == [
            .openAccessibilitySettings,
            .openMicrophoneSettings,
            .openNotificationSettings,
            .openScreenRecordingSettings,
            .requestMicrophoneAccess,
            .showPermissionSettingsAppInFinder,
        ]
    )
}

@Test
func desktopPlatformAppHostReturnsReleasedFontFamilySchema() async throws {
    let service = CodexDesktopPlatformAppHostService(
        notificationOperation: { _ in },
        settingsOperation: { _ in }
    )

    let response = try await service.invoke(
        service: "systemFonts",
        method: "getFontFamilies",
        arguments: []
    )
    guard case let .array(families) = response else {
        Issue.record("systemFonts.getFontFamilies must return an array")
        return
    }
    guard case let .object(family)? = families.first,
          case let .string(familyName)? = family["family"],
          case let .array(faces)? = family["faces"],
          case let .object(face)? = faces.first,
          case let .string(fullName)? = face["fullName"],
          case let .string(postscriptName)? = face["postscriptName"],
          case let .string(styleName)? = face["styleName"]
    else {
        Issue.record(
            "font families must contain family and non-empty faces fields"
        )
        return
    }

    #expect(!familyName.isEmpty)
    #expect(!fullName.isEmpty)
    #expect(!postscriptName.isEmpty)
    #expect(!styleName.isEmpty)
    #expect(face["isMonospaced"] == .bool(true)
        || face["isMonospaced"] == .bool(false))
}

@Test
func desktopPlatformAppHostRoutesOpenInDetectionAndIconProviders()
    async throws
{
    let service = CodexDesktopPlatformAppHostService(
        notificationOperation: { _ in },
        settingsOperation: { _ in },
        openInTargetAvailabilityProvider: { target in
            #expect(target == "editor-x")
            return .object(["available": .bool(true)])
        },
        openInTargetIconProvider: { target in
            #expect(target == "editor-x")
            return .object([
                "mimeType": .string("image/png"),
                "data": .string("base64-data"),
            ])
        }
    )

    #expect(
        try await service.invoke(
            service: "openIn",
            method: "detectTarget",
            arguments: [.object(["target": .string("editor-x")])]
        ) == .object(["available": .bool(true)])
    )
    #expect(
        try await service.invoke(
            service: "openIn",
            method: "loadTargetIcon",
            arguments: [.object(["target": .string("editor-x")])]
        ) == .object([
            "mimeType": .string("image/png"),
            "data": .string("base64-data"),
        ])
    )
}

@Test
func desktopPlatformAppHostRejectsMalformedOpenInDetectionRequests()
    async throws
{
    let service = CodexDesktopPlatformAppHostService(
        notificationOperation: { _ in },
        settingsOperation: { _ in }
    )
    let malformed: [[CodexDesktopAppHostRPC.Value]] = [
        [],
        [.object(["target": .string("")])],
        [.object(["target": .bool(true)])],
        [.object(["target": .string("systemDefault")]), .null],
    ]
    for arguments in malformed {
        await #expect(throws: CodexDesktopPlatformAppHostService.Error.invalidArguments) {
            try await service.invoke(
                service: "openIn",
                method: "detectTarget",
                arguments: arguments
            )
        }
        await #expect(throws: CodexDesktopPlatformAppHostService.Error.invalidArguments) {
            try await service.invoke(
                service: "openIn",
                method: "loadTargetIcon",
                arguments: arguments
            )
        }
    }
}

@Test
func desktopPlatformAppHostProvidesAndUsesOpenInTarget() async throws {
    let recorder = AppHostOpenRecorder()
    let service = CodexDesktopPlatformAppHostService(
        notificationOperation: { _ in },
        settingsOperation: { _ in },
        openURL: { url in
            await recorder.append(url)
            return true
        }
    )
    let targets = try await service.invoke(
        service: "openIn",
        method: "getTargets",
        arguments: [.object(["cwd": .string("/workspace")])]
    )
    guard case let .object(fields) = targets,
          case let .array(targetValues)? = fields["targets"]
    else {
        Issue.record("openIn targets must use the released object shape")
        return
    }
    #expect(fields["mode"] == .string("native"))
    #expect(targetValues.count == 1)

    #expect(
        try await service.invoke(
            service: "openIn",
            method: "setGlobalPreferredTarget",
            arguments: [
                .object(["target": .string("systemDefault")])
            ]
        ) == .object(["success": .bool(true)])
    )
    #expect(
        try await service.invoke(
            service: "openIn",
            method: "open",
            arguments: [
                .object([
                    "path": .string("https://example.invalid/item"),
                    "target": .string("systemDefault"),
                ])
            ]
        ) == .object(["success": .bool(true)])
    )
    #expect(
        await recorder.urls.map(\.absoluteString)
            == ["https://example.invalid/item"]
    )
}

private actor AppHostNotificationRecorder {
    private(set) var operations:
        [CodexDesktopPlatformAppHostService.NotificationOperation] = []

    func append(
        _ operation:
            CodexDesktopPlatformAppHostService.NotificationOperation
    ) {
        operations.append(operation)
    }
}

private actor AppHostSettingsRecorder {
    private(set) var operations:
        [CodexDesktopPlatformAppHostService.SettingsOperation] = []

    func append(
        _ operation:
            CodexDesktopPlatformAppHostService.SettingsOperation
    ) {
        operations.append(operation)
    }
}

private actor AppHostOpenRecorder {
    private(set) var urls: [URL] = []

    func append(_ url: URL) {
        urls.append(url)
    }
}
