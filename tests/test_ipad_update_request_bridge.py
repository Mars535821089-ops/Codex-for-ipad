from __future__ import annotations

import json
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).parents[1]


class IpadUpdateRequestBridgeTests(unittest.TestCase):
    def run_helper(self, *arguments: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [
                "python3",
                str(ROOT / "scripts" / "ipad_update_request.py"),
                *arguments,
            ],
            cwd=ROOT,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )

    def test_validate_rejects_wrong_schema_and_unknown_operation(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            request = Path(temporary) / "request.json"
            request.write_text(
                json.dumps(
                    {
                        "schemaVersion": 2,
                        "requestID": "request-1",
                        "operation": "deleteEverything",
                        "requestedAt": "2026-08-15T00:00:00Z",
                        "beta": True,
                        "planType": "plus",
                    }
                ),
                encoding="utf-8",
            )

            result = self.run_helper("validate", "--request", str(request))

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("schemaVersion", result.stderr)

    def test_validate_accepts_released_request_and_normalizes_output(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            request = Path(temporary) / "request.json"
            output = Path(temporary) / "normalized.json"
            request.write_text(
                json.dumps(
                    {
                        "schemaVersion": 1,
                        "requestID": "request-1",
                        "operation": "installUpdate",
                        "requestedAt": "2026-08-15T00:00:00Z",
                        "beta": True,
                        "planType": "plus",
                    }
                ),
                encoding="utf-8",
            )

            result = self.run_helper(
                "validate",
                "--request",
                str(request),
                "--output",
                str(output),
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(json.loads(output.read_text()), json.loads(request.read_text()))

    def test_mark_consumed_deduplicates_request_id(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            request = Path(temporary) / "request.json"
            state = Path(temporary) / "consumed.json"
            request.write_text(
                json.dumps(
                    {
                        "schemaVersion": 1,
                        "requestID": "request-1",
                        "operation": "checkForUpdates",
                        "requestedAt": "2026-08-15T00:00:00Z",
                        "beta": True,
                        "planType": "plus",
                    }
                ),
                encoding="utf-8",
            )

            first = self.run_helper(
                "mark-consumed", "--request", str(request), "--state", str(state)
            )
            second = self.run_helper(
                "mark-consumed", "--request", str(request), "--state", str(state)
            )

            self.assertEqual(first.returncode, 0, first.stderr)
            self.assertNotEqual(second.returncode, 0)
            self.assertEqual(json.loads(state.read_text())["requestIDs"], ["request-1"])

    def test_poller_is_disabled_after_automatic_updates_are_removed(self) -> None:
        result = subprocess.run(
            [str(ROOT / "scripts/poll_ipad_update_requests.sh")],
            cwd=ROOT,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=15,
        )
        self.assertEqual(result.returncode, 78)
        self.assertIn("AUTOMATIC_UPDATE_DISABLED", result.stderr)


if __name__ == "__main__":
    unittest.main()
