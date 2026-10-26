import Foundation

/// The library's movies and series, ready for Search to rank on the device as
/// the query is typed, so `spiderman` finds Spider-Man and `interstelar`
/// finds Interstellar.
///
/// Titles and queries are read without case, accents, spacing or punctuation,
/// with "&" as "and". A title with "&" also matches as if it weren't there, so
/// `fast furious` finds Fast & Furious. Each title matches at the best `Tier`
/// it reaches. Results are ranked by tier, then a typo's edits, then how early
/// in the title the match starts, then shorter titles, older ones, and title
/// order.
///
/// Everything a search needs is worked out once in `init`, and a search only
/// walks flat arrays of scalar values, so it can run on every keystroke over
/// tens of thousands of titles.
struct LibrarySearchIndex: Sendable {
    /// How a title matches the query, best first.
    enum Tier: Int, Comparable, Sendable {
        /// The title reads as the query.
        case exact
        /// The title starts with the query.
        case prefix
        /// One of the title's words starts with the query, as `men` in X-Men.
        case wordStart
        /// The query is somewhere in the title, as `iderman` in Spider-Man.
        case contains
        /// Each word of a query of two or more starts a word of the title, in
        /// any order, as `potter goblet`. Words of 5 or more allow typos.
        case allWords
        /// The query starts a word of the title, give or take a typo or two.
        case typo

        static func < (lhs: Tier, rhs: Tier) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// A title Search found, and how it matched.
    struct Match: Sendable {
        let item: BrowseItem
        let tier: Tier
        /// The typo's edits, and 0 for every other tier.
        let distance: Int

        /// Exact, prefix, word start or all words: the query reads as this title.
        var isStrong: Bool {
            switch tier {
            case .exact, .prefix, .wordStart, .allWords: return true
            case .contains, .typo: return false
            }
        }
    }

    /// The items, one per content ID, in the order they were given.
    private let items: [BrowseItem]
    /// What a search needs of each item, at the same index.
    private let entries: [Entry]
    /// Every form of every title.
    private let variants: [Variant]
    /// The scalar values of every form, one after another.
    private let scalars: [UInt32]
    /// Where each form's words start, as offsets into that form.
    private let starts: [Int]
    /// The item types, indexed by `Entry.type`.
    private let typeNames: [String]

    var count: Int { items.count }

    init(items: [BrowseItem]) {
        var seen = Set<String>()
        let kept = items.filter { seen.insert($0.contentId).inserted }
        // Each title's place in title order, so ranking compares numbers only.
        var order = [Int](repeating: 0, count: kept.count)
        let sorted = kept.indices.sorted {
            (kept[$0].title, kept[$0].contentId) < (kept[$1].title, kept[$1].contentId)
        }
        for (place, index) in sorted.enumerated() { order[index] = place }

        var entries: [Entry] = []
        var variants: [Variant] = []
        var scalars: [UInt32] = []
        var starts: [Int] = []
        var typeNames: [String] = []
        var typeCodes: [String: Int] = [:]
        entries.reserveCapacity(kept.count)
        variants.reserveCapacity(kept.count)
        for (index, item) in kept.enumerated() {
            let type: Int
            if let code = typeCodes[item.type] {
                type = code
            } else {
                type = typeNames.count
                typeCodes[item.type] = type
                typeNames.append(item.type)
            }
            let first = variants.count
            for form in Self.forms(of: item.title) {
                variants.append(Variant(
                    scalars: scalars.count..<(scalars.count + form.scalars.count),
                    starts: starts.count..<(starts.count + form.starts.count),
                    mask: form.scalars.reduce(0) { $0 | Self.bit($1) }
                ))
                scalars += form.scalars
                starts += form.starts
            }
            entries.append(Entry(type: type, year: item.year ?? .max, order: order[index], variants: first..<variants.count))
        }

        self.items = kept
        self.entries = entries
        self.variants = variants
        self.scalars = scalars
        self.starts = starts
        self.typeNames = typeNames
    }

