#!/usr/bin/env python3
"""Generate the dependency-free CodexPad Xcode project deterministically."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import stat
from pathlib import Path


DESKTOP_SURFACE_DIRECTORY_NAME = "CodexDesktopSurface"
BUNDLED_SKILLS_RESOURCE_PATH = "Application/Resources/skills"
BUNDLED_NODE_RUNTIME_RESOURCE_PATH = (
    "Application/Resources/NodeRuntime"
)
BUNDLED_NODE_MCP_PACKAGES_RESOURCE_PATH = (
    "Application/Resources/MCPPackages"
)
BUNDLED_PYTHON_MCP_PACKAGES_RESOURCE_PATH = (
    "Application/Resources/PythonPackages"
)
PYTHON_BRIDGE_SOURCE_PATH = (
    "CodexPythonRuntimeBridge/CodexPythonRuntimeBridge.m"
)
PYTHON_BRIDGE_HEADER_PATH = (
    "CodexPythonRuntimeBridge/include/"
    "CodexPythonRuntimeBridge.h"
)
IOS_SYSTEM_FRAMEWORK_PATHS = (
    "Vendor/ios_system/ios_system.xcframework",
    "Vendor/ios_system/files.xcframework",
    "Vendor/ios_system/shell.xcframework",
    "Vendor/ios_system/text.xcframework",
)
NODE_MOBILE_FRAMEWORK_PATH = (
    "Vendor/node_mobile/NodeMobile.xcframework"
)
NODE_MOBILE_LOCK_PATH = "Vendor/node_mobile/runtime-lock.json"
NODE_MOBILE_LOCK = {
    "schemaVersion": 1,
    "runtime": "NodeMobile",
    "version": "18.20.4",
    "sourceURL": (
        "https://github.com/nodejs-mobile/nodejs-mobile/"
        "releases/download/v18.20.4/"
        "nodejs-mobile-v18.20.4-ios.zip"
    ),
    "archiveBytes": 51_492_431,
    "archiveSha256": (
        "8c5ca3a0d1e38de7f182a5642593e8259"
        "3b820efd375a14b3ecafc4bcfee620e"
    ),
    "xcframeworkPath": "NodeMobile.xcframework",
}
PYTHON_FRAMEWORK_PATH = (
    "Vendor/python_apple/Python.xcframework"
)
PYTHON_RUNTIME_LOCK_PATH = (
    "Vendor/python_apple/runtime-lock.json"
)
PYTHON_RUNTIME_LOCK = {
    "schemaVersion": 1,
    "runtime": "CPython",
    "version": "3.13.14",
    "abi": "cp313",
    "sourceRepository": (
        "https://github.com/beeware/Python-Apple-support"
    ),
    "sourceTag": "3.13-b14",
    "sourceCommit": "54d8ab6ef4fbac4d60706f311a986aee5236c71b",
    "sourceURL": (
        "https://github.com/beeware/Python-Apple-support/"
        "releases/download/3.13-b14/"
        "Python-3.13-iOS-support.b14.tar.gz"
    ),
    "assetName": "Python-3.13-iOS-support.b14.tar.gz",
    "archiveBytes": 32_387_292,
    "archiveSha256": (
        "8b5cb76ef8d8a2946052479358eeec9d5"
        "4b4496cb60920e175ec1489b5cf7963"
    ),
    "xcframeworkPath": "Python.xcframework",
    "versionsPath": "VERSIONS",
    "compatibilityPatches": [
        {
            "id": "quote-fwork-placeholder-path",
            "path": (
                "Python.xcframework/build/utils.sh"
            ),
            "sha256": (
                "a4bb9d3e34f63ea0e022a013898df666"
                "96062f83b372dd9b947c415020c705f1"
            ),
        }
    ],
}


def _identifier(kind: str, value: str) -> str:
    digest = hashlib.sha256(f"{kind}:{value}".encode("utf-8")).hexdigest()
    return digest[:24].upper()


def _quote(value: str) -> str:
    escaped = value.replace("\\", "\\\\").replace('"', '\\"')
    return f'"{escaped}"'


def _file_type(path: str) -> str:
    if path.endswith(".swift"):
        return "sourcecode.swift"
    if path.endswith(".m"):
        return "sourcecode.c.objc"
    if path.endswith(".h"):
        return "sourcecode.c.h"
    if path.endswith(".xcassets"):
        return "folder.assetcatalog"
    if path.endswith(".plist"):
        return "text.plist.xml"
    if path in {
        BUNDLED_SKILLS_RESOURCE_PATH,
        BUNDLED_NODE_RUNTIME_RESOURCE_PATH,
        BUNDLED_NODE_MCP_PACKAGES_RESOURCE_PATH,
        BUNDLED_PYTHON_MCP_PACKAGES_RESOURCE_PATH,
    }:
        return "folder"
    raise ValueError(f"unsupported CodexPad project file: {path}")


def _desktop_surface_file_type(path: Path) -> str:
    if path.is_dir():
        return "folder"
    suffix_types = {
        ".css": "text.css",
        ".html": "text.html",
        ".js": "sourcecode.javascript",
        ".json": "text.json",
    }
    return suffix_types.get(path.suffix.lower(), "file")


def _discover_files(source_root: Path) -> tuple[list[str], list[str]]:
    swift_files = _discover_swift_files(source_root)
    asset_catalogs = sorted(
        path.relative_to(source_root).as_posix()
        for path in source_root.rglob("*.xcassets")
        if path.is_dir()
        and not _is_bundled_opaque_resource(path, source_root)
    )
    plist_resources = sorted(
        path.relative_to(source_root).as_posix()
        for path in source_root.rglob("*.plist")
        if path.is_file()
        and not _is_bundled_opaque_resource(path, source_root)
        and path.relative_to(source_root).as_posix()
            != "Resources/Info.plist"
    )
    resources = asset_catalogs + plist_resources
    bundled_skills = source_root / BUNDLED_SKILLS_RESOURCE_PATH
    if bundled_skills.exists() or bundled_skills.is_symlink():
        if bundled_skills.is_symlink() or not bundled_skills.is_dir():
            raise ValueError(
                "bundled recommended-skills resource must be a directory"
            )
        resources.append(BUNDLED_SKILLS_RESOURCE_PATH)
    node_runtime = (
        source_root / BUNDLED_NODE_RUNTIME_RESOURCE_PATH
    )
    if node_runtime.exists() or node_runtime.is_symlink():
        if node_runtime.is_symlink() or not node_runtime.is_dir():
            raise ValueError(
                "bundled Node runtime resource must be a directory"
            )
        resources.append(BUNDLED_NODE_RUNTIME_RESOURCE_PATH)
    node_mcp_packages = (
        source_root / BUNDLED_NODE_MCP_PACKAGES_RESOURCE_PATH
    )
    if node_mcp_packages.exists() or node_mcp_packages.is_symlink():
        _validate_bundled_node_mcp_packages(
            source_root,
            node_mcp_packages,
        )
        resources.append(BUNDLED_NODE_MCP_PACKAGES_RESOURCE_PATH)
    python_mcp_packages = (
        source_root / BUNDLED_PYTHON_MCP_PACKAGES_RESOURCE_PATH
    )
    if (
        python_mcp_packages.exists()
        or python_mcp_packages.is_symlink()
    ):
        _validate_bundled_python_mcp_packages(
            source_root,
            python_mcp_packages,
        )
        resources.append(
            BUNDLED_PYTHON_MCP_PACKAGES_RESOURCE_PATH
        )
    return swift_files, sorted(resources)


def _validate_bundled_node_mcp_packages(
    source_root: Path,
    packages_root: Path,
) -> None:
    required = (
        packages_root / "package.json",
        packages_root / "package-lock.json",
        packages_root / "runtime-lock.json",
        packages_root / "node_modules",
    )
    if (
        packages_root.is_symlink()
        or not packages_root.is_dir()
        or any(
            path.is_symlink()
            or not (path.is_dir() if path.name == "node_modules" else path.is_file())
            for path in required
        )
    ):
        raise ValueError(
            "bundled Node MCP package snapshot is incomplete"
        )
    try:
        lock = json.loads(required[2].read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise ValueError(
            "bundled Node MCP package snapshot lock is invalid"
        ) from error
    if (
        lock.get("schemaVersion") != 1
        or lock.get("runtime")
        != {"name": "NodeMobile", "version": "18.20.4"}
        or not isinstance(lock.get("packages"), list)
        or not lock["packages"]
    ):
        raise ValueError(
            "bundled Node MCP package snapshot lock is invalid"
        )
    package_lock_sha256 = hashlib.sha256(
        required[1].read_bytes()
    ).hexdigest()
    if lock.get("packageLockSha256") != package_lock_sha256:
        raise ValueError(
            "bundled Node MCP package-lock digest does not match"
        )
    resource_root = source_root / "Application/Resources"
    for package in lock["packages"]:
        if not isinstance(package, dict):
            raise ValueError(
                "bundled Node MCP package snapshot lock is invalid"
            )
        entrypoint = package.get("entrypoint")
        if (
            not isinstance(package.get("name"), str)
            or not isinstance(package.get("version"), str)
            or not isinstance(entrypoint, str)
            or not entrypoint.startswith("MCPPackages/")
            or entrypoint.startswith("/")
            or ".." in Path(entrypoint).parts
            or not (resource_root / entrypoint).is_file()
        ):
            raise ValueError(
                "bundled Node MCP package entrypoint is invalid"
            )


def _validate_bundled_python_mcp_packages(
    source_root: Path,
    packages_root: Path,
) -> None:
    requirements_lock = packages_root / "requirements.lock"
    uvx_registry = packages_root / "uvx-registry.json"
    runtime_lock = packages_root / "runtime-lock.json"
    device_packages = packages_root / "ios-arm64"
    simulator_packages = (
        packages_root / "ios-arm64-simulator"
    )
    required = (
        requirements_lock,
        uvx_registry,
        runtime_lock,
        device_packages,
        simulator_packages,
    )
    if (
        packages_root.is_symlink()
        or not packages_root.is_dir()
        or any(path.is_symlink() for path in required)
        or not requirements_lock.is_file()
        or not uvx_registry.is_file()
        or not runtime_lock.is_file()
        or not device_packages.is_dir()
        or not simulator_packages.is_dir()
    ):
        raise ValueError(
            "embedded Python package snapshot is incomplete"
        )
    lock = _read_json_object(
        runtime_lock,
        label="embedded Python package snapshot lock",
    )
    runtime = lock.get("runtime")
    packages = lock.get("packages")
    native_extensions = lock.get("nativeExtensions")
    tree = lock.get("tree")
    if (
        lock.get("schemaVersion") != 1
        or runtime
        != {
            "name": "CPython",
            "version": "3.13.14",
            "abi": "cp313",
            "sourceTag": "3.13-b14",
            "sourceCommit":
                "54d8ab6ef4fbac4d60706f311a986aee5236c71b",
        }
        or lock.get("requirementsLockSha256")
        != _sha256_file(requirements_lock)
        or lock.get("uvxRegistrySha256")
        != _sha256_file(uvx_registry)
        or lock.get("snapshotRoots")
        != ["ios-arm64", "ios-arm64-simulator"]
        or not isinstance(tree, dict)
        or not _is_sha256(tree.get("sha256"))
        or not isinstance(tree.get("fileCount"), int)
        or tree["fileCount"] <= 0
        or not isinstance(tree.get("totalBytes"), int)
        or tree["totalBytes"] <= 0
        or not isinstance(packages, list)
        or not packages
        or not isinstance(native_extensions, list)
        or not native_extensions
    ):
        raise ValueError(
            "embedded Python package snapshot lock is invalid"
        )
    for package in packages:
        entrypoint = package.get("entrypoint")
        if (
            not isinstance(package, dict)
            or not isinstance(package.get("name"), str)
            or not package["name"]
            or not isinstance(package.get("version"), str)
            or not package["version"]
            or not isinstance(entrypoint, str)
            or not entrypoint
            or not isinstance(package.get("consoleScript"), str)
            or not package["consoleScript"]
        ):
            raise ValueError(
                "embedded Python package snapshot lock is invalid"
            )
        module, separator, callable_name = entrypoint.partition(":")
        module_pattern = (
            r"[A-Za-z_][A-Za-z0-9_]*"
            r"(?:\.[A-Za-z_][A-Za-z0-9_]*)*"
        )
        if (
            re.fullmatch(module_pattern, module) is None
            or (
                separator
                and re.fullmatch(
                    r"[A-Za-z_][A-Za-z0-9_]*",
                    callable_name,
                )
                is None
            )
        ):
            raise ValueError(
                "embedded Python package snapshot entrypoint is invalid"
            )
        module_path = Path(*module.split("."))
        for slice_root in (device_packages, simulator_packages):
            candidates = (
                slice_root / f"{module_path.as_posix()}.py",
                slice_root / module_path / "__init__.py",
            )
            if not any(
                path.is_file() and not path.is_symlink()
                for path in candidates
            ):
                raise ValueError(
                    "embedded Python package snapshot entrypoint "
                    "is missing"
                )

    for extension in native_extensions:
        slices = (
            extension.get("slices")
            if isinstance(extension, dict)
            else None
        )
        if (
            not isinstance(extension, dict)
            or not isinstance(extension.get("module"), str)
            or not extension["module"]
            or not isinstance(extension.get("package"), str)
            or not extension["package"]
            or not isinstance(slices, dict)
            or set(slices) != {
                "ios-arm64",
                "ios-arm64-simulator",
            }
        ):
            raise ValueError(
                "embedded Python package snapshot native "
                "extension lock is invalid"
            )
        for slice_name, slice_root in (
            ("ios-arm64", device_packages),
            ("ios-arm64-simulator", simulator_packages),
        ):
            descriptor = slices[slice_name]
            relative = (
                descriptor.get("path")
                if isinstance(descriptor, dict)
                else None
            )
            if (
                not isinstance(descriptor, dict)
                or descriptor.get("architectures") != ["arm64"]
                or not isinstance(relative, str)
                or not relative.endswith(".so")
                or Path(relative).is_absolute()
                or ".." in Path(relative).parts
                or not _is_sha256(descriptor.get("sha256"))
                or not isinstance(descriptor.get("size"), int)
                or descriptor["size"] <= 0
            ):
                raise ValueError(
                    "embedded Python package snapshot native "
                    "extension lock is invalid"
                )
            native = slice_root / relative
            if (
                native.is_symlink()
                or not native.is_file()
                or native.stat().st_size != descriptor["size"]
                or _sha256_file(native) != descriptor["sha256"]
            ):
                raise ValueError(
                    "embedded Python package snapshot native "
                    "extension does not match"
                )

    if _python_snapshot_tree_identity(packages_root) != tree:
        raise ValueError(
            "embedded Python package snapshot tree does not match"
        )


def _python_snapshot_tree_identity(
    packages_root: Path,
) -> dict[str, object]:
    files: list[Path] = []
    for slice_name in ("ios-arm64", "ios-arm64-simulator"):
        root = packages_root / slice_name
        for directory, directory_names, file_names in os.walk(
            root,
            followlinks=False,
        ):
            directory_names.sort()
            file_names.sort()
            current = Path(directory)
            for name in directory_names:
                path = current / name
                mode = path.lstat().st_mode
                if stat.S_ISLNK(mode) or not stat.S_ISDIR(mode):
                    raise ValueError(
                        "embedded Python package snapshot tree "
                        "contains an unsafe directory"
                    )
            for name in file_names:
                path = current / name
                mode = path.lstat().st_mode
                if stat.S_ISLNK(mode) or not stat.S_ISREG(mode):
                    raise ValueError(
                        "embedded Python package snapshot tree "
                        "contains an unsafe file"
                    )
                files.append(path)
    files.sort(
        key=lambda path: path.relative_to(packages_root).as_posix()
    )
    if not files:
        raise ValueError(
            "embedded Python package snapshot tree is empty"
        )
    digest = hashlib.sha256()
    total_bytes = 0
    for path in files:
        relative = path.relative_to(packages_root).as_posix()
        size = path.stat().st_size
        digest.update(relative.encode("utf-8"))
        digest.update(b"\0")
        digest.update(str(size).encode("ascii"))
        digest.update(b"\0")
        digest.update(_sha256_file(path).encode("ascii"))
        digest.update(b"\n")
        total_bytes += size
    return {
        "sha256": digest.hexdigest(),
        "fileCount": len(files),
        "totalBytes": total_bytes,
    }


def _is_sha256(value: object) -> bool:
    return (
        isinstance(value, str)
        and re.fullmatch(r"[0-9a-fA-F]{64}", value) is not None
    )


def _is_bundled_opaque_resource(
    path: Path,
    source_root: Path,
) -> bool:
    for relative_root in (
        BUNDLED_SKILLS_RESOURCE_PATH,
        BUNDLED_NODE_RUNTIME_RESOURCE_PATH,
        BUNDLED_NODE_MCP_PACKAGES_RESOURCE_PATH,
        BUNDLED_PYTHON_MCP_PACKAGES_RESOURCE_PATH,
    ):
        try:
            path.relative_to(source_root / relative_root)
            return True
        except ValueError:
            continue
    return False


def _discover_ios_system_frameworks(project_root: Path) -> tuple[str, ...]:
    existing = tuple(
        path
        for path in IOS_SYSTEM_FRAMEWORK_PATHS
        if (project_root / path).is_dir()
    )
    if existing and len(existing) != len(IOS_SYSTEM_FRAMEWORK_PATHS):
        missing = sorted(set(IOS_SYSTEM_FRAMEWORK_PATHS) - set(existing))
        raise ValueError(
            "embedded ios_system framework set is incomplete: "
            + ", ".join(missing)
        )
    return existing


def _discover_embedded_frameworks(
    project_root: Path,
) -> tuple[tuple[str, ...], bool]:
    frameworks = list(
        _discover_ios_system_frameworks(project_root)
    )
    node_framework = project_root / NODE_MOBILE_FRAMEWORK_PATH
    node_lock = project_root / NODE_MOBILE_LOCK_PATH
    if node_framework.exists() or node_lock.exists():
        if not node_framework.is_dir() or not node_lock.is_file():
            raise ValueError(
                "embedded NodeMobile runtime is incomplete"
            )
        lock = _read_json_object(
            node_lock,
            label="NodeMobile runtime lock",
        )
        if lock != NODE_MOBILE_LOCK:
            raise ValueError(
                "embedded NodeMobile runtime lock does not match "
                "the pinned release"
            )
        frameworks.append(NODE_MOBILE_FRAMEWORK_PATH)

    python_framework = project_root / PYTHON_FRAMEWORK_PATH
    python_lock = project_root / PYTHON_RUNTIME_LOCK_PATH
    python_versions = project_root / "Vendor/python_apple/VERSIONS"
    python_utils = python_framework / "build/utils.sh"
    python_bridge_source = project_root / PYTHON_BRIDGE_SOURCE_PATH
    python_bridge_header = project_root / PYTHON_BRIDGE_HEADER_PATH
    python_packages = (
        project_root
        / "CodexPad"
        / BUNDLED_PYTHON_MCP_PACKAGES_RESOURCE_PATH
    )
    runtime_markers = (
        python_framework,
        python_lock,
        python_versions,
        python_utils,
        python_bridge_source,
        python_bridge_header,
    )
    has_runtime_marker = any(
        path.exists() or path.is_symlink()
        for path in runtime_markers
    )
    has_packages_marker = (
        python_packages.exists() or python_packages.is_symlink()
    )
    if not has_runtime_marker and not has_packages_marker:
        return tuple(frameworks), False
    if not has_runtime_marker:
        raise ValueError("embedded CPython runtime is incomplete")
    if not has_packages_marker:
        raise ValueError(
            "embedded Python package snapshot is incomplete"
        )
    required_files = (
        python_lock,
        python_versions,
        python_utils,
        python_bridge_source,
        python_bridge_header,
        python_framework / "Info.plist",
        python_framework
        / "build/iOS-dylib-Info-template.plist",
        python_framework / "lib/python3.13/os.py",
        python_framework
        / "ios-arm64/Python.framework/Python",
        python_framework
        / "ios-arm64/Python.framework/Headers/Python.h",
        python_framework
        / "ios-arm64/Python.framework/Info.plist",
        python_framework
        / "ios-arm64_x86_64-simulator/"
        "Python.framework/Python",
        python_framework
        / "ios-arm64_x86_64-simulator/"
        "Python.framework/Headers/Python.h",
        python_framework
        / "ios-arm64_x86_64-simulator/"
        "Python.framework/Info.plist",
    )
    required_directories = (
        python_framework
        / "ios-arm64/lib-arm64/python3.13/lib-dynload",
        python_framework
        / "ios-arm64_x86_64-simulator/"
        "lib-arm64/python3.13/lib-dynload",
    )
    if (
        not python_framework.is_dir()
        or any(not path.is_file() for path in required_files)
        or any(
            not path.is_dir()
            for path in required_directories
        )
        or any(
            not any(
                item.is_file()
                and not item.is_symlink()
                for item in path.glob("*.so")
            )
            for path in required_directories
        )
    ):
        raise ValueError("embedded CPython runtime is incomplete")
    lock = _read_json_object(
        python_lock,
        label="CPython runtime lock",
    )
    if lock != PYTHON_RUNTIME_LOCK:
        raise ValueError(
            "embedded CPython runtime lock does not match "
            "the pinned release"
        )
    compatibility_patches = lock["compatibilityPatches"]
    expected_utils_sha256 = compatibility_patches[0]["sha256"]
    if _sha256_file(python_utils) != expected_utils_sha256:
        raise ValueError(
            "embedded CPython compatibility helper does not match "
            "the pinned patch"
        )
    frameworks.append(PYTHON_FRAMEWORK_PATH)
    return tuple(frameworks), True


def _discover_swift_files(source_root: Path) -> list[str]:
    if not source_root.is_dir():
        return []
    return sorted(
        path.relative_to(source_root).as_posix()
        for path in source_root.rglob("*.swift")
        if path.is_file()
        and not _is_bundled_opaque_resource(path, source_root)
    )


def _read_json_object(path: Path, *, label: str) -> dict[str, object]:
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise ValueError(f"{label} is unreadable: {path}") from error
    if not isinstance(payload, dict):
        raise ValueError(f"{label} must contain a JSON object: {path}")
    return payload


def _sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def _desktop_surface_resource_tree(root: Path) -> tuple[int, int, str]:
    file_count = 0
    total_bytes = 0
    tree = hashlib.sha256()
    for path in sorted(item for item in root.rglob("*") if item.is_file()):
        relative = path.relative_to(root).as_posix()
        size = path.stat().st_size
        digest = _sha256_file(path)
        tree.update(relative.encode("utf-8"))
        tree.update(b"\0")
        tree.update(str(size).encode("ascii"))
        tree.update(b"\0")
        tree.update(digest.encode("ascii"))
        tree.update(b"\n")
        file_count += 1
        total_bytes += size
    return file_count, total_bytes, tree.hexdigest()


def _resolve_desktop_surface(
    project_root: Path,
    *,
    desktop_version: str,
    desktop_build: str,
) -> tuple[str, tuple[tuple[str, str], ...], str] | None:
    repository_root = project_root.parent
    version_root = repository_root / "versions" / desktop_version
    version_manifest_path = version_root / "manifest.json"
    surface_manifest_path = version_root / "desktop-surface-manifest.json"

    if (
        not version_manifest_path.exists()
        and not surface_manifest_path.exists()
    ):
        if (repository_root / "versions").is_dir():
            raise ValueError(
                f"version manifest is missing for desktop {desktop_version}"
            )
        return None
    if not version_manifest_path.is_file():
        raise ValueError(
            f"version manifest is missing for desktop {desktop_version}"
        )
    if not surface_manifest_path.is_file():
        raise ValueError(
            f"desktop surface manifest is missing for desktop {desktop_version}"
        )

    version_manifest = _read_json_object(
        version_manifest_path,
        label="version manifest",
    )
    manifest_version = version_manifest.get("version")
    manifest_build = str(version_manifest.get("build", ""))
    if manifest_version != desktop_version:
        raise ValueError(
            "version manifest does not match requested desktop version"
        )
    if manifest_build != desktop_build:
        raise ValueError(
            "version manifest does not match requested desktop build"
        )

    surface_manifest = _read_json_object(
        surface_manifest_path,
        label="desktop surface manifest",
    )
    if surface_manifest.get("desktopVersion") != manifest_version:
        raise ValueError(
            "desktop surface manifest does not match version manifest"
        )
    if str(surface_manifest.get("desktopBuild", "")) != manifest_build:
        raise ValueError(
            "desktop surface manifest build does not match version manifest"
        )
    if (
        surface_manifest.get("resourceDirectoryName")
        != DESKTOP_SURFACE_DIRECTORY_NAME
    ):
        raise ValueError(
            "desktop surface resource directory must be CodexDesktopSurface"
        )

    source = (
        repository_root
        / "artifacts"
        / f"full-reverse-{manifest_version}"
        / "app-asar"
        / "webview"
    )
    if not source.is_dir() or not (source / "index.html").is_file():
        raise ValueError(
            f"desktop surface webview is missing for {manifest_version}"
        )
    actual_integrity = _desktop_surface_resource_tree(source)
    expected_integrity = (
        surface_manifest.get("resourceFileCount"),
        surface_manifest.get("resourceTotalBytes"),
        surface_manifest.get("resourceTreeSha256"),
    )
    if actual_integrity != expected_integrity:
        raise ValueError(
            "desktop surface resource integrity mismatch for "
            f"{manifest_version}"
        )
    entries: list[tuple[str, str]] = []
    for entry in sorted(source.iterdir(), key=lambda path: path.name):
        if entry.is_symlink() or not (entry.is_file() or entry.is_dir()):
            raise ValueError(
                f"unsupported desktop surface entry: {entry.name}"
            )
        entries.append((entry.name, _desktop_surface_file_type(entry)))
    if not entries:
        raise ValueError("desktop surface webview is empty")
    relative_source = Path(os.path.relpath(source, project_root)).as_posix()
    relative_manifest = Path(
        os.path.relpath(surface_manifest_path, project_root)
    ).as_posix()
    return relative_source, tuple(entries), relative_manifest


def _build_settings(
    configuration: str,
    desktop_version: str,
    desktop_build: str,
    *,
    has_embedded_python: bool,
) -> str:
    optimization = "-Onone" if configuration == "Debug" else "-O"
    compilation = (
        "SWIFT_COMPILATION_MODE = singlefile;"
        if configuration == "Debug"
        else "SWIFT_COMPILATION_MODE = wholemodule;"
    )
    python_settings = ""
    if has_embedded_python:
        python_settings = """\
				ENABLE_USER_SCRIPT_SANDBOXING = NO;
				"EXCLUDED_ARCHS[sdk=iphonesimulator*]" = x86_64;
				HEADER_SEARCH_PATHS = "$(inherited) ${PROJECT_DIR}/CodexPythonRuntimeBridge/include";
				SWIFT_ACTIVE_COMPILATION_CONDITIONS = "$(inherited) CODEX_EMBEDDED_PYTHON";
				SWIFT_OBJC_BRIDGING_HEADER = CodexPythonRuntimeBridge/include/CodexPythonRuntimeBridge.h;
