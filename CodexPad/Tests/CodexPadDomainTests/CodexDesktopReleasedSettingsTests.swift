import CodexPadDomain
import Foundation
import Testing

@testable import CodexPadApplication

@Test
func desktopReleasedSettingsPinEveryDefinitionInReleaseOrder() {
    let settings = CodexDesktopReleasedSettings.all

    #expect(settings.count == 62)
    #expect(Set(settings.map(\.key)).count == 62)
    #expect(settings.first?.key == "ambient-suggestions-enabled")
    #expect(settings.last?.key == "worktree-keep-count")
    #expect(CodexDesktopReleasedSettings.effectiveDefaults.count == 58)
    #expect(
        Set(settings.compactMap { setting in
            setting.defaultValue == nil ? setting.key : nil
        }) == [
            "appearanceLightChromeTheme",
            "appearanceDarkChromeTheme",
            "integratedTerminalShell",
            "git-show-sidebar-pr-icons",
        ]
    )
}

@Test
func desktopReleasedSettingsPreserveExactEffectiveValuesAndMetadata() {
    let values = CodexDesktopReleasedSettings.effectiveDefaults

    #expect(values["appearanceTheme"] == .string("system"))
    #expect(values["sansFontSize"] == .integer(14))
    #expect(values["codeFontSize"] == .integer(12))
    #expect(values["open-in-target-preferences"] == .object([:]))
    #expect(values["microphoneInputDeviceId"] == .null)
    #expect(
        values["enabled-reasoning-efforts"] == .array([
            .string("low"),
            .string("medium"),
            .string("high"),
            .string("xhigh"),
            .string("ultra"),
        ])
    )
    #expect(
        CodexDesktopReleasedSettings.hiddenKeys.contains(
            "codex-micro-layout"
        )
    )
    #expect(
        CodexDesktopReleasedSettings.readOnlyKeys == [
            "git-commit-instructions",
            "git-pr-instructions",
        ]
    )
}

@Test
func desktopReleasedSettingsPreserveTheHardwareLayoutDefault() {
    guard case let .object(layout)? =
        CodexDesktopReleasedSettings.effectiveDefaults[
            "codex-micro-layout"
        ],
        case let .object(slots)? = layout["slots"],
        case let .object(analogStick)? = layout["analogStick"]
    else {
        Issue.record("Released hardware layout is missing.")
        return
    }

    #expect(
        slots["ACT10_ACT11"] == .object([
            "keycapId": .string("MIC")
        ])
    )
    #expect(
        analogStick["up"] == .object([
            "type": .string("command"),
            "commandId": .string("composer.togglePlanMode"),
        ])
    )
    #expect(layout["encoderMode"] == .string("composer-navigation"))
    #expect(layout["voiceButtonMode"] == .string("push-to-talk"))
}

@Test
func desktopReleasedSettingsOverlayConfiguredValuesWithoutDroppingDefaults() {
    let effective = CodexDesktopReleasedSettings.effectiveValues(
        configured: [
            "appearanceTheme": .string("dark"),
            "integratedTerminalShell": .string("/bin/zsh"),
            "future-desktop-setting": .object([
                "enabled": .bool(true)
            ]),
        ]
    )

    #expect(effective["appearanceTheme"] == .string("dark"))
    #expect(effective["integratedTerminalShell"] == .string("/bin/zsh"))
    #expect(effective["sansFontSize"] == .integer(14))
    #expect(
        effective["future-desktop-setting"] == .object([
            "enabled": .bool(true)
        ])
    )
    #expect(
        effective.count
            == CodexDesktopReleasedSettings.effectiveDefaults.count + 2
    )
}
