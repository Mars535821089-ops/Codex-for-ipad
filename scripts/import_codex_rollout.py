#!/usr/bin/env python3
"""Import one explicitly selected desktop Codex rollout through CodexCore FFI."""

from __future__ import annotations

import argparse
import dataclasses
import datetime as dt
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import uuid
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple, Union


ROOT = Path(__file__).resolve().parents[1]
CORE = ROOT / "CodexCore"
BRIDGE_SOURCE = ROOT / "scripts/codex_core_rollout_import_bridge.c"
TEST_FIXTURES = (ROOT / "tests/fixtures").resolve()
DEFAULT_SESSIONS_ROOT = (Path.home() / ".codex/sessions").resolve()
DEFAULT_BRIDGE_CACHE = ROOT / ".update-state/rollout-import-bridge"
IMPORT_NAMESPACE = uuid.UUID("42354441-2f08-5f78-a4f8-56a0aaf0a3b6")
UUID_RE = re.compile(
    r"^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-"
    r"[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$"
)
OUTER_TYPE_RE = re.compile(br'"type"\s*:\s*"([^"]+)"')
SourceValue = Union[str, Dict[str, Any]]


class RolloutImportError(RuntimeError):
    def __init__(self, code: str):
        super().__init__(code)
        self.code = code


@dataclasses.dataclass(frozen=True)
class ParsedRollout:
    input_path: Path
    input_sha256: str
    input_bytes: int
    input_records: int
    session_meta_records: int
    workspace_id: str
    thread_id: str
    session_id: str
    turn_id: str
    user_item_id: str
    assistant_item_id: Optional[str]
    cwd: str
    cli_version: str
    model_provider: str
    source: SourceValue
    thread_source: Optional[str]
    forked_from_id: Optional[str]
    parent_thread_id: Optional[str]
    agent_nickname: Optional[str]
    agent_role: Optional[str]
    created_at: int
    user_timestamp: int
    assistant_timestamp: Optional[int]
    user_text: str
    assistant_text: Optional[str]
    title: str
    history_mode: Optional[str]


@dataclasses.dataclass(frozen=True)
class ImportOutcome:
    rollout: ParsedRollout
    summary: Dict[str, Union[int, str]]
    thread_list: Dict[str, Any]
    thread_read: Dict[str, Any]


@dataclasses.dataclass(frozen=True)
class _Message:
    index: int
    timestamp: int
    text: str
    raw_id: Optional[str]


def _sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def _json_bytes(value: Any) -> bytes:
    return json.dumps(
        value, ensure_ascii=False, separators=(",", ":"), sort_keys=True
    ).encode("utf-8")


def _timestamp(value: Any) -> int:
    if isinstance(value, bool):
        raise RolloutImportError("invalid-timestamp")
    if isinstance(value, (int, float)):
        if value < 0:
            raise RolloutImportError("invalid-timestamp")
        return int(value)
    if not isinstance(value, str) or not value.strip():
        raise RolloutImportError("missing-timestamp")
    normalized = value.strip()
    if normalized.endswith("Z"):
        normalized = normalized[:-1] + "+00:00"
    try:
        parsed = dt.datetime.fromisoformat(normalized)
    except ValueError as error:
        raise RolloutImportError("invalid-timestamp") from error
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=dt.timezone.utc)
    result = int(parsed.timestamp())
    if result < 0:
        raise RolloutImportError("invalid-timestamp")
    return result


def _stable_uuid(raw: Optional[str], scope: str) -> str:
    candidate = raw.strip() if isinstance(raw, str) else ""
    if UUID_RE.fullmatch(candidate):
        return str(uuid.UUID(candidate))
    return str(uuid.uuid5(IMPORT_NAMESPACE, scope + "\0" + candidate))


def _unique_uuid(raw: Optional[str], scope: str, used: set) -> str:
    candidate = _stable_uuid(raw, scope)
    attempt = 0
    while candidate.lower() in used:
        attempt += 1
        candidate = str(
            uuid.uuid5(
                IMPORT_NAMESPACE,
                scope + "\0collision\0" + str(attempt) + "\0" + (raw or ""),
            )
        )
    used.add(candidate.lower())
    return candidate


def _optional_text(value: Any) -> Optional[str]:
    if not isinstance(value, str):
        return None
    stripped = value.strip()
    return stripped or None


def _source_id_key(key: str) -> bool:
    lowered = key.lower()
    return lowered == "id" or lowered.endswith("_id") or key.endswith("Id")


