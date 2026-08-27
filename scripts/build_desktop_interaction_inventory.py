#!/usr/bin/env python3
"""Index official visible messages and controls without launching Codex."""

from __future__ import annotations

import argparse
from collections import defaultdict
from pathlib import Path
import re
import sys
from typing import Any

if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from scripts.build_desktop_ui_parity import (
    BUILD_PATTERN,
    SHA256_PATTERN,
    SURFACE_DEFINITIONS,
    VERSION_PATTERN,
)
from scripts.javascript_string_scanner import parse_javascript_string_at
from scripts.protocol_manifest import sha256_file, write_json_atomic


STRING_LITERAL = rb"(?:`(?:\\.|[^`\\])*`|'(?:\\.|[^'\\])*'|\"(?:\\.|[^\"\\])*\")"
MESSAGE_DESCRIPTOR_PATTERN = re.compile(
    rb"(?:^|[,{])\s*id\s*:\s*(?P<id>" + STRING_LITERAL + rb")"
    rb"\s*,\s*defaultMessage\s*:\s*(?P<default>" + STRING_LITERAL + rb")"
    rb"\s*,\s*description\s*:\s*(?P<description>" + STRING_LITERAL + rb")",
    re.MULTILINE,
)
INTERACTION_KIND_PATTERNS = (
    ("context-menu-item", ("context menu item",)),
    ("menu-item", ("menu item",)),
    ("button", ("button label", "button text", " button ")),
    ("dropdown", ("dropdown", "drop-down")),
    ("tab", ("tab label", " tab ", "tab title")),
    ("toggle", ("toggle", "checkbox", "switch label")),
    (
        "input",
        (
            "input label",
            "input field",
            "text field",
            "search field",
            "placeholder",
            "shortcut capture",
        ),
    ),
    ("link", ("link label", "link text")),
    ("tooltip", ("tooltip",)),
    ("shortcut", ("shortcut command", "keyboard shortcut")),
    ("action", ("action label",)),
    ("control", ("accessible label", "aria label", "affordance")),
)


def _inside_comment(source: bytes, offset: int) -> bool:
    line_start = source.rfind(b"\n", 0, offset) + 1
    if source.find(b"//", line_start, offset) >= 0:
        return True
    return source.rfind(b"/*", 0, offset) > source.rfind(b"*/", 0, offset)


def _message_descriptors(source: bytes) -> list[dict[str, object]]:
    descriptors: list[dict[str, object]] = []
    for match in MESSAGE_DESCRIPTOR_PATTERN.finditer(source):
        if _inside_comment(source, match.start()):
            continue
        identifier = parse_javascript_string_at(source, match.start("id"))
        default_message = parse_javascript_string_at(
            source, match.start("default")
        )
        description = parse_javascript_string_at(
            source, match.start("description")
        )
        if (
            identifier is None
            or default_message is None
            or description is None
            or not identifier.value
        ):
            continue
        descriptors.append(
            {
                "id": identifier.value,
                "defaultMessage": default_message.value,
                "description": description.value,
                "byteOffset": identifier.start,
            }
        )
    return descriptors


def _interaction_kind(description: str) -> str | None:
    normalized = f" {description.casefold()} "
    for kind, needles in INTERACTION_KIND_PATTERNS:
        if any(needle in normalized for needle in needles):
            return kind
    return None


def _surface_source_files(
    recovered_root: Path,
    patterns: list[str],
) -> tuple[list[Path], list[str]]:
    asset_root = recovered_root / "webview/assets"
    files: set[Path] = set()
    missing: list[str] = []
    for pattern in patterns:
        matches = sorted(path for path in asset_root.glob(pattern) if path.is_file())
        if not matches:
            missing.append(pattern)
        files.update(matches)
    return sorted(files), missing


