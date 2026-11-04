import Foundation

/// The automatic subtitle choice for one load.
enum SubtitleAutoSelection: Equatable {
    /// Leave the subtitles as the player started them.
    case noChange
    /// Turn subtitles off.
    case disable
    /// Select this track.
    case select(PlayerTrack)
}

/// Turns Settings > Subtitles (or the device's caption settings, or a pick
/// carried through this viewing) into a subtitle choice once the tracks are
/// known. The player runs it on the engine's tracks and the detail pages on
/// the catalogue's, so both show the same answer on every server. Pure: no
/// I/O and no actor isolation.
///
/// Audio isn't chosen here; see `VividInitialAudioPreference`.
struct SubtitleAutoResolver {

    struct Inputs {
        /// The preferred subtitle language. Nil is no preference; an empty
        /// string means no subtitles.
        let preferredLanguage: String?
        /// More preferred languages, in order, from Apple's caption profile.
        let additionalPreferredLanguages: [String]
        /// Nil is treated as Auto.
        let mode: SubtitleMode?
        /// Whether forced tracks may be chosen automatically.
        let showForced: Bool
        /// Apple's Forced Only display mode.
        let forcedOnly: Bool
        /// With `forcedOnly`, match the forced track to the audio's language,
        /// as Apple's Forced Only does, rather than to the preferred language.
        let forcedFollowsAudio: Bool
        /// Prefer CC/SDH tracks, as Apple's accessibility characteristics ask.
        let preferAccessibilityTracks: Bool
        /// The language list is authoritative: when nothing matches, turn
        /// subtitles off rather than keep whatever the server started.
        let disableWhenNoLanguageMatch: Bool
        /// A pick carried from earlier in this viewing. A track matching it
        /// wins over the language rules.
        let trackSignature: SubtitleTrackSignature?
        /// Backup languages, tried only when no track is in a preferred
        /// language. They don't count as the viewer's language when Auto
        /// compares the audio: an Arabic viewer with an English backup still
        /// gets subtitles for English audio.
        let fallbackLanguages: [String]
        /// The tracks to choose from, embedded and sidecar, in list order.
        let availableSubtitles: [PlayerTrack]
        /// The playing audio's language. Auto turns subtitles off when it's
        /// a preferred subtitle language.
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

    /// The automatic choice. Callers skip this when the viewer already chose
    /// a track for the item.
    static func resolve(_ inputs: Inputs) -> SubtitleAutoSelection {
        let tracks = inputs.availableSubtitles
        guard !tracks.isEmpty else { return inputs.disableWhenNoLanguageMatch ? .disable : .noChange }

        let mode = inputs.mode ?? .auto
        if mode == .off { return .disable }

        let accessibility = inputs.preferAccessibilityTracks
        let preferredLanguages = orderedLanguages(from: inputs)

        if inputs.forcedOnly {
            return resolveForcedOnly(inputs, preferredLanguages: preferredLanguages)
        }

        if let signature = inputs.trackSignature, let match = bestSignatureMatch(signature, in: tracks) {
            return .select(match)
        }

        // With Show Forced Subtitles off, a forced (signs-only) track is never
        // chosen automatically, not even as the only track in the language.
        let readable = inputs.showForced ? tracks : tracks.filter { !isForced($0) }

        guard let rawLanguage = inputs.preferredLanguage else {
            if inputs.disableWhenNoLanguageMatch { return .disable }
            return mode == .always ? alwaysWithoutLanguage(inputs, readable: readable) : .noChange
        }
        if rawLanguage.isEmpty { return .disable }

        // Auto with audio already in a preferred language: only the forced
        // track in that language (what Show Forced Subtitles is for), or off.
        if mode == .auto, let audio = inputs.currentAudioLanguage,
           preferredLanguages.contains(where: { languagesMatch(audio, $0) }) {
            if inputs.showForced,
               let matchingLanguage = preferredLanguages.first(where: {
                   normalizedLanguageIdentifier(audio) == normalizedLanguageIdentifier($0)
               }) ?? preferredLanguages.first(where: { languagesMatch(audio, $0) }),
               let forced = bestLanguageMatch([matchingLanguage], in: tracks.filter(isForced),
                                              preferForced: true, preferAccessibility: accessibility) {
                return .select(forced)
            }
            return .disable
        }

        let backupLanguages = inputs.fallbackLanguages.filter { backup in
            !backup.isEmpty && !preferredLanguages.contains(where: { languagesMatch($0, backup) })
        }

        // With a backup language, a full-dialogue track in it beats a
        // signs-only track in the viewer's language: the viewer wants to
        // follow the dialogue.
        if !backupLanguages.isEmpty {
            let fullDialogue = readable.filter { !isForced($0) }
            for languages in [preferredLanguages, backupLanguages] {
                if let pick = bestLanguageMatch(languages, in: fullDialogue,
                                                preferForced: false, preferAccessibility: accessibility) {
                    return .select(pick)
                }
            }
        }

        // Readable subtitles in the viewer's language, preferring the
        // full-dialogue track. A forced track mustn't take this pick: it's
        // signs-only and looks like subtitles that stopped working.
        if let pick = bestLanguageMatch(preferredLanguages, in: readable,
                                        preferForced: false, preferAccessibility: accessibility) {
            return .select(pick)
        }

        // Nothing in the viewer's language: the backup language's track.
        if !backupLanguages.isEmpty,
           let pick = bestLanguageMatch(backupLanguages, in: readable,
                                        preferForced: false, preferAccessibility: accessibility) {
            return .select(pick)
        }

        // No language matches. Rather than a language the viewer may not
        // read, take only a forced track, and only when forced are wanted.
        if !inputs.disableWhenNoLanguageMatch, inputs.showForced, let forced = tracks.first(where: isForced) {
            return .select(forced)
        }
        return inputs.disableWhenNoLanguageMatch ? .disable : .noChange
    }

