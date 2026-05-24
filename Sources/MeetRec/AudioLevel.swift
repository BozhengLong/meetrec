import Foundation
import AVFoundation

enum AudioLevel {
    /// Returns the peak absolute sample value across all channels of an
    /// AVAudioPCMBuffer (Float32, non-interleaved). Result is clamped to 0...1.
    static func peak(of buffer: AVAudioPCMBuffer) -> Float {
        let frames = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        guard frames > 0, channels > 0 else { return 0 }

        var maxAbs: Float = 0
        for c in 0..<channels {
            guard let data = buffer.floatChannelData?[c] else { continue }
            for i in 0..<frames {
                let v = Swift.abs(data[i])
                if v > maxAbs { maxAbs = v }
            }
        }
        return min(maxAbs, 1.0)
    }
}
