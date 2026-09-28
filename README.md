# Conversation Trail

中文 | [English](README.en.md)

本人经常在同一个 ChatGPT 对话里聊很久。网页端自带的 conversation trail 不够稳定，想回头找某个问题，只能在长页面里反复滚动。这就是为什么会有这个插件。

它给长对话加了两条导航：左边看回复，右边找问题。

- **回复大纲**：列出当前回答里的标题，点击就能跳到对应位置。回答还在生成时，大纲也会跟着更新。
- **问题轨迹**：列出这次对话里问过的问题，点击就能回到那一轮。
- **声浪模式（可选）**：按 ChatGPT 桌面端的声浪效果 1:1 复刻。播放音乐时，两侧导航会跟随左右声道一起律动，让长对话多一点沉浸感和陪伴感。不开启声浪、不安装音频组件，也不影响导航功能。

两条导航平时收在页面边缘，鼠标移上去才会展开。小圆点表示当前读到的位置。支持深色模式、键盘操作和系统的“减少动态效果”设置。

https://github.com/user-attachments/assets/7519b014-d2c3-42f2-bca4-13dc52a219a7

约 1 分 32 秒 · 中文配音，中英字幕

## 安装

需要 **Chrome 116+**。如果要使用声浪，还需要 **macOS 13+**；当前下载包适用于 **Apple Silicon Mac**。

1. 从 [Releases](https://github.com/Johnny-xuan/conversation-trail/releases) 下载 ZIP 并解压。
2. 如果要使用声浪，双击 **Conversation Trail Audio.pkg** 完成安装。只用导航可以跳过这一步。
3. 打开 `chrome://extensions`，开启右上角的“开发者模式”。
4. 点击“加载已解压的扩展程序”，选择压缩包里的 **Conversation Trail Extension** 文件夹。
5. 打开或刷新 [ChatGPT](https://chatgpt.com/)。

Chrome 会直接读取这个文件夹，所以安装后不要移动或删除它。

带 `-preview` 后缀的安装包尚未完成 Apple 公证，macOS 可能会拦截安装。具体情况以对应的 Release 说明为准。

## 使用

- **回到之前的问题**：把鼠标移到右侧细线上，展开问题列表，点击问题即可回到对应的一轮对话。
- **查看当前回复的大纲**：左侧会列出当前回答中的标题，点击标题即可跳转。没有标题的回答不会显示大纲。
- **确认阅读位置**：滚动页面时，两侧的小圆点会跟随当前问题和当前标题。

要开启声浪，点击 Chrome 工具栏里的扩展图标，再打开“系统音频声浪”。Local Audio Engine 会自动启动；第一次使用时，按 macOS 的提示授予系统音频权限即可。之后播放音乐或其他系统声音，两侧导航就会跟着声音起伏。

声浪开关会自动保存，并对当前 Chrome 配置中的所有 ChatGPT 页面生效。刷新页面或重启 Chrome 后不需要重新开启。遇到授权或连接问题时，可以在扩展菜单中点击“继续授权”或“重新连接”。

## 隐私

扩展不会保存聊天内容，只会保存声浪开关的状态。

开启声浪后，Local Audio Engine 会在本机内存中把系统音频转换成频谱数据。它不会把音频录成文件，不做语音识别或转写，也不会上传音频或频谱数据。

macOS 把这项权限归在“屏幕与系统音频录制”中，但 Local Audio Engine 只接收音频，不捕获画面。音频服务只接受本机连接；没有客户端使用时，会自动停止捕获。

## 致谢

本项目 fork 自 [grid-oaa/ChatGPT-helper](https://github.com/grid-oaa/ChatGPT-helper)，并在此基础上继续开发。

## 贡献

发现问题或有改进想法，欢迎提交 [Issue](https://github.com/Johnny-xuan/conversation-trail/issues) 或 PR。如果改动比较大，请先开 Issue 说明使用场景，方便一起确认方向。
