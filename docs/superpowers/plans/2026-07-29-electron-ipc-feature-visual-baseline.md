# Codex Electron IPC、功能与视觉参考基线 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 从已验证的 `26.721.41059` Electron 构建中生成可复现的主进程/preload/renderer 文件清单、IPC 证据、界面资源与设计 token 清单、功能同等性矩阵初始版和阻断报告。

**Architecture:** Python 标准库只读取已解包 ASAR，先建立逐文件哈希与入口图，再从 Electron 构建和 renderer 资源中提取带来源位置的字符串调用证据。所有推断与直接证据分开保存；功能矩阵对尚未验证的能力保持 `unknown`，任何 `unknown`、`missing` 或 `mismatch` 都令同等性门禁失败。

**Tech Stack:** Python 3 标准库、Bash 3.2、Electron/Vite 已发布 JavaScript/CSS/HTML、`unittest`、JSON、Markdown、Git

## Global Constraints

- 项目根目录固定为 `/Users/you/projects/Codex-持续更新逆向Ipad版`。
- 官方输入固定为已验证版本 `26.721.41059`，其 DMG SHA-256 为 `ae864e2def7db56d0bb77a876a5cbe4e4c2f554ccc654cec921b946892583c0a`。
- ASAR 输入固定为 `artifacts/app-asar-26.721.41059/`，包版本必须与 `versions/26.721.41059/manifest.json` 一致。
- 官方 Codex 是唯一产品基准；功能入口、文案、图标语义、状态、顺序与操作结果不得用自定义设计替代。
- 构建产物没有 source map 时，只恢复稳定领域命名和来源映射，不声称恢复原始变量名、注释或未发布源文件。
- 直接观察证据与静态推断必须使用不同的 `evidenceKind`；静态字符串命中不得伪装成运行时验证。
- 每条证据必须包含版本、相对文件路径、SHA-256、字节偏移和命中摘要。
- `unknown`、`missing`、`mismatch`、`desktop-only-unmapped` 任一状态都必须令同等性门禁返回非零。
- 本阶段不声明 iPad App、Simulator、真机安装或完整 1:1 同等性。
- 源码、索引、日志、报告和 Git 中不得记录 API key、会话 token、Cookie、签名私钥或 provisioning profile 内容。

---

## File Structure

```text
scripts/
├── electron_bundle_inventory.py       # 校验 ASAR 版本并生成入口、哈希和资源类型清单
├── javascript_string_scanner.py       # 无求值扫描 JS 字符串及其精确字节偏移
├── extract_electron_ipc.py            # 从 main/preload/renderer 生成 IPC 证据与配对状态
├── extract_visual_reference.py        # 提取 HTML 入口、CSS token、字体、图标与媒体资源
├── build_feature_inventory.py         # 汇总协议、IPC、视觉证据并生成同等性矩阵
└── check_parity_gate.py               # 对矩阵执行显式失败门禁
tests/
├── fixtures/electron-mini/             # 最小 main/preload/renderer/CSS/HTML 构建
├── test_electron_bundle_inventory.py
├── test_javascript_string_scanner.py
├── test_extract_electron_ipc.py
├── test_extract_visual_reference.py
├── test_build_feature_inventory.py
└── test_check_parity_gate.py
versions/26.721.41059/
├── electron/bundle-index.json
├── electron/ipc-inventory.json
├── visual/reference-inventory.json
└── feature-inventory.json
reports/phase-03-electron-reference-baseline.md
```

### Task 1: Electron bundle identity and deterministic index

**Files:**
- Create: `scripts/electron_bundle_inventory.py`
- Create: `tests/test_electron_bundle_inventory.py`

**Interfaces:**
- Consumes: `scripts.protocol_manifest.sha256_file`, `write_json_atomic`
- Produces: `build_bundle_inventory(asar_root: Path, expected_version: str) -> dict[str, object]`
- Produces CLI: `python3 scripts/electron_bundle_inventory.py --asar-root PATH --expected-version VERSION --output PATH`
- Index entry shape: `{"path": str, "bytes": int, "sha256": str, "role": str}`

- [ ] **Step 1: Write the failing identity and stable-order tests**

