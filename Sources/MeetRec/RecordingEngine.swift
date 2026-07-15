import Foundation
import AVFoundation
import AppKit
import Combine

@MainActor
final class RecordingEngine: ObservableObject {

    @Published private(set) var isRecording = false
    @Published private(set) var elapsed: TimeInterval = 0
    /// True while startAsync is in flight. Starting takes seconds now (AEC
    /// init), and hotkey auto-repeat can fire toggle() many times in that
    /// window — without this guard each call spawns a full capture pipeline.
    private var isStarting = false
    /// Debounce: Carbon hotkeys fire repeatedly (~150ms) while held, which
    /// would stop a recording right after starting it.
    private var lastToggle = Date.distantPast
    @Published var systemMuted = false {
        didSet { writer?.systemMuted = systemMuted }
    }
    @Published var micMuted = false {
        didSet { writer?.micMuted = micMuted }
    }
    @Published private(set) var lastOutputURL: URL?
    @Published private(set) var systemLevel: Float = 0
    @Published private(set) var micLevel: Float = 0

    private var systemCapture: SystemAudioCapture?
    private var micCapture: MicrophoneCapture?
    private var writer: StereoWriter?
    private var startDate: Date?
    private var timer: Timer?

    var recordingsDirectory: URL {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Recordings", isDirectory: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        return url
    }

    func toggle() {
        guard Date().timeIntervalSince(lastToggle) > 1.0 else {
            Log.write("toggle ignored — debounced")
            return
        }
        lastToggle = Date()
        if isRecording {
            stop()
        } else {
            guard !isStarting else {
                Log.write("toggle ignored — start already in progress")
                return
            }
            Task {
                do { try await startAsync() } catch {
                    Log.write("failed to start — \(error)")
                    cleanup()
                }
            }
        }
    }

    func startAsync() async throws {
        guard !isRecording, !isStarting else { return }
        isStarting = true
        defer { isStarting = false }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HHmm"
        let filename = "\(formatter.string(from: Date())).m4a"
        let url = recordingsDirectory.appendingPathComponent(filename)
        Log.write("starting recording → \(url.path)")

        let writer = try StereoWriter(outputURL: url)
        writer.systemMuted = systemMuted
        writer.micMuted = micMuted
        writer.start()
        self.writer = writer

        let mic = MicrophoneCapture()
        mic.onBuffer = { [weak writer, weak self] buffer, _ in
            writer?.appendMic(buffer: buffer)
            let peak = AudioLevel.peak(of: buffer)
            Task { @MainActor [weak self] in
                guard let self else { return }
                if peak > self.micLevel { self.micLevel = peak }
            }
        }
        try await mic.start()
        self.micCapture = mic

        let sys = SystemAudioCapture()
        sys.onBuffer = { [weak writer, weak self] buffer, _ in
            writer?.appendSystem(buffer: buffer)
            let peak = AudioLevel.peak(of: buffer)
            Task { @MainActor [weak self] in
                guard let self else { return }
                if peak > self.systemLevel { self.systemLevel = peak }
            }
        }
        do {
            try await sys.start()
            self.systemCapture = sys
        } catch {
            Log.write("system audio capture FAILED — \(error). Continuing with mic-only.")
        }

        let start = Date()
        startDate = start
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.elapsed = Date().timeIntervalSince(start)
                // Exponential decay so meters drop smoothly when levels fall.
                self.systemLevel *= 0.85
                self.micLevel *= 0.85
            }
        }
        lastOutputURL = url
        isRecording = true
    }

    func stop() {
        guard isRecording else { return }
        let outputURL = lastOutputURL
        let sys = systemCapture
        let mic = micCapture

        Task {
            await sys?.stop()
        }
        // AUVoiceIO teardown can block for a long time. Keep mic stop off the
        // main thread and never let the writer finalization wait on it —
        // otherwise the UI freezes and the m4a never gets its moov atom.
        Task.detached {
            guard let mic else { return }
            Log.write("stopping mic engine (background)")
            mic.stop()
        }
        writer?.finish { [weak self] in
            DispatchQueue.main.async {
                self?.cleanup()
                if let url = outputURL {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            }
        }
    }

    private func cleanup() {
        timer?.invalidate()
        timer = nil
        systemCapture = nil
        micCapture = nil
        writer = nil
        startDate = nil
        elapsed = 0
        systemLevel = 0
        micLevel = 0
        isRecording = false
    }
}
