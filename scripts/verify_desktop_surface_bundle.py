#!/usr/bin/env python3
"""Verify the complete released desktop renderer inside an iPad app bundle."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import re
import sys
from typing import Any

if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from scripts.protocol_manifest import sha256_file, write_json_atomic


MANIFEST_NAME = "desktop-surface-manifest.json"
VERSION_PATTERN = re.compile(r"^[0-9]+(?:\.[0-9]+)+$")
BUILD_PATTERN = re.compile(r"^[1-9][0-9]*$")


def _object(value: Any, label: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise ValueError(f"{label} is malformed")
    return value


def _safe_file(root: Path, relative: Any) -> Path:
    if not isinstance(relative, str) or not relative:
        raise ValueError("renderer relative path is malformed")
    relative_path = Path(relative)
    if (
        relative_path.is_absolute()
        or ".." in relative_path.parts
        or "." in relative_path.parts
        or "\\" in relative
    ):
        raise ValueError(f"renderer path escapes surface root: {relative}")
    root = root.resolve()
    candidate = (root / relative_path).resolve()
    try:
        candidate.relative_to(root)
    except ValueError as error:
        raise ValueError(
            f"renderer path escapes surface root: {relative}"
        ) from error
    return candidate


def _tree_identity(root: Path) -> tuple[int, int, str]:
    count = 0
    total_bytes = 0
    digest = hashlib.sha256()
    paths = sorted(
        path
        for path in root.rglob("*")
        if path.is_file() and path.relative_to(root).as_posix() != MANIFEST_NAME
    )
    for path in paths:
        relative = path.relative_to(root).as_posix()
        size = path.stat().st_size
        file_digest = sha256_file(path)
        digest.update(relative.encode("utf-8"))
        digest.update(b"\0")
        digest.update(str(size).encode("ascii"))
        digest.update(b"\0")
        digest.update(file_digest.encode("ascii"))
        digest.update(b"\n")
        count += 1
        total_bytes += size
    return count, total_bytes, digest.hexdigest()


def verify_bundle(
    surface_root: Path,
    *,
    expected_version: str,
    expected_build: str,
) -> dict[str, Any]:
    if VERSION_PATTERN.fullmatch(expected_version) is None:
        raise ValueError("expected desktop version is malformed")
    if BUILD_PATTERN.fullmatch(expected_build) is None:
        raise ValueError("expected desktop build is malformed")
    surface_root = surface_root.resolve()
    if not surface_root.is_dir():
        raise ValueError("bundled desktop surface is missing")
    manifest_path = surface_root / MANIFEST_NAME
    if not manifest_path.is_file():
        raise ValueError("bundled desktop surface manifest is missing")
    manifest = _object(
        json.loads(manifest_path.read_text(encoding="utf-8")),
        "desktop surface manifest",
    )

    expected_fields = {
        "schemaVersion": 1,
        "desktopVersion": expected_version,
        "desktopBuild": expected_build,
        "productName": "Codex",
        "ipadProductName": "Codex for ipad",
        "resourceDirectoryName": "CodexDesktopSurface",
    }
    for field, expected in expected_fields.items():
        if manifest.get(field) != expected:
            raise ValueError(
                f"desktop surface {field} mismatch: "
                f"expected {expected!r}, got {manifest.get(field)!r}"
            )

    entry = _object(manifest.get("entry"), "desktop surface entry")
    entry_path = entry.get("path")
    entry_file = _safe_file(surface_root, entry_path)
    if not entry_file.is_file():
        raise ValueError(f"renderer entry is missing: {entry_path}")

    critical_files = manifest.get("criticalFiles")
    if not isinstance(critical_files, list) or not critical_files:
        raise ValueError("desktop surface critical files are malformed")
    seen: set[str] = set()
    for raw_row in critical_files:
        row = _object(raw_row, "critical file record")
        relative = row.get("path")
        file_path = _safe_file(surface_root, relative)
        if relative in seen:
            raise ValueError(f"duplicate critical file record: {relative}")
        seen.add(relative)
        if not file_path.is_file():
            raise ValueError(f"critical file is missing: {relative}")
        expected_bytes = row.get("bytes")
        if not isinstance(expected_bytes, int) or expected_bytes < 0:
            raise ValueError(f"critical file byte count is malformed: {relative}")
        if file_path.stat().st_size != expected_bytes:
            raise ValueError(f"critical file size mismatch: {relative}")
        expected_sha256 = row.get("sha256")
        if (
            not isinstance(expected_sha256, str)
            or re.fullmatch(r"[0-9a-f]{64}", expected_sha256) is None
        ):
            raise ValueError(f"critical file hash is malformed: {relative}")
        if sha256_file(file_path) != expected_sha256:
            raise ValueError(f"critical file hash mismatch: {relative}")

    count, total_bytes, tree_sha256 = _tree_identity(surface_root)
    expected_count = manifest.get("resourceFileCount")
    expected_bytes = manifest.get("resourceTotalBytes")
    expected_tree = manifest.get("resourceTreeSha256")
    if count != expected_count:
        raise ValueError(
            f"renderer file count mismatch: expected {expected_count}, got {count}"
        )
    if total_bytes != expected_bytes:
        raise ValueError(
            "renderer total byte count mismatch: "
            f"expected {expected_bytes}, got {total_bytes}"
        )
    if tree_sha256 != expected_tree:
        raise ValueError(
            f"renderer tree hash mismatch: expected {expected_tree}, "
            f"got {tree_sha256}"
        )

    return {
        "status": "passed",
        "desktopVersion": expected_version,
        "desktopBuild": expected_build,
        "entry": entry_path,
        "criticalFileCount": len(critical_files),
        "resourceFileCount": count,
        "resourceTotalBytes": total_bytes,
        "resourceTreeSha256": tree_sha256,
        "completeTreeVerified": True,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--surface-root", type=Path, required=True)
    parser.add_argument("--desktop-version", required=True)
    parser.add_argument("--desktop-build", required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    try:
        result = verify_bundle(
            args.surface_root,
            expected_version=args.desktop_version,
            expected_build=args.desktop_build,
        )
        write_json_atomic(args.output, result)
    except (OSError, ValueError, json.JSONDecodeError) as error:
        parser.error(str(error))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
