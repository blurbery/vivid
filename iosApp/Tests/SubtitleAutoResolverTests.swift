import XCTest
#if os(tvOS)
@testable import VividTV
#else
@testable import Vivid
#endif

final class SubtitleAutoResolverTests: XCTestCase {
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

    private func inputs(
        preferredLanguage: String?,
        mode: SubtitleMode?,
        showForced: Bool,
        tracks: [PlayerTrack],
        audioLanguage: String?,
        additionalLanguages: [String] = [],
        forcedOnly: Bool = false,
        preferAccessibility: Bool = false,
        disableWhenNoLanguageMatch: Bool = false
    ) -> SubtitleAutoResolver.Inputs {
        SubtitleAutoResolver.Inputs(
            preferredLanguage: preferredLanguage,
            additionalPreferredLanguages: additionalLanguages,
            mode: mode,
            showForced: showForced,
            forcedOnly: forcedOnly,
            preferAccessibilityTracks: preferAccessibility,
            disableWhenNoLanguageMatch: disableWhenNoLanguageMatch,
            trackSignature: nil,
            availableSubtitles: tracks,
            currentAudioLanguage: audioLanguage
        )
    }

    /// The living-room regression: foreign-language audio, English sub
    /// preference, "show forced" ON. The forced (signs-only) track must
    /// not win over the full dialogue track — signs tracks go silent for
    /// whole dialogue scenes and read as "subtitles stopped working".
    func testShowForcedDoesNotStealFullDialoguePick() {
        let forced = track(id: 13, lang: "eng", forced: true, title: "English (Forced)")
        let full = track(id: 14, lang: "eng", title: "English")
        let result = SubtitleAutoResolver.resolve(inputs(
            preferredLanguage: "en",
            mode: .auto,
            showForced: true,
            tracks: [forced, full],
            audioLanguage: "kor"
        ))
        XCTAssertEqual(result, .select(full))
    }

    /// Auto mode with audio already in the preferred language: full subs
    /// are redundant, and THIS is the case "show forced" exists for —
    /// select the forced track instead of disabling (Android parity).
    func testAudioLanguageMatchSelectsForcedWhenWanted() {
        let forced = track(id: 13, lang: "eng", forced: true)
        let full = track(id: 14, lang: "eng")
        let result = SubtitleAutoResolver.resolve(inputs(
            preferredLanguage: "en",
            mode: .auto,
            showForced: true,
            tracks: [forced, full],
            audioLanguage: "eng"
        ))
        XCTAssertEqual(result, .select(forced))
    }

    func testAudioLanguageMatchDisablesWhenForcedNotWanted() {
        let forced = track(id: 13, lang: "eng", forced: true)
        let full = track(id: 14, lang: "eng")
        let result = SubtitleAutoResolver.resolve(inputs(
            preferredLanguage: "en",
            mode: .auto,
            showForced: false,
            tracks: [forced, full],
            audioLanguage: "en"
        ))
        XCTAssertEqual(result, .disable)
    }

    /// Full-dialogue preference also skips SDH tracks when a plain
    /// track exists in the language.
    func testFullPickPrefersNonHearingImpaired() {
        let sdh = track(id: 12, lang: "eng", hearingImpaired: true, title: "English (SDH)")
        let full = track(id: 14, lang: "eng")
        let result = SubtitleAutoResolver.resolve(inputs(
            preferredLanguage: "en",
            mode: .auto,
            showForced: true,
            tracks: [sdh, full],
            audioLanguage: "kor"
        ))
        XCTAssertEqual(result, .select(full))
    }

    /// Tracks labelled CC/SDH in the title but missing the ffmpeg
    /// hearing-impaired disposition flag are still demoted below a plain
    /// track in the same language.
    func testFullPickDemotesTitleOnlyCCTracks() {
        let cc = track(id: 12, lang: "eng", title: "English (CC)")
        let sdh = track(id: 13, lang: "eng", title: "English SDH")
        let full = track(id: 14, lang: "eng", title: "English")
        let result = SubtitleAutoResolver.resolve(inputs(
            preferredLanguage: "en",
            mode: .auto,
            showForced: false,
            tracks: [cc, sdh, full],
            audioLanguage: "kor"
        ))
        XCTAssertEqual(result, .select(full))
    }

