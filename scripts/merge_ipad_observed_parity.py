#!/usr/bin/env python3
"""Strictly merge partial physical-iPad parity manifests.

The merger combines observations without upgrading an unobserved capture to
verified status.  All inputs must describe the same desktop release and the
same physical device; source manifest hashes are retained for auditability.
"""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import shutil
import tempfile
from typing import Any

from scripts.parity_capture_plan import capture_specs, capture_specs_by_surface


EXPECTED_SPECS = capture_specs()
EXPECTED_BY_SURFACE = capture_specs_by_surface()


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _read_manifest(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise ValueError(f"observed manifest is malformed: {path}") from error
    if not isinstance(value, dict) or value.get("schemaVersion") != 5:
        raise ValueError(f"observed manifest must use schema 5: {path}")
    return value


def _copy_checked(source: Path, destination: Path, expected_sha256: str) -> None:
    if not source.is_file():
        raise ValueError(f"observed attachment is missing: {source}")
    actual = _sha256(source)
    if actual != expected_sha256:
        raise ValueError(f"observed attachment hash mismatch: {source}")
    destination.parent.mkdir(parents=True, exist_ok=True)
    if not destination.exists():
        shutil.copyfile(source, destination)


def merge_observed_manifests(
    manifests: list[Path],
    output_root: Path,
    *,
    desktop_version: str,
    desktop_build: str,
    device_id: str,
) -> Path:
    """Merge schema-5 manifests and return the schema-6 manifest path."""
    if not manifests:
        raise ValueError("at least one observed manifest is required")
    loaded: list[tuple[Path, dict[str, Any], str]] = []
    for raw_path in manifests:
        path = Path(raw_path).resolve()
        value = _read_manifest(path)
        if value.get("desktopVersion") != desktop_version:
            raise ValueError("observed manifests mix desktop versions")
        if str(value.get("desktopBuild")) != str(desktop_build):
            raise ValueError("observed manifests mix desktop builds")
        if value.get("deviceId") != device_id:
            raise ValueError("observed manifests mix physical devices")
        if not isinstance(value.get("deviceName"), str) or not value["deviceName"].strip():
            raise ValueError("observed manifest device name is malformed")
        loaded.append((path, value, _sha256(path)))

    device_name = loaded[0][1]["deviceName"]
    if any(value["deviceName"] != device_name for _, value, _ in loaded):
        raise ValueError("observed manifests mix device names")

    output_root.parent.mkdir(parents=True, exist_ok=True)
    staging = Path(tempfile.mkdtemp(prefix=f".{output_root.name}.staging-", dir=output_root.parent))
    try:
        merged: dict[tuple[str, str], dict[str, Any]] = {}
        source_rows: list[dict[str, Any]] = []
        for source_path, value, source_sha in loaded:
            source_rows.append({
                "path": str(source_path),
                "sha256": source_sha,
                "observedCaptureCount": sum(
                    len(surface.get("captures", []))
                    for surface in value.get("surfaces", {}).values()
                    if isinstance(surface, dict)
                ),
            })
            surfaces = value.get("surfaces")
            if not isinstance(surfaces, dict):
                raise ValueError("observed manifest surfaces are malformed")
            for surface_id, surface in surfaces.items():
                if surface_id not in EXPECTED_BY_SURFACE or not isinstance(surface, dict):
                    raise ValueError(f"unknown observed surface: {surface_id}")
                captures = surface.get("captures", [])
                if not isinstance(captures, list):
                    raise ValueError(f"observed captures are malformed: {surface_id}")
                for capture in captures:
                    if not isinstance(capture, dict):
                        raise ValueError("observed capture is malformed")
                    key = capture.get("captureKey")
                    spec = next((row for row in EXPECTED_BY_SURFACE[surface_id] if row["captureKey"] == key), None)
                    if spec is None:
                        raise ValueError(f"unknown observed capture: {surface_id}|{key}")
                    if capture.get("deviceId") != device_id:
                        raise ValueError("capture device does not match merge device")
                    image_name = capture.get("path")
                    image_sha = capture.get("sha256")
                    if not isinstance(image_name, str) or not isinstance(image_sha, str):
                        raise ValueError("observed capture path/hash is malformed")
                    image_path = (source_path.parent / image_name).resolve()
                    if image_path.parent != source_path.parent:
                        raise ValueError("observed capture escapes manifest directory")
                    observation_name = (
                        f"observations/{surface_id}-{key}-{image_sha[:16]}.png"
                    )
                    _copy_checked(image_path, staging / observation_name, image_sha)
                    observation = dict(capture)
                    observation["sourceManifestSha256"] = source_sha
                    observation["sourceManifestPath"] = str(source_path)
                    observation["path"] = observation_name
                    identity = (surface_id, key)
                    existing = merged.get(identity)
                    if existing is None:
                        base = {k: v for k, v in capture.items() if k != "observations"}
                        base["path"] = observation_name
                        base["observations"] = [observation]
                        merged[identity] = base
                    else:
                        existing["observations"].append(observation)

        surfaces_out: dict[str, dict[str, Any]] = {}
        for surface_id, specs in EXPECTED_BY_SURFACE.items():
            rows = [merged[(surface_id, spec["captureKey"])] for spec in specs if (surface_id, spec["captureKey"]) in merged]
            surfaces_out[surface_id] = {"captures": rows}
        observed_count = len(merged)
        manifest = {
            "schemaVersion": 6,
            "evidenceMode": "physical-official-renderer-observed-merged",
            "desktopVersion": desktop_version,
            "desktopBuild": str(desktop_build),
            "deviceId": device_id,
            "deviceName": device_name,
            "observedCaptureCount": observed_count,
            "requiredCaptureCount": len(EXPECTED_SPECS),
            "missingCaptureCount": len(EXPECTED_SPECS) - observed_count,
            "observedSurfaceIds": sorted({surface_id for surface_id, _ in merged}),
            "missingSurfaceIds": [surface_id for surface_id, rows in surfaces_out.items() if not rows["captures"]],
            "sourceManifests": source_rows,
            "surfaces": surfaces_out,
        }
        (staging / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        if output_root.exists():
            shutil.rmtree(output_root)
        staging.rename(output_root)
        return output_root / "manifest.json"
    except Exception:
        shutil.rmtree(staging, ignore_errors=True)
        raise


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--desktop-version", required=True)
    parser.add_argument("--desktop-build", required=True)
    parser.add_argument("--device-id", required=True)
    parser.add_argument("manifests", nargs="+", type=Path)
    args = parser.parse_args()
    print(merge_observed_manifests(args.manifests, args.output, desktop_version=args.desktop_version, desktop_build=args.desktop_build, device_id=args.device_id))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
