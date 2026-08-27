#!/usr/bin/env python3
"""Export deterministic S01-S10 iPad captures from an XCResult bundle."""

from __future__ import annotations

import argparse
import hashlib
import json
import struct
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
from typing import Any
import uuid

try:
    from PIL import Image, ImageOps
except ModuleNotFoundError:  # pragma: no cover - exercised by lean verifier hosts
    Image = None  # type: ignore[assignment]
    ImageOps = None  # type: ignore[assignment]

if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from scripts.parity_capture_plan import capture_specs, capture_specs_by_surface


EXPECTED_SURFACE_IDS = tuple(f"S{index:02d}" for index in range(1, 11))
EXPECTED_CAPTURE_SPECS = capture_specs()
EXPECTED_CAPTURE_SPECS_BY_SURFACE = capture_specs_by_surface()
EXPECTED_CAPTURE_KEYS = {
    (spec["surfaceId"], spec["captureKey"]): spec
    for spec in EXPECTED_CAPTURE_SPECS
}


def _allows_visual_alias(identity: tuple[str, str], previous: tuple[str, str]) -> bool:
    """Return true only for an alias explicitly declared by the capture plan."""
    for alias_identity, target_identity in (
        (identity, previous),
        (previous, identity),
    ):
        alias = EXPECTED_CAPTURE_KEYS[alias_identity].get("visualAliasOf")
        if (
            isinstance(alias, (list, tuple))
            and len(alias) == 2
            and tuple(alias) == target_identity
        ):
            return True
    return False
ATTACHMENT_PREFIX = "CODEXPAD_PARITY_"
ATTACHMENT_PATTERN = re.compile(
    r"^CODEXPAD_PARITY_(S(?:0[1-9]|10))__(.+)\.png$"
)
INVENTORY_PREFIX = "CODEXPAD_INVENTORY_"
INVENTORY_PATTERN = re.compile(
    r"^CODEXPAD_INVENTORY_(S(?:0[1-9]|10))__(.+)\.json$"
)
INTERACTION_ATTACHMENT_NAME = "Physical iPad interaction acceptance"
EXPECTED_INTERACTION_ACTIONS = tuple(
    "|".join((
        spec["surfaceId"],
        spec["captureKey"],
        spec["route"],
        spec["state"],
    ))
    for spec in EXPECTED_CAPTURE_SPECS
)
STRICT_EVIDENCE_MODE = "complete-desktop-comparison"
PHYSICAL_RENDERER_EVIDENCE_MODE = "physical-official-renderer-observed"


def _known_duplicate_priority(
    identity: tuple[str, str],
    test_identifier: str,
) -> int | None:
    """Rank the two XCTest producers that intentionally overlap S09."""
    if identity[0] != "S09":
        return None
    if test_identifier.endswith(
        "/testCapturesOfficialRendererParitySurfaces()"
    ):
        return 0
    if test_identifier.endswith(
        "/testCapturesS09SecondaryProductStatesOnPhysicalIPad()"
    ):
        return 1
    return None


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _load_manifest(path: Path) -> list[dict[str, Any]]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise ValueError("XCResult attachment manifest is malformed") from error
    if not isinstance(value, list):
        raise ValueError("XCResult attachment manifest is malformed")
    return value


def _canonical_attachment_name(suggested_name: str) -> str:
    if "_0_" in suggested_name:
        stem, suffix = suggested_name.rsplit("_0_", 1)
        extension = Path(suffix).suffix.lower()
        if extension in {".png", ".json"}:
            return stem + extension
    return suggested_name


def _attachment_device_identity(
    attachment: dict[str, Any],
    *,
    label: str,
) -> tuple[str, str]:
    device_id = attachment.get("deviceId")
    device_name = attachment.get("deviceName")
    if not isinstance(device_id, str) or not device_id.strip():
        raise ValueError(f"{label} device id is malformed")
    if not isinstance(device_name, str) or not device_name.strip():
        raise ValueError(f"{label} device name is malformed")
    return device_id.strip(), device_name.strip()


def _safe_exported_file(export_root: Path, raw_name: object) -> Path:
    if not isinstance(raw_name, str) or not raw_name:
        raise ValueError("XCResult exported attachment filename is malformed")
    relative = Path(raw_name)
    if (
        relative.is_absolute()
        or len(relative.parts) != 1
        or relative.name != raw_name
    ):
        raise ValueError("XCResult exported attachment filename escapes export")
    path = (export_root / relative).resolve()
    try:
        path.relative_to(export_root)
    except ValueError as error:
        raise ValueError(
            "XCResult exported attachment filename escapes export"
        ) from error
    if not path.is_file():
        raise ValueError(f"XCResult attachment is missing: {raw_name}")
    return path


