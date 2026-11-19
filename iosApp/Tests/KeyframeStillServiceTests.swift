import CoreGraphics
import Foundation
import UIKit
import XCTest
#if os(tvOS)
@testable import VividTV
#else
@testable import Vivid
#endif

/// The keyframe still service: its gates, its cache and window, the order
/// and limits of read-ahead, and its place in the scrub preview provider.
/// Time is a number the tests move, and the service's clock is `tick()`.
@MainActor
final class KeyframeStillServiceTests: XCTestCase {
    private static let mp4 = "stills_h264_bframes.mp4"
    private static let matroska = "stills_h264_bframes.mkv"

    // MARK: - The switch and the gates

    func testWithTheSwitchOffNothingIsMadeAndScrubbingIsAsBefore() async throws {
        let rig = Rig()
        rig.enabled = false
        var readersMade = 0
        let controller = try VividPlaybackController()
        let provider = VividScrubPreviewProvider(
            engine: controller.engine,
            makeReader: { _ in
                readersMade += 1
                return nil
            },
            stillSwitch: rig.switchRead, stills: rig.environment, expectsFrameReader: false,
            stillsWaitForMove: false)
        provider.stillPlayer = rig.player
        var previews: [VividScrubPreviewProvider.Preview?] = []
        provider.onPreview = { previews.append($0) }

        provider.activate(try Self.directSpec())
        provider.playbackStarted()
        provider.begin(atSourceTime: 15)
        provider.request(atSourceTime: 25)
        for _ in 0..<8 { rig.advance() }

        await Task.yield()
        XCTAssertNil(provider.debugStillService)
        XCTAssertEqual(rig.switchAsks, 1, "the switch is read once for the load, at its first frame")
        XCTAssertEqual(rig.environmentsBuilt, 0, "and with it off the service's environment is never built")
        XCTAssertEqual(rig.opens.value, 0, "no reader")
        XCTAssertEqual(rig.watchesMade, 0, "no network monitor")
        XCTAssertEqual(rig.stateAsks, 0, "the player isn't even asked")
        XCTAssertEqual(rig.headerAsks, 0)
        XCTAssertEqual(readersMade, 2, "the frame reader is looked for on every target, as before")
        XCTAssertTrue(previews.allSatisfy { $0 == nil })
        XCTAssertNil(KeyframeStillService.makeIfEligible(for: try Self.directSpec(), hasServerSheets: false,
                                                         player: rig.player, environment: rig.environment, carried: nil))
        await provider.endSession()?.value
    }

    func testWithTheSwitchOffAFrameReaderThatGivesNothingIsNotQuestioned() async throws {
        let rig = Rig()
        rig.enabled = false
        let frames = FrameReader(image: nil, canRead: false)
        let controller = try VividPlaybackController()
        let provider = VividScrubPreviewProvider(engine: controller.engine, makeReader: { _ in frames },
                                                 stillSwitch: rig.switchRead, stills: rig.environment, expectsFrameReader: true,
            stillsWaitForMove: false)
        provider.stillPlayer = rig.player
        provider.activate(try Self.directSpec())
        provider.playbackStarted()
        provider.begin(atSourceTime: 15)
        try await waitUntil { frames.thumbnails == 1 }
        provider.endInteraction()
        await provider.endSession()?.value
        XCTAssertEqual(frames.questions, 0)
        XCTAssertEqual(frames.shutdowns, 1, "retired at the end of the scrub, as before")
        XCTAssertEqual(rig.opens.value, 0)
        XCTAssertEqual(rig.switchAsks, 1)
        XCTAssertEqual(rig.environmentsBuilt, 0)
    }

    func testEachGateLeavesTheLoadWithoutAService() throws {
        typealias Gate = KeyframeStillService.Gate
        let direct = try Self.directSpec()
        let hls = try VividLoadSpec(directURL: Self.address("/Videos/1/master.m3u8?MediaSourceId=1"), headers: [:],
                                    startPosition: 0, audioOnly: false, nativeHLS: true)
        let transcode = try VividLoadSpec(directURL: Self.address("/Videos/1/stream.mkv?VideoCodec=h264&MediaSourceId=1"),
                                          headers: [:], startPosition: 0, audioOnly: false)
        let audioOnly = try VividLoadSpec(directURL: Self.address("/Audio/1/stream.flac?Static=true"), headers: [:],
                                          startPosition: 0, audioOnly: true)
        // The address asks for the stored file, but the app asked for HLS.
        let staticHLS = try VividLoadSpec(directURL: Self.address("/Videos/1/master.m3u8?Static=true&MediaSourceId=1"),
                                          headers: [:], startPosition: 0, audioOnly: false, nativeHLS: true)
        let cases: [(name: String, spec: VividLoadSpec, sheets: Bool, change: (Rig) -> Void, gate: Gate)] = [
            ("HLS at an address that says Static", staticHLS, false, { _ in }, .notOriginalFile),
            ("switch off", direct, false, { $0.enabled = false }, .switchedOff),
            ("server sheets", direct, true, { _ in }, .serverSheets),
            ("HLS", hls, false, { _ in }, .notOriginalFile),
            ("transcode", transcode, false, { _ in }, .notOriginalFile),
            ("audio only", audioOnly, false, { _ in }, .audioOnly),
            ("Apple TV HD", direct, false, { $0.machine = "AppleTV5,3" }, .appleTVHD),
            ("another load", direct, false, { $0.state = nil }, .loadNotCurrent),
            ("AirPlay or Picture in Picture", direct, false, { $0.state?.isHandedOff = true }, .handedOff),
            ("background", direct, false, { $0.state?.isAppActive = false }, .background),
        ]
        for item in cases {
            let rig = Rig()
            item.change(rig)
            XCTAssertEqual(KeyframeStillService.gate(for: item.spec, hasServerSheets: item.sheets, state: rig.state,
                                                     environment: rig.environment), item.gate, item.name)
            XCTAssertNil(KeyframeStillService.makeIfEligible(for: item.spec, hasServerSheets: item.sheets, player: rig.player,
                                                             environment: rig.environment, carried: nil), item.name)
            XCTAssertEqual(rig.opens.value, 0, item.name)
            XCTAssertEqual(rig.watchesMade, 0, item.name)
        }
    }

    func testOnlyAFilePlayedAsStoredIsEligible() throws {
        let original = PlaybackProtocolV3.PlanDelivery.originalHTTP
        func isOriginal(_ path: String, delivery: String = original, plan: String = "legacy-direct", hls: Bool = false) -> Bool {
            VividLoadSpec.playsStoredFile(url: Self.address(path), delivery: delivery, isLegacyDirect: plan == "legacy-direct",
                                          nativeRemoteHLS: hls)
        }
        XCTAssertTrue(isOriginal("/Videos/1/stream.mkv?Static=true&MediaSourceId=1"), "Jellyfin and Emby direct play")
        XCTAssertTrue(isOriginal("/Videos/1/stream.mkv?static=TRUE"))
        XCTAssertFalse(isOriginal("/Videos/1/stream.mkv?Static=false"))
        XCTAssertFalse(isOriginal("/Videos/1/stream.mkv?MediaSourceId=1"), "a server transcode or remux")
        XCTAssertFalse(isOriginal("/Videos/1/master.m3u8?Static=true", hls: true))
        XCTAssertTrue(isOriginal("/stream/s1", plan: "plan:1"), "Silo's original file")
        for delivery in [PlaybackProtocolV3.PlanDelivery.remuxProgressive, PlaybackProtocolV3.PlanDelivery.remuxHLS,
                         PlaybackProtocolV3.PlanDelivery.transcodeHLS] {
            XCTAssertFalse(isOriginal("/stream/s1", delivery: delivery, plan: "plan:1"), delivery)
        }
        XCTAssertFalse(isOriginal("/stream/s1", plan: "plan:1", hls: true))

        // The specs the player really builds.
        let rig = Rig()
        let download = try VividLoadSpec(offlineURL: try Self.fixtureURL(Self.mp4), startPosition: 0, audioOnly: false)
        let silo = try VividLoadSpec(validating: PlaybackEndFixtures.plan(sessionId: "s1", durationSeconds: 7200),
                                     sessionID: "s1", matchContentEnabled: false, sourceURLOverride: Self.address("/stream/s1"))
        for spec in [download, silo, try Self.directSpec()] {
            XCTAssertTrue(spec.playsStoredFile)
            XCTAssertNil(KeyframeStillService.gate(for: spec, hasServerSheets: false, state: rig.state, environment: rig.environment))
        }
    }

    func testAddressesOnTheViewersOwnNetworkAreToldApart() {
        for host in ["10.0.0.5", "192.168.1.20", "172.16.0.1", "172.31.255.1", "169.254.3.4", "127.0.0.1", "localhost",
                     "nas.local", "[fe80::1]", "fd12:3456::1", "::1"] {
            XCTAssertTrue(KeyframeStillService.isLocalHost(host), host)
        }
        for host in ["media.example.invalid", "172.32.0.1", "8.8.8.8", "192.169.1.1", "2001:db8::1", "fdserver.example.invalid", ""] {
            XCTAssertFalse(KeyframeStillService.isLocalHost(host), host)
        }
        XCTAssertFalse(KeyframeStillService.isLocalHost(nil))
    }

    func testDolbyVisionWithNoBasePictureEndsTheServiceWithoutAStill() async throws {
        for (name, info) in [("profile 5", Self.info(dolbyVisionProfile: 5, compatibility: 0)),
                             ("no keyframe index", Self.info(hasIndex: false))] {
            let rig = Rig()
            let reader = ScriptedReader(info: info)
            rig.reader = reader
            let service = try XCTUnwrap(rig.makeService(try Self.directSpec()), name)
            _ = service.request(atSourceTime: 96) { _, _ in XCTFail("no still: \(name)") }
            rig.playSteadily(service)
            try await waitUntil { service.isFinished }
            await service.shutdown()?.value
            await service.settle()
            XCTAssertTrue(service.isRuledOut, name)
            XCTAssertEqual(reader.asked.count, 0, name)
            XCTAssertEqual(reader.shutdowns, 1, name)
            XCTAssertEqual(service.holdings, .init(), name)
        }
    }

    // MARK: - Nothing before the first frame and steady play

    func testNothingIsMadeBeforeTheFirstFrameAndASpellOfSteadyPlay() async throws {
        let rig = Rig()
        let reader = ScriptedReader()
        rig.reader = reader
        var readersMade = 0
        let controller = try VividPlaybackController()
        let provider = VividScrubPreviewProvider(
            engine: controller.engine,
            makeReader: { _ in
                readersMade += 1
                return nil
            },
            stillSwitch: rig.switchRead, stills: rig.environment, expectsFrameReader: false,
            stillsWaitForMove: false)
        provider.stillPlayer = rig.player
        var latest: VividScrubPreviewProvider.Preview?
        provider.onPreview = { latest = $0 }

        provider.activate(try Self.directSpec(), startSourceTime: 600)
        provider.begin(atSourceTime: 96)
        provider.request(atSourceTime: 97)
        XCTAssertNil(provider.debugStillService, "activating makes nothing")
        XCTAssertEqual(rig.watchesMade, 0)
        XCTAssertEqual(rig.opens.value, 0)
        XCTAssertEqual(rig.stateAsks, 0)

        provider.playbackStarted()
        // The first frame's own turn reads the switch and nothing else: no
        // service, no observer, no timer, and the player isn't asked.
        XCTAssertNil(provider.debugStillService)
        XCTAssertEqual(rig.switchAsks, 1)
        XCTAssertEqual(rig.stateAsks, 0)
        XCTAssertEqual(rig.environmentsBuilt, 0)
        try await waitUntil { provider.debugStillService != nil }
        let service = try XCTUnwrap(provider.debugStillService)
        XCTAssertEqual(service.holdings, .init(observers: 3), "and then no monitor, reader or work until steady play")
        XCTAssertEqual(rig.watchesMade, 0)

        // The first tick only takes a sample, so four more seconds are
        // four seconds of steady play: not enough.
        for _ in 0..<5 { rig.advance(service) }
        await service.settle()
        XCTAssertEqual(rig.opens.value, 0, "no reader inside the first five seconds")
        XCTAssertEqual(reader.prepares, 0)

        // A stall starts the count again.
        rig.state?.unsettled = .buffering
        rig.advance(service)
        rig.state?.unsettled = nil
        for _ in 0..<5 { rig.advance(service) }
        await service.settle()
        XCTAssertEqual(rig.opens.value, 0)

        XCTAssertEqual(rig.watchesMade, 0, "the network monitor waits for steady play too")
        rig.advance(service)
        try await waitUntil { latest?.sourceTime == 97 }
        XCTAssertEqual(rig.opens.value, 1)
        XCTAssertEqual(rig.watchesMade, 1)
        XCTAssertEqual(rig.switchAsks, 1, "still the one read")
        XCTAssertEqual(reader.asked.map(\.time), [96], "the scrub that was waiting gets its keyframe")
        XCTAssertEqual(readersMade, 0, "no frame reader is expected here, so none is looked for")
        await provider.endSession()?.value
        await service.settle()
        XCTAssertEqual(reader.shutdowns, 1)
    }

    // MARK: - A real file

