import Foundation

/// The Top Shelf's few words, in the language chosen inside Vivid when there
/// is one and the Apple TV's language otherwise.
struct ShelfStrings {
    let bundle: Bundle

    /// Works the language out afresh. The extension process outlives a change
    /// of language in the app, so every run has to ask again.
    static func current(appGroup: UserDefaults = SharedStorage.suite) -> ShelfStrings {
        let chosen = appGroup.string(forKey: SharedStorage.appLanguageKey).flatMap { $0.isEmpty ? nil : $0 }
        // Keeps anything the system formats for the extension in step.
        if let chosen {
            UserDefaults.standard.set([chosen], forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        }
        let preferences = chosen.map { [$0] } ?? systemLanguages()
        let match = Bundle.preferredLocalizations(from: Bundle.main.localizations, forPreferences: preferences).first
        let bundle = match
            .flatMap { Bundle.main.path(forResource: $0, ofType: "lproj") }
            .flatMap(Bundle.init(path:))
        return ShelfStrings(bundle: bundle ?? .main)
    }

    /// The Apple TV's own language order. Read from the global domain because
    /// this process's view may still hold the override from an earlier run.
    private static func systemLanguages() -> [String] {
        let value = CFPreferencesCopyValue(
            "AppleLanguages" as CFString,
            kCFPreferencesAnyApplication,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        )
        return value as? [String] ?? Locale.preferredLanguages
    }

    // The keys and comments below are the String Catalog's, so they can't be
    // reworded here without updating Localizable.xcstrings.

    var continueWatching: String {
        String(localized: "Continue Watching", bundle: bundle, comment: "Top Shelf row title")
    }

    var nextUp: String {
        String(localized: "Next Up", bundle: bundle, comment: "Top Shelf row title")
    }

    /// The title on a tile. An episode's own name says little on its own, so
    /// it's shown as its series with the season and episode numbers.
    func title(for entry: ShelfEntry) -> String {
        guard entry.kind == .episode,
              let seriesTitle = entry.seriesTitle, !seriesTitle.isEmpty,
              let season = entry.season, let episode = entry.episode
        else { return entry.title }
        let seasonText = String(season)
        let episodeText = String(episode)
        return String(
            localized: "\(seriesTitle) · S\(seasonText)E\(episodeText)",
            bundle: bundle,
            comment: "Top Shelf episode tile: series name, then season and episode numbers"
        )
    }
}
