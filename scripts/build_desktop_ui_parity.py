#!/usr/bin/env python3
"""Build a truthful page, state, interaction, and visual parity contract."""

from __future__ import annotations

import argparse
from pathlib import Path
import re
import sys
from typing import Any

if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from scripts.protocol_manifest import (
    load_json_object,
    sha256_file,
    write_json_atomic,
)


SURFACE_DEFINITIONS = (
    {
        "id": "S01",
        "category": "launch-auth-onboarding",
        "name": "Launch, sign in, and first run",
        "routes": [
            "/login",
            "/welcome",
            "/select-workspace",
            "/first-run",
            "/codex-access",
        ],
        "evidenceGlobs": [
            "login-route-*.js",
            "onboarding-page-*.js",
            "select-workspace-page-*.js",
            "first-run-*.js",
        ],
        "requiredStates": [
            "launch",
            "signed-out",
            "device-code",
            "api-key-expanded",
            "project-selection",
            "first-run",
            "error",
        ],
    },
    {
        "id": "S02",
        "category": "app-shell-navigation",
        "name": "Main shell, sidebar, and top navigation",
        "routes": ["/", "/global/search"],
        "evidenceGlobs": ["app-initial-*.js"],
        "requiredStates": [
            "sidebar-expanded",
            "sidebar-collapsed",
            "filter-all",
            "filter-chat",
            "filter-work",
            "pinned",
            "unread",
            "loading",
        ],
    },
    {
        "id": "S03",
        "category": "home-projects",
        "name": "Home, new task, and projects",
        "routes": ["/", "/projects", "/extension/panel/new"],
        "evidenceGlobs": [
            "app-initial-*.js",
            "chat-home-hero-*.js",
            "home-ambient-suggestions-content-*.js",
            "projects-index-page-*.js",
        ],
        "requiredStates": [
            "home-chat",
            "home-codex",
            "home-work",
            "temporary-chat",
            "projects-empty",
            "projects-populated",
            "projects-search",
        ],
    },
    {
        "id": "S04",
        "category": "conversation-workspace",
        "name": "Conversation and task workspace",
        "routes": [
            "/local/:conversationId",
            "/work/conversation/:conversationId",
            "/remote/:taskId",
            "/chatgpt/quick-chat/:conversationId",
            "/hotkey-window/*",
        ],
        "evidenceGlobs": [
            "local-conversation-page-*.js",
            "local-conversation-thread-*.js",
            "queued-message-list-*.js",
        ],
        "requiredStates": [
            "empty-composer",
            "streaming",
            "working",
            "queued",
            "steered",
            "approval",
            "subagents-active",
            "subagents-done",
            "reconnecting",
            "error",
        ],
    },
    {
        "id": "S05",
        "category": "task-panels",
        "name": "Files, Side chat, Browser, Review, Detail, and Terminal panels",
        "routes": ["/local/:conversationId"],
        "evidenceGlobs": ["thread-app-shell-chrome-*.js"],
        "requiredStates": [
            "files",
            "side-chat",
            "browser",
            "review",
            "detail",
            "terminal-bottom",
            "terminal-right",
            "panel-resize",
            "panel-collapsed",
        ],
    },
    {
        "id": "S06",
        "category": "review-diff",
        "name": "Review and diff",
        "routes": ["/diff"],
        "evidenceGlobs": [
            "editor-diff-page-*.js",
            "app-initial-*.js",
        ],
        "requiredStates": [
            "unified",
            "split",
            "staged",
            "unstaged",
            "last-turn",
            "comments",
            "conflict",
            "revert-confirmation",
            "commit",
            "empty",
            "error",
        ],
    },
    {
        "id": "S07",
        "category": "terminal",
        "name": "Terminal",
        "routes": ["/local/:conversationId"],
        "evidenceGlobs": ["app-initial-*.js", "shellsession-*.js"],
        "requiredStates": [
            "created",
            "input",
            "output",
            "resized",
            "reconnecting",
            "exited",
            "workspace-mismatch",
        ],
    },
    {
        "id": "S08",
        "category": "settings",
        "name": "Settings and keyboard shortcuts",
        "routes": [
            "/settings",
            "/settings/general-settings",
            "/settings/profile",
            "/settings/appearance",
            "/settings/git-settings",
            "/settings/connections",
            "/settings/agent",
            "/settings/keyboard-shortcuts",
            "/settings/usage",
            "/settings/browser-use",
            "/settings/computer-use",
            "/settings/mcp-settings",
            "/settings/plugins-settings",
            "/settings/skills-settings",
            "/settings/data-controls",
        ],
        "evidenceGlobs": [
            "settings-page-*.js",
            "general-settings-*.js",
            "appearance-settings-*.js",
            "agent-settings-*.js",
            "keyboard-shortcuts-settings-*.js",
        ],
        "requiredStates": [
            "search",
            "search-empty",
            "personal",
            "integrations",
            "coding",
            "archived",
            "managed",
            "read-only",
            "shortcut-conflict",
            "shortcut-override",
        ],
    },
    {
        "id": "S09",
        "category": "secondary-products",
        "name": "Automations, pull requests, security, library, sites, plugins, and skills",
        "routes": [
            "/automations",
            "/pull-requests",
            "/security",
            "/library",
            "/sites",
            "/plugins",
            "/skills",
            "/mcp-app/:server/:toolName",
            "/codex-mobile",
            "/remote-connections",
            "/connector/oauth_callback",
        ],
        "evidenceGlobs": [
            "automations-page-*.js",
            "plugins-page-*.js",
            "skills-page-*.js",
            "security-*.js",
        ],
        "requiredStates": ["loading", "empty", "populated", "error"],
    },
    {
        "id": "S10",
        "category": "overlays-interactions-responsive",
        "name": "Global overlays, transient states, shortcuts, and iPad layout",
        "routes": ["*"],
        "evidenceGlobs": [
            "app-initial-*.js",
            "keyboard-shortcuts-settings-*.js",
        ],
        "requiredStates": [
            "command-palette",
            "file-search",
            "context-menu",
            "tooltip",
            "dropdown",
            "dialog",
            "toast",
            "hover",
            "focus",
            "pressed",
            "disabled",
            "drag",
            "resize",
            "portrait",
            "landscape",
            "stage-manager",
        ],
    },
)

