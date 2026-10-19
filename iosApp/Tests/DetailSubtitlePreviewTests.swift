import XCTest
#if os(tvOS)
@testable import VividTV
#else
@testable import Vivid
#endif

/// The detail page's subtitle row shows what playback will pick from
/// Settings > Subtitles, or from the device's caption settings, using the
/// player's own resolver and audio choice. It never reads a server's
/// remembered subtitle mode, so it reads the same on Silo, Emby and Jellyfin.
@MainActor
final class DetailSubtitlePreviewTests: XCTestCase {
    private var saved: (language: String, mode: String, forced: Bool, device: Bool, audio: String, backup: String)!

    override func setUp() async throws {
        let settings = PlayerSettings.shared
        saved = (settings.preferredSubtitleLanguage, settings.preferredSubtitleMode,
                 settings.showForcedSubtitles, settings.subtitleMatchesSystemAppearance,
                 settings.audioLanguage, settings.preferredSubtitleBackupLanguage)
        settings.setSubtitleMatchesSystemAppearance(false)
        settings.preferredSubtitleLanguage = "en"
        settings.preferredSubtitleMode = SubtitleMode.auto.rawValue
        settings.showForcedSubtitles = true
        settings.audioLanguage = "en"
        settings.preferredSubtitleBackupLanguage = PlaybackPrefSentinel.none
    }

    override func tearDown() async throws {
        let settings = PlayerSettings.shared
        settings.preferredSubtitleLanguage = saved.language
        settings.preferredSubtitleMode = saved.mode
        settings.showForcedSubtitles = saved.forced
        settings.audioLanguage = saved.audio
        settings.preferredSubtitleBackupLanguage = saved.backup
        settings.setSubtitleMatchesSystemAppearance(saved.device)
    }

    private func version(_ json: String) throws -> FileVersion {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(FileVersion.self, from: Data(json.utf8))
    }

    /// English and Japanese audio; a full English track and a forced one.
    private func film() throws -> FileVersion {
        try version("""
        {
          "file_id": 1,
          "audio_tracks": [
            { "codec": "eac3", "language": "eng", "default": true },
            { "codec": "aac", "language": "jpn" }
          ],
          "subtitle_tracks": [
            { "index": 3, "codec": "subrip", "language": "eng" },
            { "index": 4, "codec": "subrip", "language": "eng", "forced": true }
          ]
        }
        """)
    }

    private func label(_ version: FileVersion?, audio: Int? = nil) -> String {
        DetailPlaybackFormatting.automaticSubtitleLabel(version: version, selectedAudioTrackIndex: audio)
    }

    /// The reported setup: English, Auto, Show Forced Subtitles on. English
    /// audio plays the forced track only, foreign audio the full track.
    func testAutoWithForcedShowsTheForcedTrackForEnglishAudio() throws {
        let film = try film()
        XCTAssertEqual(label(film), "Auto: English (Forced)")
        XCTAssertEqual(label(film, audio: 1), "Auto: English")
    }

    func testAutoWithoutForcedShowsOffForEnglishAudio() throws {
        PlayerSettings.shared.showForcedSubtitles = false
        XCTAssertEqual(label(try film()), "Auto: Off")
    }

    func testAlwaysShowsTheFullTrack() throws {
        PlayerSettings.shared.preferredSubtitleMode = SubtitleMode.always.rawValue
        XCTAssertEqual(label(try film()), "English")
    }

    func testOffShowsOffEvenWithForcedOn() throws {
        PlayerSettings.shared.preferredSubtitleMode = SubtitleMode.off.rawValue
        XCTAssertEqual(label(try film()), "Off")
    }

    /// The audio language comes from the player's own rule (Settings audio
    /// language), not the file's default track, so the row and playback agree.
    func testAudioFollowsThePlayersAudioChoice() throws {
        let japaneseFirst = try version("""
        {
          "file_id": 2,
          "audio_tracks": [
            { "codec": "aac", "language": "jpn", "default": true },
            { "codec": "eac3", "language": "eng" }
          ],
          "subtitle_tracks": [
            { "index": 3, "codec": "subrip", "language": "eng" },
            { "index": 4, "codec": "subrip", "language": "eng", "title": "Forced" }
          ]
        }
        """)
        XCTAssertEqual(label(japaneseFirst), "Auto: English (Forced)")
        PlayerSettings.shared.audioLanguage = "ja"
        XCTAssertEqual(label(japaneseFirst), "Auto: English")
    }

