import Foundation
import SQLite3

/// The library index that Studios & Networks, Search and movie collection
/// rows read, kept on disk in SQLite.
///
/// A library can run to hundreds of thousands of titles, and holding every
/// one in memory took about 8.6 KB each: enough on a large library for tvOS
/// to close the app partway through the read. Here each page of titles goes
/// straight to disk as it arrives, memory holds only what a query returns,
/// and the progress saved with each page lets a read cut short carry on
/// where it stopped instead of starting again.
///
/// One file is read at a time: a read builds a separate file, which replaces
/// the one in use only once it's complete, so Search and brand pages keep
/// working from the last complete read meanwhile. Every call is synchronous
/// and serialised, so callers with more than a few lookups run off the main
/// actor.
final class StudioLibraryDatabase: @unchecked Sendable {
    /// The kind of title a library read asked for. Each has its own keys.
    enum Media: String, Sendable, CaseIterable {
        case movie, series
    }

    /// What Search keeps of each title.
    struct SearchTitle: Sendable {
        let contentId: String
        let type: String
        let title: String
        let year: Int?
    }

    /// How far a read of one kind has got.
    struct Progress: Equatable, Sendable {
        /// The library offset the next page starts at.
        var offset: Int
        /// The server has no more titles of this kind.
        var isDone: Bool
    }

    /// One title from a library page, with the TMDb ID the server lists.
    struct Entry: Sendable {
        let item: BrowseItem
        let tmdbId: String?
    }

    enum Failure: Error {
        case open(String)
        case statement(String)
    }

