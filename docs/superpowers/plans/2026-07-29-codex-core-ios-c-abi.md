# Codex Core iOS C ABI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 建立可编译到 iPhoneOS 与 iPhoneSimulator 的独立 Rust `CodexCore` 静态库、稳定最小 C ABI、可重复生成的 XCFramework，以及由 Swift 调用的本地 ABI 冒烟事件流。

**Architecture:** Rust Core 持有每实例独立的 sequence 与事件队列，C ABI 只暴露 opaque handle、显式状态码和由 Rust 分配/释放的字节缓冲区。Swift `CodexCoreClient` 独占 handle，把 C buffer 立即复制为 `Data` 后释放，并通过一个小型 `CodexCoreTransport` 协议隔离 Presentation/Application。XCFramework 不提交 Git，由仓库脚本从相同 Rust 源码为 device 与 simulator 重建，Xcode 工程只链接生成路径。

**Tech Stack:** Rust 1.94+、Serde/serde_json、C11 ABI、cargo、rustup Apple iOS targets、lipo、xcodebuild XCFramework、Swift 6.4、Foundation、Testing、Python 3 `unittest`、Xcode 27

## Global Constraints

- 项目根目录固定为 `/Users/you/projects/Codex-持续更新逆向Ipad版`。
- 官方基线继续固定为 `26.721.41059`（build `5848`）。
- C ABI 版本从整数 `1` 开始；所有跨边界结构使用固定宽度整数与 `#[repr(C)]`。
- Rust panic、借用指针、Swift 对象、`String`、`Vec` 和异常不得越过 C ABI。
- 每个由 Rust 返回的非空 buffer 必须且只能由 `codex_core_buffer_free` 释放。
- 本阶段的 `ping`/`pong` 是 ABI 冒烟契约，不作为 Codex 功能矩阵完成证据，不创建演示 Workspace 或 Thread。
- XCFramework 输出固定为 `build/CodexCore.xcframework`，`build/` 保持 Git ignored。
- 支持 `aarch64-apple-ios`、`aarch64-apple-ios-sim`、`x86_64-apple-ios`；Simulator slice 必须为 arm64+x86_64 universal archive。
- Xcode App 继续 `TARGETED_DEVICE_FAMILY = 2`、deployment target `18.0`、bundle ID `com.mars.codexpad`、默认不签名。
- 源码、测试、日志、报告和生成物不得包含 API key、Cookie、token、签名身份、Team ID 或 provisioning profile。
- 当前无可用 Simulator device；只声明 generic Simulator 编译与 ABI 单元测试，不声明启动、截图或真机运行。

---

## File Structure

```text
CodexCore/
├── Cargo.toml
├── Cargo.lock
├── include/
│   ├── codex_core.h
│   └── module.modulemap
└── src/
    └── lib.rs
CodexPad/CodexPad/ProtocolBridge/
├── CodexCoreClient.swift
└── CodexCoreEnvelope.swift
CodexPad/Tests/CodexPadDomainTests/
└── CodexCoreEnvelopeTests.swift
scripts/
└── build_codex_core_xcframework.sh
tests/
├── test_build_codex_core_xcframework.py
└── test_generate_codexpad_xcode_project.py
reports/
└── phase-05-codex-core-ios-c-abi.md
```

### Task 1: Rust Core state and stable C ABI

**Files:**
- Create: `CodexCore/Cargo.toml`
- Create: `CodexCore/src/lib.rs`
- Create: `CodexCore/include/codex_core.h`
- Create: `CodexCore/include/module.modulemap`

**Interfaces:**
- Produces: `codex_core_abi_version() -> uint32_t`
- Produces: `codex_core_create() -> CodexCoreHandle *`
- Produces: `codex_core_destroy(CodexCoreHandle *)`
- Produces: `codex_core_submit_json(handle, bytes, length) -> CodexCoreStatus`
- Produces: `codex_core_next_event_json(handle, CodexCoreBuffer *) -> CodexCoreStatus`
- Produces: `codex_core_buffer_free(CodexCoreBuffer *)`

- [ ] **Step 1: Create the crate and write failing Rust behavior tests**

`Cargo.toml` defines package `codex-core`, library name `codex_core`, crate types `rlib` and `staticlib`, and dependencies `serde = { version = "1", features = ["derive"] }` plus `serde_json = "1"`.

In `lib.rs`, start with tests that require:

