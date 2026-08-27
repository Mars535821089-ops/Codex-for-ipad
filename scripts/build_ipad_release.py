#!/usr/bin/env python3
"""Archive, export, and offline-verify a Release IPA for Codex for ipad."""

from __future__ import annotations

import argparse
from dataclasses import dataclass
import datetime as dt
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
from typing import Any, Callable, Sequence
import zipfile

if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from scripts.protocol_manifest import (
    load_json_object,
    sha256_file,
    write_json_atomic,
)
from scripts.release_identity import ReleaseIdentity


PRODUCT_NAME = "Codex for ipad"
BUNDLE_IDENTIFIER = "dev.codexforipad.app"
SCHEME = "CodexPad"
MANIFEST_SCHEMA_VERSION = 1
TEAM_ID_PATTERN = re.compile(r"^[A-Z0-9]{10}$")
CommandRunner = Callable[..., bytes]
ProjectSyncChecker = Callable[[Path, ReleaseIdentity], None]


def _production_input_roots(project_root: Path) -> tuple[tuple[str, Path], ...]:
    """Return the source/configuration inputs that determine the IPA payload."""
    return (
        ("CodexPad/CodexPad", project_root / "CodexPad/CodexPad"),
        (
            "CodexPad/CodexPad.xcodeproj/project.pbxproj",
            project_root / "CodexPad/CodexPad.xcodeproj/project.pbxproj",
        ),
        (
            "CodexPad/CodexPythonRuntimeBridge",
            project_root / "CodexPad/CodexPythonRuntimeBridge",
        ),
        ("CodexPad/Package.swift", project_root / "CodexPad/Package.swift"),
        (
            "CodexPad/Vendor/runtime-lock.json",
            project_root / "CodexPad/Vendor/runtime-lock.json",
        ),
        (
            "CodexPad/CodexPad/Application/Resources/MCPPackages/runtime-lock.json",
            project_root
            / "CodexPad/CodexPad/Application/Resources/MCPPackages/runtime-lock.json",
        ),
        (
            "CodexPad/CodexPad/Application/Resources/PythonPackages/runtime-lock.json",
            project_root
            / "CodexPad/CodexPad/Application/Resources/PythonPackages/runtime-lock.json",
        ),
        ("CodexCore/Cargo.toml", project_root / "CodexCore/Cargo.toml"),
        ("CodexCore/Cargo.lock", project_root / "CodexCore/Cargo.lock"),
        ("CodexCore/src", project_root / "CodexCore/src"),
        ("CodexCore/resources", project_root / "CodexCore/resources"),
        ("CodexCore/vendor", project_root / "CodexCore/vendor"),
    )


def production_input_fingerprint(project_root: Path) -> str:
    """Hash current Swift/Rust production inputs without build products."""
    project_root = project_root.resolve()
    digest = hashlib.sha256()

    def add(kind: str, relative: str, payload: bytes = b"") -> None:
        digest.update(kind.encode("ascii"))
        digest.update(b"\0")
        digest.update(relative.encode("utf-8"))
        digest.update(b"\0")
        digest.update(payload)
        digest.update(b"\n")

    for relative_root, root in _production_input_roots(project_root):
        if root.is_symlink():
            add("symlink", relative_root, os.readlink(root).encode("utf-8"))
            continue
        if not root.exists():
            add("missing", relative_root)
            continue
        paths = (root,) if root.is_file() else tuple(sorted(root.rglob("*")))
        for path in paths:
            relative = path.relative_to(project_root).as_posix()
            if path.is_symlink():
                add("symlink", relative, os.readlink(path).encode("utf-8"))
            elif path.is_dir():
                add("directory", relative)
            elif path.is_file():
                add("file", relative, sha256_file(path).encode("ascii"))
            else:
                raise ValueError(
                    f"production input contains unsupported file: {relative}"
                )
    return digest.hexdigest()


