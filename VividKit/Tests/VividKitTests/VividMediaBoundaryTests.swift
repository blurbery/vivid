// SPDX-License-Identifier: Apache-2.0
import AVFoundation
import VideoToolbox
import CVividMedia
import XCTest
@testable import VividKit

final class VividMediaBoundaryTests: XCTestCase {
    func testBitmapSubtitleDisplaySetsEndWhenTheNextSetBegins() {
        let context = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8,
            bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let image = context.makeImage()!
        func cue(_ id: Int, track: Int, start: Double, end: Double, bitmap: Bool) -> VividSubtitleCue {
            VividSubtitleCue(id: id, track: track, start: start, end: end,
                text: bitmap ? nil : "Text subtitle", image: bitmap ? image : nil,
                rectangle: .zero, canvas: CGSize(width: 1, height: 1))
        }

        var timeline = [
            cue(1, track: 4, start: 1, end: 6, bitmap: true),
            cue(2, track: 8, start: 1, end: 6, bitmap: true),
            cue(3, track: 4, start: 1, end: 6, bitmap: false)
        ]
        let nextSet = [
            cue(4, track: 4, start: 2, end: 7, bitmap: true),
            cue(5, track: 4, start: 2, end: 7, bitmap: true)
        ]
        VividSubtitleEngine.append(nextSet, to: &timeline)

        XCTAssertEqual(timeline.first { $0.id == 1 }?.end, 2)
        XCTAssertEqual(timeline.first { $0.id == 2 }?.end, 6)
        XCTAssertEqual(timeline.first { $0.id == 3 }?.end, 6)
        XCTAssertEqual(timeline.filter { $0.start == 2 }.count, 2)

        VividSubtitleEngine.append([cue(6, track: 4, start: 2, end: 7, bitmap: true)], to: &timeline)
        XCTAssertEqual(timeline.filter { $0.track == 4 && $0.start == 2 }.map(\.id), [6])
    }

    func testClockStallRequiresSixSecondsAndFiresOnce() {
        var detector = VividClockStallDetector()
        XCTAssertFalse(detector.observe(time: 0, uptime: 0, eligible: true))
        XCTAssertFalse(detector.observe(time: 0, uptime: 5.99, eligible: true))
        XCTAssertTrue(detector.observe(time: 0, uptime: 6, eligible: true))
        XCTAssertFalse(detector.observe(time: 0, uptime: 60, eligible: true))
    }

    func testClockStallIgnoresProgressAndResetsWhenIneligible() {
        var detector = VividClockStallDetector()
        for second in 0..<20 {
            XCTAssertFalse(detector.observe(time: Double(second), uptime: Double(second), eligible: true))
        }
        XCTAssertFalse(detector.observe(time: 19, uptime: 24, eligible: false))
        XCTAssertFalse(detector.observe(time: 19, uptime: 30, eligible: true))
        XCTAssertFalse(detector.observe(time: 19, uptime: 35, eligible: true))
        XCTAssertTrue(detector.observe(time: 19, uptime: 36, eligible: true))
        detector = VividClockStallDetector()
        XCTAssertFalse(detector.observe(time: 0, uptime: 40, eligible: true))
        XCTAssertFalse(detector.observe(time: .nan, uptime: 46, eligible: true))
        XCTAssertFalse(detector.observe(time: 0, uptime: 47, eligible: true))
    }

    func testAudioRecoveryRequiresClockMovementAndTimesOut() {
        for elapsed in [0.0, 2, 5.99] {
            XCTAssertEqual(VividAudioRecoveryProgress.evaluate(position: 493.442294,
                currentTime: 493.442294, elapsed: elapsed, isCurrent: true, wantsPlayback: true), .waiting)
        }
        XCTAssertEqual(VividAudioRecoveryProgress.evaluate(position: 493.442294,
            currentTime: 493.442294, elapsed: 6, isCurrent: true, wantsPlayback: true), .timedOut)
        XCTAssertEqual(VividAudioRecoveryProgress.evaluate(position: 493.442294,
            currentTime: 493.65, elapsed: 2, isCurrent: true, wantsPlayback: true), .recovered)
        XCTAssertEqual(VividAudioRecoveryProgress.evaluate(position: 493.442294,
            currentTime: .nan, elapsed: 6, isCurrent: true, wantsPlayback: true), .timedOut)
    }

    func testAudioRecoveryCancelsForPauseOrSupersededPlaybackBeforeAcceptingProgress() {
        for current in [false, true] {
            for wantsPlayback in [false, true] where !current || !wantsPlayback {
                XCTAssertEqual(VividAudioRecoveryProgress.evaluate(position: 10,
                    currentTime: 30, elapsed: 7, isCurrent: current, wantsPlayback: wantsPlayback), .cancelled)
            }
        }
    }

