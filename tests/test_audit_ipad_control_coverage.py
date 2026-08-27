from __future__ import annotations

import json
import hashlib
from pathlib import Path
import subprocess
import sys
import tempfile


def test_control_audit_deduplicates_and_separates_production_from_test_evidence() -> None:
    from scripts.audit_ipad_control_coverage import audit_controls

    asset = (
        b'const controls = [{id:"shared.cancel"},'
        b'{id:"missing.control"},{id:"test.only"}];\n'
    )
    recovered_sha256 = hashlib.sha256(b"formatted recovered source").hexdigest()

    def interaction(identifier: str, message: str, kind: str) -> dict[str, object]:
        return {
            "id": identifier,
            "defaultMessage": message,
            "kind": kind,
            "occurrences": [
                {
                    "file": "webview/assets/app.js",
                    "fileSha256": recovered_sha256,
                    "byteOffset": 100,
                }
            ],
        }

    inventory = {
        "desktopVersion": "26.810.52044",
        "desktopBuild": "6662",
        "sourceIdentity": {"desktopSurfaceTreeSha256": "abc"},
        "surfaces": [
            {
                "id": "S01",
                "interactions": [
                    interaction("shared.cancel", "Cancel", "button"),
                    interaction("missing.control", "Desktop only", "control"),
                ],
            },
            {
                "id": "S02",
                "interactions": [
                    interaction("shared.cancel", "Cancel", "button"),
                    interaction("test.only", "Observed only", "tooltip"),
                ],
            },
        ],
    }
    production = {
        "CodexSurfaces.swift": 'Button("Cancel") {}\nText("Unrelated")\n'
    }
    ui_tests = {
        "CodexPadParityCaptureUITests.swift": (
            'XCTAssertTrue(app.staticTexts["Cancel"].exists)\n'
            'XCTAssertTrue(app.staticTexts["Observed only"].exists)\n'
        )
    }

    report = audit_controls(
        inventory,
        {"assets/app.js": asset},
        production,
        ui_tests,
    )

    assert report["staticEvidenceOnly"] is True
    assert report["rawInteractionCount"] == 4
    assert report["uniqueInteractionCount"] == 3
    assert report["duplicateInteractionCount"] == 1
    assert report["assetMatchedCount"] == 3
    assert report["assetMissingCount"] == 0
    assert report["assetCoveragePercent"] == 100.0
    assert report["productionMatchedCount"] == 1
    assert report["uiTestMatchedCount"] == 2
    assert report["combinedMatchedCount"] == 2
    assert report["nativeOrTestUnreferencedCount"] == 1

    by_id = {row["id"]: row for row in report["controls"]}
    assert by_id["shared.cancel"]["surfaceIds"] == ["S01", "S02"]
    assert by_id["shared.cancel"]["assetStatus"] == "matched"
    assert by_id["test.only"]["assetStatus"] == "matched"
    assert by_id["missing.control"]["assetStatus"] == "matched"
    assert by_id["shared.cancel"]["nativeEvidenceStatus"] == "production-and-test"
    assert by_id["test.only"]["nativeEvidenceStatus"] == "test-only"
    assert by_id["missing.control"]["nativeEvidenceStatus"] == "unreferenced"
    assert by_id["shared.cancel"]["assetEvidence"][0]["idMatched"] is True
    assert (
        by_id["shared.cancel"]["assetEvidence"][0]["surfaceSha256"]
        != recovered_sha256
    )
    assert by_id["shared.cancel"]["productionEvidence"][0]["line"] == 1
    assert by_id["test.only"]["uiTestEvidence"][0]["line"] == 2