"""
    return f"""\
				ALWAYS_SEARCH_USER_PATHS = NO;
				ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;
				CODE_SIGN_ENTITLEMENTS = CodexPad/Resources/CodexPad.entitlements;
				CODE_SIGN_STYLE = Automatic;
				DEVELOPMENT_TEAM = XXXXXXXXXX;
				CURRENT_PROJECT_VERSION = {desktop_build};
{python_settings}\
				ENABLE_PREVIEWS = YES;
				GENERATE_INFOPLIST_FILE = NO;
				INFOPLIST_FILE = CodexPad/Resources/Info.plist;
				INFOPLIST_KEY_CFBundleDisplayName = "Codex for ipad";
				INFOPLIST_KEY_LSApplicationCategoryType = "public.app-category.developer-tools";
				INFOPLIST_KEY_UIApplicationSceneManifest_Generation = YES;
				INFOPLIST_KEY_UIApplicationSupportsIndirectInputEvents = YES;
				INFOPLIST_KEY_UILaunchScreen_Generation = YES;
				INFOPLIST_KEY_UISupportedInterfaceOrientations_iPad = "UIInterfaceOrientationPortrait UIInterfaceOrientationPortraitUpsideDown UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight";
				IPHONEOS_DEPLOYMENT_TARGET = 18.0;
				LD_RUNPATH_SEARCH_PATHS = "$(inherited) @executable_path/Frameworks";
				MARKETING_VERSION = {desktop_version};
				OTHER_LDFLAGS = "$(inherited) -lz -liconv -framework Security -framework CoreFoundation";
				PRODUCT_BUNDLE_IDENTIFIER = com.mars.codexpad;
				PRODUCT_NAME = "Codex for ipad";
				SDKROOT = iphoneos;
				SUPPORTED_PLATFORMS = "iphoneos iphonesimulator";
				SUPPORTS_MACCATALYST = NO;
				SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD = NO;
				SWIFT_EMIT_LOC_STRINGS = YES;
				SWIFT_OPTIMIZATION_LEVEL = {optimization};
				{compilation}
				SWIFT_VERSION = 6.0;
					TARGETED_DEVICE_FAMILY = 2;"""


def _ui_test_build_settings(configuration: str) -> str:
    optimization = "-Onone" if configuration == "Debug" else "-O"
    compilation = (
        "SWIFT_COMPILATION_MODE = singlefile;"
        if configuration == "Debug"
        else "SWIFT_COMPILATION_MODE = wholemodule;"
    )
    return f"""\
					CODE_SIGN_STYLE = Automatic;
					DEVELOPMENT_TEAM = XXXXXXXXXX;
					GENERATE_INFOPLIST_FILE = YES;
					IPHONEOS_DEPLOYMENT_TARGET = 18.0;
					PRODUCT_BUNDLE_IDENTIFIER = com.mars.codexpad.ui-tests;
					PRODUCT_NAME = CodexPadUITests;
					SDKROOT = iphoneos;
					SUPPORTED_PLATFORMS = "iphoneos iphonesimulator";
					SUPPORTS_MACCATALYST = NO;
					SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD = NO;
					SWIFT_EMIT_LOC_STRINGS = NO;
					SWIFT_OPTIMIZATION_LEVEL = {optimization};
					{compilation}
					SWIFT_VERSION = 6.0;
					TARGETED_DEVICE_FAMILY = 2;
					TEST_TARGET_NAME = CodexPad;"""


def _project_text(
    swift_files: list[str],
    resources: list[str],
    ios_system_framework_paths: tuple[str, ...],
    has_embedded_python: bool,
    ui_test_swift_files: list[str],
    desktop_version: str,
    desktop_build: str,
    desktop_surface: tuple[
        str,
        tuple[tuple[str, str], ...],
        str,
    ]
    | None,
) -> str:
    has_ui_tests = bool(ui_test_swift_files)
    project_id = _identifier("PBXProject", "CodexPad")
    main_group_id = _identifier("PBXGroup", "main")
    source_group_id = _identifier("PBXGroup", "CodexPad")
    ui_test_group_id = _identifier("PBXGroup", "CodexPadUITests")
    frameworks_group_id = _identifier("PBXGroup", "Frameworks")
    products_group_id = _identifier("PBXGroup", "Products")
    product_name = "Codex for ipad"
    product_bundle = f"{product_name}.app"
    product_id = _identifier("PBXFileReference", product_bundle)
    ui_test_product_name = "CodexPadUITests"
    ui_test_product_bundle = f"{ui_test_product_name}.xctest"
    ui_test_product_id = _identifier(
        "PBXFileReference",
        ui_test_product_bundle,
    )
    # Resolve from the Xcode project directory explicitly.  A framework path
    # stored under a named PBXGroup with sourceTree=<group> is interpreted
    # relative to that group's logical location by newer Xcode versions, which
    # made the generated ../build path appear missing during project loading.
    core_framework_path = "$(PROJECT_DIR)/../build/CodexCore.xcframework"
    core_framework_reference_id = _identifier(
        "PBXFileReference", core_framework_path
    )
    core_framework_build_id = _identifier("PBXBuildFile", core_framework_path)
    target_id = _identifier("PBXNativeTarget", "CodexPad")
    ui_test_target_id = _identifier("PBXNativeTarget", ui_test_product_name)
    ui_test_dependency_proxy_id = _identifier(
        "PBXContainerItemProxy",
        "CodexPadUITests->CodexPad",
    )
    ui_test_target_dependency_id = _identifier(
        "PBXTargetDependency",
        "CodexPadUITests->CodexPad",
    )
    sources_phase_id = _identifier("PBXSourcesBuildPhase", "CodexPad")
    resources_phase_id = _identifier("PBXResourcesBuildPhase", "CodexPad")
    frameworks_phase_id = _identifier("PBXFrameworksBuildPhase", "CodexPad")
    embed_frameworks_phase_id = _identifier(
        "PBXCopyFilesBuildPhase",
        "Embed Frameworks",
    )
    install_python_phase_id = _identifier(
        "PBXShellScriptBuildPhase",
        "Install Embedded Python",
    )
    ui_test_sources_phase_id = _identifier(
        "PBXSourcesBuildPhase",
        ui_test_product_name,
    )
    ui_test_frameworks_phase_id = _identifier(
        "PBXFrameworksBuildPhase",
        ui_test_product_name,
    )
    desktop_surface_phase_id = _identifier(
        "PBXCopyFilesBuildPhase",
        DESKTOP_SURFACE_DIRECTORY_NAME,
    )
    desktop_surface_group_id = _identifier(
        "PBXGroup",
        DESKTOP_SURFACE_DIRECTORY_NAME,
    )
    project_config_list_id = _identifier("XCConfigurationList", "project")
    target_config_list_id = _identifier("XCConfigurationList", "target")
    ui_test_config_list_id = _identifier(
        "XCConfigurationList",
        "target:CodexPadUITests",
    )
    project_debug_id = _identifier("XCBuildConfiguration", "project:Debug")
    project_release_id = _identifier("XCBuildConfiguration", "project:Release")
    target_debug_id = _identifier("XCBuildConfiguration", "target:Debug")
    target_release_id = _identifier("XCBuildConfiguration", "target:Release")
    ui_test_debug_id = _identifier(
        "XCBuildConfiguration",
        "target:CodexPadUITests:Debug",
    )
    ui_test_release_id = _identifier(
        "XCBuildConfiguration",
        "target:CodexPadUITests:Release",
    )

    all_files = [(path, "source") for path in swift_files] + [
        (path, "resource") for path in resources
    ]
    file_references = []
    build_files = []
    source_build_ids = []
    resource_build_ids = []
    group_children = []
    for path, role in all_files:
        reference_id = _identifier("PBXFileReference", path)
        build_id = _identifier("PBXBuildFile", path)
        name = Path(path).name
        is_embedded_python_packages = (
            has_embedded_python
            and role == "resource"
            and path == BUNDLED_PYTHON_MCP_PACKAGES_RESOURCE_PATH
        )
        file_references.append(
            f"\t\t{reference_id} /* {name} */ = "
            f"{{isa = PBXFileReference; lastKnownFileType = {_file_type(path)}; "
            f"path = {_quote(path)}; sourceTree = \"<group>\"; }};"
        )
        if not is_embedded_python_packages:
            build_files.append(
                f"\t\t{build_id} /* {name} in "
                f"{'Sources' if role == 'source' else 'Resources'} */ = "
                f"{{isa = PBXBuildFile; fileRef = {reference_id} /* {name} */; }};"
            )
        group_children.append(f"\t\t\t\t{reference_id} /* {name} */,")
        if role == "source":
            source_build_ids.append(
                f"\t\t\t\t{build_id} /* {name} in Sources */,"
            )
        elif not is_embedded_python_packages:
            resource_build_ids.append(
                f"\t\t\t\t{build_id} /* {name} in Resources */,"
            )

    if has_embedded_python:
        bridge_source_reference_id = _identifier(
            "PBXFileReference",
            PYTHON_BRIDGE_SOURCE_PATH,
        )
        bridge_source_build_id = _identifier(
            "PBXBuildFile",
            PYTHON_BRIDGE_SOURCE_PATH,
        )
        bridge_source_name = Path(PYTHON_BRIDGE_SOURCE_PATH).name
        file_references.append(
            f"\t\t{bridge_source_reference_id} "
            f"/* {bridge_source_name} */ = "
            "{isa = PBXFileReference; "
            "lastKnownFileType = sourcecode.c.objc; "
            f"path = {_quote(PYTHON_BRIDGE_SOURCE_PATH)}; "
            "sourceTree = SOURCE_ROOT; };"
        )
        build_files.append(
            f"\t\t{bridge_source_build_id} "
            f"/* {bridge_source_name} in Sources */ = "
            f"{{isa = PBXBuildFile; fileRef = "
            f"{bridge_source_reference_id} "
            f"/* {bridge_source_name} */; }};"
        )
        source_build_ids.append(
            f"\t\t\t\t{bridge_source_build_id} "
            f"/* {bridge_source_name} in Sources */,"
        )
        group_children.append(
            f"\t\t\t\t{bridge_source_reference_id} "
            f"/* {bridge_source_name} */,"
        )

        bridge_header_reference_id = _identifier(
            "PBXFileReference",
            PYTHON_BRIDGE_HEADER_PATH,
        )
        bridge_header_name = Path(PYTHON_BRIDGE_HEADER_PATH).name
        file_references.append(
            f"\t\t{bridge_header_reference_id} "
            f"/* {bridge_header_name} */ = "
            "{isa = PBXFileReference; "
            "lastKnownFileType = sourcecode.c.h; "
            f"path = {_quote(PYTHON_BRIDGE_HEADER_PATH)}; "
            "sourceTree = SOURCE_ROOT; };"
        )
        group_children.append(
            f"\t\t\t\t{bridge_header_reference_id} "
            f"/* {bridge_header_name} */,"
        )

    ui_test_group_children: list[str] = []
    ui_test_source_build_ids: list[str] = []
    for path in ui_test_swift_files:
        identity = f"Tests/CodexPadUITests/{path}"
        reference_id = _identifier("PBXFileReference", identity)
        build_id = _identifier("PBXBuildFile", identity)
        name = Path(path).name
        file_references.append(
            f"\t\t{reference_id} /* {name} */ = "
            "{isa = PBXFileReference; "
            f"lastKnownFileType = sourcecode.swift; path = {_quote(path)}; "
            'sourceTree = "<group>"; };'
        )
        build_files.append(
            f"\t\t{build_id} /* {name} in Sources */ = "
            f"{{isa = PBXBuildFile; fileRef = {reference_id} "
            f"/* {name} */; }};"
        )
        ui_test_group_children.append(
            f"\t\t\t\t{reference_id} /* {name} */,"
        )
        ui_test_source_build_ids.append(
            f"\t\t\t\t{build_id} /* {name} in Sources */,"
        )

    build_files.append(
        f"\t\t{core_framework_build_id} "
        "/* CodexCore.xcframework in Frameworks */ = "
        f"{{isa = PBXBuildFile; fileRef = {core_framework_reference_id} "
        "/* CodexCore.xcframework */; };"
    )
    file_references.append(
        f"\t\t{core_framework_reference_id} "
        "/* CodexCore.xcframework */ = "
        "{isa = PBXFileReference; lastKnownFileType = wrapper.xcframework; "
        f"path = {_quote(core_framework_path)}; sourceTree = \"SOURCE_ROOT\"; }};"
    )

    framework_group_children = [
        f"\t\t\t\t{core_framework_reference_id} "
        "/* CodexCore.xcframework */,"
    ]
    framework_link_build_ids = [
        f"\t\t\t\t{core_framework_build_id} "
        "/* CodexCore.xcframework in Frameworks */,"
    ]
    embedded_framework_build_ids: list[str] = []
    for framework_path in ios_system_framework_paths:
        framework_name = Path(framework_path).name
        reference_id = _identifier("PBXFileReference", framework_path)
        link_build_id = _identifier(
            "PBXBuildFile",
            f"{framework_path}:link",
        )
        embed_build_id = _identifier(
            "PBXBuildFile",
            f"{framework_path}:embed",
        )
        file_references.append(
            f"\t\t{reference_id} /* {framework_name} */ = "
            "{isa = PBXFileReference; "
            "lastKnownFileType = wrapper.xcframework; "
            f"path = {_quote(framework_path)}; "
            'sourceTree = "<group>"; };'
        )
        build_files.append(
            f"\t\t{link_build_id} /* {framework_name} in Frameworks */ = "
            f"{{isa = PBXBuildFile; fileRef = {reference_id} "
            f"/* {framework_name} */; }};"
        )
        build_files.append(
            f"\t\t{embed_build_id} /* {framework_name} in Embed Frameworks */ "
            f"= {{isa = PBXBuildFile; fileRef = {reference_id} "
            f"/* {framework_name} */; settings = {{ATTRIBUTES = "
            "(CodeSignOnCopy, RemoveHeadersOnCopy, ); }; };"
        )
        framework_group_children.append(
            f"\t\t\t\t{reference_id} /* {framework_name} */,"
        )
        framework_link_build_ids.append(
            f"\t\t\t\t{link_build_id} "
            f"/* {framework_name} in Frameworks */,"
        )
        embedded_framework_build_ids.append(
            f"\t\t\t\t{embed_build_id} "
            f"/* {framework_name} in Embed Frameworks */,"
        )

    embed_frameworks_copy_phase_section = ""
    embed_frameworks_target_phase = ""
    if embedded_framework_build_ids:
        embed_frameworks_copy_phase_section = f"""\
