#!/usr/bin/env python3
"""Build and content-anchor the exact signed Codex for ipad Release IPA."""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import stat
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any

if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from scripts.build_ipad_release import (
    ReleasePaths,
    build_release,
    load_release_identity,
    production_input_fingerprint,
)
from scripts.protocol_manifest import sha256_file
from scripts.release_identity import (
    ReleaseIdentity,
    require_matching_release_identity,
)


SHA256_PATTERN = re.compile(r"^[0-9a-f]{64}$")
TEAM_ID_PATTERN = re.compile(r"^[A-Z0-9]{10}$")
REQUIRED_VERIFICATION = (
    "bundleIdentityMatched",
    "codesignValid",
    "entitlementsValid",
    "provisioningProfileValid",
    "targetDeviceProvisioned",
)


def _read_object(path: Path, *, label: str) -> dict[str, Any]:
    if path.is_symlink() or not path.is_file():
        raise ValueError(f"{label} is missing")
    value = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise ValueError(f"{label} is malformed")
    return value


def _relative_project_file(
    project_root: Path,
    path: Path,
    *,
    label: str,
) -> tuple[Path, str]:
    project_root = project_root.resolve()
    path = path.resolve()
    try:
        relative = path.relative_to(project_root)
    except ValueError as error:
        raise ValueError(f"{label} escapes the project root") from error
    if path.is_symlink() or not path.is_file():
        raise ValueError(f"{label} is missing")
    return path, relative.as_posix()


def validate_release_gate(
    project_root: Path,
    identity: ReleaseIdentity,
    manifest_path: Path,
) -> dict[str, str]:
    """Verify the published manifest and IPA before updater commit."""
    project_root = project_root.resolve()
    manifest_path, manifest_relative = _relative_project_file(
        project_root,
        manifest_path,
        label="IPA release manifest",
    )
    expected_release_root = (
        project_root
        / "artifacts/ipad-release"
        / identity.version
        / identity.build
        / identity.dmg_sha256[:16]
    ).resolve()
    if manifest_path.parent != expected_release_root:
        raise ValueError(
            "IPA release manifest is outside its exact identity root"
        )
    manifest = _read_object(manifest_path, label="IPA release manifest")
    require_matching_release_identity(
        manifest,
        identity,
        label="IPA release manifest",
    )
    expected_production_fingerprint = production_input_fingerprint(
        project_root
    )
    recorded_production_fingerprint = manifest.get(
        "productionInputFingerprint"
    )
    if (
        not isinstance(recorded_production_fingerprint, str)
        or SHA256_PATTERN.fullmatch(recorded_production_fingerprint) is None
        or recorded_production_fingerprint != expected_production_fingerprint
    ):
        raise ValueError(
            "IPA release production input fingerprint does not match"
        )
    if (
        manifest.get("configuration") != "Release"
        or manifest.get("distributionMethod") != "debugging"
    ):
        raise ValueError("IPA release configuration is malformed")
    artifact = manifest.get("artifact")
    product = manifest.get("product")
    verification = manifest.get("verification")
    if (
        not isinstance(artifact, dict)
        or not isinstance(product, dict)
        or not isinstance(verification, dict)
    ):
        raise ValueError("IPA release evidence is malformed")
    if any(verification.get(key) is not True for key in REQUIRED_VERIFICATION):
        raise ValueError("IPA release signature or provisioning gate failed")
    if (
        product.get("architecture") != "arm64"
        or product.get("deviceFamily") != "iPad"
        or product.get("platform") != "iphoneos"
        or product.get("version") != identity.version
        or str(product.get("build", "")) != identity.build
    ):
        raise ValueError("IPA release product does not match the iPad identity")
    file_name = artifact.get("fileName")
    expected_hash = artifact.get("sha256")
    expected_size = artifact.get("sizeBytes")
    if (
        not isinstance(file_name, str)
        or not file_name.endswith(".ipa")
        or Path(file_name).name != file_name
        or not isinstance(expected_hash, str)
        or SHA256_PATTERN.fullmatch(expected_hash) is None
        or isinstance(expected_size, bool)
        or not isinstance(expected_size, int)
        or expected_size <= 0
        or artifact.get("zipIntegrity") is not True
    ):
        raise ValueError("IPA release artifact evidence is malformed")
    ipa_path, ipa_relative = _relative_project_file(
        project_root,
        manifest_path.parent / "export" / file_name,
        label="signed IPA",
    )
    actual_hash = sha256_file(ipa_path)
    if (
        ipa_path.stat().st_size != expected_size
        or actual_hash != expected_hash
    ):
        raise ValueError("signed IPA content does not match its release manifest")
    return {
        "ipaPath": ipa_relative,
        "ipaSha256": actual_hash,
        "ipaReleaseManifestPath": manifest_relative,
        "ipaReleaseManifestSha256": sha256_file(manifest_path),
    }


