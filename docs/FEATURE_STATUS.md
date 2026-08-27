# Feature Status and Product Boundaries

本文档说明功能“做到什么程度”。状态按实现、源码测试和真机证据分层，避免把文件数量、编译通过或静态 parity 报告等同于完整用户验收。

## 产品目标

目标是在 M 系列 iPad 上提供尽量接近最新版桌面 Codex 的可见界面、交互、状态、流程和功能。平台机制允许不同：macOS 的 Electron、shell、窗口、进程和文件权限模型必须映射到 iPadOS 的 SwiftUI、WKWebView、Files、Keychain 和嵌入 runtime。

本项目不是官方源码泄漏，也不声称逐字节复刻官方内部实现。公开内容由项目自身 Swift/Rust/脚本、兼容层、测试和本地生成流程组成；用户本地导入的官方资源不进入仓库。

## 用户功能矩阵

| 领域 | 仓库实现 | 当前证据/边界 |
|---|---|---|
| 应用外壳 | iPad 原生 SwiftUI scene、横竖屏、指针和键盘 command | 源码存在；Release arm64 真机包在开发阶段构建、签名、安装并运行过 |
| 桌面界面 | 本地导入桌面 Web surface，WKWebView 承载，native AppHost bridge | 登录页、主界面、侧边栏、搜索、新聊天、聊天提交、Side Chat、Review 路径曾在物理 iPad parity 测试中通过 |
| ChatGPT 登录 | OAuth/PKCE、系统认证会话、回调和 token refresh | 需要真实网络、账号和设备验证；凭据写入 Keychain |
| API Key 登录 | API Key 提交、Keychain 持久化、Responses 路由 | 实现和测试存在；真实账号额度、模型权限与服务端错误不由应用保证 |
| Provider | Adapter/client 分层、官方产品路由与 API key 路由分离 | 不是所有第三方 endpoint 的通用兼容承诺；每个 Provider 需单独验收模型、流和工具协议 |
| 流式聊天 | Swift stream adapter、Rust parser、turn/event state | 源码与测试覆盖；最终体验取决于 Provider 返回事件和网络 |
| 项目/工作区 | Files picker、安全书签、项目列表、持久恢复 | 实现；iCloud 文件可用性由 Files provider 决定 |
| 文件操作 | 枚举、UTF-8 读取、原子写入、patch、diff/review | 读取/写入上限 2 MiB；跳过符号链接；拒绝根目录逃逸 |
| Git | Rust git worker/diff、状态与审阅桥 | 适用于 iPad 可访问工作区；凭据与远端网络仍需实际配置 |
| Review | 变更投影、统一 diff 和 Review surface | 物理 iPad关键路径曾通过；复杂仓库和大型 diff 仍需扩大验收矩阵 |
| Terminal | iPad 兼容 terminal AppHost、session manager、快捷键映射 | 服务实现存在；`Control+\`` 触发 renderer panel 的真机断言仍是当前已知失败点 |
| Side Chat | AppHost 路由、界面状态和硬件快捷键 | 物理 iPad关键路径曾通过 |
| MCP | HTTP、OAuth、资源、embedded stdio、Node/Python runtime | iPad 不能运行任意 macOS 二进制；server 必须适配 embedded runtime 或 HTTP |
| 设置/模型/用量 | released settings、model catalog、usage center | 源码存在；需要继续补充真实账号/Provider 的端到端矩阵 |
| 自动更新 | 已移除 | 不安装 LaunchAgent，不后台探测、下载、替换或删除包；只保留失败关闭的兼容 stub 和显式手动流程 |
| iCloud 项目接力 | Mac/iPad 选择同一 iCloud Drive 目录 | 同步项目文件，不同步完整应用数据库、Keychain、账号或全部聊天状态 |

## 已知未完成项

1. **Terminal 物理快捷键**：最新完整物理 iPad parity 回归的唯一断言失败为 renderer 未创建 Terminal panel。服务和事件重试代码存在，但尚未形成根因修复证据。
2. **Provider 兼容矩阵**：需要继续覆盖真实流式响应、工具事件、错误恢复、限流和不同模型目录。
3. **完整设置与扩展路径**：Settings、Projects、Files、MCP、plugins/skills、remote control 等服务面很大，源码和契约测试不等于每条路径都已在真机逐项操作。
4. **iCloud 冲突体验**：系统可能生成冲突副本。当前依靠 Files/Finder 解决，应用内冲突可视化仍可加强。
5. **免费签名生命周期**：Apple Personal Team 可能要求定期重新签名；项目不会绕过 Apple 的签名规则。

## 明确不是本项目承诺的能力

- 不提供官方支持、OpenAI 认可或 App Store 分发保证。
- 不分发官方 DMG、提取后的 `app.asar`、官方二进制或已签名 IPA。
- 不让 iPad 直接执行任意 macOS 可执行文件。
- 不保证 iCloud 实时同步，也不自动解决同文件并发修改。
- 不把 Mac 上的 Keychain、账号、聊天数据库或本地设置自动复制到 iPad。
- 不保证每个自定义 Provider 都与官方事件协议完全兼容。
- 不在后台自动下载和安装新版应用。

## 何时可以称为“完成”

发布候选必须同时满足：

1. 当前输入版本与 build identity 明确。
2. Swift、Rust、Python 和 shell 契约测试通过。
3. iPhoneOS Release 构建和签名通过。
4. 安装到目标物理 iPad 成功。
5. 登录、凭据恢复、项目打开、真实聊天、文件修改、Review、Terminal、MCP 和关键设置在真机有证据。
6. 退出和重新打开应用后状态符合预期。
7. 手动升级能保留需要的数据，并有回滚/归档证据。

当前公开仓库包装已经完成；产品真机全量验收仍因上述项目保持开放。Issue 中报告问题时，请明确它属于源码、构建、签名、安装、登录、网络、Provider 还是具体真机交互层。
