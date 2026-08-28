import hashlib
import json
import re
import unittest
import xml.etree.ElementTree as ET
from pathlib import Path
from tempfile import TemporaryDirectory

from scripts.generate_codexpad_xcode_project import (
    _discover_swift_files,
    _identifier,
    generate_project,
)


class GenerateCodexPadProjectTests(unittest.TestCase):
    def test_checked_in_project_has_file_and_build_records_for_every_swift_source(self):
        repository_root = Path(__file__).resolve().parents[1]
        source_root = repository_root / "CodexPad/CodexPad"
        project_path = repository_root / "CodexPad/CodexPad.xcodeproj/project.pbxproj"
        project = project_path.read_text(encoding="utf-8")

        missing: list[str] = []
        for relative_path in _discover_swift_files(source_root):
            name = Path(relative_path).name
            reference_id = _identifier("PBXFileReference", relative_path)
            build_id = _identifier("PBXBuildFile", relative_path)
            if (
                f"{reference_id} /* {name} */ = {{isa = PBXFileReference;"
                not in project
                or f"{build_id} /* {name} in Sources */ = {{isa = PBXBuildFile;"
                not in project
            ):
                missing.append(relative_path)

        self.assertEqual([], missing)

    def _write_minimal_project(self, root: Path) -> Path:
        project_root = root / "CodexPad"
        (project_root / "CodexPad/App").mkdir(parents=True)
        (project_root / "CodexPad/App/CodexPadApp.swift").write_text(
            "import SwiftUI\n@main struct CodexPadApp: App {"
            'var body: some Scene { WindowGroup { Text("Codex") } }}\n',
            encoding="utf-8",
        )
        return project_root

    def _write_desktop_surface(
        self,
        root: Path,
        *,
        version: str,
        build: str,
    ) -> Path:
        version_root = root / "versions" / version
        version_root.mkdir(parents=True)
        (version_root / "manifest.json").write_text(
            json.dumps(
                {
                    "schemaVersion": 1,
                    "version": version,
                    "build": build,
                }
            )
            + "\n",
            encoding="utf-8",
        )
        webview = (
            root
            / "artifacts"
            / f"full-reverse-{version}"
            / "app-asar"
            / "webview"
        )
        webview.mkdir(parents=True)
        (webview / "index.html").write_text(
            "<!doctype html><title>Codex</title>\n",
            encoding="utf-8",
        )
        (webview / "assets").mkdir()
        (webview / "assets/app.js").write_text(
            "console.log('Codex');\n",
            encoding="utf-8",
        )
        file_count = 0
        total_bytes = 0
        tree = hashlib.sha256()
        for path in sorted(item for item in webview.rglob("*") if item.is_file()):
            relative = path.relative_to(webview).as_posix()
            payload = path.read_bytes()
            digest = hashlib.sha256(payload).hexdigest()
            size = len(payload)
            tree.update(relative.encode("utf-8"))
            tree.update(b"\0")
            tree.update(str(size).encode("ascii"))
            tree.update(b"\0")
            tree.update(digest.encode("ascii"))
            tree.update(b"\n")
            file_count += 1
            total_bytes += size
        (version_root / "desktop-surface-manifest.json").write_text(
            json.dumps(
                {
                    "schemaVersion": 1,
                    "desktopVersion": version,
                    "desktopBuild": build,
                    "resourceDirectoryName": "CodexDesktopSurface",
                    "resourceFileCount": file_count,
                    "resourceTotalBytes": total_bytes,
                    "resourceTreeSha256": tree.hexdigest(),
                }
            )
            + "\n",
            encoding="utf-8",
        )
        return webview

    def _write_ui_tests(
        self,
        project_root: Path,
        *relative_paths: str,
    ) -> None:
        ui_test_root = project_root / "Tests/CodexPadUITests"
        for relative_path in relative_paths:
            test_file = ui_test_root / relative_path
            test_file.parent.mkdir(parents=True, exist_ok=True)
            test_file.write_text(
                "import XCTest\n"
                "final class CodexPadUITests: XCTestCase {}\n",
                encoding="utf-8",
            )

    def _write_ios_system_runtime(self, project_root: Path) -> None:
        for name in ("ios_system", "files", "shell", "text"):
            framework = (
                project_root
                / "Vendor/ios_system"
                / f"{name}.xcframework"
            )
            framework.mkdir(parents=True)
            (framework / "Info.plist").write_text(
                "<?xml version=\"1.0\"?><plist version=\"1.0\"><dict/></plist>\n",
                encoding="utf-8",
            )

    def _write_node_mobile_runtime(self, project_root: Path) -> None:
        runtime_root = project_root / "Vendor/node_mobile"
        framework = runtime_root / "NodeMobile.xcframework"
        framework.mkdir(parents=True)
        (framework / "Info.plist").write_text(
            "<?xml version=\"1.0\"?><plist version=\"1.0\"><dict/></plist>\n",
            encoding="utf-8",
        )
        (runtime_root / "runtime-lock.json").write_text(
            json.dumps(
                {
                    "schemaVersion": 1,
                    "runtime": "NodeMobile",
                    "version": "18.20.4",
                    "sourceURL":
                        "https://github.com/nodejs-mobile/nodejs-mobile/"
                        "releases/download/v18.20.4/"
                        "nodejs-mobile-v18.20.4-ios.zip",
                    "archiveBytes": 51_492_431,
                    "archiveSha256":
                        "8c5ca3a0d1e38de7f182a5642593e8259"
                        "3b820efd375a14b3ecafc4bcfee620e",
                    "xcframeworkPath": "NodeMobile.xcframework",
                }
            )
            + "\n",
            encoding="utf-8",
        )

    def _write_node_mcp_packages(self, project_root: Path) -> None:
        packages_root = (
            project_root
            / "CodexPad/Application/Resources/MCPPackages"
        )
        entrypoint = (
            packages_root
            / "node_modules/@modelcontextprotocol/"
            "server-filesystem/dist/index.js"
        )
        entrypoint.parent.mkdir(parents=True)
        entrypoint.write_text(
            "process.stdin.resume();\n",
            encoding="utf-8",
        )
        (packages_root / "package.json").write_text(
            json.dumps(
                {
                    "name": "fixture",
                    "private": True,
                    "dependencies": {
                        "@modelcontextprotocol/server-filesystem":
                            "2026.7.10"
                    },
                }
            )
            + "\n",
            encoding="utf-8",
        )
        (packages_root / "package-lock.json").write_text(
            json.dumps(
                {
                    "name": "fixture",
                    "lockfileVersion": 3,
                    "packages": {},
                }
            )
            + "\n",
            encoding="utf-8",
        )
        package_lock_sha256 = hashlib.sha256(
            (packages_root / "package-lock.json").read_bytes()
        ).hexdigest()
        (packages_root / "runtime-lock.json").write_text(
            json.dumps(
                {
                    "schemaVersion": 1,
                    "runtime": {
                        "name": "NodeMobile",
                        "version": "18.20.4",
                    },
                    "packageLockSha256": package_lock_sha256,
                    "tree": {
                        "sha256": "b" * 64,
                        "fileCount": 1,
                        "totalBytes": entrypoint.stat().st_size,
                    },
                    "packages": [
                        {
                            "name":
                                "@modelcontextprotocol/server-filesystem",
                            "version": "2026.7.10",
                            "entrypoint":
                                "MCPPackages/node_modules/"
                                "@modelcontextprotocol/server-filesystem/"
                                "dist/index.js",
                        }
                    ],
                }
            )
            + "\n",
            encoding="utf-8",
        )

    def _write_python_runtime(self, project_root: Path) -> None:
        runtime_root = project_root / "Vendor/python_apple"
        framework = runtime_root / "Python.xcframework"
        (framework / "build").mkdir(parents=True)
        real_utils = (
            Path(__file__).resolve().parent
            / "fixtures/python-apple-utils.sh"
        )
        (framework / "build/utils.sh").write_bytes(
            real_utils.read_bytes()
        )
        (framework / "Info.plist").write_text(
            "<?xml version=\"1.0\"?><plist version=\"1.0\"><dict/></plist>\n",
            encoding="utf-8",
        )
        for slice_name in (
            "ios-arm64",
            "ios-arm64_x86_64-simulator",
        ):
            python_framework = (
                framework
                / slice_name
                / "Python.framework"
            )
            headers = python_framework / "Headers"
            headers.mkdir(parents=True)
            (headers / "Python.h").write_text(
                "#include <Python.h>\n",
                encoding="utf-8",
            )
            (python_framework / "Python").write_bytes(
                b"fixture Mach-O"
            )
            (python_framework / "Info.plist").write_text(
                "<?xml version=\"1.0\"?>"
                "<plist version=\"1.0\"><dict/></plist>\n",
                encoding="utf-8",
            )
            dynload = (
                framework
                / slice_name
                / "lib-arm64/python3.13/lib-dynload"
            )
            dynload.mkdir(
                parents=True,
            )
            (dynload / "fixture.so").write_bytes(
                b"fixture extension",
            )
        stdlib = framework / "lib/python3.13"
        stdlib.mkdir(parents=True)
        (stdlib / "os.py").write_text(
            "# fixture stdlib\n",
            encoding="utf-8",
        )
        (
            framework / "build/iOS-dylib-Info-template.plist"
        ).write_text(
            "<?xml version=\"1.0\"?><plist version=\"1.0\"><dict/></plist>\n",
            encoding="utf-8",
        )
        (runtime_root / "VERSIONS").write_text(
            "Python 3.13.14\n",
            encoding="utf-8",
        )
        (runtime_root / "runtime-lock.json").write_text(
            json.dumps(
                {
                    "schemaVersion": 1,
                    "runtime": "CPython",
                    "version": "3.13.14",
                    "abi": "cp313",
                    "sourceRepository":
                        "https://github.com/beeware/"
                        "Python-Apple-support",
                    "sourceTag": "3.13-b14",
                    "sourceCommit":
                        "54d8ab6ef4fbac4d60706f311a986aee5236c71b",
                    "sourceURL":
                        "https://github.com/beeware/"
                        "Python-Apple-support/releases/download/"
                        "3.13-b14/"
                        "Python-3.13-iOS-support.b14.tar.gz",
                    "assetName":
                        "Python-3.13-iOS-support.b14.tar.gz",
                    "archiveBytes": 32_387_292,
                    "archiveSha256":
                        "8b5cb76ef8d8a2946052479358eeec9d5"
                        "4b4496cb60920e175ec1489b5cf7963",
                    "xcframeworkPath": "Python.xcframework",
                    "versionsPath": "VERSIONS",
                    "compatibilityPatches": [
                        {
                            "id": "quote-fwork-placeholder-path",
                            "path": (
                                "Python.xcframework/build/utils.sh"
                            ),
                            "sha256": (
                                "a4bb9d3e34f63ea0e022a013898df666"
                                "96062f83b372dd9b947c415020c705f1"
                            ),
                        }
                    ],
                }
            )
            + "\n",
            encoding="utf-8",
        )
        bridge = project_root / "CodexPythonRuntimeBridge"
        (bridge / "include").mkdir(parents=True)
        (bridge / "include/CodexPythonRuntimeBridge.h").write_text(
            "int codex_python_runtime_initialize(void);\n",
            encoding="utf-8",
        )
        (bridge / "CodexPythonRuntimeBridge.m").write_text(
            '#include "CodexPythonRuntimeBridge.h"\n',
            encoding="utf-8",
        )

    def _write_python_mcp_packages(self, project_root: Path) -> None:
        packages_root = (
            project_root
            / "CodexPad/Application/Resources/PythonPackages"
        )
        native_slices = {}
        for slice_name in (
            "ios-arm64",
            "ios-arm64-simulator",
        ):
            package = (
                packages_root / slice_name / "mcp_server_time"
            )
            package.mkdir(parents=True)
            (package / "__init__.py").write_text(
                "def main(): pass\n",
                encoding="utf-8",
            )
            (package / "Ignored.swift").write_text(
                "this is Python package data, not an app source\n",
                encoding="utf-8",
            )
            (package / "Info.plist").write_text(
                "<?xml version=\"1.0\"?>"
                "<plist version=\"1.0\"><dict/></plist>\n",
                encoding="utf-8",
            )
            native = package / f"native-{slice_name}.so"
            native.write_bytes(
                f"fixture {slice_name} native".encode("utf-8"),
            )
            native_slices[slice_name] = {
                "architectures": ["arm64"],
                "path": native.relative_to(
                    packages_root / slice_name
                ).as_posix(),
                "sha256": hashlib.sha256(
                    native.read_bytes()
                ).hexdigest(),
                "size": native.stat().st_size,
            }
        requirements_lock = packages_root / "requirements.lock"
        requirements_lock.write_text(
            "mcp-server-time==0.6.2\n",
            encoding="utf-8",
        )
        uvx_registry = packages_root / "uvx-registry.json"
        uvx_registry.write_text(
            json.dumps(
                {
                    "schemaVersion": 1,
                    "commands": {
                        "mcp-server-time": {
                            "entrypoint": "mcp_server_time:main",
                        }
                    },
                }
            )
            + "\n",
            encoding="utf-8",
        )
        tree_digest = hashlib.sha256()
        tree_file_count = 0
        tree_total_bytes = 0
        tree_files = []
        for slice_name in (
            "ios-arm64",
            "ios-arm64-simulator",
        ):
            tree_files.extend(
                path
                for path in (packages_root / slice_name).rglob("*")
                if path.is_file()
            )
        for path in sorted(
            tree_files,
            key=lambda item: item.relative_to(
                packages_root
            ).as_posix(),
        ):
            relative = path.relative_to(packages_root).as_posix()
            payload = path.read_bytes()
            digest = hashlib.sha256(payload).hexdigest()
            tree_digest.update(relative.encode("utf-8"))
            tree_digest.update(b"\0")
            tree_digest.update(str(len(payload)).encode("ascii"))
            tree_digest.update(b"\0")
            tree_digest.update(digest.encode("ascii"))
            tree_digest.update(b"\n")
            tree_file_count += 1
            tree_total_bytes += len(payload)
        (packages_root / "runtime-lock.json").write_text(
            json.dumps(
                {
                    "schemaVersion": 1,
                    "runtime": {
                        "name": "CPython",
                        "version": "3.13.14",
                        "abi": "cp313",
                        "sourceTag": "3.13-b14",
                        "sourceCommit":
                            "54d8ab6ef4fbac4d60706f311a986aee5236c71b",
                    },
                    "requirementsLockSha256": hashlib.sha256(
                        requirements_lock.read_bytes()
                    ).hexdigest(),
                    "uvxRegistrySha256": hashlib.sha256(
                        uvx_registry.read_bytes()
                    ).hexdigest(),
                    "tree": {
                        "sha256": tree_digest.hexdigest(),
                        "fileCount": tree_file_count,
                        "totalBytes": tree_total_bytes,
                    },
                    "snapshotRoots": [
                        "ios-arm64",
                        "ios-arm64-simulator",
                    ],
                    "nativeExtensions": [
                        {
                            "module": "mcp_server_time.native",
                            "package": "mcp-server-time",
                            "slices": native_slices,
                        }
                    ],
                    "packages": [
                        {
                            "name": "mcp-server-time",
                            "version": "0.6.2",
                            "entrypoint": "mcp_server_time:main",
                            "consoleScript": "mcp-server-time",
                        }
                    ],
                }
            )
            + "\n",
            encoding="utf-8",
        )

    def test_app_sources_expose_live_first_turn_controls(self):
        project_root = Path(__file__).resolve().parents[1]
        source_root = project_root / "CodexPad/CodexPad"
        sources = "\n".join(
            path.read_text(encoding="utf-8")
            for path in sorted(source_root.rglob("*.swift"))
        )
        detail = (
            source_root / "Presentation/ThreadDetailView.swift"
        ).read_text(encoding="utf-8")

        self.assertIn("CodexCoreClient", sources)
        self.assertIn("openWorkspace", sources)
        self.assertIn("startThread", sources)
        self.assertIn("startTurn", sources)
        self.assertNotIn(".disabled(true)", detail)

    def test_project_is_ipad_only_and_ready_for_automatic_signing(self):
        with TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "CodexPad/App").mkdir(parents=True)
            (root / "CodexPad/App/CodexPadApp.swift").write_text(
                "import SwiftUI\n@main struct CodexPadApp: App {"
                'var body: some Scene { WindowGroup { Text("Codex") } }}\n',
                encoding="utf-8",
            )
            output = generate_project(root)
            project = output.read_text(encoding="utf-8")

        self.assertIn(
            "PRODUCT_BUNDLE_IDENTIFIER = dev.codexforipad.app;", project
        )
        self.assertIn("TARGETED_DEVICE_FAMILY = 2;", project)
        self.assertIn("IPHONEOS_DEPLOYMENT_TARGET = 18.0;", project)
        self.assertEqual(
            project.count(
                "CODE_SIGN_ENTITLEMENTS = "
                "CodexPad/Resources/CodexPad.entitlements;"
            ),
            2,
        )
        self.assertIn("CODE_SIGN_STYLE = Automatic;", project)
        self.assertNotIn("DEVELOPMENT_TEAM =", project)
        self.assertIn("ProvisioningStyle = Automatic;", project)
        self.assertNotIn("CODE_SIGNING_ALLOWED = NO;", project)
        self.assertEqual(project.count("SUPPORTS_MACCATALYST = NO;"), 2)
        self.assertEqual(
            project.count("SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD = NO;"),
            2,
        )
        self.assertIn("CodexPadApp.swift", project)

    def test_ui_test_swift_files_generate_an_ipad_ui_testing_target(self):
        with TemporaryDirectory() as directory:
            root = Path(directory)
            project_root = self._write_minimal_project(root)
            self._write_ui_tests(
                project_root,
                "LaunchTests.swift",
                "Flows/WorkspaceTests.swift",
            )

            project = generate_project(project_root).read_text(encoding="utf-8")

        self.assertIn("LaunchTests.swift in Sources", project)
        self.assertIn("WorkspaceTests.swift in Sources", project)
        self.assertIn("path = Tests/CodexPadUITests;", project)
        self.assertIn(
            "productType = "
            '"com.apple.product-type.bundle.ui-testing";',
            project,
        )
        self.assertIn(
            "CodexPadUITests.xctest */ = "
            "{isa = PBXFileReference; "
            "explicitFileType = wrapper.cfbundle;",
            project,
        )
        self.assertEqual(project.count("TEST_TARGET_NAME = CodexPad;"), 2)
        self.assertEqual(project.count("PRODUCT_NAME = CodexPadUITests;"), 2)
        self.assertEqual(
            project.count(
                "PRODUCT_BUNDLE_IDENTIFIER = dev.codexforipad.app.ui-tests;"
            ),
            2,
        )
        self.assertIn("IPHONEOS_DEPLOYMENT_TARGET = 18.0;", project)
        self.assertIn("SUPPORTED_PLATFORMS = \"iphoneos iphonesimulator\";", project)
        self.assertEqual(project.count("SUPPORTS_MACCATALYST = NO;"), 4)
        self.assertEqual(
            project.count("SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD = NO;"),
            4,
        )
        self.assertIn("TARGETED_DEVICE_FAMILY = 2;", project)

    def test_ui_testing_target_depends_on_the_codexpad_app_target(self):
        with TemporaryDirectory() as directory:
            root = Path(directory)
            project_root = self._write_minimal_project(root)
            self._write_ui_tests(project_root, "CodexPadUITests.swift")

            project = generate_project(project_root).read_text(encoding="utf-8")

        proxy = re.search(
            r"(?P<proxy>[0-9A-F]{24}) /\* PBXContainerItemProxy \*/ = \{\n"
            r"\s+isa = PBXContainerItemProxy;\n"
            r"\s+containerPortal = (?P<project>[0-9A-F]{24}) "
            r"/\* Project object \*/;\n"
            r"\s+proxyType = 1;\n"
            r"\s+remoteGlobalIDString = (?P<app>[0-9A-F]{24});\n"
            r"\s+remoteInfo = CodexPad;\n"
            r"\s+\};",
            project,
        )
        self.assertIsNotNone(proxy)
        assert proxy is not None

        dependency = re.search(
            r"(?P<dependency>[0-9A-F]{24}) /\* PBXTargetDependency \*/ = \{\n"
            r"\s+isa = PBXTargetDependency;\n"
            rf"\s+target = {proxy['app']} /\* CodexPad \*/;\n"
            rf"\s+targetProxy = {proxy['proxy']} "
            r"/\* PBXContainerItemProxy \*/;\n"
            r"\s+\};",
            project,
        )
        self.assertIsNotNone(dependency)
        assert dependency is not None
        self.assertRegex(
            project,
            r"(?s)/\* CodexPadUITests \*/ = \{.*?"
            r"dependencies = \(\n"
            rf"\s+{dependency['dependency']} /\* PBXTargetDependency \*/,\n"
            r"\s+\);",
        )

    def test_shared_scheme_uses_dependency_order_and_non_parallel_ui_tests(self):
        with TemporaryDirectory() as directory:
            root = Path(directory)
            project_root = self._write_minimal_project(root)
            self._write_ui_tests(project_root, "CodexPadUITests.swift")
            scheme = (
                project_root
                / "CodexPad.xcodeproj"
                / "xcshareddata/xcschemes/CodexPad.xcscheme"
            )
            scheme.parent.mkdir(parents=True)
            scheme.write_text("stale scheme\n", encoding="utf-8")

            generate_project(project_root)
            project = (
                project_root / "CodexPad.xcodeproj/project.pbxproj"
            ).read_text(encoding="utf-8")
            scheme_bytes = scheme.read_bytes()
            temporary_scheme_exists = scheme.with_suffix(
                ".xcscheme.tmp"
            ).exists()

        self.assertTrue(
            scheme_bytes.startswith(b'<?xml version="1.0" encoding="UTF-8"?>'),
            "the stale shared scheme was not regenerated",
        )
        document = ET.fromstring(scheme_bytes)
        build_action = document.find("./BuildAction")
        self.assertIsNotNone(build_action)
        assert build_action is not None
        self.assertEqual(build_action.attrib["parallelizeBuildables"], "YES")
        self.assertEqual(build_action.attrib["buildImplicitDependencies"], "YES")
        build_references = document.findall(
            "./BuildAction/BuildActionEntries/"
            "BuildActionEntry/BuildableReference"
        )
        self.assertEqual(
            [
                reference.attrib["BlueprintName"]
                for reference in build_references
            ],
            ["CodexPad", "CodexPadUITests"],
        )
        self.assertEqual(
            [
                reference.attrib["BuildableName"]
                for reference in build_references
            ],
            ["Codex for ipad.app", "CodexPadUITests.xctest"],
        )
        for reference in build_references:
            self.assertRegex(
                project,
                rf"{reference.attrib['BlueprintIdentifier']} "
                rf"/\* {re.escape(reference.attrib['BlueprintName'])} \*/ = "
                r"\{\n\s+isa = PBXNativeTarget;",
            )
        testable = document.find(
            "./TestAction/Testables/TestableReference"
        )
        self.assertIsNotNone(testable)
        assert testable is not None
        self.assertEqual(testable.attrib["skipped"], "NO")
        self.assertEqual(testable.attrib["parallelizable"], "NO")
        testable_reference = testable.find("./BuildableReference")
        self.assertIsNotNone(testable_reference)
        assert testable_reference is not None
        self.assertEqual(
            testable_reference.attrib["BlueprintName"],
            "CodexPadUITests",
        )
        self.assertFalse(temporary_scheme_exists)

    def test_no_ui_test_swift_files_remove_stale_ui_target_and_scheme(self):
        with TemporaryDirectory() as directory:
            root = Path(directory)
            project_root = self._write_minimal_project(root)
            self._write_ui_tests(project_root, "CodexPadUITests.swift")
            output = generate_project(project_root)
            ui_test_source = (
                project_root
                / "Tests/CodexPadUITests/CodexPadUITests.swift"
            )
            ui_test_source.unlink()
            ui_test_source.with_name("README.txt").write_text(
                "Swift UI tests are not installed in this fixture.\n",
                encoding="utf-8",
            )

            project = generate_project(project_root).read_text(encoding="utf-8")
            scheme_exists = (
                output.parent
                / "xcshareddata/xcschemes/CodexPad.xcscheme"
            ).exists()

        self.assertNotIn("CodexPadUITests", project)
        self.assertNotIn("com.apple.product-type.bundle.ui-testing", project)
        self.assertFalse(scheme_exists)

    def test_ui_target_and_shared_scheme_are_byte_deterministic(self):
        with TemporaryDirectory() as directory:
            root = Path(directory)
            first_project_root = self._write_minimal_project(root / "first")
            second_project_root = self._write_minimal_project(root / "second")
            self._write_ui_tests(
                first_project_root,
                "ZLastTests.swift",
                "Flows/AFirstTests.swift",
            )
            self._write_ui_tests(
                second_project_root,
                "Flows/AFirstTests.swift",
                "ZLastTests.swift",
            )

            first_output = generate_project(first_project_root)
            second_output = generate_project(second_project_root)
            first_project = first_output.read_bytes()
            second_project = second_output.read_bytes()
            first_scheme = (
                first_output.parent
                / "xcshareddata/xcschemes/CodexPad.xcscheme"
            ).read_bytes()
            second_scheme = (
                second_output.parent
                / "xcshareddata/xcschemes/CodexPad.xcscheme"
            ).read_bytes()
            repeated_project = generate_project(first_project_root).read_bytes()
            repeated_scheme = (
                first_output.parent
                / "xcshareddata/xcschemes/CodexPad.xcscheme"
            ).read_bytes()

        self.assertEqual(first_project, second_project)
        self.assertEqual(first_project, repeated_project)
        self.assertEqual(first_scheme, second_scheme)
        self.assertEqual(first_scheme, repeated_scheme)

    def test_project_embeds_the_imported_desktop_version_and_build(self):
        with TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "CodexPad/App").mkdir(parents=True)
            (root / "CodexPad/App/CodexPadApp.swift").write_text(
                "import SwiftUI\n@main struct CodexPadApp: App {"
                'var body: some Scene { WindowGroup { Text("Codex") } }}\n',
                encoding="utf-8",
            )
            project = generate_project(
                root,
                desktop_version="99.1.7",
                desktop_build="7000",
            ).read_text(encoding="utf-8")

        self.assertIn("MARKETING_VERSION = 99.1.7;", project)
        self.assertIn("CURRENT_PROJECT_VERSION = 7000;", project)
        self.assertNotIn("MARKETING_VERSION = 26.721.41059;", project)
        self.assertNotIn("CURRENT_PROJECT_VERSION = 5848;", project)

    def test_external_product_name_is_codex_for_ipad(self):
        with TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "CodexPad/App").mkdir(parents=True)
            (root / "CodexPad/App/CodexPadApp.swift").write_text(
                "import SwiftUI\n@main struct CodexPadApp: App {"
                'var body: some Scene { WindowGroup { Text("Codex") } }}\n',
                encoding="utf-8",
            )
            project = generate_project(root).read_text(encoding="utf-8")

        self.assertIn(
            'INFOPLIST_KEY_CFBundleDisplayName = "Codex for ipad";',
            project,
        )
        self.assertIn('PRODUCT_NAME = "Codex for ipad";', project)
        self.assertIn('path = "Codex for ipad.app";', project)
        self.assertIn('productName = "Codex for ipad";', project)

    def test_generation_is_byte_deterministic(self):
        with TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "CodexPad/App").mkdir(parents=True)
            (root / "CodexPad/App/CodexPadApp.swift").write_text(
                "import SwiftUI\n@main struct CodexPadApp: App {"
                'var body: some Scene { WindowGroup { Text("Codex") } }}\n',
                encoding="utf-8",
            )
            output = generate_project(root)
            first = output.read_bytes()
            second = generate_project(root).read_bytes()

        self.assertEqual(first, second)

    def test_manifest_selected_desktop_surface_has_fixed_bundle_directory(self):
        with TemporaryDirectory() as directory:
            root = Path(directory)
            project_root = self._write_minimal_project(root)
            self._write_desktop_surface(
                root,
                version="99.42.7",
                build="7001",
            )

            output = generate_project(
                project_root,
                desktop_version="99.42.7",
                desktop_build="7001",
            )
            first = output.read_bytes()
            second = generate_project(
                project_root,
                desktop_version="99.42.7",
                desktop_build="7001",
            ).read_bytes()
            project = second.decode("utf-8")

        self.assertEqual(first, second)
        self.assertIn("isa = PBXCopyFilesBuildPhase;", project)
        self.assertIn(
            "/* Embed CodexDesktopSurface */ = {\n"
            "\t\t\tisa = PBXCopyFilesBuildPhase;",
            project,
        )
        self.assertIn("dstSubfolderSpec = 7;", project)
        self.assertIn(
            "name = CodexDesktopSurface;\n"
            '\t\t\tpath = "../artifacts/full-reverse-99.42.7/'
            'app-asar/webview";\n'
            "\t\t\tsourceTree = SOURCE_ROOT;",
            project,
        )
        self.assertIn(
            "lastKnownFileType = folder; "
            'path = "assets"; sourceTree = "<group>";',
            project,
        )
        self.assertIn(
            "assets in Embed CodexDesktopSurface",
            project,
        )
        self.assertIn(
            "desktop-surface-manifest.json in Embed CodexDesktopSurface",
            project,
        )
        self.assertIn(
            "lastKnownFileType = text.json; "
            "name = desktop-surface-manifest.json; "
            'path = "../versions/99.42.7/'
            'desktop-surface-manifest.json"; sourceTree = SOURCE_ROOT;',
            project,
        )
        self.assertIn("dstPath = CodexDesktopSurface;", project)
        self.assertNotIn("full-reverse-26.721.41059", project)
        self.assertNotIn("full-reverse-26.721.81911", project)

    def test_desktop_surface_version_manifest_must_match_requested_version(self):
        with TemporaryDirectory() as directory:
            root = Path(directory)
            project_root = self._write_minimal_project(root)
            self._write_desktop_surface(
                root,
                version="99.42.7",
                build="7001",
            )
            manifest = root / "versions/99.42.7/manifest.json"
            manifest.write_text(
                json.dumps(
                    {
                        "schemaVersion": 1,
                        "version": "99.42.6",
                        "build": "7001",
                    }
                )
                + "\n",
                encoding="utf-8",
            )

            with self.assertRaisesRegex(
                ValueError,
                "version manifest does not match requested desktop version",
            ):
                generate_project(
                    project_root,
                    desktop_version="99.42.7",
                    desktop_build="7001",
                )

    def test_repository_generation_requires_current_surface_manifests(self):
        with TemporaryDirectory() as directory:
            root = Path(directory)
            project_root = self._write_minimal_project(root)
            (root / "versions").mkdir()

            with self.assertRaisesRegex(
                ValueError,
                "version manifest is missing for desktop 99.42.8",
            ):
                generate_project(
                    project_root,
                    desktop_version="99.42.8",
                    desktop_build="7002",
                )

    def _assert_surface_mutation_is_rejected(
        self,
        mutation,
    ) -> None:
        with TemporaryDirectory() as directory:
            root = Path(directory)
            project_root = self._write_minimal_project(root)
            webview = self._write_desktop_surface(
                root,
                version="99.42.9",
                build="7003",
            )
            project_file = (
                project_root / "CodexPad.xcodeproj/project.pbxproj"
            )
            project_file.parent.mkdir(parents=True)
            sentinel = b"existing-project-must-survive\n"
            project_file.write_bytes(sentinel)
            mutation(webview)

            with self.assertRaisesRegex(
                ValueError,
                "desktop surface resource integrity mismatch",
            ):
                generate_project(
                    project_root,
                    desktop_version="99.42.9",
                    desktop_build="7003",
                )

            self.assertEqual(project_file.read_bytes(), sentinel)

    def test_added_desktop_surface_file_is_rejected_before_project_replace(
        self,
    ):
        self._assert_surface_mutation_is_rejected(
            lambda webview: (webview / "unexpected.js").write_text(
                "unexpected\n",
                encoding="utf-8",
            )
        )

    def test_modified_desktop_surface_file_is_rejected_before_project_replace(
        self,
    ):
        self._assert_surface_mutation_is_rejected(
            lambda webview: (webview / "assets/app.js").write_text(
                "tampered\n",
                encoding="utf-8",
            )
        )

    def test_deleted_desktop_surface_file_is_rejected_before_project_replace(
        self,
    ):
        self._assert_surface_mutation_is_rejected(
            lambda webview: (webview / "assets/app.js").unlink()
        )

    def test_codex_core_xcframework_is_linked_from_generated_build_output(self):
        with TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "CodexPad/App").mkdir(parents=True)
            (root / "CodexPad/App/CodexPadApp.swift").write_text(
                "import SwiftUI\n@main struct CodexPadApp: App {"
                'var body: some Scene { WindowGroup { Text("Codex") } }}\n',
                encoding="utf-8",
            )
            project = generate_project(root).read_text(encoding="utf-8")

        self.assertIn("CodexCore.xcframework in Frameworks", project)
        self.assertIn("isa = PBXFrameworksBuildPhase;", project)
        self.assertIn(
            'path = "$(PROJECT_DIR)/../build/CodexCore.xcframework"; '
            'sourceTree = "SOURCE_ROOT";',
            project,
        )
        self.assertEqual(
            project.count(
                'OTHER_LDFLAGS = "$(inherited) -lz -liconv '
                '-framework Security -framework CoreFoundation";'
            ),
            2,
        )
        self.assertIn("/* Frameworks */ = {\n\t\t\tisa = PBXGroup;", project)

    def test_embedded_shell_resources_and_dynamic_frameworks_are_wired(self):
        with TemporaryDirectory() as directory:
            root = Path(directory)
            project_root = self._write_minimal_project(root)
            resources = project_root / "CodexPad/Application/Resources"
            resources.mkdir(parents=True)
            for name in (
                "commandDictionary.plist",
                "extraCommandsDictionary.plist",
            ):
                (resources / name).write_text(
                    "<?xml version=\"1.0\"?><plist version=\"1.0\"><dict/></plist>\n",
                    encoding="utf-8",
                )
            bundled_skills = resources / "skills/skills/.curated/fixture"
            bundled_skills.mkdir(parents=True)
            (bundled_skills / "SKILL.md").write_text(
                "---\nname: fixture\n---\n",
                encoding="utf-8",
            )
            (bundled_skills / "Ignored.swift").write_text(
                "this copied skill file must not compile\n",
                encoding="utf-8",
            )
            (bundled_skills / "Ignored.plist").write_text(
                "<?xml version=\"1.0\"?><plist version=\"1.0\"><dict/></plist>\n",
                encoding="utf-8",
            )
            self._write_ios_system_runtime(project_root)

            project = generate_project(project_root).read_text(encoding="utf-8")

        for name in ("ios_system", "files", "shell", "text"):
            framework = f"{name}.xcframework"
            self.assertIn(
                f'path = "Vendor/ios_system/{framework}"; '
                'sourceTree = "<group>";',
                project,
            )
            self.assertIn(f"{framework} in Frameworks", project)
            self.assertIn(f"{framework} in Embed Frameworks", project)
        self.assertEqual(project.count("CodeSignOnCopy"), 4)
        self.assertEqual(project.count("RemoveHeadersOnCopy"), 4)
        self.assertIn("name = \"Embed Frameworks\";", project)
        self.assertIn(
            'LD_RUNPATH_SEARCH_PATHS = "$(inherited) @executable_path/Frameworks";',
            project,
        )
        self.assertIn("dstSubfolderSpec = 10;", project)
        self.assertIn(
            'path = "Application/Resources/commandDictionary.plist";',
            project,
        )
        self.assertIn(
            'path = "Application/Resources/extraCommandsDictionary.plist";',
            project,
        )
        self.assertIn("lastKnownFileType = text.plist.xml;", project)
        self.assertIn("commandDictionary.plist in Resources", project)
        self.assertIn("extraCommandsDictionary.plist in Resources", project)
        self.assertIn(
            'lastKnownFileType = folder; '
            'path = "Application/Resources/skills";',
            project,
        )
        self.assertIn("skills in Resources", project)
        self.assertNotIn("Ignored.swift", project)
        self.assertNotIn("Ignored.plist", project)

    def test_partial_embedded_shell_runtime_is_rejected(self):
        with TemporaryDirectory() as directory:
            root = Path(directory)
            project_root = self._write_minimal_project(root)
            framework = (
                project_root
                / "Vendor/ios_system/ios_system.xcframework"
            )
            framework.mkdir(parents=True)

            with self.assertRaisesRegex(
                ValueError,
                "embedded ios_system framework set is incomplete",
            ):
                generate_project(project_root)

    def test_node_mobile_runtime_is_provenance_locked_linked_and_embedded(self):
        with TemporaryDirectory() as directory:
            root = Path(directory)
            project_root = self._write_minimal_project(root)
            self._write_ios_system_runtime(project_root)
            self._write_node_mobile_runtime(project_root)

            project = generate_project(project_root).read_text(
                encoding="utf-8"
            )

        self.assertIn(
            'path = "Vendor/node_mobile/NodeMobile.xcframework"; '
            'sourceTree = "<group>";',
            project,
        )
        self.assertIn("NodeMobile.xcframework in Frameworks", project)
        self.assertIn("NodeMobile.xcframework in Embed Frameworks", project)
        self.assertEqual(project.count("CodeSignOnCopy"), 5)
        self.assertEqual(project.count("RemoveHeadersOnCopy"), 5)

    def test_node_mcp_package_snapshot_is_copied_as_one_folder_resource(self):
        with TemporaryDirectory() as directory:
            root = Path(directory)
            project_root = self._write_minimal_project(root)
            self._write_node_mcp_packages(project_root)

            project = generate_project(project_root).read_text(
                encoding="utf-8"
            )

        self.assertIn(
            'lastKnownFileType = folder; '
            'path = "Application/Resources/MCPPackages";',
            project,
        )
        self.assertIn("MCPPackages in Resources", project)
        self.assertNotIn("server-filesystem in Resources", project)
        self.assertNotIn("index.js in Resources", project)

    def test_node_mcp_package_snapshot_without_lock_is_rejected(self):
        with TemporaryDirectory() as directory:
            root = Path(directory)
            project_root = self._write_minimal_project(root)
            packages = (
                project_root
                / "CodexPad/Application/Resources/MCPPackages"
            )
            packages.mkdir(parents=True)

            with self.assertRaisesRegex(
                ValueError,
                "bundled Node MCP package snapshot is incomplete",
            ):
                generate_project(project_root)

    def test_python_runtime_bridge_packages_and_install_phase_are_wired(self):
        with TemporaryDirectory() as directory:
            root = Path(directory)
            project_root = self._write_minimal_project(root)
            self._write_python_runtime(project_root)
            self._write_python_mcp_packages(project_root)

            project = generate_project(project_root).read_text(
                encoding="utf-8"
            )

        self.assertIn(
            'path = "Vendor/python_apple/Python.xcframework"; '
            'sourceTree = "<group>";',
            project,
        )
        self.assertIn("Python.xcframework in Frameworks", project)
        self.assertIn("Python.xcframework in Embed Frameworks", project)
        self.assertIn(
            'path = "CodexPythonRuntimeBridge/'
            'CodexPythonRuntimeBridge.m"; sourceTree = SOURCE_ROOT;',
            project,
        )
        self.assertIn("CodexPythonRuntimeBridge.m in Sources", project)
        self.assertIn(
            'path = "CodexPythonRuntimeBridge/include/'
            'CodexPythonRuntimeBridge.h"; sourceTree = SOURCE_ROOT;',
            project,
        )
        self.assertIn(
            'lastKnownFileType = folder; '
            'path = "Application/Resources/PythonPackages";',
            project,
        )
        self.assertNotIn("PythonPackages in Resources", project)
        self.assertNotIn("Ignored.swift", project)
        self.assertNotIn(
            "site-packages/mcp_server_time/Info.plist",
            project,
        )
        self.assertIn("name = \"Install Embedded Python\";", project)
        self.assertIn(
            'source \\"${PROJECT_DIR}/Vendor/python_apple/'
            'Python.xcframework/build/utils.sh\\"',
            project,
        )
        self.assertIn(
            'install_python \\"Vendor/python_apple/'
            'Python.xcframework\\" '
            '\\"PythonPackages/site-packages\\"',
            project,
        )
        self.assertIn(
            'PYTHON_PACKAGE_SLICE=\\"ios-arm64\\"',
            project,
        )
        self.assertIn(
            'PYTHON_PACKAGE_SLICE=\\"ios-arm64-simulator\\"',
            project,
        )
        self.assertIn(
            'SOURCE_PACKAGES_ROOT=\\"${PROJECT_DIR}/CodexPad/'
            'Application/Resources/PythonPackages\\"',
            project,
        )
        self.assertIn(
            'rsync -a --delete --exclude \\"ios-arm64/\\" '
            '--exclude \\"ios-arm64-simulator/\\" '
            '\\"${SOURCE_PACKAGES_ROOT}/\\" '
            '\\"${PACKAGES_ROOT}/\\"',
            project,
        )
        self.assertIn(
            'rsync -a --delete \\"${SELECTED_SOURCE_PACKAGES}/\\" '
            '\\"${PACKAGES_ROOT}/site-packages/\\"',
            project,
        )
        self.assertIn(
            'if [ \\"${CODE_SIGNING_ALLOWED:-YES}\\" = \\"NO\\" ] '
            '|| [ \\"${EFFECTIVE_PLATFORM_NAME}\\" = '
            '\\"-iphonesimulator\\" ]; then',
            project,
        )
        self.assertIn(
            'export EXPANDED_CODE_SIGN_IDENTITY=\\"-\\"',
            project,
        )
        self.assertIn(
            'export EXPANDED_CODE_SIGN_IDENTITY_NAME=\\"Ad Hoc\\"',
            project,
        )
        self.assertIn(
            ': \\"${EXPANDED_CODE_SIGN_IDENTITY:'
            '?missing signing identity}\\"',
            project,
        )
        self.assertNotIn("alwaysOutOfDate = 1;", project)
        self.assertIn(
            '"$(PROJECT_DIR)/CodexPad/Application/Resources/'
            'PythonPackages/runtime-lock.json",',
            project,
        )
        self.assertIn(
            '"$(PROJECT_DIR)/Vendor/python_apple/'
            'Python.xcframework/Info.plist",',
            project,
        )
        self.assertIn(
            '"$(PROJECT_DIR)/Vendor/python_apple/'
            'Python.xcframework/build/utils.sh",',
            project,
        )
        self.assertIn(
            '"$(CODESIGNING_FOLDER_PATH)/'
            '.codex-embedded-python.stamp",',
            project,
        )
        self.assertIn(
            'touch \\"${CODESIGNING_FOLDER_PATH}/'
            '.codex-embedded-python.stamp\\"',
            project,
        )
        self.assertEqual(
            project.count(
                "SWIFT_OBJC_BRIDGING_HEADER = "
                "CodexPythonRuntimeBridge/include/"
                "CodexPythonRuntimeBridge.h;"
            ),
            2,
        )
        self.assertEqual(
            project.count("ENABLE_USER_SCRIPT_SANDBOXING = NO;"),
            2,
        )
        self.assertEqual(
            project.count(
                '"EXCLUDED_ARCHS[sdk=iphonesimulator*]" = '
                "x86_64;"
            ),
            2,
        )
        resources = project.index("/* Resources */,")
        install = project.index("/* Install Embedded Python */,")
        embed = project.index("/* Embed Frameworks */,")
        self.assertLess(resources, install)
        self.assertLess(install, embed)

    def test_partial_python_runtime_or_package_snapshot_is_rejected(self):
        with TemporaryDirectory() as directory:
            root = Path(directory)
            project_root = self._write_minimal_project(root)
            self._write_python_runtime(project_root)

            with self.assertRaisesRegex(
                ValueError,
                "embedded Python package snapshot is incomplete",
            ):
                generate_project(project_root)

        with TemporaryDirectory() as directory:
            root = Path(directory)
            project_root = self._write_minimal_project(root)
            self._write_python_mcp_packages(project_root)

            with self.assertRaisesRegex(
                ValueError,
                "embedded CPython runtime is incomplete",
            ):
                generate_project(project_root)

    def test_python_runtime_requires_slice_metadata_and_dynload(self):
        for missing_relative in (
            (
                "Vendor/python_apple/Python.xcframework/"
                "ios-arm64/Python.framework/Info.plist"
            ),
            (
                "Vendor/python_apple/Python.xcframework/"
                "ios-arm64_x86_64-simulator/"
                "lib-arm64/python3.13/lib-dynload/fixture.so"
            ),
        ):
            with self.subTest(missing=missing_relative):
                with TemporaryDirectory() as directory:
                    root = Path(directory)
                    project_root = self._write_minimal_project(root)
                    self._write_python_runtime(project_root)
                    self._write_python_mcp_packages(project_root)
                    (project_root / missing_relative).unlink()

                    with self.assertRaisesRegex(
                        ValueError,
                        "embedded CPython runtime is incomplete",
                    ):
                        generate_project(project_root)

    def test_python_snapshot_tree_entrypoint_and_native_files_are_verified(
        self,
    ):
        for missing_relative in (
            "ios-arm64/mcp_server_time/__init__.py",
            "ios-arm64-simulator/mcp_server_time/"
            "native-ios-arm64-simulator.so",
        ):
            with self.subTest(missing=missing_relative):
                with TemporaryDirectory() as directory:
                    root = Path(directory)
                    project_root = self._write_minimal_project(root)
                    self._write_python_runtime(project_root)
                    self._write_python_mcp_packages(project_root)
                    packages_root = (
                        project_root
                        / "CodexPad/Application/Resources/"
                        "PythonPackages"
                    )
                    (packages_root / missing_relative).unlink()

                    with self.assertRaisesRegex(
                        ValueError,
                        "embedded Python package snapshot",
                    ):
                        generate_project(project_root)

    def test_partial_node_mobile_runtime_is_rejected(self):
        with TemporaryDirectory() as directory:
            root = Path(directory)
            project_root = self._write_minimal_project(root)
            framework = (
                project_root
                / "Vendor/node_mobile/NodeMobile.xcframework"
            )
            framework.mkdir(parents=True)

            with self.assertRaisesRegex(
                ValueError,
                "embedded NodeMobile runtime is incomplete",
            ):
                generate_project(project_root)

    def test_exactly_one_app_entry_is_required(self):
        with TemporaryDirectory() as directory:
            with self.assertRaisesRegex(
                ValueError, "CodexPadApp.swift is missing"
            ):
                generate_project(Path(directory))


if __name__ == "__main__":
    unittest.main()
