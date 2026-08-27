#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
usage: update_latest.sh

Manually download, reverse, build, verify, archive, and commit the current
official Codex desktop release for Codex for ipad. This script is never
scheduled or invoked by the iPad app.
EOF
}

case "$#" in
  0) ;;
  1)
    case "$1" in
      -h|--help)
        usage
        exit 0
        ;;
      *)
        usage >&2
        exit 64
        ;;
    esac
    ;;
  *)
    usage >&2
    exit 64
    ;;
esac

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DOWNLOAD_DIR="$PROJECT_ROOT/.downloads"
ARTIFACTS="$PROJECT_ROOT/artifacts"
IMPORT_SCRIPT="$PROJECT_ROOT/scripts/import_dmg.sh"
UPGRADE_SCRIPT="$PROJECT_ROOT/scripts/apply_ipad_upgrade.sh"
VERIFY_SCRIPT="$PROJECT_ROOT/scripts/verify_ipad_upgrade.sh"
STATIC_VERIFY_SCRIPT="$PROJECT_ROOT/scripts/verify_ipad_upgrade_static.sh"
STAGE_RELEASE_HELPER="$PROJECT_ROOT/scripts/stage_ipad_release.py"
PHYSICAL_ACCEPTANCE="${CODEXPAD_RUN_PHYSICAL_ACCEPTANCE:-false}"
case "$PHYSICAL_ACCEPTANCE" in
  true|false) ;;
  *)
    echo "CODEXPAD_RUN_PHYSICAL_ACCEPTANCE must be true or false: $PHYSICAL_ACCEPTANCE" >&2
    exit 64
    ;;
esac
DOWNLOAD_STATE_HELPER="$PROJECT_ROOT/scripts/official_download_state.py"
RELEASE_ARCHIVE_HELPER="$PROJECT_ROOT/scripts/release_archive.py"
IPA_RELEASE_GATE="$PROJECT_ROOT/scripts/ipad_release_gate.py"
RELEASE_PARITY_BUILDER="$PROJECT_ROOT/scripts/build_release_parity_evidence.py"
PARITY_CAPTURE_ASSEMBLER="$PROJECT_ROOT/scripts/assemble_release_parity_capture_input.py"
XCUI_EVIDENCE_HELPER="$PROJECT_ROOT/scripts/ipad_verification_evidence.py"
DESKTOP_PARITY_GATE="$PROJECT_ROOT/scripts/verify_desktop_parity_release.py"
FEATURE_COVERAGE_AUDITOR="$PROJECT_ROOT/scripts/audit_feature_protocol_coverage.py"
FEATURE_COVERAGE_MERGER="$PROJECT_ROOT/scripts/merge_feature_coverage_evidence.py"
APPHOST_API_AUDITOR="$PROJECT_ROOT/scripts/audit_desktop_apphost_api.py"
TRANSACTION_HELPER="$PROJECT_ROOT/scripts/upgrade_transaction.py"
OFFICIAL_CURL_TRANSPORT="$PROJECT_ROOT/scripts/official_curl_transport.sh"
VERIFICATION_CACHE="$PROJECT_ROOT/DerivedData/UpdaterVerification"
VERIFICATION_LOG_DIR="$VERIFICATION_CACHE/VerificationLogs"
PARITY_CAPTURE_INPUT_ROOT="$ARTIFACTS/parity-capture-input"
PARITY_RUNTIME_ROOT="$ARTIFACTS/parity-runtime"
OFFICIAL_URL="${CODEX_DMG_URL:-https://persistent.oaistatic.com/codex-app-prod/ChatGPT.dmg}"
STATE_DIR="$PROJECT_ROOT/.update-state"
UPGRADE_LOCK="$STATE_DIR/upgrade.lock"
SHLOCK_BIN="${SHLOCK_BIN:-/usr/bin/shlock}"

source "$OFFICIAL_CURL_TRANSPORT"

