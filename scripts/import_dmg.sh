#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 /path/to/ChatGPT.dmg" >&2
  exit 64
fi

DMG="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARTIFACTS="$PROJECT_ROOT/artifacts"
PROTOCOL_SCRIPT="$PROJECT_ROOT/scripts/generate_protocol_snapshot.sh"
SOURCE_SCRIPT="$PROJECT_ROOT/scripts/import_official_source.sh"
FULL_REVERSE_SCRIPT="$PROJECT_ROOT/scripts/reverse_full_bundle.py"
IPC_SCRIPT="$PROJECT_ROOT/scripts/extract_electron_ipc.py"
VISUAL_SCRIPT="$PROJECT_ROOT/scripts/extract_visual_reference.py"
BUNDLE_SCRIPT="$PROJECT_ROOT/scripts/electron_bundle_inventory.py"
FEATURE_SCRIPT="$PROJECT_ROOT/scripts/build_feature_inventory.py"
FEATURE_EVIDENCE_SCRIPT="$PROJECT_ROOT/scripts/carry_forward_feature_evidence.py"
SURFACE_MANIFEST_SCRIPT="$PROJECT_ROOT/scripts/build_desktop_surface_manifest.py"
INTERACTION_INVENTORY_SCRIPT="$PROJECT_ROOT/scripts/build_desktop_interaction_inventory.py"
UI_PARITY_SCRIPT="$PROJECT_ROOT/scripts/build_desktop_ui_parity.py"
EXPECTED_BUNDLE_ID="com.openai.codex"
EXPECTED_TEAM_ID="2DC432GLL2"

[[ -f "$DMG" ]] || { echo "DMG not found: $DMG" >&2; exit 66; }
mkdir -p "$ARTIFACTS"

hdiutil verify "$DMG" >/dev/null

ATTACH_PLIST="$(mktemp)"
MOUNT_POINT=""
STAGE=""
PREVIOUS_DEST=""
DEST_PROMOTED=false
IMPORT_SUCCEEDED=false
hdiutil attach -readonly -nobrowse -plist "$DMG" > "$ATTACH_PLIST"

MOUNT_POINT="$(
  plutil -extract system-entities xml1 -o - "$ATTACH_PLIST" |
    plutil -convert json -o - - |
    python3 -c 'import json,sys; entities=json.load(sys.stdin); print(next(x["mount-point"] for x in entities if "mount-point" in x))'
)"

cleanup_mount() {
  if [[ -n "$MOUNT_POINT" ]]; then
    hdiutil detach "$MOUNT_POINT" >/dev/null 2>&1 || true
    MOUNT_POINT=""
  fi
}

cleanup() {
  local status=$?
  trap - EXIT
  cleanup_mount
  if [[ -n "$STAGE" && -d "$STAGE" ]]; then
    rm -rf "$STAGE"
  fi
  if [[ "$IMPORT_SUCCEEDED" == true ]]; then
    if [[ -n "$PREVIOUS_DEST" && -d "$PREVIOUS_DEST" ]]; then
      rm -rf "$PREVIOUS_DEST"
    fi
  elif [[ "$DEST_PROMOTED" == true ]]; then
    rm -rf "$DEST"
    if [[ -n "$PREVIOUS_DEST" && -d "$PREVIOUS_DEST" ]]; then
      mv "$PREVIOUS_DEST" "$DEST"
    fi
  elif [[ -n "$PREVIOUS_DEST" && -d "$PREVIOUS_DEST" ]]; then
    mv "$PREVIOUS_DEST" "$DEST"
  fi
  unlink "$ATTACH_PLIST" 2>/dev/null || true
  exit "$status"
}
trap cleanup EXIT

APP="$(find "$MOUNT_POINT" -maxdepth 2 -name '*.app' -print -quit)"
[[ -n "$APP" ]] || { echo "No .app found in DMG" >&2; exit 65; }