def _map_source_value(value: Any, scope: str) -> Any:
    if isinstance(value, dict):
        mapped: Dict[str, Any] = {}
        for key, child in value.items():
            if _source_id_key(str(key)) and isinstance(child, str):
                mapped[str(key)] = _stable_uuid(child, scope + "." + str(key))
            else:
                mapped[str(key)] = _map_source_value(
                    child, scope + "." + str(key)
                )
        return mapped
    if isinstance(value, list):
        return [
            _map_source_value(child, scope + "." + str(index))
            for index, child in enumerate(value)
        ]
    return value


def _source(value: Any) -> SourceValue:
    if isinstance(value, dict):
        subagent = value.get("subagent", value.get("subAgent"))
        if subagent is not None:
            return {
                "subAgent": _map_source_value(subagent, "source.subagent")
            }
        return "unknown"
    if not isinstance(value, str) or not value.strip():
        return "unknown"
    normalized = value.strip()
    aliases = {
        "cli": "cli",
        "vscode": "vscode",
        "vs_code": "vscode",
        "exec": "exec",
        "appserver": "appServer",
        "app_server": "appServer",
        "appServer": "appServer",
        "unknown": "unknown",
    }
    known = aliases.get(normalized, aliases.get(normalized.lower()))
    if known is not None:
        return known
    return {"custom": normalized}


def _outer_type(raw_line: bytes) -> Optional[str]:
    match = OUTER_TYPE_RE.search(raw_line[:4096])
    if match is None:
        return None
    try:
        return match.group(1).decode("ascii")
    except UnicodeDecodeError:
        return None


def _message_text(payload: Dict[str, Any], content_type: str) -> Optional[str]:
    content = payload.get("content")
    if not isinstance(content, list):
        return None
    parts: List[str] = []
    for item in content:
        if (
            isinstance(item, dict)
            and item.get("type") == content_type
            and isinstance(item.get("text"), str)
        ):
            parts.append(item["text"])
    text = "".join(parts)
    return text if text.strip() else None


def _title(text: str) -> str:
    first_line = next(
        (line.strip() for line in text.splitlines() if line.strip()), ""
    )
    if not first_line:
        raise RolloutImportError("empty-user-message")
    return first_line[:120]