    /// The CC token check must not misread ordinary words containing
    /// "cc" — a title like "Soccer Cut" is a normal dialogue track.
    func testCCTokenDoesNotMatchInsideWords() {
        XCTAssertFalse(SubtitleAutoResolver.titleIndicatesHearingImpaired("Soccer Cut"))
        XCTAssertTrue(SubtitleAutoResolver.titleIndicatesHearingImpaired("English (CC)"))
        XCTAssertTrue(SubtitleAutoResolver.titleIndicatesHearingImpaired("English [SDH]"))
        XCTAssertTrue(SubtitleAutoResolver.titleIndicatesHearingImpaired("Closed Captions"))
        XCTAssertFalse(SubtitleAutoResolver.titleIndicatesHearingImpaired(nil))
    }

    func testSystemLanguageStackFallsBackInOrder() {
        let french = track(id: 10, lang: "fra")
        let spanish = track(id: 11, lang: "spa")
        let result = SubtitleAutoResolver.resolve(inputs(
            preferredLanguage: "de-DE",
            mode: .always,
            showForced: false,
            tracks: [spanish, french],
            audioLanguage: "eng",
            additionalLanguages: ["es-ES", "fr-FR"]
        ))
        XCTAssertEqual(result, .select(spanish))
    }

    func testExactRegionalLanguageWinsBeforePrimarySubtagFallback() {
        let brazilianPortuguese = track(id: 10, lang: "pt-BR")
        let portugalPortuguese = track(id: 11, lang: "pt-PT")
        let result = SubtitleAutoResolver.resolve(inputs(
            preferredLanguage: "pt-PT",
            mode: .always,
            showForced: false,
            tracks: [brazilianPortuguese, portugalPortuguese],
            audioLanguage: "eng"
        ))
        XCTAssertEqual(result, .select(portugalPortuguese))
    }

    func testFullDialogueTrackBeatsExactRegionalForcedTrack() {
        let exactForced = track(id: 10, lang: "pt-PT", forced: true)
        let genericFull = track(id: 11, lang: "pt")
        let result = SubtitleAutoResolver.resolve(inputs(
            preferredLanguage: "pt-PT",
            mode: .always,
            showForced: true,
            tracks: [exactForced, genericFull],
            audioLanguage: "eng"
        ))
        XCTAssertEqual(result, .select(genericFull))
    }

    func testRegionalLanguageStackExhaustsExactMatchesBeforeFallback() {
        let arbitraryFallback = track(id: 10, lang: "pt-AO")
        let exactSecondPreference = track(id: 11, lang: "pt-PT")
        let result = SubtitleAutoResolver.resolve(inputs(
            preferredLanguage: "pt-BR",
            mode: .always,
            showForced: false,
            tracks: [arbitraryFallback, exactSecondPreference],
            audioLanguage: "eng",
            additionalLanguages: ["pt-PT"]
        ))
        XCTAssertEqual(result, .select(exactSecondPreference))
    }

    func testSystemLanguageMatchesArbitraryISOThreeLetterMetadata() {
        let dutch = track(id: 10, lang: "nld")
        let result = SubtitleAutoResolver.resolve(inputs(
            preferredLanguage: "nl-NL",
            mode: .always,
            showForced: false,
            tracks: [dutch],
            audioLanguage: "eng"
        ))
        XCTAssertEqual(result, .select(dutch))
        XCTAssertTrue(SubtitleAutoResolver.languagesMatch("dut", "nl-NL"))
    }

    func testSystemAccessibilityCharacteristicPrefersSDH() {
        let plain = track(id: 10, lang: "eng", title: "English")
        let sdh = track(id: 11, lang: "eng", hearingImpaired: true, title: "English SDH")
        let result = SubtitleAutoResolver.resolve(inputs(
            preferredLanguage: "en",
            mode: .always,
            showForced: false,
            tracks: [plain, sdh],
            audioLanguage: "eng",
            preferAccessibility: true
        ))
        XCTAssertEqual(result, .select(sdh))
    }

    func testSystemForcedOnlyNeverSelectsFullDialogueTrack() {
        let full = track(id: 10, lang: "eng")
        let forcedSpanish = track(id: 11, lang: "spa", forced: true)
        let result = SubtitleAutoResolver.resolve(inputs(
            preferredLanguage: "en",
            mode: .auto,
            showForced: true,
            tracks: [full, forcedSpanish],
            audioLanguage: "eng",
            additionalLanguages: ["es"],
            forcedOnly: true
        ))
        XCTAssertEqual(result, .select(forcedSpanish))
    }