/* Begin PBXCopyFilesBuildPhase section */
		{embed_frameworks_phase_id} /* Embed Frameworks */ = {{
			isa = PBXCopyFilesBuildPhase;
			buildActionMask = 2147483647;
			dstPath = "";
			dstSubfolderSpec = 10;
			files = (
{chr(10).join(embedded_framework_build_ids)}
			);
			name = "Embed Frameworks";
			runOnlyForDeploymentPostprocessing = 0;
		}};
/* End PBXCopyFilesBuildPhase section */

"""
        embed_frameworks_target_phase = (
            f"\n\t\t\t\t{embed_frameworks_phase_id} "
            "/* Embed Frameworks */,"
        )

    install_python_phase_section = ""
    install_python_target_phase = ""
    if has_embedded_python:
        install_python_script = (
            "set -euo pipefail\\n"
            "if [ \\\"${CODE_SIGNING_ALLOWED:-YES}\\\" = "
            "\\\"NO\\\" ] || [ \\\"${EFFECTIVE_PLATFORM_NAME}\\\" "
            "= \\\"-iphonesimulator\\\" ]; then\\n"
            "  export EXPANDED_CODE_SIGN_IDENTITY=\\\"-\\\"\\n"
            "  export EXPANDED_CODE_SIGN_IDENTITY_NAME="
            "\\\"Ad Hoc\\\"\\n"
            "else\\n"
            "  : \\\"${EXPANDED_CODE_SIGN_IDENTITY:"
            "?missing signing identity}\\\"\\n"
            "  : \\\"${EXPANDED_CODE_SIGN_IDENTITY_NAME:"
            "?missing signing identity name}\\\"\\n"
            "fi\\n"
            "source \\\"${PROJECT_DIR}/Vendor/python_apple/"
            "Python.xcframework/build/utils.sh\\\"\\n"
            "case \\\"${EFFECTIVE_PLATFORM_NAME}\\\" in\\n"
            "  -iphoneos) "
            "PYTHON_PACKAGE_SLICE=\\\"ios-arm64\\\" ;;\\n"
            "  -iphonesimulator) "
            "PYTHON_PACKAGE_SLICE="
            "\\\"ios-arm64-simulator\\\" ;;\\n"
            "  *) echo \\\"Unsupported Python platform: "
            "${EFFECTIVE_PLATFORM_NAME}\\\" >&2; exit 1 ;;\\n"
            "esac\\n"
            "SOURCE_PACKAGES_ROOT="
            "\\\"${PROJECT_DIR}/CodexPad/Application/Resources/"
            "PythonPackages\\\"\\n"
            "PACKAGES_ROOT="
            "\\\"${CODESIGNING_FOLDER_PATH}/PythonPackages\\\"\\n"
            "SELECTED_SOURCE_PACKAGES="
            "\\\"${SOURCE_PACKAGES_ROOT}/${PYTHON_PACKAGE_SLICE}\\\"\\n"
            "test -d \\\"${SELECTED_SOURCE_PACKAGES}\\\"\\n"
            "rm -rf \\\"${PACKAGES_ROOT}\\\"\\n"
            "mkdir -p \\\"${PACKAGES_ROOT}\\\"\\n"
            "rsync -a --delete --exclude \\\"ios-arm64/\\\" "
            "--exclude \\\"ios-arm64-simulator/\\\" "
            "\\\"${SOURCE_PACKAGES_ROOT}/\\\" "
            "\\\"${PACKAGES_ROOT}/\\\"\\n"
            "mkdir -p \\\"${PACKAGES_ROOT}/site-packages\\\"\\n"
            "rsync -a --delete "
            "\\\"${SELECTED_SOURCE_PACKAGES}/\\\" "
            "\\\"${PACKAGES_ROOT}/site-packages/\\\"\\n"
            "install_python \\\"Vendor/python_apple/"
            "Python.xcframework\\\" "
            "\\\"PythonPackages/site-packages\\\"\\n"
            "touch \\\"${CODESIGNING_FOLDER_PATH}/"
            ".codex-embedded-python.stamp\\\"\\n"
        )
        install_python_phase_section = f"""\