```python
from pathlib import Path
import json

from scripts.electron_bundle_inventory import build_bundle_inventory


def test_bundle_version_entries_and_roles(tmp_path: Path) -> None:
    (tmp_path / ".vite/build").mkdir(parents=True)
    (tmp_path / "webview/assets").mkdir(parents=True)
    (tmp_path / "package.json").write_text(
        json.dumps({"version": "26.721.41059", "main": ".vite/build/early-bootstrap.js"}),
        encoding="utf-8",
    )
    (tmp_path / ".vite/build/early-bootstrap.js").write_text(
        'import("./main-A.js");\n', encoding="utf-8"
    )
    (tmp_path / ".vite/build/preload.js").write_text("bridge();\n", encoding="utf-8")
    (tmp_path / "webview/index.html").write_text(
        '<script type="module" src="./assets/index-A.js"></script>', encoding="utf-8"
    )
    (tmp_path / "webview/assets/index-A.js").write_text("render();\n", encoding="utf-8")
    result = build_bundle_inventory(tmp_path, "26.721.41059")
    assert result["version"] == "26.721.41059"
    assert [entry["path"] for entry in result["files"]] == sorted(
        entry["path"] for entry in result["files"]
    )
    roles = {entry["path"]: entry["role"] for entry in result["files"]}
    assert roles[".vite/build/early-bootstrap.js"] == "electron-entry"
    assert roles[".vite/build/preload.js"] == "preload"
    assert roles["webview/index.html"] == "renderer-html"
```

- [ ] **Step 2: Run the focused test and observe `ModuleNotFoundError`**

Run: `python3 -m unittest tests.test_electron_bundle_inventory -v`

- [ ] **Step 3: Implement strict package validation and deterministic indexing**

Implement `build_bundle_inventory` with these exact rules:

```python
package = json.loads((asar_root / "package.json").read_text(encoding="utf-8"))
if package.get("version") != expected_version:
    raise ValueError("ASAR package version does not match protocol manifest")
main = package.get("main")
if not isinstance(main, str) or not (asar_root / main).is_file():
    raise ValueError("Electron main entry is missing")
```

Classify `.vite/build/early-bootstrap.js` as `electron-entry`, names containing `preload` as `preload`, `.vite/build/*.js` as `electron-main`, `webview/index.html` as `renderer-html`, `webview/assets/*.css` as `renderer-style`, `webview/assets/*.js` as `renderer-script`, and all remaining files as `resource`. Emit sorted entries and summary counts.

- [ ] **Step 4: Run focused and full tests**

Run:

```bash
python3 -m unittest tests.test_electron_bundle_inventory -v
python3 -m unittest discover -s tests -v
```

- [ ] **Step 5: Commit**

```bash
git add scripts/electron_bundle_inventory.py tests/test_electron_bundle_inventory.py
git commit -m "feat: index Electron release bundles"
```

### Task 2: JavaScript literal scanner with byte provenance

**Files:**
- Create: `scripts/javascript_string_scanner.py`
- Create: `tests/test_javascript_string_scanner.py`

**Interfaces:**
- Produces: `JavaScriptString(value: str, quote: str, start: int, end: int)`
- Produces: `scan_javascript_strings(source: bytes) -> list[JavaScriptString]`
- Scanner decodes single-quoted, double-quoted and template literals without executing JavaScript.

- [ ] **Step 1: Write scanner tests for escapes, comments and offsets**

```python
from scripts.javascript_string_scanner import scan_javascript_strings


def test_scanner_preserves_offsets_and_ignores_comments() -> None:
    source = b'// "ignored"\\nconst a="codex:open"; const b=\\'thread\\\\/start\\';'
    strings = scan_javascript_strings(source)
    assert [item.value for item in strings] == ["codex:open", "thread/start"]
    for item in strings:
        assert source[item.start:item.end].decode().startswith(item.quote)


def test_dynamic_template_is_not_reported_as_static() -> None:
    source = b"const a=`fixed-channel`; const b=`thread/${id}`;"
    assert [item.value for item in scan_javascript_strings(source)] == ["fixed-channel"]
```

- [ ] **Step 2: Run and observe the missing scanner failure**

Run: `python3 -m unittest tests.test_javascript_string_scanner -v`

- [ ] **Step 3: Implement a single-pass lexical state machine**

The state machine must:

1. skip `//` and `/* ... */` comments;
2. enter strings only on `'`, `"` or backtick;
3. decode `\\n`, `\\r`, `\\t`, `\\\\`, escaped quote, `\\/`, `\\xNN` and `\\uNNNN`;
4. reject template strings containing an unescaped `${`;
5. store byte offsets spanning the quotes;
6. raise `ValueError` for unterminated strings instead of returning partial evidence.

- [ ] **Step 4: Run scanner and full tests**

Run:

