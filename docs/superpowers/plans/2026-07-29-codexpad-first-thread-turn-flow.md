# CodexPad First Thread/Turn Flow Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the Phase 05 ping-only path with the first user-operable local workspace, thread, and turn flow whose Rust events are consumed by the existing Swift domain reducer.

**Architecture:** Rust remains the authoritative command validator, sequence allocator, and event queue. Its JSON events map one-to-one to existing Swift `DomainEvent` payloads; `CodexCoreClient` copies and decodes each C buffer, while `CodexSessionStore` submits typed commands and drains events through the reducer. SwiftUI gathers only user-entered workspace/thread/message values and never manufactures demonstration rows or assistant output.

**Tech Stack:** Rust 1.94, Serde/serde_json, C ABI version 1, Swift 6.4, Foundation, Observation, SwiftUI, Testing, Python `unittest`, Xcode 27

## Global Constraints

- Project root is `/Users/you/projects/Codex-持续更新逆向Ipad版`.
- Official reference remains `26.721.41059` build `5848`.
- Preserve all Phase 05 C function signatures, status values, buffer ownership, and ABI version `1`.
- Preserve the exact ping/pong smoke contract.
- Commands accept caller-supplied UUID strings and never generate fake entities or assistant content.
- `workspace.open` emits one workspace event; `thread.start` emits one thread event; `turn.start` emits a running turn followed by the user's message; `turn.complete` emits caller-supplied assistant text followed by completed status.
- Reject missing references and duplicate workspace/thread/turn/item IDs before enqueuing any partial event batch.
- Swift UI consumes only `CodexSessionStore.state`; it does not read C buffers or Rust state.
- Do not add persistence, network/model calls, tool execution, signing, or device-install claims in this phase.
- Keep `TARGETED_DEVICE_FAMILY = 2`, deployment target `18.0`, bundle ID `com.mars.codexpad`, and unsigned default builds.
- No credential, token, Cookie, signing identity, Team ID, or provisioning profile may enter source, logs, fixtures, or reports.
- Existing feature-inventory rows remain `unknown` until Simulator, physical-device, and protocol-parity evidence exists.

---

## File Structure

```text
CodexCore/
├── src/
│   ├── lib.rs
│   └── session.rs
└── examples/
    └── thread_turn_smoke.rs
CodexPad/CodexPad/
├── Application/CodexSessionStore.swift
├── ProtocolBridge/
│   ├── CodexCoreClient.swift
│   └── CodexCoreEnvelope.swift
└── Presentation/
    ├── CodexRootView.swift
    ├── ThreadDetailView.swift
    ├── ThreadListView.swift
    └── WorkspaceSidebar.swift
CodexPad/Tests/CodexPadDomainTests/
├── CodexCoreEnvelopeTests.swift
└── CodexCoreFlowStoreTests.swift
reports/
└── phase-06-first-thread-turn-flow.md
```

### Task 1: Atomic Rust session commands and domain events

**Files:**
- Create: `CodexCore/src/session.rs`
- Modify: `CodexCore/src/lib.rs`

**Interfaces:**
- Consumes: existing `CodexCore::submit`, event queue, and exported C ABI.
- Produces commands:
  - `workspace.open(workspace)`
  - `thread.start(thread)`
  - `turn.start(turn, userItem)`
  - `turn.complete(turnId, assistantItem)`
- Produces event kinds:
  - `workspaceUpserted`
  - `threadUpserted`
  - `turnStarted`
  - `itemAppended`
  - `turnStatusChanged`

- [ ] **Step 1: Write failing Rust tests for the complete local flow**

Add tests using fixed UUID strings. The expected queue is:

```json
{"sequence":1,"kind":"workspaceUpserted","workspace":{"id":"00000000-0000-0000-0000-000000000001","displayName":"Mars","rootBookmarkId":null}}
{"sequence":2,"kind":"threadUpserted","thread":{"id":"00000000-0000-0000-0000-000000000002","workspaceId":"00000000-0000-0000-0000-000000000001","title":"First task"}}
{"sequence":3,"kind":"turnStarted","turn":{"id":"00000000-0000-0000-0000-000000000003","threadId":"00000000-0000-0000-0000-000000000002","status":"running"}}
{"sequence":4,"kind":"itemAppended","item":{"id":"00000000-0000-0000-0000-000000000004","threadId":"00000000-0000-0000-0000-000000000002","turnId":"00000000-0000-0000-0000-000000000003","kind":"userMessage","text":"Inspect this project"}}
{"sequence":5,"kind":"itemAppended","item":{"id":"00000000-0000-0000-0000-000000000005","threadId":"00000000-0000-0000-0000-000000000002","turnId":"00000000-0000-0000-0000-000000000003","kind":"assistantMessage","text":"Project inspection complete"}}
{"sequence":6,"kind":"turnStatusChanged","turnId":"00000000-0000-0000-0000-000000000003","status":"completed"}
```