def _validate_png(path: Path, surface_id: str) -> None:
    if Image is None:
        try:
            with path.open("rb") as stream:
                signature = stream.read(8)
                if signature != b"\x89PNG\r\n\x1a\n":
                    raise ValueError("invalid PNG signature")
                length = struct.unpack(">I", stream.read(4))[0]
                chunk_type = stream.read(4)
                if chunk_type != b"IHDR" or length < 8:
                    raise ValueError("missing PNG IHDR")
                width, height = struct.unpack(">II", stream.read(8))
        except (OSError, struct.error, ValueError) as error:
            raise ValueError(
                f"{surface_id} parity capture is not a valid PNG"
            ) from error
        if width < 320 or height < 320:
            raise ValueError(
                f"{surface_id} parity capture is too small for runtime evidence"
            )
        return
    try:
        with Image.open(path) as image:
            image.verify()
        with Image.open(path) as image:
            width, height = image.size
    except Exception as error:
        raise ValueError(
            f"{surface_id} parity capture is not a valid PNG"
        ) from error
    if width < 320 or height < 320:
        raise ValueError(
            f"{surface_id} parity capture is too small for runtime evidence"
        )


def _write_normalized_png(source: Path, destination: Path) -> None:
    if Image is None or ImageOps is None:
        # XCTest emits screenshots as canonical PNGs. On minimal verifier
        # hosts without Pillow, preserve those bytes rather than making the
        # whole upgrade gate depend on an optional image package.
        shutil.copyfile(source, destination)
        return
    with Image.open(source) as image:
        normalized = ImageOps.exif_transpose(image)
        normalized.save(destination, format="PNG")


def _collect_captures(
    export_root: Path,
    *,
    require_complete: bool,
) -> dict[tuple[str, str], dict[str, Any]]:
    manifest_path = export_root / "manifest.json"
    rows = _load_manifest(manifest_path)
    captures: dict[tuple[str, str], dict[str, Any]] = {}
    digests: dict[str, str] = {}
    for test_row in rows:
        if not isinstance(test_row, dict):
            raise ValueError("XCResult attachment manifest row is malformed")
        test_identifier = test_row.get("testIdentifier")
        if not isinstance(test_identifier, str) or not test_identifier:
            raise ValueError("XCResult test identifier is malformed")
        attachments = test_row.get("attachments")
        if not isinstance(attachments, list):
            raise ValueError("XCResult attachment list is malformed")
        for attachment in attachments:
            if not isinstance(attachment, dict):
                raise ValueError("XCResult attachment row is malformed")
            suggested = attachment.get("suggestedHumanReadableName")
            if not isinstance(suggested, str):
                raise ValueError("XCResult attachment name is malformed")
            canonical_name = _canonical_attachment_name(suggested)
            if not canonical_name.startswith(ATTACHMENT_PREFIX):
                continue
            match = ATTACHMENT_PATTERN.fullmatch(canonical_name)
            if match is None:
                raise ValueError(
                    f"malformed parity capture attachment name: {suggested}"
                )
            surface_id = match.group(1)
            capture_key = match.group(2)
            identity = (surface_id, capture_key)
            if identity not in EXPECTED_CAPTURE_KEYS:
                raise ValueError(
                    f"unexpected parity capture: {surface_id}/{capture_key}"
                )
            if identity in captures:
                previous_test_identifier = captures[identity]["testIdentifier"]
                previous_priority = _known_duplicate_priority(
                    identity,
                    previous_test_identifier,
                )
                current_priority = _known_duplicate_priority(
                    identity,
                    test_identifier,
                )
                if (
                    previous_priority is not None
                    and current_priority is not None
                    and previous_priority != current_priority
                ):
                    if current_priority < previous_priority:
                        # The primary parity sweep wins even if XCResult rows
                        # happen to be emitted in reverse order.
                        del captures[identity]
                    else:
                        # The focused S09 sweep is supplemental evidence; it
                        # must not make the canonical capture ambiguous.
                        continue
                else:
                    raise ValueError(
                        f"duplicate parity capture: {surface_id}/{capture_key}"
                    )
            if attachment.get("isAssociatedWithFailure") is True:
                raise ValueError(
                    f"{surface_id} parity capture is associated with failure"
                )
            source = _safe_exported_file(
                export_root,
                attachment.get("exportedFileName"),
            )
            device_id, device_name = _attachment_device_identity(
                attachment,
                label=f"{surface_id} parity capture",
            )
            _validate_png(source, surface_id)
            digest = _sha256(source)
            if digest in digests:
                previous = digests[digest]
                if not _allows_visual_alias(identity, previous):
                    raise ValueError(
                        f"{surface_id} reuses image bytes from {previous[0]}"
                    )
            else:
                digests[digest] = identity
            captures[identity] = {
                "captureKey": capture_key,
                "source": source,
                "sha256": digest,
                "attachmentName": canonical_name.removesuffix(".png"),
                "testIdentifier": test_identifier,
                "configurationName": attachment.get("configurationName"),
                "deviceId": device_id,
                "deviceName": device_name,
                "timestamp": attachment.get("timestamp"),
            }

    missing = [identity for identity in EXPECTED_CAPTURE_KEYS if identity not in captures]
    if missing and require_complete:
        completely_missing = [
            surface_id
            for surface_id in EXPECTED_SURFACE_IDS
            if all(
                (surface_id, spec["captureKey"]) not in captures
                for spec in EXPECTED_CAPTURE_SPECS_BY_SURFACE[surface_id]
            )
        ]
        labels = completely_missing or [
            f"{surface_id}/{capture_key}"
            for surface_id, capture_key in missing
        ]
        raise ValueError("missing parity captures: " + ", ".join(labels))
    return captures