    /// Apple's Forced Only: a forced track or nothing.
    private static func resolveForcedOnly(_ inputs: Inputs, preferredLanguages: [String]) -> SubtitleAutoSelection {
        let forcedTracks = inputs.availableSubtitles.filter(isForced)
        let accessibility = inputs.preferAccessibilityTracks
        // In the language of the audio that's playing. With the audio
        // unknown, the preferred languages decide instead.
        if inputs.forcedFollowsAudio, let audio = usableLanguage(inputs.currentAudioLanguage) {
            let forced = bestLanguageMatch([audio], in: forcedTracks, preferForced: true,
                                           preferAccessibility: accessibility)
            return forced.map(SubtitleAutoSelection.select) ?? .disable
        }
        // A forced pick with no language, carried from an earlier episode,
        // takes this episode's forced track in any language.
        let forced = preferredLanguages.isEmpty && !inputs.disableWhenNoLanguageMatch
            ? bestTrackClass(in: forcedTracks, preferForced: true, preferAccessibility: accessibility)
            : bestLanguageMatch(preferredLanguages, in: forcedTracks, preferForced: true,
                                preferAccessibility: accessibility)
        return forced.map(SubtitleAutoSelection.select) ?? .disable
    }

    /// Always with no preferred language still means subtitles: a backup
    /// language first (the device's, for Always with Language set to None),
    /// then the file's default track, then the best track. Each step tries
    /// full-dialogue tracks before signs-only ones.
    private static func alwaysWithoutLanguage(_ inputs: Inputs, readable: [PlayerTrack]) -> SubtitleAutoSelection {
        let accessibility = inputs.preferAccessibilityTracks
        let fullDialogue = readable.filter { !isForced($0) }
        for pool in [fullDialogue, readable] {
            if !inputs.fallbackLanguages.isEmpty,
               let pick = bestLanguageMatch(inputs.fallbackLanguages, in: pool,
                                            preferForced: false, preferAccessibility: accessibility) {
                return .select(pick)
            }
            if let fileDefault = pool.first(where: { $0.isDefault }) {
                return .select(fileDefault)
            }
            if let any = bestTrackClass(in: pool, preferForced: false, preferAccessibility: accessibility) {
                return .select(any)
            }
        }
        return .noChange
    }

    /// The audio language Auto compares with the subtitle language. The
    /// engine's tag for the playing track wins. A stream without a usable tag
    /// (a server transcode can drop it, and `und` says nothing) falls back to
    /// the catalogue: the track at the playing audio ordinal, or, when the
    /// ordinal is unknown, the only language the file's audio comes in. A
    /// known track the catalogue can't name stays unknown rather than taking
    /// another track's language. Unknown audio gets the full track, as
    /// foreign audio does.
    static func policyAudioLanguage(live: String?, catalog: [AudioTrack], ordinal: Int?) -> String? {
        if let live = usableLanguage(live) { return live }
        if let ordinal, catalog.indices.contains(ordinal) {
            return usableLanguage(catalog[ordinal].language)
        }
        let languages = catalog.compactMap { usableLanguage($0.language) }
        guard let first = languages.first, languages.allSatisfy({ languagesMatch($0, first) }) else { return nil }
        return first
    }

    // MARK: - Track classes and flags

    /// A track counts as forced when the file or server flags it, or when
    /// its title says so ("English Forced", "Forced (Signs)"): plenty of
    /// files name the track without setting the forced disposition.
    static func isForced(_ track: PlayerTrack) -> Bool {
        track.isForced || titleIndicatesForced(track.title)
    }

    /// "forced" must be a whole word, and "Non-Forced", "Not Forced" or
    /// "No Forced" names a full track.
    static func titleIndicatesForced(_ title: String?) -> Bool {
        guard let title, !title.isEmpty else { return false }
        let tokens = words(in: title)
        return tokens.indices.contains { index in
            tokens[index] == "forced"
                && (index == tokens.startIndex || !["non", "not", "no"].contains(tokens[index - 1]))
        }
    }

