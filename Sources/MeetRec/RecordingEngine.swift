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
    @Published private(set) var systemAudioFailed = false
    @Published private(set) var systemAudioPermissionMissing = false

    private var systemCapture: SystemAudioCapture?
    private var systemCaptureID: UUID?
    private var systemStartTask: Task<Void, Never>?
    private var systemRecovery: SystemAudioRecovery?
    private var micCapture: MicrophoneCapture?
    private var writer: StereoWriter?
    private var isStopping = false
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

        let start = Date()
        systemRecovery = SystemAudioRecovery(now: ProcessInfo.processInfo.systemUptime)
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] timer in
            Task { @MainActor in
                guard let self, self.timer === timer else { return }
                self.elapsed = Date().timeIntervalSince(start)
                self.systemLevel *= 0.85
                self.micLevel *= 0.85
                self.pollSystemAudio()
            }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        lastOutputURL = url
        isRecording = true
        pollSystemAudio()
    }

    private func pollSystemAudio() {
        guard !isStopping else { return }
        let now = ProcessInfo.processInfo.systemUptime
        switch systemRecovery?.poll(at: now) {
        case .connect:
            startSystemCapture()
        case .disconnect:
            Log.write("sck: timed out waiting for audio buffers")
            stopSystemCapture()
        default:
            break
        }
        updateSystemAudioWarning(at: now)
    }

    private func startSystemCapture() {
        guard let writer else { return }
        let capture = SystemAudioCapture()
        let id = UUID()
        systemCapture = capture
        systemCaptureID = id
        capture.onBuffer = { [weak self, weak writer] buffer, _ in
            let peak = AudioLevel.peak(of: buffer)
            DispatchQueue.main.async { [weak self, weak writer] in
                guard let self, self.systemCaptureID == id, let writer else { return }
                writer.appendSystem(buffer: buffer)
                let now = ProcessInfo.processInfo.systemUptime
                if self.systemAudioFailed { Log.write("sck: audio buffers resumed") }
                self.systemRecovery?.receivedBuffer(at: now)
                self.updateSystemAudioWarning(at: now)
                if peak > self.systemLevel { self.systemLevel = peak }
            }
        }
        capture.onInterruption = { [weak self] error in
            DispatchQueue.main.async { [weak self] in self?.systemCaptureFailed(id: id, error: error) }
        }
        systemStartTask = Task { [weak self] in
            do {
                try await capture.start()
            } catch {
                self?.systemCaptureFailed(id: id, error: error)
            }
        }
    }

    private func systemCaptureFailed(id: UUID, error: Error) {
        guard systemCaptureID == id else { return }
        Log.write("sck: capture interrupted or failed to start — \(error)")
        let now = ProcessInfo.processInfo.systemUptime
        let retry = AudioCaptureError.mayRetry(error)
        systemAudioPermissionMissing = !retry && !ScreenRecordingPermission.hasAccess
        systemRecovery?.interrupted(at: now, retry: retry)
        stopSystemCapture()
        updateSystemAudioWarning(at: now)
    }

    private func updateSystemAudioWarning(at now: TimeInterval) {
        let warn = systemRecovery?.shouldWarn(at: now) == true
        if warn != systemAudioFailed { systemAudioFailed = warn }
    }

    private func stopSystemCapture() {
        systemCaptureID = nil
        systemStartTask?.cancel()
        systemStartTask = nil
        if let capture = systemCapture {
            systemCapture = nil
            Task { await capture.stop() }
        }
    }

    func stop() {
        guard isRecording, !isStopping else { return }
        isStopping = true
        let outputURL = lastOutputURL
        let mic = micCapture
        stopSystemCapture()
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
        stopSystemCapture()
        systemRecovery = nil
        micCapture = nil
        writer = nil
        elapsed = 0
        systemLevel = 0
        micLevel = 0
        isRecording = false
        isStopping = false
        systemAudioFailed = false
        systemAudioPermissionMissing = false
    }
}