def _surface_inventory(
    recovered_root: Path,
    definition: dict[str, Any],
    source_cache: dict[
        Path, tuple[bytes, str, list[dict[str, object]]]
    ],
) -> dict[str, object]:
    source_paths, missing = _surface_source_files(
        recovered_root,
        list(definition["evidenceGlobs"]),
    )
    source_files: list[dict[str, object]] = []
    grouped: dict[
        tuple[str, str, str], list[dict[str, object]]
    ] = defaultdict(list)
    for path in source_paths:
        relative = path.relative_to(recovered_root).as_posix()
        cached = source_cache.get(path)
        if cached is None:
            source = path.read_bytes()
            digest = sha256_file(path)
            descriptors = _message_descriptors(source)
            source_cache[path] = (source, digest, descriptors)
        else:
            source, digest, descriptors = cached
        source_files.append(
            {
                "path": relative,
                "bytes": len(source),
                "sha256": digest,
            }
        )
        for descriptor in descriptors:
            key = (
                str(descriptor["id"]),
                str(descriptor["defaultMessage"]),
                str(descriptor["description"]),
            )
            grouped[key].append(
                {
                    "file": relative,
                    "fileSha256": digest,
                    "byteOffset": descriptor["byteOffset"],
                }
            )

    messages: list[dict[str, object]] = []
    interactions: list[dict[str, object]] = []
    for (identifier, default_message, description), occurrences in sorted(
        grouped.items()
    ):
        row = {
            "id": identifier,
            "defaultMessage": default_message,
            "description": description,
            "occurrences": sorted(
                occurrences,
                key=lambda item: (str(item["file"]), int(item["byteOffset"])),
            ),
        }
        messages.append(row)
        kind = _interaction_kind(description)
        if kind is not None:
            interactions.append({"kind": kind, **row})

    return {
        "id": definition["id"],
        "category": definition["category"],
        "name": definition["name"],
        "routes": list(definition["routes"]),
        "requiredStates": list(definition["requiredStates"]),
        "referenceStatus": (
            "missing-reference" if missing else "reference-indexed"
        ),
        "missingEvidenceGlobs": missing,
        "sourceFiles": source_files,
        "messageCount": len(messages),
        "interactionCount": len(interactions),
        "messages": messages,
        "interactions": interactions,
    }


def build_desktop_interaction_inventory(
    recovered_root: Path,
    *,
    desktop_version: str,
    desktop_build: str,
    desktop_surface_tree_sha256: str,
) -> dict[str, object]:
    if VERSION_PATTERN.fullmatch(desktop_version) is None:
        raise ValueError("desktop version is malformed")
    if BUILD_PATTERN.fullmatch(desktop_build) is None:
        raise ValueError("desktop build is malformed")
    if SHA256_PATTERN.fullmatch(desktop_surface_tree_sha256) is None:
        raise ValueError("desktop surface tree hash is malformed")
    recovered_root = recovered_root.resolve()
    if not (recovered_root / "webview/assets").is_dir():
        raise ValueError("recovered renderer asset root is missing")

    source_cache: dict[
        Path, tuple[bytes, str, list[dict[str, object]]]
    ] = {}
    surfaces = [
        _surface_inventory(recovered_root, definition, source_cache)
        for definition in SURFACE_DEFINITIONS
    ]
    evidence_paths = {
        str(source["path"])
        for surface in surfaces
        for source in surface["sourceFiles"]
    }
    return {
        "schemaVersion": 1,
        "desktopVersion": desktop_version,
        "desktopBuild": desktop_build,
        "sourceIdentity": {
            "desktopSurfaceTreeSha256": desktop_surface_tree_sha256,
        },
        "extractionMode": "static-official-renderer-no-execution",
        "summary": {
            "surfaceCount": len(surfaces),
            "referenceIndexed": sum(
                row["referenceStatus"] == "reference-indexed"
                for row in surfaces
            ),
            "missingReference": sum(
                row["referenceStatus"] == "missing-reference"
                for row in surfaces
            ),
            "evidenceFileCount": len(evidence_paths),
            "messageCount": sum(int(row["messageCount"]) for row in surfaces),
            "interactionCount": sum(
                int(row["interactionCount"]) for row in surfaces
            ),
            "surfacesWithInteractions": sum(
                int(row["interactionCount"]) > 0 for row in surfaces
            ),
        },
        "surfaces": surfaces,
    }


