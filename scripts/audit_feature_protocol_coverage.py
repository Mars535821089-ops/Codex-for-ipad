#!/usr/bin/env python3
"""Classify feature inventory rows by official RPC method references."""

from __future__ import annotations

import argparse
from collections import Counter
import hashlib
import json
import os
from pathlib import Path
import re
import sys

if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from scripts.protocol_manifest import load_json_object, write_json_atomic


REQUEST_DEFINITION = re.compile(
    r'(?ms)^\s*[A-Za-z][A-Za-z0-9_]*\s*=>\s*"([^"]+)"\s*'
    r"\{(.*?)^\s*\},"
)
TYPE_FIELD = {
    role: re.compile(
        rf"\b{role}:\s*(?:(?:#\[[^\]]+\]\s*)*)"
        r"(?:v[0-9]+::)?([A-Z][A-Za-z0-9]+)"
    )
    for role in ("params", "response")
}
WIRED_NOTIFICATION = re.compile(
    r'(?ms)^\s*[A-Za-z][A-Za-z0-9_]*\s*=>\s*"([^"]+)"\s*'
    r"\(\s*(?:v[0-9]+::)?([A-Z][A-Za-z0-9]+)\s*\),"
)
RENAMED_NOTIFICATION = re.compile(
    r'(?ms)#\[serde\(\s*rename\s*=\s*"([^"]+)"\s*\)\]'
    r"(?:\s*#\[[^\]]+\])*\s*"
    r"[A-Za-z][A-Za-z0-9_]*\s*"
    r"\(\s*(?:v[0-9]+::)?([A-Z][A-Za-z0-9]+)\s*\),"
)
STRING_LITERAL = re.compile(r"""(["'])([^"'\\\n]+)\1""")
SCANNED_SUFFIXES = {
    ".c",
    ".cc",
    ".cpp",
    ".h",
    ".hpp",
    ".js",
    ".m",
    ".mm",
    ".mjs",
    ".py",
    ".rs",
    ".sh",
    ".swift",
    ".ts",
    ".tsx",
}
SKIPPED_DIRECTORIES = {
    ".build",
    ".git",
    "__pycache__",
    "build",
    "DerivedData",
    "node_modules",
    "Resources",
    "target",
    "vendor",
}


def _sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def protocol_type_methods(
    source: str,
) -> dict[str, tuple[tuple[str, str], ...]]:
    """Map exported protocol type names to wire method and role pairs."""
    mapping: dict[str, set[tuple[str, str]]] = {}
    for match in REQUEST_DEFINITION.finditer(source):
        method, body = match.groups()
        for role, pattern in TYPE_FIELD.items():
            type_match = pattern.search(body)
            if type_match is not None:
                mapping.setdefault(type_match.group(1), set()).add(
                    (method, role)
                )
    for pattern in (WIRED_NOTIFICATION, RENAMED_NOTIFICATION):
        for match in pattern.finditer(source):
            method, type_name = match.groups()
            mapping.setdefault(type_name, set()).add(
                (method, "notification")
            )
    return {
        type_name: tuple(sorted(entries))
        for type_name, entries in sorted(mapping.items())
    }


def _source_files(roots: tuple[Path, ...]) -> tuple[Path, ...]:
    files: set[Path] = set()
    for root in roots:
        if not root.exists():
            raise ValueError(f"scan root is missing: {root}")
        candidates = (root,) if root.is_file() else root.rglob("*")
        for candidate in candidates:
            if not candidate.is_file():
                continue
            if any(part in SKIPPED_DIRECTORIES for part in candidate.parts):
                continue
            if candidate.suffix not in SCANNED_SUFFIXES:
                continue
            files.add(candidate.resolve())
    return tuple(sorted(files, key=lambda path: str(path)))


def _reference_base(roots: tuple[Path, ...]) -> Path:
    resolved = [path.resolve() for path in roots]
    if len(resolved) == 1:
        return resolved[0] if resolved[0].is_dir() else resolved[0].parent
    return Path(os.path.commonpath([str(path) for path in resolved]))


def _method_references(
    methods: set[str],
    roots: tuple[Path, ...],
) -> tuple[dict[str, list[dict[str, object]]], int]:
    references = {method: [] for method in sorted(methods)}
    files = _source_files(roots)
    base = _reference_base(roots)
    for path in files:
        try:
            source = path.read_text(encoding="utf-8")
        except UnicodeDecodeError:
            continue
        display_path = path.relative_to(base).as_posix()
        for line_number, line in enumerate(source.splitlines(), start=1):
            values = {match.group(2) for match in STRING_LITERAL.finditer(line)}
            for method in sorted(values & methods):
                references[method].append(
                    {"file": display_path, "line": line_number}
                )
    return references, len(files)


