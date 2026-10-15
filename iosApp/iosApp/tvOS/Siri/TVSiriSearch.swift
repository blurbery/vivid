#if os(tvOS)
import AppIntents
import Foundation

/// Search by voice from anywhere in Vivid.
///
/// tvOS keeps the Siri Remote's Siri button to itself: apps never receive the
/// press. From tvOS 17.2 a short press in an app that adopts
/// `ShowInAppSearchResultsIntent` brings up Apple's dictation prompt and runs
/// this intent with the words spoken, so Vivid can open Search with them.
///
/// tvOS has no `.system.search` schema macro, so this conforms to the protocol
/// directly. The protocol already runs the intent in the app's own process.
struct SearchVividIntent: ShowInAppSearchResultsIntent {
    static let title: LocalizedStringResource = "Search Vivid"
    static let description = IntentDescription("Opens Search in Vivid with what you asked for.")
    static let searchScopes: [StringSearchScope] = [.general, .movies, .tv]

    @Parameter(title: "Search Term", requestValueDialog: "What would you like to watch?")
    var criteria: StringSearchCriteria

    @MainActor
    func perform() async throws -> some IntentResult {
        TVSiriSearchLink.deliver(term: criteria.term)
        return .result()
    }
}

/// Spoken phrases for the same search. Siri asks for the title afterwards,
/// because App Shortcut phrases can't carry free text.
struct VividAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: SearchVividIntent(),
            phrases: [
                "Search \(.applicationName)",
                "Search in \(.applicationName)",
                "Find something to watch in \(.applicationName)",
            ],
            shortTitle: "Search",
            systemImageName: "magnifyingglass"
        )
    }
}

/// `vivid://search?q=<term>` opens Search with `term` in the field.
///
/// A Siri search travels as this link so it waits behind sign-in, profile
/// selection and the background profile lock in `ContentView.handleDeepLink`,
/// the same as a Top Shelf link.
@MainActor
enum TVSiriSearchLink {
    nonisolated static let host = "search"
    private nonisolated static let termQueryItem = "q"

    /// On a cold launch tvOS can run the intent before `ContentView` is
    /// listening, so the link is also kept here until it is handled.
    private static var pendingURL: URL?

    static func deliver(term: String) {
        guard let url = url(term: term) else { return }
        pendingURL = url
        NotificationCenter.default.post(name: .vividDeepLink, object: nil, userInfo: ["url": url])
    }

    static func consumePending() -> URL? {
        defer { pendingURL = nil }
        return pendingURL
    }

    static func clearPending(matching url: URL) {
        guard pendingURL?.absoluteString == url.absoluteString else { return }
        pendingURL = nil
    }

    nonisolated static func url(term: String) -> URL? {
        var components = URLComponents()
        components.scheme = "vivid"
        components.host = host
        components.queryItems = [URLQueryItem(name: termQueryItem, value: term)]
        return components.url
    }

    /// The trimmed search term (empty when the link has none), or nil when
    /// `url` isn't a search link.
    nonisolated static func term(from url: URL) -> String? {
        guard url.scheme?.lowercased() == "vivid",
              url.host?.lowercased() == host,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }
        let term = components.queryItems?.first { $0.name == termQueryItem }?.value ?? ""
        return term.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
#endif