# Automatic update callers were removed; this lock now protects only an
# explicitly started manual release run. shlock creates the PID file atomically
# and reclaims it after an owner dies, so a crash or forced restart cannot
# permanently stop a later manual release run.
mkdir -p "$STATE_DIR"
if [[ ! -x "$SHLOCK_BIN" ]]; then
  echo "Required upgrade lock helper is missing: $SHLOCK_BIN" >&2
  exit 69
fi
if [[ -d "$UPGRADE_LOCK" ]]; then
  # Migrate an empty lock directory left by versions that predate the PID lock.
  # A running legacy updater has no ownership metadata, so keep non-empty
  # directories locked rather than deleting unknown state.
  rmdir "$UPGRADE_LOCK" 2>/dev/null || {
    echo "A Codex for ipad upgrade is already running" >&2
    exit 75
  }
fi

acquire_upgrade_lock() {
  if "$SHLOCK_BIN" -f "$UPGRADE_LOCK" -p "$$"; then
    return 0
  fi

  # shlock intentionally leaves a just-written dead PID alone for the rest of
  # that filesystem timestamp tick, because it may belong to a concurrent
  # creator. If the recorded process is already gone, wait through that tick
  # and let shlock perform its atomic stale-file replacement on a second try.
  local recorded_pid=""
  if [[ -f "$UPGRADE_LOCK" ]]; then
    recorded_pid="$(cat "$UPGRADE_LOCK" 2>/dev/null || true)"
  fi
  if [[ "$recorded_pid" =~ ^[1-9][0-9]*$ ]] \
    && kill -0 "$recorded_pid" 2>/dev/null
  then
    return 1
  fi
  sleep 1
  "$SHLOCK_BIN" -f "$UPGRADE_LOCK" -p "$$"
}

if ! acquire_upgrade_lock; then
  echo "A Codex for ipad upgrade is already running" >&2
  exit 75
fi

LOCK_HELD=true
TRANSACTION_ACTIVE=false
TRANSACTION_DIR=""
INITIAL_HEADERS_FILE=""
INITIAL_REMOTE_FILE=""
FINAL_HEADERS_FILE=""
FINAL_REMOTE_FILE=""
ATTACH_PLIST=""
MOUNT_POINT=""
IPA_GATE_RECORD=""
PARITY_GATE_RECORD=""
STAGED_RELEASE_RECORD=""

cleanup() {
  local status=$?
  local restore_status=0
  trap - EXIT
  set +e

  if [[ -n "$MOUNT_POINT" ]]; then
    hdiutil detach "$MOUNT_POINT" >/dev/null 2>&1
    MOUNT_POINT=""
  fi
  if [[ -n "$ATTACH_PLIST" ]]; then
    unlink "$ATTACH_PLIST" 2>/dev/null
  fi

  if [[ "$TRANSACTION_ACTIVE" == "true" && -d "$TRANSACTION_DIR" ]]; then
    python3 "$TRANSACTION_HELPER" restore \
      --root "$PROJECT_ROOT" \
      --transaction-dir "$TRANSACTION_DIR"
    restore_status=$?
    if [[ $restore_status -ne 0 ]]; then
      echo "Upgrade transaction restore failed" >&2
      if [[ $status -eq 0 ]]; then
        status=$restore_status
      fi
    fi
  fi

  local temporary
  for temporary in \
    "$INITIAL_HEADERS_FILE" \
    "$INITIAL_REMOTE_FILE" \
    "$FINAL_HEADERS_FILE" \
    "$FINAL_REMOTE_FILE" \
    "$PARITY_GATE_RECORD" \
    "$IPA_GATE_RECORD"
  do
    if [[ -n "$temporary" ]]; then
      unlink "$temporary" 2>/dev/null
    fi
  done
  if [[ "$LOCK_HELD" == "true" && -f "$UPGRADE_LOCK" ]]; then
    local lock_owner
    lock_owner="$(cat "$UPGRADE_LOCK" 2>/dev/null || true)"
    if [[ "$lock_owner" == "$$" ]]; then
      unlink "$UPGRADE_LOCK" 2>/dev/null
    fi
  fi
  exit "$status"
}
trap cleanup EXIT

