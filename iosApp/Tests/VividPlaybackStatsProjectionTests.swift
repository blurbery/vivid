import AVFoundation
import Foundation
import UIKit
import XCTest
#if os(tvOS)
@testable import VividTV
#else
@testable import Vivid
#endif

final class VividPlaybackStatsProjectionTests: XCTestCase {
    func testTelemetryBurstDoesNotRepeatedlyProjectStatistics() {
        var cadence = VividPlaybackStatsCadence()
        let refreshes = (0..<1_000).filter { cadence.shouldRefresh(at: 100 + Double($0) / 1_000) }
        XCTAssertEqual(refreshes, [0, 900])
    }

    func testStateChangesRefreshImmediatelyAndRestartRoutineInterval() {
        var cadence = VividPlaybackStatsCadence()
        XCTAssertTrue(cadence.shouldRefresh(at: 10))
        XCTAssertFalse(cadence.shouldRefresh(at: 10.2))
        XCTAssertTrue(cadence.shouldRefresh(at: 10.2, force: true))
        XCTAssertFalse(cadence.shouldRefresh(at: 10.9))
        XCTAssertTrue(cadence.shouldRefresh(at: 11.2))
    }

    func testNewLoadResetsStatisticsCadence() {
        var cadence = VividPlaybackStatsCadence()
        XCTAssertTrue(cadence.shouldRefresh(at: 10))
        cadence.reset()
        XCTAssertTrue(cadence.shouldRefresh(at: 10.01))
    }

    @MainActor
    func testBufferUpdatesStayImmediateWhenStatisticsAreRateLimited() throws {
        let model = PlayerViewModel()
        defer { model.cleanup() }
        let spec = try VividLoadSpec(directURL: URL(string: "https://example.invalid/video.mp4")!,
                                    headers: [:], startPosition: 0, audioOnly: false)
        model.debugPreparePlaybackStatsLoad(spec)
        for buffer in [8.0, 0.2, 15.0, 0.0] {
            model.vividEngine.diagnostics.liveTelemetry = LiveTelemetry(forwardBufferSeconds: buffer)
            XCTAssertEqual(model.bufferedAheadSeconds, buffer, "Recovery must use the delivered sample")
            #if os(tvOS)
            XCTAssertEqual(model.timelineBufferedAheadSeconds, buffer, "Timeline must not wait for statistics")
            #endif
        }
        model.vividEngine.diagnostics.liveTelemetry = nil
        XCTAssertEqual(model.bufferedAheadSeconds, 0)
        XCTAssertNil(model.playbackStats.bufferedAheadSeconds)
        XCTAssertNil(model.playbackStats.readAheadAvailableSeconds)
        #if os(tvOS)
        XCTAssertEqual(model.timelineBufferedAheadSeconds, 0)
        #endif
    }

    @MainActor
    func testNewLoadUsesNewTelemetryAndClearsOldStatistics() throws {
        let model = PlayerViewModel()
        defer { model.cleanup() }
        for (host, buffer) in [("first.example.invalid", 9.0), ("second.example.invalid", 2.0)] {
            let spec = try VividLoadSpec(directURL: URL(string: "https://" + host + "/video.mp4")!,
                                        headers: [:], startPosition: 0, audioOnly: false)
            model.debugPreparePlaybackStatsLoad(spec)
            model.vividEngine.diagnostics.liveTelemetry = LiveTelemetry(forwardBufferSeconds: buffer)
            XCTAssertEqual(model.playbackStats.source, host)
            XCTAssertEqual(model.playbackStats.bufferedAheadSeconds, buffer)
            XCTAssertEqual(model.playbackStats.readAheadAvailableSeconds, buffer)
        }
    }

    @MainActor
    func testControllerDeliversCurrentTelemetryIncludingUnavailableSample() throws {
        let controller = try VividPlaybackController()
        defer { controller.stop() }
        let spec = try VividLoadSpec(directURL: URL(string: "https://example.invalid/video.mp4")!,
                                    headers: [:], startPosition: 0, audioOnly: false)
        let epoch = controller.beginLoad(spec)
        var snapshots: [VividPlaybackStatsSnapshot] = []
        controller.onEvent = { event in
            guard case .telemetryChanged(let telemetry) = event.event else { return }
            XCTAssertEqual(event.epoch, epoch)
            snapshots.append(VividPlaybackStatsSnapshot(engine: controller.engine, telemetry: telemetry))
        }
        controller.engine.diagnostics.liveTelemetry = LiveTelemetry(forwardBufferSeconds: 4)
        controller.engine.diagnostics.liveTelemetry = nil
        XCTAssertEqual(snapshots.count, 2)
        XCTAssertEqual(snapshots[0].telemetry?.forwardBufferSeconds, 4)
        XCTAssertEqual(snapshots[0].readAheadAvailableSeconds, 4)
        XCTAssertNil(snapshots[1].telemetry)
        XCTAssertNil(snapshots[1].readAheadAvailableSeconds)
        controller.onEvent = nil
    }

