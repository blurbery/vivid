//
//  PlaybackPrefsResolver.swift
//  Vivid (iOS + tvOS)
//
//  Pure resolution logic that turns Settings > Subtitles (or the
//  device's caption settings, or a pick carried through this viewing)
//  into a concrete subtitle-track selection once the available tracks
//  are known. The player runs it on the engine's tracks and the detail
//  pages run it on the catalogue's, so both show the same answer on
//  every server. No I/O, no actor isolation, testable in isolation
//  from the player.
//
//  Audio resolution is *not* done here: the server's `/playback/start`
//  endpoint already picks an audio track based on per-series and
//  per-library prefs and returns it as `session.audioTrackIndex`.
//  PlayerViewModel feeds that index in as `pendingAudioFfIndex` and
//  the existing pending-match path applies it.
//

import Foundation

enum SubtitleAutoSelection: Equatable {
    /// User had no preferences that point at a track, or already had
    /// an explicit override, or `mode == off`. Caller should leave the
    /// subtitle slot however the player started it.
    case noChange
    /// User wants subs disabled for this content.
    case disable
    /// Auto-select this track from the list.
    case select(PlayerTrack)
}

struct SubtitleAutoResolver {

    struct Inputs {
        /// `subtitle_language` cascaded down to this content. `nil`
        /// means the user has no preference at any level. Empty
        /// string means "no subs" — distinct from no preference.
        let preferredLanguage: String?
        /// Additional ordered language fallbacks. Used by Apple's caption
        /// profile, which exposes a stack rather than one server value.
        let additionalPreferredLanguages: [String]
        /// `subtitle_mode` from the cascade. `nil` → fall back to "auto".
        let mode: SubtitleMode?
        /// Whether forced subs should be auto-selected when available.
        let showForced: Bool
        /// Apple's Forced Only display mode.
        let forcedOnly: Bool
        /// With `forcedOnly`, match the forced track to the audio's language,
        /// as Apple's Forced Only does, rather than to `preferredLanguage`.
        let forcedFollowsAudio: Bool
        /// Prefer CC/SDH over plain subtitles when Apple requests the
        /// accessibility media characteristics.
        let preferAccessibilityTracks: Bool
        /// An explicit device language stack is authoritative. If none of
        /// those languages exists, clear any server-selected subtitle rather
        /// than leaking the server profile back into device-settings mode.
        let disableWhenNoLanguageMatch: Bool
        /// Per-series sticky pick. Highest priority signal — if a track
        /// matches the signature, select it regardless of language /
        /// mode.
        let trackSignature: SubtitleTrackSignature?
        /// Backup languages, tried only when no track is in a preferred
        /// language. They don't count as the viewer's language when Auto
        /// compares the audio: an Arabic viewer with an English backup still
        /// gets subtitles for English audio.
        let fallbackLanguages: [String]
        /// Tracks we can choose from (already-discovered embedded +
        /// sidecar entries).
        let availableSubtitles: [PlayerTrack]
        /// Language of the audio track currently playing. Used by
        /// "auto" mode to skip subs when audio matches the user's
        /// preferred subtitle language (e.g. English audio + English
        /// sub preference → no subs).
        let currentAudioLanguage: String?

        init(
            preferredLanguage: String?,
            additionalPreferredLanguages: [String] = [],
            mode: SubtitleMode?,
            showForced: Bool,
            forcedOnly: Bool = false,
            forcedFollowsAudio: Bool = false,
            preferAccessibilityTracks: Bool = false,
            disableWhenNoLanguageMatch: Bool = false,
            trackSignature: SubtitleTrackSignature?,
            fallbackLanguages: [String] = [],
            availableSubtitles: [PlayerTrack],
            currentAudioLanguage: String?
        ) {
            self.preferredLanguage = preferredLanguage
            self.additionalPreferredLanguages = additionalPreferredLanguages
            self.mode = mode
            self.showForced = showForced
            self.forcedOnly = forcedOnly
            self.forcedFollowsAudio = forcedFollowsAudio
            self.preferAccessibilityTracks = preferAccessibilityTracks
            self.disableWhenNoLanguageMatch = disableWhenNoLanguageMatch
            self.trackSignature = trackSignature
            self.fallbackLanguages = fallbackLanguages
            self.availableSubtitles = availableSubtitles
            self.currentAudioLanguage = currentAudioLanguage
        }
    }

