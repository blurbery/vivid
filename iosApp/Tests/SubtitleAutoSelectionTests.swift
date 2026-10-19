import XCTest
#if os(tvOS)
@testable import VividTV
#else
@testable import Vivid
#endif

/// Auto subtitle selection inside the player, on iOS and Apple TV. The
/// reported case: Settings > Subtitles set to English, Auto and Show Forced
/// Subtitles, playing English audio. Only the forced English track may play;
/// the full English track is for foreign audio.
@MainActor
final class SubtitleAutoSelectionTests: XCTestCase {
    private let forcedID: Int64 = 3
    private let fullID: Int64 = 4
    private let englishAudioID: Int64 = 1
    private let japaneseAudioID: Int64 = 2

    private func subtitle(_ id: Int64, forced: Bool) -> PlayerTrack {
        PlayerTrack(trackId: id, kind: .sub, title: forced ? "English (Forced)" : "English", lang: "eng",
                    codec: "subrip", audioChannelCount: nil, bitrate: nil, isDefault: false,
                    isForced: forced, isHearingImpaired: false, isExternal: false, isSelected: false,
                    ffIndex: Int(id), srcId: nil)
    }

    private func audio(_ id: Int64, lang: String?, ordinal: Int, selected: Bool) -> PlayerTrack {
        PlayerTrack(trackId: id, kind: .audio, title: nil, lang: lang, codec: "eac3",
                    audioChannelCount: 6, bitrate: nil, isDefault: ordinal == 0, isForced: false,
                    isHearingImpaired: false, isExternal: false, isSelected: selected,
                    ffIndex: Int(id), srcId: ordinal)
    }

    private func catalogueAudio(_ language: String?) -> AudioTrack {
        AudioTrack(index: nil, codec: "eac3", channels: 6, channelLayout: "5.1", bitrate: 640_000,
                   sampleRate: 48_000, language: language, title: nil, embeddedTitle: nil, isDefault: nil)
    }

    private func version(audio languages: [String?]) -> FileVersion {
        FileVersion(fileId: 42, fileName: "fixture.mkv", resolution: "3840x2160", codecVideo: "hevc",
                    codecAudio: "eac3", hdr: false, container: "mkv", fileSize: 1_000,
                    duration: 7_200, bitrate: 20_000_000, videoTracks: nil,
                    audioTracks: languages.map(catalogueAudio), subtitleTracks: nil, chapters: nil)
    }

    /// Settings > Subtitles, as `localSubtitlePrefsSnapshot` reads it.
    private func makeModel(showForced: Bool = true) -> PlayerViewModel {
        let model = PlayerViewModel()
        model.prefsForCurrentItem = .init(
            preferredLanguage: "en", additionalPreferredLanguages: [], mode: .auto,
            showForced: showForced, forcedOnly: false, preferAccessibilityTracks: false,
            disableWhenNoLanguageMatch: true, trackSignature: nil
        )
        model.subtitleTracks = [subtitle(fullID, forced: false), subtitle(forcedID, forced: true)]
        return model
    }

    private func establishLoad(_ model: PlayerViewModel) {
        let epoch = VividPlaybackController.LoadEpoch(rawValue: 1)
        model.activeVividLoadEpoch = epoch
        model.establishedVividLoadEpoch = epoch
    }

    private func finish(_ model: PlayerViewModel) async {
        model.cleanup()
        await model.waitForCleanupCompletion()
    }

    /// The regression. Startup inventory lists the subtitles before the
    /// engine has picked an audio track, so the audio language is unknown.
    /// Resolving then picked the full English track and latched it for the
    /// whole film. The pick now waits for the established load.
    func testStartupInventoryDoesNotLatchFullSubtitlesBeforeAudioIsKnown() async {
        let model = makeModel()
        model.audioTracks = [audio(englishAudioID, lang: "eng", ordinal: 0, selected: false)]
        model.selectedAudioId = nil

        model.applyAutoSubtitlePreferencesIfNeeded()
        XCTAssertNil(model.selectedSubtitleId)
        XCTAssertFalse(model.prefsResolvedForCurrentItem)

        model.audioTracks = [audio(englishAudioID, lang: "eng", ordinal: 0, selected: true)]
        model.selectedAudioId = englishAudioID
        establishLoad(model)
        model.applyAutoSubtitlePreferencesIfNeeded()
        XCTAssertEqual(model.selectedSubtitleId, forcedID)
        XCTAssertTrue(model.prefsResolvedForCurrentItem)
        await finish(model)
    }

    func testEnglishAudioWithShowForcedSelectsOnlyTheForcedTrack() async {
        let model = makeModel()
        model.audioTracks = [audio(englishAudioID, lang: "eng", ordinal: 0, selected: true)]
        model.selectedAudioId = englishAudioID
        establishLoad(model)
        model.applyAutoSubtitlePreferencesIfNeeded()
        XCTAssertEqual(model.selectedSubtitleId, forcedID)
        await finish(model)
    }

