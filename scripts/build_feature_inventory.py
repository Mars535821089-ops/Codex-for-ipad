#!/usr/bin/env python3
"""Build the initial explicit Codex feature-parity matrix."""

from __future__ import annotations

import argparse
from collections import Counter
import re
from pathlib import Path
import sys

if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from scripts.protocol_manifest import load_json_object, write_json_atomic


CATEGORY_PREFIXES = (
    ("RemoteControl", "remote-control"),
    ("Environment", "environment"),
    ("Workspace", "workspace"),
    ("Account", "account"),
    ("Process", "process"),
    ("Plugin", "plugin"),
    ("Config", "config"),
    ("Review", "review"),
    ("Skills", "skills"),
    ("Thread", "thread"),
    ("Model", "model"),
    ("Apps", "apps"),
    ("Turn", "turn"),
    ("Mcp", "mcp"),
    ("Fs", "fs"),
)
V2_SCHEMA = re.compile(
    r"^json-schema/(stable|experimental)/v2/([A-Za-z0-9]+)\.json$"
)


def pascal_to_kebab(value: str) -> str:
    first = re.sub(r"([a-z0-9])([A-Z])", r"\1-\2", value)
    second = re.sub(r"([A-Z]+)([A-Z][a-z])", r"\1-\2", first)
    return second.lower()


def _category(name: str):
    for prefix, category in CATEGORY_PREFIXES:
        if name.startswith(prefix):
            remainder = name[len(prefix) :]
            return category, remainder or prefix
    return None


def build_feature_inventory(
    version: str,
    protocol_index: dict,
    ipc_inventory: dict,
    visual_inventory: dict,
) -> dict[str, object]:
    grouped: dict[str, dict[str, object]] = {}
    for entry in protocol_index.get("files", []):
        if not isinstance(entry, dict):
            continue
        path = entry.get("path")
        if not isinstance(path, str):
            continue
        match = V2_SCHEMA.fullmatch(path)
        if not match:
            continue
        channel, schema_name = match.groups()
        classified = _category(schema_name)
        if classified is None:
            continue
        category, remainder = classified
        feature_id = f"{category}.{pascal_to_kebab(remainder)}"
        feature = grouped.setdefault(
            feature_id,
            {
                "id": feature_id,
                "name": schema_name,
                "category": category,
                "desktopEvidence": [],
                "protocolDependencies": [],
                "ipcDependencies": [],
                "ipadModule": None,
                "automatedTests": [],
                "simulatorEvidence": [],
                "deviceEvidence": [],
                "visualEvidence": [],
                "status": "unknown",
            },
        )
        evidence = {
            "evidenceKind": "protocol-schema",
            "channel": channel,
            "file": path,
            "fileSha256": entry.get("sha256"),
        }
        if evidence not in feature["desktopEvidence"]:
            feature["desktopEvidence"].append(evidence)
        if path not in feature["protocolDependencies"]:
            feature["protocolDependencies"].append(path)

    ipc_channels = [
        item.get("channel")
        for item in ipc_inventory.get("channels", [])
        if isinstance(item, dict) and isinstance(item.get("channel"), str)
    ]
    for feature in grouped.values():
        category_key = str(feature["category"]).replace("-", "")
        matches = []
        for channel in ipc_channels:
            normalized = re.sub(r"[^a-z0-9]", "", channel.lower())
            if category_key in normalized:
                matches.append(channel)
        feature["ipcDependencies"] = sorted(set(matches))
        feature["desktopEvidence"].sort(
            key=lambda item: (item["file"], item["channel"])
        )
        feature["protocolDependencies"].sort()

    features = [grouped[key] for key in sorted(grouped)]
    counts = Counter(str(item["category"]) for item in features)
    return {
        "schemaVersion": 1,
        "version": version,
        "sourceSummary": {
            "protocolFileCount": protocol_index.get("fileCount"),
            "ipcChannelCount": ipc_inventory.get("channelCount"),
            "visualResourceCount": visual_inventory.get("resourceCount"),
        },
        "featureCount": len(features),
        "categoryCounts": dict(sorted(counts.items())),
        "statusCounts": {"unknown": len(features)},
        "features": features,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--version", required=True)
    parser.add_argument("--protocol-index", type=Path, required=True)
    parser.add_argument("--ipc-inventory", type=Path, required=True)
    parser.add_argument("--visual-inventory", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    inventory = build_feature_inventory(
        args.version,
        load_json_object(args.protocol_index),
        load_json_object(args.ipc_inventory),
        load_json_object(args.visual_inventory),
    )
    write_json_atomic(args.output, inventory)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
