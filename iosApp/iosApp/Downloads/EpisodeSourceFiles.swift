import Foundation

/// Emby's episode lists carry one source per episode, while the episode
/// itself lists every version. Season, series and Choose Episodes downloads
/// fetch the rest here, so their menus offer the same versions as on Silo
/// and Jellyfin.
enum EpisodeSourceFiles {
    /// Silo and Jellyfin episode lists carry every file; Emby's don't.
    static var listsEveryFile: Bool { MediaServerProvider.active != .emby }

    /// Each episode's files by content ID, `concurrency` requests at a time.
    /// An episode whose request fails is left out. Stops between batches
    /// when cancelled.
    static func fetch(_ contentIds: [String], concurrency: Int = 4) async -> [String: [EpisodeFile]] {
        var filesByID: [String: [EpisodeFile]] = [:]
        var start = contentIds.startIndex
        while start < contentIds.endIndex, !Task.isCancelled {
            let end = min(start + concurrency, contentIds.endIndex)
            let batch = contentIds[start..<end]
            start += concurrency
            await withTaskGroup(of: (String, [EpisodeFile]?).self) { group in
                for id in batch {
                    group.addTask { (id, try? await VividAPI.shared.episodeFiles(contentId: id)) }
                }
                for await (id, files) in group {
                    if let files { filesByID[id] = files }
                }
            }
        }
        return filesByID
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
