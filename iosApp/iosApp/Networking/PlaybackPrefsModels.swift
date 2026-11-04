import Foundation

// Playback preference types shared by Settings, the detail pages and the
// player.
//
// Audio and subtitle tracks are chosen on the device on every server
// (Settings > Playback > Audio Language and Settings > Subtitles), and a pick
// lasts only for the viewing. The app never reads or writes
// `/api/v1/audio-prefs/{series_id}` or `/api/v1/subtitle-prefs/{series_id}`,
// and never picks a track from the `effective_audio_*` or
// `effective_subtitle_*` fields.

// MARK: - Track signatures

/// Finds the same subtitle track again in another episode when the stream
/// index moves: an exact signature match first, then the language.
struct SubtitleTrackSignature: Codable, Hashable {
    /// "embedded", "external" or "downloaded".
    let source: String?
    /// ISO 639-1 or 639-2.
    let language: String?
    /// "subrip", "ass", "pgs" and so on.
    let codec: String?
    let label: String?
    let forced: Bool
    let hearingImpaired: Bool

    init(
        source: String? = nil,
        language: String? = nil,
        codec: String? = nil,
        label: String? = nil,
        forced: Bool = false,
        hearingImpaired: Bool = false
    ) {
        self.source = source
        self.language = language
        self.codec = codec
        self.label = label
        self.forced = forced
        self.hearingImpaired = hearingImpaired
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        source = try container.decodeIfPresent(String.self, forKey: .source)
        language = try container.decodeIfPresent(String.self, forKey: .language)
        codec = try container.decodeIfPresent(String.self, forKey: .codec)
        label = try container.decodeIfPresent(String.self, forKey: .label)
        forced = try container.decodeIfPresent(Bool.self, forKey: .forced) ?? false
        hearingImpaired = try container.decodeIfPresent(Bool.self, forKey: .hearingImpaired) ?? false
    }
}

// MARK: - Settings values

/// Special values in the language preferences. `inherit` means no override
/// (the same word Silo's web app uses), `none` means no language and
/// `originalLanguage` follows the title's own language.
enum PlaybackPrefSentinel {
    static let inherit = "__inherit__"
    static let none = "__none__"
    static let originalLanguage = "original"
}

/// One row in a language picker. Codes come from the contract's suggestions,
/// values the server has seen and the current value; Foundation localises the
/// names.
struct PlaybackLanguageOption: Identifiable, Hashable {
    let code: String
    let label: String
    var id: String { code }

    /// ISO 639-2/B codes whose terminology form differs. Foundation maps most
    /// of them but not all (`mao`, for one), so they're spelt out.
    private static let bibliographicAliases: [String: String] = [
        "alb": "sq", "arm": "hy", "baq": "eu", "bur": "my",
        "chi": "zh", "cze": "cs", "dut": "nl", "fre": "fr",
        "geo": "ka", "ger": "de", "gre": "el", "ice": "is",
        "mac": "mk", "mao": "mi", "may": "ms", "per": "fa",
        "rum": "ro", "slo": "sk", "tib": "bo", "wel": "cy",
    ]

    /// The picker rows for a language setting: the contract's suggestions,
    /// then `runtimeValues`, then `currentValue`, one row per language. The
    /// current value replaces another spelling of the same language so the
    /// picker can select it.
    static func options(
        for key: SettingKey,
        currentValue: String? = nil,
        runtimeValues: [String] = []
    ) -> [PlaybackLanguageOption] {
        var codes: [String] = []
        var indexByLanguage: [String: Int] = [:]

        func add(_ rawValue: String, replacingAlias: Bool) {
            let code = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !code.isEmpty, code != PlaybackPrefSentinel.none, code != PlaybackPrefSentinel.inherit else { return }
            let language = languageIdentity(code)
            if let index = indexByLanguage[language] {
                if replacingAlias { codes[index] = code }
                return
            }
            indexByLanguage[language] = codes.count
            codes.append(code)
        }

        SettingPresentationMetadata.suggestedValues(for: key).forEach { add($0, replacingAlias: false) }
        runtimeValues.forEach { add($0, replacingAlias: false) }
        if let currentValue { add(currentValue, replacingAlias: true) }

        return codes.map { PlaybackLanguageOption(code: $0, label: label(forCode: $0)) }
    }

    static func label(forCode code: String) -> String {
        if code == PlaybackPrefSentinel.originalLanguage { return String(localized: "Original Language") }
        return Locale.current.localizedString(forIdentifier: code)?.capitalized
            ?? Locale.current.localizedString(forLanguageCode: code)?.capitalized
            ?? code.uppercased()
    }

    /// One spelling per language and region: `eng`, `en` and `EN` match, and
    /// so do `pt_BR` and `por-br`.
    private static func languageIdentity(_ value: String) -> String {
        let normalised = value.replacingOccurrences(of: "_", with: "-")
        var components = normalised.split(separator: "-").map(String.init)
        guard let language = components.first else { return normalised.lowercased() }
        components[0] = Locale(identifier: language).language.languageCode?.identifier(.alpha2)
            ?? bibliographicAliases[language.lowercased()]
            ?? language
        return components.joined(separator: "-").lowercased()
    }
}

// MARK: - Subtitle mode

/// Silo's `subtitle_mode`. Empty or nil inherits the next level up.
enum SubtitleMode: String, CaseIterable, Codable, Hashable {
    case auto
    case always
    case off

    var displayLabel: String {
        switch self {
        case .auto: return String(localized: "Auto")
        case .always: return String(localized: "Always")
        case .off: return String(localized: "Off")
        }
    }

    var displayDescription: String {
        switch self {
        case .auto: return String(localized: "Show subtitles only when audio language doesn't match your spoken language.")
        case .always: return String(localized: "Always show subtitles when available.")
        case .off: return String(localized: "Never show subtitles.")
        }
    }
}
