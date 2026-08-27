import tempfile
import unittest
from pathlib import Path

from scripts.diff_protocol_versions import compare_directories


class ProtocolDiffTests(unittest.TestCase):
    def test_breaking_and_compatible_changes_are_separated(self) -> None:
        root = Path(__file__).parent / "fixtures"

        report = compare_directories(
            root / "protocol-old",
            root / "protocol-new",
        )

        breaking = {
            (item["kind"], item["path"])
            for item in report["breaking"]
        }
        compatible = {
            (item["kind"], item["path"])
            for item in report["compatible"]
        }
        self.assertIn(
            ("required_property_added", "$.workspaceId"),
            breaking,
        )
        self.assertIn(("enum_value_removed", "$.mode"), breaking)
        self.assertIn(("type_narrowed", "$.limit"), breaking)
        self.assertIn(
            ("optional_property_added", "$.cursor"),
            compatible,
        )
        self.assertTrue(report["blocked"])

    def test_schema_file_addition_and_removal_are_classified(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            old = root / "old"
            new = root / "new"
            old.mkdir()
            new.mkdir()
            (old / "Removed.json").write_text(
                '{"type":"string"}',
                encoding="utf-8",
            )
            (new / "Added.json").write_text(
                '{"type":"string"}',
                encoding="utf-8",
            )

            report = compare_directories(old, new)

            self.assertEqual(
                report["breaking"][0]["kind"],
                "schema_file_removed",
            )
            self.assertEqual(
                report["compatible"][0]["kind"],
                "schema_file_added",
            )


if __name__ == "__main__":
    unittest.main()
