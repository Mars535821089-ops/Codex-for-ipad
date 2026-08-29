# CodexPad SwiftUI 领域外壳 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 建立一个可由 Xcode 27 编译为 iPad Simulator App 的独立 SwiftUI 工程，并实现不依赖桌面端的 Workspace / Thread / Turn / Item / Approval 领域事件与去重状态流。

**Architecture:** Swift 领域层保持 Foundation-only，通过按 `sequence` 顺序应用的 reducer 生成不可变 `CodexSessionState`；SwiftUI Presentation 只观察 Application store，不直接读取协议 JSON、Rust 内存或持久化文件。Xcode 工程由仓库内 Python 生成器确定性生成，后续升级可以在不依赖 XcodeGen、CocoaPods 或第三方 gem 的情况下重建工程。

**Tech Stack:** Xcode 27.0、Swift 6.4、SwiftUI、Observation、Swift Package Manager、Python 3 标准库、`unittest`、XCTest、iPadOS 18+

## Global Constraints

- 项目根目录固定为 `/Users/you/projects/Codex-持续更新逆向Ipad版`。
- 当前官方基线固定为 `26.721.41059`（build `5848`），本阶段不得把其他版本写入 App 元数据。
- iPad target 的 bundle identifier 固定为 `com.mars.codexpad`，`TARGETED_DEVICE_FAMILY` 固定为 `2`，deployment target 固定为 `18.0`。
- App 必须在无 Mac、无远程执行机、无远程桌面的运行架构下启动；本阶段不接入任何远程执行依赖。
- 不创建演示 Workspace、Thread、聊天内容、缩略图或统计数据；首次启动显示真实空状态。
- UI 只消费领域状态；所有可持久事件带 `sequence`，重复或旧 sequence 必须被忽略，跳号必须显式报告。
- 本阶段只建立结构和第一条本地状态流，不把任何功能矩阵行标为 `matched`。
- 官方 Codex 是唯一视觉和行为参考；未完成截图对比的页面保持 `unknown`。
- 工程、测试、报告和 Git 中不得记录 API key、Cookie、token、签名私钥、Team ID 或 provisioning profile 内容。
- 当前机器没有可用 Simulator device runtime；验收使用 `generic/platform=iOS Simulator` 编译目标，不声明已启动 Simulator。

---

## File Structure

```text
CodexPad/
├── Package.swift
├── CodexPad.xcodeproj/project.pbxproj
├── CodexPad/
│   ├── App/CodexPadApp.swift
│   ├── Application/CodexSessionStore.swift
│   ├── Domain/CodexDomainModels.swift
│   ├── Domain/CodexSessionReducer.swift
│   ├── Presentation/CodexRootView.swift
│   ├── Presentation/WorkspaceSidebar.swift
│   ├── Presentation/ThreadListView.swift
│   ├── Presentation/ThreadDetailView.swift
│   └── Resources/Assets.xcassets/Contents.json
└── Tests/CodexPadDomainTests/
    ├── CodexDomainModelsTests.swift
    └── CodexSessionReducerTests.swift
scripts/generate_codexpad_xcode_project.py
tests/test_generate_codexpad_xcode_project.py
reports/phase-04-codexpad-swiftui-domain-shell.md
```

### Task 1: Deterministic iPad Xcode project generator

**Files:**
- Create: `scripts/generate_codexpad_xcode_project.py`
- Create: `tests/test_generate_codexpad_xcode_project.py`
- Create: `CodexPad/CodexPad/Resources/Assets.xcassets/Contents.json`

**Interfaces:**
- Produces: `generate_project(project_root: Path) -> Path`
- Produces CLI: `python3 scripts/generate_codexpad_xcode_project.py --project-root CodexPad`
- Output: `CodexPad/CodexPad.xcodeproj/project.pbxproj`

- [ ] **Step 1: Write the failing generator contract tests**

