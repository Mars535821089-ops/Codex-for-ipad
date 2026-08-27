# Codex iPad 独立产品与持续升级系统设计

日期：2026-07-29
状态：设计已确认，目标锁定为 Codex 1:1 可观察同等性
项目：`/Users/you/projects/Codex-持续更新逆向Ipad版`

## 1. 产品目标

将最新版桌面 Codex 的发布构建、协议、界面和行为持续解析为一套可维护的 iPadOS 产品。成品安装后在 iPad 本机完成界面、会话、模型通信、项目文件、Git、差异审阅、工具调用、终端模拟、审批、技能与设置等工作，不依赖 Mac、云端执行机或远程桌面提供运行能力。

产品验收目标是 **Codex 1:1 可观察同等性**：同一官方版本、同一账户状态、同一工作区和同一输入下，iPad 版必须提供相同的功能入口、信息层级、文案、图标语义、会话状态、审批步骤、工具事件、错误状态、恢复行为和最终操作结果。不得引入另一套产品定位、交互模型、命名体系或视觉语言。

Mac 只承担开发期和升级期工作：

1. 检查官方完整 DMG；
2. 逆向提取并分析版本差异；
3. 生成兼容代码；
4. 编译、测试并用个人证书签名；
5. 向用户自己的 iPad 安装升级包；
6. 成功后清理本次下载和临时产物。

Mac 不参与 iPad App 已安装版本的日常任务执行。

## 2. 不可改变的产品不变量

1. **纯独立运行**：断开 Mac 和局域网后，已安装 App 的本机功能仍可使用。
2. **功能同等性**：桌面版每项可观察功能必须在功能矩阵中有 iPad 实现、平台等价实现或明确的系统级映射；不得通过隐藏入口减少验收范围。
3. **数据与程序分离**：升级程序不得覆盖项目、会话、设置、凭据引用、技能、授权书签和升级历史。
4. **先验证再替换**：只有逆向、生成、编译、测试、签名和安装验证全部成功，才把新版本标记为当前版本。
5. **失败可回滚**：任何失败都保留旧 IPA、旧兼容层、迁移前数据库快照和失败日志。
6. **成功后清理**：只清理已由 manifest 明确归属本次升级的 DMG、下载分片、临时解包目录、派生构建缓存和过期回滚包。
7. **持续复用**：版本相关知识进入机器可读 manifest、协议 Schema、差异规则和兼容适配器，避免把版本号散落在 UI 或业务代码中。
8. **不保存秘密**：个人签名和服务凭据引用 Keychain；源码、报告、日志与 Git 中不记录明文秘密。
9. **1:1 同等性优先**：界面和行为以当期官方 Codex 为唯一基准；任何自定义、简化、重新命名或重新编排都不能替代官方功能。
10. **差异必须显式失败**：尚未达到同等性的功能必须标为 `missing` 或 `mismatch`，不得用“移动端优化”“平台限制”或隐藏入口把它计为完成。

## 3. 总体架构

### 3.1 iPad App

```text
CodexPadApp
├── Presentation        SwiftUI 多窗口与自适应三栏界面
├── Domain              Thread / Turn / Item / Approval / Workspace 模型
├── Application         用例、状态机、任务调度和迁移协调
├── ProtocolBridge      App Server JSON-RPC 契约与版本兼容器
├── CodexCore           Rust 静态库及 Swift C ABI 封装
├── ToolRuntime         WASI、Git、搜索、补丁、文件和终端实现
├── Persistence         SQLite、文件索引、升级日志和 security-scoped bookmark
├── Networking          模型通信、流式事件、重试和连通性
└── Platform            iPadOS 文件、相机、麦克风、通知、分享和键盘接口
```

### 3.2 Mac 升级工厂

```text
OfficialReleaseProbe
  -> VerifiedDownloader
  -> DMGInspector
  -> ASARExtractor
  -> ProtocolGenerator
  -> VersionDiffer
  -> CompatibilityGenerator
  -> XcodeBuilder
  -> SimulatorVerifier
  -> PersonalSigner
  -> DeviceInstaller
  -> PostInstallVerifier
  -> ManifestCommitter
  -> ScopedCleaner
```

Mac 升级工厂是可重复执行、幂等、有恢复点的流水线。它不以下载大小、解包成功或编译通过单独代表升级成功。

## 4. 逆向与契约恢复

### 4.1 输入

- 官方固定下载入口的完整 DMG；
- `Info.plist`、entitlements、签名、公证信息；
- `app.asar`、`app.asar.unpacked`、资源和原生模块；
- 内置 Codex CLI 生成的 App Server TypeScript 与 JSON Schema；
- renderer 页面、preload、主进程和 IPC 构建代码；
- 可观察的桌面应用行为和回归用例。

### 4.2 每版本输出