def parse_rollout(input_path: Path) -> ParsedRollout:
    path = Path(input_path).expanduser().resolve()
    hasher = hashlib.sha256()
    input_bytes = 0
    input_records = 0
    session_meta_records = 0
    session_meta: Optional[Dict[str, Any]] = None
    session_meta_outer_timestamp: Any = None
    first_user: Optional[_Message] = None
    first_assistant: Optional[_Message] = None
    prior_turn_id: Optional[str] = None
    mapped_turn_id: Optional[str] = None

    try:
        source_file = path.open("rb")
    except OSError as error:
        raise RolloutImportError("input-open-failed") from error

    with source_file:
        for index, raw_line in enumerate(source_file, 1):
            hasher.update(raw_line)
            input_bytes += len(raw_line)
            if not raw_line.strip():
                continue
            input_records += 1
            record_type = _outer_type(raw_line)
            if record_type not in {
                "session_meta",
                "response_item",
                "event_msg",
                "turn_context",
            }:
                continue
            try:
                record = json.loads(raw_line)
            except (UnicodeDecodeError, json.JSONDecodeError) as error:
                raise RolloutImportError("invalid-json-record") from error
            payload = record.get("payload")
            if not isinstance(payload, dict):
                continue

            if record_type == "session_meta":
                session_meta_records += 1
                if session_meta is None:
                    session_meta = payload
                    session_meta_outer_timestamp = record.get("timestamp")
                continue

            if record_type == "turn_context":
                raw_turn_id = _optional_text(payload.get("turn_id"))
                if first_user is None:
                    prior_turn_id = raw_turn_id or prior_turn_id
                elif mapped_turn_id is None:
                    mapped_turn_id = raw_turn_id
                continue

            if first_user is None:
                user_text: Optional[str] = None
                raw_user_id: Optional[str] = None
                if (
                    record_type == "response_item"
                    and payload.get("type") == "message"
                    and payload.get("role") == "user"
                ):
                    user_text = _message_text(payload, "input_text")
                    raw_user_id = _optional_text(payload.get("id"))
                elif (
                    record_type == "event_msg"
                    and payload.get("type") == "user_message"
                    and isinstance(payload.get("message"), str)
                    and payload["message"].strip()
                ):
                    user_text = payload["message"]
                if user_text is not None:
                    first_user = _Message(
                        index=index,
                        timestamp=_timestamp(record.get("timestamp")),
                        text=user_text,
                        raw_id=raw_user_id,
                    )
                    mapped_turn_id = None
                continue

            if first_assistant is None and index > first_user.index:
                if (
                    record_type == "response_item"
                    and payload.get("type") == "message"
                    and payload.get("role") == "assistant"
                ):
                    assistant_text = _message_text(payload, "output_text")
                    if assistant_text is not None:
                        first_assistant = _Message(
                            index=index,
                            timestamp=_timestamp(record.get("timestamp")),
                            text=assistant_text,
                            raw_id=_optional_text(payload.get("id")),
                        )

    if session_meta_records != 1 or session_meta is None:
        raise RolloutImportError("session-meta-count")
    if first_user is None:
        raise RolloutImportError("missing-user-message")

    cwd = _optional_text(session_meta.get("cwd"))
    if cwd is None or not Path(cwd).is_absolute():
        raise RolloutImportError("invalid-session-cwd")
    cli_version = _optional_text(session_meta.get("cli_version"))
    model_provider = _optional_text(session_meta.get("model_provider"))
    if cli_version is None:
        raise RolloutImportError("missing-cli-version")
    if model_provider is None:
        raise RolloutImportError("missing-model-provider")

    created_at = _timestamp(
        session_meta.get("timestamp", session_meta_outer_timestamp)
    )
    if first_user.timestamp < created_at:
        raise RolloutImportError("non-monotonic-user-timestamp")
    if (
        first_assistant is not None
        and first_assistant.timestamp < first_user.timestamp
    ):
        raise RolloutImportError("non-monotonic-assistant-timestamp")

    used: set = set()
    workspace_id = _unique_uuid(None, "workspace:" + cwd, used)
    raw_session_id = _optional_text(
        session_meta.get("session_id")
    ) or _optional_text(session_meta.get("id"))
    thread_id = _unique_uuid(raw_session_id, "thread", used)
    turn_id = _unique_uuid(
        mapped_turn_id or prior_turn_id, "turn:" + thread_id, used
    )
    user_item_id = _unique_uuid(
        first_user.raw_id, "user-item:" + thread_id, used
    )
    assistant_item_id = (
        _unique_uuid(
            first_assistant.raw_id, "assistant-item:" + thread_id, used
        )
        if first_assistant is not None
        else None
    )

    return ParsedRollout(
        input_path=path,
        input_sha256=hasher.hexdigest(),
        input_bytes=input_bytes,
        input_records=input_records,
        session_meta_records=session_meta_records,
        workspace_id=workspace_id,
        thread_id=thread_id,
        session_id=thread_id,
        turn_id=turn_id,
        user_item_id=user_item_id,
        assistant_item_id=assistant_item_id,
        cwd=cwd,
        cli_version=cli_version,
        model_provider=model_provider,
        source=_source(session_meta.get("source")),
        thread_source=_optional_text(session_meta.get("thread_source")),
        forked_from_id=(
            _stable_uuid(
                _optional_text(session_meta.get("forked_from_id")),
                "forked-from:" + thread_id,
            )
            if _optional_text(session_meta.get("forked_from_id"))
            else None
        ),
        parent_thread_id=(
            _stable_uuid(
                _optional_text(session_meta.get("parent_thread_id")),
                "parent-thread:" + thread_id,
            )
            if _optional_text(session_meta.get("parent_thread_id"))
            else None
        ),
        agent_nickname=_optional_text(session_meta.get("agent_nickname")),
        agent_role=_optional_text(session_meta.get("agent_role")),
        created_at=created_at,
        user_timestamp=first_user.timestamp,
        assistant_timestamp=(
            first_assistant.timestamp if first_assistant is not None else None
        ),
        user_text=first_user.text,
        assistant_text=(
            first_assistant.text if first_assistant is not None else None
        ),
        title=_title(first_user.text),
        history_mode=_optional_text(session_meta.get("history_mode")),
    )


