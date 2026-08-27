import hashlib
import io
import json
import plistlib
import subprocess
import tarfile
import tempfile
import unittest
from pathlib import Path

from scripts import fetch_python_apple_runtime as runtime


class FetchPythonAppleRuntimeTests(unittest.TestCase):
    def make_archive(
        self,
        root: Path,
        *,
        unsafe: bool = False,
        unsafe_link: bool = False,
        missing_simulator: bool = False,
    ) -> Path:
        archive = root / runtime.ASSET_NAME
        info = {
            "AvailableLibraries": [
                {
                    "LibraryIdentifier": "ios-arm64",
                    "LibraryPath": "Python.framework",
                    "BinaryPath": "Python.framework/Python",
                    "SupportedArchitectures": ["arm64"],
                    "SupportedPlatform": "ios",
                },
            ],
        }
        if not missing_simulator:
            info["AvailableLibraries"].append(
                {
                    "LibraryIdentifier":
                        "ios-arm64_x86_64-simulator",
                    "LibraryPath": "Python.framework",
                    "BinaryPath": "Python.framework/Python",
                    "SupportedArchitectures": ["arm64", "x86_64"],
                    "SupportedPlatform": "ios",
                    "SupportedPlatformVariant": "simulator",
                }
            )
        members = {
            "Python.xcframework/Info.plist":
                plistlib.dumps(info),
            (
                "Python.xcframework/ios-arm64/"
                "Python.framework/Python"
            ): b"device",
            (
                "Python.xcframework/ios-arm64/"
                "Python.framework/Headers/Python.h"
            ): b"header",
            (
                "Python.xcframework/"
                "ios-arm64_x86_64-simulator/"
                "Python.framework/Python"
            ): b"simulator",
            "Python.xcframework/build/utils.sh":
                (
                    b"install_python() { :; }\n"
                    b'echo "$FRAMEWORK_FOLDER/$FULL_MODULE_NAME" '
                    b"> ${FULL_EXT%.so}.fwork\n"
                ),
            "Python.xcframework/lib/python3.13/os.py":
                b"# stdlib\n",
            "VERSIONS":
                b"Python version: 3.13.14 \nBuild: b14\n",
        }
        with tarfile.open(archive, "w:gz") as output:
            for name, payload in members.items():
                if missing_simulator and "simulator" in name:
                    continue
                info_member = tarfile.TarInfo(name)
                info_member.size = len(payload)
                output.addfile(info_member, io.BytesIO(payload))
            if unsafe:
                member = tarfile.TarInfo("../escape")
                member.size = 1
                output.addfile(member, io.BytesIO(b"x"))
            if unsafe_link:
                member = tarfile.TarInfo(
                    "Python.xcframework/ios-arm64/lib/escape"
                )
                member.type = tarfile.SYMTYPE
                member.linkname = "../../../../escape"
                output.addfile(member)
        return archive

    def test_runtime_lock_pins_exact_official_release(self) -> None:
        lock = runtime.runtime_lock()
        self.assertEqual(lock["runtime"], "CPython")
        self.assertEqual(lock["version"], "3.13.14")
        self.assertEqual(lock["abi"], "cp313")
        self.assertEqual(lock["sourceTag"], "3.13-b14")
        self.assertEqual(
            lock["sourceCommit"],
            "54d8ab6ef4fbac4d60706f311a986aee5236c71b",
        )
        self.assertEqual(lock["archiveBytes"], 32_387_292)
        self.assertEqual(
            lock["archiveSha256"],
            (
                "8b5cb76ef8d8a2946052479358eeec9d"
                "54b4496cb60920e175ec1489b5cf7963"
            ),
        )

    def test_extract_rejects_unsafe_tar_path(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            archive = self.make_archive(root, unsafe=True)
            with self.assertRaisesRegex(ValueError, "unsafe"):
                runtime.extract_runtime(archive, root / "out")

    def test_extract_rejects_symlink_outside_framework(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            archive = self.make_archive(root, unsafe_link=True)
            with self.assertRaisesRegex(ValueError, "unsafe link"):
                runtime.extract_runtime(archive, root / "out")

    def test_validate_requires_device_and_arm64_simulator(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            archive = self.make_archive(
                root,
                missing_simulator=True,
            )
            extracted = root / "out"
            runtime.extract_runtime(archive, extracted)
            with self.assertRaisesRegex(
                ValueError,
                "simulator",
            ):
                runtime.validate_runtime(extracted)

    def test_install_is_atomic_and_writes_verified_lock(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            archive = self.make_archive(root)
            digest = hashlib.sha256(archive.read_bytes()).hexdigest()
            destination = root / "vendor"
            destination.mkdir()
            (destination / "old").write_text("keep", encoding="utf-8")

            installed = runtime.install_runtime(
                destination,
                archive=archive,
                expected_bytes=archive.stat().st_size,
                expected_sha256=digest,
            )

            self.assertEqual(installed, destination.resolve())
            self.assertFalse((destination / "old").exists())
            self.assertTrue(
                (
                    destination
                    / "Python.xcframework/ios-arm64/"
                    "Python.framework/Python"
                ).is_file()
            )
            self.assertTrue((destination / "VERSIONS").is_file())
            lock = json.loads(
                (destination / "runtime-lock.json").read_text(
                    encoding="utf-8"
                )
            )
            self.assertEqual(lock["archiveBytes"], archive.stat().st_size)
            self.assertEqual(lock["archiveSha256"], digest)
            patched_utils = (
                destination
                / "Python.xcframework/build/utils.sh"
            )
            self.assertIn(
                '> "${FULL_EXT%.so}.fwork"',
                patched_utils.read_text(encoding="utf-8"),
            )
            self.assertEqual(
                lock["compatibilityPatches"],
                [
                    {
                        "id": "quote-fwork-placeholder-path",
                        "path": (
                            "Python.xcframework/build/utils.sh"
                        ),
                        "sha256": runtime.sha256_file(patched_utils),
                    }
                ],
            )

    def test_compatibility_patch_supports_app_name_with_spaces(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            archive = self.make_archive(root)
            extracted = root / "out"
            runtime.extract_runtime(archive, extracted)

            runtime.apply_runtime_compatibility_patches(extracted)

            helper = (
                extracted / "Python.xcframework/build/utils.sh"
            ).read_text(encoding="utf-8")
            line = next(
                item
                for item in helper.splitlines()
                if ".fwork" in item
            )
            extension = (
                root
                / "Codex for ipad.app/PythonPackages/"
                "site-packages/native.so"
            )
            extension.parent.mkdir(parents=True)
            result = subprocess.run(
                [
                    "/bin/bash",
                    "-c",
                    (
                        'FULL_EXT="$1"; '
                        'FRAMEWORK_FOLDER="Frameworks/native.framework"; '
                        'FULL_MODULE_NAME="native"; '
                        + line
                    ),
                    "bash",
                    str(extension),
                ],
                check=False,
                capture_output=True,
                text=True,
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(
                extension.with_suffix(".fwork").read_text(
                    encoding="utf-8"
                ),
                "Frameworks/native.framework/native\n",
            )

    def test_verify_archive_rejects_wrong_bytes_or_digest(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            archive = Path(temporary) / "runtime.tar.gz"
            archive.write_bytes(b"fixture")
            with self.assertRaisesRegex(ValueError, "size"):
                runtime.verify_archive(
                    archive,
                    expected_bytes=99,
                    expected_sha256="0" * 64,
                )
            with self.assertRaisesRegex(ValueError, "SHA256"):
                runtime.verify_archive(
                    archive,
                    expected_bytes=7,
                    expected_sha256="0" * 64,
                )


if __name__ == "__main__":
    unittest.main()
