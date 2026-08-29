#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 'CONNECTED IPAD NAME'" >&2
  exit 64
fi

# Installing an app must not add an explicit app-process restart. Launch is an
# opt-in action for the final device-acceptance pass only, and an already
# running Codex for ipad process is always left untouched.
LAUNCH_AFTER_INSTALL="${CODEXPAD_LAUNCH_AFTER_INSTALL:-false}"
case "$LAUNCH_AFTER_INSTALL" in
  true|false) ;;
  *)
    echo "CODEXPAD_LAUNCH_AFTER_INSTALL must be true or false" >&2
    exit 64
    ;;
esac

# Replacing an installed app while it is in the foreground can tear down the
# app process and reset the CoreDevice tunnel.  Never do that implicitly: the
# physical-acceptance operator must explicitly opt in after closing the app.
ALLOW_RUNNING_APP_REPLACEMENT="${CODEXPAD_ALLOW_RUNNING_APP_REPLACEMENT:-false}"
case "$ALLOW_RUNNING_APP_REPLACEMENT" in
  true|false) ;;
  *)
    echo "CODEXPAD_ALLOW_RUNNING_APP_REPLACEMENT must be true or false" >&2
    exit 64
    ;;
esac

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEVICE_NAME="$1"
BUNDLE_ID="com.mars.codexpad"
ARTIFACTS="$PROJECT_ROOT/artifacts"
SCREENSHOT_VALIDATOR="$PROJECT_ROOT/scripts/verify_device_screenshot.swift"
LATEST_PROBE="$PROJECT_ROOT/.planning/codex-ipad-release/latest-official-probe-20260819.json"
RELEASE_RESOLVER="$PROJECT_ROOT/scripts/resolve_ipad_release.py"
APPS_FILE=""
RELEASE_EXTRACT_DIR=""
RELEASE_RESOLUTION_FILE=""

cleanup() {
  if [[ -n "$APPS_FILE" ]]; then
    unlink "$APPS_FILE" 2>/dev/null || true
  fi
  if [[ -n "$RELEASE_RESOLUTION_FILE" ]]; then
    unlink "$RELEASE_RESOLUTION_FILE" 2>/dev/null || true
  fi
  if [[ -n "$RELEASE_EXTRACT_DIR" ]]; then
    python3 - "$RELEASE_EXTRACT_DIR" <<'PY'
from pathlib import Path
import shutil
import sys

path = Path(sys.argv[1])
if path.is_dir():
    shutil.rmtree(path)
PY
  fi
}
trap cleanup EXIT

[[ -f "$SCREENSHOT_VALIDATOR" ]] || {
  echo "Device screenshot validator is missing" >&2
  exit 66
}
[[ -f "$RELEASE_RESOLVER" ]] || {
  echo "Canonical iPad release resolver is missing" >&2
  exit 66
}
[[ -f "$LATEST_PROBE" ]] || {
  echo "Latest official release probe is missing" >&2
  exit 66
}

# Never resolve, install, or launch against an offline device. This is a
# read-only CoreDevice query; in particular, this script has no device power
# operation and must leave an unavailable iPad untouched.
DEVICE_LIST="$(xcrun devicectl list devices 2>/dev/null || true)"
DEVICE_LINE="$(grep -F "$DEVICE_NAME" <<<"$DEVICE_LIST" || true)"
if ! grep -Eq '(^|[[:space:]])(connected|available[[:space:]]+\(paired\))([[:space:]]|$)' <<<"$DEVICE_LINE"; then
  echo "Target iPad is not available; refusing install/launch and leaving device untouched" >&2
  exit 75
fi

PROCESS_INFO="$(xcrun devicectl device info processes \
  --device "$DEVICE_NAME" \
  --search "Codex for ipad" 2>/dev/null || true)"
if [[ "$ALLOW_RUNNING_APP_REPLACEMENT" != "true" ]] \
  && grep -Eq "$BUNDLE_ID|Codex for ipad" <<<"$PROCESS_INFO"; then
  echo "Target Codex for ipad is already running; refusing install/launch and leaving the iPad untouched" >&2
  echo "Close the app first or set CODEXPAD_ALLOW_RUNNING_APP_REPLACEMENT=true for an explicit acceptance pass" >&2
  exit 75