```text
versions/<version>/
├── manifest.json
├── package-metadata/
├── asar/
├── protocol/typescript/
├── protocol/json-schema/
├── normalized/
├── feature-inventory.json
├── compatibility-report.json
└── provenance.json
```

`provenance.json` 记录每个恢复模块对应的原始构建文件、哈希、提取工具版本和生成时间。原始构建不带 sourcemap 时，重构源码使用稳定的领域命名，并保留与构建片段的映射，而不是声称恢复不存在的原始变量名和注释。

### 4.3 差异分类

每次更新把变化分为：

- 协议字段新增、删除或类型变化；
- IPC channel 和工具调用变化；
- 页面、命令和设置项变化；
- 数据库与持久化变化；
- 新增资源和本地化；
- 新增或替换的原生模块；
- iPadOS 兼容层影响；
- 仅桌面外观变化。

破坏性差异必须生成失败门禁，直到兼容器和回归用例同步更新。

## 5. iPad 本机执行层

### 5.1 Codex Core

可移植 Rust 逻辑编译为 `aarch64-apple-ios` 静态库，通过最小 C ABI 暴露：

- 会话和 turn 生命周期；
- 流式事件；
- 工具请求与审批；
- 配置解析；
- 模型请求；
- patch 与差异模型；
- 技能发现和提示组装；
- 取消、恢复与错误事件。

涉及桌面进程、PTY、系统沙箱或任意可执行文件的部分由 `ExecutionProvider` 协议替换。

### 5.2 Tool Runtime

本机工具层至少包含：

- 文件读取、写入、目录遍历和原子替换；
- 文本搜索和 glob；
- diff、patch 与回滚；
- libgit2 状态、diff、branch、commit 和 worktree 等价能力；
- WASI 解释/运行环境；
- 内嵌基础命令集合；
- 终端缓冲区、ANSI 解析、输入与输出流；
- SQLite；
- HTTP/WebSocket；
- 文档、图片和媒体的系统预览；
- 用户批准后的目录级 security-scoped 访问。

桌面版“启动任意宿主二进制”的语义映射为“在 App 签名包内提供的原生工具或 WASI 工具中执行”。界面、调用契约、审批、输出、取消和日志语义保持一致。

### 5.3 文件系统

- App 容器保存数据库、缓存、技能、工具包和内部项目；
- 外部项目通过 `UIDocumentPickerViewController` 授权；
- bookmark 只保存系统授权数据，不保存用户凭据；
- 所有写入先进入同目录临时文件，再原子替换；
- 大型工作区使用增量索引和文件协调器；
- 失效 bookmark 引导用户重新授权，不删除已有状态。

## 6. 界面设计

### 6.1 Codex 1:1 界面复现

- 桌面版的项目侧栏、任务列表、主对话/差异区域、Inspector、工具面板、Composer、设置页、弹窗、菜单和状态反馈逐项复现；
- 横屏优先保持官方 Codex 的布局比例、间距、层级、颜色、字体权重、图标语义和展开/折叠状态；
- 竖屏空间不足时只允许把同一官方区域收纳进系统可展开容器，不得删除、合并、改名或改变操作顺序；
- 主区域完整支持对话、计划、工具调用、终端、文件、diff、图片和网页结果；
- 支持与官方行为对应的硬件键盘、Command 菜单、拖放、多窗口和 Stage Manager；
- 每个页面保存官方参考截图、iPad 实现截图和视觉差异结果；未经对比验证不得标记为完成。

### 6.2 状态一致性

UI 只消费领域事件，不直接读取 Rust 内存或 SQLite。所有事件带有 thread、turn、item 和 sequence 标识；重连或恢复时以持久化 sequence 去重。

## 7. 数据模型与迁移

核心实体：

- Workspace
- Thread
- Turn
- ThreadItem
- ToolCall
- Approval
- Attachment
- Skill
- AppConfiguration
- ProtocolCompatibility
- UpgradeRecord

每个发布版本携带单向迁移和兼容读取器。升级前创建数据库快照；启动成功、数据校验和冒烟测试通过后才删除迁移前快照。旧版本回滚时使用兼容读取器，不直接用新 schema 覆盖旧数据库。

## 8. 发布导入与手动升级（自动升级已移除）

项目不在 iPad 或 macOS 后台运行自动升级闭环。新版导入、逆向、适配、构建、
签名和安装均由用户在 Mac 上显式执行；旧版自动入口必须 fail-closed，并清理
遗留 LaunchAgent。产品运行时不下载、替换或删除升级包。

以下状态机仅描述人工执行 `scripts/update_latest.sh` 时的可选发布流水线，不得
由 LaunchAgent、应用启动或 iPad 请求触发：

### 8.1 状态机

```text
idle
 -> checking
 -> downloading
 -> verifying_source
 -> extracting
 -> generating_protocol
 -> diffing
 -> adapting
 -> building
 -> testing
 -> signing
 -> installing
 -> verifying_device
 -> committing
 -> cleaning
 -> idle
```

