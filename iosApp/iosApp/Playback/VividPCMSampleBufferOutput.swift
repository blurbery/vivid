// SPDX-License-Identifier: GPL-3.0-only
// Additional permission: LICENSE-APPLE-EXCEPTION at the repository root.
#if os(tvOS) && VIVID_ATMOS_TRIAL
import AVFoundation
import KSPlayer
import QuartzCore

// Scheduling reference: VideoLAN's modules/audio_output/apple/avsamplebuffer.m,
// particularly b0d5b12e07daa41b8d17d32107c11dad4e694cec (HomePod startup).
// Independently implemented adapter for KSPlayer's decoded PCM frame queue.
final class VividPCMSampleBufferOutput: AudioOutput {
    private let renderer = AVSampleBufferAudioRenderer()
    private let synchronizer = AVSampleBufferRenderSynchronizer()
    private let queue = DispatchQueue(label: "vivid.pcm.samplebuffer")
    private let queueKey = DispatchSpecificKey<Bool>()
    private var timer: DispatchSourceTimer?
    private var requesting = false
    private var playing = false
    private var anchored = false
    private var failed = false
    private var firstTime = CMTime.invalid
    private var queuedEnd = CMTime.invalid
    private var enqueuedFrames = 0
    private var peakSinceReport: Float = 0
    private weak var videoLayer: AVSampleBufferDisplayLayer?
    // Matches KSPlayer's normal forward buffer target. This is a ceiling,
    // not a minimum before starting playback.
    var maximumQueuedAudioDuration: Double = 3
    private var notifications: [NSObjectProtocol] = []
    private var diagnostic: (String, String) -> Void = { _, _ in }

    weak var renderSource: OutputRenderSourceDelegate?
    var playbackRate: Float = 1 {
        didSet { serial { if playing && anchored { synchronizer.rate = playbackRate } } }
    }
    var volume: Float = 1 { didSet { serial { renderer.volume = volume } } }
    var isMuted = false { didSet { serial { renderer.isMuted = isMuted } } }

    required init() {
        queue.setSpecific(key: queueKey, value: true)
        synchronizer.addRenderer(renderer)
        synchronizer.delaysRateChangeUntilHasSufficientMediaData = false
        renderer.allowedAudioSpatializationFormats = .monoStereoAndMultichannel
    }

    convenience init(diagnostic: @escaping (String, String) -> Void) {
        self.init()
        self.diagnostic = diagnostic
    }

    private func serial<T>(_ body: () -> T) -> T {
        if DispatchQueue.getSpecific(key: queueKey) == true { return body() }
        return queue.sync(execute: body)
    }

    func connectVideo(_ layer: AVSampleBufferDisplayLayer) -> Bool {
        serial {
            guard videoLayer !== layer else { return true }
            if let previous = videoLayer {
                previous.flushAndRemoveImage()
                synchronizer.removeRenderer(previous, at: .invalid, completionHandler: nil)
            }
            layer.flushAndRemoveImage()
            layer.controlTimebase = nil
            synchronizer.addRenderer(layer)
            videoLayer = layer
            diagnostic("audio_video_timeline_connected", "backend=pcm video=existing_ksplayer_layer clock=shared_apple_synchronizer timing=source_pts display_immediately=false")
            return true
        }
    }

    func resetVideoTimeline(to time: CMTime) {
        serial {
            // flush() already stopped audio and invalidated its anchor. This
            // only positions the paused timeline for the seek preview; the
            // first new audio sample still owns the playback anchor.
            guard !anchored, time.isNumeric, time >= .zero else { return }
            videoLayer?.flushAndRemoveImage()
            synchronizer.setRate(0, time: time)
        }
    }

