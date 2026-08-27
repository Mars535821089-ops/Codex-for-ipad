#!/usr/bin/env python3
"""Fail unless every measured Codex feature has matched iPad evidence."""

from __future__ import annotations

import argparse
from pathlib import Path
import sys

if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from scripts.protocol_manifest import load_json_object


def check_parity(feature_inventory: dict) -> list[dict[str, str]]:
    features = feature_inventory.get("features")
    if not isinstance(features, list):
        raise ValueError("feature inventory has no features array")
    blockers: list[dict[str, str]] = []
    for feature in features:
        if not isinstance(feature, dict):
            raise ValueError("feature row must be an object")
        identifier = feature.get("id")
        status = feature.get("status")
        if not isinstance(identifier, str) or not isinstance(status, str):
            raise ValueError("feature row requires string id and status")
        if status != "matched":
            blockers.append({"id": identifier, "status": status})
    return blockers


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("inventory", type=Path)
    args = parser.parse_args()
    blockers = check_parity(load_json_object(args.inventory))
    if blockers:
        print(f"parity blockers: {len(blockers)}")
        for blocker in blockers:
            print(f"{blocker['status']}\t{blocker['id']}")
        return 2
    print("parity gate: matched")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
