import CoreGraphics
import Foundation

// MARK: - Cards

enum CardPosterSize: String, Codable, CaseIterable, Identifiable, Sendable {
    case compact
    case standard
    case large

    var id: String { rawValue }

    var title: String {
        switch self {
        case .compact: String(localized: "Compact")
        case .standard: String(localized: "Standard")
        case .large: String(localized: "Large")
        }
    }

    var scale: CGFloat {
        switch self {
        case .compact: 0.86
        case .standard: 1
        case .large: 1.2
        }
    }
}

enum CardCaptionStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    case titleMetadata = "title_metadata"
    case title
    case artwork

    var id: String { rawValue }

    var title: String {
        switch self {
        case .titleMetadata: String(localized: "Title & Year")
        case .title: String(localized: "Title Only")
        case .artwork: String(localized: "Artwork Only")
        }
    }

    var showsTitle: Bool { self != .artwork }
    var showsMetadata: Bool { self == .titleMetadata }
}

struct CardPresentationPreference: Codable, Equatable, Sendable {
    var posterSize: CardPosterSize
    var caption: CardCaptionStyle

    static let standard = CardPresentationPreference(posterSize: .standard, caption: .titleMetadata)

    /// The first preset that looks exactly like this, if any.
    var preset: CardPresentationPreset? {
        CardPresentationPreset.allCases.first { $0.presentation == self }
    }

    private enum CodingKeys: String, CodingKey {
        case posterSize = "poster_size"
        case caption
    }
}

enum CardPresentationPreset: String, CaseIterable, Identifiable, Sendable {
    case balanced
    case compact
    case cinema
    case artworkOnly = "artwork_only"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .balanced: String(localized: "Balanced")
        case .compact: String(localized: "Compact")
        case .cinema: String(localized: "Cinema")
        case .artworkOnly: String(localized: "Artwork Only")
        }
    }

    var presentation: CardPresentationPreference {
        switch self {
        case .balanced: .standard
        case .compact: CardPresentationPreference(posterSize: .compact, caption: .title)
        case .cinema: CardPresentationPreference(posterSize: .large, caption: .title)
        case .artworkOnly: CardPresentationPreference(posterSize: .large, caption: .artwork)
        }
    }
}

// MARK: - Top menu

enum PrimaryMenuBuiltin: String, Codable, Sendable {
    case home
    case movies
    case series
    case forYou = "for_you"

    var title: String {
        switch self {
        case .home: String(localized: "Home")
        case .movies: String(localized: "Movies")
        case .series: String(localized: "Series")
        case .forYou: String(localized: "For You")
        }
    }

    var navigationIcon: String {
        switch self {
        case .home: AppTab.home.icon
        case .movies: "film.stack"
        case .series: "tv"
        case .forYou: AppTab.recommendations.icon
        }
    }
}

/// Home, Movies, Series, For You.
func appleDefaultPrimaryMenuItems() -> [PrimaryMenuItem] {
    [.builtin(.home), .builtin(.movies), .builtin(.series), .builtin(.forYou)]
}

enum PrimaryMenuItem: Hashable, Identifiable, Sendable {
    case builtin(PrimaryMenuBuiltin)
    case library(libraryId: Int, label: String)
    case section(libraryId: Int, sectionId: String, label: String)
    case collection(collectionId: String, label: String, libraryId: Int?)

    /// Identity for focus and de-duplication; labels never count.
    var id: String {
        switch self {
        case .builtin(let builtin):
            return "builtin:\(builtin.rawValue)"
        case .library(let libraryId, _):
            return "library:\(libraryId)"
        case .section(let libraryId, let sectionId, _):
            return "section:\(libraryId):\(sectionId)"
        case .collection(let collectionId, _, let libraryId):
            // Length-prefixed parts, so no collection id can collide with another.
            let library = libraryId.map(String.init) ?? ""
            let part = { (text: String) in "\(text.utf8.count)#\(text)" }
            return "collection|\(libraryId == nil ? 0 : 1)|\(part(library))|\(part(collectionId))"
        }
    }

    var title: String {
        switch self {
        case .builtin(let builtin): builtin.title
        case .library(_, let label), .section(_, _, let label), .collection(_, let label, _): label
        }
    }

    var isHome: Bool { self == .builtin(.home) }

    var navigationIcon: String {
        if case .builtin(let builtin) = self { return builtin.navigationIcon }
        return "rectangle.stack"
    }

