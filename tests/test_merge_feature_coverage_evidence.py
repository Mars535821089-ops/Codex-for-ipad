from __future__ import annotations

import copy
import hashlib
import json
from pathlib import Path
import tempfile
import unittest


def load_merger():
    try:
        from scripts import merge_feature_coverage_evidence
    except ImportError as error:
        raise AssertionError(
            "feature coverage evidence merger is not implemented"
        ) from error
    return merge_feature_coverage_evidence


class MergeFeatureCoverageEvidenceTests(unittest.TestCase):
    def _fixture(self, root: Path) -> tuple[Path, Path, dict, dict]:
        inventory_path = root / "feature-inventory.json"
        coverage_path = root / "feature-coverage-audit.json"
        features = [
            {
                "id": "account.login-completed-notification",
                "name": "AccountLoginCompletedNotification",
                "status": "unknown",
                "ipadModule": None,
                "automatedTests": [],
                "deviceEvidence": [],
                "visualEvidence": [],
            },
            {
                "id": "thread.read-params",
                "name": "ThreadReadParams",
                "status": "matched",
                "ipadModule": "ExistingModule",
                "automatedTests": ["ExistingTests.read"],
                "deviceEvidence": [{"result": "passed"}],
                "visualEvidence": [],
            },
            {
                "id": "model.list-params",
                "name": "ModelListParams",
                "status": "unknown",
                "ipadModule": None,
                "automatedTests": [],
                "deviceEvidence": [],
                "visualEvidence": [],
            },
        ]
        inventory = {
            "schemaVersion": 1,
            "version": "26.803.81509",
            "featureCount": len(features),
            "statusCounts": {"matched": 1, "unknown": 2},
            "features": features,
        }
        inventory_path.write_text(
            json.dumps(inventory) + "\n", encoding="utf-8"
        )
        inventory_sha = hashlib.sha256(inventory_path.read_bytes()).hexdigest()
        coverage = {
            "schemaVersion": 1,
            "version": inventory["version"],
            "inventorySha256": inventory_sha,
            "featureCount": len(features),
            "features": [
                {
                    "id": features[0]["id"],
                    "classification": "implemented-and-test-referenced",
                    "protocolMethods": ["account/login/completed"],
                    "methodCoverage": [
                        {
                            "method": "account/login/completed",
                            "roles": ["notification"],
                            "productionReferences": [
                                {"file": "Application/Login.swift", "line": 41}
                            ],
                            "testReferences": [
                                {"file": "Tests/LoginTests.swift", "line": 73}
                            ],
                        }
                    ],
                },
                {
                    "id": features[1]["id"],
                    "classification": "inventory-matched",
                    "protocolMethods": ["thread/read"],
                    "methodCoverage": [],
                },
                {
                    "id": features[2]["id"],
                    "classification": "implemented-without-test-reference",
                    "protocolMethods": ["model/list"],
                    "methodCoverage": [],
                },
            ],
        }
        coverage_path.write_text(
            json.dumps(coverage) + "\n", encoding="utf-8"
        )
        return inventory_path, coverage_path, inventory, coverage

    def test_merges_static_evidence_without_claiming_runtime_parity(self) -> None:
        merger = load_merger()
        with tempfile.TemporaryDirectory() as temporary:
            _, _, inventory, coverage = self._fixture(Path(temporary))
            result = merger.merge_feature_coverage_evidence(
                inventory=inventory,
                coverage=coverage,
            )

        rows = {row["id"]: row for row in result["features"]}
        implemented = rows["account.login-completed-notification"]
        self.assertEqual(implemented["status"], "implemented-static-evidence")
        self.assertIsNone(implemented["ipadModule"])
        self.assertEqual(implemented["automatedTests"], [])
        self.assertEqual(implemented["deviceEvidence"], [])
        self.assertEqual(implemented["visualEvidence"], [])
        self.assertEqual(
            implemented["staticProtocolEvidence"],
            {
                "classification": "implemented-and-test-referenced",
                "protocolMethods": ["account/login/completed"],
                "productionReferences": [
                    {
                        "method": "account/login/completed",
                        "file": "Application/Login.swift",
                        "line": 41,
                    }
                ],
                "testReferences": [
                    {
                        "method": "account/login/completed",
                        "file": "Tests/LoginTests.swift",
                        "line": 73,
                    }
                ],
            },
        )
        self.assertEqual(rows["thread.read-params"], inventory["features"][1])
        self.assertEqual(rows["model.list-params"]["status"], "unknown")
        self.assertEqual(
            result["statusCounts"],
            {
                "implemented-static-evidence": 1,
                "matched": 1,
                "unknown": 1,
            },
        )
        self.assertEqual(result["staticEvidenceMergedCount"], 1)

    def test_rejects_coverage_for_a_different_inventory_preimage(self) -> None:
        merger = load_merger()
        with tempfile.TemporaryDirectory() as temporary:
            inventory_path, coverage_path, _, coverage = self._fixture(
                Path(temporary)
            )
            coverage["inventorySha256"] = "0" * 64
            with self.assertRaisesRegex(ValueError, "inventory hash"):
                merger.merge_feature_coverage_evidence_files(
                    inventory_path=inventory_path,
                    coverage_path=coverage_path,
                    coverage_override=coverage,
                )

    def test_rejects_missing_or_duplicate_coverage_rows(self) -> None:
        merger = load_merger()
        with tempfile.TemporaryDirectory() as temporary:
            _, _, inventory, coverage = self._fixture(Path(temporary))
            missing = copy.deepcopy(coverage)
            missing["features"].pop()
            missing["featureCount"] = len(missing["features"])
            with self.assertRaisesRegex(ValueError, "feature ids"):
                merger.merge_feature_coverage_evidence(
                    inventory=inventory,
                    coverage=missing,
                )

            duplicate = copy.deepcopy(coverage)
            duplicate["features"][-1]["id"] = duplicate["features"][0]["id"]
            with self.assertRaisesRegex(ValueError, "duplicate"):
                merger.merge_feature_coverage_evidence(
                    inventory=inventory,
                    coverage=duplicate,
                )


if __name__ == "__main__":
    unittest.main()
