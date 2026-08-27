import re
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/build_codex_core_xcframework.sh"


class BuildCodexCoreXCFrameworkTests(unittest.TestCase):
    def setUp(self):
        self.script = SCRIPT.read_text(encoding="utf-8")

    def test_builds_every_supported_ios_target_in_locked_release_mode(self):
        for target in (
            "aarch64-apple-ios",
            "aarch64-apple-ios-sim",
            "x86_64-apple-ios",
        ):
            self.assertIn(target, self.script)

        self.assertIn("cargo build", self.script)
        self.assertRegex(self.script, r"cargo build[^\\n]+--locked[^\\n]+--release")

    def test_packages_device_and_universal_simulator_slices(self):
        self.assertIn("lipo -create", self.script)
        self.assertIn("xcodebuild -create-xcframework", self.script)
        self.assertEqual(self.script.count("-headers"), 2)
        self.assertIn("Info.plist", self.script)

    def test_bundled_sqlite_matches_the_ipados_18_deployment_target(self):
        self.assertIn('IOS_DEPLOYMENT_TARGET="18.0"', self.script)
        self.assertIn(
            'IPHONEOS_DEPLOYMENT_TARGET="$IOS_DEPLOYMENT_TARGET"',
            self.script,
        )

    def test_output_and_staging_are_anchored_inside_project_build(self):
        self.assertIn('BASH_SOURCE[0]', self.script)
        self.assertIn('BUILD_ROOT="$ROOT/build"', self.script)
        self.assertIn(".codex-core-xcframework-", self.script)
        self.assertIn("CodexCore.xcframework", self.script)

        absolute_output_assignments = re.findall(
            r'^[A-Z_]+="(/[^"]+)"', self.script, flags=re.MULTILINE
        )
        self.assertEqual([], absolute_output_assignments)

    def test_final_install_uses_atomic_rename_and_has_rollback(self):
        self.assertIn("mv \"$NEW_FRAMEWORK\" \"$FINAL_FRAMEWORK\"", self.script)
        self.assertIn("PREVIOUS_FRAMEWORK", self.script)
        self.assertIn("trap ", self.script)


if __name__ == "__main__":
    unittest.main()