def build_persistence_commands(rollout: ParsedRollout) -> List[Dict[str, Any]]:
    metadata: Dict[str, Any] = {
        "sessionId": rollout.session_id,
        "forkedFromId": rollout.forked_from_id,
        "preview": rollout.user_text,
        "ephemeral": rollout.history_mode in {"ephemeral", "transient"},
        "modelProvider": rollout.model_provider,
        "createdAt": rollout.created_at,
        "updatedAt": rollout.created_at,
        "recencyAt": rollout.created_at,
        "path": str(rollout.input_path),
        "cwd": rollout.cwd,
        "cliVersion": rollout.cli_version,
        "source": rollout.source,
        "threadSource": rollout.thread_source,
        "parentThreadId": rollout.parent_thread_id,
        "agentNickname": rollout.agent_nickname,
        "agentRole": rollout.agent_role,
    }
    commands: List[Dict[str, Any]] = [
        {
            "kind": "workspace.open",
            "workspace": {
                "id": rollout.workspace_id,
                "displayName": Path(rollout.cwd).name or rollout.cwd,
                "rootBookmarkId": None,
            },
        },
        {
            "kind": "thread.start",
            "thread": {
                "id": rollout.thread_id,
                "workspaceId": rollout.workspace_id,
                "title": rollout.title,
            },
            "metadata": metadata,
        },
        {
            "kind": "turn.start",
            "turn": {
                "id": rollout.turn_id,
                "threadId": rollout.thread_id,
                "status": "running",
            },
            "userItem": {
                "id": rollout.user_item_id,
                "threadId": rollout.thread_id,
                "turnId": rollout.turn_id,
                "kind": "userMessage",
                "text": rollout.user_text,
            },
            "timestamp": rollout.user_timestamp,
        },
    ]
    if (
        rollout.assistant_text is not None
        and rollout.assistant_item_id is not None
        and rollout.assistant_timestamp is not None
    ):
        commands.append(
            {
                "kind": "turn.complete",
                "turnId": rollout.turn_id,
                "assistantItem": {
                    "id": rollout.assistant_item_id,
                    "threadId": rollout.thread_id,
                    "turnId": rollout.turn_id,
                    "kind": "assistantMessage",
                    "text": rollout.assistant_text,
                },
                "timestamp": rollout.assistant_timestamp,
            }
        )
    return commands


def dry_run_summary(rollout: ParsedRollout) -> Dict[str, Union[int, str]]:
    commands = build_persistence_commands(rollout)
    mapped_ids = [
        rollout.workspace_id,
        rollout.thread_id,
        rollout.session_id,
        rollout.turn_id,
        rollout.user_item_id,
        rollout.assistant_item_id,
        rollout.forked_from_id,
        rollout.parent_thread_id,
    ]
    content = rollout.user_text.encode("utf-8") + b"\0"
    if rollout.assistant_text is not None:
        content += rollout.assistant_text.encode("utf-8")
    return {
        "assistantMessagesMapped": int(rollout.assistant_text is not None),
        "commandsPrepared": len(commands),
        "inputBytes": rollout.input_bytes,
        "inputRecords": rollout.input_records,
        "inputSha256": rollout.input_sha256,
        "mappedContentSha256": _sha256_bytes(content),
        "mappedIdsSha256": _sha256_bytes(_json_bytes(mapped_ids)),
        "sessionMetaRecords": rollout.session_meta_records,
        "timestampFieldsMapped": 2
        + int(rollout.assistant_timestamp is not None),
        "userMessagesMapped": 1,
    }


def _is_within(path: Path, directory: Path) -> bool:
    try:
        path.relative_to(directory)
        return True
    except ValueError:
        return False


def _selected_input(input_path: Path, allow_test_fixture: bool) -> Path:
    path = Path(input_path).expanduser().resolve()
    if path.suffix != ".jsonl" or not path.is_file():
        raise RolloutImportError("input-not-jsonl-file")
    if allow_test_fixture:
        if not _is_within(path, TEST_FIXTURES):
            raise RolloutImportError("fixture-outside-test-root")
    elif not _is_within(path, DEFAULT_SESSIONS_ROOT):
        raise RolloutImportError("input-outside-home-sessions")
    return path