mkdir -p \
  "$DOWNLOAD_DIR" \
  "$ARTIFACTS" \
  "$STATE_DIR/transactions"

# The lock is held before recovery, so no current updater can race a restore.
# A transaction is committed only after parity/archive/current-state gates pass;
# any directory left here represents an interrupted, uncommitted upgrade.
python3 "$TRANSACTION_HELPER" recover-pending \
  --root "$PROJECT_ROOT"

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
PART="$DOWNLOAD_DIR/ChatGPT-$STAMP.dmg.part"
DMG="$DOWNLOAD_DIR/ChatGPT-$STAMP.dmg"
INITIAL_HEADERS_FILE="$(mktemp "$STATE_DIR/initial-remote.headers.XXXXXX")"
INITIAL_REMOTE_FILE="$(mktemp "$STATE_DIR/initial-remote.json.XXXXXX")"
FINAL_HEADERS_FILE="$(mktemp "$STATE_DIR/final-remote.headers.XXXXXX")"
FINAL_REMOTE_FILE="$(mktemp "$STATE_DIR/final-remote.json.XXXXXX")"

probe_remote() {
  local headers_file="$1"
  local remote_file="$2"
  official_curl "$OFFICIAL_URL" \
    --http1.1 --fail --silent --show-error --location --head \
    --retry 3 --connect-timeout 15 --max-time 60 \
    --output "$headers_file"
  python3 "$DOWNLOAD_STATE_HELPER" parse-headers \
    --headers "$headers_file" \
    --output "$remote_file" \
    --url "$OFFICIAL_URL"
}

detach_image() {
  if [[ -n "$MOUNT_POINT" ]]; then
    hdiutil detach "$MOUNT_POINT" >/dev/null 2>&1 || true
    MOUNT_POINT=""
  fi
  if [[ -n "$ATTACH_PLIST" ]]; then
    unlink "$ATTACH_PLIST" 2>/dev/null || true
    ATTACH_PLIST=""
  fi
}

probe_remote "$INITIAL_HEADERS_FILE" "$INITIAL_REMOTE_FILE"
RETAINED="$(
  python3 "$DOWNLOAD_STATE_HELPER" select-reusable \
    --remote "$INITIAL_REMOTE_FILE" \
    --download-directory "$DOWNLOAD_DIR"
)"
if [[ -n "$RETAINED" ]]; then
  DMG="$RETAINED"
  echo "[1/7] Reusing retained complete official package: $(basename "$DMG")"
else
  echo "[1/7] Downloading complete official package"
  official_curl "$OFFICIAL_URL" \
    --http1.1 --fail --location --retry 3 --continue-at - \
    --output "$PART"
  # A same-second retry can target the same final name. Its old sidecar must
  # cease being authoritative before replacement.
  unlink "$DMG.remote.json" 2>/dev/null || true
  mv "$PART" "$DMG"
  probe_remote "$FINAL_HEADERS_FILE" "$FINAL_REMOTE_FILE"
  python3 "$DOWNLOAD_STATE_HELPER" assert-same \
    --expected "$INITIAL_REMOTE_FILE" \
    --actual "$FINAL_REMOTE_FILE"
fi

echo "[2/7] Verifying disk image and official application signature"
hdiutil verify "$DMG" >/dev/null

ATTACH_PLIST="$(mktemp "$STATE_DIR/official-attach.plist.XXXXXX")"
hdiutil attach -readonly -nobrowse -plist "$DMG" >"$ATTACH_PLIST"
MOUNT_POINT="$(
  plutil -extract system-entities xml1 -o - "$ATTACH_PLIST" |
    plutil -convert json -o - - |
    python3 -c 'import json,sys; entities=json.load(sys.stdin); print(next(x["mount-point"] for x in entities if "mount-point" in x))'
)"

APP="$(find "$MOUNT_POINT" -maxdepth 2 -name '*.app' -print -quit)"
[[ -n "$APP" ]] || { echo "No .app found in official DMG" >&2; exit 65; }

codesign --verify --deep --strict --verbose=2 "$APP"
spctl --assess --type execute --verbose=2 "$APP"

