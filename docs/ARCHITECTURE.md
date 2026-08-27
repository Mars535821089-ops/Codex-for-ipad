# Architecture

Codex for ipad 采用“原生 iPad 外壳 + 桌面兼容表面 + 原生服务路由 + Rust 核心”的分层结构。目标是复现用户可见的桌面工作流，同时用 iPadOS 允许的文件、凭据、浏览器和进程机制替代 macOS/Electron 专属能力。

## 总览

```text
┌───────────────────────────────────────────────────────────┐
│ SwiftUI scene, commands, iPad layout and recovery UI      │
├───────────────────────────────────────────────────────────┤
│ WKWebView desktop surface + injected bridge               │
├───────────────────────────────────────────────────────────┤
│ AppHost routers and native service adapters               │
│ auth · projects · files · git · terminal · MCP · settings │
├──────────────────────┬────────────────────────────────────┤
│ Swift domain/store   │ Rust CodexCore through C ABI       │
│ reducers/view state  │ sessions · persistence · git · HTTP│
├──────────────────────┴────────────────────────────────────┤
│ iPadOS services                                            │
│ Keychain · Files/security bookmarks · URLSession · SQLite │
└───────────────────────────────────────────────────────────┘
```

## SwiftUI 应用入口

`CodexPad/CodexPad/App/CodexPadApp.swift` 创建：

- `CodexAccountStore`：登录方式和凭据状态。
- `CodexSessionStore`：workspace、thread、turn 和持久化状态。
- `CodexCoreClient`：Swift 到 Rust Core 的桥。
- `CodexDesktopSceneRuntimeFactory`：组装桌面表面 controller、原生服务和状态投影。

启动时，应用在 Application Support 下准备：

```text
CodexPad/
├── CodexPad.sqlite
└── MigrationSnapshots/
```

SQLite 用于本机事件和会话状态持久化。它不负责 iCloud 文件同步，也不是跨设备 CloudKit store。

## 桌面表面与 AppHost

桌面 Web 资源由用户本地导入，不在 GitHub 仓库分发。`WKWebView` 承载界面，`CodexDesktopBridgeScript` 和 AppHost router 把桌面端期望的调用映射到 iPad 原生实现。

主要职责位于：

- `Application/CodexDesktopSurfaceController.swift`：生命周期、消息路由、登录、workspace 和 renderer 协调。
- `Application/CodexDesktopWebViewHost.swift`：WebView、脚本注入和硬件按键入口。
- `Application/CodexDesktopInitialAppHostRouter.swift` 及各 `*AppHostService.swift`：按服务域处理桌面 RPC。
- `Presentation/CodexDesktopSurfaceView.swift`：SwiftUI 与 WebView 的界面桥。

平台不具备的桌面能力不会伪装成完整 macOS 进程环境。实现会采用 iPadOS 可用机制，或在功能矩阵中标记差异。

## Rust Core 与 FFI

`CodexCore` 构建为 static library/XCFramework，通过 C ABI 暴露：

- Core 创建和销毁。
- JSON request/submit。
- 事件读取。
- 官方 Provider 响应执行和流式 body 输入。
- buffer 生命周期管理。

Rust 模块负责会话状态、SQLite 存储、Git diff/worker、模型目录和官方 Provider 数据流。Swift 侧的 `CodexCoreClient` 封装内存和 JSON envelope，避免 UI 直接接触原始 C 指针。

`Cargo.toml` 锁定 OpenAI Codex Rust crates 到具体 revision，并锁定 websocket fork revisions。`Cargo.lock` 应与项目一起更新和审阅。

## iCloud Drive 工作区访问

工作区联动不是自建云服务：

```text
Mac Codex ──读写──┐
                  ├── iCloud Drive project folder
iPad app ──书签───┘
```

`CodexWorkspaceAccess`：

