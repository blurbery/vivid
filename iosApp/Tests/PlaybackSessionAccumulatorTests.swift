import XCTest
@testable import Vivid

final class PlaybackSessionAccumulatorTests: XCTestCase {
    private func playing(at start: TimeInterval = 0) -> PlaybackSessionAccumulator {
        var accumulator = PlaybackSessionAccumulator(startedAt: start)
        accumulator.setPlaying(true, at: start)
        accumulator.position(nil, at: start) // the playhead is moving
        return accumulator
    }

    func testDropsDuringWarmupAreKeptSeparately() {
        var session = playing()
        session.counter(.dropped, value: 0, at: 0.5)
        session.counter(.dropped, value: 12, at: 2) // start-up
        session.counter(.dropped, value: 12, at: 6)
        session.counter(.dropped, value: 20, at: 7) // real drops
        XCTAssertEqual(session.totals.droppedFrames, 8)
        XCTAssertEqual(session.totals.warmupDroppedFrames, 12)
    }

    func testSeekStartsANewWarmup() {
        var session = playing()
        session.counter(.dropped, value: 0, at: 10)
        session.seeked(at: 20)
        session.counter(.dropped, value: 30, at: 22)
        XCTAssertEqual(session.totals.droppedFrames, 0)
        XCTAssertEqual(session.totals.warmupDroppedFrames, 30)
        XCTAssertEqual(session.totals.seeks, 1)
    }

    func testCounterResetAfterReloadNeverGoesNegativeOrDoubles() {
        var session = playing()
        session.counter(.dropped, value: 0, at: 6)
        session.counter(.dropped, value: 50, at: 10)
        session.reloaded(at: 11)
        session.counter(.dropped, value: 2, at: 20) // new core starts again from zero
        session.counter(.dropped, value: 5, at: 21)
        XCTAssertEqual(session.totals.droppedFrames, 53)
        XCTAssertEqual(session.totals.reloads, 1)
    }

    func testUnreportedCounterStaysUnmeasured() {
        var session = playing()
        session.counter(.dropped, value: 0, at: 6)
        session.counter(.delayed, value: nil, at: 6)
        XCTAssertEqual(session.totals.droppedFrames, 0)
        XCTAssertNil(session.totals.delayedFrames, "a counter the player never reported isn't zero")
    }

    func testStartupBufferingIsNotARebuffer() {
        var session = PlaybackSessionAccumulator(startedAt: 0)
        session.setBuffering(true, at: 0)
        session.setBuffering(false, at: 3)
        session.setPlaying(true, at: 3)
        session.position(nil, at: 3)
        session.tick(at: 40)
        session.setBuffering(true, at: 40)
        session.setBuffering(false, at: 44)
        XCTAssertEqual(session.totals.rebuffers, 1)
        XCTAssertEqual(session.totals.rebufferSeconds, 4, accuracy: 0.001)
    }

    /// The player only reports playing once the first frame is on screen, so
    /// a slow open that buffers first adds no played time, rebuffers or drops.
    func testSlowStartBeforeFirstFrameIsNotCountedAsPlayback() {
        var session = PlaybackSessionAccumulator(startedAt: 0)
        session.counter(.dropped, value: 0, at: 0.5)
        session.setBuffering(true, at: 1)
        session.counter(.dropped, value: 10, at: 7)
        session.setBuffering(false, at: 8)
        session.setPlaying(true, at: 8)
        session.position(nil, at: 8)
        for second in 9...20 { session.tick(at: TimeInterval(second)) } // the player ticks once a second
        XCTAssertEqual(session.totals.playedSeconds, 12, accuracy: 0.001)
        XCTAssertEqual(session.totals.rebuffers, 0)
        XCTAssertEqual(session.totals.droppedFrames, 0)
        XCTAssertEqual(session.totals.warmupDroppedFrames, 10)
    }

    func testAvSyncIgnoresWarmupAndCountsTimeOverThreshold() {
        var session = playing()
        session.avSync(ms: 400, at: 1) // warm-up
        session.avSync(ms: 150, at: 10)
        session.tick(at: 12)
        session.avSync(ms: 20, at: 12)
        session.tick(at: 14)
        XCTAssertEqual(session.totals.maxAvSyncMs, 150)
        XCTAssertEqual(session.totals.avSyncOver100msSeconds, 2, accuracy: 0.001)
    }

    func testTimelineKeepsOnlyMinutesWithProblems() {
        var session = playing()
        session.counter(.dropped, value: 0, at: 6)
        for second in stride(from: 6.0, through: 130, by: 1) { session.tick(at: second) }
        session.counter(.dropped, value: 9, at: 131)
        session.audioFault("decode_error", at: 132)
        XCTAssertEqual(session.timeline.map(\.minute), [2])
        XCTAssertEqual(session.timeline.first?.droppedFrames, 9)
        XCTAssertEqual(session.timeline.first?.faults, ["decode_error": 1])
    }

