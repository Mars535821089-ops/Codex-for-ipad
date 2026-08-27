from __future__ import annotations

import tempfile
from pathlib import Path
import unittest

from scripts.verify_desktop_bridge_api import verify_bridge_api


class VerifyDesktopBridgeAPITests(unittest.TestCase):
    def test_accepts_every_official_key_and_records_extra_ipad_keys(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            official = root / "preload.js"
            ipad = root / "Bridge.swift"
            official.write_text(
                """
                var B = {
                  windowType: C,
                  sendMessageFromView: async (value) => ({value}),
                };
                electron.contextBridge.exposeInMainWorld(
                  `electronBridge`,
                  B
                );
                """,
                encoding="utf-8",
            )
            ipad.write_text(
                """
                let source = #\"\"\"
                const bridge = {
                  windowType: "electron",
                  sendMessageFromView: async (value) => ({value}),
                  getPathForFile: (file) =>
                    typeof file?.__nativePath === "string"
                      ? file.__nativePath
                      : null,
                  ipadOnlyDiagnostic: () => true,
                };
                \"\"\"#
                """,
                encoding="utf-8",
            )

            result = verify_bridge_api(official, ipad)

            self.assertEqual(result["status"], "passed")
            self.assertEqual(
                result["officialAPIKeys"],
                ["windowType", "sendMessageFromView"],
            )
            self.assertEqual(
                result["extraIPadAPIKeys"],
                ["getPathForFile", "ipadOnlyDiagnostic"],
            )

    def test_rejects_an_official_api_missing_from_ipad(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            official = root / "preload.js"
            ipad = root / "Bridge.swift"
            official.write_text(
                """
                let Official = {requiredButtonRPC: () => true};
                contextBridge.exposeInMainWorld("electronBridge", Official);
                """,
                encoding="utf-8",
            )
            ipad.write_text(
                'const bridge = {differentRPC: () => true};\n',
                encoding="utf-8",
            )

            with self.assertRaisesRegex(
                ValueError,
                "requiredButtonRPC",
            ):
                verify_bridge_api(official, ipad)


if __name__ == "__main__":
    unittest.main()
