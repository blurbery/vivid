// SPDX-License-Identifier: Apache-2.0
import AVFoundation
import CVividMedia
import Foundation

public struct VividChapter: Sendable {
    public let id: Int
    public let name: String
    public let startSeconds: Double
}
public struct VividMediaInventory: Sendable {
    public let tracks: [VividTrack]
    public let duration: Double
    public let chapters: [VividChapter]
}
final class VividDemuxer {
    let source: VividNetwork
    var format: UnsafeMutablePointer<AVFormatContext>?
    private var io: UnsafeMutablePointer<AVIOContext>?
    var tracks: [VividTrack] = []
    init(source: VividNetwork) { self.source = source }
    func open() throws {
        format = avformat_alloc_context()
        guard let buffer = av_malloc(65_536)?.assumingMemoryBound(to: UInt8.self), format != nil else {
            throw VividPlaybackError.media(-12)
        }
        let opaque = Unmanaged.passUnretained(source).toOpaque()
        io = avio_alloc_context(buffer, 65_536, 0, opaque, { context, bytes, count in
            guard let context, let bytes else { return -5 }
            return Unmanaged<VividNetwork>.fromOpaque(context).takeUnretainedValue().read(into: bytes, count: Int(count))
        }, nil, { context, offset, whence in
            guard let context else { return -1 }
            return Unmanaged<VividNetwork>.fromOpaque(context).takeUnretainedValue().seek(offset: offset, whence: whence)
        })
        guard let io else { av_free(buffer); throw VividPlaybackError.media(-12) }
        format?.pointee.pb = io
        format?.pointee.interrupt_callback = AVIOInterruptCB(callback: { context in
            guard let context else { return 1 }
            return Unmanaged<VividNetwork>.fromOpaque(context).takeUnretainedValue().isCancelled ? 1 : 0
        }, opaque: opaque)
        vv_limit_input(format)
        var result = avformat_open_input(&format, nil, nil, nil)
        guard result >= 0, let format else { throw VividPlaybackError.media(result) }
        result = avformat_find_stream_info(format, nil)
        guard result >= 0 else { throw VividPlaybackError.media(result) }
        tracks = []
        for index in 0..<format.pointee.nb_streams {
            guard let stream = vv_stream(format, index), let parameters = stream.pointee.codecpar,
                  let kind = VividTrack.Kind(rawValue: parameters.pointee.codec_type.rawValue),
                  vv_attached_picture(stream) == 0 else { continue }
            func metadata(_ key: String) -> String {
                guard let entry = av_dict_get(stream.pointee.metadata, key, nil, 0), let value = entry.pointee.value else { return "" }
                return String(cString: value)
            }
            tracks.append(VividTrack(id: Int(index), kind: kind, name: metadata("title"), language: metadata("language"),
                codec: String(cString: avcodec_get_name(parameters.pointee.codec_id)),
                isDefault: vv_default(stream) != 0, isForced: vv_forced(stream) != 0,
                width: Int(parameters.pointee.width), height: Int(parameters.pointee.height),
                channels: Int(parameters.pointee.ch_layout.nb_channels), bitrate: parameters.pointee.bit_rate,
                frameRate: vv_time(av_guess_frame_rate(format, stream, nil)),
                pixelAspectRatio: parameters.pointee.sample_aspect_ratio.num > 0 ? vv_time(parameters.pointee.sample_aspect_ratio) : 1,
                dynamicRange: parameters.pointee.color_trc == AVCOL_TRC_SMPTE2084 ? "hdr10" : parameters.pointee.color_trc == AVCOL_TRC_ARIB_STD_B67 ? "hlg" : "sdr",
                dolbyVisionProfile: vv_dovi_profile(parameters) == 0 ? nil : Int(vv_dovi_profile(parameters))))
        }
    }
    var inventory: VividMediaInventory {
        guard let format else { return VividMediaInventory(tracks: [], duration: 0, chapters: []) }
        let chapters: [VividChapter] = (0..<format.pointee.nb_chapters).compactMap { index in
            guard let chapter = format.pointee.chapters?[Int(index)] else { return nil }
            let title = av_dict_get(chapter.pointee.metadata, "title", nil, 0).map { String(cString: $0.pointee.value) } ?? "Chapter \(index + 1)"
            return VividChapter(id: Int(index), name: title,
                startSeconds: Double(chapter.pointee.start) * vv_time(chapter.pointee.time_base) - vv_origin(format))
        }
        return VividMediaInventory(tracks: tracks,
            duration: format.pointee.duration == vv_no_pts() ? 0 : Double(format.pointee.duration) / 1_000_000,
            chapters: chapters)
    }
    deinit { avformat_close_input(&format); vv_free_io(&io) }
}
public enum VividProbe {
    public static func inspect(_ source: VividSource) throws -> VividMediaInventory {
        let network = try VividNetwork(source)
        defer { network.cancel() }
        let demuxer = VividDemuxer(source: network)
        try demuxer.open()
        return demuxer.inventory
    }
}