    func testALocalFileGivesTheKeyframeAtOrBeforeTheTargetAndThenAnswersFromTheCache() async throws {
        let rig = Rig()
        rig.state?.bufferedAheadSeconds = nil
        rig.opensRealFiles = true
        let spec = try VividLoadSpec(offlineURL: try Self.fixtureURL(Self.mp4), startPosition: 0, audioOnly: false)
        let service = try XCTUnwrap(rig.makeService(spec))
        rig.playSteadily(service)
        XCTAssertEqual(rig.watchesMade, 0, "a file on the device needs no network monitor")

        var delivered: [(image: CGImage?, time: Double)] = []
        guard case .unchanged = service.request(atSourceTime: 3.5, deliver: { delivered.append(($0, $1)) }) else {
            return XCTFail("nothing is held yet")
        }
        XCTAssertNil(service.cachedStill(forSourceTime: 3.5))
        try await waitUntil { !delivered.isEmpty }
        let still = try XCTUnwrap(delivered.first?.image)
        XCTAssertEqual(delivered.first?.time, 3.5)
        XCTAssertEqual(still.width, 320)
        // The fixture's corner square is green from two to four seconds.
        let pixel = try Self.pixel(of: still, x: 32, y: 32)
        XCTAssertTrue(pixel[1] > pixel[0] + 100 && pixel[1] > pixel[2] + 100, "\(pixel)")
        XCTAssertEqual(service.heldPositions, [1])

        // A target near it is answered in the same call, from the cache.
        XCTAssertTrue(service.cachedStill(forSourceTime: 3.9) === still)
        guard case .unchanged = service.request(atSourceTime: 3.9, deliver: { delivered.append(($0, $1)) }) else {
            return XCTFail("the still showing is still the right one")
        }
        service.clearTarget()
        guard case let .still(again) = service.request(atSourceTime: 3.9, deliver: { delivered.append(($0, $1)) }) else {
            return XCTFail("a new scrub at the same place is answered at once")
        }
        XCTAssertTrue(again === still)
        await service.settle()
        XCTAssertEqual(delivered.count, 1, "and nothing more was read for it")
        XCTAssertEqual(rig.opens.value, 1)
        XCTAssertNil(service.cachedStill(forSourceTime: 1.9), "never a still from after the target")
        XCTAssertTrue(rig.lines.contains { $0.hasPrefix("still viewer pos=1 ") && $0.contains("cache=miss") })
        XCTAssertTrue(rig.lines.contains { $0.hasPrefix("still viewer pos=1 ") && $0.contains("cache=hit") })

        await service.shutdown()?.value
        await service.settle()
        XCTAssertEqual(service.holdings, .init())
    }

    func testTheLastMatroskaCueIsNeverAskedFor() async throws {
        // The real file: its last keyframe, at six seconds, can't be read.
        let rig = Rig()
        rig.state?.bufferedAheadSeconds = nil
        rig.opensRealFiles = true
        let spec = try VividLoadSpec(offlineURL: try Self.fixtureURL(Self.matroska), startPosition: 0, audioOnly: false)
        let service = try XCTUnwrap(rig.makeService(spec))
        rig.playSteadily(service)
        var delivered: [CGImage?] = []
        _ = service.request(atSourceTime: 7.5) { image, _ in delivered.append(image) }
        try await waitUntil { !delivered.isEmpty }
        // Blue: the keyframe at four seconds, the nearest one that can be.
        let pixel = try Self.pixel(of: try XCTUnwrap(delivered.first ?? nil), x: 32, y: 32)
        XCTAssertTrue(pixel[2] > pixel[0] + 100 && pixel[2] > pixel[1] + 100, "\(pixel)")
        XCTAssertEqual(service.heldPositions, [2])
        await service.shutdown()?.value
        await service.settle()
        XCTAssertFalse(rig.lines.contains { $0.contains("lastCue") }, "it was never refused, because it was never asked for")

        // And read-ahead leaves it alone too.
        let other = Rig()
        let reader = ScriptedReader(seconds: 40, lastIsReadable: false)
        other.reader = reader
        other.state?.sourceTime = 30
        let filling = try XCTUnwrap(other.makeService(try Self.localNetworkSpec()))
        other.playSteadily(filling)
        // One keyframe for each ten seconds: those at or before 30, 20, 10
        // and 0. The points from 40 on all fall in the last cue.
        try await waitUntil { reader.asked.count == 4 }
        for _ in 0..<4 { other.advance(filling, seconds: 2, playing: false) }
        await filling.settle()
        XCTAssertEqual(reader.asked.map(\.time), [28, 20, 8, 0])
        _ = filling.request(atSourceTime: 39) { _, _ in }
        await filling.settle()
        XCTAssertEqual(reader.asked.map(\.time), [28, 20, 8, 0, 32], "the viewer gets the keyframe before the last cue")
        XCTAssertFalse(reader.asked.contains { $0.time == 36 }, "\(reader.asked)")
        await filling.shutdown()?.value
    }

    // MARK: - The honest window

    func testAStillIsOnlyShownFromAtOrBeforeTheTargetAndInsideTheWindow() async throws {
        let rig = Rig()
        rig.state?.bufferedAheadSeconds = nil
        let reader = ScriptedReader()
        rig.reader = reader
        let service = try XCTUnwrap(rig.makeService(try Self.directSpec()))
        rig.playSteadily(service)
        var delivered: [(image: CGImage?, time: Double)] = []
        let deliver: @MainActor (CGImage?, Double) -> Void = { delivered.append(($0, $1)) }

        // Hold the keyframe at 96 seconds, then stop the reader answering.
        _ = service.request(atSourceTime: 97, deliver: deliver)
        try await waitUntil { delivered.count == 1 }
        XCTAssertTrue(delivered[0].image === reader.image(24))
        service.clearTarget()
        reader.holds = true

        XCTAssertNotNil(service.cachedStill(forSourceTime: 96))
        XCTAssertNotNil(service.cachedStill(forSourceTime: 106), "ten seconds on, still honest")
        XCTAssertNil(service.cachedStill(forSourceTime: 106.5), "further than one preview interval")
        XCTAssertNil(service.cachedStill(forSourceTime: 95.9), "never a still from after the target")
        XCTAssertNil(service.cachedStill(forSourceTime: .nan))

        guard case .unchanged = service.request(atSourceTime: 130, deliver: deliver) else { return XCTFail("nothing to show at 130") }
        // The target jumps 50 seconds in a tenth of a second: 500 seconds a
        // second, so for now a still from up to 100 seconds back will do.
        rig.now += 0.1
        guard case let .still(wide) = service.request(atSourceTime: 180, deliver: deliver) else {
            return XCTFail("a fast move widens the window")
        }
        XCTAssertTrue(wide === reader.image(24))
        rig.now += 0.1
        guard case .cleared = service.request(atSourceTime: 230, deliver: deliver) else {
            return XCTFail("but not past what the move covers")
        }
        rig.now += 0.1
        guard case .still = service.request(atSourceTime: 180, deliver: deliver) else { return XCTFail("back inside") }

        // Once the target rests, the window is one interval again.
        rig.advance(service)
        XCTAssertEqual(delivered.count, 2)
        XCTAssertNil(delivered[1].image, "the far still is taken down")
        XCTAssertEqual(delivered[1].time, 180)
        reader.cancelHeld()
        await service.shutdown()?.value
        await service.settle()
    }

    // MARK: - One lane, newest first

    func testTheNewestTargetWinsAndAReadAlreadyRunningIsUsedIfItIsStillHonest() async throws {
        let rig = Rig()
        rig.state?.bufferedAheadSeconds = nil
        let reader = ScriptedReader()
        reader.holds = true
        rig.reader = reader
        let service = try XCTUnwrap(rig.makeService(try Self.directSpec()))
        rig.playSteadily(service)
        var delivered: [(image: CGImage?, time: Double)] = []
        let deliver: @MainActor (CGImage?, Double) -> Void = { delivered.append(($0, $1)) }

        _ = service.request(atSourceTime: 97, deliver: deliver)
        try await waitUntil { reader.asked.count == 1 }
        // The target moves on three times while that read is out. None of
        // those is asked for: only the newest will be.
        _ = service.request(atSourceTime: 400, deliver: deliver)
        _ = service.request(atSourceTime: 800, deliver: deliver)
        _ = service.request(atSourceTime: 101, deliver: deliver)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(reader.asked.map(\.time), [96], "one read at a time")
        XCTAssertTrue(delivered.isEmpty)

        // The read that was already running lands: four seconds before the
        // newest target, so it is shown for it.
        reader.release()
        try await waitUntil { delivered.count == 1 }
        XCTAssertTrue(delivered[0].image === reader.image(24))
        XCTAssertEqual(delivered[0].time, 101)
        // Then the newest target's own keyframe, and nothing for the two
        // it passed over.
        try await waitUntil { reader.asked.count == 2 }
        XCTAssertEqual(reader.asked.map(\.time), [96, 100])
        XCTAssertTrue(reader.asked.allSatisfy(\.urgent), "the viewer's reads are urgent")
        reader.release()
        try await waitUntil { delivered.count == 2 }
        XCTAssertTrue(delivered[1].image === reader.image(25))
        XCTAssertEqual(delivered[1].time, 101)
        await service.settle()
        XCTAssertEqual(reader.asked.count, 2)
        XCTAssertEqual(reader.superseded, 0)
        await service.shutdown()?.value
    }

    func testAReadThatLandsOutsideTheWindowIsKeptButNotShown() async throws {
        let rig = Rig()
        rig.state?.bufferedAheadSeconds = nil
        let reader = ScriptedReader()
        reader.holds = true
        rig.reader = reader
        let service = try XCTUnwrap(rig.makeService(try Self.directSpec()))
        rig.playSteadily(service)
        var delivered: [(image: CGImage?, time: Double)] = []
        _ = service.request(atSourceTime: 97) { delivered.append(($0, $1)) }
        try await waitUntil { reader.asked.count == 1 }
        rig.now += 5
        _ = service.request(atSourceTime: 900) { delivered.append(($0, $1)) }
        reader.release()
        try await waitUntil { reader.heldTimes == [900] }
        XCTAssertTrue(delivered.isEmpty, "a still from 96 seconds says nothing about 900")
        XCTAssertEqual(service.heldPositions, [24])
        reader.release()
        try await waitUntil { delivered.count == 1 }
        XCTAssertEqual(delivered[0].time, 900)
        await service.shutdown()?.value
        await service.settle()
    }

    func testFailuresAreRespected() async throws {
        // A read that fails in passing is not tried again until a wait is
        // over.
        let rig = Rig()
        rig.state?.bufferedAheadSeconds = nil
        let reader = ScriptedReader()
        reader.outcome = { _ in .transientFailure }
        rig.reader = reader
        let service = try XCTUnwrap(rig.makeService(try Self.directSpec()))
        rig.playSteadily(service)
        _ = service.request(atSourceTime: 97) { _, _ in XCTFail("nothing was read") }
        try await waitUntil { reader.asked.count == 1 }
        await service.settle()
        for _ in 0..<4 {
            rig.advance(service)
            _ = service.request(atSourceTime: 97) { _, _ in }
        }
        await service.settle()
        XCTAssertEqual(reader.asked.count, 1, "nothing inside the five-second wait")
        rig.advance(service, seconds: 2)
        try await waitUntil { reader.asked.count == 2 }
        await service.settle()
        XCTAssertFalse(service.isFinished)
        await service.shutdown()?.value

        // A file that keeps refusing is given up for the load.
        for refusal in [KeyframeStillResult.notPossible, .overLimit] {
            let rig = Rig()
            rig.state?.bufferedAheadSeconds = nil
            let reader = ScriptedReader()
            reader.outcome = { _ in refusal }
            rig.reader = reader
            let service = try XCTUnwrap(rig.makeService(try Self.directSpec()))
            rig.playSteadily(service)
            for time in [97.0, 97.5, 201] {
                _ = service.request(atSourceTime: time) { _, _ in }
                await service.settle()
            }
            XCTAssertEqual(reader.asked.map(\.time), [96, 92, 88],
                           "a refused keyframe isn't asked for twice, the one before it is tried, and three refusals end it")
            XCTAssertTrue(service.isFinished)
            XCTAssertTrue(service.isRuledOut)
            await service.shutdown()?.value
            XCTAssertEqual(reader.shutdowns, 1)
        }
    }

    // MARK: - Read-ahead