fi

RELEASE_EXTRACT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/codexpad-release.XXXXXX")"
RELEASE_RESOLUTION_FILE="$(mktemp "${TMPDIR:-/tmp}/codexpad-release.XXXXXX.json")"
python3 "$RELEASE_RESOLVER" \
  --project-root "$PROJECT_ROOT" \
  --probe "$LATEST_PROBE" \
  --extract-root "$RELEASE_EXTRACT_DIR" \
  --output "$RELEASE_RESOLUTION_FILE"

APP="$(plutil -extract appPath raw -o - "$RELEASE_RESOLUTION_FILE")"
VERSION="$(plutil -extract version raw -o - "$RELEASE_RESOLUTION_FILE")"
BUILD="$(plutil -extract build raw -o - "$RELEASE_RESOLUTION_FILE")"
[[ -d "$APP" ]] || {
  echo "Verified canonical Codex for ipad app was not extracted" >&2
  exit 70
}
APP_FILE_INFO="$(file "$APP/Codex for ipad")"
grep -q 'Mach-O 64-bit executable arm64' <<<"$APP_FILE_INFO"
codesign --verify --deep --strict "$APP"
SIGNATURE_INFO="$(codesign -dvv "$APP" 2>&1)"
grep -q 'Authority=Apple Development:' <<<"$SIGNATURE_INFO"
[[ "$VERSION" =~ ^[0-9]+(\.[0-9]+)+$ ]]
[[ "$BUILD" =~ ^[0-9]+$ ]]

xcrun devicectl device install app \
  --device "$DEVICE_NAME" \
  "$APP"

APPS_FILE="$(mktemp)"
xcrun devicectl device info apps \
  --device "$DEVICE_NAME" \
  --bundle-id "$BUNDLE_ID" \
  --json-output "$APPS_FILE" >/dev/null
python3 - "$APPS_FILE" "$BUNDLE_ID" "$VERSION" "$BUILD" <<'PY'
import json
import sys

path, bundle_id, expected_version, expected_build = sys.argv[1:]
with open(path, encoding="utf-8") as stream:
    record = json.load(stream)
apps = record.get("result", {}).get("apps", [])
app = next(
    (
        candidate
        for candidate in apps
        if candidate.get("bundleIdentifier") == bundle_id
    ),
    None,
)
if app is None:
    raise SystemExit("installed Codex for ipad bundle was not found")
if str(app.get("version", "")) != expected_version:
    raise SystemExit("installed bundle version does not match the build")
if str(app.get("bundleVersion", "")) != expected_build:
    raise SystemExit("installed bundle build does not match the build")
PY

if [[ "$LAUNCH_AFTER_INSTALL" == "true" ]]; then
  # Explicit final-acceptance invocation:
  # CODEXPAD_LAUNCH_AFTER_INSTALL=true scripts/install_to_ipad.sh 'CONNECTED IPAD NAME'
  PROCESS_INFO="$(xcrun devicectl device info processes \
    --device "$DEVICE_NAME" \
    --search "Codex for ipad" 2>/dev/null || true)"
  if grep -Eq "$BUNDLE_ID|Codex for ipad" <<<"$PROCESS_INFO"; then
    echo "Codex for ipad is already running; skipping launch and leaving its process untouched"
  else
    xcrun devicectl device process launch \
      --device "$DEVICE_NAME" \
      "$BUNDLE_ID"
  fi
else
  echo "Skipping app launch; existing iPad app process was left untouched"
  exit 0
fi

sleep 2
PROCESS_INFO="$(xcrun devicectl device info processes \
  --device "$DEVICE_NAME" \
  --search "Codex for ipad")"
grep -E "$BUNDLE_ID|Codex for ipad" <<<"$PROCESS_INFO"

