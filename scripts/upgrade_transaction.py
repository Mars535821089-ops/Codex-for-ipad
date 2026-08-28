#!/usr/bin/env python3
"""Snapshot and restore the mutable portion of an iPad upgrade."""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import tempfile
from pathlib import Path
from typing import Any, Iterable


MANIFEST_NAME = "manifest.json"
VERSION_PATTERN = re.compile(r"^[0-9]+(?:\.[0-9]+)+$")
TRANSACTION_ROOT = Path(".update-state") / "transactions"


def transaction_paths(
    root: Path,
    version: str,
) -> list[tuple[Path, str]]:
    if VERSION_PATTERN.fullmatch(version) is None:
        raise ValueError("desktop version is malformed")
    copied = (
        "CodexCore/Cargo.toml",
        "CodexCore/Cargo.lock",
        "CodexCore/src/official_provider.rs",
        "CodexCore/resources/models.json",
        "CodexCore/resources/client-version.txt",
        "CodexPad/CodexPad/Domain/CodexModelCatalog.generated.swift",
        "CodexPad/CodexPad/Domain/CodexBuildMetadata.generated.swift",
        (
            "CodexPad/CodexPad/Application/"
            "CodexExperimentalFeatureCatalog.generated.swift"
        ),
        "CodexPad/CodexPad/Application/Resources/skills",
        f"versions/{version}/model-catalog.json",
        (
            "CodexPad/CodexPad/Resources/Assets.xcassets/"
            "AppIcon.appiconset"
        ),
        "CodexPad/CodexPad.xcodeproj/project.pbxproj",
        (
            "CodexPad/CodexPad.xcodeproj/xcshareddata/"
            "xcschemes/CodexPad.xcscheme"
        ),
        "artifacts/latest-official.json",
    )
    moved = (
        f"artifacts/app-asar-{version}",
        f"artifacts/full-reverse-{version}",
        f"artifacts/Info-{version}.plist",
        f"artifacts/entitlements-{version}.plist",
        f"artifacts/manifest-{version}.json",
        f"versions/{version}",
        "build/CodexCore.xcframework",
        f"artifacts/ipad-upgrade-{version}.json",
        f"artifacts/ipad-verified-{version}.json",
        f"artifacts/ipad-release/{version}",
        f"artifacts/parity-evidence/{version}",
        "DerivedData/UpdaterVerification",
    )
    return [
        *((root / relative, "copy") for relative in copied),
        *((root / relative, "move") for relative in moved),
    ]


def _path_kind(path: Path) -> str:
    if path.is_symlink():
        return "symlink"
    if path.is_file():
        return "file"
    if path.is_dir():
        return "directory"
    if path.exists():
        raise ValueError(f"unsupported transaction path type: {path}")
    return "absent"


def _copy_path(source: Path, destination: Path, kind: str) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    if kind == "directory":
        shutil.copytree(source, destination, symlinks=True)
    elif kind in {"file", "symlink"}:
        shutil.copy2(source, destination, follow_symlinks=False)
    else:
        raise ValueError(f"unsupported snapshot kind: {kind}")


def _remove_path(path: Path) -> None:
    if path.is_symlink() or path.is_file():
        path.unlink()
    elif path.is_dir():
        shutil.rmtree(path)
    elif path.exists():
        raise ValueError(f"unsupported transaction path type: {path}")


def _write_json_atomic(path: Path, value: dict[str, Any]) -> None:
    temporary: Path | None = None
    path.parent.mkdir(parents=True, exist_ok=True)
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


def _relative_to_root(root: Path, path: Path) -> str:
    try:
        return path.relative_to(root).as_posix()
    except ValueError as error:
        raise ValueError(f"transaction path escapes project root: {path}") from error


def _validated_root_and_transaction(
    root: Path,
    transaction: Path,
) -> tuple[Path, Path]:
    root = root.resolve()
    if not root.is_dir():
        raise ValueError("project root is missing")
    transaction = transaction.resolve()
    expected_parent = (root / TRANSACTION_ROOT).resolve()
    if transaction.parent != expected_parent:
        raise ValueError(
            "transaction directory is outside the expected transaction root"
        )
    return root, transaction