REQUIRED_SHORTCUTS = (
    {"command": "New Chat", "keys": "⌘N"},
    {"command": "Command Menu", "keys": "⌘K / ⌘⇧P"},
    {"command": "Search Files", "keys": "⌘P"},
    {"command": "Settings", "keys": "⌘,"},
    {"command": "Keyboard Shortcuts", "keys": "⌘/"},
    {"command": "Sidebar", "keys": "⌘B"},
    {"command": "Bottom Panel", "keys": "⌘J"},
    {"command": "Terminal", "keys": "Ctrl+`"},
    {"command": "Browser", "keys": "⌘T"},
    {"command": "Review", "keys": "Ctrl+Shift+G"},
    {"command": "Side Chat", "keys": "⌘⌥S"},
    {"command": "Back/Forward", "keys": "⌘[ / ⌘]"},
    {"command": "Thread 1-9", "keys": "⌘1…9"},
)

VERSION_PATTERN = re.compile(r"^[0-9]+(?:\.[0-9]+)+$")
BUILD_PATTERN = re.compile(r"^[1-9][0-9]*$")
SHA256_PATTERN = re.compile(r"^[0-9a-f]{64}$")
EXPECTED_SURFACE_IDS = tuple(
    definition["id"] for definition in SURFACE_DEFINITIONS
)


def _require_sha256(value: object, label: str) -> str:
    if not isinstance(value, str) or SHA256_PATTERN.fullmatch(value) is None:
        raise ValueError(f"{label} is malformed")
    return value