EVIDENCE_DIR="$ARTIFACTS/device-validation/$VERSION"
SCREENSHOT="$EVIDENCE_DIR/latest-model-catalog-launch.png"
mkdir -p "$EVIDENCE_DIR"
SCREENSHOT_DEADLINE=$((SECONDS + 60))
while true; do
  xcrun devicectl device capture screenshot \
    --device "$DEVICE_NAME" \
    --destination "$SCREENSHOT" >/dev/null
  if xcrun swift "$SCREENSHOT_VALIDATOR" "$SCREENSHOT"; then
    break
  fi
  if (( SECONDS >= SCREENSHOT_DEADLINE )); then
    echo "Codex for ipad did not finish mounting the latest desktop surface within 60 seconds" >&2
    exit 71
  fi
  sleep 2
done

python3 - \
  "$PROJECT_ROOT" \
  "$VERSION" \
  "$BUILD" \
  "$SCREENSHOT" \
  "$ARTIFACTS/ipad-device-validation-$VERSION.json" \
  "$ARTIFACTS/ipad-verified-$VERSION.json" <<'PY'
from __future__ import annotations

import datetime
import hashlib
import json
import os
from pathlib import Path
import struct
import sys
import tempfile

root = Path(sys.argv[1])
version = sys.argv[2]
build = sys.argv[3]
screenshot = Path(sys.argv[4])
device_record_path = Path(sys.argv[5])
verified_record_path = Path(sys.argv[6])

png = screenshot.read_bytes()
if png[:8] != b"\x89PNG\r\n\x1a\n" or len(png) < 24:
    raise SystemExit("captured device screenshot is not a valid PNG")
width, height = struct.unpack(">II", png[16:24])
visual_path = screenshot.relative_to(root).as_posix()
verified_at = datetime.datetime.now(datetime.timezone.utc).isoformat(
    timespec="seconds"
).replace("+00:00", "Z")


def atomic_write(path: Path, record: dict[str, object]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary: Path | None = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="w",
            encoding="utf-8",
            dir=path.parent,
            prefix=f".{path.name}.",
            delete=False,
        ) as stream:
            json.dump(record, stream, ensure_ascii=False, indent=2)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
            temporary = Path(stream.name)
        os.replace(temporary, path)
    finally:
        if temporary is not None and temporary.exists():
            temporary.unlink()


device_record: dict[str, object] = {
    "desktopVersion": version,
    "desktopBuild": build,
    "productName": "Codex for ipad",
    "deviceClass": "M-chip iPad arm64",
    "signedBuild": "passed",
    "localSignatureVerification": "passed",
    "installation": "passed",
    "installedBundleVersionMatched": True,
    "installedBundleBuildMatched": True,
    "launch": "passed",
    "foregroundProcessSurvival": "passed",
    "visibleLaunchUI": "passed",
    "realInteraction": "pending-task-workflow-validation",
    "verifiedAt": verified_at,
    "visualEvidence": {
        "path": visual_path,
        "sha256": hashlib.sha256(png).hexdigest(),
        "pixelWidth": width,
        "pixelHeight": height,
        "ocrMarkers": [
            "New Chat / 新对话",
            "Projects / 项目",
            "Recents / 最近",
        ],
    },
}
atomic_write(device_record_path, device_record)

verified_record: dict[str, object] = {}
if verified_record_path.is_file():
    loaded = json.loads(verified_record_path.read_text(encoding="utf-8"))
    if isinstance(loaded, dict):
        verified_record = loaded
verified_record.update(
    {
        "desktopVersion": version,
        "desktopBuild": build,
        "productName": "Codex for ipad",
        "bundleVersionMatched": True,
        "bundleBuildMatched": True,
        "deviceBuild": "passed",
        "deviceArchitecture": "arm64",
        "deviceInstallation": "passed",
        "deviceLaunch": "passed",
        "deviceProcessSurvival": "passed",
        "deviceVisualEvidence": visual_path,
    }
)
atomic_write(verified_record_path, verified_record)
PY

echo "LANDED app='Codex for ipad' architecture=arm64 visible-ui=passed"
