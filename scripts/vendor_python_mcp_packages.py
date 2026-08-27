#!/usr/bin/env python3
"""Build and verify the deterministic iOS Python MCP package snapshot.

The snapshot contains two complete import roots.  Pure-Python wheels are
duplicated in both roots and the two Rust extensions are rebuilt from their
locked source distributions against the vendored BeeWare CPython runtime:

* ``ios-arm64`` for physical devices
* ``ios-arm64-simulator`` for Apple-silicon simulators

No host-platform wheel is accepted for a native extension.
"""

from __future__ import annotations

import argparse
import base64
import csv
import email.parser
import hashlib
import io
import json
import os
import re
import shutil
import stat
import subprocess
import sys
import tarfile
import tempfile
import urllib.request
import zipfile
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable, Mapping, Sequence


SCHEMA_VERSION = 1
RUNTIME_NAME = "CPython"
RUNTIME_VERSION = "3.13.14"
RUNTIME_ABI = "cp313"
RUNTIME_SOURCE_TAG = "3.13-b14"
RUNTIME_SOURCE_COMMIT = "54d8ab6ef4fbac4d60706f311a986aee5236c71b"
PACKAGE_NAME = "mcp-server-time"
PACKAGE_VERSION = "0.6.2"
PACKAGE_ENTRYPOINT = "mcp_server_time"
PACKAGE_CONSOLE_SCRIPT = "mcp-server-time"
DEVICE_SLICE = "ios-arm64"
SIMULATOR_SLICE = "ios-arm64-simulator"
LOCK_FILE_NAME = "runtime-lock.json"
REQUIREMENTS_FILE_NAME = "requirements.lock"
UVX_REGISTRY_FILE_NAME = "uvx-registry.json"

REPOSITORY_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_PACKAGES_ROOT = (
    REPOSITORY_ROOT
    / "CodexPad"
    / "CodexPad"
    / "Application"
    / "Resources"
    / "PythonPackages"
)
DEFAULT_RUNTIME_ROOT = (
    REPOSITORY_ROOT / "CodexPad" / "Vendor" / "python_apple"
)
DEFAULT_BUILD_ROOT = REPOSITORY_ROOT / ".build" / "python-mcp-snapshot"


class SnapshotError(ValueError):
    """The Python MCP snapshot does not match its pinned contract."""


@dataclass(frozen=True)
class LockedArtifact:
    """One exact PyPI input used to produce the snapshot."""

    name: str
    version: str
    filename: str
    url: str
    sha256: str
    size: int
    kind: str

    def manifest_value(self) -> dict[str, object]:
        return {
            "filename": self.filename,
            "kind": self.kind,
            "name": self.name,
            "sha256": self.sha256,
            "size": self.size,
            "url": self.url,
            "version": self.version,
        }


@dataclass(frozen=True)
class NativeExtension:
    """Expected native extension paths for each iOS import root."""

    package: str
    module: str
    paths: Mapping[str, str]


def _artifact(
    name: str,
    version: str,
    filename: str,
    sha256: str,
    size: int,
    url: str,
    kind: str = "wheel",
) -> LockedArtifact:
    return LockedArtifact(
        name=name,
        version=version,
        filename=filename,
        url=url,
        sha256=sha256,
        size=size,
        kind=kind,
    )