    func testEnglishAudioWithoutShowForcedLeavesSubtitlesOff() async {
        let model = makeModel(showForced: false)
        model.audioTracks = [audio(englishAudioID, lang: "eng", ordinal: 0, selected: true)]
        model.selectedAudioId = englishAudioID
        model.selectedSubtitleId = fullID
        establishLoad(model)
        model.applyAutoSubtitlePreferencesIfNeeded()
        XCTAssertNil(model.selectedSubtitleId)
        await finish(model)
    }

    /// Unchanged: foreign audio still gets the full English track, never the
    /// signs-only forced one.
    func testForeignAudioStillSelectsTheFullTrack() async {
        let model = makeModel()
        model.audioTracks = [
            audio(englishAudioID, lang: "eng", ordinal: 0, selected: false),
            audio(japaneseAudioID, lang: "jpn", ordinal: 1, selected: true),
        ]
        model.selectedAudioId = japaneseAudioID
        establishLoad(model)
        model.applyAutoSubtitlePreferencesIfNeeded()
        XCTAssertEqual(model.selectedSubtitleId, fullID)
        await finish(model)
    }

    /// A stream with no audio language tag (a server transcode can drop it)
    /// uses the file's catalogue language instead of reading as foreign.
    func testUntaggedEnglishAudioUsesTheCatalogueLanguage() async {
        let model = makeModel()
        model.currentSelectedVersion = version(audio: ["eng", "jpn"])
        model.audioTracks = [
            audio(englishAudioID, lang: nil, ordinal: 0, selected: true),
            audio(japaneseAudioID, lang: nil, ordinal: 1, selected: false),
        ]
        model.selectedAudioId = englishAudioID
        establishLoad(model)
        model.applyAutoSubtitlePreferencesIfNeeded()
        XCTAssertEqual(model.selectedSubtitleId, forcedID)
        await finish(model)
    }

    /// A transcode carrying one of the file's two audio tracks: its engine
    /// ordinal says nothing about the catalogue, so the requested ordinal is
    /// used instead.
    func testTranscodeOrdinalIsNotReadAgainstTheFullCatalogue() async {
        let model = makeModel()
        model.currentSelectedVersion = version(audio: ["eng", "jpn"])
        model.lastLoadRequest = .init(contentId: "movie", preferredFileId: 42, preferredAudioTrackIndex: 1,
                                      preferredSubtitleTrackIndex: nil, preferredSidecarSubtitleTrackId: nil,
                                      startFromBeginning: false)
        model.audioTracks = [audio(japaneseAudioID, lang: "und", ordinal: 0, selected: true)]
        model.selectedAudioId = japaneseAudioID
        establishLoad(model)
        model.applyAutoSubtitlePreferencesIfNeeded()
        XCTAssertEqual(model.selectedSubtitleId, fullID)
        await finish(model)
    }

    // MARK: - Player picks hold for the viewing, not Settings

    private func watchDetail() throws -> WatchDetail {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(WatchDetail.self, from: Data("""
            {"content_id":"episode-2","type":"episode","title":"Episode 2","series_id":"series",
             "series_title":"Series","season_number":1,"episode_number":2}
            """.utf8))
    }

    /// Runs `body` with Settings > Subtitles at English, Auto and Show Forced
    /// Subtitles, then puts the previous values back.
    private func withEnglishAutoSettings(_ body: () async throws -> Void) async rethrows {
        let settings = PlayerSettings.shared
        let saved = (settings.preferredSubtitleLanguage, settings.preferredSubtitleMode,
                     settings.showForcedSubtitles, settings.subtitleMatchesSystemAppearance)
        settings.preferredSubtitleLanguage = "en"
        settings.preferredSubtitleMode = SubtitleMode.auto.rawValue
        settings.showForcedSubtitles = true
        settings.setSubtitleMatchesSystemAppearance(false)
        defer {
            settings.preferredSubtitleLanguage = saved.0
            settings.preferredSubtitleMode = saved.1
            settings.showForcedSubtitles = saved.2
            settings.setSubtitleMatchesSystemAppearance(saved.3)
        }
        try await body()
    }

    /// The next episode of the same viewing: no explicit index, so the
    /// automatic pick decides from this viewing's preferences.
    private func playNextEpisode(_ model: PlayerViewModel, withForcedTrack: Bool = true) throws {
        model.hasExplicitSubtitleChoice = false
        model.prefsResolvedForCurrentItem = false
        model.prefsForCurrentItem = model.automaticSubtitlePrefsSnapshot(try watchDetail())
        model.subtitleTracks = [subtitle(fullID, forced: false)]
            + (withForcedTrack ? [subtitle(forcedID, forced: true)] : [])
        model.audioTracks = [audio(englishAudioID, lang: "eng", ordinal: 0, selected: true)]
        model.selectedAudioId = englishAudioID
        model.selectedSubtitleId = nil
        establishLoad(model)
        model.applyAutoSubtitlePreferencesIfNeeded()
    }

