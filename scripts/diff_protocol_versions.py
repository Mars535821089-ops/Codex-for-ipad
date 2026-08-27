from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Iterable

try:
    from .protocol_manifest import load_json_object, write_json_atomic
except ImportError:
    from protocol_manifest import load_json_object, write_json_atomic

BREAKING_KINDS = {
    "schema_file_removed",
    "required_property_added",
    "property_removed",
    "enum_value_removed",
    "type_narrowed",
    "schema_branch_removed",
}


def normalized_types(value: object) -> set[str]:
    if isinstance(value, str):
        return {value}
    if isinstance(value, list) and all(
        isinstance(item, str) for item in value
    ):
        return set(value)
    return set()


def _change(
    severity: str,
    kind: str,
    path: str,
    detail: str,
) -> dict[str, str]:
    return {
        "severity": severity,
        "kind": kind,
        "path": path,
        "detail": detail,
    }


def _string_set(value: object) -> set[str]:
    if isinstance(value, list) and all(
        isinstance(item, str) for item in value
    ):
        return set(value)
    return set()


def _json_values(value: object) -> set[str]:
    if not isinstance(value, list):
        return set()
    return {
        json.dumps(item, ensure_ascii=False, sort_keys=True)
        for item in value
    }


def _mapping(value: object) -> dict[str, object]:
    if not isinstance(value, dict):
        return {}
    return {
        str(key): item
        for key, item in value.items()
    }


def compare_schema(
    old: object,
    new: object,
    location: str = "$",
) -> list[dict[str, str]]:
    if not isinstance(old, dict) or not isinstance(new, dict):
        if old == new:
            return []
        return [
            _change(
                "informational",
                "value_changed",
                location,
                f"{old!r} -> {new!r}",
            )
        ]

    changes: list[dict[str, str]] = []

    old_types = normalized_types(old.get("type"))
    new_types = normalized_types(new.get("type"))
    if old_types and new_types and old_types != new_types:
        if new_types < old_types:
            changes.append(
                _change(
                    "breaking",
                    "type_narrowed",
                    location,
                    f"{sorted(old_types)} -> {sorted(new_types)}",
                )
            )
        elif old_types < new_types:
            changes.append(
                _change(
                    "compatible",
                    "type_widened",
                    location,
                    f"{sorted(old_types)} -> {sorted(new_types)}",
                )
            )
        else:
            changes.append(
                _change(
                    "breaking",
                    "type_narrowed",
                    location,
                    f"{sorted(old_types)} -> {sorted(new_types)}",
                )
            )

    old_enum = _json_values(old.get("enum"))
    new_enum = _json_values(new.get("enum"))
    for removed in sorted(old_enum - new_enum):
        changes.append(
            _change(
                "breaking",
                "enum_value_removed",
                location,
                f"removed {removed}",
            )
        )
    for added in sorted(new_enum - old_enum):
        changes.append(
            _change(
                "compatible",
                "enum_value_added",
                location,
                f"added {added}",
            )
        )

    old_properties = _mapping(old.get("properties"))
    new_properties = _mapping(new.get("properties"))
    old_required = _string_set(old.get("required"))
    new_required = _string_set(new.get("required"))

    for name in sorted(old_properties.keys() - new_properties.keys()):
        changes.append(
            _change(
                "breaking",
                "property_removed",
                f"{location}.{name}",
                "property is no longer present",
            )
        )
    for name in sorted(new_properties.keys() - old_properties.keys()):
        required = name in new_required
        changes.append(
            _change(
                "breaking" if required else "compatible",
                "required_property_added"
                if required
                else "optional_property_added",
                f"{location}.{name}",
                "new required property"
                if required
                else "new optional property",
            )
        )
    for name in sorted(old_properties.keys() & new_properties.keys()):
        changes.extend(
            compare_schema(
                old_properties[name],
                new_properties[name],
                f"{location}.{name}",
            )
        )

    for name in sorted(
        (new_required - old_required) & old_properties.keys()
    ):
        changes.append(
            _change(
                "breaking",
                "required_property_added",
                f"{location}.{name}",
                "existing property became required",
            )
        )
    for name in sorted(old_required - new_required):
        changes.append(
            _change(
                "compatible",
                "required_property_removed",
                f"{location}.{name}",
                "property is no longer required",
            )
        )

    for keyword in ("items",):
        if keyword in old and keyword in new:
            changes.extend(
                compare_schema(
                    old[keyword],
                    new[keyword],
                    f"{location}.{keyword}",
                )
            )

    for keyword in ("$defs", "definitions"):
        old_definitions = _mapping(old.get(keyword))
        new_definitions = _mapping(new.get(keyword))
        for name in sorted(old_definitions.keys() - new_definitions.keys()):
            changes.append(
                _change(
                    "breaking",
                    "schema_definition_removed",
                    f"{location}.{keyword}.{name}",
                    "schema definition removed",
                )
            )
        for name in sorted(new_definitions.keys() - old_definitions.keys()):
            changes.append(
                _change(
                    "compatible",
                    "schema_definition_added",
                    f"{location}.{keyword}.{name}",
                    "schema definition added",
                )
            )
        for name in sorted(
            old_definitions.keys() & new_definitions.keys()
        ):
            changes.extend(
                compare_schema(
                    old_definitions[name],
                    new_definitions[name],
                    f"{location}.{keyword}.{name}",
                )
            )

    for keyword in ("oneOf", "anyOf"):
        old_branches = old.get(keyword)
        new_branches = new.get(keyword)
        if not isinstance(old_branches, list) or not isinstance(
            new_branches,
            list,
        ):
            continue
        shared = min(len(old_branches), len(new_branches))
        for index in range(shared):
            changes.extend(
                compare_schema(
                    old_branches[index],
                    new_branches[index],
                    f"{location}.{keyword}[{index}]",
                )
            )
        for index in range(shared, len(old_branches)):
            changes.append(
                _change(
                    "breaking",
                    "schema_branch_removed",
                    f"{location}.{keyword}[{index}]",
                    "schema branch removed",
                )
            )
        for index in range(shared, len(new_branches)):
            changes.append(
                _change(
                    "compatible",
                    "schema_branch_added",
                    f"{location}.{keyword}[{index}]",
                    "schema branch added",
                )
            )

    return changes


