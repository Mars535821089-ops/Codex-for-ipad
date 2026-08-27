#!/usr/bin/env python3
"""Materialize and verify one immutable, content-addressed desktop release."""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import plistlib
import re
import shutil
import stat
import subprocess
import sys
import tempfile
from typing import Any

if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from scripts.release_identity import (
    ReleaseIdentity,
    require_matching_release_identity,
)
from scripts.protocol_manifest import (
    load_json_object,
    sha256_file,
    write_json_atomic,
)
from scripts.ipad_verification_evidence import _tree_sha256 as _xcresult_sha256
from scripts.build_desktop_interaction_inventory import (
    verify_desktop_interaction_inventory,
)


MANIFEST_NAME = "release-manifest.json"
LEGACY_SCHEMA_VERSION = 1
CURRENT_SCHEMA_VERSION = 2
LEGACY_DERIVED_NAMES = frozenset({"appAsar", "fullReverse", "version"})
CURRENT_DERIVED_NAMES = LEGACY_DERIVED_NAMES | {"parityEvidence"}
XCRESULT_HASH_ALGORITHM = "sha256-xcresult-tree-v1"
XCUI_LOG_FILES = {
    "python": "python-tests.log",
    "swift": "swift-tests.log",
    "rust": "rust-tests.log",
    "xcui": "xcui-tests.log",
    "device-build": "device-build.log",
    "device-surface": "device-surface.json",
}
XCUI_LOG_NAMES = frozenset(XCUI_LOG_FILES)
REQUIRED_RECORD_NAMES = frozenset(
    {
        "importManifest",
        "ipadUpgrade",
        "ipadVerification",
        "infoPlist",
    }
)
OPTIONAL_RECORD_NAMES = frozenset({"entitlements"})
MANIFEST_KEYS = frozenset(
    {
        "schemaVersion",
        "version",
        "build",
        "dmgSha256",
        "officialPackage",
        "derived",
        "records",
    }
)
TREE_IDENTITY_KEYS = frozenset(
    {
        "rootMode",
        "directoryCount",
        "fileCount",
        "symlinkCount",
        "totalBytes",
        "treeSha256",
    }
)
SHA256_PATTERN = re.compile(r"^[0-9a-f]{64}$")


def _is_volatile_derived_path(relative: str) -> bool:
    parts = relative.split("/")
    name = parts[-1]
    return (
        name == ".DS_Store"
        or "__pycache__" in parts
        or name.endswith((".pyc", ".pyo"))
    )


def _require_internal_symlink(root: Path, path: Path, target: str) -> None:
    if os.path.isabs(target):
        raise ValueError("release archive tree has an external symlink")
    try:
        resolved_root = root.resolve()
        resolved_target = (path.parent / target).resolve(strict=False)
        resolved_target.relative_to(resolved_root)
    except (OSError, RuntimeError, ValueError) as error:
        raise ValueError(
            "release archive tree has an external symlink"
        ) from error


def _require_tree_identity_types(
    record: dict[str, Any],
    *,
    label: str,
) -> None:
    root_mode = record.get("rootMode")
    if (
        isinstance(root_mode, bool)
        or not isinstance(root_mode, int)
        or not 0 <= root_mode <= 0o7777
    ):
        raise ValueError(f"{label} root mode is malformed")
    for field in (
        "directoryCount",
        "fileCount",
        "symlinkCount",
        "totalBytes",
    ):
        value = record.get(field)
        if (
            isinstance(value, bool)
            or not isinstance(value, int)
            or value < 0
        ):
            raise ValueError(f"{label} {field} is malformed")
    tree_sha256 = record.get("treeSha256")
    if (
        not isinstance(tree_sha256, str)
        or SHA256_PATTERN.fullmatch(tree_sha256) is None
    ):
        raise ValueError(f"{label} tree hash is malformed")