```rust
#[test]
fn ping_emits_monotonic_pong_events() {
    let mut core = CodexCore::default();
    core.submit(br#"{"kind":"ping","requestId":"one"}"#).unwrap();
    core.submit(br#"{"kind":"ping","requestId":"two"}"#).unwrap();
    assert_eq!(core.next_event().unwrap(), br#"{"sequence":1,"kind":"pong","requestId":"one"}"#);
    assert_eq!(core.next_event().unwrap(), br#"{"sequence":2,"kind":"pong","requestId":"two"}"#);
}

#[test]
fn malformed_and_unknown_commands_do_not_advance_sequence() {
    let mut core = CodexCore::default();
    assert_eq!(core.submit(b"{"), Err(CoreError::InvalidJson));
    assert_eq!(core.submit(br#"{"kind":"other","requestId":"x"}"#), Err(CoreError::UnsupportedCommand));
    core.submit(br#"{"kind":"ping","requestId":"ok"}"#).unwrap();
    assert!(core.next_event().unwrap().starts_with(br#"{"sequence":1,"#));
}
```

- [ ] **Step 2: Run the Rust tests and observe missing types**

Run: `cargo test --manifest-path CodexCore/Cargo.toml`

Expected: FAIL because `CodexCore`, `CoreError`, `submit`, and `next_event` do not exist.

- [ ] **Step 3: Implement the in-memory command/event core**

Use `VecDeque<Vec<u8>>`, a private `u64 next_sequence` initialized to 1, internally tagged Serde input/output structs, and exact input contract:

```json
{"kind":"ping","requestId":"<non-empty string>"}
```

Reject invalid UTF-8 or JSON as `InvalidJson`, empty `requestId` as `InvalidArgument`, and other `kind` values as `UnsupportedCommand`. Serialize compact JSON in field order `sequence`, `kind`, `requestId`.

- [ ] **Step 4: Add the C ABI and ABI ownership tests**

Declare:

```rust
#[repr(C)]
pub struct CodexCoreBuffer { pub ptr: *mut u8, pub len: usize, pub capacity: usize }
#[repr(i32)]
pub enum CodexCoreStatus { Ok = 0, InvalidArgument = 1, InvalidJson = 2, UnsupportedCommand = 3, NoEvent = 4, Panic = 255 }
```

All exported functions use `#[unsafe(no_mangle)] pub extern "C"`, validate null pointer/length combinations, and wrap internal work in `catch_unwind(AssertUnwindSafe(...))`. `next_event_json` transfers a `Vec<u8>` into `CodexCoreBuffer`; `buffer_free` reconstructs the `Vec` only when all fields describe a valid non-empty allocation and then zeros the struct. Add a Rust test that creates a handle, submits ping bytes through the C function, drains a buffer, checks exact bytes, frees it, checks zeroed fields, and destroys the handle.

- [ ] **Step 5: Write the matching C header and module map**

`codex_core.h` uses `stdint.h`, `stddef.h`, opaque `typedef struct CodexCoreHandle CodexCoreHandle;`, matching status constants, `CodexCoreBuffer`, `extern "C"` guards, and all six functions. `module.modulemap` is:

```text
module CCodexCore {
  header "codex_core.h"
  export *
}
```

- [ ] **Step 6: Run Rust tests and header symbol audit**

```bash
cargo test --manifest-path CodexCore/Cargo.toml
cargo build --manifest-path CodexCore/Cargo.toml --release
nm -gU CodexCore/target/release/libcodex_core.a | grep ' _codex_core_'
```

Expected: all Rust tests pass and the six exported symbols appear.

- [ ] **Step 7: Commit**

```bash
git add CodexCore
 git commit -m "feat: expose Codex Core C ABI"
```

### Task 2: Reproducible Apple XCFramework builder

**Files:**
- Create: `scripts/build_codex_core_xcframework.sh`
- Create: `tests/test_build_codex_core_xcframework.py`

**Interfaces:**
- Consumes: `CodexCore/Cargo.toml`, `CodexCore/include`
- Produces CLI: `bash scripts/build_codex_core_xcframework.sh`
- Produces: `build/CodexCore.xcframework`

- [ ] **Step 1: Write a failing script-contract test**

The Python test reads the script and asserts exact target names, `--locked --release`, `lipo -create`, `xcodebuild -create-xcframework`, both `-headers` arguments, project-root anchoring, staging under `build/.codex-core-xcframework-*`, and final atomic move to `build/CodexCore.xcframework`. It also asserts the script never writes outside project `build/` or Cargo target paths.