    func testReadAheadRunsOnlyWhileEveryConditionHoldsAndStopsAtOnce() async throws {
        typealias Unsettled = KeyframeStillService.PlayerState.Unsettled
        // `stops` marks the conditions that mean the player needs the
        // device or the connection to itself right now: a read that is
        // already out is stopped, not left to finish.
        let conditions: [(name: String, stops: Bool, spoil: (Rig) -> Void, mend: (Rig) -> Void)] = [
            ("buffering", true, { $0.state?.unsettled = .buffering }, { $0.state?.unsettled = nil }),
            ("loading", true, { $0.state?.unsettled = .loading }, { $0.state?.unsettled = nil }),
            ("seeking", false, { $0.state?.unsettled = .seeking }, { $0.state?.unsettled = nil }),
            ("replanning", true, { $0.state?.unsettled = .replanning }, { $0.state?.unsettled = nil }),
            ("recovering", true, { $0.state?.unsettled = .recovering }, { $0.state?.unsettled = nil }),
            ("changing quality", true, { $0.state?.unsettled = .changingQuality }, { $0.state?.unsettled = nil }),
            ("an error", true, { $0.state?.unsettled = .failed }, { $0.state?.unsettled = nil }),
            ("ended", true, { $0.state?.unsettled = .ended }, { $0.state?.unsettled = nil }),
            ("buffer low", false, { $0.state?.bufferedAheadSeconds = 19 }, { $0.state?.bufferedAheadSeconds = 40 }),
            ("no buffer telemetry", false, { $0.state?.bufferedAheadSeconds = nil }, { $0.state?.bufferedAheadSeconds = 40 }),
            ("not active", true, { $0.state?.isAppActive = false }, { $0.state?.isAppActive = true }),
            ("handed off", true, { $0.state?.isHandedOff = true }, { $0.state?.isHandedOff = false }),
            ("software decoding", true, { $0.state?.decodesInSoftware = true }, { $0.state?.decodesInSoftware = false }),
            ("decoding unknown", true, { $0.state?.decodesInSoftware = nil }, { $0.state?.decodesInSoftware = false }),
            ("mobile data", false, { $0.watch.allows = false }, { $0.watch.allows = true }),
            ("another load", true, { rig in rig.held = rig.state; rig.state = nil }, { rig in rig.state = rig.held }),
            ("no headers", false, { $0.headers = nil }, { $0.headers = [:] }),
        ]
        let rig = Rig()
        let reader = ScriptedReader()
        reader.holds = true
        rig.reader = reader
        let service = try XCTUnwrap(rig.makeService(try Self.directSpec()))

        // Before the spell of steady play: nothing, however healthy.
        for _ in 0..<5 { rig.advance(service) }
        await service.settle()
        XCTAssertEqual(rig.opens.value, 0)
        rig.advance(service)
        try await waitUntil { reader.asked.count == 1 }
        XCTAssertEqual(reader.asked.first?.urgent, false, "read-ahead is never urgent")

        XCTAssertEqual(service.sampleInterval, 0.25, "with a read out the gates are looked at four times a second")

        var expected = 1
        var cancels = 0
        for condition in conditions {
            // Spoilt while a read is running, and not one more starts.
            condition.spoil(rig)
            if condition.stops {
                // The read that is out is stopped at the next look, in
                // that call, not whenever a background task gets a turn.
                rig.advance(service, seconds: 0.25)
                cancels += 1
                XCTAssertEqual(reader.cancels, cancels, "stopped at once: \(condition.name)")
            } else {
                // Not a reason to break off a read: it finishes.
                rig.advance(service, seconds: 0.25)
                XCTAssertEqual(reader.cancels, cancels, "left to finish: \(condition.name)")
                reader.release()
            }
            try await waitUntil { reader.heldTimes.isEmpty }
            await service.settle()
            XCTAssertEqual(service.sampleInterval, 1)
            for _ in 0..<3 { rig.advance(service, seconds: 2) }
            await service.settle()
            XCTAssertEqual(reader.asked.count, expected, "no read while: \(condition.name)")
            condition.mend(rig)
            // The very next look reads again: a stopped read brought no
            // wait with it.
            rig.advance(service)
            expected += 1
            try await waitUntil { reader.asked.count == expected }
            XCTAssertEqual(reader.heldTimes.count, 1, "one read at a time: \(condition.name)")
        }
        XCTAssertFalse(rig.lines.contains { $0.contains("transient") })

        // A viewer's target takes the lane from read-ahead.
        _ = service.request(atSourceTime: 3000) { _, _ in }
        try await waitUntil { reader.asked.count == expected + 1 }
        XCTAssertEqual(reader.asked.last?.urgent, true)
        reader.release()
        reader.release()
        try await waitUntil { reader.heldTimes.isEmpty }
        await service.settle()
        XCTAssertEqual(reader.asked.count, expected + 1, "nothing is read ahead during a scrub")
        service.endScrub()

        // The switch going off ends it.
        rig.enabled = false
        rig.advance(service)
        XCTAssertTrue(service.isFinished)
        await service.shutdown()?.value
        await service.settle()
        XCTAssertEqual(reader.asked.count, expected + 1)
        XCTAssertEqual(service.holdings, .init())
    }

    func testReadAheadFillsNearThePlayheadFirstThenASparseLadderAtAPace() async throws {
        let rig = Rig()
        let reader = ScriptedReader()
        rig.reader = reader
        rig.state?.sourceTime = 594
        let service = try XCTUnwrap(rig.makeService(try Self.localNetworkSpec()))
        rig.playSteadily(service)
        // Steady play moved the playhead on to 600 seconds. One keyframe
        // for each ten seconds within two minutes either side (the file
        // has one every four) is read back to back, in one go.
        try await waitUntil { reader.asked.count >= 26 }
        await service.settle()
        let times = reader.asked.map(\.time)
        XCTAssertEqual(Array(times.prefix(7)), [600, 608, 588, 620, 580, 628, 568], "nearest first, ahead then behind")
        XCTAssertEqual(Set(times.prefix(25)), Set(stride(from: 480.0, through: 720, by: 10).map { ($0 / 4).rounded(.down) * 4 }))
        XCTAssertFalse(reader.asked.contains(where: \.urgent))
        // Then the ladder: one read, and no more until two seconds pass.
        XCTAssertEqual(times.count, 26)
        XCTAssertEqual(times[25], 300, "the five-minute point nearest the playhead")
        rig.advance(service, seconds: 1, playing: false)
        await service.settle()
        XCTAssertEqual(reader.asked.count, 26, "paced: not yet")
        rig.advance(service, seconds: 1, playing: false)
        try await waitUntil { reader.asked.count == 27 }
        await service.settle()
        XCTAssertEqual(reader.asked.count, 27, "one at a time")
        XCTAssertEqual(reader.asked[26].time, 900)

        var guardCount = 0
        while reader.asked.count < 25 + 23 + 24, guardCount < 200 {
            rig.advance(service, seconds: 2, playing: false)
            await service.settle()
            guardCount += 1
        }
        let ladder = reader.asked.dropFirst(25).map(\.time)
        XCTAssertEqual(ladder.count, 23 + 24)
        XCTAssertEqual(Set(ladder.prefix(23)), Set(stride(from: 0.0, to: 7200, by: 300)).subtracting([600]),
                       "every five minutes across the title")
        XCTAssertTrue(ladder.dropFirst(23).allSatisfy { ($0 - 148).truncatingRemainder(dividingBy: 300) == 0 },
                      "then the points halfway between: \(ladder.dropFirst(23))")
        XCTAssertEqual(ladder.dropFirst(23).first, 448, "again nearest the playhead first")
        for _ in 0..<3 {
            rig.advance(service, seconds: 2, playing: false)
            await service.settle()
        }
        XCTAssertEqual(reader.asked.count, 25 + 23 + 24, "and then it is done")
        XCTAssertEqual(Set(reader.asked.map(\.time)).count, reader.asked.count, "nothing is read twice")
        await service.shutdown()?.value
        await service.settle()
    }

    func testReadAheadKeepsToItsByteBudget() async throws {
        // 100 MB on a far server: one per cent, 1 MB. Each still costs
        // 300,000 bytes, so three fit: one near the playhead, which may
        // take half the budget, and two points of the ladder.
        let megabyte: Int64 = 1_000_000
        let cases: [(name: String, spec: VividLoadSpec, size: Int64?, bytes: Int, reads: Int)] = [
            ("far server", try Self.directSpec(), 100 * megabyte, 300_000, 3),
            ("the viewer's own network", try Self.localNetworkSpec(), 100 * megabyte, 300_000, 6),
            // One per cent would be 10 GB. The fixed limit is 60 MB.
            ("a far server's fixed limit", try Self.directSpec(), 1_000_000 * megabyte, 10_000_000, 6),
            ("length unknown", try Self.directSpec(), nil, 300_000, 0),
        ]
        for item in cases {
            let rig = Rig()
            let reader = ScriptedReader()
            reader.bytesPerStill = item.bytes
            rig.reader = reader
            rig.fileSize.value = item.size
            let service = try XCTUnwrap(rig.makeService(item.spec), item.name)
            rig.playSteadily(service)
            try await waitUntil { rig.opens.value == 1 }
            for _ in 0..<8 {
                rig.advance(service, seconds: 2, playing: false)
                await service.settle()
            }
            XCTAssertEqual(reader.asked.count, item.reads, item.name)
            XCTAssertEqual(service.readAheadSpent, item.reads * item.bytes, item.name)
            XCTAssertEqual(service.nearSpent, item.reads / 2 * item.bytes, "\(item.name): the stretch near the playhead took half")
            XCTAssertLessThanOrEqual(service.readAheadSpent, 60 * 1024 * 1024, item.name)

            // The budget belongs to the title: a reload of the same file
            // starts where this load left off.
            let carry = service.carry
            await service.shutdown()?.value
            guard item.reads == 3 else { continue }
            let next = Rig()
            let nextReader = ScriptedReader()
            nextReader.bytesPerStill = 300_000
            next.reader = nextReader
            next.fileSize.value = item.size
            let again = try XCTUnwrap(next.makeService(item.spec, carried: carry))
            next.playSteadily(again)
            try await waitUntil { next.opens.value == 1 }
            for _ in 0..<5 {
                next.advance(again, seconds: 2, playing: false)
                await again.settle()
            }
            XCTAssertEqual(nextReader.asked.count, 0, "the title's budget is already spent")
            await again.shutdown()?.value
            XCTAssertTrue(next.lines.contains { $0.hasPrefix("summary end=loadEnded ") && $0.contains("ahead_bytes=900000 budget=1000000") })
        }
    }

    // MARK: - Headers

    func testTheLoadsCurrentHeadersAreTakenBeforeEveryRead() async throws {
        let rig = Rig()
        rig.state?.bufferedAheadSeconds = nil
        rig.headers = ["Authorization": "first"]
        let reader = ScriptedReader()
        rig.reader = reader
        let service = try XCTUnwrap(rig.makeService(try Self.directSpec()))
        rig.playSteadily(service)
        XCTAssertEqual(rig.headerAsks, 0, "nothing is asked for until something is read")
        var delivered = 0
        _ = service.request(atSourceTime: 97) { _, _ in delivered += 1 }
        try await waitUntil { delivered == 1 }
        // Once to make the reader, once to open the file, once for the still.
        XCTAssertEqual(rig.headerAsks, 3)
        XCTAssertEqual(reader.headersSeen, [["Authorization": "first"]])

        // The player renews its token. The next read goes out with it.
        rig.headers = ["Authorization": "second"]
        _ = service.request(atSourceTime: 201) { _, _ in delivered += 1 }
        try await waitUntil { delivered == 2 }
        XCTAssertEqual(rig.headerAsks, 4)
        XCTAssertEqual(reader.headersSeen.last, ["Authorization": "second"])
        XCTAssertEqual(rig.headerURLs, Set([try Self.directSpec().sourceURL]), "asked for the load's own address")
        await service.shutdown()?.value
        await service.settle()
    }

    func testStillsOverHTTPReadTheOriginalAddressWithTheLoadsHeaders() async throws {
        let file = try Data(contentsOf: try Self.fixtureURL(Self.mp4))
        StillRangeStub.serve(file)
        let rig = Rig()
        rig.state?.bufferedAheadSeconds = nil
        rig.headers = ["X-Emby-Token": "token-one"]
        rig.openOverride = { url, headers in
            let source = HTTPStillByteSource(url: url, session: StillRangeStub.session(), headers: { headers.current })
            return KeyframeStillSource(reader: KeyframeStillReader(source: source), fileSize: { source.size },
                                       receivedBytes: { source.counters.bytes })
        }
        let spec = try Self.directSpec()
        let service = try XCTUnwrap(rig.makeService(spec))
        rig.playSteadily(service)
        var delivered: [CGImage?] = []
        _ = service.request(atSourceTime: 5) { image, _ in delivered.append(image) }
        try await waitUntil { !delivered.isEmpty }
        let pixel = try Self.pixel(of: try XCTUnwrap(delivered.first ?? nil), x: 32, y: 32)
        XCTAssertTrue(pixel[2] > pixel[0] + 100 && pixel[2] > pixel[1] + 100, "blue, the keyframe at four seconds: \(pixel)")
        let requests = StillRangeStub.requests()
        XCTAssertFalse(requests.isEmpty)
        for request in requests {
            XCTAssertEqual(request.url, spec.sourceURL, "the load's own http address, never the player's internal one")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Emby-Token"), "token-one")
            XCTAssertNotNil(request.value(forHTTPHeaderField: "Range"))
        }
        await service.shutdown()?.value
        await service.settle()
    }

    // MARK: - Lifetime

