import Foundation

/// A to Z the way media servers sort titles: a leading "The", "A" or "An" is
/// skipped, so "A Nightmare on Elm Street" sorts under N and "The Matrix"
/// under M. Numbers sort by value, so "Collection 9" comes before
/// "Collection 10".
enum TitleSortOrder {
    private static let leadingArticles = ["the ", "a ", "an "]

    /// Titles that differ only by a leading article fall back to their full
    /// text, so the order is stable.
    static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let order = sortKey(lhs).localizedStandardCompare(sortKey(rhs))
        return order == .orderedSame ? lhs.localizedStandardCompare(rhs) : order
    }

    /// The title without surrounding spaces or a leading article. A title
    /// that is only an article, such as "A", keeps it.
    static func sortKey(_ title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        for article in leadingArticles {
            guard let range = trimmed.range(of: article, options: [.caseInsensitive, .anchored]) else { continue }
            let rest = trimmed[range.upperBound...].trimmingCharacters(in: .whitespaces)
            if !rest.isEmpty { return rest }
        }
        return trimmed
    }

    /// Whether a name files under an A–Z choice, by the same sort key that
    /// orders a grid (so "The Matrix Collection" is under M). "#" takes
    /// every name that doesn't start with A to Z.
    static func name(_ name: String, startsWith letter: String) -> Bool {
        let first = sortKey(name)
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .uppercased()
            .first
        let isLetter = first.map { ("A"..."Z").contains($0) } ?? false
        if letter == "#" { return !isLetter }
        return isLetter && first.map(String.init) == letter
    }
}