    @MainActor
    func testSimulatorPlaybackKeepsTransportWorkingThroughTelemetryUpdates() async throws {
        let controller = try VividPlaybackController()
        controller.setMuted(true)
        let window: UIWindow
        if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first {
            window = UIWindow(windowScene: scene)
        } else {
            window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1280, height: 720))
        }
        let host = UIViewController()
        window.rootViewController = host
        host.view.addSubview(controller.engine.surface)
        controller.engine.surface.frame = host.view.bounds
        controller.engine.surface.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        defer { controller.onEvent = nil; controller.stop(); window.isHidden = true; window.rootViewController = nil }
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "v3_h264_aac", withExtension: "mp4"))
        let spec = try VividLoadSpec(directURL: url, headers: [:], startPosition: 0, audioOnly: false)
        let epoch = controller.beginLoad(spec, shouldPlayWhenReady: false)
        try await controller.finishLoad(epoch)
        var samples = 0
        controller.onEvent = { event in
            if case .telemetryChanged(let telemetry) = event.event {
                _ = VividPlaybackStatsProjection.make(
                    snapshot: VividPlaybackStatsSnapshot(engine: controller.engine, telemetry: telemetry),
                    source: VividPlaybackStatsSourceMetadata(sourceURL: url, delivery: nil, container: "mp4", playbackRate: 1))
                samples += 1
            }
        }
        controller.play()
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while controller.engine.currentTime <= 0.2 && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertGreaterThan(controller.engine.currentTime, 0.2, "Synthetic media must actually play")
        controller.pause()
        let result = await controller.seek(toSourceTime: 0.1)
        XCTAssertEqual(result, .completed(sourceSeconds: 0.1))
        XCTAssertFalse(controller.shouldPlayWhenReady)
        XCTAssertEqual(controller.activeLoadEpoch, epoch)
        XCTAssertNil(controller.engine.errorInfo)
        XCTAssertGreaterThan(samples, 0)
        controller.setRate(1.25)
        controller.play()
        XCTAssertTrue(controller.shouldPlayWhenReady)
        XCTAssertEqual(controller.activeLoadEpoch, epoch)
    }

    func testAudioOutputDetailPreservesSourceCodecAndBitrate() {
        for output in ["PCM 5.1", "Not reported"] {
            let track = TrackInfo(id: 2, name: "English", codec: "eac3", language: "eng", channels: 6, bitrate: 768_000, isAtmos: true)
            let snapshot = VividPlaybackStatsSnapshot(route: .sampleBuffer, phase: .playing,
                audioOutputFormat: output, audioTracks: [track], activeAudioTrackIndex: 2)
            let stats = VividPlaybackStatsProjection.make(snapshot: snapshot,
                source: VividPlaybackStatsSourceMetadata(sourceURL: nil, delivery: nil, container: nil, playbackRate: 1))
            XCTAssertEqual(stats.audio.codec, "eac3")
            XCTAssertEqual(stats.audio.bitrateBps, 768_000)
            XCTAssertTrue(stats.audio.detail?.contains("Atmos") == true)
            XCTAssertEqual(stats.audio.detail?.contains("Output: PCM 5.1"), output == "PCM 5.1")
        }
    }

    func testConfiguredDolbyProfileLabelDoesNotOverrideHDRFallback() {
        for (format, expected) in [(VideoFormat.dolbyVision, "DV Profile 8.1"), (.hdr10, "HDR10")] {
            let snapshot = VividPlaybackStatsSnapshot(route: .sampleBuffer, phase: .playing,
                audioOutputFormat: "PCM 5.1", outputVideoFormat: format,
                outputDolbyProfileLabel: "DV Profile 8.1", sourceDVProfile: 8,
                sourceVideoWidth: 3840, sourceVideoHeight: 2160)
            let stats = VividPlaybackStatsProjection.make(snapshot: snapshot,
                source: VividPlaybackStatsSourceMetadata(sourceURL: nil, delivery: nil, container: nil, playbackRate: 1))
            XCTAssertEqual(stats.dynamicRange, expected)
            XCTAssertEqual(stats.audio.codec, "PCM 5.1")
        }
    }

    func testProjectsPublicVividStateAndRedactsSignedSourceURL() throws {
        let audio = TrackInfo(
            id: 2,
            name: "English",
            codec: "eac3",
            language: "eng",
            channels: 6,
            bitrate: 768_000,
            isDefault: true,
            isAtmos: true
        )
        let subtitle = TrackInfo(
            id: 5,
            name: "English SDH",
            codec: "subrip",
            language: "eng",
            isDefault: true,
            isHearingImpaired: true
        )
        let telemetry = LiveTelemetry(
            forwardBufferSeconds: 12.5,
            displayCushionSeconds: nil,
            readerWindowAheadBytes: 8_000_000,
            observedFps: 23.976,
            droppedFrameCount: 3,
            accumulatedFrameDelaySeconds: 0.25,
            avSyncGapMs: -7.5,
            instantBitrateMbps: 18.5,
            averageBitrateMbps: 14.25,
            audioBridgeBitrateMbps: 0.76,
            networkThroughputMbps: 95,
            networkTransferredBytes: 120_000_000,
            cachedBytes: 12_000_000,
            demuxerBytesFetched: 130_000_000,
            producerRestartCount: 1,
            rssMb: 384
        )
        let snapshot = VividPlaybackStatsSnapshot(
            route: .sampleBuffer,
            phase: .playing,
            telemetry: telemetry,
            activeVideoDecoder: "VideoToolbox HEVC (HW)",
            activeAudioDecoder: "Stream-copy (EAC3+JOC Atmos)",
            sourceVideoFormat: .dolbyVision,
            outputVideoFormat: .hdr10,
            sourceDVProfile: 7,
            sourceVideoWidth: 3840,
            sourceVideoHeight: 2160,
            sourceVideoFrameRate: 23.976,
            sourceVideoBitrateBps: 16_000_000,
            audioTracks: [audio],
            activeAudioTrackIndex: audio.id,
            subtitleTracks: [subtitle],
            isSubtitleActive: true,
            activeSubtitleTrackIndex: subtitle.id,
            isSecondarySubtitleActive: true
        )
        let sourceURL = try XCTUnwrap(URL(
            string: "https://media.example.test/items/secret-title.mkv?token=do-not-display"
        ))
        let source = VividPlaybackStatsSourceMetadata(
            sourceURL: sourceURL,
            delivery: "original_http",
            container: "matroska",
            playbackRate: 1.25,
            secondarySubtitleLabel: "Spanish"
        )
        let sampledAt = Date(timeIntervalSince1970: 1_000)

        let stats = VividPlaybackStatsProjection.make(
            snapshot: snapshot,
            source: source,
            sampledAt: sampledAt
        )

        XCTAssertEqual(stats.sampledAt, sampledAt)
        XCTAssertEqual(stats.route, "\(VividPlaybackEngineIdentity.name) sample-buffer video")
        XCTAssertEqual(stats.source, "media.example.test")
        XCTAssertFalse(stats.allRows.map(\.1).joined().contains("do-not-display"))
        XCTAssertFalse(stats.allRows.map(\.1).joined().contains("secret-title"))
        XCTAssertEqual(stats.delivery, "Original HTTP")
        XCTAssertEqual(stats.container, "MKV")
        XCTAssertEqual(stats.video.codec, "VideoToolbox HEVC (HW)")
        XCTAssertEqual(stats.video.detail, "3840×2160 · 23.976 fps")
        XCTAssertEqual(stats.video.bitrateBps, 16_000_000)
        XCTAssertEqual(stats.audio.codec, "eac3")
        XCTAssertEqual(
            stats.audio.detail,
            "English · eng · Atmos · Stream-copy (EAC3+JOC Atmos)"
        )
        XCTAssertEqual(stats.dynamicRange, "HDR10")
        XCTAssertEqual(stats.subtitles, "English SDH · eng · SUBRIP + Spanish")
        XCTAssertEqual(stats.playbackStatus, "Playing")
        XCTAssertEqual(stats.instantReadBitrateBps, 18_500_000)
        XCTAssertEqual(stats.networkThroughputBps, 95_000_000)
        XCTAssertEqual(stats.readerWindowAheadBytes, 8_000_000)
        XCTAssertEqual(stats.residentMemoryBytes, 384_000_000)

        let labels = Set(stats.allRows.map(\.0))
        XCTAssertFalse(labels.contains("Loopback generation"))
        XCTAssertFalse(labels.contains("Source cache watermarks"))
        XCTAssertFalse(labels.contains("Video packets"))
    }

    func testRouteAsymmetricTelemetryDoesNotInventForwardBuffer() {
        let telemetry = LiveTelemetry(
            forwardBufferSeconds: nil,
            displayCushionSeconds: 0.42,
            readerWindowAheadBytes: 2_000_000,
            observedFps: 59.94,
            droppedFrameCount: 0,
            accumulatedFrameDelaySeconds: 0,
            avSyncGapMs: nil,
            instantBitrateMbps: nil,
            averageBitrateMbps: nil,
            audioBridgeBitrateMbps: nil,
            networkThroughputMbps: nil,
            networkTransferredBytes: nil,
            cachedBytes: nil,
            demuxerBytesFetched: 0,
            producerRestartCount: 0,
            rssMb: 200
        )
        let stats = VividPlaybackStatsProjection.make(
            snapshot: VividPlaybackStatsSnapshot(
                route: .sampleBuffer,
                phase: .rebuffering,
                telemetry: telemetry,
                activeVideoDecoder: "dav1d AV1 (SW)",
                sourceVideoWidth: 1920,
                sourceVideoHeight: 1080
            ),
            source: VividPlaybackStatsSourceMetadata(
                sourceURL: URL(fileURLWithPath: "/private/media/title.mkv"),
                delivery: nil,
                container: "mkv",
                playbackRate: 1
            )
        )

        XCTAssertEqual(stats.source, "Offline file")
        XCTAssertEqual(stats.bufferedAheadSeconds, nil)
        XCTAssertEqual(stats.displayCushionSeconds, 0.42)
        XCTAssertEqual(stats.playbackStatus, "Rebuffering")
        XCTAssertFalse(stats.bufferRows.contains { $0.0 == "Forward buffer" })
        XCTAssertTrue(stats.bufferRows.contains { $0.0 == "Display cushion" })
        XCTAssertFalse(stats.engineRows.contains { $0.0 == "Producer restarts" })
    }

    func testServerToneMapStatsShowPlayingDynamicRange() {
        let stats = VividPlaybackStatsProjection.make(
            snapshot: VividPlaybackStatsSnapshot(
                route: .remoteBypass,
                phase: .playing,
                sourceVideoFormat: .sdr,
                outputVideoFormat: .sdr,
                sourceVideoWidth: 1_920,
                sourceVideoHeight: 1_080
            ),
            source: VividPlaybackStatsSourceMetadata(
                sourceURL: URL(string: "https://media.example.test/transcode/master.m3u8"),
                delivery: PlaybackProtocolV3.PlanDelivery.transcodeHLS,
                container: "hls",
                playbackRate: 1
            )
        )

        XCTAssertEqual(stats.dynamicRange, "SDR")
    }

    func testIdleSnapshotProducesNoSyntheticEngineRows() {
        let stats = VividPlaybackStatsProjection.make(
            snapshot: VividPlaybackStatsSnapshot(route: .none, phase: .idle),
            source: VividPlaybackStatsSourceMetadata(
                sourceURL: nil,
                delivery: nil,
                container: nil,
                playbackRate: nil
            )
        )

        XCTAssertFalse(stats.hasRows)
        XCTAssertEqual(stats, PlaybackStats(
            sampledAt: stats.sampledAt,
            route: nil,
            source: nil,
            delivery: nil,
            container: nil,
            video: .init(),
            audio: .init(),
            dynamicRange: nil,
            subtitles: nil,
            playbackRate: nil,
            playbackStatus: nil,
            bufferedAheadSeconds: nil,
            displayCushionSeconds: nil,
            readerWindowAheadBytes: nil,
            observedFrameRate: nil,
            droppedVideoFrames: nil,
            accumulatedFrameDelaySeconds: nil,
            avSyncGapMilliseconds: nil,
            instantReadBitrateBps: nil,
            averageReadBitrateBps: nil,
            audioBridgeBitrateBps: nil,
            networkThroughputBps: nil,
            bytesTransferred: nil,
            cachedBytes: nil,
            demuxerBytesFetched: nil,
            producerRestartCount: nil,
            residentMemoryBytes: nil
        ))
    }
}
