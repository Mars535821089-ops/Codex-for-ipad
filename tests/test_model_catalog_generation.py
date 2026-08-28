import json
import subprocess
import tempfile
import unittest
from pathlib import Path


class ModelCatalogGenerationTests(unittest.TestCase):
    def test_complete_official_models_generate_lossless_versioned_outputs(self) -> None:
        project = Path(__file__).parents[1]
        script = project / "scripts/generate_model_catalog.py"
        fixture = {
            "models": [
                {
                    "slug": "gpt-visible",
                    "display_name": "GPT Visible",
                    "description": "Visible model.",
                    "default_reasoning_level": "low",
                    "supported_reasoning_levels": [
                        {"effort": "low", "description": "Fast"},
                        {"effort": "focused", "description": "Focused"},
                    ],
                    "input_modalities": ["text", "audio"],
                    "visibility": "list",
                    "priority": 2,
                    "availability_nux": {"message": "New model"},
                    "additional_speed_tiers": ["fast"],
                    "service_tiers": [{
                        "id": "priority",
                        "name": "Fast",
                        "description": "Higher speed",
                    }],
                    "default_service_tier": "priority",
                    "upgrade": None,
                    "supported_in_api": True,
                    "model_messages": {
                        "instructions_template": "{{ personality }}",
                        "instructions_variables": {
                            "personality_default": "Default",
                            "personality_friendly": "Friendly",
                            "personality_pragmatic": "Pragmatic",
                        },
                    },
                },
                {
                    "slug": "gpt-hidden",
                    "display_name": "GPT Hidden",
                    "description": "Hidden model.",
                    "default_reasoning_level": "medium",
                    "supported_reasoning_levels": [{
                        "effort": "medium",
                        "description": "Balanced",
                    }],
                    "input_modalities": ["text", "image"],
                    "visibility": "hide",
                    "priority": 1,
                    "availability_nux": None,
                    "additional_speed_tiers": [],
                    "service_tiers": [],
                    "default_service_tier": None,
                    "upgrade": {
                        "model": "gpt-visible",
                        "migration_markdown": "Use GPT Visible.",
                    },
                    "supported_in_api": True,
                },
            ]
        }
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "models.json"
            json_output = root / "version" / "model-catalog.json"
            rust_output = root / "CodexCore" / "resources" / "models.json"
            rust_client_version_output = (
                root / "CodexCore" / "resources" / "client-version.txt"
            )
            swift_output = root / "CodexModelCatalog.generated.swift"
            official_cargo = root / "official" / "codex-rs" / "Cargo.toml"
            source.write_text(json.dumps(fixture), encoding="utf-8")
            official_cargo.parent.mkdir(parents=True)
            official_cargo.write_text(
                '[workspace.package]\nversion = "0.999.0-alpha.7"\n',
                encoding="utf-8",
            )

            subprocess.run(
                [
                    "python3",
                    str(script),
                    "--source",
                    str(source),
                    "--version",
                    "99.1",
                    "--json-output",
                    str(json_output),
                    "--rust-json-output",
                    str(rust_output),
                    "--official-cargo-toml",
                    str(official_cargo),
                    "--rust-client-version-output",
                    str(rust_client_version_output),
                    "--swift-output",
                    str(swift_output),
                ],
                check=True,
            )

            catalog = json.loads(json_output.read_text(encoding="utf-8"))
            self.assertEqual(catalog["schemaVersion"], 2)
            self.assertEqual(catalog["desktopVersion"], "99.1")
            self.assertEqual([model["id"] for model in catalog["models"]], [
                "gpt-hidden",
                "gpt-visible",
            ])
            self.assertEqual(catalog["source"]["sha256"], (
                __import__("hashlib").sha256(source.read_bytes()).hexdigest()
            ))
            self.assertEqual(catalog["models"][0]["upgrade"], "gpt-visible")
            self.assertEqual(
                catalog["models"][0]["upgradeInfo"]["migrationMarkdown"],
                "Use GPT Visible.",
            )
            visible = catalog["models"][1]
            self.assertEqual(
                visible["supportedReasoningEfforts"][1],
                {"reasoningEffort": "focused", "description": "Focused"},
            )
            self.assertEqual(visible["inputModalities"], ["text", "audio"])
            self.assertTrue(visible["supportsPersonality"])
            self.assertEqual(visible["defaultServiceTier"], "priority")
            self.assertTrue(visible["isDefault"])
            self.assertEqual(json.loads(rust_output.read_text(encoding="utf-8")), fixture)
            self.assertEqual(
                rust_client_version_output.read_text(encoding="utf-8"),
                "0.999.0-alpha.7",
            )
            generated = swift_output.read_text(encoding="utf-8")
            self.assertIn('id: "gpt-visible"', generated)
            self.assertIn("defaultReasoningEffort: .low", generated)
            self.assertIn('rawValue: "focused"', generated)
            self.assertIn("reasoningEffortOptions:", generated)
            self.assertIn("inputModalities: [.text, .audio]", generated)
            self.assertIn("supportsPersonality: true", generated)
            self.assertIn("gpt-hidden", generated)

    def test_arbitrary_nonempty_official_effort_is_accepted(self) -> None:
        project = Path(__file__).parents[1]
        script = project / "scripts/generate_model_catalog.py"
        fixture = {
            "models": [{
                "slug": "gpt-visible",
                "display_name": "GPT Visible",
                "description": "Visible model.",
                "default_reasoning_level": "extreme",
                "supported_reasoning_levels": [{"effort": "extreme"}],
                "visibility": "list",
                "priority": 1,
            }]
        }
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "models.json"
            source.write_text(json.dumps(fixture), encoding="utf-8")
            result = subprocess.run(
                [
                    "python3",
                    str(script),
                    "--source",
                    str(source),
                    "--version",
                    "99.1",
                    "--json-output",
                    str(root / "catalog.json"),
                    "--swift-output",
                    str(root / "catalog.swift"),
                ],
                capture_output=True,
                text=True,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            generated = (root / "catalog.swift").read_text(encoding="utf-8")
            self.assertIn('rawValue: "extreme"', generated)

    def test_empty_official_effort_is_rejected(self) -> None:
        project = Path(__file__).parents[1]
        script = project / "scripts/generate_model_catalog.py"
        fixture = {
            "models": [{
                "slug": "gpt-visible",
                "display_name": "GPT Visible",
                "description": "Visible model.",
                "default_reasoning_level": "",
                "supported_reasoning_levels": [
                    {"effort": "", "description": "Invalid"},
                ],
                "visibility": "list",
                "priority": 1,
            }]
        }
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "models.json"
            source.write_text(json.dumps(fixture), encoding="utf-8")
            result = subprocess.run(
                [
                    "python3",
                    str(script),
                    "--source",
                    str(source),
                    "--version",
                    "99.1",
                    "--json-output",
                    str(root / "catalog.json"),
                    "--swift-output",
                    str(root / "catalog.swift"),
                ],
                capture_output=True,
                text=True,
            )
            self.assertNotEqual(result.returncode, 0)
