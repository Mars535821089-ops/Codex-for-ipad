#!/usr/bin/env python3
"""Verify that the iPad preload bridge exposes every official bridge API key."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import re
import sys

if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from scripts.protocol_manifest import write_json_atomic


EXPOSE_PATTERN = re.compile(
    r"exposeInMainWorld\(\s*[`'\"]electronBridge[`'\"]\s*,\s*"
    r"([A-Za-z_$][A-Za-z0-9_$]*)\s*\)"
)


def _object_start(source: str, identifier: str) -> int:
    pattern = re.compile(
        rf"(?:const|let|var)?\s*{re.escape(identifier)}\s*=\s*\{{"
    )
    matches = list(pattern.finditer(source))
    if not matches:
        raise ValueError(f"bridge object is missing: {identifier}")
    return matches[-1].end() - 1


def _top_level_keys(source: str, object_start: int) -> tuple[str, ...]:
    keys: list[str] = []
    depth = 0
    parenthesis_depth = 0
    bracket_depth = 0
    property_start = False
    index = object_start
    quote: str | None = None
    escaped = False
    line_comment = False
    block_comment = False
    while index < len(source):
        character = source[index]
        following = source[index + 1] if index + 1 < len(source) else ""
        if line_comment:
            if character == "\n":
                line_comment = False
            index += 1
            continue
        if block_comment:
            if character == "*" and following == "/":
                block_comment = False
                index += 2
            else:
                index += 1
            continue
        if quote is not None:
            if escaped:
                escaped = False
            elif character == "\\":
                escaped = True
            elif character == quote:
                quote = None
            index += 1
            continue
        if character == "/" and following == "/":
            line_comment = True
            index += 2
            continue
        if character == "/" and following == "*":
            block_comment = True
            index += 2
            continue
        if character in ("'", '"', "`"):
            quote = character
            index += 1
            continue
        if character == "{":
            depth += 1
            if depth == 1:
                property_start = True
            index += 1
            continue
        if character == "}":
            depth -= 1
            if depth == 0:
                break
            index += 1
            continue
        if depth == 1 and character == "(":
            parenthesis_depth += 1
            property_start = False
            index += 1
            continue
        if depth == 1 and character == ")":
            parenthesis_depth = max(0, parenthesis_depth - 1)
            index += 1
            continue
        if depth == 1 and character == "[":
            bracket_depth += 1
            property_start = False
            index += 1
            continue
        if depth == 1 and character == "]":
            bracket_depth = max(0, bracket_depth - 1)
            index += 1
            continue
        if (
            depth == 1
            and parenthesis_depth == 0
            and bracket_depth == 0
            and character == ","
        ):
            property_start = True
            index += 1
            continue
        if depth == 1 and property_start and (
            character.isalpha() or character in ("_", "$")
        ):
            end = index + 1
            while end < len(source) and (
                source[end].isalnum() or source[end] in ("_", "$")
            ):
                end += 1
            cursor = end
            while cursor < len(source) and source[cursor].isspace():
                cursor += 1
            if cursor < len(source) and source[cursor] == ":":
                key = source[index:end]
                if key not in keys:
                    keys.append(key)
            property_start = False
            index = end
            continue
        if depth == 1 and not character.isspace():
            property_start = False
        index += 1
    if depth != 0:
        raise ValueError("bridge object is unterminated")
    return tuple(keys)


def official_bridge_keys(source: str) -> tuple[str, ...]:
    match = EXPOSE_PATTERN.search(source)
    if match is None:
        raise ValueError("official electronBridge exposure is missing")
    return _top_level_keys(source, _object_start(source, match.group(1)))


def ipad_bridge_keys(source: str) -> tuple[str, ...]:
    return _top_level_keys(source, _object_start(source, "bridge"))


def verify_bridge_api(
    official_preload: Path,
    ipad_bridge: Path,
) -> dict[str, object]:
    official_source = official_preload.read_text(encoding="utf-8")
    ipad_source = ipad_bridge.read_text(encoding="utf-8")
    official = official_bridge_keys(official_source)
    ipad = ipad_bridge_keys(ipad_source)
    missing = sorted(set(official) - set(ipad))
    extra = sorted(set(ipad) - set(official))
    if missing:
        raise ValueError(
            "iPad electronBridge is missing official APIs: "
            + ", ".join(missing)
        )
    return {
        "schemaVersion": 1,
        "status": "passed",
        "officialPreloadSha256": hashlib.sha256(
            official_preload.read_bytes()
        ).hexdigest(),
        "ipadBridgeSha256": hashlib.sha256(
            ipad_bridge.read_bytes()
        ).hexdigest(),
        "officialAPIKeys": list(official),
        "ipadAPIKeys": list(ipad),
        "extraIPadAPIKeys": extra,
        "officialAPICount": len(official),
        "ipadAPICount": len(ipad),
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--official-preload", type=Path, required=True)
    parser.add_argument("--ipad-bridge", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    try:
        result = verify_bridge_api(
            args.official_preload,
            args.ipad_bridge,
        )
    except (OSError, ValueError) as error:
        parser.error(str(error))
    write_json_atomic(args.output, result)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