    func testDemuxReadPreservesSourceFailureWithoutInventingOne() {
        for source: VividPlaybackError in [.network(401), .network(403), .network(500), .network(NSURLErrorTimedOut), .invalidRange] {
            XCTAssertEqual(VividPlaybackError.demuxReadFailure(-5, sourceFailure: source), source)
        }
        XCTAssertEqual(VividPlaybackError.demuxReadFailure(-5, sourceFailure: nil), .media(-5))
    }

    func testAudioReplayRetainsOnlyUnplayedSamplesAndClearsOnSeek() throws {
        var replay = VividAudioReplayBuffer()
        for index in 0..<4 {
            replay.append(try Self.replaySample(at: Double(index)), at: 0)
        }
        XCTAssertEqual(replay.samples(at: 1.5).map { CMSampleBufferGetPresentationTimeStamp($0).seconds }, [1, 2, 3])
        XCTAssertEqual(replay.samples(at: 2).count, 2)
        XCTAssertTrue(replay.samples(at: .nan).isEmpty)
        XCTAssertEqual(replay.samples(at: 2).count, 2)
        replay.removeAll()
        XCTAssertTrue(replay.samples(at: 0).isEmpty)
    }

    func testAudioReplayBoundsMemoryAndRejectsOversizedSamples() throws {
        var replay = VividAudioReplayBuffer(byteLimit: 8)
        for index in 0..<4 {
            replay.append(try Self.replaySample(at: Double(index)), at: 0)
        }
        XCTAssertEqual(replay.samples(at: 0).map { CMSampleBufferGetPresentationTimeStamp($0).seconds }, [2, 3])
        replay.append(try Self.replaySample(at: 4, bytes: 16), at: 0)
        XCTAssertEqual(replay.samples(at: 0).count, 2)
        XCTAssertTrue(replay.samples(at: 4).isEmpty)
        replay.append(try Self.replaySample(at: 4), at: 4)
        XCTAssertEqual(replay.samples(at: 4).count, 1)
    }

