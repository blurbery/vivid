import XCTest
#if os(tvOS)
@testable import VividTV
#else
@testable import Vivid
#endif

/// Replay subtitles: a short skip back with subtitles off shows them until
/// playback is back where the skip started.
@MainActor
final class ReplaySubtitlesTests: XCTestCase {
    private func track(
        id: Int64,
        lang: String?,
        forced: Bool = false,
        hearingImpaired: Bool = false,
        title: String? = nil
    ) -> PlayerTrack {
        PlayerTrack(
            trackId: id,
            kind: .sub,
            title: title,
            lang: lang,
            codec: "subrip",
            audioChannelCount: nil,
            bitrate: nil,
            isDefault: false,
            isForced: forced,
            isHearingImpaired: hearingImpaired,
            isExternal: false,
            isSelected: false,
            ffIndex: Int(id),
            srcId: nil
        )
    }

    private var savedSetting = true

    override func setUp() async throws {
        savedSetting = PlayerSettings.shared.replaySubtitlesOnSkipBack
        PlayerSettings.shared.replaySubtitlesOnSkipBack = true
    }

    override func tearDown() async throws {
        PlayerSettings.shared.replaySubtitlesOnSkipBack = savedSetting
    }

    private func finish(_ model: PlayerViewModel) async {
        model.cleanup()
        await model.waitForCleanupCompletion()
    }

    // MARK: - When a skip starts a replay

    func testOnlyAShortSkipBackStartsAReplay() {
        XCTAssertTrue(ReplaySubtitles.startsReplay(from: 100, to: 90))
        XCTAssertTrue(ReplaySubtitles.startsReplay(from: 100, to: 40))
        XCTAssertTrue(ReplaySubtitles.startsReplay(from: 4, to: 0))
        // Further back than a minute is navigation.
        XCTAssertFalse(ReplaySubtitles.startsReplay(from: 100, to: 39))
        // Nothing to replay at the very start, and never on a skip forward.
        XCTAssertFalse(ReplaySubtitles.startsReplay(from: 0.5, to: 0))
        XCTAssertFalse(ReplaySubtitles.startsReplay(from: 100, to: 100))
        XCTAssertFalse(ReplaySubtitles.startsReplay(from: 100, to: 130))
        XCTAssertFalse(ReplaySubtitles.startsReplay(from: .nan, to: 90))
    }

    func testAReplayEndsShortlyAfterPlaybackIsBackWhereTheSkipStarted() {
        let session = ReplaySubtitles.Session(trackID: 3, restoreTrackID: nil, endTime: 100)
        XCTAssertFalse(ReplaySubtitles.hasEnded(session, at: 90))
        XCTAssertFalse(ReplaySubtitles.hasEnded(session, at: 100))
        XCTAssertFalse(ReplaySubtitles.hasEnded(session, at: 101.9))
        XCTAssertTrue(ReplaySubtitles.hasEnded(session, at: 102))
        // A seek forward past it ends it too.
        XCTAssertTrue(ReplaySubtitles.hasEnded(session, at: 900))
        XCTAssertFalse(ReplaySubtitles.hasEnded(session, at: .nan))
    }

    func testAReplayOnlyReplacesOffOrAForcedTrack() {
        XCTAssertTrue(ReplaySubtitles.canReplace(nil))
        XCTAssertTrue(ReplaySubtitles.canReplace(track(id: 1, lang: "en", forced: true)))
        XCTAssertTrue(ReplaySubtitles.canReplace(track(id: 1, lang: "en", title: "English Forced")))
        XCTAssertFalse(ReplaySubtitles.canReplace(track(id: 1, lang: "en")))
        XCTAssertFalse(ReplaySubtitles.canReplace(track(id: 1, lang: "en", hearingImpaired: true)))
    }

    // MARK: - Which track it shows

