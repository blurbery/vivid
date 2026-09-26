import Combine
import UIKit
import XCTest
#if os(tvOS)
@testable import VividTV
#else
@testable import Vivid
#endif

@MainActor
final class VividSubtitleCueCursorTests: XCTestCase {
    private func cue(_ id: Int, _ start: Double, _ end: Double) -> SubtitleCue {
        SubtitleCue(id: id, startTime: start, endTime: end, body: .text("Cue \(id)"))
    }

    private func assertEquivalent(_ cues: [SubtitleCue], times: [Double],
                                  file: StaticString = #filePath, line: UInt = #line) {
        let cursor = VividSubtitleCueCursor(cues)
        for time in times {
            let expected = cues.indices.filter { cues[$0].startTime <= time && time < cues[$0].endTime }
            let actual = cursor.selection(at: time)
            XCTAssertEqual(actual.offsets, expected, "At \(time)", file: file, line: line)
            XCTAssertEqual(actual.cues.map(\.id), expected.map { cues[$0].id }, file: file, line: line)
        }
    }

    func testUnsortedOverlapsGapsAndExactBoundariesMatchOriginalFilter() {
        let cues = [cue(7, 5, 9), cue(7, 1, 8), cue(2, 1, 3), cue(3, 3, 5),
                    cue(4, 4, 4), cue(5, 12, 14), cue(6, 9, 8)]
        let times = [-1.0, 0, 1, 1, 2.999, 3, 4, 5, 7.999, 8, 9, 10, 12, 14]
        assertEquivalent(cues, times: times + times.reversed())
    }

    func testLongCueSurvivesManyShortOverlappingCuesAndSeeks() {
        let cues = [cue(0, 0, 10_000)] + (1...1_000).map { cue($0, Double($0), Double($0) + 0.5) }
        let times = stride(from: 0.0, through: 1_001, by: 0.5).map { $0 }
        assertEquivalent(cues, times: times + [9_999, 10_000, 500.25, 2.1, 900.5, 0])
    }

    func testDeterministicMixedTimelineMatchesOriginalFilter() {
        var state: UInt64 = 0x5eed
        func next(_ bound: UInt64) -> Double {
            state = state &* 6_364_136_223_846_793_005 &+ 1
            return Double((state >> 32) % bound) / 10
        }
        let cues = (0..<600).map { index -> SubtitleCue in
            let start = next(6_000)
            return cue(index % 17, start, start + next(400))
        }
        let jumps = (0..<1_000).map { _ in next(6_500) }
        assertEquivalent(cues, times: jumps.sorted() + jumps)
    }

    func testEmptyInvalidAndNonFiniteInputsMatchOriginalFilter() {
        let times: [Double] = [-.infinity, -1, 0, 1, 2, .infinity, .nan, 1, 0]
        assertEquivalent([], times: times)
        assertEquivalent([cue(0, .nan, 4), cue(1, 0, .nan), cue(2, -.infinity, 2),
                          cue(3, 1, .infinity), cue(4, 2, 1), cue(5, 1, 1)], times: times)
    }