    /// Resolve a subtitle pick. Caller is expected to skip this when
    /// the user already chose something explicit (e.g. via the route
    /// arguments) — the resolver is for the "no override" case.
    static func resolve(_ inputs: Inputs) -> SubtitleAutoSelection {
        if inputs.availableSubtitles.isEmpty {
            return inputs.disableWhenNoLanguageMatch ? .disable : .noChange
        }

        let mode = inputs.mode ?? .auto

        if mode == .off {
            return .disable
        }

        let preferredLanguages = orderedLanguages(from: inputs)

        if inputs.forcedOnly {
            let forcedSubtitles = inputs.availableSubtitles.filter(isForced)
            // Apple's Forced Only shows the forced track in the language of
            // the audio that's playing. With the audio unknown, fall back to
            // the preferred languages below.
            if inputs.forcedFollowsAudio, let audio = usableLanguage(inputs.currentAudioLanguage) {
                if let forced = bestLanguageMatch(audio, in: forcedSubtitles, preferForced: true,
                                                  preferAccessibility: inputs.preferAccessibilityTracks) {
                    return .select(forced)
                }
                return .disable
            }
            // A forced pick with no language carried from an earlier episode
            // takes this episode's forced track, whatever its language.
            let forced = preferredLanguages.isEmpty && !inputs.disableWhenNoLanguageMatch
                ? bestTrackClass(in: forcedSubtitles, preferForced: true,
                                 preferAccessibility: inputs.preferAccessibilityTracks)
                : bestLanguageMatch(preferredLanguages, in: forcedSubtitles, preferForced: true,
                                    preferAccessibility: inputs.preferAccessibilityTracks)
            if let forced { return .select(forced) }
            return .disable
        }

        if let signature = inputs.trackSignature,
           let match = bestSignatureMatch(signature, in: inputs.availableSubtitles) {
            return .select(match)
        }

        // With Show Forced Subtitles off, a forced (signs-only) track is never
        // picked automatically, not even as the only track in the language.
        let readableSubtitles = inputs.showForced
            ? inputs.availableSubtitles
            : inputs.availableSubtitles.filter { !isForced($0) }

        guard let rawLang = inputs.preferredLanguage else {
            if inputs.disableWhenNoLanguageMatch { return .disable }
            // No language preference. Always still means subtitles: the
            // backup languages first (the device's, for Always with Language
            // set to None), then the file's default full track, then the best
            // full track. Auto leaves the player alone, since turning on a
            // random language would surprise.
            if mode == .always {
                // Full-dialogue tracks first, in every step: a signs-only
                // track is only taken when the file has nothing else.
                let fullDialogue = readableSubtitles.filter { !isForced($0) }
                for pool in [fullDialogue, readableSubtitles] {
                    if !inputs.fallbackLanguages.isEmpty, let pick = bestLanguageMatch(
                        inputs.fallbackLanguages,
                        in: pool,
                        preferForced: false,
                        preferAccessibility: inputs.preferAccessibilityTracks
                    ) {
                        return .select(pick)
                    }
                    if let fileDefault = pool.first(where: { $0.isDefault }) {
                        return .select(fileDefault)
                    }
                    if let any = bestLanguageMatch(
                        nil,
                        in: pool,
                        preferForced: false,
                        preferAccessibility: inputs.preferAccessibilityTracks
                    ) {
                        return .select(any)
                    }
                }
            }
            return .noChange
        }

        if rawLang.isEmpty {
            // User explicitly said "no subs" at this level.
            return .disable
        }

        // Auto mode skips subs when the audio is already in the
        // preferred subtitle language — the one case where the forced
        // (signs/foreign-dialogue-only) track is what "show forced
        // subtitles" is FOR. Mirrors the Android resolver.
        if mode == .auto, let audio = inputs.currentAudioLanguage,
           preferredLanguages.contains(where: { languagesMatch(audio, $0) }) {
            if inputs.showForced,
               let matchingLanguage = preferredLanguages.first(where: {
                   normalizedLanguageIdentifier(audio) == normalizedLanguageIdentifier($0)
               }) ?? preferredLanguages.first(where: { languagesMatch(audio, $0) }),
               let forced = bestLanguageMatch(
                   matchingLanguage,
                   in: inputs.availableSubtitles.filter(isForced),
                   preferForced: true,
                   preferAccessibility: inputs.preferAccessibilityTracks
               ) {
                return .select(forced)
            }
            return .disable
        }

        let backupLanguages = inputs.fallbackLanguages.filter { backup in
            !backup.isEmpty && !preferredLanguages.contains(where: { languagesMatch($0, backup) })
        }

        // With a backup language, a full-dialogue track in it beats a
        // signs-only forced track in the viewer's language: the viewer wants
        // to follow the dialogue.
        if !backupLanguages.isEmpty {
            let fullDialogue = readableSubtitles.filter { !isForced($0) }
            for languages in [preferredLanguages, backupLanguages] {
                if let pick = bestLanguageMatch(
                    languages,
                    in: fullDialogue,
                    preferForced: false,
                    preferAccessibility: inputs.preferAccessibilityTracks
                ) {
                    return .select(pick)
                }
            }
        }

        // The user wants readable subs in this language: always the
        // full-dialogue track. `showForced` must NOT steal this pick —
        // a forced track is signs-only and reads as "subtitles stopped
        // working" minutes into any dialogue scene.
        if let pick = bestLanguageMatch(
            preferredLanguages,
            in: readableSubtitles,
            preferForced: false,
            preferAccessibility: inputs.preferAccessibilityTracks
        ) {
            return .select(pick)
        }

        // Nothing in the viewer's language: the backup language's track,
        // before any other fallback.
        if !backupLanguages.isEmpty, let pick = bestLanguageMatch(
            backupLanguages,
            in: readableSubtitles,
            preferForced: false,
            preferAccessibility: inputs.preferAccessibilityTracks
        ) {
            return .select(pick)
        }

        // No matching language. `always` could fall back to anything,
        // but unless forced subs are wanted we'd rather show nothing
        // than a random language the user can't read.
        if !inputs.disableWhenNoLanguageMatch,
           inputs.showForced,
           let forced = inputs.availableSubtitles.first(where: isForced) {
            return .select(forced)
        }
        return inputs.disableWhenNoLanguageMatch ? .disable : .noChange
    }