# The resolver target is CPython 3.13 on arm64 Apple platforms.  mcp 1.19.0
# is deliberately pinned: it is the newest release satisfying
# mcp-server-time 0.6.2 before the unused PyJWT/cryptography native chain was
# introduced.  This leaves exactly two native Python dependencies.
ARTIFACTS: tuple[LockedArtifact, ...] = (
    _artifact(
        "annotated-types",
        "0.8.0",
        "annotated_types-0.8.0-py3-none-any.whl",
        "f072f4d804ea359e4eaf198b1af7a8b0943881a87f31bb764f8bf219bb9419e0",
        13427,
        "https://files.pythonhosted.org/packages/99/91/8acff4f5e50511b911bbccb72b8628a49c68ce14148cd9f6431094859a90/annotated_types-0.8.0-py3-none-any.whl",
    ),
    _artifact(
        "anyio",
        "4.14.2",
        "anyio-4.14.2-py3-none-any.whl",
        "9f505dda5ac9f0c8309b5e8bd445a8c2bf7246f3ce950121e45ea15bc41d1494",
        125813,
        "https://files.pythonhosted.org/packages/da/35/f2287558c17e29fafc8ef3daf819bb9834061cfa43bff8014f7df7f63bdc/anyio-4.14.2-py3-none-any.whl",
    ),
    _artifact(
        "attrs",
        "26.1.0",
        "attrs-26.1.0-py3-none-any.whl",
        "c647aa4a12dfbad9333ca4e71fe62ddc36f4e63b2d260a37a8b83d2f043ac309",
        67548,
        "https://files.pythonhosted.org/packages/64/b4/17d4b0b2a2dc85a6df63d1157e028ed19f90d4cd97c36717afef2bc2f395/attrs-26.1.0-py3-none-any.whl",
    ),
    _artifact(
        "certifi",
        "2026.7.22",
        "certifi-2026.7.22-py3-none-any.whl",
        "62f22742b58a1a33014a2b6b706588a8d7e2a88ae7bd1a6ebe8c992928483775",
        136983,
        "https://files.pythonhosted.org/packages/0b/a7/71ac2cff56fec219ed242bb11b8efb69fcc4bec75db06fb7bfe35de520e6/certifi-2026.7.22-py3-none-any.whl",
    ),
    _artifact(
        "click",
        "8.4.2",
        "click-8.4.2-py3-none-any.whl",
        "e6f9f66136c816745b9d65817da91d61d957fb16e02e4dcd0552553c5a197b76",
        119243,
        "https://files.pythonhosted.org/packages/fb/e2/79c688af8b210d232694e31e59da9f6ec747bae31c3f5946e4e9b98860d5/click-8.4.2-py3-none-any.whl",
    ),
    _artifact(
        "h11",
        "0.16.0",
        "h11-0.16.0-py3-none-any.whl",
        "63cf8bbe7522de3bf65932fda1d9c2772064ffb3dae62d55932da54b31cb6c86",
        37515,
        "https://files.pythonhosted.org/packages/04/4b/29cac41a4d98d144bf5f6d33995617b185d14b22401f75ca86f384e87ff1/h11-0.16.0-py3-none-any.whl",
    ),
    _artifact(
        "httpcore",
        "1.0.9",
        "httpcore-1.0.9-py3-none-any.whl",
        "2d400746a40668fc9dec9810239072b40b4484b640a8c38fd654a024c7a1bf55",
        78784,
        "https://files.pythonhosted.org/packages/7e/f5/f66802a942d491edb555dd61e3a9961140fd64c90bce1eafd741609d334d/httpcore-1.0.9-py3-none-any.whl",
    ),
    _artifact(
        "httpx",
        "0.28.1",
        "httpx-0.28.1-py3-none-any.whl",
        "d909fcccc110f8c7faf814ca82a9a4d816bc5a6dbfea25d6591d6985b8ba59ad",
        73517,
        "https://files.pythonhosted.org/packages/2a/39/e50c7c3a983047577ee07d2a9e53faf5a69493943ec3f6a384bdc792deb2/httpx-0.28.1-py3-none-any.whl",
    ),
    _artifact(
        "httpx-sse",
        "0.4.3",
        "httpx_sse-0.4.3-py3-none-any.whl",
        "0ac1c9fe3c0afad2e0ebb25a934a59f4c7823b60792691f779fad2c5568830fc",
        8960,
        "https://files.pythonhosted.org/packages/d2/fd/6668e5aec43ab844de6fc74927e155a3b37bf40d7c3790e49fc0406b6578/httpx_sse-0.4.3-py3-none-any.whl",
    ),
    _artifact(
        "idna",
        "3.18",
        "idna-3.18-py3-none-any.whl",
        "7f952cbe720b688055e3f87de14f5c3e5fdaa8bc3928985c4077ca689de849a2",
        65455,
        "https://files.pythonhosted.org/packages/1e/5e/d4e9f1a599fb8e573b7b87160658329fbf28d19eac2718f51fc3def3aa5a/idna-3.18-py3-none-any.whl",
    ),
    _artifact(
        "jsonschema",
        "4.26.0",
        "jsonschema-4.26.0-py3-none-any.whl",
        "d489f15263b8d200f8387e64b4c3a75f06629559fb73deb8fdfb525f2dab50ce",
        90630,
        "https://files.pythonhosted.org/packages/69/90/f63fb5873511e014207a475e2bb4e8b2e570d655b00ac19a9a0ca0a385ee/jsonschema-4.26.0-py3-none-any.whl",
    ),
    _artifact(
        "jsonschema-specifications",
        "2025.9.1",
        "jsonschema_specifications-2025.9.1-py3-none-any.whl",
        "98802fee3a11ee76ecaca44429fda8a41bff98b00a0f2838151b113f210cc6fe",
        18437,
        "https://files.pythonhosted.org/packages/41/45/1a4ed80516f02155c51f51e8cedb3c1902296743db0bbc66608a0db2814f/jsonschema_specifications-2025.9.1-py3-none-any.whl",
    ),
    _artifact(
        "mcp",
        "1.19.0",
        "mcp-1.19.0-py3-none-any.whl",
        "f5907fe1c0167255f916718f376d05f09a830a215327a3ccdd5ec8a519f2e572",
        170105,
        "https://files.pythonhosted.org/packages/ce/a3/3e71a875a08b6a830b88c40bc413bff01f1650f1efe8a054b5e90a9d4f56/mcp-1.19.0-py3-none-any.whl",
    ),
    _artifact(
        "mcp-server-time",
        "0.6.2",
        "mcp_server_time-0.6.2-py3-none-any.whl",
        "6b67640eb9df3df834b3de5001e37ca8b0c997ce700b014882b585964094d116",
        5693,
        "https://files.pythonhosted.org/packages/f6/71/e5b546bbe8769be4608728624ad4c4c51c93243a124e527b39465bcf559e/mcp_server_time-0.6.2-py3-none-any.whl",
    ),
    _artifact(
        "pydantic",
        "2.13.4",
        "pydantic-2.13.4-py3-none-any.whl",
        "45a282cde31d808236fd7ea9d919b128653c8b38b393d1c4ab335c62924d9aba",
        472262,
        "https://files.pythonhosted.org/packages/fd/7b/122376b1fd3c62c1ed9dc80c931ace4844b3c55407b6fb2d199377c9736f/pydantic-2.13.4-py3-none-any.whl",
    ),
    _artifact(
        "pydantic-core",
        "2.46.4",
        "pydantic_core-2.46.4.tar.gz",
        "62f875393d7f270851f20523dd2e29f082bcc82292d66db2b64ea71f64b6e1c1",
        471464,
        "https://files.pythonhosted.org/packages/9d/56/921726b776ace8d8f5db44c4ef961006580d91dc52b803c489fafd1aa249/pydantic_core-2.46.4.tar.gz",
        "sdist",
    ),
    _artifact(
        "pydantic-settings",
        "2.14.2",
        "pydantic_settings-2.14.2-py3-none-any.whl",
        "a20c97b37910b6550d5ea50fbcc2d4187defe58cd57070b73863d069419c9440",
        61715,
        "https://files.pythonhosted.org/packages/77/c1/6e422f34e569cf8e18df68d1939c81c099d2b61e4f7d9621c8a77560799c/pydantic_settings-2.14.2-py3-none-any.whl",
    ),
    _artifact(
        "python-dotenv",
        "1.2.2",
        "python_dotenv-1.2.2-py3-none-any.whl",
        "1d8214789a24de455a8b8bd8ae6fe3c6b69a5e3d64aa8a8e5d68e694bbcb285a",
        22101,
        "https://files.pythonhosted.org/packages/0b/d7/1959b9648791274998a9c3526f6d0ec8fd2233e4d4acce81bbae76b44b2a/python_dotenv-1.2.2-py3-none-any.whl",
    ),
    _artifact(
        "python-multipart",
        "0.0.32",
        "python_multipart-0.0.32-py3-none-any.whl",
        "ff6d3f776f16878c894e52e107296ffc890e913c611b1a4ec6c44e2821fe2e23",
        30042,
        "https://files.pythonhosted.org/packages/e1/04/e8135ebd1ad02c56ec633277529b2602ff99ff634be76cdba5744cf554fd/python_multipart-0.0.32-py3-none-any.whl",
    ),
    _artifact(
        "referencing",
        "0.37.0",
        "referencing-0.37.0-py3-none-any.whl",
        "381329a9f99628c9069361716891d34ad94af76e461dcb0335825aecc7692231",
        26766,
        "https://files.pythonhosted.org/packages/2c/58/ca301544e1fa93ed4f80d724bf5b194f6e4b945841c5bfd555878eea9fcb/referencing-0.37.0-py3-none-any.whl",
    ),
    _artifact(
        "rpds-py",
        "2026.6.3",
        "rpds_py-2026.6.3.tar.gz",
        "1cebd1337c242e4ec2293e541f712b2da849b29f48f0c293684b71c0632625d4",
        64051,
        "https://files.pythonhosted.org/packages/aa/2a/9618a122aeb2a169a28b03889a2995fe297588964333d4a7d67bdf46e147/rpds_py-2026.6.3.tar.gz",
        "sdist",
    ),
    _artifact(
        "sse-starlette",
        "3.4.6",
        "sse_starlette-3.4.6-py3-none-any.whl",
        "56217ab4c9a9f9c5db7b21e08732d3e7c2b807f45231ad23de0551a24c4a41f6",
        16516,
        "https://files.pythonhosted.org/packages/49/36/e10c1d1b7ca881d2625db2ec28508578499187bb1c389952c398474e1834/sse_starlette-3.4.6-py3-none-any.whl",
    ),
    _artifact(
        "starlette",
        "1.3.1",
        "starlette-1.3.1-py3-none-any.whl",
        "c7372aae11c3c3f26a42df7bd626cec2f47d03483d261d369516a615a53714c6",
        73632,
        "https://files.pythonhosted.org/packages/ec/bb/2799cc2ede3ed41131f8975621e7213dfc7ef4acbbaadfa440f32500c370/starlette-1.3.1-py3-none-any.whl",
    ),
    _artifact(
        "typing-extensions",
        "4.16.0",
        "typing_extensions-4.16.0-py3-none-any.whl",
        "481caa481374e813c1b176ada14e97f1f67a4539ce9cfeb3f350d78d6370c2e8",
        45571,
        "https://files.pythonhosted.org/packages/49/d3/b8441a820a491ddfc024b0b0cf0393375b75ea13866d9c66727e54c2fc80/typing_extensions-4.16.0-py3-none-any.whl",
    ),
    _artifact(
        "typing-inspection",
        "0.4.2",
        "typing_inspection-0.4.2-py3-none-any.whl",
        "4ed1cacbdc298c220f1bd249ed5287caa16f34d44ef4e9c3d0cbad5b521545e7",
        14611,
        "https://files.pythonhosted.org/packages/dc/9b/47798a6c91d8bdb567fe2698fe81e0c6b7cb7ef4d13da4114b41d239f65d/typing_inspection-0.4.2-py3-none-any.whl",
    ),
    _artifact(
        "tzdata",
        "2026.3",
        "tzdata-2026.3-py2.py3-none-any.whl",
        "dc096730c87af6cab1b171c9d532be840741ff5d459015e7f6947bd7d7e54931",
        348168,
        "https://files.pythonhosted.org/packages/e5/6d/b53b99a9f2766d095985947a5782f1702cabb129a34f7a802d7197af832f/tzdata-2026.3-py2.py3-none-any.whl",
    ),
    _artifact(
        "uvicorn",
        "0.52.1",
        "uvicorn-0.52.1-py3-none-any.whl",
        "e4403f9d93188cf9d1088e9f40e3acd12630e2df8675316704379a7fc20fff6a",
        79859,
        "https://files.pythonhosted.org/packages/c7/d5/68e6e9bca63c0badf67002890a46d3784c958de45b65e1275ec583ca1f06/uvicorn-0.52.1-py3-none-any.whl",
    ),
)

