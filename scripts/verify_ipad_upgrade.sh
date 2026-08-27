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
DERIVED_DATA="$PROJECT_ROOT/DerivedData/UpdaterVerification"
APP="$DERIVED_DATA/Build/Products/Debug-iphoneos/Codex for ipad.app"
VERIFICATION_LOG_DIR="$DERIVED_DATA/VerificationLogs"
PYTHON_TEST_LOG="$VERIFICATION_LOG_DIR/python-test.log"
SWIFT_TEST_LOG="$VERIFICATION_LOG_DIR/swift-test.log"
RUST_TEST_LOG="$VERIFICATION_LOG_DIR/rust-test.log"
XCUI_TEST_LOG="$VERIFICATION_LOG_DIR/xcui-test.log"
XCUI_SUMMARY="$VERIFICATION_LOG_DIR/xcui-summary.json"
DEVICE_BUILD_LOG="$VERIFICATION_LOG_DIR/device-build.log"
SURFACE_VERIFIER="$PROJECT_ROOT/scripts/verify_desktop_surface_bundle.py"
BRIDGE_API_VERIFIER="$PROJECT_ROOT/scripts/verify_desktop_bridge_api.py"
PARITY_CAPTURE_PLAN_BUILDER="$PROJECT_ROOT/scripts/parity_capture_plan.py"
INTERACTION_COVERAGE_AUDITOR="$PROJECT_ROOT/scripts/audit_ipad_interaction_coverage.py"
CONTROL_COVERAGE_AUDITOR="$PROJECT_ROOT/scripts/audit_ipad_control_coverage.py"
APPHOST_API_AUDITOR="$PROJECT_ROOT/scripts/audit_desktop_apphost_api.py"
APPHOST_SEMANTICS_AUDITOR="$PROJECT_ROOT/scripts/audit_ipad_apphost_semantics.py"
DEVICE_SELECTOR="$PROJECT_ROOT/scripts/select_physical_ipad.py"
XCUI_EVIDENCE_HELPER="$PROJECT_ROOT/scripts/ipad_verification_evidence.py"
DEVICE_SURFACE_LOG="$VERIFICATION_LOG_DIR/device-desktop-surface.json"
DEVICE_SELECTION_LOG="$VERIFICATION_LOG_DIR/physical-device-selection.json"
XCUI_RESULT="$DERIVED_DATA/CodexPadUITests.xcresult"
VERIFICATION_RECORD="$PROJECT_ROOT/artifacts/ipad-verified-$VERSION.json"
BRIDGE_API_RECORD="$PROJECT_ROOT/versions/$VERSION/desktop-bridge-api.json"
IPAD_PARITY_CAPTURE_DIR="$PROJECT_ROOT/artifacts/parity-runtime/$VERSION/$BUILD/ipad"
PARITY_CAPTURE_PLAN="$VERIFICATION_LOG_DIR/parity-capture-plan.json"
INTERACTION_COVERAGE_LOG="$VERIFICATION_LOG_DIR/ipad-interaction-static-audit.json"
CONTROL_COVERAGE_LOG="$VERIFICATION_LOG_DIR/ipad-control-static-audit.json"
APPHOST_SEMANTICS_LOG="$VERIFICATION_LOG_DIR/ipad-apphost-semantics.json"
APPHOST_COVERAGE_LOG="$VERIFICATION_LOG_DIR/desktop-apphost-coverage.json"

PHYSICAL_ACCEPTANCE="${CODEXPAD_RUN_PHYSICAL_ACCEPTANCE:-false}"
if [[ "$PHYSICAL_ACCEPTANCE" != "true" ]]; then
  echo "Physical iPad acceptance was not explicitly requested; device left untouched"
  exit 78
fi

mkdir -p "$VERIFICATION_LOG_DIR"
python3 "$XCUI_EVIDENCE_HELPER" invalidate \
  --record "$VERIFICATION_RECORD"
