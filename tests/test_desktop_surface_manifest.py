import tempfile
import unittest
from pathlib import Path

from scripts.build_desktop_surface_manifest import (
    REQUIRED_BRIDGE_MEMBERS,
    build_desktop_surface_manifest,
    verify_desktop_surface_manifest,
)


class DesktopSurfaceManifestTests(unittest.TestCase):
    def _fixture(self, root: Path) -> tuple[Path, Path]:
        webview = root / "app-asar/webview"
        assets = webview / "assets"
        assets.mkdir(parents=True)
        (webview / "index.html").write_text(
            """
            <html>
              <head>
                <title>Codex</title>
                <link rel="stylesheet" href="./assets/app.css">
                <link rel="modulepreload" href="./assets/preload.js">
              </head>
              <body>
                <script type="module" src="./assets/index.js"></script>
              </body>
            </html>
            """,
            encoding="utf-8",
        )
        (assets / "app.css").write_text(
            ":root { --height-toolbar: 46px; }\n",
            encoding="utf-8",
        )
        (assets / "index.js").write_text(
            "window.__codexSurfaceLoaded = true;\n",
            encoding="utf-8",
        )
        (assets / "preload.js").write_text(
            "export const loaded = true;\n",
            encoding="utf-8",
        )
        preload = root / "recovered-electron-source/.vite/build/preload.js"
        preload.parent.mkdir(parents=True)
        preload.write_text(
            "\n".join(
                f"bridge.{member} = true;"
                for member in REQUIRED_BRIDGE_MEMBERS
            ),
            encoding="utf-8",
        )
        return webview, preload

    def test_manifest_pins_complete_tree_entrypoints_and_bridge_shape(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            webview, preload = self._fixture(root)

            manifest = build_desktop_surface_manifest(
                webview,
                preload,
                desktop_version="99.7.1",
                desktop_build="7001",
            )

            self.assertEqual(manifest["desktopVersion"], "99.7.1")
            self.assertEqual(manifest["desktopBuild"], "7001")
            self.assertEqual(manifest["resourceFileCount"], 4)
            self.assertGreater(manifest["resourceTotalBytes"], 0)
            self.assertEqual(len(manifest["resourceTreeSha256"]), 64)
            self.assertEqual(
                manifest["entry"]["moduleEntries"],
                ["assets/index.js"],
            )
            self.assertEqual(
                manifest["entry"]["stylesheets"],
                ["assets/app.css"],
            )
            self.assertEqual(
                manifest["preloadProtocol"]["bridgeMembers"],
                list(REQUIRED_BRIDGE_MEMBERS),
            )
            self.assertEqual(
                verify_desktop_surface_manifest(manifest, webview, preload),
                [],
            )

    def test_verifier_detects_any_resource_drift(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            webview, preload = self._fixture(root)
            manifest = build_desktop_surface_manifest(
                webview,
                preload,
                desktop_version="99.7.1",
                desktop_build="7001",
            )
            (webview / "assets/index.js").write_text(
                "window.__codexSurfaceLoaded = false;\n",
                encoding="utf-8",
            )

            blockers = verify_desktop_surface_manifest(
                manifest,
                webview,
                preload,
            )

            self.assertIn("resource tree hash mismatch", blockers)


if __name__ == "__main__":
    unittest.main()
