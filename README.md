<div align="center">

# Codex for ipad

**把 Mac 上的 Codex 项目带到 iPad。通过 iCloud Drive 打开同一个工作区，随时随地 Vibe Coding。**

Bring your Codex workspace from Mac to iPad. Open the same project through iCloud Drive and keep coding wherever you are.

[![Platform](https://img.shields.io/badge/platform-iPadOS%2018%2B-black?logo=apple)](#运行要求)
[![Swift](https://img.shields.io/badge/Swift-6-orange?logo=swift)](CodexPad)
[![Rust](https://img.shields.io/badge/Rust-Core-black?logo=rust)](CodexCore)
[![License](https://img.shields.io/badge/license-MIT-blue)](LICENSE)

**如果这个项目让你的 iPad 真正成为移动开发工作站，请点一个 Star ⭐**

</div>

## 最厉害的能力：Mac ↔ iPad 项目接力

把项目目录放在 **iCloud Drive**：

1. 在 Mac 上用 Codex 打开并开发项目；
2. iCloud Drive 同步项目文件；
3. 在 iPad 的 Codex for ipad 中选择同一个文件夹；
4. 应用通过 iPadOS 安全作用域书签持续访问该工作区；
5. 随时查看文件、聊天、生成修改、审阅差异并继续编码。

它不是另建一份“移动副本”，而是让 Mac 和 iPad 面向同一个项目目录工作。实际同步时机与冲突处理由 iCloud Drive 和 iPadOS 文件系统负责。

## 功能

- iPad 原生 SwiftUI 外壳，适配 iPad 横竖屏、键盘和指针
- 与桌面 Codex 接近的主界面、侧边栏、搜索、新聊天、Review、Side Chat 与 Terminal 交互
- ChatGPT 登录与自定义 Provider / API Key
- API Key 存储在 Apple Keychain
- 流式聊天、工具调用与工作区文件访问
- 文件浏览、读取、写入、补丁应用和差异审阅
- MCP、Python 与 Rust 核心运行时
- iCloud Drive / Files 文件夹选择与持久安全书签
- 面向 M 系列 iPad 的真机构建与验收流程
- 手动导入新版桌面资源；没有后台自动下载或自动升级

## 运行要求

- Apple Silicon Mac
- Xcode 27 或兼容的更新版本
- iPadOS 18+
- M 系列 iPad 推荐
- Rust toolchain、Python 3、Node.js/npm、maturin
- 你自行获取的最新版官方 Codex/ChatGPT macOS DMG
- Apple ID 的 Personal Team 即可真机安装；免费签名通常需要定期重签

## 为什么仓库里没有 DMG、IPA 和桌面资源

本仓库只发布项目自身的 Swift、Rust、脚本和测试源码，不包含：

- 官方 `ChatGPT.dmg`
- `app.asar` 或提取后的桌面 Web 资源
- 官方 Codex 二进制
- 已签名 IPA、证书、Provisioning Profile
- 个人 Team、设备 UDID、账号、聊天和项目数据

请使用你自己取得的桌面安装包在本机生成所需资源。生成内容会进入已被 `.gitignore` 排除的 `artifacts/`、`versions/` 和 `build/`。

## 快速开始

```bash
git clone https://github.com/Mars535821089-ops/Codex-for-ipad.git
cd Codex-for-ipad

# 一次性准备依赖、导入你本机的官方 DMG，并生成 Xcode 工程
./scripts/bootstrap_public_build.sh /path/to/ChatGPT.dmg

open CodexPad/CodexPad.xcodeproj
```

然后在 Xcode 中：

1. 选择 `CodexPad` Target → **Signing & Capabilities**；
2. 选择自己的 Personal Team；
3. 把 Bundle Identifier 改成你自己的唯一值；
4. 连接 iPad，选择真机作为运行目标；
5. 点击 Run。

详细步骤见 [BUILDING.md](BUILDING.md)。

## iCloud Drive 使用方式

1. Mac：把代码目录移动到 iCloud Drive，例如 `iCloud Drive/Projects/MyProject`。
2. 等待 Finder 显示文件同步完成。
3. iPad：打开 Codex for ipad，点击 **Choose project…**。
4. 在系统文件选择器中进入 iCloud Drive，选择 `MyProject` 文件夹。
5. 首次选择后，应用保存安全作用域书签；下次可继续访问同一工作区。

> 建议避免 Mac 和 iPad 同时修改同一个文件。若 iCloud 产生冲突副本，先在 Files/Finder 中完成合并，再继续让 Codex 修改。

## Provider 与密钥

LLM 能力通过 Provider / Adapter 配置接入，不把业务逻辑锁死到单一模型。密钥写入 iOS Keychain，不应提交到 Git、配置示例、Issue 或日志。

## 项目结构

```text
CodexPad/   iPadOS SwiftUI 应用、领域测试与 UI 测试
CodexCore/  Rust 核心与 iOS FFI
scripts/    桌面包导入、工程生成、构建、签名和验收工具
tests/      Python 契约与发布流水线测试
```

## 路线图

- [ ] 扩大真实 Provider 的流式响应兼容矩阵
- [ ] 完成更多桌面快捷键的物理键盘验收
- [ ] 加强 iCloud 冲突提示与项目状态可视化
- [ ] 简化首次构建与 Personal Team 签名流程
- [ ] 持续提升桌面 Codex 功能与交互一致性

欢迎提交 Issue、Discussion 和 Pull Request。先读 [CONTRIBUTING.md](CONTRIBUTING.md)。

## 免责声明

这是非官方社区项目，与 OpenAI 没有隶属、认可或赞助关系。Codex、ChatGPT、OpenAI 及相关标识属于其各自权利人。项目源码使用 MIT License；第三方组件和用户自行导入的资源适用其各自许可与条款。
