#!/usr/bin/env python3
"""Resolve, verify, and safely extract the canonical Codex for ipad IPA."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import plistlib
import stat
import sys
import tempfile
from typing import Any
import zipfile


PRODUCT_NAME = "Codex for ipad"
BUNDLE_IDENTIFIER = "dev.codexforipad.app"


def load_object(path: Path, *, label: str) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise ValueError(f"{label} is unreadable or malformed") from error
    if not isinstance(value, dict):
        raise ValueError(f"{label} must be a JSON object")
    return value


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def project_path(project_root: Path, value: object) -> Path:
    if not isinstance(value, str) or not value:
        raise ValueError("release path is missing")
    relative = Path(value)
    if relative.is_absolute():
        raise ValueError("release path escapes project root")
    resolved = (project_root / relative).resolve()
    try:
        resolved.relative_to(project_root)
    except ValueError as error:
        raise ValueError("release path escapes project root") from error
    if resolved.is_symlink():
        raise ValueError("release path must not be a symlink")
    return resolved


def require_equal(actual: object, expected: object, *, label: str) -> None:
    if str(actual) != str(expected):
        raise ValueError(f"{label} does not match")


def require_true(value: object, *, label: str) -> None:
    if value is not True:
        raise ValueError(f"{label} is not verified")


def safe_members(archive: zipfile.ZipFile) -> list[zipfile.ZipInfo]:
    members = archive.infolist()
    for member in members:
        member_path = PurePosixPath(member.filename)
        mode = member.external_attr >> 16
        if (
            not member.filename
            or member_path.is_absolute()
            or ".." in member_path.parts
            or "\\" in member.filename
            or stat.S_ISLNK(mode)
        ):
            raise ValueError("IPA contains an unsafe ZIP member")
    return members


def resolve_release(
    *,
    project_root: Path,
    probe_path: Path,
    extract_root: Path,
) -> dict[str, object]:
    project_root = project_root.resolve()
    probe_path = probe_path.resolve()
    try:
        probe_path.relative_to(project_root)
    except ValueError as error:
        raise ValueError("probe path escapes project root") from error

    probe = load_object(probe_path, label="latest official probe")
    application = probe.get("application")
    download = probe.get("download")
    release_match = probe.get("releaseMatch")
    if not all(isinstance(value, dict) for value in (application, download, release_match)):
        raise ValueError("latest official probe release identity is incomplete")

    version = str(application.get("version", ""))
    build = str(application.get("build", ""))
    dmg_sha256 = str(download.get("sha256", ""))
    if not version or not build or len(dmg_sha256) != 64:
        raise ValueError("latest official probe release identity is malformed")
    require_true(release_match.get("dmgSha256Matched"), label="DMG identity")

    ipa_path = project_path(project_root, release_match.get("ipaPath"))
    manifest_path = project_path(project_root, release_match.get("manifestPath"))
    if not ipa_path.is_file() or not manifest_path.is_file():
        raise ValueError("canonical release artifact is missing")

    manifest = load_object(manifest_path, label="release manifest")
    artifact = manifest.get("artifact")
    product = manifest.get("product")
    verification = manifest.get("verification")
    if not all(isinstance(value, dict) for value in (artifact, product, verification)):
        raise ValueError("release manifest is incomplete")

    for actual, expected, label in (
        (manifest.get("version"), version, "manifest version"),
        (manifest.get("build"), build, "manifest build"),
        (manifest.get("dmgSha256"), dmg_sha256, "manifest DMG SHA-256"),
        (product.get("version"), version, "product version"),
        (product.get("build"), build, "product build"),
        (product.get("name"), PRODUCT_NAME, "product name"),
        (product.get("bundleIdentifier"), BUNDLE_IDENTIFIER, "bundle identifier"),
        (product.get("architecture"), "arm64", "product architecture"),
        (product.get("deviceFamily"), "iPad", "device family"),
        (product.get("platform"), "iphoneos", "product platform"),
        (artifact.get("fileName"), ipa_path.name, "artifact file name"),
        (release_match.get("ipaSha256"), artifact.get("sha256"), "probe IPA SHA-256"),
        (release_match.get("ipaSizeBytes"), artifact.get("sizeBytes"), "probe IPA size"),
    ):
        require_equal(actual, expected, label=label)

    for key in (
        "bundleIdentityMatched",
        "codesignValid",
        "entitlementsValid",
        "provisioningProfileValid",
        "targetDeviceProvisioned",
    ):
        require_true(verification.get(key), label=key)
    require_true(artifact.get("zipIntegrity"), label="IPA ZIP integrity")

    expected_size = int(artifact.get("sizeBytes", -1))
    if ipa_path.stat().st_size != expected_size:
        raise ValueError("IPA size does not match release manifest")
    expected_sha256 = str(artifact.get("sha256", ""))
    if sha256_file(ipa_path) != expected_sha256:
        raise ValueError("IPA SHA-256 does not match release manifest")

    extract_root = extract_root.resolve()
    if extract_root.exists() and any(extract_root.iterdir()):
        raise ValueError("release extraction root must be empty")
    extract_root.mkdir(parents=True, exist_ok=True)
    try:
        with zipfile.ZipFile(ipa_path) as archive:
            safe_members(archive)
            if archive.testzip() is not None:
                raise ValueError("IPA ZIP integrity check failed")
            archive.extractall(extract_root)
    except zipfile.BadZipFile as error:
        raise ValueError("IPA ZIP is malformed") from error

    apps = sorted((extract_root / "Payload").glob("*.app"))
    if len(apps) != 1 or not apps[0].is_dir():
        raise ValueError("IPA must contain exactly one app bundle")
    app_path = apps[0]
    info_path = app_path / "Info.plist"
    try:
        info = plistlib.loads(info_path.read_bytes())
    except (OSError, ValueError, plistlib.InvalidFileException) as error:
        raise ValueError("extracted app Info.plist is malformed") from error
    if not isinstance(info, dict):
        raise ValueError("extracted app Info.plist is malformed")
    for actual, expected, label in (
        (info.get("CFBundleDisplayName"), PRODUCT_NAME, "app display name"),
        (info.get("CFBundleIdentifier"), BUNDLE_IDENTIFIER, "app bundle identifier"),
        (info.get("CFBundleShortVersionString"), version, "app version"),
        (info.get("CFBundleVersion"), build, "app build"),
    ):
        require_equal(actual, expected, label=label)
    if 2 not in info.get("UIDeviceFamily", []):
        raise ValueError("extracted app does not support iPad")
    executable_name = info.get("CFBundleExecutable")
    if not isinstance(executable_name, str) or not (app_path / executable_name).is_file():
        raise ValueError("extracted app executable is missing")

    return {
        "appPath": str(app_path),
        "build": build,
        "ipaPath": str(ipa_path),
        "ipaSha256": expected_sha256,
        "manifestPath": str(manifest_path),
        "version": version,
    }


def write_json_atomic(path: Path, value: dict[str, object]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary: Path | None = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="w",
            encoding="utf-8",
            dir=path.parent,
            prefix=f".{path.name}.",
            suffix=".tmp",
            delete=False,
        ) as stream:
            temporary = Path(stream.name)
            json.dump(value, stream, ensure_ascii=False, indent=2, sort_keys=True)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--project-root", type=Path, required=True)
    parser.add_argument("--probe", type=Path, required=True)
    parser.add_argument("--extract-root", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    try:
        resolved = resolve_release(
            project_root=args.project_root,
            probe_path=args.probe,
            extract_root=args.extract_root,
        )
        write_json_atomic(args.output, resolved)
    except (OSError, ValueError, TypeError) as error:
        print(str(error), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
