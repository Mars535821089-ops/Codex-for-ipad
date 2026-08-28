# Feature Status and Product Boundaries

本文档按实现、源码测试、Release 构建和物理真机证据四层说明当前状态。当前公开基线已经完成产品闭环；后续工作属于跟随桌面 Codex 与 iPadOS 演进的持续兼容维护。

## 当前稳定基线

- 桌面兼容版本：`26.814.41957`（build `6744`）
- 目标架构：arm64 iPhoneOS Release
- 验证设备：M 系列物理 iPad
- 完整可见 parity inventory：通过
- 真实 Provider 流式响应：通过
- 清理验证数据后的独立冷启动：通过
- 后台自动升级：已关闭

详细验收层级见 [Release Acceptance](RELEASE_ACCEPTANCE.md)。

## 用户功能矩阵

| 领域 | 当前实现与验收状态 |
|---|---|
| 应用外壳 | SwiftUI iPad scene、横竖屏、指针、触控、硬件键盘与生命周期已纳入 Release 真机闭环 |
| 桌面界面 | 桌面兼容 Web surface 由 WKWebView 承载，登录页、主界面、侧边栏、搜索、新聊天和导航状态已通过物理设备 parity |
| ChatGPT 登录 | OAuth/PKCE、系统认证会话、回调、token refresh 与 Keychain 持久化 |
| API Key 登录 | 独立 Keychain item、输入验证、凭据重试与官方 Responses 路由 |
| 模型选择器 | 登录后以账号实际返回的官方远端模型目录为准；版本化 fallback 仅用于恢复，不固定模型数量 |
| 流式聊天 | thread/turn 生命周期、流式事件、停止、恢复、错误投影和持久化；真实 Provider 预期响应已通过 |
| 项目与 iCloud | Files picker、安全作用域书签、项目列表、冷启动恢复；支持 Mac 与 iPad 操作同一个 iCloud Drive 项目目录 |
| 文件工具 | 工作区枚举、模糊搜索、UTF-8 读取、原子写入、补丁、图片查看和路径边界保护 |
| Git 与 Review | Git 状态、统一 Diff、变更投影、Review surface 与 review/start 路由 |
| Side Chat | 桌面路由、面板状态、会话绑定和硬件键盘入口 |
| Terminal | iPad terminal session、输入、resize、cwd、action、renderer panel 和物理快捷键链路已通过完整 parity |
| MCP | Streamable HTTP、OAuth、资源/工具调用、server status 与嵌入式 Node/Python transport |
| 设置与用量 | released settings、模型/推理强度、主题、账户状态、用量中心和实验特性目录 |
| Plugins/Skills | 目录、安装状态、远程插件、推荐技能和 AppHost 路由 |
| 本地状态 | SQLite 会话与事件存储、迁移快照、归档会话、冷启动恢复和 renderer 投影 |
| 验证隔离 | UI 验证工作区、验证聊天、选中项目和最后活动线程不会残留到正常用户启动 |
| 自动更新 | 已移除；不会安装 LaunchAgent、后台探测、下载、替换或删除包，升级为显式手动流程 |

## 平台边界

这些是 iPadOS 与桌面 macOS 的机制差异，不是当前发布阻塞：

1. iPadOS 不直接运行任意 macOS 可执行文件；终端和 MCP 使用 iPad 兼容 runtime 或 HTTP 服务。
2. iCloud Drive 的下载时机、冲突副本和离线可用性由 Apple Files 管理；应用负责安全书签与工作区操作。
3. Mac Keychain、桌面数据库和本地设置不会复制到 iPad；两端接力的是项目目录。
4. Personal Team 免费签名需要按 Apple 生命周期定期重新签名。
5. 模型最终可见数量取决于官方远端目录、账号权限和服务端发布状态。
6. 自定义 Provider 必须分别适配并验收模型、流式事件和工具协议。

## 发布验收门槛

每个后续桌面基线都必须重新满足：

1. Swift、Rust、Python 和 shell 契约检查通过；
2. arm64 iPhoneOS Release 构建通过；
3. 使用开发签名安装到物理 M 系列 iPad 并独立冷启动；
4. 登录、模型目录、项目、聊天、文件、Git/Review、Side Chat、Terminal、MCP 和设置关键路径通过；
5. 真实 Provider 返回预期流式响应；
6. 验证数据清理后，正常用户启动没有测试项目或测试聊天；
7. 公共仓库安全门禁不包含凭据、签名、设备或官方发行物。

## 持续维护

完整产品基线已经关闭。后续计划集中在新桌面版本适配、更广 Provider/MCP 矩阵、更多键盘布局，以及 iCloud 冲突状态可视化，详见根目录 [ROADMAP](../ROADMAP.md)。
