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
        // Forced Only follows the audio: English audio gets the forced English
        // track, Japanese audio has no forced Japanese track.
        XCTAssertEqual(label(film), "Auto: English (Forced)")
        XCTAssertEqual(label(film, audio: 1), "Auto: Off")
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

    /// Always with Language set to None shows subtitles rather than nothing.
    func testAlwaysWithoutLanguageShowsATrack() throws {
        let settings = PlayerSettings.shared
        settings.preferredSubtitleLanguage = PlaybackPrefSentinel.none
        settings.preferredSubtitleMode = SubtitleMode.always.rawValue
        XCTAssertEqual(label(try film()), "English")
        settings.preferredSubtitleMode = SubtitleMode.auto.rawValue
        XCTAssertEqual(label(try film()), "Auto: Off")
    }

    /// Use Device Settings on Automatic follows the device's language, as
    /// Apple's Automatic does, not the history of caption languages.
    func testDeviceAutomaticFollowsTheDeviceLanguage() throws {
        let settings = PlayerSettings.shared
        settings.setSubtitleMatchesSystemAppearance(true)
        settings.subtitleSystemSelectionPreferences = .init(
            displayMode: .automatic, preferredLanguages: ["es"], prefersAccessibilityTracks: false,
            deviceLanguages: ["en-AU"])
        let film = try film()
        XCTAssertEqual(label(film), "Auto: English (Forced)")
        XCTAssertEqual(label(film, audio: 1), "Auto: English")
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
/// external files. The same appearance has to look the same in both, so
/// libass's options are worked out from the overlay's sizes.
final class LucidSubtitleStyleTests: XCTestCase {
    /// Equal line heights, so the box padding is the overlay's alone.
    private let face = LucidSubtitleStyle.Face(name: "Helvetica Neue", bold: true,
                                               assHeightPerEm: 1.2, overlayLineHeightPerEm: 1.2)
    private let size = SubtitleFontSizePreset.large.pointSize

    private func options(_ appearance: SubtitleAppearance,
                         geometry: LucidSubtitleStyle.Geometry? = nil) -> [String: String] {
        LucidSubtitleStyle.options(appearance, geometry: geometry, face: face)
    }

    private func value(_ options: [String: String], _ key: String) -> Double {
        Double(options[key] ?? "") ?? .nan
    }

    func testDefaultBoxMatchesTheOverlay() {
        let options = options(.default)
        #if os(tvOS)
        XCTAssertEqual(options["sub-font-size"], "46.4")
        #else
        XCTAssertEqual(options["sub-font-size"], "43.2")
        #endif
        XCTAssertEqual(options, options.merging([
            "sub-ass-override": "no", "secondary-sub-ass-override": "no",
            "sub-font": "Helvetica Neue", "sub-bold": "yes",
            "sub-color": "#FFFFFFFF", "sub-border-style": "background-box",
            "sub-back-color": "#BF000000", "sub-outline-color": "#FF000000",
            "sub-outline-size": "0", "sub-shadow-offset": "3.33",
            "sub-align-y": "bottom", "sub-margin-y": "60", "sub-margin-x": "73",
            "sub-pos": "99.86", "secondary-sub-pos": "90.04",
            "sub-scale-with-window": "no", "sub-use-margins": "no"
        ]) { _, golden in golden })
        XCTAssertEqual(options.count, 18)
    }

    /// The overlay puts text 8% in from the edge, 27% up for Lower Third, and
    /// a secondary subtitle at 17% (36%). A box moves the text in by its
    /// padding, so the box lands there instead. The margin always matches
    /// the overlay's top inset, so a cue a file moves up with {\an8} isn't
    /// pushed against the top edge.
    func testPositionsMatchTheOverlay() {
        var plain = SubtitleAppearance.default
        plain.backgroundStyle = .none
        let cases: [(SubtitlePositionPreset, String, String, String, String)] = [
            (.bottom, "bottom", "58", "99.98", "90.2"),
            (.lowerThird, "bottom", "58", "79.34", "69.55"),
            (.top, "top", "58", "99.98", "90.2"),
        ]
        for (position, align, margin, primary, secondary) in cases {
            plain.position = position
            let options = options(plain)
            XCTAssertEqual(options["sub-align-y"], align, "\(position)")
            XCTAssertEqual(options["sub-margin-y"], margin, "\(position)")
            XCTAssertEqual(options["sub-pos"], primary, "\(position)")
            XCTAssertEqual(options["secondary-sub-pos"], secondary, "\(position)")
            XCTAssertEqual(options["sub-margin-x"], "68", "\(position)")
        }
        var boxed = SubtitleAppearance.default
        boxed.position = .top
        XCTAssertEqual(options(boxed)["sub-margin-y"], "60")
        boxed.position = .lowerThird
        XCTAssertEqual(options(boxed)["sub-pos"], "79.13")
    }

    /// The overlay draws no box at 0% opacity, so libass mustn't either.
    func testTransparentBoxDrawsNoBox() {
        var appearance = SubtitleAppearance.default
        appearance.backgroundOpacity = 0
        let options = options(appearance)
        XCTAssertEqual(options["sub-border-style"], "outline-and-shadow")
        XCTAssertEqual(options["sub-shadow-offset"], "0")
        XCTAssertEqual(options["sub-back-color"], "#00000000")
        XCTAssertEqual(options["sub-pos"], "99.98")
    }

    /// libass has one box, so a glyph background inside a caption window
    /// becomes one box in the two colours composited, padded by both.
    func testGlyphBackgroundAndCaptionWindowShareOneBox() {
        var appearance = SubtitleAppearance.default
        appearance.backgroundColor = "#112233"
        appearance.backgroundOpacity = 50
        appearance.captionWindowColor = "#ffffff"
        appearance.captionWindowOpacity = 50
        var options = options(appearance)
        XCTAssertEqual(options["sub-border-style"], "background-box")
        XCTAssertEqual(options["sub-back-color"], "#BF606C77")
        XCTAssertEqual(options["sub-shadow-offset"], "6")

        appearance.backgroundStyle = .none
        appearance.captionWindowOpacity = 60
        options = self.options(appearance)
        XCTAssertEqual(options["sub-border-style"], "background-box")
        XCTAssertEqual(options["sub-back-color"], "#99FFFFFF")
        XCTAssertEqual(options["sub-shadow-offset"], "2.67")
    }

    func testBoxUsesTheBoxColourAndOpacity() {
        var appearance = SubtitleAppearance.default
        appearance.backgroundColor = "#112233"
        appearance.backgroundOpacity = 50
        let options = options(appearance)
        XCTAssertEqual(options["sub-border-style"], "background-box")
        XCTAssertEqual(options["sub-back-color"], "#80112233")
    }

    /// Shadow without a box: libass took the shadow colour from the box
    /// settings, so a 0% box opacity made the shadow invisible. It's black at
    /// 85%, as the overlay draws it.
    func testShadowStyleUsesTheOverlaysShadowColour() {
        var appearance = SubtitleAppearance.default
        appearance.backgroundStyle = .shadow
        appearance.backgroundOpacity = 0
        let options = options(appearance)
        XCTAssertEqual(options["sub-border-style"], "outline-and-shadow")
        XCTAssertEqual(options["sub-back-color"], "#D9000000")
        XCTAssertEqual(options["sub-shadow-offset"], "2")
    }

    /// The overlay's four stacked outline shadows reach twice their offset.
    func testOutlineMatchesTheOverlaysReach() {
        var appearance = SubtitleAppearance.default
        appearance.backgroundStyle = .none
        appearance.textOutline = true
        XCTAssertEqual(value(options(appearance), "sub-outline-size"), 2 * min(2, 0.03 * size) * 2 / 3, accuracy: 0.006)
        appearance.textOutline = false
        XCTAssertEqual(options(appearance)["sub-outline-size"], "0")
    }

    /// Device edges are drawn as a hard shadow of the overlay's offset and
    /// colour, without the outline the overlay doesn't draw either: raised
    /// is white up and left, depressed black down and right.
    func testDeviceEdgesMatchTheOverlay() {
        var appearance = SubtitleAppearance.default
        appearance.backgroundStyle = .none
        appearance.textOutline = true
        let offset = min(2, 0.03 * size) * 2 / 3
        appearance.systemTextEdgeStyle = .raised
        var options = options(appearance)
        XCTAssertEqual(options["sub-outline-size"], "0")
        XCTAssertEqual(value(options, "sub-shadow-offset"), -offset, accuracy: 0.006)
        XCTAssertEqual(options["sub-back-color"], "#CCFFFFFF")
        appearance.systemTextEdgeStyle = .depressed
        options = self.options(appearance)
        XCTAssertEqual(value(options, "sub-shadow-offset"), offset, accuracy: 0.006)
        XCTAssertEqual(options["sub-back-color"], "#E6000000")
        appearance.systemTextEdgeStyle = .uniform
        options = self.options(appearance)
        XCTAssertEqual(value(options, "sub-outline-size"), 2 * offset, accuracy: 0.006)
        XCTAssertEqual(options["sub-shadow-offset"], "0")
    }

    /// Translucent text fades its outline and shadow with it, as SwiftUI
    /// fades a view's shadows; the box keeps its own opacity.
    func testTextOpacityFadesOutlineAndShadow() {
        var appearance = SubtitleAppearance.default
        appearance.backgroundStyle = .shadow
        appearance.textOutline = true
        appearance.fontOpacity = 50
        let options = options(appearance)
        XCTAssertEqual(options["sub-color"], "#80FFFFFF")
        XCTAssertEqual(options["sub-outline-color"], "#80000000")
        XCTAssertEqual(options["sub-back-color"], "#6C000000")
        appearance.backgroundStyle = .box
        XCTAssertEqual(self.options(appearance)["sub-back-color"], "#BF000000")
    }

    /// On a small picture the overlay's point minimums take over, so libass
    /// gets the same larger padding and edge.
    func testSmallPictureUsesTheOverlaysMinimums() {
        let small = LucidSubtitleStyle.Geometry(videoHeight: 226, videoAspect: 16.0 / 9)
        XCTAssertEqual(value(options(.default, geometry: small), "sub-shadow-offset"), 3 / (226.0 / 1080) * 2 / 3, accuracy: 0.006)
        var outline = SubtitleAppearance.default
        outline.backgroundStyle = .none
        outline.textOutline = true
        XCTAssertEqual(value(options(outline, geometry: small), "sub-outline-size"), 2 * 0.5 / (226.0 / 1080) * 2 / 3, accuracy: 0.006)
        let large = LucidSubtitleStyle.Geometry(videoHeight: 1080, videoAspect: 16.0 / 9)
        XCTAssertEqual(options(.default, geometry: large), options(.default))
    }

    /// Lines wrap at 86% of the video's width, less the box's padding.
    func testWrapWidthFollowsTheVideoShape() {
        let scope = LucidSubtitleStyle.Geometry(videoHeight: 1080, videoAspect: 2.39)
        XCTAssertEqual(options(.default, geometry: scope)["sub-margin-x"], "70")
        var plain = SubtitleAppearance.default
        plain.backgroundStyle = .none
        XCTAssertEqual(options(plain, geometry: scope)["sub-margin-x"], "68")
    }

    /// mpv fits the picture inside the layer whatever the Zoom setting.
    func testGeometryIsTheFittedPicture() {
        let picture = CGSize(width: 1920, height: 1080)
        XCTAssertEqual(LucidSubtitleStyle.Geometry(layer: CGSize(width: 874, height: 402), picture: picture),
                       LucidSubtitleStyle.Geometry(videoHeight: 402, videoAspect: 1.78))
        XCTAssertEqual(LucidSubtitleStyle.Geometry(layer: CGSize(width: 402, height: 874), picture: picture)?.videoHeight, 226)
        XCTAssertNil(LucidSubtitleStyle.Geometry(layer: CGSize(width: 402, height: 874), picture: nil))
    }

    /// The stand-in faces are installed on iPhone, iPad and Apple TV, and
    /// their metrics are read the way libass reads them.
    func testFacesResolveWithLibassMetrics() {
        let sans = LucidSubtitleStyle.face(for: .sansSerif)
        XCTAssertEqual(sans.name, "Helvetica Neue")
        XCTAssertTrue(sans.bold)
        XCTAssertEqual(sans.assHeightPerEm, 1.192, accuracy: 0.005)
        XCTAssertEqual(sans.overlayLineHeightPerEm, 1.19, accuracy: 0.05)
        let serif = LucidSubtitleStyle.face(for: .serif)
        XCTAssertEqual(serif.name, "Times New Roman")
        XCTAssertTrue(serif.bold)
        XCTAssertEqual(serif.assHeightPerEm, 1.107, accuracy: 0.005)
        let mono = LucidSubtitleStyle.face(for: .monospace)
        XCTAssertEqual(mono.name, "Menlo")
        XCTAssertTrue(mono.bold)
        XCTAssertEqual(mono.assHeightPerEm, 1.164, accuracy: 0.005)
        let arial = LucidSubtitleStyle.face(for: .custom("Arial"))
        XCTAssertEqual(arial.name, "Arial")
        XCTAssertFalse(arial.bold)
        XCTAssertEqual(arial.assHeightPerEm, 1.117, accuracy: 0.005)
    }
}
