import Foundation

/// Spacing and punctuation insensitive title matching for Search, so
/// `spiderman` finds Spider-Man and `oceans eleven` finds Ocean's Eleven.
///
/// Silo, Emby and Jellyfin match the words of the query as typed, so a title
/// with a hyphen, apostrophe or colon the query leaves out can be missed.
/// Search also asks the server for a shorter piece or two of the query, then
/// adds the titles from those whose letters and digits contain the query's.
/// It doesn't allow for typos.
enum SearchMatching {
    /// Letters and digits only, without case or accents.
    static func key(_ text: String) -> String {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        return String(folded.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }

    /// What Search asks the server for besides the query itself.
    ///
    /// The query's longest word on its own finds titles that join it to the
    /// next word with punctuation, as in "Mission: Impossible". When the title
    /// also splits that word, as Spider-Man splits `spiderman`, the start of
    /// the word finds it, since servers match the start of a title's words.
    /// The start is half the word, so a split anywhere in its second half is
    /// found. Pieces are at least three characters, and queries under four
    /// letters and digits add none.
    static func pieces(of query: String) -> [String] {
        let folded = query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        let words = folded.unicodeScalars
            .split { !CharacterSet.alphanumerics.contains($0) }
            .map { String(String.UnicodeScalarView($0)) }
        guard words.joined().count >= 4,
              let longest = words.max(by: { $0.count < $1.count }) else { return [] }

        var pieces: [String] = []
        if words.count > 1, longest.count >= 4 { pieces.append(longest) }
        if longest.count >= 5 { pieces.append(String(longest.prefix(max((longest.count + 1) / 2, 3)))) }
        return pieces
    }

    /// The titles from the pieces' results whose letters and digits contain
    /// the query's, whatever spacing or punctuation sits between them. They
    /// keep the server's order with those that start with the query first,
    /// and each title appears once.
    static func matches(in pages: [[BrowseItem]], query: String) -> [BrowseItem] {
        let wanted = key(query)
        guard !wanted.isEmpty else { return [] }
        var seen = Set<String>()
        let found = pages.joined().filter { item in
            key(item.title).contains(wanted) && seen.insert(item.contentId).inserted
        }
        let leading = found.filter { key($0.title).hasPrefix(wanted) }
        return leading + found.filter { !key($0.title).hasPrefix(wanted) }
    }
}