    /// The titles that match `query`, best first. `types` nil means every
    /// type; otherwise only items whose type it holds.
    func search(_ query: String, types: Set<String>? = nil, limit: Int = 100) -> [Match] {
        let folded = Self.fold(query)
        let words = Self.words(in: folded, ampersandAsAnd: true)
        // A query of only "&" would find every title with "and" in it.
        guard limit > 0, !Self.words(in: folded, ampersandAsAnd: false).scalars.isEmpty else { return [] }
        let allowed = typeNames.map { types?.contains($0) ?? true }

        var found: [Found] = []
        scalars.withUnsafeBufferPointer { scalars in
            starts.withUnsafeBufferPointer { starts in
                let scorer = Scorer(query: words, scalars: scalars, starts: starts)
                defer { scorer.release() }
                for (index, entry) in entries.enumerated() where allowed[entry.type] {
                    guard let score = scorer.score(entry.variants, of: variants) else { continue }
                    found.append(Found(entry: index, score: score, year: entry.year, order: entry.order))
                }
            }
        }
        found.sort { $0.key < $1.key }
        return found.prefix(limit).map { Match(item: items[$0.entry], tier: $0.score.tier, distance: $0.score.distance) }
    }
}

// MARK: - Storage

private extension LibrarySearchIndex {
    /// What a search needs of an item, without the item itself, so walking
    /// the entries copies no references.
    struct Entry: Sendable {
        /// The item's type, as an index into `typeNames`.
        let type: Int
        /// The release year, or `Int.max` without one so those come last.
        let year: Int
        /// The item's place in order of title, then content ID.
        let order: Int
        /// The forms of the item's title, in `variants`.
        let variants: Range<Int>
    }

    /// One form of a title: its letters and digits, and where its words start.
    struct Variant: Sendable {
        /// The form's scalar values, in `scalars`.
        let scalars: Range<Int>
        /// Where the form's words start, in `starts`.
        let starts: Range<Int>
        /// `bit(_:)` of every scalar in the form, so a typo can be ruled out
        /// without lining the query up against it.
        let mask: UInt64
    }

    /// A title's or query's letters and digits, and the offset where each of
    /// its words starts.
    struct Words {
        var scalars: [UInt32] = []
        var starts: [Int] = []
    }

    /// How well one form of a title matches, compared best first.
    struct Score {
        let tier: Tier
        let distance: Int
        /// Where in the form the match starts: a word start, or for contains
        /// the query's offset. Exact and prefix are 0.
        let position: Int
        /// The form's length, so shorter titles come first.
        let length: Int

        var key: (Int, Int, Int, Int) { (tier.rawValue, distance, position, length) }

        func isBetter(than other: Score?) -> Bool {
            guard let other else { return true }
            return key < other.key
        }
    }

    /// A matching item and everything it's ranked by.
    struct Found {
        let entry: Int
        let score: Score
        let year: Int
        let order: Int

        var key: (Int, Int, Int, Int, Int, Int) {
            (score.tier.rawValue, score.distance, score.position, score.length, year, order)
        }
    }
}

// MARK: - Reading titles and queries

private extension LibrarySearchIndex {
    static let alphanumerics = CharacterSet.alphanumerics
    static let and: [UInt32] = [0x61, 0x6E, 0x64]

    /// Without case or accents.
    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    /// The forms a title matches as: with "&" as "and", and when it has one,
    /// again without it. Forms without letters or digits are left out.
    static func forms(of title: String) -> [Words] {
        let folded = fold(title)
        var forms = [words(in: folded, ampersandAsAnd: true)]
        if folded.unicodeScalars.contains("&") {
            forms.append(words(in: folded, ampersandAsAnd: false))
        }
        return forms.filter { !$0.scalars.isEmpty }
    }

    /// The runs of letters and digits in `folded`, joined, with where each
    /// starts. "&" is a word of its own, "and", or else a gap.
    static func words(in folded: String, ampersandAsAnd: Bool) -> Words {
        var words = Words()
        var inWord = false
        for scalar in folded.unicodeScalars {
            if scalar == "&", ampersandAsAnd {
                words.starts.append(words.scalars.count)
                words.scalars += and
                inWord = false
            } else if alphanumerics.contains(scalar) {
                if !inWord { words.starts.append(words.scalars.count) }
                words.scalars.append(scalar.value)
                inWord = true
            } else {
                inWord = false
            }
        }
        return words
    }

