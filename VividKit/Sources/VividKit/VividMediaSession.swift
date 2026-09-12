// SPDX-License-Identifier: GPL-3.0-only
// Additional permission: LICENSE-APPLE-EXCEPTION at the repository root.
import AVFoundation
import CVividMedia
import Foundation

public struct VividTrack: Identifiable, Sendable {
    public enum Kind: Int32, Sendable { case video = 0, audio = 1, subtitle = 3 }
    public let id: Int
    public let kind: Kind
    public let name: String
    public let language: String
    public let codec: String
    public let isDefault: Bool
    public let isForced: Bool
    public let width: Int
    public let height: Int
    public let channels: Int
    public let bitrate: Int64
    public let frameRate: Double
    public let pixelAspectRatio: Double
    public let dynamicRange: String
    public let dolbyVisionProfile: Int?
}

final class VividMediaSession: @unchecked Sendable {
    #if os(tvOS)
    var nativeDTSBridgeEnabled = false
    private var audioEnqueueAhead: Double = 1
    private var audioReplay = VividAudioReplayBuffer()
    private var hdmiDiscardBefore: Double?
    private var hdmiCatchUpFloor: Double? {
        guard let hdmiDiscardBefore else { return nil }
        return VividHDMIAudioCore.catchUpFloor(
            recoveryFloor: hdmiDiscardBefore, clock: synchronizer.currentTime().seconds)
    }
    #if DEBUG
    private var hdmiProbeEnabled = false
    private var hdmiProbeLastWait: TimeInterval = -.infinity
    private var hdmiProbeWaitCount = 0
    private var hdmiProbeSampleCount = 0
    private var hdmiProbeLastSampleEnd: Double?

    func setHDMIProbeEnabled(_ enabled: Bool) {
        condition.lock(); defer { condition.unlock() }
        hdmiProbeEnabled = enabled && ProcessInfo.processInfo.arguments.contains("-VividTVProbe")
    }