```python
from pathlib import Path
from tempfile import TemporaryDirectory
import unittest

from scripts.generate_codexpad_xcode_project import generate_project


class GenerateCodexPadProjectTests(unittest.TestCase):
    def test_project_is_ipad_only_and_unsigned_by_default(self):
        with TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "CodexPad/App").mkdir(parents=True)
            (root / "CodexPad/App/CodexPadApp.swift").write_text(
                "import SwiftUI\n@main struct CodexPadApp: App {"
                "var body: some Scene { WindowGroup { Text(\"Codex\") } }}\n"
            )
            output = generate_project(root)
            project = output.read_text()
        self.assertIn("PRODUCT_BUNDLE_IDENTIFIER = com.mars.codexpad;", project)
        self.assertIn("TARGETED_DEVICE_FAMILY = 2;", project)
        self.assertIn("IPHONEOS_DEPLOYMENT_TARGET = 18.0;", project)
        self.assertIn("CODE_SIGNING_ALLOWED = NO;", project)
        self.assertIn("CodexPadApp.swift", project)

    def test_generation_is_byte_deterministic(self):
        with TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "CodexPad/App").mkdir(parents=True)
            (root / "CodexPad/App/CodexPadApp.swift").write_text(
                "import SwiftUI\n@main struct CodexPadApp: App {"
                "var body: some Scene { WindowGroup { Text(\"Codex\") } }}\n"
            )
            output = generate_project(root)
            first = output.read_bytes()
            second = generate_project(root).read_bytes()
        self.assertEqual(first, second)
```

- [ ] **Step 2: Run the focused test and observe the missing module**

Run: `python3 -m unittest tests.test_generate_codexpad_xcode_project -v`

Expected: FAIL with `ModuleNotFoundError: scripts.generate_codexpad_xcode_project`.

- [ ] **Step 3: Implement stable file discovery and OpenStep project output**

The generator must:

1. recursively discover `CodexPad/**/*.swift` and `CodexPad/Resources/**`;
2. derive every 24-character PBX identifier from
   `sha256("<isa>:<relative-path>")[:24].upper()`;
3. sort all file references, groups and build phase entries by relative path;
4. emit one `PBXNativeTarget` named `CodexPad`;
5. emit one shared scheme through `xcodebuild` auto-scheme discovery;
6. set `SDKROOT = iphoneos`, `SUPPORTED_PLATFORMS = "iphoneos iphonesimulator"`,
   `SWIFT_VERSION = 6.0`, `GENERATE_INFOPLIST_FILE = YES`,
   `INFOPLIST_KEY_CFBundleDisplayName = Codex`,
   `INFOPLIST_KEY_UILaunchScreen_Generation = YES`,
   `INFOPLIST_KEY_UIApplicationSupportsIndirectInputEvents = YES`,
   `TARGETED_DEVICE_FAMILY = 2`, `IPHONEOS_DEPLOYMENT_TARGET = 18.0`,
   and `CODE_SIGNING_ALLOWED = NO`;
7. write through a sibling temporary file followed by `Path.replace`.

Reject a project root without exactly one `CodexPad/App/CodexPadApp.swift`.

- [ ] **Step 4: Run focused and full Python tests**

```bash
python3 -m unittest tests.test_generate_codexpad_xcode_project -v
python3 -m unittest discover -s tests -v
python3 -m py_compile scripts/generate_codexpad_xcode_project.py
```

- [ ] **Step 5: Commit**

```bash
git add scripts/generate_codexpad_xcode_project.py \
  tests/test_generate_codexpad_xcode_project.py \
  CodexPad/CodexPad/Resources/Assets.xcassets/Contents.json
git commit -m "feat: generate deterministic CodexPad project"
```

### Task 2: Foundation-only domain entities and events

**Files:**
- Create: `CodexPad/Package.swift`
- Create: `CodexPad/CodexPad/Domain/CodexDomainModels.swift`
- Create: `CodexPad/Tests/CodexPadDomainTests/CodexDomainModelsTests.swift`

**Interfaces:**
- Produces: `Workspace`, `CodexThread`, `Turn`, `ThreadItem`, `Approval`
- Produces: `DomainEvent(sequence: Int64, payload: DomainEvent.Payload)`
- All domain types conform to `Codable`, `Equatable`, `Identifiable`, `Sendable`.

- [ ] **Step 1: Create the Swift package manifest and failing model tests**

`Package.swift` defines a library product `CodexPadDomain`, target path
`CodexPad/Domain`, and XCTest target path `Tests/CodexPadDomainTests`.
It supports `.iOS(.v18)` and `.macOS(.v15)`.

