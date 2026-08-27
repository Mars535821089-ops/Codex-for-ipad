#!/usr/bin/env python3
"""Bind iPad XCUI verification to exact source and artifact evidence."""

from __future__ import annotations

import argparse
import datetime
import hashlib
import json
import math
import os
from pathlib import Path
import re
import sys
from typing import Mapping

if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from scripts.protocol_manifest import (
    load_json_object,
    sha256_file,
    write_json_atomic,
)


HEAD_PATTERN = re.compile(r"^[0-9a-f]{40}$")
XCUI_FIELDS = ("xcuiTests", "xcuiTestCount", "xcuiEvidence")


def _tree_sha256(root: Path) -> str:
    root = root.resolve()
    if not root.is_dir():
        raise ValueError("XCResult bundle is missing")
    digest = hashlib.sha256()
    file_count = 0
    for path in sorted(root.rglob("*"), key=lambda item: item.as_posix()):
        relative = path.relative_to(root).as_posix()
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
            file_count += 1
            digest.update(b"F\0")
            digest.update(relative.encode())
            digest.update(b"\0")
            with path.open("rb") as stream:
                for block in iter(lambda: stream.read(1024 * 1024), b""):
                    digest.update(block)
            digest.update(b"\0")
        else:
            raise ValueError(f"unsupported XCResult entry: {relative}")
    if file_count == 0:
        raise ValueError("XCResult bundle contains no files")
    return digest.hexdigest()


def _relative_evidence(
    project_root: Path,
    path: Path,
    *,
    directory: bool = False,
) -> dict[str, str]:
    project_root = project_root.resolve()
    path = path.resolve()
    try:
        relative = path.relative_to(project_root).as_posix()
    except ValueError as error:
        raise ValueError("verification evidence escapes the project root") from error
    if directory:
        digest = _tree_sha256(path)
    else:
        if not path.is_file() or path.stat().st_size == 0:
            raise ValueError(f"verification evidence is missing: {path}")
        digest = sha256_file(path)
    return {"path": relative, "sha256": digest}


def _load_existing_record(path: Path) -> dict[str, object]:
    if not path.exists():
        return {}
    return load_json_object(path)


def invalidate_xcui_evidence(record_path: Path) -> None:
    if not record_path.exists():
        return
    record = load_json_object(record_path)
    changed = False
    for field in XCUI_FIELDS:
        if field in record:
            del record[field]
            changed = True
    if changed:
        write_json_atomic(record_path, record)


def _require_count(summary: Mapping[str, object], field: str) -> int:
    value = summary.get(field)
    if isinstance(value, bool) or not isinstance(value, int) or value < 0:
        raise ValueError(f"XCResult summary {field} is malformed")
    return value


def _require_time(summary: Mapping[str, object], field: str) -> int | float:
    value = summary.get(field)
    if (
        isinstance(value, bool)
        or not isinstance(value, (int, float))
        or not math.isfinite(value)
        or value < 0
    ):
        raise ValueError(f"XCResult summary {field} is malformed")
    return value


def record_xcui_evidence(
    record_path: Path,
    *,
    project_root: Path,
    summary_path: Path,
    xcresult_path: Path,
    source_head: str,
    contract_path: Path,
    logs: Mapping[str, Path],
    verified_at: str | None = None,
) -> dict[str, object]:
    if HEAD_PATTERN.fullmatch(source_head) is None:
        raise ValueError("source HEAD is malformed")
    summary = load_json_object(summary_path)
    total = _require_count(summary, "totalTestCount")
    passed = _require_count(summary, "passedTests")
    failed = _require_count(summary, "failedTests")
    skipped = _require_count(summary, "skippedTests")
    expected_failures = _require_count(summary, "expectedFailures")
    start_time = _require_time(summary, "startTime")
    finish_time = _require_time(summary, "finishTime")
    if (
        summary.get("result") != "Passed"
        or total <= 0
        or failed != 0
        or expected_failures != 0
        or skipped != 0
        or passed != total
        or finish_time < start_time
    ):
        raise ValueError("XCResult summary did not pass")
    if not logs:
        raise ValueError("XCResult verification logs are missing")

    log_evidence: dict[str, dict[str, str]] = {}
    for name, path in sorted(logs.items()):
        if not name or not re.fullmatch(r"[a-z0-9-]+", name):
            raise ValueError("XCResult verification log name is malformed")
        log_evidence[name] = _relative_evidence(project_root, path)

    if verified_at is None:
        verified_at = datetime.datetime.now(datetime.timezone.utc).isoformat(
            timespec="seconds"
        ).replace("+00:00", "Z")
    xcresult_evidence = _relative_evidence(
        project_root,
        xcresult_path,
        directory=True,
    )
    xcresult_evidence["hashAlgorithm"] = "sha256-xcresult-tree-v1"
    evidence: dict[str, object] = {
        "result": "Passed",
        "totalTestCount": total,
        "passedTests": passed,
        "failedTests": failed,
        "skippedTests": skipped,
        "expectedFailures": expected_failures,
        "startTime": start_time,
        "finishTime": finish_time,
        "generatedAt": verified_at,
        "gitHead": source_head,
        "parityContract": _relative_evidence(project_root, contract_path),
        "summary": _relative_evidence(project_root, summary_path),
        "xcresult": xcresult_evidence,
        "logs": log_evidence,
    }
    record = _load_existing_record(record_path)
    record["xcuiTests"] = "passed"
    record["xcuiTestCount"] = total
    record["xcuiEvidence"] = evidence
    write_json_atomic(record_path, record)
    return evidence


def _parse_log(value: str) -> tuple[str, Path]:
    name, separator, raw_path = value.partition("=")
    if not separator or not raw_path:
        raise argparse.ArgumentTypeError("log must be NAME=PATH")
    return name, Path(raw_path)


def main() -> int:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)
    invalidate = subparsers.add_parser("invalidate")
    invalidate.add_argument("--record", type=Path, required=True)
    record = subparsers.add_parser("record")
    record.add_argument("--record", type=Path, required=True)
    record.add_argument("--project-root", type=Path, required=True)
    record.add_argument("--summary", type=Path, required=True)
    record.add_argument("--xcresult", type=Path, required=True)
    record.add_argument("--source-head", required=True)
    record.add_argument("--contract", type=Path, required=True)
    record.add_argument("--log", action="append", type=_parse_log, default=[])
    args = parser.parse_args()
    try:
        if args.command == "invalidate":
            invalidate_xcui_evidence(args.record)
        else:
            record_xcui_evidence(
                args.record,
                project_root=args.project_root,
                summary_path=args.summary,
                xcresult_path=args.xcresult,
                source_head=args.source_head,
                contract_path=args.contract,
                logs=dict(args.log),
            )
    except (OSError, ValueError, TypeError, json.JSONDecodeError) as error:
        parser.error(str(error))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
