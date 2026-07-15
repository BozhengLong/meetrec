import Foundation
import AVFoundation

/// Writes a stereo AAC m4a where both channels carry the same mix of
/// system audio + microphone (dual-mono), so playback sounds natural on
/// headphones instead of one voice per ear.
/// Heartbeat-driven: every 100ms we emit a stereo chunk, padding zeros
/// for whichever side hasn't delivered samples. This way the recording
/// continues even if one channel never produces buffers.
final class StereoWriter {

    private let outputURL: URL
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput

    private let queue = DispatchQueue(label: "meetrec.stereo-writer", qos: .userInitiated)
    private let targetSampleRate: Double = 48_000
    private let framesPerHeartbeat: Int = 4_800   // 100ms at 48kHz

    private var systemBuffer: [Float] = []
    private var micBuffer: [Float] = []
    private var systemConverter: AVAudioConverter?
    private var micConverter: AVAudioConverter?
    private var systemSourceFormat: AVAudioFormat?
    private var micSourceFormat: AVAudioFormat?
    private let workFormat: AVAudioFormat

    private var heartbeatTimer: DispatchSourceTimer?
    private var nextSampleTime: Int64 = 0
    private var systemBuffersIn = 0
    private var micBuffersIn = 0
    private var flushesOut = 0

    var systemMuted: Bool = false
    var micMuted: Bool = false

    /// Linear gain applied to the mic before mixing. Adjustable without UI:
    ///   defaults write com.local.meetrec MicGainDb -float 6
    private let micGain: Float = pow(10, Float(UserDefaults.standard.double(forKey: "MicGainDb")) / 20)

    init(outputURL: URL) throws {
        self.outputURL = outputURL

        guard let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                       sampleRate: targetSampleRate,
                                       channels: 1,
                                       interleaved: false) else {
            throw NSError(domain: "StereoWriter", code: 1)
        }
        self.workFormat = mono

        try? FileManager.default.removeItem(at: outputURL)

