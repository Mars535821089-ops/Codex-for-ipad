import tempfile
import unittest
from pathlib import Path

from scripts.build_protocol_index import build_index


class ProtocolIndexTests(unittest.TestCase):
    def test_index_is_sorted_and_classified(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            (root / "typescript/stable").mkdir(parents=True)
            (root / "json-schema/experimental").mkdir(parents=True)
            (root / "typescript/stable/Thread.ts").write_text(
                "export type Thread = {};\n",
                encoding="utf-8",
            )
            (root / "json-schema/experimental/Turn.json").write_text(
                '{"type":"object"}\n',
                encoding="utf-8",
            )

            index = build_index(root)

            self.assertEqual(index["fileCount"], 2)
            self.assertEqual(
                [entry["path"] for entry in index["files"]],
                [
                    "json-schema/experimental/Turn.json",
                    "typescript/stable/Thread.ts",
                ],
            )
            self.assertEqual(index["files"][0]["kind"], "json-schema")
            self.assertEqual(index["files"][1]["channel"], "stable")

    def test_empty_or_unexpected_output_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            with self.assertRaises(ValueError):
                build_index(root)

            (root / "other/stable").mkdir(parents=True)
            (root / "other/stable/unknown.txt").write_text(
                "unexpected",
                encoding="utf-8",
            )
            with self.assertRaises(ValueError):
                build_index(root)


if __name__ == "__main__":
    unittest.main()
