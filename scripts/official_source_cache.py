#!/usr/bin/env python3
"""Create and verify the extracted official Codex source cache."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import tempfile
from pathlib import Path
from typing import Any


MANIFEST_NAME = ".codex-source-cache.json"
SHA256_PATTERN = re.compile(r"^[0-9a-f]{64}$")
COMMIT_PATTERN = re.compile(r"^[0-9a-f]{40}$")


def tree_sha256(root: Path) -> str:
    root = root.resolve()
    if not root.is_dir():
        raise ValueError("official source cache is missing")
    digest = hashlib.sha256()
    for path in sorted(root.rglob("*"), key=lambda item: item.as_posix()):
        relative = path.relative_to(root).as_posix()
        if relative == MANIFEST_NAME:
            continue
        if path.is_symlink():
            digest.update(b"L\0")
            digest.update(relative.encode())
            digest.update(b"\0")
            digest.update(os.readlink(path).encode())
            digest.update(b"\0")
        elif path.is_dir():
            digest.update(b"D\0")
            digest.update(relative.encode())
            digest.update(b"\0")
        elif path.is_file():
            digest.update(b"F\0")
            digest.update(relative.encode())
            digest.update(b"\0")
            with path.open("rb") as stream:
                for block in iter(lambda: stream.read(1024 * 1024), b""):
                    digest.update(block)
            digest.update(b"\0")
        else:
            raise ValueError(f"unsupported source cache entry: {relative}")
    return digest.hexdigest()


def _write_json_atomic(path: Path, value: dict[str, Any]) -> None:
    temporary: Path | None = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="w",
            encoding="utf-8",
            dir=path.parent,
            prefix=f".{path.name}.",
            delete=False,
        ) as stream:
            json.dump(value, stream, ensure_ascii=False, indent=2)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
            temporary = Path(stream.name)
        os.replace(temporary, path)
    finally:
        if temporary is not None and temporary.exists():
            temporary.unlink()


def write_manifest(
    root: Path,
    tag: str,
    commit: str,
    archive_sha256: str,
) -> dict[str, Any]:
    if COMMIT_PATTERN.fullmatch(commit) is None:
        raise ValueError("source commit is malformed")
    if SHA256_PATTERN.fullmatch(archive_sha256) is None:
        raise ValueError("source archive SHA-256 is malformed")
    record = {
        "schemaVersion": 1,
        "sourceTag": tag,
        "sourceCommit": commit,
        "sourceArchiveSha256": archive_sha256,
        "treeSha256": tree_sha256(root),
    }
    _write_json_atomic(root / MANIFEST_NAME, record)
    return record


def verify_manifest(root: Path, tag: str, commit: str) -> dict[str, Any]:
    path = root / MANIFEST_NAME
    value = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict) or value.get("schemaVersion") != 1:
        raise ValueError("source cache manifest is malformed")
    if value.get("sourceTag") != tag or value.get("sourceCommit") != commit:
        raise ValueError("source cache identity differs from official tag")
    archive_sha256 = value.get("sourceArchiveSha256")
    expected_tree = value.get("treeSha256")
    if (
        not isinstance(archive_sha256, str)
        or SHA256_PATTERN.fullmatch(archive_sha256) is None
        or not isinstance(expected_tree, str)
        or SHA256_PATTERN.fullmatch(expected_tree) is None
    ):
        raise ValueError("source cache manifest hash is malformed")
    actual_tree = tree_sha256(root)
    if actual_tree != expected_tree:
        raise ValueError("source cache tree SHA-256 mismatch")
    return value


def main() -> int:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)
    for command in ("write", "verify"):
        child = subparsers.add_parser(command)
        child.add_argument("--root", type=Path, required=True)
        child.add_argument("--tag", required=True)
        child.add_argument("--commit", required=True)
        if command == "write":
            child.add_argument("--archive-sha256", required=True)
    args = parser.parse_args()
    try:
        if args.command == "write":
            value = write_manifest(
                args.root,
                args.tag,
                args.commit,
                args.archive_sha256,
            )
        else:
            value = verify_manifest(args.root, args.tag, args.commit)
    except (OSError, ValueError, json.JSONDecodeError) as error:
        parser.error(str(error))
    print(json.dumps(value, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
