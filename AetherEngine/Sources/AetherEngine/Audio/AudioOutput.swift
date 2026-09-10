import Foundation
import AVFoundation
import CoreMedia

/// Audio output via AVSampleBufferAudioRenderer + AVSampleBufferRenderSynchronizer. The synchronizer is the
/// **master clock** for the whole player: video frames check synchronizer.currentTime() to decide presentation.
final class AudioOutput: @unchecked Sendable {

    let renderer: AVSampleBufferAudioRenderer
    let synchronizer: AVSampleBufferRenderSynchronizer

    private let lock = NSLock()

    /// AE#464: the host's audio presentation offset, applied to every buffer on its way into the
    /// renderer. Guarded because the host writes it from the main actor while the demux thread reads
    /// it in `enqueue`.
    private var presentationOffset: CMTime = .zero

    /// One line per offset change, not per buffer. Reset by `setPresentationOffset`.
    private var loggedOffsetInEffect = false

    init() {
        renderer = AVSampleBufferAudioRenderer()
        synchronizer = AVSampleBufferRenderSynchronizer()
        synchronizer.addRenderer(renderer)

        // Spatial audio for AirPods Pro/Max and HomePod: renderer spatializes multichannel when system-enabled.
        renderer.allowedAudioSpatializationFormats = .multichannel

        // Rate changes ride the synchronizer timebase, and this renderer's algorithm is what decides
        // whether they keep pitch (#434). Pinned here, while the timebase is still stopped.
        AudioRatePolicy.apply(to: renderer)
    }