NATIVE_EXTENSIONS: tuple[NativeExtension, ...] = (
    NativeExtension(
        package="pydantic-core",
        module="pydantic_core._pydantic_core",
        paths={
            DEVICE_SLICE: (
                "pydantic_core/"
                "_pydantic_core.cpython-313-iphoneos.so"
            ),
            SIMULATOR_SLICE: (
                "pydantic_core/"
                "_pydantic_core.cpython-313-iphonesimulator.so"
            ),
        },
    ),
    NativeExtension(
        package="rpds-py",
        module="rpds.rpds",
        paths={
            DEVICE_SLICE: "rpds/rpds.cpython-313-iphoneos.so",
            SIMULATOR_SLICE: (
                "rpds/rpds.cpython-313-iphonesimulator.so"
            ),
        },
    ),
)

SLICE_CONTRACTS: Mapping[str, Mapping[str, str]] = {
    DEVICE_SLICE: {
        "cargoTarget": "aarch64-apple-ios",
        "expectedPlatform": "IOS",
        "frameworkSlice": "ios-arm64",
        "minimumOS": "13.0",
        "platformConfig": "arm64-iphoneos",
        "sdk": "iphoneos",
    },
    SIMULATOR_SLICE: {
        "cargoTarget": "aarch64-apple-ios-sim",
        "expectedPlatform": "IOSSIMULATOR",
        "frameworkSlice": "ios-arm64_x86_64-simulator",
        "minimumOS": "14.0",
        "platformConfig": "arm64-iphonesimulator",
        "sdk": "iphonesimulator",
    },
}


def _canonical_name(value: str) -> str:
    return re.sub(r"[-_.]+", "-", value).lower()


def canonical_requirements_lock() -> bytes:
    """Return the exact hash-locked Python dependency closure."""

    lines = [
        "# Generated by scripts/vendor_python_mcp_packages.py.",
        "# Resolver target: CPython 3.13, arm64 Apple platforms.",
        "# mcp==1.19.0 is the highest compatible release before the",
        "# unused PyJWT/cryptography native dependency chain.",
    ]
    for artifact in ARTIFACTS:
        lines.extend(
            (
                f"{artifact.name}=={artifact.version} \\",
                f"    --hash=sha256:{artifact.sha256}",
            )
        )
    return ("\n".join(lines) + "\n").encode("utf-8")


def canonical_uvx_registry() -> bytes:
    """Return the exact uvx specifier-to-module registry."""

    return _canonical_json(
        {
            PACKAGE_NAME: PACKAGE_ENTRYPOINT,
            f"{PACKAGE_NAME}@{PACKAGE_VERSION}": PACKAGE_ENTRYPOINT,
            f"{PACKAGE_NAME}@latest": PACKAGE_ENTRYPOINT,
        }
    )


def _canonical_json(payload: Mapping[str, object]) -> bytes:
    return (
        json.dumps(
            payload,
            ensure_ascii=False,
            indent=2,
            sort_keys=True,
        )
        + "\n"
    ).encode("utf-8")


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


