import Foundation

/// A series' episodes in a random order, for Shuffle. The player plays them
/// one after another through Next Up, so each one keeps the audio language,
/// subtitles and quality the viewing is using.
struct EpisodeShuffleQueue {
    let seriesId: String
    let seriesTitle: String?
    let episodes: [EpisodeListItem]

    /// The episode that follows `contentId` in this order, or nil at the end.
    func episode(after contentId: String) -> EpisodeListItem? {
        guard let index = episodes.firstIndex(where: { $0.contentId == contentId }),
              index + 1 < episodes.count else { return nil }
        return episodes[index + 1]
    }

    /// Every playable episode of the regular seasons, shuffled. Specials
    /// (season 0) are left out, as Next Up leaves them out. Nil when there
    /// is nothing to play.
    static func make<Generator: RandomNumberGenerator>(
        seriesId: String,
        seriesTitle: String?,
        episodes: [EpisodeListItem],
        now: Date = Date(),
        using generator: inout Generator
    ) -> EpisodeShuffleQueue? {
        var seen = Set<String>()
        let playable = episodes.filter { episode in
            episode.seasonNumber > 0 && isPlayable(episode, now: now) && seen.insert(episode.contentId).inserted
        }
        guard !playable.isEmpty else { return nil }
        return EpisodeShuffleQueue(
            seriesId: seriesId,
            seriesTitle: seriesTitle,
            episodes: playable.shuffled(using: &generator)
        )
    }

    /// An episode with a file plays. One whose list gives no file
    /// information plays once it has aired. Emby and Jellyfin list missing
    /// episodes with no files, and those are left out.
    static func isPlayable(_ episode: EpisodeListItem, now: Date) -> Bool {
        if let files = episode.files { return !files.isEmpty }
        guard let raw = episode.airDate, let date = airDateParser.date(from: String(raw.prefix(10))) else {
            return false
        }
        return date <= now
    }

    private static let airDateParser: ISO8601DateFormatter = {
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withFullDate]
        return parser
    }()

    /// Fetches every regular season's episodes, a few seasons at a time, and
    /// shuffles them. A season that fails to load is skipped; only when none
    /// loads does this throw.
    static func load(seriesId: String, seriesTitle: String?) async throws -> EpisodeShuffleQueue? {
        let seasons = try await MetadataRequestPool.shared.seasons(seriesId: seriesId).seasons
            .filter { !($0.isSpecials ?? false) && $0.seasonNumber > 0 }
            .map(\.seasonNumber)
        guard !seasons.isEmpty else { return nil }
        var episodes: [EpisodeListItem] = []
        var loadedAny = false
        var lastError: Error?
        for batch in stride(from: 0, to: seasons.count, by: 4).map({ Array(seasons[$0..<min($0 + 4, seasons.count)]) }) {
            try Task.checkCancellation()
            await withTaskGroup(of: Result<[EpisodeListItem], Error>.self) { group in
                for season in batch {
                    group.addTask {
                        do {
                            return .success(try await MetadataRequestPool.shared.episodes(
                                seriesId: seriesId, seasonNumber: season
                            ).episodes)
                        } catch {
                            return .failure(error)
                        }
                    }
                }
                for await result in group {
                    switch result {
                    case .success(let list):
                        loadedAny = true
                        episodes += list
                    case .failure(let error):
                        lastError = error
                    }
                }
            }
        }
        if !loadedAny, let lastError { throw lastError }
        var generator = SystemRandomNumberGenerator()
        return make(seriesId: seriesId, seriesTitle: seriesTitle, episodes: episodes, using: &generator)
    }
}

/// Carries a shuffle order from the detail page to the player that opens its
/// first episode. One use only, it must be taken by that episode's player
/// within a minute, and any other start clears it, so a stale order can
/// never turn a later ordinary Play into a shuffle.
@MainActor
final class EpisodeShuffleHandoff {
    static let shared = EpisodeShuffleHandoff()

    private var staged: (contentId: String, queue: EpisodeShuffleQueue, stagedAt: Date)?

    func stage(_ queue: EpisodeShuffleQueue) {
        guard let first = queue.episodes.first else { return }
        staged = (first.contentId, queue, Date())
    }

    func take(for contentId: String, now: Date = Date()) -> EpisodeShuffleQueue? {
        defer { staged = nil }
        guard let staged, staged.contentId == contentId,
              now.timeIntervalSince(staged.stagedAt) < 60 else { return nil }
        return staged.queue
    }
}
