from __future__ import annotations

import argparse
from pathlib import Path

try:
    from .protocol_manifest import sha256_file, write_json_atomic
except ImportError:
    from protocol_manifest import sha256_file, write_json_atomic


def build_index(protocol_root: Path) -> dict[str, object]:
    files: list[dict[str, object]] = []
    for path in sorted(item for item in protocol_root.rglob("*") if item.is_file()):
        relative = path.relative_to(protocol_root).as_posix()
        parts = relative.split("/")
        if len(parts) < 3 or parts[0] not in {"typescript", "json-schema"}:
            raise ValueError(f"unexpected protocol path: {relative}")
        if parts[1] not in {"stable", "experimental"}:
            raise ValueError(f"unexpected protocol channel: {relative}")
        files.append(
            {
                "path": relative,
                "kind": parts[0],
                "channel": parts[1],
                "bytes": path.stat().st_size,
                "sha256": sha256_file(path),
            }
        )

    if not files:
        raise ValueError(f"protocol output is empty: {protocol_root}")

    return {
        "schemaVersion": 1,
        "fileCount": len(files),
        "files": files,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--protocol-root", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    write_json_atomic(args.output, build_index(args.protocol_root))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