    /// The audio language Auto compares with the subtitle language. The
    /// engine's tag for the playing track wins. A stream without a usable tag
    /// (a server transcode can drop it, and `und` says nothing) falls back to
    /// the catalogue: the track at the playing audio ordinal, or, when the
    /// ordinal is unknown, the only language the file's audio comes in. A
    /// known track the catalogue can't name stays unknown rather than taking
    /// another track's language. Unknown audio gets the full track, as
    /// foreign audio does.
    static func policyAudioLanguage(
        live: String?,
        catalog: [AudioTrack],
        ordinal: Int?
    ) -> String? {
        if let live = usableLanguage(live) { return live }
        if let ordinal, catalog.indices.contains(ordinal) {
            return usableLanguage(catalog[ordinal].language)
        }
        let languages = catalog.compactMap { usableLanguage($0.language) }
        guard let first = languages.first,
              languages.allSatisfy({ languagesMatch($0, first) }) else { return nil }
        return first
    }

    private static func usableLanguage(_ language: String?) -> String? {
        guard let trimmed = language?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty,
              !["und", "mis", "mul", "zxx"].contains(trimmed.lowercased()) else { return nil }
        return trimmed
    }

    // MARK: - Matching helpers

    /// Score-based signature match. Higher score = better. Returns the
    /// top scorer, or nil when no track matched a strong signal
    /// (language or label) — forced/HI/codec equality alone is
    /// meaningless since `false == false` holds for nearly every track,
    /// and a weak "match" would hijack the Auto path.
    private static func bestSignatureMatch(
        _ sig: SubtitleTrackSignature,
        in tracks: [PlayerTrack]
    ) -> PlayerTrack? {
        var best: (PlayerTrack, Int)?
        for track in tracks {
            var score = 0
            var strongSignal = false
            if let sigLang = sig.language, !sigLang.isEmpty,
               let trackLang = track.lang, languagesMatch(trackLang, sigLang) {
                score += 5
                strongSignal = true
            }
            if sig.forced == isForced(track) {
                score += 1
            }
            if sig.hearingImpaired == track.isHearingImpaired {
                score += 1
            }
            if let sigCodec = sig.codec, let trackCodec = track.codec,
               sigCodec.caseInsensitiveCompare(trackCodec) == .orderedSame {
                score += 1
            }
            if let sigLabel = sig.label, !sigLabel.isEmpty,
               let title = track.title,
               title.localizedCaseInsensitiveContains(sigLabel) {
                score += 2
                strongSignal = true
            }
            if strongSignal, score > (best?.1 ?? 0) {
                best = (track, score)
            }
        }
        return best?.0
    }

