#!/usr/bin/env python3
"""Merge static protocol coverage into the feature inventory."""

from __future__ import annotations

import argparse
from collections import Counter
import copy
import hashlib
import json
from pathlib import Path
import sys
from typing import Any

if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from scripts.protocol_manifest import load_json_object, write_json_atomic


STATIC_IMPLEMENTATION_STATUS = "implemented-static-evidence"
MERGEABLE_CLASSIFICATION = "implemented-and-test-referenced"


def _feature_rows(record: dict[str, Any], *, label: str) -> list[dict[str, Any]]:
    rows = record.get("features")
    if not isinstance(rows, list):
        raise ValueError(f"{label} features must be an array")
    if record.get("featureCount") != len(rows):
        raise ValueError(f"{label} feature count mismatch")
    typed_rows: list[dict[str, Any]] = []
    seen: set[str] = set()
    for row in rows:
        if not isinstance(row, dict):
            raise ValueError(f"{label} feature row must be an object")
        identifier = row.get("id")
        if not isinstance(identifier, str) or not identifier:
            raise ValueError(f"{label} feature id must be a string")
        if identifier in seen:
            raise ValueError(f"{label} has duplicate feature id: {identifier}")
        seen.add(identifier)
        typed_rows.append(row)
    return typed_rows


def _flatten_references(
    method_rows: object,
    reference_field: str,
) -> list[dict[str, object]]:
    if not isinstance(method_rows, list):
        raise ValueError("coverage methodCoverage must be an array")
    flattened: list[dict[str, object]] = []
    for method_row in method_rows:
        if not isinstance(method_row, dict):
            raise ValueError("coverage method row must be an object")
        method = method_row.get("method")
        references = method_row.get(reference_field)
        if not isinstance(method, str) or not method:
            raise ValueError("coverage method must be a string")
        if not isinstance(references, list):
            raise ValueError(f"coverage {reference_field} must be an array")
        for reference in references:
            if not isinstance(reference, dict):
                raise ValueError("coverage reference must be an object")
            file = reference.get("file")
            line = reference.get("line")
            if not isinstance(file, str) or not file:
                raise ValueError("coverage reference file must be a string")
            if not isinstance(line, int) or isinstance(line, bool) or line < 1:
                raise ValueError("coverage reference line must be positive")
            flattened.append({"method": method, "file": file, "line": line})
    return sorted(
        flattened,
        key=lambda row: (str(row["method"]), str(row["file"]), int(row["line"])),
    )


def _static_protocol_evidence(coverage_row: dict[str, Any]) -> dict[str, object]:
    methods = coverage_row.get("protocolMethods")
    if not isinstance(methods, list) or not all(
        isinstance(method, str) and method for method in methods
    ):
        raise ValueError("coverage protocolMethods must be strings")
    method_rows = coverage_row.get("methodCoverage")
    return {
        "classification": MERGEABLE_CLASSIFICATION,
        "protocolMethods": sorted(set(methods)),
        "productionReferences": _flatten_references(
            method_rows, "productionReferences"
        ),
        "testReferences": _flatten_references(method_rows, "testReferences"),
    }


def merge_feature_coverage_evidence(
    *,
    inventory: dict[str, Any],
    coverage: dict[str, Any],
) -> dict[str, Any]:
    if inventory.get("version") != coverage.get("version"):
        raise ValueError("coverage version does not match inventory")
    inventory_rows = _feature_rows(inventory, label="inventory")
    coverage_rows = _feature_rows(coverage, label="coverage")
    inventory_ids = {str(row["id"]) for row in inventory_rows}
    coverage_by_id = {str(row["id"]): row for row in coverage_rows}
    if inventory_ids != set(coverage_by_id):
        raise ValueError("coverage feature ids do not match inventory feature ids")

    output = copy.deepcopy(inventory)
    merged = 0
    for feature in output["features"]:
        coverage_row = coverage_by_id[str(feature["id"])]
        classification = coverage_row.get("classification")
        status = feature.get("status")
        if status == "matched":
            continue
        if classification == MERGEABLE_CLASSIFICATION:
            feature["status"] = STATIC_IMPLEMENTATION_STATUS
            feature["staticProtocolEvidence"] = _static_protocol_evidence(
                coverage_row
            )
            merged += 1
        elif status == STATIC_IMPLEMENTATION_STATUS:
            feature["status"] = "unknown"
            feature.pop("staticProtocolEvidence", None)

    counts = Counter(
        str(feature.get("status"))
        for feature in output["features"]
        if isinstance(feature, dict)
    )
    output["statusCounts"] = dict(sorted(counts.items()))
    output["staticEvidenceMergedCount"] = merged
    return output


def merge_feature_coverage_evidence_files(
    *,
    inventory_path: Path,
    coverage_path: Path,
    coverage_override: dict[str, Any] | None = None,
) -> dict[str, Any]:
    inventory = load_json_object(inventory_path)
    coverage = (
        coverage_override
        if coverage_override is not None
        else load_json_object(coverage_path)
    )
    inventory_sha = hashlib.sha256(inventory_path.read_bytes()).hexdigest()
    if coverage.get("inventorySha256") != inventory_sha:
        raise ValueError("coverage inventory hash does not match inventory preimage")
    result = merge_feature_coverage_evidence(
        inventory=inventory,
        coverage=coverage,
    )
    write_json_atomic(inventory_path, result)
    return result


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--inventory", type=Path, required=True)
    parser.add_argument("--coverage", type=Path, required=True)
    args = parser.parse_args()
    try:
        merge_feature_coverage_evidence_files(
            inventory_path=args.inventory,
            coverage_path=args.coverage,
        )
    except (OSError, ValueError, json.JSONDecodeError) as error:
        parser.error(str(error))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
