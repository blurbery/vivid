#if os(tvOS)
import Observation
import SwiftUI

/// The text and artwork a Home spotlight slide shows for one item.
struct TVMarqueeContent: Equatable {
    let title: String
    let metaParts: [String]
    /// Where `runtimeText` sits in `metaParts` when it is present.
    let runtimeMetaIndex: Int
    let runtimeText: String?
    let contentRatingBadge: String?
    let backdropUrl: String?
    let fallbackArtworkUrl: String?

    /// `rowId` and `rowTitle` are accepted for callers' sake and not used.
    init(item: SectionItem, rowId: String? = nil, rowTitle: String) {
        let isEpisode = item.type.lowercased() == "episode"
        var parts: [String] = []
        if isEpisode {
            if let code = Self.episodeCode(season: item.seasonNumber, episode: item.episodeNumber) {
                parts.append(code)
            }
            parts.append(item.title)
        } else {
            if let year = item.year, year > 0 { parts.append(String(year)) }
            if let genre = item.genres?.first(where: { !$0.isEmpty }) { parts.append(genre) }
        }
        runtimeMetaIndex = parts.count
        let runtime = Self.runtimeLabel(runtime: item.runtime, durationSeconds: item.durationSeconds)
        runtimeText = runtime
        if let runtime { parts.append(runtime) }
        if !isEpisode, let rating = item.ratingImdb {
            parts.append(rating.formatted(.number.precision(.fractionLength(1))))
        }
        metaParts = parts

        title = isEpisode ? (item.seriesTitle ?? item.title) : item.title
        contentRatingBadge = item.contentRating.flatMap { $0.isEmpty ? nil : $0.uppercased() }
        backdropUrl = item.backdropUrl.flatMap { $0.isEmpty ? nil : $0 }
        fallbackArtworkUrl = item.posterUrl.flatMap { $0.isEmpty ? nil : $0 }
    }

    private static func episodeCode(season: Int?, episode: Int?) -> String? {
        switch (season, episode) {
        case let (season?, episode?):
            let seasonPart = String(
                localized: "S\(String(season))",
                comment: "Season number in an episode code, e.g. S1"
            )
            let episodePart = String(
                localized: "E\(String(episode))",
                comment: "Episode number in an episode code, e.g. E2"
            )
            return seasonPart + " " + episodePart
        case let (season?, nil):
            return String(localized: "Season \(String(season))")
        case let (nil, episode?):
            return String(localized: "Episode \(String(episode))")
        case (nil, nil):
            return nil
        }
    }

    /// Minutes from the runtime, else from the duration rounded to the
    /// nearest minute.
    private static func runtimeLabel(runtime: Int?, durationSeconds: Double?) -> String? {
        var minutes = 0
        if let runtime, runtime > 0 {
            minutes = runtime
        } else if let durationSeconds, durationSeconds > 0 {
            minutes = Int((durationSeconds / 60).rounded(.toNearestOrAwayFromZero))
        }
        guard minutes > 0 else { return nil }
        guard minutes >= 60 else { return String(localized: "\(minutes) min") }
        let hours = minutes / 60
        let remainder = minutes % 60
        return remainder == 0
            ? String(localized: "\(hours)h")
            : String(localized: "\(hours)h \(remainder)m")
    }
}

/// The backdrop and tint behind one spotlight card. The first content it is
/// given stays for its lifetime; the tint comes from what Home prepared, or
/// is worked out once and then kept.
@Observable
@MainActor
final class TVSpotlightArtworkModel {
    private(set) var tintColor: Color = .vividBackground
    private(set) var backdropURL: String?

    @ObservationIgnored private var content: TVMarqueeContent?
    @ObservationIgnored private var isSuspended = false
    /// The last URL a tint was looked up for, so the same one isn't repeated.
    @ObservationIgnored private var tintedURL: String?
    @ObservationIgnored private var tintLookup: Task<Void, Never>?

    init() {}

    func seed(_ content: TVMarqueeContent) {
        guard !isSuspended, self.content == nil else { return }
        self.content = content
        showArtwork()
    }

    func suspend() {
        isSuspended = true
        stopTintLookup()
    }

    func resume() {
        guard isSuspended else { return }
        isSuspended = false
        if content != nil { showArtwork() }
    }

    private func showArtwork() {
        guard let content else { return }
        guard let url = content.backdropUrl ?? content.fallbackArtworkUrl else {
            backdropURL = nil
            tintColor = .vividBackground
            stopTintLookup()
            return
        }
        if backdropURL != url { backdropURL = url }
        applyTint(for: url)
    }

    private func applyTint(for string: String) {
        guard !string.isEmpty, let url = URL(string: string), string != tintedURL else { return }
        tintedURL = string
        tintLookup?.cancel()
        tintLookup = nil
        if let cached = TVHomeMetadataCache.shared.cachedSpotlightTint(for: url) ?? HeroBackdropPalette.cachedTint(for: url) {
            tintColor = cached
            return
        }
        tintLookup = Task { @MainActor [weak self] in
            let tint = await TVHomeMetadataCache.shared.preparedSpotlightTint(for: url)
            guard !Task.isCancelled, let self, self.backdropURL == string else { return }
            if let tint {
                self.tintColor = tint
            } else if self.tintedURL == string {
                self.tintedURL = nil
            }
        }
    }

    private func stopTintLookup() {
        tintLookup?.cancel()
        tintLookup = nil
        tintedURL = nil
    }
}
#endif