```swift
import XCTest
@testable import CodexPadDomain

final class CodexDomainModelsTests: XCTestCase {
    func testDomainEventRoundTripsWithoutLosingIdentity() throws {
        let workspace = Workspace(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            displayName: "Codex",
            rootBookmarkID: nil
        )
        let event = DomainEvent(
            sequence: 1,
            payload: .workspaceUpserted(workspace)
        )
        let encoded = try JSONEncoder().encode(event)
        XCTAssertEqual(try JSONDecoder().decode(DomainEvent.self, from: encoded), event)
    }

    func testApprovalKeepsRequestedPendingState() {
        let approval = Approval(
            id: UUID(),
            turnID: UUID(),
            itemID: UUID(),
            title: "Apply patch",
            details: "1 file",
            status: .requested
        )
        XCTAssertEqual(approval.status, .requested)
    }
}
```

- [ ] **Step 2: Run Swift tests and observe compile failure**

Run: `swift test --package-path CodexPad`

Expected: FAIL because the domain types do not exist.

- [ ] **Step 3: Implement explicit domain types**

Use these enums:

```swift
public enum TurnStatus: String, Codable, Sendable {
    case queued, running, completed, failed, cancelled
}
public enum ThreadItemKind: String, Codable, Sendable {
    case userMessage, assistantMessage, reasoning, toolCall, toolResult
    case approval, fileChange, terminal, error
}
public enum ApprovalStatus: String, Codable, Sendable {
    case requested, approved, declined, cancelled
}
```

`DomainEvent.Payload` cases are:

```swift
case workspaceUpserted(Workspace)
case threadUpserted(CodexThread)
case turnStarted(Turn)
case turnStatusChanged(turnID: UUID, status: TurnStatus)
case itemAppended(ThreadItem)
case approvalRequested(Approval)
case approvalResolved(approvalID: UUID, status: ApprovalStatus)
```

No type may store credentials, raw bookmark bytes or protocol transport objects.

- [ ] **Step 4: Run Swift and Python suites**

```bash
swift test --package-path CodexPad
python3 -m unittest discover -s tests -v
```

- [ ] **Step 5: Commit**

```bash
git add CodexPad/Package.swift CodexPad/CodexPad/Domain \
  CodexPad/Tests/CodexPadDomainTests/CodexDomainModelsTests.swift
git commit -m "feat: define CodexPad domain events"
```

### Task 3: Ordered, deduplicating session reducer

**Files:**
- Create: `CodexPad/CodexPad/Domain/CodexSessionReducer.swift`
- Create: `CodexPad/Tests/CodexPadDomainTests/CodexSessionReducerTests.swift`

**Interfaces:**
- Produces: `CodexSessionState`
- Produces: `CodexSessionReducer.apply(_:to:) -> ApplyResult`
- `ApplyResult` cases: `.applied`, `.duplicate`, `.gap(expected: Int64, received: Int64)`, `.invalidReference(String)`

- [ ] **Step 1: Write failing ordering and lifecycle tests**

```swift
func testDuplicateSequenceIsIgnored() {
    let workspace = Workspace(id: UUID(), displayName: "Codex", rootBookmarkID: nil)
    let event = DomainEvent(sequence: 1, payload: .workspaceUpserted(workspace))
    var state = CodexSessionState()
    XCTAssertEqual(CodexSessionReducer.apply(event, to: &state), .applied)
    XCTAssertEqual(CodexSessionReducer.apply(event, to: &state), .duplicate)
    XCTAssertEqual(state.workspaces, [workspace])
    XCTAssertEqual(state.lastAppliedSequence, 1)
}

func testGapDoesNotMutateState() {
    var state = CodexSessionState()
    let event = DomainEvent(
        sequence: 2,
        payload: .workspaceUpserted(
            Workspace(id: UUID(), displayName: "Codex", rootBookmarkID: nil)
        )
    )
    XCTAssertEqual(
        CodexSessionReducer.apply(event, to: &state),
        .gap(expected: 1, received: 2)
    )
    XCTAssertTrue(state.workspaces.isEmpty)
    XCTAssertEqual(state.lastAppliedSequence, 0)
}

func testTurnItemAndApprovalRequireExistingParents() {
    var state = CodexSessionState()
    let turn = Turn(id: UUID(), threadID: UUID(), status: .running)
    let event = DomainEvent(sequence: 1, payload: .turnStarted(turn))
    XCTAssertEqual(
        CodexSessionReducer.apply(event, to: &state),
        .invalidReference("thread")
    )
    XCTAssertEqual(state.lastAppliedSequence, 0)
}
```

