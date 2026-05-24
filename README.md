# MeetRec

A minimal macOS menu-bar recorder that captures **system audio + microphone** into a single stereo M4A file (left channel = system, right channel = mic). Each channel can be muted independently in real-time via global hotkeys.

Built for archiving meetings and livestreams where you have no native recording rights (Tencent Meeting, Bilibili/YouTube live, etc.) — record now, transcribe later with whichever ASR you prefer.

## Why another recorder?

Most "AI notetaker" tools either join meetings as a visible bot, send your audio to the cloud, or require a virtual audio driver like BlackHole. MeetRec does none of that:

- **Local-only**: no cloud, no bot in your meeting
- **No virtual audio driver**: uses Apple's `ScreenCaptureKit` directly
- **Works with AirPods**: unlike Core Audio Process Taps, ScreenCaptureKit handles Bluetooth HFP/SCO mode correctly
- **Two-channel output**: system audio and microphone stay separated, so you can mute one without losing the other, and post-process them independently for transcription

## Features

- Menu bar app, no dock icon
- Left channel = system audio, right channel = microphone
- Per-channel mute toggles (real-time, no click/pop, instant)
- Global hotkeys:
  - `⌥⌘M` — toggle microphone
  - `⌥⌘S` — toggle system audio
  - `⌥⌘R` — start / stop recording
- Saves to `~/Recordings/YYYY-MM-DD_HHMM.m4a`
- Reveals the file in Finder when recording stops
- AAC 128 kbps stereo @ 48 kHz (~56 MB/hour)
- Diagnostic log at `~/Recordings/meetrec.log`

## Requirements

- macOS 14.2 or later (uses ScreenCaptureKit + Swift Concurrency)
- Xcode 15+ or Swift 5.9+ toolchain
- Microphone permission
- Screen Recording permission (ScreenCaptureKit requires it even though we discard video)

## Build & Install

```bash
git clone https://github.com/BozhengLong/meetrec.git
cd meetrec
./make-app.sh
```

This produces `MeetRec.app` in the project directory. Drag it to `/Applications` (or just double-click it where it is).

### First launch

1. macOS may show **"Cannot verify the developer"** because the app is ad-hoc signed → System Settings → Privacy & Security → click **Open Anyway**
2. Click the record icon in the menu bar → **Start Recording**
3. Allow **microphone** access when prompted
4. Allow **screen recording** access when prompted (used only for audio capture; no video is saved)

## Usage

1. Click the menu bar icon → **Start Recording** (or hit `⌥⌘R`)
2. Toggle channels as needed during the session (`⌥⌘M` for mic is the most common — when others are speaking and you don't want your background noise recorded)
3. Click **Stop & Reveal** → Finder opens with the new file selected
4. Drop the file into MacWhisper / Buzz / whisper.cpp / ChatGPT for transcription

## Architecture

```
┌──────────────────────────────────┐
│  ScreenCaptureKit (SCStream)     │  ← system audio
│  AVAudioEngine                   │  ← microphone
│      ↓ (each fed independently)  │
│  StereoWriter                    │  ← heartbeat-flushed every 100ms,
│      ↓                           │     pads silence for the muted side
│  AVAssetWriter → AAC m4a stereo  │
└──────────────────────────────────┘
```

- `SystemAudioCapture` — wraps `SCStream` with `capturesAudio=true` and a minimal 2×2 video stream that's never read.
- `MicrophoneCapture` — `AVAudioEngine.inputNode` with a tap, requests permission explicitly via `AVCaptureDevice.requestAccess`.
- `StereoWriter` — own dispatch queue, two mono Float32 ring buffers, every 100ms emits a stereo interleaved chunk through `AVAssetWriter`. Mute = append zeros instead of samples; the timeline stays aligned.
- `HotKeyManager` — Carbon `RegisterEventHotKey`, no dependencies.

## File layout

```
meetrec/
├── Package.swift
├── make-app.sh                   # builds + packages MeetRec.app
├── LICENSE
├── README.md
└── Sources/MeetRec/
    ├── MeetRecApp.swift          # app entry, MenuBarExtra, hotkey wiring
    ├── MenuBarView.swift         # SwiftUI menu UI
    ├── RecordingEngine.swift     # orchestrator (ObservableObject)
    ├── SystemAudioCapture.swift  # ScreenCaptureKit-based system audio
    ├── MicrophoneCapture.swift   # AVAudioEngine
    ├── StereoWriter.swift        # AVAssetWriter + L/R interleave
    ├── HotKeyManager.swift       # Carbon global hotkeys
    └── Log.swift                 # file-based logger
```

## Notes & limitations

- **No transcription**: by design. Feed the m4a to whatever ASR you prefer (Whisper, MacWhisper, Buzz, ChatGPT).
- **No pause**: stop & restart creates a new file. Pause within a single file isn't supported in this MVP.
- **Channel separation**: when transcribing, you can split L/R into two mono files and feed them separately for cleaner speaker attribution. `ffmpeg -i input.m4a -map_channel 0.0.0 left.m4a -map_channel 0.0.1 right.m4a`
- **Screen Recording permission**: required by ScreenCaptureKit even for audio-only. No video is ever written to disk; the dummy 2×2 video stream is discarded inside `SCStream`.
- **Output device switching mid-recording**: untested. Start playback first, then start recording.

## Why not Core Audio Process Taps?

The Process Tap API (`AudioHardwareCreateProcessTap`, macOS 14.2+) is the obvious choice for system-audio capture and what tools like Granola originally used. It works on most setups — except when the default output device is a Bluetooth headset (AirPods, Sony WH-1000XM, etc.) and your app is also recording from the microphone. In that case macOS switches Bluetooth to **HFP/SCO mode** (the lower-bandwidth call mode), and the tap silently stops receiving callbacks — `AudioDeviceStart` returns success but the IO proc never fires. ScreenCaptureKit doesn't have this problem because it sits above CoreAudio's device-routing layer.

## License

MIT — see [LICENSE](LICENSE).
