<div align="center">

# Codex for ipad

### 把桌面 Codex 的完整工作方式带到 M 系列 iPad

**同一套界面 · 同一类项目工作流 · 官方模型目录 · iCloud Drive 双端接力**

在 Mac 上开始，在 iPad 上继续。打开同一个项目、延续同一种 Codex 操作习惯，随时随地 Vibe Coding。

[![Platform](https://img.shields.io/badge/platform-iPadOS%2018%2B-black?logo=apple)](#运行要求)
[![Device](https://img.shields.io/badge/verified-M--series%20iPad-black?logo=apple)](#验证标准)
[![Swift](https://img.shields.io/badge/Swift-6-orange?logo=swift)](CodexPad)
[![Rust](https://img.shields.io/badge/Rust-CodexCore-black?logo=rust)](CodexCore)
[![Models](https://img.shields.io/badge/models-official%20catalog-10a37f)](#模型与-provider)
[![License](https://img.shields.io/badge/license-MIT-blue)](LICENSE)

**如果你也想让 iPad 成为真正的移动 Codex 工作站，欢迎点亮 Star ⭐**

</div>

---

## 这是什么

Codex for ipad 是一个以**最新版桌面 Codex 的可见界面、交互、状态、流程和功能**为兼容标准构建的 iPadOS 项目。

它不是重新设计的“AI 聊天 App”，也不是只保留输入框和文件列表的轻量客户端。项目采用：

- **桌面 Codex 界面资源**作为用户界面基准；
- **SwiftUI + WKWebView**重建桌面窗口、菜单、键盘和触控交互；
- **AppHost 兼容层**承接桌面界面所调用的原生能力；
- **Rust CodexCore**负责会话、模型、Provider、流式事件、Git 和持久化；
- **iPadOS 原生服务**替代 macOS 专属机制，包括 Keychain、Files、安全作用域书签和系统认证会话。

目标不是“长得像 Codex”，而是让桌面 Codex 的核心工作流在 iPad 上真正运转。平台机制允许存在实现差异，但用户面对的产品结构、操作路径和状态表达以桌面版为准。

## 核心亮点：Mac ↔ iPad 项目接力

Codex for ipad 最有价值的能力，是通过 **iCloud Drive 让 Mac 与 iPad 面向同一个项目目录工作**：

```text
Mac 上的 Codex ──读取 / 修改──┐
                              ├── iCloud Drive / Projects / YourProject
Codex for ipad ──安全书签──────┘
```

1. 在 Mac 上使用桌面 Codex 创建或开发项目；
2. 把项目放入 iCloud Drive；
3. 在 iPad 上通过系统 Files 选择同一个目录；
4. Codex for ipad 保存安全作用域书签，持续访问该工作区；
5. 在 iPad 上继续聊天、查看代码、修改文件、应用补丁、审阅 Diff；
6. 回到 Mac 后，继续处理同步后的同一套项目文件。

这不是导入后生成一份孤立副本。两个设备操作的是同一个 iCloud Drive 工作区。文件同步时机与冲突副本由 Apple Files/iCloud Drive 管理；应用不会把 Mac 的 Keychain 或本地数据库复制到 iPad。

## 按桌面 Codex 标准实现了什么

| 桌面 Codex 体验 | Codex for ipad 的实现 |
|---|---|
| 桌面主界面 | 本地导入桌面 Web surface，由 WKWebView 承载，并通过原生 bridge 驱动 |
| 侧边栏与项目 | 项目列表、最近会话、选择项目、新聊天、搜索和导航状态 |
| 对话与任务 | thread/turn 生命周期、流式回复、停止、恢复、错误终止和持久化投影 |
| 模型选择器 | 登录后以官方远端模型目录为准；内置版本化 fallback，并生成 Swift/Rust 双端目录 |
| ChatGPT 登录 | OAuth/PKCE、系统认证会话、回调、token refresh 与 Keychain 持久化 |
| API Key 登录 | 独立 Keychain item 与官方 Responses 路由，不与 ChatGPT token 混用 |
| 文件工具 | 工作区枚举、模糊搜索、UTF-8 读取、原子写入、补丁应用和路径边界保护 |
| Git 与 Review | Git 状态、统一 Diff、变更投影、Review surface 和 review/start 路由 |
| Side Chat | 桌面 Side Chat 路由、面板状态、会话绑定和物理键盘入口 |
| Terminal | iPad 兼容 terminal session、输入、resize、cwd、action 与 renderer 面板协议 |
| MCP | Streamable HTTP、OAuth、资源目录、server status，以及嵌入式 Node/Python transport |
| 工具调用 | workspace tools、request user input、update plan、view image、MCP resource/tool 路由 |
| 设置与用量 | released settings、模型/推理强度、主题、账户状态、用量中心与实验特性目录 |
| 键盘工作流 | 新聊天、搜索、命令菜单、侧边栏、Review、Side Chat、Terminal、前后导航等映射 |
| 本地状态 | SQLite 会话/事件存储、迁移快照、冷启动恢复与状态投影 |
| iPad 交互 | 横竖屏、触控、指针、硬件键盘、系统文件选择器和 iPadOS 生命周期 |

仓库还包含 Downloads、Library/文件预览、历史快照、自动化、Marketplace、Plugins、Skills、远程控制、Realtime、GitHub、浏览状态和可视化等 AppHost 服务域。每个服务域都通过独立 Swift 类型和测试组织，而不是把所有行为写进单一 WebView 脚本。

## 模型与 Provider

模型选择器不是长期写死的一组名称：

- ChatGPT 登录路径从官方模型接口读取当前账号可见目录；
- 客户端版本与导入的桌面版本绑定，用于官方模型请求；
- 远端目录经过可见性、API 支持和分页规则处理；
- 本地 `models.json` 作为版本化 fallback，并生成对应 Swift catalog；
- 当前真机验收目录为 **7 个可见模型**：5.6 Sol、5.6 Terra、5.6 Luna、5.5、5.4、5.4 Mini、5.3 Codex Spark；
- Provider/Adapter 分层保留扩展能力，不把产品逻辑锁定到某一家第三方模型。

真实可见模型最终受账号权限、官方目录和服务端发布状态影响。

## 不是简单套壳：四层运行架构

```text
┌──────────────────────────────────────────────────────────────┐
│ SwiftUI scene · iPad layout · commands · recovery UI         │
├──────────────────────────────────────────────────────────────┤
│ Desktop Codex surface in WKWebView · injected native bridge  │
├──────────────────────────────────────────────────────────────┤
│ AppHost service routers                                      │
│ auth · projects · files · git · review · terminal · MCP      │
│ settings · plugins · skills · realtime · remote control      │
├────────────────────────┬─────────────────────────────────────┤
│ Swift domain/stores    │ Rust CodexCore through C ABI        │
│ account · session · UI │ thread · stream · SQLite · git      │
├────────────────────────┴─────────────────────────────────────┤
│ iPadOS: Keychain · Files · security bookmarks · URLSession   │
└──────────────────────────────────────────────────────────────┘
```

详细设计见 [Architecture](docs/ARCHITECTURE.md)。

## 安全与数据边界

- ChatGPT、OpenAI、Git 和 MCP 凭据分别存入 iOS Keychain；
- Keychain item 使用设备本地可访问策略，不写入仓库或示例配置；
- 工作区只通过用户选择的 Files URL 和安全作用域书签访问；
- 拒绝绝对路径、`..`、根目录逃逸及不安全符号链接目标；
- 文本写入采用原子替换；默认单文件上限为 2 MiB；
- 公开仓库已排除个人 Team、设备 UDID、账号、聊天、项目数据、证书和描述文件。

更多说明见 [Security & Privacy](docs/SECURITY_PRIVACY.md)。

## 运行要求

- Apple Silicon Mac
- Xcode 27 或兼容的更新版本
- iPadOS 18+
- 推荐 M 系列 iPad
- Rust toolchain、Python 3、Node.js/npm、maturin
- 用户自行取得的官方 Codex/ChatGPT macOS DMG
- Apple ID Personal Team；免费开发签名通常需要定期重新签名

## 快速开始

```bash
git clone https://github.com/Mars535821089-ops/Codex-for-ipad.git
cd Codex-for-ipad

# 准备依赖、验证并导入本机官方 DMG、生成 Xcode 工程
./scripts/bootstrap_public_build.sh /path/to/ChatGPT.dmg

open CodexPad/CodexPad.xcodeproj
```

在 Xcode 中：

1. 打开 `CodexPad` Target → **Signing & Capabilities**；
2. 选择自己的 Personal Team；
3. 将 Bundle Identifier 设置为自己的唯一标识；
4. USB 连接 iPad，并选择该真机作为运行目标；
5. 点击 **Run** 完成编译、签名和安装。

完整流程见 [BUILDING.md](BUILDING.md) 与 [Getting Started](docs/GETTING_STARTED.md)。

## 为什么仓库体积没有桌面安装包那么大

GitHub 发布的是本项目自身的 Swift、Rust、脚本、协议生成器和测试源码。以下内容由构建者在本机准备或生成，并被 `.gitignore` 隔离：

- 官方 `ChatGPT.dmg`；
- `app.asar` 与提取后的桌面 Web 资源；
- 官方 Codex 二进制与第三方 runtime 构建产物；
- XCFramework、DerivedData、IPA、证书和 Provisioning Profile；
- 个人账户、Team、设备、Keychain、聊天和项目数据。

这样既保留可复现的 iPad 工程，又避免把官方发行物、签名身份和私人数据混入公开仓库。

## 验证标准

本项目把“有源码”“测试通过”“成功构建”和“真机端到端通过”视为四个不同层级。

发布验证包括：

1. Swift Domain/Integration 测试；
2. Rust Core 与模型/Provider 协议测试；
3. Python 导入、生成、签名、归档和发布契约测试；
4. Shell 语法与事务边界检查；
5. arm64 iPhoneOS Release 构建和签名；
6. 物理 M 系列 iPad 安装、启动与 UI parity 测试；
7. 登录、模型目录、项目、聊天、文件、Review、Side Chat、Terminal、MCP 和设置路径的分层验收。

当前证据与仍在扩大的验收矩阵见 [Feature Status](docs/FEATURE_STATUS.md)。仓库不会用“能编译”代替“功能已在真机工作”。

## 项目结构

```text
CodexPad/   SwiftUI iPadOS 应用、AppHost 兼容层、Domain 与 UI 测试
CodexCore/  Rust 核心、C ABI、会话/Provider/Git/SQLite 实现
scripts/    DMG 导入、协议生成、XCFramework、构建、签名、验收与手动升级
tests/      Python 契约测试、发布门禁和完整性检查
docs/       架构、功能状态、构建发布、安全与上手文档
```

## 文档导航

- [从克隆到物理 iPad 首次运行](docs/GETTING_STARTED.md)
- [功能矩阵、真机证据与平台边界](docs/FEATURE_STATUS.md)
- [SwiftUI、WKWebView、AppHost、Rust、SQLite、Keychain、MCP 与 iCloud 架构](docs/ARCHITECTURE.md)
- [构建、签名、测试、发布、手动更新和回滚](docs/BUILD_RELEASE_TESTING.md)
- [安全、隐私、凭据和公开仓库排除项](docs/SECURITY_PRIVACY.md)
- [贡献指南](CONTRIBUTING.md)

## 更新策略

Codex for ipad 采用**显式手动升级**：导入新的官方桌面包、重新生成兼容资源、运行 parity/完整性门禁、构建并安装新的 Release。后台自动探测、下载和替换已关闭，升级过程保留版本身份、归档和回滚验证。

## 路线图

- [ ] 扩大不同真实账号与 Provider 的流式响应、工具事件和错误恢复矩阵
- [ ] 完成全部桌面快捷键在不同物理键盘布局上的真机验收
- [ ] 加强 iCloud 冲突提示与项目同步状态可视化
- [ ] 继续补齐 Settings、Projects、Files、MCP、Plugins/Skills 与 Remote Control 的逐项真机证据
- [ ] 简化 Personal Team 首次签名与手动升级流程
- [ ] 跟随桌面 Codex 更新持续维护界面、协议与行为一致性

## Star、Issue 与贡献

如果 Codex for ipad 对你有帮助：

1. 给仓库一个 **Star ⭐**；
2. 在 Issue 中附上 iPad 型号、iPadOS、桌面 Codex 版本、构建阶段和复现步骤；
3. 提交 Pull Request 前阅读 [CONTRIBUTING.md](CONTRIBUTING.md)；
4. 功能报告请明确区分源码、测试、构建、签名、安装和真机交互层。

## 项目声明

这是非官方社区项目，与 OpenAI 没有隶属、认可或赞助关系。Codex、ChatGPT、OpenAI 及相关标识属于其各自权利人。项目源码使用 MIT License；用户自行导入的资源与第三方组件适用其各自许可和条款。
