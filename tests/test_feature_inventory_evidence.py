from __future__ import annotations

from collections import Counter
import json
from pathlib import Path
import unittest


ROOT = Path(__file__).parents[1]
VERSION = "26.721.81911"


class FeatureInventoryEvidenceTests(unittest.TestCase):
    def setUp(self) -> None:
        inventory_path = (
            ROOT
            / "versions"
            / VERSION
            / "feature-inventory.json"
        )
        if not inventory_path.is_file():
            self.skipTest(
                "official reverse-engineering evidence is not distributed "
                "in the public source repository"
            )
        self.inventory = json.loads(
            inventory_path.read_text(encoding="utf-8")
        )
        self.features = {
            feature["id"]: feature
            for feature in self.inventory["features"]
        }

    def test_status_counts_match_the_feature_rows(self) -> None:
        self.assertEqual(self.inventory["featureCount"], len(self.features))
        self.assertEqual(
            self.inventory["statusCounts"],
            dict(
                sorted(
                    Counter(
                        feature["status"]
                        for feature in self.features.values()
                    ).items()
                )
            ),
        )

    def test_verified_thread_directory_protocols_have_test_evidence(self) -> None:
        verified = {
            "thread.list-params",
            "thread.list-response",
            "thread.read-params",
            "thread.read-response",
            "thread.search-params",
            "thread.search-response",
            "thread.metadata-update-params",
            "thread.metadata-update-response",
            "thread.token-usage-updated-notification",
        }

        for feature_id in verified:
            with self.subTest(feature_id=feature_id):
                feature = self.features[feature_id]
                self.assertEqual(feature["status"], "matched")
                self.assertTrue(feature["ipadModule"])
                self.assertTrue(feature["automatedTests"])
                self.assertTrue(feature["protocolDependencies"])

    def test_resume_stays_unknown_until_all_legal_overrides_execute(self) -> None:
        self.assertEqual(
            self.features["thread.resume-params"]["status"],
            "unknown",
        )
        self.assertEqual(
            self.features["thread.resume-response"]["status"],
            "unknown",
        )

    def test_turn_diff_row_carries_its_own_automated_and_simulator_evidence(self) -> None:
        feature = self.features["turn.diff-updated-notification"]
        expected_tests = {
            "CodexAppServerTurnEnvelopeTests.notificationEnvelopeDecodesTurnDiffUpdatedSnapshot",
            "CodexPersistedTurnCoordinatorTests.persistedTurnPublishesAggregatedDiffSnapshotsAfterSuccessfulWrites",
            "CodexPersistedTurnWorkspaceToolExecutorTests.persistedWorkspaceToolExecutorExposesOnlySuccessfulWriteDiff",
            "CodexResumedTurnViewStateTests.stableTurnReplacesLatestDiffWithMatchingSnapshot",
            "TurnDiffUIContractTests",
        }

        self.assertEqual(feature["status"], "matched")
        self.assertEqual(set(feature["automatedTests"]), expected_tests)
        self.assertEqual(
            feature["ipadModule"],
            "CodexPadProtocolBridge/CodexPadApplication/CodexPadPresentation",
        )
        self.assertEqual(feature["deviceEvidence"], [])
        self.assertEqual(
            feature["simulatorEvidence"][0]["architectures"],
            ["arm64", "x86_64"],
        )
        self.assertEqual(
            self.features["account.login-completed-notification"][
                "automatedTests"
            ],
            [],
        )

    def test_device_evidence_records_launch_without_claiming_full_workflow(self) -> None:
        device_validation = json.loads(
            (
                ROOT
                / "artifacts"
                / f"ipad-device-validation-{VERSION}.json"
            ).read_text(encoding="utf-8")
        )
        self.assertEqual(
            device_validation["launch"],
            "passed",
        )
        self.assertEqual(
            device_validation["foregroundProcessSurvival"],
            "passed",
        )
        self.assertEqual(
            device_validation["visibleLaunchUI"],
            "passed",
        )
        self.assertEqual(
            device_validation["realInteraction"],
            "pending-task-workflow-validation",
        )

        encoded = json.dumps(
            [
                feature["deviceEvidence"]
                for feature in self.features.values()
            ],
            ensure_ascii=False,
        )
        self.assertIn("signed-build-install-launch-and-visible-passed", encoded)
        self.assertNotIn("full-task-workflow-passed", encoded)


if __name__ == "__main__":
    unittest.main()