def _run_checked(command: List[str], cwd: Path, error_code: str) -> None:
    result = subprocess.run(
        command,
        cwd=cwd,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if result.returncode != 0:
        raise RolloutImportError(error_code)


def _ensure_bridge(bridge_cache: Path) -> Path:
    cache = Path(bridge_cache).expanduser().resolve()
    cache.mkdir(parents=True, exist_ok=True)
    binary = cache / "codex-core-rollout-import-bridge"
    library = CORE / "target/debug/libcodex_core.a"
    cargo = shutil.which("cargo")
    compiler = os.environ.get("CC") or shutil.which("cc")
    if cargo is None:
        raise RolloutImportError("cargo-not-found")
    if compiler is None:
        raise RolloutImportError("c-compiler-not-found")

    _run_checked(
        [cargo, "build", "--locked", "--quiet", "--lib"],
        CORE,
        "codexcore-build-failed",
    )
    rebuild = not binary.is_file()
    if not rebuild:
        binary_mtime = binary.stat().st_mtime_ns
        rebuild = any(
            source.stat().st_mtime_ns > binary_mtime
            for source in (BRIDGE_SOURCE, CORE / "include/codex_core.h", library)
        )
    if rebuild:
        _run_checked(
            [
                compiler,
                "-std=c11",
                "-O2",
                "-I",
                str(CORE / "include"),
                str(BRIDGE_SOURCE),
                str(library),
                "-o",
                str(binary),
                "-framework",
                "CFNetwork",
                "-framework",
                "CoreFoundation",
                "-framework",
                "Security",
                "-framework",
                "SystemConfiguration",
                "-lz",
                "-liconv",
                "-lSystem",
                "-lc",
                "-lm",
            ],
            ROOT,
            "ffi-bridge-build-failed",
        )
        binary.chmod(0o700)
    return binary


def _write_jsonl(path: Path, values: List[Dict[str, Any]]) -> None:
    with path.open("wb") as output:
        for value in values:
            output.write(_json_bytes(value))
            output.write(b"\n")
    path.chmod(0o600)


def _remove_partial_database(database: Path) -> None:
    for suffix in ("", "-wal", "-shm"):
        candidate = Path(str(database) + suffix)
        try:
            candidate.unlink()
        except FileNotFoundError:
            pass


def _verify_responses(
    rollout: ParsedRollout,
    thread_list: Dict[str, Any],
    thread_read: Dict[str, Any],
) -> Tuple[int, int]:
    try:
        listed = thread_list["result"]["data"]
        thread = thread_read["result"]["thread"]
        turns = thread["turns"]
    except (KeyError, TypeError) as error:
        raise RolloutImportError("verification-response-shape") from error
    if (
        not isinstance(listed, list)
        or len(listed) != 1
        or listed[0].get("id") != rollout.thread_id
        or listed[0].get("cwd") != rollout.cwd
        or listed[0].get("sessionId") != rollout.session_id
        or listed[0].get("createdAt") != rollout.created_at
        or not isinstance(turns, list)
        or len(turns) != 1
    ):
        raise RolloutImportError("verification-metadata-mismatch")
    items = turns[0].get("items")
    if not isinstance(items, list) or not items:
        raise RolloutImportError("verification-items-missing")
    try:
        mapped_user = items[0]["content"][0]["text"]
    except (KeyError, IndexError, TypeError) as error:
        raise RolloutImportError("verification-user-shape") from error
    if mapped_user != rollout.user_text:
        raise RolloutImportError("verification-user-mismatch")
    if rollout.assistant_text is not None:
        if len(items) < 2 or items[1].get("text") != rollout.assistant_text:
            raise RolloutImportError("verification-assistant-mismatch")
    return len(listed), len(turns)


def import_rollout(
    *,
    input_path: Path,
    database_path: Path,
    snapshot_directory: Path,
    allow_test_fixture: bool = False,
    bridge_cache: Path = DEFAULT_BRIDGE_CACHE,
) -> ImportOutcome:
    selected = _selected_input(input_path, allow_test_fixture)
    database = Path(database_path).expanduser().resolve()
    snapshots = Path(snapshot_directory).expanduser().resolve()
    if database.exists():
        raise RolloutImportError("database-already-exists")
    database.parent.mkdir(parents=True, exist_ok=True)
    snapshots.mkdir(parents=True, exist_ok=True)

    rollout = parse_rollout(selected)
    commands = build_persistence_commands(rollout)
    bridge = _ensure_bridge(bridge_cache)
    storage_open = {
        "kind": "storage.open",
        "databasePath": str(database),
        "snapshotDirectory": str(snapshots),
    }
    requests = [
        {
            "id": "verify-list",
            "method": "thread/list",
            "params": {
                "modelProviders": [],
                "sourceKinds": [
                    "cli",
                    "vscode",
                    "exec",
                    "appServer",
                    "subAgent",
                    "subAgentReview",
                    "subAgentCompact",
                    "subAgentThreadSpawn",
                    "subAgentOther",
                    "unknown",
                ],
            },
        },
        {
            "id": "verify-read",
            "method": "thread/read",
            "params": {
                "threadId": rollout.thread_id,
                "includeTurns": True,
            },
        },
    ]

    try:
        with tempfile.TemporaryDirectory(
            prefix="codex-rollout-import-"
        ) as temporary:
            temporary_root = Path(temporary)
            command_file = temporary_root / "commands.jsonl"
            request_file = temporary_root / "requests.jsonl"
            response_file = temporary_root / "responses.jsonl"
            metrics_file = temporary_root / "metrics.txt"
            _write_jsonl(command_file, [storage_open] + commands)
            _write_jsonl(request_file, requests)
            result = subprocess.run(
                [
                    str(bridge),
                    str(command_file),
                    str(request_file),
                    str(response_file),
                    str(metrics_file),
                ],
                cwd=ROOT,
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
            )
            if result.returncode != 0:
                raise RolloutImportError("ffi-import-failed")
            try:
                metrics = [
                    int(value)
                    for value in metrics_file.read_text(
                        encoding="ascii"
                    ).split()
                ]
                responses = [
                    json.loads(line)
                    for line in response_file.read_text(
                        encoding="utf-8"
                    ).splitlines()
                    if line
                ]
            except (OSError, ValueError, json.JSONDecodeError) as error:
                raise RolloutImportError("ffi-output-invalid") from error
    except Exception:
        _remove_partial_database(database)
        raise

    if len(metrics) != 4 or metrics[0] != len(commands) + 1:
        _remove_partial_database(database)
        raise RolloutImportError("ffi-metrics-invalid")
    if len(responses) != 2 or metrics[3] != 2:
        _remove_partial_database(database)
        raise RolloutImportError("ffi-response-count")
    if metrics[1] != metrics[2]:
        _remove_partial_database(database)
        raise RolloutImportError("ffi-replay-count")
    thread_list, thread_read = responses
    try:
        list_count, turn_count = _verify_responses(
            rollout, thread_list, thread_read
        )
    except Exception:
        _remove_partial_database(database)
        raise

    summary = dry_run_summary(rollout)
    summary.update(
        {
            "databaseSha256": _sha256_bytes(database.read_bytes()),
            "persistedEvents": metrics[1],
            "replayedEvents": metrics[2],
            "threadListCount": list_count,
            "threadListSha256": _sha256_bytes(
                _json_bytes(thread_list)
            ),
            "threadReadSha256": _sha256_bytes(
                _json_bytes(thread_read)
            ),
            "threadReadTurnCount": turn_count,
        }
    )
    return ImportOutcome(
        rollout=rollout,
        summary=summary,
        thread_list=thread_list,
        thread_read=thread_read,
    )


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description=(
            "Import one explicitly selected ~/.codex/sessions JSONL through "
            "CodexCore commands and FFI."
        )
    )
    parser.add_argument("--input", required=True, type=Path)
    parser.add_argument("--database", type=Path)
    parser.add_argument("--snapshot-directory", type=Path)
    parser.add_argument("--bridge-cache", type=Path, default=DEFAULT_BRIDGE_CACHE)
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument(
        "--allow-test-fixture",
        action="store_true",
        help=argparse.SUPPRESS,
    )
    return parser


def main(argv: Optional[List[str]] = None) -> int:
    arguments = _parser().parse_args(argv)
    try:
        selected = _selected_input(
            arguments.input, arguments.allow_test_fixture
        )
        if arguments.dry_run:
            summary = dry_run_summary(parse_rollout(selected))
        else:
            if arguments.database is None:
                raise RolloutImportError("database-required")
            snapshots = arguments.snapshot_directory
            if snapshots is None:
                snapshots = arguments.database.parent / "MigrationSnapshots"
            summary = import_rollout(
                input_path=selected,
                database_path=arguments.database,
                snapshot_directory=snapshots,
                allow_test_fixture=arguments.allow_test_fixture,
                bridge_cache=arguments.bridge_cache,
            ).summary
        print(
            json.dumps(
                summary,
                ensure_ascii=True,
                separators=(",", ":"),
                sort_keys=True,
            )
        )
        return 0
    except RolloutImportError as error:
        print(
            json.dumps(
                {"errorCode": error.code},
                separators=(",", ":"),
                sort_keys=True,
            ),
            file=sys.stderr,
        )
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
