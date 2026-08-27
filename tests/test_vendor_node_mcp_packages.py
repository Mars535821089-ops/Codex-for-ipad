import hashlib
import json
import os
import unittest
from pathlib import Path
from tempfile import TemporaryDirectory

from scripts.vendor_node_mcp_packages import (
    ENTRYPOINT,
    PACKAGE_NAME,
    PACKAGE_VERSION,
    SnapshotError,
    generate_runtime_lock,
    verify_runtime_lock,
    write_runtime_lock,
)


class VendorNodeMCPPackagesTests(unittest.TestCase):
    def _write_fixture(self, root: Path) -> Path:
        packages_root = root / "MCPPackages"
        package_directory = (
            packages_root
            / "node_modules"
            / "@modelcontextprotocol"
            / "server-filesystem"
        )
        (package_directory / "dist").mkdir(parents=True)
        (package_directory / "dist/index.js").write_text(
            "process.stdin.resume();\n",
            encoding="utf-8",
        )
        (package_directory / "package.json").write_text(
            json.dumps(
                {
                    "name": PACKAGE_NAME,
                    "version": PACKAGE_VERSION,
                    "type": "module",
                    "bin": {
                        "mcp-server-filesystem": "dist/index.js",
                    },
                },
                indent=2,
            )
            + "\n",
            encoding="utf-8",
        )
        dependency = (
            packages_root / "node_modules/dependency/index.js"
        )
        dependency.parent.mkdir(parents=True)
        dependency.write_text(
            "export const fixture = true;\n",
            encoding="utf-8",
        )
        package_json = {
            "name": "codex-for-ipad-mcp-packages",
            "private": True,
            "version": "1.0.0",
            "engines": {"node": ">=18.20.4"},
            "dependencies": {
                PACKAGE_NAME: PACKAGE_VERSION,
            },
        }
        (packages_root / "package.json").write_text(
            json.dumps(package_json, indent=2) + "\n",
            encoding="utf-8",
        )
        package_lock = {
            "name": "codex-for-ipad-mcp-packages",
            "version": "1.0.0",
            "lockfileVersion": 3,
            "requires": True,
            "packages": {
                "": {
                    "name": "codex-for-ipad-mcp-packages",
                    "version": "1.0.0",
                    "dependencies": {
                        PACKAGE_NAME: PACKAGE_VERSION,
                    },
                },
                (
                    "node_modules/"
                    "@modelcontextprotocol/server-filesystem"
                ): {
                    "version": PACKAGE_VERSION,
                    "bin": {
                        "mcp-server-filesystem": "dist/index.js",
                    },
                },
                "node_modules/dependency": {
                    "version": "1.0.0",
                },
            },
        }
        (packages_root / "package-lock.json").write_text(
            json.dumps(package_lock, indent=2) + "\n",
            encoding="utf-8",
        )
        return packages_root

    @staticmethod
    def _expected_tree(root: Path) -> dict[str, object]:
        node_modules = root / "node_modules"
        digest = hashlib.sha256()
        file_count = 0
        total_bytes = 0
        for path in sorted(
            item for item in node_modules.rglob("*") if item.is_file()
        ):
            relative = path.relative_to(node_modules).as_posix()
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

    def test_generates_deterministic_runtime_lock(self):
        with TemporaryDirectory() as directory:
            root = self._write_fixture(Path(directory))
            first = generate_runtime_lock(root)
            lock_path = write_runtime_lock(root)
            first_bytes = lock_path.read_bytes()
            second = generate_runtime_lock(root)
            write_runtime_lock(root)

            self.assertEqual(first, second)
            self.assertEqual(first_bytes, lock_path.read_bytes())
            self.assertTrue(first_bytes.endswith(b"\n"))
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
                first,
                {
                    "schemaVersion": 1,
                    "runtime": {
                        "name": "NodeMobile",
                        "version": "18.20.4",
                    },
                    "packageLockSha256": hashlib.sha256(
                        (root / "package-lock.json").read_bytes()
                    ).hexdigest(),
                    "tree": self._expected_tree(root),
                    "packages": [
                        {
                            "name": PACKAGE_NAME,
                            "version": PACKAGE_VERSION,
                            "entrypoint": ENTRYPOINT,
                        }
                    ],
                },
            )

    def test_verify_accepts_exact_snapshot_and_rejects_tree_drift(self):
        with TemporaryDirectory() as directory:
            root = self._write_fixture(Path(directory))
            write_runtime_lock(root)
            verified = verify_runtime_lock(root)
            self.assertEqual(verified, generate_runtime_lock(root))

            entrypoint = (
                root
                / "node_modules/@modelcontextprotocol/"
                "server-filesystem/dist/index.js"
            )
            entrypoint.write_text(
                "process.exit(7);\n",
                encoding="utf-8",
            )
            with self.assertRaisesRegex(
                SnapshotError,
                "runtime-lock.json does not match",
            ):
                verify_runtime_lock(root)

    def test_rejects_any_symlink_in_node_modules(self):
        with TemporaryDirectory() as directory:
            root = self._write_fixture(Path(directory))
            link = root / "node_modules/.bin/mcp-server-filesystem"
            link.parent.mkdir()
            os.symlink(
                "../@modelcontextprotocol/server-filesystem/dist/index.js",
                link,
            )
            with self.assertRaisesRegex(SnapshotError, "symbolic link"):
                generate_runtime_lock(root)

    def test_rejects_declared_locked_and_installed_version_drift(self):
        mutators = (
            self._mutate_declared_version,
            self._mutate_locked_version,
            self._mutate_installed_version,
        )
        for mutate in mutators:
            with self.subTest(mutate=mutate.__name__):
                with TemporaryDirectory() as directory:
                    root = self._write_fixture(Path(directory))
                    mutate(root)
                    with self.assertRaisesRegex(
                        SnapshotError,
                        "version",
                    ):
                        generate_runtime_lock(root)

    def test_rejects_missing_or_symlinked_entrypoint(self):
        for replacement in ("missing", "symlink"):
            with self.subTest(replacement=replacement):
                with TemporaryDirectory() as directory:
                    root = self._write_fixture(Path(directory))
                    entrypoint = (
                        root
                        / "node_modules/@modelcontextprotocol/"
                        "server-filesystem/dist/index.js"
                    )
                    entrypoint.unlink()
                    if replacement == "symlink":
                        target = root / "outside.js"
                        target.write_text(
                            "process.stdin.resume();\n",
                            encoding="utf-8",
                        )
                        os.symlink(target, entrypoint)
                    with self.assertRaisesRegex(
                        SnapshotError,
                        "entrypoint|symbolic link",
                    ):
                        generate_runtime_lock(root)

    @staticmethod
    def _mutate_declared_version(root: Path) -> None:
        path = root / "package.json"
        data = json.loads(path.read_text(encoding="utf-8"))
        data["dependencies"][PACKAGE_NAME] = "^2026.7.10"
        path.write_text(json.dumps(data) + "\n", encoding="utf-8")

    @staticmethod
    def _mutate_locked_version(root: Path) -> None:
        path = root / "package-lock.json"
        data = json.loads(path.read_text(encoding="utf-8"))
        key = (
            "node_modules/@modelcontextprotocol/server-filesystem"
        )
        data["packages"][key]["version"] = "2026.7.11"
        path.write_text(json.dumps(data) + "\n", encoding="utf-8")

    @staticmethod
    def _mutate_installed_version(root: Path) -> None:
        path = (
            root
            / "node_modules/@modelcontextprotocol/"
            "server-filesystem/package.json"
        )
        data = json.loads(path.read_text(encoding="utf-8"))
        data["version"] = "2026.7.11"
        path.write_text(json.dumps(data) + "\n", encoding="utf-8")


if __name__ == "__main__":
    unittest.main()
