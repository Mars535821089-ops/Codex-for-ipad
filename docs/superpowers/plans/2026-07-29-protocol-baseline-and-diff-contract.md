# Codex 官方协议基线与差异契约 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 从每个已验证的官方 Codex DMG 中生成可复现的 App Server TypeScript/JSON Schema、来源证明、规范化索引和跨版本破坏性差异报告，为后续 Swift/Rust iPad 兼容层提供唯一版本契约。

**Architecture:** Mac 端脚本只读取官方 DMG，在版本专属 staging 目录运行 DMG 内置 `codex app-server generate-*`，验证输出后原子发布到 `versions/${VERSION}/protocol/`。Python 标准库负责 manifest 校验、文件哈希、规范化索引和语义差异分类；Shell 只负责 macOS 挂载、签名检查和调用内置 CLI。

**Tech Stack:** Bash 3.2、Python 3 标准库、`hdiutil`、`plutil`、`codesign`、`spctl`、Codex 内置 Rust CLI、`unittest`、Git

## Global Constraints

- 项目根目录固定为 `/Users/you/projects/Codex-持续更新逆向Ipad版`。
- 当前官方基线为 App 版本 `26.721.41059`、build `5848`、内置 CLI `0.146.0-alpha.3.1`。
- iPad 安装后的运行能力不得依赖 Mac、云端执行机、SSH、Bridge Server 或远程桌面。
- 官方 Codex 是唯一产品基准；后续 UI、文案、功能入口、状态和操作结果必须 1:1 复现，不得用自定义产品设计替代。
- 每个版本必须同时生成稳定协议和带 `--experimental` 的实验协议，二者不可互相覆盖。
- 每个生成文件必须记录 SHA-256；来源必须指向 DMG SHA-256、Bundle version/build、内置 CLI 版本和签名验证结果。
- 版本产物只能先写入 `versions/.staging-${VERSION}-${PID}/`，全部验证通过后才能原子发布到 `versions/${VERSION}/`。
- 已发布的 `versions/${VERSION}/` 不允许静默覆盖；相同来源重复执行必须幂等成功，不同来源必须失败。
- 任何协议删除、必填字段新增、字段类型收窄或枚举值删除均为阻断性变化。
- 协议生成或差异检查失败不得修改当前 iPad 兼容层，也不得删除下载 DMG。
- 源码、日志、报告和 Git 中不得记录 API key、会话 token、签名私钥或 provisioning profile 内容。
- 本计划只完成第一阶段协议基线；Electron IPC/功能清单、SwiftUI 工程、Rust iOS Core、Tool Runtime、签名安装与自动升级分别使用后续独立计划。

---

## File Structure

```text
scripts/
├── protocol_manifest.py              # manifest 数据模型、校验、哈希与原子 JSON 写入
├── build_protocol_index.py           # 扫描生成目录并输出稳定排序的协议文件索引
├── diff_protocol_versions.py         # JSON Schema 语义差异分类与 Markdown/JSON 报告
├── generate_protocol_snapshot.sh     # 挂载 DMG、验证 App、调用内置 CLI并发布版本快照
└── import_dmg.sh                     # 导入 ASAR 后接入协议快照生成
tests/
├── fixtures/
│   ├── protocol-old/                 # 小型旧版 JSON Schema 契约
│   └── protocol-new/                 # 含新增、删除和类型变化的小型新版契约
├── test_protocol_manifest.py         # manifest、哈希、幂等和路径边界测试
├── test_build_protocol_index.py      # 索引排序、分类和摘要测试
├── test_diff_protocol_versions.py    # 破坏性/兼容性差异分类测试
└── test_generate_protocol_snapshot.sh # 使用伪 App/CLI 验证 Shell 编排和失败保留
versions/
└── ${VERSION}/
    ├── manifest.json
    ├── provenance.json
    ├── protocol/
    │   ├── typescript/stable/
    │   ├── typescript/experimental/
    │   ├── json-schema/stable/
    │   ├── json-schema/experimental/
    │   └── index.json
    └── compatibility-report.json
```

