#!/usr/bin/env python3
"""Build a semantic release delta for two recovered Codex desktop bundles.

The official Electron renderer is content-addressed: a rebuild can rename
thousands of Vite chunks even when the product surface is unchanged.  This
module compares stable inventory identities and normalizes version/build and
chunk-hash references before reporting a product change.
"""

from __future__ import annotations

import argparse
from collections import Counter, defaultdict
import copy
import hashlib
import json
from pathlib import Path
import re
import sys
from typing import Iterable

if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from scripts.protocol_manifest import load_json_object, write_json_atomic


VITE_HASH_SUFFIX = re.compile(
    r"^(?P<prefix>.+?)-[A-Za-z0-9_-]{8,12}"
    r"(?P<suffix>\.(?:js|css|mjs|cjs)(?:\.map)?)$"
)
VITE_HASH_IN_TEXT = re.compile(
    r"(?P<prefix>(?:[A-Za-z0-9_./-]+?))-"
    r"(?P<hash>[A-Za-z0-9_-]{8,12})"
    r"(?P<suffix>\.(?:js|css|mjs|cjs)(?:\.map)?)"
)
TEXT_SUFFIXES = {
    ".cjs",
    ".css",
    ".html",
    ".js",
    ".json",
    ".map",
    ".mjs",
    ".svg",
    ".txt",
    ".xml",
}


def _read_json(path: Path) -> dict:
    return load_json_object(path)


def _indexed(items: Iterable[object], key: str) -> dict[str, dict]:
    result: dict[str, dict] = {}
    for item in items:
        if not isinstance(item, dict) or not isinstance(item.get(key), str):
            continue
        result[str(item[key])] = item
    return result


def _map_delta(
    old_items: Iterable[object],
    new_items: Iterable[object],
    *,
    key: str,
    semantic_projection=None,
) -> tuple[list[dict], list[dict], list[dict]]:
    old = _indexed(old_items, key)
    new = _indexed(new_items, key)
    added = [new[item] for item in sorted(set(new) - set(old))]
    removed = [old[item] for item in sorted(set(old) - set(new))]
    changed = []
    project = semantic_projection or (lambda value: value)
    for item in sorted(set(old) & set(new)):
        if project(old[item]) != project(new[item]):
            changed.append({key: item, "old": old[item], "new": new[item]})
    return added, removed, changed


def _without_provenance_source_version(value):
    copied = copy.deepcopy(value)

    def visit(node):
        if isinstance(node, dict):
            provenance = node.get("evidenceProvenance")
            if isinstance(provenance, dict):
                provenance.pop("sourceVersion", None)
            for child in node.values():
                visit(child)
        elif isinstance(node, list):
            for child in node:
                visit(child)

    visit(copied)
    return copied


def compare_feature_inventories(old: dict, new: dict) -> dict[str, object]:
    old_features = _indexed(old.get("features", []), "id")
    new_features = _indexed(new.get("features", []), "id")
    added = [new_features[item] for item in sorted(set(new_features) - set(old_features))]
    removed = [old_features[item] for item in sorted(set(old_features) - set(new_features))]
    semantic_changed = []
    provenance_only_changed = []
    for feature_id in sorted(set(old_features) & set(new_features)):
        old_feature = old_features[feature_id]
        new_feature = new_features[feature_id]
        if old_feature == new_feature:
            continue
        record = {"id": feature_id, "old": old_feature, "new": new_feature}
        if _without_provenance_source_version(
            old_feature
        ) == _without_provenance_source_version(new_feature):
            provenance_only_changed.append(record)
        else:
            semantic_changed.append(record)
    return {
        "oldCount": int(old.get("featureCount", len(old_features))),
        "newCount": int(new.get("featureCount", len(new_features))),
        "added": added,
        "removed": removed,
        "semanticChanged": semantic_changed,
        "provenanceOnlyChanged": provenance_only_changed,
    }


def stable_bundle_key(relative: str) -> str:
    path = Path(relative)
    match = VITE_HASH_SUFFIX.fullmatch(path.name)
    if match is None:
        return relative
    stable_name = f"{match.group('prefix')}{match.group('suffix')}"
    parent = path.parent.as_posix()
    return stable_name if parent == "." else f"{parent}/{stable_name}"


def _bundle_files(root: Path) -> list[str]:
    return sorted(
        path.relative_to(root).as_posix()
        for path in root.rglob("*")
        if path.is_file()
    )


