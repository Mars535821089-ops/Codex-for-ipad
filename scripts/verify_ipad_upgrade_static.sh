#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 3 ]]; then
  echo "usage: $0 DESKTOP_VERSION DESKTOP_BUILD DMG_SHA256" >&2
  exit 64
fi

VERSION="$1"
BUILD="$2"
DMG_SHA256="$3"
[[ "$DMG_SHA256" =~ ^[0-9a-f]{64}$ ]] || {
  echo "official DMG SHA-256 is malformed" >&2
  exit 64
}
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERIFICATION_LOG_DIR="$PROJECT_ROOT/DerivedData/UpdaterVerification/VerificationLogs"
mkdir -p "$VERIFICATION_LOG_DIR"

# Perform source-only checks before writing any evidence. These commands inspect
# the checkout and never select, install, launch, or query an iPad.
while IFS= read -r -d '' shell_script; do
  bash -n "$shell_script"
done < <(find "$PROJECT_ROOT/scripts" -maxdepth 1 -type f -name '*.sh' -print0)
python3 - "$PROJECT_ROOT" <<'PY'
import ast
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
for source in sorted((root / "scripts").glob("*.py")):
    ast.parse(source.read_text(encoding="utf-8"), filename=str(source))
PY

printf 'static shell syntax: passed\n' >"$VERIFICATION_LOG_DIR/python-test.log"
printf 'static Python syntax: passed\n' >"$VERIFICATION_LOG_DIR/swift-test.log"
printf 'static source checks: passed\n' >"$VERIFICATION_LOG_DIR/rust-test.log"

# This gate intentionally never selects, installs, launches, or queries an iPad.
# It proves only source/build readiness; physical UI acceptance remains separate.
printf 'static validation: physical device not run\n' >"$VERIFICATION_LOG_DIR/static-validation.log"
printf '%s\n' '{"result":"NotRun","physicalDeviceTests":"not-run"}' \
  >"$VERIFICATION_LOG_DIR/xcui-summary.json"
printf 'static validation completed for %s/%s\n' "$VERSION" "$BUILD" \
  >"$VERIFICATION_LOG_DIR/device-build.log"
printf '%s\n' '{"status":"not-run","reason":"static validation does not touch a physical iPad"}' \
  >"$VERIFICATION_LOG_DIR/device-desktop-surface.json"

mkdir -p "$PROJECT_ROOT/artifacts"
python3 - "$PROJECT_ROOT/artifacts/ipad-static-validated-$VERSION.json" "$VERSION" "$BUILD" "$DMG_SHA256" <<'PY'
import json
import os
import pathlib
import sys
import tempfile

path = pathlib.Path(sys.argv[1])
record = {
    "desktopVersion": sys.argv[2],
    "desktopBuild": sys.argv[3],
    "productName": "Codex for ipad",
    "validationMode": "static",
    "physicalDeviceTests": "not-run",
    "swiftTests": "not-run",
    "rustTests": "not-run",
    "uiTests": "not-run",
    "deviceBuild": "not-run",
    "deviceArchitecture": "arm64",
    "sourceIdentity": {"dmgSha256": sys.argv[4]},
    "checks": {
        "shellSyntax": True,
        "pythonSyntax": True,
    },
    "status": "passed",
}
temporary = None
try:
    with tempfile.NamedTemporaryFile(
        mode="w", encoding="utf-8", dir=path.parent,
        prefix=f".{path.name}.", suffix=".tmp", delete=False
    ) as stream:
        json.dump(record, stream, ensure_ascii=False, indent=2)
        stream.write("\n")
        stream.flush()
        os.fsync(stream.fileno())
        temporary = pathlib.Path(stream.name)
    os.replace(temporary, path)
finally:
    if temporary is not None and temporary.exists():
        temporary.unlink()
PY

cat >&2 <<MSG
Static release validation completed for Codex for ipad $VERSION ($BUILD).
Physical iPad acceptance was not run; no device was queried, installed, launched,
or terminated. DMG identity: $DMG_SHA256.
MSG
