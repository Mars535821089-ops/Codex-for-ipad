#!/usr/bin/env python3
"""Pin the complete released Codex renderer and its Electron bridge contract."""

from __future__ import annotations

import argparse
import hashlib
from pathlib import Path
import re
import sys

if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from scripts.extract_visual_reference import RendererHtmlParser
from scripts.protocol_manifest import sha256_file, write_json_atomic


REQUIRED_BRIDGE_MEMBERS = (
    "windowType",
    "getPreloadStartedAtMs",
    "sendMessageFromView",
    "getPathForFile",
    "startFileDrag",
    "sendWorkerMessageFromView",
    "subscribeToWorkerMessages",
    "showContextMenu",
    "getFastModeRolloutMetrics",
    "getSharedObjectSnapshotValue",
    "getInitialSidebarBootstrap",
    "getSystemThemeVariant",
    "subscribeToSystemThemeVariant",
    "triggerSentryTestError",
    "getSentryInitOptions",
    "getAppSessionId",
    "getBuildFlavor",
    "isDeviceCheckSupported",
    "isIntelMacBuild",
    "usesOwlAppShell",
)

VERSION_PATTERN = re.compile(r"^[0-9]+(?:\.[0-9]+)+$")
BUILD_PATTERN = re.compile(r"^[1-9][0-9]*$")


def _resource_tree(root: Path) -> tuple[int, int, str]:
    count = 0
    total_bytes = 0
    digest = hashlib.sha256()
    for path in sorted(item for item in root.rglob("*") if item.is_file()):
        relative = path.relative_to(root).as_posix()
        size = path.stat().st_size
        file_digest = sha256_file(path)
        digest.update(relative.encode("utf-8"))
        digest.update(b"\0")
        digest.update(str(size).encode("ascii"))
        digest.update(b"\0")
        digest.update(file_digest.encode("ascii"))
        digest.update(b"\n")
        count += 1
        total_bytes += size
    return count, total_bytes, digest.hexdigest()


def _entry_contract(webview_root: Path) -> dict[str, object]:
    entry = webview_root / "index.html"
    if not entry.is_file():
        raise ValueError("renderer index.html is missing")
    parser = RendererHtmlParser()
    parser.feed(entry.read_text(encoding="utf-8"))
    module_entries = sorted(set(parser.module_entries))
    stylesheets = sorted(set(parser.stylesheets))
    module_preloads = sorted(set(parser.preloads))
    if parser.title_parts and "".join(parser.title_parts).strip() != "Codex":
        raise ValueError("renderer title is not Codex")
    if not module_entries:
        raise ValueError("renderer has no module entry")
    for relative in module_entries + stylesheets + module_preloads:
        if not (webview_root / relative).is_file():
            raise ValueError(f"renderer dependency is missing: {relative}")
    return {
        "path": "index.html",
        "sha256": sha256_file(entry),
        "title": "".join(parser.title_parts).strip(),
        "moduleEntries": module_entries,
        "stylesheets": stylesheets,
        "modulePreloads": module_preloads,
    }


def _critical_files(
    webview_root: Path,
    entry: dict[str, object],
) -> list[dict[str, object]]:
    roles = [("entry", str(entry["path"]))]
    roles.extend(
        ("module-entry", str(path)) for path in entry["moduleEntries"]
    )
    roles.extend(
        ("stylesheet", str(path)) for path in entry["stylesheets"]
    )
    roles.extend(
        ("module-preload", str(path)) for path in entry["modulePreloads"]
    )
    rows = []
    for role, relative in roles:
        path = webview_root / relative
        rows.append(
            {
                "role": role,
                "path": relative,
                "bytes": path.stat().st_size,
                "sha256": sha256_file(path),
            }
        )
    return rows


def _bridge_members(preload_text: str) -> list[str]:
    return [
        member
        for member in REQUIRED_BRIDGE_MEMBERS
        if re.search(rf"\b{re.escape(member)}\b", preload_text)
    ]


def build_desktop_surface_manifest(
    webview_root: Path,
    preload_path: Path,
    *,
    desktop_version: str,
    desktop_build: str,
) -> dict[str, object]:
    if VERSION_PATTERN.fullmatch(desktop_version) is None:
        raise ValueError("desktop version is malformed")
    if BUILD_PATTERN.fullmatch(desktop_build) is None:
        raise ValueError("desktop build is malformed")
    webview_root = webview_root.resolve()
    preload_path = preload_path.resolve()
    if not webview_root.is_dir():
        raise ValueError("renderer root is missing")
    if not preload_path.is_file():
        raise ValueError("Electron preload contract is missing")

    preload_text = preload_path.read_text(encoding="utf-8", errors="replace")
    bridge_members = _bridge_members(preload_text)
    missing_members = sorted(set(REQUIRED_BRIDGE_MEMBERS) - set(bridge_members))
    if missing_members:
        raise ValueError(
            "Electron preload bridge members are missing: "
            + ", ".join(missing_members)
        )

    entry = _entry_contract(webview_root)
    file_count, total_bytes, tree_hash = _resource_tree(webview_root)
    return {
        "schemaVersion": 1,
        "desktopVersion": desktop_version,
        "desktopBuild": desktop_build,
        "productName": "Codex",
        "ipadProductName": "Codex for ipad",
        "bridgeProtocolVersion": 1,
        "resourceDirectoryName": "CodexDesktopSurface",
        "resourceFileCount": file_count,
        "resourceTotalBytes": total_bytes,
        "resourceTreeSha256": tree_hash,
        "entry": entry,
        "criticalFiles": _critical_files(webview_root, entry),
        "preloadProtocol": {
            "sha256": sha256_file(preload_path),
            "bridgeMembers": bridge_members,
            "viewToHostEvent": "codex-message-from-view",
            "hostToViewEvent": "message",
            "hostRPCScheme": "vscode://codex/",
            "readyMessageType": "ready",
        },
    }


def verify_desktop_surface_manifest(
    manifest: dict[str, object],
    webview_root: Path,
    preload_path: Path,
) -> list[str]:
    blockers: list[str] = []
    try:
        count, total_bytes, tree_hash = _resource_tree(webview_root)
    except OSError:
        return ["renderer root is unreadable"]
    if count != manifest.get("resourceFileCount"):
        blockers.append("resource file count mismatch")
    if total_bytes != manifest.get("resourceTotalBytes"):
        blockers.append("resource byte count mismatch")
    if tree_hash != manifest.get("resourceTreeSha256"):
        blockers.append("resource tree hash mismatch")
    if not preload_path.is_file():
        blockers.append("Electron preload contract is missing")
    elif (
        sha256_file(preload_path)
        != manifest.get("preloadProtocol", {}).get("sha256")
    ):
        blockers.append("Electron preload hash mismatch")
    for row in manifest.get("criticalFiles", []):
        if not isinstance(row, dict) or not isinstance(row.get("path"), str):
            blockers.append("critical file record is malformed")
            continue
        path = webview_root / row["path"]
        if not path.is_file():
            blockers.append(f"critical file is missing: {row['path']}")
        elif sha256_file(path) != row.get("sha256"):
            blockers.append(f"critical file hash mismatch: {row['path']}")
    return blockers


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--webview-root", type=Path, required=True)
    parser.add_argument("--preload", type=Path, required=True)
    parser.add_argument("--desktop-version", required=True)
    parser.add_argument("--desktop-build", required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    write_json_atomic(
        args.output,
        build_desktop_surface_manifest(
            args.webview_root,
            args.preload,
            desktop_version=args.desktop_version,
            desktop_build=args.desktop_build,
        ),
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