# Only a disk image that passed container, signature, and Gatekeeper checks is
# allowed to become a reusable retained package. The helper records its SHA-256.
python3 "$DOWNLOAD_STATE_HELPER" write-sidecar \
  --remote "$INITIAL_REMOTE_FILE" \
  --package "$DMG" >/dev/null

INFO="$APP/Contents/Info.plist"
VERSION="$(plutil -extract CFBundleShortVersionString raw -o - "$INFO")"
BUILD="$(plutil -extract CFBundleVersion raw -o - "$INFO")"
[[ "$VERSION" =~ ^[0-9]+(\.[0-9]+)+$ ]] || {
  echo "Official desktop version is malformed: $VERSION" >&2
  exit 65
}
[[ "$BUILD" =~ ^[0-9]+$ ]] || {
  echo "Official desktop build is malformed: $BUILD" >&2
  exit 65
}
SHA256="$(shasum -a 256 "$DMG" | awk '{print $1}')"
SIZE="$(stat -f '%z' "$DMG")"
DEST="$ARTIFACTS/app-asar-$VERSION"
IPAD_VERIFIED=false

echo "Official latest: version=$VERSION build=$BUILD size=$SIZE sha256=$SHA256"

# Release the first mount before import_dmg.sh mounts the image independently.
detach_image

TRANSACTION_DIR="$STATE_DIR/transactions/$STAMP-$$"
python3 "$TRANSACTION_HELPER" snapshot \
  --root "$PROJECT_ROOT" \
  --version "$VERSION" \
  --transaction-dir "$TRANSACTION_DIR"
TRANSACTION_ACTIVE=true

if [[ -d "$DEST" ]]; then
  echo "[3/7] Refreshing reverse import for already-seen version $VERSION"
else
  echo "[3/7] Reverse-importing version $VERSION"
fi
"$IMPORT_SCRIPT" "$DMG"

echo "[4/8] Auditing complete desktop AppHost coverage"
python3 "$APPHOST_API_AUDITOR" \
  --official-main "$DEST/.vite/build" \
  --official-renderer "$DEST/webview/assets" \
  --ipad-router "$PROJECT_ROOT/CodexPad/CodexPad/Application" \
  --output "$PROJECT_ROOT/versions/$VERSION/desktop-apphost-coverage.json" \
  --require-complete

OFFICIAL_PARITY_MANIFEST="$PARITY_RUNTIME_ROOT/$VERSION/$BUILD/official/manifest.json"
if [[ -x "$UPGRADE_SCRIPT" ]]; then
  echo "[5/8] Applying iPad upgrade"
  "$UPGRADE_SCRIPT" "$VERSION" "$BUILD"
else
  echo "Missing executable upgrade script: $UPGRADE_SCRIPT" >&2
  echo "Download retained: $DMG" >&2
  exit 78
fi

# The manual updater must never copy, re-sign, or launch a second desktop Codex
# instance. Source integration and the complete iPad build are allowed to finish
# first; exact official runtime evidence remains mandatory before physical-device
# verification, release archival, transaction commit, or transfer cleanup.
if [[ ! -f "$OFFICIAL_PARITY_MANIFEST" ]]; then
  echo "Missing approved official parity manifest: $OFFICIAL_PARITY_MANIFEST" >&2
  echo "Manual updater will not launch a desktop Codex capture instance" >&2
  echo "Download retained: $DMG" >&2
  exit 78
fi