    let url: URL
    private let lock = NSLock()
    private var connection: OpaquePointer?
    private var statements: [String: OpaquePointer] = [:]
    /// Used only while holding the lock.
    private let decoder = JSONDecoder()

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    /// Opens the file at `url`, creating it and its tables when `writable`.
    init(url: URL, writable: Bool) throws {
        self.url = url
        var handle: OpaquePointer?
        let flags = writable
            ? SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
            : SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &handle, flags, nil) == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close(handle)
            throw Failure.open(message)
        }
        connection = handle
        sqlite3_busy_timeout(handle, 5_000)
        do {
            // A small page cache: the point is that memory doesn't grow with
            // the library. The default rollback journal keeps a file whose
            // write was cut short readable, which a resumed read relies on.
            try execute("PRAGMA cache_size = -1024")
            if writable {
                try execute("PRAGMA synchronous = NORMAL")
                try execute("""
                    CREATE TABLE IF NOT EXISTS meta (name TEXT PRIMARY KEY, value TEXT NOT NULL);
                    CREATE TABLE IF NOT EXISTS titles (
                        id INTEGER PRIMARY KEY,
                        content_id TEXT NOT NULL UNIQUE,
                        media TEXT NOT NULL,
                        type TEXT NOT NULL,
                        title TEXT NOT NULL,
                        year INTEGER,
                        tmdb_id TEXT
                    );
                    CREATE TABLE IF NOT EXISTS blobs (id INTEGER PRIMARY KEY, item BLOB NOT NULL);
                    CREATE TABLE IF NOT EXISTS keys (
                        media TEXT NOT NULL, key TEXT NOT NULL, title INTEGER NOT NULL,
                        PRIMARY KEY (media, key)
                    ) WITHOUT ROWID;
                    CREATE TABLE IF NOT EXISTS tags (
                        brand TEXT NOT NULL, title INTEGER NOT NULL,
                        PRIMARY KEY (brand, title)
                    ) WITHOUT ROWID;
                    """)
            }
        } catch {
            close()
            throw error
        }
    }

    deinit { close() }

    func close() {
        lock.lock()
        defer { lock.unlock() }
        for statement in statements.values { sqlite3_finalize(statement) }
        statements = [:]
        sqlite3_close(connection)
        connection = nil
    }

    // MARK: Building

    /// Adds a page of titles and the progress it brings the read to, all or
    /// nothing. A title already added, as when a title added on the server
    /// shifts a later page, is skipped. Keys go to the first title that
    /// claims them, by TMDb ID and by title and year, and the brands the
    /// server tags a title with are recorded with it.
    func add(_ entries: [Entry], media: Media, progress: Progress) throws {
        // Encoding and tag matching don't need the file, so they run before
        // taking the lock, and a read of movies and series side by side
        // only waits for the writes.
        let encoder = JSONEncoder()
        let rows: [(entry: Entry, blob: Data, brands: [String], expiry: Date?)] = try entries.map { entry in
            let item = entry.item
            return (entry, try encoder.encode(item), StudiosNetworksStore.tagMatcher.brandIDs(for: item),
                    item.posterUrl.flatMap(SiloAPICompatibility.artworkExpiry))
        }
        try locked {
            try execute("BEGIN IMMEDIATE")
            do {
                var earliest = metaValue("posterExpiry").flatMap(Double.init)
                for row in rows {
                    let item = row.entry.item
                    // The details live in their own table, so reading every
                    // title's name for Search never reads them.
                    let insert = try statement("""
                        INSERT OR IGNORE INTO titles (content_id, media, type, title, year, tmdb_id)
                        VALUES (?, ?, ?, ?, ?, ?)
                        """)
                    bind(insert, 1, item.contentId)
                    bind(insert, 2, media.rawValue)
                    bind(insert, 3, item.type)
                    bind(insert, 4, item.title)
                    bind(insert, 5, item.year)
                    bind(insert, 6, row.entry.tmdbId.flatMap { $0.isEmpty ? nil : $0 })
                    try step(insert)
                    guard sqlite3_changes(connection) > 0 else { continue }
                    let id = sqlite3_last_insert_rowid(connection)
                    let details = try statement("INSERT INTO blobs (id, item) VALUES (?, ?)")
                    sqlite3_bind_int64(details, 1, id)
                    bind(details, 2, row.blob)
                    try step(details)
                    if let expiry = row.expiry?.timeIntervalSince1970 { earliest = min(earliest ?? expiry, expiry) }
                    if let tmdbId = row.entry.tmdbId, !tmdbId.isEmpty { try addKey(tmdbId, media: media, title: id) }
                    // Servers that leave provider IDs out of lists still match here.
                    if let year = item.year { try addKey(StudiosNetworksStore.titleKey(item.title, year: year), media: media, title: id) }
                    for brand in row.brands {
                        let tag = try statement("INSERT OR IGNORE INTO tags (brand, title) VALUES (?, ?)")
                        bind(tag, 1, brand)
                        sqlite3_bind_int64(tag, 2, id)
                        try step(tag)
                    }
                }
                // The earliest signed poster link, kept as titles are added so
                // checking it never reads the whole library.
                if let earliest { try setMeta("posterExpiry", String(earliest)) }
                try setMeta("progress.\(media.rawValue)", "\(progress.offset)|\(progress.isDone ? 1 : 0)")
                try execute("COMMIT")
            } catch {
                try? execute("ROLLBACK")
                throw error
            }
        }
    }

    private func addKey(_ key: String, media: Media, title: Int64) throws {
        let insert = try statement("INSERT OR IGNORE INTO keys (media, key, title) VALUES (?, ?, ?)")
        bind(insert, 1, media.rawValue)
        bind(insert, 2, key)
        sqlite3_bind_int64(insert, 3, title)
        try step(insert)
    }

    func progress(_ media: Media) -> Progress? {
        guard let value = meta("progress.\(media.rawValue)") else { return nil }
        let parts = value.split(separator: "|")
        guard parts.count == 2, let offset = Int(parts[0]) else { return nil }
        return Progress(offset: offset, isDone: parts[1] == "1")
    }

    func meta(_ name: String) -> String? {
        (try? locked { metaValue(name) }) ?? nil
    }

    private func metaValue(_ name: String) -> String? {
        guard let query = try? statement("SELECT value FROM meta WHERE name = ?") else { return nil }
        bind(query, 1, name)
        defer { sqlite3_reset(query) }
        return sqlite3_step(query) == SQLITE_ROW ? text(query, 0) : nil
    }

    func setMeta(_ name: String, value: String) throws {
        try locked { try setMeta(name, value) }
    }

    private func setMeta(_ name: String, _ value: String) throws {
        let upsert = try statement("INSERT OR REPLACE INTO meta (name, value) VALUES (?, ?)")
        bind(upsert, 1, name)
        bind(upsert, 2, value)
        try step(upsert)
    }

    // MARK: Reading

    /// The title a key belongs to, by TMDb ID or by title and year.
    func item(media: Media, key: String) -> BrowseItem? {
        lookup(media: media, key: key)?.item
    }

    /// The title a key belongs to, with the TMDb ID the server listed for it.
    func lookup(media: Media, key: String) -> (item: BrowseItem, tmdbId: String?)? {
        try? locked {
            let query = try statement("""
                SELECT b.item, t.tmdb_id FROM keys k JOIN titles t ON t.id = k.title JOIN blobs b ON b.id = t.id
                WHERE k.media = ? AND k.key = ?
                """)
            bind(query, 1, media.rawValue)
            bind(query, 2, key)
            defer { sqlite3_reset(query) }
            guard sqlite3_step(query) == SQLITE_ROW, let item = decodeItem(query, 0) else { return nil }
            return (item, text(query, 1))
        }
    }

    /// The titles with these content IDs, in the order given. IDs no longer
    /// in the library are left out.
    func items(contentIds: [String]) -> [BrowseItem] {
        guard !contentIds.isEmpty else { return [] }
        var found: [String: BrowseItem] = [:]
        found.reserveCapacity(contentIds.count)
        // SQLite caps how many values one statement binds, so a long list is
        // read in chunks, decoded together as one JSON array.
        for start in stride(from: 0, to: contentIds.count, by: 500) {
            let chunk = Array(contentIds[start..<min(start + 500, contentIds.count)])
            let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            let blobs: [Data] = (try? locked {
                // Prepared afresh, as the placeholder count varies.
                var query: OpaquePointer?
                let sql = "SELECT b.item FROM titles t JOIN blobs b ON b.id = t.id WHERE t.content_id IN (\(placeholders))"
                guard sqlite3_prepare_v2(connection, sql, -1, &query, nil) == SQLITE_OK, let query else {
                    throw Failure.statement(sql)
                }
                defer { sqlite3_finalize(query) }
                for (index, id) in chunk.enumerated() { bind(query, Int32(index + 1), id) }
                var blobs: [Data] = []
                while sqlite3_step(query) == SQLITE_ROW {
                    if let blob = blob(query, 0) { blobs.append(blob) }
                }
                return blobs
            }) ?? []
            for item in decodeItems(blobs) { found[item.contentId] = item }
        }
        return contentIds.compactMap { found[$0] }
    }

    /// The content IDs of every title the server tags with `brand`, movies
    /// then series, each in title order.
    func taggedIDs(brand: String) -> [String] {
        (try? locked {
            let query = try statement("""
                SELECT t.content_id FROM tags g JOIN titles t ON t.id = g.title
                WHERE g.brand = ? ORDER BY t.media = 'series', t.id
                """)
            bind(query, 1, brand)
            defer { sqlite3_reset(query) }
            var ids: [String] = []
            while sqlite3_step(query) == SQLITE_ROW {
                if let id = text(query, 0) { ids.append(id) }
            }
            return ids
        }) ?? []
    }

    /// Every title, with only what Search ranks by.
    func searchTitles() -> [SearchTitle] {
        (try? locked {
            let query = try statement("SELECT content_id, type, title, year FROM titles ORDER BY id")
            defer { sqlite3_reset(query) }
            var titles: [SearchTitle] = []
            titles.reserveCapacity(Int(count(in: "titles")))
            while sqlite3_step(query) == SQLITE_ROW {
                guard let id = text(query, 0), let type = text(query, 1), let title = text(query, 2) else { continue }
                let year = sqlite3_column_type(query, 3) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(query, 3))
                titles.append(SearchTitle(contentId: id, type: type, title: title, year: year))
            }
            return titles
        }) ?? []
    }

    /// When the first signed poster link in the library stops working, or
    /// nil when none carries an expiry, as with Emby and Jellyfin.
    func earliestPosterExpiry() -> Date? {
        meta("posterExpiry").flatMap(Double.init).map(Date.init(timeIntervalSince1970:))
    }

    var titleCount: Int {
        (try? locked { Int(count(in: "titles")) }) ?? 0
    }

    // MARK: SQLite

    private func locked<T>(_ body: () throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        guard connection != nil else { throw Failure.open("closed") }
        return try body()
    }

    private func execute(_ sql: String) throws {
        guard sqlite3_exec(connection, sql, nil, nil, nil) == SQLITE_OK else {
            throw Failure.statement(String(cString: sqlite3_errmsg(connection)))
        }
    }

    /// A cached prepared statement, reset and cleared for reuse.
    private func statement(_ sql: String) throws -> OpaquePointer {
        if let cached = statements[sql] {
            sqlite3_reset(cached)
            sqlite3_clear_bindings(cached)
            return cached
        }
        var prepared: OpaquePointer?
        guard sqlite3_prepare_v2(connection, sql, -1, &prepared, nil) == SQLITE_OK, let prepared else {
            throw Failure.statement(String(cString: sqlite3_errmsg(connection)))
        }
        statements[sql] = prepared
        return prepared
    }

    private func step(_ statement: OpaquePointer) throws {
        defer { sqlite3_reset(statement) }
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw Failure.statement(String(cString: sqlite3_errmsg(connection)))
        }
    }

    private func count(in table: String) -> Int64 {
        var query: OpaquePointer?
        guard sqlite3_prepare_v2(connection, "SELECT count(*) FROM \(table)", -1, &query, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(query) }
        return sqlite3_step(query) == SQLITE_ROW ? sqlite3_column_int64(query, 0) : 0
    }

    private func bind(_ statement: OpaquePointer, _ index: Int32, _ value: String?) {
        guard let value else { sqlite3_bind_null(statement, index); return }
        sqlite3_bind_text(statement, index, value, -1, Self.transient)
    }

    private func bind(_ statement: OpaquePointer, _ index: Int32, _ value: Int?) {
        guard let value else { sqlite3_bind_null(statement, index); return }
        sqlite3_bind_int64(statement, index, Int64(value))
    }

    private func bind(_ statement: OpaquePointer, _ index: Int32, _ value: Double?) {
        guard let value else { sqlite3_bind_null(statement, index); return }
        sqlite3_bind_double(statement, index, value)
    }

    private func bind(_ statement: OpaquePointer, _ index: Int32, _ value: Data) {
        _ = value.withUnsafeBytes { bytes in
            sqlite3_bind_blob(statement, index, bytes.baseAddress, Int32(bytes.count), Self.transient)
        }
    }

    private func text(_ statement: OpaquePointer, _ column: Int32) -> String? {
        guard let pointer = sqlite3_column_text(statement, column) else { return nil }
        return String(cString: pointer)
    }

    private func blob(_ statement: OpaquePointer, _ column: Int32) -> Data? {
        guard let pointer = sqlite3_column_blob(statement, column) else { return nil }
        return Data(bytes: pointer, count: Int(sqlite3_column_bytes(statement, column)))
    }

    private func decodeItem(_ statement: OpaquePointer, _ column: Int32) -> BrowseItem? {
        blob(statement, column).flatMap { try? decoder.decode(BrowseItem.self, from: $0) }
    }

    /// Decodes saved titles as one JSON array, which is much quicker than one
    /// decode each.
    private func decodeItems(_ blobs: [Data]) -> [BrowseItem] {
        guard !blobs.isEmpty else { return [] }
        var joined = Data("[".utf8)
        joined.reserveCapacity(blobs.reduce(2) { $0 + $1.count + 1 })
        for (index, blob) in blobs.enumerated() {
            if index > 0 { joined.append(UInt8(ascii: ",")) }
            joined.append(blob)
        }
        joined.append(UInt8(ascii: "]"))
        let decoder = JSONDecoder()
        if let items = try? decoder.decode([BrowseItem].self, from: joined) { return items }
        // One that won't decode shouldn't take the rest with it.
        return blobs.compactMap { try? decoder.decode(BrowseItem.self, from: $0) }
    }
}
