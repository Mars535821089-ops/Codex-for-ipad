from __future__ import annotations

import hashlib
import json
from pathlib import Path
import tempfile
import unittest

from scripts.ipad_verification_evidence import (
    invalidate_xcui_evidence,
    record_xcui_evidence,
)


class IPadVerificationEvidenceTests(unittest.TestCase):
    @staticmethod
    def _write_json(path: Path, value: dict[str, object]) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(
            json.dumps(value, ensure_ascii=False, indent=2) + "\n",
            encoding="utf-8",
        )

    def test_invalidate_removes_only_stale_xcui_evidence(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            record_path = Path(temporary) / "ipad-verified.json"
            preserved = {
                "desktopVersion": "26.803.81509",
                "desktopBuild": "6415",
                "deviceValidation": {"status": "passed"},
                "xcuiTests": "passed",
                "xcuiTestCount": 1,
                "xcuiEvidence": {"result": "Passed"},
            }
            self._write_json(record_path, preserved)

            invalidate_xcui_evidence(record_path)

            record = json.loads(record_path.read_text(encoding="utf-8"))
            self.assertEqual(
                record,
                {
                    "desktopVersion": "26.803.81509",
                    "desktopBuild": "6415",
                    "deviceValidation": {"status": "passed"},
                },
            )

    def test_record_binds_passed_summary_to_current_sources_and_logs(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            record_path = root / "artifacts/ipad-verified.json"
            summary_path = root / "xcresult-summary.json"
            xcresult_path = root / "CodexPadUITests.xcresult"
            xcresult_path.mkdir()
            (xcresult_path / "Info.plist").write_bytes(b"xcresult fixture\n")
            contract_path = root / "versions/desktop-ui-parity.json"
            contract_path.parent.mkdir(parents=True)
            contract_path.write_bytes(b'{"contract":"fixture"}\n')
            log_path = root / "VerificationLogs/xcui-test.log"
            log_path.parent.mkdir(parents=True)
            log_path.write_bytes(b"** TEST SUCCEEDED **\n")
            self._write_json(
                summary_path,
                {
                    "result": "Passed",
                    "totalTestCount": 3,
                    "passedTests": 3,
                    "failedTests": 0,
                    "skippedTests": 0,
                    "expectedFailures": 0,
                    "startTime": 1_786_563_297.054,
                    "finishTime": 1_786_563_368.149,
                },
            )
            self._write_json(
                record_path,
                {
                    "desktopVersion": "26.803.81509",
                    "desktopBuild": "6415",
                    "deviceValidation": {"status": "passed"},
                },
            )

            evidence = record_xcui_evidence(
                record_path,
                project_root=root,
                summary_path=summary_path,
                xcresult_path=xcresult_path,
                source_head="8" * 40,
                contract_path=contract_path,
                logs={"xcui": log_path},
                verified_at="2026-08-13T06:00:00Z",
            )

            record = json.loads(record_path.read_text(encoding="utf-8"))
            self.assertEqual(record["deviceValidation"], {"status": "passed"})
            self.assertEqual(record["xcuiTests"], "passed")
            self.assertEqual(record["xcuiTestCount"], 3)
            self.assertEqual(record["xcuiEvidence"], evidence)
            self.assertEqual(
                evidence,
                {
                    "result": "Passed",
                    "totalTestCount": 3,
                    "passedTests": 3,
                    "failedTests": 0,
                    "skippedTests": 0,
                    "expectedFailures": 0,
                    "startTime": 1_786_563_297.054,
                    "finishTime": 1_786_563_368.149,
                    "generatedAt": "2026-08-13T06:00:00Z",
                    "gitHead": "8" * 40,
                    "parityContract": {
                        "path": "versions/desktop-ui-parity.json",
                        "sha256": hashlib.sha256(
                            contract_path.read_bytes()
                        ).hexdigest(),
                    },
                    "summary": {
                        "path": "xcresult-summary.json",
                        "sha256": hashlib.sha256(
                            summary_path.read_bytes()
                        ).hexdigest(),
                    },
                    "xcresult": {
                        "path": "CodexPadUITests.xcresult",
                        "sha256": self._tree_sha256(xcresult_path),
                        "hashAlgorithm": "sha256-xcresult-tree-v1",
                    },
                    "logs": {
                        "xcui": {
                            "path": "VerificationLogs/xcui-test.log",
                            "sha256": hashlib.sha256(
                                log_path.read_bytes()
                            ).hexdigest(),
                        }
                    },
                },
            )

    def test_record_rejects_zero_tests_or_failed_summary(self) -> None:
        invalid_summaries = (
            {
                "result": "Passed",
                "totalTestCount": 0,
                "passedTests": 0,
                "failedTests": 0,
                "skippedTests": 0,
                "expectedFailures": 0,
                "startTime": 1.0,
                "finishTime": 2.0,
            },
            {
                "result": "Failed",
                "totalTestCount": 1,
                "passedTests": 0,
                "failedTests": 1,
                "skippedTests": 0,
                "expectedFailures": 0,
                "startTime": 1.0,
                "finishTime": 2.0,
            },
            {
                "result": "Passed",
                "totalTestCount": 1,
                "passedTests": 0,
                "failedTests": 0,
                "skippedTests": 1,
                "expectedFailures": 0,
                "startTime": 1.0,
                "finishTime": 2.0,
            },
            {
                "result": "Passed",
                "totalTestCount": 1,
                "passedTests": 1,
                "failedTests": 0,
                "skippedTests": 0,
                "expectedFailures": 1,
                "startTime": 1.0,
                "finishTime": 2.0,
            },
            {
                "result": "Passed",
                "totalTestCount": 2,
                "passedTests": 1,
                "failedTests": 0,
                "skippedTests": 0,
                "expectedFailures": 0,
                "startTime": 1.0,
                "finishTime": 2.0,
            },
            {
                "result": "Passed",
                "totalTestCount": 1,
                "passedTests": 1,
                "failedTests": 0,
                "skippedTests": 0,
                "expectedFailures": 0,
                "startTime": float("nan"),
                "finishTime": 2.0,
            },
            {
                "result": "Passed",
                "totalTestCount": 1,
                "passedTests": 1,
                "failedTests": 0,
                "skippedTests": 0,
                "expectedFailures": 0,
                "startTime": 1.0,
                "finishTime": float("inf"),
            },
        )
        for summary in invalid_summaries:
            with (
                self.subTest(summary=summary),
                tempfile.TemporaryDirectory() as temporary,
            ):
                root = Path(temporary)
                record_path = root / "ipad-verified.json"
                summary_path = root / "summary.json"
                xcresult_path = root / "result.xcresult"
                xcresult_path.mkdir()
                (xcresult_path / "Info.plist").write_bytes(b"fixture\n")
                contract_path = root / "contract.json"
                contract_path.write_bytes(b"{}\n")
                log_path = root / "xcui.log"
                log_path.write_bytes(b"fixture\n")
                self._write_json(summary_path, summary)
                self._write_json(
                    record_path,
                    {
                        "deviceValidation": {"status": "passed"},
                    },
                )

                with self.assertRaisesRegex(ValueError, "XCResult summary"):
                    record_xcui_evidence(
                        record_path,
                        project_root=root,
                        summary_path=summary_path,
                        xcresult_path=xcresult_path,
                        source_head="8" * 40,
                        contract_path=contract_path,
                        logs={"xcui": log_path},
                        verified_at="2026-08-13T06:00:00Z",
                    )

                self.assertNotIn(
                    "xcuiTests",
                    json.loads(record_path.read_text(encoding="utf-8")),
                )

    def test_record_failure_does_not_restore_passed_evidence(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            record_path = root / "ipad-verified.json"
            summary_path = root / "summary.json"
            xcresult_path = root / "result.xcresult"
            xcresult_path.mkdir()
            (xcresult_path / "Info.plist").write_bytes(b"fixture\n")
            contract_path = root / "contract.json"
            contract_path.write_bytes(b"{}\n")
            missing_log = root / "missing.log"
            self._write_json(
                summary_path,
                {
                    "result": "Passed",
                    "totalTestCount": 1,
                    "passedTests": 1,
                    "failedTests": 0,
                    "skippedTests": 0,
                    "expectedFailures": 0,
                    "startTime": 1.0,
                    "finishTime": 2.0,
                },
            )
            self._write_json(
                record_path,
                {
                    "desktopVersion": "26.803.81509",
                    "deviceValidation": {"status": "passed"},
                },
            )

            with self.assertRaisesRegex(
                ValueError,
                "verification evidence is missing",
            ):
                record_xcui_evidence(
                    record_path,
                    project_root=root,
                    summary_path=summary_path,
                    xcresult_path=xcresult_path,
                    source_head="8" * 40,
                    contract_path=contract_path,
                    logs={"xcui": missing_log},
                    verified_at="2026-08-13T06:00:00Z",
                )

            record = json.loads(record_path.read_text(encoding="utf-8"))
            self.assertNotIn("xcuiTests", record)
            self.assertNotIn("xcuiTestCount", record)
            self.assertNotIn("xcuiEvidence", record)

    def test_record_rejects_an_empty_xcresult_bundle(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            record_path = root / "ipad-verified.json"
            summary_path = root / "summary.json"
            xcresult_path = root / "result.xcresult"
            xcresult_path.mkdir()
            contract_path = root / "contract.json"
            contract_path.write_bytes(b"{}\n")
            log_path = root / "xcui.log"
            log_path.write_bytes(b"fixture\n")
            self._write_json(
                summary_path,
                {
                    "result": "Passed",
                    "totalTestCount": 1,
                    "passedTests": 1,
                    "failedTests": 0,
                    "skippedTests": 0,
                    "expectedFailures": 0,
                    "startTime": 1.0,
                    "finishTime": 2.0,
                },
            )

            with self.assertRaisesRegex(ValueError, "contains no files"):
                record_xcui_evidence(
                    record_path,
                    project_root=root,
                    summary_path=summary_path,
                    xcresult_path=xcresult_path,
                    source_head="8" * 40,
                    contract_path=contract_path,
                    logs={"xcui": log_path},
                    verified_at="2026-08-13T06:00:00Z",
                )

            self.assertFalse(record_path.exists())

    @staticmethod
    def _tree_sha256(root: Path) -> str:
        digest = hashlib.sha256()
        for path in sorted(root.rglob("*"), key=lambda item: item.as_posix()):
            relative = path.relative_to(root).as_posix()
            if path.is_dir():
                digest.update(b"D\0")
                digest.update(relative.encode())
                digest.update(b"\0")
            elif path.is_file():
                digest.update(b"F\0")
                digest.update(relative.encode())
                digest.update(b"\0")
                digest.update(path.read_bytes())
                digest.update(b"\0")
        return digest.hexdigest()


if __name__ == "__main__":
    unittest.main()