def _sha256_file(path: Path) -> tuple[str, int]:
    digest = hashlib.sha256()
    total = 0
    flags = os.O_RDONLY
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    try:
        descriptor = os.open(path, flags)
    except OSError as error:
        raise SnapshotError(f"snapshot file is unreadable: {path}") from error
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


def _safe_tree_files(root: Path) -> list[Path]:
    if root.is_symlink():
        raise SnapshotError(
            f"snapshot root must not be a symbolic link: {root}"
        )
    if not root.is_dir():
        raise SnapshotError(f"snapshot directory is missing: {root}")
    files: list[Path] = []
    for directory, directory_names, file_names in os.walk(
        root,
        topdown=True,
        followlinks=False,
    ):
        directory_names.sort()
        file_names.sort()
        current = Path(directory)
        for name in directory_names:
            path = current / name
            mode = path.lstat().st_mode
            relative = path.relative_to(root).as_posix()
            if stat.S_ISLNK(mode):
                raise SnapshotError(
                    f"snapshot contains a symbolic link: {relative}"
                )
            if not stat.S_ISDIR(mode):
                raise SnapshotError(
                    "snapshot contains a non-directory tree entry: "
                    f"{relative}"
                )
        for name in file_names:
            path = current / name
            mode = path.lstat().st_mode
            relative = path.relative_to(root).as_posix()
            if stat.S_ISLNK(mode):
                raise SnapshotError(
                    f"snapshot contains a symbolic link: {relative}"
                )
            if not stat.S_ISREG(mode):
                raise SnapshotError(
                    f"snapshot contains a non-regular file: {relative}"
                )
            files.append(path)
    return sorted(files, key=lambda path: path.relative_to(root).as_posix())


def tree_identity(packages_root: Path) -> dict[str, object]:
    """Hash both complete import roots without following links."""

    packages_root = Path(packages_root)
    files: list[Path] = []
    for slice_name in (DEVICE_SLICE, SIMULATOR_SLICE):
        files.extend(_safe_tree_files(packages_root / slice_name))
    files.sort(key=lambda path: path.relative_to(packages_root).as_posix())
    digest = hashlib.sha256()
    total_bytes = 0
    for path in files:
        relative = path.relative_to(packages_root).as_posix()
        file_digest, size = _sha256_file(path)
        digest.update(relative.encode("utf-8"))
        digest.update(b"\0")
        digest.update(str(size).encode("ascii"))
        digest.update(b"\0")
        digest.update(file_digest.encode("ascii"))
        digest.update(b"\n")
        total_bytes += size
    if not files:
        raise SnapshotError("Python package slice trees contain no files")
    return {
        "sha256": digest.hexdigest(),
        "fileCount": len(files),
        "totalBytes": total_bytes,
    }


def _run_checked(
    command: Sequence[str],
    *,
    cwd: Path | None = None,
    env: Mapping[str, str] | None = None,
) -> str:
    try:
        result = subprocess.run(
            list(command),
            cwd=cwd,
            env=dict(env) if env is not None else None,
            check=True,
            capture_output=True,
            text=True,
        )
    except FileNotFoundError as error:
        raise SnapshotError(f"required command is missing: {command[0]}") from error
    except subprocess.CalledProcessError as error:
        detail = (error.stderr or error.stdout or "").strip()
        raise SnapshotError(
            f"command failed ({' '.join(command)}): {detail}"
        ) from error
    return result.stdout


def validate_native_slice(
    path: Path,
    *,
    expected_platform: str,
) -> dict[str, object]:
    """Validate and describe one real arm64 iOS Mach-O extension."""

    path = Path(path)
    if path.is_symlink():
        raise SnapshotError(
            f"native extension must not be a symbolic link: {path}"
        )
    if not path.is_file():
        raise SnapshotError(f"native extension is missing: {path}")

    file_description = _run_checked(("file", "-b", str(path))).strip()
    if "Mach-O 64-bit" not in file_description or "arm64" not in file_description:
        raise SnapshotError(
            f"native extension is not an arm64 Mach-O binary: {path}"
        )
    architectures = _run_checked(("lipo", "-archs", str(path))).split()
    if architectures != ["arm64"]:
        raise SnapshotError(
            "native extension architecture mismatch: "
            f"expected arm64, found {architectures!r}: {path}"
        )

    build_description = _run_checked(
        ("xcrun", "vtool", "-show-build", str(path))
    )
    platforms = re.findall(
        r"^\s*platform\s+([A-Z0-9_]+)\s*$",
        build_description,
        flags=re.MULTILINE,
    )
    if len(platforms) != 1:
        raise SnapshotError(
            f"native extension has no unique LC_BUILD_VERSION platform: {path}"
        )
    platform = platforms[0]
    if platform != expected_platform:
        raise SnapshotError(
            "native extension platform mismatch: "
            f"expected {expected_platform}, found {platform}: {path}"
        )
    minimum_versions = re.findall(
        r"^\s*minos\s+([0-9.]+)\s*$",
        build_description,
        flags=re.MULTILINE,
    )
    if len(minimum_versions) != 1:
        raise SnapshotError(
            f"native extension has no unique minimum OS version: {path}"
        )

    linked = _run_checked(("otool", "-L", str(path)))
    dependencies = [
        line.strip().split(" (", 1)[0]
        for line in linked.splitlines()[1:]
        if line.strip()
    ]
    links_python = "@rpath/Python.framework/Python" in dependencies
    if not links_python:
        raise SnapshotError(
            f"native extension does not link the vendored Python framework: {path}"
        )
    forbidden = [
        dependency
        for dependency in dependencies
        if dependency.startswith("/")
        and not dependency.startswith("/usr/lib/")
        and not dependency.startswith("/System/Library/")
    ]
    if forbidden:
        raise SnapshotError(
            "native extension contains host-absolute dependencies: "
            f"{forbidden!r}"
        )
    digest, size = _sha256_file(path)
    return {
        "architectures": architectures,
        "dependencies": dependencies,
        "fileDescription": file_description,
        "linksPythonFramework": links_python,
        "minimumOS": minimum_versions[0],
        "platform": platform,
        "sha256": digest,
        "size": size,
    }


def _validate_exact_file(path: Path, expected: bytes, label: str) -> bytes:
    if path.is_symlink():
        raise SnapshotError(f"{label} must not be a symbolic link")
    try:
        actual = path.read_bytes()
    except FileNotFoundError as error:
        raise SnapshotError(f"{label} is missing: {path}") from error
    if actual != expected:
        raise SnapshotError(f"{label} does not match the pinned contract")
    return actual


