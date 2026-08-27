import hashlib
import json
from pathlib import Path
import tempfile
import unittest

from PIL import Image

from scripts.build_desktop_ui_parity import SURFACE_DEFINITIONS
from scripts.build_release_parity_evidence import (
    build_release_parity_evidence,
)


class BuildReleaseParityEvidenceTests(unittest.TestCase):
    def _fixture(self, root: Path):
        version = "26.727.51351"
        build = "6119"
        version_root = root / "versions" / version
        recovered = (
            root
            / "artifacts"
            / f"full-reverse-{version}"
            / "recovered-electron-source"
        )
        assets = recovered / "webview" / "assets"
        assets.mkdir(parents=True)
        for definition in SURFACE_DEFINITIONS:
            for pattern in definition["evidenceGlobs"]:
                (assets / pattern.replace("*", "fixture")).write_text(
                    "official renderer evidence\n",
                    encoding="utf-8",
                )
        version_root.mkdir(parents=True)
        dmg_sha = "a" * 64
        tree_sha = "b" * 64
        source_sha = "c" * 64
        (version_root / "manifest.json").write_text(
            json.dumps({"dmgSha256": dmg_sha}),
            encoding="utf-8",
        )
        (version_root / "desktop-surface-manifest.json").write_text(
            json.dumps({"resourceTreeSha256": tree_sha}),
            encoding="utf-8",
        )
        (recovered.parent / "full-reverse-manifest.json").write_text(
            json.dumps({"recoveredSourceIndexSha256": source_sha}),
            encoding="utf-8",
        )

        logs = root / "logs"
        logs.mkdir()
        log_paths = []
        for name in (
            "python.log",
            "swift.log",
            "rust.log",
            "xcui.log",
            "device-build.log",
            "device-surface.json",
        ):
            path = logs / name
            path.write_text(f"passed {name}\n", encoding="utf-8")
            log_paths.append(path)

        captures = root / "captures"
        captures.mkdir()
        surfaces = {}
        capture_index = 0
        for definition in SURFACE_DEFINITIONS:
            surface_id = definition["id"]
            required_states = definition["requiredStates"]
            required_routes = definition["routes"]
            row_count = max(len(required_states), len(required_routes))
            surface_captures = []
            for index in range(row_count):
                capture_index += 1
                official = captures / (
                    f"{surface_id}-{capture_index:03d}-desktop.png"
                )
                ipad = captures / f"{surface_id}-{capture_index:03d}-ipad.png"
                Image.new(
                    "RGB",
                    (640 + capture_index, 480 + capture_index),
                    (capture_index * 17 % 255, 40, 80),
                ).save(official)
                Image.new(
                    "RGB",
                    (800 + capture_index, 600 + capture_index),
                    (20, capture_index * 19 % 255, 100),
                ).save(ipad)
                surface_captures.append(
                    {
                        "route": required_routes[index % len(required_routes)],
                        "state": required_states[index % len(required_states)],
                        "officialDesktop": official.relative_to(root).as_posix(),
                        "ipad": ipad.relative_to(root).as_posix(),
                        "interactionComparison": {
                            "status": "matched",
                            "controlCountDelta": 0,
                            "keyboardAccessibleCountDelta": 0,
                            "byTagDelta": {},
                            "sharedLabelFingerprintCount": 3,
                            "missingOfficialLabelFingerprints": [],
                            "unexpectedIPadLabelFingerprints": [],
                        },
                    }
                )
            surfaces[surface_id] = {"captures": surface_captures}
        capture_input = captures / "capture-input.json"
        capture_input.write_text(
            json.dumps(
                {
                    "schemaVersion": 3,
                    "desktopVersion": version,
                    "desktopBuild": build,
                    "surfaces": surfaces,
                }
            ),
            encoding="utf-8",
        )
        return version, build, capture_input, log_paths

    def test_builds_hashed_unique_release_evidence_and_matched_contract(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            version, build, capture_input, logs = self._fixture(root)
            implementation, captures, parity = (
                build_release_parity_evidence(
                    root,
                    desktop_version=version,
                    desktop_build=build,
                    capture_input_path=capture_input,
                    python_test_log=logs[0],
                    swift_test_log=logs[1],
                    rust_test_log=logs[2],
                    xcui_test_log=logs[3],
                    device_build_log=logs[4],
                    device_surface_log=logs[5],
                )
            )

            self.assertTrue(implementation.is_file())
            self.assertTrue(captures.is_file())
            contract = json.loads(parity.read_text(encoding="utf-8"))
            self.assertEqual(contract["summary"]["implementationMatched"], 10)
            self.assertEqual(contract["summary"]["runtimeCaptureMatched"], 10)
            for row in contract["surfaces"]:
                self.assertEqual(row["implementationStatus"], "matched")
                self.assertEqual(row["simulatorEvidence"], [])
                self.assertGreaterEqual(len(row["deviceEvidence"]), 2)
                self.assertEqual(
                    row["runtimeCaptureStatus"],
                    "runtime-capture-matched",
                )
                for entry in row["visualEvidence"]:
                    path = root / entry["path"]
                    self.assertEqual(
                        hashlib.sha256(path.read_bytes()).hexdigest(),
                        entry["sha256"],
                    )
            capture_manifest = json.loads(captures.read_text(encoding="utf-8"))
            for surface_id, row in capture_manifest["surfaces"].items():
                self.assertEqual(row["interactionInventoryStatus"], "matched")
                self.assertEqual(
                    set(row["coveredStates"]),
                    set(row["requiredStates"]),
                )
                self.assertEqual(
                    set(row["coveredRoutes"]),
                    set(row["requiredRoutes"]),
                )
                for capture in row["captures"]:
                    metadata = root / capture["captureMetadata"]["path"]
                    metadata_value = json.loads(
                        metadata.read_text(encoding="utf-8")
                    )
                    self.assertEqual(
                        metadata_value["interactionComparison"]["status"],
                        "matched",
                        surface_id,
                    )

    def test_rejects_reused_surface_capture(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            version, build, capture_input, logs = self._fixture(root)
            record = json.loads(capture_input.read_text(encoding="utf-8"))
            record["surfaces"]["S02"]["captures"][0]["ipad"] = record[
                "surfaces"
            ]["S01"]["captures"][0]["ipad"]
            capture_input.write_text(json.dumps(record), encoding="utf-8")

            with self.assertRaisesRegex(
                ValueError,
                "reuses another iPad capture",
            ):
                build_release_parity_evidence(
                    root,
                    desktop_version=version,
                    desktop_build=build,
                    capture_input_path=capture_input,
                    python_test_log=logs[0],
                    swift_test_log=logs[1],
                    rust_test_log=logs[2],
                    xcui_test_log=logs[3],
                    device_build_log=logs[4],
                    device_surface_log=logs[5],
                )

    def test_rejects_representative_only_capture_without_required_state_coverage(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            version, build, capture_input, logs = self._fixture(root)
            record = json.loads(capture_input.read_text(encoding="utf-8"))
            record["surfaces"]["S01"]["captures"] = record["surfaces"][
                "S01"
            ]["captures"][:1]
            capture_input.write_text(json.dumps(record), encoding="utf-8")

            with self.assertRaisesRegex(
                ValueError,
                "S01 required states are incomplete",
            ):
                build_release_parity_evidence(
                    root,
                    desktop_version=version,
                    desktop_build=build,
                    capture_input_path=capture_input,
                    python_test_log=logs[0],
                    swift_test_log=logs[1],
                    rust_test_log=logs[2],
                    xcui_test_log=logs[3],
                    device_build_log=logs[4],
                    device_surface_log=logs[5],
                )

    def test_invalid_manual_capture_does_not_mutate_previous_evidence(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            version, build, capture_input, logs = self._fixture(root)
            evidence_root = root / "artifacts/parity-evidence" / version
            evidence_root.mkdir(parents=True)
            sentinel = evidence_root / "previous-certification.json"
            sentinel.write_bytes(b'{"status":"previous-complete"}\n')
            parity = root / "versions" / version / "desktop-ui-parity.json"
            parity.write_bytes(b'{"status":"previous-complete"}\n')
            record = json.loads(capture_input.read_text(encoding="utf-8"))
            record["surfaces"]["S02"]["captures"][0]["ipad"] = record[
                "surfaces"
            ]["S01"]["captures"][0]["ipad"]
            capture_input.write_text(json.dumps(record), encoding="utf-8")

            with self.assertRaisesRegex(
                ValueError,
                "reuses another iPad capture",
            ):
                build_release_parity_evidence(
                    root,
                    desktop_version=version,
                    desktop_build=build,
                    capture_input_path=capture_input,
                    python_test_log=logs[0],
                    swift_test_log=logs[1],
                    rust_test_log=logs[2],
                    xcui_test_log=logs[3],
                    device_build_log=logs[4],
                    device_surface_log=logs[5],
                )

            self.assertEqual(
                {
                    path.relative_to(evidence_root).as_posix():
                    path.read_bytes()
                    for path in evidence_root.rglob("*")
                    if path.is_file()
                },
                {
                    "previous-certification.json":
                    b'{"status":"previous-complete"}\n',
                },
            )
            self.assertEqual(
                parity.read_bytes(),
                b'{"status":"previous-complete"}\n',
            )

    def test_inventory_difference_keeps_surface_out_of_matched_contract(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            version, build, capture_input, logs = self._fixture(root)
            value = json.loads(capture_input.read_text(encoding="utf-8"))
            comparison = value["surfaces"]["S05"]["captures"][0][
                "interactionComparison"
            ]
            comparison["status"] = "different"
            comparison["controlCountDelta"] = -2
            capture_input.write_text(json.dumps(value), encoding="utf-8")

            _, captures, parity = build_release_parity_evidence(
                root,
                desktop_version=version,
                desktop_build=build,
                capture_input_path=capture_input,
                python_test_log=logs[0],
                swift_test_log=logs[1],
                rust_test_log=logs[2],
                xcui_test_log=logs[3],
                device_build_log=logs[4],
                device_surface_log=logs[5],
            )

            contract = json.loads(parity.read_text(encoding="utf-8"))
            self.assertEqual(contract["summary"]["implementationMatched"], 9)
            self.assertEqual(contract["summary"]["runtimeCaptureMatched"], 9)
            capture_manifest = json.loads(captures.read_text(encoding="utf-8"))
            self.assertEqual(
                capture_manifest["surfaces"]["S05"]["status"],
                "interaction-inventory-different",
            )


if __name__ == "__main__":
    unittest.main()