    func testCueBodiesAndPlacementArePreserved() throws {
        let image = try XCTUnwrap(UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        }.cgImage)
        let run = SubtitleTextRun(text: "Styled", color: SubtitleColor(r: 12, g: 34, b: 56), isBold: true)
        let placement = SubtitleTextPlacement(alignment: 8, position: CGPoint(x: 10, y: 20))
        let cues = [SubtitleCue(id: 0, startTime: 0, endTime: 2, body: .richText([run]), placement: placement),
                    SubtitleCue(id: 1, startTime: 0, endTime: 2,
                                body: .image(SubtitleImage(cgImage: image, position: .zero, canvasSize: CGSize(width: 2, height: 2))))]
        let result = VividSubtitleCueCursor(cues).selection(at: 1).cues
        guard case .richText(let runs) = result[0].body, case .image(let bitmap) = result[1].body else {
            return XCTFail("Cue bodies were changed")
        }
        XCTAssertEqual(runs[0].text, run.text)
        XCTAssertEqual(runs[0].color, run.color)
        XCTAssertTrue(runs[0].isBold)
        XCTAssertEqual(result[0].placement?.position, placement.position)
        XCTAssertEqual(result[0].placement?.alignment, placement.alignment)
        XCTAssertTrue(bitmap.cgImage === image)
    }

    func testParsedSRTAndWebVTTMatchOriginalFilter() async throws {
        for (ext, text) in [
            ("srt", "1\r\n00:00:01,000 --> 00:00:03,000\r\n<b>One</b> &amp; two\r\n\r\n2\r\n00:00:02,500 --> 00:00:04,000\r\nOverlap\r\n"),
            ("vtt", "WEBVTT\n\n00:01.000 --> 00:03.000 align:start\nOne &amp; two\n\n00:02.500 --> 00:04.000\nOverlap\n")
        ] {
            let file = try fixture(text, extension: ext)
            defer { try? FileManager.default.removeItem(at: file) }
            let document = try await VividSubtitleLoader.load(ExternalSubtitleTrack(url: file))
            guard case .cues(let cues) = document else { return XCTFail("Expected text cues") }
            XCTAssertEqual(cues.count, 2)
            assertEquivalent(cues, times: [0, 1, 2.5, 3, 4, 2.5, 1, 0])
        }
    }

    func testSubtitlesOffDoNotRepublishEmptySelections() {
        let engine = VividEngine()
        defer { engine.stop() }
        var primaryUpdates = 0
        var secondaryUpdates = 0
        let primary = engine.$subtitleCues.dropFirst().sink { _ in primaryUpdates += 1 }
        let secondary = engine.$secondarySubtitleCues.dropFirst().sink { _ in secondaryUpdates += 1 }
        defer { primary.cancel(); secondary.cancel() }
        for step in 0..<1_000 { engine.debugReceivePlaybackTime(Double(step) / 100) }
        engine.clearSubtitle()
        engine.clearSecondarySubtitle()
        XCTAssertEqual(primaryUpdates, 0)
        XCTAssertEqual(secondaryUpdates, 0)
    }

    func testUnchangedCuePublishesOnceAcrossThousandClockUpdates() async throws {
        let engine = VividEngine()
        defer { engine.stop() }
        let file = try fixture("1\n00:00:00,000 --> 00:00:10,000\nCaption\n")
        defer { try? FileManager.default.removeItem(at: file) }
        let track = engine.addExternalSubtitleTrack(ExternalSubtitleTrack(url: file))
        try await waitForSubtitles(engine)
        var updates: [[String]] = []
        let subscription = engine.$subtitleCues.dropFirst().sink { updates.append(self.texts($0)) }
        defer { subscription.cancel() }
        engine.selectSubtitleTrack(index: track.id)
        for step in 0..<1_000 { engine.debugReceivePlaybackTime(Double(step) / 100) }
        XCTAssertEqual(updates, [["Caption"]])
        engine.debugReceivePlaybackTime(10)
        engine.debugReceivePlaybackTime(11)
        XCTAssertEqual(updates, [["Caption"], []])
    }

    func testTrackSwitchWithSameCueIDsPublishesNewText() async throws {
        let engine = VividEngine()
        defer { engine.stop() }
        let first = try fixture("1\n00:00:00,000 --> 00:00:10,000\nFirst\n")
        let second = try fixture("1\n00:00:00,000 --> 00:00:10,000\nSecond\n")
        defer { try? FileManager.default.removeItem(at: first); try? FileManager.default.removeItem(at: second) }
        let one = engine.addExternalSubtitleTrack(ExternalSubtitleTrack(url: first))
        let two = engine.addExternalSubtitleTrack(ExternalSubtitleTrack(url: second))
        try await waitForSubtitles(engine)
        engine.debugReceivePlaybackTime(1)
        engine.selectSubtitleTrack(index: one.id)
        XCTAssertEqual(texts(engine.subtitleCues), ["First"])
        engine.selectSubtitleTrack(index: two.id)
        XCTAssertEqual(texts(engine.subtitleCues), ["Second"])
        engine.selectSubtitleTrack(index: 42) // Embedded/native tracks have no overlay cues.
        XCTAssertTrue(engine.subtitleCues.isEmpty)
    }

    func testDualSubtitlesDelaysAndBackwardSeeksStayIndependent() async throws {
        let engine = VividEngine()
        defer { engine.stop() }
        let first = try fixture("1\n00:00:01,000 --> 00:00:03,000\nPrimary\n\n2\n00:00:02,000 --> 00:00:04,000\nOverlap\n")
        let second = try fixture("1\n00:00:02,000 --> 00:00:05,000\nSecondary\n")
        defer { try? FileManager.default.removeItem(at: first); try? FileManager.default.removeItem(at: second) }
        let one = engine.addExternalSubtitleTrack(ExternalSubtitleTrack(url: first))
        let two = engine.addExternalSubtitleTrack(ExternalSubtitleTrack(url: second))
        try await waitForSubtitles(engine)
        engine.selectSubtitleTrack(index: one.id)
        engine.selectSecondarySubtitleTrack(index: two.id)
        let primaryCues = VividSubtitleLoader.parse(try String(contentsOf: first, encoding: .utf8))
        let secondaryCues = VividSubtitleLoader.parse(try String(contentsOf: second, encoding: .utf8))
        for delay in [0, 1_000, -1_000, 0] {
            engine.applySubtitleSettings(appearance: .default, delayMilliseconds: delay)
            for time in [0.0, 1, 2, 3, 4, 5, 20, 2.5, 1, 0] {
                engine.debugReceivePlaybackTime(time)
                let clock = time - Double(delay) / 1_000
                XCTAssertEqual(texts(engine.subtitleCues), texts(primaryCues.filter { $0.startTime <= clock && clock < $0.endTime }))
                XCTAssertEqual(texts(engine.secondarySubtitleCues), texts(secondaryCues.filter { $0.startTime <= clock && clock < $0.endTime }))
            }
        }
        engine.debugReceivePlaybackTime(2.5)
        engine.clearSubtitle()
        XCTAssertTrue(engine.subtitleCues.isEmpty)
        XCTAssertEqual(texts(engine.secondarySubtitleCues), ["Secondary"])
        engine.clearSecondarySubtitle()
        XCTAssertTrue(engine.secondarySubtitleCues.isEmpty)
        engine.selectSubtitleTrack(index: one.id)
        XCTAssertEqual(texts(engine.subtitleCues), ["Primary", "Overlap"])
    }

    func testSameTrackInBothPositionsAndStopClearBoth() async throws {
        let engine = VividEngine()
        defer { engine.stop() }
        let file = try fixture("1\n00:00:01,000 --> 00:00:03,000\nCaption\n")
        defer { try? FileManager.default.removeItem(at: file) }
        let track = engine.addExternalSubtitleTrack(ExternalSubtitleTrack(url: file))
        engine.selectSubtitleTrack(index: track.id)
        engine.selectSecondarySubtitleTrack(index: track.id)
        engine.debugReceivePlaybackTime(2)
        try await waitForSubtitles(engine) // Selection made before the document finished loading.
        XCTAssertEqual(texts(engine.subtitleCues), ["Caption"])
        XCTAssertEqual(texts(engine.secondarySubtitleCues), ["Caption"])
        engine.stop()
        XCTAssertTrue(engine.subtitleCues.isEmpty)
        XCTAssertTrue(engine.secondarySubtitleCues.isEmpty)
        engine.debugReceivePlaybackTime(2)
        XCTAssertTrue(engine.subtitleCues.isEmpty)
        let replacement = engine.addExternalSubtitleTrack(ExternalSubtitleTrack(url: file))
        try await waitForSubtitles(engine)
        engine.selectSubtitleTrack(index: replacement.id)
        XCTAssertEqual(texts(engine.subtitleCues), ["Caption"])
        XCTAssertTrue(engine.secondarySubtitleCues.isEmpty)
    }

    func testFailedAndCancelledLoadsDoNotRestoreOldCues() async throws {
        let engine = VividEngine()
        defer { engine.stop() }
        let absent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("srt")
        let track = engine.addExternalSubtitleTrack(ExternalSubtitleTrack(url: absent))
        engine.selectSubtitleTrack(index: track.id)
        try await waitForSubtitles(engine)
        XCTAssertTrue(engine.subtitleCues.isEmpty)
        let file = try fixture("1\n00:00:00,000 --> 00:00:10,000\nCancelled\n")
        defer { try? FileManager.default.removeItem(at: file) }
        let cancelled = engine.addExternalSubtitleTrack(ExternalSubtitleTrack(url: file))
        engine.selectSubtitleTrack(index: cancelled.id)
        engine.stop() // Cancel before the loader's actor task can run.
        await Task.yield()
        engine.debugReceivePlaybackTime(1)
        XCTAssertTrue(engine.subtitleCues.isEmpty)
        XCTAssertTrue(engine.secondarySubtitleCues.isEmpty)
    }

    private func fixture(_ text: String, extension ext: String = "srt") throws -> URL {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension(ext)
        try text.write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    private func waitForSubtitles(_ engine: VividEngine) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while engine.isLoadingSubtitles && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertFalse(engine.isLoadingSubtitles, "Subtitle loading did not finish")
    }

    private func texts(_ cues: [SubtitleCue]) -> [String] {
        cues.map { if case .text(let text) = $0.body { return text }; return "Non-text cue" }
    }
}
