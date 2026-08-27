#if SWIFT_PACKAGE
    import CodexPadDomain
#endif
import Foundation

public enum CodexDesktopSettingAccess:
    Equatable,
    Sendable
{
    case writable
    case readOnly
}

public struct CodexDesktopReleasedSetting:
    Equatable,
    Sendable
{
    public let key: String
    public let defaultValue: CodexJSONValue?
    public let isHidden: Bool
    public let access: CodexDesktopSettingAccess

    public init(
        key: String,
        defaultValue: CodexJSONValue?,
        isHidden: Bool = false,
        access: CodexDesktopSettingAccess = .writable
    ) {
        self.key = key
        self.defaultValue = defaultValue
        self.isHidden = isHidden
        self.access = access
    }
}

public enum CodexDesktopReleasedSettings {
    public static let all: [CodexDesktopReleasedSetting] = [
        setting("ambient-suggestions-enabled", .bool(true)),
        setting("appearanceTheme", .string("system")),
        setting("appearanceLightChromeTheme", nil),
        setting("appearanceDarkChromeTheme", nil),
        setting("appearanceLightCodeThemeId", .string("codex")),
        setting("appearanceDarkCodeThemeId", .string("codex")),
        setting("appearanceDiffMarkerStyle", .string("color")),
        setting("sansFontSize", .integer(14)),
        setting("codeFontSize", .integer(12)),
        setting("useFontSmoothing", .bool(true)),
        setting("usePointerCursors", .bool(false)),
        setting("dock-icon-preference", .string("app-default")),
        setting("reduced-motion-preference", .string("system")),
        setting("appshotDestination", .string("automatic")),
        setting("appshotSoundEnabled", .bool(true)),
        setting(
            "browser-annotation-screenshots-mode",
            .string("always")
        ),
        setting(
            "browser-download-directory",
            .null,
            isHidden: true
        ),
        setting(
            "browser-download-prompt-enabled",
            .bool(false),
            isHidden: true
        ),
        setting(
            "codex-micro-agent-source",
            .string("recent"),
            isHidden: true
        ),
        setting(
            "codex-micro-layout",
            codexMicroLayout,
            isHidden: true
        ),
        setting(
            "codex-micro-lighting-brightness",
            .integer(100),
            isHidden: true
        ),
        setting(
            "codex-micro-lighting-auto-off",
            .string("3-minutes"),
            isHidden: true
        ),
        setting(
            "computerUseAlwaysHidePictureInPicture",
            .bool(false),
            isHidden: true
        ),
        setting("mac-menu-bar-enabled", .bool(true)),
        setting("open-in-target-preferences", .object([:])),
        setting(
            "open-link-in-target-preference",
            .string("in-app-browser")
        ),
        setting(
            "open-local-url-in-target-preference",
            .string("in-app-browser")
        ),
        setting("custom_file_handlers", .object([:])),
        setting("dictationDictionary", .array([])),
        setting(
            "microphoneInputDeviceId",
            .null,
            isHidden: true
        ),
        setting("followUpQueueMode", .string("steer")),
        setting("composerEnterBehavior", .string("enter")),
        setting("show-context-window-usage", .bool(false)),
        setting("reviewDelivery", .string("inline")),
        setting("localeOverride", .null),
        setting("preventSleepWhileRunning", .bool(false)),
        setting(
            "keepRemoteControlAwakeWhilePluggedIn",
            .bool(false)
        ),
        setting("integratedTerminalShell", nil),
        setting("defaultTerminalLocation", .string("bottom")),
        setting(
            "runCodexInWindowsSubsystemForLinux",
            .bool(false),
            isHidden: true
        ),
        setting(
            "hotkey-window-projectless-default-enabled",
            .bool(false)
        ),
        setting("git-branch-prefix", .string("codex/")),
        setting("git-always-force-push", .bool(false)),
        setting("git-create-pull-request-as-draft", .bool(true)),
        setting("git-pull-request-merge-method", .string("merge")),
        setting("git-review-mode", .string("full")),
        setting("git-show-sidebar-pr-icons", nil),
        setting("git-worktree-root", .string("")),
        setting(
            "git-commit-instructions",
            .string(""),
            access: .readOnly
        ),
        setting(
            "git-pr-instructions",
            .string(""),
            access: .readOnly
        ),
        setting(
            "enabled-reasoning-efforts",
            .array([
                .string("low"),
                .string("medium"),
                .string("high"),
                .string("xhigh"),
                .string("ultra"),
            ]),
            isHidden: true
        ),
        setting(
            "show-ultra-in-model-picker-slider",
            .bool(false),
            isHidden: true
        ),
        setting("notifications-turn-mode", .string("unfocused")),
        setting("notifications-permissions-enabled", .bool(true)),
        setting("notifications-questions-enabled", .bool(true)),
        setting("default-service-tier", .null),
        setting("selected-avatar-id", .null),
        setting("avatar-overlay-mascot-width-px", .integer(112)),
        setting(
            "realtimeVoiceScreenContextEnabled",
            .bool(true),
            isHidden: true
        ),
        setting(
            "conversationDetailMode",
            .string("STEPS_COMMANDS")
        ),
        setting("worktree-auto-cleanup-enabled", .bool(true)),
        setting("worktree-keep-count", .integer(15)),
    ]