    func testLanguagesRunFromSettingsToTheDeviceToTheAudio() {
        XCTAssertEqual(
            ReplaySubtitles.languages(preferred: ["fr", nil, "de"], device: ["en-AU", "fr"], audio: "ja"),
            ["fr", "de", "en-AU", "ja"]
        )
        // Blank and undetermined languages say nothing.
        XCTAssertEqual(
            ReplaySubtitles.languages(preferred: [nil, "", " "], device: [], audio: "und"),
            []
        )
        XCTAssertEqual(ReplaySubtitles.languages(preferred: ["EN"], device: ["en"], audio: nil), ["EN"])
        // A backup language sits between the subtitle language and the device's.
        XCTAssertEqual(
            ReplaySubtitles.languages(preferred: ["ar", "en"], device: ["de"], audio: "ja"),
            ["ar", "en", "de", "ja"]
        )
    }

    func testTheFullTrackInTheFirstLanguageThatHasOneIsShown() {
        let tracks = [
            track(id: 1, lang: "eng", forced: true),
            track(id: 2, lang: "fre"),
            track(id: 3, lang: "eng"),
        ]
        XCTAssertEqual(ReplaySubtitles.track(in: tracks, languages: ["en", "fr"], preferAccessibility: false)?.trackId, 3)
        XCTAssertEqual(ReplaySubtitles.track(in: tracks, languages: ["de", "fr"], preferAccessibility: false)?.trackId, 2)
    }

    /// The order of the languages wins over the kind of track: an SDH track
    /// in the viewer's language beats a plain one in the audio's.
    func testAnEarlierLanguageBeatsAPlainerTrackInALaterOne() {
        let tracks = [
            track(id: 1, lang: "fre"),
            track(id: 2, lang: "eng", hearingImpaired: true),
        ]
        XCTAssertEqual(ReplaySubtitles.track(in: tracks, languages: ["en", "fr"], preferAccessibility: false)?.trackId, 2)
    }

    func testAPlainTrackIsPreferredUnlessAccessibilityTracksAre() {
        let tracks = [
            track(id: 1, lang: "eng", hearingImpaired: true),
            track(id: 2, lang: "eng"),
        ]
        XCTAssertEqual(ReplaySubtitles.track(in: tracks, languages: ["en"], preferAccessibility: false)?.trackId, 2)
        XCTAssertEqual(ReplaySubtitles.track(in: tracks, languages: ["en"], preferAccessibility: true)?.trackId, 1)
    }

    func testAForcedTrackIsNeverShown() {
        let tracks = [
            track(id: 1, lang: "eng", forced: true),
            track(id: 2, lang: "eng", title: "Forced (Signs)"),
        ]
        XCTAssertNil(ReplaySubtitles.track(in: tracks, languages: ["en"], preferAccessibility: false))
    }

    func testALanguageTheViewerDidNotAskForIsNeverShown() {
        let tracks = [track(id: 1, lang: "ger"), track(id: 2, lang: "spa")]
        XCTAssertNil(ReplaySubtitles.track(in: tracks, languages: ["en", "fr"], preferAccessibility: false))
        XCTAssertNil(ReplaySubtitles.track(in: [], languages: ["en"], preferAccessibility: false))
    }

    /// A file with one subtitle often leaves its language out.
    func testAnUntaggedTrackIsShownWhenNoLanguageMatches() {
        let tracks = [
            track(id: 1, lang: "ger"),
            track(id: 2, lang: nil, forced: true),
            track(id: 3, lang: "und"),
        ]
        XCTAssertEqual(ReplaySubtitles.track(in: tracks, languages: ["en"], preferAccessibility: false)?.trackId, 3)
        // A tagged match still comes first.
        XCTAssertEqual(ReplaySubtitles.track(in: tracks, languages: ["de"], preferAccessibility: false)?.trackId, 1)
    }

    // MARK: - In the player

    /// Reloads, reports and the next episode read the viewer's selection.
    func testTheViewersSelectionLeavesTheReplaysTrackOut() async {
        let model = PlayerViewModel()
        model.subtitleTracks = [track(id: 2, lang: "eng", forced: true), track(id: 5, lang: "eng")]
        model.selectedSubtitleId = 5
        XCTAssertEqual(model.viewerSubtitleId, 5)
        XCTAssertEqual(model.resolvedSubtitleTrackIndexForResume(), 5)

        model.replaySubtitleSession = ReplaySubtitles.Session(trackID: 5, restoreTrackID: nil, endTime: 100)
        XCTAssertNil(model.viewerSubtitleId)
        XCTAssertEqual(model.resolvedSubtitleTrackIndexForResume(), -1)
        XCTAssertEqual(model.playingTracksForServer.subtitle, .off)

        model.replaySubtitleSession = ReplaySubtitles.Session(trackID: 5, restoreTrackID: 2, endTime: 100)
        XCTAssertEqual(model.viewerSubtitleId, 2)
        XCTAssertEqual(model.resolvedSubtitleTrackIndexForResume(), 2)
        XCTAssertEqual(model.playingTracksForServer.subtitle, .embedded(2))

        // Once something else has changed the subtitle, the replay no
        // longer speaks for it.
        model.selectedSubtitleId = 2
        XCTAssertEqual(model.viewerSubtitleId, 2)
        await finish(model)
    }