    func testEndingTheSessionLeavesNothingBehind() async throws {
        let rig = Rig()
        let reader = ScriptedReader()
        reader.holds = true
        rig.reader = reader
        let service = try XCTUnwrap(rig.makeService(try Self.directSpec()))
        XCTAssertEqual(service.holdings, .init(observers: 3))
        rig.playSteadily(service)
        try await waitUntil { reader.asked.count == 1 }
        XCTAssertTrue(service.holdings.hasReader)
        XCTAssertTrue(service.holdings.hasNetworkWatch)
        var delivered = 0
        _ = service.request(atSourceTime: 97) { _, _ in delivered += 1 }

        let closing = service.shutdown()
        XCTAssertEqual(reader.cancels, 1, "the read that was out is stopped in the call that ends the service")
        XCTAssertTrue(service.isFinished)
        XCTAssertFalse(service.isRuledOut)
        await closing?.value
        await service.settle()
        XCTAssertEqual(service.holdings, .init(), "no reader, timer, monitor, observer or work in flight")
        XCTAssertEqual(reader.shutdowns, 1)
        XCTAssertTrue(rig.watch.isCancelled)
        XCTAssertEqual(delivered, 0)
        XCTAssertNil(service.cachedStill(forSourceTime: 97))
        let asked = reader.asked.count
        rig.advance(service)
        _ = service.request(atSourceTime: 201) { _, _ in delivered += 1 }
        await service.settle()
        XCTAssertEqual(reader.asked.count, asked, "nothing is read after the end")
        XCTAssertEqual(rig.lines.filter { $0.hasPrefix("summary ") }.count, 1)
    }

    func testEndingTheSessionWhileTheSourceIsMadeWaitsForItsReader() async throws {
        let rig = Rig()
        let reader = ScriptedReader()
        let release = DispatchSemaphore(value: 0)
        rig.openOverride = { _, _ in
            _ = release.wait(timeout: .now() + 10)
            return KeyframeStillSource(reader: reader, fileSize: { 10_000_000_000 })
        }
        let service = try XCTUnwrap(rig.makeService(try Self.directSpec()))
        rig.playSteadily(service)
        try await waitUntil { rig.opens.value == 1 }
        let closing = service.shutdown()
        XCTAssertNotNil(closing, "the source still being made is part of the wait")
        release.signal()
        await closing?.value
        XCTAssertEqual(reader.shutdowns, 1, "its reader is shut down before the wait ends")
        XCTAssertEqual(reader.prepares, 0, "and the file is never read")
        await service.settle()
    }

    func testTheFileIsNotReadWhenPlaybackStopsBeingSettledWhileTheSourceIsMade() async throws {
        let rig = Rig()
        let reader = ScriptedReader()
        let release = DispatchSemaphore(value: 0)
        rig.openOverride = { _, _ in
            _ = release.wait(timeout: .now() + 10)
            return KeyframeStillSource(reader: reader, fileSize: { 10_000_000_000 })
        }
        let service = try XCTUnwrap(rig.makeService(try Self.directSpec()))
        rig.playSteadily(service)
        try await waitUntil { rig.opens.value == 1 }
        rig.state?.unsettled = .buffering
        release.signal()
        try await waitUntil { service.holdings.hasReader }
        await service.settle()
        XCTAssertEqual(reader.prepares, 0, "the header and index wait for playback to settle")
        rig.state?.unsettled = nil
        rig.advance(service)
        try await waitUntil { reader.prepares == 1 }
        await service.shutdown()?.value
        await service.settle()
    }

    func testTheRealTimerStopsWithTheService() async throws {
        let rig = Rig()
        rig.startsTicker = true
        let service = try XCTUnwrap(rig.makeService(try Self.directSpec()))
        XCTAssertTrue(service.holdings.hasTicker)
        await service.shutdown()?.value
        XCTAssertEqual(service.holdings, .init())
    }

    func testGoingToTheBackgroundShutsTheReaderAndComingBackNeedsNoNewSpellOfSteadyPlay() async throws {
        let rig = Rig()
        rig.state?.bufferedAheadSeconds = nil
        let reader = ScriptedReader()
        rig.reader = reader
        let service = try XCTUnwrap(rig.makeService(try Self.directSpec()))
        rig.playSteadily(service)
        var delivered: [CGImage?] = []
        _ = service.request(atSourceTime: 97) { image, _ in delivered.append(image) }
        try await waitUntil { delivered.count == 1 }
        XCTAssertEqual(service.heldPositions, [24])
        reader.holds = true
        _ = service.request(atSourceTime: 201) { image, _ in delivered.append(image) }
        try await waitUntil { reader.heldTimes == [200] }

        rig.centre.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        XCTAssertEqual(reader.cancels, 1, "the read that was out is stopped there and then")
        XCTAssertFalse(service.isFinished, "the service stays, with what it knows")
        XCTAssertTrue(service.isSuspended)
        await service.settle()
        try await waitUntil { reader.shutdowns == 1 }
        XCTAssertEqual(service.holdings, .init(observers: 3), "no reader, stills, timer or monitor in the background")
        XCTAssertTrue(rig.watch.isCancelled)
        // Nothing happens in the background, whatever is asked.
        rig.advance(service)
        guard case .unchanged = service.request(atSourceTime: 97, deliver: { image, _ in delivered.append(image) }) else {
            return XCTFail("nothing in the background")
        }
        await service.settle()
        XCTAssertEqual(rig.opens.value, 1)

        // Back again, paused and scrubbing straight away: steady play can't
        // be counted now, and doesn't need to be.
        let next = ScriptedReader()
        rig.reader = next
        rig.centre.post(name: UIApplication.willEnterForegroundNotification, object: nil)
        XCTAssertFalse(service.isSuspended)
        rig.state?.isPlaying = false
        rig.state?.unsettled = .seeking
        let before = delivered.count
        _ = service.request(atSourceTime: 97) { image, _ in delivered.append(image) }
        try await waitUntil { delivered.count == before + 1 }
        XCTAssertTrue(delivered.last.flatMap { $0 } === next.image(24))
        XCTAssertEqual(rig.opens.value, 2, "a new reader, opened without waiting")
        XCTAssertFalse(rig.lines.contains { $0.hasPrefix("summary ") })

        await service.shutdown()?.value
        await service.settle()
        XCTAssertEqual(service.holdings, .init())
        XCTAssertEqual(next.shutdowns, 1)
        XCTAssertEqual(rig.lines.filter { $0.hasPrefix("summary end=loadEnded ") }.count, 1)
    }

