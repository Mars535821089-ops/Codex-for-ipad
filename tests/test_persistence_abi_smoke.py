import sqlite3
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
CORE = ROOT / "CodexCore"
REPLAY_FIXTURE = (
    ROOT / "tests/fixtures/persistence-smoke.expected.jsonl"
).read_text(encoding="utf-8")
LEGACY_FIXTURE = (
    ROOT / "tests/fixtures/persistence-legacy-confirm.expected.txt"
).read_text(encoding="utf-8")


class PersistenceABISmokeTests(unittest.TestCase):
    def run_smoke(self, mode: str, root: Path) -> str:
        result = subprocess.run(
            [
                "cargo",
                "run",
                "--locked",
                "--quiet",
                "--example",
                "persistence_smoke",
                "--",
                mode,
                str(root),
            ],
            cwd=CORE,
            check=True,
            text=True,
            capture_output=True,
        )
        return result.stdout

    def test_public_abi_reopens_exact_events_and_continues_sequence(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.assertEqual(REPLAY_FIXTURE, self.run_smoke("replay", root))

            database = root / "CodexPad.sqlite"
            with sqlite3.connect(database) as connection:
                self.assertEqual(
                    "ok",
                    connection.execute("PRAGMA integrity_check").fetchone()[0],
                )
                self.assertEqual(
                    3,
                    connection.execute("PRAGMA user_version").fetchone()[0],
                )
                self.assertEqual(
                    5,
                    connection.execute(
                        "SELECT COUNT(*) FROM event_batches"
                    ).fetchone()[0],
                )

    def test_legacy_snapshot_survives_until_public_abi_confirmation(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            database = root / "CodexPad.sqlite"
            with sqlite3.connect(database) as connection:
                connection.execute("CREATE TABLE legacy(value TEXT)")
                connection.execute("INSERT INTO legacy VALUES('keep')")

            self.assertEqual(
                "snapshot-before-confirm=true\n",
                self.run_smoke("legacy-open", root),
            )
            snapshot = (
                root / "MigrationSnapshots/schema-0-to-3.sqlite"
            )
            self.assertTrue(snapshot.is_file())
            self.assertEqual(
                LEGACY_FIXTURE,
                self.run_smoke("legacy-confirm", root),
            )
            snapshots = root / "MigrationSnapshots"
            self.assertEqual([], list(snapshots.iterdir()))
            with sqlite3.connect(database) as connection:
                self.assertEqual(
                    None,
                    connection.execute(
                        "SELECT value FROM metadata "
                        "WHERE key = 'pending_snapshot'"
                    ).fetchone(),
                )


if __name__ == "__main__":
    unittest.main()