    /// The settings contract's limits for one item.
    var meetsContract: Bool {
        func validLabel(_ text: String) -> Bool {
            text.count <= 256 && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        func validTarget(_ text: String) -> Bool {
            text.count <= 128 && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        switch self {
        case .builtin:
            return true
        case .library(let libraryId, let label):
            return libraryId > 0 && validLabel(label)
        case .section(let libraryId, let sectionId, let label):
            return libraryId > 0 && validTarget(sectionId) && validLabel(label)
        case .collection(let collectionId, let label, let libraryId):
            return (libraryId.map { $0 > 0 } ?? true) && validTarget(collectionId) && validLabel(label)
        }
    }
}

extension PrimaryMenuItem: Codable {
    private enum Kind: String, Codable {
        case builtin, library, section, collection
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case destination
        case libraryId = "library_id"
        case sectionId = "section_id"
        case collectionId = "collection_id"
        case label
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .type) {
        case .builtin:
            self = .builtin(try container.decode(PrimaryMenuBuiltin.self, forKey: .destination))
        case .library:
            self = .library(
                libraryId: try container.decode(Int.self, forKey: .libraryId),
                label: try container.decode(String.self, forKey: .label)
            )
        case .section:
            self = .section(
                libraryId: try container.decode(Int.self, forKey: .libraryId),
                sectionId: try container.decode(String.self, forKey: .sectionId),
                label: try container.decode(String.self, forKey: .label)
            )
        case .collection:
            self = .collection(
                collectionId: try container.decode(String.self, forKey: .collectionId),
                label: try container.decode(String.self, forKey: .label),
                libraryId: try container.decodeIfPresent(Int.self, forKey: .libraryId)
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .builtin(let builtin):
            try container.encode(Kind.builtin, forKey: .type)
            try container.encode(builtin, forKey: .destination)
        case .library(let libraryId, let label):
            try container.encode(Kind.library, forKey: .type)
            try container.encode(libraryId, forKey: .libraryId)
            try container.encode(label, forKey: .label)
        case .section(let libraryId, let sectionId, let label):
            try container.encode(Kind.section, forKey: .type)
            try container.encode(libraryId, forKey: .libraryId)
            try container.encode(sectionId, forKey: .sectionId)
            try container.encode(label, forKey: .label)
        case .collection(let collectionId, let label, let libraryId):
            try container.encode(Kind.collection, forKey: .type)
            try container.encode(collectionId, forKey: .collectionId)
            try container.encode(label, forKey: .label)
            try container.encodeIfPresent(libraryId, forKey: .libraryId)
        }
    }
}

struct PrimaryMenuPreference: Codable, Equatable, Sendable {
    var items: [PrimaryMenuItem]

    init(items: [PrimaryMenuItem]) {
        self.items = items
    }

    /// 1 to 64 items that each meet the contract, exactly one Home, no repeats.
    var isValid: Bool {
        guard (1...64).contains(items.count), items.allSatisfy(\.meetsContract) else { return false }
        guard items.filter(\.isHome).count == 1 else { return false }
        return Set(items.map(\.id)).count == items.count
    }

    /// Repeats removed, only builtins kept (other destinations are retired
    /// and never become tabs), and Home put first if it went missing.
    var normalised: PrimaryMenuPreference {
        var seen = Set<String>()
        var kept = items.filter { seen.insert($0.id).inserted }.filter {
            if case .builtin = $0 { return true }
            return false
        }
        if !kept.contains(where: \.isHome) { kept.insert(.builtin(.home), at: 0) }
        return PrimaryMenuPreference(items: kept)
    }

    private enum CodingKeys: String, CodingKey {
        case items
    }

    /// Reads past builtins a newer or older build no longer knows (such as
    /// Calendar or Music) instead of refusing the whole menu.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        var list = try container.nestedUnkeyedContainer(forKey: .items)
        var decoded: [PrimaryMenuItem] = []
        while !list.isAtEnd {
            let element = try list.decode(MenuElement.self)
            if let item = element.item { decoded.append(item) }
        }
        items = decoded
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(items, forKey: .items)
    }

    /// One element of a stored menu: nil for a builtin this build doesn't know.
    private struct MenuElement: Decodable {
        let item: PrimaryMenuItem?

        private enum Keys: String, CodingKey { case type, destination }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: Keys.self)
            let type = try container.decode(String.self, forKey: .type)
            if type == "builtin" {
                let destination = try? container.decodeIfPresent(String.self, forKey: .destination)
                item = destination.flatMap(PrimaryMenuBuiltin.init(rawValue:)).map(PrimaryMenuItem.builtin)
            } else {
                item = try PrimaryMenuItem(from: decoder)
            }
        }
    }
}
