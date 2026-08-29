from __future__ import annotations

import hashlib
import json
from pathlib import Path
import tempfile
import unittest

from PIL import Image

from scripts.merge_ipad_observed_parity import merge_observed_manifests


class MergeIPadObservedParityTests(unittest.TestCase):
    def _manifest(
        self,
        root: Path,
        name: str,
        *,
        surface_id: str,
        capture_key: str,
        route: str,
        state: str,
        color: tuple[int, int, int],
        device_id: str = "fixture-ipad-udid",
    ) -> Path:
        folder = root / name
        folder.mkdir(parents=True)
        image_path = folder / f"{surface_id}-{capture_key}-ipad.png"
        Image.new("RGB", (640, 480), color).save(image_path)
        image_hash = hashlib.sha256(image_path.read_bytes()).hexdigest()
        action = f"{surface_id}|{capture_key}|{route}|{state}"
        acceptance = folder / "interaction-acceptance.txt"
        acceptance.write_text(action + "\n", encoding="utf-8")
        surfaces = {
            f"S{index:02d}": {"captures": []}
            for index in range(1, 11)
        }
        surfaces[surface_id]["captures"].append({
            "captureKey": capture_key,
            "route": route,
            "stateKey": state,
            "path": image_path.name,
            "sha256": image_hash,
            "attachmentName": f"CODEXPAD_PARITY_{surface_id}__{capture_key}",
            "testIdentifier": f"ParityTests/test{surface_id}()",
            "configurationName": "Test Scheme Action",
            "deviceId": device_id,
            "deviceName": "Example iPad Pro",
            "timestamp": 1_700_000_000,
            "interactionInventory": {
                "controlCount": 1,
                "keyboardAccessibleCount": 1,
                "byTag": {"BUTTON": 1},
                "labelFingerprints": ["a" * 64],
            },
        })
        manifest = folder / "manifest.json"
        manifest.write_text(json.dumps({
            "schemaVersion": 5,
            "evidenceMode": "physical-official-renderer-observed",
            "desktopVersion": "26.810.52044",
            "desktopBuild": "6662",
            "deviceId": device_id,
            "deviceName": "Example iPad Pro",
            "observedSurfaceIds": [surface_id],
            "missingSurfaceIds": [
                candidate for candidate in surfaces if candidate != surface_id
            ],
            "interactionAcceptance": {
                "path": acceptance.name,
                "sha256": hashlib.sha256(acceptance.read_bytes()).hexdigest(),
                "actionCount": 1,
                "surfaceIds": [surface_id],
                "testIdentifier": f"ParityTests/test{surface_id}()",
                "configurationName": "Test Scheme Action",
                "deviceId": device_id,
                "deviceName": "Example iPad Pro",
                "timestamp": 1_700_000_000,
            },
            "surfaces": surfaces,
        }), encoding="utf-8")
        return manifest

    def test_merges_same_release_and_device_without_claiming_missing_states(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            first = self._manifest(
                root,
                "first",
                surface_id="S01",
                capture_key="00__launch",
                route="/login",
                state="launch",
                color=(10, 20, 30),
            )
            second = self._manifest(
                root,
                "second",
                surface_id="S02",
                capture_key="00__sidebar-expanded",
                route="/",
                state="sidebar-expanded",
                color=(40, 50, 60),
            )

            output = merge_observed_manifests(
                [first, second],
                root / "merged",
                desktop_version="26.810.52044",
                desktop_build="6662",
                device_id="fixture-ipad-udid",
            )

            value = json.loads(output.read_text(encoding="utf-8"))
            self.assertEqual(value["schemaVersion"], 6)
            self.assertEqual(value["deviceId"], "fixture-ipad-udid")
            self.assertEqual(value["observedCaptureCount"], 2)
            self.assertEqual(value["requiredCaptureCount"], 111)
            self.assertEqual(value["missingCaptureCount"], 109)
            self.assertEqual(value["observedSurfaceIds"], ["S01", "S02"])
            self.assertEqual(len(value["sourceManifests"]), 2)
            capture = value["surfaces"]["S01"]["captures"][0]
            self.assertEqual(capture["captureKey"], "00__launch")
            self.assertEqual(len(capture["observations"]), 1)
            self.assertEqual(
                capture["observations"][0]["sourceManifestSha256"],
                hashlib.sha256(first.read_bytes()).hexdigest(),
            )
            self.assertTrue((output.parent / capture["path"]).is_file())


if __name__ == "__main__":
    unittest.main()
