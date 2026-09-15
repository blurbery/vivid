// SPDX-License-Identifier: GPL-3.0-only
// Additional permission: LICENSE-APPLE-EXCEPTION at the repository root.
#if os(tvOS) && VIVID_ATMOS_TRIAL
import AVFoundation
import KSPlayer
import QuartzCore

/// JOC admission and packet adaptation only. KSPlayer retains queues and timing.
final class VividDolbyAudioBridge {
    private let lock = NSLock()
    private let samples = VividEAC3Sample()
    private let allowed: Bool
    private var selected: Int32?
    private var eligible = false
    private var failed = false
    private var firstPacket = true
    private var rate: Float = 1
    private let diagnostic: @Sendable (String, String) -> Void

    init(allowed: Bool, diagnostic: @escaping @Sendable (String, String) -> Void) {
        self.allowed = allowed
        self.diagnostic = diagnostic
    }

    var isNative: Bool {
        lock.lock(); defer { lock.unlock() }
        return allowed && eligible
    }

    func select(track: FFmpegAssetTrack, filtersEmpty: Bool) {
        lock.lock()
        // Select once at probe. A later profile discovery stays on PCM this session.
        if selected == nil {
            selected = track.trackID
            eligible = allowed && filtersEmpty && rate == 1 &&
                track.codecIdentifier == "eac3" && track.codecProfile == VividDolbyAudio.eac3JOCProfile
        }
        let native = eligible && !failed
        lock.unlock()
        event("audio_output_selected", "output=\(native ? "native_eac3_trial" : "decoded_pcm") native_atmos=unverified")
    }

    func setRate(_ value: Float) {
        lock.lock(); rate = value; let requiresFallback = eligible && value != 1; lock.unlock()
        if requiresFallback { fallback(reason: "playback_speed") }
    }

    func sample(track: FFmpegAssetTrack, bytes: UnsafeRawBufferPointer, time: CMTime) -> CMSampleBuffer? {
        lock.lock()
        guard allowed, eligible, !failed, selected == track.trackID,
              let asbd = track.audioStreamBasicDescription else { lock.unlock(); return nil }
        let sample = samples.make(bytes: bytes, presentationTime: time,
            sampleRate: Int(asbd.mSampleRate), channels: Int(asbd.mChannelsPerFrame))
        let report = sample != nil && firstPacket
        if report { firstPacket = false }
        lock.unlock()
        if sample == nil { fallback(reason: "unsupported_packet_or_format") }
        if report {
            event("audio_compressed_packet", "format=ec3 frames=1536 bytes=\(bytes.count) payload=unchanged pcm_decode=false native_atmos=unverified")
        }
        return sample
    }

    func fallback(reason: String) {
        lock.lock()
        let report = eligible && !failed
        if report { failed = true }
        lock.unlock()
        if report { event("audio_native_failed", "reason=\(reason) recovery=ksplayer_pcm_reload") }
    }

    func event(_ name: String, _ fields: String) { diagnostic(name, fields) }
}

/// Selects timestamped PCM or the opt-in compressed sample-buffer output per load.
/// Recovery creates a fresh PCM load, so the two outputs never share queued audio.
final class VividDolbyAudioOutput: AudioOutput {
    private let bridge: VividDolbyAudioBridge?
    private var output: AudioOutput?
    var maximumQueuedAudioDuration: Double = 3
    var usesPCMVideoTimeline: Bool { output is VividPCMSampleBufferOutput }
    func pcmVideoAdmission(nextTime: Double, fps: Double) -> (gap: Double, enqueue: Bool)? {
        (output as? VividPCMSampleBufferOutput)?.videoAdmission(nextTime: nextTime, fps: fps)
    }
    private weak var videoLayer: AVSampleBufferDisplayLayer?
    private var notifications: [NSObjectProtocol] = []
    private var playing = false
    private var pcmPresentationLatency: TimeInterval?
    private var watchStarted: Double = 0
    private var lastProgress: Double = 0
    private var lastTime: Double?
    private var lastPoll: Double = 0
    private var lastStatus: Int?
    private var lastReport: Double = 0
    private var reportedReady = false
    private var queueBlockedSince: Double?

    weak var renderSource: OutputRenderSourceDelegate? {
        didSet { output?.renderSource = renderSource }
    }
    var playbackRate: Float = 1 {
        didSet {
            bridge?.setRate(playbackRate)
            // Non-unit speed recovers to PCM before changing the native renderer's rate.
            if !(output is AudioRendererPlayer) || playbackRate == 1 { output?.playbackRate = playbackRate }
            Task { @MainActor [weak self] in self?.refreshPCMRouteTiming() }
        }
    }
    var volume: Float = 1 { didSet { output?.volume = volume } }
    var isMuted = false { didSet { output?.isMuted = isMuted } }

