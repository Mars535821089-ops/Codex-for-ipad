from __future__ import annotations


def test_dependency_audit_groups_controls_by_file_level_apphost_calls() -> None:
    from scripts.audit_ipad_control_apphost_dependencies import (
        audit_control_apphost_dependencies,
    )

    control_report = {
        "desktopVersion": "26.810.52044",
        "desktopBuild": "6662",
        "controls": [
            {
                "id": "clipboard.copy",
                "defaultMessage": "Copy",
                "kind": "button",
                "surfaceIds": ["S04"],
                "assetEvidence": [
                    {"path": "assets/conversation.js", "status": "matched"}
                ],
            },
            {
                "id": "settings.open",
                "defaultMessage": "Settings",
                "kind": "button",
                "surfaceIds": ["S08"],
                "assetEvidence": [
                    {"path": "assets/settings.js", "status": "matched"}
                ],
            },
        ],
    }
    surface_sources = {
        "assets/conversation.js": (
            "const host=await bridge.services;"
            "host.clipboard.writeText();host.clipboard.readText();"
            "host.appInfo.fixtureOnlyFalsePositive();"
        ),
        "assets/settings.js": 'const id="settings.open";',
    }

    report = audit_control_apphost_dependencies(
        control_report,
        surface_sources,
        ("clipboard", "appInfo"),
        approved_calls=(
            ("clipboard", "readText"),
            ("clipboard", "writeText"),
        ),
    )

    assert report["staticEvidenceOnly"] is True
    assert report["uniqueControlCount"] == 2
    assert report["controlsWithDirectAppHostDependencyCount"] == 1
    assert report["controlsWithoutDirectAppHostDependencyCount"] == 1
    assert report["directAppHostCallCount"] == 2
    clipboard = report["serviceGroups"]["clipboard"]
    assert clipboard["methods"] == ["readText", "writeText"]
    assert clipboard["controlIds"] == ["clipboard.copy"]
    assert clipboard["surfaceIds"] == ["S04"]
    by_id = {row["id"]: row for row in report["controls"]}
    assert by_id["clipboard.copy"]["directAppHostDependencies"] == [
        {"service": "clipboard", "methods": ["readText", "writeText"]}
    ]
    assert by_id["settings.open"]["directAppHostDependencies"] == []