    func videoAdmission(nextTime: Double, fps: Double) -> (gap: Double, enqueue: Bool)? {
        serial {
            guard anchored, videoLayer != nil, nextTime.isFinite, fps.isFinite, fps > 0 else { return nil }
            let gap = nextTime - synchronizer.currentTime().seconds
            // Feed two frames ahead so CoreMedia can meet each presentation
            // deadline. This replaces immediate display and host-clock polling
            // as the final scheduling authority, including at non-unit rates.
            return (gap, playing && !failed && gap <= 2 / fps)
        }
    }

    func prepare(audioFormat: AVAudioFormat) {
        let session = AVAudioSession.sharedInstance()
        let channels = min(Int(audioFormat.channelCount), session.maximumOutputNumberOfChannels)
        if channels > 0 { try? session.setPreferredOutputNumberOfChannels(channels) }
        serial {
            renderer.audioTimePitchAlgorithm = audioFormat.channelCount > 2 ? .spectral : .timeDomain
            diagnostic("audio_pcm_output", "backend=avsamplebuffer clock=apple_synchronizer startup=enqueue_then_start native_atmos=false")
            if notifications.isEmpty {
                notifications.append(NotificationCenter.default.addObserver(
                    forName: .AVSampleBufferAudioRendererWasFlushedAutomatically,
                    object: renderer, queue: nil
                ) { [weak self] _ in
                    self?.queue.async { [weak self] in self?.reportFailure("automatically_flushed") }
                })
            }
        }
    }

    func play() {
        serial {
            guard !playing, !failed else { return }
            playing = true
            if anchored { synchronizer.rate = playbackRate }
            startRequesting()
            pump()
            guard playing, !failed else { return }
            let ticker = DispatchSource.makeTimerSource(queue: queue)
            // KSPlayer's decoded queue can become nonempty without a renderer
            // readiness edge. Retry without blocking Apple's callback queue.
            ticker.schedule(deadline: .now(), repeating: .milliseconds(10), leeway: .milliseconds(2))
            ticker.setEventHandler { [weak self] in
                self?.pump()
                self?.reportClock()
            }
            timer = ticker
            ticker.resume()
        }
    }

    func pause() {
        serial {
            playing = false
            synchronizer.rate = 0
            stopRequesting()
            timer?.cancel()
            timer = nil
            // Preserve the anchor and queued samples for a true pause/resume.
        }
    }

    func flush() {
        serial {
            synchronizer.rate = 0
            stopRequesting()
            renderer.flush()
            anchored = false
            firstTime = .invalid
            queuedEnd = .invalid
            enqueuedFrames = 0
            // Do not pull here: seek completion owns the new decoded queue.
            // The next play/timer callback anchors to its first actual sample.
            if playing { startRequesting() }
        }
    }

    private func startRequesting() {
        guard !requesting, !failed else { return }
        requesting = true
        renderer.requestMediaDataWhenReady(on: queue) { [weak self] in self?.pump() }
    }

    private func stopRequesting() {
        renderer.stopRequestingMediaData()
        requesting = false
    }

