// SPDX-License-Identifier: GPL-3.0-only
// Run with VividEAC3Sample.swift and VividDolbyAudio.swift using swiftc.
import AVFoundation

@main
struct EAC3SampleTests {
    static func main() throws {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool) {
            precondition(condition(), "EC-3 check \(checks + 1) failed")
            checks += 1
        }
        // Synthetic syncframe payload, for construction tests only, not audio decoding.
        func packet(size: Int = 3072, rate: UInt8 = 0) -> Data {
            let code = size / 2 - 1
            var data = Data(repeating: 0xa5, count: size)
            data[0] = 0x0b; data[1] = 0x77
            data[2] = UInt8(code >> 8); data[3] = UInt8(code & 255)
            data[4] = rate << 6 | 0x3f; data[5] = 0x80
            return data
        }
        let builder = VividEAC3Sample()
        let pts = CMTime(value: 123456, timescale: 1000)
        func sample(_ data: Data, rate: Int = 48000, channels: Int = 6,
                    time: CMTime? = nil) -> CMSampleBuffer? {
            data.withUnsafeBytes { builder.make(bytes: $0, presentationTime: time ?? pts,
                sampleRate: rate, channels: channels) }
        }
        let bytes = packet()
        let result = sample(bytes)!
        check(CMSampleBufferGetNumSamples(result) == 1)
        check(CMSampleBufferGetPresentationTimeStamp(result) == pts)
        check(abs(CMSampleBufferGetDuration(result).seconds - 0.032) < 0.000001)
        let format = CMSampleBufferGetFormatDescription(result)!
        let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)!.pointee
        check(asbd.mFormatID == kAudioFormatEnhancedAC3)
        check(asbd.mFramesPerPacket == 1536 && asbd.mChannelsPerFrame == 6)
        let block = CMSampleBufferGetDataBuffer(result)!
        var copy = Data(count: bytes.count)
        let copied = copy.withUnsafeMutableBytes {
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: bytes.count, destination: $0.baseAddress!)
        }
        check(copied == noErr && copy == bytes)
        check(sample(packet(size: 2048)) != nil)
        check(sample(packet(rate: 1), rate: 44100) != nil)
        check(sample(packet(rate: 2), rate: 32000) != nil)
        check(sample(bytes, rate: 44100) == nil)
        check(sample(bytes, channels: 2) == nil)
        check(sample(bytes, time: .invalid) == nil)
        check(sample(Data(bytes.prefix(5))) == nil)
        check(sample(bytes + bytes) == nil)
        for (index, replacement): (Int, UInt8) in [(0, 0), (2, 0x45), (2, 0x0d), (4, 0x0f), (4, 0xff), (5, 0x40)] {
            var invalid = bytes; invalid[index] = replacement
            check(sample(invalid) == nil)
        }
        check(VividDolbyAudio(codec: "eac3", profile: 30, evidence: .streamProfile).format == .eac3JOC)
        check(VividDolbyAudio(codec: "eac3", profile: nil, evidence: .streamProfile).format == .eac3)
        check(VividDolbyAudio(codec: "ac3", profile: 30, evidence: .streamProfile).format == .ac3)
        print("Passed \(checks) EC-3 construction and classification checks.")
    }
}
