from __future__ import annotations

import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

from scripts.reverse_full_bundle import (
    build_binary_reports,
    cleanup_stale_staging,
    copy_tree,
    file_manifest,
)


def snapshot_tree(root: Path) -> list[tuple[str, str, bytes | str]]:
    snapshot: list[tuple[str, str, bytes | str]] = []
    for path in sorted(root.rglob("*")):
        relative = path.relative_to(root).as_posix()
        if path.is_symlink():
            snapshot.append((relative, "symlink", os.readlink(path)))
        elif path.is_file():
            snapshot.append((relative, "file", path.read_bytes()))
        elif path.is_dir():
            snapshot.append((relative, "directory", b""))
    return snapshot


class ReverseFullBundleTests(unittest.TestCase):
    def test_cleanup_removes_only_expired_staging_directories(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            output = root / "full-reverse-1.2.3"
            output.mkdir()
            expired = root / f".{output.name}.staging-expired"
            expired.mkdir()
            (expired / "large.bin").write_bytes(b"stale")
            fresh = root / f".{output.name}.staging-fresh"
            fresh.mkdir()
            unrelated = root / ".full-reverse-other.staging-expired"
            unrelated.mkdir()
            old = 1_000_000.0
            os.utime(expired, (old, old))
            os.utime(unrelated, (old, old))

            removed = cleanup_stale_staging(
                output,
                now=old + 7 * 60 * 60,
            )

            self.assertEqual(removed, [expired])
            self.assertFalse(expired.exists())
            self.assertTrue(fresh.is_dir())
            self.assertTrue(unrelated.is_dir())
            self.assertTrue(output.is_dir())

    def test_copy_tree_removes_destination_entries_absent_from_source(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "source"
            destination = root / "destination"
            source.mkdir()
            (source / "current.js").write_text("current\n", encoding="utf-8")
            destination.mkdir()
            (destination / "stale.js").write_text("stale\n", encoding="utf-8")

            copy_tree(source, destination)

            self.assertFalse((destination / "stale.js").exists())
            self.assertEqual(
                (destination / "current.js").read_text(encoding="utf-8"),
                "current\n",
            )

    def test_copy_tree_is_idempotent_for_relative_symlinks(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "source"
            destination = root / "destination"
            source.mkdir()
            (source / "target.js").write_text("first\n", encoding="utf-8")
            (source / "link").symlink_to("target.js")

            copy_tree(source, destination)
            (source / "target.js").write_text("second\n", encoding="utf-8")
            copy_tree(source, destination)

            self.assertTrue((destination / "link").is_symlink())
            self.assertEqual(
                (destination / "link").read_text(encoding="utf-8"),
                "second\n",
            )

    def test_file_manifest_records_hash_size_and_relative_path(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "nested").mkdir()
            (root / "nested" / "entry.js").write_text(
                "const value = 1;\n",
                encoding="utf-8",
            )

            manifest = file_manifest(root)

            self.assertEqual(len(manifest), 1)
            self.assertEqual(manifest[0]["path"], "nested/entry.js")
            self.assertEqual(manifest[0]["size"], 17)
            self.assertEqual(len(manifest[0]["sha256"]), 64)

    def test_failed_build_leaves_existing_final_output_byte_identical(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            app = root / "Official.app"
            resources = app / "Contents" / "Resources"
            resources.mkdir(parents=True)
            (resources / "theme.txt").write_text("new theme\n", encoding="utf-8")
            asar_root = root / "asar"
            (asar_root / ".vite" / "build").mkdir(parents=True)
            (asar_root / ".vite" / "build" / "main.js").write_text(
                "const fresh = true;\n",
                encoding="utf-8",
            )
            official_source = root / "official-source"
            official_source.mkdir()
            (official_source / "cli.js").write_text(
                "const cli = true;\n",
                encoding="utf-8",
            )
            output = root / "full-reverse"
            (output / "nested").mkdir(parents=True)
            (output / "sentinel.bin").write_bytes(b"\x00existing-final\xff")
            (output / "nested" / "old.txt").write_text("old\n", encoding="utf-8")
            (output / "current-link").symlink_to("sentinel.bin")
            before = snapshot_tree(output)

            fake_bin = root / "fake-bin"
            fake_bin.mkdir()
            fake_npx = fake_bin / "npx"
            fake_npx.write_text("#!/bin/sh\nexit 23\n", encoding="utf-8")
            fake_npx.chmod(0o755)
            environment = os.environ.copy()
            environment["PATH"] = f"{fake_bin}{os.pathsep}{environment['PATH']}"
            environment["PYTHONDONTWRITEBYTECODE"] = "1"

            completed = subprocess.run(
                [
                    sys.executable,
                    "scripts/reverse_full_bundle.py",
                    "--app",
                    str(app),
                    "--asar-root",
                    str(asar_root),
                    "--official-source",
                    str(official_source),
                    "--output",
                    str(output),
                    "--version",
                    "1.2.3",
                    "--build",
                    "456",
                ],
                cwd=Path(__file__).resolve().parents[1],
                env=environment,
                check=False,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )

            self.assertNotEqual(completed.returncode, 0)
            self.assertEqual(snapshot_tree(output), before)
            self.assertEqual(
                list(root.glob(f".{output.name}.staging-*")),
                [],
            )

    def test_binary_reports_do_not_embed_checkout_absolute_path(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            checkout = Path(temporary) / "checkout-root"
            resources = checkout / "resources"
            resources.mkdir(parents=True)
            executable = resources / "bin" / "fixture-tool"
            executable.parent.mkdir()
            executable.write_text(
                "#!/bin/sh\nprintf 'fixture output\\n'\n",
                encoding="utf-8",
            )
            executable.chmod(0o755)
            output = checkout / "binary-analysis"

            reports = build_binary_reports(resources, output)

            self.assertEqual(len(reports), 1)
            report_payload = str(reports[0])
            self.assertNotIn(str(checkout), report_payload)
            for report_path in output.rglob("*.txt"):
                self.assertNotIn(
                    str(checkout),
                    report_path.read_text(encoding="utf-8"),
                )


if __name__ == "__main__":
    unittest.main()
