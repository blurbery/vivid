#if os(tvOS)
import AppIntents
import Foundation

/// A short Siri press in Vivid brings up tvOS's dictation prompt, then runs
/// this with the spoken words. Vivid hands them to its own search link.
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

/// `vivid://search?q=<term>`. The root view queues it like any other link
/// until someone is signed in with a profile.
@MainActor
enum TVSiriSearchLink {
    /// tvOS can run the intent on a cold launch before the root view is
    /// listening; the root view takes this when it first appears.
    private static var pendingURL: URL?

    static func deliver(term: String) {
        guard let url = url(for: term) else { return }
        pendingURL = url
        NotificationCenter.default.post(name: .vividDeepLink, object: nil, userInfo: ["url": url])
    }

    static func consumePending() -> URL? {
        defer { pendingURL = nil }
        return pendingURL
    }

    static func clearPending(matching url: URL) {
        if pendingURL?.absoluteString == url.absoluteString { pendingURL = nil }
    }

    /// The trimmed term of a search link, empty when it has none; nil for
    /// any other link.
    nonisolated static func term(from url: URL) -> String? {
        guard url.scheme?.lowercased() == "vivid", url.host?.lowercased() == "search",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let value = components.queryItems?.first { $0.name == "q" }?.value ?? ""
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated private static func url(for term: String) -> URL? {
        var components = URLComponents()
        components.scheme = "vivid"
        components.host = "search"
        components.queryItems = [URLQueryItem(name: "q", value: term)]
        return components.url
    }
}
#endif
