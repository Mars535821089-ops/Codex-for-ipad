#!/usr/bin/env python3
"""Persist a non-promoted iPad release stage without claiming device verification."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import tempfile

from typing import Any

if __package__ in (None, ""):
    import sys
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from scripts.ipad_verification_evidence import _tree_sha256
from scripts.release_identity import ReleaseIdentity

STAGE_SCHEMA_VERSION = 1
STAGE_ROOT = Path(".update-state") / "staged-releases"


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _relative_package(root: Path, package: Path) -> str:
    package = package.resolve()
    downloads = (root / ".downloads").resolve()
    try:
        relative = package.relative_to(downloads)
    except ValueError as error:
        raise ValueError("staged package must be inside .downloads") from error
    if not relative.parts or any(part in {"", ".", ".."} for part in relative.parts):
        raise ValueError("staged package path is malformed")
    return (Path(".downloads") / relative).as_posix()


def _stage_path(root: Path, identity: ReleaseIdentity) -> Path:
    return root / STAGE_ROOT / identity.version / identity.build / f"{identity.dmg_sha256}.json"


def write_stage(root: Path, package: Path, static_record: Path) -> Path:
    root = root.resolve()
    package = package.resolve()
    static_record = static_record.resolve()
    if not package.is_file():
        raise ValueError("staged official package is missing")
    if not static_record.is_file():
        raise ValueError("static validation record is missing")
    record = json.loads(static_record.read_text(encoding="utf-8"))
    if not isinstance(record, dict) or record.get("validationMode") != "static":
        raise ValueError("static validation record is not a static result")
    if record.get("status") != "passed" or record.get("physicalDeviceTests") != "not-run":
        raise ValueError("static validation record must be passed with physical tests not-run")
    version = record.get("desktopVersion")
    build = record.get("desktopBuild")
    source = record.get("sourceIdentity")
    if not isinstance(source, dict):
        raise ValueError("static validation source identity is missing")
    identity = ReleaseIdentity(version, build, source.get("dmgSha256"))
    package_hash = _sha256(package)
    if package_hash != identity.dmg_sha256:
        raise ValueError("staged package hash does not match static validation")
    relative_package = _relative_package(root, package)
    stage = _stage_path(root, identity)
    payload: dict[str, Any] = {
        "schemaVersion": STAGE_SCHEMA_VERSION,
        "status": "staged",
        "promotion": "requires-physical-acceptance",
        "transferCleanup": "deferred",
        "version": identity.version,
        "build": identity.build,
        "dmgSha256": identity.dmg_sha256,
        "packagePath": relative_package,
        "staticValidationPath": static_record.relative_to(root).as_posix(),
        "physicalDeviceTests": "not-run",
        "sourceIdentity": {"dmgSha256": identity.dmg_sha256},
    }
    stage.parent.mkdir(parents=True, exist_ok=True)
    temporary: Path | None = None
    try:
        with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", dir=stage.parent, prefix=f".{stage.name}.", delete=False) as stream:
            json.dump(payload, stream, ensure_ascii=False, indent=2)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
            temporary = Path(stream.name)
        os.replace(temporary, stage)
    finally:
        if temporary is not None and temporary.exists():
            temporary.unlink()
    return stage


def validate_stage(root: Path, stage: Path) -> dict[str, Any]:
    root = root.resolve()
    stage = stage.resolve()
    if stage.is_symlink() or not stage.is_file():
        raise ValueError("staged release record is missing")
    payload = json.loads(stage.read_text(encoding="utf-8"))
    if not isinstance(payload, dict) or payload.get("schemaVersion") != STAGE_SCHEMA_VERSION:
        raise ValueError("staged release record is malformed")
    identity = ReleaseIdentity(payload.get("version"), payload.get("build"), payload.get("dmgSha256"))
    package = (root / payload.get("packagePath", "")).resolve()
    if package.parent != (root / ".downloads").resolve():
        raise ValueError("staged package escapes .downloads")
    if not package.is_file() or _sha256(package) != identity.dmg_sha256:
        raise ValueError("staged package is missing or has changed")
    if payload.get("status") != "staged" or payload.get("promotion") != "requires-physical-acceptance":
        raise ValueError("staged release is not awaiting physical acceptance")
    if payload.get("physicalDeviceTests") != "not-run":
        raise ValueError("staged release cannot claim physical verification")
    return payload



def _read_json(path: Path, label: str) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise ValueError(f"{label} is malformed") from error
    if not isinstance(value, dict):
        raise ValueError(f"{label} is malformed")
    return value


def _require_evidence(root: Path, verification: dict[str, Any]) -> None:
    xcui = verification.get("xcuiEvidence")
    if not isinstance(xcui, dict):
        raise ValueError("physical verification evidence is missing")
    xcresult = xcui.get("xcresult")
    if not isinstance(xcresult, dict):
        raise ValueError("physical verification xcresult evidence is missing")
    xcresult_path = root / str(xcresult.get("path", ""))
    if not xcresult_path.is_dir() or xcresult_path.is_symlink():
        raise ValueError("physical verification xcresult evidence is missing")
    expected_tree_hash = xcresult.get("sha256")
    if not isinstance(expected_tree_hash, str) or _tree_sha256(xcresult_path) != expected_tree_hash:
        raise ValueError("physical verification xcresult evidence does not match")
    logs = xcui.get("logs")
    if not isinstance(logs, dict) or not logs:
        raise ValueError("physical verification logs are missing")
    for name, item in logs.items():
        if not isinstance(item, dict):
            raise ValueError(f"physical verification log is malformed: {name}")
        path = root / str(item.get("path", ""))
        expected = item.get("sha256")
        if not path.is_file() or not isinstance(expected, str) or _sha256(path) != expected:
            raise ValueError(f"physical verification log does not match: {name}")
    surface = verification.get("desktopSurface")
    if not isinstance(surface, dict) or surface.get("deviceBundleVerified") is not True:
        raise ValueError("physical verification desktop surface evidence is missing")


def promote_stage(root: Path, stage: Path, verification_path: Path) -> dict[str, Any]:
    root = root.resolve()
    stage = stage.resolve()
    verification_path = verification_path.resolve()
    payload = validate_stage(root, stage)
    if not verification_path.is_file():
        raise ValueError("physical verification record is missing")
    verification = _read_json(verification_path, "physical verification record")
    identity = ReleaseIdentity(payload.get("version"), payload.get("build"), payload.get("dmgSha256"))
    try:
        actual = ReleaseIdentity(verification.get("desktopVersion"), verification.get("desktopBuild"), verification.get("sourceIdentity", {}).get("dmgSha256"))
    except (AttributeError, ValueError) as error:
        raise ValueError("physical verification release identity is malformed") from error
    if actual != identity:
        raise ValueError("physical verification does not match staged release")
    if verification.get("physicalDeviceTests") != "passed":
        raise ValueError("physical verification must be passed")
    if not isinstance(verification.get("physicalDeviceUDID"), str) or not verification.get("physicalDeviceUDID"):
        raise ValueError("physical verification device identity is missing")
    if verification.get("deviceArchitecture") != "arm64":
        raise ValueError("physical verification device architecture is not arm64")
    _require_evidence(root, verification)
    promoted = dict(payload)
    promoted.update({
        "status": "promoted",
        "promotion": "ready-for-archive",
        "physicalDeviceTests": "passed",
        "physicalDeviceUDID": verification["physicalDeviceUDID"],
        "physicalAcceptancePath": verification_path.relative_to(root).as_posix(),
    })
    temporary: Path | None = None
    try:
        with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", dir=stage.parent, prefix=f".{stage.name}.", suffix=".tmp", delete=False) as stream:
            json.dump(promoted, stream, ensure_ascii=False, indent=2)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
            temporary = Path(stream.name)
        os.replace(temporary, stage)
    finally:
        if temporary is not None and temporary.exists():
            temporary.unlink()
    return promoted

def main() -> int:
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)
    stage = sub.add_parser("stage")
    stage.add_argument("--project-root", type=Path, required=True)
    stage.add_argument("--package", type=Path, required=True)
    stage.add_argument("--static-record", type=Path, required=True)
    verify = sub.add_parser("verify")
    verify.add_argument("--project-root", type=Path, required=True)
    verify.add_argument("--stage", type=Path, required=True)
    promote = sub.add_parser("promote")
    promote.add_argument("--project-root", type=Path, required=True)
    promote.add_argument("--stage", type=Path, required=True)
    promote.add_argument("--verification", type=Path, required=True)
    args = parser.parse_args()
    if args.command == "stage":
        print(write_stage(args.project_root, args.package, args.static_record))
    elif args.command == "verify":
        json.dump(validate_stage(args.project_root, args.stage), sys.stdout, ensure_ascii=False)
        print()
    else:
        json.dump(promote_stage(args.project_root, args.stage, args.verification), sys.stdout, ensure_ascii=False)
        print()
    return 0


if __name__ == "__main__":
    import sys
    raise SystemExit(main())
