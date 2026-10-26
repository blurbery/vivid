import Foundation

/// Search's results as each source comes in: the strong matches from the
/// library index, then the server's titles, then weaker matches and the
/// pieces' finds. A title is only added at the end or replaced where it
/// stands, so the grid never shifts under focus on Apple TV.
struct SearchResultList {
    private(set) var items: [BrowseItem] = []
    private var positions: [String: Int] = [:]

    var isEmpty: Bool { items.isEmpty }

    func contains(_ contentId: String) -> Bool { positions[contentId] != nil }

    /// Adds the titles that aren't shown yet, at the end.
    mutating func append(_ cards: [BrowseItem]) {
        for card in cards where positions[card.contentId] == nil {
            positions[card.contentId] = items.count
            items.append(card)
        }
    }

    /// Replaces shown titles with the server's cards where they stand, for
    /// current artwork and watched state, and adds the rest at the end.
    mutating func merge(_ cards: [BrowseItem]) {
        replace(cards)
        append(cards)
    }

    /// Replaces shown titles with the server's cards where they stand,
    /// leaving out titles that aren't shown.
    mutating func replace(_ cards: [BrowseItem]) {
        for card in cards {
            if let position = positions[card.contentId] { items[position] = card }
        }
    }
}
