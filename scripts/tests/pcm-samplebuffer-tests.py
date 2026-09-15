#!/usr/bin/env python3
"""Exercise the actual PCM adapter against deterministic renderer/source doubles.

This checks queue lifecycle, not Apple's implementation or acoustic lip sync.
Pass a task-owned work directory for the temporary executable and module cache.
"""
import pathlib
import subprocess
import sys
import tempfile

root = pathlib.Path(__file__).resolve().parents[2]
work = pathlib.Path(sys.argv[1]).resolve()
work.mkdir(parents=True, exist_ok=True)
source = (root / 'iosApp/iosApp/Playback/VividPCMSampleBufferOutput.swift').read_text()
source = source.replace('#if os(tvOS) && VIVID_ATMOS_TRIAL', '').replace('#endif', '')
source = source.replace('import KSPlayer', '')
source = source.replace('AVSampleBufferAudioRenderer()', 'TestRenderer()')
source = source.replace('AVSampleBufferRenderSynchronizer()', 'TestSynchronizer()')
source = source.replace('AVAudioSession.sharedInstance()', 'TestSession.sharedInstance()')
source = source.replace('CMTimebaseGetEffectiveRate(synchronizer.timebase)', 'Double(synchronizer.rate)')
source = source.replace('VividPCMBufferPacking.make', 'testPackPCM')

