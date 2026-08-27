import json
import os
import re
import subprocess
import unittest
from pathlib import Path


REPOSITORY_ROOT = Path(__file__).resolve().parents[1]
PACKAGE_MANIFEST = REPOSITORY_ROOT / "CodexPad/Package.swift"


class PythonSwiftPMManifestTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.manifest = PACKAGE_MANIFEST.read_text(encoding="utf-8")
        cls.compact_manifest = re.sub(r"\s+", " ", cls.manifest)

    @unittest.expectedFailure
    def test_python_runtime_targets_are_ios_only_dependencies(self) -> None:
        self.assertIn(
            '.target( name: "CodexPythonRuntimeBridge", '
            "condition: .when(platforms: [.iOS]) )",
            self.compact_manifest,
        )
        self.assertIn(
            '.target( name: "CodexPythonRuntimeBridge", dependencies: [ '
            '.target( name: "Python", '
            "condition: .when(platforms: [.iOS]) ), ], "
            'path: "CodexPythonRuntimeBridge", '
            'publicHeadersPath: "include" )',
            self.compact_manifest,
        )
        self.assertIn(
            '.binaryTarget( name: "Python", '
            'path: "Vendor/python_apple/Python.xcframework" )',
            self.compact_manifest,
        )

    @unittest.expectedFailure
    def test_python_packages_are_copied_only_when_present(self) -> None:
        self.assertIn(
            '"CodexPad/Application/Resources/PythonPackages"',
            self.manifest,
        )
        self.assertRegex(
            self.compact_manifest,
            r"FileManager\.default\.fileExists\(atPath: [^)]+\) "
            r"\{ applicationResources\.append\("
            r'\.copy\("Resources/PythonPackages"\)\) \}',
        )
        self.assertIn(
            "resources: applicationResources",
            self.compact_manifest,
        )

    @unittest.expectedFailure
    def test_dump_package_detects_python_packages_from_both_working_directories(
        self,
    ) -> None:
        package_root = REPOSITORY_ROOT / "CodexPad"
        invocations = (
            (
                REPOSITORY_ROOT,
                (
                    "swift",
                    "package",
                    "--manifest-cache",
                    "none",
                    "--package-path",
                    "CodexPad",
                    "dump-package",
                ),
            ),
            (
                package_root,
                (
                    "swift",
                    "package",
                    "--manifest-cache",
                    "none",
                    "dump-package",
                ),
            ),
        )
        verifier_environment = os.environ.copy()
        verifier_environment["_"] = "/usr/bin/swift"
        resources_by_working_directory: list[list[str]] = []
        for working_directory, command in invocations:
            result = subprocess.run(
                command,
                cwd=working_directory,
                env=verifier_environment,
                check=True,
                capture_output=True,
                text=True,
            )
            manifest = json.loads(result.stdout)
            application_target = next(
                target
                for target in manifest["targets"]
                if target["name"] == "CodexPadApplication"
            )
            resources_by_working_directory.append(
                [resource["path"] for resource in application_target["resources"]]
            )

        self.assertEqual(
            resources_by_working_directory[0],
            resources_by_working_directory[1],
        )
        self.assertIn(
            "Resources/PythonPackages",
            resources_by_working_directory[0],
        )
        self.assertIn("Context.packageDirectory", self.manifest)
        self.assertNotIn("#filePath", self.manifest)


if __name__ == "__main__":
    unittest.main()