/* Begin PBXShellScriptBuildPhase section */
		{install_python_phase_id} /* Install Embedded Python */ = {{
			isa = PBXShellScriptBuildPhase;
			buildActionMask = 2147483647;
			files = (
			);
			inputPaths = (
				"$(PROJECT_DIR)/CodexPad/Application/Resources/PythonPackages/runtime-lock.json",
				"$(PROJECT_DIR)/Vendor/python_apple/Python.xcframework/Info.plist",
				"$(PROJECT_DIR)/Vendor/python_apple/Python.xcframework/build/utils.sh",
			);
			name = "Install Embedded Python";
			outputPaths = (
				"$(CODESIGNING_FOLDER_PATH)/.codex-embedded-python.stamp",
			);
			runOnlyForDeploymentPostprocessing = 0;
			shellPath = /bin/bash;
			shellScript = "{install_python_script}";
		}};
/* End PBXShellScriptBuildPhase section */

"""
        install_python_target_phase = (
            f"\n\t\t\t\t{install_python_phase_id} "
            "/* Install Embedded Python */,"
        )

    desktop_surface_main_group_child = ""
    desktop_surface_target_phase = ""
    desktop_surface_copy_phase_section = ""
    desktop_surface_group_section = ""
    if desktop_surface is not None:
        (
            desktop_surface_path,
            desktop_surface_entries,
            desktop_surface_manifest_path,
        ) = desktop_surface
        desktop_surface_group_children: list[str] = []
        desktop_surface_copy_build_files: list[str] = []
        for entry_name, entry_file_type in desktop_surface_entries:
            entry_identity = (
                f"{DESKTOP_SURFACE_DIRECTORY_NAME}:"
                f"{desktop_surface_path}:{entry_name}"
            )
            entry_reference_id = _identifier(
                "PBXFileReference",
                entry_identity,
            )
            entry_build_id = _identifier("PBXBuildFile", entry_identity)
            file_references.append(
                f"\t\t{entry_reference_id} /* {entry_name} */ = "
                "{isa = PBXFileReference; "
                f"lastKnownFileType = {entry_file_type}; "
                f"path = {_quote(entry_name)}; sourceTree = \"<group>\"; }};"
            )
            build_files.append(
                f"\t\t{entry_build_id} /* {entry_name} in "
                f"Embed {DESKTOP_SURFACE_DIRECTORY_NAME} */ = "
                f"{{isa = PBXBuildFile; fileRef = {entry_reference_id} "
                f"/* {entry_name} */; }};"
            )
            desktop_surface_group_children.append(
                f"\t\t\t\t{entry_reference_id} /* {entry_name} */,"
            )
            desktop_surface_copy_build_files.append(
                f"\t\t\t\t{entry_build_id} /* {entry_name} in "
                f"Embed {DESKTOP_SURFACE_DIRECTORY_NAME} */,"
            )
        manifest_name = "desktop-surface-manifest.json"
        manifest_identity = (
            f"{DESKTOP_SURFACE_DIRECTORY_NAME}:"
            f"{desktop_surface_manifest_path}"
        )
        manifest_reference_id = _identifier(
            "PBXFileReference",
            manifest_identity,
        )
        manifest_build_id = _identifier("PBXBuildFile", manifest_identity)
        file_references.append(
            f"\t\t{manifest_reference_id} /* {manifest_name} */ = "
            "{isa = PBXFileReference; lastKnownFileType = text.json; "
            f"name = {manifest_name}; "
            f"path = {_quote(desktop_surface_manifest_path)}; "
            "sourceTree = SOURCE_ROOT; };"
        )
        build_files.append(
            f"\t\t{manifest_build_id} /* {manifest_name} in "
            f"Embed {DESKTOP_SURFACE_DIRECTORY_NAME} */ = "
            f"{{isa = PBXBuildFile; fileRef = {manifest_reference_id} "
            f"/* {manifest_name} */; }};"
        )
        desktop_surface_group_children.append(
            f"\t\t\t\t{manifest_reference_id} /* {manifest_name} */,"
        )
        desktop_surface_copy_build_files.append(
            f"\t\t\t\t{manifest_build_id} /* {manifest_name} in "
            f"Embed {DESKTOP_SURFACE_DIRECTORY_NAME} */,"
        )
        desktop_surface_main_group_child = (
            f"\n\t\t\t\t{desktop_surface_group_id} "
            f"/* {DESKTOP_SURFACE_DIRECTORY_NAME} */,"
        )
        desktop_surface_target_phase = (
            f"\n\t\t\t\t{desktop_surface_phase_id} "
            f"/* Embed {DESKTOP_SURFACE_DIRECTORY_NAME} */,"
        )
        desktop_surface_copy_phase_section = f"""\
