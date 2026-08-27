import json
import tempfile
import unittest
from pathlib import Path

from scripts.canonicalize_json import canonicalize_tree


class CanonicalizeJsonTests(unittest.TestCase):
    def test_object_order_is_stable_and_array_order_is_preserved(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            target = root / "schema.json"
            target.write_text(
                '{"definitions":{"z":{"type":"string"},"a":{"type":"number"}},"required":["z","a"]}',
                encoding="utf-8",
            )

            canonicalize_tree(root)

            parsed = json.loads(target.read_text(encoding="utf-8"))
            self.assertEqual(list(parsed["definitions"]), ["a", "z"])
            self.assertEqual(parsed["required"], ["z", "a"])
            self.assertTrue(target.read_text(encoding="utf-8").endswith("\n"))

    def test_invalid_json_fails_without_overwriting_source(self):
        with tempfile.TemporaryDirectory() as tmp:
            target = Path(tmp) / "broken.json"
            original = '{"broken":'
            target.write_text(original, encoding="utf-8")

            with self.assertRaises(json.JSONDecodeError):
                canonicalize_tree(Path(tmp))

            self.assertEqual(target.read_text(encoding="utf-8"), original)
