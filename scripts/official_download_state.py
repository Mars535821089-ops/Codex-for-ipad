#!/usr/bin/env python3
"""Bind retained official packages to the exact remote object they came from."""

from __future__ import annotations

import argparse
import datetime
import hashlib
import hmac
import json
import os
import re
import stat
import sys
import tempfile
from pathlib import Path
from typing import Any

if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from scripts.protocol_manifest import sha256_file
from scripts.release_archive import (
    MANIFEST_NAME,
    verify_live_release_snapshot,
    verify_release_archive,
)
from scripts.release_identity import (
    ReleaseIdentity,
    require_matching_release_identity,
)
from scripts.ipad_release_gate import validate_release_gate


REMOTE_IDENTITY_FIELDS = (
    "official_url",
    "etag",
    "last_modified",
    "content_length",
)
PACKAGE_HASH_FIELD = "package_sha256"
SHA256_PATTERN = re.compile(r"^[0-9a-f]{64}$")
HTTP_STATUS_PATTERN = re.compile(r"^HTTP/\S+\s+(\d{3})(?:\s|$)")
VERSION_PATTERN = re.compile(r"^[0-9]+(?:\.[0-9]+)+$")
BUILD_PATTERN = re.compile(r"^[1-9][0-9]*$")


def parse_headers(
    text: str,
    url: str,
    *,
    checked_at: str | None = None,
) -> dict[str, Any]:
    """Parse the final HTTP response from a curl --location --head transcript."""
    current: dict[str, str] = {}
    status_code: int | None = None
    for raw_line in text.splitlines():
        line = raw_line.strip()
        if line.startswith("HTTP/"):
            match = HTTP_STATUS_PATTERN.match(line)
            if match is None:
                raise ValueError("official HTTP response status is malformed")
            current = {}
            status_code = int(match.group(1))
            continue
        if not line or status_code is None or ":" not in line:
            continue
        key, value = line.split(":", 1)
        current[key.lower()] = value.strip()

    if status_code is None:
        raise ValueError("official HTTP response status is missing")
    if not 200 <= status_code < 300:
        raise ValueError(
            f"official HTTP status {status_code} is not successful"
        )
    length = current.get("content-length", "")
    record: dict[str, Any] = {
        "checked_at": checked_at
        or datetime.datetime.now(datetime.timezone.utc).strftime(
            "%Y%m%dT%H%M%SZ"
        ),
        "official_url": url,
        "status_code": status_code,
        "etag": current.get("etag", ""),
        "last_modified": current.get("last-modified", ""),
        "content_length": int(length) if length.isdigit() else 0,
    }
    validate_remote(record)
    return record


def validate_remote(record: dict[str, Any]) -> None:
    url = record.get("official_url")
    etag = record.get("etag")
    last_modified = record.get("last_modified")
    content_length = record.get("content_length")
    status_code = record.get("status_code")
    if not isinstance(url, str) or not url:
        raise ValueError("official remote URL is missing")
    if not isinstance(etag, str) or not isinstance(last_modified, str):
        raise ValueError("official remote identity fields are malformed")
    if not etag and not last_modified:
        raise ValueError("official remote has no stable identity")
    if (
        isinstance(content_length, bool)
        or not isinstance(content_length, int)
        or content_length <= 0
    ):
        raise ValueError("official remote content length is missing")
    if status_code is not None and (
        isinstance(status_code, bool)
        or not isinstance(status_code, int)
        or not 200 <= status_code < 300
    ):
        raise ValueError("official remote HTTP status is not successful")


def same_remote(left: dict[str, Any], right: dict[str, Any]) -> bool:
    validate_remote(left)
    validate_remote(right)
    return all(left.get(field) == right.get(field) for field in REMOTE_IDENTITY_FIELDS)


def sidecar_path(package: Path) -> Path:
    return package.with_name(package.name + ".remote.json")


