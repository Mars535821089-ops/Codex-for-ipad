import json
import tempfile
import unittest
from pathlib import Path

from scripts.protocol_manifest import (
    assert_within,
    sha256_file,
    validate_version,
    write_json_atomic,
)


class ProtocolManifestTests(unittest.TestCase):
    def test_hash_and_atomic_json_are_deterministic(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            source = root / "input.bin"
            source.write_bytes(b"codex\n")
            self.assertEqual(
                sha256_file(source),
                "243b0dc9b847e66c440dca985e10fe0ce9e29c379b018ddd5747ba8948f84cc8",
            )

            output = root / "manifest.json"
            write_json_atomic(
                output,
                {"version": "26.721.41059", "build": "5848"},
            )

            self.assertEqual(
                json.loads(output.read_text(encoding="utf-8")),
                {"build": "5848", "version": "26.721.41059"},
            )
            self.assertEqual(list(root.glob(".manifest.json.*")), [])

    def test_version_and_path_boundary(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw).resolve()
            self.assertEqual(validate_version("26.721.41059"), "26.721.41059")
            self.assertEqual(
                assert_within(root / "26.721.41059", root),
                root / "26.721.41059",
            )
            with self.assertRaises(ValueError):
                validate_version("../../outside")
            with self.assertRaises(ValueError):
                assert_within(root.parent / "outside", root)


if __name__ == "__main__":
    unittest.main()
