#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 /absolute/path/ChatGPT.dmg" >&2
  exit 64
fi

DMG="$1"
[[ "$DMG" == /* ]] || {
  echo "DMG path must be absolute: $DMG" >&2
  exit 64
}
[[ -f "$DMG" ]] || {
  echo "DMG not found: $DMG" >&2
  exit 66
}

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSIONS_ROOT="${CODEX_PROTOCOL_VERSIONS_ROOT:-$PROJECT_ROOT/versions}"
APP_OVERRIDE="${CODEX_PROTOCOL_APP_OVERRIDE:-}"
INDEX_SCRIPT="$PROJECT_ROOT/scripts/build_protocol_index.py"
PYTHON="${PYTHON:-python3}"
export PYTHONPATH="$PROJECT_ROOT${PYTHONPATH:+:$PYTHONPATH}"

mkdir -p "$VERSIONS_ROOT"

ATTACH_PLIST=""
MOUNT_POINT=""
APP=""
SIGNATURE_VERIFIED=false
GATEKEEPER_ACCEPTED=false
SOURCE_VERIFICATION="official"

detach_image() {
  if [[ -n "$MOUNT_POINT" ]]; then
    hdiutil detach "$MOUNT_POINT" >/dev/null 2>&1 || true
  fi
  if [[ -n "$ATTACH_PLIST" && -f "$ATTACH_PLIST" ]]; then
    unlink "$ATTACH_PLIST" 2>/dev/null || true
  fi
}
trap detach_image EXIT

if [[ -n "$APP_OVERRIDE" ]]; then
  [[ "$APP_OVERRIDE" == /* ]] || {
    echo "CODEX_PROTOCOL_APP_OVERRIDE must be absolute" >&2
    exit 64
  }
  [[ -d "$APP_OVERRIDE" ]] || {
    echo "Fixture app not found: $APP_OVERRIDE" >&2
    exit 66
  }
  APP="$APP_OVERRIDE"
  SOURCE_VERIFICATION="fixture"
else
  hdiutil verify "$DMG" >/dev/null
  ATTACH_PLIST="$(mktemp "${TMPDIR:-/tmp}/codex-protocol-attach.XXXXXX")"
  hdiutil attach -readonly -nobrowse -plist "$DMG" > "$ATTACH_PLIST"
  MOUNT_POINT="$(
    plutil -extract system-entities xml1 -o - "$ATTACH_PLIST" |
      plutil -convert json -o - - |
      "$PYTHON" -c 'import json,sys; print(next(x["mount-point"] for x in json.load(sys.stdin) if "mount-point" in x))'
  )"

  APP_COUNT="$(find "$MOUNT_POINT" -maxdepth 2 -name '*.app' -type d | wc -l | tr -d ' ')"
  [[ "$APP_COUNT" == "1" ]] || {
    echo "Expected exactly one app in DMG, found $APP_COUNT" >&2
    exit 65
  }
  APP="$(find "$MOUNT_POINT" -maxdepth 2 -name '*.app' -type d -print -quit)"
  codesign --verify --deep --strict --verbose=2 "$APP"
  SIGNATURE_VERIFIED=true
  spctl --assess --type execute --verbose=2 "$APP"
  GATEKEEPER_ACCEPTED=true
fi

INFO="$APP/Contents/Info.plist"
CODEX="$APP/Contents/Resources/codex"
[[ -f "$INFO" ]] || {
  echo "Info.plist missing: $INFO" >&2
  exit 65
}
[[ -x "$CODEX" ]] || {
  echo "Embedded Codex CLI missing or not executable: $CODEX" >&2
  exit 65
}

VERSION="$(plutil -extract CFBundleShortVersionString raw -o - "$INFO")"
BUILD="$(plutil -extract CFBundleVersion raw -o - "$INFO")"
"$PYTHON" - "$VERSION" <<'PY'
from scripts.protocol_manifest import validate_version
import sys

validate_version(sys.argv[1])
PY

CLI_VERSION_RAW="$("$CODEX" --version)"
CLI_VERSION="${CLI_VERSION_RAW#codex-cli }"
[[ -n "$CLI_VERSION" ]] || {
  echo "Embedded Codex CLI returned an empty version" >&2
  exit 65
}

DMG_SHA256="$(shasum -a 256 "$DMG" | awk '{print $1}')"
DESTINATION="$VERSIONS_ROOT/$VERSION"
STAGE="$VERSIONS_ROOT/.staging-$VERSION-$$"
[[ ! -e "$STAGE" ]] || {
  echo "Staging directory already exists: $STAGE" >&2
  exit 73
}
mkdir -p \
  "$STAGE/protocol/typescript/stable" \
  "$STAGE/protocol/typescript/experimental" \
  "$STAGE/protocol/json-schema/stable" \
  "$STAGE/protocol/json-schema/experimental"

"$CODEX" app-server generate-ts \
  --out "$STAGE/protocol/typescript/stable"
"$CODEX" app-server generate-ts --experimental \
  --out "$STAGE/protocol/typescript/experimental"
"$CODEX" app-server generate-json-schema \
  --out "$STAGE/protocol/json-schema/stable"
"$CODEX" app-server generate-json-schema --experimental \
  --out "$STAGE/protocol/json-schema/experimental"

"$PYTHON" "$PROJECT_ROOT/scripts/canonicalize_json.py" \
  "$STAGE/protocol/json-schema"

for output in \
  "$STAGE/protocol/typescript/stable" \
  "$STAGE/protocol/typescript/experimental" \
  "$STAGE/protocol/json-schema/stable" \
  "$STAGE/protocol/json-schema/experimental"
do
  [[ -n "$(find "$output" -type f -print -quit)" ]] || {
    echo "Generated protocol output is empty: $output" >&2
    exit 70
  }
done

"$PYTHON" "$INDEX_SCRIPT" \
  --protocol-root "$STAGE/protocol" \
  --output "$STAGE/protocol/index.json"
PROTOCOL_INDEX_SHA256="$(
  shasum -a 256 "$STAGE/protocol/index.json" | awk '{print $1}'
)"

GENERATED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
"$PYTHON" - \
  "$STAGE/manifest.json" \
  "$STAGE/provenance.json" \
  "$VERSION" \
  "$BUILD" \
  "$CLI_VERSION" \
  "$DMG" \
  "$DMG_SHA256" \
  "$PROTOCOL_INDEX_SHA256" \
  "$SIGNATURE_VERIFIED" \
  "$GATEKEEPER_ACCEPTED" \
  "$SOURCE_VERIFICATION" \
  "$GENERATED_AT" <<'PY'
from pathlib import Path
import sys

from scripts.protocol_manifest import write_json_atomic

(
    manifest_path,
    provenance_path,
    version,
    build,
    cli_version,
    dmg_path,
    dmg_sha256,
    protocol_index_sha256,
    signature_verified,
    gatekeeper_accepted,
    source_verification,
    generated_at,
) = sys.argv[1:]

write_json_atomic(
    Path(manifest_path),
    {
        "schemaVersion": 1,
        "version": version,
        "build": build,
        "cliVersion": cli_version,
        "dmgSha256": dmg_sha256,
        "protocolIndexSha256": protocol_index_sha256,
        "signatureVerified": signature_verified == "true",
        "gatekeeperAccepted": gatekeeper_accepted == "true",
    },
)
write_json_atomic(
    Path(provenance_path),
    {
        "schemaVersion": 1,
        "version": version,
        "build": build,
        "cliVersion": cli_version,
        "sourceDmg": dmg_path,
        "dmgSha256": dmg_sha256,
        "sourceVerification": source_verification,
        "signatureVerified": signature_verified == "true",
        "gatekeeperAccepted": gatekeeper_accepted == "true",
        "generatedAt": generated_at,
        "generator": "scripts/generate_protocol_snapshot.sh",
        "commands": [
            "codex app-server generate-ts --out DIR",
            "codex app-server generate-ts --experimental --out DIR",
            "codex app-server generate-json-schema --out DIR",
            "codex app-server generate-json-schema --experimental --out DIR",
        ],
    },
)
PY

if [[ -d "$DESTINATION" && ! -f "$DESTINATION/manifest.json" ]]; then
  "$PYTHON" - "$DESTINATION" "$STAGE" <<'PY'
from pathlib import Path
import shutil
import sys

destination = Path(sys.argv[1])
stage = Path(sys.argv[2])
allowed = {"official-source.json", "app-icons"}
unexpected = sorted(child.name for child in destination.iterdir() if child.name not in allowed)
if unexpected:
    raise SystemExit(
        "incomplete published version contains unexpected entries: "
        + ", ".join(unexpected)
    )
for child in list(destination.iterdir()):
    target = stage / child.name
    if target.exists():
        raise SystemExit(f"staging collision while merging {child.name}")
    shutil.move(str(child), str(target))
destination.rmdir()
PY
fi

if [[ -e "$DESTINATION" ]]; then
  [[ -f "$DESTINATION/manifest.json" ]] || {
    echo "Published version has no manifest: $DESTINATION" >&2
    exit 73
  }
  "$PYTHON" - "$DESTINATION/manifest.json" "$STAGE/manifest.json" <<'PY'
import json
import sys
from pathlib import Path

keys = ("dmgSha256", "build", "cliVersion", "protocolIndexSha256")
old = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
new = json.loads(Path(sys.argv[2]).read_text(encoding="utf-8"))
different = [key for key in keys if old.get(key) != new.get(key)]
if different:
    raise SystemExit(
        "published protocol source differs for: " + ", ".join(different)
    )
PY
  "$PYTHON" - "$STAGE" <<'PY'
from pathlib import Path
import shutil
import sys

stage = Path(sys.argv[1])
if stage.name.startswith(".staging-") and stage.parent.name == "versions":
    shutil.rmtree(stage)
elif stage.name.startswith(".staging-"):
    shutil.rmtree(stage)
else:
    raise SystemExit(f"refusing to remove unexpected staging path: {stage}")
PY
  echo "version=$VERSION"
  echo "build=$BUILD"
  echo "cli=$CLI_VERSION"
  echo "published=$DESTINATION (identical)"
  exit 0
fi

mv "$STAGE" "$DESTINATION"

echo "version=$VERSION"
echo "build=$BUILD"
echo "cli=$CLI_VERSION"
echo "signature_verified=$SIGNATURE_VERIFIED"
echo "gatekeeper_accepted=$GATEKEEPER_ACCEPTED"
echo "published=$DESTINATION"
