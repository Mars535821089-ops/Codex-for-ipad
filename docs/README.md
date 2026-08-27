# Documentation

这里是 **Codex for ipad** 的完整文档入口。README 负责快速介绍，本文档目录负责交代实现、边界、构建、验证、隐私和维护细节。

## 阅读顺序

1. [Getting Started](GETTING_STARTED.md) — 从克隆仓库到真机首次运行，再到打开 iCloud Drive 项目。
2. [Feature Status](FEATURE_STATUS.md) — 功能矩阵、完成度定义、当前已知问题和平台差异。
3. [Architecture](ARCHITECTURE.md) — SwiftUI、WebView、AppHost、Rust Core、SQLite、Keychain、MCP 和工作区访问的关系。
4. [Build, Release and Testing](BUILD_RELEASE_TESTING.md) — 依赖锁定、DMG 导入、构建、签名、真机安装、测试和手动更新。
5. [Security and Privacy](SECURITY_PRIVACY.md) — 数据位置、密钥处理、文件访问边界、公开仓库排除项和漏洞报告。

## 一句话边界

本仓库发布的是一个非官方 iPadOS 兼容实现及其构建、分析和验收工具。它不会分发官方 DMG、官方提取资源、官方二进制、已签名 IPA、证书、Provisioning Profile、账号或个人数据。

## 文档状态词

| 状态 | 含义 |
|---|---|
| Implemented | 仓库中存在生产实现和对应接口；不等于所有 Provider、账号和设备组合都已验证。 |
| Source-tested | 相关 Swift、Rust 或 Python 测试覆盖了该行为。 |
| Device-verified | 已在物理 iPad 的特定构建和测试路径中观察到结果。 |
| Pending | 仍需要实现、修复或补充证据。 |
| Platform difference | iPadOS 的系统机制与 macOS 不同，行为目标一致但实现不会逐字节相同。 |

项目不会仅凭“编译通过”宣称所有功能完成。最终结论必须分别说明源码、自动化测试、构建、签名、安装和真机端到端证据。
