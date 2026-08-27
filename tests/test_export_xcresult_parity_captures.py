from __future__ import annotations

import hashlib
import json
from pathlib import Path
import tempfile
import unittest

from PIL import Image, ImageOps

from scripts.export_xcresult_parity_captures import (
    PHYSICAL_RENDERER_EVIDENCE_MODE,
    export_parity_captures,
)
from scripts.parity_capture_plan import capture_specs


class ExportXCResultParityCapturesTests(unittest.TestCase):
    def _export_fixture(
        self,
        root: Path,
        *,
        missing_surface: str | None = None,
        duplicate_surface: str | None = None,
        duplicate_bytes: bool = False,
        alias_bytes: bool = False,
        exif_orientation: int | None = None,
        missing_interaction_acceptance: bool = False,
        malformed_interaction_acceptance: bool = False,
        missing_inventory_surface: str | None = None,
        malformed_inventory_surface: str | None = None,
        reverse_rows: bool = False,
    ) -> Path:
        exported = root / "xcresult-export"
        exported.mkdir(parents=True)
        rows = []
        first_payload: bytes | None = None
        specs = capture_specs()
        for index, spec in enumerate(specs, start=1):
            surface_id = spec["surfaceId"]
            capture_key = spec["captureKey"]
            if surface_id == missing_surface:
                continue
            exported_name = f"attachment-{index:02d}.png"
            attachment_path = exported / exported_name
            image = Image.new(
                "RGB",
                (640 + index, 480 + index),
                (index * 17 % 255, 40, 80),
            )
            if alias_bytes and (surface_id, capture_key) == ("S01", "01__signed-out"):
                image = Image.new("RGB", (641, 481), (17, 40, 80))
            if exif_orientation is None:
                image.save(attachment_path)
            else:
                exif = image.getexif()
                exif[274] = exif_orientation
                image.save(attachment_path, exif=exif)
            payload = attachment_path.read_bytes()
            if duplicate_bytes and index == len(specs):
                assert first_payload is not None
                payload = first_payload
                attachment_path.write_bytes(payload)
            if first_payload is None:
                first_payload = payload
            attachment_surface = (
                duplicate_surface
                if index == len(specs) and duplicate_surface is not None
                else surface_id
            )
            attachment_capture_key = (
                specs[0]["captureKey"]
                if index == len(specs) and duplicate_surface is not None
                else capture_key
            )
            row = {
                    "testIdentifier":
                        "CodexPadParityCaptureUITests/"
                        f"testCapture{surface_id}_{capture_key}()",
                    "testIdentifierURL":
                        "test://com.apple.xcode/CodexPad/"
                        "CodexPadParityCaptureUITests/"
                        f"testCapture{surface_id}_{capture_key}",
                    "attachments": [
                        {
                            "configurationName": "Parity Capture",
                            "deviceId": "redacted-fixture-device",
                            "deviceName": "iPad Pro 13-inch (M5)",
                            "exportedFileName": exported_name,
                            "isAssociatedWithFailure": False,
                            "suggestedHumanReadableName":
                                "CODEXPAD_PARITY_"
                                f"{attachment_surface}__{attachment_capture_key}"
                                f"_0_fixture-{index:02d}.png",
                            "timestamp": 1_700_000_000 + index,
                        }
                    ],
                }
            if surface_id != missing_inventory_surface:
                inventory_name = f"inventory-{index:02d}.json"
                inventory = {
                    "controlCount": index + 2,
                    "keyboardAccessibleCount": index + 1,
                    "byTag": {"BUTTON": index + 1, "INPUT": 1},
                    "labelFingerprints": [
                        hashlib.sha256(
                            f"{surface_id}-{capture_key}-label".encode("utf-8")
                        ).hexdigest()
                    ],
                }
                if surface_id == malformed_inventory_surface:
                    inventory["labelFingerprints"] = ["not-a-sha256"]
                (exported / inventory_name).write_text(
                    json.dumps(inventory),
                    encoding="utf-8",
                )
                row["attachments"].append(
                    {
                        "configurationName": "Parity Capture",
                        "deviceId": "redacted-fixture-device",
                        "deviceName": "iPad Pro 13-inch (M5)",
                        "exportedFileName": inventory_name,
                        "isAssociatedWithFailure": False,
                        "suggestedHumanReadableName":
                            "CODEXPAD_INVENTORY_"
                            f"{surface_id}__{capture_key}"
                            f"_0_fixture-{index:02d}.json",
                        "timestamp": 1_700_000_000 + index,
                    }
                )
            rows.append(row)
        if not missing_interaction_acceptance:
            interaction_name = "interaction-acceptance.txt"
            interactions = [
                "|".join((
                    spec["surfaceId"],
                    spec["captureKey"],
                    spec["route"],
                    spec["state"],
                ))
                for spec in specs
                if spec["surfaceId"] != missing_surface
            ]
            if malformed_interaction_acceptance:
                interactions.pop()
            (exported / interaction_name).write_text(
                "\n".join(interactions) + "\n",
                encoding="utf-8",
            )
            rows[0]["attachments"].append(
                {
                    "configurationName": "Parity Capture",
                    "deviceId": "redacted-fixture-device",
                    "deviceName": "iPad Pro 13-inch (M5)",
                    "exportedFileName": interaction_name,
                    "isAssociatedWithFailure": False,
                    "suggestedHumanReadableName":
                        "Physical iPad interaction acceptance_0_fixture.txt",
                    "timestamp": 1_700_000_100,
                }
            )
        (exported / "manifest.json").write_text(
            json.dumps(list(reversed(rows)) if reverse_rows else rows),
            encoding="utf-8",
        )
        return exported

    def test_exports_exact_s01_s10_pngs_with_stable_manifest(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            exported = self._export_fixture(root)
            destination = root / "captures"

            manifest_path = export_parity_captures(
                exported,
                destination,
                desktop_version="26.803.81509",
                desktop_build="6415",
            )

            manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
            self.assertEqual(manifest["schemaVersion"], 4)
            self.assertEqual(manifest["desktopVersion"], "26.803.81509")
            self.assertEqual(manifest["desktopBuild"], "6415")
            self.assertEqual(
                manifest["deviceId"],
                "redacted-fixture-device",
            )
            self.assertEqual(manifest["deviceName"], "iPad Pro 13-inch (M5)")
            interaction = manifest["interactionAcceptance"]
            self.assertEqual(interaction["path"], "interaction-acceptance.txt")
            self.assertEqual(
                interaction["deviceId"],
                "redacted-fixture-device",
            )
            self.assertEqual(interaction["actionCount"], len(capture_specs()))
            self.assertEqual(interaction["surfaceIds"], [
                f"S{index:02d}" for index in range(1, 11)
            ])
            self.assertEqual(
                hashlib.sha256(
                    (destination / interaction["path"]).read_bytes()
                ).hexdigest(),
                interaction["sha256"],
            )
            self.assertEqual(list(manifest["surfaces"]), [
                f"S{index:02d}" for index in range(1, 11)
            ])
            for surface_id, row in manifest["surfaces"].items():
                self.assertTrue(row["captures"])
                for capture_row in row["captures"]:
                    capture = destination / capture_row["path"]
                    self.assertEqual(
                        capture.name,
                        f"{surface_id}-{capture_row['captureKey']}-ipad.png",
                    )
                    self.assertEqual(
                        hashlib.sha256(capture.read_bytes()).hexdigest(),
                        capture_row["sha256"],
                    )
                    self.assertEqual(
                        capture_row["attachmentName"],
                        f"CODEXPAD_PARITY_{surface_id}__"
                        f"{capture_row['captureKey']}",
                    )
                    self.assertEqual(
                        capture_row["deviceId"],
                        "redacted-fixture-device",
                    )
                    inventory = capture_row["interactionInventory"]
                    self.assertGreater(inventory["controlCount"], 0)
                    self.assertGreater(
                        inventory["keyboardAccessibleCount"], 0
                    )
                    self.assertTrue(inventory["byTag"])
                    self.assertTrue(inventory["labelFingerprints"])

    def test_rejects_missing_or_duplicate_surface_before_mutating_output(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            destination = root / "captures"
            destination.mkdir()
            sentinel = destination / "previous.txt"
            sentinel.write_text("previous-complete\n", encoding="utf-8")

            for exported, message in (
                (
                    self._export_fixture(
                        root / "missing",
                        missing_surface="S07",
                    ),
                    "missing parity captures: S07",
                ),
                (
                    self._export_fixture(
                        root / "duplicate",
                        duplicate_surface="S01",
                    ),
                    "duplicate parity capture: S01/00__launch",
                ),
            ):
                with self.subTest(message=message):
                    with self.assertRaisesRegex(ValueError, message):
                        export_parity_captures(
                            exported,
                            destination,
                            desktop_version="26.803.81509",
                            desktop_build="6415",
                        )
                    self.assertEqual(
                        {
                            path.name: path.read_bytes()
                            for path in destination.iterdir()
                        },
                        {"previous.txt": b"previous-complete\n"},
                    )

    def test_allows_known_s09_supplemental_duplicate_and_keeps_primary_capture(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            exported = self._export_fixture(root)
            rows = json.loads((exported / "manifest.json").read_text())
            primary = next(
                row
                for row in rows
                if any(
                    str(attachment.get("suggestedHumanReadableName", ""))
                    .startswith("CODEXPAD_PARITY_S09__01__empty")
                    for attachment in row["attachments"]
                )
            )
            primary["testIdentifier"] = (
                "CodexPadParityCaptureUITests/"
                "testCapturesOfficialRendererParitySurfaces()"
            )
            source = exported / next(
                attachment["exportedFileName"]
                for attachment in primary["attachments"]
                if str(attachment.get("suggestedHumanReadableName", ""))
                .startswith("CODEXPAD_PARITY_S09__01__empty")
            )
            duplicate_name = "supplemental-s09-01.png"
            (exported / duplicate_name).write_bytes(source.read_bytes())
            inventory_name = "supplemental-s09-01.json"
            (exported / inventory_name).write_text(
                json.dumps({
                    "controlCount": 3,
                    "keyboardAccessibleCount": 2,
                    "byTag": {"BUTTON": 2, "INPUT": 1},
                    "labelFingerprints": ["a" * 64],
                }),
                encoding="utf-8",
            )
            duplicate = {
                "testIdentifier":
                    "CodexPadParityCaptureUITests/"
                    "testCapturesS09SecondaryProductStatesOnPhysicalIPad()",
                "attachments": [
                    {
                        "configurationName": "Parity Capture",
                        "deviceId": "redacted-fixture-device",
                        "deviceName": "iPad Pro 13-inch (M5)",
                        "exportedFileName": duplicate_name,
                        "isAssociatedWithFailure": False,
                        "suggestedHumanReadableName":
                            "CODEXPAD_PARITY_S09__01__empty_0_supplemental.png",
                        "timestamp": 1_700_000_999,
                    },
                    {
                        "configurationName": "Parity Capture",
                        "deviceId": "redacted-fixture-device",
                        "deviceName": "iPad Pro 13-inch (M5)",
                        "exportedFileName": inventory_name,
                        "isAssociatedWithFailure": False,
                        "suggestedHumanReadableName":
                            "CODEXPAD_INVENTORY_S09__01__empty_0_supplemental.json",
                        "timestamp": 1_700_000_999,
                    },
                ],
            }
            rows.append(duplicate)
            (exported / "manifest.json").write_text(
                json.dumps(rows),
                encoding="utf-8",
            )

            manifest_path = export_parity_captures(
                exported,
                root / "captures",
                desktop_version="26.810.52044",
                desktop_build="6662",
            )

            manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
            capture = next(
                row
                for row in manifest["surfaces"]["S09"]["captures"]
                if row["captureKey"] == "01__empty"
            )
            self.assertEqual(
                capture["testIdentifier"],
                "CodexPadParityCaptureUITests/"
                "testCapturesOfficialRendererParitySurfaces()",
            )

    def test_exports_observed_physical_renderer_evidence_without_fabricating_missing_surfaces(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            exported = self._export_fixture(root, missing_surface="S09")
            manifest_path = export_parity_captures(
                exported,
                root / "captures",
                desktop_version="26.810.52044",
                desktop_build="6662",
                evidence_mode=PHYSICAL_RENDERER_EVIDENCE_MODE,
            )
            manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
            self.assertEqual(manifest["schemaVersion"], 5)
            self.assertEqual(
                manifest["evidenceMode"],
                PHYSICAL_RENDERER_EVIDENCE_MODE,
            )
            self.assertEqual(manifest["missingSurfaceIds"], ["S09"])
            self.assertEqual(manifest["surfaces"]["S09"]["captures"], [])
            self.assertNotIn("S09", manifest["observedSurfaceIds"])
            self.assertEqual(
                manifest["interactionAcceptance"]["actionCount"],
                sum(
                    spec["surfaceId"] != "S09" for spec in capture_specs()
                ),
            )

    def test_physical_renderer_evidence_preserves_valid_observed_action_order(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            exported = self._export_fixture(root, missing_surface="S09")
            acceptance = exported / "interaction-acceptance.txt"
            observed_actions = acceptance.read_text(encoding="utf-8").splitlines()
            observed_actions[3], observed_actions[4] = (
                observed_actions[4],
                observed_actions[3],
            )
            acceptance.write_text(
                "\n".join(observed_actions) + "\n",
                encoding="utf-8",
            )

            manifest_path = export_parity_captures(
                exported,
                root / "captures",
                desktop_version="26.810.52044",
                desktop_build="6662",
                evidence_mode=PHYSICAL_RENDERER_EVIDENCE_MODE,
            )

            copied_acceptance = manifest_path.parent / "interaction-acceptance.txt"
            self.assertEqual(
                copied_acceptance.read_text(encoding="utf-8").splitlines(),
                observed_actions,
            )

    def test_physical_renderer_evidence_rejects_invalid_observed_action_sets(self):
        mutations = {
            "missing": lambda actions: actions[:-1],
            "duplicate": lambda actions: actions + [actions[0]],
            "extra": lambda actions: actions + ["S99|00__extra|/extra|extra"],
        }
        for label, mutate in mutations.items():
            with self.subTest(label=label):
                with tempfile.TemporaryDirectory() as temporary:
                    root = Path(temporary)
                    exported = self._export_fixture(root, missing_surface="S09")
                    acceptance = exported / "interaction-acceptance.txt"
                    actions = acceptance.read_text(encoding="utf-8").splitlines()
                    acceptance.write_text(
                        "\n".join(mutate(actions)) + "\n",
                        encoding="utf-8",
                    )

                    with self.assertRaisesRegex(
                        ValueError,
                        "interaction acceptance actions do not match observed captures",
                    ):
                        export_parity_captures(
                            exported,
                            root / "captures",
                            desktop_version="26.810.52044",
                            desktop_build="6662",
                            evidence_mode=PHYSICAL_RENDERER_EVIDENCE_MODE,
                        )

    def test_rejects_reused_image_bytes(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            exported = self._export_fixture(
                root,
                duplicate_bytes=True,
            )
            with self.assertRaisesRegex(
                ValueError,
                "S10 reuses image bytes from S01",
            ):
                export_parity_captures(
                    exported,
                    root / "captures",
                    desktop_version="26.803.81509",
                    desktop_build="6415",
                )

    def test_allows_only_declared_visual_alias(self):
        for reverse_rows in (False, True):
            with self.subTest(reverse_rows=reverse_rows):
                with tempfile.TemporaryDirectory() as temporary:
                    root = Path(temporary)
                    exported = self._export_fixture(
                        root,
                        alias_bytes=True,
                        reverse_rows=reverse_rows,
                    )
                    manifest_path = export_parity_captures(
                        exported,
                        root / "captures",
                        desktop_version="26.803.81509",
                        desktop_build="6415",
                    )
                    manifest = json.loads(
                        manifest_path.read_text(encoding="utf-8")
                    )
                    signed_out = next(
                        row
                        for row in manifest["surfaces"]["S01"]["captures"]
                        if row["captureKey"] == "01__signed-out"
                    )
                    self.assertEqual(
                        signed_out["visualAliasOf"],
                        ["S01", "00__launch"],
                    )

    def test_rejects_missing_or_incomplete_interaction_acceptance(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            for exported, message in (
                (
                    self._export_fixture(
                        root / "missing-interactions",
                        missing_interaction_acceptance=True,
                    ),
                    "interaction acceptance attachment is missing",
                ),
                (
                    self._export_fixture(
                        root / "incomplete-interactions",
                        malformed_interaction_acceptance=True,
                    ),
                    "interaction acceptance actions must cover S01 through S10",
                ),
            ):
                with self.subTest(message=message):
                    with self.assertRaisesRegex(ValueError, message):
                        export_parity_captures(
                            exported,
                            root / "captures",
                            desktop_version="26.803.81509",
                            desktop_build="6415",
                        )

    def test_rejects_missing_or_malformed_interaction_inventory(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            for exported, message in (
                (
                    self._export_fixture(
                        root / "missing-inventory",
                        missing_inventory_surface="S07",
                    ),
                    "missing interaction inventories: S07",
                ),
                (
                    self._export_fixture(
                        root / "malformed-inventory",
                        malformed_inventory_surface="S04",
                    ),
                    "S04 interaction inventory is malformed",
                ),
            ):
                with self.subTest(message=message):
                    with self.assertRaisesRegex(ValueError, message):
                        export_parity_captures(
                            exported,
                            root / "captures",
                            desktop_version="26.803.81509",
                            desktop_build="6415",
                        )

    def test_normalizes_exif_orientation_before_hashing_capture(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            exported = self._export_fixture(root, exif_orientation=6)
            destination = root / "captures"

            manifest_path = export_parity_captures(
                exported,
                destination,
                desktop_version="26.803.81509",
                desktop_build="6415",
            )

            manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
            index = 0
            for row in manifest["surfaces"].values():
                for capture_row in row["captures"]:
                    index += 1
                    source = exported / f"attachment-{index:02d}.png"
                    capture = destination / capture_row["path"]
                    with Image.open(source) as raw:
                        expected_size = ImageOps.exif_transpose(raw).size
                    with Image.open(capture) as normalized:
                        self.assertEqual(normalized.size, expected_size)
                        self.assertEqual(normalized.getexif().get(274, 1), 1)
                    self.assertEqual(
                        hashlib.sha256(capture.read_bytes()).hexdigest(),
                        capture_row["sha256"],
                    )


if __name__ == "__main__":
    unittest.main()