    /// A bit for `scalar`: one each for a to z and 0 to 9, and the rest share
    /// the others. A title without a scalar's bit doesn't hold that scalar.
    static func bit(_ scalar: UInt32) -> UInt64 {
        switch scalar {
        case 0x61...0x7A: return 1 << UInt64(scalar - 0x61)
        case 0x30...0x39: return 1 << UInt64(scalar - 0x30 + 26)
        default: return 1 << UInt64(36 + scalar % 28)
        }
    }

    /// Typos allowed in a query, or a word of one, of `length` scalars: none
    /// under 5, 1 up to 8 and 2 from 9.
    static func allowance(forLength length: Int) -> Int {
        length < 5 ? 0 : length < 9 ? 1 : 2
    }
}

// MARK: - Matching

private extension LibrarySearchIndex {
    /// Bits of a typo table cell that hold the start of its alignment. A cell
    /// is its edits times `1 << startBits`, plus the start.
    static let startBits = 6
    /// How much of a title the typo tier reads, which keeps every start
    /// within `startBits`.
    static let typoColumns = 1 << startBits

    /// Scores titles against one query. The query and the typo table live in
    /// raw memory, so scoring a title allocates nothing and counts no
    /// references. `release()` frees them.
    struct Scorer {
        let scalars: UnsafeBufferPointer<UInt32>
        let starts: UnsafeBufferPointer<Int>
        let query: UnsafeBufferPointer<UInt32>
        let queryStarts: UnsafeBufferPointer<Int>
        /// `bit(_:)` of each query scalar.
        let queryBits: UnsafeBufferPointer<UInt64>
        let allowance: Int
        /// Three columns of the typo table, long enough for the whole query.
        let columns: UnsafeMutableBufferPointer<Int>
        /// A single start at 0, for a typo within one title word.
        let origin: UnsafeBufferPointer<Int>

        init(query: Words, scalars: UnsafeBufferPointer<UInt32>, starts: UnsafeBufferPointer<Int>) {
            self.scalars = scalars
            self.starts = starts
            self.query = Self.copy(query.scalars)
            self.queryStarts = Self.copy(query.starts)
            self.queryBits = Self.copy(query.scalars.map(LibrarySearchIndex.bit))
            self.allowance = LibrarySearchIndex.allowance(forLength: query.scalars.count)
            self.columns = .allocate(capacity: 3 * (query.scalars.count + 1))
            self.columns.initialize(repeating: 0)
            self.origin = Self.copy([0])
        }

        func release() {
            query.deallocate()
            queryStarts.deallocate()
            queryBits.deallocate()
            columns.deallocate()
            origin.deallocate()
        }

        /// The best score any of a title's forms reaches, trying the cheap
        /// tiers on every form before the typo tables.
        func score(_ forms: Range<Int>, of variants: [Variant]) -> Score? {
            var best: Score?
            for form in forms {
                if let score = occurrence(in: variants[form]), score.isBetter(than: best) { best = score }
            }
            if best != nil { return best }
            if queryStarts.count > 1 {
                for form in forms {
                    if let score = allWords(in: variants[form]), score.isBetter(than: best) { best = score }
                }
                if best != nil { return best }
            }
            if allowance > 0 {
                for form in forms {
                    if let score = typo(in: variants[form]), score.isBetter(than: best) { best = score }
                }
            }
            return best
        }

        /// Exact, prefix, word start or contains: where the query first
        /// appears in the form, preferring a word start.
        func occurrence(in form: Variant) -> Score? {
            let text = title(form), words = wordStarts(form)
            let length = query.count
            guard length <= text.count else { return nil }
            var anywhere: Int?
            var word = 0
            for offset in 0...(text.count - length)
            where text[offset] == query[0] && LibrarySearchIndex.matches(query, text, at: offset) {
                while word < words.count, words[word] < offset { word += 1 }
                if word < words.count, words[word] == offset {
                    if offset == 0 {
                        return Score(tier: length == text.count ? .exact : .prefix, distance: 0, position: 0, length: text.count)
                    }
                    return Score(tier: .wordStart, distance: 0, position: offset, length: text.count)
                }
                if anywhere == nil { anywhere = offset }
            }
            return anywhere.map { Score(tier: .contains, distance: 0, position: $0, length: text.count) }
        }

