#!/usr/bin/env python3
"""Create and verify the pinned Node MCP package snapshot manifest."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import stat
import sys
import tempfile
from pathlib import Path
from typing import Any, Iterable


SCHEMA_VERSION = 1
RUNTIME_NAME = "NodeMobile"
RUNTIME_VERSION = "18.20.4"
NODE_ENGINE = ">=18.20.4"
PACKAGE_NAME = "@modelcontextprotocol/server-filesystem"
PACKAGE_VERSION = "2026.7.10"
INSTALLED_ENTRYPOINT = (
    "node_modules/@modelcontextprotocol/"
    "server-filesystem/dist/index.js"
)
ENTRYPOINT = f"MCPPackages/{INSTALLED_ENTRYPOINT}"
LOCK_FILE_NAME = "runtime-lock.json"
DEFAULT_PACKAGES_ROOT = (
    Path(__file__).resolve().parents[1]
    / "CodexPad"
    / "CodexPad"
    / "Application"
    / "Resources"
    / "MCPPackages"
)


class SnapshotError(ValueError):
    """The vendored package tree does not match its pinned contract."""


def _duplicate_rejecting_object(
    pairs: Iterable[tuple[str, Any]],
) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise SnapshotError(f"duplicate JSON key: {key}")
        result[key] = value
    return result


def _read_json_object(path: Path, label: str) -> dict[str, Any]:
    if path.is_symlink():
        raise SnapshotError(f"{label} must not be a symbolic link")
    try:
        raw = path.read_bytes()
    except FileNotFoundError as error:
        raise SnapshotError(f"{label} is missing: {path}") from error
    except OSError as error:
        raise SnapshotError(f"{label} is unreadable: {path}") from error
    try:
        parsed = json.loads(
            raw.decode("utf-8"),
            object_pairs_hook=_duplicate_rejecting_object,
        )
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise SnapshotError(f"{label} is not valid UTF-8 JSON") from error
    if not isinstance(parsed, dict):
        raise SnapshotError(f"{label} must contain a JSON object")
    return parsed


def _require_exact_version(
    actual: object,
    *,
    source: str,
) -> None:
    if actual != PACKAGE_VERSION:
        raise SnapshotError(
            f"{source} version mismatch: "
            f"expected {PACKAGE_VERSION}, found {actual!r}"
        )


def _validate_package_metadata(
    packages_root: Path,
) -> bytes:
    package_json_path = packages_root / "package.json"
    package_json = _read_json_object(
        package_json_path,
        "package.json",
    )
    dependencies = package_json.get("dependencies")
    if not isinstance(dependencies, dict):
        raise SnapshotError(
            "package.json dependencies must be an object"
        )
    _require_exact_version(
        dependencies.get(PACKAGE_NAME),
        source="package.json dependency",
    )
    engines = package_json.get("engines")
    if not isinstance(engines, dict) or engines.get("node") != NODE_ENGINE:
        raise SnapshotError(
            "package.json Node engine mismatch: "
            f"expected {NODE_ENGINE!r}"
        )

    package_lock_path = packages_root / "package-lock.json"
    package_lock = _read_json_object(
        package_lock_path,
        "package-lock.json",
    )
    if package_lock.get("lockfileVersion") != 3:
        raise SnapshotError(
            "package-lock.json lockfileVersion must be 3"
        )
    locked_packages = package_lock.get("packages")
    if not isinstance(locked_packages, dict):
        raise SnapshotError(
            "package-lock.json packages must be an object"
        )
    locked_root = locked_packages.get("")
    if not isinstance(locked_root, dict):
        raise SnapshotError(
            "package-lock.json root package is missing"
        )
    locked_dependencies = locked_root.get("dependencies")
    if not isinstance(locked_dependencies, dict):
        raise SnapshotError(
            "package-lock.json root dependencies must be an object"
        )
    _require_exact_version(
        locked_dependencies.get(PACKAGE_NAME),
        source="package-lock.json root dependency",
    )
    locked_package_key = f"node_modules/{PACKAGE_NAME}"
    locked_package = locked_packages.get(locked_package_key)
    if not isinstance(locked_package, dict):
        raise SnapshotError(
            f"package-lock.json is missing {locked_package_key}"
        )
    _require_exact_version(
        locked_package.get("version"),
        source="package-lock.json installed package",
    )

    installed_package_path = (
        packages_root
        / "node_modules"
        / "@modelcontextprotocol"
        / "server-filesystem"
        / "package.json"
    )
    installed_package = _read_json_object(
        installed_package_path,
        "installed package.json",
    )
    if installed_package.get("name") != PACKAGE_NAME:
        raise SnapshotError(
            "installed package name mismatch: "
            f"expected {PACKAGE_NAME!r}"
        )
    _require_exact_version(
        installed_package.get("version"),
        source="installed package",
    )
    installed_bin = installed_package.get("bin")
    if (
        not isinstance(installed_bin, dict)
        or installed_bin.get("mcp-server-filesystem")
        != "dist/index.js"
    ):
        raise SnapshotError(
            "installed package entrypoint declaration mismatch"
        )

    entrypoint = packages_root / INSTALLED_ENTRYPOINT
    if entrypoint.is_symlink():
        raise SnapshotError(
            "MCP package entrypoint must not be a symbolic link"
        )
    if not entrypoint.is_file():
        raise SnapshotError(
            f"MCP package entrypoint is missing: {INSTALLED_ENTRYPOINT}"
        )
    return package_lock_path.read_bytes()


def _tree_files(node_modules: Path) -> list[Path]:
    if node_modules.is_symlink():
        raise SnapshotError(
            "node_modules must not be a symbolic link"
        )
    if not node_modules.is_dir():
        raise SnapshotError("node_modules directory is missing")

    files: list[Path] = []
    for directory, directory_names, file_names in os.walk(
        node_modules,
        topdown=True,
        followlinks=False,
    ):
        directory_names.sort()
        file_names.sort()
        current = Path(directory)
        for name in directory_names:
            path = current / name
            mode = path.lstat().st_mode
            if stat.S_ISLNK(mode):
                raise SnapshotError(
                    f"node_modules contains a symbolic link: "
                    f"{path.relative_to(node_modules).as_posix()}"
                )
            if not stat.S_ISDIR(mode):
                raise SnapshotError(
                    "node_modules contains a non-directory tree entry: "
                    f"{path.relative_to(node_modules).as_posix()}"
                )
        for name in file_names:
            path = current / name
            mode = path.lstat().st_mode
            if stat.S_ISLNK(mode):
                raise SnapshotError(
                    f"node_modules contains a symbolic link: "
                    f"{path.relative_to(node_modules).as_posix()}"
                )
            if not stat.S_ISREG(mode):
                raise SnapshotError(
                    "node_modules contains a non-regular file: "
                    f"{path.relative_to(node_modules).as_posix()}"
                )
            files.append(path)
    return sorted(
        files,
        key=lambda path: path.relative_to(node_modules).as_posix(),
    )


def _sha256_file(path: Path) -> tuple[str, int]:
    digest = hashlib.sha256()
    total = 0
    flags = os.O_RDONLY
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    descriptor = os.open(path, flags)
    try:
        metadata = os.fstat(descriptor)
        if not stat.S_ISREG(metadata.st_mode):
            raise SnapshotError(
                f"snapshot path is not a regular file: {path}"
            )
        while True:
            block = os.read(descriptor, 1024 * 1024)
            if not block:
                break
            digest.update(block)
            total += len(block)
        if total != metadata.st_size:
            raise SnapshotError(
                f"snapshot file changed while hashing: {path}"
            )
    finally:
        os.close(descriptor)
    return digest.hexdigest(), total


def _tree_identity(node_modules: Path) -> dict[str, object]:
    digest = hashlib.sha256()
    file_count = 0
    total_bytes = 0
    for path in _tree_files(node_modules):
        relative = path.relative_to(node_modules).as_posix()
        file_digest, size = _sha256_file(path)
        digest.update(relative.encode("utf-8"))
        digest.update(b"\0")
        digest.update(str(size).encode("ascii"))
        digest.update(b"\0")
        digest.update(file_digest.encode("ascii"))
        digest.update(b"\n")
        file_count += 1
        total_bytes += size
    if file_count == 0:
        raise SnapshotError("node_modules tree contains no files")
    return {
        "sha256": digest.hexdigest(),
        "fileCount": file_count,
        "totalBytes": total_bytes,
    }


def generate_runtime_lock(
    packages_root: Path,
) -> dict[str, object]:
    packages_root = Path(packages_root)
    if packages_root.is_symlink():
        raise SnapshotError(
            "MCPPackages root must not be a symbolic link"
        )
    if not packages_root.is_dir():
        raise SnapshotError(
            f"MCPPackages root is missing: {packages_root}"
        )
    tree = _tree_identity(packages_root / "node_modules")
    package_lock_bytes = _validate_package_metadata(packages_root)
    return {
        "schemaVersion": SCHEMA_VERSION,
        "runtime": {
            "name": RUNTIME_NAME,
            "version": RUNTIME_VERSION,
        },
        "packageLockSha256": hashlib.sha256(
            package_lock_bytes
        ).hexdigest(),
        "tree": tree,
        "packages": [
            {
                "name": PACKAGE_NAME,
                "version": PACKAGE_VERSION,
                "entrypoint": ENTRYPOINT,
            }
        ],
    }


def _canonical_json(payload: dict[str, object]) -> bytes:
    return (
        json.dumps(
            payload,
            ensure_ascii=False,
            indent=2,
            sort_keys=True,
        )
        + "\n"
    ).encode("utf-8")


def write_runtime_lock(packages_root: Path) -> Path:
    packages_root = Path(packages_root)
    payload = generate_runtime_lock(packages_root)
    encoded = _canonical_json(payload)
    temporary_path: Path | None = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="wb",
            prefix=f".{LOCK_FILE_NAME}.",
            dir=packages_root,
            delete=False,
        ) as stream:
            temporary_path = Path(stream.name)
            stream.write(encoded)
            stream.flush()
            os.fsync(stream.fileno())
        lock_path = packages_root / LOCK_FILE_NAME
        temporary_path.replace(lock_path)
        temporary_path = None
        return lock_path
    finally:
        if temporary_path is not None:
            temporary_path.unlink(missing_ok=True)


def verify_runtime_lock(
    packages_root: Path,
) -> dict[str, object]:
    packages_root = Path(packages_root)
    expected = generate_runtime_lock(packages_root)
    lock_path = packages_root / LOCK_FILE_NAME
    if lock_path.is_symlink():
        raise SnapshotError(
            "runtime-lock.json must not be a symbolic link"
        )
    try:
        actual_bytes = lock_path.read_bytes()
    except FileNotFoundError as error:
        raise SnapshotError("runtime-lock.json is missing") from error
    actual = _read_json_object(lock_path, "runtime-lock.json")
    if actual != expected or actual_bytes != _canonical_json(expected):
        raise SnapshotError(
            "runtime-lock.json does not match the vendored package tree"
        )
    return expected


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description=(
            "Generate or verify the deterministic Node MCP package lock"
        )
    )
    parser.add_argument(
        "--packages-root",
        "--root",
        dest="packages_root",
        type=Path,
        default=DEFAULT_PACKAGES_ROOT,
    )
    parser.add_argument(
        "--verify",
        action="store_true",
        help="verify the existing runtime-lock.json",
    )
    args = parser.parse_args(argv)
    try:
        if args.verify:
            payload = verify_runtime_lock(args.packages_root)
            action = "verified"
        else:
            write_runtime_lock(args.packages_root)
            payload = generate_runtime_lock(args.packages_root)
            action = "written"
    except (SnapshotError, OSError) as error:
        print(f"Node MCP package snapshot error: {error}", file=sys.stderr)
        return 1
    print(
        json.dumps(
            {
                "action": action,
                "packagesRoot": str(args.packages_root),
                "packageLockSha256": payload[
                    "packageLockSha256"
                ],
                "tree": payload["tree"],
            },
            sort_keys=True,
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