if [[ "$PHYSICAL_ACCEPTANCE" == "true" ]]; then
  if [[ -x "$VERIFY_SCRIPT" ]]; then
    echo "[6/8] Verifying iPad upgrade on the explicitly selected physical device"
    "$VERIFY_SCRIPT" "$VERSION" "$BUILD" "$SHA256"
    IPAD_VERIFIED=true
    STAGED_RELEASE_RECORD="$STATE_DIR/staged-releases/$VERSION/$BUILD/$SHA256.json"
    if [[ -f "$STAGED_RELEASE_RECORD" ]]; then
      echo "[6/8] Promoting the exact staged candidate after physical acceptance"
      python3 "$STAGE_RELEASE_HELPER" promote \
        --project-root "$PROJECT_ROOT" \
        --stage "$STAGED_RELEASE_RECORD" \
        --verification "$ARTIFACTS/ipad-verified-$VERSION.json"
    else
      # Preserve the legacy direct-physical path for a first-ever run. Future
      # background upgrades stage first; an existing stage is always promoted
      # and never bypassed.
      echo "No staged record found; continuing one-time direct physical acceptance"
    fi
  else
    echo "Missing executable verification script: $VERIFY_SCRIPT" >&2
    echo "Download retained: $DMG" >&2
    exit 78
  fi
else
  if [[ -x "$STATIC_VERIFY_SCRIPT" && -x "$STAGE_RELEASE_HELPER" ]]; then
    echo "[6/8] Running static iPad release validation; physical device left untouched"
    "$STATIC_VERIFY_SCRIPT" "$VERSION" "$BUILD" "$SHA256"
    STATIC_RECORD="$ARTIFACTS/ipad-static-validated-$VERSION.json"
    STAGED_RELEASE_RECORD="$(python3 "$STAGE_RELEASE_HELPER" stage \
      --project-root "$PROJECT_ROOT" \
      --package "$DMG" \
      --static-record "$STATIC_RECORD")"
    echo "Static release staged at $STAGED_RELEASE_RECORD; physical acceptance, promotion, archive, and cleanup remain deferred"
    # The staged source/import result is deliberately retained for the later
    # physical-acceptance pass. It is not promoted to latest-official.json and
    # the transfer package remains retained; only the rollback snapshot is
    # committed so EXIT cleanup cannot silently erase the staged candidate.
    python3 "$TRANSACTION_HELPER" commit \
      --root "$PROJECT_ROOT" \
      --transaction-dir "$TRANSACTION_DIR"
    TRANSACTION_ACTIVE=false
    exit 0
  else
    echo "Missing executable static validation/staging script" >&2
    echo "Download retained: $DMG" >&2
    exit 78
  fi
fi

[[ -d "$DEST" ]] || { echo "Extracted version missing: $DEST" >&2; exit 70; }

echo "[6/10] Rebuilding exact feature protocol coverage audit"
VERSION_ROOT="$PROJECT_ROOT/versions/$VERSION"
FEATURE_PROTOCOL_SOURCE="$PROJECT_ROOT/artifacts/full-reverse-$VERSION/official-codex-source/codex-rs/app-server-protocol/src/protocol/common.rs"
python3 "$FEATURE_COVERAGE_AUDITOR" \
  --protocol "$FEATURE_PROTOCOL_SOURCE" \
  --inventory "$VERSION_ROOT/feature-inventory.json" \
  --production-root "$PROJECT_ROOT/CodexPad/CodexPad" \
  --production-root "$PROJECT_ROOT/CodexCore" \
  --test-root "$PROJECT_ROOT/CodexPad/Tests" \
  --test-root "$PROJECT_ROOT/tests" \
  --output "$VERSION_ROOT/feature-coverage-audit.json"
python3 "$FEATURE_COVERAGE_MERGER" \
  --inventory "$VERSION_ROOT/feature-inventory.json" \
  --coverage "$VERSION_ROOT/feature-coverage-audit.json"
python3 "$FEATURE_COVERAGE_AUDITOR" \
  --protocol "$FEATURE_PROTOCOL_SOURCE" \
  --inventory "$VERSION_ROOT/feature-inventory.json" \
  --production-root "$PROJECT_ROOT/CodexPad/CodexPad" \
  --production-root "$PROJECT_ROOT/CodexCore" \
  --test-root "$PROJECT_ROOT/CodexPad/Tests" \
  --test-root "$PROJECT_ROOT/tests" \
  --output "$VERSION_ROOT/feature-coverage-audit.json"

