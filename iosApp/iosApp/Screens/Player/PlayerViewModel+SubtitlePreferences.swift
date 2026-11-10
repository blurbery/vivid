import Foundation
import OSLog

/// The automatic subtitle pick.
///
/// Its preferences come from, in order: a pick or Off made in the player
/// during this viewing, then Settings > Subtitles, or the device's caption
/// settings when Use Device Settings is on. No server-side subtitle setting
/// takes part, on Silo, Emby or Jellyfin. The player resolves the
/// preferences against the tracks it plays and the detail pages against the
/// catalogue's, so both show the same choice.
extension PlayerViewModel {
    // MARK: - Resolving

    /// Runs the automatic pick once per item, or again with
    /// `forceReevaluation`. A pick the viewer made for this item always wins.
    func applyAutoSubtitlePreferencesIfNeeded(forceReevaluation: Bool = false) {
        guard !hasExplicitSubtitleChoice, let prefs = prefsForCurrentItem else { return }
        guard forceReevaluation || !prefsResolvedForCurrentItem else { return }

        // Startup inventory can list subtitles before the engine has picked
        // an audio track, and before server subtitle files are mounted.
        // Resolving then would see no audio language, Auto would fall through
        // to the full track, and the latch below would keep that answer for
        // the whole item. Wait for the established load, as deferred picks
        // do; `loadVivid` re-enters `adoptVividInventory` once it is.
        guard isVividLoadEstablished else { return }

        let candidates = subtitleTracksForAutomaticPick
        guard !candidates.isEmpty else {
            // Embedded or sidecar tracks can still arrive in a later update.
            prefsResolvedForCurrentItem = false
            return
        }

        let audioLanguage = SubtitleAutoResolver.policyAudioLanguage(
            live: audioTracks.first(where: { $0.trackId == selectedAudioId })?.lang,
            catalog: currentSelectedVersion?.audioTracks ?? [],
            ordinal: catalogAudioOrdinalForSubtitlePolicy
        )
        let pick = SubtitleAutoResolver.resolve(.init(
            preferredLanguage: prefs.preferredLanguage,
            additionalPreferredLanguages: prefs.additionalPreferredLanguages,
            mode: prefs.mode,
            showForced: prefs.showForced,
            forcedOnly: prefs.forcedOnly,
            forcedFollowsAudio: prefs.forcedFollowsAudio,
            preferAccessibilityTracks: prefs.preferAccessibilityTracks,
            disableWhenNoLanguageMatch: prefs.disableWhenNoLanguageMatch,
            trackSignature: prefs.trackSignature,
            fallbackLanguages: prefs.fallbackLanguages,
            availableSubtitles: candidates,
            currentAudioLanguage: audioLanguage
        ))
        prefsResolvedForCurrentItem = true
        applyAutoSubtitle(pick)
    }

    /// Re-runs the automatic pick for the current item. Auto's answer depends
    /// on the audio's language, so an audio switch needs this in every mode.
    /// A pick made for this item stays.
    func reapplyAutomaticSubtitlePolicy() {
        guard !hasExplicitSubtitleChoice else { return }
        prefsForCurrentItem = automaticSubtitlePrefsSnapshot()
        prefsResolvedForCurrentItem = false
        applyAutoSubtitlePreferencesIfNeeded(forceReevaluation: true)
    }

    /// Answers the engine's `systemCaptionRequest` (upstream api.md, "The
    /// system asks for captions").
    ///
    /// iOS 26's Automatic Subtitles turn captions on with no API to read, so
    /// the engine passing the request on is the only signal. The engine has
    /// already deselected its own rendition by then (a full-screen system
    /// caption box would draw over Vivid's overlay), so Vivid answers by
    /// selecting its own matching track. No match does nothing: the request
    /// is to select a matching track, not to turn something on.
    func handleSystemCaptionRequest(epoch: VividPlaybackController.LoadEpoch, request: SystemCaptionRequest) {
        // Track lists and Silo plans belong to one load, so a request from an
        // earlier load names a language against tracks that are gone.
        guard epoch == vividPlaybackController.activeLoadEpoch,
              let language = request.language, !language.isEmpty,
              !subtitleTracks.isEmpty else { return }

        // `.always` because the system has already decided captions are on;
        // `disableWhenNoLanguageMatch: false` keeps an unmatched language a
        // no-op rather than clearing a selection the viewer can see.
        let pick = SubtitleAutoResolver.resolve(.init(
            preferredLanguage: language,
            mode: .always,
            showForced: false,
            disableWhenNoLanguageMatch: false,
            trackSignature: nil,
            availableSubtitles: subtitleTracksForAutomaticPick,
            currentAudioLanguage: audioTracks.first(where: { $0.trackId == selectedAudioId })?.lang
        ))
        guard case .select(let track) = pick else { return }
        Self.logger.info(
            "[CMP-SUB] system caption request answered language=\(language, privacy: .public) trackId=\(track.trackId, privacy: .public)"
        )
        applyAutoSubtitle(.select(track))
    }