- [ ] **Step 2: Run the focused test and observe missing script**

Run: `python3 -m unittest tests.test_build_codex_core_xcframework -v`

Expected: FAIL because the builder script does not exist.

- [ ] **Step 3: Implement the fail-fast builder**

The script uses `set -euo pipefail`, resolves its root from `BASH_SOURCE[0]`, verifies `rustup`, `cargo`, `lipo`, and `xcodebuild`, verifies all three installed targets, builds each target with `cargo build --locked --release --manifest-path`, creates the simulator universal archive with `lipo`, calls `xcodebuild -create-xcframework` with device and simulator libraries plus `CodexCore/include`, validates `Info.plist`, moves any previous final output to the staging rollback path, and atomically renames the new framework into place. A trap restores the previous output on failure.

- [ ] **Step 4: Install missing targets and execute the real build**

```bash
rustup target add aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios
bash scripts/build_codex_core_xcframework.sh
plutil -p build/CodexCore.xcframework/Info.plist
lipo -archs build/CodexCore.xcframework/ios-arm64_x86_64-simulator/libcodex_core.a
```

Expected: device and simulator library entries exist; simulator archs are `arm64 x86_64`.

- [ ] **Step 5: Run focused and full Python tests, then commit**

```bash
python3 -m unittest tests.test_build_codex_core_xcframework -v
python3 -m unittest discover -s tests -v
 git add scripts/build_codex_core_xcframework.sh tests/test_build_codex_core_xcframework.py
 git commit -m "build: generate Codex Core XCFramework"
```

### Task 3: Swift envelope and C ABI client

**Files:**
- Create: `CodexPad/CodexPad/ProtocolBridge/CodexCoreEnvelope.swift`
- Create: `CodexPad/CodexPad/ProtocolBridge/CodexCoreClient.swift`
- Create: `CodexPad/Tests/CodexPadDomainTests/CodexCoreEnvelopeTests.swift`
- Modify: `CodexPad/Package.swift`
- Modify: `scripts/generate_codexpad_xcode_project.py`
- Modify: `tests/test_generate_codexpad_xcode_project.py`

**Interfaces:**
- Produces: `CodexCoreCommand.ping(requestID:)`
- Produces: `CodexCoreEvent(sequence:kind:requestID:)`
- Produces: `CodexCoreTransport.submit(_:)`, `nextEvent()`
- Produces: `CodexCoreClient` using `CCodexCore`

- [ ] **Step 1: Write failing Swift envelope tests**

Add a package target `CodexPadProtocolBridge` depending on `CodexPadDomain`, with path `CodexPad/ProtocolBridge` and excluding `CodexCoreClient.swift` under `SWIFT_PACKAGE` by guarding the whole client file with `#if !SWIFT_PACKAGE`. Test exact compact encoding of ping and decoding of pong sequence/request identity, plus rejection of zero sequence and non-`pong` kinds by a validating initializer.

- [ ] **Step 2: Run the focused Swift test and observe missing envelope types**

Run: `swift test --package-path CodexPad --filter codexCoreEnvelope`

Expected: FAIL because `CodexCoreCommand` and `CodexCoreEvent` do not exist.

- [ ] **Step 3: Implement Foundation-only envelope types**

Use explicit `CodingKeys` and a custom command encoder so bytes are exactly `{"kind":"ping","requestId":"..."}`. `CodexCoreEvent` decodes `sequence`, `kind`, and `requestId`, then validates `sequence > 0`, `kind == "pong"`, and non-empty request ID.

- [ ] **Step 4: Write the Swift C ABI client**

`CodexCoreTransport` is `@MainActor` and returns `CodexCoreEvent?`. `CodexCoreClient` checks `codex_core_abi_version() == 1`, creates exactly one handle, destroys it in `deinit`, maps nonzero statuses to a typed `CodexCoreClientError`, copies returned buffer bytes into `Data`, calls `codex_core_buffer_free` with `defer`, and decodes the event. It must never expose the raw handle or buffer.

- [ ] **Step 5: Write a failing Xcode generator linkage test**

Extend the Python generator test to require `CodexCore.xcframework`, `PBXFrameworksBuildPhase`, a build file in that phase, and a relative file reference `../build/CodexCore.xcframework` while preserving byte determinism.

- [ ] **Step 6: Modify the generator to link the XCFramework**

Add one stable PBX file reference for the XCFramework, one stable PBX build file, a `Frameworks` group, and a `PBXFrameworksBuildPhase` attached to `CodexPad`. Do not copy the binary into Git or the source tree.