INFO="$APP/Contents/Info.plist"
ASAR="$APP/Contents/Resources/app.asar"
codesign --verify --deep --strict --verbose=2 "$APP"
spctl --assess --type execute --verbose=2 "$APP"
SIGNATURE_INFO="$(codesign -dvv "$APP" 2>&1)"
BUNDLE_ID="$(plutil -extract CFBundleIdentifier raw -o - "$INFO")"
TEAM_ID="$(
  printf '%s\n' "$SIGNATURE_INFO" |
    awk -F= '/^TeamIdentifier=/ {print $2; exit}'
)"
[[ "$BUNDLE_ID" == "$EXPECTED_BUNDLE_ID" ]] || {
  echo "Unexpected official bundle identifier: $BUNDLE_ID" >&2
  exit 65
}
[[ "$TEAM_ID" == "$EXPECTED_TEAM_ID" ]] || {
  echo "Unexpected official signing team: $TEAM_ID" >&2
  exit 65
}
VERSION="$(plutil -extract CFBundleShortVersionString raw -o - "$INFO")"
BUILD="$(plutil -extract CFBundleVersion raw -o - "$INFO")"
DEST="$ARTIFACTS/app-asar-$VERSION"

[[ -f "$ASAR" ]] || { echo "app.asar not found" >&2; exit 65; }

if [[ -e "$DEST" && ! -d "$DEST" ]]; then
  echo "ASAR destination exists but is not a directory: $DEST" >&2
  exit 73
fi

STAGE="$(mktemp -d "$ARTIFACTS/.asar-$VERSION.XXXXXX")"
npx -y @electron/asar@4.0.1 extract "$ASAR" "$STAGE"
if [[ -d "$DEST" ]]; then
  PREVIOUS_DEST="$ARTIFACTS/.asar-$VERSION.previous.$$"
  [[ ! -e "$PREVIOUS_DEST" ]] || {
    echo "ASAR rollback destination already exists: $PREVIOUS_DEST" >&2
    exit 73
  }
  mv "$DEST" "$PREVIOUS_DEST"
fi
if mv "$STAGE" "$DEST"; then
  STAGE=""
  DEST_PROMOTED=true
else
  echo "ASAR promotion failed: $DEST" >&2
  exit 73
fi

cp "$INFO" "$ARTIFACTS/Info-$VERSION.plist"
codesign -d --entitlements :- "$APP" \
  > "$ARTIFACTS/entitlements-$VERSION.plist" 2>/dev/null || true

DMG_SHA256="$(shasum -a 256 "$DMG" | awk '{print $1}')"
FILE_COUNT="$(find "$DEST" -type f | wc -l | tr -d ' ')"

python3 - "$ARTIFACTS/manifest-$VERSION.json" <<PY
import json, sys
manifest = {
    "version": "$VERSION",
    "build": "$BUILD",
    "dmg_filename": "$(basename "$DMG")",
    "dmg_sha256": "$DMG_SHA256",
    "extracted_path": "artifacts/$(basename "$DEST")",
    "file_count": int("$FILE_COUNT"),
}
with open(sys.argv[1], "w", encoding="utf-8") as f:
    json.dump(manifest, f, ensure_ascii=False, indent=2)
    f.write("\\n")
PY

# Import the exact official Codex source while the verified bundle is mounted.
"$SOURCE_SCRIPT" "$APP" "$VERSION" "$BUILD" "$DMG_SHA256"

OFFICIAL_SOURCE="$PROJECT_ROOT/artifacts/upstream/codex-rust-v$(
  "$APP/Contents/Resources/codex" --version | awk '{print $2}'
)"
FULL_REVERSE="$PROJECT_ROOT/artifacts/full-reverse-$VERSION"
python3 "$FULL_REVERSE_SCRIPT" \
  --app "$APP" \
  --asar-root "$DEST" \
  --official-source "$OFFICIAL_SOURCE" \
  --output "$FULL_REVERSE" \
  --version "$VERSION" \
  --build "$BUILD"
[[ -f "$FULL_REVERSE/full-reverse-manifest.json" ]] || {
  echo "Full reverse manifest missing for $VERSION" >&2
  exit 70
}

