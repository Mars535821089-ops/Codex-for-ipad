# Build, Release and Testing Reference

本文件交代公开源码如何变成物理 iPad 上的应用，以及各验证层分别证明什么。

## 构建输入

| 输入 | 来源 | 是否进 Git |
|---|---|---|
| Swift 应用/测试 | 本仓库 `CodexPad/` | 是 |
| Rust Core/lockfile | 本仓库 `CodexCore/` | 是 |
| Python/Shell pipeline | 本仓库 `scripts/`、`tests/` | 是 |
| Node MCP snapshot | 锁定 runtime/package tree | 是，保留自身第三方许可 |
| BeeWare Python Apple runtime | `runtime-lock.json` 锁定 URL、tag、commit、SHA-256 | 否，本地下载 |
| Python MCP packages | 使用脚本和 lock metadata 本地构建 | 否 |
| 官方桌面 DMG/Web resources | 用户自行取得并本地导入 | 否 |
| Apple signing assets | 用户自己的 Xcode/Keychain/Developer account | 否 |

当前 Python Apple runtime lock 指向 CPython 3.13.14 / BeeWare `3.13-b14`，并记录 archive SHA-256。Node Mobile runtime lock 记录 Node 18.20.4、文件系统 MCP server 版本、package-lock hash 和完整 tree hash。应以仓库内 lock 文件为准，不以本文数字替代机器校验。

## Bootstrap

```bash
./scripts/bootstrap_public_build.sh /absolute/path/to/ChatGPT.dmg
```

失败采用非零退出码；不会在缺工具、DMG 不存在或签名身份不符合预期时继续生成“看似成功”的工程。

`import_dmg.sh` 会：

- `hdiutil verify`。
- 只读挂载 DMG。
- `codesign --verify --deep --strict` 和 `spctl --assess`。
- 校验官方应用 Bundle ID 和 signing Team。
- 读取 version/build。
- staged import；失败时恢复原 destination。
- 生成本地协议、IPC、visual、bundle、feature 和 interaction 清单。

## Xcode 工程与签名

生成器默认使用公共 Bundle ID 占位值；每个使用者必须换成自己的唯一 ID，并让 Xcode 自动管理签名。

```bash
open CodexPad/CodexPad.xcodeproj
```

Release 构建脚本会对生产输入计算 fingerprint，并为 archive/export/IPA 生成 manifest 和 hash。任何 Team ID、UDID 或证书只属于本地构建环境。

## 测试层级

### 1. 静态与语法

```bash
python3 -m py_compile scripts/*.py
for file in scripts/*.sh; do bash -n "$file"; done
plutil -lint CodexPad/CodexPad/Resources/Info.plist
swift package --package-path CodexPad describe
```

证明：脚本可解析、plist 有效、Swift package manifest 可读取。它不证明应用可运行。

### 2. Python 契约与流水线测试

```bash
python3 -m pytest tests
```

覆盖 DMG/import、protocol/feature inventory、Xcode project generation、release archive、transaction、update disabled contract、device selection/installation contract 和 parity evidence。部分测试使用 fixture，不连接真实服务。

### 3. Swift package 测试

```bash
swift test --package-path CodexPad
```

主要覆盖 Domain、Application、ProtocolBridge 的状态、序列化、路由、安全路径、凭据和 view-state 逻辑。Swift Package 测试不包含完整 iOS app resources、entitlements 或真机 Keychain 行为。

### 4. Rust Core 测试

```bash
cargo test --manifest-path CodexCore/Cargo.toml
```

覆盖 session reducer、SQLite replay/migration、Git diff/worker、model catalog、provider stream 和 C ABI 相关行为。网络依赖首次构建可能需要下载 crates/git revisions。

### 5. iPhoneOS 构建

使用 Xcode 或项目脚本构建真实 `iphoneos` 目标。该层证明 Swift、资源、XCFramework、entitlements 和签名可组合成应用。

### 6. 物理 iPad UI/端到端

物理验收需显式开启，设备选择器会选择可用的真实 iPad。安装脚本默认：

- 不启动应用。
- 应用正在前台时不替换安装。
- 不执行设备重启、关机、抹除或重新配对。
- 设备离线时直接停止安装。

如确需安装后启动或覆盖运行中应用，必须由操作者显式设置相应环境变量；这不是默认路径。

## Parity 证据

工具链区分：

- 官方桌面 capture。
- protocol/IPC/API inventory。
- iPad static implementation coverage。
- XCUITest capture。
- 物理设备截图和 UI assertion。
- release manifest、source head、input fingerprint 和 IPA hash。

静态清单的 100% 只说明“每个清单项有映射”，不说明每项在真实账号、网络和设备上工作。最终 gate 必须消费物理证据。

## 手动更新

后台自动更新已关闭。三个兼容入口的行为是：

- `configure_auto_update.sh`：卸载并删除旧 LaunchAgent，然后报告 disabled。
- `check_and_update_latest.sh`：立即以退出码 78 失败关闭。
- `poll_ipad_update_requests.sh`：立即以退出码 78 失败关闭。

用户拥有两种显式更新方式：

1. 取得新版 DMG 后重新运行 `bootstrap_public_build.sh`，审阅并在 Xcode 构建。
2. 维护者显式执行 `update_latest.sh`，走下载、导入、构建、验证、归档和 transaction commit 流程。

`update_latest.sh` 从未被 iPad app 或后台调度器自动调用。物理验收还要求显式设置 `CODEXPAD_RUN_PHYSICAL_ACCEPTANCE=true`。

## Release 和回滚原则

- 先验证，再归档，再 transaction commit，最后清理临时下载。
- release identity 由 desktop version/build 和相关 manifest 共同约束。
- archive 记录 SHA-256，远端最终探测发生在 commit 前。
- 只有 commit 成功后才删除多余下载文件。
- 更新失败不得覆盖最后一个已确认 release。
- 公共 GitHub Release 不应附带个人签名 IPA。

## 公开快照验证记录

首次公共提交 `0610771` 发布前完成：

- 4,805 个 staged files。
- Git pack 约 18.42 MiB；最大 tracked file 小于 1 MiB。
- 58 个 Python 脚本通过 `py_compile`。
- 16 个 shell 脚本通过 `bash -n`。
- Xcode project generator 聚焦测试 29/29 通过。
- Swift package description、plist lint 和公开内容敏感扫描通过。
- updater/archive 五个扩展回归模块在开发工作区此前为 70/70 通过。

这些数字是特定提交的证据，不自动适用于未来提交。每次发布都应重新运行相应检查。