def test_control_audit_cli_writes_real_matched_and_missing_rows() -> None:
    root = Path(__file__).resolve().parents[1]
    with tempfile.TemporaryDirectory() as temporary:
        temporary_root = Path(temporary)
        inventory = temporary_root / "inventory.json"
        surface = temporary_root / "Surface"
        production = temporary_root / "Production"
        ui_tests = temporary_root / "UITests"
        output = temporary_root / "report.json"
        surface.mkdir()
        production.mkdir()
        ui_tests.mkdir()
        asset = b'const signIn = {id:"login.signIn", label:"Sign in"};\n'
        recovered_sha256 = hashlib.sha256(b"formatted fixture").hexdigest()
        (surface / "app.js").write_bytes(asset)
        inventory.write_text(
            json.dumps(
                {
                    "desktopVersion": "26.810.52044",
                    "desktopBuild": "6662",
                    "sourceIdentity": {"desktopSurfaceTreeSha256": "abc"},
                    "surfaces": [
                        {
                            "id": "S01",
                            "interactions": [
                                {
                                    "id": "login.signIn",
                                    "defaultMessage": "Sign in",
                                    "kind": "button",
                                    "occurrences": [{
                                        "file": "webview/app.js",
                                        "fileSha256": recovered_sha256,
                                        "byteOffset": 42,
                                    }],
                                },
                                {
                                    "id": "login.deviceCode",
                                    "defaultMessage": "Use device code",
                                    "kind": "button",
                                    "occurrences": [{
                                        "file": "webview/missing.js",
                                        "fileSha256": "0" * 64,
                                        "byteOffset": 0,
                                    }],
                                },
                            ],
                        }
                    ],
                }
            ),
            encoding="utf-8",
        )
        (production / "Login.swift").write_text(
            'Button("Sign in") {}\n', encoding="utf-8"
        )
        (ui_tests / "LoginUITests.swift").write_text(
            'app.buttons["Sign in"].tap()\n', encoding="utf-8"
        )

        result = subprocess.run(
            [
                sys.executable,
                str(root / "scripts/audit_ipad_control_coverage.py"),
                "--inventory",
                str(inventory),
                "--surface-root",
                str(surface),
                "--production-root",
                str(production),
                "--ui-test-root",
                str(ui_tests),
                "--output",
                str(output),
            ],
            text=True,
            capture_output=True,
            check=False,
        )

        assert result.returncode == 0, result.stderr
        report = json.loads(output.read_text(encoding="utf-8"))
        assert report["uniqueInteractionCount"] == 2
        assert report["assetMatchedCount"] == 1
        assert report["assetMissingCount"] == 1
        assert report["productionMatchedCount"] == 1
        assert report["nativeOrTestUnreferencedCount"] == 1
        assert "assets=1/2" in result.stdout
        assert "production=1/2" in result.stdout
        assert "asset-missing=1" in result.stdout


def test_control_audit_cli_can_gate_missing_embedded_assets() -> None:
    root = Path(__file__).resolve().parents[1]
    with tempfile.TemporaryDirectory() as temporary:
        temporary_root = Path(temporary)
        inventory = temporary_root / "inventory.json"
        surface = temporary_root / "Surface"
        production = temporary_root / "Production"
        ui_tests = temporary_root / "UITests"
        output = temporary_root / "report.json"
        surface.mkdir()
        production.mkdir()
        ui_tests.mkdir()
        inventory.write_text(
            json.dumps({
                "surfaces": [{
                    "id": "S01",
                    "interactions": [{
                        "id": "missing.control",
                        "defaultMessage": "Missing",
                        "kind": "button",
                        "occurrences": [{
                            "file": "webview/assets/missing.js",
                            "fileSha256": "0" * 64,
                            "byteOffset": 0,
                        }],
                    }],
                }],
            }),
            encoding="utf-8",
        )

        result = subprocess.run(
            [
                sys.executable,
                str(root / "scripts/audit_ipad_control_coverage.py"),
                "--inventory", str(inventory),
                "--surface-root", str(surface),
                "--production-root", str(production),
                "--ui-test-root", str(ui_tests),
                "--output", str(output),
                "--require-assets-complete",
            ],
            text=True,
            capture_output=True,
            check=False,
        )

        assert result.returncode == 1
        assert "embedded control assets are incomplete" in result.stderr
        assert json.loads(output.read_text())["assetMissingCount"] == 1