def _safe_evidence_file(
    evidence_root: Path,
    raw: object,
    *,
    label: str,
) -> dict[str, str]:
    if not isinstance(raw, dict):
        raise ValueError(f"{label} evidence entry is malformed")
    relative = raw.get("path")
    expected_sha256 = _require_sha256(raw.get("sha256"), f"{label} hash")
    if not isinstance(relative, str) or not relative:
        raise ValueError(f"{label} evidence path is malformed")
    relative_path = Path(relative)
    if (
        relative_path.is_absolute()
        or ".." in relative_path.parts
        or "." in relative_path.parts
        or "\\" in relative
    ):
        raise ValueError(f"{label} evidence path escapes its root")
    evidence_root = evidence_root.resolve()
    candidate = (evidence_root / relative_path).resolve()
    try:
        candidate.relative_to(evidence_root)
    except ValueError as error:
        raise ValueError(f"{label} evidence path escapes its root") from error
    if not candidate.is_file():
        raise ValueError(f"{label} evidence file is missing")
    if sha256_file(candidate) != expected_sha256:
        raise ValueError(f"{label} evidence hash mismatch")
    return {"path": relative_path.as_posix(), "sha256": expected_sha256}


def _verified_evidence_list(
    evidence_root: Path,
    raw: object,
    *,
    label: str,
    allow_empty: bool = False,
) -> list[dict[str, str]]:
    if not isinstance(raw, list) or (not raw and not allow_empty):
        raise ValueError(f"{label} evidence list is malformed")
    return [
        _safe_evidence_file(
            evidence_root,
            entry,
            label=f"{label}[{index}]",
        )
        for index, entry in enumerate(raw)
    ]


def _surface_evidence(
    recovered_root: Path,
    patterns: list[str],
) -> tuple[str, list[dict[str, object]]]:
    asset_root = recovered_root / "webview/assets"
    rows = []
    missing = []
    for pattern in patterns:
        matches = sorted(path for path in asset_root.glob(pattern) if path.is_file())
        if not matches:
            missing.append(pattern)
            continue
        for path in matches:
            rows.append(
                {
                    "glob": pattern,
                    "file": path.relative_to(recovered_root).as_posix(),
                    "bytes": path.stat().st_size,
                    "sha256": sha256_file(path),
                }
            )
    return ("missing-reference" if missing else "reference-indexed"), rows


def _implementation_row(
    implementation_evidence: dict[str, Any] | None,
    surface_id: str,
    evidence_root: Path | None,
) -> tuple[
    str,
    list[dict[str, str]],
    list[dict[str, str]],
    list[dict[str, str]],
    list[dict[str, str]],
]:
    if not implementation_evidence:
        return "unmatched", [], [], [], []
    if evidence_root is None:
        raise ValueError(
            "evidence root is required with implementation evidence"
        )
    surfaces = implementation_evidence.get("surfaces")
    row = surfaces.get(surface_id) if isinstance(surfaces, dict) else None
    if not isinstance(row, dict):
        return "unmatched", [], [], [], []
    automated = _verified_evidence_list(
        evidence_root,
        row.get("automatedTests"),
        label=f"{surface_id} automated tests",
    )
    simulator = _verified_evidence_list(
        evidence_root,
        row.get("simulatorEvidence"),
        label=f"{surface_id} simulator",
        allow_empty=True,
    )
    device = _verified_evidence_list(
        evidence_root,
        row.get("deviceEvidence"),
        label=f"{surface_id} device",
    )
    visual = _verified_evidence_list(
        evidence_root,
        row.get("visualEvidence"),
        label=f"{surface_id} visual",
    )
    status = "matched" if row.get("status") == "matched" else "unmatched"
    return status, automated, simulator, device, visual