def _metadata_headers(path: Path) -> Mapping[str, str]:
    if path.is_symlink() or not path.is_file():
        raise SnapshotError(f"installed METADATA is missing: {path}")
    try:
        return email.parser.BytesParser().parsebytes(path.read_bytes())
    except (OSError, ValueError) as error:
        raise SnapshotError(f"installed METADATA is invalid: {path}") from error


def _validate_installed_distributions(slice_root: Path) -> None:
    expected = {
        _canonical_name(artifact.name): artifact for artifact in ARTIFACTS
    }
    actual: dict[str, tuple[str, Path]] = {}
    for dist_info in sorted(slice_root.glob("*.dist-info")):
        if dist_info.is_symlink() or not dist_info.is_dir():
            raise SnapshotError(
                f"installed dist-info is not a directory: {dist_info}"
            )
        headers = _metadata_headers(dist_info / "METADATA")
        name = headers.get("Name")
        version = headers.get("Version")
        if not name or not version:
            raise SnapshotError(
                f"installed METADATA lacks Name or Version: {dist_info}"
            )
        canonical = _canonical_name(name)
        if canonical in actual:
            raise SnapshotError(
                f"duplicate installed distribution: {canonical}"
            )
        actual[canonical] = (version, dist_info)
    if set(actual) != set(expected):
        missing = sorted(set(expected) - set(actual))
        extra = sorted(set(actual) - set(expected))
        raise SnapshotError(
            "installed dependency closure mismatch: "
            f"missing={missing!r}, extra={extra!r}"
        )
    for name, artifact in expected.items():
        actual_version, _ = actual[name]
        if actual_version != artifact.version:
            raise SnapshotError(
                f"installed {artifact.name} version mismatch: "
                f"expected {artifact.version}, found {actual_version}"
            )

    entrypoint = slice_root / PACKAGE_ENTRYPOINT / "__init__.py"
    if entrypoint.is_symlink() or not entrypoint.is_file():
        raise SnapshotError(
            f"Python MCP entrypoint package is missing: {entrypoint}"
        )
    server_distribution = actual[_canonical_name(PACKAGE_NAME)][1]
    entry_points_path = server_distribution / "entry_points.txt"
    if entry_points_path.is_symlink() or not entry_points_path.is_file():
        raise SnapshotError(
            f"Python MCP console-script metadata is missing: {entry_points_path}"
        )
    entry_points = entry_points_path.read_text(encoding="utf-8")
    declaration = re.search(
        rf"(?m)^\s*{re.escape(PACKAGE_CONSOLE_SCRIPT)}\s*=\s*"
        rf"{re.escape(PACKAGE_ENTRYPOINT)}(?::[A-Za-z_][A-Za-z0-9_]*)?\s*$",
        entry_points,
    )
    if declaration is None:
        raise SnapshotError(
            "Python MCP console-script declaration does not match "
            f"{PACKAGE_CONSOLE_SCRIPT} -> {PACKAGE_ENTRYPOINT}"
        )


def _native_manifest(packages_root: Path) -> list[dict[str, object]]:
    result: list[dict[str, object]] = []
    for extension in NATIVE_EXTENSIONS:
        slices: dict[str, object] = {}
        for slice_name in (DEVICE_SLICE, SIMULATOR_SLICE):
            relative = extension.paths[slice_name]
            contract = SLICE_CONTRACTS[slice_name]
            inspected = validate_native_slice(
                packages_root / slice_name / relative,
                expected_platform=contract["expectedPlatform"],
            )
            slices[slice_name] = {
                "cargoTarget": contract["cargoTarget"],
                "path": relative,
                **inspected,
            }
        result.append(
            {
                "module": extension.module,
                "package": extension.package,
                "slices": slices,
            }
        )
    return result


def generate_runtime_lock(packages_root: Path) -> dict[str, object]:
    """Generate the complete manifest from an existing snapshot tree."""

    packages_root = Path(packages_root)
    if packages_root.is_symlink():
        raise SnapshotError(
            "PythonPackages root must not be a symbolic link"
        )
    if not packages_root.is_dir():
        raise SnapshotError(
            f"PythonPackages root is missing: {packages_root}"
        )
    requirements = _validate_exact_file(
        packages_root / REQUIREMENTS_FILE_NAME,
        canonical_requirements_lock(),
        REQUIREMENTS_FILE_NAME,
    )
    registry = _validate_exact_file(
        packages_root / UVX_REGISTRY_FILE_NAME,
        canonical_uvx_registry(),
        UVX_REGISTRY_FILE_NAME,
    )
    for slice_name in (DEVICE_SLICE, SIMULATOR_SLICE):
        _validate_installed_distributions(packages_root / slice_name)
    native_extensions = _native_manifest(packages_root)
    tree = tree_identity(packages_root)
    return {
        "schemaVersion": SCHEMA_VERSION,
        "runtime": {
            "abi": RUNTIME_ABI,
            "name": RUNTIME_NAME,
            "sourceCommit": RUNTIME_SOURCE_COMMIT,
            "sourceTag": RUNTIME_SOURCE_TAG,
            "version": RUNTIME_VERSION,
        },
        "requirementsLockSha256": hashlib.sha256(requirements).hexdigest(),
        "uvxRegistrySha256": hashlib.sha256(registry).hexdigest(),
        "resolution": {
            "artifactCount": len(ARTIFACTS),
            "mcpPin": "1.19.0",
            "reason": (
                "highest compatible mcp release before the unused "
                "PyJWT/cryptography native dependency chain"
            ),
            "target": "CPython 3.13 arm64 Apple platforms",
        },
        "dependencyArtifacts": [
            artifact.manifest_value() for artifact in ARTIFACTS
        ],
        "nativeExtensions": native_extensions,
        "snapshotRoots": [DEVICE_SLICE, SIMULATOR_SLICE],
        "tree": tree,
        "packages": [
            {
                "name": PACKAGE_NAME,
                "version": PACKAGE_VERSION,
                "entrypoint": PACKAGE_ENTRYPOINT,
                "consoleScript": PACKAGE_CONSOLE_SCRIPT,
            }
        ],
    }


def write_runtime_lock(packages_root: Path) -> Path:
    """Atomically write ``runtime-lock.json`` for an existing tree."""

    packages_root = Path(packages_root)
    encoded = _canonical_json(generate_runtime_lock(packages_root))
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


