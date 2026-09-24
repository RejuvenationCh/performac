// Core/Database.swift — SQLite3 wrapper: v1's schema verbatim (db.js), WAL,
// retention sweep, settings helpers. SQLite3 is the system C library.
import SQLite3
import Foundation

enum SQLValue: Equatable, Sendable {
    case int(Int64)
    case real(Double)
    case text(String)
    case null

    var intVal: Int64 {
        switch self { case .int(let v): return v; case .real(let v): return Int64(v); default: return 0 }
    }
    var realVal: Double {
        switch self { case .real(let v): return v; case .int(let v): return Double(v); default: return 0 }
    }
    var stringVal: String {
        switch self { case .text(let v): return v; default: return "" }
    }
    var isNull: Bool { self == .null }
    var doubleVal: Double {
        switch self {
        case .real(let v): v
        case .int(let v): Double(v)
        case .text(let t): Double(t) ?? 0
        case .null: 0
        }
    }
}

typealias DBRow = [String: SQLValue]

let SCHEMA = """
CREATE TABLE IF NOT EXISTS proc_samples(
  ts INTEGER NOT NULL, pid INTEGER NOT NULL, name TEXT NOT NULL,
  cpu REAL NOT NULL, rss_mb INTEGER NOT NULL);
CREATE INDEX IF NOT EXISTS idx_proc_ts ON proc_samples(ts);
CREATE INDEX IF NOT EXISTS idx_proc_name ON proc_samples(name, ts);
CREATE TABLE IF NOT EXISTS disk_samples(
  ts INTEGER NOT NULL, volume TEXT NOT NULL, free_gb REAL NOT NULL, total_gb REAL NOT NULL);
CREATE INDEX IF NOT EXISTS idx_disk ON disk_samples(volume, ts);
CREATE TABLE IF NOT EXISTS cache_samples(
  ts INTEGER NOT NULL, cache_id TEXT NOT NULL, path TEXT NOT NULL,
  size_mb INTEGER NOT NULL, newest_mtime INTEGER, file_count INTEGER NOT NULL);
CREATE INDEX IF NOT EXISTS idx_cache ON cache_samples(cache_id, ts);
CREATE TABLE IF NOT EXISTS events(
  ts INTEGER NOT NULL, kind TEXT NOT NULL, key TEXT NOT NULL, detail TEXT NOT NULL DEFAULT '');
CREATE INDEX IF NOT EXISTS idx_events ON events(kind, ts);
CREATE TABLE IF NOT EXISTS findings(
  id TEXT PRIMARY KEY, kind TEXT NOT NULL,
  severity TEXT NOT NULL CHECK(severity IN ('info','amber','red')),
  headline TEXT NOT NULL, why TEXT NOT NULL, detail TEXT NOT NULL DEFAULT '',
  link_kind TEXT, link_target TEXT,
  first_seen INTEGER NOT NULL, updated INTEGER NOT NULL, last_notified INTEGER);
CREATE TABLE IF NOT EXISTS dup_groups(
  scan_ts INTEGER NOT NULL, hash TEXT NOT NULL, size_mb INTEGER NOT NULL, paths TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS settings(key TEXT PRIMARY KEY, value TEXT NOT NULL);
-- Everything the app has ever moved to the Trash. Append-only: "what happened to that
-- folder" must always have an answer.
CREATE TABLE IF NOT EXISTS trash_log(
  ts INTEGER NOT NULL, path TEXT NOT NULL, ok INTEGER NOT NULL, detail TEXT NOT NULL DEFAULT '');
CREATE INDEX IF NOT EXISTS idx_trash_ts ON trash_log(ts);
-- Die temperature, sampled with the 30s tick. Kept as its own table rather than an event
-- because it is a continuous series, not an occurrence.
CREATE TABLE IF NOT EXISTS temp_samples(ts INTEGER NOT NULL, celsius REAL NOT NULL);
CREATE INDEX IF NOT EXISTS idx_temp_ts ON temp_samples(ts);
-- The last disk scan's tree. Kept in a table rather than a settings blob so browsing a
-- stale scan is the same indexed lookup as browsing a fresh one — one code path, and a
-- ~100k-node home directory never has to be held in memory or re-parsed as JSON.
CREATE TABLE IF NOT EXISTS scan_entries(
  parent TEXT NOT NULL, name TEXT NOT NULL, items INTEGER NOT NULL,
  bytes INTEGER NOT NULL, is_dir INTEGER NOT NULL, mtime INTEGER NOT NULL DEFAULT 0);
CREATE INDEX IF NOT EXISTS idx_scan_parent ON scan_entries(parent);
"""

