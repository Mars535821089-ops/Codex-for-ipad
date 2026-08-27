#!/usr/bin/env python3
"""Group embedded desktop controls by file-level AppHost dependencies.

This is a prioritization audit, not runtime proof. A dependency is attributed
when a control and a direct AppHost call occur in the same official web asset;
the report does not claim that activating that control executes every call in
that asset.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import sys
from typing import Any

if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from scripts.audit_desktop_apphost_api import renderer_calls
from scripts.protocol_manifest import write_json_atomic


def _matched_asset_paths(control: dict[str, Any]) -> tuple[str, ...]:
    return tuple(sorted({
        str(evidence.get("path", ""))
        for evidence in control.get("assetEvidence", [])
        if isinstance(evidence, dict)
        and evidence.get("status") == "matched"
        and evidence.get("path")
    }))


def audit_control_apphost_dependencies(
    control_report: dict[str, Any],
    surface_sources: dict[str, str],
    official_services: tuple[str, ...],
    *,
    approved_calls: tuple[tuple[str, str], ...] | None = None,
) -> dict[str, Any]:
    approved = set(approved_calls) if approved_calls is not None else None
    calls_by_path = {
        path: tuple(
            call
            for call in renderer_calls(source, official_services)
            if approved is None or call in approved
        )
        for path, source in surface_sources.items()
    }
    controls: list[dict[str, Any]] = []
    service_groups: dict[str, dict[str, set[str]]] = {}
    all_calls: set[tuple[str, str]] = set()
    controls_with_dependencies = 0

    for source_control in control_report.get("controls", []):
        if not isinstance(source_control, dict):
            continue
        paths = _matched_asset_paths(source_control)
        dependency_methods: dict[str, set[str]] = {}
        dependency_assets: dict[str, set[str]] = {}
        for path in paths:
            for service, method in calls_by_path.get(path, ()):
                all_calls.add((service, method))
                dependency_methods.setdefault(service, set()).add(method)
                dependency_assets.setdefault(service, set()).add(path)

        dependencies = [
            {
                "service": service,
                "methods": sorted(dependency_methods[service]),
            }
            for service in sorted(dependency_methods)
        ]
        controls_with_dependencies += int(bool(dependencies))
        control_id = str(source_control.get("id", ""))
        surface_ids = {
            str(surface_id)
            for surface_id in source_control.get("surfaceIds", [])
            if surface_id
        }
        for dependency in dependencies:
            service = dependency["service"]
            group = service_groups.setdefault(
                service,
                {
                    "methods": set(),
                    "controlIds": set(),
                    "surfaceIds": set(),
                    "assets": set(),
                },
            )
            group["methods"].update(dependency["methods"])
            if control_id:
                group["controlIds"].add(control_id)
            group["surfaceIds"].update(surface_ids)
            group["assets"].update(dependency_assets[service])
        controls.append(
            {
                "id": control_id,
                "defaultMessage": source_control.get("defaultMessage", ""),
                "kind": source_control.get("kind", ""),
                "surfaceIds": sorted(surface_ids),
                "assetPaths": list(paths),
                "directAppHostDependencies": dependencies,
            }
        )

    unique_count = len(controls)
    return {
        "schemaVersion": 1,
        "desktopVersion": control_report.get("desktopVersion"),
        "desktopBuild": control_report.get("desktopBuild"),
        "staticEvidenceOnly": True,
        "attributionRule": (
            "control and direct AppHost call coexist in the same official web "
            "asset; this groups runtime-validation candidates and does not "
            "prove that activating the control executes every attributed call"
        ),
        "uniqueControlCount": unique_count,
        "controlsWithDirectAppHostDependencyCount": controls_with_dependencies,
        "controlsWithoutDirectAppHostDependencyCount": (
            unique_count - controls_with_dependencies
        ),
        "directAppHostCallCount": len(all_calls),
        "directAppHostServiceCount": len(service_groups),
        "serviceGroups": {
            service: {
                "methods": sorted(group["methods"]),
                "controlIds": sorted(group["controlIds"]),
                "controlCount": len(group["controlIds"]),
                "surfaceIds": sorted(group["surfaceIds"]),
                "assets": sorted(group["assets"]),
            }
            for service, group in sorted(service_groups.items())
        },
        "controls": controls,
    }


def _load_object(path: Path) -> dict[str, Any]:
    value = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise ValueError(f"expected JSON object: {path}")
    return value


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--control-report", type=Path, required=True)
    parser.add_argument("--apphost-report", type=Path, required=True)
    parser.add_argument("--surface-root", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    try:
        control_report = _load_object(args.control_report)
        apphost_report = _load_object(args.apphost_report)
        official_services = tuple(apphost_report["officialServices"])
        paths = {
            path
            for control in control_report.get("controls", [])
            if isinstance(control, dict)
            for path in _matched_asset_paths(control)
        }
        surface_sources = {
            path: (args.surface_root / path).read_text(
                encoding="utf-8", errors="replace"
            )
            for path in sorted(paths)
            if (args.surface_root / path).is_file()
        }
        report = audit_control_apphost_dependencies(
            control_report,
            surface_sources,
            official_services,
            approved_calls=tuple(
                (str(call["service"]), str(call["method"]))
                for call in apphost_report["directRendererCalls"]
            ),
        )
    except (KeyError, OSError, ValueError) as error:
        parser.error(str(error))
    write_json_atomic(args.output, report)
    print(args.output)
    print(
        f"controls-with-apphost="
        f"{report['controlsWithDirectAppHostDependencyCount']}/"
        f"{report['uniqueControlCount']} "
        f"services={report['directAppHostServiceCount']} "
        f"calls={report['directAppHostCallCount']}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