def _normalized_content(
    path: Path,
    *,
    version: str,
    build: str,
) -> bytes:
    data = path.read_bytes()
    if path.suffix.lower() not in TEXT_SUFFIXES:
        return data
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError:
        return data
    # Normalize Vite/Rolldown content hashes in one regex pass.  This avoids
    # an O(files * files) replacement loop over a 8k+ file bundle.
    text = VITE_HASH_IN_TEXT.sub(
        lambda match: f"{match.group('prefix')}{match.group('suffix')}",
        text,
    )
    if version:
        text = text.replace(version, "<DESKTOP_VERSION>")
    if build:
        text = text.replace(build, "<DESKTOP_BUILD>")
    return text.encode("utf-8")


def _sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def compare_bundle_content(
    old_root: Path,
    new_root: Path,
    *,
    old_version: str,
    new_version: str,
    old_build: str,
    new_build: str,
) -> dict[str, object]:
    old_paths = _bundle_files(old_root)
    new_paths = _bundle_files(new_root)
    old_groups: dict[str, list[str]] = defaultdict(list)
    new_groups: dict[str, list[str]] = defaultdict(list)
    for relative in old_paths:
        old_groups[stable_bundle_key(relative)].append(relative)
    for relative in new_paths:
        new_groups[stable_bundle_key(relative)].append(relative)

    added: list[dict] = []
    removed: list[dict] = []
    changed: list[dict] = []
    unresolved_ambiguous_groups: list[dict] = []
    unchanged_count = 0
    ambiguous_group_count = 0

    old_digest_cache: dict[str, str] = {}
    new_digest_cache: dict[str, str] = {}

    def digest_for(relative: str, *, old: bool) -> str:
        cache = old_digest_cache if old else new_digest_cache
        if relative not in cache:
            root = old_root if old else new_root
            version = old_version if old else new_version
            build = old_build if old else new_build
            cache[relative] = _sha256(
                _normalized_content(
                    root / relative,
                    version=version,
                    build=build,
                )
            )
        return cache[relative]

    def record_pair(
        *,
        stable_key: str,
        old_path: str,
        new_path: str,
        reason: str,
        confidence: str,
        ambiguous: bool,
    ) -> None:
        nonlocal unchanged_count
        if digest_for(old_path, old=True) == digest_for(new_path, old=False):
            unchanged_count += 1
            return
        old_bytes = (old_root / old_path).stat().st_size
        new_bytes = (new_root / new_path).stat().st_size
        changed.append(
            {
                "stableKey": stable_key,
                "oldPath": old_path,
                "newPath": new_path,
                "oldBytes": old_bytes,
                "newBytes": new_bytes,
                "byteDelta": new_bytes - old_bytes,
                "ambiguousStableGroup": ambiguous,
                "pairingReason": reason,
                "pairingConfidence": confidence,
            }
        )

    for stable_key in sorted(set(old_groups) | set(new_groups)):
        old_members = old_groups.get(stable_key, [])
        new_members = new_groups.get(stable_key, [])
        if not old_members:
            added.extend(
                {"stableKey": stable_key, "path": path} for path in new_members
            )
            continue
        if not new_members:
            removed.extend(
                {"stableKey": stable_key, "path": path} for path in old_members
            )
            continue

        ambiguous = len(old_members) > 1 or len(new_members) > 1
        if ambiguous:
            ambiguous_group_count += 1

        remaining_old = set(old_members)
        remaining_new = set(new_members)

        # A literal path is stronger identity evidence than a coincidentally
        # equal digest in a collision group.  Pair these first so a content
        # swap cannot masquerade as two unchanged files.
        for path in sorted(remaining_old & remaining_new):
            record_pair(
                stable_key=stable_key,
                old_path=path,
                new_path=path,
                reason="exact-path",
                confidence="high",
                ambiguous=ambiguous,
            )
            remaining_old.remove(path)
            remaining_new.remove(path)

        # A stable key with one member on each side is the normal Vite rename
        # case and has no competing candidate.
        if not ambiguous and remaining_old and remaining_new:
            old_path = next(iter(remaining_old))
            new_path = next(iter(remaining_new))
            record_pair(
                stable_key=stable_key,
                old_path=old_path,
                new_path=new_path,
                reason="unique-stable-key",
                confidence="high",
                ambiguous=False,
            )
            remaining_old.clear()
            remaining_new.clear()

        # Within a collision group, identical normalized content is strong
        # semantic evidence even when the generated filename changed.
        old_by_hash: dict[str, list[str]] = defaultdict(list)
        new_by_hash: dict[str, list[str]] = defaultdict(list)
        for relative in remaining_old:
            old_by_hash[digest_for(relative, old=True)].append(relative)
        for relative in remaining_new:
            new_by_hash[digest_for(relative, old=False)].append(relative)
        for digest in sorted(set(old_by_hash) & set(new_by_hash)):
            old_candidates = sorted(old_by_hash[digest])
            new_candidates = sorted(new_by_hash[digest])
            for old_path, new_path in zip(old_candidates, new_candidates):
                record_pair(
                    stable_key=stable_key,
                    old_path=old_path,
                    new_path=new_path,
                    reason="normalized-content",
                    confidence="high",
                    ambiguous=ambiguous,
                )
                remaining_old.remove(old_path)
                remaining_new.remove(new_path)

        # A byte size that occurs exactly once on both sides is useful but not
        # identity-proof, so expose it as medium confidence rather than
        # silently treating the pair as certain.
        old_by_size: dict[int, list[str]] = defaultdict(list)
        new_by_size: dict[int, list[str]] = defaultdict(list)
        for relative in remaining_old:
            old_by_size[(old_root / relative).stat().st_size].append(relative)
        for relative in remaining_new:
            new_by_size[(new_root / relative).stat().st_size].append(relative)
        for size in sorted(set(old_by_size) & set(new_by_size)):
            if len(old_by_size[size]) != 1 or len(new_by_size[size]) != 1:
                continue
            old_path = old_by_size[size][0]
            new_path = new_by_size[size][0]
            record_pair(
                stable_key=stable_key,
                old_path=old_path,
                new_path=new_path,
                reason="unique-size",
                confidence="medium",
                ambiguous=ambiguous,
            )
            remaining_old.remove(old_path)
            remaining_new.remove(new_path)

        # Exact-path and other proven pairs can reduce a collision to one
        # candidate on each side.  The elimination is useful but remains
        # medium-confidence evidence because the original key was ambiguous.
        if len(remaining_old) == 1 and len(remaining_new) == 1:
            old_path = next(iter(remaining_old))
            new_path = next(iter(remaining_new))
            record_pair(
                stable_key=stable_key,
                old_path=old_path,
                new_path=new_path,
                reason="collision-elimination",
                confidence="medium",
                ambiguous=ambiguous,
            )
            remaining_old.clear()
            remaining_new.clear()

        if remaining_old or remaining_new:
            unresolved_ambiguous_groups.append(
                {
                    "stableKey": stable_key,
                    "oldPaths": sorted(remaining_old),
                    "newPaths": sorted(remaining_new),
                    "reason": "insufficient-pairing-evidence",
                }
            )

    return {
        "oldFileCount": len(old_paths),
        "newFileCount": len(new_paths),
        "oldStableKeyCount": len(old_groups),
        "newStableKeyCount": len(new_groups),
        "unchangedCount": unchanged_count,
        "changed": changed,
        "added": added,
        "removed": removed,
        "ambiguousChangedGroupCount": ambiguous_group_count,
        "unresolvedAmbiguousGroupCount": len(unresolved_ambiguous_groups),
        "unresolvedAmbiguousGroups": unresolved_ambiguous_groups,
    }


