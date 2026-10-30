import Foundation

/// An app-facing projection of an Vivid media track. `trackId` is the
/// per-kind id passed back through the Vivid controller; `ffIndex` is the
/// source stream index used to match server-supplied preferences.
///
/// Fields beyond id/title/lang are optional because not every codec populates
/// every field — e.g. PGS subtitle tracks report no `audio-channels`.
struct PlayerTrack: Identifiable, Equatable, Hashable {
    enum Kind: String {
        case audio
        case sub
        case video
        case unknown
    }

    let trackId: Int64
    let kind: Kind
    let title: String?
    let lang: String?
    let codec: String?
    /// Numeric channel count when the demuxer reported it.
    let audioChannelCount: Int?
    /// Demuxed bitrate in bits per second (0 if unknown).
    let bitrate: Int64?
    let isDefault: Bool
    let isForced: Bool
    let isHearingImpaired: Bool
    let isExternal: Bool
    let isSelected: Bool
    let ffIndex: Int?
    let srcId: Int?

    var id: String { "\(kind.rawValue)-\(trackId)" }

    var normalizedTitle: String? {
        Self.normalizedText(title)
    }

    var normalizedLanguageCode: String? {
        guard let code = Self.normalizedText(lang),
              code.caseInsensitiveCompare("und") != .orderedSame else {
            return nil
        }
        return code
    }

    var primaryLabel: String {
        if let title = normalizedTitle {
            return title
        }
        if let lang = normalizedLanguageCode {
            return languageDisplayName(lang)
        }
        return String(localized: "Track \(Int(trackId))", comment: "Fallback name for an untitled audio or subtitle track")
    }

    var attributesLabel: String? {
        let parts = attributeParts()
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Same attributes as `attributesLabel`, unjoined — for UIs that render
    /// each attribute as its own pill instead of a dot-separated line.
    var attributePillLabels: [String] {
        attributeParts()
    }

    /// Pill labels with the language optionally omitted — for rows that
    /// already surface the language as the primary name.
    func attributePillLabels(includeLanguage: Bool) -> [String] {
        attributeParts(includeLanguage: includeLanguage)
    }

    /// Language-first display name for subtitle pickers. Embedded subtitle
    /// titles are unreliable (frequently the format name or the media
    /// filename), so the language leads and the title demotes to
    /// `languageFirstDetailLabel` when it actually carries meaning.
    var languageFirstPrimaryLabel: String {
        if let lang = normalizedLanguageCode {
            return languageDisplayName(lang)
        }
        return primaryLabel
    }

    /// The embedded title, but only when it says something the language,
    /// codec, and flags don't already — e.g. "Dub (SDH)" or "Signs & Songs"
    /// survives; "ASS", "SubRip", or a repeat of the language is dropped.
    var languageFirstDetailLabel: String? {
        guard let lang = normalizedLanguageCode else { return nil }
        guard let title = normalizedTitle else { return nil }

        let lowered = title.lowercased()
        let formatNames: Set<String> = [
            "ass", "ssa", "srt", "subrip", "pgs", "sup", "sub",
            "vtt", "webvtt", "vobsub", "dvdsub", "mov_text",
        ]
        if formatNames.contains(lowered) { return nil }
        if let codec, lowered == codec.lowercased() { return nil }
        if title.caseInsensitiveCompare(languageDisplayName(lang)) == .orderedSame { return nil }
        // Embedded titles are usually English language names, whatever the app's language.
        if title.caseInsensitiveCompare(Self.englishLanguageName(lang)) == .orderedSame { return nil }
        if title.caseInsensitiveCompare(lang) == .orderedSame { return nil }
        return title
    }

    private func attributeParts(includeLanguage: Bool = true) -> [String] {
        var parts: [String] = []

        if includeLanguage,
           let lang = normalizedLanguageCode,
           let title = normalizedTitle,
           !title.localizedCaseInsensitiveContains(lang) {
            parts.append(languageDisplayName(lang))
        }

        if kind == .audio, let label = channelCountLabel {
            parts.append(label)
        }

        if let codec = Self.normalizedText(codec) {
            parts.append(codec.uppercased())
        }
        if isDefault {
            parts.append(String(localized: "Default", comment: "Track attribute pill: the file's default track"))
        }
        if isForced {
            parts.append(String(localized: "Forced", comment: "Track attribute pill: forced subtitles"))
        }
        if isHearingImpaired {
            parts.append("SDH")
        }
        if isExternal {
            parts.append(String(localized: "External", comment: "Track attribute pill: a subtitle file outside the video"))
        }

        return parts
    }

    /// Human-readable channel count for audio tracks (e.g. "5.1"), or nil when
    /// the demuxer reported no usable count.
    var channelCountLabel: String? {
        guard let count = audioChannelCount, count > 0 else { return nil }
        return Self.formatChannelCount(count)
    }

    private static func formatChannelCount(_ count: Int) -> String {
        switch count {
        case 1: return String(localized: "mono", comment: "Audio channel layout")
        case 2: return String(localized: "stereo", comment: "Audio channel layout")
        case 6: return "5.1"
        case 8: return "7.1"
        default: return String(localized: "\(count)ch", comment: "Audio channel count, abbreviated")
        }
    }

    /// The language's name in the app's language.
    private func languageDisplayName(_ code: String) -> String {
        guard let name = Locale.current.localizedString(forLanguageCode: code), let first = name.first else {
            return code.uppercased()
        }
        // Only the first letter: "Portugais brésilien", not "Portugais Brésilien".
        return String(first).uppercased(with: Locale.current) + name.dropFirst()
    }

    private static func englishLanguageName(_ code: String) -> String {
        Locale(identifier: "en").localizedString(forLanguageCode: code)?.capitalized ?? code.uppercased()
    }

    private static func normalizedText(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}

/// What to do with a track selection the app is holding on behalf of the user
/// (a persisted pick, a detail-screen pick, a resumed selection) when Vivid's
/// inventory arrives.
///
/// Split out as a pure decision because the hazard it exists to prevent is
/// invisible in the happy path: Vivid publishes its track inventory during
/// startup, before it has dispatched the source onto a decode backend, and an
/// audio switch applied there makes the engine rebuild its pipeline against a
/// route it has not chosen yet. On a software-decode source that rebuild lands
/// on the native path, is rejected for the codec, and takes the in-flight load
/// down with it.
enum DeferredTrackSelectionGate {
    enum Outcome: Equatable {
        /// Keep holding the selection: the load is not established yet.
        case deferUntilEstablished
        /// Adopt it as the published selection without touching the engine —
        /// the engine is already on this track.
        case adoptWithoutEngineCall
        /// Establish and different: drive the engine.
        case applyToEngine
    }

    static func outcome(
        isLoadEstablished: Bool,
        engineAlreadyMatches: Bool
    ) -> Outcome {
        guard isLoadEstablished else { return .deferUntilEstablished }
        return engineAlreadyMatches ? .adoptWithoutEngineCall : .applyToEngine
    }
}
