# Getting Started on a Physical iPad

本教程从干净克隆开始，生成本地依赖、使用自己的 Apple Personal Team 签名，在物理 iPad 上运行应用，并打开 Mac 与 iPad 共用的 iCloud Drive 项目。

## 你需要准备

- Apple Silicon Mac。
- Xcode 27 或兼容的更新版本。
- iPadOS 18 或更高版本的 iPad；M 系列 iPad 为主要目标。
- 数据线或已建立可信配对的无线调试连接。
- `python3`、`node`、`npm`、`rustup`、`cargo` 和 `maturin`。
- 你自己合法取得的官方 macOS `ChatGPT.dmg`。
- 已在 Xcode 登录的 Apple ID。免费的 Personal Team 可用，但安装通常需要定期重新签名。

先检查工具：

```bash
xcodebuild -version
python3 --version
node --version
npm --version
rustup --version
cargo --version
maturin --version
```

## 第一步：克隆并准备本地构建输入

```bash
git clone https://github.com/Mars535821089-ops/Codex-for-ipad.git
cd Codex-for-ipad
./scripts/bootstrap_public_build.sh /absolute/path/to/ChatGPT.dmg
```

脚本按顺序执行：

1. 检查必需命令和 DMG 路径。
2. 添加 iOS Rust targets：`aarch64-apple-ios`、`aarch64-apple-ios-sim`、`x86_64-apple-ios`。
3. 校验 DMG 及其中应用的签名、Bundle ID 和签名 Team。
4. 在本地导入桌面包并生成协议、IPC、界面和功能清单。
5. 下载锁定版本的 BeeWare Python Apple runtime（若本地不存在）。
6. 本地重建 iOS Python MCP package snapshot。
7. 构建 `CodexCore.xcframework`。
8. 根据导入包的 version/build 重新生成 Xcode 工程和构建元数据。

所有提取资源和生成二进制都留在本机，并由 `.gitignore` 排除。

## 第二步：配置个人签名

```bash
open CodexPad/CodexPad.xcodeproj
```

在 Xcode 中选择 `CodexPad` target：

1. 打开 **Signing & Capabilities**。
2. 勾选 **Automatically manage signing**。
3. 选择自己的 Personal Team。
4. 将 Bundle Identifier 改为唯一值，例如 `dev.yourname.codexforipad`。
5. 在 Xcode 顶部选择已连接的物理 iPad。
6. 点击 Run。

不要把 Team ID、设备 UDID、证书、描述文件或导出的 IPA 提交到仓库。

## 第三步：打开 iCloud Drive 项目

1. 在 Mac 的 iCloud Drive 中建立项目目录，例如 `iCloud Drive/Projects/MyProject`。
2. 等待 Finder 显示同步完成。
3. 在 iPad 打开 Codex for ipad。
4. 点击 **Choose project…**，在系统 Files 选择器中选择同一个目录。
5. 应用保存该目录的 iPadOS security-scoped bookmark；下次启动时用书签恢复访问。

这不是 CloudKit 数据库复制，也不会把 Mac 的整个 Codex 应用状态搬到 iPad。共享的是你选择的文件夹内容；文件下载、上传、冲突副本和同步时机由 iCloud Drive/iPadOS 管理。

## 第四步：登录和发送第一条消息

应用提供 ChatGPT OAuth 和 API Key 路径。API Key 与 OAuth credential 使用 Apple Keychain 本地保存，不写入项目文件。

首次验收建议依次确认：

1. 登录后重新启动应用，账号状态仍存在。
2. 选择工作区后能列出文本文件。
3. 新建聊天并发送一条只读请求。
4. 再尝试产生文件修改并打开 Review。
5. 回到 Mac 等待 iCloud Drive 同步，检查实际文件差异。

## 验证

源码级检查：

```bash
python3 -m pytest tests
swift test --package-path CodexPad
cargo test --manifest-path CodexCore/Cargo.toml
```

真机检查必须使用自己的签名配置。模拟器不等价于 Keychain、Files provider、security-scoped bookmark、物理键盘或真实网络登录验收。

## 常见问题

### `missing required command`

安装输出中点名的工具，然后重新运行 bootstrap。脚本不会静默跳过缺失依赖。

### Xcode 显示 Provisioning Profile 或 Bundle ID 错误

确认 Xcode 已登录 Apple ID、选择了 Personal Team、Bundle ID 唯一，并保持 Automatically manage signing 开启。

### Files 中选择了目录，但文件尚未可读

在 Files 中确认目录已从 iCloud 下载到设备。大文件、非 UTF-8 文本、符号链接和超出目录根的路径会被工作区访问层拒绝。

### 登录回调没有返回应用

确认生成工程保留 `codex` URL scheme，并在真实设备上重新发起登录。网络代理、内容过滤器和系统浏览器会话也会影响 OAuth 回调。

### 免费签名过期

重新连接 iPad，在 Xcode 中再次 Run。免费 Personal Team 的有效期由 Apple 控制，项目不在后台自行重签。

### 更新到新版桌面资源

获取新版 DMG 后再次运行 bootstrap。项目不安装后台自动更新任务。
