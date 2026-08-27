import importlib.util
import json
import tempfile
import unittest
from pathlib import Path
from unittest import mock


ROOT = Path(__file__).parents[1]
MODULE_PATH = ROOT / "scripts" / "upgrade_transaction.py"


def load_module():
    if not MODULE_PATH.is_file():
        raise AssertionError("upgrade transaction helper is missing")
    spec = importlib.util.spec_from_file_location(
        "upgrade_transaction",
        MODULE_PATH,
    )
    if spec is None or spec.loader is None:
        raise RuntimeError("upgrade transaction module could not be loaded")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class UpgradeTransactionTests(unittest.TestCase):
    def setUp(self) -> None:
        self.module = load_module()

    def test_manifest_covers_every_apply_and_verify_mutation(self) -> None:
        version = "26.721.81911"
        expected = {
            "CodexCore/Cargo.toml",
            "CodexCore/Cargo.lock",
            "CodexCore/src/official_provider.rs",
            "CodexCore/resources/models.json",
            "CodexPad/CodexPad/Domain/CodexModelCatalog.generated.swift",
            "CodexPad/CodexPad/Domain/CodexBuildMetadata.generated.swift",
            (
                "CodexPad/CodexPad/Application/"
                "CodexExperimentalFeatureCatalog.generated.swift"
            ),
            "CodexPad/CodexPad/Application/Resources/skills",
            f"versions/{version}/model-catalog.json",
            "CodexPad/CodexPad/Resources/Assets.xcassets/AppIcon.appiconset",
            "CodexPad/CodexPad.xcodeproj/project.pbxproj",
            (
                "CodexPad/CodexPad.xcodeproj/xcshareddata/"
                "xcschemes/CodexPad.xcscheme"
            ),
            f"artifacts/app-asar-{version}",
            f"artifacts/full-reverse-{version}",
            f"artifacts/Info-{version}.plist",
            f"artifacts/entitlements-{version}.plist",
            f"artifacts/manifest-{version}.json",
            f"versions/{version}",
            "build/CodexCore.xcframework",
            f"artifacts/ipad-upgrade-{version}.json",
            f"artifacts/ipad-verified-{version}.json",
            f"artifacts/ipad-release/{version}",
            f"artifacts/parity-evidence/{version}",
            "artifacts/latest-official.json",
            "DerivedData/UpdaterVerification",
        }

        actual = {
            path.relative_to(Path("/fixture")).as_posix()
            for path, _strategy in self.module.transaction_paths(
                Path("/fixture"),
                version,
            )
        }

        self.assertEqual(actual, expected)
        self.assertFalse(
            any(
                strategy == "copy" and "full-reverse" in path.as_posix()
                for path, strategy in self.module.transaction_paths(
                    Path("/fixture"),
                    version,
                )
            ),
            "the multi-gigabyte reverse import must be renamed, never copied",
        )

    def test_version_requires_numeric_dot_separated_components(self) -> None:
        root = Path("/fixture")

        for version in ("", ".", "..", "26", "26.", ".721", "26..721", "26.721-beta"):
            with self.subTest(version=version):
                with self.assertRaisesRegex(ValueError, "desktop version"):
                    self.module.transaction_paths(root, version)

        paths = self.module.transaction_paths(root, "26.721.81911")
        self.assertTrue(paths)

    def test_restore_round_trip_preserves_existing_and_absent_paths(self) -> None:
        version = "26.721.81911"
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "project"
            transaction = root / ".update-state" / "transactions" / "tx"
            paths = self.module.transaction_paths(root, version)
            absent = {
                root / f"artifacts/ipad-upgrade-{version}.json",
                root / f"artifacts/ipad-verified-{version}.json",
            }
            directories = {
                root / f"artifacts/app-asar-{version}",
                root / f"artifacts/full-reverse-{version}",
                root / f"versions/{version}",
                root
                / "CodexPad/CodexPad/Resources/Assets.xcassets/"
                "AppIcon.appiconset",
                root / "CodexPad/CodexPad/Application/Resources/skills",
                root / "build/CodexCore.xcframework",
                root / "DerivedData/UpdaterVerification",
            }
            for index, (path, _strategy) in enumerate(paths):
                if path in absent:
                    continue
                if path in directories:
                    path.mkdir(parents=True, exist_ok=True)
                    (path / "old.txt").write_text(
                        f"old-directory-{index}\n",
                        encoding="utf-8",
                    )
                else:
                    path.parent.mkdir(parents=True, exist_ok=True)
                    path.write_text(f"old-file-{index}\n", encoding="utf-8")
            before = self._capture(paths)

            self.module.snapshot(root, version, transaction)
            for index, (path, _strategy) in enumerate(paths):
                if path.exists():
                    if path.is_dir():
                        for child in path.iterdir():
                            if child.is_file():
                                child.unlink()
                        (path / "new.txt").write_text(
                            f"new-directory-{index}\n",
                            encoding="utf-8",
                        )
                    else:
                        path.write_text(f"new-file-{index}\n", encoding="utf-8")
                else:
                    path.parent.mkdir(parents=True, exist_ok=True)
                    path.write_text(f"newly-created-{index}\n", encoding="utf-8")

            self.module.restore(root, transaction)

            self.assertEqual(self._capture(paths), before)
            self.assertFalse(transaction.exists())

    def test_recover_pending_restores_interrupted_transaction(self) -> None:
        version = "26.721.81911"
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "project"
            target = root / "CodexCore" / "Cargo.toml"
            target.parent.mkdir(parents=True)
            target.write_text("old\n", encoding="utf-8")
            transaction = root / ".update-state" / "transactions" / "tx"

            self.module.snapshot(root, version, transaction)
            target.write_text("partial-upgrade\n", encoding="utf-8")
            recovered = self.module.recover_pending(root)

            self.assertEqual(recovered, [transaction.resolve()])
            self.assertEqual(target.read_text(encoding="utf-8"), "old\n")
            self.assertFalse(transaction.exists())

    def test_recover_pending_discards_manifest_free_empty_snapshot(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "project"
            root.mkdir()
            transaction = root / ".update-state" / "transactions" / "empty"
            transaction.mkdir(parents=True)

            recovered = self.module.recover_pending(root)

            self.assertEqual(recovered, [transaction.resolve()])
            self.assertFalse(transaction.exists())

    def test_recover_pending_rejects_data_without_manifest(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "project"
            root.mkdir()
            transaction = root / ".update-state" / "transactions" / "broken"
            (transaction / "data").mkdir(parents=True)

            with self.assertRaisesRegex(ValueError, "data but no manifest"):
                self.module.recover_pending(root)

            self.assertTrue(transaction.exists())

    def test_commit_discards_snapshot_without_restoring_new_state(self) -> None:
        version = "26.721.81911"
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "project"
            transaction = root / ".update-state" / "transactions" / "tx"
            target = root / "CodexCore" / "Cargo.toml"
            target.parent.mkdir(parents=True)
            target.write_text("old\n", encoding="utf-8")

            self.module.snapshot(root, version, transaction)
            target.write_text("new\n", encoding="utf-8")
            self.module.commit(root, transaction)

            self.assertEqual(target.read_text(encoding="utf-8"), "new\n")
            self.assertFalse(transaction.exists())

    def test_commit_rejects_transaction_outside_expected_directory(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "project"
            root.mkdir()
            transaction = root / "unexpected" / "tx"
            transaction.mkdir(parents=True)
            (transaction / "manifest.json").write_text(
                "{}\n",
                encoding="utf-8",
            )

            with self.assertRaisesRegex(ValueError, "expected transaction"):
                self.module.commit(root, transaction)

            self.assertTrue(transaction.is_dir())

    def test_commit_validates_expected_entries_and_backups_before_deleting(
        self,
    ) -> None:
        version = "26.721.81911"
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "project"
            transaction = root / ".update-state" / "transactions" / "tx"
            target = root / "CodexCore" / "Cargo.toml"
            target.parent.mkdir(parents=True)
            target.write_text("old\n", encoding="utf-8")
            self.module.snapshot(root, version, transaction)

            manifest_path = transaction / "manifest.json"
            manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
            manifest["entries"].pop()
            manifest_path.write_text(
                json.dumps(manifest),
                encoding="utf-8",
            )

            with self.assertRaisesRegex(ValueError, "expected entries"):
                self.module.commit(root, transaction)

            self.assertTrue(transaction.is_dir())

        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "project"
            transaction = root / ".update-state" / "transactions" / "tx"
            target = root / "CodexCore" / "Cargo.toml"
            target.parent.mkdir(parents=True)
            target.write_text("old\n", encoding="utf-8")
            self.module.snapshot(root, version, transaction)

            manifest = json.loads(
                (transaction / "manifest.json").read_text(encoding="utf-8")
            )
            target_entry = next(
                entry
                for entry in manifest["entries"]
                if entry["relative_path"] == "CodexCore/Cargo.toml"
            )
            (transaction / target_entry["backup"]).unlink()

            with self.assertRaisesRegex(ValueError, "backup is missing"):
                self.module.commit(root, transaction)

            self.assertTrue(transaction.is_dir())

    def test_missing_backup_is_detected_before_current_state_is_removed(self) -> None:
        version = "26.721.81911"
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "project"
            transaction = root / ".update-state" / "transactions" / "tx"
            target = root / "CodexCore" / "Cargo.toml"
            target.parent.mkdir(parents=True)
            target.write_text("old\n", encoding="utf-8")
            self.module.snapshot(root, version, transaction)
            target.write_text("new\n", encoding="utf-8")
            manifest = json.loads(
                (transaction / "manifest.json").read_text(encoding="utf-8")
            )
            target_entry = next(
                entry
                for entry in manifest["entries"]
                if entry["relative_path"] == "CodexCore/Cargo.toml"
            )
            (transaction / target_entry["backup"]).unlink()

            with self.assertRaisesRegex(ValueError, "backup is missing"):
                self.module.restore(root, transaction)

            self.assertTrue(target.is_file())
            self.assertEqual(target.read_text(encoding="utf-8"), "new\n")
            self.assertTrue(transaction.exists())

    def test_restore_remains_retryable_after_a_mid_restore_move_failure(
        self,
    ) -> None:
        version = "26.721.81911"
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "project"
            transaction = root / ".update-state" / "transactions" / "tx"
            paths = self.module.transaction_paths(root, version)
            restored_directories = (
                root / "build/CodexCore.xcframework",
                root / "DerivedData/UpdaterVerification",
            )
            for index, path in enumerate(restored_directories):
                path.mkdir(parents=True)
                (path / "old.txt").write_text(
                    f"old-directory-{index}\n",
                    encoding="utf-8",
                )
            before = self._capture(paths)

            self.module.snapshot(root, version, transaction)
            for index, path in enumerate(restored_directories):
                path.mkdir(parents=True)
                (path / "new.txt").write_text(
                    f"new-directory-{index}\n",
                    encoding="utf-8",
                )

            real_move = self.module.shutil.move
            move_calls = 0

            def fail_second_move(source, destination):
                nonlocal move_calls
                move_calls += 1
                if move_calls == 2:
                    raise OSError("injected restore move failure")
                return real_move(source, destination)

            restore_failed = False
            try:
                with mock.patch.object(
                    self.module.shutil,
                    "move",
                    side_effect=fail_second_move,
                ):
                    self.module.restore(root, transaction)
            except OSError:
                restore_failed = True

            if restore_failed:
                self.module.restore(root, transaction)

            self.assertEqual(self._capture(paths), before)
            self.assertFalse(transaction.exists())

    @staticmethod
    def _capture(paths):
        captured = {}
        for path, _strategy in paths:
            if not path.exists():
                captured[path] = ("absent", None)
            elif path.is_file():
                captured[path] = ("file", path.read_bytes())
            else:
                captured[path] = (
                    "directory",
                    {
                        child.relative_to(path).as_posix(): child.read_bytes()
                        for child in path.rglob("*")
                        if child.is_file()
                    },
                )
        return captured


if __name__ == "__main__":
    unittest.main()