def _collect_interaction_acceptance(
    export_root: Path,
    *,
    expected_actions: tuple[str, ...],
    allow_reordered_actions: bool,
) -> dict[str, Any]:
    rows = _load_manifest(export_root / "manifest.json")
    accepted: dict[str, Any] | None = None
    for test_row in rows:
        if not isinstance(test_row, dict):
            raise ValueError("XCResult attachment manifest row is malformed")
        test_identifier = test_row.get("testIdentifier")
        attachments = test_row.get("attachments")
        if not isinstance(test_identifier, str) or not isinstance(
            attachments, list
        ):
            raise ValueError("XCResult interaction attachment row is malformed")
        for attachment in attachments:
            if not isinstance(attachment, dict):
                raise ValueError("XCResult attachment row is malformed")
            suggested = attachment.get("suggestedHumanReadableName")
            if not isinstance(suggested, str) or not suggested.startswith(
                INTERACTION_ATTACHMENT_NAME
            ):
                continue
            if accepted is not None:
                raise ValueError(
                    "duplicate interaction acceptance attachment"
                )
            if attachment.get("isAssociatedWithFailure") is True:
                raise ValueError(
                    "interaction acceptance is associated with failure"
                )
            if "CodexPadParityCaptureUITests" not in test_identifier:
                raise ValueError(
                    "interaction acceptance came from the wrong test"
                )
            source = _safe_exported_file(
                export_root,
                attachment.get("exportedFileName"),
            )
            device_id, device_name = _attachment_device_identity(
                attachment,
                label="interaction acceptance",
            )
            try:
                actions = source.read_text(encoding="utf-8").splitlines()
            except (OSError, UnicodeDecodeError) as error:
                raise ValueError(
                    "interaction acceptance attachment is malformed"
                ) from error
            actions_match = actions == list(expected_actions)
            if allow_reordered_actions:
                actions_match = (
                    len(actions) == len(set(actions))
                    and set(actions) == set(expected_actions)
                )
            if not actions_match:
                raise ValueError(
                    "interaction acceptance actions must cover S01 through S10"
                    if expected_actions == EXPECTED_INTERACTION_ACTIONS
                    else "interaction acceptance actions do not match observed captures"
                )
            accepted = {
                "source": source,
                "actions": actions,
                "testIdentifier": test_identifier,
                "configurationName": attachment.get("configurationName"),
                "deviceId": device_id,
                "deviceName": device_name,
                "timestamp": attachment.get("timestamp"),
            }
    if accepted is None:
        raise ValueError("interaction acceptance attachment is missing")
    return accepted


