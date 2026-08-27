#!/usr/bin/env python3
"""Build a conservative control-level desktop-to-iPad evidence map.

The desktop inventory may repeat the same localized interaction across several
surfaces. This audit deduplicates by ``id + defaultMessage + kind``, proves
whether the official web asset containing each control is embedded unchanged,
and separately records exact Swift/UI-test string evidence. Asset presence is
UI implementation evidence, but is not bridge behavior or physical-device
runtime proof.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import sys
from pathlib import Path
from typing import Any, Iterable


def load_json(path: Path) -> dict[str, Any]:
    value = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise ValueError(f"expected JSON object: {path}")
    return value


def _decode_swift_string(value: str) -> str:
    replacements = {
        r"\n": "\n",
        r"\r": "\r",
        r"\t": "\t",
        r'\"': '"',
        r"\\": "\\",
        r"\0": "\0",
    }
    for escaped, decoded in replacements.items():
        value = value.replace(escaped, decoded)
    return value


def _swift_strings(source: str) -> Iterable[tuple[str, int, str]]:
    """Yield normal Swift string literals while ignoring comments.

    The checked-in UI labels use ordinary or triple-quoted literals. Raw Swift
    strings remain deliberately unmatched rather than risking false evidence.
    """

    index = 0
    line = 1
    length = len(source)
    source_lines = source.splitlines()
    block_depth = 0
    while index < length:
        if block_depth:
            if source.startswith("/*", index):
                block_depth += 1
                index += 2
                continue
            if source.startswith("*/", index):
                block_depth -= 1
                index += 2
                continue
            if source[index] == "\n":
                line += 1
            index += 1
            continue
        if source.startswith("//", index):
            newline = source.find("\n", index + 2)
            if newline < 0:
                return
            line += 1
            index = newline + 1
            continue
        if source.startswith("/*", index):
            block_depth = 1
            index += 2
            continue
        if source[index] != '"':
            if source[index] == "\n":
                line += 1
            index += 1
            continue

        start_line = line
        triple = source.startswith('"""', index)
        index += 3 if triple else 1
        content: list[str] = []
        while index < length:
            if triple and source.startswith('"""', index):
                index += 3
                break
            if not triple and source[index] == '"':
                index += 1
                break
            character = source[index]
            if character == "\\" and index + 1 < length:
                content.append(character)
                content.append(source[index + 1])
                index += 2
                continue
            content.append(character)
            if character == "\n":
                line += 1
            index += 1
        context = source_lines[start_line - 1] if source_lines else ""
        yield _decode_swift_string("".join(content)), start_line, context.strip()


def _context_kind(context: str, *, ui_test: bool) -> str:
    if ui_test:
        return "ui-test-reference"
    if ".accessibilityLabel" in context:
        return "accessibility-label"
    for call, kind in (
        ("Button(", "button"),
        ("Menu(", "menu"),
        ("Toggle(", "toggle"),
        ("Picker(", "picker"),
        ("TextField(", "text-field"),
        ("SecureField(", "secure-field"),
        ("Link(", "link"),
        ("Label(", "label"),
        ("Text(", "text"),
        ("CommandMenu(", "command-menu"),
    ):
        if call in context:
            return kind
    return "swift-string-literal"


def _string_index(
    sources: dict[str, str], *, ui_test: bool
) -> dict[str, list[dict[str, Any]]]:
    result: dict[str, list[dict[str, Any]]] = {}
    for path in sorted(sources):
        source = sources[path]
        digest = hashlib.sha256(source.encode("utf-8")).hexdigest()
        for label, line, context in _swift_strings(source):
            if not label:
                continue
            result.setdefault(label, []).append(
                {
                    "path": path,
                    "line": line,
                    "contextKind": _context_kind(context, ui_test=ui_test),
                    "sourceSha256": digest,
                }
            )
    return result


