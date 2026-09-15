// SPDX-License-Identifier: GPL-3.0-only
// Additional permission: LICENSE-APPLE-EXCEPTION at the repository root.
#if os(tvOS) && VIVID_ATMOS_TRIAL
import AVFoundation
import KSPlayer
import QuartzCore
import MediaPlayer

// Native E-AC-3 trial. Keeps compressed packets intact and uses the same
// bounded, shared-timeline lifecycle as the separately retained PCM output.
final class VividNativeEAC3Output: AudioOutput {
    let renderer = AVSampleBufferAudioRenderer()
    let synchronizer = AVSampleBufferRenderSynchronizer()
    private let queue = DispatchQueue(label: "vivid.eac3.samplebuffer")
    private let queueKey = DispatchSpecificKey<Bool>()
    private var timer: DispatchSourceTimer?
    private var requesting = false
    private var playing = false
    private var anchored = false
    private var failed = false
    private var firstTime = CMTime.invalid
    private var queuedEnd = CMTime.invalid
    private var enqueuedFrames = 0
    private weak var videoLayer: AVSampleBufferDisplayLayer?
    // Matches KSPlayer's normal forward buffer target. This is a ceiling,
    // not a minimum before starting playback.
    var maximumQueuedAudioDuration: Double = 3
    private var notifications: [NSObjectProtocol] = []
    private var previousMultichannelSupport: Bool?
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

    var currentRenderTime: CMTime { serial { synchronizer.currentTime() } }
    var enqueuedCompressedEndTime: CMTime { serial { queuedEnd } }
    var needsAudioTimeAnchor: Bool { serial { !anchored } }

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
            diagnostic("audio_video_timeline_connected", "backend=native_eac3 video=existing_ksplayer_layer clock=shared_apple_synchronizer timing=source_pts display_immediately=false")
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
        // Apple decodes the compressed stream for the active route. Do not
        // force the decoded PCM channel count onto its native output.
        serial {
            let session = AVAudioSession.sharedInstance()
            if previousMultichannelSupport == nil {
                let previous = session.supportsMultichannelContent
                do {
                    // Content capability is independent of whether the route
                    // currently advertises spatial playback as enabled.
                    try session.setSupportsMultichannelContent(true)
                    previousMultichannelSupport = previous
                    diagnostic("audio_native_content", "multichannel=true previous=\(previous)")
                } catch {
                    diagnostic("audio_native_content", "declaration_failed=true")
                }
            }
            diagnostic("audio_native_output", "backend=avsamplebuffer clock=shared_apple_synchronizer startup=enqueue_then_start native_atmos=unverified")
            if notifications.isEmpty {
                for name in [Notification.Name.AVSampleBufferAudioRendererWasFlushedAutomatically,
                             Notification.Name.AVSampleBufferAudioRendererOutputConfigurationDidChange] {
                    notifications.append(NotificationCenter.default.addObserver(
                        forName: name, object: renderer, queue: nil
                    ) { [weak self] note in
                        let reason = note.name == .AVSampleBufferAudioRendererWasFlushedAutomatically
                            ? "automatically_flushed" : "output_configuration_changed"
                        self?.queue.async { [weak self] in self?.reportFailure(reason) }
                    })
                }
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
            guard let sample = frame.compressedSampleBuffer,
                  let format = CMSampleBufferGetFormatDescription(sample),
                  CMFormatDescriptionGetMediaSubType(format) == kAudioFormatEnhancedAC3 else {
                reportFailure("invalid_compressed_sample")
                return
            }
            let presentationTime = CMSampleBufferGetPresentationTimeStamp(sample)
            let duration = CMSampleBufferGetDuration(sample)
            guard presentationTime.isNumeric, duration.isNumeric, duration > .zero else {
                reportFailure("invalid_compressed_timestamp")
                return
            }
            // The packet adapter already validates the EC-3 frame layout.
            // Enqueue its original bytes, format and timestamp without decoding.
            renderer.enqueue(sample)
            startRequesting()
            enqueuedFrames += 1
            queuedEnd = presentationTime + duration
            if !anchored {
                firstTime = presentationTime
                anchored = true
                // KSPlayer has already decided when playback may begin. Unlike
                // VLC's push interface it supplies no future host deadline.
                // Enqueue first, then start now at that sample's source PTS.
                synchronizer.setRate(playbackRate, time: firstTime)
                diagnostic("audio_native_anchor", "first_pts=\(firstTime.seconds) first_frame_enqueued=true rate=\(playbackRate) payload=unchanged")
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
        diagnostic("audio_native_output_failed", "reason=\(reason) code=\(error?.code ?? 0)")
    }

    func reportStatus() {
        serial {
            let session = AVAudioSession.sharedInstance()
            var resolved = "unavailable"
            var layouts = "unavailable"
            if #available(tvOS 17.2, *) {
                resolved = String(session.renderingMode.rawValue)
                layouts = session.supportedOutputChannelLayouts.map {
                    String($0.layoutTag)
                }.joined(separator: ",")
            }
            let info = MPNowPlayingInfoCenter.default().nowPlayingInfo
            let nowPlayingRate = (info?[MPNowPlayingInfoPropertyPlaybackRate] as? NSNumber)?.doubleValue ?? -1
            diagnostic("audio_native_session", "category=\(session.category.rawValue) mode=\(session.mode.rawValue) policy=\(session.routeSharingPolicy.rawValue) multichannel=\(session.supportsMultichannelContent) spatial_enabled=\(session.currentRoute.outputs.contains { $0.isSpatialAudioEnabled }) now_playing_keys=\(info?.count ?? 0) now_playing_rate=\(nowPlayingRate) output_channels=\(session.outputNumberOfChannels)")
            diagnostic("audio_native_queue", "ahead_s=\(queuedEnd.seconds - synchronizer.currentTime().seconds) limit_s=\(maximumQueuedAudioDuration) video_connected=\(videoLayer != nil) presentation=source_pts")
            diagnostic("audio_native_rendering", "resolved_mode=\(resolved) atmos_mode_value=5 supported_layouts=\(layouts) route=\(session.currentRoute.outputs.map { $0.portType.rawValue }.joined(separator: ",")) volume=\(renderer.volume) muted=\(renderer.isMuted)")
        }
    }

    deinit {
        for notification in notifications { NotificationCenter.default.removeObserver(notification) }
        pause()
        serial {
            renderer.flush()
            if let previousMultichannelSupport {
                let session = AVAudioSession.sharedInstance()
                if session.supportsMultichannelContent {
                    try? session.setSupportsMultichannelContent(previousMultichannelSupport)
                }
            }
            if let videoLayer {
                videoLayer.flushAndRemoveImage()
                synchronizer.removeRenderer(videoLayer, at: .invalid, completionHandler: nil)
            }
        }
    }
}
#endif
