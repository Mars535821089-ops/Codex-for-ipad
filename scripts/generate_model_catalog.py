#!/usr/bin/env python3
"""Generate lossless iPad model-catalog snapshots from official models.json."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
from pathlib import Path
from typing import Any, Optional


KNOWN_EFFORTS = {
    "none",
    "minimal",
    "low",
    "medium",
    "high",
    "xhigh",
    "max",
    "ultra",
}
INPUT_MODALITIES = {"text", "image", "audio"}
VISIBILITIES = {"list", "hide", "none"}


def _swift_string(value: str) -> str:
    return json.dumps(value, ensure_ascii=False)


def _swift_optional_string(value: Optional[str]) -> str:
    return "nil" if value is None else _swift_string(value)


def _nonempty_string(value: object, field: str) -> str:
    if not isinstance(value, str) or not value:
        raise ValueError(f"{field} must be a non-empty string")
    return value


def _optional_string(value: object, field: str) -> Optional[str]:
    if value is None:
        return None
    return _nonempty_string(value, field)


def _supports_personality(raw: dict[str, object]) -> bool:
    messages = raw.get("model_messages")
    if not isinstance(messages, dict):
        return False
    template = messages.get("instructions_template")
    variables = messages.get("instructions_variables")
    if not isinstance(template, str) or "{{ personality }}" not in template:
        return False
    if not isinstance(variables, dict):
        return False
    return all(
        isinstance(variables.get(key), str)
        for key in (
            "personality_default",
            "personality_friendly",
            "personality_pragmatic",
        )
    )


def _reasoning_options(
    raw: dict[str, object],
    model_id: str,
) -> list[dict[str, str]]:
    levels = raw.get("supported_reasoning_levels", [])
    if not isinstance(levels, list):
        raise ValueError(
            f"supported_reasoning_levels must be an array for {model_id}"
        )
    options: list[dict[str, str]] = []
    for index, level in enumerate(levels):
        if not isinstance(level, dict):
            raise ValueError(
                f"reasoning option {index} must be an object for {model_id}"
            )
        effort = _nonempty_string(
            level.get("effort"),
            f"reasoning option {index} effort for {model_id}",
        )
        description = level.get("description", "")
        if not isinstance(description, str):
            raise ValueError(
                f"reasoning option {index} description must be a string "
                f"for {model_id}"
            )
        options.append(
            {
                "reasoningEffort": effort,
                "description": description,
            }
        )
    return options


def _input_modalities(
    raw: dict[str, object],
    model_id: str,
) -> list[str]:
    values = raw.get("input_modalities", ["text", "image"])
    if not isinstance(values, list):
        raise ValueError(f"input_modalities must be an array for {model_id}")
    modalities: list[str] = []
    for value in values:
        if value not in INPUT_MODALITIES:
            raise ValueError(f"unsupported input modality for {model_id}: {value}")
        modalities.append(str(value))
    return modalities


def _service_tiers(
    raw: dict[str, object],
    model_id: str,
) -> list[dict[str, str]]:
    values = raw.get("service_tiers", [])
    if not isinstance(values, list):
        raise ValueError(f"service_tiers must be an array for {model_id}")
    tiers: list[dict[str, str]] = []
    for index, value in enumerate(values):
        if not isinstance(value, dict):
            raise ValueError(
                f"service tier {index} must be an object for {model_id}"
            )
        tiers.append(
            {
                "id": _nonempty_string(
                    value.get("id"),
                    f"service tier {index} id for {model_id}",
                ),
                "name": _nonempty_string(
                    value.get("name"),
                    f"service tier {index} name for {model_id}",
                ),
                "description": _nonempty_string(
                    value.get("description"),
                    f"service tier {index} description for {model_id}",
                ),
            }
        )
    return tiers


def _upgrade_info(
    raw: dict[str, object],
    model_id: str,
) -> tuple[Optional[str], Optional[dict[str, Optional[str]]]]:
    upgrade = raw.get("upgrade")
    if upgrade is None:
        return None, None
    if not isinstance(upgrade, dict):
        raise ValueError(f"upgrade must be an object for {model_id}")
    target = _nonempty_string(
        upgrade.get("model"),
        f"upgrade model for {model_id}",
    )
    migration_markdown = upgrade.get("migration_markdown")
    if migration_markdown is not None and not isinstance(
        migration_markdown,
        str,
    ):
        raise ValueError(
            f"upgrade migration_markdown must be a string for {model_id}"
        )
    return target, {
        "model": target,
        "upgradeCopy": None,
        "modelLink": None,
        "migrationMarkdown": migration_markdown,
    }


def _normalize_models(document: dict[str, object]) -> list[dict[str, Any]]:
    raw_models = document.get("models")
    if not isinstance(raw_models, list):
        raise ValueError("official models.json has no models array")

    models: list[dict[str, Any]] = []
    priorities: dict[str, int] = {}
    for raw in raw_models:
        if not isinstance(raw, dict):
            raise ValueError("every official model must be an object")
        model_id = _nonempty_string(raw.get("slug"), "model slug")
        if model_id in priorities:
            raise ValueError(f"duplicate model slug: {model_id}")
        display_name = _nonempty_string(
            raw.get("display_name"),
            f"display_name for {model_id}",
        )
        description = raw.get("description")
        if description is None:
            description = ""
        if not isinstance(description, str):
            raise ValueError(f"description must be a string for {model_id}")

        default_effort = raw.get("default_reasoning_level")
        if default_effort is None:
            default_effort = "none"
        default_effort = _nonempty_string(
            default_effort,
            f"default_reasoning_level for {model_id}",
        )
        visibility = raw.get("visibility")
        if visibility not in VISIBILITIES:
            raise ValueError(f"unsupported visibility for {model_id}: {visibility}")
        priority = raw.get("priority", 1_000_000)
        if not isinstance(priority, int) or isinstance(priority, bool):
            raise ValueError(f"priority must be an integer for {model_id}")

        additional_speed_tiers = raw.get("additional_speed_tiers", [])
        if (
            not isinstance(additional_speed_tiers, list)
            or not all(isinstance(value, str) for value in additional_speed_tiers)
        ):
            raise ValueError(
                f"additional_speed_tiers must be a string array for {model_id}"
            )
        default_service_tier = _optional_string(
            raw.get("default_service_tier"),
            f"default_service_tier for {model_id}",
        )
        availability = raw.get("availability_nux")
        if availability is None:
            availability_nux = None
        elif isinstance(availability, dict):
            availability_nux = {
                "message": _nonempty_string(
                    availability.get("message"),
                    f"availability_nux message for {model_id}",
                )
            }
        else:
            raise ValueError(f"availability_nux must be an object for {model_id}")
        upgrade, upgrade_info = _upgrade_info(raw, model_id)

        priorities[model_id] = priority
        models.append(
            {
                "id": model_id,
                "model": model_id,
                "upgrade": upgrade,
                "upgradeInfo": upgrade_info,
                "availabilityNux": availability_nux,
                "displayName": display_name,
                "description": description,
                "hidden": visibility != "list",
                "supportedReasoningEfforts": _reasoning_options(raw, model_id),
                "defaultReasoningEffort": default_effort,
                "inputModalities": _input_modalities(raw, model_id),
                "supportsPersonality": _supports_personality(raw),
                "additionalSpeedTiers": list(additional_speed_tiers),
                "serviceTiers": _service_tiers(raw, model_id),
                "defaultServiceTier": default_service_tier,
                "isDefault": False,
            }
        )

    models.sort(key=lambda model: (priorities[str(model["id"])], str(model["id"])))
    if models:
        default = next(
            (model for model in models if not model["hidden"]),
            models[0],
        )
        default["isDefault"] = True
    return models


def _effort_expression(effort: str) -> str:
    if effort in KNOWN_EFFORTS:
        return f".{effort}"
    return f"CodexReasoningEffort(rawValue: {_swift_string(effort)})!"


def _render_reasoning_options(options: list[dict[str, str]]) -> str:
    if not options:
        return "[]"
    entries = [
        (
            ".init(reasoningEffort: %s, description: %s)"
            % (
                _effort_expression(option["reasoningEffort"]),
                _swift_string(option["description"]),
            )
        )
        for option in options
    ]
    return "[\n                " + ",\n                ".join(entries) + ",\n            ]"


def _render_service_tiers(tiers: list[dict[str, str]]) -> str:
    if not tiers:
        return "[]"
    entries = [
        (
            ".init(id: %s, name: %s, description: %s)"
            % (
                _swift_string(tier["id"]),
                _swift_string(tier["name"]),
                _swift_string(tier["description"]),
            )
        )
        for tier in tiers
    ]
    return "[\n                " + ",\n                ".join(entries) + ",\n            ]"


def _render_upgrade_info(
    value: Optional[dict[str, Optional[str]]],
) -> str:
    if value is None:
        return "nil"
    return (
        ".init(\n"
        f"                model: {_swift_string(str(value['model']))},\n"
        f"                upgradeCopy: {_swift_optional_string(value['upgradeCopy'])},\n"
        f"                modelLink: {_swift_optional_string(value['modelLink'])},\n"
        "                migrationMarkdown: "
        f"{_swift_optional_string(value['migrationMarkdown'])}\n"
        "            )"
    )


def _render_availability(value: Optional[dict[str, str]]) -> str:
    if value is None:
        return "nil"
    return f".init(message: {_swift_string(value['message'])})"


def _render_swift(models: list[dict[str, Any]], version: str) -> str:
    entries: list[str] = []
    for model in models:
        modalities = ", ".join(
            f".{modality}" for modality in model["inputModalities"]
        )
        speeds = ", ".join(
            _swift_string(value) for value in model["additionalSpeedTiers"]
        )
        entries.append(
            """\
        .init(
            id: %s,
            model: %s,
            upgrade: %s,
            upgradeInfo: %s,
            availabilityNux: %s,
            displayName: %s,
            description: %s,
            hidden: %s,
            reasoningEffortOptions: %s,
            defaultReasoningEffort: %s,
            inputModalities: [%s],
            supportsPersonality: %s,
            additionalSpeedTiers: [%s],
            serviceTiers: %s,
            defaultServiceTier: %s,
            isDefault: %s
        )"""
            % (
                _swift_string(model["id"]),
                _swift_string(model["model"]),
                _swift_optional_string(model["upgrade"]),
                _render_upgrade_info(model["upgradeInfo"]),
                _render_availability(model["availabilityNux"]),
                _swift_string(model["displayName"]),
                _swift_string(model["description"]),
                str(model["hidden"]).lower(),
                _render_reasoning_options(model["supportedReasoningEfforts"]),
                _effort_expression(model["defaultReasoningEffort"]),
                modalities,
                str(model["supportsPersonality"]).lower(),
                speeds,
                _render_service_tiers(model["serviceTiers"]),
                _swift_optional_string(model["defaultServiceTier"]),
                str(model["isDefault"]).lower(),
            )
        )
    return """\