Add rejection tests proving an unknown workspace, duplicate ID, empty title,
empty user text, and invalid UUID leave both sequence and event queue
unchanged.

- [ ] **Step 2: Run focused Rust tests and observe unsupported commands**

Run:

```bash
cargo test --manifest-path CodexCore/Cargo.toml session_flow -- --nocapture
```

Expected: FAIL because only `ping` is accepted.

- [ ] **Step 3: Implement focused wire/session types**

`session.rs` defines private Serde wire structures plus a `SessionIndex`
containing `HashSet<String>` values for workspace, thread, turn, and item IDs.
It validates UUID syntax without adding a dependency by requiring the canonical
ASCII `8-4-4-4-12` hex layout. Each accepted command first validates the entire
batch, then mutates the index and returns `Vec<Vec<u8>>`; serialization occurs
before any sequence or queue mutation.

`CodexCore::submit` retains the ping path and delegates the four new tagged
commands. It assigns consecutive sequence values only after validation,
appends the complete event batch, and cannot expose a partially committed turn.

- [ ] **Step 4: Run Rust and C ABI regressions**

```bash
cargo fmt --manifest-path CodexCore/Cargo.toml --check
cargo test --manifest-path CodexCore/Cargo.toml --locked
cargo run --manifest-path CodexCore/Cargo.toml --example abi_smoke --quiet
```

Expected: all Rust tests pass and ping output remains byte-identical.

- [ ] **Step 5: Commit**

```bash
git add CodexCore/src
git commit -m "feat: add atomic Core thread turn flow"
```

### Task 2: Swift command and domain-event envelopes

**Files:**
- Modify: `CodexPad/CodexPad/ProtocolBridge/CodexCoreEnvelope.swift`
- Modify: `CodexPad/CodexPad/ProtocolBridge/CodexCoreClient.swift`
- Modify: `CodexPad/Tests/CodexPadDomainTests/CodexCoreEnvelopeTests.swift`

**Interfaces:**
- Produces `CodexCoreCommand.openWorkspace(_:)`.
- Produces `CodexCoreCommand.startThread(_:)`.
- Produces `CodexCoreCommand.startTurn(_:userItem:)`.
- Produces `CodexCoreCommand.completeTurn(turnID:assistantItem:)`.
- Produces `CodexCoreEvent.pong(sequence:requestID:)` and
  `CodexCoreEvent.domain(DomainEvent)`.

- [ ] **Step 1: Write failing encoding and decoding tests**

Use fixed UUIDs and assert:

```swift
try CodexCoreCommand.openWorkspace(workspace).encodedData()
try CodexCoreCommand.startThread(thread).encodedData()
try CodexCoreCommand.startTurn(turn, userItem: userItem).encodedData()
try CodexCoreCommand.completeTurn(
    turnID: turn.id,
    assistantItem: assistantItem
).encodedData()
```

decode to the exact corresponding `DomainEvent` values at sequences 1 through
6. Also assert malformed UUID, unsupported event kind, zero sequence, and an
invalid status throw `CodexCoreEnvelopeError`.

- [ ] **Step 2: Run the focused Swift tests and observe missing cases**

```bash
swift test --package-path CodexPad --filter codexCoreEnvelope
```

Expected: FAIL because the new command/event cases do not exist.

- [ ] **Step 3: Implement deterministic command encoding**

Encode typed `CodexPadDomain` values with private `Encodable` wire structs and
explicit `CodingKeys`. Use `JSONEncoder.outputFormatting = [.sortedKeys]` for
the new commands; preserve the existing hand-built compact ping bytes. Validate
all text and identity invariants before encoding.

- [ ] **Step 4: Implement validated event decoding**