    func testSystemForcedOnlyDisablesWhenNoForcedTrackExists() {
        let result = SubtitleAutoResolver.resolve(inputs(
            preferredLanguage: "en",
            mode: .auto,
            showForced: true,
            tracks: [track(id: 10, lang: "eng")],
            audioLanguage: "eng",
            forcedOnly: true
        ))
        XCTAssertEqual(result, .disable)
    }

    func testSystemPolicyDisablesWhenNoSubtitleTracksAreAvailable() {
        let result = SubtitleAutoResolver.resolve(inputs(
            preferredLanguage: "en",
            mode: .always,
            showForced: false,
            tracks: [],
            audioLanguage: "eng",
            disableWhenNoLanguageMatch: true
        ))
        XCTAssertEqual(result, .disable)
    }

    func testSystemForcedOnlyDoesNotSelectUnrequestedLanguage() {
        let frenchForced = track(id: 11, lang: "fra", forced: true)
        let result = SubtitleAutoResolver.resolve(inputs(
            preferredLanguage: "en",
            mode: .auto,
            showForced: true,
            tracks: [frenchForced],
            audioLanguage: "eng",
            forcedOnly: true,
            disableWhenNoLanguageMatch: true
        ))
        XCTAssertEqual(result, .disable)
    }

    func testSystemLanguageMissClearsExistingServerSelection() {
        let english = track(id: 10, lang: "eng")
        let result = SubtitleAutoResolver.resolve(inputs(
            preferredLanguage: "es",
            mode: .always,
            showForced: false,
            tracks: [english],
            audioLanguage: "eng",
            disableWhenNoLanguageMatch: true
        ))
        XCTAssertEqual(result, .disable)
    }

    func testServerLanguageMissStillLeavesExistingSelectionAlone() {
        let english = track(id: 10, lang: "eng")
        let result = SubtitleAutoResolver.resolve(inputs(
            preferredLanguage: "es",
            mode: .always,
            showForced: false,
            tracks: [english],
            audioLanguage: "eng"
        ))
        XCTAssertEqual(result, .noChange)
    }
    func testStrictLanguagePolicyWithoutPreferenceDisablesSubtitles() {
        XCTAssertEqual(SubtitleAutoResolver.resolve(.init(
            preferredLanguage: nil, mode: .always, showForced: true,
            disableWhenNoLanguageMatch: true, trackSignature: nil,
            availableSubtitles: [track(id: 1, lang: "en")], currentAudioLanguage: "ja"
        )), .disable)
    }

    // MARK: - Audio language for Auto

    private func audio(_ language: String?) -> AudioTrack {
        AudioTrack(index: nil, codec: "eac3", channels: 6, channelLayout: "5.1", bitrate: 640_000,
                   sampleRate: 48_000, language: language, title: nil, embeddedTitle: nil, isDefault: nil)
    }

    func testPolicyAudioLanguagePrefersTheStreamTag() {
        XCTAssertEqual(SubtitleAutoResolver.policyAudioLanguage(
            live: "jpn", catalog: [audio("eng"), audio("jpn")], ordinal: 0
        ), "jpn")
    }

    /// A transcode can drop the audio language, and `und` says nothing. The
    /// catalogue's language for the playing ordinal stands in.
    func testPolicyAudioLanguageFallsBackToTheCatalogueOrdinal() {
        for live in [nil, "", "und", "UND"] as [String?] {
            XCTAssertEqual(SubtitleAutoResolver.policyAudioLanguage(
                live: live, catalog: [audio("jpn"), audio("eng")], ordinal: 1
            ), "eng", String(describing: live))
        }
    }

    func testPolicyAudioLanguageUsesASingleLanguageCatalogue() {
        XCTAssertEqual(SubtitleAutoResolver.policyAudioLanguage(
            live: nil, catalog: [audio("eng"), audio("en"), audio(nil)], ordinal: nil
        ), "eng")
        XCTAssertEqual(SubtitleAutoResolver.policyAudioLanguage(
            live: nil, catalog: [audio("eng")], ordinal: 5
        ), "eng")
    }

