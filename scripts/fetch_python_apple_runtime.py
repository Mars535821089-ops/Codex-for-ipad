#!/usr/bin/env python3
"""Install the pinned BeeWare CPython iOS support package."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import plistlib
import posixpath
import shutil
import tarfile
import tempfile
import urllib.request
from pathlib import Path


PYTHON_VERSION = "3.13.14"
ABI = "cp313"
SOURCE_TAG = "3.13-b14"
SOURCE_COMMIT = "54d8ab6ef4fbac4d60706f311a986aee5236c71b"
ASSET_NAME = "Python-3.13-iOS-support.b14.tar.gz"
SOURCE_URL = (
    "https://github.com/beeware/Python-Apple-support/"
    f"releases/download/{SOURCE_TAG}/{ASSET_NAME}"
)
ARCHIVE_BYTES = 32_387_292
ARCHIVE_SHA256 = (
    "8b5cb76ef8d8a2946052479358eeec9d"
    "54b4496cb60920e175ec1489b5cf7963"
)
FRAMEWORK_PATH = "Python.xcframework"
UTILS_PATH = f"{FRAMEWORK_PATH}/build/utils.sh"
FWORK_REDIRECTION_UNPATCHED = (
    'echo "$FRAMEWORK_FOLDER/$FULL_MODULE_NAME" '
    "> ${FULL_EXT%.so}.fwork"
)
FWORK_REDIRECTION_PATCHED = (
    'echo "$FRAMEWORK_FOLDER/$FULL_MODULE_NAME" '
    '> "${FULL_EXT%.so}.fwork"'
)
PATCHED_UTILS_SHA256 = (
    "a4bb9d3e34f63ea0e022a013898df666"
    "96062f83b372dd9b947c415020c705f1"
)


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def verify_archive(
    path: Path,
    *,
    expected_bytes: int = ARCHIVE_BYTES,
    expected_sha256: str = ARCHIVE_SHA256,
) -> None:
    size = path.stat().st_size
    if size != expected_bytes:
        raise ValueError(f"CPython archive size mismatch: {size}")
    digest = sha256_file(path)
    if digest != expected_sha256:
        raise ValueError(
            f"CPython archive SHA256 mismatch: {digest}"
        )


def runtime_lock(
    *,
    archive_bytes: int = ARCHIVE_BYTES,
    archive_sha256: str = ARCHIVE_SHA256,
    patched_utils_sha256: str = PATCHED_UTILS_SHA256,
) -> dict[str, object]:
    return {
        "schemaVersion": 1,
        "runtime": "CPython",
        "version": PYTHON_VERSION,
        "abi": ABI,
        "sourceRepository":
            "https://github.com/beeware/Python-Apple-support",
        "sourceTag": SOURCE_TAG,
        "sourceCommit": SOURCE_COMMIT,
        "sourceURL": SOURCE_URL,
        "assetName": ASSET_NAME,
        "archiveBytes": archive_bytes,
        "archiveSha256": archive_sha256,
        "xcframeworkPath": FRAMEWORK_PATH,
        "versionsPath": "VERSIONS",
        "compatibilityPatches": [
            {
                "id": "quote-fwork-placeholder-path",
                "path": UTILS_PATH,
                "sha256": patched_utils_sha256,
            }
        ],
    }


def extract_runtime(archive: Path, destination: Path) -> None:
    allowed_roots = {FRAMEWORK_PATH, "VERSIONS"}
    destination.mkdir(parents=True, exist_ok=True)
    with tarfile.open(archive, "r:gz") as source:
        for member in source.getmembers():
            relative = Path(member.name)
            if (
                relative.is_absolute()
                or ".." in relative.parts
                or not relative.parts
            ):
                raise ValueError(
                    "CPython archive contains an unsafe path"
                )
            if relative.parts[0] not in allowed_roots:
                continue
            if member.islnk():
                raise ValueError(
                    "CPython archive contains an unsafe link"
                )
            target = destination / relative
            if member.issym():
                linkname = member.linkname
                resolved_link = posixpath.normpath(
                    posixpath.join(
                        posixpath.dirname(member.name),
                        linkname,
                    )
                )
                resolved_parts = Path(resolved_link).parts
                if (
                    not linkname
                    or posixpath.isabs(linkname)
                    or not resolved_parts
                    or resolved_parts[0] != FRAMEWORK_PATH
                    or ".." in resolved_parts
                ):
                    raise ValueError(
                        "CPython archive contains an unsafe link"
                    )
                target.parent.mkdir(
                    parents=True,
                    exist_ok=True,
                )
                os.symlink(linkname, target)
                continue
            if member.isdir():
                target.mkdir(parents=True, exist_ok=True)
                continue
            if not member.isfile():
                raise ValueError(
                    "CPython archive contains an unsupported member"
                )
            target.parent.mkdir(parents=True, exist_ok=True)
            input_stream = source.extractfile(member)
            if input_stream is None:
                raise ValueError(
                    "CPython archive member is unreadable"
                )
            with input_stream, target.open("wb") as output_stream:
                shutil.copyfileobj(input_stream, output_stream)


def apply_runtime_compatibility_patches(root: Path) -> str:
    """Apply deterministic iPad app-path fixes to the pinned helper."""

    utils = root / UTILS_PATH
    try:
        source = utils.read_text(encoding="utf-8")
    except OSError as error:
        raise ValueError(
            f"CPython compatibility helper is unreadable: {utils}"
        ) from error
    old_count = source.count(FWORK_REDIRECTION_UNPATCHED)
    patched_count = source.count(FWORK_REDIRECTION_PATCHED)
    if old_count == 1 and patched_count == 0:
        utils.write_text(
            source.replace(
                FWORK_REDIRECTION_UNPATCHED,
                FWORK_REDIRECTION_PATCHED,
            ),
            encoding="utf-8",
        )
    elif old_count != 0 or patched_count != 1:
        raise ValueError(
            "CPython compatibility helper does not match "
            "the expected fwork redirection"
        )
    return sha256_file(utils)


def validate_runtime(root: Path) -> None:
    framework = root / FRAMEWORK_PATH
    required = [
        framework / "Info.plist",
        framework
        / "ios-arm64/Python.framework/Python",
        framework
        / "ios-arm64/Python.framework/Headers/Python.h",
        framework / "build/utils.sh",
        framework / "lib/python3.13",
        root / "VERSIONS",
    ]
    missing = [str(path) for path in required if not path.exists()]
    if missing:
        raise ValueError(
            "CPython XCFramework is incomplete: "
            + ", ".join(missing)
        )
    metadata = plistlib.loads(
        (framework / "Info.plist").read_bytes()
    )
    libraries = metadata.get("AvailableLibraries")
    if not isinstance(libraries, list):
        raise ValueError("CPython XCFramework metadata is invalid")
    device = any(
        library.get("SupportedPlatform") == "ios"
        and library.get("SupportedPlatformVariant") is None
        and "arm64" in library.get("SupportedArchitectures", [])
        for library in libraries
        if isinstance(library, dict)
    )
    simulator = any(
        library.get("SupportedPlatform") == "ios"
        and library.get("SupportedPlatformVariant") == "simulator"
        and "arm64" in library.get("SupportedArchitectures", [])
        for library in libraries
        if isinstance(library, dict)
    )
    if not device:
        raise ValueError(
            "CPython XCFramework lacks the ios-arm64 device slice"
        )
    if not simulator:
        raise ValueError(
            "CPython XCFramework lacks the arm64 simulator slice"
        )
    versions = (root / "VERSIONS").read_text(encoding="utf-8")
    if (
        f"Python version: {PYTHON_VERSION}" not in versions
        or "Build: b14" not in versions
    ):
        raise ValueError("CPython VERSIONS metadata is inconsistent")
    helper = (root / UTILS_PATH).read_text(encoding="utf-8")
    if (
        helper.count(FWORK_REDIRECTION_PATCHED) != 1
        or FWORK_REDIRECTION_UNPATCHED in helper
    ):
        raise ValueError(
            "CPython compatibility helper is not patched"
        )


def install_runtime(
    vendor_root: Path,
    *,
    archive: Path | None = None,
    expected_bytes: int = ARCHIVE_BYTES,
    expected_sha256: str = ARCHIVE_SHA256,
) -> Path:
    vendor_root = vendor_root.resolve()
    vendor_root.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(
        prefix=".python-apple-install-",
        dir=vendor_root.parent,
    ) as temporary:
        staging = Path(temporary)
        local_archive = archive
        if local_archive is None:
            local_archive = staging / ASSET_NAME
            request = urllib.request.Request(
                SOURCE_URL,
                headers={
                    "User-Agent": "Codex-for-iPad-runtime-pin",
                },
            )
            with urllib.request.urlopen(request) as response:
                with local_archive.open("wb") as output_stream:
                    shutil.copyfileobj(response, output_stream)
        verify_archive(
            local_archive,
            expected_bytes=expected_bytes,
            expected_sha256=expected_sha256,
        )
        extracted = staging / "extracted"
        extract_runtime(local_archive, extracted)
        patched_utils_sha256 = (
            apply_runtime_compatibility_patches(extracted)
        )
        validate_runtime(extracted)
        (extracted / "runtime-lock.json").write_text(
            json.dumps(
                runtime_lock(
                    archive_bytes=expected_bytes,
                    archive_sha256=expected_sha256,
                    patched_utils_sha256=patched_utils_sha256,
                ),
                ensure_ascii=False,
                indent=2,
                sort_keys=True,
            )
            + "\n",
            encoding="utf-8",
        )
        replacement = vendor_root.with_name(
            f".{vendor_root.name}.replacement"
        )
        if replacement.exists():
            shutil.rmtree(replacement)
        shutil.move(str(extracted), replacement)
        previous = vendor_root.with_name(
            f".{vendor_root.name}.previous"
        )
        if previous.exists():
            shutil.rmtree(previous)
        if vendor_root.exists():
            vendor_root.replace(previous)
        replacement.replace(vendor_root)
        if previous.exists():
            shutil.rmtree(previous)
    return vendor_root


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--vendor-root", required=True, type=Path)
    parser.add_argument("--archive", type=Path)
    args = parser.parse_args()
    destination = install_runtime(
        args.vendor_root,
        archive=args.archive,
    )
    print(
        json.dumps(
            {
                "runtime": "CPython",
                "version": PYTHON_VERSION,
                "abi": ABI,
                "vendorRoot": str(destination),
                "archiveSha256": ARCHIVE_SHA256,
            },
            sort_keys=True,
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
