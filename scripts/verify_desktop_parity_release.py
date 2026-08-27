#!/usr/bin/env python3
"""Verify that one iPad release is bound to complete desktop parity evidence."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import re
import sys
from typing import Any

if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from scripts.build_desktop_surface_manifest import (
    verify_desktop_surface_manifest,
)
from scripts.build_desktop_interaction_inventory import (
    verify_desktop_interaction_inventory,
)
from scripts.build_desktop_ui_parity import (
    EXPECTED_SURFACE_IDS,
    desktop_ui_parity_blockers,
)
from scripts.check_parity_gate import check_parity
from scripts.protocol_manifest import (
    load_json_object,
    sha256_file,
    write_json_atomic,
)


VERSION_PATTERN = re.compile(r"^[0-9]+(?:\.[0-9]+)+$")
BUILD_PATTERN = re.compile(r"^[1-9][0-9]*$")
SHA256_PATTERN = re.compile(r"^[0-9a-f]{64}$")
FEATURE_COVERAGE_CLASSIFICATIONS = {
    "implemented-and-test-referenced",
    "inventory-matched",
}


def _require_equal(
    record: dict[str, Any],
    key: str,
    expected: object,
    *,
    label: str,
) -> None:
    if record.get(key) != expected:
        raise ValueError(f"{label} {key} does not match exact release")


def _safe_evidence_file(
    root: Path,
    record: object,
    *,
    label: str,
    path_key: str = "path",
    expected_bytes: object | None = None,
) -> Path:
    if not isinstance(record, dict):
        raise ValueError(f"{label} evidence record is malformed")
    relative = record.get(path_key)
    expected_sha256 = record.get("sha256")
    if (
        not isinstance(relative, str)
        or not relative
        or not isinstance(expected_sha256, str)
        or SHA256_PATTERN.fullmatch(expected_sha256) is None
    ):
        raise ValueError(f"{label} evidence identity is malformed")
    relative_path = Path(relative)
    if (
        relative_path.is_absolute()
        or ".." in relative_path.parts
        or "." in relative_path.parts
        or "\\" in relative
    ):
        raise ValueError(f"{label} evidence path escapes its root")
    root = root.resolve()
    candidate = (root / relative_path).resolve()
    try:
        candidate.relative_to(root)
    except ValueError as error:
        raise ValueError(f"{label} evidence path escapes its root") from error
    if not candidate.is_file():
        raise ValueError(f"{label} evidence file is missing")
    if sha256_file(candidate) != expected_sha256:
        raise ValueError(f"{label} evidence hash mismatch")
    if expected_bytes is not None:
        if (
            isinstance(expected_bytes, bool)
            or not isinstance(expected_bytes, int)
            or expected_bytes < 0
            or candidate.stat().st_size != expected_bytes
        ):
            raise ValueError(f"{label} evidence byte count mismatch")
    return candidate


def _verify_contract_evidence(
    project_root: Path,
    recovered_root: Path,
    contract: dict[str, Any],
) -> int:
    surfaces = contract.get("surfaces")
    if not isinstance(surfaces, list):
        raise ValueError("desktop UI parity surfaces are malformed")
    evidence_count = 0
    for surface in surfaces:
        if not isinstance(surface, dict):
            raise ValueError("desktop UI parity surface is malformed")
        surface_id = surface.get("id")
        for index, record in enumerate(surface.get("desktopEvidence", [])):
            _safe_evidence_file(
                recovered_root,
                record,
                label=f"{surface_id} desktop reference {index}",
                path_key="file",
                expected_bytes=(
                    record.get("bytes")
                    if isinstance(record, dict)
                    else None
                ),
            )
            evidence_count += 1
        for field in (
            "automatedTests",
            "simulatorEvidence",
            "deviceEvidence",
            "visualEvidence",
        ):
            records = surface.get(field)
            if not isinstance(records, list):
                raise ValueError(f"{surface_id} {field} is malformed")
            for index, record in enumerate(records):
                _safe_evidence_file(
                    project_root,
                    record,
                    label=f"{surface_id} {field} {index}",
                )
                evidence_count += 1
        captures = surface.get("runtimeCaptureEvidence")
        if not isinstance(captures, dict):
            raise ValueError(f"{surface_id} runtime captures are malformed")
        capture_rows = captures.get("captures")
        if not isinstance(capture_rows, list) or not capture_rows:
            raise ValueError(f"{surface_id} runtime captures are malformed")
        for capture_index, capture in enumerate(capture_rows, start=1):
            if not isinstance(capture, dict):
                raise ValueError(f"{surface_id} runtime captures are malformed")
            for capture_name in (
                "officialDesktop",
                "ipad",
                "pixelDiff",
                "captureMetadata",
            ):
                _safe_evidence_file(
                    project_root,
                    capture.get(capture_name),
                    label=(
                        f"{surface_id} capture {capture_index} "
                        f"{capture_name}"
                    ),
                )
                evidence_count += 1
    return evidence_count


def _verify_feature_coverage(
    version_root: Path,
    full_reverse_root: Path,
    feature_inventory: dict[str, Any],
    *,
    desktop_version: str,
) -> dict[str, Any]:
    project_root = version_root.parent.parent.resolve()
    coverage_path = version_root / "feature-coverage-audit.json"
    coverage = load_json_object(coverage_path)
    if coverage.get("version") != desktop_version:
        raise ValueError("feature coverage version does not match exact release")
    if coverage.get("featureCount") != feature_inventory.get("featureCount"):
        raise ValueError("feature coverage feature count does not match inventory")
    protocol = (
        full_reverse_root
        / "official-codex-source/codex-rs/app-server-protocol/src/protocol/common.rs"
    )
    inventory_path = version_root / "feature-inventory.json"
    if not protocol.is_file():
        raise ValueError("feature coverage protocol source is missing")
    protocol_source = coverage.get("protocolSource")
    inventory_source = coverage.get("inventorySource")
    if not isinstance(protocol_source, str) or not protocol_source:
        raise ValueError("feature coverage protocol source is malformed")
    if not isinstance(inventory_source, str) or not inventory_source:
        raise ValueError("feature coverage inventory source is malformed")
    recorded_protocol = Path(protocol_source)
    if not recorded_protocol.is_absolute():
        recorded_protocol = project_root / recorded_protocol
    recorded_inventory = Path(inventory_source)
    if not recorded_inventory.is_absolute():
        recorded_inventory = project_root / recorded_inventory
    if recorded_protocol.resolve() != protocol.resolve():
        raise ValueError("feature coverage protocol source does not match release")
    if recorded_inventory.resolve() != inventory_path.resolve():
        raise ValueError("feature coverage inventory source does not match release")
    if coverage.get("protocolSha256") != sha256_file(protocol):
        raise ValueError("feature coverage protocol hash does not match release")
    if coverage.get("inventorySha256") != sha256_file(inventory_path):
        raise ValueError("feature coverage inventory hash does not match release")
    counts = coverage.get("classificationCounts")
    if not isinstance(counts, dict):
        raise ValueError("feature coverage classifications are malformed")
    blockers = {
        key: value
        for key, value in counts.items()
        if key not in FEATURE_COVERAGE_CLASSIFICATIONS and value
    }
    if blockers:
        raise ValueError(f"feature coverage blockers: {len(blockers)}")
    return coverage


def verify_release(
    project_root: Path,
    *,
    desktop_version: str,
    desktop_build: str,
    expected_dmg_sha256: str,
    output_path: Path | None = None,
) -> dict[str, object]:
    if VERSION_PATTERN.fullmatch(desktop_version) is None:
        raise ValueError("desktop version is malformed")
    if BUILD_PATTERN.fullmatch(desktop_build) is None:
        raise ValueError("desktop build is malformed")
    if SHA256_PATTERN.fullmatch(expected_dmg_sha256) is None:
        raise ValueError("expected DMG hash is malformed")

    project_root = project_root.resolve()
    if not project_root.is_dir():
        raise ValueError("project root is missing")
    version_root = project_root / "versions" / desktop_version
    artifacts_root = project_root / "artifacts"
    full_reverse_root = artifacts_root / f"full-reverse-{desktop_version}"

    version_manifest = load_json_object(version_root / "manifest.json")
    import_manifest = load_json_object(
        artifacts_root / f"manifest-{desktop_version}.json"
    )
    full_reverse_manifest = load_json_object(
        full_reverse_root / "full-reverse-manifest.json"
    )
    surface_manifest = load_json_object(
        version_root / "desktop-surface-manifest.json"
    )
    ui_contract = load_json_object(
        version_root / "desktop-ui-parity.json"
    )
    try:
        interaction_inventory = load_json_object(
            version_root / "desktop-interaction-inventory.json"
        )
    except (FileNotFoundError, json.JSONDecodeError, ValueError) as error:
        raise ValueError("desktop interaction inventory is missing") from error
    feature_inventory = load_json_object(version_root / "feature-inventory.json")

    for label, record, version_key, build_key in (
        (
            "version manifest",
            version_manifest,
            "version",
            "build",
        ),
        (
            "import manifest",
            import_manifest,
            "version",
            "build",
        ),
        (
            "full reverse manifest",
            full_reverse_manifest,
            "version",
            "build",
        ),
        (
            "desktop surface manifest",
            surface_manifest,
            "desktopVersion",
            "desktopBuild",
        ),
        (
            "desktop UI parity",
            ui_contract,
            "desktopVersion",
            "desktopBuild",
        ),
    ):
        _require_equal(
            record,
            version_key,
            desktop_version,
            label=label,
        )
        _require_equal(
            record,
            build_key,
            desktop_build,
            label=label,
        )

    _require_equal(
        version_manifest,
        "dmgSha256",
        expected_dmg_sha256,
        label="version manifest",
    )
    _require_equal(
        import_manifest,
        "dmg_sha256",
        expected_dmg_sha256,
        label="import manifest",
    )
    _require_equal(
        feature_inventory,
        "version",
        desktop_version,
        label="feature inventory",
    )

    source_identity = ui_contract.get("sourceIdentity")
    if not isinstance(source_identity, dict):
        raise ValueError("desktop UI parity source identity is missing")
    expected_source_identity = {
        "dmgSha256": expected_dmg_sha256,
        "desktopSurfaceTreeSha256": surface_manifest.get(
            "resourceTreeSha256"
        ),
        "recoveredSourceIndexSha256": full_reverse_manifest.get(
            "recoveredSourceIndexSha256"
        ),
    }
    if source_identity != expected_source_identity:
        raise ValueError(
            "desktop UI parity source identity does not match exact release"
        )
    for key, value in expected_source_identity.items():
        if not isinstance(value, str) or SHA256_PATTERN.fullmatch(value) is None:
            raise ValueError(f"exact release {key} is malformed")

    renderer_root = full_reverse_root / "app-asar/webview"
    preload_path = (
        full_reverse_root
        / "recovered-electron-source/.vite/build/preload.js"
    )
    surface_blockers = verify_desktop_surface_manifest(
        surface_manifest,
        renderer_root,
        preload_path,
    )
    if surface_blockers:
        raise ValueError(
            "desktop surface blockers: " + "; ".join(surface_blockers)
        )
    interaction_summary = verify_desktop_interaction_inventory(
        interaction_inventory,
        full_reverse_root / "recovered-electron-source",
        desktop_version=desktop_version,
        desktop_build=desktop_build,
        desktop_surface_tree_sha256=str(
            surface_manifest.get("resourceTreeSha256", "")
        ),
    )

    recovered_source_index = (
        full_reverse_root / "recovered-source-index.json"
    )
    if not recovered_source_index.is_file():
        raise ValueError("recovered source index is missing")
    if (
        sha256_file(recovered_source_index)
        != full_reverse_manifest.get("recoveredSourceIndexSha256")
    ):
        raise ValueError("recovered source index hash mismatch")

    ui_blockers = desktop_ui_parity_blockers(ui_contract)
    if ui_blockers:
        raise ValueError(f"desktop UI parity blockers: {len(ui_blockers)}")
    if [
        row.get("id")
        for row in ui_contract.get("surfaces", [])
        if isinstance(row, dict)
    ] != list(EXPECTED_SURFACE_IDS):
        raise ValueError("desktop UI parity surface identity mismatch")
    evidence_count = _verify_contract_evidence(
        project_root,
        full_reverse_root / "recovered-electron-source",
        ui_contract,
    )

    feature_blockers = check_parity(feature_inventory)
    if feature_blockers:
        raise ValueError(f"feature parity blockers: {len(feature_blockers)}")
    _verify_feature_coverage(
        version_root,
        full_reverse_root,
        feature_inventory,
        desktop_version=desktop_version,
    )

    result: dict[str, object] = {
        "schemaVersion": 1,
        "status": "passed",
        "desktopVersion": desktop_version,
        "desktopBuild": desktop_build,
        "sourceIdentity": expected_source_identity,
        "desktopSurface": "passed",
        "desktopUIParity": "passed",
        "desktopInteractionInventory": "passed",
        "interactionCount": interaction_summary["interactionCount"],
        "interactionEvidenceFileCount": interaction_summary[
            "evidenceFileCount"
        ],
        "featureParity": "passed",
        "surfaceCount": len(EXPECTED_SURFACE_IDS),
        "featureCount": feature_inventory.get("featureCount"),
        "featureCoverage": "passed",
        "evidenceFileCount": evidence_count,
    }
    if output_path is not None:
        output_path = output_path.resolve()
        try:
            output_path.relative_to(project_root)
        except ValueError as error:
            raise ValueError(
                "parity verification output escapes project root"
            ) from error
        write_json_atomic(output_path, result)
    return result


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--project-root", type=Path, required=True)
    parser.add_argument("--desktop-version", required=True)
    parser.add_argument("--desktop-build", required=True)
    parser.add_argument("--expected-dmg-sha256", required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    try:
        verify_release(
            args.project_root,
            desktop_version=args.desktop_version,
            desktop_build=args.desktop_build,
            expected_dmg_sha256=args.expected_dmg_sha256,
            output_path=args.output,
        )
    except (OSError, ValueError, TypeError, json.JSONDecodeError) as error:
        parser.error(str(error))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
