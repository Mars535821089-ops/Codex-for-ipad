import unittest
from pathlib import Path
from tempfile import TemporaryDirectory

from scripts.extract_electron_ipc import extract_ipc_inventory


class ExtractElectronIpcTests(unittest.TestCase):
    def test_ipc_channels_are_paired_with_source_evidence(self):
        root = Path("tests/fixtures/electron-mini")
        inventory = extract_ipc_inventory(root, "test")
        channels = {item["channel"]: item for item in inventory["channels"]}
        self.assertEqual(channels["workspace:read"]["pairing"], "paired")
        self.assertEqual(channels["window:close"]["pairing"], "paired")
        self.assertTrue(
            all(item["fileSha256"] for item in inventory["evidence"])
        )
        self.assertTrue(
            all(item["byteOffset"] >= 0 for item in inventory["evidence"])
        )

    def test_main_only_and_client_only_are_explicit(self):
        root = Path("tests/fixtures/electron-mini")
        inventory = extract_ipc_inventory(root, "test")
        channels = {item["channel"]: item for item in inventory["channels"]}
        self.assertEqual(channels["codex"]["pairing"], "client-only")

    def test_identifier_bound_channels_are_resolved(self):
        with TemporaryDirectory() as directory:
            root = Path(directory)
            build = root / ".vite/build"
            build.mkdir(parents=True)
            (build / "main.js").write_text(
                'const channels={read:"workspace:read"};'
                "ipcMain.handle(channels.read, readWorkspace);",
                encoding="utf-8",
            )
            (build / "preload.js").write_text(
                'const readChannel="workspace:read";'
                "ipcRenderer.invoke(readChannel);",
                encoding="utf-8",
            )

            inventory = extract_ipc_inventory(root, "test")

        channels = {item["channel"]: item for item in inventory["channels"]}
        self.assertEqual(channels["workspace:read"]["pairing"], "paired")
        self.assertEqual(
            {
                item["evidenceKind"]
                for item in inventory["evidence"]
                if item["channel"] == "workspace:read"
            },
            {"static-derived-callsite"},
        )

    def test_false_binding_match_inside_string_does_not_abort_extraction(self):
        with TemporaryDirectory() as directory:
            root = Path(directory)
            build = root / ".vite/build"
            build.mkdir(parents=True)
            (build / "main.js").write_text(
                'const diagnostic="x=`unterminated";'
                'ipcMain.handle("workspace:read", readWorkspace);',
                encoding="utf-8",
            )

            inventory = extract_ipc_inventory(root, "test")

        self.assertEqual(
            [item["channel"] for item in inventory["channels"]],
            ["workspace:read"],
        )

    def test_identifier_resolution_uses_nearest_preceding_binding(self):
        with TemporaryDirectory() as directory:
            root = Path(directory)
            build = root / ".vite/build"
            build.mkdir(parents=True)
            (build / "preload.js").write_text(
                'let channel="workspace:first";'
                "ipcRenderer.invoke(channel);"
                'channel="workspace:second";'
                "ipcRenderer.invoke(channel);",
                encoding="utf-8",
            )

            inventory = extract_ipc_inventory(root, "test")

        self.assertEqual(
            [item["channel"] for item in inventory["channels"]],
            ["workspace:first", "workspace:second"],
        )

    def test_required_module_exports_resolve_minified_channel_alias(self):
        with TemporaryDirectory() as directory:
            root = Path(directory)
            build = root / ".vite/build"
            build.mkdir(parents=True)
            (build / "channels.js").write_text(
                'var xV="workspace:read";'
                'Object.defineProperty(exports,"z",'
                "{enumerable:true,get:function(){return xV}});",
                encoding="utf-8",
            )
            (build / "main.js").write_text(
                'const a=require("./channels.js");'
                "ipcMain.handle(a.z, readWorkspace);",
                encoding="utf-8",
            )
            (build / "preload.js").write_text(
                'ipcRenderer.invoke("workspace:read");',
                encoding="utf-8",
            )

            inventory = extract_ipc_inventory(root, "test")

        channels = {item["channel"]: item for item in inventory["channels"]}
        self.assertEqual(channels["workspace:read"]["pairing"], "paired")

    def test_send_sync_is_a_client_operation_for_pairing(self):
        with TemporaryDirectory() as directory:
            root = Path(directory)
            build = root / ".vite/build"
            build.mkdir(parents=True)
            (build / "main.js").write_text(
                'ipcMain.on("config:read", replyWithConfig);',
                encoding="utf-8",
            )
            (build / "preload.js").write_text(
                'ipcRenderer.sendSync("config:read");',
                encoding="utf-8",
            )

            inventory = extract_ipc_inventory(root, "test")

        channels = {item["channel"]: item for item in inventory["channels"]}
        self.assertEqual(channels["config:read"]["pairing"], "paired")
        self.assertEqual(channels["config:read"]["preloadOperations"], ["sendSync"])

    def test_post_message_is_a_client_operation_for_pairing(self):
        with TemporaryDirectory() as directory:
            root = Path(directory)
            build = root / ".vite/build"
            build.mkdir(parents=True)
            (build / "main.js").write_text(
                'ipcMain.on("host:connect", connectHost);',
                encoding="utf-8",
            )
            (build / "preload.js").write_text(
                'ipcRenderer.postMessage("host:connect", payload);',
                encoding="utf-8",
            )

            inventory = extract_ipc_inventory(root, "test")

        channels = {item["channel"]: item for item in inventory["channels"]}
        self.assertEqual(channels["host:connect"]["pairing"], "paired")
        self.assertEqual(
            channels["host:connect"]["preloadOperations"], ["postMessage"]
        )

    def test_unresolved_call_arguments_are_reported(self):
        with TemporaryDirectory() as directory:
            root = Path(directory)
            build = root / ".vite/build"
            build.mkdir(parents=True)
            (build / "preload.js").write_text(
                "ipcRenderer.invoke(makeChannel(kind), payload);",
                encoding="utf-8",
            )

            inventory = extract_ipc_inventory(root, "test")

        self.assertEqual(inventory["unresolvedCallCount"], 1)
        self.assertEqual(
            inventory["unresolvedCalls"][0]["expression"],
            "makeChannel(kind)",
        )
        self.assertEqual(
            inventory["unresolvedCalls"][0]["operation"],
            "invoke",
        )

    def test_template_channel_factory_is_recorded_as_dynamic_pattern(self):
        with TemporaryDirectory() as directory:
            root = Path(directory)
            build = root / ".vite/build"
            build.mkdir(parents=True)
            (build / "preload.js").write_text(
                "function channel(kind){"
                "return `worker:${kind}:from-view`"
                "}"
                "ipcRenderer.invoke(channel(kind), payload);",
                encoding="utf-8",
            )

            inventory = extract_ipc_inventory(root, "test")

        self.assertEqual(inventory["unresolvedCallCount"], 0)
        self.assertEqual(
            inventory["channels"][0]["channel"],
            "worker:${dynamic}:from-view",
        )
        self.assertEqual(
            inventory["evidence"][0]["evidenceKind"],
            "static-derived-pattern-callsite",
        )

    def test_bridge_global_name_may_begin_with_underscore(self):
        with TemporaryDirectory() as directory:
            root = Path(directory)
            build = root / ".vite/build"
            build.mkdir(parents=True)
            (build / "preload.js").write_text(
                'const bridgeName="__codexBridge";'
                "contextBridge.exposeInMainWorld(bridgeName, bridge);",
                encoding="utf-8",
            )

            inventory = extract_ipc_inventory(root, "test")

        self.assertEqual(inventory["unresolvedCallCount"], 0)
        self.assertEqual(inventory["channels"][0]["channel"], "__codexBridge")


if __name__ == "__main__":
    unittest.main()
