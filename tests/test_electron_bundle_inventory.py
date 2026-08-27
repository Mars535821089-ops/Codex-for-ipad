import json
import tempfile
import unittest
from pathlib import Path

from scripts.electron_bundle_inventory import build_bundle_inventory


class ElectronBundleInventoryTests(unittest.TestCase):
    def test_bundle_version_entries_and_roles(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / ".vite/build").mkdir(parents=True)
            (root / "webview/assets").mkdir(parents=True)
            (root / "package.json").write_text(
                json.dumps(
                    {
                        "version": "26.721.41059",
                        "main": ".vite/build/early-bootstrap.js",
                    }
                ),
                encoding="utf-8",
            )
            (root / ".vite/build/early-bootstrap.js").write_text(
                'import("./main-A.js");\n', encoding="utf-8"
            )
            (root / ".vite/build/preload.js").write_text(
                "bridge();\n", encoding="utf-8"
            )
            (root / "webview/index.html").write_text(
                '<script type="module" src="./assets/index-A.js"></script>',
                encoding="utf-8",
            )
            (root / "webview/assets/index-A.js").write_text(
                "render();\n", encoding="utf-8"
            )

            result = build_bundle_inventory(root, "26.721.41059")

            self.assertEqual(result["version"], "26.721.41059")
            self.assertEqual(
                [entry["path"] for entry in result["files"]],
                sorted(entry["path"] for entry in result["files"]),
            )
            roles = {entry["path"]: entry["role"] for entry in result["files"]}
            self.assertEqual(
                roles[".vite/build/early-bootstrap.js"], "electron-entry"
            )
            self.assertEqual(roles[".vite/build/preload.js"], "preload")
            self.assertEqual(roles["webview/index.html"], "renderer-html")

    def test_version_mismatch_is_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "package.json").write_text(
                json.dumps({"version": "1.0", "main": "main.js"}),
                encoding="utf-8",
            )
            (root / "main.js").write_text("", encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "version"):
                build_bundle_inventory(root, "2.0")


if __name__ == "__main__":
    unittest.main()
