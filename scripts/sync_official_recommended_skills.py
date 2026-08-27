#!/usr/bin/env python3
"""Synchronize the official desktop recommended-skill bundle into CodexPad."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import stat
import tempfile
from pathlib import Path
from typing import Any


def _remove_path(path: Path) -> None:
    if path.is_symlink() or path.is_file():
        path.unlink()
    elif path.is_dir():
        shutil.rmtree(path)
    elif path.exists():
        raise ValueError(f"unsupported destination path type: {path}")


def _validated_files(root: Path) -> list[Path]:
    if root.is_symlink() or not root.is_dir():
        raise ValueError(f"official recommended-skills root is missing: {root}")
    curated = root / "skills" / ".curated"
    if curated.is_symlink() or not curated.is_dir():
        raise ValueError(
            "official recommended-skills root is missing skills/.curated"
        )

    files: list[Path] = []
    skill_count = 0
    for path in sorted(root.rglob("*")):
        relative = path.relative_to(root)
        if path.is_symlink():
            raise ValueError(
                f"official recommended-skills bundle contains a symlink: {relative}"
            )
        mode = path.lstat().st_mode
        if stat.S_ISDIR(mode):
            if (
                path.parent == curated
                and (path / "SKILL.md").is_file()
                and not (path / "SKILL.md").is_symlink()
            ):
                skill_count += 1
            continue
        if not stat.S_ISREG(mode):
            raise ValueError(
                "official recommended-skills bundle contains an unsupported "
                f"entry: {relative}"
            )
        files.append(path)
    if skill_count == 0:
        raise ValueError(
            "official recommended-skills bundle contains no curated skills"
        )
    return files


def _tree_identity(root: Path) -> dict[str, Any]:
    files = _validated_files(root)
    digest = hashlib.sha256()
    total_bytes = 0
    for path in files:
        relative = path.relative_to(root).as_posix()
        payload = path.read_bytes()
        file_hash = hashlib.sha256(payload).hexdigest()
        digest.update(relative.encode("utf-8"))
        digest.update(b"\0")
        digest.update(str(len(payload)).encode("ascii"))
        digest.update(b"\0")
        digest.update(file_hash.encode("ascii"))
        digest.update(b"\n")
        total_bytes += len(payload)
    return {
        "fileCount": len(files),
        "totalBytes": total_bytes,
        "treeSha256": digest.hexdigest(),
    }


def synchronize(source: Path, destination: Path) -> dict[str, Any]:
    source = source.expanduser()
    destination = destination.expanduser()
    source_identity = _tree_identity(source)

    if destination.is_symlink():
        raise ValueError(
            f"recommended-skills destination must not be a symlink: {destination}"
        )
    if destination.exists() and not destination.is_dir():
        raise ValueError(
            "recommended-skills destination has an unsupported type: "
            f"{destination}"
        )

    destination.parent.mkdir(parents=True, exist_ok=True)
    workspace = Path(
        tempfile.mkdtemp(
            prefix=f".{destination.name}.sync.",
            dir=destination.parent,
        )
    )
    staged = workspace / "payload"
    previous = workspace / "previous"
    previous_moved = False
    promoted = False
    try:
        shutil.copytree(source, staged, symlinks=False, copy_function=shutil.copy2)
        if _tree_identity(staged) != source_identity:
            raise ValueError(
                "recommended-skills staged copy does not match official source"
            )

        if destination.exists():
            os.replace(destination, previous)
            previous_moved = True
        os.replace(staged, destination)
        promoted = True

        if _tree_identity(destination) != source_identity:
            raise ValueError(
                "recommended-skills destination does not match official source"
            )
        if previous_moved:
            shutil.rmtree(previous)
        previous_moved = False
    except BaseException:
        if promoted and (destination.exists() or destination.is_symlink()):
            _remove_path(destination)
        if previous_moved and previous.exists():
            os.replace(previous, destination)
        raise
    finally:
        if workspace.exists():
            shutil.rmtree(workspace)

    return {
        "source": str(source),
        "destination": str(destination),
        **source_identity,
    }


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Synchronize official desktop recommended skills into CodexPad"
    )
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--destination", type=Path, required=True)
    return parser


def main() -> int:
    args = build_parser().parse_args()
    try:
        result = synchronize(args.source, args.destination)
    except (OSError, ValueError) as error:
        raise SystemExit(str(error)) from error
    print(json.dumps(result, ensure_ascii=False, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
