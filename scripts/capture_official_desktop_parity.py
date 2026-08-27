#!/usr/bin/env python3
"""Validate official desktop captures and publish a release-bound manifest."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import sys
import tempfile
from typing import Any
import uuid

from PIL import Image

if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from scripts.build_desktop_ui_parity import SURFACE_DEFINITIONS
from scripts.parity_capture_plan import capture_specs_by_surface


EXPECTED_SURFACE_IDS = tuple(f"S{index:02d}" for index in range(1, 11))
SURFACE_DEFINITION_BY_ID = {
    definition["id"]: definition for definition in SURFACE_DEFINITIONS
}
EXPECTED_CAPTURE_SPECS_BY_SURFACE = capture_specs_by_surface()
SHA256_PATTERN = re.compile(r"^[0-9a-f]{64}$")


def _validate_interaction_inventory(
    raw: object, *, surface_id: str
) -> dict[str, object]:
    if not isinstance(raw, dict):
        raise ValueError(f"{surface_id} interaction inventory is missing")
    control_count = raw.get("controlCount")
    keyboard_count = raw.get("keyboardAccessibleCount")
    by_tag = raw.get("byTag")
    fingerprints = raw.get("labelFingerprints")
    if not isinstance(control_count, int) or control_count <= 0:
        raise ValueError(f"{surface_id} interaction control count is malformed")
    if (
        not isinstance(keyboard_count, int)
        or keyboard_count < 0
        or keyboard_count > control_count
    ):
        raise ValueError(f"{surface_id} keyboard control count is malformed")
    if (
        not isinstance(by_tag, dict)
        or not by_tag
        or any(
            not isinstance(tag, str)
            or not tag
            or not isinstance(count, int)
            or count <= 0
            for tag, count in by_tag.items()
        )
        or sum(by_tag.values()) != control_count
    ):
        raise ValueError(f"{surface_id} interaction tag counts are malformed")
    if (
        not isinstance(fingerprints, list)
        or not fingerprints
        or len(set(fingerprints)) != len(fingerprints)
        or any(
            not isinstance(value, str) or SHA256_PATTERN.fullmatch(value) is None
            for value in fingerprints
        )
    ):
        raise ValueError(f"{surface_id} interaction fingerprints are malformed")
    return {
        "controlCount": control_count,
        "keyboardAccessibleCount": keyboard_count,
        "byTag": dict(sorted(by_tag.items())),
        "labelFingerprints": sorted(fingerprints),
    }


def _load_object(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise ValueError("official desktop driver result is malformed") from error
    if not isinstance(value, dict):
        raise ValueError("official desktop driver result is malformed")
    return value


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _safe_capture(capture_root: Path, raw_path: object) -> Path:
    if not isinstance(raw_path, str) or not raw_path:
        raise ValueError("official desktop capture path is missing")
    relative = Path(raw_path)
    if (
        relative.is_absolute()
        or "." in relative.parts
        or ".." in relative.parts
        or "\\" in raw_path
    ):
        raise ValueError("official desktop capture path escapes capture root")
    candidate = (capture_root / relative).resolve()
    try:
        candidate.relative_to(capture_root)
    except ValueError as error:
        raise ValueError(
            "official desktop capture path escapes capture root"
        ) from error
    if not candidate.is_file():
        raise ValueError("official desktop capture is missing")
    try:
        with Image.open(candidate) as image:
            image.verify()
        with Image.open(candidate) as image:
            if image.format != "PNG" or image.width < 640 or image.height < 480:
                raise ValueError("official desktop capture is undersized")
    except (OSError, SyntaxError) as error:
        raise ValueError("official desktop capture is not a valid PNG") from error
    return candidate


def _replace_directory_atomically(staging: Path, output_root: Path) -> None:
    backup = output_root.with_name(
        f".{output_root.name}.backup-{uuid.uuid4().hex}"
    )
    had_output = output_root.exists()
    try:
        if had_output:
            os.replace(output_root, backup)
        os.replace(staging, output_root)
    except BaseException:
        if output_root.exists():
            shutil.rmtree(output_root)
        if backup.exists():
            os.replace(backup, output_root)
        raise
    finally:
        if backup.exists():
            shutil.rmtree(backup)


def build_official_manifest(
    capture_root: Path,
    *,
    driver_result_path: Path,
    output_root: Path,
    desktop_version: str,
    desktop_build: str,
) -> Path:
    capture_root = capture_root.resolve()
    driver_result_path = driver_result_path.resolve()
    output_root = output_root.resolve()
    value = _load_object(driver_result_path)
    if value.get("schemaVersion") != 2:
        raise ValueError("official desktop driver schema is malformed")
    if value.get("bundleIdentifier") != "com.openai.codex":
        raise ValueError("official desktop bundle identifier does not match")
    if value.get("desktopVersion") != desktop_version:
        raise ValueError("official desktop version does not match")
    if value.get("desktopBuild") != desktop_build:
        raise ValueError("official desktop build does not match")
    if value.get("profileMode") != "isolated":
        raise ValueError("official desktop capture did not use an isolated profile")
    rows = value.get("surfaces")
    if not isinstance(rows, list) or not rows:
        raise ValueError("official desktop surfaces must be ordered S01 through S10")
    row_surface_ids = [
        row.get("id") if isinstance(row, dict) else None for row in rows
    ]
    if tuple(dict.fromkeys(row_surface_ids)) != EXPECTED_SURFACE_IDS:
        raise ValueError("official desktop surfaces must be ordered S01 through S10")

    validated = []
    hashes: set[str] = set()
    capture_keys: dict[str, set[str]] = {
        surface_id: set() for surface_id in EXPECTED_SURFACE_IDS
    }
    route_state_pairs: dict[str, set[tuple[str, str]]] = {
        surface_id: set() for surface_id in EXPECTED_SURFACE_IDS
    }
    routes_by_surface: dict[str, set[str]] = {
        surface_id: set() for surface_id in EXPECTED_SURFACE_IDS
    }
    states_by_surface: dict[str, set[str]] = {
        surface_id: set() for surface_id in EXPECTED_SURFACE_IDS
    }
    for row in rows:
        if not isinstance(row, dict):
            raise ValueError("official desktop row is malformed")
        surface_id = row.get("id")
        if surface_id not in EXPECTED_SURFACE_IDS:
            raise ValueError("official desktop surface id is malformed")
        route = row.get("route")
        if not isinstance(route, str) or not route:
            raise ValueError(f"{surface_id} official desktop route is missing")
        state = row.get("stateKey")
        if not isinstance(state, str) or not state:
            raise ValueError(f"{surface_id} official desktop state is missing")
        capture_key = row.get("captureKey")
        if not isinstance(capture_key, str) or not capture_key:
            raise ValueError(f"{surface_id} capture key is malformed")
        if capture_key in capture_keys[surface_id]:
            raise ValueError(f"{surface_id} capture keys are duplicated")
        pair = (route, state)
        if pair in route_state_pairs[surface_id]:
            raise ValueError(f"{surface_id} route/state pairs are duplicated")
        capture_keys[surface_id].add(capture_key)
        route_state_pairs[surface_id].add(pair)
        routes_by_surface[surface_id].add(route)
        states_by_surface[surface_id].add(state)
        source = _safe_capture(capture_root, row.get("path"))
        digest = _sha256(source)
        if digest in hashes:
            raise ValueError(f"{surface_id} reuses image bytes")
        hashes.add(digest)
        interaction_inventory = _validate_interaction_inventory(
            row.get("interactionInventory"), surface_id=surface_id
        )
        validated.append(
            (
                surface_id,
                capture_key,
                state,
                route,
                source,
                digest,
                interaction_inventory,
            )
        )

    for surface_id in EXPECTED_SURFACE_IDS:
        definition = SURFACE_DEFINITION_BY_ID[surface_id]
        if states_by_surface[surface_id] != set(definition["requiredStates"]):
            raise ValueError(f"{surface_id} required states are incomplete")
        if routes_by_surface[surface_id] != set(definition["routes"]):
            raise ValueError(f"{surface_id} required routes are incomplete")
        actual = [
            (row["captureKey"], row["route"], row["stateKey"])
            for row in rows
            if row["id"] == surface_id
        ]
        expected = [
            (spec["captureKey"], spec["route"], spec["state"])
            for spec in EXPECTED_CAPTURE_SPECS_BY_SURFACE[surface_id]
        ]
        if actual != expected:
            raise ValueError(f"{surface_id} capture plan does not match")

    output_root.parent.mkdir(parents=True, exist_ok=True)
    staging = Path(
        tempfile.mkdtemp(prefix=f".{output_root.name}.", dir=output_root.parent)
    )
    try:
        manifest_surfaces: dict[str, dict[str, Any]] = {
            surface_id: {"captures": []}
            for surface_id in EXPECTED_SURFACE_IDS
        }
        for (
            surface_id,
            capture_key,
            state,
            route,
            source,
            digest,
            interaction_inventory,
        ) in validated:
            name = f"{surface_id}-{capture_key}-official.png"
            shutil.copy2(source, staging / name)
            manifest_surfaces[surface_id]["captures"].append({
                "captureKey": capture_key,
                "path": name,
                "sha256": digest,
                "route": route,
                "stateKey": state,
                "interactionInventory": interaction_inventory,
            })
        manifest = {
            "schemaVersion": 2,
            "bundleIdentifier": "com.openai.codex",
            "desktopVersion": desktop_version,
            "desktopBuild": desktop_build,
            "profileMode": "isolated",
            "surfaces": manifest_surfaces,
        }
        (staging / "manifest.json").write_text(
            json.dumps(manifest, ensure_ascii=False, indent=2) + "\n",
            encoding="utf-8",
        )
        _replace_directory_atomically(staging, output_root)
    finally:
        if staging.exists():
            shutil.rmtree(staging)
    return output_root / "manifest.json"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--capture-root", type=Path, required=True)
    parser.add_argument("--driver-result", type=Path, required=True)
    parser.add_argument("--output-root", type=Path, required=True)
    parser.add_argument("--desktop-version", required=True)
    parser.add_argument("--desktop-build", required=True)
    args = parser.parse_args()
    print(
        build_official_manifest(
            args.capture_root,
            driver_result_path=args.driver_result,
            output_root=args.output_root,
            desktop_version=args.desktop_version,
            desktop_build=args.desktop_build,
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
