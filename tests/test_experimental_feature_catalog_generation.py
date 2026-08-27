import importlib.util
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).parents[1]
SCRIPT = ROOT / "scripts" / "generate_experimental_feature_catalog.py"


def load_module():
    spec = importlib.util.spec_from_file_location(
        "generate_experimental_feature_catalog",
        SCRIPT,
    )
    if spec is None or spec.loader is None:
        raise RuntimeError("feature catalog generator could not be loaded")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


FIXTURE = r'''
pub const FEATURES: &[FeatureSpec] = &[
    FeatureSpec {
        id: Feature::StableFixture,
        key: "stable_fixture",
        stage: Stage::Stable,
        default_enabled: true,
    },
    FeatureSpec {
        id: Feature::NetworkProxy,
        key: "network_proxy",
        stage: Stage::Experimental {
            name: "Network proxy",
            menu_description: "Use a proxy\nfor requests.",
            announcement: "New \"proxy\" support",
        },
        default_enabled: false,
    },
    FeatureSpec {
        id: Feature::WindowsOnly,
        key: "windows_only",
        stage: Stage::UnderDevelopment,
        default_enabled: cfg!(windows),
    },
    FeatureSpec {
        id: Feature::NonWindows,
        key: "non_windows",
        stage: Stage::Deprecated,
        default_enabled: !cfg!(windows),
    },
];
'''


class ExperimentalFeatureCatalogGenerationTests(unittest.TestCase):
    def setUp(self) -> None:
        self.module = load_module()

    def test_parses_nested_registry_and_renders_ipad_defaults(self) -> None:
        features = [
            self.module.parse_feature(block)
            for block in self.module.feature_blocks(FIXTURE)
        ]

        self.assertEqual(
            [feature["name"] for feature in features],
            [
                "stable_fixture",
                "network_proxy",
                "windows_only",
                "non_windows",
            ],
        )
        self.assertEqual(
            [feature["default_enabled"] for feature in features],
            [True, False, False, True],
        )
        rendered = self.module.render(features, Path("official/lib.rs"))
        self.assertIn("stage: .beta", rendered)
        self.assertIn('displayName: "Network proxy"', rendered)
        self.assertIn(
            'description: "Use a proxy\\nfor requests."',
            rendered,
        )
        self.assertIn(
            'announcement: "New \\"proxy\\" support"',
            rendered,
        )

    def test_cli_enforces_optional_expected_count(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            source = Path(temporary) / "lib.rs"
            output = Path(temporary) / "Catalog.swift"
            source.write_text(FIXTURE, encoding="utf-8")

            result = subprocess.run(
                [
                    sys.executable,
                    str(SCRIPT),
                    "--source",
                    str(source),
                    "--output",
                    str(output),
                    "--expected-count",
                    "3",
                ],
                text=True,
                capture_output=True,
                check=False,
            )

            self.assertNotEqual(result.returncode, 0)
            self.assertIn(
                "feature count changed: expected 3, found 4",
                result.stderr,
            )
            self.assertFalse(output.exists())

    def test_rejects_unknown_default_expression(self) -> None:
        invalid = FIXTURE.replace(
            "default_enabled: true,",
            "default_enabled: some_runtime_check(),",
            1,
        )

        with self.assertRaisesRegex(
            ValueError,
            "unsupported default expression for stable_fixture",
        ):
            self.module.parse_feature(
                self.module.feature_blocks(invalid)[0]
            )


if __name__ == "__main__":
    unittest.main()