def _runtime_capture_row(
    capture_manifest: dict[str, Any] | None,
    definition: dict[str, Any],
    evidence_root: Path | None,
) -> tuple[str, str, dict[str, Any]]:
    surface_id = definition["id"]
    if not capture_manifest:
        return "runtime-capture-pending", "pending", {}
    if evidence_root is None:
        raise ValueError("evidence root is required with runtime captures")
    surfaces = capture_manifest.get("surfaces")
    row = surfaces.get(surface_id) if isinstance(surfaces, dict) else None
    if not isinstance(row, dict):
        return "runtime-capture-pending", "pending", {}
    inventory_status = row.get("interactionInventoryStatus")
    if inventory_status not in {"matched", "different"}:
        raise ValueError(
            f"{surface_id} interaction inventory status is malformed"
        )
    required_routes = list(definition["routes"])
    required_states = list(definition["requiredStates"])
    if row.get("requiredRoutes") != required_routes:
        raise ValueError(f"{surface_id} required routes are incomplete")
    if row.get("requiredStates") != required_states:
        raise ValueError(f"{surface_id} required states are incomplete")
    covered_routes = row.get("coveredRoutes")
    covered_states = row.get("coveredStates")
    if not isinstance(covered_routes, list) or set(covered_routes) != set(
        required_routes
    ):
        raise ValueError(f"{surface_id} required routes are incomplete")
    if not isinstance(covered_states, list) or set(covered_states) != set(
        required_states
    ):
        raise ValueError(f"{surface_id} required states are incomplete")
    raw_captures = row.get("captures")
    if not isinstance(raw_captures, list) or not raw_captures:
        raise ValueError(f"{surface_id} runtime captures are malformed")
    required_evidence = (
        "officialDesktop",
        "ipad",
        "pixelDiff",
        "captureMetadata",
    )
    captures = []
    for index, raw_capture in enumerate(raw_captures, start=1):
        if not isinstance(raw_capture, dict):
            raise ValueError(f"{surface_id} runtime captures are malformed")
        route = raw_capture.get("route")
        state = raw_capture.get("state")
        capture_inventory_status = raw_capture.get(
            "interactionInventoryStatus"
        )
        if route not in required_routes or state not in required_states:
            raise ValueError(f"{surface_id} runtime capture coverage is malformed")
        if capture_inventory_status not in {"matched", "different"}:
            raise ValueError(
                f"{surface_id} interaction inventory status is malformed"
            )
        captures.append(
            {
                "route": route,
                "state": state,
                "status": raw_capture.get("status"),
                "interactionInventoryStatus": capture_inventory_status,
                **{
                    key: _safe_evidence_file(
                        evidence_root,
                        raw_capture.get(key),
                        label=f"{surface_id} capture {index} {key}",
                    )
                    for key in required_evidence
                },
            }
        )
    if {capture["route"] for capture in captures} != set(required_routes):
        raise ValueError(f"{surface_id} required routes are incomplete")
    if {capture["state"] for capture in captures} != set(required_states):
        raise ValueError(f"{surface_id} required states are incomplete")
    evidence = {
        "requiredRoutes": required_routes,
        "requiredStates": required_states,
        "coveredRoutes": sorted(covered_routes),
        "coveredStates": sorted(covered_states),
        "captures": captures,
    }
    status = (
        "runtime-capture-matched"
        if row.get("status") == "matched"
        and inventory_status == "matched"
        and all(capture["status"] == "matched" for capture in captures)
        and all(
            capture["interactionInventoryStatus"] == "matched"
            for capture in captures
        )
        else "runtime-capture-pending"
    )
    return status, inventory_status, evidence


def _summary_for_surfaces(
    surfaces: list[dict[str, object]],
) -> dict[str, int]:
    return {
        "surfaceCount": len(surfaces),
        "referenceIndexed": sum(
            row.get("referenceStatus") == "reference-indexed"
            for row in surfaces
        ),
        "missingReference": sum(
            row.get("referenceStatus") == "missing-reference"
            for row in surfaces
        ),
        "implementationMatched": sum(
            row.get("implementationStatus") == "matched"
            for row in surfaces
        ),
        "implementationUnmatched": sum(
            row.get("implementationStatus") != "matched"
            for row in surfaces
        ),
        "runtimeCaptureMatched": sum(
            row.get("runtimeCaptureStatus") == "runtime-capture-matched"
            for row in surfaces
        ),
        "runtimeCapturePending": sum(
            row.get("runtimeCaptureStatus") != "runtime-capture-matched"
            for row in surfaces
        ),
        "interactionInventoryMatched": sum(
            row.get("interactionInventoryStatus") == "matched"
            for row in surfaces
        ),
        "interactionInventoryDifferent": sum(
            row.get("interactionInventoryStatus") == "different"
            for row in surfaces
        ),
        "interactionInventoryPending": sum(
            row.get("interactionInventoryStatus") == "pending"
            for row in surfaces
        ),
    }