@dataclass(frozen=True)
class ReleasePaths:
    project_root: Path
    root: Path
    project: Path
    archive: Path
    export: Path
    export_options: Path
    manifest: Path

    @classmethod
    def for_identity(
        cls,
        project_root: Path,
        output_root: Path,
        identity: ReleaseIdentity,
    ) -> "ReleasePaths":
        project_root = project_root.resolve()
        output_root = output_root.resolve()
        root = (
            output_root
            / identity.version
            / identity.build
            / identity.dmg_sha256[:16]
        )
        stem = f"CodexPad-{identity.version}-{identity.build}"
        return cls(
            project_root=project_root,
            root=root,
            project=project_root / "CodexPad/CodexPad.xcodeproj",
            archive=root / f"{stem}.xcarchive",
            export=root / "export",
            export_options=root / "ExportOptions-debugging.plist",
            manifest=root / f"{stem}.release.json",
        )


def _one_consistent_string(
    values: Sequence[object],
    *,
    label: str,
) -> str:
    strings = [value for value in values if isinstance(value, str) and value]
    if not strings or len(set(strings)) != 1:
        raise ValueError(f"release identity {label} is missing or inconsistent")
    return strings[0]


def load_release_identity(record_path: Path) -> ReleaseIdentity:
    """Read an exact identity record and construct the shared immutable type."""
    payload = load_json_object(record_path)
    source_identity = payload.get("sourceIdentity")
    if not isinstance(source_identity, dict):
        source_identity = {}
    version = _one_consistent_string(
        (payload.get("version"), payload.get("desktopVersion")),
        label="version",
    )
    build_values = [
        value
        for value in (payload.get("build"), payload.get("desktopBuild"))
        if value is not None
    ]
    build = _one_consistent_string(
        tuple(str(value) for value in build_values),
        label="build",
    )
    dmg_sha256 = _one_consistent_string(
        (
            payload.get("dmgSha256"),
            payload.get("dmg_sha256"),
            source_identity.get("dmgSha256"),
        ),
        label="DMG SHA-256",
    )
    return ReleaseIdentity(version, build, dmg_sha256)


def _require_team_id(team_id: str) -> None:
    if TEAM_ID_PATTERN.fullmatch(team_id) is None:
        raise ValueError("developer team ID is malformed")


def build_archive_command(
    paths: ReleasePaths,
    identity: ReleaseIdentity,
    team_id: str,
    *,
    target_device_id: str,
) -> list[str]:
    _require_team_id(team_id)
    # Archiving is deliberately device-independent. The target UDID is only
    # used later to verify that the exported provisioning profile contains the
    # intended physical iPad; passing it to xcodebuild here can wake, launch,
    # or otherwise disturb the device during the build phase.
    if not target_device_id or any(character.isspace() for character in target_device_id):
        raise ValueError("target device identifier is malformed")
    return [
        "xcodebuild",
        "-project",
        str(paths.project),
        "-scheme",
        SCHEME,
        "-configuration",
        "Release",
        "-destination",
        "generic/platform=iOS",
        "-archivePath",
        str(paths.archive),
        "-allowProvisioningUpdates",
        "-allowProvisioningDeviceRegistration",
        f"DEVELOPMENT_TEAM={team_id}",
        f"PRODUCT_BUNDLE_IDENTIFIER={BUNDLE_IDENTIFIER}",
        f"MARKETING_VERSION={identity.version}",
        f"CURRENT_PROJECT_VERSION={identity.build}",
        "archive",
    ]


def export_options(team_id: str) -> dict[str, object]:
    _require_team_id(team_id)
    return {
        "destination": "export",
        "method": "debugging",
        "signingStyle": "automatic",
        "stripSwiftSymbols": True,
        "teamID": team_id,
        "thinning": "<none>",
    }


