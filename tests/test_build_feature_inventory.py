import unittest

from scripts.build_feature_inventory import build_feature_inventory


class BuildFeatureInventoryTests(unittest.TestCase):
    def test_protocol_groups_create_deterministic_unknown_rows(self):
        categories = [
            "Account",
            "Apps",
            "Config",
            "Environment",
            "Fs",
            "Mcp",
            "Model",
            "Plugin",
            "Process",
            "RemoteControl",
            "Review",
            "Skills",
            "Thread",
            "Turn",
            "Workspace",
        ]
        protocol = {
            "files": [
                {
                    "path": f"json-schema/stable/v2/{name}ReadParams.json",
                    "sha256": f"sha-{name}",
                }
                for name in reversed(categories)
            ]
        }
        inventory = build_feature_inventory(
            "test",
            protocol,
            {"channels": [], "evidence": []},
            {"resources": []},
        )
        features = inventory["features"]
        self.assertEqual(
            [item["id"] for item in features],
            sorted(item["id"] for item in features),
        )
        self.assertEqual(
            {item["category"] for item in features},
            {
                "account",
                "apps",
                "config",
                "environment",
                "fs",
                "mcp",
                "model",
                "plugin",
                "process",
                "remote-control",
                "review",
                "skills",
                "thread",
                "turn",
                "workspace",
            },
        )
        self.assertTrue(
            all(item["status"] == "unknown" for item in features)
        )
        self.assertTrue(all(item["desktopEvidence"] for item in features))

    def test_matching_ipc_channels_are_attached(self):
        inventory = build_feature_inventory(
            "test",
            {
                "files": [
                    {
                        "path": "json-schema/stable/v2/ThreadReadParams.json",
                        "sha256": "protocol-sha",
                    }
                ]
            },
            {
                "channels": [
                    {"channel": "thread:read", "pairing": "paired"}
                ],
                "evidence": [],
            },
            {"resources": []},
        )
        self.assertEqual(
            inventory["features"][0]["ipcDependencies"], ["thread:read"]
        )


if __name__ == "__main__":
    unittest.main()
