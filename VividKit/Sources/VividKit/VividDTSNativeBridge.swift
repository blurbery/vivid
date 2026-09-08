// SPDX-License-Identifier: Apache-2.0
#if os(tvOS)
import AVFoundation
import CVividMedia
import Foundation

public final class VividDTSNativeBridge: @unchecked Sendable {
    public let directory: URL
    private let source: VividSource
    private let selectedAudio: Int
    private let requestedTime: Double
    private let condition = NSCondition()
    private var network: VividNetwork?
    private var stopped = false
    private var playhead: Double
    private var failure: Error?
    private var ready = false
    private var workerActive = false
    private var offset: Double = 0
    private var mediaInventory: VividMediaInventory?
    private var server: VividDTSLoopbackServer?
    private var subtitleDecoder = VividSubtitleEngine()
    private var cues: [VividSubtitleCue] = []
    private var selectedSubtitles: Set<Int> = []

    public var timelineOffset: Double { condition.lock(); defer { condition.unlock() }; return offset }
    public var inventory: VividMediaInventory? { condition.lock(); defer { condition.unlock() }; return mediaInventory }
    public var error: Error? { condition.lock(); defer { condition.unlock() }; return failure }

    public init(source: VividSource, audioTrack: Int, at seconds: Double) throws {
        guard seconds.isFinite, seconds >= 0 else { throw VividPlaybackError.invalidSource }
        self.source = source; selectedAudio = audioTrack; requestedTime = seconds; playhead = seconds
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("vivid-dts-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    }

    public func start() async throws -> URL {
        let server = try VividDTSLoopbackServer(directory: directory)
        self.server = server
        let url: URL
        do { url = try await server.start() }
        catch { stop(); throw error }
        condition.withLock { workerActive = true }
        DispatchQueue(label: "com.blurbery.vivid.dts.bridge", qos: .userInitiated).async { [self] in
            defer {
                condition.lock(); workerActive = false; let remove = stopped; condition.unlock()
                if remove { try? FileManager.default.removeItem(at: directory) }
            }
            do { try produce() }
            catch {
                condition.lock(); if !stopped { failure = error }; condition.broadcast(); condition.unlock()
            }
        }
        do {
            let deadline = Date().addingTimeInterval(15)
            while Date() < deadline {
                try Task.checkCancellation()
                let (playable, error, cancelled) = condition.withLock { (ready, failure, stopped) }
                if let error { throw error }
                if cancelled { throw CancellationError() }
                if playable { return url }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            throw VividPlaybackError.renderer(-11819)
        } catch { stop(); throw error }
    }

    public func updatePlayhead(_ seconds: Double) {
        guard seconds.isFinite else { return }
        condition.lock(); playhead = seconds; condition.broadcast(); condition.unlock()
    }
    public func selectSubtitles(_ ids: Set<Int>) {
        condition.lock(); selectedSubtitles = ids; condition.unlock()
    }
    public func subtitles(at seconds: Double) -> [VividSubtitleCue] {
        condition.lock(); let selected = selectedSubtitles
        let visible = cues.filter { selected.contains($0.track) && $0.end >= seconds && $0.start <= seconds }
        condition.unlock()
        return visible + subtitleDecoder.rendered(at: seconds, selected: selected)
    }
    public func stop() {
        condition.lock(); stopped = true; let input = network; let remove = !workerActive; condition.broadcast(); condition.unlock()
        input?.cancel(); server?.stop()
        if remove { try? FileManager.default.removeItem(at: directory) }
    }

    deinit { stop() }

    private func produce() throws {
        let input = try VividNetwork(source)
        condition.lock(); network = input; let cancelled = stopped; condition.unlock()
        if cancelled { input.cancel(); throw CancellationError() }
        defer { input.cancel() }
        let demuxer = VividDemuxer(source: input)
        try demuxer.open()
        guard let format = demuxer.format,
              let video = demuxer.tracks.first(where: { $0.kind == .video }),
              let audio = demuxer.tracks.first(where: { $0.id == selectedAudio && $0.kind == .audio }),
              audio.codec == "dts", ["h264", "hevc"].contains(video.codec) else {
            throw VividPlaybackError.unsupportedTrack
        }
        let origin = vv_origin(format)
        if requestedTime > 0 {
            let target = (requestedTime + origin) * 1_000_000
            guard target.isFinite, target < Double(Int64.max), target > Double(Int64.min) else { throw VividPlaybackError.invalidSource }
            let code = avformat_seek_file(format, -1, Int64.min, Int64(target), Int64.max, AVSEEK_FLAG_BACKWARD)
            guard code >= 0 else { throw VividPlaybackError.media(code) }
        }
        var packet = av_packet_alloc()
        guard let pointer = packet else { throw VividPlaybackError.media(-12) }
        defer { av_packet_free(&packet) }
        var bridge: OpaquePointer?
        defer { vv_dts_bridge_free(&bridge) }
        var lastPlaylistCheck = Date.distantPast
        while !input.isCancelled {
            let code = av_read_frame(format, pointer)
            if code == vv_eof() {
                if let bridge {
                    let finish = vv_dts_bridge_finish(bridge)
                    guard finish >= 0 else { throw VividPlaybackError.media(finish) }
                    condition.lock(); ready = true; condition.unlock()
                } else { throw VividPlaybackError.unsupportedTrack }
                return
            }
            guard code >= 0 else { throw input.lastFailure ?? VividPlaybackError.media(code) }
            defer { av_packet_unref(pointer) }
            guard let stream = vv_stream(format, UInt32(pointer.pointee.stream_index)) else { continue }
            let timestamp = pointer.pointee.dts == vv_no_pts() ? pointer.pointee.pts : pointer.pointee.dts
            let seconds = timestamp == vv_no_pts() ? nil : Double(timestamp) * vv_time(stream.pointee.time_base) - origin
            if bridge == nil {
                guard pointer.pointee.stream_index == video.id, pointer.pointee.flags & AV_PKT_FLAG_KEY != 0,
                      let seconds else { continue }
                var error: Int32 = 0
                bridge = vv_dts_bridge_create(format, Int32(video.id), Int32(audio.id), seconds + origin, 0,
                    directory.appendingPathComponent("index.m3u8").path,
                    directory.appendingPathComponent("segment%06d.m4s").path, &error)
                guard bridge != nil else { throw VividPlaybackError.media(error) }
                condition.lock(); offset = seconds; mediaInventory = demuxer.inventory; condition.unlock()
            }
            condition.lock()
            while !stopped, pointer.pointee.stream_index == video.id, let seconds, seconds > playhead + 20 {
                _ = condition.wait(until: Date(timeIntervalSinceNow: 0.1))
            }
            let cancelled = stopped
            let now = playhead
            condition.unlock()
            if cancelled { throw CancellationError() }
            if stream.pointee.codecpar?.pointee.codec_type == AVMEDIA_TYPE_SUBTITLE {
                let pts = pointer.pointee.pts == vv_no_pts() ? seconds ?? 0 :
                    Double(pointer.pointee.pts) * vv_time(stream.pointee.time_base) - origin
                let decoded = subtitleDecoder.decode(pointer, stream: stream, pts: pts, origin: origin)
                condition.lock(); cues.removeAll { $0.end < now - 5 }; cues.append(contentsOf: decoded); condition.unlock()
            }
            let result = vv_dts_bridge_write(bridge, pointer)
            guard result >= 0 else { throw VividPlaybackError.media(result) }
            if Date().timeIntervalSince(lastPlaylistCheck) > 0.1 {
                lastPlaylistCheck = Date()
                let playlist = (try? String(contentsOf: directory.appendingPathComponent("index.m3u8"), encoding: .utf8)) ?? ""
                if playlist.components(separatedBy: "#EXTINF:").count >= 3 {
                    condition.lock(); ready = true; condition.unlock()
                }
            }
        }
        throw CancellationError()
    }
}
#endif