    required convenience init() { self.init(bridge: nil) }
    init(bridge: VividDolbyAudioBridge?) { self.bridge = bridge }

    func prepare(audioFormat: AVAudioFormat) {
        guard output == nil else { return }
        if bridge?.isNative == true {
            let native = AudioRendererPlayer()
            native.reanchorsAfterFlush = true
            // Let Apple establish a ready presentation timeline for the native route.
            // Ordinary KSPlayer PCM output keeps its existing start policy.
            native.synchronizer.delaysRateChangeUntilHasSufficientMediaData = true
            // Do not impose a PCM channel count on the compressed Apple audio route.
            output = native
            let centre = NotificationCenter.default
            for name in [Notification.Name.AVSampleBufferAudioRendererOutputConfigurationDidChange,
                         Notification.Name.AVSampleBufferAudioRendererWasFlushedAutomatically] {
                notifications.append(centre.addObserver(forName: name, object: native.renderer, queue: .main) { [weak self] note in
                    self?.bridge?.fallback(reason: note.name == Notification.Name.AVSampleBufferAudioRendererOutputConfigurationDidChange
                        ? "renderer_configuration_changed" : "renderer_automatically_flushed")
                })
            }
        } else {
            let pcm = VividPCMSampleBufferOutput { [weak bridge] name, fields in
                bridge?.event(name, fields)
            }
            pcm.maximumQueuedAudioDuration = maximumQueuedAudioDuration
            output = pcm
            pcm.prepare(audioFormat: audioFormat)
        }
        output?.renderSource = renderSource
        output?.playbackRate = playbackRate
        output?.volume = volume
        output?.isMuted = isMuted
    }

    @MainActor
    func synchroniseVideo(layer: AVSampleBufferDisplayLayer) -> Bool {
        if let pcm = output as? VividPCMSampleBufferOutput { return pcm.connectVideo(layer) }
        guard let native = output as? AudioRendererPlayer else { return false }
        if videoLayer !== layer {
            if let previous = videoLayer {
                previous.flushAndRemoveImage()
                native.synchronizer.removeRenderer(previous, at: .invalid, completionHandler: nil)
            }
            layer.controlTimebase = nil
            native.synchronizer.addRenderer(layer)
            videoLayer = layer
            bridge?.event("audio_video_timeline_connected", "video=existing_ksplayer_layer timing=source_pts display_immediately=false")
        }
        return true
    }

    @MainActor
    func resetTimeline(to time: CMTime) {
        if let pcm = output as? VividPCMSampleBufferOutput {
            pcm.resetVideoTimeline(to: time)
            return
        }
        guard let native = output as? AudioRendererPlayer else { return }
        native.resetTimeline(to: time)
        resetWatch()
        bridge?.event("audio_timeline_reset", "target=\(time.seconds) next_packet_anchor=true")
    }

    func play() {
        guard !playing, let output else { return }
        playing = true
        resetWatch()
        output.play()
        Task { @MainActor [weak self] in self?.refreshPCMRouteTiming() }
        if let native = output as? AudioRendererPlayer {
            bridge?.event("audio_timeline_play", "time=\(native.currentRenderTime.seconds) needs_anchor=\(native.needsAudioTimeAnchor)")
        }
    }
    func pause() {
        playing = false
        output?.pause()
        resetWatch()
    }
    func flush() {
        output?.flush()
        if Thread.isMainThread { resetWatch() }
        else { DispatchQueue.main.async { [weak self] in self?.resetWatch() } }
    }

    private func resetWatch() {
        watchStarted = CACurrentMediaTime()
        lastProgress = watchStarted
        lastTime = nil
        queueBlockedSince = nil
    }

    @MainActor
    func refreshPCMRouteTiming() {
        guard let pcm = output as? AudioEnginePlayer else { return }
        let ports = AVAudioSession.sharedInstance().currentRoute.outputs
        let airPlay = !ports.isEmpty && ports.allSatisfy { $0.portType == .airPlay }
        pcmPresentationLatency = pcm.updateSourcePresentationLatency(enabled: airPlay && playbackRate == 1)
    }

