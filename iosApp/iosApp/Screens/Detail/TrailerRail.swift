import Foundation

/// One card in a detail page's trailer rail: a video the catalogue links to
/// (YouTube today, found through TMDb) or one of the title's own extras.
enum TrailerRailEntry: Identifiable, Hashable {
    case remote(ItemVideo)
    case local(ItemExtra)

    /// Remote and local cards use different prefixes, so an extra can never
    /// shadow a video that happens to share its key.
    var id: String {
        switch self {
        case .remote(let video): "remote:\(video.site):\(video.siteKey)"
        case .local(let extra): "local:\(extra.contentId)"
        }
    }

    var kind: String {
        switch self {
        case .remote(let video): video.kind
        case .local(let extra): extra.kind
        }
    }

    /// The video's name or the extra's title, else the label for its kind.
    var title: String {
        let given: String?
        switch self {
        case .remote(let video): given = video.name
        case .local(let extra): given = extra.title
        }
        let trimmed = given?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? ExtraKindLabels.label(for: kind) : trimmed
    }
}

/// Builds the trailer rail and the YouTube links its cards open. Thumbnails
/// load from i.ytimg.com and a card hands the video to the YouTube app or
/// website. A card sends YouTube only the video key and normal connection
/// information, as the privacy policy says.
enum TrailerRail {
    /// Playable videos first (only YouTube can be opened), in server order,
    /// then every extra in server order.
    static func entries(videos: [ItemVideo]?, extras: [ItemExtra]?, allowRemote: Bool) -> [TrailerRailEntry] {
        let remote = allowRemote
            ? (videos ?? []).filter { $0.site.lowercased() == "youtube" }.map(TrailerRailEntry.remote)
            : []
        return remote + (extras ?? []).map(TrailerRailEntry.local)
    }

    static func thumbnailURL(siteKey: String) -> URL? {
        URL(string: "https://i.ytimg.com/vi/\(siteKey)/hqdefault.jpg")
    }

    /// The full web address with the app's scheme: the Apple TV YouTube app
    /// ignores the short form.
    static func youtubeDeepLinkURL(siteKey: String) -> URL? {
        URL(string: "youtube://www.youtube.com/watch?v=\(siteKey)")
    }

    static func youtubeWatchURL(siteKey: String) -> URL? {
        URL(string: "https://www.youtube.com/watch?v=\(siteKey)")
    }
}
