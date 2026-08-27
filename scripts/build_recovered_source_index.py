#!/usr/bin/env python3
"""Index the recovered Electron source tree without executing bundle code."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
from collections import Counter
from pathlib import Path


SOURCE_SUFFIXES = {".cjs", ".css", ".html", ".js", ".json", ".mjs"}
DEPENDENCY_PATTERN = re.compile(
    r"""(?:from\s*|import\s*\(|require\s*\()\s*["'`](\.[^"'`]+)["'`]"""
)
ASSET_REFERENCE_PATTERN = re.compile(
    r"""["'`](\./[^"'`]+\.(?:css|html|js|json|mjs|wasm))["'`]"""
)
PATH_LITERAL_PATTERN = re.compile(r"""["'`](/[A-Za-z][^"'`\s]*)["'`]""")
MESSAGE_PATTERN = re.compile(
    r"""id:\s*["'`]([^"'`]+)["'`]\s*,\s*defaultMessage:\s*["'`]([^"'`]*)["'`]""",
    re.DOTALL,
)

CATEGORY_KEYWORDS = {
    "account-auth": ("account", "auth", "login", "profile"),
    "apps-plugins-skills": ("appgen", "mcp", "plugin", "skill"),
    "browser-computer-use": ("browser", "computer-use", "remote-control"),
    "conversation-thread": ("composer", "conversation", "message", "thread", "turn"),
    "diff-review-git": ("diff", "git", "review", "worktree"),
    "environment-project": ("environment", "project", "workspace"),
    "model-usage": ("model", "rate-limit", "usage"),
    "settings": ("preference", "setting"),
    "terminal-tools": ("command", "terminal", "tool"),
    "voice-realtime": ("audio", "realtime", "voice"),
}
UI_ROUTE_PREFIXES = (
    "/automations",
    "/avatar-overlay",
    "/codex-access",
    "/codex-mobile",
    "/first-run",
    "/global/search",
    "/hotkey-window",
    "/local",
    "/mcp-app",
    "/new-thread",
    "/plugins",
    "/settings",
)


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def categories_for(path: str) -> list[str]:
    lowered = path.lower()
    return sorted(
        category
        for category, keywords in CATEGORY_KEYWORDS.items()
        if any(keyword in lowered for keyword in keywords)
    )


def index_source_tree(root: Path) -> dict[str, object]:
    modules: list[dict[str, object]] = []
    category_counts: Counter[str] = Counter()
    string_paths: set[str] = set()
    ui_route_candidates: set[str] = set()
    messages: dict[str, str] = {}

    for path in sorted(root.rglob("*")):
        if not path.is_file() or path.suffix.lower() not in SOURCE_SUFFIXES:
            continue
        relative = path.relative_to(root).as_posix()
        text = path.read_text(encoding="utf-8", errors="replace")
        dependencies = sorted(
            set(DEPENDENCY_PATTERN.findall(text))
            | set(ASSET_REFERENCE_PATTERN.findall(text))
        )
        module_paths = sorted(set(PATH_LITERAL_PATTERN.findall(text)))
        module_messages = [
            {"id": message_id, "defaultMessage": default_message}
            for message_id, default_message in MESSAGE_PATTERN.findall(text)
        ]
        module_categories = categories_for(relative)
        category_counts.update(module_categories)
        string_paths.update(module_paths)
        ui_route_candidates.update(
            path
            for path in module_paths
            if path.startswith(UI_ROUTE_PREFIXES)
        )
        for message in module_messages:
            messages.setdefault(message["id"], message["defaultMessage"])
        modules.append(
            {
                "path": relative,
                "bytes": path.stat().st_size,
                "lines": text.count("\n") + (0 if text.endswith("\n") else 1),
                "sha256": sha256(path),
                "categories": module_categories,
                "dependencies": dependencies,
                "stringPaths": module_paths,
                "messages": module_messages,
            }
        )

    return {
        "schemaVersion": 1,
        "moduleCount": len(modules),
        "dependencyEdgeCount": sum(len(row["dependencies"]) for row in modules),
        "stringPathCount": len(string_paths),
        "uiRouteCandidateCount": len(ui_route_candidates),
        "messageCount": len(messages),
        "categoryCounts": dict(sorted(category_counts.items())),
        "stringPaths": sorted(string_paths),
        "uiRouteCandidates": sorted(ui_route_candidates),
        "messages": [
            {"id": key, "defaultMessage": messages[key]}
            for key in sorted(messages)
        ],
        "modules": modules,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source-root", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    index = index_source_tree(args.source_root)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(
        json.dumps(index, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    print(
        json.dumps(
            {
                "moduleCount": index["moduleCount"],
                "dependencyEdgeCount": index["dependencyEdgeCount"],
                "stringPathCount": index["stringPathCount"],
                "uiRouteCandidateCount": index["uiRouteCandidateCount"],
                "messageCount": index["messageCount"],
                "categoryCounts": index["categoryCounts"],
            },
            ensure_ascii=False,
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