    /// Add the video display layer to the synchronizer for automatic A/V sync + frame pacing. On iOS18/tvOS18/
    /// macOS15+ Apple split the queue rendering surface onto displayLayer.sampleBufferRenderer; direct
    /// addRenderer(layer) still type-checks but on tvOS 26+ fails with FigVideoQueueRemote err=-12080 after the
    /// first enqueue, so attach the renderer instead.
    func attachVideoLayer(_ displayLayer: AVSampleBufferDisplayLayer) {
        if #available(tvOS 18.0, iOS 18.0, macOS 15.0, *) {
            synchronizer.addRenderer(displayLayer.sampleBufferRenderer)
        } else {
            synchronizer.addRenderer(displayLayer)
        }
    }

    /// Remove the video display layer and block until removal completes. The synchronizer detaches asynchronously;
    /// if the caller immediately assigns displayLayer.controlTimebase for a new Atmos session the layer is briefly
    /// owned by both (Apple-documented UB). Symptom: first PCM->Atmos switch after launch throws FigVideoQueueRemote
    /// err=-12080 and the display layer stops rendering (audio keeps going). The semaphore wait (sub-100ms) makes
    /// the handoff deterministic.
    func detachVideoLayer(_ displayLayer: AVSampleBufferDisplayLayer) {
        let semaphore = DispatchSemaphore(value: 0)
        if #available(tvOS 18.0, iOS 18.0, macOS 15.0, *) {
            synchronizer.removeRenderer(displayLayer.sampleBufferRenderer, at: synchronizer.currentTime()) { _ in
                semaphore.signal()
            }
        } else {
            synchronizer.removeRenderer(displayLayer, at: synchronizer.currentTime()) { _ in
                semaphore.signal()
            }
        }
        let result = semaphore.wait(timeout: .now() + .seconds(1))
        #if DEBUG
        if result == .timedOut {
            EngineLog.emit("[AudioOutput] detachVideoLayer: timed out waiting for synchronizer removal", category: .swPlayback)
        }
        #endif
    }

    var volume: Float {
        get { renderer.volume }
        set { renderer.volume = newValue }
    }

    /// Set playback speed (0.5-2.0). Hosts own rate state (lastRate/pausedByHost); this object is stateless about it.
    func setRate(_ rate: Float) {
        let at = synchronizer.currentTime()
        EngineLog.emit("[AudioOutput] setRate \(rate) at t=\(String(format: "%.3f", at.seconds))", category: .swPlayback)
        synchronizer.setRate(rate, time: at)
    }

    /// Pause audio (and the master clock). Hosts resume via setRate (pausedByHost pattern); deliberately no resume() here.
    func pause() {
        let at = synchronizer.currentTime()
        EngineLog.emit("[AudioOutput] pause at t=\(String(format: "%.3f", at.seconds))", category: .swPlayback)
        synchronizer.setRate(0.0, time: at)
    }

    /// AE#464: set the audio presentation offset. Positive presents audio later than video, which on
    /// this path means stamping its samples further ahead on the synchronizer's timeline: at clock
    /// time t the renderer then plays what was recorded at t minus the offset, while the video layer
    /// still presents t. Applied to buffers enqueued from here on; the samples already inside the
    /// renderer keep the previous offset until something flushes them.
    func setPresentationOffset(seconds: Double) {
        lock.lock()
        defer { lock.unlock() }
        presentationOffset = seconds == 0 ? .zero : CMTime(seconds: seconds, preferredTimescale: 90000)
        loggedOffsetInEffect = false
    }

    /// Enqueue a decoded audio CMSampleBuffer. Always enqueues (renderer buffers internally); gating on
    /// isReadyForMoreMediaData dropped early samples before the synchronizer started, giving silence.
    ///
    /// AE#464: this is where a lip-sync offset is applied, and the position is the point. It is past
    /// the audio tap (whose `sourceTime` is documented as the SOURCE axis and feeds transcription),
    /// past the decoder's gapless clock (which would absorb a sub-100 ms offset as rounding), and
    /// past the caller's `lastEnqueuedAudioPtsSec` bookkeeping (whose lead is measured against the
    /// synchronizer clock, i.e. against the source axis too). Only the renderer sees the shift.
    func enqueue(sampleBuffer: CMSampleBuffer) {
        renderer.enqueue(retimed(sampleBuffer))

        #if DEBUG
        // Once per session: first enqueue + any renderer rejection, to distinguish "nothing enqueued" from
        // "renderer rejected our format".
        if !_loggedFirstEnqueue {
            _loggedFirstEnqueue = true
            let fmt = CMSampleBufferGetFormatDescription(sampleBuffer).flatMap {
                CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee
            }
            let sr = fmt.map { "\($0.mSampleRate)Hz" } ?? "?"
            let ch = fmt.map { "\($0.mChannelsPerFrame)ch" } ?? "?"
            let count = CMSampleBufferGetNumSamples(sampleBuffer)
            EngineLog.emit("[AudioOutput] first enqueue: \(sr) \(ch), \(count) samples, renderer.error=\(String(describing: renderer.error))", category: .swPlayback)
        } else if let err = renderer.error, !_loggedRendererError {
            _loggedRendererError = true
            EngineLog.emit("[AudioOutput] renderer error: \(err)", category: .swPlayback)
        }
        #endif
    }

    #if DEBUG
    private var _loggedFirstEnqueue = false
    private var _loggedRendererError = false
    #endif

    /// A copy of `sampleBuffer` shifted by the current offset, or the buffer itself when there is
    /// none (the overwhelmingly common case, and one that must not cost an allocation). A copy that
    /// cannot be made is delivered unshifted: an audible lip-sync error is a far better outcome than
    /// a dropped buffer, which is silence.
    private func retimed(_ sampleBuffer: CMSampleBuffer) -> CMSampleBuffer {
        lock.lock()
        let offset = presentationOffset
        lock.unlock()
        guard offset != .zero else { return sampleBuffer }
        let shifted = Self.retimed(sampleBuffer, by: offset)

        // Release-visible, once per offset change: an offset that was set and an offset that is being
        // DELIVERED are different claims, and without this line the difference is only measurable with
        // a capture card. The two timestamps are the whole proof.
        if !loggedOffsetInEffect, shifted !== sampleBuffer {
            loggedOffsetInEffect = true
            let source = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
            EngineLog.emit(
                "[AudioOutput] AE#464 audio delay in effect: "
                + String(format: "%+.0f ms", offset.seconds * 1000)
                + String(format: " (sample at %.3fs delivered at %.3fs)", source, source + offset.seconds),
                category: .swPlayback
            )
        }
        return shifted
    }

    /// The timing half, pure so the shift can be checked without a renderer. Every timing entry moves
    /// by `offset`, presentation and decode alike; an entry with no valid presentation stamp is left
    /// alone rather than given one.
    static func retimed(_ sampleBuffer: CMSampleBuffer, by offset: CMTime) -> CMSampleBuffer {
        guard offset != .zero else { return sampleBuffer }
        var count: CMItemCount = 0
        guard CMSampleBufferGetSampleTimingInfoArray(sampleBuffer,
                                                     entryCount: 0,
                                                     arrayToFill: nil,
                                                     entriesNeededOut: &count) == noErr,
              count > 0 else { return sampleBuffer }
        var timings = [CMSampleTimingInfo](repeating: .invalid, count: Int(count))
        guard CMSampleBufferGetSampleTimingInfoArray(sampleBuffer,
                                                     entryCount: count,
                                                     arrayToFill: &timings,
                                                     entriesNeededOut: nil) == noErr else {
            return sampleBuffer
        }
        for i in timings.indices where timings[i].presentationTimeStamp.isValid {
            timings[i].presentationTimeStamp = CMTimeAdd(timings[i].presentationTimeStamp, offset)
            if timings[i].decodeTimeStamp.isValid {
                timings[i].decodeTimeStamp = CMTimeAdd(timings[i].decodeTimeStamp, offset)
            }
        }
        var shifted: CMSampleBuffer?
        guard CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault,
                                                    sampleBuffer: sampleBuffer,
                                                    sampleTimingEntryCount: count,
                                                    sampleTimingArray: &timings,
                                                    sampleBufferOut: &shifted) == noErr,
              let shifted else { return sampleBuffer }
        return shifted
    }

    var currentTime: CMTime {
        synchronizer.currentTime()
    }

    var currentTimeSeconds: Double {
        let t = CMTimeGetSeconds(currentTime)
        return t.isFinite ? t : 0
    }

    /// Whether the audio renderer can accept more samples. The combined demux loop normally paces on the
    /// video renderer; in background-audio-only mode (video dropped) it paces on this instead, so it does
    /// not buffer the rest of the file unbounded.
    var isReadyForMoreMediaData: Bool {
        renderer.isReadyForMoreMediaData
    }

    /// Flush the audio renderer (call on seek).
    func flush() {
        lock.lock()
        defer { lock.unlock() }
        renderer.flush()
    }

    func stop() {
        lock.lock()
        defer { lock.unlock() }
        synchronizer.setRate(0.0, time: .zero)
        renderer.flush()
    }

    /// Atomically jump the master clock to a time and resume at a rate. The ONLY way the clock is (re)anchored:
    /// demux loops call it once on the first decoded packet, seek paths call it directly. Avoids the
    /// falling-through-time races that pause -> flush -> setRate would expose.
    func seekClock(to time: CMTime, rate: Float) {
        lock.lock()
        defer { lock.unlock() }
        EngineLog.emit("[AudioOutput] seekClock to=\(String(format: "%.3f", time.seconds)) rate=\(rate)", category: .swPlayback)
        synchronizer.setRate(rate, time: time)
    }
}
