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

    /// An episode that hasn't aired yet never plays, even with a file.
    /// Otherwise one with a file plays, and one whose list gives no file
    /// information plays once it has aired. Emby and Jellyfin list missing
    /// episodes with no files, and those are left out.
    static func isPlayable(_ episode: EpisodeListItem, now: Date) -> Bool {
        let airDate = episode.airDate.flatMap { airDateParser.date(from: String($0.prefix(10))) }
        if let airDate, airDate > now { return false }
        if let files = episode.files { return !files.isEmpty }
        return airDate != nil
    }

    private static let airDateParser: ISO8601DateFormatter = {
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withFullDate]
        return parser
    }()

    /// Fetches every regular season's episodes, a few seasons at a time, and
    /// shuffles them. Any season that fails to load fails the whole shuffle,
    /// so it never quietly leaves a season out.
    static func load(seriesId: String, seriesTitle: String?) async throws -> EpisodeShuffleQueue? {
        let seasons = try await MetadataRequestPool.shared.seasons(seriesId: seriesId).seasons
            .filter { !($0.isSpecials ?? false) && $0.seasonNumber > 0 }
            .map(\.seasonNumber)
        guard !seasons.isEmpty else { return nil }
        var episodes: [EpisodeListItem] = []
        var failure: Error?
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
                        episodes += list
                    case .failure(let error):
                        failure = error
                    }
                }
            }
            if let failure { throw failure }
        }
        var generator = SystemRandomNumberGenerator()
        return make(seriesId: seriesId, seriesTitle: seriesTitle, episodes: episodes, using: &generator)
    }
}

/// Why Shuffle couldn't start, for the alert the detail pages show.
enum EpisodeShuffleProblem: Error, Equatable {
    case unreachable
    /// The server answered, but with an error or something Vivid couldn't read.
    case loadFailed
    case nothingToPlay

    var title: String {
        switch self {
        case .unreachable: String(localized: "Can't Reach Server")
        case .loadFailed, .nothingToPlay: String(localized: "Couldn't Start Shuffle")
        }
    }

    var message: String {
        switch self {
        case .unreachable: String(localized: "Can't reach the server. Check your connection and try again.")
        case .loadFailed: String(localized: "Something went wrong while talking to the server.")
        case .nothingToPlay: String(localized: "This series has no episodes to play yet.")
        }
    }
}

extension EpisodeShuffleQueue {
    /// Only a failure to reach the server reads as unreachable.
    static func problem(for error: Error) -> EpisodeShuffleProblem {
        if case HTTPError.network = error { return .unreachable }
        if error is URLError { return .unreachable }
        return .loadFailed
    }

    /// Gathers the order for the detail pages. Nil when the task was
    /// cancelled (the viewer left the page), so nothing starts late.
    @MainActor
    static func gather(seriesId: String, seriesTitle: String?) async -> Result<EpisodeShuffleQueue, EpisodeShuffleProblem>? {
        guard ConnectionMonitor.shared.isServerReachable else { return .failure(.unreachable) }
        do {
            let queue = try await load(seriesId: seriesId, seriesTitle: seriesTitle)
            guard !Task.isCancelled else { return nil }
            return queue.map { .success($0) } ?? .failure(.nothingToPlay)
        } catch {
            guard !Task.isCancelled, !(error is CancellationError) else { return nil }
            return .failure(problem(for: error))
        }
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
