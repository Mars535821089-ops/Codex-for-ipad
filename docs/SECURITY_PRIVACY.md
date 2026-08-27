# Security and Privacy

本项目会接触代码、凭据、聊天和远端服务。默认原则是：凭据放 Keychain，项目访问必须由用户通过 Files 授权，生成物与个人签名不进入公开仓库，日志只记录诊断所需的最少信息。

## 数据存放位置

| 数据 | 位置 | 是否通过项目自动同步 |
|---|---|---|
| ChatGPT OAuth tokens | iPad 本机 Keychain，ThisDeviceOnly | 否 |
| OpenAI API Key | iPad 本机 Keychain，ThisDeviceOnly | 否 |
| Git credential | iPad 本机 Keychain，ThisDeviceOnly | 否 |
| MCP OAuth credential | iPad 本机 Keychain | 否 |
| Thread/session/event state | App sandbox Application Support 的 SQLite | 否 |
| Migration snapshots | App sandbox Application Support | 否 |
| Workspace bookmark | App state中的安全作用域书签数据 | 书签本身不是项目文件 |
| 项目文件 | 用户选择的 Files/iCloud Drive 目录 | 由 iCloud Drive 决定 |
| 本地 DMG 提取物和构建产物 | `artifacts/`、`versions/`、`build/` 等 ignored 路径 | 不进入 Git |

`ThisDeviceOnly` 表示 credential 不应被 iCloud Keychain 同步到另一设备。卸载应用、改变签名身份或系统清理可能导致需要重新登录。

## Keychain 行为

Keychain store 使用 update-then-add，并处理并发写入产生的 duplicate-item race。OAuth token 体积较大，采用分组件记录和 manifest revision；只有 manifest 与全部组件一致时才恢复 credential，避免应用使用半写入状态。

公开日志、Issue 和测试 fixture 应只使用明显占位值。不要提交真实 key、cookie、authorization header、OAuth token、证书或账号导出。

## 文件系统边界

工作区访问层执行以下检查：

- 路径必须是非空相对路径。
- 拒绝以 `/` 开头或包含 `..` 的路径。
- 标准化并解析符号链接后必须仍位于工作区根目录。
- 枚举跳过符号链接后代。
- 仅读取 UTF-8 普通文件。
- 单次文本读取或写入不超过 2 MiB。
- 写入使用原子替换。
- 安全作用域 access lease 用完后释放。

用户授予的是所选文件夹范围，不是整个 iPad 文件系统。Files provider 仍可能在文件未下载、权限撤销或 bookmark stale 时拒绝访问。

## 网络与 Provider

- OAuth 和 API Key 路由分离。
- API Key 不应发送到 ChatGPT account-only endpoint。
- ChatGPT OAuth token 不应作为普通 API key 转发。
- MCP HTTP/OAuth server 属于用户配置的第三方信任边界。
- 自定义 Provider 能看到发送给它的 prompt、文件上下文和工具结果；使用前应审阅其隐私条款。
- `NSAllowsLocalNetworking` 允许本地网络服务，但不代表应用自动扫描局域网。

## 源码和第三方边界

公开仓库刻意排除：

- `*.dmg`、`*.app`、`*.asar`、`*.ipa`、`*.xcarchive`、`*.mobileprovision` 和证书。
- 官方桌面提取资源和官方二进制。
- Team ID、device UDID、个人 Bundle ID 和个人绝对路径。
- `.env`、`auth.json`、`settings.json`、API keys 和 tokens。
- DerivedData、target、build cache 和本地 Python XCFramework。

第三方组件保留自己的许可证。仓库根 MIT License 只覆盖项目自身原创代码，不重新许可用户本地导入的官方资源或第三方依赖。

## 签名与分发

每个用户使用自己的 Apple Team 和唯一 Bundle ID。已签名 IPA 可能包含设备、团队和 provisioning 信息，而且个人签名通常不能供其他人安装，因此不应上传公开 Release。

项目不会绕过 Apple code signing。免费 Personal Team 的重签周期、设备信任和 provisioning 由 Apple/Xcode 管理。

## 日志与问题报告

提交 Issue 前请删除：

- Authorization/Cookie header。
- 完整 API key/token。
- Apple ID、邮箱、真实用户名和私人仓库 URL。
- Team ID、UDID、设备序列号和 provisioning profile。
- 私人聊天内容、项目源文件和本地绝对路径。

建议保留：错误类别、HTTP 状态、已脱敏 request ID、应用 version/build、iPadOS/Xcode 版本、可复现步骤和最小日志片段。

## 漏洞报告

不要把未修复的凭据泄漏、路径逃逸、任意代码执行或认证绕过细节直接发布为公开 Issue。使用 GitHub 仓库已启用的 **Private vulnerability reporting**，流程和支持范围见根目录 [SECURITY.md](../SECURITY.md)。

## 删除应用后的预期

iPadOS 删除应用通常会删除其 app sandbox 数据，包括 SQLite、迁移快照和本地书签状态；Keychain item 的生命周期受系统和签名身份影响，不能用“删除 UI 数据”推断 Keychain 一定同步清除。项目文件本身位于用户选择的 iCloud Drive/Files 目录，不属于应用沙盒，删除应用不应删除该工作区。
