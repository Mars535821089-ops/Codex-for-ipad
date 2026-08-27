#!/usr/bin/env python3
"""Install the pinned NodeMobile iOS runtime with release verification."""

from __future__ import annotations

import argparse
import hashlib
import json
import shutil
import tempfile
import urllib.request
import zipfile
from pathlib import Path


VERSION = "18.20.4"
SOURCE_URL = (
    "https://github.com/nodejs-mobile/nodejs-mobile/"
    f"releases/download/v{VERSION}/"
    f"nodejs-mobile-v{VERSION}-ios.zip"
)
ARCHIVE_BYTES = 51_492_431
ARCHIVE_SHA256 = (
    "8c5ca3a0d1e38de7f182a5642593e8259"
    "3b820efd375a14b3ecafc4bcfee620e"
)
FRAMEWORK_PATH = "NodeMobile.xcframework"


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def verify_archive(path: Path) -> None:
    size = path.stat().st_size
    if size != ARCHIVE_BYTES:
        raise ValueError(
            f"NodeMobile archive size mismatch: {size}"
        )
    digest = sha256_file(path)
    if digest != ARCHIVE_SHA256:
        raise ValueError(
            f"NodeMobile archive SHA256 mismatch: {digest}"
        )


def runtime_lock() -> dict[str, object]:
    return {
        "schemaVersion": 1,
        "runtime": "NodeMobile",
        "version": VERSION,
        "sourceURL": SOURCE_URL,
        "archiveBytes": ARCHIVE_BYTES,
        "archiveSha256": ARCHIVE_SHA256,
        "xcframeworkPath": FRAMEWORK_PATH,
    }


def extract_framework(archive: Path, destination: Path) -> None:
    prefix = f"{FRAMEWORK_PATH}/"
    with zipfile.ZipFile(archive) as source:
        members = [
            member
            for member in source.infolist()
            if member.filename == FRAMEWORK_PATH
            or member.filename.startswith(prefix)
        ]
        if not members:
            raise ValueError(
                "NodeMobile archive does not contain its XCFramework"
            )
        for member in members:
            relative = Path(member.filename)
            if relative.is_absolute() or ".." in relative.parts:
                raise ValueError(
                    "NodeMobile archive contains an unsafe path"
                )
            target = destination / relative
            if member.is_dir():
                target.mkdir(parents=True, exist_ok=True)
                continue
            target.parent.mkdir(parents=True, exist_ok=True)
            with source.open(member) as input_stream:
                with target.open("wb") as output_stream:
                    shutil.copyfileobj(input_stream, output_stream)


def install_runtime(
    vendor_root: Path,
    *,
    archive: Path | None = None,
) -> Path:
    vendor_root = vendor_root.resolve()
    vendor_root.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(
        prefix=".node-mobile-install-",
        dir=vendor_root.parent,
    ) as temporary:
        staging = Path(temporary)
        local_archive = archive
        if local_archive is None:
            local_archive = staging / "NodeMobile.zip"
            urllib.request.urlretrieve(
                SOURCE_URL,
                local_archive,
            )
        verify_archive(local_archive)
        extract_framework(local_archive, staging)
        framework = staging / FRAMEWORK_PATH
        required = [
            framework / "Info.plist",
            framework
            / "ios-arm64/NodeMobile.framework/NodeMobile",
            framework
            / "ios-arm64/NodeMobile.framework/Headers/NodeMobile.h",
            framework
            / (
                "ios-arm64_x86_64-simulator/"
                "NodeMobile.framework/NodeMobile"
            ),
        ]
        missing = [str(path) for path in required if not path.is_file()]
        if missing:
            raise ValueError(
                "NodeMobile XCFramework is incomplete: "
                + ", ".join(missing)
            )
        (staging / "runtime-lock.json").write_text(
            json.dumps(
                runtime_lock(),
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
        replacement.mkdir()
        shutil.move(str(framework), replacement / FRAMEWORK_PATH)
        shutil.move(
            staging / "runtime-lock.json",
            replacement / "runtime-lock.json",
        )
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
                "runtime": "NodeMobile",
                "version": VERSION,
                "vendorRoot": str(destination),
                "archiveSha256": ARCHIVE_SHA256,
            },
            sort_keys=True,
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
