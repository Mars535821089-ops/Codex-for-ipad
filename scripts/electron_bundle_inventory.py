#!/usr/bin/env python3
"""Build a deterministic inventory of a released Electron ASAR tree."""

from __future__ import annotations

import argparse
from collections import Counter
import json
from pathlib import Path
import sys

if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from scripts.protocol_manifest import sha256_file, write_json_atomic


def classify_role(relative: str) -> str:
    if relative == ".vite/build/early-bootstrap.js":
        return "electron-entry"
    if relative.startswith(".vite/build/") and "preload" in Path(relative).name:
        return "preload"
    if relative.startswith(".vite/build/") and relative.endswith(".js"):
        return "electron-main"
    if relative == "webview/index.html":
        return "renderer-html"
    if relative.startswith("webview/assets/") and relative.endswith(".css"):
        return "renderer-style"
    if relative.startswith("webview/assets/") and relative.endswith(".js"):
        return "renderer-script"
    return "resource"


def build_bundle_inventory(
    asar_root: Path, expected_version: str
) -> dict[str, object]:
    root = asar_root.resolve()
    package_path = root / "package.json"
    if not package_path.is_file():
        raise ValueError("ASAR package.json is missing")
    package = json.loads(package_path.read_text(encoding="utf-8"))
    if not isinstance(package, dict):
        raise ValueError("ASAR package.json must contain an object")
    if package.get("version") != expected_version:
        raise ValueError("ASAR package version does not match protocol manifest")
    main = package.get("main")
    if not isinstance(main, str) or not (root / main).is_file():
        raise ValueError("Electron main entry is missing")

    files: list[dict[str, object]] = []
    for path in sorted(item for item in root.rglob("*") if item.is_file()):
        relative = path.relative_to(root).as_posix()
        files.append(
            {
                "path": relative,
                "bytes": path.stat().st_size,
                "sha256": sha256_file(path),
                "role": classify_role(relative),
            }
        )
    if not files:
        raise ValueError("ASAR bundle contains no files")
    role_counts = Counter(str(entry["role"]) for entry in files)
    return {
        "schemaVersion": 1,
        "version": expected_version,
        "package": {
            "name": package.get("name"),
            "productName": package.get("productName"),
            "version": package["version"],
            "main": main,
        },
        "fileCount": len(files),
        "totalBytes": sum(int(entry["bytes"]) for entry in files),
        "roleCounts": dict(sorted(role_counts.items())),
        "files": files,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--asar-root", type=Path, required=True)
    parser.add_argument("--expected-version", required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    inventory = build_bundle_inventory(args.asar_root, args.expected_version)
    write_json_atomic(args.output, inventory)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