任一步失败进入 `failed_<stage>`，保留：

- 下载包；
- 当前 stage manifest；
- 标准输出和错误；
- 新旧协议差异；
- 构建日志；
- 旧可安装 IPA；
- 数据迁移快照。

### 8.2 最新版验证

最新版不是由网页文案或本地文件名判断。必须同时记录：

- 官方下载 URL；
- HTTP ETag、Last-Modified 和 Content-Length；
- DMG SHA-256；
- `hdiutil verify`；
- Bundle version 和 build；
- Developer ID、Team ID、公证与 Gatekeeper；
- ASAR integrity；
- 与已导入版本 manifest 的比较。

### 8.3 个人签名与安装

- 使用用户本机 Xcode 账户的个人开发证书；
- 签名身份和 provisioning profile 由 Xcode/Keychain 管理；
- 构建产物生成版本化 archive 和 IPA；
- 通过 `xcrun devicectl` 或 Xcode 安装到已配对的个人 iPad；
- 安装后启动 App，读取运行版本、数据库 schema、协议版本并执行冒烟任务；
- 验证成功才更新 `current-release.json`。

### 8.4 清理规则

清理器只接受本次 upgrade manifest 中的绝对路径，并要求路径位于：

- 项目 `.downloads/`；
- 项目版本临时目录；
- 项目专用 DerivedData；
- 已超过保留数量的项目回滚目录。

默认保留：

- 当前正式版；
- 上一个成功版；
- 最近一次失败现场；
- 每版本 manifest、协议 Schema、差异报告和测试报告。

## 9. 错误处理与恢复

- 下载支持断点续传和 SHA 校验；
- 解包写入唯一 staging，完成后原子改名；
- 协议生成失败不触碰现有兼容代码；
- 生成代码在独立版本目录编译；
- 安装前确认设备、签名身份、bundle identifier 和目标版本；
- 安装失败不卸载旧版本；
- 首次启动失败时重新安装上一成功 IPA；
- 数据迁移失败恢复快照；
- 清理失败只记录警告，不撤销已经验证成功的升级；
- 同一时间只允许一个升级事务持有锁。

## 10. 验证体系

### 10.1 自动测试

- Rust Core 单元测试；
- Swift Domain/Application 单元测试；
- JSON-RPC Schema 契约测试；
- 版本兼容快照测试；
- SQLite 迁移与回滚测试；
- Tool Runtime 文件、Git、patch、WASI 和取消测试；
- UI 状态机与可访问性测试；
- 更新状态机故障注入测试；
- 清理器路径边界测试。

### 10.2 Simulator 验证

- 冷启动和恢复；
- iPad 横竖屏与多窗口；
- 新建项目、对话和任务；
- 流式回复；
- 文件查看、编辑、diff、patch；
- Git 操作；
- 工具审批、取消和超时；
- 离线恢复；
- 老数据库迁移；
- 内存和崩溃检查。

### 10.3 真机门禁

- 个人签名安装成功；
- 无 Mac、无远程执行端时启动和运行；
- 选择本机与文件提供器目录；
- 完成一条真实模型请求；
- 完成文件编辑和 Git diff；
- 完成工具调用和审批；
- 后台/前台切换恢复；
- 升级后数据完整；
- 上一版回滚可用。

## 11. 功能同等性矩阵

逆向阶段维护 `feature-inventory.json`。每个功能包含：

- 桌面入口与观察证据；
- 官方参考截图、窗口尺寸和界面状态；
- 协议或 IPC 依赖；
- iPad 实现模块；
- 自动测试；
- Simulator 证据；
- 真机证据；
- 视觉差异结果；
- 当前状态。

只有所有功能均有真机证据，且不存在 `missing`、`mismatch`、`unknown` 或 `desktop-only-unmapped` 状态，才可声明与 Codex 1:1 完整。

## 12. 交付物

1. 逐版本逆向档案和来源映射；
2. 可维护的 Swift/Rust 源码；
3. Xcode iPadOS 工程；
4. Simulator 可运行 App；
5. 个人签名真机 IPA；
6. 自动版本检查、下载、逆向、适配、构建、测试、签名、安装、验证和清理流水线；
7. 数据迁移与回滚系统；
8. 功能同等性矩阵；
9. 每版本测试和升级报告。

## 13. 首个实施序列

1. 从内置 CLI 生成完整 App Server TypeScript 与 JSON Schema；
2. 恢复 Electron 主进程、preload、renderer 的 IPC/功能清单；
3. 建立功能同等性矩阵；
4. 创建 SwiftUI iPadOS 工程和领域模型；
5. 建立 Rust Core iOS 编译与 C ABI；
6. 接通第一条 thread/turn 流；
7. 逐项实现 Tool Runtime；
8. 完成数据迁移、升级工厂、签名和真机闭环；
9. 对功能矩阵逐项补齐证据。
