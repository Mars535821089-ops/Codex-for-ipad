import hashlib
import json
import os
import shutil
import subprocess
import tempfile
import time
import unittest
import re
from pathlib import Path


ROOT = Path(__file__).parents[1]


class UpdaterSandbox:
    version = "26.721.81911"
    build = "5973"

    def __init__(self, temporary: str) -> None:
        self.root = Path(temporary) / "project"
        self.scripts = self.root / "scripts"
        self.bin = self.root / "fake-bin"
        self.state = self.root / "fake-state"
        self.mount = self.root / "mount"
        for directory in (
            self.scripts,
            self.bin,
            self.state,
            self.mount / "Official.app" / "Contents",
        ):
            directory.mkdir(parents=True, exist_ok=True)
        for name in (
            "update_latest.sh",
            "official_curl_transport.sh",
            "official_download_state.py",
            "release_archive.py",
            "release_identity.py",
            "build_desktop_interaction_inventory.py",
            "build_desktop_ui_parity.py",
            "javascript_string_scanner.py",
            "audit_desktop_apphost_api.py",
            "audit_feature_protocol_coverage.py",
            "merge_feature_coverage_evidence.py",
            "protocol_manifest.py",
            "upgrade_transaction.py",
            "ipad_release_gate.py",
            "build_ipad_release.py",
            "ipad_verification_evidence.py",
        ):
            source = ROOT / "scripts" / name
            if source.exists():
                shutil.copy2(source, self.scripts / name)
        self._write_fake_commands()
        self._write_pipeline_scripts()
        self.capture_input = (
            self.root
            / "artifacts"
            / "parity-capture-input"
            / self.version
            / self.build
            / "capture-input.json"
        )
        self.capture_input.parent.mkdir(parents=True, exist_ok=True)
        self.capture_input.write_text(
            json.dumps(
                {
                    "schemaVersion": 1,
                    "desktopVersion": self.version,
                    "desktopBuild": self.build,
                    "surfaces": {},
                }
            )
            + "\n",
            encoding="utf-8",
        )
        self.official_parity_manifest = (
            self.root
            / "artifacts"
            / "parity-runtime"
            / self.version
            / self.build
            / "official"
            / "manifest.json"
        )
        self.ipad_parity_manifest = (
            self.root
            / "artifacts"
            / "parity-runtime"
            / self.version
            / self.build
            / "ipad"
            / "manifest.json"
        )
        for manifest in (
            self.official_parity_manifest,
            self.ipad_parity_manifest,
        ):
            manifest.parent.mkdir(parents=True, exist_ok=True)
            manifest.write_text("{}\n", encoding="utf-8")
        self.environment = {
            **os.environ,
            "PATH": f"{self.bin}:{os.environ['PATH']}",
            "CODEX_DMG_URL": "https://example.invalid/ChatGPT.dmg",
            "FAKE_DOWNLOAD_DIR": str(self.root / ".downloads"),
            "FAKE_MOUNT": str(self.mount),
            "FAKE_STATE": str(self.state),
            "FAKE_VERIFICATION_CACHE": str(
                self.root / "DerivedData/UpdaterVerification"
            ),
            "FAKE_VERSION": self.version,
            "FAKE_BUILD": self.build,
            # Transaction tests exercise the explicit physical-acceptance path.
            "CODEXPAD_RUN_PHYSICAL_ACCEPTANCE": "true",
        }

    def run(self, **environment):
        return subprocess.run(
            [str(self.scripts / "update_latest.sh")],
            cwd=self.root,
            env={**self.environment, **environment},
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=20,
        )

    def _write_executable(self, path: Path, text: str) -> None:
        path.write_text(text, encoding="utf-8")
        path.chmod(0o755)

    def _write_fake_commands(self) -> None:
        self._write_executable(
            self.bin / "curl",
            """#!/usr/bin/env bash
set -euo pipefail
is_head=false
output=""
previous=""
for argument in "$@"; do
  if [[ "$argument" == "--head" ]]; then is_head=true; fi
  if [[ "$previous" == "--output" ]]; then output="$argument"; fi
  previous="$argument"
done
if [[ "$is_head" == "true" ]]; then
  count_file="$FAKE_STATE/head-count"
  count=0
  [[ ! -f "$count_file" ]] || count="$(cat "$count_file")"
  count=$((count + 1))
  printf '%s' "$count" >"$count_file"
  if [[ "${LOG_HEAD_EVENTS:-false}" == "true" ]]; then
    printf 'head-%s\\n' "$count" >>"$FAKE_STATE/pipeline-events"
  fi
  if [[ "${BLOCK_FIRST_HEAD:-false}" == "true" && "$count" -eq 1 ]]; then
    : >"$FAKE_STATE/first-head-ready"
    while [[ ! -f "$FAKE_STATE/release-first-head" ]]; do sleep 0.02; done
    exit 88
  fi
  etag='"current-etag"'
  if [[ -n "${CHANGE_HEAD_AT:-}" && "$count" -ge "$CHANGE_HEAD_AT" ]]; then
    etag='"replacement-etag"'
  fi
  headers="$(printf 'HTTP/1.1 200 OK\\ncontent-length: 8\\netag: %s\\nlast-modified: Thu, 30 Jul 2026 00:00:00 GMT\\n\\n' "$etag")"
  if [[ -n "$output" ]]; then
    printf '%s\\n' "$headers" >"$output"
  else
    printf '%s\\n' "$headers"
  fi
else
  printf '12345678' >"$output"
fi
""",
        )
        self._write_executable(
            self.bin / "hdiutil",
            """#!/usr/bin/env bash
set -euo pipefail
case "$1" in
  verify) exit "${HDIUTIL_VERIFY_EXIT:-0}" ;;
  attach) printf '<plist version="1.0"><dict/></plist>\\n' ;;
  detach) exit 0 ;;
  *) exit 2 ;;
esac
""",
        )
        self._write_executable(
            self.bin / "plutil",
            """#!/usr/bin/env bash
set -euo pipefail
if [[ "$1" == "-extract" && "$2" == "system-entities" ]]; then
  printf '<plist version="1.0"><array/></plist>\\n'
elif [[ "$1" == "-convert" ]]; then
  cat >/dev/null
  printf '[{"mount-point":"%s"}]\\n' "$FAKE_MOUNT"
elif [[ "$1" == "-extract" && "$2" == "CFBundleShortVersionString" ]]; then
  printf '%s\\n' "$FAKE_VERSION"
elif [[ "$1" == "-extract" && "$2" == "CFBundleVersion" ]]; then
  printf '%s\\n' "$FAKE_BUILD"
else
  exit 2
fi
""",
        )
        self._write_executable(
            self.bin / "codesign",
            """#!/usr/bin/env bash
exit "${CODESIGN_EXIT:-0}"
""",
        )
        self._write_executable(
            self.bin / "spctl",
            """#!/usr/bin/env bash
: >"$FAKE_STATE/spctl-called"
exit "${SPCTL_EXIT:-0}"
""",
        )
        self._write_executable(
            self.bin / "git",
            """#!/usr/bin/env bash
set -euo pipefail
if [[ "$1" == "-C" && "$3" == "rev-parse" && "$4" == "HEAD" ]]; then
  printf '8099cb9ce7a3bdf275f670b2c432bbf21cf21a8e\n'
else
  exit 2
fi
""",
        )
        self._write_executable(
            self.bin / "unlink",
            """#!/usr/bin/env bash
set -euo pipefail
if [[ "$#" -eq 1 && "$1" == "$FAKE_DOWNLOAD_DIR/"*.dmg ]]; then
  printf 'delete-transfer\\n' >>"$FAKE_STATE/pipeline-events"
fi
exec /bin/unlink "$@"
""",
        )
        self._write_executable(
            self.bin / "rm",
            """#!/usr/bin/env bash
set -euo pipefail
for argument in "$@"; do
  if [[ "$argument" == "$FAKE_DOWNLOAD_DIR/"*.dmg ]]; then
    printf 'delete-transfer\\n' >>"$FAKE_STATE/pipeline-events"
  fi
  if [[ "$argument" == "$FAKE_VERIFICATION_CACHE" ]]; then
    printf 'delete-verification-cache\\n' >>"$FAKE_STATE/pipeline-events"
  fi
done
exec /bin/rm "$@"
""",
        )

    def _write_pipeline_scripts(self) -> None:
        self._write_executable(
            self.scripts / "capture_official_desktop_parity.sh",
            """#!/usr/bin/env bash
set -euo pipefail
printf 'official-desktop-capture\n' >>"$FAKE_STATE/pipeline-events"
python3 - "$1" "$2" "$3" <<'PY'
import json
import os
from pathlib import Path
import sys
root = Path(os.environ["FAKE_STATE"]).parent
record = {"dmg": sys.argv[1], "version": sys.argv[2], "build": sys.argv[3]}
(Path(os.environ["FAKE_STATE"]) / "official-capture-args.json").write_text(
    json.dumps(record) + "\\n", encoding="utf-8"
)
manifest = root / "artifacts/parity-runtime" / sys.argv[2] / sys.argv[3] / "official/manifest.json"
manifest.parent.mkdir(parents=True, exist_ok=True)
manifest.write_text("{}\\n", encoding="utf-8")
PY
""",
        )
        self._write_executable(
            self.scripts / "assemble_release_parity_capture_input.py",
            """#!/usr/bin/env python3
import json
import os
from pathlib import Path
import sys

arguments = sys.argv[1:]
value = lambda name: arguments[arguments.index(name) + 1]
record = {
    name: value(name)
    for name in (
        "--project-root",
        "--official-manifest",
        "--ipad-manifest",
        "--output",
        "--desktop-version",
        "--desktop-build",
    )
}
for name in ("--official-manifest", "--ipad-manifest"):
    if not Path(record[name]).is_file():
        raise SystemExit(f"missing capture manifest {name}: {record[name]}")
(Path(os.environ["FAKE_STATE"]) / "capture-assembler-args.json").write_text(
    json.dumps(record) + "\\n",
    encoding="utf-8",
)
with (Path(os.environ["FAKE_STATE"]) / "pipeline-events").open(
    "a", encoding="utf-8"
) as stream:
    stream.write("capture-input-assemble\\n")
output = Path(record["--output"])
output.parent.mkdir(parents=True, exist_ok=True)
output.write_text(
    json.dumps(
        {
            "schemaVersion": 1,
            "desktopVersion": record["--desktop-version"],
            "desktopBuild": record["--desktop-build"],
            "surfaces": {},
        }
    )
    + "\\n",
    encoding="utf-8",
)
""",
        )
        self._write_executable(
            self.scripts / "audit_desktop_apphost_api.py",
            """#!/usr/bin/env python3
import json
import os
from pathlib import Path
import sys

arguments = sys.argv[1:]
value = lambda name: arguments[arguments.index(name) + 1]
required = (
    "--official-main",
    "--official-renderer",
    "--ipad-router",
    "--output",
)
record = {name: value(name) for name in required}
if "--require-complete" not in arguments:
    raise SystemExit("missing --require-complete")
for name in required[:3]:
    if not Path(record[name]).is_dir():
        raise SystemExit(f"missing audit input {name}: {record[name]}")
(Path(os.environ["FAKE_STATE"]) / "apphost-audit-args.json").write_text(
    json.dumps(record) + "\\n",
    encoding="utf-8",
)
with (Path(os.environ["FAKE_STATE"]) / "pipeline-events").open(
    "a", encoding="utf-8"
) as stream:
    stream.write("apphost-audit\\n")
if os.environ.get("FAIL_APPHOST_AUDIT") == "true":
    raise SystemExit(98)
output = Path(record["--output"])
output.parent.mkdir(parents=True, exist_ok=True)
output.write_text(
    json.dumps({"status": "complete"}) + "\\n",
    encoding="utf-8",
)
""",
        )
        self._write_executable(
            self.scripts / "build_release_parity_evidence.py",
            """#!/usr/bin/env python3
import hashlib
import json
import os
from pathlib import Path
import shutil
import sys

arguments = sys.argv[1:]
value = lambda name: arguments[arguments.index(name) + 1]
events = Path(os.environ["FAKE_STATE"]) / "pipeline-events"
with events.open("a", encoding="utf-8") as stream:
    stream.write("parity-evidence-build\\n")
record = {
    name: value(name)
    for name in (
        "--project-root",
        "--desktop-version",
        "--desktop-build",
        "--capture-input",
        "--python-test-log",
        "--swift-test-log",
        "--rust-test-log",
        "--xcui-test-log",
        "--device-build-log",
        "--device-surface-log",
    )
}
record["__arguments"] = arguments
(Path(os.environ["FAKE_STATE"]) / "parity-evidence-args.json").write_text(
    json.dumps(record) + "\\n",
    encoding="utf-8",
)
evidence_root = (
    Path(record["--project-root"])
    / "artifacts"
    / "parity-evidence"
    / record["--desktop-version"]
)
evidence_root.mkdir(parents=True, exist_ok=True)
(evidence_root / "verification").mkdir(parents=True, exist_ok=True)
for argument, name in (
    ("--python-test-log", "python-tests.log"),
    ("--swift-test-log", "swift-tests.log"),
    ("--rust-test-log", "rust-tests.log"),
    ("--xcui-test-log", "xcui-tests.log"),
    ("--device-build-log", "device-build.log"),
    ("--device-surface-log", "device-surface.json"),
):
    shutil.copy2(record[argument], evidence_root / "verification" / name)
(evidence_root / "new.txt").write_text(
    "new parity evidence\\n",
    encoding="utf-8",
)
root = Path(record["--project-root"])
version = record["--desktop-version"]
reference = (
    root
    / f"artifacts/full-reverse-{version}/recovered-electron-source/"
    "webview/assets/reference.js"
)
manifest = json.loads(
    (root / f"versions/{version}/manifest.json").read_text(
        encoding="utf-8"
    )
)
contract = {
    "schemaVersion": 2,
    "desktopVersion": version,
    "desktopBuild": record["--desktop-build"],
    "sourceIdentity": {
        "dmgSha256": manifest["dmgSha256"],
        "desktopSurfaceTreeSha256": "1" * 64,
        "recoveredSourceIndexSha256": "2" * 64,
    },
    "surfaces": [
        {
            "desktopEvidence": [
                {
                    "file": "webview/assets/reference.js",
                    "bytes": reference.stat().st_size,
                    "sha256": hashlib.sha256(
                        reference.read_bytes()
                    ).hexdigest(),
                }
            ]
        }
    ],
}
(root / f"versions/{version}/desktop-ui-parity.json").write_text(
    json.dumps(contract) + "\\n",
    encoding="utf-8",
)
if os.environ.get("FAIL_PARITY_EVIDENCE_BUILD") == "true":
    raise SystemExit(97)
""",
        )
        evidence_helper = self.scripts / "ipad_verification_evidence.py"
        real_evidence_helper = (
            self.scripts / "ipad_verification_evidence_real.py"
        )
        evidence_helper.replace(real_evidence_helper)
        self._write_executable(
            evidence_helper,
            """#!/usr/bin/env python3
if __name__ == "__main__":
    import importlib
    import json
    import os
    from pathlib import Path
    import sys

    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
    arguments = sys.argv[1:]
    command = arguments[0]
    if command == "record":
        value = lambda name: arguments[arguments.index(name) + 1]
        logs = [
            arguments[index + 1]
            for index, argument in enumerate(arguments)
            if argument == "--log"
        ]
        record = {
            "--record": value("--record"),
            "--project-root": value("--project-root"),
            "--summary": value("--summary"),
            "--xcresult": value("--xcresult"),
            "--source-head": value("--source-head"),
            "--contract": value("--contract"),
            "--log": logs,
        }
        (Path(os.environ["FAKE_STATE"]) / "xcui-evidence-args.json").write_text(
            json.dumps(record) + "\\n",
            encoding="utf-8",
        )
        with (Path(os.environ["FAKE_STATE"]) / "pipeline-events").open(
            "a", encoding="utf-8"
        ) as stream:
            stream.write("xcui-evidence-bind\\n")
    module = importlib.import_module(
        "scripts.ipad_verification_evidence_real"
    )
    raise SystemExit(module.main())
else:
    from scripts.ipad_verification_evidence_real import *
    from scripts.ipad_verification_evidence_real import _tree_sha256
""",
        )
        self._write_executable(
            self.scripts / "verify_desktop_parity_release.py",
            """#!/usr/bin/env python3
import json
import os
from pathlib import Path
import sys

events = Path(os.environ["FAKE_STATE"]) / "pipeline-events"
with events.open("a", encoding="utf-8") as stream:
    stream.write("desktop-parity-gate\\n")
if os.environ.get("FAIL_DESKTOP_PARITY_GATE") == "true":
    raise SystemExit(96)
args = sys.argv
output = Path(args[args.index("--output") + 1])
output.write_text(
    json.dumps({"status": "passed"}) + "\\n",
    encoding="utf-8",
)
""",
        )
        transaction = self.scripts / "upgrade_transaction.py"
        real_transaction = self.scripts / "upgrade_transaction_real.py"
        transaction.replace(real_transaction)
        self._write_executable(
            transaction,
            """#!/usr/bin/env python3
import os
from pathlib import Path
import subprocess
import sys

command = sys.argv[1]
events = Path(os.environ["FAKE_STATE"]) / "pipeline-events"
with events.open("a", encoding="utf-8") as stream:
    stream.write(f"{command}\\n")
if command == "commit" and os.environ.get("FAIL_TRANSACTION_COMMIT") == "true":
    raise SystemExit(91)
real = Path(__file__).with_name("upgrade_transaction_real.py")
raise SystemExit(
    subprocess.run([sys.executable, str(real), *sys.argv[1:]], check=False).returncode
)
""",
        )
        official_state = self.scripts / "official_download_state.py"
        real_official_state = (
            self.scripts / "official_download_state_real.py"
        )
        official_state.replace(real_official_state)
        self._write_executable(
            official_state,
            """#!/usr/bin/env python3
if __name__ == "__main__":
    import os
    from pathlib import Path
    import runpy
    import sys

    command = sys.argv[1]
    if command == "assert-local-current":
        events = Path(os.environ["FAKE_STATE"]) / "pipeline-events"
        with events.open("a", encoding="utf-8") as stream:
            stream.write("local-current\\n")
        if os.environ.get("FAIL_LOCAL_CURRENT") == "true":
            raise SystemExit(95)
    if command == "cleanup-incomplete-parts":
        events = Path(os.environ["FAKE_STATE"]) / "pipeline-events"
        with events.open("a", encoding="utf-8") as stream:
            stream.write("cleanup-incomplete-parts\\n")
    real = Path(__file__).with_name("official_download_state_real.py")
    runpy.run_path(str(real), run_name="__main__")
else:
    from scripts.official_download_state_real import *
""",
        )
        archive = self.scripts / "release_archive.py"
        real_archive = self.scripts / "release_archive_real.py"
        archive.replace(real_archive)
        self._write_executable(
            archive,
            """#!/usr/bin/env python3
if __name__ == "__main__":
    import importlib
    import os
    from pathlib import Path
    import sys

    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
    command = sys.argv[1]
    events = Path(os.environ["FAKE_STATE"]) / "pipeline-events"
    if command == "archive":
        with events.open("a", encoding="utf-8") as stream:
            stream.write("archive-start\\n")
        if os.environ.get("FAIL_RELEASE_ARCHIVE") == "true":
            raise SystemExit(94)
    module = importlib.import_module("scripts.release_archive_real")
    result = module.main()
    if command == "archive":
        with events.open("a", encoding="utf-8") as stream:
            stream.write("archive-complete\\n")
    raise SystemExit(result)
else:
    from scripts.release_archive_real import *
""",
        )
        evidence = self.scripts / "seed_release_evidence.py"
        evidence.write_text(
            """from pathlib import Path
import hashlib
import json
import plistlib
import sys

command = sys.argv[1]
root = Path(sys.argv[2])
version = sys.argv[3]
build = sys.argv[4]
package = Path(sys.argv[5])
if package.is_file():
    package_hash = hashlib.sha256(package.read_bytes()).hexdigest()
else:
    package_hash = sys.argv[5]


def write_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value) + "\\n", encoding="utf-8")


if command == "import":
    sys.path.insert(0, str(root))
    from scripts.build_desktop_ui_parity import SURFACE_DEFINITIONS

    app_asar = root / f"artifacts/app-asar-{version}"
    app_asar.mkdir(parents=True, exist_ok=True)
    (app_asar / "index.html").write_text(
        "<main>fixture renderer</main>\\n",
        encoding="utf-8",
    )
    official_main = app_asar / ".vite/build/main.js"
    official_main.parent.mkdir(parents=True, exist_ok=True)
    official_main.write_text("// fixture AppHost main bundle\\n", encoding="utf-8")
    official_renderer = app_asar / "webview/assets/reference.js"
    official_renderer.parent.mkdir(parents=True, exist_ok=True)
    official_renderer.write_text(
        "// fixture AppHost renderer bundle\\n",
        encoding="utf-8",
    )
    full_reverse = root / f"artifacts/full-reverse-{version}"
    renderer = full_reverse / "app-asar/webview/index.html"
    renderer.parent.mkdir(parents=True, exist_ok=True)
    renderer.write_text(
        "<main>fixture renderer</main>\\n",
        encoding="utf-8",
    )
    recovered_reference = (
        full_reverse
        / "recovered-electron-source/webview/assets/reference.js"
    )
    recovered_reference.parent.mkdir(parents=True, exist_ok=True)
    recovered_reference.write_text(
        "desktop reference fixture\\n",
        encoding="utf-8",
    )
    protocol_source = (
        full_reverse
        / "official-codex-source/codex-rs/app-server-protocol/src/protocol/common.rs"
    )
    protocol_source.parent.mkdir(parents=True, exist_ok=True)
    protocol_source.write_text("// fixture protocol source\\n", encoding="utf-8")
    version_root = root / f"versions/{version}"
    write_json(
        version_root / "feature-inventory.json",
        {
            "schemaVersion": 1,
            "version": version,
            "build": build,
            "featureCount": 0,
            "features": [],
        },
    )
    for scan_root in (
        root / "CodexPad/CodexPad",
        root / "CodexPad/CodexPad/Application",
        root / "CodexCore",
        root / "CodexPad/Tests",
        root / "tests",
    ):
        scan_root.mkdir(parents=True, exist_ok=True)
    write_json(
        full_reverse / "full-reverse-manifest.json",
        {
            "schemaVersion": 1,
            "version": version,
            "build": build,
        },
    )
    write_json(
        version_root / "manifest.json",
        {
            "schemaVersion": 1,
            "version": version,
            "build": build,
            "dmgSha256": package_hash,
        },
    )
    write_json(
        version_root / "desktop-surface-manifest.json",
        {
            "desktopVersion": version,
            "desktopBuild": build,
            "resourceTreeSha256": hashlib.sha256(b"surface").hexdigest(),
        },
    )
    reference_payload = recovered_reference.read_bytes()
    reference_digest = hashlib.sha256(reference_payload).hexdigest()
    interaction_surfaces = []
    for definition in SURFACE_DEFINITIONS:
        surface_id = str(definition["id"])
        occurrence = {
            "file": "webview/assets/reference.js",
            "fileSha256": reference_digest,
            "byteOffset": 0,
        }
        interaction = {
            "kind": "button",
            "id": f"fixture.{surface_id}.button",
            "defaultMessage": f"Fixture {surface_id}",
            "description": "Button label for fixture interaction",
            "occurrences": [occurrence],
        }
        interaction_surfaces.append(
            {
                "id": surface_id,
                "category": definition["category"],
                "name": definition["name"],
                "routes": list(definition["routes"]),
                "requiredStates": list(definition["requiredStates"]),
                "referenceStatus": "reference-indexed",
                "missingEvidenceGlobs": [],
                "sourceFiles": [
                    {
                        "path": "webview/assets/reference.js",
                        "bytes": len(reference_payload),
                        "sha256": reference_digest,
                    }
                ],
                "messageCount": 1,
                "interactionCount": 1,
                "messages": [
                    {
                        key: value
                        for key, value in interaction.items()
                        if key != "kind"
                    }
                ],
                "interactions": [interaction],
            }
        )
    write_json(
        version_root / "desktop-interaction-inventory.json",
        {
            "schemaVersion": 1,
            "desktopVersion": version,
            "desktopBuild": build,
            "sourceIdentity": {
                "desktopSurfaceTreeSha256": "1" * 64,
            },
            "extractionMode": "static-official-renderer-no-execution",
            "summary": {
                "surfaceCount": len(interaction_surfaces),
                "referenceIndexed": len(interaction_surfaces),
                "missingReference": 0,
                "evidenceFileCount": 1,
                "messageCount": len(interaction_surfaces),
                "interactionCount": len(interaction_surfaces),
                "surfacesWithInteractions": len(interaction_surfaces),
            },
            "surfaces": interaction_surfaces,
        },
    )
    write_json(
        root / f"artifacts/manifest-{version}.json",
        {
            "version": version,
            "build": build,
            "dmg_sha256": package_hash,
            "extracted_path": f"artifacts/app-asar-{version}",
            "file_count": 3,
        },
    )
    info = root / f"artifacts/Info-{version}.plist"
    info.parent.mkdir(parents=True, exist_ok=True)
    with info.open("wb") as stream:
        plistlib.dump(
            {
                "CFBundleShortVersionString": version,
                "CFBundleVersion": build,
            },
            stream,
        )

if command in {"upgrade", "verify"}:
    write_json(
        root / f"artifacts/ipad-upgrade-{version}.json",
        {
            "desktopVersion": version,
            "desktopBuild": build,
            "modelCatalogGenerated": True,
            "buildMetadataGenerated": True,
            "codexCoreUpgraded": True,
            "xcframeworkRebuilt": True,
        },
    )

if command == "verify":
    write_json(
        root / f"artifacts/ipad-verified-{version}.json",
        {
            "desktopVersion": version,
            "desktopBuild": build,
            "productName": "Codex for ipad",
            "bundleVersionMatched": True,
            "bundleBuildMatched": True,
            "rustTests": "passed",
            "swiftTests": "passed",
            "swiftTestCount": 7,
            "xcuiTests": "passed",
            "physicalDeviceTests": "passed",
            "physicalDeviceUDID": "00000000-0000000000000000",
            "physicalDeviceName": "Example iPad Pro",
            "physicalDeviceModel": "iPad Pro (12.9-inch) (5th generation)",
            "physicalDeviceOS": "26.0",
            "deviceBuild": "passed",
            "deviceArchitecture": "arm64",
            "desktopSurfaceCompleteTree": "passed",
            "sourceIdentity": {
                "dmgSha256": package_hash,
            },
            "desktopSurface": {
                "deviceBundleVerified": True,
            },
        },
    )
""",
            encoding="utf-8",
        )
        self._write_executable(
            self.scripts / "import_dmg.sh",
            """#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
python3 "$root/scripts/seed_release_evidence.py" \
  import "$root" "$FAKE_VERSION" "$FAKE_BUILD" "$1"
""",
        )
        mutation = self.scripts / "mutate_upgrade_state.py"
        mutation.write_text(
            """from pathlib import Path
import sys

root = Path(sys.argv[1])
version = sys.argv[2]
paths = [
    root / "CodexCore/Cargo.toml",
    root / "CodexCore/Cargo.lock",
    root / "CodexCore/src/official_provider.rs",
    root / "CodexPad/CodexPad/Domain/CodexModelCatalog.generated.swift",
    root / "CodexPad/CodexPad/Domain/CodexBuildMetadata.generated.swift",
    root / "CodexPad/CodexPad/Application/Resources/skills",
    root / f"versions/{version}/model-catalog.json",
    root / "CodexPad/CodexPad/Resources/Assets.xcassets/AppIcon.appiconset",
    root / "CodexPad/CodexPad.xcodeproj/project.pbxproj",
    root / "build/CodexCore.xcframework",
    root / f"artifacts/ipad-upgrade-{version}.json",
    root / f"artifacts/ipad-verified-{version}.json",
    root / "artifacts/latest-official.json",
    root / "DerivedData/UpdaterVerification",
]
directories = {
    root / "CodexPad/CodexPad/Application/Resources/skills",
    root / "CodexPad/CodexPad/Resources/Assets.xcassets/AppIcon.appiconset",
    root / "build/CodexCore.xcframework",
    root / "DerivedData/UpdaterVerification",
}
for index, path in enumerate(paths):
    if path in directories:
        path.mkdir(parents=True, exist_ok=True)
        (path / "new.txt").write_text(f"new-{index}\\n", encoding="utf-8")
    else:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(f"new-{index}\\n", encoding="utf-8")
""",
            encoding="utf-8",
        )
        self._write_executable(
            self.scripts / "apply_ipad_upgrade.sh",
            """#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
if [[ "${LOG_IPAD_UPGRADE:-false}" == "true" ]]; then
  printf 'ipad-upgrade\n' >>"$FAKE_STATE/pipeline-events"
fi
python3 "$root/scripts/mutate_upgrade_state.py" "$root" "$1"
dmg="$(find "$FAKE_DOWNLOAD_DIR" -maxdepth 1 -name 'ChatGPT-*.dmg' -print -quit)"
python3 "$root/scripts/seed_release_evidence.py" \
  upgrade "$root" "$1" "$2" "$dmg"
""",
        )
        self._write_executable(
            self.scripts / "verify_ipad_upgrade.sh",
            """#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
printf 'ipad-verify\\n' >>"$FAKE_STATE/pipeline-events"
if [[ "${FAIL_IPAD_VERIFY:-false}" == "true" ]]; then
  exit 93
fi
verification="$root/DerivedData/UpdaterVerification/VerificationLogs"
mkdir -p "$verification"
for name in \
  python-test.log swift-test.log rust-test.log xcui-test.log \
  device-build.log device-desktop-surface.json
do
  printf 'passed %s\n' "$name" >"$verification/$name"
done
printf '%s\n' \
  '{"result":"Passed","totalTestCount":1,"passedTests":1,"failedTests":0,"skippedTests":0,"expectedFailures":0,"startTime":1.0,"finishTime":2.0}' \
  >"$verification/xcui-summary.json"
xcresult="$root/DerivedData/UpdaterVerification/CodexPadUITests.xcresult"
mkdir -p "$xcresult"
printf 'xcresult fixture\n' >"$xcresult/Info.plist"
python3 "$root/scripts/mutate_upgrade_state.py" "$root" "$1"
python3 "$root/scripts/seed_release_evidence.py" \
  verify "$root" "$1" "$2" "$3"
""",
        )
        gate = self.scripts / "ipad_release_gate.py"
        real_gate = self.scripts / "ipad_release_gate_real.py"
        gate.replace(real_gate)
        self._write_executable(
            gate,
            """#!/usr/bin/env python3
if __name__ == "__main__":
    import hashlib
    import json
    import os
    from pathlib import Path
    import sys

    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
    from scripts.build_ipad_release import production_input_fingerprint

    arguments = sys.argv[1:]
    value = lambda name: arguments[arguments.index(name) + 1]
    root = Path(value("--project-root"))
    identity = json.loads(
        Path(value("--identity-record")).read_text(encoding="utf-8")
    )
    release = (
        Path(value("--output-root"))
        / identity["version"]
        / str(identity["build"])
        / identity["dmg_sha256"][:16]
    )
    ipa = release / "export/Codex for ipad.ipa"
    ipa.parent.mkdir(parents=True, exist_ok=True)
    ipa.write_bytes(b"signed IPA fixture")
    manifest = release / "CodexPad.release.json"
    payload = {
        "schemaVersion": 1,
        "version": identity["version"],
        "build": str(identity["build"]),
        "dmgSha256": identity["dmg_sha256"],
        "configuration": "Release",
        "distributionMethod": "debugging",
        "productionInputFingerprint": production_input_fingerprint(root),
        "artifact": {
            "fileName": ipa.name,
            "sha256": hashlib.sha256(ipa.read_bytes()).hexdigest(),
            "sizeBytes": ipa.stat().st_size,
            "zipIntegrity": True,
        },
        "product": {
            "architecture": "arm64",
            "build": str(identity["build"]),
            "deviceFamily": "iPad",
            "platform": "iphoneos",
            "version": identity["version"],
        },
        "verification": {
            "bundleIdentityMatched": True,
            "codesignValid": True,
            "entitlementsValid": True,
            "provisioningProfileValid": True,
            "targetDeviceProvisioned": True,
        },
    }
    manifest.write_text(json.dumps(payload) + "\\n", encoding="utf-8")
    output = {
        "ipaPath": ipa.relative_to(root).as_posix(),
        "ipaSha256": payload["artifact"]["sha256"],
        "ipaReleaseManifestPath": manifest.relative_to(root).as_posix(),
        "ipaReleaseManifestSha256": hashlib.sha256(
            manifest.read_bytes()
        ).hexdigest(),
    }
    Path(value("--output")).write_text(
        json.dumps(output) + "\\n",
        encoding="utf-8",
    )
    with (Path(os.environ["FAKE_STATE"]) / "pipeline-events").open(
        "a", encoding="utf-8"
    ) as stream:
        stream.write("ipa-gate\\n")
    if os.environ.get("FAIL_IPA_GATE") == "true":
        raise SystemExit(92)
else:
    from scripts.ipad_release_gate_real import *
""",
        )

    def seed_transaction_state(self):
        existing = {}
        absent = {
            self.root / f"artifacts/ipad-upgrade-{self.version}.json",
            self.root / f"artifacts/ipad-verified-{self.version}.json",
        }
        paths = [
            self.root / "CodexCore/Cargo.toml",
            self.root / "CodexCore/Cargo.lock",
            self.root / "CodexCore/src/official_provider.rs",
            self.root
            / "CodexPad/CodexPad/Domain/CodexModelCatalog.generated.swift",
            self.root
            / "CodexPad/CodexPad/Domain/CodexBuildMetadata.generated.swift",
            self.root
            / "CodexPad/CodexPad/Application/Resources/skills",
            self.root / f"versions/{self.version}/model-catalog.json",
            self.root
            / "CodexPad/CodexPad/Resources/Assets.xcassets/AppIcon.appiconset",
            self.root / "CodexPad/CodexPad.xcodeproj/project.pbxproj",
            self.root / f"artifacts/app-asar-{self.version}",
            self.root / f"artifacts/full-reverse-{self.version}",
            self.root / f"artifacts/Info-{self.version}.plist",
            self.root / f"artifacts/entitlements-{self.version}.plist",
            self.root / f"artifacts/manifest-{self.version}.json",
            self.root / f"versions/{self.version}",
            self.root / "build/CodexCore.xcframework",
            self.root / f"artifacts/ipad-upgrade-{self.version}.json",
            self.root / f"artifacts/ipad-verified-{self.version}.json",
            self.root / f"artifacts/parity-evidence/{self.version}",
            self.root / "artifacts/latest-official.json",
            self.root / "DerivedData/UpdaterVerification",
        ]
        directories = {
            self.root
            / "CodexPad/CodexPad/Application/Resources/skills",
            self.root
            / "CodexPad/CodexPad/Resources/Assets.xcassets/AppIcon.appiconset",
            self.root / f"artifacts/app-asar-{self.version}",
            self.root / f"artifacts/full-reverse-{self.version}",
            self.root / f"versions/{self.version}",
            self.root / f"artifacts/parity-evidence/{self.version}",
            self.root / "build/CodexCore.xcframework",
            self.root / "DerivedData/UpdaterVerification",
        }
        for index, path in enumerate(paths):
            if path in absent:
                continue
            if path in directories:
                path.mkdir(parents=True, exist_ok=True)
                value = f"old-directory-{index}\n".encode()
                (path / "old.txt").write_bytes(value)
                existing[path] = ("directory", value)
            else:
                path.parent.mkdir(parents=True, exist_ok=True)
                value = f"old-file-{index}\n".encode()
                path.write_bytes(value)
                existing[path] = ("file", value)
        return paths, absent, existing


