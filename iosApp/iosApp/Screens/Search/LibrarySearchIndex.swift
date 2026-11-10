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
/// hundreds of thousands of titles. It keeps each title's name and content ID
/// only, so a large library fits; Search reads its matches' details from the
/// saved library afterwards.
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
        let contentId: String
        let title: String
        let tier: Tier
        /// The typo's edits, and 0 for every other tier.
        let distance: Int

        /// Exact, prefix, word start or all words: the query reads as this title.
        var isStrong: Bool {
            switch tier {
            case .exact, .prefix, .wordStart, .allWords: true
            case .contains, .typo: false
            }
        }
    }

    /// The content IDs, one per title, in the order they were given.
    private let ids: [String]
    /// The titles' names, at the same index as `ids`.
    private let names: [String]
    /// What ranking needs of each title, at the same index as `ids`.
    private let titles: [IndexedTitle]
    /// Every form of every title.
    private let forms: [Form]
    /// The scalar values of every form, one form after another.
    private let text: [UInt32]
    /// Where each form's words start, as offsets into that form.
    private let wordStarts: [Int]
    /// The item types, indexed by `IndexedTitle.type`.
    private let types: [String]

    var count: Int { ids.count }

    init(items: [BrowseItem]) {
        self.init(titles: items.map {
            StudioLibraryDatabase.SearchTitle(contentId: $0.contentId, type: $0.type, title: $0.title, year: $0.year)
        })
    }

    init(titles all: [StudioLibraryDatabase.SearchTitle]) {
        var seen = Set<String>()
        let kept = all.filter { seen.insert($0.contentId).inserted }

        // Each title's place in title order, so ranking compares numbers only.
        var titleOrder = [Int](repeating: 0, count: kept.count)
        let byTitle = kept.indices.sorted {
            (kept[$0].title, kept[$0].contentId) < (kept[$1].title, kept[$1].contentId)
        }
        for (place, index) in byTitle.enumerated() { titleOrder[index] = place }

        var titles: [IndexedTitle] = []
        var forms: [Form] = []
        var text: [UInt32] = []
        var wordStarts: [Int] = []
        var types: [String] = []
        var typeIndex: [String: Int] = [:]
        titles.reserveCapacity(kept.count)
        forms.reserveCapacity(kept.count)

        for (index, item) in kept.enumerated() {
            let type: Int
            if let known = typeIndex[item.type] {
                type = known
            } else {
                type = types.count
                typeIndex[item.type] = type
                types.append(item.type)
            }
            let firstForm = forms.count
            for words in Self.forms(of: item.title) {
                forms.append(Form(
                    text: text.count..<(text.count + words.scalars.count),
                    wordStarts: wordStarts.count..<(wordStarts.count + words.starts.count),
                    letters: words.scalars.reduce(0) { $0 | Self.letterBit($1) }
                ))
                text += words.scalars
                wordStarts += words.starts
            }
            titles.append(IndexedTitle(
                type: type, year: item.year ?? .max, titleOrder: titleOrder[index], forms: firstForm..<forms.count
            ))
        }

        self.ids = kept.map(\.contentId)
        self.names = kept.map(\.title)
        self.titles = titles
        self.forms = forms
        self.text = text
        self.wordStarts = wordStarts
        self.types = types
    }

    /// The titles that match `query`, best first. `types` nil means every
    /// type; otherwise only items whose type it holds.
    func search(_ query: String, types wanted: Set<String>? = nil, limit: Int = 100) -> [Match] {
        let folded = Self.fold(query)
        // A query of only "&" would find every title with "and" in it, so the
        // query needs letters or digits of its own.
        guard limit > 0, !Self.words(in: folded, ampersandAsAnd: false).scalars.isEmpty else { return [] }
        let queryWords = Self.words(in: folded, ampersandAsAnd: true)
        let allowedTypes = types.map { wanted?.contains($0) ?? true }

        var hits: [Hit] = []
        text.withUnsafeBufferPointer { text in
            wordStarts.withUnsafeBufferPointer { wordStarts in
                let matcher = Matcher(query: queryWords, text: text, wordStarts: wordStarts)
                defer { matcher.release() }
                for (index, title) in titles.enumerated() where allowedTypes[title.type] {
                    guard let score = matcher.bestScore(of: title.forms, in: forms) else { continue }
                    hits.append(Hit(title: index, score: score, year: title.year, titleOrder: title.titleOrder))
                }
            }
        }
        hits.sort { $0.rank < $1.rank }
        return hits.prefix(limit).map {
            Match(contentId: ids[$0.title], title: names[$0.title], tier: $0.score.tier, distance: $0.score.distance)
        }
    }
}

