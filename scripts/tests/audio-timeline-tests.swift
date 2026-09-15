// SPDX-License-Identifier: GPL-3.0-only
// Compile alongside the patched KSPlayer AudioRendererPlayer.swift on macOS.
// Minimal queue doubles exercise the real renderer lifecycle; all output is muted silence.
import AVFoundation

public extension CMTime {
    init(seconds: Double) { self.init(seconds: seconds, preferredTimescale: 600_000) }
}
func KSLog(_ message: String) {}
public protocol OutputRenderSourceDelegate: AnyObject {
    func getAudioOutputRender() -> AudioFrame?
    func setAudio(time: CMTime, position: Int64)
}
public protocol AudioOutput: AnyObject {
    var renderSource: OutputRenderSourceDelegate? { get set }
    var playbackRate: Float { get set }
    var volume: Float { get set }
    var isMuted: Bool { get set }
    init()
    func prepare(audioFormat: AVAudioFormat)
    func play()
    func pause()
    func flush()
}
public final class AudioFrame {
    let cmtime: CMTime
    let audioFormat = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
    let numberOfSamples: UInt32 = 1536
    let compressedSampleBuffer: CMSampleBuffer?
    init(time: Double) {
        cmtime = CMTime(seconds: time)
        var description: CMAudioFormatDescription?
        precondition(CMAudioFormatDescriptionCreate(allocator: nil, asbd: audioFormat.streamDescription,
            layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil,
            formatDescriptionOut: &description) == noErr)
        var block: CMBlockBuffer?
        precondition(CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil,
            blockLength: 6144, blockAllocator: nil, customBlockSource: nil, offsetToData: 0,
            dataLength: 6144, flags: 0, blockBufferOut: &block) == noErr)
        precondition(CMBlockBufferFillDataBytes(with: 0, blockBuffer: block!, offsetIntoDestination: 0,
            dataLength: 6144) == noErr)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48000),
            presentationTimeStamp: cmtime, decodeTimeStamp: .invalid)
        var size = 4
        var sample: CMSampleBuffer?
        precondition(CMSampleBufferCreateReady(allocator: nil, dataBuffer: block,
            formatDescription: description, sampleCount: 1536, sampleTimingEntryCount: 1,
            sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &size,
            sampleBufferOut: &sample) == noErr)
        compressedSampleBuffer = sample
    }
    init(array: [AudioFrame]) { fatalError("PCM merging is not part of this native handoff test") }
    func toCMSampleBuffer() -> CMSampleBuffer? { compressedSampleBuffer }
}
final class Source: OutputRenderSourceDelegate {
    private let lock = NSLock()
    private var frames: [AudioFrame] = []
    private var observed: [Double] = []
    func enqueue(_ time: Double) { lock.lock(); frames.append(AudioFrame(time: time)); lock.unlock() }
    func clear() { lock.lock(); frames.removeAll(); observed.removeAll(); lock.unlock() }
    var times: [Double] { lock.lock(); defer { lock.unlock() }; return observed }
    func getAudioOutputRender() -> AudioFrame? {
        lock.lock(); defer { lock.unlock() }; return frames.isEmpty ? nil : frames.removeFirst()
    }
    func setAudio(time: CMTime, position: Int64) { lock.lock(); observed.append(time.seconds); lock.unlock() }
}
@main struct AudioTimelineTests {
    static func main() {
        var checks = 0
        func check(_ passed: @autoclosure () -> Bool, _ message: String) {
            precondition(passed(), message); checks += 1
        }
        func settle(_ condition: () -> Bool) {
            let end = Date().addingTimeInterval(2)
            while !condition(), Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
            check(condition(), "Asynchronous timebase update timed out")
        }
        let source = Source()
        let output = AudioRendererPlayer()
        output.isMuted = true
        output.reanchorsAfterFlush = true
        output.renderSource = source
        let video = AVSampleBufferDisplayLayer()
        output.synchronizer.addRenderer(video)
        output.resetTimeline(to: CMTime(seconds: 100))
        source.enqueue(100.032)
        output.play()
        check(source.times.first == 100.032, "Initial anchor must use the first source packet")
        settle { abs(output.currentRenderTime.seconds - 100.032) < 0.5 }
        check(output.synchronizer.renderers.contains { $0 === video },
              "Existing video layer must belong to the audio synchroniser")
        output.pause()
        source.clear()
        source.enqueue(230) // Represents already decoded audio far ahead of the playhead.
        output.play()
        check((source.times.first ?? 999) < 102, "Resume must not jump to a queued future packet")
        output.pause()
        output.flush()
        source.clear()
        output.resetTimeline(to: CMTime(seconds: 3))
        source.enqueue(3.008)
        output.play()
        check(source.times.first == 3.008, "Backward seek must anchor to the post-flush packet")
        settle { abs(output.currentRenderTime.seconds - 3.008) < 0.5 }
        check(output.synchronizer.renderers.contains { $0 === video },
              "Video must remain connected after the backward seek")
        output.pause()
        output.flush()
        source.clear()
        output.play()
        check(source.times.isEmpty && output.needsAudioTimeAnchor, "Empty seek queue must wait, not start at zero")
        source.enqueue(200.064)
        output.play()
        check(source.times.first == 200.064, "Retry must anchor to the newly available packet")
        output.pause()
        output.flush()
        output.synchronizer.removeRenderer(video, at: .invalid, completionHandler: nil)
        print("Passed \(checks) real Apple renderer timeline checks (muted synthetic PCM, not an Atmos test).")
    }
}
