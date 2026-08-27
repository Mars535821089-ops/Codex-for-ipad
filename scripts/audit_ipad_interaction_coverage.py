#!/usr/bin/env python3
"""Audit physical-iPad interaction-state coverage without launching desktop Codex.

The desktop interaction inventory is the authoritative list of surfaces and
required states.  The XCTest source is only considered covered when it emits
the exact ``surface|captureKey|route|state`` acceptance marker.  This report is
deliberately conservative: static source presence is not runtime success.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path
from typing import Any


MARKER = re.compile(r'"(S\d{2}\|[^"\n]+\|[^"\n]+\|[^"\n]+)"')


def load_json(path: Path) -> dict[str, Any]:
    value = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise ValueError(f"expected JSON object: {path}")
    return value


def audit(inventory: dict[str, Any], plan: dict[str, Any], ui_test: str) -> dict[str, Any]:
    expected = {
        f"{row['surfaceId']}|{row['captureKey']}|{row['route']}|{row['state']}"
        for row in plan.get("captures", [])
    }
    emitted = set(MARKER.findall(ui_test))
    accepted_non_capture = set(plan.get("acceptedNonCaptureMarkers", []))
    covered = sorted(expected & emitted)
    missing = sorted(expected - emitted)
    unexpected = sorted(emitted - expected - accepted_non_capture)
    interactions = sum(
        int(surface.get("interactionCount", 0))
        for surface in inventory.get("surfaces", [])
    )
    return {
        "schemaVersion": 1,
        "desktopVersion": inventory.get("desktopVersion"),
        "desktopBuild": inventory.get("desktopBuild"),
        "source": {
            "interactionInventory": inventory.get("sourceIdentity"),
            "capturePlanSchemaVersion": plan.get("schemaVersion"),
        },
        "staticEvidenceOnly": True,
        "interactionCount": interactions,
        "requiredCaptureCount": len(expected),
        "emittedAcceptanceMarkerCount": len(emitted),
        "coveredCaptureCount": len(covered),
        "missingCaptureCount": len(missing),
        "unexpectedMarkerCount": len(unexpected),
        "acceptedNonCaptureMarkerCount": len(emitted & accepted_non_capture),
        "acceptedNonCaptureMarkers": sorted(emitted & accepted_non_capture),
        "coveragePercent": round((len(covered) / len(expected) * 100) if expected else 100.0, 2),
        "covered": covered,
        "missing": missing,
        "unexpected": unexpected,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--inventory", type=Path, required=True)
    parser.add_argument("--capture-plan", type=Path, required=True)
    parser.add_argument("--ui-test", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--require-complete", action="store_true")
    args = parser.parse_args()

    report = audit(
        load_json(args.inventory),
        load_json(args.capture_plan),
        args.ui_test.read_text(encoding="utf-8"),
    )
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(args.output)
    print(
        f"coverage={report['coveragePercent']:.2f}% "
        f"covered={report['coveredCaptureCount']}/{report['requiredCaptureCount']} "
        f"interactions={report['interactionCount']}"
    )
    if args.require_complete and (
        report["coveredCaptureCount"] != report["requiredCaptureCount"]
        or report["missingCaptureCount"] != 0
        or report["unexpectedMarkerCount"] != 0
    ):
        print(
            "static interaction coverage is incomplete: "
            f"missing={report['missingCaptureCount']} "
            f"unexpected={report['unexpectedMarkerCount']}",
            file=sys.stderr,
        )
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
