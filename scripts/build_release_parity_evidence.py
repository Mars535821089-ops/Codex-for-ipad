#!/usr/bin/env python3
"""Build release-bound implementation and visual evidence for S01-S10."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import re
import shutil
import sys
from typing import Any

from PIL import Image, ImageChops

if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from scripts.build_desktop_ui_parity import (
    EXPECTED_SURFACE_IDS,
    SURFACE_DEFINITIONS,
    build_desktop_ui_parity,
)
from scripts.protocol_manifest import (
    load_json_object,
    sha256_file,
    write_json_atomic,
)


SHA256_PATTERN = re.compile(r"^[0-9a-f]{64}$")


def _require_text(value: object, label: str) -> str:
    if not isinstance(value, str) or not value.strip():
        raise ValueError(f"{label} is missing")
    return value.strip()


def _safe_project_file(
    project_root: Path,
    raw: object,
    *,
    label: str,
) -> Path:
    relative = _require_text(raw, label)
    relative_path = Path(relative)
    if (
        relative_path.is_absolute()
        or ".." in relative_path.parts
        or "." in relative_path.parts
        or "\\" in relative
    ):
        raise ValueError(f"{label} escapes the project root")
    candidate = (project_root / relative_path).resolve()
    try:
        candidate.relative_to(project_root)
    except ValueError as error:
        raise ValueError(f"{label} escapes the project root") from error
    if not candidate.is_file():
        raise ValueError(f"{label} is missing")
    return candidate


def _evidence_entry(project_root: Path, path: Path) -> dict[str, str]:
    return {
        "path": path.resolve().relative_to(project_root).as_posix(),
        "sha256": sha256_file(path),
    }


def _copy_evidence_file(
    project_root: Path,
    source: Path,
    destination: Path,
) -> dict[str, str]:
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source, destination)
    return _evidence_entry(project_root, destination)


def _validated_png(path: Path, label: str) -> Image.Image:
    try:
        with Image.open(path) as opened:
            opened.verify()
        with Image.open(path) as opened:
            image = opened.convert("RGBA")
    except Exception as error:
        raise ValueError(f"{label} is not a valid image") from error
    if image.width < 320 or image.height < 320:
        raise ValueError(f"{label} is too small for runtime evidence")
    return image


def _render_pixel_diff(
    official_path: Path,
    ipad_path: Path,
    output_path: Path,
) -> None:
    official = _validated_png(official_path, "official desktop capture")
    ipad = _validated_png(ipad_path, "iPad capture")
    width = max(official.width, ipad.width)
    height = max(official.height, ipad.height)

    def canvas(image: Image.Image) -> Image.Image:
        result = Image.new("RGBA", (width, height), (0, 0, 0, 255))
        result.paste(image, (0, 0))
        return result

    diff = ImageChops.difference(canvas(official), canvas(ipad))
    output_path.parent.mkdir(parents=True, exist_ok=True)
    diff.save(output_path, format="PNG")


def _validate_capture_input(
    capture_input: dict[str, Any],
    *,
    desktop_version: str,
    desktop_build: str,
) -> dict[str, dict[str, Any]]:
    if capture_input.get("schemaVersion") != 3:
        raise ValueError("capture input schema version is malformed")
    if capture_input.get("desktopVersion") != desktop_version:
        raise ValueError("capture input desktop version does not match")
    if capture_input.get("desktopBuild") != desktop_build:
        raise ValueError("capture input desktop build does not match")
    surfaces = capture_input.get("surfaces")
    if not isinstance(surfaces, dict):
        raise ValueError("capture input surfaces are missing")
    if tuple(surfaces) != EXPECTED_SURFACE_IDS:
        raise ValueError("capture input surfaces must be ordered S01 through S10")
    return surfaces


def _capture_rows_for_surface(
    raw: object,
    *,
    surface_id: str,
    required_routes: list[str],
    required_states: list[str],
) -> list[dict[str, Any]]:
    if not isinstance(raw, dict):
        raise ValueError(f"{surface_id} capture input is malformed")
    captures = raw.get("captures")
    if not isinstance(captures, list) or not captures:
        raise ValueError(f"{surface_id} captures are missing")
    if any(not isinstance(row, dict) for row in captures):
        raise ValueError(f"{surface_id} capture input is malformed")
    typed = [row for row in captures if isinstance(row, dict)]
    states = [
        _require_text(row.get("state"), f"{surface_id} capture state")
        for row in typed
    ]
    routes = [
        _require_text(row.get("route"), f"{surface_id} capture route")
        for row in typed
    ]
    if len(set(zip(routes, states))) != len(typed):
        raise ValueError(f"{surface_id} capture route/state pairs are duplicated")
    if set(states) != set(required_states):
        raise ValueError(f"{surface_id} required states are incomplete")
    if set(routes) != set(required_routes):
        raise ValueError(f"{surface_id} required routes are incomplete")
    return typed


def _validated_interaction_comparison(
    row: dict[str, Any],
    *,
    surface_id: str,
) -> dict[str, Any]:
    comparison = row.get("interactionComparison")
    if not isinstance(comparison, dict):
        raise ValueError(f"{surface_id} interaction comparison is malformed")
    status = comparison.get("status")
    control_delta = comparison.get("controlCountDelta")
    keyboard_delta = comparison.get("keyboardAccessibleCountDelta")
    by_tag_delta = comparison.get("byTagDelta")
    shared_count = comparison.get("sharedLabelFingerprintCount")
    missing = comparison.get("missingOfficialLabelFingerprints")
    unexpected = comparison.get("unexpectedIPadLabelFingerprints")
    valid = (
        status in {"matched", "different"}
        and isinstance(control_delta, int)
        and not isinstance(control_delta, bool)
        and isinstance(keyboard_delta, int)
        and not isinstance(keyboard_delta, bool)
        and isinstance(by_tag_delta, dict)
        and all(
            isinstance(tag, str)
            and bool(tag)
            and isinstance(delta, int)
            and not isinstance(delta, bool)
            and delta != 0
            for tag, delta in by_tag_delta.items()
        )
        and isinstance(shared_count, int)
        and not isinstance(shared_count, bool)
        and shared_count >= 0
        and isinstance(missing, list)
        and len(missing) == len(set(missing))
        and isinstance(unexpected, list)
        and len(unexpected) == len(set(unexpected))
        and all(
            isinstance(value, str)
            and SHA256_PATTERN.fullmatch(value) is not None
            for value in [*missing, *unexpected]
        )
    )
    calculated_status = (
        "matched"
        if control_delta == 0
        and keyboard_delta == 0
        and not by_tag_delta
        and not missing
        and not unexpected
        else "different"
    )
    if not valid or status != calculated_status:
        raise ValueError(f"{surface_id} interaction comparison is malformed")
    return {
        "status": status,
        "controlCountDelta": control_delta,
        "keyboardAccessibleCountDelta": keyboard_delta,
        "byTagDelta": dict(sorted(by_tag_delta.items())),
        "sharedLabelFingerprintCount": shared_count,
        "missingOfficialLabelFingerprints": sorted(missing),
        "unexpectedIPadLabelFingerprints": sorted(unexpected),
    }


def build_release_parity_evidence(
    project_root: Path,
    *,
    desktop_version: str,
    desktop_build: str,
    capture_input_path: Path,
    python_test_log: Path,
    swift_test_log: Path,
    rust_test_log: Path,
    xcui_test_log: Path,
    device_build_log: Path,
    device_surface_log: Path,
) -> tuple[Path, Path, Path]:
    project_root = project_root.resolve()
    version_root = project_root / "versions" / desktop_version
    full_reverse_root = (
        project_root / "artifacts" / f"full-reverse-{desktop_version}"
    )
    evidence_root = (
        project_root / "artifacts" / "parity-evidence" / desktop_version
    )

    capture_input = load_json_object(capture_input_path)
    capture_surfaces = _validate_capture_input(
        capture_input,
        desktop_version=desktop_version,
        desktop_build=desktop_build,
    )

    verification_sources = {
        "python-tests.log": python_test_log,
        "swift-tests.log": swift_test_log,
        "rust-tests.log": rust_test_log,
        "xcui-tests.log": xcui_test_log,
        "device-build.log": device_build_log,
        "device-surface.json": device_surface_log,
    }
    for source in verification_sources.values():
        if not source.is_file() or source.stat().st_size == 0:
            raise ValueError(f"verification evidence is missing: {source}")

    # Validate every manual capture before touching an existing certification
    # tree. A missing, duplicate, undersized, or malformed S01-S10 capture must
    # leave the last complete visual-certification evidence unchanged.
    definitions = {
        definition["id"]: definition for definition in SURFACE_DEFINITIONS
    }
    validated_captures: dict[str, list[dict[str, Any]]] = {}
    official_hashes: set[str] = set()
    ipad_hashes: set[str] = set()
    for surface_id in EXPECTED_SURFACE_IDS:
        definition = definitions[surface_id]
        rows = _capture_rows_for_surface(
            capture_surfaces[surface_id],
            surface_id=surface_id,
            required_routes=list(definition["routes"]),
            required_states=list(definition["requiredStates"]),
        )
        validated_captures[surface_id] = rows
        for index, row in enumerate(rows, start=1):
            capture_label = f"{surface_id} capture {index}"
            _validated_interaction_comparison(row, surface_id=capture_label)
            official_source = _safe_project_file(
                project_root,
                row.get("officialDesktop"),
                label=f"{capture_label} official desktop capture",
            )
            ipad_source = _safe_project_file(
                project_root,
                row.get("ipad"),
                label=f"{capture_label} iPad capture",
            )
            _validated_png(
                official_source,
                f"{capture_label} official desktop capture",
            )
            _validated_png(ipad_source, f"{capture_label} iPad capture")
            official_digest = sha256_file(official_source)
            ipad_digest = sha256_file(ipad_source)
            if official_digest == ipad_digest:
                raise ValueError(
                    f"{capture_label} desktop and iPad captures are identical files"
                )
            if official_digest in official_hashes:
                raise ValueError(
                    f"{capture_label} reuses another official desktop capture"
                )
            if ipad_digest in ipad_hashes:
                raise ValueError(f"{capture_label} reuses another iPad capture")
            official_hashes.add(official_digest)
            ipad_hashes.add(ipad_digest)

    evidence_root.mkdir(parents=True, exist_ok=True)
    copied: dict[str, dict[str, str]] = {}
    for name, source in verification_sources.items():
        copied[name] = _copy_evidence_file(
            project_root,
            source,
            evidence_root / "verification" / name,
        )

    implementation_surfaces: dict[str, dict[str, object]] = {}
    capture_surfaces_output: dict[str, dict[str, object]] = {}
    for surface_id in EXPECTED_SURFACE_IDS:
        surface_root = evidence_root / surface_id
        surface_root.mkdir(parents=True, exist_ok=True)
        definition = definitions[surface_id]
        output_captures: list[dict[str, Any]] = []
        visual_evidence: list[dict[str, str]] = []
        device_capture_evidence: list[dict[str, str]] = []
        comparisons: list[dict[str, Any]] = []
        for index, row in enumerate(validated_captures[surface_id], start=1):
            capture_label = f"{surface_id} capture {index}"
            interaction_comparison = _validated_interaction_comparison(
                row,
                surface_id=capture_label,
            )
            comparisons.append(interaction_comparison)
            official_source = _safe_project_file(
                project_root,
                row.get("officialDesktop"),
                label=f"{capture_label} official desktop capture",
            )
            ipad_source = _safe_project_file(
                project_root,
                row.get("ipad"),
                label=f"{capture_label} iPad capture",
            )
            official_image = _validated_png(
                official_source,
                f"{capture_label} official desktop capture",
            )
            ipad_image = _validated_png(
                ipad_source,
                f"{capture_label} iPad capture",
            )
            capture_root = surface_root / f"capture-{index:03d}"
            capture_root.mkdir(parents=True, exist_ok=True)
            official_destination = capture_root / "official-desktop.png"
            ipad_destination = capture_root / "ipad.png"
            shutil.copy2(official_source, official_destination)
            shutil.copy2(ipad_source, ipad_destination)
            diff_destination = capture_root / "pixel-diff.png"
            _render_pixel_diff(
                official_destination,
                ipad_destination,
                diff_destination,
            )
            metadata_path = capture_root / "capture-metadata.json"
            write_json_atomic(
                metadata_path,
                {
                    "schemaVersion": 3,
                    "desktopVersion": desktop_version,
                    "desktopBuild": desktop_build,
                    "surfaceId": surface_id,
                    "route": row["route"],
                    "state": row["state"],
                    "officialDesktopDimensions": [
                        official_image.width,
                        official_image.height,
                    ],
                    "ipadDimensions": [ipad_image.width, ipad_image.height],
                    "interactionComparison": interaction_comparison,
                },
            )
            official_entry = _evidence_entry(
                project_root,
                official_destination,
            )
            ipad_entry = _evidence_entry(project_root, ipad_destination)
            diff_entry = _evidence_entry(project_root, diff_destination)
            metadata_entry = _evidence_entry(project_root, metadata_path)
            capture_status = (
                "matched"
                if interaction_comparison["status"] == "matched"
                else "interaction-inventory-different"
            )
            output_captures.append(
                {
                    "route": row["route"],
                    "state": row["state"],
                    "status": capture_status,
                    "interactionInventoryStatus": interaction_comparison[
                        "status"
                    ],
                    "officialDesktop": official_entry,
                    "ipad": ipad_entry,
                    "pixelDiff": diff_entry,
                    "captureMetadata": metadata_entry,
                }
            )
            visual_evidence.extend(
                [official_entry, ipad_entry, diff_entry, metadata_entry]
            )
            device_capture_evidence.append(ipad_entry)
        surface_status = (
            "matched"
            if all(row["status"] == "matched" for row in comparisons)
            else "interaction-inventory-different"
        )
        implementation_surfaces[surface_id] = {
            "status": surface_status,
            "automatedTests": [
                copied["python-tests.log"],
                copied["swift-tests.log"],
                copied["rust-tests.log"],
                copied["xcui-tests.log"],
            ],
            "simulatorEvidence": [],
            "deviceEvidence": [
                copied["device-build.log"],
                copied["device-surface.json"],
                *device_capture_evidence,
            ],
            "visualEvidence": visual_evidence,
        }
        capture_surfaces_output[surface_id] = {
            "status": surface_status,
            "interactionInventoryStatus": (
                "matched"
                if surface_status == "matched"
                else "different"
            ),
            "requiredRoutes": list(definition["routes"]),
            "requiredStates": list(definition["requiredStates"]),
            "coveredRoutes": sorted(
                {row["route"] for row in validated_captures[surface_id]}
            ),
            "coveredStates": sorted(
                {row["state"] for row in validated_captures[surface_id]}
            ),
            "captures": output_captures,
        }

    implementation_path = evidence_root / "implementation-evidence.json"
    capture_manifest_path = evidence_root / "capture-manifest.json"
    write_json_atomic(
        implementation_path,
        {
            "schemaVersion": 3,
            "desktopVersion": desktop_version,
            "desktopBuild": desktop_build,
            "surfaces": implementation_surfaces,
        },
    )
    write_json_atomic(
        capture_manifest_path,
        {
            "schemaVersion": 3,
            "desktopVersion": desktop_version,
            "desktopBuild": desktop_build,
            "surfaces": capture_surfaces_output,
        },
    )

    version_manifest = load_json_object(version_root / "manifest.json")
    surface_manifest = load_json_object(
        version_root / "desktop-surface-manifest.json"
    )
    full_reverse_manifest = load_json_object(
        full_reverse_root / "full-reverse-manifest.json"
    )
    parity_path = version_root / "desktop-ui-parity.json"
    write_json_atomic(
        parity_path,
        build_desktop_ui_parity(
            full_reverse_root / "recovered-electron-source",
            desktop_version=desktop_version,
            desktop_build=desktop_build,
            source_dmg_sha256=_require_text(
                version_manifest.get("dmgSha256"),
                "version manifest DMG hash",
            ),
            desktop_surface_tree_sha256=_require_text(
                surface_manifest.get("resourceTreeSha256"),
                "desktop surface tree hash",
            ),
            recovered_source_index_sha256=_require_text(
                full_reverse_manifest.get("recoveredSourceIndexSha256"),
                "recovered source index hash",
            ),
            implementation_evidence={
                "surfaces": implementation_surfaces,
            },
            capture_manifest={"surfaces": capture_surfaces_output},
            evidence_root=project_root,
        ),
    )
    return implementation_path, capture_manifest_path, parity_path


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--project-root", type=Path, required=True)
    parser.add_argument("--desktop-version", required=True)
    parser.add_argument("--desktop-build", required=True)
    parser.add_argument("--capture-input", type=Path, required=True)
    parser.add_argument("--python-test-log", type=Path, required=True)
    parser.add_argument("--swift-test-log", type=Path, required=True)
    parser.add_argument("--rust-test-log", type=Path, required=True)
    parser.add_argument("--xcui-test-log", type=Path, required=True)
    parser.add_argument("--device-build-log", type=Path, required=True)
    parser.add_argument("--device-surface-log", type=Path, required=True)
    args = parser.parse_args()
    implementation, captures, parity = build_release_parity_evidence(
        args.project_root,
        desktop_version=args.desktop_version,
        desktop_build=args.desktop_build,
        capture_input_path=args.capture_input,
        python_test_log=args.python_test_log,
        swift_test_log=args.swift_test_log,
        rust_test_log=args.rust_test_log,
        xcui_test_log=args.xcui_test_log,
        device_build_log=args.device_build_log,
        device_surface_log=args.device_surface_log,
    )
    print(f"Implementation evidence: {implementation}")
    print(f"Capture manifest: {captures}")
    print(f"Desktop UI parity: {parity}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