    private func traceHDMIAudio(_ sample: CMSampleBuffer, pts: Double, duration: Double, waiting: Bool) {
        guard hdmiProbeEnabled else { return }
        let uptime = ProcessInfo.processInfo.systemUptime
        if waiting {
            guard hdmiProbeWaitCount < 24, uptime - hdmiProbeLastWait >= 2 else { return }
            hdmiProbeLastWait = uptime
            hdmiProbeWaitCount += 1
        } else {
            hdmiProbeSampleCount += 1
        }
        let actualPTS = CMSampleBufferGetPresentationTimeStamp(sample).seconds
        let actualDuration = CMSampleBufferGetDuration(sample).seconds
        let gap = hdmiProbeLastSampleEnd.map { actualPTS - $0 } ?? 0
        if !waiting { hdmiProbeLastSampleEnd = actualPTS + actualDuration }
        guard waiting || hdmiProbeSampleCount <= 3 else { return }
        let description = CMSampleBufferGetFormatDescription(sample)
        let asbd = description.flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0) }?.pointee
        let now = synchronizer.currentTime().seconds
        print("[VividTVProbe] hdmiAudioQueue event=\(waiting ? "wait" : "enqueue") clock=\(now) pts=\(pts) duration=\(duration) samplePTS=\(actualPTS) sampleDuration=\(actualDuration) sampleGap=\(gap) samples=\(CMSampleBufferGetNumSamples(sample)) sampleRate=\(asbd?.mSampleRate ?? 0) sampleChannels=\(asbd?.mChannelsPerFrame ?? 0) formatID=\(asbd?.mFormatID ?? 0) audioEnd=\(audioEnd ?? -1) ready=\(audio.isReadyForMoreMediaData) sufficient=\(audio.hasSufficientMediaDataForReliablePlaybackStart) status=\(audio.status.rawValue) errorCode=\((audio.error as NSError?)?.code ?? 0) enqueueAhead=\(audioEnqueueAhead) discardBefore=\(hdmiDiscardBefore ?? -1) native=\(nativeAudioFormat != nil)")
    }
    #endif

    func audioRecoveryState() -> (end: Double?, finished: Bool) {
        condition.lock(); defer { condition.unlock() }
        return (audioEnd, audioIndex == nil || audioDone)
    }

    func hdmiAudioState() -> (end: Double?, finished: Bool) {
        condition.lock(); defer { condition.unlock() }
        return (audioEnd, audioIndex == nil || audioDone)
    }

    func resetHDMIAudio(at time: Double) {
        condition.lock(); defer { condition.unlock() }
        guard !cancelled, audioIndex != nil, time.isFinite else { return }
        hdmiDiscardBefore = time
        audio.flush()
        audioReplay.removeAll()
        condition.broadcast()
    }

    func clearHDMIRecovery() {
        condition.lock(); defer { condition.unlock() }
        hdmiDiscardBefore = nil
    }

    func recoverAudioOutput() -> Bool {
        condition.lock(); defer { condition.unlock() }
        guard !cancelled, audioIndex != nil else { return false }
        let now = max(start, synchronizer.currentTime().seconds)
        guard now.isFinite else { return false }
        let samples = audioReplay.samples(at: now)
        guard !samples.isEmpty else { return false }
        // This lock also guards every enqueue, so no old buffer can slip
        // between the flush and the retained audio being re-enqueued.
        audio.flush()
        for sample in samples { audio.enqueue(sample) }
        condition.broadcast()
        return audio.status != .failed
    }
    func setAudioOutputLatency(_ latency: Double) {
        condition.lock()
        audioEnqueueAhead = latency.isFinite ? min(8, max(1, latency + 1)) : 1
        condition.broadcast()
        condition.unlock()
    }
    #endif
    struct Inventory { let tracks: [VividTrack]; let duration: Double; let audio: Int?; let chapters: [VividChapter] }
    struct Snapshot {
        let frontier: Double
        let readAheadSeconds: Double
        let end: Double
        let started: Bool
        let renderersFull: Bool
        let finished: Bool
        let hardware: Bool
        let nativeAudio: Bool
        let failure: VividPlaybackError?
        let subtitles: [VividSubtitleCue]
    }
    private let source: VividNetwork
    private let video: AVSampleBufferVideoRenderer
    private let audio: AVSampleBufferAudioRenderer
    private let synchronizer: AVSampleBufferRenderSynchronizer
    private var start: Double
    private let requestedAudio: Int?
    private let requestedAudioOrdinal: Int?
    private let audioOnly: Bool
    private let preferredAudioLanguages: [String]
    private let condition = NSCondition()
    private let demuxQueue = DispatchQueue(label: "com.blurbery.vivid.demux", qos: .userInitiated)
    private let videoPackets = VividBuffer(byteLimit: ProcessInfo.processInfo.physicalMemory > 3_500_000_000 ? 96 * 1024 * 1024 : 48 * 1024 * 1024)
    private let audioPackets = VividBuffer(byteLimit: 12 * 1024 * 1024)
    private var format: UnsafeMutablePointer<AVFormatContext>?
    private var demuxer: VividDemuxer?
    private var videoDecoder: UnsafeMutablePointer<AVCodecContext>?
    private var nativeAudioFormat: CMAudioFormatDescription?
    private let forceSoftwareAudio: Bool
    private var audioDecoder: UnsafeMutablePointer<AVCodecContext>?
    private var videoIndex: Int32?
    private var audioIndex: Int32?
    private var cancelled = false
    private var generation: UInt64 = 0
    private var failure: VividPlaybackError?
    #if os(tvOS)
    private var tvDisplayFormatDescription: CMVideoFormatDescription?
    var displayFormatDescription: CMVideoFormatDescription? {
        condition.lock(); defer { condition.unlock() }
        return tvDisplayFormatDescription
    }
    #endif
    private var videoEnd: Double?
    private var audioEnd: Double?
    private var videoDone = false
    private var audioDone = false
    private var hardware = false
    private var origin: Double = 0
    private var subtitleEngine = VividSubtitleEngine()
    private var selectedSubtitleIDs: Set<Int> = []
    private var subtitleCues: [VividSubtitleCue] = []

    init(source: VividNetwork, video: AVSampleBufferVideoRenderer, audio: AVSampleBufferAudioRenderer,
         synchronizer: AVSampleBufferRenderSynchronizer, start: Double, audioTrack: Int?, audioTrackOrdinal: Int?, audioOnly: Bool, preferredAudioLanguages: [String], forceSoftwareAudio: Bool) {
        self.source = source
        self.video = video
        self.audio = audio
        self.synchronizer = synchronizer
        self.start = start
        requestedAudio = audioTrack
        requestedAudioOrdinal = audioTrackOrdinal
        self.audioOnly = audioOnly
        self.forceSoftwareAudio = forceSoftwareAudio
        self.preferredAudioLanguages = preferredAudioLanguages
    }
    func open() async throws -> Inventory {
        try await withCheckedThrowingContinuation { continuation in
            demuxQueue.async { [self] in
                do { continuation.resume(returning: try prepare()) }
                catch { cleanup(); continuation.resume(throwing: error) }
            }
        }
    }
    private func prepare() throws -> Inventory {
        let demuxer = VividDemuxer(source: source)
        self.demuxer = demuxer
        try demuxer.open()
        guard let format = demuxer.format else { throw VividPlaybackError.invalidSource }
        self.format = format
        origin = vv_origin(format)
        let tracks = demuxer.tracks
        var result: Int32 = 0
        videoIndex = audioOnly ? nil : tracks.first(where: { $0.kind == .video }).map { Int32($0.id) }
        let audioTracks = tracks.filter { $0.kind == .audio }
        if let requestedAudio {
            guard audioTracks.contains(where: { $0.id == requestedAudio }) else { throw VividPlaybackError.unsupportedTrack }
            audioIndex = Int32(requestedAudio)
        } else if let ordinal = requestedAudioOrdinal {
            guard audioTracks.indices.contains(ordinal) else { throw VividPlaybackError.unsupportedTrack }
            audioIndex = Int32(audioTracks[ordinal].id)
        } else {
            let preferred = preferredAudioLanguages.lazy.compactMap { language in
                audioTracks.first { $0.language.caseInsensitiveCompare(language) == .orderedSame }
            }.first
            audioIndex = (preferred ?? audioTracks.first(where: \.isDefault) ?? audioTracks.first).map { Int32($0.id) }
        }
        #if os(tvOS)
        if nativeDTSBridgeEnabled, let audioIndex,
           let parameters = vv_stream(format, UInt32(audioIndex))?.pointee.codecpar,
           parameters.pointee.codec_id == AV_CODEC_ID_DTS {
            throw VividPlaybackError.nativeDTSRequired(Int(audioIndex))
        }
        #endif
        if let videoIndex {
            videoDecoder = vv_create_decoder(vv_stream(format, UInt32(videoIndex)), 1, &result)
            guard videoDecoder != nil else { throw source.lastFailure ?? VividPlaybackError.media(result) }
        }
        if let audioIndex, !forceSoftwareAudio,
           let stream = vv_stream(format, UInt32(audioIndex)), let parameters = stream.pointee.codecpar {
            nativeAudioFormat = vv_native_audio_format(parameters)?.takeRetainedValue()
        }
        if let audioIndex, nativeAudioFormat == nil {
            audioDecoder = vv_create_decoder(vv_stream(format, UInt32(audioIndex)), 0, &result)
            guard audioDecoder != nil else { throw source.lastFailure ?? VividPlaybackError.media(result) }
        }
        guard videoDecoder != nil || audioDecoder != nil || nativeAudioFormat != nil else { throw VividPlaybackError.unsupportedTrack }
        if start > 0 {
            guard start.isFinite, start < Double(Int64.max) / 1_000_000 - max(origin, 0) else { throw VividPlaybackError.invalidSource }
            result = avformat_seek_file(format, -1, Int64.min, Int64((start + origin) * 1_000_000), Int64.max, AVSEEK_FLAG_BACKWARD)
            guard result >= 0 else { throw source.lastFailure ?? VividPlaybackError.media(result) }
        }
        return Inventory(tracks: tracks,
            duration: format.pointee.duration == vv_no_pts() ? 0 : Double(format.pointee.duration) / 1_000_000,
            audio: audioIndex.map(Int.init), chapters: demuxer.inventory.chapters)
    }
    func run() {
        demuxQueue.async { [self] in
            guard let format else { return }
            condition.lock(); let epoch = generation; condition.unlock()
            guard !shouldStop(epoch) else { return }
            let workers = DispatchGroup()
            if let videoDecoder {
                workers.enter()
                DispatchQueue(label: "com.blurbery.vivid.video", qos: .userInitiated).async { [self] in
                    decode(videoDecoder, queue: videoPackets, isVideo: true, epoch: epoch); workers.leave()
                }
            }
            if let nativeAudioFormat {
                workers.enter()
                DispatchQueue(label: "com.blurbery.vivid.audio.native", qos: .userInitiated).async { [self] in
                    renderCompressedAudio(nativeAudioFormat, epoch: epoch); workers.leave()
                }
            } else if let audioDecoder {
                workers.enter()
                DispatchQueue(label: "com.blurbery.vivid.audio", qos: .userInitiated).async { [self] in
                    decode(audioDecoder, queue: audioPackets, isVideo: false, epoch: epoch); workers.leave()
                }
            }
            while !shouldStop(epoch) {
                guard let pointer = av_packet_alloc() else { fail(.media(-12)); break }
                let packet = VividPacket(pointer)
                let result = av_read_frame(format, pointer)
                if result < 0 {
                    let sourceFailure = source.lastFailure
                    if result == vv_eof(), sourceFailure == nil { break }
                    if !shouldStop(epoch) {
                        fail(VividPlaybackError.demuxReadFailure(result, sourceFailure: sourceFailure))
                    }
                    break
                }
                let index = pointer.pointee.stream_index
                guard packet.byteCount <= 32 * 1024 * 1024 else { fail(.media(-22)); break }
                if let stream = vv_stream(format, UInt32(index)) {
                    let pts = pointer.pointee.pts == vv_no_pts() ? pointer.pointee.dts : pointer.pointee.pts
                    packet.presentationTime = pts == vv_no_pts() ? nil : Double(pts) * vv_time(stream.pointee.time_base) - origin
                    packet.duration = max(0, Double(pointer.pointee.duration) * vv_time(stream.pointee.time_base))
                }
                if index == videoIndex { if !videoPackets.put(packet) { break } }
                else if index == audioIndex { if !audioPackets.put(packet) { break } }
                else {
                    condition.lock(); let selected = selectedSubtitleIDs.contains(Int(index)); condition.unlock()
                    if selected, let stream = vv_stream(format, UInt32(index)) {
                        let cues = subtitleEngine.decode(pointer, stream: stream, pts: packet.presentationTime ?? 0, origin: origin)
                        condition.lock()
                        if generation == epoch {
                            let cutoff = synchronizer.currentTime().seconds - 5
                            subtitleCues.removeAll { $0.end < cutoff }
                            VividSubtitleEngine.append(cues, to: &subtitleCues)
                            if subtitleCues.count > 512 { subtitleCues.removeFirst(subtitleCues.count - 512) }
                        }
                        condition.unlock()
                    }
                }
            }
            videoPackets.finish(); audioPackets.finish()
            workers.wait()
            if isCancelled { cleanup() }
        }
    }
    func seek(to seconds: Double) async throws {
        guard seconds.isFinite, seconds >= 0, seconds < Double(Int64.max) / 1_000_000 - max(origin, 0) else {
            throw VividPlaybackError.invalidSource
        }
        let epoch = interruptForSeek()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                demuxQueue.async { [self] in
                    guard !shouldStop(epoch), let format else {
                        continuation.resume(throwing: snapshot().failure.map { $0 as Error } ?? CancellationError()); return
                    }
                    source.resumeReads()
                    format.pointee.pb?.pointee.error = 0
                    format.pointee.pb?.pointee.eof_reached = 0
                    let code = avformat_seek_file(format, -1, Int64.min, Int64((seconds + origin) * 1_000_000), Int64.max, AVSEEK_FLAG_BACKWARD)
                    guard code >= 0, !shouldStop(epoch) else {
                        if !shouldStop(epoch) { fail(.media(code)) }
                        continuation.resume(throwing: shouldStop(epoch) ? VividPlaybackError.cancelled : .media(code))
                        return
                    }
                    if let videoDecoder { avcodec_flush_buffers(videoDecoder) }
                    if let audioDecoder { avcodec_flush_buffers(audioDecoder) }
                    subtitleEngine.flush()
                    let flushed = DispatchSemaphore(value: 0)
                    video.flush(removingDisplayedImage: false) { flushed.signal() }
                    guard flushed.wait(timeout: .now() + 5) == .success else {
                        fail(.renderer(-1)); continuation.resume(throwing: VividPlaybackError.renderer(-1)); return
                    }
                    audio.flush()
                    condition.lock()
                    guard !cancelled, generation == epoch else {
                        let error: Error = failure.map { $0 as Error } ?? CancellationError()
                        condition.unlock(); continuation.resume(throwing: error); return
                    }
                    start = seconds; videoEnd = nil; audioEnd = nil; subtitleCues = []
                    #if os(tvOS)
                    audioReplay.removeAll()
                    hdmiDiscardBefore = nil
                    #endif
                    videoDone = false; audioDone = false
                    condition.unlock()
                    videoPackets.reset(); audioPackets.reset()
                    run()
                    continuation.resume()
                }
            }
        } onCancel: { if !self.shouldStop(epoch) { self.cancel() } }
    }
    private func interruptForSeek() -> UInt64 {
        condition.lock(); generation &+= 1; let value = generation; condition.broadcast(); condition.unlock()
        source.interrupt(); videoPackets.cancel(); audioPackets.cancel()
        return value
    }
    func selectSubtitles(_ ids: Set<Int>) {
        condition.lock(); selectedSubtitleIDs = ids; subtitleCues = []; condition.unlock()
    }
    func cancel() {
        condition.lock(); cancelled = true
        #if os(tvOS)
        audioReplay.removeAll()
        #endif
        condition.broadcast(); condition.unlock()
        source.cancel(); videoPackets.cancel(); audioPackets.cancel()
        demuxQueue.async { [self] in cleanup() }
    }
    private func shouldStop(_ epoch: UInt64) -> Bool {
        condition.lock(); defer { condition.unlock() }
        return cancelled || epoch != generation
    }
    private var isCancelled: Bool {
        condition.lock(); defer { condition.unlock() }
        return cancelled
    }
    private func fail(_ error: VividPlaybackError, line: UInt = #line) {
        #if os(tvOS) && DEBUG
        if ProcessInfo.processInfo.arguments.contains("-VividTVProbe") {
            print("[VividTVProbe] mediaSessionFailure line=\(line) error=\(String(describing: error)) clock=\(synchronizer.currentTime().seconds) sourceFailure=\(String(describing: source.lastFailure))")
        }
        #endif
        condition.lock(); if failure == nil { failure = error }; condition.unlock()
        cancel()
    }
    func snapshot() -> Snapshot {
        condition.lock(); defer { condition.unlock() }
        let ends = [videoIndex == nil ? nil : videoEnd, audioIndex == nil ? nil : audioEnd].compactMap { $0 }
        let started = (videoIndex == nil || videoEnd != nil) && (audioIndex == nil || audioEnd != nil)
        let activeEnds = [videoIndex == nil || videoDone ? nil : videoEnd,
                          audioIndex == nil || audioDone ? nil : audioEnd].compactMap { $0 }
        let packetSpans = [videoIndex == nil || videoDone ? nil : videoPackets.bufferedSeconds,
                           audioIndex == nil || audioDone ? nil : audioPackets.bufferedSeconds].compactMap { $0 }
        return Snapshot(frontier: activeEnds.min() ?? ends.max() ?? start, readAheadSeconds: packetSpans.min() ?? 0, end: ends.max() ?? start,
            started: started, renderersFull: (videoIndex != nil && !video.isReadyForMoreMediaData) || (audioIndex != nil && !audio.isReadyForMoreMediaData), finished: (videoIndex == nil || videoDone) && (audioIndex == nil || audioDone),
            hardware: hardware, nativeAudio: nativeAudioFormat != nil, failure: failure, subtitles: subtitleCues + subtitleEngine.rendered(at: synchronizer.currentTime().seconds, selected: selectedSubtitleIDs))
    }
    func setBufferTarget(seconds: Double) {
        videoPackets.setTarget(seconds: seconds); audioPackets.setTarget(seconds: seconds)
    }
    func observeDelivery(headroom: Double, active: Bool) {
        source.observeDelivery(headroom: headroom, active: active)
    }
    func updateSourceHeaders(_ headers: [String: String]) -> Bool {
        source.updateHeaders(headers)
    }
    private func decode(_ decoder: UnsafeMutablePointer<AVCodecContext>, queue: VividBuffer, isVideo: Bool, epoch: UInt64) {
        guard let frame = av_frame_alloc() else { fail(.media(-12)); return }
        defer { var optional: UnsafeMutablePointer<AVFrame>? = frame; av_frame_free(&optional) }
        guard let converter = vv_converter_create() else { fail(.media(-12)); return }
        defer { var optional: OpaquePointer? = converter; vv_converter_free(&optional) }
        var nextTime: Double?
        while !shouldStop(epoch) {
            let packet = queue.take()
            if shouldStop(epoch) { return }
            var result = avcodec_send_packet(decoder, packet?.pointer)
            if result == vv_again() {
                drain(decoder, converter: converter, frame: frame, isVideo: isVideo, nextTime: &nextTime, epoch: epoch)
                result = avcodec_send_packet(decoder, packet?.pointer)
            }
            guard result >= 0 || result == vv_eof() else { fail(.media(result)); return }
            drain(decoder, converter: converter, frame: frame, isVideo: isVideo, nextTime: &nextTime, epoch: epoch)
            if packet == nil { break }
        }
        condition.lock()
        if epoch == generation { if isVideo { videoDone = true } else { audioDone = true } }
        condition.unlock()
    }
    private func drain(_ decoder: UnsafeMutablePointer<AVCodecContext>, converter: OpaquePointer, frame: UnsafeMutablePointer<AVFrame>,
                       isVideo: Bool, nextTime: inout Double?, epoch: UInt64) {
        while !shouldStop(epoch) {
            av_frame_unref(frame)
            let result = avcodec_receive_frame(decoder, frame)
            if result == vv_again() || result == vv_eof() { return }
            guard result >= 0 else { fail(.media(result)); return }
            let base = vv_time(decoder.pointee.pkt_timebase)
            let stamp = frame.pointee.best_effort_timestamp
            let decodedPTS = stamp == vv_no_pts() ? nil : Double(stamp) * base - origin
            let pts = isVideo
                ? (decodedPTS ?? nextTime)
                : Self.softwareAudioPresentationTime(
                    decoded: decodedPTS,
                    expected: nextTime,
                    sampleRate: Int(frame.pointee.sample_rate)
                )
            guard let pts, pts.isFinite else {
                fail(.media(-22)); return
            }
            let duration = isVideo ? max(Double(frame.pointee.duration) * base, 1.0 / 120.0) :
                Double(frame.pointee.nb_samples) / Double(max(1, frame.pointee.sample_rate))
            nextTime = pts + duration
            if pts + duration <= start { continue }
            var unmanaged: Unmanaged<CMSampleBuffer>?
            let timestamp = CMTime(seconds: pts, preferredTimescale: 1_000_000)
            let code = isVideo ? vv_make_video_sample(converter, frame, timestamp, CMTime(seconds: duration, preferredTimescale: 1_000_000), &unmanaged) :
                vv_make_audio_sample(converter, frame, timestamp, &unmanaged)
            guard code >= 0, let unmanaged else { fail(.media(code)); return }
            var sample = unmanaged.takeRetainedValue()
            if !isVideo && pts < start {
                let skip = min(CMSampleBufferGetNumSamples(sample), Int(ceil((start - pts) * Double(frame.pointee.sample_rate))))
                let count = CMSampleBufferGetNumSamples(sample) - skip
                if count <= 0 { continue }
                var trimmed: CMSampleBuffer?
                guard CMSampleBufferCopySampleBufferForRange(allocator: kCFAllocatorDefault, sampleBuffer: sample,
                    sampleRange: CFRange(location: skip, length: count), sampleBufferOut: &trimmed) == noErr,
                    let trimmed else { fail(.media(-22)); return }
                sample = trimmed
            }
            condition.lock()
            while !cancelled && generation == epoch {
                #if os(tvOS)
                if !isVideo, let floor = hdmiCatchUpFloor, pts + duration <= floor { break }
                #endif
                let ready = isVideo ? video.isReadyForMoreMediaData : audio.isReadyForMoreMediaData
                let now = synchronizer.currentTime().seconds
                #if os(tvOS)
                let enqueueAhead = isVideo ? 1 : audioEnqueueAhead
                #else
                let enqueueAhead: Double = 1
                #endif
                if ready && pts < max(start, now) + enqueueAhead { break }
                #if os(tvOS) && DEBUG
                if !isVideo { traceHDMIAudio(sample, pts: pts, duration: duration, waiting: true) }
                #endif
                _ = condition.wait(until: Date(timeIntervalSinceNow: 0.02))
            }
            guard !cancelled, generation == epoch else { condition.unlock(); return }
            #if os(tvOS)
            if !isVideo, let floor = hdmiCatchUpFloor, pts + duration <= floor {
                condition.unlock(); continue
            }
            #endif
            let rendererError: Error?
            if isVideo {
                #if os(tvOS)
                tvDisplayFormatDescription = CMSampleBufferGetFormatDescription(sample)
                #endif
                video.enqueue(sample)
                rendererError = video.status == .failed ? video.error : nil
                videoEnd = max(videoEnd ?? start, pts + duration)
                hardware = frame.pointee.format == AV_PIX_FMT_VIDEOTOOLBOX.rawValue
            } else {
                #if os(tvOS) && DEBUG
                traceHDMIAudio(sample, pts: pts, duration: duration, waiting: false)
                #endif
                #if os(tvOS)
                audioReplay.append(sample, at: synchronizer.currentTime().seconds)
                #endif
                audio.enqueue(sample)
                #if os(tvOS)
                if let floor = hdmiCatchUpFloor, pts >= floor {
                    hdmiDiscardBefore = nil
                }
                #endif
                rendererError = audio.status == .failed ? audio.error : nil
                audioEnd = max(audioEnd ?? start, pts + duration)
            }
            condition.unlock()
            if let rendererError { fail(.renderer((rendererError as NSError).code)); return }
        }
    }

    /// Millisecond container time bases cannot represent common DTS frame
    /// durations exactly. Feeding every rounded packet timestamp to CoreMedia
    /// creates tiny gaps/overlaps between otherwise continuous PCM buffers,
    /// heard as crackles. Preserve real forward gaps, but never feed the audio
    /// renderer a repeated/backward time and snap sub-2 ms forward rounding
    /// drift to the sample-accurate end of the previous decoded frame.
    static func softwareAudioPresentationTime(
        decoded: Double?,
        expected: Double?,
        sampleRate: Int
    ) -> Double? {
        guard let decoded else { return expected }
        guard let expected, sampleRate > 0 else { return decoded }
        let roundingTolerance = max(0.002, 2 / Double(sampleRate))
        return decoded <= expected + roundingTolerance ? expected : decoded
    }

    private func renderCompressedAudio(_ format: CMAudioFormatDescription, epoch: UInt64) {
        defer { condition.lock(); audioDone = true; condition.unlock() }
        #if os(tvOS) && DEBUG
        var probePackets = 0
        #endif
        while !shouldStop(epoch), let packet = audioPackets.take() {
            guard let pts = packet.presentationTime else { continue }
            let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)!.pointee
            let duration = packet.duration > 0 ? packet.duration : Double(asbd.mFramesPerPacket) / asbd.mSampleRate
            #if os(tvOS) && DEBUG
            if ProcessInfo.processInfo.arguments.contains("-VividTVProbe"), probePackets < 3, pts + duration > start {
                print("[VividTVProbe] packet pts=\(pts) duration=\(duration) framesPerPacket=\(asbd.mFramesPerPacket) sampleRate=\(asbd.mSampleRate) channels=\(asbd.mChannelsPerFrame) bytes=\(packet.byteCount)")
                probePackets += 1
            }
            #endif
            guard duration > 0, pts + duration > start else { continue }
            var unmanaged: Unmanaged<CMSampleBuffer>?
            let status = vv_make_audio_packet(format, packet.pointer,
                CMTime(seconds: pts, preferredTimescale: 1_000_000),
                CMTime(seconds: duration, preferredTimescale: 1_000_000), &unmanaged)
            guard status == 0, let sample = unmanaged?.takeRetainedValue() else { fail(.renderer(Int(status))); return }
            condition.lock()
            while !cancelled && generation == epoch {
                #if os(tvOS)
                if let floor = hdmiCatchUpFloor, pts + duration <= floor { break }
                let enqueueAhead = audioEnqueueAhead
                #else
                let enqueueAhead: Double = 1
                #endif
                if audio.isReadyForMoreMediaData && pts < max(start, synchronizer.currentTime().seconds) + enqueueAhead { break }
                #if os(tvOS) && DEBUG
                traceHDMIAudio(sample, pts: pts, duration: duration, waiting: true)
                #endif
                _ = condition.wait(until: Date(timeIntervalSinceNow: 0.02))
            }
            guard !cancelled, generation == epoch else { condition.unlock(); return }
            #if os(tvOS)
            if let floor = hdmiCatchUpFloor, pts + duration <= floor {
                condition.unlock(); continue
            }
            audioReplay.append(sample, at: synchronizer.currentTime().seconds)
            #endif
            #if os(tvOS) && DEBUG
            traceHDMIAudio(sample, pts: pts, duration: duration, waiting: false)
            #endif
            audio.enqueue(sample)
            #if os(tvOS)
            if let floor = hdmiCatchUpFloor, pts >= floor {
                hdmiDiscardBefore = nil
            }
            #endif
            audioEnd = max(audioEnd ?? start, pts + duration)
            let error = audio.status == .failed ? audio.error : nil
            condition.unlock()
            if let error { fail(.renderer((error as NSError).code)); return }
        }
    }
    private func cleanup() {
        avcodec_free_context(&videoDecoder); avcodec_free_context(&audioDecoder)
        format = nil; demuxer = nil; nativeAudioFormat = nil
        source.cancel()
    }
    deinit { cleanup() }
}

struct VividAudioReplayBuffer {
    private var retained: [CMSampleBuffer] = []
    private var byteCount = 0
    private let byteLimit: Int

    init(byteLimit: Int = 16 * 1024 * 1024) { self.byteLimit = max(1, byteLimit) }

    mutating func append(_ sample: CMSampleBuffer, at time: Double) {
        _ = samples(at: time)
        let size = CMSampleBufferGetTotalSampleSize(sample)
        guard size > 0, size <= byteLimit else { return }
        while !retained.isEmpty && (byteCount + size > byteLimit || retained.count >= 512) {
            byteCount -= CMSampleBufferGetTotalSampleSize(retained.removeFirst())
        }
        retained.append(sample); byteCount += size
    }

    mutating func samples(at time: Double) -> [CMSampleBuffer] {
        guard time.isFinite else { return [] }
        retained.removeAll { sample in
            let end = CMSampleBufferGetPresentationTimeStamp(sample).seconds + CMSampleBufferGetDuration(sample).seconds
            guard !end.isFinite || end <= time else { return false }
            byteCount -= CMSampleBufferGetTotalSampleSize(sample)
            return true
        }
        return retained
    }

    mutating func removeAll() { retained.removeAll(); byteCount = 0 }
}
