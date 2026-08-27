import json
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/extract_javascript_semantic_delta.mjs"


class JavaScriptSemanticDeltaTests(unittest.TestCase):
    def _run_delta(self, old_source: str, new_source: str) -> dict:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            old_path = root / "main-old.js"
            new_path = root / "main-new.js"
            json_path = root / "delta.json"
            markdown_path = root / "delta.md"
            old_path.write_text(old_source, encoding="utf-8")
            new_path.write_text(new_source, encoding="utf-8")
            subprocess.run(
                [
                    "node",
                    str(SCRIPT),
                    "--old",
                    str(old_path),
                    "--new",
                    str(new_path),
                    "--old-version",
                    "1.0",
                    "--new-version",
                    "1.1",
                    "--json-out",
                    str(json_path),
                    "--markdown-out",
                    str(markdown_path),
                ],
                cwd=ROOT,
                check=True,
                capture_output=True,
                text=True,
            )
            result = json.loads(json_path.read_text(encoding="utf-8"))
            result["_markdown"] = markdown_path.read_text(encoding="utf-8")
            return result

    @staticmethod
    def _values(result: dict, category: str, side: str) -> list[str]:
        return [
            item["value"]
            for item in result["semanticDelta"][category][side]
        ]

    def test_local_identifier_renames_and_equivalent_literals_are_ignored(self):
        old = r'''
            const localAlpha = "same";
            const escaped = "thread\/start";
            const fixed = `fixed-channel`;
            const dynamic = `thread/${localAlpha}`;
        '''
        new = r'''
            const localBeta = 'same';
            const escapedAgain = 'thread/start';
            const fixedAgain = `fixed-channel`;
            const dynamicAgain = `thread/${localBeta}`;
        '''

        result = self._run_delta(old, new)

        self.assertEqual(result["schemaVersion"], 1)
        self.assertEqual(result["semanticDelta"]["stringLiterals"]["added"], [])
        self.assertEqual(result["semanticDelta"]["stringLiterals"]["removed"], [])
        self.assertNotIn("identifiers", result["semanticDelta"])

    def test_extracts_real_strings_keys_methods_routes_operations_and_flags(self):
        old = r'''
            const api = {
              route: "thread/old",
              oldMethod() {},
              featureFlag: "legacy_feature_enabled",
              callback: "codex://old/callback",
            };
            bridge.invoke("appHost.oldOperation");
        '''
        new = r'''
            const api = {
              route: "thread/queue/start",
              newMethod() {},
              featureFlag: "thread_queue_enabled",
              callback: "codex://thread/queue",
            };
            bridge.invoke("appHost.threadQueueStart");
        '''

        result = self._run_delta(old, new)

        self.assertIn(
            "thread/queue/start", self._values(result, "routes", "added")
        )
        self.assertIn(
            "appHost.threadQueueStart",
            self._values(result, "appHostOperations", "added"),
        )
        self.assertIn(
            "codex://thread/queue",
            self._values(result, "urlSchemes", "added"),
        )
        self.assertIn(
            "thread_queue_enabled",
            self._values(result, "featureFlags", "added"),
        )
        self.assertIn(
            "newMethod", self._values(result, "methodNames", "added")
        )
        self.assertIn("route", self._values(result, "objectKeys", "unchanged"))
        self.assertNotIn(
            "featureFlag", self._values(result, "objectKeys", "added")
        )

    def test_counts_duplicate_evidence_and_emits_versioned_markdown(self):
        old = 'dispatch("thread/read"); dispatch("thread/read");'
        new = 'dispatch("thread/read"); dispatch("thread/list"); dispatch("thread/list");'

        result = self._run_delta(old, new)

        added = result["semanticDelta"]["routes"]["added"]
        removed = result["semanticDelta"]["routes"]["removed"]
        self.assertEqual(added, [{"value": "thread/list", "count": 2}])
        self.assertEqual(removed, [{"value": "thread/read", "count": 1}])
        self.assertEqual(result["oldVersion"], "1.0")
        self.assertEqual(result["newVersion"], "1.1")
        self.assertIn("# JavaScript Semantic Delta: 1.0 → 1.1", result["_markdown"])
        self.assertIn("`thread/list` (2)", result["_markdown"])


if __name__ == "__main__":
    unittest.main()