    /// English audio beside an untagged dub: playing the dub must not borrow
    /// English from the other track, or Auto hides subtitles over it.
    func testPolicyAudioLanguageKeepsAnUntaggedPlayingTrackUnknown() {
        XCTAssertNil(SubtitleAutoResolver.policyAudioLanguage(
            live: nil, catalog: [audio("eng"), audio(nil)], ordinal: 1
        ))
        XCTAssertNil(SubtitleAutoResolver.policyAudioLanguage(
            live: "und", catalog: [audio("eng"), audio("und")], ordinal: 1
        ))
    }

    /// Several audio languages and nothing saying which one plays: unknown,
    /// rather than a guess that could hide subtitles for foreign audio.
    func testPolicyAudioLanguageStaysUnknownForAmbiguousCatalogue() {
        XCTAssertNil(SubtitleAutoResolver.policyAudioLanguage(
            live: nil, catalog: [audio("eng"), audio("jpn")], ordinal: nil
        ))
        XCTAssertNil(SubtitleAutoResolver.policyAudioLanguage(live: "und", catalog: [], ordinal: 0))
    }


    // MARK: - Show Forced Subtitles and forced detection

    /// With Show Forced Subtitles off, a forced track is never picked, even as
    /// the language's only track: foreign audio plays without subtitles.
    func testForcedToggleOffNeverPicksTheOnlyForcedTrack() {
        let forced = track(id: 3, lang: "eng", forced: true)
        let foreignAudio = inputs(preferredLanguage: "en", mode: .auto, showForced: false,
                                  tracks: [forced], audioLanguage: "ja", disableWhenNoLanguageMatch: true)
        XCTAssertEqual(SubtitleAutoResolver.resolve(foreignAudio), .disable)
        let always = inputs(preferredLanguage: "en", mode: .always, showForced: false,
                            tracks: [forced], audioLanguage: "en", disableWhenNoLanguageMatch: true)
        XCTAssertEqual(SubtitleAutoResolver.resolve(always), .disable)
    }

    /// With the toggle on, the language's only forced track still plays.
    func testForcedToggleOnKeepsTheOnlyForcedTrackAsFallback() {
        let forced = track(id: 3, lang: "eng", forced: true)
        let always = inputs(preferredLanguage: "en", mode: .always, showForced: true,
                            tracks: [forced], audioLanguage: "en", disableWhenNoLanguageMatch: true)
        XCTAssertEqual(SubtitleAutoResolver.resolve(always), .select(forced))
    }

    /// Many files name the forced track without flagging it. Auto with English
    /// audio picks it, and Always still prefers the full track.
    func testTitleOnlyForcedTrackCountsAsForced() {
        let full = track(id: 4, lang: "eng", title: "English")
        let titled = track(id: 3, lang: "eng", title: "English Forced")
        let auto = inputs(preferredLanguage: "en", mode: .auto, showForced: true,
                          tracks: [titled, full], audioLanguage: "eng", disableWhenNoLanguageMatch: true)
        XCTAssertEqual(SubtitleAutoResolver.resolve(auto), .select(titled))
        let always = inputs(preferredLanguage: "en", mode: .always, showForced: true,
                            tracks: [titled, full], audioLanguage: "eng", disableWhenNoLanguageMatch: true)
        XCTAssertEqual(SubtitleAutoResolver.resolve(always), .select(full))
    }

    func testForcedTitleDetectionNeedsTheWholeWord() {
        XCTAssertTrue(SubtitleAutoResolver.titleIndicatesForced("Forced"))
        XCTAssertTrue(SubtitleAutoResolver.titleIndicatesForced("Signs & Songs (Forced)"))
        XCTAssertFalse(SubtitleAutoResolver.titleIndicatesForced("English (Non-Forced)"))
        XCTAssertFalse(SubtitleAutoResolver.titleIndicatesForced("Not Forced"))
        XCTAssertFalse(SubtitleAutoResolver.titleIndicatesForced("Unforced Errors"))
        XCTAssertFalse(SubtitleAutoResolver.titleIndicatesForced(nil))
    }

    /// Off means no subtitles, forced ones included.
    func testOffDisablesEvenWithForcedWanted() {
        let forced = track(id: 3, lang: "eng", forced: true)
        let off = inputs(preferredLanguage: "en", mode: .off, showForced: true,
                         tracks: [forced], audioLanguage: "eng", disableWhenNoLanguageMatch: true)
        XCTAssertEqual(SubtitleAutoResolver.resolve(off), .disable)
    }

