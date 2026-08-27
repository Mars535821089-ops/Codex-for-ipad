#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 /path/to/version/app-icons" >&2
  exit 64
fi

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE="$1"
DEST="$PROJECT_ROOT/CodexPad/CodexPad/Resources/Assets.xcassets/AppIcon.appiconset"
LIGHT="$SOURCE/icon-codex-light.png"
DARK="$SOURCE/icon-codex-dark-color.png"

[[ -f "$LIGHT" && -f "$DARK" ]] || {
  echo "Official Codex icon pair is incomplete: $SOURCE" >&2
  exit 66
}

STAGE="$(mktemp -d "$PROJECT_ROOT/build/.codex-app-icon.XXXXXX")"
cleanup() {
  rm -rf "$STAGE"
}
trap cleanup EXIT

# The official desktop PNGs contain alpha. iPad app icons must be opaque.
for variant in light dark; do
  if [[ "$variant" == "light" ]]; then
    input="$LIGHT"
    output="AppIcon.png"
  else
    input="$DARK"
    output="AppIcon-dark.png"
  fi
  sips -s format jpeg -s formatOptions 100 "$input" \
    --out "$STAGE/$variant.jpg" >/dev/null
  sips -s format png "$STAGE/$variant.jpg" \
    --out "$STAGE/$output" >/dev/null
done
rm -f "$STAGE/light.jpg" "$STAGE/dark.jpg"

cat > "$STAGE/Contents.json" <<'JSON'
{
  "images" : [
    {
      "filename" : "AppIcon.png",
      "idiom" : "universal",
      "platform" : "ios",
      "size" : "1024x1024"
    },
    {
      "appearances" : [
        {
          "appearance" : "luminosity",
          "value" : "dark"
        }
      ],
      "filename" : "AppIcon-dark.png",
      "idiom" : "universal",
      "platform" : "ios",
      "size" : "1024x1024"
    }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
JSON

rm -rf "$DEST"
mv "$STAGE" "$DEST"
trap - EXIT
echo "Synchronized official Codex iPad app icon"
