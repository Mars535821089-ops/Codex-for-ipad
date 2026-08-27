from __future__ import annotations

import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import scripts.build_desktop_interaction_inventory as inventory_module
from scripts.build_desktop_interaction_inventory import (
    build_desktop_interaction_inventory,
)
from scripts.build_desktop_ui_parity import SURFACE_DEFINITIONS


class DesktopInteractionInventoryTests(unittest.TestCase):
    def _write_surface_assets(self, root: Path) -> None:
        assets = root / "webview/assets"
        assets.mkdir(parents=True)
        for definition in SURFACE_DEFINITIONS:
            for index, pattern in enumerate(definition["evidenceGlobs"]):
                path = assets / pattern.replace("*", f"fixture-{index}")
                path.write_text(
                    "const messages=["
                    "{id:`shared.status`,defaultMessage:`Ready`,"
                    "description:`Status text`},"
                    f"{{id:`{definition['id']}.action.{index}`,"
                    f"defaultMessage:`{definition['id']} Action {index}`,"
                    "description:`Button label for the official action`},"
                    "];\n"
                    "// {id:`ignored.comment`,defaultMessage:`Ignore`,"
                    "description:`Button label hidden in a comment`}\n",
                    encoding="utf-8",
                )

    def test_indexes_official_messages_and_interactions_per_surface(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            recovered = Path(temporary)
            self._write_surface_assets(recovered)

            inventory = build_desktop_interaction_inventory(
                recovered,
                desktop_version="99.7.1",
                desktop_build="7001",
                desktop_surface_tree_sha256="a" * 64,
            )

            self.assertEqual(inventory["schemaVersion"], 1)
            self.assertEqual(inventory["desktopVersion"], "99.7.1")
            self.assertEqual(inventory["desktopBuild"], "7001")
            self.assertEqual(
                inventory["sourceIdentity"]["desktopSurfaceTreeSha256"],
                "a" * 64,
            )
            self.assertEqual(
                inventory["summary"]["surfaceCount"],
                len(SURFACE_DEFINITIONS),
            )
            self.assertEqual(
                inventory["summary"]["surfacesWithInteractions"],
                len(SURFACE_DEFINITIONS),
            )
            for row in inventory["surfaces"]:
                self.assertEqual(row["referenceStatus"], "reference-indexed")
                self.assertTrue(row["sourceFiles"])
                self.assertTrue(row["messages"])
                self.assertTrue(row["interactions"])
                self.assertTrue(
                    all(
                        item["id"] != "ignored.comment"
                        for item in row["messages"]
                    )
                )
                self.assertTrue(
                    all(item["kind"] == "button" for item in row["interactions"])
                )

    def test_missing_required_surface_asset_is_reported_truthfully(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            recovered = Path(temporary)
            self._write_surface_assets(recovered)
            missing = next(
                (recovered / "webview/assets").glob("login-route-*.js")
            )
            missing.unlink()

            inventory = build_desktop_interaction_inventory(
                recovered,
                desktop_version="99.7.1",
                desktop_build="7001",
                desktop_surface_tree_sha256="a" * 64,
            )

            s01 = next(row for row in inventory["surfaces"] if row["id"] == "S01")
            self.assertEqual(s01["referenceStatus"], "missing-reference")
            self.assertIn("login-route-*.js", s01["missingEvidenceGlobs"])

    def test_rejects_malformed_release_identity(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            recovered = Path(temporary)
            self._write_surface_assets(recovered)

            with self.assertRaisesRegex(ValueError, "desktop version"):
                build_desktop_interaction_inventory(
                    recovered,
                    desktop_version="latest",
                    desktop_build="7001",
                    desktop_surface_tree_sha256="a" * 64,
                )
            with self.assertRaisesRegex(ValueError, "surface tree hash"):
                build_desktop_interaction_inventory(
                    recovered,
                    desktop_version="99.7.1",
                    desktop_build="7001",
                    desktop_surface_tree_sha256="not-a-hash",
                )

    def test_shared_official_chunks_are_scanned_only_once(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            recovered = Path(temporary)
            self._write_surface_assets(recovered)
            unique_files = len(
                list((recovered / "webview/assets").glob("*.js"))
            )

            with patch.object(
                inventory_module,
                "_message_descriptors",
                wraps=inventory_module._message_descriptors,
            ) as scanner:
                build_desktop_interaction_inventory(
                    recovered,
                    desktop_version="99.7.1",
                    desktop_build="7001",
                    desktop_surface_tree_sha256="a" * 64,
                )

            self.assertEqual(scanner.call_count, unique_files)


if __name__ == "__main__":
    unittest.main()