// Generated from the complete official Codex model catalog for desktop build %s.
// Runtime model selection uses model/list; this is a versioned fallback snapshot.
// Regenerated by scripts/generate_model_catalog.py during every upgrade.
extension CodexModelCatalog {
    public static let current: [CodexModelConfiguration] = [
%s
    ]
}
""" % (version, ",\n".join(entries))


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--json-output", type=Path, required=True)
    parser.add_argument("--swift-output", type=Path, required=True)
    parser.add_argument("--rust-json-output", type=Path)
    parser.add_argument("--official-cargo-toml", type=Path)
    parser.add_argument("--rust-client-version-output", type=Path)
    args = parser.parse_args()

    if (args.official_cargo_toml is None) != (
        args.rust_client_version_output is None
    ):
        raise ValueError(
            "official Cargo.toml and Rust client-version output must be provided together"
        )

    raw_source = args.source.read_bytes()
    document = json.loads(raw_source)
    if not isinstance(document, dict):
        raise ValueError("official models.json must be an object")
    models = _normalize_models(document)
    if not models:
        raise ValueError("official model catalog has no models")

    args.json_output.parent.mkdir(parents=True, exist_ok=True)
    args.swift_output.parent.mkdir(parents=True, exist_ok=True)
    args.json_output.write_text(
        json.dumps(
            {
                "schemaVersion": 2,
                "desktopVersion": args.version,
                "source": {
                    "path": str(args.source),
                    "sha256": hashlib.sha256(raw_source).hexdigest(),
                    "modelCount": len(models),
                },
                "models": models,
            },
            ensure_ascii=False,
            indent=2,
        )
        + "\n",
        encoding="utf-8",
    )
    args.swift_output.write_text(
        _render_swift(models, args.version),
        encoding="utf-8",
    )
    if args.rust_json_output is not None:
        args.rust_json_output.parent.mkdir(parents=True, exist_ok=True)
        args.rust_json_output.write_bytes(raw_source)
    if args.official_cargo_toml is not None:
        cargo_text = args.official_cargo_toml.read_text(encoding="utf-8")
        workspace_package = re.search(
            r"(?ms)^\[workspace\.package\]\s*(.*?)(?=^\[|\Z)",
            cargo_text,
        )
        if workspace_package is None:
            raise ValueError("official Cargo.toml has no workspace.package table")
        version_match = re.search(
            r'(?m)^version\s*=\s*"([^"]+)"\s*$',
            workspace_package.group(1),
        )
        if version_match is None:
            raise ValueError("official Cargo.toml has no workspace package version")
        client_version = version_match.group(1)
        if re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+(?:[-+][0-9A-Za-z.-]+)?", client_version) is None:
            raise ValueError("official Codex client version is malformed")
        args.rust_client_version_output.parent.mkdir(parents=True, exist_ok=True)
        args.rust_client_version_output.write_text(client_version, encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
