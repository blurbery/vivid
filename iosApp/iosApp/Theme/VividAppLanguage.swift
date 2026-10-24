import Foundation

/// The language of Vivid's interface on this device. `system` follows the
/// device's language order. Any other choice is saved as Vivid's own
/// `AppleLanguages` override, the same key iOS's per-app Language setting
/// writes, and takes effect the next time Vivid opens.
enum VividAppLanguage: String, CaseIterable, Identifiable {
    case system
    case english = "en"
    case french = "fr"
    case german = "de"
    case spanish = "es"
    case japanese = "ja"
    case simplifiedChinese = "zh-Hans"

    private static let overrideKey = "AppleLanguages"
    var id: String { rawValue }

    /// Each language's name in that language, shown the same in every
    /// language so people can find their own. `nil` for `system`.
    var nativeName: String? {
        switch self {
        case .system: nil
        case .english: "English"
        case .french: "Français"
        case .german: "Deutsch"
        case .spanish: "Español"
        case .japanese: "日本語"
        case .simplifiedChinese: "简体中文"
        }
    }

    /// The saved choice. Reads Vivid's own defaults only: the device's
    /// language list also answers to `AppleLanguages` through the global
    /// domain.
    static var saved: VividAppLanguage {
        guard let bundleID = Bundle.main.bundleIdentifier,
              let languages = UserDefaults.standard.persistentDomain(forName: bundleID)?[overrideKey] as? [String],
              let first = languages.first else { return .system }
        return allCases.first { $0 != .system && (first == $0.rawValue || first.hasPrefix($0.rawValue + "-")) } ?? .system
    }

    static func save(_ language: VividAppLanguage) {
        if language == .system {
            UserDefaults.standard.removeObject(forKey: overrideKey)
            SharedStorage.suite.removeObject(forKey: SharedStorage.appLanguageKey)
        } else {
            UserDefaults.standard.set([language.rawValue], forKey: overrideKey)
            SharedStorage.suite.set(language.rawValue, forKey: SharedStorage.appLanguageKey)
        }
    }

    /// Whether Vivid has to reopen to show `language`: false when the choice
    /// resolves to the language it already shows.
    static func needsReopen(for language: VividAppLanguage) -> Bool {
        let preferences = language == .system ? deviceLanguages : [language.rawValue]
        let resolved = Bundle.preferredLocalizations(from: Bundle.main.localizations, forPreferences: preferences).first
        return resolved != Bundle.main.preferredLocalizations.first
    }

    /// The device's language order, without Vivid's own override.
    private static var deviceLanguages: [String] {
        CFPreferencesCopyValue("AppleLanguages" as CFString, kCFPreferencesAnyApplication,
                               kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? [String] ?? []
    }

    /// The language Vivid is showing now, as TMDb names it, or `nil` for
    /// English, which is what TMDb answers without one.
    static var tmdbLanguage: String? {
        switch Bundle.main.preferredLocalizations.first {
        case "fr": "fr-FR"
        case "de": "de-DE"
        case "es": "es-ES"
        case "ja": "ja-JP"
        case "zh-Hans": "zh-CN"
        default: nil
        }
    }
}
