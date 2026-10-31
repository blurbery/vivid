import XCTest
@testable import Vivid

/// The version, edition, audio and subtitle text detail pages show, decoded
/// from server JSON so the inputs the formatting relies on are checked too.
@MainActor
final class DetailPlaybackLabelTests: XCTestCase {
    private func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }

    private func versions(_ json: String) throws -> [FileVersion] {
        try decoder().decode([FileVersion].self, from: Data(json.utf8))
    }

    private func version(_ json: String) throws -> FileVersion {
        try decoder().decode(FileVersion.self, from: Data(json.utf8))
    }

    private func subtitles(_ json: String) throws -> FileVersion {
        try version(#"{"file_id":1,"resolution":"1080p","subtitle_tracks":"# + json + "}")
    }

    private func audio(_ json: String, effectiveIndex: Int? = nil) throws -> FileVersion {
        let effective = effectiveIndex.map { #","effective_audio_track_index":\#($0)"# } ?? ""
        return try version(#"{"file_id":1,"resolution":"1080p""# + effective + #","audio_tracks":"# + json + "}")
    }

    private func context(mode: String, signature: SubtitleTrackSignature? = nil) -> DetailPlaybackFormatting.SubtitleAutoContext {
        DetailPlaybackFormatting.SubtitleAutoContext(preferredLanguage: "en", mode: mode, signature: signature, audioLanguage: "ja")
    }

    // MARK: - Versions and editions

    func testWithoutAPickFourKBeatsAnEarlierHD() throws {
        let files = try versions(#"""
        [{"file_id":10,"resolution":"1080p","codec_video":"hevc"},
         {"file_id":20,"resolution":"4K","codec_video":"hevc"}]
        """#)
        XCTAssertEqual(DetailVersionSelection.displayVersion(versions: files, selectedFileId: nil, lastFileId: nil)?.fileId, 20)
    }

    func testShortLabelShowsTheHDRFlag() throws {
        let file = try version(#"{"file_id":1,"resolution":"2160p","codec_video":"hevc","codec_audio":"truehd","hdr":true}"#)
        XCTAssertEqual(DetailPlaybackFormatting.versionShortLabel(file), "2160p · HEVC · HDR · TrueHD")
    }

    func testLabelsShowDolbyVisionProfile() throws {
        let file = try version(#"""
        {"file_id":1,"resolution":"2160p","codec_video":"hevc","codec_audio":"eac3","hdr":true,
         "video_tracks":[{"dolby_vision":"Profile 8.1","color_range":"tv"}]}
        """#)
        XCTAssertEqual(file.videoTracks?.first?.colorRange, "tv")
        XCTAssertEqual(DetailPlaybackFormatting.versionShortLabel(file), "2160p · HEVC · DV P8.1 · EAC3")
        XCTAssertEqual(DetailPlaybackFormatting.versionPrimaryText(file), "2160p · HEVC · DV P8.1 · EAC3")
    }

    func testTaggedFilesFormAnEditionBeforeStandard() throws {
        let files = try versions(#"""
        [{"file_id":1,"resolution":"4K","edition_raw":"Director's Cut","edition_key":"directors_cut"},
         {"file_id":2,"resolution":"1080p","edition_raw":"Director's Cut","edition_key":"directors_cut"},
         {"file_id":3,"resolution":"1080p"}]
        """#)
        let editions = PlaybackEditions.editions(from: files)
        XCTAssertEqual(editions.count, 2)
        XCTAssertEqual(editions[0].label, "Director's Cut")
        XCTAssertEqual(editions[0].versions.count, 2)
        XCTAssertEqual(editions[1].label, "Standard")
    }

    func testOlderEditionFieldGroupsFiles() throws {
        let files = try versions(#"""
        [{"file_id":1,"resolution":"1080p","edition":"Theatrical"},
         {"file_id":2,"resolution":"720p","edition":"Theatrical"}]
        """#)
        let editions = PlaybackEditions.editions(from: files)
        XCTAssertEqual(editions.count, 1)
        XCTAssertEqual(editions.first?.label, "Theatrical")
        XCTAssertEqual(editions.first?.versions.map(\.fileId), [1, 2])
    }

    func testCurrentEditionIsTheOneHoldingTheFile() throws {
        let files = try versions(#"""
        [{"file_id":1,"resolution":"1080p","edition":"Theatrical"},
         {"file_id":2,"resolution":"1080p","edition":"Extended"}]
        """#)
        XCTAssertEqual(DetailPlaybackFormatting.currentEdition(versions: files, currentVersion: files[1])?.label, "Extended")
    }

    func testSelectorsTurnOnOnlyWithAChoice() throws {
        let single = try version(#"""
        {"file_id":1,"resolution":"4K",
         "audio_tracks":[{"codec":"aac","language":"eng"}],
         "subtitle_tracks":[{"index":2,"codec":"srt","language":"eng"}]}
        """#)
        XCTAssertFalse(DetailPlaybackFormatting.shouldEnableVersionSelector(versions: [single], currentVersion: single))
        XCTAssertTrue(DetailPlaybackFormatting.shouldShowAudioValue(version: single))
        XCTAssertFalse(DetailPlaybackFormatting.shouldEnableAudioSelector(version: single))
        XCTAssertTrue(DetailPlaybackFormatting.shouldShowSubtitleValue(version: single))
        XCTAssertFalse(DetailPlaybackFormatting.shouldEnableSubtitleSelector(version: single))
        let subtitle = try XCTUnwrap(single.subtitleTracks?.first)
        XCTAssertEqual(DetailPlaybackFormatting.subtitleShortLabel(subtitle, ordinal: 0), "English")

        let double = try version(#"""
        {"file_id":2,"resolution":"4K",
         "audio_tracks":[{"codec":"aac","language":"eng"},{"codec":"ac3","language":"spa"}],
         "subtitle_tracks":[{"index":2,"codec":"srt","language":"eng"},{"index":3,"codec":"srt","language":"spa"}]}
        """#)
        XCTAssertTrue(DetailPlaybackFormatting.shouldEnableAudioSelector(version: double))
        XCTAssertTrue(DetailPlaybackFormatting.shouldEnableSubtitleSelector(version: double))
    }

    func testVersionSelectorListsTheCurrentEditionOnly() throws {
        let files = try versions(#"""
        [{"file_id":1,"resolution":"4K","edition_raw":"Theatrical","edition_key":"theatrical"},
         {"file_id":2,"resolution":"4K","edition_raw":"Extended","edition_key":"extended"},
         {"file_id":3,"resolution":"1080p","edition_raw":"Extended","edition_key":"extended"}]
        """#)
        XCTAssertFalse(DetailPlaybackFormatting.shouldEnableVersionSelector(versions: files, currentVersion: files[0]))
        XCTAssertTrue(DetailPlaybackFormatting.shouldEnableVersionSelector(versions: files, currentVersion: files[1]))
        XCTAssertEqual(DetailPlaybackFormatting.versionSelectorVersions(versions: files, currentVersion: files[1]).map(\.fileId), [2, 3])
    }

    func testSingleUntaggedFileIsStandard() throws {
        let file = try version(#"{"file_id":1,"resolution":"1080p"}"#)
        XCTAssertEqual(file.editionDisplayLabel, "Standard")
        let editions = PlaybackEditions.editions(from: [file])
        XCTAssertEqual(editions.count, 1)
        XCTAssertEqual(editions.first?.label, "Standard")
    }

    // MARK: - Audio

    func testPickedAudioTrackIsSelected() throws {
        let file = try audio(#"[{"codec":"aac","language":"eng","default":true},{"codec":"truehd","language":"jpn","layout":"7.1"}]"#)
        let options = DetailPlaybackFormatting.audioOptions(version: file, selectedAudioTrackIndex: 1)
        XCTAssertEqual(options.count, 2)
        XCTAssertEqual(options.map(\.ordinal), [0, 1])
        XCTAssertTrue(options[1].isSelected)
    }

    func testSettingsLanguageDecidesAndTheServerIndexIsIgnored() throws {
        let file = try audio(#"[{"codec":"aac","language":"eng","default":true},{"codec":"truehd","language":"jpn","layout":"7.1"}]"#,
                             effectiveIndex: 1)
        XCTAssertEqual(DetailPlaybackFormatting.audioValueLabel(version: file, selectedAudioTrackIndex: nil, preferredLanguage: "en"),
                       "English · AAC")
        XCTAssertEqual(DetailPlaybackFormatting.audioValueLabel(version: file, selectedAudioTrackIndex: 1, preferredLanguage: "en"),
                       "Japanese · TrueHD · 7.1")
        XCTAssertEqual(DetailPlaybackFormatting.audioValueLabel(version: file, selectedAudioTrackIndex: nil, annotateAuto: true,
                                                                preferredLanguage: "en"),
                       "Auto: English · AAC")
        XCTAssertEqual(DetailPlaybackFormatting.audioValueLabel(version: file, selectedAudioTrackIndex: nil, preferredLanguage: "ja"),
                       "Japanese · TrueHD · 7.1")
        XCTAssertEqual(DetailPlaybackFormatting.audioOptions(version: file, selectedAudioTrackIndex: nil, preferredLanguage: "en")
                        .map(\.isSelected), [true, false])

        let noMatch = try audio(#"[{"codec":"aac","language":"fra"},{"codec":"ac3","language":"spa","default":true}]"#)
        XCTAssertEqual(DetailPlaybackFormatting.audioValueLabel(version: noMatch, selectedAudioTrackIndex: nil, preferredLanguage: "de"),
                       "Spanish · AC3")
        let noPreference = try audio(#"[{"codec":"aac","language":"eng"},{"codec":"ac3","language":"spa"}]"#)
        XCTAssertEqual(DetailPlaybackFormatting.audioValueLabel(version: noPreference, selectedAudioTrackIndex: nil, preferredLanguage: ""),
                       "English · AAC")
    }

    func testDefaultTrueHDGivesWayToADirectlyPlayableSibling() throws {
        let file = try audio(#"""
        [{"codec":"truehd","language":"eng","layout":"7.1","default":true},
         {"codec":"eac3","language":"eng","layout":"5.1"},
         {"codec":"ac3","language":"eng","title":"Commentary","channels":2}]
        """#, effectiveIndex: 0)
        XCTAssertEqual(DetailPlaybackFormatting.resolvedAudioOrdinal(version: file, selectedAudioTrackIndex: nil, preferredLanguage: "en"), 1)
        XCTAssertEqual(DetailPlaybackFormatting.audioTechnicalSummary(version: file, selectedAudioTrackIndex: nil, preferredLanguage: "en"),
                       "EAC3 5.1")
        XCTAssertEqual(DetailPlaybackFormatting.audioTechnicalSummary(version: file, selectedAudioTrackIndex: 0, preferredLanguage: "en"),
                       "TrueHD 7.1")
        XCTAssertEqual(DetailPlaybackFormatting.resolvedAudioOrdinal(version: file, selectedAudioTrackIndex: 7, preferredLanguage: "en"), 1)
        let options = DetailPlaybackFormatting.audioOptions(version: file, selectedAudioTrackIndex: nil, preferredLanguage: "en")
        XCTAssertEqual(options.map(\.isSelected), [false, true, false])
        XCTAssertFalse(options.contains { $0.detail.contains("Preferred") })
    }

    func testCodecJargonTitleIsLeftOut() throws {
        let file = try audio(#"[{"codec":"eac3","language":"eng","title":"atsc a/52b (ac-3, e-ac-3)","channels":6,"default":true}]"#,
                             effectiveIndex: 0)
        XCTAssertEqual(DetailPlaybackFormatting.audioValueLabel(version: file, selectedAudioTrackIndex: nil, preferredLanguage: "en"),
                       "English · EAC3 · 5.1")
        let option = try XCTUnwrap(DetailPlaybackFormatting.audioOptions(version: file, selectedAudioTrackIndex: nil, preferredLanguage: "en").first)
        XCTAssertEqual(option.title, "English")
        XCTAssertEqual(option.detail, "EAC3 · 5.1 · Default")
    }

    // MARK: - Subtitles

    func testPathOnlyExternalSubtitleDecodes() throws {
        let file = try subtitles(#"[{"codec":"srt","language":"eng","file_name":"/subs/English.srt","external":true}]"#)
        let track = try XCTUnwrap(file.subtitleTracks?.first)
        XCTAssertEqual(track.externalPath, "/subs/English.srt")
        XCTAssertEqual(track.id, "-1|/subs/English.srt")
    }

    func testAlwaysPicksTheExternalEnglishFile() throws {
        let file = try subtitles(#"""
        [{"index":2,"codec":"subrip","language":"eng"},
         {"index":7,"codec":"ass","language":"eng","external":true,"external_path":"movie.en.ass"}]
        """#)
        let pick = try XCTUnwrap(DetailPlaybackFormatting.automaticSubtitle(version: file, context: context(mode: "always")))
        XCTAssertEqual(pick.track.codec, "ass")
    }

    func testEmbeddedTrackWithoutAnIndexIsStreamZero() throws {
        let file = try subtitles(#"""
        [{"codec":"subrip","language":"eng"},
         {"index":3,"codec":"ass","language":"jpn"}]
        """#)
        let pick = try XCTUnwrap(DetailPlaybackFormatting.automaticSubtitle(version: file, context: context(mode: "always")))
        XCTAssertEqual(pick.track.language, "eng")
        XCTAssertEqual(pick.track.selectionIndex, 0)
    }

    func testIndexlessEmbeddedAndExternalTracks() throws {
        let file = try subtitles(#"""
        [{"codec":"subrip","language":"eng"},
         {"codec":"srt","language":"fra","file_name":"/subs/fr.srt","external":true}]
        """#)
        let tracks = try XCTUnwrap(file.subtitleTracks)
        XCTAssertEqual(tracks.map(\.selectionIndex), [0, nil])
        XCTAssertEqual(DetailPlaybackFormatting.subtitleShortLabel(tracks[0], ordinal: 0), "English")
    }

    func testLanguageSignatureTieGoesToTheExternalFile() throws {
        let signature = try decoder().decode(SubtitleTrackSignature.self, from: Data(
            #"{"language":"en","forced":false,"hearing_impaired":false}"#.utf8))
        let file = try subtitles(#"""
        [{"index":2,"codec":"subrip","language":"eng"},
         {"index":9,"codec":"ass","language":"eng","external":true,"external_path":"movie.en.ass"}]
        """#)
        let pick = try XCTUnwrap(DetailPlaybackFormatting.automaticSubtitle(version: file, context: context(mode: "auto", signature: signature)))
        XCTAssertEqual(pick.track.codec, "ass")
    }

    func testSDHTitleBecomesASuffix() throws {
        let file = try subtitles(#"""
        [{"index":2,"title":"sdh","codec":"subrip","language":"eng","default":true},
         {"index":3,"codec":"srt","language":"jpn"}]
        """#)
        let track = try XCTUnwrap(file.subtitleTracks?.first)
        XCTAssertEqual(DetailPlaybackFormatting.subtitleShortLabel(track, ordinal: 0), "English (SDH)")
    }

    func testTitlesThatAlreadySaySoGetNoSuffix() throws {
        let file = try subtitles(#"""
        [{"index":2,"title":"Signs and Songs Forced","codec":"srt","language":"eng","forced":false},
         {"index":3,"title":"Director's Commentary (Hearing Impaired)","codec":"srt"}]
        """#)
        let tracks = try XCTUnwrap(file.subtitleTracks)
        XCTAssertEqual(DetailPlaybackFormatting.subtitleShortLabel(tracks[1], ordinal: 1), "Director's Commentary (Hearing Impaired)")
    }
}