### Task 1: Version manifest and provenance primitives

**Files:**
- Create: `scripts/protocol_manifest.py`
- Create: `tests/test_protocol_manifest.py`

**Interfaces:**
- Produces: `sha256_file(path: Path) -> str`
- Produces: `validate_version(value: str) -> str`
- Produces: `assert_within(path: Path, root: Path) -> Path`
- Produces: `write_json_atomic(path: Path, payload: Mapping[str, object]) -> None`
- Produces: `load_json_object(path: Path) -> dict[str, object]`
- Consumes: Python 3 standard library only

- [ ] **Step 1: Write failing validation and atomic-write tests**

```python
# tests/test_protocol_manifest.py
import json
import tempfile
import unittest
from pathlib import Path

from scripts.protocol_manifest import (
    assert_within,
    sha256_file,
    validate_version,
    write_json_atomic,
)


class ProtocolManifestTests(unittest.TestCase):
    def test_hash_and_atomic_json_are_deterministic(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            source = root / "input.bin"
            source.write_bytes(b"codex\n")
            self.assertEqual(
                sha256_file(source),
                "243b0dc9b847e66c440dca985e10fe0ce9e29c379b018ddd5747ba8948f84cc8",
            )
            output = root / "manifest.json"
            write_json_atomic(output, {"version": "26.721.41059", "build": "5848"})
            self.assertEqual(
                json.loads(output.read_text(encoding="utf-8")),
                {"build": "5848", "version": "26.721.41059"},
            )
            self.assertEqual(list(root.glob(".manifest.json.*")), [])

    def test_version_and_path_boundary(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw).resolve()
            self.assertEqual(validate_version("26.721.41059"), "26.721.41059")
            self.assertEqual(assert_within(root / "26.721.41059", root), root / "26.721.41059")
            with self.assertRaises(ValueError):
                validate_version("../../outside")
            with self.assertRaises(ValueError):
                assert_within(root.parent / "outside", root)


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: Run the test and confirm the module is absent**

Run:

```bash
cd /Users/you/projects/Codex-持续更新逆向Ipad版
python3 -m unittest tests.test_protocol_manifest -v
```

Expected: FAIL with `ModuleNotFoundError: No module named 'scripts.protocol_manifest'`.

- [ ] **Step 3: Implement the manifest primitives**

```python
# scripts/protocol_manifest.py
from __future__ import annotations

import hashlib
import json
import os
import re
from pathlib import Path
from typing import Mapping

VERSION_PATTERN = re.compile(r"^[0-9]+(?:\.[0-9A-Za-z-]+)+$")


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def validate_version(value: str) -> str:
    if not VERSION_PATTERN.fullmatch(value):
        raise ValueError(f"invalid version: {value!r}")
    return value


def assert_within(path: Path, root: Path) -> Path:
    resolved_root = root.resolve()
    resolved_path = path.resolve()
    if resolved_path != resolved_root and resolved_root not in resolved_path.parents:
        raise ValueError(f"path escapes root: {resolved_path}")
    return resolved_path


