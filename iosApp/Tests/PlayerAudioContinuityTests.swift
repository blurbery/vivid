import XCTest
#if os(tvOS)
@testable import VividTV
#else
@testable import Vivid
#endif

/// The audio that plays stays the audio the viewer has: through reloads of
/// the same title, into next episodes of the same viewing, and in what Emby
/// and Jellyfin are told is playing. iOS and Apple TV.
@MainActor
final class PlayerAudioContinuityTests: XCTestCase {
    private func catalogueAudio(_ language: String?, codec: String = "eac3") -> AudioTrack {
        AudioTrack(index: nil, codec: codec, channels: 6, channelLayout: "5.1", bitrate: 640_000,
                   sampleRate: 48_000, language: language, title: nil, embeddedTitle: nil, isDefault: nil)
    }

    private func version(audio languages: [String?]) -> FileVersion {
        FileVersion(fileId: 42, fileName: "fixture.mkv", resolution: "3840x2160", codecVideo: "hevc",
                    codecAudio: "eac3", hdr: false, container: "mkv", fileSize: 1_000,
                    duration: 7_200, bitrate: 20_000_000, videoTracks: nil,
                    audioTracks: languages.map { catalogueAudio($0) }, subtitleTracks: nil, chapters: nil)
    }

    private func audio(_ id: Int64, lang: String?, ordinal: Int) -> PlayerTrack {
        PlayerTrack(trackId: id, kind: .audio, title: nil, lang: lang, codec: "eac3",
                    audioChannelCount: 6, bitrate: nil, isDefault: ordinal == 0, isForced: false,
                    isHearingImpaired: false, isExternal: false, isSelected: false,
                    ffIndex: Int(id), srcId: ordinal)
    }

    private func subtitle(_ id: Int64, external: Bool = false, ffIndex: Int? = nil) -> PlayerTrack {
        PlayerTrack(trackId: id, kind: .sub, title: nil, lang: "eng", codec: "subrip",
                    audioChannelCount: nil, bitrate: nil, isDefault: false, isForced: false,
                    isHearingImpaired: false, isExternal: external, isSelected: false,
                    ffIndex: ffIndex, srcId: nil)
    }

    private func finish(_ model: PlayerViewModel) async {
        model.cleanup()
        await model.waitForCleanupCompletion()
    }

    // MARK: - Reloads

    /// A transcode carries one audio track, so the engine calls it ordinal 0.
    /// A quality change or session renewal must ask for the file's Japanese
    /// track again, not the file's first (English) one.
    func testReloadKeepsTheTranscodesAudioWhenItsListDoesNotLineUp() async {
        let model = PlayerViewModel()
        model.currentSelectedVersion = version(audio: ["eng", "jpn"])
        model.audioTracks = [audio(1, lang: "jpn", ordinal: 0)]
        model.selectedAudioId = 1
        model.loadAudioOrdinal = 1
        XCTAssertNil(model.engineCatalogAudioOrdinal)
        XCTAssertEqual(model.resolvedAudioTrackIndexForResume(), 1)
        await finish(model)
    }

    /// When every track of the file is playable, a switch made in the player
    /// is what a reload asks for.
    func testReloadUsesASwitchMadeInThePlayer() async {
        let model = PlayerViewModel()
        model.currentSelectedVersion = version(audio: ["eng", "jpn"])
        model.audioTracks = [audio(1, lang: "eng", ordinal: 0), audio(2, lang: "jpn", ordinal: 1)]
        model.selectedAudioId = 2
        model.loadAudioOrdinal = 0
        XCTAssertEqual(model.resolvedAudioTrackIndexForResume(), 1)
        await finish(model)
    }

    // MARK: - Next episodes

    func testNextEpisodePrefersTheLanguagePickedInThisViewing() {
        let both = [catalogueAudio("eng"), catalogueAudio("jpn")]
        XCTAssertEqual(
            VividInitialAudioPreference.preferredLanguage(viewing: "jpn", settings: "en", tracks: both),
            "jpn"
        )
        XCTAssertEqual(
            VividInitialAudioPreference.selectedOrdinal(
                manual: nil, tracks: both,
                preferredLanguage: VividInitialAudioPreference.preferredLanguage(
                    viewing: "jpn", settings: "en", tracks: both
                )
            ),
            1
        )
        // Nothing picked: Settings.
        XCTAssertEqual(
            VividInitialAudioPreference.preferredLanguage(viewing: nil, settings: "en", tracks: both),
            "en"
        )
        // An episode without the picked language follows Settings, not
        // straight to English.
        let frenchAndEnglish = [catalogueAudio("eng"), catalogueAudio("fra")]
        XCTAssertEqual(
            VividInitialAudioPreference.preferredLanguage(viewing: "jpn", settings: "fr", tracks: frenchAndEnglish),
            "fr"
        )
    }