/* Begin PBXCopyFilesBuildPhase section */
		{desktop_surface_phase_id} /* Embed {DESKTOP_SURFACE_DIRECTORY_NAME} */ = {{
			isa = PBXCopyFilesBuildPhase;
			buildActionMask = 2147483647;
			dstPath = {DESKTOP_SURFACE_DIRECTORY_NAME};
			dstSubfolderSpec = 7;
			files = (
{chr(10).join(desktop_surface_copy_build_files)}
			);
			name = "Embed {DESKTOP_SURFACE_DIRECTORY_NAME}";
			runOnlyForDeploymentPostprocessing = 0;
		}};
/* End PBXCopyFilesBuildPhase section */

"""
        desktop_surface_group_section = f"""\
		{desktop_surface_group_id} /* {DESKTOP_SURFACE_DIRECTORY_NAME} */ = {{
			isa = PBXGroup;
			children = (
{chr(10).join(desktop_surface_group_children)}
			);
			name = {DESKTOP_SURFACE_DIRECTORY_NAME};
			path = {_quote(desktop_surface_path)};
			sourceTree = SOURCE_ROOT;
		}};
"""

    ui_test_product_file_reference = ""
    ui_test_container_proxy_section = ""
    ui_test_main_group_child = ""
    ui_test_group_section = ""
    ui_test_product_group_child = ""
    ui_test_frameworks_phase_section = ""
    ui_test_native_target_section = ""
    ui_test_target_attribute = ""
    ui_test_project_target = ""
    ui_test_sources_phase_section = ""
    ui_test_target_dependency_section = ""
    ui_test_build_configuration_section = ""
    ui_test_configuration_list_section = ""
    if has_ui_tests:
        ui_test_product_file_reference = (
            f"\n\t\t{ui_test_product_id} /* {ui_test_product_bundle} */ = "
            "{isa = PBXFileReference; explicitFileType = wrapper.cfbundle; "
            "includeInIndex = 0; "
            f"path = {ui_test_product_bundle}; "
            "sourceTree = BUILT_PRODUCTS_DIR; };"
        )
        ui_test_container_proxy_section = f"""\