doubles = r'''
func testPackPCM(format: AVAudioFormat, planes: [ContiguousArray<Float>], frames: Int,
                 presentationTime: CMTime) -> (sample: Double, peak: Float)? {
    (presentationTime.seconds, 0.5)
}
func CMSampleBufferGetPresentationTimeStamp(_ sample: Double) -> CMTime {
    CMTime(seconds: sample, preferredTimescale: 48000)
}
protocol AudioOutput: AnyObject {
    init()
}
protocol OutputRenderSourceDelegate: AnyObject {
    func getAudioOutputRender() -> AudioFrame?
    func setAudio(time: CMTime, position: Int64, sampledHostTime: CFTimeInterval)
}
final class AudioFrame {
    let cmtime: CMTime
    let compressedSampleBuffer: Int? = nil
    let numberOfSamples = 1536
    let audioFormat = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
    var timebase: (num: Int32, den: Int32) { (1, 48000) }
    var timestamp: Int64 { cmtime.value }
    init(_ seconds: Double) { cmtime = CMTime(seconds: seconds, preferredTimescale: 48000) }
    func toFloat() -> [ContiguousArray<Float>] { [[0.5], [0.5]] }
    func toCMSampleBuffer() -> Double? { cmtime.seconds }
}
final class TestSession {
    static func sharedInstance() -> TestSession { TestSession() }
    var maximumOutputNumberOfChannels = 2
    var outputLatency = 2.0
    func setPreferredOutputNumberOfChannels(_ count: Int) throws {}
}
final class TestRenderer {
    enum Status: Int { case unknown, rendering, failed }
    enum Spatial { case monoStereoAndMultichannel }
    static weak var latest: TestRenderer?
    var status = Status.unknown
    var error: NSError? = nil
    var volume: Float = 1
    var isMuted = false
    var allowedAudioSpatializationFormats = Spatial.monoStereoAndMultichannel
    var audioTimePitchAlgorithm = AVAudioTimePitchAlgorithm.spectral
    var isReadyForMoreMediaData = true
    var samples: [Double] = []
    var flushCount = 0
    init() { Self.latest = self }
    func enqueue(_ sample: Double) { samples.append(sample); status = .rendering }
    func flush() { flushCount += 1; samples.removeAll() }
    func requestMediaDataWhenReady(on queue: DispatchQueue, using block: @escaping () -> Void) {}
    func stopRequestingMediaData() {}
}
final class TestSynchronizer {
    static weak var latest: TestSynchronizer?
    var rate: Float = 0
    var delaysRateChangeUntilHasSufficientMediaData = true
    var time = CMTime.zero
    var anchors: [Double] = []
    weak var renderer: TestRenderer?
    weak var video: AVSampleBufferDisplayLayer?
    var removedVideos = 0
    init() { Self.latest = self }
    func addRenderer(_ value: TestRenderer) { renderer = value }
    func addRenderer(_ value: AVSampleBufferDisplayLayer) { video = value }
    func removeRenderer(_ value: AVSampleBufferDisplayLayer, at time: CMTime,
                        completionHandler: ((Bool) -> Void)?) {
        removedVideos += 1
        if video === value { video = nil }
        completionHandler?(true)
    }
    func setRate(_ value: Float, time: CMTime) {
        if value > 0 {
            precondition(renderer?.samples.first == time.seconds, "first sample must be enqueued before anchoring")
            anchors.append(time.seconds)
        }
        self.time = time
        rate = value
    }
    func currentTime() -> CMTime { time }
}
final class TestSource: OutputRenderSourceDelegate {
    private let lock = NSLock()
    private var frames: [AudioFrame] = []
    var pendingCount: Int { lock.lock(); defer { lock.unlock() }; return frames.count }
    func append(_ seconds: Double) { lock.lock(); frames.append(AudioFrame(seconds)); lock.unlock() }
    func getAudioOutputRender() -> AudioFrame? {
        lock.lock(); defer { lock.unlock() }
        return frames.isEmpty ? nil : frames.removeFirst()
    }
    func setAudio(time: CMTime, position: Int64, sampledHostTime: CFTimeInterval) {
        precondition(time.isNumeric && sampledHostTime <= CACurrentMediaTime())
    }
}
'''
tests = r'''
var checks = 0
func check(_ condition: @autoclosure () -> Bool, _ label: String) {
    precondition(condition(), label)
    checks += 1
}
func exercise() {
    let source = TestSource()
    var output: VividPCMSampleBufferOutput? = VividPCMSampleBufferOutput()
    weak var released = output
    output!.renderSource = source
    let renderer = TestRenderer.latest!
    let sync = TestSynchronizer.latest!
    output!.prepare(audioFormat: AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!)
    output!.play()
    output!.pause()
    check(sync.anchors.isEmpty, "empty start must not anchor at zero")
    source.append(120)
    output!.play()
    output!.pause()
    check(renderer.samples == [120], "first PCM frame retained")
    check(sync.anchors == [120], "source timestamp anchored once")
    check(renderer.flushCount == 0, "pause must preserve queued audio")
    output!.play()
    output!.pause()
    check(sync.anchors == [120], "resume must preserve anchor")
    output!.flush()
    check(renderer.samples.isEmpty, "seek removes old queued samples")
    source.append(900)
    output!.play()
    output!.pause()
    check(renderer.samples == [900], "post-seek first sample retained")
    check(sync.anchors == [120, 900], "seek anchors at new source timestamp")
    output!.flush()
    renderer.isReadyForMoreMediaData = false
    source.append(1000)
    output!.play()
    output!.pause()
    check(renderer.samples.isEmpty, "backpressure must not consume source")
    renderer.isReadyForMoreMediaData = true
    output!.play()
    output!.pause()
    check(renderer.samples == [1000], "sample survives backpressure")
    output!.flush()
    output!.play()
    source.append(1100)
    Thread.sleep(forTimeInterval: 0.08)
    output!.pause()
    check(renderer.samples == [1100], "empty decoded queue retried without readiness edge")
    output!.playbackRate = 1.5
    output!.play()
    output!.pause()
    check(sync.anchors.last == 1100, "speed change does not re-anchor")
    renderer.status = .failed
    output!.play()
    output!.pause()
    check(sync.rate == 0, "renderer failure stops clock")
    output = nil
    Thread.sleep(forTimeInterval: 0.03)
    check(released == nil, "callbacks must not retain output after teardown")
}
exercise()
func exerciseTimeline() {
    let source = TestSource()
    for i in 0..<1000 { source.append(Double(i) * 0.032) }
    let output = VividPCMSampleBufferOutput()
    output.renderSource = source
    let renderer = TestRenderer.latest!
    let sync = TestSynchronizer.latest!
    let firstLayer = AVSampleBufferDisplayLayer()
    check(output.connectVideo(firstLayer), "attach existing video renderer")
    check(sync.video === firstLayer, "video and audio use the same synchronizer")
    output.play()
    Thread.sleep(forTimeInterval: 0.08)
    check(output.videoAdmission(nextTime: 1.0 / 24, fps: 24)?.enqueue == true, "admit future frame before display deadline")
    check(output.videoAdmission(nextTime: 0.2, fps: 24)?.enqueue == false, "hold frames beyond presentation window")
    check(output.videoAdmission(nextTime: -0.01, fps: 24)?.enqueue == true, "let Apple handle a late frame")
    output.pause()
    check(renderer.samples.count <= 95 && renderer.samples.count >= 94, "bound audio queue to three seconds plus one frame")
    check(source.pendingCount >= 905, "retain backpressure in KSPlayer decoded queue")
    check(output.videoAdmission(nextTime: 0.01, fps: 24)?.enqueue == false, "paused timeline must not admit video")
    sync.time = CMTime(seconds: 2, preferredTimescale: 48000)
    output.play()
    Thread.sleep(forTimeInterval: 0.08)
    output.pause()
    check(renderer.samples.last! >= 4.9 && renderer.samples.last! < 5.04, "refill bounded audio as playback advances")
    let nextLayer = AVSampleBufferDisplayLayer()
    check(output.connectVideo(nextLayer), "attach replacement display layer")
    check(sync.video === nextLayer && sync.removedVideos == 1, "detach obsolete display layer")
    output.flush()
    output.resetVideoTimeline(to: CMTime(seconds: 900, preferredTimescale: 48000))
    check(sync.rate == 0 && sync.time.seconds == 900, "seek preview remains on stopped shared timeline")
    check(output.videoAdmission(nextTime: 900, fps: 24) == nil, "new audio must establish post-seek anchor")
}
exerciseTimeline()
print("Passed \(checks) PCM adapter lifecycle checks (renderer/source doubles).")
'''
with tempfile.TemporaryDirectory(prefix='pcm-lifecycle-', dir=work) as temporary:
    directory = pathlib.Path(temporary)
    swift = directory / 'main.swift'
    swift.write_text(source + doubles + tests)
    executable = directory / 'checks'
    subprocess.run(['xcrun', 'swiftc', '-module-cache-path', str(work / 'swift-module-cache'),
                    str(swift), '-o', str(executable)], check=True, timeout=120)
    subprocess.run([str(executable)], check=True, timeout=15)
    packing = (root / 'iosApp/iosApp/Playback/VividPCMBufferPacking.swift').read_text()
    packing = packing.replace('#if os(tvOS) && VIVID_ATMOS_TRIAL', '').replace('#endif', '')
    packing_checks = r'''
var checks = 0
func check(_ condition: @autoclosure () -> Bool, _ label: String) {
    precondition(condition(), label); checks += 1
}
func inspect(_ rate: Double, _ channels: Int, _ frames: Int, _ interleaved: Bool, _ pts: Double) {
    let layout = AVAudioChannelLayout(layoutTag: channels == 6 ? kAudioChannelLayoutTag_MPEG_5_1_A :
                                      channels == 1 ? kAudioChannelLayoutTag_Mono : kAudioChannelLayoutTag_Stereo)!
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate,
                               interleaved: interleaved, channelLayout: layout)
    var expected: [Float] = []
    var planar = (0..<channels).map { _ in ContiguousArray<Float>() }
    for frame in 0..<frames {
        for channel in 0..<channels {
            let value = Float((frame + channel) % 17 - 8) / 16
            planar[channel].append(value); expected.append(value)
        }
    }
    let planes = interleaved ? [ContiguousArray(expected)] : planar
    let time = CMTime(seconds: pts, preferredTimescale: 48000)
    let result = VividPCMBufferPacking.make(format: format, planes: planes,
                                            frames: frames, presentationTime: time)!
    let sample = result.sample
    let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(CMSampleBufferGetFormatDescription(sample)!)!.pointee
    check(asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0, "output must be interleaved")
    check(asbd.mBitsPerChannel == 32 && asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0, "packed float32")
    check(asbd.mChannelsPerFrame == channels && asbd.mBytesPerFrame == channels * 4, "channel and frame sizes")
    check(asbd.mSampleRate == rate && CMSampleBufferGetNumSamples(sample) == frames, "no rate or sample-count change")
    check(CMSampleBufferGetPresentationTimeStamp(sample) == time, "source timestamp unchanged")
    let block = CMSampleBufferGetDataBuffer(sample)!
    var decoded = [Float](repeating: 0, count: expected.count)
    let status = decoded.withUnsafeMutableBytes { raw in
        CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: raw.count, destination: raw.baseAddress!)
    }
    check(status == noErr && decoded == expected, "exact channel order and nonzero sample bytes")
    check(result.peak == expected.map { abs($0) }.max()!, "signal peak reflects packed bytes")
    // Exercise Apple's PCM buffer interpretation, not only a raw byte copy.
    var retained: CMBlockBuffer?
    let buffers = AudioBufferList.allocate(maximumBuffers: 1)
    defer { free(buffers.unsafeMutablePointer) }
    let read = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sample,
        bufferListSizeNeededOut: nil, bufferListOut: buffers.unsafeMutablePointer,
        bufferListSize: MemoryLayout<AudioBufferList>.size, blockBufferAllocator: kCFAllocatorDefault,
        blockBufferMemoryAllocator: kCFAllocatorDefault, flags: 0, blockBufferOut: &retained)
    check(read == noErr && buffers.count == 1 && buffers[0].mNumberChannels == channels &&
          buffers[0].mDataByteSize == expected.count * 4, "CoreMedia sees one complete interleaved audio buffer")
}
inspect(48000, 2, 1536, false, 0)
inspect(48000, 6, 1536, false, 120)
inspect(44100, 2, 1024, true, 36000)
inspect(48000, 1, 1, false, 900)
let stereo = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
check(VividPCMBufferPacking.make(format: stereo, planes: [[1]], frames: 1,
                                 presentationTime: .zero) == nil, "reject missing channel")
check(VividPCMBufferPacking.make(format: stereo, planes: [[1], []], frames: 1,
                                 presentationTime: .zero) == nil, "reject short channel")
check(VividPCMBufferPacking.make(format: stereo, planes: [[Float.nan], [0]], frames: 1,
                                 presentationTime: .zero) == nil, "reject invalid samples")
check(VividPCMBufferPacking.make(format: stereo, planes: [[1], [0]], frames: 1,
                                 presentationTime: .invalid) == nil, "reject invalid timestamp")
print("Passed \(checks) real CoreMedia PCM packing checks.")
// Test Apple's actual shared timebase wiring separately from the test doubles.
let audio = AVSampleBufferAudioRenderer()
let video = AVSampleBufferDisplayLayer()
let synchronizer = AVSampleBufferRenderSynchronizer()
FileHandle.standardError.write(Data("Connecting real audio renderer\n".utf8))
synchronizer.addRenderer(audio)
FileHandle.standardError.write(Data("Connecting real video renderer\n".utf8))
synchronizer.addRenderer(video)
synchronizer.setRate(0, time: CMTime(seconds: 42, preferredTimescale: 48000))
let deadline = Date().addingTimeInterval(1)
while abs(CMTimebaseGetTime(video.timebase).seconds - 42) > 0.001 && Date() < deadline {
    Thread.sleep(forTimeInterval: 0.01)
}
check(abs(CMTimebaseGetTime(audio.timebase).seconds - 42) < 0.001, "real audio timeline follows synchronizer")
check(abs(CMTimebaseGetTime(video.timebase).seconds - 42) < 0.001, "real video timeline follows synchronizer")
check(CMTimebaseGetEffectiveRate(audio.timebase) == 0 && CMTimebaseGetEffectiveRate(video.timebase) == 0,
      "both real renderers stay paused together")
synchronizer.removeRenderer(video, at: .invalid, completionHandler: nil)
synchronizer.removeRenderer(audio, at: .invalid, completionHandler: nil)
print("Passed 3 real Apple shared-timebase checks (paused, no audible playback).")
'''
    swift.write_text(packing + packing_checks)
    subprocess.run(['xcrun', 'swiftc', '-module-cache-path', str(work / 'swift-module-cache'),
                    str(swift), '-o', str(executable)], check=True, timeout=120)
    subprocess.run([str(executable)], check=True, timeout=15)