SOURCE_HEAD="$(git -C "$PROJECT_ROOT" rev-parse HEAD)"
python3 "$BRIDGE_API_VERIFIER" \
  --official-preload \
  "$PROJECT_ROOT/artifacts/full-reverse-$VERSION/recovered-electron-source/.vite/build/preload.js" \
  --ipad-bridge \
  "$PROJECT_ROOT/CodexPad/CodexPad/ProtocolBridge/CodexDesktopBridgeScript.swift" \
  --output "$BRIDGE_API_RECORD"
python3 "$PARITY_CAPTURE_PLAN_BUILDER" \
  --output "$PARITY_CAPTURE_PLAN"
python3 "$INTERACTION_COVERAGE_AUDITOR" \
  --inventory \
  "$PROJECT_ROOT/versions/$VERSION/desktop-interaction-inventory.json" \
  --capture-plan "$PARITY_CAPTURE_PLAN" \
  --ui-test \
  "$PROJECT_ROOT/CodexPad/Tests/CodexPadUITests/CodexPadParityCaptureUITests.swift" \
  --output "$INTERACTION_COVERAGE_LOG" \
  --require-complete
python3 "$CONTROL_COVERAGE_AUDITOR" \
  --inventory \
  "$PROJECT_ROOT/versions/$VERSION/desktop-interaction-inventory.json" \
  --surface-root \
  "$PROJECT_ROOT/artifacts/full-reverse-$VERSION/app-asar/webview" \
  --production-root "$PROJECT_ROOT/CodexPad/CodexPad" \
  --ui-test-root "$PROJECT_ROOT/CodexPad/Tests/CodexPadUITests" \
  --output "$CONTROL_COVERAGE_LOG" \
  --require-assets-complete
python3 "$APPHOST_API_AUDITOR" \
  --official-main \
  "$PROJECT_ROOT/artifacts/full-reverse-$VERSION/app-asar/.vite/build" \
  --official-renderer \
  "$PROJECT_ROOT/artifacts/full-reverse-$VERSION/app-asar/webview/assets" \
  --ipad-router "$PROJECT_ROOT/CodexPad/CodexPad/Application" \
  --output "$APPHOST_COVERAGE_LOG" \
  --require-complete
python3 "$APPHOST_SEMANTICS_AUDITOR" \
  --apphost-report "$APPHOST_COVERAGE_LOG" \
  --source-root "$PROJECT_ROOT/CodexPad/CodexPad/Application" \
  --output "$APPHOST_SEMANTICS_LOG" \
  --require-no-placeholders
python3 "$DEVICE_SELECTOR" --format json >"$DEVICE_SELECTION_LOG"
DEVICE_UDID="$(
  python3 - "$DEVICE_SELECTION_LOG" <<'PY'
import json
import sys
print(json.load(open(sys.argv[1], encoding="utf-8"))["udid"])
PY
)"
DEVICE_DESTINATION="platform=iOS,id=$DEVICE_UDID"
TEAM_ID="${DEVELOPMENT_TEAM:-}"
if [[ -z "$TEAM_ID" ]]; then
  TEAM_ID="$(
    defaults export com.apple.dt.Xcode - 2>/dev/null |
      python3 -c '
import plistlib
import sys

data = plistlib.loads(sys.stdin.buffer.read())
teams = data.get("IDEProvisioningTeamByIdentifier", {})
for entries in teams.values():
    for team in entries:
        if team.get("isFreeProvisioningTeam") or team.get("teamType") == "Personal Team":
            team_id = team.get("teamID", "")
            if team_id:
                print(team_id)
                raise SystemExit(0)
'
  )"
fi
[[ -n "$TEAM_ID" ]] || {
  echo "Personal Team has not finished syncing in Xcode" >&2
  exit 78
}
python3 -m unittest discover \
  -s "$PROJECT_ROOT/tests" \
  -p 'test_*.py' 2>&1 | tee "$PYTHON_TEST_LOG"
if [[ -f "$PROJECT_ROOT/scripts/run_swift_tests.py" ]]; then
  python3 "$PROJECT_ROOT/scripts/run_swift_tests.py" \
    --package-path "$PROJECT_ROOT/CodexPad" 2>&1 | tee "$SWIFT_TEST_LOG"
else
  swift test --package-path "$PROJECT_ROOT/CodexPad" 2>&1 | tee "$SWIFT_TEST_LOG"