    /// The catalogue ordinal of the audio that's playing.
    private var catalogAudioOrdinalForSubtitlePolicy: Int? {
        if let ordinal = engineCatalogAudioOrdinal { return ordinal }
        // The plan and the load describe the audio the item started with, not
        // a track the viewer has switched to since.
        guard !audioPickedForCurrentItem else { return nil }
        return activePreparedProtocolV3?.plan.selectedTracks.audio?.index
            ?? loadAudioOrdinal
            ?? lastLoadRequest?.preferredAudioTrackIndex
    }

    /// Applies a resolver verdict. `noChange` leaves the player alone (no
    /// preference points anywhere); `disable` and `select` change state only
    /// when the selection actually differs.
    private func applyAutoSubtitle(_ pick: SubtitleAutoSelection) {
        switch pick {
        case .noChange:
            return
        case .disable:
            localExternalSubtitlePick = nil
            guard selectedSubtitleId != nil else { return }
            selectedSubtitleId = nil
            if reloadForServerBurnInIfNeeded(reason: "auto_preference") { return }
            applySubtitleTrackSelection(nil, reason: "auto_preference")
        case .select(let track):
            guard selectedSubtitleId != track.trackId else { return }
            selectedSubtitleId = track.trackId
            if reloadForServerBurnInIfNeeded(reason: "auto_preference") { return }
            applySubtitleTrackSelection(track.trackId, reason: "auto_preference")
        }
    }

    // MARK: - Preference snapshots

    /// What drives the automatic pick for the item being loaded: this
    /// viewing's player choice first, then Settings > Subtitles, or the
    /// device's caption settings when Vivid follows them.
    func automaticSubtitlePrefsSnapshot(_ watchDetail: WatchDetail? = nil) -> PrefsSnapshot {
        let settingsPrefs = Self.settingsSubtitlePrefs(settings)
        let prefs = viewingSubtitlePrefs ?? settingsPrefs
        return shuffleQueue == nil ? prefs : Self.shuffleSubtitlePrefs(prefs, settings: settingsPrefs)
    }

    /// Shuffle jumps between seasons, so an episode is more likely to lack
    /// the subtitle language in use, whether picked in the player or set in
    /// Settings. Rather than turning subtitles off, it falls back to Settings
    /// > Subtitles' languages, then English. Off stays off, and a forced-only
    /// pick stays forced-only.
    nonisolated static func shuffleSubtitlePrefs(_ viewing: PrefsSnapshot, settings: PrefsSnapshot) -> PrefsSnapshot {
        guard viewing.mode != .off, let carried = viewing.preferredLanguage, !carried.isEmpty,
              !viewing.forcedOnly else { return viewing }
        var languages: [String] = []
        for language in [settings.preferredLanguage].compactMap({ $0 })
            + settings.additionalPreferredLanguages + settings.fallbackLanguages + viewing.fallbackLanguages + ["en"]
        where !language.isEmpty && language != carried && !languages.contains(language) {
            languages.append(language)
        }
        var prefs = viewing
        prefs.fallbackLanguages = languages
        return prefs
    }

    /// Settings > Subtitles, or the device's caption settings when Vivid
    /// follows them. The detail pages read the same preferences.
    static func settingsSubtitlePrefs(_ settings: PlayerSettings) -> PrefsSnapshot {
        settings.subtitleMatchesSystemAppearance
            ? systemCaptionPrefs(settings.subtitleSystemSelectionPreferences)
            : localSubtitlePrefs(settings)
    }