/* Begin PBXContainerItemProxy section */
		{ui_test_dependency_proxy_id} /* PBXContainerItemProxy */ = {{
			isa = PBXContainerItemProxy;
			containerPortal = {project_id} /* Project object */;
			proxyType = 1;
			remoteGlobalIDString = {target_id};
			remoteInfo = CodexPad;
		}};
/* End PBXContainerItemProxy section */

"""
        ui_test_main_group_child = (
            f"\t\t\t\t{ui_test_group_id} /* {ui_test_product_name} */,\n"
        )
        ui_test_group_section = f"""\
		{ui_test_group_id} /* {ui_test_product_name} */ = {{
			isa = PBXGroup;
			children = (
{chr(10).join(ui_test_group_children)}
			);
			path = Tests/CodexPadUITests;
			sourceTree = "<group>";
		}};
"""
        ui_test_product_group_child = (
            f"\t\t\t\t{ui_test_product_id} "
            f"/* {ui_test_product_bundle} */,\n"
        )
        ui_test_frameworks_phase_section = f"""\
		{ui_test_frameworks_phase_id} /* Frameworks */ = {{
			isa = PBXFrameworksBuildPhase;
			buildActionMask = 2147483647;
			files = (
			);
			runOnlyForDeploymentPostprocessing = 0;
		}};
