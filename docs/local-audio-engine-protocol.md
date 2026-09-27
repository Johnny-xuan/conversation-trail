# Local Audio Engine Protocol v2

Local Audio Engine 是一个与具体产品无关的 macOS 本地服务。它只负责获得一次系统音频权限、分析一次声音，并把同一份实时数据流扇出给多个本地客户端。

## 角色

- **Engine**：`Local Audio Engine.app`，唯一的系统音频捕获者和数据提供者。
- **Client**：需要声浪数据的任意本地应用。
- **Adapter**：在客户端不能直接使用本地协议时负责转发。例如 Conversation Trail 的 Native Messaging relay。

## Transport

Engine 监听随机的 `127.0.0.1` TCP 端口，并将连接信息写入：

```text
~/Library/Application Support/Local Audio Engine/endpoint.json
```

该文件权限为 `0600`，包含每次启动随机生成的 token。服务不监听局域网网卡。

协议使用 UTF-8 JSON Lines；每个 JSON 对象以 `\n` 结束。

## Handshake

客户端读取 `endpoint.json` 后发送：

```json
{
  "type": "hello",
  "protocolVersion": 2,
  "token": "per-launch-random-token",
  "clientId": "conversation-trail.chrome",
  "stream": "audio.spectrum.stereo"
}
```

Engine 验证成功后返回：

```json
{
  "type": "ready",
  "protocolVersion": 2,
  "stream": "audio.spectrum.stereo",
  "channels": ["left", "right"],
  "bands": 24,
  "framesPerSecond": 50
}
```

## Audio frame

```json
{
  "type": "audio-frame",
  "protocolVersion": 2,
  "sequence": 1042,
  "timestamp": 1790496000.125,
  "channels": [
    { "level": 0.42, "peak": 0.81, "bands": [0.11, 0.24, 0.37] },
    { "level": 0.28, "peak": 0.63, "bands": [0.05, 0.17, 0.26] }
  ]
}
```

`channels` 固定为两项，依次是左声道、右声道。每个声道的 `bands` 固定为 24 项，示例仅展示前三项。频段从低频到高频排列，24 个边界区间按对数覆盖 55–12000Hz；不是时间域切片，也不是识别出的音符。`level` 是该声道最近 20ms 的 RMS，`peak` 是该窗口内的绝对采样峰值，`bands` 是频段 RMS 能量。三者都使用相同的固定软压缩映射到 `0...1`，不包含原始音频样本：

```text
energy(amplitude) = min(1, log1p(max(0, amplitude - 0.0025) * 20) / log1p((1 - 0.0025) * 20))
```

频谱使用最近 2048 个样本、Hann 窗和实数 FFT，按窗函数能量校准单边功率，再按频段边界与 FFT bin 的重叠比例分配。在 48kHz 捕获下窗口约 42.7ms，每 20ms 更新；低采样率下仍保留固定频段位置，超出 Nyquist 频率的部分没有能量。左右声道分别分析，不下混、不互相抵消，也不人为制造声像差异；单声道输入会复制到左右输出。

分析跨捕获回调连续累积，不按回调丢样本，不做 attack/release 平滑或自动增益；停止或格式切换时清除窗口。频谱会在真实样本移出窗口后自然归零。当前输出为 50 帧/秒，客户端应读取握手中的 `framesPerSecond`，而不是假定到达间隔恒定。

`timestamp` 使用 UNIX 秒，表示分析窗口结束时间；以捕获回调到达的系统时间为基准，按该回调剩余样本数回推。它可用于识别过期帧，但不是声卡播放时钟，不能直接用于宣称端到端听觉延迟。`sequence` 为递增帧序号。

## Lifecycle

- 第一个客户端订阅时，Engine 启动系统音频捕获。
- 缺少权限时广播 `engine-status`，`state: "permission-required"`，并提供本地授权引导；订阅保持有效，授权后自动开始捕获并广播 `state: "streaming"`。
- 多个客户端共享同一条捕获流。
- 最后一个客户端断开时，Engine 停止捕获。
- 关闭 Engine 窗口不停止服务；退出 App 才终止服务。
- Engine 每次启动都会更换端口和 token。
- `protocolVersion` 不兼容时，客户端必须拒绝连接，不能猜测字段含义。
- v2 用 `channels` 替代 v1 帧顶层的 `level / peak / bands`，并将时间域切片改为频段能量。旧客户端须升级，不能把新频谱解释成旧波形；不提供双协议兼容路径。

Conversation Trail relay 在连接期间另向扩展报告 `relay-status`：`state` 为 `launching` 或 `connecting`，`message` 描述当前步骤。它会处理冷启动与失效端点，并等待真实握手完成；启动失败则返回明确错误，而不是要求用户猜测等待时间。`stop` 或断开 Native Messaging 会取消未完成的连接流程。Chrome 关闭 Native Messaging 输入后，relay 退出进程并释放订阅，不留下空转的后台进程。

扩展持久化的是用户是否启用声浪的选择，不是实时连接状态。连接错误或等待授权不会清除选择；没有 ChatGPT 页面时取消订阅，之后按偏好恢复。