    private func pump() {
        guard playing, !failed else { return }
        guard renderer.status != .failed else { reportFailure("renderer_failed"); return }
        // Bound each callback so pause/seek cannot starve behind a long stream.
        for _ in 0..<32 {
            if anchored, queuedEnd.isNumeric {
                let ahead = queuedEnd.seconds - synchronizer.currentTime().seconds
                if ahead >= maximumQueuedAudioDuration * Double(max(playbackRate, 1)) {
                    stopRequesting()
                    break
                }
            }
            guard renderer.isReadyForMoreMediaData else { break }
            guard let frame = renderSource?.getAudioOutputRender() else {
                // Avoid a hot readiness callback while the decoder is empty.
                stopRequesting()
                break
            }
            guard frame.compressedSampleBuffer == nil, frame.numberOfSamples > 0,
                  frame.audioFormat.sampleRate > 0, frame.timebase.den > 0, frame.timebase.num > 0 else {
                reportFailure("invalid_pcm_sample")
                return
            }
            // Use KSPlayer's public timebase fields, avoiding a temporary copy
            // of the entire audio buffer solely to retrieve its timestamp.
            let ticks = frame.timestamp.multipliedReportingOverflow(by: Int64(frame.timebase.num))
            guard !ticks.overflow else { reportFailure("invalid_pcm_timestamp"); return }
            let presentationTime = CMTime(value: ticks.partialValue, timescale: frame.timebase.den)
            guard [.pcmFormatFloat32, .pcmFormatInt16, .pcmFormatInt32].contains(frame.audioFormat.commonFormat),
                  let packed = VividPCMBufferPacking.make(format: frame.audioFormat, planes: frame.toFloat(),
                    frames: Int(frame.numberOfSamples), presentationTime: presentationTime) else {
                reportFailure("invalid_pcm_packing")
                return
            }
            renderer.enqueue(packed.sample)
            peakSinceReport = max(peakSinceReport, packed.peak)
            startRequesting()
            enqueuedFrames += 1
            queuedEnd = presentationTime + CMTime(seconds: Double(frame.numberOfSamples) / frame.audioFormat.sampleRate,
                                             preferredTimescale: 1_000_000_000)
            if !anchored {
                firstTime = presentationTime
                anchored = true
                // KSPlayer has already decided when playback may begin. Unlike
                // VLC's push interface it supplies no future host deadline.
                // Enqueue first, then start now at that sample's source PTS.
                synchronizer.setRate(playbackRate, time: firstTime)
                diagnostic("audio_pcm_anchor", "first_pts=\(firstTime.seconds) first_frame_enqueued=true rate=\(playbackRate) input_interleaved=\(frame.audioFormat.isInterleaved) output_interleaved=true channels=\(frame.audioFormat.channelCount) sample_rate=\(frame.audioFormat.sampleRate)")
                reportClock()
            }
        }
    }

    private func reportClock() {
        guard playing, anchored, !failed else { return }
        // Read time now, rather than anchoring a delayed observer argument at
        // delivery time. Carry the host timestamp through KSPlayer's handoff.
        let host = CACurrentMediaTime()
        let time = synchronizer.currentTime()
        renderSource?.setAudio(time: time, position: -1, sampledHostTime: host)
    }

    private func reportFailure(_ reason: String) {
        guard !failed else { return }
        failed = true
        pause()
        let error = renderer.error as NSError?
        diagnostic("audio_pcm_failed", "reason=\(reason) code=\(error?.code ?? 0)")
    }

    func reportStatus() {
        serial {
            diagnostic("audio_pcm_timing", "backend=avsamplebuffer status=\(renderer.status.rawValue) anchored=\(anchored) first_pts=\(firstTime.seconds) mapped_media_time=\(synchronizer.currentTime().seconds) queued_until=\(queuedEnd.seconds) enqueued_frames=\(enqueuedFrames) effective_rate=\(CMTimebaseGetEffectiveRate(synchronizer.timebase)) clock_policy=apple_synchronizer native_atmos=false")
            diagnostic("audio_pcm_signal", "packed_float32=true peak=\(peakSinceReport) volume=\(renderer.volume) muted=\(renderer.isMuted) route_latency_s=\(AVAudioSession.sharedInstance().outputLatency)")
            diagnostic("audio_pcm_queue", "ahead_s=\(queuedEnd.seconds - synchronizer.currentTime().seconds) limit_s=\(maximumQueuedAudioDuration * Double(max(playbackRate, 1))) video_connected=\(videoLayer != nil) presentation=source_pts")
            peakSinceReport = 0
        }
    }

    deinit {
        for notification in notifications { NotificationCenter.default.removeObserver(notification) }
        pause()
        serial {
            renderer.flush()
            if let videoLayer {
                videoLayer.flushAndRemoveImage()
                synchronizer.removeRenderer(videoLayer, at: .invalid, completionHandler: nil)
            }
        }
    }
}
#endif
