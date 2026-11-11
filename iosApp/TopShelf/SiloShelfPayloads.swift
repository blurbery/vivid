import Foundation

// The parts of Silo's replies the Top Shelf reads. Decoding is forgiving on
// purpose: one odd item or field shouldn't cost the viewer the whole shelf.

/// The home sections reply.
struct SiloHomePayload: Decodable {
    struct Section: Decodable {
        let kind: String
        let items: [Item]
        /// Items that were sent but couldn't be read.
        let droppedItems: Int

        private enum CodingKeys: String, CodingKey {
            case kind = "section_type"
            case items
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            kind = try container.decode(String.self, forKey: .kind)
            // Items that aren't even a list still leave the section, so the
            // shelf can tell its own rows were unreadable.
            let sent: [Lenient<Item>]
            do {
                sent = try container.decodeIfPresent([Lenient<Item>].self, forKey: .items) ?? []
            } catch {
                items = []
                droppedItems = 1
                return
            }
            items = sent.compactMap(\.value)
            droppedItems = sent.count - items.count
        }
    }

    struct Item: Decodable {
        let contentID: String
        let type: String
        let title: String
        let seriesID: String?
        let seriesTitle: String?
        let seasonNumber: Int?
        let episodeNumber: Int?
        let positionSeconds: Double?
        let durationSeconds: Double?
        let posterURL: String?

        private enum CodingKeys: String, CodingKey {
            case contentID = "content_id"
            case type, title
            case seriesID = "series_id"
            case seriesTitle = "series_title"
            case seasonNumber = "season_number"
            case episodeNumber = "episode_number"
            case positionSeconds = "position_seconds"
            case durationSeconds = "duration_seconds"
            case posterURL = "poster_url"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            // Without these three there is nothing to open or to call it.
            contentID = try container.decode(String.self, forKey: .contentID)
            type = try container.decode(String.self, forKey: .type)
            title = try container.decode(String.self, forKey: .title)
            seriesID = container.optional(String.self, .seriesID)
            seriesTitle = container.optional(String.self, .seriesTitle)
            seasonNumber = container.optional(Int.self, .seasonNumber)
            episodeNumber = container.optional(Int.self, .episodeNumber)
            positionSeconds = container.optional(Double.self, .positionSeconds)
            durationSeconds = container.optional(Double.self, .durationSeconds)
            posterURL = container.optional(String.self, .posterURL)
        }
    }

    let sections: [Section]

    /// True when the sections the shelf reads (those whose kind `matches`)
    /// sent items but not one could be read, which means the reply has
    /// changed shape. Reported as a failure rather than as an empty shelf,
    /// so the status shows it. Other Home rows don't count either way.
    func isUnreadable(where matches: (String) -> Bool) -> Bool {
        let used = sections.filter { matches($0.kind) }
        let kept = used.reduce(0) { $0 + $1.items.count }
        let dropped = used.reduce(0) { $0 + $1.droppedItems }
        return kept == 0 && dropped > 0
    }

    private enum CodingKeys: String, CodingKey { case sections }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sections = try container.decodeIfPresent([Lenient<Section>].self, forKey: .sections)?.compactMap(\.value) ?? []
    }
}

/// One catalogue item, of which only the poster is wanted.
struct SiloItemPayload: Decodable {
    let posterURL: String?

    private enum CodingKeys: String, CodingKey { case posterURL = "poster_url" }

    init(from decoder: Decoder) throws {
        posterURL = try decoder.container(keyedBy: CodingKeys.self).optional(String.self, .posterURL)
    }
}

/// The reply to a token refresh.
struct SiloRefreshPayload: Decodable {
    let accessToken: String

    private enum CodingKeys: String, CodingKey { case accessToken = "access_token" }
}

/// An array element that decodes to nil instead of failing the whole array.
struct Lenient<Value: Decodable>: Decodable {
    let value: Value?

    init(from decoder: Decoder) throws {
        value = try? Value(from: decoder)
    }
}

private extension KeyedDecodingContainer {
    /// A value that is missing, null or of the wrong type reads as nil.
    func optional<T: Decodable>(_ type: T.Type, _ key: Key) -> T? {
        (try? decodeIfPresent(type, forKey: key)) ?? nil
    }
}
