#!/usr/bin/env python3
"""Validate and durably consume update requests emitted by Codex for ipad."""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import tempfile
from pathlib import Path
from typing import Any


OPERATIONS = {"checkForUpdates", "installUpdate"}
REQUIRED_KEYS = {
    "schemaVersion",
    "requestID",
    "operation",
    "requestedAt",
    "beta",
    "planType",
}


def _read_request(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise ValueError(f"cannot read update request: {exc}") from exc
    if not isinstance(value, dict):
        raise ValueError("update request must be a JSON object")
    if set(value) != REQUIRED_KEYS:
        raise ValueError("update request keys do not match schema")
    if value.get("schemaVersion") != 1:
        raise ValueError("schemaVersion must be 1")
    request_id = value.get("requestID")
    if not isinstance(request_id, str) or not request_id.strip():
        raise ValueError("requestID must be a non-empty string")
    operation = value.get("operation")
    if operation not in OPERATIONS:
        raise ValueError(f"unsupported operation: {operation!r}")
    requested_at = value.get("requestedAt")
    if not isinstance(requested_at, str) or not requested_at.strip():
        raise ValueError("requestedAt must be a non-empty string")
    try:
        dt.datetime.fromisoformat(requested_at.replace("Z", "+00:00"))
    except ValueError as exc:
        raise ValueError("requestedAt must be ISO-8601") from exc
    if not isinstance(value.get("beta"), bool):
        raise ValueError("beta must be boolean")
    plan_type = value.get("planType")
    if not isinstance(plan_type, str) or not plan_type.strip():
        raise ValueError("planType must be a non-empty string")
    return value


def _read_state(path: Path) -> dict[str, Any]:
    if not path.exists():
        return {"schemaVersion": 1, "requestIDs": []}
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise ValueError(f"cannot read consumed request state: {exc}") from exc
    if not isinstance(value, dict) or value.get("schemaVersion") != 1:
        raise ValueError("consumed request state schemaVersion must be 1")
    request_ids = value.get("requestIDs")
    if not isinstance(request_ids, list) or not all(
        isinstance(item, str) and item for item in request_ids
    ):
        raise ValueError("consumed request state requestIDs must be strings")
    return {"schemaVersion": 1, "requestIDs": list(dict.fromkeys(request_ids))}


def _atomic_write(path: Path, value: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            json.dump(value, stream, indent=2, sort_keys=True)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass


def main() -> int:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)

    validate = subparsers.add_parser("validate")
    validate.add_argument("--request", type=Path, required=True)
    validate.add_argument("--output", type=Path)

    mark = subparsers.add_parser("mark-consumed")
    mark.add_argument("--request", type=Path, required=True)
    mark.add_argument("--state", type=Path, required=True)

    consumed = subparsers.add_parser("is-consumed")
    consumed.add_argument("--request", type=Path, required=True)
    consumed.add_argument("--state", type=Path, required=True)

    args = parser.parse_args()
    try:
        request = _read_request(args.request)
        if args.command == "validate":
            if args.output:
                _atomic_write(args.output, request)
            else:
                json.dump(request, sort_keys=True)
                print()
            return 0

        state = _read_state(args.state)
        request_id = request["requestID"]
        if args.command == "is-consumed":
            return 0 if request_id in state["requestIDs"] else 1
        if request_id in state["requestIDs"]:
            raise ValueError(f"requestID already consumed: {request_id}")
        state["requestIDs"].append(request_id)
        _atomic_write(args.state, state)
        return 0
    except ValueError as exc:
        print(str(exc), file=os.sys.stderr)
        return 10


if __name__ == "__main__":
    raise SystemExit(main())
