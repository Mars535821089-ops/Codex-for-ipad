#!/usr/bin/env python3
"""Shared immutable identity for one exact official desktop release."""

from __future__ import annotations

import re
from typing import Any


SHA256_PATTERN = re.compile(r"^[0-9a-f]{64}$")
VERSION_PATTERN = re.compile(r"^[0-9]+(?:\.[0-9]+)+$")
BUILD_PATTERN = re.compile(r"^[1-9][0-9]*$")


class ReleaseIdentity:
    """Immutable version, build, and official package hash triple."""

    __slots__ = ("version", "build", "dmg_sha256")

    version: str
    build: str
    dmg_sha256: str

    def __init__(
        self,
        version: str,
        build: str,
        dmg_sha256: str,
    ) -> None:
        if (
            not isinstance(version, str)
            or VERSION_PATTERN.fullmatch(version) is None
            or not isinstance(build, str)
            or BUILD_PATTERN.fullmatch(build) is None
            or not isinstance(dmg_sha256, str)
            or SHA256_PATTERN.fullmatch(dmg_sha256) is None
        ):
            raise ValueError("release identity is malformed")
        object.__setattr__(self, "version", version)
        object.__setattr__(self, "build", build)
        object.__setattr__(self, "dmg_sha256", dmg_sha256)

    def __setattr__(self, name: str, value: object) -> None:
        raise AttributeError("ReleaseIdentity is immutable")

    def __delattr__(self, name: str) -> None:
        raise AttributeError("ReleaseIdentity is immutable")

    def __eq__(self, other: object) -> bool:
        if not isinstance(other, ReleaseIdentity):
            return NotImplemented
        return (
            self.version,
            self.build,
            self.dmg_sha256,
        ) == (
            other.version,
            other.build,
            other.dmg_sha256,
        )

    def __hash__(self) -> int:
        return hash((self.version, self.build, self.dmg_sha256))

    @property
    def release_root(self) -> str:
        return (
            f"artifacts/releases/{self.version}/{self.build}/"
            f"{self.dmg_sha256}"
        )


def require_matching_release_identity(
    record: dict[str, Any],
    identity: ReleaseIdentity,
    *,
    label: str,
    version_key: str = "version",
    build_key: str = "build",
    sha_key: str = "dmgSha256",
) -> None:
    """Require a child record to name the same exact release triple."""
    if not isinstance(record, dict):
        raise ValueError(f"{label} is malformed")
    try:
        actual = ReleaseIdentity(
            version=record.get(version_key),
            build=record.get(build_key),
            dmg_sha256=record.get(sha_key),
        )
    except ValueError as error:
        raise ValueError(f"{label} release identity is malformed") from error
    if actual != identity:
        raise ValueError(f"{label} does not match release identity")