"""
        ui_test_native_target_section = f"""\
		{ui_test_target_id} /* {ui_test_product_name} */ = {{
			isa = PBXNativeTarget;
			buildConfigurationList = {ui_test_config_list_id} /* Build configuration list for PBXNativeTarget "{ui_test_product_name}" */;
			buildPhases = (
				{ui_test_sources_phase_id} /* Sources */,
				{ui_test_frameworks_phase_id} /* Frameworks */,
			);
			buildRules = (
			);
			dependencies = (
				{ui_test_target_dependency_id} /* PBXTargetDependency */,
			);
			name = {ui_test_product_name};
			productName = {ui_test_product_name};
			productReference = {ui_test_product_id} /* {ui_test_product_bundle} */;
			productType = "com.apple.product-type.bundle.ui-testing";
		}};
"""
        ui_test_target_attribute = f"""\
					{ui_test_target_id} = {{
						CreatedOnToolsVersion = 27.0;
						ProvisioningStyle = Automatic;
					}};
"""
        ui_test_project_target = (
            f"\t\t\t\t{ui_test_target_id} /* {ui_test_product_name} */,\n"
        )
        ui_test_sources_phase_section = f"""\
		{ui_test_sources_phase_id} /* Sources */ = {{
			isa = PBXSourcesBuildPhase;
			buildActionMask = 2147483647;
			files = (
{chr(10).join(ui_test_source_build_ids)}
			);
			runOnlyForDeploymentPostprocessing = 0;
		}};
"""
        ui_test_target_dependency_section = f"""\
/* Begin PBXTargetDependency section */
		{ui_test_target_dependency_id} /* PBXTargetDependency */ = {{
			isa = PBXTargetDependency;
			target = {target_id} /* CodexPad */;
			targetProxy = {ui_test_dependency_proxy_id} /* PBXContainerItemProxy */;
		}};
/* End PBXTargetDependency section */

"""
        ui_test_build_configuration_section = f"""\
		{ui_test_debug_id} /* Debug */ = {{
			isa = XCBuildConfiguration;
			buildSettings = {{
{_ui_test_build_settings("Debug")}
			}};
			name = Debug;
		}};
		{ui_test_release_id} /* Release */ = {{
			isa = XCBuildConfiguration;
			buildSettings = {{
{_ui_test_build_settings("Release")}
			}};
			name = Release;
		}};
"""
        ui_test_configuration_list_section = f"""\
		{ui_test_config_list_id} /* Build configuration list for PBXNativeTarget "{ui_test_product_name}" */ = {{
			isa = XCConfigurationList;
			buildConfigurations = (
				{ui_test_debug_id} /* Debug */,
				{ui_test_release_id} /* Release */,
			);
			defaultConfigurationIsVisible = 0;
			defaultConfigurationName = Release;
		}};
"""

    return f"""\
// !$*UTF8*$!
{{
	archiveVersion = 1;
	classes = {{
	}};
	objectVersion = 77;
	objects = {{

/* Begin PBXBuildFile section */
{chr(10).join(build_files)}
/* End PBXBuildFile section */

{ui_test_container_proxy_section}\
/* Begin PBXFileReference section */
{chr(10).join(file_references)}
		{product_id} /* {product_bundle} */ = {{isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = {_quote(product_bundle)}; sourceTree = BUILT_PRODUCTS_DIR; }};{ui_test_product_file_reference}
/* End PBXFileReference section */

{embed_frameworks_copy_phase_section}\
{desktop_surface_copy_phase_section}\
{install_python_phase_section}\
/* Begin PBXFrameworksBuildPhase section */
		{frameworks_phase_id} /* Frameworks */ = {{
			isa = PBXFrameworksBuildPhase;
			buildActionMask = 2147483647;
			files = (
{chr(10).join(framework_link_build_ids)}
			);
			runOnlyForDeploymentPostprocessing = 0;
		}};
{ui_test_frameworks_phase_section}\
/* End PBXFrameworksBuildPhase section */

/* Begin PBXGroup section */
		{main_group_id} = {{
			isa = PBXGroup;
			children = (
				{source_group_id} /* CodexPad */,
{ui_test_main_group_child}\
				{frameworks_group_id} /* Frameworks */,{desktop_surface_main_group_child}
				{products_group_id} /* Products */,
			);
			sourceTree = "<group>";
		}};
		{source_group_id} /* CodexPad */ = {{
			isa = PBXGroup;
			children = (
{chr(10).join(group_children)}
			);
			path = CodexPad;
			sourceTree = "<group>";
		}};
{ui_test_group_section}\
{desktop_surface_group_section}\
		{frameworks_group_id} /* Frameworks */ = {{
			isa = PBXGroup;
			children = (
{chr(10).join(framework_group_children)}
			);
			name = Frameworks;
			sourceTree = "<group>";
		}};
		{products_group_id} /* Products */ = {{
			isa = PBXGroup;
			children = (
				{product_id} /* {product_bundle} */,
{ui_test_product_group_child}\
			);
			name = Products;
			sourceTree = "<group>";
		}};
/* End PBXGroup section */

/* Begin PBXNativeTarget section */
		{target_id} /* CodexPad */ = {{
			isa = PBXNativeTarget;
			buildConfigurationList = {target_config_list_id} /* Build configuration list for PBXNativeTarget "CodexPad" */;
			buildPhases = (
				{sources_phase_id} /* Sources */,
				{frameworks_phase_id} /* Frameworks */,
				{resources_phase_id} /* Resources */,{install_python_target_phase}{embed_frameworks_target_phase}{desktop_surface_target_phase}
			);
			buildRules = (
			);
			dependencies = (
			);
			name = CodexPad;
			productName = {_quote(product_name)};
			productReference = {product_id} /* {product_bundle} */;
			productType = "com.apple.product-type.application";
		}};
{ui_test_native_target_section}\
/* End PBXNativeTarget section */

/* Begin PBXProject section */
		{project_id} /* Project object */ = {{
			isa = PBXProject;
			attributes = {{
				BuildIndependentTargetsInParallel = 1;
				LastSwiftUpdateCheck = 2700;
				LastUpgradeCheck = 2700;
				TargetAttributes = {{
					{target_id} = {{
						CreatedOnToolsVersion = 27.0;
						ProvisioningStyle = Automatic;
					}};
{ui_test_target_attribute}\
				}};
			}};
			buildConfigurationList = {project_config_list_id} /* Build configuration list for PBXProject "CodexPad" */;
			compatibilityVersion = "Xcode 16.0";
			developmentRegion = en;
			hasScannedForEncodings = 0;
			knownRegions = (
				en,
				Base,
			);
			mainGroup = {main_group_id};
			productRefGroup = {products_group_id} /* Products */;
			projectDirPath = "";
			projectRoot = "";
			targets = (
				{target_id} /* CodexPad */,
{ui_test_project_target}\
			);
		}};
/* End PBXProject section */

/* Begin PBXResourcesBuildPhase section */
		{resources_phase_id} /* Resources */ = {{
			isa = PBXResourcesBuildPhase;
			buildActionMask = 2147483647;
			files = (
{chr(10).join(resource_build_ids)}
			);
			runOnlyForDeploymentPostprocessing = 0;
		}};
/* End PBXResourcesBuildPhase section */

/* Begin PBXSourcesBuildPhase section */
		{sources_phase_id} /* Sources */ = {{
			isa = PBXSourcesBuildPhase;
			buildActionMask = 2147483647;
			files = (
{chr(10).join(source_build_ids)}
			);
			runOnlyForDeploymentPostprocessing = 0;
		}};
{ui_test_sources_phase_section}\
/* End PBXSourcesBuildPhase section */

{ui_test_target_dependency_section}\
/* Begin XCBuildConfiguration section */
		{project_debug_id} /* Debug */ = {{
			isa = XCBuildConfiguration;
			buildSettings = {{
				CLANG_ENABLE_MODULES = YES;
				ENABLE_TESTABILITY = YES;
				SDKROOT = iphoneos;
				SWIFT_ACTIVE_COMPILATION_CONDITIONS = DEBUG;
			}};
			name = Debug;
		}};
		{project_release_id} /* Release */ = {{
			isa = XCBuildConfiguration;
			buildSettings = {{
				CLANG_ENABLE_MODULES = YES;
				SDKROOT = iphoneos;
				SWIFT_COMPILATION_MODE = wholemodule;
			}};
			name = Release;
		}};
		{target_debug_id} /* Debug */ = {{
			isa = XCBuildConfiguration;
			buildSettings = {{
{_build_settings("Debug", desktop_version, desktop_build, has_embedded_python=has_embedded_python)}
			}};
			name = Debug;
		}};
		{target_release_id} /* Release */ = {{
			isa = XCBuildConfiguration;
			buildSettings = {{
{_build_settings("Release", desktop_version, desktop_build, has_embedded_python=has_embedded_python)}
			}};
			name = Release;
		}};
{ui_test_build_configuration_section}\
/* End XCBuildConfiguration section */

/* Begin XCConfigurationList section */
		{project_config_list_id} /* Build configuration list for PBXProject "CodexPad" */ = {{
			isa = XCConfigurationList;
			buildConfigurations = (
				{project_debug_id} /* Debug */,
				{project_release_id} /* Release */,
			);
			defaultConfigurationIsVisible = 0;
			defaultConfigurationName = Release;
		}};
		{target_config_list_id} /* Build configuration list for PBXNativeTarget "CodexPad" */ = {{
			isa = XCConfigurationList;
			buildConfigurations = (
				{target_debug_id} /* Debug */,
				{target_release_id} /* Release */,
			);
			defaultConfigurationIsVisible = 0;
			defaultConfigurationName = Release;
		}};
{ui_test_configuration_list_section}\
/* End XCConfigurationList section */
	}};
	rootObject = {project_id} /* Project object */;
}}
"""


def _scheme_text() -> str:
    app_target_id = _identifier("PBXNativeTarget", "CodexPad")
    ui_test_target_id = _identifier("PBXNativeTarget", "CodexPadUITests")
    container = "container:CodexPad.xcodeproj"
    return f"""\
