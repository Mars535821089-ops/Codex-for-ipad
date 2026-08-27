from __future__ import annotations

import importlib.util
import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest import mock


ROOT = Path(__file__).parents[1]
MODULE_PATH = ROOT / "scripts" / "sync_official_recommended_skills.py"


def load_module():
    spec = importlib.util.spec_from_file_location(
        "sync_official_recommended_skills",
        MODULE_PATH,
    )
    if spec is None or spec.loader is None:
        raise RuntimeError("recommended-skills sync module could not be loaded")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class SyncOfficialRecommendedSkillsTests(unittest.TestCase):
    def setUp(self) -> None:
        self.module = load_module()

    @staticmethod
    def _write_source(root: Path) -> Path:
        source = root / "official"
        skill = source / "skills/.curated/fixture"
        skill.mkdir(parents=True)
        (source / ".gitkeep").write_bytes(b"")
        (skill / "SKILL.md").write_text(
            "---\nname: fixture\ndescription: Fixture skill\n---\n",
            encoding="utf-8",
        )
        (skill / "scripts").mkdir()
        (skill / "scripts/run.py").write_text(
            "print('fixture')\n",
            encoding="utf-8",
        )
        return source

    @staticmethod
    def _capture(root: Path) -> dict[str, bytes]:
        return {
            path.relative_to(root).as_posix(): path.read_bytes()
            for path in root.rglob("*")
            if path.is_file()
        }

    def test_cli_replaces_stale_tree_with_exact_official_bundle(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = self._write_source(root)
            destination = root / "CodexPad/Resources/skills"
            destination.mkdir(parents=True)
            (destination / "stale.txt").write_text(
                "stale\n",
                encoding="utf-8",
            )

            result = subprocess.run(
                [
                    "python3",
                    str(MODULE_PATH),
                    "--source",
                    str(source),
                    "--destination",
                    str(destination),
                ],
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                timeout=10,
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(self._capture(destination), self._capture(source))
            self.assertFalse((destination / "stale.txt").exists())
            report = json.loads(result.stdout)
            self.assertEqual(report["fileCount"], 3)
            self.assertEqual(len(report["treeSha256"]), 64)
            self.assertEqual(report["destination"], str(destination))
            self.assertEqual(
                list(destination.parent.glob(".skills.sync.*")),
                [],
            )

    def test_missing_curated_skills_preserves_existing_destination(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "official"
            source.mkdir()
            (source / "README.md").write_text("not a skill bundle\n")
            destination = root / "destination"
            destination.mkdir()
            (destination / "old.txt").write_text("old\n")
            before = self._capture(destination)

            with self.assertRaisesRegex(ValueError, "skills/.curated"):
                self.module.synchronize(source, destination)

            self.assertEqual(self._capture(destination), before)

    def test_source_symlink_is_rejected_before_destination_replacement(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = self._write_source(root)
            external = root / "external.txt"
            external.write_text("external\n")
            os.symlink(
                external,
                source / "skills/.curated/fixture/references",
            )
            destination = root / "destination"
            destination.mkdir()
            (destination / "old.txt").write_text("old\n")
            before = self._capture(destination)

            with self.assertRaisesRegex(ValueError, "contains a symlink"):
                self.module.synchronize(source, destination)

            self.assertEqual(self._capture(destination), before)

    def test_promotion_failure_restores_previous_destination(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = self._write_source(root)
            destination = root / "destination"
            destination.mkdir()
            (destination / "old.txt").write_text("old\n")
            before = self._capture(destination)
            real_replace = self.module.os.replace
            calls = 0

            def fail_second_replace(source_path, destination_path):
                nonlocal calls
                calls += 1
                if calls == 2:
                    raise OSError("injected promotion failure")
                return real_replace(source_path, destination_path)

            with mock.patch.object(
                self.module.os,
                "replace",
                side_effect=fail_second_replace,
            ):
                with self.assertRaisesRegex(
                    OSError,
                    "injected promotion failure",
                ):
                    self.module.synchronize(source, destination)

            self.assertEqual(self._capture(destination), before)
            self.assertEqual(
                list(destination.parent.glob(".destination.sync.*")),
                [],
            )

    def test_destination_symlink_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = self._write_source(root)
            external = root / "external"
            external.mkdir()
            destination = root / "destination"
            os.symlink(external, destination)

            with self.assertRaisesRegex(ValueError, "must not be a symlink"):
                self.module.synchronize(source, destination)

            self.assertTrue(destination.is_symlink())


if __name__ == "__main__":
    unittest.main()
