import Foundation
import SQLite3

// The SQLite file is the source of truth. The published archive dictionary in
// NewsFeed is only a small, backwards-compatible cache for the reading UI.
final class ArchiveStore {
    private var db: OpaquePointer?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let url: URL
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    enum StoreError: LocalizedError {
        case database(String)
        var errorDescription: String? {
            switch self { case .database(let detail): return "Archive database: \(detail)" }
        }
    }

    init(url: URL) throws {
        self.url = url
        let result = sqlite3_open_v2(url.path, &db, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil)
        guard result == SQLITE_OK else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "Unable to open"
            if db != nil { sqlite3_close(db) }
            db = nil
            throw StoreError.database(message)
        }
        do {
            try execute("PRAGMA journal_mode=WAL")
            try execute("PRAGMA busy_timeout=3000")
            try execute("CREATE TABLE IF NOT EXISTS stories (id TEXT PRIMARY KEY, published REAL NOT NULL, source TEXT NOT NULL, title TEXT NOT NULL, summary TEXT NOT NULL, payload BLOB NOT NULL)")
            // Non-destructive migration of archives created before full-text
            // saving. The JSON payload stays compatible with old backups.
            try? execute("ALTER TABLE stories ADD COLUMN has_text INTEGER NOT NULL DEFAULT 0")
            try? execute("ALTER TABLE stories ADD COLUMN checked_at REAL NOT NULL DEFAULT 0")
            try execute("CREATE INDEX IF NOT EXISTS stories_recent ON stories(published DESC)")
            try execute("CREATE INDEX IF NOT EXISTS stories_source ON stories(source, published DESC)")
            try execute("CREATE INDEX IF NOT EXISTS stories_missing_text ON stories(has_text, checked_at, published DESC)")
            try repairUnreliableFullTexts()
        } catch {
            sqlite3_close(db); db = nil
            throw error
        }
    }

    deinit { if let db { sqlite3_close(db) } }

    private func checked(_ rc: Int32) throws {
        guard rc == SQLITE_OK || rc == SQLITE_DONE || rc == SQLITE_ROW else {
            throw StoreError.database(db.map { String(cString: sqlite3_errmsg($0)) } ?? "Unknown error")
        }
    }

    private func execute(_ sql: String) throws {
        try checked(sqlite3_exec(db, sql, nil, nil, nil))
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        try checked(sqlite3_prepare_v2(db, sql, -1, &statement, nil))
        guard let statement else { throw StoreError.database("Could not prepare query") }
        return statement
    }

    private func bind(_ string: String, at column: Int32, to statement: OpaquePointer) throws {
        try string.withCString { try checked(sqlite3_bind_text(statement, column, $0, -1, transient)) }
    }

    private func bind(_ data: Data, at column: Int32, to statement: OpaquePointer) throws {
        try data.withUnsafeBytes {
            try checked(sqlite3_bind_blob(statement, column, $0.baseAddress, Int32(data.count), transient))
        }
    }

    private func rows(_ sql: String, configure: ((OpaquePointer) throws -> Void)? = nil) throws -> [NewsItem] {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try configure?(statement)
        var result: [NewsItem] = []
        var step = sqlite3_step(statement)
        while step == SQLITE_ROW {
            if let bytes = sqlite3_column_blob(statement, 0) {
                let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0)))
                if let item = try? decoder.decode(NewsItem.self, from: data) { result.append(item) }
            }
            step = sqlite3_step(statement)
        }
        try checked(step)
        return result
    }

    var count: Int {
        guard let statement = try? prepare("SELECT COUNT(*) FROM stories") else { return 0 }
        defer { sqlite3_finalize(statement) }
        return sqlite3_step(statement) == SQLITE_ROW ? Int(sqlite3_column_int64(statement, 0)) : 0
    }

    var fullTextCount: Int {
        guard let stmt = try? prepare("SELECT COUNT(*) FROM stories WHERE has_text = 1") else { return 0 }
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int64(stmt, 0)) : 0
    }

    func missingText(limit: Int) throws -> [NewsItem] {
        let deadline = Date().addingTimeInterval(-30 * 86_400).timeIntervalSince1970
        return try rows("SELECT payload FROM stories WHERE has_text = 0 AND checked_at < ? ORDER BY checked_at ASC, published DESC LIMIT ?") { stmt in
            try self.checked(sqlite3_bind_double(stmt, 1, deadline))
            try self.checked(sqlite3_bind_int(stmt, 2, Int32(limit)))
        }
    }

    var byteSize: Int64 {
        let paths = [url.path, url.path + "-wal", url.path + "-shm"]
        return paths.reduce(0) { size, path in
            let attributes = try? FileManager.default.attributesOfItem(atPath: path)
            return size + ((attributes?[.size] as? NSNumber)?.int64Value ?? 0)
        }
    }

    func all() throws -> [NewsItem] {
        try rows("SELECT payload FROM stories ORDER BY published DESC")
    }

    func latest(limit: Int) throws -> [NewsItem] {
        try rows("SELECT payload FROM stories ORDER BY published DESC LIMIT ?") {
            try self.checked(sqlite3_bind_int($0, 1, Int32(limit)))
        }
    }

    func search(_ query: String) throws -> [NewsItem] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return try all() }
        // SQLite's default LIKE is case-insensitive for ASCII only. Keep
        // Serbian diacritics searchable without an extra Unicode extension.
        if text.unicodeScalars.contains(where: { $0.value > 127 }) {
            return try all().filter {
                $0.title.localizedCaseInsensitiveContains(text) ||
                $0.summary.localizedCaseInsensitiveContains(text) ||
                $0.sourceName.localizedCaseInsensitiveContains(text)
            }
        }
        let escaped = text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
        return try rows("SELECT payload FROM stories WHERE title LIKE ? ESCAPE '\\' OR summary LIKE ? ESCAPE '\\' OR source LIKE ? ESCAPE '\\' ORDER BY published DESC") { stmt in
            let pattern = "%" + escaped + "%"
            for col in 1...3 { try self.bind(pattern, at: Int32(col), to: stmt) }
        }
    }

    func article(id: String) throws -> NewsItem? {
        try rows("SELECT payload FROM stories WHERE id = ?") { try self.bind(id, at: 1, to: $0) }.first
    }

    // SITO 0.9.0/0.9.1 mistakenly treated 150-character RSS teasers as full
    // articles. Repair them on opening the existing database, in a single
    // transaction. The snippets move to previewText; no article is deleted.
    // This is idempotent and also covers archives restored from older backups.
    private func repairUnreliableFullTexts() throws {
        let mislabeled = try all().filter { $0.fullText != nil && !$0.hasFullText }
        guard !mislabeled.isEmpty else { return }
        try execute("BEGIN IMMEDIATE TRANSACTION")
        do {
            let stmt = try prepare("UPDATE stories SET payload = ?, has_text = 0, checked_at = 0 WHERE id = ?")
            defer { sqlite3_finalize(stmt) }
            for item in mislabeled {
                let repaired = item.cleanedForArchive()
                sqlite3_reset(stmt); sqlite3_clear_bindings(stmt)
                try bind(encoder.encode(repaired), at: 1, to: stmt)
                try bind(item.id, at: 2, to: stmt)
                try checked(sqlite3_step(stmt))
            }
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    func sourceNames() throws -> [String] {
        let stmt = try prepare("SELECT DISTINCT source FROM stories ORDER BY source COLLATE NOCASE")
        defer { sqlite3_finalize(stmt) }
        var names: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let ptr = sqlite3_column_text(stmt, 0) {
                names.append(String(decoding: UnsafeBufferPointer(start: ptr,
                    count: Int(sqlite3_column_bytes(stmt, 0))), as: UTF8.self))
            }
        }
        return names
    }

    func insert(_ articles: [NewsItem]) throws {
        guard !articles.isEmpty else { return }
        try execute("BEGIN IMMEDIATE TRANSACTION")
        do {
            let stmt = try prepare("INSERT OR REPLACE INTO stories (id,published,source,title,summary,payload,has_text,checked_at) VALUES (?,?,?,?,?,?,?,?)")
            defer { sqlite3_finalize(stmt) }
            let previous = try prepare("SELECT payload FROM stories WHERE id = ?")
            defer { sqlite3_finalize(previous) }
            for item in articles {
                sqlite3_reset(previous); sqlite3_clear_bindings(previous)
                try bind(item.id, at: 1, to: previous)
                var merged = item.cleanedForArchive()
                let previousStep = sqlite3_step(previous)
                try checked(previousStep)
                if previousStep == SQLITE_ROW,
                   let bytes = sqlite3_column_blob(previous, 0),
                   let old = try? decoder.decode(NewsItem.self, from: Data(bytes: bytes,
                                                    count: Int(sqlite3_column_bytes(previous, 0)))) {
                    merged = merged.merging(older: old)
                }
                sqlite3_reset(stmt); sqlite3_clear_bindings(stmt)
                try bind(merged.id, at: 1, to: stmt)
                try checked(sqlite3_bind_double(stmt, 2, merged.published.timeIntervalSince1970))
                try bind(merged.sourceName, at: 3, to: stmt)
                try bind(merged.title, at: 4, to: stmt)
                try bind(merged.summary, at: 5, to: stmt)
                try bind(encoder.encode(merged), at: 6, to: stmt)
                try checked(sqlite3_bind_int(stmt, 7, merged.hasFullText ? 1 : 0))
                try checked(sqlite3_bind_double(stmt, 8, merged.textCheckedAt?.timeIntervalSince1970 ?? 0))
                try checked(sqlite3_step(stmt))
            }
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    // A deliberate cleanup never touches bookmarks or an article with a saved PDF.
    // Those IDs are supplied by NewsFeed, so callers cannot accidentally lose them.
    private func eligibleIDs(olderThan cutoff: Date?, sourceName: String?, protecting protected: Set<String>) throws -> [String] {
        let filters = [cutoff == nil ? nil : "published < ?", sourceName == nil ? nil : "source = ?"].compactMap { $0 }
        let sql = "SELECT id FROM stories" + (filters.isEmpty ? "" : " WHERE " + filters.joined(separator: " AND "))
        let lookup = try prepare(sql)
        defer { sqlite3_finalize(lookup) }
        var column: Int32 = 1
        if let cutoff {
            try checked(sqlite3_bind_double(lookup, column, cutoff.timeIntervalSince1970))
            column += 1
        }
        if let sourceName { try bind(sourceName, at: column, to: lookup) }
        var unwanted: [String] = []
        while sqlite3_step(lookup) == SQLITE_ROW {
            if let ptr = sqlite3_column_text(lookup, 0) {
                let id = String(decoding: UnsafeBufferPointer(start: ptr,
                    count: Int(sqlite3_column_bytes(lookup, 0))), as: UTF8.self)
                if !protected.contains(id) { unwanted.append(id) }
            }
        }
        return unwanted
    }

    func eligibleCount(olderThan cutoff: Date?, sourceName: String?, protecting protected: Set<String>) throws -> Int {
        try eligibleIDs(olderThan: cutoff, sourceName: sourceName, protecting: protected).count
    }

    func prune(olderThan cutoff: Date?, sourceName: String?, protecting protected: Set<String>) throws -> Int {
        let unwanted = try eligibleIDs(olderThan: cutoff, sourceName: sourceName, protecting: protected)
        guard !unwanted.isEmpty else { return 0 }
        try execute("BEGIN IMMEDIATE TRANSACTION")
        do {
            let stmt = try prepare("DELETE FROM stories WHERE id = ?")
            defer { sqlite3_finalize(stmt) }
            for id in unwanted {
                sqlite3_reset(stmt); sqlite3_clear_bindings(stmt)
                try bind(id, at: 1, to: stmt)
                try checked(sqlite3_step(stmt))
            }
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
        // Reclaim disk pages now, instead of making users wait for SQLite to
        // reuse them at a future date. Maintenance is only done on manual cleanup.
        try? execute("PRAGMA wal_checkpoint(TRUNCATE)")
        try? execute("VACUUM")
        return unwanted.count
    }
}
