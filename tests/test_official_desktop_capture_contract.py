import os
import subprocess
import unittest
from pathlib import Path


ROOT = Path(__file__).parents[1]


class OfficialDesktopCaptureContractTests(unittest.TestCase):
    def test_capture_wrapper_is_permanently_disabled(self) -> None:
        script = (
            ROOT / "scripts/capture_official_desktop_parity.sh"
        ).read_text(encoding="utf-8")

        self.assertIn("permanently disabled", script)
        self.assertIn("physical iPad only", script)
        self.assertIn("exit 78", script)

    def test_capture_wrapper_cannot_be_reenabled_by_environment(self) -> None:
        environment = os.environ.copy()
        environment["CODEX_ALLOW_DESKTOP_PARITY_CAPTURE"] = "true"

        result = subprocess.run(
            [str(ROOT / "scripts/capture_official_desktop_parity.sh")],
            cwd=ROOT,
            env=environment,
            text=True,
            capture_output=True,
            timeout=5,
            check=False,
        )

        self.assertEqual(result.returncode, 78)
        self.assertIn("permanently disabled", result.stderr)
        self.assertIn("physical iPad only", result.stderr)

    def test_capture_wrapper_contains_no_desktop_copy_sign_or_launch_path(self) -> None:
        script = (
            ROOT / "scripts/capture_official_desktop_parity.sh"
        ).read_text(encoding="utf-8")

        for forbidden in (
            "hdiutil attach",
            "mktemp",
            "ditto",
            "codesign",
            "open -n",
            "CAPTURE_BUNDLE_ID",
            "CODEX_ALLOW_DESKTOP_PARITY_CAPTURE",
            "capture_official_desktop_parity_cdp.mjs",
        ):
            self.assertNotIn(forbidden, script)

    def test_cdp_driver_is_also_permanently_disabled_when_invoked_directly(self) -> None:
        driver = ROOT / "scripts/capture_official_desktop_parity_cdp.mjs"

        result = subprocess.run(
            ["node", str(driver)],
            cwd=ROOT,
            text=True,
            capture_output=True,
            timeout=5,
            check=False,
        )

        self.assertEqual(result.returncode, 78)
        self.assertIn("permanently disabled", result.stderr)
        self.assertIn("physical iPad only", result.stderr)

    def test_cdp_driver_contains_no_dormant_desktop_capture_implementation(self) -> None:
        driver = (
            ROOT / "scripts/capture_official_desktop_parity_cdp.mjs"
        ).read_text(encoding="utf-8")

        self.assertLessEqual(len(driver.splitlines()), 12)
        for forbidden in (
            "WebSocket",
            "Page.captureScreenshot",
            "Runtime.evaluate",
            "electronBridge",
            "--remote-debugging-port",
            "--user-data-dir",
            "ChatGPT.app",
            "Codex.app",
            "open -n",
            "hdiutil",
            "codesign",
        ):
            self.assertNotIn(forbidden, driver)


if __name__ == "__main__":
    unittest.main()
