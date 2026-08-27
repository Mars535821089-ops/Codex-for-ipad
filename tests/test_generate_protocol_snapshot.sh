#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/codex-protocol-test.XXXXXX")"
FAIL_SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/codex-protocol-fail.XXXXXX")"

cleanup() {
  python3 - "$SANDBOX" "$FAIL_SANDBOX" <<'PY'
from pathlib import Path
import shutil
import sys

for raw in sys.argv[1:]:
    path = Path(raw)
    if path.name.startswith(("codex-protocol-test.", "codex-protocol-fail.")):
        shutil.rmtree(path, ignore_errors=True)
PY
}
trap cleanup EXIT

make_fake_app() {
  local root="$1"
  local version="$2"
  local fail_experimental="${3:-false}"
  local app="$root/Fake.app"
  mkdir -p "$app/Contents/Resources"
  cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleShortVersionString</key><string>$version</string>
<key>CFBundleVersion</key><string>7</string>
</dict></plist>
PLIST
  cat > "$app/Contents/Resources/codex" <<SH
#!/usr/bin/env bash
set -euo pipefail
if [[ "\${1:-}" == "--version" ]]; then
  echo "codex-cli 9.9.9"
  exit 0
fi
kind="\${2:-}"
out=""
experimental=false
while [[ \$# -gt 0 ]]; do
  if [[ "\$1" == "--out" ]]; then
    out="\$2"
    shift 2
    continue
  fi
  [[ "\$1" == "--experimental" ]] && experimental=true
  shift
done
if [[ "$fail_experimental" == "true" && "\$kind" == "generate-json-schema" && "\$experimental" == "true" ]]; then
  exit 42
fi
mkdir -p "\$out"
if [[ "\$kind" == "generate-ts" ]]; then
  printf 'export type Protocol = { experimental: %s };\\n' "\$experimental" > "\$out/Protocol.ts"
else
  printf '{"type":"object","experimental":%s}\\n' "\$experimental" > "\$out/Protocol.json"
fi
SH
  chmod +x "$app/Contents/Resources/codex"
  touch "$root/Fake.dmg"
}

make_fake_app "$SANDBOX" "99.1.0"

(
  cd "${TMPDIR:-/tmp}"
  CODEX_PROTOCOL_APP_OVERRIDE="$SANDBOX/Fake.app" \
  CODEX_PROTOCOL_VERSIONS_ROOT="$SANDBOX/versions" \
    "$ROOT/scripts/generate_protocol_snapshot.sh" "$SANDBOX/Fake.dmg"
)

test -f "$SANDBOX/versions/99.1.0/protocol/index.json"
test -f "$SANDBOX/versions/99.1.0/protocol/typescript/stable/Protocol.ts"
test -f "$SANDBOX/versions/99.1.0/protocol/typescript/experimental/Protocol.ts"
test -f "$SANDBOX/versions/99.1.0/protocol/json-schema/stable/Protocol.json"
test -f "$SANDBOX/versions/99.1.0/protocol/json-schema/experimental/Protocol.json"
grep -q '"cliVersion": "9.9.9"' "$SANDBOX/versions/99.1.0/provenance.json"

before="$(shasum -a 256 "$SANDBOX/versions/99.1.0/protocol/index.json" | awk '{print $1}')"
CODEX_PROTOCOL_APP_OVERRIDE="$SANDBOX/Fake.app" \
CODEX_PROTOCOL_VERSIONS_ROOT="$SANDBOX/versions" \
  "$ROOT/scripts/generate_protocol_snapshot.sh" "$SANDBOX/Fake.dmg"
after="$(shasum -a 256 "$SANDBOX/versions/99.1.0/protocol/index.json" | awk '{print $1}')"
test "$before" = "$after"

make_fake_app "$SANDBOX" "99.1.1"
mkdir -p "$SANDBOX/versions/99.1.1/app-icons"
printf '{"sourceCommit":"fixture"}\n' \
  > "$SANDBOX/versions/99.1.1/official-source.json"
printf 'fixture-icon\n' \
  > "$SANDBOX/versions/99.1.1/app-icons/icon.png"
CODEX_PROTOCOL_APP_OVERRIDE="$SANDBOX/Fake.app" \
CODEX_PROTOCOL_VERSIONS_ROOT="$SANDBOX/versions" \
  "$ROOT/scripts/generate_protocol_snapshot.sh" "$SANDBOX/Fake.dmg"
test -f "$SANDBOX/versions/99.1.1/manifest.json"
test -f "$SANDBOX/versions/99.1.1/protocol/index.json"
grep -q '"sourceCommit":"fixture"' \
  "$SANDBOX/versions/99.1.1/official-source.json"
grep -q 'fixture-icon' \
  "$SANDBOX/versions/99.1.1/app-icons/icon.png"

make_fake_app "$FAIL_SANDBOX" "99.2.0" true
set +e
CODEX_PROTOCOL_APP_OVERRIDE="$FAIL_SANDBOX/Fake.app" \
CODEX_PROTOCOL_VERSIONS_ROOT="$FAIL_SANDBOX/versions" \
  "$ROOT/scripts/generate_protocol_snapshot.sh" "$FAIL_SANDBOX/Fake.dmg"
rc=$?
set -e
test "$rc" -eq 42
test ! -e "$FAIL_SANDBOX/versions/99.2.0"
test -n "$(find "$FAIL_SANDBOX/versions" -maxdepth 1 -type d -name '.staging-99.2.0-*' -print -quit)"

echo "protocol snapshot fixture PASS"