        self.writer = try AVAssetWriter(outputURL: outputURL, fileType: .m4a)

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVNumberOfChannelsKey: 2,
            AVSampleRateKey: targetSampleRate,
            AVEncoderBitRateKey: 128_000
        ]
        self.input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
        self.input.expectsMediaDataInRealTime = true

        guard writer.canAdd(input) else {
            throw NSError(domain: "StereoWriter", code: 2)
        }
        writer.add(input)
    }

    func start() {
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        Log.write("writer started, status=\(writer.status.rawValue) url=\(outputURL.lastPathComponent)")

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .milliseconds(100),
                       repeating: .milliseconds(100))
        timer.setEventHandler { [weak self] in
            self?.heartbeat()
        }
        timer.resume()
        heartbeatTimer = timer
    }

    func finish(_ completion: @escaping () -> Void) {
        queue.async { [self] in
            heartbeatTimer?.cancel()
            heartbeatTimer = nil
            heartbeat()  // final flush
            Log.write("writer finishing — systemBuffersIn=\(systemBuffersIn) micBuffersIn=\(micBuffersIn) flushesOut=\(flushesOut)")
            guard writer.status == .writing else {
                Log.write("writer already dead (status=\(writer.status.rawValue) err=\(writer.error?.localizedDescription ?? "nil")) — cancelling")
                writer.cancelWriting()
                completion()
                return
            }
            input.markAsFinished()
            writer.finishWriting {
                Log.write("writer finished, status=\(self.writer.status.rawValue) err=\(self.writer.error?.localizedDescription ?? "nil")")
                completion()
            }
        }
    }

    func appendSystem(buffer: AVAudioPCMBuffer) {
        queue.async { [self] in
            systemBuffersIn += 1
            // The source format can change mid-recording (e.g. a capture
            // fallback swaps implementations) — recreate the converter then.
            if systemConverter == nil || systemSourceFormat?.isEqual(buffer.format) != true {
                systemConverter = AVAudioConverter(from: buffer.format, to: workFormat)
                systemSourceFormat = buffer.format
                Log.write("system converter created from sr=\(buffer.format.sampleRate) ch=\(buffer.format.channelCount)")
            }
            guard let conv = systemConverter,
                  let mono = convert(buffer: buffer, with: conv) else { return }
            if systemMuted {
                systemBuffer.append(contentsOf: Array(repeating: 0, count: mono.count))
            } else {
                systemBuffer.append(contentsOf: mono)
            }
        }
    }

    func appendMic(buffer: AVAudioPCMBuffer) {
        queue.async { [self] in
            micBuffersIn += 1
            if micConverter == nil || micSourceFormat?.isEqual(buffer.format) != true {
                micConverter = AVAudioConverter(from: buffer.format, to: workFormat)
                micSourceFormat = buffer.format
                Log.write("mic converter created from sr=\(buffer.format.sampleRate) ch=\(buffer.format.channelCount)")
            }
            guard let conv = micConverter,
                  let mono = convert(buffer: buffer, with: conv) else { return }
            if micMuted {
                micBuffer.append(contentsOf: Array(repeating: 0, count: mono.count))
            } else {
                micBuffer.append(contentsOf: mono)
            }
        }
    }

    // MARK: - Heartbeat

    private func heartbeat() {
        // Decide how many frames this tick. Aim for framesPerHeartbeat,
        // but don't exceed what either side has if both have data.
        // If one side is empty, still emit framesPerHeartbeat (zero-padding it).
        let haveSystem = systemBuffer.count
        let haveMic = micBuffer.count
        let target: Int
        if haveSystem == 0 && haveMic == 0 {
            return  // truly nothing yet (e.g. before any source started)
        }
        target = min(framesPerHeartbeat, max(haveSystem, haveMic))
        guard target > 0 else { return }

        var interleaved = [Float](repeating: 0, count: target * 2)

        let sysN = min(target, haveSystem)
        let micN = min(target, haveMic)
        for i in 0..<target {
            let sys = i < sysN ? systemBuffer[i] : 0
            let mic = i < micN ? micBuffer[i] * micGain : 0
            let mixed = Self.softClip(sys + mic)
            interleaved[i * 2] = mixed
            interleaved[i * 2 + 1] = mixed
        }
        if sysN > 0 { systemBuffer.removeFirst(sysN) }
        if micN > 0 { micBuffer.removeFirst(micN) }

        guard let cmBuffer = makeCMSampleBuffer(from: interleaved, frameCount: target) else { return }
        while !input.isReadyForMoreMediaData {
            // A failed writer never becomes ready — bail out instead of
            // spinning forever and blocking this queue (finish() would hang).
            guard writer.status == .writing else {
                Log.write("writer no longer writing (status=\(writer.status.rawValue)) — dropping chunk")
                heartbeatTimer?.cancel()
                heartbeatTimer = nil
                return
            }
            Thread.sleep(forTimeInterval: 0.001)
        }
        let ok = input.append(cmBuffer)
        if ok {
            flushesOut += 1
            nextSampleTime += Int64(target)
            if flushesOut == 1 || flushesOut % 50 == 0 {
                Log.write("flush #\(flushesOut) frames=\(target) sysSrc=\(sysN) micSrc=\(micN)")
            }
        } else {
            Log.write("append FAILED, writer status=\(writer.status.rawValue) err=\(writer.error?.localizedDescription ?? "nil")")
        }
    }

    /// Linear below the knee; the overshoot is squeezed into the remaining
    /// headroom so two simultaneously loud sources can't hard-clip.
    private static func softClip(_ x: Float) -> Float {
        let knee: Float = 0.95
        let a = abs(x)
        guard a > knee else { return x }
        let squeezed = knee + (1 - knee) * tanh((a - knee) / (1 - knee))
        return x < 0 ? -squeezed : squeezed
    }

    private func convert(buffer: AVAudioPCMBuffer, with converter: AVAudioConverter) -> [Float]? {
        let ratio = workFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 1024)
        guard let out = AVAudioPCMBuffer(pcmFormat: workFormat, frameCapacity: capacity) else { return nil }

        var supplied = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, outStatus in
            if supplied {
                outStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            outStatus.pointee = .haveData
            return buffer
        }
        if status == .error || error != nil { return nil }

        let n = Int(out.frameLength)
        guard let ch = out.floatChannelData?[0] else { return nil }
        return Array(UnsafeBufferPointer(start: ch, count: n))
    }

    private func makeCMSampleBuffer(from interleaved: [Float], frameCount: Int) -> CMSampleBuffer? {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: targetSampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 8,
            mFramesPerPacket: 1,
            mBytesPerFrame: 8,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 32,
            mReserved: 0
        )

        var format: CMAudioFormatDescription?
        var status = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: 0, layout: nil,
            magicCookieSize: 0, magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &format
        )
        guard status == noErr, let fmt = format else { return nil }

        let byteCount = frameCount * Int(asbd.mBytesPerFrame)
        var blockBuffer: CMBlockBuffer?
        status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: byteCount,
            blockAllocator: nil, customBlockSource: nil,
            offsetToData: 0, dataLength: byteCount,
            flags: 0, blockBufferOut: &blockBuffer
        )
        guard status == noErr, let block = blockBuffer else { return nil }

        _ = interleaved.withUnsafeBufferPointer { ptr -> OSStatus in
            CMBlockBufferReplaceDataBytes(
                with: ptr.baseAddress!, blockBuffer: block,
                offsetIntoDestination: 0, dataLength: byteCount
            )
        }

        var sampleBuffer: CMSampleBuffer?
        let timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(targetSampleRate)),
            presentationTimeStamp: CMTime(value: nextSampleTime, timescale: CMTimeScale(targetSampleRate)),
            decodeTimeStamp: .invalid
        )
        var timingArr = [timing]
        var sampleSizeArr = [Int](repeating: Int(asbd.mBytesPerFrame), count: frameCount)

        status = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: block, dataReady: true,
            makeDataReadyCallback: nil, refcon: nil,
            formatDescription: fmt,
            sampleCount: frameCount,
            sampleTimingEntryCount: 1, sampleTimingArray: &timingArr,
            sampleSizeEntryCount: frameCount, sampleSizeArray: &sampleSizeArr,
            sampleBufferOut: &sampleBuffer
        )
        guard status == noErr else { return nil }
        return sampleBuffer
    }
}
