import Foundation
import AVFoundation
import AppKit
import Combine

@MainActor
final class RecordingEngine: ObservableObject {

    @Published private(set) var isRecording = false
    @Published private(set) var elapsed: TimeInterval = 0
    @Published var systemMuted = false {
        didSet { writer?.systemMuted = systemMuted }
    }
    @Published var micMuted = false {
        didSet { writer?.micMuted = micMuted }
    }
    @Published private(set) var lastOutputURL: URL?

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
        if isRecording {
            stop()
        } else {
            Task {
                do { try await startAsync() } catch {
                    Log.write("failed to start — \(error)")
                    cleanup()
                }
            }
        }
    }

    func startAsync() async throws {
        guard !isRecording else { return }

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
        mic.onBuffer = { [weak writer] buffer, _ in
            writer?.appendMic(buffer: buffer)
        }
        try await mic.start()
        self.micCapture = mic

        let sys = SystemAudioCapture()
        sys.onBuffer = { [weak writer] buffer, _ in
            writer?.appendSystem(buffer: buffer)
        }
        do {
            try await sys.start()
            self.systemCapture = sys
        } catch {
            Log.write("system audio capture FAILED — \(error). Continuing with mic-only.")
        }

        let start = Date()
        startDate = start
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.elapsed = Date().timeIntervalSince(start)
            }
        }
        lastOutputURL = url
        isRecording = true
    }

    func stop() {
        guard isRecording else { return }
        let outputURL = lastOutputURL
        let sys = systemCapture

        Task {
            await sys?.stop()
        }
        micCapture?.stop()
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
        isRecording = false
    }
}
