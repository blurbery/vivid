import Foundation

// Home and catalogue payloads the Top Shelf reads. Decoded with snake-case
// key conversion. Foundation only: CI compiles this file on its own on macOS.

struct TopShelfSectionsResponse: Decodable {
    let sections: [TopShelfSection]

    init(sections: [TopShelfSection]) {
        self.sections = sections
    }
}

extension TopShelfSectionsResponse {
    private enum CodingKeys: String, CodingKey {
        case sections
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sections = try container.decodeIfPresent([TopShelfSection].self, forKey: .sections) ?? []
    }
}

struct TopShelfSection: Decodable {
    let id: String
    let sectionType: String
    let title: String
    let items: [TopShelfItem]
}

struct TopShelfItem: Decodable {
    let contentId: String
    let type: String
    let title: String
    let seriesId: String?
    let seriesTitle: String?
    let seasonNumber: Int?
    let episodeNumber: Int?
    let positionSeconds: Double?
    let durationSeconds: Double?
    let progressUpdatedAt: String?
    let posterUrl: String?
    let backdropUrl: String?

    /// How far through the item is, from 0 to 1; nil without a position and
    /// a positive duration.
    var playbackProgress: Double? {
        guard let positionSeconds, let durationSeconds, durationSeconds > 0 else { return nil }
        return min(max(positionSeconds / durationSeconds, 0), 1)
    }
}

/// A series' seasons, for episode posters.
struct TopShelfSeasonsResponse: Decodable {
    let seasons: [TopShelfSeason]
}

extension TopShelfSeasonsResponse {
    private enum CodingKeys: String, CodingKey {
        case seasons
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        seasons = try container.decodeIfPresent([TopShelfSeason].self, forKey: .seasons) ?? []
    }
}

struct TopShelfSeason: Decodable {
    let seasonNumber: Int
    let posterUrl: String?
}

/// The one field the Top Shelf needs from a series' detail.
struct TopShelfItemDetail: Decodable {
    let posterUrl: String?
}