// MARK: - Storage

private extension LibrarySearchIndex {
    /// What ranking needs of an item, without the item itself, so walking the
    /// titles copies no references.
    struct IndexedTitle: Sendable {
        /// The item's type, as an index into `types`.
        let type: Int
        /// The release year, or `Int.max` without one so those come last.
        let year: Int
        /// The item's place in order of title, then content ID.
        let titleOrder: Int
        /// The title's forms, in `forms`.
        let forms: Range<Int>
    }

    /// One form of a title: its letters and digits, and where its words start.
    struct Form: Sendable {
        /// The form's scalar values, in `text`.
        let text: Range<Int>
        /// Where the form's words start, in `wordStarts`.
        let wordStarts: Range<Int>
        /// `letterBit(_:)` of every scalar in the form, so a typo can be ruled
        /// out without lining the query up against it.
        let letters: UInt64
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

        var rank: (Int, Int, Int, Int) { (tier.rawValue, distance, position, length) }

        func beats(_ other: Score?) -> Bool {
            guard let other else { return true }
            return rank < other.rank
        }
    }

    /// A matching title and everything it's ranked by.
    struct Hit {
        let title: Int
        let score: Score
        let year: Int
        let titleOrder: Int

        var rank: (Int, Int, Int, Int, Int, Int) {
            (score.tier.rawValue, score.distance, score.position, score.length, year, titleOrder)
        }
    }
}

// MARK: - Reading titles and queries