echo "[7/10] Binding current release captures and verification logs"
PARITY_CAPTURE_INPUT="$PARITY_CAPTURE_INPUT_ROOT/$VERSION/$BUILD/capture-input.json"
IPAD_PARITY_MANIFEST="$PARITY_RUNTIME_ROOT/$VERSION/$BUILD/ipad/manifest.json"
python3 "$PARITY_CAPTURE_ASSEMBLER" \
  --project-root "$PROJECT_ROOT" \
  --official-manifest "$OFFICIAL_PARITY_MANIFEST" \
  --ipad-manifest "$IPAD_PARITY_MANIFEST" \
  --output "$PARITY_CAPTURE_INPUT" \
  --desktop-version "$VERSION" \
  --desktop-build "$BUILD"
python3 "$RELEASE_PARITY_BUILDER" \
  --project-root "$PROJECT_ROOT" \
  --desktop-version "$VERSION" \
  --desktop-build "$BUILD" \
  --capture-input "$PARITY_CAPTURE_INPUT" \
  --python-test-log "$VERIFICATION_LOG_DIR/python-test.log" \
  --swift-test-log "$VERIFICATION_LOG_DIR/swift-test.log" \
  --rust-test-log "$VERIFICATION_LOG_DIR/rust-test.log" \
  --xcui-test-log "$VERIFICATION_LOG_DIR/xcui-test.log" \
  --device-build-log "$VERIFICATION_LOG_DIR/device-build.log" \
  --device-surface-log \
    "$VERIFICATION_LOG_DIR/device-desktop-surface.json"

PARITY_VERIFICATION_DIR="$ARTIFACTS/parity-evidence/$VERSION/verification"
STABLE_XCUI_SUMMARY="$PARITY_VERIFICATION_DIR/xcui-summary.json"
STABLE_XCUI_RESULT="$PARITY_VERIFICATION_DIR/CodexPadUITests.xcresult"
/bin/cp -p "$VERIFICATION_LOG_DIR/xcui-summary.json" "$STABLE_XCUI_SUMMARY"
rm -rf "$STABLE_XCUI_RESULT"
/bin/cp -R \
  "$VERIFICATION_CACHE/CodexPadUITests.xcresult" \
  "$STABLE_XCUI_RESULT"

SOURCE_HEAD="$(git -C "$PROJECT_ROOT" rev-parse HEAD)"
python3 "$XCUI_EVIDENCE_HELPER" record \
  --record "$ARTIFACTS/ipad-verified-$VERSION.json" \
  --project-root "$PROJECT_ROOT" \
  --summary "$STABLE_XCUI_SUMMARY" \
  --xcresult "$STABLE_XCUI_RESULT" \
  --source-head "$SOURCE_HEAD" \
  --contract "$VERSION_ROOT/desktop-ui-parity.json" \
  --log "python=$PARITY_VERIFICATION_DIR/python-tests.log" \
  --log "swift=$PARITY_VERIFICATION_DIR/swift-tests.log" \
  --log "rust=$PARITY_VERIFICATION_DIR/rust-tests.log" \
  --log "xcui=$PARITY_VERIFICATION_DIR/xcui-tests.log" \
  --log "device-build=$PARITY_VERIFICATION_DIR/device-build.log" \
  --log "device-surface=$PARITY_VERIFICATION_DIR/device-surface.json"

echo "[6/9] Enforcing exact desktop feature and UI parity evidence"
PARITY_GATE_RECORD="$STATE_DIR/parity-gate-$STAMP-$$.json"
python3 "$DESKTOP_PARITY_GATE" \
  --project-root "$PROJECT_ROOT" \
  --desktop-version "$VERSION" \
  --desktop-build "$BUILD" \
  --expected-dmg-sha256 "$SHA256" \
  --output "$PARITY_GATE_RECORD"

echo "[7/9] Building and validating the exact signed iPad Release IPA"
IPA_GATE_RECORD="$STATE_DIR/ipa-gate-$STAMP-$$.json"
"$IPA_RELEASE_GATE" build-and-validate \
  --project-root "$PROJECT_ROOT" \
  --identity-record "$ARTIFACTS/manifest-$VERSION.json" \
  --output-root "$ARTIFACTS/ipad-release" \
  --output "$IPA_GATE_RECORD"