    /// CC/SDH from the title, for files that label the track ("English (CC)",
    /// "English SDH") without the hearing-impaired disposition. "cc" and
    /// "sdh" must be whole words, so "soccer" doesn't count.
    static func titleIndicatesHearingImpaired(_ title: String?) -> Bool {
        guard let title, !title.isEmpty else { return false }
        let lowered = title.lowercased()
        if lowered.contains("hearing impaired") || lowered.contains("closed caption") { return true }
        let tokens = words(in: lowered)
        return tokens.contains("cc") || tokens.contains("sdh")
    }

    private static func words(in text: String) -> [Substring] {
        text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber })
    }

    /// The track classes to try, best first.
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
        let any: (PlayerTrack) -> Bool = { _ in true }

        if preferForced { return [forced, accessible, plain, nonForced, any] }
        if preferAccessibility { return [accessible, plain, nonForced, forced, any] }
        return [plain, nonForced, forced, any]
    }

    // MARK: - Matching

    /// The best track for a carried pick, by score. A track needs a strong
    /// signal (its language or its title) to count: forced, CC and codec
    /// agree on nearly every track, so on their own they'd hijack Auto.
    private static func bestSignatureMatch(_ signature: SubtitleTrackSignature,
                                           in tracks: [PlayerTrack]) -> PlayerTrack? {
        var best: (track: PlayerTrack, score: Int)?
        for track in tracks {
            var score = 0
            var strongSignal = false
            if let language = signature.language, !language.isEmpty,
               let trackLanguage = track.lang, languagesMatch(trackLanguage, language) {
                score += 5
                strongSignal = true
            }
            if signature.forced == isForced(track) { score += 1 }
            if signature.hearingImpaired == track.isHearingImpaired { score += 1 }
            if let codec = signature.codec, let trackCodec = track.codec,
               codec.caseInsensitiveCompare(trackCodec) == .orderedSame {
                score += 1
            }
            if let label = signature.label, !label.isEmpty,
               let title = track.title, title.localizedCaseInsensitiveContains(label) {
                score += 2
                strongSignal = true
            }
            if strongSignal, score > (best?.score ?? 0) {
                best = (track, score)
            }
        }
        return best?.track
    }

    /// The best track in one of `languages`. Track class comes before
    /// regional exactness, so a full-dialogue track in the generic language
    /// beats an exact signs-only one. Within a class, every exact match (in
    /// language order) is tried before primary-language matches.
    private static func bestLanguageMatch(
        _ languages: [String],
        in tracks: [PlayerTrack],
        preferForced: Bool,
        preferAccessibility: Bool
    ) -> PlayerTrack? {
        for predicate in trackClassPredicates(preferForced: preferForced, preferAccessibility: preferAccessibility) {
            for language in languages {
                let normalized = normalizedLanguageIdentifier(language)
                if let exact = tracks.first(where: {
                    predicate($0) && $0.lang.map(normalizedLanguageIdentifier) == normalized
                }) {
                    return exact
                }
            }
            for language in languages {
                if let match = tracks.first(where: {
                    predicate($0) && $0.lang.map { languagesMatch($0, language) } == true
                }) {
                    return match
                }
            }
        }
        return nil
    }

    /// The first track of the best class present, whatever its language.
    private static func bestTrackClass(in tracks: [PlayerTrack], preferForced: Bool,
                                       preferAccessibility: Bool) -> PlayerTrack? {
        for predicate in trackClassPredicates(preferForced: preferForced, preferAccessibility: preferAccessibility) {
            if let track = tracks.first(where: predicate) { return track }
        }
        return nil
    }

    // MARK: - Languages

    /// The preferred language then the additional ones, without blanks or
    /// repeats. Empty when there's no preferred language.
    private static func orderedLanguages(from inputs: Inputs) -> [String] {
        guard let first = inputs.preferredLanguage, !first.isEmpty else { return [] }
        var result: [String] = []
        for language in [first] + inputs.additionalPreferredLanguages where !language.isEmpty {
            let normalized = normalizedLanguageIdentifier(language)
            if !result.contains(where: { normalizedLanguageIdentifier($0) == normalized }) {
                result.append(language)
            }
        }
        return result
    }

    /// The trimmed language, or nil when it's blank or names no language
    /// (`und`, `mis`, `mul`, `zxx`).
    private static func usableLanguage(_ language: String?) -> String? {
        guard let trimmed = language?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty,
              !["und", "mis", "mul", "zxx"].contains(trimmed.lowercased()) else { return nil }
        return trimmed
    }

    /// Loose ISO 639 comparison. Foundation canonicalises alpha-2, alpha-3
    /// terminology and alpha-3 bibliographic codes before the primary
    /// subtags are compared, so an Apple tag such as `nl-NL` matches file
    /// metadata such as `nld` without a hand-kept language list.
    static func languagesMatch(_ a: String, _ b: String) -> Bool {
        let left = normalizedLanguageIdentifier(a)
        let right = normalizedLanguageIdentifier(b)
        return left == right || canonicalPrimaryLanguage(left) == canonicalPrimaryLanguage(right)
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
        return languageCode?.identifier(.alpha2) ?? languageCode?.identifier(.alpha3) ?? primary
    }
}