final class DB: @unchecked Sendable {
    let handle: OpaquePointer
    /// One connection is shared by the sampler (utility pool) and the store (main actor).
    /// SQLite serializes individual API calls, but a prepare/finalize interleaving across
    /// threads aborts with SQLITE_MISUSE — so all statement work holds this lock.
    let lock = NSLock()

    /// `readOnly` opens a second connection for the UI.
    ///
    /// Every statement on a connection holds one lock, so a UI read on the same connection
    /// blocks behind whatever the sampler is doing — a cache walk, a drift walk, an 87k-row
    /// insert. That is what made expanding a folder take seconds: not the query (0.1 ms) but
    /// waiting for the lock. WAL allows concurrent readers alongside one writer, so the UI
    /// gets its own handle and never waits on a background write.
    init(path: String, readOnly: Bool = false) {
        var h: OpaquePointer?
        let flags = readOnly ? SQLITE_OPEN_READONLY : (SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
        guard sqlite3_open_v2(path, &h, flags, nil) == SQLITE_OK, let h else {
            fatalError("cannot open sqlite db at \(path)")
        }
        handle = h
        if readOnly {
            // a reader must never block on a writer's transaction
            sqlite3_busy_timeout(handle, 2000)
        } else {
            sqlite3_exec(handle, "PRAGMA journal_mode = WAL;", nil, nil, nil)
            sqlite3_exec(handle, SCHEMA, nil, nil, nil)
            migrate()
        }
    }

    /// CREATE TABLE IF NOT EXISTS never alters an existing table, so a column added to
    /// SCHEMA is simply absent on any database that already existed. Adding mtime to
    /// scan_entries that way crashed the app on launch. Every future column belongs here.
    ///
    /// ALTER TABLE ADD COLUMN on an existing column is an error, not a no-op, so each is
    /// checked first via table_info.
    private func migrate() {
        let additions: [(table: String, column: String, decl: String)] = [
            ("scan_entries", "mtime", "INTEGER NOT NULL DEFAULT 0"),
            ("scan_entries", "kind", "TEXT NOT NULL DEFAULT ''"),
        ]
        for a in additions {
            var exists = false
            var s: OpaquePointer?
            if sqlite3_prepare_v2(handle, "PRAGMA table_info(\(a.table))", -1, &s, nil) == SQLITE_OK, let s {
                while sqlite3_step(s) == SQLITE_ROW {
                    if let c = sqlite3_column_text(s, 1), String(cString: c) == a.column { exists = true }
                }
                sqlite3_finalize(s)
            }
            if !exists {
                sqlite3_exec(handle, "ALTER TABLE \(a.table) ADD COLUMN \(a.column) \(a.decl)", nil, nil, nil)
            }
        }
    }

    deinit { sqlite3_close(handle) }

    func prepare(_ sql: String) -> Stmt {
        lock.lock()
        defer { lock.unlock() }
        return Stmt(db: self, sql: sql)
    }
}

final class Stmt: @unchecked Sendable {
    /// nil when the statement could not be prepared; every operation then no-ops.
    private let stmt: OpaquePointer?
    private let db: DB    // strong: the connection must outlive every statement

    init(db: DB, sql: String) {
        self.db = db
        var s: OpaquePointer?
        guard sqlite3_prepare_v2(db.handle, sql, -1, &s, nil) == SQLITE_OK, let s else {
            // Was fatalError, which turned any schema drift into a launch crash: adding an
            // mtime column to scan_entries did exactly that, because CREATE TABLE IF NOT
            // EXISTS never alters an existing table. A statement that cannot be prepared is
            // now inert — it reads as empty and writes nothing — so a bad query costs a
            // feature, never the app.
            let msg = String(cString: sqlite3_errmsg(db.handle))
            FileHandle.standardError.write(Data("[db] prepare failed: \(msg) — \(sql)\n".utf8))
            stmt = nil
            return
        }
        stmt = s
    }

    deinit {
        db.lock.lock()
        sqlite3_finalize(stmt)
        db.lock.unlock()
    }

    private func withLock<T>(_ body: () -> T) -> T {
        db.lock.lock()
        defer { db.lock.unlock() }
        return body()
    }

