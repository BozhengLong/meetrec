import Foundation
import AVFoundation
import AudioToolbox
import CoreAudio
import os

enum VoiceProcessingError: Error {
    case componentNotFound
    case setupFailed(step: String, status: OSStatus)
    case badClientFormat
}

/// Microphone capture through the low-level AUVoiceIO unit
/// (kAudioUnitSubType_VoiceProcessingIO) — the same processing chain
/// conferencing apps use: echo cancellation + noise suppression + AGC.
///
/// Why not AVAudioEngine.setVoiceProcessingEnabled? On this setup it either
/// starts but delivers zero input buffers (tap-only, no output render path),
/// or fails kAUInitialize (-10875) with a muted monitor path — and a failed
/// attempt poisons the engine. Driving AUVoiceIO directly avoids all of it.
///
/// Hard-won rules encoded below:
/// - Element 1 = mic side, element 0 = output/reference side. Element 0 must
///   stay ENABLED and must have a data source (our silence render callback),
///   or the input side never runs.
/// - macOS 14+ ducks all other system audio by default — must set the ducking
///   configuration to minimum or the recorded meeting audio gets quiet.
/// - Client stream formats may only be set on the client-facing scopes
///   (Output/element 1, Input/element 0) and must keep the unit's own sample
///   rate — asking VPIO to resample is a classic -10875 source.
/// - AudioUnitRender needs an ABL with real memory: set AVAudioPCMBuffer
///   frameLength BEFORE rendering so mDataByteSize is correct.
final class VoiceProcessingMicCapture {

    var onBuffer: ((AVAudioPCMBuffer, AVAudioTime) -> Void)?
    private(set) var streamFormat: AVAudioFormat?

    private var unit: AudioUnit?
    private var didInitialize = false
    private var didStart = false
    private var stopped = false
    private let stateLock = NSLock()

    fileprivate var clientFormat: AVAudioFormat?
    fileprivate var maxFrames: UInt32 = 4096
    private let counter = OSAllocatedUnfairLock<Int64>(initialState: 0)
    private let renderErrors = OSAllocatedUnfairLock<Int64>(initialState: 0)

    var bufferCount: Int64 { counter.withLock { $0 } }

    private var deviceListenerBlock: AudioObjectPropertyListenerBlock?
    private var deviceListenerAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    // MARK: - Start

    /// Blocking — call off the main thread. Throws on any fatal setup failure
    /// after tearing down whatever was partially built.
    func start() throws {
        do {
            try setUp()
        } catch {
            tearDown()
            throw error
        }
    }