def verify_runtime_lock(packages_root: Path) -> dict[str, object]:
    """Verify the manifest, metadata, complete tree, and native slices."""

    packages_root = Path(packages_root)
    expected = generate_runtime_lock(packages_root)
    lock_path = packages_root / LOCK_FILE_NAME
    actual = _read_json_object(lock_path, LOCK_FILE_NAME)
    try:
        actual_bytes = lock_path.read_bytes()
    except OSError as error:
        raise SnapshotError(f"{LOCK_FILE_NAME} is unreadable") from error
    if actual != expected or actual_bytes != _canonical_json(expected):
        raise SnapshotError(
            "runtime-lock.json does not match the vendored package tree"
        )
    return expected


def _download_artifact(
    artifact: LockedArtifact,
    cache_root: Path,
) -> Path:
    cache_root.mkdir(parents=True, exist_ok=True)
    destination = cache_root / artifact.filename
    if destination.exists():
        digest, size = _sha256_file(destination)
        if digest == artifact.sha256 and size == artifact.size:
            return destination
        destination.unlink()
    temporary = destination.with_name(
        f".{destination.name}.{os.getpid()}.download"
    )
    temporary.unlink(missing_ok=True)
    try:
        request = urllib.request.Request(
            artifact.url,
            headers={"User-Agent": "CodexPad-PythonSnapshot/1"},
        )
        with urllib.request.urlopen(request, timeout=120) as response:
            with temporary.open("wb") as stream:
                shutil.copyfileobj(response, stream)
                stream.flush()
                os.fsync(stream.fileno())
        digest, size = _sha256_file(temporary)
        if digest != artifact.sha256 or size != artifact.size:
            raise SnapshotError(
                f"downloaded artifact mismatch for {artifact.filename}: "
                f"sha256={digest}, size={size}"
            )
        temporary.replace(destination)
        return destination
    finally:
        temporary.unlink(missing_ok=True)


def _safe_archive_path(name: str, label: str) -> Path:
    if "\\" in name:
        raise SnapshotError(f"{label} contains a backslash path: {name}")
    path = Path(name)
    if path.is_absolute() or any(part in ("", ".", "..") for part in path.parts):
        raise SnapshotError(f"{label} contains an unsafe path: {name}")
    return path


def _write_archive_file(
    destination_root: Path,
    relative: Path,
    payload: bytes,
) -> None:
    destination = destination_root / relative
    destination.parent.mkdir(parents=True, exist_ok=True)
    if destination.is_symlink():
        raise SnapshotError(
            f"archive would overwrite a symbolic link: {relative.as_posix()}"
        )
    if destination.exists():
        existing = destination.read_bytes()
        if existing != payload:
            raise SnapshotError(
                "archive file collision with different contents: "
                f"{relative.as_posix()}"
            )
        return
    destination.write_bytes(payload)
    destination.chmod(0o644)


def _extract_wheel(wheel: Path, destination_root: Path) -> None:
    try:
        with zipfile.ZipFile(wheel) as archive:
            for member in sorted(archive.infolist(), key=lambda item: item.filename):
                relative = _safe_archive_path(
                    member.filename.rstrip("/"),
                    f"wheel {wheel.name}",
                )
                mode = member.external_attr >> 16
                if stat.S_ISLNK(mode):
                    raise SnapshotError(
                        f"wheel contains a symbolic link: {member.filename}"
                    )
                if member.is_dir():
                    (destination_root / relative).mkdir(
                        parents=True,
                        exist_ok=True,
                    )
                    continue
                file_type = stat.S_IFMT(mode)
                if file_type not in (0, stat.S_IFREG):
                    raise SnapshotError(
                        f"wheel contains a non-regular file: {member.filename}"
                    )
                _write_archive_file(
                    destination_root,
                    relative,
                    archive.read(member),
                )
    except (OSError, zipfile.BadZipFile) as error:
        raise SnapshotError(f"wheel is invalid: {wheel}") from error


def _extract_sdist(sdist: Path, destination_root: Path) -> Path:
    destination_root.mkdir(parents=True, exist_ok=True)
    try:
        with tarfile.open(sdist, mode="r:*") as archive:
            for member in sorted(archive.getmembers(), key=lambda item: item.name):
                relative = _safe_archive_path(
                    member.name.rstrip("/"),
                    f"source distribution {sdist.name}",
                )
                destination = destination_root / relative
                if member.isdir():
                    destination.mkdir(parents=True, exist_ok=True)
                    continue
                if not member.isfile():
                    raise SnapshotError(
                        "source distribution contains a link or special file: "
                        f"{member.name}"
                    )
                stream = archive.extractfile(member)
                if stream is None:
                    raise SnapshotError(
                        f"source distribution member is unreadable: {member.name}"
                    )
                _write_archive_file(
                    destination_root,
                    relative,
                    stream.read(),
                )
    except (OSError, tarfile.TarError) as error:
        raise SnapshotError(
            f"source distribution is invalid: {sdist}"
        ) from error
    children = sorted(destination_root.iterdir())
    if len(children) != 1 or not children[0].is_dir():
        raise SnapshotError(
            f"source distribution must have one top-level directory: {sdist}"
        )
    return children[0]


def _find_host_python(explicit: Path | None) -> Path:
    if explicit is not None:
        candidate = explicit
    else:
        uv = shutil.which("uv")
        if uv is not None:
            value = _run_checked((uv, "python", "find", "3.13")).strip()
            candidate = Path(value)
        else:
            executable = shutil.which("python3.13")
            if executable is None:
                raise SnapshotError(
                    "CPython 3.13 host interpreter is required"
                )
            candidate = Path(executable)
    version = _run_checked(
        (
            str(candidate),
            "-c",
            "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')",
        )
    ).strip()
    if version != "3.13":
        raise SnapshotError(
            f"host interpreter must be CPython 3.13, found {version}: {candidate}"
        )
    return candidate


def _validate_runtime(runtime_root: Path) -> None:
    lock = _read_json_object(runtime_root / LOCK_FILE_NAME, "Python runtime lock")
    if (
        lock.get("schemaVersion") != 1
        or lock.get("runtime") != RUNTIME_NAME
        or lock.get("version") != RUNTIME_VERSION
        or lock.get("abi") != RUNTIME_ABI
        or lock.get("sourceTag") != RUNTIME_SOURCE_TAG
        or lock.get("sourceCommit") != RUNTIME_SOURCE_COMMIT
    ):
        raise SnapshotError(
            "vendored BeeWare Python runtime identity does not match "
            f"{RUNTIME_VERSION}/{RUNTIME_SOURCE_TAG}/{RUNTIME_SOURCE_COMMIT}"
        )
    xcframework = runtime_root / "Python.xcframework"
    for contract in SLICE_CONTRACTS.values():
        config = (
            xcframework
            / contract["frameworkSlice"]
            / "platform-config"
            / contract["platformConfig"]
        )
        if not (config / "make_cross_venv.py").is_file():
            raise SnapshotError(
                f"BeeWare cross-build configuration is missing: {config}"
            )


