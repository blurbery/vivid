// SPDX-License-Identifier: GPL-3.0-only
// Additional permission: LICENSE-APPLE-EXCEPTION at the repository root.
#if os(tvOS) && VIVID_ATMOS_TRIAL
import AVFoundation

enum VividPCMBufferPacking {
    // VLC's sample-buffer output uses packed, interleaved Float32 PCM.
    // Preserve sample count, source PTS and channel layout while packing planes.
    static func make(format: AVAudioFormat, planes: [ContiguousArray<Float>],
                     frames: Int, presentationTime: CMTime) -> (sample: CMSampleBuffer, peak: Float)? {
        let channels = Int(format.channelCount)
        guard frames > 0, channels > 0, presentationTime.isNumeric,
              format.sampleRate.isFinite, format.sampleRate > 0 else { return nil }
        if format.isInterleaved {
            guard planes.count == 1, planes[0].count >= frames * channels else { return nil }
        } else {
            guard planes.count == channels, planes.allSatisfy({ $0.count >= frames }) else { return nil }
        }
        let packedFormat: AVAudioFormat?
        if let layout = format.channelLayout {
            packedFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: format.sampleRate,
                                         interleaved: true, channelLayout: layout)
        } else {
            packedFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: format.sampleRate,
                                         channels: format.channelCount, interleaved: true)
        }
        guard let packedFormat else { return nil }
        var values = [Float](repeating: 0, count: frames * channels)
        var peak: Float = 0
        for frame in 0..<frames {
            for channel in 0..<channels {
                let index = frame * channels + channel
                let value = format.isInterleaved ? planes[0][index] : planes[channel][frame]
                guard value.isFinite else { return nil }
                values[index] = value
                peak = max(peak, abs(value))
            }
        }
        let bytes = values.count * MemoryLayout<Float>.size
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
            blockLength: bytes, blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
            offsetToData: 0, dataLength: bytes, flags: kCMBlockBufferAssureMemoryNowFlag,
            blockBufferOut: &block) == noErr, let block else { return nil }
        let copied = values.withUnsafeBytes { raw in
            CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: block,
                                          offsetIntoDestination: 0, dataLength: bytes)
        }
        guard copied == noErr else { return nil }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: presentationTime,
                                        decodeTimeStamp: .invalid)
        var size = channels * MemoryLayout<Float>.size
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block,
            formatDescription: packedFormat.formatDescription, sampleCount: frames,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1,
            sampleSizeArray: &size, sampleBufferOut: &sample) == noErr, let sample else { return nil }
        return (sample, peak)
    }
}
#endif