def build_desktop_ui_parity(
    recovered_root: Path,
    *,
    desktop_version: str,
    desktop_build: str,
    source_dmg_sha256: str,
    desktop_surface_tree_sha256: str,
    recovered_source_index_sha256: str,
    implementation_evidence: dict[str, Any] | None = None,
    capture_manifest: dict[str, Any] | None = None,
    evidence_root: Path | None = None,
) -> dict[str, object]:
    if VERSION_PATTERN.fullmatch(desktop_version) is None:
        raise ValueError("desktop version is malformed")
    if BUILD_PATTERN.fullmatch(desktop_build) is None:
        raise ValueError("desktop build is malformed")
    source_dmg_sha256 = _require_sha256(
        source_dmg_sha256,
        "source DMG hash",
    )
    desktop_surface_tree_sha256 = _require_sha256(
        desktop_surface_tree_sha256,
        "desktop surface tree hash",
    )
    recovered_source_index_sha256 = _require_sha256(
        recovered_source_index_sha256,
        "recovered source index hash",
    )
    recovered_root = recovered_root.resolve()
    if evidence_root is not None:
        evidence_root = evidence_root.resolve()

    surfaces = []
    for definition in SURFACE_DEFINITIONS:
        reference_status, desktop_evidence = _surface_evidence(
            recovered_root,
            list(definition["evidenceGlobs"]),
        )
        (
            implementation_status,
            automated_tests,
            simulator_evidence,
            device_evidence,
            visual_evidence,
        ) = _implementation_row(
            implementation_evidence,
            definition["id"],
            evidence_root,
        )
        (
            capture_status,
            interaction_inventory_status,
            capture_evidence,
        ) = _runtime_capture_row(
            capture_manifest,
            definition,
            evidence_root,
        )
        surfaces.append(
            {
                "id": definition["id"],
                "category": definition["category"],
                "name": definition["name"],
                "routes": list(definition["routes"]),
                "requiredStates": list(definition["requiredStates"]),
                "referenceStatus": reference_status,
                "desktopEvidence": desktop_evidence,
                "implementationStatus": implementation_status,
                "automatedTests": automated_tests,
                "simulatorEvidence": simulator_evidence,
                "deviceEvidence": device_evidence,
                "visualEvidence": visual_evidence,
                "runtimeCaptureStatus": capture_status,
                "interactionInventoryStatus": interaction_inventory_status,
                "runtimeCaptureEvidence": capture_evidence,
            }
        )

    return {
        "schemaVersion": 3,
        "desktopVersion": desktop_version,
        "desktopBuild": desktop_build,
        "sourceIdentity": {
            "dmgSha256": source_dmg_sha256,
            "desktopSurfaceTreeSha256": desktop_surface_tree_sha256,
            "recoveredSourceIndexSha256": recovered_source_index_sha256,
        },
        "target": "desktop-identical-ipad-surface",
        "acceptanceDimensions": [
            "interface",
            "sections",
            "functions",
            "styles",
            "states",
            "interactions",
            "control-inventory",
            "shortcuts",
            "localization",
            "responsive-layout",
        ],
        "visualContract": {
            "source": "visual/reference-inventory.json",
            "requiredComparison": "same-state official desktop / iPad / pixel diff",
            "status": (
                "matched"
                if all(
                    row["runtimeCaptureStatus"]
                    == "runtime-capture-matched"
                    for row in surfaces
                )
                else "runtime-capture-pending"
            ),
        },
        "requiredShortcuts": list(REQUIRED_SHORTCUTS),
        "summary": _summary_for_surfaces(surfaces),
        "surfaces": surfaces,
    }