def snapshot(root: Path, version: str, transaction: Path) -> None:
    root, transaction = _validated_root_and_transaction(root, transaction)
    if transaction.exists():
        raise ValueError("transaction directory already exists")

    entries = []
    for index, (path, strategy) in enumerate(transaction_paths(root, version)):
        entries.append(
            {
                "relative_path": _relative_to_root(root, path),
                "strategy": strategy,
                "kind": _path_kind(path),
                "backup": f"data/{index}",
            }
        )
    manifest = {
        "schema_version": 1,
        "project_root": str(root),
        "desktop_version": version,
        "entries": entries,
    }

    transaction.mkdir(parents=True)
    _write_json_atomic(transaction / MANIFEST_NAME, manifest)
    try:
        for entry in entries:
            if entry["kind"] == "absent":
                continue
            source = root / entry["relative_path"]
            backup = transaction / entry["backup"]
            if entry["strategy"] == "move":
                backup.parent.mkdir(parents=True, exist_ok=True)
                shutil.move(str(source), str(backup))
            else:
                _copy_path(source, backup, entry["kind"])
    except BaseException:
        _restore_partial_snapshot(root, transaction, entries)
        raise


def _restore_partial_snapshot(
    root: Path,
    transaction: Path,
    entries: Iterable[dict[str, Any]],
) -> None:
    for entry in reversed(list(entries)):
        if entry["strategy"] != "move":
            continue
        backup = transaction / entry["backup"]
        if not backup.exists() and not backup.is_symlink():
            continue
        target = root / entry["relative_path"]
        target.parent.mkdir(parents=True, exist_ok=True)
        _remove_path(target)
        shutil.move(str(backup), str(target))
    shutil.rmtree(transaction, ignore_errors=True)