def build_export_command(paths: ReleasePaths) -> list[str]:
    return [
        "xcodebuild",
        "-exportArchive",
        "-archivePath",
        str(paths.archive),
        "-exportPath",
        str(paths.export),
        "-exportOptionsPlist",
        str(paths.export_options),
        "-allowProvisioningUpdates",
    ]


def validate_xcode_27(output: bytes) -> str:
    """Require the selected xcodebuild to be the Xcode 27.0 toolchain."""
    first_line = output.decode("utf-8", errors="strict").splitlines()[:1]
    if not first_line:
        raise ValueError("Xcode 27 version output is missing")
    match = re.fullmatch(r"Xcode (27\.0)(?:\.[0-9]+)?", first_line[0])
    if match is None:
        raise ValueError("Xcode 27.0 must be selected for IPA export")
    return match.group(1)


def verify_generated_project(
    project_root: Path,
    identity: ReleaseIdentity,
) -> None:
    """Regenerate deterministically, reject drift, and restore exact inputs."""
    from scripts.generate_codexpad_xcode_project import generate_project

    codexpad_root = project_root / "CodexPad"
    generated_paths = (
        codexpad_root / "CodexPad.xcodeproj/project.pbxproj",
        codexpad_root
        / "CodexPad.xcodeproj/xcshareddata/xcschemes/CodexPad.xcscheme",
    )
    snapshots = {
        path: path.read_bytes() if path.is_file() else None
        for path in generated_paths
    }
    try:
        generate_project(
            codexpad_root,
            desktop_version=identity.version,
            desktop_build=identity.build,
        )
        changed = [
            path
            for path, before in snapshots.items()
            if (
                path.read_bytes() if path.is_file() else None
            ) != before
        ]
    finally:
        for path, before in snapshots.items():
            if before is None:
                path.unlink(missing_ok=True)
            else:
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(before)
    if changed:
        names = ", ".join(path.name for path in changed)
        raise ValueError(
            f"generated Xcode project is stale: {names}; "
            "run generate_codexpad_xcode_project.py first"
        )