    /// Pick the best language-matched track. Prefers non-forced
    /// (full-dialogue) when `preferForced` is false; otherwise the
    /// first forced match if any. Falls back to the first language
    /// match in either category.
    private static func bestLanguageMatch(
        _ language: String?,
        in tracks: [PlayerTrack],
        preferForced: Bool,
        preferAccessibility: Bool = false
    ) -> PlayerTrack? {
        guard let language else {
            return bestTrackClass(in: tracks, preferForced: preferForced,
                                  preferAccessibility: preferAccessibility)
        }
        return bestLanguageMatch(
            [language],
            in: tracks,
            preferForced: preferForced,
            preferAccessibility: preferAccessibility
        )
    }

    /// Apply track-class priority before regional exactness: a full-dialogue
    /// generic-language track must beat an exact signs-only track. Within the
    /// same class, exhaust Apple's ordered exact locale matches before falling
    /// back to primary-language equivalence.
    private static func bestLanguageMatch(
        _ languages: [String],
        in tracks: [PlayerTrack],
        preferForced: Bool,
        preferAccessibility: Bool
    ) -> PlayerTrack? {
        let predicates = trackClassPredicates(
            preferForced: preferForced,
            preferAccessibility: preferAccessibility
        )
        for predicate in predicates {
            for language in languages {
                let normalized = normalizedLanguageIdentifier(language)
                if let exact = tracks.first(where: { track in
                    predicate(track)
                        && track.lang.map(normalizedLanguageIdentifier) == normalized
                }) {
                    return exact
                }
            }
            for language in languages {
                if let fallback = tracks.first(where: { track in
                    predicate(track)
                        && track.lang.map { languagesMatch($0, language) } == true
                }) {
                    return fallback
                }
            }
        }
        return nil
    }

    private static func bestTrackClass(
        in tracks: [PlayerTrack],
        preferForced: Bool,
        preferAccessibility: Bool
    ) -> PlayerTrack? {
        for predicate in trackClassPredicates(
            preferForced: preferForced,
            preferAccessibility: preferAccessibility
        ) {
            if let track = tracks.first(where: predicate) { return track }
        }
        return nil
    }

