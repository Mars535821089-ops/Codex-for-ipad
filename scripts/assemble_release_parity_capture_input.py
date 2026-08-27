#!/usr/bin/env python3
"""Bind official desktop and physical-iPad captures into one release input."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import sys
import tempfile
from typing import Any

if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from scripts.build_desktop_ui_parity import SURFACE_DEFINITIONS
from scripts.parity_capture_plan import capture_specs, capture_specs_by_surface


EXPECTED_SURFACE_IDS = tuple(f"S{index:02d}" for index in range(1, 11))
SURFACE_DEFINITION_BY_ID = {
    definition["id"]: definition for definition in SURFACE_DEFINITIONS
}
EXPECTED_CAPTURE_SPECS = capture_specs()
EXPECTED_CAPTURE_SPECS_BY_SURFACE = capture_specs_by_surface()
SHA256_PATTERN = re.compile(r"^[0-9a-f]{64}$")


def _load_object(path: Path, label: str) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise ValueError(f"{label} is malformed") from error
    if not isinstance(value, dict):
        raise ValueError(f"{label} is malformed")
    return value


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _safe_manifest_file(
    project_root: Path,
    manifest_path: Path,
    raw_path: object,
    *,
    label: str,
) -> Path:
    if not isinstance(raw_path, str) or not raw_path:
        raise ValueError(f"{label} path is missing")
    relative = Path(raw_path)
    if (
        relative.is_absolute()
        or "." in relative.parts
        or ".." in relative.parts
        or "\\" in raw_path
    ):
        raise ValueError(f"{label} path escapes its manifest")
    candidate = (manifest_path.parent / relative).resolve()
    try:
        candidate.relative_to(project_root)
    except ValueError as error:
        raise ValueError(f"{label} path escapes the project root") from error
    if not candidate.is_file():
        raise ValueError(f"{label} capture is missing")
    return candidate


def _validated_capture(
    project_root: Path,
    manifest_path: Path,
    row: object,
    *,
    label: str,
) -> Path:
    if not isinstance(row, dict):
        raise ValueError(f"{label} row is malformed")
    path = _safe_manifest_file(
        project_root,
        manifest_path,
        row.get("path"),
        label=label,
    )
    expected_hash = row.get("sha256")
    if not isinstance(expected_hash, str) or not SHA256_PATTERN.fullmatch(
        expected_hash
    ):
        raise ValueError(f"{label} hash is malformed")
    if _sha256(path) != expected_hash:
        raise ValueError(f"{label} hash does not match")
    return path


def _validate_identity(
    value: dict[str, Any],
    *,
    label: str,
    schema_version: int,
    desktop_version: str,
    desktop_build: str,
) -> dict[str, Any]:
    if value.get("schemaVersion") != schema_version:
        raise ValueError(f"{label} schema version is malformed")
    if value.get("desktopVersion") != desktop_version:
        raise ValueError(f"{label} version does not match")
    if value.get("desktopBuild") != desktop_build:
        raise ValueError(f"{label} build does not match")
    surfaces = value.get("surfaces")
    if not isinstance(surfaces, dict) or tuple(surfaces) != EXPECTED_SURFACE_IDS:
        raise ValueError(f"{label} surfaces must be ordered S01 through S10")
    return surfaces


def _validated_interaction_inventory(
    row: object,
    *,
    label: str,
) -> dict[str, Any]:
    if not isinstance(row, dict):
        raise ValueError(f"{label} interaction inventory is malformed")
    raw = row.get("interactionInventory")
    if not isinstance(raw, dict):
        raise ValueError(f"{label} interaction inventory is malformed")
    control_count = raw.get("controlCount")
    keyboard_count = raw.get("keyboardAccessibleCount")
    by_tag = raw.get("byTag")
    fingerprints = raw.get("labelFingerprints")
    valid = (
        isinstance(control_count, int)
        and not isinstance(control_count, bool)
        and control_count > 0
        and isinstance(keyboard_count, int)
        and not isinstance(keyboard_count, bool)
        and 0 < keyboard_count <= control_count
        and isinstance(by_tag, dict)
        and bool(by_tag)
        and all(
            isinstance(tag, str)
            and bool(tag)
            and isinstance(count, int)
            and not isinstance(count, bool)
            and count > 0
            for tag, count in by_tag.items()
        )
        and sum(by_tag.values()) == control_count
        and isinstance(fingerprints, list)
        and bool(fingerprints)
        and len(fingerprints) == len(set(fingerprints))
        and all(
            isinstance(value, str)
            and SHA256_PATTERN.fullmatch(value) is not None
            for value in fingerprints
        )
    )
    if not valid:
        raise ValueError(f"{label} interaction inventory is malformed")
    return {
        "controlCount": control_count,
        "keyboardAccessibleCount": keyboard_count,
        "byTag": dict(sorted(by_tag.items())),
        "labelFingerprints": sorted(fingerprints),
    }


def _capture_rows(
    raw: object,
    *,
    surface_id: str,
    label: str,
) -> list[dict[str, Any]]:
    if not isinstance(raw, dict):
        raise ValueError(f"{surface_id} {label} row is malformed")
    captures = raw.get("captures")
    if (
        not isinstance(captures, list)
        or not captures
        or any(not isinstance(row, dict) for row in captures)
    ):
        raise ValueError(f"{surface_id} {label} captures are malformed")
    typed = [row for row in captures if isinstance(row, dict)]
    definition = SURFACE_DEFINITION_BY_ID[surface_id]
    routes = [row.get("route") for row in typed]
    states = [row.get("stateKey") for row in typed]
    capture_keys = [row.get("captureKey") for row in typed]
    if any(not isinstance(route, str) or not route for route in routes):
        raise ValueError(f"{surface_id} {label} route is missing")
    if any(not isinstance(state, str) or not state for state in states):
        raise ValueError(f"{surface_id} {label} state is missing")
    if (
        any(not isinstance(key, str) or not key for key in capture_keys)
        or len(set(capture_keys)) != len(capture_keys)
    ):
        raise ValueError(f"{surface_id} {label} capture keys are malformed")
    if len(set(zip(routes, states))) != len(typed):
        raise ValueError(f"{surface_id} {label} route/state pairs are duplicated")
    if set(states) != set(definition["requiredStates"]):
        raise ValueError(f"{surface_id} required states are incomplete")
    if set(routes) != set(definition["routes"]):
        raise ValueError(f"{surface_id} required routes are incomplete")
    expected = [
        (spec["captureKey"], spec["route"], spec["state"])
        for spec in EXPECTED_CAPTURE_SPECS_BY_SURFACE[surface_id]
    ]
    actual = list(zip(capture_keys, routes, states))
    if actual != expected:
        raise ValueError(f"{surface_id} capture plan does not match")
    return typed


def _compare_interaction_inventories(
    official: dict[str, Any],
    ipad: dict[str, Any],
) -> dict[str, Any]:
    official_tags = official["byTag"]
    ipad_tags = ipad["byTag"]
    tag_delta = {
        tag: ipad_tags.get(tag, 0) - official_tags.get(tag, 0)
        for tag in sorted(set(official_tags) | set(ipad_tags))
        if ipad_tags.get(tag, 0) != official_tags.get(tag, 0)
    }
    official_fingerprints = set(official["labelFingerprints"])
    ipad_fingerprints = set(ipad["labelFingerprints"])
    missing = sorted(official_fingerprints - ipad_fingerprints)
    unexpected = sorted(ipad_fingerprints - official_fingerprints)
    control_delta = ipad["controlCount"] - official["controlCount"]
    keyboard_delta = (
        ipad["keyboardAccessibleCount"]
        - official["keyboardAccessibleCount"]
    )
    matched = (
        control_delta == 0
        and keyboard_delta == 0
        and not tag_delta
        and not missing
        and not unexpected
    )
    return {
        "status": "matched" if matched else "different",
        "controlCountDelta": control_delta,
        "keyboardAccessibleCountDelta": keyboard_delta,
        "byTagDelta": tag_delta,
        "sharedLabelFingerprintCount": len(
            official_fingerprints & ipad_fingerprints
        ),
        "missingOfficialLabelFingerprints": missing,
        "unexpectedIPadLabelFingerprints": unexpected,
        "official": official,
        "ipad": ipad,
    }


def _write_json_atomic(path: Path, value: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(
        prefix=f".{path.name}.",
        suffix=".tmp",
        dir=path.parent,
    )
    temporary_path = Path(temporary)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            json.dump(value, handle, ensure_ascii=False, indent=2)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary_path, path)
    finally:
        if temporary_path.exists():
            temporary_path.unlink()


def assemble_capture_input(
    project_root: Path,
    *,
    official_manifest_path: Path,
    ipad_manifest_path: Path,
    output_path: Path,
    desktop_version: str,
    desktop_build: str,
) -> Path:
    project_root = project_root.resolve()
    official_manifest_path = official_manifest_path.resolve()
    ipad_manifest_path = ipad_manifest_path.resolve()
    output_path = output_path.resolve()
    for path, label in (
        (official_manifest_path, "official desktop manifest"),
        (ipad_manifest_path, "iPad manifest"),
    ):
        try:
            path.relative_to(project_root)
        except ValueError as error:
            raise ValueError(f"{label} escapes the project root") from error
    try:
        output_path.relative_to(project_root)
    except ValueError as error:
        raise ValueError("capture input output escapes the project root") from error

    official_value = _load_object(
        official_manifest_path,
        "official desktop manifest",
    )
    ipad_value = _load_object(ipad_manifest_path, "iPad manifest")
    official_surfaces = _validate_identity(
        official_value,
        label="official desktop",
        schema_version=2,
        desktop_version=desktop_version,
        desktop_build=desktop_build,
    )
    ipad_surfaces = _validate_identity(
        ipad_value,
        label="iPad",
        schema_version=4,
        desktop_version=desktop_version,
        desktop_build=desktop_build,
    )
    interaction = ipad_value.get("interactionAcceptance")
    if not isinstance(interaction, dict):
        raise ValueError("iPad interaction acceptance is missing")
    interaction_surface_ids = interaction.get("surfaceIds")
    expected_action_count = len(EXPECTED_CAPTURE_SPECS)
    if (
        interaction.get("actionCount") != expected_action_count
        or not isinstance(interaction_surface_ids, list)
        or tuple(interaction_surface_ids) != EXPECTED_SURFACE_IDS
    ):
        raise ValueError(
            "iPad interaction acceptance must cover S01 through S10"
        )

    combined: dict[str, dict[str, Any]] = {}
    for surface_id in EXPECTED_SURFACE_IDS:
        official_rows = _capture_rows(
            official_surfaces[surface_id],
            surface_id=surface_id,
            label="official desktop",
        )
        ipad_rows = _capture_rows(
            ipad_surfaces[surface_id],
            surface_id=surface_id,
            label="iPad",
        )
        ipad_by_pair = {
            (row["route"], row["stateKey"]): row for row in ipad_rows
        }
        official_pairs = {
            (row["route"], row["stateKey"]) for row in official_rows
        }
        if official_pairs != set(ipad_by_pair):
            raise ValueError(f"{surface_id} capture route/state pairs do not match")

        captures: list[dict[str, Any]] = []
        for official_row in official_rows:
            route = official_row["route"]
            state_key = official_row["stateKey"]
            capture_key = official_row["captureKey"]
            ipad_row = ipad_by_pair[(route, state_key)]
            if ipad_row.get("captureKey") != capture_key:
                raise ValueError(f"{surface_id} capture keys do not match")
            expected_attachment = (
                f"CODEXPAD_PARITY_{surface_id}__{capture_key}"
            )
            if ipad_row.get("attachmentName") != expected_attachment:
                raise ValueError(f"{surface_id} capture state does not match")
            official_path = _validated_capture(
                project_root,
                official_manifest_path,
                official_row,
                label=f"{surface_id} official desktop",
            )
            ipad_path = _validated_capture(
                project_root,
                ipad_manifest_path,
                ipad_row,
                label=f"{surface_id} iPad",
            )
            if (
                official_path == ipad_path
                or _sha256(official_path) == _sha256(ipad_path)
            ):
                raise ValueError(
                    f"{surface_id} desktop and iPad captures are identical"
                )
            official_inventory = _validated_interaction_inventory(
                official_row,
                label=f"{surface_id} official desktop",
            )
            ipad_inventory = _validated_interaction_inventory(
                ipad_row,
                label=f"{surface_id} iPad",
            )
            captures.append({
                "route": route,
                "state": state_key,
                "officialDesktop": official_path.relative_to(
                    project_root
                ).as_posix(),
                "ipad": ipad_path.relative_to(project_root).as_posix(),
                "interactionComparison": _compare_interaction_inventories(
                    official_inventory,
                    ipad_inventory,
                ),
            })
        combined[surface_id] = {"captures": captures}

    _write_json_atomic(
        output_path,
        {
            "schemaVersion": 3,
            "desktopVersion": desktop_version,
            "desktopBuild": desktop_build,
            "surfaces": combined,
        },
    )
    return output_path


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--project-root", type=Path, required=True)
    parser.add_argument("--official-manifest", type=Path, required=True)
    parser.add_argument("--ipad-manifest", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--desktop-version", required=True)
    parser.add_argument("--desktop-build", required=True)
    args = parser.parse_args()
    output = assemble_capture_input(
        args.project_root,
        official_manifest_path=args.official_manifest,
        ipad_manifest_path=args.ipad_manifest,
        output_path=args.output,
        desktop_version=args.desktop_version,
        desktop_build=args.desktop_build,
    )
    print(output)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