    func testAMemoryWarningDropsTheStillsAndTheDecoderButKeepsTheReader() async throws {
        let rig = Rig()
        rig.state?.bufferedAheadSeconds = nil
        let reader = ScriptedReader()
        rig.reader = reader
        let service = try XCTUnwrap(rig.makeService(try Self.directSpec()))
        rig.playSteadily(service)
        var delivered = 0
        _ = service.request(atSourceTime: 97) { _, _ in delivered += 1 }
        try await waitUntil { delivered == 1 }
        await service.settle()
        XCTAssertEqual(service.holdings.heldStills, 2, "decoded, and packed as a JPEG")

        rig.centre.post(name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
        try await waitUntil { service.holdings.heldStills == 0 }
        XCTAssertEqual(reader.decoderCloses, 1)
        XCTAssertTrue(service.holdings.hasReader)
        XCTAssertFalse(service.isFinished)
        XCTAssertNil(service.cachedStill(forSourceTime: 97))

        // The same keyframe can be had again.
        service.clearTarget()
        _ = service.request(atSourceTime: 97) { _, _ in delivered += 1 }
        try await waitUntil { delivered == 2 }
        XCTAssertEqual(reader.asked.map(\.time), [96, 96])
        XCTAssertEqual(reader.prepares, 1, "without opening the file again")
        await service.shutdown()?.value
        await service.settle()
    }

    func testAReadAheadStartedBeforeAMemoryWarningDoesNotRefillTheCache() async throws {
        let rig = Rig()
        let reader = ScriptedReader()
        reader.holds = true
        reader.bytesPerStill = 300_000
        rig.reader = reader
        rig.fileSize.value = 100_000_000
        let service = try XCTUnwrap(rig.makeService(try Self.directSpec()))
        rig.playSteadily(service)
        try await waitUntil { rig.opens.value == 1 }
        for _ in 0..<4 where reader.asked.isEmpty {
            rig.advance(service, seconds: 2, playing: false)
            await service.settle()
        }
        try await waitUntil { reader.heldTimes.count == 1 }
        rig.centre.post(name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
        reader.release()
        try await waitUntil { service.readAheadSpent == 300_000 }
        XCTAssertEqual(service.holdings.heldStills, 0, "the warning's empty cache stays empty")
        XCTAssertTrue(rig.lines.contains { $0.hasPrefix("still ahead ") }, "the read itself still counts")
        await service.shutdown()?.value
        await service.settle()
    }

    func testTimesAreMovedOntoTheReadersAxisWhenTheVideoStartsLate() async throws {
        let rig = Rig()
        rig.state?.bufferedAheadSeconds = nil
        var facts = Self.info()
        facts.videoStartOffset = 2
        let reader = ScriptedReader(info: facts)
        rig.reader = reader
        let service = try XCTUnwrap(rig.makeService(try Self.directSpec()))
        rig.playSteadily(service)
        var delivered = 0
        // Asked before the file is open, when the offset isn't known yet.
        _ = service.request(atSourceTime: 305) { _, _ in delivered += 1 }
        try await waitUntil { delivered == 1 }
        XCTAssertEqual(reader.asked.map(\.time), [300], "305 s on the player's clock is 303 s into the video")
        await service.shutdown()?.value
        await service.settle()
    }

    func testTheDecoderIsClosedOnceAScrubHasBeenOverForAMoment() async throws {
        let rig = Rig()
        rig.state?.bufferedAheadSeconds = nil
        let reader = ScriptedReader()
        rig.reader = reader
        let service = try XCTUnwrap(rig.makeService(try Self.directSpec()))
        rig.playSteadily(service)
        var delivered = 0
        _ = service.request(atSourceTime: 97) { _, _ in delivered += 1 }
        try await waitUntil { delivered == 1 }
        for _ in 0..<5 { rig.advance(service) }
        XCTAssertEqual(reader.decoderCloses, 0, "not while the scrub is going on")
        service.endScrub()
        rig.advance(service, seconds: 2)
        XCTAssertEqual(reader.decoderCloses, 0, "not straight away")
        rig.advance(service, seconds: 2)
        XCTAssertEqual(reader.decoderCloses, 1)
        for _ in 0..<5 { rig.advance(service) }
        XCTAssertEqual(reader.decoderCloses, 1, "once")
        XCTAssertEqual(reader.shutdowns, 0, "the reader stays for the load")
        XCTAssertTrue(service.holdings.hasReader)
        await service.shutdown()?.value
        await service.settle()
    }

    func testTheMeasurementLinesCarryNumbersOnly() async throws {
        let rig = Rig()
        rig.headers = ["Authorization": "Bearer secret-token"]
        rig.state?.droppedFrames = 7
        rig.state?.avSyncGapMilliseconds = 1.5
        let reader = ScriptedReader(seconds: 120)
        rig.reader = reader
        rig.state?.sourceTime = 54
        let spec = try Self.localNetworkSpec()
        let service = try XCTUnwrap(rig.makeService(spec))
        rig.playSteadily(service)
        try await waitUntil { reader.asked.count == 13 }
        await service.settle()
        var delivered = 0
        _ = service.request(atSourceTime: 50) { _, _ in delivered += 1 }
        try await waitUntil { delivered == 1 }
        service.endScrub()
        for _ in 0..<4 { rig.advance(service, seconds: 2, playing: false) }
        await service.shutdown()?.value
        await service.settle()

        XCTAssertTrue(rig.lines.contains("burst begin drops=7 buffer=40.0 avsync=1.5"), "\(rig.lines.prefix(6))")
        XCTAssertTrue(rig.lines.contains("burst end drops=7 buffer=40.0 avsync=1.5"))
        XCTAssertEqual(rig.lines.filter { $0.hasPrefix("still ahead ") && $0.contains("cache=miss drops=7 buffer=40.0 avsync=1.5") }.count, 13)
        XCTAssertTrue(rig.lines.contains { $0.hasPrefix("still viewer pos=12 bytes=0 reads=0 keyframe=0 ms=0 cache=hit") })
        let summary = try XCTUnwrap(rig.lines.last)
        XCTAssertTrue(summary.hasPrefix("summary end=loadEnded served=1 hits=1 hit_rate=100 stills=13 ahead_bytes=13000 "), summary)
        XCTAssertTrue(summary.contains("first_still_ms=") && summary.hasSuffix("failures=none"), summary)
        let host = try XCTUnwrap(spec.sourceURL.host)
        for line in rig.lines {
            XCTAssertFalse(line.contains(host) || line.contains("http") || line.contains("secret") || line.contains("stream.mkv"), line)
        }
    }

    // MARK: - In the provider

    func testAFrameReaderThatWorksKeepsTheLoad() async throws {
        let rig = Rig()
        let image = try XCTUnwrap(ScriptedReader.picture(level: 90))
        let frames = FrameReader(image: image, canRead: true)
        let controller = try VividPlaybackController()
        let provider = VividScrubPreviewProvider(engine: controller.engine, makeReader: { _ in frames },
                                                 stillSwitch: rig.switchRead, stills: rig.environment, expectsFrameReader: true,
            stillsWaitForMove: false)
        provider.stillPlayer = rig.player
        var latest: VividScrubPreviewProvider.Preview?
        provider.onPreview = { latest = $0 }
        provider.activate(try Self.directSpec())
        provider.playbackStarted()
        try await waitUntil { provider.debugStillService != nil }
        let service = try XCTUnwrap(provider.debugStillService)
        XCTAssertTrue(service.isStandingBy, "the frame reader is tried first where there is one")
        rig.playSteadily(service)
        provider.begin(atSourceTime: 15)
        try await waitUntil { latest?.sourceTime == 15 }
        XCTAssertTrue(latest?.image === image)
        XCTAssertTrue(service.isStandingBy, "and while it works the service only ever counted steady play")
        XCTAssertTrue(service.hasSteadyPlay)
        XCTAssertEqual(service.holdings, .init(observers: 3), "with its timer stopped once that was counted")
        XCTAssertEqual(frames.questions, 0)
        XCTAssertEqual(rig.watchesMade, 0)
        XCTAssertEqual(rig.opens.value, 0)
        await provider.endSession()?.value
    }

    func testAFrameReaderThatCannotReadTheFileHandsTheLoadOver() async throws {
        let rig = Rig()
        rig.state?.bufferedAheadSeconds = nil
        let reader = ScriptedReader()
        rig.reader = reader
        let frames = FrameReader(image: nil, canRead: false)
        var readersMade = 0
        let controller = try VividPlaybackController()
        let provider = VividScrubPreviewProvider(
            engine: controller.engine,
            makeReader: { _ in
                readersMade += 1
                return frames
            },
            stillSwitch: rig.switchRead, stills: rig.environment, expectsFrameReader: true,
            stillsWaitForMove: false)
        provider.stillPlayer = rig.player
        var latest: VividScrubPreviewProvider.Preview?
        provider.onPreview = { latest = $0 }
        provider.activate(try Self.directSpec())
        provider.playbackStarted()
        // Steady play is counted from the first frame, while the frame
        // reader still has the load, so the first scrub doesn't have to
        // wait for a spell of it that can't happen during a scrub.
        try await waitUntil { provider.debugStillService != nil }
        let service = try XCTUnwrap(provider.debugStillService)
        XCTAssertTrue(service.isStandingBy)
        rig.playSteadily(service)
        XCTAssertEqual(rig.opens.value, 0, "standing by, it opens nothing")
        rig.state?.isPlaying = false
        rig.state?.unsettled = .seeking
        provider.begin(atSourceTime: 97)
        try await waitUntil { latest?.sourceTime == 97 }
        XCTAssertFalse(service.isStandingBy)
        XCTAssertEqual(frames.thumbnails, 1)
        XCTAssertEqual(frames.questions, 1)
        XCTAssertEqual(frames.shutdowns, 1)
        XCTAssertTrue(latest?.image === reader.image(24))

        // The scrub ends and another begins: the same service, the same
        // reader, and no second try at the frame reader.
        provider.endInteraction()
        XCTAssertNil(latest)
        provider.begin(atSourceTime: 98)
        XCTAssertEqual(latest?.sourceTime, 98, "answered in the same call, from the cache")
        XCTAssertTrue(provider.debugStillService === service)
        XCTAssertEqual(readersMade, 1)
        XCTAssertEqual(rig.opens.value, 1)
        XCTAssertEqual(reader.shutdowns, 0)
        await provider.endSession()?.value
        await service.settle()
        XCTAssertEqual(reader.shutdowns, 1)
        XCTAssertEqual(service.holdings, .init())
    }

    func testServerSheetsWinAndAnEmptySheetListLetsTheServiceIn() async throws {
        let rig = Rig()
        let controller = try VividPlaybackController()
        let provider = VividScrubPreviewProvider(
            engine: controller.engine,
            makeStore: { ScrubPreviewSheetStore(sheets: $0, session: StillRangeStub.session()) },
            makeReader: { _ in nil }, stillSwitch: rig.switchRead, stills: rig.environment, expectsFrameReader: false,
            stillsWaitForMove: false)
        provider.stillPlayer = rig.player
        let sheets = try XCTUnwrap(ScrubPreviewSheets(
            key: "k", intervalMilliseconds: 10_000, columns: 4, rows: 2, thumbnailCount: 8,
            sheetURLs: [Self.address("/sheets/0.jpg")], headers: [:], expiresAt: nil))
        var loads = 0
        provider.activate(try Self.directSpec(), sheets: .init(key: "k") {
            loads += 1
            return sheets
        })
        provider.playbackStarted()
        XCTAssertNil(provider.debugStillService, "not while the sheet list is on its way")
        try await waitUntil { loads == 1 }
        await Task.yield()
        XCTAssertNil(provider.debugStillService, "and not once the server has sheets")
        XCTAssertEqual(rig.watchesMade, 0)
        await provider.endSession()?.value

        provider.activate(try Self.directSpec(), sheets: .init(key: "none") { nil })
        provider.playbackStarted()
        XCTAssertNil(provider.debugStillService)
        try await waitUntil { provider.debugStillService != nil }
        let service = try XCTUnwrap(provider.debugStillService)
        XCTAssertFalse(service.isStandingBy)
        await provider.endSession()?.value
        XCTAssertNil(provider.debugStillService)
        XCTAssertTrue(service.isFinished)
    }

    func testAStillFromAnOldLoadNeverPublishes() async throws {
        let rig = Rig()
        rig.state?.bufferedAheadSeconds = nil
        let reader = ScriptedReader()
        reader.holds = true
        // Even a reader that answers after it was told to stop.
        reader.answersWhenShutDown = true
        rig.reader = reader
        let controller = try VividPlaybackController()
        let provider = VividScrubPreviewProvider(engine: controller.engine, makeReader: { _ in nil },
                                                 stillSwitch: rig.switchRead, stills: rig.environment, expectsFrameReader: false,
            stillsWaitForMove: false)
        provider.stillPlayer = rig.player
        var previews: [VividScrubPreviewProvider.Preview] = []
        provider.onPreview = { if let preview = $0 { previews.append(preview) } }
        provider.activate(try Self.directSpec())
        provider.playbackStarted()
        provider.begin(atSourceTime: 97)
        // The service is made a turn after the first frame, and takes the
        // scrub that is already going.
        try await waitUntil { provider.debugStillService != nil }
        let first = try XCTUnwrap(provider.debugStillService)
        rig.playSteadily(first)
        try await waitUntil { reader.asked.count == 1 }

        // The next load begins while that read is still running.
        let nextReader = ScriptedReader()
        rig.reader = nextReader
        provider.activate(try Self.directSpec())
        XCTAssertTrue(first.isFinished)
        XCTAssertNil(provider.debugStillService, "and the new load has nothing until its own first frame")
        await provider.endSession(keepingSheets: true)?.value
        await first.settle()
        XCTAssertEqual(reader.shutdowns, 1)
        XCTAssertEqual(reader.answeredLate, 1)
        XCTAssertTrue(previews.isEmpty, "the old load's still went nowhere")

        // A scrub superseded inside one load is fenced the same way.
        provider.activate(try Self.directSpec())
        provider.playbackStarted()
        nextReader.holds = true
        provider.begin(atSourceTime: 97)
        try await waitUntil { provider.debugStillService != nil }
        let second = try XCTUnwrap(provider.debugStillService)
        rig.playSteadily(second)
        try await waitUntil { nextReader.asked.count == 1 }
        provider.endInteraction()
        nextReader.release()
        await second.settle()
        XCTAssertTrue(previews.isEmpty)
        XCTAssertEqual(second.heldPositions, [24], "though the still is kept for the next scrub")
        await provider.endSession()?.value
    }

    // MARK: - The player comes first

    func testAGateClosingStopsAViewersReadAtOnceAndThatIsNotAFailure() async throws {
        let rig = Rig()
        rig.state?.bufferedAheadSeconds = nil
        let reader = ScriptedReader()
        reader.holds = true
        // Even a read that loses the race and comes back as a failure.
        reader.stoppedResult = .transientFailure
        rig.reader = reader
        let service = try XCTUnwrap(rig.makeService(try Self.directSpec()))
        rig.playSteadily(service)
        var delivered: [(image: CGImage?, time: Double)] = []
        let deliver: @MainActor (CGImage?, Double) -> Void = { delivered.append(($0, $1)) }
        _ = service.request(atSourceTime: 97, deliver: deliver)
        try await waitUntil { reader.heldTimes == [96] }
        XCTAssertEqual(service.sampleInterval, 0.25)

        // The picture goes to an AirPlay receiver. The very next scrub
        // request sees it, with no tick in between, and stops the read in
        // that call.
        rig.state?.isHandedOff = true
        _ = service.request(atSourceTime: 98, deliver: deliver)
        XCTAssertEqual(reader.cancels, 1)
        try await waitUntil { reader.heldTimes.isEmpty }
        await service.settle()
        XCTAssertFalse(service.isFinished)

        // Back again, and the keyframe is asked for straight away: the
        // stopped read brought no wait.
        rig.state?.isHandedOff = false
        rig.advance(service, seconds: 0.25)
        _ = service.request(atSourceTime: 97, deliver: deliver)
        try await waitUntil { reader.heldTimes == [96] }
        XCTAssertEqual(reader.asked.count, 2)

        // The player starts buffering. The tick stops the read, the target
        // stays, and nothing is read for it until playback has settled.
        rig.state?.unsettled = .buffering
        rig.advance(service, seconds: 0.25)
        XCTAssertEqual(reader.cancels, 2)
        try await waitUntil { reader.heldTimes.isEmpty }
        await service.settle()
        for _ in 0..<3 {
            rig.advance(service)
            await service.settle()
        }
        XCTAssertEqual(reader.asked.count, 2)
        XCTAssertTrue(delivered.isEmpty)
        reader.holds = false
        rig.state?.unsettled = nil
        rig.advance(service)
        try await waitUntil { delivered.count == 1 }
        XCTAssertEqual(delivered[0].time, 97, "the target that was waiting is answered once playback settles")
        XCTAssertEqual(reader.asked.count, 3)
        await service.shutdown()?.value
        await service.settle()
        XCTAssertTrue(try XCTUnwrap(rig.lines.last).hasSuffix("failures=none"), "\(rig.lines.last ?? "")")
        XCTAssertEqual(rig.lines.filter { $0.hasPrefix("stop ") }, ["stop handedOff reads=1 open=0", "stop buffering reads=1 open=0"])
    }

    func testAGateClosingStopsAnOpenThatIsRunningAndTheFileIsOpenedAgainLater() async throws {
        let rig = Rig()
        rig.state?.bufferedAheadSeconds = nil
        let reader = ScriptedReader()
        reader.holdsPrepare = true
        rig.reader = reader
        let service = try XCTUnwrap(rig.makeService(try Self.directSpec()))
        rig.playSteadily(service)
        var delivered = 0
        _ = service.request(atSourceTime: 97) { _, _ in delivered += 1 }
        try await waitUntil { reader.prepares == 1 }
        XCTAssertEqual(service.sampleInterval, 0.25)

        rig.state?.unsettled = .loading
        rig.advance(service, seconds: 0.25)
        XCTAssertEqual(reader.cancels, 1)
        await service.settle()
        XCTAssertFalse(service.isFinished)

        reader.holdsPrepare = false
        rig.state?.unsettled = nil
        rig.advance(service, seconds: 0.25)
        try await waitUntil { delivered == 1 }
        XCTAssertEqual(reader.prepares, 2, "opened again at the next look, with no wait")
        XCTAssertEqual(rig.opens.value, 1, "by the reader it already had")
        await service.shutdown()?.value
        await service.settle()
        XCTAssertTrue(try XCTUnwrap(rig.lines.last).hasSuffix("failures=none"))
    }

    func testWhilePlaybackIsUnsettledAScrubIsAnsweredOnlyFromWhatIsHeld() async throws {
        typealias Unsettled = KeyframeStillService.PlayerState.Unsettled
        let rig = Rig()
        rig.state?.bufferedAheadSeconds = nil
        let reader = ScriptedReader()
        rig.reader = reader
        let service = try XCTUnwrap(rig.makeService(try Self.directSpec()))
        rig.playSteadily(service)
        var delivered: [(image: CGImage?, time: Double)] = []
        let deliver: @MainActor (CGImage?, Double) -> Void = { delivered.append(($0, $1)) }

        // No reader yet, and the player is buffering: none is opened.
        rig.state?.unsettled = .buffering
        _ = service.request(atSourceTime: 97, deliver: deliver)
        rig.advance(service)
        await service.settle()
        XCTAssertEqual(rig.opens.value, 0, "no file is opened for a scrub while the player is buffering")
        // Settled, with the target still the current one: now it is.
        rig.state?.unsettled = nil
        rig.advance(service)
        try await waitUntil { delivered.count == 1 }
        XCTAssertEqual(reader.asked.map(\.time), [96])

        for unsettled in [Unsettled.buffering, .loading, .replanning, .recovering, .changingQuality, .failed, .ended] {
            service.clearTarget()
            rig.state?.unsettled = unsettled
            guard case let .still(held) = service.request(atSourceTime: 98, deliver: deliver) else {
                return XCTFail("a still already held is still shown: \(unsettled)")
            }
            XCTAssertTrue(held === reader.image(24))
            guard case .cleared = service.request(atSourceTime: 301, deliver: deliver) else {
                return XCTFail("nothing held for it: \(unsettled)")
            }
            rig.advance(service)
            await service.settle()
            XCTAssertEqual(reader.asked.count, 1, "and nothing is read for it: \(unsettled)")
        }

        // Seeking is what a scrub itself reports, so it holds nothing up.
        rig.state?.unsettled = .seeking
        _ = service.request(atSourceTime: 301, deliver: deliver)
        try await waitUntil { reader.asked.count == 2 }
        XCTAssertEqual(reader.asked.last?.time, 300)
        XCTAssertEqual(reader.cancels, 0)
        await service.shutdown()?.value
        await service.settle()
    }

    func testTheCarryKeyKeepsTheFileVersionAndDropsTokens() {
        func key(_ address: String) -> String { KeyframeStillService.carryKey(for: URL(string: address)!) }
        XCTAssertEqual(key("https://media.example.invalid/Videos/1/stream?Static=true&MediaSourceId=a&api_key=secret#t"),
                       "https://media.example.invalid/Videos/1/stream?MediaSourceId=a")
        XCTAssertNotEqual(key("https://media.example.invalid/Videos/1/stream?MediaSourceId=a&PlaySessionId=x"),
                          key("https://media.example.invalid/Videos/1/stream?MediaSourceId=b&PlaySessionId=x"),
                          "two versions of one title don't share a budget")
        XCTAssertEqual(key("https://media.example.invalid/Videos/1/stream?MediaSourceId=a&PlaySessionId=x"),
                       key("https://media.example.invalid/Videos/1/stream?PlaySessionId=y&MediaSourceId=a"))
        XCTAssertEqual(key("https://media.example.invalid/a.mkv?token=secret"), "https://media.example.invalid/a.mkv")
    }

    func testThePlayersStateIsMappedOneCaseAtATime() {
        typealias Snapshot = KeyframeStillService.PlayerSnapshot
        func state(_ change: (inout Snapshot) -> Void) -> KeyframeStillService.PlayerState {
            var snapshot = Snapshot(sourceTime: 42, isPlaying: true, bufferedAheadSeconds: 31, videoDecoder: "hevc (VideoToolbox)",
                                    droppedFrames: 3, avSyncGapMilliseconds: 1.5)
            change(&snapshot)
            return KeyframeStillService.playerState(from: snapshot)
        }
        XCTAssertEqual(state { _ in }, .init(sourceTime: 42, isPlaying: true, unsettled: nil, bufferedAheadSeconds: 31,
                                             isAppActive: true, isHandedOff: false, decodesInSoftware: false,
                                             droppedFrames: 3, avSyncGapMilliseconds: 1.5))
        XCTAssertEqual(state { $0.hasError = true }.unsettled, .failed)
        XCTAssertEqual(state { $0.hasReachedEnd = true }.unsettled, .ended)
        XCTAssertEqual(state { $0.isReplanning = true }.unsettled, .replanning)
        XCTAssertEqual(state { $0.isRecovering = true }.unsettled, .recovering)
        XCTAssertEqual(state { $0.isChangingQuality = true }.unsettled, .changingQuality)
        XCTAssertEqual(state { $0.isSeeking = true }.unsettled, .seeking)
        XCTAssertEqual(state { $0.isLoading = true }.unsettled, .loading)
        XCTAssertEqual(state { $0.isBuffering = true }.unsettled, .buffering)
        // With several at once, the gravest is the one reported.
        let flags: [(WritableKeyPath<Snapshot, Bool>, KeyframeStillService.PlayerState.Unsettled)] = [
            (\.hasError, .failed), (\.hasReachedEnd, .ended), (\.isReplanning, .replanning), (\.isRecovering, .recovering),
            (\.isChangingQuality, .changingQuality), (\.isLoading, .loading), (\.isBuffering, .buffering), (\.isSeeking, .seeking),
        ]
        for first in flags.indices {
            let reported = state { snapshot in
                for flag in flags[first...] { snapshot[keyPath: flag.0] = true }
            }
            XCTAssertEqual(reported.unsettled, flags[first].1)
        }
        // Seeking never hides loading or buffering, which stop the viewer's reads.
        XCTAssertEqual(state { $0.isSeeking = true; $0.isBuffering = true }.unsettled, .buffering)
        XCTAssertEqual(state { $0.isSeeking = true; $0.isLoading = true }.unsettled, .loading)
        // Only seeking lets the viewer's own reads go on.
        for unsettled in flags.map(\.1) {
            XCTAssertEqual(unsettled.stopsViewerReads, unsettled != .seeking, "\(unsettled)")
        }

        XCTAssertTrue(state { $0.isAirPlayHandOff = true }.isHandedOff)
        XCTAssertTrue(state { $0.isPictureInPicture = true }.isHandedOff)
        XCTAssertFalse(state { $0.isAppActive = false }.isAppActive)
        XCTAssertNil(state { $0.videoDecoder = nil }.decodesInSoftware, "not known until the engine says")
        XCTAssertEqual(state { $0.videoDecoder = "hevc" }.decodesInSoftware, true)
        XCTAssertEqual(state { $0.videoDecoder = "h264 (videotoolbox-copy)" }.decodesInSoftware, false)
        XCTAssertNil(state { $0.bufferedAheadSeconds = nil }.bufferedAheadSeconds)
        XCTAssertFalse(state { $0.isPlaying = false }.isPlaying)
    }

    // MARK: - Bounds

    func testADamagedIndexIsRefusedAndNoWalkDependsOnWhatTheFileSays() async throws {
        func entries(_ times: [Double]) -> [KeyframeIndexEntry] {
            times.map { KeyframeIndexEntry(time: $0, bytePosition: 0, size: nil, isReadable: true) }
        }
        XCTAssertNotNil(KeyframeStillService.usableIndex(entries([0, 4, 8, 8]), duration: 7200))
        XCTAssertNotNil(KeyframeStillService.usableIndex(entries([0, 4]), duration: nil))
        for duration in [3.0e13, .infinity, .nan, -1] {
            XCTAssertNil(KeyframeStillService.usableIndex(entries([0, 4]), duration: duration), "\(duration)")
        }
        for times in [[0, 4, 3.0e13], [0, 8, 4], [0, .nan], [-1, 4], [0, .infinity]] {
            XCTAssertNil(KeyframeStillService.usableIndex(entries(times), duration: 7200), "\(times)")
        }
        // The shim keeps one entry past its 400,000 limit so a longer index
        // arrives here too long, never cut short. A fixture with that many
        // keyframes would run to many megabytes, so the edge is checked here.
        XCTAssertNotNil(KeyframeStillService.usableIndex(entries(Array(repeating: 1, count: 400_000)), duration: 7200))
        XCTAssertNil(KeyframeStillService.usableIndex(entries(Array(repeating: 1, count: 400_001)), duration: 7200))

        // One cue a million years out, or cues out of order: the file gets
        // no stills, and nothing is asked of it.
        for times in [[0, 4, 8, 3.0e13], [0, 8, 4]] {
            let rig = Rig()
            let reader = ScriptedReader(times: times, duration: 7200)
            rig.reader = reader
            let service = try XCTUnwrap(rig.makeService(try Self.localNetworkSpec()))
            rig.playSteadily(service)
            try await waitUntil { service.isFinished }
            XCTAssertTrue(service.isRuledOut)
            XCTAssertEqual(reader.asked.count, 0)
            await service.shutdown()?.value
            await service.settle()
            XCTAssertTrue(rig.lines.contains { $0.hasPrefix("summary end=badIndex ") })
        }

        // A file that is all keyframes: 8,000 of them in under seven
        // minutes. Near the playhead it is still one for each ten seconds,
        // and the ladder is the one point not already held.
        let rig = Rig()
        let reader = ScriptedReader(times: (0..<8_000).map { Double($0) * 0.05 }, duration: 400)
        rig.reader = reader
        rig.state?.sourceTime = 194
        let service = try XCTUnwrap(rig.makeService(try Self.localNetworkSpec()))
        rig.playSteadily(service)
        for _ in 0..<6 {
            rig.advance(service, seconds: 2, playing: false)
            await service.settle()
        }
        XCTAssertEqual(reader.asked.count, 26, "25 near the playhead and the start of the file")
        XCTAssertEqual(Set(reader.asked.map(\.time)).count, 26)
        XCTAssertEqual(reader.asked.last?.time, 0)
        await service.shutdown()?.value
        await service.settle()
    }

    /// The app goes to the background while a read ahead is part way
    /// through a block and a viewer read waits behind it. Every byte of the
    /// read ahead counts, including those landing while the reader stops,
    /// and none of the viewer's do. A carry taken before the reader stopped
    /// sees them too, so the next load of the file doesn't spend them again.
    func testBytesStillArrivingWhenTheReaderStopsAreCountedForTheTitle() async throws {
        let rig = Rig()
        let reader = ScriptedReader()
        reader.fetchedPerStill = 0
        reader.holds = true
        rig.reader = reader
        rig.fileSize.value = 100_000_000
        let service = try XCTUnwrap(rig.makeService(try Self.directSpec()))
        rig.playSteadily(service)
        try await waitUntil { rig.opens.value == 1 }
        for _ in 0..<4 where reader.asked.isEmpty {
            rig.advance(service, seconds: 2, playing: false)
            await service.settle()
        }
        try await waitUntil { reader.asked.count == 1 }
        reader.addFetched(250_000)
        _ = service.request(atSourceTime: 3000) { _, _ in }
        try await waitUntil { reader.asked.count == 2 }
        let carry = service.carry
        reader.fetchedWhenStopped = 50_000
        rig.centre.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        try await waitUntil { !service.holdings.hasReader }
        await service.shutdown()?.value
        XCTAssertEqual(service.readAheadSpent, 300_000)
        XCTAssertEqual(service.nearSpent, 300_000, "it was a read near the playhead")
        XCTAssertEqual(carry.readAheadBytes, 300_000)
        XCTAssertEqual(carry.nearBytes, 300_000)

        // The next load of the same file starts from there.
        let next = Rig()
        next.reader = ScriptedReader()
        let again = try XCTUnwrap(next.makeService(try Self.directSpec(), carried: carry))
        XCTAssertEqual(again.readAheadSpent, 300_000)
        await again.shutdown()?.value
    }

    func testAViewerReadFromBeforeAMemoryWarningIsDroppedOnceTheScrubHasEnded() async throws {
        let rig = Rig()
        rig.state?.bufferedAheadSeconds = nil
        let reader = ScriptedReader()
        reader.holds = true
        rig.reader = reader
        let service = try XCTUnwrap(rig.makeService(try Self.directSpec()))
        rig.playSteadily(service)
        _ = service.request(atSourceTime: 97) { _, _ in }
        try await waitUntil { reader.heldTimes.count == 1 }
        rig.centre.post(name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
        service.endScrub()
        reader.release()
        try await waitUntil { rig.lines.contains { $0.hasPrefix("still viewer ") } }
        XCTAssertEqual(service.holdings.heldStills, 0, "nothing is left to show it, so it isn't kept")
        await service.shutdown()?.value
        await service.settle()
    }

    func testTheBudgetCountsWhatTheSourceFetchedNotWhatTheReaderWasHanded() async throws {
        // 100 MB on a far server: 1 MB to spend. The reader is handed
        // 1,000 bytes for each still, but the source fetched 300,000.
        let rig = Rig()
        let reader = ScriptedReader()
        reader.fetchedPerStill = 300_000
        rig.reader = reader
        rig.fileSize.value = 100_000_000
        let service = try XCTUnwrap(rig.makeService(try Self.directSpec()))
        rig.playSteadily(service)
        try await waitUntil { rig.opens.value == 1 }
        for _ in 0..<8 {
            rig.advance(service, seconds: 2, playing: false)
            await service.settle()
        }
        XCTAssertEqual(reader.asked.count, 3)
        XCTAssertEqual(service.readAheadSpent, 900_000)
        XCTAssertEqual(service.nearSpent, 300_000)
        XCTAssertTrue(rig.lines.contains { $0.hasPrefix("still ahead ") && $0.contains(" bytes=1000 fetched=300000 ") })
        // The viewer's own reads are counted the same way, and never
        // against the budget.
        var delivered = 0
        _ = service.request(atSourceTime: 3000) { _, _ in delivered += 1 }
        try await waitUntil { delivered == 1 }
        XCTAssertEqual(service.readAheadSpent, 900_000)
        await service.shutdown()?.value
        await service.settle()
        XCTAssertTrue(try XCTUnwrap(rig.lines.last).contains(" viewer_bytes=300000 "))

        // An ordinary film, 2 GB on a far server, with half a megabyte
        // fetched for each still: the stretch near the playhead stops at
        // half the 20 MB, and the ladder across the title gets the rest.
        let film = Rig()
        let filmReader = ScriptedReader()
        filmReader.fetchedPerStill = 512 * 1024
        film.reader = filmReader
        film.fileSize.value = 2_000_000_000
        let filling = try XCTUnwrap(film.makeService(try Self.directSpec()))
        film.playSteadily(filling)
        for _ in 0..<40 {
            film.advance(filling, seconds: 2, playing: false)
            await filling.settle()
        }
        let times = filmReader.asked.map(\.time)
        XCTAssertEqual(times.count, 38)
        XCTAssertTrue(times.prefix(19).allSatisfy { abs($0 - 606) <= 120 }, "\(times.prefix(19))")
        XCTAssertTrue(times.dropFirst(19).allSatisfy { abs($0 - 606) > 120 }, "the ladder is reached: \(times.dropFirst(19))")
        XCTAssertLessThanOrEqual(filling.nearSpent, 10_000_000)
        XCTAssertLessThanOrEqual(filling.readAheadSpent, 20_000_000)
        await filling.shutdown()?.value
        await filling.settle()
    }

    func testReadAheadStartsAtAHealthyBufferAndStopsOnlyAtALowOne() async throws {
        let rig = Rig()
        rig.state?.bufferedAheadSeconds = 25
        let reader = ScriptedReader()
        reader.holds = true
        rig.reader = reader
        let service = try XCTUnwrap(rig.makeService(try Self.directSpec()))
        rig.playSteadily(service)
        for _ in 0..<2 { rig.advance(service) }
        await service.settle()
        XCTAssertEqual(rig.opens.value, 0, "25 seconds is not enough to start on")

        rig.state?.bufferedAheadSeconds = 30
        rig.advance(service)
        try await waitUntil { reader.asked.count == 1 }
        // Once started, it goes on through a dip that stays above 20.
        rig.state?.bufferedAheadSeconds = 25
        reader.release()
        try await waitUntil { reader.asked.count == 2 }
        // Below 20 it stops.
        rig.state?.bufferedAheadSeconds = 19.9
        reader.release()
        try await waitUntil { reader.heldTimes.isEmpty }
        for _ in 0..<2 { rig.advance(service) }
        await service.settle()
        XCTAssertEqual(reader.asked.count, 2)
        // And 25 no longer starts it again.
        rig.state?.bufferedAheadSeconds = 25
        for _ in 0..<2 { rig.advance(service) }
        await service.settle()
        XCTAssertEqual(reader.asked.count, 2)
        rig.state?.bufferedAheadSeconds = 30
        rig.advance(service)
        try await waitUntil { reader.asked.count == 3 }
        await service.shutdown()?.value
        await service.settle()
    }

    func testAWideWindowIsLookedAtAgainJustAfterTheTargetStops() async throws {
        let rig = Rig()
        rig.state?.bufferedAheadSeconds = nil
        let gate = Gate()
        let slept = Shared<[TimeInterval]>([])
        rig.sleep = { seconds in
            slept.value += [seconds]
            await gate.wait()
        }
        let reader = ScriptedReader()
        rig.reader = reader
        let service = try XCTUnwrap(rig.makeService(try Self.directSpec()))
        rig.playSteadily(service)
        var delivered: [(image: CGImage?, time: Double)] = []
        let deliver: @MainActor (CGImage?, Double) -> Void = { delivered.append(($0, $1)) }
        _ = service.request(atSourceTime: 97, deliver: deliver)
        try await waitUntil { delivered.count == 1 }
        service.clearTarget()
        reader.holds = true

        // A slow start, then 50 seconds in a tenth of a second: the still
        // from 84 seconds back will do while the target moves like that.
        _ = service.request(atSourceTime: 130, deliver: deliver)
        XCTAssertFalse(service.holdings.hasWindowCheck, "nothing to look at again while the window is the usual one")
        rig.now += 0.1
        guard case .still = service.request(atSourceTime: 180, deliver: deliver) else { return XCTFail("a fast move widens the window") }
        XCTAssertTrue(service.holdings.hasWindowCheck)
        try await waitUntil { gate.waiting == 1 }
        XCTAssertEqual(slept.value.count, 1)
        XCTAssertEqual(slept.value[0], 0.55, accuracy: 0.051, "just after the rate goes stale")

        // The target stops there. No further request comes and no tick
        // either: the one look that was arranged takes the far still down.
        rig.now += 0.6
        gate.open()
        try await waitUntil { delivered.count == 2 }
        XCTAssertNil(delivered[1].image)
        XCTAssertEqual(delivered[1].time, 180)
        XCTAssertFalse(service.holdings.hasWindowCheck)
        reader.cancelHeld()
        await service.shutdown()?.value
        await service.settle()
    }

    // MARK: - Lifetime, continued

    func testAServiceLetGoWithoutShutdownLeavesNothingBehind() async throws {
        let rig = Rig()
        let reader = ScriptedReader()
        reader.holds = true
        rig.reader = reader
        var service = rig.makeService(try Self.directSpec())
        rig.playSteadily(try XCTUnwrap(service))
        try await waitUntil { reader.asked.count == 1 }
        weak var released = service
        service = nil
        XCTAssertNil(released)
        XCTAssertEqual(reader.cancels, 1, "the read that was out is stopped")
        XCTAssertTrue(rig.watch.isCancelled)
        try await waitUntil { reader.shutdowns == 1 }
        // Its observers went with it.
        rig.centre.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        rig.centre.post(name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
        XCTAssertEqual(reader.decoderCloses, 0)
    }

    // MARK: - In the provider, continued

    func testEndingTheSessionNeverWaitsForTheFrameReadersAnswer() async throws {
        let rig = Rig()
        let frames = FrameReader(image: nil, canRead: false)
        let gate = Gate()
        frames.answerGate = gate
        let controller = try VividPlaybackController()
        let provider = VividScrubPreviewProvider(engine: controller.engine, makeReader: { _ in frames },
                                                 stillSwitch: rig.switchRead, stills: rig.environment, expectsFrameReader: true,
                                                 stillsWaitForMove: false)
        provider.stillPlayer = rig.player
        provider.activate(try Self.directSpec())
        provider.playbackStarted()
        provider.begin(atSourceTime: 97)
        // The reader gave no still and is being asked whether it can read
        // the file at all, which can wait on an asset load.
        try await waitUntil { gate.waiting == 1 }
        XCTAssertEqual(frames.questions, 1)

        // The session ends, and what it hands back finishes with the
        // question still unanswered.
        await provider.endSession()?.value
        XCTAssertEqual(gate.waiting, 1)
        XCTAssertEqual(frames.shutdowns, 1)

        // The late answer goes nowhere.
        gate.open()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertNil(provider.debugStillService)
        XCTAssertEqual(rig.opens.value, 0)
    }

    func testWhereAStillWaitsForTheSelectionToMoveNothingIsReadUntilItDoes() async throws {
        let rig = Rig()
        rig.state?.bufferedAheadSeconds = nil
        let reader = ScriptedReader()
        rig.reader = reader
        let controller = try VividPlaybackController()
        // As on Apple TV, where the still isn't shown until then.
        let provider = VividScrubPreviewProvider(engine: controller.engine, makeReader: { _ in nil },
                                                 stillSwitch: rig.switchRead, stills: rig.environment, expectsFrameReader: false,
                                                 stillsWaitForMove: true)
        provider.stillPlayer = rig.player
        var latest: VividScrubPreviewProvider.Preview?
        provider.onPreview = { latest = $0 }
        provider.activate(try Self.directSpec())
        provider.playbackStarted()
        try await waitUntil { provider.debugStillService != nil }
        let service = try XCTUnwrap(provider.debugStillService)
        rig.playSteadily(service)
        await service.settle()

        provider.begin(atSourceTime: 97)
        provider.request(atSourceTime: 97)
        rig.advance(service)
        await service.settle()
        XCTAssertEqual(rig.opens.value, 0, "a scrub that hasn't moved opens nothing")
        XCTAssertEqual(reader.asked.count, 0)

        provider.request(atSourceTime: 101)
        try await waitUntil { latest?.sourceTime == 101 }
        XCTAssertEqual(reader.asked.map(\.time), [100])
        // Back where it began. It has moved now, so that is read too.
        provider.request(atSourceTime: 97)
        try await waitUntil { latest?.sourceTime == 97 }
        XCTAssertEqual(reader.asked.map(\.time), [100, 96])
        await provider.endSession()?.value
        await service.settle()
    }

    // MARK: - Helpers

    private func waitUntil(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<1500 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTFail("timed out", file: file, line: line)
        // Stops the test here, before a line that counts on the condition.
        throw WaitTimedOut()
    }

    private struct WaitTimedOut: Error {}

    private static func address(_ path: String, host: String = "media.example.invalid") -> URL {
        URL(string: "https://\(host)\(path)")!
    }

    /// Emby or Jellyfin direct play of the stored file.
    private static func directSpec() throws -> VividLoadSpec {
        try VividLoadSpec(directURL: address("/Videos/1/stream.mkv?Static=true&MediaSourceId=1"), headers: [:],
                          startPosition: 0, audioOnly: false)
    }

    private static func localNetworkSpec() throws -> VividLoadSpec {
        try VividLoadSpec(directURL: address("/Videos/1/stream.mkv?Static=true&MediaSourceId=1", host: "192.168.1.20:8096"),
                          headers: [:], startPosition: 0, audioOnly: false)
    }

    private static func fixtureURL(_ name: String) throws -> URL {
        let parts = name.split(separator: ".").map(String.init)
        return try XCTUnwrap(Bundle(for: KeyframeStillServiceTests.self).url(forResource: parts[0], withExtension: parts[1]), name)
    }

    nonisolated static func info(dolbyVisionProfile: Int? = nil, compatibility: Int = 1, hasIndex: Bool = true,
                     duration: Double = 7200, keyframes: Int = 1800) -> KeyframeStillInfo {
        KeyframeStillInfo(
            duration: duration, startTime: 0, codedWidth: 1920, codedHeight: 1080, sampleAspectNumerator: 1,
            sampleAspectDenominator: 1, rotationDegrees: 0, codecName: "hevc", bitDepth: 10, transfer: .pq,
            primaries: .bt2020, matrix: .bt2020, range: .limited, dolbyVisionProfile: dolbyVisionProfile,
            dolbyVisionCompatibility: compatibility, hasKeyframeIndex: hasIndex, keyframeCount: keyframes, bytesReadToOpen: 0)
    }

    /// The red, green and blue of one pixel, counting from the top left.
    private static func pixel(of image: CGImage, x: Int, y: Int) throws -> [Int] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let width = image.width, height = image.height
        try bytes.withUnsafeMutableBytes { raw in
            let context = try XCTUnwrap(CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                                  bytesPerRow: width * 4, space: try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)),
                                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        let start = (y * width + x) * 4
        return [Int(bytes[start]), Int(bytes[start + 1]), Int(bytes[start + 2])]
    }
}

// MARK: - Stand-ins

/// The player and the outside world as the service sees them, with every
/// part a value the test sets.
@MainActor
private final class Rig {
    var enabled = true
    var machine = "AppleTV14,1"
    var now: TimeInterval = 1_000
    var state: KeyframeStillService.PlayerState? = .init(
        sourceTime: 600, isPlaying: true, unsettled: nil, bufferedAheadSeconds: 40, isAppActive: true,
        isHandedOff: false, decodesInSoftware: false, droppedFrames: 0, avSyncGapMilliseconds: 0)
    var held: KeyframeStillService.PlayerState?
    var headers: [String: String]? = [:]
    var stateAsks = 0
    var switchAsks = 0
    var environmentsBuilt = 0
    /// Stands in for the wait before a wide window is looked at again.
    /// Nil returns at once.
    var sleep: (@Sendable (TimeInterval) async -> Void)?
    var headerAsks = 0
    var headerURLs: Set<URL> = []
    var watchesMade = 0
    var startsTicker = false
    var opensRealFiles = false
    var lines: [String] = []
    let watch = Watch()
    let centre = NotificationCenter()
    let opens = Count()
    let fileSize = Shared<Int64?>(10_000_000_000)
    private let readerBox = Shared<ScriptedReader?>(nil)
    /// What the next reader opened will be.
    var reader: ScriptedReader? {
        get { readerBox.value }
        set { readerBox.value = newValue }
    }
    var openOverride: (@Sendable (URL, KeyframeStillHeaders) -> KeyframeStillSource?)?

    var player: KeyframeStillService.Player {
        KeyframeStillService.Player(
            state: { [unowned self] in
                stateAsks += 1
                return state
            },
            headers: { [unowned self] url in
                headerAsks += 1
                headerURLs.insert(url)
                return headers
            })
    }

    /// The hidden switch as the provider reads it.
    var switchRead: @MainActor () -> Bool {
        { [unowned self] in
            switchAsks += 1
            return enabled
        }
    }

    var environment: KeyframeStillService.Environment {
        environmentsBuilt += 1
        var environment = KeyframeStillService.Environment()
        environment.sleep = sleep ?? { _ in }
        environment.isEnabled = { [unowned self] in enabled }
        environment.machineIdentifier = machine
        environment.uptime = { [unowned self] in now }
        let opens = opens, fileSize = fileSize, readerBox = readerBox, override = openOverride, real = opensRealFiles
        environment.open = { url, headers in
            opens.add()
            if let override { return override(url, headers) }
            if real { return KeyframeStillService.openSource(url, headers) }
            guard let reader = readerBox.value else { return nil }
            reader.headers = headers
            var received: (@Sendable () -> Int)?
            if reader.countsFetched { received = { reader.fetched } }
            return KeyframeStillSource(reader: reader, fileSize: { fileSize.value }, receivedBytes: received)
        }
        environment.makeNetworkWatch = { [unowned self] in
            watchesMade += 1
            return watch
        }
        environment.startsTicker = startsTicker
        environment.notifications = centre
        environment.record = { [unowned self] in lines.append($0) }
        return environment
    }

    func makeService(_ spec: VividLoadSpec, carried: KeyframeStillService.Carry? = nil,
                     standingBy: Bool = false) -> KeyframeStillService? {
        KeyframeStillService.makeIfEligible(for: spec, hasServerSheets: false, player: player, environment: environment,
                                            carried: carried, standingBy: standingBy)
    }

    /// Moves the clock on, and the playhead with it while playing.
    func advance(_ service: KeyframeStillService? = nil, seconds: TimeInterval = 1, playing: Bool = true) {
        now += seconds
        if playing, state?.isPlaying == true, state?.unsettled == nil { state?.sourceTime += seconds }
        service?.tick()
    }

    /// One sample and then five seconds of play: the spell a reader waits
    /// for.
    func playSteadily(_ service: KeyframeStillService) {
        for _ in 0..<6 { advance(service) }
    }
}

private final class Watch: KeyframeStillNetworkWatch {
    var allows = true
    private(set) var isCancelled = false

    var allowsReadAhead: Bool { allows }

    func cancel() {
        isCancelled = true
    }
}

private final class Count: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int { lock.withLock { count } }

    func add() {
        lock.withLock { count += 1 }
    }
}

private final class Shared<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var held: Value

    init(_ value: Value) {
        held = value
    }

    var value: Value {
        get { lock.withLock { held } }
        set { lock.withLock { held = newValue } }
    }
}

/// A frame reader like the iPhone and iPad one, which gives a fixed answer.
@MainActor
private final class FrameReader: ScrubStillSource {
    private let image: CGImage?
    private let canRead: Bool
    private(set) var thumbnails = 0
    private(set) var questions = 0
    private(set) var shutdowns = 0

