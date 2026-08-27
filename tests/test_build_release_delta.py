import json
import tempfile
import unittest
from pathlib import Path

from scripts.build_release_delta import (
    build_release_delta,
    compare_bundle_content,
    compare_feature_inventories,
    stable_bundle_key,
)


class BuildReleaseDeltaTests(unittest.TestCase):
    def test_provenance_only_feature_change_is_not_semantic(self):
        old = {
            "featureCount": 1,
            "features": [
                {
                    "id": "thread.read-params",
                    "status": "matched",
                    "ipadModule": "CodexCore",
                    "evidenceProvenance": {
                        "kind": "identical-desktop-protocol",
                        "sourceVersion": "1.0",
                    },
                }
            ],
        }
        new = json.loads(json.dumps(old))
        new["features"][0]["evidenceProvenance"]["sourceVersion"] = "1.1"

        result = compare_feature_inventories(old, new)

        self.assertEqual(result["semanticChanged"], [])
        self.assertEqual(
            [item["id"] for item in result["provenanceOnlyChanged"]],
            ["thread.read-params"],
        )

    def test_non_provenance_feature_change_remains_semantic(self):
        old = {
            "featureCount": 1,
            "features": [{"id": "thread.read-params", "status": "unknown"}],
        }
        new = {
            "featureCount": 1,
            "features": [{"id": "thread.read-params", "status": "matched"}],
        }

        result = compare_feature_inventories(old, new)

        self.assertEqual(result["provenanceOnlyChanged"], [])
        self.assertEqual(
            [item["id"] for item in result["semanticChanged"]],
            ["thread.read-params"],
        )

    def test_vite_hash_suffix_is_removed_from_stable_bundle_key(self):
        self.assertEqual(
            stable_bundle_key("webview/assets/app-initial-BnNjcVmf.js"),
            "webview/assets/app-initial.js",
        )
        self.assertEqual(
            stable_bundle_key(".vite/build/main-Cw5W_AF8.js"),
            ".vite/build/main.js",
        )
        self.assertEqual(
            stable_bundle_key("webview/index.html"),
            "webview/index.html",
        )
        self.assertEqual(
            stable_bundle_key("webview/assets/model-BuKF3pF12.js"),
            "webview/assets/model.js",
        )
        self.assertEqual(
            stable_bundle_key("webview/assets/visualization--nOoZ3b82.js"),
            "webview/assets/visualization.js",
        )

    def test_release_delta_normalizes_versions_builds_and_chunk_references(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            old_version_root = root / "versions/1.0"
            new_version_root = root / "versions/1.1"
            old_bundle = root / "old-asar"
            new_bundle = root / "new-asar"
            for path in (old_version_root, new_version_root, old_bundle, new_bundle):
                path.mkdir(parents=True)

            self._write_version_evidence(old_version_root, "1.0", "10")
            self._write_version_evidence(new_version_root, "1.1", "11")
            self._write_bundle(old_bundle, "1.0", "10", "OLDHASH1")
            self._write_bundle(new_bundle, "1.1", "11", "NEWHASH1")

            result = build_release_delta(
                old_version_root=old_version_root,
                new_version_root=new_version_root,
                old_bundle_root=old_bundle,
                new_bundle_root=new_bundle,
            )

            self.assertEqual(result["schemaVersion"], 3)
            self.assertEqual(result["features"]["semanticChanged"], [])
            self.assertEqual(
                len(result["features"]["provenanceOnlyChanged"]), 1
            )
            normalized = result["bundleContent"]["normalized"]
            self.assertEqual(normalized["added"], [])
            self.assertEqual(normalized["removed"], [])
            self.assertEqual(normalized["changed"], [])
            self.assertEqual(normalized["unchangedCount"], 3)

    def test_bundle_pairing_prefers_exact_path_before_content_digest(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            old_root = root / "old"
            new_root = root / "new"
            old_root.mkdir()
            new_root.mkdir()
            self._write_files(
                old_root,
                {
                    "chunk-AAAAAAAA.js": "alpha",
                    "chunk-BBBBBBBB.js": "bravo",
                },
            )
            self._write_files(
                new_root,
                {
                    "chunk-AAAAAAAA.js": "bravo",
                    "chunk-CCCCCCCC.js": "alpha",
                },
            )

            result = self._compare_bundles(old_root, new_root)

            self.assertEqual(result["unchangedCount"], 0)
            self.assertEqual(
                [(item["oldPath"], item["newPath"]) for item in result["changed"]],
                [
                    ("chunk-AAAAAAAA.js", "chunk-AAAAAAAA.js"),
                    ("chunk-BBBBBBBB.js", "chunk-CCCCCCCC.js"),
                ],
            )
            self.assertEqual(
                result["changed"][0]["pairingReason"], "exact-path"
            )
            self.assertEqual(result["changed"][0]["pairingConfidence"], "high")

    def test_bundle_pairing_keeps_indistinguishable_collision_unresolved(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            old_root = root / "old"
            new_root = root / "new"
            old_root.mkdir()
            new_root.mkdir()
            self._write_files(
                old_root,
                {
                    "chunk-AAAAAAAA.js": "old-a",
                    "chunk-BBBBBBBB.js": "old-b",
                },
            )
            self._write_files(
                new_root,
                {
                    "chunk-CCCCCCCC.js": "new-c",
                    "chunk-DDDDDDDD.js": "new-d",
                },
            )

            result = self._compare_bundles(old_root, new_root)

            self.assertEqual(result["changed"], [])
            self.assertEqual(result["added"], [])
            self.assertEqual(result["removed"], [])
            self.assertEqual(result["ambiguousChangedGroupCount"], 1)
            self.assertEqual(
                result["unresolvedAmbiguousGroups"],
                [
                    {
                        "stableKey": "chunk.js",
                        "oldPaths": ["chunk-AAAAAAAA.js", "chunk-BBBBBBBB.js"],
                        "newPaths": ["chunk-CCCCCCCC.js", "chunk-DDDDDDDD.js"],
                        "reason": "insufficient-pairing-evidence",
                    }
                ],
            )

    def test_bundle_pairing_marks_unique_stable_key_as_high_confidence(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            old_root = root / "old"
            new_root = root / "new"
            old_root.mkdir()
            new_root.mkdir()
            self._write_files(old_root, {"main-AAAAAAAA.js": "old-main"})
            self._write_files(new_root, {"main-BBBBBBBB.js": "new-main"})

            result = self._compare_bundles(old_root, new_root)

            self.assertEqual(len(result["changed"]), 1)
            self.assertEqual(result["changed"][0]["pairingReason"], "unique-stable-key")
            self.assertEqual(result["changed"][0]["pairingConfidence"], "high")
            self.assertFalse(result["changed"][0]["ambiguousStableGroup"])

    def test_bundle_pairing_uses_unique_size_only_as_medium_confidence(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            old_root = root / "old"
            new_root = root / "new"
            old_root.mkdir()
            new_root.mkdir()
            self._write_files(
                old_root,
                {
                    "chunk-AAAAAAAA.js": "aaa",
                    "chunk-BBBBBBBB.js": "bbbbb",
                },
            )
            self._write_files(
                new_root,
                {
                    "chunk-CCCCCCCC.js": "ccc",
                    "chunk-DDDDDDDD.js": "ddddd",
                },
            )

            result = self._compare_bundles(old_root, new_root)

            self.assertEqual(len(result["changed"]), 2)
            self.assertEqual(
                {item["pairingReason"] for item in result["changed"]},
                {"unique-size"},
            )
            self.assertEqual(
                {item["pairingConfidence"] for item in result["changed"]},
                {"medium"},
            )
            self.assertEqual(result["unresolvedAmbiguousGroups"], [])

    @staticmethod
    def _write_files(root: Path, files: dict[str, str]) -> None:
        for relative, content in files.items():
            path = root / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(content, encoding="utf-8")

    @staticmethod
    def _compare_bundles(old_root: Path, new_root: Path) -> dict:
        return compare_bundle_content(
            old_root,
            new_root,
            old_version="1.0",
            new_version="1.1",
            old_build="10",
            new_build="11",
        )

    @staticmethod
    def _write_version_evidence(root: Path, version: str, build: str) -> None:
        (root / "protocol").mkdir()
        (root / "electron").mkdir()
        (root / "protocol/index.json").write_text(
            json.dumps({"fileCount": 0, "files": [], "schemaVersion": 1}),
            encoding="utf-8",
        )
        (root / "electron/ipc-inventory.json").write_text(
            json.dumps(
                {
                    "channelCount": 0,
                    "channels": [],
                    "unresolvedCallCount": 0,
                    "unresolvedCalls": [],
                }
            ),
            encoding="utf-8",
        )
        (root / "feature-inventory.json").write_text(
            json.dumps(
                {
                    "featureCount": 1,
                    "features": [
                        {
                            "id": "thread.read-params",
                            "status": "matched",
                            "evidenceProvenance": {
                                "kind": "identical-desktop-protocol",
                                "sourceVersion": version,
                            },
                        }
                    ],
                }
            ),
            encoding="utf-8",
        )
        (root / "desktop-interaction-inventory.json").write_text(
            json.dumps(
                {
                    "desktopVersion": version,
                    "desktopBuild": build,
                    "summary": {"interactionCount": 0},
                    "surfaces": [],
                }
            ),
            encoding="utf-8",
        )
        (root / "desktop-surface-manifest.json").write_text(
            json.dumps(
                {
                    "desktopVersion": version,
                    "desktopBuild": build,
                    "resourceFileCount": 0,
                    "resourceTotalBytes": 0,
                    "resourceTreeSha256": version,
                    "preloadProtocol": {"sha256": "same"},
                }
            ),
            encoding="utf-8",
        )

    @staticmethod
    def _write_bundle(
        root: Path, version: str, build: str, chunk_hash: str
    ) -> None:
        (root / "webview/assets").mkdir(parents=True)
        (root / "package.json").write_text(
            json.dumps(
                {
                    "version": version,
                    "codexBuildNumber": build,
                    "main": "webview/index.html",
                }
            ),
            encoding="utf-8",
        )
        (root / "webview/index.html").write_text(
            f'<script src="./assets/app-initial-{chunk_hash}.js"></script>',
            encoding="utf-8",
        )
        (root / f"webview/assets/app-initial-{chunk_hash}.js").write_text(
            f'export const version="{version}"; export const build="{build}";',
            encoding="utf-8",
        )


if __name__ == "__main__":
    unittest.main()