```bash
python3 -m unittest tests.test_javascript_string_scanner -v
python3 -m unittest discover -s tests -v
```

- [ ] **Step 5: Commit**

```bash
git add scripts/javascript_string_scanner.py tests/test_javascript_string_scanner.py
git commit -m "feat: scan JavaScript literals with provenance"
```

### Task 3: Electron IPC evidence extraction and pairing

**Files:**
- Create: `scripts/extract_electron_ipc.py`
- Create: `tests/fixtures/electron-mini/.vite/build/main-A.js`
- Create: `tests/fixtures/electron-mini/.vite/build/preload.js`
- Create: `tests/fixtures/electron-mini/webview/assets/index-A.js`
- Create: `tests/test_extract_electron_ipc.py`

**Interfaces:**
- Consumes: `scan_javascript_strings`, `sha256_file`, `write_json_atomic`
- Produces: `extract_ipc_inventory(asar_root: Path, version: str) -> dict[str, object]`
- Evidence shape: `{"channel": str, "side": "main"|"preload"|"renderer", "operation": str, "file": str, "fileSha256": str, "byteOffset": int, "evidenceKind": "static-callsite"}`
- Channel shape: `{"channel": str, "mainOperations": list[str], "preloadOperations": list[str], "rendererOperations": list[str], "pairing": "paired"|"main-only"|"client-only"}`

- [ ] **Step 1: Add a miniature bundle and failing extraction test**

Fixture contents:

```javascript
// .vite/build/main-A.js
ipcMain.handle("workspace:read", readWorkspace);
ipcMain.on("window:close", closeWindow);
```

```javascript
// .vite/build/preload.js
contextBridge.exposeInMainWorld("codex", {
  read: () => ipcRenderer.invoke("workspace:read"),
  close: () => ipcRenderer.send("window:close"),
});
```

```javascript
// webview/assets/index-A.js
window.codex.read();
```

Test:

```python
from pathlib import Path
from scripts.extract_electron_ipc import extract_ipc_inventory


def test_ipc_channels_are_paired_with_source_evidence() -> None:
    root = Path("tests/fixtures/electron-mini")
    inventory = extract_ipc_inventory(root, "test")
    channels = {item["channel"]: item for item in inventory["channels"]}
    assert channels["workspace:read"]["pairing"] == "paired"
    assert channels["window:close"]["pairing"] == "paired"
    assert all(item["fileSha256"] for item in inventory["evidence"])
    assert all(item["byteOffset"] >= 0 for item in inventory["evidence"])
```

- [ ] **Step 2: Run and observe the missing extractor failure**

Run: `python3 -m unittest tests.test_extract_electron_ipc -v`

- [ ] **Step 3: Implement callsite extraction**

For every build JS file, inspect a 160-byte ASCII window before each scanned literal and classify the nearest call:

```text
ipcMain.handle(       -> side=main, operation=handle
ipcMain.on(           -> side=main, operation=on
ipcRenderer.invoke(   -> side=preload, operation=invoke
ipcRenderer.send(     -> side=preload, operation=send
ipcRenderer.on(       -> side=preload, operation=on
contextBridge.exposeInMainWorld( -> side=preload, operation=expose
```

Only accept channel strings matching `^[A-Za-z0-9][A-Za-z0-9._:/-]{1,159}$`. Deduplicate exact evidence tuples, sort by channel/file/offset, and classify `paired` only when a main handler/listener and preload invoke/send exist for the same channel.

- [ ] **Step 4: Run focused and full tests**

Run:

```bash
python3 -m unittest tests.test_extract_electron_ipc -v
python3 -m unittest discover -s tests -v
```

- [ ] **Step 5: Commit**

```bash
git add scripts/extract_electron_ipc.py tests/fixtures/electron-mini tests/test_extract_electron_ipc.py
git commit -m "feat: recover Electron IPC evidence"
```

### Task 4: Renderer visual-reference inventory

**Files:**
- Create: `scripts/extract_visual_reference.py`
- Create: `tests/fixtures/electron-mini/webview/index.html`
- Create: `tests/fixtures/electron-mini/webview/assets/app.css`
- Create: `tests/test_extract_visual_reference.py`

**Interfaces:**
- Produces: `extract_visual_reference(webview_root: Path, version: str) -> dict[str, object]`
- Token shape: `{"name": str, "value": str, "file": str, "fileSha256": str, "byteOffset": int}`
- Resource shape: `{"path": str, "kind": "font"|"icon"|"image"|"audio"|"video"|"wasm"|"document"|"other", "bytes": int, "sha256": str}`

