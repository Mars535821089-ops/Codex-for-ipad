#!/usr/bin/env python3
"""Recover literal Electron IPC callsites with release-file provenance."""

from __future__ import annotations

import argparse
from collections import defaultdict
import re
from pathlib import Path
import sys

if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from scripts.javascript_string_scanner import parse_javascript_string_at
from scripts.protocol_manifest import sha256_file, write_json_atomic


CHANNEL_PATTERN = re.compile(r"^[A-Za-z_$][A-Za-z0-9_$._:/-]{1,159}$")
CHANNEL_TEMPLATE_PATTERN = re.compile(
    r"^[A-Za-z_$][A-Za-z0-9_$._:/{}-]{1,199}$"
)
CALL_PATTERNS = (
    (re.compile(rb"ipcMain\s*\.\s*handle\s*\(\s*"), "main", "handle"),
    (re.compile(rb"ipcMain\s*\.\s*on\s*\(\s*"), "main", "on"),
    (
        re.compile(rb"ipcRenderer\s*\.\s*invoke\s*\(\s*"),
        "preload",
        "invoke",
    ),
    (
        re.compile(rb"ipcRenderer\s*\.\s*send\s*\(\s*"),
        "preload",
        "send",
    ),
    (
        re.compile(rb"ipcRenderer\s*\.\s*sendSync\s*\(\s*"),
        "preload",
        "sendSync",
    ),
    (
        re.compile(rb"ipcRenderer\s*\.\s*postMessage\s*\(\s*"),
        "preload",
        "postMessage",
    ),
    (re.compile(rb"ipcRenderer\s*\.\s*on\s*\(\s*"), "preload", "on"),
    (
        re.compile(rb"contextBridge\s*\.\s*exposeInMainWorld\s*\(\s*"),
        "preload",
        "expose",
    ),
)
IDENTIFIER = rb"[A-Za-z_$][A-Za-z0-9_$]*"
STATIC_BINDING_PATTERN = re.compile(
    rb"(?<![A-Za-z0-9_$])(" + IDENTIFIER + rb")\s*=\s*(['\"`])"
)
OBJECT_BINDING_PATTERN = re.compile(
    rb"(?<![A-Za-z0-9_$])(" + IDENTIFIER + rb")\s*=\s*\{([^{}]*)\}"
)
OBJECT_FIELD_PATTERN = re.compile(
    rb"(" + IDENTIFIER + rb")\s*:\s*(['\"`])"
)
ARGUMENT_PATTERN = re.compile(
    rb"(?:"
    + IDENTIFIER
    + rb"\."
    + IDENTIFIER
    + rb"|"
    + IDENTIFIER
    + rb"|['\"`])"
)
EXPORT_GETTER_PATTERN = re.compile(
    rb"Object\.defineProperty\(\s*exports\s*,\s*"
    rb"(['\"])([^'\"]+)\1\s*,.{0,300}?"
    rb"return\s+(" + IDENTIFIER + rb")\s*\}",
    re.DOTALL,
)
REQUIRE_PATTERN = re.compile(
    rb"(?<![A-Za-z0-9_$])("
    + IDENTIFIER
    + rb")\s*=\s*require\(\s*(['\"])([^'\"]+)\2\s*\)"
)
FUNCTION_FACTORY_PATTERN = re.compile(
    rb"function\s+("
    + IDENTIFIER
    + rb")\s*\(\s*("
    + IDENTIFIER
    + rb")\s*\)\s*\{\s*return\s*`([^`]*)`\s*\}"
)


