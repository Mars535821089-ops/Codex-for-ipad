import hashlib
import json
import tempfile
import unittest
from pathlib import Path

from PIL import Image

from scripts.build_desktop_ui_parity import SURFACE_DEFINITIONS
from scripts.capture_official_desktop_parity import build_official_manifest
from scripts.parity_capture_plan import capture_specs_by_surface


class CaptureOfficialDesktopParityTests(unittest.TestCase):
    version = "26.810.41047"
    build = "6570"

    def _fixture(self, root: Path) -> tuple[Path, Path]:
        capture = root / "driver-output"
        capture.mkdir(parents=True)
        rows = []
        specs_by_surface = capture_specs_by_surface()
        for index, definition in enumerate(SURFACE_DEFINITIONS, start=1):
            surface = definition["id"]
            for capture_index, spec in enumerate(specs_by_surface[surface]):
                route = spec["route"]
                state = spec["state"]
                capture_key = spec["captureKey"]
                image = capture / f"{surface}-{capture_key}-official.png"
                Image.new(
                    "RGB",
                    (900 + capture_index, 700 + index),
                    ((index * 19 + capture_index) % 255, 30, 80),
                ).save(image)
                rows.append(
                    {
                        "id": surface,
                        "captureKey": capture_key,
                        "path": image.name,
                        "route": route,
                        "stateKey": state,
                        "interactionInventory": {
                            "controlCount": index + 2,
                            "keyboardAccessibleCount": index + 1,
                            "byTag": {"BUTTON": index + 1, "INPUT": 1},
                            "labelFingerprints": [
                                hashlib.sha256(
                                    f"{surface}-{route}-{state}-control".encode(
                                        "utf-8"
                                    )
                                ).hexdigest()
                            ],
                        },
                    }
                )
        result = capture / "driver-result.json"
        result.write_text(
            json.dumps(
                {
                    "schemaVersion": 2,
                    "bundleIdentifier": "com.openai.codex",
                    "desktopVersion": self.version,
                    "desktopBuild": self.build,
                    "profileMode": "isolated",
                    "surfaces": rows,
                }
            ),
            encoding="utf-8",
        )
        return capture, result

    def test_builds_hashed_atomic_manifest_for_exact_release(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            capture, result = self._fixture(root)
            output = root / "runtime/official"

            manifest_path = build_official_manifest(
                capture,
                driver_result_path=result,
                output_root=output,
                desktop_version=self.version,
                desktop_build=self.build,
            )

            manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
            self.assertEqual(manifest["schemaVersion"], 2)
            self.assertEqual(tuple(manifest["surfaces"]), tuple(
                f"S{index:02d}" for index in range(1, 11)
            ))
            self.assertEqual(manifest["profileMode"], "isolated")
            definitions = {row["id"]: row for row in SURFACE_DEFINITIONS}
            for surface, row in manifest["surfaces"].items():
                captures = row["captures"]
                self.assertEqual(
                    {capture["route"] for capture in captures},
                    set(definitions[surface]["routes"]),
                )
                self.assertEqual(
                    {capture["stateKey"] for capture in captures},
                    set(definitions[surface]["requiredStates"]),
                )
                for capture_row in captures:
                    image = output / capture_row["path"]
                    self.assertTrue(image.is_file())
                    self.assertEqual(
                        capture_row["sha256"],
                        hashlib.sha256(image.read_bytes()).hexdigest(),
                    )
                    self.assertEqual(
                        image.name,
                        f"{surface}-{capture_row['captureKey']}-official.png",
                    )
                    inventory = capture_row["interactionInventory"]
                    self.assertGreater(inventory["controlCount"], 0)
                    self.assertGreater(
                        inventory["keyboardAccessibleCount"], 0
                    )
                    self.assertTrue(inventory["labelFingerprints"])

    def test_rejects_missing_surface_without_replacing_previous_output(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            capture, result = self._fixture(root)
            value = json.loads(result.read_text(encoding="utf-8"))
            value["surfaces"] = [
                row for row in value["surfaces"] if row["id"] != "S10"
            ]
            result.write_text(json.dumps(value), encoding="utf-8")
            output = root / "runtime/official"
            output.mkdir(parents=True)
            sentinel = output / "manifest.json"
            sentinel.write_text("old\n", encoding="utf-8")

            with self.assertRaisesRegex(ValueError, "S01 through S10"):
                build_official_manifest(
                    capture,
                    driver_result_path=result,
                    output_root=output,
                    desktop_version=self.version,
                    desktop_build=self.build,
                )

            self.assertEqual(sentinel.read_text(encoding="utf-8"), "old\n")

    def test_rejects_missing_interaction_inventory(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            capture, result = self._fixture(root)
            value = json.loads(result.read_text(encoding="utf-8"))
            row = next(row for row in value["surfaces"] if row["id"] == "S05")
            row.pop("interactionInventory")
            result.write_text(json.dumps(value), encoding="utf-8")

            with self.assertRaisesRegex(
                ValueError, "S05 interaction inventory is missing"
            ):
                build_official_manifest(
                    capture,
                    driver_result_path=result,
                    output_root=root / "runtime/official",
                    desktop_version=self.version,
                    desktop_build=self.build,
                )

    def test_rejects_stale_identity_and_duplicate_image_bytes(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            capture, result = self._fixture(root)
            value = json.loads(result.read_text(encoding="utf-8"))
            value["desktopBuild"] = "stale"
            result.write_text(json.dumps(value), encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "build does not match"):
                build_official_manifest(
                    capture,
                    driver_result_path=result,
                    output_root=root / "stale",
                    desktop_version=self.version,
                    desktop_build=self.build,
                )

            capture, result = self._fixture(root / "duplicate")
            first, second = value = json.loads(
                result.read_text(encoding="utf-8")
            )["surfaces"][:2]
            (capture / second["path"]).write_bytes(
                (capture / first["path"]).read_bytes()
            )
            with self.assertRaisesRegex(ValueError, "reuses image bytes"):
                build_official_manifest(
                    capture,
                    driver_result_path=result,
                    output_root=root / "duplicate-output",
                    desktop_version=self.version,
                    desktop_build=self.build,
                )

    def test_rejects_incomplete_required_states_and_routes(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            capture, result = self._fixture(root)
            value = json.loads(result.read_text(encoding="utf-8"))
            value["surfaces"] = [
                row
                for row in value["surfaces"]
                if not (row["id"] == "S01" and row["stateKey"] == "error")
            ]
            result.write_text(json.dumps(value), encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "S01 required states are incomplete"):
                build_official_manifest(
                    capture,
                    driver_result_path=result,
                    output_root=root / "missing-state",
                    desktop_version=self.version,
                    desktop_build=self.build,
                )

    def test_rejects_noncanonical_capture_plan(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            capture, result = self._fixture(root)
            value = json.loads(result.read_text(encoding="utf-8"))
            value["surfaces"][0]["captureKey"] = "99__launch"
            result.write_text(json.dumps(value), encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "S01 capture plan does not match"):
                build_official_manifest(
                    capture,
                    driver_result_path=result,
                    output_root=root / "noncanonical",
                    desktop_version=self.version,
                    desktop_build=self.build,
                )

            capture, result = self._fixture(root / "route")
            value = json.loads(result.read_text(encoding="utf-8"))
            target = next(
                row
                for row in value["surfaces"]
                if row["id"] == "S08" and row["route"] == "/settings/data-controls"
            )
            target["route"] = "/settings"
            result.write_text(json.dumps(value), encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "S08 required routes are incomplete"):
                build_official_manifest(
                    capture,
                    driver_result_path=result,
                    output_root=root / "missing-route",
                    desktop_version=self.version,
                    desktop_build=self.build,
                )


if __name__ == "__main__":
    unittest.main()
