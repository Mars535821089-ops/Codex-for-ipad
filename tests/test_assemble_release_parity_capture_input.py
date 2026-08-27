from __future__ import annotations

import hashlib
import json
from pathlib import Path
import tempfile
import unittest

from PIL import Image

from scripts.assemble_release_parity_capture_input import assemble_capture_input
from scripts.build_desktop_ui_parity import SURFACE_DEFINITIONS
from scripts.parity_capture_plan import capture_specs_by_surface


class AssembleReleaseParityCaptureInputTests(unittest.TestCase):
    version = "26.810.41047"
    build = "6570"

    @staticmethod
    def _sha256(path: Path) -> str:
        return hashlib.sha256(path.read_bytes()).hexdigest()

    def _fixture(self, root: Path) -> tuple[Path, Path, Path]:
        runtime = root / f"artifacts/parity-runtime/{self.version}/{self.build}"
        official_root = runtime / "official"
        ipad_root = runtime / "ipad"
        official_root.mkdir(parents=True)
        ipad_root.mkdir(parents=True)
        official_surfaces = {}
        ipad_surfaces = {}
        capture_count = 0
        specs_by_surface = capture_specs_by_surface()
        for index, definition in enumerate(SURFACE_DEFINITIONS, start=1):
            surface_id = definition["id"]
            official_captures = []
            ipad_captures = []
            for capture_index, spec in enumerate(specs_by_surface[surface_id]):
                route = spec["route"]
                state_key = spec["state"]
                capture_key = spec["captureKey"]
                label_fingerprint = hashlib.sha256(
                    f"{surface_id}-{route}-{state_key}-control".encode("utf-8")
                ).hexdigest()
                interaction_inventory = {
                    "controlCount": index + 2,
                    "keyboardAccessibleCount": index + 1,
                    "byTag": {"BUTTON": index + 1, "INPUT": 1},
                    "labelFingerprints": [label_fingerprint],
                }
                basename = f"{surface_id}-{capture_index:02d}-{state_key}"
                official = official_root / f"{basename}-desktop.png"
                ipad = ipad_root / f"{basename}-ipad.png"
                Image.new(
                    "RGB",
                    (640 + capture_index, 480 + index),
                    (index, capture_index, 30),
                ).save(official)
                Image.new(
                    "RGB",
                    (800 + capture_index, 600 + index),
                    (40, index, capture_index),
                ).save(ipad)
                official_captures.append({
                    "path": official.name,
                    "sha256": self._sha256(official),
                    "route": route,
                    "stateKey": state_key,
                    "captureKey": capture_key,
                    "interactionInventory": interaction_inventory,
                })
                ipad_captures.append({
                    "path": ipad.name,
                    "sha256": self._sha256(ipad),
                    "route": route,
                    "stateKey": state_key,
                    "captureKey": capture_key,
                    "attachmentName": (
                        f"CODEXPAD_PARITY_{surface_id}__{capture_key}"
                    ),
                    "interactionInventory": interaction_inventory,
                })
                capture_count += 1
            official_surfaces[surface_id] = {"captures": official_captures}
            ipad_surfaces[surface_id] = {"captures": ipad_captures}
        official_manifest = official_root / "manifest.json"
        official_manifest.write_text(json.dumps({
            "schemaVersion": 2,
            "desktopVersion": self.version,
            "desktopBuild": self.build,
            "surfaces": official_surfaces,
        }) + "\n", encoding="utf-8")
        ipad_manifest = ipad_root / "manifest.json"
        ipad_manifest.write_text(json.dumps({
            "schemaVersion": 4,
            "desktopVersion": self.version,
            "desktopBuild": self.build,
            "interactionAcceptance": {
                "actionCount": capture_count,
                "surfaceIds": list(ipad_surfaces),
            },
            "surfaces": ipad_surfaces,
        }) + "\n", encoding="utf-8")
        return official_manifest, ipad_manifest, runtime / "capture-input.json"

    def test_assembles_exact_hashed_s01_s10_input_atomically(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            official, ipad, output = self._fixture(root)

            result = assemble_capture_input(
                root,
                official_manifest_path=official,
                ipad_manifest_path=ipad,
                output_path=output,
                desktop_version=self.version,
                desktop_build=self.build,
            )

            self.assertEqual(result, output.resolve())
            value = json.loads(output.read_text(encoding="utf-8"))
            self.assertEqual(value["schemaVersion"], 3)
            self.assertEqual(value["desktopVersion"], self.version)
            self.assertEqual(value["desktopBuild"], self.build)
            self.assertEqual(list(value["surfaces"]), [
                f"S{index:02d}" for index in range(1, 11)
            ])
            definitions = {row["id"]: row for row in SURFACE_DEFINITIONS}
            for surface_id, row in value["surfaces"].items():
                captures = row["captures"]
                definition = definitions[surface_id]
                self.assertEqual(
                    {capture["route"] for capture in captures},
                    set(definition["routes"]),
                )
                self.assertEqual(
                    {capture["state"] for capture in captures},
                    set(definition["requiredStates"]),
                )
                for capture in captures:
                    comparison = capture["interactionComparison"]
                    self.assertEqual(comparison["status"], "matched")
                    self.assertEqual(comparison["controlCountDelta"], 0)
                    self.assertEqual(
                        comparison["keyboardAccessibleCountDelta"],
                        0,
                    )
                    self.assertEqual(comparison["byTagDelta"], {})
                    self.assertEqual(
                        comparison["missingOfficialLabelFingerprints"],
                        [],
                    )
                    self.assertEqual(
                        comparison["unexpectedIPadLabelFingerprints"],
                        [],
                    )
                    for key in ("officialDesktop", "ipad"):
                        self.assertFalse(Path(capture[key]).is_absolute())
                        self.assertTrue((root / capture[key]).is_file())

    def test_rejects_stale_or_unaccepted_inputs_without_replacing_output(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            official, ipad, output = self._fixture(root)
            output.write_text("previous-complete\n", encoding="utf-8")

            cases = []
            official_value = json.loads(official.read_text(encoding="utf-8"))
            official_value["desktopBuild"] = "6569"
            stale = official.with_name("stale.json")
            stale.write_text(json.dumps(official_value), encoding="utf-8")
            cases.append((stale, ipad, "official desktop build does not match"))

            ipad_value = json.loads(ipad.read_text(encoding="utf-8"))
            ipad_value.pop("interactionAcceptance")
            unaccepted = ipad.with_name("unaccepted.json")
            unaccepted.write_text(json.dumps(ipad_value), encoding="utf-8")
            cases.append((official, unaccepted, "iPad interaction acceptance is missing"))

            for official_case, ipad_case, message in cases:
                with self.subTest(message=message):
                    with self.assertRaisesRegex(ValueError, message):
                        assemble_capture_input(
                            root,
                            official_manifest_path=official_case,
                            ipad_manifest_path=ipad_case,
                            output_path=output,
                            desktop_version=self.version,
                            desktop_build=self.build,
                        )
                    self.assertEqual(
                        output.read_text(encoding="utf-8"),
                        "previous-complete\n",
                    )

    def test_rejects_state_or_hash_mismatch(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            official, ipad, output = self._fixture(root)
            ipad_value = json.loads(ipad.read_text(encoding="utf-8"))
            ipad_value["surfaces"]["S06"]["captures"][0]["attachmentName"] = (
                "CODEXPAD_PARITY_S06__wrong__state"
            )
            ipad.write_text(json.dumps(ipad_value), encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "S06 capture state does not match"):
                assemble_capture_input(
                    root,
                    official_manifest_path=official,
                    ipad_manifest_path=ipad,
                    output_path=output,
                    desktop_version=self.version,
                    desktop_build=self.build,
                )

            official, ipad, output = self._fixture(root / "hash")
            official_value = json.loads(official.read_text(encoding="utf-8"))
            official_value["surfaces"]["S03"]["captures"][0]["sha256"] = "0" * 64
            official.write_text(json.dumps(official_value), encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "S03 official desktop hash does not match"):
                assemble_capture_input(
                    root / "hash",
                    official_manifest_path=official,
                    ipad_manifest_path=ipad,
                    output_path=output,
                    desktop_version=self.version,
                    desktop_build=self.build,
                )

    def test_rejects_missing_or_malformed_interaction_inventory(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            official, ipad, output = self._fixture(root)
            official_value = json.loads(official.read_text(encoding="utf-8"))
            official_value["surfaces"]["S04"]["captures"][0].pop(
                "interactionInventory"
            )
            official.write_text(json.dumps(official_value), encoding="utf-8")
            with self.assertRaisesRegex(
                ValueError,
                "S04 official desktop interaction inventory is malformed",
            ):
                assemble_capture_input(
                    root,
                    official_manifest_path=official,
                    ipad_manifest_path=ipad,
                    output_path=output,
                    desktop_version=self.version,
                    desktop_build=self.build,
                )

            official, ipad, output = self._fixture(root / "malformed")
            ipad_value = json.loads(ipad.read_text(encoding="utf-8"))
            ipad_value["surfaces"]["S08"]["captures"][0]["interactionInventory"][
                "labelFingerprints"
            ] = ["not-a-sha256"]
            ipad.write_text(json.dumps(ipad_value), encoding="utf-8")
            with self.assertRaisesRegex(
                ValueError,
                "S08 iPad interaction inventory is malformed",
            ):
                assemble_capture_input(
                    root / "malformed",
                    official_manifest_path=official,
                    ipad_manifest_path=ipad,
                    output_path=output,
                    desktop_version=self.version,
                    desktop_build=self.build,
                )

    def test_rejects_incomplete_required_states_or_routes(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            official, ipad, output = self._fixture(root)
            official_value = json.loads(official.read_text(encoding="utf-8"))
            official_value["surfaces"]["S01"]["captures"] = [
                row
                for row in official_value["surfaces"]["S01"]["captures"]
                if row["stateKey"] != "error"
            ]
            official.write_text(json.dumps(official_value), encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "S01 required states are incomplete"):
                assemble_capture_input(
                    root,
                    official_manifest_path=official,
                    ipad_manifest_path=ipad,
                    output_path=output,
                    desktop_version=self.version,
                    desktop_build=self.build,
                )

            official, ipad, output = self._fixture(root / "routes")
            official_value = json.loads(official.read_text(encoding="utf-8"))
            first = next(
                row
                for row in official_value["surfaces"]["S08"]["captures"]
                if row["route"] == "/settings/data-controls"
            )
            first["route"] = "/settings"
            official.write_text(json.dumps(official_value), encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "S08 required routes are incomplete"):
                assemble_capture_input(
                    root / "routes",
                    official_manifest_path=official,
                    ipad_manifest_path=ipad,
                    output_path=output,
                    desktop_version=self.version,
                    desktop_build=self.build,
                )

if __name__ == "__main__":
    unittest.main()