IPA_PATH="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["ipaPath"])' "$IPA_GATE_RECORD")"
IPA_SHA256="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["ipaSha256"])' "$IPA_GATE_RECORD")"
IPA_RELEASE_MANIFEST_PATH="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["ipaReleaseManifestPath"])' "$IPA_GATE_RECORD")"
IPA_RELEASE_MANIFEST_SHA256="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["ipaReleaseManifestSha256"])' "$IPA_GATE_RECORD")"

echo "[8/9] Archiving the exact verified release"
python3 "$RELEASE_ARCHIVE_HELPER" archive \
  --project-root "$PROJECT_ROOT" \
  --version "$VERSION" \
  --build "$BUILD" \
  --dmg-sha256 "$SHA256" \
  --dmg "$DMG"

RELEASE_ROOT="artifacts/releases/$VERSION/$BUILD/$SHA256"
RELEASE_MANIFEST="$PROJECT_ROOT/$RELEASE_ROOT/release-manifest.json"
RELEASE_MANIFEST_SHA256="$(
  shasum -a 256 "$RELEASE_MANIFEST" | awk '{print $1}'
)"
if [[ ! "$RELEASE_MANIFEST_SHA256" =~ ^[0-9a-f]{64}$ ]]; then
  echo "Release manifest hash is malformed" >&2
  exit 70
fi

echo "[9/9] Confirming the archived official package is still current"
probe_remote "$FINAL_HEADERS_FILE" "$FINAL_REMOTE_FILE"
python3 "$DOWNLOAD_STATE_HELPER" assert-same \
  --expected "$INITIAL_REMOTE_FILE" \
  --actual "$FINAL_REMOTE_FILE"

python3 - "$ARTIFACTS/latest-official.json" <<PY
import json
import os
import pathlib
import tempfile
import sys

path = pathlib.Path(sys.argv[1])
record = {
    "checked_at": "$STAMP",
    "official_url": "$OFFICIAL_URL",
    "version": "$VERSION",
    "build": "$BUILD",
    "size": int("$SIZE"),
    "sha256": "$SHA256",
    "reverse_imported": True,
    "ipad_upgrade_verified": "$IPAD_VERIFIED" == "true",
    "releaseRoot": "$RELEASE_ROOT",
    "releaseManifestSha256": "$RELEASE_MANIFEST_SHA256",
    "ipaPath": "$IPA_PATH",
    "ipaSha256": "$IPA_SHA256",
    "ipaReleaseManifestPath": "$IPA_RELEASE_MANIFEST_PATH",
    "ipaReleaseManifestSha256": "$IPA_RELEASE_MANIFEST_SHA256",
}
temporary = None
try:
    with tempfile.NamedTemporaryFile(
        mode="w",
        encoding="utf-8",
        dir=path.parent,
        prefix=f".{path.name}.",
        delete=False,
    ) as handle:
        json.dump(record, handle, ensure_ascii=False, indent=2)
        handle.write("\\n")
        handle.flush()
        os.fsync(handle.fileno())
        temporary = pathlib.Path(handle.name)
    os.replace(temporary, path)
finally:
    if temporary is not None and temporary.exists():
        temporary.unlink()
PY

python3 "$DOWNLOAD_STATE_HELPER" assert-local-current \
  --project-root "$PROJECT_ROOT" \
  --latest "$ARTIFACTS/latest-official.json"

python3 "$TRANSACTION_HELPER" commit \
  --root "$PROJECT_ROOT" \
  --transaction-dir "$TRANSACTION_DIR"
TRANSACTION_ACTIVE=false

echo "[7/7] Upgrade committed; deleting redundant transfer files"
rm -f -- "$DMG" "$DMG.remote.json" "$PART"
python3 "$DOWNLOAD_STATE_HELPER" cleanup-incomplete-parts \
  --remote "$FINAL_REMOTE_FILE" \
  --download-directory "$DOWNLOAD_DIR"
rm -rf "$VERIFICATION_CACHE"

echo "SUCCESS version=$VERSION build=$BUILD"