    private func bind(_ args: [SQLValue]) {
        sqlite3_reset(stmt)
        sqlite3_clear_bindings(stmt)
        for (i, a) in args.enumerated() {
            let idx = Int32(i + 1)
            switch a {
            case .int(let v): sqlite3_bind_int64(stmt, idx, v)
            case .real(let v): sqlite3_bind_double(stmt, idx, v)
            case .text(let v): sqlite3_bind_text(stmt, idx, v, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            case .null: sqlite3_bind_null(stmt, idx)
            }
        }
    }

    private func readRow() -> DBRow {
        var out = DBRow()
        for i in 0 ..< sqlite3_column_count(stmt) {
            let name = String(cString: sqlite3_column_name(stmt, i))
            switch sqlite3_column_type(stmt, i) {
            case SQLITE_INTEGER: out[name] = .int(sqlite3_column_int64(stmt, i))
            case SQLITE_FLOAT: out[name] = .real(sqlite3_column_double(stmt, i))
            case SQLITE_TEXT: out[name] = .text(String(cString: sqlite3_column_text(stmt, i)))
            default: out[name] = .null
            }
        }
        return out
    }

    /// execute without reading rows
    func run(_ args: [SQLValue] = []) {
        guard stmt != nil else { return  }
        return withLock {
            bind(args)
            _ = sqlite3_step(stmt)
        }
    }

    func get(_ args: [SQLValue] = []) -> DBRow? {
        guard stmt != nil else { return nil }
        return withLock {
            bind(args)
            guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
            return readRow()
        }
    }

    func all(_ args: [SQLValue] = []) -> [DBRow] {
        guard stmt != nil else { return [] }
        return withLock {
            bind(args)
            var out: [DBRow] = []
            while sqlite3_step(stmt) == SQLITE_ROW { out.append(readRow()) }
            return out
        }
    }
}

// retention deletes; dup_groups keeps the latest scan only — port of db.js sweep
func sweep(_ db: DB, _ cfg: Config, _ now: Int64) {
    let day: Int64 = 86_400_000
    db.prepare("DELETE FROM proc_samples WHERE ts < ?").run([.int(now - Int64(cfg.retentionDays.proc) * day)])
    db.prepare("DELETE FROM disk_samples WHERE ts < ?").run([.int(now - Int64(cfg.retentionDays.disk) * day)])
    db.prepare("DELETE FROM cache_samples WHERE ts < ?").run([.int(now - Int64(cfg.retentionDays.cache) * day)])
    db.prepare("DELETE FROM events WHERE ts < ?").run([.int(now - Int64(cfg.retentionDays.events) * day)])
    db.prepare("DELETE FROM dup_groups WHERE scan_ts < (SELECT MAX(scan_ts) FROM dup_groups)").run()
}

func getSetting(_ db: DB, _ key: String) -> JSONValue? {
    guard let row = db.prepare("SELECT value FROM settings WHERE key = ?").get([.text(key)]),
          let text = row["value"]?.stringVal,
          let data = text.data(using: .utf8),
          let obj = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    else { return nil }
    return JSONValue.from(obj)
}

func setSetting(_ db: DB, _ key: String, _ value: JSONValue) {
    let text = value.jsonString
    db.prepare("INSERT INTO settings(key, value) VALUES(?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value")
        .run([.text(key), .text(text)])
}

func allSettings(_ db: DB) -> [String: JSONValue] {
    var out: [String: JSONValue] = [:]
    for row in db.prepare("SELECT key, value FROM settings").all() {
        guard let key = row["key"]?.stringVal,
              let text = row["value"]?.stringVal,
              let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        else { continue }
        out[key] = JSONValue.from(obj)
    }
    return out
}

extension JSONValue {
    /// JSONValue → JSONSerialization-compatible object (objects/arrays only — used for
    /// re-encoding merged configs where the top level is always an object)
    var jsonObject: Any {
        switch self {
        case .number(let v): return v
        case .bool(let v): return v
        case .string(let v): return v
        case .array(let v): return v.map { $0.jsonObject }
        case .object(let v): return v.mapValues { $0.jsonObject }
        case .null: return NSNull()
        }
    }

    /// Full JSON text. NSJSONSerialization refuses bare numbers/strings as the top-level
    /// object, but v1's settings rows store JSON.stringify(...) of any value — so encode
    /// strings ourselves. Keys are config identifiers (plain ASCII).
    var jsonString: String {
        switch self {
        case .number(let v):
            return String(format: "%.17g", v)
        case .bool(let v):
            return v ? "true" : "false"
        case .string(let v):
            let escaped = v.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            return "\"" + escaped + "\""
        case .array(let v):
            return "[" + v.map { $0.jsonString }.joined(separator: ",") + "]"
        case .object(let v):
            return "{" + v.sorted { $0.key < $1.key }
                .map { "\"\($0.key)\":\($0.value.jsonString)" }.joined(separator: ",") + "}"
        case .null:
            return "null"
        }
    }
}
