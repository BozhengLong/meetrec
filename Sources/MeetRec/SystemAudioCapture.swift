import Foundation
import AVFoundation
import ScreenCaptureKit
import CoreMedia

enum AudioCaptureError: Error {
    case noDisplays
    case noPermission
    case streamStartFailed(Error)
}

/// System-audio capture via ScreenCaptureKit. Works on built-in speakers,
/// Bluetooth (AirPods), and external DACs — unlike Core Audio Process Taps
/// which fails when output is routed through HFP/SCO Bluetooth.
final class SystemAudioCapture: NSObject, SCStreamOutput, SCStreamDelegate {

    private var stream: SCStream?
    private let audioQueue = DispatchQueue(label: "meetrec.sck-audio", qos: .userInitiated)
    private var handleCount = 0

    var onBuffer: ((AVAudioPCMBuffer, AVAudioTime) -> Void)?

    func start() async throws {
        Log.write("sck: requesting shareable content")
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: true
            )
        } catch {
            Log.write("sck: SCShareableContent FAILED — likely missing Screen Recording permission. \(error)")
            throw AudioCaptureError.noPermission
        }

        guard let display = content.displays.first else {
            Log.write("sck: no displays found")
            throw AudioCaptureError.noDisplays
        }
        Log.write("sck: using display \(display.displayID) \(display.width)x\(display.height)")

        let filter = SCContentFilter(display: display, excludingWindows: [])

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.sampleRate = 48_000
        config.channelCount = 2
        config.excludesCurrentProcessAudio = true
        // We don't care about video frames; keep them minimal so they don't cost us much.
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1) // ~1 fps, discarded
        config.queueDepth = 6
        config.showsCursor = false

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
        Log.write("sck: stream created, starting capture")

        do {
            try await stream.startCapture()
        } catch {
            Log.write("sck: startCapture FAILED — \(error)")
            throw AudioCaptureError.streamStartFailed(error)
        }

        self.stream = stream
        Log.write("sck: STARTED ✓ (sr=48000, ch=2)")
    }

    func stop() async {
        do {
            try await stream?.stopCapture()
            Log.write("sck: stopped, total buffers=\(handleCount)")
        } catch {
            Log.write("sck: stop error \(error)")
        }
        stream = nil
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard outputType == .audio else { return }
        guard sampleBuffer.isValid else { return }

        handleCount += 1
        if handleCount == 1 || handleCount % 200 == 0 {
            Log.write("sck: audio buffer #\(handleCount) samples=\(sampleBuffer.numSamples)")
        }

        guard let pcm = pcmBuffer(from: sampleBuffer) else { return }
        let time = AVAudioTime(sampleTime: AVAudioFramePosition(handleCount), atRate: 48_000)
        onBuffer?(pcm, time)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        Log.write("sck: stream stopped with error \(error)")
    }

    // MARK: - CMSampleBuffer → AVAudioPCMBuffer

    private func pcmBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let formatDesc = sampleBuffer.formatDescription,
              let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) else {
            return nil
        }
        var asbd = asbdPtr.pointee
        guard let format = AVAudioFormat(streamDescription: &asbd) else { return nil }

        let frameCount = AVAudioFrameCount(sampleBuffer.numSamples)
        guard let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return nil }
        pcm.frameLength = frameCount

        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(frameCount),
            into: pcm.mutableAudioBufferList
        )
        guard status == noErr else {
            Log.write("sck: copy PCM data failed status=\(status)")
            return nil
        }
        return pcm
    }
}