    init(image: CGImage?, canRead: Bool) {
        self.image = image
        self.canRead = canRead
    }

    func thumbnail(at transportTime: Double, maxWidth: Int) async -> CGImage? {
        thumbnails += 1
        return image
    }

    /// Set to hold the answer back, as a slow asset load would.
    var answerGate: Gate?

    func canProduceStills() async -> Bool {
        questions += 1
        await answerGate?.wait()
        return canRead
    }

    func shutdown() async {
        shutdowns += 1
    }
}

/// A keyframe reader with a made-up index: a keyframe every four seconds.
/// It records what it is asked and can hold its answers back, with one
/// read running and one waiting, as the real reader does.
private final class ScriptedReader: KeyframeStillReading, @unchecked Sendable {
    private let lock = NSLock()
    private let entries: [KeyframeIndexEntry]
    private let facts: KeyframeStillInfo?
    private var isOpen = false
    private var isShutDown = false
    private var requests: [(time: Double, urgent: Bool)] = []
    private var waiting: [(time: Double, continuation: CheckedContinuation<KeyframeStillResult, Never>)] = []
    private var pictures: [Int: CGImage] = [:]
    private var seen: [[String: String]] = []
    private var counts = (prepares: 0, decoderCloses: 0, shutdowns: 0, superseded: 0, late: 0, cancels: 0)
    private var settings = (holds: false, bytes: 1_000, answersWhenShutDown: false)
    private var opening: [CheckedContinuation<KeyframeStillInfo?, Never>] = []
    private var extras = (holdsPrepare: false, fetchedPerStill: nil as Int?, fetchedTotal: 0,
                          stoppedResult: KeyframeStillResult.cancelled)
    private var script: (@Sendable (Int) -> KeyframeStillResult)?
    private var lateBytes = 0
    private var box: KeyframeStillHeaders?