    /// A pick as preferences the next episode can resolve against its own
    /// tracks: the same language and kind of track (forced, CC/SDH, title),
    /// or Off when `track` is nil.
    static func viewingSubtitlePrefs(for track: PlayerTrack?) -> PrefsSnapshot {
        guard let track else {
            return PrefsSnapshot(
                preferredLanguage: nil, additionalPreferredLanguages: [], mode: .off,
                showForced: false, forcedOnly: false, preferAccessibilityTracks: false,
                disableWhenNoLanguageMatch: true, trackSignature: nil
            )
        }
        let language = track.normalizedLanguageCode
        let isForced = SubtitleAutoResolver.isForced(track)
        return PrefsSnapshot(
            preferredLanguage: language,
            additionalPreferredLanguages: [],
            mode: .always,
            showForced: isForced,
            // A forced pick stays forced: an episode without a forced track in
            // that language plays without subtitles rather than the full track.
            forcedOnly: isForced,
            preferAccessibilityTracks: track.isHearingImpaired,
            // A pick without a language still means "subtitles on".
            disableWhenNoLanguageMatch: language != nil,
            trackSignature: SubtitleTrackSignature(
                source: track.isExternal ? "external" : "embedded",
                language: language,
                codec: track.codec,
                label: track.normalizedTitle,
                forced: isForced,
                hearingImpaired: track.isHearingImpaired
            )
        )
    }

    func systemCaptionPrefsSnapshot() -> PrefsSnapshot {
        Self.systemCaptionPrefs(settings.subtitleSystemSelectionPreferences)
    }

    /// The device's caption settings in Apple's three display modes.
    static func systemCaptionPrefs(_ system: SystemCaptionSelectionPreferences) -> PrefsSnapshot {
        let firstLanguage = system.preferredLanguages.first
        let remainingLanguages = Array(system.preferredLanguages.dropFirst())
        switch system.displayMode {
        case .forcedOnly:
            return PrefsSnapshot(
                preferredLanguage: firstLanguage,
                additionalPreferredLanguages: remainingLanguages,
                mode: .auto,
                showForced: true,
                forcedOnly: true,
                preferAccessibilityTracks: system.prefersAccessibilityTracks,
                disableWhenNoLanguageMatch: true,
                trackSignature: nil,
                forcedFollowsAudio: true
            )
        case .automatic:
            // Apple's Automatic shows subtitles in the device's language when
            // the audio isn't in it. The caption languages are a history of
            // past picks and don't decide it.
            return PrefsSnapshot(
                preferredLanguage: system.deviceLanguages.first ?? firstLanguage,
                additionalPreferredLanguages: system.deviceLanguages.isEmpty ? remainingLanguages : [],
                mode: .auto,
                showForced: true,
                forcedOnly: false,
                preferAccessibilityTracks: system.prefersAccessibilityTracks,
                disableWhenNoLanguageMatch: true,
                trackSignature: nil
            )
        case .alwaysOn:
            // Always On prefers the full track, but a language whose only
            // track is forced still gets that track rather than nothing.
            return PrefsSnapshot(
                preferredLanguage: firstLanguage,
                additionalPreferredLanguages: remainingLanguages,
                mode: .always,
                showForced: true,
                forcedOnly: false,
                preferAccessibilityTracks: system.prefersAccessibilityTracks,
                disableWhenNoLanguageMatch: true,
                trackSignature: nil
            )
        }
    }

    func localSubtitlePrefsSnapshot(_ watchDetail: WatchDetail? = nil) -> PrefsSnapshot {
        Self.localSubtitlePrefs(settings)
    }

    /// Settings > Subtitles: Language, Backup Language, Behaviour and Show
    /// Forced Subtitles.
    static func localSubtitlePrefs(_ settings: PlayerSettings) -> PrefsSnapshot {
        let language = settings.preferredSubtitleLanguage == PlaybackPrefSentinel.none
            ? nil : settings.preferredSubtitleLanguage
        let backup = settings.preferredSubtitleBackupLanguage
        let mode = SubtitleMode(rawValue: settings.preferredSubtitleMode)
        // Always with Language set to None still shows subtitles: in the
        // device's language when the file has it, otherwise the file's own
        // default track.
        let alwaysWithoutLanguage = language == nil && mode == .always
        let fallback: [String]
        if alwaysWithoutLanguage {
            fallback = Locale.preferredLanguages
        } else if language != nil, !backup.isEmpty, backup != PlaybackPrefSentinel.none {
            // A backup only stands in for a chosen language.
            fallback = [backup]
        } else {
            fallback = []
        }
        return PrefsSnapshot(
            preferredLanguage: language,
            additionalPreferredLanguages: [],
            mode: mode,
            showForced: settings.showForcedSubtitles,
            forcedOnly: false,
            preferAccessibilityTracks: false,
            disableWhenNoLanguageMatch: !alwaysWithoutLanguage,
            trackSignature: nil,
            fallbackLanguages: fallback
        )
    }
}
