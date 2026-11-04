import Foundation

/// Spacing and punctuation insensitive title matching for Search, so
/// `spiderman` finds Spider-Man and `oceans eleven` finds Ocean's Eleven.
///
/// Silo, Emby and Jellyfin match the words of the query as typed, so a title
/// with a hyphen, apostrophe or colon the query leaves out can be missed.
/// Search also asks the server for a shorter piece or two of the query, then
/// adds the titles from those whose letters and digits contain the query's.
/// When that finds nothing, it tries the query's longest word with a hyphen
/// near its start, so `xmen` finds X-Men. It doesn't allow for typos.
enum SearchMatching {
    /// Letters and digits only, without case or accents.
    static func key(_ text: String) -> String {
        String(fold(text).unicodeScalars.filter(CharacterSet.alphanumerics.contains))
    }

    /// What Search asks the server for besides the query itself.
    ///
    /// The query's longest word on its own finds titles that join it to the
    /// next word with punctuation, as in "Mission: Impossible". When the title
    /// also splits that word, as Spider-Man splits `spiderman`, the start of
    /// the word finds it, since servers match the start of a title's words.
    /// The start is half the word, so a split anywhere in its second half is
    /// found. Pieces are at least three characters: the start needs a word of
    /// five letters and digits, and the word on its own needs four, so `dune`
    /// and `x men` add none.
    static func pieces(of query: String) -> [String] {
        let words = Self.words(of: query)
        guard let longest = longestWord(in: words) else { return [] }
        var pieces: [String] = []
        if words.count > 1, longest.count >= 4 { pieces.append(longest) }
        if longest.count >= 5 { pieces.append(String(longest.prefix(startLength(of: longest)))) }
        return pieces
    }

    /// What Search asks for when neither the query nor its pieces found a
    /// title holding it: the longest word with a hyphen after each letter
    /// before the start the pieces use, as in `x-men` and `toy-story`. Every
    /// server finds a title typed with its hyphen, and a hyphen in the wrong
    /// place matches nothing. Up to five, so a first word of up to five
    /// letters is found, as in `harry-potter`.
    static func splits(of query: String) -> [String] {
        guard let longest = longestWord(in: words(of: query)), longest.count >= 4 else { return [] }
        let lastSplit = min(startLength(of: longest), 6)
        return (1..<lastSplit).map { "\(longest.prefix($0))-\(longest.dropFirst($0))" }
    }

    /// Whether any of `items` has a title whose letters and digits contain
    /// the query's.
    static func hasMatch(in items: [BrowseItem], query: String) -> Bool {
        let wanted = key(query)
        guard !wanted.isEmpty else { return false }
        return items.contains { key($0.title).contains(wanted) }
    }

    /// The titles from the pieces' results whose letters and digits contain
    /// the query's, whatever spacing or punctuation sits between them. They
    /// keep the server's order with those that start with the query first,
    /// and each title appears once.
    static func matches(in pages: [[BrowseItem]], query: String) -> [BrowseItem] {
        let wanted = key(query)
        guard !wanted.isEmpty else { return [] }
        var seen = Set<String>()
        var leading: [BrowseItem] = []
        var others: [BrowseItem] = []
        for item in pages.joined() {
            let title = key(item.title)
            guard title.contains(wanted), seen.insert(item.contentId).inserted else { continue }
            if title.hasPrefix(wanted) { leading.append(item) } else { others.append(item) }
        }
        return leading + others
    }

    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    /// The query's words, without case or accents, split at spaces and punctuation.
    private static func words(of query: String) -> [String] {
        fold(query).unicodeScalars
            .split { !CharacterSet.alphanumerics.contains($0) }
            .map { String(String.UnicodeScalarView($0)) }
    }

    /// The longest word, the first of those as long.
    private static func longestWord(in words: [String]) -> String? {
        words.max { $0.count < $1.count }
    }

    /// The length of the start of `word` that Search asks for: half of it,
    /// and at least three characters.
    private static func startLength(of word: String) -> Int {
        max((word.count + 1) / 2, 3)
    }
}
