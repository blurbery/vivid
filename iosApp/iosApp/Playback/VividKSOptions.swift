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

    init(load: LoadOptions, start: Double, audioIndex: Int32?) {
        matchContent = load.matchContentEnabled
        self.audioIndex = audioIndex
        audioOrdinal = load.audioTrackOrdinal
        audioLanguages = load.preferredAudioLanguages
        super.init()
        appendHeader(load.httpHeaders)
        startPlayTime = start
        videoDisable = load.audioOnly
        registerRemoteControll = false
        autoSelectEmbedSubtitle = false
        isSeekImageSubtitle = true
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
    private let rendered: @Sendable (Double) -> Void

    init(source: OutputRenderSourceDelegate, rendered: @escaping @Sendable (Double) -> Void) {
        self.source = source
        self.rendered = rendered
    }

    func getVideoOutputRender(force: Bool) -> VideoVTBFrame? { source?.getVideoOutputRender(force: force) }
    func getAudioOutputRender() -> AudioFrame? { source?.getAudioOutputRender() }
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