    /// A file without subtitles still shows the row, reading Off.
    func testFileWithoutSubtitlesStillShowsTheRow() throws {
        let bare = try version(#"{ "file_id": 3, "audio_tracks": [{ "codec": "aac", "language": "eng" }] }"#)
        XCTAssertTrue(DetailPlaybackFormatting.shouldShowSubtitleValue(version: bare))
        XCTAssertEqual(label(bare), "Auto: Off")
        XCTAssertFalse(DetailPlaybackFormatting.shouldShowSubtitleValue(version: nil))
    }

    /// Use Device Settings: the device's display mode and languages decide,
    /// as they do in the player.
    func testDeviceSettingsDecideTheRow() throws {
        let settings = PlayerSettings.shared
        settings.setSubtitleMatchesSystemAppearance(true)
        let film = try film()
        settings.subtitleSystemSelectionPreferences = .init(
            displayMode: .alwaysOn, preferredLanguages: ["en"], prefersAccessibilityTracks: false)
        XCTAssertEqual(label(film), "English")
        settings.subtitleSystemSelectionPreferences = .init(
            displayMode: .forcedOnly, preferredLanguages: ["en"], prefersAccessibilityTracks: false)
        XCTAssertEqual(label(film, audio: 1), "Auto: English (Forced)")
        settings.subtitleSystemSelectionPreferences = .init(
            displayMode: .automatic, preferredLanguages: ["en"], prefersAccessibilityTracks: false)
        XCTAssertEqual(label(film), "Auto: English (Forced)")
        XCTAssertEqual(label(film, audio: 1), "Auto: English")
        settings.subtitleSystemSelectionPreferences = .init(
            displayMode: .automatic, preferredLanguages: ["fr"], prefersAccessibilityTracks: false)
        XCTAssertEqual(label(film, audio: 1), "Auto: Off")
    }

    /// Arabic with an English backup, on an English film with only English
    /// subtitles: the row promises the English track. With Language set to
    /// None, the backup does nothing.
    func testBackupLanguageShowsWhenTheMainLanguageIsMissing() throws {
        let settings = PlayerSettings.shared
        settings.preferredSubtitleLanguage = "ar"
        settings.preferredSubtitleBackupLanguage = "en"
        XCTAssertEqual(label(try film()), "Auto: English")
        settings.preferredSubtitleLanguage = PlaybackPrefSentinel.none
        XCTAssertEqual(label(try film()), "Auto: Off")
    }

    /// Setting Language to the backup's language clears the backup, so the
    /// Backup Language picker never points at a row it doesn't list.
    func testChoosingTheBackupAsLanguageClearsTheBackup() {
        let settings = PlayerSettings.shared
        settings.preferredSubtitleLanguage = "ar"
        settings.preferredSubtitleBackupLanguage = "en"
        #if os(tvOS)
        let viewModel = TVSettingsViewModel()
        #else
        let viewModel = SettingsViewModel()
        #endif
        viewModel.editorSubtitleLanguage = "fr"
        XCTAssertEqual(settings.preferredSubtitleBackupLanguage, "en")
        viewModel.editorSubtitleLanguage = "en"
        XCTAssertEqual(settings.preferredSubtitleBackupLanguage, PlaybackPrefSentinel.none)
    }

    /// A bitmap subtitle file beside the media never plays, so the row
    /// doesn't promise it.
    func testServerBitmapSubtitleFileIsNotPromised() throws {
        let sup = try version("""
        {
          "file_id": 4,
          "audio_tracks": [{ "codec": "aac", "language": "jpn" }],
          "subtitle_tracks": [
            { "index": 7, "codec": "pgssub", "language": "eng", "external": true, "external_path": "movie.en.sup" }
          ]
        }
        """)
        XCTAssertEqual(label(sup), "Auto: Off")
    }
}

/// Embedded and ASS subtitles are styled by libass; the text overlay draws
/// external files. The same appearance has to look the same in both.
final class LucidSubtitleStyleTests: XCTestCase {
    /// Shadow without a box: libass took the shadow colour from the box
    /// settings, so a 0% box opacity made the shadow invisible. It's black at
    /// 85%, as the overlay draws it.
    func testShadowStyleUsesTheOverlaysShadowColour() {
        var appearance = SubtitleAppearance.default
        appearance.backgroundStyle = .shadow
        appearance.backgroundOpacity = 0
        let options = LucidSubtitleStyle.options(appearance)
        XCTAssertEqual(options["sub-border-style"], "outline-and-shadow")
        XCTAssertEqual(options["sub-back-color"], "#D9000000")
        XCTAssertEqual(options["sub-shadow-offset"], "2")
    }

    func testBoxUsesTheBoxColourAndOpacity() {
        var appearance = SubtitleAppearance.default
        appearance.backgroundStyle = .box
        appearance.backgroundColor = "#112233"
        appearance.backgroundOpacity = 50
        let options = LucidSubtitleStyle.options(appearance)
        XCTAssertEqual(options["sub-border-style"], "background-box")
        XCTAssertEqual(options["sub-back-color"], "#80112233")
    }

    /// A device raised edge is drawn as a shadow, without the outline the
    /// overlay doesn't draw either.
    func testDeviceRaisedEdgeHasNoOutline() {
        var appearance = SubtitleAppearance.default
        appearance.backgroundStyle = .none
        appearance.textOutline = true
        appearance.systemTextEdgeStyle = .raised
        let options = LucidSubtitleStyle.options(appearance)
        XCTAssertEqual(options["sub-outline-size"], "0")
        XCTAssertEqual(options["sub-shadow-offset"], "2")
        appearance.systemTextEdgeStyle = .uniform
        XCTAssertEqual(LucidSubtitleStyle.options(appearance)["sub-outline-size"], "1.33")
    }
}
