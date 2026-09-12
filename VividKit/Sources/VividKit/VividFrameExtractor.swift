// SPDX-License-Identifier: GPL-3.0-only
// Additional permission: LICENSE-APPLE-EXCEPTION at the repository root.
import AVFoundation
import CoreImage
import CVividMedia
import Foundation

public final class VividFrameExtractor: @unchecked Sendable {
    private let source: VividSource
    private let queue = DispatchQueue(label: "com.blurbery.vivid.preview", qos: .utility)
    private let lock = NSLock()
    private var activeInput: VividNetwork?
    private var stopped = false
    public init(source: VividSource) { self.source = source }
    public func cancel() { lock.lock(); stopped = true; activeInput?.cancel(); lock.unlock() }
    public func image(at seconds: Double, width: Int) async -> CGImage? {
        guard seconds.isFinite, seconds >= 0, width > 0 else { return nil }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                queue.async { [self] in continuation.resume(returning: extract(seconds, width: min(1024, width))) }
            }
        } onCancel: { self.cancel() }
    }
    private func extract(_ seconds: Double, width: Int) -> CGImage? {
        guard let network = try? VividNetwork(source) else { return nil }
        lock.lock()
        guard !stopped else { lock.unlock(); network.cancel(); return nil }
        activeInput = network; lock.unlock()
        defer { network.cancel(); lock.lock(); activeInput = nil; lock.unlock() }
        let demuxer = VividDemuxer(source: network)
        guard (try? demuxer.open()) != nil, let format = demuxer.format,
              let track = demuxer.tracks.first(where: { $0.kind == .video }),
              let stream = vv_stream(format, UInt32(track.id)) else { return nil }
        var error: Int32 = 0
        var decoder = vv_create_decoder(stream, 1, &error)
        guard let context = decoder else { return nil }
        defer { avcodec_free_context(&decoder) }
        let origin = vv_origin(format)
        guard seconds < Double(Int64.max) / 1_000_000 - max(0, origin),
              avformat_seek_file(format, -1, Int64.min, Int64((seconds + origin) * 1_000_000), Int64.max, AVSEEK_FLAG_BACKWARD) >= 0 else { return nil }
        var frame = av_frame_alloc(); var packet = av_packet_alloc(); var converter = vv_converter_create()
        guard let framePointer = frame, let packetPointer = packet, let converterPointer = converter else {
            av_frame_free(&frame); av_packet_free(&packet); vv_converter_free(&converter); return nil
        }
        defer { av_frame_free(&frame); av_packet_free(&packet); vv_converter_free(&converter) }
        let deadline = ProcessInfo.processInfo.systemUptime + 4
        for _ in 0..<1000 {
            guard !network.isCancelled, ProcessInfo.processInfo.systemUptime < deadline else { return nil }
            let result = av_read_frame(format, packetPointer)
            if result < 0 { _ = avcodec_send_packet(context, nil) }
            else if packetPointer.pointee.stream_index == Int32(track.id) { _ = avcodec_send_packet(context, packetPointer) }
            av_packet_unref(packetPointer)
            while avcodec_receive_frame(context, framePointer) >= 0 {
                let pts = Double(framePointer.pointee.best_effort_timestamp) * vv_time(stream.pointee.time_base) - origin
                defer { av_frame_unref(framePointer) }
                guard pts >= seconds else { continue }
                var unmanaged: Unmanaged<CMSampleBuffer>?
                guard vv_make_video_sample(converterPointer, framePointer, .zero, .invalid, &unmanaged) == 0,
                      let sample = unmanaged?.takeRetainedValue(), let pixel = CMSampleBufferGetImageBuffer(sample) else { return nil }
                let image = CIImage(cvPixelBuffer: pixel)
                let scale = min(1, CGFloat(width) / image.extent.width)
                let thumbnail = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                return CIContext(options: [.cacheIntermediates: false]).createCGImage(thumbnail, from: thumbnail.extent)
            }
            if result < 0 { break }
        }
        return nil
    }
}