def _static_bindings(source: bytes) -> dict[str, list[tuple[int, str]]]:
    bindings: dict[str, list[tuple[int, str]]] = defaultdict(list)
    for match in STATIC_BINDING_PATTERN.finditer(source):
        try:
            literal = parse_javascript_string_at(source, match.end() - 1)
        except ValueError:
            continue
        if literal is not None and CHANNEL_PATTERN.fullmatch(literal.value):
            bindings[match.group(1).decode("ascii")].append(
                (match.start(), literal.value)
            )
    for match in OBJECT_BINDING_PATTERN.finditer(source):
        object_name = match.group(1).decode("ascii")
        body = match.group(2)
        body_offset = match.start(2)
        for field in OBJECT_FIELD_PATTERN.finditer(body):
            try:
                literal = parse_javascript_string_at(
                    source, body_offset + field.end() - 1
                )
            except ValueError:
                continue
            if literal is not None and CHANNEL_PATTERN.fullmatch(literal.value):
                field_name = field.group(1).decode("ascii")
                bindings[f"{object_name}.{field_name}"].append(
                    (match.start(), literal.value)
                )
    for match in FUNCTION_FACTORY_PATTERN.finditer(source):
        name = match.group(1).decode("ascii")
        parameter = match.group(2)
        body = match.group(3)
        placeholder = b"${" + parameter + b"}"
        if placeholder not in body:
            continue
        normalized = body.replace(placeholder, b"${dynamic}")
        if b"${" in normalized.replace(b"${dynamic}", b""):
            continue
        value = normalized.decode("utf-8", errors="replace")
        if CHANNEL_TEMPLATE_PATTERN.fullmatch(value):
            bindings[name].append((match.start(), value))
    for values in bindings.values():
        values.sort()
    return bindings


def _resolve_call_argument(
    source: bytes,
    offset: int,
    bindings: dict[str, list[tuple[int, str]]],
) -> tuple[str, str] | None:
    match = ARGUMENT_PATTERN.match(source, offset)
    if match is None:
        return None
    expression = match.group(0)
    if expression[:1] in (b"'", b'"', b"`"):
        literal = parse_javascript_string_at(source, offset)
        if literal is None:
            return None
        return literal.value, "static-callsite"
    candidates = bindings.get(expression.decode("ascii"), [])
    preceding = [value for position, value in candidates if position < offset]
    if not preceding:
        return None
    value = preceding[-1]
    kind = (
        "static-derived-pattern-callsite"
        if "${dynamic}" in value
        else "static-derived-callsite"
    )
    return value, kind


def _first_argument_expression(source: bytes, offset: int) -> str:
    index = offset
    nesting: list[int] = []
    pairs = {ord("("): ord(")"), ord("["): ord("]"), ord("{"): ord("}")}
    quote: int | None = None
    escaped = False
    while index < len(source):
        byte = source[index]
        if quote is not None:
            if escaped:
                escaped = False
            elif byte == ord("\\"):
                escaped = True
            elif byte == quote:
                quote = None
            index += 1
            continue
        if byte in (ord("'"), ord('"'), ord("`")):
            quote = byte
        elif byte in pairs:
            nesting.append(pairs[byte])
        elif nesting and byte == nesting[-1]:
            nesting.pop()
        elif not nesting and byte in (ord(","), ord(")")):
            break
        index += 1
    return source[offset:index].decode("utf-8", errors="replace").strip()


def _value_before(
    bindings: dict[str, list[tuple[int, str]]], name: str, offset: int
) -> str | None:
    values = [
        value for position, value in bindings.get(name, []) if position < offset
    ]
    return values[-1] if values else None


def _module_exports(source: bytes) -> dict[str, str]:
    bindings = _static_bindings(source)
    exports: dict[str, str] = {}
    for match in EXPORT_GETTER_PATTERN.finditer(source):
        exported_name = match.group(2).decode("utf-8")
        local_name = match.group(3).decode("ascii")
        value = _value_before(bindings, local_name, match.start())
        if value is not None:
            exports[exported_name] = value
    return exports


def _add_required_exports(
    *,
    source: bytes,
    path: Path,
    root: Path,
    exports_by_file: dict[str, dict[str, str]],
    bindings: dict[str, list[tuple[int, str]]],
) -> None:
    for match in REQUIRE_PATTERN.finditer(source):
        alias = match.group(1).decode("ascii")
        requested = match.group(3).decode("utf-8")
        target = (path.parent / requested).resolve()
        try:
            relative = target.relative_to(root).as_posix()
        except ValueError:
            continue
        exported = exports_by_file.get(relative)
        if exported is None and not relative.endswith(".js"):
            exported = exports_by_file.get(f"{relative}.js")
        for name, value in (exported or {}).items():
            bindings[f"{alias}.{name}"].append((match.start(), value))