    @MainActor
    func testFiveHourSessionWithProblemsEveryMinuteStaysSmall() throws {
        var session = playing()
        session.counter(.dropped, value: 0, at: 6)
        var dropped = 0
        for second in stride(from: 6.0, through: 5 * 3600, by: 1) {
            session.tick(at: second)
            if Int(second) % 60 == 30 {
                dropped += 3
                session.counter(.dropped, value: dropped, at: second)
                session.avSync(ms: 180, at: second)
                session.audioFault("decode_error", at: second)
            }
        }
        XCTAssertLessThanOrEqual(session.timeline.count, PlaybackSessionAccumulator.maxTimelineMinutes)
        let report = PlaybackSessionRecorder.finish(
            PlaybackSessionReport(startedAt: Date(), updatedAt: Date(),
                                  app: AppHealthAppInfo(version: "0.14.3", build: "57", os: "tvOS 27.0", device: "AppleTV14,1"),
                                  setup: .init(), media: .init(), totals: .init(), timeline: [], notMeasured: []),
            session)
        let size = try XCTUnwrap(PlaybackSessionRecorder.encode(report)).count
        XCTAssertLessThan(size, 64 * 1024, "the report stays small however long or big the movie")
    }

    func testWarmupOnlyCountsDroppedFrames() {
        var session = playing()
        session.counter(.dropped, value: 2, at: 0.5)
        session.counter(.delayed, value: 9, at: 0.5)
        session.counter(.dropped, value: 5, at: 2)
        session.counter(.delayed, value: 30, at: 2)
        session.counter(.decoderDropped, value: 0, at: 2)
        session.counter(.decoderDropped, value: 4, at: 3)
        XCTAssertEqual(session.totals.warmupDroppedFrames, 5)
        XCTAssertEqual(session.totals.delayedFrames, 0)
        XCTAssertEqual(session.totals.decoderDroppedFrames, 0)
    }

    @MainActor
    func testWorstCaseFaultTimelineIsTrimmedToFit() throws {
        var session = playing()
        for minute in 0..<PlaybackSessionAccumulator.maxTimelineMinutes {
            let second = 10 + Double(minute) * 60
            for seconds in stride(from: second - 59, through: second, by: 1) where seconds > 0 { session.tick(at: seconds) }
            for kind in 0..<PlaybackSessionAccumulator.maxFaultKinds + 4 { session.audioFault("audio_fault_kind_\(kind)", at: second) }
        }
        let report = PlaybackSessionRecorder.finish(
            PlaybackSessionReport(startedAt: Date(), updatedAt: Date(),
                                  app: AppHealthAppInfo(version: "0.14.3", build: "57", os: "tvOS 27.0", device: "AppleTV14,1"),
                                  setup: .init(), media: .init(), totals: .init(), timeline: [], notMeasured: []),
            session)
        let size = try XCTUnwrap(PlaybackSessionRecorder.encode(report)).count
        XCTAssertLessThanOrEqual(size, PlaybackSessionRecorder.maxEncodedBytes)
        XCTAssertFalse(report.timeline.isEmpty, "the newest problem minutes are kept")
        XCTAssertEqual(report.timeline.last?.minute, PlaybackSessionAccumulator.maxTimelineMinutes - 1)
    }

    func testRefillingRightAfterASeekIsNotARebuffer() {
        var session = playing()
        for second in 1...30 { session.tick(at: TimeInterval(second)) }
        session.seeked(at: 30)
        session.setBuffering(true, at: 31)
        session.setBuffering(false, at: 33)
        XCTAssertEqual(session.totals.rebuffers, 0)
        for second in 34...60 { session.tick(at: TimeInterval(second)) }
        session.setBuffering(true, at: 60) // a stall in steady playback
        session.setBuffering(false, at: 62)
        XCTAssertEqual(session.totals.rebuffers, 1)
    }

    func testHiddenVideoDoesNotCountDropsOrSync() {
        var session = playing()
        session.counter(.dropped, value: 0, at: 6)
        session.setVideoVisible(false, at: 10)
        session.counter(.dropped, value: 500, at: 30)
        session.avSync(ms: 900, at: 30)
        session.setVideoVisible(true, at: 40)
        session.counter(.dropped, value: 503, at: 50)
        XCTAssertEqual(session.totals.droppedFrames, 3)
        XCTAssertNil(session.totals.maxAvSyncMs)
    }

    /// On AirPlay the first frame is held until the speakers start; that
    /// wait is startup, not playback.
    func testHeldFirstFrameIsStartupNotPlayback() {
        var session = PlaybackSessionAccumulator(startedAt: 0)
        session.setPlaying(true, at: 1)
        for second in 1...4 { session.position(0, at: TimeInterval(second)) }
        for second in 5...10 { session.position(Double(second - 4), at: TimeInterval(second)) }
        XCTAssertEqual(session.totals.firstFrameSeconds, 1)
        XCTAssertEqual(session.totals.playbackStartSeconds, 5)
        XCTAssertEqual(session.totals.playedSeconds, 5, accuracy: 0.001)
        XCTAssertEqual(session.totals.stalls, 0)
    }