def _inventory_error(message: str) -> ValueError:
    return ValueError(f"desktop interaction inventory {message}")


def _require_inventory_relative_path(raw: object) -> str:
    if not isinstance(raw, str) or not raw:
        raise _inventory_error("source path is malformed")
    relative = Path(raw)
    if (
        relative.is_absolute()
        or "\\" in raw
        or "" in raw.split("/")
        or "." in relative.parts
        or ".." in relative.parts
    ):
        raise _inventory_error("source path escapes recovered renderer")
    return relative.as_posix()


def _require_inventory_count(value: object, *, label: str) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or value < 0:
        raise _inventory_error(f"{label} is malformed")
    return value


def verify_desktop_interaction_inventory(
    inventory: dict[str, object],
    recovered_root: Path,
    *,
    desktop_version: str,
    desktop_build: str,
    desktop_surface_tree_sha256: str,
) -> dict[str, int]:
    """Verify the static official control inventory against exact source bytes."""
    if (
        inventory.get("schemaVersion") != 1
        or inventory.get("desktopVersion") != desktop_version
        or str(inventory.get("desktopBuild", "")) != desktop_build
        or inventory.get("extractionMode")
        != "static-official-renderer-no-execution"
    ):
        raise _inventory_error("identity is malformed")
    source_identity = inventory.get("sourceIdentity")
    if (
        not isinstance(source_identity, dict)
        or source_identity
        != {"desktopSurfaceTreeSha256": desktop_surface_tree_sha256}
    ):
        raise _inventory_error("source identity does not match exact release")

    recovered_root = recovered_root.resolve()
    if not recovered_root.is_dir():
        raise _inventory_error("recovered renderer root is missing")
    surfaces = inventory.get("surfaces")
    if not isinstance(surfaces, list):
        raise _inventory_error("surfaces are malformed")
    expected_ids = [str(row["id"]) for row in SURFACE_DEFINITIONS]
    if [row.get("id") for row in surfaces if isinstance(row, dict)] != expected_ids:
        raise _inventory_error("surface identity mismatch")

    evidence_paths: set[str] = set()
    total_messages = 0
    total_interactions = 0
    indexed_count = 0
    surfaces_with_interactions = 0
    valid_kinds = {kind for kind, _ in INTERACTION_KIND_PATTERNS}
    for definition, surface in zip(SURFACE_DEFINITIONS, surfaces):
        if not isinstance(surface, dict):
            raise _inventory_error("surface is malformed")
        surface_id = str(definition["id"])
        if (
            surface.get("category") != definition["category"]
            or surface.get("name") != definition["name"]
            or surface.get("routes") != list(definition["routes"])
            or surface.get("requiredStates")
            != list(definition["requiredStates"])
        ):
            raise _inventory_error(f"{surface_id} definition mismatch")
        if (
            surface.get("referenceStatus") != "reference-indexed"
            or surface.get("missingEvidenceGlobs") != []
        ):
            raise _inventory_error(f"{surface_id} reference is incomplete")
        indexed_count += 1

        source_files = surface.get("sourceFiles")
        if not isinstance(source_files, list) or not source_files:
            raise _inventory_error(f"{surface_id} source files are missing")
        source_records: dict[str, tuple[str, int]] = {}
        for record in source_files:
            if not isinstance(record, dict):
                raise _inventory_error(f"{surface_id} source record is malformed")
            relative = _require_inventory_relative_path(record.get("path"))
            if relative in source_records:
                raise _inventory_error(f"{surface_id} source path is duplicated")
            expected_bytes = _require_inventory_count(
                record.get("bytes"),
                label=f"{surface_id} source byte count",
            )
            expected_sha256 = record.get("sha256")
            if (
                not isinstance(expected_sha256, str)
                or SHA256_PATTERN.fullmatch(expected_sha256) is None
            ):
                raise _inventory_error(f"{surface_id} source hash is malformed")
            candidate = (recovered_root / relative).resolve()
            try:
                candidate.relative_to(recovered_root)
            except ValueError as error:
                raise _inventory_error(
                    f"{surface_id} source path escapes recovered renderer"
                ) from error
            if (
                candidate.is_symlink()
                or not candidate.is_file()
                or candidate.stat().st_size != expected_bytes
                or sha256_file(candidate) != expected_sha256
            ):
                raise _inventory_error(f"{surface_id} source hash mismatch")
            source_records[relative] = (expected_sha256, expected_bytes)
            evidence_paths.add(relative)

        messages = surface.get("messages")
        interactions = surface.get("interactions")
        if not isinstance(messages, list) or not isinstance(interactions, list):
            raise _inventory_error(f"{surface_id} controls are malformed")
        if _require_inventory_count(
            surface.get("messageCount"), label=f"{surface_id} message count"
        ) != len(messages):
            raise _inventory_error(f"{surface_id} message count mismatch")
        if _require_inventory_count(
            surface.get("interactionCount"),
            label=f"{surface_id} interaction count",
        ) != len(interactions):
            raise _inventory_error(f"{surface_id} interaction count mismatch")
        if not interactions:
            raise _inventory_error(f"{surface_id} has no indexed controls")

        message_keys: set[tuple[str, str, str]] = set()
        for collection_name, rows in (
            ("message", messages),
            ("interaction", interactions),
        ):
            for row in rows:
                if not isinstance(row, dict):
                    raise _inventory_error(
                        f"{surface_id} {collection_name} is malformed"
                    )
                identity = (
                    row.get("id"),
                    row.get("defaultMessage"),
                    row.get("description"),
                )
                if not all(isinstance(value, str) and value for value in identity):
                    raise _inventory_error(
                        f"{surface_id} {collection_name} identity is malformed"
                    )
                if collection_name == "message":
                    message_keys.add(identity)  # type: ignore[arg-type]
                else:
                    if row.get("kind") not in valid_kinds:
                        raise _inventory_error(
                            f"{surface_id} interaction kind is malformed"
                        )
                    if identity not in message_keys:
                        raise _inventory_error(
                            f"{surface_id} interaction is absent from messages"
                        )
                occurrences = row.get("occurrences")
                if not isinstance(occurrences, list) or not occurrences:
                    raise _inventory_error(
                        f"{surface_id} {collection_name} occurrences are missing"
                    )
                for occurrence in occurrences:
                    if not isinstance(occurrence, dict):
                        raise _inventory_error(
                            f"{surface_id} occurrence is malformed"
                        )
                    relative = _require_inventory_relative_path(
                        occurrence.get("file")
                    )
                    source_record = source_records.get(relative)
                    offset = occurrence.get("byteOffset")
                    if (
                        source_record is None
                        or occurrence.get("fileSha256") != source_record[0]
                        or isinstance(offset, bool)
                        or not isinstance(offset, int)
                        or offset < 0
                        or offset >= source_record[1]
                    ):
                        raise _inventory_error(
                            f"{surface_id} occurrence does not match source"
                        )

        total_messages += len(messages)
        total_interactions += len(interactions)
        surfaces_with_interactions += 1

    summary = inventory.get("summary")
    expected_summary = {
        "surfaceCount": len(surfaces),
        "referenceIndexed": indexed_count,
        "missingReference": 0,
        "evidenceFileCount": len(evidence_paths),
        "messageCount": total_messages,
        "interactionCount": total_interactions,
        "surfacesWithInteractions": surfaces_with_interactions,
    }
    if summary != expected_summary:
        raise _inventory_error("summary does not match indexed controls")
    return expected_summary


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--recovered-root", type=Path, required=True)
    parser.add_argument("--desktop-version", required=True)
    parser.add_argument("--desktop-build", required=True)
    parser.add_argument("--desktop-surface-tree-sha256", required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    write_json_atomic(
        args.output,
        build_desktop_interaction_inventory(
            args.recovered_root,
            desktop_version=args.desktop_version,
            desktop_build=args.desktop_build,
            desktop_surface_tree_sha256=args.desktop_surface_tree_sha256,
        ),
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
