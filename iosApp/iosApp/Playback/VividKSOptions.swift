// SPDX-License-Identifier: GPL-3.0-only
// Additional permission: LICENSE-APPLE-EXCEPTION at the repository root.
#if os(tvOS)
import AVFoundation
import AVKit
import KSPlayer
import UIKit
import QuartzCore

/// Only adapts Vivid's selection and Match Content policy. Buffer defaults stay upstream.
final class VividKSOptions: KSOptions {
    let matchContent: Bool
    private let audioIndex: Int32?
    private let audioOrdinal: Int?
    private let audioLanguages: [String]
    private let milestone: @Sendable (String, Double) -> Void

    init(load: LoadOptions, start: Double, audioIndex: Int32?, milestone: @escaping @Sendable (String, Double) -> Void) {
        matchContent = load.matchContentEnabled
        self.audioIndex = audioIndex
        audioOrdinal = load.audioTrackOrdinal
        audioLanguages = load.preferredAudioLanguages
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

    override func wantedAudio(tracks: [MediaPlayerTrack]) -> Int? {
        if let audioIndex, let index = tracks.firstIndex(where: { $0.trackID == audioIndex }) { return index }
        if let audioOrdinal, tracks.indices.contains(audioOrdinal) { return audioOrdinal }
        for language in audioLanguages {
            if let index = tracks.firstIndex(where: { $0.languageCode?.lowercased() == language.lowercased() }) { return index }
        }
        return super.wantedAudio(tracks: tracks)
    }

    @MainActor
    override func updateVideo(refreshRate: Float, isDovi: Bool, formatDescription: CMFormatDescription?) {
        guard matchContent else { return }
        super.updateVideo(refreshRate: refreshRate, isDovi: isDovi, formatDescription: formatDescription)
    }
}

/// A bounded await must also finish when upstream cancels or replaces a seek.
final class VividKSSeekResult: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Bool?
    func complete(_ result: Bool) { lock.lock(); self.result = result; lock.unlock() }
    func read() -> Bool? { lock.lock(); defer { lock.unlock() }; return result }
}

/// Observes the PCM render callback without changing samples, clocking or channel selection.
/// This measures submission to Apple's audio engine, not sound at the receiver.
final class VividKSAudioProbe: OutputRenderSourceDelegate {
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
