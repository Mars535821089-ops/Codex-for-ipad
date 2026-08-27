import importlib.util
import json
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).parents[1]
MODULE_PATH = ROOT / "scripts" / "official_source_cache.py"


def load_module():
    spec = importlib.util.spec_from_file_location(
        "official_source_cache",
        MODULE_PATH,
    )
    if spec is None or spec.loader is None:
        raise RuntimeError("official source cache module could not be loaded")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class OfficialSourceCacheTests(unittest.TestCase):
    def setUp(self) -> None:
        self.module = load_module()

    def test_write_then_verify_pins_commit_archive_and_tree(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "source"
            (root / "codex-rs").mkdir(parents=True)
            (root / "codex-rs/Cargo.toml").write_text(
                "[workspace]\n",
                encoding="utf-8",
            )
            record = self.module.write_manifest(
                root,
                "rust-v1.2.3",
                "a" * 40,
                "b" * 64,
            )

            verified = self.module.verify_manifest(
                root,
                "rust-v1.2.3",
                "a" * 40,
            )

            self.assertEqual(verified, record)
            self.assertEqual(len(record["treeSha256"]), 64)
            self.assertEqual(record["sourceArchiveSha256"], "b" * 64)

    def test_verify_rejects_changed_cached_source_tree(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "source"
            root.mkdir()
            source = root / "source.rs"
            source.write_text("old\n", encoding="utf-8")
            self.module.write_manifest(
                root,
                "rust-v1.2.3",
                "a" * 40,
                "b" * 64,
            )
            source.write_text("tampered\n", encoding="utf-8")

            with self.assertRaisesRegex(ValueError, "tree SHA-256 mismatch"):
                self.module.verify_manifest(
                    root,
                    "rust-v1.2.3",
                    "a" * 40,
                )

    def test_verify_rejects_changed_official_commit(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "source"
            root.mkdir()
            (root / "source.rs").write_text("source\n", encoding="utf-8")
            self.module.write_manifest(
                root,
                "rust-v1.2.3",
                "a" * 40,
                "b" * 64,
            )

            with self.assertRaisesRegex(ValueError, "identity differs"):
                self.module.verify_manifest(
                    root,
                    "rust-v1.2.3",
                    "c" * 40,
                )

    def test_manifest_file_is_excluded_from_tree_digest(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "source"
            root.mkdir()
            (root / "source.rs").write_text("source\n", encoding="utf-8")
            record = self.module.write_manifest(
                root,
                "rust-v1.2.3",
                "a" * 40,
                "b" * 64,
            )
            manifest = root / self.module.MANIFEST_NAME
            value = json.loads(manifest.read_text(encoding="utf-8"))
            value["localNote"] = "ignored manifest metadata"
            manifest.write_text(json.dumps(value), encoding="utf-8")

            self.assertEqual(
                self.module.tree_sha256(root),
                record["treeSha256"],
            )


if __name__ == "__main__":
    unittest.main()