Change `CodexCoreEvent` to an enum. Its `init(data:)` first decodes a header
containing `sequence` and `kind`, then decodes exactly one typed payload and
constructs an existing `DomainEvent`. `CodexCoreClient.nextEvent()` calls this
initializer after copying and freeing the Rust buffer.

- [ ] **Step 5: Run Swift tests and commit**

```bash
swift test --package-path CodexPad
git add CodexPad/CodexPad/ProtocolBridge \
  CodexPad/Tests/CodexPadDomainTests/CodexCoreEnvelopeTests.swift
git commit -m "feat: decode Core domain events in Swift"
```

### Task 3: Store transport submission and ordered draining

**Files:**
- Modify: `CodexPad/Package.swift`
- Modify: `CodexPad/CodexPad/Application/CodexSessionStore.swift`
- Create: `CodexPad/Tests/CodexPadDomainTests/CodexCoreFlowStoreTests.swift`

**Interfaces:**
- `CodexSessionStore.init(state:transport:)`
- `openWorkspace(id:displayName:rootBookmarkID:)`
- `startThread(id:workspaceID:title:)`
- `startTurn(id:threadID:itemID:text:)`
- `completeTurn(id:itemID:text:)`
- `lastTransportProblem: String?`

- [ ] **Step 1: Add the package dependency and failing fake-transport tests**

Make `CodexPadApplication` depend on both `CodexPadDomain` and
`CodexPadProtocolBridge`. A `@MainActor` fake transport records submitted
commands and returns queued `CodexCoreEvent` values.

Test that `openWorkspace`, `startThread`, and `startTurn` submit exactly one
typed command each, drain all returned domain events, advance
`lastAppliedSequence` to `4`, select the new workspace/thread, and preserve the
user's text. Test that pong is ignored and a sequence gap is exposed through
the existing reducer problem.

- [ ] **Step 2: Run focused tests and observe missing store APIs**

```bash
swift test --package-path CodexPad --filter codexCoreFlowStore
```

Expected: FAIL because the store has no transport or submission methods.

- [ ] **Step 3: Implement submit-and-drain**

Store the transport as `private let transport: (any CodexCoreTransport)?`.
Each public operation constructs domain values from its arguments, submits one
command, then drains until `nextEvent()` returns nil. Apply `.domain` events in
order and ignore `.pong`. On thrown transport errors set
`lastTransportProblem = String(describing: error)` and rethrow; do not mutate
selection before the matching domain event has applied.

- [ ] **Step 4: Run all Swift tests and commit**

```bash
swift test --package-path CodexPad
git add CodexPad/Package.swift \
  CodexPad/CodexPad/Application/CodexSessionStore.swift \
  CodexPad/Tests/CodexPadDomainTests/CodexCoreFlowStoreTests.swift
git commit -m "feat: drive session store from Core transport"
```

### Task 4: User-operated workspace, thread, and composer controls

**Files:**
- Modify: `CodexPad/CodexPad/App/CodexPadApp.swift`
- Modify: `CodexPad/CodexPad/Presentation/CodexRootView.swift`
- Modify: `CodexPad/CodexPad/Presentation/WorkspaceSidebar.swift`
- Modify: `CodexPad/CodexPad/Presentation/ThreadListView.swift`
- Modify: `CodexPad/CodexPad/Presentation/ThreadDetailView.swift`

**Interfaces:**
- App creates one `CodexCoreClient` and injects it into one session store.
- Workspace and thread creation use user-entered names.
- Composer uses user-entered non-whitespace text and caller-created UUIDs.

- [ ] **Step 1: Add failing source-contract assertions**

Extend `tests/test_generate_codexpad_xcode_project.py` to assert the discovered
app sources contain `CodexCoreClient`, `openWorkspace`, `startThread`, and
`startTurn`, and that `ThreadDetailView` no longer contains
`.disabled(true)`. Keep the generator byte-determinism test.

- [ ] **Step 2: Run the focused Python test and observe disabled controls**

```bash
python3 -m unittest tests.test_generate_codexpad_xcode_project -v
```

Expected: FAIL because the app does not instantiate the client and the composer
is still permanently disabled.

- [ ] **Step 3: Wire the live Core and explicit creation sheets**

`CodexPadApp` constructs `CodexCoreClient` once and injects it into
`CodexSessionStore`; initialization failure is retained in
`lastTransportProblem`.

