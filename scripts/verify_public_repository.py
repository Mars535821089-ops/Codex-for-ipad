#!/usr/bin/env python3
"""Fail when a public snapshot contains local identity or private artifacts."""

from __future__ import annotations

import re
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BLOCKED_PATH_PARTS = {
    ".downloads",
    ".update-state",
    "DerivedData",
    "xcuserdata",
    "project.xcworkspace",
}
BLOCKED_SUFFIXES = {
    ".app",
    ".asar",
    ".dmg",
    ".ipa",
    ".mobileprovision",
    ".p12",
    ".xcarchive",
    ".xcresult",
}
BLOCKED_BASENAMES = {"auth.json", "settings.json"}
VENDORED_CONTENT_PARTS = {"node_modules", "vendor"}
BLOCKED_CONTENT = {
    "personal home path": re.compile(rb"/Users/[A-Za-z0-9._-]+/"),
    "project signing team": re.compile(
        rb"DEVELOPMENT_TEAM\\s*=\\s*[A-Z0-9]{10}"
    ),
    "physical device identifier": re.compile(
        rb"(?<![0-9A-F])[0-9A-F]{8}-[0-9A-F]{16}(?![0-9A-F])"
    ),
    "personal bundle identifier": re.compile(
        rb"com\\.[A-Za-z0-9._-]+\\.codexpad", re.I
    ),
    "GitHub token": re.compile(rb"gh[opsu]_[A-Za-z0-9_]{20,}"),
    "OpenAI secret key": re.compile(rb"sk-(?:proj-)?[A-Za-z0-9_-]{32,}"),
    "private key": re.compile(
        rb"BEGIN (?:RSA |EC |OPENSSH )?PRIVATE " + rb"KEY"
    ),
}

SYNTHETIC_CONTENT = {
    "personal home path": {
        b"/Users/you/",
        b"/Users/example/",
        b"/Users/runner/",
    },
    "physical device identifier": {
        b"00000000-0000000000000000",
        b"00008101-000E11111111111E",
    },
}


def tracked_files() -> list[Path]:
    output = subprocess.check_output(
        ["git", "ls-files", "-z"], cwd=ROOT
    )
    return [ROOT / raw.decode() for raw in output.split(b"\0") if raw]


def main() -> int:
    violations: list[str] = []
    for path in tracked_files():
        relative = path.relative_to(ROOT)
        if (
            any(part in BLOCKED_PATH_PARTS for part in relative.parts)
            or path.suffix.lower() in BLOCKED_SUFFIXES
            or path.name in BLOCKED_BASENAMES
        ):
            violations.append(f"blocked path: {relative}")
            continue
        try:
            content = path.read_bytes()
        except OSError as error:
            violations.append(f"unreadable tracked file: {relative}: {error}")
            continue
        # Third-party sources are reproducible from lockfiles and may contain
        # standard cryptographic test strings. Their paths are still checked.
        if any(part in VENDORED_CONTENT_PARTS for part in relative.parts):
            continue
        for label, pattern in BLOCKED_CONTENT.items():
            matches = list(pattern.finditer(content))
            allowed = SYNTHETIC_CONTENT.get(label, set())
            if any(match.group(0) not in allowed for match in matches):
                violations.append(f"{label}: {relative}")
    if violations:
        print("Public repository verification failed:")
        for violation in violations:
            print(f"- {violation}")
        return 1
    print(f"Public repository verification passed: {len(tracked_files())} tracked files")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