def _interaction_rows(inventory: dict[str, Any]) -> tuple[int, list[dict[str, Any]]]:
    raw_count = 0
    deduplicated: dict[tuple[str, str, str], dict[str, Any]] = {}
    for surface in inventory.get("surfaces", []):
        if not isinstance(surface, dict):
            continue
        surface_id = str(surface.get("id", ""))
        interactions = surface.get("interactions", [])
        if not isinstance(interactions, list):
            continue
        for interaction in interactions:
            if not isinstance(interaction, dict):
                continue
            raw_count += 1
            identity = (
                str(interaction.get("id", "")),
                str(interaction.get("defaultMessage", "")),
                str(interaction.get("kind", "")),
            )
            row = deduplicated.setdefault(
                identity,
                {
                    "id": identity[0],
                    "defaultMessage": identity[1],
                    "kind": identity[2],
                    "surfaceIds": set(),
                    "desktopOccurrences": [],
                },
            )
            if surface_id:
                row["surfaceIds"].add(surface_id)
            for occurrence in interaction.get("occurrences", []):
                if (
                    isinstance(occurrence, dict)
                    and occurrence not in row["desktopOccurrences"]
                ):
                    row["desktopOccurrences"].append(occurrence)
    rows = []
    for identity in sorted(deduplicated):
        row = deduplicated[identity]
        rows.append({**row, "surfaceIds": sorted(row["surfaceIds"])})
    return raw_count, rows


def _asset_evidence(
    control: dict[str, Any], surface_sources: dict[str, bytes]
) -> tuple[str, list[dict[str, Any]]]:
    evidence: list[dict[str, Any]] = []
    matched = False
    integrity_error = False
    for occurrence in control.get("desktopOccurrences", []):
        original_path = str(occurrence.get("file", ""))
        relative_path = (
            original_path.removeprefix("webview/")
            if original_path.startswith("webview/")
            else original_path
        )
        payload = surface_sources.get(relative_path)
        recovered_source_sha256 = str(occurrence.get("fileSha256", ""))
        byte_offset = occurrence.get("byteOffset")
        if payload is None:
            status = "missing-file"
            surface_sha256 = None
            id_matched = False
            message_matched = False
        else:
            surface_sha256 = hashlib.sha256(payload).hexdigest()
            id_matched = control["id"].encode("utf-8") in payload
            message = control["defaultMessage"]
            message_candidates = {
                message.encode("utf-8"),
                json.dumps(message, ensure_ascii=False)[1:-1].encode("utf-8"),
                json.dumps(message, ensure_ascii=True)[1:-1].encode("ascii"),
            }
            message_matched = any(
                candidate and candidate in payload
                for candidate in message_candidates
            )
            if id_matched:
                status = "matched"
                matched = True
            else:
                status = "identity-missing"
                integrity_error = True
        evidence.append(
            {
                "path": relative_path,
                "recoveredSourceByteOffset": byte_offset,
                "recoveredSourceSha256": recovered_source_sha256,
                "surfaceSha256": surface_sha256,
                "idMatched": id_matched,
                "defaultMessageMatched": message_matched,
                "status": status,
            }
        )
    if matched:
        return "matched", evidence
    if integrity_error:
        return "integrity-error", evidence
    return "missing", evidence


