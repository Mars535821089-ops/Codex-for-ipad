#!/usr/bin/env bash
set -euo pipefail

SOURCE_ONLY=false
if [[ $# -gt 0 && "$1" == "--source-only" ]]; then
  SOURCE_ONLY=true
  shift
fi
if [[ $# -ne 2 ]]; then
  echo "usage: $0 [--source-only] DESKTOP_VERSION DESKTOP_BUILD" >&2
  exit 64
fi

VERSION="$1"
BUILD="$2"
if [[ ! "$VERSION" =~ ^[0-9]+(\.[0-9]+)+$ ]]; then
  echo "desktop version is malformed: $VERSION" >&2
  exit 64
fi
if [[ ! "$BUILD" =~ ^[0-9]+$ ]]; then
  echo "desktop build is malformed: $BUILD" >&2
  exit 64
fi
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_RECORD="$PROJECT_ROOT/versions/$VERSION/official-source.json"
CARGO_TOML="$PROJECT_ROOT/CodexCore/Cargo.toml"
PROVIDER="$PROJECT_ROOT/CodexCore/src/official_provider.rs"
LOCKFILE="$PROJECT_ROOT/CodexCore/Cargo.lock"
ICON_SOURCE="$PROJECT_ROOT/versions/$VERSION/app-icons"
ICON_DEST="$PROJECT_ROOT/CodexPad/CodexPad/Resources/Assets.xcassets/AppIcon.appiconset"
REPORT="$PROJECT_ROOT/artifacts/ipad-upgrade-$VERSION.json"
MODEL_CATALOG_SCRIPT="$PROJECT_ROOT/scripts/generate_model_catalog.py"
MODEL_SOURCE="$PROJECT_ROOT/artifacts/full-reverse-$VERSION/official-codex-source/codex-rs/models-manager/models.json"
MODEL_JSON="$PROJECT_ROOT/versions/$VERSION/model-catalog.json"
MODEL_SWIFT="$PROJECT_ROOT/CodexPad/CodexPad/Domain/CodexModelCatalog.generated.swift"
MODEL_RUST_JSON="$PROJECT_ROOT/CodexCore/resources/models.json"
OFFICIAL_CARGO_TOML="$PROJECT_ROOT/artifacts/full-reverse-$VERSION/official-codex-source/codex-rs/Cargo.toml"
MODEL_CLIENT_VERSION="$PROJECT_ROOT/CodexCore/resources/client-version.txt"
BUILD_METADATA_SCRIPT="$PROJECT_ROOT/scripts/generate_build_metadata.py"
BUILD_METADATA_SWIFT="$PROJECT_ROOT/CodexPad/CodexPad/Domain/CodexBuildMetadata.generated.swift"
FEATURE_CATALOG_SCRIPT="$PROJECT_ROOT/scripts/generate_experimental_feature_catalog.py"
FEATURE_SOURCE="$PROJECT_ROOT/artifacts/full-reverse-$VERSION/official-codex-source/codex-rs/features/src/lib.rs"
FEATURE_SWIFT="$PROJECT_ROOT/CodexPad/CodexPad/Application/CodexExperimentalFeatureCatalog.generated.swift"
SKILL_SYNC_SCRIPT="$PROJECT_ROOT/scripts/sync_official_recommended_skills.py"
SKILL_SOURCE="$PROJECT_ROOT/artifacts/full-reverse-$VERSION/bundle-resources/skills"
SKILL_DEST="$PROJECT_ROOT/CodexPad/CodexPad/Application/Resources/skills"

[[ -f "$SOURCE_RECORD" ]] || {
  echo "Official source provenance missing: $SOURCE_RECORD" >&2
  exit 66
}
SOURCE_COMMIT="$(
  python3 - "$SOURCE_RECORD" "$VERSION" "$BUILD" <<'PY'
import json
import re
import sys

path, expected_version, expected_build = sys.argv[1:]
with open(path, encoding="utf-8") as stream:
    record = json.load(stream)
if not isinstance(record, dict):
    raise SystemExit("official source provenance must be a JSON object")
for field, expected in (
    ("desktopVersion", expected_version),
    ("desktopBuild", expected_build),
):
    if record.get(field) != expected:
        raise SystemExit(
            f"official source {field} does not match requested {expected}"
        )
commit = record.get("sourceCommit")
if not isinstance(commit, str) or re.fullmatch(r"[0-9a-f]{40}", commit) is None:
    raise SystemExit("official source commit is malformed")
print(commit)
PY
)"
[[ "$SOURCE_COMMIT" =~ ^[0-9a-f]{40}$ ]] || exit 65

BACKUP="$(mktemp -d)"
cp "$CARGO_TOML" "$BACKUP/Cargo.toml"
cp "$PROVIDER" "$BACKUP/official_provider.rs"
cp "$LOCKFILE" "$BACKUP/Cargo.lock"
if [[ -f "$MODEL_SWIFT" ]]; then
  cp "$MODEL_SWIFT" "$BACKUP/CodexModelCatalog.generated.swift"
fi
if [[ -f "$MODEL_JSON" ]]; then
  cp "$MODEL_JSON" "$BACKUP/model-catalog.json"
fi
if [[ -f "$MODEL_RUST_JSON" ]]; then
  cp "$MODEL_RUST_JSON" "$BACKUP/models.json"
fi
if [[ -f "$MODEL_CLIENT_VERSION" ]]; then
  cp "$MODEL_CLIENT_VERSION" "$BACKUP/client-version.txt"
fi
if [[ -f "$BUILD_METADATA_SWIFT" ]]; then
  cp "$BUILD_METADATA_SWIFT" "$BACKUP/CodexBuildMetadata.generated.swift"
fi
if [[ -f "$FEATURE_SWIFT" ]]; then
  cp "$FEATURE_SWIFT" "$BACKUP/CodexExperimentalFeatureCatalog.generated.swift"
fi
if [[ -d "$ICON_DEST" ]]; then
  cp -R "$ICON_DEST" "$BACKUP/AppIcon.appiconset"
fi
if [[ -d "$SKILL_DEST" ]]; then
  cp -R "$SKILL_DEST" "$BACKUP/recommended-skills"
fi
restore_on_failure() {
  status=$?
  if [[ $status -ne 0 ]]; then
    cp "$BACKUP/Cargo.toml" "$CARGO_TOML"
    cp "$BACKUP/official_provider.rs" "$PROVIDER"
    cp "$BACKUP/Cargo.lock" "$LOCKFILE"
    if [[ -f "$BACKUP/CodexModelCatalog.generated.swift" ]]; then
      cp "$BACKUP/CodexModelCatalog.generated.swift" "$MODEL_SWIFT"
    else
      rm -f "$MODEL_SWIFT"
    fi
    if [[ -f "$BACKUP/model-catalog.json" ]]; then
      cp "$BACKUP/model-catalog.json" "$MODEL_JSON"
    else
      rm -f "$MODEL_JSON"
    fi
    if [[ -f "$BACKUP/models.json" ]]; then
      cp "$BACKUP/models.json" "$MODEL_RUST_JSON"
    else
      rm -f "$MODEL_RUST_JSON"
    fi
    if [[ -f "$BACKUP/client-version.txt" ]]; then
      cp "$BACKUP/client-version.txt" "$MODEL_CLIENT_VERSION"
    else
      rm -f "$MODEL_CLIENT_VERSION"
    fi
    if [[ -f "$BACKUP/CodexBuildMetadata.generated.swift" ]]; then
      cp "$BACKUP/CodexBuildMetadata.generated.swift" "$BUILD_METADATA_SWIFT"
    else
      rm -f "$BUILD_METADATA_SWIFT"
    fi
    if [[ -f "$BACKUP/CodexExperimentalFeatureCatalog.generated.swift" ]]; then
      cp "$BACKUP/CodexExperimentalFeatureCatalog.generated.swift" "$FEATURE_SWIFT"
    else
      rm -f "$FEATURE_SWIFT"
    fi
    if [[ -d "$BACKUP/AppIcon.appiconset" ]]; then
      rm -rf "$ICON_DEST"
      cp -R "$BACKUP/AppIcon.appiconset" "$ICON_DEST"
    else
      rm -rf "$ICON_DEST"
    fi
    if [[ -d "$BACKUP/recommended-skills" ]]; then
      rm -rf "$SKILL_DEST"
      cp -R "$BACKUP/recommended-skills" "$SKILL_DEST"
    else
      rm -rf "$SKILL_DEST"
    fi
  fi
  rm -rf "$BACKUP"
  exit "$status"
}
trap restore_on_failure EXIT

python3 - "$CARGO_TOML" "$PROVIDER" "$SOURCE_COMMIT" <<'PY'
import pathlib
import re
import sys

cargo = pathlib.Path(sys.argv[1])
provider = pathlib.Path(sys.argv[2])
commit = sys.argv[3]

cargo_text = cargo.read_text(encoding="utf-8")
cargo_text, count = re.subn(
    r'(codex-(?:api|protocol|client)\s*=\s*\{[^}]*\brev\s*=\s*")[0-9a-f]{40}(")',
    rf'\g<1>{commit}\2',
    cargo_text,
)
if count != 3:
    raise SystemExit(
        "expected codex-api, codex-client, and codex-protocol revision fields"
    )
cargo.write_text(cargo_text, encoding="utf-8")

provider_text = provider.read_text(encoding="utf-8")
provider_text, count = re.subn(
    r'const OFFICIAL_SOURCE_COMMIT: &str = "[0-9a-f]{40}";',
    f'const OFFICIAL_SOURCE_COMMIT: &str = "{commit}";',
    provider_text,
    count=1,
)
if count != 1:
    raise SystemExit("official provider source commit constant not found")
provider.write_text(provider_text, encoding="utf-8")
PY

[[ -f "$MODEL_SOURCE" ]] || {
  echo "Official model catalog missing: $MODEL_SOURCE" >&2
  exit 66
}
[[ -f "$OFFICIAL_CARGO_TOML" ]] || {
  echo "Official Codex Cargo.toml missing: $OFFICIAL_CARGO_TOML" >&2
  exit 66
}
python3 "$MODEL_CATALOG_SCRIPT" \
  --source "$MODEL_SOURCE" \
  --version "$VERSION" \
  --json-output "$MODEL_JSON" \
  --swift-output "$MODEL_SWIFT" \
  --rust-json-output "$MODEL_RUST_JSON" \
  --official-cargo-toml "$OFFICIAL_CARGO_TOML" \
  --rust-client-version-output "$MODEL_CLIENT_VERSION"
python3 "$BUILD_METADATA_SCRIPT" \
  --source "$SOURCE_RECORD" \
  --swift-output "$BUILD_METADATA_SWIFT"
[[ -f "$FEATURE_SOURCE" ]] || {
  echo "Official experimental feature registry missing: $FEATURE_SOURCE" >&2
  exit 66
}
python3 "$FEATURE_CATALOG_SCRIPT" \
  --source "$FEATURE_SOURCE" \
  --output "$FEATURE_SWIFT"

cargo update --manifest-path "$CARGO_TOML" -p codex-api
if [[ "$SOURCE_ONLY" == "false" ]]; then
  cargo test --locked --manifest-path "$CARGO_TOML"
  cargo check --locked --manifest-path "$CARGO_TOML" --target aarch64-apple-ios
  "$PROJECT_ROOT/scripts/build_codex_core_xcframework.sh"
fi
"$PROJECT_ROOT/scripts/sync_official_app_icon.sh" "$ICON_SOURCE"
python3 "$SKILL_SYNC_SCRIPT" \
  --source "$SKILL_SOURCE" \
  --destination "$SKILL_DEST"
python3 "$PROJECT_ROOT/scripts/generate_codexpad_xcode_project.py" \
  --project-root "$PROJECT_ROOT/CodexPad" \
  --desktop-version "$VERSION" \
  --desktop-build "$BUILD"

if [[ "$SOURCE_ONLY" == "true" ]]; then
  XCFRAMEWORK_REBUILT=False
else
  XCFRAMEWORK_REBUILT=True
fi
python3 - "$REPORT" <<PY
import json
import sys

record = {
    "desktopVersion": "$VERSION",
    "desktopBuild": "$BUILD",
    "sourceCommit": "$SOURCE_COMMIT",
    "modelCatalogGenerated": True,
    "buildMetadataGenerated": True,
    "experimentalFeatureCatalogGenerated": True,
    "recommendedSkillsBundled": True,
    "codexCoreUpgraded": True,
    "sourceIntegrationComplete": True,
    "xcframeworkRebuilt": $XCFRAMEWORK_REBUILT,
}
with open(sys.argv[1], "w", encoding="utf-8") as handle:
    json.dump(record, handle, ensure_ascii=False, indent=2)
    handle.write("\\n")
PY

trap - EXIT
rm -rf "$BACKUP"
if [[ "$SOURCE_ONLY" == "true" ]]; then
  echo "Applied Codex for ipad source integration from desktop $VERSION ($BUILD)"
else
  echo "Applied Codex for ipad upgrade from desktop $VERSION ($BUILD)"
fi