# Release this mount before the protocol generator independently verifies and
# mounts the same official DMG.
cleanup_mount

"$PROTOCOL_SCRIPT" "$DMG"
[[ -f "$PROJECT_ROOT/versions/$VERSION/protocol/index.json" ]] || {
  echo "Protocol snapshot missing for $VERSION" >&2
  exit 70
}
[[ -f "$PROJECT_ROOT/versions/$VERSION/official-source.json" ]] || {
  echo "Official source provenance missing for $VERSION" >&2
  exit 70
}

VERSION_ROOT="$PROJECT_ROOT/versions/$VERSION"
mkdir -p "$VERSION_ROOT/electron" "$VERSION_ROOT/visual"
python3 "$IPC_SCRIPT" \
  --asar-root "$DEST" \
  --version "$VERSION" \
  --output "$VERSION_ROOT/electron/ipc-inventory.json"
python3 "$VISUAL_SCRIPT" \
  --webview-root "$DEST/webview" \
  --version "$VERSION" \
  --output "$VERSION_ROOT/visual/reference-inventory.json"
python3 "$BUNDLE_SCRIPT" \
  --asar-root "$DEST" \
  --expected-version "$VERSION" \
  --output "$VERSION_ROOT/electron/bundle-index.json"
python3 "$SURFACE_MANIFEST_SCRIPT" \
  --webview-root "$FULL_REVERSE/app-asar/webview" \
  --preload "$FULL_REVERSE/recovered-electron-source/.vite/build/preload.js" \
  --desktop-version "$VERSION" \
  --desktop-build "$BUILD" \
  --output "$VERSION_ROOT/desktop-surface-manifest.json"
SURFACE_TREE_SHA256="$(
  python3 -c \
    'import json,sys; print(json.load(open(sys.argv[1], encoding="utf-8"))["resourceTreeSha256"])' \
    "$VERSION_ROOT/desktop-surface-manifest.json"
)"
RECOVERED_SOURCE_INDEX_SHA256="$(
  python3 -c \
    'import json,sys; print(json.load(open(sys.argv[1], encoding="utf-8"))["recoveredSourceIndexSha256"])' \
    "$FULL_REVERSE/full-reverse-manifest.json"
)"
python3 "$INTERACTION_INVENTORY_SCRIPT" \
  --recovered-root "$FULL_REVERSE/recovered-electron-source" \
  --desktop-version "$VERSION" \
  --desktop-build "$BUILD" \
  --desktop-surface-tree-sha256 "$SURFACE_TREE_SHA256" \
  --output "$VERSION_ROOT/desktop-interaction-inventory.json"
python3 "$UI_PARITY_SCRIPT" \
  --recovered-root "$FULL_REVERSE/recovered-electron-source" \
  --desktop-version "$VERSION" \
  --desktop-build "$BUILD" \
  --source-dmg-sha256 "$DMG_SHA256" \
  --desktop-surface-tree-sha256 "$SURFACE_TREE_SHA256" \
  --recovered-source-index-sha256 "$RECOVERED_SOURCE_INDEX_SHA256" \
  --output "$VERSION_ROOT/desktop-ui-parity.json"
python3 "$FEATURE_SCRIPT" \
  --version "$VERSION" \
  --protocol-index "$VERSION_ROOT/protocol/index.json" \
  --ipc-inventory "$VERSION_ROOT/electron/ipc-inventory.json" \
  --visual-inventory "$VERSION_ROOT/visual/reference-inventory.json" \
  --output "$VERSION_ROOT/feature-inventory.json"
python3 "$FEATURE_EVIDENCE_SCRIPT" \
  --project-root "$PROJECT_ROOT" \
  --inventory "$VERSION_ROOT/feature-inventory.json"

IMPORT_SUCCEEDED=true
echo "Imported $VERSION ($BUILD)"
echo "Source: $DEST"
echo "Manifest: $ARTIFACTS/manifest-$VERSION.json"