    func testCatchingUpTurnsTheSubtitlesBackOff() async {
        let model = PlayerViewModel()
        model.subtitleTracks = [track(id: 5, lang: "eng")]
        model.selectedSubtitleId = 5
        model.replaySubtitleSession = ReplaySubtitles.Session(trackID: 5, restoreTrackID: nil, endTime: 100)

        model.updateReplaySubtitles(at: 101)
        XCTAssertEqual(model.selectedSubtitleId, 5)
        XCTAssertNotNil(model.replaySubtitleSession)

        model.updateReplaySubtitles(at: 102)
        XCTAssertNil(model.selectedSubtitleId)
        XCTAssertNil(model.replaySubtitleSession)
        // Nothing here counts as the viewer choosing Off.
        XCTAssertFalse(model.hasExplicitSubtitleChoice)
        XCTAssertNil(model.viewingSubtitlePrefs)
        await finish(model)
    }

    /// A subtitle chosen during the replay stays when it ends.
    func testAPickMadeDuringAReplayIsKept() async {
        let model = PlayerViewModel()
        model.subtitleTracks = [track(id: 5, lang: "eng"), track(id: 6, lang: "fre")]
        model.selectedSubtitleId = 5
        model.replaySubtitleSession = ReplaySubtitles.Session(trackID: 5, restoreTrackID: nil, endTime: 100)

        model.selectedSubtitleId = 6
        model.updateReplaySubtitles(at: 200)
        XCTAssertEqual(model.selectedSubtitleId, 6)
        XCTAssertNil(model.replaySubtitleSession)
        await finish(model)
    }

    func testTurningSubtitlesOffDuringAReplayEndsIt() async {
        let model = PlayerViewModel()
        model.subtitleTracks = [track(id: 5, lang: "eng")]
        model.selectedSubtitleId = 5
        model.replaySubtitleSession = ReplaySubtitles.Session(trackID: 5, restoreTrackID: nil, endTime: 100)

        model.disableSubtitles()
        XCTAssertNil(model.replaySubtitleSession)
        XCTAssertNil(model.selectedSubtitleId)
        XCTAssertTrue(model.hasExplicitSubtitleChoice)
        await finish(model)
    }

    func testSkippingBackAgainKeepsTheReplayToTheFurthestPoint() async {
        let model = PlayerViewModel()
        model.subtitleTracks = [track(id: 5, lang: "eng")]
        model.selectedSubtitleId = 5
        model.replaySubtitleSession = ReplaySubtitles.Session(trackID: 5, restoreTrackID: nil, endTime: 100)

        model.replaySubtitlesAfterSkip(from: 95, to: 85, seekReloadsPlayback: false)
        XCTAssertEqual(model.replaySubtitleSession?.endTime, 100)
        // Pressed during the last moments, past where the first skip began.
        model.replaySubtitlesAfterSkip(from: 101, to: 91, seekReloadsPlayback: false)
        XCTAssertEqual(model.replaySubtitleSession?.endTime, 101)
        // A skip forward leaves it to end on its own.
        model.replaySubtitlesAfterSkip(from: 91, to: 121, seekReloadsPlayback: false)
        XCTAssertEqual(model.replaySubtitleSession?.endTime, 101)
        XCTAssertEqual(model.selectedSubtitleId, 5)
        await finish(model)
    }

