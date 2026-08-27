import importlib.util
import json
import re
import sqlite3
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/import_codex_rollout.py"
FIXTURE = ROOT / "tests/fixtures/rollout-import-sanitized.jsonl"
FIRST_USER = "Review the persisted bridge.\nKeep the replay exact."
ASSISTANT = "The persisted bridge is ready."
UUID_PATTERN = re.compile(
    r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-"
    r"[0-9a-f]{4}-[0-9a-f]{12}$"
)


def load_importer():
    spec = importlib.util.spec_from_file_location(
        "import_codex_rollout", SCRIPT
    )
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


class CodexRolloutImportTests(unittest.TestCase):
    def test_bridge_links_the_vendored_libgit2_zlib_dependency(self):
        source = SCRIPT.read_text(encoding="utf-8")

        self.assertIn('"-lz",', source)

    def test_parser_maps_real_metadata_first_user_and_deterministic_ids(self):
        importer = load_importer()

        first = importer.parse_rollout(FIXTURE)
        second = importer.parse_rollout(FIXTURE)

        self.assertEqual(first.thread_id, second.thread_id)
        self.assertRegex(first.thread_id, UUID_PATTERN)
        self.assertRegex(first.workspace_id, UUID_PATTERN)
        self.assertRegex(first.turn_id, UUID_PATTERN)
        self.assertRegex(first.user_item_id, UUID_PATTERN)
        self.assertRegex(first.assistant_item_id, UUID_PATTERN)
        self.assertEqual("/Users/example/desktop-project", first.cwd)
        self.assertEqual("1.2.3", first.cli_version)
        self.assertEqual("openai", first.model_provider)
        self.assertEqual(
            1, first.source["subAgent"]["thread_spawn"]["depth"]
        )
        self.assertRegex(
            first.source["subAgent"]["thread_spawn"]["parent_thread_id"],
            UUID_PATTERN,
        )
        self.assertEqual(FIRST_USER, first.user_text)
        self.assertEqual(ASSISTANT, first.assistant_text)
        self.assertNotIn("SANITIZED_DEVELOPER_CONTEXT", first.user_text)
        self.assertNotIn("SECOND_USER_MESSAGE", first.user_text)
        self.assertEqual(1_785_373_323, first.created_at)
        self.assertEqual(1_785_373_324, first.user_timestamp)
        self.assertEqual(1_785_373_325, first.assistant_timestamp)

    def test_dry_run_prints_only_counts_and_hashes_and_creates_no_database(self):
        with tempfile.TemporaryDirectory() as directory:
            database = Path(directory) / "CodexPad.sqlite"
            result = subprocess.run(
                [
                    sys.executable,
                    str(SCRIPT),
                    "--input",
                    str(FIXTURE),
                    "--database",
                    str(database),
                    "--allow-test-fixture",
                    "--dry-run",
                ],
                cwd=ROOT,
                text=True,
                capture_output=True,
            )

            self.assertEqual(0, result.returncode, result.stderr)
            summary = json.loads(result.stdout)
            self.assertFalse(database.exists())
            self.assertEqual(8, summary["inputRecords"])
            self.assertEqual(4, summary["commandsPrepared"])
            self.assertEqual(1, summary["userMessagesMapped"])
            self.assertEqual(1, summary["assistantMessagesMapped"])
            self.assertRegex(summary["inputSha256"], r"^[0-9a-f]{64}$")
            self.assertRegex(summary["mappedIdsSha256"], r"^[0-9a-f]{64}$")
            self.assertRegex(
                summary["mappedContentSha256"], r"^[0-9a-f]{64}$"
            )
            combined = result.stdout + result.stderr
            for secret in (
                FIRST_USER,
                ASSISTANT,
                "desktop-session-not-a-uuid",
                "/Users/example/desktop-project",
            ):
                self.assertNotIn(secret, combined)

    def test_import_uses_core_ffi_and_reopens_thread_list_and_read(self):
        importer = load_importer()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            outcome = importer.import_rollout(
                input_path=FIXTURE,
                database_path=root / "CodexPad.sqlite",
                snapshot_directory=root / "MigrationSnapshots",
                allow_test_fixture=True,
                bridge_cache=root / "bridge-cache",
            )

            self.assertEqual(1, outcome.summary["threadListCount"])
            self.assertEqual(1, outcome.summary["threadReadTurnCount"])
            self.assertEqual(
                outcome.summary["persistedEvents"],
                outcome.summary["replayedEvents"],
            )
            listed = outcome.thread_list["result"]["data"]
            self.assertEqual(outcome.rollout.thread_id, listed[0]["id"])
            self.assertEqual(outcome.rollout.cwd, listed[0]["cwd"])
            self.assertEqual(
                outcome.rollout.created_at, listed[0]["createdAt"]
            )
            thread = outcome.thread_read["result"]["thread"]
            self.assertEqual(outcome.rollout.thread_id, thread["id"])
            self.assertEqual(1, len(thread["turns"]))
            items = thread["turns"][0]["items"]
            self.assertEqual("userMessage", items[0]["type"])
            self.assertEqual(
                FIRST_USER, items[0]["content"][0]["text"]
            )
            self.assertEqual("agentMessage", items[1]["type"])
            self.assertEqual(ASSISTANT, items[1]["text"])

            database = root / "CodexPad.sqlite"
            with sqlite3.connect(database) as connection:
                self.assertEqual(
                    "ok",
                    connection.execute("PRAGMA integrity_check").fetchone()[0],
                )
                self.assertEqual(
                    4,
                    connection.execute(
                        "SELECT COUNT(*) FROM event_batches"
                    ).fetchone()[0],
                )
                commands = [
                    json.loads(bytes(row[0]).decode("utf-8"))
                    for row in connection.execute(
                        "SELECT command FROM event_batches "
                        "ORDER BY first_sequence"
                    )
                ]
            self.assertEqual(
                FIRST_USER, commands[2]["userItem"]["text"]
            )
            self.assertNotIn(
                "SECOND_USER_MESSAGE",
                json.dumps(commands, ensure_ascii=False),
            )

    def test_production_cli_requires_explicit_home_sessions_selection(self):
        result = subprocess.run(
            [
                sys.executable,
                str(SCRIPT),
                "--input",
                str(FIXTURE),
                "--dry-run",
            ],
            cwd=ROOT,
            text=True,
            capture_output=True,
        )

        self.assertNotEqual(0, result.returncode)
        self.assertNotIn(FIRST_USER, result.stdout + result.stderr)

    def test_importer_contains_no_direct_sqlite_writer(self):
        source = SCRIPT.read_text(encoding="utf-8")
        self.assertNotIn("import sqlite3", source)
        self.assertNotIn("INSERT INTO", source)
        bridge_source = (
            ROOT / "scripts/codex_core_rollout_import_bridge.c"
        ).read_text(encoding="utf-8")
        self.assertNotIn("sqlite3", bridge_source)
        self.assertNotIn("INSERT INTO", bridge_source)


if __name__ == "__main__":
    unittest.main()
