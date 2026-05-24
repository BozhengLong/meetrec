# MeetRec

[![macOS](https://img.shields.io/badge/macOS-14.2%2B-blue)](https://www.apple.com/macos/)
[![License: MIT](https://img.shields.io/badge/license-MIT-yellow.svg)](LICENSE)
[![Latest release](https://img.shields.io/github/v/release/BozhengLong/meetrec)](https://github.com/BozhengLong/meetrec/releases)
[![Stars](https://img.shields.io/github/stars/BozhengLong/meetrec?style=social)](https://github.com/BozhengLong/meetrec/stargazers)

**Record meetings, livestreams, and calls on macOS — locally, into a single stereo M4A file.** Left channel is system audio, right channel is your microphone. No cloud. No bot in your meeting. No virtual audio driver. Works with AirPods.

<!-- TODO: replace this line with a short demo gif -->
> _Demo gif coming soon — menu bar icon, hotkey muting mic, file appearing in Finder._

## Install

```bash
git clone https://github.com/BozhengLong/meetrec.git
cd meetrec
./make-app.sh
```

Drag `MeetRec.app` to `/Applications` and double-click. On first launch macOS will block it (ad-hoc signed), so either:

- System Settings → Privacy & Security → **Open Anyway**, or
- `xattr -dr com.apple.quarantine /Applications/MeetRec.app`

Or grab the prebuilt zip from [Releases](https://github.com/BozhengLong/meetrec/releases) and do the same.

## What it does

- 🎙️ Captures **system audio** (via ScreenCaptureKit) + **microphone** (via AVAudioEngine) simultaneously
- 🎚️ Stereo M4A output: **L = system, R = mic** — separated for clean transcription downstream
- 🔇 Independent per-channel mute, real-time, with global hotkeys
- 📊 Live level meters in the popover so you can see audio is actually flowing
- ⏱️ Recording time visible right in the menu bar (no need to click)
- 🎧 **Works with AirPods** and other Bluetooth output, unlike Process-Tap–based tools
- 💾 Saves to `~/Recordings/YYYY-MM-DD_HHMM.m4a`, opens Finder on stop

### Hotkeys

| Combo | Action |
|---|---|
| `⌥⌘R` | Start / stop recording |
| `⌥⌘M` | Toggle microphone |
| `⌥⌘S` | Toggle system audio |

## How it compares

| | MeetRec | [Granola](https://www.granola.ai/) | [Audio Hijack](https://rogueamoeba.com/audiohijack/) | [BlackHole](https://github.com/ExistentialAudio/BlackHole) + OBS |
|---|---|---|---|---|
| Price | Free | Subscription | $64 one-time | Free |
| Local-only | ✅ | ❌ (cloud transcription) | ✅ | ✅ |
| Joins meeting as bot | ✅ no | ✅ no | ✅ no | ✅ no |
| Needs virtual audio driver | ✅ no | ✅ no | ✅ no | ❌ yes |
| Works with AirPods | ✅ | ✅ | ✅ | ✅ |
| Built-in transcription | ❌ (BYO Whisper) | ✅ | ❌ | ❌ |
| Open source | ✅ | ❌ | ❌ | ✅ (BlackHole only) |
| Setup complexity | one script | install | install | multi-step routing |

If you want auto-summarized meeting notes with live transcript, use Granola. If you want a full audio production suite, use Audio Hijack. **If you just want a clean local recording that you'll feed into Whisper/ChatGPT yourself, that's what MeetRec is.**

## After recording

MeetRec deliberately stops at "make a clean audio file." Transcribe with whatever you prefer:

```bash
# Split L (system) and R (mic) into two mono files for cleaner transcription
ffmpeg -i 2026-05-24_1430.m4a \
  -map_channel 0.0.0 system.m4a \
  -map_channel 0.0.1 mic.m4a

# Then transcribe each side
whisper-cli -m models/ggml-large-v3.bin -f system.wav -l zh
```

Or just drag the m4a into [MacWhisper](https://goodsnooze.gumroad.com/l/macwhisper), [Buzz](https://github.com/chidiwilliams/buzz), or ChatGPT.

## Permissions you'll be asked for

| Permission | Why |
|---|---|
| Microphone | Records your voice into the right channel |
| Screen Recording | ScreenCaptureKit needs it to capture system audio. **No video is ever saved** — the dummy 2×2 video stream is discarded |

If you only see the mic side recorded and `~/Recordings/meetrec.log` contains `SCShareableContent FAILED ... declined TCCs`, the Screen Recording permission is denied. Open **System Settings → Privacy & Security → Screen Recording**, enable MeetRec, then fully quit and relaunch. If MeetRec doesn't appear in the list at all (macOS suppressing the prompt after a previous denial), reset and try again:

```bash
tccutil reset ScreenCapture com.local.meetrec
```

This is most likely to happen after rebuilding from source — re-signing changes the app identity and TCC may silently remember a stale "denied" state.

## Known limitations

- **No transcription** — by design. Feed the m4a to whatever ASR you prefer.
- **No pause within a single file** — stop & restart creates a new file.
- **Switching the system output device mid-recording** is untested. Start playback first, then start recording.
- **Ad-hoc signed**, not Apple-notarized. First launch needs a Gatekeeper override (see Install above).

## Requirements

- macOS **14.2** or later
- Apple Silicon or Intel Mac
- Xcode 15+ / Swift 5.9+ toolchain (for building from source)

## Build from source

```bash
git clone https://github.com/BozhengLong/meetrec.git
cd meetrec
./make-app.sh         # → ./MeetRec.app
# or, just the binary:
swift build -c release
```

<details>
<summary><strong>Architecture</strong></summary>

```
┌──────────────────────────────────┐
│  SCStream (capturesAudio=true)   │  ← system audio
│  AVAudioEngine.inputNode         │  ← microphone
│      ↓ (independent callbacks)   │
│  StereoWriter                    │  ← heartbeat-flushed every 100ms,
│      ↓                           │     pads silence for the muted side
│  AVAssetWriter → AAC m4a stereo  │
└──────────────────────────────────┘
```

- `SystemAudioCapture` — wraps `SCStream` with `capturesAudio=true` and a minimal 2×2 video stream that's discarded inside SCKit.
- `MicrophoneCapture` — `AVAudioEngine.inputNode` with a tap, requests permission explicitly via `AVCaptureDevice.requestAccess`.
- `StereoWriter` — own dispatch queue, two mono Float32 ring buffers, every 100ms emits a stereo interleaved chunk through `AVAssetWriter`. Mute = append zeros instead of samples; the timeline stays aligned, no click/pop.
- `HotKeyManager` — Carbon `RegisterEventHotKey`, no dependencies.
- `AudioLevel` — peak-detection over PCM buffers for the level meters.

### File layout

```
meetrec/
├── Package.swift
├── make-app.sh                   # builds + packages MeetRec.app
├── LICENSE
├── README.md
└── Sources/MeetRec/
    ├── MeetRecApp.swift          # app entry, MenuBarExtra, hotkey wiring
    ├── MenuBarView.swift         # SwiftUI popover with level meters
    ├── RecordingEngine.swift     # orchestrator (ObservableObject)
    ├── SystemAudioCapture.swift  # ScreenCaptureKit-based system audio
    ├── MicrophoneCapture.swift   # AVAudioEngine
    ├── StereoWriter.swift        # AVAssetWriter + L/R interleave
    ├── HotKeyManager.swift       # Carbon global hotkeys
    ├── AudioLevel.swift          # peak detection for meters
    └── Log.swift                 # file-based logger
```

</details>

<details>
<summary><strong>Why not Core Audio Process Taps?</strong></summary>

The Process Tap API (`AudioHardwareCreateProcessTap`, macOS 14.2+) is the "obvious" way to capture system audio. We tried it first. It works on built-in speakers and most output devices — but **silently fails when the default output is Bluetooth in HFP/SCO mode** (AirPods etc. while your app is also recording from the mic). In that case macOS switches the Bluetooth profile to the lower-bandwidth call mode, and the tap's IO proc never fires — `AudioDeviceStart` returns `noErr` but no callbacks come in. ScreenCaptureKit's audio path sits above CoreAudio's device routing and doesn't have this issue.

</details>

## License

MIT — see [LICENSE](LICENSE).
