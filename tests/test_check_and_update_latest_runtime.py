from __future__ import annotations

import os
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).parents[1]


class CheckAndUpdateLatestRuntimeTests(unittest.TestCase):
    def test_automatic_checker_fails_closed_without_network_or_side_effects(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            state = Path(temporary) / ".update-state"
            state.mkdir()
            sentinel = state / "sentinel"
            sentinel.write_text("keep", encoding="utf-8")
            env = os.environ.copy()
            env["HOME"] = temporary
            result = subprocess.run(
                [str(ROOT / "scripts/check_and_update_latest.sh")],
                cwd=ROOT,
                env=env,
                text=True,
                capture_output=True,
                timeout=15,
            )
            self.assertEqual(result.returncode, 78)
            self.assertIn("AUTOMATIC_UPDATE_DISABLED", result.stderr)
            self.assertEqual(sentinel.read_text(encoding="utf-8"), "keep")

    def test_legacy_force_install_flag_cannot_reenable_automatic_updates(self) -> None:
        env = os.environ.copy()
        env["CODEX_IPAD_FORCE_INSTALL"] = "true"
        result = subprocess.run(
            [str(ROOT / "scripts/check_and_update_latest.sh")],
            cwd=ROOT,
            env=env,
            text=True,
            capture_output=True,
            timeout=15,
        )
        self.assertEqual(result.returncode, 78)
        self.assertIn("AUTOMATIC_UPDATE_DISABLED", result.stderr)


if __name__ == "__main__":
    unittest.main()