def _validate_interaction_inventory(
    raw: object,
    *,
    surface_id: str,
) -> dict[str, Any]:
    if not isinstance(raw, dict):
        raise ValueError(f"{surface_id} interaction inventory is malformed")
    control_count = raw.get("controlCount")
    keyboard_count = raw.get("keyboardAccessibleCount")
    by_tag = raw.get("byTag")
    fingerprints = raw.get("labelFingerprints")
    valid = (
        isinstance(control_count, int)
        and not isinstance(control_count, bool)
        and control_count > 0
        and isinstance(keyboard_count, int)
        and not isinstance(keyboard_count, bool)
        and 0 < keyboard_count <= control_count
        and isinstance(by_tag, dict)
        and bool(by_tag)
        and all(
            isinstance(tag, str)
            and bool(tag)
            and isinstance(count, int)
            and not isinstance(count, bool)
            and count > 0
            for tag, count in by_tag.items()
        )
        and sum(by_tag.values()) == control_count
        and isinstance(fingerprints, list)
        and bool(fingerprints)
        and len(fingerprints) == len(set(fingerprints))
        and all(
            isinstance(value, str)
            and re.fullmatch(r"[0-9a-f]{64}", value) is not None
            for value in fingerprints
        )
    )
    if not valid:
        raise ValueError(f"{surface_id} interaction inventory is malformed")
    return {
        "controlCount": control_count,
        "keyboardAccessibleCount": keyboard_count,
        "byTag": dict(sorted(by_tag.items())),
        "labelFingerprints": sorted(fingerprints),
    }


def _collect_interaction_inventories(
    export_root: Path,
    *,
    expected_identities: set[tuple[str, str]],
    require_complete: bool,
) -> tuple[
    dict[tuple[str, str], dict[str, Any]],
    dict[tuple[str, str], tuple[str, str]],
]:
    rows = _load_manifest(export_root / "manifest.json")
    inventories: dict[tuple[str, str], dict[str, Any]] = {}
    inventory_devices: dict[tuple[str, str], tuple[str, str]] = {}
    inventory_test_identifiers: dict[tuple[str, str], str] = {}
    for test_row in rows:
        if not isinstance(test_row, dict):
            raise ValueError("XCResult attachment manifest row is malformed")
        test_identifier = test_row.get("testIdentifier")
        attachments = test_row.get("attachments")
        if not isinstance(test_identifier, str) or not isinstance(
            attachments, list
        ):
            raise ValueError("XCResult interaction attachment row is malformed")
        for attachment in attachments:
            if not isinstance(attachment, dict):
                raise ValueError("XCResult attachment row is malformed")
            suggested = attachment.get("suggestedHumanReadableName")
            if not isinstance(suggested, str):
                raise ValueError("XCResult attachment name is malformed")
            canonical_name = _canonical_attachment_name(suggested)
            if not canonical_name.startswith(INVENTORY_PREFIX):
                continue
            match = INVENTORY_PATTERN.fullmatch(canonical_name)
            if match is None:
                raise ValueError(
                    f"malformed interaction inventory attachment: {suggested}"
                )
            surface_id = match.group(1)
            capture_key = match.group(2)
            identity = (surface_id, capture_key)
            if identity not in EXPECTED_CAPTURE_KEYS:
                raise ValueError(
                    "unexpected interaction inventory: "
                    f"{surface_id}/{capture_key}"
                )
            if identity in inventories:
                previous_priority = _known_duplicate_priority(
                    identity,
                    inventory_test_identifiers[identity],
                )
                current_priority = _known_duplicate_priority(
                    identity,
                    test_identifier,
                )
                if (
                    previous_priority is not None
                    and current_priority is not None
                    and previous_priority != current_priority
                ):
                    if current_priority < previous_priority:
                        del inventories[identity]
                        del inventory_devices[identity]
                    else:
                        continue
                else:
                    raise ValueError(
                        "duplicate interaction inventory: "
                        f"{surface_id}/{capture_key}"
                    )
            if attachment.get("isAssociatedWithFailure") is True:
                raise ValueError(
                    f"{surface_id} interaction inventory is associated with failure"
                )
            if "CodexPadParityCaptureUITests" not in test_identifier:
                raise ValueError(
                    f"{surface_id} interaction inventory came from the wrong test"
                )
            source = _safe_exported_file(
                export_root,
                attachment.get("exportedFileName"),
            )
            device_identity = _attachment_device_identity(
                attachment,
                label=f"{surface_id} interaction inventory",
            )
            try:
                raw = json.loads(source.read_text(encoding="utf-8"))
            except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
                raise ValueError(
                    f"{surface_id} interaction inventory is malformed"
                ) from error
            inventories[identity] = _validate_interaction_inventory(
                raw,
                surface_id=surface_id,
            )
            inventory_devices[identity] = device_identity
            inventory_test_identifiers[identity] = test_identifier
    missing = [
        identity for identity in expected_identities if identity not in inventories
    ]
    if missing:
        completely_missing = [
            surface_id
            for surface_id in EXPECTED_SURFACE_IDS
            if all(
                (surface_id, spec["captureKey"]) not in inventories
                for spec in EXPECTED_CAPTURE_SPECS_BY_SURFACE[surface_id]
            )
        ]
        labels = completely_missing or [
            f"{surface_id}/{capture_key}"
            for surface_id, capture_key in missing
        ]
        raise ValueError(
            "missing interaction inventories: " + ", ".join(labels)
        )
    return inventories, inventory_devices