fi
SWIFT_TEST_COUNT="$(
  python3 "$PROJECT_ROOT/scripts/swift_test_count.py" "$SWIFT_TEST_LOG"
)"
(
  cargo test \
    --locked \
    --manifest-path "$PROJECT_ROOT/CodexCore/Cargo.toml"
) 2>&1 | tee "$RUST_TEST_LOG"
rm -rf "$XCUI_RESULT"
rm -f "$XCUI_SUMMARY"
xcodebuild \
  -project "$PROJECT_ROOT/CodexPad/CodexPad.xcodeproj" \
  -scheme CodexPad \
  -configuration Debug \
  -sdk iphoneos \
  -destination "$DEVICE_DESTINATION" \
  -derivedDataPath "$DERIVED_DATA" \
  -resultBundlePath "$XCUI_RESULT" \
  -allowProvisioningUpdates \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  CODE_SIGN_STYLE=Automatic \
  -parallel-testing-enabled NO \
  -disable-concurrent-destination-testing \
  -collect-test-diagnostics never \
  -test-timeouts-enabled YES \
  -default-test-execution-time-allowance 1800 \
  -maximum-test-execution-time-allowance 1800 \
  -only-testing:CodexPadUITests \
  test 2>&1 | tee "$XCUI_TEST_LOG" "$DEVICE_BUILD_LOG"
xcrun xcresulttool get test-results summary \
  --path "$XCUI_RESULT" \
  --compact >"$XCUI_SUMMARY"

python3 "$PROJECT_ROOT/scripts/export_xcresult_parity_captures.py" \
  --xcresult "$XCUI_RESULT" \
  --output "$IPAD_PARITY_CAPTURE_DIR" \
  --desktop-version "$VERSION" \
  --desktop-build "$BUILD"

[[ -d "$APP" ]] || {
  echo "missing signed physical-device app: $APP" >&2
  exit 70
}
display_name="$(plutil -extract CFBundleDisplayName raw -o - "$APP/Info.plist")"
[[ "$display_name" == "Codex for ipad" ]] || {
  echo "unexpected display name: $display_name" >&2
  exit 70
}
short_version="$(plutil -extract CFBundleShortVersionString raw -o - "$APP/Info.plist")"
[[ "$short_version" == "$VERSION" ]] || {
  echo "unexpected short version: $short_version (expected $VERSION)" >&2
  exit 70
}
bundle_version="$(plutil -extract CFBundleVersion raw -o - "$APP/Info.plist")"
[[ "$bundle_version" == "$BUILD" ]] || {
  echo "unexpected bundle version: $bundle_version (expected $BUILD)" >&2
  exit 70
}
file_output="$(file "$APP/Codex for ipad")"
echo "$file_output"
file "$APP/Codex for ipad" | grep -q 'arm64' || {
  echo "device binary is not arm64: $file_output" >&2
  exit 70
}
codesign --verify --deep --strict "$APP"
signature_info="$(codesign -dvv "$APP" 2>&1)"
grep -q 'Authority=Apple Development:' <<<"$signature_info" || {
  echo "physical-device app is not Apple Development signed" >&2
  exit 70
}
python3 "$SURFACE_VERIFIER" \
  --surface-root "$APP/CodexDesktopSurface" \
  --desktop-version "$VERSION" \
  --desktop-build "$BUILD" \
  --output "$DEVICE_SURFACE_LOG"
python3 - \
  "$VERIFICATION_RECORD" \
  "$DEVICE_SELECTION_LOG" \
  "$SWIFT_TEST_LOG" \
  "$DEVICE_SURFACE_LOG" \
  "$VERSION" \
  "$BUILD" \
  "$DMG_SHA256" \
  "$SWIFT_TEST_COUNT" <<'PY'
import json
import os
import sys
import tempfile
from pathlib import Path

