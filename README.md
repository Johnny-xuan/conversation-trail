# Conversation Trail

为 ChatGPT 长对话提供问题轨迹、回复大纲与可选的系统音频声浪，让阅读和回看更轻松。

**v0.1.0** · [下载](https://github.com/Johnny-xuan/conversation-trail/releases)

## 主要功能

### 问题轨迹

在页面右侧整理当前对话中的用户提问。展开轨迹即可浏览问题，点击直接跳转；滚动阅读时，当前位置会同步标记，方便回看前面的讨论。

### 回复大纲

在页面左侧展示当前正在阅读的回复章节，支持多级标题。点击标题即可定位到对应内容，不必在长回答中反复寻找。

两侧轨迹平时收起为简洁的细线，展开时显示完整内容。独立的阅读定位点始终标记当前位置，并支持键盘操作、深色模式和系统的减少动态效果设置。

### 系统音频声浪

开启声浪后，两侧细线会跟随 Mac 正在播放的声音变化：左侧大纲对应左声道，右侧问题轨迹对应右声道，不同位置呈现不同频段的起伏。

声浪来自真实音频，不是预设动画。静音时线条恢复平静，操作目录时让位于导航，阅读定位点不随声浪移动。

这是一个可选功能：默认关闭，开启后会记住你的选择；不安装本地音频组件，也能完整使用问题轨迹和回复大纲。

## 安装

需要 Google Chrome 116 或更新版本。系统音频声浪需要 macOS 13 或更新版本；当前下载包面向 Apple Silicon Mac。

1. 从 [Releases](https://github.com/Johnny-xuan/conversation-trail/releases) 下载 ZIP，解压到准备长期保留的位置。
2. 如需声浪功能，双击包内的 **Conversation Trail Audio.pkg**，按提示安装。安装器会一并安装 Local Audio Engine 和连接组件，过程中需要管理员授权。
3. 打开 `chrome://extensions`，开启右上角的“开发者模式”。
4. 点击“加载已解压的扩展程序”，选择包内的 **Conversation Trail Extension** 文件夹。
5. 打开或刷新 ChatGPT 页面，即可使用两侧导航。

**加载后不要删除或移动扩展文件夹**，Chrome 仍需要从中读取文件。

带有 `-preview` 后缀的安装包尚未完成 Apple 公证，macOS 可能显示安全提示或阻止安装。请以 Release 中标注的签名与公证状态为准。

## 使用声浪

1. 安装本地音频组件后，在 ChatGPT 页面点击 Chrome 工具栏中的扩展图标。
2. 开启“系统音频声浪”。Local Audio Engine 会自动启动，无需提前打开应用。
3. 首次使用时，按 macOS 提示授予系统音频权限；授权后自动继续连接。
4. 播放音乐或其他系统声音，即可看到两侧轨迹的变化。

开关适用于当前 Chrome 配置中的所有 ChatGPT 页面。刷新页面、重新打开 ChatGPT 或重启 Chrome 后，都会按保存的选择恢复；主动关闭后也会记住关闭状态。

关闭最后一个 ChatGPT 页面会暂停音频订阅，但保留开关选择。等待授权或连接暂时失败时，也不会把已保存的开启状态改为关闭；需要时可在扩展菜单中选择“继续授权”或“重新连接”。

## 隐私与权限

- 音频只在本机处理，不录音，不保存音频或声浪历史。
- 不识别语音、不转写内容，不上传音频或声浪数据。
- 扩展只在当前 Chrome 配置中保存声浪开关选择。
- 本地音频服务只接受本机连接，不向局域网开放。
- 多个页面共享音频订阅；没有客户端订阅时，Engine 停止捕获。

macOS 通过“屏幕与系统音频录制”权限提供系统声音。Local Audio Engine 只接收音频，不捕获画面，不截图，也不保存屏幕内容。

## 从源码运行与构建

完整的本地音频构建需要 macOS、Node.js、Python 3 和 Xcode 命令行工具。

```sh
npm ci
npm run engine:install
npm run relay:install
```

随后在 `chrome://extensions` 中加载包含 `manifest.json` 的项目根目录。更新代码后，重新加载扩展并刷新 ChatGPT 页面。

生成包含音频安装器和扩展的统一 ZIP：

```sh
npm run release:build
```

产物位于 `dist/`，默认使用当前 Mac 的架构。可通过 `LOCAL_AUDIO_ENGINE_ARCH=arm64` 或 `x86_64` 指定构建目标。

<details>
<summary>签名、公证与开发检查</summary>

默认构建生成未公证的预览包。使用 Developer ID 签名并完成 Apple 公证：

```sh
LOCAL_AUDIO_ENGINE_SIGNING_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
CONVERSATION_TRAIL_INSTALLER_IDENTITY="Developer ID Installer: Your Name (TEAMID)" \
CONVERSATION_TRAIL_NOTARY_PROFILE="your-notary-keychain-profile" \
npm run release:build
```

公证凭据需先通过 `xcrun notarytool store-credentials` 保存到钥匙串，不写入项目。构建脚本会等待公证成功并附加票据，再生成不带 `-preview` 后缀的 ZIP。

```sh
npm test
npm run engine:test
```

音频服务独立于浏览器扩展，通过本地协议提供数据。接口与生命周期说明见 [Local Audio Engine Protocol](docs/local-audio-engine-protocol.md)。

</details>

## 致谢

感谢 [grid-oaa/ChatGPT-helper](https://github.com/grid-oaa/ChatGPT-helper) 提供的问题目录与回复大纲设计基础。