    /// Called by Vivid's existing telemetry ticker. A running timebase alone is not Atmos proof.
    @MainActor
    func poll() {
        guard playing else { return }
        let now = CACurrentMediaTime()
        guard now - lastPoll >= 1 else { return }
        lastPoll = now
        if let pcm = output as? VividPCMSampleBufferOutput {
            if now - lastReport >= 5 {
                lastReport = now
                pcm.reportStatus()
            }
            return
        }
        if let pcm = output as? AudioEnginePlayer {
            refreshPCMRouteTiming()
            if now - lastReport >= 5 {
                lastReport = now
                let session = AVAudioSession.sharedInstance()
                let timing = pcm.sourcePresentationTiming
                bridge?.event("audio_pcm_timing", "engine_running=\(pcm.engine.isRunning) route_latency_s=\(session.outputLatency) io_buffer_s=\(session.ioBufferDuration) output_node_latency_s=\(pcm.engine.outputNode.presentationLatency) source_presentation_latency_s=\(pcmPresentationLatency ?? -1) render_host_delay_s=\(timing?.hostDelay ?? -1) rendered_buffer_s=\(timing?.bufferDuration ?? -1) mapped_media_time=\(timing?.mediaTime ?? -1) clock_policy=\(timing != nil ? "airplay_render_host_time" : pcmPresentationLatency == nil ? "ksplayer_output_latency" : "source_latency_fallback") native_atmos=false")
            }
            return
        }
        guard let native = output as? AudioRendererPlayer else { return }
        if native.needsAudioTimeAnchor {
            // An empty post-seek queue must not start the renderer at zero or an old time.
            native.play()
            if !native.needsAudioTimeAnchor {
                resetWatch()
                bridge?.event("audio_timeline_anchored", "time=\(native.currentRenderTime.seconds)")
            } else if now - watchStarted > 8 {
                bridge?.fallback(reason: "audio_anchor_timeout")
            }
            return
        }
        let renderer = native.renderer
        if renderer.status == .failed {
            let error = renderer.error as NSError?
            bridge?.event("audio_renderer_error", "domain=\(error?.domain ?? "unknown") code=\(error?.code ?? 0)")
            bridge?.fallback(reason: "renderer_failed_\(error?.code ?? 0)")
            return
        }
        let time = native.currentRenderTime.seconds
        let effectiveRate = CMTimebaseGetEffectiveRate(native.synchronizer.timebase)
        if time.isFinite, lastTime == nil || time > (lastTime ?? time) + 0.01 {
            lastTime = time
            lastProgress = now
        }
        let ready = renderer.hasSufficientMediaDataForReliablePlaybackStart
        if lastStatus != renderer.status.rawValue || (!reportedReady && ready) || now - lastReport >= 5 {
            lastReport = now
            lastStatus = renderer.status.rawValue
            reportedReady = reportedReady || ready
            bridge?.event("audio_renderer_state", "status=\(renderer.status.rawValue) sufficient_data=\(ready) time=\(time) queued_until=\(native.enqueuedCompressedEndTime.seconds) video_connected=\(videoLayer.map { layer in native.synchronizer.renderers.contains { $0 === layer } } ?? false) synchronizer_rate=\(native.synchronizer.rate) effective_rate=\(effectiveRate) waits_for_readiness=\(native.synchronizer.delaysRateChangeUntilHasSufficientMediaData) route_latency_s=\(AVAudioSession.sharedInstance().outputLatency) io_buffer_s=\(AVAudioSession.sharedInstance().ioBufferDuration) native_atmos=unverified")
        }
        if effectiveRate == 0, native.synchronizer.rate > 0 {
            // A requested rate is not proof that Apple's timeline has started.
            // Bound readiness waiting so a renderer that cannot prime recovers to PCM.
            if now - watchStarted > 8 {
                bridge?.fallback(reason: "renderer_readiness_timeout")
            }
            return
        }
        let queuedEnd = native.enqueuedCompressedEndTime.seconds
        if queuedEnd.isFinite, time.isFinite, time > queuedEnd + 0.5 {
            if queueBlockedSince == nil { queueBlockedSince = now }
        } else { queueBlockedSince = nil }
        if let blocked = queueBlockedSince, now - blocked > 3 {
            bridge?.fallback(reason: "audio_queue_not_progressing")
        } else if now - watchStarted > 5, now - lastProgress > 3 {
            bridge?.fallback(reason: "audio_timeline_stopped")
        } else if now - watchStarted > 8, renderer.status == .unknown {
            bridge?.fallback(reason: "renderer_start_timeout")
        }
    }

    deinit {
        for notification in notifications { NotificationCenter.default.removeObserver(notification) }
        output?.pause()
        if let native = output as? AudioRendererPlayer, let videoLayer {
            native.synchronizer.removeRenderer(videoLayer, at: .invalid, completionHandler: nil)
        }
        output?.flush()
    }
}
#endif