def _validate_runtime_capture_evidence(
    row: dict[str, object],
) -> None:
    surface_id = row.get("id")
    evidence = row.get("runtimeCaptureEvidence")
    if not isinstance(evidence, dict) or set(evidence) != {
        "requiredRoutes",
        "requiredStates",
        "coveredRoutes",
        "coveredStates",
        "captures",
    }:
        raise ValueError(
            "desktop UI parity runtime capture evidence is malformed"
        )
    routes = row.get("routes")
    states = row.get("requiredStates")
    if (
        not isinstance(routes, list)
        or not isinstance(states, list)
        or evidence.get("requiredRoutes") != routes
        or evidence.get("requiredStates") != states
        or set(evidence.get("coveredRoutes", [])) != set(routes)
        or set(evidence.get("coveredStates", [])) != set(states)
    ):
        raise ValueError(f"{surface_id} runtime capture coverage is malformed")
    captures = evidence.get("captures")
    if not isinstance(captures, list) or not captures:
        raise ValueError(
            "desktop UI parity runtime capture evidence is malformed"
        )
    required_evidence = {
        "officialDesktop",
        "ipad",
        "pixelDiff",
        "captureMetadata",
    }
    for capture in captures:
        if (
            not isinstance(capture, dict)
            or capture.get("route") not in routes
            or capture.get("state") not in states
            or capture.get("status")
            not in {"matched", "interaction-inventory-different"}
            or capture.get("interactionInventoryStatus")
            not in {"matched", "different"}
        ):
            raise ValueError(
                "desktop UI parity runtime capture evidence is malformed"
            )
        for key in required_evidence:
            entry = capture.get(key)
            if (
                not isinstance(entry, dict)
                or not isinstance(entry.get("path"), str)
                or not entry["path"]
                or not isinstance(entry.get("sha256"), str)
                or SHA256_PATTERN.fullmatch(entry["sha256"]) is None
            ):
                raise ValueError(
                    "desktop UI parity runtime capture evidence is malformed"
                )
    if {capture["route"] for capture in captures} != set(routes):
        raise ValueError(f"{surface_id} required routes are incomplete")
    if {capture["state"] for capture in captures} != set(states):
        raise ValueError(f"{surface_id} required states are incomplete")