def write_json_atomic(path: Path, payload: Mapping[str, object]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.{os.getpid()}")
    with temporary.open("w", encoding="utf-8") as stream:
        json.dump(payload, stream, ensure_ascii=False, indent=2, sort_keys=True)
        stream.write("\n")
        stream.flush()
        os.fsync(stream.fileno())
    os.replace(temporary, path)


def load_json_object(path: Path) -> dict[str, object]:
    payload = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(payload, dict):
        raise ValueError(f"expected JSON object: {path}")
    return payload
```

- [ ] **Step 4: Run the focused test**

Run:

```bash
python3 -m unittest tests.test_protocol_manifest -v
```

Expected: 2 tests PASS.

- [ ] **Step 5: Commit the primitives**

```bash
git add scripts/protocol_manifest.py tests/test_protocol_manifest.py
git commit -m "feat: add version manifest primitives"
```

### Task 2: Deterministic protocol file index

**Files:**
- Create: `scripts/build_protocol_index.py`
- Create: `tests/test_build_protocol_index.py`

**Interfaces:**
- Consumes: `sha256_file`, `write_json_atomic` from `scripts.protocol_manifest`
- Produces: `build_index(protocol_root: Path) -> dict[str, object]`
- Produces CLI: `python3 scripts/build_protocol_index.py --protocol-root PATH --output PATH`
- Index entry shape: `{"path": str, "kind": "typescript"|"json-schema", "channel": "stable"|"experimental", "bytes": int, "sha256": str}`

- [ ] **Step 1: Write the failing deterministic-index test**

```python
# tests/test_build_protocol_index.py
import tempfile
import unittest
from pathlib import Path

from scripts.build_protocol_index import build_index


class ProtocolIndexTests(unittest.TestCase):
    def test_index_is_sorted_and_classified(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            (root / "typescript/stable").mkdir(parents=True)
            (root / "json-schema/experimental").mkdir(parents=True)
            (root / "typescript/stable/Thread.ts").write_text(
                "export type Thread = {};\n", encoding="utf-8"
            )
            (root / "json-schema/experimental/Turn.json").write_text(
                '{"type":"object"}\n', encoding="utf-8"
            )
            index = build_index(root)
            self.assertEqual(index["fileCount"], 2)
            self.assertEqual(
                [entry["path"] for entry in index["files"]],
                [
                    "json-schema/experimental/Turn.json",
                    "typescript/stable/Thread.ts",
                ],
            )
            self.assertEqual(index["files"][0]["kind"], "json-schema")
            self.assertEqual(index["files"][1]["channel"], "stable")


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: Run the test and confirm the index module is absent**

Run:

```bash
python3 -m unittest tests.test_build_protocol_index -v
```

Expected: FAIL with `ModuleNotFoundError: No module named 'scripts.build_protocol_index'`.

- [ ] **Step 3: Implement stable scanning and CLI output**

```python
# scripts/build_protocol_index.py
from __future__ import annotations

import argparse
from pathlib import Path

from protocol_manifest import sha256_file, write_json_atomic


def build_index(protocol_root: Path) -> dict[str, object]:
    files: list[dict[str, object]] = []
    for path in sorted(item for item in protocol_root.rglob("*") if item.is_file()):
        relative = path.relative_to(protocol_root).as_posix()
        parts = relative.split("/")
        if len(parts) < 3 or parts[0] not in {"typescript", "json-schema"}:
            raise ValueError(f"unexpected protocol path: {relative}")
        if parts[1] not in {"stable", "experimental"}:
            raise ValueError(f"unexpected protocol channel: {relative}")
        files.append(
            {
                "path": relative,
                "kind": parts[0],
                "channel": parts[1],
                "bytes": path.stat().st_size,
                "sha256": sha256_file(path),
            }
        )
    if not files:
        raise ValueError(f"protocol output is empty: {protocol_root}")
    return {"schemaVersion": 1, "fileCount": len(files), "files": files}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--protocol-root", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    write_json_atomic(args.output, build_index(args.protocol_root))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
```

When imported as `scripts.build_protocol_index`, change the import line to:

```python
try:
    from .protocol_manifest import sha256_file, write_json_atomic
except ImportError:
    from protocol_manifest import sha256_file, write_json_atomic
```

- [ ] **Step 4: Run the index tests and CLI smoke check**

Run:

```bash
python3 -m unittest tests.test_build_protocol_index -v
python3 scripts/build_protocol_index.py --help
```

Expected: 1 test PASS and CLI usage exits 0.

- [ ] **Step 5: Commit the index builder**

```bash
git add scripts/build_protocol_index.py tests/test_build_protocol_index.py
git commit -m "feat: index generated protocol files"
```

### Task 3: Semantic JSON Schema compatibility classifier

**Files:**
- Create: `scripts/diff_protocol_versions.py`
- Create: `tests/fixtures/protocol-old/Request.json`
- Create: `tests/fixtures/protocol-new/Request.json`
- Create: `tests/test_diff_protocol_versions.py`

**Interfaces:**
- Produces: `compare_schema(old: object, new: object, location: str = "$") -> list[dict[str, str]]`
- Produces: `compare_directories(old_root: Path, new_root: Path) -> dict[str, object]`
- Produces CLI: `python3 scripts/diff_protocol_versions.py --old PATH --new PATH --json-out PATH --markdown-out PATH`
- Change shape: `{"severity": "breaking"|"compatible"|"informational", "kind": str, "path": str, "detail": str}`
- CLI exit: `0` without breaking changes, `2` when breaking changes exist, `1` for invalid input

- [ ] **Step 1: Create fixture schemas**

```json
// tests/fixtures/protocol-old/Request.json
{
  "type": "object",
  "required": ["threadId", "mode"],
  "properties": {
    "threadId": {"type": "string"},
    "mode": {"enum": ["read", "write"]},
    "limit": {"type": ["integer", "null"]}
  }
}
```

```json
// tests/fixtures/protocol-new/Request.json
{
  "type": "object",
  "required": ["threadId", "mode", "workspaceId"],
  "properties": {
    "threadId": {"type": "string"},
    "mode": {"enum": ["read"]},
    "workspaceId": {"type": "string"},
    "limit": {"type": "integer"},
    "cursor": {"type": ["string", "null"]}
  }
}
```

Store the files as strict JSON without the comment lines.

- [ ] **Step 2: Write the failing compatibility test**

```python
# tests/test_diff_protocol_versions.py
import unittest
from pathlib import Path

from scripts.diff_protocol_versions import compare_directories


class ProtocolDiffTests(unittest.TestCase):
    def test_breaking_and_compatible_changes_are_separated(self) -> None:
        root = Path(__file__).parent / "fixtures"
        report = compare_directories(root / "protocol-old", root / "protocol-new")
        breaking = {(item["kind"], item["path"]) for item in report["breaking"]}
        compatible = {(item["kind"], item["path"]) for item in report["compatible"]}
        self.assertIn(("required_property_added", "$.workspaceId"), breaking)
        self.assertIn(("enum_value_removed", "$.mode"), breaking)
        self.assertIn(("type_narrowed", "$.limit"), breaking)
        self.assertIn(("optional_property_added", "$.cursor"), compatible)
        self.assertTrue(report["blocked"])


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 3: Run the test and confirm the classifier is absent**

Run:

```bash
python3 -m unittest tests.test_diff_protocol_versions -v
```

Expected: FAIL with `ModuleNotFoundError: No module named 'scripts.diff_protocol_versions'`.

- [ ] **Step 4: Implement recursive compatibility rules**

Implement these exact rules in `scripts/diff_protocol_versions.py`:

```python
BREAKING_KINDS = {
    "schema_file_removed",
    "required_property_added",
    "property_removed",
    "enum_value_removed",
    "type_narrowed",
}


def normalized_types(value: object) -> set[str]:
    if isinstance(value, str):
        return {value}
    if isinstance(value, list) and all(isinstance(item, str) for item in value):
        return set(value)
    return set()
```

Directory comparison must:

1. Load every `*.json` file as an object.
2. Report missing old files as `schema_file_removed`.
3. Report new files as `schema_file_added`.
4. Recurse through `properties`, `required`, `enum`, `type`, `items`, `oneOf`, `anyOf`, `$defs` and `definitions`.
5. Treat an added property as compatible unless it also enters the parent `required` array.
6. Treat `{"integer", "null"} -> {"integer"}` as `type_narrowed`.
7. Sort all changes by `path`, then `kind`, then `detail`.
8. Emit JSON with `blocked`, `breaking`, `compatible`, `informational`, `oldFileCount`, and `newFileCount`.
9. Emit Markdown headings containing the count and one bullet per change.

- [ ] **Step 5: Run focused tests and exercise the blocking exit code**

Run:

```bash
python3 -m unittest tests.test_diff_protocol_versions -v
set +e
python3 scripts/diff_protocol_versions.py \
  --old tests/fixtures/protocol-old \
  --new tests/fixtures/protocol-new \
  --json-out /tmp/codex-protocol-diff.json \
  --markdown-out /tmp/codex-protocol-diff.md
status=$?
set -e
test "$status" -eq 2
grep -q 'required_property_added' /tmp/codex-protocol-diff.json
grep -q 'Breaking changes (3)' /tmp/codex-protocol-diff.md
```

Expected: unit test PASS, CLI returns 2, both grep checks PASS.

- [ ] **Step 6: Commit the classifier**

```bash
git add scripts/diff_protocol_versions.py tests/fixtures tests/test_diff_protocol_versions.py
git commit -m "feat: classify app-server protocol changes"
```

### Task 4: DMG-contained protocol snapshot generator

**Files:**
- Create: `scripts/generate_protocol_snapshot.sh`
- Create: `tests/test_generate_protocol_snapshot.sh`

**Interfaces:**
- Consumes CLI: `scripts/generate_protocol_snapshot.sh /absolute/path/ChatGPT.dmg`
- Consumes: `scripts/build_protocol_index.py`
- Produces: `versions/${VERSION}/manifest.json`
- Produces: `versions/${VERSION}/provenance.json`
- Produces: four protocol output directories and `protocol/index.json`
- Environment for tests only: `CODEX_PROTOCOL_APP_OVERRIDE=/absolute/path/Fake.app`

- [ ] **Step 1: Write a fake Codex CLI orchestration test**

```bash
#!/usr/bin/env bash
# tests/test_generate_protocol_snapshot.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/codex-protocol-test.XXXXXX")"
FAKE_APP="$SANDBOX/Fake.app"
mkdir -p "$FAKE_APP/Contents/Resources"
cat > "$FAKE_APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleShortVersionString</key><string>99.1.0</string>
<key>CFBundleVersion</key><string>7</string>
</dict></plist>
PLIST
cat > "$FAKE_APP/Contents/Resources/codex" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "--version" ]]; then echo "codex-cli 9.9.9"; exit 0; fi
out=""
experimental=false
while [[ $# -gt 0 ]]; do
  [[ "$1" == "--out" ]] && { out="$2"; shift 2; continue; }
  [[ "$1" == "--experimental" ]] && experimental=true
  shift
done
mkdir -p "$out"
printf '{"type":"object","experimental":%s}\n' "$experimental" > "$out/Protocol.json"
SH
chmod +x "$FAKE_APP/Contents/Resources/codex"
touch "$SANDBOX/Fake.dmg"

CODEX_PROTOCOL_APP_OVERRIDE="$FAKE_APP" \
CODEX_PROTOCOL_VERSIONS_ROOT="$SANDBOX/versions" \
  "$ROOT/scripts/generate_protocol_snapshot.sh" "$SANDBOX/Fake.dmg"

test -f "$SANDBOX/versions/99.1.0/protocol/index.json"
test -f "$SANDBOX/versions/99.1.0/protocol/json-schema/stable/Protocol.json"
test -f "$SANDBOX/versions/99.1.0/protocol/json-schema/experimental/Protocol.json"
grep -q '"cliVersion": "9.9.9"' "$SANDBOX/versions/99.1.0/provenance.json"
unlink "$SANDBOX/Fake.dmg"
```

The test owns its unique temporary directory; add a final Python `shutil.rmtree` call for that exact directory after all assertions pass.

- [ ] **Step 2: Run the Shell test and confirm the generator is absent**

Run:

```bash
bash tests/test_generate_protocol_snapshot.sh
```

Expected: FAIL because `scripts/generate_protocol_snapshot.sh` does not exist.

- [ ] **Step 3: Implement verified mounting and four generation passes**

`scripts/generate_protocol_snapshot.sh` must execute this sequence:

```text
validate absolute DMG path
resolve project and versions roots
if CODEX_PROTOCOL_APP_OVERRIDE is absent:
  hdiutil verify DMG
  hdiutil attach -readonly -nobrowse -plist DMG
  locate exactly one *.app
  codesign --verify --deep --strict App
  spctl --assess --type execute App
else:
  use the explicit test App and mark signature checks as fixture
read CFBundleShortVersionString and CFBundleVersion
run embedded codex --version
create versions/.staging-${VERSION}-${PID}
run generate-ts stable
run generate-ts --experimental
run generate-json-schema stable
run generate-json-schema --experimental
reject every empty output directory
build protocol/index.json
write manifest.json and provenance.json atomically
if versions/${VERSION} exists:
  compare DMG hash, build, CLI version, and protocol index hash
  return success only when all values match
atomically rename staging to versions/${VERSION}
detach only the mount created by this process
```

Use these output paths:

```bash
"$CODEX" app-server generate-ts \
  --out "$STAGE/protocol/typescript/stable"
"$CODEX" app-server generate-ts --experimental \
  --out "$STAGE/protocol/typescript/experimental"
"$CODEX" app-server generate-json-schema \
  --out "$STAGE/protocol/json-schema/stable"
"$CODEX" app-server generate-json-schema --experimental \
  --out "$STAGE/protocol/json-schema/experimental"
```

The manifest must contain:

```json
{
  "schemaVersion": 1,
  "version": "26.721.41059",
  "build": "5848",
  "cliVersion": "0.146.0-alpha.3.1",
  "dmgSha256": "ae864e2def7db56d0bb77a876a5cbe4e4c2f554ccc654cec921b946892583c0a",
  "protocolIndexSha256": "64位小写十六进制SHA-256",
  "signatureVerified": true,
  "gatekeeperAccepted": true
}
```

`protocolIndexSha256` 的实际值在执行时由 `protocol/index.json` 计算，生成的 manifest 必须写入对应的 64 位小写十六进制字符串。

- [ ] **Step 4: Run the fixture test twice to prove idempotency**

Run:

```bash
bash tests/test_generate_protocol_snapshot.sh
bash tests/test_generate_protocol_snapshot.sh
```

Expected: both invocations PASS; each creates and removes its own isolated fixture.

- [ ] **Step 5: Inject a fake CLI failure and verify no published directory exists**

Extend the test with a second fake CLI that exits 42 for `generate-json-schema --experimental`. Assert:

```bash
test ! -e "$FAIL_SANDBOX/versions/99.2.0"
test -d "$FAIL_SANDBOX/versions/.staging-99.2.0-"*
```

Expected: generator returns nonzero, published version is absent, staging evidence remains.

- [ ] **Step 6: Commit the snapshot generator**

```bash
git add scripts/generate_protocol_snapshot.sh tests/test_generate_protocol_snapshot.sh
git commit -m "feat: generate protocol snapshots from official dmg"
```

### Task 5: Integrate protocol generation into reverse import

**Files:**
- Modify: `scripts/import_dmg.sh`
- Create: `tests/test_import_pipeline_contract.py`

**Interfaces:**
- Consumes: `scripts/generate_protocol_snapshot.sh DMG`
- Produces: ASAR artifact plus matching `versions/${VERSION}/protocol/index.json`
- Preserves: existing `artifacts/app-asar-${VERSION}` and metadata behavior

- [ ] **Step 1: Write a static pipeline contract test**

```python
# tests/test_import_pipeline_contract.py
import unittest
from pathlib import Path


class ImportPipelineContractTests(unittest.TestCase):
    def test_reverse_import_requires_protocol_snapshot(self) -> None:
        script = (
            Path(__file__).parents[1] / "scripts/import_dmg.sh"
        ).read_text(encoding="utf-8")
        generation = script.index('"$PROTOCOL_SCRIPT" "$DMG"')
        success = script.index('echo "Imported $VERSION ($BUILD)"')
        self.assertLess(generation, success)
        self.assertIn(
            '[[ -f "$PROJECT_ROOT/versions/$VERSION/protocol/index.json" ]]',
            script,
        )


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: Run the contract test and verify it fails**

Run:

```bash
python3 -m unittest tests.test_import_pipeline_contract -v
```

Expected: FAIL because `PROTOCOL_SCRIPT` is not present.

- [ ] **Step 3: Add the protocol gate to `import_dmg.sh`**

Add near the other path declarations:

```bash
PROTOCOL_SCRIPT="$PROJECT_ROOT/scripts/generate_protocol_snapshot.sh"
```

After ASAR extraction and metadata creation, before the success messages, add:

```bash
"$PROTOCOL_SCRIPT" "$DMG"
[[ -f "$PROJECT_ROOT/versions/$VERSION/protocol/index.json" ]] || {
  echo "Protocol snapshot missing for $VERSION" >&2
  exit 70
}
```

Change the existing-version path so that an already extracted ASAR with a missing protocol snapshot runs the protocol generator instead of exiting 73.

- [ ] **Step 4: Run all first-phase unit and Shell tests**

Run:

```bash
python3 -m unittest discover -s tests -p 'test_*.py' -v
bash tests/test_generate_protocol_snapshot.sh
bash -n scripts/import_dmg.sh scripts/generate_protocol_snapshot.sh scripts/update_latest.sh
```

Expected: all Python tests PASS, Shell fixture PASS, syntax checks PASS.

- [ ] **Step 5: Commit pipeline integration**

```bash
git add scripts/import_dmg.sh tests/test_import_pipeline_contract.py
git commit -m "feat: require protocol snapshot during reverse import"
```

### Task 6: Generate and verify the real 26.721.41059 baseline

**Files:**
- Create: `versions/26.721.41059/manifest.json`
- Create: `versions/26.721.41059/provenance.json`
- Create: `versions/26.721.41059/protocol/**`
- Create: `versions/26.721.41059/compatibility-report.json`
- Create: `reports/phase-02-protocol-baseline.md`

**Interfaces:**
- Consumes: `/Users/you/Downloads/ChatGPT.dmg`
- Consumes expected DMG SHA-256: `ae864e2def7db56d0bb77a876a5cbe4e4c2f554ccc654cec921b946892583c0a`
- Produces the authoritative version contract used by the next IPC/feature-inventory plan

- [ ] **Step 1: Run the complete test suite before using the real DMG**

Run:

```bash
python3 -m unittest discover -s tests -p 'test_*.py' -v
bash tests/test_generate_protocol_snapshot.sh
bash -n scripts/*.sh
```

Expected: all tests and syntax checks PASS.

- [ ] **Step 2: Confirm the real DMG hash**

Run:

```bash
actual="$(shasum -a 256 /Users/you/Downloads/ChatGPT.dmg | awk '{print $1}')"
test "$actual" = "ae864e2def7db56d0bb77a876a5cbe4e4c2f554ccc654cec921b946892583c0a"
```

Expected: exit 0.

- [ ] **Step 3: Generate the real stable and experimental contracts**

Run:

```bash
scripts/generate_protocol_snapshot.sh /Users/you/Downloads/ChatGPT.dmg
```

Expected:

```text
version=26.721.41059
build=5848
cli=0.146.0-alpha.3.1
signature_verified=true
gatekeeper_accepted=true
published=versions/26.721.41059
```

- [ ] **Step 4: Verify the generated baseline structurally**

Run:

```bash
test -s versions/26.721.41059/protocol/index.json
test -s versions/26.721.41059/manifest.json
test -s versions/26.721.41059/provenance.json
for path in \
  protocol/typescript/stable \
  protocol/typescript/experimental \
  protocol/json-schema/stable \
  protocol/json-schema/experimental
do
  test "$(find "versions/26.721.41059/$path" -type f | wc -l | tr -d ' ')" -gt 0
done
python3 -m json.tool versions/26.721.41059/manifest.json >/dev/null
python3 -m json.tool versions/26.721.41059/provenance.json >/dev/null
python3 -m json.tool versions/26.721.41059/protocol/index.json >/dev/null
```

Expected: every assertion exits 0.

- [ ] **Step 5: Create the initial no-predecessor compatibility report**

Write `versions/26.721.41059/compatibility-report.json` as:

```json
{
  "schemaVersion": 1,
  "version": "26.721.41059",
  "predecessor": null,
  "blocked": false,
  "breaking": [],
  "compatible": [],
  "informational": [
    {
      "severity": "informational",
      "kind": "initial_baseline",
      "path": "$",
      "detail": "No predecessor has been imported; this version establishes the first protocol baseline."
    }
  ]
}
```

- [ ] **Step 6: Write the evidence report**

`reports/phase-02-protocol-baseline.md` must record:

1. DMG version, build, exact bytes and SHA-256.
2. `hdiutil`, `codesign`, Gatekeeper results.
3. Embedded CLI version.
4. Stable/experimental TypeScript and JSON Schema file counts.
5. Protocol index SHA-256.
6. Commands executed and their exit status.
7. Statement that this phase establishes protocol evidence only and does not claim an iPad build exists.

- [ ] **Step 7: Re-run generation to prove real-version idempotency**

Run:

```bash
before="$(shasum -a 256 versions/26.721.41059/protocol/index.json | awk '{print $1}')"
scripts/generate_protocol_snapshot.sh /Users/you/Downloads/ChatGPT.dmg
after="$(shasum -a 256 versions/26.721.41059/protocol/index.json | awk '{print $1}')"
test "$before" = "$after"
git status --short
```

Expected: generator reports the identical version already published; hashes match; only intended plan implementation and generated baseline files are present.

- [ ] **Step 8: Commit the authoritative baseline**

```bash
git add scripts tests versions/26.721.41059 reports/phase-02-protocol-baseline.md
git commit -m "feat: establish Codex 26.721.41059 protocol baseline"
```

## Self-Review

### Spec coverage

- Section 4.1 input coverage: official DMG, bundle metadata, signature, embedded CLI — Tasks 4 and 6.
- Section 4.2 versioned TypeScript/JSON Schema and provenance — Tasks 2, 4 and 6.
- Section 4.3 protocol field classification — Task 3.
- Section 8.2 source verification inputs relevant to this phase — Tasks 4 and 6.
- Section 9 staging, atomic publication and failure evidence — Tasks 1 and 4.
- Section 10 JSON-RPC Schema and version snapshot tests — Tasks 2 through 6.
- This plan intentionally does not claim coverage for UI, Rust Core, Tool Runtime, device installation, data migrations or the final cleanup transaction; each remains a named follow-on plan under the unchanged product specification.

### Type consistency

- All Python path inputs use `pathlib.Path`.
- JSON index entries use the same `path`, `kind`, `channel`, `bytes`, and `sha256` names in tests and implementation.
- Compatibility changes use the same `severity`, `kind`, `path`, and `detail` names across JSON, Markdown and tests.
- Version directories use `versions/${VERSION}/protocol/` consistently.

## Follow-on plan sequence

1. Electron main/preload/renderer IPC extraction and `feature-inventory.json`.
2. 官方 Codex 页面/状态参考采集、视觉基线和 1:1 同等性门禁。
3. SwiftUI iPad workspace, domain events and protocol model generation.
4. Rust Codex Core `aarch64-apple-ios` static library and stable C ABI.
5. iPad Tool Runtime: files, search, patch, libgit2, WASI and terminal.
6. SQLite persistence, migrations, snapshots and rollback readers.
7. Mac upgrade transaction: probe, download, adapt, build, test and scoped cleanup.
8. Personal signing, `devicectl` installation and real-device verification.
9. Full feature-parity matrix closure and release evidence.