- [ ] **Step 7: Regenerate and compile the real iPad app**

```bash
bash scripts/build_codex_core_xcframework.sh
python3 scripts/generate_codexpad_xcode_project.py --project-root CodexPad
swift test --package-path CodexPad
xcodebuild -project CodexPad/CodexPad.xcodeproj -scheme CodexPad \
  -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath DerivedData/CodexPad CODE_SIGNING_ALLOWED=NO build
```

Expected: Swift package tests pass; Xcode compiles `CodexCoreClient.swift`, imports `CCodexCore`, and links `libcodex_core.a` for both simulator architectures.

- [ ] **Step 8: Commit**

```bash
git add CodexPad scripts/generate_codexpad_xcode_project.py tests/test_generate_codexpad_xcode_project.py
 git commit -m "feat: bridge CodexPad to Rust Core"
```

### Task 4: ABI smoke executable evidence and Phase 05 report

**Files:**
- Create: `CodexCore/examples/abi_smoke.rs`
- Create: `reports/phase-05-codex-core-ios-c-abi.md`

**Interfaces:**
- Consumes: Rust C ABI, built XCFramework, Swift/Xcode build output
- Produces: executable ABI smoke evidence and Phase 05 report

- [ ] **Step 1: Write the ABI smoke example through only exported C functions**

The example creates a handle, submits `{"kind":"ping","requestId":"phase-05"}`, drains one buffer, prints its UTF-8 JSON, frees the buffer, verifies it is zeroed, verifies a second drain returns `NoEvent`, and destroys the handle. It must not instantiate private Rust core types.

- [ ] **Step 2: Run the smoke executable and exact-output assertion**

```bash
OUTPUT=$(cargo run --manifest-path CodexCore/Cargo.toml --example abi_smoke --quiet)
test "$OUTPUT" = '{"sequence":1,"kind":"pong","requestId":"phase-05"}'
```

- [ ] **Step 3: Perform a clean full verification**

Move old project-scoped `DerivedData/CodexPad` and `build/CodexCore.xcframework` aside, then run:

```bash
cargo test --manifest-path CodexCore/Cargo.toml --locked
bash scripts/build_codex_core_xcframework.sh
python3 -m unittest discover -s tests -v
swift test --package-path CodexPad
python3 scripts/generate_codexpad_xcode_project.py --project-root CodexPad
xcodebuild -project CodexPad/CodexPad.xcodeproj -scheme CodexPad \
  -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath DerivedData/CodexPad CODE_SIGNING_ALLOWED=NO build
```

Inspect XCFramework variants, static-library architectures, app metadata, and linked symbols with `nm`.

- [ ] **Step 4: Verify parity remains blocked and write the report**

The report records Rust/Python/Swift test counts, three Rust targets, ABI version and symbols, XCFramework paths/architectures/size, generic Simulator build result, `.app` path/size/version, exact smoke event, and parity blocker count. It explicitly records that ping/pong is only ABI evidence; no official feature status, Simulator evidence, device evidence, or visual evidence changes.

- [ ] **Step 5: Commit, merge locally, verify main, and clean the worktree**

```bash
git add CodexCore reports/phase-05-codex-core-ios-c-abi.md
 git commit -m "test: verify Codex Core iOS ABI baseline"
```

After fresh branch verification, fast-forward merge to `main`, repeat Rust/Python/Swift/Xcode verification from the merged tree, keep the verifiable main-project `.app` and generated XCFramework, remove only this owned `.worktrees/codex-core-ios-abi` worktree, and delete the merged feature branch.

## Self-Review

- **Spec coverage:** This plan implements implementation-sequence item 5 only: portable Rust Core state, iOS device/simulator compilation, minimal C ABI, Swift ownership wrapper, generated XCFramework, and build/smoke evidence. Item 6 (real thread/turn flow), Tool Runtime, persistence, networking, UI parity, signing, device installation, and update cleanup remain separate phases.
- **Placeholder scan:** Every task defines exact files, interfaces, failure expectations, implementation constraints, verification commands, and commit boundaries. No deferred implementation marker is used.
- **Type consistency:** `CodexCoreBuffer`, `CodexCoreStatus`, six C symbols, ABI version `1`, `CodexCoreCommand`, `CodexCoreEvent`, `CodexCoreTransport`, and `CodexCoreClient` use the same names and ownership rules across Rust, C header, module map, Swift, tests, generator, and report.