def desktop_ui_parity_blockers(
    contract: dict[str, object],
) -> list[dict[str, str]]:
    blockers = []
    if contract.get("schemaVersion") != 3:
        raise ValueError("desktop UI parity schema version is malformed")
    source_identity = contract.get("sourceIdentity")
    if not isinstance(source_identity, dict):
        raise ValueError("desktop UI parity source identity is missing")
    for key in (
        "dmgSha256",
        "desktopSurfaceTreeSha256",
        "recoveredSourceIndexSha256",
    ):
        _require_sha256(
            source_identity.get(key),
            f"desktop UI parity source identity {key}",
        )
    surfaces = contract.get("surfaces")
    if not isinstance(surfaces, list):
        raise ValueError("desktop UI parity contract has no surfaces")
    ids = [
        row.get("id") if isinstance(row, dict) else None
        for row in surfaces
    ]
    if ids != list(EXPECTED_SURFACE_IDS):
        raise ValueError(
            "desktop UI parity surfaces must be exactly S01 through S10"
        )
    typed_surfaces = [
        row for row in surfaces if isinstance(row, dict)
    ]
    if contract.get("summary") != _summary_for_surfaces(typed_surfaces):
        raise ValueError("desktop UI parity summary does not match surfaces")
    expected_visual_status = (
        "matched"
        if all(
            row.get("runtimeCaptureStatus") == "runtime-capture-matched"
            for row in typed_surfaces
        )
        else "runtime-capture-pending"
    )
    visual_contract = contract.get("visualContract")
    if (
        not isinstance(visual_contract, dict)
        or visual_contract.get("status") != expected_visual_status
    ):
        raise ValueError("desktop UI parity visual status is inconsistent")
    for row in surfaces:
        if not isinstance(row, dict) or not isinstance(row.get("id"), str):
            raise ValueError("desktop UI parity surface is malformed")
        if row.get("referenceStatus") == "reference-indexed":
            desktop_evidence = row.get("desktopEvidence")
            if (
                not isinstance(desktop_evidence, list)
                or not desktop_evidence
                or any(
                    not isinstance(entry, dict)
                    or not isinstance(entry.get("file"), str)
                    or not entry["file"]
                    or not isinstance(entry.get("bytes"), int)
                    or entry["bytes"] < 0
                    or not isinstance(entry.get("sha256"), str)
                    or SHA256_PATTERN.fullmatch(entry["sha256"]) is None
                    for entry in desktop_evidence
                )
            ):
                raise ValueError("desktop reference evidence is malformed")
        if row.get("implementationStatus") == "matched":
            for field in (
                "automatedTests",
                "deviceEvidence",
                "visualEvidence",
            ):
                evidence = row.get(field)
                if (
                    not isinstance(evidence, list)
                    or not evidence
                    or any(
                        not isinstance(entry, dict)
                        or not isinstance(entry.get("path"), str)
                        or not entry["path"]
                        or not isinstance(entry.get("sha256"), str)
                        or SHA256_PATTERN.fullmatch(entry["sha256"]) is None
                        for entry in evidence
                    )
                ):
                    raise ValueError(
                        f"desktop UI parity {field} is malformed"
                    )
            simulator_evidence = row.get("simulatorEvidence")
            if (
                not isinstance(simulator_evidence, list)
                or any(
                    not isinstance(entry, dict)
                    or not isinstance(entry.get("path"), str)
                    or not entry["path"]
                    or not isinstance(entry.get("sha256"), str)
                    or SHA256_PATTERN.fullmatch(entry["sha256"]) is None
                    for entry in simulator_evidence
                )
            ):
                raise ValueError(
                    "desktop UI parity simulatorEvidence is malformed"
                )
        if row.get("runtimeCaptureStatus") == "runtime-capture-matched":
            _validate_runtime_capture_evidence(row)
        inventory_status = row.get("interactionInventoryStatus")
        if inventory_status not in {"matched", "different", "pending"}:
            raise ValueError(
                "desktop UI parity interaction inventory status is malformed"
            )
        if inventory_status in {"matched", "different"}:
            _validate_runtime_capture_evidence(row)
        if (
            row.get("referenceStatus") != "reference-indexed"
            or row.get("implementationStatus") != "matched"
            or row.get("runtimeCaptureStatus") != "runtime-capture-matched"
            or inventory_status != "matched"
        ):
            blockers.append(
                {
                    "id": row["id"],
                    "referenceStatus": str(row.get("referenceStatus")),
                    "implementationStatus": str(
                        row.get("implementationStatus")
                    ),
                    "runtimeCaptureStatus": str(
                        row.get("runtimeCaptureStatus")
                    ),
                    "interactionInventoryStatus": str(inventory_status),
                }
            )
    return blockers


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--recovered-root", type=Path, required=True)
    parser.add_argument("--desktop-version", required=True)
    parser.add_argument("--desktop-build", required=True)
    parser.add_argument("--source-dmg-sha256", required=True)
    parser.add_argument("--desktop-surface-tree-sha256", required=True)
    parser.add_argument("--recovered-source-index-sha256", required=True)
    parser.add_argument("--implementation-evidence", type=Path)
    parser.add_argument("--capture-manifest", type=Path)
    parser.add_argument("--evidence-root", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    implementation = (
        load_json_object(args.implementation_evidence)
        if args.implementation_evidence
        else None
    )
    captures = (
        load_json_object(args.capture_manifest)
        if args.capture_manifest
        else None
    )
    write_json_atomic(
        args.output,
        build_desktop_ui_parity(
            args.recovered_root,
            desktop_version=args.desktop_version,
            desktop_build=args.desktop_build,
            source_dmg_sha256=args.source_dmg_sha256,
            desktop_surface_tree_sha256=(
                args.desktop_surface_tree_sha256
            ),
            recovered_source_index_sha256=(
                args.recovered_source_index_sha256
            ),
            implementation_evidence=implementation,
            capture_manifest=captures,
            evidence_root=args.evidence_root,
        ),
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
