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
    #if VIVID_ATMOS_TRIAL
    let dolbyAudio: VividDolbyAudioBridge
    private weak var dolbyAudioOutput: VividDolbyAudioOutput?
    #endif
    let matchContent: Bool
    private let audioIndex: Int32?
    private let audioOrdinal: Int?
    private let audioLanguages: [String]
    private let diagnostic: @Sendable (String, String) -> Void
    private let audioProfileLock = NSLock()
    private var audioProfiles: [Int32: VividDolbyAudio] = [:]
    private let dolbyLock = NSLock()
    private var dolbyAttempt: (base: CMFormatDescription, native: CMFormatDescription, rate: Float, profile: UInt8)?
    private var dolbyConfigured = false
    private var dolbyFailed = false
    private var requiresNativeP5 = false
    private var p5TrialEligible = false
    private var p5VideoGateInstalled = false
    private let milestone: @Sendable (String, Double) -> Void
    @MainActor private var displayUpdatesActive = true
    @MainActor private var receivedDisplayUpdate = false
    @MainActor private var lastDisplayCriteria: AVDisplayCriteria?
    @MainActor private var lastDisplayRate: Float?
    @MainActor private var lastDisplayRange: Int?

    init(load: LoadOptions, start: Double, audioIndex: Int32?, nativeAudioAllowed: Bool = true, milestone: @escaping @Sendable (String, Double) -> Void,
         diagnostic: @escaping @Sendable (String, String) -> Void) {
        #if VIVID_ATMOS_TRIAL
        dolbyAudio = VividDolbyAudioBridge(allowed: nativeAudioAllowed, diagnostic: diagnostic)
        #endif
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

    override func videoClockSync(main: KSClock, nextVideoTime: TimeInterval, fps: Double,
                                 frameCount: Int) -> (Double, ClockProcessType) {
        let result = super.videoClockSync(main: main, nextVideoTime: nextVideoTime,
                                         fps: fps, frameCount: frameCount)
        #if VIVID_ATMOS_TRIAL
        // Keep the upstream audio clock and correction actions. AirPlay PCM should not
        // remain nearly four frames late when decoded frames are available to catch up.
        if !dolbyAudio.isNative, fps.isFinite, fps > 0, result.0.isFinite,
           result.0 < -2 / fps, frameCount > 1, case .next = result.1 {
            let ports = AVAudioSession.sharedInstance().currentRoute.outputs
            if !ports.isEmpty, ports.allSatisfy({ $0.portType == .airPlay }) {
                return (result.0, .dropNextFrame)
            }
        }
        #endif
        return result
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
        #if VIVID_ATMOS_TRIAL
        if assetTrack.mediaType == .audio, let track = assetTrack as? FFmpegAssetTrack {
            recordAudioProfile(trackID: track.trackID, codecName: track.codecIdentifier,
                               profile: track.codecProfile, evidence: .streamProfile, reset: true)
            dolbyAudio.select(track: track, filtersEmpty: audioFilters.isEmpty)
        }
        #endif
        #if VIVID_P8_TRIAL
        if assetTrack.mediaType == .video {
            // Use KSPlayer's existing direct VideoToolbox decoder only for eligible P8.1.
            // Respect upstream software-decode requirements (rotation/deinterlacing/filters).
            let metadata = VividDolbyVideo(track: assetTrack)
            var candidate = metadata.isNativeProfile81Candidate
            var prefix = "p8"
            #if VIVID_P5_TRIAL
            dolbyLock.lock()
            requiresNativeP5 = metadata.profile == 5
            p5TrialEligible = metadata.isNativeProfile5Candidate && hardwareDecode &&
                videoFilters.isEmpty && p5VideoGateInstalled
            let p5Eligible = p5TrialEligible
            dolbyLock.unlock()
            if metadata.profile == 5 {
                candidate = p5Eligible
                prefix = "p5"
            }
            #endif
            if #available(tvOS 17.0, *), candidate, hardwareDecode, videoFilters.isEmpty {
                asynchronousDecompression = true
            }
            if candidate {
                diagnostic("\(prefix)_decoder_selection", "hardware=\(hardwareDecode) direct_videotoolbox=\(asynchronousDecompression) filters=\(videoFilters.count)")
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

    func audioClassification(trackID: Int32) -> VividDolbyAudio? {
        audioProfileLock.lock(); defer { audioProfileLock.unlock() }
        return audioProfiles[trackID]
    }

    private func recordAudioProfile(trackID: Int32, codecName: String, profile: Int32,
                                    evidence: VividDolbyAudio.Evidence, reset: Bool = false) {
        let detected = VividDolbyAudio(codec: codecName, profile: profile == -99 ? nil : profile, evidence: evidence)
        audioProfileLock.lock()
        let classification = detected.retainingJOC(from: reset ? nil : audioProfiles[trackID])
        audioProfiles[trackID] = classification
        audioProfileLock.unlock()
        diagnostic("audio_classified", "track=\(trackID) " + classification.diagnosticFields)
    }

    func installP5VideoGate() {
        dolbyLock.lock(); p5VideoGateInstalled = true; dolbyLock.unlock()
    }

    var allowsNativeP5Trial: Bool {
        dolbyLock.lock(); defer { dolbyLock.unlock() }
        return p5TrialEligible && !dolbyFailed
    }

    var allowsVideoPresentation: Bool {
        dolbyLock.lock(); defer { dolbyLock.unlock() }
        return !requiresNativeP5 || (dolbyConfigured && !dolbyFailed && p5VideoGateInstalled)
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
        let profile = dolbyAttempt?.profile
        let rejectBase = requiresNativeP5 && native == nil
        dolbyLock.unlock()
        guard !rejectBase else { return }
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
            diagnostic(profile == 5 ? "p5_display_requested" : "p8_display_requested", "source_profile=\(profile ?? 0) actual_display_mode=unverified")
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
        let metadata = VividDolbyVideo(track: track)
        var proposed = VividDolbyVideo.profile81Format(track: track)
        #if VIVID_P5_TRIAL
        if metadata.profile == 5, allowsNativeP5Trial {
            proposed = VividDolbyVideo.profile5Format(track: track)
        }
        #endif
        guard let native = proposed, let base = track.formatDescription else {
            if metadata.profile == 5 {
                dolbyLock.lock(); dolbyFailed = true; dolbyLock.unlock()
                diagnostic("p5_native_failed", "reason=format_adapter_rejected presentation=blocked")
            } else if metadata.isNativeProfile81Candidate {
                diagnostic("p8_format_unavailable", "fallback=hdr10 reason=format_adapter_rejected")
            }
            return nil
        }
        dolbyLock.lock()
        dolbyAttempt = (base, native, track.nominalFrameRate, metadata.profile ?? 0)
        dolbyConfigured = false
        dolbyLock.unlock()
        diagnostic(metadata.profile == 5 ? "p5_decoder_attempt" : "p8_decoder_attempt",
                   "profile=\(metadata.profile ?? 0) compatibility=\(metadata.compatibility ?? 0) native_dv_verified=false")
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
        guard let attempt else { return }
        let isP5 = attempt.profile == 5
        diagnostic(isP5 ? "p5_decoder_configuration" : "p8_decoder_configuration",
                   "status=\(status) accepted=\(configured) fallback=\(!configured && !isP5) native_dv_verified=false")
        if isP5 && !configured {
            diagnostic("p5_native_failed", "reason=decoder_rejected status=\(status) presentation=blocked")
            return
        }
        Task { @MainActor [weak self] in
            self?.updateVideo(refreshRate: attempt.rate, isDovi: true, formatDescription: attempt.base)
        }
    }
}
#endif

#if VIVID_ATMOS_TRIAL
extension LucidFFOptions: KSAudioProfileObserver {
    func didDecodeAudioProfile(trackID: Int32, codecName: String, profile: Int32) {
        recordAudioProfile(trackID: trackID, codecName: codecName, profile: profile, evidence: .decodedProfile)
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
    private let allowsVideo: @Sendable () -> Bool
    private let rendered: @Sendable (Double) -> Void
    private let available: @Sendable (String, Double) -> Void

    init(source: OutputRenderSourceDelegate, allowsVideo: @escaping @Sendable () -> Bool,
         available: @escaping @Sendable (String, Double) -> Void,
         rendered: @escaping @Sendable (Double) -> Void) {
        self.source = source
        self.allowsVideo = allowsVideo
        self.available = available
        self.rendered = rendered
    }

    func getVideoOutputRender(force: Bool) -> VideoVTBFrame? {
        guard allowsVideo() else { return nil }
        let frame = source?.getVideoOutputRender(force: force)
        guard allowsVideo() else { return nil }
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
            if report {
                #if VIVID_ATMOS_TRIAL
                let event = frame?.compressedSampleBuffer == nil
                    ? "first_decoded_audio_retrieved" : "first_compressed_audio_retrieved"
                #else
                let event = "first_decoded_audio_retrieved"
                #endif
                available(event, CACurrentMediaTime())
            }
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

#if os(tvOS) && VIVID_ATMOS_TRIAL
extension LucidFFOptions: KSAudioPacketProvider {
    func makeAudioOutput() -> AudioOutput {
        let output = VividDolbyAudioOutput(bridge: dolbyAudio)
        dolbyAudioOutput = output
        return output
    }
    func audioSampleBuffer(for track: FFmpegAssetTrack, bytes: UnsafeRawBufferPointer,
                           presentationTime: CMTime) -> CMSampleBuffer? {
        dolbyAudio.sample(track: track, bytes: bytes, time: presentationTime)
    }
}
#endif

#if os(tvOS) && VIVID_ATMOS_TRIAL
extension LucidFFOptions: KSVideoPresentationTimebaseProvider {
    var usesSynchronizedVideoTiming: Bool { dolbyAudio.isNative }
    @MainActor func prepareVideoPresentation(layer: AVSampleBufferDisplayLayer) -> Bool {
        dolbyAudioOutput?.synchroniseVideo(layer: layer) ?? false
    }
    @MainActor func resetVideoPresentationTime(to time: CMTime) {
        dolbyAudioOutput?.resetTimeline(to: time)
    }
}
#endif
