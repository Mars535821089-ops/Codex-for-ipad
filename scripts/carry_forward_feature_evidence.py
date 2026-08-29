#!/usr/bin/env python3
"""Carry release-independent feature evidence across identical protocols."""

from __future__ import annotations

import argparse
from collections import Counter
import copy
from pathlib import Path
import re
import sys
from typing import Any

if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from scripts.protocol_manifest import load_json_object, write_json_atomic


VERSION_PATTERN = re.compile(r"^[0-9]+(?:\.[0-9]+)+$")
EVIDENCE_FIELDS = (
    "ipadModule",
    "automatedTests",
    "simulatorEvidence",
    "deviceEvidence",
    "visualEvidence",
)


def _version_key(version: str) -> tuple[int, ...]:
    if VERSION_PATTERN.fullmatch(version) is None:
        raise ValueError(f"malformed version: {version}")
    return tuple(int(component) for component in version.split("."))


def _desktop_identity(feature: dict[str, Any]) -> tuple[tuple[str, str, str], ...]:
    rows = feature.get("desktopEvidence")
    if not isinstance(rows, list) or not rows:
        return ()
    identity: list[tuple[str, str, str]] = []
    for row in rows:
        if not isinstance(row, dict):
            return ()
        channel = row.get("channel")
        path = row.get("file")
        digest = row.get("fileSha256")
        if not all(isinstance(value, str) and value for value in (channel, path, digest)):
            return ()
        identity.append((channel, path, digest))
    return tuple(sorted(identity))


def _eligible_source(feature: dict[str, Any]) -> bool:
    return (
        feature.get("status") == "matched"
        and isinstance(feature.get("ipadModule"), str)
        and bool(feature["ipadModule"].strip())
        and isinstance(feature.get("automatedTests"), list)
        and bool(feature["automatedTests"])
        and bool(_desktop_identity(feature))
    )


def carry_forward_feature_evidence(
    current: dict[str, Any],
    previous_inventories: list[dict[str, Any]],
) -> dict[str, Any]:
    current_version = current.get("version")
    if not isinstance(current_version, str):
        raise ValueError("current inventory version is missing")
    current_key = _version_key(current_version)
    features = current.get("features")
    if not isinstance(features, list):
        raise ValueError("current inventory features are missing")

    candidates: dict[str, list[tuple[tuple[int, ...], str, dict[str, Any]]]] = {}
    for inventory in previous_inventories:
        version = inventory.get("version")
        rows = inventory.get("features")
        if not isinstance(version, str) or not isinstance(rows, list):
            continue
        try:
            version_key = _version_key(version)
        except ValueError:
            continue
        if version_key >= current_key:
            continue
        for feature in rows:
            if not isinstance(feature, dict) or not _eligible_source(feature):
                continue
            identifier = feature.get("id")
            if isinstance(identifier, str):
                candidates.setdefault(identifier, []).append(
                    (version_key, version, feature)
                )

    output = copy.deepcopy(current)
    carried = 0
    for feature in output["features"]:
        if not isinstance(feature, dict) or feature.get("status") != "unknown":
            continue
        identifier = feature.get("id")
        identity = _desktop_identity(feature)
        if not isinstance(identifier, str) or not identity:
            continue
        sources = sorted(candidates.get(identifier, []), reverse=True)
        source = next(
            (
                (version, row)
                for _, version, row in sources
                if _desktop_identity(row) == identity
            ),
            None,
        )
        if source is None:
            continue
        source_version, source_feature = source
        for field in EVIDENCE_FIELDS:
            feature[field] = copy.deepcopy(source_feature[field])
        feature["status"] = "matched"
        feature["evidenceProvenance"] = {
            "kind": "identical-desktop-protocol",
            "sourceVersion": source_version,
        }
        carried += 1

    statuses = Counter(
        str(feature.get("status"))
        for feature in output["features"]
        if isinstance(feature, dict)
    )
    output["statusCounts"] = dict(sorted(statuses.items()))
    output["carriedEvidenceCount"] = carried
    return output


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--project-root", type=Path, required=True)
    parser.add_argument("--inventory", type=Path, required=True)
    args = parser.parse_args()
    project_root = args.project_root.resolve()
    inventory_path = args.inventory.resolve()
    inventory_path.relative_to(project_root)
    current = load_json_object(inventory_path)
    previous: list[dict[str, Any]] = []
    for path in sorted((project_root / "versions").glob("*/feature-inventory.json")):
        if path.resolve() != inventory_path:
            previous.append(load_json_object(path))
    write_json_atomic(
        inventory_path,
        carry_forward_feature_evidence(current, previous),
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
