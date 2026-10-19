import Foundation
import SQLite3

/// Suchindex (SQLite) in der Mediathek. Nur zum schnellen Laden und Suchen: Die Wahrheit sind
/// die Begleitdateien, der Index lässt sich jederzeit daraus neu bauen.
final class ArchiveIndex {
    static let schemaVersion = 1

    struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ s: String) { errorDescription = s }
    }

    private var db: OpaquePointer?
    let url: URL
    let readOnly: Bool

    private static let TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(url: URL, readOnly: Bool = false) throws {
        self.url = url
        self.readOnly = readOnly
        let flags = readOnly ? SQLITE_OPEN_READONLY : (SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
        guard sqlite3_open_v2(url.path, &db, flags | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "?"
            sqlite3_close(db)
            db = nil
            throw Failure("Index lässt sich nicht öffnen: \(msg)")
        }
        sqlite3_busy_timeout(db, 5000)
        if !readOnly {
            // Externe Platten (auch exFAT): klassisches Journal statt WAL
            try exec("PRAGMA journal_mode=DELETE")
            try exec("PRAGMA synchronous=FULL")
        }
    }

    deinit { sqlite3_close(db) }

    // MARK: Grundlagen

    func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? "?"
            sqlite3_free(err)
            throw Failure("Index: \(msg)")
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer? {
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else {
            throw Failure("Index: \(String(cString: sqlite3_errmsg(db)))")
        }
        return st
    }

    private func bind(_ st: OpaquePointer?, _ values: [Any?]) {
        for (i, v) in values.enumerated() {
            let idx = Int32(i + 1)
            switch v {
            case nil: sqlite3_bind_null(st, idx)
            case let s as String: sqlite3_bind_text(st, idx, s, -1, Self.TRANSIENT)
            case let n as Int: sqlite3_bind_int64(st, idx, Int64(n))
            case let n as Int64: sqlite3_bind_int64(st, idx, n)
            case let d as Double: sqlite3_bind_double(st, idx, d)
            default: sqlite3_bind_null(st, idx)
            }
        }
    }

    private func run(_ sql: String, _ values: [Any?] = []) throws {
        let st = try prepare(sql)
        defer { sqlite3_finalize(st) }
        bind(st, values)
        guard sqlite3_step(st) == SQLITE_DONE else { throw Failure("Index: \(String(cString: sqlite3_errmsg(db)))") }
    }

    private func column(_ st: OpaquePointer?, _ i: Int32) -> String? {
        guard let c = sqlite3_column_text(st, i) else { return nil }
        return String(cString: c)
    }

    func transaction(_ body: () throws -> Void) throws {
        try exec("BEGIN IMMEDIATE")
        do {
            try body()
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    // MARK: Schema

    func createSchema(libraryID: String) throws {
        try exec("""
        CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT);
        CREATE TABLE IF NOT EXISTS videos(
            id TEXT PRIMARY KEY, rel_path TEXT NOT NULL, sha256 TEXT, size INTEGER,
            created REAL, imported REAL, kind TEXT, format TEXT, project TEXT, json TEXT NOT NULL);
        CREATE INDEX IF NOT EXISTS videos_sha ON videos(sha256);
        CREATE INDEX IF NOT EXISTS videos_created ON videos(created);
        CREATE TABLE IF NOT EXISTS video_song(video TEXT, song TEXT);
        CREATE TABLE IF NOT EXISTS video_mood(video TEXT, mood TEXT);
        CREATE TABLE IF NOT EXISTS video_tag(video TEXT, tag TEXT);
        CREATE INDEX IF NOT EXISTS vs_v ON video_song(video);
        CREATE INDEX IF NOT EXISTS vm_v ON video_mood(video);
        CREATE INDEX IF NOT EXISTS vt_v ON video_tag(video);
        """)
        try setMeta("schema", String(Self.schemaVersion))
        try setMeta("library", libraryID)
    }

    func setMeta(_ key: String, _ value: String) throws {
        try run("INSERT OR REPLACE INTO meta(key, value) VALUES(?, ?)", [key, value])
    }

    func meta(_ key: String) -> String? {
        guard let st = try? prepare("SELECT value FROM meta WHERE key = ?") else { return nil }
        defer { sqlite3_finalize(st) }
        bind(st, [key])
        return sqlite3_step(st) == SQLITE_ROW ? column(st, 0) : nil
    }

    var schema: Int { meta("schema").flatMap(Int.init) ?? 0 }

    /// Schnelle Prüfung, ob die Datei ein brauchbarer Index ist.
    func isHealthy() -> Bool {
        guard let st = try? prepare("PRAGMA quick_check") else { return false }
        defer { sqlite3_finalize(st) }
        return sqlite3_step(st) == SQLITE_ROW && column(st, 0) == "ok"
    }

    // MARK: Datensätze

    func upsert(_ r: VideoRecord) throws {
        let json = String(decoding: try Sidecar.encoder.encode(r), as: UTF8.self)
        try run("""
            INSERT OR REPLACE INTO videos(id, rel_path, sha256, size, created, imported, kind, format, project, json)
            VALUES(?,?,?,?,?,?,?,?,?,?)
            """, [r.id, r.relPath, r.sha256, r.size, r.createdAt.timeIntervalSince1970, r.importedAt.timeIntervalSince1970,
                  r.kind.id, r.format.id, r.project?.id, json])
        try run("DELETE FROM video_song WHERE video = ?", [r.id])
        try run("DELETE FROM video_mood WHERE video = ?", [r.id])
        try run("DELETE FROM video_tag WHERE video = ?", [r.id])
        for s in r.songs { try run("INSERT INTO video_song(video, song) VALUES(?, ?)", [r.id, s.id]) }
        for m in r.moods { try run("INSERT INTO video_mood(video, mood) VALUES(?, ?)", [r.id, m.id]) }
        for t in r.tags { try run("INSERT INTO video_tag(video, tag) VALUES(?, ?)", [r.id, t]) }
    }

    func delete(id: String) throws {
        for t in ["videos"] { try run("DELETE FROM \(t) WHERE id = ?", [id]) }
        for t in ["video_song", "video_mood", "video_tag"] { try run("DELETE FROM \(t) WHERE video = ?", [id]) }
    }

    func removeAll() throws {
        try exec("DELETE FROM videos; DELETE FROM video_song; DELETE FROM video_mood; DELETE FROM video_tag;")
    }

    func all() throws -> [VideoRecord] {
        let st = try prepare("SELECT rel_path, json FROM videos ORDER BY created DESC")
        defer { sqlite3_finalize(st) }
        var out: [VideoRecord] = []
        while sqlite3_step(st) == SQLITE_ROW {
            guard let path = column(st, 0), let json = column(st, 1),
                  var r = try? Sidecar.decoder.decode(VideoRecord.self, from: Data(json.utf8)) else { continue }
            r.relPath = path
            out.append(r)
        }
        return out
    }

    func find(sha256: String) -> String? {
        guard let st = try? prepare("SELECT id FROM videos WHERE sha256 = ? LIMIT 1") else { return nil }
        defer { sqlite3_finalize(st) }
        bind(st, [sha256])
        return sqlite3_step(st) == SQLITE_ROW ? column(st, 0) : nil
    }

    var count: Int {
        guard let st = try? prepare("SELECT COUNT(*) FROM videos") else { return 0 }
        defer { sqlite3_finalize(st) }
        return sqlite3_step(st) == SQLITE_ROW ? Int(sqlite3_column_int64(st, 0)) : 0
    }
}
