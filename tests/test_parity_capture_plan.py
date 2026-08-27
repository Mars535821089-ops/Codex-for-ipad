from __future__ import annotations

import json
from pathlib import Path
import subprocess
import tempfile
import unittest

from scripts.build_desktop_ui_parity import SURFACE_DEFINITIONS
from scripts.parity_capture_plan import ACCEPTED_NON_CAPTURE_MARKERS, capture_specs


ROOT = Path(__file__).parents[1]


class ParityCapturePlanTests(unittest.TestCase):
    def test_plan_covers_every_route_and_state_with_unique_capture_keys(self) -> None:
        specs = capture_specs()
        for definition in SURFACE_DEFINITIONS:
            rows = [
                row for row in specs if row["surfaceId"] == definition["id"]
            ]
            self.assertEqual(
                {row["route"] for row in rows}, set(definition["routes"])
            )
            self.assertEqual(
                {row["state"] for row in rows},
                set(definition["requiredStates"]),
            )
            self.assertEqual(
                len({row["captureKey"] for row in rows}), len(rows)
            )
            self.assertEqual(
                len({(row["route"], row["state"]) for row in rows}),
                len(rows),
            )

    def test_cli_writes_atomic_schema_one_plan(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary) / "nested/capture-plan.json"
            result = subprocess.run(
                [
                    "python3",
                    str(ROOT / "scripts/parity_capture_plan.py"),
                    "--output",
                    str(output),
                ],
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            value = json.loads(output.read_text(encoding="utf-8"))
            self.assertEqual(value["schemaVersion"], 1)
            self.assertEqual(value["captures"], list(capture_specs()))
            self.assertEqual(
                value["acceptedNonCaptureMarkers"],
                list(ACCEPTED_NON_CAPTURE_MARKERS),
            )
            self.assertEqual(result.stdout.strip(), str(output.resolve()))


if __name__ == "__main__":
    unittest.main()