- 通过系统文件选择器取得用户选择的目录 URL。
- 生成 Base64 编码的 security-scoped bookmark。
- 每次读写时临时调用 `startAccessingSecurityScopedResource()`。
- 枚举时跳过 package descendants 和符号链接后代。
- 默认最多列出 2,000 个条目。
- 单个可读或写入文本上限为 2 MiB。
- 只按 UTF-8 文本处理文件。
- 拒绝绝对路径、`..`、解析后逃出根目录的路径及不安全符号链接目标。
- 写入采用原子写入。

iCloud 是否已下载文件、何时上传、是否生成冲突副本由系统 Files provider 决定。应用层不覆盖 iCloud 冲突解决器。

## 凭据与登录

凭据使用 generic-password Keychain items，并设置 `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`。Keychain item 不参与 iCloud Keychain 同步：

- ChatGPT OAuth：ID/access/refresh token 分组件保存，使用 manifest/revision 防止部分写入被当作完整 credential。
- OpenAI API Key：独立 item，保存前去除首尾空白。
- Git credential：独立 service，调试描述永远把密码显示为 `<redacted>`。
- MCP OAuth：独立运行时和 credential store。

应用 entitlement 只声明自身 Keychain access group。公开仓库不提供共享 Keychain group、个人证书或账户数据。

## Provider 与流式对话

Provider 通过 Swift adapter/client 与 Rust stream parser 接入。ChatGPT OAuth 使用 Codex 产品路由；API Key 使用原生 Responses 路由。代码明确分离这两类凭据，避免把 ChatGPT token 当 API Key 发送，或把 API Key 发往产品账号接口。

“支持 Adapter/Provider”表示业务层具有可替换接口，不表示任意第三方 OpenAI-compatible endpoint 都无需适配即可完整工作。模型目录、事件形状、工具调用、认证和流式细节仍需逐 Provider 验收。

## MCP 运行时

项目包含：

- Streamable HTTP MCP client。
- stdio 抽象。
- iOS embedded transport。
- Node Mobile runtime snapshot 和文件系统 server。
- BeeWare CPython iOS runtime 与本地构建的 Python MCP packages。
- MCP OAuth、资源目录、server status 和配置存储。

iPadOS 不提供通用 macOS shell/进程环境。因此 stdio 型 server 必须能运行在嵌入 runtime 中，或采用 HTTP transport；任意桌面二进制不能直接复制到 iPad 执行。

## 键盘、Terminal 与平台差异

SwiftUI Commands 和 WebView hardware-key path共同映射桌面快捷键，包括新聊天、命令菜单、搜索文件、侧边栏、底部面板、Terminal、Review、Side Chat、前后导航和聊天槽位。

Terminal 是 iPad 兼容服务，不等于 macOS Terminal.app。物理键盘事件还受布局、UIKit key code 和 WebView focus 影响。当前 `Control+\`` 的完整真机 renderer panel 断言仍列为待完成验收，详见 [Feature Status](FEATURE_STATUS.md)。

## 构建时桌面资源导入

公开仓库不包含桌面 Web bundle。bootstrap 在本地验证 DMG、只读挂载、提取版本和 build、生成协议/IPC/功能/视觉清单，再生成 Xcode 工程。该设计把第三方分发边界与项目源码分开，也让每个构建能绑定到明确的桌面 release identity。

## 关键设计取舍

| 选择 | 获得 | 代价 |
|---|---|---|
| iCloud Drive + security bookmark | 不需要自建同步服务，Mac/iPad 面向同一目录 | 同步延迟与冲突由系统控制，聊天状态不自动跨设备复制 |
| SQLite 本地事件存储 | 离线、事务和迁移快照 | 每个安装沙盒独立，卸载会移除本地状态 |
| Keychain ThisDeviceOnly | 凭据不进入仓库或 iCloud Keychain | 换设备、卸载或签名身份变化可能要求重新登录 |
| 本地导入 DMG | 不在仓库重新分发官方包 | 首次构建步骤更长，用户必须自行提供输入 |
| 物理 iPad 为最终验收 | 覆盖真实 Keychain/Files/键盘/网络行为 | 测试慢于模拟器，需要签名和连接设备 |