        /// All words: each query word starts a word of the form, exactly or,
        /// for words of 5 or more, within their own allowance. Exact starts
        /// are checked for every word first, since they're cheap and rule most
        /// titles out. Each word takes the first title word it starts exactly,
        /// or else the first it starts with a typo, and the position is the
        /// earliest of those.
        func allWords(in form: Variant) -> Score? {
            let text = title(form), words = wordStarts(form)
            var position = Int.max
            for word in 0..<queryStarts.count {
                let range = queryWord(word)
                if let start = LibrarySearchIndex.wordStarting(with: slice(range), in: text, words: words) {
                    position = min(position, start)
                } else if LibrarySearchIndex.allowance(forLength: range.count) == 0 {
                    return nil
                }
            }
            for word in 0..<queryStarts.count {
                let range = queryWord(word)
                let pattern = slice(range)
                guard LibrarySearchIndex.wordStarting(with: pattern, in: text, words: words) == nil else { continue }
                let allowance = LibrarySearchIndex.allowance(forLength: range.count)
                guard missing(range, from: form.mask) <= allowance else { return nil }
                var found: Int?
                for index in 0..<words.count {
                    let start = words[index]
                    let end = index + 1 < words.count ? words[index + 1] : text.count
                    let titleWord = UnsafeBufferPointer(rebasing: text[start..<end])
                    if LibrarySearchIndex.typoMatch(pattern, in: titleWord, starts: origin, allowance: allowance, columns: columns) != nil {
                        found = start
                        break
                    }
                }
                guard let found else { return nil }
                position = min(position, found)
            }
            return Score(tier: .allWords, distance: 0, position: position, length: text.count)
        }

        /// Typo: the query lines up with the start of a word of the form, and
        /// what follows, within the query's allowance.
        func typo(in form: Variant) -> Score? {
            guard missing(0..<query.count, from: form.mask) <= allowance else { return nil }
            let text = title(form)
            guard let match = LibrarySearchIndex.typoMatch(
                query, in: text, starts: wordStarts(form), allowance: allowance, columns: columns
            ) else { return nil }
            return Score(tier: .typo, distance: match.distance, position: match.start, length: text.count)
        }

        /// How many query scalars in `range` the form doesn't hold. Each needs
        /// an edit, so more than the allowance rules a typo out.
        private func missing(_ range: Range<Int>, from mask: UInt64) -> Int {
            var count = 0
            for index in range where queryBits[index] & mask == 0 { count += 1 }
            return count
        }

        private func title(_ form: Variant) -> UnsafeBufferPointer<UInt32> {
            UnsafeBufferPointer(rebasing: scalars[form.scalars])
        }

        private func wordStarts(_ form: Variant) -> UnsafeBufferPointer<Int> {
            UnsafeBufferPointer(rebasing: starts[form.starts])
        }

        /// The query scalars of its `index`th word.
        private func queryWord(_ index: Int) -> Range<Int> {
            queryStarts[index]..<(index + 1 < queryStarts.count ? queryStarts[index + 1] : query.count)
        }

        private func slice(_ range: Range<Int>) -> UnsafeBufferPointer<UInt32> {
            UnsafeBufferPointer(rebasing: query[range])
        }

        private static func copy<Element>(_ array: [Element]) -> UnsafeBufferPointer<Element> {
            let buffer = UnsafeMutableBufferPointer<Element>.allocate(capacity: array.count)
            _ = buffer.initialize(from: array)
            return UnsafeBufferPointer(buffer)
        }
    }

    /// Whether `text` holds `pattern` at `offset`.
    static func matches(_ pattern: UnsafeBufferPointer<UInt32>, _ text: UnsafeBufferPointer<UInt32>, at offset: Int) -> Bool {
        for index in 0..<pattern.count where pattern[index] != text[offset + index] { return false }
        return true
    }

    /// The offset of the first word of `text` that starts with `pattern`.
    static func wordStarting(
        with pattern: UnsafeBufferPointer<UInt32>, in text: UnsafeBufferPointer<UInt32>, words: UnsafeBufferPointer<Int>
    ) -> Int? {
        for index in 0..<words.count {
            let start = words[index]
            let end = index + 1 < words.count ? words[index + 1] : text.count
            if end - start >= pattern.count, matches(pattern, text, at: start) { return start }
        }
        return nil
    }