    private static func replaySample(at seconds: Double, bytes: Int = 4) throws -> CMSampleBuffer {
        var block: CMBlockBuffer?
        XCTAssertEqual(CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
            blockLength: bytes, blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
            offsetToData: 0, dataLength: bytes, flags: 0, blockBufferOut: &block), noErr)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 1),
            presentationTimeStamp: CMTime(seconds: seconds, preferredTimescale: 1_000), decodeTimeStamp: .invalid)
        var size = bytes
        var sample: CMSampleBuffer?
        XCTAssertEqual(CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: try XCTUnwrap(block),
            formatDescription: nil, sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample), noErr)
        return try XCTUnwrap(sample)
    }

    func testAudioRecoveryIsBoundedAndRearmsAfterQuietPeriod() {
        var budget = VividAudioRecoveryBudget()
        XCTAssertTrue(budget.consume(at: 0))
        XCTAssertTrue(budget.consume(at: 1))
        XCTAssertTrue(budget.consume(at: 2))
        XCTAssertFalse(budget.consume(at: 3))
        XCTAssertFalse(budget.consume(at: .nan))
        XCTAssertFalse(budget.consume(at: 29.99))
        XCTAssertTrue(budget.consume(at: 30))
        XCTAssertFalse(budget.consume(at: 30.1))
        XCTAssertTrue(budget.consume(at: 32))
    }
    func testNativeDTSBridgeRejectsUnrelatedCodecsAndUnsupportedFormats() throws {
        let input = try XCTUnwrap(avformat_alloc_context())
        defer { avformat_free_context(input) }
        let video = try XCTUnwrap(avformat_new_stream(input, nil))
        let audio = try XCTUnwrap(avformat_new_stream(input, nil))
        video.pointee.codecpar.pointee.codec_type = AVMEDIA_TYPE_VIDEO
        video.pointee.codecpar.pointee.codec_id = AV_CODEC_ID_H264
        audio.pointee.codecpar.pointee.codec_type = AVMEDIA_TYPE_AUDIO
        audio.pointee.codecpar.pointee.sample_rate = 48_000
        av_channel_layout_default(&audio.pointee.codecpar.pointee.ch_layout, 8)
        for codec in [AV_CODEC_ID_AAC, AV_CODEC_ID_EAC3, AV_CODEC_ID_TRUEHD, AV_CODEC_ID_FLAC] {
            audio.pointee.codecpar.pointee.codec_id = codec
            var status: Int32 = 0
            XCTAssertNil(vv_dts_bridge_create(input, 0, 1, 0, 0, "/unused/index.m3u8", "/unused/segment%06d.m4s", &status))
            XCTAssertLessThan(status, 0)
        }
        audio.pointee.codecpar.pointee.codec_id = AV_CODEC_ID_DTS
        audio.pointee.codecpar.pointee.sample_rate = 0
        var status: Int32 = 0
        XCTAssertNil(vv_dts_bridge_create(input, 0, 1, 0, 0, "/unused/index.m3u8", "/unused/segment%06d.m4s", &status))
        XCTAssertLessThan(status, 0)
        XCTAssertNil(vv_dts_bridge_create(input, -1, 1, 0, 0, "/unused/index.m3u8", "/unused/segment%06d.m4s", &status))
    }

    @MainActor
    func testAACUsesNativeAudioAndAdvancesClock() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("m4a")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try AVAssetWriter(outputURL: url, fileType: .m4a)
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 128_000])
        writer.add(input); XCTAssertTrue(writer.startWriting()); writer.startSession(atSourceTime: .zero)
        var frame = av_frame_alloc(); var converter = vv_converter_create()
        guard let pointer = frame, let convert = converter else { throw VividPlaybackError.invalidSource }
        defer { av_frame_free(&frame); vv_converter_free(&converter) }
        pointer.pointee.format = AV_SAMPLE_FMT_FLT.rawValue
        pointer.pointee.sample_rate = 48_000; pointer.pointee.nb_samples = 1024
        av_channel_layout_default(&pointer.pointee.ch_layout, 2)
        XCTAssertGreaterThanOrEqual(av_frame_get_buffer(pointer, 0), 0)
        memset(pointer.pointee.data.0, 0, 1024 * 2 * MemoryLayout<Float>.size)
        let deadline = Date().addingTimeInterval(10)
        for index in 0..<96 {
            while !input.isReadyForMoreMediaData && Date() < deadline { try await Task.sleep(nanoseconds: 1_000_000) }
            guard input.isReadyForMoreMediaData else { throw VividPlaybackError.renderer(-1) }
            var sample: Unmanaged<CMSampleBuffer>?
            XCTAssertEqual(vv_make_audio_sample(convert, pointer, CMTime(value: Int64(index * 1024), timescale: 48_000), &sample), 0)
            XCTAssertTrue(input.append(try XCTUnwrap(sample?.takeRetainedValue())))
        }
        input.markAsFinished(); await writer.finishWriting(); XCTAssertEqual(writer.status, .completed)
        let player = VividPlayer(); defer { player.stop() }
        try await player.load(VividSource(url: url), autoplay: true)
        let playDeadline = Date().addingTimeInterval(5)
        while player.currentTime < 0.2 && player.error == nil && Date() < playDeadline { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertNil(player.error)
        XCTAssertTrue(player.nativeAudioDecode)
        XCTAssertGreaterThan(player.currentTime, 0.15)
    }

    func testASSRendererProducesAndClearsStyledCaption() throws {
        let document = """
        [Script Info]
        ScriptType: v4.00+
        PlayResX: 640
        PlayResY: 360
        [V4+ Styles]
        Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
        Style: Default,Helvetica,32,&H0000FFFF,&H000000FF,&H00000000,&H00000000,-1,0,0,0,100,100,0,0,1,2,1,2,10,10,10,1
        [Events]
        Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
        Dialogue: 0,0:00:01.00,0:00:02.00,Default,,0,0,0,,Vivid styled subtitle
        """
        let renderer = try XCTUnwrap(VividASSRenderer(data: Data(document.utf8)))
        XCTAssertNil(renderer.render(at: 0, width: 640, height: 360))
        XCTAssertNotNil(renderer.render(at: 1.5, width: 640, height: 360))
        XCTAssertNotNil(renderer.render(at: 1.6, width: 640, height: 360))
        XCTAssertNil(renderer.render(at: 2.5, width: 640, height: 360))
    }

    @MainActor
    func testMatroskaHardwareVideoPlaybackAndSeek() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let movie = base.appendingPathExtension("mov"), matroska = base.appendingPathExtension("mkv")
        defer { try? FileManager.default.removeItem(at: movie); try? FileManager.default.removeItem(at: matroska) }
        let writer = try AVAssetWriter(outputURL: movie, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 320, AVVideoHeightKey: 180,
            AVVideoCompressionPropertiesKey: [AVVideoMaxKeyFrameIntervalKey: 15]])
        let adapter = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 320, kCVPixelBufferHeightKey as String: 180])
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        let deadline = Date().addingTimeInterval(10)
        for index in 0..<90 {
            while !input.isReadyForMoreMediaData && Date() < deadline { try await Task.sleep(nanoseconds: 1_000_000) }
            guard input.isReadyForMoreMediaData else { throw VividPlaybackError.renderer(-1) }
            var pixel: CVPixelBuffer?
            let pool = try XCTUnwrap(adapter.pixelBufferPool)
            XCTAssertEqual(CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixel), kCVReturnSuccess)
            let frame = try XCTUnwrap(pixel)
            CVPixelBufferLockBaseAddress(frame, [])
            memset(CVPixelBufferGetBaseAddress(frame), Int32(index + 64), CVPixelBufferGetDataSize(frame))
            CVPixelBufferUnlockBaseAddress(frame, [])
            XCTAssertTrue(adapter.append(frame, withPresentationTime: CMTime(value: Int64(index), timescale: 30)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed)
        try Self.remux(movie: movie, matroska: matroska)
        let player = VividPlayer()
        defer { player.stop() }
        try await player.load(VividSource(url: matroska), autoplay: false)
        let firstFrameDeadline = Date().addingTimeInterval(5)
        while player.state == .opening && Date() < firstFrameDeadline { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(player.state, .paused)
        XCTAssertNil(player.error)
        XCTAssertEqual(player.hardwareVideoDecode, VTIsHardwareDecodeSupported(kCMVideoCodecType_H264))
        XCTAssertEqual(player.duration, 3, accuracy: 0.1)
        XCTAssertEqual(player.chapters.map(\.name), ["Opening", "Second chapter"])
        XCTAssertEqual(player.chapters.last?.startSeconds ?? -1, 1.5, accuracy: 0.001)
        let subtitle = try XCTUnwrap(player.tracks.first { $0.kind == .subtitle })
        try await player.selectSubtitles([subtitle.id])
        for target in [1.25, 0.25, 1.25, 0.75, 1.75] {
            player.pause()
            try await player.seek(to: target)
            let seekDeadline = Date().addingTimeInterval(5)
            while player.state == .opening && Date() < seekDeadline { try await Task.sleep(nanoseconds: 20_000_000) }
            XCTAssertEqual(player.state, .paused)
            XCTAssertEqual(player.currentTime, target, accuracy: 0.05)
            player.play()
            let playDeadline = Date().addingTimeInterval(2)
            while player.currentTime <= target + 0.1 && player.error == nil && Date() < playDeadline { try await Task.sleep(nanoseconds: 20_000_000) }
            let captionDeadline = Date().addingTimeInterval(2)
            while !player.subtitleCues.contains(where: { $0.text == "Embedded caption" }) && Date() < captionDeadline {
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            XCTAssertTrue(player.subtitleCues.contains(where: { $0.text == "Embedded caption" }))
            XCTAssertGreaterThan(player.currentTime, target + 0.1, "target=\(target) state=\(player.state) decoded=\(player.decodedAhead) clock=\(player.synchronizer.currentTime().seconds) rate=\(player.synchronizer.rate)")
            XCTAssertEqual(player.hardwareVideoDecode, VTIsHardwareDecodeSupported(kCMVideoCodecType_H264))
            XCTAssertNil(player.error)
            if player.error != nil { break }
        }
    }

    private static func remux(movie: URL, matroska: URL) throws {
        var input: UnsafeMutablePointer<AVFormatContext>?
        guard avformat_open_input(&input, movie.path, nil, nil) >= 0, let source = input else { throw VividPlaybackError.invalidSource }
        defer { avformat_close_input(&input) }
        guard avformat_find_stream_info(source, nil) >= 0, let stream = vv_stream(source, 0),
              let parameters = stream.pointee.codecpar, let extra = parameters.pointee.extradata else { throw VividPlaybackError.invalidSource }
        func integer(_ value: UInt64, width: Int? = nil) -> Data {
            let count = width ?? max(1, (64 - value.leadingZeroBitCount + 7) / 8)
            return Data((0..<count).reversed().map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) })
        }
        func element(_ id: UInt64, _ data: Data) -> Data {
            var count = 1
            while UInt64(data.count) >= (UInt64(1) << (count * 7)) - 1 { count += 1 }
            return integer(id) + integer(UInt64(data.count) | (UInt64(1) << (count * 7)), width: count) + data
        }
        func number(_ id: UInt64, _ value: UInt64) -> Data { element(id, integer(value)) }
        let header = number(0x4286, 1) + number(0x42F7, 1) + number(0x42F2, 4) + number(0x42F3, 8)
            + element(0x4282, Data("matroska".utf8)) + number(0x4287, 4) + number(0x4285, 2)
        let info = number(0x2AD7B1, 1_000_000) + element(0x4489, integer(Double(3000).bitPattern, width: 8))
            + element(0x4D80, Data("Vivid test".utf8)) + element(0x5741, Data("Vivid test".utf8))
        let video = number(0xB0, UInt64(parameters.pointee.width)) + number(0xBA, UInt64(parameters.pointee.height))
        let track = number(0xD7, 1) + number(0x73C5, 1) + number(0x83, 1)
            + element(0x86, Data("V_MPEG4/ISO/AVC".utf8))
            + element(0x63A2, Data(bytes: extra, count: Int(parameters.pointee.extradata_size)))
            + element(0xE0, video)
        let subtitle = number(0xD7, 2) + number(0x73C5, 2) + number(0x83, 17)
            + element(0x86, Data("S_TEXT/UTF8".utf8)) + element(0x22B59C, Data("eng".utf8))
        func chapter(_ id: UInt64, _ start: UInt64, _ end: UInt64, _ title: String) -> Data {
            element(0xB6, number(0x73C4, id) + number(0x91, start) + number(0x92, end)
                + element(0x80, element(0x85, Data(title.utf8))))
        }
        let chapters = element(0x1043A770, element(0x45B9,
            chapter(1, 0, 1_500_000_000, "Opening") + chapter(2, 1_500_000_000, 3_000_000_000, "Second chapter")))
        var segment = element(0x1549A966, info) + element(0x1654AE6B, element(0xAE, track) + element(0xAE, subtitle)) + chapters
        var packet = av_packet_alloc()
        guard let value = packet else { throw VividPlaybackError.invalidSource }
        defer { av_packet_free(&packet) }
        while av_read_frame(source, value) >= 0 {
            if value.pointee.stream_index == 0, let bytes = value.pointee.data {
                let pts = max(0, Double(value.pointee.pts) * vv_time(stream.pointee.time_base) * 1000)
                let block = Data([0x81, 0, 0, value.pointee.flags & 1 != 0 ? 0x80 : 0]) + Data(bytes: bytes, count: Int(value.pointee.size))
                var cluster = number(0xE7, UInt64(pts.rounded())) + element(0xA3, block)
                if value.pointee.flags & 1 != 0 {
                    let caption = Data([0x82, 0, 0, 0]) + Data("Embedded caption".utf8)
                    cluster += element(0xA0, element(0xA1, caption) + number(0x9B, 500))
                }
                segment += element(0x1F43B675, cluster)
            }
            av_packet_unref(value)
        }
        try (element(0x1A45DFA3, header) + element(0x18538067, segment)).write(to: matroska)
    }

    func testInterruptedHTTPReadRetriesFromDeliveredFrontier() throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [VividRangeProtocol.self]
        let source = try VividNetwork(VividSource(url: URL(string: "https://vivid.invalid/partial")!), configuration: configuration)
        defer { source.cancel() }
        let completed = expectation(description: "Partial read recovers")
        DispatchQueue.global().async {
            var output = [UInt8]()
            var scratch = [UInt8](repeating: 0, count: 65_536)
            while true {
                let count = source.read(into: &scratch, count: scratch.count)
                if count == vv_eof() { break }
                guard count > 0 else { XCTFail("Read failed with \(count): \(String(describing: source.lastFailure))"); break }
                output.append(contentsOf: scratch.prefix(Int(count)))
                if output.count == 65_536 { VividRangeProtocol.interruptFirstRequest() }
            }
            XCTAssertEqual(output, (0..<131_072).map { UInt8(truncatingIfNeeded: $0) })
            completed.fulfill()
        }
        wait(for: [completed], timeout: 3)
    }

    @MainActor
    func testSeekingRetainsRenderersAndPreservesPausedIntent() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("wav")
        let samples = 48_000 * 6
        var data = Data()
        func word<T: FixedWidthInteger>(_ value: T) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: "RIFF".utf8); word(UInt32(36 + samples * 4))
        data.append(contentsOf: "WAVEfmt ".utf8); word(UInt32(16)); word(UInt16(1)); word(UInt16(2))
        word(UInt32(48_000)); word(UInt32(192_000)); word(UInt16(4)); word(UInt16(16))
        data.append(contentsOf: "data".utf8); word(UInt32(samples * 4))
        data.append(Data(repeating: 0, count: samples * 4))
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let player = VividPlayer()
        defer { player.stop() }
        let layer = player.displayLayer
        let audio = player.audioRenderer
        try await player.load(VividSource(url: url), autoplay: false)
        XCTAssertEqual(player.duration, 6, accuracy: 0.001)
        try await player.seek(to: 3.25)
        XCTAssertTrue(player.displayLayer === layer)
        XCTAssertTrue(player.audioRenderer === audio)
        XCTAssertEqual(player.currentTime, 3.25, accuracy: 0.001)
        XCTAssertEqual(player.synchronizer.rate, 0)
        try await player.seek(to: 0.5)
        XCTAssertEqual(player.currentTime, 0.5, accuracy: 0.001)
        XCTAssertEqual(player.synchronizer.rate, 0)
    }

    func testContentRangeRejectsWrongOrUnboundedRepresentations() {
        for text in ["bytes */100", "bytes 0-100/100", "bytes -1-9/100", "bytes 5-2/100",
                     "bytes 0-9/*", "items 0-9/100", "bytes 0-999999999999999999999/100",
                     "bytes +1-9/100", "bytes 0-9/100/", "bytes 0--9/100"] {
            XCTAssertNil(VividNetwork.parseContentRange(text), text)
        }
        let valid = VividNetwork.parseContentRange("bytes 37711309-38759884/69673403510")
        XCTAssertEqual(valid?.start, 37_711_309)
        XCTAssertEqual(valid?.end, 38_759_884)
        XCTAssertEqual(valid?.total, 69_673_403_510)
    }

    func testFileSeekReadsExactFrontierAndCancellationWins() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data((0..<256).map(UInt8.init)).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let source = try VividNetwork(VividSource(url: url))
        defer { source.cancel() }
        var bytes = [UInt8](repeating: 0, count: 8)
        XCTAssertEqual(source.seek(offset: 0, whence: 0x10000), 256)
        XCTAssertEqual(source.seek(offset: -8, whence: 2), 248)
        XCTAssertEqual(source.read(into: &bytes, count: bytes.count), 8)
        XCTAssertEqual(bytes, Array(248...255).map(UInt8.init))
        XCTAssertEqual(source.read(into: &bytes, count: bytes.count), vv_eof())
        XCTAssertEqual(source.seek(offset: 4, whence: 0), 4)
        XCTAssertEqual(source.read(into: &bytes, count: bytes.count), 8)
        XCTAssertEqual(bytes, Array(4...11).map(UInt8.init))
        source.cancel()
        XCTAssertEqual(source.read(into: &bytes, count: bytes.count), vv_exit())
    }

    func testCancellingFullQueueReleasesBlockedProducer() throws {
        func packet() throws -> VividPacket {
            let raw = try XCTUnwrap(av_packet_alloc())
            let packet = VividPacket(raw)
            XCTAssertEqual(av_new_packet(raw, 16), 0)
            return packet
        }
        let queue = VividBuffer(byteLimit: 16)
        XCTAssertTrue(queue.put(try packet()))
        let blocked = try packet()
        let started = expectation(description: "Producer starts")
        let finished = expectation(description: "Cancellation wakes producer")
        DispatchQueue.global().async {
            started.fulfill()
            XCTAssertFalse(queue.put(blocked))
            finished.fulfill()
        }
        wait(for: [started], timeout: 1)
        queue.cancel()
        wait(for: [finished], timeout: 1)
        XCTAssertNil(queue.take())
    }

    func testFinishingQueuePreservesTailPackets() throws {
        let raw = try XCTUnwrap(av_packet_alloc())
        let packet = VividPacket(raw)
        XCTAssertEqual(av_new_packet(raw, 16), 0)
        let queue = VividBuffer(byteLimit: 16)
        XCTAssertTrue(queue.put(packet))
        queue.finish()
        XCTAssertTrue(queue.take() === packet)
        XCTAssertNil(queue.take())
        XCTAssertFalse(queue.put(packet))
    }

    func testHardwareFrameSampleKeepsOriginalPixelBuffer() throws {
        var converter: OpaquePointer? = try XCTUnwrap(vv_converter_create())
        defer { vv_converter_free(&converter) }
        var frame: UnsafeMutablePointer<AVFrame>? = try XCTUnwrap(av_frame_alloc())
        defer { av_frame_free(&frame) }
        var output: Unmanaged<CMSampleBuffer>?
        var originalAddress: UnsafeMutableRawPointer?
        do {
            var pixel: CVPixelBuffer?
            XCTAssertEqual(CVPixelBufferCreate(nil, 32, 32, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, nil, &pixel), kCVReturnSuccess)
            let buffer = try XCTUnwrap(pixel)
            originalAddress = Unmanaged.passUnretained(buffer).toOpaque()
            frame!.pointee.format = AV_PIX_FMT_VIDEOTOOLBOX.rawValue
            withUnsafeMutableBytes(of: &frame!.pointee.data) { storage in
                storage.bindMemory(to: UnsafeMutablePointer<UInt8>?.self)[3] = originalAddress!.assumingMemoryBound(to: UInt8.self)
            }
            XCTAssertEqual(vv_make_video_sample(converter, frame, CMTime(value: 10, timescale: 1),
                CMTime(value: 1, timescale: 24), &output), 0)
        }
        av_frame_free(&frame)
        let sample = try XCTUnwrap(output).takeRetainedValue()
        let retainedPixel = try XCTUnwrap(CMSampleBufferGetImageBuffer(sample))
        XCTAssertEqual(Unmanaged.passUnretained(retainedPixel).toOpaque(), originalAddress)
        XCTAssertEqual(CVPixelBufferGetWidth(retainedPixel), 32)
        XCTAssertEqual(CMSampleBufferGetPresentationTimeStamp(sample).seconds, 10)
    }

    func testPCMConversionPreservesWideSurroundChannelLabels() throws {
        var converter: OpaquePointer? = try XCTUnwrap(vv_converter_create())
        defer { vv_converter_free(&converter) }
        var frame: UnsafeMutablePointer<AVFrame>? = try XCTUnwrap(av_frame_alloc())
        defer { av_frame_free(&frame) }
        frame!.pointee.format = AV_SAMPLE_FMT_S16.rawValue
        frame!.pointee.sample_rate = 48_000
        frame!.pointee.nb_samples = 480
        XCTAssertEqual(av_channel_layout_from_string(&frame!.pointee.ch_layout, "7.1(wide)"), 0)
        XCTAssertEqual(av_frame_get_buffer(frame, 0), 0)
        memset(frame!.pointee.data.0, 0, 480 * 8 * MemoryLayout<Int16>.size)
        var result: Unmanaged<CMSampleBuffer>?
        XCTAssertEqual(vv_make_audio_sample(converter, frame, .zero, &result), 0)
        let sample = try XCTUnwrap(result).takeRetainedValue()
        let format = try XCTUnwrap(CMSampleBufferGetFormatDescription(sample))
        var layoutSize = 0
        let layout = try XCTUnwrap(CMAudioFormatDescriptionGetChannelLayout(format, sizeOut: &layoutSize))
        XCTAssertEqual(layout.pointee.mNumberChannelDescriptions, 8)
        let offset = MemoryLayout<AudioChannelLayout>.offset(of: \.mChannelDescriptions)!
        let descriptions = UnsafeRawPointer(layout).advanced(by: offset)
            .assumingMemoryBound(to: AudioChannelDescription.self)
        let labels = (0..<8).map { descriptions[$0].mChannelLabel }
        XCTAssertEqual(labels, [kAudioChannelLabel_Left, kAudioChannelLabel_Right,
            kAudioChannelLabel_Center, kAudioChannelLabel_LFEScreen,
            kAudioChannelLabel_LeftSurround, kAudioChannelLabel_RightSurround,
            kAudioChannelLabel_LeftCenter, kAudioChannelLabel_RightCenter])
    }

    func testPCMConversionPreservesSampleCountTimestampAndChannelOrder() throws {
        var converter: OpaquePointer? = try XCTUnwrap(vv_converter_create())
        defer { vv_converter_free(&converter) }
        var frame: UnsafeMutablePointer<AVFrame>? = try XCTUnwrap(av_frame_alloc())
        defer { av_frame_free(&frame) }
        frame!.pointee.format = AV_SAMPLE_FMT_S16.rawValue
        frame!.pointee.sample_rate = 48_000
        frame!.pointee.nb_samples = 480
        av_channel_layout_default(&frame!.pointee.ch_layout, 2)
        XCTAssertEqual(av_frame_get_buffer(frame, 0), 0)
        frame!.pointee.data.0!.withMemoryRebound(to: Int16.self, capacity: 960) { samples in
            for index in 0..<480 { samples[index * 2] = 16_384; samples[index * 2 + 1] = -16_384 }
        }
        var result: Unmanaged<CMSampleBuffer>?
        XCTAssertEqual(vv_make_audio_sample(converter, frame, CMTime(value: 5, timescale: 1), &result), 0)
        let sample = try XCTUnwrap(result).takeRetainedValue()
        XCTAssertEqual(CMSampleBufferGetNumSamples(sample), 480)
        XCTAssertEqual(CMSampleBufferGetPresentationTimeStamp(sample).seconds, 5)
        XCTAssertEqual(CMSampleBufferGetDuration(sample).seconds, 0.01, accuracy: 0.000001)
        let block = try XCTUnwrap(CMSampleBufferGetDataBuffer(sample))
        var values = [Float](repeating: 0, count: 2)
        XCTAssertEqual(CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: 8, destination: &values), noErr)
        XCTAssertEqual(values[0], 0.5, accuracy: 0.000001)
        XCTAssertEqual(values[1], -0.5, accuracy: 0.000001)
    }

    func testPCMConversionReusesItsFormatDescription() throws {
        var converter: OpaquePointer? = try XCTUnwrap(vv_converter_create())
        defer { vv_converter_free(&converter) }
        var frame: UnsafeMutablePointer<AVFrame>? = try XCTUnwrap(av_frame_alloc())
        defer { av_frame_free(&frame) }
        frame!.pointee.format = AV_SAMPLE_FMT_FLTP.rawValue
        frame!.pointee.sample_rate = 48_000
        frame!.pointee.nb_samples = 512
        av_channel_layout_default(&frame!.pointee.ch_layout, 6)
        XCTAssertEqual(av_frame_get_buffer(frame, 0), 0)

        var firstResult: Unmanaged<CMSampleBuffer>?
        XCTAssertEqual(vv_make_audio_sample(converter, frame, .zero, &firstResult), 0)
        let firstSample = try XCTUnwrap(firstResult).takeRetainedValue()
        let firstFormat = try XCTUnwrap(CMSampleBufferGetFormatDescription(firstSample))

        var secondResult: Unmanaged<CMSampleBuffer>?
        XCTAssertEqual(vv_make_audio_sample(
            converter,
            frame,
            CMTime(value: 512, timescale: 48_000),
            &secondResult
        ), 0)
        let secondSample = try XCTUnwrap(secondResult).takeRetainedValue()
        let secondFormat = try XCTUnwrap(CMSampleBufferGetFormatDescription(secondSample))

        XCTAssertEqual(
            Unmanaged.passUnretained(firstFormat).toOpaque(),
            Unmanaged.passUnretained(secondFormat).toOpaque()
        )
    }

    func testSoftwareAudioSnapsTimestampRoundingButPreservesDiscontinuities() {
        let exactFrameEnd = 512.0 / 48_000.0
        XCTAssertEqual(VividMediaSession.softwareAudioPresentationTime(
            decoded: 0.011,
            expected: exactFrameEnd,
            sampleRate: 48_000
        ), exactFrameEnd)
        XCTAssertEqual(VividMediaSession.softwareAudioPresentationTime(
            decoded: 0.025,
            expected: exactFrameEnd,
            sampleRate: 48_000
        ), 0.025)
        XCTAssertEqual(VividMediaSession.softwareAudioPresentationTime(
            decoded: nil,
            expected: exactFrameEnd,
            sampleRate: 48_000
        ), exactFrameEnd)
        XCTAssertEqual(VividMediaSession.softwareAudioPresentationTime(
            decoded: 0,
            expected: exactFrameEnd,
            sampleRate: 48_000
        ), exactFrameEnd, "Repeated DTS timestamps must remain monotonic")
    }
}

private final class VividRangeProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var firstRequest: VividRangeProtocol?

    static func interruptFirstRequest() {
        lock.lock()
        let pending = firstRequest
        firstRequest = nil
        lock.unlock()
        if let pending { pending.client?.urlProtocol(pending, didFailWithError: URLError(.timedOut)) }
    }

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "vivid.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let range = request.value(forHTTPHeaderField: "Range") ?? ""
        let start = range == "bytes=0-1048575" ? 0 : 65_536
        if start == 65_536 { XCTAssertEqual(range, "bytes=65536-131071") }
        let response = HTTPURLResponse(url: request.url!, statusCode: 206, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Range": "bytes \(start)-131071/131072", "ETag": "\"fixture\""])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if start == 0 {
            Self.lock.lock()
            Self.firstRequest = self
            Self.lock.unlock()
            client?.urlProtocol(self, didLoad: Data((0..<65_536).map { UInt8(truncatingIfNeeded: $0) }))
        } else {
            client?.urlProtocol(self, didLoad: Data((65_536..<131_072).map { UInt8(truncatingIfNeeded: $0) }))
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {
        Self.lock.lock()
        if Self.firstRequest === self { Self.firstRequest = nil }
        Self.lock.unlock()
    }
}