def _make_cross_venv(
    host_python: Path,
    runtime_root: Path,
    build_root: Path,
    slice_name: str,
) -> Path:
    contract = SLICE_CONTRACTS[slice_name]
    config = (
        runtime_root
        / "Python.xcframework"
        / contract["frameworkSlice"]
        / "platform-config"
        / contract["platformConfig"]
    )
    venv = build_root / "cross-venvs" / slice_name
    shutil.rmtree(venv, ignore_errors=True)
    venv.parent.mkdir(parents=True, exist_ok=True)
    _run_checked((str(host_python), "-m", "venv", str(venv)))
    _run_checked(
        (
            str(host_python),
            str(config / "make_cross_venv.py"),
            str(venv),
            str(config),
        )
    )
    return venv / "bin" / "python3"


def _native_build_environment(
    slice_name: str,
    *,
    base_environment: Mapping[str, str] | None = None,
) -> dict[str, str]:
    """Select the exact Apple SDK and deployment floor for Cargo."""

    try:
        contract = SLICE_CONTRACTS[slice_name]
    except KeyError as error:
        raise SnapshotError(f"unknown Python snapshot slice: {slice_name}") from error
    environment = dict(
        os.environ if base_environment is None else base_environment
    )
    sdk_root = _run_checked(
        (
            "xcrun",
            "--sdk",
            contract["sdk"],
            "--show-sdk-path",
        ),
        env=environment,
    ).strip()
    if not sdk_root:
        raise SnapshotError(
            f"xcrun returned no SDK path for {contract['sdk']}"
        )
    environment["SDKROOT"] = sdk_root
    environment["IPHONEOS_DEPLOYMENT_TARGET"] = contract["minimumOS"]
    return environment


def _native_wheel(
    artifact: LockedArtifact,
    source_root: Path,
    slice_name: str,
    cross_python: Path,
    build_root: Path,
    maturin: str,
) -> Path:
    contract = SLICE_CONTRACTS[slice_name]
    work = build_root / "native-work" / artifact.name / slice_name
    shutil.rmtree(work, ignore_errors=True)
    shutil.copytree(source_root, work)
    output = build_root / "native-wheels" / artifact.name / slice_name
    shutil.rmtree(output, ignore_errors=True)
    output.mkdir(parents=True)
    environment = _native_build_environment(slice_name)
    _run_checked(
        (
            maturin,
            "build",
            "--locked",
            "--release",
            "--target",
            contract["cargoTarget"],
            "--interpreter",
            str(cross_python),
            "--out",
            str(output),
        ),
        cwd=work,
        env=environment,
    )
    wheels = sorted(output.glob("*.whl"))
    if len(wheels) != 1:
        raise SnapshotError(
            f"maturin produced {len(wheels)} wheels for "
            f"{artifact.name}/{slice_name}"
        )
    filename = wheels[0].name
    expected_suffix = (
        "arm64_iphoneos.whl"
        if slice_name == DEVICE_SLICE
        else "arm64_iphonesimulator.whl"
    )
    if (
        "-cp313-cp313-" not in filename
        or not filename.endswith(expected_suffix)
    ):
        raise SnapshotError(
            f"maturin produced an unexpected wheel tag: {filename}"
        )
    return wheels[0]


def _normalize_install_name(
    slice_root: Path,
    extension: NativeExtension,
    slice_name: str,
) -> None:
    path = slice_root / extension.paths[slice_name]
    identity = (
        f"@rpath/{extension.module}.framework/{extension.module}"
    )
    _run_checked(("install_name_tool", "-id", identity, str(path)))


def _urlsafe_record_digest(payload: bytes) -> str:
    digest = base64.urlsafe_b64encode(hashlib.sha256(payload).digest())
    return "sha256=" + digest.rstrip(b"=").decode("ascii")


def _normalize_native_sbom(path: Path) -> None:
    """Remove optional per-build identity fields from a CycloneDX SBOM."""

    path = Path(path)
    payload = _read_json_object(path, "native wheel CycloneDX SBOM")
    if (
        payload.get("bomFormat") != "CycloneDX"
        or not isinstance(payload.get("specVersion"), str)
        or not isinstance(payload.get("metadata"), dict)
        or not isinstance(payload.get("components"), list)
    ):
        raise SnapshotError(
            f"native wheel CycloneDX SBOM has an invalid shape: {path}"
        )
    payload.pop("serialNumber", None)
    metadata = payload["metadata"]
    assert isinstance(metadata, dict)
    metadata.pop("timestamp", None)
    path.write_bytes(_canonical_json(payload))


def _normalize_distribution_sbom(
    slice_root: Path,
    artifact: LockedArtifact,
) -> None:
    candidates: list[Path] = []
    for dist_info in slice_root.glob("*.dist-info"):
        headers = _metadata_headers(dist_info / "METADATA")
        if (
            _canonical_name(headers.get("Name", ""))
            == _canonical_name(artifact.name)
            and headers.get("Version") == artifact.version
        ):
            candidates.append(dist_info)
    if len(candidates) != 1:
        raise SnapshotError(
            f"cannot identify installed dist-info for {artifact.name}"
        )
    sboms = sorted(
        (candidates[0] / "sboms").glob("*.cyclonedx.json")
    )
    if len(sboms) != 1:
        raise SnapshotError(
            f"expected one CycloneDX SBOM for {artifact.name}, "
            f"found {len(sboms)}"
        )
    _normalize_native_sbom(sboms[0])


