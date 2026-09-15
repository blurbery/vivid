// SPDX-License-Identifier: GPL-3.0-only
// Additional permission: LICENSE-APPLE-EXCEPTION at the repository root.
#if os(tvOS)
import AVFoundation
import AVKit
import KSPlayer
import UIKit
import QuartzCore

/// Only adapts Vivid's selection and Match Content policy. Buffer defaults stay upstream.
final class LucidFFOptions: KSOptions {
    let matchContent: Bool
    private let audioIndex: Int32?
    private let audioOrdinal: Int?
    private let audioLanguages: [String]
    private let diagnostic: @Sendable (String, String) -> Void
    private let dolbyLock = NSLock()
    private var dolbyAttempt: (base: CMFormatDescription, native: CMFormatDescription, rate: Float)?
    private var dolbyConfigured = false
    private var dolbyFailed = false
    private let milestone: @Sendable (String, Double) -> Void
    @MainActor private var displayUpdatesActive = true
    @MainActor private var receivedDisplayUpdate = false
    @MainActor private var lastDisplayCriteria: AVDisplayCriteria?
    @MainActor private var lastDisplayRate: Float?
    @MainActor private var lastDisplayRange: Int?

    init(load: LoadOptions, start: Double, audioIndex: Int32?, milestone: @escaping @Sendable (String, Double) -> Void,
         diagnostic: @escaping @Sendable (String, String) -> Void) {
        matchContent = load.matchContentEnabled
        self.audioIndex = audioIndex
        audioOrdinal = load.audioTrackOrdinal
        audioLanguages = load.preferredAudioLanguages
        self.diagnostic = diagnostic
        self.milestone = milestone
        super.init()
        appendHeader(load.httpHeaders)
        startPlayTime = start
        videoDisable = load.audioOnly
        registerRemoteControll = false
        autoSelectEmbedSubtitle = false
        isSeekImageSubtitle = true
    }

    override func process(url: URL) -> AbstractAVIOContext? {
        // Public hook on the demux worker, immediately before avformat_open_input.
        milestone("source_open_begins", CACurrentMediaTime())
        return super.process(url: url)
    }

    override func process(assetTrack: some MediaPlayerTrack) {
        // Public hook after upstream chooses this stream, before track/decoder setup.
        let kind = assetTrack.mediaType == .video ? "video" : assetTrack.mediaType == .audio ? "audio" : "subtitle"
        milestone("\(kind)_stream_selected", CACurrentMediaTime())
        super.process(assetTrack: assetTrack)
        #if VIVID_P8_TRIAL
        if assetTrack.mediaType == .video {
            // Use KSPlayer's existing direct VideoToolbox decoder only for eligible P8.1.
            // Respect upstream software-decode requirements (rotation/deinterlacing/filters).
            let candidate = VividDolbyVideo(track: assetTrack).isNativeProfile81Candidate
            if #available(tvOS 17.0, *), candidate, hardwareDecode, videoFilters.isEmpty {
                asynchronousDecompression = true
            }
            if candidate {
                diagnostic("p8_decoder_selection", "hardware=\(hardwareDecode) direct_videotoolbox=\(asynchronousDecompression) filters=\(videoFilters.count)")
            }
        }
        #endif
        milestone("\(kind)_options_processed", CACurrentMediaTime())
        guard matchContent, assetTrack.mediaType == .video,
              let format = assetTrack.formatDescription else { return }
        // Preserve the trial's existing Dolby admission policy before changing the display.
        guard VividDolbyVideo(track: assetTrack).allowsBaselinePlayback else { return }
        #if VIVID_P8_TRIAL
        // The decoder callback requests P8 display criteria once configuration is accepted.
        if asynchronousDecompression, VividDolbyVideo(track: assetTrack).isNativeProfile81Candidate { return }
        #endif
        let rate = assetTrack.nominalFrameRate
        let isDovi = assetTrack.dovi != nil
        Task { @MainActor [weak self] in
            // A delayed probe callback must not override renderer metadata or a stopped load.
            guard let self, self.displayUpdatesActive, !self.receivedDisplayUpdate else { return }
            self.updateVideo(refreshRate: rate, isDovi: isDovi, formatDescription: format)
        }
    }

    override func wantedAudio(tracks: [MediaPlayerTrack]) -> Int? {
        if let audioIndex, let index = tracks.firstIndex(where: { $0.trackID == audioIndex }) { return index }
        if let audioOrdinal, tracks.indices.contains(audioOrdinal) { return audioOrdinal }
        for language in audioLanguages {
            if let index = tracks.firstIndex(where: { $0.languageCode?.lowercased() == language.lowercased() }) { return index }
        }
        return super.wantedAudio(tracks: tracks)
    }

    @MainActor
    func invalidateDisplayUpdates() {
        displayUpdatesActive = false
        lastDisplayCriteria = nil
    }

    @MainActor
    override func updateVideo(refreshRate: Float, isDovi: Bool, formatDescription: CMFormatDescription?) {
        guard displayUpdatesActive, matchContent, refreshRate.isFinite, refreshRate > 0,
              let formatDescription,
              let manager = UIApplication.shared.windows.first?.avDisplayManager,
              manager.isDisplayCriteriaMatchingEnabled else { return }
        receivedDisplayUpdate = true
        dolbyLock.lock()
        let native = dolbyConfigured ? dolbyAttempt?.native : nil
        dolbyLock.unlock()
        var range = formatDescription.dynamicRange
        // Match KSPlayer GPL's existing output policy, including its HDR10 DV fallback.
        if range == .dolbyVision { range = .hdr10 }
        let rangeValue = native == nil ? Int(range.rawValue) : Int(DynamicRange.dolbyVision.rawValue)
        if let previous = lastDisplayCriteria,
           manager.preferredDisplayCriteria === previous,
           lastDisplayRate == refreshRate, lastDisplayRange == rangeValue { return }
        milestone("display_criteria_begins", CACurrentMediaTime())
        if #available(tvOS 17.0, *), let native {
            manager.preferredDisplayCriteria = AVDisplayCriteria(refreshRate: refreshRate, formatDescription: native)
            diagnostic("p8_display_requested", "source=p8_1 actual_display_mode=unverified")
        } else {
            super.updateVideo(refreshRate: refreshRate, isDovi: isDovi, formatDescription: formatDescription)
        }
        lastDisplayCriteria = manager.preferredDisplayCriteria
        lastDisplayRate = refreshRate
        lastDisplayRange = rangeValue
        milestone("display_criteria_returned", CACurrentMediaTime())
    }
}

