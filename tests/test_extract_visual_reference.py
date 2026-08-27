import unittest
from pathlib import Path

from scripts.extract_visual_reference import extract_visual_reference


class ExtractVisualReferenceTests(unittest.TestCase):
    def test_visual_tokens_and_entry_assets_keep_provenance(self):
        result = extract_visual_reference(
            Path("tests/fixtures/electron-mini/webview"), "test"
        )
        tokens = {item["name"]: item["value"] for item in result["cssTokens"]}
        self.assertEqual(tokens["--background"], "#ffffff")
        self.assertEqual(tokens["--sidebar-width"], "260px")
        self.assertEqual(result["html"]["title"], "Codex")
        self.assertEqual(result["html"]["moduleEntries"], ["assets/index-A.js"])
        font = next(
            item for item in result["resources"] if item["kind"] == "font"
        )
        self.assertEqual(font["path"], "assets/codex.woff2")
        self.assertTrue(font["sha256"])

    def test_conflicting_token_values_are_reported(self):
        result = extract_visual_reference(
            Path("tests/fixtures/electron-mini/webview"), "test"
        )
        self.assertEqual(result["tokenConflicts"], [])


if __name__ == "__main__":
    unittest.main()