class UpdateLatestIntegrityTests(unittest.TestCase):
    def test_help_exits_before_acquiring_the_upgrade_lock(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            sandbox = UpdaterSandbox(temporary)
            unexpected_lock_helper = sandbox.bin / "unexpected-shlock"
            sandbox._write_executable(
                unexpected_lock_helper,
                "#!/usr/bin/env bash\nexit 91\n",
            )

            result = subprocess.run(
                [str(sandbox.scripts / "update_latest.sh"), "--help"],
                cwd=sandbox.root,
                env={
                    **sandbox.environment,
                    "SHLOCK_BIN": str(unexpected_lock_helper),
                },
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                timeout=5,
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("usage:", result.stdout.lower())
            self.assertFalse(
                (sandbox.root / ".update-state" / "upgrade.lock").exists()
            )

    def test_missing_official_parity_manifest_still_runs_source_upgrade_first(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            sandbox = UpdaterSandbox(temporary)
            sandbox.seed_transaction_state()
            sandbox.official_parity_manifest.unlink()

            result = sandbox.run(LOG_IPAD_UPGRADE="true")

            self.assertEqual(result.returncode, 78, result.stderr)
            events = (
                sandbox.state / "pipeline-events"
            ).read_text(encoding="utf-8").splitlines()
            self.assertEqual(
                events,
                [
                    "recover-pending",
                    "snapshot",
                    "apphost-audit",
                    "ipad-upgrade",
                    "restore",
                ],
            )
            self.assertNotIn("ipad-verify", events)
            self.assertIn(
                "Missing approved official parity manifest",
                result.stderr,
            )

    def test_stale_literal_mktemp_names_do_not_block_upgrade(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            state = Path(temporary)
            script = (ROOT / "scripts/update_latest.sh").read_text(
                encoding="utf-8"
            )
            templates = re.findall(
                r'mktemp "\$STATE_DIR/([^"]+)"',
                script,
            )
            self.assertGreaterEqual(len(templates), 5)
            for template in templates:
                self.assertTrue(
                    template.endswith("XXXXXX"),
                    msg=f"BSD mktemp requires trailing Xs: {template}",
                )
                (state / template).write_text("stale\n", encoding="utf-8")
                result = subprocess.run(
                    ["mktemp", str(state / template)],
                    text=True,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    timeout=5,
                )
                self.assertEqual(
                    result.returncode,
                    0,
                    msg=f"template={template}\nstderr={result.stderr}",
                )
                self.assertNotEqual(
                    Path(result.stdout.strip()).name,
                    template,
                )

    def test_signature_failure_does_not_create_a_reusable_sidecar(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            sandbox = UpdaterSandbox(temporary)

            result = sandbox.run(CODESIGN_EXIT="42")

            self.assertEqual(result.returncode, 42)
            self.assertTrue(list((sandbox.root / ".downloads").glob("*.dmg")))
            self.assertFalse(
                list((sandbox.root / ".downloads").glob("*.remote.json"))
            )
            self.assertFalse((sandbox.state / "spctl-called").exists())

    def test_second_updater_exits_without_touching_first_run_files(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            sandbox = UpdaterSandbox(temporary)
            first = subprocess.Popen(
                [str(sandbox.scripts / "update_latest.sh")],
                cwd=sandbox.root,
                env={**sandbox.environment, "BLOCK_FIRST_HEAD": "true"},
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
            )
            ready = sandbox.state / "first-head-ready"
            deadline = time.monotonic() + 5
            while not ready.exists() and time.monotonic() < deadline:
                time.sleep(0.02)
            try:
                self.assertTrue(
                    ready.exists(),
                    "first updater did not acquire its lock",
                )
                before = self._tree_bytes(sandbox.root / ".update-state")

                second = sandbox.run()

                after = self._tree_bytes(sandbox.root / ".update-state")
                self.assertEqual(second.returncode, 75)
                self.assertLess(len(second.stdout) + len(second.stderr), 1024)
                self.assertEqual(after, before)
            finally:
                (sandbox.state / "release-first-head").touch()
                first.communicate(timeout=5)
            self.assertFalse(
                (sandbox.root / ".update-state" / "upgrade.lock").exists()
            )

    def test_stale_upgrade_lock_is_reclaimed_before_the_next_cycle(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            sandbox = UpdaterSandbox(temporary)
            lock = sandbox.root / ".update-state" / "upgrade.lock"
            lock.parent.mkdir(parents=True, exist_ok=True)
            lock.write_text("999999999\n", encoding="utf-8")

            result = sandbox.run(CODESIGN_EXIT="42")

            self.assertEqual(result.returncode, 42)
            self.assertFalse(lock.exists())
            self.assertNotIn("already running", result.stderr)

    def test_next_cycle_recovers_interrupted_transaction_before_probe(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            sandbox = UpdaterSandbox(temporary)
            sandbox.seed_transaction_state()
            target = sandbox.root / "CodexCore" / "Cargo.toml"
            old = target.read_bytes()
            transaction = (
                sandbox.root / ".update-state" / "transactions" / "crashed"
            )
            snapshot = subprocess.run(
                [
                    str(sandbox.scripts / "upgrade_transaction.py"),
                    "snapshot",
                    "--root",
                    str(sandbox.root),
                    "--version",
                    sandbox.version,
                    "--transaction-dir",
                    str(transaction),
                ],
                cwd=sandbox.root,
                env=sandbox.environment,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
            )
            self.assertEqual(snapshot.returncode, 0, snapshot.stderr)
            target.write_text("interrupted\n", encoding="utf-8")
            (sandbox.state / "pipeline-events").unlink()

            result = sandbox.run(CODESIGN_EXIT="42")

            self.assertEqual(result.returncode, 42)
            self.assertEqual(target.read_bytes(), old)
            self.assertFalse(transaction.exists())
            events = (
                sandbox.state / "pipeline-events"
            ).read_text(encoding="utf-8").splitlines()
            self.assertEqual(events[0], "recover-pending")

    def test_final_remote_change_restores_every_upgrade_mutation(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            sandbox = UpdaterSandbox(temporary)
            paths, absent, existing = sandbox.seed_transaction_state()

            result = sandbox.run(
                CHANGE_HEAD_AT="3",
                LOG_HEAD_EVENTS="true",
            )

            self.assertNotEqual(result.returncode, 0)
            events = (
                sandbox.state / "pipeline-events"
            ).read_text(encoding="utf-8").splitlines()
            self.assertEqual(
                events,
                [
                    "recover-pending",
                    "head-1",
                    "head-2",
                    "snapshot",
                    "apphost-audit",
                    "ipad-verify",
                    "capture-input-assemble",
                    "parity-evidence-build",
                    "xcui-evidence-bind",
                    "desktop-parity-gate",
                    "ipa-gate",
                    "archive-start",
                    "archive-complete",
                    "head-3",
                    "restore",
                ],
            )
            for path in paths:
                with self.subTest(path=path):
                    if path in absent:
                        self.assertFalse(path.exists())
                    elif existing[path][0] == "file":
                        self.assertEqual(path.read_bytes(), existing[path][1])
                    else:
                        self.assertEqual(
                            (path / "old.txt").read_bytes(),
                            existing[path][1],
                        )
                        self.assertFalse((path / "new.txt").exists())
            self.assertFalse(
                (
                    sandbox.root
                    / f"artifacts/app-asar-{sandbox.version}/index.html"
                ).is_file()
            )
            package_hash = hashlib.sha256(b"12345678").hexdigest()
            release_root = (
                sandbox.root
                / f"artifacts/releases/{sandbox.version}/{sandbox.build}"
                / package_hash
            )
            self.assertTrue(
                (release_root / "release-manifest.json").is_file()
            )
            archived = subprocess.run(
                [
                    str(sandbox.scripts / "release_archive.py"),
                    "verify",
                    "--project-root",
                    str(sandbox.root),
                    "--version",
                    sandbox.version,
                    "--build",
                    sandbox.build,
                    "--dmg-sha256",
                    package_hash,
                ],
                cwd=sandbox.root,
                env=sandbox.environment,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
            )
            self.assertEqual(archived.returncode, 0, archived.stderr)
            self.assertTrue(
                list((sandbox.root / ".downloads").glob("*.dmg.remote.json"))
            )
            self.assertFalse(
                (sandbox.root / ".update-state" / "upgrade.lock").exists()
            )
            transactions = sandbox.root / ".update-state" / "transactions"
            self.assertFalse(transactions.exists() and any(transactions.iterdir()))

    def test_success_archives_rechecks_commits_then_cleans_transfer_state(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            sandbox = UpdaterSandbox(temporary)
            sandbox.seed_transaction_state()
            downloads = sandbox.root / ".downloads"
            downloads.mkdir()
            historical_part = downloads / "ChatGPT-historical.dmg.part"
            complete_part = downloads / "ChatGPT-complete.dmg.part"
            source_part = downloads / "codex-historical.tar.gz.part"
            retained_package = downloads / "ChatGPT-retained.dmg"
            retained_sidecar = downloads / "ChatGPT-retained.dmg.remote.json"
            historical_part.write_bytes(b"old")
            complete_part.write_bytes(b"12345678")
            source_part.write_bytes(b"historical-source")
            retained_package.write_bytes(b"12345678")
            retained_sidecar.write_text("{}\n", encoding="utf-8")

            result = sandbox.run(LOG_HEAD_EVENTS="true")

            self.assertEqual(result.returncode, 0, result.stderr)
            events = (
                sandbox.state / "pipeline-events"
            ).read_text(encoding="utf-8").splitlines()
            self.assertEqual(
                events,
                [
                    "recover-pending",
                    "head-1",
                    "head-2",
                    "snapshot",
                    "apphost-audit",
                    "ipad-verify",
                    "capture-input-assemble",
                    "parity-evidence-build",
                    "xcui-evidence-bind",
                    "desktop-parity-gate",
                    "ipa-gate",
                    "archive-start",
                    "archive-complete",
                    "head-3",
                    "local-current",
                    "commit",
                    "delete-transfer",
                    "cleanup-incomplete-parts",
                    "delete-verification-cache",
                ],
            )
            package_hash = hashlib.sha256(b"12345678").hexdigest()
            expected_release_root = (
                f"artifacts/releases/{sandbox.version}/{sandbox.build}/"
                f"{package_hash}"
            )
            latest = json.loads(
                (
                    sandbox.root / "artifacts/latest-official.json"
                ).read_text(encoding="utf-8")
            )
            self.assertEqual(
                latest["releaseRoot"],
                expected_release_root,
            )
            manifest = (
                sandbox.root
                / expected_release_root
                / "release-manifest.json"
            )
            self.assertEqual(
                latest["releaseManifestSha256"],
                hashlib.sha256(manifest.read_bytes()).hexdigest(),
            )
            self.assertTrue(
                (
                    sandbox.root
                    / expected_release_root
                    / "official/ChatGPT.dmg"
                ).is_file()
            )
            self.assertFalse(historical_part.exists())
            self.assertEqual(complete_part.read_bytes(), b"12345678")
            self.assertEqual(source_part.read_bytes(), b"historical-source")
            self.assertEqual(retained_package.read_bytes(), b"12345678")
            self.assertEqual(
                retained_sidecar.read_text(encoding="utf-8"),
                "{}\n",
            )
            self.assertEqual(
                sorted(path.name for path in downloads.iterdir()),
                sorted(
                    [
                        complete_part.name,
                        source_part.name,
                        retained_package.name,
                        retained_sidecar.name,
                    ]
                ),
            )
            self.assertFalse(
                (sandbox.root / "DerivedData/UpdaterVerification").exists()
            )
            transactions = sandbox.root / ".update-state" / "transactions"
            self.assertFalse(transactions.exists() and any(transactions.iterdir()))

    def test_archive_failure_restores_upgrade_and_retains_transfer(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            sandbox = UpdaterSandbox(temporary)
            paths, absent, existing = sandbox.seed_transaction_state()

            result = sandbox.run(FAIL_RELEASE_ARCHIVE="true")

            self.assertEqual(result.returncode, 94)
            events = (
                sandbox.state / "pipeline-events"
            ).read_text(encoding="utf-8").splitlines()
            self.assertEqual(
                events,
                [
                    "recover-pending",
                    "snapshot",
                    "apphost-audit",
                    "ipad-verify",
                    "capture-input-assemble",
                    "parity-evidence-build",
                    "xcui-evidence-bind",
                    "desktop-parity-gate",
                    "ipa-gate",
                    "archive-start",
                    "restore",
                ],
            )
            for path in paths:
                with self.subTest(path=path):
                    if path in absent:
                        self.assertFalse(path.exists())
                    elif existing[path][0] == "file":
                        self.assertEqual(path.read_bytes(), existing[path][1])
                    else:
                        self.assertEqual(
                            (path / "old.txt").read_bytes(),
                            existing[path][1],
                        )
                        self.assertFalse((path / "new.txt").exists())
            downloads = sandbox.root / ".downloads"
            self.assertEqual(len(list(downloads.glob("*.dmg"))), 1)
            self.assertEqual(
                len(list(downloads.glob("*.dmg.remote.json"))),
                1,
            )
            package_hash = hashlib.sha256(b"12345678").hexdigest()
            release_root = (
                sandbox.root
                / f"artifacts/releases/{sandbox.version}/{sandbox.build}"
                / package_hash
            )
            self.assertFalse(release_root.exists())

    def test_ipad_verification_failure_restores_and_never_commits(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            sandbox = UpdaterSandbox(temporary)
            paths, absent, existing = sandbox.seed_transaction_state()

            result = sandbox.run(FAIL_IPAD_VERIFY="true")

            self.assertEqual(result.returncode, 93)
            events = (
                sandbox.state / "pipeline-events"
            ).read_text(encoding="utf-8").splitlines()
            self.assertEqual(
                events,
                [
                    "recover-pending",
                    "snapshot",
                    "apphost-audit",
                    "ipad-verify",
                    "restore",
                ],
            )
            self.assertNotIn("commit", events)
            for path in paths:
                with self.subTest(path=path):
                    if path in absent:
                        self.assertFalse(path.exists())
                    elif existing[path][0] == "file":
                        self.assertEqual(path.read_bytes(), existing[path][1])
                    else:
                        self.assertEqual(
                            (path / "old.txt").read_bytes(),
                            existing[path][1],
                        )
                        self.assertFalse((path / "new.txt").exists())
            self.assertTrue(
                list((sandbox.root / ".downloads").glob("*.dmg"))
            )
            self.assertTrue(
                list(
                    (sandbox.root / ".downloads").glob("*.dmg.remote.json")
                )
            )

    def test_apphost_audit_failure_restores_before_ipad_verification(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            sandbox = UpdaterSandbox(temporary)
            sandbox.seed_transaction_state()

            result = sandbox.run(FAIL_APPHOST_AUDIT="true")

            self.assertEqual(result.returncode, 98)
            events = (
                sandbox.state / "pipeline-events"
            ).read_text(encoding="utf-8").splitlines()
            self.assertEqual(
                events,
                ["recover-pending", "snapshot", "apphost-audit", "restore"],
            )
            self.assertNotIn("ipad-verify", events)
            self.assertNotIn("commit", events)

    def test_signed_ipa_gate_failure_restores_and_never_archives(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            sandbox = UpdaterSandbox(temporary)
            sandbox.seed_transaction_state()

            result = sandbox.run(FAIL_IPA_GATE="true")

            self.assertEqual(result.returncode, 92)
            events = (
                sandbox.state / "pipeline-events"
            ).read_text(encoding="utf-8").splitlines()
            self.assertEqual(
                events,
                [
                    "recover-pending",
                    "snapshot",
                    "apphost-audit",
                    "ipad-verify",
                    "capture-input-assemble",
                    "parity-evidence-build",
                    "xcui-evidence-bind",
                    "desktop-parity-gate",
                    "ipa-gate",
                    "restore",
                ],
            )
            self.assertNotIn("archive-start", events)
            self.assertNotIn("commit", events)
            self.assertFalse(
                (
                    sandbox.root
                    / f"artifacts/ipad-release/{sandbox.version}"
                ).exists()
            )

    def test_desktop_parity_failure_restores_before_ipa_or_archive(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            sandbox = UpdaterSandbox(temporary)
            sandbox.seed_transaction_state()

            result = sandbox.run(FAIL_DESKTOP_PARITY_GATE="true")

            self.assertEqual(result.returncode, 96)
            events = (
                sandbox.state / "pipeline-events"
            ).read_text(encoding="utf-8").splitlines()
            self.assertEqual(
                events,
                [
                    "recover-pending",
                    "snapshot",
                    "apphost-audit",
                    "ipad-verify",
                    "capture-input-assemble",
                    "parity-evidence-build",
                    "xcui-evidence-bind",
                    "desktop-parity-gate",
                    "restore",
                ],
            )
            self.assertNotIn("ipa-gate", events)
            self.assertNotIn("archive-start", events)
            self.assertNotIn("commit", events)

    def test_release_evidence_builder_uses_only_current_capture_and_logs(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            sandbox = UpdaterSandbox(temporary)

            result = sandbox.run()

            self.assertEqual(result.returncode, 0, result.stderr)
            arguments = json.loads(
                (
                    sandbox.state / "parity-evidence-args.json"
                ).read_text(encoding="utf-8")
            )
            self.assertEqual(
                arguments["--project-root"],
                str(sandbox.root),
            )
            self.assertEqual(
                arguments["--desktop-version"],
                sandbox.version,
            )
            self.assertEqual(arguments["--desktop-build"], sandbox.build)
            self.assertEqual(
                arguments["--capture-input"],
                str(sandbox.capture_input),
            )
            verification_logs = (
                sandbox.root
                / "DerivedData/UpdaterVerification/VerificationLogs"
            )
            expected_logs = {
                "--python-test-log": "python-test.log",
                "--swift-test-log": "swift-test.log",
                "--rust-test-log": "rust-test.log",
                "--xcui-test-log": "xcui-test.log",
                "--device-build-log": "device-build.log",
                "--device-surface-log": "device-desktop-surface.json",
            }
            for argument, name in expected_logs.items():
                with self.subTest(argument=argument):
                    self.assertEqual(
                        arguments[argument],
                        str(verification_logs / name),
                    )
            self.assertNotIn(
                "--simulator-build-log",
                arguments["__arguments"],
            )
            self.assertNotIn(
                "--simulator-surface-log",
                arguments["__arguments"],
            )

    def test_release_capture_input_is_assembled_from_current_runtime_manifests(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            sandbox = UpdaterSandbox(temporary)

            result = sandbox.run()

            self.assertEqual(result.returncode, 0, result.stderr)
            arguments = json.loads(
                (
                    sandbox.state / "capture-assembler-args.json"
                ).read_text(encoding="utf-8")
            )
            self.assertEqual(arguments["--project-root"], str(sandbox.root))
            self.assertEqual(
                arguments["--official-manifest"],
                str(sandbox.official_parity_manifest),
            )
            self.assertEqual(
                arguments["--ipad-manifest"],
                str(sandbox.ipad_parity_manifest),
            )
            self.assertEqual(arguments["--output"], str(sandbox.capture_input))
            self.assertEqual(arguments["--desktop-version"], sandbox.version)
            self.assertEqual(arguments["--desktop-build"], sandbox.build)

    def test_final_xcui_evidence_binding_uses_rebuilt_parity_contract(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            sandbox = UpdaterSandbox(temporary)

            result = sandbox.run()

            self.assertEqual(result.returncode, 0, result.stderr)
            arguments = json.loads(
                (
                    sandbox.state / "xcui-evidence-args.json"
                ).read_text(encoding="utf-8")
            )
            verification_logs = (
                sandbox.root
                / "DerivedData/UpdaterVerification/VerificationLogs"
            )
            self.assertEqual(
                arguments["--record"],
                str(
                    sandbox.root
                    / f"artifacts/ipad-verified-{sandbox.version}.json"
                ),
            )
            self.assertEqual(arguments["--project-root"], str(sandbox.root))
            self.assertEqual(
                arguments["--summary"],
                str(
                    sandbox.root
                    / f"artifacts/parity-evidence/{sandbox.version}/"
                    "verification/xcui-summary.json"
                ),
            )
            self.assertEqual(
                arguments["--xcresult"],
                str(
                    sandbox.root
                    / f"artifacts/parity-evidence/{sandbox.version}/"
                    "verification/CodexPadUITests.xcresult"
                ),
            )
            self.assertEqual(
                arguments["--contract"],
                str(
                    sandbox.root
                    / f"versions/{sandbox.version}/desktop-ui-parity.json"
                ),
            )
            self.assertRegex(arguments["--source-head"], r"^[0-9a-f]{40}$")
            self.assertEqual(
                arguments["--log"],
                [
                    f"python={sandbox.root / f'artifacts/parity-evidence/{sandbox.version}/verification/python-tests.log'}",
                    f"swift={sandbox.root / f'artifacts/parity-evidence/{sandbox.version}/verification/swift-tests.log'}",
                    f"rust={sandbox.root / f'artifacts/parity-evidence/{sandbox.version}/verification/rust-tests.log'}",
                    f"xcui={sandbox.root / f'artifacts/parity-evidence/{sandbox.version}/verification/xcui-tests.log'}",
                    f"device-build={sandbox.root / f'artifacts/parity-evidence/{sandbox.version}/verification/device-build.log'}",
                    f"device-surface={sandbox.root / f'artifacts/parity-evidence/{sandbox.version}/verification/device-surface.json'}",
                ],
            )
            evidence_root = (
                sandbox.root
                / f"artifacts/parity-evidence/{sandbox.version}/verification"
            )
            self.assertTrue((evidence_root / "xcui-summary.json").is_file())
            self.assertTrue(
                (evidence_root / "CodexPadUITests.xcresult").is_dir()
            )
            events = (
                sandbox.state / "pipeline-events"
            ).read_text(encoding="utf-8").splitlines()
            self.assertLess(
                events.index("parity-evidence-build"),
                events.index("xcui-evidence-bind"),
            )
            self.assertLess(
                events.index("xcui-evidence-bind"),
                events.index("desktop-parity-gate"),
            )

    def test_release_evidence_failure_restores_before_parity_or_ipa(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            sandbox = UpdaterSandbox(temporary)
            paths, absent, existing = sandbox.seed_transaction_state()

            result = sandbox.run(FAIL_PARITY_EVIDENCE_BUILD="true")

            self.assertEqual(result.returncode, 97)
            events = (
                sandbox.state / "pipeline-events"
            ).read_text(encoding="utf-8").splitlines()
            self.assertEqual(
                events,
                [
                    "recover-pending",
                    "snapshot",
                    "apphost-audit",
                    "ipad-verify",
                    "capture-input-assemble",
                    "parity-evidence-build",
                    "restore",
                ],
            )
            self.assertNotIn("desktop-parity-gate", events)
            self.assertNotIn("ipa-gate", events)
            self.assertNotIn("archive-start", events)
            self.assertNotIn("commit", events)
            for path in paths:
                with self.subTest(path=path):
                    if path in absent:
                        self.assertFalse(path.exists())
                    elif existing[path][0] == "file":
                        self.assertEqual(path.read_bytes(), existing[path][1])
                    else:
                        self.assertEqual(
                            (path / "old.txt").read_bytes(),
                            existing[path][1],
                        )
                        self.assertFalse((path / "new.txt").exists())

    def test_commit_failure_retains_download_and_restores_verification_cache(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            sandbox = UpdaterSandbox(temporary)
            _, _, existing = sandbox.seed_transaction_state()
            downloads = sandbox.root / ".downloads"
            downloads.mkdir()
            historical_part = downloads / "ChatGPT-historical.dmg.part"
            historical_part.write_bytes(b"old")
            verification_cache = (
                sandbox.root / "DerivedData/UpdaterVerification"
            )
            old_cache = existing[verification_cache][1]

            result = sandbox.run(FAIL_TRANSACTION_COMMIT="true")

            self.assertEqual(result.returncode, 91)
            events = (
                sandbox.state / "pipeline-events"
            ).read_text(encoding="utf-8").splitlines()
            self.assertEqual(
                events,
                [
                    "recover-pending",
                    "snapshot",
                    "apphost-audit",
                    "ipad-verify",
                    "capture-input-assemble",
                    "parity-evidence-build",
                    "xcui-evidence-bind",
                    "desktop-parity-gate",
                    "ipa-gate",
                    "archive-start",
                    "archive-complete",
                    "local-current",
                    "commit",
                    "restore",
                ],
            )
            self.assertEqual(historical_part.read_bytes(), b"old")
            self.assertEqual(len(list(downloads.glob("*.dmg"))), 1)
            self.assertEqual(
                len(list(downloads.glob("*.dmg.remote.json"))),
                1,
            )
            self.assertEqual(
                (verification_cache / "old.txt").read_bytes(),
                old_cache,
            )
            self.assertFalse((verification_cache / "new.txt").exists())
            package_hash = hashlib.sha256(b"12345678").hexdigest()
            release_root = (
                sandbox.root
                / f"artifacts/releases/{sandbox.version}/{sandbox.build}"
                / package_hash
            )
            self.assertTrue(
                (release_root / "release-manifest.json").is_file()
            )
            transactions = sandbox.root / ".update-state" / "transactions"
            self.assertFalse(transactions.exists() and any(transactions.iterdir()))
            self.assertFalse(
                (sandbox.root / ".update-state" / "upgrade.lock").exists()
            )

    @staticmethod
    def _tree_bytes(root: Path):
        if not root.exists():
            return {}
        return {
            path.relative_to(root).as_posix(): (
                "directory" if path.is_dir() else path.read_bytes()
            )
            for path in root.rglob("*")
        }


if __name__ == "__main__":
    unittest.main()
