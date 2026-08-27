#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 /absolute/path/to/ChatGPT.dmg" >&2
  exit 64
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
DMG="$1"

[[ -f "$DMG" ]] || {
  echo "DMG not found: $DMG" >&2
  exit 66
}

for command in python3 rustup cargo xcodebuild hdiutil npm maturin; do
  command -v "$command" >/dev/null 2>&1 || {
    echo "missing required command: $command" >&2
    exit 69
  }
done

rustup target add   aarch64-apple-ios   aarch64-apple-ios-sim   x86_64-apple-ios

"$ROOT/scripts/import_dmg.sh" "$DMG"

if [[ ! -f "$ROOT/CodexPad/Vendor/Python.xcframework/Info.plist" ]]; then
  python3 "$ROOT/scripts/fetch_python_apple_runtime.py"     --vendor-root "$ROOT/CodexPad/Vendor"
fi

python3 "$ROOT/scripts/vendor_python_mcp_packages.py" --build
"$ROOT/scripts/build_codex_core_xcframework.sh"

IDENTITY="$(
  python3 - "$ROOT/artifacts" <<'PY'
import json
from pathlib import Path
import sys

records = []
for path in Path(sys.argv[1]).glob("manifest-*.json"):
    try:
        record = json.loads(path.read_text(encoding="utf-8"))
        records.append((path.stat().st_mtime_ns, record))
    except (OSError, ValueError, KeyError):
        pass
if not records:
    raise SystemExit("no imported desktop manifest found")
record = max(records, key=lambda item: item[0])[1]
print(record["version"], record["build"])
PY
)"
read -r VERSION BUILD <<<"$IDENTITY"

python3 "$ROOT/scripts/generate_codexpad_xcode_project.py"   --project-root "$ROOT"   --desktop-version "$VERSION"   --desktop-build "$BUILD"

echo
echo "Prepared Codex for ipad $VERSION ($BUILD)"
echo "Next: open $ROOT/CodexPad/CodexPad.xcodeproj"
echo "Select your Personal Team and a unique Bundle Identifier in Xcode."
