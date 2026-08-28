import hashlib
import json
import os
import shutil
import subprocess
import unittest
import zipfile
from pathlib import Path
from tempfile import TemporaryDirectory

from scripts.vendor_python_mcp_packages import (
    ARTIFACTS,
    DEVICE_SLICE,
    NATIVE_EXTENSIONS,
    PACKAGE_NAME,
    PACKAGE_VERSION,
    SIMULATOR_SLICE,
    SnapshotError,
    canonical_requirements_lock,
    canonical_uvx_registry,
    generate_runtime_lock,
    tree_identity,
    validate_native_slice,
    verify_runtime_lock,
    write_runtime_lock,
    _extract_wheel,
    _native_build_environment,
    _normalize_native_sbom,
)


REPOSITORY_ROOT = Path(__file__).resolve().parents[1]
PYTHON_XCFRAMEWORK = (
    REPOSITORY_ROOT
    / "CodexPad"
    / "Vendor"
    / "python_apple"
    / "Python.xcframework"
)


class VendorPythonMCPPackagesTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        if not (PYTHON_XCFRAMEWORK / "ios-arm64").is_dir():
            raise unittest.SkipTest(
                "the optional Python XCFramework has not been bootstrapped"
            )
        cls._native_directory = TemporaryDirectory()
        native_directory = Path(cls._native_directory.name)
        source = native_directory / "fixture.c"
        source.write_text(
            """
#include <Python.h>

static struct PyModuleDef module = {
    PyModuleDef_HEAD_INIT, "fixture", NULL, -1, NULL
};

PyMODINIT_FUNC PyInit_fixture(void) {
    return PyModule_Create(&module);
}
""".lstrip(),
            encoding="utf-8",
        )
        cls.device_fixture = native_directory / "fixture-iphoneos.so"
        cls.simulator_fixture = (
            native_directory / "fixture-iphonesimulator.so"
        )
        cls._compile_native_fixture(
            source,
            cls.device_fixture,
            sdk="iphoneos",
            target="arm64-apple-ios13.0",
            framework_slice="ios-arm64",
        )
        cls._compile_native_fixture(
            source,
            cls.simulator_fixture,
            sdk="iphonesimulator",
            target="arm64-apple-ios14.0-simulator",
            framework_slice="ios-arm64_x86_64-simulator",
        )

    @classmethod
    def tearDownClass(cls) -> None:
        cls._native_directory.cleanup()

    @staticmethod
    def _compile_native_fixture(
        source: Path,
        output: Path,
        *,
        sdk: str,
        target: str,
        framework_slice: str,
    ) -> None:
        framework_root = PYTHON_XCFRAMEWORK / framework_slice
        subprocess.run(
            [
                "xcrun",
                "--sdk",
                sdk,
                "clang",
                "-dynamiclib",
                "-target",
                target,
                "-I",
                str(framework_root / "include/python3.13"),
                "-F",
                str(framework_root),
                "-framework",
                "Python",
                "-Wl,-install_name,@rpath/fixture.framework/fixture",
                str(source),
                "-o",
                str(output),
            ],
            check=True,
            capture_output=True,
            text=True,
        )

    @staticmethod
    def _expected_tree(root: Path) -> dict[str, object]:
        digest = hashlib.sha256()
        file_count = 0
        total_bytes = 0
        files: list[Path] = []
        for slice_name in (DEVICE_SLICE, SIMULATOR_SLICE):
            files.extend(
                path
                for path in (root / slice_name).rglob("*")
                if path.is_file()
            )
        for path in sorted(
            files,
            key=lambda item: item.relative_to(root).as_posix(),
        ):
            relative = path.relative_to(root).as_posix()
            payload = path.read_bytes()
            file_digest = hashlib.sha256(payload).hexdigest()
            digest.update(relative.encode("utf-8"))
            digest.update(b"\0")
            digest.update(str(len(payload)).encode("ascii"))
            digest.update(b"\0")
            digest.update(file_digest.encode("ascii"))
            digest.update(b"\n")
            file_count += 1
            total_bytes += len(payload)
        return {
            "sha256": digest.hexdigest(),
            "fileCount": file_count,
            "totalBytes": total_bytes,
        }

    def _write_fixture(self, directory: Path) -> Path:
        packages_root = directory / "PythonPackages"
        packages_root.mkdir()
        (packages_root / "requirements.lock").write_bytes(
            canonical_requirements_lock()
        )
        (packages_root / "uvx-registry.json").write_bytes(
            canonical_uvx_registry()
        )
        artifact_by_name = {
            artifact.name: artifact for artifact in ARTIFACTS
        }
        for slice_name in (DEVICE_SLICE, SIMULATOR_SLICE):
            slice_root = packages_root / slice_name
            entrypoint = slice_root / "mcp_server_time/__init__.py"
            entrypoint.parent.mkdir(parents=True)
            entrypoint.write_text(
                "def main():\n    return 0\n",
                encoding="utf-8",
            )
            for artifact in ARTIFACTS:
                normalized = artifact.name.replace("-", "_")
                dist_info = (
                    slice_root
                    / f"{normalized}-{artifact.version}.dist-info"
                )
                dist_info.mkdir()
                (dist_info / "METADATA").write_text(
                    (
                        "Metadata-Version: 2.4\n"
                        f"Name: {artifact.name}\n"
                        f"Version: {artifact.version}\n"
                    ),
                    encoding="utf-8",
                )
                if artifact.name == PACKAGE_NAME:
                    (dist_info / "entry_points.txt").write_text(
                        (
                            "[console_scripts]\n"
                            "mcp-server-time = mcp_server_time:main\n"
                        ),
                        encoding="utf-8",
                    )

        for extension in NATIVE_EXTENSIONS:
            artifact = artifact_by_name[extension.package]
            self.assertEqual(artifact.kind, "sdist")
            for slice_name, relative_path in extension.paths.items():
                destination = packages_root / slice_name / relative_path
                destination.parent.mkdir(parents=True, exist_ok=True)
                source = (
                    self.device_fixture
                    if slice_name == DEVICE_SLICE
                    else self.simulator_fixture
                )
                shutil.copyfile(source, destination)
        return packages_root

    def test_exact_minimal_closure_and_source_artifact_hashes(self):
        self.assertEqual(PACKAGE_NAME, "mcp-server-time")
        self.assertEqual(PACKAGE_VERSION, "0.6.2")
        self.assertEqual(len(ARTIFACTS), 27)
        versions = {
            artifact.name: artifact.version for artifact in ARTIFACTS
        }
        self.assertEqual(versions["mcp"], "1.19.0")
        self.assertEqual(versions["mcp-server-time"], "0.6.2")
        self.assertEqual(versions["pydantic-core"], "2.46.4")
        self.assertEqual(versions["rpds-py"], "2026.6.3")
        artifacts = {artifact.name: artifact for artifact in ARTIFACTS}
        self.assertEqual(
            artifacts["mcp-server-time"].sha256,
            "6b67640eb9df3df834b3de5001e37ca8b0c997ce700b014882b585964094d116",
        )
        self.assertEqual(
            artifacts["pydantic-core"].sha256,
            "62f875393d7f270851f20523dd2e29f082bcc82292d66db2b64ea71f64b6e1c1",
        )
        self.assertEqual(
            artifacts["rpds-py"].sha256,
            "1cebd1337c242e4ec2293e541f712b2da849b29f48f0c293684b71c0632625d4",
        )
        self.assertEqual(artifacts["pydantic-core"].kind, "sdist")
        self.assertEqual(artifacts["rpds-py"].kind, "sdist")
        self.assertNotIn("cryptography", versions)
        self.assertNotIn("pyjwt", versions)

    def test_tree_identity_is_deterministic_and_ignores_mtime(self):
        with TemporaryDirectory() as directory:
            root = Path(directory)
            for slice_name, filenames in (
                (DEVICE_SLICE, ("z.py", "a.py")),
                (SIMULATOR_SLICE, ("b.py", "nested/a.py")),
            ):
                for filename in filenames:
                    path = root / slice_name / filename
                    path.parent.mkdir(parents=True, exist_ok=True)
                    path.write_text(
                        f"{slice_name}/{filename}\n",
                        encoding="utf-8",
                    )
            first = tree_identity(root)
            for path in root.rglob("*"):
                if path.is_file():
                    os.utime(path, (1, 1))
            second = tree_identity(root)
            self.assertEqual(first, second)
            self.assertEqual(first, self._expected_tree(root))

    def test_tree_identity_rejects_symlinks(self):
        with TemporaryDirectory() as directory:
            root = Path(directory)
            (root / DEVICE_SLICE).mkdir()
            (root / SIMULATOR_SLICE).mkdir()
            target = root / "outside.py"
            target.write_text("outside = True\n", encoding="utf-8")
            os.symlink(target, root / DEVICE_SLICE / "linked.py")
            with self.assertRaisesRegex(SnapshotError, "symbolic link"):
                tree_identity(root)

    def test_wheel_extraction_accepts_permission_only_zip_mode(self):
        with TemporaryDirectory() as directory:
            root = Path(directory)
            wheel = root / "fixture.whl"
            member = zipfile.ZipInfo("fixture/__init__.py")
            member.external_attr = 0o644 << 16
            with zipfile.ZipFile(wheel, "w") as archive:
                archive.writestr(member, b"value = 1\n")
            destination = root / "installed"
            destination.mkdir()
            _extract_wheel(wheel, destination)
            self.assertEqual(
                (destination / "fixture/__init__.py").read_bytes(),
                b"value = 1\n",
            )

    def test_generates_canonical_runtime_lock_and_uvx_registry(self):
        with TemporaryDirectory() as directory:
            root = self._write_fixture(Path(directory))
            first = generate_runtime_lock(root)
            lock_path = write_runtime_lock(root)
            first_bytes = lock_path.read_bytes()
            second = generate_runtime_lock(root)
            write_runtime_lock(root)

            self.assertEqual(first, second)
            self.assertEqual(first_bytes, lock_path.read_bytes())
            self.assertEqual(first["tree"], self._expected_tree(root))
            self.assertEqual(
                first["requirementsLockSha256"],
                hashlib.sha256(canonical_requirements_lock()).hexdigest(),
            )
            self.assertEqual(
                first["uvxRegistrySha256"],
                hashlib.sha256(canonical_uvx_registry()).hexdigest(),
            )
            self.assertEqual(
                json.loads(canonical_uvx_registry()),
                {
                    "mcp-server-time": "mcp_server_time",
                    "mcp-server-time@0.6.2": "mcp_server_time",
                    "mcp-server-time@latest": "mcp_server_time",
                },
            )
            self.assertEqual(
                first_bytes,
                (
                    json.dumps(
                        first,
                        ensure_ascii=False,
                        indent=2,
                        sort_keys=True,
                    )
                    + "\n"
                ).encode("utf-8"),
            )
            self.assertEqual(
                first["packages"],
                [
                    {
                        "name": "mcp-server-time",
                        "version": "0.6.2",
                        "entrypoint": "mcp_server_time",
                        "consoleScript": "mcp-server-time",
                    }
                ],
            )

    def test_verify_rejects_tree_and_requirements_lock_tampering(self):
        with TemporaryDirectory() as directory:
            root = self._write_fixture(Path(directory))
            write_runtime_lock(root)
            self.assertEqual(
                verify_runtime_lock(root),
                generate_runtime_lock(root),
            )

            entrypoint = root / DEVICE_SLICE / "mcp_server_time/__init__.py"
            original = entrypoint.read_bytes()
            entrypoint.write_bytes(original + b"# tampered\n")
            with self.assertRaisesRegex(
                SnapshotError,
                "runtime-lock.json does not match",
            ):
                verify_runtime_lock(root)

            entrypoint.write_bytes(original)
            (root / "requirements.lock").write_bytes(
                canonical_requirements_lock() + b"# tampered\n"
            )
            with self.assertRaisesRegex(
                SnapshotError,
                "requirements.lock",
            ):
                verify_runtime_lock(root)

    def test_native_extensions_are_real_arm64_ios_slices(self):
        device = validate_native_slice(
            self.device_fixture,
            expected_platform="IOS",
        )
        simulator = validate_native_slice(
            self.simulator_fixture,
            expected_platform="IOSSIMULATOR",
        )
        self.assertEqual(device["architectures"], ["arm64"])
        self.assertEqual(device["platform"], "IOS")
        self.assertEqual(simulator["architectures"], ["arm64"])
        self.assertEqual(simulator["platform"], "IOSSIMULATOR")
        self.assertTrue(device["linksPythonFramework"])
        self.assertTrue(simulator["linksPythonFramework"])
        with self.assertRaisesRegex(SnapshotError, "platform"):
            validate_native_slice(
                self.device_fixture,
                expected_platform="IOSSIMULATOR",
            )

    def test_native_build_environment_selects_each_ios_sdk(self):
        device = _native_build_environment(
            DEVICE_SLICE,
            base_environment={"PATH": os.environ["PATH"]},
        )
        simulator = _native_build_environment(
            SIMULATOR_SLICE,
            base_environment={"PATH": os.environ["PATH"]},
        )
        self.assertIn("iPhoneOS", device["SDKROOT"])
        self.assertEqual(device["IPHONEOS_DEPLOYMENT_TARGET"], "13.0")
        self.assertIn("iPhoneSimulator", simulator["SDKROOT"])
        self.assertEqual(
            simulator["IPHONEOS_DEPLOYMENT_TARGET"],
            "14.0",
        )

    def test_native_sbom_removes_only_volatile_build_identity(self):
        with TemporaryDirectory() as directory:
            root = Path(directory)
            first = root / "first.json"
            second = root / "second.json"
            common = {
                "bomFormat": "CycloneDX",
                "specVersion": "1.5",
                "version": 1,
                "metadata": {
                    "tools": [{"name": "cargo-cyclonedx"}],
                },
                "components": [{"name": "fixture", "version": "1.0"}],
            }
            for path, serial, timestamp in (
                (
                    first,
                    "urn:uuid:11111111-1111-4111-8111-111111111111",
                    "2026-08-04T15:00:00Z",
                ),
                (
                    second,
                    "urn:uuid:22222222-2222-4222-8222-222222222222",
                    "2026-08-04T16:00:00Z",
                ),
            ):
                payload = json.loads(json.dumps(common))
                payload["serialNumber"] = serial
                payload["metadata"]["timestamp"] = timestamp
                path.write_text(json.dumps(payload), encoding="utf-8")
                _normalize_native_sbom(path)
            self.assertEqual(first.read_bytes(), second.read_bytes())
            normalized = json.loads(first.read_text(encoding="utf-8"))
            self.assertNotIn("serialNumber", normalized)
            self.assertNotIn("timestamp", normalized["metadata"])
            self.assertEqual(
                normalized["components"],
                [{"name": "fixture", "version": "1.0"}],
            )

    def test_missing_or_wrong_native_slice_is_rejected(self):
        with TemporaryDirectory() as directory:
            root = self._write_fixture(Path(directory))
            simulator_extension = NATIVE_EXTENSIONS[0].paths[
                SIMULATOR_SLICE
            ]
            (root / SIMULATOR_SLICE / simulator_extension).unlink()
            with self.assertRaisesRegex(
                SnapshotError,
                "native extension is missing",
            ):
                generate_runtime_lock(root)

        with TemporaryDirectory() as directory:
            root = self._write_fixture(Path(directory))
            device_extension = NATIVE_EXTENSIONS[0].paths[DEVICE_SLICE]
            shutil.copyfile(
                self.simulator_fixture,
                root / DEVICE_SLICE / device_extension,
            )
            with self.assertRaisesRegex(SnapshotError, "platform"):
                generate_runtime_lock(root)


if __name__ == "__main__":
    unittest.main()
