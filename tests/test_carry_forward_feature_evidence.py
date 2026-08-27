from __future__ import annotations

import copy
import unittest

from scripts.carry_forward_feature_evidence import (
    carry_forward_feature_evidence,
)


def feature(
    identifier: str,
    digest: str,
    *,
    status: str = "unknown",
) -> dict:
    row = {
        "id": identifier,
        "desktopEvidence": [
            {
                "channel": "stable",
                "file": f"{identifier}.json",
                "fileSha256": digest,
            }
        ],
        "ipadModule": None,
        "automatedTests": [],
        "simulatorEvidence": [],
        "deviceEvidence": [],
        "visualEvidence": [],
        "status": status,
    }
    if status == "matched":
        row.update(
            {
                "ipadModule": "CodexPadApplication",
                "automatedTests": ["FeatureTests.testRoundTrip"],
                "simulatorEvidence": [{"result": "passed"}],
                "deviceEvidence": [{"result": "passed"}],
                "visualEvidence": [{"surface": "workspace"}],
            }
        )
    return row


class CarryForwardFeatureEvidenceTests(unittest.TestCase):
    def test_carries_only_exact_protocol_identity_from_latest_prior_version(self) -> None:
        current = {
            "version": "26.3.0",
            "features": [
                feature("thread.same", "a" * 64),
                feature("thread.changed", "c" * 64),
                feature("thread.new", "d" * 64),
            ],
            "statusCounts": {"unknown": 3},
        }
        older = {
            "version": "26.1.0",
            "features": [
                feature("thread.same", "a" * 64, status="matched"),
                feature("thread.changed", "b" * 64, status="matched"),
            ],
        }
        latest = copy.deepcopy(older)
        latest["version"] = "26.2.0"
        latest["features"][0]["automatedTests"] = ["LatestTests.testSame"]

        output = carry_forward_feature_evidence(current, [older, latest])
        rows = {row["id"]: row for row in output["features"]}

        self.assertEqual(rows["thread.same"]["status"], "matched")
        self.assertEqual(
            rows["thread.same"]["automatedTests"],
            ["LatestTests.testSame"],
        )
        self.assertEqual(
            rows["thread.same"]["evidenceProvenance"],
            {
                "kind": "identical-desktop-protocol",
                "sourceVersion": "26.2.0",
            },
        )
        self.assertEqual(rows["thread.changed"]["status"], "unknown")
        self.assertEqual(rows["thread.new"]["status"], "unknown")
        self.assertEqual(
            output["statusCounts"],
            {"matched": 1, "unknown": 2},
        )
        self.assertEqual(output["carriedEvidenceCount"], 1)

    def test_rejects_matched_source_without_automated_test_evidence(self) -> None:
        current = {
            "version": "2.0",
            "features": [feature("thread.read", "a" * 64)],
        }
        source = feature("thread.read", "a" * 64, status="matched")
        source["automatedTests"] = []
        output = carry_forward_feature_evidence(
            current,
            [{"version": "1.0", "features": [source]}],
        )
        self.assertEqual(output["features"][0]["status"], "unknown")
        self.assertEqual(output["carriedEvidenceCount"], 0)


if __name__ == "__main__":
    unittest.main()