def _protocol_delta(old: dict, new: dict) -> dict[str, object]:
    added, removed, changed = _map_delta(
        old.get("files", []), new.get("files", []), key="path"
    )
    return {
        "oldCount": int(old.get("fileCount", 0)),
        "newCount": int(new.get("fileCount", 0)),
        "added": added,
        "removed": removed,
        "changed": changed,
    }


def _ipc_delta(old: dict, new: dict) -> dict[str, object]:
    def semantic(channel):
        return {
            key: channel.get(key)
            for key in (
                "channel",
                "mainOperations",
                "pairing",
                "preloadOperations",
                "rendererOperations",
            )
        }

    added, removed, changed = _map_delta(
        old.get("channels", []),
        new.get("channels", []),
        key="channel",
        semantic_projection=semantic,
    )
    return {
        "oldCount": int(old.get("channelCount", 0)),
        "newCount": int(new.get("channelCount", 0)),
        "added": added,
        "removed": removed,
        "semanticChangedChannels": changed,
        "oldUnresolvedCallCount": int(old.get("unresolvedCallCount", 0)),
        "newUnresolvedCallCount": int(new.get("unresolvedCallCount", 0)),
    }


def _interaction_delta(old: dict, new: dict) -> dict[str, object]:
    def flatten(inventory):
        result = []
        for surface in inventory.get("surfaces", []):
            if not isinstance(surface, dict):
                continue
            surface_id = surface.get("id")
            for interaction in surface.get("interactions", []):
                if not isinstance(interaction, dict):
                    continue
                item = copy.deepcopy(interaction)
                item["stableId"] = f"{surface_id}:{interaction.get('id')}"
                result.append(item)
        return result

    def semantic(interaction):
        return {
            key: interaction.get(key)
            for key in ("id", "kind", "defaultMessage", "description")
        }

    added, removed, changed = _map_delta(
        flatten(old),
        flatten(new),
        key="stableId",
        semantic_projection=semantic,
    )
    return {
        "oldCount": int(old.get("summary", {}).get("interactionCount", 0)),
        "newCount": int(new.get("summary", {}).get("interactionCount", 0)),
        "added": added,
        "removed": removed,
        "messageOrKindChanged": changed,
    }