    private static func trackClassPredicates(
        preferForced: Bool,
        preferAccessibility: Bool
    ) -> [(PlayerTrack) -> Bool] {
        let accessible: (PlayerTrack) -> Bool = {
            !isForced($0) && ($0.isHearingImpaired || titleIndicatesHearingImpaired($0.title))
        }
        let plain: (PlayerTrack) -> Bool = {
            !isForced($0) && !$0.isHearingImpaired && !titleIndicatesHearingImpaired($0.title)
        }
        let nonForced: (PlayerTrack) -> Bool = { !isForced($0) }
        let forced: (PlayerTrack) -> Bool = { isForced($0) }

        if preferForced { return [forced, accessible, plain, nonForced, { _ in true }] }
        if preferAccessibility { return [accessible, plain, nonForced, forced, { _ in true }] }
        return [plain, nonForced, forced, { _ in true }]
    }

    private static func orderedLanguages(from inputs: Inputs) -> [String] {
        guard let first = inputs.preferredLanguage, !first.isEmpty else { return [] }
        var result: [String] = []
        for language in [first] + inputs.additionalPreferredLanguages where !language.isEmpty {
            let normalized = normalizedLanguageIdentifier(language)
            if !result.contains(where: {
                normalizedLanguageIdentifier($0) == normalized
            }) {
                result.append(language)
            }
        }
        return result
    }

    /// A track counts as forced when the file or server flags it, or when
    /// its title says so ("English Forced", "Forced (Signs)"): plenty of
    /// files name the track without setting the forced disposition.
    static func isForced(_ track: PlayerTrack) -> Bool {
        track.isForced || titleIndicatesForced(track.title)
    }

    /// "forced" must be a whole word, and "Non-Forced" or "Not Forced"
    /// names a full track.
    static func titleIndicatesForced(_ title: String?) -> Bool {
        guard let title, !title.isEmpty else { return false }
        let tokens = title.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        return tokens.indices.contains { index in
            tokens[index] == "forced"
                && (index == tokens.startIndex || !["non", "not", "no"].contains(tokens[index - 1]))
        }
    }

    /// CC/SDH detection from the track title, for files that label the
    /// track ("English (CC)", "English SDH") without setting the ffmpeg
    /// hearing-impaired disposition flag. "cc"/"sdh" must match as whole
    /// tokens — a bare substring check would hit words like "soccer".
    static func titleIndicatesHearingImpaired(_ title: String?) -> Bool {
        guard let title, !title.isEmpty else { return false }
        let lowered = title.lowercased()
        if lowered.contains("hearing impaired") || lowered.contains("closed caption") {
            return true
        }
        let tokens = lowered.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        return tokens.contains("cc") || tokens.contains("sdh")
    }

    /// Loose ISO 639 comparison. Foundation canonicalizes arbitrary alpha-2,
    /// alpha-3 terminology, and alpha-3 bibliographic spellings before the
    /// primary language subtags are compared. This keeps Apple locale tags
    /// such as `nl-NL` equivalent to mux metadata such as `nld` without a
    /// hand-maintained language allowlist.
    static func languagesMatch(_ a: String, _ b: String) -> Bool {
        let la = normalizedLanguageIdentifier(a)
        let lb = normalizedLanguageIdentifier(b)
        if la == lb { return true }
        return canonicalPrimaryLanguage(la) == canonicalPrimaryLanguage(lb)
    }

    private static func normalizedLanguageIdentifier(_ identifier: String) -> String {
        identifier
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
    }

    private static func canonicalPrimaryLanguage(_ identifier: String) -> String {
        let primary = identifier.split(separator: "-").first.map(String.init) ?? identifier
        let languageCode = Locale(identifier: primary).language.languageCode
        return languageCode?.identifier(.alpha2)
            ?? languageCode?.identifier(.alpha3)
            ?? primary
    }
}