def package_sha256(package: Path) -> str:
    digest = hashlib.sha256()
    with package.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _write_json_atomic(path: Path, value: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary_path: Path | None = None
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
            temporary_path = Path(stream.name)
        os.chmod(temporary_path, 0o600)
        os.replace(temporary_path, path)
    finally:
        if temporary_path is not None and temporary_path.exists():
            temporary_path.unlink()


def write_sidecar(package: Path, remote: dict[str, Any]) -> Path:
    validate_remote(remote)
    if not package.is_file():
        raise ValueError("official package is missing")
    if package.stat().st_size != remote["content_length"]:
        raise ValueError("official package size does not match remote")
    output = sidecar_path(package)
    record = {
        **remote,
        PACKAGE_HASH_FIELD: package_sha256(package),
    }
    _write_json_atomic(output, record)
    return output


def select_reusable_package(
    directory: Path,
    remote: dict[str, Any],
) -> Path | None:
    validate_remote(remote)
    if not directory.is_dir():
        return None
    for package in sorted(directory.glob("ChatGPT-*.dmg"), reverse=True):
        sidecar = sidecar_path(package)
        if not sidecar.is_file():
            continue
        try:
            recorded = json.loads(sidecar.read_text(encoding="utf-8"))
            if not isinstance(recorded, dict):
                continue
            if package.stat().st_size != remote["content_length"]:
                continue
            recorded_hash = recorded.get(PACKAGE_HASH_FIELD)
            if (
                same_remote(recorded, remote)
                and isinstance(recorded_hash, str)
                and SHA256_PATTERN.fullmatch(recorded_hash) is not None
                and hmac.compare_digest(
                    package_sha256(package),
                    recorded_hash,
                )
            ):
                return package
        except (OSError, ValueError, json.JSONDecodeError):
            continue
    return None


def cleanup_incomplete_parts(
    directory: Path,
    *,
    content_length: int,
) -> list[Path]:
    if (
        isinstance(content_length, bool)
        or not isinstance(content_length, int)
        or content_length <= 0
    ):
        raise ValueError("official remote content length is missing")
    if not directory.is_dir():
        return []

    removed: list[Path] = []
    for candidate in sorted(directory.glob("ChatGPT-*.dmg.part")):
        try:
            metadata = candidate.lstat()
            if not stat.S_ISREG(metadata.st_mode):
                continue
            if metadata.st_size >= content_length:
                continue
            candidate.unlink()
        except FileNotFoundError:
            continue
        removed.append(candidate)
    return removed


def _read_remote(path: Path) -> dict[str, Any]:
    value = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise ValueError("remote record must be a JSON object")
    validate_remote(value)
    return value


def _read_json_object(path: Path, *, label: str) -> dict[str, Any]:
    if not path.is_file():
        raise ValueError(f"{label} is missing")
    value = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise ValueError(f"{label} is malformed")
    return value


def _require_identity(
    record: dict[str, Any],
    *,
    version_key: str,
    build_key: str,
    version: str,
    build: str,
    label: str,
) -> None:
    if (
        record.get(version_key) != version
        or str(record.get(build_key, "")) != build
    ):
        raise ValueError(f"{label} does not match latest official build")


def validate_local_current(
    project_root: Path,
    latest_path: Path,
) -> dict[str, Any]:
    project_root = project_root.resolve()
    if not project_root.is_dir():
        raise ValueError("project root is missing")
    latest_path = latest_path.resolve()
    expected_latest = (
        project_root / "artifacts" / "latest-official.json"
    ).resolve()
    if latest_path != expected_latest:
        raise ValueError("latest official path is outside the project artifacts")
    latest = _read_json_object(latest_path, label="latest official record")

    version = latest.get("version")
    build = latest.get("build")
    package_hash = latest.get("sha256")
    package_size = latest.get("size")
    if (
        not isinstance(version, str)
        or VERSION_PATTERN.fullmatch(version) is None
        or not isinstance(build, str)
        or BUILD_PATTERN.fullmatch(build) is None
        or not isinstance(package_hash, str)
        or SHA256_PATTERN.fullmatch(package_hash) is None
        or isinstance(package_size, bool)
        or not isinstance(package_size, int)
        or package_size <= 0
        or not isinstance(latest.get("official_url"), str)
        or not latest["official_url"]
        or latest.get("reverse_imported") is not True
        or latest.get("ipad_upgrade_verified") is not True
    ):
        raise ValueError("latest official record is malformed")

    release_identity = ReleaseIdentity(
        version=version,
        build=build,
        dmg_sha256=package_hash,
    )
    has_release_root = "releaseRoot" in latest
    has_manifest_anchor = "releaseManifestSha256" in latest
    # Records committed before content-addressed release archives existed must
    # run through the updater once so they acquire an immutable archive anchor.
    if not has_release_root and not has_manifest_anchor:
        raise ValueError(
            "latest official release archive anchors are missing"
        )
    if has_release_root != has_manifest_anchor:
        raise ValueError(
            "latest official release archive anchors are incomplete"
        )
    release_root = latest.get("releaseRoot")
    if release_root != release_identity.release_root:
        raise ValueError(
            "latest official releaseRoot does not match release identity"
        )
    release_path = project_root / release_identity.release_root
    if release_path.resolve() != release_path.absolute():
        raise ValueError(
            "latest official releaseRoot escapes its exact release path"
        )
    expected_manifest_hash = latest.get("releaseManifestSha256")
    manifest_path = release_path / MANIFEST_NAME
    if (
        not isinstance(expected_manifest_hash, str)
        or SHA256_PATTERN.fullmatch(expected_manifest_hash) is None
        or manifest_path.is_symlink()
        or not manifest_path.is_file()
        or not hmac.compare_digest(
            sha256_file(manifest_path),
            expected_manifest_hash,
        )
    ):
        raise ValueError(
            "latest official release manifest hash does not match"
        )
    release_manifest = verify_release_archive(
        project_root,
        release_identity,
    )
    verify_live_release_snapshot(
        project_root,
        release_identity,
        release_manifest,
    )
    ipa_anchor_fields = (
        "ipaPath",
        "ipaSha256",
        "ipaReleaseManifestPath",
        "ipaReleaseManifestSha256",
    )
    if any(field not in latest for field in ipa_anchor_fields):
        raise ValueError("latest official signed IPA anchors are missing")
    ipa_manifest_relative = latest.get("ipaReleaseManifestPath")
    if not isinstance(ipa_manifest_relative, str):
        raise ValueError("latest official signed IPA anchors are malformed")
    gate = validate_release_gate(
        project_root,
        release_identity,
        project_root / ipa_manifest_relative,
    )
    for field in ipa_anchor_fields:
        value = latest.get(field)
        if (
            not isinstance(value, str)
            or not hmac.compare_digest(value, gate[field])
        ):
            raise ValueError(
                "latest official signed IPA anchors do not match"
            )

    import_record = _read_json_object(
        project_root / f"artifacts/manifest-{version}.json",
        label="reverse import record",
    )
    _require_identity(
        import_record,
        version_key="version",
        build_key="build",
        version=version,
        build=build,
        label="reverse import record",
    )
    if import_record.get("dmg_sha256") != package_hash:
        raise ValueError("reverse import record does not match latest official package")
    extracted_relative = f"artifacts/app-asar-{version}"
    extracted = project_root / extracted_relative
    if (
        import_record.get("extracted_path") != extracted_relative
        or not extracted.is_dir()
    ):
        raise ValueError("reverse import ASAR tree is missing")
    expected_file_count = import_record.get("file_count")
    if (
        isinstance(expected_file_count, bool)
        or not isinstance(expected_file_count, int)
        or expected_file_count <= 0
    ):
        raise ValueError("reverse import record is malformed")
    actual_file_count = sum(
        1 for path in extracted.rglob("*") if path.is_file()
    )
    if actual_file_count != expected_file_count:
        raise ValueError("reverse import ASAR tree does not match import record")

    full_reverse = project_root / f"artifacts/full-reverse-{version}"
    full_reverse_record = _read_json_object(
        full_reverse / "full-reverse-manifest.json",
        label="full reverse manifest",
    )
    _require_identity(
        full_reverse_record,
        version_key="version",
        build_key="build",
        version=version,
        build=build,
        label="full reverse manifest",
    )
    if not (full_reverse / "app-asar/webview/index.html").is_file():
        raise ValueError("full reverse renderer entry is missing")

    for label, path in (
        (
            "iPad upgrade record",
            project_root / f"artifacts/ipad-upgrade-{version}.json",
        ),
        (
            "iPad verification record",
            project_root / f"artifacts/ipad-verified-{version}.json",
        ),
        (
            "desktop surface manifest",
            project_root / f"versions/{version}/desktop-surface-manifest.json",
        ),
    ):
        record = _read_json_object(path, label=label)
        _require_identity(
            record,
            version_key="desktopVersion",
            build_key="desktopBuild",
            version=version,
            build=build,
            label=label,
        )
        if label == "desktop surface manifest":
            tree_hash = record.get("resourceTreeSha256")
            if (
                not isinstance(tree_hash, str)
                or SHA256_PATTERN.fullmatch(tree_hash) is None
            ):
                raise ValueError("desktop surface manifest is malformed")
    return latest


def _command_parse_headers(args: argparse.Namespace) -> None:
    record = parse_headers(
        args.headers.read_text(encoding="iso-8859-1"),
        args.url,
    )
    _write_json_atomic(args.output, record)


def _command_select_reusable(args: argparse.Namespace) -> None:
    selected = select_reusable_package(
        args.download_directory,
        _read_remote(args.remote),
    )
    if selected is not None:
        print(selected)


def _command_write_sidecar(args: argparse.Namespace) -> None:
    print(write_sidecar(args.package, _read_remote(args.remote)))


def _command_cleanup_incomplete_parts(args: argparse.Namespace) -> None:
    remote = _read_remote(args.remote)
    for removed in cleanup_incomplete_parts(
        args.download_directory,
        content_length=remote["content_length"],
    ):
        print(removed)


def _command_assert_same(args: argparse.Namespace) -> None:
    expected = _read_remote(args.expected)
    actual = _read_remote(args.actual)
    if not same_remote(expected, actual):
        raise ValueError("official remote changed during the upgrade")


def _command_assert_local_current(args: argparse.Namespace) -> None:
    validate_local_current(args.project_root, args.latest)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(required=True)

    parse = subparsers.add_parser("parse-headers")
    parse.add_argument("--headers", type=Path, required=True)
    parse.add_argument("--output", type=Path, required=True)
    parse.add_argument("--url", required=True)
    parse.set_defaults(handler=_command_parse_headers)

    select = subparsers.add_parser("select-reusable")
    select.add_argument("--remote", type=Path, required=True)
    select.add_argument("--download-directory", type=Path, required=True)
    select.set_defaults(handler=_command_select_reusable)

    write = subparsers.add_parser("write-sidecar")
    write.add_argument("--remote", type=Path, required=True)
    write.add_argument("--package", type=Path, required=True)
    write.set_defaults(handler=_command_write_sidecar)

    cleanup_parts = subparsers.add_parser("cleanup-incomplete-parts")
    cleanup_parts.add_argument("--remote", type=Path, required=True)
    cleanup_parts.add_argument(
        "--download-directory",
        type=Path,
        required=True,
    )
    cleanup_parts.set_defaults(handler=_command_cleanup_incomplete_parts)

    compare = subparsers.add_parser("assert-same")
    compare.add_argument("--expected", type=Path, required=True)
    compare.add_argument("--actual", type=Path, required=True)
    compare.set_defaults(handler=_command_assert_same)

    local = subparsers.add_parser("assert-local-current")
    local.add_argument("--project-root", type=Path, required=True)
    local.add_argument("--latest", type=Path, required=True)
    local.set_defaults(handler=_command_assert_local_current)
    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    try:
        args.handler(args)
    except (OSError, ValueError, json.JSONDecodeError) as error:
        parser.error(str(error))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