    /// A carried forced pick with no language takes this episode's forced
    /// track, and plays nothing when the episode has none.
    func testForcedOnlyWithoutLanguageTakesAnyForcedTrack() {
        let full = track(id: 4, lang: nil)
        let forced = track(id: 3, lang: nil, forced: true)
        XCTAssertEqual(SubtitleAutoResolver.resolve(inputs(preferredLanguage: nil, mode: .always, showForced: true,
            tracks: [full, forced], audioLanguage: nil, forcedOnly: true)), .select(forced))
        XCTAssertEqual(SubtitleAutoResolver.resolve(inputs(preferredLanguage: nil, mode: .always, showForced: true,
            tracks: [full], audioLanguage: nil, forcedOnly: true)), .disable)
    }

    // MARK: - Backup language

    private func backupInputs(mode: SubtitleMode = .auto, tracks: [PlayerTrack], audio: String?) -> SubtitleAutoResolver.Inputs {
        SubtitleAutoResolver.Inputs(
            preferredLanguage: "ar", mode: mode, showForced: true,
            disableWhenNoLanguageMatch: true, trackSignature: nil,
            fallbackLanguages: ["en"], availableSubtitles: tracks, currentAudioLanguage: audio
        )
    }

    /// Arabic with an English backup: an English film without Arabic
    /// subtitles plays the English ones. English audio isn't the viewer's
    /// language, so Auto still shows subtitles.
    func testBackupLanguageFillsInWhenTheMainLanguageIsMissing() {
        let english = track(id: 4, lang: "eng")
        XCTAssertEqual(SubtitleAutoResolver.resolve(backupInputs(tracks: [english], audio: "eng")), .select(english))
    }

    /// The main language always wins, even as a CC/SDH track against a plain
    /// backup track.
    func testMainLanguageBeatsTheBackup() {
        let arabicSDH = track(id: 5, lang: "ara", hearingImpaired: true)
        let english = track(id: 4, lang: "eng")
        XCTAssertEqual(SubtitleAutoResolver.resolve(backupInputs(tracks: [english, arabicSDH], audio: "eng")), .select(arabicSDH))
    }

    /// Audio already in the main language: Auto plays only its forced track,
    /// and the backup isn't used.
    func testBackupIsNotUsedWhenTheAudioIsInTheMainLanguage() {
        let arabicForced = track(id: 6, lang: "ara", forced: true)
        let english = track(id: 4, lang: "eng")
        XCTAssertEqual(SubtitleAutoResolver.resolve(backupInputs(tracks: [english, arabicForced], audio: "ara")), .select(arabicForced))
        XCTAssertEqual(SubtitleAutoResolver.resolve(backupInputs(tracks: [english], audio: "ara")), .disable)
    }

    func testBackupFollowsAlwaysAndOff() {
        let english = track(id: 4, lang: "eng")
        XCTAssertEqual(SubtitleAutoResolver.resolve(backupInputs(mode: .always, tracks: [english], audio: "ara")), .select(english))
        XCTAssertEqual(SubtitleAutoResolver.resolve(backupInputs(mode: .off, tracks: [english], audio: "eng")), .disable)
    }

    /// Neither language present: no subtitles.
    func testNoMainOrBackupTrackLeavesSubtitlesOff() {
        let french = track(id: 7, lang: "fra")
        XCTAssertEqual(SubtitleAutoResolver.resolve(backupInputs(tracks: [french], audio: "eng")), .disable)
    }

    /// Arabic with an English backup, and the file's only Arabic track is
    /// signs-only: the English full track wins, so the dialogue can be
    /// followed. Without a backup the forced Arabic track is still the pick.
    func testBackupFullTrackBeatsAForcedOnlyMainTrack() {
        let arabicForced = track(id: 6, lang: "ara", forced: true)
        let english = track(id: 4, lang: "eng")
        XCTAssertEqual(SubtitleAutoResolver.resolve(backupInputs(tracks: [arabicForced, english], audio: "eng")), .select(english))
        XCTAssertEqual(SubtitleAutoResolver.resolve(backupInputs(tracks: [arabicForced], audio: "eng")), .select(arabicForced))
        let noBackup = SubtitleAutoResolver.Inputs(
            preferredLanguage: "ar", mode: .auto, showForced: true, disableWhenNoLanguageMatch: true,
            trackSignature: nil, availableSubtitles: [arabicForced, english], currentAudioLanguage: "eng")
        XCTAssertEqual(SubtitleAutoResolver.resolve(noBackup), .select(arabicForced))
    }
}
