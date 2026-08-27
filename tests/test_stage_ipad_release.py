from __future__ import annotations

import hashlib
import json
import tempfile
import unittest
from pathlib import Path

from scripts.ipad_verification_evidence import _tree_sha256
from scripts.stage_ipad_release import (
    promote_stage,
    validate_stage,
    write_stage,
)


class StageReleaseTests(unittest.TestCase):
    def _fixture(self, root: Path) -> tuple[Path, Path, Path, str]:
        package = root / ".downloads" / "ChatGPT-test.dmg"
        package.parent.mkdir(parents=True)
        package.write_bytes(b"official package")
        digest = hashlib.sha256(package.read_bytes()).hexdigest()
        static = root / "artifacts" / "ipad-static-validated-26.814.41957.json"
        static.parent.mkdir(parents=True)
        static.write_text(json.dumps({
            "desktopVersion": "26.814.41957",
            "desktopBuild": "6744",
            "validationMode": "static",
            "status": "passed",
            "physicalDeviceTests": "not-run",
            "sourceIdentity": {"dmgSha256": digest},
        }) + "\n")
        stage = write_stage(root, package, static)
        return package, static, stage, digest

    def _verification(self, root: Path, digest: str, *, passed: bool = True) -> Path:
        xcresult = root / "DerivedData" / "CodexPadUITests.xcresult"
        xcresult.mkdir(parents=True)
        (xcresult / "result.txt").write_text("passed\n")
        xcui_log = root / "DerivedData" / "VerificationLogs" / "xcui-test.log"
        xcui_log.parent.mkdir(parents=True)
        xcui_log.write_text("passed\n")
        xcresult_hash = _tree_sha256(xcresult)
        log_hash = hashlib.sha256(xcui_log.read_bytes()).hexdigest()
        path = root / "artifacts" / "ipad-verified-26.814.41957.json"
        path.write_text(json.dumps({
            "desktopVersion": "26.814.41957",
            "desktopBuild": "6744",
            "physicalDeviceTests": "passed" if passed else "not-run",
            "physicalDeviceUDID": "CE819B41-CC70-58D4-82A8-D5D680DBAA62",
            "deviceArchitecture": "arm64",
            "sourceIdentity": {"dmgSha256": digest},
            "xcuiEvidence": {
                "xcresult": {"path": "DerivedData/CodexPadUITests.xcresult", "sha256": xcresult_hash},
                "logs": {"xcui": {"path": "DerivedData/VerificationLogs/xcui-test.log", "sha256": log_hash}},
            },
            "desktopSurface": {"deviceBundleVerified": True},
        }) + "\n")
        return path

    def test_staged_release_is_not_promoted_by_validation(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            _, _, stage, _ = self._fixture(root)
            record = validate_stage(root, stage)
            self.assertEqual(record["status"], "staged")
            self.assertEqual(record["physicalDeviceTests"], "not-run")

    def test_promote_requires_passed_physical_identity_and_evidence(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            _, _, stage, digest = self._fixture(root)
            verification = self._verification(root, digest)
            promoted = promote_stage(root, stage, verification)
            self.assertEqual(promoted["status"], "promoted")
            self.assertEqual(promoted["promotion"], "ready-for-archive")
            self.assertEqual(promoted["physicalDeviceTests"], "passed")
            self.assertEqual(promoted["physicalAcceptancePath"], verification.relative_to(root).as_posix())
            self.assertTrue(stage.is_file())
            self.assertEqual(json.loads(stage.read_text())["status"], "promoted")

    def test_failed_or_mismatched_physical_record_keeps_stage_unpromoted(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            _, _, stage, digest = self._fixture(root)
            verification = self._verification(root, digest, passed=False)
            with self.assertRaisesRegex(ValueError, "physical verification"):
                promote_stage(root, stage, verification)
            self.assertEqual(json.loads(stage.read_text())["status"], "staged")


if __name__ == "__main__":
    unittest.main()