- [ ] **Step 2: Run and observe missing reducer types**

Run: `swift test --package-path CodexPad --filter CodexSessionReducerTests`

- [ ] **Step 3: Implement atomic reducer transitions**

`CodexSessionState` stores sorted arrays for public observation and private
lookup dictionaries inside reducer functions. Apply rules:

- `sequence <= lastAppliedSequence` returns `.duplicate`;
- `sequence != lastAppliedSequence + 1` returns `.gap` without mutation;
- referenced workspace/thread/turn/item/approval must already exist;
- upsert preserves array position when identity already exists;
- append events with duplicate entity IDs return `.invalidReference("duplicate-item")`;
- only `.applied` advances `lastAppliedSequence`;
- every mutation is performed on a local copy and assigned back after validation.

- [ ] **Step 4: Run reducer and full Swift tests**

```bash
swift test --package-path CodexPad --filter CodexSessionReducerTests
swift test --package-path CodexPad
```

- [ ] **Step 5: Commit**

```bash
git add CodexPad/CodexPad/Domain/CodexSessionReducer.swift \
  CodexPad/Tests/CodexPadDomainTests/CodexSessionReducerTests.swift
git commit -m "feat: reduce ordered Codex session events"
```

### Task 4: Application store and real-empty SwiftUI shell

**Files:**
- Create: `CodexPad/CodexPad/Application/CodexSessionStore.swift`
- Create: `CodexPad/CodexPad/App/CodexPadApp.swift`
- Create: `CodexPad/CodexPad/Presentation/CodexRootView.swift`
- Create: `CodexPad/CodexPad/Presentation/WorkspaceSidebar.swift`
- Create: `CodexPad/CodexPad/Presentation/ThreadListView.swift`
- Create: `CodexPad/CodexPad/Presentation/ThreadDetailView.swift`
- Modify: `CodexPad/Package.swift`
- Test: `CodexPad/Tests/CodexPadDomainTests/CodexSessionStoreTests.swift`

**Interfaces:**
- Produces: `@MainActor @Observable final class CodexSessionStore`
- Produces: `apply(_ event: DomainEvent) -> ApplyResult`
- Presentation consumes only `CodexSessionStore.state` and selection IDs.

- [ ] **Step 1: Add the Application target and failing store test**

Add library target `CodexPadApplication`, depending on `CodexPadDomain`, with
path `CodexPad/Application`; make the test target depend on both libraries.

```swift
@MainActor
func testStorePublishesAppliedStateAndRetainsGap() {
    let store = CodexSessionStore()
    let workspace = Workspace(id: UUID(), displayName: "Codex", rootBookmarkID: nil)
    XCTAssertEqual(
        store.apply(DomainEvent(sequence: 1, payload: .workspaceUpserted(workspace))),
        .applied
    )
    XCTAssertEqual(store.state.workspaces, [workspace])
    XCTAssertEqual(
        store.apply(DomainEvent(sequence: 3, payload: .workspaceUpserted(workspace))),
        .gap(expected: 2, received: 3)
    )
    XCTAssertEqual(store.lastApplyProblem, .gap(expected: 2, received: 3))
}
```

- [ ] **Step 2: Run and observe missing Application module**

Run: `swift test --package-path CodexPad --filter CodexSessionStoreTests`

- [ ] **Step 3: Implement store and presentation**

`CodexSessionStore` owns:

```swift
public private(set) var state = CodexSessionState()
public private(set) var lastApplyProblem: ApplyResult?
public var selectedWorkspaceID: UUID?
public var selectedThreadID: UUID?
```

The root view uses `NavigationSplitView`:

- sidebar title `Codex`, official workspace list, and `ContentUnavailableView`
  when no authorized workspace exists;
- content column lists threads belonging to the selected workspace;
- detail column renders the selected thread's ordered items;
- `.inspector` exposes current turn and approval state without deleting or
  renaming any official area;
- composer is disabled until a workspace and thread exist;
- no sample entity is inserted by `CodexPadApp`.

Accessibility identifiers are:
`codex.workspace.sidebar`, `codex.thread.list`, `codex.thread.detail`,
`codex.composer`, and `codex.inspector`.

- [ ] **Step 4: Generate the project and compile both layers**