def _write_json(path: Path, value: object) -> None:
    path.write_text(
        json.dumps(
            value,
            ensure_ascii=False,
            indent=2,
            sort_keys=False,
        )
        + "\n",
        encoding="utf-8",
    )


def export_parity_captures(
    export_root: Path,
    output_root: Path,
    *,
    desktop_version: str,
    desktop_build: str,
    evidence_mode: str = STRICT_EVIDENCE_MODE,
) -> Path:
    """Validate one exported attachment tree and replace output atomically."""

    export_root = export_root.resolve()
    output_root = output_root.resolve()
    if not export_root.is_dir():
        raise ValueError("XCResult attachment export directory is missing")
    if evidence_mode not in {
        STRICT_EVIDENCE_MODE,
        PHYSICAL_RENDERER_EVIDENCE_MODE,
    }:
        raise ValueError("parity evidence mode is unsupported")
    require_complete = evidence_mode == STRICT_EVIDENCE_MODE
    captures = _collect_captures(
        export_root,
        require_complete=require_complete,
    )
    if not captures:
        raise ValueError("physical renderer evidence has no captures")
    observed_specs = tuple(
        spec
        for spec in EXPECTED_CAPTURE_SPECS
        if (spec["surfaceId"], spec["captureKey"]) in captures
    )
    expected_actions = tuple(
        "|".join((
            spec["surfaceId"],
            spec["captureKey"],
            spec["route"],
            spec["state"],
        ))
        for spec in observed_specs
    )
    interaction_acceptance = _collect_interaction_acceptance(
        export_root,
        expected_actions=expected_actions,
        allow_reordered_actions=not require_complete,
    )
    interaction_inventories, inventory_devices = _collect_interaction_inventories(
        export_root,
        expected_identities=set(captures),
        require_complete=require_complete,
    )
    device_identities = {
        (capture["deviceId"], capture["deviceName"])
        for capture in captures.values()
    }
    device_identities.add((
        interaction_acceptance["deviceId"],
        interaction_acceptance["deviceName"],
    ))
    device_identities.update(inventory_devices.values())
    if len(device_identities) != 1:
        raise ValueError("parity evidence mixes multiple devices")
    device_id, device_name = next(iter(device_identities))

    output_root.parent.mkdir(parents=True, exist_ok=True)
    staging = Path(
        tempfile.mkdtemp(
            prefix=f".{output_root.name}.staging-",
            dir=output_root.parent,
        )
    )
    backup: Path | None = None
    try:
        manifest_surfaces: dict[str, dict[str, Any]] = {}
        normalized_digests: dict[str, str] = {}
        for surface_id in EXPECTED_SURFACE_IDS:
            output_captures: list[dict[str, Any]] = []
            for spec in EXPECTED_CAPTURE_SPECS_BY_SURFACE[surface_id]:
                identity = (surface_id, spec["captureKey"])
                if identity not in captures:
                    continue
                capture = captures[identity]
                destination_name = (
                    f"{surface_id}-{spec['captureKey']}-ipad.png"
                )
                destination = staging / destination_name
                _write_normalized_png(capture["source"], destination)
                normalized_digest = _sha256(destination)
                if normalized_digest in normalized_digests:
                    previous = normalized_digests[normalized_digest]
                    if not _allows_visual_alias(identity, previous):
                        raise ValueError(
                            f"{surface_id} reuses image bytes from "
                            f"{previous[0]}"
                        )
                else:
                    normalized_digests[normalized_digest] = identity
                capture_row = {
                    "captureKey": spec["captureKey"],
                    "route": spec["route"],
                    "stateKey": spec["state"],
                    "path": destination_name,
                    "sha256": normalized_digest,
                    "attachmentName": capture["attachmentName"],
                    "testIdentifier": capture["testIdentifier"],
                    "configurationName": capture["configurationName"],
                    "deviceId": capture["deviceId"],
                    "deviceName": capture["deviceName"],
                    "timestamp": capture["timestamp"],
                    "interactionInventory": interaction_inventories[identity],
                }
                if "visualAliasOf" in spec:
                    capture_row["visualAliasOf"] = list(spec["visualAliasOf"])
                output_captures.append(capture_row)
            manifest_surfaces[surface_id] = {"captures": output_captures}
        interaction_destination = staging / "interaction-acceptance.txt"
        interaction_destination.write_text(
            "\n".join(interaction_acceptance["actions"]) + "\n",
            encoding="utf-8",
        )
        _write_json(
            staging / "manifest.json",
            {
                "schemaVersion": 4 if require_complete else 5,
                "evidenceMode": evidence_mode,
                "desktopVersion": desktop_version,
                "desktopBuild": desktop_build,
                "deviceId": device_id,
                "deviceName": device_name,
                "observedSurfaceIds": sorted({
                    identity[0] for identity in captures
                }),
                "missingSurfaceIds": [
                    surface_id
                    for surface_id in EXPECTED_SURFACE_IDS
                    if all(identity[0] != surface_id for identity in captures)
                ],
                "interactionAcceptance": {
                    "path": interaction_destination.name,
                    "sha256": _sha256(interaction_destination),
                    "actionCount": len(interaction_acceptance["actions"]),
                    "surfaceIds": sorted({identity[0] for identity in captures}),
                    "testIdentifier": interaction_acceptance[
                        "testIdentifier"
                    ],
                    "configurationName": interaction_acceptance[
                        "configurationName"
                    ],
                    "deviceId": interaction_acceptance["deviceId"],
                    "deviceName": interaction_acceptance["deviceName"],
                    "timestamp": interaction_acceptance["timestamp"],
                },
                "surfaces": manifest_surfaces,
            },
        )

        if output_root.exists():
            backup = output_root.with_name(
                f".{output_root.name}.previous-{uuid.uuid4().hex}"
            )
            output_root.rename(backup)
        staging.rename(output_root)
        if backup is not None:
            shutil.rmtree(backup)
        return output_root / "manifest.json"
    except Exception:
        if output_root.exists() and backup is not None:
            shutil.rmtree(output_root)
        if backup is not None and backup.exists():
            backup.rename(output_root)
        raise
    finally:
        if staging.exists():
            shutil.rmtree(staging)


