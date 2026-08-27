import Foundation
import CoreText
import UserNotifications

#if canImport(AVFAudio)
import AVFAudio
#endif
#if canImport(UIKit)
import UIKit
#endif

/// iPadOS-backed implementations for desktop notification and permission
/// AppHost services.
public actor CodexDesktopPlatformAppHostService {
    public typealias Value = CodexDesktopAppHostRPC.Value

    public enum NotificationOperation: Equatable, Sendable {
        case show(id: String, title: String, body: String)
        case hide(
            notificationID: String?,
            conversationID: String?,
            navigationPath: String?
        )
    }

    public enum SettingsOperation: Equatable, Sendable {
        case openAccessibilitySettings
        case openMicrophoneSettings
        case openNotificationSettings
        case openScreenRecordingSettings
        case requestMicrophoneAccess
        case showPermissionSettingsAppInFinder
    }

    public enum Error: Swift.Error, Equatable, Sendable {
        case invalidArguments
        case unsupportedMethod(service: String, method: String)
    }

    public typealias NotificationOperationHandler =
        @Sendable (NotificationOperation) async throws -> Void
    public typealias SettingsOperationHandler =
        @Sendable (SettingsOperation) async throws -> Void
    public typealias OpenURLHandler =
        @Sendable (URL) async -> Bool
    public typealias OpenInTargetAvailabilityProvider =
        @Sendable (String) async throws -> Value
    public typealias OpenInTargetIconProvider =
        @Sendable (String) async throws -> Value

    private let notificationOperation: NotificationOperationHandler
    private let settingsOperation: SettingsOperationHandler
    private let openURL: OpenURLHandler
    private let openInTargetAvailabilityProvider:
        OpenInTargetAvailabilityProvider
    private let openInTargetIconProvider: OpenInTargetIconProvider
    private var preferredOpenTarget: String?

    public init(
        notificationOperation: NotificationOperationHandler? = nil,
        settingsOperation: SettingsOperationHandler? = nil,
        openURL: OpenURLHandler? = nil,
        openInTargetAvailabilityProvider:
            OpenInTargetAvailabilityProvider? = nil,
        openInTargetIconProvider:
            OpenInTargetIconProvider? = nil
    ) {
        self.notificationOperation = notificationOperation
            ?? Self.performNotificationOperation
        self.settingsOperation = settingsOperation
            ?? Self.performSettingsOperation
        self.openURL = openURL ?? Self.performOpenURL
        self.openInTargetAvailabilityProvider =
            openInTargetAvailabilityProvider ?? { _ in
                .object(["available": .bool(false)])
            }
        self.openInTargetIconProvider =
            openInTargetIconProvider ?? { _ in .null }
    }

    public func invoke(
        service: String,
        method: String,
        arguments: [Value]?
    ) async throws -> Value {
        switch (service, method) {
        case ("notifications", "show"):
            let fields = try argumentObject(arguments)
            guard case let .string(id)? = fields["id"],
                  case let .string(title)? = fields["title"],
                  case let .string(body)? = fields["body"]
            else {
                throw Error.invalidArguments
            }
            try await notificationOperation(
                .show(id: id, title: title, body: body)
            )
            return .undefined

        case ("notifications", "hide"):
            let fields = try argumentObject(arguments)
            try await notificationOperation(
                .hide(
                    notificationID: Self.string(
                        fields["notificationId"]
                    ),
                    conversationID: Self.string(
                        fields["conversationId"]
                    ),
                    navigationPath: Self.string(
                        fields["navigationPath"]
                    )
                )
            )
            return .undefined

        case (
            "systemPermissions",
            "getNotificationPermissionStatus"
        ):
            let settings = await UNUserNotificationCenter.current()
                .notificationSettings()
            return .string(
                Self.notificationStatus(
                    settings.authorizationStatus
                )
            )

        case ("systemPermissions", "openAccessibilitySettings"):
            try await settingsOperation(.openAccessibilitySettings)
            return .undefined

        case ("systemPermissions", "openMicrophoneSettings"):
            try await settingsOperation(.openMicrophoneSettings)
            return .undefined

        case ("dictationAudio", "getBuiltInMicrophoneName"):
            #if os(iOS)
            let inputName = AVAudioSession.sharedInstance()
                .availableInputs?
                .first(where: { $0.portType == .builtInMic })?
                .portName
            return inputName.map(Value.string) ?? .null
            #else
            return .null
            #endif

        case ("systemFonts", "getFontFamilies"):
            return Self.systemFontFamilies()

        case ("systemPermissions", "openNotificationSettings"):
            try await settingsOperation(.openNotificationSettings)
            return .undefined

        case (
            "systemPermissions",
            "openScreenRecordingSettings"
        ):
            try await settingsOperation(.openScreenRecordingSettings)
            return .undefined

        case ("systemPermissions", "requestMicrophoneAccess"):
            try await settingsOperation(.requestMicrophoneAccess)
            return .undefined

        case (
            "systemPermissions",
            "showPermissionSettingsAppInFinder"
        ):
            try await settingsOperation(
                .showPermissionSettingsAppInFinder
            )
            return .undefined

        case ("openIn", "getTargets"):
            let target = Value.object([
                "id": .string("systemDefault"),
                "target": .string("systemDefault"),
                "label": .string("Open"),
                "icon": .null,
                "kind": .string("native"),
                "available": .bool(true),
                "default": .bool(
                    preferredOpenTarget == "systemDefault"
                ),
            ])
            return .object([
                "preferredTarget": preferredOpenTarget.map {
                    .string($0)
                } ?? .null,
                "availableTargets": .array([
                    .string("systemDefault")
                ]),
                "mode": .string("native"),
                "targets": .array([target]),
            ])

        case ("openIn", "detectTarget"):
            guard arguments?.count == 1 else {
                throw Error.invalidArguments
            }
            let fields = try argumentObject(arguments)
            guard case let .string(target)? = fields["target"],
                  !target.trimmingCharacters(in: .whitespacesAndNewlines)
                    .isEmpty
            else {
                throw Error.invalidArguments
            }
            let response = try await openInTargetAvailabilityProvider(target)
            guard case let .object(responseFields) = response,
                  case .bool? = responseFields["available"]
            else {
                throw Error.invalidArguments
            }
            return response

        case ("openIn", "loadTargetIcon"):
            guard arguments?.count == 1 else {
                throw Error.invalidArguments
            }
            let fields = try argumentObject(arguments)
            guard case let .string(target)? = fields["target"],
                  !target.trimmingCharacters(in: .whitespacesAndNewlines)
                    .isEmpty
            else {
                throw Error.invalidArguments
            }
            return try await openInTargetIconProvider(target)

        case ("openIn", "setGlobalPreferredTarget"):
            let fields = try argumentObject(arguments)
            guard case let .string(target)? = fields["target"] else {
                throw Error.invalidArguments
            }
            preferredOpenTarget = target
            return .object(["success": .bool(true)])

        case ("openIn", "open"):
            let fields = try argumentObject(arguments)
            guard case let .string(path)? = fields["path"] else {
                throw Error.invalidArguments
            }
            let url: URL
            if let parsed = URL(string: path),
               parsed.scheme != nil
            {
                url = parsed
            } else {
                url = URL(fileURLWithPath: path)
            }
            return .object([
                "success": .bool(await openURL(url))
            ])

        default:
            throw Error.unsupportedMethod(
                service: service,
                method: method
            )
        }
    }

    private func argumentObject(
        _ arguments: [Value]?
    ) throws -> [String: Value] {
        guard case let .object(fields)? = arguments?.first else {
            throw Error.invalidArguments
        }
        return fields
    }

    private static func string(_ value: Value?) -> String? {
        guard case let .string(string)? = value else {
            return nil
        }
        return string
    }

    private static func systemFontFamilies() -> Value {
        let postscriptNames =
            CTFontManagerCopyAvailablePostScriptNames() as? [String] ?? []
        var facesByFamily: [String: [Value]] = [:]

        for postscriptName in postscriptNames {
            let font = CTFontCreateWithName(
                postscriptName as CFString,
                14,
                nil
            )
            let family = CTFontCopyFamilyName(font) as String
            guard !family.isEmpty else {
                continue
            }
            let fullName = CTFontCopyFullName(font) as String
            let styleName =
                CTFontCopyName(font, kCTFontStyleNameKey) as String?
                ?? "Regular"
            let isMonospaced = CTFontGetSymbolicTraits(font)
                .contains(.traitMonoSpace)

            facesByFamily[family, default: []].append(
                .object([
                    "fullName": .string(
                        fullName.isEmpty ? postscriptName : fullName
                    ),
                    "postscriptName": .string(postscriptName),
                    "styleName": .string(styleName),
                    "isMonospaced": .bool(isMonospaced),
                ])
            )
        }

        let families = facesByFamily.keys.sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }.map { family in
            let faces = facesByFamily[family, default: []].sorted {
                Self.fontFaceSortKey($0) < Self.fontFaceSortKey($1)
            }
            return Value.object([
                "family": .string(family),
                "faces": .array(faces),
            ])
        }
        return .array(families)
    }

    private static func fontFaceSortKey(_ value: Value) -> String {
        guard case let .object(fields) = value,
              case let .string(styleName)? = fields["styleName"],
              case let .string(postscriptName)? = fields["postscriptName"]
        else {
            return ""
        }
        return "\(styleName.lowercased())\u{0}\(postscriptName.lowercased())"
    }

    private static func performNotificationOperation(
        _ operation: NotificationOperation
    ) async throws {
        let center = UNUserNotificationCenter.current()
        switch operation {
        case let .show(id, title, body):
            let settings = await center.notificationSettings()
            if settings.authorizationStatus == .notDetermined {
                _ = try await center.requestAuthorization(
                    options: [.alert, .badge, .sound]
                )
            }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            try await center.add(
                UNNotificationRequest(
                    identifier: id,
                    content: content,
                    trigger: nil
                )
            )

        case let .hide(notificationID, _, _):
            guard let notificationID else {
                return
            }
            center.removePendingNotificationRequests(
                withIdentifiers: [notificationID]
            )
            center.removeDeliveredNotifications(
                withIdentifiers: [notificationID]
            )
        }
    }

    private static func performSettingsOperation(
        _ operation: SettingsOperation
    ) async throws {
        #if canImport(UIKit)
        if operation == .requestMicrophoneAccess {
            if #available(iOS 17.0, *) {
                _ = await AVAudioApplication.requestRecordPermission()
            }
            return
        }
        guard let url = URL(
            string: UIApplication.openSettingsURLString
        ) else {
            return
        }
        await MainActor.run {
            UIApplication.shared.open(url)
        }
        #else
        _ = operation
        #endif
    }

    private static func notificationStatus(
        _ status: UNAuthorizationStatus
    ) -> String {
        switch status {
        case .notDetermined:
            return "not-determined"
        case .denied:
            return "denied"
        case .authorized:
            return "authorized"
        case .provisional:
            return "provisional"
        case .ephemeral:
            return "ephemeral"
        @unknown default:
            return "unknown"
        }
    }

    private static func performOpenURL(_ url: URL) async -> Bool {
        #if canImport(UIKit)
        return await withCheckedContinuation { continuation in
            Task { @MainActor in
                UIApplication.shared.open(
                    url,
                    options: [:]
                ) { success in
                    continuation.resume(returning: success)
                }
            }
        }
        #else
        _ = url
        return false
        #endif
    }
}