```bash
swift test --package-path CodexPad
python3 scripts/generate_codexpad_xcode_project.py --project-root CodexPad
xcodebuild -project CodexPad/CodexPad.xcodeproj \
  -scheme CodexPad \
  -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath DerivedData/CodexPad \
  CODE_SIGNING_ALLOWED=NO build
```

- [ ] **Step 5: Commit**

```bash
git add CodexPad
git commit -m "feat: build CodexPad SwiftUI domain shell"
```

### Task 5: Version mapping, build evidence and phase report

**Files:**
- Create: `reports/phase-04-codexpad-swiftui-domain-shell.md`
- Modify: `versions/26.721.41059/feature-inventory.json`

**Interfaces:**
- Consumes Swift test results, Xcode build log and app bundle metadata.
- Produces a compiled `.app` under project-scoped `DerivedData/CodexPad`.
- Keeps every feature status `unknown`.

- [ ] **Step 1: Write and run a failing mapping assertion**

Run a Python assertion requiring every `thread.*` and `turn.*` feature to have:

```python
feature["ipadModule"] in {
    "CodexPadDomain",
    "CodexPadApplication",
    "CodexPadPresentation",
}
```

Expected: FAIL because all `ipadModule` values are currently `None`.

- [ ] **Step 2: Map implemented structural modules without changing status**

For every `thread.*` row set:

```json
{
  "ipadModule": "CodexPadDomain",
  "automatedTests": [
    "CodexDomainModelsTests",
    "CodexSessionReducerTests"
  ],
  "status": "unknown"
}
```

For every `turn.*` row use the same fields. Do not add Simulator or device
evidence and do not change `statusCounts`.

- [ ] **Step 3: Run complete build and inspect the app**

```bash
rm -rf DerivedData/CodexPad
swift test --package-path CodexPad
python3 -m unittest discover -s tests -v
python3 scripts/generate_codexpad_xcode_project.py --project-root CodexPad
xcodebuild -project CodexPad/CodexPad.xcodeproj \
  -scheme CodexPad \
  -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath DerivedData/CodexPad \
  CODE_SIGNING_ALLOWED=NO build
APP=DerivedData/CodexPad/Build/Products/Debug-iphonesimulator/CodexPad.app
test -d "$APP"
plutil -extract CFBundleIdentifier raw "$APP/Info.plist"
plutil -extract CFBundleDisplayName raw "$APP/Info.plist"
```

Expected metadata: `com.mars.codexpad` and `Codex`.

- [ ] **Step 4: Verify the parity gate still blocks and write the report**

```bash
set +e
python3 scripts/check_parity_gate.py \
  versions/26.721.41059/feature-inventory.json
test $? -eq 2
```

The report records:

- Xcode, Swift and SDK versions;
- Swift and Python test counts;
- generic iPad Simulator build command and exit code;
- compiled app absolute path, size, bundle identifier and display name;
- mapped thread/turn row counts;
- parity blocker count;
- explicit statements that no Simulator runtime was available, no app was
  launched, no screenshot comparison ran, no true-device installation ran,
  and no feature is yet `matched`.

- [ ] **Step 5: Rebuild from clean DerivedData and commit**

Delete project-scoped DerivedData, regenerate the project, repeat Swift tests,
Python tests and `xcodebuild`, then:

```bash
git add CodexPad scripts/generate_codexpad_xcode_project.py \
  tests/test_generate_codexpad_xcode_project.py \
  versions/26.721.41059/feature-inventory.json \
  reports/phase-04-codexpad-swiftui-domain-shell.md
git commit -m "feat: establish compiled CodexPad shell baseline"
```

## Self-Review

- Spec coverage: this plan implements implementation-sequence item 4, the SwiftUI
  project, foundational domain model, Application store, sequence de-duplication,
  explicit gap handling, a real empty state, and a generic iPad Simulator build.
  Rust Core, protocol transport, persistence, Tool Runtime, visual screenshots,
  device signing and installation remain separate independently testable plans.
- Placeholder scan: the plan contains no deferred implementation marker; every
  task has concrete files, interfaces, red/green commands, exact status rules and
  a commit boundary.
- Type consistency: `DomainEvent`, `CodexSessionState`, `ApplyResult`,
  `CodexSessionReducer.apply`, and `CodexSessionStore.apply` keep the same names
  and signatures across Domain, Application, Presentation and tests.
