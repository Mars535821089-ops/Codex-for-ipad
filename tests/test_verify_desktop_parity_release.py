from __future__ import annotations

import copy
import hashlib
import json
import tempfile
import unittest
from pathlib import Path

from scripts.build_desktop_surface_manifest import (
    REQUIRED_BRIDGE_MEMBERS,
    build_desktop_surface_manifest,
)
from scripts.build_desktop_interaction_inventory import (
    build_desktop_interaction_inventory,
)
from scripts.build_desktop_ui_parity import (
    SURFACE_DEFINITIONS,
    build_desktop_ui_parity,
)
from scripts.verify_desktop_parity_release import verify_release


class VerifyDesktopParityReleaseTests(unittest.TestCase):
    VERSION = "99.7.1"
    BUILD = "7001"
    DMG_SHA256 = hashlib.sha256(b"official fixture DMG").hexdigest()

    def _write_json(self, path: Path, value: object) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(
            json.dumps(value, ensure_ascii=False, indent=2) + "\n",
            encoding="utf-8",
        )

    def _write_reference_files(self, recovered_root: Path) -> None:
        for definition in SURFACE_DEFINITIONS:
            for pattern in definition["evidenceGlobs"]:
                filename = pattern.replace("*", "fixture")
                path = recovered_root / "webview/assets" / filename
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(
                    (
                        f"const message={{id:`{definition['id']}.fixture`,"
                        f"defaultMessage:`{definition['id']} Fixture`,"
                        "description:`Button label for fixture control`};\n"
                    ),
                    encoding="utf-8",
                )

    def _capture_manifest(
        self,
        evidence: dict[str, str],
    ) -> dict[str, object]:
        surfaces = {}
        for definition in SURFACE_DEFINITIONS:
            routes = definition["routes"]
            states = definition["requiredStates"]
            captures = [
                {
                    "route": routes[index % len(routes)],
                    "state": states[index % len(states)],
                    "status": "matched",
                    "interactionInventoryStatus": "matched",
                    "officialDesktop": evidence,
                    "ipad": evidence,
                    "pixelDiff": evidence,
                    "captureMetadata": evidence,
                }
                for index in range(max(len(routes), len(states)))
            ]
            surfaces[definition["id"]] = {
                "status": "matched",
                "interactionInventoryStatus": "matched",
                "requiredRoutes": list(routes),
                "requiredStates": list(states),
                "coveredRoutes": sorted(set(routes)),
                "coveredStates": sorted(set(states)),
                "captures": captures,
            }
        return {"surfaces": surfaces}

    def _seed_release(self, root: Path) -> dict[str, Path | str]:
        version_root = root / "versions" / self.VERSION
        artifacts = root / "artifacts"
        full_reverse = artifacts / f"full-reverse-{self.VERSION}"
        renderer = full_reverse / "app-asar/webview"
        (renderer / "assets").mkdir(parents=True)
        (renderer / "assets/main.js").write_text(
            "console.log('Codex');\n",
            encoding="utf-8",
        )
        (renderer / "index.html").write_text(
            "<html><head><title>Codex</title></head>"
            '<body><script type="module" src="assets/main.js"></script>'
            "</body></html>\n",
            encoding="utf-8",
        )
        recovered = full_reverse / "recovered-electron-source"
        self._write_reference_files(recovered)
        preload = recovered / ".vite/build/preload.js"
        preload.parent.mkdir(parents=True)
        preload.write_text(
            "\n".join(REQUIRED_BRIDGE_MEMBERS) + "\n",
            encoding="utf-8",
        )

        recovered_index = full_reverse / "recovered-source-index.json"
        self._write_json(recovered_index, {"files": []})
        recovered_index_sha = hashlib.sha256(
            recovered_index.read_bytes()
        ).hexdigest()
        surface_manifest = build_desktop_surface_manifest(
            renderer,
            preload,
            desktop_version=self.VERSION,
            desktop_build=self.BUILD,
        )

        evidence_path = artifacts / "parity-evidence/proof.json"
        self._write_json(evidence_path, {"status": "passed"})
        evidence = {
            "path": evidence_path.relative_to(root).as_posix(),
            "sha256": hashlib.sha256(evidence_path.read_bytes()).hexdigest(),
        }
        implementation = {
            "surfaces": {
                definition["id"]: {
                    "status": "matched",
                    "automatedTests": [evidence],
                    "simulatorEvidence": [evidence],
                    "deviceEvidence": [evidence],
                    "visualEvidence": [evidence],
                }
                for definition in SURFACE_DEFINITIONS
            }
        }
        captures = self._capture_manifest(evidence)
        ui_contract = build_desktop_ui_parity(
            recovered,
            desktop_version=self.VERSION,
            desktop_build=self.BUILD,
            source_dmg_sha256=self.DMG_SHA256,
            desktop_surface_tree_sha256=surface_manifest[
                "resourceTreeSha256"
            ],
            recovered_source_index_sha256=recovered_index_sha,
            implementation_evidence=implementation,
            capture_manifest=captures,
            evidence_root=root,
        )

        self._write_json(
            version_root / "manifest.json",
            {
                "version": self.VERSION,
                "build": self.BUILD,
                "dmgSha256": self.DMG_SHA256,
            },
        )
        self._write_json(
            artifacts / f"manifest-{self.VERSION}.json",
            {
                "version": self.VERSION,
                "build": self.BUILD,
                "dmg_sha256": self.DMG_SHA256,
            },
        )
        self._write_json(
            full_reverse / "full-reverse-manifest.json",
            {
                "version": self.VERSION,
                "build": self.BUILD,
                "recoveredSourceIndexSha256": recovered_index_sha,
            },
        )
        self._write_json(
            version_root / "desktop-surface-manifest.json",
            surface_manifest,
        )
        self._write_json(
            version_root / "desktop-interaction-inventory.json",
            build_desktop_interaction_inventory(
                recovered,
                desktop_version=self.VERSION,
                desktop_build=self.BUILD,
                desktop_surface_tree_sha256=surface_manifest[
                    "resourceTreeSha256"
                ],
            ),
        )
        self._write_json(
            version_root / "desktop-ui-parity.json",
            ui_contract,
        )
        self._write_json(
            version_root / "feature-inventory.json",
            {
                "schemaVersion": 1,
                "version": self.VERSION,
                "featureCount": 1,
                "statusCounts": {"matched": 1},
                "features": [{"id": "fixture.feature", "status": "matched"}],
            },
        )
        feature_inventory = version_root / "feature-inventory.json"
        protocol = (
            full_reverse
            / "official-codex-source/codex-rs/app-server-protocol"
            / "src/protocol/common.rs"
        )
        protocol.parent.mkdir(parents=True, exist_ok=True)
        protocol.write_text("// fixture protocol\n", encoding="utf-8")
        self._write_json(
            version_root / "feature-coverage-audit.json",
            {
                "schemaVersion": 1,
                "version": self.VERSION,
                "protocolSource": str(protocol),
                "protocolSha256": hashlib.sha256(
                    protocol.read_bytes()
                ).hexdigest(),
                "inventorySource": str(feature_inventory),
                "inventorySha256": hashlib.sha256(
                    feature_inventory.read_bytes()
                ).hexdigest(),
                "featureCount": 1,
                "officialMappedTypeCount": 1,
                "officialMethodCount": 1,
                "productionFileCount": 1,
                "testFileCount": 1,
                "classificationCounts": {"inventory-matched": 1},
                "features": [
                    {
                        "id": "fixture.feature",
                        "classification": "inventory-matched",
                    }
                ],
            },
        )
        return {
            "root": root,
            "renderer": renderer,
            "recovered_index": recovered_index,
            "evidence": evidence_path,
            "ui": version_root / "desktop-ui-parity.json",
            "interaction": (
                version_root / "desktop-interaction-inventory.json"
            ),
            "feature": version_root / "feature-inventory.json",
            "coverage": version_root / "feature-coverage-audit.json",
        }

    def _verify(self, root: Path) -> dict[str, object]:
        return verify_release(
            root,
            desktop_version=self.VERSION,
            desktop_build=self.BUILD,
            expected_dmg_sha256=self.DMG_SHA256,
            output_path=root / "artifacts/parity-release-verified.json",
        )

    def test_matching_release_identity_surface_ui_and_features_pass(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self._seed_release(root)

            result = self._verify(root)

            self.assertEqual(result["status"], "passed")
            self.assertEqual(result["surfaceCount"], 10)
            self.assertGreater(result["evidenceFileCount"], 0)
            self.assertEqual(
                json.loads(
                    (
                        root / "artifacts/parity-release-verified.json"
                    ).read_text(encoding="utf-8")
                ),
                result,
            )

    def test_any_ui_or_feature_blocker_stops_release(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            paths = self._seed_release(root)
            ui = json.loads(Path(paths["ui"]).read_text(encoding="utf-8"))
            ui["surfaces"][0]["implementationStatus"] = "unmatched"
            ui["summary"]["implementationMatched"] -= 1
            ui["summary"]["implementationUnmatched"] += 1
            self._write_json(Path(paths["ui"]), ui)

            with self.assertRaisesRegex(ValueError, "UI parity blockers"):
                self._verify(root)

        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            paths = self._seed_release(root)
            feature = json.loads(
                Path(paths["feature"]).read_text(encoding="utf-8")
            )
            feature["features"][0]["status"] = "unknown"
            self._write_json(Path(paths["feature"]), feature)

            with self.assertRaisesRegex(ValueError, "feature parity blockers"):
                self._verify(root)

    def test_feature_coverage_gap_or_identity_tamper_stops_release(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            paths = self._seed_release(root)
            coverage_path = Path(paths["coverage"])
            coverage = json.loads(
                coverage_path.read_text(encoding="utf-8")
            )
            coverage["classificationCounts"] = {"not-implemented": 1}
            coverage["features"][0]["classification"] = "not-implemented"
            self._write_json(coverage_path, coverage)

            with self.assertRaisesRegex(ValueError, "coverage blockers"):
                self._verify(root)

        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            paths = self._seed_release(root)
            coverage_path = Path(paths["coverage"])
            coverage = json.loads(
                coverage_path.read_text(encoding="utf-8")
            )
            coverage["inventorySha256"] = "0" * 64
            self._write_json(coverage_path, coverage)

            with self.assertRaisesRegex(ValueError, "inventory hash"):
                self._verify(root)

    def test_renderer_recovered_source_or_evidence_tamper_stops_release(self):
        cases = (
            ("renderer", "resource tree"),
            ("recovered_index", "recovered source index hash"),
            ("evidence", "evidence hash mismatch"),
        )
        for key, expected_error in cases:
            with self.subTest(key=key), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                paths = self._seed_release(root)
                target = Path(paths[key])
                if target.is_dir():
                    target = target / "index.html"
                target.write_text("tampered\n", encoding="utf-8")

                with self.assertRaisesRegex(ValueError, expected_error):
                    self._verify(root)

    def test_interaction_inventory_is_required_and_bound_to_official_sources(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            paths = self._seed_release(root)
            Path(paths["interaction"]).unlink()

            with self.assertRaisesRegex(
                ValueError,
                "desktop interaction inventory",
            ):
                self._verify(root)

        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            paths = self._seed_release(root)
            inventory_path = Path(paths["interaction"])
            inventory = json.loads(inventory_path.read_text(encoding="utf-8"))
            inventory["surfaces"][0]["sourceFiles"][0]["sha256"] = "0" * 64
            self._write_json(inventory_path, inventory)

            with self.assertRaisesRegex(
                ValueError,
                "desktop interaction inventory.*hash",
            ):
                self._verify(root)

    def test_identity_or_summary_tamper_stops_release(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            paths = self._seed_release(root)
            ui = json.loads(Path(paths["ui"]).read_text(encoding="utf-8"))
            ui["sourceIdentity"]["dmgSha256"] = "d" * 64
            self._write_json(Path(paths["ui"]), ui)
            with self.assertRaisesRegex(ValueError, "source identity"):
                self._verify(root)

        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            paths = self._seed_release(root)
            ui = json.loads(Path(paths["ui"]).read_text(encoding="utf-8"))
            malformed = copy.deepcopy(ui)
            malformed["summary"]["surfaceCount"] = 0
            self._write_json(Path(paths["ui"]), malformed)
            with self.assertRaisesRegex(ValueError, "summary"):
                self._verify(root)


if __name__ == "__main__":
    unittest.main()
