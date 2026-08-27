import hashlib
import importlib.util
import json
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).parents[1]
MODULE_PATH = ROOT / "scripts" / "verify_desktop_surface_bundle.py"


def load_module():
    if not MODULE_PATH.is_file():
        raise AssertionError("desktop surface bundle verifier is missing")
    spec = importlib.util.spec_from_file_location(
        "verify_desktop_surface_bundle",
        MODULE_PATH,
    )
    if spec is None or spec.loader is None:
        raise RuntimeError("desktop surface bundle verifier could not load")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class DesktopSurfaceBundleVerifierTests(unittest.TestCase):
    def setUp(self) -> None:
        self.module = load_module()

    def test_complete_bundled_tree_matches_the_imported_manifest(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "CodexDesktopSurface"
            self._write_fixture(root)

            result = self.module.verify_bundle(
                root,
                expected_version="26.721.81911",
                expected_build="5973",
            )

            self.assertEqual(result["status"], "passed")
            self.assertEqual(result["resourceFileCount"], 2)
            self.assertTrue(result["completeTreeVerified"])

    def test_tampered_bundled_resource_stops_verification(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "CodexDesktopSurface"
            self._write_fixture(root)
            (root / "assets/app.js").write_text(
                "tampered",
                encoding="utf-8",
            )

            with self.assertRaisesRegex(ValueError, "size mismatch"):
                self.module.verify_bundle(
                    root,
                    expected_version="26.721.81911",
                    expected_build="5973",
                )

    def test_manifest_is_not_counted_as_a_renderer_resource(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "CodexDesktopSurface"
            self._write_fixture(root)
            manifest_path = root / "desktop-surface-manifest.json"
            manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
            manifest["resourceFileCount"] = 3
            manifest_path.write_text(
                json.dumps(manifest),
                encoding="utf-8",
            )

            with self.assertRaisesRegex(ValueError, "file count mismatch"):
                self.module.verify_bundle(
                    root,
                    expected_version="26.721.81911",
                    expected_build="5973",
                )

    @staticmethod
    def _write_fixture(root: Path) -> None:
        (root / "assets").mkdir(parents=True)
        (root / "index.html").write_text(
            "<html>Codex</html>",
            encoding="utf-8",
        )
        (root / "assets/app.js").write_text(
            "console.log('Codex')",
            encoding="utf-8",
        )
        records = []
        total = 0
        tree = hashlib.sha256()
        for relative in ("assets/app.js", "index.html"):
            path = root / relative
            payload = path.read_bytes()
            digest = hashlib.sha256(payload).hexdigest()
            size = len(payload)
            records.append(
                {
                    "path": relative,
                    "role": (
                        "entry" if relative == "index.html" else "module-entry"
                    ),
                    "bytes": size,
                    "sha256": digest,
                }
            )
            tree.update(relative.encode())
            tree.update(b"\0")
            tree.update(str(size).encode())
            tree.update(b"\0")
            tree.update(digest.encode())
            tree.update(b"\n")
            total += size
        manifest = {
            "schemaVersion": 1,
            "desktopVersion": "26.721.81911",
            "desktopBuild": "5973",
            "productName": "Codex",
            "ipadProductName": "Codex for ipad",
            "resourceDirectoryName": "CodexDesktopSurface",
            "resourceFileCount": 2,
            "resourceTotalBytes": total,
            "resourceTreeSha256": tree.hexdigest(),
            "entry": {"path": "index.html"},
            "criticalFiles": records,
        }
        (root / "desktop-surface-manifest.json").write_text(
            json.dumps(manifest),
            encoding="utf-8",
        )