def _json_files(root: Path) -> dict[str, Path]:
    if not root.is_dir():
        raise ValueError(f"schema directory missing: {root}")
    return {
        path.relative_to(root).as_posix(): path
        for path in sorted(root.rglob("*.json"))
        if path.is_file()
    }


def _sorted_changes(
    changes: Iterable[dict[str, str]],
) -> list[dict[str, str]]:
    return sorted(
        changes,
        key=lambda item: (
            item["path"],
            item["kind"],
            item["detail"],
        ),
    )


def compare_directories(
    old_root: Path,
    new_root: Path,
) -> dict[str, object]:
    old_files = _json_files(old_root)
    new_files = _json_files(new_root)
    changes: list[dict[str, str]] = []

    for relative in sorted(old_files.keys() - new_files.keys()):
        changes.append(
            _change(
                "breaking",
                "schema_file_removed",
                relative,
                "schema file removed",
            )
        )
    for relative in sorted(new_files.keys() - old_files.keys()):
        changes.append(
            _change(
                "compatible",
                "schema_file_added",
                relative,
                "schema file added",
            )
        )
    for relative in sorted(old_files.keys() & new_files.keys()):
        old = load_json_object(old_files[relative])
        new = load_json_object(new_files[relative])
        changes.extend(compare_schema(old, new))

    breaking = _sorted_changes(
        item for item in changes if item["severity"] == "breaking"
    )
    compatible = _sorted_changes(
        item for item in changes if item["severity"] == "compatible"
    )
    informational = _sorted_changes(
        item
        for item in changes
        if item["severity"] == "informational"
    )
    return {
        "blocked": bool(breaking),
        "oldFileCount": len(old_files),
        "newFileCount": len(new_files),
        "breaking": breaking,
        "compatible": compatible,
        "informational": informational,
    }


def _markdown_section(
    title: str,
    changes: list[dict[str, str]],
) -> list[str]:
    lines = [f"## {title} ({len(changes)})", ""]
    if not changes:
        return lines + ["- None", ""]
    for change in changes:
        lines.append(
            f"- `{change['kind']}` at `{change['path']}`: "
            f"{change['detail']}"
        )
    return lines + [""]


def write_markdown(path: Path, report: dict[str, object]) -> None:
    lines = [
        "# Codex App Server Protocol Compatibility",
        "",
        f"Blocked: `{str(report['blocked']).lower()}`",
        "",
    ]
    lines.extend(
        _markdown_section(
            "Breaking changes",
            report["breaking"],
        )
    )
    lines.extend(
        _markdown_section(
            "Compatible changes",
            report["compatible"],
        )
    )
    lines.extend(
        _markdown_section(
            "Informational changes",
            report["informational"],
        )
    )
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n".join(lines), encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--old", required=True, type=Path)
    parser.add_argument("--new", required=True, type=Path)
    parser.add_argument("--json-out", required=True, type=Path)
    parser.add_argument("--markdown-out", required=True, type=Path)
    args = parser.parse_args()
    try:
        report = compare_directories(args.old, args.new)
        write_json_atomic(args.json_out, report)
        write_markdown(args.markdown_out, report)
    except (OSError, ValueError, json.JSONDecodeError) as error:
        print(f"protocol diff failed: {error}")
        return 1
    return 2 if report["blocked"] else 0


if __name__ == "__main__":
    raise SystemExit(main())