#if VIVID_P8_TRIAL
extension LucidFFOptions: KSVideoFormatDescriptionProvider {
    func videoDecompressionFormat(for track: FFmpegAssetTrack) -> CMFormatDescription? {
        dolbyLock.lock(); let failed = dolbyFailed; dolbyLock.unlock()
        guard !failed else { return nil }
        guard let native = VividDolbyVideo.profile81Format(track: track),
              let base = track.formatDescription else {
            if VividDolbyVideo(track: track).isNativeProfile81Candidate {
                diagnostic("p8_format_unavailable", "fallback=hdr10 reason=format_adapter_rejected")
            }
            return nil
        }
        dolbyLock.lock()
        dolbyAttempt = (base, native, track.nominalFrameRate)
        dolbyConfigured = false
        dolbyLock.unlock()
        diagnostic("p8_decoder_attempt", "profile=8 compatibility=1 atom=dvvC codec=hvc1 native_dv_verified=false")
        return native
    }

    func videoDecompressionFormatConfigured(_ format: CMFormatDescription?, status: OSStatus) {
        dolbyLock.lock()
        guard dolbyAttempt != nil, !dolbyFailed else { dolbyLock.unlock(); return }
        dolbyConfigured = format != nil && status == noErr
        dolbyFailed = !dolbyConfigured
        let attempt = dolbyAttempt
        let configured = dolbyConfigured
        dolbyLock.unlock()
        diagnostic("p8_decoder_configuration", "status=\(status) accepted=\(configured) fallback=\(!configured) native_dv_verified=false")
        guard let attempt else { return }
        Task { @MainActor [weak self] in
            self?.updateVideo(refreshRate: attempt.rate, isDovi: true, formatDescription: attempt.base)
        }
    }
}
#endif

/// A bounded await must also finish when upstream cancels or replaces a seek.
final class LucidSeekResult: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Bool?
    func complete(_ result: Bool) { lock.lock(); self.result = result; lock.unlock() }
    func read() -> Bool? { lock.lock(); defer { lock.unlock() }; return result }
}

/// Observes the PCM render callback without changing samples, clocking or channel selection.
/// This measures submission to Apple's audio engine, not sound at the receiver.
final class LucidRenderProbe: OutputRenderSourceDelegate {
    weak var source: OutputRenderSourceDelegate?
    private let lock = NSLock()
    private var first = true
    private var firstVideo = true
    private var firstAudio = true
    private let rendered: @Sendable (Double) -> Void
    private let available: @Sendable (String, Double) -> Void

    init(source: OutputRenderSourceDelegate, available: @escaping @Sendable (String, Double) -> Void,
         rendered: @escaping @Sendable (Double) -> Void) {
        self.source = source
        self.available = available
        self.rendered = rendered
    }

    func getVideoOutputRender(force: Bool) -> VideoVTBFrame? {
        let frame = source?.getVideoOutputRender(force: force)
        if frame != nil {
            lock.lock(); let report = firstVideo; firstVideo = false; lock.unlock()
            if report { available("first_decoded_video_retrieved", CACurrentMediaTime()) }
        }
        return frame
    }
    func getAudioOutputRender() -> AudioFrame? {
        let frame = source?.getAudioOutputRender()
        if frame != nil {
            lock.lock(); let report = firstAudio; firstAudio = false; lock.unlock()
            if report { available("first_decoded_audio_retrieved", CACurrentMediaTime()) }
        }
        return frame
    }
    func setVideo(time: CMTime, position: Int64) { source?.setVideo(time: time, position: position) }
    func setAudio(time: CMTime, position: Int64) {
        source?.setAudio(time: time, position: position)
        lock.lock()
        let report = first
        first = false
        lock.unlock()
        if report { rendered(CACurrentMediaTime()) }
    }
}
#endif