    /// Skips that add up to more than a minute before where the subtitles
    /// would end are navigation, as one long skip is.
    func testSkippingBackPastTheLimitEndsTheReplay() async {
        let model = PlayerViewModel()
        model.subtitleTracks = [track(id: 5, lang: "eng")]
        model.selectedSubtitleId = 5
        model.replaySubtitleSession = ReplaySubtitles.Session(trackID: 5, restoreTrackID: nil, endTime: 100)

        model.replaySubtitlesAfterSkip(from: 50, to: 40, seekReloadsPlayback: false)
        XCTAssertEqual(model.replaySubtitleSession?.endTime, 100)
        model.replaySubtitlesAfterSkip(from: 40, to: 30, seekReloadsPlayback: false)
        XCTAssertNil(model.replaySubtitleSession)
        XCTAssertNil(model.selectedSubtitleId)
        await finish(model)
    }

    /// With the setting turned off mid-replay, another skip ends it.
    func testSkippingBackWithTheSettingOffEndsTheReplay() async {
        let model = PlayerViewModel()
        model.subtitleTracks = [track(id: 5, lang: "eng")]
        model.selectedSubtitleId = 5
        model.replaySubtitleSession = ReplaySubtitles.Session(trackID: 5, restoreTrackID: nil, endTime: 100)

        PlayerSettings.shared.replaySubtitlesOnSkipBack = false
        model.replaySubtitlesAfterSkip(from: 95, to: 85, seekReloadsPlayback: false)
        XCTAssertNil(model.replaySubtitleSession)
        XCTAssertNil(model.selectedSubtitleId)
        await finish(model)
    }

    /// A scrub, a chapter or a remote command is the viewer moving
    /// elsewhere, so only a skip keeps the replay going.
    func testAnyOtherSeekEndsTheReplay() async {
        let model = PlayerViewModel()
        model.duration = 600
        model.subtitleTracks = [track(id: 5, lang: "eng")]
        model.selectedSubtitleId = 5
        model.replaySubtitleSession = ReplaySubtitles.Session(trackID: 5, restoreTrackID: nil, endTime: 100)

        model.commitSeek(to: 90, source: "skipDebounce", keepsReplaySubtitles: true)
        XCTAssertNotNil(model.replaySubtitleSession)
        XCTAssertEqual(model.selectedSubtitleId, 5)

        model.seekTo(seconds: 30)
        XCTAssertNil(model.replaySubtitleSession)
        XCTAssertNil(model.selectedSubtitleId)
        await finish(model)
    }

    /// A replay left behind by a subtitle change is forgotten, not revived.
    func testAReplayWhoseTrackIsNoLongerSelectedIsForgotten() async {
        let model = PlayerViewModel()
        model.subtitleTracks = [track(id: 5, lang: "eng"), track(id: 6, lang: "fre")]
        model.selectedSubtitleId = 6
        model.replaySubtitleSession = ReplaySubtitles.Session(trackID: 5, restoreTrackID: nil, endTime: 100)

        model.replaySubtitlesAfterSkip(from: 95, to: 85, seekReloadsPlayback: false)
        XCTAssertNil(model.replaySubtitleSession)
        XCTAssertEqual(model.selectedSubtitleId, 6)
        await finish(model)
    }

    /// A seek the loaded stream can't reach reloads playback, which starts
    /// from the viewer's own selection.
    func testASkipThatReloadsPlaybackEndsTheReplay() async {
        let model = PlayerViewModel()
        model.subtitleTracks = [track(id: 5, lang: "eng")]
        model.selectedSubtitleId = 5
        model.replaySubtitleSession = ReplaySubtitles.Session(trackID: 5, restoreTrackID: nil, endTime: 100)

        model.replaySubtitlesAfterSkip(from: 95, to: 85, seekReloadsPlayback: true)
        XCTAssertNil(model.replaySubtitleSession)
        XCTAssertNil(model.selectedSubtitleId)
        await finish(model)
    }

    /// Before the load is established there are no tracks to show, and a
    /// subtitle pick may still be on its way.
    func testNothingStartsWithoutAnEstablishedLoad() async {
        let model = PlayerViewModel()
        model.subtitleTracks = [track(id: 5, lang: "eng")]
        model.replaySubtitlesAfterSkip(from: 100, to: 90, seekReloadsPlayback: false)
        XCTAssertNil(model.replaySubtitleSession)
        XCTAssertNil(model.selectedSubtitleId)
        await finish(model)
    }
}