def _tree_identity(
    root: Path,
    *,
    file_overrides: dict[str, bytes] | None = None,
    ignore_volatile: bool = False,
) -> dict[str, object]:
    if root.is_symlink() or not root.is_dir():
        raise ValueError(f"release archive source tree is missing: {root.name}")
    digest = hashlib.sha256()
    root_mode = stat.S_IMODE(root.stat().st_mode)
    digest.update(b"root\0")
    digest.update(f"{root_mode:o}".encode("ascii"))
    digest.update(b"\n")
    directory_count = 0
    file_count = 0
    symlink_count = 0
    total_bytes = 0
    overrides = file_overrides or {}
    seen_overrides: set[str] = set()
    for path in sorted(root.rglob("*")):
        relative = path.relative_to(root).as_posix()
        if ignore_volatile and _is_volatile_derived_path(relative):
            continue
        path_stat = path.lstat()
        mode = stat.S_IMODE(path_stat.st_mode)
        if stat.S_ISLNK(path_stat.st_mode):
            target = os.readlink(path)
            _require_internal_symlink(root, path, target)
            digest.update(b"symlink\0")
            digest.update(relative.encode("utf-8"))
            digest.update(b"\0")
            digest.update(target.encode("utf-8"))
            digest.update(b"\n")
            symlink_count += 1
        elif stat.S_ISDIR(path_stat.st_mode):
            digest.update(b"directory\0")
            digest.update(relative.encode("utf-8"))
            digest.update(b"\0")
            digest.update(f"{mode:o}".encode("ascii"))
            digest.update(b"\n")
            directory_count += 1
        elif stat.S_ISREG(path_stat.st_mode):
            override = overrides.get(relative)
            if override is None:
                size = path_stat.st_size
                file_sha256 = sha256_file(path)
            else:
                size = len(override)
                file_sha256 = hashlib.sha256(override).hexdigest()
                seen_overrides.add(relative)
            digest.update(b"file\0")
            digest.update(relative.encode("utf-8"))
            digest.update(b"\0")
            digest.update(f"{mode:o}".encode("ascii"))
            digest.update(b"\0")
            digest.update(str(size).encode("ascii"))
            digest.update(b"\0")
            digest.update(file_sha256.encode("ascii"))
            digest.update(b"\n")
            file_count += 1
            total_bytes += size
        else:
            raise ValueError(
                f"release archive tree contains a special file: {relative}"
            )
    missing_overrides = set(overrides) - seen_overrides
    if missing_overrides:
        raise ValueError(
            "release archive tree override is missing: "
            + sorted(missing_overrides)[0]
        )
    return {
        "rootMode": root_mode,
        "directoryCount": directory_count,
        "fileCount": file_count,
        "symlinkCount": symlink_count,
        "totalBytes": total_bytes,
        "treeSha256": digest.hexdigest(),
    }


def _remove_partial_destination(destination: Path) -> None:
    if destination.is_symlink() or destination.is_file():
        destination.unlink()
    elif destination.exists():
        shutil.rmtree(destination)