    private func setUp() throws {
        var desc = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_VoiceProcessingIO,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        guard let component = AudioComponentFindNext(nil, &desc) else {
            Log.write("vp: AudioComponentFindNext found no VoiceProcessingIO")
            throw VoiceProcessingError.componentNotFound
        }
        var newUnit: AudioUnit?
        try check(AudioComponentInstanceNew(component, &newUnit), "InstanceNew")
        guard let unit = newUnit else { throw VoiceProcessingError.componentNotFound }
        self.unit = unit

        // Enable mic capture on element 1. Output element 0 stays enabled
        // (default) — VPIO needs its render cycle to run the input side and
        // to track the echo reference.
        var one: UInt32 = 1
        try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO,
                                       kAudioUnitScope_Input, 1,
                                       &one, propSize(of: one)),
                  "EnableIO input")

        bindDefaultDevices(unit)
        configureVoiceProcessing(unit)

        // Learn the unit's preferred client-side capture format, then try to
        // pin it to Float32 non-interleaved mono at the SAME sample rate.
        var asbd = AudioStreamBasicDescription()
        var asbdSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check(AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat,
                                       kAudioUnitScope_Output, 1,
                                       &asbd, &asbdSize),
                  "GetFormat output/1")
        Log.write("vp: unit preferred client format sr=\(asbd.mSampleRate) ch=\(asbd.mChannelsPerFrame)")

        var mono = monoFloatASBD(sampleRate: asbd.mSampleRate)
        let setMono = AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat,
                                           kAudioUnitScope_Output, 1,
                                           &mono, propSize(of: mono))
        if setMono != noErr {
            Log.write("vp: mono client format rejected (status=\(setMono)) — keeping unit's format")
        }

        // Give the reference/render side a defined format at the same rate.
        var renderFmt = monoFloatASBD(sampleRate: asbd.mSampleRate)
        let setRender = AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat,
                                             kAudioUnitScope_Input, 0,
                                             &renderFmt, propSize(of: renderFmt))
        if setRender != noErr {
            Log.write("vp: render-side format set failed (status=\(setRender)) — continuing")
        }

        var inputCB = AURenderCallbackStruct(
            inputProc: vpInputCallback,
            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque()
        )
        try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_SetInputCallback,
                                       kAudioUnitScope_Global, 1,
                                       &inputCB, propSize(of: inputCB)),
                  "SetInputCallback")

        // Silence source for element 0 — without a data source on the output
        // element the whole unit stalls and the mic delivers zero buffers.
        var silenceCB = AURenderCallbackStruct(
            inputProc: vpSilenceCallback,
            inputProcRefCon: nil
        )
        try check(AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback,
                                       kAudioUnitScope_Input, 0,
                                       &silenceCB, propSize(of: silenceCB)),
                  "SetRenderCallback silence")

        try check(AudioUnitInitialize(unit), "Initialize")
        didInitialize = true

        // Initialize may adjust the client format — read back the definitive
        // one and build the AVAudioFormat every emitted buffer will use.
        var finalASBD = AudioStreamBasicDescription()
        var finalSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check(AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat,
                                       kAudioUnitScope_Output, 1,
                                       &finalASBD, &finalSize),
                  "GetFormat post-init")
        guard finalASBD.mSampleRate > 0,
              let format = AVAudioFormat(streamDescription: &finalASBD) else {
            Log.write("vp: unusable client format after init (sr=\(finalASBD.mSampleRate))")
            throw VoiceProcessingError.badClientFormat
        }
        clientFormat = format
        streamFormat = format

        var reportedMax: UInt32 = 0
        var maxSize = UInt32(MemoryLayout<UInt32>.size)
        if AudioUnitGetProperty(unit, kAudioUnitProperty_MaximumFramesPerSlice,
                                kAudioUnitScope_Global, 0,
                                &reportedMax, &maxSize) == noErr {
            maxFrames = max(4096, reportedMax)
        }

        try check(AudioOutputUnitStart(unit), "Start")
        didStart = true

        installDeviceListener()
        Log.write("vp: STARTED ✓ client format sr=\(format.sampleRate) ch=\(format.channelCount) maxFrames=\(maxFrames)")
    }

    // MARK: - Device binding & VP properties (best-effort, non-fatal)

    private func bindDefaultDevices(_ unit: AudioUnit) {
        func defaultDevice(_ selector: AudioObjectPropertySelector) -> AudioDeviceID? {
            var address = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var device = AudioDeviceID(0)
            var size = UInt32(MemoryLayout<AudioDeviceID>.size)
            let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                                    &address, 0, nil, &size, &device)
            return status == noErr ? device : nil
        }

        // On VPIO the element selects which side you bind: 1 = mic device,
        // 0 = output/reference device. Best-effort — the unit falls back to
        // system defaults on its own if a set is rejected.
        if var input = defaultDevice(kAudioHardwarePropertyDefaultInputDevice) {
            let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                              kAudioUnitScope_Global, 1,
                                              &input, propSize(of: input))
            Log.write("vp: bind input device \(input) status=\(status)")
        }
        if var output = defaultDevice(kAudioHardwarePropertyDefaultOutputDevice) {
            let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                              kAudioUnitScope_Global, 0,
                                              &output, propSize(of: output))
            Log.write("vp: bind output device \(output) status=\(status)")
        }
    }

    private func configureVoiceProcessing(_ unit: AudioUnit) {
        // Default ducking lowers all other system audio — which is exactly
        // the meeting audio we're recording (audibly AND in the SCK capture).
        var ducking = AUVoiceIOOtherAudioDuckingConfiguration(
            mEnableAdvancedDucking: false,
            mDuckingLevel: .min
        )
        let duckStatus = AudioUnitSetProperty(unit, kAUVoiceIOProperty_OtherAudioDuckingConfiguration,
                                              kAudioUnitScope_Global, 0,
                                              &ducking, propSize(of: ducking))
        if duckStatus != noErr {
            Log.write("vp: WARNING ducking config failed status=\(duckStatus) — system audio may get quieter while recording")
        }

        var agc: UInt32 = 1
        let agcStatus = AudioUnitSetProperty(unit, kAUVoiceIOProperty_VoiceProcessingEnableAGC,
                                             kAudioUnitScope_Global, 0,
                                             &agc, propSize(of: agc))
        if agcStatus != noErr { Log.write("vp: AGC enable failed status=\(agcStatus)") }

        var bypass: UInt32 = 0
        let bypassStatus = AudioUnitSetProperty(unit, kAUVoiceIOProperty_BypassVoiceProcessing,
                                                kAudioUnitScope_Global, 0,
                                                &bypass, propSize(of: bypass))
        if bypassStatus != noErr { Log.write("vp: bypass disable failed status=\(bypassStatus)") }
    }

    private func installDeviceListener() {
        let block: AudioObjectPropertyListenerBlock = { _, _ in
            Log.write("vp: default input device changed mid-recording — still recording from the bound device (follow-the-default is future work)")
        }
        deviceListenerBlock = block
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject),
                                            &deviceListenerAddress,
                                            DispatchQueue.global(qos: .utility),
                                            block)
    }

    // MARK: - Input path (realtime thread)

    fileprivate func handleInput(flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
                                 timeStamp: UnsafePointer<AudioTimeStamp>,
                                 bus: UInt32,
                                 frames: UInt32) -> OSStatus {
        guard let unit, let format = clientFormat,
              frames > 0, frames <= maxFrames,
              let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
            return noErr
        }
        // frameLength BEFORE render so the ABL's mDataByteSize is sized right.
        pcm.frameLength = AVAudioFrameCount(frames)

        let status = AudioUnitRender(unit, flags, timeStamp, bus, frames, pcm.mutableAudioBufferList)
        guard status == noErr else {
            let n = renderErrors.withLock { $0 += 1; return $0 }
            if n == 1 { Log.write("vp: AudioUnitRender failed status=\(status)") }
            return status
        }

        let n = counter.withLock { $0 += 1; return $0 }
        if n == 1 || n % 200 == 0 {
            Log.write("vp mic buffer #\(n) frames=\(frames)")
        }
        let time = AVAudioTime(audioTimeStamp: timeStamp, sampleRate: format.sampleRate)
        onBuffer?(pcm, time)
        return noErr
    }

    // MARK: - Stop

    /// Idempotent; may block briefly in AUVoiceIO teardown — call off main.
    func stop() {
        stateLock.lock()
        let alreadyStopped = stopped
        stopped = true
        stateLock.unlock()
        guard !alreadyStopped else { return }
        tearDown()
        Log.write("vp: stopped, total buffers=\(bufferCount) renderErrors=\(renderErrors.withLock { $0 })")
    }

    private func tearDown() {
        if let block = deviceListenerBlock {
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject),
                                                   &deviceListenerAddress,
                                                   DispatchQueue.global(qos: .utility),
                                                   block)
            deviceListenerBlock = nil
        }
        guard let unit else { return }
        if didStart { AudioOutputUnitStop(unit) }
        if didInitialize { AudioUnitUninitialize(unit) }
        AudioComponentInstanceDispose(unit)
        self.unit = nil
        didStart = false
        didInitialize = false
    }

    // MARK: - Helpers

    private func check(_ status: OSStatus, _ step: String) throws {
        guard status == noErr else {
            Log.write("vp: \(step) FAILED status=\(status)")
            throw VoiceProcessingError.setupFailed(step: step, status: status)
        }
    }

    private func propSize<T>(of value: T) -> UInt32 {
        UInt32(MemoryLayout<T>.size)
    }

    private func monoFloatASBD(sampleRate: Float64) -> AudioStreamBasicDescription {
        AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 32,
            mReserved: 0
        )
    }
}

// MARK: - C callbacks

private let vpInputCallback: AURenderCallback = { refCon, ioActionFlags, inTimeStamp, inBusNumber, inNumberFrames, _ in
    let capture = Unmanaged<VoiceProcessingMicCapture>.fromOpaque(refCon).takeUnretainedValue()
    return capture.handleInput(flags: ioActionFlags,
                               timeStamp: inTimeStamp,
                               bus: inBusNumber,
                               frames: inNumberFrames)
}

private let vpSilenceCallback: AURenderCallback = { _, ioActionFlags, _, _, _, ioData in
    if let abl = ioData {
        for buffer in UnsafeMutableAudioBufferListPointer(abl) {
            if let data = buffer.mData {
                memset(data, 0, Int(buffer.mDataByteSize))
            }
        }
    }
    ioActionFlags.pointee.insert(.unitRenderAction_OutputIsSilence)
    return noErr
}