def _run_command(
    command: list[str],
    *,
    capture_output: bool = False,
) -> bytes:
    result = subprocess.run(
        command,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if result.returncode != 0:
        tool = Path(command[0]).name
        raise ValueError(f"{tool} failed with status {result.returncode}")
    return result.stdout if capture_output else b""


def _run(
    command_runner: CommandRunner,
    command: list[str],
    *,
    capture_output: bool = False,
) -> bytes:
    return command_runner(command, capture_output=capture_output)


def _load_plist_bytes(data: bytes, *, label: str) -> dict[str, Any]:
    try:
        payload = plistlib.loads(data)
    except (ValueError, TypeError, plistlib.InvalidFileException) as error:
        raise ValueError(f"{label} is malformed") from error
    if not isinstance(payload, dict):
        raise ValueError(f"{label} is malformed")
    return payload


def _require_safe_zip_members(archive: zipfile.ZipFile) -> None:
    for member in archive.infolist():
        path = PurePosixPath(member.filename)
        if (
            not member.filename
            or path.is_absolute()
            or ".." in path.parts
            or "\\" in member.filename
        ):
            raise ValueError("IPA contains an unsafe ZIP member")


def _iso8601_utc(value: dt.datetime) -> str:
    if value.tzinfo is None:
        value = value.replace(tzinfo=dt.timezone.utc)
    value = value.astimezone(dt.timezone.utc)
    return value.isoformat(timespec="seconds").replace("+00:00", "Z")


def _require_entitlements(
    entitlements: dict[str, Any],
    *,
    team_id: str,
    label: str,
    allow_wildcard_keychain_group: bool = False,
) -> None:
    application_identifier = entitlements.get("application-identifier")
    expected_application_identifier = f"{team_id}.{BUNDLE_IDENTIFIER}"
    if application_identifier != expected_application_identifier:
        raise ValueError(f"{label} entitlements do not match the app identity")
    if entitlements.get("com.apple.developer.team-identifier") != team_id:
        raise ValueError(f"{label} entitlements do not match the team")
    if entitlements.get("get-task-allow") is not True:
        raise ValueError(f"{label} entitlements are not a debugging export")
    keychain_access_groups = entitlements.get("keychain-access-groups")
    expected_keychain_group = expected_application_identifier
    allowed_keychain_groups = {expected_keychain_group}
    if allow_wildcard_keychain_group:
        allowed_keychain_groups.add(f"{team_id}.*")
    if (
        not isinstance(keychain_access_groups, list)
        or not any(
            isinstance(group, str) and group in allowed_keychain_groups
            for group in keychain_access_groups
        )
    ):
        raise ValueError(
            f"{label} entitlements do not permit the app Keychain group"
        )


def _locate_exported_ipa(export_root: Path) -> Path:
    candidates = sorted(
        path
        for path in export_root.rglob("*.ipa")
        if path.is_file() and not path.is_symlink()
    )
    if len(candidates) != 1:
        raise ValueError("debugging export did not produce exactly one IPA")
    return candidates[0]


def verify_ipa(
    ipa_path: Path,
    identity: ReleaseIdentity,
    *,
    team_id: str,
    target_device_id: str,
    command_runner: CommandRunner = _run_command,
    now: dt.datetime | None = None,
    install_device: str | None = None,
) -> dict[str, Any]:
    """Verify an IPA entirely from local ZIP, signature, and profile data."""
    _require_team_id(team_id)
    if not target_device_id:
        raise ValueError("target device identifier is required")
    ipa_path = ipa_path.resolve()
    if ipa_path.is_symlink() or not ipa_path.is_file():
        raise ValueError("IPA is missing")
    if now is None:
        now = dt.datetime.now(dt.timezone.utc)
    elif now.tzinfo is None:
        now = now.replace(tzinfo=dt.timezone.utc)
    else:
        now = now.astimezone(dt.timezone.utc)

    try:
        with zipfile.ZipFile(ipa_path) as archive:
            _require_safe_zip_members(archive)
            corrupt_member = archive.testzip()
            if corrupt_member is not None:
                raise ValueError("IPA ZIP integrity check failed")
            with tempfile.TemporaryDirectory(
                prefix="codexpad-ipa-verify-"
            ) as temporary:
                extraction_root = Path(temporary)
                archive.extractall(extraction_root)
                payload_root = extraction_root / "Payload"
                app_candidates = sorted(payload_root.glob("*.app"))
                if (
                    len(app_candidates) != 1
                    or not app_candidates[0].is_dir()
                ):
                    raise ValueError(
                        "IPA must contain exactly one Payload app"
                    )
                app = app_candidates[0]
                info_path = app / "Info.plist"
                if not info_path.is_file():
                    raise ValueError("IPA app Info.plist is missing")
                info = _load_plist_bytes(
                    info_path.read_bytes(),
                    label="IPA app Info.plist",
                )
                bundle_identifier = info.get("CFBundleIdentifier")
                version = str(info.get("CFBundleShortVersionString", ""))
                build = str(info.get("CFBundleVersion", ""))
                executable_name = info.get("CFBundleExecutable")
                device_families = info.get("UIDeviceFamily")
                platform_name = info.get("DTPlatformName")
                minimum_os_version = str(info.get("MinimumOSVersion", ""))
                if bundle_identifier != BUNDLE_IDENTIFIER:
                    raise ValueError("IPA bundle identifier does not match")
                if version != identity.version:
                    raise ValueError("IPA version does not match release identity")
                if build != identity.build:
                    raise ValueError("IPA build does not match release identity")
                if (
                    not isinstance(executable_name, str)
                    or not executable_name
                    or Path(executable_name).name != executable_name
                ):
                    raise ValueError("IPA executable name is malformed")
                if (
                    not isinstance(device_families, list)
                    or 2 not in device_families
                ):
                    raise ValueError("IPA does not declare iPad device support")
                if platform_name != "iphoneos":
                    raise ValueError("IPA was not built for iphoneos")
                if minimum_os_version != "18.0":
                    raise ValueError(
                        "IPA minimum OS version does not match iPad target"
                    )
                executable = app / executable_name
                if not executable.is_file():
                    raise ValueError("IPA app executable is missing")

                architectures = _run(
                    command_runner,
                    ["/usr/bin/lipo", "-archs", str(executable)],
                    capture_output=True,
                ).decode("utf-8", errors="strict").split()
                if "arm64" not in architectures:
                    raise ValueError("IPA app executable does not contain arm64")

                _run(
                    command_runner,
                    [
                        "/usr/bin/codesign",
                        "--verify",
                        "--deep",
                        "--strict",
                        str(app),
                    ],
                )
                entitlements = _load_plist_bytes(
                    _run(
                        command_runner,
                        [
                            "/usr/bin/codesign",
                            "-d",
                            "--entitlements",
                            ":-",
                            str(app),
                        ],
                        capture_output=True,
                    ),
                    label="signed app entitlements",
                )
                _require_entitlements(
                    entitlements,
                    team_id=team_id,
                    label="signed app",
                )

                profile_path = app / "embedded.mobileprovision"
                if not profile_path.is_file():
                    raise ValueError(
                        "embedded provisioning profile is missing"
                    )
                profile = _load_plist_bytes(
                    _run(
                        command_runner,
                        [
                            "/usr/bin/security",
                            "cms",
                            "-D",
                            "-i",
                            str(profile_path),
                        ],
                        capture_output=True,
                    ),
                    label="embedded provisioning profile",
                )
                expiration = profile.get("ExpirationDate")
                if not isinstance(expiration, dt.datetime):
                    raise ValueError(
                        "provisioning profile expiration is malformed"
                    )
                if expiration.tzinfo is None:
                    expiration = expiration.replace(tzinfo=dt.timezone.utc)
                else:
                    expiration = expiration.astimezone(dt.timezone.utc)
                if expiration <= now:
                    raise ValueError("embedded provisioning profile is expired")

                provisioned_devices = profile.get("ProvisionedDevices")
                if (
                    not isinstance(provisioned_devices, list)
                    or target_device_id not in provisioned_devices
                ):
                    raise ValueError(
                        "target device is absent from provisioning profile"
                    )
                team_identifiers = profile.get("TeamIdentifier")
                if (
                    not isinstance(team_identifiers, list)
                    or team_id not in team_identifiers
                ):
                    raise ValueError(
                        "provisioning profile does not match the team"
                    )
                profile_entitlements = profile.get("Entitlements")
                if not isinstance(profile_entitlements, dict):
                    raise ValueError(
                        "provisioning profile entitlements are malformed"
                    )
                _require_entitlements(
                    profile_entitlements,
                    team_id=team_id,
                    label="provisioning profile",
                    allow_wildcard_keychain_group=True,
                )

                if install_device is not None:
                    if not install_device.strip():
                        raise ValueError("install device name is empty")
                    _run(
                        command_runner,
                        [
                            "/usr/bin/xcrun",
                            "devicectl",
                            "device",
                            "install",
                            "app",
                            "--device",
                            target_device_id,
                            str(app),
                        ],
                    )
    except zipfile.BadZipFile as error:
        raise ValueError("IPA ZIP is malformed") from error

    return {
        "artifact": {
            "fileName": ipa_path.name,
            "sha256": sha256_file(ipa_path),
            "sizeBytes": ipa_path.stat().st_size,
            "zipIntegrity": True,
        },
        "product": {
            "architecture": "arm64",
            "bundleIdentifier": BUNDLE_IDENTIFIER,
            "build": identity.build,
            "deviceFamily": "iPad",
            "minimumOSVersion": minimum_os_version,
            "name": PRODUCT_NAME,
            "platform": "iphoneos",
            "version": identity.version,
        },
        "verification": {
            "bundleIdentityMatched": True,
            "codesignValid": True,
            "entitlementsValid": True,
            "provisioningProfileExpiration": _iso8601_utc(expiration),
            "provisioningProfileValid": True,
            "targetDeviceProvisioned": True,
        },
    }


def create_dry_run_plan(
    paths: ReleasePaths,
    identity: ReleaseIdentity,
    *,
    team_id: str,
    target_device_id: str,
    install_device: str | None,
) -> dict[str, Any]:
    _require_team_id(team_id)
    archive_command = build_archive_command(
        paths,
        identity,
        team_id,
        target_device_id=target_device_id,
    )
    return {
        "archiveCommand": archive_command,
        "clearContainer": False,
        "clearKeychain": False,
        "distributionMethod": "debugging",
        "exportCommand": build_export_command(paths),
        "installOverExisting": install_device is not None,
        "releaseIdentity": {
            "build": identity.build,
            "dmgSha256": identity.dmg_sha256,
            "version": identity.version,
        },
        "targetDeviceCheck": bool(target_device_id),
        "uninstall": False,
    }


def _write_export_options(path: Path, team_id: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.{os.getpid()}")
    with temporary.open("wb") as stream:
        plistlib.dump(
            export_options(team_id),
            stream,
            fmt=plistlib.FMT_XML,
            sort_keys=True,
        )
        stream.flush()
        os.fsync(stream.fileno())
    os.replace(temporary, path)


def build_release(
    paths: ReleasePaths,
    identity: ReleaseIdentity,
    *,
    team_id: str,
    target_device_id: str,
    install_device: str | None,
    command_runner: CommandRunner = _run_command,
    project_sync_checker: ProjectSyncChecker = verify_generated_project,
    now: dt.datetime | None = None,
) -> dict[str, Any]:
    """Build a fresh archive/export, verify it, then publish the manifest."""
    _require_team_id(team_id)
    if not target_device_id:
        raise ValueError("target device identifier is required")
    if not paths.project.is_dir():
        raise ValueError("CodexPad Xcode project is missing")
    if paths.root.exists() or paths.root.is_symlink():
        raise ValueError(f"release output already exists: {paths.root.name}")
    project_sync_checker(paths.project_root, identity)
    xcode_version = validate_xcode_27(
        _run(
            command_runner,
            ["xcodebuild", "-version"],
            capture_output=True,
        )
    )
    paths.root.parent.mkdir(parents=True, exist_ok=True)
    staging_root = paths.root.with_name(
        f".{paths.root.name}.staging-{os.getpid()}"
    )
    if staging_root.exists() or staging_root.is_symlink():
        raise ValueError("staging release output already exists")
    staging_paths = ReleasePaths(
        project_root=paths.project_root,
        root=staging_root,
        project=paths.project,
        archive=staging_root / paths.archive.name,
        export=staging_root / "export",
        export_options=staging_root / paths.export_options.name,
        manifest=staging_root / paths.manifest.name,
    )
    try:
        staging_root.mkdir()
        _write_export_options(staging_paths.export_options, team_id)
        _run(
            command_runner,
            build_archive_command(
                staging_paths,
                identity,
                team_id,
                target_device_id=target_device_id,
            ),
        )
        if not staging_paths.archive.is_dir():
            raise ValueError("Release archive was not produced")
        _run(command_runner, build_export_command(staging_paths))
        ipa_path = _locate_exported_ipa(staging_paths.export)
        verification = verify_ipa(
            ipa_path,
            identity,
            team_id=team_id,
            target_device_id=target_device_id,
            command_runner=command_runner,
            now=now,
            install_device=install_device,
        )
        generated_at = now or dt.datetime.now(dt.timezone.utc)
        manifest = {
            "schemaVersion": MANIFEST_SCHEMA_VERSION,
            "version": identity.version,
            "build": identity.build,
            "dmgSha256": identity.dmg_sha256,
            "productionInputFingerprint": production_input_fingerprint(
                paths.project_root
            ),
            "configuration": "Release",
            "distributionMethod": "debugging",
            "xcodeVersion": xcode_version,
            **verification,
            "installOverExisting": {
                "containerAndKeychainPreserved": True,
                "performed": install_device is not None,
                "requested": install_device is not None,
                "targetBoundToProvisioningProfile": (
                    install_device is not None
                ),
            },
            "generatedAt": _iso8601_utc(generated_at),
        }
        write_json_atomic(staging_paths.manifest, manifest)
        os.replace(staging_root, paths.root)
        return manifest
    finally:
        if staging_root.exists():
            shutil.rmtree(staging_root)


def release_cli_payload(
    paths: ReleasePaths,
    manifest: dict[str, Any],
) -> dict[str, str]:
    artifact = manifest.get("artifact")
    if not isinstance(artifact, dict):
        raise ValueError("release manifest artifact is malformed")
    file_name = artifact.get("fileName")
    if (
        not isinstance(file_name, str)
        or not file_name
        or Path(file_name).name != file_name
    ):
        raise ValueError("release manifest IPA file name is malformed")
    ipa = (paths.export / file_name).resolve()
    if not ipa.is_file() or ipa.parent != paths.export.resolve():
        raise ValueError("release manifest IPA is missing")
    return {
        "ipa": str(ipa),
        "manifest": str(paths.manifest.resolve()),
        "sha256": str(artifact.get("sha256", "")),
    }


def _default_project_root() -> Path:
    return Path(__file__).resolve().parents[1]


def main() -> int:
    parser = argparse.ArgumentParser(
        description=(
            "Archive, export with Xcode 27 method=debugging, and "
            "offline-verify a Codex for ipad Release IPA."
        )
    )
    parser.add_argument(
        "--project-root",
        type=Path,
        default=_default_project_root(),
    )
    parser.add_argument("--identity-record", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path)
    parser.add_argument("--team-id", required=True)
    parser.add_argument(
        "--target-device-id-env",
        default="CODEX_IPAD_TARGET_DEVICE_ID",
        help=(
            "environment variable containing the target device identifier; "
            "its value is never persisted"
        ),
    )
    parser.add_argument(
        "--install-device",
        help=(
            "optional connected device name; installs over the existing app "
            "without uninstalling or clearing its container/Keychain"
        ),
    )
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()

    try:
        project_root = args.project_root.resolve()
        identity = load_release_identity(args.identity_record.resolve())
        output_root = (
            args.output_dir.resolve()
            if args.output_dir is not None
            else project_root / "build/ipad-release"
        )
        paths = ReleasePaths.for_identity(
            project_root,
            output_root,
            identity,
        )
        target_device_id = os.environ.get(
            args.target_device_id_env,
            "",
        )
        if args.dry_run:
            plan = create_dry_run_plan(
                paths,
                identity,
                team_id=args.team_id,
                target_device_id=target_device_id or "<runtime-required>",
                install_device=args.install_device,
            )
            print(json.dumps(plan, ensure_ascii=False, indent=2, sort_keys=True))
            return 0
        if not target_device_id:
            raise ValueError(
                f"target device identifier environment variable is empty: "
                f"{args.target_device_id_env}"
            )
        manifest = build_release(
            paths,
            identity,
            team_id=args.team_id,
            target_device_id=target_device_id,
            install_device=args.install_device,
        )
        print(
            json.dumps(
                release_cli_payload(paths, manifest),
                indent=2,
                sort_keys=True,
            )
        )
    except (OSError, ValueError, TypeError, json.JSONDecodeError) as error:
        parser.error(str(error))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