def _rewrite_distribution_record(
    slice_root: Path,
    artifact: LockedArtifact,
) -> None:
    candidates: list[Path] = []
    for dist_info in slice_root.glob("*.dist-info"):
        headers = _metadata_headers(dist_info / "METADATA")
        if (
            _canonical_name(headers.get("Name", ""))
            == _canonical_name(artifact.name)
            and headers.get("Version") == artifact.version
        ):
            candidates.append(dist_info)
    if len(candidates) != 1:
        raise SnapshotError(
            f"cannot identify installed dist-info for {artifact.name}"
        )
    record = candidates[0] / "RECORD"
    if not record.is_file():
        raise SnapshotError(
            f"installed distribution RECORD is missing: {record}"
        )
    try:
        old_rows = list(
            csv.reader(io.StringIO(record.read_text(encoding="utf-8")))
        )
    except (OSError, csv.Error) as error:
        raise SnapshotError(f"installed RECORD is invalid: {record}") from error
    relative_record = record.relative_to(slice_root).as_posix()
    paths = sorted(
        {
            row[0]
            for row in old_rows
            if row and row[0] and row[0] != relative_record
        }
    )
    output = io.StringIO(newline="")
    writer = csv.writer(output, lineterminator="\n")
    for relative in paths:
        path = slice_root / relative
        if path.is_symlink() or not path.is_file():
            raise SnapshotError(
                f"installed RECORD references a missing file: {relative}"
            )
        payload = path.read_bytes()
        writer.writerow(
            (relative, _urlsafe_record_digest(payload), str(len(payload)))
        )
    writer.writerow((relative_record, "", ""))
    record.write_text(output.getvalue(), encoding="utf-8")


def _write_metadata_files(packages_root: Path) -> None:
    (packages_root / REQUIREMENTS_FILE_NAME).write_bytes(
        canonical_requirements_lock()
    )
    (packages_root / UVX_REGISTRY_FILE_NAME).write_bytes(
        canonical_uvx_registry()
    )


def build_snapshot(
    packages_root: Path,
    *,
    runtime_root: Path = DEFAULT_RUNTIME_ROOT,
    build_root: Path = DEFAULT_BUILD_ROOT,
    host_python: Path | None = None,
    maturin: str = "maturin",
) -> dict[str, object]:
    """Build both complete import roots and atomically install the result."""

    packages_root = Path(packages_root)
    runtime_root = Path(runtime_root)
    build_root = Path(build_root)
    _validate_runtime(runtime_root)
    selected_python = _find_host_python(host_python)
    if shutil.which(maturin) is None:
        raise SnapshotError(f"maturin executable is missing: {maturin}")
    installed_targets = set(
        _run_checked(("rustup", "target", "list", "--installed")).splitlines()
    )
    required_targets = {
        contract["cargoTarget"] for contract in SLICE_CONTRACTS.values()
    }
    missing_targets = sorted(required_targets - installed_targets)
    if missing_targets:
        raise SnapshotError(
            f"required Rust targets are missing: {missing_targets!r}"
        )

    cache_root = build_root / "downloads"
    artifacts = {
        artifact.name: _download_artifact(artifact, cache_root)
        for artifact in ARTIFACTS
    }
    source_roots: dict[str, Path] = {}
    for artifact in ARTIFACTS:
        if artifact.kind != "sdist":
            continue
        source_destination = build_root / "sources" / artifact.name
        shutil.rmtree(source_destination, ignore_errors=True)
        source_roots[artifact.name] = _extract_sdist(
            artifacts[artifact.name],
            source_destination,
        )

    cross_pythons = {
        slice_name: _make_cross_venv(
            selected_python,
            runtime_root,
            build_root,
            slice_name,
        )
        for slice_name in (DEVICE_SLICE, SIMULATOR_SLICE)
    }
    staging = packages_root.parent / (
        f".{packages_root.name}.staging.{os.getpid()}"
    )
    shutil.rmtree(staging, ignore_errors=True)
    staging.mkdir(parents=True)
    try:
        _write_metadata_files(staging)
        for slice_name in (DEVICE_SLICE, SIMULATOR_SLICE):
            slice_root = staging / slice_name
            slice_root.mkdir()
            for artifact in ARTIFACTS:
                if artifact.kind == "wheel":
                    _extract_wheel(artifacts[artifact.name], slice_root)
            for artifact in ARTIFACTS:
                if artifact.kind != "sdist":
                    continue
                wheel = _native_wheel(
                    artifact,
                    source_roots[artifact.name],
                    slice_name,
                    cross_pythons[slice_name],
                    build_root,
                    maturin,
                )
                _extract_wheel(wheel, slice_root)
                extension = next(
                    item
                    for item in NATIVE_EXTENSIONS
                    if item.package == artifact.name
                )
                _normalize_install_name(
                    slice_root,
                    extension,
                    slice_name,
                )
                _normalize_distribution_sbom(slice_root, artifact)
                _rewrite_distribution_record(slice_root, artifact)
            _validate_installed_distributions(slice_root)
        write_runtime_lock(staging)
        payload = verify_runtime_lock(staging)

        backup = packages_root.parent / (
            f".{packages_root.name}.backup.{os.getpid()}"
        )
        shutil.rmtree(backup, ignore_errors=True)
        if packages_root.exists():
            packages_root.replace(backup)
        try:
            staging.replace(packages_root)
        except BaseException:
            if backup.exists() and not packages_root.exists():
                backup.replace(packages_root)
            raise
        shutil.rmtree(backup, ignore_errors=True)
        return payload
    finally:
        shutil.rmtree(staging, ignore_errors=True)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description=(
            "Build or verify the deterministic iOS Python MCP snapshot"
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
        "--runtime-root",
        type=Path,
        default=DEFAULT_RUNTIME_ROOT,
    )
    parser.add_argument(
        "--build-root",
        type=Path,
        default=DEFAULT_BUILD_ROOT,
    )
    parser.add_argument("--host-python", type=Path)
    parser.add_argument("--maturin", default="maturin")
    action = parser.add_mutually_exclusive_group(required=True)
    action.add_argument(
        "--build",
        action="store_true",
        help="download locked inputs and build both iOS slices",
    )
    action.add_argument(
        "--verify",
        action="store_true",
        help="verify an existing snapshot without network access",
    )
    args = parser.parse_args(argv)
    try:
        if args.build:
            payload = build_snapshot(
                args.packages_root,
                runtime_root=args.runtime_root,
                build_root=args.build_root,
                host_python=args.host_python,
                maturin=args.maturin,
            )
            action_name = "built"
        else:
            payload = verify_runtime_lock(args.packages_root)
            action_name = "verified"
    except (SnapshotError, OSError) as error:
        print(f"Python MCP snapshot error: {error}", file=sys.stderr)
        return 1
    print(
        json.dumps(
            {
                "action": action_name,
                "packagesRoot": str(args.packages_root),
                "requirementsLockSha256": payload[
                    "requirementsLockSha256"
                ],
                "tree": payload["tree"],
            },
            sort_keys=True,
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