output_path = Path(sys.argv[1])
device_selection_log = Path(sys.argv[2])
swift_test_log = Path(sys.argv[3])
device_surface_log = Path(sys.argv[4])
version = sys.argv[5]
build = sys.argv[6]
dmg_sha256 = sys.argv[7]
swift_test_count = int(sys.argv[8])
physical_device = json.loads(
    device_selection_log.read_text(encoding="utf-8")
)
if (
    not isinstance(physical_device, dict)
    or not isinstance(physical_device.get("udid"), str)
    or not isinstance(physical_device.get("name"), str)
    or not isinstance(physical_device.get("modelName"), str)
    or not isinstance(physical_device.get("operatingSystemVersion"), str)
):
    raise RuntimeError("selected physical iPad inventory is malformed")
device_surface = json.loads(device_surface_log.read_text(encoding="utf-8"))
if not isinstance(device_surface, dict) or device_surface.get("status") != "passed":
    raise RuntimeError("physical-device desktop surface verification did not pass")

if output_path.exists():
    with output_path.open(encoding="utf-8") as handle:
        record = json.load(handle)
    if not isinstance(record, dict):
        raise TypeError("existing iPad verification record must be an object")
else:
    record = {}

record.update({
    "desktopVersion": version,
    "desktopBuild": build,
    "productName": "Codex for ipad",
    "bundleVersionMatched": True,
    "bundleBuildMatched": True,
    "rustTests": "passed",
    "swiftTests": "passed",
    "swiftTestCount": swift_test_count,
    "physicalDeviceTests": "passed",
    "physicalDeviceUDID": physical_device["udid"],
    "physicalDeviceName": physical_device["name"],
    "physicalDeviceModel": physical_device["modelName"],
    "physicalDeviceOS": physical_device["operatingSystemVersion"],
    "deviceBuild": "passed",
    "deviceArchitecture": "arm64",
    "desktopSurfaceCompleteTree": "passed",
    "sourceIdentity": {
        "dmgSha256": dmg_sha256,
    },
    "desktopSurface": {
        "entry": device_surface["entry"],
        "criticalFileCount": device_surface["criticalFileCount"],
        "resourceFileCount": device_surface["resourceFileCount"],
        "resourceTotalBytes": device_surface["resourceTotalBytes"],
        "resourceTreeSha256": device_surface["resourceTreeSha256"],
        "deviceBundleVerified": True,
    },
})

temporary_path = None
try:
    with tempfile.NamedTemporaryFile(
        mode="w",
        encoding="utf-8",
        dir=output_path.parent,
        prefix=f".{output_path.name}.",
        suffix=".tmp",
        delete=False,
    ) as handle:
        temporary_path = Path(handle.name)
        json.dump(record, handle, ensure_ascii=False, indent=2)
        handle.write("\n")
        handle.flush()
        os.fsync(handle.fileno())
    os.replace(temporary_path, output_path)
finally:
    if temporary_path is not None:
        temporary_path.unlink(missing_ok=True)
PY
CURRENT_HEAD="$(git -C "$PROJECT_ROOT" rev-parse HEAD)"
[[ "$CURRENT_HEAD" == "$SOURCE_HEAD" ]] || {
  echo "git HEAD changed during iPad verification" >&2
  exit 70
}
python3 "$XCUI_EVIDENCE_HELPER" record \
  --record "$VERIFICATION_RECORD" \
  --project-root "$PROJECT_ROOT" \
  --summary "$XCUI_SUMMARY" \
  --xcresult "$XCUI_RESULT" \
  --source-head "$SOURCE_HEAD" \
  --contract "$PROJECT_ROOT/versions/$VERSION/desktop-ui-parity.json" \
  --log "python=$PYTHON_TEST_LOG" \
  --log "swift=$SWIFT_TEST_LOG" \
  --log "rust=$RUST_TEST_LOG" \
  --log "static-interaction=$INTERACTION_COVERAGE_LOG" \
  --log "static-controls=$CONTROL_COVERAGE_LOG" \
  --log "apphost-semantics=$APPHOST_SEMANTICS_LOG" \
  --log "xcui=$XCUI_TEST_LOG" \
  --log "device-build=$DEVICE_BUILD_LOG" \
  --log "device-surface=$DEVICE_SURFACE_LOG"
echo "Verified Codex for ipad upgrade $VERSION ($BUILD)"
