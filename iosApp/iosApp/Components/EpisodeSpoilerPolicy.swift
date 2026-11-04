import Foundation
import SwiftUI

/// Hides what the viewer hasn't reached yet when Hide Episode Spoilers is on.
///
/// An episode is covered when it is neither watched nor in progress and comes
/// after the viewer's position: the first episode in progress, otherwise the
/// first unwatched episode of the season they're up to, judged from the
/// seasons' watched counts. Specials sort before every numbered season, so
/// they are never covered. Silo, Emby and Jellyfin share the rule, since it
/// only reads the shared episode and season user data.
enum EpisodeSpoilerPolicy {
    /// A covered still is decoded this small and blurred once by the image
    /// pipeline (`VividImageRequest.softening`, a fraction of the decoded
    /// width), then cached like any other decode. Nothing blurs per frame and
    /// the full-size decode is skipped.
    static let coveredStillDecodeSize = CGSize(width: 64, height: 36)
    static let coveredStillSoftening: Float = 0.08

    struct Position: Hashable, Comparable {
        let season: Int
        let episode: Int

        static func < (lhs: Position, rhs: Position) -> Bool {
            (lhs.season, lhs.episode) < (rhs.season, rhs.episode)
        }
    }

    /// Where the viewer is up to, or nil when nothing is left to watch.
    /// `pages` holds the loaded episode lists by season number.
    static func currentPosition(seasons: [Season], pages: [Int: [EpisodeListItem]]) -> Position? {
        // Specials neither anchor the position nor get covered.
        let loaded = inOrder(pages.keys.sorted().flatMap { pages[$0] ?? [] }.filter { $0.seasonNumber > 0 })
        if let inProgress = loaded.first(where: isInProgress) {
            return Position(inProgress)
        }

        for season in seasons.sortedForDisplay() where !isSpecials(season) {
            if let page = pages[season.seasonNumber] {
                if let unwatched = inOrder(page).first(where: { !isPlayed($0) }) {
                    return Position(unwatched)
                }
                continue
            }
            // An unloaded season the viewer hasn't finished is where they're
            // up to, so everything from its first episode counts as not yet
            // reached. A season without user data (Emby sends no season
            // counts) is skipped rather than guessed at, so a loaded later
            // season decides from its own episodes.
            if isWatched(season) == false {
                return Position(season: season.seasonNumber, episode: 0)
            }
        }

        if seasons.isEmpty, let unwatched = loaded.first(where: { !isPlayed($0) }) {
            return Position(unwatched)
        }
        return nil
    }

    static func isFuture(_ episode: EpisodeListItem, after position: Position?) -> Bool {
        guard let position, episode.seasonNumber > 0, !isPlayed(episode), !isInProgress(episode) else { return false }
        return Position(episode) > position
    }

    /// Copies of `episodes` with the future ones covered: the overview is
    /// scrambled and the card blurs the still. The title stays readable.
    static func cover(_ episodes: [EpisodeListItem], after position: Position?) -> [EpisodeListItem] {
        guard position != nil else { return episodes }
        return episodes.map { isFuture($0, after: position) ? $0.coveringSpoilers() : $0 }
    }

    static func cover(_ pages: [Int: [EpisodeListItem]], after position: Position?) -> [Int: [EpisodeListItem]] {
        guard position != nil else { return pages }
        return pages.mapValues { cover($0, after: position) }
    }

    private static func inOrder(_ episodes: [EpisodeListItem]) -> [EpisodeListItem] {
        episodes.sorted { Position($0) < Position($1) }
    }

    private static func isPlayed(_ episode: EpisodeListItem) -> Bool {
        episode.userData?.played ?? false
    }

    private static func isInProgress(_ episode: EpisodeListItem) -> Bool {
        episode.userData?.isInProgress == true && !isPlayed(episode)
    }

    private static func isSpecials(_ season: Season) -> Bool {
        season.isSpecials == true || season.seasonNumber == 0
    }

    /// Nil when the server sent no user data for the season. No unplayed
    /// episodes means finished, including an empty season, so it never puts
    /// the position at its start.
    private static func isWatched(_ season: Season) -> Bool? {
        guard let userData = season.userData else { return nil }
        if userData.played { return true }
        return userData.unplayedCount.map { $0 == 0 } ?? false
    }
}

private extension EpisodeSpoilerPolicy.Position {
    init(_ episode: EpisodeListItem) {
        self.init(season: episode.seasonNumber, episode: episode.episodeNumber)
    }
}

extension EpisodeListItem {
    /// The same episode with its overview swapped for random letters of the
    /// same shape, and `hidesSpoilers` set so cards blur the still. The title,
    /// identifiers, numbering, dates and user data are unchanged.
    func coveringSpoilers() -> EpisodeListItem {
        EpisodeListItem(
            contentId: contentId,
            seasonNumber: seasonNumber,
            episodeNumber: episodeNumber,
            title: title,
            overview: overview.map { SpoilerText.scramble($0, seed: contentId) },
            airDate: airDate,
            runtime: runtime,
            imdbId: imdbId,
            tmdbId: tmdbId,
            tvdbId: tvdbId,
            stillUrl: stillUrl,
            stillThumbhash: stillThumbhash,
            userData: userData,
            files: files,
            hidesSpoilers: true,
            hasEveryFile: hasEveryFile
        )
    }
}

/// Swaps letters and digits for random ones, keeping case, spacing and
/// punctuation, so the result still reads as text of the same length. A given
/// seed always gives the same result, so a card doesn't change between draws.
enum SpoilerText {
    private static let lowercase = Array("abcdefghijklmnopqrstuvwxyz")
    private static let uppercase = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
    private static let digits = Array("0123456789")

    static func scramble(_ text: String, seed: String) -> String {
        var generator = SeededGenerator(seed: seed + "\u{1F}" + text)
        let characters = text.map { character -> Character in
            let pool: [Character]
            if character.isNumber {
                pool = digits
            } else if character.isLetter {
                pool = character.isUppercase ? uppercase : lowercase
            } else {
                return character
            }
            return pool.randomElement(using: &generator)!
        }
        return String(characters)
    }

    /// SplitMix64, seeded with the FNV-1a hash of the seed text.
    private struct SeededGenerator: RandomNumberGenerator {
        private var state: UInt64

        init(seed: String) {
            state = seed.utf8.reduce(0xcbf2_9ce4_8422_2325) { hash, byte in
                (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01b3
            }
        }

        mutating func next() -> UInt64 {
            state &+= 0x9e37_79b9_7f4a_7c15
            var mixed = state
            mixed = (mixed ^ (mixed >> 30)) &* 0xbf58_476d_1ce4_e5b9
            mixed = (mixed ^ (mixed >> 27)) &* 0x94d0_49bb_1331_11eb
            return mixed ^ (mixed >> 31)
        }
    }
}

extension View {
    /// Dims a covered still and marks it with an eye-slash when `active`, and
    /// leaves it untouched otherwise. The softening itself comes from the
    /// pipeline, through `coveredStillDecodeSize` and `coveredStillSoftening`.
    @ViewBuilder
    func spoilerCovered(_ active: Bool, symbolSize: CGFloat = 22) -> some View {
        if active {
            self
                .overlay(Color.black.opacity(0.25))
                .overlay {
                    Image(systemName: "eye.slash")
                        .font(.system(size: symbolSize, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.85))
                }
                .accessibilityHidden(true)
        } else {
            self
        }
    }
}