    init(seconds: Double = 7200, lastIsReadable: Bool = true, info: KeyframeStillInfo? = nil) {
        let count = Int(seconds / 4)
        entries = (0..<count).map {
            KeyframeIndexEntry(time: Double($0) * 4, bytePosition: Int64($0) * 1_000_000 + 4_096, size: nil,
                               isReadable: lastIsReadable || $0 < count - 1)
        }
        facts = info ?? KeyframeStillServiceTests.info(duration: seconds, keyframes: count)
    }

    /// A reader with exactly this index.
    init(times: [Double], duration: Double) {
        entries = times.enumerated().map {
            KeyframeIndexEntry(time: $0.element, bytePosition: Int64($0.offset) * 100_000 + 4_096, size: nil, isReadable: true)
        }
        facts = KeyframeStillServiceTests.info(duration: duration, keyframes: times.count)
    }

    /// Holds the opening of the file back until `releasePrepare()`.
    var holdsPrepare: Bool {
        get { lock.withLock { extras.holdsPrepare } }
        set { lock.withLock { extras.holdsPrepare = newValue } }
    }

    /// What the source fetches for each still, where that is more than the
    /// reader is handed. Nil for a source that doesn't count it.
    var fetchedPerStill: Int? {
        get { lock.withLock { extras.fetchedPerStill } }
        set { lock.withLock { extras.fetchedPerStill = newValue } }
    }

