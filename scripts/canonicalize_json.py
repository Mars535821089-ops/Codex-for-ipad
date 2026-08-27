#!/usr/bin/env python3
"""Canonicalize generated JSON files without changing array semantics."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import tempfile


def canonicalize_file(path: Path) -> None:
    value = json.loads(path.read_text(encoding="utf-8"))
    content = json.dumps(
        value,
        ensure_ascii=False,
        indent=2,
        sort_keys=True,
    ) + "\n"
    fd, temporary = tempfile.mkstemp(
        prefix=f".{path.name}.",
        suffix=".tmp",
        dir=path.parent,
    )
    temporary_path = Path(temporary)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(content)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary_path, path)
    except BaseException:
        temporary_path.unlink(missing_ok=True)
        raise


def canonicalize_tree(root: Path) -> None:
    for path in sorted(root.rglob("*.json")):
        canonicalize_file(path)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("root", type=Path)
    args = parser.parse_args()
    canonicalize_tree(args.root)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