def _write_json_atomic(path: Path, value: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary: Path | None = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="w",
            encoding="utf-8",
            dir=path.parent,
            prefix=f".{path.name}.",
            delete=False,
        ) as stream:
            json.dump(value, stream, ensure_ascii=False, indent=2)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
            temporary = Path(stream.name)
        os.chmod(temporary, 0o600)
        os.replace(temporary, path)
    finally:
        if temporary is not None and temporary.exists():
            temporary.unlink()


def _discover_team_id() -> str:
    explicit = os.environ.get("DEVELOPMENT_TEAM", "")
    if TEAM_ID_PATTERN.fullmatch(explicit):
        return explicit
    result = subprocess.run(
        ["defaults", "export", "com.apple.dt.Xcode", "-"],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if result.returncode != 0:
        raise ValueError("Xcode developer team discovery failed")
    import plistlib

    payload = plistlib.loads(result.stdout)
    teams = payload.get("IDEProvisioningTeamByIdentifier", {})
    if isinstance(teams, dict):
        for entries in teams.values():
            if not isinstance(entries, list):
                continue
            for team in entries:
                if not isinstance(team, dict):
                    continue
                team_id = team.get("teamID")
                if (
                    (team.get("isFreeProvisioningTeam")
                     or team.get("teamType") == "Personal Team")
                    and isinstance(team_id, str)
                    and TEAM_ID_PATTERN.fullmatch(team_id)
                ):
                    return team_id
    raise ValueError("Xcode personal developer team is missing")


def load_target_device_id(project_root: Path) -> str:
    runtime = os.environ.get("CODEX_IPAD_TARGET_DEVICE_ID", "")
    if runtime:
        if runtime != runtime.strip() or "\n" in runtime:
            raise ValueError("runtime target device identifier is malformed")
        return runtime
    state_path = (
        project_root.resolve()
        / ".update-state/ipad-target-device-id"
    )
    if state_path.is_symlink() or not state_path.is_file():
        raise ValueError("private target device state is missing")
    if stat.S_IMODE(state_path.stat().st_mode) != 0o600:
        raise ValueError("private target device state must use mode 0600")
    value = state_path.read_text(encoding="utf-8").strip()
    if not value or any(character.isspace() for character in value):
        raise ValueError("private target device state is malformed")
    return value


def _remove_path(path: Path) -> None:
    if path.is_dir() and not path.is_symlink():
        shutil.rmtree(path)
    else:
        path.unlink()


def build_and_validate(
    project_root: Path,
    identity_record: Path,
    output_root: Path,
) -> dict[str, str]:
    identity = load_release_identity(identity_record.resolve())
    paths = ReleasePaths.for_identity(
        project_root.resolve(),
        output_root.resolve(),
        identity,
    )
    needs_build = not paths.root.exists()
    if not needs_build:
        try:
            return validate_release_gate(project_root, identity, paths.manifest)
        except (OSError, ValueError, json.JSONDecodeError):
            needs_build = True
    if needs_build:
        target_device_id = load_target_device_id(project_root)
        stale_root: Path | None = None
        if paths.root.exists() or paths.root.is_symlink():
            stale_root = Path(
                tempfile.mkdtemp(
                    prefix=f".{paths.root.name}.stale-",
                    dir=paths.root.parent,
                )
            )
            stale_root.rmdir()
            os.replace(paths.root, stale_root)
        try:
            build_release(
                paths,
                identity,
                team_id=_discover_team_id(),
                target_device_id=target_device_id,
                install_device=None,
            )
            result = validate_release_gate(
                project_root,
                identity,
                paths.manifest,
            )
        except BaseException:
            if paths.root.exists() or paths.root.is_symlink():
                _remove_path(paths.root)
            if stale_root is not None:
                os.replace(stale_root, paths.root)
            raise
        else:
            if stale_root is not None:
                _remove_path(stale_root)
            return result
    return validate_release_gate(project_root, identity, paths.manifest)


def main() -> int:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(required=True)
    build = subparsers.add_parser("build-and-validate")
    build.add_argument("--project-root", type=Path, required=True)
    build.add_argument("--identity-record", type=Path, required=True)
    build.add_argument("--output-root", type=Path, required=True)
    build.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    try:
        result = build_and_validate(
            args.project_root,
            args.identity_record,
            args.output_root,
        )
        _write_json_atomic(args.output, result)
    except (OSError, ValueError, json.JSONDecodeError) as error:
        parser.error(str(error))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
