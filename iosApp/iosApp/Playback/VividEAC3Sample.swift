// SPDX-License-Identifier: GPL-3.0-only
// Additional permission: LICENSE-APPLE-EXCEPTION at the repository root.
import AVFoundation

/// Constructs one compressed EC-3 sample without decoding or changing its payload.
/// The first trial accepts a single independent, six-block syncframe per packet.
/// Other packet layouts are left to KSPlayer's normal E-AC-3 decoder.
final class VividEAC3Sample {
    struct Header: Equatable {
        let sampleRate: Int
        let channels: Int
        let channelMode: UInt8

        init?(bytes: UnsafeRawBufferPointer) {
            guard bytes.count >= 6, bytes[0] == 0x0b, bytes[1] == 0x77,
                  bytes[2] >> 6 == 0, (bytes[2] >> 3) & 7 == 0,
                  ((Int(bytes[2] & 7) << 8 | Int(bytes[3])) + 1) * 2 == bytes.count,
                  bytes[4] >> 6 < 3, (bytes[4] >> 4) & 3 == 3,
                  bytes[5] >> 3 == 16 else { return nil }
            sampleRate = [48_000, 44_100, 32_000][Int(bytes[4] >> 6)]
            channelMode = (bytes[4] >> 1) & 7
            channels = [2, 1, 2, 3, 3, 4, 4, 5][Int(channelMode)] + Int(bytes[4] & 1)
        }
    }

    private var cached: (Header, CMAudioFormatDescription)?

    func make(bytes: UnsafeRawBufferPointer, presentationTime: CMTime,
              sampleRate: Int, channels: Int) -> CMSampleBuffer? {
        guard presentationTime.isNumeric, let base = bytes.baseAddress,
              let header = Header(bytes: bytes), header.sampleRate == sampleRate,
              header.channels == channels else { return nil }
        let format: CMAudioFormatDescription
        if let cached, cached.0 == header {
            format = cached.1
        } else {
            // EC-3 elementary syncframes carry their own decoder/JOC information.
            // No invented dec3 cookie or inferred Atmos channel layout is supplied.
            var asbd = AudioStreamBasicDescription(mSampleRate: Double(sampleRate),
                mFormatID: kAudioFormatEnhancedAC3, mFormatFlags: 0, mBytesPerPacket: 0,
                mFramesPerPacket: 1536, mBytesPerFrame: 0,
                mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 0, mReserved: 0)
            var description: CMAudioFormatDescription?
            guard CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd,
                layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil,
                extensions: nil, formatDescriptionOut: &description) == noErr,
                let description else { return nil }
            format = description
            cached = (header, format)
        }
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault,
            memoryBlock: nil, blockLength: bytes.count, blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil, offsetToData: 0, dataLength: bytes.count,
            flags: 0, blockBufferOut: &block) == noErr, let block,
            CMBlockBufferReplaceDataBytes(with: base, blockBuffer: block,
                offsetIntoDestination: 0, dataLength: bytes.count) == noErr else { return nil }
        var packet = AudioStreamPacketDescription(mStartOffset: 0,
            mVariableFramesInPacket: 1536, mDataByteSize: UInt32(bytes.count))
        var sample: CMSampleBuffer?
        guard CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: kCFAllocatorDefault,
            dataBuffer: block, formatDescription: format, sampleCount: 1,
            presentationTimeStamp: presentationTime, packetDescriptions: &packet,
            sampleBufferOut: &sample) == noErr else { return nil }
        return sample
    }
}