def audit_controls(
    inventory: dict[str, Any],
    surface_sources: dict[str, bytes],
    production_sources: dict[str, str],
    ui_test_sources: dict[str, str],
) -> dict[str, Any]:
    raw_count, controls = _interaction_rows(inventory)
    production_index = _string_index(production_sources, ui_test=False)
    ui_test_index = _string_index(ui_test_sources, ui_test=True)

    production_matched = 0
    ui_test_matched = 0
    combined_matched = 0
    native_unreferenced = 0
    asset_matched = 0
    asset_missing = 0
    asset_integrity_errors = 0
    for control in controls:
        asset_status, asset_evidence = _asset_evidence(
            control, surface_sources
        )
        asset_matched += int(asset_status == "matched")
        asset_missing += int(asset_status != "matched")
        asset_integrity_errors += int(asset_status == "integrity-error")
        label = control["defaultMessage"]
        production_evidence = production_index.get(label, [])
        ui_test_evidence = ui_test_index.get(label, [])
        has_production = bool(production_evidence)
        has_ui_test = bool(ui_test_evidence)
        production_matched += int(has_production)
        ui_test_matched += int(has_ui_test)
        combined_matched += int(has_production or has_ui_test)
        native_unreferenced += int(not has_production and not has_ui_test)
        if has_production and has_ui_test:
            status = "production-and-test"
        elif has_production:
            status = "production-only"
        elif has_ui_test:
            status = "test-only"
        else:
            status = "unreferenced"
        control["assetStatus"] = asset_status
        control["assetEvidence"] = asset_evidence
        control["nativeEvidenceStatus"] = status
        control["productionEvidence"] = production_evidence
        control["uiTestEvidence"] = ui_test_evidence

    unique_count = len(controls)
    return {
        "schemaVersion": 1,
        "desktopVersion": inventory.get("desktopVersion"),
        "desktopBuild": inventory.get("desktopBuild"),
        "sourceIdentity": inventory.get("sourceIdentity"),
        "staticEvidenceOnly": True,
        "assetMatchRule": (
            "at least one recovered inventory occurrence maps to the same "
            "relative official web asset and that embedded asset contains the "
            "exact interaction id; recovered-source hashes and offsets are "
            "recorded but not compared because recovery reformats JavaScript"
        ),
        "nativeMatchRule": (
            "exact Swift string literal after id+defaultMessage+kind deduplication"
        ),
        "rawInteractionCount": raw_count,
        "uniqueInteractionCount": unique_count,
        "duplicateInteractionCount": raw_count - unique_count,
        "surfaceSourceFileCount": len(surface_sources),
        "assetMatchedCount": asset_matched,
        "assetMissingCount": asset_missing,
        "assetIntegrityErrorCount": asset_integrity_errors,
        "assetCoveragePercent": round(
            (asset_matched / unique_count * 100) if unique_count else 100.0,
            2,
        ),
        "productionSourceFileCount": len(production_sources),
        "uiTestSourceFileCount": len(ui_test_sources),
        "productionMatchedCount": production_matched,
        "uiTestMatchedCount": ui_test_matched,
        "combinedMatchedCount": combined_matched,
        "nativeOrTestUnreferencedCount": native_unreferenced,
        "productionCoveragePercent": round(
            (production_matched / unique_count * 100) if unique_count else 100.0,
            2,
        ),
        "combinedCoveragePercent": round(
            (combined_matched / unique_count * 100) if unique_count else 100.0,
            2,
        ),
        "controls": controls,
    }


def _read_swift_tree(root: Path) -> dict[str, str]:
    if root.is_file():
        return {root.name: root.read_text(encoding="utf-8")}
    return {
        path.relative_to(root).as_posix(): path.read_text(encoding="utf-8")
        for path in sorted(root.rglob("*.swift"))
        if path.is_file()
    }


def _read_binary_tree(root: Path) -> dict[str, bytes]:
    if root.is_file():
        return {root.name: root.read_bytes()}
    return {
        path.relative_to(root).as_posix(): path.read_bytes()
        for path in sorted(root.rglob("*"))
        if path.is_file()
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--inventory", type=Path, required=True)
    parser.add_argument("--surface-root", type=Path, required=True)
    parser.add_argument("--production-root", type=Path, required=True)
    parser.add_argument("--ui-test-root", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--require-assets-complete", action="store_true")
    args = parser.parse_args()

    report = audit_controls(
        load_json(args.inventory),
        _read_binary_tree(args.surface_root),
        _read_swift_tree(args.production_root),
        _read_swift_tree(args.ui_test_root),
    )
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(
        json.dumps(report, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    print(args.output)
    print(
        f"assets={report['assetMatchedCount']}/"
        f"{report['uniqueInteractionCount']} "
        f"asset-missing={report['assetMissingCount']} "
        f"production={report['productionMatchedCount']}/"
        f"{report['uniqueInteractionCount']} "
        f"combined={report['combinedMatchedCount']}/"
        f"{report['uniqueInteractionCount']} "
        f"native-unreferenced={report['nativeOrTestUnreferencedCount']} "
        f"raw={report['rawInteractionCount']}"
    )
    if args.require_assets_complete and (
        report["assetMissingCount"] != 0
        or report["assetIntegrityErrorCount"] != 0
    ):
        print("embedded control assets are incomplete", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