def _clone_or_copy_tree(source: Path, destination: Path) -> None:
    if source.is_symlink() or not source.is_dir():
        raise ValueError(f"release archive source tree is missing: {source.name}")
    if destination.exists() or destination.is_symlink():
        raise ValueError("release archive destination already exists")
    destination.parent.mkdir(parents=True, exist_ok=True)
    clone = subprocess.run(
        ["/bin/cp", "-cR", str(source), str(destination)],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if clone.returncode == 0:
        return
    _remove_partial_destination(destination)
    shutil.copytree(source, destination, symlinks=True)


def _remove_volatile_derived_paths(root: Path) -> None:
    for path in sorted(
        root.rglob("*"),
        key=lambda item: len(item.relative_to(root).parts),
        reverse=True,
    ):
        relative = path.relative_to(root).as_posix()
        if not _is_volatile_derived_path(relative):
            continue
        if path.is_symlink() or path.is_file():
            path.unlink()
        elif path.is_dir():
            shutil.rmtree(path)


def _clone_or_copy_file(source: Path, destination: Path) -> None:
    if source.is_symlink() or not source.is_file():
        raise ValueError(f"release archive source file is missing: {source.name}")
    if destination.exists() or destination.is_symlink():
        raise ValueError("release archive destination already exists")
    destination.parent.mkdir(parents=True, exist_ok=True)
    clone = subprocess.run(
        ["/bin/cp", "-c", "-p", str(source), str(destination)],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if clone.returncode != 0:
        _remove_partial_destination(destination)
        shutil.copy2(source, destination)


def _require_safe_archive_root(
    project_root: Path,
    identity: ReleaseIdentity,
) -> Path:
    project_root = project_root.resolve()
    if not project_root.is_dir():
        raise ValueError("project root is missing")
    release_root = project_root / identity.release_root
    if release_root.absolute() != release_root.resolve(strict=False):
        raise ValueError("release archive path escapes exact identity root")
    return release_root


def _record_identity(
    record_path: Path,
    identity: ReleaseIdentity,
    *,
    version_key: str,
    build_key: str,
    sha_key: str | None,
    label: str,
) -> dict[str, Any]:
    record = load_json_object(record_path)
    if sha_key is None:
        if (
            record.get(version_key) != identity.version
            or str(record.get(build_key, "")) != identity.build
        ):
            raise ValueError(f"{label} does not match release identity")
    else:
        require_matching_release_identity(
            record,
            identity,
            label=label,
            version_key=version_key,
            build_key=build_key,
            sha_key=sha_key,
        )
    return record


def _canonical_json_bytes(payload: dict[str, Any]) -> bytes:
    return (
        json.dumps(
            payload,
            ensure_ascii=False,
            indent=2,
            sort_keys=True,
        )
        + "\n"
    ).encode("utf-8")


def _write_bytes_atomic(path: Path, payload: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.{os.getpid()}")
    with temporary.open("wb") as stream:
        stream.write(payload)
        stream.flush()
        os.fsync(stream.fileno())
    os.replace(temporary, path)


def _require_lexical_relative_path(raw: object, *, label: str) -> str:
    if not isinstance(raw, str) or not raw:
        raise ValueError(f"{label} path is malformed")
    relative = Path(raw)
    components = raw.split("/")
    if (
        relative.is_absolute()
        or raw.startswith("/")
        or "\\" in raw
        or "" in components
        or "." in components
        or ".." in components
    ):
        raise ValueError(f"{label} path escapes the release archive")
    return relative.as_posix()


def _reject_tree_symlinks(root: Path, *, label: str) -> None:
    for path in root.rglob("*"):
        if path.is_symlink():
            raise ValueError(f"{label} contains a symlink")


def _map_evidence_path(raw: object, identity: ReleaseIdentity) -> str:
    relative = _require_lexical_relative_path(
        raw,
        label="release evidence",
    )
    parity_prefix = f"artifacts/parity-evidence/{identity.version}/"
    contract_path = f"versions/{identity.version}/desktop-ui-parity.json"
    if relative.startswith(parity_prefix):
        suffix = relative[len(parity_prefix) :]
        _require_lexical_relative_path(suffix, label="release evidence")
        return f"derived/parityEvidence/{suffix}"
    if relative == contract_path:
        return "derived/version/desktop-ui-parity.json"
    raise ValueError("release evidence path is outside the exact archive map")


def _map_evidence_paths(value: object, identity: ReleaseIdentity) -> object:
    if isinstance(value, list):
        return [_map_evidence_paths(item, identity) for item in value]
    if isinstance(value, dict):
        mapped = {
            key: _map_evidence_paths(item, identity)
            for key, item in value.items()
        }
        if "path" in mapped:
            mapped["path"] = _map_evidence_path(mapped["path"], identity)
        return mapped
    return value


def _archive_projection(
    trees: dict[str, Path],
    records: dict[str, Path],
    identity: ReleaseIdentity,
) -> tuple[dict[str, bytes], dict[str, bytes]]:
    contract = load_json_object(trees["version"] / "desktop-ui-parity.json")
    mapped_contract = _map_evidence_paths(contract, identity)
    if not isinstance(mapped_contract, dict):
        raise ValueError("desktop parity contract is malformed")
    contract_bytes = _canonical_json_bytes(mapped_contract)

    verification = load_json_object(records["ipadVerification"])
    mapped_verification = dict(verification)
    xcui_evidence = _map_evidence_paths(
        verification.get("xcuiEvidence"),
        identity,
    )
    if not isinstance(xcui_evidence, dict):
        raise ValueError("iPad verification XCUI evidence is missing")
    mapped_verification["xcuiEvidence"] = xcui_evidence
    parity_contract = xcui_evidence.get("parityContract")
    if not isinstance(parity_contract, dict):
        raise ValueError("iPad verification parity contract is malformed")
    parity_contract["sha256"] = hashlib.sha256(contract_bytes).hexdigest()
    verification_bytes = _canonical_json_bytes(mapped_verification)
    return (
        {"desktop-ui-parity.json": contract_bytes},
        {"ipadVerification": verification_bytes},
    )


def _require_sha256(value: object, *, label: str) -> str:
    if not isinstance(value, str) or SHA256_PATTERN.fullmatch(value) is None:
        raise ValueError(f"{label} hash is malformed")
    return value


def _resolve_archived_path(
    release_root: Path,
    raw: object,
    *,
    label: str,
) -> Path:
    relative = _require_lexical_relative_path(raw, label=label)
    candidate = release_root
    for component in relative.split("/"):
        candidate = candidate / component
        try:
            mode = candidate.lstat().st_mode
        except FileNotFoundError as error:
            raise ValueError(f"{label} is missing") from error
        if stat.S_ISLNK(mode):
            raise ValueError(f"{label} contains a symlink")
    try:
        candidate.relative_to(release_root)
    except ValueError as error:
        raise ValueError(f"{label} escapes the release archive") from error
    return candidate


def _verify_archived_file_evidence(
    release_root: Path,
    record: object,
    *,
    label: str,
    expected_path: str | None = None,
    expected_bytes: object | None = None,
) -> Path:
    if not isinstance(record, dict):
        raise ValueError(f"{label} record is malformed")
    if expected_path is not None and record.get("path") != expected_path:
        raise ValueError(f"{label} path is malformed")
    expected_sha256 = _require_sha256(
        record.get("sha256"),
        label=label,
    )
    path = _resolve_archived_path(
        release_root,
        record.get("path"),
        label=label,
    )
    if not path.is_file() or sha256_file(path) != expected_sha256:
        raise ValueError(f"{label} hash mismatch")
    if expected_bytes is not None:
        if (
            isinstance(expected_bytes, bool)
            or not isinstance(expected_bytes, int)
            or expected_bytes < 0
            or path.stat().st_size != expected_bytes
        ):
            raise ValueError(f"{label} byte count mismatch")
    return path


def _verify_desktop_evidence(
    release_root: Path,
    contract: dict[str, Any],
) -> None:
    surfaces = contract.get("surfaces")
    if not isinstance(surfaces, list):
        raise ValueError("desktop parity surfaces are malformed")
    recovered_prefix = (
        "derived/fullReverse/recovered-electron-source/"
    )
    for surface_index, surface in enumerate(surfaces):
        if not isinstance(surface, dict):
            raise ValueError("desktop parity surface is malformed")
        evidence = surface.get("desktopEvidence")
        if not isinstance(evidence, list):
            raise ValueError("desktop parity evidence is malformed")
        for evidence_index, entry in enumerate(evidence):
            label = (
                f"desktop parity surface {surface_index} "
                f"evidence {evidence_index}"
            )
            if not isinstance(entry, dict):
                raise ValueError(f"{label} record is malformed")
            relative = _require_lexical_relative_path(
                entry.get("file"),
                label=label,
            )
            archived = {
                "path": recovered_prefix + relative,
                "sha256": entry.get("sha256"),
            }
            _verify_archived_file_evidence(
                release_root,
                archived,
                label=label,
                expected_bytes=entry.get("bytes"),
            )


def _verify_contract_path_evidence(
    release_root: Path,
    value: object,
    *,
    label: str,
) -> None:
    if isinstance(value, list):
        for index, item in enumerate(value):
            _verify_contract_path_evidence(
                release_root,
                item,
                label=f"{label}[{index}]",
            )
        return
    if not isinstance(value, dict):
        return
    if "path" in value:
        path = value.get("path")
        if (
            not isinstance(path, str)
            or not path.startswith("derived/parityEvidence/")
        ):
            raise ValueError(f"{label} path is outside parity evidence")
        _verify_archived_file_evidence(
            release_root,
            value,
            label=label,
        )
    for key, item in value.items():
        if key != "desktopEvidence":
            _verify_contract_path_evidence(
                release_root,
                item,
                label=f"{label}.{key}",
            )


def _require_nonnegative_number(value: object, *, label: str) -> float:
    if (
        isinstance(value, bool)
        or not isinstance(value, (int, float))
        or not math.isfinite(value)
        or value < 0
    ):
        raise ValueError(f"{label} is malformed")
    return float(value)


def _require_nonnegative_count(value: object, *, label: str) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or value < 0:
        raise ValueError(f"{label} is malformed")
    return value


def _verify_archived_parity_evidence(
    release_root: Path,
    records: dict[str, Path],
    identity: ReleaseIdentity,
) -> None:
    contract_path = (
        release_root / "derived/version/desktop-ui-parity.json"
    )
    if contract_path.is_symlink() or not contract_path.is_file():
        raise ValueError("archived desktop parity contract is missing")
    contract = load_json_object(contract_path)
    source_identity = contract.get("sourceIdentity")
    if (
        contract.get("schemaVersion") != CURRENT_SCHEMA_VERSION
        or contract.get("desktopVersion") != identity.version
        or str(contract.get("desktopBuild", "")) != identity.build
        or not isinstance(source_identity, dict)
        or source_identity.get("dmgSha256") != identity.dmg_sha256
    ):
        raise ValueError("archived desktop parity contract identity mismatch")
    interaction_path = (
        release_root
        / "derived/version/desktop-interaction-inventory.json"
    )
    try:
        interaction_inventory = load_json_object(interaction_path)
    except (FileNotFoundError, json.JSONDecodeError, ValueError) as error:
        raise ValueError("desktop interaction inventory is missing") from error
    verify_desktop_interaction_inventory(
        interaction_inventory,
        release_root / "derived/fullReverse/recovered-electron-source",
        desktop_version=identity.version,
        desktop_build=identity.build,
        desktop_surface_tree_sha256=str(
            source_identity.get("desktopSurfaceTreeSha256", "")
        ),
    )
    _verify_desktop_evidence(release_root, contract)
    _verify_contract_path_evidence(
        release_root,
        contract,
        label="desktop parity contract",
    )

    verification = load_json_object(records["ipadVerification"])
    evidence = verification.get("xcuiEvidence")
    if not isinstance(evidence, dict):
        raise ValueError("archived XCUI evidence is missing")
    total = _require_nonnegative_count(
        evidence.get("totalTestCount"),
        label="XCUI total test count",
    )
    passed = _require_nonnegative_count(
        evidence.get("passedTests"),
        label="XCUI passed test count",
    )
    failed = _require_nonnegative_count(
        evidence.get("failedTests"),
        label="XCUI failed test count",
    )
    skipped = _require_nonnegative_count(
        evidence.get("skippedTests"),
        label="XCUI skipped test count",
    )
    expected_failures = _require_nonnegative_count(
        evidence.get("expectedFailures"),
        label="XCUI expected failure count",
    )
    start = _require_nonnegative_number(
        evidence.get("startTime"),
        label="XCUI start time",
    )
    finish = _require_nonnegative_number(
        evidence.get("finishTime"),
        label="XCUI finish time",
    )
    if (
        evidence.get("result") != "Passed"
        or total <= 0
        or passed != total
        or failed != 0
        or skipped != 0
        or expected_failures != 0
        or finish < start
        or verification.get("xcuiTestCount") != total
    ):
        raise ValueError("archived XCUI evidence did not pass")

    _verify_archived_file_evidence(
        release_root,
        evidence.get("parityContract"),
        label="archived XCUI parity contract",
        expected_path="derived/version/desktop-ui-parity.json",
    )
    summary_path = _verify_archived_file_evidence(
        release_root,
        evidence.get("summary"),
        label="archived XCUI summary",
        expected_path=(
            "derived/parityEvidence/verification/xcui-summary.json"
        ),
    )
    summary = load_json_object(summary_path)
    for field in (
        "result",
        "totalTestCount",
        "passedTests",
        "failedTests",
        "skippedTests",
        "expectedFailures",
        "startTime",
        "finishTime",
    ):
        if summary.get(field) != evidence.get(field):
            raise ValueError("archived XCUI summary does not match evidence")
    logs = evidence.get("logs")
    if not isinstance(logs, dict) or set(logs) != XCUI_LOG_NAMES:
        raise ValueError("archived XCUI logs are incomplete")
    for name, entry in logs.items():
        log_path = _verify_archived_file_evidence(
            release_root,
            entry,
            label=f"archived XCUI log {name}",
            expected_path=(
                "derived/parityEvidence/verification/"
                + XCUI_LOG_FILES[name]
            ),
        )
        if log_path.stat().st_size <= 0:
            raise ValueError(f"archived XCUI log {name} is empty")

    xcresult = evidence.get("xcresult")
    if (
        not isinstance(xcresult, dict)
        or xcresult.get("hashAlgorithm") != XCRESULT_HASH_ALGORITHM
    ):
        raise ValueError("archived XCResult identity is malformed")
    expected_xcresult_hash = _require_sha256(
        xcresult.get("sha256"),
        label="archived XCResult",
    )
    xcresult_path = _resolve_archived_path(
        release_root,
        xcresult.get("path"),
        label="archived XCResult",
    )
    if xcresult.get("path") != (
        "derived/parityEvidence/verification/CodexPadUITests.xcresult"
    ):
        raise ValueError("archived XCResult path is malformed")
    if not xcresult_path.is_dir():
        raise ValueError("archived XCResult bundle is missing")
    _reject_tree_symlinks(xcresult_path, label="archived XCResult")
    if _xcresult_sha256(xcresult_path) != expected_xcresult_hash:
        raise ValueError("archived XCResult hash mismatch")


def _require_passed_release_records(
    trees: dict[str, Path],
    records: dict[str, Path],
    identity: ReleaseIdentity,
    *,
    allow_legacy_simulator_evidence: bool = False,
) -> None:
    _record_identity(
        records["importManifest"],
        identity,
        version_key="version",
        build_key="build",
        sha_key="dmg_sha256",
        label="import manifest",
    )
    _record_identity(
        trees["version"] / "manifest.json",
        identity,
        version_key="version",
        build_key="build",
        sha_key="dmgSha256",
        label="version manifest",
    )
    _record_identity(
        trees["fullReverse"] / "full-reverse-manifest.json",
        identity,
        version_key="version",
        build_key="build",
        sha_key=None,
        label="full reverse manifest",
    )
    upgrade = _record_identity(
        records["ipadUpgrade"],
        identity,
        version_key="desktopVersion",
        build_key="desktopBuild",
        sha_key=None,
        label="iPad upgrade record",
    )
    for field in (
        "modelCatalogGenerated",
        "buildMetadataGenerated",
        "codexCoreUpgraded",
        "xcframeworkRebuilt",
    ):
        if upgrade.get(field) is not True:
            raise ValueError(f"iPad upgrade record {field} did not pass")

    verification = _record_identity(
        records["ipadVerification"],
        identity,
        version_key="desktopVersion",
        build_key="desktopBuild",
        sha_key=None,
        label="iPad verification record",
    )
    if (
        verification.get("productName") != "Codex for ipad"
        or verification.get("bundleVersionMatched") is not True
        or verification.get("bundleBuildMatched") is not True
        or verification.get("deviceArchitecture") != "arm64"
    ):
        raise ValueError("iPad verification record did not pass")
    for field in (
        "rustTests",
        "swiftTests",
        "xcuiTests",
        "deviceBuild",
        "desktopSurfaceCompleteTree",
    ):
        if verification.get(field) != "passed":
            raise ValueError(f"iPad verification record {field} did not pass")
    if verification.get("physicalDeviceTests") != "passed":
        if not (
            allow_legacy_simulator_evidence
            and verification.get("simulatorBuild") == "passed"
        ):
            raise ValueError(
                "iPad verification record physicalDeviceTests did not pass"
            )
    swift_test_count = verification.get("swiftTestCount")
    if (
        isinstance(swift_test_count, bool)
        or not isinstance(swift_test_count, int)
        or swift_test_count <= 0
    ):
        raise ValueError("iPad verification record has no Swift tests")
    source_identity = verification.get("sourceIdentity")
    if (
        not isinstance(source_identity, dict)
        or source_identity.get("dmgSha256") != identity.dmg_sha256
    ):
        raise ValueError("iPad verification source identity did not match")
    surface_summary = verification.get("desktopSurface")
    if (
        not isinstance(surface_summary, dict)
        or surface_summary.get("deviceBundleVerified") is not True
    ):
        raise ValueError("iPad verification surface record did not pass")
    if (
        allow_legacy_simulator_evidence
        and verification.get("physicalDeviceTests") != "passed"
        and surface_summary.get("simulatorBundleVerified") is not True
    ):
        raise ValueError("legacy iPad simulator surface record did not pass")

    info_path = records["infoPlist"]
    if info_path.is_symlink() or not info_path.is_file():
        raise ValueError("official Info.plist is missing")
    with info_path.open("rb") as stream:
        info = plistlib.load(stream)
    if (
        not isinstance(info, dict)
        or info.get("CFBundleShortVersionString") != identity.version
        or str(info.get("CFBundleVersion", "")) != identity.build
    ):
        raise ValueError("official Info.plist does not match release identity")


def _source_layout(
    project_root: Path,
    identity: ReleaseIdentity,
) -> tuple[dict[str, Path], dict[str, Path]]:
    trees = {
        "appAsar": (
            project_root / f"artifacts/app-asar-{identity.version}"
        ),
        "fullReverse": (
            project_root / f"artifacts/full-reverse-{identity.version}"
        ),
        "version": project_root / f"versions/{identity.version}",
        "parityEvidence": (
            project_root / f"artifacts/parity-evidence/{identity.version}"
        ),
    }
    records = {
        "importManifest": (
            project_root / f"artifacts/manifest-{identity.version}.json"
        ),
        "ipadUpgrade": (
            project_root / f"artifacts/ipad-upgrade-{identity.version}.json"
        ),
        "ipadVerification": (
            project_root / f"artifacts/ipad-verified-{identity.version}.json"
        ),
        "infoPlist": (
            project_root / f"artifacts/Info-{identity.version}.plist"
        ),
        "entitlements": (
            project_root / f"artifacts/entitlements-{identity.version}.plist"
        ),
    }
    return trees, records


def _source_snapshot(
    project_root: Path,
    identity: ReleaseIdentity,
    dmg_path: Path,
) -> tuple[dict[str, dict[str, object]], dict[str, dict[str, object]]]:
    if dmg_path.is_symlink() or not dmg_path.is_file():
        raise ValueError("official DMG is missing")
    if sha256_file(dmg_path) != identity.dmg_sha256:
        raise ValueError("official DMG hash does not match release identity")

    trees, records = _source_layout(project_root, identity)
    _require_passed_release_records(trees, records, identity)
    tree_file_overrides, record_overrides = _archive_projection(
        trees,
        records,
        identity,
    )

    tree_rows = {}
    for name, path in trees.items():
        file_overrides = (
            tree_file_overrides if name == "version" else None
        )
        tree_rows[name] = {
            "path": f"derived/{name}",
            **_tree_identity(
                path,
                file_overrides=file_overrides,
                ignore_volatile=True,
            ),
        }
    record_rows: dict[str, dict[str, object]] = {}
    for name, path in records.items():
        if not path.is_file():
            if name == "entitlements":
                continue
            raise ValueError(f"release record is missing: {name}")
        projected = record_overrides.get(name)
        record_rows[name] = {
            "path": f"records/{path.name}",
            "bytes": len(projected) if projected is not None else path.stat().st_size,
            "sha256": (
                hashlib.sha256(projected).hexdigest()
                if projected is not None
                else sha256_file(path)
            ),
        }
    return tree_rows, record_rows


def _verify_manifest_files(
    release_root: Path,
    manifest: dict[str, Any],
    identity: ReleaseIdentity,
) -> None:
    official = manifest.get("officialPackage")
    if (
        not isinstance(official, dict)
        or set(official) != {"path", "bytes", "sha256"}
        or official.get("path") != "official/ChatGPT.dmg"
        or official.get("sha256") != identity.dmg_sha256
        or isinstance(official.get("bytes"), bool)
        or not isinstance(official.get("bytes"), int)
        or official["bytes"] <= 0
    ):
        raise ValueError("release official package record is malformed")
    official_path = release_root / "official/ChatGPT.dmg"
    if (
        official_path.is_symlink()
        or not official_path.is_file()
        or official_path.stat().st_size != official.get("bytes")
        or sha256_file(official_path) != official.get("sha256")
    ):
        raise ValueError("archived official DMG does not match manifest")

    schema_version = manifest.get("schemaVersion")
    if isinstance(schema_version, bool) or schema_version not in {
        LEGACY_SCHEMA_VERSION,
        CURRENT_SCHEMA_VERSION,
    }:
        raise ValueError("release manifest schema is unsupported")
    expected_derived_names = (
        LEGACY_DERIVED_NAMES
        if schema_version == LEGACY_SCHEMA_VERSION
        else CURRENT_DERIVED_NAMES
    )
    derived = manifest.get("derived")
    if not isinstance(derived, dict) or set(derived) != expected_derived_names:
        raise ValueError("release derived tree records are malformed")
    for name, expected in derived.items():
        if not isinstance(expected, dict):
            raise ValueError(f"release derived tree is malformed: {name}")
        if set(expected) != {"path", *TREE_IDENTITY_KEYS}:
            raise ValueError(f"release derived tree is malformed: {name}")
        _require_tree_identity_types(
            expected,
            label=f"release derived tree {name}",
        )
        relative = expected.get("path")
        if relative != f"derived/{name}":
            raise ValueError(f"release derived tree path is malformed: {name}")
        expected_identity = {
            key: expected.get(key)
            for key in TREE_IDENTITY_KEYS
        }
        archived_tree = release_root / relative
        actual = _tree_identity(archived_tree)
        if (
            actual != expected_identity
            and not (
                schema_version == LEGACY_SCHEMA_VERSION
                and _tree_identity(
                    archived_tree,
                    ignore_volatile=True,
                )
                == expected_identity
            )
        ):
            raise ValueError(f"release derived tree hash mismatch: {name}")

    records = manifest.get("records")
    if not isinstance(records, dict):
        raise ValueError("release records are malformed")
    record_names = frozenset(records)
    if (
        not REQUIRED_RECORD_NAMES.issubset(record_names)
        or not record_names.issubset(
            REQUIRED_RECORD_NAMES | OPTIONAL_RECORD_NAMES
        )
    ):
        raise ValueError("release records are incomplete or unexpected")
    archived_records: dict[str, Path] = {}
    expected_record_paths = {
        "importManifest": f"records/manifest-{identity.version}.json",
        "ipadUpgrade": f"records/ipad-upgrade-{identity.version}.json",
        "ipadVerification": (
            f"records/ipad-verified-{identity.version}.json"
        ),
        "infoPlist": f"records/Info-{identity.version}.plist",
        "entitlements": (
            f"records/entitlements-{identity.version}.plist"
        ),
    }
    for name, expected in records.items():
        if (
            not isinstance(expected, dict)
            or set(expected) != {"path", "bytes", "sha256"}
            or isinstance(expected.get("bytes"), bool)
            or not isinstance(expected.get("bytes"), int)
            or expected["bytes"] <= 0
            or not isinstance(expected.get("sha256"), str)
            or SHA256_PATTERN.fullmatch(expected["sha256"]) is None
        ):
            raise ValueError(f"release record is malformed: {name}")
        relative = expected.get("path")
        if relative != expected_record_paths[name]:
            raise ValueError(f"release record path is malformed: {name}")
        path = release_root / relative
        if (
            path.is_symlink()
            or not path.is_file()
            or path.stat().st_size != expected.get("bytes")
            or sha256_file(path) != expected.get("sha256")
        ):
            raise ValueError(f"release record hash mismatch: {name}")
        archived_records[name] = path
    _require_passed_release_records(
        {
            name: release_root / f"derived/{name}"
            for name in LEGACY_DERIVED_NAMES
        },
        archived_records,
        identity,
        allow_legacy_simulator_evidence=(
            schema_version == LEGACY_SCHEMA_VERSION
        ),
    )
    if schema_version == CURRENT_SCHEMA_VERSION:
        _verify_archived_parity_evidence(
            release_root,
            archived_records,
            identity,
        )


def verify_release_archive(
    project_root: Path,
    identity: ReleaseIdentity,
) -> dict[str, Any]:
    release_root = _require_safe_archive_root(project_root, identity)
    if not release_root.is_dir():
        raise ValueError("release archive is missing")
    manifest_path = release_root / MANIFEST_NAME
    if manifest_path.is_symlink() or not manifest_path.is_file():
        raise ValueError("release manifest is missing")
    manifest = load_json_object(manifest_path)
    if set(manifest) != MANIFEST_KEYS:
        raise ValueError("release manifest fields are malformed")
    require_matching_release_identity(
        manifest,
        identity,
        label="release manifest",
    )
    schema_version = manifest.get("schemaVersion")
    if isinstance(schema_version, bool) or schema_version not in {
        LEGACY_SCHEMA_VERSION,
        CURRENT_SCHEMA_VERSION,
    }:
        raise ValueError("release manifest schema is unsupported")
    _verify_manifest_files(release_root, manifest, identity)
    return manifest


def verify_live_release_snapshot(
    project_root: Path,
    identity: ReleaseIdentity,
    manifest: dict[str, Any],
) -> None:
    derived = manifest.get("derived")
    if not isinstance(derived, dict):
        raise ValueError("release derived tree records are malformed")
    schema_version = manifest.get("schemaVersion")
    if isinstance(schema_version, bool) or schema_version not in {
        LEGACY_SCHEMA_VERSION,
        CURRENT_SCHEMA_VERSION,
    }:
        raise ValueError("release manifest schema is unsupported")
    expected_tree_names = (
        LEGACY_DERIVED_NAMES
        if schema_version == LEGACY_SCHEMA_VERSION
        else CURRENT_DERIVED_NAMES
    )
    if set(derived) != expected_tree_names:
        raise ValueError("release derived tree records are malformed")
    live_trees, live_records = _source_layout(
        project_root.resolve(),
        identity,
    )
    expected_records = manifest.get("records")
    if not isinstance(expected_records, dict):
        raise ValueError("release records are malformed")
    for name, live_record in live_records.items():
        expected = expected_records.get(name)
        if expected is None:
            if live_record.exists() or live_record.is_symlink():
                raise ValueError(
                    f"live release record does not match archive: {name}"
                )
            continue
        if live_record.is_symlink() or not live_record.is_file():
            raise ValueError(f"live release record is missing: {name}")
    tree_file_overrides: dict[str, bytes] = {}
    record_overrides: dict[str, bytes] = {}
    if schema_version == CURRENT_SCHEMA_VERSION:
        for name in CURRENT_DERIVED_NAMES:
            live_tree = live_trees[name]
            if live_tree.is_symlink() or not live_tree.is_dir():
                raise ValueError(f"live release tree is missing: {name}")
        for name in REQUIRED_RECORD_NAMES:
            live_record = live_records[name]
            if live_record.is_symlink() or not live_record.is_file():
                raise ValueError(f"live release record is missing: {name}")
        tree_file_overrides, record_overrides = _archive_projection(
            live_trees,
            live_records,
            identity,
        )
    for name in expected_tree_names:
        live_tree = live_trees[name]
        expected = derived.get(name)
        if not isinstance(expected, dict):
            raise ValueError(
                f"release derived tree is malformed: {name}"
            )
        actual = _tree_identity(
            live_tree,
            file_overrides=(
                tree_file_overrides if name == "version" else None
            ),
            ignore_volatile=True,
        )
        expected_identity = {
            key: expected.get(key)
            for key in TREE_IDENTITY_KEYS
        }
        if actual != expected_identity:
            raise ValueError(
                f"live release tree does not match archive: {name}"
            )
    for name, live_record in live_records.items():
        expected = expected_records.get(name)
        if expected is None:
            continue
        projected = record_overrides.get(name)
        actual_bytes = (
            len(projected) if projected is not None else live_record.stat().st_size
        )
        actual_sha256 = (
            hashlib.sha256(projected).hexdigest()
            if projected is not None
            else sha256_file(live_record)
        )
        if (
            actual_bytes != expected.get("bytes")
            or actual_sha256 != expected.get("sha256")
        ):
            raise ValueError(
                f"live release record does not match archive: {name}"
            )


def archive_release(
    project_root: Path,
    identity: ReleaseIdentity,
    dmg_path: Path,
) -> dict[str, Any]:
    project_root = project_root.resolve()
    release_root = _require_safe_archive_root(project_root, identity)
    source_trees, source_records = _source_snapshot(
        project_root,
        identity,
        dmg_path.resolve(),
    )
    expected_manifest = {
        "schemaVersion": CURRENT_SCHEMA_VERSION,
        "version": identity.version,
        "build": identity.build,
        "dmgSha256": identity.dmg_sha256,
        "officialPackage": {
            "path": "official/ChatGPT.dmg",
            "bytes": dmg_path.stat().st_size,
            "sha256": identity.dmg_sha256,
        },
        "derived": source_trees,
        "records": source_records,
    }

    if release_root.exists() or release_root.is_symlink():
        existing = verify_release_archive(project_root, identity)
        if existing != expected_manifest:
            raise ValueError(
                "existing release archive conflicts with current exact release"
            )
        return existing

    release_root.parent.mkdir(parents=True, exist_ok=True)
    staging = Path(
        tempfile.mkdtemp(
            prefix=f".{identity.dmg_sha256}.staging-",
            dir=release_root.parent,
        )
    )
    try:
        _clone_or_copy_file(
            dmg_path,
            staging / "official/ChatGPT.dmg",
        )
        trees, records = _source_layout(project_root, identity)
        for name, source in trees.items():
            destination = staging / f"derived/{name}"
            _clone_or_copy_tree(source, destination)
            _remove_volatile_derived_paths(destination)
        for name, source in records.items():
            if name not in source_records:
                continue
            _clone_or_copy_file(
                source,
                staging / str(source_records[name]["path"]),
            )
        tree_file_overrides, record_overrides = _archive_projection(
            trees,
            records,
            identity,
        )
        for relative, payload in tree_file_overrides.items():
            _write_bytes_atomic(
                staging / "derived/version" / relative,
                payload,
            )
        for name, payload in record_overrides.items():
            _write_bytes_atomic(
                staging / str(source_records[name]["path"]),
                payload,
            )
        write_json_atomic(staging / MANIFEST_NAME, expected_manifest)
        _verify_manifest_files(staging, expected_manifest, identity)
        try:
            os.replace(staging, release_root)
        except OSError:
            if not release_root.is_dir():
                raise
            existing = verify_release_archive(project_root, identity)
            if existing != expected_manifest:
                raise ValueError(
                    "concurrent release archive conflicts with exact release"
                )
        return verify_release_archive(project_root, identity)
    finally:
        if staging.exists():
            shutil.rmtree(staging)


def main() -> int:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(required=True)
    for command in ("archive", "verify"):
        child = subparsers.add_parser(command)
        child.add_argument("--project-root", type=Path, required=True)
        child.add_argument("--version", required=True)
        child.add_argument("--build", required=True)
        child.add_argument("--dmg-sha256", required=True)
        if command == "archive":
            child.add_argument("--dmg", type=Path, required=True)
    args = parser.parse_args()
    try:
        identity = ReleaseIdentity(
            args.version,
            args.build,
            args.dmg_sha256,
        )
        if args.__dict__.get("dmg") is not None:
            archive_release(args.project_root, identity, args.dmg)
        else:
            verify_release_archive(args.project_root, identity)
    except (OSError, ValueError, TypeError, json.JSONDecodeError) as error:
        parser.error(str(error))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