def export_xcresult(
    xcresult: Path,
    output_root: Path,
    *,
    desktop_version: str,
    desktop_build: str,
    evidence_mode: str = STRICT_EVIDENCE_MODE,
) -> Path:
    xcresult = xcresult.resolve()
    if not xcresult.is_dir():
        raise ValueError("XCResult bundle is missing")
    with tempfile.TemporaryDirectory(
        prefix="codexpad-xcresult-attachments."
    ) as temporary:
        export_root = Path(temporary)
        subprocess.run(
            [
                "xcrun",
                "xcresulttool",
                "export",
                "attachments",
                "--path",
                str(xcresult),
                "--output-path",
                str(export_root),
            ],
            check=True,
        )
        return export_parity_captures(
            export_root,
            output_root,
            desktop_version=desktop_version,
            desktop_build=desktop_build,
            evidence_mode=evidence_mode,
        )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--xcresult", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--desktop-version", required=True)
    parser.add_argument("--desktop-build", required=True)
    parser.add_argument(
        "--evidence-mode",
        choices=(STRICT_EVIDENCE_MODE, PHYSICAL_RENDERER_EVIDENCE_MODE),
        default=STRICT_EVIDENCE_MODE,
    )
    args = parser.parse_args()
    manifest = export_xcresult(
        args.xcresult,
        args.output,
        desktop_version=args.desktop_version,
        desktop_build=args.desktop_build,
        evidence_mode=args.evidence_mode,
    )
    print(manifest)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
