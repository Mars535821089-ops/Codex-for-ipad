import unittest
from pathlib import Path


class DeviceInstallContractTests(unittest.TestCase):
    @property
    def script(self) -> str:
        return (
            Path(__file__).parents[1] / "scripts/install_to_ipad.sh"
        ).read_text(encoding="utf-8")

    def test_launch_verification_searches_the_process_executable_name(
        self,
    ) -> None:
        script = self.script

        self.assertIn('--search "Codex for ipad"', script)
        self.assertIn(
            'grep -E "$BUNDLE_ID|Codex for ipad" <<<"$PROCESS_INFO"',
            script,
        )

    def test_successful_launch_captures_and_validates_visible_device_ui(
        self,
    ) -> None:
        script = self.script

        self.assertIn("devicectl device capture screenshot", script)
        self.assertIn("verify_device_screenshot.swift", script)
        self.assertIn('xcrun swift "$SCREENSHOT_VALIDATOR" "$SCREENSHOT"', script)
        self.assertIn("SCREENSHOT_DEADLINE=$((SECONDS + 60))", script)
        self.assertIn(
            "did not finish mounting the latest desktop surface within 60 seconds",
            script,
        )
        self.assertIn('ipad-device-validation-$VERSION.json', script)
        self.assertIn('"realInteraction": "pending-task-workflow-validation"', script)

    def test_visible_ui_markers_track_the_latest_desktop_surface(
        self,
    ) -> None:
        script = self.script

        for marker in (
            '"New Chat / 新对话"',
            '"Projects / 项目"',
            '"Recents / 最近"',
        ):
            self.assertIn(marker, script)

        self.assertNotIn(
            '"Ready when you are. / 我们该构建什么？"',
            script,
        )

    def test_persisted_evidence_contains_no_device_or_signing_identifier(
        self,
    ) -> None:
        script = self.script

        self.assertNotIn("device='$DEVICE_NAME'", script)
        self.assertNotIn('"deviceName":', script)
        self.assertNotIn('"teamID":', script)
        self.assertNotIn('"signingIdentity":', script)

    def test_install_uses_the_prebuilt_canonical_release_without_xcodebuild(self) -> None:
        script = self.script

        self.assertNotIn("xcodebuild", script)
        self.assertIn(
            'LATEST_PROBE="$PROJECT_ROOT/.planning/codex-ipad-release/latest-official-probe-20260819.json"',
            script,
        )
        self.assertIn('RELEASE_RESOLVER="$PROJECT_ROOT/scripts/resolve_ipad_release.py"', script)
        self.assertIn('python3 "$RELEASE_RESOLVER"', script)
        self.assertIn('--probe "$LATEST_PROBE"', script)

    def test_offline_device_is_rejected_before_build_or_install(self) -> None:
        script = self.script

        preflight = 'DEVICE_LIST="$(xcrun devicectl list devices'
        self.assertIn(preflight, script)
        self.assertIn(
            "Target iPad is not available; refusing install/launch and leaving device untouched",
            script,
        )
        self.assertLess(script.index(preflight), script.index("device install app"))

    def test_running_app_blocks_replacement_without_explicit_opt_in(self) -> None:
        script = self.script

        self.assertIn(
            'ALLOW_RUNNING_APP_REPLACEMENT="${CODEXPAD_ALLOW_RUNNING_APP_REPLACEMENT:-false}"',
            script,
        )
        self.assertIn(
            'Target Codex for ipad is already running; refusing install/launch',
            script,
        )
        self.assertIn(
            'CODEXPAD_ALLOW_RUNNING_APP_REPLACEMENT=true',
            script,
        )
        self.assertLess(
            script.index("device info processes"),
            script.index("device install app"),
        )

    def test_install_never_terminates_an_existing_ipad_app_process(self) -> None:
        script = self.script

        self.assertIn(
            'LAUNCH_AFTER_INSTALL="${CODEXPAD_LAUNCH_AFTER_INSTALL:-false}"',
            script,
        )
        self.assertIn('if [[ "$LAUNCH_AFTER_INSTALL" == "true" ]]; then', script)
        self.assertIn(
            'CODEXPAD_LAUNCH_AFTER_INSTALL=true',
            script,
        )
        self.assertIn(
            "Skipping app launch; existing iPad app process was left untouched",
            script,
        )

        self.assertNotIn("--terminate-existing", script)
        self.assertIn(
            'if grep -Eq "$BUNDLE_ID|Codex for ipad" <<<"$PROCESS_INFO"; then',
            script,
        )
        self.assertIn(
            "Codex for ipad is already running; skipping launch and leaving its process untouched",
            script,
        )
        self.assertIn("xcrun devicectl device process launch", script)
        self.assertIn('--device "$DEVICE_NAME"', script)

    def test_device_install_script_contains_no_device_power_operation(self) -> None:
        script = self.script.lower()

        self.assertNotIn(" reboot", script)
        self.assertNotIn(" shutdown", script)
        self.assertNotIn(" poweroff", script)

    def test_install_verifies_device_bundle_before_optional_launch(self) -> None:
        script = self.script

        installed_apps_query = "xcrun devicectl device info apps"
        optional_launch_branch = 'if [[ "$LAUNCH_AFTER_INSTALL" == "true" ]]; then'
        self.assertIn(installed_apps_query, script)
        self.assertLess(
            script.index(installed_apps_query),
            script.index(optional_launch_branch),
        )
        self.assertIn(
            '"$APPS_FILE" "$BUNDLE_ID" "$VERSION" "$BUILD"',
            script,
        )

    def test_install_reads_version_and_build_from_the_verified_release(self) -> None:
        script = self.script

        self.assertIn(
            'VERSION="$(plutil -extract version raw -o - "$RELEASE_RESOLUTION_FILE")"',
            script,
        )
        self.assertIn(
            'BUILD="$(plutil -extract build raw -o - "$RELEASE_RESOLUTION_FILE")"',
            script,
        )
        self.assertIn(
            'APP="$(plutil -extract appPath raw -o - "$RELEASE_RESOLUTION_FILE")"',
            script,
        )


if __name__ == "__main__":
    unittest.main()