def _classification(
    methods: list[dict[str, object]],
    inventory_tests: list[object],
    inventory_status: object,
) -> str:
    if inventory_status == "matched":
        return "inventory-matched"
    if not methods:
        return "protocol-unmapped"
    production_complete = all(
        method["productionReferences"] for method in methods
    )
    production_any = any(
        method["productionReferences"] for method in methods
    )
    test_complete = bool(inventory_tests) or all(
        method["testReferences"] for method in methods
    )
    if production_complete and test_complete:
        return "implemented-and-test-referenced"
    if production_complete:
        return "implemented-without-test-reference"
    if production_any:
        return "partially-implemented"
    return "not-implemented"


def audit_feature_protocol_coverage(
    *,
    protocol_path: Path,
    inventory_path: Path,
    production_roots: tuple[Path, ...],
    test_roots: tuple[Path, ...],
) -> dict[str, object]:
    protocol_source = protocol_path.read_text(encoding="utf-8")
    inventory = load_json_object(inventory_path)
    features = inventory.get("features")
    if not isinstance(features, list):
        raise ValueError("feature inventory features must be an array")
    if inventory.get("featureCount") != len(features):
        raise ValueError("feature inventory featureCount mismatch")

    type_mapping = protocol_type_methods(protocol_source)
    official_methods = {
        method
        for entries in type_mapping.values()
        for method, _ in entries
    }
    production_references, production_file_count = _method_references(
        official_methods,
        production_roots,
    )
    test_references, test_file_count = _method_references(
        official_methods,
        test_roots,
    )

    output_features: list[dict[str, object]] = []
    for feature in features:
        if not isinstance(feature, dict):
            raise ValueError("feature inventory row must be an object")
        name = feature.get("name")
        if not isinstance(name, str) or not name:
            raise ValueError("feature inventory row name must be a string")
        entries = type_mapping.get(name, ())
        methods: dict[str, set[str]] = {}
        for method, role in entries:
            methods.setdefault(method, set()).add(role)
        method_coverage = [
            {
                "method": method,
                "roles": sorted(roles),
                "productionReferences": production_references.get(method, []),
                "testReferences": test_references.get(method, []),
            }
            for method, roles in sorted(methods.items())
        ]
        inventory_tests = feature.get("automatedTests")
        if not isinstance(inventory_tests, list):
            inventory_tests = []
        output_features.append(
            {
                "id": feature.get("id"),
                "name": name,
                "category": feature.get("category"),
                "inventoryStatus": feature.get("status"),
                "inventoryAutomatedTests": inventory_tests,
                "protocolMethods": sorted(methods),
                "methodCoverage": method_coverage,
                "classification": _classification(
                    method_coverage,
                    inventory_tests,
                    feature.get("status"),
                ),
            }
        )

    counts = Counter(
        str(feature["classification"]) for feature in output_features
    )
    return {
        "schemaVersion": 1,
        "version": inventory.get("version"),
        "protocolSource": str(protocol_path),
        "protocolSha256": _sha256(protocol_path),
        "inventorySource": str(inventory_path),
        "inventorySha256": _sha256(inventory_path),
        "featureCount": len(output_features),
        "officialMappedTypeCount": len(type_mapping),
        "officialMethodCount": len(official_methods),
        "productionFileCount": production_file_count,
        "testFileCount": test_file_count,
        "classificationCounts": dict(sorted(counts.items())),
        "features": output_features,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--protocol", type=Path, required=True)
    parser.add_argument("--inventory", type=Path, required=True)
    parser.add_argument(
        "--production-root",
        type=Path,
        action="append",
        required=True,
    )
    parser.add_argument(
        "--test-root",
        type=Path,
        action="append",
        required=True,
    )
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    try:
        result = audit_feature_protocol_coverage(
            protocol_path=args.protocol,
            inventory_path=args.inventory,
            production_roots=tuple(args.production_root),
            test_roots=tuple(args.test_root),
        )
    except (OSError, ValueError, json.JSONDecodeError) as error:
        parser.error(str(error))
    write_json_atomic(args.output, result)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