    /// Picking full English subtitles in the player used to set Behaviour to
    /// Always for everything. Now Settings stays on Auto and the pick only
    /// follows this viewing into the next episode.
    func testPlayerPickKeepsSettingsAndCarriesToTheNextEpisode() async throws {
        try await withEnglishAutoSettings {
            let model = PlayerViewModel()
            let sidecarID = SubtitleTrackIdSpace.makeSidecarTrackId(urlIndex: 0)
            let file = FileManager.default.temporaryDirectory
                .appendingPathComponent("vivid-subtitle-test-\(UUID().uuidString).srt")
            try Data("1\n00:00:01,000 --> 00:00:02,000\nHello\n".utf8).write(to: file)
            defer { try? FileManager.default.removeItem(at: file) }
            model.vividPlaybackController.addExternalSubtitleTrack(
                ExternalSubtitleTrack(url: file, name: "English", language: "eng", formatHint: "srt"),
                appTrackID: sidecarID
            )
            let sidecar = PlayerTrack(trackId: sidecarID, kind: .sub, title: "English", lang: "eng",
                                      codec: "subrip", audioChannelCount: nil, bitrate: nil, isDefault: false,
                                      isForced: false, isHearingImpaired: false, isExternal: true,
                                      isSelected: false, ffIndex: nil, srcId: 0)
            model.subtitleTracks = [sidecar]

            model.selectSubtitle(sidecar)
            XCTAssertEqual(model.selectedSubtitleId, sidecarID)
            XCTAssertEqual(PlayerSettings.shared.preferredSubtitleMode, SubtitleMode.auto.rawValue)
            XCTAssertEqual(PlayerSettings.shared.preferredSubtitleLanguage, "en")

            try playNextEpisode(model)
            XCTAssertEqual(model.selectedSubtitleId, fullID)
            await finish(model)
        }
    }

    /// Off in the player used to set Behaviour to Off for everything, so
    /// forced subtitles never came back. Now it holds for this viewing only.
    func testPlayerOffKeepsSettingsAndCarriesToTheNextEpisode() async throws {
        try await withEnglishAutoSettings {
            let model = PlayerViewModel()
            model.disableSubtitles()
            XCTAssertEqual(PlayerSettings.shared.preferredSubtitleMode, SubtitleMode.auto.rawValue)

            try playNextEpisode(model)
            XCTAssertNil(model.selectedSubtitleId)
            await finish(model)
        }
    }

    /// Without a player pick, the next episode follows Settings > Subtitles.
    func testNextEpisodeWithoutAPlayerPickFollowsSettings() async throws {
        try await withEnglishAutoSettings {
            let model = PlayerViewModel()
            try playNextEpisode(model)
            XCTAssertEqual(model.selectedSubtitleId, forcedID)
            await finish(model)
        }
    }

    /// A forced pick carries as a forced pick, not as the full track.
    func testForcedPlayerPickCarriesAsForced() async throws {
        let prefs = PlayerViewModel.viewingSubtitlePrefs(for: subtitle(forcedID, forced: true))
        XCTAssertEqual(prefs.mode, .always)
        XCTAssertTrue(prefs.forcedOnly)
        XCTAssertEqual(prefs.trackSignature?.forced, true)
        try await withEnglishAutoSettings {
            let model = PlayerViewModel()
            model.viewingSubtitlePrefs = prefs
            try playNextEpisode(model)
            XCTAssertEqual(model.selectedSubtitleId, forcedID)
            // An episode without a forced English track stays without
            // subtitles; it doesn't swap in the full track.
            try playNextEpisode(model, withForcedTrack: false)
            XCTAssertNil(model.selectedSubtitleId)
            model.viewingSubtitlePrefs = PlayerViewModel.viewingSubtitlePrefs(for: subtitle(fullID, forced: false))
            try playNextEpisode(model)
            XCTAssertEqual(model.selectedSubtitleId, fullID)
            await finish(model)
        }
    }

    /// After the viewer switches audio, the load's ordinal describes the old
    /// track. With an untagged transcode it must not be read as the new
    /// track's language; unknown audio keeps the full track.
    func testAudioSwitchDoesNotReuseTheLoadOrdinal() async {
        await withEnglishAutoSettings {
            let model = makeModel()
            model.currentSelectedVersion = version(audio: ["eng", "jpn"])
            model.lastLoadRequest = .init(contentId: "movie", preferredFileId: 42, preferredAudioTrackIndex: 0,
                                          preferredSubtitleTrackIndex: nil, preferredSidecarSubtitleTrackId: nil,
                                          startFromBeginning: false)
            let switched = audio(japaneseAudioID, lang: "und", ordinal: 0, selected: true)
            model.audioTracks = [switched]
            establishLoad(model)
            model.selectAudio(switched)
            XCTAssertEqual(model.selectedSubtitleId, fullID)
            await finish(model)
        }
    }

