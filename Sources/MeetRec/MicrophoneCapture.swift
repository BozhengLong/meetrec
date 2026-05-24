import Foundation
import AVFoundation

enum MicrophoneCaptureError: Error {
    case permissionDenied
}

final class MicrophoneCapture {
    private let engine = AVAudioEngine()
    var onBuffer: ((AVAudioPCMBuffer, AVAudioTime) -> Void)?
    private(set) var streamFormat: AVAudioFormat?
    private var bufferCount = 0

    func start() async throws {
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        guard granted else {
            Log.write("microphone permission DENIED")
            throw MicrophoneCaptureError.permissionDenied
        }

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
        Log.write("mic engine started")
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        Log.write("mic engine stopped, total buffers=\(bufferCount)")
    }
}