def extract_ipc_inventory(
    asar_root: Path, version: str
) -> dict[str, object]:
    root = asar_root.resolve()
    build_root = root / ".vite/build"
    if not build_root.is_dir():
        raise ValueError("Electron build directory is missing")
    candidates = sorted(build_root.glob("*.js"))
    renderer_assets = root / "webview/assets"
    if renderer_assets.is_dir():
        candidates.extend(sorted(renderer_assets.glob("*.js")))

    exports_by_file = {
        path.relative_to(root).as_posix(): _module_exports(path.read_bytes())
        for path in candidates
    }
    evidence: list[dict[str, object]] = []
    unresolved_calls: list[dict[str, object]] = []
    seen: set[tuple[str, str, str, str, int]] = set()
    unresolved_seen: set[tuple[str, str, str, int]] = set()
    for path in candidates:
        relative = path.relative_to(root).as_posix()
        source = path.read_bytes()
        digest = sha256_file(path)
        bindings = _static_bindings(source)
        _add_required_exports(
            source=source,
            path=path,
            root=root,
            exports_by_file=exports_by_file,
            bindings=bindings,
        )
        for pattern, side, name in CALL_PATTERNS:
            for match in pattern.finditer(source):
                resolved = _resolve_call_argument(source, match.end(), bindings)
                if resolved is None:
                    expression = _first_argument_expression(
                        source, match.end()
                    )
                    key = (side, name, relative, match.end())
                    if key not in unresolved_seen:
                        unresolved_seen.add(key)
                        unresolved_calls.append(
                            {
                                "side": side,
                                "operation": name,
                                "expression": expression,
                                "file": relative,
                                "fileSha256": digest,
                                "byteOffset": match.end(),
                            }
                        )
                    continue
                channel, evidence_kind = resolved
                if not CHANNEL_TEMPLATE_PATTERN.fullmatch(channel):
                    continue
                key = (channel, side, name, relative, match.end())
                if key in seen:
                    continue
                seen.add(key)
                evidence.append(
                    {
                        "channel": channel,
                        "side": side,
                        "operation": name,
                        "file": relative,
                        "fileSha256": digest,
                        "byteOffset": match.end(),
                        "evidenceKind": evidence_kind,
                    }
                )
    evidence.sort(
        key=lambda item: (
            item["channel"],
            item["file"],
            item["byteOffset"],
            item["operation"],
        )
    )
    unresolved_calls.sort(
        key=lambda item: (
            item["file"],
            item["byteOffset"],
            item["operation"],
        )
    )

    grouped: dict[str, dict[str, set[str]]] = defaultdict(
        lambda: {"main": set(), "preload": set(), "renderer": set()}
    )
    for item in evidence:
        grouped[str(item["channel"])][str(item["side"])].add(
            str(item["operation"])
        )
    channels: list[dict[str, object]] = []
    for channel in sorted(grouped):
        operations = grouped[channel]
        main_operations = sorted(operations["main"])
        preload_operations = sorted(operations["preload"])
        renderer_operations = sorted(operations["renderer"])
        has_main = bool(set(main_operations) & {"handle", "on"})
        has_client = bool(
            set(preload_operations)
            & {"invoke", "send", "sendSync", "postMessage"}
        )
        if has_main and has_client:
            pairing = "paired"
        elif has_main:
            pairing = "main-only"
        else:
            pairing = "client-only"
        channels.append(
            {
                "channel": channel,
                "mainOperations": main_operations,
                "preloadOperations": preload_operations,
                "rendererOperations": renderer_operations,
                "pairing": pairing,
            }
        )
    pairing_counts = defaultdict(int)
    for item in channels:
        pairing_counts[str(item["pairing"])] += 1
    return {
        "schemaVersion": 1,
        "version": version,
        "evidenceCount": len(evidence),
        "unresolvedCallCount": len(unresolved_calls),
        "channelCount": len(channels),
        "pairingCounts": {
            key: pairing_counts[key]
            for key in ("paired", "main-only", "client-only")
        },
        "channels": channels,
        "evidence": evidence,
        "unresolvedCalls": unresolved_calls,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--asar-root", type=Path, required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    write_json_atomic(
        args.output, extract_ipc_inventory(args.asar_root, args.version)
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
