from __future__ import annotations

import hashlib
import json
from pathlib import Path

from scripts.build_desktop_ui_parity import SURFACE_DEFINITIONS


REFERENCE_PATH = "webview/assets/reference.js"
REFERENCE_PAYLOAD = b"desktop reference fixture\n"
SURFACE_TREE_SHA256 = "1" * 64


def build_desktop_interaction_inventory(
    *,
    version: str,
    build: str,
    reference_payload: bytes = REFERENCE_PAYLOAD,
    surface_tree_sha256: str = SURFACE_TREE_SHA256,
) -> dict[str, object]:
    digest = hashlib.sha256(reference_payload).hexdigest()
    surfaces = []
    for definition in SURFACE_DEFINITIONS:
        surface_id = str(definition["id"])
        occurrence = {
            "file": REFERENCE_PATH,
            "fileSha256": digest,
            "byteOffset": 0,
        }
        interaction = {
            "kind": "button",
            "id": f"fixture.{surface_id}.button",
            "defaultMessage": f"Fixture {surface_id}",
            "description": "Button label for fixture interaction",
            "occurrences": [occurrence],
        }
        surfaces.append(
            {
                "id": surface_id,
                "category": definition["category"],
                "name": definition["name"],
                "routes": list(definition["routes"]),
                "requiredStates": list(definition["requiredStates"]),
                "referenceStatus": "reference-indexed",
                "missingEvidenceGlobs": [],
                "sourceFiles": [
                    {
                        "path": REFERENCE_PATH,
                        "bytes": len(reference_payload),
                        "sha256": digest,
                    }
                ],
                "messageCount": 1,
                "interactionCount": 1,
                "messages": [
                    {
                        key: value
                        for key, value in interaction.items()
                        if key != "kind"
                    }
                ],
                "interactions": [interaction],
            }
        )
    surface_count = len(surfaces)
    return {
        "schemaVersion": 1,
        "desktopVersion": version,
        "desktopBuild": build,
        "sourceIdentity": {
            "desktopSurfaceTreeSha256": surface_tree_sha256,
        },
        "extractionMode": "static-official-renderer-no-execution",
        "summary": {
            "surfaceCount": surface_count,
            "referenceIndexed": surface_count,
            "missingReference": 0,
            "evidenceFileCount": 1,
            "messageCount": surface_count,
            "interactionCount": surface_count,
            "surfacesWithInteractions": surface_count,
        },
        "surfaces": surfaces,
    }


def write_desktop_interaction_inventory(
    root: Path,
    *,
    version: str,
    build: str,
    reference_payload: bytes = REFERENCE_PAYLOAD,
    surface_tree_sha256: str = SURFACE_TREE_SHA256,
) -> Path:
    path = root / f"versions/{version}/desktop-interaction-inventory.json"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        json.dumps(
            build_desktop_interaction_inventory(
                version=version,
                build=build,
                reference_payload=reference_payload,
                surface_tree_sha256=surface_tree_sha256,
            )
        )
        + "\n",
        encoding="utf-8",
    )
    return path