    /// The fewest edits (insert, delete, substitute or swap two neighbours)
    /// that turn `pattern` into a prefix of `text` from one of `starts`, and
    /// the earliest start that needs that few, or nil when it takes more than
    /// `allowance`. Only the first `typoColumns` scalars of the text count.
    ///
    /// This is one pass over an optimal string alignment table, a column per
    /// scalar of the text and a row per scalar of the pattern, where an
    /// alignment may begin free only at a start (Sellers). Each cell holds its
    /// edits above the start it came from, so the smallest cell has the fewest
    /// edits and then the earliest start. Edits stop counting past the
    /// allowance, a column only works out the rows that can still be within
    /// it (Ukkonen's cut-off), and once none are, it skips to the next start.
    /// Callers have already ruled out an exact match, so after 1 edit is found
    /// and its alignments die out, later starts can't do better.
    ///
    /// `columns` holds three columns of `pattern.count + 1` cells.
    static func typoMatch(
        _ pattern: UnsafeBufferPointer<UInt32>,
        in text: UnsafeBufferPointer<UInt32>,
        starts: UnsafeBufferPointer<Int>,
        allowance: Int,
        columns: UnsafeMutableBufferPointer<Int>
    ) -> (distance: Int, start: Int)? {
        let rows = pattern.count + 1
        let last = pattern.count
        let width = min(text.count, typoColumns)
        guard last > 0, width > 0, 3 * rows <= columns.count else { return nil }
        let edit = 1 << startBits
        let dead = (allowance + 1) * edit

        // Two columns back, the last column and this one, and the last row
        // each has written. Rows past that are always `dead`.
        var older = columns.baseAddress!
        var previous = older + rows
        var current = previous + rows
        older.update(repeating: dead, count: 3 * rows)
        var olderEnd = 0, previousEnd = 0, currentEnd = 0
        // The last row of the previous column within the allowance, or -1.
        var previousTop = -1
        var nextStart = 0
        var best = Int.max

        var column = 0
        while column <= width {
            if previousTop < 0 {
                // Every alignment so far is past the allowance, so start
                // afresh at the next start.
                guard nextStart < starts.count, starts[nextStart] < width, best >= 2 * edit else { break }
                column = starts[nextStart]
                older.update(repeating: dead, count: olderEnd + 1)
                previous.update(repeating: dead, count: previousEnd + 1)
                olderEnd = 0
                previousEnd = 0
            }

            // Row 0 aligns none of the pattern: free at a start, and one more
            // skipped scalar of the text after it.
            if nextStart < starts.count, starts[nextStart] == column, column < width {
                current[0] = column
                nextStart += 1
            } else {
                current[0] = min(previous[0] + edit, dead)
            }
            var top = current[0] < dead ? 0 : -1

            // Rows up to one past the previous column's last live row can be
            // within the allowance, and so can each row under a live one.
            let band = min(last, previousTop + 1)
            var row = 0
            while row < last, row < band || current[row] < dead {
                row += 1
                var cell = min(current[row - 1], previous[row]) + edit
                if column > 0 {
                    let scalar = text[column - 1]
                    cell = min(cell, previous[row - 1] + (pattern[row - 1] == scalar ? 0 : edit))
                    if row > 1, column > 1, pattern[row - 1] == text[column - 2], pattern[row - 2] == scalar {
                        cell = min(cell, older[row - 2] + edit)
                    }
                }
                current[row] = min(cell, dead)
                if cell < dead { top = row }
            }
            // Rows past this column's still hold the one three columns back.
            if currentEnd > row {
                (current + row + 1).update(repeating: dead, count: currentEnd - row)
            }
            currentEnd = row
            if top == last { best = min(best, current[last]) }

            (older, previous, current) = (previous, current, older)
            (olderEnd, previousEnd, currentEnd) = (previousEnd, currentEnd, olderEnd)
            previousTop = top
            column += 1
        }
        guard best != Int.max else { return nil }
        return (best >> startBits, best & (edit - 1))
    }
}