def build_release_delta(
    *,
    old_version_root: Path,
    new_version_root: Path,
    old_bundle_root: Path,
    new_bundle_root: Path,
) -> dict[str, object]:
    old_features = _read_json(old_version_root / "feature-inventory.json")
    new_features = _read_json(new_version_root / "feature-inventory.json")
    old_interactions = _read_json(
        old_version_root / "desktop-interaction-inventory.json"
    )
    new_interactions = _read_json(
        new_version_root / "desktop-interaction-inventory.json"
    )
    old_surface = _read_json(old_version_root / "desktop-surface-manifest.json")
    new_surface = _read_json(new_version_root / "desktop-surface-manifest.json")
    old_version = str(old_surface.get("desktopVersion", old_version_root.name))
    new_version = str(new_surface.get("desktopVersion", new_version_root.name))
    old_build = str(old_surface.get("desktopBuild", ""))
    new_build = str(new_surface.get("desktopBuild", ""))

    normalized_bundle = compare_bundle_content(
        old_bundle_root,
        new_bundle_root,
        old_version=old_version,
        new_version=new_version,
        old_build=old_build,
        new_build=new_build,
    )
    return {
        "schemaVersion": 3,
        "oldVersion": old_version,
        "oldBuild": old_build,
        "newVersion": new_version,
        "newBuild": new_build,
        "protocol": _protocol_delta(
            _read_json(old_version_root / "protocol/index.json"),
            _read_json(new_version_root / "protocol/index.json"),
        ),
        "ipc": _ipc_delta(
            _read_json(old_version_root / "electron/ipc-inventory.json"),
            _read_json(new_version_root / "electron/ipc-inventory.json"),
        ),
        "features": compare_feature_inventories(old_features, new_features),
        "interactions": _interaction_delta(old_interactions, new_interactions),
        "surfaceBundle": {
            "oldResourceFileCount": old_surface.get("resourceFileCount"),
            "newResourceFileCount": new_surface.get("resourceFileCount"),
            "oldResourceTotalBytes": old_surface.get("resourceTotalBytes"),
            "newResourceTotalBytes": new_surface.get("resourceTotalBytes"),
            "oldResourceTreeSha256": old_surface.get("resourceTreeSha256"),
            "newResourceTreeSha256": new_surface.get("resourceTreeSha256"),
            "preloadProtocolChanged": old_surface.get("preloadProtocol")
            != new_surface.get("preloadProtocol"),
        },
        "bundleContent": {"normalization": {
            "viteHashSuffix": "final -[A-Za-z0-9_-]{8,12} before JS/CSS suffix",
            "versionAndBuildPlaceholders": True,
            "chunkReferencesRewrittenToStableKeys": True,
            "pairingOrder": [
                "exact-path",
                "unique-stable-key",
                "normalized-content",
                "unique-size",
                "collision-elimination",
            ],
            "ambiguousPairsExposeConfidence": True,
        }, "normalized": normalized_bundle},
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--old-version-root", type=Path, required=True)
    parser.add_argument("--new-version-root", type=Path, required=True)
    parser.add_argument("--old-bundle-root", type=Path, required=True)
    parser.add_argument("--new-bundle-root", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    result = build_release_delta(
        old_version_root=args.old_version_root,
        new_version_root=args.new_version_root,
        old_bundle_root=args.old_bundle_root,
        new_bundle_root=args.new_bundle_root,
    )
    write_json_atomic(args.output, result)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
