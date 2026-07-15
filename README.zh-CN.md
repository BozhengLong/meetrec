# MeetRec

[![macOS](https://img.shields.io/badge/macOS-14.2%2B-blue)](https://www.apple.com/macos/)
[![License: MIT](https://img.shields.io/badge/license-MIT-yellow.svg)](LICENSE)
[![Latest release](https://img.shields.io/github/v/release/BozhengLong/meetrec)](https://github.com/BozhengLong/meetrec/releases)

[English](README.md) | **简体中文**

**常驻 Mac 菜单栏的一键会议录音工具。** 它同时录下会议、通话或直播的双方声音——对方的和你的——保存为一个音频文件，存在你自己的磁盘上。一切都在本地完成：没有云端、不用注册账号、不会有机器人加入你的会议。

<img src="docs/popover.png" width="330" alt="MeetRec 录音中的弹出面板——系统音频和麦克风的实时电平条">

## 安装

从 [Releases](https://github.com/BozhengLong/meetrec/releases) 下载 `MeetRec.app.zip`，解压后把 `MeetRec.app` 拖进 `/Applications`。

首次启动会被 macOS 拦截（应用已签名但未经 Apple 公证）。一次性解决，两种方法任选：

- 系统设置 → 隐私与安全性 → 拉到底部 → 点**仍要打开**，或
- `xattr -dr com.apple.quarantine /Applications/MeetRec.app`

之后 MeetRec 会引导你完成所需的两项权限授权。想从源码构建？[见下文](#从源码构建)——不会有 Gatekeeper 拦截。

## 功能

- 🎙️ 录下**完整的对话**——系统音频 + 麦克风自然混合进一个 m4a 文件；支持 AirPods
- 🔊 麦克风带**回声消除、降噪、自动增益**——外放开会也不会录进对方声音的回声
- 🔇 双路声音可分别实时静音，支持全局热键
- 🚦 如果录音意外缺失系统音频，会**大声警告**（弹窗 + 菜单栏图标）——绝不静默失败
- 💾 保存到 `~/Recordings/YYYY-MM-DD_HHMM.m4a`，停止时自动在 Finder 中展示

| 热键 | 功能 |
|---|---|
| `⌥⌘R` | 开始 / 停止录音 |
| `⌥⌘M` | 麦克风静音开关 |
| `⌥⌘S` | 系统音频静音开关 |

## 录完之后

MeetRec 有意止步于"产出一个干净的音频文件"——不内置转写。把 m4a 拖给 [MacWhisper](https://goodsnooze.gumroad.com/l/macwhisper)、[Buzz](https://github.com/chidiwilliams/buzz)、ChatGPT，或者：

```bash
whisper-cli -m models/ggml-large-v3.bin -f 2026-05-24_1430.m4a -l zh
```

两个声道内容相同，任何工具都能处理；说话人区分交给你的转写工具做。

<details>
<summary><strong>可选调节</strong></summary>

```bash
# 觉得自己的声音在混音里偏小/偏大？调麦克风增益（单位 dB，默认 0）：
defaults write com.local.meetrec MicGainDb -float 6

# 想要未经处理的原始麦克风声音？关闭回声消除等处理：
defaults write com.local.meetrec DisableAEC -bool true
```

</details>

## 权限

| 权限 | 用途 |
|---|---|
| 麦克风 | 录你的声音 |
| 屏幕录制 | macOS 把系统音频采集放在这个权限之下。**绝不会保存任何视频** |

MeetRec 启动时会检测缺失的权限并引导你完成。万一卡住了，最后一招是 `tccutil reset ScreenCapture com.local.meetrec`，然后重启应用重新授权。

## 已知限制

- **不支持暂停**——停止再开始会生成新文件
- **预编译包仅支持 Apple Silicon**——Intel Mac 请从源码构建
- **未经公证**——首次启动需要一次性的 Gatekeeper 放行（见安装）
- **录音中途切换输出设备**未经测试；录音中途切换输入设备会继续从原设备采集（有意为之）

## 从源码构建

需要 macOS 14.2+ 和 Xcode 15+ / Swift 5.9+ 工具链。

```bash
git clone https://github.com/BozhengLong/meetrec.git
cd meetrec
./make-app.sh         # → ./MeetRec.app
```

本地构建的应用没有隔离属性，不会被 Gatekeeper 拦截。如果机器上有 Apple Development 证书，`make-app.sh` 会自动用它签名——权限授权在重新构建后依然有效。

<details>
<summary><strong>架构</strong></summary>

```
┌──────────────────────────────────┐
│  SCStream (capturesAudio=true)   │  ← 系统音频
│  AUVoiceIO / AVAudioEngine       │  ← 麦克风（AEC + 降噪 + AGC）
│      ↓ （独立回调）               │
│  StereoWriter                    │  ← 每 100ms 心跳刷写，
│      ↓                           │     静音侧填充无声样本
│  AVAssetWriter → AAC m4a 立体声  │
└──────────────────────────────────┘
```

- `SystemAudioCapture` — 封装 `SCStream`（`capturesAudio=true`），附带一条 2×2 的最小视频流，在 SCKit 内部即被丢弃。
- `MicrophoneCapture` — facade 模式：优先尝试 `VoiceProcessingMicCapture`（直接驱动 AUVoiceIO：回声消除 + 降噪 + 自动增益），配 3 秒零数据看门狗，异常时换入全新的普通 `AVAudioEngine` 采集——麦克风绝不静默丢失。（AVAudioEngine 自带的 `setVoiceProcessingEnabled` 对仅采集场景是死路，详见源码注释。）
- `VoiceProcessingMicCapture` — 底层 `kAudioUnitSubType_VoiceProcessingIO` 配置：输出 element 挂静音渲染回调（驱动输入侧运转的必要条件）、ducking 配置为最小（防止录到的系统音频被压低）、客户端格式跟随单元自身采样率。
- `StereoWriter` — 独立 dispatch queue，两个单声道 Float32 环形缓冲，每 100ms 混合双源（麦克风增益 + 软削波）并通过 `AVAssetWriter` 写出双单声道立体声块。静音 = 填零样本，时间轴保持对齐，无爆音。
- `ScreenRecordingPermission` — 启动预检（`CGPreflightScreenCaptureAccess`）、设置页直达引导、授权轮询、一键重启。
- `HotKeyManager` — Carbon `RegisterEventHotKey`，零依赖。
- `AudioLevel` — PCM 缓冲峰值检测，供电平条使用。

### 文件布局

```
meetrec/
├── Package.swift
├── make-app.sh                   # 构建 + 打包 MeetRec.app
├── LICENSE
├── README.md
└── Sources/MeetRec/
    ├── MeetRecApp.swift          # 应用入口、MenuBarExtra、热键接线
    ├── MenuBarView.swift         # SwiftUI 弹出面板（电平条）
    ├── RecordingEngine.swift     # 调度器（ObservableObject）
    ├── SystemAudioCapture.swift  # 基于 ScreenCaptureKit 的系统音频
    ├── MicrophoneCapture.swift   # facade：AEC 优先 + 普通采集兜底
    ├── VoiceProcessingMicCapture.swift # 底层 AUVoiceIO（AEC/降噪/AGC）
    ├── ScreenRecordingPermission.swift # 启动预检 + 引导授权
    ├── StereoWriter.swift        # AVAssetWriter + 双单声道混音
    ├── HotKeyManager.swift       # Carbon 全局热键
    ├── AudioLevel.swift          # 电平峰值检测
    └── Log.swift                 # 文件日志
```

</details>

<details>
<summary><strong>为什么不用 Core Audio Process Taps？</strong></summary>

Process Tap API（`AudioHardwareCreateProcessTap`，macOS 14.2+）是采集系统音频"显而易见"的方案，我们最先尝试的就是它。它在内置扬声器和多数输出设备上工作正常——但**当默认输出是 HFP/SCO 模式的蓝牙设备时会静默失败**（比如戴着 AirPods 同时又在录麦克风）。此时 macOS 会把蓝牙切换到低带宽通话模式，tap 的 IO proc 永远不会触发——`AudioDeviceStart` 返回 `noErr`，但回调一个也不来。ScreenCaptureKit 的音频通路位于 CoreAudio 设备路由之上，没有这个问题。

</details>

## 许可证

MIT — 见 [LICENSE](LICENSE)。
