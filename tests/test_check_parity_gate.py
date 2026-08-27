import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

from scripts.check_parity_gate import check_parity


class CheckParityGateTests(unittest.TestCase):
    def test_unknown_and_mismatch_are_blocking(self):
        inventory = {
            "features": [
                {"id": "thread.list", "status": "matched"},
                {"id": "tool.approval", "status": "unknown"},
                {"id": "workspace.git", "status": "mismatch"},
            ]
        }
        blockers = check_parity(inventory)
        self.assertEqual(
            [(item["id"], item["status"]) for item in blockers],
            [
                ("tool.approval", "unknown"),
                ("workspace.git", "mismatch"),
            ],
        )

    def test_cli_returns_two_for_a_blocker(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "inventory.json"
            path.write_text(
                json.dumps(
                    {"features": [{"id": "thread.list", "status": "unknown"}]}
                ),
                encoding="utf-8",
            )
            result = subprocess.run(
                [sys.executable, "scripts/check_parity_gate.py", str(path)],
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(result.returncode, 2)
            self.assertIn("thread.list", result.stdout)


if __name__ == "__main__":
    unittest.main()