    /// Auto depends on the audio, so switching from English to Japanese audio
    /// swaps the forced track for the full one with Settings > Subtitles in
    /// charge, not only with Use Device Settings. A pick made for the item
    /// stays put.
    func testAudioSwitchReresolvesAutoFromSettings() async {
        await withEnglishAutoSettings {
            let model = makeModel()
            let english = audio(englishAudioID, lang: "eng", ordinal: 0, selected: true)
            let japanese = audio(japaneseAudioID, lang: "jpn", ordinal: 1, selected: false)
            model.audioTracks = [english, japanese]
            model.selectedAudioId = englishAudioID
            establishLoad(model)
            model.applyAutoSubtitlePreferencesIfNeeded()
            XCTAssertEqual(model.selectedSubtitleId, forcedID)

            model.selectAudio(japanese)
            XCTAssertEqual(model.selectedSubtitleId, fullID)

            model.hasExplicitSubtitleChoice = true
            model.selectAudio(english)
            XCTAssertEqual(model.selectedSubtitleId, fullID)
            await finish(model)
        }
    }

    /// A refused Silo audio switch leaves the original audio playing, so the
    /// load's ordinal must keep naming it.
    func testRefusedAudioSwitchKeepsTheLoadOrdinal() async {
        let model = makeModel()
        let plan = PlaybackEndFixtures.plan(sessionId: "fixture-session", durationSeconds: 3_600)
        model.activePreparedProtocolV3 = PreparedPlaybackV3(
            playbackAttemptId: "apple:fixture-attempt",
            planAttemptId: "apple-plan:fixture-attempt",
            planAttemptKey: plan.planAttemptKey,
            outputContextId: ApplePlaybackV3Capabilities.snapshot().outputContextId,
            serverFeatures: [PlaybackProtocolV3.planFeature],
            plan: plan
        )
        // No server ordinal, so the replan is refused before it is issued.
        let unmappable = PlayerTrack(trackId: japaneseAudioID, kind: .audio, title: nil, lang: "und",
                                     codec: "eac3", audioChannelCount: 6, bitrate: nil, isDefault: false,
                                     isForced: false, isHearingImpaired: false, isExternal: false,
                                     isSelected: false, ffIndex: nil, srcId: nil)
        model.audioTracks = [audio(englishAudioID, lang: "eng", ordinal: 0, selected: true), unmappable]
        model.selectedAudioId = englishAudioID
        model.selectAudio(unmappable)
        XCTAssertEqual(model.selectedAudioId, englishAudioID)
        XCTAssertFalse(model.audioPickedForCurrentItem)
        await finish(model)
    }

    /// A Silo replan (audio switch, quality change) reloads the engine with
    /// subtitles off. The embedded subtitle playing before it is read back by
    /// its stream index, so the reload puts it back; Off stays Off.
    func testReplanReadsBackThePlayingEmbeddedSubtitle() async {
        let model = makeModel()
        let plan = PlaybackEndFixtures.plan(sessionId: "fixture-session", durationSeconds: 3_600)
        model.activePreparedProtocolV3 = PreparedPlaybackV3(
            playbackAttemptId: "apple:fixture-attempt",
            planAttemptId: "apple-plan:fixture-attempt",
            planAttemptKey: plan.planAttemptKey,
            outputContextId: ApplePlaybackV3Capabilities.snapshot().outputContextId,
            serverFeatures: [PlaybackProtocolV3.planFeature],
            plan: plan
        )
        model.hasExplicitSubtitleChoice = true
        model.selectedSubtitleId = fullID
        XCTAssertEqual(model.resolvedSubtitleTrackIndexForResume(), Int(fullID))
        model.selectedSubtitleId = nil
        XCTAssertEqual(model.resolvedSubtitleTrackIndexForResume(), -1)
        await finish(model)
    }

    /// A manual pick still wins over Auto.
    func testExplicitChoiceIsNotOverridden() async {
        let model = makeModel()
        model.audioTracks = [audio(englishAudioID, lang: "eng", ordinal: 0, selected: true)]
        model.selectedAudioId = englishAudioID
        model.selectedSubtitleId = fullID
        model.hasExplicitSubtitleChoice = true
        establishLoad(model)
        model.applyAutoSubtitlePreferencesIfNeeded()
        XCTAssertEqual(model.selectedSubtitleId, fullID)
        await finish(model)
    }
}