- [ ] **Step 1: Add HTML/CSS fixture and failing test**

```css
:root {
  --background: #ffffff;
  --foreground: #0d0d0d;
  --sidebar-width: 260px;
}
@font-face { font-family: "Codex Sans"; src: url("./codex.woff2"); }
```

```python
from pathlib import Path
from scripts.extract_visual_reference import extract_visual_reference


def test_visual_tokens_and_entry_assets_keep_provenance() -> None:
    result = extract_visual_reference(
        Path("tests/fixtures/electron-mini/webview"), "test"
    )
    tokens = {item["name"]: item["value"] for item in result["cssTokens"]}
    assert tokens["--background"] == "#ffffff"
    assert tokens["--sidebar-width"] == "260px"
    assert result["html"]["title"] == "Codex"
    assert result["html"]["moduleEntries"] == ["assets/index-A.js"]
```

- [ ] **Step 2: Run and observe the missing visual extractor failure**

Run: `python3 -m unittest tests.test_extract_visual_reference -v`

- [ ] **Step 3: Implement deterministic HTML, CSS and resource extraction**

Use `html.parser.HTMLParser` for title, module scripts, stylesheets and preload links. Scan CSS custom properties with `(?m)(--[a-zA-Z0-9_-]+)\\s*:\\s*([^;{}]+);`, retain every occurrence with byte offset, and separately emit conflicts when the same token has different values. Hash all webview resources and classify by suffix; do not copy or transform official assets.

- [ ] **Step 4: Run focused and full tests**

Run:

```bash
python3 -m unittest tests.test_extract_visual_reference -v
python3 -m unittest discover -s tests -v
```

- [ ] **Step 5: Commit**

```bash
git add scripts/extract_visual_reference.py tests/fixtures/electron-mini tests/test_extract_visual_reference.py
git commit -m "feat: inventory Codex visual references"
```

### Task 5: Feature parity matrix and explicit failure gate

**Files:**
- Create: `scripts/build_feature_inventory.py`
- Create: `scripts/check_parity_gate.py`
- Create: `tests/test_build_feature_inventory.py`
- Create: `tests/test_check_parity_gate.py`

**Interfaces:**
- Produces: `build_feature_inventory(version: str, protocol_index: dict, ipc_inventory: dict, visual_inventory: dict) -> dict[str, object]`
- Produces: `check_parity(feature_inventory: dict) -> list[dict[str, str]]`
- Feature shape: `{"id": str, "name": str, "category": str, "desktopEvidence": list[dict], "protocolDependencies": list[str], "ipcDependencies": list[str], "ipadModule": str | None, "automatedTests": list[str], "simulatorEvidence": list[str], "deviceEvidence": list[str], "visualEvidence": list[str], "status": str}`
- CLI gate returns `0` only when every feature is `matched`; otherwise returns `2`.

- [ ] **Step 1: Write failing matrix and gate tests**

```python
from scripts.check_parity_gate import check_parity


def test_unknown_and_mismatch_are_blocking() -> None:
    inventory = {
        "features": [
            {"id": "thread.list", "status": "matched"},
            {"id": "tool.approval", "status": "unknown"},
            {"id": "workspace.git", "status": "mismatch"},
        ]
    }
    blockers = check_parity(inventory)
    assert [(item["id"], item["status"]) for item in blockers] == [
        ("tool.approval", "unknown"),
        ("workspace.git", "mismatch"),
    ]
```

The builder test must assert that protocol groups create deterministic initial feature rows for `account`, `apps`, `config`, `environment`, `fs`, `mcp`, `model`, `plugin`, `process`, `remote-control`, `review`, `skills`, `thread`, `turn`, and `workspace`, and that every initial row has `status == "unknown"` with nonempty desktop evidence.

- [ ] **Step 2: Run and observe both missing-module failures**

Run:

```bash
python3 -m unittest tests.test_build_feature_inventory -v
python3 -m unittest tests.test_check_parity_gate -v
```

- [ ] **Step 3: Implement deterministic grouping and the blocking CLI**

Derive feature IDs from stable and experimental `v2/*.json` protocol filenames by splitting PascalCase method names into lower kebab-case and grouping by the fixed categories above. Attach matching IPC evidence when a normalized channel contains the feature stem. Initial `ipadModule`, tests and runtime evidence arrays remain empty and status remains `unknown`; this is an explicit measured gap, not a completed feature.