<?xml version="1.0" encoding="UTF-8"?>
<Scheme
   LastUpgradeVersion = "2700"
   version = "1.7">
   <BuildAction
      parallelizeBuildables = "YES"
      buildImplicitDependencies = "YES">
      <BuildActionEntries>
         <BuildActionEntry
            buildForTesting = "YES"
            buildForRunning = "YES"
            buildForProfiling = "YES"
            buildForArchiving = "YES"
            buildForAnalyzing = "YES">
            <BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "{app_target_id}"
               BuildableName = "Codex for ipad.app"
               BlueprintName = "CodexPad"
               ReferencedContainer = "{container}">
            </BuildableReference>
         </BuildActionEntry>
         <BuildActionEntry
            buildForTesting = "YES"
            buildForRunning = "NO"
            buildForProfiling = "NO"
            buildForArchiving = "NO"
            buildForAnalyzing = "NO">
            <BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "{ui_test_target_id}"
               BuildableName = "CodexPadUITests.xctest"
               BlueprintName = "CodexPadUITests"
               ReferencedContainer = "{container}">
            </BuildableReference>
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <TestAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      shouldUseLaunchSchemeArgsEnv = "YES">
      <Testables>
         <TestableReference
            skipped = "NO"
            parallelizable = "NO">
            <BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "{ui_test_target_id}"
               BuildableName = "CodexPadUITests.xctest"
               BlueprintName = "CodexPadUITests"
               ReferencedContainer = "{container}">
            </BuildableReference>
         </TestableReference>
      </Testables>
      <MacroExpansion>
         <BuildableReference
            BuildableIdentifier = "primary"
            BlueprintIdentifier = "{app_target_id}"
            BuildableName = "Codex for ipad.app"
            BlueprintName = "CodexPad"
            ReferencedContainer = "{container}">
         </BuildableReference>
      </MacroExpansion>
   </TestAction>
   <LaunchAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      launchStyle = "0"
      useCustomWorkingDirectory = "NO"
      ignoresPersistentStateOnLaunch = "NO"
      debugDocumentVersioning = "YES"
      debugServiceExtension = "internal"
      allowLocationSimulation = "YES">
      <BuildableProductRunnable
         runnableDebuggingMode = "0">
         <BuildableReference
            BuildableIdentifier = "primary"
            BlueprintIdentifier = "{app_target_id}"
            BuildableName = "Codex for ipad.app"
            BlueprintName = "CodexPad"
            ReferencedContainer = "{container}">
         </BuildableReference>
      </BuildableProductRunnable>
   </LaunchAction>
   <ProfileAction
      buildConfiguration = "Release"
      shouldUseLaunchSchemeArgsEnv = "YES"
      savedToolIdentifier = ""
      useCustomWorkingDirectory = "NO"
      debugDocumentVersioning = "YES">
      <BuildableProductRunnable
         runnableDebuggingMode = "0">
         <BuildableReference
            BuildableIdentifier = "primary"
            BlueprintIdentifier = "{app_target_id}"
            BuildableName = "Codex for ipad.app"
            BlueprintName = "CodexPad"
            ReferencedContainer = "{container}">
         </BuildableReference>
      </BuildableProductRunnable>
   </ProfileAction>
   <AnalyzeAction
      buildConfiguration = "Debug">
   </AnalyzeAction>
   <ArchiveAction
      buildConfiguration = "Release"
      revealArchiveInOrganizer = "YES">
   </ArchiveAction>
</Scheme>
"""


def _write_text_atomically(output: Path, text: str) -> None:
    output.parent.mkdir(parents=True, exist_ok=True)
    temporary = output.with_suffix(f"{output.suffix}.tmp")
    temporary.write_text(text, encoding="utf-8")
    temporary.replace(output)


def generate_project(
    project_root: Path,
    *,
    desktop_version: str = "0.0.0",
    desktop_build: str = "1",
) -> Path:
    if not re.fullmatch(r"[0-9]+(?:\.[0-9]+)*", desktop_version):
        raise ValueError("desktop version must contain numeric components")
    if not re.fullmatch(r"[1-9][0-9]*", desktop_build):
        raise ValueError("desktop build must be a positive integer")
    root = project_root.resolve()
    source_root = root / "CodexPad"
    entry = source_root / "App/CodexPadApp.swift"
    if not entry.is_file():
        raise ValueError("CodexPadApp.swift is missing")
    swift_files, resources = _discover_files(source_root)
    embedded_framework_paths, has_embedded_python = (
        _discover_embedded_frameworks(
        project_root
        )
    )
    if swift_files.count("App/CodexPadApp.swift") != 1:
        raise ValueError("exactly one CodexPadApp.swift is required")
    ui_test_swift_files = _discover_swift_files(
        root / "Tests/CodexPadUITests"
    )
    desktop_surface = _resolve_desktop_surface(
        root,
        desktop_version=desktop_version,
        desktop_build=desktop_build,
    )
    output = root / "CodexPad.xcodeproj/project.pbxproj"
    _write_text_atomically(
        output,
        _project_text(
            swift_files,
            resources,
            embedded_framework_paths,
            has_embedded_python,
            ui_test_swift_files,
            desktop_version,
            desktop_build,
            desktop_surface,
        ),
    )
    # Keep the explicit Info.plist identity synchronized with the generated
    # Xcode build settings.  The project intentionally uses a checked-in
    # plist (GENERATE_INFOPLIST_FILE=NO), so MARKETING_VERSION and
    # CURRENT_PROJECT_VERSION alone do not update the built bundle metadata.
    info_plist = source_root / "Resources/Info.plist"
    if info_plist.is_file():
        info_text = info_plist.read_text(encoding="utf-8")
        info_text, version_count = re.subn(
            r"(<key>CFBundleShortVersionString</key>\s*<string>)[^<]+(</string>)",
            rf"\g<1>{desktop_version}\g<2>",
            info_text,
            count=1,
        )
        info_text, build_count = re.subn(
            r"(<key>CFBundleVersion</key>\s*<string>)[^<]+(</string>)",
            rf"\g<1>{desktop_build}\g<2>",
            info_text,
            count=1,
        )
        if version_count != 1 or build_count != 1:
            raise ValueError("Info.plist release identity fields are malformed")
        _write_text_atomically(info_plist, info_text)
    scheme_output = (
        root
        / "CodexPad.xcodeproj"
        / "xcshareddata/xcschemes/CodexPad.xcscheme"
    )
    if ui_test_swift_files:
        _write_text_atomically(
            scheme_output,
            _scheme_text(),
        )
    else:
        scheme_output.unlink(missing_ok=True)
    return output


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--project-root", required=True, type=Path)
    parser.add_argument("--desktop-version", required=True)
    parser.add_argument("--desktop-build", required=True)
    args = parser.parse_args()
    print(
        generate_project(
            args.project_root,
            desktop_version=args.desktop_version,
            desktop_build=args.desktop_build,
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
