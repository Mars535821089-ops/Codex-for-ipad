from __future__ import annotations

import copy
import hashlib
import tempfile
import unittest
from pathlib import Path

from scripts.build_desktop_ui_parity import (
    SURFACE_DEFINITIONS,
    build_desktop_ui_parity,
    desktop_ui_parity_blockers,
)


class DesktopUIParityContractTests(unittest.TestCase):
    SOURCE_HASHES = {
        "source_dmg_sha256": "a" * 64,
        "desktop_surface_tree_sha256": "b" * 64,
        "recovered_source_index_sha256": "c" * 64,
    }

    def _write_reference_files(self, root: Path) -> None:
        for definition in SURFACE_DEFINITIONS:
            for pattern in definition["evidenceGlobs"]:
                filename = pattern.replace("*", "fixture")
                path = root / "webview/assets" / filename
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(
                    f"// evidence for {definition['id']}\n",
                    encoding="utf-8",
                )

    def _capture_manifest(
        self,
        evidence: dict[str, str],
        *,
        different_surface: str | None = None,
    ) -> dict[str, object]:
        surfaces = {}
        for definition in SURFACE_DEFINITIONS:
            surface_id = definition["id"]
            is_different = surface_id == different_surface
            states = definition["requiredStates"]
            routes = definition["routes"]
            captures = []
            for index in range(max(len(states), len(routes))):
                captures.append(
                    {
                        "route": routes[index % len(routes)],
                        "state": states[index % len(states)],
                        "status": (
                            "interaction-inventory-different"
                            if is_different and index == 0
                            else "matched"
                        ),
                        "interactionInventoryStatus": (
                            "different"
                            if is_different and index == 0
                            else "matched"
                        ),
                        "officialDesktop": evidence,
                        "ipad": evidence,
                        "pixelDiff": evidence,
                        "captureMetadata": evidence,
                    }
                )
            surfaces[surface_id] = {
                "status": (
                    "interaction-inventory-different"
                    if is_different
                    else "matched"
                ),
                "interactionInventoryStatus": (
                    "different" if is_different else "matched"
                ),
                "requiredRoutes": list(routes),
                "requiredStates": list(states),
                "coveredRoutes": sorted(set(routes)),
                "coveredStates": sorted(set(states)),
                "captures": captures,
            }
        return {"surfaces": surfaces}

    def test_all_desktop_surfaces_start_truthfully_unmatched(self):
        with tempfile.TemporaryDirectory() as temporary:
            recovered = Path(temporary)
            self._write_reference_files(recovered)

            contract = build_desktop_ui_parity(
                recovered,
                desktop_version="99.7.1",
                desktop_build="7001",
                **self.SOURCE_HASHES,
            )

            self.assertEqual(
                contract["summary"]["surfaceCount"],
                len(SURFACE_DEFINITIONS),
            )
            self.assertEqual(
                contract["summary"]["referenceIndexed"],
                len(SURFACE_DEFINITIONS),
            )
            self.assertEqual(contract["summary"]["implementationMatched"], 0)
            self.assertEqual(
                contract["summary"]["implementationUnmatched"],
                len(SURFACE_DEFINITIONS),
            )
            self.assertEqual(
                len(desktop_ui_parity_blockers(contract)),
                len(SURFACE_DEFINITIONS),
            )
            self.assertTrue(
                all(
                    item["referenceStatus"] == "reference-indexed"
                    and item["implementationStatus"] == "unmatched"
                    and item["runtimeCaptureStatus"]
                    == "runtime-capture-pending"
                    for item in contract["surfaces"]
                )
            )

    def test_missing_desktop_evidence_is_a_distinct_blocker(self):
        with tempfile.TemporaryDirectory() as temporary:
            recovered = Path(temporary)
            contract = build_desktop_ui_parity(
                recovered,
                desktop_version="99.7.1",
                desktop_build="7001",
                **self.SOURCE_HASHES,
            )

            blockers = desktop_ui_parity_blockers(contract)

            self.assertTrue(blockers)
            self.assertTrue(
                all(
                    blocker["referenceStatus"] == "missing-reference"
                    for blocker in blockers
                )
            )

    def test_security_route_chunk_is_indexed_as_secondary_product_evidence(self):
        with tempfile.TemporaryDirectory() as temporary:
            recovered = Path(temporary)
            self._write_reference_files(recovered)
            assets = recovered / "webview/assets"
            for path in assets.glob("security-page-*.js"):
                path.unlink()
            (assets / "security-route-fixture.js").write_text(
                "// renamed official security route chunk\n",
                encoding="utf-8",
            )

            contract = build_desktop_ui_parity(
                recovered,
                desktop_version="99.7.1",
                desktop_build="7001",
                **self.SOURCE_HASHES,
            )

            secondary = next(
                row for row in contract["surfaces"] if row["id"] == "S09"
            )
            self.assertEqual(
                secondary["referenceStatus"],
                "reference-indexed",
            )
            self.assertTrue(
                any(
                    row["file"].endswith("security-route-fixture.js")
                    for row in secondary["desktopEvidence"]
                )
            )

    def test_contract_pins_exact_release_source_hashes(self):
        with tempfile.TemporaryDirectory() as temporary:
            recovered = Path(temporary)
            self._write_reference_files(recovered)

            contract = build_desktop_ui_parity(
                recovered,
                desktop_version="99.7.1",
                desktop_build="7001",
                **self.SOURCE_HASHES,
            )

            self.assertEqual(
                contract["sourceIdentity"],
                {
                    "dmgSha256": "a" * 64,
                    "desktopSurfaceTreeSha256": "b" * 64,
                    "recoveredSourceIndexSha256": "c" * 64,
                },
            )

    def test_blocker_scan_requires_exact_s01_through_s10(self):
        with tempfile.TemporaryDirectory() as temporary:
            recovered = Path(temporary)
            self._write_reference_files(recovered)
            contract = build_desktop_ui_parity(
                recovered,
                desktop_version="99.7.1",
                desktop_build="7001",
                **self.SOURCE_HASHES,
            )

            malformed_contracts = []
            empty = copy.deepcopy(contract)
            empty["surfaces"] = []
            empty["summary"]["surfaceCount"] = 0
            malformed_contracts.append(empty)
            missing = copy.deepcopy(contract)
            missing["surfaces"].pop()
            malformed_contracts.append(missing)
            duplicate = copy.deepcopy(contract)
            duplicate["surfaces"][-1]["id"] = "S09"
            malformed_contracts.append(duplicate)
            extra = copy.deepcopy(contract)
            extra["surfaces"].append(copy.deepcopy(extra["surfaces"][-1]))
            extra["surfaces"][-1]["id"] = "S11"
            malformed_contracts.append(extra)

            for malformed in malformed_contracts:
                with self.subTest(ids=[
                    row["id"] for row in malformed["surfaces"]
                ]):
                    with self.assertRaisesRegex(ValueError, "S01 through S10"):
                        desktop_ui_parity_blockers(malformed)

    def test_summary_is_recomputed_instead_of_trusted(self):
        with tempfile.TemporaryDirectory() as temporary:
            recovered = Path(temporary)
            self._write_reference_files(recovered)
            contract = build_desktop_ui_parity(
                recovered,
                desktop_version="99.7.1",
                desktop_build="7001",
                **self.SOURCE_HASHES,
            )
            contract["summary"]["implementationMatched"] = 10

            with self.assertRaisesRegex(ValueError, "summary"):
                desktop_ui_parity_blockers(contract)

    def test_matched_evidence_is_content_hashed_and_required(self):
        with tempfile.TemporaryDirectory() as temporary:
            project_root = Path(temporary)
            recovered = project_root / "recovered"
            self._write_reference_files(recovered)
            evidence_path = project_root / "evidence/proof.json"
            evidence_path.parent.mkdir()
            evidence_path.write_text('{"status":"passed"}\n', encoding="utf-8")
            evidence_sha = hashlib.sha256(
                evidence_path.read_bytes()
            ).hexdigest()
            evidence = {
                "path": evidence_path.relative_to(project_root).as_posix(),
                "sha256": evidence_sha,
            }
            implementation = {
                "surfaces": {
                    definition["id"]: {
                        "status": "matched",
                        "automatedTests": [evidence],
                        "simulatorEvidence": [],
                        "deviceEvidence": [evidence],
                        "visualEvidence": [evidence],
                    }
                    for definition in SURFACE_DEFINITIONS
                }
            }
            captures = self._capture_manifest(evidence)

            contract = build_desktop_ui_parity(
                recovered,
                desktop_version="99.7.1",
                desktop_build="7001",
                implementation_evidence=implementation,
                capture_manifest=captures,
                evidence_root=project_root,
                **self.SOURCE_HASHES,
            )

            self.assertEqual(desktop_ui_parity_blockers(contract), [])
            self.assertEqual(
                contract["summary"]["implementationMatched"],
                len(SURFACE_DEFINITIONS),
            )
            self.assertEqual(
                contract["summary"]["runtimeCaptureMatched"],
                len(SURFACE_DEFINITIONS),
            )
            self.assertTrue(
                all(
                    row["interactionInventoryStatus"] == "matched"
                    and set(row["runtimeCaptureEvidence"]) == {
                        "requiredRoutes",
                        "requiredStates",
                        "coveredRoutes",
                        "coveredStates",
                        "captures",
                    }
                    for row in contract["surfaces"]
                )
            )
            evidence_path.write_text("tampered\n", encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "hash mismatch"):
                build_desktop_ui_parity(
                    recovered,
                    desktop_version="99.7.1",
                    desktop_build="7001",
                    implementation_evidence=implementation,
                    capture_manifest=captures,
                    evidence_root=project_root,
                    **self.SOURCE_HASHES,
                )

    def test_interaction_inventory_difference_is_an_explicit_blocker(self):
        with tempfile.TemporaryDirectory() as temporary:
            project_root = Path(temporary)
            recovered = project_root / "recovered"
            self._write_reference_files(recovered)
            evidence_path = project_root / "evidence/proof.json"
            evidence_path.parent.mkdir()
            evidence_path.write_text('{"status":"passed"}\n', encoding="utf-8")
            evidence = {
                "path": evidence_path.relative_to(project_root).as_posix(),
                "sha256": hashlib.sha256(evidence_path.read_bytes()).hexdigest(),
            }
            implementation = {
                "surfaces": {
                    definition["id"]: {
                        "status": "matched",
                        "automatedTests": [evidence],
                        "simulatorEvidence": [],
                        "deviceEvidence": [evidence],
                        "visualEvidence": [evidence],
                    }
                    for definition in SURFACE_DEFINITIONS
                }
            }
            captures = self._capture_manifest(
                evidence,
                different_surface="S05",
            )

            contract = build_desktop_ui_parity(
                recovered,
                desktop_version="99.7.1",
                desktop_build="7001",
                implementation_evidence=implementation,
                capture_manifest=captures,
                evidence_root=project_root,
                **self.SOURCE_HASHES,
            )

            s05 = next(row for row in contract["surfaces"] if row["id"] == "S05")
            self.assertEqual(s05["interactionInventoryStatus"], "different")
            blockers = desktop_ui_parity_blockers(contract)
            s05_blocker = next(row for row in blockers if row["id"] == "S05")
            self.assertEqual(
                s05_blocker["interactionInventoryStatus"],
                "different",
            )


if __name__ == "__main__":
    unittest.main()
