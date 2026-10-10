import Foundation

/// Emby's episode lists carry one source per episode, while the episode
/// itself lists every version. Season, series and Choose Episodes downloads
/// fetch the rest here so their menus offer the same versions as Silo and
/// Jellyfin.
enum EpisodeSourceFiles {
    /// Silo and Jellyfin episode lists carry every file; Emby's don't.
    static var listsEveryFile: Bool { MediaServerProvider.active != .emby }

    /// Each episode's files by content id, a few requests at a time. An
    /// episode whose request fails is left out. Stops when cancelled.
    static func fetch(_ contentIds: [String], concurrency: Int = 4) async -> [String: [EpisodeFile]] {
        var found: [String: [EpisodeFile]] = [:]
        var start = 0
        while start < contentIds.count, !Task.isCancelled {
            let chunk = contentIds[start..<min(start + concurrency, contentIds.count)]
            start += concurrency
            await withTaskGroup(of: (String, [EpisodeFile]?).self) { group in
                for id in chunk {
                    group.addTask { (id, try? await VividAPI.shared.episodeFiles(contentId: id)) }
                }
                for await (id, files) in group {
                    if let files { found[id] = files }
                }
            }
        }
        return found
    }
}

extension EpisodeListItem {
    /// The same episode with every file the server has for it.
    func withEveryFile(_ files: [EpisodeFile]) -> EpisodeListItem {
        EpisodeListItem(
            contentId: contentId,
            seasonNumber: seasonNumber,
            episodeNumber: episodeNumber,
            title: title,
            overview: overview,
            airDate: airDate,
            runtime: runtime,
            imdbId: imdbId,
            tmdbId: tmdbId,
            tvdbId: tvdbId,
            stillUrl: stillUrl,
            stillThumbhash: stillThumbhash,
            userData: userData,
            files: files,
            hidesSpoilers: hidesSpoilers,
            hasEveryFile: true
        )
    }
}