`CodexRootView` owns workspace/thread creation sheet state. The sidebar and
thread list expose plus buttons only; submitting a trimmed non-empty user value
calls the corresponding store method with a new UUID. No workspace, thread, or
message is created without a user action.

`ThreadDetailView` accepts an `onSubmit: (String) -> Void` closure. Its send
button is enabled only when a thread exists and the trimmed draft is non-empty;
after a successful submission it clears the draft. The Core emits the running
turn and user item, so the existing reducer and list rendering remain the only
UI data source.

- [ ] **Step 4: Regenerate and compile both Apple variants**

```bash
bash scripts/build_codex_core_xcframework.sh
python3 scripts/generate_codexpad_xcode_project.py --project-root CodexPad
python3 -m unittest discover -s tests -v
swift test --package-path CodexPad
xcodebuild -project CodexPad/CodexPad.xcodeproj -scheme CodexPad \
  -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath DerivedData/CodexPad CODE_SIGNING_ALLOWED=NO build
xcodebuild -project CodexPad/CodexPad.xcodeproj -scheme CodexPad \
  -sdk iphoneos -destination 'generic/platform=iOS' \
  -derivedDataPath DerivedData/CodexPadDevice CODE_SIGNING_ALLOWED=NO build
```

Expected: all tests and both unsigned generic builds succeed.

- [ ] **Step 5: Commit**

```bash
git add CodexPad tests/test_generate_codexpad_xcode_project.py
git commit -m "feat: expose first local CodexPad session flow"
```

### Task 5: Exported-ABI flow smoke and Phase 06 evidence

**Files:**
- Create: `CodexCore/examples/thread_turn_smoke.rs`
- Create: `reports/phase-06-first-thread-turn-flow.md`

**Interfaces:**
- Consumes only the six existing C ABI functions.
- Produces six exact JSON event lines and one deterministic state-flow report.

- [ ] **Step 1: Write the C ABI flow smoke**

Submit the four commands from Task 1 through `codex_core_submit_json`, drain six
buffers through `codex_core_next_event_json`, print one event per line, free
every buffer, verify a final `NoEvent`, and destroy the handle. Do not use
`CodexCore` or private session types.

- [ ] **Step 2: Run exact-output and full clean verification**

```bash
cargo run --manifest-path CodexCore/Cargo.toml \
  --example thread_turn_smoke --quiet > /tmp/thread-turn-smoke.jsonl
diff -u tests/fixtures/thread-turn-smoke.expected.jsonl \
  /tmp/thread-turn-smoke.jsonl
cargo test --manifest-path CodexCore/Cargo.toml --locked
python3 -m unittest discover -s tests -v
swift test --package-path CodexPad
bash scripts/build_codex_core_xcframework.sh
python3 scripts/generate_codexpad_xcode_project.py --project-root CodexPad
```

Add the exact expected JSONL fixture as part of this task before running the
diff. Then run the generic Simulator and generic device builds from Task 4.

- [ ] **Step 3: Record evidence boundaries**

The report records test counts, exact six-event JSONL, static-library
architectures, app architectures/version/size, live source symbols, and parity
blocker count. It states that the local user-driven path is implemented but no
feature row changes status because no Simulator runtime or physical iPad
execution evidence exists.

- [ ] **Step 4: Commit, merge, reverify main, and clean**

```bash
git add CodexCore/examples/thread_turn_smoke.rs \
  tests/fixtures/thread-turn-smoke.expected.jsonl \
  reports/phase-06-first-thread-turn-flow.md
git commit -m "test: verify first CodexPad thread turn flow"
```

Fast-forward the verified feature branch to `main`, rerun Rust, Python, Swift,
XCFramework, and generic Simulator verification from the main checkout, retain
the main-checkout `.app` and XCFramework, remove only the owned Phase 06
worktree, and delete the merged feature branch.

## Self-Review

- **Spec coverage:** This plan implements implementation-sequence item 6 only:
  a first local workspace/thread/turn/user-item flow over the real C ABI and
  reducer. Provider-generated assistant output, persistence, tool runtime,
  device install, and parity status changes are intentionally outside this
  phase and remain explicit later plan items.
- **Placeholder scan:** All commands, event shapes, validation rules, files,
  failure expectations, and verification commands are concrete.
- **Type consistency:** Rust wire kinds, Swift command cases, domain payloads,
  store operations, and the six-event smoke use identical IDs, names, sequence
  semantics, and statuses.