    /// A stopped playhead with no buffering is how a parked audio clock
    /// shows, since video waits for it and A/V sync stays near zero.
    func testStoppedPlayheadInSteadyPlaybackIsAStall() {
        var session = playing()
        for second in 1...20 { session.position(Double(second), at: TimeInterval(second)) }
        for second in 21...25 { session.position(20, at: TimeInterval(second)) }
        for second in 26...30 { session.position(Double(second - 5), at: TimeInterval(second)) }
        XCTAssertEqual(session.totals.stalls, 1)
        XCTAssertEqual(session.totals.stallSeconds, 5, accuracy: 0.001)
        XCTAssertEqual(session.timeline.map(\.minute), [0])
    }

    func testHoldsDuringWarmupBufferingOrPauseAreNotStalls() {
        var session = playing()
        for second in 1...20 { session.position(Double(second), at: TimeInterval(second)) }
        session.seeked(at: 20)
        for second in 21...24 { session.position(100, at: TimeInterval(second)) } // AirPlay engaging after a seek
        session.setBuffering(true, at: 30)
        for second in 31...40 { session.position(100, at: TimeInterval(second)) }
        session.setBuffering(false, at: 40)
        session.setPlaying(false, at: 41)
        for second in 42...60 { session.position(100, at: TimeInterval(second)) }
        XCTAssertEqual(session.totals.stalls, 0)
    }

    func testFrameRateMatchFlagsJudder() {
        var report = PlaybackSessionReport(
            startedAt: Date(), updatedAt: Date(),
            app: AppHealthAppInfo(version: "0.14.3", build: "57", os: "tvOS 27.0", device: "AppleTV14,1"),
            setup: .init(), media: .init(), totals: .init(), timeline: [], notMeasured: [])
        XCTAssertNil(report.frameRateMatched)
        for (fps, hz, matched) in [(23.976, 59.94, false), (24, 60, false), (23.976, 23.976, true), (25, 50, true), (29.97, 59.94, true)] {
            report.media.contentFps = fps
            report.setup.displayRefreshHz = hz
            XCTAssertEqual(report.frameRateMatched, matched, "\(fps) fps on \(hz) Hz")
        }
    }

    func testPausedTimeIsNotPlayedTime() {
        var session = playing()
        for second in 1...10 { session.tick(at: TimeInterval(second)) }
        session.setPlaying(false, at: 10)
        for second in 11...100 { session.tick(at: TimeInterval(second)) }
        XCTAssertEqual(session.totals.playedSeconds, 10, accuracy: 0.001)
    }

    func testFormatTokensRejectFreeTextAndAddresses() {
        XCTAssertEqual(VividMPVPlayer.formatToken("HEVC"), "hevc")
        XCTAssertEqual(VividMPVPlayer.formatToken("spdif-eac3"), "spdif-eac3")
        XCTAssertNil(VividMPVPlayer.formatToken("https://media.example.com/video.mkv"))
        XCTAssertNil(VividMPVPlayer.formatToken("My Movie Title"))
        XCTAssertNil(VividMPVPlayer.formatToken("192.168.1.20:8096/x"))
        XCTAssertNil(VividMPVPlayer.formatToken("192.168.1.20"))
        XCTAssertNil(VividMPVPlayer.formatToken("nas.local"))
    }

    func testFaultNamesStayBounded() {
        var session = playing()
        for index in 0..<500 { session.audioFault("fault_\(index)", at: 10) }
        session.audioFault("https://server.example.com/x", at: 10)
        XCTAssertLessThanOrEqual(session.totals.audioFaults.count, PlaybackSessionAccumulator.maxFaultKinds + 1)
        XCTAssertEqual(session.totals.audioFaults.values.reduce(0, +), 501)
        XCTAssertFalse(session.totals.audioFaults.keys.contains { $0.contains("example") })
    }

    @MainActor
    func testReportNeverContainsAddressesAndListsWhatWasNotMeasured() throws {
        var session = playing()
        session.counter(.dropped, value: 0, at: 6)
        var report = PlaybackSessionReport(
            startedAt: Date(timeIntervalSince1970: 1_790_000_000), updatedAt: Date(timeIntervalSince1970: 1_790_000_000),
            app: AppHealthAppInfo(version: "0.14.3", build: "57", os: "tvOS 27.0", device: "AppleTV14,1"),
            setup: .init(), media: .init(), totals: .init(), timeline: [], notMeasured: [])
        report.setup.audioOutput = "airplay"
        report.media.videoCodec = VividMPVPlayer.formatToken("https://server.example.com/stream")
        let finished = PlaybackSessionRecorder.finish(report, session)
        let json = String(decoding: try XCTUnwrap(PlaybackSessionRecorder.encode(finished)), as: UTF8.self)
        XCTAssertFalse(json.contains("example.com"))
        XCTAssertFalse(json.contains("http"))
        XCTAssertTrue(finished.notMeasured.contains("video_codec"))
        XCTAssertTrue(finished.notMeasured.contains("delayed_frames"))
        XCTAssertTrue(finished.notMeasured.contains("airplay_receiver_formats"))
        XCTAssertFalse(finished.notMeasured.contains("dropped_frames"))
    }
}