- [ ] **Step 4: Run focused/full tests and verify gate exit `2`**

Run:

```bash
python3 -m unittest tests.test_build_feature_inventory tests.test_check_parity_gate -v
python3 -m unittest discover -s tests -v
python3 scripts/check_parity_gate.py versions/26.721.41059/feature-inventory.json
```

Expected: unit tests PASS; the real parity command exits `2` and lists every non-`matched` feature.

- [ ] **Step 5: Commit**

```bash
git add scripts/build_feature_inventory.py scripts/check_parity_gate.py tests/test_build_feature_inventory.py tests/test_check_parity_gate.py
git commit -m "feat: establish explicit Codex parity gate"
```

### Task 6: Generate the `26.721.41059` Electron reference baseline

**Files:**
- Create: `versions/26.721.41059/electron/bundle-index.json`
- Create: `versions/26.721.41059/electron/ipc-inventory.json`
- Create: `versions/26.721.41059/visual/reference-inventory.json`
- Create: `versions/26.721.41059/feature-inventory.json`
- Create: `reports/phase-03-electron-reference-baseline.md`

**Interfaces:**
- Consumes every CLI from Tasks 1–5
- Produces immutable version evidence for the Swift/Rust/iPad implementation plans

- [ ] **Step 1: Run all tests and syntax checks**

```bash
python3 -m unittest discover -s tests -v
python3 -m py_compile scripts/*.py tests/test_*.py
git diff --check
```

- [ ] **Step 2: Generate the four versioned inventories**

```bash
python3 scripts/electron_bundle_inventory.py \
  --asar-root artifacts/app-asar-26.721.41059 \
  --expected-version 26.721.41059 \
  --output versions/26.721.41059/electron/bundle-index.json
python3 scripts/extract_electron_ipc.py \
  --asar-root artifacts/app-asar-26.721.41059 \
  --version 26.721.41059 \
  --output versions/26.721.41059/electron/ipc-inventory.json
python3 scripts/extract_visual_reference.py \
  --webview-root artifacts/app-asar-26.721.41059/webview \
  --version 26.721.41059 \
  --output versions/26.721.41059/visual/reference-inventory.json
python3 scripts/build_feature_inventory.py \
  --version 26.721.41059 \
  --protocol-index versions/26.721.41059/protocol/index.json \
  --ipc-inventory versions/26.721.41059/electron/ipc-inventory.json \
  --visual-inventory versions/26.721.41059/visual/reference-inventory.json \
  --output versions/26.721.41059/feature-inventory.json
```

- [ ] **Step 3: Verify source identity and inventory structure**

Run a Python assertion that checks:

```python
assert bundle["version"] == protocol_manifest["version"] == "26.721.41059"
assert bundle["package"]["main"] == ".vite/build/early-bootstrap.js"
assert bundle["fileCount"] >= 5900
assert ipc["evidence"]
assert visual["resources"]
assert features["features"]
assert all(item["desktopEvidence"] for item in features["features"])
```

- [ ] **Step 4: Write the phase report**

`reports/phase-03-electron-reference-baseline.md` must record:

- ASAR package version and main entry;
- total indexed files and bytes;
- Electron main/preload/renderer counts;
- IPC evidence count, paired/main-only/client-only channel counts;
- renderer script/style/font/icon/image/media counts;
- CSS token count and conflicting token count;
- feature count by category and parity blocker count;
- exact inventory SHA-256 values;
- test commands and exit statuses;
- explicit statement that static evidence is not runtime observation and that no iPad build exists yet.

- [ ] **Step 5: Verify reproducibility and commit**

Regenerate all four JSON files, compare their SHA-256 values before/after, run the full suite again, then:

```bash
git add scripts tests versions/26.721.41059/electron \
  versions/26.721.41059/visual versions/26.721.41059/feature-inventory.json \
  reports/phase-03-electron-reference-baseline.md
git commit -m "feat: establish Codex Electron reference baseline"
```

## Self-Review

- Spec coverage: this plan covers Electron main/preload/renderer inputs, package/resource provenance, IPC recovery, visual resources, initial feature matrix and explicit parity failure. Runtime screenshots, SwiftUI, Rust Core, Tool Runtime, signing and device installation remain in their own subsequent plans.
- Placeholder scan: no deferred implementation marker is used; every extractor has exact input, output, validation rule, test and command.
- Type consistency: `version`, `fileSha256`, `byteOffset`, `evidenceKind`, `status` and feature evidence arrays retain identical names across producer, gate and versioned output.