    var countsFetched: Bool { lock.withLock { extras.fetchedPerStill != nil } }

    /// Bytes the source fetched for a read that hasn't finished.
    func addFetched(_ bytes: Int) {
        lock.withLock { extras.fetchedTotal += bytes }
    }

    /// Bytes that land once the reader is told to stop, before it has.
    var fetchedWhenStopped: Int {
        get { lock.withLock { lateBytes } }
        set { lock.withLock { lateBytes = newValue } }
    }
    var fetched: Int { lock.withLock { extras.fetchedTotal } }

    /// How a read that is told to stop ends. The real reader says
    /// `.cancelled`; a failure here stands for one that lost the race.
    var stoppedResult: KeyframeStillResult {
        get { lock.withLock { extras.stoppedResult } }
        set { lock.withLock { extras.stoppedResult = newValue } }
    }

    var cancels: Int { lock.withLock { counts.cancels } }

    func cancel() {
        lock.lock()
        counts.cancels += 1
        extras.fetchedTotal += lateBytes
        lateBytes = 0
        // A reader that answers late ignores being told to stop.
        guard !settings.answersWhenShutDown else { return lock.unlock() }
        let stale = waiting
        waiting = []
        let openers = opening
        opening = []
        let result = extras.stoppedResult
        lock.unlock()
        stale.forEach { $0.continuation.resume(returning: result) }
        openers.forEach { $0.resume(returning: nil) }
    }

    func releasePrepare() {
        let openers = lock.withLock { () -> [CheckedContinuation<KeyframeStillInfo?, Never>] in
            defer { opening = [] }
            isOpen = true
            return opening
        }
        openers.forEach { $0.resume(returning: facts) }
    }

    var holds: Bool {
        get { lock.withLock { settings.holds } }
        set { lock.withLock { settings.holds = newValue } }
    }

    var bytesPerStill: Int {
        get { lock.withLock { settings.bytes } }
        set { lock.withLock { settings.bytes = newValue } }
    }

    var answersWhenShutDown: Bool {
        get { lock.withLock { settings.answersWhenShutDown } }
        set { lock.withLock { settings.answersWhenShutDown = newValue } }
    }

    var outcome: (@Sendable (Int) -> KeyframeStillResult)? {
        get { lock.withLock { script } }
        set { lock.withLock { script = newValue } }
    }

    var headers: KeyframeStillHeaders? {
        get { lock.withLock { box } }
        set { lock.withLock { box = newValue } }
    }

    var asked: [(time: Double, urgent: Bool)] { lock.withLock { requests } }
    var heldTimes: [Double] { lock.withLock { waiting.map(\.time) } }
    var headersSeen: [[String: String]] { lock.withLock { seen } }
    var prepares: Int { lock.withLock { counts.prepares } }
    var decoderCloses: Int { lock.withLock { counts.decoderCloses } }
    var shutdowns: Int { lock.withLock { counts.shutdowns } }
    var superseded: Int { lock.withLock { counts.superseded } }
    var answeredLate: Int { lock.withLock { counts.late } }

    var info: KeyframeStillInfo? { lock.withLock { isOpen ? facts : nil } }
    var index: [KeyframeIndexEntry] { lock.withLock { isOpen ? entries : [] } }

    func prepare() async -> KeyframeStillInfo? {
        await withCheckedContinuation { continuation in
            lock.lock()
            counts.prepares += 1
            if extras.holdsPrepare {
                opening.append(continuation)
                lock.unlock()
                return
            }
            isOpen = true
            lock.unlock()
            continuation.resume(returning: facts)
        }
    }

    func result(at seconds: Double, maxWidth: Int, urgent: Bool) async -> KeyframeStillResult {
        await withCheckedContinuation { continuation in
            lock.lock()
            requests.append((seconds, urgent))
            if let box { seen.append(box.current) }
            if isShutDown {
                lock.unlock()
                continuation.resume(returning: .cancelled)
                return
            }
            guard settings.holds else {
                let result = made(at: seconds)
                lock.unlock()
                continuation.resume(returning: result)
                return
            }
            var replaced: CheckedContinuation<KeyframeStillResult, Never>?
            if waiting.count >= 2 {
                replaced = waiting.removeLast().continuation
                counts.superseded += 1
            }
            waiting.append((seconds, continuation))
            lock.unlock()
            replaced?.resume(returning: .superseded)
        }
    }

    /// Lets the read that is running finish with its still.
    func release() {
        lock.lock()
        guard !waiting.isEmpty else { return lock.unlock() }
        let next = waiting.removeFirst()
        let result = made(at: next.time)
        lock.unlock()
        next.continuation.resume(returning: result)
    }

    func cancelHeld() {
        let stale = lock.withLock { () -> [CheckedContinuation<KeyframeStillResult, Never>] in
            defer { waiting = [] }
            return waiting.map(\.continuation)
        }
        stale.forEach { $0.resume(returning: .cancelled) }
    }

    func closeDecoder() {
        lock.withLock { counts.decoderCloses += 1 }
    }

    func shutdown() async {
        let answers = lock.withLock { () -> [(CheckedContinuation<KeyframeStillResult, Never>, KeyframeStillResult)] in
            counts.shutdowns += 1
            isShutDown = true
            let stale = waiting
            waiting = []
            let openers = opening
            opening = []
            openers.forEach { $0.resume(returning: nil) }
            let late = settings.answersWhenShutDown
            if late { counts.late += stale.count }
            return stale.map { ($0.continuation, late ? made(at: $0.time) : .cancelled) }
        }
        for (continuation, result) in answers { continuation.resume(returning: result) }
    }

    func image(_ position: Int) -> CGImage? {
        lock.withLock { picture(position) }
    }

    /// Call with the lock held.
    private func made(at seconds: Double) -> KeyframeStillResult {
        guard let position = entries.lastIndex(where: { $0.time <= seconds }) else { return .notPossible }
        if let script { return script(position) }
        guard entries[position].isReadable else { return .lastCue }
        guard let image = picture(position) else { return .notPossible }
        if let fetchedPerStill = extras.fetchedPerStill { extras.fetchedTotal += fetchedPerStill }
        return .still(KeyframeStill(image: image, time: entries[position].time, indexPosition: position,
                                    bytesRead: settings.bytes, readCount: 1, keyframeBytes: settings.bytes,
                                    packetsDecoded: 1, elapsed: 0.012))
    }

    /// Call with the lock held. The same picture every time for a position.
    private func picture(_ position: Int) -> CGImage? {
        if let made = pictures[position] { return made }
        let made = Self.picture(level: 20 + position % 200)
        pictures[position] = made
        return made
    }

    static func picture(level: Int) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: 16, height: 8, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        let grey = CGFloat(level) / 255
        context.setFillColor(red: grey, green: grey, blue: grey, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 16, height: 8))
        return context.makeImage()
    }
}

/// Something a test opens when it is ready, for work that has to wait.
private final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    var waiting: Int { lock.withLock { waiters.count } }

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if isOpen {
                lock.unlock()
                continuation.resume()
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }

    func open() {
        let woken = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            isOpen = true
            defer { waiters = [] }
            return waiters
        }
        woken.forEach { $0.resume() }
    }
}

/// Serves a file held in memory to range requests, and remembers them.
private final class StillRangeStub: URLProtocol {
    private static let lock = NSLock()
    private static var file = Data()
    private static var recorded: [URLRequest] = []

    static func serve(_ data: Data) {
        lock.withLock {
            file = data
            recorded = []
        }
    }

    static func requests() -> [URLRequest] {
        lock.withLock { recorded }
    }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StillRangeStub.self]
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let file = Self.lock.withLock { () -> Data in
            Self.recorded.append(request)
            return Self.file
        }
        guard let url = request.url, let header = request.value(forHTTPHeaderField: "Range"), header.hasPrefix("bytes=") else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let ends = header.dropFirst(6).split(separator: "-").compactMap { Int($0) }
        guard ends.count == 2, ends[0] < file.count, ends[0] <= ends[1] else {
            let response = HTTPURLResponse(url: url, statusCode: 416, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Range": "bytes */\(file.count)"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        let last = min(ends[1], file.count - 1)
        let body = file.subdata(in: ends[0]..<(last + 1))
        let response = HTTPURLResponse(url: url, statusCode: 206, httpVersion: "HTTP/1.1", headerFields: [
            "Content-Range": "bytes \(ends[0])-\(last)/\(file.count)", "Content-Length": String(body.count),
        ])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
