#!/usr/bin/env python3
"""Canonical route/state pairing for desktop and physical-iPad captures."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import sys
import tempfile
from typing import Any

if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from scripts.build_desktop_ui_parity import SURFACE_DEFINITIONS


STATE_ROUTE_OVERRIDES = {
    "S01": {
        "launch": "/login",
        "signed-out": "/login",
        "device-code": "/login",
        "api-key-expanded": "/login",
        "project-selection": "/select-workspace",
        "first-run": "/first-run",
        "error": "/login",
    },
    "S02": {state: "/" for state in (
        "sidebar-expanded", "sidebar-collapsed", "filter-all", "filter-chat",
        "filter-work", "pinned", "unread", "loading",
    )},
    "S03": {
        "home-chat": "/",
        "home-codex": "/",
        "home-work": "/",
        "temporary-chat": "/extension/panel/new",
        "projects-empty": "/projects",
        "projects-populated": "/projects",
        "projects-search": "/projects",
    },
    "S04": {state: "/local/:conversationId" for state in (
        "empty-composer", "streaming", "working", "queued", "steered",
        "approval", "subagents-active", "subagents-done", "reconnecting",
        "error",
    )},
    "S05": {state: "/local/:conversationId" for state in (
        "files", "side-chat", "browser", "review", "detail",
        "terminal-bottom", "terminal-right", "panel-resize", "panel-collapsed",
    )},
    "S06": {state: "/diff" for state in (
        "unified", "split", "staged", "unstaged", "last-turn", "comments",
        "conflict", "revert-confirmation", "commit", "empty", "error",
    )},
    "S07": {state: "/local/:conversationId" for state in (
        "created", "input", "output", "resized", "reconnecting", "exited",
        "workspace-mismatch",
    )},
    "S08": {
        "search": "/settings",
        "search-empty": "/settings",
        "personal": "/settings/profile",
        "integrations": "/settings/connections",
        "coding": "/settings/agent",
        "archived": "/settings/data-controls",
        "managed": "/settings/general-settings",
        "read-only": "/settings/general-settings",
        "shortcut-conflict": "/settings/keyboard-shortcuts",
        "shortcut-override": "/settings/keyboard-shortcuts",
    },
    "S09": {},
    "S10": {},
}

# Some states intentionally render the same surface (for example the initial
# signed-out route).  Keep this explicit so duplicate-image validation remains
# strict for every non-declared pair.
VISUAL_ALIASES = {
    ("S01", "01__signed-out"): ["S01", "00__launch"],
}

# These are physical-iPad acceptance observations, not screenshot captures.
# The corresponding desktop Settings routes are intentionally not exposed in
# the iPad sidebar; S09 exercises the product routes independently.
ACCEPTED_NON_CAPTURE_MARKERS = (
    "S08|15__search|/settings/mcp-settings|not-exposed-on-ipad-sidebar",
    "S08|17__search|/settings/skills-settings|not-exposed-on-ipad-sidebar",
)


def capture_specs() -> tuple[dict[str, Any], ...]:
    specs: list[dict[str, Any]] = []
    for definition in SURFACE_DEFINITIONS:
        routes = definition["routes"]
        states = definition["requiredStates"]
        overrides = STATE_ROUTE_OVERRIDES[definition["id"]]
        pairs: list[tuple[str, str]] = []
        for index, state in enumerate(states):
            route = overrides.get(state, routes[index % len(routes)])
            pairs.append((route, state))
        covered_routes = {route for route, _ in pairs}
        for route in routes:
            if route in covered_routes:
                continue
            state = next(
                candidate
                for candidate in states
                if (route, candidate) not in pairs
            )
            pairs.append((route, state))
        for index, (route, state) in enumerate(pairs):
            specs.append({
                "surfaceId": definition["id"],
                "captureKey": f"{index:02d}__{state}",
                "route": route,
                "state": state,
                **(
                    {"visualAliasOf": VISUAL_ALIASES[(definition["id"], f"{index:02d}__{state}")]}
                    if (definition["id"], f"{index:02d}__{state}") in VISUAL_ALIASES
                    else {}
                ),
            })
    return tuple(specs)


def capture_specs_by_surface() -> dict[str, tuple[dict[str, Any], ...]]:
    grouped: dict[str, list[dict[str, Any]]] = {
        definition["id"]: [] for definition in SURFACE_DEFINITIONS
    }
    for spec in capture_specs():
        grouped[spec["surfaceId"]].append(spec)
    return {surface_id: tuple(rows) for surface_id, rows in grouped.items()}


def write_capture_plan(output: Path) -> Path:
    output = output.resolve()
    output.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(
        prefix=f".{output.name}.", suffix=".tmp", dir=output.parent
    )
    temporary_path = Path(temporary)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            json.dump(
                {
                    "schemaVersion": 1,
                    "captures": list(capture_specs()),
                    "acceptedNonCaptureMarkers": list(ACCEPTED_NON_CAPTURE_MARKERS),
                },
                handle,
                ensure_ascii=False,
                indent=2,
            )
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary_path, output)
    finally:
        if temporary_path.exists():
            temporary_path.unlink()
    return output


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    print(write_capture_plan(args.output))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
