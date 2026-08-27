#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
MANIFEST="$ROOT/CodexCore/Cargo.toml"
HEADERS="$ROOT/CodexCore/include"
BUILD_ROOT="$ROOT/build"
STAGING="$BUILD_ROOT/.codex-core-xcframework-$$"
NEW_FRAMEWORK="$STAGING/new/CodexCore.xcframework"
PREVIOUS_FRAMEWORK="$STAGING/previous/CodexCore.xcframework"
FINAL_FRAMEWORK="$BUILD_ROOT/CodexCore.xcframework"
SIMULATOR_LIBRARY="$STAGING/libcodex_core-simulator.a"
IOS_DEPLOYMENT_TARGET="18.0"
SUCCESS=0

cleanup() {
  local exit_status=$?

  if [[ "$SUCCESS" -ne 1 && -d "$PREVIOUS_FRAMEWORK" ]]; then
    if [[ -e "$FINAL_FRAMEWORK" ]]; then
      /usr/bin/python3 - "$FINAL_FRAMEWORK" <<'PY'
import shutil
import sys

shutil.rmtree(sys.argv[1])
PY
    fi
    mkdir -p "$(dirname "$FINAL_FRAMEWORK")"
    mv "$PREVIOUS_FRAMEWORK" "$FINAL_FRAMEWORK"
  fi

  if [[ -d "$STAGING" ]]; then
    /usr/bin/python3 - "$STAGING" <<'PY'
import shutil
import sys

shutil.rmtree(sys.argv[1])
PY
  fi

  exit "$exit_status"
}
trap cleanup EXIT

for command in rustup cargo lipo xcodebuild; do
  if ! command -v "$command" >/dev/null 2>&1; then
    echo "missing required command: $command" >&2
    exit 1
  fi
done

if [[ ! -f "$MANIFEST" || ! -f "$HEADERS/codex_core.h" || ! -f "$HEADERS/module.modulemap" ]]; then
  echo "CodexCore manifest or public headers are missing" >&2
  exit 1
fi

targets=(
  aarch64-apple-ios
  aarch64-apple-ios-sim
  x86_64-apple-ios
)
installed_targets="$(rustup target list --installed)"
for target in "${targets[@]}"; do
  if ! grep -qx "$target" <<<"$installed_targets"; then
    echo "missing Rust target: $target" >&2
    echo "install with: rustup target add $target" >&2
    exit 1
  fi
done

mkdir -p "$STAGING/new" "$STAGING/previous"

for target in "${targets[@]}"; do
  IPHONEOS_DEPLOYMENT_TARGET="$IOS_DEPLOYMENT_TARGET" \
    cargo build --locked --release --manifest-path "$MANIFEST" --target "$target"
done

lipo -create \
  "$ROOT/CodexCore/target/aarch64-apple-ios-sim/release/libcodex_core.a" \
  "$ROOT/CodexCore/target/x86_64-apple-ios/release/libcodex_core.a" \
  -output "$SIMULATOR_LIBRARY"

xcodebuild -create-xcframework \
  -library "$SIMULATOR_LIBRARY" \
  -headers "$HEADERS" \
  -library "$ROOT/CodexCore/target/aarch64-apple-ios/release/libcodex_core.a" \
  -headers "$HEADERS" \
  -output "$NEW_FRAMEWORK"

if [[ ! -f "$NEW_FRAMEWORK/Info.plist" ]]; then
  echo "XCFramework Info.plist was not generated" >&2
  exit 1
fi
/usr/bin/plutil -lint "$NEW_FRAMEWORK/Info.plist" >/dev/null

if [[ -e "$FINAL_FRAMEWORK" ]]; then
  mv "$FINAL_FRAMEWORK" "$PREVIOUS_FRAMEWORK"
fi
mv "$NEW_FRAMEWORK" "$FINAL_FRAMEWORK"
SUCCESS=1

echo "CodexCore XCFramework: $FINAL_FRAMEWORK"
