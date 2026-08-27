from __future__ import annotations

import hashlib
import json
import os
import re
from pathlib import Path
from typing import Mapping

VERSION_PATTERN = re.compile(r"^[0-9]+(?:\.[0-9A-Za-z-]+)+$")


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def validate_version(value: str) -> str:
    if not VERSION_PATTERN.fullmatch(value):
        raise ValueError(f"invalid version: {value!r}")
    return value


def assert_within(path: Path, root: Path) -> Path:
    resolved_root = root.resolve()
    resolved_path = path.resolve()
    if (
        resolved_path != resolved_root
        and resolved_root not in resolved_path.parents
    ):
        raise ValueError(f"path escapes root: {resolved_path}")
    return resolved_path


def write_json_atomic(path: Path, payload: Mapping[str, object]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.{os.getpid()}")
    with temporary.open("w", encoding="utf-8") as stream:
        json.dump(
            payload,
            stream,
            ensure_ascii=False,
            indent=2,
            sort_keys=True,
        )
        stream.write("\n")
        stream.flush()
        os.fsync(stream.fileno())
    os.replace(temporary, path)


def load_json_object(path: Path) -> dict[str, object]:
    payload = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(payload, dict):
        raise ValueError(f"expected JSON object: {path}")
    return payload
