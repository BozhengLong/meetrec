import Foundation
import AVFoundation

enum MicrophoneCaptureError: Error {
    case permissionDenied
}

/// Facade over two capture implementations:
/// 1. `VoiceProcessingMicCapture` (AUVoiceIO: echo cancellation + noise
///    suppression + AGC) — tried first.
/// 2. `PlainMicCapture` (AVAudioEngine tap) — fallback when VP setup fails,
///    when a watchdog sees zero VP buffers 3s after start, or when the user
///    opts out:  defaults write com.local.meetrec DisableAEC -bool true
///
/// Iron rule: the mic must never be silently lost. Every retry/fallback uses
/// a FRESH instance — a failed voice-processing attempt must never poison
/// the path that follows it.
final class MicrophoneCapture {

    var onBuffer: ((AVAudioPCMBuffer, AVAudioTime) -> Void)?
    var streamFormat: AVAudioFormat? {
        lock.lock(); defer { lock.unlock() }
        switch impl {
        case .vp(let vp): return vp.streamFormat
        case .plain(let plain): return plain.streamFormat
        case .none: return nil
        }
    }

    private enum Impl {
        case vp(VoiceProcessingMicCapture)
        case plain(PlainMicCapture)
        case none
    }
    private var impl: Impl = .none
    private var stopped = false
    private let lock = NSLock()

    func start() async throws {
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        guard granted else {
            Log.write("microphone permission DENIED")
            throw MicrophoneCaptureError.permissionDenied
        }

        if UserDefaults.standard.bool(forKey: "DisableAEC") {
            Log.write("mic: DisableAEC set — using plain capture")
            try startPlain()
            return
        }

        // VP setup is blocking (CoreAudio calls, possibly seconds) — keep it
        // off the main actor.
        let vp = VoiceProcessingMicCapture()
        vp.onBuffer = { [weak self] buffer, time in self?.onBuffer?(buffer, time) }
        do {
            try await Task.detached(priority: .userInitiated) { try vp.start() }.value
            adoptVP(vp)
            armWatchdog(for: vp)
        } catch {
            Log.write("mic: voice processing setup failed (\(error)) — falling back to plain capture")
            try startPlain()
        }
    }

    private func adoptVP(_ vp: VoiceProcessingMicCapture) {
        lock.lock()
        impl = .vp(vp)
        lock.unlock()
    }

    private func isStillActiveVP(_ vp: VoiceProcessingMicCapture) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if case .vp(let current) = impl, current === vp, !stopped { return true }
        return false
    }

    /// If the VP unit started but never delivers data, swap in a fresh plain
    /// capture. A recording without AEC beats a recording without the mic.
    private func armWatchdog(for vp: VoiceProcessingMicCapture) {
        Task.detached(priority: .userInitiated) { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self else { return }
            guard self.isStillActiveVP(vp), vp.bufferCount == 0 else { return }

            Log.write("mic watchdog: AUVoiceIO delivered 0 buffers in 3s — falling back to plain capture")
            vp.stop()
            do {
                try self.startPlain()
            } catch {
                Log.write("mic watchdog: CRITICAL — plain fallback also failed (\(error)); no mic for this recording")
            }
        }
    }

    private func startPlain() throws {
        let plain = PlainMicCapture()
        plain.onBuffer = { [weak self] buffer, time in self?.onBuffer?(buffer, time) }
        try plain.start()
        lock.lock()
        defer { lock.unlock() }
        if stopped {
            // stop() raced us (user hit stop during fallback) — don't leak a
            // running engine.
            plain.stop()
            return
        }
        impl = .plain(plain)
    }

    /// Idempotent. May block in AUVoiceIO teardown — RecordingEngine calls
    /// this from a detached task, never the main thread.
    func stop() {
        lock.lock()
        let current = impl
        impl = .none
        stopped = true
        lock.unlock()

        switch current {
        case .vp(let vp): vp.stop()
        case .plain(let plain): plain.stop()
        case .none: break
        }
    }
}

/// The original AVAudioEngine input-tap capture. No voice processing — see
/// the facade note; AVAudioEngine's VP mode is a dead end on this setup.
final class PlainMicCapture {
    private let engine = AVAudioEngine()
    var onBuffer: ((AVAudioPCMBuffer, AVAudioTime) -> Void)?
    private(set) var streamFormat: AVAudioFormat?
    private var bufferCount = 0

    func start() throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        streamFormat = format
        Log.write("mic format sr=\(format.sampleRate) ch=\(format.channelCount)")

        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, time in
            guard let self else { return }
            self.bufferCount += 1
            if self.bufferCount == 1 || self.bufferCount % 200 == 0 {
                Log.write("mic buffer #\(self.bufferCount) frames=\(buffer.frameLength)")
            }
            self.onBuffer?(buffer, time)
        }

        engine.prepare()
        try engine.start()
        Log.write("mic engine started (plain)")
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        Log.write("mic engine stopped, total buffers=\(bufferCount)")
    }
}
