#!/usr/bin/env python3
"""Persist a complete, inspectable reverse baseline for one official bundle."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import stat
import subprocess
import tempfile
import time
from pathlib import Path

try:
    from scripts.build_recovered_source_index import index_source_tree
except ModuleNotFoundError:
    from build_recovered_source_index import index_source_tree


RECOVERABLE_SUFFIXES = {
    ".cjs",
    ".css",
    ".html",
    ".js",
    ".json",
    ".mjs",
}
STALE_STAGING_MIN_AGE_SECONDS = 6 * 60 * 60


def cleanup_stale_staging(
    destination: Path,
    *,
    now: float | None = None,
) -> list[Path]:
    """Remove expired sibling staging trees left by interrupted imports."""
    current_time = time.time() if now is None else now
    prefix = f".{destination.name}.staging-"
    removed: list[Path] = []
    if not destination.parent.is_dir():
        return removed
    for candidate in sorted(destination.parent.iterdir()):
        if (
            not candidate.name.startswith(prefix)
            or candidate.is_symlink()
            or not candidate.is_dir()
        ):
            continue
        try:
            age = current_time - candidate.stat().st_mtime
        except FileNotFoundError:
            continue
        if age < STALE_STAGING_MIN_AGE_SECONDS:
            continue
        shutil.rmtree(candidate)
        removed.append(candidate)
    return removed


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def copy_tree(source: Path, destination: Path) -> None:
    destination.mkdir(parents=True, exist_ok=True)
    subprocess.run(
        [
            "rsync",
            "-a",
            "--delete",
            f"{source}{os.sep}",
            f"{destination}{os.sep}",
        ],
        check=True,
    )


def copy_recoverable_source(asar_root: Path, output: Path) -> None:
    for relative_root in (Path(".vite"), Path("webview")):
        root = asar_root / relative_root
        if not root.exists():
            continue
        for source in root.rglob("*"):
            if (
                not source.is_file()
                or source.suffix.lower() not in RECOVERABLE_SUFFIXES
            ):
                continue
            destination = output / source.relative_to(asar_root)
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source, destination)


def format_recovered_source(output: Path) -> None:
    pattern = str(output / "**" / "*.{js,mjs,cjs,css,html,json}")
    subprocess.run(
        [
            "npx",
            "--yes",
            "prettier@3.6.2",
            "--ignore-path=/dev/null",
            "--write",
            pattern,
        ],
        check=True,
        stdout=subprocess.DEVNULL,
    )


def command_output(command: list[str], *, cwd: Path | None = None) -> str:
    completed = subprocess.run(
        command,
        check=False,
        cwd=cwd,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        errors="replace",
    )
    return completed.stdout


def is_executable(path: Path) -> bool:
    try:
        mode = path.stat().st_mode
    except OSError:
        return False
    return stat.S_ISREG(mode) and bool(mode & stat.S_IXUSR)


def build_binary_reports(resources: Path, output: Path) -> list[dict[str, object]]:
    reports: list[dict[str, object]] = []
    candidates: list[Path] = []
    for path in resources.rglob("*"):
        if not path.is_file():
            continue
        if is_executable(path) or path.suffix.lower() in {".node", ".dylib", ".wasm"}:
            candidates.append(path)

    for binary in sorted(candidates):
        relative = binary.relative_to(resources)
        relative_argument = relative.as_posix()
        report_base = output / relative
        report_base.parent.mkdir(parents=True, exist_ok=True)
        file_description = command_output(
            ["file", relative_argument],
            cwd=resources,
        ).strip()
        report = {
            "path": relative.as_posix(),
            "size": binary.stat().st_size,
            "sha256": sha256(binary),
            "file": file_description,
        }
        reports.append(report)
        (report_base.with_suffix(report_base.suffix + ".file.txt")).write_text(
            file_description + "\n",
            encoding="utf-8",
        )
        if "Mach-O" in file_description:
            (report_base.with_suffix(report_base.suffix + ".symbols.txt")).write_text(
                command_output(["nm", "-m", relative_argument], cwd=resources),
                encoding="utf-8",
            )
            (report_base.with_suffix(report_base.suffix + ".loads.txt")).write_text(
                command_output(["otool", "-L", relative_argument], cwd=resources),
                encoding="utf-8",
            )
        (report_base.with_suffix(report_base.suffix + ".strings.txt")).write_text(
            command_output(["strings", "-a", relative_argument], cwd=resources),
            encoding="utf-8",
        )
    return reports


def file_manifest(root: Path) -> list[dict[str, object]]:
    records: list[dict[str, object]] = []
    for path in sorted(root.rglob("*")):
        if path.is_file():
            records.append(
                {
                    "path": path.relative_to(root).as_posix(),
                    "size": path.stat().st_size,
                    "sha256": sha256(path),
                }
            )
    return records


def build_full_reverse(
    *,
    app: Path,
    asar_root: Path,
    official_source: Path,
    output: Path,
    version: str,
    build: str,
) -> dict[str, object]:
    resources = app / "Contents" / "Resources"
    asar_destination = output / "app-asar"
    copy_tree(asar_root, asar_destination)

    bundle_resources = output / "bundle-resources"
    bundle_resources.mkdir(parents=True, exist_ok=True)
    for source in resources.iterdir():
        if source.name in {"app.asar", "app.asar.unpacked"}:
            continue
        destination = bundle_resources / source.name
        if source.is_dir():
            copy_tree(source, destination)
        elif source.is_file():
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source, destination)

    source_destination = output / "official-codex-source"
    copy_tree(official_source, source_destination)

    recovered_source = output / "recovered-electron-source"
    copy_recoverable_source(asar_destination, recovered_source)
    format_recovered_source(recovered_source)
    recovered_source_index = output / "recovered-source-index.json"
    recovered_source_index.write_text(
        json.dumps(
            index_source_tree(recovered_source),
            ensure_ascii=False,
            indent=2,
        )
        + "\n",
        encoding="utf-8",
    )

    binary_reports = build_binary_reports(
        bundle_resources,
        output / "binary-analysis",
    )
    manifest = {
        "schemaVersion": 1,
        "version": version,
        "build": build,
        "officialAppBundle": file_manifest(app),
        "asar": file_manifest(asar_destination),
        "bundleResources": file_manifest(bundle_resources),
        "officialCodexSource": file_manifest(source_destination),
        "recoveredElectronSource": file_manifest(recovered_source),
        "recoveredSourceIndexSha256": sha256(recovered_source_index),
        "binaries": binary_reports,
    }
    (output / "full-reverse-manifest.json").write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    summary = {
        "version": version,
        "build": build,
        "officialAppBundleFiles": len(manifest["officialAppBundle"]),
        "asarFiles": len(manifest["asar"]),
        "bundleResourceFiles": len(manifest["bundleResources"]),
        "officialSourceFiles": len(manifest["officialCodexSource"]),
        "recoveredElectronFiles": len(manifest["recoveredElectronSource"]),
        "recoveredSourceIndexSha256": manifest["recoveredSourceIndexSha256"],
        "analyzedBinaries": len(binary_reports),
    }
    (output / "summary.json").write_text(
        json.dumps(summary, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    return summary


def promote_staged_output(staging: Path, destination: Path) -> None:
    if not destination.exists() and not destination.is_symlink():
        os.replace(staging, destination)
        return

    backup = Path(
        tempfile.mkdtemp(
            prefix=f".{destination.name}.backup-",
            dir=destination.parent,
        )
    )
    backup.rmdir()
    os.replace(destination, backup)
    try:
        os.replace(staging, destination)
    except BaseException:
        os.replace(backup, destination)
        raise
    else:
        shutil.rmtree(backup, ignore_errors=True)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", required=True, type=Path)
    parser.add_argument("--asar-root", required=True, type=Path)
    parser.add_argument("--official-source", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--version", required=True)
    parser.add_argument("--build", required=True)
    args = parser.parse_args()

    resources = args.app / "Contents" / "Resources"
    if not resources.is_dir() or not args.asar_root.is_dir():
        raise SystemExit("official resource or ASAR tree is missing")
    if not args.official_source.is_dir():
        raise SystemExit("official CLI source tree is missing")

    args.output.parent.mkdir(parents=True, exist_ok=True)
    cleanup_stale_staging(args.output)
    staging = Path(
        tempfile.mkdtemp(
            prefix=f".{args.output.name}.staging-",
            dir=args.output.parent,
        )
    )
    try:
        summary = build_full_reverse(
            app=args.app,
            asar_root=args.asar_root,
            official_source=args.official_source,
            output=staging,
            version=args.version,
            build=args.build,
        )
        promote_staged_output(staging, args.output)
    finally:
        if staging.exists():
            shutil.rmtree(staging)
    print(json.dumps(summary, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
