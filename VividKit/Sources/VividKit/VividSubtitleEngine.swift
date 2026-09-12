// SPDX-License-Identifier: GPL-3.0-only
// Additional permission: LICENSE-APPLE-EXCEPTION at the repository root.
import CoreGraphics
import CVividMedia
import Foundation

public struct VividSubtitleCue: @unchecked Sendable {
    public let id: Int
    public let track: Int
    public let start: Double
    public let end: Double
    public let text: String?
    public let image: CGImage?
    public let rectangle: CGRect
    public let canvas: CGSize

    fileprivate func ending(at time: Double) -> Self {
        Self(id: id, track: track, start: start, end: time, text: text,
             image: image, rectangle: rectangle, canvas: canvas)
    }
}
final class VividSubtitleEngine {
    private var decoders: [Int32: UnsafeMutablePointer<AVCodecContext>] = [:]
    private var nextID = 0
    private let lock = NSLock()
    private var ass: [Int: VividASSRenderer] = [:]
    private let rendering = DispatchQueue(label: "com.blurbery.vivid.subtitles", qos: .userInitiated)
    private var renderPending = false
    private var images: [VividSubtitleCue] = []
    private var epoch: UInt64 = 0

    /// Bitmap subtitle codecs such as PGS publish a replacement display set.
    /// Their decoded end time is often absent, so letting every set use the
    /// fallback duration stacks several dialogue images on screen. Keep all
    /// rectangles from one display set, but end the previous set when the next
    /// one for that track begins.
    static func append(_ decoded: [VividSubtitleCue], to timeline: inout [VividSubtitleCue]) {
        let nextBitmapStart = Dictionary(grouping: decoded.filter { $0.image != nil }, by: \.track)
            .mapValues { cues in cues.map(\.start).min()! }
        if !nextBitmapStart.isEmpty {
            timeline = timeline.compactMap { cue in
                guard cue.image != nil, let next = nextBitmapStart[cue.track] else { return cue }
                if abs(cue.start - next) < 0.001 { return nil }
                guard cue.start < next, cue.end > next else { return cue }
                return cue.ending(at: next)
            }
        }
        timeline.append(contentsOf: decoded)
    }

    func rendered(at time: Double, selected: Set<Int>) -> [VividSubtitleCue] {
        lock.lock(); defer { lock.unlock() }
        let result = images.filter { selected.contains($0.track) }
        guard !renderPending else { return result }
        renderPending = true
        let renderers = ass.filter { selected.contains($0.key) }, generation = epoch
        rendering.async { [self] in
            let next = renderers.compactMap { id, renderer -> VividSubtitleCue? in
                guard let image = renderer.render(at: time, width: 1920, height: 1080) else { return nil }
                return VividSubtitleCue(id: -id-1, track: id, start: max(0, time-1), end: time+1,
                    text: nil, image: image, rectangle: CGRect(x: 0, y: 0, width: 1, height: 1), canvas: CGSize(width: 1920, height: 1080))
            }
            lock.lock(); if epoch == generation { images = next }; renderPending = false; lock.unlock()
        }
        return result
    }
    func decode(_ packet: UnsafeMutablePointer<AVPacket>, stream: UnsafeMutablePointer<AVStream>, pts: Double, origin: Double) -> [VividSubtitleCue] {
        let index = packet.pointee.stream_index
        if let parameters = stream.pointee.codecpar,
           parameters.pointee.codec_id == AV_CODEC_ID_ASS || parameters.pointee.codec_id == AV_CODEC_ID_SSA {
            lock.lock()
            if ass[Int(index)] == nil, let extra = parameters.pointee.extradata, parameters.pointee.extradata_size > 0 {
                ass[Int(index)] = VividASSRenderer(data: Data(bytes: extra, count: Int(parameters.pointee.extradata_size)), document: false)
            }
            let renderer = ass[Int(index)]
            lock.unlock()
            if let renderer, let bytes = packet.pointee.data {
                renderer.append(data: bytes, size: packet.pointee.size, start: pts,
                    duration: max(0.001, Double(packet.pointee.duration) * vv_time(stream.pointee.time_base)))
                return []
            }
        }
        var code: Int32 = 0
        if decoders[index] == nil { decoders[index] = vv_create_decoder(stream, 0, &code) }
        guard let decoder = decoders[index] else { return [] }
        var subtitle = AVSubtitle()
        var got: Int32 = 0
        guard avcodec_decode_subtitle2(decoder, &subtitle, &got, packet) >= 0 else { return [] }
        defer { avsubtitle_free(&subtitle) }
        guard got != 0 else { return [] }
        let base = subtitle.pts == vv_no_pts() ? pts : Double(subtitle.pts) / 1_000_000 - origin
        let start = base + Double(subtitle.start_display_time) / 1000
        let end = base + Double(subtitle.end_display_time) / 1000
        var cues: [VividSubtitleCue] = []
        for index in 0..<min(subtitle.num_rects, 256) {
            guard let rect = vv_subtitle_rect(&subtitle, index) else { continue }
            var text: String?
            if let value = rect.pointee.text { text = String(cString: value) }
            else if let value = rect.pointee.ass {
                let fields = String(cString: value).split(separator: ",", maxSplits: 8, omittingEmptySubsequences: false)
                text = String(fields.last ?? "").replacingOccurrences(of: "\\N", with: "\n")
                    .replacingOccurrences(of: "\\n", with: "\n")
                    .replacingOccurrences(of: "\\{[^}]*\\}", with: "", options: .regularExpression)
            }
            let image = rect.pointee.type == SUBTITLE_BITMAP ? vv_subtitle_image(rect)?.takeRetainedValue() : nil
            guard text != nil || image != nil else { continue }
            nextID &+= 1
            let width = max(1, decoder.pointee.width), height = max(1, decoder.pointee.height)
            cues.append(VividSubtitleCue(id: nextID, track: Int(packet.pointee.stream_index), start: start,
                end: end > start ? end : start + 5, text: text, image: image,
                rectangle: CGRect(x: Double(rect.pointee.x)/Double(width), y: Double(rect.pointee.y)/Double(height),
                                  width: Double(rect.pointee.w)/Double(width), height: Double(rect.pointee.h)/Double(height)),
                canvas: CGSize(width: Int(width), height: Int(height))))
        }
        return cues
    }
    func flush() {
        for decoder in decoders.values { avcodec_flush_buffers(decoder) }
        lock.lock(); epoch &+= 1; images = []; let renderers = ass.values; lock.unlock()
        for renderer in renderers { renderer.flush() }
    }
    deinit { for decoder in decoders.values { var pointer: UnsafeMutablePointer<AVCodecContext>? = decoder; avcodec_free_context(&pointer) } }
}
