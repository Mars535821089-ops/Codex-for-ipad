from __future__ import annotations

import os
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).parents[1]


class ConfigureAutoUpdateRuntimeTests(unittest.TestCase):
    def test_configuration_is_explicitly_disabled_and_removes_agents(self) -> None:
        source = (ROOT / "scripts/configure_auto_update.sh").read_text(
            encoding="utf-8"
        )
        self.assertIn("AUTOMATIC_UPDATE_DISABLED", source)
        self.assertNotIn("StartInterval", source)
        self.assertNotIn("bootstrap", source)
        self.assertNotIn("kickstart", source)

    def test_configuration_removes_legacy_agents_without_xcode_or_network(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary) / "home"
            agents = home / "Library" / "LaunchAgents"
            agents.mkdir(parents=True)
            old = [
                agents / "dev.codexforipad.autoupdate.plist",
                agents / "dev.codexforipad.ipad-request-poller.plist",
            ]
            for path in old:
                path.write_text("legacy", encoding="utf-8")
            env = os.environ.copy()
            env["HOME"] = str(home)
            env["PATH"] = "/usr/bin:/bin"
            result = subprocess.run(
                [str(ROOT / "scripts/configure_auto_update.sh")],
                cwd=ROOT,
                env=env,
                text=True,
                capture_output=True,
                timeout=15,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("AUTOMATIC_UPDATE_DISABLED", result.stdout)
            self.assertTrue(all(not path.exists() for path in old))

    def test_compatibility_entrypoints_fail_closed(self) -> None:
        for script in (
            "scripts/check_and_update_latest.sh",
            "scripts/poll_ipad_update_requests.sh",
        ):
            result = subprocess.run(
                [str(ROOT / script)],
                cwd=ROOT,
                text=True,
                capture_output=True,
                timeout=15,
            )
            self.assertEqual(result.returncode, 78)
            self.assertIn("AUTOMATIC_UPDATE_DISABLED", result.stderr)


if __name__ == "__main__":
    unittest.main()