    /// A switch in the player carries its language to the next episodes.
    func testAudioPickInThePlayerCarriesItsLanguage() async {
        let model = PlayerViewModel()
        model.currentSelectedVersion = version(audio: ["eng", "jpn"])
        let english = audio(1, lang: "eng", ordinal: 0)
        let japanese = audio(2, lang: "jpn", ordinal: 1)
        model.audioTracks = [english, japanese]
        model.selectedAudioId = 1
        model.selectAudio(japanese)
        XCTAssertEqual(model.viewingAudioLanguage, "jpn")
        await finish(model)
    }

    /// An untagged stream takes the catalogue's language for that track; a
    /// track with no language at all carries nothing, so Settings applies.
    func testViewingLanguageFallsBackToTheCatalogue() {
        let catalog = [catalogueAudio("eng"), catalogueAudio("jpn"), catalogueAudio("und")]
        XCTAssertEqual(PlayerViewModel.viewingAudioLanguage(stream: nil, catalog: catalog, ordinal: 1), "jpn")
        XCTAssertEqual(PlayerViewModel.viewingAudioLanguage(stream: "ger", catalog: catalog, ordinal: 1), "ger")
        XCTAssertNil(PlayerViewModel.viewingAudioLanguage(stream: nil, catalog: catalog, ordinal: 2))
        XCTAssertNil(PlayerViewModel.viewingAudioLanguage(stream: nil, catalog: catalog, ordinal: 7))
        XCTAssertNil(PlayerViewModel.viewingAudioLanguage(stream: nil, catalog: [], ordinal: nil))
    }

    // MARK: - Emby and Jellyfin reports

    func testReportedTracksNameWhatIsPlaying() async {
        let model = PlayerViewModel()
        model.currentSelectedVersion = version(audio: ["eng", "jpn"])
        model.audioTracks = [audio(1, lang: "eng", ordinal: 0), audio(2, lang: "jpn", ordinal: 1)]
        model.selectedAudioId = 2
        let sidecarID = SubtitleTrackIdSpace.makeSidecarTrackId(urlIndex: 7)
        let openSubtitlesID: Int64 = 9_000_000_001
        model.subtitleTracks = [subtitle(3, ffIndex: 3), subtitle(sidecarID, external: true),
                                subtitle(openSubtitlesID, external: true)]

        model.selectedSubtitleId = nil
        XCTAssertEqual(model.playingTracksForServer, .init(audioOrdinal: 1, subtitle: .off))
        model.selectedSubtitleId = 3
        XCTAssertEqual(model.playingTracksForServer.subtitle, .embedded(3))
        model.selectedSubtitleId = sidecarID
        XCTAssertEqual(model.playingTracksForServer.subtitle, .serverStream(7))
        model.selectedSubtitleId = openSubtitlesID
        XCTAssertEqual(model.playingTracksForServer.subtitle, .off)

        // A transcode's single track can't be named by the file's ordinal.
        model.audioTracks = [audio(1, lang: "jpn", ordinal: 0)]
        model.selectedAudioId = 1
        XCTAssertNil(model.playingTracksForServer.audioOrdinal)
        await finish(model)
    }

    func testReportedStreamIndexesMapToTheServersStreams() {
        let audioStreams: [Int?] = [1, 2]
        let japanese = MediaServerPlayingTracks(audioOrdinal: 1, subtitle: .embedded(5))
        XCTAssertTrue(japanese.streamIndexes(
            audioStreamIndexes: audioStreams, directPlay: true, initialAudio: 1, initialSubtitle: nil
        ) == (2, 5))
        // A transcode keeps what the session asked for: its own audio, and no
        // embedded stream index that names a container it isn't sending.
        XCTAssertTrue(MediaServerPlayingTracks(audioOrdinal: nil, subtitle: .embedded(5)).streamIndexes(
            audioStreamIndexes: audioStreams, directPlay: false, initialAudio: 2, initialSubtitle: nil
        ) == (2, -1))
        XCTAssertTrue(MediaServerPlayingTracks(audioOrdinal: 0, subtitle: .serverStream(9)).streamIndexes(
            audioStreamIndexes: audioStreams, directPlay: false, initialAudio: 2, initialSubtitle: nil
        ) == (1, 9))
        // Before the player has said anything, the session's own tracks.
        XCTAssertTrue(MediaServerPlayingTracks().streamIndexes(
            audioStreamIndexes: audioStreams, directPlay: true, initialAudio: 1, initialSubtitle: nil
        ) == (1, -1))
    }
}