    public static let effectiveDefaults: [String: CodexJSONValue] =
        Dictionary(
            uniqueKeysWithValues: all.compactMap { setting in
                setting.defaultValue.map { (setting.key, $0) }
            }
        )

    /// Reconstructs the released desktop `get-settings` effective-value map.
    ///
    /// Defaults remain visible for settings the user has never changed, while
    /// every explicitly configured value (including forward-compatible keys
    /// introduced by a newer desktop bundle) wins at the top level.
    public static func effectiveValues(
        configured: [String: CodexJSONValue]
    ) -> [String: CodexJSONValue] {
        effectiveDefaults.merging(configured) { _, configuredValue in
            configuredValue
        }
    }

    public static let hiddenKeys: Set<String> = Set(
        all.lazy.filter(\.isHidden).map(\.key)
    )

    public static let readOnlyKeys: Set<String> = Set(
        all.lazy.filter { $0.access == .readOnly }.map(\.key)
    )

    private static func setting(
        _ key: String,
        _ defaultValue: CodexJSONValue?,
        isHidden: Bool = false,
        access: CodexDesktopSettingAccess = .writable
    ) -> CodexDesktopReleasedSetting {
        CodexDesktopReleasedSetting(
            key: key,
            defaultValue: defaultValue,
            isHidden: isHidden,
            access: access
        )
    }

    private static let codexMicroLayout: CodexJSONValue = .object([
        "version": .integer(1),
        "slots": .object([
            "ACT06": .object([
                "keycapId": .string("FAST")
            ]),
            "ACT07": .object([
                "keycapId": .string("APPR")
            ]),
            "ACT08": .object([
                "keycapId": .string("REJ")
            ]),
            "ACT09": .object([
                "keycapId": .string("SPLIT")
            ]),
            "ACT10_ACT11": .object([
                "keycapId": .string("MIC")
            ]),
            "ACT12": .object([
                "keycapId": .string("CODEX")
            ]),
        ]),
        "analogStick": .object([
            "up": .object([
                "type": .string("command"),
                "commandId": .string("composer.togglePlanMode"),
            ]),
            "right": .object([
                "type": .string("command"),
                "commandId": .string("navigateForward"),
            ]),
            "down": .object([
                "type": .string("command"),
                "commandId": .string("toggleSidebar"),
            ]),
            "left": .object([
                "type": .string("command"),
                "commandId": .string("navigateBack"),
            ]),
        ]),
        "encoderMode": .string("composer-navigation"),
        "voiceButtonMode": .string("push-to-talk"),
    ])
}
