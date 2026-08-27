#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 4 ]]; then
  echo "usage: $0 /path/to/ChatGPT.app DESKTOP_VERSION DESKTOP_BUILD DMG_SHA256" >&2
  exit 64
fi

APP="$1"
DESKTOP_VERSION="$2"
DESKTOP_BUILD="$3"
DMG_SHA256="$4"
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DOWNLOAD_ROOT="$PROJECT_ROOT/.downloads"
UPSTREAM_ROOT="$PROJECT_ROOT/artifacts/upstream"
CODEX_BINARY="$APP/Contents/Resources/codex"
CACHE_HELPER="$PROJECT_ROOT/scripts/official_source_cache.py"

[[ -x "$CODEX_BINARY" ]] || {
  echo "Embedded Codex executable missing: $CODEX_BINARY" >&2
  exit 66
}
[[ "$DMG_SHA256" =~ ^[0-9a-f]{64}$ ]] || {
  echo "DMG SHA-256 is malformed" >&2
  exit 65
}

CLI_VERSION="$("$CODEX_BINARY" --version | awk '{print $2}')"
[[ "$CLI_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]] || {
  echo "Unexpected embedded Codex version: $CLI_VERSION" >&2
  exit 65
}
TAG="rust-v$CLI_VERSION"
SOURCE_COMMIT="$(
  git ls-remote https://github.com/openai/codex.git \
    "refs/tags/$TAG" "refs/tags/$TAG^{}" |
    awk 'END {print $1}'
)"
[[ "$SOURCE_COMMIT" =~ ^[0-9a-f]{40}$ ]] || {
  echo "Official source tag not found: $TAG" >&2
  exit 69
}

mkdir -p \
  "$DOWNLOAD_ROOT" \
  "$UPSTREAM_ROOT" \
  "$PROJECT_ROOT/versions/$DESKTOP_VERSION"
ICON_SOURCE="$PROJECT_ROOT/versions/$DESKTOP_VERSION/app-icons"
mkdir -p "$ICON_SOURCE"
cp "$APP/Contents/Resources/icon-codex-light.png" \
  "$ICON_SOURCE/icon-codex-light.png"
cp "$APP/Contents/Resources/icon-codex-dark-color.png" \
  "$ICON_SOURCE/icon-codex-dark-color.png"
DEST="$UPSTREAM_ROOT/codex-$TAG"
ARCHIVE="$DOWNLOAD_ROOT/codex-$TAG.tar.gz"
PART="$ARCHIVE.part"

if [[ ! -d "$DEST" ]]; then
  curl --fail --location --retry 3 \
    --output "$PART" \
    "https://codeload.github.com/openai/codex/tar.gz/refs/tags/$TAG"
  mv "$PART" "$ARCHIVE"
  tar -tzf "$ARCHIVE" >/dev/null
  SOURCE_ARCHIVE_SHA256="$(shasum -a 256 "$ARCHIVE" | awk '{print $1}')"
  STAGE="$(mktemp -d "$UPSTREAM_ROOT/.codex-source.XXXXXX")"
  cleanup_stage() {
    rm -rf "$STAGE"
  }
  trap cleanup_stage EXIT
  tar -xzf "$ARCHIVE" --strip-components=1 -C "$STAGE"
  [[ -f "$STAGE/codex-rs/Cargo.toml" ]] || {
    echo "Official Codex source archive is incomplete" >&2
    exit 65
  }
  mv "$STAGE" "$DEST"
  trap - EXIT
  SOURCE_CACHE_JSON="$(
    python3 "$CACHE_HELPER" write \
      --root "$DEST" \
      --tag "$TAG" \
      --commit "$SOURCE_COMMIT" \
      --archive-sha256 "$SOURCE_ARCHIVE_SHA256"
  )"
else
  SOURCE_CACHE_JSON="$(
    python3 "$CACHE_HELPER" verify \
      --root "$DEST" \
      --tag "$TAG" \
      --commit "$SOURCE_COMMIT"
  )"
  echo "Verified cached official Codex source: $DEST"
fi

SOURCE_ARCHIVE_SHA256="$(
  python3 -c \
    'import json,sys; print(json.loads(sys.argv[1])["sourceArchiveSha256"])' \
    "$SOURCE_CACHE_JSON"
)"
SOURCE_TREE_SHA256="$(
  python3 -c \
    'import json,sys; print(json.loads(sys.argv[1])["treeSha256"])' \
    "$SOURCE_CACHE_JSON"
)"
if [[ ! "$SOURCE_ARCHIVE_SHA256" =~ ^[0-9a-f]{64}$ ]]; then
  echo "Official source archive hash is malformed" >&2
  exit 70
fi
if [[ ! "$SOURCE_TREE_SHA256" =~ ^[0-9a-f]{64}$ ]]; then
  echo "Official source tree hash is malformed" >&2
  exit 70
fi
CODEX_SHA256="$(shasum -a 256 "$CODEX_BINARY" | awk '{print $1}')"
RUST_TOOLCHAIN="$(
  awk -F'"' '/^channel = "/ {print $2; exit}' \
    "$PROJECT_ROOT/rust-toolchain.toml"
)"

python3 - "$PROJECT_ROOT/versions/$DESKTOP_VERSION/official-source.json" <<PY
import json
import sys

record = {
    "schemaVersion": 1,
    "desktopVersion": "$DESKTOP_VERSION",
    "desktopBuild": "$DESKTOP_BUILD",
    "dmgSha256": "$DMG_SHA256",
    "embeddedCliVersion": "$CLI_VERSION",
    "embeddedCliSha256": "$CODEX_SHA256",
    "sourceRepository": "https://github.com/openai/codex",
    "sourceTag": "$TAG",
    "sourceCommit": "$SOURCE_COMMIT",
    "sourceArchiveSha256": "$SOURCE_ARCHIVE_SHA256",
    "sourceTreeSha256": "$SOURCE_TREE_SHA256",
    "iosNetworkCrate": "codex-api",
    "rustToolchain": "$RUST_TOOLCHAIN",
}
with open(sys.argv[1], "w", encoding="utf-8") as handle:
    json.dump(record, handle, ensure_ascii=False, indent=2)
    handle.write("\\n")
PY

# The extracted source and provenance remain; the redundant transfer files do not.
rm -f "$ARCHIVE" "$PART"
echo "Imported official Codex source $TAG ($SOURCE_COMMIT)"
