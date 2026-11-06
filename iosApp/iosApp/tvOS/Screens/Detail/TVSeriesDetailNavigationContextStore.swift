#if os(tvOS)
import Foundation

/// Hands a series page the episode it should open on. A Continue Watching
/// card or an episode redirect stages the context, then opens the series;
/// the next detail page for exactly that series takes it once. Memory only.
@MainActor
enum TVSeriesDetailNavigationContextStore {
    struct Context: Equatable {
        let seriesContentId: String
        let seasonNumber: Int
        let episodeContentId: String
    }

    private static var pending: Context?

    /// Replaces whatever was staged before.
    static func stage(seriesContentId: String, seasonNumber: Int, episodeContentId: String) {
        pending = Context(
            seriesContentId: seriesContentId,
            seasonNumber: seasonNumber,
            episodeContentId: episodeContentId
        )
    }

    /// The page a Continue Watching card or Spotlight slide opens. An episode
    /// with a known series and season stages itself and opens its series
    /// straight away, rather than opening its own page and redirecting once
    /// that loads. Any other item, including an episode missing either, opens
    /// its own page.
    static func destination(for item: SectionItem) -> String {
        let isEpisode = item.type.lowercased() == "episode" || item.episodeNumber != nil
        let seriesId = item.seriesId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard isEpisode, !seriesId.isEmpty, let season = item.seasonNumber else { return item.contentId }
        stage(seriesContentId: seriesId, seasonNumber: season, episodeContentId: item.contentId)
        return seriesId
    }

    /// The staged context when it belongs to this series, which clears it.
    /// Any other id leaves it pending.
    static func take(for contentId: String) -> Context? {
        guard let context = pending, context.seriesContentId == contentId else { return nil }
        pending = nil
        return context
    }
}
#endif