def _load_manifest(
    root: Path,
    transaction: Path,
) -> tuple[Path, Path, dict[str, Any]]:
    root, transaction = _validated_root_and_transaction(root, transaction)
    manifest_path = transaction / MANIFEST_NAME
    value = json.loads(manifest_path.read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise ValueError("transaction manifest is malformed")
    if value.get("schema_version") != 1:
        raise ValueError("transaction manifest schema is unsupported")
    if value.get("project_root") != str(root):
        raise ValueError("transaction belongs to a different project root")
    entries = value.get("entries")
    if not isinstance(entries, list):
        raise ValueError("transaction manifest entries are malformed")
    return root, transaction, value


def _safe_manifest_target(root: Path, relative: Any) -> Path:
    if not isinstance(relative, str) or not relative:
        raise ValueError("transaction path is malformed")
    relative_path = Path(relative)
    if relative_path.is_absolute() or ".." in relative_path.parts:
        raise ValueError("transaction path escapes project root")
    return root / relative_path


def _safe_backup_path(transaction: Path, relative: Any) -> Path:
    if not isinstance(relative, str) or not relative:
        raise ValueError("transaction backup path is malformed")
    relative_path = Path(relative)
    if relative_path.is_absolute() or ".." in relative_path.parts:
        raise ValueError("transaction backup path escapes transaction")
    return transaction / relative_path


def _validated_manifest_entries(
    root: Path,
    transaction: Path,
    manifest: dict[str, Any],
) -> list[tuple[Path, str, str, Path]]:
    version = manifest.get("desktop_version")
    if not isinstance(version, str) or VERSION_PATTERN.fullmatch(version) is None:
        raise ValueError("transaction desktop version is malformed")
    entries = manifest["entries"]
    expected = transaction_paths(root, version)
    if len(entries) != len(expected):
        raise ValueError("transaction manifest does not contain expected entries")

    validated = []
    for index, (entry, (expected_target, expected_strategy)) in enumerate(
        zip(entries, expected)
    ):
        if not isinstance(entry, dict):
            raise ValueError("transaction manifest entry is malformed")
        expected_relative = _relative_to_root(root, expected_target)
        expected_backup = f"data/{index}"
        if (
            entry.get("relative_path") != expected_relative
            or entry.get("strategy") != expected_strategy
            or entry.get("backup") != expected_backup
        ):
            raise ValueError(
                "transaction manifest does not contain expected entries"
            )

        target = _safe_manifest_target(root, entry["relative_path"])
        kind = entry.get("kind")
        if kind not in {"absent", "file", "directory", "symlink"}:
            raise ValueError("transaction manifest entry is malformed")
        backup = _safe_backup_path(transaction, entry["backup"])
        backup_exists = backup.exists() or backup.is_symlink()
        if kind == "absent":
            if backup_exists:
                raise ValueError(
                    f"transaction backup is unexpected: {expected_backup}"
                )
        elif not backup_exists:
            raise ValueError(
                f"transaction backup is missing: {expected_backup}"
            )
        elif _path_kind(backup) != kind:
            raise ValueError(
                f"transaction backup kind is malformed: {expected_backup}"
            )
        validated.append((target, kind, expected_strategy, backup))
    return validated


def restore(root: Path, transaction: Path) -> None:
    root, transaction, manifest = _load_manifest(root, transaction)
    validated = _validated_manifest_entries(root, transaction, manifest)

    for target, kind, _strategy, backup in validated:
        _remove_path(target)
        if kind == "absent":
            continue
        _copy_path(backup, target, kind)
    shutil.rmtree(transaction)


def commit(root: Path, transaction: Path) -> None:
    root, transaction, manifest = _load_manifest(root, transaction)
    _validated_manifest_entries(root, transaction, manifest)
    shutil.rmtree(transaction)


def recover_pending(root: Path) -> list[Path]:
    root = root.resolve()
    if not root.is_dir():
        raise ValueError("project root is missing")
    transaction_root = (root / TRANSACTION_ROOT).resolve()
    transaction_root.mkdir(parents=True, exist_ok=True)
    pending = sorted(
        (path for path in transaction_root.iterdir() if path.is_dir()),
        key=lambda path: (path.stat().st_mtime_ns, path.name),
        reverse=True,
    )
    recovered: list[Path] = []
    for transaction in pending:
        manifest = transaction / MANIFEST_NAME
        if not manifest.exists():
            # snapshot writes its manifest before moving or copying any project
            # path. A manifest-free directory therefore contains no mutable
            # project state and is safe to discard only while data/ is absent.
            if (transaction / "data").exists():
                raise ValueError(
                    f"pending transaction has data but no manifest: {transaction.name}"
                )
            shutil.rmtree(transaction)
            recovered.append(transaction)
            continue
        restore(root, transaction)
        recovered.append(transaction)
    return recovered


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)

    snapshot_parser = subparsers.add_parser("snapshot")
    snapshot_parser.add_argument("--root", type=Path, required=True)
    snapshot_parser.add_argument("--version", required=True)
    snapshot_parser.add_argument(
        "--transaction-dir",
        type=Path,
        required=True,
    )

    restore_parser = subparsers.add_parser("restore")
    restore_parser.add_argument("--root", type=Path, required=True)
    restore_parser.add_argument(
        "--transaction-dir",
        type=Path,
        required=True,
    )

    commit_parser = subparsers.add_parser("commit")
    commit_parser.add_argument("--root", type=Path, required=True)
    commit_parser.add_argument(
        "--transaction-dir",
        type=Path,
        required=True,
    )
    recover_parser = subparsers.add_parser("recover-pending")
    recover_parser.add_argument("--root", type=Path, required=True)
    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    try:
        if args.command == "snapshot":
            snapshot(args.root, args.version, args.transaction_dir)
        elif args.command == "restore":
            restore(args.root, args.transaction_dir)
        elif args.command == "commit":
            commit(args.root, args.transaction_dir)
        else:
            recover_pending(args.root)
    except (OSError, ValueError, json.JSONDecodeError) as error:
        parser.error(str(error))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
