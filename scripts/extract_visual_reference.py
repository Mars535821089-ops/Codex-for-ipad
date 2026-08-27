#!/usr/bin/env python3
"""Inventory released renderer entry points, CSS tokens, and visual assets."""

from __future__ import annotations

import argparse
from collections import Counter, defaultdict
from html.parser import HTMLParser
import re
from pathlib import Path
import sys

if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from scripts.protocol_manifest import sha256_file, write_json_atomic


TOKEN_PATTERN = re.compile(
    rb"(?m)(--[a-zA-Z0-9_-]+)\s*:\s*([^;{}]+);"
)


class RendererHtmlParser(HTMLParser):
    def __init__(self):
        super().__init__()
        self.in_title = False
        self.title_parts: list[str] = []
        self.module_entries: list[str] = []
        self.stylesheets: list[str] = []
        self.preloads: list[str] = []

    @staticmethod
    def _path(value: str) -> str:
        return value[2:] if value.startswith("./") else value

    def handle_starttag(self, tag, attrs):
        attributes = dict(attrs)
        if tag == "title":
            self.in_title = True
        elif tag == "script" and attributes.get("type") == "module":
            if "src" in attributes:
                self.module_entries.append(self._path(attributes["src"]))
        elif tag == "link":
            href = attributes.get("href")
            relation = attributes.get("rel")
            if href and relation == "stylesheet":
                self.stylesheets.append(self._path(href))
            elif href and relation == "modulepreload":
                self.preloads.append(self._path(href))

    def handle_endtag(self, tag):
        if tag == "title":
            self.in_title = False

    def handle_data(self, data):
        if self.in_title:
            self.title_parts.append(data)


def classify_resource(path: Path) -> str:
    suffix = path.suffix.lower()
    if suffix in {".woff", ".woff2", ".ttf", ".otf"}:
        return "font"
    if suffix == ".svg":
        return "icon"
    if suffix in {".png", ".webp", ".jpg", ".jpeg", ".gif", ".heic"}:
        return "image"
    if suffix in {".wav", ".mp3", ".m4a", ".aac", ".flac"}:
        return "audio"
    if suffix in {".mp4", ".mov", ".m4v", ".webm"}:
        return "video"
    if suffix == ".wasm":
        return "wasm"
    if suffix in {
        ".pdf",
        ".doc",
        ".docx",
        ".xls",
        ".xlsx",
        ".ppt",
        ".pptx",
    }:
        return "document"
    return "other"


def extract_visual_reference(
    webview_root: Path, version: str
) -> dict[str, object]:
    root = webview_root.resolve()
    html_path = root / "index.html"
    if not html_path.is_file():
        raise ValueError("renderer index.html is missing")
    parser = RendererHtmlParser()
    parser.feed(html_path.read_text(encoding="utf-8"))

    tokens: list[dict[str, object]] = []
    token_values: dict[str, set[str]] = defaultdict(set)
    for css_path in sorted(root.rglob("*.css")):
        relative = css_path.relative_to(root).as_posix()
        digest = sha256_file(css_path)
        source = css_path.read_bytes()
        for match in TOKEN_PATTERN.finditer(source):
            name = match.group(1).decode("ascii")
            value = match.group(2).decode("utf-8", errors="replace").strip()
            token_values[name].add(value)
            tokens.append(
                {
                    "name": name,
                    "value": value,
                    "file": relative,
                    "fileSha256": digest,
                    "byteOffset": match.start(1),
                }
            )
    tokens.sort(key=lambda item: (item["name"], item["file"], item["byteOffset"]))
    conflicts = [
        {"name": name, "values": sorted(values)}
        for name, values in sorted(token_values.items())
        if len(values) > 1
    ]

    resources: list[dict[str, object]] = []
    for path in sorted(item for item in root.rglob("*") if item.is_file()):
        resources.append(
            {
                "path": path.relative_to(root).as_posix(),
                "kind": classify_resource(path),
                "bytes": path.stat().st_size,
                "sha256": sha256_file(path),
            }
        )
    kind_counts = Counter(str(item["kind"]) for item in resources)
    return {
        "schemaVersion": 1,
        "version": version,
        "html": {
            "path": "index.html",
            "sha256": sha256_file(html_path),
            "title": "".join(parser.title_parts).strip(),
            "moduleEntries": sorted(set(parser.module_entries)),
            "stylesheets": sorted(set(parser.stylesheets)),
            "modulePreloads": sorted(set(parser.preloads)),
        },
        "cssTokenCount": len(tokens),
        "tokenConflictCount": len(conflicts),
        "cssTokens": tokens,
        "tokenConflicts": conflicts,
        "resourceCount": len(resources),
        "resourceKindCounts": dict(sorted(kind_counts.items())),
        "resources": resources,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--webview-root", type=Path, required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    write_json_atomic(
        args.output, extract_visual_reference(args.webview_root, args.version)
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