private extension LibrarySearchIndex {
    static let alphanumerics = CharacterSet.alphanumerics
    /// "and", for an "&".
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
            if ampersandAsAnd, scalar == "&" {
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
    static func letterBit(_ scalar: UInt32) -> UInt64 {
        switch scalar {
        case 0x61...0x7A: 1 << UInt64(scalar - 0x61)
        case 0x30...0x39: 1 << UInt64(scalar - 0x30 + 26)
        default: 1 << UInt64(36 + scalar % 28)
        }
    }

    /// Typos allowed in a query, or a word of one, of `length` scalars: none
    /// under 5, 1 up to 8 and 2 from 9.
    static func typoAllowance(forLength length: Int) -> Int {
        switch length {
        case ..<5: 0
        case ..<9: 1
        default: 2
        }
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
    struct Matcher {
        let text: UnsafeBufferPointer<UInt32>
        let wordStarts: UnsafeBufferPointer<Int>
        let query: UnsafeBufferPointer<UInt32>
        let queryWordStarts: UnsafeBufferPointer<Int>
        /// `letterBit(_:)` of each query scalar.
        let queryLetters: UnsafeBufferPointer<UInt64>
        /// Typos the whole query allows.
        let allowance: Int
        /// Three columns of the typo table, long enough for the whole query.
        let table: UnsafeMutableBufferPointer<Int>
        /// A single start at 0, for a typo within one title word.
        let firstOnly: UnsafeBufferPointer<Int>

        init(query: Words, text: UnsafeBufferPointer<UInt32>, wordStarts: UnsafeBufferPointer<Int>) {
            self.text = text
            self.wordStarts = wordStarts
            self.query = Self.copy(query.scalars)
            self.queryWordStarts = Self.copy(query.starts)
            self.queryLetters = Self.copy(query.scalars.map(LibrarySearchIndex.letterBit))
            self.allowance = LibrarySearchIndex.typoAllowance(forLength: query.scalars.count)
            self.table = .allocate(capacity: 3 * (query.scalars.count + 1))
            self.table.initialize(repeating: 0)
            self.firstOnly = Self.copy([0])
        }

        func release() {
            query.deallocate()
            queryWordStarts.deallocate()
            queryLetters.deallocate()
            table.deallocate()
            firstOnly.deallocate()
        }

        /// The best score any of a title's forms reaches. Every form gets the
        /// cheap tiers before any gets the typo tables.
        func bestScore(of titleForms: Range<Int>, in forms: [Form]) -> Score? {
            if let best = best(.occurrence, of: titleForms, in: forms) { return best }
            if queryWordStarts.count > 1, let best = best(.allWords, of: titleForms, in: forms) { return best }
            return allowance > 0 ? best(.typo, of: titleForms, in: forms) : nil
        }

        private enum Pass { case occurrence, allWords, typo }

        private func best(_ pass: Pass, of titleForms: Range<Int>, in forms: [Form]) -> Score? {
            var best: Score?
            for index in titleForms {
                let score: Score?
                switch pass {
                case .occurrence: score = occurrence(in: forms[index])
                case .allWords: score = allWords(in: forms[index])
                case .typo: score = typo(in: forms[index])
                }
                if let score, score.beats(best) { best = score }
            }
            return best
        }

        /// Exact, prefix, word start or contains: where the query first
        /// appears in the form, preferring a word start.
        func occurrence(in form: Form) -> Score? {
            let title = formText(form), starts = formStarts(form)
            let length = query.count
            guard length <= title.count else { return nil }
            var firstAnywhere: Int?
            var word = 0
            for offset in 0...(title.count - length)
            where title[offset] == query[0] && LibrarySearchIndex.holds(query, in: title, at: offset) {
                while word < starts.count, starts[word] < offset { word += 1 }
                guard word < starts.count, starts[word] == offset else {
                    if firstAnywhere == nil { firstAnywhere = offset }
                    continue
                }
                guard offset == 0 else {
                    return Score(tier: .wordStart, distance: 0, position: offset, length: title.count)
                }
                return Score(tier: length == title.count ? .exact : .prefix, distance: 0, position: 0, length: title.count)
            }
            return firstAnywhere.map { Score(tier: .contains, distance: 0, position: $0, length: title.count) }
        }

        /// All words: each query word starts a word of the form, exactly or,
        /// for words of 5 or more, within their own allowance. Exact starts
        /// are checked for every word first, since they're cheap and rule most
        /// titles out. Each word takes the first title word it starts exactly,
        /// or else the first it starts with a typo, and the position is the
        /// earliest of those.
        func allWords(in form: Form) -> Score? {
            let title = formText(form), starts = formStarts(form)
            var position = Int.max
            for word in 0..<queryWordStarts.count {
                let range = queryWord(word)
                if let start = LibrarySearchIndex.firstWord(startingWith: queryScalars(range), in: title, starts: starts) {
                    position = min(position, start)
                } else if LibrarySearchIndex.typoAllowance(forLength: range.count) == 0 {
                    return nil
                }
            }
            // A second pass for the words without an exact start, so a title
            // the first pass rules out never reaches the typo table.
            for wordIndex in 0..<queryWordStarts.count {
                let range = queryWord(wordIndex)
                let word = queryScalars(range)
                guard LibrarySearchIndex.firstWord(startingWith: word, in: title, starts: starts) == nil else { continue }
                let allowance = LibrarySearchIndex.typoAllowance(forLength: range.count)
                guard missingLetters(range, from: form.letters) <= allowance else { return nil }
                var found: Int?
                for index in 0..<starts.count {
                    let start = starts[index]
                    let end = index + 1 < starts.count ? starts[index + 1] : title.count
                    let titleWord = UnsafeBufferPointer(rebasing: title[start..<end])
                    if LibrarySearchIndex.typoAlignment(
                        of: word, in: titleWord, from: firstOnly, allowance: allowance, table: table
                    ) != nil {
                        found = start
                        break
                    }
                }
                guard let found else { return nil }
                position = min(position, found)
            }
            return Score(tier: .allWords, distance: 0, position: position, length: title.count)
        }

        /// Typo: the query lines up with the start of a word of the form, and
        /// what follows, within the query's allowance.
        func typo(in form: Form) -> Score? {
            guard missingLetters(0..<query.count, from: form.letters) <= allowance else { return nil }
            let title = formText(form)
            guard let alignment = LibrarySearchIndex.typoAlignment(
                of: query, in: title, from: formStarts(form), allowance: allowance, table: table
            ) else { return nil }
            return Score(tier: .typo, distance: alignment.distance, position: alignment.start, length: title.count)
        }

        /// How many query scalars in `range` the form doesn't hold. Each needs
        /// an edit, so more than the allowance rules a typo out.
        private func missingLetters(_ range: Range<Int>, from letters: UInt64) -> Int {
            range.reduce(0) { $0 + (queryLetters[$1] & letters == 0 ? 1 : 0) }
        }

        private func formText(_ form: Form) -> UnsafeBufferPointer<UInt32> {
            UnsafeBufferPointer(rebasing: text[form.text])
        }

        private func formStarts(_ form: Form) -> UnsafeBufferPointer<Int> {
            UnsafeBufferPointer(rebasing: wordStarts[form.wordStarts])
        }

        /// The query scalars of its `index`th word.
        private func queryWord(_ index: Int) -> Range<Int> {
            let end = index + 1 < queryWordStarts.count ? queryWordStarts[index + 1] : query.count
            return queryWordStarts[index]..<end
        }

        private func queryScalars(_ range: Range<Int>) -> UnsafeBufferPointer<UInt32> {
            UnsafeBufferPointer(rebasing: query[range])
        }

        private static func copy<Element>(_ array: [Element]) -> UnsafeBufferPointer<Element> {
            let buffer = UnsafeMutableBufferPointer<Element>.allocate(capacity: array.count)
            _ = buffer.initialize(from: array)
            return UnsafeBufferPointer(buffer)
        }
    }

    /// Whether `text` holds `pattern` at `offset`.
    static func holds(_ pattern: UnsafeBufferPointer<UInt32>, in text: UnsafeBufferPointer<UInt32>, at offset: Int) -> Bool {
        for index in 0..<pattern.count where pattern[index] != text[offset + index] { return false }
        return true
    }

    /// The offset of the first word of `text` that starts with `pattern`.
    static func firstWord(
        startingWith pattern: UnsafeBufferPointer<UInt32>, in text: UnsafeBufferPointer<UInt32>, starts: UnsafeBufferPointer<Int>
    ) -> Int? {
        for index in 0..<starts.count {
            let start = starts[index]
            let end = index + 1 < starts.count ? starts[index + 1] : text.count
            if end - start >= pattern.count, holds(pattern, in: text, at: start) { return start }
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
    /// `table` holds three columns of `pattern.count + 1` cells.
    static func typoAlignment(
        of pattern: UnsafeBufferPointer<UInt32>,
        in text: UnsafeBufferPointer<UInt32>,
        from starts: UnsafeBufferPointer<Int>,
        allowance: Int,
        table: UnsafeMutableBufferPointer<Int>
    ) -> (distance: Int, start: Int)? {
        let rows = pattern.count + 1
        let lastRow = pattern.count
        let width = min(text.count, typoColumns)
        guard lastRow > 0, width > 0, 3 * rows <= table.count else { return nil }
        let oneEdit = 1 << startBits
        let overAllowance = (allowance + 1) * oneEdit

        // The column two back, the last one and this one, with the last row
        // each has written. Rows past that always hold `overAllowance`.
        var twoBack = table.baseAddress!
        var lastColumn = twoBack + rows
        var column = lastColumn + rows
        twoBack.update(repeating: overAllowance, count: 3 * rows)
        var twoBackEnd = 0, lastColumnEnd = 0, columnEnd = 0
        // The last row of the last column within the allowance, or -1.
        var lastColumnTop = -1
        var nextStart = 0
        var best = Int.max

        var offset = 0
        while offset <= width {
            if lastColumnTop < 0 {
                // Every alignment so far is past the allowance, so start
                // afresh at the next start.
                guard nextStart < starts.count, starts[nextStart] < width, best >= 2 * oneEdit else { break }
                offset = starts[nextStart]
                twoBack.update(repeating: overAllowance, count: twoBackEnd + 1)
                lastColumn.update(repeating: overAllowance, count: lastColumnEnd + 1)
                twoBackEnd = 0
                lastColumnEnd = 0
            }

            // Row 0 aligns none of the pattern: free at a start, and one more
            // skipped scalar of the text after it.
            if nextStart < starts.count, starts[nextStart] == offset, offset < width {
                column[0] = offset
                nextStart += 1
            } else {
                column[0] = min(lastColumn[0] + oneEdit, overAllowance)
            }
            var top = column[0] < overAllowance ? 0 : -1

            // Rows up to one past the last column's top live row can be within
            // the allowance, and so can each row under a live one.
            let band = min(lastRow, lastColumnTop + 1)
            var row = 0
            while row < lastRow, row < band || column[row] < overAllowance {
                row += 1
                var cell = min(column[row - 1], lastColumn[row]) + oneEdit
                if offset > 0 {
                    let scalar = text[offset - 1]
                    cell = min(cell, lastColumn[row - 1] + (pattern[row - 1] == scalar ? 0 : oneEdit))
                    if row > 1, offset > 1, pattern[row - 1] == text[offset - 2], pattern[row - 2] == scalar {
                        cell = min(cell, twoBack[row - 2] + oneEdit)
                    }
                }
                column[row] = min(cell, overAllowance)
                if cell < overAllowance { top = row }
            }
            // Rows past this column's still hold the column three back.
            if columnEnd > row {
                (column + row + 1).update(repeating: overAllowance, count: columnEnd - row)
            }
            columnEnd = row
            if top == lastRow { best = min(best, column[lastRow]) }

            (twoBack, lastColumn, column) = (lastColumn, column, twoBack)
            (twoBackEnd, lastColumnEnd, columnEnd) = (lastColumnEnd, columnEnd, twoBackEnd)
            lastColumnTop = top
            offset += 1
        }
        guard best != Int.max else { return nil }
        return (best >> startBits, best & (oneEdit - 1))
    }
}
